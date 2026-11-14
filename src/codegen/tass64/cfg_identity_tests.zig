// R30 TDD: pure assembly CFG tests, deliberately unimported before acceptance
// of the preceding producer round. These are not source-language fixtures.
const std = @import("std");
const cfg = @import("cfg_dead_values.zig");
const allocator = std.testing.allocator;

const Counts = struct {
    removed: usize = 0,
    loads: usize = 0,
    carry: usize = 0,
    bytes: usize = 0,
};

fn expectRewrite(input: []const u8, expected: []const u8, counts: Counts) !void {
    const result = try cfg.rewrite(allocator, input);
    defer allocator.free(result.assembly);
    try std.testing.expectEqualStrings(expected, result.assembly);
    // Do not assume that an optional future identity counter exists, or count
    // logical identities as literal loads merely to fit the old stats layout.
    try std.testing.expectEqual(counts.removed, result.stats.removed);
    try std.testing.expectEqual(counts.loads, result.stats.loads_removed);
    try std.testing.expectEqual(counts.carry, result.stats.carry_removed);
    try std.testing.expectEqual(counts.bytes, result.stats.bytes_saved);
}

fn expectKept(input: []const u8) !void {
    try expectRewrite(input, input, .{});
}

test "CFG identity removes numeric ORA zero EOR zero AND255 before a physical NZ kill" {
    for ([_][]const u8{
        "ora #0",   "ora #$00", "ora #0x00",
        "eor #0",   "eor #$00", "eor #0x00",
        "and #255", "and #$ff", "and #0xff",
    }) |identity| {
        const input = try std.fmt.allocPrint(allocator, "{s}\nlda value\nrts\n", .{identity});
        defer allocator.free(input);
        // The real memory read remains, including its A and NZ result.
        try expectRewrite(input, "lda value\nrts\n", .{ .removed = 1, .bytes = 2 });
    }
}

test "CFG identity reads of unchanged A do not make identity A an output" {
    for ([_][]const u8{ "ora #0", "eor #0", "and #255" }) |identity| {
        for ([_][]const u8{ "tax", "tay", "cmp #7", "bit observed", "lda $dc04" }) |kill| {
            const input = try std.fmt.allocPrint(allocator, "{s}\nsta output\n{s}\nrts\n", .{ identity, kill });
            defer allocator.free(input);
            const expected = try std.fmt.allocPrint(allocator, "sta output\n{s}\nrts\n", .{kill});
            defer allocator.free(expected);
            try expectRewrite(input, expected, .{ .removed = 1, .bytes = 2 });
        }
    }
}

test "CFG identity unchanged A store alone does not make return flags dead" {
    for ([_][]const u8{ "ora #0", "eor #0", "and #255" }) |identity| {
        const live = try std.fmt.allocPrint(allocator, "{s}\nsta output\nrts\n", .{identity});
        defer allocator.free(live);
        // STA reads A but does not overwrite NZ. Return exposes those flags.
        try expectKept(live);
    }
}

test "CFG identity N and Z consumers retain flags even when both later paths kill them" {
    for ([_][]const u8{ "beq", "bne", "bmi", "bpl" }) |condition| {
        const input = try std.fmt.allocPrint(
            allocator,
            "ora #0\n{s} left\ntax\njmp done\nleft:\ntay\ndone:\nrts\n",
            .{condition},
        );
        defer allocator.free(input);
        try expectKept(input);
    }
    // PHP observes physical status and stores it on the hardware stack before
    // PLP restores SP/status; a later TAX does not erase that earlier read.
    try expectKept("eor #0\nphp\nplp\ntax\nrts\n");
    // PHP requires the identity, which in turn consumes the original literal A.
    try expectKept("lda #0\nora #0\nphp\nplp\nlda #1\nrts\n");
}

test "CFG identity diamonds require NZ dead on every successor" {
    try expectRewrite(
        "ora #0\nbcc left\ntax\njmp done\nleft:\ntay\ndone:\nrts\n",
        "bcc left\ntax\njmp done\nleft:\ntay\ndone:\nrts\n",
        .{ .removed = 1, .bytes = 2 },
    );
    // The split consumes only C, but one successor reads NZ before its kill.
    try expectKept("ora #0\nbcc left\ntax\njmp done\nleft:\nphp\nplp\ntay\ndone:\nrts\n");
    // The other successor exits with live NZ; a proof on only the fallthrough
    // path would incorrectly approve this one.
    try expectKept("and #255\nbvs left\ntax\njmp done\nleft:\nnop\ndone:\nrts\n");
    // A cycle after a real first NZ kill is different from an unresolved
    // cycle: the candidate's flags die before its back edge.
    try expectRewrite("eor #0\nloop:\ntax\njmp loop\n", "loop:\ntax\njmp loop\n", .{ .removed = 1, .bytes = 2 });
}

test "CFG identity calls exits modes unknown controls and unresolved cycles retain NZ" {
    for ([_][]const u8{
        "jsr leaf",           "rts",         "rti",           "brk",       "sed",                   "cld",                                   "sei", "cli",
        "madeup instruction", "jmp missing", "jmp (pointer)", "jmp $1234", "jmp target+1\ntarget:", "loop:\nnop\nbcc exit\njmp loop\nexit:",
    }) |barrier| {
        const input = try std.fmt.allocPrint(allocator, "ora #0\n{s}\ntax\nrts\n", .{barrier});
        defer allocator.free(input);
        try expectKept(input);
    }
}

test "CFG identity A changing logical operations and symbolic immediates are not candidates" {
    for ([_][]const u8{
        "ora #1",      "ora #255",    "eor #1",     "eor #255",   "and #0",   "and #254",
        "ora #<table", "eor #>table", "and #table", "and #(255)", "ora #(0)",
    }) |operation| {
        const input = try std.fmt.allocPrint(allocator, "{s}\nlda #7\nrts\ntable:\n.byte 0\n", .{operation});
        defer allocator.free(input);
        try expectKept(input);
    }
}

test "CFG identity progressive deletion never borrows a removed kill for a literal" {
    try expectRewrite("lda #0\nora #0\nlda #1\nrts\n", "lda #1\nrts\n", .{ .removed = 2, .loads = 1, .bytes = 4 });
    try expectRewrite("ora #0\neor #0\nlda #1\nrts\n", "lda #1\nrts\n", .{ .removed = 2, .bytes = 4 });
    // Once the identity is removed, TAX still consumes the original literal A.
    try expectRewrite("lda #0\nora #0\ntax\nlda #1\nrts\n", "lda #0\ntax\nlda #1\nrts\n", .{ .removed = 1, .bytes = 2 });
}

test "CFG identity does not hide live register carry or memory dependencies" {
    try expectRewrite("ldx #7\nora #0\nstx output\ntax\nrts\n", "ldx #7\nstx output\ntax\nrts\n", .{ .removed = 1, .bytes = 2 });
    try expectRewrite("ldy #7\nand #255\ntya\nrts\n", "ldy #7\ntya\nrts\n", .{ .removed = 1, .bytes = 2 });
    try expectRewrite("sec\nora #0\nadc #1\nrts\n", "sec\nadc #1\nrts\n", .{ .removed = 1, .bytes = 2 });
    try expectRewrite("clc\neor #0\ncmp #0\nrts\n", "cmp #0\nrts\n", .{ .removed = 2, .carry = 1, .bytes = 3 });
    try expectRewrite("ldx #7\nand #255\ntax\nrts\n", "tax\nrts\n", .{ .removed = 2, .loads = 1, .bytes = 4 });
}

test "CFG identity section boundaries and global ASM retain the previous path" {
    try expectKept(
        \\; zeropage_section_begin owner=function:f kind=code
        \\f:
        \\ora #0
        \\jmp g
        \\; zeropage_section_end owner=function:f kind=code
        \\; zeropage_section_begin owner=function:g kind=code
        \\g:
        \\tax
        \\rts
        \\; zeropage_section_end owner=function:g kind=code
        \\
    );
    try expectKept(
        \\; zeropage_section_begin owner=module:main kind=rodata
        \\ora #0
        \\tax
        \\rts
        \\; zeropage_section_end owner=module:main kind=rodata
        \\
    );
    try expectKept("ora #0\ntax\nrts\n; inline asm from ZeroPage line 1\nnop\n; end inline asm\n");
}

test "CFG identity deletion keeps all provenance labels comments and repeats identically" {
    const input = "entry:\n; NZ only\nora #0\n\nsta output\nnext:\n; real kill\ntax\nrts\n";
    const expected = "entry:\n; NZ only\n\nsta output\nnext:\n; real kill\ntax\nrts\n";
    try expectRewrite(input, expected, .{ .removed = 1, .bytes = 2 });
    const result = try cfg.rewrite(allocator, expected);
    defer allocator.free(result.assembly);
    try std.testing.expectEqualStrings(expected, result.assembly);
    try std.testing.expectEqual(@as(usize, 0), result.stats.removed);
}
