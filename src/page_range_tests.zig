const std = @import("std");
const parser = @import("parser.zig");
const pipeline = @import("codegen/tass64/pipeline.zig");

const a = std.testing.allocator;
const program =
    \\export fn main() void {
    \\    const dst: [*]u8 = @ptrFromInt(0x6000);
    \\    var i: u16 = 0;
    \\    while (i < 1280) {
    \\        const chosen: u8 = if (i >= 768 and i < 1024) 0x69 else 0x35;
    \\        dst[i] = chosen;
    \\        i += 1;
    \\    }
    \\}
;

fn emit(source: []const u8) ![]u8 {
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    return pipeline.emitProgram(a, parsed.program);
}

test "page range selector uses one high byte compare and preserves the carry at its join" {
    const assembly = try emit(program);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    ldx main_i+1\n    cpx #$03\n    bne if_expr_") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "_done:\n    sec\n    sta main_chosen\n") != null);
}

test "page range selector shares the high byte load across multiple complete pages" {
    const source = try std.mem.replaceOwned(u8, a, program, "i >= 768", "i >= 512");
    defer a.free(source);
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    ldx main_i+1\n    cpx #$02\n    bcc if_expr_") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    cpx #$04\n    bcs if_expr_") != null);
}

test "page range selector leaves partial pages and image observers on the existing path" {
    for ([_][2][]const u8{
        .{ "i >= 768", "i >= 769" },
        .{ "i < 1024", "i < 1025" },
        .{ "dst[i] = chosen;", "const raw: *u8 = @ptrFromInt(0x080d); dst[i] = chosen + raw.*;" },
    }) |change| {
        const source = try std.mem.replaceOwned(u8, a, program, change[0], change[1]);
        defer a.free(source);
        const assembly = try emit(source);
        defer a.free(assembly);
        try std.testing.expect(std.mem.indexOf(u8, assembly, "    bne if_expr_") == null);
        try std.testing.expect(std.mem.indexOf(u8, assembly, "    beq if_expr_") != null);
    }
}

const paired =
    \\export fn main() void {
    \\    const dst: [*]u8 = @ptrFromInt(0x6000);
    \\    var i: u16 = 0;
    \\    while (i < 1280) {
    \\        const first: u8 = if (i >= 768 and i < 1024) 0x69 else 0x35;
    \\        const second: u8 = if (i >= 768 and i < 1024) 0x96 else 0xc6;
    \\        dst[i] = first + second;
    \\        i += 1;
    \\    }
    \\}
;

test "adjacent page selectors share the predicate and preserve both stores" {
    const assembly = try emit(paired);
    defer a.free(assembly);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "    cpx #$03\n"));
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda #105\n    sta main_first\n    lda #150\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda #53\n    sta main_first\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda #198\nif_expr_") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "_done:\n    sec\n    sta main_second\n") != null);
}

test "adjacent page selectors share a two-bound or zero-based range" {
    for ([_][]const u8{ "512", "0" }) |lower| {
        const source = try std.mem.replaceOwned(u8, a, paired, "768", lower);
        defer a.free(source);
        const assembly = try emit(source);
        defer a.free(assembly);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "    cpx #$04\n"));
        try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, lower, "0")) 0 else 1), std.mem.count(u8, assembly, "    cpx #$02\n"));
    }
}

test "adjacent page selectors keep separate checks across distinct ranges and calls" {
    const distinct = try std.mem.replaceOwned(u8, a, paired, "and i < 1024) 0x96", "and i < 1280) 0x96");
    defer a.free(distinct);
    const called = try std.mem.replaceOwned(u8, a, "fn between() void {}\n" ++ paired, "        const second", "        between();\n        const second");
    defer a.free(called);
    for ([_][]const u8{ distinct, called }) |source| {
        const assembly = try emit(source);
        defer a.free(assembly);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, "    cpx #$03\n"));
        try std.testing.expect(std.mem.indexOf(u8, assembly, "    sec\n    sta main_first\n") != null);
    }
}
