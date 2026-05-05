package main

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

State :: struct {
    working_directory: string,
    exit: bool,
    
    command_allocator: runtime.Allocator,
    
    builtins: [dynamic] string,
}

main :: proc() {
    standart_in := os.to_reader(os.stdin)
    r, ok := io.to_read_write_closer(standart_in)
    assert(ok)
    
    buffer: [256] u8
    
    state: State
    state.command_allocator = context.temp_allocator
    state_allocator   := context.allocator
    
    state.working_directory, _ = os.get_working_directory(state_allocator)
    
    for !state.exit {
        free_all(state.command_allocator)
        
        fmt.printf("$ ")
        
        // @todo(viktor): read line, not read all
        read_bytes, read_error := io.read(r, buffer[:])
        if read_error != nil {
            fmt.panicf("ERROR: failed to read into buffer:%v\n", read_error)
        }
        input_text := transmute(string) buffer[:read_bytes]
        
        // @cleanup
        input := parse_arguments(&state, input_text, state.command_allocator)
        arguments := input.arguments
        
        if len(arguments) == 0 do continue
        
        command := shift(&arguments)
        
        clear(&state.builtins)
        
        out_sb := strings.builder_make(state.command_allocator)
        err_sb := strings.builder_make(state.command_allocator)
        
        if is_command(&state, "exit", command) {
            state.exit = true
        } else if is_command(&state, "echo", command) {
            for arg, index in arguments {
                if index != 0 do fmt.sbprintf(&out_sb, " ")
                fmt.sbprintf(&out_sb, "%v", arg)
            }
            fmt.sbprintf(&out_sb, "\n")
        } else if is_command(&state, "cd", command) {
            target := shift(&arguments)
            
            target = parse_path(&state, target)
            
            if os.is_directory(target) {
                next, _ := os.clean_path(target, state_allocator)
                
                delete_string(state.working_directory, state_allocator)
                state.working_directory = next
            } else {
                fmt.sbprintf(&out_sb, "cd: %v: No such file or directory\n", target)
            }
            
        } else if is_command(&state, "pwd", command) {
            fmt.sbprintf(&out_sb, "%v\n", state.working_directory)
        } else if is_command(&state, "type", command) {
            found := false
            
            exe_name := shift(&arguments)
            for it in state.builtins {
                if it == exe_name {
                    found = true
                    break
                }
            }
            
            if found {
                fmt.sbprintf(&out_sb, "%v is a shell builtin\n", exe_name)
            } else {
                fullpath, ok := find_in_path(exe_name)
                if ok {
                    fmt.sbprintf(&out_sb, "%v is %v\n", exe_name, fullpath)
                } else {
                    fmt.sbprintf(&out_sb, "%v: not found\n", exe_name)
                }
            }            
        } else {
            exe_name := command
            _, found := find_in_path(exe_name)
            
            if found {
                exe_command: [dynamic] string // @leak
                
                append(&exe_command, exe_name)
                append(&exe_command, ..arguments)
                
                description: os.Process_Desc
                description.command = exe_command[:]
                description.working_dir = state.working_directory
                command_state, out_buffer, err_buffer, error := os.process_exec(description, state.command_allocator)
                if error != nil {
                    fmt.sbprintf(&err_sb, "ERROR trying to execute %v: %v\n", exe_name, error)
                }
                
                out_string := transmute(string) out_buffer
                err_string := transmute(string) err_buffer
                
                fmt.sbprintf(&out_sb, "%v", out_string)
                fmt.sbprintf(&err_sb, "%v", err_string)
            } else {
                fmt.sbprintf(&err_sb, "%v: command not found\n", command)
            }
        }
        
        if strings.builder_len(out_sb) > 0 {
            fmt.fprintf(input.file[.Out], "%v", strings.to_string(out_sb))
        }
        
        if strings.builder_len(err_sb) > 0 {
            fmt.fprintf(input.file[.Err], "%v", strings.to_string(err_sb))
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
    
    current:= strings.builder_make(allocator)
    
    skip_next: bool
    escape_next: bool
    was_space: bool
    for r, index in input {
        append_current: bool
        append_rune: bool
        
        defer was_space = strings.is_space(r)
        
        next_rune: rune
        if index+1 < len(input) {
            next_rune = cast(rune) input[index+1]
        }
        
        if skip_next {
            skip_next = false
            continue
        } else if escape_next {
            escape_next = false
            if quote_kind == .Double {
                switch r {
                case '"', '$', '\\', '`', '\n':
                    append_rune = true
                }
            } else {
                append_rune = true
            }
        } else {
            switch quote_kind {
            case .None:
                if r == '\"' {
                    if next_rune == '\"' {
                        skip_next = true
                    } else {
                        if was_space {
                            append_current = true
                        }
                        quote_kind = .Double
                    }
                } else if r == '\'' {
                    if next_rune == '\'' {
                        skip_next = true
                    } else {
                        if was_space {
                            append_current = true
                        }
                        quote_kind = .Single
                    }
                } else if r == '\\' {
                    escape_next = true
                } else if strings.is_space(r) {
                    append_current = true
                } else {
                    append_rune = true
                }
                
            case .Single:
                if r == '\'' {
                    if next_rune == '\'' {
                        skip_next = true
                    } else {
                        quote_kind = .None
                    }
                } else {
                    append_rune = true
                }
            
            case .Double:
                if r == '\"' {
                    if next_rune == '\"' {
                        skip_next = true
                    } else {
                        quote_kind = .None
                    }
                } else if r == '\\' {
                    escape_next = true
                } else if r == '\r' || r == '\n' {
                    append_current = true
                } else {
                    append_rune = true
                }
            }
        }
        
        if append_current {
            if strings.builder_len(current) != 0 {
                append(&arguments, strings.clone(strings.to_string(current), allocator))
                strings.builder_reset(&current)
            }
        } else if append_rune {
            strings.write_rune(&current, r)
        }
    }
    
    result: Input
    result.file[.Out] = os.stdout
    result.file[.Err] = os.stderr
    {
        is:    [Target] enum { None, Create, Append }
        index: [Target] int
        
        for arg, arg_index in arguments {
            if arg == "1>" || arg == ">" {
                if arg_index == len(arguments) -1 {
                    // @todo(viktor): Error: something like pwsh's: Missing file specification after redirection operator.
                } else {
                    is[.Out] = .Create
                    index[.Out] = arg_index + 1
                }
            }
            
            if arg == "2>" {
                if arg_index == len(arguments) -1 {
                    // @todo(viktor): Error: something like pwsh's: Missing file specification after redirection operator.
                } else {
                    is[.Err] = .Create
                    index[.Err] = arg_index + 1
                }
            }
            
            if arg == "1>>" || arg == ">>" {
                if arg_index == len(arguments) -1 {
                    // @todo(viktor): Error: something like pwsh's: Missing file specification after redirection operator.
                } else {
                    is[.Out] = .Append
                    index[.Out] = arg_index + 1
                }
            }
            
            if arg == "2>>" {
                if arg_index == len(arguments) -1 {
                    // @todo(viktor): Error: something like pwsh's: Missing file specification after redirection operator.
                } else {
                    is[.Err] = .Append
                    index[.Err] = arg_index + 1
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
    append(&state.builtins, command)
    
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