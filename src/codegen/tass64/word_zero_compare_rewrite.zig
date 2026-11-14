const std = @import("std");
const planner = @import("word_zero_compare_plan.zig");
const cfg = @import("cfg_dead_values.zig");
const machine = @import("instruction.zig");

pub const Stats = struct {
    diamonds_reduced: usize = 0,
    branches_removed: usize = 0,
    low_compares_removed: usize = 0,
    bytes_saved: usize = 0,
};
pub const Result = struct { assembly: []u8, stats: Stats };

fn sameCandidate(expected: planner.Candidate, current: planner.Candidate) bool {
    return expected.high_compare_line == current.high_compare_line and
        expected.branch_line == current.branch_line and expected.low_compare_line == current.low_compare_line and
        expected.join_line == current.join_line and expected.consumer_line == current.consumer_line and
        expected.high_value == current.high_value and expected.consumer == current.consumer and
        std.mem.eql(u8, expected.owner, current.owner) and std.mem.eql(u8, expected.join, current.join);
}

fn removePair(allocator: std.mem.Allocator, assembly: []const u8, candidate: planner.Candidate) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, assembly, '\n');
    var line: usize = 0;
    var first = true;
    while (lines.next()) |raw| : (line += 1) {
        if (line == candidate.branch_line or line == candidate.low_compare_line) continue;
        if (!first) try out.writer.writeByte('\n');
        first = false;
        try out.writer.writeAll(raw);
    }
    return out.toOwnedSlice();
}

/// Original candidates schedule work only. Reparse the current immutable buffer
/// and prove its actual remaining N/Z uses before constructing a replacement.
fn reduceCurrent(allocator: std.mem.Allocator, assembly: []const u8, scheduled: planner.Candidate) !?[]u8 {
    var fresh = try planner.analyze(allocator, assembly);
    defer fresh.deinit(allocator);
    for (fresh.candidates) |candidate| {
        if (!sameCandidate(scheduled, candidate)) continue;
        if (!try cfg.outputsDeadAfterLine(allocator, assembly, candidate.join_line, machine.nz)) return null;
        return try removePair(allocator, assembly, candidate);
    }
    return null;
}

/// Remove only BNE/CMP #0 in a freshly validated CPX-immediate word diamond.
/// CPX carry already equals the original carry: unequal highs skipped CMP,
/// while equal highs make both CPX and CMP #0 set C. A/X/Y/SP/V/I/D/memory stay
/// unchanged; the only differing N/Z must die on every actual successor path.
/// Four saved bytes per pair is a nominal instruction count, not final PRG size.
pub fn rewrite(allocator: std.mem.Allocator, assembly: []const u8) !Result {
    var schedule = try planner.analyze(allocator, assembly);
    defer schedule.deinit(allocator);
    var current = try allocator.dupe(u8, assembly);
    errdefer allocator.free(current);
    var stats: Stats = .{};
    var index = schedule.candidates.len;
    // Later deletion leaves earlier raw positions stable. Every subsequent
    // proof still reparses current output, never a graph with removed killers.
    while (index != 0) {
        index -= 1;
        if (try reduceCurrent(allocator, current, schedule.candidates[index])) |next| {
            allocator.free(current);
            current = next;
            stats.diamonds_reduced += 1;
            stats.branches_removed += 1;
            stats.low_compares_removed += 1;
            stats.bytes_saved += 4;
        }
    }
    return .{ .assembly = current, .stats = stats };
}

const begin = "; zeropage_section_begin owner=function:f kind=code lifetime=static address=near\n";
const end = "; zeropage_section_end owner=function:f kind=code\n";
const body = "f:\n    cpx #4\n    bne cmp_word_9_done\n    cmp #0\ncmp_word_9_done:\n    bcc yes\n    jmp no\nyes:\n    sta output\n    lda #1\n    rts\nno:\n    sta output\n    lda #0\n    rts\n";
const adjacent_body = "f:\n    cpx #4\n    bne cmp_word_1_done\n    cmp #0\ncmp_word_1_done:\n    bcc second\n    jmp second\nsecond:\n    cpx #7\n    bne cmp_word_2_done\n    cmp #0\ncmp_word_2_done:\n    bcs yes\n    jmp no\nyes:\n    lda #1\n    rts\nno:\n    lda #0\n    rts\n";
const data = "; zeropage_section_begin owner=function:f kind=static_frame\noutput:\n    .byte 0\n; zeropage_section_end owner=function:f kind=static_frame\n";
fn fixture(allocator: std.mem.Allocator, code: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ "* = $2000\n", begin, code, end, data });
}
fn expectReduced(input: []const u8, count: usize) !void {
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualDeep(Stats{ .diamonds_reduced = count, .branches_removed = count, .low_compares_removed = count, .bytes_saved = count * 4 }, result.stats);
}
fn expectKept(input: []const u8) !void {
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualStrings(input, result.assembly);
    try std.testing.expectEqualDeep(Stats{}, result.stats);
}

test "word zero rewrite removes only the proved branch and low compare and preserves labels data and stores" {
    const input = try fixture(std.testing.allocator, body);
    defer std.testing.allocator.free(input);
    const expected_body = try std.mem.replaceOwned(u8, std.testing.allocator, body, "    bne cmp_word_9_done\n    cmp #0\n", "");
    defer std.testing.allocator.free(expected_body);
    const expected = try fixture(std.testing.allocator, expected_body);
    defer std.testing.allocator.free(expected);
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualStrings(expected, result.assembly);
    try std.testing.expectEqualDeep(Stats{ .diamonds_reduced = 1, .branches_removed = 1, .low_compares_removed = 1, .bytes_saved = 4 }, result.stats);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result.assembly, "sta output"));
}

test "word zero rewrite handles both carry consumers and all literal high values" {
    for (0..256) |high| {
        const instruction = try std.fmt.allocPrint(std.testing.allocator, "cpx #{d}", .{high});
        defer std.testing.allocator.free(instruction);
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, body, "cpx #4", instruction);
        defer std.testing.allocator.free(changed);
        const input = try fixture(std.testing.allocator, changed);
        defer std.testing.allocator.free(input);
        try expectReduced(input, 1);
    }
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, body, "bcc yes", "bcs yes");
    defer std.testing.allocator.free(changed);
    const input = try fixture(std.testing.allocator, changed);
    defer std.testing.allocator.free(input);
    try expectReduced(input, 1);
}

test "word zero carry identity holds for every X H and boundary A independent of D" {
    for (0..256) |high| for (0..256) |x| for ([_]usize{ 0, 1, 127, 128, 255 }) |a| {
        const original_carry = if (x != high) x >= high else a >= 0;
        try std.testing.expectEqual(original_carry, x >= high);
    };
}

test "word zero rewrite requires N Z dead on both paths before PHP calls or returns" {
    for ([_][2][]const u8{
        .{ "    lda #1", "    php\n    lda #1" },                   .{ "    lda #0", "    php\n    lda #0" },
        .{ "    lda #1\n    rts", "    rts" },                      .{ "    lda #0\n    rts", "    rts" },
        .{ "    lda #1", "    bmi observe\nobserve:\n    lda #1" }, .{ "    lda #0", "    beq observe\nobserve:\n    lda #0" },
        .{ "    lda #1", "    jsr helper\n    lda #1" },
    }) |change| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, body, change[0], change[1]);
        defer std.testing.allocator.free(changed);
        const with_helper = try std.mem.concat(std.testing.allocator, u8, &.{ changed, "helper:\n    rts\n" });
        defer std.testing.allocator.free(with_helper);
        const input = try fixture(std.testing.allocator, with_helper);
        defer std.testing.allocator.free(input);
        try expectKept(input);
    }
}

test "word zero rewrite does not infer a cyclic path dead or bypass unknown consumers" {
    for ([_][]const u8{ "loop:\n    nop\n    bcc loop\n", "    .byte $ea\n", "    lda strange(data)\n", "    jmp (pointer)\n" }) |prefix| {
        const replacement = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "    lda #1" });
        defer std.testing.allocator.free(replacement);
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, body, "    lda #1", replacement);
        defer std.testing.allocator.free(changed);
        const input = try fixture(std.testing.allocator, changed);
        defer std.testing.allocator.free(input);
        try expectKept(input);
    }
}

test "word zero rewrite preserves entry alias observer nonzero low and noncarry barriers" {
    for ([_][2][]const u8{
        .{ "    cmp #0", "bypass:\n    cmp #0" }, .{ "    bne cmp_word_9_done", "bypass:\n    bne cmp_word_9_done" },
        .{ "cmp #0", "cmp #1" },                  .{ "cmp #0", "cmp $a000" },
        .{ "cpx #4", "cpx $d020" },               .{ "bcc yes", "beq yes" },
        .{ "bcc yes", "bne yes" },                .{ "cmp_word_9_done:\n", "alias:\ncmp_word_9_done:\n    jsr alias\n" },
    }) |change| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, body, change[0], change[1]);
        defer std.testing.allocator.free(changed);
        const input = try fixture(std.testing.allocator, changed);
        defer std.testing.allocator.free(input);
        try expectKept(input);
    }
    const original = try fixture(std.testing.allocator, body);
    defer std.testing.allocator.free(original);
    for ([_][]const u8{ ".word cmp_word_9_done\n", ".word f+2\n", "CMP_WORD_9_DONE:\n", "; inline asm from ZeroPage line 4\n    nop\n; end inline asm\n" }) |tail| {
        const input = try std.mem.concat(std.testing.allocator, u8, &.{ original, tail });
        defer std.testing.allocator.free(input);
        try expectKept(input);
    }
}

test "word zero rewrite preserves ROM MMIO and volatile memory operations that kill dead flags" {
    const first = try std.mem.replaceOwned(u8, std.testing.allocator, body, "lda #1", "lda $dc04");
    defer std.testing.allocator.free(first);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, first, "lda #0", "lda $a000");
    defer std.testing.allocator.free(changed);
    const input = try fixture(std.testing.allocator, changed);
    defer std.testing.allocator.free(input);
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqual(@as(usize, 1), result.stats.diamonds_reduced);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.assembly, "lda $dc04"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.assembly, "lda $a000"));
}

test "word zero rewrite refuses a stale schedule after shape indices or liveness change" {
    const original = try fixture(std.testing.allocator, body);
    defer std.testing.allocator.free(original);
    var scheduled = try planner.analyze(std.testing.allocator, original);
    defer scheduled.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), scheduled.candidates.len);
    for ([_][2][]const u8{
        .{ "cmp #0", "cmp #1" },          .{ "cpx #4", "cpx #5" },               .{ "bcc yes", "beq yes" },
        .{ "lda #1", "php\n    lda #1" }, .{ "f:\n", "f:\n; extra raw line\n" },
    }) |change| {
        const current = try std.mem.replaceOwned(u8, std.testing.allocator, original, change[0], change[1]);
        defer std.testing.allocator.free(current);
        const result = try reduceCurrent(std.testing.allocator, current, scheduled.candidates[0]);
        defer if (result) |owned| std.testing.allocator.free(owned);
        try std.testing.expect(result == null);
    }
}

test "word zero rewrite processes adjacent diamonds on fresh current assembly in descending order" {
    const input = try fixture(std.testing.allocator, adjacent_body);
    defer std.testing.allocator.free(input);
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualDeep(Stats{ .diamonds_reduced = 2, .branches_removed = 2, .low_compares_removed = 2, .bytes_saved = 8 }, result.stats);
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "cpx #4\ncmp_word_1_done:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "cpx #7\ncmp_word_2_done:") != null);
    const second = try rewrite(std.testing.allocator, result.assembly);
    defer std.testing.allocator.free(second.assembly);
    try std.testing.expectEqualStrings(result.assembly, second.assembly);
    try std.testing.expectEqualDeep(Stats{}, second.stats);
}

test "word zero rewrite preserves every standalone comment blank raw label and newline convention" {
    const commented = try std.mem.replaceOwned(u8, std.testing.allocator, body, "    bne cmp_word_9_done\n    cmp #0\n", "; before branch\n    bne cmp_word_9_done\n\n; before low\n    cmp #0\n; before join\nunused_alias:\n");
    defer std.testing.allocator.free(commented);
    const input = try fixture(std.testing.allocator, commented);
    defer std.testing.allocator.free(input);
    const expected_without_branch = try std.mem.replaceOwned(u8, std.testing.allocator, input, "    bne cmp_word_9_done\n", "");
    defer std.testing.allocator.free(expected_without_branch);
    const expected = try std.mem.replaceOwned(u8, std.testing.allocator, expected_without_branch, "    cmp #0\n", "");
    defer std.testing.allocator.free(expected);
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualStrings(expected, result.assembly);
    const without_trailing_newline = input[0 .. input.len - 1];
    const without = try rewrite(std.testing.allocator, without_trailing_newline);
    defer std.testing.allocator.free(without.assembly);
    try std.testing.expectEqualStrings(expected[0 .. expected.len - 1], without.assembly);
    const crlf = try std.mem.replaceOwned(u8, std.testing.allocator, input, "\n", "\r\n");
    defer std.testing.allocator.free(crlf);
    const crlf_result = try rewrite(std.testing.allocator, crlf);
    defer std.testing.allocator.free(crlf_result.assembly);
    const crlf_expected = try std.mem.replaceOwned(u8, std.testing.allocator, expected, "\n", "\r\n");
    defer std.testing.allocator.free(crlf_expected);
    try std.testing.expectEqualStrings(crlf_expected, crlf_result.assembly);
}

fn allocationFailure(allocator: std.mem.Allocator, code: []const u8) !void {
    const input = try fixture(allocator, code);
    defer allocator.free(input);
    const result = rewrite(allocator, input) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer allocator.free(result.assembly);
    const declined = try std.mem.concat(allocator, u8, &.{ input, ".word f+2\n" });
    defer allocator.free(declined);
    const unchanged = try rewrite(allocator, declined);
    defer allocator.free(unchanged.assembly);
}
test "word zero rewrite frees scheduled fresh current output and proof state on allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{body});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{adjacent_body});
}
