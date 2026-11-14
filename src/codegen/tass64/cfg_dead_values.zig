const std = @import("std");
const ast = @import("../../ast.zig");
const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");

pub const Stats = struct { removed: usize = 0, loads_removed: usize = 0, carry_removed: usize = 0, identities_removed: usize = 0, transfers_removed: usize = 0, bytes_saved: usize = 0 };
pub const Result = struct { assembly: []u8, stats: Stats };
const Node = struct { text: []const u8, scope: usize, boundary: bool = false, instruction: ?machine.Instruction = null, label: bool = false };
const Target = struct { index: usize, scope: usize, unique: bool = true };
const Key = struct { index: usize, mask: u16 };
const Status = enum { visiting, dead };
const Frame = struct { key: Key, entered: bool = false, children: [2]Key = undefined, count: usize = 0, next: usize = 0 };
const Step = union(enum) { dead, live, children: struct { values: [2]Key, count: usize } };

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r");
}
fn labelName(text: []const u8) ?[]const u8 {
    if (text.len < 2 or text[text.len - 1] != ':') return null;
    const name = text[0 .. text.len - 1];
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return null;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return null;
    return name;
}
// These numeric byte operations preserve A and every flag except N/Z.
fn identity(instruction: machine.Instruction) bool {
    if (instruction.operand != .immediate) return false;
    const value = machine.integer(instruction.operand.immediate) orelse return false;
    return switch (instruction.op) {
        .ora, .eor => value == 0,
        .@"and" => value == 255,
        else => false,
    };
}
fn outputMask(instruction: machine.Instruction) u16 {
    return if (identity(instruction)) machine.nz else instruction.effects().writes;
}
fn registerTransfer(op: machine.Op) bool {
    return switch (op) {
        .tax, .tay, .tsx, .txa, .tya => true,
        else => false,
    };
}
fn immediateByte(instruction: machine.Instruction) ?u8 {
    if (instruction.operand != .immediate) return null;
    return std.math.cast(u8, machine.integer(instruction.operand.immediate) orelse return null);
}
fn candidate(node: Node, late: bool) ?machine.Instruction {
    if (node.scope == 0 or node.boundary) return null;
    const instruction = node.instruction orelse return null;
    switch (instruction.op) {
        .lda, .ldx, .ldy => {
            // Start with literal byte immediates, leaving address/relocation
            // expressions and unsupported assembler shapes entirely intact.
            if (immediateByte(instruction) == null) return null;
        },
        .sec, .clc => if (instruction.operand != .none) return null,
        .ora, .eor, .@"and" => if (!identity(instruction)) return null,
        else => if (!late or !registerTransfer(instruction.op) or instruction.operand != .none) return null,
    }
    return instruction;
}

const registers_mask = [_]u16{ machine.a, machine.x, machine.y };

fn byteFlags(value: u8) u16 {
    if (value == 0) return machine.z;
    return if (value & 0x80 != 0) machine.n else 0;
}

fn removeRepeatedValues(analysis: Analysis, removed: []bool, proof: *Proof, stats: *Stats) !void {
    const nodes = analysis.nodes.items;
    var registers: [registers_mask.len]?u8 = @splat(null);
    var nz: ?u16 = null;
    for (nodes, removed, 0..) |node, *drop, index| {
        if (drop.*) continue;
        if (!node.boundary and (node.text.len == 0 or node.text[0] == ';')) continue;
        const instruction = node.instruction;
        const effects = if (instruction) |inst| literalIndexedEffects(inst, node.text) orelse inst.effects() else machine.Effects{ .barrier = true };
        if (node.scope == 0 or effects.barrier) {
            registers = @splat(null);
            nz = null;
            continue;
        }
        const inst = instruction.?;
        const transfer = inst.operand == .none and registerTransfer(inst.op);
        const value = if (transfer) switch (inst.op) {
            .tax, .tay => registers[0],
            .txa => registers[1],
            .tya => registers[2],
            else => null,
        } else immediateByte(inst);
        const dest: ?usize = switch (inst.op) {
            .lda, .txa, .tya => 0,
            .ldx, .tax => 1,
            .ldy, .tay => 2,
            else => null,
        };
        if (dest != null and value != null) {
            const reg = dest.?;
            const flags = byteFlags(value.?);
            const changed = if (nz) |known| known ^ flags else machine.nz;
            if (registers[reg] == value) {
                // A backedge can revisit the instruction. Its own N/Z
                // overwrite disappears along with its register write.
                drop.* = true;
                if (changed == 0 or try proof.dead(nodes, analysis.targets, removed, .{ .index = index + 1, .mask = changed }, null)) {
                    stats.removed += 1;
                    if (transfer) {
                        stats.transfers_removed += 1;
                        stats.bytes_saved += 1;
                    } else {
                        stats.loads_removed += 1;
                        stats.bytes_saved += 2;
                    }
                    continue;
                }
                drop.* = false;
            }
            registers[reg] = value;
            nz = flags;
            continue;
        }
        for (&registers, registers_mask) |*known, mask| {
            if (effects.writes & mask != 0) known.* = null;
        }
        if (effects.writes & machine.nz != 0) nz = null;
    }
}
fn conditional(op: machine.Op) bool {
    return switch (op) {
        .bcc, .bcs, .beq, .bne, .bmi, .bpl, .bvc, .bvs => true,
        else => false,
    };
}
fn jumpTarget(nodes: []const Node, targets: std.StringHashMap(Target), index: usize, instruction: machine.Instruction) ?usize {
    if (instruction.operand != .direct or instruction.operand.direct.offset != 0) return null;
    const target = targets.get(instruction.operand.direct.name) orelse return null;
    if (!target.unique or target.scope == 0 or target.scope != nodes[index].scope) return null;
    return target.index;
}
fn literalIndexedEffects(instruction: machine.Instruction, text: []const u8) ?machine.Effects {
    if (instruction.operand != .unknown or (instruction.op != .lda and instruction.op != .sta and instruction.op != .ldx)) return null;
    const operand = layout.literalIndex(text) orelse return null;
    if (operand.address < 256 or (instruction.op == .ldx and operand.register != machine.y)) return null;
    var effects = (machine.Instruction{ .op = instruction.op, .operand = .{ .address = operand.address } }).effects();
    effects.reads |= operand.register;
    return effects;
}

fn advance(nodes: []const Node, targets: std.StringHashMap(Target), removed: []const bool, key: Key, allow_literal_index: bool, dead_at_return: u16) Step {
    if (key.mask == 0) return .dead;
    if (key.index >= nodes.len) return .live;
    const node = nodes[key.index];
    if (node.boundary or node.scope == 0) return .live;
    if (removed[key.index] or node.text.len == 0 or node.text[0] == ';' or node.label)
        return .{ .children = .{ .values = .{ .{ .index = key.index + 1, .mask = key.mask }, undefined }, .count = 1 } };
    const instruction = node.instruction orelse return .live;
    const indexed_effects = if (allow_literal_index) literalIndexedEffects(instruction, node.text) else null;
    const effects = indexed_effects orelse instruction.effects();
    // Every register/physical-flag read is checked before that instruction's
    // writes. CMP consumes A even though it kills C/N/Z, for example.
    if (effects.reads & key.mask != 0) return .live;
    if (instruction.op == .rts and key.mask & ~dead_at_return == 0) return .dead;
    if (instruction.op == .jmp or conditional(instruction.op)) {
        const target = jumpTarget(nodes, targets, key.index, instruction) orelse return .live;
        return .{ .children = .{
            .values = .{ .{ .index = target, .mask = key.mask }, .{ .index = key.index + 1, .mask = key.mask } },
            .count = if (instruction.op == .jmp) 1 else 2,
        } };
    }
    // Calls/returns, unknown addressing and status-mode barriers expose all
    // surviving outputs. Do not infer interprocedural or interrupt liveness.
    if (effects.barrier) return .live;
    const mask = key.mask & ~effects.writes;
    if (mask == 0) return .dead;
    return .{ .children = .{ .values = .{ .{ .index = key.index + 1, .mask = mask }, undefined }, .count = 1 } };
}

const Proof = struct {
    allocator: std.mem.Allocator,
    memo: std.AutoHashMap(Key, Status),
    stack: std.ArrayList(Frame) = .empty,
    allow_literal_index: bool = false,
    dead_at_return: u16 = 0,

    fn init(allocator: std.mem.Allocator) Proof {
        return .{ .allocator = allocator, .memo = .init(allocator) };
    }
    fn deinit(self: *Proof) void {
        self.memo.deinit();
        self.stack.deinit(self.allocator);
    }
    fn dead(self: *Proof, nodes: []const Node, targets: std.StringHashMap(Target), removed: []const bool, start: Key, kill_line: ?usize) !bool {
        self.memo.clearRetainingCapacity();
        self.stack.clearRetainingCapacity();
        try self.stack.append(self.allocator, .{ .key = start });
        while (self.stack.items.len != 0) {
            const frame = &self.stack.items[self.stack.items.len - 1];
            if (!frame.entered) {
                if (self.memo.get(frame.key)) |status| {
                    if (status == .visiting) return false;
                    _ = self.stack.pop();
                    continue;
                }
                const step: Step = if (frame.key.index == kill_line) .dead else advance(nodes, targets, removed, frame.key, self.allow_literal_index, self.dead_at_return);
                switch (step) {
                    .live => return false,
                    .dead => {
                        try self.memo.put(frame.key, .dead);
                        _ = self.stack.pop();
                        continue;
                    },
                    .children => |children| {
                        try self.memo.put(frame.key, .visiting);
                        frame.entered = true;
                        frame.children = children.values;
                        frame.count = children.count;
                    },
                }
            }
            if (frame.next < frame.count) {
                const child = frame.children[frame.next];
                frame.next += 1;
                try self.stack.append(self.allocator, .{ .key = child });
            } else {
                try self.memo.put(frame.key, .dead);
                _ = self.stack.pop();
            }
        }
        return true;
    }
};

// Owns the unchanged R30 parser's arrays/map; node text and map keys borrow
// the assembly buffer. Both rewrite and the read-only query share this parser.
const Analysis = struct {
    allocator: std.mem.Allocator,
    raw_lines: std.ArrayList([]const u8),
    nodes: std.ArrayList(Node),
    targets: std.StringHashMap(Target),

    fn init(allocator: std.mem.Allocator, assembly: []const u8) !Analysis {
        var raw_lines: std.ArrayList([]const u8) = .empty;
        errdefer raw_lines.deinit(allocator);
        var nodes: std.ArrayList(Node) = .empty;
        errdefer nodes.deinit(allocator);
        var targets: std.StringHashMap(Target) = .init(allocator);
        errdefer targets.deinit();
        const sectioned = std.mem.indexOf(u8, assembly, "; zeropage_section_") != null;
        var scope: usize = if (sectioned) 0 else 1;
        var scope_sequence: usize = scope;
        var split = std.mem.splitScalar(u8, assembly, '\n');
        while (split.next()) |raw| {
            const text = trim(raw);
            var node: Node = .{ .text = text, .scope = scope };
            if (std.mem.startsWith(u8, text, "; zeropage_section_")) {
                node.boundary = true;
                scope = 0;
                if (std.mem.startsWith(u8, text, "; zeropage_section_begin ")) {
                    var fields = std.mem.tokenizeScalar(u8, text, ' ');
                    while (fields.next()) |field| if (std.mem.eql(u8, field, "kind=code")) {
                        scope_sequence += 1;
                        scope = scope_sequence;
                        break;
                    };
                }
            } else if (labelName(text)) |name| {
                node.label = true;
                const entry = try targets.getOrPut(name);
                if (entry.found_existing) entry.value_ptr.unique = false else entry.value_ptr.* = .{ .index = nodes.items.len, .scope = scope };
            } else node.instruction = machine.Instruction.parse(text);
            try raw_lines.append(allocator, raw);
            try nodes.append(allocator, node);
        }
        return .{ .allocator = allocator, .raw_lines = raw_lines, .nodes = nodes, .targets = targets };
    }
    fn deinit(self: *Analysis) void {
        self.raw_lines.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.targets.deinit();
    }
};

/// Read-only liveness at the point immediately AFTER raw_line. This says
/// nothing about the anchor instruction's effects or whether it can be removed.
/// Unknown bits, ASM, invalid/unknown anchors and non-code positions decline.
/// The source remains borrowed only during this call; every remaining real
/// instruction participates (the query's removed mask is entirely false).
pub fn outputsDeadAfterLine(allocator: std.mem.Allocator, assembly: []const u8, raw_line: usize, mask: u16) !bool {
    if (std.mem.indexOf(u8, assembly, "; inline asm") != null) return false;
    var query = try OutputQuery.init(allocator, assembly);
    defer query.deinit();
    return query.deadAfterLine(raw_line, mask);
}

/// Share parsed control flow across several liveness queries. Callers can
/// close an entry to an already replaced instruction sequence so subsequent
/// proofs cannot depend on effects of the instructions it replaced.
pub const OutputQuery = struct {
    analysis: Analysis,
    removed: []bool,
    proof: Proof,

    pub fn init(allocator: std.mem.Allocator, assembly: []const u8) !OutputQuery {
        var analysis = try Analysis.init(allocator, assembly);
        errdefer analysis.deinit();
        const removed = try allocator.alloc(bool, analysis.nodes.items.len);
        @memset(removed, false);
        return .{ .analysis = analysis, .removed = removed, .proof = Proof.init(allocator) };
    }

    pub fn initWithLiteralIndex(allocator: std.mem.Allocator, assembly: []const u8) !OutputQuery {
        var query = try init(allocator, assembly);
        query.proof.allow_literal_index = true;
        return query;
    }

    pub fn deinit(self: *OutputQuery) void {
        self.proof.deinit();
        self.analysis.allocator.free(self.removed);
        self.analysis.deinit();
    }

    pub fn closeEntry(self: *OutputQuery, raw_line: usize) void {
        self.analysis.nodes.items[raw_line].boundary = true;
    }

    pub fn markRemoved(self: *OutputQuery, raw_line: usize) void {
        self.removed[raw_line] = true;
    }

    /// The caller checks the function's ABI and excludes any native observer
    /// of the specified caller-clobbered register on return.
    pub fn setDeadAtReturn(self: *OutputQuery, mask: u16) void {
        self.proof.dead_at_return = mask;
    }

    pub fn deadAfterLine(self: *OutputQuery, raw_line: usize, mask: u16) !bool {
        return self.deadAfterLineBeforeKill(raw_line, mask, null);
    }

    /// The caller proves that entry at kill_line overwrites every requested
    /// output before any observation. All paths that bypass it are checked.
    pub fn deadAfterLineBeforeKill(self: *OutputQuery, raw_line: usize, mask: u16, kill_line: ?usize) !bool {
        const nodes = self.analysis.nodes.items;
        const known = machine.a | machine.x | machine.y | machine.sp | machine.flags;
        if (mask & ~known != 0 or raw_line >= nodes.len) return false;
        const anchor = nodes[raw_line];
        if (anchor.scope == 0 or anchor.boundary or (!anchor.label and anchor.instruction == null)) return false;
        if (anchor.instruction) |instruction| {
            if (instruction.operand == .unknown and
                (!self.proof.allow_literal_index or literalIndexedEffects(instruction, anchor.text) == null)) return false;
        }
        return self.proof.dead(nodes, self.analysis.targets, self.removed, .{ .index = raw_line + 1, .mask = mask }, kill_line);
    }
};

/// Borrow complete assembly; return an owned copy with proved-dead literal
/// loads, carry setup and numeric logical identities removed. Identity A is
/// unchanged; only its N/Z outputs require a dead-value proof. All CPU state
/// is live at boundaries/exits.
/// Labels and comments retain their exact spelling/order. No memory operation,
/// stack operation, control transfer, operand or source counter is rewritten.
pub fn rewrite(allocator: std.mem.Allocator, assembly: []const u8) !Result {
    return rewriteForPhase(allocator, assembly, false);
}

/// Run on the final standalone image, where earlier rewrites may have made
/// new outputs dead. Include register transfers that leave SP untouched.
/// Fixed absolute indexed loads and stores keep their memory accesses.
pub fn rewriteLate(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.default_frame != .static or options.abi.functions.len != 0) return null;
    for (program.functions) |function| {
        if (function.exported and !std.mem.eql(u8, function.name, "main")) return null;
    }
    const result = try rewriteForPhase(a, assembly, true);
    errdefer a.free(result.assembly);
    if (result.stats.removed != 0) {
        var graph = try layout.parseForSize(a, assembly);
        defer graph.deinit(a);
        // With a closed linear layout, deleting bytes cannot increase a
        // relative span. Decline PC-dependent padding and address observers.
        if (try image.permitsLocalShrink(a, graph, program)) return result.assembly;
    }
    a.free(result.assembly);
    return null;
}

fn rewriteForPhase(allocator: std.mem.Allocator, assembly: []const u8, late: bool) !Result {
    if (std.mem.indexOf(u8, assembly, "; inline asm") != null)
        return .{ .assembly = try allocator.dupe(u8, assembly), .stats = .{} };
    var analysis = try Analysis.init(allocator, assembly);
    defer analysis.deinit();
    const raw_lines = analysis.raw_lines;
    const nodes = analysis.nodes;
    const targets = analysis.targets;
    const removed = try allocator.alloc(bool, nodes.items.len);
    defer allocator.free(removed);
    @memset(removed, false);
    var proof = Proof.init(allocator);
    defer proof.deinit();
    proof.allow_literal_index = late;
    var stats: Stats = .{};
    // Later decisions are already reflected in each proof. Never rely on an
    // instruction previously removed by this pass to kill an earlier output.
    var index = nodes.items.len;
    while (index != 0) {
        index -= 1;
        const instruction = candidate(nodes.items[index], late) orelse continue;
        if (!try proof.dead(nodes.items, targets, removed, .{ .index = index + 1, .mask = outputMask(instruction) }, null)) continue;
        removed[index] = true;
        stats.removed += 1;
        if (instruction.op == .sec or instruction.op == .clc) {
            stats.carry_removed += 1;
            stats.bytes_saved += 1;
        } else if (identity(instruction)) {
            stats.identities_removed += 1;
            stats.bytes_saved += 2;
        } else if (registerTransfer(instruction.op)) {
            stats.transfers_removed += 1;
            stats.bytes_saved += 1;
        } else {
            stats.loads_removed += 1;
            stats.bytes_saved += 2;
        }
    }
    // Build reaching values from retained instructions only. A removed load
    // can supply neither a register value nor a flag overwrite to later proofs.
    if (late) try removeRepeatedValues(analysis, removed, &proof, &stats);
    if (stats.removed == 0) return .{ .assembly = try allocator.dupe(u8, assembly), .stats = stats };
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (raw_lines.items, removed, 0..) |raw, drop, line_index| {
        if (drop) continue;
        try out.writer.writeAll(raw);
        if (line_index + 1 < raw_lines.items.len) try out.writer.writeByte('\n');
    }
    return .{ .assembly = try out.toOwnedSlice(), .stats = stats };
}

fn expectRewrite(input: []const u8, expected: []const u8, count: usize) !void {
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualStrings(expected, result.assembly);
    try std.testing.expectEqual(count, result.stats.removed);
}

const late_test_header = "* = $2000\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
const late_test_end = "    rts\n; zeropage_section_end owner=function:main kind=code\n";
const late_test_packet = "    ldx #$c1\n    lda #$99\n    adc #1\n    ora #0\n    sta $c110,y\n    ldx #7\n";

test "late CFG removes dead values across a literal indexed store" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const result = (try rewriteLate(a, parsed.program, late_test_header ++ late_test_packet ++ late_test_end)) orelse
        return error.ExpectedLateRewrite;
    defer a.free(result);
    try std.testing.expectEqualStrings(late_test_header ++
        "    lda #$99\n    adc #1\n    sta $c110,y\n    ldx #7\n" ++ late_test_end, result);
}

test "late CFG removes repeated immediate loads with equivalent or dead N/Z" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const start = late_test_header ++ "    ldx #2\n    lda $c110,x\n    stx $c000\n";
    const middle = "    bcc right\n    lda #1\n    sta $c004\n    jmp done\nright:\n    lda #2\n    sta $c004\ndone:\n    stx $c001\n    ldy #4\n    sty $c002\n    lda #6\n";
    const input = start ++ "    ldx #$02\n" ++ middle ++ "    ldy #4\n    beq done\n" ++ late_test_end;
    const output = (try rewriteLate(a, parsed.program, input)) orelse return error.ExpectedLateRewrite;
    defer a.free(output);
    try std.testing.expectEqualStrings(start ++ middle ++ "    beq done\n" ++ late_test_end, output);
    const measured = try rewriteForPhase(a, input, true);
    defer a.free(measured.assembly);
    try std.testing.expectEqual(@as(usize, 2), measured.stats.loads_removed);
    try std.testing.expectEqual(@as(usize, 4), measured.stats.bytes_saved);
    try expectRewrite(input, input, 0);
}

test "late CFG forwards byte constants through retained transfers" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const head = late_test_header ++ "    ldx #0\n    txa\n    sta $c000\n";
    const tail = "    sta $c001\n    stx $c002\n" ++ late_test_end;
    const output = (try rewriteLate(a, parsed.program, head ++ "    lda #0\n    tax\n" ++ tail)) orelse
        return error.ExpectedLateRewrite;
    defer a.free(output);
    try std.testing.expectEqualStrings(head ++ tail, output);

    const flags = head ++ "    ldy #3\n    txa\n    beq done\ndone:\n" ++ tail;
    const unchanged = try rewriteLate(a, parsed.program, flags);
    defer if (unchanged) |bytes| a.free(bytes);
    try std.testing.expect(unchanged == null);
}

test "late CFG keeps repeated loads across entries, clobbers and live N/Z" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    for ([_][]const u8{
        "    ldx #2\n    stx $c000\n    lda #0\n    ldx #2\n    beq done\ndone:\n    stx $c001\n",
        "    ldx #2\n    stx $c000\n    lda $c001\n    ldx #2\n    php\n    plp\n    stx $c001\n",
        "    bcc joined\n    ldx #2\n    stx $c000\njoined:\n    ldx #2\n    stx $c001\n",
        "    ldx #2\n    stx $c000\n    inx\n    stx $c001\n    ldx #2\n    stx $c002\n",
        "    ldx #2\n    stx $c000\n    jsr done\n    ldx #2\n    stx $c001\ndone:\n",
    }) |body| {
        const input = try std.mem.concat(a, u8, &.{ late_test_header, body, late_test_end });
        defer a.free(input);
        try std.testing.expect((try rewriteLate(a, parsed.program, input)) == null);
    }
}

test "late CFG keeps indexed register reads and physical decimal flag consumers" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    for ([_][]const u8{
        "    ldx #2\n    lda $c110,x\n    ldx #7\n",
        "    ldy #2\n    sta $c110,y\n    ldy #7\n",
        "    adc #1\n    ora #0\n    sta $c110,y\n    beq done\n    ldx #7\ndone:\n",
        "    adc #1\n    ora #0\n    sta $c110,y\n    php\n    plp\n    ldx #7\n",
    }) |body| {
        const text = try std.mem.concat(a, u8, &.{ late_test_header, body, late_test_end });
        defer a.free(text);
        try std.testing.expect((try rewriteLate(a, parsed.program, text)) == null);
    }
}

test "late CFG models literal LDX absolute Y as reading Y and killing X" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const body = "    ldy #1\n    ldx #9\n    ldx $c2ff,y\n    ldy #4\n";
    const result = (try rewriteLate(a, parsed.program, late_test_header ++ body ++ late_test_end)) orelse
        return error.ExpectedLateRewrite;
    defer a.free(result);
    try std.testing.expectEqualStrings(late_test_header ++ "    ldy #1\n    ldx $c2ff,y\n    ldy #4\n" ++ late_test_end, result);
}

test "late CFG removes register transfers whose outputs are killed" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    const body = "    txa\n    tya\n    lda $c000\n    tax\n    tsx\n    ldx #3\n    tay\n    ldy #5\n";
    const input = late_test_header ++ body ++ late_test_end;
    const result = (try rewriteLate(a, parsed.program, input)) orelse return error.ExpectedLateRewrite;
    defer a.free(result);
    try std.testing.expectEqualStrings(late_test_header ++ "    lda $c000\n    ldx #3\n    ldy #5\n" ++ late_test_end, result);

    const measured = try rewriteForPhase(a, input, true);
    defer a.free(measured.assembly);
    try std.testing.expectEqual(@as(usize, 5), measured.stats.removed);
    try std.testing.expectEqual(@as(usize, 5), measured.stats.transfers_removed);
    try std.testing.expectEqual(@as(usize, 5), measured.stats.bytes_saved);
}

test "late CFG keeps register transfers observed by flags, memory and either branch arm" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    for ([_][]const u8{
        "    tya\n    bmi done\n    lda $c000\ndone:\n    lda $c000\n",
        "    tay\n    lda $c110,y\n    ldy #0\n",
        "    txa\n    ldy #0\n    bcc done\n    sta $c001\ndone:\n    lda $c000\n",
        "    txs\n    txs\n",
    }) |body| {
        const input = try std.mem.concat(a, u8, &.{ late_test_header, body, late_test_end });
        defer a.free(input);
        try std.testing.expect((try rewriteLate(a, parsed.program, input)) == null);
    }
}

test "late CFG keeps code address observers and nonlinear layouts" {
    const a = std.testing.allocator;
    const parsed = try @import("../../parser.zig").parseSource(a, "export fn main() void {}");
    defer parsed.deinit(a);
    for ([_][]const u8{
        late_test_header ++ "    lda #<main\n    sta $c000\n" ++ late_test_packet ++ late_test_end,
        late_test_header ++ "    lda $2001\n    sta $c000\n" ++ late_test_packet ++ late_test_end,
        late_test_header ++ late_test_packet ++ late_test_end ++ ".if (* & $ff) > $db\n.fill 1,0\n.endif\n",
    }) |text| try std.testing.expect((try rewriteLate(a, parsed.program, text)) == null);
}
test "CFG dead literals remove only values killed before a read and preserve final live CPU state" {
    try expectRewrite("lda #0\nlda #1\nrts\n", "lda #1\nrts\n", 1);
    try expectRewrite("ldx #0\nldx #1\nrts\n", "ldx #1\nrts\n", 1);
    try expectRewrite("ldy #0\nldy #1\nrts\n", "ldy #1\nrts\n", 1);
    try expectRewrite("lda #0\nldx #1\nrts\n", "lda #0\nldx #1\nrts\n", 0);
    try expectRewrite("lda #0\nlda #1\nlda #2\nrts", "lda #2\nrts", 2);
}
test "CFG dead literals require both diamond paths and preserve source labels" {
    try expectRewrite("lda #0\nldy #7\nbeq left\nlda #1\njmp join\nleft:\nlda #2\njoin:\nrts\n", "ldy #7\nbeq left\nlda #1\njmp join\nleft:\nlda #2\njoin:\nrts\n", 1);
    const one_live = "lda #0\nldy #7\nbeq left\nlda #1\njmp join\nleft:\nsta observed\njoin:\nrts\n";
    try expectRewrite(one_live, one_live, 0);
}
test "CFG proof joins shared suffixes but keeps cyclic and unresolved paths" {
    try expectRewrite("lda #0\nldy #7\nbeq left\nnop\njmp join\nleft:\nnop\njoin:\nlda #1\nrts\n", "ldy #7\nbeq left\nnop\njmp join\nleft:\nnop\njoin:\nlda #1\nrts\n", 1);
    for ([_][]const u8{ "loop:\nnop\njmp loop", "jmp missing", "jmp target\ntarget:\ntarget:\nlda #1", "jmp target+1\ntarget:\nlda #1", "jmp (pointer)", "madeup text\nlda #1" }) |suffix| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "lda #0\n{s}\nrts\n", .{suffix});
        defer std.testing.allocator.free(input);
        try expectRewrite(input, input, 0);
    }
}
test "CFG reads precede kills and branches observe their physical flags" {
    for ([_][]const u8{ "cmp #0", "bit data", "sta result", "adc #1", "tax", "php", "beq target\ntarget:" }) |consumer| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "lda #0\n{s}\nlda #1\nrts\n", .{consumer});
        defer std.testing.allocator.free(input);
        try expectRewrite(input, input, 0);
    }
    try expectRewrite("sec\nlda source\ncmp #0\nrts\n", "lda source\ncmp #0\nrts\n", 1);
    for ([_][]const u8{ "adc #1", "ror a", "php", "bcs target\ntarget:" }) |consumer| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "sec\n{s}\nclc\nrts\n", .{consumer});
        defer std.testing.allocator.free(input);
        try expectRewrite(input, input, 0);
    }
}
test "CFG tracks index registers independently after NZ is killed" {
    try expectRewrite("ldx #0\nlda #1\nsta output\nldx #2\nrts\n", "lda #1\nsta output\nldx #2\nrts\n", 1);
    try expectRewrite("ldy #0\nlda #1\nsta output\nldy #2\nrts\n", "lda #1\nsta output\nldy #2\nrts\n", 1);
    for ([_][2][]const u8{
        .{ "ldx #0", "lda data,x\nldx #1" },
        .{ "ldy #0", "lda (pointer),y\nldy #1" },
        .{ "ldx #0", "stx output\nldx #1" },
        .{ "ldy #0", "tya\nldy #1" },
    }) |parts| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\nrts\n", .{ parts[0], parts[1] });
        defer std.testing.allocator.free(input);
        try expectRewrite(input, input, 0);
    }
}
test "CFG boolean leftovers can cross direct jumps without changing surviving flags" {
    try expectRewrite("lda #0\nsec\njmp false\nfalse:\nlda #0\nsec\nrts\n", "jmp false\nfalse:\nlda #0\nsec\nrts\n", 2);
    // Z is killed by LDX before BEQ; C survives until both path-local CLCs.
    try expectRewrite("sec\nldx #7\nbeq left\nclc\njmp done\nleft:\nclc\ndone:\nrts\n", "ldx #7\nbeq left\nclc\njmp done\nleft:\nclc\ndone:\nrts\n", 1);
}
test "CFG calls returns mode changes memory effects and assembly stay conservative" {
    for ([_][]const u8{ "jsr leaf", "rts", "rti", "brk", "cld", "sed", "cli", "sei", "unknown instruction" }) |barrier| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "lda #0\n{s}\nlda #1\nrts\n", .{barrier});
        defer std.testing.allocator.free(input);
        try expectRewrite(input, input, 0);
    }
    const asm_input = "lda #0\nlda #1\nrts\n; inline asm from ZeroPage line 1\nnop\n; end inline asm\n";
    try expectRewrite(asm_input, asm_input, 0);
    try expectRewrite("lda $d012\nsta value\nlda #1\nrts\n", "lda $d012\nsta value\nlda #1\nrts\n", 0);
    try expectRewrite("lda $d012\nlda #1\nrts\n", "lda $d012\nlda #1\nrts\n", 0);
    try expectRewrite("ldx $dc04\nldx #1\nrts\n", "ldx $dc04\nldx #1\nrts\n", 0);
    try expectRewrite("lda #0\nlda $d012\nrts\n", "lda $d012\nrts\n", 1);
    try expectRewrite("sec\nsta value\nclc\nrts\n", "sta value\nclc\nrts\n", 1);
}
test "CFG section boundaries and external direct jumps expose all CPU state" {
    const input = "; zeropage_section_begin owner=function:f kind=code\nf:\nlda #0\njmp g\n; zeropage_section_end owner=function:f kind=code\n; zeropage_section_begin owner=function:g kind=code\ng:\nlda #1\nrts\n; zeropage_section_end owner=function:g kind=code\n";
    try expectRewrite(input, input, 0);
    const end = "; zeropage_section_begin owner=function:f kind=code\nlda #0\n; zeropage_section_end owner=function:f kind=code\nlda #1\nrts\n";
    try expectRewrite(end, end, 0);
}
test "CFG stats describe only removed literal instruction bytes and output is idempotent" {
    const input = "lda #0\nsec\njmp false\nfalse:\nlda #0\nsec\nrts\n";
    const first = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(first.assembly);
    try std.testing.expectEqualDeep(Stats{ .removed = 2, .loads_removed = 1, .carry_removed = 1, .bytes_saved = 3 }, first.stats);
    const second = try rewrite(std.testing.allocator, first.assembly);
    defer std.testing.allocator.free(second.assembly);
    try std.testing.expectEqualStrings(first.assembly, second.assembly);
    try std.testing.expectEqualDeep(Stats{}, second.stats);
}
fn allocationFailure(allocator: std.mem.Allocator) !void {
    const result = rewrite(allocator, "lda #0\nldy #7\nbeq left\nnop\njmp done\nleft:\nnop\ndone:\nlda #1\nrts\n") catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer allocator.free(result.assembly);
}
test "CFG proof releases partial graph DFS memo and output on allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}
