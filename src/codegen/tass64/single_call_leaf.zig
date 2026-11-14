const std = @import("std");
const ast = @import("../../ast.zig");

const calls = @import("call_argument_proof.zig");
const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const reachability = @import("reachability.zig");
const storage = @import("storage_model.zig");

const Leaf = struct {
    name: []const u8,
    section_start: usize,
    section_end: usize,
    body: []const []const u8,
    call: usize,
    upper_bytes: usize,
};

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn onlyCall(graph: layout.Analysis, name: []const u8) ?usize {
    var call: ?usize = null;
    for (graph.nodes.items, 0..) |node, index| {
        const inst = machine.Instruction.parse(node.text) orelse continue;
        if (inst.op != .jsr and inst.op != .jmp and !layout.conditional(inst.op)) continue;
        if (inst.operand != .direct or !std.ascii.eqlIgnoreCase(inst.operand.direct.name, name)) continue;
        if (call != null or node.zone != .code or !calls.exact(node.text, .jsr, name, 0)) return null;
        call = index;
    }
    return call;
}

fn noFallthrough(nodes: []const layout.Line) bool {
    var index = nodes.len;
    while (index != 0) {
        index -= 1;
        const node = nodes[index];
        if (node.zone == .data) continue;
        if (layout.label(node.text) != null) return false;
        const inst = machine.Instruction.parse(node.text) orelse continue;
        return same(node.text, "rts") or inst.op == .jmp;
    }
    return false;
}

fn ordinaryOperand(lines: []const []const u8, model: storage.Model, managed: bool, inst: machine.Instruction, text: []const u8) bool {
    return switch (inst.operand) {
        .none => same(text, @tagName(inst.op)),
        .immediate => |value| (machine.integer(value) orelse return false) <= 255,
        .direct => |ref| model.resolve(ref, 1) != null or
            (managed and (storage.claimedScratch(lines, ref) or model.ordinaryStorage(lines, ref, 1, true))),
        else => false,
    };
}

fn findLeaf(graph: layout.Analysis, model: storage.Model, managed: bool, name: []const u8) ?Leaf {
    const call = onlyCall(graph, name) orelse return null;
    const entry = graph.target(name) orelse return null;
    const nodes = graph.nodes.items;
    const lines = graph.raw.items;
    const head = nodes[entry];
    if (head.zone != .code or nodes[call].scope == head.scope or head.index == 0 or
        !same(storage.sectionOwner(trim(lines[head.index - 1]), "code") orelse return null, name) or
        !noFallthrough(nodes[0..entry])) return null;

    var depth: usize = 0;
    var end = entry + 1;
    while (end < nodes.len and nodes[end].scope == head.scope) : (end += 1) {
        const text = nodes[end].text;
        if (same(text, "rts")) break;
        if (same(text, "pha")) {
            depth += 1;
            continue;
        }
        if (same(text, "pla")) {
            if (depth == 0) return null;
            depth -= 1;
            continue;
        }
        const inst = machine.Instruction.parse(text) orelse return null;
        const effects = inst.effects();
        if (effects.barrier or effects.memory == .stack or (effects.reads | effects.writes) & machine.sp != 0 or
            !ordinaryOperand(lines, model, managed, inst, text)) return null;
    }
    if (depth != 0 or end == nodes.len or nodes[end].scope != head.scope or
        (end + 1 < nodes.len and nodes[end + 1].scope == head.scope)) return null;
    var section_end = nodes[end].index + 1;
    while (section_end < lines.len) : (section_end += 1) {
        const line = trim(lines[section_end]);
        if (std.mem.startsWith(u8, line, "; zeropage_section_end ")) break;
        if (line.len != 0 and line[0] != ';') return null;
    }
    if (section_end == lines.len) return null;
    return .{
        .name = name,
        .section_start = head.index - 1,
        .section_end = section_end + 1,
        .body = lines[head.index + 1 .. nodes[end].index],
        .call = call,
        .upper_bytes = graph.maxBytes(entry + 1, end) orelse return null,
    };
}

const BranchSpan = struct {
    first: usize,
    end: usize,
    remaining: usize,

    fn includes(self: BranchSpan, index: usize) bool {
        return self.first <= index and index < self.end;
    }
};

fn branchSpans(a: std.mem.Allocator, graph: layout.Analysis) !std.ArrayList(BranchSpan) {
    var spans: std.ArrayList(BranchSpan) = .empty;
    errdefer spans.deinit(a);
    for (graph.nodes.items, 0..) |node, index| {
        const inst = machine.Instruction.parse(node.text) orelse continue;
        if (!layout.conditional(inst.op) or inst.operand != .direct) continue;
        const target = graph.target(inst.operand.direct.name) orelse continue;
        const forward = target > index;
        const first = if (forward) index + 1 else target;
        const end = if (forward) target else index;
        const limit: usize = if (forward) 127 else 126;
        try spans.append(a, .{ .first = first, .end = end, .remaining = limit -| (graph.maxBytes(first, end) orelse limit) });
    }
    return spans;
}

fn reserveBranchGrowth(spans: []BranchSpan, leaf: Leaf) bool {
    // The call is three bytes. Charge every earlier accepted expansion to
    // every branch it crosses, without counting any unrelated deletion.
    const growth = leaf.upper_bytes -| 3;
    for (spans) |span| if (span.includes(leaf.call) and growth > span.remaining) return false;
    for (spans) |*span| if (span.includes(leaf.call)) {
        span.remaining -= growth;
    };
    return true;
}

const Edit = struct {
    first: usize,
    end: usize,
    insertion: ?Leaf = null,

    fn lessThan(_: void, lhs: Edit, rhs: Edit) bool {
        return lhs.first < rhs.first;
    }
};

/// Inline straight-line, single-call leaves after allocation and other
/// machine passes. Their static frames still have program lifetime.
pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.functions.len != 0 or program.functions.len < 2 or
        std.mem.indexOf(u8, assembly, "    jsr ") == null or
        std.mem.indexOf(u8, assembly, "zeropage_test6502_expect_stack_") != null) return null;
    for (program.functions) |function| {
        if (function.exported and !same(function.name, "main")) return null;
    }

    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    var model = storage.Model.init(a);
    defer model.deinit();
    const lines = graph.raw.items;
    try model.collectWithPromotedParameters(assembly, lines);
    var spans = try branchSpans(a, graph);
    defer spans.deinit(a);
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(a);
    for (program.functions) |function| {
        if (reachability.rootReason(program, function) != null) continue;
        const leaf = findLeaf(graph, model, options.zero_page.declared, function.name) orelse continue;
        if (!reserveBranchGrowth(spans.items, leaf)) continue;
        const call_line = graph.nodes.items[leaf.call].index;
        try edits.append(a, .{ .first = leaf.section_start, .end = leaf.section_end });
        try edits.append(a, .{ .first = call_line, .end = call_line + 1, .insertion = leaf });
    }
    if (edits.items.len == 0 or !try image.permitsLocalShrink(a, graph, program)) return null;

    std.mem.sort(Edit, edits.items, {}, Edit.lessThan);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const w = &out.writer;
    var copied: usize = 0;
    for (edits.items) |edit| {
        if (edit.first < copied) return null;
        for (lines[copied..edit.first]) |line| try w.print("{s}\n", .{line});
        if (edit.insertion) |leaf| {
            try w.print("; zeropage_inline_begin function={s}\n", .{leaf.name});
            for (leaf.body) |line| try w.print("{s}\n", .{line});
            try w.print("; zeropage_inline_end function={s}\n", .{leaf.name});
        }
        copied = edit.end;
    }
    for (lines[copied..], copied..) |line, i| {
        try w.writeAll(line);
        if (i + 1 < lines.len) try w.writeByte('\n');
    }
    return try out.toOwnedSlice();
}

const parser = @import("../../parser.zig");
const test_source =
    \\fn leaf(value: u8) u8 { return value + 1; }
    \\export fn main() void { _ = leaf(4); }
;
const caller =
    \\* = $2000
    \\; zeropage_section_begin owner=function:main kind=code lifetime=static address=near
    \\main:
    \\    lda #4
    \\    sta leaf_value
    \\    jsr leaf
    \\    rts
    \\; zeropage_section_end owner=function:main kind=code
    \\
;
const test_leaf =
    \\; zeropage_section_begin owner=function:leaf kind=code lifetime=static address=near
    \\leaf:
    \\    lda leaf_value
    \\    pha
    \\    ldx #7
    \\    pla
    \\    clc
    \\    adc #1
    \\    rts
    \\; zeropage_section_end owner=function:leaf kind=code
    \\; zeropage_section_begin owner=function:leaf kind=static_frame lifetime=static address=near
    \\leaf_value:
    \\    .byte 0
    \\; zeropage_section_end owner=function:leaf kind=static_frame
    \\
;

test "single call leaf moves balanced code and retains the static frame" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, test_source);
    defer parsed.deinit(a);
    const result = (try rewrite(a, parsed.program, caller ++ test_leaf)) orelse return error.ExpectedInline;
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "    sta leaf_value\n; zeropage_inline_begin function=leaf\n    lda leaf_value\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "    adc #1\n; zeropage_inline_end function=leaf\n    rts\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\nleaf:\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\nleaf_value:\n    .byte 0\n") != null);
}

test "single call leaf checks the expanded forward and backward relative branch span" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, test_source);
    defer parsed.deinit(a);
    for ([_]bool{ false, true }) |backward| {
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        const w = &out.writer;
        for ([_]usize{ 121, 122 }) |padding| {
            out.clearRetainingCapacity();
            try w.writeAll(caller[0..std.mem.indexOf(u8, caller, "    lda").?]);
            if (backward) try w.writeAll("near:\n") else try w.writeAll("    bne near\n");
            try w.writeAll("    jsr leaf\n");
            for (0..padding) |_| try w.writeAll("    nop\n");
            if (backward) try w.writeAll("    bne near\n") else try w.writeAll("near:\n");
            try w.writeAll(caller[std.mem.indexOf(u8, caller, "    rts").?..]);
            try w.writeAll(test_leaf);
            // The replacement is 10 bytes at the conservative encoded bound.
            const result = try rewrite(a, parsed.program, out.written());
            defer if (result) |text| a.free(text);
            try std.testing.expect(result == null);
        }
        out.clearRetainingCapacity();
        try w.writeAll(caller[0..std.mem.indexOf(u8, caller, "    lda").?]);
        if (backward) try w.writeAll("near:\n") else try w.writeAll("    bne near\n");
        try w.writeAll("    jsr leaf\n");
        for (0..(if (backward) @as(usize, 116) else 117)) |_| try w.writeAll("    nop\n");
        if (backward) try w.writeAll("    bne near\n") else try w.writeAll("near:\n");
        try w.writeAll(caller[std.mem.indexOf(u8, caller, "    rts").?..]);
        try w.writeAll(test_leaf);
        const result = (try rewrite(a, parsed.program, out.written())) orelse return error.ExpectedInline;
        defer a.free(result);
    }
}

test "single call leaf retains observed entries and live caller stack" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, test_source);
    defer parsed.deinit(a);
    for ([_][2][]const u8{
        .{ "    lda #4", "    jsr leaf\n    lda #4" },
        .{ "    lda #4", "    lda #<leaf" },
        .{ "    ldx #7", "    tsx" },
        .{ "    ldx #7", "    lda $0101" },
        .{ "    ldx #7", "    pla" },
        .{ "    ldx #7", "alternate:\n    ldx #7" },
        .{ "    jsr leaf\n    rts", "    jsr leaf\n    nop" },
    }) |edit| {
        const text = try std.mem.replaceOwned(u8, a, caller ++ test_leaf, edit[0], edit[1]);
        defer a.free(text);
        try std.testing.expect((try rewrite(a, parsed.program, text)) == null);
    }
    const exported = try parser.parseSource(a, "export " ++ test_source);
    defer exported.deinit(a);
    try std.testing.expect((try rewrite(a, exported.program, caller ++ test_leaf)) == null);
}
