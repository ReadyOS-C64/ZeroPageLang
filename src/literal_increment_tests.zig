const std = @import("std");
const parser = @import("parser.zig");
const pipeline = @import("codegen/tass64/pipeline.zig");
const increment = @import("codegen/tass64/literal_increment.zig");

const allocator = std.testing.allocator;
const source =
    \\fn word(n: u16) u16 {
    \\    var value: u16 = n;
    \\    value += 1;
    \\    return value + 1;
    \\}
    \\fn byte(n: u8) u8 {
    \\    var value: u8 = n;
    \\    value += 1;
    \\    return value + 1;
    \\}
    \\fn byteUnused(n: u8) u8 {
    \\    var value: u8 = n;
    \\    value += 1;
    \\    return n + 1;
    \\}
    \\export fn main() void { _ = word(255); _ = byte(255); _ = byteUnused(255); }
;

fn compile(text: []const u8) ![]u8 {
    const parsed = try parser.parseSource(allocator, text);
    defer parsed.deinit(allocator);
    return pipeline.emitProgram(allocator, parsed.program);
}

test "literal increment compacts owned byte and word updates when outputs die" {
    const assembly = try compile(source);
    defer allocator.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    inc word_value\n    bne zeropage_word_increment_") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    inc word_value+1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    inc byte_value\n    lda byte_value\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    inc byteUnused_value\n    lda byteUnused_n\n") != null);
}

test "literal increment keeps status at return and retains observable operand paths" {
    const returning = try compile(
        \\fn word(n: u16) u16 { var value: u16 = n; value += 1; return value; }
        \\export fn main() void { _ = word(255); }
    );
    defer allocator.free(returning);
    try std.testing.expect(std.mem.indexOf(u8, returning, "    inc word_value\n") == null);
    for ([_][]const u8{
        "pub const zeropage_options = .{ .image = .{ .basic_stub = false, .load_addr = 0xa000, .entry_addr = 0xa000 } };",
        "pub const zeropage_options = .{ .modules = .{ .load_window = .{ .addr = 0xc000, .size = 0x800 }, .reu_cache = .{ .addr = 0x20000, .size = 0x10000 } } };",
    }) |prefix| {
        const text = try std.mem.concat(allocator, u8, &.{ prefix, "\n", source });
        defer allocator.free(text);
        const assembly = try compile(text);
        defer allocator.free(assembly);
        try std.testing.expect(std.mem.indexOf(u8, assembly, "    inc word_value\n") == null);
        try std.testing.expect(std.mem.indexOf(u8, assembly, "    inc byte_value\n") == null);
    }
    const assembly = try compile(
        \\export fn main() u8 {
        \\    var value: u8 = 4;
        \\    value += 1;
        \\    asm {
        \\        nop
        \\    }
        \\    return value + 1;
        \\}
    );
    defer allocator.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    inc main_value\n") == null);
}

test "literal increment follows both paths and keeps the high-byte flags live" {
    const parsed = try parser.parseSource(allocator, "export fn main() void {}");
    defer parsed.deinit(allocator);
    const prefix =
        \\* = $2000
        \\; zeropage_section_begin owner=function:main kind=code
        \\main:
        \\    ldx #0
        \\    lda #1
        \\    clc
        \\    adc main_word
        \\    sta main_word
        \\    txa
        \\    adc main_word+1
        \\    sta main_word+1
    ;
    const suffix =
        \\; zeropage_section_end owner=function:main kind=code
        \\; zeropage_section_begin owner=function:main kind=static_frame
        \\main_word:
        \\    .word 0
        \\; zeropage_section_end owner=function:main kind=static_frame
    ;
    for ([_][]const u8{
        "    php\n    rts",
        "    bne live\n    ldx #0\n    lda #0\n    clc\n    adc #0\nlive:\n    rts",
        "    lda #0\n    ldx #0\n    bvc live\n    clc\nlive:\n    rts",
        "    ldx #0\n    lda #0\n    clc\n    adc #0\n    rts",
    }, 0..) |continuation, index| {
        const text = try std.mem.concat(allocator, u8, &.{ prefix, "\n", continuation, "\n", suffix, "\n" });
        defer allocator.free(text);
        const result = try increment.rewrite(allocator, parsed.program, text);
        defer if (result) |rewritten| allocator.free(rewritten);
        try std.testing.expectEqual(index == 3, result != null);
    }
}
