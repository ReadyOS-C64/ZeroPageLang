const std = @import("std");
const ast = @import("../../ast.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");
const image = @import("unreachable_code.zig");

const Replacement = union(enum) { drop, ldx: u8, beq: []const u8, sec_rts };
const Edit = struct {
    index: usize,
    replacement: Replacement = .drop,

    fn lessThan(_: void, first: Edit, second: Edit) bool {
        return first.index < second.index;
    }
};

fn is(raw: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r"), expected);
}

fn planBridge(a: std.mem.Allocator, lines: []const []const u8, start: usize, edits: *std.ArrayList(Edit)) !void {
    if (lines.len - start < 4 or !is(lines[start + 1], "txa")) return;
    var tax = start + 2;
    var replacement: Replacement = .drop;
    if (!is(lines[tax], "tax")) {
        const inst = machine.Instruction.parse(lines[tax]) orelse return;
        if (inst.operand != .immediate) return;
        const value = machine.integer(inst.operand.immediate) orelse return;
        switch (inst.op) {
            .@"and" => switch (value) {
                0 => replacement = .{ .ldx = 0 },
                255 => {},
                else => return,
            },
            .ora => switch (value) {
                0 => {},
                255 => replacement = .{ .ldx = 255 },
                else => return,
            },
            .eor => if (value != 0) return,
            else => return,
        }
        tax += 1;
        if (tax + 1 >= lines.len or !is(lines[tax], "tax")) return;
    }
    if (!is(lines[tax + 1], "pla")) return;
    // PHA/PLA still writes the same pending byte and supplies final A/N/Z.
    try edits.append(a, .{ .index = start + 1, .replacement = replacement });
    for (start + 2..tax + 1) |index| try edits.append(a, .{ .index = index });
}

fn op(text: []const u8, expected: machine.Op) bool {
    const inst = machine.Instruction.parse(text) orelse return false;
    return inst.op == expected;
}

fn target(text: []const u8, expected: machine.Op) ?[]const u8 {
    const inst = machine.Instruction.parse(text) orelse return null;
    return if (inst.op == expected and inst.operand == .direct and inst.operand.direct.offset == 0)
        inst.operand.direct.name
    else
        null;
}

fn skipLabels(nodes: []const layout.Line, start: usize) usize {
    var i = start;
    while (i < nodes.len and layout.label(nodes[i].text) != null) : (i += 1) {}
    return i;
}

fn hasLabel(nodes: []const layout.Line, name: []const u8) bool {
    for (nodes) |node| {
        const label = layout.label(node.text) orelse continue;
        if (std.ascii.eqlIgnoreCase(label, name)) return true;
    }
    return false;
}

fn hasAlternateEntry(nodes: []const layout.Line, first: usize, end: usize) bool {
    for (nodes, 0..) |node, index| {
        if (index >= first and index < end) continue;
        const inst = machine.Instruction.parse(node.text) orelse continue;
        if (inst.op != .jsr and inst.op != .jmp and !layout.conditional(inst.op)) continue;
        if (inst.operand == .direct and hasLabel(nodes[first + 1 .. end], inst.operand.direct.name)) return true;
    }
    return false;
}

fn planBoolean(a: std.mem.Allocator, graph: layout.Analysis, first: usize, end: usize, edits: *std.ArrayList(Edit)) !void {
    const nodes = graph.nodes.items;
    if (end - first < 14 or !op(nodes[first + 1].text, .lda)) return;
    const tail = end - 6;
    if (!is(nodes[tail].text, "lda #1") or !is(nodes[tail + 3].text, "lda #0") or !is(nodes[end - 1].text, "rts")) return;
    const false_label = layout.label(nodes[tail + 2].text) orelse return;
    const done_label = layout.label(nodes[tail + 4].text) orelse return;
    if (!std.ascii.eqlIgnoreCase(target(nodes[tail + 1].text, .jmp) orelse return, done_label)) return;

    const previous = edits.items.len;
    var committed = false;
    defer if (!committed) edits.shrinkRetainingCapacity(previous);
    var i = first + 2;
    while (i + 2 < tail and op(nodes[i].text, .cmp)) {
        const branch = i + 1;
        const true_label = target(nodes[branch].text, .bne) orelse return;
        const sec = skipLabels(nodes[0..tail], branch + 1);
        if (sec + 1 >= tail or !is(nodes[sec].text, "sec") or
            !std.ascii.eqlIgnoreCase(target(nodes[sec + 1].text, .jmp) orelse return, false_label)) return;
        i = skipLabels(nodes[0..tail], sec + 2);
        if (!hasLabel(nodes[sec + 2 .. i], true_label)) return;
        if ((graph.maxBytes(branch + 1, tail + 2) orelse return) > 127) return;
        try edits.appendSlice(a, &.{
            .{ .index = nodes[branch].index, .replacement = .{ .beq = false_label } },
            .{ .index = nodes[sec].index },
            .{ .index = nodes[sec + 1].index },
        });
    }
    if (edits.items.len == previous or i >= tail or !is(nodes[i].text, "sec") or
        skipLabels(nodes[0..tail], i + 1) != tail or hasAlternateEntry(nodes, first, end)) return;
    // Both literal loads overwrite N/Z. The common SEC restores C without
    // changing the other flags or the order of the original comparisons.
    try edits.appendSlice(a, &.{
        .{ .index = nodes[i].index },
        .{ .index = nodes[end - 1].index, .replacement = .sec_rts },
    });
    committed = true;
}

pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.functions.len != 0 or
        std.mem.indexOf(u8, assembly, "zeropage_test6502_expect_stack_") != null) return null;
    if (std.mem.indexOf(u8, assembly, "    pha\n    txa\n") == null and
        std.mem.indexOf(u8, assembly, "    sec\n    jmp ") == null) return null;
    for (program.functions) |function| {
        if (function.exported and !std.mem.eql(u8, function.name, "main")) return null;
    }
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    const nodes = graph.nodes.items;
    const lines = graph.raw.items;
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(a);
    for (nodes, 0..) |node, index| {
        if (node.zone != .code) continue;
        if (is(node.text, "pha")) try planBridge(a, lines, node.index, &edits);
        const entry = layout.label(node.text) orelse continue;
        if (node.index == 0 or !is(storage.sectionOwner(lines[node.index - 1], "code") orelse continue, entry)) continue;
        var end = index + 1;
        while (end < nodes.len and nodes[end].scope == node.scope) : (end += 1) {}
        try planBoolean(a, graph, index, end, &edits);
    }
    if (edits.items.len == 0 or !try image.permitsLocalShrink(a, graph, program)) return null;
    std.mem.sort(Edit, edits.items, {}, Edit.lessThan);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var edit: usize = 0;
    for (lines, 0..) |line, index| {
        if (edit < edits.items.len and edits.items[edit].index == index) {
            switch (edits.items[edit].replacement) {
                .drop => {},
                .ldx => |value| try output.writer.print("    ldx #{d}\n", .{value}),
                .beq => |name| try output.writer.print("    beq {s}\n", .{name}),
                .sec_rts => try output.writer.writeAll("    sec\n    rts\n"),
            }
            edit += 1;
            continue;
        }
        try output.writer.writeAll(line);
        if (index + 1 < lines.len) try output.writer.writeByte('\n');
    }
    return try output.toOwnedSlice();
}

test "local folds reject a boolean return with an alternate entry or an out-of-range false branch" {
    const a = std.testing.allocator;
    for ([_]usize{ 1, 40 }) |comparisons| {
        var text: std.Io.Writer.Allocating = .init(a);
        defer text.deinit();
        try text.writer.writeAll("; zeropage_section_begin owner=function:probe kind=code\nprobe:\n    lda #0\n");
        for (0..comparisons) |index| {
            try text.writer.print("    cmp #0\n    bne yes_{d}\n    sec\n    jmp no\nyes_{d}:\n", .{ index, index });
        }
        try text.writer.writeAll("    sec\n    lda #1\n    jmp done\nno:\n    lda #0\ndone:\n    rts\n; zeropage_section_end owner=function:probe kind=code\n");
        if (comparisons == 1) {
            try text.writer.writeAll("; zeropage_section_begin owner=function:observer kind=code\nobserver:\n    jmp YES_0\n; zeropage_section_end owner=function:observer kind=code\n");
        }
        var graph = try layout.parseForSize(a, text.written());
        defer graph.deinit(a);
        try std.testing.expect(graph.complete);
        var edits: std.ArrayList(Edit) = .empty;
        defer edits.deinit(a);
        const end = graph.target("observer") orelse graph.nodes.items.len;
        try planBoolean(a, graph, 0, end, &edits);
        try std.testing.expectEqual(@as(usize, 0), edits.items.len);
    }
}
