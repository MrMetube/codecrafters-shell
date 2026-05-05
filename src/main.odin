package main

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

State :: struct {
    working_directory: string,
    exit: bool,
    
    builtins: [dynamic] string,
}

main :: proc() {
    standart_in := os.to_reader(os.stdin)
    r, ok := io.to_read_write_closer(standart_in)
    assert(ok)
    
    buffer: [256] u8
    
    command_allocator := context.temp_allocator
    state_allocator   := context.allocator
    
    state: State
    state.working_directory, _ = os.get_working_directory(state_allocator)
    
    for !state.exit {
        free_all(command_allocator)
        
        fmt.printf("$ ")
        
        // @todo(viktor): read line, not read all
        read_bytes, read_error := io.read(r, buffer[:])
        if read_error != nil {
            fmt.panicf("ERROR: failed to read into buffer:%v\n", read_error)
        }
        input := transmute(string) buffer[:read_bytes]
        
        arguments := parse_arguments(input, command_allocator)
        
        if len(arguments) == 0 do continue
        
        command := shift(&arguments)
        
        clear(&state.builtins)

        if is_command(&state, "exit", command) {
            state.exit = true
        } else if is_command(&state, "echo", command) {
            for arg, index in arguments {
                if index != 0 do fmt.printf(" ")
                fmt.printf("%v", arg)
            }
            fmt.printf("\n")
        } else if is_command(&state, "cd", command) {
            target := shift(&arguments)
            
            if target == "~" {
                target, _ = os.user_home_dir(command_allocator)
            } else if !os.is_absolute_path(target) {
                target, _ = os.join_path({state.working_directory, target}, command_allocator)
            }
            
            if os.is_directory(target) {
                next, _ := os.clean_path(target, state_allocator)
                
                delete_string(state.working_directory, state_allocator)
                state.working_directory = next
            } else {
                fmt.printf("cd: %v: No such file or directory\n", target)
            }
            
        } else if is_command(&state, "pwd", command) {
            fmt.printf("%v\n", state.working_directory)
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
                fmt.printf("%v is a shell builtin\n", exe_name)
            } else {
                fullpath, ok := find_in_path(exe_name)
                if ok {
                    fmt.printf("%v is %v\n", exe_name, fullpath)
                } else {
                    fmt.printf("%v: not found\n", exe_name)
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
                
                state, out_buffer, err_buffer, error := os.process_exec(description, command_allocator)
                out_string := transmute(string) out_buffer
                fmt.printf("%v", out_string)
                if error != nil {
                    fmt.panicf("ERROR trying to execute %v: %v\n", exe_name, error)
                }
                assert(error == nil)
            } else {
                fmt.printf("%v: command not found\n", command)
            }
        }
    }
}

parse_arguments :: proc (input: string, allocator: runtime.Allocator) -> [] string {
    arguments := make([dynamic] string, allocator)
    quote_kind: enum {
        None,
        Single,
        Double,
    }
    
    current:= strings.builder_make(allocator)
    
    skip_next: bool
    escape_next: bool
    for r, index in input {
        if skip_next {
            skip_next = false
            continue
        }
        
        append_current: bool
        append_rune: bool
        if escape_next {
            escape_next = false
            fmt.sbprintf(&current, "%v", r)
            continue
        }
        
        switch quote_kind {
        case .None:
            if r == '\"' {
                if index+1 < len(input) && input[index+1] == '\"' {
                    skip_next = true
                } else {
                    append_current = true
                    quote_kind = .Double
                }
            } else if r == '\'' {
                if index+1 < len(input) && input[index+1] == '\'' {
                    skip_next = true
                } else {
                    append_current = true
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
                if index+1 < len(input) && input[index+1] == '\'' {
                    skip_next = true
                } else {
                    append_current = true
                    quote_kind = .None
                }
            } else {
                append_rune = true
            }
        
        case .Double:
            if r == '\"' {
                if index+1 < len(input) && input[index+1] == '\"' {
                    skip_next = true
                } else {
                    append_current = true
                    quote_kind = .None
                }
            } else if r == '\r' || r == '\n' {
                append_current = true
            } else {
                append_rune = true
            }
        }
        
        if append_current {
            if strings.builder_len(current) != 0 {
                append(&arguments, strings.clone(strings.to_string(current), allocator))
                strings.builder_reset(&current)
            }
        }
        
        if append_rune {
            fmt.sbprintf(&current, "%v", r)
        }
    }
    
    return arguments[:]
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