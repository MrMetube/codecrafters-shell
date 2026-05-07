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
    
    jobs: [dynamic] Job
}

Input :: struct {
    arguments:  [] string,
    out, error: ^os.File,
    background: bool,
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
    
    current: strings.Builder,
    result:  Input,
    input: string,
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
    input: Input
    eval(state, "", &input, &dummy, &dummy)
    
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
        input := parse_arguments(&state, input_text, state.command_allocator)
        
        if len(input.arguments) == 0 do continue
        
        command := shift(&input.arguments)
        
        output := strings.builder_make(state.command_allocator)
        error := strings.builder_make(state.command_allocator)
        
        eval(&state, command, &input, &output, &error)
        
        fmt.fprintf(input.out,   "%v", strings.to_string(output))
        fmt.fprintf(input.error, "%v", strings.to_string(error))
    }
}

eval :: proc (state: ^State, command: string, input: ^Input, output, error: ^strings.Builder) {
    if is_command(state, "exit", command) {
        state.exit = true
    } else if is_command(state, "echo", command) {
        for arg, index in input.arguments {
            if index != 0 do fmt.sbprintf(output, " ")
            fmt.sbprintf(output, "%v", arg)
        }
        fmt.sbprintf(output, "\n")
    } else if is_command(state, "cd", command) {
        target := shift(&input.arguments)
        
        target = eval_path(state, target)
        
        if os.is_directory(target) {
            next, _ := os.clean_path(target, state.allocator)
            
            delete_string(state.working_directory, state.allocator)
            state.working_directory = next
        } else {
            fmt.sbprintf(output, "cd: %v: No such file or directory\n", target)
        }
        
    } else if is_command(state, "pwd", command) {
        fmt.sbprintf(output, "%v\n", state.working_directory)
    } else if is_command(state, "jobs", command) {
        reap_jobs_and_print(state, output, show_running = true)
    } else if is_command(state, "type", command) {
        is_builtin := false
        
        exe_name := shift(&input.arguments)
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
        exe_name := command
        _, found := find_in_path(exe_name)
        
        if found {
            exe_command := make([dynamic] string, state.command_allocator)
            
            append(&exe_command, exe_name)
            append(&exe_command, ..input.arguments)
            
            description := os.Process_Desc {
                command = exe_command[:],
                working_dir = state.working_directory,
            }
            
            // @leak input.file handles
            if input.background {
                description.stdout = input.out
                description.stderr = input.error
                
                process, start_error := os.process_start(description)
                info, _ := os.process_info_by_handle(process, {.PPid}, context.temp_allocator)
                
                if start_error != nil {
                    fmt.sbprintf(error, "ERROR trying to start %v: %v\n", exe_name, error)
                }
                
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
                    command_line = strings.join(exe_command[:], " ", state.allocator),
                }
                
                id := index + 1
                fmt.sbprintfln(output, "[%v] %v", id, process.pid)
            } else {
                _, out_buffer, err_buffer, exec_error := os.process_exec(description, state.command_allocator)
                
                if exec_error != nil {
                    fmt.sbprintf(error, "ERROR trying to execute %v: %v\n", exe_name, error)
                }
                
                out_string := transmute(string) out_buffer
                err_string := transmute(string) err_buffer
                
                fmt.sbprintf(output, "%v", out_string)
                fmt.sbprintf(error, "%v", err_string)
            }
        } else {
            fmt.sbprintf(error, "%v: command not found\n", command)
        }
    }
}

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

parse_arguments :: proc (state: ^State, input: string, allocator: runtime.Allocator) -> Input {
    arguments := make([dynamic] string, allocator)
    
    parser: Parser
    parser.state = state
    parser.input = input
    parser.allocator = allocator
    parser.current = strings.builder_make(parser.allocator)
    parser.result.out   = os.stdout
    parser.result.error = os.stderr
    
    for parser.input != "" {
        current_string := parse_string(&parser)
        
        if current_string != "" {
            switch current_string {
            case "1>", ">":   parse_redirection(&parser, .Create, .Out)
            case "2>":        parse_redirection(&parser, .Create, .Err)
            case "1>>", ">>": parse_redirection(&parser, .Append, .Out)
            case "2>>":       parse_redirection(&parser, .Append, .Err)
                
            case "&":
                parser.result.background = true
                if parser.input != "" {
                    fmt.panicf("ERROR content after '&': `%v`\n", parser.input)
                }
                
            case:
                append(&arguments, strings.clone(current_string, allocator))
            }
        }
    }
    
    parser.result.arguments = arguments[:]
    
    return parser.result
}

parse_redirection :: proc (parser: ^Parser, kind: Redirection_Kind, target: Target) {
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
    
    switch target {
        case .Out: parser.result.out   = handle
        case .Err: parser.result.error = handle
    }
}

parse_string :: proc (parser: ^Parser) -> string {
    strings.builder_reset(&parser.current)
    
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
            strings.write_rune(&parser.current, r)
        }
    }
    
    parser.input = parser.input[eaten:]
    
    result := strings.to_string(parser.current)
    
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

is_command :: proc (state: ^State, command, input: string) -> bool {
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

shift :: proc (s: ^[] string) -> string {
    assert(len(s) > 0)
    result := s[0]
    s^ = s[1:]
    return result
}

chop :: proc (s: ^string, separator: string) -> (string, bool) #optional_ok {
    head, match, tail := strings.partition(s^, separator)
    ok := match == separator
    s^ = tail
    return head, ok
}