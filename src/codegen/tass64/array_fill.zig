const std = @import("std");
const ast = @import("../../ast.zig");
const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");

const math = "zeropage_math_tmp";
const loop_prefix = "zeropage_array_fill_";
const Edit = struct { end: usize, first: machine.Symbol, value: u8, words: usize, load_x: bool };

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn immediate(line: []const u8, op: machine.Op) ?u8 {
    const inst = machine.Instruction.parse(line) orelse return null;
    if (inst.op != op or inst.operand != .immediate) return null;
    return std.math.cast(u8, machine.integer(inst.operand.immediate) orelse return null);
}

fn store(line: []const u8) ?machine.Symbol {
    const inst = machine.Instruction.parse(line) orelse return null;
    return if (inst.op == .sta and inst.operand == .direct) inst.operand.direct else null;
}

const WordStores = struct { target: machine.Symbol, len: usize };

// The first packet must establish A. Within a run the matched stores and
// optional TXA preserve its byte, so the preceding CFG pass may omit reloads.
fn wordAt(lines: []const []const u8, value: u8, known_a: ?u8) ?WordStores {
    var i: usize = 0;
    if (immediate(lines[0], .lda) == value) {
        i += 1;
    } else if (known_a != value) return null;
    if (lines.len < i + 4 or
        !std.mem.eql(u8, trim(lines[i]), "sta " ++ math) or
        !std.mem.eql(u8, trim(lines[i + 1]), "stx " ++ math ++ "+1")) return null;
    const low = store(lines[i + 2]) orelse return null;
    const transfer = std.mem.eql(u8, trim(lines[i + 3]), "txa");
    const len = i + 4 + @as(usize, @intFromBool(transfer));
    if (lines.len < len) return null;
    const high = store(lines[len - 1]) orelse return null;
    if (low.offset < 0 or high.offset != @as(i64, low.offset) + 1 or !std.mem.eql(u8, low.name, high.name)) return null;
    return .{ .target = low, .len = len };
}

test "array fill recognizes packets after constant register forwarding" {
    const first = [_][]const u8{
        "lda #7",    "sta zeropage_math_tmp", "stx zeropage_math_tmp+1",
        "sta table", "sta table+1",
    };
    const next = [_][]const u8{
        "sta zeropage_math_tmp", "stx zeropage_math_tmp+1",
        "sta table+2",           "sta table+3",
    };
    try std.testing.expectEqual(first.len, wordAt(&first, 7, null).?.len);
    try std.testing.expectEqual(next.len, wordAt(&next, 7, 7).?.len);
    try std.testing.expect(wordAt(&next, 7, null) == null);
    try std.testing.expect(wordAt(&next, 7, 6) == null);
}

fn contiguousWords(lines: []const []const u8, model: storage.Model, scratch: ?storage.Location, known_x: ?u8) ?Edit {
    const load = immediate(lines[0], .ldx);
    const value = load orelse known_x orelse return null;
    var end: usize = @intFromBool(load != null);
    if (end == lines.len) return null;
    const first = (wordAt(lines[end..], value, null) orelse return null).target;
    const origin = model.resolveObject(first, 2) orelse return null;
    const frame = model.frames.items[origin.frame];
    if (frame.lower < 0x0200 or frame.upper > 0xa000) return null;
    var words: usize = 0;
    while (words < 128 and end < lines.len) {
        const packet = wordAt(lines[end..], value, if (words != 0) value else null) orelse break;
        const loc = model.resolveObject(packet.target, 2) orelse break;
        if (loc.frame != origin.frame or loc.offset != origin.offset + 2 * words) break;
        if (scratch) |tmp| {
            if (!model.disjoint(loc, 2, tmp, 2)) break;
        }
        end += packet.len;
        words += 1;
    }
    return if (words >= 2) .{ .end = end, .first = first, .value = value, .words = words, .load_x = load != null } else null;
}

fn emit(w: *std.Io.Writer, edit: Edit, line: usize) !void {
    const first: usize = @intCast(edit.first.offset);
    const target = edit.first.name;
    if (edit.load_x) try w.print("    ldx #{d}\n", .{edit.value});
    try w.print("    lda #{d}\n    sta " ++ math ++ "\n    stx " ++ math ++ "+1\n", .{edit.value});
    if (edit.words < 6) {
        for (first..first + 2 * edit.words) |offset| try w.print("    sta {s}+{d}\n", .{ target, offset });
        return;
    }
    // At six words the paired loop beats the original scratch traffic
    // even with zero-page scratch and a page-crossing backedge.
    // BPL stops after index zero, including a half-width of 128 bytes.
    try w.print(
        "    ldx #{d}\n" ++ loop_prefix ++ "{d}:\n" ++
            "    sta {s}+{d},x\n    sta {s}+{d},x\n    dex\n    bpl " ++ loop_prefix ++ "{d}\n    ldx #{d}\n",
        .{ edit.words - 1, line, target, first, target, first + edit.words, line, edit.value },
    );
}

/// Compact adjacent equal-byte word initializers with a known X. The new
/// code leaves the same A/X, N/Z and scratch.
pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.abi.default_frame != .static or options.abi.functions.len != 0 or options.memory.placements.len != 0 or
        std.mem.indexOf(u8, assembly, "    sta " ++ math ++ "\n    stx " ++ math ++ "+1\n") == null or
        std.ascii.indexOfIgnoreCase(assembly, loop_prefix) != null) return null;
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
    const scratch = model.resolveObject(.{ .name = math }, 2);
    if (scratch) |tmp| {
        if (!std.mem.eql(u8, model.frames.items[tmp.frame].owner, "compiler:scratch")) return null;
    } else {
        const claim = storage.claimedAddress(lines, math, "scratch") orelse return null;
        if (claim.width != 2) return null;
    }
    var edits: std.AutoArrayHashMapUnmanaged(usize, Edit) = .empty;
    defer edits.deinit(a);
    var next: usize = 0;
    var scope: usize = 0;
    var known_x: ?u8 = null;
    for (graph.nodes.items) |node| {
        if (node.index < next) continue;
        if (node.zone != .code or node.scope != scope) known_x = null;
        scope = node.scope;
        if (node.zone != .code) continue;
        const inst = machine.Instruction.parse(node.text) orelse {
            known_x = null;
            continue;
        };
        if (inst.op == .ldx or inst.op == .lda) {
            if (contiguousWords(lines[node.index..], model, scratch, known_x)) |edit| {
                try edits.put(a, node.index, edit);
                next = node.index + edit.end;
                known_x = edit.value;
                continue;
            }
        }
        const effects = inst.effects();
        if (effects.barrier or effects.writes & machine.x != 0) known_x = immediate(node.text, .ldx);
    }
    if (edits.count() == 0 or !try image.permitsLocalShrink(a, graph, program)) return null;
    var output: std.Io.Writer.Allocating = .init(a);
    errdefer output.deinit();
    next = 0;
    for (edits.keys(), edits.values(), 0..) |first, edit, sequence| {
        for (lines[next..first]) |line| try output.writer.print("{s}\n", .{line});
        try emit(&output.writer, edit, sequence);
        next = first + edit.end;
    }
    for (lines[next..], next..) |line, index| {
        try output.writer.writeAll(line);
        if (index + 1 < lines.len) try output.writer.writeByte('\n');
    }
    return try output.toOwnedSlice();
}
