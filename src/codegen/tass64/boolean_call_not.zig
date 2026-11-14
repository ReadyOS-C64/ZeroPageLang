const std = @import("std");
const ast = @import("../../ast.zig");
const cfg = @import("cfg_dead_values.zig");
const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const Facts = struct {
    a: enum { zero, one, boolean, unknown } = .unknown,
    carry_set: bool = false,

    fn merge(dest: *?Facts, incoming: Facts) void {
        const old = dest.* orelse {
            dest.* = incoming;
            return;
        };
        dest.* = .{
            .a = if (old.a == incoming.a) old.a else if (old.a == .unknown or incoming.a == .unknown) .unknown else .boolean,
            .carry_set = old.carry_set and incoming.carry_set,
        };
    }

    fn after(self: Facts, inst: machine.Instruction) Facts {
        const immediate = if (inst.operand == .immediate) machine.integer(inst.operand.immediate) else null;
        const effects = inst.effects();
        var result = self;
        if (effects.writes & machine.a != 0) result.a = .unknown;
        if (effects.writes & machine.c != 0) result.carry_set = false;
        if (inst.op == .lda) {
            if (immediate == 0) result.a = .zero;
            if (immediate == 1) result.a = .one;
        }
        if (inst.op == .@"and") {
            if (immediate == 0) result.a = .zero;
            if (immediate == 1) result.a = .boolean;
        }
        if (inst.op == .sec or (inst.op == .cmp and (immediate == 0 or (immediate == 1 and self.a == .one)))) result.carry_set = true;
        return result;
    }
};

fn returnFacts(a: std.mem.Allocator, graph: layout.Analysis, entry: usize) !?Facts {
    const nodes = graph.nodes.items;
    const scope = nodes[entry].scope;
    var end = entry + 1;
    while (end < nodes.len and nodes[end].scope == scope) : (end += 1) {}
    const incoming = try a.alloc(?Facts, end - entry);
    defer a.free(incoming);
    @memset(incoming, null);
    incoming[0] = .{};
    var returned: ?Facts = null;
    for (nodes[entry..end], entry..) |node, index| {
        var facts = incoming[index - entry] orelse continue;
        if (layout.label(node.text) == null) {
            const inst = machine.Instruction.parse(node.text) orelse return null;
            if (inst.operand == .unknown) return null;
            if (inst.op == .rts) {
                if (!same(node.text, "rts") or facts.a == .unknown) return null;
                Facts.merge(&returned, facts);
                continue;
            }
            if (inst.op == .jmp or layout.conditional(inst.op)) {
                if (inst.operand != .direct or inst.operand.direct.offset != 0) return null;
                const target = graph.target(inst.operand.direct.name) orelse return null;
                if (target <= index or target >= end) return null;
                Facts.merge(&incoming[target - entry], facts);
                if (inst.op == .jmp) continue;
            } else {
                // A local return proof cannot depend on another call, a
                // status boundary or an instruction that can write the stack.
                const effects = inst.effects();
                if (effects.barrier or (effects.memory != .none and effects.memory != .read) or
                    effects.writes & machine.sp != 0) return null;
                facts = facts.after(inst);
            }
        }
        if (index + 1 == end) return null;
        Facts.merge(&incoming[index + 1 - entry], facts);
    }
    return returned;
}

const Packet = struct {
    call: usize,
    truth: usize,
    falsehood: usize,
    done: usize,
    callee: usize,
    restore_set_carry: bool,
};

fn namedLabel(name: []const u8, base: []const u8, suffix: []const u8) bool {
    return name.len == base.len + suffix.len and std.mem.startsWith(u8, name, base) and same(name[base.len..], suffix);
}

fn match(graph: layout.Analysis, program: ast.Program, start: usize) ?Packet {
    const nodes = graph.nodes.items;
    if (nodes.len - start < 8 or nodes[start].zone != .code) return null;
    const call = nodes[start].text;
    if (!std.mem.startsWith(u8, call, "jsr ")) return null;
    const name = call["jsr ".len..];
    const function = program.findFunction(name) orelse return null;
    if (function.exported) return null;
    const callee = graph.target(name) orelse return null;
    if (nodes[callee].zone != .code or !same(layout.label(nodes[callee].text).?, name) or
        (callee > 0 and nodes[callee - 1].scope == nodes[callee].scope)) return null;

    if (!same(nodes[start + 1].text, "cmp #1") or !same(nodes[start + 2].text, "lda #0") or
        !same(nodes[start + 5].text, "lda #1")) return null;
    const branch = nodes[start + 3].text;
    if (!std.mem.startsWith(u8, branch, "bcs ")) return null;
    const truth = layout.label(nodes[start + 4].text) orelse return null;
    const prefix = "bool_not_";
    if (!std.mem.startsWith(u8, truth, prefix) or !std.mem.endsWith(u8, truth, "_true") or
        truth.len <= prefix.len + "_true".len) return null;
    const base = truth[0 .. truth.len - "_true".len];
    for (base[prefix.len..]) |digit| if (!std.ascii.isDigit(digit)) return null;
    const restore = same(nodes[start + 6].text, "sec");
    const false_index = start + @as(usize, if (restore) 7 else 6);
    const done_index = false_index + 1;
    if (done_index >= nodes.len) return null;
    const falsehood = layout.label(nodes[false_index].text) orelse return null;
    const done = layout.label(nodes[done_index].text) orelse return null;
    if (!namedLabel(falsehood, base, "_false") or !namedLabel(done, base, "_done") or !same(branch["bcs ".len..], falsehood)) return null;
    for (nodes[start .. done_index + 1], 0..) |node, offset| {
        if (node.scope != nodes[start].scope or node.index != nodes[start].index + offset) return null;
    }
    if (graph.target(truth) != start + 4 or graph.target(falsehood) != false_index or graph.target(done) != done_index) return null;
    // Only the original BCS can enter a label within this window. All
    // other relative spans have both endpoints outside the rewritten bytes.
    for (nodes, 0..) |node, index| {
        if (layout.label(node.text) != null or index == start + 3) continue;
        if (layout.tokenPresent(node.text, truth) or layout.tokenPresent(node.text, falsehood) or
            layout.tokenPresent(node.text, done)) return null;
    }
    return .{
        .call = nodes[start].index,
        .truth = nodes[start + 4].index,
        .falsehood = nodes[false_index].index,
        .done = nodes[done_index].index,
        .callee = callee,
        .restore_set_carry = restore,
    };
}

pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.functions.len != 0 or
        std.mem.indexOf(u8, assembly, "    cmp #1\n    lda #0\n    bcs bool_not_") == null or
        std.mem.indexOf(u8, assembly, "zeropage_test6502_expect_stack_") != null) return null;
    for (program.functions) |function| {
        if (function.exported and !same(function.name, "main")) return null;
    }
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    var packets: std.ArrayList(Packet) = .empty;
    defer packets.deinit(a);
    var returns: std.AutoHashMap(usize, ?Facts) = .init(a);
    defer returns.deinit();
    for (graph.nodes.items, 0..) |_, index| {
        const packet = match(graph, program, index) orelse continue;
        const fact = try returns.getOrPut(packet.callee);
        if (!fact.found_existing) fact.value_ptr.* = try returnFacts(a, graph, packet.callee);
        if (fact.value_ptr.* != null) try packets.append(a, packet);
    }
    if (packets.items.len == 0 or !try image.permitsLocalShrink(a, graph, program)) return null;

    const lines = graph.raw.items;
    var query = try cfg.OutputQuery.init(a, assembly);
    defer query.deinit();
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    const w = &output.writer;
    var copied: usize = 0;
    for (packets.items) |packet| {
        const facts = returns.get(packet.callee).?.?;
        // With SEC in the old false arm, C always exits set. Otherwise it
        // classifies the input as zero or one before the inversion.
        const carry_ready = packet.restore_set_carry and facts.carry_set;
        // Other packets are behind a JSR, a barrier for this liveness query.
        const carry_needed = !carry_ready and !try query.deadAfterLine(packet.done, machine.c);
        for (lines[copied .. packet.call + 1]) |line| try w.print("{s}\n", .{line});
        try w.print("{s}\n", .{lines[packet.truth]});
        if (carry_needed and !packet.restore_set_carry) try w.writeAll("    cmp #1\n");
        try w.writeAll("    eor #1\n");
        if (carry_needed and packet.restore_set_carry) try w.writeAll("    sec\n");
        copied = packet.falsehood;
    }
    for (lines[copied..], copied..) |line, index| {
        try w.writeAll(line);
        if (index + 1 < lines.len) try w.writeByte('\n');
    }
    return try output.toOwnedSlice();
}

const parser = @import("../../parser.zig");
const test_program = "fn choose() bool { return true; } export fn main() void {}";
const test_start = "* = $2000\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
const test_packet =
    "    jsr choose\n    cmp #1\n    lda #0\n    bcs bool_not_2_false\n" ++
    "bool_not_2_true:\n    lda #1\n";
const test_join = "bool_not_2_false:\nbool_not_2_done:\n";
const test_callee =
    "    rts\n; zeropage_section_end owner=function:main kind=code\n" ++
    "; zeropage_section_begin owner=function:choose kind=code\nchoose:\n";
const test_end = "; zeropage_section_end owner=function:choose kind=code\n";
const test_returns = "    bne false_return\n    lda #1\n    sec\n    rts\nfalse_return:\n    lda #0\n    sec\n    rts\n";

test "boolean call NOT uses EOR when both return paths supply set carry" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, test_program);
    defer parsed.deinit(a);
    const original = test_start ++ test_packet ++ "    sec\n" ++ test_join ++ test_callee ++ test_returns ++ test_end;
    const expected = test_start ++ "    jsr choose\nbool_not_2_true:\n    eor #1\n" ++ test_join ++ test_callee ++ test_returns ++ test_end;
    const output = (try rewrite(a, parsed.program, original)) orelse return error.ExpectedBooleanNot;
    defer a.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "boolean call NOT restores the original physical carry when live" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, test_program);
    defer parsed.deinit(a);
    const uncertain = "    bne false_return\n    lda #1\n    clc\n    rts\nfalse_return:\n    lda #0\n    rts\n";
    const original = test_start ++ test_packet ++ "    sec\n" ++ test_join ++ test_callee ++ uncertain ++ test_end;
    const output = (try rewrite(a, parsed.program, original)) orelse return error.ExpectedBooleanNot;
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "    eor #1\n    sec\n" ++ test_join) != null);
    const no_sec = test_start ++ test_packet ++ test_join ++ test_callee ++ test_returns ++ test_end;
    const compared = (try rewrite(a, parsed.program, no_sec)) orelse return error.ExpectedBooleanNot;
    defer a.free(compared);
    try std.testing.expect(std.mem.indexOf(u8, compared, "    cmp #1\n    eor #1\n" ++ test_join) != null);
}

test "boolean call NOT may drop carry setup after an all-path kill proof" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, test_program);
    defer parsed.deinit(a);
    const original = test_start ++ test_packet ++ test_join ++ "    clc\n" ++ test_callee ++ test_returns ++ test_end;
    const output = (try rewrite(a, parsed.program, original)) orelse return error.ExpectedBooleanNot;
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "bool_not_2_true:\n    eor #1\n" ++ test_join) != null);
}

test "boolean call NOT declines unknown bytes, open entries and unproven returns" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, test_program);
    defer parsed.deinit(a);
    const prefix = test_start ++ test_packet ++ test_join ++ test_callee;
    for ([_][]const u8{
        prefix ++ "    bne unknown\n    lda #1\n    rts\nunknown:\n    lda #2\n    rts\n" ++ test_end,
        prefix ++ "    txs\n    lda #1\n    rts\n" ++ test_end,
        prefix ++ "    lda #1\n    bne choose\n    rts\n" ++ test_end,
        test_start ++ "    jmp bool_not_2_true\n" ++ test_packet ++ test_join ++ test_callee ++ test_returns ++ test_end,
    }) |original| {
        const output = try rewrite(a, parsed.program, original);
        defer if (output) |bytes| a.free(bytes);
        try std.testing.expect(output == null);
    }
}
