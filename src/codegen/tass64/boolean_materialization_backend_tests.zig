const late_layout = @import("layout_tail_test_support.zig");
const std = @import("std");
const ast = @import("../../ast.zig");
const parser = @import("../../parser.zig");
const emitter = @import("emitter.zig");
const optimizer = @import("optimizer.zig");
const pipeline = @import("pipeline.zig");
const call_arguments = @import("call_argument_rewrite.zig");
const materialization = @import("boolean_materialization.zig");
const cfg_dead_values = @import("cfg_dead_values.zig");
const branch_a = @import("branch_a_forwarding.zig");
const allocator = std.testing.allocator;

// These fixtures retain all declarations and do not request ZP allocation.
// Recreate the accepted pipeline immediately before the boolean pass, rather
// than comparing against a second invocation of the pass being tested.
fn previousAssembly(program: ast.Program) ![]u8 {
    const emitted = try emitter.emitProgram(allocator, program);
    defer allocator.free(emitted);
    const arguments = try call_arguments.rewrite(allocator, program, emitted);
    return optimizer.finalizeAssemblyWithOptions(allocator, arguments, .{
        .reuse_pointer_bases = program.zeropage_module == null,
        .cleanup_values = program.zeropage_module == null,
        .hoist_loop_pointers = program.zeropage_module == null,
        .reduce_loop_ranges = program.zeropage_module == null,
    });
}

fn labels(assembly: []const u8) ![]u8 {
    var result: std.Io.Writer.Allocating = .init(allocator);
    errdefer result.deinit();
    var lines = std.mem.splitScalar(u8, assembly, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.endsWith(u8, line, ":")) {
            try result.writer.writeAll(line);
            try result.writer.writeByte('\n');
        }
    }
    return result.toOwnedSlice();
}

fn expectLabelsUnchanged(before: []const u8, after: []const u8) !void {
    const old_labels = try labels(before);
    defer allocator.free(old_labels);
    const new_labels = try labels(after);
    defer allocator.free(new_labels);
    try std.testing.expect(old_labels.len != 0);
    try std.testing.expectEqualStrings(old_labels, new_labels);
}

// Reproduce the later value passes without rerunning the boolean pass under
// test. Ordinary edge reuse now follows the first CFG cleanup; only its new
// identities request another CFG cleanup. Label checks remain independent.
fn laterValues(program: ast.Program, assembly: []const u8) ![]u8 {
    const first = try cfg_dead_values.rewrite(allocator, assembly);
    var current = first.assembly;
    errdefer allocator.free(current);
    if (program.zeropage_options.modules == null) {
        const edges = try branch_a.rewriteOrdinary(allocator, current);
        allocator.free(current);
        current = edges.assembly;
        if (edges.stats.reloads_replaced != 0) {
            const second = try cfg_dead_values.rewrite(allocator, current);
            allocator.free(current);
            current = second.assembly;
        }
    }
    const completed = try late_layout.finish(allocator, program, current);
    allocator.free(current);
    return completed;
}

fn expectFold(source: []const u8, and_folds: bool, or_folds: bool) !void {
    const parsed = try parser.parseSource(allocator, source);
    defer parsed.deinit(allocator);
    const before = try previousAssembly(parsed.program);
    defer allocator.free(before);
    const folded = try materialization.rewrite(allocator, before);
    defer allocator.free(folded.assembly);
    const after = try pipeline.emitProgram(allocator, parsed.program);
    defer allocator.free(after);
    try std.testing.expect(folded.stats.folds > 0);
    if (and_folds) try std.testing.expect(folded.stats.bne_folds > 0);
    if (or_folds) try std.testing.expect(folded.stats.beq_folds > 0);
    try std.testing.expect(folded.stats.bytes_saved > 0);
    const expected = try laterValues(parsed.program, folded.assembly);
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, after);
    try expectLabelsUnchanged(before, after);
}

test "boolean materialization backend folds comparison AND consumers" {
    try expectFold(
        \\export fn main() void {
        \\    var a: u8 = 1; var b: u8 = 2; var result: u8 = 0;
        \\    const selected: bool = a < b and b != 7;
        \\    if (selected) { result = 3; }
        \\    _ = result;
        \\}
    , true, false);
}

test "boolean materialization backend folds comparison OR consumers" {
    try expectFold(
        \\export fn main() void {
        \\    var a: u8 = 1; var b: u8 = 2; var result: u8 = 0;
        \\    const selected: bool = a >= b or b == 7;
        \\    if (selected) { result = 3; }
        \\    _ = result;
        \\}
    , false, true);
}

test "boolean materialization backend nested conditions preserve every source and helper label" {
    try expectFold(
        \\export fn main() void {
        \\    var a: u8 = 1; var b: u8 = 2; var result: u8 = 0;
        \\    while (a < 8) {
        \\        const selected: bool = (a < b and b != 7) or (a == 4 and b > 0);
        \\        if (selected) {
        \\            const inner: bool = b >= a or a == 3;
        \\            if (inner) { result = result + 1; }
        \\        }
        \\        a = a + 1;
        \\    }
        \\    _ = result;
        \\}
    , true, true);
}

fn expectUnchanged(source: []const u8, has_unblocked_match: bool) !void {
    const parsed = try parser.parseSource(allocator, source);
    defer parsed.deinit(allocator);
    const before = try previousAssembly(parsed.program);
    defer allocator.free(before);
    const after = try pipeline.emitProgram(allocator, parsed.program);
    defer allocator.free(after);
    if (parsed.program.zeropage_module == null and parsed.program.zeropage_options.memory.placements.len == 0) {
        // Later CFG cleanup may remove a dead value even when the boolean
        // materializer pass itself correctly leaves its producer intact.
        const expected = try laterValues(parsed.program, before);
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, after);
    } else try std.testing.expectEqualStrings(before, after);
    try expectLabelsUnchanged(before, after);
    const unguarded = try materialization.rewrite(allocator, before);
    defer allocator.free(unguarded.assembly);
    if (has_unblocked_match) {
        // This proves the pipeline's module/placement guard is effective even
        // when the textual pattern itself would otherwise be eligible.
        try std.testing.expect(unguarded.stats.folds > 0);
    } else {
        try std.testing.expectEqual(@as(usize, 0), unguarded.stats.folds);
        try std.testing.expectEqualStrings(before, unguarded.assembly);
        if (std.mem.indexOf(u8, before, "; inline asm") != null) {
            // Erase only the barrier comment in a private counterfactual. The
            // real output above must stay unchanged even though otherwise
            // eligible patterns occur on both sides of the source ASM block.
            const no_marker = try std.mem.replaceOwned(u8, allocator, before, "; inline asm", "; erased test barrier");
            defer allocator.free(no_marker);
            const eligible = try materialization.rewrite(allocator, no_marker);
            defer allocator.free(eligible.assembly);
            try std.testing.expect(eligible.stats.bne_folds > 0);
            try std.testing.expect(eligible.stats.beq_folds > 0);
        } else {
            // Ensure value-only coverage really contains comparison-result
            // materialization, rather than merely having no comparisons.
            try std.testing.expect(std.mem.indexOf(u8, before, "_true:\n    lda #1\ncmp_") != null);
        }
    }
}

test "boolean materialization backend source ASM blocks folds across the whole image" {
    try expectUnchanged(
        \\export fn main() void {
        \\    var a: u8 = 1; var b: u8 = 2;
        \\    const selected: bool = a < b and b != 7;
        \\    if (selected) { a = 3; }
        \\    asm {
        \\        nop
        \\    }
        \\    const second: bool = a == 3 or b > 4;
        \\    if (second) { b = 5; }
        \\}
    , false);
}

test "boolean materialization pass keeps value only comparison materializers before later cleanup" {
    try expectUnchanged(
        \\export fn main() void {
        \\    var a: u8 = 1; var b: u8 = 2;
        \\    const less: bool = a < b;
        \\    _ = a != b;
        \\    _ = less;
        \\}
    , false);
}

test "boolean materialization backend relocated module keeps the previous path" {
    try expectUnchanged(
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{ .entry = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{ .id = "boolean_guard", .abi = 1, .exports = .{ .entry = entry }, .deps = .{} };
        \\fn entry(value: u8) u8 { return value; }
        \\export fn main() void {
        \\    var a: u8 = 1; var b: u8 = 2;
        \\    const selected: bool = a < b and b != 7;
        \\    if (selected) { a = 3; }
        \\}
    , true);
}

test "boolean materialization backend any fixed placement keeps the previous path" {
    try expectUnchanged(
        \\pub const zeropage_options = .{ .memory = .{
        \\    .regions = .{ .fixed = .{ .addr = 0x2000, .size = 0x0100 } },
        \\    .placements = .{ .fixed = .{ .region = .fixed, .load = .direct, .functions = .{ main } } },
        \\} };
        \\export fn main() void {
        \\    var a: u8 = 1; var b: u8 = 2;
        \\    const selected: bool = a < b and b != 7;
        \\    if (selected) { a = 3; }
        \\}
    , true);
}
