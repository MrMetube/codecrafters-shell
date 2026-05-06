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
    
    allocator: runtime.Allocator,
    command_allocator: runtime.Allocator,
    
    builtins: [dynamic] string,
    
    jobs: [dynamic] Job
}

Input :: struct {
    arguments:  [] string,
    file:       [Target] ^os.File,
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

Eval_Result :: struct {
}

state_init :: proc (state: ^State) {
    state.command_allocator = context.temp_allocator
    state.allocator         = context.allocator
    
    state.working_directory, _ = os.get_working_directory(state.allocator)
    
    state.builtins = make([dynamic] string, state.allocator)
    state.jobs = make([dynamic] Job, state.allocator)
    
    clear(&state.builtins)
    dummy := strings.builder_make(context.temp_allocator)
    input: Input
    eval(state, "", &input, &dummy, &dummy)
    
    state.initialized = true
}

main :: proc () {
    standart_in := os.to_reader(os.stdin)
    reader, ok := io.to_read_write_closer(standart_in)
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
        
        out := strings.builder_make(state.command_allocator)
        err := strings.builder_make(state.command_allocator)
        
        eval(&state, command, &input, &out, &err)
        
        fmt.fprintf(input.file[.Out], "%v", strings.to_string(out))
        fmt.fprintf(input.file[.Err], "%v", strings.to_string(err))
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
        
        target = parse_path(state, target)
        
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
                description.stdout = input.file[.Out]
                description.stderr = input.file[.Err]
                
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

parse_path :: proc (state: ^State, target: string) -> string {
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

Parser :: struct {
    state: enum {
        None,
        Single,
        Double,
        Redirection,
        Background,
    },
    
    redirection_target: Target,
    redirection_kind: enum { Create, Append },
}

parse_arguments :: proc (state: ^State, input: string, allocator: runtime.Allocator) -> Input {
    arguments := make([dynamic] string, allocator)
    parser: Parser
    
    escape_next: bool
    
    current := strings.builder_make(allocator)
    
    result: Input
    result.file[.Out] = os.stdout
    result.file[.Err] = os.stderr
    
    for r, index in input {
        action: enum { None, Append_Current, Append_Rune }
        
        if escape_next {
            escape_next = false
            if parser.state == .Double {
                switch r {
                case '"', '$', '\\', '`', '\n':
                    action = .Append_Rune
                }
            } else {
                action = .Append_Rune
            }
        } else {
            switch parser.state {
            case .Background:
                fmt.panicf("ERROR content after '&': `%v`\n", input[index:]) 
            case .None, .Redirection:
                if r == '\"' {
                    parser.state = .Double
                } else if r == '\'' {
                    parser.state = .Single
                } else if r == '\\' {
                    escape_next = true
                } else if strings.is_space(r) {
                    action = .Append_Current
                } else {
                    action = .Append_Rune
                }
                
            case .Single:
                if r == '\'' {
                    parser.state = .None
                } else {
                    action = .Append_Rune
                }
            
            case .Double:
                if r == '\"' {
                    parser.state = .None
                } else if r == '\\' {
                    escape_next = true
                } else {
                    action = .Append_Rune
                }
            }
        }
        
        switch action {
        case .None: // nothing
        
        case .Append_Current:
            append_arg(state, &parser, &arguments, &current, &result, allocator)
            
        case .Append_Rune:
            strings.write_rune(&current, r)
        }
    }
    
    // @todo(viktor): incomplete redirection missing target param
    append_arg(state, &parser, &arguments, &current, &result, allocator)
    
    assert(parser.state != .Redirection)
    
    if parser.state == .Background {
        result.background = true
    }
    
    result.arguments = arguments[:]
    
    return result
}

append_arg :: proc (state: ^State, parser: ^Parser, arguments: ^[dynamic] string, current: ^strings.Builder, result: ^Input, allocator: runtime.Allocator) {
    if strings.builder_len(current^) != 0 {
        if parser.state == .Redirection {
            parser.state = .None
            
            current_string := strings.to_string(current^)
            defer strings.builder_reset(current)
            
            path := parse_path(state, current_string)
            
            flags := os.File_Flags{ .Read, .Write, .Create }
            switch parser.redirection_kind {
                case .Create: flags += { .Trunc }
                case .Append: flags += { .Append }
            }
            
            // @todo(viktor): handle the error
            result.file[parser.redirection_target], _ = os.open(path, flags) 
        } else {
            current_string := strings.to_string(current^)
            defer strings.builder_reset(current)
            
            switch current_string {
            case "1>", ">":
                parser.state = .Redirection
                parser.redirection_target = .Out
                parser.redirection_kind   = .Create
                
            case "2>":
                parser.state = .Redirection
                parser.redirection_target = .Err
                parser.redirection_kind   = .Create
                
            case "1>>", ">>":
                parser.state = .Redirection
                parser.redirection_target = .Out
                parser.redirection_kind   = .Append
                
            case "2>>":
                parser.state = .Redirection
                parser.redirection_target = .Err
                parser.redirection_kind   = .Append
            case "&":
                parser.state = .Background
            case:
                append(arguments, strings.clone(strings.to_string(current^), allocator))
            }
        }
    }
}

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