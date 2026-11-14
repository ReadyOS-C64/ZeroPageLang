const std = @import("std");
pub const Stats = struct { folds: usize = 0, inverted: usize = 0, bytes_saved: usize = 0 };
pub const Result = struct { assembly: []u8, stats: Stats };
const machine = @import("instruction.zig");
const Zone = enum { code, data, unsectioned };
const Line = struct { index: usize, text: []const u8, zone: Zone = .unsectioned, scope: usize = 0 };
const Section = struct { owner: []const u8, kind: []const u8 };
const Action = enum { keep, drop, normal, inverted, one_with_sec };
fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}
fn identifierByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}
fn symbol(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| if (!identifierByte(c)) return false;
    return true;
}
fn label(s: []const u8) ?[]const u8 {
    if (s.len < 2 or s[s.len - 1] != ':') return null;
    return if (symbol(s[0 .. s.len - 1])) s[0 .. s.len - 1] else null;
}
fn operand(s: []const u8, op: []const u8) ?[]const u8 {
    const split = std.mem.indexOfAny(u8, s, " \t") orelse return null;
    if (!std.mem.eql(u8, s[0..split], op)) return null;
    return trim(s[split..]);
}
fn immediate(s: []const u8, op: []const u8, value: []const u8) bool {
    return std.mem.eql(u8, operand(s, op) orelse return false, value);
}
fn direct(s: []const u8, op: []const u8) ?[]const u8 {
    const v = operand(s, op) orelse return null;
    return if (symbol(v)) v else null;
}
fn uniqueInternal(lines: []const Line, name: []const u8) bool {
    var definitions: usize = 0;
    var references: usize = 0;
    for (lines) |l| {
        if (label(l.text)) |n| if (std.ascii.eqlIgnoreCase(n, name)) {
            definitions += 1;
            continue;
        };
        var i: usize = 0;
        while (i < l.text.len) {
            if (!identifierByte(l.text[i])) {
                i += 1;
                continue;
            }
            const first = i;
            while (i < l.text.len and identifierByte(l.text[i])) : (i += 1) {}
            if (std.ascii.eqlIgnoreCase(l.text[first..i], name)) references += 1;
        }
    }
    return definitions == 1 and references == 1;
}
fn section(text: []const u8) ?Section {
    var owner: ?[]const u8 = null;
    var kind: ?[]const u8 = null;
    var fields = std.mem.tokenizeAny(u8, text, " \t");
    while (fields.next()) |field| {
        if (std.mem.startsWith(u8, field, "owner=")) {
            if (owner != null or field.len == 6) return null;
            owner = field[6..];
        } else if (std.mem.startsWith(u8, field, "kind=")) {
            if (kind != null or field.len == 5) return null;
            kind = field[5..];
        }
    }
    return .{ .owner = owner orelse return null, .kind = kind orelse return null };
}
fn conditional(op: machine.Op) bool {
    return switch (op) {
        .bcc, .bcs, .beq, .bne, .bmi, .bpl, .bvc, .bvs => true,
        else => false,
    };
}
fn uniqueLabel(lines: []const Line, name: []const u8) ?usize {
    var found: ?usize = null;
    for (lines, 0..) |line, index| if (label(line.text)) |defined| {
        if (!std.ascii.eqlIgnoreCase(defined, name)) continue;
        if (found != null) return null;
        found = index;
    };
    return found;
}
fn looksControl(text: []const u8) bool {
    const end = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
    for ([_][]const u8{ "jmp", "jsr", "bcc", "bcs", "beq", "bne", "bmi", "bpl", "bvc", "bvs", "brk", "rti" }) |op|
        if (std.ascii.eqlIgnoreCase(text[0..end], op)) return true;
    return false;
}
// Same conservative control boundary as branch_A: all explicit control targets
// are unique named code entries, never numeric, offset, indirect or raw data.
fn controlsKnown(a: std.mem.Allocator, lines: []const Line) !bool {
    var pending: std.ArrayList(usize) = .empty;
    defer pending.deinit(a);
    for (lines) |line| {
        const inst = machine.Instruction.parse(line.text) orelse {
            if (looksControl(line.text)) return false;
            continue;
        };
        if (inst.op == .brk or inst.op == .rti) return false;
        if (inst.op != .jmp and inst.op != .jsr and !conditional(inst.op)) continue;
        if (inst.operand != .direct or inst.operand.direct.offset != 0) return false;
        try pending.append(a, uniqueLabel(lines, inst.operand.direct.name) orelse return false);
    }
    const visited = try a.alloc(bool, lines.len);
    defer a.free(visited);
    @memset(visited, false);
    while (pending.pop()) |index| {
        if (index >= lines.len) return false;
        if (visited[index]) continue;
        visited[index] = true;
        const line = lines[index];
        if (line.zone == .data) return false;
        if (label(line.text) != null) {
            try pending.append(a, index + 1);
            continue;
        }
        if (line.zone == .code) continue;
        const inst = machine.Instruction.parse(line.text) orelse return false;
        if (inst.op == .rts) continue;
        if (inst.op == .jmp or inst.op == .jsr or conditional(inst.op)) {
            try pending.append(a, uniqueLabel(lines, inst.operand.direct.name).?);
            if (inst.op == .jmp) continue;
        }
        try pending.append(a, index + 1);
    }
    return true;
}
fn unchanged(a: std.mem.Allocator, text: []const u8) !Result {
    return .{ .assembly = try a.dupe(u8, text), .stats = .{} };
}
fn match(lines: []const Line, first: usize) ?bool {
    if (lines.len - first < 9) return null;
    const g = lines[first .. first + 9];
    if (g[0].zone == .data) return null;
    for (g) |line| if (line.scope != g[0].scope or line.zone != g[0].zone) return null;
    if (!immediate(g[0].text, "cmp", "#0") or !immediate(g[4].text, "lda", "#1") or !immediate(g[7].text, "lda", "#0")) return null;
    const zero = direct(g[1].text, "beq");
    const yes = zero orelse direct(g[1].text, "bne") orelse return null;
    const no = direct(g[2].text, "jmp") orelse return null;
    const done = direct(g[5].text, "jmp") orelse return null;
    if (!std.mem.eql(u8, label(g[3].text) orelse return null, yes) or
        !std.mem.eql(u8, label(g[6].text) orelse return null, no) or
        !std.mem.eql(u8, label(g[8].text) orelse return null, done)) return null;
    if (!uniqueInternal(lines, yes) or !uniqueInternal(lines, no) or !uniqueInternal(lines, done)) return null;
    return zero != null;
}
/// CMP #1 puts (A != 0) in C for every input byte. LDA/ROL produces that
/// canonical bit without arithmetic or a decimal-mode premise. For inversion,
/// initialize zero and branch over LDA #1 / SEC when the input was nonzero.
/// The shorter ROL/EOR/SEC inverse is slower for nonzero inputs with live C;
/// keep this faster branch form instead. Both forms restore CMP #0's C=1;
/// other final CPU state and physical RAM are identical. All three original
/// targets must have no outside entry/address observations; keep their order.
pub fn rewrite(a: std.mem.Allocator, text: []const u8) !Result {
    if (std.mem.indexOf(u8, text, "; inline asm") != null) return .{ .assembly = try a.dupe(u8, text), .stats = .{} };
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    var significant: std.ArrayList(Line) = .empty;
    defer significant.deinit(a);
    var active: ?Section = null;
    var scope: usize = 0;
    var next_scope: usize = 0;
    var split = std.mem.splitScalar(u8, text, '\n');
    while (split.next()) |raw| {
        const index = lines.items.len;
        try lines.append(a, raw);
        const s = trim(raw);
        if (std.mem.startsWith(u8, s, "; zeropage_section_")) {
            const marker = section(s) orelse return unchanged(a, text);
            if (std.mem.startsWith(u8, s, "; zeropage_section_begin ")) {
                if (active != null) return unchanged(a, text);
                active = marker;
                next_scope += 1;
                scope = next_scope;
            } else if (std.mem.startsWith(u8, s, "; zeropage_section_end ")) {
                const prior = active orelse return unchanged(a, text);
                if (!std.mem.eql(u8, prior.owner, marker.owner) or !std.mem.eql(u8, prior.kind, marker.kind)) return unchanged(a, text);
                active = null;
                scope = 0;
            } else return unchanged(a, text);
            continue;
        }
        if (s.len == 0 or s[0] == ';') continue;
        const zone: Zone = if (active) |current| (if (std.mem.eql(u8, current.kind, "code")) .code else .data) else .unsectioned;
        if (zone == .code and label(s) == null and machine.Instruction.parse(s) == null) return unchanged(a, text);
        try significant.append(a, .{ .index = index, .text = s, .zone = zone, .scope = scope });
    }
    if (active != null or !try controlsKnown(a, significant.items)) return unchanged(a, text);
    const actions = try a.alloc(Action, lines.items.len);
    defer a.free(actions);
    @memset(actions, .keep);
    const targets = try a.alloc(?[]const u8, lines.items.len);
    defer a.free(targets);
    @memset(targets, null);
    var stats: Stats = .{};
    var i: usize = 0;
    while (i < significant.items.len) : (i += 1) {
        const inverted = match(significant.items, i) orelse continue;
        const g = significant.items[i .. i + 9];
        actions[g[0].index] = if (inverted) .inverted else .normal;
        for ([_]usize{ 1, 2, 4, 5, 7 }) |j| actions[g[j].index] = .drop;
        if (inverted) {
            targets[g[0].index] = direct(g[2].text, "jmp").?;
            actions[g[4].index] = .one_with_sec;
        }
        stats.folds += 1;
        stats.inverted += @intFromBool(inverted);
        stats.bytes_saved += if (inverted) 5 else 8;
        i += 8;
    }
    if (stats.folds == 0) return .{ .assembly = try a.dupe(u8, text), .stats = stats };
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    for (lines.items, actions, 0..) |raw, action, index| {
        switch (action) {
            .keep => try out.writer.writeAll(raw),
            .drop => continue,
            .normal => try out.writer.writeAll("    cmp #1\n    lda #0\n    rol\n    sec"),
            .inverted => try out.writer.print("    cmp #1\n    lda #0\n    bcs {s}", .{targets[index].?}),
            .one_with_sec => try out.writer.print("{s}\n    sec", .{raw}),
        }
        if (index + 1 < lines.items.len) try out.writer.writeByte('\n');
    }
    return .{ .assembly = try out.toOwnedSlice(), .stats = stats };
}
const input =
    \\    cmp #0
    \\    beq zero
    \\    jmp nonzero
    \\zero:
    \\    lda #1
    \\    jmp done
    \\nonzero:
    \\    lda #0
    \\done:
    \\    sta output
    \\    rts
    \\
;
test "zero materializer retains all labels and exact final carry" {
    const r = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expectEqual(Stats{ .folds = 1, .inverted = 1, .bytes_saved = 5 }, r.stats);
    try std.testing.expectEqualStrings(
        \\    cmp #1
        \\    lda #0
        \\    bcs nonzero
        \\zero:
        \\    lda #1
        \\    sec
        \\nonzero:
        \\done:
        \\    sta output
        \\    rts
        \\
    , r.assembly);
}
test "nonzero materializer handles arbitrary source bytes without boolean types" {
    const source = try std.mem.replaceOwned(u8, std.testing.allocator, input, "beq zero", "bne zero");
    defer std.testing.allocator.free(source);
    const r = try rewrite(std.testing.allocator, source);
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expectEqual(Stats{ .folds = 1, .bytes_saved = 8 }, r.stats);
    try std.testing.expect(std.mem.indexOf(u8, r.assembly, "eor") == null);
    const again = try rewrite(std.testing.allocator, r.assembly);
    defer std.testing.allocator.free(again.assembly);
    try std.testing.expectEqual(@as(usize, 0), again.stats.folds);
    try std.testing.expectEqualStrings(r.assembly, again.assembly);
}
test "zero materializer pins every outside target observation and opaque assembly" {
    const extras = [_][]const u8{
        "jmp zero",                                          "bne nonzero",  "lda #<done",  ".word zero+1",
        "alias = nonzero",                                   "unknown done", "zero:",       "nonzero:",
        "done:",                                             "jmp ZERO",     "bne NonZero", "lda #<DONE",
        "alias = ZeRo+1",                                    "ZERO:",        "Nonzero:",    "DONE:",
        "; inline asm from ZeroPage\nnop\n; end inline asm",
    };
    for (extras) |extra| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n", .{ input, extra });
        defer std.testing.allocator.free(source);
        const r = try rewrite(std.testing.allocator, source);
        defer std.testing.allocator.free(r.assembly);
        try std.testing.expectEqual(@as(usize, 0), r.stats.folds);
        try std.testing.expectEqualStrings(source, r.assembly);
    }
}
test "zero materializer rejects malformed arms entries and nonzero comparisons" {
    const changes = [_][2][]const u8{
        .{ "cmp #0", "cmp #1" },                       .{ "beq zero", "bcs zero" },
        .{ "lda #1", "lda #2" },                       .{ "lda #0", "lda #255" },
        .{ "jmp nonzero", "jmp (nonzero)" },           .{ "zero:\n", "zero:\nalias:\n" },
        .{ "jmp done", "sta observed\n    jmp done" }, .{ "nonzero:\n", "nonzero:\n    bit observed\n" },
    };
    for (changes) |change| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, input, change[0], change[1]);
        defer std.testing.allocator.free(source);
        const r = try rewrite(std.testing.allocator, source);
        defer std.testing.allocator.free(r.assembly);
        try std.testing.expectEqual(@as(usize, 0), r.stats.folds);
        try std.testing.expectEqualStrings(source, r.assembly);
    }
}
test "zero materializer preserves comments whitespace and complete symbol names" {
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, input, "    lda #1", "\tlda\t#1\n; keep arm provenance");
    defer std.testing.allocator.free(changed);
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\nlda zero_extra\n; zero nonzero done\n", .{changed});
    defer std.testing.allocator.free(source);
    const r = try rewrite(std.testing.allocator, source);
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expectEqual(@as(usize, 1), r.stats.folds);
    try std.testing.expect(std.mem.indexOf(u8, r.assembly, "; keep arm provenance") != null);
}
fn allocationProof(a: std.mem.Allocator) !void {
    const r = rewrite(a, input) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer a.free(r.assembly);
    try std.testing.expectEqual(@as(usize, 1), r.stats.folds);
}
test "zero materializer releases every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProof, .{});
}
