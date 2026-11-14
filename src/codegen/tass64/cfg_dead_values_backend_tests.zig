const late_layout = @import("layout_tail_test_support.zig");
const short_branches = @import("short_branches.zig");
const std = @import("std");
const ast = @import("../../ast.zig");
const parser = @import("../../parser.zig");
const emitter = @import("emitter.zig");
const optimizer = @import("optimizer.zig");
const pipeline = @import("pipeline.zig");
const arguments = @import("call_argument_rewrite.zig");
const x_values = @import("x_value_forwarding.zig");
const boolean = @import("boolean_materialization.zig");
const cfg = @import("cfg_dead_values.zig");
const dead_storage = @import("dead_call_storage.zig");
const dead_writes = @import("dead_call_writes.zig");
const machine = @import("instruction.zig");
const allocator = std.testing.allocator;

// Fixtures retain all source functions, omit ZP policy, and therefore exercise
// exactly the pipeline up to the CFG pass without a second liveness/layout path.
fn baseline(program: ast.Program) ![]u8 {
    const emitted = try emitter.emitProgram(allocator, program);
    defer allocator.free(emitted);
    const copied = try arguments.rewrite(allocator, program, emitted);
    const previous = try optimizer.finalizeAssemblyWithOptions(allocator, copied, .{
        .reuse_pointer_bases = program.zeropage_module == null,
        .cleanup_values = program.zeropage_module == null,
        .hoist_loop_pointers = program.zeropage_module == null,
        .reduce_loop_ranges = program.zeropage_module == null,
    });
    if (program.zeropage_module != null or program.zeropage_options.memory.placements.len != 0) return previous;
    defer allocator.free(previous);
    const forwarded = try x_values.rewrite(allocator, previous);
    defer allocator.free(forwarded.assembly);
    return (try boolean.rewrite(allocator, forwarded.assembly)).assembly;
}

fn selectedLines(text: []const u8, memory: bool) ![]u8 {
    var result: std.Io.Writer.Allocating = .init(allocator);
    errdefer result.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const selected = if (!memory) std.mem.endsWith(u8, line, ":") else blk: {
            const instruction = machine.Instruction.parse(line) orelse break :blk false;
            break :blk instruction.effects().memory != .none;
        };
        if (selected) try result.writer.print("{s}\n", .{line});
    }
    return result.toOwnedSlice();
}

fn expectSameLabels(before: []const u8, after: []const u8) !void {
    const old = try selectedLines(before, false);
    defer allocator.free(old);
    const new = try selectedLines(after, false);
    defer allocator.free(new);
    try std.testing.expect(old.len != 0);
    try std.testing.expectEqualStrings(old, new);
}

test "CFG backend composes real AND OR and effectful source calls after the boolean fold" {
    const sources = [_][]const u8{
        \\export fn main() void {
        \\    var a: u8 = 1; var b: u8 = 2; var result: u8 = 0;
        \\    const selected: bool = a < b and b != 7;
        \\    if (selected) { result = 3; }
        \\    _ = result;
        \\}
        ,
        \\export fn main() void {
        \\    var a: u8 = 1; var b: u8 = 2; var result: u8 = 0;
        \\    const selected: bool = a >= b or b == 7;
        \\    if (selected) { result = 3; }
        \\    _ = result;
        \\}
        ,
        \\fn touch(value: *u8) u8 { value.* = value.* + 1; return value.*; }
        \\export fn main() void {
        \\    var a: u8 = 1; var b: u8 = 2;
        \\    const selected: bool = touch(&a) < b and touch(&b) != 7;
        \\    if (selected) { a = 9; }
        \\    _ = a;
        \\}
        ,
    };
    for (sources) |source| {
        const parsed = try parser.parseSource(allocator, source);
        defer parsed.deinit(allocator);
        const before = try baseline(parsed.program);
        defer allocator.free(before);
        const expected = try cfg.rewrite(allocator, before);
        defer allocator.free(expected.assembly);
        try std.testing.expect(expected.stats.removed > 0);
        try std.testing.expect(expected.stats.loads_removed > 0);
        const actual = try pipeline.emitBeforeSingleCallLeaf(allocator, parsed.program);
        defer allocator.free(actual);
        const unwritten = try dead_writes.rewrite(allocator, expected.assembly);
        defer allocator.free(unwritten.assembly);
        const pruned = try dead_storage.rewrite(allocator, unwritten.assembly);
        defer allocator.free(pruned.assembly);
        const completed = try late_layout.finish(allocator, parsed.program, pruned.assembly);
        defer allocator.free(completed);
        try std.testing.expectEqualStrings(completed, actual);
        // CFG keeps every label. The later storage pass independently removes
        // only verified unused compiler capture definitions.
        try expectSameLabels(before, expected.assembly);
        try std.testing.expectEqual(std.mem.count(u8, before, "    jsr touch\n"), std.mem.count(u8, actual, "    jsr touch\n"));
    }
}

test "CFG backend module placement and retained ASM guards keep otherwise eligible constants" {
    const sources = [_][]const u8{
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{ .entry = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{ .id = "cfg_guard", .abi = 1, .exports = .{ .entry = entry }, .deps = .{} };
        \\fn entry(value: u8) u8 { return value; }
        \\export fn main() void { _ = @as(u8, 0); _ = @as(u8, 1); }
        ,
        \\pub const zeropage_options = .{ .memory = .{
        \\    .regions = .{ .fixed = .{ .addr = 0x2000, .size = 0x0100 } },
        \\    .placements = .{ .fixed = .{ .region = .fixed, .load = .direct, .functions = .{ main } } },
        \\} };
        \\export fn main() void { _ = @as(u8, 0); _ = @as(u8, 1); }
        ,
        \\export fn main() void {
        \\    _ = @as(u8, 0); _ = @as(u8, 1);
        \\    asm {
        \\        nop
        \\    }
        \\}
        ,
    };
    for (sources) |source| {
        const parsed = try parser.parseSource(allocator, source);
        defer parsed.deinit(allocator);
        const before = try baseline(parsed.program);
        defer allocator.free(before);
        const after = try pipeline.emitBeforeSingleCallLeaf(allocator, parsed.program);
        defer allocator.free(after);
        try std.testing.expectEqualStrings(before, after);
        try expectSameLabels(before, after);
        const unguarded = try cfg.rewrite(allocator, before);
        defer allocator.free(unguarded.assembly);
        if (std.mem.indexOf(u8, before, "; inline asm") != null) {
            try std.testing.expectEqual(@as(usize, 0), unguarded.stats.removed);
            const no_marker = try std.mem.replaceOwned(u8, allocator, before, "; inline asm", "; erased test barrier");
            defer allocator.free(no_marker);
            const eligible = try cfg.rewrite(allocator, no_marker);
            defer allocator.free(eligible.assembly);
            try std.testing.expect(eligible.stats.removed > 0);
        } else try std.testing.expect(unguarded.stats.removed > 0);
    }
}

test "CFG backend keeps every ordered volatile read even when its value is discarded or overwritten" {
    const source =
        \\export fn main() void {
        \\    const first: *volatile u8 = @ptrFromInt(0xdc04);
        \\    const second: *volatile u8 = @ptrFromInt(0xd012);
        \\    _ = first.*;
        \\    _ = second.*;
        \\    _ = first.*;
        \\    _ = @as(u8, 0);
        \\}
    ;
    const parsed = try parser.parseSource(allocator, source);
    defer parsed.deinit(allocator);
    const before = try baseline(parsed.program);
    defer allocator.free(before);
    const expected = try cfg.rewrite(allocator, before);
    defer allocator.free(expected.assembly);
    const after = try pipeline.emitBeforeSingleCallLeaf(allocator, parsed.program);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(expected.assembly, after);
    const old_memory = try selectedLines(before, true);
    defer allocator.free(old_memory);
    const new_memory = try selectedLines(after, true);
    defer allocator.free(new_memory);
    try std.testing.expectEqualStrings(old_memory, new_memory);
    var volatile_reads: usize = 0;
    var lines = std.mem.splitScalar(u8, after, '\n');
    while (lines.next()) |line| {
        const instruction = machine.Instruction.parse(line) orelse continue;
        if (instruction.op == .lda and instruction.operand == .indirect) volatile_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), volatile_reads);
    try expectSameLabels(before, after);
}

test "CFG backend treats source callee entry as observing all preceding CPU outputs" {
    const source =
        \\fn observe() void { _ = @as(u16, 1); }
        \\export fn main() void { _ = @as(u16, 0x817f); observe(); }
    ;
    const parsed = try parser.parseSource(allocator, source);
    defer parsed.deinit(allocator);
    const before = try baseline(parsed.program);
    defer allocator.free(before);
    const folded = try cfg.rewrite(allocator, before);
    defer allocator.free(folded.assembly);
    try std.testing.expectEqual(@as(usize, 0), folded.stats.removed);
    try std.testing.expect(std.mem.indexOf(u8, before, "ldx #129\n    lda #127") != null);
    try std.testing.expect(std.mem.indexOf(u8, before, "    jsr observe\n") != null);
    const after = try pipeline.emitBeforeSingleCallLeaf(allocator, parsed.program);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    try expectSameLabels(before, after);
}
