const std = @import("std");
const parser = @import("parser.zig");
const pipeline = @import("codegen/tass64/pipeline.zig");

const a = std.testing.allocator;
const sample =
    \\fn leaf(value: u16) u16 { return (value & 31) * 3 + (value & 63) * 7; }
    \\export fn main() void {
    \\    const input: *volatile u16 = @ptrFromInt(0xc100);
    \\    const output: *volatile u16 = @ptrFromInt(0xc110);
    \\    var word: u16 = input.*;
    \\    output.* = leaf(word);
    \\}
;

fn emit(source: []const u8) ![]u8 {
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    return pipeline.emitBeforeSingleCallLeaf(a, parsed.program);
}

test "private leaf coalescing reads the caller word and retains the actual call" {
    const assembly = try emit(sample);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "leaf:\n    lda main_word\n    and #31\n") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, "    lda main_word\n    and #"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "    jsr leaf\n"));
    try std.testing.expect(std.mem.indexOf(u8, assembly, "leaf_value") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    sta main_word\n    stx main_word+1\n    jsr leaf\n") != null);
}

test "private leaf coalescing keeps parameter storage for two sites and public or computed calls" {
    for ([_][2][]const u8{
        .{ "output.* = leaf(word);", "output.* = leaf(word); output.* = leaf(word);" },
        .{ "fn leaf(", "export fn leaf(" },
        .{ "output.* = leaf(word);", "output.* = leaf(word + 1);" },
        .{ "return (value", "var unrelated: u8 = 0; unrelated += 1; return (value" },
    }) |edit| {
        const source = try std.mem.replaceOwned(u8, a, sample, edit[0], edit[1]);
        defer a.free(source);
        const assembly = try emit(source);
        defer a.free(assembly);
        try std.testing.expect(std.mem.indexOf(u8, assembly, "leaf_value:\n    .word 0\n") != null);
    }
}

test "private leaf coalescing handles managed scratch and preserves scalar claims" {
    const scratch = "pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scratch } };\n";
    const scalars = "pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scalars } };\n";
    const managed = try emit(scratch ++ sample);
    defer a.free(managed);
    try std.testing.expect(std.mem.indexOf(u8, managed, "zeropage_math_tmp = address($") != null);
    try std.testing.expect(std.mem.indexOf(u8, managed, "leaf_value") == null);
    const claimed = try emit(scalars ++ sample);
    defer a.free(claimed);
    try std.testing.expect(std.mem.indexOf(u8, claimed, "leaf_value = address($") != null);
}

test "private leaf coalescing counts only retained callers" {
    const assembly = try emit("fn unused(other: u16) u16 { return leaf(other); }\n" ++ sample);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "leaf_value") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "    jsr leaf\n"));
}
