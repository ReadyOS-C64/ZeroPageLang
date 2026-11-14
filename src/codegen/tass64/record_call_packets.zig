const std = @import("std");
const ast = @import("../../ast.zig");
const domains = @import("placement_domains.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");
const image = @import("unreachable_code.zig");

const scratch = "zeropage_ptr_tmp";
pub const Parameter = struct { function: usize, index: usize };
pub const Packet = struct {
    argument: domains.RecordArgument,
    first_line: usize,
    low_store: usize,
    transfer: usize,
};

pub const Origin = struct {
    caller: usize,
    local: []const u8,
};

/// An indirect store whose two pointer bytes come from the same record
/// parameter. Y is deliberately left unconstrained by this query.
pub const IndirectStore = struct { parameter: Parameter, line: usize };

pub fn indirectStoreAt(program: ast.Program, graph: layout.Analysis, model: storage.Model, line: usize) ?IndirectStore {
    const lines = graph.raw.items;
    if (!graph.complete or line >= lines.len) return null;
    const store = machine.Instruction.parse(lines[line]) orelse return null;
    if (store.op != .sta or store.operand != .indirect or !same(store.operand.indirect, "(" ++ scratch ++ "),y")) return null;
    const temporary = pointerScratch(lines) orelse return null;
    const owner = callerAt(program, lines, line) orelse return null;
    const caller = program.functions[owner];
    // The setup and consumers must share one straight-line window. Only
    // flag/register operations, stack pulls and reads may follow the pair,
    // apart from other stores through this same already established pointer.
    var first = line;
    while (first > 0) {
        first -= 1;
        const text = std.mem.trim(u8, lines[first], " \t\r");
        if (text.len == 0 or (text[0] == ';' and !std.mem.startsWith(u8, text, "; zeropage_section_"))) continue;
        const inst = machine.Instruction.parse(text) orelse return null;
        if (instruction(text, .sta, scratch, 1)) break;
        const effects = inst.effects();
        if (effects.barrier or effects.memory == .read_write or
            (effects.memory == .write and !instructionThroughScratch(inst))) return null;
    }
    if (first < 3 or !instruction(lines[first], .sta, scratch, 1) or
        !instruction(lines[first - 2], .sta, scratch, 0)) return null;
    const load = machine.Instruction.parse(lines[first - 3]) orelse return null;
    if (load.op != .lda or load.operand != .direct or load.operand.direct.offset != 0) return null;
    const name = load.operand.direct.name;
    if (!instruction(lines[first - 1], .lda, name, 1)) return null;
    for (caller.params, 0..) |param, index| {
        if (param.ty != .pointer or param.ty.pointer.is_volatile or param.ty.pointer.is_many or
            param.ty.pointer.child != .custom or program.findStruct(param.ty.pointer.child.custom) == null) continue;
        if (name.len != caller.name.len + 1 + param.name.len or !std.mem.startsWith(u8, name, caller.name) or
            name[caller.name.len] != '_' or !same(name[caller.name.len + 1 ..], param.name)) continue;
        const slot = parameterSlot(model, lines, caller.name, name) orelse return null;
        if (slot == .zero_page and slot.zero_page.address < temporary.address + 2 and
            temporary.address < slot.zero_page.address + 2) return null;
        return .{ .parameter = .{ .function = owner, .index = index }, .line = line };
    }
    return null;
}

fn instructionThroughScratch(inst: machine.Instruction) bool {
    return inst.op == .sta and inst.operand == .indirect and same(inst.operand.indirect, "(" ++ scratch ++ "),y");
}

/// Prove the private function copies the argument to scratch before any
/// path can reach a read, and that the function body leaves scratch intact.
/// The caller separately validates global control and the parameter lifetime.
pub fn stableReadScratch(a: std.mem.Allocator, program: ast.Program, graph: layout.Analysis, model: storage.Model, parameter: Parameter) !bool {
    const function = program.functions[parameter.function];
    const name = try qualified(a, function, function.params[parameter.index].name);
    defer a.free(name);
    const lines = graph.raw.items;
    const temporary = pointerScratch(lines) orelse return false;
    const slot = parameterSlot(model, lines, function.name, name) orelse return false;
    if (slot == .zero_page and slot.zero_page.address < temporary.address + 2 and
        temporary.address < slot.zero_page.address + 2) return false;
    const entry = graph.target(function.name) orelse return false;
    const scope = graph.nodes.items[entry].scope;
    if (scope == 0) return false;
    var copied = false;
    var read = false;
    var index = entry + 1;
    while (index < graph.nodes.items.len and graph.nodes.items[index].scope == scope) : (index += 1) {
        const node = graph.nodes.items[index];
        if (layout.label(node.text) != null) {
            if (!copied) return false;
            continue;
        }
        if (!copied and index + 3 < graph.nodes.items.len and graph.nodes.items[index + 3].scope == scope and
            instruction(node.text, .lda, name, 0) and
            instruction(graph.nodes.items[index + 1].text, .sta, scratch, 0) and
            instruction(graph.nodes.items[index + 2].text, .lda, name, 1) and
            instruction(graph.nodes.items[index + 3].text, .sta, scratch, 1))
        {
            copied = true;
            index += 3;
            continue;
        }
        const inst = machine.Instruction.parse(node.text) orelse return false;
        if (inst.op == .jmp or layout.conditional(inst.op)) {
            if (!copied or inst.operand != .direct or inst.operand.direct.offset != 0) return false;
            const target = graph.target(inst.operand.direct.name) orelse return false;
            if (target <= entry or graph.nodes.items[target].scope != scope) return false;
            continue;
        }
        if (inst.op == .rts and copied) continue;
        if (inst.effects().barrier) return false;
        if (inst.operand == .indirect) {
            if (!copied or inst.op != .lda or !same(inst.operand.indirect, "(" ++ scratch ++ "),y")) return false;
            read = true;
        }
        switch (inst.effects().memory) {
            .write, .read_write => {
                if (inst.operand != .direct) return false;
                const cell = model.resolve(inst.operand.direct, 1) orelse return false;
                if (model.frames.items[cell.frame].lower < 0x0200) return false;
                if (slot == .resident and !model.disjoint(slot.resident, 2, cell, 1)) return false;
            },
            else => {},
        }
    }
    // Entries from another scope may only target the function label. Any
    // internal label is reached from the dominated part of this scope.
    for (graph.nodes.items) |node| {
        if (node.scope == scope) continue;
        const inst = machine.Instruction.parse(node.text) orelse continue;
        if (inst.op != .jsr and inst.op != .jmp and !layout.conditional(inst.op)) continue;
        if (inst.operand != .direct or inst.operand.direct.offset != 0) return false;
        const target = graph.target(inst.operand.direct.name) orelse return false;
        if (graph.nodes.items[target].scope == scope and target != entry) return false;
    }
    return copied and read;
}

/// Check an established origin's full byte-indexed write range against a
/// named resident footprint. A store's wrong-page bus cycle is a read.
pub fn originWriteDisjoint(a: std.mem.Allocator, program: ast.Program, graph: layout.Analysis, model: storage.Model, origin: Origin, protected: image.Footprint) !bool {
    const name = (try writeOriginLabel(a, program, model, origin)) orelse return false;
    defer a.free(name);
    return image.footprintsDisjoint(graph, .indexed(name, 255, false), protected);
}

pub fn originWriteDisjointFromParameter(a: std.mem.Allocator, program: ast.Program, graph: layout.Analysis, model: storage.Model, origin: Origin, parameter: Parameter) !bool {
    const callee = program.functions[parameter.function];
    const name = try qualified(a, callee, callee.params[parameter.index].name);
    defer a.free(name);
    const slot = parameterSlot(model, graph.raw.items, callee.name, name) orelse return false;
    if (slot == .resident) return originWriteDisjoint(a, program, graph, model, origin, .{ .label = name, .last = 1 });
    const root = (try writeOriginLabel(a, program, model, origin)) orelse return false;
    a.free(root);
    return true;
}

fn writeOriginLabel(a: std.mem.Allocator, program: ast.Program, model: storage.Model, origin: Origin) !?[]const u8 {
    const caller = program.functions[origin.caller];
    const name = try qualified(a, caller, origin.local);
    errdefer a.free(name);
    const cell = model.resolve(.{ .name = name }, 1) orelse {
        a.free(name);
        return null;
    };
    const frame = model.frames.items[cell.frame];
    if (same(frame.owner, caller.name) and frame.lower >= 0x0200 and frame.upper + 255 < 0x8000) return name;
    a.free(name);
    return null;
}

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn instruction(line: []const u8, op: machine.Op, name: []const u8, offset: i32) bool {
    const inst = machine.Instruction.parse(line) orelse return false;
    return inst.op == op and inst.operand == .direct and inst.operand.direct.offset == offset and same(inst.operand.direct.name, name);
}

fn addressByte(line: []const u8, op: machine.Op, selector: u8, name: []const u8) bool {
    const inst = machine.Instruction.parse(line) orelse return false;
    if (inst.op != op or inst.operand != .immediate) return false;
    const operand = inst.operand.immediate;
    return operand.len > 1 and operand[0] == selector and same(operand[1..], name);
}

fn qualified(a: std.mem.Allocator, function: ast.Function, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}_{s}", .{ function.name, name });
}

// Only projections that leave the address unchanged match this packet.
// Following the first declared field gives zero offset in the packed ABI.
fn zeroOffsetProjection(program: ast.Program, root: []const u8, path: []const u8, target: []const u8) bool {
    if (path.len == 0) return same(root, target);
    const record = program.findStruct(root) orelse return false;
    if (record.fields.len == 0) return false;
    const field = record.fields[0];
    if (field.ty != .custom) return false;
    if (same(path, field.name)) return same(field.ty.custom, target);
    return path.len > field.name.len + 1 and std.mem.startsWith(u8, path, field.name) and
        path[field.name.len] == '_' and zeroOffsetProjection(program, field.ty.custom, path[field.name.len + 1 ..], target);
}

const Slot = union(enum) {
    resident: storage.Location,
    zero_page: storage.Claim,
};

fn pointerScratch(lines: []const []const u8) ?storage.Claim {
    if (storage.claimedAddress(lines, scratch, "pointer")) |claim|
        return if (claim.width == 2) claim else null;
    var found = false;
    for (lines) |line| {
        if (!std.mem.startsWith(u8, line, scratch ++ " = ")) continue;
        if (found or !same(line, scratch ++ " = $fb")) return null;
        found = true;
    }
    return if (found) .{ .address = 0xfb, .width = 2 } else null;
}

fn parameterSlot(model: storage.Model, lines: []const []const u8, owner: []const u8, name: []const u8) ?Slot {
    if (model.resolveObject(.{ .name = name }, 2)) |cell| {
        const frame = model.frames.items[cell.frame];
        if (same(frame.owner, owner) and frame.upper <= 0x8000) return .{ .resident = cell };
    }
    const claim = storage.claimedAddress(lines, name, "parameter") orelse return null;
    return if (claim.width == 2) .{ .zero_page = claim } else null;
}

fn matchSource(a: std.mem.Allocator, program: ast.Program, model: storage.Model, lines: []const []const u8, edge: domains.RecordArgument, low_store: usize) !?usize {
    if (low_store < 2) return null;
    const caller = program.functions[edge.caller];
    const target_type = program.functions[edge.callee].params[edge.parameter].ty.pointer.child.custom;
    switch (edge.source) {
        .unknown => return null,
        .local => |name| {
            const label = try qualified(a, caller, name);
            const cell = model.resolve(.{ .name = label }, 1) orelse return null;
            const frame = model.frames.items[cell.frame];
            if (!same(frame.owner, caller.name) or frame.upper > 0x8000) return null;
            const address = try std.fmt.allocPrint(a, "{s}+0", .{label});
            if (addressByte(lines[low_store - 2], .ldx, '>', address) and
                addressByte(lines[low_store - 1], .lda, '<', address)) return low_store - 2;
        },
        .forwarded => |from| {
            const param = caller.params[from.parameter];
            if (param.ty != .pointer or param.ty.pointer.child != .custom or
                !zeroOffsetProjection(program, param.ty.pointer.child.custom, from.path, target_type)) return null;
            const label = try qualified(a, caller, param.name);
            const slot = parameterSlot(model, lines, caller.name, label) orelse return null;
            if (from.path.len == 0) {
                if (instruction(lines[low_store - 2], .ldx, label, 1) and
                    instruction(lines[low_store - 1], .lda, label, 0)) return low_store - 2;
            } else if (low_store >= 6 and
                instruction(lines[low_store - 6], .lda, label, 0) and
                instruction(lines[low_store - 5], .sta, scratch, 0) and
                instruction(lines[low_store - 4], .lda, label, 1) and
                instruction(lines[low_store - 3], .sta, scratch, 1) and
                instruction(lines[low_store - 2], .ldx, scratch, 1) and
                instruction(lines[low_store - 1], .lda, scratch, 0))
            {
                const temporary = pointerScratch(lines) orelse return null;
                if (slot == .zero_page and slot.zero_page.address < temporary.address + 2 and
                    temporary.address < slot.zero_page.address + 2) return null;
                return low_store - 6;
            }
        },
    }
    return null;
}

fn lowStore(a: std.mem.Allocator, program: ast.Program, model: storage.Model, lines: []const []const u8, callee: ast.Function, index: usize, transfer: usize) !?usize {
    var end = transfer;
    // The known ABI shapes have the record pointer first and at most one
    // trailing byte parameter. Its store cannot touch the record pair.
    if (index != 0 or callee.params.len == 0 or callee.params.len > 2) return null;
    if (callee.params.len == 2) {
        const trailing = callee.params[1];
        switch (trailing.ty) {
            .u8, .i8, .bool => {},
            .custom => |name| if (program.findEnum(name) == null) return null,
            else => return null,
        }
        const label = try qualified(a, callee, trailing.name);
        const pointer = try qualified(a, callee, callee.params[index].name);
        const pointer_slot = parameterSlot(model, lines, callee.name, pointer) orelse return null;
        const disjoint = if (model.resolveObject(.{ .name = label }, 1)) |slot|
            pointer_slot == .zero_page or model.disjoint(pointer_slot.resident, 2, slot, 1)
        else if (storage.claimedAddress(lines, label, "parameter")) |slot|
            slot.width == 1 and (pointer_slot == .resident or slot.address < pointer_slot.zero_page.address or slot.address >= pointer_slot.zero_page.address + 2)
        else
            false;
        if (!disjoint or end < 2 or !instruction(lines[end - 1], .sta, label, 0)) return null;
        const load = machine.Instruction.parse(lines[end - 2]) orelse return null;
        if (load.op != .lda or (load.operand != .direct and load.operand != .immediate)) return null;
        end -= 2;
    } else if (end > 0 and same(std.mem.trim(u8, lines[end - 1], " \t"), "txa")) {
        end -= 1;
    }
    return if (end >= 2) end - 2 else null;
}

fn callerAt(program: ast.Program, lines: []const []const u8, line: usize) ?usize {
    var first = line;
    while (first > 0) {
        first -= 1;
        const text = lines[first];
        if (!std.mem.startsWith(u8, text, "; zeropage_section_")) continue;
        const owner = storage.sectionOwner(text, "code") orelse return null;
        for (program.functions, 0..) |function, i| if (same(function.name, owner)) return i;
        return null;
    }
    return null;
}

fn directWriteTouches(model: storage.Model, lines: []const []const u8, inst: machine.Instruction, name: []const u8, slot: Slot) bool {
    switch (inst.operand) {
        .direct => |ref| {
            if (std.ascii.eqlIgnoreCase(ref.name, name)) return true;
            if (slot == .resident) {
                const cell = model.resolve(ref, 1) orelse return false;
                return cell.frame == slot.resident.frame and cell.offset >= slot.resident.offset and cell.offset < slot.resident.offset + 2;
            }
            const claim = storage.claimedAddress(lines, ref.name, "parameter") orelse return false;
            const address = @as(i64, claim.address) + ref.offset;
            return address >= slot.zero_page.address and address < slot.zero_page.address + 2;
        },
        .indexed => |ref| return std.ascii.eqlIgnoreCase(ref.base.name, name),
        .address => |address| return slot == .zero_page and address >= slot.zero_page.address and address < slot.zero_page.address + 2,
        else => return false,
    }
}

/// Match each retained argument to a distinct straight-line setup and a JSR
/// or tail JMP. This checks the named stores and known direct aliases. Other
/// aliases and the lifetime of these values are obligations of the consumer.
pub fn match(a: std.mem.Allocator, program: ast.Program, graph: layout.Analysis, model: storage.Model, arguments: []const domains.RecordArgument, parameter: Parameter) !?[]Packet {
    if (!graph.complete or parameter.function >= program.functions.len) return null;
    const callee = program.functions[parameter.function];
    if (callee.exported or same(callee.name, "main") or parameter.index >= callee.params.len or
        callee.params[parameter.index].ty != .pointer or callee.params[parameter.index].ty.pointer.child != .custom or
        graph.target(callee.name) == null) return null;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    const lines = graph.raw.items;
    const name = try qualified(temp, callee, callee.params[parameter.index].name);
    const slot = parameterSlot(model, lines, callee.name, name) orelse return null;
    const used = try temp.alloc(bool, arguments.len);
    @memset(used, false);
    var packets: std.ArrayList(Packet) = .empty;
    defer packets.deinit(a);
    for (graph.nodes.items) |node| {
        const inst = machine.Instruction.parse(node.text) orelse continue;
        if (inst.op != .jsr and inst.op != .jmp and !layout.conditional(inst.op)) continue;
        if (inst.operand != .direct or !std.ascii.eqlIgnoreCase(inst.operand.direct.name, callee.name)) continue;
        if (node.zone != .code or inst.operand.direct.offset != 0 or layout.conditional(inst.op)) return null;
        const caller = callerAt(program, lines, node.index) orelse return null;
        const low = (try lowStore(temp, program, model, lines, callee, parameter.index, node.index)) orelse return null;
        if (!instruction(lines[low], .sta, name, 0) or !instruction(lines[low + 1], .stx, name, 1)) return null;
        for (arguments, used) |edge, *matched| {
            if (matched.* or edge.caller != caller or edge.callee != parameter.function or edge.parameter != parameter.index) continue;
            const first = (try matchSource(temp, program, model, lines, edge, low)) orelse continue;
            if (callerAt(program, lines, first) != caller) return null;
            matched.* = true;
            try packets.append(a, .{ .argument = edge, .first_line = first, .low_store = low, .transfer = node.index });
            break;
        } else return null;
    }
    if (packets.items.len == 0) return null;
    for (arguments, used) |edge, matched| {
        if (edge.callee == parameter.function and edge.parameter == parameter.index and !matched) return null;
    }
    for (graph.nodes.items) |node| {
        const inst = machine.Instruction.parse(node.text) orelse continue;
        const effect = inst.effects().memory;
        if (effect != .write and effect != .read_write) continue;
        if (!directWriteTouches(model, lines, inst, name, slot)) continue;
        for (packets.items) |packet| {
            if (node.index == packet.low_store or node.index == packet.low_store + 1) break;
        } else return null;
    }
    return try packets.toOwnedSlice(a);
}

/// Trace matched setup packets back to distinct named resident locals.
/// Cycles and unmatched native entries fail the trace. The result still
/// needs an access-width and indirect-write proof before removing a store.
pub fn trace(a: std.mem.Allocator, program: ast.Program, graph: layout.Analysis, model: storage.Model, arguments: []const domains.RecordArgument, parameter: Parameter) !?[]Origin {
    var work: Trace = .{ .allocator = a, .program = program, .graph = graph, .model = model, .arguments = arguments };
    defer work.active.deinit(a);
    defer work.finished.deinit(a);
    defer work.origins.deinit(a);
    if (!try work.visit(parameter)) return null;
    return try work.origins.toOwnedSlice(a);
}

const Trace = struct {
    allocator: std.mem.Allocator,
    program: ast.Program,
    graph: layout.Analysis,
    model: storage.Model,
    arguments: []const domains.RecordArgument,
    active: std.AutoHashMapUnmanaged(Parameter, void) = .empty,
    finished: std.AutoHashMapUnmanaged(Parameter, void) = .empty,
    origins: std.ArrayList(Origin) = .empty,

    fn visit(self: *Trace, parameter: Parameter) std.mem.Allocator.Error!bool {
        if (self.finished.contains(parameter)) return true;
        if (self.active.contains(parameter) or self.active.count() >= 64) return false;
        const a = self.allocator;
        try self.active.put(a, parameter, {});
        defer _ = self.active.remove(parameter);
        const incoming = (try match(a, self.program, self.graph, self.model, self.arguments, parameter)) orelse return false;
        defer a.free(incoming);
        for (incoming) |packet| {
            const edge = packet.argument;
            switch (edge.source) {
                .unknown => return false,
                .forwarded => |value| if (!try self.visit(.{ .function = edge.caller, .index = value.parameter })) return false,
                .local => |name| {
                    for (self.origins.items) |origin| {
                        if (origin.caller == edge.caller and same(origin.local, name)) break;
                    } else try self.origins.append(a, .{ .caller = edge.caller, .local = name });
                },
            }
        }
        try self.finished.put(a, parameter, {});
        return true;
    }
};
