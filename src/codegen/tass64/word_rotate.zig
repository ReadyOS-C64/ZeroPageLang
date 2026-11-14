const std = @import("std");
const ast = @import("../../ast.zig");

const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");

const shift = [_][]const u8{ "asl", "pha", "txa", "rol", "tax", "pla" };
const scratch_names = [_][]const u8{ "zeropage_math_tmp", "zeropage_mul_lhs", "zeropage_ptr_value" };
const Scratch = struct { name: []const u8, min_shifts: usize };
const Packet = struct { shifts: usize, arithmetic: usize };
const Edit = struct { start: usize, packet: Packet, scratch: Scratch };

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn matches(lines: []const []const u8, instructions: []const []const u8) bool {
    if (lines.len < instructions.len) return false;
    for (lines[0..instructions.len], instructions) |line, instruction| {
        if (!std.mem.eql(u8, trim(line), instruction)) return false;
    }
    return true;
}

fn wordPart(line: []const u8, op: machine.Op, name: []const u8, offset: i32) bool {
    const inst = machine.Instruction.parse(line) orelse return false;
    return inst.op == op and inst.operand == .direct and
        std.mem.eql(u8, inst.operand.direct.name, name) and inst.operand.direct.offset == offset;
}

fn packetAt(lines: []const []const u8, source: []const u8) ?Packet {
    if (lines.len < 15 or !matches(lines[1..], &.{ "asl", "pha" }) or
        !wordPart(lines[3], .lda, source, 1) or !matches(lines[4..], &.{ "rol", "tax", "pla" })) return null;
    var cursor: usize = 7;
    var shifts: usize = 1;
    while (matches(lines[cursor..], &shift)) {
        cursor += shift.len;
        shifts += 1;
    }
    if (shifts < 2 or lines.len - cursor < 8) return null;
    const op: machine.Op = if (std.mem.eql(u8, trim(lines[cursor]), "clc"))
        .adc
    else if (std.mem.eql(u8, trim(lines[cursor]), "sec"))
        .sbc
    else
        return null;
    const tail = lines[cursor..];
    if (!wordPart(tail[1], op, source, 0) or !matches(tail[2..], &.{ "pha", "txa" }) or
        !wordPart(tail[4], op, source, 1) or !matches(tail[5..], &.{ "tax", "pla" })) return null;
    const end = tail[7..];
    if (!matches(end, &.{"rts"}) and
        !(matches(end, &shift) and matches(end[shift.len..], &.{"rts"}))) return null;
    return .{ .shifts = shifts, .arithmetic = cursor };
}

/// The extra write can survive the terminal packet. Every original read of
/// the byte must therefore have a newer write in the same straight-line block.
/// A sole compiler scratch definition rules out colocated aliases.
fn blockLocalScratch(graph: layout.Analysis, declaration: usize, name: []const u8) bool {
    var scope: usize = 0;
    var written = false;
    for (graph.nodes.items) |node| {
        if (node.scope != scope) {
            scope = node.scope;
            written = false;
        }
        if (node.index == declaration) continue;
        const inst = machine.Instruction.parse(node.text) orelse {
            written = false;
            if (layout.tokenPresent(node.text, name)) return false;
            continue;
        };
        const effects = inst.effects();
        if (effects.barrier) written = false;
        if (!layout.tokenPresent(node.text, name)) continue;
        if (node.zone != .code or inst.operand != .direct or
            !std.mem.eql(u8, inst.operand.direct.name, name) or
            inst.operand.direct.offset < 0 or inst.operand.direct.offset > 1) return false;
        if (inst.operand.direct.offset == 0) continue;
        if (effects.memory == .write) {
            written = true;
        } else if (!written) return false;
    }
    return true;
}

fn scratchCell(graph: layout.Analysis, model: storage.Model, managed: bool, name: []const u8) ?Scratch {
    const lines = graph.raw.items;
    for (graph.nodes.items) |node| {
        if (node.zone != .data or node.index == 0 or !std.mem.startsWith(u8, node.text, name) or
            !std.mem.startsWith(u8, trim(lines[node.index - 1]), "; zeropage_section_begin owner=compiler kind=scratch ")) continue;
        const tail = node.text[name.len..];
        const after = lines[node.index + 1 ..];
        const end = "; zeropage_section_end owner=compiler kind=scratch";
        const min_shifts: usize = if (std.mem.eql(u8, tail, ":") and matches(after, &.{ ".word 0", end })) blk: {
            const slot = model.resolveObject(.{ .name = name }, 2) orelse return null;
            if (!std.mem.eql(u8, model.frames.items[slot.frame].owner, "compiler:scratch")) return null;
            break :blk 3;
        } else if (managed and std.mem.startsWith(u8, tail, " = address(") and matches(after, &.{end})) blk: {
            const claim = storage.claimedAddress(lines, name, "scratch") orelse return null;
            if (claim.width != 2) return null;
            break :blk 2;
        } else continue;
        if (blockLocalScratch(graph, node.index, name)) return .{ .name = name, .min_shifts = min_shifts };
    }
    return null;
}

pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.functions.len != 0 or
        std.mem.indexOf(u8, assembly, next) == null or
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
    var cells: [scratch_names.len]?Scratch = @splat(null);
    for (scratch_names, &cells) |name, *cell| cell.* = scratchCell(graph, model, options.zero_page.declared, name);
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(a);
    for (graph.nodes.items) |node| {
        if (node.zone != .code or !std.mem.startsWith(u8, node.text, "lda ")) continue;
        const inst = machine.Instruction.parse(node.text) orelse continue;
        if (inst.operand != .direct or inst.operand.direct.offset != 0) continue;
        const source = inst.operand.direct.name;
        const packet = packetAt(lines[node.index..], source) orelse continue;
        if (!model.ordinaryStorage(lines, inst.operand.direct, 2, options.zero_page.declared)) continue;
        var best: ?Scratch = null;
        for (cells) |cell| {
            const scratch = cell orelse continue;
            if (std.mem.eql(u8, scratch.name, source) or packet.shifts < scratch.min_shifts) continue;
            if (best == null or scratch.min_shifts < best.?.min_shifts) best = scratch;
        }
        const scratch = best orelse continue;
        try edits.append(a, .{ .start = node.index, .packet = packet, .scratch = scratch });
    }
    if (edits.items.len == 0 or !try image.permitsLocalShrink(a, graph, program)) return null;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const w = &out.writer;
    var copied: usize = 0;
    for (edits.items) |edit| {
        const start = edit.start;
        const arithmetic = start + edit.packet.arithmetic;
        const high_operand = trim(lines[start + 3])["lda ".len..];
        for (lines[copied .. start + 1]) |line| try w.print("{s}\n", .{line});
        try w.print("    ldx {s}\n    stx {s}+1\n", .{ high_operand, edit.scratch.name });
        for (0..edit.packet.shifts) |_| try w.print("    asl\n    rol {s}+1\n", .{edit.scratch.name});
        for (lines[arithmetic .. arithmetic + 3]) |line| try w.print("{s}\n", .{line});
        try w.print("    lda {s}+1\n", .{edit.scratch.name});
        copied = arithmetic + 4;
    }
    for (lines[copied..], copied..) |line, index| {
        try w.writeAll(line);
        if (index + 1 < lines.len) try w.writeByte('\n');
    }
    return try out.toOwnedSlice();
}

const parser = @import("../../parser.zig");
const header = "* = $2000\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
const first = "    lda main_word\n    asl\n    pha\n    lda main_word+1\n    rol\n    tax\n    pla\n";
const next = "    asl\n    pha\n    txa\n    rol\n    tax\n    pla\n";
const add = "    clc\n    adc main_word\n    pha\n    txa\n    adc main_word+1\n    tax\n    pla\n";
const sub = "    sec\n    sbc main_word\n    pha\n    txa\n    sbc main_word+1\n    tax\n    pla\n";
const footer = "    rts\n; zeropage_section_end owner=function:main kind=code\n" ++
    "; zeropage_section_begin owner=function:main kind=static_frame\nmain_word:\n    .word 0\n" ++
    "; zeropage_section_end owner=function:main kind=static_frame\n";
const scratch_start = "; zeropage_section_begin owner=compiler kind=scratch lifetime=static address=near\n";
const scratch_end = "; zeropage_section_end owner=compiler kind=scratch\n";
const resident = scratch_start ++ "zeropage_math_tmp:\n    .word 0\n" ++ scratch_end;

test "terminal word rotate borrows resident scratch for three shifts" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const result = (try rewrite(a, parsed.program, header ++ first ++ next ++ next ++ sub ++ footer ++ resident)) orelse return error.ExpectedRotation;
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "    ldx main_word+1\n    stx zeropage_math_tmp+1\n    asl\n    rol zeropage_math_tmp+1\n") != null);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, result, "    rol zeropage_math_tmp+1\n"));
    try std.testing.expect(std.mem.indexOf(u8, result, "    sbc main_word\n    pha\n    lda zeropage_math_tmp+1\n    sbc main_word+1\n") != null);
    try std.testing.expect((try rewrite(a, parsed.program, header ++ first ++ next ++ add ++ footer ++ resident)) == null);
}

test "terminal word rotate needs a verified scratch claim for two shifts" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, "pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scratch } };\n" ++
        "export fn main() void {}");
    defer parsed.deinit(a);
    const code = header ++ first ++ next ++ add ++ next ++ footer ++ scratch_start ++
        "zeropage_math_tmp = address($24)\n" ++ scratch_end;
    const claim = "; zeropage_zp_claim label=zeropage_math_tmp addr=36 size=2 kind=scratch benefit=10\n";
    const result = (try rewrite(a, parsed.program, code ++ claim)) orelse return error.ExpectedRotation;
    defer a.free(result);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result, "    rol zeropage_math_tmp+1\n"));
    try std.testing.expect(std.mem.indexOf(u8, result, next ++ "    rts\n") != null);
    try std.testing.expect((try rewrite(a, parsed.program, code)) == null);
}

test "terminal word rotate retains scratch live across control flow and ambiguous aliases" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const code = header ++ first ++ next ++ next ++ add ++ footer;
    const caller = "; zeropage_section_begin owner=function:caller kind=code\ncaller:\n" ++
        "    sta zeropage_math_tmp+1\n    jsr main\n    lda zeropage_math_tmp+1\n    rts\n" ++
        "; zeropage_section_end owner=function:caller kind=code\n";
    for ([_][]const u8{
        code ++ resident ++ caller,
        code ++ resident ++ "alias = zeropage_math_tmp+1\n",
        code ++ scratch_start ++ "zeropage_math_tmp:\nalias:\n    .word 0\n" ++ scratch_end,
        header ++ first ++ "alternate:\n" ++ next ++ next ++ add ++ footer ++ resident,
        header ++ first ++ next ++ next ++ add ++ "    sta zeropage_math_tmp+1\n" ++ footer ++ resident,
    }) |input| try std.testing.expect((try rewrite(a, parsed.program, input)) == null);
}
