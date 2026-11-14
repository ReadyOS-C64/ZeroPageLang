const std = @import("std");
const ast = @import("../../ast.zig");
const cfg = @import("cfg_dead_values.zig");
const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const literal_io = @import("literal_pointer_io.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");

const capture = "zeropage_mul_lhs";
const mask_tail = [_][]const u8{ "pha", "txa", "and #0", "tax", "pla", "sta " ++ capture, "stx " ++ capture ++ "+1" };
const narrowed_tail = [_][]const u8{ "pha", "ldx #0", "pla", "sta " ++ capture, "stx " ++ capture ++ "+1" };
const shift = [_][]const u8{ "asl", "pha", "txa", "rol", "tax", "pla" };
const add = [_][]const u8{ "clc", "adc " ++ capture, "pha", "txa", "adc " ++ capture ++ "+1", "tax", "pla" };
const subtract = [_][]const u8{ "sec", "sbc " ++ capture, "pha", "txa", "sbc " ++ capture ++ "+1", "tax", "pla" };

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn matches(lines: []const []const u8, packet: []const []const u8) bool {
    if (lines.len < packet.len) return false;
    for (lines[0..packet.len], packet) |line, instruction| {
        if (!std.mem.eql(u8, trim(line), instruction)) return false;
    }
    return true;
}

const Window = struct {
    start: usize,
    end: usize,
    narrow_end: usize,
    low_add: ?usize = null,

    fn write(self: Window, writer: *std.Io.Writer, lines: []const []const u8) !void {
        try writer.print("{s}\n    pha\n    ldx #0\n    pla\n    sta " ++ capture ++ "\n    stx " ++ capture ++ "+1\n", .{lines[self.start]});
        var i = self.start + 1 + mask_tail.len;
        while (i < self.end) {
            const line = trim(lines[i]);
            if (i < self.narrow_end) {
                try writer.writeAll("    asl\n");
                i += shift.len;
            } else if (i == self.low_add) {
                try writer.writeAll("    adc " ++ capture ++ "\n    pha\n    pla\n");
                i += add.len;
            } else {
                if (std.mem.eql(u8, line, add[4])) {
                    try writer.writeAll("    adc #0\n");
                } else if (std.mem.eql(u8, line, subtract[4])) {
                    try writer.writeAll("    sbc #0\n");
                } else try writer.print("{s}\n", .{lines[i]});
                i += 1;
            }
        }
    }
};

fn plan(lines: []const []const u8, start: usize) ?Window {
    const low = trim(lines[start]);
    const prefix = "and #";
    if (!std.mem.startsWith(u8, low, prefix)) return null;
    const mask = machine.integer(low[prefix.len..]) orelse return null;
    if (mask > 255 or !matches(lines[start + 1 ..], &mask_tail)) return null;
    var i = start + 1 + mask_tail.len;
    var result: Window = .{ .start = start, .end = i, .narrow_end = i };
    var bound = mask;
    var known_zero_high = true;
    var saw_arithmetic = false;
    while (matches(lines[i..], &shift)) {
        i += shift.len;
        known_zero_high = known_zero_high and bound <= 127;
        if (known_zero_high) {
            bound *= 2;
            result.narrow_end = i;
        }
        const addition = matches(lines[i..], &add);
        if (!addition and !matches(lines[i..], &subtract)) continue;
        // A following add or full shift overwrites each removed PHA's
        // pending byte. When collapsing the add, keep its final PHA/PLA.
        // Allow up to six of NMOS decimal low-digit correction. Below
        // $80 even after that correction, low ADC leaves C and V clear.
        if (addition and known_zero_high and bound + mask <= 121) result.low_add = i;
        saw_arithmetic = true;
        known_zero_high = false;
        i += add.len;
    }
    if (!saw_arithmetic) return null;
    result.end = i;
    return result;
}

fn eligible(program: ast.Program, assembly: []const u8) bool {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.functions.len != 0 or
        std.mem.indexOf(u8, assembly, "zeropage_test6502_expect_stack_") != null or
        std.mem.indexOf(u8, assembly, "zeropage_test6502_expect_mem_") != null) return false;
    for (program.functions) |function| {
        if (function.exported and !std.mem.eql(u8, function.name, "main")) return false;
    }
    return true;
}

/// Narrow the low end of a captured word product whose literal mask
/// proves the original high byte zero. Keep both input reads in this phase.
pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, assembly, "    and #0\n    tax\n    pla\n    sta " ++ capture ++ "\n") == null or
        !eligible(program, assembly)) return null;
    const options = program.zeropage_options;
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    const lines = graph.raw.items;
    var windows: std.ArrayList(Window) = .empty;
    defer windows.deinit(a);
    var covered: usize = 0;
    for (graph.nodes.items) |node| {
        if (node.zone != .code or node.index < covered) continue;
        if (plan(lines, node.index)) |window| {
            try windows.append(a, window);
            covered = window.end;
        }
    }
    if (windows.items.len == 0) return null;
    var model = storage.Model.init(a);
    defer model.deinit();
    try model.collect(assembly);
    if (model.resolveObject(.{ .name = capture }, 2)) |slot| {
        if (!std.mem.eql(u8, model.frames.items[slot.frame].owner, "compiler:scratch")) return null;
    } else if (!options.zero_page.declared or !storage.claimedScratch(lines, .{ .name = capture, .offset = 1 })) return null;
    if (!try literal_io.closedImage(a, program, assembly, graph, model)) return null;

    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var copied: usize = 0;
    for (windows.items) |window| {
        for (lines[copied..window.start]) |line| try output.writer.print("{s}\n", .{line});
        try window.write(&output.writer, lines);
        copied = window.end;
    }
    for (lines[copied..], copied..) |line, i| {
        try output.writer.writeAll(line);
        if (i + 1 < lines.len) try output.writer.writeByte('\n');
    }
    return try output.toOwnedSlice();
}

/// Both the range pass and the general stack-bridge fold can produce this
/// mask/capture packet. Its LDA overwrites N/Z and LDX #0 overwrites X.
/// Delete the first LDX only when its access is to a proved ordinary word.
pub fn rewriteDeadHighReads(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, assembly, "    pha\n    ldx #0\n    pla\n    sta " ++ capture ++ "\n") == null or
        !eligible(program, assembly)) return null;
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    const lines = graph.raw.items;
    var model = storage.Model.init(a);
    defer model.deinit();
    try model.collectWithPromotedParameters(assembly, lines);
    var edits: std.ArrayList(usize) = .empty;
    defer edits.deinit(a);
    for (graph.nodes.items) |node| {
        const prefix = "and #";
        if (node.zone != .code or node.index < 2 or !std.mem.startsWith(u8, node.text, prefix)) continue;
        const mask = machine.integer(node.text[prefix.len..]) orelse continue;
        if (mask > 255 or !matches(lines[node.index + 1 ..], &narrowed_tail)) continue;
        if (model.ordinaryWordLoad(lines, lines[node.index - 2], lines[node.index - 1], program.zeropage_options.zero_page.declared))
            try edits.append(a, node.index - 2);
    }
    if (edits.items.len == 0 or !try image.permitsLocalShrink(a, graph, program)) return null;

    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var copied: usize = 0;
    for (edits.items) |index| {
        for (lines[copied..index]) |line| try output.writer.print("{s}\n", .{line});
        copied = index + 1;
    }
    for (lines[copied..], copied..) |line, index| {
        try output.writer.writeAll(line);
        if (index + 1 < lines.len) try output.writer.writeByte('\n');
    }
    return try output.toOwnedSlice();
}

const zero_high_bridge = [_][]const u8{ "tay", "txa", "rol", "tax", "tya" };
const double_zero_high_bridge = zero_high_bridge ++ [_][]const u8{"asl"} ++ zero_high_bridge;
const zero_high_label = "zeropage_zero_high_rotate_";
const RotateEdit = struct { start: usize, double: bool };

/// With X=0, the shifted high byte is the carry from the low ASL.
pub fn rewriteZeroHighRotate(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, assembly, "    asl\n    tay\n    txa\n    rol\n    tax\n    tya\n") == null or
        std.ascii.indexOfIgnoreCase(assembly, zero_high_label) != null or
        program.zeropage_options.abi.default_frame != .static or !eligible(program, assembly)) return null;
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    var candidates: std.ArrayList(usize) = .empty;
    defer candidates.deinit(a);
    const lines = graph.raw.items;
    var scope: usize = 0;
    var zero_x = false;
    for (graph.nodes.items, 0..) |node, i| {
        if (node.scope != scope) {
            zero_x = false;
            scope = node.scope;
        }
        if (node.zone != .code) continue;
        if (zero_x and i != 0 and graph.nodes.items[i - 1].scope == node.scope and
            std.mem.eql(u8, graph.nodes.items[i - 1].text, "asl") and matches(lines[node.index..], &zero_high_bridge))
        {
            try candidates.append(a, node.index);
        }
        const inst = machine.Instruction.parse(node.text) orelse {
            zero_x = false; // A label can admit a different reaching X.
            continue;
        };
        if (inst.op == .ldx and inst.operand == .immediate) {
            zero_x = machine.integer(inst.operand.immediate) == 0;
            continue;
        }
        const effect = inst.effects();
        if (effect.writes & machine.x != 0 or effect.barrier) zero_x = false;
    }
    if (candidates.items.len == 0 or !try image.permitsLocalShrink(a, graph, program)) return null;

    var query = try cfg.OutputQuery.initWithLiteralIndex(a, assembly);
    defer query.deinit();
    var selected: std.ArrayList(RotateEdit) = .empty;
    defer selected.deinit(a);
    var i = candidates.items.len;
    while (i > 0) {
        i -= 1;
        const start = candidates.items[i];
        const outputs = machine.c | machine.nz | machine.y;
        const double = matches(lines[start..], &double_zero_high_bridge) and
            try query.deadAfterLine(start + double_zero_high_bridge.len - 1, outputs);
        if (!double and !try query.deadAfterLine(start + zero_high_bridge.len - 1, outputs)) continue;
        try selected.append(a, .{ .start = start, .double = double });
        query.closeEntry(start);
    }
    if (selected.items.len == 0) return null;

    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var copied: usize = 0;
    var label_id: usize = 0;
    while (selected.pop()) |edit| : (label_id += 1) {
        for (lines[copied..edit.start]) |line| try output.writer.print("{s}\n", .{line});
        if (edit.double) {
            // Place the first carry in bit 1 before shifting the low byte
            // again. The second carry can then set bit 0 with INX.
            try output.writer.print("    bcc " ++ zero_high_label ++ "{d}_first\n    ldx #2\n" ++
                zero_high_label ++ "{d}_first:\n    asl\n", .{ label_id, label_id });
        }
        try output.writer.print("    bcc " ++ zero_high_label ++ "{d}\n    inx\n" ++ zero_high_label ++ "{d}:\n", .{ label_id, label_id });
        copied = edit.start + (if (edit.double) double_zero_high_bridge.len else zero_high_bridge.len);
    }
    for (lines[copied..], copied..) |line, line_index| {
        try output.writer.writeAll(line);
        if (line_index + 1 < lines.len) try output.writer.writeByte('\n');
    }
    return try output.toOwnedSlice();
}

const rotate_header = "* = $0801\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
const rotate_footer = "    rts\n; zeropage_section_end owner=function:main kind=code\n";
const rotate_bridge = "    tay\n    txa\n    rol\n    tax\n    tya\n";
const rotate_kills = "    ldy #2\n    clc\n";

test "zero high rotate carries into X and leaves A untouched" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const start = rotate_header ++ "    ldx #0\n    lda $c100\n    asl\n";
    const input = start ++ rotate_bridge ++ rotate_kills ++ rotate_footer;
    const result = (try rewriteZeroHighRotate(a, parsed.program, input)) orelse return error.ExpectedZeroHighRotate;
    defer a.free(result);
    try std.testing.expectEqualStrings(start ++ "    bcc zeropage_zero_high_rotate_0\n    inx\nzeropage_zero_high_rotate_0:\n" ++ rotate_kills ++ rotate_footer, result);
}

test "zero high rotate declines live flags Y and alternate entries" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const start = rotate_header ++ "    ldx #0\n    lda $c100\n    asl\n";
    for ([_][]const u8{
        start ++ rotate_bridge ++ "    adc #0\n" ++ rotate_kills,
        start ++ rotate_bridge ++ "    beq done\ndone:\n" ++ rotate_kills,
        start ++ rotate_bridge ++ "    sty $c100\n" ++ rotate_kills,
        start ++ "alternate:\n" ++ rotate_bridge ++ rotate_kills,
        start ++ "    ldx $c100\n" ++ rotate_bridge ++ rotate_kills,
    }) |body| {
        const input = try std.mem.concat(a, u8, &.{ body, rotate_footer });
        defer a.free(input);
        const result = try rewriteZeroHighRotate(a, parsed.program, input);
        defer if (result) |code| a.free(code);
        try std.testing.expect(result == null);
    }
}

test "zero high rotate combines two consecutive bridges" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const start = rotate_header ++ "    ldx #0\n    lda $c100\n    asl\n";
    const pair = rotate_bridge ++ "    asl\n" ++ rotate_bridge;
    const result = (try rewriteZeroHighRotate(a, parsed.program, start ++ pair ++ rotate_kills ++ rotate_footer)) orelse
        return error.ExpectedZeroHighRotate;
    defer a.free(result);
    try std.testing.expectEqualStrings(start ++
        "    bcc zeropage_zero_high_rotate_0_first\n    ldx #2\nzeropage_zero_high_rotate_0_first:\n    asl\n" ++
        "    bcc zeropage_zero_high_rotate_0\n    inx\nzeropage_zero_high_rotate_0:\n" ++ rotate_kills ++ rotate_footer, result);
}

test "zero high rotate preserves the second bridge when its flags are live" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const start = rotate_header ++ "    ldx #0\n    lda $c100\n    asl\n";
    const suffix = "    asl\n" ++ rotate_bridge ++ "    adc #0\n" ++ rotate_kills ++ rotate_footer;
    const result = (try rewriteZeroHighRotate(a, parsed.program, start ++ rotate_bridge ++ suffix)) orelse
        return error.ExpectedZeroHighRotate;
    defer a.free(result);
    try std.testing.expectEqualStrings(start ++
        "    bcc zeropage_zero_high_rotate_0\n    inx\nzeropage_zero_high_rotate_0:\n" ++ suffix, result);
}
