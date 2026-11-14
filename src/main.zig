const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) u8 {
    var it = std.process.Args.Iterator.init(init.minimal.args);
    defer it.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(init.gpa);
    while (it.next()) |arg| args.append(init.gpa, arg) catch return 1;

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    defer stdout_writer.interface.flush() catch {};
    defer stderr_writer.interface.flush() catch {};

    cli.run(init.gpa, init.io, init.environ_map, args.items, &stdout_writer.interface, &stderr_writer.interface) catch return 1;
    return 0;
}
