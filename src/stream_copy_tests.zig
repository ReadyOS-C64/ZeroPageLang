const std = @import("std");
const parser = @import("parser.zig");
const pipeline = @import("codegen/tass64/pipeline.zig");
const stream_copy = @import("codegen/tass64/stream_copy.zig");

const allocator = std.testing.allocator;
const bound = "cmp #(((>(zeropage_stream_copy_image_end-1))+1) <? $ff)";
const old_bound = "cmp #>(zeropage_stream_copy_image_end-1)";
const source =
    \\fn transfer(source: [*]u8, target: [*]u8, count: u16) usize {
    \\    var i: u16 = 0;
    \\    while (i < count) { target[i] = source[i]; i += 1; }
    \\    return @intFromPtr(target) + i;
    \\}
    \\export fn main() void {
    \\    const s: [*]u8 = @ptrFromInt(0x60fd);
    \\    const d: [*]u8 = @ptrFromInt(0x68fe);
    \\    _ = transfer(s, d, 257);
    \\}
;

fn emit(text: []const u8) ![]u8 {
    const parsed = try parser.parseSource(allocator, text);
    defer parsed.deinit(allocator);
    return pipeline.emitProgram(allocator, parsed.program);
}

test "stream copy guards both pages and keeps the ordinary indexed loop" {
    const dynamic = try std.mem.replaceOwned(u8, allocator, source, "_ = transfer(s, d, 257);", "const n: *volatile u16 = @ptrFromInt(0xc100); _ = transfer(s, d, n.*);");
    defer allocator.free(dynamic);
    const assembly = try emit(dynamic);
    defer allocator.free(assembly);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, bound ++ "\n    bcc zeropage_stream_copy_0_fallback\n    adc "));
    try std.testing.expect(std.mem.indexOf(u8, assembly, old_bound) == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    beq zeropage_stream_copy_0_fallback\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda (zeropage_string_ptr),y\n    sta (zeropage_ptr_tmp),y\n    iny\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "while_0_top:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda (zeropage_ptr_tmp),y\n    pha\n") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "    ldx transfer_count+1\n" ++
        "    bne zeropage_stream_copy_0_bounds\n"));
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    ldy #0\n    txa\n    beq zeropage_stream_copy_0_tail_setup\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    tya\n    ldy #0\n    jmp while_0_done\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    cmp transfer_count\n    jmp while_0_done\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "while_0_body:\n    sta zeropage_ptr_value\n" ++
        "    stx zeropage_ptr_value+1\n    adc transfer_source\n") != null);
}

test "fallback index reuse rejects alternate entries to the comparison or body" {
    const parsed = try parser.parseSource(allocator, source);
    defer parsed.deinit(allocator);
    const assembly =
        "* = $0801\n; zeropage_section_begin owner=function:transfer kind=code\ntransfer:\n" ++
        "zeropage_stream_copy_0_fallback:\n    jmp while_0_top\nwhile_0_top:\n" ++
        "    ldx transfer_i+1\n    lda transfer_i\n    cpx transfer_count+1\n" ++
        "    bne cmp_word_1_done\n    cmp transfer_count\ncmp_word_1_done:\n    bcs while_0_done\n" ++
        "while_0_body:\n    ldx transfer_i+1\n    lda transfer_i\n    sta zeropage_ptr_value\n" ++
        "    stx zeropage_ptr_value+1\n    clc\n    adc transfer_source\n    jmp while_0_top\n" ++
        "while_0_done:\n    rts\n; zeropage_section_end owner=function:transfer kind=code\n" ++
        "zeropage_stream_copy_image_end:\n";
    const candidate = (try stream_copy.reuseFallbackIndex(allocator, parsed.program, assembly)) orelse
        return error.ExpectedFallbackIndexReuse;
    defer allocator.free(candidate);
    for ([_][]const u8{ "cmp_word_1_done", "while_0_body" }) |entry| {
        const branch = try std.fmt.allocPrint(allocator, "    bne {s}\n    jmp while_0_top", .{entry});
        defer allocator.free(branch);
        const modified = try std.mem.replaceOwned(u8, allocator, assembly, "    jmp while_0_top", branch);
        defer allocator.free(modified);
        const output = try stream_copy.reuseFallbackIndex(allocator, parsed.program, modified);
        defer if (output) |result| allocator.free(result);
        try std.testing.expect(output == null);
    }
    const padding = try std.mem.concat(allocator, u8, &.{ assembly, "    .fill (($100 - (* & $ff)) & $ff),0\n" });
    defer allocator.free(padding);
    const output = try stream_copy.reuseFallbackIndex(allocator, parsed.program, padding);
    defer if (output) |result| allocator.free(result);
    try std.testing.expect(output == null);
}

test "stream copy emitter restores equal comparison flags" {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try @import("codegen/tass64/stream_copy.zig").emitGuarded(allocator, &output.writer, "copy", .{
        .source = "source",
        .target = "target",
        .count = "count",
        .index = "index",
    }, 0);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "    lda copy_count\n    sta copy_index\n    tay\n    sec\n    sbc #1\n    sta zeropage_ptr_value\n" ++
        "    ldx copy_count+1\n    stx copy_index+1\n    txa\n    sbc #0\n    sta zeropage_ptr_value+1\n" ++
        "    tya\n    ldy #0\n    sec\n    jmp while_0_done\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "    ldx copy_count\n    beq zeropage_stream_copy_0_finish\nzeropage_stream_copy_0_tail:\n") != null);
    const copy_byte = "    lda (zeropage_string_ptr),y\n    sta (zeropage_ptr_tmp),y\n    iny\n";
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "zeropage_stream_copy_0_page:\n" ++ copy_byte ++ copy_byte ++ "    bne zeropage_stream_copy_0_page\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "zeropage_stream_copy_0_tail:\n" ++ copy_byte ++ "    dex\n    bne zeropage_stream_copy_0_tail\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "    dex\n    bne zeropage_stream_copy_0_tail\n    beq zeropage_stream_copy_0_last_page\n" ++
        "zeropage_stream_copy_0_finish:\n    dec zeropage_ptr_tmp+1\nzeropage_stream_copy_0_last_page:\n    dey\n    tya\n") != null);
}

test "stream copy uses absolute indexes for proven fixed spans" {
    const assembly = try emit(source);
    defer allocator.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda $60fd,y\n    sta $68fe,y\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda $61fd\n    sta $69fe\n    iny\n" ++
        "zeropage_static_copy_finish:\n    ldx #1\n    stx transfer_i\n    ldy #0\n    sty zeropage_ptr_value\n" ++
        "    stx transfer_i+1\n    stx zeropage_ptr_value+1\n" ++
        "    lda #<$69fe\n    sta zeropage_ptr_tmp\n    lda #>$69fe\n    sta zeropage_ptr_tmp+1\n") != null);
    const copy_byte = "    lda $60fd,y\n    sta $68fe,y\n    iny\n";
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_static_copy_full:\n" ++ copy_byte ** 4 ++ "    bne zeropage_static_copy_full\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_stream_copy_0_fallback:") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "while_0_top:") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    sta zeropage_ptr_tmp+1\nwhile_0_done:\n" ++
        "    lda transfer_i\n    clc\n    adc #<$68fe\n    pha\n    lda transfer_i+1\n    adc #>$68fe\n    tax\n    pla\n    rts\n") != null);
}

test "exact page copy wraps Y and publishes the last index with a borrow" {
    const text = try std.mem.replaceOwned(u8, allocator, source, "257", "256");
    defer allocator.free(text);
    const assembly = try emit(text);
    defer allocator.free(assembly);
    const copy_byte = "    lda $60fd,y\n    sta $68fe,y\n    iny\n";
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_static_copy_full:\n" ++ copy_byte ** 4 ++
        "    bne zeropage_static_copy_full\nzeropage_static_copy_finish:\n" ++
        "    sty transfer_i\n    lda #255\n    sta zeropage_ptr_value\n    ldx #1\n" ++
        "    stx transfer_i+1\n    sty zeropage_ptr_value+1\n" ++
        "    lda #<$69fd\n    sta zeropage_ptr_tmp\n    lda #>$69fd\n    sta zeropage_ptr_tmp+1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_static_copy_short:") == null);
}

test "stream copy keeps the guard when a fixed raw read can see the resident image" {
    const text = try std.mem.replaceOwned(u8, allocator, source, "0x60fd", "0x0900");
    defer allocator.free(text);
    const assembly = try emit(text);
    defer allocator.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_stream_copy_0_fallback:") != null);
}

test "stream copy keeps volatile, exported and assembly-observed functions on the original path" {
    for ([_][2][]const u8{
        .{ "fn transfer", "export fn transfer" },
        .{ "[*]u8", "[*]volatile u8" },
        .{ "_ = transfer", "asm {\nnop\n}\n_ = transfer" },
        .{ "fn transfer", "export fn zeropage_stream_copy_image_end() void {}\nfn transfer" },
    }) |change| {
        const text = try std.mem.replaceOwned(u8, allocator, source, change[0], change[1]);
        defer allocator.free(text);
        const assembly = try emit(text);
        defer allocator.free(assembly);
        try std.testing.expect(std.mem.indexOf(u8, assembly, bound) == null and std.mem.indexOf(u8, assembly, old_bound) == null);
    }
}

test "stream copy preserves static frame labels in its generated namespace" {
    const text = try std.mem.concat(allocator, u8, &.{
        source,
        \\
        \\export fn zeropage() u16 {
        \\    var stream_copy_image_end: u16 = 7;
        \\    stream_copy_image_end += 1;
        \\    return stream_copy_image_end;
        \\}
    });
    defer allocator.free(text);
    const assembly = try emit(text);
    defer allocator.free(assembly);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "zeropage_stream_copy_image_end:\n"));
    try std.testing.expect(std.mem.indexOf(u8, assembly, bound) == null and std.mem.indexOf(u8, assembly, old_bound) == null);
}
