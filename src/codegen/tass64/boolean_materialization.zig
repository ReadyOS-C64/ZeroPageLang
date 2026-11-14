const std = @import("std");

pub const Stats = struct {
    folds: usize = 0,
    bne_folds: usize = 0,
    beq_folds: usize = 0,
    bytes_saved: usize = 0,
};
pub const Result = struct { assembly: []u8, stats: Stats };
const Line = struct { index: usize, text: []const u8 };
const Action = union(enum) { keep, drop, sec, jump: []const u8, false_path: []const u8 };
const Match = struct { other: []const u8, next: []const u8, branch_nonzero: bool };
const SymbolCounts = struct { definitions: usize, references: usize };

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r");
}
fn identifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
fn symbol(text: []const u8) bool {
    if (text.len == 0 or !(std.ascii.isAlphabetic(text[0]) or text[0] == '_')) return false;
    for (text) |byte| if (!identifierByte(byte)) return false;
    return true;
}
fn label(text: []const u8) ?[]const u8 {
    if (text.len < 2 or text[text.len - 1] != ':') return null;
    const name = text[0 .. text.len - 1];
    return if (symbol(name)) name else null;
}
fn operand(text: []const u8, mnemonic: []const u8) ?[]const u8 {
    const end = std.mem.indexOfAny(u8, text, " \t") orelse return null;
    if (!std.mem.eql(u8, text[0..end], mnemonic)) return null;
    return trim(text[end..]);
}
fn immediate(text: []const u8, mnemonic: []const u8, value: []const u8) bool {
    return std.mem.eql(u8, operand(text, mnemonic) orelse return false, value);
}
fn direct(text: []const u8, mnemonic: []const u8) ?[]const u8 {
    const name = operand(text, mnemonic) orelse return null;
    return if (symbol(name)) name else null;
}

// All noncomment symbolic uses count, including address immediates, arithmetic,
// aliases, data and unknown syntax. Quoted occurrences may conservatively pin.
// Only the uniquely defined label's own definition is excluded.
fn symbolCounts(lines: []const Line, name: []const u8) SymbolCounts {
    var result: SymbolCounts = .{ .definitions = 0, .references = 0 };
    for (lines) |line| {
        if (label(line.text)) |defined| if (std.mem.eql(u8, defined, name)) {
            result.definitions += 1;
            continue;
        };
        var index: usize = 0;
        while (index < line.text.len) {
            if (!identifierByte(line.text[index])) {
                index += 1;
                continue;
            }
            const start = index;
            while (index < line.text.len and identifierByte(line.text[index])) : (index += 1) {}
            if (std.mem.eql(u8, line.text[start..index], name)) result.references += 1;
        }
    }
    return result;
}

fn match(lines: []const Line, start: usize) ?Match {
    if (lines.len - start < 9) return null;
    const group = lines[start .. start + 9];
    if (!immediate(group[0].text, "lda", "#0") or !immediate(group[3].text, "lda", "#1") or !immediate(group[5].text, "cmp", "#0")) return null;
    const done = direct(group[1].text, "jmp") orelse return null;
    const true_label = label(group[2].text) orelse return null;
    if (!std.mem.eql(u8, label(group[4].text) orelse return null, done)) return null;
    const nonzero = direct(group[6].text, "bne");
    const next = nonzero orelse direct(group[6].text, "beq") orelse return null;
    const other = direct(group[7].text, "jmp") orelse return null;
    if (!std.mem.eql(u8, label(group[8].text) orelse return null, next)) return null;
    const done_counts = symbolCounts(lines, done);
    if (done_counts.definitions != 1 or done_counts.references != 1) return null;
    if (symbolCounts(lines, true_label).definitions != 1 or symbolCounts(lines, next).definitions != 1) return null;
    return .{ .other = other, .next = next, .branch_nonzero = nonzero != null };
}

/// Borrow optimized, pre-ZP-relocation assembly and return owned assembly.
/// Fold only zero/one materializers whose immediate consumer retests A against
/// zero. SEC reproduces CMP #0's C=1; LDA preserves the identical A/NZ and
/// neither operation changes X/Y/V/I/D, memory or the hardware stack.
pub fn rewrite(allocator: std.mem.Allocator, assembly: []const u8) !Result {
    // Raw assembly can name instruction addresses or otherwise observe internal
    // control-flow anchors. Do not infer the absence of such observations.
    if (std.mem.indexOf(u8, assembly, "; inline asm") != null) return .{ .assembly = try allocator.dupe(u8, assembly), .stats = .{} };
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var significant: std.ArrayList(Line) = .empty;
    defer significant.deinit(allocator);
    var split = std.mem.splitScalar(u8, assembly, '\n');
    while (split.next()) |raw| {
        const index = lines.items.len;
        try lines.append(allocator, raw);
        const text = trim(raw);
        if (text.len != 0 and text[0] != ';') try significant.append(allocator, .{ .index = index, .text = text });
    }
    const actions = try allocator.alloc(Action, lines.items.len);
    defer allocator.free(actions);
    @memset(actions, .keep);
    var stats: Stats = .{};
    var index: usize = 0;
    while (index < significant.items.len) : (index += 1) {
        const found = match(significant.items, index) orelse continue;
        const group = significant.items[index .. index + 9];
        actions[group[1].index] = .{ .false_path = if (found.branch_nonzero) found.other else found.next };
        actions[group[5].index] = .sec;
        actions[group[6].index] = if (found.branch_nonzero) .drop else .{ .jump = found.other };
        actions[group[7].index] = .drop;
        stats.folds += 1;
        if (found.branch_nonzero) stats.bne_folds += 1 else stats.beq_folds += 1;
        stats.bytes_saved += if (found.branch_nonzero) 5 else 2;
        index += 8;
    }
    if (stats.folds == 0) return .{ .assembly = try allocator.dupe(u8, assembly), .stats = stats };
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (lines.items, actions, 0..) |raw, action, line_index| {
        switch (action) {
            .keep => try out.writer.writeAll(raw),
            .drop => continue,
            .sec => try out.writer.writeAll("    sec"),
            .jump => |target| try out.writer.print("    jmp {s}", .{target}),
            .false_path => |target| try out.writer.print("    sec\n    jmp {s}", .{target}),
        }
        if (line_index + 1 < lines.items.len) try out.writer.writeByte('\n');
    }
    return .{ .assembly = try out.toOwnedSlice(), .stats = stats };
}

const bne_source =
    \\    lda source
    \\    cmp #7
    \\    bne cmp_true
    \\cmp_false:
    \\    lda #0
    \\    jmp cmp_done
    \\cmp_true:
    \\    lda #1
    \\cmp_done:
    \\    cmp #0
    \\    bne bool_rhs
    \\    jmp bool_false
    \\bool_rhs:
    \\    sta result
    \\bool_false:
    \\    rts
    \\
;

test "boolean retest folds AND without changing labels producer or endpoint values" {
    const result = try rewrite(std.testing.allocator, bne_source);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualDeep(Stats{ .folds = 1, .bne_folds = 1, .bytes_saved = 5 }, result.stats);
    try std.testing.expectEqualStrings(
        \\    lda source
        \\    cmp #7
        \\    bne cmp_true
        \\cmp_false:
        \\    lda #0
        \\    sec
        \\    jmp bool_false
        \\cmp_true:
        \\    lda #1
        \\cmp_done:
        \\    sec
        \\bool_rhs:
        \\    sta result
        \\bool_false:
        \\    rts
        \\
    , result.assembly);
}

test "boolean retest folds inverse OR consumer with exact true and false destinations" {
    const input = try std.mem.replaceOwned(u8, std.testing.allocator, bne_source, "bne bool_rhs", "beq bool_rhs");
    defer std.testing.allocator.free(input);
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualDeep(Stats{ .folds = 1, .beq_folds = 1, .bytes_saved = 2 }, result.stats);
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "lda #0\n    sec\n    jmp bool_rhs") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "cmp_done:\n    sec\n    jmp bool_false\nbool_rhs:") != null);
}

test "boolean retest preserves whitespace comments and repeated pass identity" {
    const input = try std.mem.replaceOwned(u8, std.testing.allocator, bne_source, "    lda #1\n", "\tlda\t#1\n; preserve provenance\n\n");
    defer std.testing.allocator.free(input);
    const first = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(first.assembly);
    try std.testing.expectEqual(@as(usize, 1), first.stats.folds);
    try std.testing.expect(std.mem.indexOf(u8, first.assembly, "\tlda\t#1\n; preserve provenance\n\n") != null);
    const second = try rewrite(std.testing.allocator, first.assembly);
    defer std.testing.allocator.free(second.assembly);
    try std.testing.expectEqual(@as(usize, 0), second.stats.folds);
    try std.testing.expectEqualStrings(first.assembly, second.assembly);
}

test "boolean retest rejects external join observations duplicate labels and assembly" {
    for ([_][]const u8{ "jmp cmp_done", "bne cmp_done", "lda #<cmp_done", ".word cmp_done", "alias = cmp_done+1", "unknown cmp_done", "cmp_done:", "cmp_true:", "bool_rhs:", "; inline asm from ZeroPage line 1\nnop\n; end inline asm" }) |extra| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}", .{ bne_source, extra });
        defer std.testing.allocator.free(input);
        const result = try rewrite(std.testing.allocator, input);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqual(@as(usize, 0), result.stats.folds);
        try std.testing.expectEqualStrings(input, result.assembly);
    }
}

test "boolean retest rejects malformed or value only materialization" {
    const changes = [_][2][]const u8{
        .{ "lda #0\n    jmp", "lda #2\n    jmp" },
        .{ "lda #1", "lda #255" },
        .{ "cmp_done:\n    cmp #0", "cmp_done:\n    cmp #1" },
        .{ "bne bool_rhs", "bmi bool_rhs" },
        .{ "jmp bool_false", "jmp (bool_false)" },
        .{ "cmp_done:\n    cmp #0", "cmp_done:\n    sta observed\n    cmp #0" },
        .{ "    cmp #0\n    bne bool_rhs\n    jmp bool_false", "    sta observed" },
        .{ "cmp_true:\n", "cmp_true:\nalias:\n" },
        .{ "bool_rhs:\n", "not_rhs:\n" },
    };
    for (changes) |change| {
        const input = try std.mem.replaceOwned(u8, std.testing.allocator, bne_source, change[0], change[1]);
        defer std.testing.allocator.free(input);
        const result = try rewrite(std.testing.allocator, input);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqual(@as(usize, 0), result.stats.folds);
        try std.testing.expectEqualStrings(input, result.assembly);
    }
}

test "boolean retest symbol proof handles expressions without substring aliasing" {
    const similar = try std.fmt.allocPrint(std.testing.allocator, "{s}\nlda cmp_done_extra\n; cmp_done mention\n", .{bne_source});
    defer std.testing.allocator.free(similar);
    const result = try rewrite(std.testing.allocator, similar);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqual(@as(usize, 1), result.stats.folds);
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    // Allocating Writer represents its backing allocator failure as WriteFailed.
    const result = rewrite(allocator, bne_source) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer allocator.free(result.assembly);
}
test "boolean retest allocation failures release lines actions and output" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}
