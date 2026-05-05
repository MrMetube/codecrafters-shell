package main

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

State :: struct {
    cwd: string,
    exit: bool,
    
    builtins: [dynamic] string,
}

main :: proc() {
    standart_in := os.to_reader(os.stdin)
    r, ok := io.to_read_write_closer(standart_in)
    assert(ok)
    
    buffer: [256] u8
    
    state: State
    state.cwd, _ = os.get_working_directory(context.allocator)
    
    for !state.exit {
        fmt.printf("$ ")
        
        // @todo(viktor): read line, not read all
        read_bytes, read_error := io.read(r, buffer[:])
        if read_error != nil {
            fmt.panicf("ERROR: failed to read into buffer:%v\n", read_error)
        }
        input := transmute(string) buffer[:read_bytes]
        
        arguments := strings.trim_space(input)
        command   := chop(&arguments, " ")
        
        clear(&state.builtins)

        if is_command(&state, "exit", command) {
            state.exit = true
        } else if is_command(&state, "echo", command) {
            fmt.printf("%v\n", arguments)
        } else if is_command(&state, "pwd", command) {
            fmt.printf("%v\n", state.cwd)
        } else if is_command(&state, "type", command) {
            found := false
            for it in state.builtins {
                if it == arguments {
                    found = true
                    break
                }
            }
            
            if found {
                fmt.printf("%v is a shell builtin\n", arguments)
            } else {
                exe_name := chop(&arguments, " ")
                
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
                exe_command: [dynamic] string
                append(&exe_command, exe_name)
                for arguments != "" {
                    append(&exe_command, chop(&arguments, " "))
                }
                
                description: os.Process_Desc
                description.command = exe_command[:]
                
                state, out_buffer, err_buffer, error := os.process_exec(description, context.temp_allocator)
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
    append(&state.builtins, command)
    
    result: bool
    if input == command {
        result = true
    }
    
    return result
}

chop :: proc (s: ^string, separator: string) -> (string, bool) #optional_ok {
    head, match, tail := strings.partition(s^, separator)
    ok := match == separator
    s^ = tail
    return head, ok
}