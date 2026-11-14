const std = @import("std");
const parser = @import("parser.zig");
const pipeline = @import("codegen/tass64/pipeline.zig");

const a = std.testing.allocator;
const sample =
    \\fn transform(value: u16) u16 { return value + 7; }
    \\export fn main() void {
    \\    const input: *volatile u16 = @ptrFromInt(0xc1ff);
    \\    const output: *volatile u16 = @ptrFromInt(0xc310);
    \\    const value: u16 = input.*;
    \\    output.* = transform(value);
    \\}
;

fn emit(source: []const u8) ![]u8 {
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    return pipeline.emitProgram(a, parsed.program);
}

test "literal pointer I/O preserves the crossing read and both target stores" {
    const assembly = try emit(sample);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    ldy #1\n    lda $c1ff\n    ldx $c1ff,y\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    ldy #1\n    sta $c310\n    lda zeropage_ptr_value+1\n    sta $c311\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "main_input:\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "main_output:\n") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "; zeropage_inline_begin function=transform\n"));
}

test "literal pointer I/O retains the indirect path for unproved domains or pointer escapes" {
    for ([_][2][]const u8{
        .{ "0xc1ff", "0xcfff" },
        .{ "0xc1ff", "0x080d" },
        .{ "0xc1ff", "0x00fb" },
        .{ "const input:", "var input:" },
        .{ "    const value: u16 = input.*;", "    const alias: *volatile u16 = input;\n    const value: u16 = alias.*;" },
    }) |change| {
        const source = try std.mem.replaceOwned(u8, a, sample, change[0], change[1]);
        defer a.free(source);
        const assembly = try emit(source);
        defer a.free(assembly);
        try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda (zeropage_ptr_tmp),y\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, assembly, "    sta (zeropage_ptr_tmp),y\n") != null);
    }
}

test "literal pointer I/O preserves a live initializer register on the skipped path" {
    const assembly = try emit(
        \\export fn main() void {
        \\    const input: *volatile u8 = @ptrFromInt(0xc100);
        \\    const flag: u8 = input.*;
        \\    const output: *volatile u16 = @ptrFromInt(0xc3ff);
        \\    if (flag != 0) { output.* = 0x817e; }
        \\}
    );
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    ldx #195\n    lda main_flag\n    sec\n    beq if_0_else\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    sta $c3ff\n    lda zeropage_ptr_value+1\n    sta $c400\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "main_output:\n") == null);
}

test "literal pointer I/O works with a remapped managed snapshot" {
    const assembly = try emit("pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scratch, .ranges = .{.{ .addr = 0x24, .size = 16 }} } };\n" ++ sample);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_ptr_tmp = address($24)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    sta zeropage_zp_snapshot+0,x\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda $c1ff\n    ldx $c1ff,y\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    sta $c310\n    lda zeropage_ptr_value+1\n    sta $c311\n") != null);
}
