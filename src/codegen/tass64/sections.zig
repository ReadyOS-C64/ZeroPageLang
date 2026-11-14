const std = @import("std");

pub const Owner = union(enum) {
    compiler,
    runtime,
    module: []const u8,
    function: []const u8,
};

pub const Kind = enum {
    code,
    rodata,
    data,
    bss,
    static_frame,
    scratch,
    return_slot,
};

pub const Lifetime = enum {
    static,
    module,
    call,
};

pub const Address = enum {
    near,
    zero_page,
    reu,
};

pub fn emitBegin(writer: anytype, owner: Owner, kind: Kind, lifetime: Lifetime, address: Address) !void {
    try writer.writeAll("; zeropage_section_begin owner=");
    try writeOwner(writer, owner);
    try writer.print(" kind={s} lifetime={s} address={s}\n", .{ @tagName(kind), @tagName(lifetime), @tagName(address) });
}

pub fn emitEnd(writer: anytype, owner: Owner, kind: Kind) !void {
    try writer.writeAll("; zeropage_section_end owner=");
    try writeOwner(writer, owner);
    try writer.print(" kind={s}\n", .{@tagName(kind)});
}

fn writeOwner(writer: anytype, owner: Owner) !void {
    switch (owner) {
        .compiler => try writer.writeAll("compiler"),
        .runtime => try writer.writeAll("runtime"),
        .module => |name| try writer.print("module:{s}", .{name}),
        .function => |name| try writer.print("function:{s}", .{name}),
    }
}

test "emits stable section marker comments" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try emitBegin(&out.writer, .{ .function = "main" }, .code, .static, .near);
    try emitEnd(&out.writer, .{ .function = "main" }, .code);

    try std.testing.expectEqualStrings(
        \\; zeropage_section_begin owner=function:main kind=code lifetime=static address=near
        \\; zeropage_section_end owner=function:main kind=code
        \\
    , out.written());
}
