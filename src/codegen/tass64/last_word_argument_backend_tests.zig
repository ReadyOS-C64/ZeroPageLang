// R25 regression tests for final-word capture and single-argument proof markers.
const std = @import("std");
const parser = @import("../../parser.zig");
const emitter = @import("emitter.zig");
const rewrite = @import("call_argument_rewrite.zig");
const pipeline = @import("pipeline.zig");
const allocator = std.testing.allocator;

fn expectInOrder(assembly: []const u8, needles: []const []const u8) !void {
    var offset: usize = 0;
    for (needles) |needle| {
        const found = std.mem.indexOfPos(u8, assembly, offset, needle) orelse return error.ExpectedInstructionSequence;
        offset = found + needle.len;
    }
}

fn directWord(source: []const u8, target: []const u8, temporary: []const u8) ![]u8 {
    const parsed = try parser.parseSource(allocator, source);
    defer parsed.deinit(allocator);
    const before = try emitter.emitProgram(allocator, parsed.program);
    defer allocator.free(before);
    const after = try rewrite.rewrite(allocator, parsed.program, before);
    errdefer allocator.free(after);
    const capture = try std.fmt.allocPrint(allocator, "    sta {s}\n    stx {s}+1\n", .{ temporary, temporary });
    defer allocator.free(capture);
    const old_copy = try std.fmt.allocPrint(allocator, "    lda {s}\n    sta {s}\n    lda {s}+1\n    sta {s}+1\n", .{ temporary, target, temporary, target });
    defer allocator.free(old_copy);
    const early_store = try std.fmt.allocPrint(allocator, "    sta {s}\n    stx {s}+1\n", .{ target, target });
    defer allocator.free(early_store);
    const final_reload = try std.fmt.allocPrint(allocator, "    lda {s}+1\n    jsr leaf\n", .{target});
    defer allocator.free(final_reload);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, before, capture));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, before, old_copy));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, after, capture));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, after, old_copy));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, after, early_store));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, after, final_reload));
    // Old code stores the high byte with STA during the copy phase. Its
    // replacement must really move that write to STX at evaluation time.
    const old_high_store = try std.fmt.allocPrint(allocator, "    sta {s}+1\n", .{target});
    defer allocator.free(old_high_store);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, after, old_high_store));
    const old_high_load = try std.fmt.allocPrint(allocator, "    lda {s}+1\n", .{temporary});
    defer allocator.free(old_high_load);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, after, old_high_load));

    // The pure argument pass above establishes the final high-byte reload.
    // The real pipeline forwards the same high byte from X, preserving A/NZ.
    const optimized = try pipeline.emitBeforeSingleCallLeaf(allocator, parsed.program);
    defer allocator.free(optimized);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, optimized, early_store));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, optimized, "    txa\n    jsr leaf\n"));
    try std.testing.expect(std.mem.indexOf(u8, optimized, capture) == null);
    return after;
}

test "last word argument backend directly captures single u16 i16 usize and pointer values" {
    const cases = [_][2][]const u8{
        .{ "u16", "0x8134" },
        .{ "i16", "0x8134" },
        .{ "usize", "0x81ff" },
        .{ "*u8", "@ptrFromInt(0xc1ff)" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator, "fn leaf(value: {s}) {s} {{ return value; }} export fn main() void {{ _ = leaf({s}); }}", .{ case[0], case[0], case[1] });
        defer allocator.free(source);
        const after = try directWord(source, "leaf_value", "zeropage_call_arg_0");
        defer allocator.free(after);
    }
}

test "last word argument backend reload stays after retained earlier copies" {
    const after = try directWord(
        \\fn first() u8 { return 0x42; }
        \\fn leaf(first_value: u8, last: u16) u16 { return last ^ first_value; }
        \\export fn main() void {
        \\    const location: *u16 = @ptrFromInt(0xc1ff);
        \\    _ = leaf(first(), location.*);
        \\}
    , "leaf_last", "zeropage_call_arg_1");
    defer allocator.free(after);
    // The indirect final expression keeps the first byte on its original
    // staging path, while its own final word can still be captured directly.
    try expectInOrder(after, &.{
        "jsr first\n",
        "sta zeropage_call_arg_0\n",
        "lda (zeropage_ptr_tmp),y\n",
        "sta leaf_last\n    stx leaf_last+1\n",
        "lda zeropage_call_arg_0\n    sta leaf_first_value\n",
        "lda leaf_last+1\n    jsr leaf\n",
    });
}

test "last word argument backend permits earlier nested expression and enum byte formal" {
    const after = try directWord(
        \\const Mode = enum(u8) { idle, active };
        \\fn first() Mode { return .active; }
        \\fn leaf(mode: Mode, last: u16) u16 { if (mode == .active) { return last; } return 0; }
        \\export fn main() void { _ = leaf(first(), 0x8134); }
    , "leaf_last", "zeropage_call_arg_1");
    defer allocator.free(after);
    try expectInOrder(after, &.{ "jsr first\n", "sta leaf_mode\n", "sta leaf_last\n    stx leaf_last+1\n", "lda leaf_last+1\n    jsr leaf\n" });
}

fn expectUnchanged(source: []const u8) !void {
    const parsed = try parser.parseSource(allocator, source);
    defer parsed.deinit(allocator);
    const before = try emitter.emitProgram(allocator, parsed.program);
    defer allocator.free(before);
    const after = try rewrite.rewrite(allocator, parsed.program, before);
    defer allocator.free(after);
    var expected: std.Io.Writer.Allocating = .init(allocator);
    defer expected.deinit();
    var lines = std.mem.splitScalar(u8, before, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "; zeropage_scalar_call_")) continue;
        try expected.writer.writeAll(line);
        if (lines.index != null) try expected.writer.writeByte('\n');
    }
    try std.testing.expectEqualStrings(expected.written(), after);
}

test "last word argument backend leaves a single byte final argument staged" {
    try expectUnchanged("fn leaf(value: u8) u8 { return value; } export fn main() void { _ = leaf(0x81); }");
}

test "last word argument backend retains last byte copy after a directly captured earlier word" {
    const parsed = try parser.parseSource(allocator, "fn leaf(value: u16, last: u8) u16 { return value; } export fn main() void { _ = leaf(0x8134, 0x42); }");
    defer parsed.deinit(allocator);
    const before = try emitter.emitProgram(allocator, parsed.program);
    defer allocator.free(before);
    const after = try rewrite.rewrite(allocator, parsed.program, before);
    defer allocator.free(after);
    try expectInOrder(after, &.{ "sta leaf_value\n    stx leaf_value+1\n", "sta zeropage_call_arg_1\n", "lda zeropage_call_arg_1\n    sta leaf_last\n", "jsr leaf\n" });
    try std.testing.expect(std.mem.indexOf(u8, after, "lda leaf_last\n    jsr leaf") == null);
}

test "last word argument backend public escaped and recursive cells keep their old copies" {
    try expectUnchanged("export fn leaf(value: u16) u16 { return value; } export fn main() void { _ = leaf(0x8134); }");
    try expectUnchanged("fn leaf(value: u16) u16 { const address: *u16 = &value; return address.*; } export fn main() void { _ = leaf(0x8134); }");
    try expectUnchanged("fn leaf(value: u16) u16 { if (value == 0) { return 0; } return leaf(0); } export fn main() void { _ = leaf(0x8134); }");
}

test "last word argument backend ROM under RAM destination cannot use the new read" {
    try expectUnchanged("pub const zeropage_options = .{ .image = .{ .basic_stub = false, .load_addr = 0xa000, .entry_addr = 0xa000 } }; fn leaf(value: u16) u16 { return value; } export fn main() void { _ = leaf(0x8134); }");
}

test "last word argument backend software stack caller and callee keep their old bridges" {
    try expectUnchanged(
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{ .leaf = .{ .frame = .stack } } },
        \\};
        \\fn leaf(value: u16) u16 { return value; }
        \\export fn main() void { _ = leaf(0x8134); }
    );
    try expectUnchanged(
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{ .main = .{ .frame = .stack } } },
        \\};
        \\fn leaf(value: u16) u16 { return value; }
        \\export fn main() void { _ = leaf(0x8134); }
    );
}

test "last word argument backend module placement and source ASM keep old paths" {
    try expectUnchanged(
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{ .leaf = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{ .id = "last_word_guard", .abi = 1, .exports = .{ .leaf = leaf }, .deps = .{} };
        \\fn leaf(value: u16) u16 { return value; }
        \\export fn main() void { _ = leaf(0x8134); }
    );
    try expectUnchanged(
        \\pub const zeropage_options = .{ .memory = .{
        \\    .regions = .{ .fixed = .{ .addr = 0x2000, .size = 0x0100 } },
        \\    .placements = .{ .fixed = .{ .region = .fixed, .load = .direct, .functions = .{ main } } },
        \\} };
        \\fn leaf(value: u16) u16 { return value; }
        \\export fn main() void { _ = leaf(0x8134); }
    );
    try expectUnchanged(
        \\fn leaf(value: u16) u16 { return value; }
        \\export fn main() void {
        \\    _ = leaf(0x8134);
        \\    asm {
        \\        nop
        \\    }
        \\}
    );
}
