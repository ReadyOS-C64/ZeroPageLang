const std = @import("std");
const parser = @import("parser.zig");
const pipeline = @import("codegen/tass64/pipeline.zig");
const a = std.testing.allocator;

const source =
    \\fn readIndexed(pointer: [*]volatile u8, index: u16) u8 { return pointer[index]; }
    \\fn writeIndexed(pointer: [*]volatile u8, index: u16, value: u8) void { pointer[index] = value; }
    \\export fn main() void {
    \\    const p: [*]volatile u8 = @ptrFromInt(0xc1ff);
    \\    writeIndexed(p, 257, 129);
    \\    _ = readIndexed(p, 257);
    \\}
;

fn compiled(prefix: []const u8, body: []const u8) ![]u8 {
    const text = try std.mem.concat(a, u8, &.{ prefix, "\n", body });
    defer a.free(text);
    const parsed = try parser.parseSource(a, text);
    defer parsed.deinit(a);
    return pipeline.emitProgram(a, parsed.program);
}

fn has(assembly: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, assembly, part) != null;
}

test "direct pointer bases avoid staging the source word but retain the physical access and index scratch" {
    const assembly = try compiled("", source);
    defer a.free(assembly);
    try std.testing.expect(has(assembly, "    adc readIndexed_pointer\n    sta zeropage_ptr_tmp\n    txa\n    adc readIndexed_pointer+1\n"));
    try std.testing.expect(has(assembly, "    adc writeIndexed_pointer\n    sta zeropage_ptr_tmp\n    txa\n    adc writeIndexed_pointer+1\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, "    sta zeropage_ptr_value\n    stx zeropage_ptr_value+1\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "    lda (zeropage_ptr_tmp),y\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "    sta (zeropage_ptr_tmp),y\n"));
}

test "direct pointer bases keep remapped mandatory pair and tight scratch pool" {
    const prefix = "pub const zeropage_options=.{.zero_page=.{.profile=.kernal,.allocation=.scalars,.ranges=.{.{.addr=0x20,.size=4}}}};";
    const assembly = try compiled(prefix, source);
    defer a.free(assembly);
    try std.testing.expect(has(assembly, "    adc readIndexed_pointer\n"));
    try std.testing.expect(has(assembly, "zeropage_ptr_tmp = address($20)"));
    try std.testing.expect(has(assembly, "zeropage_ptr_value:\n    .word 0"));
}

test "direct pointer bases leave loader, fixed placement and ROM shadow paths guarded" {
    for ([_][]const u8{
        "pub const zeropage_options=.{.image=.{.basic_stub=false,.load_addr=0xa000,.entry_addr=0xa000}};",
        "pub const zeropage_options=.{.modules=.{.load_window=.{.addr=0xc000,.size=0x800},.reu_cache=.{.addr=0x20000,.size=0x10000}}};",
        "pub const zeropage_options=.{.memory=.{.regions=.{.r=.{.addr=0x2000,.size=256}},.placements=.{.p=.{.region=.r,.load=.direct,.functions=.{placed}}}}};fn placed()u8{return 7;}",
    }) |prefix| {
        const assembly = try compiled(prefix, source);
        defer a.free(assembly);
        try std.testing.expect(!has(assembly, "    adc readIndexed_pointer\n"));
        try std.testing.expect(!has(assembly, "    adc writeIndexed_pointer\n"));
    }
}

const pass = @import("codegen/tass64/pointer_add_forwarding.zig");
const raw =
    \\zeropage_ptr_tmp = $fb
    \\* = $2000
    \\; zeropage_section_begin owner=function:main kind=code
    \\main:
    \\    ldx base+1
    \\    lda base
    \\    sta zeropage_ptr_tmp
    \\    stx zeropage_ptr_tmp+1
    \\    ldx index+1
    \\    lda index
    \\    sta zeropage_ptr_value
    \\    stx zeropage_ptr_value+1
    \\    clc
    \\    lda zeropage_ptr_tmp
    \\    adc zeropage_ptr_value
    \\    sta zeropage_ptr_tmp
    \\    lda zeropage_ptr_tmp+1
    \\    adc zeropage_ptr_value+1
    \\    sta zeropage_ptr_tmp+1
    \\    rts
    \\; zeropage_section_end owner=function:main kind=code
    \\; zeropage_section_begin owner=function:main kind=static_frame
    \\base:
    \\    .word 0
    \\index:
    \\    .word 0
    \\; zeropage_section_end owner=function:main kind=static_frame
    \\; zeropage_section_begin owner=compiler kind=scratch
    \\zeropage_ptr_value:
    \\    .word 0
    \\; zeropage_section_end owner=compiler kind=scratch
    \\
;

fn selected(text: []const u8, expected: usize) !void {
    const parsed = try parser.parseSource(a, "export fn main()void{}");
    defer parsed.deinit(a);
    const result = try pass.rewriteWithDirectBases(a, parsed.program, text);
    defer a.free(result.assembly);
    try std.testing.expectEqual(expected, result.stats.direct_bases_folded);
    if (expected != 0) {
        try std.testing.expectEqual(@as(usize, 13), result.stats.bytes_saved);
        try std.testing.expect(has(result.assembly, "    ldx index+1\n    lda index\n    sta zeropage_ptr_value\n    stx zeropage_ptr_value+1\n    clc\n    adc base\n    sta zeropage_ptr_tmp\n    txa\n    adc base+1\n    sta zeropage_ptr_tmp+1\n"));
    }
}

test "direct pointer bases validate both complete words, unique ownership, and exact instructions" {
    try selected(raw, 1);
    for ([_][2][]const u8{
        .{ "base:\n    .word 0", "base:\n    .byte 0\n    .byte 0" },
        .{ "base:\n", "BAse = $2100\nbase:\n" },
        .{ "base:\n", "alias:\nbase:\n" },
        .{ "index:\n", "index:\nINDEX:\n" },
        .{ "    lda base\n", "    lda @w base\n" },
        .{ "    lda base\n", "    lda base+0\n" },
        .{ "    ldx index+1\n", "midway:\n    ldx index+1\n" },
        .{ "    adc zeropage_ptr_value\n", "    adc zeropage_ptr_value+0\n" },
        .{ "* = $2000", "* = $a000" },
        .{ "* = $2000", ".cpu \"65816\"\n* = $2000" },
        .{ "; zeropage_section_begin owner=function:main kind=static_frame", "* = $2000\n; zeropage_section_begin owner=function:main kind=static_frame" },
        .{ "; zeropage_section_begin owner=compiler kind=scratch", "* = $2000\n; zeropage_section_begin owner=compiler kind=scratch" },
        .{ "zeropage_ptr_tmp = $fb", "zeropage_ptr_tmp = $fe" },
    }) |pair| {
        const text = try std.mem.replaceOwned(u8, a, raw, pair[0], pair[1]);
        defer a.free(text);
        try selected(text, 0);
    }
}

fn verifyAllocation(allocator: std.mem.Allocator, program: @import("ast.zig").Program) !void {
    const result = pass.rewriteWithDirectBases(allocator, program, raw) catch |err| {
        return if (err == error.WriteFailed) error.OutOfMemory else err;
    };
    defer allocator.free(result.assembly);
    try std.testing.expectEqual(@as(usize, 1), result.stats.direct_bases_folded);
}

test "direct pointer bases free all model, policy and output allocations" {
    const parsed = try parser.parseSource(a, "export fn main()void{}");
    defer parsed.deinit(a);
    try std.testing.checkAllAllocationFailures(a, verifyAllocation, .{parsed.program});
}
