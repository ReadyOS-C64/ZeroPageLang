const std = @import("std");
const ast = @import("../../ast.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");
const source_spans = @import("static_copy_span.zig");
const image_layout = @import("unreachable_code.zig");
const page_range = @import("page_range.zig");

const Window = struct {
    base: []const u8,
    index: []const u8,
    store: bool,

    fn width(self: Window) usize {
        return if (self.store) store_width else load_width;
    }
};
const setup_width = 10;
const load_width = 12;
const store_width = 13;

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn operand(line: []const u8, mnemonic: []const u8) ?[]const u8 {
    const text = trim(line);
    if (!std.mem.startsWith(u8, text, mnemonic)) return null;
    return text[mnemonic.len..];
}

fn direct(line: []const u8, mnemonic: []const u8) ?[]const u8 {
    const text = operand(line, mnemonic) orelse return null;
    const parsed = machine.parseOperand(text);
    if (parsed != .direct or !std.mem.eql(u8, parsed.direct.name, text)) return null;
    return text;
}

fn high(line: []const u8, mnemonic: []const u8, symbol: []const u8) bool {
    const text = operand(line, mnemonic) orelse return false;
    return text.len == symbol.len + 2 and std.mem.startsWith(u8, text, symbol) and std.mem.endsWith(u8, text, "+1");
}

fn match(lines: []const []const u8) ?Window {
    if (lines.len < setup_width + 2) return null;
    const index = direct(lines[1], "lda ") orelse return null;
    const base = direct(lines[5], "adc ") orelse return null;
    if (!high(lines[0], "ldx ", index) or !high(lines[8], "adc ", base)) return null;
    for ([_]usize{ 2, 3, 4, 6, 7, 9, 10 }, [_][]const u8{
        "sta zeropage_ptr_value", "stx zeropage_ptr_value+1", "clc",    "sta zeropage_ptr_tmp",
        "txa",                    "sta zeropage_ptr_tmp+1",   "ldy #0",
    }) |i, expected| {
        if (!std.mem.eql(u8, trim(lines[i]), expected)) return null;
    }
    const store = lines.len >= store_width and std.mem.eql(u8, trim(lines[11]), "pla") and
        std.mem.eql(u8, trim(lines[12]), "sta (zeropage_ptr_tmp),y");
    if (!store and !std.mem.eql(u8, trim(lines[11]), "lda (zeropage_ptr_tmp),y")) return null;
    return .{ .base = base, .index = index, .store = store };
}

fn slotIs(symbol: []const u8, function: []const u8, name: []const u8) bool {
    return symbol.len == function.len + name.len + 1 and std.mem.startsWith(u8, symbol, function) and
        symbol[function.len] == '_' and std.mem.eql(u8, symbol[function.len + 1 ..], name);
}

const Cell = struct {
    address: union(enum) { resident: storage.Location, zero_page: u16 },
    bytes: u16,
};

fn cell(model: storage.Model, lines: []const []const u8, name: []const u8, owner: []const u8, bytes: u16) ?Cell {
    var found: ?Cell = null;
    for (lines) |raw| {
        const line = trim(raw);
        if (std.mem.endsWith(u8, line, ":") and std.ascii.eqlIgnoreCase(line[0 .. line.len - 1], name)) {
            if (found != null or !std.mem.eql(u8, line[0 .. line.len - 1], name)) return null;
            const loc = model.resolve(.{ .name = name }, bytes) orelse return null;
            if (!std.mem.eql(u8, model.frames.items[loc.frame].owner, owner)) return null;
            found = .{ .address = .{ .resident = loc }, .bytes = bytes };
        } else if (std.mem.indexOf(u8, line, " = ")) |split| {
            if (!std.ascii.eqlIgnoreCase(line[0..split], name)) continue;
            if (found != null or !std.mem.eql(u8, line[0..split], name)) return null;
            const rhs = line[split + 3 ..];
            const literal = if (std.mem.startsWith(u8, rhs, "address(") and std.mem.endsWith(u8, rhs, ")"))
                rhs[8 .. rhs.len - 1]
            else
                rhs;
            const addr = machine.integer(literal) orelse return null;
            if (addr < 2 or addr > 256 - @as(u32, bytes)) return null;
            found = .{ .address = .{ .zero_page = @intCast(addr) }, .bytes = bytes };
        }
    }
    return found;
}

fn disjoint(model: storage.Model, first: Cell, second: Cell) bool {
    return switch (first.address) {
        .resident => |loc| second.address == .zero_page or model.disjoint(loc, first.bytes, second.address.resident, second.bytes),
        .zero_page => |addr| second.address == .resident or addr + first.bytes <= second.address.zero_page or
            second.address.zero_page + second.bytes <= addr,
    };
}

fn sourceCell(model: storage.Model, lines: []const []const u8, owner: []const u8, name: []const u8, bytes: u16) ?Cell {
    if (name.len <= owner.len or !std.mem.startsWith(u8, name, owner) or name[owner.len] != '_') return null;
    return cell(model, lines, name, owner, bytes);
}

const ByteOperation = struct {
    instruction: []const u8,
    carry: ?[]const u8,
    operand_slot: ?[]const u8,
};

const Witness = struct { start: usize, window: Window, operation: ?ByteOperation = null };

const PendingByte = struct { width: usize, operation: ?ByteOperation = null };

fn pendingByte(gap: []const []const u8) ?PendingByte {
    // The load gives A/N/Z exactly. PHA only consumes A and SP. Logical
    // operations read A, and arithmetic explicitly initializes carry.
    if (gap.len == 0) return null;
    if (std.mem.eql(u8, trim(gap[0]), "pha")) return .{ .width = 1 };
    const first = trim(gap[0]);
    const clear = std.mem.eql(u8, first, "clc");
    const set = std.mem.eql(u8, first, "sec");
    const word_bitwise = std.mem.eql(u8, first, "ldx #0");
    const op_line: usize = if (clear or set or word_bitwise) 1 else 0;
    if (gap.len <= op_line + 1 or !std.mem.eql(u8, trim(gap[op_line + 1]), "pha")) return null;
    const text = trim(gap[op_line]);
    const instruction = machine.Instruction.parse(text) orelse return null;
    if (clear) {
        if (instruction.op != .adc) return null;
    } else if (set) {
        if (instruction.op != .sbc) return null;
    } else switch (instruction.op) {
        .@"and", .ora, .eor => {},
        else => return null,
    }
    const rhs = switch (instruction.operand) {
        .immediate => |literal| blk: {
            const value = machine.integer(literal) orelse return null;
            if (value > 255) return null;
            break :blk null;
        },
        .direct => |reference| blk: {
            const split = std.mem.indexOfScalar(u8, text, ' ') orelse return null;
            if (!std.mem.eql(u8, text[split + 1 ..], reference.name)) return null;
            break :blk reference.name;
        },
        else => return null,
    };
    var start = op_line + 2;
    // A byte result can come through the existing AX bitwise lowering.
    // Keep its balanced stack transfers and the initialized high byte.
    if (word_bitwise) {
        if (gap.len - start < 4 or !std.mem.eql(u8, trim(gap[start]), "txa")) return null;
        start += 1;
        if (machine.Instruction.parse(gap[start])) |high_op| {
            if (high_op.op == instruction.op and high_op.operand == .immediate and
                machine.integer(high_op.operand.immediate) == 0) start += 1;
        }
        if (gap.len - start < 3 or !std.mem.eql(u8, trim(gap[start]), "tax") or
            !std.mem.eql(u8, trim(gap[start + 1]), "pla") or !std.mem.eql(u8, trim(gap[start + 2]), "pha")) return null;
        start += 3;
    }
    return .{ .width = start, .operation = .{ .instruction = text, .carry = if (clear or set) first else null, .operand_slot = rhs } };
}

fn afterLoad(gap: []const []const u8) ?Witness {
    const pending = pendingByte(gap) orelse return null;
    const store = match(gap[pending.width..]) orelse return null;
    return if (store.store) .{
        .start = load_width + pending.width,
        .window = store,
        .operation = pending.operation,
    } else null;
}

fn followingStore(lines: []const []const u8, first: Window) ?Witness {
    if (!first.store) return afterLoad(lines[load_width..]);
    // Match the next store's pending byte production. Both spellings load A
    // before PHA; the shift spelling also loads X before TXA. Neither reads
    // Y, C or V. Any label, scratch access, call or branch breaks the pair.
    const gap = lines[store_width..];
    if (gap.len < 2) return null;
    const literal = if (operand(gap[0], "lda #")) |value| machine.integer(value) else null;
    const size: usize = if (literal != null and literal.? <= 255 and std.mem.eql(u8, trim(gap[1]), "pha"))
        2
    else if (gap.len >= 5 and std.mem.eql(u8, trim(gap[2]), "asl") and
        std.mem.eql(u8, trim(gap[3]), "txa") and std.mem.eql(u8, trim(gap[4]), "pha"))
        5
    else
        return null;
    const window = match(gap[size..]) orelse return null;
    if (!window.store) return null;
    if (size == 5 and (!high(gap[0], "ldx ", window.index) or
        !std.mem.eql(u8, direct(gap[1], "lda ") orelse return null, window.index))) return null;
    return .{ .start = store_width + size, .window = window };
}

const PairWords = struct { ptr: Cell, value: Cell, slots: [4]Cell };

fn pairWords(model: storage.Model, lines: []const []const u8, owner: []const u8, first: Window, second: Window) ?PairWords {
    const ptr = cell(model, lines, "zeropage_ptr_tmp", "compiler:scratch", 2) orelse return null;
    if (ptr.address != .zero_page) return null;
    const value = cell(model, lines, "zeropage_ptr_value", "compiler:scratch", 2) orelse return null;
    if (!disjoint(model, ptr, value)) return null;
    var slots: [4]Cell = undefined;
    for ([_][]const u8{ first.index, first.base, second.index, second.base }, &slots) |name, *slot| {
        slot.* = sourceCell(model, lines, owner, name, 2) orelse return null;
        if (!disjoint(model, slot.*, ptr) or !disjoint(model, slot.*, value)) return null;
    }
    return .{ .ptr = ptr, .value = value, .slots = slots };
}

fn pairStorageSafe(model: storage.Model, lines: []const []const u8, owner: []const u8, first: Window, witness: Witness) bool {
    const pair = pairWords(model, lines, owner, first, witness.window) orelse return false;
    const operation = witness.operation orelse return true;
    const operand_name = operation.operand_slot orelse return true;
    const rhs = sourceCell(model, lines, owner, operand_name, 1) orelse return false;
    return disjoint(model, rhs, pair.ptr) and disjoint(model, rhs, pair.value);
}

fn writePairedAccess(w: *std.Io.Writer, window: Window, span: source_spans.IndexedSpan, resident_upper: u32) !bool {
    const first_page = span.minimum & 0xff00;
    const same_page = first_page == (span.maximum & 0xff00);
    const first_base = @as(u32, span.base) + first_page;
    // Indexed instructions can read the wrong page before a carry. Both
    // that page and the effective address must stay in the proved RAM domain.
    if (first_base >> 8 <= resident_upper >> 8 or @as(u32, span.base) + span.maximum >= 0x8000) return false;
    if (!same_page) {
        try w.print(
            "    lda {s}+1\n    clc\n    adc #${x:0>2}\n    sta zeropage_ptr_tmp+1\n" ++
                "    lda #${x:0>2}\n    sta zeropage_ptr_tmp\n",
            .{ window.index, span.base >> 8, span.base & 255 },
        );
    }
    try w.print("    ldy {s}\n", .{window.index});
    // LDA or PLA supplies the original A/N/Z. The gap and witness
    // kill X/Y/C/V before use and overwrite both scratch words.
    if (window.store) try w.writeAll("    pla\n");
    const operation = if (window.store) "sta" else "lda";
    if (same_page) {
        try w.print("    {s} ${x:0>4},y\n", .{ operation, first_base });
    } else try w.print("    {s} (zeropage_ptr_tmp),y\n", .{operation});
    return true;
}

fn writeSetup(w: *std.Io.Writer, window: Window, span: source_spans.IndexedSpan, original: []const []const u8) !void {
    const low: u16 = span.base & 255;
    const minimum = low + (span.minimum & 255);
    const maximum = low + (span.maximum & 255);
    const known_high = span.minimum >> 8 == span.maximum >> 8;
    const known_carry = known_high and minimum >> 8 == maximum >> 8;
    if (known_high) {
        try w.print("    ldx #${x:0>2}\n", .{span.minimum >> 8});
    } else {
        try w.print("    ldx {s}+1\n", .{window.index});
    }
    for (original[1..4]) |line| try w.print("{s}\n", .{line});
    if (low != 0) try w.print("    clc\n    adc #${x:0>2}\n", .{low});
    try w.writeAll("    sta zeropage_ptr_tmp\n");
    if (known_carry) {
        // The source proof bounds the full effective address below $8000.
        // Both original high ADC inputs are positive and the result stays
        // positive, so the final C and V are both clear.
        const high_byte = (span.base >> 8) + (span.minimum >> 8) + (minimum >> 8);
        try w.print("    clc\n    clv\n    lda #${x:0>2}\n", .{high_byte});
    } else {
        if (low == 0) try w.writeAll("    clc\n");
        try w.print("    txa\n    adc #${x:0>2}\n", .{span.base >> 8});
    }
    try w.writeAll("    sta zeropage_ptr_tmp+1\n");
}

fn byte(line: []const u8, prefix: []const u8) ?u8 {
    return std.math.cast(u8, machine.integer(operand(line, prefix) orelse return null) orelse return null);
}

const Store = struct {
    window: Window,
    value: ?u8, // null means the low byte of the running index
    width: usize,
};

fn loopStore(lines: []const []const u8, index: []const u8, single_page: bool, index_high: u8) ?Store {
    if (lines.len < 2) return null;
    var value: ?u8 = null;
    var count: usize = 2;
    if (byte(lines[0], "lda #")) |literal| {
        value = literal;
    } else if (direct(lines[0], "lda ")) |slot| {
        if (!std.mem.eql(u8, slot, index)) return null;
    } else {
        if (!single_page or lines.len < 5 or !high(lines[0], "ldx ", index) or
            !std.mem.eql(u8, direct(lines[1], "lda ") orelse return null, index) or
            !std.mem.eql(u8, trim(lines[2]), "asl") or !std.mem.eql(u8, trim(lines[3]), "txa")) return null;
        count = 5;
        value = index_high;
    }
    if (!std.mem.eql(u8, trim(lines[count - 1]), "pha")) return null;
    const window = match(lines[count..]) orelse return null;
    if (!window.store or !std.mem.eql(u8, window.index, index)) return null;
    return .{ .window = window, .value = value, .width = count + store_width };
}

const PageHeader = struct {
    top: []const u8,
    compare: []const u8,
    body: []const u8,
    index: []const u8,
    first_high: u8,
    limit_high: u8,
    done: []const u8,
    end: usize, // first body instruction
};

const PageTail = struct {
    increment_label: ?[]const u8,
    end: usize, // index of the unchanged done label
};

const PageLoop = struct { head: PageHeader, accesses: PageAccesses, tail: PageTail };

const PageAccesses = struct {
    windows: [2]Window,
    width: usize,
    body: union(enum) {
        fill: [2]?u8,
        transform: ?ByteOperation,
    },
};

fn pageAccesses(lines: []const []const u8, index: []const u8, single_page: bool, index_high: u8) ?PageAccesses {
    if (match(lines)) |first| {
        if (first.store or !std.mem.eql(u8, first.index, index)) return null;
        const second = afterLoad(lines[load_width..]) orelse return null;
        if (!std.mem.eql(u8, second.window.index, index)) return null;
        return .{
            .windows = .{ first, second.window },
            .width = second.start + store_width,
            .body = .{ .transform = second.operation },
        };
    }
    const first = loopStore(lines, index, single_page, index_high) orelse return null;
    const second = loopStore(lines[first.width..], index, single_page, index_high) orelse return null;
    return .{
        .windows = .{ first.window, second.window },
        .width = first.width + second.width,
        .body = .{ .fill = .{ first.value, second.value } },
    };
}

fn loopLabel(stem: []const u8, name: []const u8, suffix: []const u8) bool {
    return std.mem.startsWith(u8, name, stem) and std.mem.eql(u8, name[stem.len..], suffix);
}

const Increment = struct { width: usize, label: ?[]const u8 = null };

fn loopIncrement(lines: []const []const u8, index: []const u8) ?Increment {
    if (lines.len >= 8 and byte(lines[0], "ldx #") == 0 and byte(lines[1], "lda #") == 1 and
        std.mem.eql(u8, trim(lines[2]), "clc") and
        std.mem.eql(u8, direct(lines[3], "adc ") orelse "", index) and
        std.mem.eql(u8, direct(lines[4], "sta ") orelse "", index) and
        std.mem.eql(u8, trim(lines[5]), "txa") and high(lines[6], "adc ", index) and
        high(lines[7], "sta ", index)) return .{ .width = 8 };

    if (lines.len < 4 or !std.mem.eql(u8, direct(lines[0], "inc ") orelse "", index) or
        !high(lines[2], "inc ", index)) return null;
    const label = layout.label(trim(lines[3])) orelse return null;
    if (!std.mem.startsWith(u8, label, "zeropage_word_increment_") or
        !std.mem.eql(u8, direct(lines[1], "bne ") orelse "", label)) return null;
    const reload = lines.len > 4 and std.mem.eql(u8, direct(lines[4], "lda ") orelse "", index);
    return .{ .width = if (reload) 5 else 4, .label = label };
}

fn pageHeader(lines: []const []const u8, start: usize) ?PageHeader {
    if (start < 4 or lines.len - start < 8) return null;
    const top = layout.label(trim(lines[start])) orelse return null;
    if (!std.mem.startsWith(u8, top, "while_") or !std.mem.endsWith(u8, top, "_top")) return null;
    const stem = top[0 .. top.len - 3];
    const index = direct(lines[start + 2], "lda ") orelse return null;
    if (!high(lines[start + 1], "ldx ", index)) return null;
    const limit = byte(lines[start + 3], "cpx #") orelse return null;
    const first = byte(lines[start - 4], "ldx #") orelse return null;
    if (first >= limit or limit >= 0x80 or byte(lines[start - 3], "lda #") != 0 or
        !std.mem.eql(u8, direct(lines[start - 2], "sta ") orelse return null, index) or
        !high(lines[start - 1], "stx ", index)) return null;

    var i = start + 4;
    const branch_compare = direct(lines[i], "bne ");
    if (branch_compare != null) {
        if (byte(lines[i + 1], "cmp #") != 0) return null;
        i += 2;
    }
    const compare = layout.label(trim(lines[i])) orelse return null;
    if (branch_compare) |name| if (!std.mem.eql(u8, name, compare)) return null;
    i += 1;
    if (i + 2 >= lines.len) return null;
    const short_done = direct(lines[i], "bcs ");
    const long_body = direct(lines[i], "bcc ");
    const done = short_done orelse (direct(lines[i + 1], "jmp ") orelse return null);
    if (short_done == null and long_body == null) return null;
    i += if (short_done != null) @as(usize, 1) else 2;
    const body = layout.label(trim(lines[i])) orelse return null;
    if (!loopLabel(stem, body, "body") or !loopLabel(stem, done, "done")) return null;
    if (long_body) |name| if (!std.mem.eql(u8, name, body)) return null;
    return .{
        .top = top,
        .compare = compare,
        .body = body,
        .index = index,
        .first_high = first,
        .limit_high = limit,
        .done = done,
        .end = i + 1,
    };
}

fn pageTail(lines: []const []const u8, start: usize, head: PageHeader) ?PageTail {
    const increment = loopIncrement(lines[start..], head.index) orelse return null;
    const i = start + increment.width;
    if (lines.len - i < 2 or !std.mem.eql(u8, direct(lines[i], "jmp ") orelse return null, head.top) or
        !std.mem.eql(u8, layout.label(trim(lines[i + 1])) orelse return null, head.done)) return null;
    return .{ .increment_label = increment.label, .end = i + 1 };
}

fn pageLoop(lines: []const []const u8, start: usize) ?PageLoop {
    const head = pageHeader(lines, start) orelse return null;
    const accesses = pageAccesses(lines[head.end..], head.index, head.limit_high - head.first_high == 1, head.first_high) orelse return null;
    return .{ .head = head, .accesses = accesses, .tail = pageTail(lines, head.end + accesses.width, head) orelse return null };
}

fn isolatedLoop(lines: []const []const u8, start: usize, end: usize, labels: []const []const u8) bool {
    // No alternate entry may bypass the immediate initializer. A relative
    // branch crossing a changed interval can also become too long.
    for (lines, 0..) |raw, i| {
        const line = trim(raw);
        if (i >= start and i < end or line.len == 0 or line[0] == ';') continue;
        for (labels) |name| {
            if (layout.tokenPresent(line, name)) return false;
        }
        const inst = machine.Instruction.parse(line) orelse continue;
        const relative = layout.conditional(inst.op);
        if (!relative and inst.op != .jmp and inst.op != .jsr) continue;
        if (inst.operand != .direct or inst.operand.direct.offset != 0) return false;
        if (!relative) continue;
        // A branch wholly before or wholly after the splice is unaffected.
        const same_side = if (i < start) lines[0..start] else lines[end..];
        const known_target = for (same_side) |target_line| {
            const label = layout.label(trim(target_line)) orelse continue;
            if (std.ascii.eqlIgnoreCase(label, inst.operand.direct.name)) break true;
        } else false;
        if (!known_target) return false;
    }
    return true;
}

fn findSpan(spans: []const source_spans.IndexedSpan, function: []const u8, window: Window) ?source_spans.IndexedSpan {
    for (spans) |span| {
        if (span.fixed_base and std.mem.eql(u8, span.function, function) and
            slotIs(window.base, function, span.pointer_name) and slotIs(window.index, function, span.index_name)) return span;
    }
    return null;
}

fn pageBase(span: source_spans.IndexedSpan, head: PageHeader, resident_upper: u32) ?u16 {
    const first = @as(u16, head.first_high) << 8;
    const last = (@as(u16, head.limit_high) << 8) - 1;
    if (first < span.minimum or last > span.maximum) return null;
    const address = @as(u32, span.base) + first;
    if (address >> 8 <= resident_upper >> 8 or @as(u32, span.base) + last >= 0x8000) return null;
    return @intCast(address);
}

fn storeImmediate(w: *std.Io.Writer, value: u16, slot: []const u8, suffix: []const u8) !void {
    try w.print("    lda #${x:0>2}\n    sta {s}{s}\n", .{ value, slot, suffix });
}

const ptr_name = "zeropage_ptr_tmp";
const index_scratch = "zeropage_ptr_value";
const string_ptr = "zeropage_string_ptr";

fn writePageAccess(w: *std.Io.Writer, operation: []const u8, multipage: bool, pair: []const u8, base: u16) !void {
    if (multipage) {
        try w.print("    {s} ({s}),y\n", .{ operation, pair });
    } else {
        try w.print("    {s} ${x:0>4},y\n", .{ operation, base });
    }
}

fn writePageLoop(w: *std.Io.Writer, loop: PageLoop, bases: [2]u16, first_pair: []const u8) !void {
    const head = loop.head;
    const multipage = head.limit_high - head.first_high > 1;
    const borrow_string = multipage and std.mem.eql(u8, first_pair, string_ptr);
    try w.print("{s}:\n    tay\n", .{head.top});
    if (borrow_string) try w.writeAll(
        "    lda zeropage_string_ptr\n    sta zeropage_ptr_value\n" ++
            "    lda zeropage_string_ptr+1\n    sta zeropage_ptr_value+1\n",
    );
    const pairs = [_][]const u8{ first_pair, ptr_name };
    if (multipage) {
        const shared_high = bases[0] >> 8 == bases[1] >> 8;
        for (pairs, bases) |pair, base| {
            if (base & 255 == 0) try w.print("    sty {s}\n", .{pair}) else try storeImmediate(w, base & 255, pair, "");
            if (!shared_high) try storeImmediate(w, (base >> 8) - 1, pair, "+1");
        }
        if (shared_high) {
            try storeImmediate(w, (bases[0] >> 8) - 1, first_pair, "+1");
            try w.writeAll("    sta zeropage_ptr_tmp+1\n");
        }
    }
    try w.print("{s}:\n", .{head.compare});
    if (multipage) try w.print("    inc {s}+1\n    inc {s}+1\n", .{ first_pair, ptr_name });
    try w.print("{s}:\n", .{head.body});
    switch (loop.accesses.body) {
        .fill => |values| for (values, pairs, bases) |store, pair, base| {
            if (store) |value| try w.print("    lda #${x:0>2}\n", .{value}) else try w.writeAll("    tya\n");
            try writePageAccess(w, "sta", multipage, pair, base);
        },
        .transform => |maybe_operation| {
            try writePageAccess(w, "lda", multipage, pairs[0], bases[0]);
            if (maybe_operation) |operation| {
                if (operation.carry) |carry| try w.print("    {s}\n", .{carry});
                // The byte result is consumed before the old store setup
                // kills the high byte and flags from any AX bitwise gap.
                try w.print("    {s}\n", .{operation.instruction});
            }
            try writePageAccess(w, "sta", multipage, pairs[1], bases[1]);
        },
    }
    try w.print("    iny\n    bne {s}\n", .{head.body});
    if (loop.tail.increment_label) |name| try w.print("{s}:\n", .{name});
    if (multipage) try w.print("    inx\n    cpx #${x:0>2}\n    bcc {s}\n", .{ head.limit_high, head.compare });
    // Preserve the same final pending byte below SP, without increasing depth.
    try w.writeAll("    pha\n    pla\n");
    if (borrow_string) try w.writeAll(
        "    lda zeropage_ptr_value\n    sta zeropage_string_ptr\n" ++
            "    lda zeropage_ptr_value+1\n    sta zeropage_string_ptr+1\n",
    );
    if (multipage) {
        try w.writeAll("    dec zeropage_ptr_tmp\n");
        if (bases[1] & 255 != 0) try w.writeAll("    inc zeropage_ptr_tmp+1\n");
        try storeImmediate(w, 255, index_scratch, "");
    } else {
        const last = bases[1] + 255;
        try storeImmediate(w, last & 255, ptr_name, "");
        if (last & 255 == 255) try w.writeAll("    sta zeropage_ptr_value\n") else try storeImmediate(w, 255, index_scratch, "");
        try storeImmediate(w, last >> 8, ptr_name, "+1");
        try w.writeAll("    inx\n");
    }
    try storeImmediate(w, head.limit_high - 1, index_scratch, "+1");
    // The original unit ADC (or the last destination-high ADC for an
    // INC backedge) cannot overflow in the proved positive address range.
    try w.print("    tya\n    sta {s}\n    stx {s}+1\n    clv\n", .{ head.index, head.index });
    if (!multipage) try w.writeAll("    sec\n");
}

fn tryPageLoop(w: *std.Io.Writer, model: storage.Model, lines: []const []const u8, start: usize, loop: PageLoop, spans: []const source_spans.IndexedSpan, owner: []const u8, upper: u32) !bool {
    const head = loop.head;
    const first, const second = loop.accesses.windows;
    const first_span = findSpan(spans, owner, first) orelse return false;
    const second_span = findSpan(spans, owner, second) orelse return false;
    const bases = [2]u16{ pageBase(first_span, head, upper) orelse return false, pageBase(second_span, head, upper) orelse return false };
    const pair = pairWords(model, lines, owner, first, second) orelse return false;
    const counter, const first_slot, _, const second_slot = pair.slots;
    if (!disjoint(model, counter, first_slot) or !disjoint(model, counter, second_slot)) return false;
    const operand_cell: ?Cell = blk: {
        if (loop.accesses.body != .transform) break :blk null;
        const operation = loop.accesses.body.transform orelse break :blk null;
        const name = operation.operand_slot orelse break :blk null;
        const rhs = sourceCell(model, lines, owner, name, 1) orelse return false;
        // The loop no longer publishes the running index to its frame.
        if (!disjoint(model, rhs, counter) or !disjoint(model, rhs, pair.ptr) or !disjoint(model, rhs, pair.value)) return false;
        break :blk rhs;
    };
    var first_pair: []const u8 = index_scratch;
    if (head.limit_high - head.first_high > 1 and pair.value.address != .zero_page) {
        const borrowed = cell(model, lines, string_ptr, "compiler:scratch", 2) orelse return false;
        if (borrowed.address != .zero_page or !disjoint(model, borrowed, pair.ptr) or !disjoint(model, borrowed, pair.value)) return false;
        for (pair.slots) |slot| if (!disjoint(model, borrowed, slot)) return false;
        if (operand_cell) |rhs| if (!disjoint(model, rhs, borrowed)) return false;
        first_pair = string_ptr;
    }
    const labels = [_][]const u8{ head.top, head.compare, head.body, loop.tail.increment_label orelse "" };
    if (!isolatedLoop(lines, start, loop.tail.end, labels[0..if (loop.tail.increment_label == null) 3 else 4])) return false;
    try writePageLoop(w, loop, bases, first_pair);
    return true;
}

const PageTransform = struct {
    bases: [2]u16,
    op: machine.Op,
    carry: ?[]const u8,
    end: usize,
};

fn directPageTransform(lines: []const []const u8, index: []const u8, selector: page_range.StoredSelector) ?PageTransform {
    const read_width = 8;
    if (lines.len < read_width or !high(lines[0], "lda ", index) or
        !std.mem.eql(u8, direct(lines[6], "ldy ") orelse return null, index)) return null;
    for ([_]usize{ 1, 3, 5, 7 }, [_][]const u8{
        "clc", "sta zeropage_ptr_tmp+1", "sta zeropage_ptr_tmp", "lda (zeropage_ptr_tmp),y",
    }) |i, expected| if (!std.mem.eql(u8, trim(lines[i]), expected)) return null;
    const read_hi = byte(lines[2], "adc #") orelse return null;
    const read_lo = byte(lines[4], "lda #") orelse return null;

    const pending = pendingByte(lines[read_width..]) orelse return null;
    const operation = pending.operation orelse return null;
    if (!std.mem.eql(u8, operation.operand_slot orelse return null, selector.destination)) return null;
    const store_start = read_width + pending.width;
    const store = lines[store_start..];
    if (store.len < 12 or !high(store[0], "ldx ", index) or
        !std.mem.eql(u8, direct(store[1], "lda ") orelse return null, index) or
        !std.mem.eql(u8, trim(store[2]), "sta zeropage_ptr_value") or
        !std.mem.eql(u8, trim(store[3]), "stx zeropage_ptr_value+1")) return null;

    var i: usize = 4;
    var write_lo: u8 = 0;
    if (std.mem.eql(u8, trim(store[i]), "clc")) {
        write_lo = byte(store[i + 1], "adc #") orelse return null;
        if (write_lo == 0) return null;
        i += 2;
    }
    if (!std.mem.eql(u8, trim(store[i]), "sta zeropage_ptr_tmp")) return null;
    i += 1;
    if (write_lo == 0) {
        if (!std.mem.eql(u8, trim(store[i]), "clc")) return null;
        i += 1;
    }
    if (store.len - i < 6 or !std.mem.eql(u8, trim(store[i]), "txa") or
        !std.mem.eql(u8, trim(store[i + 2]), "sta zeropage_ptr_tmp+1") or
        byte(store[i + 3], "ldy #") != 0 or
        !std.mem.eql(u8, trim(store[i + 4]), "pla") or
        !std.mem.eql(u8, trim(store[i + 5]), "sta (zeropage_ptr_tmp),y")) return null;
    const write_hi = byte(store[i + 1], "adc #") orelse return null;
    return .{
        .bases = .{ (@as(u16, read_hi) << 8) | read_lo, (@as(u16, write_hi) << 8) | write_lo },
        .op = machine.Instruction.parse(operation.instruction).?.op,
        .carry = operation.carry,
        .end = store_start + i + 6,
    };
}

fn fixedPageBase(spans: []const source_spans.IndexedSpan, owner: []const u8, head: PageHeader, base: u16, upper: u32) ?u16 {
    for (spans) |span| {
        if (span.fixed_base and span.base == base and std.mem.eql(u8, span.function, owner) and
            slotIs(head.index, owner, span.index_name))
        {
            if (pageBase(span, head, upper)) |address| return address;
        }
    }
    return null;
}

const CloneSlot = struct { name: []const u8, cell: Cell };

fn cloneBytes(lines: []const []const u8, slots: []const CloneSlot) ?usize {
    // The source proof places the resident image above page one. Only
    // these resolved direct cells and the exact indexed forms below occur
    // in the matched loop or its clone.
    var size: usize = 0;
    for (lines) |raw| {
        const line = trim(raw);
        if (line.len == 0 or layout.label(line) != null) continue;
        const inst = machine.Instruction.parse(line) orelse return null;
        if (layout.conditional(inst.op)) {
            size += 2;
        } else if (inst.op == .jmp) {
            size += 3;
        } else size += switch (inst.operand) {
            .none => 1,
            .immediate => 2,
            .indirect => |address| if (std.mem.eql(u8, address, "(zeropage_ptr_tmp),y")) @as(usize, 2) else return null,
            .direct => |ref| for (slots) |slot| {
                if (std.mem.eql(u8, slot.name, ref.name) and ref.offset >= 0 and ref.offset < slot.cell.bytes) {
                    break if (slot.cell.address == .zero_page) @as(usize, 2) else 3;
                }
            } else return null,
            .unknown => blk: {
                const address = operand(line, if (inst.op == .lda) "lda " else "sta ") orelse return null;
                if (!std.mem.endsWith(u8, address, ",y")) return null;
                const base = machine.integer(address[0 .. address.len - 2]) orelse return null;
                if (base < 0x0200 or base >= 0x8000) return null;
                break :blk 3;
            },
            else => return null,
        };
    }
    return size;
}

const clone_prefix = "zeropage_page_clone_";

fn writePageClones(w: *std.Io.Writer, original: []const []const u8, head: PageHeader, selectors: [2]page_range.StoredSelector, transforms: [2]PageTransform, bases: [2][2]u16, increment_label: ?[]const u8) !void {
    try w.print("{s}:\n    tay\n", .{head.top});
    for (original[1..]) |line| {
        if (layout.label(trim(line))) |name| {
            if (increment_label == null or !std.mem.eql(u8, name, increment_label.?)) try w.print("{s}\n", .{line});
        }
    }
    for (head.first_high..head.limit_high) |page| {
        const offset: u16 = @intCast((page - head.first_high) << 8);
        try w.print(clone_prefix ++ "{s}_{x:0>2}:\n", .{ head.top, page });
        for (selectors, transforms, bases) |selector, transform, addresses| {
            try writePageAccess(w, "lda", false, "", addresses[0] + offset);
            if (transform.carry) |carry| try w.print("    {s}\n", .{carry});
            try w.print("    {s} #${x:0>2}\n", .{ @tagName(transform.op), selector.valueAt(@intCast(page)) });
            try writePageAccess(w, "sta", false, "", addresses[1] + offset);
        }
        try w.print("    iny\n    bne " ++ clone_prefix ++ "{s}_{x:0>2}\n", .{ head.top, page });
    }
    if (increment_label) |name| try w.print("{s}:\n", .{name});

    // Publish the last pending byte and recreate the state of the original
    // last store, increment and exit comparison.
    try w.writeAll("    pha\n    pla\n");
    for (selectors) |selector| try storeImmediate(w, selector.valueAt(head.limit_high - 1), selector.destination, "");
    const last = bases[1][1] + (@as(u16, head.limit_high - head.first_high) << 8) - 1;
    try storeImmediate(w, last & 255, ptr_name, "");
    if (last & 255 == 255) try w.writeAll("    sta zeropage_ptr_value\n") else try storeImmediate(w, 255, index_scratch, "");
    try storeImmediate(w, last >> 8, ptr_name, "+1");
    try storeImmediate(w, head.limit_high - 1, index_scratch, "+1");
    try w.print("    ldx #${x:0>2}\n    tya\n    sta {s}\n    stx {s}+1\n    clv\n    sec\n", .{ head.limit_high, head.index, head.index });
}

const CloneLoop = struct {
    head: PageHeader,
    tail: PageTail,
    selectors: [2]page_range.StoredSelector,
    transforms: [2]PageTransform,
};

fn cloneLoop(lines: []const []const u8, start: usize) ?CloneLoop {
    const head = pageHeader(lines, start) orelse return null;
    if (head.limit_high - head.first_high < 2) return null;
    const first = page_range.matchStored(lines[head.end..], head.index) orelse return null;
    const second = page_range.matchStored(lines[head.end + first.end ..], head.index) orelse return null;
    const body = head.end + first.end + second.end;
    const first_transform = directPageTransform(lines[body..], head.index, first) orelse return null;
    const second_transform = directPageTransform(lines[body + first_transform.end ..], head.index, second) orelse return null;
    const tail = pageTail(lines, body + first_transform.end + second_transform.end, head) orelse return null;
    return .{ .head = head, .tail = tail, .selectors = .{ first, second }, .transforms = .{ first_transform, second_transform } };
}

fn pageClones(a: std.mem.Allocator, model: storage.Model, lines: []const []const u8, start: usize, loop: CloneLoop, spans: []const source_spans.IndexedSpan, owner: []const u8, upper: u32) !?[]u8 {
    const head = loop.head;
    const slots = [_]CloneSlot{
        .{ .name = head.index, .cell = sourceCell(model, lines, owner, head.index, 2) orelse return null },
        .{ .name = loop.selectors[0].destination, .cell = sourceCell(model, lines, owner, loop.selectors[0].destination, 1) orelse return null },
        .{ .name = loop.selectors[1].destination, .cell = sourceCell(model, lines, owner, loop.selectors[1].destination, 1) orelse return null },
        .{ .name = ptr_name, .cell = cell(model, lines, ptr_name, "compiler:scratch", 2) orelse return null },
        .{ .name = index_scratch, .cell = cell(model, lines, index_scratch, "compiler:scratch", 2) orelse return null },
    };
    if (slots[3].cell.address != .zero_page) return null;
    for (slots, 0..) |first, i| {
        for (slots[i + 1 ..]) |second| if (!disjoint(model, first.cell, second.cell)) return null;
    }
    const original = lines[start..loop.tail.end];
    const fallback_bytes = cloneBytes(original, &slots) orelse return null;
    // Two absolute reads, two absolute writes, two immediate ALU ops and INY/BNE.
    if (@as(usize, head.limit_high - head.first_high) * 19 > fallback_bytes) return null;
    var bases: [2][2]u16 = undefined;
    for (loop.transforms, &bases) |transform, *addresses| {
        for (transform.bases, addresses) |base, *address| {
            address.* = fixedPageBase(spans, owner, head, base, upper) orelse return null;
        }
    }
    var candidate: std.Io.Writer.Allocating = .init(a);
    defer candidate.deinit();
    try writePageClones(&candidate.writer, original, head, loop.selectors, loop.transforms, bases, loop.tail.increment_label);
    var generated: std.ArrayList([]const u8) = .empty;
    defer generated.deinit(a);
    var input = std.mem.splitScalar(u8, candidate.written(), '\n');
    while (input.next()) |line| try generated.append(a, line);
    const new_bytes = cloneBytes(generated.items, &slots) orelse return null;
    if (new_bytes > fallback_bytes) return null;
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(a);
    for (original) |line| {
        if (layout.label(trim(line))) |name| try labels.append(a, name);
    }
    if (!isolatedLoop(lines, start, loop.tail.end, labels.items)) return null;
    return try candidate.toOwnedSlice();
}

/// Specialize both selected byte operations and addresses once per page.
/// Cost against the actual fallback after local addressing and selector folding.
pub fn cloneSelectedPages(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, assembly, "bool_and_") == null or
        std.ascii.indexOfIgnoreCase(assembly, clone_prefix) != null or
        std.mem.indexOf(u8, assembly, ".fill ((") != null) return null;
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    var input = std.mem.splitScalar(u8, assembly, '\n');
    while (input.next()) |line| try lines.append(a, line);
    var model = storage.Model.init(a);
    defer model.deinit();
    var spans: ?[]source_spans.IndexedSpan = null;
    defer if (spans) |proved| a.free(proved);
    var upper: u32 = 0;
    var result: std.Io.Writer.Allocating = .init(a);
    defer result.deinit();
    var owner: ?[]const u8 = null;
    var copied: usize = 0;
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const line = lines.items[i];
        if (std.mem.startsWith(u8, line, "; zeropage_section_")) owner = storage.sectionOwner(line, "code");
        const function = owner orelse continue;
        const loop = cloneLoop(lines.items, i) orelse continue;
        if (spans == null) {
            upper = (try image_layout.residentLayoutUpperBound(a, assembly)) orelse return null;
            spans = source_spans.proveIndexed(a, program, upper) catch |err| switch (err) {
                error.Unproven => return null,
                error.OutOfMemory => return err,
            };
            if (spans.?.len == 0) return null;
            try model.collect(assembly);
        }
        if (try pageClones(a, model, lines.items, i, loop, spans.?, function, upper)) |replacement| {
            defer a.free(replacement);
            for (lines.items[copied..i]) |unchanged| try result.writer.print("{s}\n", .{unchanged});
            try result.writer.writeAll(replacement);
            copied = loop.tail.end;
            i = copied - 1;
        }
    }
    if (copied == 0) return null;
    for (lines.items[copied..], copied..) |line, index| {
        try result.writer.writeAll(line);
        if (index + 1 < lines.items.len) try result.writer.writeByte('\n');
    }
    return try result.toOwnedSlice();
}

/// Fold known address setup. If a second straight-line store overwrites
/// both scratch words, the first uses Y as the low offset. For proved full
/// pages, advance the two pointer highs only at page boundaries.
pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    // Other rewrites already decline conditional layout. This phase can also
    // move a whole loop, so reject the known location-dependent padding form.
    const fixed_layout = std.mem.indexOf(u8, assembly, ".fill ((") == null;
    return rewriteInternal(a, program, assembly, fixed_layout);
}

fn rewriteInternal(a: std.mem.Allocator, program: ast.Program, assembly: []const u8, page_loops: bool) !?[]u8 {
    if (std.mem.indexOf(u8, assembly, "    stx zeropage_ptr_value+1\n    clc\n    adc ") == null) return null;
    const upper = (try image_layout.residentLayoutUpperBound(a, assembly)) orelse return null;
    const spans = source_spans.proveIndexed(a, program, upper) catch |err| switch (err) {
        error.Unproven => return null,
        error.OutOfMemory => return err,
    };
    defer a.free(spans);
    if (spans.len == 0) return null;
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    var input = std.mem.splitScalar(u8, assembly, '\n');
    while (input.next()) |line| try lines.append(a, line);
    var model = storage.Model.init(a);
    defer model.deinit();
    var storage_collected = false;
    var result: std.Io.Writer.Allocating = .init(a);
    defer result.deinit();
    var owner: ?[]const u8 = null;
    var changed = false;
    var loop_changed = false;
    var witness_end: usize = 0;
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const line = lines.items[i];
        if (std.mem.startsWith(u8, line, "; zeropage_section_")) owner = storage.sectionOwner(line, "code");
        if (page_loops and owner != null) {
            if (pageLoop(lines.items, i)) |loop| {
                if (!storage_collected) {
                    try model.collect(assembly);
                    storage_collected = true;
                }
                if (try tryPageLoop(&result.writer, model, lines.items, i, loop, spans, owner.?, upper)) {
                    i = loop.tail.end - 1;
                    changed = true;
                    loop_changed = true;
                    continue;
                }
            }
        }
        if (owner) |function| if (match(lines.items[i..])) |window| {
            if (findSpan(spans, function, window)) |proved| {
                if (i >= witness_end) {
                    if (followingStore(lines.items[i..], window)) |witness| {
                        if (!storage_collected) {
                            try model.collect(assembly);
                            storage_collected = true;
                        }
                        if (pairStorageSafe(model, lines.items, function, window, witness) and
                            try writePairedAccess(&result.writer, window, proved, upper))
                        {
                            witness_end = i + witness.start + store_width;
                            i += window.width() - 1;
                            changed = true;
                            continue;
                        }
                    }
                }
                try writeSetup(&result.writer, window, proved, lines.items[i .. i + setup_width]);
                i += setup_width - 1;
                changed = true;
                continue;
            }
        };
        try result.writer.writeAll(line);
        if (i + 1 < lines.items.len) try result.writer.writeByte('\n');
    }
    if (!changed) return null;
    const candidate_upper = (try image_layout.residentLayoutUpperBound(a, result.written())) orelse std.math.maxInt(u32);
    if (candidate_upper > upper) return if (loop_changed) rewriteInternal(a, program, assembly, false) else null;
    return try result.toOwnedSlice();
}
