const std = @import("std");
const ast = @import("../../ast.zig");
const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");

const term_nodes = 10;
const tail_nodes = 7;

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn labelStem(text: []const u8, prefix: []const u8) ?[]const u8 {
    const label = layout.label(text) orelse return null;
    if (!std.mem.startsWith(u8, label, prefix) or !std.mem.endsWith(u8, label, "_true") or
        label.len <= prefix.len + "_true".len) return null;
    const stem = label[0 .. label.len - "_true".len];
    for (stem[prefix.len..]) |digit| if (!std.ascii.isDigit(digit)) return null;
    return stem;
}

fn named(text: []const u8, stem: []const u8, suffix: []const u8) bool {
    return std.mem.startsWith(u8, text, stem) and same(text[stem.len..], suffix);
}

fn branchTo(text: []const u8, opcode: []const u8, target: []const u8) bool {
    return std.mem.startsWith(u8, text, opcode) and same(text[opcode.len..], target);
}

fn matchTerm(term: []const layout.Line, falsehood: []const u8) bool {
    const load = machine.Instruction.parse(term[0].text) orelse return false;
    const stem = labelStem(term[4].text, "bool_not_") orelse return false;
    const not_false = layout.label(term[6].text) orelse return false;
    return load.op == .lda and same(term[1].text, "cmp #1") and same(term[2].text, "lda #0") and
        named(not_false, stem, "_false") and branchTo(term[3].text, "bcs ", not_false) and
        same(term[5].text, "lda #1") and named(term[7].text, stem, "_done:") and
        same(term[8].text, "cmp #0") and branchTo(term[9].text, "beq ", falsehood);
}

const Plan = struct {
    first: usize,
    tail: usize,
    ret: usize,
    falsehood: []const u8,
};

fn match(graph: layout.Analysis, ret: usize) ?Plan {
    const nodes = graph.nodes.items;
    if (ret + 1 < tail_nodes or nodes[ret].zone != .code or !same(nodes[ret].text, "rts") or
        (ret + 1 < nodes.len and nodes[ret + 1].scope == nodes[ret].scope)) return null;
    const tail = ret + 1 - tail_nodes;
    const stem = labelStem(nodes[tail].text, "bool_and_") orelse return null;
    const falsehood = layout.label(nodes[tail + 3].text) orelse return null;
    const done = layout.label(nodes[tail + 5].text) orelse return null;
    if (!same(nodes[tail + 1].text, "lda #1") or !named(falsehood, stem, "_false") or
        !same(nodes[tail + 4].text, "lda #0") or !named(done, stem, "_done") or
        !branchTo(nodes[tail + 2].text, "jmp ", done)) return null;

    var first = tail;
    // From a new branch to false, the final true load and jump cost five
    // bytes, plus only the retained tests that follow that branch.
    var span: usize = 5;
    while (first >= term_nodes) {
        const end = if (named(nodes[first - 1].text, stem, "_rhs:")) first - 1 else first;
        if (end < term_nodes or !matchTerm(nodes[end - term_nodes .. end], falsehood)) break;
        if (span > 127) return null;
        first = end - term_nodes;
        span += (graph.maxBytes(first, first + 2) orelse return null) + 2;
    }
    if (first == tail) return null;
    for (nodes[first .. ret + 1], 0..) |node, offset| {
        if (node.scope != nodes[ret].scope or node.index != nodes[first].index + offset) return null;
        const name = layout.label(node.text) orelse continue;
        for (nodes[0..first]) |outside| if (layout.tokenPresent(outside.text, name)) return null;
        for (nodes[ret + 1 ..]) |outside| if (layout.tokenPresent(outside.text, name)) return null;
    }
    return .{ .first = nodes[first].index, .tail = nodes[tail].index, .ret = nodes[ret].index, .falsehood = falsehood };
}

pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.functions.len != 0 or
        std.mem.indexOf(u8, assembly, "    cmp #0\n    beq bool_and_") == null or
        std.mem.indexOf(u8, assembly, "zeropage_test6502_expect_stack_") != null) return null;
    for (program.functions) |function| {
        if (function.exported and !same(function.name, "main")) return null;
    }
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    var plans: std.ArrayList(Plan) = .empty;
    defer plans.deinit(a);
    for (graph.nodes.items, 0..) |_, index| {
        if (match(graph, index)) |plan| try plans.append(a, plan);
    }
    if (plans.items.len == 0 or !try image.permitsLocalShrink(a, graph, program)) return null;

    const lines = graph.raw.items;
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    const w = &output.writer;
    var copied: usize = 0;
    for (plans.items) |plan| {
        for (lines[copied..plan.first]) |line| try w.print("{s}\n", .{line});
        var next = plan.first;
        while (next < plan.tail) {
            const term = lines[next .. next + term_nodes];
            try w.print("{s}\n{s}\n    bcs {s}\n{s}\n{s}\n{s}\n", .{
                term[0], term[1], plan.falsehood, term[4], term[6], term[7],
            });
            next += term_nodes;
            if (next < plan.tail and layout.label(std.mem.trim(u8, lines[next], " \t\r")) != null) {
                try w.print("{s}\n", .{lines[next]});
                next += 1;
            }
        }
        // The old CMP #0 sets C on every exit from the conjunction. The
        // existing literal loads restore A/N/Z before this common exit.
        for (lines[plan.tail..plan.ret]) |line| try w.print("{s}\n", .{line});
        try w.writeAll("    sec\n");
        copied = plan.ret;
    }
    for (lines[copied..], copied..) |line, index| {
        try w.writeAll(line);
        if (index + 1 < lines.len) try w.writeByte('\n');
    }
    return try output.toOwnedSlice();
}

const parser = @import("../../parser.zig");
const test_start = "* = $2000\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
const test_end = "; zeropage_section_end owner=function:main kind=code\n";
const test_term = "    lda #0\n    cmp #1\n    lda #0\n    bcs bool_not_1_false\n" ++
    "bool_not_1_true:\n    lda #1\nbool_not_1_false:\nbool_not_1_done:\n    cmp #0\n    beq bool_and_0_false\n";
const second_term = "bool_and_0_rhs:\n    lda #255\n    cmp #1\n    lda #0\n    bcs bool_not_2_false\n" ++
    "bool_not_2_true:\n    lda #1\nbool_not_2_false:\nbool_not_2_done:\n    cmp #0\n    beq bool_and_0_false\n";
const test_tail = "bool_and_0_true:\n    lda #1\n    jmp bool_and_0_done\n" ++
    "bool_and_0_false:\n    lda #0\nbool_and_0_done:\n";
const return_tail = test_tail ++ "    rts\n" ++ test_end;

test "terminal boolean NOT branches on the original byte and restores carry at return" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const expected = test_start ++
        "    lda #0\n    cmp #1\n    bcs bool_and_0_false\nbool_not_1_true:\nbool_not_1_false:\nbool_not_1_done:\n" ++
        "bool_and_0_rhs:\n    lda #255\n    cmp #1\n    bcs bool_and_0_false\nbool_not_2_true:\nbool_not_2_false:\nbool_not_2_done:\n" ++
        test_tail ++ "    sec\n    rts\n" ++ test_end;
    const output = (try rewrite(a, parsed.program, test_start ++ test_term ++ second_term ++ return_tail)) orelse
        return error.ExpectedDirectBranch;
    defer a.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "terminal boolean NOT rewrites a closed single test" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const output = (try rewrite(a, parsed.program, test_start ++ test_term ++ return_tail)) orelse
        return error.ExpectedDirectBranch;
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "    cmp #1\n    bcs bool_and_0_false\n") != null);
}

test "terminal boolean NOT declines outside entries and intervening flag reads" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    for ([_][]const u8{
        test_start ++ "    jmp BOOL_NOT_1_TRUE\n" ++ test_term ++ second_term ++ return_tail,
        test_start ++ "    bne bool_and_0_false\n" ++ test_term ++ second_term ++ return_tail,
        test_start ++ test_term ++ second_term ++ test_tail ++ "    php\n    rts\n" ++ test_end,
        test_start ++ test_term ++ "    php\n" ++ second_term ++ return_tail,
    }) |input| {
        const output = try rewrite(a, parsed.program, input);
        defer if (output) |bytes| a.free(bytes);
        try std.testing.expect(output == null);
    }
}
