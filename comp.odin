package comp

import "core:os"
import "core:fmt"

main :: proc () {
    for arg, index in os.args {
        fmt.printfln("%d%v", index, arg)
    }
    fmt.printfln("line:%v", os.get_env("COMP_LINE", context.allocator))
    fmt.printfln("point:%v", os.get_env("COMP_POINT", context.allocator))
}