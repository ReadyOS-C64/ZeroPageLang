const std = @import("std");
const ast = @import("../../ast.zig");

const cfg = @import("cfg_dead_values.zig");
const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const literal_io = @import("literal_pointer_io.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");

const Cell = union(enum) {
    resident: storage.Location,
    zero_page: u32,

    fn resolve(model: storage.Model, lines: []const []const u8, reference: machine.Symbol, width: u32, managed: bool, scratch: bool) ?Cell {
        if (model.resolveObject(reference, width)) |slot| {
            if (scratch and !std.mem.eql(u8, model.frames.items[slot.frame].owner, "compiler:scratch")) return null;
            return .{ .resident = slot };
        }
        if (!managed or reference.offset < 0) return null;
        const claim = storage.claimedAddress(lines, reference.name, if (scratch) "scratch" else "parameter") orelse return null;
        const offset: u32 = @intCast(reference.offset);
        if (offset + width > claim.width) return null;
        return .{ .zero_page = claim.address + offset };
    }

    fn disjoint(a: Cell, width_a: u32, b: Cell, width_b: u32, model: storage.Model) bool {
        return switch (a) {
            .resident => |slot| b != .resident or model.disjoint(slot, width_a, b.resident, width_b),
            .zero_page => |at| b != .zero_page or at + width_a <= b.zero_page or b.zero_page + width_b <= at,
        };
    }
};

const Packet = struct {
    start: usize,
    end: usize,
    source: []const u8,
    scratch: []const u8,

    fn matches(a: Packet, b: Packet) bool {
        return a.end - a.start <= b.end - b.start and std.mem.eql(u8, a.source, b.source) and
            std.mem.eql(u8, a.scratch, b.scratch);
    }
};

fn direct(node: layout.Line, op: machine.Op, offset: i32) ?[]const u8 {
    const inst = machine.Instruction.parse(node.text) orelse return null;
    return if (inst.op == op and inst.operand == .direct and inst.operand.direct.offset == offset)
        inst.operand.direct.name
    else
        null;
}

fn sameName(actual: ?[]const u8, expected: []const u8) bool {
    return std.mem.eql(u8, actual orelse return false, expected);
}

fn packetAt(nodes: []const layout.Line, start: usize) ?Packet {
    if (nodes.len - start < 7 or nodes[start].zone != .code) return null;
    const source = direct(nodes[start], .lda, 0) orelse return null;
    if (!sameName(direct(nodes[start + 1], .ldx, 1), source)) return null;
    const scratch = direct(nodes[start + 2], .stx, 1) orelse return null;
    var end = start + 3;
    while (end + 1 < nodes.len and std.mem.eql(u8, nodes[end].text, "asl") and
        sameName(direct(nodes[end + 1], .rol, 1), scratch)) : (end += 2)
    {}
    if (end == start + 3 or nodes.len - end < 2) return null;
    const carry = nodes[end].text;
    const op: machine.Op = if (std.mem.eql(u8, carry, "clc")) .adc else if (std.mem.eql(u8, carry, "sec")) .sbc else return null;
    if (!sameName(direct(nodes[end + 1], op, 0), source)) return null;
    for (nodes[start .. end + 2], 0..) |node, offset| {
        if (node.scope != nodes[start].scope or node.index != nodes[start].index + offset) return null;
    }
    return .{ .start = start, .end = end, .source = source, .scratch = scratch };
}

const Domain = struct {
    model: storage.Model,
    lines: []const []const u8,
    resident: literal_io.Range,
    managed: bool,

    fn cell(self: Domain, reference: machine.Symbol, width: u32, scratch: bool) ?Cell {
        return Cell.resolve(self.model, self.lines, reference, width, self.managed, scratch);
    }

    fn stableBetween(self: Domain, nodes: []const layout.Line, a: Packet, b: Packet) bool {
        if (nodes[a.start].scope != nodes[b.start].scope) return false;
        const source = self.cell(.{ .name = a.source }, 2, false) orelse return false;
        const scratch = self.cell(.{ .name = a.scratch }, 2, true) orelse return false;
        if (!source.disjoint(2, scratch, 2, self.model)) return false;
        return self.preserves(nodes[a.end..b.start], nodes[a.start].scope, source, scratch, true);
    }

    fn preserves(self: Domain, nodes: []const layout.Line, scope: usize, source: Cell, scratch: ?Cell, protect_x_reads: bool) bool {
        for (nodes) |node| {
            if (node.scope != scope) return false;
            const inst = machine.Instruction.parse(node.text) orelse return false;
            // Numeric absolute indexed operands use the assembler's literal
            // syntax. Admit only external RAM and an unchanged Y index.
            if (inst.operand == .unknown) {
                const index = layout.literalIndex(node.text) orelse return false;
                if (index.register != machine.y or !self.resident.external(index.address, 255)) return false;
                if (inst.op != .sta and inst.op != .lda) return false;
                continue;
            }
            const effects = inst.effects();
            if (effects.barrier or effects.writes & machine.x != 0 or
                (protect_x_reads and effects.reads & machine.x != 0)) return false;
            if (effects.memory != .write and effects.memory != .read_write) continue;
            switch (inst.operand) {
                .address => |addr| if (!self.resident.external(addr, 0)) return false,
                .direct => |ref| {
                    const write = self.cell(ref, 1, false) orelse self.cell(ref, 1, true) orelse return false;
                    if (!write.disjoint(1, source, 2, self.model)) return false;
                    if (scratch) |word| if (!write.disjoint(1, word, 2, self.model)) return false;
                },
                else => return false,
            }
        }
        return true;
    }
};

const Edit = struct { first: Packet, second: Packet };

/// Reuse A's shifted low byte through X and keep the existing high byte
/// in scratch. Both arithmetic packets establish carry before using A.
pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    if (!eligible(program) or std.mem.indexOf(u8, assembly, "    asl\n    rol ") == null) return null;
    const options = program.zeropage_options;
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    const upper = (try image.residentLayoutUpperBound(a, assembly)) orelse return null;
    const lines = graph.raw.items;
    var model = storage.Model.init(a);
    defer model.deinit();
    try model.collectWithPromotedParameters(assembly, lines);
    const domain: Domain = .{ .model = model, .lines = lines, .managed = options.zero_page.declared, .resident = .{ .start = options.image.load_addr, .end = upper } };
    const nodes = graph.nodes.items;
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(a);
    var previous: ?Packet = null;
    var at: usize = 0;
    while (at < nodes.len) {
        const next = packetAt(nodes, at) orelse {
            at += 1;
            continue;
        };
        at = next.end;
        if (previous) |first| {
            if (first.matches(next) and domain.stableBetween(nodes, first, next)) {
                try edits.append(a, .{ .first = first, .second = next });
            }
        }
        previous = next;
    }
    if (edits.items.len == 0 or !try image.permitsLocalShrink(a, graph, program) or
        !try literal_io.closedImage(a, program, assembly, graph, model)) return null;

    var query = try cfg.OutputQuery.initWithLiteralIndex(a, assembly);
    defer query.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var copied: usize = 0;
    for (edits.items, 0..) |edit, i| {
        const first_end = nodes[edit.first.end].index;
        const second_start = nodes[edit.second.start].index;
        const second_end = nodes[edit.second.end].index;
        if (i == 0 or edits.items[i - 1].second.start != edit.first.start) {
            for (lines[copied..first_end]) |line| try out.writer.print("{s}\n", .{line});
            try out.writer.writeAll("    tax\n");
            copied = first_end;
        }
        for (lines[copied..second_start]) |line| try out.writer.print("{s}\n", .{line});
        try out.writer.writeAll("    txa\n");
        const shared_end = second_start + edit.first.end - edit.first.start;
        for (lines[shared_end..second_end]) |line| try out.writer.print("{s}\n", .{line});
        const continues = i + 1 < edits.items.len and edits.items[i + 1].first.start == edit.second.start;
        if (continues) {
            if (shared_end != second_end) try out.writer.writeAll("    tax\n");
        } else if (!try query.deadAfterLine(second_end - 1, machine.x)) {
            // A later chain retains its first LDX. The other entries
            // into that chain are excluded by stableBetween.
            try out.writer.print("{s}\n", .{lines[second_start + 1]});
        }
        copied = second_end;
    }
    for (lines[copied..], copied..) |line, i| {
        try out.writer.writeAll(line);
        if (i + 1 < lines.len) try out.writer.writeByte('\n');
    }
    return try out.toOwnedSlice();
}

const parser = @import("../../parser.zig");
const a_test = std.testing.allocator;
const header = "* = $0801\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
const prefix = "    lda value\n    ldx value+1\n    stx scratch+1\n    asl\n    rol scratch+1\n";
const subtract = "    sec\n    sbc value\n    sta $c110,y\n    lda scratch+1\n    sbc value+1\n    sta $c112,y\n";
const add = "    clc\n    adc value\n    sta $c114,y\n    lda scratch+1\n    adc value+1\n    sta $c116,y\n";
const footer = "    rts\n; zeropage_section_end owner=function:main kind=code\n" ++
    "; zeropage_section_begin owner=function:main kind=static_frame\nvalue:\n    .word 0\n" ++
    "; zeropage_section_end owner=function:main kind=static_frame\n" ++
    "; zeropage_section_begin owner=compiler kind=scratch\nscratch:\n    .word 0\n" ++
    "; zeropage_section_end owner=compiler kind=scratch\n";

test "shifted products share the prefix and only reload X when live" {
    const parsed = try parser.parseSource(a_test, "export fn main() void {}");
    defer parsed.deinit(a_test);
    const input = header ++ prefix ++ subtract ++ "; inline packet boundary\n" ++ prefix ++ add;
    const shared = header ++ prefix ++ "    tax\n" ++ subtract ++ "; inline packet boundary\n    txa\n";
    const kept = (try rewrite(a_test, parsed.program, input ++ footer)) orelse return error.ExpectedProductReuse;
    defer a_test.free(kept);
    try std.testing.expectEqualStrings(shared ++ "    ldx value+1\n" ++ add ++ footer, kept);
    const kill = "    ldx #7\n";
    const dead = (try rewrite(a_test, parsed.program, input ++ kill ++ footer)) orelse return error.ExpectedProductReuse;
    defer a_test.free(dead);
    try std.testing.expectEqualStrings(shared ++ add ++ kill ++ footer, dead);
    const extra = "    asl\n    rol scratch+1\n";
    const longer = header ++ prefix ++ subtract ++ prefix ++ extra ++ add ++ kill ++ footer;
    const extended = (try rewrite(a_test, parsed.program, longer)) orelse return error.ExpectedProductReuse;
    defer a_test.free(extended);
    try std.testing.expectEqualStrings(header ++ prefix ++ "    tax\n" ++ subtract ++ "    txa\n" ++ extra ++ add ++ kill ++ footer, extended);
    const triple = header ++ prefix ++ subtract ++ prefix ++ extra ++ add ++ prefix ++ extra ++ subtract ++ kill ++ footer;
    const chained = (try rewrite(a_test, parsed.program, triple)) orelse return error.ExpectedProductReuse;
    defer a_test.free(chained);
    try std.testing.expectEqualStrings(header ++ prefix ++ "    tax\n" ++ subtract ++ "    txa\n" ++ extra ++ "    tax\n" ++ add ++ "    txa\n" ++ subtract ++ kill ++ footer, chained);
}

test "shifted products decline unstable operands, X users and alternate entries" {
    const parsed = try parser.parseSource(a_test, "export fn main() void {}");
    defer parsed.deinit(a_test);
    for ([_][]const u8{
        "    sta value+1\n", "    sta scratch+1\n", "    txa\n",
        "    sta $c112,x\n", "    sta ($fb),y\n",   "alternate:\n",
        "    sta $d020\n",
    }) |between| {
        const input = try std.mem.concat(a_test, u8, &.{ header, prefix, subtract, between, prefix, add, footer });
        defer a_test.free(input);
        const result = try rewrite(a_test, parsed.program, input);
        defer if (result) |text| a_test.free(text);
        try std.testing.expect(result == null);
    }
    const changed_count = header ++ prefix ++ "    asl\n    rol scratch+1\n" ++ subtract ++ prefix ++ add ++ footer;
    try std.testing.expect((try rewrite(a_test, parsed.program, changed_count)) == null);
}

fn eligible(program: ast.Program) bool {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.default_frame != .static or options.abi.functions.len != 0) return false;
    for (program.functions) |function| {
        if (function.exported and !std.mem.eql(u8, function.name, "main")) return false;
    }
    return true;
}

const HighPacket = struct {
    start: usize,
    end: usize,
    source: []const u8,
    scratch: ?[]const u8 = null,
};

fn highPacketAt(nodes: []const layout.Line, start: usize) ?HighPacket {
    if (nodes.len - start < 5 or nodes[start].zone != .code) return null;
    const source = direct(nodes[start], .lda, 0) orelse return null;
    var packet: HighPacket = .{ .start = start, .end = start + 5, .source = source };
    if (std.mem.eql(u8, nodes[start + 1].text, "asl")) {
        if (nodes.len - start < 7 or !std.mem.eql(u8, nodes[start + 2].text, "tay") or
            !sameName(direct(nodes[start + 3], .lda, 1), source) or
            !std.mem.eql(u8, nodes[start + 4].text, "rol") or !std.mem.eql(u8, nodes[start + 5].text, "tax") or
            !std.mem.eql(u8, nodes[start + 6].text, "tya")) return null;
        packet.end = start + 7;
    } else {
        if (!sameName(direct(nodes[start + 1], .ldx, 1), source)) return null;
        const scratch = direct(nodes[start + 2], .stx, 1) orelse return null;
        if (!std.mem.eql(u8, nodes[start + 3].text, "asl") or
            !sameName(direct(nodes[start + 4], .rol, 1), scratch)) return null;
        packet.scratch = scratch;
    }
    for (nodes[start..packet.end], 0..) |node, offset| {
        if (node.scope != nodes[start].scope or node.index != nodes[start].index + offset) return null;
    }
    return packet;
}

const HighEdit = struct { packet: HighPacket, keep_register: bool = true, selected: bool = false };

/// Recompute the low shift in A and reuse the high byte already in X.
pub fn rewriteHigh(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    if (!eligible(program) or std.mem.indexOf(u8, assembly, "    asl\n    tay\n") == null) return null;
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    const upper = (try image.residentLayoutUpperBound(a, assembly)) orelse return null;
    const lines = graph.raw.items;
    var model = storage.Model.init(a);
    defer model.deinit();
    try model.collectWithPromotedParameters(assembly, lines);
    const options = program.zeropage_options;
    const domain: Domain = .{ .model = model, .lines = lines, .managed = options.zero_page.declared, .resident = .{ .start = options.image.load_addr, .end = upper } };
    const nodes = graph.nodes.items;
    var edits: std.ArrayList(HighEdit) = .empty;
    defer edits.deinit(a);
    var producer: ?HighPacket = null;
    var at: usize = 0;
    while (at < nodes.len) {
        const packet = highPacketAt(nodes, at) orelse {
            at += 1;
            continue;
        };
        at = packet.end;
        const prior = producer;
        producer = if (packet.scratch == null) packet else null;
        const first = prior orelse continue;
        const scope = nodes[first.start].scope;
        if (scope != nodes[packet.start].scope or !std.mem.eql(u8, first.source, packet.source)) continue;
        const source = domain.cell(.{ .name = packet.source }, 2, false) orelse continue;
        if (packet.scratch) |name| {
            const scratch = domain.cell(.{ .name = name }, 2, true) orelse continue;
            if (!source.disjoint(2, scratch, 2, model)) continue;
        }
        if (domain.preserves(nodes[first.end..packet.start], scope, source, null, false)) {
            try edits.append(a, .{ .packet = packet });
        }
    }
    if (edits.items.len == 0 or !try image.permitsLocalShrink(a, graph, program) or
        !try literal_io.closedImage(a, program, assembly, graph, model)) return null;

    var query = try cfg.OutputQuery.initWithLiteralIndex(a, assembly);
    defer query.deinit();
    var i = edits.items.len;
    var any = false;
    while (i > 0) {
        i -= 1;
        const edit = &edits.items[i];
        const start = nodes[edit.packet.start].index;
        const end = nodes[edit.packet.end - 1].index;
        if (edit.packet.scratch != null) {
            if (!try query.deadAfterLine(end, machine.c | machine.nz)) continue;
            edit.keep_register = !try query.deadAfterLine(end, machine.x);
            // The new STX reads the reaching X before any restore.
            query.markRemoved(start + 1);
            query.markRemoved(end);
        } else {
            if (!try query.deadAfterLine(end, machine.c)) continue;
            edit.keep_register = !try query.deadAfterLine(end, machine.y);
            for (start + 3..end + 1) |line| query.markRemoved(line);
            if (!edit.keep_register) query.markRemoved(start + 2);
        }
        edit.selected = true;
        any = true;
    }
    if (!any) return null;

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var copied: usize = 0;
    for (edits.items) |edit| {
        if (!edit.selected) continue;
        const start = nodes[edit.packet.start].index;
        for (lines[copied .. start + 1]) |line| try out.writer.print("{s}\n", .{line});
        try out.writer.writeAll("    asl\n");
        if (edit.packet.scratch != null) {
            try out.writer.print("{s}\n", .{lines[start + 2]});
            if (edit.keep_register) try out.writer.print("{s}\n", .{lines[start + 1]});
        } else if (edit.keep_register) try out.writer.writeAll("    tay\n");
        copied = nodes[edit.packet.end - 1].index + 1;
    }
    for (lines[copied..], copied..) |line, line_index| {
        try out.writer.writeAll(line);
        if (line_index + 1 < lines.len) try out.writer.writeByte('\n');
    }
    return try out.toOwnedSlice();
}

const register_bridge = "    lda value\n    asl\n    tay\n    lda value+1\n    rol\n    tax\n    tya\n";
const bridge_low = "    lda value\n    asl\n";
const publish = "    clc\n    adc value\n    ldy #1\n    sta $c110,y\n    txa\n    adc value+1\n    sta $c111,y\n";

test "shifted high byte is reused by register and scratch bridges" {
    const parsed = try parser.parseSource(a_test, "export fn main() void {}");
    defer parsed.deinit(a_test);
    const base = header ++ register_bridge ++ publish;
    const suffix = "    asl\n    tay\n    txa\n    rol\n    tax\n    tya\n" ++ add ++ footer;
    const reg = (try rewriteHigh(a_test, parsed.program, base ++ register_bridge ++ suffix)) orelse return error.ExpectedHighReuse;
    defer a_test.free(reg);
    try std.testing.expectEqualStrings(base ++ bridge_low ++ suffix, reg);

    const scratch_suffix = "    asl\n    rol scratch+1\n" ++ add ++ footer;
    const mem = (try rewriteHigh(a_test, parsed.program, base ++ prefix ++ scratch_suffix)) orelse return error.ExpectedHighReuse;
    defer a_test.free(mem);
    try std.testing.expectEqualStrings(base ++ bridge_low ++ "    stx scratch+1\n    ldx value+1\n" ++ scratch_suffix, mem);
}

test "shifted high byte reuse keeps flag consumers and clobbered values" {
    const parsed = try parser.parseSource(a_test, "export fn main() void {}");
    defer parsed.deinit(a_test);
    const base = header ++ register_bridge ++ publish;
    const live_y = "    clc\n    sta $c110,y\n" ++ footer;
    const kept_y = (try rewriteHigh(a_test, parsed.program, base ++ register_bridge ++ live_y)) orelse return error.ExpectedHighReuse;
    defer a_test.free(kept_y);
    try std.testing.expectEqualStrings(base ++ bridge_low ++ "    tay\n" ++ live_y, kept_y);
    for ([_][]const u8{ "    ldx #2\n", "    inc value\n", "alternate:\n" }) |clobber| {
        const input = try std.mem.concat(a_test, u8, &.{ base, clobber, register_bridge, live_y });
        defer a_test.free(input);
        const refused = try rewriteHigh(a_test, parsed.program, input);
        defer if (refused) |out| a_test.free(out);
        try std.testing.expect(refused == null);
    }
    const carry = "    bcs done\n    lda #1\ndone:\n" ++ footer;
    try std.testing.expect((try rewriteHigh(a_test, parsed.program, base ++ register_bridge ++ carry)) == null);
}
