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
}

state_init :: proc (state: ^State) {
    state.command_allocator = context.temp_allocator
    state.allocator         = context.allocator
    
    state.working_directory, _ = os.get_working_directory(state.allocator)
    
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
        // @todo(viktor): 
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
            
            _, out_buffer, err_buffer, exec_error := os.process_exec(description, state.command_allocator)
            
            if exec_error != nil {
                fmt.sbprintf(error, "ERROR trying to execute %v: %v\n", exe_name, error)
            }
            
            out_string := transmute(string) out_buffer
            err_string := transmute(string) err_buffer
            
            fmt.sbprintf(output, "%v", out_string)
            fmt.sbprintf(error, "%v", err_string)
        } else {
            fmt.sbprintf(error, "%v: command not found\n", command)
        }
    }
}

parse_path :: proc (state: ^State, target: string) -> string {
    result := target
    if target == "~" {
        result, _ = os.user_home_dir(state.command_allocator)
    } else if !os.is_absolute_path(target) {
        result, _ = os.join_path({state.working_directory, target}, state.command_allocator)
    }
    
    return result
}

Input :: struct {
    arguments: [] string,
    file: [Target] ^os.File,
}

Target :: enum { Out, Err }

parse_arguments :: proc (state: ^State, input: string, allocator: runtime.Allocator) -> Input {
    arguments := make([dynamic] string, allocator)
    quote_kind: enum {
        None,
        Single,
        Double,
    }
    
    current := strings.builder_make(allocator)
    
    escape_next: bool
    for r, index in input {
        action: enum { None, Append_Current, Append_Rune }
        
        if escape_next {
            escape_next = false
            if quote_kind == .Double {
                switch r {
                case '"', '$', '\\', '`', '\n':
                    action = .Append_Rune
                }
            } else {
                action = .Append_Rune
            }
        } else {
            switch quote_kind {
            case .None:
                if r == '\"' {
                    quote_kind = .Double
                } else if r == '\'' {
                    quote_kind = .Single
                } else if r == '\\' {
                    escape_next = true
                } else if strings.is_space(r) {
                    action = .Append_Current
                } else {
                    action = .Append_Rune
                }
                
            case .Single:
                if r == '\'' {
                    quote_kind = .None
                } else {
                    action = .Append_Rune
                }
            
            case .Double:
                if r == '\"' {
                    quote_kind = .None
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
            if strings.builder_len(current) != 0 {
                append(&arguments, strings.clone(strings.to_string(current), allocator))
                strings.builder_reset(&current)
            }
            
        case .Append_Rune:
            strings.write_rune(&current, r)
        }
    }
    
    if strings.builder_len(current) != 0 {
        append(&arguments, strings.clone(strings.to_string(current), allocator))
        strings.builder_reset(&current)
    }
    
    result: Input
    result.file[.Out] = os.stdout
    result.file[.Err] = os.stderr
    {
        is:    [Target] enum { None, Create, Append }
        index: [Target] int
        
        for arg, arg_index in arguments {
            // @todo(viktor): these can be assigned multiple times in one command
            switch arg {
            case "1>", ">":
                is[.Out]    = .Create
                index[.Out] = arg_index + 1
            
            case "2>":
                is[.Err]    = .Create
                index[.Err] = arg_index + 1
            
            case "1>>", ">>":
                is[.Out]    = .Append
                index[.Out] = arg_index + 1
            
            case "2>>":
                is[.Err]    = .Append
                index[.Err] = arg_index + 1
            }
            
            if is != { .Out = .None, .Err = .None } {
                if arg_index+1 < len(arguments) {
                    
                } else {
                    // @todo(viktor): Error: something like pwsh's: Missing file specification after redirection operator.
                }
            }
        }
        
        for kind in Target {
            if is[kind] != .None {
                index := index[kind]
                
                path := parse_path(state, arguments[index])
                
                flags := os.File_Flags{ .Read, .Write, .Create }
                if is[kind] == .Append {
                    flags += { .Append }
                } else {
                    assert(is[kind] == .Create)
                    flags += { .Trunc }
                }
                
                // @todo(viktor): handle the error
                result.file[kind], _ = os.open(path, flags) 
                
                remove_range(&arguments, index-1, index+1)
            }
        }
    }
    
    result.arguments = arguments[:]
    
    return result
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

clone_string :: proc (s: string, allocator: runtime.Allocator) -> string {
    bytes := transmute([] u8) s
    buffer := make([] u8, len(bytes), allocator)
    copy(buffer, bytes)
    result := transmute(string) buffer
    return result
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