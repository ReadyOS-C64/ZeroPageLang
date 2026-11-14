const std = @import("std");
const ast = @import("../../ast.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");
const literal_io = @import("literal_pointer_io.zig");
const word_multiply = @import("word_multiply.zig");

const prefix = "zeropage_affine_reduce_";
const group_prefix = "zeropage_affine_group_";
const capture = "zeropage_mul_lhs";

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn identifier(expr: ast.Expr) ?[]const u8 {
    return if (expr == .value and expr.value == .ident) expr.value.ident else null;
}

fn integer(expr: ast.Expr) ?u16 {
    return if (expr == .value and expr.value == .int) expr.value.int else null;
}

const Shape = struct {
    index: []const u8,
    total: []const u8,
    count: []const u8,
    seed: []const u8,
    factor: u16,
    bias: u16,
    grouped: bool,
};

fn indexOffset(expr: ast.Expr, name: []const u8, offset: u16) bool {
    if (offset == 0) return same(identifier(expr) orelse return false, name);
    return expr == .add and same(identifier(expr.add.lhs.*) orelse return false, name) and integer(expr.add.rhs.*) == offset;
}

const Term = struct { factor: u16, bias: u16 };

fn sourceTerm(expr: ast.Expr, index: []const u8, offset: u16) ?Term {
    if (expr != .add or expr.add.lhs.* != .mul) return null;
    const mul = expr.add.lhs.mul;
    const factor = if (integer(mul.rhs.*)) |right| blk: {
        if (!indexOffset(mul.lhs.*, index, offset)) return null;
        break :blk right;
    } else blk: {
        if (!indexOffset(mul.rhs.*, index, offset)) return null;
        break :blk integer(mul.lhs.*) orelse return null;
    };
    if (factor < 2) return null;
    return .{ .factor = factor, .bias = integer(expr.add.rhs.*) orelse return null };
}

fn sourceShape(function: ast.Function) ?Shape {
    if (function.exported or function.return_type != .u16 or function.params.len != 2 or function.body.len < 4) return null;
    const init_index, const init_total, const stmt = function.body[0..3].*;
    const result = function.body[function.body.len - 1];
    if (init_index != .var_decl or init_total != .var_decl or stmt != .while_stmt or result != .return_expr) return null;
    const index = init_index.var_decl;
    const total = init_total.var_decl;
    if (!index.mutable or !total.mutable or index.ty == null or index.ty.? != .u16 or
        total.ty == null or total.ty.? != .u16 or integer(index.init) != 0) return null;
    if (!same(identifier(result.return_expr) orelse return null, total.name)) return null;
    const seed = identifier(total.init) orelse return null;
    const loop = stmt.while_stmt;
    const condition = switch (loop.condition) {
        .lt => loop.condition.lt,
        .lte => loop.condition.lte,
        else => return null,
    };
    const grouped = loop.condition == .lte;
    const terms: u16 = if (grouped) 3 else 1;
    if (loop.body.len != terms + 1 or !indexOffset(condition.lhs.*, index.name, if (grouped) 3 else 0)) return null;
    const count = identifier(condition.rhs.*) orelse return null;
    for (function.params) |param| {
        if (!(param.ty == .u8 and same(param.name, count)) and !(param.ty == .u16 and same(param.name, seed))) return null;
    }
    const advance = loop.body[terms];
    if (advance != .add_assign or !same(advance.add_assign.name, index.name) or integer(advance.add_assign.value) != terms) return null;
    var first: Term = undefined;
    for (loop.body[0..terms], 0..) |accumulate, offset| {
        if (accumulate != .add_assign or !same(accumulate.add_assign.name, total.name)) return null;
        const term = sourceTerm(accumulate.add_assign.value, index.name, @intCast(offset)) orelse return null;
        if (offset == 0) {
            first = term;
        } else if (term.factor != first.factor or term.bias != first.bias) return null;
    }
    return .{ .index = index.name, .total = total.name, .count = count, .seed = seed, .factor = first.factor, .bias = first.bias, .grouped = grouped };
}

const Slots = struct {
    index: []const u8,
    total: []const u8,
    count: []const u8,
    seed: []const u8,

    fn resolve(a: std.mem.Allocator, model: storage.Model, function: []const u8, shape: Shape) !?Slots {
        const names = [_][]const u8{ shape.index, shape.total, shape.count, shape.seed };
        const widths = [_]u32{ 2, 2, 1, 2 };
        var slots: [4][]const u8 = undefined;
        var locations: [4]storage.Location = undefined;
        for (names, widths, &slots, &locations, 0..) |name, width, *slot, *location, i| {
            slot.* = try std.fmt.allocPrint(a, "{s}_{s}", .{ function, name });
            location.* = model.resolveObject(.{ .name = slot.* }, width) orelse return null;
            if (!same(model.frames.items[location.frame].owner, function)) return null;
            for (locations[0..i], widths[0..i]) |other, other_width| {
                if (!model.disjoint(location.*, width, other, other_width)) return null;
            }
        }
        return .{ .index = slots[0], .total = slots[1], .count = slots[2], .seed = slots[3] };
    }
};

const Cursor = struct {
    lines: []const layout.Line,
    index: usize,
    scope: usize,

    fn next(self: *Cursor) ?[]const u8 {
        if (self.index >= self.lines.len or self.lines[self.index].scope != self.scope) return null;
        defer self.index += 1;
        return self.lines[self.index].text;
    }

    fn exact(self: *Cursor, expected: []const u8) bool {
        return same(self.next() orelse return false, expected);
    }

    fn sequence(self: *Cursor, expected: []const []const u8) bool {
        for (expected) |line| if (!self.exact(line)) return false;
        return true;
    }

    fn literal(self: *Cursor, op: machine.Op, value: u16) bool {
        const instruction = machine.Instruction.parse(self.next() orelse return false) orelse return false;
        return instruction.op == op and instruction.operand == .immediate and machine.integer(instruction.operand.immediate) == value;
    }

    fn direct(self: *Cursor, op: machine.Op, name: []const u8, offset: i32) bool {
        const instruction = machine.Instruction.parse(self.next() orelse return false) orelse return false;
        return instruction.op == op and instruction.operand == .direct and
            instruction.operand.direct.offset == offset and same(instruction.operand.direct.name, name);
    }

    fn label(self: *Cursor) ?[]const u8 {
        return layout.label(self.next() orelse return null);
    }

    fn target(self: *Cursor, op: machine.Op) ?[]const u8 {
        const instruction = machine.Instruction.parse(self.next() orelse return null) orelse return null;
        return if (instruction.op == op and instruction.operand == .direct and instruction.operand.direct.offset == 0)
            instruction.operand.direct.name
        else
            null;
    }
};

const shift_word = &[_][]const u8{ "asl", "pha", "txa", "rol", "tax", "pla" };
const swap = &[_][]const u8{ "pha", "txa" };
const restore = &[_][]const u8{ "tax", "pla" };

fn matchLiteralAdd(c: *Cursor, literal: u16) bool {
    return c.exact("clc") and c.literal(.adc, literal & 255) and c.sequence(swap) and
        c.literal(.adc, literal >> 8) and c.sequence(restore);
}

fn matchProduct(c: *Cursor, index: []const u8, factor: u16, offset: u16) bool {
    if (!c.direct(.ldx, index, 1) or !c.direct(.lda, index, 0)) return false;
    if (offset != 0 and !matchLiteralAdd(c, offset)) return false;
    if (std.math.isPowerOfTwo(factor)) {
        const shifts = @ctz(factor);
        if (shifts >= 8) {
            for (0..shifts - 8) |_| if (!c.exact("asl")) return false;
            return c.exact("tax") and c.literal(.lda, 0);
        }
        for (0..shifts) |_| if (!c.sequence(shift_word)) return false;
        return true;
    }
    const plan = word_multiply.choose(factor, offset != 0) orelse return false;
    const input = if (offset == 0) index else capture;
    if (offset != 0 and (!c.direct(.sta, input, 0) or !c.direct(.stx, input, 1))) return false;
    var bit = plan.shifts;
    while (bit != 0) {
        bit -= 1;
        if (!c.sequence(shift_word)) return false;
        const mask = @as(u16, 1) << bit;
        if ((plan.adds | plan.subtracts) & mask == 0) continue;
        const subtract = plan.subtracts & mask != 0;
        const op: machine.Op = if (subtract) .sbc else .adc;
        if (!c.exact(if (subtract) "sec" else "clc") or !c.direct(op, input, 0) or
            !c.sequence(swap) or !c.direct(op, input, 1) or !c.sequence(restore)) return false;
    }
    return true;
}

const Loop = struct {
    first: usize,
    last: usize, // unchanged done label
    top: []const u8,
    compare: []const u8,
    body: []const u8,
    done: []const u8,
    inc_label: ?[]const u8,
};

fn hasSuffix(label: []const u8, stem: []const u8, suffix: []const u8) bool {
    return std.mem.startsWith(u8, label, stem) and same(label[stem.len..], suffix);
}

fn matchLoop(graph: layout.Analysis, function: []const u8, shape: Shape, slots: Slots) ?Loop {
    const entry = graph.target(function) orelse return null;
    const node = graph.nodes.items[entry];
    if (node.zone != .code or node.index == 0 or
        !same(storage.sectionOwner(graph.raw.items[node.index - 1], "code") orelse return null, function)) return null;
    var c: Cursor = .{ .lines = graph.nodes.items, .index = entry + 1, .scope = node.scope };
    if (!c.literal(.ldx, 0) or !c.literal(.lda, 0) or !c.direct(.sta, slots.index, 0) or
        !c.direct(.stx, slots.index, 1) or !c.direct(.ldx, slots.seed, 1) or !c.direct(.lda, slots.seed, 0) or
        !c.direct(.sta, slots.total, 0) or !c.direct(.stx, slots.total, 1)) return null;
    const first = c.index;
    const top = c.label() orelse return null;
    if (!std.mem.startsWith(u8, top, "while_") or !std.mem.endsWith(u8, top, "_top")) return null;
    const stem = top[0 .. top.len - 3];
    if (!c.direct(.ldx, slots.index, 1) or !c.direct(.lda, slots.index, 0) or
        (shape.grouped and !matchLiteralAdd(&c, 3)) or !c.literal(.cpx, 0)) return null;
    const compare = c.target(.bne) orelse return null;
    if (!c.direct(.cmp, slots.count, 0) or !same(c.label() orelse return null, compare)) return null;
    var short_done: ?[]const u8 = null;
    var long_body: ?[]const u8 = null;
    if (shape.grouped) {
        long_body = c.target(.beq) orelse return null;
        if (!same(c.target(.bcc) orelse return null, long_body.?)) return null;
    } else {
        const branch = c;
        short_done = c.target(.bcs);
        if (short_done == null) {
            c = branch;
            long_body = c.target(.bcc) orelse return null;
        }
    }
    const done = short_done orelse (c.target(.jmp) orelse return null);
    const body = c.label() orelse return null;
    if (!hasSuffix(body, stem, "body") or !hasSuffix(done, stem, "done") or
        (long_body != null and !same(long_body.?, body))) return null;
    for (0..@as(usize, if (shape.grouped) 3 else 1)) |offset| {
        if (!matchProduct(&c, slots.index, shape.factor, @intCast(offset)) or !matchLiteralAdd(&c, shape.bias) or
            !c.exact("clc") or !c.direct(.adc, slots.total, 0) or !c.direct(.sta, slots.total, 0) or
            !c.exact("txa") or !c.direct(.adc, slots.total, 1) or !c.direct(.sta, slots.total, 1)) return null;
    }

    var inc_label: ?[]const u8 = null;
    const tail = c;
    if (!shape.grouped and c.direct(.inc, slots.index, 0)) {
        const join = c.target(.bne) orelse return null;
        if (!std.mem.startsWith(u8, join, "zeropage_word_increment_") or
            !c.direct(.inc, slots.index, 1) or !same(c.label() orelse return null, join)) return null;
        inc_label = join;
        const before_reload = c;
        if (!c.direct(.lda, slots.index, 0)) c = before_reload;
    } else {
        c = tail;
        if (!c.literal(.ldx, 0) or !c.literal(.lda, if (shape.grouped) 3 else 1) or !c.exact("clc") or !c.direct(.adc, slots.index, 0) or
            !c.direct(.sta, slots.index, 0) or !c.exact("txa") or !c.direct(.adc, slots.index, 1) or
            !c.direct(.sta, slots.index, 1)) return null;
    }
    if (!same(c.target(.jmp) orelse return null, top)) return null;
    const last = c.index;
    if (!same(c.label() orelse return null, done)) return null;
    return .{ .first = first, .last = last, .top = top, .compare = compare, .body = body, .done = done, .inc_label = inc_label };
}

fn isolated(graph: layout.Analysis, loop: Loop) bool {
    for (graph.nodes.items, 0..) |node, i| {
        if (i >= loop.first and i < loop.last) continue;
        for ([_][]const u8{ loop.top, loop.compare, loop.body }) |name| {
            if (layout.tokenPresent(node.text, name)) return false;
        }
        if (loop.inc_label) |name| if (layout.tokenPresent(node.text, name)) return false;
    }
    return true;
}

fn writeTermAdd(w: *std.Io.Writer, loop: Loop, slots: Slots, use_y: bool) !void {
    try w.print("{s}:\n{s}:\n    clc\n", .{ loop.compare, loop.body });
    if (use_y) {
        try w.writeAll("    tya\n");
    } else try w.print("    lda {s}\n", .{slots.index});
    try w.print("    adc {s}\n    sta {s}\n    lda {s}+1\n    adc {s}+1\n    sta {s}+1\n", .{ slots.total, slots.total, slots.index, slots.total, slots.total });
}

fn writeLoop(w: *std.Io.Writer, loop: Loop, shape: Shape, slots: Slots) !void {
    const use_y = shape.factor & 255 != 0;
    try w.print("{s}:\n    ldx {s}\n    txa\n    sec\n    beq {s}\n", .{ loop.top, slots.count, loop.done });
    // Keep the caller's Y in the private low slot until the epilogue
    // publishes the original source index. A zero trip skips the save.
    if (use_y) {
        try w.print("    sty {s}\n    ldy #${x:0>2}\n", .{ slots.index, shape.bias & 255 });
    } else if (shape.bias & 255 != 0) {
        try w.print("    lda #${x:0>2}\n    sta {s}\n", .{ shape.bias & 255, slots.index });
    }
    if (shape.bias >> 8 != 0) try w.print("    lda #${x:0>2}\n    sta {s}+1\n", .{ shape.bias >> 8, slots.index });
    try writeTermAdd(w, loop, slots, use_y);
    try w.print("    dex\n    beq " ++ prefix ++ "{s}\n", .{loop.top});
    if (use_y) {
        try w.print("    tya\n    clc\n    adc #${x:0>2}\n    tay\n", .{shape.factor & 255});
    } else try w.writeAll("    clc\n");
    if (shape.factor >> 8 != 0) {
        try w.print("    lda {s}+1\n    adc #${x:0>2}\n    sta {s}+1\n", .{ slots.index, shape.factor >> 8, slots.index });
    } else try w.print("    bcc {s}\n    inc {s}+1\n", .{ loop.body, slots.index });
    try w.print("    jmp {s}\n", .{loop.body});
    if (loop.inc_label) |name| try w.print("{s}:\n", .{name});
    // The last bias addition used the stack at this depth. Reproduce
    // its pending byte, then restore the counter and the compare flags.
    try w.print(prefix ++ "{s}:\n", .{loop.top});
    if (use_y) {
        try w.print("    tya\n    pha\n    pla\n    ldy {s}\n", .{slots.index});
    } else try w.print("    lda {s}\n    pha\n    pla\n", .{slots.index});
    try w.print("    lda {s}\n    sta {s}\n    stx {s}+1\n    cpx #0\n", .{ slots.count, slots.index, slots.index });
    // INC leaves the last high accumulator ADC's overflow intact.
    if (loop.inc_label == null) try w.writeAll("    clv\n");
}

const CaptureStorage = enum { none, resident, zero_page };

fn captureStorage(graph: layout.Analysis, model: storage.Model, slots: Slots, managed: bool) ?CaptureStorage {
    if (model.resolveObject(.{ .name = capture }, 2)) |word| {
        if (!same(model.frames.items[word.frame].owner, "compiler:scratch")) return null;
        for ([_][]const u8{ slots.index, slots.total, slots.count, slots.seed }, [_]u32{ 2, 2, 1, 2 }) |name, width| {
            const slot = model.resolveObject(.{ .name = name }, width) orelse return null;
            if (!model.disjoint(word, 2, slot, width)) return null;
        }
        return .resident;
    }
    if (!managed or graph.target(capture) != null) return null;
    var address: ?u32 = null;
    var claim: ?u32 = null;
    const equate = capture ++ " = address(";
    const marker = "; zeropage_zp_claim label=" ++ capture ++ " addr=";
    for (graph.raw.items) |line| {
        if (std.mem.startsWith(u8, line, equate)) {
            if (address != null or !std.mem.endsWith(u8, line, ")")) return null;
            address = machine.integer(line[equate.len .. line.len - 1]) orelse return null;
        } else if (std.mem.startsWith(u8, line, marker)) {
            const fields = line[marker.len..];
            const split = std.mem.indexOfScalar(u8, fields, ' ') orelse return null;
            if (claim != null or !std.mem.startsWith(u8, fields[split..], " size=2 kind=scratch ")) return null;
            claim = machine.integer(fields[0..split]) orelse return null;
        }
    }
    const physical = address orelse return null;
    if (physical < 2 or physical > 254 or claim != physical) return null;
    return .zero_page;
}

fn writeGroup(w: *std.Io.Writer, loop: Loop, shape: Shape, slots: Slots, captured: CaptureStorage) !void {
    // Sum the three affine terms modulo a word. Each group advances
    // the source index by three, so the group sum advances by 9*factor.
    const initial = (shape.factor +% shape.bias) *% 3;
    const delta = shape.factor *% 9;
    // The memory form can omit initialization of a zero low byte.
    // Keep it when saving and restoring Y would then grow this kernel.
    const use_y = initial & 255 != 0 and delta & 255 != 0;
    try w.print(
        "{s}:\n    ldx {s}\n    cpx #3\n    bcs " ++ group_prefix ++ "init_{s}\n" ++
            "    ldx #0\n    lda #3\n    pha\n    pla\n    clv\n    cmp {s}\n    jmp {s}\n" ++
            group_prefix ++ "init_{s}:\n",
        .{ loop.top, slots.count, loop.top, slots.count, loop.done, loop.top },
    );
    if (use_y) {
        try w.print("    sty {s}\n    ldy #{d}\n", .{ slots.index, initial & 255 });
    } else if (initial & 255 != 0) {
        try w.print("    lda #{d}\n    sta {s}\n", .{ initial & 255, slots.index });
    }
    if (initial >> 8 != 0) try w.print("    lda #{d}\n    sta {s}+1\n", .{ initial >> 8, slots.index });
    try writeTermAdd(w, loop, slots, use_y);
    try w.print("    dex\n    dex\n    dex\n    cpx #3\n    bcc " ++ group_prefix ++ "exit_{s}\n", .{loop.top});
    if (delta & 255 != 0) {
        if (use_y) {
            try w.print("    tya\n    clc\n    adc #{d}\n    tay\n", .{delta & 255});
        } else try w.print("    lda {s}\n    clc\n    adc #{d}\n    sta {s}\n", .{ slots.index, delta & 255, slots.index });
    } else try w.writeAll("    clc\n");
    if (delta >> 8 != 0) {
        try w.print("    lda {s}+1\n    adc #{d}\n    sta {s}+1\n", .{ slots.index, delta >> 8, slots.index });
    } else try w.print("    bcc {s}\n    inc {s}+1\n", .{ loop.body, slots.index });
    try w.print("    jmp {s}\n", .{loop.body});
    // X holds the remainder. Restore the consumed index and the last
    // original captured operand, which was (index before the group)+2.
    try w.print(group_prefix ++ "exit_{s}:\n", .{loop.top});
    if (use_y) try w.print("    ldy {s}\n", .{slots.index});
    try w.writeAll("    txa\n    eor #$ff\n");
    if (captured != .none) {
        // The exit comparison left C clear. In binary mode count plus
        // the complemented remainder gives index-1 and sets C, since
        // an entered group consumed at least three elements.
        try w.print("    adc {s}\n    sta " ++ capture ++ "\n    adc #0\n", .{slots.count});
    } else try w.print("    sec\n    adc {s}\n", .{slots.count});
    try w.print("    sta {s}\n", .{slots.index});
    try w.writeAll("    ldx #0\n");
    if (captured != .none) try w.writeAll("    stx " ++ capture ++ "+1\n");
    try w.print("    stx {s}+1\n", .{slots.index});
    // Both paths reproduce the failed header, including its stack byte
    // and the ninth bit of index+3 when the count is 255.
    try w.print(
        group_prefix ++ "failed_{s}:\n    ldx {s}+1\n    lda {s}\n    clc\n    adc #3\n" ++
            "    pha\n    txa\n    adc #0\n    tax\n    pla\n    cpx #0\n" ++
            "    bne " ++ group_prefix ++ "compared_{s}\n    cmp {s}\n" ++ group_prefix ++ "compared_{s}:\n",
        .{ loop.top, slots.index, slots.index, loop.top, slots.count, loop.top },
    );
}

fn encodedBytes(graph: layout.Analysis, first: usize, last: usize, captured: CaptureStorage) ?usize {
    var bytes = graph.maxBytes(first, last) orelse return null;
    if (captured == .zero_page) {
        for (graph.nodes.items[first..last]) |node| {
            const inst = machine.Instruction.parse(node.text) orelse continue;
            if (inst.operand == .direct and same(inst.operand.direct.name, capture) and
                std.mem.indexOf(u8, node.text, " @w ") == null)
            {
                // The matched capture operations are ordinary byte
                // opcodes with a two-byte zero-page encoding.
                bytes -= 1;
            }
        }
    }
    return bytes;
}

fn shortBranchesFit(graph: layout.Analysis, external_done: []const u8) bool {
    for (graph.nodes.items, 0..) |node, i| {
        const inst = machine.Instruction.parse(node.text) orelse continue;
        if (!layout.conditional(inst.op)) continue;
        if (inst.operand != .direct or inst.operand.direct.offset != 0) return false;
        const name = inst.operand.direct.name;
        const target = graph.target(name) orelse
            (if (same(name, external_done)) graph.nodes.items.len else return false);
        const bytes = if (target > i) graph.maxBytes(i + 1, target) else graph.maxBytes(target, i);
        if ((bytes orelse return false) > @as(usize, if (target > i) 127 else 126)) return false;
    }
    return true;
}

const Edit = struct {
    start: usize,
    end: usize,
    text: []const u8,

    fn lessThan(_: void, first: Edit, second: Edit) bool {
        return first.start < second.start;
    }
};

/// Use a countdown and a running term for a closed modular word reduction.
pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.functions.len != 0 or
        std.ascii.indexOfIgnoreCase(assembly, prefix) != null or
        std.ascii.indexOfIgnoreCase(assembly, group_prefix) != null) return null;
    var have_shape = false;
    for (program.functions) |function| {
        if (function.exported and !same(function.name, "main")) return null;
        if (sourceShape(function) != null) have_shape = true;
    }
    if (!have_shape) return null;
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    for (graph.nodes.items) |node| {
        if (same(node.text, "sed")) return null;
    }
    var model = storage.Model.init(a);
    defer model.deinit();
    try model.collect(assembly);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var edits: std.ArrayList(Edit) = .empty;
    for (program.functions) |function| {
        const shape = sourceShape(function) orelse continue;
        const slots = (try Slots.resolve(temp, model, function.name, shape)) orelse continue;
        const loop = matchLoop(graph, function.name, shape, slots) orelse continue;
        if (!isolated(graph, loop)) continue;
        const captured = if (shape.grouped and !std.math.isPowerOfTwo(shape.factor))
            captureStorage(graph, model, slots, options.zero_page.declared) orelse continue
        else
            .none;
        var replacement: std.Io.Writer.Allocating = .init(temp);
        if (shape.grouped) {
            try writeGroup(&replacement.writer, loop, shape, slots, captured);
        } else try writeLoop(&replacement.writer, loop, shape, slots);
        const fragment = try layout.parseForSize(temp, replacement.written());
        const old_bytes = encodedBytes(graph, loop.first, loop.last, captured) orelse continue;
        const new_bytes = encodedBytes(fragment, 0, fragment.nodes.items.len, captured) orelse continue;
        if (!fragment.complete or new_bytes > old_bytes or !shortBranchesFit(fragment, loop.done)) continue;
        try edits.append(temp, .{
            .start = graph.nodes.items[loop.first].index,
            .end = graph.nodes.items[loop.last].index,
            .text = replacement.written(),
        });
    }
    if (edits.items.len == 0 or !try literal_io.closedImage(a, program, assembly, graph, model)) return null;
    std.mem.sort(Edit, edits.items, {}, Edit.lessThan);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var copied: usize = 0;
    for (edits.items) |edit| {
        if (edit.start < copied) return null;
        for (graph.raw.items[copied..edit.start]) |line| try out.writer.print("{s}\n", .{line});
        try out.writer.writeAll(edit.text);
        copied = edit.end;
    }
    for (graph.raw.items[copied..], copied..) |line, i| {
        try out.writer.writeAll(line);
        if (i + 1 < graph.raw.items.len) try out.writer.writeByte('\n');
    }
    return try out.toOwnedSlice();
}
