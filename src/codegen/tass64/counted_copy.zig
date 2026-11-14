const std = @import("std");
const ast = @import("../../ast.zig");
const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");

const scratch = "zeropage_ptr_tmp";
const begin = "; zeropage_loop_begin id=";
const capture_marker = "; zeropage_loop_capture source=";
const read_marker = "; zeropage_pointer_read source=";
const packet_len = 28;

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn after(raw: []const u8, prefix: []const u8) ?[]const u8 {
    const line = trim(raw);
    return if (std.mem.startsWith(u8, line, prefix)) line[prefix.len..] else null;
}

fn refIs(line: []const u8, prefix: []const u8, name: []const u8, suffix: []const u8) bool {
    const operand = after(line, prefix) orelse return false;
    return operand.len == name.len + suffix.len and std.mem.startsWith(u8, operand, name) and same(operand[name.len..], suffix);
}

const Loop = struct {
    start: usize,
    count: u32,
    counter: []const u8,
    capture: []const u8,
    pointer: []const u8,
    target: []const u8,
    top: []const u8,
    body: []const u8,
    next: []const u8,
    done: []const u8,

    fn write(self: Loop, writer: *std.Io.Writer, lines: []const []const u8) !void {
        const packet = lines[self.start .. self.start + packet_len];
        try writer.print("{s}\n{s}\n    ; zeropage_loop_invariant source={s}\n", .{ packet[0], packet[1], self.pointer });
        for (packet[13..17]) |line| try writer.print("{s}\n", .{line});
        try writer.print("    ldy #0\n{s}\n{s}\n    sty {s}\n{s}\n{s}\n    ; zeropage_loop_pointer_read\n", .{
            packet[5], packet[6], self.capture, packet[8], packet[9],
        });
        try writer.print("{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n", .{ packet[17], packet[18], packet[21], packet[22], packet[23], packet[24] });
        // The fixed body plus latch is at most 23 bytes with absolute slots.
        try writer.print("    iny\n    cpy #{d}\n    bcc {s}\n    dey\n{s}\n{s}\n{s}\n{s}\n", .{
            self.count, self.body, packet[2], packet[3], packet[26], packet[27],
        });
    }
};

fn loopLabel(label: []const u8, id: []const u8, suffix: []const u8) bool {
    return refIs(label, "for_", id, suffix);
}

fn match(lines: []const []const u8, start: usize) ?Loop {
    const header = after(lines[start], begin) orelse return null;
    const split = std.mem.indexOf(u8, header, " count=") orelse return null;
    const id = header[0..split];
    if (id.len == 0) return null;
    for (id) |char| if (!std.ascii.isDigit(char)) return null;
    const count = machine.integer(header[split + " count=".len ..]) orelse return null;
    if (count == 0 or count > 255 or start < 3 or lines.len - start < packet_len) return null;
    const p = lines[start .. start + packet_len];
    const top = layout.label(trim(p[1])) orelse return null;
    const body = layout.label(trim(p[5])) orelse return null;
    const next = layout.label(trim(p[23])) orelse return null;
    const done = layout.label(trim(p[26])) orelse return null;
    if (!loopLabel(top, id, "_top") or !loopLabel(body, id, "_body") or
        !loopLabel(next, id, "_next") or !loopLabel(done, id, "_done") or
        !refIs(p[27], "; zeropage_loop_end id=", id, "")) return null;

    const counter = after(p[2], "lda ") orelse return null;
    const capture = after(p[6], capture_marker) orelse return null;
    const read = after(p[12], read_marker) orelse return null;
    const read_width = " bytes=1";
    if (!std.mem.endsWith(u8, read, read_width)) return null;
    const pointer = read[0 .. read.len - read_width.len];
    const store = after(p[22], "sta ") orelse return null;
    if (!std.mem.endsWith(u8, store, ",y")) return null;
    const target = store[0 .. store.len - 2];
    if (!same(trim(lines[start - 3]), "lda #0") or !refIs(lines[start - 2], "sta ", counter, "") or
        !refIs(lines[start - 1], "sta ", counter, "+1") or
        machine.integer(after(p[3], "cmp #") orelse return null) != count or !refIs(p[4], "bcs ", done, "")) return null;
    if (!refIs(p[7], "sta ", capture, "") or !same(trim(p[8]), "lda #0") or
        !refIs(p[9], "sta ", capture, "+1") or !refIs(p[10], "lda ", capture, "") or !same(trim(p[11]), "tay") or
        !refIs(p[13], "lda ", pointer, "") or !same(trim(p[14]), "sta " ++ scratch) or
        !refIs(p[15], "lda ", pointer, "+1") or !same(trim(p[16]), "sta " ++ scratch ++ "+1") or
        !same(trim(p[17]), "lda (" ++ scratch ++ "),y") or !same(trim(p[18]), "pha") or
        !refIs(p[19], "lda ", capture, "") or !same(trim(p[20]), "tay") or !same(trim(p[21]), "pla") or
        !refIs(p[24], "inc ", counter, "") or !refIs(p[25], "jmp ", top, "")) return null;

    return .{ .start = start, .count = count, .counter = counter, .capture = capture, .pointer = pointer, .target = target, .top = top, .body = body, .next = next, .done = done };
}

fn frameObject(model: storage.Model, owner: []const u8, name: []const u8, size: u32) ?storage.Location {
    const result = model.resolveObject(.{ .name = name }, size) orelse return null;
    return if (same(model.frames.items[result.frame].owner, owner)) result else null;
}

fn definitionIndex(graph: layout.Analysis, name: []const u8) ?usize {
    const index = graph.target(name) orelse return null;
    return graph.nodes.items[index].index + 1;
}

fn wordDefinition(graph: layout.Analysis, name: []const u8) bool {
    const index = definitionIndex(graph, name) orelse return false;
    return index < graph.raw.items.len and same(trim(graph.raw.items[index]), ".word 0");
}

fn byteExtent(graph: layout.Analysis, name: []const u8, count: u32) bool {
    const index = definitionIndex(graph, name) orelse return false;
    var width: u32 = 0;
    for (graph.raw.items[index..]) |raw| {
        const line = trim(raw);
        if (!std.mem.startsWith(u8, line, ".byte ")) break;
        width += storage.dataBytes(line) orelse return false;
        if (width >= count) return true;
    }
    return false;
}

fn scratchAddress(lines: []const []const u8, managed: bool) ?u32 {
    if (managed) {
        const claim = storage.claimedAddress(lines, scratch, "pointer") orelse return null;
        return if (claim.width == 2 and claim.address <= 253) claim.address else null;
    }
    for (lines) |line| if (same(trim(line), scratch ++ " = $fb")) return 251;
    return null;
}

fn verify(graph: layout.Analysis, model: storage.Model, owner: []const u8, loop: Loop, managed: bool) bool {
    const counter = frameObject(model, owner, loop.counter, 2) orelse return false;
    const capture = frameObject(model, owner, loop.capture, 2) orelse return false;
    const target = frameObject(model, owner, loop.target, loop.count) orelse return false;
    if (!wordDefinition(graph, loop.counter) or !wordDefinition(graph, loop.capture) or !byteExtent(graph, loop.target, loop.count) or
        !model.disjoint(counter, 2, capture, 2) or !model.disjoint(counter, 2, target, loop.count) or
        !model.disjoint(capture, 2, target, loop.count)) return false;
    const pair = scratchAddress(graph.raw.items, managed) orelse return false;
    if (frameObject(model, owner, loop.pointer, 2)) |pointer| {
        if (!wordDefinition(graph, loop.pointer) or !model.disjoint(pointer, 2, counter, 2) or
            !model.disjoint(pointer, 2, capture, 2) or !model.disjoint(pointer, 2, target, loop.count)) return false;
    } else {
        if (!managed) return false;
        const claim = storage.claimedAddress(graph.raw.items, loop.pointer, "parameter") orelse return false;
        if (claim.width != 2 or claim.address > 253 or (claim.address < pair + 2 and pair < claim.address + 2)) return false;
    }
    // Every interior entry must execute the original initialization and
    // the same packet. The canonical backedge is the only loop-label use.
    for (graph.nodes.items) |node| {
        if (node.index >= loop.start and node.index < loop.start + packet_len) continue;
        for ([_][]const u8{ loop.top, loop.body, loop.next, loop.done }) |label| {
            if (layout.tokenPresent(node.text, label)) return false;
        }
    }
    return true;
}

pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.functions.len != 0 or
        std.mem.indexOf(u8, assembly, read_marker) == null or std.mem.indexOf(u8, assembly, begin) == null or
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
    var loops: std.ArrayList(Loop) = .empty;
    defer loops.deinit(a);
    var owner: ?[]const u8 = null;
    for (lines, 0..) |line, index| {
        if (std.mem.startsWith(u8, line, "; zeropage_section_")) owner = storage.sectionOwner(line, "code");
        const function = owner orelse continue;
        const loop = match(lines, index) orelse continue;
        if (verify(graph, model, function, loop, options.zero_page.declared)) try loops.append(a, loop);
    }
    if (loops.items.len == 0 or !try image.permitsLocalShrink(a, graph, program)) return null;
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var copied: usize = 0;
    for (loops.items) |loop| {
        for (lines[copied..loop.start]) |line| try output.writer.print("{s}\n", .{line});
        try loop.write(&output.writer, lines);
        copied = loop.start + packet_len;
    }
    for (lines[copied..], copied..) |line, index| {
        try output.writer.writeAll(line);
        if (index + 1 < lines.len) try output.writer.writeByte('\n');
    }
    return try output.toOwnedSlice();
}
