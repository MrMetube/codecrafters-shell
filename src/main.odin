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
    for loop {
        fmt.printf("$ ")
        
        read_bytes, read_error := io.read(r, buffer[:])
        if read_error != nil {
            fmt.panicf("ERROR: failed to read into buffer:%v\n", read_error)
        }
        
        command := transmute(string) buffer[:read_bytes]
        command = strings.trim_space(command)
        switch command {
        case "exit":
            loop = false
        case "echo":
            fmt.printf("%v\n", command)
        case:
            fmt.printf("%v: command not found\n", command)
        }
    }
}
