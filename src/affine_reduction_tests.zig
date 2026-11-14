const std = @import("std");
const parser = @import("parser.zig");
const pipeline = @import("codegen/tass64/pipeline.zig");

const a = std.testing.allocator;
const sample =
    \\fn sum(count: u8, seed: u16) u16 {
    \\    var index: u16 = 0;
    \\    var total: u16 = seed;
    \\    while (index < count) { total += index * 3 + 7; index += 1; }
    \\    return total;
    \\}
    \\export fn main() void {
    \\    const count: *volatile u8 = @ptrFromInt(0xc100);
    \\    const seed: *volatile u16 = @ptrFromInt(0xc102);
    \\    const out: *volatile u16 = @ptrFromInt(0xc110);
    \\    out.* = sum(count.*, seed.*);
    \\}
;

fn emit(source: []const u8) ![]u8 {
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    return pipeline.emitProgram(a, parsed.program);
}

test "affine reduction keeps the zero trip and reconstructs the original exit" {
    const assembly = try emit(sample);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "while_0_top:\n    ldx sum_count\n    txa\n    sec\n    beq while_0_done\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    ldy sum_index\n    lda sum_count\n    sta sum_index\n    stx sum_index+1\n    cpx #0\n    clv\nwhile_0_done:\n") != null);
}

test "affine reduction recognizes signed digit multiplication and a wide bias" {
    const source = try std.mem.replaceOwned(u8, a, sample, "index * 3 + 7", "index * 7 + 509");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    sty sum_index\n    ldy #$fd\n    lda #$01\n    sta sum_index+1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    tya\n    clc\n    adc #$07\n    tay\n") != null);
}

test "affine reduction preserves overflow for the INC backedge" {
    const source = try std.mem.replaceOwned(u8, a, sample, "    return total;", "    total += 1;\n    return total;");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_word_increment_0:\nzeropage_affine_reduce_while_0_top:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    stx sum_index+1\n    cpx #0\nwhile_0_done:\n") != null);
}

test "affine reduction keeps its fallback for side effects, wide counts and unproved memory" {
    for ([_][2][]const u8{
        .{ "index += 1;", "index += 1; if (index == 10) { break; }" },
        .{ "count: u8, seed", "count: u16, seed" },
        .{ "0xc110", "0xd020" },
        .{ "var index: u16 = 0", "var index: u16 = 1" },
    }) |edit| {
        const source = try std.mem.replaceOwned(u8, a, sample, edit[0], edit[1]);
        defer a.free(source);
        const assembly = try emit(source);
        defer a.free(assembly);
        try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_affine_reduce_") == null);
    }
}

const grouped =
    \\fn sum(count: u8, seed: u16) u16 {
    \\    var index: u16 = 0;
    \\    var total: u16 = seed;
    \\    while (index + 3 <= count) {
    \\        total += index * 3 + 7;
    \\        total += (index + 1) * 3 + 7;
    \\        total += (index + 2) * 3 + 7;
    \\        index += 3;
    \\    }
    \\    while (index < count) { total += index * 3 + 7; index += 1; }
    \\    return total;
    \\}
    \\export fn main() void {
    \\    const count: *volatile u8 = @ptrFromInt(0xc100);
    \\    const seed: *volatile u16 = @ptrFromInt(0xc102);
    \\    const out: *volatile u16 = @ptrFromInt(0xc110);
    \\    out.* = sum(count.*, seed.*);
    \\}
;

test "grouped affine reduction sums three terms and replays the failed header" {
    const assembly = try emit(grouped);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    cpx #3\n    bcs zeropage_affine_group_init_while_0_top\n" ++
        "    lda #3\n    clv\n    cmp sum_count\n    jmp while_0_done\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_affine_group_init_while_0_top:\n    sty sum_index\n    ldy #30\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    tya\n    clc\n    adc #27\n    tay\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_affine_group_exit_while_0_top:\n    ldy sum_index\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    ldy sum_index\n    txa\n    eor #$ff\n" ++
        "    adc sum_count\n    sta zeropage_mul_lhs\n    adc #0\n    sta sum_index\n" ++
        "    ldx #0\n    stx zeropage_mul_lhs+1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    cmp sum_count\nzeropage_affine_group_compared_while_0_top:\nwhile_0_done:\nwhile_1_top:\n") != null);
}

test "grouped affine reduction keeps unequal terms and partial groups on the fallback" {
    for ([_][2][]const u8{
        .{ "(index + 2) * 3", "(index + 1) * 3" },
        .{ "(index + 1) * 3 + 7", "(index + 1) * 3 + 8" },
        .{ "index += 3;", "index += 2;" },
        .{ "index + 3 <= count", "index + 2 <= count" },
    }) |edit| {
        const source = try std.mem.replaceOwned(u8, a, grouped, edit[0], edit[1]);
        defer a.free(source);
        const assembly = try emit(source);
        defer a.free(assembly);
        try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_affine_group_") == null);
    }
}

test "grouped affine reduction restores a managed multiply capture" {
    const options = "pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scratch } };\n";
    const assembly = try emit(options ++ grouped);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_mul_lhs = address($") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_affine_group_exit_while_0_top:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    ldy sum_index\n    txa\n    eor #$ff\n" ++
        "    adc sum_count\n    sta zeropage_mul_lhs\n    adc #0\n    sta sum_index\n" ++
        "    ldx #0\n    stx zeropage_mul_lhs+1\n") != null);
}

test "grouped affine reduction handles powers of two without a capture" {
    const source = try std.mem.replaceOwned(u8, a, grouped, "* 3 + 7", "* 256 + 65535");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_affine_group_exit_while_0_top:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    adc #9\n    sta sum_index+1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    txa\n    eor #$ff\n    sec\n    adc sum_count\n    sta sum_index\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_mul_lhs") == null);
}

test "affine reduction carries a zero initial low byte in Y when the low term changes" {
    const source = try std.mem.replaceOwned(u8, a, sample, "index * 3 + 7", "index * 3 + 256");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    beq while_0_done\n    sty sum_index\n    ldy #$00\n    lda #$01\n") != null);
}

test "affine reduction keeps the compact memory kernel when the low term is invariant" {
    const source = try std.mem.replaceOwned(u8, a, sample, "index * 3 + 7", "index * 256 + 7");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    beq while_0_done\n    lda #$07\n    sta sum_index\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "while_0_body:\n    clc\n    lda sum_index\n") != null);
}
