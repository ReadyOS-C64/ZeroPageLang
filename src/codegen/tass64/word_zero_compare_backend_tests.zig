const late_layout = @import("layout_tail_test_support.zig");
const short_branches = @import("short_branches.zig");
const std = @import("std");
const ast = @import("../../ast.zig");
const parser = @import("../../parser.zig");
const emitter = @import("emitter.zig");
const arguments = @import("call_argument_rewrite.zig");
const optimizer = @import("optimizer.zig");
const x_values = @import("x_value_forwarding.zig");
const branch_a = @import("branch_a_forwarding.zig");
const booleans = @import("boolean_materialization.zig");
const cfg = @import("cfg_dead_values.zig");
const planner = @import("word_zero_compare_plan.zig");
const word_zero = @import("word_zero_compare_rewrite.zig");
const machine = @import("instruction.zig");
const writes = @import("dead_call_writes.zig");
const storage = @import("dead_call_storage.zig");
const pipeline = @import("pipeline.zig");
const allocator = std.testing.allocator;

const less_source =
    \\fn classify(value: u16) u8 {
    \\    if (value < 0x0100) { return 17; }
    \\    return 42;
    \\}
    \\export fn main() void { _ = classify(255); _ = classify(256); }
;
const greater_source =
    \\fn classify(value: u16) u8 {
    \\    if (value >= 0x8000) { return 17; }
    \\    return 42;
    \\}
    \\export fn main() void { _ = classify(32767); _ = classify(32768); }
;
const nonzero_source =
    \\fn classify(value: u16) u8 {
    \\    if (value < 257) { return 17; }
    \\    return 42;
    \\}
    \\export fn main() void { _ = classify(256); _ = classify(257); }
;
const equality_source =
    \\fn classify(value: u16) u8 {
    \\    if (value == 256) { return 17; }
    \\    return 42;
    \\}
    \\export fn main() void { _ = classify(256); _ = classify(257); }
;
const void_source =
    \\fn converge(value: u16) void {
    \\    while (value < 256) { value = 256; }
    \\}
    \\export fn main() void { converge(0); converge(256); }
;
const asm_source =
    \\fn classify(value: u16) u8 {
    \\    if (value < 256) { return 17; }
    \\    return 42;
    \\}
    \\export fn main() void {
    \\    _ = classify(255);
    \\    asm {
    \\        nop
    \\    }
    \\}
;
const module_source =
    \\pub const zeropage_options = .{
    \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
    \\    .abi = .{ .functions = .{ .entry = .{ .frame = .stack } } },
    \\};
    \\pub const zeropage_module = .{ .id = "word_zero_guard", .abi = 1, .exports = .{ .entry = entry }, .deps = .{} };
    \\fn entry(value: u8) u8 { return value; }
    \\fn classify(value: u16) u8 { if (value < 256) { return 17; } return 42; }
    \\export fn main() void { _ = entry(7); _ = classify(255); }
;
const placement_source =
    \\pub const zeropage_options = .{ .memory = .{
    \\    .regions = .{ .fixed = .{ .addr = 0x2000, .size = 0x0100 } },
    \\    .placements = .{ .fixed = .{ .region = .fixed, .load = .direct, .functions = .{ leaf } } },
    \\} };
    \\fn leaf() u8 { return 7; }
    \\fn classify(value: u16) u8 { if (value < 256) { return 17; } return 42; }
    \\export fn main() void { _ = leaf(); _ = classify(255); }
;

fn guarded(program: ast.Program) bool {
    return program.zeropage_module != null or program.zeropage_options.memory.placements.len != 0;
}

// All fixture functions are actually retained by calls/module exports, and no
// fixture declares a zero-page policy. Reproduce the actual current boundary:
// emitter -> call rewrite -> old optimizer -> X -> branch A -> bool -> CFG.
fn preparedAssembly(program: ast.Program) ![]u8 {
    try std.testing.expect(!program.zeropage_options.zero_page.declared);
    const emitted = try emitter.emitProgram(allocator, program);
    defer allocator.free(emitted);
    const captured = try arguments.rewrite(allocator, program, emitted);
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
        const edge = try branch_a.rewrite(allocator, current);
        allocator.free(current);
        current = edge.assembly;
        const folded = try booleans.rewrite(allocator, current);
        allocator.free(current);
        current = folded.assembly;
        const cleaned = try cfg.rewrite(allocator, current);
        allocator.free(current);
        current = cleaned.assembly;
    }
    return current;
}

fn finish(program: ast.Program, assembly: []const u8) ![]u8 {
    if (guarded(program)) return allocator.dupe(u8, assembly);
    const eliminated = try writes.rewrite(allocator, assembly);
    defer allocator.free(eliminated.assembly);
    const pruned = try storage.rewrite(allocator, eliminated.assembly);
    defer allocator.free(pruned.assembly);
    const laid_out = try late_layout.finish(allocator, program, pruned.assembly);
    errdefer allocator.free(laid_out);
    if (try cfg.rewriteLate(allocator, program, laid_out)) |cleaned| {
        allocator.free(laid_out);
        return cleaned;
    }
    return laid_out;
}

fn expectOnlyPairs(before: []const u8, after: []const u8, count: usize) !void {
    var old_lines = std.mem.splitScalar(u8, before, '\n');
    var new_lines = std.mem.splitScalar(u8, after, '\n');
    var next = new_lines.next();
    var branches: usize = 0;
    var compares: usize = 0;
    while (old_lines.next()) |old| {
        if (next) |new| if (std.mem.eql(u8, old, new)) {
            next = new_lines.next();
            continue;
        };
        const instruction = machine.Instruction.parse(std.mem.trim(u8, old, " \t\r")) orelse return error.UnexpectedRemovedText;
        if (instruction.op == .bne and instruction.operand == .direct and
            std.mem.startsWith(u8, instruction.operand.direct.name, "cmp_word_"))
        {
            branches += 1;
        } else if (instruction.op == .cmp and instruction.operand == .immediate and
            (machine.integer(instruction.operand.immediate) orelse return error.ExpectedLiteralLowCompare) == 0)
        {
            compares += 1;
        } else return error.UnexpectedRemovedInstruction;
    }
    try std.testing.expect(next == null);
    try std.testing.expectEqual(count, branches);
    try std.testing.expectEqual(count, compares);
}

fn check(source: []const u8, expected_count: usize) !void {
    const parsed = try parser.parseSource(allocator, source);
    defer parsed.deinit(allocator);
    const before = try preparedAssembly(parsed.program);
    defer allocator.free(before);
    const rewritten = try word_zero.rewrite(allocator, before);
    defer allocator.free(rewritten.assembly);
    try expectOnlyPairs(before, rewritten.assembly, rewritten.stats.diamonds_reduced);
    if (!guarded(parsed.program)) {
        try std.testing.expectEqualDeep(word_zero.Stats{
            .diamonds_reduced = expected_count,
            .branches_removed = expected_count,
            .low_compares_removed = expected_count,
            .bytes_saved = expected_count * 4,
        }, rewritten.stats);
        if (expected_count == 0) try std.testing.expectEqualStrings(before, rewritten.assembly);
    }
    const expected = try finish(parsed.program, if (guarded(parsed.program)) before else rewritten.assembly);
    defer allocator.free(expected);
    const actual = try pipeline.emitProgram(allocator, parsed.program);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "word zero backend composes actual unsigned less and greater equal return markers" {
    for ([_][]const u8{ less_source, greater_source }) |source| {
        const parsed = try parser.parseSource(allocator, source);
        defer parsed.deinit(allocator);
        const before = try preparedAssembly(parsed.program);
        defer allocator.free(before);
        var plan = try planner.analyze(allocator, before);
        defer plan.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), plan.candidates.len);
        const candidate = plan.candidates[0];
        try std.testing.expectEqualStrings("classify", candidate.owner);
        try std.testing.expectEqual(@as(u8, if (std.mem.eql(u8, source, less_source)) 1 else 128), candidate.high_value);
        try std.testing.expect(std.mem.indexOf(u8, before, "lda #17\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, before, "lda #42\n") != null);
        const pure = try word_zero.rewrite(allocator, before);
        defer allocator.free(pure.assembly);
        try std.testing.expectEqual(@as(usize, 1), pure.stats.diamonds_reduced);
        try expectOnlyPairs(before, pure.assembly, 1);
    }
    // Validate both pure emitter-derived positives before the deliberately red
    // pre-integration pipeline assertion stops this group on the old compiler.
    try check(less_source, 1);
    try check(greater_source, 1);
}

test "word zero backend keeps nonzero low and equality consumers on existing source paths" {
    try check(nonzero_source, 0);
    try check(equality_source, 0);
}

test "word zero backend retains finite void loop exit physical NZ through actual RTS" {
    const parsed = try parser.parseSource(allocator, void_source);
    defer parsed.deinit(allocator);
    const before = try preparedAssembly(parsed.program);
    defer allocator.free(before);
    var plan = try planner.analyze(allocator, before);
    defer plan.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), plan.candidates.len);
    try std.testing.expect(!try cfg.outputsDeadAfterLine(allocator, before, plan.candidates[0].join_line, machine.nz));
    try check(void_source, 0);
}

test "word zero backend emitter derived first true body PHP observer rejects the existing candidate" {
    const parsed = try parser.parseSource(allocator, less_source);
    defer parsed.deinit(allocator);
    const before = try preparedAssembly(parsed.program);
    defer allocator.free(before);
    var original = try planner.analyze(allocator, before);
    defer original.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), original.candidates.len);
    // The consumer's real taken target is the first true body. Insert the
    // machine observer immediately after its label, before any generated load
    // or other N/Z kill. This is deliberately emitter-derived assembly, not a
    // source-language promise that ordinary comparison flags are observable.
    var lines = std.mem.splitScalar(u8, before, '\n');
    var index: usize = 0;
    var consumer: ?machine.Instruction = null;
    while (lines.next()) |line| : (index += 1) if (index == original.candidates[0].consumer_line) {
        consumer = machine.Instruction.parse(std.mem.trim(u8, line, " \t\r"));
        break;
    };
    const instruction = consumer orelse return error.ExpectedActualCarryConsumer;
    try std.testing.expect(instruction.operand == .direct);
    const target = try std.fmt.allocPrint(allocator, "{s}:\n", .{instruction.operand.direct.name});
    defer allocator.free(target);
    const at = (std.mem.indexOf(u8, before, target) orelse return error.ExpectedTrueBody) + target.len;
    const observed = try std.mem.concat(allocator, u8, &.{ before[0..at], "    php\n    plp\n", before[at..] });
    defer allocator.free(observed);
    var plan = try planner.analyze(allocator, observed);
    defer plan.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), plan.candidates.len);
    try std.testing.expect(!try cfg.outputsDeadAfterLine(allocator, observed, plan.candidates[0].join_line, machine.nz));
    const rewritten = try word_zero.rewrite(allocator, observed);
    defer allocator.free(rewritten.assembly);
    try std.testing.expectEqualDeep(word_zero.Stats{}, rewritten.stats);
    try std.testing.expectEqualStrings(observed, rewritten.assembly);
}

test "word zero backend source ASM retains real comparisons and source block" {
    try check(asm_source, 0);
}

test "word zero backend module and legal fixed placement retain guarded pipeline paths" {
    try check(module_source, 0);
    try check(placement_source, 0);
}
