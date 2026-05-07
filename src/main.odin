package main

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

State :: struct {
    initialized: bool,
    
    working_directory: string,
    exit: bool,
    
    allocator:         runtime.Allocator,
    command_allocator: runtime.Allocator,
    
    builtins: [dynamic] string,
    
    jobs: [dynamic] Job,
}

Pipeline :: struct {
    background: bool,
    
    commands: ^[dynamic] Command,
    output: ^os.File,
    error:  ^os.File,
}

Command :: struct {
    arguments: [dynamic] string,
    
    process: os.Process,
    is_builtin: bool,
}

Target :: enum { Out, Err }

Job :: struct {
    state: Job_State,
    process: os.Process,
    command_line: string,
}

Job_State :: enum {
    Unused,
    Running,
    Done,
}

Parser :: struct {
    state: ^State,
    allocator: runtime.Allocator,
    
    buffer: strings.Builder,
    input: string,
    
    pipeline: Pipeline,
}

Redirection_Kind :: enum { Create, Append }

state_init :: proc (state: ^State) {
    state.command_allocator = context.temp_allocator
    state.allocator         = context.allocator
    
    state.working_directory, _ = os.get_working_directory(state.allocator)
    
    state.builtins = make([dynamic] string, state.allocator)
    state.jobs     = make([dynamic] Job, state.allocator)
    
    clear(&state.builtins)
    
    dummy  := strings.builder_make(context.temp_allocator)
    writer := strings.to_writer(&dummy)
    
    command: Command
    command.arguments = make([dynamic] string, context.temp_allocator)
    append(&command.arguments, "")
    
    eval_builtin(state, command, writer, writer)
    
    state.initialized = true
}

main :: proc () {
    standart_in := os.to_reader(os.stdin)
    reader,  ok := io.to_read_write_closer(standart_in)
    assert(ok)
    
    state: State
    state_init(&state)
    
    for !state.exit {
        free_all(state.command_allocator)
        
        reap_jobs_and_print(&state, os.to_writer(os.stdout), show_running = false)
        
        fmt.printf("$ ")
        
        input_builder := strings.builder_make(state.command_allocator)
        for {
            read, _, read_error := io.read_rune(reader)
            
            if read_error != nil {
                fmt.panicf("ERROR: failed to read into rune: %v\n", read_error)
            }
            
            if read == '\r' {
                read, _, read_error = io.read_rune(reader)
                if read_error != nil {
                    fmt.panicf("ERROR: failed to read into rune: %v\n", read_error)
                }
            }
            
            if read == '\n' {
                break
            }
            
            if read == '\t' {
                partial_input := strings.to_string(input_builder)
                fmt.printf("You input: ´%v´\n", partial_input)
                for builtin in state.builtins {
                    if strings.starts_with(builtin, partial_input) {
                        fmt.printf("$ %v\n", builtin)
                        break
                    }
                }
            } else {
                strings.write_rune(&input_builder, read)
            }
        }
        
        input_text := strings.to_string(input_builder)
        // @leak
        cmd_buf := make([dynamic] Command, state.command_allocator)
        pipeline := parse_arguments(&state, input_text, &cmd_buf, state.command_allocator)
        // assert that command's arguments are not empty
        
        if len(pipeline.commands) == 1 {
            output := os.to_writer(pipeline.output)
            error  := os.to_writer(pipeline.error)
            
            command := &pipeline.commands[0]
            if command.is_builtin {
                eval_builtin(&state, command^, output, error)
            } else {
                eval_command(&state, pipeline, command, output)
            }
        } else if len(pipeline.commands) == 2 {
            output := os.to_writer(pipeline.output)
            error  := os.to_writer(pipeline.error)
            
            first  := pipeline.commands[0]
            second := pipeline.commands[1]
            
            task: {
                if !first.is_builtin  && !command_is_in_path(pipeline, first)  { break task }
                if !second.is_builtin && !command_is_in_path(pipeline, second) { break task }
                
                second_in, first_out, pipe_error := os.pipe()
                assert(pipe_error == nil)
                
                if first.is_builtin {
                    // @todo(viktor): just using the first_out pipe-end causes an infinite stall/hang
                    _output := strings.builder_make(state.command_allocator)
                    eval_builtin(&state, first, strings.to_writer(&_output), error)
                    os.write_string(first_out, strings.to_string(_output))
                } else {
                    start_command(&state, &first, { stdout = first_out }, error)
                }
                os.close(first_out)
                
                if second.is_builtin {
                    _output := strings.builder_make(state.command_allocator)
                    pipe_read_all(&_output, second_in)
                    
                    if !first.is_builtin {
                        _, _ = os.process_wait(first.process)
                    }
                    
                    first_output := strings.to_string(_output)
                    append(&second.arguments, strings.clone(first_output, state.command_allocator))
                        
                    eval_builtin(&state, second, output, error)
                } else {
                    eval_command(&state, pipeline, &second, output, second_in)
                }
            }
        } else {
            unimplemented()
        }
    }
}

eval_command :: proc (state: ^State, pipeline: Pipeline, command: ^Command, output: io.Writer, input: ^os.File = nil) {
    if !command_is_in_path(pipeline, command^) { return }
    
    start_command(state, command, { stdout = pipeline.output, stderr = pipeline.error, stdin = input }, os.to_writer(pipeline.error))
    
    if !pipeline.background {
        _, wait_error := os.process_wait(command.process)
        assert(wait_error == nil)
    } else {
        // @leak pipeline's ^os.File handles
        
        index := -1
        for job, job_index in state.jobs {
            if job.state == .Unused {
                index = job_index
                delete(job.command_line, state.allocator)
                break
            }
        }
        
        if index == -1 {
            index = len(state.jobs)
            append_nothing(&state.jobs)
        }
        
        job := &state.jobs[index]
        job^ = {
            state = .Running,
            process = command.process,
            // @todo(viktor): quote args with a space
            command_line = strings.join(command.arguments[:], " ", state.allocator),
        }
        
        id := index + 1
        fmt.wprintfln(output, "[%v] %v", id, command.process.pid)
    }
}

start_command :: proc (state: ^State, command: ^Command, params: os.Process_Desc = {}, error: io.Writer) {
    params := params
    params.command = command.arguments[:]
    params.working_dir = state.working_directory
    
    process, start_error := os.process_start(params)
    if start_error != nil {
        command_name := command.arguments[0]
        fmt.wprintfln(error, "ERROR trying to start %v: %v", command_name, start_error)
    }
    
    command.process = process
}

pipe_read_all :: proc (buffer: ^strings.Builder, read_end: ^os.File) {
    buf: [4096] u8 = ---
    read_loop: for {
        has_data, err := os.pipe_has_data(read_end)
        n: int
        if has_data {
            n, err = os.read(read_end, buf[:])
        }
        
        switch err {
        case nil: append(&buffer.buf, ..buf[:n])
        case .EOF, .Broken_Pipe:
            break read_loop
        case: unimplemented()
        }
    }
}

eval_builtin :: proc (state: ^State, command: Command, output, error: io.Writer) {
    command_name := command.arguments[0]
    arguments    := command.arguments[1:]
    
    if is_builtin(state, "exit", command_name) {
        state.exit = true
    } else if is_builtin(state, "echo", command_name) {
        for arg, index in arguments {
            if index != 0 do fmt.wprintf(output, " ")
            fmt.wprintf(output, "%v", arg)
        }
        fmt.wprintf(output, "\n")
    } else if is_builtin(state, "cd", command_name) {
        target := shift(&arguments)
        
        target = eval_path(state, target)
        
        if os.is_directory(target) {
            next, _ := os.clean_path(target, state.allocator)
            
            delete_string(state.working_directory, state.allocator)
            state.working_directory = next
        } else {
            fmt.wprintfln(output, "cd: %v: No such file or directory", target)
        }
    } else if is_builtin(state, "pwd", command_name) {
        fmt.wprintfln(output, "%v", state.working_directory)
    } else if is_builtin(state, "jobs", command_name) {
        reap_jobs_and_print(state, output, show_running = true)
    } else if is_builtin(state, "type", command_name) {
        is_builtin := false
        
        exe_name := shift(&arguments)
        for it in state.builtins {
            if it == exe_name {
                is_builtin = true
                break
            }
        }
        
        if is_builtin {
            fmt.wprintfln(output, "%v is a shell builtin", exe_name)
        } else {
            fullpath, found := find_in_path(exe_name)
            if found {
                fmt.wprintfln(output, "%v is %v", exe_name, fullpath)
            } else {
                fmt.wprintfln(output, "%v: not found", exe_name)
            }
        }
    }
}

is_builtin :: proc (state: ^State, command, input: string) -> bool {
    if !state.initialized {
        append(&state.builtins, command)
        return false
    }
    
    result: bool
    if input == command {
        result = true
    }
    
    return result
}

command_is_builtin :: proc (state: ^State, command: Command) -> bool {
    name := command.arguments[0]
    result: bool
    
    for builtin in state.builtins {
        if builtin == name {
            result = true
            break
        }
    }
    
    return result
}

////////////////////////////////////////////////

eval_path :: proc (state: ^State, target: string) -> string {
    result: string
    if target == "~" {
        result, _ = os.user_home_dir(state.command_allocator)
    } else if !os.is_absolute_path(target) {
        result, _ = os.join_path({state.working_directory, target}, state.command_allocator)
    } else {
        result = strings.clone(target)
    }
    
    return result
}

////////////////////////////////////////////////

reap_jobs_and_print :: proc (state: ^State, output: io.Writer, show_running := false) {
    high_job_ids: [2] int
    for &job, index in state.jobs {
        if job.state == .Unused do continue
        
        process_state, wait_error := os.process_wait(job.process, timeout = 0)
        done: bool
        if wait_error != nil && wait_error != .Timeout {
            ok := false
            when ODIN_OS == .Linux {
                if wait_error == os.Platform_Error.ECHILD {
                    ok = true
                }
            }
            
            if !ok {
                fmt.panicf("Error when waiting on pid %v: %v : %v\n", job.process.pid, wait_error, os.error_string(wait_error))
            }
        }
        
        if (wait_error == .Timeout || wait_error == nil) && process_state.exited {
            done = true
        }
        
        if done {
            job.state = .Done
        }
        
        id := index + 1
        if id > high_job_ids[0] {
            high_job_ids[1] = high_job_ids[0]
            high_job_ids[0] = id
        } else if id > high_job_ids[1] {
            high_job_ids[1] = id
        }
    }
    
    for &job, index in state.jobs {
        if job.state == .Unused do continue
        
        id := index + 1
        icon := " "
        if id == high_job_ids[0] { icon = "+" }
        if id == high_job_ids[1] { icon = "-" } 
        
        print := job.state == .Done
        if show_running do print = true
        
        if print {
            fmt.wprintfln(output, "[%v]%v  %-24s%v", id, icon, job.state, job.command_line)
        }
        
        if job.state == .Done {
            job.state = .Unused
        }
    }
}

////////////////////////////////////////////////

parse_arguments :: proc (state: ^State, input: string, commands_buffer: ^[dynamic] Command, allocator: runtime.Allocator) -> Pipeline {
    parser: Parser
    parser.state = state
    parser.input = input
    parser.allocator = allocator
    parser.buffer = strings.builder_make(parser.allocator)
    
    parser.pipeline.commands = commands_buffer
    parser.pipeline.output   = os.stdout
    parser.pipeline.error    = os.stderr
    
    loop: for parser.input != "" {
        command := parse_command(&parser)
        
        before := parser.input
        peeked := parse_string(&parser)
        
        ended: bool
        switch peeked {
        // @todo(viktor): there could be multiple redirections but no more pipes or commands
        case "1>", ">":   parse_redirection(&parser, &parser.pipeline, .Create, .Out); ended = true
        case "2>":        parse_redirection(&parser, &parser.pipeline, .Create, .Err); ended = true
        case "1>>", ">>": parse_redirection(&parser, &parser.pipeline, .Append, .Out); ended = true
        case "2>>":       parse_redirection(&parser, &parser.pipeline, .Append, .Err); ended = true
            
        case "|":
            // continue pipeline
            
        case "&":
            parser.pipeline.background = true
            ended = true
            
        case: 
            // @note(viktor): reset what was peeked
            // @todo(viktor): is anything else even valid?
            parser.input = before
        }
        
        append(parser.pipeline.commands, command)
        
        if ended {
            if parser.input != "" {
                // @todo(viktor): fix this message, not always being after &
                fmt.panicf("ERROR content after '&': `%v`\n", parser.input)
            }
            break loop
        }
    }
    
    return parser.pipeline
}

parse_command :: proc (parser: ^Parser) -> Command {
    command: Command
    command.arguments = make([dynamic] string, parser.allocator)
    
    loop: for parser.input != "" {
        before := parser.input
        current := parse_string(parser)
        
        switch current {
        case "": continue loop
        
        case "1>", ">", "2>", "1>>", ">>", "2>>", "|", "&":
            parser.input = before
            break loop
        }
        
        append(&command.arguments, strings.clone(current, parser.allocator))
    }
    
    command.is_builtin = command_is_builtin(parser.state, command)
    
    return command
}

parse_redirection :: proc (parser: ^Parser, pipeline: ^Pipeline, kind: Redirection_Kind, target: Target) {
    arg := parse_string(parser)
    // @todo(viktor): handle empty result
    
    path := eval_path(parser.state, arg)
    
    flags := os.File_Flags{ .Read, .Write, .Create }
    switch kind {
        case .Create: flags += { .Trunc }
        case .Append: flags += { .Append }
    }
    
    // @todo(viktor): handle the error
    handle, open_error := os.open(path, flags)
    assert(open_error == nil)
    
    switch target {
        case .Out: pipeline.output   = handle
        case .Err: pipeline.error = handle
    }
}

parse_string :: proc (parser: ^Parser) -> string {
    strings.builder_reset(&parser.buffer)
    
    Flags :: bit_set[ enum {
        space_is_break,
        double_quote_sets,
        double_quote_ends,
        single_quote_sets,
        single_quote_ends,
        backslash_is_escape,
        
        escape_only_special,
        
        // transient flags
        escape_next,
    }]
    
    Normal :: Flags { .space_is_break, .double_quote_sets, .single_quote_sets, .backslash_is_escape }
    Single :: Flags { .single_quote_ends }
    Double :: Flags { .double_quote_ends, .backslash_is_escape, .escape_only_special }
    
    Escape_Special :: Flags { .escape_next, .escape_only_special }
    
    tasks := Normal
    
    eaten: int
    
    loop: for r in parser.input {
        eaten += 1
        
        append_rune: bool
        if Escape_Special <= tasks {
            tasks -= { .escape_next }
            switch r {
            case '"', '$', '\\', '`', '\n': append_rune = true
            case:                           unimplemented("invalid escaped character")
            }
        } else if .escape_next in tasks {
            tasks -= { .escape_next }
            
            append_rune = true
        } else if .space_is_break      in tasks && strings.is_space(r) {
            break loop
        } else if .double_quote_sets   in tasks && r == '\"' {
            tasks = Double
        } else if .double_quote_ends   in tasks && r == '\"' {
            tasks = Normal
        } else if .single_quote_sets   in tasks && r == '\'' {
            tasks = Single
        } else if .single_quote_ends   in tasks && r == '\'' {
            tasks = Normal
        } else if .backslash_is_escape in tasks && r == '\\' {
            tasks += { .escape_next }
        } else {
            append_rune = true
        }
        
        if append_rune {
            strings.write_rune(&parser.buffer, r)
        }
    }
    
    parser.input = parser.input[eaten:]
    
    result := strings.to_string(parser.buffer)
    
    return result
}

////////////////////////////////////////////////

find_in_path :: proc (target: string) -> (string, bool) {
    path_variable := os.get_env("PATH", context.temp_allocator)
                
    fullpath: string
    ok: bool
    for path_variable != "" {
        path_separator :: ";" when ODIN_OS == .Windows else ":"
        
        dir_path := chop(&path_variable, path_separator)
        
        dir_info, dir_error := os.read_all_directory_by_path(dir_path, context.temp_allocator)
        if dir_error == nil {
            for info in dir_info {
                if info.name == target {
                    fullpath = info.fullpath
                    ok = true
                }
            }
        }
    }
    
    return fullpath, ok
}

command_is_in_path :: proc (pipeline: Pipeline, command: Command) -> bool {
    name := command.arguments[0]
    
    _, result := find_in_path(name)
    if !result {
        fmt.fprintf(pipeline.error, "%v: command not found\n", name)
    }
    return result
}

chop :: proc (s: ^string, separator: string) -> (string, bool) #optional_ok {
    head, match, tail := strings.partition(s^, separator)
    ok := match == separator
    s^ = tail
    return head, ok
}

////////////////////////////////////////////////

shift :: proc (s: ^[] string) -> string {
    assert(len(s) > 0)
    result := s[0]
    s^ = s[1:]
    return result
}