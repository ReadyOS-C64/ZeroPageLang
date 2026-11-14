const std = @import("std");
const machine = @import("instruction.zig");

pub const Consumer = enum { bcc, bcs };
/// Original zero-based raw line indices. Names borrow the analyzed assembly.
/// A candidate is a shape description, NEVER authorization to remove code.
pub const Candidate = struct {
    high_compare_line: usize,
    branch_line: usize,
    low_compare_line: usize,
    join_line: usize,
    consumer_line: usize,
    high_value: u8,
    join: []const u8,
    owner: []const u8,
    consumer: Consumer,
};
pub const Plan = struct {
    candidates: []Candidate,

    /// Frees the candidate array only; the caller retains the source buffer.
    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.candidates);
        self.* = .{ .candidates = &.{} };
    }
};
const Zone = enum { code, data, unsectioned };
const Node = struct {
    text: []const u8,
    line: usize,
    scope: usize,
    owner: []const u8,
    zone: Zone,
    instruction: ?machine.Instruction,
    label: ?[]const u8,
};
const Section = struct { owner: []const u8, kind: []const u8 };

fn empty() Plan {
    return .{ .candidates = &.{} };
}
fn identifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
fn labelName(text: []const u8) ?[]const u8 {
    if (text.len < 2 or text[text.len - 1] != ':' or (!std.ascii.isAlphabetic(text[0]) and text[0] != '_')) return null;
    const name = text[0 .. text.len - 1];
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
fn control(op: machine.Op) bool {
    return op == .jmp or op == .jsr or conditional(op);
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
fn tokens(text: []const u8, name: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (!identifierByte(text[index])) {
            index += 1;
            continue;
        }
        const start = index;
        while (index < text.len and identifierByte(text[index])) : (index += 1) {}
        if (std.ascii.eqlIgnoreCase(text[start..index], name)) count += 1;
    }
    return count;
}
fn references(nodes: []const Node, name: []const u8) usize {
    var count: usize = 0;
    for (nodes) |node| if (node.label == null) {
        count += tokens(node.text, name);
    };
    return count;
}
fn codeLabel(nodes: []const Node, index: usize) bool {
    if (nodes[index].zone == .code) return true;
    // Metadata emits no bytes: an alias immediately outside a section may
    // still name its first instruction. Follow every co-located label.
    var next = index + 1;
    while (next < nodes.len and nodes[next].label != null) : (next += 1) {}
    if (next == nodes.len) return false;
    const following = nodes[next];
    return following.zone == .code or following.instruction != null or
        std.mem.startsWith(u8, following.text, "*") or
        std.mem.startsWith(u8, following.text, ".logical") or std.mem.startsWith(u8, following.text, ".here");
}
fn codeAddressesUnobserved(nodes: []const Node) bool {
    // Any symbolic code-address exposure can observe the removed instruction's
    // bytes or an offset into it. Initially decline the complete plan. Ordinary
    // exact named control transfers are the only admitted code-label uses.
    for (nodes, 0..) |definition, index| {
        const name = definition.label orelse continue;
        if (!codeLabel(nodes, index)) continue;
        for (nodes) |node| {
            if (node.label != null) continue;
            // Mnemonics/directive names are not symbol references. A source
            // function named byte or word must not collide with .byte/.word;
            // their operands still expose code addresses and must be scanned.
            const reference_text = if (node.instruction != null or std.mem.startsWith(u8, node.text, "."))
                node.text[std.mem.indexOfAny(u8, node.text, " \t") orelse node.text.len ..]
            else
                node.text;
            if (tokens(reference_text, name) == 0) continue;
            const instruction = node.instruction orelse return false;
            if (!control(instruction.op) or instruction.operand != .direct or instruction.operand.direct.offset != 0 or
                !std.ascii.eqlIgnoreCase(instruction.operand.direct.name, name)) return false;
        }
    }
    return true;
}
fn controlsKnown(allocator: std.mem.Allocator, nodes: []const Node) !bool {
    var pending: std.ArrayList(usize) = .empty;
    defer pending.deinit(allocator);
    for (nodes) |node| if (node.instruction) |instruction| {
        if (instruction.op == .brk or instruction.op == .rti) return false;
        if (!control(instruction.op)) continue;
        if (instruction.operand != .direct or instruction.operand.direct.offset != 0) return false;
        const opcode_end = std.mem.indexOfAny(u8, node.text, " \t") orelse return false;
        const operand_text = std.mem.trim(u8, node.text[opcode_end..], " \t");
        if (!std.ascii.eqlIgnoreCase(operand_text, instruction.operand.direct.name)) return false;
        try pending.append(allocator, uniqueLabel(nodes, instruction.operand.direct.name) orelse return false);
    };
    // Compiler test hooks can be unsectioned. Their complete reachable path
    // must stay parsed code until RTS or an actual code-section entry.
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
        if (instruction.operand == .unknown) return false;
        if (instruction.op == .rts) continue;
        if (control(instruction.op)) {
            try pending.append(allocator, uniqueLabel(nodes, instruction.operand.direct.name).?);
            if (instruction.op == .jmp) continue;
        }
        try pending.append(allocator, index + 1);
    }
    return true;
}
fn internalJoin(name: []const u8) bool {
    const prefix = "cmp_word_";
    const suffix = "_done";
    if (name.len <= prefix.len + suffix.len or !std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix) or
        !std.ascii.eqlIgnoreCase(name[name.len - suffix.len ..], suffix)) return false;
    for (name[prefix.len .. name.len - suffix.len]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}
fn literal(inst: machine.Instruction, op: machine.Op) ?u8 {
    if (inst.op != op or inst.operand != .immediate) return null;
    const value = machine.integer(inst.operand.immediate) orelse return null;
    return std.math.cast(u8, value);
}

/// Detects shapes only. N/Z may still be live: callers MUST obtain a fresh CFG
/// proof on this exact buffer and revalidate the candidate before any edit.
/// No storage, liveness, deletion or performance authorization is returned.
pub fn analyze(allocator: std.mem.Allocator, assembly: []const u8) !Plan {
    if (std.mem.indexOf(u8, assembly, "; inline asm") != null) return empty();
    var nodes: std.ArrayList(Node) = .empty;
    defer nodes.deinit(allocator);
    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(allocator);
    var active: ?Section = null;
    var scope: usize = 0;
    var next_scope: usize = 0;
    var owner: []const u8 = "";
    var split = std.mem.splitScalar(u8, assembly, '\n');
    var line: usize = 0;
    while (split.next()) |raw| : (line += 1) {
        const text = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, text, "; zeropage_section_")) {
            const marker = section(text) orelse return empty();
            if (std.mem.startsWith(u8, text, "; zeropage_section_begin ")) {
                if (active != null) return empty();
                active = marker;
                if (std.mem.eql(u8, marker.kind, "code") and std.mem.startsWith(u8, marker.owner, "function:") and marker.owner.len > "function:".len) {
                    next_scope += 1;
                    scope = next_scope;
                    owner = marker.owner["function:".len..];
                } else {
                    scope = 0;
                    owner = "";
                }
            } else if (std.mem.startsWith(u8, text, "; zeropage_section_end ")) {
                const prior = active orelse return empty();
                if (!std.mem.eql(u8, marker.owner, prior.owner) or !std.mem.eql(u8, marker.kind, prior.kind)) return empty();
                active = null;
                scope = 0;
                owner = "";
            } else return empty();
            continue;
        }
        if (text.len == 0 or text[0] == ';') continue;
        const label = labelName(text);
        const instruction = machine.Instruction.parse(text);
        const zone: Zone = if (active) |current| (if (std.mem.eql(u8, current.kind, "code")) .code else .data) else .unsectioned;
        if (zone == .code and label == null and (instruction == null or instruction.?.operand == .unknown)) return empty();
        try nodes.append(allocator, .{ .text = text, .line = line, .scope = scope, .owner = owner, .zone = zone, .label = label, .instruction = instruction });
    }
    if (active != null or !try controlsKnown(allocator, nodes.items) or !codeAddressesUnobserved(nodes.items)) return empty();
    for (nodes.items, 0..) |high, index| {
        if (high.scope == 0 or index + 4 >= nodes.items.len) continue;
        const high_value = literal(high.instruction orelse continue, .cpx) orelse continue;
        const branch_node = nodes.items[index + 1];
        const low_node = nodes.items[index + 2];
        if (branch_node.scope != high.scope or low_node.scope != high.scope) continue;
        const branch = branch_node.instruction orelse continue;
        if (branch.op != .bne or branch.operand != .direct or branch.operand.direct.offset != 0 or !internalJoin(branch.operand.direct.name)) continue;
        if ((literal(low_node.instruction orelse continue, .cmp) orelse continue) != 0) continue;
        const join_index = uniqueLabel(nodes.items, branch.operand.direct.name) orelse continue;
        if (references(nodes.items, branch.operand.direct.name) != 1) continue;
        var alias_end = index + 3;
        var aliases_safe = true;
        var found_join = false;
        while (alias_end < nodes.items.len and nodes.items[alias_end].label != null) : (alias_end += 1) {
            const alias = nodes.items[alias_end];
            if (alias_end == join_index) found_join = true;
            if (alias.scope != high.scope or uniqueLabel(nodes.items, alias.label.?) == null or
                references(nodes.items, alias.label.?) != @as(usize, if (alias_end == join_index) 1 else 0)) aliases_safe = false;
        }
        if (!found_join or !aliases_safe or alias_end == nodes.items.len) continue;
        const consumer_node = nodes.items[alias_end];
        if (consumer_node.scope != high.scope) continue;
        const consumer = consumer_node.instruction orelse continue;
        if ((consumer.op != .bcc and consumer.op != .bcs) or consumer.operand != .direct or consumer.operand.direct.offset != 0) continue;
        const target = uniqueLabel(nodes.items, consumer.operand.direct.name) orelse continue;
        if (nodes.items[target].scope != high.scope) continue;
        try candidates.append(allocator, .{
            .high_compare_line = high.line,
            .branch_line = branch_node.line,
            .low_compare_line = low_node.line,
            .join_line = nodes.items[join_index].line,
            .consumer_line = consumer_node.line,
            .high_value = high_value,
            .join = nodes.items[join_index].label.?,
            .owner = high.owner,
            .consumer = if (consumer.op == .bcc) .bcc else .bcs,
        });
    }
    return .{ .candidates = try candidates.toOwnedSlice(allocator) };
}

const begin = "; zeropage_section_begin owner=function:f kind=code lifetime=static address=near\n";
const end = "; zeropage_section_end owner=function:f kind=code\n";
const body = "f:\n    cpx #4\n    bne cmp_word_9_done\n    cmp #0\ncmp_word_9_done:\n    bcc yes\n    jmp no\nyes:\n    lda #1\n    rts\nno:\n    lda #0\n    rts\n";
fn fixture(allocator: std.mem.Allocator, code: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ "* = $2000\n", begin, code, end });
}
fn expectCount(input: []const u8, count: usize) !void {
    var plan = try analyze(std.testing.allocator, input);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(count, plan.candidates.len);
}

test "word zero planner records raw lines borrowed ownership and a shape only" {
    const input = try fixture(std.testing.allocator, body);
    defer std.testing.allocator.free(input);
    var plan = try analyze(std.testing.allocator, input);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), plan.candidates.len);
    try std.testing.expectEqualDeep(Candidate{ .high_compare_line = 3, .branch_line = 4, .low_compare_line = 5, .join_line = 6, .consumer_line = 7, .high_value = 4, .join = "cmp_word_9_done", .owner = "f", .consumer = .bcc }, plan.candidates[0]);
    try std.testing.expect(@intFromPtr(plan.candidates[0].join.ptr) >= @intFromPtr(input.ptr));
    try std.testing.expect(@intFromPtr(plan.candidates[0].join.ptr) + plan.candidates[0].join.len <= @intFromPtr(input.ptr) + input.len);
    const live = try std.mem.replaceOwned(u8, std.testing.allocator, input, "    lda #1", "    php");
    defer std.testing.allocator.free(live);
    // N/Z are observed, but this planner intentionally does not decide liveness.
    try expectCount(live, 1);
}

test "word zero planner admits all byte high literals both carry consumers and zero spellings" {
    for (0..256) |high| {
        const compare = try std.fmt.allocPrint(std.testing.allocator, "cpx #{d}", .{high});
        defer std.testing.allocator.free(compare);
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, body, "cpx #4", compare);
        defer std.testing.allocator.free(changed);
        const input = try fixture(std.testing.allocator, changed);
        defer std.testing.allocator.free(input);
        var plan = try analyze(std.testing.allocator, input);
        defer plan.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), plan.candidates.len);
        try std.testing.expectEqual(high, plan.candidates[0].high_value);
    }
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, body, "bcc yes", "bcs yes");
    defer std.testing.allocator.free(changed);
    const hexadecimal = try std.mem.replaceOwned(u8, std.testing.allocator, changed, "cmp #0", "cmp #$00");
    defer std.testing.allocator.free(hexadecimal);
    const input = try fixture(std.testing.allocator, hexadecimal);
    defer std.testing.allocator.free(input);
    var plan = try analyze(std.testing.allocator, input);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(Consumer.bcs, plan.candidates[0].consumer);
}

test "word zero planner preserves comment gaps and unused co located aliases" {
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, body, "    cmp #0\ncmp_word_9_done:\n", "; before low\n\n    cmp #0\n; before join\nunused_before:\ncmp_word_9_done:\n; after join\nunused_after:\n");
    defer std.testing.allocator.free(changed);
    const input = try fixture(std.testing.allocator, changed);
    defer std.testing.allocator.free(input);
    try expectCount(input, 1);
    for ([_][]const u8{ "    jmp unused_before\n", "    jsr unused_after\n", "unused_after:\n" }) |extra| {
        const amended = try std.mem.concat(std.testing.allocator, u8, &.{ input, extra });
        defer std.testing.allocator.free(amended);
        try expectCount(amended, 0);
    }
}

test "word zero planner excludes intervening entries changed operands and noncarry consumers" {
    for ([_][2][]const u8{
        .{ "    bne cmp_word_9_done", "bypass:\n    bne cmp_word_9_done" }, .{ "    cmp #0", "bypass:\n    cmp #0" },
        .{ "cpx #4", "cpx #256" },                                          .{ "cpx #4", "cpx #<yes" },
        .{ "cpx #4", "cpx high" },                                          .{ "cmp #0", "cmp #1" },
        .{ "cmp #0", "cmp low" },                                           .{ "cmp #0", "lda #0" },
        .{ "cmp #0", "nop\n    cmp #0" },                                   .{ "cmp_word_9_done", "ordinary_join" },
        .{ "bcc yes", "beq yes" },                                          .{ "bcc yes", "bne yes" },
        .{ "bcc yes", "bmi yes" },                                          .{ "bcc yes", "php\n    bcc yes" },
        .{ "bne cmp_word_9_done", "beq cmp_word_9_done" },
    }) |change| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, body, change[0], change[1]);
        defer std.testing.allocator.free(changed);
        const input = try fixture(std.testing.allocator, changed);
        defer std.testing.allocator.free(input);
        try expectCount(input, 0);
    }
}

test "word zero planner rejects extra join uses and all symbolic code address observations" {
    const original = try fixture(std.testing.allocator, body);
    defer std.testing.allocator.free(original);
    for ([_][]const u8{
        "    bne CMP_WORD_9_DONE\n", "    jsr cmp_word_9_done\n", "    lda #<cmp_word_9_done\n", ".word cmp_word_9_done\n", "alias = cmp_word_9_done+1\n",
        ".word f+2\n",               "    lda f+2\n",             "    lda #>yes\n",             "    ldx no\n",            "unknown f\n",
        "CMP_WORD_9_DONE:\n",        "YES:\n",
    }) |extra| {
        const input = try std.mem.concat(std.testing.allocator, u8, &.{ original, extra });
        defer std.testing.allocator.free(input);
        try expectCount(input, 0);
    }
    const outside_alias = try std.mem.concat(std.testing.allocator, u8, &.{ "outside_code_alias:\n", original, ".word outside_code_alias+2\n" });
    defer std.testing.allocator.free(outside_alias);
    try expectCount(outside_alias, 0); // The origin cannot prove a distinct data address.
    const alias_at_section = try std.mem.replaceOwned(u8, std.testing.allocator, outside_alias, "* = $2000\n", "");
    defer std.testing.allocator.free(alias_at_section);
    try expectCount(alias_at_section, 0);
}

test "word zero planner treats assembler symbol identity case insensitively" {
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, body, "bne cmp_word_9_done", "bne CMP_WORD_9_DONE");
    defer std.testing.allocator.free(changed);
    const input = try fixture(std.testing.allocator, changed);
    defer std.testing.allocator.free(input);
    try expectCount(input, 1);
}

test "word zero planner distinguishes symbol references from mnemonic and directive names" {
    for ([_][]const u8{ "byte", "word", "cpx" }) |name| {
        const renamed = try std.mem.replaceOwned(u8, std.testing.allocator, body, "f:\n", "entry:\n");
        defer std.testing.allocator.free(renamed);
        const label = try std.fmt.allocPrint(std.testing.allocator, "{s}:\n", .{name});
        defer std.testing.allocator.free(label);
        const code = try std.mem.replaceOwned(u8, std.testing.allocator, renamed, "entry:\n", label);
        defer std.testing.allocator.free(code);
        const input = try std.mem.concat(std.testing.allocator, u8, &.{ ".byte 0\n.word 0\n", begin, code, end });
        defer std.testing.allocator.free(input);
        try expectCount(input, 1);
        const observation = try std.fmt.allocPrint(std.testing.allocator, "{s}.word {s}+2\n", .{ input, name });
        defer std.testing.allocator.free(observation);
        try expectCount(observation, 0);
    }
}

test "word zero planner declines unknown numeric offset indirect and unresolved control globally" {
    const original = try fixture(std.testing.allocator, body);
    defer std.testing.allocator.free(original);
    for ([_][]const u8{ "jmp $2000\n", "jsr $ffd2\n", "jmp f+1\n", "bne yes+0\n", "jmp (pointer)\n", "bne missing\n", "brk\n", "rti\n" }) |extra| {
        const input = try std.mem.concat(std.testing.allocator, u8, &.{ original, extra });
        defer std.testing.allocator.free(input);
        try expectCount(input, 0);
    }
}

test "word zero planner validates unsectioned helper paths and rejects code in data" {
    const called = try std.mem.replaceOwned(u8, std.testing.allocator, body, "f:\n", "f:\n    jsr helper\n");
    defer std.testing.allocator.free(called);
    const original = try fixture(std.testing.allocator, called);
    defer std.testing.allocator.free(original);
    for ([_]struct { tail: []const u8, count: usize }{
        .{ .tail = "helper:\n    rts\n", .count = 1 },
        .{ .tail = "helper:\n    beq helper_end\n    nop\nhelper_end:\n    rts\n", .count = 1 },
        .{ .tail = "helper:\n    .byte $60\n", .count = 0 },
        .{ .tail = "helper:\n    nop\n", .count = 0 },
        .{ .tail = "helper:\n    bne helper_end\n    .byte $60\nhelper_end:\n    rts\n", .count = 0 },
        .{ .tail = "; zeropage_section_begin owner=runtime kind=rodata\nhelper:\n    rts\n; zeropage_section_end owner=runtime kind=rodata\n", .count = 0 },
        .{ .tail = "; zeropage_section_begin owner=runtime kind=code\nhelper:\n    .byte $60\n; zeropage_section_end owner=runtime kind=code\n", .count = 0 },
    }) |case| {
        const input = try std.mem.concat(std.testing.allocator, u8, &.{ original, case.tail });
        defer std.testing.allocator.free(input);
        try expectCount(input, case.count);
    }
}

test "word zero planner requires source function ownership balanced sections and same scope" {
    const original = try fixture(std.testing.allocator, body);
    defer std.testing.allocator.free(original);
    for ([_][2][]const u8{
        .{ "owner=function:f", "owner=runtime" },                                            .{ "kind=code", "kind=static_frame" },
        .{ end, "" },                                                                        .{ "cmp_word_9_done:\n", end ++ begin ++ "cmp_word_9_done:\n" },
        .{ "yes:\n", end ++ "; zeropage_section_begin owner=function:g kind=code\nyes:\n" }, .{ "    cmp #0", "    .byte $ea\n    cmp #0" },
        .{ "    cmp #0", "    madeup text\n    cmp #0" },
    }) |change| {
        const input = try std.mem.replaceOwned(u8, std.testing.allocator, original, change[0], change[1]);
        defer std.testing.allocator.free(input);
        try expectCount(input, 0);
    }
    const naked = body;
    try expectCount(naked, 0);
}

test "word zero planner rejects genuinely balanced cross function joins and consumers" {
    const target_other_function = begin ++
        "f:\ncpx #4\nbne cmp_word_9_done\ncmp #0\ncmp_word_9_done:\nbcc g\nrts\n" ++ end ++
        "; zeropage_section_begin owner=function:g kind=code\ng:\nlda #1\nrts\n; zeropage_section_end owner=function:g kind=code\n";
    try expectCount(target_other_function, 0);
    const join_other_function = begin ++ "f:\ncpx #4\nbne cmp_word_9_done\ncmp #0\n" ++ end ++
        "; zeropage_section_begin owner=function:g kind=code\ncmp_word_9_done:\nbcc yes\nrts\nyes:\nlda #1\nrts\n; zeropage_section_end owner=function:g kind=code\n";
    try expectCount(join_other_function, 0);
}

test "word zero planner declines retained ASM anywhere and keeps data labels unobserved by control" {
    const original = try fixture(std.testing.allocator, body);
    defer std.testing.allocator.free(original);
    const asm_input = try std.mem.concat(std.testing.allocator, u8, &.{ original, "; inline asm from ZeroPage line 1\nnop\n; end inline asm\n" });
    defer std.testing.allocator.free(asm_input);
    try expectCount(asm_input, 0);
    const data = try std.mem.concat(std.testing.allocator, u8, &.{ ".word basic_next\nbasic_next:\n.word 0\n", original, "; zeropage_section_begin owner=function:f kind=static_frame\nf_value:\n.word 0\n; zeropage_section_end owner=function:f kind=static_frame\n" });
    defer std.testing.allocator.free(data);
    try expectCount(data, 1);
}

test "word zero planner records multiple shapes deterministically without editing source" {
    const second = try std.mem.replaceOwned(u8, std.testing.allocator, body, "cmp_word_9_done", "cmp_word_10_done");
    defer std.testing.allocator.free(second);
    const renamed_yes = try std.mem.replaceOwned(u8, std.testing.allocator, second, "yes", "second_yes");
    defer std.testing.allocator.free(renamed_yes);
    const renamed_no = try std.mem.replaceOwned(u8, std.testing.allocator, renamed_yes, "no", "second_no");
    defer std.testing.allocator.free(renamed_no);
    const without_function_label = renamed_no[3..];
    const combined = try std.mem.concat(std.testing.allocator, u8, &.{ body, without_function_label });
    defer std.testing.allocator.free(combined);
    const input = try fixture(std.testing.allocator, combined);
    defer std.testing.allocator.free(input);
    const saved = try std.testing.allocator.dupe(u8, input);
    defer std.testing.allocator.free(saved);
    var first = try analyze(std.testing.allocator, input);
    defer first.deinit(std.testing.allocator);
    var again = try analyze(std.testing.allocator, input);
    defer again.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), first.candidates.len);
    try std.testing.expectEqualDeep(first.candidates, again.candidates);
    try std.testing.expect(first.candidates[0].branch_line < first.candidates[1].branch_line);
    try std.testing.expectEqualStrings(saved, input);
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    const input = try fixture(allocator, body);
    defer allocator.free(input);
    var plan = try analyze(allocator, input);
    defer plan.deinit(allocator);
    const rejected = try std.mem.concat(allocator, u8, &.{ input, "jmp missing\n" });
    defer allocator.free(rejected);
    var declined = try analyze(allocator, rejected);
    defer declined.deinit(allocator);
}
test "word zero planner releases partial parsed controls and candidate arrays on allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}
