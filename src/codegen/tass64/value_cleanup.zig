const std = @import("std");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");

const State = struct {
    nz_matches_a: bool = false,
    cell: ?storage.Location = null,
    y_cell: ?storage.Location = null,

    fn observe(self: *State, model: storage.Model, inst: machine.Instruction) void {
        const effect = inst.effects();
        if (effect.barrier) {
            self.* = .{};
            return;
        }
        const location = if (inst.operand == .direct) model.resolve(inst.operand.direct, 1) else null;
        const prior_a = self.cell;
        const prior_y = self.y_cell;
        switch (effect.memory) {
            .write, .read_write => {
                if (inst.op == .sty and location != null) {
                    self.y_cell = location;
                } else if (self.y_cell) |known| {
                    if (location) |written| {
                        if (known.frame != written.frame or known.offset == written.offset) self.y_cell = null;
                    } else self.y_cell = null;
                }
                if (inst.op == .sta and location != null) {
                    // The written ordinary-RAM byte now equals A, regardless of
                    // whether the previous A identity was known.
                    self.cell = location;
                } else if (self.cell) |known| {
                    if (location) |written| {
                        if (known.frame != written.frame or known.offset == written.offset) self.cell = null;
                    } else self.cell = null;
                }
            },
            .read => if (location == null) {
                // Unknown/volatile reads are not ordinary-memory facts.
                self.cell = null;
                // Ordinary indexed RAM reads leave Y and its source cell
                // unchanged. Unknown/volatile reads revoke the fact.
                if (inst.operand != .indexed or !model.indexedReadIsRam(inst.operand.indexed.base)) self.y_cell = null;
            },
            .none, .stack => {},
        }
        if (effect.writes & machine.a != 0) {
            self.cell = switch (inst.op) {
                .lda => location,
                .tya => prior_y,
                else => null,
            };
        }
        if (effect.writes & machine.y != 0) self.y_cell = switch (inst.op) {
            .ldy => location,
            .tay => prior_a,
            else => null,
        };
        self.nz_matches_a = switch (inst.op) {
            .lda, .pla, .txa, .tya, .tax, .tay, .@"and", .ora, .eor => true,
            .asl, .lsr, .rol, .ror => inst.operand == .none,
            // NMOS decimal ADC/SBC flags need not describe adjusted A. A dead-
            // flag proof can still remove a temporary; this relation cannot.
            .adc, .sbc => false,
            else => if (effect.writes & (machine.a | machine.nz) != 0) false else self.nz_matches_a,
        };
    }
};

fn same(a: storage.Location, b: storage.Location) bool {
    return a.frame == b.frame and a.offset == b.offset;
}

fn nzDead(lines: []const []const u8) bool {
    return outputsDead(lines, machine.nz);
}

fn outputsDead(lines: []const []const u8, outputs: u16) bool {
    var needed = outputs;
    for (lines) |line| {
        const inst = machine.Instruction.parse(line) orelse return false;
        const effect = inst.effects();
        if (effect.barrier or effect.reads & needed != 0) return false;
        needed &= ~effect.writes;
        if (needed == 0) return true;
    }
    return false;
}

// Borrow input, return owned output. This runs after the legacy adjacent
// peepholes so exposing a new adjacency cannot enable an unproved old rewrite.
pub fn optimize(allocator: std.mem.Allocator, assembly: []const u8) ![]u8 {
    var model = storage.Model.init(allocator);
    defer model.deinit();
    try model.collect(assembly);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var split = std.mem.splitScalar(u8, assembly, '\n');
    while (split.next()) |line| try lines.append(allocator, line);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var active = false;
    var in_assembly = false;
    var state: State = .{};
    var pairs: usize = 0;
    var reloads: usize = 0;
    var y_pairs: usize = 0;
    var y_loads: usize = 0;
    var y_transfers: usize = 0;
    var index: usize = 0;
    while (index < lines.items.len) {
        const raw = lines.items[index];
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "; inline asm from ZeroPage line ")) in_assembly = true;
        if (std.mem.eql(u8, line, "; end inline asm")) in_assembly = false;
        if (storage.sectionOwner(line, "code") != null) {
            active = true;
        } else if (std.mem.startsWith(u8, line, "; zeropage_section_")) {
            active = false;
        }
        const inst = if (active and !in_assembly) machine.Instruction.parse(line) else null;
        if (inst) |current| {
            if (current.op == .pha and current.operand == .none and index + 1 < lines.items.len) {
                const next = machine.Instruction.parse(lines.items[index + 1]);
                if (next != null and next.?.op == .pla and next.?.operand == .none and
                    (state.nz_matches_a or nzDead(lines.items[index + 2 ..])))
                {
                    // Keep the actual optimized flags, not PLA's removed NZ.
                    pairs += 1;
                    index += 2;
                    continue;
                }
            }
            if (current.op == .lda and current.operand == .direct) {
                if (model.resolve(current.operand.direct, 1)) |location| {
                    if (state.cell) |known| {
                        if (same(known, location) and (state.nz_matches_a or nzDead(lines.items[index + 1 ..]))) {
                            // A already equals this RAM byte. If only dead NZ
                            // justified removal, do not invent the load's flags.
                            reloads += 1;
                            index += 1;
                            continue;
                        }
                    }
                    if (state.y_cell) |known| {
                        if (same(known, location)) {
                            if (index + 1 < lines.items.len) {
                                const next = machine.Instruction.parse(lines.items[index + 1]);
                                if (next != null and next.?.op == .tay and next.?.operand == .none and outputsDead(lines.items[index + 2 ..], machine.a | machine.nz)) {
                                    y_pairs += 1;
                                    index += 2;
                                    continue;
                                }
                            }
                            // TYA supplies exactly LDA's A/NZ and leaves Y
                            // untouched. Only a proven ordinary RAM read dies.
                            try out.writer.writeAll("    tya\n");
                            state.observe(model, .{ .op = .tya, .operand = .none });
                            y_loads += 1;
                            index += 1;
                            continue;
                        }
                    }
                }
            }
            if (current.op == .tay and current.operand == .none and state.cell != null and state.y_cell != null and same(state.cell.?, state.y_cell.?) and (state.nz_matches_a or nzDead(lines.items[index + 1 ..]))) {
                y_transfers += 1;
                index += 1;
                continue;
            }
            state.observe(model, current);
        } else state = .{};
        if (index + 1 < lines.items.len or raw.len != 0) try out.writer.print("{s}\n", .{raw});
        index += 1;
    }
    if (pairs != 0 or reloads != 0 or y_pairs != 0 or y_loads != 0 or y_transfers != 0) try out.writer.print("; zeropage_value_cleanup stack_pairs={d} reloads={d} y_pairs={d} y_loads={d} y_transfers={d}\n", .{ pairs, reloads, y_pairs, y_loads, y_transfers });
    return try out.toOwnedSlice();
}

fn testProgram(allocator: std.mem.Allocator, code: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\* = $2000
        \\; zeropage_section_begin owner=function:f kind=code lifetime=static address=near
        \\f:
        \\{s}
        \\    rts
        \\; zeropage_section_end owner=function:f kind=code
        \\; zeropage_section_begin owner=function:f kind=static_frame lifetime=static address=near
        \\f_root:
        \\f_value:
        \\    .byte 0
        \\f_other:
        \\    .byte 0
        \\; zeropage_section_end owner=function:f kind=static_frame
        \\
    , .{code});
}

fn expectCounts(code: []const u8, expected: []const u8) !void {
    const input = try testProgram(std.testing.allocator, code);
    defer std.testing.allocator.free(input);
    const output = try optimize(std.testing.allocator, input);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, expected) != null);
}

test "stack pairs require equivalent NZ or NZ dead before every consumer" {
    try expectCounts("lda #128\npha\npla\nphp", "stack_pairs=1 reloads=0");
    try expectCounts("lda #128\nldx #0\npha\npla\nsta f_value\nlda #7", "stack_pairs=1 reloads=0");
    for ([_][]const u8{ "php", "bne target", "bmi target", "rts", "unknown instruction" }) |consumer| {
        const code = try std.fmt.allocPrint(std.testing.allocator, "lda #128\nldx #0\npha\npla\n{s}", .{consumer});
        defer std.testing.allocator.free(code);
        try expectCounts(code, "pha\npla");
    }
    try expectCounts("lda #127\nclc\nadc #1\npha\npla\nphp", "pha\npla");
    try expectCounts("lda #127\nclc\nadc #1\npha\npla\nlda #1", "stack_pairs=1 reloads=0");
}

test "reload forwarding uses canonical RAM cells and correct surviving flags" {
    try expectCounts("lda #7\nsta f_value\nlda f_root", "stack_pairs=0 reloads=1");
    try expectCounts("lda f_value\nldx #0\nlda f_value\nlda #1", "stack_pairs=0 reloads=1");
    // Removing the first dead-NZ reload must not make the later live-NZ reload
    // look redundant: only instructions actually retained may define NZ.
    try expectCounts("lda f_value\nldx #0\nlda f_value\nsta f_other\nlda f_other\nphp", "stack_pairs=0 reloads=1");
    try expectCounts("lda f_value\nldx #0\nlda f_value\nphp", "ldx #0\nlda f_value\nphp");
}

test "writes aliases calls joins IO and opaque assembly revoke RAM facts" {
    for ([_][]const u8{
        "inc f_root",     "sta (ptr),y",                                              "sta f_other,x", "sta $fb",         "stx f_value",
        "lda $d012",      "ldx $dc04",                                                "jsr helper",    "bne join\njoin:", ".byte 0",
        "madeup operand", "; inline asm from ZeroPage line 1\nnop\n; end inline asm",
    }) |between| {
        const code = try std.fmt.allocPrint(std.testing.allocator, "lda f_value\n{s}\nlda f_value\nphp", .{between});
        defer std.testing.allocator.free(code);
        const input = try testProgram(std.testing.allocator, code);
        defer std.testing.allocator.free(input);
        const output = try optimize(std.testing.allocator, input);
        defer std.testing.allocator.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "reloads=1") == null);
    }
    try expectCounts("lda f_value\nstx f_other\nlda f_value", "stack_pairs=0 reloads=1");
    try expectCounts("lda f_value\ninc f_other\nlda f_value\nlda #0", "stack_pairs=0 reloads=1");
}

test "unproven layout and assembly bodies keep their accesses" {
    const input = try testProgram(std.testing.allocator, "lda f_value\nsta f_other\nlda f_other");
    defer std.testing.allocator.free(input);
    const io = try std.mem.replaceOwned(u8, std.testing.allocator, input, "* = $2000", "* = $d000");
    defer std.testing.allocator.free(io);
    const output = try optimize(std.testing.allocator, io);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "zeropage_value_cleanup") == null);
    try expectCounts("; inline asm from ZeroPage line 1\nlda #7\npha\npla\n; end inline asm", "pha\npla");
}

test "Y forwards a canonical RAM index through reads and disjoint stores" {
    try expectCounts("lda f_value\ntay\nlda #99\nsta f_other\nlda f_root\ntay\nlda #7", "y_pairs=1");
    try expectCounts("lda f_value\ntay\nlda #99\nlda f_root\nphp", "y_loads=1");
    try expectCounts("ldy f_root\nlda #99\nlda f_value\ntay\nphp", "y_loads=1");
}

test "Y facts stop at aliases index changes control flow IO and opaque assembly" {
    for ([_][]const u8{
        "inc f_root",     "sta f_value",                                              "stx f_root", "sta (ptr),y", "sta f_other,x",   "sta $2000",
        "ldy #0",         "iny",                                                      "dey",        "jsr helper",  "bne join\njoin:", "lda $d012",
        "madeup operand", "; inline asm from ZeroPage line 1\nnop\n; end inline asm",
    }) |between| {
        const code = try std.fmt.allocPrint(std.testing.allocator, "lda f_value\ntay\nlda #99\n{s}\nlda f_root\ntay\nphp", .{between});
        defer std.testing.allocator.free(code);
        const input = try testProgram(std.testing.allocator, code);
        defer std.testing.allocator.free(input);
        const output = try optimize(std.testing.allocator, input);
        defer std.testing.allocator.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "y_loads=1") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "y_pairs=1") == null);
    }
}

test "Y pair elimination requires A and NZ dead or replaces the load with TYA" {
    try expectCounts("lda f_value\ntay\nlda #99\nlda f_value\ntay\nsta f_other\nphp", "y_loads=1");
    try expectCounts("lda f_value\ntay\nlda #99\nlda f_value\ntay\nbmi target", "y_loads=1");
    try expectCounts("lda f_value\ntay\nlda #99\nlda f_value\ntay\nrts", "y_loads=1");
    try expectCounts("lda f_value\ntay\nlda #99\nlda f_value\ntay\nlda (ptr),y", "y_pairs=1");
}
