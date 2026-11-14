const std = @import("std");
const parser = @import("parser.zig");
const pipeline = @import("codegen/tass64/pipeline.zig");

const a = std.testing.allocator;
const sample =
    \\fn mask(word: u16) u16 { return word & 63; }
    \\fn setLow(word: u16) u16 { return word | 0x42; }
    \\fn setHigh(word: u16) u16 { return word | 0xff00; }
    \\fn both(cell: u8, mark: u8) bool { return cell != 0 and cell != mark; }
    \\export fn main() void {
    \\    var word: u16 = 0x8129;
    \\    var cell: u8 = 6;
    \\    const mark: u8 = 8;
    \\    word = mask(word);
    \\    word = setLow(word);
    \\    word = setHigh(word);
    \\    if (both(cell, mark)) { cell += 1; }
    \\}
;

fn emit(source: []const u8) ![]u8 {
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    return pipeline.emitBeforeSingleCallLeaf(a, parsed.program);
}

test "local folds retain the stack operations and avoid redundant high-byte transfers" {
    const assembly = try emit(sample);
    defer a.free(assembly);
    for ([_][]const u8{
        "    and #63\n    pha\n    ldx #0\n    pla\n    rts\n",
        "    ora #66\n    pha\n    pla\n    rts\n",
        "    pha\n    ldx #255\n    pla\n    rts\n",
    }) |sequence| try std.testing.expect(std.mem.indexOf(u8, assembly, sequence) != null);
}

test "local folds share carry and branch directly to the false boolean return" {
    const assembly = try emit(sample);
    defer a.free(assembly);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, "    beq bool_and_0_false\n"));
    try std.testing.expect(std.mem.indexOf(u8, assembly, "bool_and_0_false:\n    lda #0\nbool_and_0_done:\n    sec\n    rts\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "cmp_1_false:\ncmp_1_true:\ncmp_1_done:\n") != null);
}

test "local folds keep public exports and observed fixed addresses on the original path" {
    const changed = try std.mem.replaceOwned(u8, a, sample, "fn mask", "export fn mask");
    defer a.free(changed);
    const public_assembly = try emit(changed);
    defer a.free(public_assembly);
    try std.testing.expect(std.mem.indexOf(u8, public_assembly, "    pha\n    txa\n    and #0\n    tax\n    pla\n") != null);

    const observed = try std.mem.replaceOwned(u8, a, sample, "var word: u16 = 0x8129;", "const p: *volatile u16 = @ptrFromInt(0x080d); var word: u16 = p.*;");
    defer a.free(observed);
    const observed_assembly = try emit(observed);
    defer a.free(observed_assembly);
    try std.testing.expect(std.mem.indexOf(u8, observed_assembly, "    pha\n    txa\n    and #0\n    tax\n    pla\n") != null);
}
