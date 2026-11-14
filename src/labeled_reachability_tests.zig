const std = @import("std");
const parser = @import("parser.zig");
const dead = @import("codegen/tass64/unreachable_code.zig");
const a = std.testing.allocator;

const declarations = "export fn f()u8{return 7;} export fn main()void{}";
const begin = "; zeropage_section_begin owner=function:f kind=code lifetime=static address=near\n";
const end = "; zeropage_section_end owner=function:f kind=code\n";

fn rewrite(assembly: []const u8) !dead.Result {
    const p = try parser.parseSource(a, declarations);
    defer p.deinit(a);
    return dead.rewriteProgram(a, assembly, p.program);
}

const cycle = "* = $2000\n" ++ begin ++
    "f:\n    lda #7\n    rts\ndead_a:\n    lda #17\n    bcc dead_b\n    rts\ndead_b:\n    jmp dead_a\n" ++ end;

test "labeled reachability drops a private unreachable cycle and leaves its label anchors" {
    const result = try rewrite(cycle);
    defer a.free(result.assembly);
    try std.testing.expectEqual(@as(usize, 4), result.stats.instructions_removed);
    try std.testing.expectEqualStrings("* = $2000\n" ++ begin ++
        "f:\n    lda #7\n    rts\ndead_a:\ndead_b:\n" ++ end, result.assembly);
}

test "labeled reachability follows live local calls and both branch edges" {
    const text = "* = $2000\n" ++ begin ++
        "f:\n    bcc alternate\n    jsr local\n    rts\nalternate:\n    lda #7\n    rts\nlocal:\n    lda #8\n    rts\n" ++ end;
    const result = try rewrite(text);
    defer a.free(result.assembly);
    try std.testing.expectEqualStrings(text, result.assembly);
}

test "labeled reachability roots cross-scope direct entry and both co-located labels" {
    const text = "* = $2000\nmain:\n    jsr alternate\n    rts\n" ++ begin ++
        "f:\n    lda #7\n    rts\nfirst_alias:\nalternate:\n    lda #8\n    rts\n" ++ end;
    const result = try rewrite(text);
    defer a.free(result.assembly);
    try std.testing.expectEqualStrings(text, result.assembly);
}

test "labeled reachability retains code with an observed interior address" {
    const text = cycle ++ "vector:\n    .word dead_a\n";
    const result = try rewrite(text);
    defer a.free(result.assembly);
    try std.testing.expectEqualStrings(text, result.assembly);
}

test "labeled reachability keeps unknown owner sections and invalid original control modes" {
    const unknown_owner = "* = $2000\n; zeropage_section_begin owner=function:fake kind=code lifetime=static address=near\nfake:\n    rts\nlater:\n    lda #3\n    rts\n; zeropage_section_end owner=function:fake kind=code\n";
    const invalid = "* = $2000\n" ++ begin ++ "f:\n    rts\nlater:\n    jsr @w f\n    rts\n" ++ end;
    for ([_][]const u8{ unknown_owner, invalid }) |text| {
        const result = try rewrite(text);
        defer a.free(result.assembly);
        try std.testing.expectEqualStrings(text, result.assembly);
    }
}

test "labeled reachability removes a jump to the same next instruction after dead code is pruned" {
    const text = "* = $2000\n" ++ begin ++
        "f:\n    jmp next\ndead:\n    lda #3\n    rts\ncoalias:\nnext:\n    lda #7\n    rts\n" ++ end;
    const result = try rewrite(text);
    defer a.free(result.assembly);
    try std.testing.expectEqualStrings("* = $2000\n" ++ begin ++
        "f:\ndead:\ncoalias:\nnext:\n    lda #7\n    rts\n" ++ end, result.assembly);
}

test "labeled reachability preserves a jump around an externally live block" {
    const text = "* = $2000\nmain:\n    jmp alternate\n" ++ begin ++
        "f:\n    jmp next\nalternate:\n    lda #9\n    rts\nnext:\n    lda #7\n    rts\n" ++ end;
    const result = try rewrite(text);
    defer a.free(result.assembly);
    try std.testing.expectEqualStrings(text, result.assembly);
}

test "labeled reachability preserves a backward self-loop and casefold ambiguity" {
    const self_loop = "* = $2000\n" ++ begin ++ "f:\n    jmp f\n" ++ end;
    const duplicate = "* = $2000\n" ++ begin ++ "f:\n    rts\nDead:\n    lda #8\n    rts\ndead:\n    rts\n" ++ end;
    for ([_][]const u8{ self_loop, duplicate }) |text| {
        const result = try rewrite(text);
        defer a.free(result.assembly);
        try std.testing.expectEqualStrings(text, result.assembly);
    }
}
