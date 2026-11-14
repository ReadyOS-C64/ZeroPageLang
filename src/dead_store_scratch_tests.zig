const std = @import("std");
const parser = @import("parser.zig");
const literal_io = @import("codegen/tass64/literal_pointer_io.zig");
const pipeline = @import("codegen/tass64/pipeline.zig");

const a = std.testing.allocator;
const sample =
    \\fn scale(value: u16) u16 { return value * 7; }
    \\export fn main() void {
    \\    const input: *volatile u16 = @ptrFromInt(0xc100);
    \\    const first: *volatile u16 = @ptrFromInt(0xc1ff);
    \\    const second: *volatile u16 = @ptrFromInt(0xc110);
    \\    var word: u16 = input.*;
    \\    first.* = word;
    \\    second.* = scale(word);
    \\}
;
const full_low_capture = "    sta zeropage_ptr_value\n";
const full_pointer_low = "    sty zeropage_ptr_tmp\n";
const managed = "pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scratch, .ranges = .{.{ .addr = 0x24, .size = 16 }} } };\n";
const first_slim_store =
    "    ldy #0\n    sta $c1ff,y\n    iny\n" ++
    "    lda zeropage_ptr_value+1\n    sta $c1ff,y\n";
const first_slim = "    stx zeropage_ptr_value+1\n    ldx #$c1\n" ++ first_slim_store;

fn emit(source: []const u8) ![]u8 {
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    return pipeline.emitProgram(a, parsed.program);
}

test "dead store scratch keeps both target stores and the terminal scratch publication" {
    for ([_][]const u8{ "", managed }) |options| {
        const source = try std.mem.concat(a, u8, &.{ options, sample });
        defer a.free(source);
        const assembly = try emit(source);
        defer a.free(assembly);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, full_low_capture));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, full_pointer_low));
        try std.testing.expect(std.mem.indexOf(u8, assembly, "    stx zeropage_ptr_value+1\n    sta $c1ff\n    lda zeropage_ptr_value+1\n    sta $c200\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, assembly, "    sty zeropage_ptr_tmp\n    ldx #$c1\n    stx zeropage_ptr_tmp+1\n    ldy #1\n    sta $c110\n") != null);
    }
}

test "dead store scratch respects physical aliases of remapped scratch" {
    const parsed = try parser.parseSource(a, managed ++ sample);
    defer parsed.deinit(a);
    const assembly = try pipeline.emitBeforeSingleCallLeaf(a, parsed.program);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_ptr_tmp = address($24)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_ptr_value = address($28)\n") != null);
    const first_full =
        full_low_capture ++ "    stx zeropage_ptr_value+1\n    ldy #$ff\n" ++
        full_pointer_low ++ "    ldx #$c1\n    stx zeropage_ptr_tmp+1\n" ++
        "    ldy #0\n    sta $c1ff,y\n    iny\n    lda zeropage_ptr_value+1\n    sta $c1ff,y\n";
    const restored = try std.mem.replaceOwned(u8, a, assembly, first_slim, first_full);
    defer a.free(restored);
    const rewritten = (try literal_io.rewriteDeadStoreScratch(a, parsed.program, restored)) orelse return error.ExpectedScratchRemoval;
    defer a.free(rewritten);
    try std.testing.expectEqualStrings(assembly, rewritten);
    for ([_][]const u8{ "    lda $24\n", "    lda $25\n", "    lda $28\n" }) |read| {
        const observed_packet = try std.mem.concat(a, u8, &.{ first_full, read });
        defer a.free(observed_packet);
        const observed = try std.mem.replaceOwned(u8, a, assembly, first_slim, observed_packet);
        defer a.free(observed);
        const refused = try literal_io.rewriteDeadStoreScratch(a, parsed.program, observed);
        defer if (refused) |buffer| a.free(buffer);
        try std.testing.expect(refused == null);
    }
}

test "dead store scratch stops at a conditional kill or a leaf that uses pointer scratch" {
    for ([_][2][]const u8{
        .{ "second.* = scale(word);", "if (word != 0) { second.* = scale(word); }" },
        .{ "return value * 7;", "const port: *volatile u16 = @ptrFromInt(0xc104); return value + port.*;" },
    }) |edit| {
        const source = try std.mem.replaceOwned(u8, a, sample, edit[0], edit[1]);
        defer a.free(source);
        const assembly = try emit(source);
        defer a.free(assembly);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, full_low_capture));
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, full_pointer_low));
    }
}

const high_header = "* = $0801\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
const high_end = "    rts\n; zeropage_section_end owner=function:main kind=code\n";
const resident_high = "; zeropage_section_begin owner=compiler kind=scratch\nzeropage_ptr_value:\n    .word 0\n" ++
    "; zeropage_section_end owner=compiler kind=scratch\n";
const managed_high = "zeropage_ptr_value = address($28)\nscratch_alias = $29\n" ++
    "; zeropage_zp_claim label=zeropage_ptr_value addr=40 size=2 kind=scratch\n";
const high_store = "    sta zeropage_ptr_value+1\n";
const high_overwrite = "    stx zeropage_ptr_value+1\n";

test "dead high scratch keeps external stores and the last publication" {
    const bus_and_stack = "    sta $c1ff,y\n    pha\n    pla\n    lda $c110\n";
    for ([_][2][]const u8{ .{ "", resident_high }, .{ managed, managed_high } }) |configuration| {
        const program = try std.mem.concat(a, u8, &.{ configuration[0], "export fn main() void {}" });
        defer a.free(program);
        const parsed = try parser.parseSource(a, program);
        defer parsed.deinit(a);
        const source = try std.mem.concat(a, u8, &.{
            high_header, high_store, bus_and_stack, high_overwrite, high_end, configuration[1],
        });
        defer a.free(source);
        const result = (try literal_io.rewriteDeadScratch(a, parsed.program, source)) orelse return error.ExpectedDeadHighStore;
        defer a.free(result);
        const expected = try std.mem.concat(a, u8, &.{ high_header, bus_and_stack, high_overwrite, high_end, configuration[1] });
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, result);
    }
}

test "dead high scratch retains writes visible through aliases or bypassed overwrites" {
    const parsed = try parser.parseSource(a, managed ++ "export fn main() void {}");
    defer parsed.deinit(a);
    for ([_][]const u8{
        "    lda zeropage_ptr_value+1\n",
        "    lda $29\n",
        "    lda scratch_alias\n",
        "    lda $28,x\n",
        "    lda ($fb),y\n",
        "alternate:\n",
        "    bne done\n",
    }) |observer| {
        const source = try std.mem.concat(a, u8, &.{
            high_header, high_store, observer, high_overwrite, "done:\n", high_end, managed_high,
        });
        defer a.free(source);
        const result = try literal_io.rewriteDeadScratch(a, parsed.program, source);
        defer if (result) |buffer| a.free(buffer);
        try std.testing.expect(result == null);
    }
}

const pointer_init = "    sta zeropage_ptr_tmp\n    stx zeropage_ptr_tmp+1\n";
const pointer_overwrite = "    sty zeropage_ptr_tmp\n    stx zeropage_ptr_tmp+1\n";
const pointer_default = "zeropage_ptr_tmp = $fb\nstring_destination = zeropage_ptr_tmp\n";
const pointer_managed = "zeropage_ptr_tmp = address($24)\nstring_destination = zeropage_ptr_tmp\n" ++
    "; zeropage_zp_claim label=zeropage_ptr_tmp addr=36 size=2 kind=pointer\n";

test "dead pointer scratch tracks separate bytes and preserves aliased reads" {
    for ([_][2][]const u8{ .{ "", pointer_default }, .{ managed, pointer_managed } }) |configuration| {
        const program = try std.mem.concat(a, u8, &.{ configuration[0], "export fn main() void {}" });
        defer a.free(program);
        const parsed = try parser.parseSource(a, program);
        defer parsed.deinit(a);
        const observe_low = "    lda string_destination\n    ldx $c2ff,y\n";
        const source = try std.mem.concat(a, u8, &.{ high_header, pointer_init, observe_low, pointer_overwrite, high_end, configuration[1] });
        defer a.free(source);
        const result = (try literal_io.rewriteDeadScratch(a, parsed.program, source)) orelse return error.ExpectedDeadPointerHigh;
        defer a.free(result);
        const expected = try std.mem.concat(a, u8, &.{
            high_header, "    sta zeropage_ptr_tmp\n", observe_low, pointer_overwrite, high_end, configuration[1],
        });
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, result);

        const indirect = try std.mem.concat(a, u8, &.{
            high_header, pointer_init, "    lda (string_destination),y\n", pointer_overwrite, high_end, configuration[1],
        });
        defer a.free(indirect);
        const refused = try literal_io.rewriteDeadScratch(a, parsed.program, indirect);
        defer if (refused) |buffer| a.free(buffer);
        try std.testing.expect(refused == null);
    }
}
