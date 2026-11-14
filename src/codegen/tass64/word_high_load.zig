const std = @import("std");
const ast = @import("../../ast.zig");
const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");

const left = [_][]const u8{ "asl", "pha", "txa", "rol", "tax", "pla" };
const right = [_][]const u8{ "pha", "txa", "lsr", "tax", "pla", "ror" };
const Edit = struct { start: usize, transfer: usize, high_operand: []const u8 };

fn trim(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r");
}

fn matches(lines: []const []const u8, packet: []const []const u8) bool {
    if (lines.len < packet.len) return false;
    for (lines[0..packet.len], packet) |raw, expected| {
        if (!std.mem.eql(u8, trim(raw), expected)) return false;
    }
    return true;
}

fn ordinaryArithmeticOperand(lines: []const []const u8, operand: machine.Operand, model: storage.Model, managed: bool) bool {
    return switch (operand) {
        .immediate => |value| (machine.integer(value) orelse return false) <= 255,
        .direct => |reference| model.ordinaryStorage(lines, reference, 1, managed),
        else => false,
    };
}

fn arithmeticBridge(lines: []const []const u8, tail: []const []const u8, model: storage.Model, managed: bool) bool {
    if (tail.len < 7 or !matches(tail[2..], &.{ "pha", "txa" }) or !matches(tail[5..], &.{ "tax", "pla" })) return false;
    const low = machine.Instruction.parse(tail[1]) orelse return false;
    const high = machine.Instruction.parse(tail[4]) orelse return false;
    if (low.op != high.op) return false;
    switch (low.op) {
        .adc => if (!std.mem.eql(u8, trim(tail[0]), "clc")) return false,
        .sbc => if (!std.mem.eql(u8, trim(tail[0]), "sec")) return false,
        else => return false,
    }
    return ordinaryArithmeticOperand(lines, low.operand, model, managed) and
        ordinaryArithmeticOperand(lines, high.operand, model, managed);
}

/// Load the high byte directly into A at the existing TXA. The old
/// LDX changes only X/N/Z, none of which the intervening instructions read.
/// The high operation still sees the same carry, and PHA/PLA leave the same
/// byte and SP. Any low arithmetic read must also be an ordinary access.
pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.functions.len != 0 or
        std.mem.indexOf(u8, assembly, "    pha\n    txa\n") == null or
        std.mem.indexOf(u8, assembly, "zeropage_test6502_expect_stack_") != null) return null;
    for (program.functions) |function| {
        if (function.exported and !std.mem.eql(u8, function.name, "main")) return null;
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
    for (graph.nodes.items) |node| {
        const prefix = "ldx ";
        if (node.zone != .code or !std.mem.startsWith(u8, node.text, prefix) or node.index + 2 > lines.len) continue;
        const tail = lines[node.index + 2 ..];
        if (!model.ordinaryWordLoad(lines, node.text, lines[node.index + 1], options.zero_page.declared)) continue;
        const transfer: usize = if (matches(tail, &left))
            node.index + 4
        else if (matches(tail, &right))
            node.index + 3
        else if (arithmeticBridge(lines, tail, model, options.zero_page.declared))
            node.index + 5
        else
            continue;
        try edits.append(a, .{ .start = node.index, .transfer = transfer, .high_operand = node.text[prefix.len..] });
    }
    if (edits.items.len == 0 or !try image.permitsLocalShrink(a, graph, program)) return null;
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    const w = &output.writer;
    var copied: usize = 0;
    for (edits.items) |edit| {
        for (lines[copied..edit.start]) |line| try w.print("{s}\n", .{line});
        for (lines[edit.start + 1 .. edit.transfer]) |line| try w.print("{s}\n", .{line});
        try w.print("    lda {s}\n", .{edit.high_operand});
        copied = edit.transfer + 1;
    }
    for (lines[copied..], copied..) |line, index| {
        try w.writeAll(line);
        if (index + 1 < lines.len) try w.writeByte('\n');
    }
    return try output.toOwnedSlice();
}

const parser = @import("../../parser.zig");
const test_header = "* = $2000\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
const test_footer = "    rts\n; zeropage_section_end owner=function:main kind=code\n";
const test_object = "; zeropage_section_begin owner=function:main kind=static_frame\n" ++
    "main_word:\n    .word 0\n; zeropage_section_end owner=function:main kind=static_frame\n";
const test_load = "    ldx main_word+1\n    lda main_word\n";
const test_left = "    asl\n    pha\n    txa\n    rol\n    tax\n    pla\n";
const test_right = "    pha\n    txa\n    lsr\n    tax\n    pla\n    ror\n";

test "word shift loads the resident high byte into A while preserving the stack bridge" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    for ([_][2][]const u8{
        .{ test_left, "    lda main_word\n    asl\n    pha\n    lda main_word+1\n    rol\n    tax\n    pla\n" },
        .{ test_right, "    lda main_word\n    pha\n    lda main_word+1\n    lsr\n    tax\n    pla\n    ror\n" },
    }) |pair| {
        const input = try std.mem.concat(a, u8, &.{ test_header, test_load, pair[0], test_footer, test_object });
        defer a.free(input);
        const expected = try std.mem.concat(a, u8, &.{ test_header, pair[1], test_footer, test_object });
        defer a.free(expected);
        const output = (try rewrite(a, parsed.program, input)) orelse return error.ExpectedShift;
        defer a.free(output);
        try std.testing.expectEqualStrings(expected, output);
    }
}

test "word shift requires both bytes of a claimed zero-page parameter" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, "pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scalars } };\n" ++
        "export fn main() void {}");
    defer parsed.deinit(a);
    const code = test_header ++ test_load ++ test_right ++ test_footer;
    const equate = "main_word = address($24)\n";
    const claim = "; zeropage_zp_claim label=main_word addr=36 size=2 kind=parameter benefit=10\n";
    const output = (try rewrite(a, parsed.program, code ++ equate ++ claim)) orelse return error.ExpectedShift;
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "    pha\n    lda main_word+1\n    lsr\n") != null);
    try std.testing.expect((try rewrite(a, parsed.program, code ++ equate)) == null);
}

test "word shift retains unknown aliases, split objects, and alternate entries" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const split_object = "; zeropage_section_begin owner=function:main kind=static_frame\n" ++
        "main_word:\n    .byte 0\nother:\n    .byte 0\n; zeropage_section_end owner=function:main kind=static_frame\n";
    for ([_][]const u8{
        test_header ++ test_load ++ test_left ++ test_footer ++ "main_word = $d020\n",
        test_header ++ test_load ++ test_left ++ test_footer ++ split_object,
        test_header ++ "    bne other\n    ldx main_word+1\nother:\n    lda main_word\n" ++ test_left ++ test_footer ++ test_object,
    }) |input| {
        const output = try rewrite(a, parsed.program, input);
        defer if (output) |bytes| a.free(bytes);
        try std.testing.expect(output == null);
    }
}

test "word arithmetic loads the high byte after the low ADC or SBC" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const rhs = "; zeropage_section_begin owner=function:main kind=static_frame\n" ++
        "main_rhs:\n    .word 0\n; zeropage_section_end owner=function:main kind=static_frame\n";
    const code = test_header ++ test_load ++ "    clc\n    adc main_rhs\n    pha\n    txa\n    adc main_rhs+1\n    tax\n    pla\n" ++
        test_load ++ "    sec\n    sbc #1\n    pha\n    txa\n    sbc #0\n    tax\n    pla\n" ++ test_footer ++ test_object ++ rhs;
    const output = (try rewrite(a, parsed.program, code)) orelse return error.ExpectedArithmetic;
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "    adc main_rhs\n    pha\n    lda main_word+1\n    adc main_rhs+1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "    sbc #1\n    pha\n    lda main_word+1\n    sbc #0\n") != null);
}

test "word arithmetic retains unknown operands and alternate entries" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    for ([_][]const u8{
        "    clc\n    adc io\n    pha\n    txa\n    adc io+1\n    tax\n    pla\n",
        "    clc\n    adc #1\n    pha\nentry:\n    txa\n    adc #0\n    tax\n    pla\n",
        "    clc\n    adc #1\n    pha\n    txa\n    sbc #0\n    tax\n    pla\n",
    }) |tail| {
        const input = try std.mem.concat(a, u8, &.{ test_header, test_load, tail, test_footer, test_object, "io = $d020\n" });
        defer a.free(input);
        const output = try rewrite(a, parsed.program, input);
        defer if (output) |bytes| a.free(bytes);
        try std.testing.expect(output == null);
    }
}
