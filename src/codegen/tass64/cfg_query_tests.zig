const std = @import("std");
const cfg = @import("cfg_dead_values.zig");
const machine = @import("instruction.zig");

fn expectQuery(source: []const u8, line: usize, mask: u16, expected: bool) !void {
    try std.testing.expectEqual(expected, try cfg.outputsDeadAfterLine(std.testing.allocator, source, line, mask));
}

test "shared CFG query distinguishes N Z from A and C on two carry successors" {
    for ([_][]const u8{ "bcc", "bcs" }) |branch| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "join:\n{s} left\nsta output\nlda #0\nrts\nleft:\nsta output\nlda #1\nrts\n", .{branch});
        defer std.testing.allocator.free(source);
        try expectQuery(source, 0, machine.nz, true);
        try expectQuery(source, 0, machine.a, false);
        try expectQuery(source, 0, machine.c, false);
        try expectQuery(source, 0, machine.a | machine.nz, false);
    }
}

test "shared CFG query starts after exact raw anchor not at candidate effects" {
    const source = "lda #7\ncmp #0\nlda #1\nrts\n";
    try expectQuery(source, 0, machine.nz, true);
    try expectQuery(source, 0, machine.a, false); // CMP reads A before killing flags.
    try expectQuery(source, 1, machine.a, true); // The current CMP is not evaluated.
    const word = "cpx #4\nbne join\ncmp #0\njoin:\nbcc yes\nlda #0\nrts\nyes:\nlda #1\nrts\n";
    try expectQuery(word, 3, machine.nz, true);
    try expectQuery(word, 3, machine.c, false);
}

test "shared CFG query preserves raw blank comment and join alias positions" {
    const source = "; header\n\nfirst_alias:\n; gap\njoin:\n\n; output flags die\nlda #1\nrts\n";
    try expectQuery(source, 2, machine.nz, true);
    try expectQuery(source, 4, machine.nz, true);
    try expectQuery(source, 0, machine.nz, false);
    try expectQuery(source, 1, 0, false);
    try expectQuery(source, 3, 0, false);
}

test "shared CFG query checks each flag read before kill and both successors" {
    try expectQuery("join:\nbeq yes\nlda #0\nrts\nyes:\nlda #1\nrts\n", 0, machine.nz, false);
    try expectQuery("join:\nbmi yes\nlda #0\nrts\nyes:\nlda #1\nrts\n", 0, machine.nz, false);
    try expectQuery("join:\nbmi yes\nlda #0\nrts\nyes:\nlda #1\nrts\n", 0, machine.z, true);
    try expectQuery("join:\nbeq yes\nlda #0\nrts\nyes:\nlda #1\nrts\n", 0, machine.n, true);
    try expectQuery("join:\nbcc yes\nlda #0\nrts\nyes:\nphp\nlda #1\nrts\n", 0, machine.nz, false);
    try expectQuery("join:\nbcc yes\nlda #0\nrts\nyes:\nrts\n", 0, machine.nz, false);
}

test "shared CFG query preserves call return unknown mode and cyclic barriers" {
    for ([_][]const u8{
        "jsr leaf\nlda #0\nrts\nleaf:\nrts\n",
        "rts\nlda #0\n",
        "madeup text\nlda #0\nrts\n",
        "lda weird(data)\nlda #0\nrts\n",
        "jmp missing\nlda #0\nrts\n",
        "jmp (pointer)\nlda #0\nrts\n",
        "jmp target+1\ntarget:\nlda #0\nrts\n",
        "loop:\nnop\nbcc loop\nlda #0\nrts\n",
        "sed\nlda #0\nrts\n",
        "sei\nlda #0\nrts\n",
    }) |suffix| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ "join:\n", suffix });
        defer std.testing.allocator.free(source);
        try expectQuery(source, 0, machine.nz, false);
    }
    // A kill before entering a loop still proves the old N/Z dead; the
    // unchanged prover rejects cycles only while the queried bits survive.
    try expectQuery("join:\nloop:\ndex\nbne loop\nlda #0\nrts\n", 0, machine.nz, true);
}

test "shared CFG query retains original case sensitive and duplicate target behavior" {
    try expectQuery("join:\njmp TARGET\ntarget:\nlda #0\nrts\n", 0, machine.nz, false);
    try expectQuery("join:\njmp target\ntarget:\nlda #0\ntarget:\nlda #1\nrts\n", 0, machine.nz, false);
    try expectQuery("join:\njmp target\ntarget:\nlda #0\nrts\n", 0, machine.nz, true);
}

const begin = "; zeropage_section_begin owner=function:f kind=code\n";
const end = "; zeropage_section_end owner=function:f kind=code\n";
test "shared CFG query excludes outside code boundaries bounds and unknown masks even for zero" {
    const source = "* = $2000\n" ++ begin ++ "join:\nlda #0\nrts\n" ++ end ++
        "; zeropage_section_begin owner=function:f kind=static_frame\nvalue:\n.word 0\n; zeropage_section_end owner=function:f kind=static_frame\n";
    try expectQuery(source, 2, machine.nz, true);
    try expectQuery(source, 2, 0, true);
    for ([_]usize{ 0, 1, 5, 6, 7, 8, 9, 10, 100, std.math.maxInt(usize) }) |line| {
        try expectQuery(source, line, machine.nz, false);
        try expectQuery(source, line, 0, false);
    }
    try expectQuery(source, 2, 0x400, false);
    try expectQuery(source, 2, machine.nz | 0x8000, false);
    try expectQuery("", 0, 0, false);
    try expectQuery(".byte 0\nlda #0\nrts\n", 0, 0, false);
    try expectQuery("madeup\nlda #0\nrts\n", 0, 0, false);
    try expectQuery("lda weird(data)\nlda #0\nrts\n", 0, 0, false);
}

test "shared CFG query cannot cross code sections or retained ASM" {
    const source = begin ++ "join:\njmp other\n" ++ end ++
        "; zeropage_section_begin owner=function:g kind=code\nother:\nlda #0\nrts\n; zeropage_section_end owner=function:g kind=code\n";
    try expectQuery(source, 1, machine.nz, false);
    const asm_source = begin ++ "join:\nlda #0\nrts\n" ++ end ++ "; inline asm from ZeroPage line 8\nnop\n; end inline asm\n";
    try expectQuery(asm_source, 1, machine.nz, false);
    try expectQuery(asm_source, 1, 0, false);
}

test "shared CFG query uses actual remaining instructions and never anticipates rewrite removals" {
    const source = "join:\nora #0\nlda #1\nrts\n";
    try expectQuery(source, 0, machine.a, false);
    const result = try cfg.rewrite(std.testing.allocator, source);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqualStrings("join:\nlda #1\nrts\n", result.assembly);
    try expectQuery(result.assembly, 0, machine.a, true);
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    const source = try allocator.dupe(u8, "join:\nbcc left\nlda #0\nrts\nleft:\nlda #1\nrts\n");
    defer allocator.free(source);
    if (!try cfg.outputsDeadAfterLine(allocator, source, 0, machine.nz)) return error.ExpectedDead;
    if (try cfg.outputsDeadAfterLine(allocator, source, 0, machine.c)) return error.ExpectedLive;
    if (try cfg.outputsDeadAfterLine(allocator, source, std.math.maxInt(usize), machine.nz)) return error.ExpectedInvalid;
}
test "shared CFG query releases partial parser targets removed masks and proof work on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}
