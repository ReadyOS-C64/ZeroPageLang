const std = @import("std");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");
const selection = @import("stride_selection.zig");

pub const Stats = struct {
    matched_sites: usize = 0,
    replacements: usize = 0,
    selected_factors: usize = 0,
    legacy_min_bytes: u64 = 0,
    selected_max_bytes: u64 = 0,
    pinned_assembly: bool = false,
};
pub const Result = struct {
    assembly: []u8,
    usage: selection.Usage = .{},
    generic_needed: bool,
    stats: Stats = .{},

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.assembly);
    }
};

const Match = struct { line: usize, factor: u16 };
const Group = struct { count: u32 = 0, plan: ?selection.Plan = null, selected: bool = false };

// Borrow assembly before runtime/helper emission, return owned text. The parent
// excludes module/DLL emission and passes keep_generic for prepared placements
// not represented here. No compiler flags, source counters or AST mutation.
pub fn rewrite(allocator: std.mem.Allocator, assembly: []const u8, keep_generic: bool) !Result {
    var result: Result = .{ .assembly = undefined, .generic_needed = keep_generic };
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var offset: usize = 0;
    while (offset < assembly.len) {
        const end = if (std.mem.indexOfScalarPos(u8, assembly, offset, '\n')) |newline| newline + 1 else assembly.len;
        try lines.append(allocator, assembly[offset..end]);
        offset = end;
    }
    var matches: std.ArrayList(Match) = .empty;
    defer matches.deinit(allocator);
    var groups: std.AutoHashMap(u16, Group) = .init(allocator);
    defer groups.deinit();
    var active = false;
    var in_assembly = false;
    for (lines.items, 0..) |raw, index| {
        const line = trim(raw);
        if (std.mem.startsWith(u8, line, "; inline asm from ZeroPage line ")) in_assembly = true;
        if (in_assembly) {
            // Even an explicit private-scratch read can observe the old helper's
            // scratch contents, so preserve all original multiply sequences.
            if (std.mem.indexOf(u8, line, "zeropage_mul") != null) result.stats.pinned_assembly = true;
            if (std.mem.eql(u8, line, "; end inline asm")) in_assembly = false;
            continue;
        }
        if (storage.sectionOwner(line, "code") != null) {
            active = true;
            continue;
        } else if (std.mem.startsWith(u8, line, "; zeropage_section_")) {
            active = false;
            continue;
        }
        if (!active) continue;
        if (matchFactor(lines.items[index..])) |factor| {
            try matches.append(allocator, .{ .line = index, .factor = factor });
            const group = try groups.getOrPut(factor);
            if (!group.found_existing) group.value_ptr.* = .{};
            group.value_ptr.count += 1;
        }
    }
    result.stats.matched_sites = matches.items.len;
    const generic_references = std.mem.count(u8, assembly, "zeropage_mul16");
    const external_generic = keep_generic or generic_references != matches.items.len;
    if (result.stats.pinned_assembly or matches.items.len == 0) {
        result.generic_needed = keep_generic or generic_references != 0 or result.stats.pinned_assembly;
        result.assembly = try allocator.dupe(u8, assembly);
        return result;
    }

    // First select independently profitable groups with no shared-helper credit.
    // Then consider ALL groups together: the generic helper's minimum 39-byte
    // removal can make the complete portfolio profitable, but is credited once.
    var all_supported = true;
    var all_old: u64 = 0;
    var all_new: u64 = 0;
    var iterator = groups.valueIterator();
    var keys = groups.iterator();
    while (keys.next()) |entry| {
        var label_buffer: [64]u8 = undefined;
        const helper = try std.fmt.bufPrint(&label_buffer, "zeropage_stride_mul_{d}", .{entry.key_ptr.*});
        // Do not create a helper that changes an existing source label/reference
        // into a duplicate definition or turns a previously unknown label valid.
        entry.value_ptr.plan = if (std.mem.indexOf(u8, assembly, helper) == null)
            selection.estimate(entry.key_ptr.*, entry.value_ptr.count, true, .conservative)
        else
            null;
        if (entry.value_ptr.plan) |plan| {
            entry.value_ptr.selected = plan.selected_bytes < plan.legacy_bytes;
            all_old += plan.legacy_bytes;
            all_new += plan.selected_bytes;
        } else all_supported = false;
    }
    if (!external_generic and all_supported and all_new < all_old + 39) {
        while (iterator.next()) |group| group.selected = true;
    }
    keys = groups.iterator();
    while (keys.next()) |entry| {
        if (entry.value_ptr.selected) {
            result.stats.selected_factors += 1;
            result.stats.replacements += entry.value_ptr.count;
            result.stats.legacy_min_bytes += entry.value_ptr.plan.?.legacy_bytes;
            result.stats.selected_max_bytes += entry.value_ptr.plan.?.selected_bytes;
        }
    }
    if (result.stats.replacements == 0) {
        result.generic_needed = keep_generic or generic_references != 0;
        result.assembly = try allocator.dupe(u8, assembly);
        return result;
    }
    result.generic_needed = external_generic or result.stats.replacements != matches.items.len;
    if (!result.generic_needed) result.stats.legacy_min_bytes += 39;
    std.debug.assert(result.stats.selected_max_bytes < result.stats.legacy_min_bytes);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var index: usize = 0;
    var match_index: usize = 0;
    while (index < lines.items.len) {
        if (match_index < matches.items.len and matches.items[match_index].line == index) {
            const found = matches.items[match_index];
            match_index += 1;
            const group = groups.get(found.factor).?;
            if (group.selected) {
                try result.usage.emitCall(&out.writer, group.plan.?);
                index += 7;
                continue;
            }
        }
        try out.writer.writeAll(lines.items[index]);
        index += 1;
    }
    if (assembly.len != 0 and assembly[assembly.len - 1] != '\n') try out.writer.writeByte('\n');
    try out.writer.print("; zeropage_stride_selection sites={d} factors={d} legacy_min_bytes={d} selected_max_bytes={d}\n", .{ result.stats.replacements, result.stats.selected_factors, result.stats.legacy_min_bytes, result.stats.selected_max_bytes });
    result.assembly = try out.toOwnedSlice();
    return result;
}

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r\n");
}
fn direct(inst: machine.Instruction, op: machine.Op, name: []const u8, offset: i32) bool {
    return inst.op == op and inst.operand == .direct and inst.operand.direct.offset == offset and std.mem.eql(u8, inst.operand.direct.name, name);
}
fn immediate(inst: machine.Instruction, op: machine.Op) ?u8 {
    if (inst.op != op or inst.operand != .immediate) return null;
    const value = machine.integer(inst.operand.immediate) orelse return null;
    return std.math.cast(u8, value);
}
fn matchFactor(lines: []const []const u8) ?u16 {
    if (lines.len < 7) return null;
    var instructions: [7]machine.Instruction = undefined;
    for (&instructions, lines[0..7]) |*inst, raw| inst.* = machine.Instruction.parse(trim(raw)) orelse return null;
    if (!direct(instructions[0], .sta, "zeropage_mul_lhs", 0) or !direct(instructions[1], .stx, "zeropage_mul_lhs", 1)) return null;
    const lo = immediate(instructions[2], .lda) orelse return null;
    const hi = immediate(instructions[3], .ldx) orelse return null;
    if (!direct(instructions[4], .sta, "zeropage_mul_rhs", 0) or !direct(instructions[5], .stx, "zeropage_mul_rhs", 1) or !direct(instructions[6], .jsr, "zeropage_mul16", 0)) return null;
    return @as(u16, lo) | (@as(u16, hi) << 8);
}

fn setup(writer: anytype, factor: u16) !void {
    try writer.print("    sta zeropage_mul_lhs\n    stx zeropage_mul_lhs+1\n    lda #{d}\n    ldx #{d}\n    sta zeropage_mul_rhs\n    stx zeropage_mul_rhs+1\n    jsr zeropage_mul16\n", .{ factor & 255, factor >> 8 });
}
fn testInput(allocator: std.mem.Allocator, factors: []const u16, suffix: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("; zeropage_section_begin owner=function:f kind=code lifetime=static address=near\nf:\n");
    for (factors) |factor| try setup(&out.writer, factor);
    try out.writer.writeAll("    rts\n; zeropage_section_end owner=function:f kind=code\n");
    try out.writer.writeAll(suffix);
    return try out.toOwnedSlice();
}

test "stride rewrite leaves zero nonmatching and unprofitable inputs byte exact" {
    for ([_][]const u8{ "", "lda #9\njsr zeropage_mul16", "; inline asm from ZeroPage line 1\nnop\n; end inline asm\n" }) |input| {
        var result = try rewrite(std.testing.allocator, input, false);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(input, result.assembly);
        try std.testing.expectEqual(@as(usize, 0), result.stats.replacements);
    }
    const input = try testInput(std.testing.allocator, &.{9}, "");
    defer std.testing.allocator.free(input);
    var result = try rewrite(std.testing.allocator, input, false);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(input, result.assembly);
    try std.testing.expect(result.generic_needed);
}

test "profitable repeated nine byte strides share one body and prune generic dependency" {
    const input = try testInput(std.testing.allocator, &.{ 9, 9, 9, 9, 9, 9, 9, 9 }, "");
    defer std.testing.allocator.free(input);
    var result = try rewrite(std.testing.allocator, input, false);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8), result.stats.matched_sites);
    try std.testing.expectEqual(@as(usize, 8), result.stats.replacements);
    try std.testing.expectEqual(@as(usize, 1), result.stats.selected_factors);
    try std.testing.expect(!result.generic_needed);
    try std.testing.expectEqual(@as(u64, 159), result.stats.legacy_min_bytes);
    try std.testing.expectEqual(@as(u64, 95), result.stats.selected_max_bytes);
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, result.assembly, "jsr zeropage_stride_mul_9"));
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "zeropage_mul16") == null);
    try std.testing.expectEqual(@as(u64, 8), result.usage.call_sites);
}

test "unmatched generic calls and prepared placements keep the shared helper alive" {
    for ([_]bool{ false, true }) |placement| {
        const input = try testInput(std.testing.allocator, &.{ 9, 9, 9, 9, 9, 9 }, if (placement) "" else "jsr zeropage_mul16\n");
        defer std.testing.allocator.free(input);
        var result = try rewrite(std.testing.allocator, input, placement);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 6), result.stats.replacements);
        try std.testing.expect(result.generic_needed);
        try std.testing.expectEqual(@as(u64, 90), result.stats.legacy_min_bytes);
        try std.testing.expectEqual(@as(u64, 89), result.stats.selected_max_bytes);
    }
}

test "opaque multiply scratch references pin original sequences and ordinary asm stays opaque" {
    const pinned = try testInput(std.testing.allocator, &.{ 9, 9, 9, 9, 9, 9 }, "; inline asm from ZeroPage line 1\n    lda zeropage_mul_rhs\n; end inline asm\n");
    defer std.testing.allocator.free(pinned);
    var preserved = try rewrite(std.testing.allocator, pinned, false);
    defer preserved.deinit(std.testing.allocator);
    try std.testing.expect(preserved.stats.pinned_assembly and preserved.generic_needed);
    try std.testing.expectEqualStrings(pinned, preserved.assembly);
    const input = try testInput(std.testing.allocator, &.{ 9, 9, 9, 9, 9, 9 }, "; inline asm from ZeroPage line 1\n    sed\n; end inline asm\n");
    defer std.testing.allocator.free(input);
    var result = try rewrite(std.testing.allocator, input, false);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), result.stats.replacements);
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "    sed\n") != null);
}

test "helper elimination credit is global and never counted once per factor" {
    // Neither single body is worthwhile even with a separate (incorrect) generic
    // credit here; larger combinations likewise must not duplicate that credit.
    const input = try testInput(std.testing.allocator, &.{ 3, 5, 9 }, "");
    defer std.testing.allocator.free(input);
    var result = try rewrite(std.testing.allocator, input, false);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.stats.replacements);
    const single = try testInput(std.testing.allocator, &.{4}, "");
    defer std.testing.allocator.free(single);
    var sole = try rewrite(std.testing.allocator, single, false);
    defer sole.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), sole.stats.replacements);
    try std.testing.expect(!sole.generic_needed);
    const other = try testInput(std.testing.allocator, &.{ 4, 7 }, "");
    defer std.testing.allocator.free(other);
    var fallback = try rewrite(std.testing.allocator, other, false);
    defer fallback.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), fallback.stats.replacements);
    try std.testing.expect(fallback.generic_needed);
}

test "data sections labels malformed setup and inline assembly cannot masquerade as matches" {
    const input = try testInput(std.testing.allocator, &.{ 9, 9, 9, 9, 9, 9 }, "");
    defer std.testing.allocator.free(input);
    const data = try std.mem.replaceOwned(u8, std.testing.allocator, input, "kind=code", "kind=rodata");
    defer std.testing.allocator.free(data);
    var result = try rewrite(std.testing.allocator, data, false);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.stats.matched_sites);
    try std.testing.expectEqualStrings(data, result.assembly);
    const interrupted = try std.mem.replaceOwned(u8, std.testing.allocator, input, "    lda #9", "join:\n    lda #9");
    defer std.testing.allocator.free(interrupted);
    var labels = try rewrite(std.testing.allocator, interrupted, false);
    defer labels.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), labels.stats.matched_sites);
    const opaque_input = try std.fmt.allocPrint(std.testing.allocator, "; inline asm from ZeroPage line 1\n{s}; end inline asm\n", .{input});
    defer std.testing.allocator.free(opaque_input);
    var skipped = try rewrite(std.testing.allocator, opaque_input, false);
    defer skipped.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), skipped.stats.matched_sites);
    try std.testing.expectEqualStrings(opaque_input, skipped.assembly);
}

test "existing stride helper labels or references keep their source meaning" {
    for ([_][]const u8{ "zeropage_stride_mul_9:\n    rts\n", ".word zeropage_stride_mul_9\n" }) |suffix| {
        const input = try testInput(std.testing.allocator, &.{ 9, 9, 9, 9, 9, 9 }, suffix);
        defer std.testing.allocator.free(input);
        var result = try rewrite(std.testing.allocator, input, false);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), result.stats.replacements);
        try std.testing.expect(result.generic_needed);
        try std.testing.expectEqualStrings(input, result.assembly);
    }
}
