const std = @import("std");
const storage = @import("dead_call_storage.zig");

pub const Stats = struct {
    stores_removed: usize = 0,
    low_stores_removed: usize = 0,
    high_stores_removed: usize = 0,
    bytes_removed: usize = 0,
};
pub const Result = struct { assembly: []u8, stats: Stats };

/// Remove only direct STA/STX/STY into never-read bytes of private captures.
/// Analyze the ORIGINAL complete assembly through the same R26 family/alias/
/// domain/RAM proof used by storage pruning; no counterfactual use deletion.
/// Every producer, formal/source store, read, RMW, call, flag and label remains.
pub fn rewrite(allocator: std.mem.Allocator, assembly: []const u8) !Result {
    var plan = try storage.analyze(allocator, assembly);
    defer plan.deinit(allocator);
    if (!plan.family_safe or plan.cells.len == 0) return .{ .assembly = try allocator.dupe(u8, assembly), .stats = .{} };
    const removed = try allocator.alloc(bool, plan.lines.len);
    defer allocator.free(removed);
    @memset(removed, false);
    var stats: Stats = .{};
    for (plan.cells) |cell| for (cell.stores) |store| {
        if (cell.read_mask & (@as(u2, 1) << store.byte_offset) != 0 or removed[store.line]) continue;
        removed[store.line] = true;
        stats.stores_removed += 1;
        if (store.byte_offset == 0) stats.low_stores_removed += 1 else stats.high_stores_removed += 1;
        // Shared analysis proves resident RAM >= $0200, before ZP allocation.
        // Nominal instruction bytes, not a whole-PRG/after-ZP size claim.
        stats.bytes_removed += 3;
    };
    if (stats.stores_removed == 0) return .{ .assembly = try allocator.dupe(u8, assembly), .stats = stats };
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (plan.lines, removed, 0..) |line, drop, index| {
        if (drop) continue;
        try out.writer.writeAll(line);
        if (index + 1 < plan.lines.len) try out.writer.writeByte('\n');
    }
    return .{ .assembly = try out.toOwnedSlice(), .stats = stats };
}

const begin = "; zeropage_section_begin owner=compiler kind=scratch lifetime=static address=near\n";
const end = "; zeropage_section_end owner=compiler kind=scratch\n";
const word = "zeropage_call_arg_0:\n.word 0\n";
fn fixture(allocator: std.mem.Allocator, body: []const u8, cells: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ "* = $2000\n", body, "\n", begin, cells, end });
}
fn expectKept(body: []const u8, cells: []const u8) !void {
    const input = try fixture(std.testing.allocator, body, cells);
    defer std.testing.allocator.free(input);
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualDeep(Stats{}, result.stats);
    try std.testing.expectEqualStrings(input, result.assembly);
}

test "dead capture writes remove STA STX STY only and compose with unchanged R26 pruning" {
    const body = "probe:\nlda #7\nsta zeropage_call_arg_0\nldx #129\nstx zeropage_call_arg_0+1\nsty zeropage_call_arg_0\nsta formal_parameter\nlda $dc04\njsr callee\nrts\ncallee:\nrts\n";
    const input = try fixture(std.testing.allocator, body, word);
    defer std.testing.allocator.free(input);
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualDeep(Stats{ .stores_removed = 3, .low_stores_removed = 2, .high_stores_removed = 1, .bytes_removed = 9 }, result.stats);
    const expected = try fixture(std.testing.allocator, "probe:\nlda #7\nldx #129\nsta formal_parameter\nlda $dc04\njsr callee\nrts\ncallee:\nrts\n", word);
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result.assembly);
    const pruned = try storage.rewrite(std.testing.allocator, result.assembly);
    defer std.testing.allocator.free(pruned.assembly);
    try std.testing.expectEqualDeep(storage.Stats{ .slots_pruned = 1, .bytes_pruned = 2 }, pruned.stats);
    try std.testing.expect(std.mem.indexOf(u8, pruned.assembly, "zeropage_call_arg_0:") == null);
    try std.testing.expect(std.mem.indexOf(u8, pruned.assembly, begin ++ end) != null);
}

test "dead capture writes use byte precise read masks and preserve RMW" {
    const cases = [_]struct { body: []const u8, mask: u2, low: usize, high: usize }{
        .{ .body = "sta zeropage_call_arg_0\nstx zeropage_call_arg_0+1\nlda zeropage_call_arg_0+1\nrts", .mask = 2, .low = 1, .high = 0 },
        .{ .body = "sta zeropage_call_arg_0\nstx zeropage_call_arg_0+1\nlda zeropage_call_arg_0\nrts", .mask = 1, .low = 0, .high = 1 },
        .{ .body = "sta zeropage_call_arg_0\nstx zeropage_call_arg_0+1\nrol zeropage_call_arg_0+1\nrts", .mask = 2, .low = 1, .high = 0 },
        .{ .body = "sta zeropage_call_arg_0\nstx zeropage_call_arg_0+1\nbit zeropage_call_arg_0\nrts", .mask = 1, .low = 0, .high = 1 },
    };
    for (cases) |case| {
        const input = try fixture(std.testing.allocator, case.body, word);
        defer std.testing.allocator.free(input);
        var plan = try storage.analyze(std.testing.allocator, input);
        defer plan.deinit(std.testing.allocator);
        try std.testing.expect(plan.family_safe);
        try std.testing.expectEqual(@as(usize, 1), plan.cells.len);
        try std.testing.expectEqual(case.mask, plan.cells[0].read_mask);
        try std.testing.expectEqual(@as(usize, 2), plan.cells[0].stores.len);
        const result = try rewrite(std.testing.allocator, input);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqual(case.low, result.stats.low_stores_removed);
        try std.testing.expectEqual(case.high, result.stats.high_stores_removed);
        const pruned = try storage.rewrite(std.testing.allocator, result.assembly);
        defer std.testing.allocator.free(pruned.assembly);
        try std.testing.expectEqualDeep(storage.Stats{}, pruned.stats);
        try std.testing.expect(std.mem.indexOf(u8, result.assembly, "zeropage_call_arg_0:") != null);
    }
}

test "dead capture writes retain all writes to bytes read anywhere including earlier reads" {
    try expectKept("lda zeropage_call_arg_0\nsta zeropage_call_arg_0\nlda zeropage_call_arg_0+1\nstx zeropage_call_arg_0+1\nrts", word);
    for ([_][]const u8{ "lda", "ldx", "ldy", "adc", "sbc", "and", "ora", "eor", "cmp", "cpx", "cpy", "bit", "inc", "dec", "asl", "lsr", "rol", "ror" }) |opcode| {
        const body = try std.fmt.allocPrint(std.testing.allocator, "sta zeropage_call_arg_0\n{s} zeropage_call_arg_0\nrts", .{opcode});
        defer std.testing.allocator.free(body);
        try expectKept(body, word);
    }
}

test "dead capture writes share R26 full family escape and cross cell alias barriers" {
    const cells = word ++ "zeropage_call_arg_1:\n.word 0\n";
    for ([_][]const u8{
        "lda zeropage_call_arg_0+2",   "sta zeropage_call_arg_1-1",   "lda #<zeropage_call_arg_0",
        "lda zeropage_call_arg_0,x",   "lda (zeropage_call_arg_0),y", ".word zeropage_call_arg_0",
        "alias = zeropage_call_arg_0", "unknown zeropage_call_arg_0", "lda zeropage_call_arg_0-1",
    }) |escape| {
        const body = try std.fmt.allocPrint(std.testing.allocator, "sta zeropage_call_arg_1\n{s}\nrts", .{escape});
        defer std.testing.allocator.free(body);
        try expectKept(body, cells);
    }
    try expectKept("sta zeropage_call_arg_0\nlda other_scratch+2\nrts", "other_scratch:\n.word 0\n" ++ word);
    try expectKept("sta zeropage_call_arg_0\nlda #<other_scratch\nrts", "other_scratch:\n.word 0\n" ++ word);
    try expectKept("sta zeropage_call_arg_0\nlda other_scratch,x\nrts", "other_scratch:\n.word 0\n" ++ word);
}

test "dead capture writes preserve aliases duplicates layout unknowns and global ASM" {
    for ([_][]const u8{
        "alias:\n" ++ word,                        "zeropage_call_arg_0:\nalias:\n.word 0\n", word ++ word,
        word ++ "ZEROPAGE_CALL_ARG_0:\n.word 0\n", "zeropage_call_arg_0:\n.word 1\n",         "zeropage_call_arg_0:\n.byte 0,0\n",
        word ++ ".unknown 0\n",
    }) |cells| try expectKept("sta zeropage_call_arg_0\nrts", cells);
    try expectKept("sta zeropage_call_arg_0\n; inline asm from ZeroPage line 1\nnop\n; end inline asm\nrts", word);
}

test "dead capture writes retain other storage ownership and remapped domains" {
    const input = try fixture(std.testing.allocator, "sta zeropage_call_arg_0\nrts", word);
    defer std.testing.allocator.free(input);
    for ([_][]const u8{ "owner=function:public kind=static_frame", "owner=compiler kind=data", "owner=module:public kind=rodata" }) |owner| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, input, "owner=compiler kind=scratch", owner);
        defer std.testing.allocator.free(changed);
        const result = try rewrite(std.testing.allocator, changed);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqualStrings(changed, result.assembly);
        try std.testing.expectEqualDeep(Stats{}, result.stats);
    }
    for ([_][]const u8{ "* = $2000\nnop\n", ".logical $2000\nnop\n.here\n" }) |remap| {
        const changed = try std.mem.concat(std.testing.allocator, u8, &.{ input, remap });
        defer std.testing.allocator.free(changed);
        const result = try rewrite(std.testing.allocator, changed);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqualStrings(changed, result.assembly);
        try std.testing.expectEqualDeep(Stats{}, result.stats);
    }
}

test "dead capture writes preserve case folded reads and ignore only unread byte stores" {
    const input = try fixture(std.testing.allocator, "sta ZEROPAGE_CALL_ARG_0\nstx ZeroPage_Call_Arg_0+1\nlda zeropage_call_arg_0+1\nrts", word);
    defer std.testing.allocator.free(input);
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqual(@as(usize, 1), result.stats.stores_removed);
    try std.testing.expectEqual(@as(usize, 1), result.stats.low_stores_removed);
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "sta ZEROPAGE_CALL_ARG_0") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "stx ZeroPage_Call_Arg_0+1") != null);
}

test "dead capture writes preserve complete producers and are idempotent" {
    const input = try fixture(std.testing.allocator, "lda $dc04\nsta zeropage_call_arg_0\njsr effect\nstx zeropage_call_arg_0+1\nphp\npla\nrts\neffect:\nrts", word);
    defer std.testing.allocator.free(input);
    const first = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(first.assembly);
    try std.testing.expectEqual(@as(usize, 2), first.stats.stores_removed);
    try std.testing.expect(std.mem.indexOf(u8, first.assembly, "lda $dc04\njsr effect\nphp\npla\nrts\neffect:\nrts") != null);
    const second = try rewrite(std.testing.allocator, first.assembly);
    defer std.testing.allocator.free(second.assembly);
    try std.testing.expectEqualDeep(Stats{}, second.stats);
    try std.testing.expectEqualStrings(first.assembly, second.assembly);
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    const input = try fixture(allocator, "sta zeropage_call_arg_0\nstx zeropage_call_arg_0+1\nlda zeropage_call_arg_0+1\nsty zeropage_call_arg_1\nrts", word ++ "zeropage_call_arg_1:\n.word 0\n");
    defer allocator.free(input);
    const result = rewrite(allocator, input) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer allocator.free(result.assembly);
}
test "dead capture writes free shared plan nested stores and output on all allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}
