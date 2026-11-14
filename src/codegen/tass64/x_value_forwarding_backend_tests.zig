const late_layout = @import("layout_tail_test_support.zig");
const std = @import("std");
const ast = @import("../../ast.zig");
const parser = @import("../../parser.zig");
const emitter = @import("emitter.zig");
const arguments = @import("call_argument_rewrite.zig");
const optimizer = @import("optimizer.zig");
const booleans = @import("boolean_materialization.zig");
const cfg = @import("cfg_dead_values.zig");
const writes = @import("dead_call_writes.zig");
const storage = @import("dead_call_storage.zig");
const forwarding = @import("x_value_forwarding.zig");
const pipeline = @import("pipeline.zig");
const allocator = std.testing.allocator;

fn guarded(program: ast.Program) bool {
    return program.zeropage_module != null or program.zeropage_options.memory.placements.len != 0;
}

// These fixtures retain every function and do not request ZP allocation.
fn preparedAssembly(program: ast.Program) ![]u8 {
    const raw = try emitter.emitProgram(allocator, program);
    defer allocator.free(raw);
    const captured = try arguments.rewrite(allocator, program, raw);
    return optimizer.finalizeAssemblyWithOptions(allocator, captured, .{
        .reuse_pointer_bases = program.zeropage_module == null,
        .cleanup_values = program.zeropage_module == null,
        .hoist_loop_pointers = program.zeropage_module == null,
        .reduce_loop_ranges = program.zeropage_module == null,
    });
}

// Consume no caller storage; the returned assembly is owned. This is the exact
// accepted R27 tail, and the same tail follows X forwarding in R28.
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
    const completed = try late_layout.finish(allocator, program, current);
    allocator.free(current);
    return completed;
}

fn expectOnlyLoadTransfers(before: []const u8, after: []const u8, count: usize) !void {
    var old_lines = std.mem.splitScalar(u8, before, '\n');
    var new_lines = std.mem.splitScalar(u8, after, '\n');
    var replaced: usize = 0;
    while (old_lines.next()) |old| {
        const new = new_lines.next() orelse return error.ExpectedSameAssemblyLines;
        if (std.mem.eql(u8, old, new)) continue;
        try std.testing.expect(std.mem.startsWith(u8, std.mem.trim(u8, old, " \t"), "lda "));
        try std.testing.expectEqualStrings("txa", std.mem.trim(u8, new, " \t"));
        replaced += 1;
    }
    try std.testing.expect(new_lines.next() == null);
    try std.testing.expectEqual(count, replaced);
}

const Emission = struct {
    before: []u8,
    forwarded: []u8,
    after: []u8,

    fn deinit(self: Emission) void {
        allocator.free(self.before);
        allocator.free(self.forwarded);
        allocator.free(self.after);
    }
};

fn check(source: []const u8, selected: bool) !Emission {
    const parsed = try parser.parseSource(allocator, source);
    defer parsed.deinit(allocator);
    const prepared = try preparedAssembly(parsed.program);
    defer allocator.free(prepared);
    const before = try finish(parsed.program, prepared);
    errdefer allocator.free(before);
    const result = try forwarding.rewrite(allocator, prepared);
    errdefer allocator.free(result.assembly);
    try expectOnlyLoadTransfers(prepared, result.assembly, result.stats.loads_forwarded);
    const expected = try finish(parsed.program, if (guarded(parsed.program)) prepared else result.assembly);
    defer allocator.free(expected);
    const after = try pipeline.emitBeforeSingleCallLeaf(allocator, parsed.program);
    errdefer allocator.free(after);
    try std.testing.expectEqualStrings(expected, after);
    if (!guarded(parsed.program)) {
        if (selected) {
            try std.testing.expect(result.stats.loads_forwarded > 0);
            try std.testing.expect(result.stats.bytes_saved > 0);
        } else {
            try std.testing.expectEqual(@as(usize, 0), result.stats.loads_forwarded);
            try std.testing.expectEqualStrings(before, after);
        }
    } else {
        try std.testing.expectEqualStrings(before, after);
    }
    return .{ .before = before, .forwarded = result.assembly, .after = after };
}

test "X value forwarding backend replaces final private word high reload with TXA" {
    const emitted = try check("fn leaf(value: u16) u16 { return value; } export fn main() void { _ = leaf(0x8134); }", true);
    defer emitted.deinit();
    try std.testing.expect(std.mem.indexOf(u8, emitted.before, "sta leaf_value\n    stx leaf_value+1\n    lda leaf_value+1\n    jsr leaf\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted.after, "sta leaf_value\n    stx leaf_value+1\n    txa\n    jsr leaf\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted.after, "leaf_value:\n    .word 0") != null);
}

test "X value forwarding backend public high capture becomes TXA then both dead capture stores disappear" {
    const emitted = try check("export fn leaf(value: u16) u16 { return value; } export fn main() void { _ = leaf(0x8134); }", true);
    defer emitted.deinit();
    // This is the accepted R27 byte-mask result: the high byte still has a
    // reader even though the low private store has already been eliminated.
    try std.testing.expect(std.mem.indexOf(u8, emitted.before, "stx zeropage_call_arg_0+1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted.before, "lda zeropage_call_arg_0+1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted.before, "zeropage_call_arg_0:\n    .word 0") != null);
    // The pure X phase preserves both stores/formal writes; only its LDA is
    // replaced. The following DSE/data phases may now remove both captures.
    try std.testing.expect(std.mem.indexOf(u8, emitted.forwarded, "stx zeropage_call_arg_0+1\n    sta leaf_value\n    txa\n    sta leaf_value+1\n    jsr leaf\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted.after, "lda #52\n    sta leaf_value\n    txa\n    sta leaf_value+1\n    jsr leaf\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted.after, "zeropage_call_arg_0") == null);
    try std.testing.expect(std.mem.indexOf(u8, emitted.after, "leaf_value:\n    .word 0") != null);
}

test "X value forwarding backend preserves volatile loads and invalidates uncertain memory facts" {
    const emitted = try check(
        \\fn leaf(value: u16, tail: u8) u16 { return value; }
        \\export fn main() void {
        \\    const device: *volatile u8 = @ptrFromInt(0xd012);
        \\    _ = leaf(0x8134, device.*);
        \\}
    , false);
    defer emitted.deinit();
    try std.testing.expect(std.mem.indexOf(u8, emitted.after, "lda (zeropage_ptr_tmp),y\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted.after, "lda zeropage_call_arg_0+1\n    sta leaf_value+1\n") != null);
}

fn asmBlock(assembly: []const u8) ![]const u8 {
    const begin = std.mem.indexOf(u8, assembly, "; inline asm") orelse return error.ExpectedInlineAssembly;
    const end = std.mem.indexOfPos(u8, assembly, begin, "; end inline asm") orelse return error.ExpectedInlineAssembly;
    return assembly[begin .. end + "; end inline asm".len];
}

test "X value forwarding backend leaves ASM exact but forwards fresh facts outside it" {
    const emitted = try check(
        \\fn leaf(value: u16) u16 { return value; }
        \\export fn main() void {
        \\    var byte: u8 = 7;
        \\    asm {
        \\        ldx @byte
        \\        lda @byte
        \\    }
        \\    _ = leaf(0x8134);
        \\}
    , true);
    defer emitted.deinit();
    try std.testing.expectEqualStrings(try asmBlock(emitted.before), try asmBlock(emitted.forwarded));
    try std.testing.expectEqualStrings(try asmBlock(emitted.before), try asmBlock(emitted.after));
    try std.testing.expect(std.mem.indexOf(u8, try asmBlock(emitted.after), "ldx main_byte\n    lda main_byte") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted.before, "lda zeropage_call_arg_0+1\n    sta leaf_value+1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted.after, "txa\n    sta leaf_value+1\n") != null);
    // Existing opaque-ASM guards still retain capture writes/data downstream.
    try std.testing.expect(std.mem.indexOf(u8, emitted.after, "zeropage_call_arg_0:\n    .word 0") != null);
}

test "X value forwarding backend module and placement keep the complete R27 path" {
    const module = try check(
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{ .entry = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{ .id = "x_forward_guard", .abi = 1, .exports = .{ .entry = entry }, .deps = .{} };
        \\fn entry(value: u16) u16 { return value; }
        \\export fn main() void { _ = entry(0x8134); }
    , false);
    defer module.deinit();
    const placement = try check(
        \\pub const zeropage_options = .{ .memory = .{
        \\    .regions = .{ .fixed = .{ .addr = 0x2000, .size = 0x0100 } },
        \\    .placements = .{ .fixed = .{ .region = .fixed, .load = .direct, .functions = .{ leaf } } },
        \\} };
        \\fn leaf(value: u16) u16 { return value; }
        \\export fn main() void { _ = leaf(0x8134); }
    , false);
    defer placement.deinit();
}

test "X value forwarding backend visible ROM shadow cannot establish RAM value identity" {
    const emitted = try check("pub const zeropage_options = .{ .image = .{ .basic_stub = false, .load_addr = 0xa000, .entry_addr = 0xa000 } }; export fn leaf(value: u16) u16 { return value; } export fn main() void { _ = leaf(0x8134); }", false);
    defer emitted.deinit();
    try std.testing.expect(std.mem.indexOf(u8, emitted.after, "lda zeropage_call_arg_0+1\n") != null);
}
