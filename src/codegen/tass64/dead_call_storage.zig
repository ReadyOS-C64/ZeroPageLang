const std = @import("std");
const storage = @import("storage_model.zig");
const machine = @import("instruction.zig");

pub const Stats = struct { slots_pruned: usize = 0, bytes_pruned: usize = 0 };
pub const Result = struct { assembly: []u8, stats: Stats };
pub const Store = struct { line: usize, byte_offset: u1 };
pub const Cell = struct {
    label: []const u8,
    label_line: usize,
    word_line: usize,
    read_mask: u2,
    reference_count: usize,
    stores: []Store,
};
/// Arrays are owned; line text and labels borrow the original input assembly.
/// Cells have passed the exact canonical R26 ownership/alias/layout/RAM gates.
pub const Plan = struct {
    lines: [][]const u8 = &.{},
    cells: []Cell = &.{},
    family_safe: bool = false,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        for (self.cells) |cell| if (cell.stores.len != 0) allocator.free(cell.stores);
        if (self.cells.len != 0) allocator.free(self.cells);
        if (self.lines.len != 0) allocator.free(self.lines);
        self.* = .{};
    }
};
const Section = struct {
    owner: []const u8,
    kind: []const u8,

    fn scratch(self: Section) bool {
        return std.mem.eql(u8, self.owner, "compiler") and std.mem.eql(u8, self.kind, "scratch");
    }
};
const Candidate = struct { name: []const u8, label_line: usize, word_line: usize, section_start: usize };

fn trim(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r");
}
fn symbolByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
fn labelName(text: []const u8) ?[]const u8 {
    if (text.len < 2 or text[text.len - 1] != ':') return null;
    const name = text[0 .. text.len - 1];
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return null;
    for (name) |byte| if (!symbolByte(byte)) return null;
    return name;
}
fn callArgument(name: []const u8) bool {
    const prefix = "zeropage_call_arg_";
    if (!std.mem.startsWith(u8, name, prefix) or name.len == prefix.len) return false;
    for (name[prefix.len..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}
fn callArgumentInsensitive(name: []const u8) bool {
    const prefix = "zeropage_call_arg_";
    if (name.len <= prefix.len or !std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix)) return false;
    for (name[prefix.len..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}
fn section(text: []const u8) ?Section {
    var owner: ?[]const u8 = null;
    var kind: ?[]const u8 = null;
    var fields = std.mem.tokenizeAny(u8, text, " \t");
    while (fields.next()) |field| {
        if (std.mem.startsWith(u8, field, "owner=")) {
            if (owner != null or field.len == "owner=".len) return null;
            owner = field["owner=".len..];
        } else if (std.mem.startsWith(u8, field, "kind=")) {
            if (kind != null or field.len == "kind=".len) return null;
            kind = field["kind=".len..];
        }
    }
    return .{ .owner = owner orelse return null, .kind = kind orelse return null };
}
fn counts(lines: []const []const u8, name: []const u8) struct { definitions: usize, uses: usize } {
    var definitions: usize = 0;
    var uses: usize = 0;
    for (lines) |raw| {
        const text = trim(raw);
        if (text.len == 0 or text[0] == ';') continue;
        // The pinned assembler is case-insensitive without -C, which the
        // compiler does not request. Case variants must pin the same symbol.
        if (labelName(text)) |defined| if (std.ascii.eqlIgnoreCase(name, defined)) {
            definitions += 1;
            continue;
        };
        // Inspect operands, data, aliases and unknown forms, including quoted
        // text conservatively. Similar identifier substrings do not alias.
        var index: usize = 0;
        while (index < text.len) {
            if (!symbolByte(text[index])) {
                index += 1;
                continue;
            }
            const start = index;
            while (index < text.len and symbolByte(text[index])) : (index += 1) {}
            if (std.ascii.eqlIgnoreCase(name, text[start..index])) uses += 1;
        }
    }
    return .{ .definitions = definitions, .uses = uses };
}
fn alias(model: *const storage.Model, name: []const u8, location: storage.Location) bool {
    var labels = model.labels.iterator();
    while (labels.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, name)) continue;
        if (entry.value_ptr.frame == location.frame and entry.value_ptr.offset == location.offset) return true;
    }
    return false;
}
fn sameDomain(model: *const storage.Model, location: storage.Location) bool {
    const domain = model.frames.items[location.frame].domain;
    for (model.frames.items) |frame| if (frame.bytes != 0 and frame.domain != domain) return false;
    return true;
}
fn remapped(lines: []const []const u8, after: usize) bool {
    for (lines[after + 1 ..]) |raw| {
        const text = trim(raw);
        if (text.len == 0 or text[0] == ';') continue;
        if (text[0] == '*') return true;
        for ([_][]const u8{ ".logical", ".here" }) |directive| {
            if (text.len >= directive.len and std.ascii.eqlIgnoreCase(text[0..directive.len], directive)) return true;
        }
    }
    return false;
}
fn unchanged(allocator: std.mem.Allocator, assembly: []const u8) !Result {
    return .{ .assembly = try allocator.dupe(u8, assembly), .stats = .{} };
}
fn byteMemory(op: machine.Op) bool {
    return switch (op) {
        .lda, .ldx, .ldy, .sta, .stx, .sty, .adc, .sbc, .@"and", .ora, .eor, .cmp, .cpx, .cpy, .inc, .dec, .asl, .lsr, .rol, .ror, .bit => true,
        else => false,
    };
}
const Canonical = struct { name: []const u8, location: storage.Location };
fn canonical(model: *const storage.Model, name: []const u8) ?Canonical {
    var labels = model.labels.iterator();
    while (labels.next()) |entry| if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) {
        return .{ .name = entry.key_ptr.*, .location = entry.value_ptr.* };
    };
    return null;
}
// A frame can contain MANY adjacent objects. Model.resolve alone bounds the
// frame, so other_scratch+2 could still reach a neighboring capture. Stop at the
// next distinct label offset, conservatively treating aggregate roots as narrow.
fn extent(model: *const storage.Model, base: storage.Location) u32 {
    var upper = model.frames.items[base.frame].bytes;
    var labels = model.labels.iterator();
    while (labels.next()) |entry| {
        const location = entry.value_ptr.*;
        if (location.frame == base.frame and location.offset > base.offset) upper = @min(upper, location.offset);
    }
    return upper - base.offset;
}
fn withinObject(model: *const storage.Model, base: Canonical, offset: i32) bool {
    return offset >= 0 and @as(u64, @intCast(offset)) < extent(model, base.location) and
        model.resolve(.{ .name = base.name, .offset = offset }, 1) != null;
}
fn directByte(instruction: ?machine.Instruction, name: []const u8) ?machine.Symbol {
    const inst = instruction orelse return null;
    if (!byteMemory(inst.op) or inst.operand != .direct or !std.ascii.eqlIgnoreCase(inst.operand.direct.name, name)) return null;
    return inst.operand.direct;
}
fn familySafe(model: *const storage.Model, lines: []const []const u8, candidates: []const Candidate) bool {
    for (candidates) |candidate| if (counts(lines, candidate.name).definitions != 1) return false;
    for (lines) |raw| {
        const text = trim(raw);
        if (text.len == 0 or text[0] == ';' or labelName(text) != null) continue;
        const instruction = machine.Instruction.parse(text);
        var index: usize = 0;
        while (index < text.len) {
            if (!symbolByte(text[index])) {
                index += 1;
                continue;
            }
            const start = index;
            while (index < text.len and symbolByte(text[index])) : (index += 1) {}
            const token = text[start..index];
            if (callArgumentInsensitive(token)) {
                var defined = false;
                for (candidates) |candidate| if (std.ascii.eqlIgnoreCase(candidate.name, token)) {
                    defined = true;
                };
                if (!defined) return false;
                const reference = directByte(instruction, token) orelse return false;
                if (reference.offset < 0 or reference.offset > 1) return false;
                const base = canonical(model, token) orelse return false;
                if (!std.mem.eql(u8, model.frames.items[base.location.frame].owner, "compiler:scratch") or !withinObject(model, base, reference.offset)) return false;
            } else if (canonical(model, token)) |base| {
                if (directByte(instruction, token)) |reference| {
                    if (!withinObject(model, base, reference.offset)) return false;
                    continue;
                }
                // A compiler-scratch address/index/indirect/unknown escape can
                // reach neighboring captures even when their names never occur.
                if (std.mem.eql(u8, model.frames.items[base.location.frame].owner, "compiler:scratch")) return false;
                // Ordinary source object pointer/index expressions retain their
                // existing object-validity contract; no private-scratch address
                // is a public ABI. Explicit out-of-object direct accesses above
                // are nevertheless rejected, including source-frame neighbors.
                if (instruction) |inst| switch (inst.operand) {
                    .immediate => continue,
                    .indexed => |reference| if (std.ascii.eqlIgnoreCase(reference.base.name, token) and withinObject(model, base, reference.base.offset)) {
                        continue;
                    },
                    else => {},
                };
                return false;
            }
        }
    }
    return true;
}

/// Analyze the unchanged complete pre-ZP input, including every original use.
/// Both pruning and dead-store selection consume this one safety proof; neither
/// can hide an unsafe use by deleting it before constructing the other facts.
pub fn analyze(allocator: std.mem.Allocator, assembly: []const u8) !Plan {
    if (std.mem.indexOf(u8, assembly, "; inline asm") != null) return .{};
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var split = std.mem.splitScalar(u8, assembly, '\n');
    while (split.next()) |raw| try lines.append(allocator, raw);
    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(allocator);
    var active: ?Section = null;
    var active_start: usize = 0;
    for (lines.items, 0..) |raw, index| {
        const text = trim(raw);
        if (std.mem.startsWith(u8, text, "; zeropage_section_")) {
            const marker = section(text) orelse return .{};
            if (std.mem.startsWith(u8, text, "; zeropage_section_begin ")) {
                if (active != null) return .{};
                active = marker;
                active_start = index;
            } else if (std.mem.startsWith(u8, text, "; zeropage_section_end ")) {
                const prior = active orelse return .{};
                if (!std.mem.eql(u8, prior.owner, marker.owner) or !std.mem.eql(u8, prior.kind, marker.kind)) return .{};
                active = null;
            } else return .{};
            continue;
        }
        const current = active orelse continue;
        if (!current.scratch()) continue;
        const name = labelName(text) orelse continue;
        if (!callArgument(name)) continue;
        var next = index + 1;
        while (next < lines.items.len) : (next += 1) {
            const following = trim(lines.items[next]);
            if (following.len == 0) continue;
            if (following[0] == ';') {
                // Section markers are semantic boundaries, not slot trivia.
                if (std.mem.startsWith(u8, following, "; zeropage_section_")) break;
                continue;
            }
            if (std.mem.eql(u8, following, ".word 0")) try candidates.append(allocator, .{ .name = name, .label_line = index, .word_line = next, .section_start = active_start });
            break;
        }
    }
    if (active != null or candidates.items.len == 0) return .{};
    var model = storage.Model.init(allocator);
    defer model.deinit();
    try model.collect(assembly);
    if (!familySafe(&model, lines.items, candidates.items)) return .{};
    var cells: std.ArrayList(Cell) = .empty;
    errdefer {
        for (cells.items) |cell| if (cell.stores.len != 0) allocator.free(cell.stores);
        cells.deinit(allocator);
    }
    for (candidates.items) |candidate| {
        const references = counts(lines.items, candidate.name);
        if (references.definitions != 1) continue;
        const location = model.resolve(.{ .name = candidate.name }, 2) orelse continue;
        if (!std.mem.eql(u8, model.frames.items[location.frame].owner, "compiler:scratch") or alias(&model, candidate.name, location) or
            !sameDomain(&model, location) or remapped(lines.items, candidate.section_start)) continue;
        var stores: std.ArrayList(Store) = .empty;
        defer stores.deinit(allocator);
        var read_mask: u2 = 0;
        for (lines.items, 0..) |raw, line_index| {
            const instruction = machine.Instruction.parse(trim(raw)) orelse continue;
            const reference = directByte(instruction, candidate.name) orelse continue;
            // familySafe already proved every symbolic use lies in byte 0/1.
            if (reference.offset < 0 or reference.offset > 1) unreachable;
            const offset: u1 = @intCast(reference.offset);
            switch (instruction.effects().memory) {
                .read, .read_write => read_mask |= @as(u2, 1) << offset,
                .write => {
                    // Only these NMOS stores write without reading the cell.
                    if (instruction.op != .sta and instruction.op != .stx and instruction.op != .sty) unreachable;
                    try stores.append(allocator, .{ .line = line_index, .byte_offset = offset });
                },
                .none, .stack => unreachable,
            }
        }
        const owned_stores = try stores.toOwnedSlice(allocator);
        errdefer allocator.free(owned_stores);
        try cells.append(allocator, .{
            .label = candidate.name,
            .label_line = candidate.label_line,
            .word_line = candidate.word_line,
            .read_mask = read_mask,
            .reference_count = references.uses,
            .stores = owned_stores,
        });
    }
    const owned_lines = try lines.toOwnedSlice(allocator);
    errdefer allocator.free(owned_lines);
    return .{ .lines = owned_lines, .cells = try cells.toOwnedSlice(allocator), .family_safe = true };
}

/// Preserve the accepted R26 rewrite API/output: only zero-reference words are
/// pruned. The shared analysis additionally supplies facts for dead-store use.
pub fn rewrite(allocator: std.mem.Allocator, assembly: []const u8) !Result {
    var plan = try analyze(allocator, assembly);
    defer plan.deinit(allocator);
    if (!plan.family_safe) return unchanged(allocator, assembly);
    const removed = try allocator.alloc(bool, plan.lines.len);
    defer allocator.free(removed);
    @memset(removed, false);
    var stats: Stats = .{};
    for (plan.cells) |cell| {
        if (cell.reference_count != 0) continue;
        removed[cell.label_line] = true;
        removed[cell.word_line] = true;
        stats.slots_pruned += 1;
        stats.bytes_pruned += 2;
    }
    if (stats.slots_pruned == 0) return unchanged(allocator, assembly);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (plan.lines, removed, 0..) |raw, drop, index| {
        if (drop) continue;
        try out.writer.writeAll(raw);
        if (index + 1 < plan.lines.len) try out.writer.writeByte('\n');
    }
    return .{ .assembly = try out.toOwnedSlice(), .stats = stats };
}

const begin = "; zeropage_section_begin owner=compiler kind=scratch lifetime=static address=near\n";
const end = "; zeropage_section_end owner=compiler kind=scratch\n";
fn fixture(allocator: std.mem.Allocator, definitions: []const u8, uses: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ "* = $2000\n", uses, "\n", begin, definitions, end });
}
fn expectKept(definitions: []const u8, uses: []const u8) !void {
    const input = try fixture(std.testing.allocator, definitions, uses);
    defer std.testing.allocator.free(input);
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualDeep(Stats{}, result.stats);
    try std.testing.expectEqualStrings(input, result.assembly);
}
test "dead call storage prunes gaps and an empty family while preserving other cells and metadata" {
    const input = try fixture(std.testing.allocator, "zeropage_call_arg_0:\n.word 0\nzeropage_call_arg_1:\n.word 0\nzeropage_call_arg_2:\n; keep provenance\n.word 0\nother:\n.word 0\n", "lda zeropage_call_arg_1\nlda zeropage_call_arg_0_extra");
    defer std.testing.allocator.free(input);
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualDeep(Stats{ .slots_pruned = 2, .bytes_pruned = 4 }, result.stats);
    const expected = try fixture(std.testing.allocator, "zeropage_call_arg_1:\n.word 0\n; keep provenance\nother:\n.word 0\n", "lda zeropage_call_arg_1\nlda zeropage_call_arg_0_extra");
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result.assembly);
    const only = try fixture(std.testing.allocator, "zeropage_call_arg_0:\n.word 0\nzeropage_call_arg_9:\n.word 0\n", "");
    defer std.testing.allocator.free(only);
    const empty = try rewrite(std.testing.allocator, only);
    defer std.testing.allocator.free(empty.assembly);
    try std.testing.expectEqualDeep(Stats{ .slots_pruned = 2, .bytes_pruned = 4 }, empty.stats);
    try std.testing.expectEqualStrings("* = $2000\n\n" ++ begin ++ end, empty.assembly);
}
test "dead call storage keeps every symbolic read write offset address data and unknown use" {
    for ([_][]const u8{
        "lda zeropage_call_arg_0",       "sta zeropage_call_arg_0+1", "lda zeropage_call_arg_0,x",     "lda (zeropage_call_arg_0),y",
        "lda #<zeropage_call_arg_0",     ".word zeropage_call_arg_0", "alias = zeropage_call_arg_0+1", "unknown zeropage_call_arg_0",
        ".text \"zeropage_call_arg_0\"", "LDA ZEROPAGE_CALL_ARG_0",   ".word ZeroPage_Call_Arg_0+1",
    }) |use| try expectKept("zeropage_call_arg_0:\n.word 0\n", use);
}
test "dead call storage pins the whole family when another capture can reach a neighbor" {
    const definitions = "zeropage_call_arg_0:\n.word 0\nzeropage_call_arg_1:\n.word 0\n";
    for ([_][]const u8{
        "lda zeropage_call_arg_0+2",     "sta zeropage_call_arg_1-1",     "lda #<zeropage_call_arg_0",
        "lda zeropage_call_arg_0,x",     "lda (zeropage_call_arg_0),y",   ".word zeropage_call_arg_0",
        "pointer = zeropage_call_arg_0", "unknown zeropage_call_arg_0+3", "LDA ZEROPAGE_CALL_ARG_0+2",
    }) |use| try expectKept(definitions, use);
    // An ordinary high-byte access stays within capture zero; it must not pin
    // truly unused capture one merely because the family is globally shared.
    const input = try fixture(std.testing.allocator, definitions, "lda zeropage_call_arg_0+1");
    defer std.testing.allocator.free(input);
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualDeep(Stats{ .slots_pruned = 1, .bytes_pruned = 2 }, result.stats);
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "zeropage_call_arg_0:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "zeropage_call_arg_1:") == null);
}
test "dead call storage detects scratch aliases and noncapture object offset escapes" {
    const definitions = "other_scratch:\nalias:\n.word 0\nzeropage_call_arg_0:\n.word 0\n";
    for ([_][]const u8{
        "lda other_scratch+2", "lda alias+2",           "lda #<alias",         "lda other_scratch,x", "lda (alias),y",
        ".word alias",         "unknown OTHER_SCRATCH", "sta other_scratch-1",
    }) |use| try expectKept(definitions, use);
    const source_neighbor = "* = $2000\n; zeropage_section_begin owner=function:f kind=static_frame\nf_local:\n.word 0\n; zeropage_section_end owner=function:f kind=static_frame\nlda f_local+2\n";
    const input = try std.mem.concat(std.testing.allocator, u8, &.{ source_neighbor, begin, "zeropage_call_arg_0:\n.word 0\n", end });
    defer std.testing.allocator.free(input);
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualStrings(input, result.assembly);
    try std.testing.expectEqualDeep(Stats{}, result.stats);
}
test "dead call storage keeps aliases duplicate definitions malformed words and unknown layouts" {
    for ([_][]const u8{
        "alias:\nzeropage_call_arg_0:\n.word 0\n",                        "zeropage_call_arg_0:\nalias:\n.word 0\n",
        "zeropage_call_arg_0:\n.word 0\nzeropage_call_arg_0:\n.word 0\n", "zeropage_call_arg_0:\n.word 1\n",
        "zeropage_call_arg_0:\n.byte 0,0\n",                              "zeropage_call_arg_0:\n.word $0000\n",
        "zeropage_call_arg_0:\n.word 0,0\n",                              "zeropage_call_arg_0:\n.align 2\n.word 0\n",
        "zeropage_call_arg_0:\n.word 0\n.unknown 0\n",                    "zeropage_call_arg_0:\n.word 0\n* = $2000\nalias:\n.word 0\n",
    }) |definitions| try expectKept(definitions, "");
    try expectKept("zeropage_call_arg_0:\n.word 0\n", "zeropage_call_arg_0:\n.word 0");
    try expectKept("zeropage_call_arg_0:\n.word 0\n", "ZEROPAGE_CALL_ARG_0:\n.word 0");
    try expectKept("zeropage_call_arg_0:\n.word 0\n", "zeropage_call_arg_0 = $2000");
}
test "dead call storage leaves static public function noncanonical families and ASM untouched" {
    for ([_][]const u8{ "zeropage_call_arg_", "zeropage_call_arg_x", "zeropage_call_arg_0_extra", "zeropage_math_tmp" }) |name| {
        const definitions = try std.fmt.allocPrint(std.testing.allocator, "{s}:\n.word 0\n", .{name});
        defer std.testing.allocator.free(definitions);
        try expectKept(definitions, "");
    }
    try expectKept("zeropage_call_arg_0:\n.word 0\n", "; inline asm from ZeroPage line 1\nnop\n; end inline asm");
    const original = try fixture(std.testing.allocator, "zeropage_call_arg_0:\n.word 0\n", "");
    defer std.testing.allocator.free(original);
    for ([_][]const u8{ "owner=function:public kind=static_frame", "owner=function:public kind=code", "owner=compiler kind=data", "owner=module:main kind=rodata" }) |owner| {
        const input = try std.mem.replaceOwned(u8, std.testing.allocator, original, "owner=compiler kind=scratch", owner);
        defer std.testing.allocator.free(input);
        const result = try rewrite(std.testing.allocator, input);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqualStrings(input, result.assembly);
        try std.testing.expectEqualDeep(Stats{}, result.stats);
    }
}
test "dead call storage does not repair invalid section metadata or unknown origins" {
    const good = try fixture(std.testing.allocator, "zeropage_call_arg_0:\n.word 0\n", "");
    defer std.testing.allocator.free(good);
    const changes = [_][2][]const u8{
        .{ end, "" },               .{ begin, "" },                  .{ end, "; zeropage_section_end owner=compiler kind=data\n" },
        .{ begin, begin ++ begin }, .{ "* = $2000", "* = unknown" }, .{ "* = $2000", "* = $d000" },
    };
    for (changes) |change| {
        const input = try std.mem.replaceOwned(u8, std.testing.allocator, good, change[0], change[1]);
        defer std.testing.allocator.free(input);
        const result = try rewrite(std.testing.allocator, input);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqualStrings(input, result.assembly);
        try std.testing.expectEqualDeep(Stats{}, result.stats);
    }
}
test "dead call storage keeps cross domain frames and code only origin remaps" {
    const good = try fixture(std.testing.allocator, "zeropage_call_arg_0:\n.word 0\n", "");
    defer std.testing.allocator.free(good);
    for ([_][]const u8{ "* = $2000\nnop\n", ".logical $2000\nnop\n.here\n", ".here\n", ".LOGICAL $2000\nnop\n.HERE\n" }) |remap| {
        const input = try std.mem.concat(std.testing.allocator, u8, &.{ good, remap });
        defer std.testing.allocator.free(input);
        const result = try rewrite(std.testing.allocator, input);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqualStrings(input, result.assembly);
        try std.testing.expectEqualDeep(Stats{}, result.stats);
    }
    const earlier = "* = $2000\n; zeropage_section_begin owner=function:f kind=static_frame\nalias:\n.word 0\n; zeropage_section_end owner=function:f kind=static_frame\n";
    const input = try std.mem.concat(std.testing.allocator, u8, &.{ earlier, good });
    defer std.testing.allocator.free(input);
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualStrings(input, result.assembly);
    try std.testing.expectEqualDeep(Stats{}, result.stats);
}
test "dead call storage is idempotent and comments do not create symbol uses" {
    const input = try fixture(std.testing.allocator, "zeropage_call_arg_12:\n\n; zeropage_call_arg_12 debug note\n.word 0\n", "; zeropage_call_arg_12 comment");
    defer std.testing.allocator.free(input);
    const first = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(first.assembly);
    try std.testing.expectEqual(@as(usize, 1), first.stats.slots_pruned);
    const second = try rewrite(std.testing.allocator, first.assembly);
    defer std.testing.allocator.free(second.assembly);
    try std.testing.expectEqualDeep(Stats{}, second.stats);
    try std.testing.expectEqualStrings(first.assembly, second.assembly);
}
fn allocationFailure(allocator: std.mem.Allocator) !void {
    const input = try fixture(allocator, "zeropage_call_arg_0:\n.word 0\nzeropage_call_arg_1:\n.word 0\n", "lda zeropage_call_arg_1");
    defer allocator.free(input);
    const result = rewrite(allocator, input) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer allocator.free(result.assembly);
}
test "dead call storage allocation failures release canonical model candidates and output" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}
