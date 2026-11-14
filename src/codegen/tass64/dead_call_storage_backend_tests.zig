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
const dead = @import("dead_call_storage.zig");
const pipeline = @import("pipeline.zig");
const allocator = std.testing.allocator;

// All fixture functions are retained and no fixture requests ZP allocation.
// Reproduce the current sequence through dead capture writes, immediately
// before the R26 data-pruning phase whose storage/label contract is tested here.
fn previousAssembly(program: ast.Program) ![]u8 {
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
    if (program.zeropage_module == null and program.zeropage_options.memory.placements.len == 0) {
        const forwarded = try x_values.rewrite(allocator, current);
        allocator.free(current);
        current = forwarded.assembly;
        const folded = try booleans.rewrite(allocator, current);
        allocator.free(current);
        current = folded.assembly;
        const cleaned = try cfg.rewrite(allocator, current);
        allocator.free(current);
        current = cleaned.assembly;
        const eliminated = try writes.rewrite(allocator, current);
        allocator.free(current);
        current = eliminated.assembly;
    }
    return current;
}

fn excluded(name: []const u8, removed: []const []const u8) bool {
    for (removed) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn labels(assembly: []const u8, removed: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, assembly, '\n');
    while (lines.next()) |raw| {
        const text = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.endsWith(u8, text, ":")) continue;
        const name = text[0 .. text.len - 1];
        if (excluded(name, removed)) continue;
        try out.writer.print("{s}\n", .{name});
    }
    return out.toOwnedSlice();
}

fn expectBalancedSections(assembly: []const u8) !void {
    var active = false;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, assembly, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "; zeropage_section_begin ")) {
            try std.testing.expect(!active);
            active = true;
            count += 1;
        } else if (std.mem.startsWith(u8, line, "; zeropage_section_end ")) {
            try std.testing.expect(active);
            active = false;
        }
    }
    try std.testing.expect(!active);
    try std.testing.expect(count > 0);
}

fn check(source: []const u8, removed: []const []const u8) ![]u8 {
    const parsed = try parser.parseSource(allocator, source);
    defer parsed.deinit(allocator);
    const before = try previousAssembly(parsed.program);
    defer allocator.free(before);
    const pruned = try dead.rewrite(allocator, before);
    defer allocator.free(pruned.assembly);
    const after = try pipeline.emitBeforeSingleCallLeaf(allocator, parsed.program);
    errdefer allocator.free(after);
    if (parsed.program.zeropage_module != null or parsed.program.zeropage_options.memory.placements.len != 0) {
        try std.testing.expectEqualStrings(before, after);
    } else {
        try std.testing.expectEqual(@as(usize, removed.len), pruned.stats.slots_pruned);
        try std.testing.expectEqual(@as(usize, 2 * removed.len), pruned.stats.bytes_pruned);
        const completed = try late_layout.finish(allocator, parsed.program, pruned.assembly);
        defer allocator.free(completed);
        try std.testing.expectEqualStrings(completed, after);
    }
    for (removed) |name| {
        const definition = try std.fmt.allocPrint(allocator, "{s}:\n    .word 0", .{name});
        defer allocator.free(definition);
        try std.testing.expect(std.mem.indexOf(u8, before, definition) != null);
        try std.testing.expect(std.mem.indexOf(u8, after, definition) == null);
    }
    const old_labels = try labels(before, removed);
    defer allocator.free(old_labels);
    const new_labels = try labels(after, &.{});
    defer allocator.free(new_labels);
    try std.testing.expectEqualStrings(old_labels, new_labels);
    try expectBalancedSections(after);
    return after;
}

test "dead call storage backend removes private word capture data and keeps empty section markers" {
    const after = try check("fn identity(value: u16) u16 { return value; } export fn main() void { _ = identity(0x8134); }", &.{"zeropage_call_arg_0"});
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "sta identity_value\n    stx identity_value+1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "identity_value:\n    .word 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "; zeropage_section_begin owner=compiler kind=scratch lifetime=static address=near\n; zeropage_section_end owner=compiler kind=scratch") != null);
}

test "dead call storage backend retains complete byte captures with real copy reads" {
    const source = "fn later() u8 { return 7; } fn leaf(first: u8, last: u8) u8 { return first ^ last; } export fn main() void { _ = leaf(0x81, later()); }";
    const parsed = try parser.parseSource(allocator, source);
    defer parsed.deinit(allocator);
    const before = try previousAssembly(parsed.program);
    defer allocator.free(before);
    // The later call prevents direct first capture. Copying that first byte
    // changes A, making the final byte's reload necessary as well. Establish
    // these actual reads before demanding that data pruning retain both words.
    try std.testing.expect(std.mem.indexOf(u8, before, "lda zeropage_call_arg_0\n    sta leaf_first\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, before, "lda zeropage_call_arg_1\n    sta leaf_last\n") != null);
    const after = try check(source, &.{});
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "zeropage_call_arg_0:\n    .word 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "zeropage_call_arg_1:\n    .word 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "lda zeropage_call_arg_0\n    sta leaf_first\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "lda zeropage_call_arg_1\n    sta leaf_last\n") != null);
}

test "dead call storage backend public word ABI retains formal storage after X forwarding" {
    const after = try check("export fn leaf(value: u16) u16 { return value; } export fn main() void { _ = leaf(0x8134); }", &.{"zeropage_call_arg_0"});
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "zeropage_call_arg_0:") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "leaf_value:\n    .word 0") != null);
    // R28 forwards the former private high-byte read from X; R27 can then
    // remove both unread capture writes. Public formal writes remain intact.
    try std.testing.expect(std.mem.indexOf(u8, after, "sta leaf_value\n    txa\n    sta leaf_value+1\n    jsr leaf\n") != null);
}

test "dead call storage backend source ASM and mixed case symbol address observations retain cells" {
    const after = try check(
        \\fn identity(value: u16) u16 { return value; }
        \\export fn main() void {
        \\    _ = identity(0x8134);
        \\    asm {
        \\        lda #<ZEROPAGE_CALL_ARG_0
        \\        ldx #>ZeroPage_Call_Arg_0
        \\    }
        \\}
    , &.{});
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "zeropage_call_arg_0:\n    .word 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "#<ZEROPAGE_CALL_ARG_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "#>ZeroPage_Call_Arg_0") != null);
}

test "dead call storage backend module and placement stay on their prior emission path" {
    const module = try check(
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{ .entry = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{ .id = "dead_call_guard", .abi = 1, .exports = .{ .entry = entry }, .deps = .{} };
        \\fn entry(value: u16) u16 { return value; }
        \\export fn main() void { _ = entry(0x8134); }
    , &.{});
    defer allocator.free(module);
    const placement = try check(
        \\pub const zeropage_options = .{ .memory = .{
        \\    .regions = .{ .fixed = .{ .addr = 0x2000, .size = 0x0100 } },
        \\    .placements = .{ .fixed = .{ .region = .fixed, .load = .direct, .functions = .{ leaf } } },
        \\} };
        \\fn leaf(value: u16) u16 { return value; }
        \\export fn main() void { _ = leaf(0x8134); }
    , &.{});
    defer allocator.free(placement);
}
