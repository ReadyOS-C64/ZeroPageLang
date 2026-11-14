const std = @import("std");
const ast = @import("../../ast.zig");

const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");

const Edit = struct { save: usize, restore: usize };

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn same(line: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, trim(line), expected);
}

fn byteLiteral(operand: machine.Operand) bool {
    return operand == .immediate and (machine.integer(operand.immediate) orelse return false) <= 255;
}

pub fn ordinaryByte(operand: machine.Operand, lines: []const []const u8, model: storage.Model, managed: bool) bool {
    return byteLiteral(operand) or (operand == .direct and
        (model.ordinaryStorage(lines, operand.direct, 1, managed) or
            (managed and storage.claimedScratch(lines, operand.direct))));
}

fn restoreOffset(tail: []const []const u8, lines: []const []const u8, model: storage.Model, managed: bool) ?usize {
    if (tail.len < 3) return null;
    const load = machine.Instruction.parse(tail[1]) orelse return null;
    if (load.op == .ldx and byteLiteral(load.operand) and same(tail[2], "pla")) return 2;
    if (tail.len < 5 or !same(tail[3], "tax") or !same(tail[4], "pla")) return null;
    if (!same(tail[1], "txa") and !(load.op == .lda and ordinaryByte(load.operand, lines, model, managed))) return null;
    const operation = machine.Instruction.parse(tail[2]) orelse return null;
    const valid = switch (operation.op) {
        .adc, .sbc, .@"and", .ora, .eor => ordinaryByte(operation.operand, lines, model, managed),
        .asl, .lsr, .rol, .ror => same(tail[2], @tagName(operation.op)),
        else => false,
    };
    return if (valid) 4 else null;
}

pub fn yOverwrittenBeforeRead(lines: []const []const u8) bool {
    for (lines) |raw| {
        const line = trim(raw);
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "; zeropage_section_")) return false;
        if (line[0] == ';') continue;
        const inst = machine.Instruction.parse(line) orelse return false;
        const effects = inst.effects();
        if (effects.barrier or effects.reads & machine.y != 0) return false;
        if (effects.writes & machine.y != 0) return true;
    }
    return false;
}

/// TAY changes N/Z where PHA does not. The first high-byte load
/// or transfer overwrites those flags before any read, while TYA
/// supplies the same A and N/Z as PLA at the end of the bridge.
pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.functions.len != 0 or
        std.mem.indexOf(u8, assembly, "    pha\n") == null or
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
    for (graph.nodes.items) |node| {
        if (node.zone != .code or !same(node.text, "pha")) continue;
        const offset = restoreOffset(lines[node.index..], lines, model, options.zero_page.declared) orelse continue;
        const restore = node.index + offset;
        if (!yOverwrittenBeforeRead(lines[restore + 1 ..])) continue;
        try edits.append(a, .{ .save = node.index, .restore = restore });
    }
    if (edits.items.len == 0 or !try image.permitsPrivateStackRewrite(a, graph, program)) return null;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const w = &out.writer;
    var copied: usize = 0;
    for (edits.items) |edit| {
        for (lines[copied..edit.save]) |line| try w.print("{s}\n", .{line});
        try w.writeAll("    tay\n");
        for (lines[edit.save + 1 .. edit.restore]) |line| try w.print("{s}\n", .{line});
        try w.writeAll("    tya\n");
        copied = edit.restore + 1;
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
    "; zeropage_section_begin owner=function:main kind=static_frame\nmain_word:\n    .word 0\n" ++
    "; zeropage_section_end owner=function:main kind=static_frame\n";
const test_add = "    pha\n    txa\n    adc main_word+1\n    tax\n    pla\n";
const test_shift = "    pha\n    lda main_word+1\n    rol\n    tax\n    pla\n";
const test_immediate = "    pha\n    ldx #0\n    pla\n";

test "word Y bridge preserves word ALU and shift packets until Y is written" {
    const parsed = try parser.parseSource(test_allocator, "export fn main() void {}");
    defer parsed.deinit(test_allocator);
    const text = test_header ++ test_add ++ test_shift ++ test_immediate ++ "    ldy #0\n" ++ test_tail;
    const output = (try rewrite(test_allocator, parsed.program, text)) orelse return error.ExpectedYBridge;
    defer test_allocator.free(output);
    const expected = test_header ++
        "    tay\n    txa\n    adc main_word+1\n    tax\n    tya\n" ++
        "    tay\n    lda main_word+1\n    rol\n    tax\n    tya\n" ++
        "    tay\n    ldx #0\n    tya\n    ldy #0\n" ++ test_tail;
    try std.testing.expectEqualStrings(expected, output);
}

test "word Y bridge rejects live Y, alternate entries and stack-page operands" {
    const parsed = try parser.parseSource(test_allocator, "export fn main() void {}");
    defer parsed.deinit(test_allocator);
    for ([_][]const u8{
        test_add ++ "    sta main_word,y\n    ldy #0\n",
        test_add ++ "    tya\n    ldy #0\n",
        test_add ++ "    lda $01ff\n    ldy #0\n",
        test_add ++ "    ldy #0\n    lda @w $24,x\n",
        test_add ++ "    ldy #0\n    lda $24,y\n",
        test_add ++ "    bcc skip\n    ldy #0\nskip:\n",
        test_add ++ "    jsr helper\n    ldy #0\n",
        "    pha\nalternate:\n    txa\n    adc main_word+1\n    tax\n    pla\n    ldy #0\n",
        "    pha\n    lda $01ff\n    rol\n    tax\n    pla\n    ldy #0\n",
    }) |body| {
        const text = try std.mem.concat(test_allocator, u8, &.{ test_header, body, test_tail });
        defer test_allocator.free(text);
        try std.testing.expect((try rewrite(test_allocator, parsed.program, text)) == null);
    }
    const observed = try parser.parseSource(test_allocator,
        \\const test6502 = @import("test6502");
        \\export fn main() void { test6502.expectMemU8(1, 0x1ff, 0); }
    );
    defer observed.deinit(test_allocator);
    try std.testing.expect((try rewrite(test_allocator, observed.program, test_header ++ test_add ++ "    ldy #0\n" ++ test_tail)) == null);
}

test "word Y bridge accepts compiler scratch only with an allocation claim" {
    const parsed = try parser.parseSource(test_allocator, "pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scratch } };\n" ++
        "export fn main() void {}");
    defer parsed.deinit(test_allocator);
    const text = test_header ++ "    pha\n    txa\n    sbc zeropage_math_tmp+1\n    tax\n    pla\n    tay\n    lda $24,x\n" ++ test_tail ++
        "zeropage_math_tmp = address($24)\n";
    const claim = "; zeropage_zp_claim label=zeropage_math_tmp addr=36 size=2 kind=scratch benefit=2\n";
    const output = (try rewrite(test_allocator, parsed.program, text ++ claim)) orelse return error.ExpectedYBridge;
    defer test_allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "    tay\n    txa\n    sbc zeropage_math_tmp+1\n    tax\n    tya\n") != null);
    try std.testing.expect((try rewrite(test_allocator, parsed.program, text)) == null);
}
