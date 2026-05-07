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
    arguments: [] string,
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
    dummy := strings.builder_make(context.temp_allocator)
    command: Command
    command.arguments = {""}
    eval(state, command, &dummy, &dummy, false)
    
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
        
        {
            out := strings.builder_make(state.command_allocator)
            reap_jobs_and_print(&state, &out, show_running = false)
            fmt.printf("%v", strings.to_string(out))
        }
        
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
        
        output := strings.builder_make(state.command_allocator)
        error  := strings.builder_make(state.command_allocator)
                
        if len(pipeline.commands) == 1 {
            command := pipeline.commands[0]
            
            if pipeline.background {
                // @leak pipeline's ^os.File handles
                eval(&state, command, &output, &error, true, pipeline.output, pipeline.error)
            } else {
                eval(&state, command, &output, &error, false)
            }
        } else if len(pipeline.commands) == 2 {
            first  := pipeline.commands[0]
            second := pipeline.commands[1]
            
            first_name  := first.arguments[0]
            second_name := second.arguments[0]
            
            _, first_found  := find_in_path(first_name)
            _, second_found := find_in_path(second_name)
            
            if !first_found {
                fmt.sbprintf(&error, "%v: command not found\n", first_name)
            } else {
                if !second_found {
                    fmt.sbprintf(&error, "%v: command not found\n", second_name)
                } else {
                    second_in, first_out, pipe_error := os.pipe()
                    assert(pipe_error == nil)
                    
                    start_command(&state,   first,           &error, first_out)
                    execute_command(&state, second, &output, &error, second_in)
                }
            }
        } else {
            unimplemented()
        }
        fmt.fprintf(pipeline.output, "%v", strings.to_string(output))
        fmt.fprintf(pipeline.error,  "%v", strings.to_string(error))
    }
}

eval :: proc (state: ^State, command: Command, output, error: ^strings.Builder, is_background: bool, bg_output: ^os.File = nil, bg_error: ^os.File = nil) {
    command_name := command.arguments[0]
    
    handled := eval_builtin(state, command_name, command.arguments[1:], output, error)
    if handled { return }
    
    _, found := find_in_path(command_name)
    if !found {
        fmt.sbprintf(error, "%v: command not found\n", command_name)
        return
    }
    
    if is_background {
        process := start_command(state, command, error, bg_output, bg_error)
        
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
            process = process,
            // @todo(viktor): quote args with a space
            command_line = strings.join(command.arguments, " ", state.allocator),
        }
        
        id := index + 1
        fmt.sbprintfln(output, "[%v] %v", id, process.pid)
    } else {
        execute_command(state, command, output, error)
    }
}

start_command :: proc (state: ^State, command: Command, error: ^strings.Builder, out: ^os.File = nil, err: ^os.File = nil) -> os.Process {
    command_name := command.arguments[0]
    
    process, start_error := os.process_start({
        command     = command.arguments,
        working_dir = state.working_directory,
        stdout      = out,
        stderr      = err,
    })
    
    if start_error != nil {
        fmt.sbprintf(error, "ERROR trying to start %v: %v\n", command_name, start_error)
    }
    
    return process
}
execute_command :: proc (state: ^State, command: Command, output, error: ^strings.Builder, input: ^os.File = nil) {
    command_name := command.arguments[0]
    
    _, out_buffer, error_buffer, exec_error := os.process_exec({
        command     = command.arguments,
        working_dir = state.working_directory,
        stdin       = input,
    }, state.command_allocator)
    
    if exec_error != nil {
        fmt.sbprintf(error, "ERROR trying to exec %v: %v\n", command_name, exec_error)
    }
    
    out_string := transmute(string) out_buffer
    err_string := transmute(string) error_buffer
    
    fmt.sbprintf(output, "%v", out_string)
    fmt.sbprintf(error,  "%v", err_string)
}

eval_builtin :: proc (state: ^State, command_name: string, arguments: [] string, output, error: ^strings.Builder) -> bool {
    arguments := arguments
    
    result := true
    if is_builtin(state, "exit", command_name) {
        state.exit = true
    } else if is_builtin(state, "echo", command_name) {
        for arg, index in arguments {
            if index != 0 do fmt.sbprintf(output, " ")
            fmt.sbprintf(output, "%v", arg)
        }
        fmt.sbprintf(output, "\n")
    } else if is_builtin(state, "cd", command_name) {
        target := shift(&arguments)
        
        target = eval_path(state, target)
        
        if os.is_directory(target) {
            next, _ := os.clean_path(target, state.allocator)
            
            delete_string(state.working_directory, state.allocator)
            state.working_directory = next
        } else {
            fmt.sbprintf(output, "cd: %v: No such file or directory\n", target)
        }
        
    } else if is_builtin(state, "pwd", command_name) {
        fmt.sbprintf(output, "%v\n", state.working_directory)
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
            fmt.sbprintf(output, "%v is a shell builtin\n", exe_name)
        } else {
            fullpath, found := find_in_path(exe_name)
            if found {
                fmt.sbprintf(output, "%v is %v\n", exe_name, fullpath)
            } else {
                fmt.sbprintf(output, "%v: not found\n", exe_name)
            }
        }
    } else {
        result = false
    }
    
    return result
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

reap_jobs_and_print :: proc (state: ^State, output: ^strings.Builder, show_running := false) {
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
            fmt.sbprintfln(output, "[%v]%v  %-24s%v", id, icon, job.state, job.command_line)
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
        // @todo(viktor): can only redirect or pipe, right?
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
                fmt.panicf("ERROR content after '&': `%v`\n", parser.input)
            }
            break loop
        }
    }
    
    return parser.pipeline
}

parse_command :: proc (parser: ^Parser) -> Command {
    arguments := make([dynamic] string, parser.allocator)
    
    command: Command
    
    loop: for parser.input != "" {
        before := parser.input
        current := parse_string(parser)
        
        switch current {
        case "": continue loop
        
        case "1>", ">", "2>", "1>>", ">>", "2>>", "|", "&":
            parser.input = before
            break loop
        }
        
        append(&arguments, strings.clone(current, parser.allocator))
    }
    
    command.arguments = arguments[:]
    
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
                if (os.Permissions_Execute_All & info.mode != {}) {
                    if info.name == target {
                        fullpath = info.fullpath
                        ok = true
                    }
                }
            }
        }
    }
    
    return fullpath, ok
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