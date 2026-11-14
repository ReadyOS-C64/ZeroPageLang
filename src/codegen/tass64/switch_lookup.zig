const std = @import("std");

pub const Interval = struct { first: u16, last: u16, value: u16 };
pub const Kind = enum { constant, interval, lookup };
pub const Plan = struct {
    kind: Kind,
    first: u16 = 0,
    last: u16 = 0,
    value: u16 = 0,
    default: u16,
    selector_word: bool,
    result_word: bool,
    entries: [256]u16 = [_]u16{0} ** 256,
    count: u16 = 0,
    bias: u8 = 0,
    bytes: u32 = 0,
    legacy_bytes: u32,
};

fn guardBytes(plan: Plan) u32 {
    if (plan.first == plan.last) return if (plan.selector_word) 14 else 7;
    if (!plan.selector_word) return @as(u32, if (plan.first > 0) 7 else 0) + @as(u32, if (plan.last < 255) 7 else 0);
    if (plan.first >> 8 == plan.last >> 8) return 7 + @as(u32, if (plan.first & 255 > 0) 7 else 0) + @as(u32, if (plan.last & 255 < 255) 7 else 0);
    return @as(u32, if (plan.first > 0) 16 else 0) + @as(u32, if (plan.last < 65535) 18 else 0);
}

// Select from constant, interval, and lookup representations using complete
// guard/default/table costs. Inputs are already semantically validated.
pub fn choose(intervals: []const Interval, default: u16, selector_word: bool, result_word: bool, legacy_bytes: u32, selector: ?u16) ?Plan {
    return chooseWithLayout(intervals, default, selector_word, result_word, legacy_bytes, selector, true);
}

pub fn chooseWithLayout(intervals: []const Interval, default: u16, selector_word: bool, result_word: bool, legacy_bytes: u32, selector: ?u16, allow_bias: bool) ?Plan {
    var plan: Plan = .{ .kind = .constant, .default = default, .value = default, .selector_word = selector_word, .result_word = result_word, .legacy_bytes = legacy_bytes };
    const value_bytes: u32 = if (result_word) 4 else 2;
    if (selector) |key| {
        for (intervals) |range| if (key >= range.first and key <= range.last) {
            plan.value = range.value;
            break;
        };
        plan.bytes = value_bytes;
        return if (plan.bytes < legacy_bytes) plan else null;
    }
    var first: u32 = 65536;
    var last: u32 = 0;
    var covered: u32 = 0;
    var uniform = true;
    var match_value: ?u16 = null;
    for (intervals) |range| {
        if (range.value == default) continue;
        first = @min(first, range.first);
        last = @max(last, range.last);
        covered += @as(u32, range.last) - range.first + 1;
        if (match_value) |old| {
            if (old != range.value) uniform = false;
        } else match_value = range.value;
    }
    if (match_value == null) {
        plan.bytes = value_bytes;
        return if (plan.bytes < legacy_bytes) plan else null;
    }
    plan.first = @intCast(first);
    plan.last = @intCast(last);
    const span = last - first + 1;
    if (uniform and covered == span) {
        plan.value = match_value.?;
        if (first == 0 and last == (if (selector_word) @as(u32, 65535) else 255)) {
            plan.bytes = value_bytes;
        } else {
            plan.kind = .interval;
            plan.bytes = guardBytes(plan) + 2 * value_bytes + 3;
        }
        return if (plan.bytes < legacy_bytes) plan else null;
    }
    if (span > 256) return null;
    plan.kind = .lookup;
    const compact = allow_bias and first >> 8 == last >> 8;
    plan.count = if (compact) @intCast(span) else if (first >> 8 == last >> 8) @intCast((last & 255) + 1) else 256;
    plan.bias = if (compact) @truncate(first) else 0;
    @memset(&plan.entries, default);
    for (intervals) |range| {
        if (range.value == default) continue;
        for (range.first..@as(u32, range.last) + 1) |key| {
            const index = if (compact) key - first else key & 255;
            plan.entries[index] = range.value;
        }
    }
    plan.bytes = guardBytes(plan) + 1 + @as(u32, if (result_word) 6 else 3) + 3 + value_bytes + @as(u32, plan.count) * (if (result_word) @as(u32, 2) else 1);
    return if (plan.bytes < legacy_bytes) plan else null;
}

pub fn emitValue(writer: anytype, value: u16, word: bool) !void {
    if (word) try writer.print("    ldx #{d}\n", .{value >> 8});
    try writer.print("    lda #{d}\n", .{value & 255});
}

pub fn emitCode(writer: anytype, plan: Plan, id: usize) !void {
    try writer.print("    ; zeropage_switch_result id={d} kind={s} bytes={d} legacy_min_bytes={d}\n", .{ id, @tagName(plan.kind), plan.bytes, plan.legacy_bytes });
    if (plan.kind == .constant) {
        try emitValue(writer, plan.value, plan.result_word);
        try writer.print("switch_expr_{d}_done:\n", .{id});
        return;
    }
    try emitGuards(writer, plan, id);
    if (plan.kind == .lookup) {
        try writer.writeAll("    tay\n");
        if (plan.result_word) try writer.print("    ldx @w zeropage_lookup_{d}_hi-{d},y\n", .{ id, plan.bias });
        try writer.print("    lda @w zeropage_lookup_{d}_lo-{d},y\n", .{ id, plan.bias });
    } else try emitValue(writer, plan.value, plan.result_word);
    try writer.print("    jmp switch_expr_{d}_done\nzeropage_lookup_{d}_default:\n", .{ id, id });
    try emitValue(writer, plan.default, plan.result_word);
    try writer.print("switch_expr_{d}_done:\n", .{id});
}

fn emitGuards(writer: anytype, plan: Plan, id: usize) !void {
    if (plan.first == plan.last) {
        if (plan.selector_word) try writer.print("    cpx #{d}\n    beq zeropage_lookup_{d}_page\n    jmp zeropage_lookup_{d}_default\nzeropage_lookup_{d}_page:\n", .{ plan.first >> 8, id, id, id });
        try writer.print("    cmp #{d}\n    beq zeropage_lookup_{d}_ready\n    jmp zeropage_lookup_{d}_default\nzeropage_lookup_{d}_ready:\n", .{ plan.first & 255, id, id, id });
        return;
    }
    if (plan.selector_word and plan.first >> 8 != plan.last >> 8) {
        if (plan.first > 0) try writer.print("    cpx #{d}\n    bcs zeropage_lookup_{d}_lower_hi\n    jmp zeropage_lookup_{d}_default\nzeropage_lookup_{d}_lower_hi:\n    bne zeropage_lookup_{d}_lower\n    cmp #{d}\n    bcs zeropage_lookup_{d}_lower\n    jmp zeropage_lookup_{d}_default\nzeropage_lookup_{d}_lower:\n", .{ plan.first >> 8, id, id, id, id, plan.first & 255, id, id, id });
        if (plan.last < 65535) try writer.print("    cpx #{d}\n    bcc zeropage_lookup_{d}_ready\n    beq zeropage_lookup_{d}_upper_lo\n    jmp zeropage_lookup_{d}_default\nzeropage_lookup_{d}_upper_lo:\n    cmp #{d}\n    bcc zeropage_lookup_{d}_ready\n    beq zeropage_lookup_{d}_ready\n    jmp zeropage_lookup_{d}_default\nzeropage_lookup_{d}_ready:\n", .{ plan.last >> 8, id, id, id, id, plan.last & 255, id, id, id, id });
        return;
    }
    if (plan.selector_word) try writer.print("    cpx #{d}\n    beq zeropage_lookup_{d}_page\n    jmp zeropage_lookup_{d}_default\nzeropage_lookup_{d}_page:\n", .{ plan.first >> 8, id, id, id });
    const low = plan.first & 255;
    const high = plan.last & 255;
    if (low > 0) try writer.print("    cmp #{d}\n    bcs zeropage_lookup_{d}_lower\n    jmp zeropage_lookup_{d}_default\nzeropage_lookup_{d}_lower:\n", .{ low, id, id, id });
    if (high < 255) try writer.print("    cmp #{d}\n    bcc zeropage_lookup_{d}_ready\n    jmp zeropage_lookup_{d}_default\nzeropage_lookup_{d}_ready:\n", .{ high + 1, id, id, id });
}

pub fn emitData(writer: anytype, plan: Plan, id: usize) !void {
    std.debug.assert(plan.kind == .lookup);
    try writer.print("zeropage_lookup_{d}_lo:\n    .byte ", .{id});
    for (plan.entries[0..plan.count], 0..) |value, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{value & 255});
    }
    try writer.writeByte('\n');
    if (plan.result_word) {
        try writer.print("zeropage_lookup_{d}_hi:\n    .byte ", .{id});
        for (plan.entries[0..plan.count], 0..) |value, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.print("{d}", .{value >> 8});
        }
        try writer.writeByte('\n');
    }
}

test "result plans distinguish constants intervals compact tables and sparse costs" {
    const ranges = [_]Interval{ .{ .first = 10, .last = 12, .value = 3 }, .{ .first = 13, .last = 15, .value = 4 } };
    const table = choose(&ranges, 9, false, false, 100, null).?;
    try std.testing.expectEqual(Kind.lookup, table.kind);
    try std.testing.expectEqual(@as(u16, 6), table.count);
    try std.testing.expectEqual(@as(u8, 10), table.bias);
    try std.testing.expectEqual(@as(u16, 3), table.entries[0]);
    try std.testing.expectEqual(@as(u16, 4), table.entries[5]);
    try std.testing.expect(choose(&ranges, 9, false, false, 10, null) == null);
    try std.testing.expectEqual(Kind.constant, choose(&ranges, 9, false, false, 100, 11).?.kind);
    const same = [_]Interval{ .{ .first = 0, .last = 2, .value = 7 }, .{ .first = 3, .last = 8, .value = 7 } };
    try std.testing.expectEqual(Kind.interval, choose(&same, 0, false, true, 100, null).?.kind);
    try std.testing.expectEqual(Kind.constant, choose(&same, 7, false, true, 100, null).?.kind);
    const sparse = [_]Interval{ .{ .first = 0, .last = 0, .value = 1 }, .{ .first = 255, .last = 255, .value = 2 } };
    try std.testing.expect(choose(&sparse, 0, false, true, 50, null) == null);
}

test "cross page word tables use raw low byte slots and preserve hole defaults" {
    const ranges = [_]Interval{ .{ .first = 250, .last = 255, .value = 0x1234 }, .{ .first = 257, .last = 260, .value = 0x8001 } };
    const plan = choose(&ranges, 77, true, true, 1000, null).?;
    try std.testing.expectEqual(@as(u16, 256), plan.count);
    try std.testing.expectEqual(@as(u8, 0), plan.bias);
    try std.testing.expectEqual(@as(u16, 0x1234), plan.entries[255]);
    try std.testing.expectEqual(@as(u16, 77), plan.entries[0]);
    try std.testing.expectEqual(@as(u16, 0x8001), plan.entries[1]);
}

// Opaque assembly can deliberately enter an old dispatch/case label. In that
// case retain the original switch blocks throughout the program. Walking AST
// payloads structurally also covers asm nested in selector/block expressions.
pub fn referencesDispatch(value: anytype) bool {
    return @import("../../inline_asm.zig").referencesText(value, referencesSwitchLabel);
}

fn referencesSwitchLabel(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "switch_expr_") != null;
}

test "a full 256 value window crossing a page still indexes by raw low byte" {
    const ranges = [_]Interval{ .{ .first = 250, .last = 300, .value = 1 }, .{ .first = 301, .last = 505, .value = 2 } };
    const plan = choose(&ranges, 9, true, false, 1000, null).?;
    try std.testing.expectEqual(@as(u16, 256), plan.count);
    try std.testing.expectEqual(@as(u8, 0), plan.bias);
    try std.testing.expectEqual(@as(u16, 1), plan.entries[250]);
    try std.testing.expectEqual(@as(u16, 1), plan.entries[0]);
    try std.testing.expectEqual(@as(u16, 2), plan.entries[249]);
}

test "nested opaque references pin original switch dispatch blocks" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator,
        \\export fn main() void {
        \\    const value: u8 = blk: {
        \\        asm {
        \\            jmp switch_expr_0_case_0
        \\        }
        \\        break :blk 0;
        \\    };
        \\    _ = value;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(referencesDispatch(parsed.program.functions));
}

test "low images account for unbiassed prefix storage before adopting a table" {
    const values = [_]Interval{ .{ .first = 224, .last = 225, .value = 10 }, .{ .first = 226, .last = 227, .value = 20 } };
    try std.testing.expect(chooseWithLayout(&values, 99, false, false, 100, null, false) == null);
    const plan = chooseWithLayout(&values, 99, false, false, 1000, null, false).?;
    try std.testing.expectEqual(@as(u8, 0), plan.bias);
    try std.testing.expectEqual(@as(u16, 228), plan.count);
    try std.testing.expectEqual(@as(u16, 99), plan.entries[223]);
    try std.testing.expectEqual(@as(u16, 10), plan.entries[224]);
}
