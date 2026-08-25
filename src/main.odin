#+vet explicit-allocators
package main

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:slice"

Allocator :: runtime.Allocator

Shell :: struct {
    initialized: bool,
    
    working_directory: string,
    exit: bool,
    
    allocator:         Allocator,
    command_allocator: Allocator,
    
    builtins: [dynamic] string,
    
    jobs: [dynamic] Job,
    
    history: [dynamic] string,
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
    shell: ^Shell,
    allocator: Allocator,
    
    buffer: strings.Builder,
    input: string,
    
    pipeline: Pipeline,
}

Redirection_Kind :: enum { Create, Append }

shell_init :: proc (shell: ^Shell) {
    shell.command_allocator = context.temp_allocator
    shell.allocator         = context.allocator
    
    shell.working_directory, _ = os.get_working_directory(shell.allocator)
    
    shell.builtins = make([dynamic] string, shell.allocator)
    shell.jobs     = make([dynamic] Job, shell.allocator)
    
    clear(&shell.builtins)
    
    dummy  := strings.builder_make(context.temp_allocator)
    writer := strings.to_writer(&dummy)
    
    command: Command
    command.arguments = make([dynamic] string, context.temp_allocator)
    append(&command.arguments, "")
    
    eval_builtin(shell, command, writer, writer)
    
    shell.initialized = true
}

main :: proc () {
    standart_in := os.to_reader(os.stdin)
    reader,  ok := io.to_read_write_closer(standart_in)
    assert(ok)
    
    shell: Shell
    shell_init(&shell)
    
    cmd_buf := make([dynamic] Command, shell.allocator)
    
    terminal_data, terminal_ok := begin_terminal_mode()
    assert(terminal_ok)
    defer end_terminal_mode(terminal_data)
    
    for !shell.exit {
        free_all(shell.command_allocator)
        clear(&cmd_buf)
        
        reap_jobs_and_print(&shell, os.to_writer(os.stdout), show_running = false)
        
        redraw_prompt("")
        
        typed:   [dynamic; 4096] u8
        matches: [dynamic; 2048] string
        
        input: for {
            read_buffer: [1] u8
            read_count, read_error := io.read(reader, read_buffer[:])
            if read_error != nil {
                fmt.panicf("ERROR: failed to read : %v\n", read_error)
            }
            
            typed_character := read_buffer[0]
            reset_matches := true
            switch typed_character {
            case '\t':
                reset_matches = false
                if len(matches) == 0 {
                    prefix := transmute(string) typed[:]
                    for command in shell.builtins {
                        if strings.starts_with(command, prefix) {
                            append(&matches, command)
                        }
                    }
                    
                    matches_in_path :: proc (matches: ^[dynamic; $N] string, prefix: string, allocator: Allocator) {
                        // @speed cache this
                        path_variable := os.get_env("PATH", allocator)
                        
                        // @copypasta form find_in_path
                        match: for path_variable != "" {
                            path_separator :: ";" when ODIN_OS == .Windows else ":"
                            
                            dir_path := chop(&path_variable, path_separator)
                            
                            dir_info, dir_error := os.read_all_directory_by_path(dir_path, allocator)
                            if dir_error == nil {
                                for info in dir_info {
                                    if (os.Permissions_Execute_All & info.mode != {}) {
                                        if strings.starts_with(info.name, prefix) {
                                            // @hack to skip cases where the system echo and the builtin echo are added to matches.
                                            present: bool
                                            for match in matches {
                                                if match == info.name {
                                                    present = true
                                                    break
                                                }
                                            }
                                            
                                            if !present {
                                                append(matches, info.name)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    matches_in_path(&matches, prefix, shell.command_allocator)
                    slice.sort(matches[:])
                    
                    switch len(matches) {
                    case 0:
                        fmt.print('\a')
                        
                    case 1:
                        copy_to_buffer(&typed, transmute([] u8) matches[0])
                        append(&typed, ' ')
                        reset_matches = true
                        
                    case:
                        longer_prefix_found: bool
                        longer_prefix: string
                        first := matches[0]
                        // @speed
                        for i in 0..<len(first)-len(prefix) {
                            // lexical sorting ensures that the shortes common-prefix would appear before longer matches with that prefix
                            longer_prefix = first[:len(first)-i]
                            longer_prefix_found = true
                            for other in matches[1:] {
                                if !strings.starts_with(other, longer_prefix) {
                                    longer_prefix_found = false
                                    break
                                }
                            }
                            
                            if longer_prefix_found {
                                break
                            }
                        }
                        
                        if !longer_prefix_found {   
                            fmt.print('\a')
                        } else if longer_prefix != prefix {
                            copy_to_buffer(&typed, transmute([] u8) longer_prefix)
                            reset_matches = true
                        }
                    }
                } else {
                    fmt.printf("\n")
                    for match, index in matches {
                        if index > 0 { fmt.printf("  ") }
                        fmt.printf("%v", match)
                    }
                    fmt.printf("\n")
                }
                
            case '\b', 0x7F:
                if len(typed) > 0 {
                    typed[len(typed)-1] = 0
                    resize(&typed, len(typed)-1)
                }
                   
            case '\n':
                append(&typed, typed_character)
                break input
                
            case:
                append(&typed, typed_character)
            }
            
            if reset_matches {
                clear(&matches)
            }
            
            redraw_prompt(&typed)
        }
        redraw_prompt(&typed)
        
        input_text := transmute(string) typed[:]
        input_text = strings.trim_space(input_text)
        
        if input_text != "" {
            append(&shell.history, strings.clone(input_text, shell.allocator))
        }
        pipeline := parse_pipeline(&shell, input_text, &cmd_buf, shell.command_allocator)
        // assert that command's arguments are not empty
        
        output := os.to_writer(pipeline.output)
        error  := os.to_writer(pipeline.error)
        
        valid := true
        for c in pipeline.commands {
            if !command_valid(error, c) {
                valid = false
            }
        }
        
        if valid {
            Pipe :: struct {
                input:  ^os.File,
                output: ^os.File,
            }
            
            pipes := make([] Pipe, len(pipeline.commands), shell.command_allocator)
            
            for index in 0..<len(pipeline.commands)-1 {
                r, w, pipe_error  := os.pipe()
                assert(pipe_error == nil)
                pipes[index].output  = w
                pipes[index+1].input = r
            }
            
            for &command, index in pipeline.commands {
                pipe := pipes[index]
                
                if command.is_builtin {
                    if index > 0 {
                        prev    := pipeline.commands[index-1]
                        prev_output := strings.builder_make(shell.command_allocator)
                        pipe_read_all(&prev_output, pipe.input)
                        
                        if !prev.is_builtin {
                            _, _ = os.process_wait(prev.process)
                        }
                        
                        append(&command.arguments, strings.clone(strings.to_string(prev_output), shell.command_allocator))
                    }
                    
                    if index < len(pipeline.commands)-1 {
                        // @todo(viktor): just using the pipe.output causes an infinite stall/hang
                        this_output := strings.builder_make(shell.command_allocator)
                        eval_builtin(&shell, command, strings.to_writer(&this_output), error)
                        os.write_string(pipe.output, strings.to_string(this_output))
                    } else {
                        eval_builtin(&shell, command, output, error)
                    }
                } else {
                    if index < len(pipes)-1 {
                        start_command(&shell, &command, { stdout = pipe.output, stdin = pipe.input }, error)
                    } else {
                        eval_command(&shell, pipeline, &command, output, pipe.input)
                    }
                }
                
                os.close(pipe.output)
            }
        }
        
        if pipeline.error  != os.stderr { os.close(pipeline.error)  }
        if pipeline.output != os.stdout { os.close(pipeline.output) }
    }
}

////////////////////////////////////////////////

redraw_prompt :: proc { redraw_prompt_b, redraw_prompt_s }
redraw_prompt_b :: proc (buffer: ^[dynamic; $N] u8) { redraw_prompt(transmute(string) buffer[:]) }
redraw_prompt_s :: proc (line: string) {
    fmt.printf("\r\x1b[2K$ %s", line)
}

copy_to_buffer :: proc (destination: ^[dynamic; $N] u8, source: [] u8) {
    resize(destination, len(source))
    copy(destination[:], source)
}

eval_command :: proc (shell: ^Shell, pipeline: Pipeline, command: ^Command, output: io.Writer, input: ^os.File = nil) {
    error := os.to_writer(pipeline.error)
    if !command_is_in_path(error, command^) { return }
    
    start_command(shell, command, { stdout = pipeline.output, stderr = pipeline.error, stdin = input }, error)
    
    if !pipeline.background {
        if command.process != {} {
            _, wait_error := os.process_wait(command.process)
            assert(wait_error == nil)
        }
    } else {
        // @leak pipeline's ^os.File handles
        
        index := -1
        for job, job_index in shell.jobs {
            if job.state == .Unused {
                index = job_index
                delete(job.command_line, shell.allocator)
                break
            }
        }
        
        if index == -1 {
            index = len(shell.jobs)
            append_nothing(&shell.jobs)
        }
        
        job := &shell.jobs[index]
        job^ = {
            state = .Running,
            process = command.process,
            // @todo(viktor): quote args with a space
            command_line = strings.join(command.arguments[:], " ", shell.allocator),
        }
        
        id := index + 1
        fmt.wprintfln(output, "[%v] %v", id, command.process.pid)
    }
}

start_command :: proc (shell: ^Shell, command: ^Command, params: os.Process_Desc = {}, error: io.Writer) {
    params := params
    params.command = command.arguments[:]
    params.working_dir = shell.working_directory
    
    process, start_error := os.process_start(params)
    if start_error != nil {
        command_name := command.arguments[0]
        fmt.wprintfln(error, "ERROR trying to start %v: %v", command_name, start_error)
    }
    
    command.process = process
}

pipe_read_all :: proc (buffer: ^strings.Builder, read_end: ^os.File) {
    backing: [4096] u8 = ---
    read_loop: for {
        has_data, err := os.pipe_has_data(read_end)
        read_bytes: int
        if has_data {
            read_bytes, err = os.read(read_end, backing[:])
        }
        
        switch err {
        case nil: append(&buffer.buf, ..backing[:read_bytes])
        case .EOF, .Broken_Pipe:
            break read_loop
        case: unimplemented()
        }
    }
}

eval_builtin :: proc (shell: ^Shell, command: Command, output, error: io.Writer) {
    command_name := command.arguments[0]
    arguments    := command.arguments[1:]
    
    if is_builtin(shell, "exit", command_name) {
        shell.exit = true
    } else if is_builtin(shell, "echo", command_name) {
        for arg, index in arguments {
            if index != 0 do fmt.wprintf(output, " ")
            fmt.wprintf(output, "%v", arg)
        }
        fmt.wprintf(output, "\n")
    } else if is_builtin(shell, "cd", command_name) {
        target := shift(&arguments)
        
        target = eval_path(shell, target)
        
        if os.is_directory(target) {
            next, _ := os.clean_path(target, shell.allocator)
            
            delete_string(shell.working_directory, shell.allocator)
            shell.working_directory = next
        } else {
            fmt.wprintfln(output, "cd: %v: No such file or directory", target)
        }
    } else if is_builtin(shell, "pwd", command_name) {
        fmt.wprintfln(output, "%v", shell.working_directory)
    } else if is_builtin(shell, "jobs", command_name) {
        reap_jobs_and_print(shell, output, show_running = true)
    } else if is_builtin(shell, "history", command_name) {
        for entry, index in shell.history {
            fmt.wprintfln(output, "% 4d  %v", 1+index, entry)
        }
    } else if is_builtin(shell, "type", command_name) {
        is_builtin := false
        
        exe_name := shift(&arguments)
        for it in shell.builtins {
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

is_builtin :: proc (shell: ^Shell, command, input: string) -> bool {
    if !shell.initialized {
        append(&shell.builtins, command)
        return false
    }
    
    result: bool
    if input == command {
        result = true
    }
    
    return result
}

////////////////////////////////////////////////

eval_path :: proc (shell: ^Shell, target: string) -> string {
    result: string
    if target == "~" {
        result, _ = os.user_home_dir(shell.command_allocator)
    } else if !os.is_absolute_path(target) {
        result, _ = os.join_path({shell.working_directory, target}, shell.command_allocator)
    } else {
        result = strings.clone(target, shell.command_allocator)
    }
    
    return result
}

////////////////////////////////////////////////

reap_jobs_and_print :: proc (shell: ^Shell, output: io.Writer, show_running := false) {
    high_job_ids: [2] int
    for &job, index in shell.jobs {
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
    
    for &job, index in shell.jobs {
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

parse_pipeline :: proc (shell: ^Shell, input: string, commands_buffer: ^[dynamic] Command, allocator: Allocator) -> Pipeline {
    parser := Parser {
        shell = shell,
        input = input,
        
        allocator = allocator,
        buffer    = strings.builder_make(allocator),
        
        pipeline = {
            commands = commands_buffer,
            output   = os.stdout,
            error    = os.stderr,
        },
    }
    
    loop: for parser.input != "" {
        command := parse_command(&parser)
        append(parser.pipeline.commands, command)
        
        before := parser.input
        peeked := parse_string(&parser)
        
        
        switch peeked {
            // @todo(viktor): dont accept more pipes or args, just more redirections and a background
        case "1>", ">":   parse_redirection(&parser, &parser.pipeline, .Create, .Out)
        case "2>":        parse_redirection(&parser, &parser.pipeline, .Create, .Err)
        case "1>>", ">>": parse_redirection(&parser, &parser.pipeline, .Append, .Out)
        case "2>>":       parse_redirection(&parser, &parser.pipeline, .Append, .Err)
            
        case "|":
            // continue pipeline
            
        case "&":
            parser.pipeline.background = true
            if parser.input != "" {
                fmt.panicf("ERROR content after '&': `%v`\n", parser.input)
            }
            break loop
            
        case: 
            // @note(viktor): reset what was peeked
            // @todo(viktor): is anything else even valid?
            parser.input = before
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
    
    command.is_builtin = command_is_builtin(parser.shell, command)
    
    return command
}

command_is_builtin :: proc (state: ^Shell, command: Command) -> bool {
    if len(command.arguments) == 0 do return false
    
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

parse_redirection :: proc (parser: ^Parser, pipeline: ^Pipeline, kind: Redirection_Kind, target: Target) {
    arg := parse_string(parser)
    // @todo(viktor): handle empty result
    
    path := eval_path(parser.shell, arg)
    
    flags := os.File_Flags{ .Read, .Write, .Create }
    switch kind {
        case .Create: flags += { .Trunc }
        case .Append: flags += { .Append }
    }
    
    // @todo(viktor): handle the error
    handle, open_error := os.open(path, flags)
    assert(open_error == nil)
    
    switch target {
        case .Out: pipeline.output = handle
        case .Err: pipeline.error  = handle
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
    
    parser.input = strings.trim_left_space(parser.input)
    
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
    parser.input = strings.trim_left_space(parser.input)
    
    result := strings.to_string(parser.buffer)
    
    return result
}

////////////////////////////////////////////////

command_valid :: proc (error: io.Writer, command: Command) -> bool { return command.is_builtin || command_is_in_path(error, command) } 

find_in_path :: proc (target: string) -> (string, bool) {
    // @speed cache this
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

command_is_in_path :: proc (error: io.Writer, command: Command) -> bool {
    if len(command.arguments) == 0 do return false
    
    name := command.arguments[0]
    
    _, result := find_in_path(name)
    if !result {
        fmt.wprintfln(error, "%v: command not found", name)
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