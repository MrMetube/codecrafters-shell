#+build linux
package main

import "core:fmt"
import "core:sys/posix"

begin_terminal_mode :: proc () -> (rawptr, bool) {
    // @slop
    if !posix.isatty(posix.STDIN_FILENO) {
        fmt.eprintln("stdin is not a terminal")
        return nil, false
    }
    
    original := new(posix.termios)
    if posix.tcgetattr(posix.STDIN_FILENO, original) != .OK {
        fmt.eprintln("tcgetattr failed")
        return nil, false
    }
    
    raw := original^
    raw.c_lflag -= { .ECHO, .ICANON }
    
    // Read one byte at a time.
    raw.c_cc[auto_cast posix.VMIN]  = 1
    raw.c_cc[auto_cast posix.VTIME] = 0
    
    if posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &raw) != .OK {
        fmt.eprintln("tcsetattr failed")
        return original, false
    }
    
    return original, true
}

end_terminal_mode :: proc (data: rawptr) {
    if data != nil {
        original := cast(^posix.termios) data
        posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, original)
        free(original)
    }
}
