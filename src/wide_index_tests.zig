const std = @import("std");
const parser = @import("parser.zig");
const pipeline = @import("codegen/tass64/pipeline.zig");

const a = std.testing.allocator;
const program =
    \\fn fill(p: [*]u8) void {
    \\    var i: u16 = 768;
    \\    while (i < 1024) { p[i] = i; i += 1; }
    \\}
    \\export fn main() void {
    \\    const p: [*]u8 = @ptrFromInt(0x6000);
    \\    var i: u16 = 0;
    \\    while (i < 1280) { p[i] = 7; i += 1; }
    \\    fill(p);
    \\}
;

fn emit(source: []const u8) ![]u8 {
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    return pipeline.emitProgram(a, parsed.program);
}

test "wide index uses fixed base bytes and a proved constant high index" {
    const assembly = try emit(program);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    adc #$60\n    sta zeropage_ptr_tmp+1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda #$63\n    sta zeropage_ptr_tmp+1\n") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, "    sta (zeropage_ptr_tmp),y\n"));
}

test "wide index bounds a managed snapshot even with a function named fill" {
    const source = "pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scratch, .ranges = .{.{ .addr = 0x24, .size = 16 }} } };\n" ++ program;
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_ptr_tmp = address($24)") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    adc #$60\n    sta zeropage_ptr_tmp+1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda #$63\n    sta zeropage_ptr_tmp+1\n") != null);
}

test "wide index retains the dynamic setup on image aliases or runtime bases" {
    for ([_][2][]const u8{
        .{ "fill(p);", "const alias: *u8 = @ptrFromInt(0x0900); alias.* = 7; fill(p);" },
        .{ "const p: [*]u8 = @ptrFromInt(0x6000);", "const raw: *volatile u16 = @ptrFromInt(0xc100); const address: u16 = raw.*; const p: [*]u8 = @ptrFromInt(address);" },
    }) |change| {
        const source = try std.mem.replaceOwned(u8, a, program, change[0], change[1]);
        defer a.free(source);
        const assembly = try emit(source);
        defer a.free(assembly);
        try std.testing.expect(std.mem.indexOf(u8, assembly, "    adc main_p\n") != null);
    }
}

const paired =
    \\export fn main() void {
    \\    const a: [*]u8 = @ptrFromInt(0x60fd);
    \\    const b: [*]u8 = @ptrFromInt(0x68fe);
    \\    var i: u16 = 769;
    \\    while (i < 1024) { a[i] = 7; b[i] = 11; i += 1; }
    \\}
;

test "paired wide index stores use absolute Y then overwrite both scratch pairs" {
    for ([_][]const u8{ "", "pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scalars, .ranges = .{.{ .addr = 0x24, .size = 16 }} } };\n" }) |options| {
        const source = try std.fmt.allocPrint(a, "{s}{s}", .{ options, paired });
        defer a.free(source);
        const assembly = try emit(source);
        defer a.free(assembly);
        try std.testing.expect(std.mem.indexOf(u8, assembly, "    ldy main_i\n    pla\n    sta $63fd,y\n") != null);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "    stx zeropage_ptr_value+1\n"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "    sta (zeropage_ptr_tmp),y\n"));
    }
}

test "paired wide index stores spanning pages leave the low index in Y" {
    const source = try std.mem.replaceOwned(u8, a, paired, "i: u16 = 769", "i: u16 = 1");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "    stx zeropage_ptr_value+1\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, "    sta (zeropage_ptr_tmp),y\n"));
    try std.testing.expect(std.mem.indexOf(
        u8,
        assembly,
        "    lda main_i+1\n    clc\n    adc #$60\n    sta zeropage_ptr_tmp+1\n" ++
            "    lda #$fd\n    sta zeropage_ptr_tmp\n    ldy main_i\n    pla\n    sta (zeropage_ptr_tmp),y\n",
    ) != null);
}

test "a wide index store that overwrites scratch cannot also omit its capture" {
    const source = try std.mem.replaceOwned(u8, a, paired, "b[i] = 11;", "b[i] = 11; a[i] = 12;");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "    sta $63fd,y\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, "    stx zeropage_ptr_value+1\n"));
}

test "a call between wide index stores keeps the first scratch writes" {
    const source = try std.mem.replaceOwned(u8, a, "fn rhs() u8 { return 11; }\n" ++ paired, "b[i] = 11", "b[i] = rhs()");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, "    stx zeropage_ptr_value+1\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, "    sta (zeropage_ptr_tmp),y\n"));
}

test "a complete page of wide index stores runs on the hardware low byte" {
    const source = try std.mem.replaceOwned(u8, a, paired, "769", "768");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(
        u8,
        assembly,
        "    lda #$07\n    sta $63fd,y\n    lda #$0b\n    sta $6bfe,y\n    iny\n    bne while_0_body\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    stx main_i+1\n    clv\n    sec\nwhile_0_done:\n") != null);
}

test "wide fill hoists biased pointers over multiple complete pages" {
    const source = try std.mem.replaceOwned(u8, a, paired, "769", "512");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "while_0_top:\n    tay\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda zeropage_string_ptr\n    sta zeropage_ptr_value\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    inc zeropage_string_ptr+1\n    inc zeropage_ptr_tmp+1\nwhile_0_body:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    inx\n    cpx #$04\n    bcc cmp_word_") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda zeropage_ptr_value\n    sta zeropage_string_ptr\n") != null);
}

test "one complete page can store the index low and high bytes" {
    const source = try std.mem.replaceOwned(u8, a, paired, "769;\n    while (i < 1024) { a[i] = 7; b[i] = 11;", "768;\n    while (i < 1024) { a[i] = i; b[i] = i >> 8;");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    tya\n    sta $63fd,y\n    lda #$03\n    sta $6bfe,y\n") != null);
}

const transform =
    \\export fn main() void {
    \\    const src: [*]u8 = @ptrFromInt(0x60fd);
    \\    const dst: [*]u8 = @ptrFromInt(0x68fe);
    \\    const delta: u8 = 7;
    \\    var i: u16 = 769;
    \\    while (i < 1024) { dst[i] = src[i] + delta; i += 1; }
    \\}
;

test "wide indexed read before a store uses absolute Y within one index page" {
    const assembly = try emit(transform);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    ldy main_i\n    lda $63fd,y\n    clc\n    adc main_delta\n    pha\n") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "    stx zeropage_ptr_value+1\n"));
}

test "wide indexed read before a store leaves the low index in Y across pages" {
    const source = try std.mem.replaceOwned(u8, a, transform, "769", "1");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(
        u8,
        assembly,
        "    lda main_i+1\n    clc\n    adc #$60\n    sta zeropage_ptr_tmp+1\n" ++
            "    lda #$fd\n    sta zeropage_ptr_tmp\n    ldy main_i\n    lda (zeropage_ptr_tmp),y\n",
    ) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "    stx zeropage_ptr_value+1\n"));
}

test "wide indexed read before a store supports byte subtraction and bitwise operations" {
    for ([_][2][]const u8{ .{ "- delta", "    sbc main_delta\n" }, .{ "^ delta", "    eor main_delta\n" }, .{ "& delta", "    and main_delta\n" }, .{ "| delta", "    ora main_delta\n" } }) |operation| {
        const source = try std.mem.replaceOwned(u8, a, transform, "+ delta", operation[0]);
        defer a.free(source);
        const assembly = try emit(source);
        defer a.free(assembly);
        try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda $63fd,y\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, assembly, operation[1]) != null);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "    stx zeropage_ptr_value+1\n"));
    }
}

test "wide indexed read supports a direct byte copy into the following store" {
    const source = try std.mem.replaceOwned(u8, a, transform, " + delta", "");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda $63fd,y\n    pha\n") != null);
}

test "wide indexed read keeps its captured address across an intervening call" {
    const source = try std.mem.replaceOwned(u8, a, "fn rhs() u8 { return 11; }\n" ++ transform, "+ delta", "+ rhs()");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda $63fd,y\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda (zeropage_ptr_tmp),y\n") != null);
}

test "whole page transform uses two absolute accesses and retains the byte operation" {
    const source = try std.mem.replaceOwned(u8, a, transform, "769", "768");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(
        u8,
        assembly,
        "while_0_body:\n    lda $63fd,y\n    clc\n    adc main_delta\n    sta $6bfe,y\n    iny\n    bne while_0_body\n",
    ) != null);
}

test "whole page transform advances both pointers only on index wrap" {
    const source = try std.mem.replaceOwned(u8, a, transform, "769", "0");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(
        u8,
        assembly,
        "    inc zeropage_string_ptr+1\n    inc zeropage_ptr_tmp+1\nwhile_0_body:\n" ++
            "    lda (zeropage_string_ptr),y\n    clc\n    adc main_delta\n    sta (zeropage_ptr_tmp),y\n    iny\n    bne while_0_body\n",
    ) != null);
}

test "whole page transform preserves the updated resident index when the operand reads it" {
    const aligned = try std.mem.replaceOwned(u8, a, transform, "769", "768");
    defer a.free(aligned);
    const source = try std.mem.replaceOwned(u8, a, aligned, "+ delta", "+ i");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    adc main_i\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    jmp while_0_top\nwhile_0_done:\n") != null);
}

test "whole page transform keeps X as the high index across byte bitwise operations" {
    const aligned = try std.mem.replaceOwned(u8, a, transform, "769", "0");
    defer a.free(aligned);
    const source = try std.mem.replaceOwned(u8, a, aligned, "+ delta", "^ delta");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(
        u8,
        assembly,
        "while_0_body:\n    lda (zeropage_string_ptr),y\n    eor main_delta\n" ++
            "    sta (zeropage_ptr_tmp),y\n    iny\n    bne while_0_body\n    inx\n",
    ) != null);
}

test "whole page transform retains the source increment label from the INC backedge" {
    const options = "pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scratch } };\n";
    const aligned = try std.mem.replaceOwned(u8, a, options ++ transform, "769", "0");
    defer a.free(aligned);
    const source = try std.mem.replaceOwned(u8, a, aligned, "i += 1; }\n", "i += 1; }\n    dst[769] = 0xb9;\n");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    bne while_0_body\nzeropage_word_increment_0:\n    inx\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    inc main_i\n") == null);
}

const selected_transform =
    \\export fn main() void {
    \\    const a: [*]u8 = @ptrFromInt(0x60fd);
    \\    const b: [*]u8 = @ptrFromInt(0x68fe);
    \\    const out_a: [*]u8 = @ptrFromInt(0x68fd);
    \\    const out_b: [*]u8 = @ptrFromInt(0x7600);
    \\    var i: u16 = 256;
    \\    while (i < 1280) {
    \\        const first: u8 = if (i >= 768 and i < 1024) 0x69 else 0x35;
    \\        const second: u8 = if (i >= 768 and i < 1280) 0x96 else 0xc6;
    \\        out_a[i] = a[i] + first;
    \\        out_b[i] = b[i] - second;
    \\        i += 1;
    \\    }
    \\}
;

test "fixed page transforms select each operand and address independently" {
    const assembly = try emit(selected_transform);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(
        u8,
        assembly,
        "zeropage_page_clone_while_0_top_03:\n" ++
            "    lda $63fd,y\n    clc\n    adc #$69\n    sta $6bfd,y\n" ++
            "    lda $6bfe,y\n    sec\n    sbc #$96\n    sta $7900,y\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        assembly,
        "zeropage_page_clone_while_0_top_04:\n" ++
            "    lda $64fd,y\n    clc\n    adc #$35\n    sta $6cfd,y\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        assembly,
        "    lda #$35\n    sta main_first\n    lda #$96\n    sta main_second\n",
    ) != null);
}

test "fixed page transforms retain the existing loop when cloning would grow it" {
    const long_span = try std.mem.replaceOwned(u8, a, selected_transform, "i < 1280) {", "i < 2304) {");
    defer a.free(long_span);
    const assembly = try emit(long_span);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_page_clone_") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    cpx #$03\n    bne if_expr_") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda (zeropage_ptr_tmp),y\n    clc\n    adc main_first\n") != null);
}

test "fixed page transforms require a full range and a closed straight-line body" {
    for ([_][2][]const u8{
        .{ "i: u16 = 256", "i: u16 = 257" },
        .{ "        out_b[i]", "        check();\n        out_b[i]" },
        .{ "b[i] - second", "b[i] - first" },
    }) |edit| {
        const source = try std.mem.replaceOwned(u8, a, "fn check() void {}\n" ++ selected_transform, edit[0], edit[1]);
        defer a.free(source);
        const assembly = try emit(source);
        defer a.free(assembly);
        try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_page_clone_") == null);
    }
}
