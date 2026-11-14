const std = @import("std");
const ast = @import("../../ast.zig");
const parser = @import("../../parser.zig");
const module_sidecars = @import("module_sidecars.zig");
const pipeline = @import("pipeline.zig");
const runtime = @import("runtime.zig");

const emitProgram = pipeline.emitProgram;
const emitProgramWithOptions = pipeline.emitProgramWithOptions;
const screenCode = runtime.screenCode;

test "fills uniform literal word arrays and keeps mixed and runtime fields" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const Record = struct { zeros: [6]u16, ones: [6]u16, mixed: [4]u16 };
        \\fn make(value: u16) Record {
        \\    return Record{
        \\        .zeros = [_]u16{ 0, 0, 0, 0, 0, 0 },
        \\        .ones = [_]u16{ 0xabab, 0xabab, 0xabab, 0xabab, 0xabab, 0xabab },
        \\        .mixed = [_]u16{ 0x0102, 0, value, 0x0201 },
        \\    };
        \\}
        \\export fn main() void { _ = make(7); }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try expectContainsInOrder(assembly, &.{
        "zeropage_array_fill_0:\n    sta make_return_zeros+0,x",
        "zeropage_array_fill_1:\n    sta make_return_ones+0,x",
        "    sta make_return_mixed+0\n",
        "    lda make_value\n",
        "    sta make_return_mixed+6\n",
    });
}

fn expectContainsInOrder(haystack: []const u8, needles: []const []const u8) !void {
    var cursor: usize = 0;
    for (needles) |needle| {
        const found = std.mem.indexOfPos(u8, haystack, cursor, needle) orelse {
            std.debug.print("missing ordered assembly text: {s}\n", .{needle});
            return error.TestExpectedEqual;
        };
        cursor = found + needle.len;
    }
}

test "selects immediate byte and word arithmetic without math scratch" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn plus(value: u8) u8 { return value + 17; }
        \\fn leftPlus(value: u8) u8 { return 17 + value; }
        \\fn minus(value: u16) u16 { return value - 257; }
        \\export fn main() void {
        \\    _ = plus(1);
        \\    _ = leftPlus(1);
        \\    _ = minus(512);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);
    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda plus_value\n    clc\n    adc #17\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda leftPlus_value\n    clc\n    adc #17\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sec\n    sbc #1\n    pha\n    lda minus_value+1\n    sbc #1\n    tax\n    pla\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_math_tmp:") == null);
}

test "removes private unreachable functions frames and their runtime helpers" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn dead(value: u16) u16 {
        \\    var scratch: u16 = value * 37;
        \\    return scratch;
        \\}
        \\fn deadCaller() u16 { return dead(12); }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    for ([_][]const u8{ "\ndead:", "\ndeadCaller:", "\ndead_scratch:", "\nzeropage_mul16:", "\nzeropage_mul_lhs:" }) |label| {
        try std.testing.expect(std.mem.indexOf(u8, assembly, label) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, assembly, "function=dead status=removed reason=unreachable") != null);
}

test "unused function diagnostics survive tree shaking" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn dead() u8 { return missingFunction(); }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnknownFunction, emitProgram(std.testing.allocator, parsed.program));
}

test "constant byte multiplication selects bounded shift add sequences" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn scale(value: u8) u8 { return value * 40; }
        \\export fn main() void { _ = scale(7); }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "\nzeropage_mul16:") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    asl\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    adc zeropage_math_tmp\n") != null);
}

test "constant word multiplication preserves A X width and Y" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\export fn twice(value: u16) u16 { return value * 2; }
        \\export fn page(value: u16) u16 { return value * 256; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "\nzeropage_mul16:") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "twice:\n    ldx twice_value+1\n    lda twice_value\n    asl\n    pha\n    txa\n    rol\n    tax\n    pla\n    rts") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "page:\n    ldx page_value+1\n    lda page_value\n    tax\n    lda #0\n    rts") != null);
}

test "odd word multiplication reuses a direct scalar operand without helper storage" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn scale(value: u16) u16 { return value * 3; }
        \\export fn main() void { _ = scale(7); }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    adc scale_value\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    adc scale_value+1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_mul_") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_mul16") == null);
}

test "odd word multiplication captures a volatile operand exactly once" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\export fn scale(value: *volatile u16) u16 { return value.* * 7; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, "    lda (zeropage_ptr_tmp),y\n"));
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    sbc zeropage_mul_lhs\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "\nzeropage_mul_lhs:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_mul_rhs") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_mul16") == null);
}

test "odd word multiplication leaves an explicit multiply helper observer on the old path" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn scale(value: u16) u16 { return value * 3; }
        \\export fn main() void {
        \\    _ = scale(7);
        \\    asm {
        \\        jsr ZEROPAGE_MUL16
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "\nzeropage_mul16:\n") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "    jsr zeropage_mul16\n"));
}

test "dense byte constant multiplication keeps compact generic helper" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn dense(value: u8) u8 { return value * 255; }
        \\export fn main() void { _ = dense(7); }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try expectContainsInOrder(assembly, &.{ "dense:", "jmp zeropage_mul16", "zeropage_mul16:" });
}

test "ordinary if comparison branches directly with stable control labels" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn choose(value: u8) u8 {
        \\    if (value < 3 and value > 1) { return 7; }
        \\    if (value == 9) { return 8; }
        \\    return 0;
        \\}
        \\export fn main() void { _ = choose(2); }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "\ncmp_") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "if_0_then:") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "if_1_then:") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_cond_0_rhs:") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "bcs if_0_then") != null);
}

test "comparisons select immediate and static operands without staging" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const Mark = enum(u8) { empty, high = 240 };
        \\fn byte(value: u8) bool { return value < 128; }
        \\fn word(a: u16, b: u16) bool { return a >= b; }
        \\fn mixed(a: u16, b: u8) bool { return a > b; }
        \\fn mark(value: Mark) bool { return value == .high; }
        \\export fn main() void { _ = byte(1); _ = word(256, 255); _ = mixed(256, 255); _ = mark(.high); }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "lda byte_value\n    cmp #128\n") != null);
    try expectContainsInOrder(assembly, &.{ "word:", "cpx word_b+1", "bne cmp_word_", "cmp word_b" });
    try expectContainsInOrder(assembly, &.{ "mixed:", "cpx #0", "bne cmp_word_", "cmp mixed_b" });
    try std.testing.expect(std.mem.indexOf(u8, assembly, "lda mark_value\n    cmp #240\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_math_tmp") == null);
}

test "word volatile RHS is fully loaded before comparison flags" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn compare(value: u16, address: *volatile u16) bool { return value < address.*; }
        \\export fn main() void { const ptr: *volatile u16 = @ptrFromInt(0xc100); _ = compare(256, ptr); }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try expectContainsInOrder(assembly, &.{ "compare:", "lda (zeropage_ptr_tmp),y", "iny", "lda (zeropage_ptr_tmp),y", "sta zeropage_math_tmp", "cpx zeropage_math_tmp+1", "cmp zeropage_math_tmp" });
}

test "module image comparisons keep relocation-compatible operand staging" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{ .entry = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{ .id = "compare", .abi = 1, .exports = .{ .entry = entry }, .deps = .{} };
        \\fn entry(value: u8) u8 { return value; }
        \\export fn main() void { var a: u8 = 1; var b: u8 = 2; if (a < b) { a = 3; } }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "cmp zeropage_math_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "cmp main_b") == null);
}

test "typed adjacent struct reads reuse their ordinary RAM pointer base" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const Pair = struct { a: u8, b: u8 };
        \\fn read(pair: *Pair) u16 { const a = pair.a; const b = pair.b; return a + b; }
        \\export fn main() void { var pair = Pair{ .a = 3, .b = 7 }; _ = read(&pair); }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_pointer_reuse source=read_pair") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, "lda (zeropage_ptr_tmp),y"));
    // Count pointer materialization inside the reader; the caller's final-word
    // argument reload also reads this high byte to preserve its pre-JSR A/NZ.
    const begin = std.mem.indexOf(u8, assembly, "read:\n").?;
    const end = std.mem.indexOfPos(u8, assembly, begin, "; zeropage_section_end owner=function:read kind=code").?;
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly[begin..end], "lda read_pair+1"));
}

test "array initializer temporaries and RAM reloads use flag-aware cleanup" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn make(value: u8) u8 {
        \\    var items = [_]u8{ value, 7 };
        \\    const first = items[0];
        \\    const second = first;
        \\    return second;
        \\}
        \\export fn main() void { _ = make(3); }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "stack_pairs=2 reloads=") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    pha\n    pla\n") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "lda make_items+0"));
    try std.testing.expect(std.mem.indexOf(u8, assembly, "lda make_first") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "lda make_second") == null);
}

test "module output retains its existing stack temporaries and relocation path" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{ .entry = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{ .id = "values", .abi = 1, .exports = .{ .entry = entry }, .deps = .{} };
        \\fn entry(value: u8) u8 { return value; }
        \\export fn main() void { var items = [_]u8{ 7, 8 }; _ = items[0]; }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    pha\n    pla\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_value_cleanup stack_pairs=") == null);
}

test "runtime loops guard taken branch page crossings and skip filler" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try runtime.emitClearScreenRoutine(&out.writer);
    try runtime.emitMultiplyRoutine(&out.writer);
    const text = out.written();
    try expectContainsInOrder(text, &.{ ".if (* & $ff) > $f0", "jmp clearScreenLoop", ".fill (($100 - (* & $ff)) & $ff),0", ".endif", "clearScreenLoop:" });
    try expectContainsInOrder(text, &.{ ".if (* & $ff) > $db", "jmp zeropage_mul16_loop", ".fill (($100 - (* & $ff)) & $ff),0", ".endif", "zeropage_mul16_loop:" });
}

test "general multiply consumes each multiplier bit through carry before adding" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try runtime.emitMultiplyRoutine(&out.writer);
    const text = out.written();
    try expectContainsInOrder(text, &.{ "zeropage_mul16_loop:", "lsr zeropage_mul_rhs+1", "ror zeropage_mul_rhs", "bcc zeropage_mul16_skip_add", "lda zeropage_mul_result", "clc", "adc zeropage_mul_lhs", "zeropage_mul16_skip_add:", "asl zeropage_mul_lhs", "rol zeropage_mul_lhs+1", "dex", "bne zeropage_mul16_loop" });
    try std.testing.expect(std.mem.indexOf(u8, text, "and #1") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "beq zeropage_mul16_skip_add") == null);
}

test "module public entry and nested callees survive without resident calls" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .default_frame = .stack },
        \\};
        \\pub const zeropage_module = .{ .id = "public", .abi = 1, .exports = .{ .entry = entry }, .deps = .{} };
        \\fn leaf() u8 { return 1; }
        \\fn identity(value: u8) u8 { return value; }
        \\fn entry() u8 {
        \\    const value: u8 = leaf();
        \\    return identity(value);
        \\}
        \\fn dead() u8 { return 99; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    for ([_][]const u8{ "\nentry:", "\nidentity:", "\nleaf:" }) |label| try std.testing.expect(std.mem.indexOf(u8, assembly, label) != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "\ndead:") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "function=entry status=retained reason=module_export") != null);
}

test "literal minus runtime value keeps subtraction operand order" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn minus(value: u8) u8 { return 17 - value; }
        \\export fn main() void { _ = minus(5); }
    );
    defer parsed.deinit(std.testing.allocator);
    const asm_text = try pipeline.emitBeforeSingleCallLeaf(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{ "minus:", "lda #17", "sec", "sbc minus_value" });
}

test "emits parsed border program" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\export fn main() void { c64.vic.border = 6; }
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta $d020") != null);
}

test "emits parsed text program with calls branch and loop" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\fn drawFrame() void {
        \\    var x: u8 = 0;
        \\    while (x < 22) {
        \\        x += 1;
        \\        if (x == 3) { continue; }
        \\        c64.screen.putAt(3 + x, 4, '*');
        \\        if (x == 10) { break; }
        \\    }
        \\}
        \\fn drawStatus() void {
        \\    var row: u8 = 7;
        \\    if (row == 7) { c64.screen.putsAt(5, 11, "IF BRANCH OK"); } else { c64.screen.putsAt(5, 11, "BAD"); }
        \\}
        \\export fn main() void {
        \\    c64.screen.clear();
        \\    c64.screen.putsAt(3, 2, "ZEROPAGE TEXT DEMO");
        \\    drawFrame();
        \\    drawStatus();
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "while_0_top") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "if_1_else") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr drawFrame") != null);
}

test "emits section ownership markers for code storage scratch runtime and rodata" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\const greeting = "VALUE";
        \\const table = [_]u8{ 2, 3 };
        \\fn helper(a: u8) u8 {
        \\    var local: u8 = a;
        \\    local *= table[0];
        \\    return local;
        \\}
        \\export fn main() void {
        \\    c64.console.clear();
        \\    c64.console.puts(greeting);
        \\    c64.console.print(" {x}\n", .{helper(3)});
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=function:main kind=code lifetime=static address=near") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=function:helper kind=code lifetime=static address=near") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=function:helper kind=static_frame lifetime=static address=near") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "helper_a:\n    .byte 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=compiler kind=scratch lifetime=static address=near") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_mul_lhs:\n    .word 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=runtime kind=data lifetime=static address=near") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_console_x:\n    .byte 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=module:main kind=rodata lifetime=static address=near") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "owner=module:flattened") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_str_greeting:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_arr_table:") != null);
    try expectContainsInOrder(asm_text, &.{
        "; zeropage_section_begin owner=function:main kind=code lifetime=static address=near",
        "; zeropage_section_end owner=function:main kind=code",
        "; zeropage_section_begin owner=function:main kind=static_frame lifetime=static address=near",
        "; zeropage_section_end owner=function:main kind=static_frame",
        "; zeropage_section_begin owner=function:helper kind=code lifetime=static address=near",
        "; zeropage_section_end owner=function:helper kind=code",
        "; zeropage_section_begin owner=function:helper kind=static_frame lifetime=static address=near",
        "helper_a:\n    .byte 0",
        "helper_local:\n    .byte 0",
        "; zeropage_section_end owner=function:helper kind=static_frame",
        "; zeropage_section_begin owner=compiler kind=scratch lifetime=static address=near",
    });
}

test "emits raw REU runtime helpers and ownership markers" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\const test6502 = @import("test6502");
        \\export fn main() void {
        \\    ZeroPage.reu.copyC64ToReu(0x0400, 0x010000, 3);
        \\    ZeroPage.reu.copyReuToC64(0x010000, 0x0420, 3);
        \\    ZeroPage.reu.swap(0x0420, 0x010010, 2);
        \\    ZeroPage.reu.fill(0x010020, 0xaa, 4);
        \\    test6502.expectEqualBool(1, true, ZeroPage.reu.present());
        \\    test6502.expectEqualBool(2, true, ZeroPage.reu.compare(0x0420, 0x010010, 2));
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);

    try expectContainsInOrder(asm_text, &.{
        "lda #0\n    sta zeropage_reu_c64_addr\n    stx zeropage_reu_c64_addr+1\n    sta zeropage_reu_addr\n    sta zeropage_reu_addr+1\n    lda #$01\n    sta zeropage_reu_addr+2",
        "jsr zeropage_reu_copy_c64_to_reu",
        "jsr zeropage_reu_copy_reu_to_c64",
        "jsr zeropage_reu_swap",
        "jsr zeropage_reu_fill",
        "jsr zeropage_reu_present",
        "jsr zeropage_reu_compare",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=runtime kind=code lifetime=static address=near\nzeropage_reu_present:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta $df02") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta $df06") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta $df01") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_reu_fill_byte:\n    .byte 0") != null);
}

test "unused raw REU runtime does not change static assembly" {
    const src =
        \\const c64 = @import("c64");
        \\export fn main() void { c64.vic.border = 6; }
    ;
    const parsed_a = try parser.parseSource(std.testing.allocator, src);
    defer parsed_a.deinit(std.testing.allocator);
    const parsed_b = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\const c64 = @import("c64");
        \\export fn main() void { c64.vic.border = 6; }
    );
    defer parsed_b.deinit(std.testing.allocator);

    const asm_a = try emitProgram(std.testing.allocator, parsed_a.program);
    defer std.testing.allocator.free(asm_a);
    const asm_b = try emitProgram(std.testing.allocator, parsed_b.program);
    defer std.testing.allocator.free(asm_b);

    try std.testing.expectEqualStrings(asm_a, asm_b);
}

test "groups module rodata by source owner" {
    var parsed_import = try parser.parseSourceWithPrefix(std.testing.allocator,
        \\const title = "IMPORTED";
        \\const table = [_]u8{ 4, 5 };
    , "assets");
    defer parsed_import.deinit(std.testing.allocator);
    var parsed_main = try parser.parseSource(std.testing.allocator,
        \\const title = "MAIN";
        \\const table = [_]u8{ 1, 2 };
        \\export fn main() void {}
    );
    defer parsed_main.deinit(std.testing.allocator);

    var string_constants = [_]ast.StringConstant{
        parsed_import.program.string_constants[0],
        parsed_main.program.string_constants[0],
    };
    var array_constants = [_]ast.ArrayConstant{
        parsed_import.program.array_constants[0],
        parsed_main.program.array_constants[0],
    };
    const program = ast.Program{
        .string_constants = &string_constants,
        .array_constants = &array_constants,
        .functions = parsed_main.program.functions,
    };

    const asm_text = try emitProgram(std.testing.allocator, program);
    defer std.testing.allocator.free(asm_text);

    try expectContainsInOrder(asm_text, &.{
        "; zeropage_section_begin owner=module:assets kind=rodata lifetime=static address=near",
        "zeropage_str_assets_title:",
        "zeropage_arr_assets_table:",
        "; zeropage_section_end owner=module:assets kind=rodata",
        "; zeropage_section_begin owner=module:main kind=rodata lifetime=static address=near",
        "zeropage_str_title:",
        "zeropage_arr_table:",
        "; zeropage_section_end owner=module:main kind=rodata",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "owner=module:flattened") == null);
}

test "colocates function static frames after each function code section" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\const test6502 = @import("test6502");
        \\const Pair = struct { left: u8, right: u16 };
        \\fn pairValue(seed: u8) u16 {
        \\    var pair = Pair{ .left = seed, .right = 0x1234 };
        \\    var bytes = [_]u8{ 1, 2, 3 };
        \\    var name = c64.string.buffer(6);
        \\    for (bytes) |item| {
        \\        _ = item;
        \\    }
        \\    bytes[1] = 4;
        \\    return pair.right + bytes[1];
        \\}
        \\fn optionalValue(flag: bool) ?u8 {
        \\    if (flag) { return 7; }
        \\    return null;
        \\}
        \\export fn main() void {
        \\    const value = pairValue(2);
        \\    const maybe = optionalValue(true);
        \\    test6502.expectEqualU16(1, 0x1238, value);
        \\    test6502.expectSomeU8(2, 7, maybe);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);

    try expectContainsInOrder(asm_text, &.{
        "; zeropage_section_begin owner=function:main kind=code lifetime=static address=near",
        "; zeropage_section_end owner=function:main kind=code",
        "; zeropage_section_begin owner=function:main kind=static_frame lifetime=static address=near",
        "main_value:\n    .word 0",
        "main_maybe:\n    .byte 0\n    .byte 0",
        "; zeropage_section_end owner=function:main kind=static_frame",
        "; zeropage_section_begin owner=function:pairValue kind=code lifetime=static address=near",
        "; zeropage_section_end owner=function:pairValue kind=code",
        "; zeropage_section_begin owner=function:pairValue kind=static_frame lifetime=static address=near",
        "pairValue_seed:\n    .byte 0",
        "pairValue_pair:\n",
        "pairValue_pair_left:\n    .byte 0",
        "pairValue_pair_right:\n    .word 0",
        "pairValue_bytes:\n    .byte 0,0,0",
        "pairValue_name_len:\n    .byte 0",
        "pairValue_name_data:\n    .byte 0,0,0,0,0,0",
        "pairValue_for_0_index:\n    .word 0",
        "pairValue_item:\n    .byte 0",
        "; zeropage_section_end owner=function:pairValue kind=static_frame",
        "; zeropage_section_begin owner=function:optionalValue kind=code lifetime=static address=near",
        "; zeropage_section_end owner=function:optionalValue kind=code",
        "; zeropage_section_begin owner=function:optionalValue kind=static_frame lifetime=static address=near",
        "optionalValue_flag:\n    .byte 0",
        "optionalValue_return:\n    .byte 0\n    .byte 0",
        "; zeropage_section_end owner=function:optionalValue kind=static_frame",
    });
}

test "emits leaf main on ZeroPage software stack" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400, .zp = .{ .sp = 0xf3, .fp = 0xf5 } },
        \\    .abi = .{ .functions = .{ .main = .{ .frame = .stack } } },
        \\};
        \\export fn main() void {
        \\    var border: u8 = 2;
        \\    var total: u16 = 0x0100;
        \\    total += 5;
        \\    if (total > 0) {
        \\        border = 5;
        \\    }
        \\    c64.vic.border = border;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_sp = $f3") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_fp = $f5") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda #$00\n    sta zeropage_stack_sp") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda #$c8\n    sta zeropage_stack_sp+1") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta (zeropage_stack_fp),y") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda (zeropage_stack_fp),y") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta $d020") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_border:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=function:main kind=static_frame") == null);
}

test "emits static caller to ZeroPage software stack helper bridge" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400, .zp = .{ .sp = 0xf3, .fp = 0xf5 } },
        \\    .abi = .{ .functions = .{ .add8 = .{ .frame = .stack }, .add16 = .{ .frame = .stack } } },
        \\};
        \\fn add8(a: u8, b: u8) u8 {
        \\    var total: u8 = a + b;
        \\    return total;
        \\}
        \\fn add16(a: u16, b: u16) u16 {
        \\    var total: u16 = a + b;
        \\    return total;
        \\}
        \\export fn main() void {
        \\    var byte: u8 = add8(2, 3);
        \\    var word: u16 = add16(0x0100, 5);
        \\    _ = byte;
        \\    _ = word;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_sp = $f3") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_fp = $f5") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta (zeropage_stack_fp),y") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr add8") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr add16") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_ret_lo:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_ret_hi:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=function:add8 kind=code lifetime=static address=near") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=function:add8 kind=static_frame") == null);
    try expectContainsInOrder(asm_text, &.{
        "main:",
        "sta zeropage_stack_fp",
        "adc #$05",
        "stx zeropage_stack_sp",
        "sta (zeropage_stack_fp),y",
        "jsr add8",
        "ldy zeropage_stack_fp\n    sty zeropage_stack_sp",
        "ldy zeropage_stack_fp+1\n    sty zeropage_stack_sp+1",
        "jsr add16",
        "ldy zeropage_stack_fp\n    sty zeropage_stack_sp",
    });
}

test "static stack return cells survive register and resident address observations" {
    const a = std.testing.allocator;
    const source =
        \\const test6502 = @import("test6502");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 64 },
        \\    .abi = .{ .functions = .{ .worker = .{ .frame = .stack } } },
        \\};
        \\fn worker(word: u16) u16 { return word; }
        \\export fn main() void {
        \\    _ = worker(0x1234);
    ;
    for ([_][]const u8{
        "\n    test6502.expectY(1, 0);\n}",
        "\n    test6502.expectMemU8(1, 0x080d, 0);\n}",
    }) |suffix| {
        const text = try std.mem.concat(a, u8, &.{ source, suffix });
        defer a.free(text);
        const parsed = try parser.parseSource(a, text);
        defer parsed.deinit(a);
        const assembly = try pipeline.emitUnoptimizedAssembly(a, parsed.program);
        defer a.free(assembly);
        try expectContainsInOrder(assembly, &.{
            "jsr worker\n    sta zeropage_stack_ret_lo\n    stx zeropage_stack_ret_hi",
            "lda zeropage_stack_ret_lo\n    ldx zeropage_stack_ret_hi",
            "zeropage_stack_ret_lo:",
            "zeropage_stack_ret_hi:",
        });
    }
}

test "emits ZeroPage software stack caller to static helper bridge" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400, .zp = .{ .sp = 0xf3, .fp = 0xf5 } },
        \\    .abi = .{ .functions = .{ .main = .{ .frame = .stack } } },
        \\};
        \\fn add8(a: u8, b: u8) u8 {
        \\    return a + b;
        \\}
        \\fn add16(a: u16, b: u16) u16 {
        \\    return a + b;
        \\}
        \\export fn main() void {
        \\    var byte: u8 = add8(2, 3);
        \\    var word: u16 = add16(0x0100, 5);
        \\    _ = byte;
        \\    _ = word;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_sp = $f3") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_fp = $f5") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta add8_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta add16_a\n    stx add16_a+1") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta (zeropage_stack_sp),y") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda (zeropage_stack_sp),y") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr add8") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr add16") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_ret_lo:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_ret_hi:") != null);
    try expectContainsInOrder(asm_text, &.{
        "main:",
        "sta add8_a",
        "sta add8_b",
        "sta (zeropage_stack_sp),y",
        "adc #$02",
        "jsr add8",
        "sta zeropage_stack_ret_lo",
        "sec\n    lda zeropage_stack_sp\n    sbc #$02",
        "lda (zeropage_stack_sp),y",
        "sta zeropage_stack_fp",
        "lda zeropage_stack_ret_lo",
        "sta add16_a",
        "jsr add16",
        "stx zeropage_stack_ret_hi",
        "lda zeropage_stack_ret_lo",
        "ldx zeropage_stack_ret_hi",
    });
}

test "emits stack caller to imported static helper label" {
    var parsed_import = try parser.parseSourceWithPrefix(std.testing.allocator,
        \\fn add8(a: u8, b: u8) u8 {
        \\    return a + b;
        \\}
    , "math");
    defer parsed_import.deinit(std.testing.allocator);
    var parsed_main = try parser.parseSource(std.testing.allocator,
        \\const math = @import("math.zp64");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{ .main = .{ .frame = .stack } } },
        \\};
        \\export fn main() void {
        \\    var value: u8 = math.add8(2, 3);
        \\    _ = value;
        \\}
    );
    defer parsed_main.deinit(std.testing.allocator);

    var functions = [_]ast.Function{
        parsed_import.program.functions[0],
        parsed_main.program.functions[0],
    };
    const program = ast.Program{
        .zeropage_options = parsed_main.program.zeropage_options,
        .functions = &functions,
    };

    const asm_text = try emitProgram(std.testing.allocator, program);
    defer std.testing.allocator.free(asm_text);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta math_add8_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr math_add8") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=function:math_add8 kind=static_frame") != null);
}

test "emits ZeroPage software stack caller to stack helper bridge" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400, .zp = .{ .sp = 0xf3, .fp = 0xf5 } },
        \\    .abi = .{ .functions = .{ .main = .{ .frame = .stack }, .add8 = .{ .frame = .stack }, .add16 = .{ .frame = .stack } } },
        \\};
        \\fn add8(a: u8, b: u8) u8 {
        \\    return a + b;
        \\}
        \\fn add16(a: u16, b: u16) u16 {
        \\    return a + b;
        \\}
        \\export fn main() void {
        \\    var byte: u8 = add8(2, 3);
        \\    var word: u16 = add16(0x0100, 5);
        \\    _ = byte;
        \\    _ = word;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_sp = $f3") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_fp = $f5") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta (zeropage_stack_sp),y") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr add8") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr add16") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_ret_lo:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_ret_hi:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=function:add8 kind=static_frame") == null);
    try expectContainsInOrder(asm_text, &.{
        "main:",
        "sta (zeropage_stack_fp),y",
        "lda (zeropage_stack_fp),y",
        "sta (zeropage_stack_sp),y",
        "sta zeropage_stack_fp",
        "adc #$04",
        "jsr add8\n    pha",
        "sec\n    lda zeropage_stack_fp\n    sbc #$02\n    sta zeropage_stack_sp",
        "lda zeropage_stack_fp+1\n    sbc #0\n    sta zeropage_stack_sp+1",
        "lda (zeropage_stack_sp),y",
        "sta zeropage_stack_fp",
        "sta zeropage_stack_fp+1\n    pla",
        "jsr add16\n    pha",
        "sta zeropage_stack_fp+1\n    pla",
    });
}

test "nested stack return uses cells when the hardware stack page is observed" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a,
        \\const test6502 = @import("test6502");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 256 },
        \\    .abi = .{ .default_frame = .stack },
        \\};
        \\fn worker(a: u16) u16 { return a; }
        \\export fn main() void {
        \\    _ = worker(0x1234);
        \\    test6502.expectMemU8(1, 0x01ff, 0);
        \\}
    );
    defer parsed.deinit(a);
    const assembly = try pipeline.emitUnoptimizedAssembly(a, parsed.program);
    defer a.free(assembly);
    try expectContainsInOrder(assembly, &.{
        "jsr worker\n    sta zeropage_stack_ret_lo\n    stx zeropage_stack_ret_hi",
        "lda zeropage_stack_ret_lo\n    ldx zeropage_stack_ret_hi",
        "zeropage_stack_ret_lo:",
    });
}

test "nested stack bridge checks caller link and callee frame together" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc8fa, .size = 6 },
        \\    .abi = .{ .default_frame = .stack },
        \\};
        \\fn identity(value: u16) u16 { return value; }
        \\export fn main() void { _ = identity(0x805a); }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, "_overflow:\n    jmp zeropage_stack_overflow_trap"));
    try expectContainsInOrder(assembly, &.{
        "adc #$04\n    tax\n    lda zeropage_stack_sp+1",
        "zeropage_stack_guard_1_ok:",
        "    sta (zeropage_stack_sp),y",
        "    jsr identity",
    });
}

test "stack bridges forward typed frame slots and stage computed arguments" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc8f0, .size = 32 },
        \\    .abi = .{ .default_frame = .stack },
        \\};
        \\fn pair(wide: u16, byte: u8) u16 { return wide; }
        \\fn direct(wide: u16, byte: u8) u16 { return pair(wide, byte); }
        \\fn staged(wide: u16, byte: u8) u16 { return pair(wide, byte + 1); }
        \\export fn main() void { _ = direct(257, 3); _ = staged(257, 3); }
    );
    defer parsed.deinit(a);
    const assembly = try pipeline.emitUnoptimizedAssembly(a, parsed.program);
    defer a.free(assembly);

    const direct = std.mem.indexOf(u8, assembly, "\ndirect:\n").?;
    const staged = std.mem.indexOf(u8, assembly, "\nstaged:\n").?;
    const guard = "    lda zeropage_stack_sp\n    clc\n    adc #$05";
    try std.testing.expect(std.mem.startsWith(u8, assembly[direct + "\ndirect:\n".len ..], guard));
    try expectContainsInOrder(assembly[direct..staged], &.{
        guard,
        "sta zeropage_stack_sp+1",
        "ldy #$01\n    lda (zeropage_stack_fp),y\n    tax\n    ldy #$00\n    lda (zeropage_stack_fp),y",
        "ldy #$02\n    lda (zeropage_stack_fp),y\n    ldy #$02\n    sta (zeropage_stack_sp),y",
        "jsr pair",
    });
    try expectContainsInOrder(assembly[staged..], &.{
        "ldy #$03\n    sta (zeropage_stack_fp),y",
        guard,
        "ldy #$04\n    lda (zeropage_stack_fp),y\n    tax",
        "jsr pair",
    });
}

test "stack word forwarding preserves the last wide argument in X" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc8f0, .size = 32 },
        \\    .abi = .{ .default_frame = .stack },
        \\};
        \\fn worker(a: u16, b: u16, tag: u8) u16 { _ = tag; return a - b; }
        \\fn relay(a: u16, b: u16, tag: u8) u16 { return worker(a, b, tag); }
        \\export fn main() void { _ = relay(0x8142, 0x02ff, 5); }
    );
    defer parsed.deinit(a);
    const assembly = try pipeline.emitUnoptimizedAssembly(a, parsed.program);
    defer a.free(assembly);
    const relay = std.mem.indexOf(u8, assembly, "\nrelay:\n").?;
    try expectContainsInOrder(assembly[relay..], &.{
        "ldy #$00\n    lda (zeropage_stack_fp),y\n    ldy #$00\n    sta (zeropage_stack_sp),y",
        "ldy #$01\n    lda (zeropage_stack_fp),y\n    ldy #$01\n    sta (zeropage_stack_sp),y",
        "ldy #$03\n    lda (zeropage_stack_fp),y\n    tax\n    ldy #$02",
        "ldy #$04\n    lda (zeropage_stack_fp),y\n    ldy #$04\n    sta (zeropage_stack_sp),y",
        "jsr worker",
    });
}

test "nested stack reservation adds a high byte for a 255-byte callee frame" {
    const a = std.testing.allocator;
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    try source.writer.writeAll(
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0200 },
        \\    .abi = .{ .default_frame = .stack },
        \\};
        \\fn wide(value: u8) u8 {
        \\
    );
    for (0..127) |index| try source.writer.print("    var local{d}: u16 = 0;\n", .{index});
    try source.writer.writeAll("    return value;\n}\nexport fn main() void { _ = wide(0x5a); }\n");

    const parsed = try parser.parseSource(a, source.written());
    defer parsed.deinit(a);
    const assembly = try pipeline.emitUnoptimizedAssembly(a, parsed.program);
    defer a.free(assembly);
    try expectContainsInOrder(assembly, &.{
        "adc #$01\n    tax\n    lda zeropage_stack_sp+1\n    adc #1",
        "    cmp #$ca",
        "zeropage_stack_guard_1_ok:",
        "    adc #$ff",
        "    jsr wide",
    });
}

test "emits stack caller to imported stack helper label" {
    var parsed_import = try parser.parseSourceWithPrefix(std.testing.allocator,
        \\fn add8(a: u8, b: u8) u8 {
        \\    return a + b;
        \\}
    , "math");
    defer parsed_import.deinit(std.testing.allocator);
    var parsed_main = try parser.parseSource(std.testing.allocator,
        \\const math = @import("math.zp64");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{ .main = .{ .frame = .stack }, .math_add8 = .{ .frame = .stack } } },
        \\};
        \\export fn main() void {
        \\    var value: u8 = math.add8(2, 3);
        \\    _ = value;
        \\}
    );
    defer parsed_main.deinit(std.testing.allocator);

    var functions = [_]ast.Function{
        parsed_import.program.functions[0],
        parsed_main.program.functions[0],
    };
    const program = ast.Program{
        .zeropage_options = parsed_main.program.zeropage_options,
        .functions = &functions,
    };

    const asm_text = try emitProgram(std.testing.allocator, program);
    defer std.testing.allocator.free(asm_text);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr math_add8") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta (zeropage_stack_sp),y") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=function:math_add8 kind=static_frame") == null);
}

test "compacts stack word traffic and drops only the impossible zero-limit branch" {
    const source =
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc8f8, .size = 8 },
        \\    .abi = .{ .functions = .{ .mix = .{ .frame = .stack } } },
        \\};
        \\fn mix(a: u16, b: u16) u16 { return a - (b + 1); }
        \\export fn main() void { _ = mix(0x8000, 1); }
    ;
    const a = std.testing.allocator;
    for ([_]struct { text: []const u8, compact: bool }{
        .{ .text = source, .compact = true },
        .{ .text = "pub const zeropage_module = .{ .id = \"bridge\", .abi = 1, .flags = .{}, .exports = .{ .entry = entry }, .deps = .{} };\nfn entry() u8 { return 7; }\n" ++ source, .compact = false },
    }) |variant| {
        const parsed = try parser.parseSource(a, variant.text);
        defer parsed.deinit(a);
        const assembly = try pipeline.emitUnoptimizedAssembly(a, parsed.program);
        defer a.free(assembly);
        try std.testing.expectEqual(variant.compact, std.mem.indexOf(u8, assembly, "    txa\n    iny\n    sta (zeropage_stack_fp),y") != null);
        try std.testing.expectEqual(variant.compact, std.mem.indexOf(u8, assembly, "    dey\n    lda (zeropage_stack_fp),y") != null);
        try std.testing.expectEqual(!variant.compact, std.mem.indexOf(u8, assembly, "    pha\n    txa\n    tax\n    pla") != null);
        try std.testing.expectEqual(variant.compact, std.mem.indexOf(u8, assembly, "    beq zeropage_stack_guard_0_ok\nzeropage_stack_guard_0_overflow:") != null);
    }
}

test "direct stack word arithmetic keeps the staging path for stack observers" {
    const a = std.testing.allocator;
    const source =
        \\const test6502 = @import("test6502");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 64 },
        \\    .abi = .{ .functions = .{ .mix = .{ .frame = .stack } } },
        \\};
        \\fn mix(a: u16, b: u16) u16 { return a - b; }
        \\export fn main() void {
        \\    _ = mix(0x8000, 1);
    ;
    for ([_]struct { suffix: []const u8, direct: bool }{
        .{ .suffix = "\n}", .direct = true },
        .{ .suffix = "\n    test6502.expectMemU8(1, 0xc805, 0);\n}", .direct = false },
    }) |variant| {
        const text = try std.mem.concat(a, u8, &.{ source, variant.suffix });
        defer a.free(text);
        const parsed = try parser.parseSource(a, text);
        defer parsed.deinit(a);
        const assembly = try pipeline.emitUnoptimizedAssembly(a, parsed.program);
        defer a.free(assembly);
        const direct = "    sec\n    ldy #$02\n    sbc (zeropage_stack_fp),y";
        try std.testing.expectEqual(variant.direct, std.mem.indexOf(u8, assembly, direct) != null);
    }
}

test "direct stack byte branches keep boolean value lowering and respect observers" {
    const a = std.testing.allocator;
    const source =
        \\const test6502 = @import("test6502");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 64 },
        \\    .abi = .{ .functions = .{ .check = .{ .frame = .stack } } },
        \\};
        \\fn check(a: u8) bool {
        \\    if (a < 16) { return false; }
        \\    return a != 255;
        \\}
        \\export fn main() void {
        \\    _ = check(32);
    ;
    for ([_]struct { suffix: []const u8, direct: bool }{
        .{ .suffix = "\n}", .direct = true },
        .{ .suffix = "\n    test6502.expectMemU8(1, 0xc801, 0);\n}", .direct = false },
    }) |variant| {
        const text = try std.mem.concat(a, u8, &.{ source, variant.suffix });
        defer a.free(text);
        const parsed = try parser.parseSource(a, text);
        defer parsed.deinit(a);
        const assembly = try pipeline.emitUnoptimizedAssembly(a, parsed.program);
        defer a.free(assembly);
        const direct = "    cmp #$10\n    bcc zeropage_stack_cond_0_body\n    jmp if_0_else";
        try std.testing.expectEqual(variant.direct, std.mem.indexOf(u8, assembly, direct) != null);
        try std.testing.expect(std.mem.indexOf(u8, assembly, "bne stack_cmp_2_true") != null);
    }
}

test "static stack bridge publishes the checked end only before pure scalar arguments" {
    const a = std.testing.allocator;
    const source =
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc8fc, .size = 4 },
        \\    .abi = .{ .functions = .{ .worker = .{ .frame = .stack } } },
        \\};
        \\fn worker(a: u16, b: u16) u16 { _ = b; return a; }
        \\export fn main() void {
        \\    const word: u16 = 0x1200;
    ;
    for ([_]struct { call: []const u8, early: bool }{
        .{ .call = "\n    _ = worker(word + 1, 2);\n}", .early = true },
        .{ .call = "\n    const ptr: *volatile u16 = @ptrFromInt(0x2000);\n    _ = worker(ptr.*, 2);\n}", .early = false },
    }) |variant| {
        const text = try std.mem.concat(a, u8, &.{ source, variant.call });
        defer a.free(text);
        const parsed = try parser.parseSource(a, text);
        defer parsed.deinit(a);
        const assembly = try pipeline.emitUnoptimizedAssembly(a, parsed.program);
        defer a.free(assembly);
        const early = "zeropage_stack_guard_0_ok:\n    stx zeropage_stack_sp\n    sta zeropage_stack_sp+1";
        const late = "    sta zeropage_stack_sp+1\n    jsr worker";
        try std.testing.expectEqual(variant.early, std.mem.indexOf(u8, assembly, early) != null);
        try std.testing.expectEqual(!variant.early, std.mem.indexOf(u8, assembly, late) != null);
    }
}

test "emits recursive ZeroPage software stack calls with overflow guards" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0010, .zp = .{ .sp = 0xf3, .fp = 0xf5 } },
        \\    .abi = .{ .functions = .{
        \\        .main = .{ .frame = .stack },
        \\        .countdown = .{ .frame = .stack },
        \\        .isEven = .{ .frame = .stack },
        \\        .isOdd = .{ .frame = .stack },
        \\    } },
        \\};
        \\fn countdown(value: u8) u8 {
        \\    if (value == 0) {
        \\        return 5;
        \\    }
        \\    return countdown(value - 1);
        \\}
        \\fn isEven(value: u8) bool {
        \\    if (value == 0) {
        \\        return true;
        \\    }
        \\    return isOdd(value - 1);
        \\}
        \\fn isOdd(value: u8) bool {
        \\    if (value == 0) {
        \\        return false;
        \\    }
        \\    return isEven(value - 1);
        \\}
        \\export fn main() void {
        \\    var value: u8 = countdown(3);
        \\    var ok: bool = isEven(4);
        \\    _ = value;
        \\    _ = ok;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_sp = $f3") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "cmp #$c8") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "cpx #$10") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "bcs zeropage_stack_guard_") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_overflow_trap:\n    brk") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr countdown") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr isOdd") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr isEven") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "unsupported stack frame recursion") == null);
}

test "stack reservations retain the carry guard for observable or wrapping pointers" {
    const a = std.testing.allocator;
    const source =
        \\const test6502 = @import("test6502");
        \\fn work(x: u8) u8 { return x; }
        \\export fn main() void { _ = work(1);
    ;
    for ([_]struct { base: u16, suffix: []const u8, checks_carry: bool }{
        .{ .base = 0xc8fe, .suffix = "}", .checks_carry = false },
        .{ .base = 0xc8fe, .suffix = "test6502.expectMemU8(1, 0xf7, 0); }", .checks_carry = true },
        .{ .base = 0xfffe, .suffix = "}", .checks_carry = true },
    }) |row| {
        const text = try std.fmt.allocPrint(a, "pub const zeropage_options = .{{ .stack = .{{ .base = {d}, .size = 2 }}, .abi = .{{ .functions = .{{ .work = .{{ .frame = .stack }} }} }} }};\n{s}\n{s}", .{ row.base, source, row.suffix });
        defer a.free(text);
        const parsed = try parser.parseSource(a, text);
        defer parsed.deinit(a);
        const assembly = try pipeline.emitUnoptimizedAssembly(a, parsed.program);
        defer a.free(assembly);
        try std.testing.expectEqual(row.checks_carry, std.mem.indexOf(u8, assembly, "bcs zeropage_stack_guard_0_overflow") != null);
        try std.testing.expect(std.mem.indexOf(u8, assembly, "bcc zeropage_stack_guard_0_ok") != null);
    }
}

test "static-only output does not emit ZeroPage software stack overflow trap" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\export fn main() void {
        \\    var value: u8 = 5;
        \\    _ = value;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_overflow_trap") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_guard_") == null);
}

test "emits fixed array for loops with stable labels" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const test6502 = @import("test6502");
        \\const values = [_]u8{ 1, 2, 3 };
        \\export fn main() void {
        \\    var sum: u8 = 0;
        \\    for (values) |item| {
        \\        sum += item;
        \\    }
        \\    for (values, 0..) |value, index| {
        \\        sum += value + index;
        \\        continue;
        \\    }
        \\    for (0..values.len) |i| {
        \\        if (i == 2) { break; }
        \\        sum += values[i];
        \\    }
        \\    test6502.expectEqualU8(1, 18, sum);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "for_0_top") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "for_1_next") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "for_2_done") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_for_0_index") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_index:\n    .word 0") != null);
}

test "emits scalar pointer address-of and dereference stores" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const test6502 = @import("test6502");
        \\export fn main() void {
        \\    var byte: u8 = 1;
        \\    var word: u16 = 0;
        \\    const byte_ptr: *u8 = &byte;
        \\    const word_ptr: *u16 = &word;
        \\    byte_ptr.* = 7;
        \\    word_ptr.* = 0x1234;
        \\    test6502.expectEqualU8(1, 7, byte);
        \\    test6502.expectEqualU16(2, 0x1234, word);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "#<main_byte") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta (zeropage_ptr_tmp),y") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_ptr_value") != null);
}

test "emits volatile pointer from integer for MMIO stores" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\export fn main() void {
        \\    const border: *volatile u8 = @ptrFromInt(0xd020);
        \\    border.* = 6;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_border") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta (zeropage_ptr_tmp),y") != null);
}

test "emits many-item pointer indexing loads and stores" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\export fn main() void {
        \\    const bytes: [*]volatile u8 = @ptrFromInt(0x0400);
        \\    const words: [*]u16 = @ptrFromInt(0x0800);
        \\    bytes[2] = 7;
        \\    words[1] = 0x1234;
        \\    const b: u8 = bytes[2];
        \\    const w: u16 = words[1];
        \\    _ = b;
        \\    _ = w;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_words") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta (zeropage_ptr_tmp),y") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda (zeropage_ptr_tmp),y") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta zeropage_ptr_value") != null);
}

test "emits struct pointer field and nested array mutation" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const test6502 = @import("test6502");
        \\const Cell = enum(u8) { empty, x, o };
        \\const Board = struct { cells: [3]Cell, score: u16, turn: Cell };
        \\fn mutate(board: *Board, index: u8) void {
        \\    board.cells[index] = .x;
        \\    board.score += 3;
        \\    board.turn = .o;
        \\}
        \\export fn main() void {
        \\    var board = Board{ .cells = [_]Cell{ .empty, .empty, .empty }, .score = 10, .turn = .x };
        \\    mutate(&board, 1);
        \\    test6502.expectEqualU8(1, 1, board.cells[1]);
        \\    test6502.expectEqualU16(2, 13, board.score);
        \\    test6502.expectEqualU8(3, 2, board.turn);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_board:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "mutate_board:\n    .word 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_ptr_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta (zeropage_ptr_tmp),y") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "ldy #3\n    lda (zeropage_ptr_tmp),y") != null);
}

test "emits limited scalar as casts" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const test6502 = @import("test6502");
        \\export fn main() void {
        \\    const byte: u8 = @as(u8, 3);
        \\    const word: u16 = @as(u16, byte);
        \\    const screen: [*]volatile u8 = @as([*]volatile u8, @ptrFromInt(0x0400));
        \\    screen[@as(u8, 1)] = byte;
        \\    test6502.expectEqualU16(1, 3, word);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_screen") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "ldx #4") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta (zeropage_ptr_tmp),y") != null);
}

test "emits layout comptime builtins as immediate values" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const test6502 = @import("test6502");
        \\const Cell = enum(u8) { empty, x, o };
        \\const Header = struct { tag: u8, word: u16, cell: Cell, ok: bool };
        \\const Nested = struct { a: u8, header: Header, tail: u16 };
        \\const Event = union(enum) { none, key: u8, word: u16 };
        \\export fn main() void {
        \\    var bytes: [@sizeOf(Header) + @alignOf(Header)]u8 = .{ 0, 1, 2, 3, 4, 5 };
        \\    test6502.expectEqualU16(1, 5, @sizeOf(Header));
        \\    test6502.expectEqualU16(2, 3, @sizeOf(Event));
        \\    test6502.expectEqualU16(3, 4, @offsetOf(Header, "ok"));
        \\    test6502.expectEqualU16(4, 2, @offsetOf(Nested, "header.word"));
        \\    test6502.expectEqualU8(5, 5, bytes[5]);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_bytes:\n    .byte 0,0,0,0,0,0") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "    ldx #$00\n    lda #$05") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "    ldx #$00\n    lda #$03") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "    ldx #$00\n    lda #$04") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "    ldx #$00\n    lda #$02") != null);
}

test "emits functions with params returns bools and struct fields" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\const Marker = struct { x: u8, ch: u8 };
        \\fn add8(a: u8, b: u8) u8 { return a + b; }
        \\fn isFive(v: u8) bool { return v == 5; }
        \\export fn main() void {
        \\    var total: u8 = add8(2, 3);
        \\    var ok: bool = isFive(total);
        \\    var base: u16 = 1024;
        \\    var delta: i8 = 1;
        \\    var signed_base: i16 = 2048;
        \\    var screen_ptr: usize = 1024;
        \\    var marker = Marker{ .x = 12, .ch = '*' };
        \\    c64.screen.hexAt(2, 2, total);
        \\    c64.screen.hex16At(5, 2, base);
        \\    if (ok == true) { c64.screen.putAt(marker.x, 10, marker.ch); }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try pipeline.emitBeforeSingleCallLeaf(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr add8") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_marker_x") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "hexNibbleToScreen") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, ".word 0") != null);
}

test "emits enum tags and flattened nested composite storage" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const test6502 = @import("test6502");
        \\const Cell = enum(u8) { empty = 0, x = 1, o };
        \\const Board = struct { cells: [9]Cell };
        \\const Game = struct { board: Board, history: [9]u8, move_count: u8 };
        \\fn winner(cell: Cell) Cell { return cell; }
        \\export fn main() void {
        \\    var game = Game{
        \\        .board = Board{ .cells = [_]Cell{ .empty, .empty, .empty, .empty, .empty, .empty, .empty, .empty, .empty } },
        \\        .history = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        \\        .move_count = 0,
        \\    };
        \\    game.board.cells[0] = Cell.x;
        \\    game.history[0] = 4;
        \\    const chosen: Cell = if (game.board.cells[0] == .x) .o else .empty;
        \\    const from_switch: Cell = switch (winner(chosen)) {
        \\        Cell.o => .x,
        \\        else => .empty,
        \\    };
        \\    test6502.expectEqualU8(1, 1, game.board.cells[0]);
        \\    test6502.expectEqualU8(2, 4, game.history[0]);
        \\    test6502.expectEqualU8(3, 1, from_switch);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_game_board_cells:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_game_history:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_game_move_count:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_chosen:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "switch_expr_") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda #1") != null);
}

test "emits fixed arrays of struct field loads and stores" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const test6502 = @import("test6502");
        \\const Point = struct { x: u8, y: u8 };
        \\const WordPoint = struct { x: u16, y: u16 };
        \\const points_const = [_]Point{ Point{ .x = 1, .y = 2 }, Point{ .x = 3, .y = 4 } };
        \\export fn main() void {
        \\    var points: [2]Point = .{ Point{ .x = 5, .y = 6 }, Point{ .x = 7, .y = 8 } };
        \\    var words: [2]WordPoint = .{ WordPoint{ .x = 256, .y = 511 }, WordPoint{ .x = 1024, .y = 2048 } };
        \\    var idx: u8 = 1;
        \\    points[idx].x = points_const[0].y;
        \\    words[idx].y = words[0].x + 1;
        \\    test6502.expectEqualU8(1, 2, points[1].x);
        \\    test6502.expectEqualU16(2, 257, words[1].y);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_arr_points_const:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_points:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_words:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr zeropage_stride_mul_4") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_mul_lhs:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_mul_result:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_mul_rhs:\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta (zeropage_ptr_tmp),y") != null);
}

test "emits limited struct value copies params and returns" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const test6502 = @import("test6502");
        \\const Cell = enum(u8) { empty, x, o };
        \\const Board = struct { cells: [3]Cell, count: u8 };
        \\fn makeBoard(mark: Cell) Board {
        \\    return Board{ .cells = [_]Cell{ mark, .empty, .o }, .count = 2 };
        \\}
        \\fn score(board: Board) u8 {
        \\    return board.count + board.cells[0] + board.cells[2];
        \\}
        \\export fn main() void {
        \\    var board = makeBoard(.x);
        \\    const snap = board;
        \\    var other: Board = Board{ .cells = [_]Cell{ .empty, .empty, .empty }, .count = 0 };
        \\    other = board;
        \\    test6502.expectEqualU8(1, 5, score(other));
        \\    test6502.expectEqualU8(2, 1, snap.cells[0]);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "makeBoard_return_cells:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "score_board_cells:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_snap_cells:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda main_board_cells+0\n    sta main_other_cells+0") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda main_other_cells+0\n    sta score_board_cells+0") != null);
}

test "compacts large struct value copies with generated copy loops" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const test6502 = @import("test6502");
        \\const Cell = enum(u8) { empty, x, o };
        \\const Board = struct { cells: [9]Cell };
        \\const Game = struct { board: Board, history: [9]u8, move_count: u8 };
        \\fn makeGame() Game {
        \\    return Game{
        \\        .board = Board{ .cells = [_]Cell{ .empty, .empty, .empty, .empty, .empty, .empty, .empty, .empty, .empty } },
        \\        .history = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8 },
        \\        .move_count = 9,
        \\    };
        \\}
        \\fn score(game: Game) u8 { return game.history[8] + game.move_count; }
        \\export fn main() void {
        \\    var game = makeGame();
        \\    const snap = game;
        \\    test6502.expectEqualU8(1, 17, score(snap));
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_game:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_snap:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_copy_") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda makeGame_return,x") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta main_game,x") != null);
}

test "prunes unused clear screen and hex helpers" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\export fn main() void {
        \\    c64.vic.border = 6;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "clearScreen:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "consolePutHexByte:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "hexNibbleToScreen:") == null);
}

test "emits only needed console and hex helpers" {
    const console_only = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\export fn main() void {
        \\    c64.console.print("HELLO\n", .{});
        \\}
    );
    defer console_only.deinit(std.testing.allocator);
    const console_asm = try emitProgram(std.testing.allocator, console_only.program);
    defer std.testing.allocator.free(console_asm);
    try std.testing.expect(std.mem.indexOf(u8, console_asm, "consolePutChar:") != null);
    try std.testing.expect(std.mem.indexOf(u8, console_asm, "consolePutHexByte:") == null);
    try std.testing.expect(std.mem.indexOf(u8, console_asm, "hexNibbleToScreen:") == null);

    const hex_at = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\export fn main() void {
        \\    c64.screen.hexAt(0, 0, 15);
        \\}
    );
    defer hex_at.deinit(std.testing.allocator);
    const hex_asm = try emitProgram(std.testing.allocator, hex_at.program);
    defer std.testing.allocator.free(hex_asm);
    try std.testing.expect(std.mem.indexOf(u8, hex_asm, "hexNibbleToScreen:") != null);
    try std.testing.expect(std.mem.indexOf(u8, hex_asm, "consolePutHexByte:") == null);
}

test "emits console print newline scroll runtime and CIA sleep" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\export fn main() void {
        \\    c64.console.clear();
        \\    var i: u8 = 30;
        \\    c64.console.print("HELLO {s} {x}\n", .{ "WORLD", i });
        \\    c64.time.sleepTicks(add(0, 1));
        \\    c64.time.sleepFrames(add(0, 1));
        \\}
        \\fn add(a: u8, b: u8) u8 { return a + b; }
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "consolePutChar") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "consoleScroll") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sleepTicks") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "$dc04") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sleepFrames") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "$d012") != null);
}

test "emits PETSCII string constants and length-counted console and KERNAL calls" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\const greeting = "hello";
        \\const kernal_line = "kernal\n";
        \\const file_name = "demo,s,w";
        \\export fn main() void {
        \\    c64.console.clear();
        \\    c64.console.print("{s}\n", .{greeting});
        \\    c64.console.puts(greeting);
        \\    c64.kernal.puts(kernal_line);
        \\    c64.kernal.setName(file_name);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_str_greeting:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, ".byte $48,$45,$4c,$4c,$4f") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "$00") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr consolePutString") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "petsciiToScreen") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr $ffd2") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr $ffbd") != null);
}

test "rejects scalar for string formatter and string for hex formatter" {
    const bad_string_arg = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\export fn main() void {
        \\    c64.console.print("{s}", .{1});
        \\}
    );
    defer bad_string_arg.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedFormatArgument, emitProgram(std.testing.allocator, bad_string_arg.program));

    const bad_hex_arg = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\const msg = "nope";
        \\export fn main() void {
        \\    c64.console.print("{x}", .{msg});
        \\}
    );
    defer bad_hex_arg.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedFormatArgument, emitProgram(std.testing.allocator, bad_hex_arg.program));
}

test "emits mutable string buffer assignment append and output" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\const prefix = "hello, ";
        \\const subject = "mutable";
        \\export fn main() void {
        \\    var msg = c64.string.buffer(32);
        \\    msg = prefix ++ subject;
        \\    c64.string.append(msg, " ok\n");
        \\    c64.console.puts(msg);
        \\    c64.kernal.setName(msg);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_msg_len") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_msg_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "stringAppend") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_string_dst_cap") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "ldx #<main_msg_data") != null);
}

test "emits PETSCII controls as inline bytes without extra labels" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\const title = c64.petscii.clear ++ c64.petscii.home ++ "go";
        \\export fn main() void {
        \\    c64.console.puts(title);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, ".byte $93,$13,$47,$4f") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_str_clear") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_str_home") == null);
}

test "emits C64 PETSCII keyboard reads and key constants as scalar bytes" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\export fn main() void {
        \\    var key = c64.keyboard.readPetscii();
        \\    var waited = c64.keyboard.waitPetscii();
        \\    if (key == c64.key.return_ or waited == c64.key.cursor_down) {
        \\        c64.vic.border = c64.key.yellow;
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr $ffe4") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr keyboardWaitPetscii") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "keyboardWaitPetscii:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_keyboard_key") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "cmp #13") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "cmp #17") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda #158") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_str_return") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_str_yellow") == null);
}

test "emits scalar switch dispatch and expression results" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\export fn main() void {
        \\    var key: u8 = c64.key.return_;
        \\    const value = switch (key) {
        \\        c64.key.return_ => 1,
        \\        c64.key.cursor_down, c64.key.cursor_up => 2,
        \\        else => 3,
        \\    };
        \\    switch (value) {
        \\        1 => { c64.vic.border = 5; },
        \\        else => { c64.vic.border = 2; },
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_switch_value:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "switch_expr_") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "switch_") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "cmp #13") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "cmp #17") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta $d020") != null);
}

test "does not emit keyboard wait helper for nonblocking keyboard read" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\export fn main() void {
        \\    var key = c64.keyboard.readPetscii();
        \\    c64.vic.border = key;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr $ffe4") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "keyboardWaitPetscii:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_keyboard_key") == null);
}

test "emits inline asm with block-local labels and preservation" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\export fn main() void {
        \\    asm {
        \\loop:
        \\        lda #$00
        \\        sta $d020
        \\        bne loop
        \\    }
        \\    asm {
        \\loop:
        \\        inc $d021
        \\        bne loop
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_asm_0_loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_asm_1_loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "bne zeropage_asm_0_loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "    php\n    pha\n") != null);
}

test "external inline asm jsr forces full preservation" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\export fn main() void {
        \\    asm {
        \\        lda #65
        \\        jsr $ffd2
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "    php\n    pha\n    txa\n    pha\n    tya\n    pha\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "    jsr $ffd2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "    pla\n    tay\n    pla\n    tax\n    pla\n    plp\n") != null);
}

test "inline asm can read params and write byte locals" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\fn copy(input: u8, signed: i8, ok: bool) void {
        \\    var out: u8 = 0;
        \\    var signed_out: i8 = 0;
        \\    var ok_out: bool = false;
        \\    asm {
        \\        lda @input
        \\        sta @out
        \\        lda @signed
        \\        sta @signed_out
        \\        lda @ok
        \\        sta @ok_out
        \\    }
        \\}
        \\export fn main() void {
        \\    copy(7, 255, true);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda copy_input") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta copy_out") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda copy_signed") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta copy_ok_out") != null);
}

test "inline asm rejects non-byte ZeroPage variables" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\export fn main() void {
        \\    var word: u16 = 1024;
        \\    asm {
        \\        lda @word
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectError(error.UnsupportedInlineAsmVariableType, emitProgram(std.testing.allocator, parsed.program));
}

test "inline asm rewrites string data and length operands" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\const source = "abc";
        \\export fn main() void {
        \\    var msg = c64.string.buffer(8);
        \\    asm {
        \\        ldx #<@source.data
        \\        ldy #>@source.data
        \\        lda #@source.len
        \\        sta @msg.len
        \\        ldy #0
        \\        lda @source.data,y
        \\        sta @msg.data,y
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "ldx #<zeropage_str_source") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "ldy #>zeropage_str_source") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda #3") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta main_msg_len") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda zeropage_str_source,y") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta main_msg_data,y") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "stringAppend:") == null);
}

test "inline asm rejects unsafe string operand forms" {
    {
        const parsed = try parser.parseSource(std.testing.allocator,
            \\const c64 = @import("c64");
            \\const source = "abc";
            \\export fn main() void {
            \\    asm {
            \\        sta @source.data
            \\    }
            \\}
        );
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedInlineAsmConstStringWrite, emitProgram(std.testing.allocator, parsed.program));
    }

    {
        const parsed = try parser.parseSource(std.testing.allocator,
            \\const c64 = @import("c64");
            \\const source = "abc";
            \\export fn main() void {
            \\    asm {
            \\        lda @source
            \\    }
            \\}
        );
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedInlineAsmStringOperand, emitProgram(std.testing.allocator, parsed.program));
    }

    {
        const parsed = try parser.parseSource(std.testing.allocator,
            \\const c64 = @import("c64");
            \\export fn main() void {
            \\    var msg = c64.string.buffer(8);
            \\    asm {
            \\        lda #@msg.len
            \\    }
            \\}
        );
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedInlineAsmRuntimeStringLenImmediate, emitProgram(std.testing.allocator, parsed.program));
    }

    {
        const parsed = try parser.parseSource(std.testing.allocator,
            \\const c64 = @import("c64");
            \\export fn main() void {
            \\    var msg = c64.string.buffer(8);
            \\    asm {
            \\        lda @msg.ptr
            \\    }
            \\}
        );
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedInlineAsmStringOperand, emitProgram(std.testing.allocator, parsed.program));
    }

    {
        const parsed = try parser.parseSource(std.testing.allocator,
            \\const c64 = @import("c64");
            \\export fn main() void {
            \\    asm {
            \\        lda @missing.data
            \\    }
            \\}
        );
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnknownInlineAsmStringOperand, emitProgram(std.testing.allocator, parsed.program));
    }
}

test "emits tagged union storage and switch payload capture" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const test6502 = @import("test6502");
        \\const Event = union(enum) { none, key: u8, word: u16 };
        \\fn makeKey(code: u8) Event {
        \\    return Event{ .key = code };
        \\}
        \\fn score(event: Event) u8 {
        \\    return switch (event) {
        \\        .none => 0,
        \\        .key => |key| key,
        \\        .word => |value| if (value == 0x1234) 1 else 2,
        \\    };
        \\}
        \\export fn main() void {
        \\    var event: Event = makeKey(7);
        \\    test6502.expectEqualU8(1, 7, score(event));
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "main_event:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "score_event:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "score_key:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_union_switch_payload:\n") != null);
}

test "screen code conversion handles uppercase text" {
    try std.testing.expectEqual(@as(u8, 26), screenCode('Z'));
    try std.testing.expectEqual(@as(u8, 9), screenCode('I'));
    try std.testing.expectEqual(@as(u8, 32), screenCode(' '));
}

test "near arena heap metadata and helpers are emitted on demand" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .heaps = .{
        \\        .main = .{ .region = .{ .addr = 0x9000, .size = 0x0100 }, .kind = .arena },
        \\        .scratch = .{ .region = .{ .addr = 0x9100, .size = 0x0100 }, .kind = .arena },
        \\    },
        \\};
        \\export fn main() void {
        \\    _ = ZeroPage.heap("main").allocBytes(16);
        \\    ZeroPage.heap("scratch").reset();
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.program.zeropage_options.heaps.len);
    try std.testing.expectEqualStrings("main", parsed.program.zeropage_options.heaps[0].name);
    try std.testing.expectEqual(@as(u16, 0x9000), parsed.program.zeropage_options.heaps[0].addr);
    try std.testing.expectEqual(@as(u16, 0x0100), parsed.program.zeropage_options.heaps[0].size);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_heap_main_alloc_bytes",
        "jsr zeropage_heap_scratch_reset",
        "; zeropage_section_begin owner=runtime kind=code lifetime=static address=near",
        "zeropage_heap_main_alloc_bytes:",
        "zeropage_heap_scratch_reset:",
        "; zeropage_section_begin owner=runtime kind=data lifetime=static address=near",
        "zeropage_heap_main_cursor:",
        "zeropage_heap_scratch_cursor:",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_heap_scratch_alloc_bytes:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_heap_main_reset:") == null);
}

test "fixed near heap metadata and helpers are emitted on demand" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .heaps = .{
        \\        .sprites = .{ .region = .{ .addr = 0x9200, .size = 0x0040 }, .kind = .fixed, .block = 16 },
        \\        .unused = .{ .region = .{ .addr = 0x9300, .size = 0x0040 }, .kind = .fixed, .block = 16 },
        \\        .main = .{ .region = .{ .addr = 0x9400, .size = 0x0040 }, .kind = .arena },
        \\    },
        \\};
        \\export fn main() void {
        \\    const block = ZeroPage.heap("sprites").allocBytes(8);
        \\    if (block) |ptr| {
        \\        ZeroPage.heap("sprites").free(ptr);
        \\    }
        \\    ZeroPage.heap("sprites").reset();
        \\    _ = ZeroPage.heap("main").allocBytes(4);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), parsed.program.zeropage_options.heaps.len);
    try std.testing.expectEqual(.fixed, parsed.program.zeropage_options.heaps[0].kind);
    try std.testing.expectEqual(@as(?u16, 16), parsed.program.zeropage_options.heaps[0].block);
    try std.testing.expectEqual(.arena, parsed.program.zeropage_options.heaps[2].kind);
    try std.testing.expectEqual(@as(?u16, null), parsed.program.zeropage_options.heaps[2].block);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_heap_sprites_alloc_bytes",
        "jsr zeropage_heap_sprites_free",
        "jsr zeropage_heap_sprites_reset",
        "jsr zeropage_heap_main_alloc_bytes",
        "; zeropage_section_begin owner=runtime kind=code lifetime=static address=near",
        "zeropage_heap_sprites_alloc_bytes:",
        "zeropage_heap_sprites_reset:",
        "zeropage_heap_sprites_free:",
        "zeropage_heap_main_alloc_bytes:",
        "; zeropage_section_begin owner=runtime kind=data lifetime=static address=near",
        "zeropage_heap_sprites_cursor:",
        "zeropage_heap_sprites_free_head:",
        "zeropage_heap_main_cursor:",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_heap_unused_alloc_bytes:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_heap_unused_cursor:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_heap_main_free_head:") == null);
}

test "far REU arena heap metadata and helpers are emitted on demand" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .reu = .{
        \\        .heaps = .{
        \\            .assets = .{ .region = .{ .addr = 0x010000, .size = 0x0100 }, .kind = .arena },
        \\            .scratch = .{ .region = .{ .addr = 0x020000, .size = 0x0100 }, .kind = .arena },
        \\            .unused = .{ .region = .{ .addr = 0x030000, .size = 0x0100 }, .kind = .arena },
        \\        },
        \\    },
        \\};
        \\export fn main() void {
        \\    const maybe_far = ZeroPage.reu.heap("assets").allocBytes(16);
        \\    if (maybe_far) |far| {
        \\        ZeroPage.reu.copyFromC64(far, 0x0400, 16);
        \\        ZeroPage.reu.copyToC64(far, 0x0500, 16);
        \\    }
        \\    ZeroPage.reu.heap("scratch").reset();
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), parsed.program.zeropage_options.reu.heaps.len);
    try std.testing.expectEqualStrings("assets", parsed.program.zeropage_options.reu.heaps[0].name);
    try std.testing.expectEqual(@as(u32, 0x010000), parsed.program.zeropage_options.reu.heaps[0].addr);
    try std.testing.expectEqual(@as(u32, 0x0100), parsed.program.zeropage_options.reu.heaps[0].size);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_reu_heap_assets_alloc_bytes",
        "jsr zeropage_reu_copy_c64_to_reu",
        "jsr zeropage_reu_copy_reu_to_c64",
        "jsr zeropage_reu_heap_scratch_reset",
        "; zeropage_section_begin owner=runtime kind=code lifetime=static address=near",
        "zeropage_reu_copy_c64_to_reu:",
        "zeropage_reu_heap_assets_alloc_bytes:",
        "zeropage_reu_heap_scratch_reset:",
        "; zeropage_section_begin owner=runtime kind=data lifetime=static address=near",
        "zeropage_reu_heap_len:",
        "zeropage_reu_heap_assets_cursor:",
        "zeropage_reu_heap_scratch_cursor:",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_reu_heap_unused_alloc_bytes:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_reu_heap_unused_cursor:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda #$00\n    sta zeropage_reu_addr\n    lda #$00\n    sta zeropage_reu_addr+1\n    lda #$01\n    sta zeropage_reu_addr+2") == null);
}

test "far REU struct views lower to staged get and set transfers" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\const Enemy = struct {
        \\    hp: u8,
        \\    score: u16,
        \\};
        \\pub const zeropage_options = .{
        \\    .reu = .{
        \\        .heaps = .{
        \\            .assets = .{ .region = .{ .addr = 0x010000, .size = 0x0100 }, .kind = .arena },
        \\        },
        \\    },
        \\};
        \\export fn main() void {
        \\    const maybe_far = ZeroPage.reu.heap("assets").allocBytes(@sizeOf(Enemy) * 2);
        \\    if (maybe_far) |far| {
        \\        var enemies = ZeroPage.reu.view(Enemy, far, 2);
        \\        enemies.set(0, Enemy{ .hp = 1, .score = 0x0203 });
        \\        var idx: u8 = 1;
        \\        const loaded = enemies.get(idx);
        \\        _ = loaded;
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_reu_heap_assets_alloc_bytes",
        "main_enemies:",
        "; zeropage_section_begin owner=runtime kind=code lifetime=static address=near",
        "zeropage_reu_copy_c64_to_reu:",
        "zeropage_reu_copy_reu_to_c64:",
        "; zeropage_section_begin owner=runtime kind=data lifetime=static address=near",
        "zeropage_reu_view_offset:",
        "zeropage_reu_view_record:",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_reu_view_record") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_reu_view_offset") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr zeropage_mul16") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr zeropage_reu_copy_c64_to_reu") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr zeropage_reu_copy_reu_to_c64") != null);
}

test "far REU struct views materialize and flush through near arena heaps" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\const Enemy = struct {
        \\    hp: u8,
        \\    score: u16,
        \\};
        \\pub const zeropage_options = .{
        \\    .heaps = .{
        \\        .main = .{ .region = .{ .addr = 0x9000, .size = 0x0100 }, .kind = .arena },
        \\        .fixed = .{ .region = .{ .addr = 0x9100, .size = 0x0100 }, .kind = .fixed, .block = 16 },
        \\    },
        \\    .reu = .{
        \\        .heaps = .{
        \\            .assets = .{ .region = .{ .addr = 0x010000, .size = 0x0100 }, .kind = .arena },
        \\        },
        \\    },
        \\};
        \\export fn main() void {
        \\    const maybe_far = ZeroPage.reu.heap("assets").allocBytes(@sizeOf(Enemy) * 2);
        \\    if (maybe_far) |far| {
        \\        var enemies = ZeroPage.reu.view(Enemy, far, 2);
        \\        enemies.set(0, Enemy{ .hp = 1, .score = 0x0203 });
        \\        if (enemies.materialize("main")) |local| {
        \\            const loaded = local.get(0);
        \\            local.set(1, loaded);
        \\            enemies.flush(local);
        \\        }
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_reu_heap_assets_alloc_bytes",
        "jsr zeropage_heap_main_alloc_bytes",
        "jsr zeropage_reu_copy_reu_to_c64",
        "sta (zeropage_ptr_tmp),y",
        "jsr zeropage_reu_copy_c64_to_reu",
        "; zeropage_section_begin owner=runtime kind=data lifetime=static address=near",
        "zeropage_heap_main_cursor:",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_reu_view_record:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_heap_fixed_alloc_bytes:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_heap_fixed_cursor:") == null);
}

test "far REU struct views materialize and flush ranges through near arena heaps" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\const Enemy = struct {
        \\    hp: u8,
        \\    x: u8,
        \\    score: u16,
        \\};
        \\pub const zeropage_options = .{
        \\    .heaps = .{
        \\        .main = .{ .region = .{ .addr = 0x9000, .size = 0x0100 }, .kind = .arena },
        \\    },
        \\    .reu = .{
        \\        .heaps = .{
        \\            .assets = .{ .region = .{ .addr = 0x010000, .size = 0x0100 }, .kind = .arena },
        \\        },
        \\    },
        \\};
        \\export fn main() void {
        \\    const maybe_far = ZeroPage.reu.heap("assets").allocBytes(@sizeOf(Enemy) * 6);
        \\    if (maybe_far) |far| {
        \\        var start: u8 = 2;
        \\        var enemies = ZeroPage.reu.view(Enemy, far, 6);
        \\        if (enemies.materializeRange("main", start, 2)) |local| {
        \\            const loaded = local.get(1);
        \\            local.set(0, loaded);
        \\            enemies.flushRange(start, local);
        \\        }
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_reu_heap_assets_alloc_bytes",
        "cmp #5",
        "jsr zeropage_heap_main_alloc_bytes",
        "jsr zeropage_stride_mul_4",
        "jsr zeropage_reu_copy_reu_to_c64",
        "sta (zeropage_ptr_tmp),y",
        "jsr zeropage_reu_copy_c64_to_reu",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "far_materialize_range_") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "lda #<8") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_heap_main_cursor:") != null);
}

test "far REU struct view metadata-only programs keep assembly identical" {
    const no_options = try parser.parseSource(std.testing.allocator,
        \\export fn main() void {
        \\}
    );
    defer no_options.deinit(std.testing.allocator);
    const with_reu_heap = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .reu = .{
        \\        .heaps = .{
        \\            .assets = .{ .region = .{ .addr = 0x010000, .size = 0x0100 }, .kind = .arena },
        \\        },
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer with_reu_heap.deinit(std.testing.allocator);

    const no_options_asm = try emitProgram(std.testing.allocator, no_options.program);
    defer std.testing.allocator.free(no_options_asm);
    const with_reu_heap_asm = try emitProgram(std.testing.allocator, with_reu_heap.program);
    defer std.testing.allocator.free(with_reu_heap_asm);

    try std.testing.expectEqualStrings(no_options_asm, with_reu_heap_asm);
}

test "near arena heap metadata-only programs keep assembly identical" {
    const no_options = try parser.parseSource(std.testing.allocator,
        \\export fn main() void {}
    );
    defer no_options.deinit(std.testing.allocator);
    const with_heap = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .heaps = .{
        \\        .main = .{ .region = .{ .addr = 0x9000, .size = 0x0100 }, .kind = .arena },
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer with_heap.deinit(std.testing.allocator);

    const no_options_asm = try emitProgram(std.testing.allocator, no_options.program);
    defer std.testing.allocator.free(no_options_asm);
    const with_heap_asm = try emitProgram(std.testing.allocator, with_heap.program);
    defer std.testing.allocator.free(with_heap_asm);

    try std.testing.expectEqualStrings(no_options_asm, with_heap_asm);
}

test "far REU arena heap metadata-only programs keep assembly identical" {
    const no_options = try parser.parseSource(std.testing.allocator,
        \\export fn main() void {}
    );
    defer no_options.deinit(std.testing.allocator);
    const with_reu_heap = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .reu = .{
        \\        .heaps = .{
        \\            .assets = .{ .region = .{ .addr = 0x010000, .size = 0x0100 }, .kind = .arena },
        \\        },
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer with_reu_heap.deinit(std.testing.allocator);

    const no_options_asm = try emitProgram(std.testing.allocator, no_options.program);
    defer std.testing.allocator.free(no_options_asm);
    const with_reu_heap_asm = try emitProgram(std.testing.allocator, with_reu_heap.program);
    defer std.testing.allocator.free(with_reu_heap_asm);

    try std.testing.expectEqualStrings(no_options_asm, with_reu_heap_asm);
}

test "near arena heap invalid metadata and names fail clearly" {
    try std.testing.expectError(error.DuplicateZeroPageHeapOption, parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .heaps = .{
        \\        .main = .{ .region = .{ .addr = 0x9000, .size = 0x0100 }, .kind = .arena },
        \\        .main = .{ .region = .{ .addr = 0x9100, .size = 0x0100 }, .kind = .arena },
        \\    },
        \\};
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.InvalidZeroPageHeapBlock, parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .heaps = .{
        \\        .main = .{ .region = .{ .addr = 0x9000, .size = 0x0100 }, .kind = .fixed },
        \\    },
        \\};
        \\export fn main() void {}
    ));

    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .heaps = .{
        \\        .main = .{ .region = .{ .addr = 0x9000, .size = 0x0100 }, .kind = .arena },
        \\    },
        \\};
        \\export fn main() void {
        \\    _ = ZeroPage.heap("missing").allocBytes(1);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnknownHeap, emitProgram(std.testing.allocator, parsed.program));
}

test "fixed near heap invalid metadata and free calls fail clearly" {
    try std.testing.expectError(error.InvalidZeroPageHeapBlock, parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .heaps = .{
        \\        .sprites = .{ .region = .{ .addr = 0x9200, .size = 0x0040 }, .kind = .fixed },
        \\    },
        \\};
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.InvalidZeroPageHeapBlock, parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .heaps = .{
        \\        .sprites = .{ .region = .{ .addr = 0x9200, .size = 0x0040 }, .kind = .fixed, .block = 1 },
        \\    },
        \\};
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.InvalidZeroPageHeapBlock, parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .heaps = .{
        \\        .sprites = .{ .region = .{ .addr = 0x9200, .size = 0x0030 }, .kind = .fixed, .block = 32 },
        \\    },
        \\};
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.InvalidZeroPageHeapBlock, parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .heaps = .{
        \\        .main = .{ .region = .{ .addr = 0x9200, .size = 0x0040 }, .kind = .arena, .block = 16 },
        \\    },
        \\};
        \\export fn main() void {}
    ));

    const arena_free = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .heaps = .{
        \\        .main = .{ .region = .{ .addr = 0x9200, .size = 0x0040 }, .kind = .arena },
        \\    },
        \\};
        \\export fn main() void {
        \\    const ptr: [*]u8 = @ptrFromInt(0x9200);
        \\    ZeroPage.heap("main").free(ptr);
        \\}
    );
    defer arena_free.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedHeapFunction, emitProgram(std.testing.allocator, arena_free.program));

    const non_pointer_free = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .heaps = .{
        \\        .sprites = .{ .region = .{ .addr = 0x9200, .size = 0x0040 }, .kind = .fixed, .block = 16 },
        \\    },
        \\};
        \\export fn main() void {
        \\    ZeroPage.heap("sprites").free(1);
        \\}
    );
    defer non_pointer_free.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedPointerType, emitProgram(std.testing.allocator, non_pointer_free.program));
}

test "far REU arena heap invalid metadata and opaque handle misuse fail clearly" {
    try std.testing.expectError(error.DuplicateZeroPageHeapOption, parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .reu = .{
        \\        .heaps = .{
        \\            .assets = .{ .region = .{ .addr = 0x010000, .size = 0x0100 }, .kind = .arena },
        \\            .assets = .{ .region = .{ .addr = 0x020000, .size = 0x0100 }, .kind = .arena },
        \\        },
        \\    },
        \\};
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.UnsupportedZeroPageOptions, parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .reu = .{
        \\        .heaps = .{
        \\            .assets = .{ .region = .{ .addr = 0x010000, .size = 0x0100 }, .kind = .fixed },
        \\        },
        \\    },
        \\};
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.InvalidZeroPageReuHeapRegion, parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .reu = .{
        \\        .heaps = .{
        \\            .assets = .{ .region = .{ .addr = 0x00fffff0, .size = 0x0020 }, .kind = .arena },
        \\        },
        \\    },
        \\};
        \\export fn main() void {}
    ));

    const unknown_name = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .reu = .{
        \\        .heaps = .{
        \\            .assets = .{ .region = .{ .addr = 0x010000, .size = 0x0100 }, .kind = .arena },
        \\        },
        \\    },
        \\};
        \\export fn main() void {
        \\    const maybe_far = ZeroPage.reu.heap("missing").allocBytes(1);
        \\    if (maybe_far) |far| {
        \\        ZeroPage.reu.copyToC64(far, 0x0400, 1);
        \\    }
        \\}
    );
    defer unknown_name.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnknownHeap, emitProgram(std.testing.allocator, unknown_name.program));

    const far_deref = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .reu = .{
        \\        .heaps = .{
        \\            .assets = .{ .region = .{ .addr = 0x010000, .size = 0x0100 }, .kind = .arena },
        \\        },
        \\    },
        \\};
        \\export fn main() void {
        \\    const maybe_far = ZeroPage.reu.heap("assets").allocBytes(1);
        \\    if (maybe_far) |far| {
        \\        _ = far.*;
        \\    }
        \\}
    );
    defer far_deref.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedPointerTarget, emitProgram(std.testing.allocator, far_deref.program));
}

test "emits runtime module load window helper on demand" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\const table = [_]u8{ 1, 2, 3 };
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\    },
        \\    .abi = .{ .functions = .{
        \\        .tick = .{ .frame = .stack },
        \\        .ptr = .{ .frame = .stack },
        \\        .bump = .{ .frame = .stack },
        \\    } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_runtime",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick, .ptr = ptr },
        \\    .deps = .{},
        \\};
        \\fn bump(v: u8) u8 { return v + 1; }
        \\fn tick(v: u8) u8 { return bump(v); }
        \\fn ptr() usize { return @intFromPtr(&table[1]); }
        \\export fn main() void { _ = ZeroPage.module.load("enemy_runtime"); }
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_module_load_current",
        "zeropage_module_payload_range_start:",
        "; zeropage_relocation kind=abs16",
        "; zeropage_relocation kind=hi8",
        "; zeropage_relocation kind=lo8",
        "zeropage_module_load_current:",
        "lda zeropage_module_registry_loaded",
        "beq zeropage_module_load_current_not_loaded",
        "jsr zeropage_reu_present",
        "jsr zeropage_reu_copy_c64_to_reu",
        "jsr zeropage_reu_copy_reu_to_c64",
        "sta $c001",
        "sta $c002",
        "sta $c000+6+(zeropage_module_reloc_0+1-zeropage_module_payload_range_start)",
        "sta zeropage_module_registry_loaded",
        "sta zeropage_module_registry_refcount",
        "zeropage_module_is_loaded_current:",
        "zeropage_module_payload_jump_table:",
        "    jmp tick",
        "    jmp ptr",
        "zeropage_module_payload_range_end:",
    });
}

test "current module BASIC bank window wraps load and dispatch" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xa000, .size = 0x0800, .bank = .ram_under_basic },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_basic_current",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{},
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    _ = ZeroPage.module.load("enemy_basic_current");
        \\    if (ZeroPage.module.call("enemy_basic_current", "tick", .{4})) |value| { _ = value; }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_module_load_current",
        "jsr zeropage_module_bank_enter_basic",
        "jsr $a000",
        "sta zeropage_module_bank_saved_a",
        "stx zeropage_module_bank_saved_x",
        "jsr zeropage_module_bank_exit_basic",
        "ldx zeropage_module_bank_saved_x",
        "lda zeropage_module_bank_saved_a",
        "zeropage_module_bank_enter_basic:",
        "lda $0001",
        "sta zeropage_module_bank_saved_port",
        "and #$fe",
        "sta $0001",
        "zeropage_module_bank_exit_basic:",
        "lda zeropage_module_bank_saved_port",
        "sta $0001",
        "zeropage_module_load_current:",
        "jsr zeropage_module_bank_enter_basic",
        "jsr zeropage_reu_copy_reu_to_c64",
        "sta $a001",
        "sta $a002",
        "jsr zeropage_module_bank_exit_basic",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_bank_saved_port:\n    .byte 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_bank_saved_status:\n    .byte 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_bank_saved_a:\n    .byte 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_bank_saved_x:\n    .byte 0") != null);
}

test "current module KERNAL bank window wraps load and dispatch" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xe000, .size = 0x0800, .bank = .ram_under_kernal },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_kernal_current",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{},
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    _ = ZeroPage.module.load("enemy_kernal_current");
        \\    if (ZeroPage.module.call("enemy_kernal_current", "tick", .{4})) |value| { _ = value; }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_module_load_current",
        "jsr zeropage_module_bank_enter_kernal",
        "jsr $e000",
        "sta zeropage_module_bank_saved_a",
        "stx zeropage_module_bank_saved_x",
        "jsr zeropage_module_bank_exit_kernal",
        "ldx zeropage_module_bank_saved_x",
        "lda zeropage_module_bank_saved_a",
        "zeropage_module_bank_enter_kernal:",
        "php",
        "pla",
        "sta zeropage_module_bank_saved_status",
        "sei",
        "lda $0001",
        "sta zeropage_module_bank_saved_port",
        "and #$fd",
        "sta $0001",
        "zeropage_module_bank_exit_kernal:",
        "lda zeropage_module_bank_saved_port",
        "sta $0001",
        "lda zeropage_module_bank_saved_status",
        "pha",
        "plp",
        "zeropage_module_load_current:",
        "jsr zeropage_module_bank_enter_kernal",
        "jsr zeropage_reu_copy_reu_to_c64",
        "sta $e001",
        "sta $e002",
        "jsr zeropage_module_bank_exit_kernal",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_bank_saved_port:\n    .byte 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_bank_saved_a:\n    .byte 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_bank_saved_x:\n    .byte 0") != null);
}

test "current module KERNAL bank console exports use console trampolines" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xe000, .size = 0x0800, .bank = .ram_under_kernal },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\    },
        \\    .abi = .{ .functions = .{ .banner = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_kernal_console",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .banner = banner },
        \\    .deps = .{},
        \\};
        \\fn banner() u8 {
        \\    c64.console.print("TRAMP EXPORT\n", .{});
        \\    return 5;
        \\}
        \\export fn main() void {
        \\    _ = ZeroPage.module.load("enemy_kernal_console");
        \\    if (ZeroPage.module.call("enemy_kernal_console", "banner", .{})) |value| { _ = value; }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "banner:",
        "jsr zeropage_module_kernal_trampoline_console_put_char",
        "jsr zeropage_module_kernal_trampoline_console_newline",
        "zeropage_module_kernal_trampoline_console_put_char:",
        "jsr zeropage_module_kernal_trampoline_enter",
        "jsr consolePutChar",
        "jsr zeropage_module_kernal_trampoline_exit",
        "zeropage_module_kernal_trampoline_saved_status:\n    .byte 0",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "\"kernal_trampoline_safe\"") == null);
}

test "KERNAL bank current-module exports reject KERNAL-dependent call graphs" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xe000, .size = 0x0800, .bank = .ram_under_kernal },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_kernal_unsafe",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\};
        \\fn tick(v: u8) u8 {
        \\    const key = c64.keyboard.readPetscii();
        \\    return v + key;
        \\}
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectError(error.UnsafeKernalBankModuleExport, emitProgram(std.testing.allocator, parsed.program));
}

test "module isLoaded emits registry state without loader payload seed" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_runtime",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{},
        \\};
        \\fn tick(v: u8) u8 { return v; }
        \\export fn main() void { _ = ZeroPage.module.isLoaded("enemy_runtime"); }
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_module_is_loaded_current",
        "; zeropage_section_begin owner=runtime kind=code",
        "zeropage_module_is_loaded_current:",
        "lda zeropage_module_registry_loaded",
        "; zeropage_section_begin owner=runtime kind=data",
        "zeropage_module_registry_load_window = $c000",
        "zeropage_module_registry_reu_cache = $030000",
        "zeropage_module_registry_payload_size = 0",
        "zeropage_module_registry_loaded:",
        "zeropage_module_registry_refcount:",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_load_current:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_payload_jump_table:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_reu_copy_c64_to_reu") == null);
}

test "module isLoaded observes dependency registry rows without enabling dependency loading" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x001800 },
        \\        .registry = .{ .capacity = 3 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{
        \\                .math_core = "mathcore",
        \\                .pathing = "pathing",
        \\            },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_runtime",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core", "pathing" },
        \\};
        \\fn tick(v: u8) u8 { return v; }
        \\export fn main() void {
        \\    _ = ZeroPage.module.isLoaded("enemy_runtime");
        \\    _ = ZeroPage.module.isLoaded("math_core");
        \\    _ = ZeroPage.module.isLoaded("pathing");
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_module_is_loaded_current",
        "lda zeropage_module_registry_row1_loaded",
        "lda zeropage_module_registry_row2_loaded",
        "; zeropage_section_begin owner=runtime kind=data",
        "zeropage_module_registry_capacity = 3",
        "zeropage_module_registry_entry_count = 3",
        "zeropage_module_registry_row_size = 2",
        "; zeropage_module_registry_row 0 id=enemy_runtime role=current",
        "zeropage_module_registry_row0_reu_cache = $030000",
        "zeropage_module_registry_row0_loaded:",
        "zeropage_module_registry_loaded:",
        "zeropage_module_registry_row1_reu_cache = $030800",
        "zeropage_module_registry_row1_loaded:",
        "zeropage_module_registry_row2_reu_cache = $031000",
        "zeropage_module_registry_row2_loaded:",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_load_current:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_load_from_disk_current:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_payload_jump_table:") == null);
}

test "module unload emits registry clear helper without loader payload seed" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_runtime",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{},
        \\};
        \\fn tick(v: u8) u8 { return v; }
        \\export fn main() void { ZeroPage.module.unload("enemy_runtime"); }
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_module_unload_current",
        "; zeropage_section_begin owner=runtime kind=code",
        "zeropage_module_is_loaded_current:",
        "zeropage_module_unload_current:",
        "lda #0",
        "sta zeropage_module_registry_loaded",
        "sta zeropage_module_registry_refcount",
        "; zeropage_section_begin owner=runtime kind=data",
        "zeropage_module_registry_payload_size = 0",
        "zeropage_module_registry_loaded:",
        "zeropage_module_registry_refcount:",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_load_current:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_payload_jump_table:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_reu_copy_c64_to_reu") == null);
}

test "module load after unload emits full loader and clear helper" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\const table = [_]u8{ 1, 2, 3 };
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\    },
        \\    .abi = .{ .functions = .{
        \\        .tick = .{ .frame = .stack },
        \\        .ptr = .{ .frame = .stack },
        \\        .bump = .{ .frame = .stack },
        \\    } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_runtime",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick, .ptr = ptr },
        \\    .deps = .{},
        \\};
        \\fn bump(v: u8) u8 { return v + 1; }
        \\fn tick(v: u8) u8 { return bump(v); }
        \\fn ptr() usize { return @intFromPtr(&table[1]); }
        \\export fn main() void {
        \\    _ = ZeroPage.module.load("enemy_runtime");
        \\    ZeroPage.module.unload("enemy_runtime");
        \\    _ = ZeroPage.module.load("enemy_runtime");
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_module_load_current",
        "jsr zeropage_module_unload_current",
        "jsr zeropage_module_load_current",
        "zeropage_module_load_current:",
        "zeropage_module_load_current_not_loaded:",
        "jsr zeropage_reu_copy_c64_to_reu",
        "jsr zeropage_reu_copy_reu_to_c64",
        "sta zeropage_module_registry_loaded",
        "sta zeropage_module_registry_refcount",
        "zeropage_module_unload_current:",
        "sta zeropage_module_registry_loaded",
        "sta zeropage_module_registry_refcount",
        "zeropage_module_payload_jump_table:",
    });
}

test "module load rejects missing metadata and dependency graphs" {
    const missing_module = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\export fn main() void { _ = ZeroPage.module.load("missing"); }
    );
    defer missing_module.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnknownZeroPageModule, emitProgram(std.testing.allocator, missing_module.program));

    const missing_loader = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_runtime",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{},
        \\};
        \\fn tick(v: u8) u8 { return v; }
        \\export fn main() void { _ = ZeroPage.module.load("enemy_runtime"); }
    );
    defer missing_loader.deinit(std.testing.allocator);
    try std.testing.expectError(error.MissingZeroPageModuleLoader, emitProgram(std.testing.allocator, missing_loader.program));

    const deps = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_runtime",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math" },
        \\};
        \\fn tick(v: u8) u8 { return v; }
        \\export fn main() void { _ = ZeroPage.module.load("enemy_runtime"); }
    );
    defer deps.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedZeroPageModuleDependencyLoad, emitProgram(std.testing.allocator, deps.program));
}

test "module dynamic call emits loaded guard and jump-table dispatch" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack }, .wide = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_runtime",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick, .wide = wide },
        \\    .deps = .{},
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\fn wide(v: u16) u16 { return v + 1; }
        \\export fn main() void {
        \\    _ = ZeroPage.module.load("enemy_runtime");
        \\    const maybe = ZeroPage.module.call("enemy_runtime", "wide", .{0x1234});
        \\    _ = maybe;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_module_load_current",
        "lda zeropage_module_registry_loaded",
        "beq module_call_",
        "sta zeropage_stack_fp",
        "sta (zeropage_stack_fp),y",
        "jsr zeropage_module_registry_jump_table+3",
        "sta zeropage_stack_ret_lo",
        "stx zeropage_stack_ret_hi",
        "sta main_maybe",
        "lda zeropage_stack_ret_lo",
        "sta main_maybe+1",
        "lda zeropage_stack_ret_hi",
        "sta main_maybe+2",
        "module_call_",
        "zeropage_module_payload_jump_table:",
    });
}

test "module dynamic call only emits registry state without loader payload seed" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_runtime",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{},
        \\};
        \\fn tick(v: u8) u8 { return v; }
        \\export fn main() void {
        \\    const maybe = ZeroPage.module.call("enemy_runtime", "tick", .{5});
        \\    _ = maybe;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "lda zeropage_module_registry_loaded",
        "jsr zeropage_module_registry_jump_table+0",
        "zeropage_module_is_loaded_current:",
        "zeropage_module_registry_payload_size = 0",
        "zeropage_module_registry_loaded:",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_load_current:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_payload_jump_table:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_reu_copy_c64_to_reu") == null);
}

test "module disk load emits KERNAL staging path and reuses module loader patching" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_runtime",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{},
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    _ = ZeroPage.module.loadFromDisk("enemy_runtime", "enemyrt");
        \\}
    );
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.program.zeropage_options.modules.?.disk_staging != null);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_module_load_from_disk_current",
        "zeropage_module_load_from_disk_current:",
        "jsr $ffbd",
        "jsr $ffba",
        "jsr $ffd5",
        "bcc zeropage_module_load_from_disk_loaded",
        "zeropage_module_load_from_disk_loaded:",
        "jsr zeropage_reu_copy_c64_to_reu",
        "jsr zeropage_reu_copy_reu_to_c64",
        "sta zeropage_module_registry_loaded",
        "zeropage_module_disk_filename:",
        ".byte $45",
        ".byte $4e",
    });
}

test "module preload policy emits startup disk load before main" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .policy = .{ .current = .{ .mode = .preload, .filename = "enemyrt" } },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_runtime",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{},
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    _ = ZeroPage.module.isLoaded("enemy_runtime");
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "* = $080d",
        "zeropage_module_preload_start:",
        "jsr zeropage_module_load_from_disk_current",
        "main:",
        "jsr zeropage_module_is_loaded_current",
        "zeropage_module_load_from_disk_current:",
        "zeropage_module_disk_filename:",
        ".byte $45",
    });
}

test "manual module load policy does not emit startup preload" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .policy = .{ .current = .{ .mode = .manual, .filename = "enemyrt" } },
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_preload_start:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_load_from_disk_current:") == null);
}

test "on-demand module load policy emits disk load at dynamic call site" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .policy = .{ .current = .{ .mode = .on_demand, .filename = "enemyrt" } },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_runtime",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{},
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    const maybe = ZeroPage.module.call("enemy_runtime", "tick", .{5});
        \\    _ = maybe;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "main:",
        "lda zeropage_module_registry_loaded",
        "bne module_call_",
        "jsr zeropage_module_load_from_disk_current",
        "lda zeropage_module_registry_loaded",
        "beq module_call_",
        "jsr zeropage_module_registry_jump_table+0",
        "zeropage_module_load_from_disk_current:",
        "zeropage_module_disk_filename:",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_preload_start:") == null);
}

test "dependency disk loader emits manifest filename row cache and registry writes" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x001800 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .registry = .{ .capacity = 3 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{ .math_core = "mathcore", .pathing = "pathing" },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_deps",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core", "pathing" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    _ = ZeroPage.module.loadDependency("pathing");
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "main:",
        "jsr zeropage_module_load_dependency_row2",
        "zeropage_module_registry_row2_reu_cache = $031000",
    });
    const required = [_][]const u8{
        "zeropage_module_dependency_row2_filename:",
        ".byte $50",
        ".byte $41",
        "zeropage_module_load_dependency_row2:",
        "lda zeropage_module_registry_row2_loaded",
        "jsr $ffbd",
        "jsr $ffba",
        "jsr $ffd5",
        "bcc zeropage_module_load_dependency_row2_loaded",
        "sta zeropage_reu_len",
        "sta zeropage_reu_len+1",
        "jsr zeropage_reu_copy_c64_to_reu",
        "sta zeropage_module_registry_row2_loaded",
        "sta zeropage_module_registry_row2_refcount",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, asm_text, needle) == null) {
            std.debug.print("missing dependency call assembly text: {s}\n", .{needle});
            return error.TestExpectedEqual;
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_load_from_disk_current:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_payload_jump_table:") == null);
}

test "dependency acquire emits explicit refcount helper" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x001800 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .registry = .{ .capacity = 2 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{ .math_core = "mathcore" },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_deps",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    _ = ZeroPage.module.acquireDependency("math_core");
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_module_acquire_dependency_row1",
        "zeropage_module_acquire_dependency_row1:",
        "lda zeropage_module_registry_row1_refcount",
        "cmp #$ff",
        "inc zeropage_module_registry_row1_refcount",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_load_dependency_row1:") != null);
}

test "module dependency call uses compile-time sidecar ordinal and activation" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x001000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .registry = .{ .capacity = 2 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{ .math_core = "mathcore" },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_dep_call",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    if (ZeroPage.module.call("math_core", "add", .{3})) |value| {
        \\        _ = value;
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const params = [_]module_sidecars.DependencyParam{.{ .ty = .u8, .offset = 0 }};
    const exports = [_]module_sidecars.DependencyExport{.{
        .name = "add",
        .ordinal = 2,
        .target_original = 0x2400,
        .return_type = .u8,
        .params = &params,
        .frame_size = 3,
    }};
    const relocs = [_]module_sidecars.RelocationPatch{.{
        .payload_offset = 9,
        .kind = .abs16,
        .after = .{ 0x34, 0xc0 },
        .size = 2,
    }};
    const deps = [_]module_sidecars.DependencyModule{.{
        .id = "math_core",
        .payload_start = 0x2400,
        .jump_table_bytes = 9,
        .load_window_addr = 0xc000,
        .load_window_size = 0x0800,
        .payload_length = 0x0100,
        .exports = &exports,
        .relocations = &relocs,
    }};

    const asm_text = try emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &deps });
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "lda zeropage_module_registry_row1_loaded",
        "jsr zeropage_module_activate_dependency_row1",
        "jsr zeropage_module_registry_jump_table+6",
        "zeropage_module_activate_dependency_row1:",
    });
    const required = [_][]const u8{
        "zeropage_module_registry_row1_reu_cache = $030800",
        "sta $c007",
        "sta $c009",
        "lda #1",
        "sta zeropage_module_registry_active_row",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, asm_text, needle) == null) {
            std.debug.print("missing dependency call assembly text: {s}\n", .{needle});
            return error.TestExpectedEqual;
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_dependency_row1_filename:") == null);
}

test "typed dependency binding call lowers to known ordinal dispatch" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\const MathCore = ZeroPage.module.import(.math_core, .{
        \\    .add = fn (u8) u8,
        \\});
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x001000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .registry = .{ .capacity = 2 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{ .math_core = "mathcore" },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_dep_call",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    if (MathCore.add(3)) |value| {
        \\        _ = value;
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const params = [_]module_sidecars.DependencyParam{.{ .ty = .u8, .offset = 0 }};
    const exports = [_]module_sidecars.DependencyExport{.{
        .name = "add",
        .ordinal = 2,
        .target_original = 0x2400,
        .return_type = .u8,
        .params = &params,
        .frame_size = 3,
    }};
    const deps = [_]module_sidecars.DependencyModule{.{
        .id = "math_core",
        .payload_start = 0x2400,
        .jump_table_bytes = 9,
        .load_window_addr = 0xc000,
        .load_window_size = 0x0800,
        .payload_length = 0x0100,
        .exports = &exports,
        .relocations = &.{},
    }};

    const asm_text = try emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &deps });
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "lda zeropage_module_registry_row1_loaded",
        "jsr zeropage_module_activate_dependency_row1",
        "jsr zeropage_module_registry_jump_table+6",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "MathCore") == null);
}

test "typed dependency lifecycle methods lower to dependency helpers" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\const MathCore = ZeroPage.module.import(.math_core, .{
        \\    .add = fn (u8) u8,
        \\});
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x001000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .registry = .{ .capacity = 2 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{ .math_core = "mathcore" },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_dep_lifecycle",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    const loaded = MathCore.load();
        \\    const present = MathCore.isLoaded();
        \\    MathCore.unload();
        \\    _ = loaded;
        \\    _ = present;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const params = [_]module_sidecars.DependencyParam{.{ .ty = .u8, .offset = 0 }};
    const exports = [_]module_sidecars.DependencyExport{.{
        .name = "add",
        .ordinal = 0,
        .target_original = 0x2400,
        .return_type = .u8,
        .params = &params,
        .frame_size = 3,
    }};
    const deps = [_]module_sidecars.DependencyModule{.{
        .id = "math_core",
        .payload_start = 0x2400,
        .jump_table_bytes = 3,
        .load_window_addr = 0xc000,
        .load_window_size = 0x0800,
        .payload_length = 0x0100,
        .exports = &exports,
        .relocations = &.{},
    }};

    const asm_text = try emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &deps });
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_module_load_dependency_row1",
        "lda zeropage_module_registry_row1_loaded",
        "jsr zeropage_module_unload_dependency_row1",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_load_dependency_row1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_unload_dependency_row1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "MathCore") == null);
}

test "typed dependency loadGraph lowers to graph loader sequence" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\const MathCore = ZeroPage.module.import(.math_core, .{
        \\    .add = fn (u8) u8,
        \\});
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x002000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .registry = .{ .capacity = 4 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{
        \\                .math_core = "mathcore",
        \\                .pathing = "pathing",
        \\                .fixed_math = "fixedmath",
        \\            },
        \\        },
        \\        .dependency_graph = .{
        \\            .math_core = .{ .deps = .{ .fixed_math } },
        \\            .pathing = .{ .deps = .{} },
        \\            .fixed_math = .{ .deps = .{} },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_dep_graph_binding",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core", "pathing" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    const ok = MathCore.loadGraph();
        \\    _ = ok;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const params = [_]module_sidecars.DependencyParam{.{ .ty = .u8, .offset = 0 }};
    const exports = [_]module_sidecars.DependencyExport{.{
        .name = "add",
        .ordinal = 0,
        .target_original = 0x2400,
        .return_type = .u8,
        .params = &params,
        .frame_size = 3,
    }};
    const deps = [_]module_sidecars.DependencyModule{.{
        .id = "math_core",
        .payload_start = 0x2400,
        .jump_table_bytes = 3,
        .load_window_addr = 0xc000,
        .load_window_size = 0x0800,
        .payload_length = 0x0100,
        .exports = &exports,
        .relocations = &.{},
    }};

    const asm_text = try emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &deps });
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_module_load_dependency_row3",
        "jsr zeropage_module_load_dependency_row1",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_graph_load_") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "MathCore") == null);
}

test "typed dependency graph ownership methods lower to acquire and release helpers" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\const MathCore = ZeroPage.module.import(.math_core, .{
        \\    .add = fn (u8) u8,
        \\});
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x002000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .registry = .{ .capacity = 4 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{
        \\                .math_core = "mathcore",
        \\                .pathing = "pathing",
        \\                .fixed_math = "fixedmath",
        \\            },
        \\        },
        \\        .dependency_graph = .{
        \\            .math_core = .{ .deps = .{ .fixed_math } },
        \\            .pathing = .{ .deps = .{} },
        \\            .fixed_math = .{ .deps = .{} },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_dep_graph_binding",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core", "pathing" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    const ok = MathCore.acquireGraph();
        \\    if (ok) {
        \\        MathCore.releaseGraph();
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const params = [_]module_sidecars.DependencyParam{.{ .ty = .u8, .offset = 0 }};
    const exports = [_]module_sidecars.DependencyExport{.{
        .name = "add",
        .ordinal = 0,
        .target_original = 0x2400,
        .return_type = .u8,
        .params = &params,
        .frame_size = 3,
    }};
    const deps = [_]module_sidecars.DependencyModule{.{
        .id = "math_core",
        .payload_start = 0x2400,
        .jump_table_bytes = 3,
        .load_window_addr = 0xc000,
        .load_window_size = 0x0800,
        .payload_length = 0x0100,
        .exports = &exports,
        .relocations = &.{},
    }};

    const asm_text = try emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &deps });
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_module_acquire_dependency_row3",
        "jsr zeropage_module_acquire_dependency_row1",
        "jsr zeropage_module_unload_dependency_row1",
        "jsr zeropage_module_unload_dependency_row3",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_load_dependency_row3:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_unload_dependency_row3:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "MathCore") == null);
}

test "typed current binding lifecycle methods lower to current helpers" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\const EnemyRuntime = ZeroPage.module.import(.enemy_runtime, .{
        \\    .border = fn (u8) u8,
        \\});
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\    },
        \\    .abi = .{ .functions = .{ .borderColor = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_runtime",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .border = borderColor },
        \\    .deps = .{},
        \\};
        \\fn borderColor(v: u8) u8 { return v + 2; }
        \\export fn main() void {
        \\    const embedded = EnemyRuntime.load();
        \\    const disk = EnemyRuntime.loadFromDisk("enemyrt");
        \\    const present = EnemyRuntime.isLoaded();
        \\    EnemyRuntime.unload();
        \\    const border = EnemyRuntime.border(3);
        \\    _ = embedded;
        \\    _ = disk;
        \\    _ = present;
        \\    _ = border;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_module_load_current",
        "jsr zeropage_module_load_from_disk_current",
        "jsr zeropage_module_is_loaded_current",
        "jsr zeropage_module_unload_current",
        "jsr zeropage_module_registry_jump_table+0",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_load_dependency_row") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "EnemyRuntime") == null);
}

test "module dependency unload clears row and active owner without loader payload" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x001000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .registry = .{ .capacity = 2 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{ .math_core = "mathcore" },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_dep_unload",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    ZeroPage.module.unloadDependency("math_core");
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "main:",
        "jsr zeropage_module_unload_dependency_row1",
        "zeropage_module_unload_dependency_row1:",
        "lda zeropage_module_registry_row1_refcount",
        "cmp #1",
        "dec zeropage_module_registry_row1_refcount",
        "zeropage_module_unload_dependency_row1_final_release:",
        "sta zeropage_module_registry_row1_loaded",
        "sta zeropage_module_registry_row1_refcount",
        "lda zeropage_module_registry_active_row",
        "cmp #1",
        "sta zeropage_module_registry_active_row",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_load_dependency_row1:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_activate_dependency_row1:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_payload_jump_table:") == null);
}

test "current module state runtime saves before unload and restores after load" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x002000 },
        \\        .state = .{
        \\            .current = .{
        \\                .mode = .persist_in_reu,
        \\                .ranges = .{
        \\                    .{ .offset = 0x0100, .size = 2 },
        \\                },
        \\            },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_state",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{},
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    _ = ZeroPage.module.load("enemy_state");
        \\    ZeroPage.module.unload("enemy_state");
        \\    _ = ZeroPage.module.load("enemy_state");
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_state_current_snapshot_reu = $030800") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_state_current_saved:") != null);
    try expectContainsInOrder(asm_text, &.{
        "zeropage_module_load_current:",
        "jsr zeropage_module_state_restore_current",
        "zeropage_module_state_save_current:",
        "jsr zeropage_reu_copy_c64_to_reu",
        "zeropage_module_state_restore_current:",
        "jsr zeropage_reu_copy_reu_to_c64",
        "zeropage_module_unload_current:",
        "jsr zeropage_module_state_save_current",
    });
}

test "dependency activation saves active current module state before switching rows" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x003000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .registry = .{ .capacity = 2 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{ .math_core = "mathcore" },
        \\        },
        \\        .state = .{
        \\            .current = .{
        \\                .mode = .persist_in_reu,
        \\                .ranges = .{ .{ .offset = 0x0100, .size = 2 } },
        \\            },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_state_dep",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    if (ZeroPage.module.call("math_core", "add", .{4})) |value| {
        \\        _ = value;
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const params = [_]module_sidecars.DependencyParam{.{ .ty = .u8, .offset = 0 }};
    const exports = [_]module_sidecars.DependencyExport{.{
        .name = "add",
        .ordinal = 0,
        .params = &params,
        .return_type = .u8,
        .frame_size = 1,
        .target_original = 0x0813,
    }};
    const deps = [_]module_sidecars.DependencyModule{.{
        .id = "math_core",
        .load_window_addr = 0xc000,
        .load_window_size = 0x0800,
        .payload_length = 8,
        .payload_start = 0x0810,
        .jump_table_bytes = 3,
        .exports = &exports,
        .relocations = &.{},
    }};

    const asm_text = try emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &deps });
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_state_current_snapshot_reu = $031000") != null);
    try expectContainsInOrder(asm_text, &.{
        "zeropage_module_activate_dependency_row1:",
        "lda zeropage_module_registry_active_row",
        "cmp #0",
        "jsr zeropage_module_state_save_current",
        "zeropage_module_activate_dependency_row1_skip_state_save:",
        "sta zeropage_module_registry_active_row",
    });
}

test "dependency state runtime saves and restores persistent dependency rows" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x004000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .registry = .{ .capacity = 3 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{ .math_core = "mathcore", .pathing = "pathing" },
        \\        },
        \\        .state = .{
        \\            .current = .{ .mode = .discard_on_unload },
        \\            .deps = .{
        \\                .math_core = .{
        \\                    .mode = .persist_in_reu,
        \\                    .ranges = .{ .{ .offset = 0x0040, .size = 2 } },
        \\                },
        \\                .pathing = .{
        \\                    .mode = .persist_in_reu,
        \\                    .ranges = .{ .{ .offset = 0x0060, .size = 2 } },
        \\                },
        \\            },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_state_dep_runtime",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core", "pathing" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    _ = ZeroPage.module.loadDependency("math_core");
        \\    _ = ZeroPage.module.loadDependency("pathing");
        \\    if (ZeroPage.module.call("math_core", "add", .{4})) |value| { _ = value; }
        \\    if (ZeroPage.module.call("pathing", "step", .{4})) |value| { _ = value; }
        \\    ZeroPage.module.unloadDependency("pathing");
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const params = [_]module_sidecars.DependencyParam{.{ .ty = .u8, .offset = 0 }};
    const math_exports = [_]module_sidecars.DependencyExport{.{
        .name = "add",
        .ordinal = 0,
        .params = &params,
        .return_type = .u8,
        .frame_size = 1,
        .target_original = 0x0813,
    }};
    const path_exports = [_]module_sidecars.DependencyExport{.{
        .name = "step",
        .ordinal = 0,
        .params = &params,
        .return_type = .u8,
        .frame_size = 1,
        .target_original = 0x0913,
    }};
    const deps = [_]module_sidecars.DependencyModule{
        .{
            .id = "math_core",
            .load_window_addr = 0xc000,
            .load_window_size = 0x0800,
            .payload_length = 8,
            .payload_start = 0x0810,
            .jump_table_bytes = 3,
            .exports = &math_exports,
            .relocations = &.{},
        },
        .{
            .id = "pathing",
            .load_window_addr = 0xc000,
            .load_window_size = 0x0800,
            .payload_length = 8,
            .payload_start = 0x0910,
            .jump_table_bytes = 3,
            .exports = &path_exports,
            .relocations = &.{},
        },
    };

    const asm_text = try emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &deps });
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_state_dep1_snapshot_reu = $032000") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_state_dep2_snapshot_reu = $032800") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_state_dep1_saved:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_state_dep2_saved:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_state_save_active_dependency:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr zeropage_module_state_save_dependency_row1") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr zeropage_module_state_save_dependency_row2") != null);
    try expectContainsInOrder(asm_text, &.{
        "zeropage_module_activate_dependency_row1:",
        "jsr zeropage_module_state_save_active_dependency",
        "jsr zeropage_module_state_restore_dependency_row1",
        "zeropage_module_activate_dependency_row2:",
        "jsr zeropage_module_state_save_active_dependency",
        "jsr zeropage_module_state_restore_dependency_row2",
        "zeropage_module_unload_dependency_row2:",
        "jsr zeropage_module_state_save_dependency_row2",
    });
}

test "dependency preload policy emits startup row loads in dependency order" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x002000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .registry = .{ .capacity = 3 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{ .math_core = "mathcore", .pathing = "pathing" },
        \\        },
        \\        .policy = .{
        \\            .current = .{ .mode = .manual },
        \\            .deps = .{
        \\                .pathing = .{ .mode = .preload },
        \\                .math_core = .{ .mode = .preload },
        \\            },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_dep_preload",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core", "pathing" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "zeropage_module_dependency_preload_start:",
        "jsr zeropage_module_load_dependency_row1",
        "jsr zeropage_module_load_dependency_row2",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_load_dependency_row1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_dependency_row1_filename:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_load_from_disk_current:") == null);
}

test "dependency on-demand policy emits lazy row load at dependency call site" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\const MathCore = ZeroPage.module.import(.math_core, .{
        \\    .add = fn (u8) u8,
        \\});
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x001000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .registry = .{ .capacity = 2 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{ .math_core = "mathcore" },
        \\        },
        \\        .policy = .{
        \\            .current = .{ .mode = .manual },
        \\            .deps = .{ .math_core = .{ .mode = .on_demand } },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_dep_on_demand",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    if (MathCore.add(3)) |value| { _ = value; }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const params = [_]module_sidecars.DependencyParam{.{ .ty = .u8, .offset = 0 }};
    const exports = [_]module_sidecars.DependencyExport{.{
        .name = "add",
        .ordinal = 2,
        .target_original = 0x2400,
        .return_type = .u8,
        .params = &params,
        .frame_size = 3,
    }};
    const deps = [_]module_sidecars.DependencyModule{.{
        .id = "math_core",
        .payload_start = 0x2400,
        .jump_table_bytes = 9,
        .load_window_addr = 0xc000,
        .load_window_size = 0x0800,
        .payload_length = 0x0100,
        .exports = &exports,
        .relocations = &.{},
    }};

    const asm_text = try emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &deps });
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "lda zeropage_module_registry_row1_loaded",
        "bne module_call_",
        "jsr zeropage_module_load_dependency_row1",
        "lda zeropage_module_registry_row1_loaded",
        "beq module_call_",
        "jsr zeropage_module_activate_dependency_row1",
        "jsr zeropage_module_registry_jump_table+6",
        "zeropage_module_load_dependency_row1:",
        "zeropage_module_dependency_row1_filename:",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_dependency_preload_start:") == null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "MathCore") == null);
}

test "dependency graph load emits topological row loads and rollback" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x002000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .registry = .{ .capacity = 4 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{
        \\                .math_core = "mathcore",
        \\                .pathing = "pathing",
        \\                .fixed_math = "fixedmath",
        \\            },
        \\        },
        \\        .dependency_graph = .{
        \\            .math_core = .{ .deps = .{ .fixed_math } },
        \\            .pathing = .{ .deps = .{} },
        \\            .fixed_math = .{ .deps = .{} },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_graph_load",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core", "pathing" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    const ok = ZeroPage.module.loadDependencyGraph("math_core");
        \\    _ = ok;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "lda zeropage_module_registry_row3_loaded",
        "jsr zeropage_module_load_dependency_row3",
        "beq module_dependency_graph_load_0_fail_0",
        "sta zeropage_module_graph_load_0_row0_new",
        "lda zeropage_module_registry_row1_loaded",
        "jsr zeropage_module_load_dependency_row1",
        "beq module_dependency_graph_load_0_fail_1",
        "module_dependency_graph_load_0_fail_1:",
        "lda zeropage_module_graph_load_0_row0_new",
        "jsr zeropage_module_unload_dependency_row3",
        "zeropage_module_load_dependency_row3:",
        "zeropage_module_dependency_row3_filename:",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_unload_dependency_row3:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_registry_entry_count = 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_registry_row3_reu_cache = $031800") != null);
}

test "dependency graph acquire emits topological row acquires and rollback" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x002000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .registry = .{ .capacity = 4 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{
        \\                .math_core = "mathcore",
        \\                .pathing = "pathing",
        \\                .fixed_math = "fixedmath",
        \\            },
        \\        },
        \\        .dependency_graph = .{
        \\            .math_core = .{ .deps = .{ .fixed_math } },
        \\            .pathing = .{ .deps = .{} },
        \\            .fixed_math = .{ .deps = .{} },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_graph_acquire",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core", "pathing" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    const ok = ZeroPage.module.acquireDependencyGraph("math_core");
        \\    _ = ok;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_module_acquire_dependency_row3",
        "beq module_dependency_graph_acquire_0_fail_0",
        "sta zeropage_module_graph_load_0_row0_new",
        "jsr zeropage_module_acquire_dependency_row1",
        "beq module_dependency_graph_acquire_0_fail_1",
        "module_dependency_graph_acquire_0_fail_1:",
        "lda zeropage_module_graph_load_0_row0_new",
        "jsr zeropage_module_unload_dependency_row3",
        "zeropage_module_acquire_dependency_row3:",
        "inc zeropage_module_registry_row3_refcount",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_load_dependency_row3:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_unload_dependency_row3:") != null);
}

test "dependency graph release emits reverse topological row releases" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x002000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .registry = .{ .capacity = 4 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{
        \\                .math_core = "mathcore",
        \\                .pathing = "pathing",
        \\                .fixed_math = "fixedmath",
        \\            },
        \\        },
        \\        .dependency_graph = .{
        \\            .math_core = .{ .deps = .{ .fixed_math } },
        \\            .pathing = .{ .deps = .{} },
        \\            .fixed_math = .{ .deps = .{} },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_graph_release",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core", "pathing" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    ZeroPage.module.releaseDependencyGraph("math_core");
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "jsr zeropage_module_unload_dependency_row1",
        "jsr zeropage_module_unload_dependency_row3",
        "zeropage_module_unload_dependency_row1:",
        "zeropage_module_unload_dependency_row3:",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_load_dependency_row1:") == null);
}

test "graph node dependency sidecars validate without making transitive nodes callable" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x002000 },
        \\        .registry = .{ .capacity = 4 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{
        \\                .math_core = "mathcore",
        \\                .pathing = "pathing",
        \\                .fixed_math = "fixedmath",
        \\            },
        \\        },
        \\        .dependency_graph = .{
        \\            .math_core = .{ .deps = .{ .fixed_math } },
        \\            .pathing = .{ .deps = .{} },
        \\            .fixed_math = .{ .deps = .{} },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_graph_sidecars",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core", "pathing" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const params = [_]module_sidecars.DependencyParam{.{ .ty = .u8, .offset = 0 }};
    const math_exports = [_]module_sidecars.DependencyExport{.{
        .name = "add",
        .ordinal = 0,
        .target_original = 0x2400,
        .return_type = .u8,
        .params = &params,
        .frame_size = 3,
    }};
    const fixed_exports = [_]module_sidecars.DependencyExport{.{
        .name = "bias",
        .ordinal = 0,
        .target_original = 0x2500,
        .return_type = .u8,
        .params = &params,
        .frame_size = 3,
    }};
    const deps = [_]module_sidecars.DependencyModule{
        .{
            .id = "math_core",
            .payload_start = 0x2400,
            .jump_table_bytes = 3,
            .load_window_addr = 0xc000,
            .load_window_size = 0x0800,
            .payload_length = 0x0100,
            .exports = &math_exports,
            .relocations = &.{},
        },
        .{
            .id = "fixed_math",
            .payload_start = 0x2500,
            .jump_table_bytes = 3,
            .load_window_addr = 0xc000,
            .load_window_size = 0x0800,
            .payload_length = 0x0100,
            .exports = &fixed_exports,
            .relocations = &.{},
        },
    };

    const asm_text = try emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &deps });
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_activate_dependency_row3:") == null);

    const ghost = [_]module_sidecars.DependencyModule{.{
        .id = "ghost_math",
        .payload_start = 0x2500,
        .jump_table_bytes = 3,
        .load_window_addr = 0xc000,
        .load_window_size = 0x0800,
        .payload_length = 0x0100,
        .exports = &fixed_exports,
        .relocations = &.{},
    }};
    try std.testing.expectError(error.UnknownZeroPageModule, emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &ghost }));
}

test "assigned dependency sidecars may target an extra load window" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .extra_load_windows = .{
        \\            .aux = .{ .addr = 0x6000, .size = 0x0800 },
        \\        },
        \\        .window_assignments = .{
        \\            .math_core = .aux,
        \\        },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x001000 },
        \\        .registry = .{ .capacity = 2 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{ .math_core = "mathcore" },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_window_sidecar",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    if (ZeroPage.module.call("math_core", "add", .{3})) |value| {
        \\        _ = value;
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const params = [_]module_sidecars.DependencyParam{.{ .ty = .u8, .offset = 0 }};
    const exports = [_]module_sidecars.DependencyExport{.{
        .name = "add",
        .ordinal = 0,
        .target_original = 0x2400,
        .return_type = .u8,
        .params = &params,
        .frame_size = 3,
    }};
    const deps = [_]module_sidecars.DependencyModule{.{
        .id = "math_core",
        .payload_start = 0x2400,
        .jump_table_bytes = 3,
        .load_window_addr = 0xc000,
        .load_window_size = 0x0800,
        .payload_length = 0x0100,
        .exports = &exports,
        .relocations = &.{},
    }};

    const asm_text = try emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &deps });
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "lda zeropage_module_registry_active_row_aux",
        "jsr zeropage_module_activate_dependency_row1",
        "jsr $6000",
        "sta zeropage_module_registry_active_row_aux",
        "zeropage_module_registry_row1_reu_cache = $030800",
    });

    const too_large = [_]module_sidecars.DependencyModule{.{
        .id = "math_core",
        .payload_start = 0x2400,
        .jump_table_bytes = 3,
        .load_window_addr = 0xc000,
        .load_window_size = 0x0800,
        .payload_length = 0x0900,
        .exports = &exports,
        .relocations = &.{},
    }};
    try std.testing.expectError(error.ZeroPageModulePayloadTooLarge, emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &too_large }));
}

test "assigned dependency sidecars may target a BASIC banked load window" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .extra_load_windows = .{
        \\            .basic = .{ .addr = 0xa000, .size = 0x0800, .bank = .ram_under_basic },
        \\        },
        \\        .window_assignments = .{
        \\            .math_core = .basic,
        \\        },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x001000 },
        \\        .registry = .{ .capacity = 2 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{ .math_core = "mathcore" },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_basic_window_sidecar",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    if (ZeroPage.module.call("math_core", "add", .{3})) |value| {
        \\        _ = value;
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const params = [_]module_sidecars.DependencyParam{.{ .ty = .u8, .offset = 0 }};
    const exports = [_]module_sidecars.DependencyExport{.{
        .name = "add",
        .ordinal = 0,
        .target_original = 0x2400,
        .return_type = .u8,
        .params = &params,
        .frame_size = 3,
    }};
    const deps = [_]module_sidecars.DependencyModule{.{
        .id = "math_core",
        .payload_start = 0x2400,
        .jump_table_bytes = 3,
        .load_window_addr = 0xc000,
        .load_window_size = 0x0800,
        .payload_length = 0x0100,
        .exports = &exports,
        .relocations = &.{},
    }};

    const asm_text = try emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &deps });
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "lda zeropage_module_registry_active_row_basic",
        "jsr zeropage_module_activate_dependency_row1",
        "zeropage_module_activate_dependency_row1:",
        "jsr zeropage_module_bank_enter_basic",
        "jsr zeropage_reu_copy_reu_to_c64",
        "sta $a001",
        "jsr zeropage_module_bank_exit_basic",
        "sta zeropage_module_registry_active_row_basic",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr $a000") != null);
}

test "assigned dependency sidecars may target a KERNAL banked load window" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .extra_load_windows = .{
        \\            .kernal = .{ .addr = 0xe000, .size = 0x0800, .bank = .ram_under_kernal },
        \\        },
        \\        .window_assignments = .{
        \\            .math_core = .kernal,
        \\        },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x001000 },
        \\        .registry = .{ .capacity = 2 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{ .math_core = "mathcore" },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_kernal_window_sidecar",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    if (ZeroPage.module.call("math_core", "add", .{3})) |value| {
        \\        _ = value;
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const params = [_]module_sidecars.DependencyParam{.{ .ty = .u8, .offset = 0 }};
    const exports = [_]module_sidecars.DependencyExport{.{
        .name = "add",
        .ordinal = 0,
        .target_original = 0x2400,
        .return_type = .u8,
        .params = &params,
        .frame_size = 3,
    }};
    const deps = [_]module_sidecars.DependencyModule{.{
        .id = "math_core",
        .payload_start = 0x2400,
        .jump_table_bytes = 3,
        .load_window_addr = 0xc000,
        .load_window_size = 0x0800,
        .payload_length = 0x0100,
        .exports = &exports,
        .relocations = &.{},
    }};

    const asm_text = try emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &deps });
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "lda zeropage_module_registry_active_row_kernal",
        "jsr zeropage_module_activate_dependency_row1",
        "zeropage_module_activate_dependency_row1:",
        "jsr zeropage_module_bank_enter_kernal",
        "jsr zeropage_reu_copy_reu_to_c64",
        "sta $e001",
        "jsr zeropage_module_bank_exit_kernal",
        "sta zeropage_module_registry_active_row_kernal",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr $e000") != null);
}

test "assigned KERNAL bank dependency sidecars reject KERNAL-dependent exports" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .extra_load_windows = .{
        \\            .kernal = .{ .addr = 0xe000, .size = 0x0800, .bank = .ram_under_kernal },
        \\        },
        \\        .window_assignments = .{ .math_core = .kernal },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x001000 },
        \\        .registry = .{ .capacity = 2 },
        \\        .disk_manifest = .{ .current = "enemyrt", .deps = .{ .math_core = "mathcore" } },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_kernal_window_reject",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    if (ZeroPage.module.call("math_core", "add", .{3})) |value| { _ = value; }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const params = [_]module_sidecars.DependencyParam{.{ .ty = .u8, .offset = 0 }};
    const exports = [_]module_sidecars.DependencyExport{.{
        .name = "add",
        .ordinal = 0,
        .target_original = 0x2400,
        .return_type = .u8,
        .params = &params,
        .frame_size = 3,
        .requires_kernal_rom = true,
    }};
    const deps = [_]module_sidecars.DependencyModule{.{
        .id = "math_core",
        .payload_start = 0x2400,
        .jump_table_bytes = 3,
        .load_window_addr = 0xc000,
        .load_window_size = 0x0800,
        .payload_length = 0x0100,
        .exports = &exports,
        .relocations = &.{},
    }};

    try std.testing.expectError(error.UnsafeKernalBankModuleExport, emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &deps }));
}

test "assigned KERNAL bank dependency sidecars accept trampoline-safe console exports" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .extra_load_windows = .{
        \\            .kernal = .{ .addr = 0xe000, .size = 0x0800, .bank = .ram_under_kernal },
        \\        },
        \\        .window_assignments = .{ .math_core = .kernal },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x001000 },
        \\        .registry = .{ .capacity = 2 },
        \\        .disk_manifest = .{ .current = "enemyrt", .deps = .{ .math_core = "mathcore" } },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_kernal_window_accept",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    if (ZeroPage.module.call("math_core", "add", .{3})) |value| { _ = value; }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const params = [_]module_sidecars.DependencyParam{.{ .ty = .u8, .offset = 0 }};
    const exports = [_]module_sidecars.DependencyExport{.{
        .name = "add",
        .ordinal = 0,
        .target_original = 0x2400,
        .return_type = .u8,
        .params = &params,
        .frame_size = 3,
        .requires_kernal_rom = true,
        .kernal_trampoline_safe = true,
    }};
    const deps = [_]module_sidecars.DependencyModule{.{
        .id = "math_core",
        .payload_start = 0x2400,
        .jump_table_bytes = 3,
        .load_window_addr = 0xc000,
        .load_window_size = 0x0800,
        .payload_length = 0x0100,
        .exports = &exports,
        .relocations = &.{},
    }};

    const asm_text = try emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &deps });
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr zeropage_module_bank_enter_kernal") != null);
}

test "low-level graph node calls dispatch through transitive registry rows" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x002000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .registry = .{ .capacity = 4 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{
        \\                .math_core = "mathcore",
        \\                .pathing = "pathing",
        \\                .fixed_math = "fixedmath",
        \\            },
        \\        },
        \\        .dependency_graph = .{
        \\            .math_core = .{ .deps = .{ .fixed_math } },
        \\            .pathing = .{ .deps = .{} },
        \\            .fixed_math = .{ .deps = .{} },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_graph_calls",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core", "pathing" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    if (ZeroPage.module.call("fixed_math", "bias", .{4})) |value| { _ = value; }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const params = [_]module_sidecars.DependencyParam{.{ .ty = .u8, .offset = 0 }};
    const fixed_exports = [_]module_sidecars.DependencyExport{.{
        .name = "bias",
        .ordinal = 0,
        .target_original = 0x2500,
        .return_type = .u8,
        .params = &params,
        .frame_size = 3,
    }};
    const deps = [_]module_sidecars.DependencyModule{.{
        .id = "fixed_math",
        .payload_start = 0x2500,
        .jump_table_bytes = 3,
        .load_window_addr = 0xc000,
        .load_window_size = 0x0800,
        .payload_length = 0x0100,
        .exports = &fixed_exports,
        .relocations = &.{},
    }};

    const asm_text = try emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &deps });
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "lda zeropage_module_registry_row3_loaded",
        "jsr zeropage_module_activate_dependency_row3",
        "jsr zeropage_module_registry_jump_table+0",
        "zeropage_module_activate_dependency_row3:",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_load_dependency_row3:") == null);

    try std.testing.expectError(error.MissingZeroPageDependencySidecar, emitProgramWithOptions(std.testing.allocator, parsed.program, .{}));
}

test "typed graph node binding calls lower to transitive registry rows" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\const FixedMath = ZeroPage.module.import(.fixed_math, .{
        \\    .bias = fn (u8) u8,
        \\});
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x002000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .registry = .{ .capacity = 4 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{
        \\                .math_core = "mathcore",
        \\                .pathing = "pathing",
        \\                .fixed_math = "fixedmath",
        \\            },
        \\        },
        \\        .dependency_graph = .{
        \\            .math_core = .{ .deps = .{ .fixed_math } },
        \\            .pathing = .{ .deps = .{} },
        \\            .fixed_math = .{ .deps = .{} },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_typed_graph_node",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core", "pathing" },
        \\};
        \\fn tick(v: u8) u8 { return v + 1; }
        \\export fn main() void {
        \\    if (FixedMath.bias(4)) |value| { _ = value; }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const params = [_]module_sidecars.DependencyParam{.{ .ty = .u8, .offset = 0 }};
    const fixed_exports = [_]module_sidecars.DependencyExport{.{
        .name = "bias",
        .ordinal = 0,
        .target_original = 0x2500,
        .return_type = .u8,
        .params = &params,
        .frame_size = 3,
    }};
    const deps = [_]module_sidecars.DependencyModule{.{
        .id = "fixed_math",
        .payload_start = 0x2500,
        .jump_table_bytes = 3,
        .load_window_addr = 0xc000,
        .load_window_size = 0x0800,
        .payload_length = 0x0100,
        .exports = &fixed_exports,
        .relocations = &.{},
    }};

    const asm_text = try emitProgramWithOptions(std.testing.allocator, parsed.program, .{ .dependency_modules = &deps });
    defer std.testing.allocator.free(asm_text);
    try expectContainsInOrder(asm_text, &.{
        "lda zeropage_module_registry_row3_loaded",
        "jsr zeropage_module_activate_dependency_row3",
        "jsr zeropage_module_registry_jump_table+0",
    });
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "FixedMath") == null);
    try std.testing.expectError(error.MissingZeroPageDependencySidecar, emitProgramWithOptions(std.testing.allocator, parsed.program, .{}));
}

test "raw image metadata controls assembly origin and entry" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .image = .{ .load_addr = 0x1000, .entry_addr = 0x1010, .basic_stub = false, .address_limit = 0xc600 },
        \\};
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "* = $1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "* = $1010") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "basic_next") == null);
}

test "direct scalar ALU operands preserve carry width and avoid scratch" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn plus(a: u16, b: u8) u16 { return a + b; }
        \\fn minus(a: u16, b: u16) u16 { return a - b; }
        \\fn masked(a: u16) u16 { return a & 0x81ff; }
        \\fn joined(a: u16, b: u16) u16 { return a | b; }
        \\export fn main() void { _ = plus(255, 1); _ = minus(256, 1); _ = masked(0xffff); _ = joined(1, 256); }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try pipeline.emitBeforeSingleCallLeaf(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try expectContainsInOrder(assembly, &.{ "plus:", "adc plus_b", "pha\n    lda plus_a+1\n    adc #0\n    tax\n    pla" });
    try expectContainsInOrder(assembly, &.{ "minus:", "sbc minus_b", "pha\n    lda minus_a+1\n    sbc minus_b+1\n    tax\n    pla" });
    // ALU lowering still selects both byte immediates; CFG cleanup can remove
    // the low-byte identity once PHA/TXA/high-AND makes its N/Z unobservable.
    const raw = try pipeline.emitUnoptimizedAssembly(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(raw);
    try expectContainsInOrder(raw, &.{ "masked:", "and #255", "and #129" });
    try expectContainsInOrder(assembly, &.{ "masked:", "lda masked_a", "pha\n    txa\n    and #129\n    tax\n    pla" });
    try std.testing.expect(std.mem.indexOf(u8, assembly, "and #255") == null);
    try expectContainsInOrder(assembly, &.{ "joined:", "ora joined_b", "ora joined_b+1" });
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_math_tmp:") == null);
}

test "direct ALU operands read mutable RHS only after lhs effects" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn mutate(location: *u16) u16 { location.* = 300; return 7; }
        \\fn add(initial: u16) u16 { var rhs: u16 = initial; return mutate(&rhs) + rhs; }
        \\fn bits(initial: u16) u16 { var rhs: u16 = initial; return mutate(&rhs) ^ rhs; }
        \\export fn main() void { _ = add(1); _ = bits(1); }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try expectContainsInOrder(assembly, &.{ "add:", "jsr mutate", "adc add_rhs", "adc add_rhs+1" });
    try expectContainsInOrder(assembly, &.{ "bits:", "jsr mutate", "eor bits_rhs", "eor bits_rhs+1" });
}

test "word byte extraction shifts omit all unused shift helpers and scratch" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn high(value: u16) u16 { return value >> 8; }
        \\export fn main() void { _ = high(0x81ff); }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try pipeline.emitBeforeSingleCallLeaf(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try expectContainsInOrder(assembly, &.{ "high:", "asl\n    txa\n    ldx #0" });
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_shift_") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_shl16") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_shr16") == null);
}

test "constant shift assignments use count entries and prune count storage" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn left(value: u16) u16 { var result: u16 = value; result <<= 3; return result; }
        \\export fn main() void { _ = left(0x81ff); }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try expectContainsInOrder(assembly, &.{ "left:", "jsr zeropage_shl16_const_3", "zeropage_shl16_const_3:", "ldx #3", "dex" });
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_shift_count") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_shr16") == null);
}

test "constant switch results prune scratch and own readonly table data" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn choose(value: u8) u16 { return switch (value) {
        \\    224 => 0x8000, 225 => 0x8001, 226 => 0x8002, 227 => 0x8003,
        \\    228 => 0x8004, 229 => 0x8005, else => 65535,
        \\}; }
        \\export fn main() void { _ = choose(225); }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "kind=lookup") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "ldx @w zeropage_lookup_") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "-224,y") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "owner=compiler kind=rodata") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_switch_value:") == null);
}

test "switch folding validates every constant cast before eliminating dispatch" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\export fn main() void {
        \\    const value: u8 = switch (0) { 0 => 1, else => @as(u16, 300) };
        \\    _ = value;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCast, emitProgram(std.testing.allocator, parsed.program));
}

test "low images reject biased lookup costs instead of producing negative operands" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .image = .{ .load_addr = 0x0010, .entry_addr = 0x0010, .basic_stub = false },
        \\};
        \\fn choose(value: u8) u16 { return switch (value) {
        \\    224 => 0x8000, 225 => 0x8001, 226 => 0x8002, 227 => 0x8003,
        \\    228 => 0x8004, 229 => 0x8005, else => 65535,
        \\}; }
        \\export fn main() void { _ = choose(225); }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "kind=lookup") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_switch_value:") != null);
}

test "explicit dispatch references preserve legacy case entry semantics" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn choose(value: u8) u8 { return switch (value) {
        \\    0 => 20, 1 => 21, 2 => 22, 3 => 23, else => 24,
        \\}; }
        \\export fn main() void {
        \\    _ = choose(0);
        \\    asm {
        \\        ; debugger reference to switch_expr_0_case_0
        \\        nop
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_switch_result") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_switch_value:") != null);
}

test "source stride helper names retain their meaning and keep generic addressing" {
    const parsed = try parser.parseSource(std.testing.allocator,
        \\const WordPoint = struct { x: u16, y: u16 };
        \\fn zeropage_stride_mul_4(value: u16) u16 { return value + 1; }
        \\export fn main() void {
        \\    var words = [_]WordPoint{ WordPoint{ .x = 1, .y = 2 }, WordPoint{ .x = 3, .y = 4 } };
        \\    var index: u8 = 1;
        \\    words[index].y = zeropage_stride_mul_4(words[0].x);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try emitProgram(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(assembly);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assembly, "\nzeropage_stride_mul_4:\n"));
    try std.testing.expect(std.mem.indexOf(u8, assembly, "jsr zeropage_mul16") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_stride_selection") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_mul_rhs:\n") != null);
}
