const late_layout = @import("layout_tail_test_support.zig");
const std = @import("std");
const ast = @import("../../ast.zig");
const parser = @import("../../parser.zig");
const emitter = @import("emitter.zig");
const arguments = @import("call_argument_rewrite.zig");
const optimizer = @import("optimizer.zig");
const x_values = @import("x_value_forwarding.zig");
const booleans = @import("boolean_materialization.zig");
const cfg = @import("cfg_dead_values.zig");
const writes = @import("dead_call_writes.zig");
const storage = @import("dead_call_storage.zig");
const pipeline = @import("pipeline.zig");
const allocator = std.testing.allocator;

fn guarded(program: ast.Program) bool {
    return program.zeropage_module != null or program.zeropage_options.memory.placements.len != 0;
}

// All fixture declarations are retained; none requests ZP allocation. Return
// normalized instructions immediately before capture-write/data pruning.
fn preparedAssembly(program: ast.Program) ![]u8 {
    const raw = try emitter.emitProgram(allocator, program);
    defer allocator.free(raw);
    const captured = try arguments.rewrite(allocator, program, raw);
    var current = try optimizer.finalizeAssemblyWithOptions(allocator, captured, .{
        .reuse_pointer_bases = program.zeropage_module == null,
        .cleanup_values = program.zeropage_module == null,
        .hoist_loop_pointers = program.zeropage_module == null,
        .reduce_loop_ranges = program.zeropage_module == null,
    });
    errdefer allocator.free(current);
    if (!guarded(program)) {
        const forwarded = try x_values.rewrite(allocator, current);
        allocator.free(current);
        current = forwarded.assembly;
        const folded = try booleans.rewrite(allocator, current);
        allocator.free(current);
        current = folded.assembly;
        const cleaned = try cfg.rewrite(allocator, current);
        allocator.free(current);
        current = cleaned.assembly;
    }
    return current;
}

fn contains(list: []const []const u8, text: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, text)) return true;
    return false;
}

// Compare every significant instruction, source/helper label and data line,
// allowing only the precise private stores/definitions named by each test.
fn significant(assembly: []const u8, instructions: []const []const u8, definitions: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var expect_word = false;
    var lines = std.mem.splitScalar(u8, assembly, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == ';') continue;
        if (expect_word) {
            try std.testing.expectEqualStrings(".word 0", line);
            expect_word = false;
            continue;
        }
        if (std.mem.endsWith(u8, line, ":") and contains(definitions, line[0 .. line.len - 1])) {
            expect_word = true;
            continue;
        }
        if (contains(instructions, line)) continue;
        try out.writer.print("{s}\n", .{line});
    }
    try std.testing.expect(!expect_word);
    return out.toOwnedSlice();
}

fn sections(assembly: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, assembly, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "; zeropage_section_")) try out.writer.print("{s}\n", .{line});
    return out.toOwnedSlice();
}

fn check(source: []const u8, removed_stores: []const []const u8, removed_cells: []const []const u8) ![]u8 {
    const parsed = try parser.parseSource(allocator, source);
    defer parsed.deinit(allocator);
    const prepared = try preparedAssembly(parsed.program);
    defer allocator.free(prepared);
    const old_pruned = if (guarded(parsed.program))
        storage.Result{ .assembly = try allocator.dupe(u8, prepared), .stats = .{} }
    else
        try storage.rewrite(allocator, prepared);
    defer allocator.free(old_pruned.assembly);
    const after = try pipeline.emitBeforeSingleCallLeaf(allocator, parsed.program);
    errdefer allocator.free(after);
    var phase_after: ?[]u8 = null;
    defer if (phase_after) |text| allocator.free(text);
    if (!guarded(parsed.program)) {
        const eliminated = try writes.rewrite(allocator, prepared);
        defer allocator.free(eliminated.assembly);
        const new_pruned = try storage.rewrite(allocator, eliminated.assembly);
        defer allocator.free(new_pruned.assembly);
        try std.testing.expectEqual(removed_stores.len, eliminated.stats.stores_removed);
        try std.testing.expectEqual(removed_cells.len, new_pruned.stats.slots_pruned - old_pruned.stats.slots_pruned);
        phase_after = try allocator.dupe(u8, new_pruned.assembly);
        const completed = try late_layout.finish(allocator, parsed.program, new_pruned.assembly);
        defer allocator.free(completed);
        try std.testing.expectEqualStrings(completed, after);
    } else {
        try std.testing.expectEqual(@as(usize, 0), removed_stores.len);
        try std.testing.expectEqual(@as(usize, 0), removed_cells.len);
        try std.testing.expectEqualStrings(old_pruned.assembly, after);
    }
    for (removed_stores) |instruction| {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, old_pruned.assembly, instruction));
        try std.testing.expect(std.mem.indexOf(u8, after, instruction) == null);
    }
    const expected = try significant(old_pruned.assembly, removed_stores, removed_cells);
    defer allocator.free(expected);
    const actual = try significant(phase_after orelse after, &.{}, &.{});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    const old_sections = try sections(old_pruned.assembly);
    defer allocator.free(old_sections);
    const new_sections = try sections(after);
    defer allocator.free(new_sections);
    try std.testing.expectEqualStrings(old_sections, new_sections);
    return after;
}

test "dead call writes backend removes forwarded byte capture store and its data only" {
    const after = try check("fn leaf(value: u8) u8 { return value; } export fn main() void { _ = leaf(0x81); }", &.{"sta zeropage_call_arg_0"}, &.{"zeropage_call_arg_0"});
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "lda #129\n    sta leaf_value\n    jsr leaf\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "leaf_value:\n    .byte 0") != null);
}

test "dead call writes backend public word removes both unread captures after X forwarding" {
    const after = try check("export fn leaf(value: u16) u16 { return value; } export fn main() void { _ = leaf(0x8134); }", &.{ "sta zeropage_call_arg_0", "stx zeropage_call_arg_0+1" }, &.{"zeropage_call_arg_0"});
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "sta leaf_value\n    txa\n    sta leaf_value+1\n    jsr leaf\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "zeropage_call_arg_0:") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "leaf_value:\n    .word 0") != null);
}

test "dead call writes backend private word with no capture stores needs no new rewrite" {
    const after = try check("fn leaf(value: u16) u16 { return value; } export fn main() void { _ = leaf(0x8134); }", &.{}, &.{});
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "sta leaf_value\n    stx leaf_value+1\n    txa\n    jsr leaf\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "zeropage_call_arg_0:") == null);
}

test "dead call writes backend retains volatile producer source writes and nested calls" {
    const after = try check(
        \\fn produce(location: *volatile u8) u8 {
        \\    const prior: u8 = location.*;
        \\    location.* = prior;
        \\    return prior;
        \\}
        \\fn leaf(value: u8, tag: u8) u8 { return value ^ tag; }
        \\export fn main() void {
        \\    const device: *volatile u8 = @ptrFromInt(0xd012);
        \\    _ = leaf(produce(device), 7);
        \\}
    , &.{"sta zeropage_call_arg_1"}, &.{"zeropage_call_arg_1"});
    defer allocator.free(after);
    // The full significant-line comparison above checks every producer and
    // source/formal store; these assertions make the observable work explicit.
    try std.testing.expect(std.mem.indexOf(u8, after, "jsr produce\n    sta leaf_value\n    lda #7\n    sta leaf_tag\n    jsr leaf\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "lda (zeropage_ptr_tmp),y\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "sta (zeropage_ptr_tmp),y\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "produce_prior:") != null);
}

test "dead call writes backend ASM cross base and mixed case observations keep family cells" {
    const after = try check(
        \\fn leaf(first: u8, last: u8) u8 { return first ^ last; }
        \\export fn main() void {
        \\    _ = leaf(0x81, 0x42);
        \\    asm {
        \\        lda ZEROPAGE_CALL_ARG_0+2
        \\        ldx #<ZeroPage_Call_Arg_1
        \\    }
        \\}
    , &.{}, &.{});
    defer allocator.free(after);
    // Ordinary source cannot name private compiler scratch outside ASM. The
    // isolated cross-cell/offset proof is separately tested by the pure pass;
    // this actual-source case checks the global ASM/address-observer boundary.
    try std.testing.expect(std.mem.indexOf(u8, after, "ZEROPAGE_CALL_ARG_0+2") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "zeropage_call_arg_0:\n    .word 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "zeropage_call_arg_1:\n    .word 0") != null);
}

test "dead call writes backend module and placement retain the complete previous path" {
    const module = try check(
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{ .entry = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{ .id = "dead_write_guard", .abi = 1, .exports = .{ .entry = entry }, .deps = .{} };
        \\fn entry(value: u8) u8 { return value; }
        \\export fn main() void { _ = entry(0x81); }
    , &.{}, &.{});
    defer allocator.free(module);
    const placement = try check(
        \\pub const zeropage_options = .{ .memory = .{
        \\    .regions = .{ .fixed = .{ .addr = 0x2000, .size = 0x0100 } },
        \\    .placements = .{ .fixed = .{ .region = .fixed, .load = .direct, .functions = .{ leaf } } },
        \\} };
        \\fn leaf(value: u8) u8 { return value; }
        \\export fn main() void { _ = leaf(0x81); }
    , &.{}, &.{});
    defer allocator.free(placement);
}
