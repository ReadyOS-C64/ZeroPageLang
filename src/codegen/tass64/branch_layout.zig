const std = @import("std");
const machine = @import("instruction.zig");
pub const Zone = enum { code, data, unsectioned };
pub const Line = struct { index: usize, text: []const u8, zone: Zone = .unsectioned, scope: usize = 0, runtime: bool = false };
const Section = struct { owner: []const u8, kind: []const u8 };
fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}
fn identifierByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}
fn symbol(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| if (!identifierByte(c)) return false;
    return true;
}
pub fn label(s: []const u8) ?[]const u8 {
    if (s.len < 2 or s[s.len - 1] != ':') return null;
    return if (symbol(s[0 .. s.len - 1])) s[0 .. s.len - 1] else null;
}
fn section(text: []const u8) ?Section {
    var owner: ?[]const u8 = null;
    var kind: ?[]const u8 = null;
    var fields = std.mem.tokenizeAny(u8, text, " \t");
    while (fields.next()) |field| {
        if (std.mem.startsWith(u8, field, "owner=")) {
            if (owner != null or field.len == 6) return null;
            owner = field[6..];
        } else if (std.mem.startsWith(u8, field, "kind=")) {
            if (kind != null or field.len == 5) return null;
            kind = field[5..];
        }
    }
    return .{ .owner = owner orelse return null, .kind = kind orelse return null };
}
pub fn conditional(op: machine.Op) bool {
    return switch (op) {
        .bcc, .bcs, .beq, .bne, .bmi, .bpl, .bvc, .bvs => true,
        else => false,
    };
}
fn uniqueLabel(lines: []const Line, name: []const u8) ?usize {
    var found: ?usize = null;
    for (lines, 0..) |line, index| if (label(line.text)) |defined| {
        if (!std.ascii.eqlIgnoreCase(defined, name)) continue;
        if (found != null) return null;
        found = index;
    };
    return found;
}
fn looksControl(text: []const u8) bool {
    const end = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
    for ([_][]const u8{ "jmp", "jsr", "bcc", "bcs", "beq", "bne", "bmi", "bpl", "bvc", "bvs", "brk", "rti" }) |op|
        if (std.ascii.eqlIgnoreCase(text[0..end], op)) return true;
    return false;
}
// Same conservative control boundary as branch_A: all explicit control targets
// are unique named code entries, never numeric, offset, indirect or raw data.
fn isStackOverflowTrap(lines: []const Line, index: usize) bool {
    if (index == 0 or index + 1 >= lines.len) return false;
    const trap = lines[index];
    if (!trap.runtime or trap.zone != .code or !std.mem.eql(u8, trap.text, "brk")) return false;
    const entry = lines[index - 1];
    const jump = lines[index + 1];
    const name = "zeropage_stack_overflow_trap";
    return entry.scope == trap.scope and jump.scope == trap.scope and
        std.mem.eql(u8, entry.text, name ++ ":") and std.mem.eql(u8, jump.text, "jmp " ++ name) and
        (index == 1 or lines[index - 2].scope != trap.scope) and
        (index + 2 == lines.len or lines[index + 2].scope != trap.scope);
}

fn controlsKnown(a: std.mem.Allocator, lines: []const Line, allow_stack_trap: bool) !bool {
    var pending: std.ArrayList(usize) = .empty;
    defer pending.deinit(a);
    for (lines, 0..) |line, index| {
        const inst = machine.Instruction.parse(line.text) orelse {
            if (looksControl(line.text)) return false;
            continue;
        };
        if (inst.op == .brk and !(allow_stack_trap and isStackOverflowTrap(lines, index))) return false;
        if (inst.op == .rti) return false;
        if (inst.op != .jmp and inst.op != .jsr and !conditional(inst.op)) continue;
        if (inst.operand != .direct or inst.operand.direct.offset != 0) return false;
        // Instruction parsing strips addressing-size hints for its effect
        // model. Do not turn a forced or malformed control into a valid plain
        // branch while deleting it: accept only the original bare identifier.
        const split = std.mem.indexOfAny(u8, line.text, " \t") orelse return false;
        const raw_target = trim(line.text[split..]);
        if (!symbol(raw_target) or !std.mem.eql(u8, raw_target, inst.operand.direct.name)) return false;
        try pending.append(a, uniqueLabel(lines, inst.operand.direct.name) orelse return false);
    }
    const visited = try a.alloc(bool, lines.len);
    defer a.free(visited);
    @memset(visited, false);
    while (pending.pop()) |index| {
        if (index >= lines.len) return false;
        if (visited[index]) continue;
        visited[index] = true;
        const line = lines[index];
        if (line.zone == .data) return false;
        if (label(line.text) != null) {
            try pending.append(a, index + 1);
            continue;
        }
        if (line.zone == .code) continue;
        const inst = machine.Instruction.parse(line.text) orelse return false;
        if (inst.op == .rts) continue;
        if (inst.op == .jmp or inst.op == .jsr or conditional(inst.op)) {
            try pending.append(a, uniqueLabel(lines, inst.operand.direct.name).?);
            if (inst.op == .jmp) continue;
        }
        try pending.append(a, index + 1);
    }
    return true;
}
pub fn tokenPresent(text: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (!identifierByte(text[i])) {
            i += 1;
            continue;
        }
        const first = i;
        while (i < text.len and identifierByte(text[i])) : (i += 1) {}
        if (std.ascii.eqlIgnoreCase(text[first..i], name)) return true;
    }
    return false;
}
fn codeObserved(lines: []const Line, operands_only: bool) bool {
    for (lines) |definition| {
        if (definition.zone != .code) continue;
        const name = label(definition.text) orelse continue;
        for (lines) |line| {
            if (label(line.text) != null) continue;
            const instruction = machine.Instruction.parse(line.text);
            if (instruction) |inst| {
                if (inst.op == .jmp or inst.op == .jsr or conditional(inst.op)) continue;
            }
            const references = if (operands_only and (instruction != null or std.mem.startsWith(u8, line.text, ".")))
                line.text[std.mem.indexOfAny(u8, line.text, " \t") orelse line.text.len ..]
            else
                line.text;
            // Conservative even for quoted data: an ambiguous code-name token
            // is not permission to change instruction-address arithmetic.
            if (tokenPresent(references, name)) return true;
        }
    }
    return false;
}
fn architectureOverride(s: []const u8) bool {
    const end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
    for ([_][]const u8{ ".cpu", ".al", ".as", ".xl", ".xs" }) |directive|
        if (std.ascii.eqlIgnoreCase(s[0..end], directive)) return true;
    return false;
}

// Bounds are on encoded bytes, not source text. Every direct/indexed memory
// operand conservatively costs three, including ZP aliases and forced absolute
// forms; immediate operands cost two, truly operandless instructions one. This can
// decline a short ZP-heavy span, but cannot undercount a valid NMOS instruction.
// Numeric indexed operands used by ZP enter/leave have no symbolic effects model;
// only their strict literal+X/Y spelling is admitted here, at the full3B bound.
// Unknown expressions or multi-statement operand text still decline.
pub const LiteralIndex = struct { address: u16, register: u16 };

pub fn literalIndex(text: []const u8) ?LiteralIndex {
    const first = std.mem.indexOfAny(u8, text, " \t") orelse return null;
    const operand = trim(text[first..]);
    const comma = std.mem.indexOfScalar(u8, operand, ',') orelse return null;
    const base = trim(operand[0..comma]);
    const register = trim(operand[comma + 1 ..]);
    const mask = if (std.mem.eql(u8, register, "x")) machine.x else if (std.mem.eql(u8, register, "y")) machine.y else return null;
    const value = machine.integer(base) orelse return null;
    return if (value <= 65535) .{ .address = @intCast(value), .register = mask } else null;
}
fn maxEncodedWidth(inst: machine.Instruction, text: []const u8) ?usize {
    if (conditional(inst.op)) return 2;
    if (inst.op == .jmp or inst.op == .jsr) return 3;
    return switch (inst.operand) {
        // The effect parser accepts explicit `a` as accumulator syntax even
        // for LDA/STA. In the assembler it may be a three-byte symbol access.
        .none => if (std.mem.indexOfAny(u8, text, " \t")) |split| (if (trim(text[split..]).len == 0) @as(usize, 1) else 3) else 1,
        .immediate => 2,
        // Parenthesized expressions such as (cell)+0 may encode absolute.
        // Canonical (zp),Y also takes this conservative maximum bound.
        .indirect => 3,
        .direct, .address, .indexed => 3,
        .unknown => if (literalIndex(text) != null) 3 else null,
    };
}

const StackPointers = struct {
    sp: bool = false,
    fp: bool = false,

    fn collect(lines: []const Line) StackPointers {
        return .{
            .sp = hasBytePair(lines, "zeropage_stack_sp"),
            .fp = hasBytePair(lines, "zeropage_stack_fp"),
        };
    }

    fn hasBytePair(lines: []const Line, name: []const u8) bool {
        var found = false;
        for (lines) |line| {
            if (!std.ascii.startsWithIgnoreCase(line.text, name)) continue;
            const rest = line.text[name.len..];
            if (rest.len != 0 and identifierByte(rest[0])) continue;
            if (found or line.zone != .unsectioned) return false;
            const assignment = trim(rest);
            if (assignment.len == 0 or assignment[0] != '=') return false;
            const literal = trim(assignment[1..]);
            if (literal.len != 3 or literal[0] != '$') return false;
            if ((machine.integer(literal) orelse return false) >= 0xff) return false;
            found = true;
        }
        return found;
    }

    fn operandWidth(self: StackPointers, inst: machine.Instruction, text: []const u8) ?usize {
        switch (inst.op) {
            .lda, .ldx, .ldy, .sta, .stx, .sty, .adc, .sbc, .cmp => {},
            else => return null,
        }
        const split = std.mem.indexOfAny(u8, text, " \t") orelse return null;
        const operand = trim(text[split..]);
        if (self.sp and isPairOperand(operand, "zeropage_stack_sp", inst)) return 2;
        if (self.fp and isPairOperand(operand, "zeropage_stack_fp", inst)) return 2;
        return null;
    }

    fn isPairOperand(operand: []const u8, comptime name: []const u8, inst: machine.Instruction) bool {
        if (inst.operand == .direct)
            return std.mem.eql(u8, operand, name) or std.mem.eql(u8, operand, name ++ "+1");
        return inst.operand == .indirect and inst.op != .ldx and inst.op != .ldy and inst.op != .stx and inst.op != .sty and
            std.mem.eql(u8, operand, "(" ++ name ++ "),y");
    }
};

pub const Analysis = struct {
    complete: bool = false,
    raw: std.ArrayList([]const u8) = .empty,
    nodes: std.ArrayList(Line) = .empty,
    stack_pointers: StackPointers = .{},
    pub fn deinit(self: *Analysis, a: std.mem.Allocator) void {
        self.raw.deinit(a);
        self.nodes.deinit(a);
        self.* = .{};
    }
    pub fn target(self: Analysis, name: []const u8) ?usize {
        return uniqueLabel(self.nodes.items, name);
    }
    pub fn maxBytes(self: Analysis, first: usize, end: usize) ?usize {
        if (first > end or end > self.nodes.items.len) return null;
        var sum: usize = 0;
        for (self.nodes.items[first..end]) |node| {
            if (label(node.text) != null) continue;
            const inst = machine.Instruction.parse(node.text) orelse return null;
            const width = self.stack_pointers.operandWidth(inst, node.text) orelse maxEncodedWidth(inst, node.text) orelse return null;
            sum = std.math.add(usize, sum, width) catch return null;
        }
        return sum;
    }
};

pub fn parse(a: std.mem.Allocator, text: []const u8) !Analysis {
    return parseInternal(a, text, true, false);
}

pub fn parseWithStackOverflowTrap(a: std.mem.Allocator, text: []const u8) !Analysis {
    return parseInternal(a, text, true, true);
}

/// Parse the same encoded layout when a consumer needs a byte bound only.
/// This does not certify control flow or the absence of address observers.
pub fn parseForSize(a: std.mem.Allocator, text: []const u8) !Analysis {
    return parseInternal(a, text, false, false);
}

/// Check the control graph and code-address references on a size-only parse.
/// A mnemonic or directive name does not refer to a same-named function.
pub fn controlsUnobserved(a: std.mem.Allocator, analysis: Analysis) !bool {
    return analysis.complete and try controlsKnown(a, analysis.nodes.items, false) and
        !codeObserved(analysis.nodes.items, true);
}

fn parseInternal(a: std.mem.Allocator, text: []const u8, check_control: bool, allow_stack_trap: bool) !Analysis {
    var result: Analysis = .{};
    errdefer result.deinit(a);
    if (std.mem.indexOf(u8, text, "; inline asm") != null) return result;
    var active: ?Section = null;
    var scope: usize = 0;
    var next_scope: usize = 0;
    var split = std.mem.splitScalar(u8, text, '\n');
    while (split.next()) |raw| {
        const index = result.raw.items.len;
        try result.raw.append(a, raw);
        const s = trim(raw);
        if (architectureOverride(s)) return result;
        if (std.mem.startsWith(u8, s, "; zeropage_section_")) {
            const marker = section(s) orelse return result;
            if (std.mem.startsWith(u8, s, "; zeropage_section_begin ")) {
                if (active != null) return result;
                active = marker;
                next_scope += 1;
                scope = next_scope;
            } else if (std.mem.startsWith(u8, s, "; zeropage_section_end ")) {
                const prior = active orelse return result;
                if (!std.mem.eql(u8, prior.owner, marker.owner) or !std.mem.eql(u8, prior.kind, marker.kind)) return result;
                active = null;
                scope = 0;
            } else return result;
            continue;
        }
        if (s.len == 0 or s[0] == ';') continue;
        const zone: Zone = if (active) |current| (if (std.mem.eql(u8, current.kind, "code")) .code else .data) else .unsectioned;
        if (zone == .code and label(s) == null) {
            if (std.mem.indexOfScalar(u8, s, ':') != null) return result;
            const inst = machine.Instruction.parse(s) orelse return result;
            if (maxEncodedWidth(inst, s) == null) return result;
        }
        const runtime = if (active) |current| std.mem.eql(u8, current.owner, "runtime") else false;
        try result.nodes.append(a, .{ .index = index, .text = s, .zone = zone, .scope = scope, .runtime = runtime });
    }
    if (active != null) return result;
    if (check_control and (!try controlsKnown(a, result.nodes.items, allow_stack_trap) or codeObserved(result.nodes.items, false))) return result;
    if (allow_stack_trap) result.stack_pointers = StackPointers.collect(result.nodes.items);
    result.complete = true;
    return result;
}
