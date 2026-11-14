const std = @import("std");
const ast = @import("../../ast.zig");

const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");
const word_y = @import("word_y_bridge.zig");

const Edit = struct {
    start: usize,
    end: usize,
    move_x: bool = false,
    refresh_nz: bool,
};

fn same(text: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, text, " \t\r"), expected);
}

fn setsNZFromA(text: []const u8) bool {
    const inst = machine.Instruction.parse(text) orelse return false;
    return switch (inst.op) {
        .lda, .@"and", .ora, .eor => true,
        .txa, .tya, .pla, .asl, .lsr, .rol, .ror => same(text, @tagName(inst.op)),
        else => false,
    };
}

fn moveImmediateX(lines: []const []const u8, index: usize, model: storage.Model, managed: bool) ?Edit {
    const packet = lines[index..];
    if (packet.len < 4) return null;
    const saved_to_y = same(packet[1], "tay");
    if (saved_to_y) {
        if (!same(packet[3], "tya") or !word_y.yOverwrittenBeforeRead(packet[4..])) return null;
    } else if (!same(packet[1], "pha") or !same(packet[3], "pla")) return null;
    const load = machine.Instruction.parse(packet[2]) orelse return null;
    if (load.op != .ldx or load.operand != .immediate or
        (machine.integer(load.operand.immediate) orelse return null) > 255) return null;
    const producer = machine.Instruction.parse(packet[0]) orelse return null;
    const refresh_nz = switch (producer.op) {
        .adc, .sbc, .lda, .@"and", .ora, .eor => blk: {
            if (!word_y.ordinaryByte(producer.operand, lines, model, managed)) return null;
            // Decimal ADC/SBC can set N/Z from an intermediate value.
            // PLA/TYA used to recompute them from the adjusted A.
            break :blk producer.op == .adc or producer.op == .sbc;
        },
        .asl, .lsr, .rol, .ror => blk: {
            if (!same(packet[0], @tagName(producer.op))) return null;
            break :blk false;
        },
        else => return null,
    };
    return .{ .start = index, .end = index + 4, .move_x = true, .refresh_nz = refresh_nz };
}

/// Drop stack saves used only to refresh N/Z. When an immediate
/// LDX intervenes, move it before a producer that reads neither X
/// nor N/Z. Keep the decimal-mode flag refresh where it is needed.
pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.functions.len != 0 or
        (std.mem.indexOf(u8, assembly, "    pha\n") == null and std.mem.indexOf(u8, assembly, "    tay\n    ldx #") == null) or
        std.mem.indexOf(u8, assembly, "zeropage_test6502_expect_stack_") != null) return null;
    for (program.functions) |function| {
        if (function.exported and !same(function.name, "main")) return null;
    }
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    const lines = graph.raw.items;
    var model = storage.Model.init(a);
    defer model.deinit();
    try model.collectWithPromotedParameters(assembly, lines);
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(a);
    var consumed: usize = 0;
    for (graph.nodes.items, 0..) |node, i| {
        if (node.zone != .code or node.index < consumed) continue;
        const edit = if (node.index + 1 < lines.len and same(node.text, "pha") and same(lines[node.index + 1], "pla"))
            Edit{
                .start = node.index,
                .end = node.index + 2,
                .refresh_nz = i == 0 or graph.nodes.items[i - 1].scope != node.scope or
                    !setsNZFromA(graph.nodes.items[i - 1].text),
            }
        else
            moveImmediateX(lines, node.index, model, options.zero_page.declared) orelse continue;
        try edits.append(a, edit);
        consumed = edit.end;
    }
    if (edits.items.len == 0 or !try image.permitsPrivateStackRewrite(a, graph, program)) return null;

    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const w = &out.writer;
    var copied: usize = 0;
    for (edits.items) |edit| {
        for (lines[copied..edit.start]) |line| try w.print("{s}\n", .{line});
        if (edit.move_x) try w.print("{s}\n{s}\n", .{ lines[edit.start + 2], lines[edit.start] });
        if (edit.refresh_nz) try w.writeAll("    ora #0\n");
        copied = edit.end;
    }
    for (lines[copied..], copied..) |line, index| {
        try w.writeAll(line);
        if (index + 1 < lines.len) try w.writeByte('\n');
    }
    return try out.toOwnedSlice();
}

const parser = @import("../../parser.zig");
const test_allocator = std.testing.allocator;
const test_header = "* = $2000\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
const test_tail = "    rts\n; zeropage_section_end owner=function:main kind=code\n" ++
    "; zeropage_section_begin owner=function:main kind=static_frame\nmain_byte:\n    .byte 0\n" ++
    "; zeropage_section_end owner=function:main kind=static_frame\n";
const stack_pair = "    pha\n    pla\n";

test "short saves remove a redundant flag refresh or retain it with ORA zero" {
    const parsed = try parser.parseSource(test_allocator, "export fn main() void {}");
    defer parsed.deinit(test_allocator);
    const input = test_header ++ "    lda main_byte\n" ++ stack_pair ++
        "    adc #9\n" ++ stack_pair ++ test_tail;
    const output = (try rewrite(test_allocator, parsed.program, input)) orelse return error.ExpectedShortSave;
    defer test_allocator.free(output);
    try std.testing.expectEqualStrings(test_header ++ "    lda main_byte\n    adc #9\n    ora #0\n" ++ test_tail, output);
}

test "short saves move immediate X loads and keep NMOS decimal result flags" {
    const parsed = try parser.parseSource(test_allocator, "export fn main() void {}");
    defer parsed.deinit(test_allocator);
    const input = test_header ++ "    and #31\n    pha\n    ldx #0\n    pla\n" ++
        "    sbc main_byte\n    tay\n    ldx #2\n    tya\n    ldy #1\n" ++ test_tail;
    const output = (try rewrite(test_allocator, parsed.program, input)) orelse return error.ExpectedShortSave;
    defer test_allocator.free(output);
    try std.testing.expectEqualStrings(test_header ++
        "    ldx #0\n    and #31\n    ldx #2\n    sbc main_byte\n    ora #0\n    ldy #1\n" ++ test_tail, output);
}

test "short saves retain X consumers, live Y, alternate entries and observed stack" {
    const parsed = try parser.parseSource(test_allocator, "export fn main() void {}");
    defer parsed.deinit(test_allocator);
    for ([_][]const u8{
        "    lda main_byte,x\n    pha\n    ldx #0\n    pla\n",
        "    and #31\n    tay\n    ldx #0\n    tya\n    sty main_byte\n    ldy #1\n",
        "    and #31\nentry:\n    pha\n    ldx #0\n    pla\n",
        "    pha\nentry:\n    pla\n",
        stack_pair ++ "    lda $01ff\n",
    }) |body| {
        const text = try std.mem.concat(test_allocator, u8, &.{ test_header, body, test_tail });
        defer test_allocator.free(text);
        try std.testing.expect((try rewrite(test_allocator, parsed.program, text)) == null);
    }
}
