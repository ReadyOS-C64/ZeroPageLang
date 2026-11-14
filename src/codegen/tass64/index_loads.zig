const std = @import("std");
const ast = @import("../../ast.zig");
const cfg = @import("cfg_dead_values.zig");
const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn commentsEnd(lines: []const []const u8, start: usize) usize {
    var i = start;
    while (i < lines.len and same(trim(lines[i]), "; zeropage_loop_pointer_read")) : (i += 1) {}
    return i;
}

fn canLoadY(inst: machine.Instruction) bool {
    // LDY and LDA share the encodings and bus accesses for these modes.
    return switch (inst.operand) {
        .immediate, .direct, .address => true,
        .indexed => |idx| idx.register == machine.x,
        else => false,
    };
}

fn tableLoad(model: storage.Model, line: []const u8) ?machine.Symbol {
    const load = machine.Instruction.parse(line) orelse return null;
    if (load.op != .lda or load.operand != .indexed or load.operand.indexed.register != machine.x) return null;
    const table = load.operand.indexed.base;
    const slot = model.resolve(table, 1) orelse return null;
    // LDA and LDY must both assemble as absolute,X. All possible reads
    // including page-crossing dummy reads must be in ordinary RAM.
    const frame = model.frames.items[slot.frame];
    if (frame.lower < 0x0200 or frame.upper + 255 >= 0x8000) return null;
    return table;
}

fn directSlot(line: []const u8, op: machine.Op) ?machine.Symbol {
    const inst = machine.Instruction.parse(line) orelse return null;
    if (inst.op != op or inst.operand != .direct) return null;
    return inst.operand.direct;
}

fn editedLine(lines: []const []const u8, replacements: []const ?[]const u8, index: usize) []const u8 {
    return replacements[index] orelse lines[index];
}

// Hold one table index in Y while keeping its published value and the
// memory access order. Intervening table reads use X and each store must
// be disjoint from the forwarded slot. Stop at labels and other effects.
fn forwardTableIndex(a: std.mem.Allocator, model: storage.Model, lines: []const []const u8, replacements: []?[]const u8, start: usize) !void {
    const first = editedLine(lines, replacements, start);
    if (lines.len - start < 4 or tableLoad(model, first) == null) return;
    const store = editedLine(lines, replacements, start + 1);
    const slot = directSlot(store, .sta) orelse return;
    const location = model.resolveObject(slot, 1) orelse return;
    if (model.frames.items[location.frame].upper > 0x8000) return;
    var load_index = start + 2;
    while (load_index + 1 < lines.len) : (load_index += 2) {
        if (tableLoad(model, editedLine(lines, replacements, load_index)) == null) break;
        const written = directSlot(editedLine(lines, replacements, load_index + 1), .sta) orelse return;
        const other = model.resolveObject(written, 1) orelse return;
        if (!model.disjoint(location, 1, other, 1)) return;
    }
    if (load_index >= lines.len) return;
    const reload = directSlot(editedLine(lines, replacements, load_index), .ldy) orelse return;
    if (slot.offset != reload.offset or !same(slot.name, reload.name)) return;
    const after_reload = load_index + 1 + @as(usize, @intFromBool(replacements[load_index] != null and
        load_index + 1 < lines.len and replacements[load_index + 1] != null and replacements[load_index + 1].?.len == 0));
    const consumer = commentsEnd(lines, after_reload);
    if (consumer >= lines.len) return;
    const next = machine.Instruction.parse(lines[consumer]) orelse return;
    if (next.op != .lda or next.operand != .indirect or !std.mem.endsWith(u8, next.operand.indirect, "),y")) return;
    replacements[start] = try std.fmt.allocPrint(a, "    ldy{s}", .{trim(first)[3..]});
    replacements[start + 1] = try std.fmt.allocPrint(a, "    sty{s}", .{trim(store)[3..]});
    replacements[load_index] = "";
}

fn directIndex(a: std.mem.Allocator, model: storage.Model, query: *cfg.OutputQuery, lines: []const []const u8, replacements: []?[]const u8, start: usize) !void {
    if (start + 2 >= lines.len or !same(trim(lines[start + 1]), "tay")) return;
    var end = start + 2;
    while (end < lines.len) {
        const inst = machine.Instruction.parse(lines[end]) orelse break;
        if (inst.op != .lda or inst.operand != .indexed or inst.operand.indexed.register != machine.y) break;
        const ref = inst.operand.indexed.base;
        const cell = model.resolve(ref, 1) orelse break;
        const frame = model.frames.items[cell.frame];
        // LDA zp,X can wrap where LDA abs,Y cannot. Use the same absolute
        // addressing on both versions, including the page-crossing read.
        if (frame.lower < 0x0200 or !std.mem.endsWith(u8, trim(lines[end]), ",y")) break;
        if (end + 1 == lines.len) break;
        const store = machine.Instruction.parse(lines[end + 1]);
        end += 1;
        if (store == null or store.?.op != .sta or store.?.operand != .direct) break;
        end += 1;
    }
    if (end == start + 2) return;
    for (replacements[start..end]) |edit| if (edit != null) return;
    if (!try query.deadAfterLine(end - 1, machine.y)) return;
    replacements[start] = "";
    replacements[start + 1] = "";
    for (start + 2..end) |i| {
        const line = trim(lines[i]);
        if (!std.mem.startsWith(u8, line, "lda ")) continue;
        replacements[i] = try std.fmt.allocPrint(a, "    {s}x", .{line[0 .. line.len - 1]});
    }
    query.closeEntry(start);
}

pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.abi.default_frame != .static or options.abi.functions.len != 0 or options.memory.placements.len != 0 or
        (std.mem.indexOf(u8, assembly, "    tay\n") == null and
            std.mem.indexOf(u8, assembly, "; zeropage_loop_pointer_read") == null)) return null;
    for (program.functions) |function| {
        if (function.exported and !same(function.name, "main")) return null;
    }
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const temporary = scratch.allocator();
    const lines = graph.raw.items;
    const replacements = try temporary.alloc(?[]const u8, lines.len);
    @memset(replacements, null);
    var model = storage.Model.init(a);
    defer model.deinit();
    try model.collectWithPromotedParameters(assembly, lines);
    var query = try cfg.OutputQuery.initWithLiteralIndex(a, assembly);
    defer query.deinit();
    var n = graph.nodes.items.len;
    while (n != 0) {
        n -= 1;
        const node = graph.nodes.items[n];
        const i = node.index;
        if (node.zone != .code or i + 2 >= lines.len or !same(trim(lines[i + 1]), "tay")) continue;
        const inst = machine.Instruction.parse(node.text) orelse continue;
        if (inst.op == .txa and inst.operand == .none) {
            try directIndex(temporary, model, &query, lines, replacements, i);
        } else if (inst.op == .lda and canLoadY(inst)) {
            const consumer = commentsEnd(lines, i + 2);
            if (consumer >= lines.len) continue;
            const next = machine.Instruction.parse(lines[consumer]) orelse continue;
            if (next.op != .lda or next.effects().barrier) continue;
            const operand = node.text[std.mem.indexOfAny(u8, node.text, " \t").?..];
            replacements[i] = try std.fmt.allocPrint(temporary, "    ldy{s}", .{operand});
            replacements[i + 1] = "";
        }
    }
    for (graph.nodes.items) |node| {
        if (node.zone != .code) continue;
        try forwardTableIndex(temporary, model, lines, replacements, node.index);
    }
    for (replacements) |edit| {
        if (edit != null) break;
    } else return null;
    if (!try image.permitsLocalShrink(a, graph, program)) return null;
    var output: std.Io.Writer.Allocating = .init(a);
    errdefer output.deinit();
    for (lines, replacements, 0..) |line, edit, i| {
        if (edit != null and edit.?.len == 0) continue;
        try output.writer.writeAll(edit orelse line);
        if (i + 1 < lines.len) try output.writer.writeByte('\n');
    }
    return try output.toOwnedSlice();
}

test "table forwarding retains ordered stores and rejects a changed index slot" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const head = "* = $2000\nptr = $fb\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
    const data = "; zeropage_section_end owner=function:main kind=code\n" ++
        "; zeropage_section_begin owner=function:main kind=static_frame\ntable:\n    .byte 7,8\nslot:\n    .byte 0\nother:\n    .byte 0\n" ++
        "; zeropage_section_end owner=function:main kind=static_frame\n";
    const prefix = "    lda table,x\n    sta slot\n    lda table,x\n";
    const consumer = "    ; zeropage_loop_pointer_read\n    lda (ptr),y\n    rts\n";
    const result = (try rewrite(a, parsed.program, head ++ prefix ++ "    sta other\n    ldy slot\n" ++ consumer ++ data)) orelse
        return error.ExpectedIndexRewrite;
    defer a.free(result);
    try std.testing.expectEqualStrings(head ++ "    ldy table,x\n    sty slot\n    lda table,x\n    sta other\n" ++ consumer ++ data, result);
    for ([_][]const u8{
        "    sta slot\n    ldy slot\n",
        "    sta other\nentry:\n    ldy slot\n",
        "    sta other\n    ldy other\n    sty slot\n",
    }) |body| {
        const input = try std.mem.concat(a, u8, &.{ head, prefix, body, consumer, data });
        defer a.free(input);
        const unchanged = try rewrite(a, parsed.program, input);
        defer if (unchanged) |output| a.free(output);
        // A later independent store/load may itself be forwarded.
        if (unchanged) |output| try std.testing.expect(std.mem.indexOf(u8, output, "    lda table,x\n    sta slot\n") != null);
    }
    const combined = (try rewrite(a, parsed.program, head ++
        "    txa\n    tay\n    lda table,y\n    sta slot\n    lda table,y\n    sta other\n    lda slot\n    tay\n" ++
        consumer ++ data)) orelse return error.ExpectedIndexRewrite;
    defer a.free(combined);
    try std.testing.expectEqualStrings(head ++ "    ldy table,x\n    sty slot\n    lda table,x\n    sta other\n" ++ consumer ++ data, combined);
}

test "index loads preserve indirect reads and use X for absolute tables" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const head = "* = $2000\nptr = $fb\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
    const data = "; zeropage_section_end owner=function:main kind=code\n" ++
        "; zeropage_section_begin owner=function:main kind=static_frame\ntable:\n    .byte 7,8\ncell:\n    .byte 0\n" ++
        "; zeropage_section_end owner=function:main kind=static_frame\n";
    const body = "    txa\n    tay\n    lda table,y\n    sta cell\n    lda cell\n    tay\n" ++
        "    ; zeropage_loop_pointer_read\n    lda (ptr),y\n    rts\n";
    const result = (try rewrite(a, parsed.program, head ++ body ++ data)) orelse return error.ExpectedIndexRewrite;
    defer a.free(result);
    try std.testing.expectEqualStrings(head ++ "    ldy table,x\n    sty cell\n" ++
        "    ; zeropage_loop_pointer_read\n    lda (ptr),y\n    rts\n" ++ data, result);
    for ([_][]const u8{
        "    lda cell\n    tay\nentry:\n    lda (ptr),y\n    rts\n",
        "    lda cell\n    tay\n    sta $c000\n    lda (ptr),y\n    rts\n",
        "    txa\n    tay\n    lda table,y\n    sty $c000\n    rts\n",
        "    lda (ptr),y\n    tay\n    lda (ptr),y\n    rts\n",
    }) |control| {
        const input = try std.mem.concat(a, u8, &.{ head, control, data });
        defer a.free(input);
        const untouched = try rewrite(a, parsed.program, input);
        defer if (untouched) |output| a.free(output);
        try std.testing.expect(untouched == null);
    }
    const overlap = (try rewrite(a, parsed.program, head ++
        "    txa\n    tay\n    lda table,y\n    tay\n    lda (ptr),y\n    rts\n" ++ data)) orelse return error.ExpectedIndexRewrite;
    defer a.free(overlap);
    try std.testing.expectEqualStrings(head ++
        "    lda table,x\n    tay\n    lda (ptr),y\n    rts\n" ++ data, overlap);
}
