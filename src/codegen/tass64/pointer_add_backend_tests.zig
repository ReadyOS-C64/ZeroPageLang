const std = @import("std");
const parser = @import("../../parser.zig");
const pipeline = @import("pipeline.zig");
const a = std.testing.allocator;
const body =
    \\fn readIndexed(pointer: [*]volatile u8, index: u16) u8 { return pointer[index]; }
    \\fn writeIndexed(pointer: [*]volatile u8, index: u16, value: u8) void { pointer[index] = value; }
    \\export fn main() void {
    \\    const pointer: [*]volatile u8 = @ptrFromInt(0xc1ff);
    \\    writeIndexed(pointer, 0x0101, 0x81);
    \\    _ = readIndexed(pointer, 0x0101);
    \\}
;
const old_setup =
    \\    sta zeropage_ptr_value
    \\    stx zeropage_ptr_value+1
    \\    clc
    \\    lda zeropage_ptr_tmp
    \\    adc zeropage_ptr_value
    \\    sta zeropage_ptr_tmp
    \\    lda zeropage_ptr_tmp+1
    \\    adc zeropage_ptr_value+1
    \\    sta zeropage_ptr_tmp+1
;
const new_setup =
    \\    sta zeropage_ptr_value
    \\    stx zeropage_ptr_value+1
    \\    clc
    \\    adc zeropage_ptr_tmp
    \\    sta zeropage_ptr_tmp
    \\    txa
    \\    adc zeropage_ptr_tmp+1
    \\    sta zeropage_ptr_tmp+1
;
fn emitted(prefix: []const u8, source_body: []const u8) ![]u8 {
    const text = try std.mem.concat(a, u8, &.{ prefix, "\n", source_body });
    defer a.free(text);
    const parsed = try parser.parseSource(a, text);
    defer parsed.deinit(a);
    return pipeline.emitProgram(a, parsed.program);
}
fn has(text: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, text, needle) != null);
}
fn lacks(text: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, text, needle) == null);
}

test "pointer addition backend uses held index while retaining scratch writes and volatile accesses" {
    for ([_][]const u8{ "", "pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .off } };", "pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scratch } };", "pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scalars } };" }) |prefix| {
        const assembly = try emitted(prefix, body);
        defer a.free(assembly);
        try has(assembly, "    adc readIndexed_pointer\n    sta zeropage_ptr_tmp\n    txa\n    adc readIndexed_pointer+1\n");
        try has(assembly, "    adc writeIndexed_pointer\n    sta zeropage_ptr_tmp\n    txa\n    adc writeIndexed_pointer+1\n");
        try lacks(assembly, old_setup);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "    lda (zeropage_ptr_tmp),y\n"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "    sta (zeropage_ptr_tmp),y\n"));
    }
}

test "pointer addition backend respects source selected pointer pairs and full pool" {
    const prefix = "pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scalars, .ranges = .{ .{ .addr = 0x20, .size = 4 } } } };";
    const assembly = try emitted(prefix, body);
    defer a.free(assembly);
    try has(assembly, "    adc readIndexed_pointer\n");
    try has(assembly, "    adc writeIndexed_pointer\n");
    try lacks(assembly, old_setup);
    try has(assembly, "zeropage_ptr_tmp = address($20)");
    try has(assembly, "zeropage_ptr_value:\n    .word 0");
}

test "pointer addition backend retained asm and ROM shadow keep original setup" {
    const asm_body =
        \\fn readIndexed(pointer: [*]volatile u8, index: u16) u8 { return pointer[index]; }
        \\export fn main() void {
        \\    const pointer: [*]volatile u8 = @ptrFromInt(0xc1ff);
        \\    _ = readIndexed(pointer, 0x0101);
        \\    asm {
        \\        nop
        \\    }
        \\}
    ;
    const assembly = try emitted("", asm_body);
    defer a.free(assembly);
    try has(assembly, old_setup);
    try lacks(assembly, new_setup);
    const shadow = try emitted("pub const zeropage_options = .{ .image = .{ .basic_stub = false, .load_addr = 0xa000, .entry_addr = 0xa000 } };", body);
    defer a.free(shadow);
    try has(shadow, old_setup);
    try lacks(shadow, new_setup);
}

test "pointer addition backend module and fixed placement keep original setup" {
    const module_prefix =
        \\pub const zeropage_options = .{ .stack = .{ .base = 0xc800, .size = 0x400 }, .abi = .{ .functions = .{ .entry = .{ .frame = .stack } } } };
        \\pub const zeropage_module = .{ .id = "pointer_guard", .abi = 1, .exports = .{ .entry = entry }, .deps = .{} };
        \\fn entry(value: u8) u8 { return value; }
    ;
    const placement_prefix =
        \\pub const zeropage_options = .{ .memory = .{ .regions = .{ .fixed = .{ .addr = 0x2000, .size = 0x100 } }, .placements = .{ .fixed = .{ .region = .fixed, .load = .direct, .functions = .{ placed } } } } };
        \\fn placed() u8 { return 7; }
    ;
    for ([_][]const u8{ module_prefix, placement_prefix }) |prefix| {
        const assembly = try emitted(prefix, body);
        defer a.free(assembly);
        try has(assembly, old_setup);
        try lacks(assembly, new_setup);
    }
}
