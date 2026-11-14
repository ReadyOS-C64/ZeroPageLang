const std = @import("std");
const ast = @import("../../ast.zig");
const cfg = @import("cfg_dead_values.zig");
const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");

const begin = "; zeropage_loop_begin id=";
const counter_scratch = "zeropage_ptr_tmp";
const latch_bytes = 10; // Absolute INC/LDA, immediate CMP, and relative BCC.

fn trim(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r");
}

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn after(line: []const u8, prefix: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, line, prefix)) line[prefix.len..] else null;
}

fn affixed(text: []const u8, prefix: []const u8, middle: []const u8, suffix: []const u8) bool {
    const rest = after(text, prefix) orelse return false;
    const end = after(rest, middle) orelse return false;
    return same(end, suffix);
}

const Loop = struct {
    top: usize,
    body: usize,
    next: usize,
    done: usize,
    counter: []const u8,
    initial_zero: bool,
    short_header: bool,
    omit_compare: bool = false,

    fn shorterFirst(_: void, a: Loop, b: Loop) bool {
        if (a.done - a.top != b.done - b.top) return a.done - a.top < b.done - b.top;
        return a.top < b.top;
    }

    fn sourceOrder(_: void, a: Loop, b: Loop) bool {
        return a.top < b.top;
    }
};

fn safePreheaderStore(graph: layout.Analysis, model: storage.Model, ref: machine.Symbol, counter: storage.Location, managed: bool) bool {
    if (model.resolve(ref, 1)) |target| return model.disjoint(target, 1, counter, 2);
    if (!same(ref.name, counter_scratch) or ref.offset < 0 or ref.offset >= 2) return false;
    if (managed) {
        const claim = storage.claimedAddress(graph.raw.items, counter_scratch, "pointer") orelse return false;
        return claim.width == 2;
    }
    for (graph.raw.items) |line| {
        if (same(trim(line), counter_scratch ++ " = $fb")) return true;
    }
    return false;
}

fn initialZero(graph: layout.Analysis, model: storage.Model, marker: usize, top: usize, counter: []const u8, slot: storage.Location, managed: bool) ?bool {
    const lines = graph.raw.items;
    if (marker < 3 or !same(trim(lines[marker - 3]), "lda #0") or
        !affixed(trim(lines[marker - 2]), "sta ", counter, "") or
        !affixed(trim(lines[marker - 1]), "sta ", counter, "+1")) return null;

    var zero = true;
    for (lines[marker + 1 .. top]) |raw| {
        const line = trim(raw);
        if (line.len == 0 or (line[0] == ';' and after(line, "; zeropage_section_") == null)) continue;
        const inst = machine.Instruction.parse(line) orelse return null;
        // No alternate entry, control transfer or unresolved store can
        // intervene between the counter initialization and its first read.
        switch (inst.op) {
            .lda => switch (inst.operand) {
                .immediate => |value| zero = machine.integer(value) == 0,
                .direct => zero = false,
                else => return null,
            },
            .sta => {
                if (inst.operand != .direct or !safePreheaderStore(graph, model, inst.operand.direct, slot, managed)) return null;
            },
            else => return null,
        }
    }
    return zero;
}

fn closedPacket(graph: layout.Analysis, top: usize, body: usize, next: usize, done: usize, backedge: usize) bool {
    const nodes = graph.nodes.items;
    const top_name = layout.label(nodes[top].text).?;
    for (nodes[top .. done + 1], top..) |node, index| {
        if (node.scope != nodes[top].scope or node.zone != .code) return false;
        if (layout.label(node.text)) |name| {
            for (nodes[0..top]) |outside| if (layout.tokenPresent(outside.text, name)) return false;
            for (nodes[done + 1 ..]) |outside| if (layout.tokenPresent(outside.text, name)) return false;
            continue;
        }
        if (index == backedge) continue;
        if (layout.tokenPresent(node.text, top_name)) return false;
        // Only the original header can branch across either changed span.
        // A retained branch to done would cross the expanded latch.
        if (index < body) continue;
        const inst = machine.Instruction.parse(node.text) orelse return false;
        if (!layout.conditional(inst.op)) continue;
        if (inst.operand != .direct or inst.operand.direct.offset != 0) return false;
        const target = graph.target(inst.operand.direct.name) orelse return false;
        if (target < body or target > next) return false;
    }
    return true;
}

fn match(graph: layout.Analysis, model: storage.Model, owner: []const u8, marker: usize, managed: bool) ?Loop {
    const lines = graph.raw.items;
    const nodes = graph.nodes.items;
    const header = after(trim(lines[marker]), begin) orelse return null;
    const split = std.mem.indexOf(u8, header, " count=") orelse return null;
    const id = header[0..split];
    if (id.len == 0) return null;
    for (id) |char| if (!std.ascii.isDigit(char)) return null;
    const count = machine.integer(header[split + " count=".len ..]) orelse return null;
    if (count == 0 or count > 255) return null;
    var names: [4][32]u8 = undefined;
    const top_name = std.fmt.bufPrint(&names[0], "for_{s}_top", .{id}) catch return null;
    const body_name = std.fmt.bufPrint(&names[1], "for_{s}_body", .{id}) catch return null;
    const next_name = std.fmt.bufPrint(&names[2], "for_{s}_next", .{id}) catch return null;
    const done_name = std.fmt.bufPrint(&names[3], "for_{s}_done", .{id}) catch return null;
    const top = graph.target(top_name) orelse return null;
    const body = graph.target(body_name) orelse return null;
    const next = graph.target(next_name) orelse return null;
    const done = graph.target(done_name) orelse return null;
    if (top >= body or body >= next or next >= done) return null;
    const top_line = nodes[top].index;
    const body_line = nodes[body].index;
    const next_line = nodes[next].index;
    const done_line = nodes[done].index;
    if (marker >= top_line or done_line != next_line + 3 or done_line + 1 >= lines.len) return null;
    const short_header = body_line == top_line + 4 and affixed(trim(lines[top_line + 3]), "bcs ", done_name, "");
    const long_header = body_line == top_line + 5 and affixed(trim(lines[top_line + 3]), "bcc ", body_name, "") and
        affixed(trim(lines[top_line + 4]), "jmp ", done_name, "");
    if (!short_header and !long_header) return null;
    if (machine.integer(after(trim(lines[top_line + 2]), "cmp #") orelse return null) != count) return null;
    if (!affixed(trim(lines[done_line + 1]), "; zeropage_loop_end id=", id, "")) return null;

    const counter = after(trim(lines[top_line + 1]), "lda ") orelse return null;
    const name = after(counter, owner) orelse return null;
    if (!affixed(name, "_for_", id, "_index") or
        !affixed(trim(lines[next_line + 1]), "inc ", counter, "") or
        !affixed(trim(lines[next_line + 2]), "jmp ", top_name, "")) return null;
    const slot = model.resolveObject(.{ .name = counter }, 2) orelse return null;
    if (!same(model.frames.items[slot.frame].owner, owner)) return null;
    const definition = nodes[graph.target(counter) orelse return null].index + 1;
    if (definition >= lines.len or !same(trim(lines[definition]), ".word 0")) return null;
    const zero = initialZero(graph, model, marker, top_line, counter, slot, managed) orelse return null;
    // The original body stays in place relative to the new 10-byte latch.
    if ((graph.maxBytes(body, next) orelse return null) > 128 - latch_bytes) return null;
    if (!closedPacket(graph, top, body, next, done, next + 2)) return null;
    return .{ .top = top_line, .body = body_line, .next = next_line, .done = done_line, .counter = counter, .initial_zero = zero, .short_header = short_header };
}

pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.functions.len != 0 or
        std.mem.indexOf(u8, assembly, begin) == null or
        std.mem.indexOf(u8, assembly, "zeropage_test6502_expect_stack_") != null) return null;
    for (program.functions) |function| {
        if (function.exported and !same(function.name, "main")) return null;
    }
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete or !try image.permitsLocalShrink(a, graph, program)) return null;
    const lines = graph.raw.items;
    var model = storage.Model.init(a);
    defer model.deinit();
    try model.collectWithPromotedParameters(assembly, lines);
    var candidates: std.ArrayList(Loop) = .empty;
    defer candidates.deinit(a);
    var owner: ?[]const u8 = null;
    for (lines, 0..) |raw, index| {
        const line = trim(raw);
        if (after(line, "; zeropage_section_") != null) owner = storage.sectionOwner(line, "code");
        const function = owner orelse continue;
        const loop = match(graph, model, function, index, options.zero_page.declared) orelse continue;
        try candidates.append(a, loop);
    }
    if (candidates.items.len == 0) return null;
    var query = try cfg.OutputQuery.init(a, assembly);
    defer query.deinit();
    // Do not use a candidate's old header as a flag kill for any other proof.
    for (candidates.items) |loop| query.closeEntry(loop.top);
    std.mem.sort(Loop, candidates.items, {}, Loop.shorterFirst);
    var chosen: std.ArrayList(Loop) = .empty;
    defer chosen.deinit(a);
    next_candidate: for (candidates.items) |candidate| {
        for (chosen.items) |other| {
            if (candidate.top <= other.done and other.top <= candidate.done) continue :next_candidate;
        }
        var loop = candidate;
        // INC, LDA and CMP on the new latch overwrite these flags without
        // reading them. A path that bypasses the latch must prove its own kill.
        loop.omit_compare = try query.deadAfterLineBeforeKill(loop.body, machine.c | machine.nz, loop.next);
        const first_bytes: usize = (if (loop.initial_zero) @as(usize, 0) else 2) +
            (if (loop.omit_compare) @as(usize, 0) else 2);
        const old_bytes: usize = if (loop.short_header) 13 else 16;
        if (latch_bytes + first_bytes < old_bytes) try chosen.append(a, loop);
    }
    if (chosen.items.len == 0) return null;
    std.mem.sort(Loop, chosen.items, {}, Loop.sourceOrder);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    const w = &output.writer;
    var copied: usize = 0;
    for (chosen.items) |loop| {
        for (lines[copied .. loop.top + 1]) |line| try w.print("{s}\n", .{line});
        if (!loop.initial_zero) try w.writeAll("    lda #0\n");
        if (!loop.omit_compare) try w.print("{s}\n", .{lines[loop.top + 2]});
        for (lines[loop.body .. loop.next + 2]) |line| try w.print("{s}\n", .{line});
        try w.print("{s}\n{s}\n    bcc {s}\n", .{
            lines[loop.top + 1], lines[loop.top + 2], layout.label(trim(lines[loop.body])).?,
        });
        copied = loop.done;
    }
    for (lines[copied..], copied..) |line, index| {
        try w.writeAll(line);
        if (index + 1 < lines.len) try w.writeByte('\n');
    }
    return try output.toOwnedSlice();
}

const capture_prefix = "; zeropage_loop_capture source=";
const RegisterLoop = struct {
    top: usize,
    body: usize,
    capture: usize,
    next: usize,
    done: usize,
    bound: u8,
};

fn privateSlot(graph: layout.Analysis, model: storage.Model, owner: []const u8, name: []const u8, accesses: []const usize) bool {
    const slot = model.resolveObject(.{ .name = name }, 2) orelse return false;
    if (!same(model.frames.items[slot.frame].owner, owner)) return false;
    const nodes = graph.nodes.items;
    const definition = graph.target(name) orelse return false;
    if (definition + 1 >= nodes.len or !same(nodes[definition + 1].text, ".word 0")) return false;
    for (nodes, 0..) |node, i| {
        if (i == definition or std.mem.indexOfScalar(usize, accesses, node.index) != null) continue;
        if (layout.tokenPresent(node.text, name)) return false;
        const inst = machine.Instruction.parse(node.text) orelse {
            // Reject a named alias at the same address and any equate or
            // emitted address expression that refers to this object.
            if (layout.label(node.text)) |label| {
                if (model.resolve(.{ .name = label }, 1)) |alias| {
                    if (!model.disjoint(alias, 1, slot, 2)) return false;
                }
            }
            continue;
        };
        const ref = switch (inst.operand) {
            .direct => |ref| ref,
            .indexed => |operand| operand.base,
            else => continue,
        };
        if (model.resolve(ref, 1)) |cell| {
            const width: u32 = if (inst.operand == .indexed) 256 else 1;
            if (!model.disjoint(cell, width, slot, 2)) return false;
        }
    }
    return true;
}

fn registerMatch(graph: layout.Analysis, model: storage.Model, owner: []const u8, marker: usize) ?RegisterLoop {
    const lines = graph.raw.items;
    const nodes = graph.nodes.items;
    const header = after(trim(lines[marker]), begin) orelse return null;
    const split = std.mem.indexOf(u8, header, " count=") orelse return null;
    const id = header[0..split];
    const bound = std.math.cast(u8, machine.integer(header[split + " count=".len ..]) orelse return null) orelse return null;
    if (bound == 0) return null;
    var names: [4][32]u8 = undefined;
    const top = graph.target(std.fmt.bufPrint(&names[0], "for_{s}_top", .{id}) catch return null) orelse return null;
    const body_name = std.fmt.bufPrint(&names[1], "for_{s}_body", .{id}) catch return null;
    const body = graph.target(body_name) orelse return null;
    const next = graph.target(std.fmt.bufPrint(&names[2], "for_{s}_next", .{id}) catch return null) orelse return null;
    const done = graph.target(std.fmt.bufPrint(&names[3], "for_{s}_done", .{id}) catch return null) orelse return null;
    if (top >= body or body >= next or next >= done or marker >= nodes[top].index) return null;
    const top_line = nodes[top].index;
    const body_line = nodes[body].index;
    const next_line = nodes[next].index;
    const done_line = nodes[done].index;
    if (body_line != top_line + 2 or !same(trim(lines[top_line + 1]), "lda #0") or
        next_line <= body_line + 2 or done_line != next_line + 5 or done_line + 1 >= lines.len or marker < 2) return null;
    const capture = after(trim(lines[body_line + 1]), capture_prefix) orelse return null;
    if (!affixed(trim(lines[body_line + 2]), "sta ", capture, "")) return null;
    const counter = after(trim(lines[next_line + 1]), "inc ") orelse return null;
    if (!affixed(after(counter, owner) orelse return null, "_for_", id, "_index") or
        !affixed(trim(lines[marker - 2]), "sta ", counter, "") or !affixed(trim(lines[marker - 1]), "sta ", counter, "+1") or
        !affixed(trim(lines[next_line + 2]), "lda ", counter, "") or
        machine.integer(after(trim(lines[next_line + 3]), "cmp #") orelse return null) != bound or
        !affixed(trim(lines[next_line + 4]), "bcc ", body_name, "") or
        !affixed(trim(lines[done_line + 1]), "; zeropage_loop_end id=", id, "")) return null;
    const slot = model.resolveObject(.{ .name = counter }, 2) orelse return null;
    const managed = storage.claimedAddress(lines, counter_scratch, "pointer") != null;
    _ = initialZero(graph, model, marker, top_line, counter, slot, managed) orelse return null;
    if (!closedPacket(graph, top, body, next, done, done - 1)) return null;
    for (lines[body_line + 3 .. next_line]) |line| {
        if (after(trim(line), begin) != null or after(trim(line), "; zeropage_inline_") != null) return null;
    }
    for (nodes[body + 1 .. next]) |node| {
        if (layout.label(node.text) != null) continue;
        const inst = machine.Instruction.parse(node.text) orelse return null;
        if (inst.op == .jmp) {
            if (inst.operand != .direct) return null;
            const target = graph.target(inst.operand.direct.name) orelse return null;
            if (target <= body or target > next) return null;
        } else if (!layout.conditional(inst.op) and inst.op != .rts) {
            const effects = inst.effects();
            if (effects.barrier or (effects.reads | effects.writes) & machine.x != 0) return null;
        }
        if (layout.conditional(inst.op) and (inst.operand != .direct or same(inst.operand.direct.name, body_name))) return null;
    }
    if (!privateSlot(graph, model, owner, counter, &.{ marker - 2, marker - 1, next_line + 1, next_line + 2 })) return null;
    const capture_line = body_line + 2;
    var allowed: [2]usize = .{ capture_line, capture_line };
    for (marker + 1..top_line) |index| {
        if (affixed(trim(lines[index]), "sta ", capture, "+1")) allowed[1] = index;
    }
    if (!privateSlot(graph, model, owner, capture, &allowed)) return null;
    return .{ .top = top_line, .body = body_line, .capture = capture_line, .next = next_line, .done = done_line, .bound = bound };
}

pub fn rewriteRegister(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.abi.default_frame != .static or options.abi.functions.len != 0 or options.memory.placements.len != 0 or
        std.mem.indexOf(u8, assembly, capture_prefix) == null) return null;
    inline for ([_][]const u8{ "prime_regs", "expect_a_", "expect_x_", "expect_p_", "expect_stack_", "snapshot" }) |hook| {
        if (std.mem.indexOf(u8, assembly, "zeropage_test6502_" ++ hook) != null) return null;
    }
    for (program.functions) |function| if (function.exported and !same(function.name, "main")) return null;
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    const lines = graph.raw.items;
    var model = storage.Model.init(a);
    defer model.deinit();
    try model.collectWithPromotedParameters(assembly, lines);
    const Candidate = struct { loop: RegisterLoop, free_x: bool };
    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(a);
    var edits: std.ArrayList(RegisterLoop) = .empty;
    defer edits.deinit(a);
    var query = try cfg.OutputQuery.initWithLiteralIndex(a, assembly);
    defer query.deinit();
    var owner: ?[]const u8 = null;
    for (lines, 0..) |raw, index| {
        const line = trim(raw);
        if (after(line, "; zeropage_section_") != null) owner = storage.sectionOwner(line, "code");
        const name = owner orelse continue;
        if (after(line, begin) == null) continue;
        const loop = registerMatch(graph, model, name, index) orelse continue;
        const function = program.findFunction(name) orelse continue;
        const free_x = !function.exported and switch (function.return_type) {
            .void, .bool, .u8, .i8 => true,
            .custom => |custom| program.findEnum(custom) != null,
            else => false,
        };
        try candidates.append(a, .{ .loop = loop, .free_x = free_x });
        query.closeEntry(loop.top);
        query.closeEntry(loop.next);
    }
    for (candidates.items) |candidate| {
        const loop = candidate.loop;
        query.setDeadAtReturn(if (candidate.free_x) machine.x else 0);
        if (!try query.deadAfterLineBeforeKill(loop.capture, machine.nz, loop.next) or
            !try query.deadAfterLine(loop.done, machine.a | machine.x)) continue;
        for (graph.nodes.items) |node| {
            if (node.index < loop.body or node.index >= loop.next) continue;
            if (same(node.text, "rts") and !candidate.free_x) break;
        } else {
            try edits.append(a, loop);
        }
    }
    if (edits.items.len == 0 or !try image.permitsLocalShrink(a, graph, program)) return null;
    var output: std.Io.Writer.Allocating = .init(a);
    errdefer output.deinit();
    var copied: usize = 0;
    for (edits.items) |loop| {
        for (lines[copied .. loop.top + 1]) |line| try output.writer.print("{s}\n", .{line});
        try output.writer.writeAll("    ldx #0\n");
        for (lines[loop.body..loop.capture]) |line| try output.writer.print("{s}\n", .{line});
        try output.writer.writeAll("    txa\n");
        for (lines[loop.capture + 1 .. loop.next + 1]) |line| try output.writer.print("{s}\n", .{line});
        try output.writer.print("    inx\n    cpx #{d}\n{s}\n", .{ loop.bound, lines[loop.done - 1] });
        copied = loop.done;
    }
    for (lines[copied..], copied..) |line, index| {
        try output.writer.writeAll(line);
        if (index + 1 < lines.len) try output.writer.writeByte('\n');
    }
    return try output.toOwnedSlice();
}

const parser = @import("../../parser.zig");

test "register latch keeps an eligible range counter in X" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const input = test_entry ++ "    lda #0\n    sta main_for_1_index\n    sta main_for_1_index+1\n" ++
        "; zeropage_loop_begin id=1 count=8\nfor_1_top:\n    lda #0\nfor_1_body:\n" ++
        "; zeropage_loop_capture source=main_i\n    sta main_i\n    tay\n    lda $c000\n" ++
        "for_1_next:\n    inc main_for_1_index\n    lda main_for_1_index\n    cmp #8\n    bcc for_1_body\nfor_1_done:\n" ++
        "; zeropage_loop_end id=1\n    lda #1\n    ldx #0\n    rts\n; zeropage_section_end owner=function:main kind=code\n" ++
        "; zeropage_section_begin owner=function:main kind=static_frame\nmain_for_1_index:\n    .word 0\nmain_i:\n    .word 0\n" ++
        "; zeropage_section_end owner=function:main kind=static_frame\n";
    const output = (try rewriteRegister(a, parsed.program, input)) orelse return error.ExpectedRegisterLatch;
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "for_1_top:\n    ldx #0\nfor_1_body:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "    txa\n    tay\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "    inx\n    cpx #8\n    bcc for_1_body\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "sta main_i\n") == null);
    for ([_][2][]const u8{
        .{ "    lda $c000", "    lda $c000,x" },
        .{ "    lda $c000", "    ldx #4" },
        .{ "    lda $c000", "    jsr main" },
        .{ "    lda $c000", "    bcc for_1_body" },
        .{ "    ldx #0\n    rts", "    stx $c000\n    rts" },
    }) |change| {
        const variant = try std.mem.replaceOwned(u8, a, input, change[0], change[1]);
        defer a.free(variant);
        try std.testing.expect((try rewriteRegister(a, parsed.program, variant)) == null);
    }
}

const test_entry = "* = $2000\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
const test_init =
    "    lda #0\n    sta main_for_1_index\n    sta main_for_1_index+1\n; zeropage_loop_begin id=1 count=8\n";
const test_header = test_entry ++ test_init;
const test_top = "for_1_top:\n    lda main_for_1_index\n    cmp #8\n    bcs for_1_done\nfor_1_body:\n";
const test_tail =
    "for_1_next:\n    inc main_for_1_index\n    jmp for_1_top\nfor_1_done:\n; zeropage_loop_end id=1\n";
const test_footer =
    "    rts\n; zeropage_section_end owner=function:main kind=code\n" ++
    "; zeropage_section_begin owner=function:main kind=static_frame\n" ++
    "main_for_1_index:\n    .word 0\nmain_local:\n    .word 0\n" ++
    "; zeropage_section_end owner=function:main kind=static_frame\n";

test "counted latch omits only dead first-entry compare and keeps all labels" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const body = "    lda #1\n    clc\n";
    const expected = test_header ++ "for_1_top:\nfor_1_body:\n" ++ body ++
        "for_1_next:\n    inc main_for_1_index\n    lda main_for_1_index\n    cmp #8\n" ++
        "    bcc for_1_body\nfor_1_done:\n; zeropage_loop_end id=1\n" ++ test_footer;
    const output = (try rewrite(a, parsed.program, test_header ++ test_top ++ body ++ test_tail ++ test_footer)) orelse
        return error.ExpectedLatch;
    defer a.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "counted latch preserves live initial compare after a disjoint preheader store" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const preheader = "    lda main_local\n    sta main_local+1\n";
    const top = "for_1_top:\n    lda main_for_1_index\n    cmp #8\n    bcc for_1_body\n    jmp for_1_done\nfor_1_body:\n";
    const body = "    php\n    pla\n";
    const output = (try rewrite(a, parsed.program, test_header ++ preheader ++ top ++ body ++ test_tail ++ test_footer)) orelse
        return error.ExpectedLatch;
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "for_1_top:\n    lda #0\n    cmp #8\nfor_1_body:\n    php\n") != null);
}

test "counted latch declines aliases, alternate entry and growing relative spans" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const alias_preheader = "    lda main_local\n    sta main_local-1\n";
    const alternate = test_entry ++ "    jmp alternate\n" ++ test_init ++ test_top ++ "alternate:\n";
    for ([_][]const u8{
        test_header ++ alias_preheader ++ test_top ++ test_tail ++ test_footer,
        alternate ++ test_tail ++ test_footer,
        test_header ++ test_top ++ "    beq for_1_done\n" ++ test_tail ++ test_footer,
        test_header ++ test_top ++ "    jmp for_1_top\n" ++ test_tail ++ test_footer,
    }) |input| {
        const output = try rewrite(a, parsed.program, input);
        defer if (output) |bytes| a.free(bytes);
        try std.testing.expect(output == null);
    }
}

test "counted latch accepts the final legal backward byte and declines the next" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const pad = "    nop\n";
    const kill = "    lda #1\n    clc\n";
    const fits = test_header ++ test_top ++ kill ++ pad ** 115 ++ test_tail ++ test_footer;
    const too_far = test_header ++ test_top ++ kill ++ pad ** 116 ++ test_tail ++ test_footer;
    const output = (try rewrite(a, parsed.program, fits)) orelse return error.ExpectedLatch;
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "    bcc for_1_body\nfor_1_done:") != null);
    try std.testing.expect((try rewrite(a, parsed.program, too_far)) == null);
}

test "counted latch treats the repeat compare as a flag kill" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const body = "    ldy #1\n    beq for_1_next\n    clc\n";
    const output = (try rewrite(a, parsed.program, test_header ++ test_top ++ body ++ test_tail ++ test_footer)) orelse
        return error.ExpectedLatch;
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "for_1_top:\nfor_1_body:\n") != null);
}
