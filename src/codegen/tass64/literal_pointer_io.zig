const std = @import("std");
const cfg = @import("cfg_dead_values.zig");
const ast = @import("../../ast.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");
const image = @import("unreachable_code.zig");

const ptr = "zeropage_ptr_tmp";
const value = "zeropage_ptr_value";
const snapshot = "zeropage_zp_snapshot";

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn is(line: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, trim(line), expected);
}

fn suffix(line: []const u8, prefix: []const u8) ?[]const u8 {
    const text = trim(line);
    return if (std.mem.startsWith(u8, text, prefix)) text[prefix.len..] else null;
}

fn number(line: []const u8, prefix: []const u8) ?u32 {
    return machine.integer(suffix(line, prefix) orelse return null);
}

const Literal = struct {
    address: u16,
    width: u8,

    fn fromDecl(decl: ast.VarDecl) ?Literal {
        const ty = decl.ty orelse return null;
        if (decl.mutable or ty != .pointer or ty.pointer.is_many or ty.pointer.child != .scalar or decl.init != .ptr_from_int) return null;
        const operand = decl.init.ptr_from_int.*;
        if (operand != .value or operand.value != .int) return null;
        return .{
            .address = operand.value.int,
            .width = switch (ty.pointer.child.scalar) {
                .bool, .u8, .i8 => 1,
                .u16, .i16, .usize => 2,
            },
        };
    }
};

pub const Range = struct {
    start: u32,
    end: u32,

    fn visible(first: u32, last: u32) bool {
        return (first >= 0x0200 and last < 0x8000) or (first >= 0xc000 and last < 0xd000);
    }

    pub fn external(self: Range, base: u32, max_index: u32) bool {
        const last = base + max_index;
        const first = if (base >> 8 == last >> 8) base else base & 0xff00;
        return visible(first, last) and (last < self.start or first >= self.end);
    }
};

const Access = enum { read, store };
const Patch = struct {
    start: usize,
    end: usize,
    access: ?Access = null,
    literal: Literal = undefined,

    fn lessThan(_: void, first: Patch, second: Patch) bool {
        return first.start < second.start;
    }
};

fn refIs(line: []const u8, op: machine.Op, name: []const u8, offset: i32) bool {
    const inst = machine.Instruction.parse(line) orelse return false;
    if (inst.op != op or inst.operand != .direct or inst.operand.direct.offset != offset or
        !std.mem.eql(u8, inst.operand.direct.name, name)) return false;
    const text = suffix(line, @tagName(op)) orelse return false;
    const operand = trim(text);
    return operand.len == name.len + @as(usize, if (offset == 0) 0 else 2) and
        std.mem.startsWith(u8, operand, name) and (offset == 0 or std.mem.endsWith(u8, operand, "+1"));
}

fn startsWith(lines: []const []const u8, expected: []const []const u8) bool {
    if (lines.len < expected.len) return false;
    for (lines[0..expected.len], expected) |line, instruction| {
        if (!is(line, instruction)) return false;
    }
    return true;
}

fn initializer(lines: []const []const u8, name: []const u8, literal: Literal) bool {
    return lines.len >= 4 and number(lines[0], "ldx #") == literal.address >> 8 and
        number(lines[1], "lda #") == literal.address & 255 and refIs(lines[2], .sta, name, 0) and refIs(lines[3], .stx, name, 1);
}

fn accessAt(lines: []const []const u8, i: usize, name: []const u8, literal: Literal, init: usize) ?Patch {
    if (!refIs(lines[i], .ldx, name, 1) or i + 1 >= lines.len) return null;
    const reload = refIs(lines[i + 1], .lda, name, 0);
    // Earlier value forwarding can remove the low-byte reload when A
    // still holds the literal from the immediately preceding initializer.
    if (!reload and i != init + 4) return null;
    const setup = i + (if (reload) @as(usize, 2) else 1);
    const address_setup = [_][]const u8{ "sta " ++ ptr, "stx " ++ ptr ++ "+1", "ldy #0" };
    if (!startsWith(lines[setup..], &address_setup)) return null;
    const body = setup + address_setup.len;
    const read = [_][]const u8{ "lda (" ++ ptr ++ "),y", "pha", "iny", "lda (" ++ ptr ++ "),y", "tax", "pla" };
    const read_width: usize = if (literal.width == 2) read.len else 1;
    if (startsWith(lines[body..], read[0..read_width])) {
        return .{ .start = if (reload) i else init, .end = body + read_width, .access = .read, .literal = literal };
    }
    const store = [_][]const u8{ "lda " ++ value, "sta (" ++ ptr ++ "),y", "iny", "lda " ++ value ++ "+1", "sta (" ++ ptr ++ "),y" };
    const store_width: usize = if (literal.width == 2) store.len else 2;
    if (!reload or !startsWith(lines[body..], store[0..store_width])) return null;
    if (literal.width == 2 and (i < 2 or !is(lines[i - 2], "sta " ++ value) or !is(lines[i - 1], "stx " ++ value ++ "+1"))) return null;
    return .{ .start = i, .end = body + store_width, .access = .store, .literal = literal };
}

fn initDominates(graph: layout.Analysis, init: usize, code_end: usize) bool {
    const suffix_start = init + 4;
    // Treat the initialized suffix as a single-entry region. A branch
    // from the prefix (or a call from outside) cannot enter that suffix.
    for (graph.nodes.items) |node| {
        if (node.index >= suffix_start and node.index < code_end) continue;
        const inst = machine.Instruction.parse(node.text) orelse continue;
        if (inst.op != .jsr and inst.op != .jmp and !layout.conditional(inst.op)) continue;
        if (inst.operand != .direct) return false;
        const target = graph.target(inst.operand.direct.name) orelse return false;
        const line = graph.nodes.items[target].index;
        if (line >= suffix_start and line < code_end) return false;
    }
    return true;
}

fn initializerOutputsUsed(lines: []const []const u8) u16 {
    var live = machine.a | machine.x | machine.nz;
    var used: u16 = 0;
    for (lines) |line| {
        const text = trim(line);
        if (text.len == 0) continue;
        const inst = machine.Instruction.parse(text) orelse break;
        const effect = inst.effects();
        if (effect.barrier) break;
        used |= effect.reads & live;
        live &= ~effect.writes;
        if (live == 0) break;
    }
    return used | live;
}

fn planCell(a: std.mem.Allocator, graph: layout.Analysis, model: storage.Model, owner: []const u8, name: []const u8, literal: Literal, edits: *std.ArrayList(Patch)) !bool {
    const location = model.resolveObject(.{ .name = name }, 2) orelse return false;
    if (!std.mem.eql(u8, model.frames.items[location.frame].owner, owner)) return false;
    var labels = model.labels.iterator();
    while (labels.next()) |other| {
        if (!std.mem.eql(u8, name, other.key_ptr.*) and other.value_ptr.frame == location.frame and
            other.value_ptr.offset >= location.offset and other.value_ptr.offset < location.offset + 2) return false;
    }

    const lines = graph.raw.items;
    const old_len = edits.items.len;
    var committed = false;
    defer if (!committed) edits.shrinkRetainingCapacity(old_len);
    var active: ?[]const u8 = null;
    var init: ?usize = null;
    var data: ?usize = null;
    var code_end: ?usize = null;
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const line = trim(lines[i]);
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "; zeropage_section_")) {
            if (init != null and code_end == null) code_end = i;
            active = storage.sectionOwner(line, "code");
        }
        if (line[0] == ';') continue;
        const in_owner = if (active) |function| std.mem.eql(u8, owner, function) else false;
        if (in_owner and initializer(lines[i..], name, literal)) {
            if (init != null) return false;
            init = i;
            i += 3;
        } else if (layout.tokenPresent(line, name)) {
            if (layout.label(line)) |label| {
                if (!std.mem.eql(u8, label, name) or data != null or i + 1 >= lines.len or !is(lines[i + 1], ".word 0")) return false;
                data = i;
            } else if (init != null and code_end == null and in_owner) {
                const packet = accessAt(lines, i, name, literal, init.?) orelse return false;
                try edits.append(a, packet);
                i = packet.end - 1;
            } else return false;
        }
    }
    if (edits.items.len == old_len or init == null or data == null or code_end == null or
        !initDominates(graph, init.?, code_end.?)) return false;
    if (edits.items[old_len].start != init.?) {
        const used = initializerOutputsUsed(lines[init.? + 4 .. code_end.?]);
        const keep_x = used & machine.x != 0;
        const keep_a = used & (machine.a | machine.nz) != 0;
        if (!keep_x and keep_a) try edits.append(a, .{ .start = init.?, .end = init.? + 1 });
        const prefix: usize = if (keep_a) 2 else if (keep_x) 1 else 0;
        try edits.append(a, .{ .start = init.? + prefix, .end = init.? + 4 });
    }
    try edits.append(a, .{ .start = data.?, .end = data.? + 2 });
    committed = true;
    return true;
}

fn indexedNumber(text: []const u8, register: []const u8) ?u32 {
    if (!std.mem.endsWith(u8, text, register)) return null;
    return machine.integer(text[0 .. text.len - register.len]);
}

fn snapshotOffset(text: []const u8, indexed: bool) ?u32 {
    const prefix = snapshot ++ "+";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const offset = text[prefix.len..];
    return if (indexed) indexedNumber(offset, ",x") else machine.integer(offset);
}

fn lifecycleLoop(lines: []const []const u8, start: usize, snapshot_bytes: u32) ?usize {
    const loop = lines[start..];
    if (loop.len < 6 or number(loop[0], "ldx #") != 0) return null;
    const label = layout.label(trim(loop[1])) orelse return null;
    const zeroing = std.mem.startsWith(u8, label, "zeropage_zp_zero_");
    const saving = std.mem.startsWith(u8, label, "zeropage_zp_save_");
    if (!zeroing and !saving and !std.mem.startsWith(u8, label, "zeropage_zp_restore_")) return null;
    const tail: usize = if (zeroing) 3 else 4;
    if (loop.len <= tail + 2 or !is(loop[tail], "inx") or
        !std.mem.eql(u8, suffix(loop[tail + 2], "bne ") orelse return null, label)) return null;
    const count = number(loop[tail + 1], "cpx #") orelse return null;
    if (count == 0 or count > 254) return null;
    const zp = if (saving) suffix(loop[2], "lda ") else suffix(loop[if (zeroing) 2 else 3], "sta ");
    const base = indexedNumber(zp orelse return null, ",x") orelse return null;
    if (base < 2 or base > 255 or base + count > 256) return null;
    if (!zeroing) {
        const operand = if (saving) suffix(loop[3], "sta ") else suffix(loop[2], "lda ");
        const offset = snapshotOffset(operand orelse return null, true) orelse return null;
        if (offset +| count > snapshot_bytes) return null;
    }
    const end = start + tail + 3;
    for (lines, 0..) |raw, i| {
        const line = trim(raw);
        if (i >= start and i < end or line.len == 0 or line[0] == ';') continue;
        if (layout.tokenPresent(line, label)) return null;
    }
    return end;
}

fn knownAliases(graph: layout.Analysis, aliases: *std.StringHashMap(u32)) !bool {
    for (graph.nodes.items) |node| {
        const equal = std.mem.indexOf(u8, node.text, " = ") orelse continue;
        if (node.text[0] == '*') continue;
        const name = node.text[0..equal];
        const raw = node.text[equal + 3 ..];
        const expression = if (std.mem.startsWith(u8, raw, "address(") and std.mem.endsWith(u8, raw, ")")) raw[8 .. raw.len - 1] else raw;
        const address = machine.integer(expression) orelse aliases.get(expression) orelse return false;
        if (address > 65535 or aliases.contains(name) or graph.target(name) != null) return false;
        try aliases.put(name, address);
    }
    return true;
}

fn memoryClosed(graph: layout.Analysis, model: storage.Model, aliases: std.StringHashMap(u32), resident: Range, edits: []const Patch, managed: bool) bool {
    const lines = graph.raw.items;
    var snapshot_bytes: u32 = 0;
    var snapshot_seen = false;
    var lifecycle_start: ?usize = null;
    var lifecycle_end: ?usize = null;
    for (lines, 0..) |line, i| {
        if (is(line, "zeropage_zp_enter:")) {
            if (!managed or lifecycle_start != null or i == 0 or
                !is(lines[i - 1], "; zeropage_section_begin owner=runtime kind=code lifetime=static address=near")) return false;
            lifecycle_start = i;
        }
        if (lifecycle_start != null and lifecycle_end == null and is(line, "; zeropage_section_end owner=runtime kind=code")) {
            lifecycle_end = i;
        }
        if (!is(line, snapshot ++ ":")) continue;
        if (!managed or snapshot_seen or i == 0 or i + 2 >= lines.len or
            !is(lines[i - 1], "; zeropage_section_begin owner=compiler kind=data lifetime=static address=near") or
            !is(lines[i + 2], "; zeropage_section_end owner=compiler kind=data")) return false;
        const extent = suffix(lines[i + 1], ".fill ") orelse return false;
        if (!std.mem.endsWith(u8, extent, ",0")) return false;
        snapshot_bytes = machine.integer(extent[0 .. extent.len - 2]) orelse return false;
        if (snapshot_bytes == 0 or snapshot_bytes > 254) return false;
        snapshot_seen = true;
    }
    var certified_end: usize = 0;
    var patch: usize = 0;
    for (graph.nodes.items) |node| {
        if (node.index < certified_end) continue;
        const lifecycle = lifecycle_start != null and lifecycle_end != null and
            node.index >= lifecycle_start.? and node.index < lifecycle_end.?;
        if (lifecycle) {
            if (lifecycleLoop(lines, node.index, snapshot_bytes)) |end| {
                if (end > lifecycle_end.?) return false;
                certified_end = end;
                continue;
            }
        }
        while (patch < edits.len and edits[patch].end <= node.index) : (patch += 1) {}
        const inst = machine.Instruction.parse(node.text) orelse {
            // A data relocation can expose an address that moves. The
            // fixed BASIC link precedes all code and remains at its origin.
            if (suffix(node.text, ".word ") orelse suffix(node.text, ".byte ")) |data| {
                if (node.zone == .unsectioned and is(node.text, ".word basic_next") and
                    graph.target("basic_next") != null and node.index < graph.nodes.items[graph.target("basic_next").?].index) continue;
                var fields = std.mem.splitScalar(u8, data, ',');
                while (fields.next()) |field| if (machine.integer(trim(field)) == null) return false;
            }
            continue;
        };
        if (inst.op == .txs or inst.op == .rti or inst.op == .brk) return false;
        if (inst.op == .jsr or inst.op == .jmp or layout.conditional(inst.op)) continue;
        switch (inst.operand) {
            .none => {
                // Canonical accumulator shifts use no explicit operand.
                if (std.mem.indexOfAny(u8, node.text, " \t") != null) return false;
            },
            .immediate => |literal| if (machine.integer(literal) == null) return false,
            .direct => |ref| {
                if (model.resolveObject(ref, 1) != null) continue;
                if (lifecycle and std.mem.eql(u8, ref.name, snapshot) and ref.offset >= 0 and ref.offset < snapshot_bytes) continue;
                const base = aliases.get(ref.name) orelse return false;
                const address = @as(i64, base) + ref.offset;
                if (address < 2 or address > 65535 or (address > 255 and !resident.external(@intCast(address), 0))) return false;
            },
            .address => |address| if (address < 2 or (address > 255 and !resident.external(address, 0))) return false,
            .indirect => {
                if (patch == edits.len or node.index < edits[patch].start or edits[patch].access == null) return false;
            },
            .indexed, .unknown => {
                const split = std.mem.indexOfAny(u8, node.text, " \t") orelse return false;
                const operand = trim(node.text[split..]);
                const base = indexedNumber(operand, ",x") orelse indexedNumber(operand, ",y") orelse return false;
                if (base > 65535 or !resident.external(base, 255)) return false;
            },
        }
    }
    return true;
}

/// Prove the same retained memory domain without any pending indirect edits.
pub fn closedImage(a: std.mem.Allocator, program: ast.Program, assembly: []const u8, graph: layout.Analysis, model: storage.Model) !bool {
    const options = program.zeropage_options;
    const upper = (try image.residentLayoutUpperBound(a, assembly)) orelse return false;
    const resident: Range = .{ .start = options.image.load_addr, .end = upper };
    if (!Range.visible(resident.start, resident.end - 1) or !try layout.controlsUnobserved(a, graph)) return false;
    var aliases = std.StringHashMap(u32).init(a);
    defer aliases.deinit();
    return try knownAliases(graph, &aliases) and memoryClosed(graph, model, aliases, resident, &.{}, options.zero_page.declared);
}

fn writeAccess(w: *std.Io.Writer, patch: Patch) !void {
    const address = patch.literal.address;
    const wide = patch.literal.width == 2;
    if (patch.access.? == .store and wide) {
        // The unchanged AX capture immediately precedes this packet.
        // Use Y for the pointer low byte so the RHS low byte stays in A.
        try w.print("    ldy #${x:0>2}\n    sty " ++ ptr ++ "\n    ldx #${x:0>2}\n    stx " ++ ptr ++ "+1\n    ldy #0\n", .{ address & 255, address >> 8 });
    } else {
        try w.print("    ldx #${x:0>2}\n    lda #${x:0>2}\n    sta " ++ ptr ++ "\n    stx " ++ ptr ++ "+1\n    ldy #0\n", .{ address >> 8, address & 255 });
    }
    switch (patch.access.?) {
        .read => {
            try w.print("    lda ${x:0>4},y\n", .{address});
            if (wide) try w.print("    pha\n    iny\n    lda ${x:0>4},y\n    tax\n    pla\n", .{address});
        },
        .store => {
            if (!wide) try w.writeAll("    lda " ++ value ++ "\n");
            try w.print("    sta ${x:0>4},y\n", .{address});
            if (wide) try w.print("    iny\n    lda " ++ value ++ "+1\n    sta ${x:0>4},y\n", .{address});
        },
    }
}

/// Replace indirect scalar accesses to private, initialized literal pointers.
/// Only exact certified indirect packets and closed resident memory may move.
pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.functions.len != 0 or
        std.mem.indexOf(u8, assembly, "(" ++ ptr ++ "),y") == null) return null;
    var have_literal = false;
    for (program.functions) |function| {
        if (function.exported and !std.mem.eql(u8, function.name, "main")) return null;
        for (function.body) |stmt| {
            if (stmt == .var_decl and Literal.fromDecl(stmt.var_decl) != null) have_literal = true;
        }
    }
    if (!have_literal) return null;
    const upper = (try image.residentLayoutUpperBound(a, assembly)) orelse return null;
    const resident: Range = .{ .start = options.image.load_addr, .end = upper };
    if (!Range.visible(resident.start, resident.end - 1)) return null;
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!try layout.controlsUnobserved(a, graph)) return null;
    var model = storage.Model.init(a);
    defer model.deinit();
    try model.collect(assembly);
    var edits: std.ArrayList(Patch) = .empty;
    defer edits.deinit(a);
    for (program.functions) |function| {
        for (function.body) |stmt| {
            if (stmt != .var_decl) continue;
            const literal = Literal.fromDecl(stmt.var_decl) orelse continue;
            if (!resident.external(literal.address, literal.width - 1)) continue;
            const name = try std.fmt.allocPrint(a, "{s}_{s}", .{ function.name, stmt.var_decl.name });
            defer a.free(name);
            _ = try planCell(a, graph, model, function.name, name, literal, &edits);
        }
    }
    if (edits.items.len == 0) return null;
    std.mem.sort(Patch, edits.items, {}, Patch.lessThan);
    for (edits.items[0 .. edits.items.len - 1], edits.items[1..]) |first, second| {
        if (first.end > second.start) return null;
    }
    var aliases = std.StringHashMap(u32).init(a);
    defer aliases.deinit();
    if (!try knownAliases(graph, &aliases)) return null;
    const p = aliases.get(ptr) orelse return null;
    if (p < 2 or p > 254) return null;
    for (edits.items) |edit| {
        if (edit.access != .store) continue;
        if (aliases.get(value)) |v| {
            if (v < 2 or v > 254 or (v < p + 2 and p < v + 2)) return null;
        } else {
            const slot = model.resolveObject(.{ .name = value }, 2) orelse return null;
            if (!std.mem.eql(u8, model.frames.items[slot.frame].owner, "compiler:scratch")) return null;
        }
        break;
    }
    if (!memoryClosed(graph, model, aliases, resident, edits.items, options.zero_page.declared)) return null;

    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var copied: usize = 0;
    for (edits.items) |edit| {
        for (graph.raw.items[copied..edit.start]) |line| try output.writer.print("{s}\n", .{line});
        if (edit.access != null) try writeAccess(&output.writer, edit);
        copied = edit.end;
    }
    for (graph.raw.items[copied..], copied..) |line, i| {
        try output.writer.writeAll(line);
        if (i + 1 < graph.raw.items.len) try output.writer.writeByte('\n');
    }
    return try output.toOwnedSlice();
}

const StoreScratch = struct {
    aliases: std.StringHashMap(u32),
    model: storage.Model,
    pointer: u32,
    value_zp: ?u32,
    value_resident: ?storage.Location,

    fn disjointAddress(self: StoreScratch, address: i64) bool {
        return address != self.pointer and address != self.pointer + 1 and
            (self.value_zp == null or address != self.value_zp.?);
    }

    fn transparent(self: StoreScratch, inst: machine.Instruction) bool {
        const effects = inst.effects();
        if (effects.barrier or effects.writes & machine.sp != 0) return false;
        return switch (inst.operand) {
            .none, .immediate => effects.memory == .none,
            .address => |address| self.disjointAddress(address),
            .direct => |ref| if (self.aliases.get(ref.name)) |base|
                self.disjointAddress(@as(i64, base) + ref.offset)
            else if (self.model.resolveObject(ref, 1)) |location|
                self.value_resident == null or self.model.disjoint(location, 1, self.value_resident.?, 1)
            else
                false,
            else => false,
        };
    }

    fn transparentLeaf(self: StoreScratch, graph: layout.Analysis, target: machine.Symbol) bool {
        if (target.offset != 0) return false;
        const entry = graph.target(target.name) orelse return false;
        const nodes = graph.nodes.items;
        const first = nodes[entry];
        if (first.zone != .code or first.index == 0 or
            !std.mem.eql(u8, storage.sectionOwner(graph.raw.items[first.index - 1], "code") orelse return false, target.name)) return false;
        var depth: usize = 0;
        for (nodes[entry + 1 ..]) |node| {
            if (node.scope != first.scope) break;
            const inst = machine.Instruction.parse(node.text) orelse return false;
            if (is(node.text, "rts")) return depth == 0;
            if (is(node.text, "pha")) {
                depth += 1;
            } else if (is(node.text, "pla")) {
                if (depth == 0) return false;
                depth -= 1;
            } else if (!self.transparent(inst)) return false;
        }
        return false;
    }
};

const store_packet_len = 11;

fn fullWordStore(nodes: []const layout.Line, resident: Range) bool {
    const last = nodes[store_packet_len - 1];
    if (nodes[0].zone != .code or last.scope != nodes[0].scope or last.index - nodes[0].index != store_packet_len - 1) return false;
    if (!is(nodes[0].text, "sta " ++ value) or !is(nodes[1].text, "stx " ++ value ++ "+1") or
        !is(nodes[3].text, "sty " ++ ptr) or !is(nodes[5].text, "stx " ++ ptr ++ "+1") or
        !is(nodes[6].text, "ldy #0") or !is(nodes[8].text, "iny") or
        !is(nodes[9].text, "lda " ++ value ++ "+1") or !is(last.text, nodes[7].text)) return false;
    const operand = suffix(nodes[7].text, "sta ") orelse return false;
    if (!std.mem.startsWith(u8, operand, "$")) return false;
    const base = indexedNumber(operand, ",y") orelse return false;
    return base < 65535 and resident.external(base, 1) and number(nodes[2].text, "ldy #") == base & 255 and
        number(nodes[4].text, "ldx #") == base >> 8;
}

/// Remove a word store's dead pointer and low-value scratch writes while
/// retaining its high-value capture and both physical target write states.
pub fn rewriteDeadStoreScratch(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.functions.len != 0 or
        std.mem.count(u8, assembly, "    sty " ++ ptr ++ "\n") < 2) return null;
    for (program.functions) |function| {
        if (function.exported and !std.mem.eql(u8, function.name, "main")) return null;
    }
    const upper = (try image.residentLayoutUpperBound(a, assembly)) orelse return null;
    const resident: Range = .{ .start = options.image.load_addr, .end = upper };
    if (!Range.visible(resident.start, resident.end - 1)) return null;
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!try layout.controlsUnobserved(a, graph)) return null;
    var model = storage.Model.init(a);
    defer model.deinit();
    try model.collect(assembly);
    var aliases = std.StringHashMap(u32).init(a);
    defer aliases.deinit();
    if (!try knownAliases(graph, &aliases)) return null;
    const pointer = aliases.get(ptr) orelse return null;
    if (pointer < 2 or pointer > 254) return null;
    const value_zp = aliases.get(value);
    const value_resident = if (value_zp == null) model.resolveObject(.{ .name = value }, 2) orelse return null else null;
    if (value_zp) |v| {
        if (!options.zero_page.declared or v < 2 or v > 254 or (v < pointer + 2 and pointer < v + 2)) return null;
    } else if (!std.mem.eql(u8, model.frames.items[value_resident.?.frame].owner, "compiler:scratch")) return null;
    const scratch: StoreScratch = .{ .aliases = aliases, .model = model, .pointer = pointer, .value_zp = value_zp, .value_resident = value_resident };

    // Walk backwards in each block. Keep the last full packet intact.
    // Any earlier packet uses that same terminal kill, never another edit.
    const nodes = graph.nodes.items;
    var edits: std.ArrayList(usize) = .empty;
    defer edits.deinit(a);
    var kill_scope: ?usize = null;
    var end = nodes.len;
    while (end > 0) {
        const node = nodes[end - 1];
        if (kill_scope != node.scope) kill_scope = null;
        if (end >= store_packet_len) {
            const start = end - store_packet_len;
            const packet = nodes[start..end];
            if (fullWordStore(packet, resident)) {
                if (kill_scope != null) {
                    try edits.appendSlice(a, &.{ packet[0].index, packet[2].index, packet[3].index, packet[5].index });
                } else kill_scope = node.scope;
                end = start;
                continue;
            }
        }
        if (kill_scope != null) {
            const transparent = if (machine.Instruction.parse(node.text)) |inst|
                if (inst.op == .jsr and inst.operand == .direct) scratch.transparentLeaf(graph, inst.operand.direct) else scratch.transparent(inst)
            else
                false;
            if (!transparent) kill_scope = null;
        }
        end -= 1;
    }
    if (edits.items.len == 0 or !memoryClosed(graph, model, aliases, resident, &.{}, options.zero_page.declared)) return null;
    std.mem.sort(usize, edits.items, {}, std.sort.asc(usize));
    return try removeLines(a, graph.raw.items, edits.items);
}

fn removeLines(a: std.mem.Allocator, lines: []const []const u8, edits: []const usize) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var edit: usize = 0;
    for (lines, 0..) |line, i| {
        if (edit < edits.len and i == edits[edit]) {
            edit += 1;
            continue;
        }
        try output.writer.writeAll(line);
        if (i + 1 < lines.len) try output.writer.writeByte('\n');
    }
    return try output.toOwnedSlice();
}

const ScratchCell = struct {
    name: []const u8,
    operand: []const u8,
    offset: u32,
};

const overwrite_cells = [_]ScratchCell{
    .{ .name = value, .operand = value ++ "+1", .offset = 1 },
    .{ .name = ptr, .operand = ptr, .offset = 0 },
    .{ .name = ptr, .operand = ptr ++ "+1", .offset = 1 },
    .{ .name = "zeropage_mul_lhs", .operand = "zeropage_mul_lhs+1", .offset = 1 },
};

const ScratchByte = union(enum) {
    resident: storage.Location,
    zero_page: u32,

    fn resolve(cell: ScratchCell, model: storage.Model, aliases: std.StringHashMap(u32), lines: []const []const u8, managed: bool) ?ScratchByte {
        const pointer = std.mem.eql(u8, cell.name, ptr);
        if (aliases.get(cell.name)) |base| {
            if (managed) {
                const claim = storage.claimedAddress(lines, cell.name, if (pointer) "pointer" else "scratch") orelse return null;
                if (claim.address != base or claim.width != 2) return null;
            } else if (!pointer or base != 0xfb) return null;
            return .{ .zero_page = base + cell.offset };
        }
        if (pointer) return null;
        var object = model.resolveObject(.{ .name = cell.name }, 2) orelse return null;
        if (!std.mem.eql(u8, model.frames.items[object.frame].owner, "compiler:scratch")) return null;
        object.offset += cell.offset;
        return .{ .resident = object };
    }

    fn fixedDisjoint(self: ScratchByte, resident: Range, address: i64) bool {
        if (address < 2 or address > 65535) return false;
        if (address <= 255) return self != .zero_page or address != self.zero_page;
        return resident.external(@intCast(address), 0);
    }

    fn disjointAccess(self: ScratchByte, resident: Range, model: storage.Model, aliases: std.StringHashMap(u32), inst: machine.Instruction, text: []const u8) bool {
        if (inst.operand == .unknown) {
            const indexed = layout.literalIndex(text) orelse return false;
            // Only absolute memory instructions. Include the uncorrected
            // page and the full index range in the ordinary-RAM proof.
            if (inst.op != .lda and inst.op != .ldx and inst.op != .ldy and inst.op != .sta) return false;
            return resident.external(indexed.address, 255);
        }
        const effects = inst.effects();
        if (effects.barrier) return false;
        return switch (inst.operand) {
            .none => is(text, @tagName(inst.op)) and
                (effects.memory == .none or effects.memory == .stack),
            .immediate => effects.memory == .none,
            .address => |address| self.fixedDisjoint(resident, address),
            .direct => |ref| if (aliases.get(ref.name)) |base|
                self.fixedDisjoint(resident, @as(i64, base) + ref.offset)
            else if (model.resolveObject(ref, 1)) |location|
                self != .resident or model.disjoint(location, 1, self.resident, 1)
            else
                false,
            else => false,
        };
    }
};

fn writesCell(inst: machine.Instruction, text: []const u8, cell: ScratchCell) bool {
    if (inst.op != .sta and inst.op != .stx and inst.op != .sty) return false;
    const operand = suffix(text, switch (inst.op) {
        .sta => "sta ",
        .stx => "stx ",
        .sty => "sty ",
        else => unreachable,
    }) orelse return false;
    return std.mem.eql(u8, operand, cell.operand);
}

/// Keep each block's last store to each tracked byte. Earlier stores can use
/// that overwrite only when every intervening instruction leaves the byte
/// alone. Both the original external store and its dummy read remain.
pub fn rewriteDeadScratch(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.default_frame != .static or options.abi.functions.len != 0) return null;
    var eligible = [_]bool{false} ** overwrite_cells.len;
    inline for (overwrite_cells, 0..) |cell, i| {
        eligible[i] = std.mem.count(u8, assembly, "    sta " ++ cell.operand ++ "\n") +
            std.mem.count(u8, assembly, "    stx " ++ cell.operand ++ "\n") +
            std.mem.count(u8, assembly, "    sty " ++ cell.operand ++ "\n") >= 2;
    }
    if (std.mem.indexOfScalar(bool, &eligible, true) == null) return null;
    for (program.functions) |function| {
        if (function.exported and !std.mem.eql(u8, function.name, "main")) return null;
    }
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    const upper = (try image.residentLayoutUpperBound(a, assembly)) orelse return null;
    const resident: Range = .{ .start = options.image.load_addr, .end = upper };
    if (upper <= resident.start or !Range.visible(resident.start, upper - 1)) return null;

    var model = storage.Model.init(a);
    defer model.deinit();
    const lines = graph.raw.items;
    try model.collectWithPromotedParameters(assembly, lines);
    var aliases: std.StringHashMap(u32) = .init(a);
    defer aliases.deinit();
    if (!try knownAliases(graph, &aliases)) return null;
    var bytes = [_]?ScratchByte{null} ** overwrite_cells.len;
    for (overwrite_cells, eligible, 0..) |cell, candidate, i| {
        if (candidate) bytes[i] = ScratchByte.resolve(cell, model, aliases, lines, options.zero_page.declared);
    }

    var edits: std.ArrayList(usize) = .empty;
    defer edits.deinit(a);
    var later_store = [_]bool{false} ** overwrite_cells.len;
    var scope: usize = 0;
    var end = graph.nodes.items.len;
    while (end != 0) {
        end -= 1;
        const node = graph.nodes.items[end];
        if (node.scope != scope) {
            @memset(&later_store, false);
            scope = node.scope;
        }
        if (node.zone != .code) continue;
        const inst = machine.Instruction.parse(node.text) orelse {
            @memset(&later_store, false);
            continue;
        };
        for (overwrite_cells, bytes, &later_store) |cell, maybe_scratch, *kill| {
            const scratch = maybe_scratch orelse continue;
            if (writesCell(inst, node.text, cell)) {
                if (kill.*) try edits.append(a, node.index) else kill.* = true;
            } else if (kill.* and !scratch.disjointAccess(resident, model, aliases, inst, node.text)) {
                kill.* = false;
            }
        }
    }
    if (edits.items.len == 0 or !try image.permitsLocalShrink(a, graph, program)) return null;
    std.mem.reverse(usize, edits.items);
    return try removeLines(a, lines, edits.items);
}

const math_tmp = "zeropage_math_tmp";
const sum_low: ScratchCell = .{ .name = math_tmp, .operand = math_tmp, .offset = 0 };
const sum_high: ScratchCell = .{ .name = math_tmp, .operand = math_tmp ++ "+1", .offset = 1 };
const held_add = [_][]const u8{
    "sta " ++ math_tmp, "stx " ++ math_tmp ++ "+1", "pla", "tax",                      "pla", "clc",
    "adc " ++ math_tmp, "sta " ++ math_tmp,         "txa", "adc " ++ math_tmp ++ "+1", "tax", "lda " ++ math_tmp,
};

const HeldHigh = struct { start: usize, value: u8 };
const StackAdd = struct {
    hold: HeldHigh,
    add: usize,
    keep_txa: bool = true,
    keep_high_store: bool = true,
    use_y: bool = false,
};

fn matchStackPacket(nodes: []const layout.Line, start: usize, instructions: []const []const u8) bool {
    if (instructions.len > nodes.len - start) return false;
    const first = nodes[start];
    for (nodes[start .. start + instructions.len], instructions, 0..) |node, inst, i| {
        if (node.scope != first.scope or node.index != first.index + i or !is(node.text, inst)) return false;
    }
    return true;
}

fn scratchOverwritten(
    nodes: []const layout.Line,
    scope: usize,
    cell: ScratchCell,
    scratch: ScratchByte,
    resident: Range,
    model: storage.Model,
    aliases: std.StringHashMap(u32),
    removed: []const bool,
) bool {
    for (nodes) |node| {
        if (node.scope != scope) return false;
        if (removed[node.index]) continue;
        const inst = machine.Instruction.parse(node.text) orelse return false;
        if (writesCell(inst, node.text, cell)) return true;
        if (!scratch.disjointAccess(resident, model, aliases, inst, node.text)) return false;
    }
    return false;
}

/// A known high byte can be added as an immediate to the right word's X.
/// Keep the original low push and preserve any scratch writes still read.
pub fn rewriteKnownHighStack(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.default_frame != .static or options.abi.functions.len != 0 or
        std.mem.indexOf(u8, assembly, "    pha\n    txa\n    pha\n") == null or
        std.mem.indexOf(u8, assembly, "    stx " ++ math_tmp ++ "+1\n    pla\n    tax\n    pla\n") == null or
        std.mem.indexOf(u8, assembly, "zeropage_test6502_expect_stack_") != null) return null;
    for (program.functions) |function| {
        if (function.exported and !is(function.name, "main")) return null;
    }

    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    const nodes = graph.nodes.items;
    const lines = graph.raw.items;
    var edits: std.ArrayList(StackAdd) = .empty;
    defer edits.deinit(a);
    var held: ?HeldHigh = null;
    var x: ?u8 = null;
    var scope: usize = 0;
    var at: usize = 0;
    while (at < nodes.len) : (at += 1) {
        const node = nodes[at];
        if (scope != node.scope) {
            scope = node.scope;
            held = null;
            x = null;
        }
        if (node.zone != .code) continue;
        if (held) |hold| {
            if (matchStackPacket(nodes, at, &held_add)) {
                try edits.append(a, .{ .hold = hold, .add = at });
                held = null;
                x = null;
                at += held_add.len - 1;
                continue;
            }
        }
        if (x) |high| {
            if (matchStackPacket(nodes, at, &.{ "pha", "txa", "pha" })) {
                held = .{ .start = node.index, .value = high };
                at += 2;
                continue;
            }
        }
        const inst = machine.Instruction.parse(node.text) orelse {
            held = null;
            x = null;
            continue;
        };
        const effects = inst.effects();
        if (effects.barrier or (effects.reads | effects.writes) & machine.sp != 0) held = null;
        if (inst.op == .ldx and inst.operand == .immediate) {
            x = if (machine.integer(inst.operand.immediate)) |imm| std.math.cast(u8, imm) else null;
        } else if (effects.barrier or effects.writes & machine.x != 0) x = null;
    }
    if (edits.items.len == 0 or !try image.permitsPrivateStackRewrite(a, graph, program)) return null;

    var model = storage.Model.init(a);
    defer model.deinit();
    try model.collectWithPromotedParameters(assembly, lines);
    if (!try closedImage(a, program, assembly, graph, model)) return null;
    const upper = (try image.residentLayoutUpperBound(a, assembly)) orelse return null;
    const resident: Range = .{ .start = options.image.load_addr, .end = upper };
    var aliases: std.StringHashMap(u32) = .init(a);
    defer aliases.deinit();
    if (!try knownAliases(graph, &aliases)) return null;
    const low = ScratchByte.resolve(sum_low, model, aliases, lines, options.zero_page.declared) orelse return null;
    const high = ScratchByte.resolve(sum_high, model, aliases, lines, options.zero_page.declared) orelse return null;
    var query = try cfg.OutputQuery.initWithLiteralIndex(a, assembly);
    defer query.deinit();
    const removed = try a.alloc(bool, lines.len);
    defer a.free(removed);
    @memset(removed, false);
    var i = edits.items.len;
    while (i > 0) {
        i -= 1;
        const edit = &edits.items[i];
        const start = nodes[edit.add].index;
        const end = start + held_add.len - 1;
        const following = nodes[edit.add + held_add.len ..];
        const add_scope = nodes[edit.add].scope;
        edit.keep_txa = !try query.deadAfterLine(edit.hold.start + 2, machine.a | machine.nz);
        edit.keep_high_store = !scratchOverwritten(following, add_scope, sum_high, high, resident, model, aliases, removed);
        edit.use_y = try query.deadAfterLine(end, machine.y) and
            scratchOverwritten(following, add_scope, sum_low, low, resident, model, aliases, removed);
        if (!edit.keep_high_store) removed[start + 1] = true;
        if (edit.use_y) removed[start + 7] = true;
        if (!edit.keep_txa) query.markRemoved(edit.hold.start + 1);
        query.markRemoved(edit.hold.start + 2);
        query.markRemoved(start + 2);
        query.markRemoved(start + 3);
    }

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var copied: usize = 0;
    for (edits.items) |edit| {
        const start = nodes[edit.add].index;
        for (lines[copied .. edit.hold.start + 1]) |line| try out.writer.print("{s}\n", .{line});
        if (edit.keep_txa) try out.writer.writeAll("    txa\n");
        for (lines[edit.hold.start + 3 .. start + 1]) |line| try out.writer.print("{s}\n", .{line});
        if (edit.keep_high_store) try out.writer.writeAll("    stx " ++ math_tmp ++ "+1\n");
        try out.writer.writeAll("    pla\n    clc\n    adc " ++ math_tmp ++ "\n");
        try out.writer.writeAll(if (edit.use_y) "    tay\n" else "    sta " ++ math_tmp ++ "\n");
        try out.writer.print("    txa\n    adc #{d}\n    tax\n", .{edit.hold.value});
        try out.writer.writeAll(if (edit.use_y) "    tya\n" else "    lda " ++ math_tmp ++ "\n");
        copied = start + held_add.len;
    }
    for (lines[copied..], copied..) |line, line_index| {
        try out.writer.writeAll(line);
        if (line_index + 1 < lines.len) try out.writer.writeByte('\n');
    }
    return try out.toOwnedSlice();
}

const stack_test_header = "* = $0801\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
const stack_test_footer = "    rts\n; zeropage_section_end owner=function:main kind=code\n" ++
    "; zeropage_section_begin owner=compiler kind=scratch\nzeropage_math_tmp:\n    .word 0\n" ++
    "; zeropage_section_end owner=compiler kind=scratch\n";
const stack_test_hold = "    ldx #7\n    lda #19\n    pha\n    txa\n    pha\n";
const stack_test_right = "    lda #29\n    ldx #3\n";
const stack_test_add = "    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n    pla\n    tax\n    pla\n" ++
    "    clc\n    adc zeropage_math_tmp\n    sta zeropage_math_tmp\n    txa\n    adc zeropage_math_tmp+1\n" ++
    "    tax\n    lda zeropage_math_tmp\n";

test "known high stack word adds its constant directly and retains observable scratch" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const input = stack_test_header ++ stack_test_hold ++ stack_test_right ++ stack_test_add ++ stack_test_footer;
    const actual = (try rewriteKnownHighStack(a, parsed.program, input)) orelse return error.ExpectedKnownHighStack;
    defer a.free(actual);
    const want = stack_test_header ++ "    ldx #7\n    lda #19\n    pha\n" ++ stack_test_right ++
        "    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n    pla\n    clc\n    adc zeropage_math_tmp\n" ++
        "    sta zeropage_math_tmp\n    txa\n    adc #7\n    tax\n    lda zeropage_math_tmp\n" ++ stack_test_footer;
    try std.testing.expectEqualStrings(want, actual);
}

test "known high stack word borrows Y across the high add when scratch and Y die" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const kills = "    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n    ldy #1\n";
    const input = stack_test_header ++ stack_test_hold ++ stack_test_right ++ stack_test_add ++ kills ++ stack_test_footer;
    const actual = (try rewriteKnownHighStack(a, parsed.program, input)) orelse return error.ExpectedKnownHighStack;
    defer a.free(actual);
    const want = stack_test_header ++ "    ldx #7\n    lda #19\n    pha\n" ++ stack_test_right ++
        "    sta zeropage_math_tmp\n    pla\n    clc\n    adc zeropage_math_tmp\n" ++
        "    tay\n    txa\n    adc #7\n    tax\n    tya\n" ++ kills ++ stack_test_footer;
    try std.testing.expectEqualStrings(want, actual);
}

test "known high stack word retains the transfer when the right operand reads A" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const right = "    adc #3\n    tax\n";
    const input = stack_test_header ++ stack_test_hold ++ right ++ stack_test_add ++ stack_test_footer;
    const actual = (try rewriteKnownHighStack(a, parsed.program, input)) orelse return error.ExpectedKnownHighStack;
    defer a.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "    pha\n    txa\n" ++ right) != null);
}

test "known high stack word declines visible stack positions and alternate entries" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    for ([_][]const u8{ "    tsx\n", "    lda $0100\n", "    php\n", "alternate:\n" }) |observer| {
        const input = try std.mem.concat(a, u8, &.{ stack_test_header, stack_test_hold, observer, stack_test_right, stack_test_add, stack_test_footer });
        defer a.free(input);
        const actual = try rewriteKnownHighStack(a, parsed.program, input);
        defer if (actual) |text| a.free(text);
        try std.testing.expect(actual == null);
    }
}
