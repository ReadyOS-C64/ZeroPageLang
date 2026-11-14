const std = @import("std");
const machine = @import("instruction.zig");
const layout = @import("branch_layout.zig");
pub const Stats = struct { folds: usize = 0, forward: usize = 0, backward: usize = 0, bytes_saved: usize = 0 };
pub const Result = struct { assembly: []u8, stats: Stats };
const Replacement = struct { inverse: machine.Op, target: []const u8 };

/// Retarget a short branch through a label-only entry to JMP. The original
/// jump stays for fallthrough and any other callers. No instruction moves.
pub fn threadBackedges(a: std.mem.Allocator, text: []const u8) !?[]u8 {
    var graph = try layout.parse(a, text);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    const nodes = graph.nodes.items;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var copied: usize = 0;
    for (nodes, 0..) |node, i| {
        if (node.zone != .code) continue;
        const branch = machine.Instruction.parse(node.text) orelse continue;
        if (!layout.conditional(branch.op)) continue;
        const entry = graph.target(branch.operand.direct.name) orelse continue;
        var j = entry;
        while (j < nodes.len and nodes[j].scope == node.scope and layout.label(nodes[j].text) != null) : (j += 1) {}
        if (j == nodes.len or nodes[j].scope != node.scope) continue;
        const jump = machine.Instruction.parse(nodes[j].text) orelse continue;
        if (jump.op != .jmp) continue;
        const target = graph.target(jump.operand.direct.name) orelse continue;
        if (target >= i or nodes[target].scope != node.scope) continue;
        const prefix = graph.maxBytes(target, i) orelse continue;
        if (prefix > 126) continue;
        for (graph.raw.items[copied..node.index]) |line| try out.writer.print("{s}\n", .{line});
        try out.writer.print("    {s} {s}\n", .{ @tagName(branch.op), jump.operand.direct.name });
        copied = node.index + 1;
    }
    if (copied == 0) return null;
    for (graph.raw.items[copied..], copied..) |line, index| {
        try out.writer.writeAll(line);
        if (index + 1 < graph.raw.items.len) try out.writer.writeByte('\n');
    }
    return try out.toOwnedSlice();
}

test "threaded backedges preserve the JMP entry and require signed branch range" {
    const a = std.testing.allocator;
    const head = "; zeropage_section_begin owner=function:f kind=code\nloop:\n";
    const ending = "    inc index\n    bne latch\n    inc index+1\nlatch:\nalias:\n    jmp loop\n; zeropage_section_end owner=function:f kind=code\n";
    for ([_]usize{ 123, 124 }) |padding| {
        var input: std.Io.Writer.Allocating = .init(a);
        defer input.deinit();
        try input.writer.writeAll(head);
        for (0..padding) |_| try input.writer.writeAll("    nop\n");
        try input.writer.writeAll(ending);
        const output = try threadBackedges(a, input.written());
        defer if (output) |result| a.free(result);
        if (padding == 123) {
            const expected = try std.mem.replaceOwned(u8, a, input.written(), "bne latch", "bne loop");
            defer a.free(expected);
            try std.testing.expectEqualStrings(expected, output orelse return error.ExpectedThreadedBranch);
        } else try std.testing.expect(output == null);
    }
    const work = try std.mem.replaceOwned(u8, a, head ++ ending, "alias:\n", "alias:\n    iny\n");
    defer a.free(work);
    const output = try threadBackedges(a, work);
    defer if (output) |result| a.free(result);
    try std.testing.expect(output == null);
}

fn inverse(op: machine.Op) ?machine.Op {
    return switch (op) {
        .bcc => .bcs,
        .bcs => .bcc,
        .beq => .bne,
        .bne => .beq,
        .bmi => .bpl,
        .bpl => .bmi,
        .bvc => .bvs,
        .bvs => .bvc,
        else => null,
    };
}
// Must be the LAST machine rewrite, after optional ZP allocation. With no
// origin/alignment/data directive inside the code region, all changes delete
// three-byte JMPs and preserve two-byte branches. Independent max-width bounds
// cover every valid NMOS instruction encoding, including later alias choices.
pub fn rewrite(a: std.mem.Allocator, text: []const u8) !Result {
    return rewriteInternal(a, text, false);
}

pub fn rewriteWithStackOverflowTrap(a: std.mem.Allocator, text: []const u8) !Result {
    return rewriteInternal(a, text, true);
}

fn rewriteInternal(a: std.mem.Allocator, text: []const u8, allow_stack_trap: bool) !Result {
    var analysis = if (allow_stack_trap) try layout.parseWithStackOverflowTrap(a, text) else try layout.parse(a, text);
    defer analysis.deinit(a);
    if (!analysis.complete) return .{ .assembly = try a.dupe(u8, text), .stats = .{} };
    const nodes = analysis.nodes.items;
    const replacements = try a.alloc(?Replacement, analysis.raw.items.len);
    defer a.free(replacements);
    @memset(replacements, null);
    const removed = try a.alloc(bool, analysis.raw.items.len);
    defer a.free(removed);
    @memset(removed, false);
    var stats: Stats = .{};
    for (nodes, 0..) |node, index| {
        if (node.zone != .code or index + 2 >= nodes.len) continue;
        const branch = machine.Instruction.parse(node.text) orelse continue;
        const inverted = inverse(branch.op) orelse continue;
        if (branch.operand != .direct or branch.operand.direct.offset != 0) continue;
        const jump_node = nodes[index + 1];
        if (jump_node.scope != node.scope) continue;
        const jump = machine.Instruction.parse(jump_node.text) orelse continue;
        if (jump.op != .jmp or jump.operand != .direct or jump.operand.direct.offset != 0) continue;
        const body = analysis.target(branch.operand.direct.name) orelse continue;
        var next = index + 2;
        var body_is_next = false;
        while (next < nodes.len and layout.label(nodes[next].text) != null and nodes[next].scope == node.scope) : (next += 1) {
            if (next == body) body_is_next = true;
        }
        if (!body_is_next) continue;
        const target = analysis.target(jump.operand.direct.name) orelse continue;
        if (nodes[target].zone != .code or nodes[target].scope != node.scope) continue;
        if (target > index + 1) {
            const upper = analysis.maxBytes(index + 2, target) orelse continue;
            if (upper > 127) continue;
            stats.forward += 1;
        } else {
            const prefix = analysis.maxBytes(target, index) orelse continue;
            if (prefix > 126) continue; // prefix + the branch's own two bytes
            stats.backward += 1;
        }
        replacements[node.index] = .{ .inverse = inverted, .target = jump.operand.direct.name };
        removed[jump_node.index] = true;
        stats.folds += 1;
        stats.bytes_saved += 3;
    }
    if (stats.folds == 0) return .{ .assembly = try a.dupe(u8, text), .stats = stats };
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    for (analysis.raw.items, 0..) |raw, index| {
        if (removed[index]) continue;
        if (replacements[index]) |r| {
            try out.writer.print("    {s} {s}", .{ @tagName(r.inverse), r.target });
        } else try out.writer.writeAll(raw);
        if (index + 1 < analysis.raw.items.len) try out.writer.writeByte('\n');
    }
    return .{ .assembly = try out.toOwnedSlice(), .stats = stats };
}
const sample =
    \\; zeropage_section_begin owner=function:f kind=code lifetime=static address=near
    \\f:
    \\    cmp #9
    \\    bcc yes
    \\; keep branch provenance
    \\    jmp no
    \\yes:
    \\    lda #1
    \\    rts
    \\no:
    \\    lda #0
    \\    rts
    \\; zeropage_section_end owner=function:f kind=code
    \\
;
test "short branch inverts predicate and removes only the absolute jump" {
    const result = try rewrite(std.testing.allocator, sample);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualDeep(Stats{ .folds = 1, .forward = 1, .bytes_saved = 3 }, result.stats);
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "    bcs no\n; keep branch provenance\nyes:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "jmp") == null);
}
test "short branch maps all eight NMOS predicates without producing flags" {
    for ([_][2][]const u8{ .{ "bcc", "bcs" }, .{ "bcs", "bcc" }, .{ "beq", "bne" }, .{ "bne", "beq" }, .{ "bmi", "bpl" }, .{ "bpl", "bmi" }, .{ "bvc", "bvs" }, .{ "bvs", "bvc" } }) |pair| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, sample, "bcc yes", tryWord(pair[0]));
        defer std.testing.allocator.free(source);
        const result = try rewrite(std.testing.allocator, source);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqual(@as(usize, 1), result.stats.folds);
        var target: [32]u8 = undefined;
        const expected = try std.fmt.bufPrint(&target, "{s} no", .{pair[1]});
        try std.testing.expect(std.mem.indexOf(u8, result.assembly, expected) != null);
    }
}
fn tryWord(comptime_dummy: []const u8) []const u8 {
    // Each value is a static canonical mnemonic; no allocated test text escapes.
    if (std.mem.eql(u8, comptime_dummy, "bcc")) return "bcc yes";
    if (std.mem.eql(u8, comptime_dummy, "bcs")) return "bcs yes";
    if (std.mem.eql(u8, comptime_dummy, "beq")) return "beq yes";
    if (std.mem.eql(u8, comptime_dummy, "bne")) return "bne yes";
    if (std.mem.eql(u8, comptime_dummy, "bmi")) return "bmi yes";
    if (std.mem.eql(u8, comptime_dummy, "bpl")) return "bpl yes";
    if (std.mem.eql(u8, comptime_dummy, "bvc")) return "bvc yes";
    return "bvs yes";
}
fn padded(a: std.mem.Allocator, count: usize, backward: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try out.writer.writeAll("; zeropage_section_begin owner=function:f kind=code\nf:\n");
    if (backward) try out.writer.writeAll("no:\n");
    if (!backward) try out.writer.writeAll("    cmp #9\n    bcc yes\n    jmp no\nyes:\n");
    for (0..count) |_| try out.writer.writeAll("    nop\n");
    if (backward) {
        try out.writer.writeAll("    cmp #9\n    bcc yes\n    jmp no\nyes:\n    rts\n");
    } else try out.writer.writeAll("    lda #1\n    rts\nno:\n    lda #0\n    rts\n");
    try out.writer.writeAll("; zeropage_section_end owner=function:f kind=code\n");
    return out.toOwnedSlice();
}
test "short branch proves exact forward127 and backward128 boundaries and declines beyond" {
    for ([_]struct { count: usize, back: bool, folds: usize }{
        .{ .count = 124, .back = false, .folds = 1 }, .{ .count = 125, .back = false, .folds = 0 },
        .{ .count = 124, .back = true, .folds = 1 },  .{ .count = 125, .back = true, .folds = 0 },
    }) |row| {
        const source = try padded(std.testing.allocator, row.count, row.back);
        defer std.testing.allocator.free(source);
        const result = try rewrite(std.testing.allocator, source);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqual(row.folds, result.stats.folds);
        if (row.folds == 0) try std.testing.expectEqualStrings(source, result.assembly);
    }
}
test "short branch conservatively counts forced absolute and unknown ZP memory as three bytes" {
    for ([_]usize{ 42, 43 }) |count| {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        for (0..count) |_| try out.writer.writeAll("    lda @w cell\n");
        const source0 = try std.mem.replaceOwned(u8, std.testing.allocator, sample, "    lda #1\n", out.written());
        defer std.testing.allocator.free(source0);
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ source0, "cell = address($02)\n" });
        defer std.testing.allocator.free(source);
        const result = try rewrite(std.testing.allocator, source);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqual(@as(usize, if (count == 42) 1 else 0), result.stats.folds);
    }
}
test "short branch rejects opaque or unknown control and data targets globally" {
    for ([_][]const u8{
        "jmp $2000", "jsr $ffd2", "jmp yes+1",                "jmp (pointer)",                                     "bne missing", "brk", "rti",
        "JMP YES",   "YES:",      "jmp raw\nraw:\n.byte $60", "; inline asm from ZeroPage\nnop\n; end inline asm",
    }) |extra| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ sample, extra, "\n" });
        defer std.testing.allocator.free(source);
        const result = try rewrite(std.testing.allocator, source);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqual(@as(usize, 0), result.stats.folds);
        try std.testing.expectEqualStrings(source, result.assembly);
    }
}

test "stack trap opt-in recognizes only the compiler runtime section and still bounds branches" {
    const a = std.testing.allocator;
    const trap = "; zeropage_section_begin owner=runtime kind=code\n" ++
        "zeropage_stack_overflow_trap:\n    brk\n    jmp zeropage_stack_overflow_trap\n" ++
        "; zeropage_section_end owner=runtime kind=code\n";
    for ([_]usize{ 124, 125 }) |count| {
        const body = try padded(a, count, false);
        defer a.free(body);
        const source = try std.mem.concat(a, u8, &.{ body, trap });
        defer a.free(source);
        const old = try rewrite(a, source);
        defer a.free(old.assembly);
        try std.testing.expectEqualStrings(source, old.assembly);
        const result = try rewriteWithStackOverflowTrap(a, source);
        defer a.free(result.assembly);
        try std.testing.expectEqual(@as(usize, if (count == 124) 1 else 0), result.stats.folds);
        try std.testing.expect(std.mem.endsWith(u8, result.assembly, trap));
    }
    for ([_][2][]const u8{
        .{ "owner=runtime", "owner=function:fault" },
        .{ "    brk\n", "    rti\n" },
        .{ "    brk\n", "    brk\n    nop\n" },
        .{ "jmp zeropage_stack_overflow_trap", "jmp zeropage_stack_overflow_trap+1" },
        .{ "; zeropage_section_end", "    nop\n; zeropage_section_end" },
    }) |change| {
        const malformed = try std.mem.replaceOwned(u8, a, trap, change[0], change[1]);
        defer a.free(malformed);
        const source = try std.mem.concat(a, u8, &.{ sample, malformed });
        defer a.free(source);
        const result = try rewriteWithStackOverflowTrap(a, source);
        defer a.free(result.assembly);
        try std.testing.expectEqualStrings(source, result.assembly);
    }
}
test "short branch declines code-byte address observations and alternate CPU modes" {
    for ([_][]const u8{
        "observed = f+2", ".word F+2",     "lda #<f+2", "lda f+2",
        ".cpu \"65816\"", ".CPU \"6502\"", ".al",       ".xl",
    }) |extra| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ sample, extra, "\n" });
        defer std.testing.allocator.free(source);
        const result = try rewrite(std.testing.allocator, source);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqual(@as(usize, 0), result.stats.folds);
        try std.testing.expectEqualStrings(source, result.assembly);
    }
}

test "stack branch counts only proved zero-page pointer operands at the signed limit" {
    const a = std.testing.allocator;
    const trap = "; zeropage_section_begin owner=runtime kind=code\n" ++
        "zeropage_stack_overflow_trap:\n    brk\n    jmp zeropage_stack_overflow_trap\n" ++
        "; zeropage_section_end owner=runtime kind=code\n";
    for ([_]struct { equate: []const u8, operand: []const u8, padding: usize, folds: usize }{
        .{ .equate = "zeropage_stack_fp = $f9", .operand = "zeropage_stack_fp", .padding = 122, .folds = 1 },
        .{ .equate = "zeropage_stack_fp = $f9", .operand = "zeropage_stack_fp+1", .padding = 122, .folds = 1 },
        .{ .equate = "zeropage_stack_fp = $fe", .operand = "(zeropage_stack_fp),y", .padding = 122, .folds = 1 },
        .{ .equate = "zeropage_stack_fp = $f9", .operand = "zeropage_stack_fp", .padding = 123, .folds = 0 },
        .{ .equate = "zeropage_stack_fp = $ff", .operand = "zeropage_stack_fp+1", .padding = 122, .folds = 0 },
        .{ .equate = "zeropage_stack_fp = $01f9", .operand = "zeropage_stack_fp", .padding = 122, .folds = 0 },
        .{ .equate = "zeropage_stack_fp = $f9", .operand = "@w zeropage_stack_fp", .padding = 122, .folds = 0 },
        .{ .equate = "zeropage_stack_fp = $f9\nZEROPage_stack_fp = $f9", .operand = "zeropage_stack_fp", .padding = 122, .folds = 0 },
    }) |row| {
        const body = try padded(a, row.padding, false);
        defer a.free(body);
        const line = try std.fmt.allocPrint(a, "    lda {s}\n    lda #1\n", .{row.operand});
        defer a.free(line);
        const expanded = try std.mem.replaceOwned(u8, a, body, "    lda #1\n", line);
        defer a.free(expanded);
        const source = try std.mem.concat(a, u8, &.{ row.equate, "\n", expanded, trap });
        defer a.free(source);
        const result = try rewriteWithStackOverflowTrap(a, source);
        defer a.free(result.assembly);
        try std.testing.expectEqual(row.folds, result.stats.folds);
    }
}
test "short branch does not normalize invalid forced width control operands" {
    for ([_][2][]const u8{ .{ "bcc yes", "bcc @w yes" }, .{ "jmp no", "jmp @w @w no" }, .{ "jmp no", "jmp @w no" } }) |change| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, sample, change[0], change[1]);
        defer std.testing.allocator.free(source);
        const result = try rewrite(std.testing.allocator, source);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqual(@as(usize, 0), result.stats.folds);
        try std.testing.expectEqualStrings(source, result.assembly);
    }
}
test "short branch preserves label entries and refuses to match across section scopes" {
    const with_entry = try std.mem.replaceOwned(u8, std.testing.allocator, sample, "    jmp no\n", "mid_entry:\n    jmp no\n");
    defer std.testing.allocator.free(with_entry);
    const separate = try std.mem.replaceOwned(u8, std.testing.allocator, sample, "yes:\n", "; zeropage_section_end owner=function:f kind=code\n; zeropage_section_begin owner=function:f kind=code\nyes:\n");
    defer std.testing.allocator.free(separate);
    for ([_][]const u8{ with_entry, separate }) |source| {
        const result = try rewrite(std.testing.allocator, source);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqual(@as(usize, 0), result.stats.folds);
        try std.testing.expectEqualStrings(source, result.assembly);
    }
    const first = try rewrite(std.testing.allocator, sample);
    defer std.testing.allocator.free(first.assembly);
    const second = try rewrite(std.testing.allocator, first.assembly);
    defer std.testing.allocator.free(second.assembly);
    try std.testing.expectEqual(@as(usize, 0), second.stats.folds);
    try std.testing.expectEqualStrings(first.assembly, second.assembly);
}
fn allocationProof(a: std.mem.Allocator) !void {
    const result = rewrite(a, sample) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer a.free(result.assembly);
    try std.testing.expectEqual(@as(usize, 1), result.stats.folds);
}
test "short branch owns all results and releases every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProof, .{});
}

test "short branch bounds numeric indexed lifecycle operations without claiming memory effects" {
    for ([_]usize{ 42, 43 }) |count| {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        for (0..count) |_| try out.writer.writeAll("    lda $02,x\n");
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, sample, "    lda #1\n", out.written());
        defer std.testing.allocator.free(source);
        const result = try rewrite(std.testing.allocator, source);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqual(@as(usize, if (count == 42) 1 else 0), result.stats.folds);
        try std.testing.expectEqual(count, std.mem.count(u8, result.assembly, "    lda $02,x\n"));
        if (count == 43) try std.testing.expectEqualStrings(source, result.assembly);
    }
    for ([_][]const u8{ "lda 2*x", "lda $02,x : .fill 256", "lda $02,xx" }) |operand| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, sample, "lda #1", operand);
        defer std.testing.allocator.free(source);
        const result = try rewrite(std.testing.allocator, source);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqual(@as(usize, 0), result.stats.folds);
        try std.testing.expectEqualStrings(source, result.assembly);
    }
}

test "short branch does not treat symbol named a as an implied one byte instruction" {
    for ([_]usize{ 42, 43 }) |count| {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        for (0..count) |_| try out.writer.writeAll("    lda a\n");
        const body_source = try std.mem.replaceOwned(u8, std.testing.allocator, sample, "    lda #1\n", out.written());
        defer std.testing.allocator.free(body_source);
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ body_source, "a=$c100\n" });
        defer std.testing.allocator.free(source);
        const result = try rewrite(std.testing.allocator, source);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqual(@as(usize, if (count == 42) 1 else 0), result.stats.folds);
        try std.testing.expectEqual(count, std.mem.count(u8, result.assembly, "    lda a\n"));
        if (count == 43) try std.testing.expectEqualStrings(source, result.assembly);
    }
}

test "short branch bounds parenthesized absolute expressions as three bytes" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for (0..43) |_| try out.writer.writeAll("    lda (cell)+0\n");
    const before = try std.mem.replaceOwned(u8, std.testing.allocator, sample, "    lda #1\n", out.written());
    defer std.testing.allocator.free(before);
    const source = try std.mem.concat(std.testing.allocator, u8, &.{ before, "cell=$c100\n" });
    defer std.testing.allocator.free(source);
    const result = try rewrite(std.testing.allocator, source);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqual(@as(usize, 0), result.stats.folds);
    try std.testing.expectEqualStrings(source, result.assembly);
}
