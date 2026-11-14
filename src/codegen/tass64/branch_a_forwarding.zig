const std = @import("std");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");

pub const Stats = struct { reloads_replaced: usize = 0, bytes_saved: usize = 0 };
pub const Result = struct { assembly: []u8, stats: Stats };
const Zone = enum { code, data, unsectioned };
const Node = struct { text: []const u8, raw_line: usize, scope: usize, owner: []const u8, zone: Zone, instruction: ?machine.Instruction, label: ?[]const u8 };
const Section = struct { owner: []const u8, kind: []const u8 };

fn trim(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r");
}
fn identifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
fn labelName(text: []const u8) ?[]const u8 {
    if (text.len < 2 or text[text.len - 1] != ':') return null;
    const name = text[0 .. text.len - 1];
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return null;
    for (name) |byte| if (!identifierByte(byte)) return null;
    return name;
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
fn conditional(op: machine.Op) bool {
    return switch (op) {
        .bcc, .bcs, .beq, .bne, .bmi, .bpl, .bvc, .bvs => true,
        else => false,
    };
}
fn immediateCompare(instruction: ?machine.Instruction) bool {
    const inst = instruction orelse return false;
    return inst.op == .cmp and inst.operand == .immediate and
        (machine.integer(inst.operand.immediate) orelse return false) <= 255;
}
fn comparison(instruction: ?machine.Instruction) bool {
    const inst = instruction orelse return false;
    return immediateCompare(instruction) or (inst.op == .cmp and inst.operand == .direct);
}
fn generatedBody(name: []const u8) bool {
    if (name.len <= 9 or !std.ascii.eqlIgnoreCase(name[0..4], "for_") or !std.ascii.eqlIgnoreCase(name[name.len - 5 ..], "_body")) return false;
    for (name[4 .. name.len - 5]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}
fn exactDefinition(nodes: []const Node, reference: machine.Symbol) bool {
    const defined = uniqueLabel(nodes, reference.name) orelse return false;
    return std.mem.eql(u8, nodes[defined].label.?, reference.name);
}
fn uniqueLabel(nodes: []const Node, name: []const u8) ?usize {
    var found: ?usize = null;
    for (nodes, 0..) |node, index| if (node.label) |defined| {
        if (!std.ascii.eqlIgnoreCase(defined, name)) continue;
        if (found != null) return null;
        found = index;
    };
    return found;
}
fn references(nodes: []const Node, name: []const u8) usize {
    var count: usize = 0;
    for (nodes) |node| {
        if (node.label != null) continue;
        var index: usize = 0;
        while (index < node.text.len) {
            if (!identifierByte(node.text[index])) {
                index += 1;
                continue;
            }
            const start = index;
            while (index < node.text.len and identifierByte(node.text[index])) : (index += 1) {}
            if (std.ascii.eqlIgnoreCase(node.text[start..index], name)) count += 1;
        }
    }
    return count;
}
fn visible(model: storage.Model, nodes: []const Node, reference: machine.Symbol) ?storage.Location {
    // Model keys preserve spelling; assembler symbol identity is case-insensitive.
    const defined = uniqueLabel(nodes, reference.name) orelse return null;
    const name = nodes[defined].label.?;
    const location = model.resolve(.{ .name = name, .offset = reference.offset }, 1) orelse return null;
    const frame = model.frames.items[location.frame];
    if (frame.upper <= 0xa000 or (frame.lower >= 0xc000 and frame.upper <= 0xd000)) return location;
    return null;
}
fn counterId(owner: []const u8, name: []const u8) ?[]const u8 {
    const middle = "_for_";
    const suffix = "_index";
    if (name.len <= owner.len + middle.len + suffix.len or !std.ascii.eqlIgnoreCase(name[0..owner.len], owner) or
        !std.mem.startsWith(u8, name[owner.len..], middle) or !std.mem.endsWith(u8, name, suffix)) return null;
    const id = name[owner.len + middle.len .. name.len - suffix.len];
    for (id) |byte| if (!std.ascii.isDigit(byte)) return null;
    return id;
}
fn sameCounterBody(id: []const u8, name: []const u8) bool {
    return name.len == "for_".len + id.len + "_body".len and std.ascii.eqlIgnoreCase(name[0..4], "for_") and
        std.mem.eql(u8, name[4 .. 4 + id.len], id) and std.ascii.eqlIgnoreCase(name[4 + id.len ..], "_body");
}
fn headerAt(nodes: []const Node, index: usize) bool {
    if (index + 2 >= nodes.len or nodes[index].scope == 0 or nodes[index + 1].scope != nodes[index].scope or nodes[index + 2].scope != nodes[index].scope) return false;
    const load = nodes[index].instruction orelse return false;
    const branch = nodes[index + 2].instruction orelse return false;
    return load.op == .lda and load.operand == .direct and comparison(nodes[index + 1].instruction) and conditional(branch.op);
}
fn legacyHeaderAt(nodes: []const Node, index: usize) bool {
    return headerAt(nodes, index) and immediateCompare(nodes[index + 1].instruction);
}
const Establishment = struct { from: usize, root: usize, cell: storage.Location };
fn controlsKnown(allocator: std.mem.Allocator, nodes: []const Node) !bool {
    var pending: std.ArrayList(usize) = .empty;
    defer pending.deinit(allocator);
    for (nodes) |node| if (node.instruction) |instruction| {
        if (instruction.op == .brk or instruction.op == .rti) return false;
        if (instruction.op != .jmp and instruction.op != .jsr and !conditional(instruction.op)) continue;
        if (instruction.operand != .direct or instruction.operand.direct.offset != 0) return false;
        try pending.append(allocator, uniqueLabel(nodes, instruction.operand.direct.name) orelse return false);
    };
    // Runtime/test hooks can be unsectioned. Admit their entries only when every
    // reachable path consists of parsed code until a return or real code entry;
    // a named jump to data is no stronger proof than an unknown numeric jump.
    const visited = try allocator.alloc(bool, nodes.len);
    defer allocator.free(visited);
    @memset(visited, false);
    while (pending.pop()) |index| {
        if (index >= nodes.len) return false;
        if (visited[index]) continue;
        visited[index] = true;
        const node = nodes[index];
        if (node.zone == .code) continue;
        if (node.zone == .data) return false;
        if (node.label != null) {
            try pending.append(allocator, index + 1);
            continue;
        }
        const instruction = node.instruction orelse return false;
        if (instruction.op == .rts) continue;
        if (instruction.op == .jmp or instruction.op == .jsr or conditional(instruction.op)) {
            // All control operands and unique targets were checked above.
            try pending.append(allocator, uniqueLabel(nodes, instruction.operand.direct.name).?);
            if (instruction.op == .jmp) continue;
        }
        try pending.append(allocator, index + 1);
    }
    return true;
}
fn unchanged(allocator: std.mem.Allocator, assembly: []const u8) !Result {
    return .{ .assembly = try allocator.dupe(u8, assembly), .stats = .{} };
}

/// Reuse A on a uniquely entered internal edge. Legacy counter gates remain. The
/// header's visible RAM LDA dominates its consecutive CMP/branch. ORA #0 restores
/// exactly the original reload's A/NZ, preserving all other physical CPU state.
/// Never remove the identity here, even for CMP #0; CFG cleanup is independent.
pub fn rewrite(allocator: std.mem.Allocator, assembly: []const u8) !Result {
    return rewriteMode(allocator, assembly, .legacy);
}
/// Ordinary edges run exactly once after boolean materialization AND its first
/// CFG cleanup, before word-compare cleanup. The caller may rerun CFG afterward
/// only when identities were introduced. No records survive API invocations;
/// explicitly protect every possible root used by the earlier legacy pass.
/// Callers also keep module/loader/placement AST guards outside this pure API.
pub fn rewriteOrdinary(allocator: std.mem.Allocator, assembly: []const u8) !Result {
    return rewriteMode(allocator, assembly, .ordinary);
}
const Mode = enum { legacy, ordinary };
fn legacyEstablishment(nodes: []const Node, index: usize) bool {
    if (!legacyHeaderAt(nodes, index)) return false;
    const load = nodes[index].instruction.?;
    const branch = nodes[index + 2].instruction.?;
    if (load.operand.direct.offset != 0 or branch.operand != .direct or branch.operand.direct.offset != 0) return false;
    const id = counterId(nodes[index].owner, load.operand.direct.name) orelse return false;
    return sameCounterBody(id, branch.operand.direct.name);
}
fn rewriteMode(allocator: std.mem.Allocator, assembly: []const u8, mode: Mode) !Result {
    if (std.mem.indexOf(u8, assembly, "; inline asm") != null) return unchanged(allocator, assembly);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var nodes: std.ArrayList(Node) = .empty;
    defer nodes.deinit(allocator);
    var active: ?Section = null;
    var scope: usize = 0;
    var next_scope: usize = 0;
    var owner: []const u8 = "";
    var split = std.mem.splitScalar(u8, assembly, '\n');
    while (split.next()) |raw| {
        const raw_line = lines.items.len;
        try lines.append(allocator, raw);
        const text = trim(raw);
        if (std.mem.startsWith(u8, text, "; zeropage_section_")) {
            const marker = section(text) orelse return unchanged(allocator, assembly);
            if (std.mem.startsWith(u8, text, "; zeropage_section_begin ")) {
                if (active != null) return unchanged(allocator, assembly);
                active = marker;
                if (storage.sectionOwner(text, "code")) |function| {
                    next_scope += 1;
                    scope = next_scope;
                    owner = function;
                } else {
                    scope = 0;
                    owner = "";
                }
            } else if (std.mem.startsWith(u8, text, "; zeropage_section_end ")) {
                const prior = active orelse return unchanged(allocator, assembly);
                if (!std.mem.eql(u8, marker.owner, prior.owner) or !std.mem.eql(u8, marker.kind, prior.kind)) return unchanged(allocator, assembly);
                active = null;
                scope = 0;
                owner = "";
            } else return unchanged(allocator, assembly);
            continue;
        }
        if (text.len == 0 or text[0] == ';') continue;
        const label = labelName(text);
        const instruction = machine.Instruction.parse(text);
        const zone: Zone = if (active) |current| (if (std.mem.eql(u8, current.kind, "code")) .code else .data) else .unsectioned;
        if (zone == .code and label == null and instruction == null) return unchanged(allocator, assembly);
        try nodes.append(allocator, .{ .text = text, .raw_line = raw_line, .scope = scope, .owner = owner, .zone = zone, .instruction = instruction, .label = label });
    }
    if (active != null or !try controlsKnown(allocator, nodes.items)) return unchanged(allocator, assembly);
    var model = storage.Model.init(allocator);
    defer model.deinit();
    try model.collect(assembly);
    const replaced = try allocator.alloc(bool, lines.items.len);
    defer allocator.free(replaced);
    @memset(replaced, false);
    const established = try allocator.alloc(?Establishment, nodes.items.len);
    defer allocator.free(established);
    @memset(established, null);
    var stats: Stats = .{};
    for (nodes.items, 0..) |header, index| {
        if (!headerAt(nodes.items, index)) continue;
        const load = header.instruction.?;
        const branch = nodes.items[index + 2].instruction.?;
        if (branch.operand != .direct or branch.operand.direct.offset != 0) continue;
        const counter = counterId(header.owner, load.operand.direct.name);
        const legacy = counter != null or generatedBody(branch.operand.direct.name);
        if ((mode == .legacy and !legacy) or (mode == .ordinary and legacy)) continue;
        if (legacy) {
            const id = counter orelse continue;
            if (load.operand.direct.offset != 0 or !sameCounterBody(id, branch.operand.direct.name) or !immediateCompare(nodes.items[index + 1].instruction)) continue;
        } else {
            // Unlike the inherited counter path, new ordinary proofs require
            // exact defined spelling: removing an unresolved differently-cased
            // LDA must never make an invalid assembler program valid.
            if (!exactDefinition(nodes.items, load.operand.direct) or !exactDefinition(nodes.items, branch.operand.direct)) continue;
            const compare = nodes.items[index + 1].instruction.?;
            if (compare.operand == .direct) {
                if (!exactDefinition(nodes.items, compare.operand.direct)) continue;
                _ = visible(model, nodes.items, compare.operand.direct) orelse continue;
            }
        }
        const target = uniqueLabel(nodes.items, branch.operand.direct.name) orelse continue;
        if (references(nodes.items, branch.operand.direct.name) != 1) continue;
        var first = target;
        while (first != 0 and nodes.items[first - 1].label != null) : (first -= 1) {}
        var last = target;
        while (last + 1 < nodes.items.len and nodes.items[last + 1].label != null) : (last += 1) {}
        var aliases_safe = true;
        for (nodes.items[first .. last + 1], first..) |alias, alias_index| {
            if (alias.scope != header.scope or uniqueLabel(nodes.items, alias.label.?) == null or
                references(nodes.items, alias.label.?) != @as(usize, if (alias_index == target) 1 else 0)) aliases_safe = false;
        }
        if (!aliases_safe or first == 0 or last + 1 >= nodes.items.len) continue;
        const predecessor = nodes.items[first - 1].instruction orelse continue;
        if (nodes.items[first - 1].scope != header.scope or (predecessor.op != .jmp and predecessor.op != .rts)) continue;
        const body_index = last + 1;
        const body = nodes.items[body_index];
        const reload = body.instruction orelse continue;
        if (body.scope != header.scope or reload.op != .lda or reload.operand != .direct) continue;
        if (legacy) {
            // Preserve the original counter-only exclusion exactly.
            if (legacyHeaderAt(nodes.items, body_index)) continue;
        } else {
            if (!exactDefinition(nodes.items, reload.operand.direct)) continue;
            // The earlier legacy invocation already may have created ORAs
            // depending on this root. Its records are not this invocation's,
            // so protect every possible legacy establishment explicitly.
            if (legacyEstablishment(nodes.items, body_index)) continue;
            // Ordinary header-as-body chains only move forward. A later
            // candidate cannot remove an already-used establishing root.
            if (headerAt(nodes.items, body_index) and body_index <= index) continue;
        }
        const before = visible(model, nodes.items, load.operand.direct) orelse continue;
        const after = visible(model, nodes.items, reload.operand.direct) orelse continue;
        if (before.frame != after.frame or before.offset != after.offset or
            !std.mem.eql(u8, model.frames.items[before.frame].owner, header.owner)) continue;
        // Revalidate current semantics explicitly: an original header already
        // changed to ORA#0 needs an accepted earlier exact-cell establishment,
        // ultimately rooted in an unchanged real LDA. Edges/labels never change.
        const root = if (replaced[header.raw_line]) root: {
            const prior = established[index] orelse continue;
            if (prior.from >= index or prior.root > prior.from or replaced[nodes.items[prior.root].raw_line] or
                prior.cell.frame != before.frame or prior.cell.offset != before.offset) continue;
            break :root prior.root;
        } else index;
        if (replaced[body.raw_line]) continue;
        // Pin roots accepted earlier in THIS invocation, independent of
        // apparent reachability. Roots from the separate earlier legacy call
        // are protected structurally above, not by surviving record storage.
        var pinned_root = false;
        for (established) |prior| if (prior) |proof| {
            if (proof.root == body_index) pinned_root = true;
        };
        if (pinned_root) continue;
        replaced[body.raw_line] = true;
        established[body_index] = .{ .from = index, .root = root, .cell = before };
        stats.reloads_replaced += 1;
        stats.bytes_saved += 1; // resident LDA abs 3 -> ORA immediate 2
    }
    // Final audit of the actual selected graph, independent of candidate
    // iteration order. Every accepted identity still has a real load root.
    for (established) |prior| if (prior) |proof| {
        if (replaced[nodes.items[proof.root].raw_line]) return unchanged(allocator, assembly);
    };
    if (stats.reloads_replaced == 0) return unchanged(allocator, assembly);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (lines.items, replaced, 0..) |raw, replace, index| {
        if (replace) try out.writer.writeAll("    ora #0") else try out.writer.writeAll(raw);
        if (index + 1 < lines.items.len) try out.writer.writeByte('\n');
    }
    return .{ .assembly = try out.toOwnedSlice(), .stats = stats };
}

const code_begin = "; zeropage_section_begin owner=function:f kind=code lifetime=static address=near\n";
const code_end = "; zeropage_section_end owner=function:f kind=code\n";
const frame_begin = "; zeropage_section_begin owner=function:f kind=static_frame lifetime=static address=near\n";
const frame_end = "; zeropage_section_end owner=function:f kind=static_frame\n";
const code = "f:\nfor_0_top:\n    lda f_for_0_index\n    cmp #9\n    bcc for_0_body\n    jmp for_0_done\nfor_0_body:\n; preserve capture metadata\n    lda f_for_0_index\n    sta f_index\n    tay\n    jmp for_0_top\nfor_0_done:\n    rts\n";
const data = "f_for_0_index:\nf_counter_alias:\n    .word 0\nf_index:\n    .byte 0\n";
fn fixture(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ "* = $2000\n", code_begin, body, code_end, frame_begin, data, frame_end });
}
fn expectChanged(input: []const u8, count: usize) !void {
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualDeep(Stats{ .reloads_replaced = count, .bytes_saved = count }, result.stats);
    try std.testing.expectEqual(count, std.mem.count(u8, result.assembly, "    ora #0"));
}
fn expectKept(input: []const u8) !void {
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualDeep(Stats{}, result.stats);
    try std.testing.expectEqualStrings(input, result.assembly);
}

test "branch A reuses a uniquely entered visible hidden counter without changing labels or flags" {
    const input = try fixture(std.testing.allocator, code);
    defer std.testing.allocator.free(input);
    const expected_code = try std.mem.replaceOwned(u8, std.testing.allocator, code, "metadata\n    lda f_for_0_index", "metadata\n    ora #0");
    defer std.testing.allocator.free(expected_code);
    const expected = try fixture(std.testing.allocator, expected_code);
    defer std.testing.allocator.free(expected);
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualStrings(expected, result.assembly);
    try std.testing.expectEqualDeep(Stats{ .reloads_replaced = 1, .bytes_saved = 1 }, result.stats);
}

test "branch A supports every conditional edge and always emits identity even for CMP zero" {
    for ([_][]const u8{ "bcc", "bcs", "beq", "bne", "bmi", "bpl", "bvc", "bvs" }) |opcode| {
        const branch = try std.fmt.allocPrint(std.testing.allocator, "{s} for_0_body", .{opcode});
        defer std.testing.allocator.free(branch);
        const body = try std.mem.replaceOwned(u8, std.testing.allocator, code, "bcc for_0_body", branch);
        defer std.testing.allocator.free(body);
        const input = try fixture(std.testing.allocator, body);
        defer std.testing.allocator.free(input);
        try expectChanged(input, 1);
    }
    const zero = try std.mem.replaceOwned(u8, std.testing.allocator, code, "cmp #9", "cmp #0");
    defer std.testing.allocator.free(zero);
    const input = try fixture(std.testing.allocator, zero);
    defer std.testing.allocator.free(input);
    try expectChanged(input, 1);
}

test "branch A canonical aliases identify the exact byte and preserve case insensitive entries" {
    for ([_][]const u8{ "f_counter_alias", "f_counter_alias+0", "F_COUNTER_ALIAS" }) |name| {
        const replacement = try std.fmt.allocPrint(std.testing.allocator, "metadata\n    lda {s}", .{name});
        defer std.testing.allocator.free(replacement);
        const body = try std.mem.replaceOwned(u8, std.testing.allocator, code, "metadata\n    lda f_for_0_index", replacement);
        defer std.testing.allocator.free(body);
        const input = try fixture(std.testing.allocator, body);
        defer std.testing.allocator.free(input);
        try expectChanged(input, 1);
    }
    const wrong = try std.mem.replaceOwned(u8, std.testing.allocator, code, "metadata\n    lda f_for_0_index", "metadata\n    lda f_for_0_index+1");
    defer std.testing.allocator.free(wrong);
    const input = try fixture(std.testing.allocator, wrong);
    defer std.testing.allocator.free(input);
    try expectKept(input);
}

test "branch A accepts forward and backward layouts with explicit no fallthrough" {
    const backwards = "f:\n    jmp header\nfor_0_body:\n    lda f_for_0_index\n    sta f_index\n    rts\nheader:\n    lda f_for_0_index\n    cmp #9\n    bcc for_0_body\n    jmp done\ndone:\n    rts\n";
    const input = try fixture(std.testing.allocator, backwards);
    defer std.testing.allocator.free(input);
    try expectChanged(input, 1);
    const previous_rts = try std.mem.replaceOwned(u8, std.testing.allocator, code, "    jmp for_0_done\nfor_0_body:", "    rts\nfor_0_body:");
    defer std.testing.allocator.free(previous_rts);
    const other = try fixture(std.testing.allocator, previous_rts);
    defer std.testing.allocator.free(other);
    try expectChanged(other, 1);
}

test "branch A keeps a body with fallthrough or any additional entry reference" {
    const fallthrough = try std.mem.replaceOwned(u8, std.testing.allocator, code, "jmp for_0_done", "nop");
    defer std.testing.allocator.free(fallthrough);
    const input = try fixture(std.testing.allocator, fallthrough);
    defer std.testing.allocator.free(input);
    try expectKept(input);
    for ([_][]const u8{ "jmp for_0_body", "jsr for_0_body", "bne FOR_0_BODY", "lda #<for_0_body", ".word for_0_body", "alias = for_0_body+1", "unknown for_0_body" }) |reference| {
        const original = try fixture(std.testing.allocator, code);
        defer std.testing.allocator.free(original);
        const extra = try std.mem.concat(std.testing.allocator, u8, &.{ original, reference, "\n" });
        defer std.testing.allocator.free(extra);
        try expectKept(extra);
    }
}

test "branch A guards all co located labels and duplicate case folded definitions" {
    const aliased = try std.mem.replaceOwned(u8, std.testing.allocator, code, "for_0_body:\n", "unused_alias:\nfor_0_body:\nafter_alias:\n");
    defer std.testing.allocator.free(aliased);
    const input = try fixture(std.testing.allocator, aliased);
    defer std.testing.allocator.free(input);
    try expectChanged(input, 1);
    for ([_][]const u8{ "jmp unused_alias", "lda #<after_alias", "FOR_0_BODY:", "unused_alias:" }) |reference| {
        const extra = try std.mem.concat(std.testing.allocator, u8, &.{ input, reference, "\n" });
        defer std.testing.allocator.free(extra);
        try expectKept(extra);
    }
}

test "branch A rejects header bypass labels nonliteral compares and intervening operations" {
    const changes = [_][2][]const u8{
        .{ "    cmp #9", "bypass:\n    cmp #9" },                        .{ "    bcc for_0_body", "bypass:\n    bcc for_0_body" },
        .{ "cmp #9", "cmp f_index" },                                    .{ "cmp #9", "cmp #256" },
        .{ "cmp #9", "cmp #<for_0_done" },                               .{ "    cmp #9", "    inx\n    cmp #9" },
        .{ "    bcc for_0_body", "    jsr helper\n    bcc for_0_body" }, .{ "metadata\n    lda f_for_0_index", "metadata\n    tax\n    lda f_for_0_index" },
    };
    for (changes) |change| {
        const body = try std.mem.replaceOwned(u8, std.testing.allocator, code, change[0], change[1]);
        defer std.testing.allocator.free(body);
        const input = try fixture(std.testing.allocator, body);
        defer std.testing.allocator.free(input);
        try expectKept(input);
    }
}

test "branch A declines numeric offset indirect and unresolved control globally" {
    for ([_][]const u8{ "jmp $2000", "jsr $ffd2", "jmp for_0_top+1", "jmp (pointer)", "bne missing", "brk", "rti" }) |control| {
        const original = try fixture(std.testing.allocator, code);
        defer std.testing.allocator.free(original);
        const input = try std.mem.concat(std.testing.allocator, u8, &.{ original, control, "\n" });
        defer std.testing.allocator.free(input);
        try expectKept(input);
    }
}

test "branch A validates unsectioned runtime entry paths without accepting raw data targets" {
    const called = try std.mem.replaceOwned(u8, std.testing.allocator, code, "f:\n", "f:\n    jsr helper\n");
    defer std.testing.allocator.free(called);
    const original = try fixture(std.testing.allocator, called);
    defer std.testing.allocator.free(original);
    for ([_][]const u8{
        "helper:\nhelper_alias:\n    rts\n",
        "helper:\n    beq helper_done\n    lda #1\nhelper_done:\n    rts\n",
        "; zeropage_section_begin owner=runtime:helper kind=code\nhelper:\n    rts\n; zeropage_section_end owner=runtime:helper kind=code\n",
    }) |tail| {
        const input = try std.mem.concat(std.testing.allocator, u8, &.{ original, tail });
        defer std.testing.allocator.free(input);
        try expectChanged(input, 1);
    }
    for ([_][]const u8{
        "helper:\n    .byte $60\n",
        "helper:\n    beq helper_done\n    .byte $60\nhelper_done:\n    rts\n",
        "helper:\n    lda #1\n",
        "; zeropage_section_begin owner=runtime:helper kind=rodata\nhelper:\n    rts\n; zeropage_section_end owner=runtime:helper kind=rodata\n",
        "; zeropage_section_begin owner=runtime:helper kind=code\nhelper:\n    .byte $60\n; zeropage_section_end owner=runtime:helper kind=code\n",
    }) |tail| {
        const input = try std.mem.concat(std.testing.allocator, u8, &.{ original, tail });
        defer std.testing.allocator.free(input);
        try expectKept(input);
    }
}

test "branch A rejects unknown code ASM and malformed or cross function scopes" {
    for ([_][]const u8{ "    nop\n", "    .byte $ea\n", "    madeup text\n" }) |extra| {
        if (std.mem.indexOf(u8, extra, "nop") != null) continue;
        const body = try std.mem.concat(std.testing.allocator, u8, &.{ code, extra });
        defer std.testing.allocator.free(body);
        const input = try fixture(std.testing.allocator, body);
        defer std.testing.allocator.free(input);
        try expectKept(input);
    }
    const original = try fixture(std.testing.allocator, code);
    defer std.testing.allocator.free(original);
    const asm_input = try std.mem.concat(std.testing.allocator, u8, &.{ original, "; inline asm from ZeroPage line 1\nnop\n; end inline asm\n" });
    defer std.testing.allocator.free(asm_input);
    try expectKept(asm_input);
    const bad = try std.mem.replaceOwned(u8, std.testing.allocator, original, code_end, "");
    defer std.testing.allocator.free(bad);
    try expectKept(bad);
    const split = try std.mem.replaceOwned(u8, std.testing.allocator, original, "for_0_body:\n", code_end ++ "; zeropage_section_begin owner=function:g kind=code\nfor_0_body:\n");
    defer std.testing.allocator.free(split);
    try expectKept(split);
}

test "branch A restricts hidden counter ownership and stable generated IDs" {
    for ([_][2][]const u8{
        .{ "f_for_0_index", "f_user_counter" }, .{ "f_for_0_index", "g_for_0_index" }, .{ "f_for_0_index", "f_for_1_index" },
    }) |change| {
        const original = try fixture(std.testing.allocator, code);
        defer std.testing.allocator.free(original);
        const input = try std.mem.replaceOwned(u8, std.testing.allocator, original, change[0], change[1]);
        defer std.testing.allocator.free(input);
        try expectKept(input);
    }
}

test "branch A refuses shadow MMIO unknown origins and crossing visible RAM frame limits" {
    const original = try fixture(std.testing.allocator, code);
    defer std.testing.allocator.free(original);
    for ([_][]const u8{ "$a000", "$bfff", "$d000", "$e000", "unknown" }) |origin| {
        const input = try std.mem.replaceOwned(u8, std.testing.allocator, original, "$2000", origin);
        defer std.testing.allocator.free(input);
        try expectKept(input);
    }
    for ([_]struct { origin: []const u8, count: usize }{
        .{ .origin = "$9ffd", .count = 1 }, .{ .origin = "$9ffe", .count = 0 },
        .{ .origin = "$cffd", .count = 1 }, .{ .origin = "$cffe", .count = 0 },
    }) |case| {
        const replacement = try std.fmt.allocPrint(std.testing.allocator, "* = {s}\n{s}", .{ case.origin, frame_begin });
        defer std.testing.allocator.free(replacement);
        const input = try std.mem.replaceOwned(u8, std.testing.allocator, original, frame_begin, replacement);
        defer std.testing.allocator.free(input);
        if (case.count == 0) try expectKept(input) else try expectChanged(input, case.count);
    }
}

test "branch A rejects a body reload that is itself another establishing header" {
    const self_cycle = "f:\n    jmp done\nfor_0_body:\n    lda f_for_0_index\n    cmp #9\n    bcc for_0_body\n    jmp done\ndone:\n    rts\n";
    const input = try fixture(std.testing.allocator, self_cycle);
    defer std.testing.allocator.free(input);
    try expectKept(input);
}

test "branch A preserves all comments and is idempotent" {
    const input = try fixture(std.testing.allocator, code);
    defer std.testing.allocator.free(input);
    const first = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(first.assembly);
    try std.testing.expect(std.mem.indexOf(u8, first.assembly, "; preserve capture metadata") != null);
    const second = try rewrite(std.testing.allocator, first.assembly);
    defer std.testing.allocator.free(second.assembly);
    try std.testing.expectEqualStrings(first.assembly, second.assembly);
    try std.testing.expectEqualDeep(Stats{}, second.stats);
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    const input = try fixture(allocator, code);
    defer allocator.free(input);
    const result = rewrite(allocator, input) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer allocator.free(result.assembly);
}
test "branch A releases partial node model selection and output storage on allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}

fn expectOrdinaryChanged(input: []const u8, count: usize) !void {
    const result = try rewriteOrdinary(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualDeep(Stats{ .reloads_replaced = count, .bytes_saved = count }, result.stats);
    try std.testing.expectEqual(count, std.mem.count(u8, result.assembly, "    ora #0"));
}
fn expectOrdinaryKept(input: []const u8) !void {
    const result = try rewriteOrdinary(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualDeep(Stats{}, result.stats);
    try std.testing.expectEqualStrings(input, result.assembly);
}
const ordinary = "f:\n    lda f_value\n    cmp #9\n    bcc rhs\n    jmp done\nrhs:\n    lda f_alias\n    sta f_result\n    rts\ndone:\n    lda #37\n    rts\n";
const ordinary_data = "f_value:\nf_alias:\n    .byte 0\nf_limit:\n    .byte 0\nf_result:\n    .byte 0\n";
fn ordinaryFixture(body: []const u8) ![]u8 {
    return std.mem.concat(std.testing.allocator, u8, &.{ "* = $2000\n", code_begin, body, code_end, "* = $c100\n", frame_begin, ordinary_data, frame_end });
}
test "general branch A reuses ordinary internal edge and visible direct CMP operand" {
    for ([_][]const u8{ "cmp #9", "cmp f_limit" }) |compare| {
        const body = try std.mem.replaceOwned(u8, std.testing.allocator, ordinary, "cmp #9", compare);
        defer std.testing.allocator.free(body);
        const input = try ordinaryFixture(body);
        defer std.testing.allocator.free(input);
        try expectOrdinaryChanged(input, 1);
    }
}
test "general branch A supports ordinary forward backward and exact canonical offset bytes" {
    const backward = "f:\n    jmp header\nrhs:\n    lda f_alias\n    sta f_result\n    rts\nheader:\n    lda f_value\n    cmp f_limit\n    bcc rhs\n    jmp done\ndone:\n    lda #37\n    rts\n";
    const input = try ordinaryFixture(backward);
    defer std.testing.allocator.free(input);
    try expectOrdinaryChanged(input, 1);
    const offset = "f:\n    lda f_value+1\n    cmp #9\n    bcc rhs\n    jmp done\nrhs:\n    lda f_limit\n    rts\ndone:\n    rts\n";
    const other = try ordinaryFixture(offset);
    defer std.testing.allocator.free(other);
    try expectOrdinaryChanged(other, 1);
}
test "general branch A admits only rooted forward establishing-header chains" {
    const chain = "f:\n    lda f_value\n    cmp #0\n    bne first\n    jmp done\nfirst:\n    lda f_value\n    cmp f_limit\n    beq second\n    jmp done\nsecond:\n    lda f_alias\n    cmp #128\n    bne result\n    jmp done\nresult:\n    lda f_value\n    rts\ndone:\n    lda #37\n    rts\n";
    const input = try ordinaryFixture(chain);
    defer std.testing.allocator.free(input);
    try expectOrdinaryChanged(input, 3);
    const first = try rewriteOrdinary(std.testing.allocator, input);
    defer std.testing.allocator.free(first.assembly);
    const again = try rewriteOrdinary(std.testing.allocator, first.assembly);
    defer std.testing.allocator.free(again.assembly);
    try std.testing.expectEqual(@as(usize, 0), again.stats.reloads_replaced);
    try std.testing.expectEqualStrings(first.assembly, again.assembly);
}
test "general branch A rejects self or backward establishing header dependencies" {
    const self = "f:\n    jmp rhs\nrhs:\n    lda f_value\n    cmp f_limit\n    bne rhs\n    jmp done\ndone:\n    rts\n";
    const cyclic = "f:\n    jmp late\nearly:\n    lda f_value\n    cmp f_limit\n    bne late\n    jmp done\nlate:\n    lda f_value\n    cmp #9\n    bne early\n    jmp done\ndone:\n    rts\n";
    const a = try ordinaryFixture(self);
    defer std.testing.allocator.free(a);
    try expectOrdinaryKept(a);
    const b = try ordinaryFixture(cyclic);
    defer std.testing.allocator.free(b);
    try expectOrdinaryKept(b);
}
test "general branch A rejects ordinary alternate entries fallthrough and header bypasses" {
    const input = try ordinaryFixture(ordinary);
    defer std.testing.allocator.free(input);
    for ([_][]const u8{ "jmp rhs\n", "jsr rhs\n", ".word rhs\n", "alias = rhs+1\n", "lda #<rhs\n" }) |tail| {
        const changed = try std.mem.concat(std.testing.allocator, u8, &.{ input, tail });
        defer std.testing.allocator.free(changed);
        try expectOrdinaryKept(changed);
    }
    for ([_][2][]const u8{ .{ "    jmp done\nrhs:", "    nop\nrhs:" }, .{ "    cmp #9", "bypass:\n    cmp #9" }, .{ "    bcc rhs", "bypass:\n    bcc rhs" }, .{ "rhs:\n", "alias_entry:\nrhs:\n" } }) |pair| {
        const body = try std.mem.replaceOwned(u8, std.testing.allocator, ordinary, pair[0], pair[1]);
        defer std.testing.allocator.free(body);
        const changed = try ordinaryFixture(body);
        defer std.testing.allocator.free(changed);
        if (std.mem.indexOf(u8, pair[1], "alias_entry") != null) {
            const escaped = try std.mem.concat(std.testing.allocator, u8, &.{ changed, ".word alias_entry\n" });
            defer std.testing.allocator.free(escaped);
            try expectOrdinaryKept(escaped);
        } else try expectOrdinaryKept(changed);
    }
}
test "general branch A requires both canonical reload and compare memory visible RAM" {
    for ([_][]const u8{ "cmp $d020", "cmp (f_limit),y", "cmp f_limit,x", "cmp missing", "cmp #256", "cmp #<rhs" }) |compare| {
        const body = try std.mem.replaceOwned(u8, std.testing.allocator, ordinary, "cmp #9", compare);
        defer std.testing.allocator.free(body);
        const input = try ordinaryFixture(body);
        defer std.testing.allocator.free(input);
        try expectOrdinaryKept(input);
    }
    const body = try std.mem.replaceOwned(u8, std.testing.allocator, ordinary, "cmp #9", "cmp compare_cell");
    defer std.testing.allocator.free(body);
    const base = try ordinaryFixture(body);
    defer std.testing.allocator.free(base);
    for ([_][]const u8{ "$a000", "$d020", "$e000", "$cfff" }) |origin| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "{s}* = {s}\n; zeropage_section_begin owner=function:f kind=static_frame\ncompare_cell:\n.word 0\n; zeropage_section_end owner=function:f kind=static_frame\n", .{ base, origin });
        defer std.testing.allocator.free(input);
        try expectOrdinaryKept(input);
    }
}
test "general branch A retains NZ identity even when immediately overwritten and preserves comments" {
    const body = try std.mem.replaceOwned(u8, std.testing.allocator, ordinary, "    sta f_result", "; retained comment\n    cmp #0\n    sta f_result");
    defer std.testing.allocator.free(body);
    const input = try ordinaryFixture(body);
    defer std.testing.allocator.free(input);
    const result = try rewriteOrdinary(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqual(@as(usize, 1), result.stats.reloads_replaced);
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "    ora #0\n; retained comment\n    cmp #0") != null);
}

test "general branch A handles every physical conditional and safe colocated aliases" {
    for ([_][]const u8{ "bcc", "bcs", "beq", "bne", "bmi", "bpl", "bvc", "bvs" }) |op| {
        const branch = try std.fmt.allocPrint(std.testing.allocator, "{s} rhs", .{op});
        defer std.testing.allocator.free(branch);
        const body = try std.mem.replaceOwned(u8, std.testing.allocator, ordinary, "bcc rhs", branch);
        defer std.testing.allocator.free(body);
        const aliased = try std.mem.replaceOwned(u8, std.testing.allocator, body, "rhs:\n", "before_alias:\nrhs:\nafter_alias:\n");
        defer std.testing.allocator.free(aliased);
        const input = try ordinaryFixture(aliased);
        defer std.testing.allocator.free(input);
        try expectOrdinaryChanged(input, 1);
    }
}
test "general branch A rejects cross owner unknown casing and case folded duplicate entries" {
    const input = try ordinaryFixture(ordinary);
    defer std.testing.allocator.free(input);
    for ([_][2][]const u8{
        .{ "    lda f_alias", "    lda F_ALIAS" },                                                .{ "    lda f_value", "    lda F_VALUE" },
        .{ "rhs:\n", "rhs:\nRHS:\n" },                                                            .{ "f_value:\n", "f_value:\nF_VALUE:\n" },
        .{ "rhs:\n", code_end ++ "; zeropage_section_begin owner=function:g kind=code\nrhs:\n" },
    }) |pair| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, input, pair[0], pair[1]);
        defer std.testing.allocator.free(changed);
        try expectOrdinaryKept(changed);
    }
}
test "general branch A does not replace an entry of a forward chain with an alternate observer" {
    const chain = "f:\n    lda f_value\n    cmp #0\n    bne first\n    jmp done\nfirst:\n    lda f_value\n    cmp f_limit\n    beq second\n    jmp done\nsecond:\n    lda f_alias\n    rts\ndone:\n    rts\n";
    const input = try ordinaryFixture(chain);
    defer std.testing.allocator.free(input);
    const observed = try std.mem.concat(std.testing.allocator, u8, &.{ input, ".word first\n" });
    defer std.testing.allocator.free(observed);
    // The observed first label retains its real establishing LDA. Its outgoing
    // unique edge still has a complete independent root and may be optimized.
    try expectOrdinaryChanged(observed, 1);
    const result = try rewriteOrdinary(std.testing.allocator, observed);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "first:\n    lda f_value\n") != null);
}
test "general branch A chain allocation failures retain all owners of proof arrays" {
    const body = "f:\n    lda f_value\n    cmp #0\n    bne first\n    jmp done\nfirst:\n    lda f_value\n    cmp f_limit\n    bne second\n    jmp done\nsecond:\n    lda f_alias\n    rts\ndone:\n    rts\n";
    const input = try ordinaryFixture(body);
    defer std.testing.allocator.free(input);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, bytes: []const u8) !void {
            const result = rewriteOrdinary(allocator, bytes) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => return err,
            };
            defer allocator.free(result.assembly);
            try std.testing.expectEqual(@as(usize, 2), result.stats.reloads_replaced);
        }
    }.run, .{input});
}

test "general branch A pins ordinary direct compare roots against backward legacy candidates" {
    const body = "unreachable:\n    rts\nf:\nfor_0_body:\n    lda f_alias\n    cmp f_limit\n    bcc later_header\n    jmp done\nlater_header:\n    lda f_for_0_index\n    cmp #9\n    bcc for_0_body\n    jmp done\ndone:\n    rts\n";
    const input = try std.mem.concat(std.testing.allocator, u8, &.{ "* = $2000\n", code_begin, body, code_end, "* = $c100\n", frame_begin, "f_for_0_index:\nf_alias:\n.byte 0\nf_limit:\n.byte 0\n", frame_end });
    defer std.testing.allocator.free(input);
    const result = try rewriteOrdinary(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqual(@as(usize, 0), result.stats.reloads_replaced);
    try std.testing.expectEqualStrings(input, result.assembly);
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "for_0_body:\n    lda f_alias\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "later_header:\n    lda f_for_0_index\n") != null);
}

test "general branch A separate modes retain legacy results and protect earlier invocation roots" {
    const input = try fixture(std.testing.allocator, code);
    defer std.testing.allocator.free(input);
    const untouched = try rewriteOrdinary(std.testing.allocator, input);
    defer std.testing.allocator.free(untouched.assembly);
    try std.testing.expectEqualStrings(input, untouched.assembly);
    const first = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(first.assembly);
    const later = try rewriteOrdinary(std.testing.allocator, first.assembly);
    defer std.testing.allocator.free(later.assembly);
    try std.testing.expectEqual(@as(usize, 0), later.stats.reloads_replaced);
    try std.testing.expectEqualStrings(first.assembly, later.assembly);
    try std.testing.expect(std.mem.indexOf(u8, later.assembly, "for_0_top:\n    lda f_for_0_index\n") != null);
}
