const std = @import("std");
const ast = @import("../../ast.zig");
const machine = @import("instruction.zig");
const scalars = @import("zero_page_scalars.zig");
const storage = @import("storage_model.zig");

pub const Marker = struct { id: usize, index: usize, width: u32, temp: []const u8, target: []const u8, line: usize };
pub const Argument = struct { decision: usize, store: ?Marker = null, copy: ?Marker = null };
pub const Call = struct {
    id: usize,
    callee: []const u8,
    begin: usize,
    end: usize = 0,
    arguments: []Argument,
    stores: usize = 0,
    copies: usize = 0,
    temp_base: ?usize = null,
};
const Prefix = "; zeropage_scalar_call_";
fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r\n");
}
fn next(words: *std.mem.TokenIterator(u8, .scalar), key: []const u8) ?[]const u8 {
    const word = words.next() orelse return null;
    if (word.len <= key.len + 1 or !std.mem.startsWith(u8, word, key) or word[key.len] != '=') return null;
    return word[key.len + 1 ..];
}
fn number(text: []const u8) ?usize {
    if (text.len == 0) return null;
    for (text) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseInt(usize, text, 10) catch null;
}
fn identifier(text: []const u8) bool {
    if (text.len == 0 or !(std.ascii.isAlphabetic(text[0]) or text[0] == '_')) return false;
    for (text[1..]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}
pub fn exact(raw: []const u8, op: machine.Op, label: []const u8, offset: i32) bool {
    const inst = machine.Instruction.parse(trim(raw)) orelse return false;
    return inst.op == op and inst.operand == .direct and std.mem.eql(u8, inst.operand.direct.name, label) and inst.operand.direct.offset == offset;
}
pub fn shape(lines: []const []const u8, store: Marker, copy: Marker) bool {
    if (store.line + store.width >= lines.len or copy.line + 2 * copy.width >= lines.len) return false;
    if (!exact(lines[store.line + 1], .sta, store.temp, 0)) return false;
    if (!exact(lines[copy.line + 1], .lda, store.temp, 0) or !exact(lines[copy.line + 2], .sta, store.target, 0)) return false;
    return store.width == 1 or (exact(lines[store.line + 2], .stx, store.temp, 1) and exact(lines[copy.line + 3], .lda, store.temp, 1) and exact(lines[copy.line + 4], .sta, store.target, 1));
}
pub fn visible(model: storage.Model, location: storage.Location) bool {
    const frame = model.frames.items[location.frame];
    return frame.valid and frame.ordinary_ram and (frame.upper <= 0xa000 or (frame.lower >= 0xc000 and frame.upper <= 0xd000));
}
fn targetMatches(target: []const u8, callee: []const u8, parameter: []const u8) bool {
    return target.len == callee.len + 1 + parameter.len and std.mem.startsWith(u8, target, callee) and target[callee.len] == '_' and std.mem.eql(u8, target[callee.len + 1 ..], parameter);
}
fn decisionFor(decisions: []const scalars.Decision, callee: []const u8, parameter: []const u8) ?usize {
    var found: ?usize = null;
    for (decisions, 0..) |d, index| if (std.mem.eql(u8, d.function_name, callee) and std.mem.eql(u8, d.parameter_name, parameter)) {
        if (found != null or !targetMatches(d.label, callee, parameter) or (d.size != 1 and d.size != 2)) return null;
        found = index;
    };
    return found;
}
fn tempDefinition(model: storage.Model, lines: []const []const u8, name: []const u8) bool {
    const loc = model.resolve(.{ .name = name }, 2) orelse return false;
    if (!std.mem.eql(u8, model.frames.items[loc.frame].owner, "compiler:scratch")) return false;
    var count: usize = 0;
    for (lines, 0..) |raw, index| {
        const line = trim(raw);
        if (!std.mem.endsWith(u8, line, ":")) continue;
        const label = line[0 .. line.len - 1];
        if (!std.ascii.eqlIgnoreCase(label, name)) continue;
        count += 1;
        if (!std.mem.eql(u8, label, name) or index + 1 >= lines.len or !std.mem.eql(u8, trim(lines[index + 1]), ".word 0")) return false;
    }
    if (count != 1) return false;
    var names = model.labels.iterator();
    while (names.next()) |entry| {
        const other = entry.value_ptr.*;
        if (other.frame == loc.frame and other.offset >= loc.offset and other.offset < loc.offset + 2 and !std.mem.eql(u8, entry.key_ptr.*, name)) return false;
    }
    return true;
}
fn callEnd(lines: []const []const u8, call: Call) bool {
    if (call.stores != call.arguments.len or call.copies != call.arguments.len) return false;
    for (call.arguments, 0..) |arg, index| {
        const store = arg.store orelse return false;
        const copy = arg.copy orelse return false;
        if (!shape(lines, store, copy) or store.line + store.width >= call.arguments[0].copy.?.line) return false;
        const stop = if (index + 1 < call.arguments.len) call.arguments[index + 1].copy.?.line else call.end;
        var line = copy.line + 1 + 2 * copy.width;
        if (line > stop) return false;
        while (line < stop) : (line += 1) {
            const text = trim(lines[line]);
            // Every proof marker is parsed separately; no nested or unknown
            // markers, labels, stack effects or source code may hide here.
            if (text.len != 0 and (text[0] != ';' or std.mem.startsWith(u8, text, Prefix))) return false;
        }
    }
    var next_line = call.end + 1;
    while (next_line < lines.len) : (next_line += 1) {
        const line = trim(lines[next_line]);
        if (line.len == 0 or line[0] == ';') continue;
        return exact(line, .jsr, call.callee, 0);
    }
    return false;
}
pub fn deinit(allocator: std.mem.Allocator, calls: []Call) void {
    for (calls) |call| allocator.free(call.arguments);
    allocator.free(calls);
}

/// Own call/argument arrays; names borrow the input AST/assembly. Invalid proof
/// metadata declines the complete batch. This validates the actual emitter's
/// scalar-copy grammar, not arbitrary assembly or placement eligibility.
pub fn collect(allocator: std.mem.Allocator, program: ast.Program, lines: []const []const u8, decisions: []const scalars.Decision, model: storage.Model) !?[]Call {
    var calls: std.ArrayList(Call) = .empty;
    defer {
        for (calls.items) |call| allocator.free(call.arguments);
        calls.deinit(allocator);
    }
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(allocator);
    for (lines, 0..) |raw, line_index| {
        const text = trim(raw);
        if (!std.mem.startsWith(u8, text, Prefix)) continue;
        var words = std.mem.tokenizeScalar(u8, text[Prefix.len..], ' ');
        const kind = words.next() orelse return null;
        const id = number(next(&words, "id") orelse return null) orelse return null;
        if (std.mem.eql(u8, kind, "begin")) {
            const callee_name = next(&words, "callee") orelse return null;
            const count = number(next(&words, "count") orelse return null) orelse return null;
            if (words.next() != null or !identifier(callee_name) or count == 0) return null;
            for (calls.items) |call| if (call.id == id) return null;
            if (stack.items.len != 0 and calls.items[stack.items[stack.items.len - 1]].copies != 0) return null;
            const callee = program.findFunction(callee_name) orelse return null;
            if (callee.params.len != count) return null;
            const arguments = try allocator.alloc(Argument, count);
            var owned = true;
            defer if (owned) allocator.free(arguments);
            for (callee.params, 0..) |param, index| arguments[index] = .{ .decision = decisionFor(decisions, callee_name, param.name) orelse return null };
            try calls.append(allocator, .{ .id = id, .callee = callee.name, .begin = line_index, .arguments = arguments });
            owned = false;
            try stack.append(allocator, calls.items.len - 1);
            continue;
        }
        if (stack.items.len == 0) return null;
        const call = &calls.items[stack.items[stack.items.len - 1]];
        if (call.id != id) return null;
        if (std.mem.eql(u8, kind, "end")) {
            if (words.next() != null) return null;
            call.end = line_index;
            if (!callEnd(lines, call.*)) return null;
            _ = stack.pop();
            continue;
        }
        const is_store = std.mem.eql(u8, kind, "store");
        const is_copy = std.mem.eql(u8, kind, "copy");
        if (!is_store and !is_copy) return null;
        const index = number(next(&words, "index") orelse return null) orelse return null;
        const width = number(next(&words, "width") orelse return null) orelse return null;
        const temp = next(&words, "temp") orelse return null;
        const target = next(&words, "target") orelse return null;
        if (words.next() != null or index >= call.arguments.len or (width != 1 and width != 2) or !identifier(target) or !std.mem.startsWith(u8, temp, "zeropage_call_arg_")) return null;
        const slot = number(temp["zeropage_call_arg_".len..]) orelse return null;
        if (slot < index) return null;
        if (call.temp_base) |base| {
            if (slot - index != base) return null;
        } else call.temp_base = slot - index;
        const arg = &call.arguments[index];
        const decision = decisions[arg.decision];
        if (width != decision.size or !std.mem.eql(u8, target, decision.label) or !tempDefinition(model, lines, temp)) return null;
        const value: Marker = .{ .id = id, .index = index, .width = @intCast(width), .temp = temp, .target = target, .line = line_index };
        if (is_store) {
            if (call.copies != 0 or call.stores != index or arg.store != null) return null;
            arg.store = value;
            call.stores += 1;
        } else {
            if (call.stores != call.arguments.len or call.copies != index or arg.copy != null) return null;
            const store = arg.store orelse return null;
            if (!std.mem.eql(u8, store.temp, temp) or !std.mem.eql(u8, store.target, target) or store.width != width) return null;
            arg.copy = value;
            call.copies += 1;
        }
    }
    if (stack.items.len != 0) return null;
    const result = try calls.toOwnedSlice(allocator);
    // Ownership transferred; defer above sees an empty list.
    return result;
}
