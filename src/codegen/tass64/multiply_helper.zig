const std = @import("std");
const ast = @import("../../ast.zig");
const runtime = @import("runtime.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const image = @import("unreachable_code.zig");
const storage = @import("storage_model.zig");

const entry = "zeropage_mul16";
const loop = entry ++ "_loop";
const bits = entry ++ "_bits";
const done = entry ++ "_done";
const skip_add = entry ++ "_skip_add";
const lhs = "zeropage_mul_lhs";
const rhs = "zeropage_mul_rhs";
const result_word = "zeropage_mul_result";
const word_routine = runtime.multiply_word_routine;
const init_at = std.mem.indexOf(u8, word_routine, "    ldx #16\n    ; The 36-byte") orelse unreachable;
const padding_at = std.mem.indexOf(u8, word_routine, ".if (* & $ff)") orelse unreachable;
const shift_at = std.mem.indexOf(u8, word_routine, "    ; ROR exposes") orelse unreachable;
const add_at = std.mem.indexOf(u8, word_routine, "    bcc " ++ skip_add ++ "\n") orelse unreachable;
const skip_at = std.mem.indexOf(u8, word_routine, skip_add ++ ":\n") orelse unreachable;
const latch_at = std.mem.indexOf(u8, word_routine, "    dex\n    bne " ++ loop) orelse unreachable;
const return_at = std.mem.indexOf(u8, word_routine, "    lda " ++ result_word ++ "\n    ldx ") orelse unreachable;
const counter_routine = word_routine[0..init_at] ++
    "    ldx #8\n    ; Keep the loop and its taken branches in one page.\n" ++
    // The old padding threshold is still valid and the assembler sees the
    // same PC at both conditions.
    word_routine[padding_at..shift_at] ++
    "    lsr " ++ rhs ++ "\n" ++ word_routine[add_at..return_at] ++
    // After eight shifts the high byte holds the original low byte.
    // Recover the old 16th shift's carry, then clear the byte with X=0.
    "    lsr " ++ lhs ++ "+1\n    stx " ++ lhs ++ "+1\n" ++ word_routine[return_at..];

const register_routine = word_routine[0..init_at] ++
    // SEC occupies one byte less than LDX #8. Evaluate the padding at
    // the counter helper's PC so the padding jump and fill stay identical.
    "    sec\n    ; Keep the sentinel loop in one page.\n" ++
    ".if ((* + 1) & $ff) > $db\n" ++
    "    jmp " ++ loop ++ "\n" ++
    ".if ((* + 1) & $ff) > $db\n" ++
    "    .fill (($100 - ((* + 1) & $ff)) & $ff),0\n" ++
    ".endif\n.endif\n" ++
    loop ++ ":\n    lda " ++ rhs ++ "\n    ror\n" ++
    // The seeded high bit survives until the eighth LSR. On the
    // add path X holds the remainder while A forms the two sums.
    bits ++ ":\n    bcc " ++ skip_add ++ "\n    tax\n" ++
    word_routine[add_at + ("    bcc " ++ skip_add ++ "\n").len .. skip_at] ++
    "    txa\n" ++ word_routine[skip_at..latch_at] ++
    // A is zero after the sentinel shifts out. Preserve it while
    // recovering the original carry from the left high byte.
    "    lsr\n    bne " ++ bits ++ "\n    sta " ++ rhs ++ "\n" ++
    "    lsr " ++ lhs ++ "+1\n    sta " ++ lhs ++ "+1\n" ++ word_routine[return_at..];

fn wordRegisterRoutine(comptime extra_setup: u32) []const u8 {
    const pad_pc = std.fmt.comptimePrint("((* - {d}) & $ff)", .{extra_setup});
    return word_routine[0..init_at] ++
        // Keep the original left low byte in the consumed right low slot.
        "    ldx " ++ rhs ++ "\n    lda " ++ lhs ++ "\n    sta " ++ rhs ++ "\n    txa\n" ++
        "    ; Keep the counter helper padding.\n" ++
        ".if " ++ pad_pc ++ " > $db\n    jmp " ++ loop ++ "\n" ++
        ".if " ++ pad_pc ++ " > $db\n    .fill (($100 - " ++ pad_pc ++ ") & $ff),0\n" ++
        ".endif\n.endif\n" ++
        loop ++ ":\n    sec\n    ror\n" ++ bits ++ ":\n    bcc " ++ skip_add ++ "\n    tax\n" ++
        word_routine[add_at + ("    bcc " ++ skip_add ++ "\n").len .. skip_at] ++
        "    txa\n" ++ word_routine[skip_at..latch_at] ++
        "    lsr\n    bne " ++ bits ++ "\n    ldx " ++ rhs ++ "+1\n    beq " ++ done ++ "\n" ++
        // A is zero once the sentinel leaves. The nonzero high byte in X
        // starts the second phase and guarantees that TXA/BNE restarts it.
        "    sta " ++ rhs ++ "+1\n    txa\n    bne " ++ loop ++ "\n" ++
        done ++ ":\n    lsr " ++ rhs ++ "\n    sta " ++ rhs ++ "\n    sta " ++ lhs ++ "+1\n" ++ word_routine[return_at..];
}

const Word = union(enum) {
    resident: storage.Location,
    zero_page: u32,

    fn resolve(model: storage.Model, lines: []const []const u8, name: []const u8, managed: bool) ?Word {
        if (model.resolveObject(.{ .name = name }, 2)) |location| {
            if (!std.mem.eql(u8, model.frames.items[location.frame].owner, "compiler:scratch")) return null;
            return .{ .resident = location };
        }
        if (!managed) return null;
        const claim = storage.claimedAddress(lines, name, "scratch") orelse return null;
        return if (claim.width == 2) .{ .zero_page = claim.address } else null;
    }

    fn disjoint(first: Word, second: Word, model: storage.Model) bool {
        return switch (first) {
            .resident => second != .resident or model.disjoint(first.resident, 2, second.resident, 2),
            .zero_page => second != .zero_page or first.zero_page + 2 <= second.zero_page or second.zero_page + 2 <= first.zero_page,
        };
    }

    fn operandBytes(word: Word) u32 {
        return if (word == .zero_page) 2 else 3;
    }
};

fn byteIncoming(nodes: []const layout.Line, index: usize) bool {
    const transfer = nodes[index];
    if (transfer.zone != .code) return false;
    var write_end = index;
    const pending_lhs = [_][]const u8{ "pla", "sta " ++ lhs ++ "+1", "pla", "sta " ++ lhs };
    if (write_end >= pending_lhs.len) {
        for (nodes[write_end - pending_lhs.len .. write_end], pending_lhs) |node, expected| {
            if (node.scope != transfer.scope or !std.mem.eql(u8, node.text, expected)) break;
        } else write_end -= pending_lhs.len;
    }
    if (write_end < 4) return false;
    const rhs_write = nodes[write_end - 4 .. write_end];
    for (rhs_write) |node| if (node.scope != transfer.scope) return false;
    if (!std.mem.eql(u8, rhs_write[0].text, "ldx #0") or
        !std.mem.eql(u8, rhs_write[2].text, "sta " ++ rhs) or
        !std.mem.eql(u8, rhs_write[3].text, "stx " ++ rhs ++ "+1")) return false;
    const load = machine.Instruction.parse(rhs_write[1].text) orelse return false;
    return load.op == .lda;
}

const Transfers = struct {
    count: usize = 0,
    last: usize = 0,
    all_byte: bool = true,
};

fn closedTransfers(graph: layout.Analysis, head: usize, body_end: usize) ?Transfers {
    const nodes = graph.nodes.items;
    var prior = head;
    while (prior != 0 and nodes[prior - 1].zone == .data) prior -= 1;
    if (prior == 0) return null;
    const terminator = machine.Instruction.parse(nodes[prior - 1].text) orelse return null;
    if (terminator.op != .rts and terminator.op != .jmp) return null;

    var incoming: Transfers = .{};
    for (nodes, 0..) |node, index| {
        if (index >= head and node.index < body_end) continue;
        if (layout.tokenPresent(node.text, loop) or layout.tokenPresent(node.text, skip_add)) return null;
        if (layout.tokenPresent(node.text, entry)) {
            if (node.zone != .code or (!std.mem.eql(u8, node.text, "jsr " ++ entry) and
                !std.mem.eql(u8, node.text, "jmp " ++ entry))) return null;
            incoming.all_byte = incoming.all_byte and byteIncoming(nodes, index);
            incoming.count += 1;
            incoming.last = index;
        }
        const inst = machine.Instruction.parse(node.text) orelse continue;
        switch (inst.operand) {
            .direct => |ref| if (ref.offset < 0) return null,
            .indexed => |ref| if (ref.base.offset < 0) return null,
            else => {},
        }
        if (!layout.conditional(inst.op)) continue;
        if (inst.operand != .direct) return null;
        const target = graph.target(inst.operand.direct.name) orelse return null;
        // The helper can grow. Branches outside its exact body cannot
        // span the edit, even when both targets are ordinary code labels.
        if ((node.index < body_end) != (nodes[target].index < body_end)) return null;
    }
    return if (incoming.count != 0) incoming else null;
}

fn insideBackedge(graph: layout.Analysis, site: usize) bool {
    const nodes = graph.nodes.items;
    for (nodes[site + 1 ..]) |node| {
        if (node.scope != nodes[site].scope) break;
        const inst = machine.Instruction.parse(node.text) orelse continue;
        if ((inst.op != .jmp and !layout.conditional(inst.op)) or inst.operand != .direct) continue;
        const target = graph.target(inst.operand.direct.name) orelse continue;
        if (target <= site and nodes[target].scope == node.scope) return true;
    }
    return false;
}

fn repeatedUse(graph: layout.Analysis, incoming: Transfers) bool {
    if (incoming.count >= 2 or insideBackedge(graph, incoming.last)) return true;
    const nodes = graph.nodes.items;
    var start = incoming.last;
    while (start != 0 and nodes[start - 1].scope == nodes[start].scope) start -= 1;
    const name = layout.label(nodes[start].text) orelse return false;
    const raw = nodes[start].index;
    if (raw == 0 or !std.mem.eql(u8, storage.sectionOwner(graph.raw.items[raw - 1], "code") orelse return false, name)) return false;
    var callers: usize = 0;
    for (nodes, 0..) |node, index| {
        if (node.zone != .code) continue;
        const inst = machine.Instruction.parse(node.text) orelse continue;
        if ((inst.op != .jsr and inst.op != .jmp) or inst.operand != .direct or
            inst.operand.direct.offset != 0 or !std.mem.eql(u8, inst.operand.direct.name, name)) continue;
        callers += 1;
        if (callers >= 2 or insideBackedge(graph, index)) return true;
    }
    return false;
}

pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const opts = program.zeropage_options;
    if (program.zeropage_module != null or opts.modules != null or opts.stack != null or
        opts.memory.placements.len != 0 or opts.abi.default_frame != .static or opts.abi.functions.len != 0) return null;
    const begin = std.mem.indexOf(u8, assembly, word_routine) orelse return null;
    if (begin != 0 and assembly[begin - 1] != '\n') return null;
    for (program.functions) |function| {
        if (function.exported and !std.mem.eql(u8, function.name, "main")) return null;
    }
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    const head = graph.target(entry) orelse return null;
    const first = graph.nodes.items[head];
    if (first.zone != .unsectioned or first.index != std.mem.count(u8, assembly[0..begin], "\n")) return null;
    const incoming = closedTransfers(graph, head, first.index + std.mem.count(u8, word_routine, "\n")) orelse return null;

    var model = storage.Model.init(a);
    defer model.deinit();
    const lines = graph.raw.items;
    try model.collectWithPromotedParameters(assembly, lines);
    const left = Word.resolve(model, lines, lhs, opts.zero_page.declared) orelse return null;
    const right = Word.resolve(model, lines, rhs, opts.zero_page.declared) orelse return null;
    const result = Word.resolve(model, lines, result_word, opts.zero_page.declared) orelse return null;
    if (!left.disjoint(right, model) or !left.disjoint(result, model) or !right.disjoint(result, model)) return null;

    if (!incoming.all_byte) {
        // Spend code bytes where the call graph shows potential repeated use.
        // The preserved padding width caps growth at 20–26 bytes.
        if (!repeatedUse(graph, incoming) or layout.tokenPresent(assembly, bits) or layout.tokenPresent(assembly, done) or
            !try image.permitsMultiplyGrowth(a, graph, program, 4 * right.operandBytes() + 2 * left.operandBytes() + 8)) return null;
        const extra_setup = 2 * right.operandBytes() + left.operandBytes() - 1;
        const word_replacement = switch (extra_setup) {
            inline 5...8 => |delta| wordRegisterRoutine(delta),
            else => unreachable,
        };
        return try std.mem.concat(a, u8, &.{ assembly[0..begin], word_replacement, assembly[begin + word_routine.len ..] });
    }

    // Replace one right-high LSR with a left-high LSR and STX. A mixed
    // allocation can grow by four bytes when only the right word is in ZP.
    const counter_growth = 2 * left.operandBytes() - right.operandBytes();

    // A register remainder adds two implied-operation bytes and
    // one RHS store relative to the counter helper. Its fixed padding
    // cost makes the upper bound independent of the assembler's PC.
    const register_growth = counter_growth + 2 + right.operandBytes();
    const replacement = if (!layout.tokenPresent(assembly, bits) and
        try image.permitsMultiplyGrowth(a, graph, program, register_growth))
        register_routine
    else if (try image.permitsMultiplyGrowth(a, graph, program, counter_growth))
        counter_routine
    else
        return null;
    return try std.mem.concat(a, u8, &.{ assembly[0..begin], replacement, assembly[begin + word_routine.len ..] });
}

const a_test = std.testing.allocator;
const header = "* = $0801\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
const packet = "    ldx #0\n    lda #255\n    sta zeropage_mul_rhs\n    stx zeropage_mul_rhs+1\n" ++
    "    pla\n    sta zeropage_mul_lhs+1\n    pla\n    sta zeropage_mul_lhs\n";
const ending = "; zeropage_section_end owner=function:main kind=code\n";
const scratch = "; zeropage_section_begin owner=compiler kind=scratch\n" ++
    "zeropage_mul_lhs:\n    .word 0\nzeropage_mul_rhs:\n    .word 0\nzeropage_mul_result:\n    .word 0\n" ++
    "; zeropage_section_end owner=compiler kind=scratch\n";

test "byte multiply proves both normal and terminal transfers" {
    const parsed = try @import("../../parser.zig").parseSource(a_test, "export fn main() void {}");
    defer parsed.deinit(a_test);
    const callers = header ++ packet ++ "    jsr zeropage_mul16\n" ++ packet ++ "    jmp zeropage_mul16\n" ++ ending;
    const result = (try rewrite(a_test, parsed.program, callers ++ runtime.multiply_word_routine ++ scratch)) orelse
        return error.ExpectedByteMultiply;
    defer a_test.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, callers));
    try std.testing.expect(std.mem.indexOf(u8, result, "    sec\n    ; Keep the sentinel loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "    ror\nzeropage_mul16_bits:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "    lsr zeropage_mul_lhs+1\n    sta zeropage_mul_lhs+1\n") != null);
}

test "byte multiply keeps the counter helper when the sentinel label is already defined" {
    const parsed = try @import("../../parser.zig").parseSource(a_test, "export fn main() void {}");
    defer parsed.deinit(a_test);
    const callers = header ++ packet ++ "    jmp zeropage_mul16\n" ++ ending;
    const occupied = "; zeropage_section_begin owner=compiler kind=rodata\n" ++
        "zeropage_mul16_bits:\n    .byte 0\n; zeropage_section_end owner=compiler kind=rodata\n";
    const result = (try rewrite(a_test, parsed.program, callers ++ runtime.multiply_word_routine ++ scratch ++ occupied)) orelse
        return error.ExpectedByteMultiply;
    defer a_test.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "    ldx #8\n") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result, "zeropage_mul16_bits:\n"));
}

test "multiply specialization keeps alternate entries on the original helper" {
    const parsed = try @import("../../parser.zig").parseSource(a_test, "export fn main() void {}");
    defer parsed.deinit(a_test);
    for ([_][]const u8{
        header ++ packet ++ "alternate:\n    jmp zeropage_mul16\n" ++ ending,
        header ++ packet ++ "    jsr zeropage_mul16\n    jmp zeropage_mul16_loop\n" ++ ending,
        header ++ packet ++ "    jsr zeropage_mul16\n    nop\n" ++ ending,
    }) |callers| {
        const input = try std.mem.concat(a_test, u8, &.{ callers, runtime.multiply_word_routine, scratch });
        defer a_test.free(input);
        const result = try rewrite(a_test, parsed.program, input);
        defer if (result) |assembly| a_test.free(assembly);
        try std.testing.expect(result == null);
    }
}

test "word multiply specializes mixed calls but keeps one-shot word calls compact" {
    const parsed = try @import("../../parser.zig").parseSource(a_test, "export fn main() void {}");
    defer parsed.deinit(a_test);
    const word_call = "    ldx #1\n    stx zeropage_mul_rhs+1\n    jmp zeropage_mul16\n";
    const repeated = header ++ packet ++ "    jsr zeropage_mul16\n" ++ word_call ++ ending;
    const result = (try rewrite(a_test, parsed.program, repeated ++ word_routine ++ scratch)) orelse
        return error.ExpectedWordMultiply;
    defer a_test.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, repeated));
    try std.testing.expect(std.mem.indexOf(u8, result, "    txa\n    bne zeropage_mul16_loop\nzeropage_mul16_done:\n") != null);
    const single = try rewrite(a_test, parsed.program, header ++ word_call ++ ending ++ word_routine ++ scratch);
    defer if (single) |output| a_test.free(output);
    try std.testing.expect(single == null);
}
