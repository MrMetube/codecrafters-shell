#+build linux
package main

import "core:sys/posix"

original: posix.termios

begin_terminal_mode :: proc () {
    if !posix.isatty(posix.STDIN_FILENO) {
        panic("stdin is not a terminal")
    }
    
    if posix.tcgetattr(posix.STDIN_FILENO, &original) != .OK {
        panic("tcgetattr should not fail")
    }
    
    raw := original
    raw.c_lflag -= { .ECHO, .ICANON }
    
    // Read one byte at a time.
    raw.c_cc[auto_cast posix.VMIN]  = 1
    raw.c_cc[auto_cast posix.VTIME] = 0
    
    if posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &raw) != .OK {
        panic("tcsetattr should not fail")
    }
}

end_terminal_mode :: proc () {
    posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &original)
}
