const std = @import("std");
const ast = @import("../../ast.zig");
const machine = @import("instruction.zig");
const layout = @import("branch_layout.zig");
const placement_domains = @import("placement_domains.zig");
pub const Decline = enum { none, unproven_program, unproven_layout, unproven_control, code_observer };
pub const Stats = struct { declined: Decline = .none, instructions_removed: usize = 0, labeled_instructions_removed: usize = 0, fallthrough_jumps_removed: usize = 0, runs_removed: usize = 0, rts_removed: usize = 0, jumps_removed: usize = 0, bytes_removed_upper: usize = 0 };
pub const Result = struct { assembly: []u8, stats: Stats };
const Value = struct { lower: u32, upper: u32, fixed: bool = false };
const Definition = struct { name: []const u8, address: ?Value = null, alias: ?[]const u8 = null };
const Padding = struct { start: usize, end: usize };
const Definitions = struct {
    items: []Definition,
    image_start: u32,
    image_end: u32,
    padding: ?Padding = null,

    fn observesImage(self: Definitions, base: u32, additional: u32) bool {
        const end = base + additional;
        if (base < self.image_end and end >= self.image_start) return true;
        return end >= 65536 and end - 65536 >= self.image_start;
    }
};
fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}
fn identifier(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}
fn symbolic(s: []const u8) ?machine.Symbol {
    // The effect parser reserves plain `a` for accumulator syntax. Here it can
    // be a real assembler symbol, whose unique definition must still resolve.
    if (identifier(s)) return .{ .name = s };
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return null;
    const value = machine.parseOperand(s);
    return if (value == .direct) value.direct else null;
}
fn definition(defs: []const Definition, name: []const u8) ?Definition {
    var found: ?Definition = null;
    for (defs) |d| if (std.ascii.eqlIgnoreCase(d.name, name)) {
        if (found != null) return null;
        found = d;
    };
    return found;
}
fn valueOf(defs: []const Definition, text: []const u8, depth: usize) ?Value {
    if (depth > 16) return null;
    const s = trim(text);
    if (machine.integer(s)) |v| return if (v <= 65535) .{ .lower = v, .upper = v, .fixed = true } else null;
    if (std.mem.startsWith(u8, s, "address(") and std.mem.endsWith(u8, s, ")")) return valueOf(defs, s[8 .. s.len - 1], depth + 1);
    const ref = symbolic(s) orelse return null;
    const d = definition(defs, ref.name) orelse return null;
    const base = if (d.alias) |alias| valueOf(defs, alias, depth + 1) orelse return null else d.address orelse return null;
    const lower = @as(i64, base.lower) + ref.offset;
    const upper = @as(i64, base.upper) + ref.offset;
    if (lower < 0 or upper > 65535) return null;
    return .{ .lower = @intCast(lower), .upper = @intCast(upper), .fixed = base.fixed };
}
fn scalarExpression(text: []const u8) bool {
    var s = trim(text);
    while (std.mem.startsWith(u8, s, "address(") and std.mem.endsWith(u8, s, ")")) s = trim(s[8 .. s.len - 1]);
    return machine.integer(s) != null or symbolic(s) != null;
}
fn literalString(s: []const u8) ?u32 {
    if (s.len < 2 or s[0] != '"' or s[s.len - 1] != '"') return null;
    for (s[1 .. s.len - 1]) |c| if (c == '"' or c == '\\' or c < 32 or c >= 127) return null;
    return @intCast(s.len - 2);
}
fn dataWidth(s: []const u8, defs: ?[]const Definition) ?u32 {
    if (std.mem.startsWith(u8, s, ".text ")) return literalString(trim(s[6..]));
    if (std.mem.startsWith(u8, s, ".fill ")) {
        if (std.mem.eql(u8, s, ".fill (($100 - (* & $ff)) & $ff),0")) return 255;
        const comma = std.mem.indexOfScalar(u8, s, ',') orelse return null;
        const count = machine.integer(trim(s[6..comma])) orelse return null;
        const byte = machine.integer(trim(s[comma + 1 ..])) orelse return null;
        return if (count <= 65536 and byte <= 255) count else null;
    }
    const unit: u32 = if (std.mem.startsWith(u8, s, ".byte ")) 1 else if (std.mem.startsWith(u8, s, ".word ")) 2 else return null;
    var fields = std.mem.splitScalar(u8, s[6..], ',');
    var count: u32 = 0;
    while (fields.next()) |field| {
        const t = trim(field);
        if (machine.integer(t)) |v| {
            if (v > (if (unit == 1) @as(u32, 255) else 65535)) return null;
        } else if (t.len != 0 and (t[0] == '<' or t[0] == '>')) {
            const scalar = trim(t[1..]);
            if (machine.integer(scalar) == null and symbolic(scalar) == null) return null;
            if (defs) |known| {
                if (machine.integer(scalar) == null and valueOf(known, scalar, 0) == null) return null;
            }
        } else if (unit != 2 or symbolic(t) == null) return null;
        if (defs) |known| {
            if (t.len > 0 and t[0] != '<' and t[0] != '>' and valueOf(known, t, 0) == null) return null;
        }
        count = std.math.add(u32, count, unit) catch return null;
    }
    return count;
}
// Conservative address upper bounds, not a second assembler. Unknown data/layout
// declines the pass; no persistent scope is guessed from a later literal origin. This proves deleted
// absolute operands still denote representable16-bit addresses in original text.
fn collectDefinitions(a: std.mem.Allocator, analysis: layout.Analysis) !?Definitions {
    return collectDefinitionsWithPadding(a, analysis, false);
}

fn multiplyPadding(lines: []const []const u8, index: usize) ?Padding {
    const before = [_][]const u8{
        "zeropage_mul16:",
        "lda #0",
        "sta zeropage_mul_result",
        "sta zeropage_mul_result+1",
        "ldx #16",
        "; The 36-byte loop's branch PC must not cross the page either.",
    };
    const after = [_][]const u8{
        ".if (* & $ff) > $db",
        "jmp zeropage_mul16_loop",
        ".if (* & $ff) > $db",
        ".fill (($100 - (* & $ff)) & $ff),0",
        ".endif",
        ".endif",
        "zeropage_mul16_loop:",
    };
    if (index < before.len or lines.len - index < after.len) return null;
    for (lines[index - before.len .. index], before) |line, expected| {
        if (!std.mem.eql(u8, trim(line), expected)) return null;
    }
    for (lines[index..][0..after.len], after) |line, expected| {
        if (!std.mem.eql(u8, trim(line), expected)) return null;
    }
    return .{ .start = index, .end = index + after.len - 1 };
}

fn collectDefinitionsWithPadding(a: std.mem.Allocator, analysis: layout.Analysis, allow_padding: bool) !?Definitions {
    var defs: std.ArrayList(Definition) = .empty;
    errdefer defs.deinit(a);
    var upper: ?u32 = null;
    var origin: u32 = 65536;
    var image_start: u32 = 65536;
    var image_end: u32 = 0;
    var node_index: usize = 0;
    var code_started = false;
    var padding: ?Padding = null;
    for (analysis.raw.items, 0..) |raw, index| {
        if (padding) |span| {
            if (index < span.end) continue;
        }
        const s = trim(raw);
        if (s.len == 0 or s[0] == ';') continue;
        while (node_index < analysis.nodes.items.len and analysis.nodes.items[node_index].index < index) : (node_index += 1) {}
        const zone = if (node_index < analysis.nodes.items.len and analysis.nodes.items[node_index].index == index) analysis.nodes.items[node_index].zone else layout.Zone.unsectioned;
        // Location-dependent assembly conditionals can change unrelated emitted
        // bytes when code shrinks. No generic preprocessor proof is implied.
        if (std.mem.startsWith(u8, s, ".if ") or std.mem.eql(u8, s, ".else") or std.mem.eql(u8, s, ".endif")) {
            if (allow_padding and padding == null and zone == .unsectioned and upper != null and upper.? <= 65536 - 36) {
                if (multiplyPadding(analysis.raw.items, index)) |span| {
                    padding = span;
                    // At $dc through $fc the jump and fill occupy at most
                    // 36 bytes. At $fd through $ff only the jump is emitted.
                    upper = upper.? + 36;
                    image_end = @max(image_end, upper.?);
                    continue;
                }
            }
            defs.deinit(a);
            return null;
        }
        if (std.mem.startsWith(u8, s, "* = ")) {
            // Basic preamble origins are allowed before code. Once code starts,
            // an origin can physically overlay another retained named entry.
            if (code_started) {
                defs.deinit(a);
                return null;
            }
            const v = machine.integer(trim(s[4..])) orelse 65536;
            if (v > 65535 or (upper != null and v < upper.?)) {
                defs.deinit(a);
                return null;
            }
            origin = v;
            upper = v;
            image_start = @min(image_start, v);
            continue;
        }
        if (zone == .code) code_started = true;
        if (layout.label(s)) |name| {
            try defs.append(a, .{ .name = name, .address = if (upper) |v| .{ .lower = origin, .upper = v } else null });
            continue;
        }
        if (std.mem.indexOfScalar(u8, s, '=')) |eq| {
            const name = trim(s[0..eq]);
            if (identifier(name)) {
                const alias = trim(s[eq + 1 ..]);
                // A tuple/list equate can expand a .byte/.word operand into
                // many bytes. Only known scalar expression shapes are bounded.
                if (!scalarExpression(alias)) {
                    defs.deinit(a);
                    return null;
                }
                try defs.append(a, .{ .name = name, .alias = alias });
                continue;
            }
        }
        const width = if (machine.Instruction.parse(s) != null) 3 else dataWidth(s, null) orelse {
            // Unknown directives may establish persistent logical/virtual/
            // encoding scopes; a later literal origin is not a proof reset.
            defs.deinit(a);
            return null;
        };
        if (upper == null or width > 65536 - upper.?) {
            defs.deinit(a);
            return null;
        }
        upper = upper.? + width;
        image_end = @max(image_end, upper.?);
    }
    return .{ .items = try defs.toOwnedSlice(a), .image_start = image_start, .image_end = image_end, .padding = padding };
}

/// Upper bound on the complete resident image, including all late data.
/// Reject layouts whose directives or origins cannot be bounded here.
pub fn residentUpperBound(a: std.mem.Allocator, assembly: []const u8) !?u32 {
    var analysis = try layout.parse(a, assembly);
    defer analysis.deinit(a);
    return imageEnd(a, analysis);
}

/// Conservative resident bound for a consumer with independent source and
/// access proofs. Unlike branch rewriting this query only needs layout size.
pub fn residentLayoutUpperBound(a: std.mem.Allocator, assembly: []const u8) !?u32 {
    var analysis = try layout.parseForSize(a, assembly);
    defer analysis.deinit(a);
    return imageEnd(a, analysis);
}

/// A byte footprint relative to a named label. For an indexed read or store
/// that can cross a page, the 6502 can also read up to 255 bytes below base.
pub const Footprint = struct {
    label: []const u8,
    first: i32 = 0,
    last: i32 = 0,

    pub fn indexed(label: []const u8, maximum: u8, may_cross_page: bool) Footprint {
        return .{ .label = label, .first = if (may_cross_page and maximum != 0) -255 else 0, .last = maximum };
    }
};

/// Prove separation using the minimum number of bytes between two labels.
/// The containing image still needs its own ordinary-memory and no-wrap
/// proof. Unknown directives, origins and alternative mappings in the
/// span make the separation unknown.
pub fn footprintsDisjoint(analysis: layout.Analysis, left: Footprint, right: Footprint) bool {
    if (!analysis.complete or left.first > left.last or right.first > right.last) return false;
    const a = analysis.target(left.label) orelse return false;
    const b = analysis.target(right.label) orelse return false;
    if (a == b) return left.last < right.first or right.last < left.first;
    const first, const last, const earlier, const later = if (a < b)
        .{ a, b, left, right }
    else
        .{ b, a, right, left };
    var distance: i64 = 0;
    for (analysis.nodes.items[first + 1 .. last]) |node| {
        if (layout.label(node.text) != null) continue;
        if (machine.Instruction.parse(node.text)) |inst| {
            distance += switch (inst.op) {
                .jmp, .jsr => 3,
                else => if (layout.conditional(inst.op) or inst.operand != .none) @as(i64, 2) else 1,
            };
        } else {
            // A location-dependent fill can have width zero. Decline any
            // directive here except known fixed-width scalar data.
            if (std.mem.indexOfScalar(u8, node.text, '=')) |eq| {
                if (identifier(trim(node.text[0..eq])) and scalarExpression(node.text[eq + 1 ..])) continue;
            }
            if (!std.mem.startsWith(u8, node.text, ".byte ") and
                !std.mem.startsWith(u8, node.text, ".word ") and
                !std.mem.startsWith(u8, node.text, ".text ")) return false;
            distance += dataWidth(node.text, null) orelse return false;
        }
    }
    return earlier.last < distance + later.first;
}

fn imageEnd(a: std.mem.Allocator, analysis: layout.Analysis) !?u32 {
    if (!analysis.complete) return null;
    const defs = (try collectDefinitions(a, analysis)) orelse return null;
    defer a.free(defs.items);
    return defs.image_end;
}
fn controlsRepresentable(analysis: layout.Analysis, defs: []const Definition) bool {
    for (analysis.nodes.items, 0..) |node, index| {
        const inst = machine.Instruction.parse(node.text) orelse continue;
        if (inst.op != .jmp and inst.op != .jsr and !layout.conditional(inst.op)) continue;
        if (inst.operand != .direct) return false;
        const ref = inst.operand.direct;
        if (valueOf(defs, ref.name, 0) == null) return false;
        if (!layout.conditional(inst.op)) continue;
        const target = analysis.target(ref.name) orelse return false;
        if (node.scope != analysis.nodes.items[target].scope) return false;
        // Check every original conditional, including dead ones, so deleting a
        // valid instruction cannot silently repair a pre-existing range error.
        if (target > index) {
            const span = analysis.maxBytes(index + 1, target) orelse return false;
            if (span > 127) return false;
        } else {
            const span = analysis.maxBytes(target, index) orelse return false;
            if (span > 126) return false;
        }
    }
    return true;
}
fn tokenPresent(text: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (!std.ascii.isAlphanumeric(text[i]) and text[i] != '_') {
            i += 1;
            continue;
        }
        const first = i;
        while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) : (i += 1) {}
        if (std.ascii.eqlIgnoreCase(text[first..i], name)) return true;
    }
    return false;
}
// branch_layout protects named CODE sections. Compiler runtime helpers can also
// be unsectioned; a code-pointer/data observer of those entries must pin this
// pass too, even though every entry label itself would remain present.
fn helperCodeObserved(analysis: layout.Analysis) bool {
    for (analysis.nodes.items) |node| {
        const inst = machine.Instruction.parse(node.text) orelse continue;
        if (inst.op != .jmp and inst.op != .jsr and !layout.conditional(inst.op)) continue;
        const name = inst.operand.direct.name;
        const target = analysis.target(name) orelse return true;
        if (analysis.nodes.items[target].zone != .unsectioned) continue;
        for (analysis.nodes.items) |observer| {
            if (layout.label(observer.text) != null) continue;
            if (machine.Instruction.parse(observer.text)) |control| {
                if (control.op == .jmp or control.op == .jsr or layout.conditional(control.op)) continue;
            }
            if (tokenPresent(observer.text, name)) return true;
        }
    }
    return false;
}
const MemoryMode = enum { direct, x, y, indirect_x, indirect_y };
fn memoryAllowed(op: machine.Op, mode: MemoryMode, base: Value, forced: bool) bool {
    return switch (op) {
        .lda, .sta, .adc, .sbc, .@"and", .ora, .eor, .cmp => true,
        .ldx => mode == .direct or mode == .y,
        .ldy => mode == .direct or mode == .x,
        .stx => mode == .direct or (mode == .y and base.upper <= 255 and !forced),
        .sty => mode == .direct or (mode == .x and base.upper <= 255 and !forced),
        .inc, .dec => mode == .direct or mode == .x,
        .asl, .lsr, .rol, .ror => mode == .direct or mode == .x,
        .bit, .cpx, .cpy => mode == .direct,
        else => false,
    };
}
fn immediateAllowed(op: machine.Op) bool {
    return switch (op) {
        .lda, .ldx, .ldy, .adc, .sbc, .@"and", .ora, .eor, .cmp, .cpx, .cpy => true,
        else => false,
    };
}
fn impliedAllowed(op: machine.Op) bool {
    return switch (op) {
        .tax, .txa, .tay, .tya, .tsx, .txs, .inx, .dex, .iny, .dey, .pha, .pla, .php, .plp, .clc, .sec, .cli, .sei, .cld, .sed, .clv, .nop, .rts, .asl, .lsr, .rol, .ror => true,
        else => false,
    };
}
const FixedAccess = struct { base: u32, additional: u32 = 0 };
const stack_access: FixedAccess = .{ .base = 0x100, .additional = 255 };
const InstructionProof = struct {
    width: usize,
    access: ?FixedAccess = null,
};

fn instructionProof(node: layout.Line, analysis: layout.Analysis, defs: []const Definition) ?InstructionProof {
    const inst = machine.Instruction.parse(node.text) orelse return null;
    const split = std.mem.indexOfAny(u8, node.text, " \t") orelse node.text.len;
    var operand = trim(node.text[split..]);
    if (std.mem.indexOfScalar(u8, operand, ';') != null or std.mem.indexOfScalar(u8, operand, ':') != null) return null;
    if (inst.op == .jmp or inst.op == .jsr or layout.conditional(inst.op)) {
        if (!identifier(operand) or analysis.target(operand) == null or valueOf(defs, operand, 0) == null) return null;
        return .{ .width = if (layout.conditional(inst.op)) 2 else 3, .access = if (inst.op == .jsr) stack_access else null };
    }
    if (operand.len == 0) {
        if (!impliedAllowed(inst.op)) return null;
        const access = switch (inst.op) {
            .rts, .pha, .pla, .php, .plp => stack_access,
            else => null,
        };
        return .{ .width = 1, .access = access };
    }
    if (operand[0] == '#') {
        if (!immediateAllowed(inst.op)) return null;
        const literal = operand[1..];
        if (machine.integer(literal)) |v| return if (v <= 255) .{ .width = 2 } else null;
        if (literal.len <= 1 or (literal[0] != '<' and literal[0] != '>')) return null;
        const value = valueOf(defs, literal[1..], 0) orelse return null;
        return .{ .width = 2, .access = if (value.fixed) .{ .base = value.lower } else null };
    }
    var forced = false;
    if (std.mem.startsWith(u8, operand, "@w ")) {
        forced = true;
        operand = trim(operand[3..]);
    }
    if (std.mem.startsWith(u8, operand, "@w")) return null;
    if (std.mem.eql(u8, operand, "a") and definition(defs, "a") == null and !forced) {
        return switch (inst.op) {
            .asl, .lsr, .rol, .ror => .{ .width = 1 },
            else => null,
        };
    }
    if (operand.len > 0 and operand[0] == '(') {
        if (forced) return null;
        var base_text: []const u8 = undefined;
        const mode: MemoryMode = if (std.mem.endsWith(u8, operand, "),y")) blk: {
            base_text = operand[1 .. operand.len - 3];
            break :blk .indirect_y;
        } else if (std.mem.endsWith(u8, operand, ",x)")) blk: {
            base_text = operand[1 .. operand.len - 3];
            break :blk .indirect_x;
        } else return null;
        if (!identifier(base_text) and machine.integer(base_text) == null) return null;
        const base = valueOf(defs, base_text, 0) orelse return null;
        if (base.upper > 255 or !memoryAllowed(inst.op, mode, base, false)) return null;
        return .{ .width = 2, .access = .{ .base = 0, .additional = 255 } };
    }
    var mode: MemoryMode = .direct;
    var base_text = operand;
    if (std.mem.indexOfScalar(u8, operand, ',')) |comma| {
        base_text = trim(operand[0..comma]);
        const register = trim(operand[comma + 1 ..]);
        mode = if (std.mem.eql(u8, register, "x")) .x else if (std.mem.eql(u8, register, "y")) .y else return null;
    }
    const base = valueOf(defs, base_text, 0) orelse return null;
    if (!memoryAllowed(inst.op, mode, base, forced)) return null;
    // An unforced indexed instruction must not switch to zero-page wrapping.
    if (mode != .direct and !forced and base.lower <= 255 and base.upper > 255) return null;
    // 64tass encodes a bare byte literal in zero page when the opcode
    // has that indexed mode. Absolute-only Y modes and @w can hit page 1.
    const literal_wraps = mode != .direct and !forced and base.upper <= 255 and
        machine.integer(base_text) != null and (mode == .x or inst.op == .ldx or inst.op == .stx);
    const access: ?FixedAccess = if (!base.fixed) null else if (mode == .direct) .{ .base = base.lower } else if (base.upper <= 255 and !forced)
        .{ .base = 0, .additional = if (literal_wraps) 255 else 255 + base.upper }
    else
        .{ .base = base.lower, .additional = 255 };
    return .{ .width = 3, .access = access };
}

fn operandDecline(analysis: layout.Analysis, defs: Definitions, protect_stack: bool) Decline {
    for (defs.items) |def| {
        if (def.alias) |alias| {
            if (valueOf(defs.items, alias, 0) == null) return .unproven_layout;
        }
    }
    for (analysis.nodes.items) |node| {
        if (machine.Instruction.parse(node.text)) |inst| {
            const proof = instructionProof(node, analysis, defs.items) orelse return .unproven_layout;
            if (proof.access) |access| {
                if (defs.observesImage(access.base, access.additional)) return .code_observer;
                // Ordinary pushes, pulls, calls and returns have their own
                // stack discipline. Explicit accesses can observe a spill.
                if (protect_stack and inst.effects().memory != .stack and inst.op != .jsr and inst.op != .rts and
                    access.base <= 0x1ff and access.base + access.additional >= 0x100) return .code_observer;
            }
        } else if (std.mem.startsWith(u8, node.text, ".byte ") or std.mem.startsWith(u8, node.text, ".word ")) {
            if (dataWidth(node.text, defs.items) == null) return .unproven_layout;
        }
    }
    return .none;
}
// Ordinary compiler CODE regions have no implicit fallthrough into data or
// opaque unsectioned bytes. Every final named block must terminate explicitly.
fn codeSectionsClosed(analysis: layout.Analysis, defs: []const Definition) bool {
    var active: ?usize = null;
    var terminated = false;
    for (analysis.nodes.items) |node| {
        if (active != null and (node.zone != .code or node.scope != active.?)) {
            if (!terminated) return false;
            active = null;
        }
        if (node.zone != .code) continue;
        if (active == null) {
            active = node.scope;
            terminated = false;
        }
        if (layout.label(node.text) != null) {
            terminated = false;
            continue;
        }
        const inst = machine.Instruction.parse(node.text) orelse return false;
        if (!terminated and (inst.op == .rts or inst.op == .jmp) and instructionProof(node, analysis, defs) != null) terminated = true;
    }
    return active == null or terminated;
}
fn definitionLessThan(_: void, lhs: Definition, rhs: Definition) bool {
    return std.ascii.lessThanIgnoreCase(lhs.name, rhs.name);
}

fn uniqueDefinitions(defs: []Definition) bool {
    std.mem.sort(Definition, defs, {}, definitionLessThan);
    for (1..defs.len) |i| {
        if (std.ascii.eqlIgnoreCase(defs[i - 1].name, defs[i].name)) return false;
    }
    return true;
}

/// Check whether a local shortening may move code and data addresses.
/// The caller proves each edited window's entries, exits and branch spans.
pub fn permitsLocalShrink(a: std.mem.Allocator, analysis: layout.Analysis, program: ast.Program) !bool {
    return permitsLocalRewrite(a, analysis, program, false);
}

pub fn permitsPrivateStackRewrite(a: std.mem.Allocator, analysis: layout.Analysis, program: ast.Program) !bool {
    return permitsLocalRewrite(a, analysis, program, true);
}

fn permitsLocalRewrite(a: std.mem.Allocator, analysis: layout.Analysis, program: ast.Program, protect_stack: bool) !bool {
    if (!try layout.controlsUnobserved(a, analysis)) return false;
    const defs = (try collectDefinitions(a, analysis)) orelse return false;
    defer a.free(defs.items);
    return permitsBoundedRewrite(a, analysis, program, defs, protect_stack);
}

pub const TailCallLayout = struct { padding_end: usize = 0 };

/// Model the multiply padding as a fallthrough to its loop. With padding
/// enabled the emitted JMP has the same destination. A caller must retain
/// instruction widths before this block to keep its assembler PC constant.
pub fn tailCallLayout(a: std.mem.Allocator, analysis: layout.Analysis, program: ast.Program) !?TailCallLayout {
    return paddedMultiplyLayout(a, analysis, program, true, 0);
}

pub fn permitsMultiplyGrowth(a: std.mem.Allocator, analysis: layout.Analysis, program: ast.Program, growth: u32) !bool {
    return (try paddedMultiplyLayout(a, analysis, program, false, growth)) != null;
}

fn paddedMultiplyLayout(a: std.mem.Allocator, analysis: layout.Analysis, program: ast.Program, protect_stack: bool, growth: u32) !?TailCallLayout {
    var defs = (try collectDefinitionsWithPadding(a, analysis, true)) orelse return null;
    defer a.free(defs.items);
    if (growth != 0) {
        if (defs.padding == null or growth > 65536 - defs.image_end) return null;
        defs.image_end += growth;
        if (defs.image_end > program.zeropage_options.image.address_limit) return null;
        for (defs.items) |*def| {
            if (def.address) |*address| address.upper += growth;
        }
    }
    var graph = analysis;
    var nodes: std.ArrayList(layout.Line) = .empty;
    defer nodes.deinit(a);
    if (defs.padding) |span| {
        for (analysis.nodes.items) |node| {
            if (node.index < span.start or node.index >= span.end) try nodes.append(a, node);
        }
        graph.nodes = nodes;
    }
    if (!try layout.controlsUnobserved(a, graph) or !try permitsBoundedRewrite(a, graph, program, defs, protect_stack)) return null;
    return .{ .padding_end = if (defs.padding) |span| span.end else 0 };
}

fn permitsBoundedRewrite(a: std.mem.Allocator, analysis: layout.Analysis, program: ast.Program, defs: Definitions, protect_stack: bool) !bool {
    const image = placement_domains.ImageRange{ .start = defs.image_start, .end = defs.image_end };
    if (!((image.start >= 0x0200 and image.end <= 0x8000) or
        (image.start >= 0xc000 and image.end <= 0xd000))) return false;
    if (defs.items.len == 0 or !uniqueDefinitions(defs.items) or operandDecline(analysis, defs, protect_stack) != .none or helperCodeObserved(analysis)) return false;
    if (try placement_domains.observesMovableImage(a, program, image)) return false;
    return !protect_stack or !try placement_domains.observesMovableImage(a, program, .{ .start = 0x100, .end = 0x200 });
}

const FunctionGraph = struct {
    analyzed_scope: []bool,
    reachable: []bool,
    redundant_jumps: []bool,

    fn deinit(self: FunctionGraph, a: std.mem.Allocator) void {
        a.free(self.redundant_jumps);
        a.free(self.reachable);
        a.free(self.analyzed_scope);
    }

    fn covers(self: FunctionGraph, scope: usize) bool {
        return scope < self.analyzed_scope.len and self.analyzed_scope[scope];
    }

    fn seed(self: FunctionGraph, a: std.mem.Allocator, work: *std.ArrayList(usize), index: usize) !void {
        if (self.reachable[index]) return;
        self.reachable[index] = true;
        try work.append(a, index);
    }
};

// The validated assembly marks scope boundaries. A graph is only enabled for a
// function scope whose first actual node names the same declared source entry.
// Other CODE sections keep the R43 all-labels-are-entries policy.
fn sourceFunctionScope(text: []const u8, first: layout.Line, scope: usize, program: ast.Program) bool {
    if (first.scope != scope or first.zone != .code) return false;
    const entry = layout.label(first.text) orelse return false;
    var fields = std.mem.tokenizeAny(u8, text, " \t");
    while (fields.next()) |field| {
        const prefix = "owner=function:";
        if (!std.mem.startsWith(u8, field, prefix)) continue;
        const owner = field[prefix.len..];
        return std.mem.eql(u8, owner, entry) and program.findFunction(owner) != null;
    }
    return false;
}

fn functionGraph(a: std.mem.Allocator, analysis: layout.Analysis, program: ast.Program) !FunctionGraph {
    const nodes = analysis.nodes.items;
    const analyzed_scope = try a.alloc(bool, analysis.raw.items.len + 1);
    errdefer a.free(analyzed_scope);
    @memset(analyzed_scope, false);
    const reachable = try a.alloc(bool, nodes.len);
    errdefer a.free(reachable);
    @memset(reachable, false);
    const redundant_jumps = try a.alloc(bool, nodes.len);
    errdefer a.free(redundant_jumps);
    @memset(redundant_jumps, false);
    const graph: FunctionGraph = .{ .analyzed_scope = analyzed_scope, .reachable = reachable, .redundant_jumps = redundant_jumps };
    var work: std.ArrayList(usize) = .empty;
    defer work.deinit(a);
    var scope: usize = 0;
    var first: usize = 0;
    for (analysis.raw.items, 0..) |raw, index| {
        const text = trim(raw);
        if (!std.mem.startsWith(u8, text, "; zeropage_section_begin ")) continue;
        scope += 1;
        while (first < nodes.len and nodes[first].index < index) : (first += 1) {}
        if (first == nodes.len) break;
        if (!sourceFunctionScope(text, nodes[first], scope, program)) continue;
        analyzed_scope[scope] = true;
        try graph.seed(a, &work, first);
    }
    // Include every incoming transfer from outside the function scope, even
    // when the origin is itself dead or belongs to opaque runtime ownership.
    // Edges internal to a covered scope are followed only from live nodes.
    const targets = try a.alloc(?usize, nodes.len);
    defer a.free(targets);
    @memset(targets, null);
    for (nodes, 0..) |node, index| {
        const inst = machine.Instruction.parse(node.text) orelse continue;
        if (inst.op != .jmp and inst.op != .jsr and !layout.conditional(inst.op)) continue;
        const target = analysis.target(inst.operand.direct.name).?; // already validated
        if (!graph.covers(nodes[target].scope)) continue;
        if (node.scope == nodes[target].scope) targets[index] = target else try graph.seed(a, &work, target);
    }
    while (work.pop()) |index| {
        const node = nodes[index];
        const inst = machine.Instruction.parse(node.text);
        if (targets[index]) |target| try graph.seed(a, &work, target);
        if (inst) |op| if (op.op == .rts or op.op == .jmp) continue;
        const next = index + 1;
        // The original section-closure proof rules out live fallthrough out of
        // the section. Leave boundaries untouched even for synthetic inputs.
        if (next < nodes.len and nodes[next].scope == node.scope) try graph.seed(a, &work, next);
    }
    // A live direct JMP can fall through when every preceding node between
    // the branch and its forward label emits no retained instruction. A chain
    // of such rewrites always advances, even if the target is itself a JMP.
    for (nodes, 0..) |node, index| {
        if (!reachable[index]) continue;
        const target = targets[index] orelse continue;
        if (target <= index) continue;
        const inst = machine.Instruction.parse(node.text) orelse continue;
        if (inst.op != .jmp) continue;
        for (index + 1..target) |between| {
            if (reachable[between] and layout.label(nodes[between].text) == null) break;
        } else redundant_jumps[index] = true;
    }
    return graph;
}

/// Borrow source and own the result. The assembly-only path roots all labels.
/// The typed path also follows internal edges from declared source entries and
/// incoming external targets. Labels, comments, data and sections survive.
/// Run after placement and before the final monotonic short-branch pass.
pub fn rewrite(a: std.mem.Allocator, assembly: []const u8) !Result {
    return rewriteProgram(a, assembly, null);
}

pub fn rewriteProgram(a: std.mem.Allocator, assembly: []const u8, program: ?ast.Program) !Result {
    var analysis = try layout.parse(a, assembly);
    defer analysis.deinit(a);
    if (!analysis.complete) return .{ .assembly = try a.dupe(u8, assembly), .stats = .{ .declined = .unproven_program } };
    const defs = (try collectDefinitions(a, analysis)) orelse return .{ .assembly = try a.dupe(u8, assembly), .stats = .{ .declined = .unproven_layout } };
    defer a.free(defs.items);
    if (!controlsRepresentable(analysis, defs.items) or !codeSectionsClosed(analysis, defs.items)) return .{ .assembly = try a.dupe(u8, assembly), .stats = .{ .declined = .unproven_control } };
    const decline = operandDecline(analysis, defs, false);
    if (decline != .none) return .{ .assembly = try a.dupe(u8, assembly), .stats = .{ .declined = decline } };
    if (helperCodeObserved(analysis)) return .{ .assembly = try a.dupe(u8, assembly), .stats = .{ .declined = .code_observer } };
    const graph: ?FunctionGraph = if (program) |source|
        if (defs.items.len != 0 and uniqueDefinitions(defs.items)) try functionGraph(a, analysis, source) else null
    else
        null;
    defer if (graph) |g| g.deinit(a);
    const removed = try a.alloc(bool, analysis.raw.items.len);
    defer a.free(removed);
    @memset(removed, false);
    var terminated = false;
    var prior_scope: ?usize = null;
    var in_run = false;
    var stats: Stats = .{};
    for (analysis.nodes.items, 0..) |node, index| {
        if (node.zone != .code or prior_scope == null or prior_scope.? != node.scope) {
            terminated = false;
            in_run = false;
        }
        prior_scope = node.scope;
        if (node.zone != .code) continue;
        if (layout.label(node.text) != null) {
            terminated = false;
            in_run = false;
            continue;
        }
        const inst = machine.Instruction.parse(node.text) orelse continue;
        const reachable = if (graph) |g| (if (g.covers(node.scope)) g.reachable[index] else !terminated) else !terminated;
        const redundant_jump = if (graph) |g| g.redundant_jumps[index] else false;
        if (!reachable or redundant_jump) {
            if (instructionProof(node, analysis, defs.items)) |proof| {
                removed[node.index] = true;
                stats.instructions_removed += 1;
                if (redundant_jump) stats.fallthrough_jumps_removed += 1 else if (!terminated) stats.labeled_instructions_removed += 1;
                stats.bytes_removed_upper += proof.width;
                if (inst.op == .rts) stats.rts_removed += 1;
                if (inst.op == .jmp) stats.jumps_removed += 1;
                if (!in_run) {
                    stats.runs_removed += 1;
                    in_run = true;
                }
            } else in_run = false;
        } else {
            // Do not use malformed RTS/JMP syntax as a reachability proof.
            if ((inst.op == .rts or inst.op == .jmp) and instructionProof(node, analysis, defs.items) != null) terminated = true;
        }
    }
    if (stats.instructions_removed == 0) return .{ .assembly = try a.dupe(u8, assembly), .stats = stats };
    if (program) |source| {
        const image: placement_domains.ImageRange = .{ .start = defs.image_start, .end = defs.image_end };
        if (try placement_domains.observesMovableImage(a, source, image)) {
            return .{ .assembly = try a.dupe(u8, assembly), .stats = .{ .declined = .code_observer } };
        }
    }
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    for (analysis.raw.items, 0..) |raw, index| {
        if (removed[index]) continue;
        try out.writer.writeAll(raw);
        if (index + 1 < analysis.raw.items.len) try out.writer.writeByte('\n');
    }
    return .{ .assembly = try out.toOwnedSlice(), .stats = stats };
}

const sample =
    \\* = $2000
    \\; zeropage_section_begin owner=function:f kind=code lifetime=static address=near
    \\f:
    \\    lda #7
    \\    rts
    \\; retained provenance
    \\    lda #9
    \\    sta f_value
    \\    sec
    \\    jmp done
    \\    rts
    \\done:
    \\    rts
    \\; zeropage_section_end owner=function:f kind=code
    \\; zeropage_section_begin owner=function:f kind=static_frame lifetime=static address=near
    \\f_value:
    \\    .byte 0
    \\; zeropage_section_end owner=function:f kind=static_frame
    \\
;
test "unreachable cleanup removes complete valid runs after RTS and preserves every label" {
    const r = try rewrite(std.testing.allocator, sample);
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expectEqual(@as(usize, 5), r.stats.instructions_removed);
    try std.testing.expect(std.mem.indexOf(u8, r.assembly, "; retained provenance\ndone:") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, r.assembly, "    rts\n"));
    try std.testing.expect(std.mem.indexOf(u8, r.assembly, "f_value:\n    .byte 0") != null);
}
test "unreachable cleanup preserves alternate named entries and co-located aliases" {
    const text = try std.mem.replaceOwned(u8, std.testing.allocator, sample, "    lda #9", "entry:\nalias_entry:\n    lda #9");
    defer std.testing.allocator.free(text);
    const r = try rewrite(std.testing.allocator, text);
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expectEqual(@as(usize, 1), r.stats.instructions_removed);
    try std.testing.expect(std.mem.indexOf(u8, r.assembly, "entry:\nalias_entry:\n    lda #9") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.assembly, "jmp done") != null);
}
test "unreachable cleanup gates opaque controls code observers and architecture" {
    for ([_][]const u8{ "\njsr $ffd2\n", "\njmp (ptr)\n", "\n.word f+1\n", "\n.cpu \"65816\"\n", "\n; inline asm from ZeroPage\nnop\n; end inline asm\n" }) |extra| {
        const text = try std.mem.concat(std.testing.allocator, u8, &.{ sample, extra });
        defer std.testing.allocator.free(text);
        const r = try rewrite(std.testing.allocator, text);
        defer std.testing.allocator.free(r.assembly);
        try std.testing.expectEqualStrings(text, r.assembly);
    }
}

test "unreachable cleanup also protects observed unsectioned helper code entries" {
    const text = try std.mem.concat(std.testing.allocator, u8, &.{ sample, "\njsr helper\nhelper:\n    rts\nobserved:\n    .word helper\n" });
    defer std.testing.allocator.free(text);
    const r = try rewrite(std.testing.allocator, text);
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expectEqualStrings(text, r.assembly);
}
test "unreachable cleanup never erases invalid operands or undefined symbols" {
    for ([_][]const u8{ "sta #1", "lda #256", "lda missing", "lda #<missing", "stx f_value,x", "ldx (ptr),y", "pha #0", "rts #0", "stx @w zp,y" }) |bad| {
        const text = try std.mem.replaceOwned(u8, std.testing.allocator, sample, "    lda #9", bad);
        defer std.testing.allocator.free(text);
        const r = try rewrite(std.testing.allocator, text);
        defer std.testing.allocator.free(r.assembly);
        try std.testing.expect(std.mem.indexOf(u8, r.assembly, bad) != null);
    }
}
test "unreachable cleanup does not use invalid terminating modes as reachability proof" {
    const text = "* = $2000\n; zeropage_section_begin owner=function:f kind=code\nf:\n    rts #0\n    lda #7\n    rts\n; zeropage_section_end owner=function:f kind=code\n";
    const r = try rewrite(std.testing.allocator, text);
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expectEqualStrings(text, r.assembly);
}
test "unreachable cleanup validates every original conditional range before deleting any bytes" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.writeAll("* = $2000\n; zeropage_section_begin owner=function:f kind=code\nf:\n    bcc far\n    rts\n    rts\n");
    for (0..126) |_| try out.writer.writeAll("    nop\n");
    try out.writer.writeAll("far:\n    rts\n; zeropage_section_end owner=function:f kind=code\n");
    const r = try rewrite(std.testing.allocator, out.written());
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expectEqualStrings(out.written(), r.assembly);
}
test "unreachable cleanup keeps memory instructions exact until proved unreachable" {
    const text = "* = $2000\n; zeropage_section_begin owner=function:f kind=code\nf:\n    lda $dc04\n    sta $c100\n    rts\n    lda $dc04\n    sta $c100\n    rts\n; zeropage_section_end owner=function:f kind=code\n";
    const r = try rewrite(std.testing.allocator, text);
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expectEqual(@as(usize, 3), r.stats.instructions_removed);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.assembly, "lda $dc04"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.assembly, "sta $c100"));
}
test "unreachable cleanup allows canonical exact ZP aliases and terminal indirect modes" {
    const text = "* = $2000\n; zeropage_section_begin owner=function:f kind=code\nf:\n    rts\n    lda (ptr),y\n    sta slot+1\n    ldx #7\n    stx zp,y\n    asl a\n    rts\n; zeropage_section_end owner=function:f kind=code\nptr = address($fb)\nslot = address($20)\nzp = $02\n";
    const r = try rewrite(std.testing.allocator, text);
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expectEqual(@as(usize, 6), r.stats.instructions_removed);
    try std.testing.expect(std.mem.indexOf(u8, r.assembly, "slot = address($20)") != null);
}
test "unreachable cleanup validates named A as memory instead of assuming accumulator" {
    const text = "* = $2000\n; zeropage_section_begin owner=function:f kind=code\nf:\n    rts\n    lda a\n    asl a\n    rts\n; zeropage_section_end owner=function:f kind=code\na = $c100\n";
    const r = try rewrite(std.testing.allocator, text);
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expectEqual(@as(usize, 3), r.stats.instructions_removed);
    try std.testing.expectEqual(@as(usize, 7), r.stats.bytes_removed_upper);
}
test "unreachable cleanup does not infer labels from alias expressions or unknown address domains" {
    for ([_][]const u8{ "* = $10000", ".logical $2000", "*=$2000" }) |origin| {
        const text = try std.mem.replaceOwned(u8, std.testing.allocator, sample, "* = $2000", origin);
        defer std.testing.allocator.free(text);
        const r = try rewrite(std.testing.allocator, text);
        defer std.testing.allocator.free(r.assembly);
        try std.testing.expectEqualStrings(text, r.assembly);
    }
}
test "unreachable cleanup follows all eight conditional predicates without treating them as terminators" {
    for ([_][]const u8{ "bcc", "bcs", "beq", "bne", "bmi", "bpl", "bvc", "bvs" }) |op| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "* = $2000\n; zeropage_section_begin owner=function:f kind=code\nf:\n    {s} next\n    lda #7\n    rts\n    {s} next\n    lda #9\nnext:\n    rts\n; zeropage_section_end owner=function:f kind=code\n", .{ op, op });
        defer std.testing.allocator.free(text);
        const r = try rewrite(std.testing.allocator, text);
        defer std.testing.allocator.free(r.assembly);
        try std.testing.expectEqual(@as(usize, 2), r.stats.instructions_removed);
        try std.testing.expect(std.mem.indexOf(u8, r.assembly, "lda #7") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.assembly, "lda #9") == null);
    }
}
test "unreachable cleanup preserves separate code scopes and data through origin remaps" {
    const text = "* = $2000\n; zeropage_section_begin owner=function:f kind=code\nf:\n    rts\n; zeropage_section_end owner=function:f kind=code\n* = $3000\n; zeropage_section_begin owner=function:g kind=code\ng:\n    lda #7\n    rts\n; zeropage_section_end owner=function:g kind=code\n";
    const r = try rewrite(std.testing.allocator, text);
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expectEqualStrings(text, r.assembly);
}
fn allocationProof(a: std.mem.Allocator) !void {
    const r = rewrite(a, sample) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    defer a.free(r.assembly);
    try std.testing.expectEqual(@as(usize, 5), r.stats.instructions_removed);
}
test "unreachable cleanup owns output and releases proof arrays through every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProof, .{});
}

test "unreachable cleanup rejects physical code overlap and persistent layout scopes" {
    const text = "* = $2001\n; zeropage_section_begin owner=function:g kind=code\ng:\n    lda #9\n    rts\n; zeropage_section_end owner=function:g kind=code\n* = $2000\n; zeropage_section_begin owner=function:f kind=code\nf:\n    rts\n    lda #7\n    rts\n; zeropage_section_end owner=function:f kind=code\n";
    const r = try rewrite(std.testing.allocator, text);
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expectEqualStrings(text, r.assembly);
}
test "unreachable cleanup cannot use conditional-only symbol definitions" {
    const text = "* = $2000\n.if 0\nslot:\n    .byte 0\n.endif\n; zeropage_section_begin owner=function:f kind=code\nf:\n    rts\n    lda slot\n    rts\n; zeropage_section_end owner=function:f kind=code\n";
    const r = try rewrite(std.testing.allocator, text);
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expect(std.mem.indexOf(u8, r.assembly, "    lda slot\n") != null);
}

test "unreachable cleanup rejects location-dependent assembler conditionals globally" {
    const text = "* = $2000\n; zeropage_section_begin owner=function:f kind=code\nf:\n    rts\n    rts\n; zeropage_section_end owner=function:f kind=code\n.if * == $2002\n    .byte $aa\n.else\n    .byte $bb\n.endif\n";
    const r = try rewrite(std.testing.allocator, text);
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expectEqualStrings(text, r.assembly);
}

test "unreachable cleanup requires explicit termination before data or opaque fallthrough" {
    const text = "* = $2000\n; zeropage_section_begin owner=function:f kind=code\nf:\n    rts\n    rts\n; zeropage_section_end owner=function:f kind=code\n; zeropage_section_begin owner=function:g kind=code\ng:\n    lda #7\n; zeropage_section_end owner=function:g kind=code\nbytes:\n    .byte $60\n";
    const r = try rewrite(std.testing.allocator, text);
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expectEqualStrings(text, r.assembly);
}

test "unreachable cleanup admits compiler literal low high word table bytes" {
    const text = try std.mem.concat(std.testing.allocator, u8, &.{ sample, "\nweights:\n    .byte <10,>10,<65535,>65535\n" });
    defer std.testing.allocator.free(text);
    const r = try rewrite(std.testing.allocator, text);
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expectEqual(@as(usize, 5), r.stats.instructions_removed);
    try std.testing.expect(std.mem.indexOf(u8, r.assembly, "    .byte <10,>10,<65535,>65535\n") != null);
}
test "unreachable cleanup cannot count assembler vector aliases as scalar data" {
    const text = try std.mem.concat(std.testing.allocator, u8, &.{ sample, "\nitems = [1,2,3]\n    .word items\n" });
    defer std.testing.allocator.free(text);
    const r = try rewrite(std.testing.allocator, text);
    defer std.testing.allocator.free(r.assembly);
    try std.testing.expectEqualStrings(text, r.assembly);
}

test "unreachable cleanup preserves fixed memory observations of the loaded image" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "$2005", "fixed_address", "$1ffe,x" }) |operand| {
        const text = try std.fmt.allocPrint(a, "* = $2000\n; zeropage_section_begin owner=function:f kind=code\nf:\n    lda {s}\n    rts\n    nop\n; zeropage_section_end owner=function:f kind=code\npayload:\n    .byte $11,$22\nfixed_address = $2005\n", .{operand});
        defer a.free(text);
        const result = try rewrite(a, text);
        defer a.free(result.assembly);
        try std.testing.expectEqualStrings(text, result.assembly);
    }
}

test "unreachable cleanup keeps original address range errors visible" {
    const text = "* = $2000\n; zeropage_section_begin owner=function:f kind=code\nf:\n    lda payload+$dffb\n    rts\n    nop\n; zeropage_section_end owner=function:f kind=code\npayload:\n    .byte 1\n";
    const result = try rewrite(std.testing.allocator, text);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualStrings(text, result.assembly);
}
