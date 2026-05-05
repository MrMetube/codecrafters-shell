package main

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

main :: proc() {
    standart_in := os.to_reader(os.stdin)
    r, ok := io.to_read_write_closer(standart_in)
    assert(ok)
    
    buffer: [256] u8
    
    loop := true
    builtins: [dynamic] string
    for loop {
        fmt.printf("$ ")
        
        // @todo(viktor): read line, not read all
        read_bytes, read_error := io.read(r, buffer[:])
        if read_error != nil {
            fmt.panicf("ERROR: failed to read into buffer:%v\n", read_error)
        }
        input := transmute(string) buffer[:read_bytes]
        
        arguments := strings.trim_space(input)
        command   := chop(&arguments, " ")
        // fmt.printf("command = `%v` arguments = `%v`", command, arguments)
        
        handled := false
        
        clear(&builtins)

        if is_command(&builtins, &handled, "exit", command) {
            loop = false
        }
        
        if is_command(&builtins, &handled, "echo", command) {
            fmt.printf("%v\n", arguments)
        }

        if is_command(&builtins, &handled, "type", command) {
            found := false
            for it in builtins {
                if it == arguments {
                    found = true
                    break
                }
            }
            
            if found {
                fmt.printf("%v is a shell builtin\n", arguments)
            } else {
                
                dirs: [] string
                path_variable := os.get_env("PATH", context.temp_allocator)
                
                found_path: string
                for path_variable != "" {
                    path_separator :: ";" when ODIN_OS == .Windows else ":"
                    
                    dir_path, ok := chop(&path_variable, path_separator)
                    if !ok {
                        dir_path = path_variable
                        path_variable = ""
                    }
                    
                    dir_info, dir_error := os.read_all_directory_by_path(dir_path, context.temp_allocator)
                    if dir_error == nil {
                        for info in dir_info {
                            if (os.Permissions_Execute_All & info.mode != {}) && info.name == arguments {
                                found_path = info.fullpath
                            }
                        }
                    }
                }
                
                if found_path != "" {
                    fmt.printf("%v is %v\n", arguments, found_path)
                } else {
                    fmt.printf("%v: not found\n", arguments)
                }
            }            
        }
        
        
        if !handled {
            fmt.printf("%v: command not found\n", command)
        }
    }
}

is_command :: proc (builtins: ^[dynamic] string, handled: ^bool, command, input: string) -> bool {
    append(builtins, command)
    
    result: bool
    if input == command {
        result = true
        handled^ = true
    }
    
    return result
}

chop :: proc (s: ^string, separator: string) -> (string, bool) #optional_ok {
    head, match, tail := strings.partition(s^, separator)
    ok := match == separator
    if ok {
        s^ = tail
    }
    return head, ok
}