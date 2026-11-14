const std = @import("std");
const parser = @import("parser.zig");
const pipeline = @import("codegen/tass64/pipeline.zig");
const masked_multiply = @import("codegen/tass64/masked_multiply.zig");

const a = std.testing.allocator;
const sample =
    \\fn masked(value: u16) u16 {
    \\    return (value & 31) * 3 + (value & 63) * 7 + (value & 127) * 9;
    \\}
    \\export fn main() void {
    \\    const input: *volatile u16 = @ptrFromInt(0xc100);
    \\    const output: *volatile u16 = @ptrFromInt(0xc110);
    \\    var word: u16 = input.*;
    \\    output.* = masked(word);
    \\}
;

fn emit(source: []const u8) ![]u8 {
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    return pipeline.emitBeforeSingleCallLeaf(a, parsed.program);
}

test "masked multiplication removes the dead local high load and keeps both volatile source reads" {
    const assembly = try emit(sample);
    defer a.free(assembly);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, assembly, "    ldx main_word+1\n    lda main_word\n    and #"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, assembly, "    lda main_word\n    and #"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, "    lda $c100,y\n"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, assembly, "    pha\n    ldx #0\n    pla\n    sta zeropage_mul_lhs\n"));
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    asl\n    adc zeropage_mul_lhs\n    pha\n    pla\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    asl\n    asl\n    asl\n    pha\n    txa\n    rol\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    sbc #0\n    tax\n    pla\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    adc #0\n    tax\n    pla\n") != null);
}

const test_packet =
    "* = $0801\n; zeropage_section_begin owner=function:main kind=code\nmain:\n" ++
    "    ldx input_word+1\n    lda input_word\n    and #31\n    pha\n    ldx #0\n    pla\n" ++
    "    sta zeropage_mul_lhs\n    stx zeropage_mul_lhs+1\n" ++
    "    asl\n    pha\n    txa\n    rol\n    tax\n    pla\n" ++
    "    clc\n    adc zeropage_mul_lhs\n    pha\n    txa\n    adc zeropage_mul_lhs+1\n    tax\n    pla\n    rts\n" ++
    "; zeropage_section_end owner=function:main kind=code\n" ++
    "; zeropage_section_begin owner=compiler kind=scratch\nzeropage_mul_lhs:\n    .word 0\n" ++
    "; zeropage_section_end owner=compiler kind=scratch\n";

test "masked multiplication drops only the overwritten load of a verified word claim" {
    const parsed = try parser.parseSource(a, "pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scalars } };\n" ++
        "export fn main() void {}");
    defer parsed.deinit(a);
    const equate = "input_word = address($10)\n";
    const claim = "; zeropage_zp_claim label=input_word addr=16 size=2 kind=parameter benefit=10\n";
    const good = (try masked_multiply.rewriteDeadHighReads(a, parsed.program, test_packet ++ equate ++ claim)) orelse
        return error.ExpectedMaskedRewrite;
    defer a.free(good);
    try std.testing.expect(std.mem.indexOf(u8, good, "main:\n    lda input_word\n    and #31\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, good, "    pha\n    ldx #0\n    pla\n    sta zeropage_mul_lhs\n    stx zeropage_mul_lhs+1\n") != null);

    const bad_claim = "; zeropage_zp_claim label=input_word addr=16 size=1 kind=parameter benefit=10\n";
    for ([_][]const u8{ equate, equate ++ bad_claim, "input_word = $c100\n" }) |alias| {
        const input = try std.mem.concat(a, u8, &.{ test_packet, alias });
        defer a.free(input);
        const output = try masked_multiply.rewriteDeadHighReads(a, parsed.program, input);
        defer if (output) |bytes| a.free(bytes);
        try std.testing.expect(output == null);
    }
}

test "masked multiplication preserves the full first shift and high add when their bounds require them" {
    const changed = try std.mem.replaceOwned(u8, a, sample, "value & 31", "value & 191");
    defer a.free(changed);
    const assembly = try emit(changed);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    and #191\n    pha\n    ldx #0\n    pla\n    sta zeropage_mul_lhs\n    stx zeropage_mul_lhs+1\n" ++
        "    asl\n    pha\n    txa\n    rol\n    tax\n    pla\n    clc\n    adc zeropage_mul_lhs\n    pha\n    txa\n    adc #0\n") != null);
}

test "masked multiplication keeps the high add when decimal correction can set overflow" {
    const changed = try std.mem.replaceOwned(u8, a, sample, "value & 31", "value & 41");
    defer a.free(changed);
    const assembly = try emit(changed);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    and #41\n    pha\n    ldx #0\n    pla\n    sta zeropage_mul_lhs\n    stx zeropage_mul_lhs+1\n" ++
        "    asl\n    clc\n    adc zeropage_mul_lhs\n    pha\n    txa\n    adc #0\n") != null);
}

test "masked multiplication supports managed capture and keeps wider masks and public code unchanged" {
    const managed = "pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scratch } };\n";
    const assembly = try emit(managed ++ sample);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_mul_lhs = address($") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    asl\n    adc zeropage_mul_lhs\n    pha\n    pla\n") != null);

    const public = try std.mem.replaceOwned(u8, a, sample, "fn masked", "export fn masked");
    defer a.free(public);
    const public_assembly = try emit(public);
    defer a.free(public_assembly);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, public_assembly, "    txa\n    and #0\n    tax\n"));

    const wide = try std.mem.replaceOwned(u8, a, sample, "value & 31", "value & 511");
    defer a.free(wide);
    const wide_assembly = try emit(wide);
    defer a.free(wide_assembly);
    try std.testing.expect(std.mem.indexOf(u8, wide_assembly, "    txa\n    and #1\n    tax\n    pla\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide_assembly, "    adc zeropage_mul_lhs+1\n") != null);
}
