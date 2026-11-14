const std = @import("std");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");

pub const Stats = struct { loads_forwarded: usize = 0, bytes_saved: usize = 0 };
pub const Result = struct { assembly: []u8, stats: Stats };

fn same(a: storage.Location, b: storage.Location) bool {
    return a.frame == b.frame and a.offset == b.offset;
}
// A RAM-under-ROM write does not establish the value returned by a visible ROM
// read. Require the WHOLE canonical frame to fit permanently visible RAM.
fn visible(model: storage.Model, instruction: machine.Instruction) ?storage.Location {
    if (instruction.operand != .direct) return null;
    const location = model.resolve(instruction.operand.direct, 1) orelse return null;
    const frame = model.frames.items[location.frame];
    if (frame.upper <= 0xa000 or (frame.lower >= 0xc000 and frame.upper <= 0xd000)) return location;
    return null;
}
fn preserveDisjoint(model: storage.Model, fact: ?storage.Location, written: storage.Location) ?storage.Location {
    const known = fact orelse return null;
    return if (model.disjoint(known, 1, written, 1)) known else null;
}

const State = struct {
    a_cell: ?storage.Location = null,
    x_cell: ?storage.Location = null,

    fn observe(self: *State, model: storage.Model, instruction: machine.Instruction) void {
        const effects = instruction.effects();
        if (effects.barrier) {
            self.* = .{};
            return;
        }
        const location = visible(model, instruction);
        const prior_a = self.a_cell;
        const prior_x = self.x_cell;
        switch (effects.memory) {
            .read => if (location == null) {
                // Unknown, indexed, indirect, numeric, volatile/MMIO and
                // ROM-shadow reads all revoke the memory identity facts.
                self.* = .{};
            },
            .write, .read_write => if (location) |written| {
                self.a_cell = preserveDisjoint(model, self.a_cell, written);
                self.x_cell = preserveDisjoint(model, self.x_cell, written);
                if (instruction.op == .sta) self.a_cell = written;
                if (instruction.op == .stx) self.x_cell = written;
            } else {
                self.* = .{};
            },
            .stack => self.* = .{},
            .none => {},
        }
        if (effects.writes & machine.a != 0) self.a_cell = switch (instruction.op) {
            .lda => location,
            .txa => prior_x,
            else => null,
        };
        if (effects.writes & machine.x != 0) self.x_cell = switch (instruction.op) {
            .ldx => location,
            .tax => prior_a,
            else => null,
        };
    }
};

/// Borrow complete pre-ZP assembly and return owned assembly. Replace only LDA
/// of a proved visible-RAM byte equal to X with TXA. Both produce identical A/NZ
/// and preserve X/Y/C/V/I/D/SP; no old-NZ relation or dead-flags guess is needed.
pub fn rewrite(allocator: std.mem.Allocator, assembly: []const u8) !Result {
    var model = storage.Model.init(allocator);
    defer model.deinit();
    try model.collect(assembly);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var split = std.mem.splitScalar(u8, assembly, '\n');
    while (split.next()) |line| try lines.append(allocator, line);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var state: State = .{};
    var active = false;
    var in_assembly = false;
    var stats: Stats = .{};
    for (lines.items, 0..) |raw, index| {
        const line = std.mem.trim(u8, raw, " \t\r");
        var forwarded = false;
        if (std.mem.startsWith(u8, line, "; inline asm")) {
            in_assembly = true;
            state = .{};
        } else if (in_assembly) {
            if (std.mem.eql(u8, line, "; end inline asm")) in_assembly = false;
            state = .{};
        } else {
            if (storage.sectionOwner(line, "code") != null) {
                active = true;
            } else if (std.mem.startsWith(u8, line, "; zeropage_section_")) {
                active = false;
            }
            if (active) {
                if (machine.Instruction.parse(line)) |instruction| {
                    if (instruction.op == .lda) {
                        if (visible(model, instruction)) |location| if (state.x_cell) |known| {
                            if (same(location, known)) {
                                forwarded = true;
                                state.observe(model, .{ .op = .txa, .operand = .none });
                                stats.loads_forwarded += 1;
                                // Canonical visible storage is >= $0200, before
                                // ZP allocation: LDA abs 3 bytes -> TXA 1 byte.
                                stats.bytes_saved += 2;
                            }
                        };
                    }
                    if (!forwarded) state.observe(model, instruction);
                } else state = .{}; // Labels, comments, blanks and unknowns.
            } else state = .{};
        }
        if (forwarded) try out.writer.writeAll("    txa") else try out.writer.writeAll(raw);
        if (index + 1 < lines.items.len) try out.writer.writeByte('\n');
    }
    return .{ .assembly = try out.toOwnedSlice(), .stats = stats };
}

fn fixture(allocator: std.mem.Allocator, code: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\* = $2000
        \\; zeropage_section_begin owner=function:f kind=code lifetime=static address=near
        \\f:
        \\{s}
        \\    rts
        \\; zeropage_section_end owner=function:f kind=code
        \\; zeropage_section_begin owner=function:f kind=static_frame lifetime=static address=near
        \\f_root:
        \\f_low:
        \\    .byte 0
        \\f_high:
        \\    .byte 0
        \\f_other:
        \\    .byte 0
        \\; zeropage_section_end owner=function:f kind=static_frame
        \\; zeropage_section_begin owner=compiler kind=scratch lifetime=static address=near
        \\zeropage_call_arg_0:
        \\    .word 0
        \\; zeropage_section_end owner=compiler kind=scratch
        \\
    , .{code});
}
fn expectCode(code: []const u8, expected: []const u8, count: usize) !void {
    const input = try fixture(std.testing.allocator, code);
    defer std.testing.allocator.free(input);
    const want = try fixture(std.testing.allocator, expected);
    defer std.testing.allocator.free(want);
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualStrings(want, result.assembly);
    try std.testing.expectEqualDeep(Stats{ .loads_forwarded = count, .bytes_saved = count * 2 }, result.stats);
}

test "X forwarding replaces capture high reload across disjoint formal low writes" {
    try expectCode("stx zeropage_call_arg_0+1\nsta f_low\nlda zeropage_call_arg_0+1\nsta f_high", "stx zeropage_call_arg_0+1\nsta f_low\n    txa\nsta f_high", 1);
}

test "X forwarding learns LDX and TAX and tracks canonical byte aliases" {
    try expectCode("ldx f_root+1\nlda f_low\nlda f_high", "ldx f_root+1\nlda f_low\n    txa", 1);
    try expectCode("lda f_root+1\ntax\nlda #9\nlda f_high", "lda f_root+1\ntax\nlda #9\n    txa", 1);
    try expectCode("sta f_root\ntax\nlda #9\nlda f_low", "sta f_root\ntax\nlda #9\n    txa", 1);
    try expectCode("ldx f_high\ntxa\ntax\nlda f_high", "ldx f_high\ntxa\ntax\n    txa", 1);
    try expectCode("stx f_root\nlda f_high", "stx f_root\nlda f_high", 0);
}

test "X forwarding invalidates aliases and preserves only proved disjoint memory facts" {
    for ([_][]const u8{ "sta f_root+1", "sty f_high", "inc f_high", "sta (pointer),y", "sta f_low,x", "sta $c100" }) |write| {
        const code = try std.fmt.allocPrint(std.testing.allocator, "stx f_high\n{s}\nlda f_high", .{write});
        defer std.testing.allocator.free(code);
        try expectCode(code, code, 0);
    }
    try expectCode("stx f_high\ninc f_low\nlda f_high", "stx f_high\ninc f_low\n    txa", 1);
    try expectCode("stx f_high\nsty f_low\nlda f_high", "stx f_high\nsty f_low\n    txa", 1);
    // A remembered the OLD RAM value. STX changes that byte, so a later TAX
    // cannot pretend the old A still identifies the overwritten cell.
    try expectCode("lda f_high\nstx f_high\ntax\nlda f_high", "lda f_high\nstx f_high\ntax\nlda f_high", 0);
    try expectCode("lda f_high\nsty f_high\ntax\nlda f_high", "lda f_high\nsty f_high\ntax\nlda f_high", 0);
    try expectCode("lda f_high\nstx f_low\ntax\nlda f_high", "lda f_high\nstx f_low\ntax\n    txa", 1);
}

test "X forwarding honors CPU clobbers calls branches labels comments and stack boundaries" {
    for ([_][]const u8{ "inx", "dex", "ldx #7", "tsx", "jsr helper", "jmp join\njoin:", "bne join\njoin:", "join:", "; provenance", "", "php", "pha\npla", "sed", "sei", "unknown text" }) |barrier| {
        const code = try std.fmt.allocPrint(std.testing.allocator, "stx f_high\n{s}\nlda f_high", .{barrier});
        defer std.testing.allocator.free(code);
        try expectCode(code, code, 0);
    }
    // Changed A/C/V/N/Z or Y do not destroy unchanged X's RAM identity.
    try expectCode("stx f_high\nlda #9\nclc\nadc #1\nldy #3\nlda f_high", "stx f_high\nlda #9\nclc\nadc #1\nldy #3\n    txa", 1);
    // A-clobber must not feed a stale TAX fact.
    try expectCode("lda f_high\nlda #7\ntax\nlda f_high", "lda f_high\nlda #7\ntax\nlda f_high", 0);
}

test "X forwarding never removes volatile unknown indexed or ROM shadow reads" {
    for ([_][]const u8{ "lda $dc04", "ldx $d012", "lda (pointer),y", "lda f_low,x", "bit $c100" }) |read| {
        const code = try std.fmt.allocPrint(std.testing.allocator, "stx f_high\n{s}\nlda f_high", .{read});
        defer std.testing.allocator.free(code);
        try expectCode(code, code, 0);
    }
    const input = try fixture(std.testing.allocator, "stx f_high\nlda f_high");
    defer std.testing.allocator.free(input);
    for ([_][]const u8{ "$a000", "$bfff", "$d000", "$e000" }) |origin| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, input, "$2000", origin);
        defer std.testing.allocator.free(changed);
        const result = try rewrite(std.testing.allocator, changed);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqualStrings(changed, result.assembly);
        try std.testing.expectEqualDeep(Stats{}, result.stats);
    }
    const ram = try std.mem.replaceOwned(u8, std.testing.allocator, input, "$2000", "$c000");
    defer std.testing.allocator.free(ram);
    const result = try rewrite(std.testing.allocator, ram);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqual(@as(usize, 1), result.stats.loads_forwarded);
}

test "X forwarding revokes both facts across unknown writes and cross domain aliases" {
    try expectCode("lda f_high\nsta $c100\ntax\nlda f_high", "lda f_high\nsta $c100\ntax\nlda f_high", 0);
    try expectCode("lda f_high\nldx $dc04\ntax\nlda f_high", "lda f_high\nldx $dc04\ntax\nlda f_high", 0);
    const input =
        \\* = $2000
        \\; zeropage_section_begin owner=function:f kind=code
        \\f:
        \\    stx first
        \\    sta second
        \\    lda first
        \\    rts
        \\; zeropage_section_end owner=function:f kind=code
        \\* = $3000
        \\; zeropage_section_begin owner=function:first kind=static_frame
        \\first:
        \\    .byte 0
        \\; zeropage_section_end owner=function:first kind=static_frame
        \\* = $3000
        \\; zeropage_section_begin owner=function:second kind=static_frame
        \\second:
        \\    .byte 0
        \\; zeropage_section_end owner=function:second kind=static_frame
        \\
    ;
    const result = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualStrings(input, result.assembly);
    try std.testing.expectEqualDeep(Stats{}, result.stats);
}

test "X forwarding visible RAM proof includes exclusive limits and rejects crossing frames" {
    const input = try fixture(std.testing.allocator, "stx f_high\nlda f_high");
    defer std.testing.allocator.free(input);
    const marker = "; zeropage_section_begin owner=function:f kind=static_frame";
    for ([_]struct { origin: []const u8, expected: usize }{
        .{ .origin = "$9ffd", .expected = 1 },
        .{ .origin = "$9ffe", .expected = 0 },
        .{ .origin = "$cffd", .expected = 1 },
        .{ .origin = "$cffe", .expected = 0 },
    }) |case| {
        const replacement = try std.fmt.allocPrint(std.testing.allocator, "* = {s}\n{s}", .{ case.origin, marker });
        defer std.testing.allocator.free(replacement);
        const relocated = try std.mem.replaceOwned(u8, std.testing.allocator, input, marker, replacement);
        defer std.testing.allocator.free(relocated);
        const result = try rewrite(std.testing.allocator, relocated);
        defer std.testing.allocator.free(result.assembly);
        try std.testing.expectEqual(case.expected, result.stats.loads_forwarded);
        if (case.expected == 0) try std.testing.expectEqualStrings(relocated, result.assembly);
    }
}

test "X forwarding skips ASM bodies resets both boundaries and can optimize outside" {
    const code = "stx f_high\nlda f_high\n; inline asm from ZeroPage line 1\nstx f_high\nlda f_high\n; zeropage_section_begin owner=function:forged kind=code\n; end inline asm\nlda f_high\nstx f_high\nlda f_high";
    const expected = "stx f_high\n    txa\n; inline asm from ZeroPage line 1\nstx f_high\nlda f_high\n; zeropage_section_begin owner=function:forged kind=code\n; end inline asm\nlda f_high\nstx f_high\n    txa";
    try expectCode(code, expected, 2);
}

test "X forwarding is limited to source code sections and is idempotent" {
    const outside = "* = $2000\nstx value\nlda value\n; zeropage_section_begin owner=compiler kind=scratch\nvalue:\n.byte 0\n; zeropage_section_end owner=compiler kind=scratch\n";
    const unchanged = try rewrite(std.testing.allocator, outside);
    defer std.testing.allocator.free(unchanged.assembly);
    try std.testing.expectEqualStrings(outside, unchanged.assembly);
    const input = try fixture(std.testing.allocator, "stx f_high\nlda f_high\nlda f_high");
    defer std.testing.allocator.free(input);
    const first = try rewrite(std.testing.allocator, input);
    defer std.testing.allocator.free(first.assembly);
    try std.testing.expectEqual(@as(usize, 2), first.stats.loads_forwarded);
    const second = try rewrite(std.testing.allocator, first.assembly);
    defer std.testing.allocator.free(second.assembly);
    try std.testing.expectEqualStrings(first.assembly, second.assembly);
    try std.testing.expectEqualDeep(Stats{}, second.stats);
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    const input = try fixture(allocator, "stx zeropage_call_arg_0+1\nsta f_low\nlda zeropage_call_arg_0+1\nsta f_high");
    defer allocator.free(input);
    const result = rewrite(allocator, input) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer allocator.free(result.assembly);
}
test "X forwarding releases canonical model lines and output on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}
