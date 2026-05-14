pub const cell = @import("cell.zig");

pub const options = @import("terminal_options");

/// This is set to true when we're building the C library.
pub const c_api = if (options.c_abi) @import("c/main.zig") else void;

test {
    @import("std").testing.refAllDecls(@This());
}
