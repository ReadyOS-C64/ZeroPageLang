const short_branches = @import("short_branches.zig");
const std = @import("std");
const ast = @import("../../ast.zig");
const parser = @import("../../parser.zig");
const emitter = @import("emitter.zig");
const arguments = @import("call_argument_rewrite.zig");
const optimizer = @import("optimizer.zig");
const x_values = @import("x_value_forwarding.zig");
const branch = @import("branch_a_forwarding.zig");
const booleans = @import("boolean_materialization.zig");
const cfg = @import("cfg_dead_values.zig");
const writes = @import("dead_call_writes.zig");
const storage = @import("dead_call_storage.zig");
const counted_latch = @import("counted_latch.zig");
const pipeline = @import("pipeline.zig");
const allocator = std.testing.allocator;

const range_source =
    \\export fn main() void {
    \\    var total: u16 = 0;
    \\    for (0..9) |index| { total += index; }
    \\    _ = total;
    \\}
;
const array_source =
    \\const values = [_]u16{ 1, 255, 256, 0x8134 };
    \\export fn main() void {
    \\    var total: u16 = 0;
    \\    for (values) |value| { total += value; }
    \\    _ = total;
    \\}
;

fn guarded(program: ast.Program) bool {
    return program.zeropage_module != null or program.zeropage_options.memory.placements.len != 0;
}

// Actual R29 boundary: ordinary R28 lowering through X forwarding, before
// boolean materialization/CFG/DSE/storage. Every fixture function is retained.
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
        const result = try x_values.rewrite(allocator, current);
        allocator.free(current);
        current = result.assembly;
    }
    return current;
}

fn finish(program: ast.Program, assembly: []const u8) ![]u8 {
    var current = try allocator.dupe(u8, assembly);
    errdefer allocator.free(current);
    if (!guarded(program)) {
        const folded = try booleans.rewrite(allocator, current);
        allocator.free(current);
        current = folded.assembly;
        const cleaned = try cfg.rewrite(allocator, current);
        allocator.free(current);
        current = cleaned.assembly;
        const eliminated = try writes.rewrite(allocator, current);
        allocator.free(current);
        current = eliminated.assembly;
        const pruned = try storage.rewrite(allocator, current);
        allocator.free(current);
        current = pruned.assembly;
    }
    if (!guarded(program) and program.zeropage_options.modules == null) {
        const shortened = try short_branches.rewrite(allocator, current);
        allocator.free(current);
        current = shortened.assembly;
        if (try counted_latch.rewrite(allocator, program, current)) |latched| {
            allocator.free(current);
            current = latched;
        }
        if (try cfg.rewriteLate(allocator, program, current)) |cleaned| {
            allocator.free(current);
            current = cleaned;
        }
    }
    return current;
}

// Pure production replacements preserve every line and label: only a real
// direct counter LDA may become the NZ-restoring ORA identity instruction.
fn expectOnlyCounterIdentities(before: []const u8, after: []const u8, expected: usize) !void {
    var old_lines = std.mem.splitScalar(u8, before, '\n');
    var new_lines = std.mem.splitScalar(u8, after, '\n');
    var changed: usize = 0;
    while (old_lines.next()) |old| {
        const new = new_lines.next() orelse return error.ExpectedSameAssemblyLines;
        if (std.mem.eql(u8, old, new)) continue;
        const instruction = std.mem.trim(u8, old, " \t");
        try std.testing.expect(std.mem.startsWith(u8, instruction, "lda main_for_"));
        try std.testing.expect(std.mem.endsWith(u8, instruction, "_index"));
        try std.testing.expectEqualStrings("ora #0", std.mem.trim(u8, new, " \t"));
        changed += 1;
    }
    try std.testing.expect(new_lines.next() == null);
    try std.testing.expectEqual(expected, changed);
}

fn check(source: []const u8, selected: bool) !void {
    const parsed = try parser.parseSource(allocator, source);
    defer parsed.deinit(allocator);
    const prepared = try preparedAssembly(parsed.program);
    defer allocator.free(prepared);
    const result = try branch.rewrite(allocator, prepared);
    defer allocator.free(result.assembly);
    try expectOnlyCounterIdentities(prepared, result.assembly, result.stats.reloads_replaced);
    const expected = try finish(parsed.program, if (guarded(parsed.program)) prepared else result.assembly);
    defer allocator.free(expected);
    const after = try pipeline.emitProgram(allocator, parsed.program);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(expected, after);
    if (!guarded(parsed.program)) {
        if (selected) {
            try std.testing.expect(result.stats.reloads_replaced > 0);
            try std.testing.expect(result.stats.bytes_saved > 0);
        } else {
            try std.testing.expectEqual(@as(usize, 0), result.stats.reloads_replaced);
            try std.testing.expectEqualStrings(prepared, result.assembly);
        }
    } else {
        const old = try finish(parsed.program, prepared);
        defer allocator.free(old);
        try std.testing.expectEqualStrings(old, after);
    }
}

test "branch A forwarding backend reuses actual range and word-array loop counters" {
    try check(range_source, true);
    try check(array_source, true);
}

test "branch A forwarding backend emitter-derived physical flag observer retains ORA" {
    const parsed = try parser.parseSource(allocator, array_source);
    defer parsed.deinit(allocator);
    const prepared = try preparedAssembly(parsed.program);
    defer allocator.free(prepared);
    const body = std.mem.indexOf(u8, prepared, "for_0_body:\n") orelse return error.ExpectedGeneratedLoopBody;
    const load = "    lda main_for_0_index\n";
    const at = std.mem.indexOfPos(u8, prepared, body, load) orelse return error.ExpectedGeneratedCounterLoad;
    const end = at + load.len;
    // This is deliberately an emitter-derived machine observer, not an
    // ordinary source-language NZ promise. PHP reads physical status before
    // the generated ASL/TAY can overwrite NZ; PLP restores stack/flags.
    const observed = try std.mem.concat(allocator, u8, &.{ prepared[0..end], "    php\n    plp\n", prepared[end..] });
    defer allocator.free(observed);
    const result = try branch.rewrite(allocator, observed);
    defer allocator.free(result.assembly);
    try std.testing.expectEqual(@as(usize, 1), result.stats.reloads_replaced);
    try expectOnlyCounterIdentities(observed, result.assembly, 1);
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "for_0_body:\n    ora #0\n    php\n    plp\n    asl\n") != null);
    const cleaned = try cfg.rewrite(allocator, result.assembly);
    defer allocator.free(cleaned.assembly);
    try std.testing.expect(std.mem.indexOf(u8, cleaned.assembly, "ora #0\n    php\n    plp\n") != null);
}

test "branch A forwarding backend emitter-derived extra address reference pins body entry" {
    const parsed = try parser.parseSource(allocator, array_source);
    defer parsed.deinit(allocator);
    const prepared = try preparedAssembly(parsed.program);
    defer allocator.free(prepared);
    // Source cannot name generated loop bodies outside ASM. Add an explicit
    // assembly data observer to actual emitter output to test the extra-entry
    // proof independently of the source ASM global barrier.
    const observed = try std.mem.concat(allocator, u8, &.{ prepared, "\n    .word FOR_0_BODY\n" });
    defer allocator.free(observed);
    const result = try branch.rewrite(allocator, observed);
    defer allocator.free(result.assembly);
    try std.testing.expectEqual(@as(usize, 0), result.stats.reloads_replaced);
    try std.testing.expectEqualStrings(observed, result.assembly);
}

test "branch A forwarding backend source ASM keeps the real loop and block unchanged" {
    try check(
        \\export fn main() void {
        \\    var total: u16 = 0;
        \\    for (0..9) |index| {
        \\        total += index;
        \\        asm {
        \\            nop
        \\        }
        \\    }
        \\    _ = total;
        \\}
    , false);
}

test "branch A forwarding backend module and fixed placement retain prior paths" {
    try check(
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{ .entry = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{ .id = "branch_guard", .abi = 1, .exports = .{ .entry = entry }, .deps = .{} };
        \\fn entry(value: u8) u8 { return value; }
        \\export fn main() void {
        \\    var total: u16 = 0;
        \\    for (0..9) |index| { total += index; }
        \\    _ = entry(7);
        \\    _ = total;
        \\}
    , false);
    try check(
        \\pub const zeropage_options = .{ .memory = .{
        \\    .regions = .{ .fixed = .{ .addr = 0x2000, .size = 0x0100 } },
        \\    .placements = .{ .fixed = .{ .region = .fixed, .load = .direct, .functions = .{ leaf } } },
        \\} };
        \\fn leaf() u8 { return 7; }
        \\export fn main() void {
        \\    var total: u16 = 0;
        \\    for (0..9) |index| { total += index; }
        \\    _ = leaf();
        \\    _ = total;
        \\}
    , false);
}

test "branch A forwarding backend visible ROM shadow cannot establish counter identity" {
    const source = try std.mem.concat(allocator, u8, &.{ "pub const zeropage_options = .{ .image = .{ .basic_stub = false, .load_addr = 0xa000, .entry_addr = 0xa000 } };\n", range_source });
    defer allocator.free(source);
    try check(source, false);
}
