const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const emitter = @import("codegen/tass64/emitter.zig");
const a = std.testing.allocator;

const functions =
    \\fn index() u8 { return 0; }
    \\fn rhs() u8 { return 3; }
    \\const Holder = struct { pad: u8, items: [2]u16 };
    \\export fn main() void {}
;

fn emit(source: []const u8) ![]u8 {
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    return emitter.emitProgram(a, parsed.program);
}

fn apiCode(text: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, text, "\napi:\n") orelse return error.MissingApi;
    const end = std.mem.indexOfPos(u8, text, start, "; zeropage_section_end owner=function:api kind=code") orelse return error.MissingApi;
    return text[start..end];
}

test "compound indexed update emits the address/index and RHS exactly once across supported families" {
    for ([_][]const u8{
        "export fn api() u8 { var values = [_]u8{1,2}; values[index()] {s} rhs(); return values[0]; }",
        "export fn api() u16 { var values = [_]u16{1,2}; values[index()] {s} rhs(); return values[0]; }",
        "export fn api(p: [*]u8) u8 { p[index()] {s} rhs(); return 0; }",
        "export fn api(p: [*]u16) u16 { p[index()] {s} rhs(); return 0; }",
        "export fn api(h: *Holder) u16 { h.items[index()] {s} rhs(); return 0; }",
        "export fn api() u16 { var h = Holder{.pad=0,.items=[_]u16{1,2}}; h.items[index()] {s} rhs(); return h.items[0]; }",
    }) |pattern| {
        for ([_][]const u8{ "+=", "-=", "*=", "&=", "|=", "^=", "<<=", ">>=" }) |op| {
            const split = std.mem.indexOf(u8, pattern, "{s}").?;
            const stmt = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ pattern[0..split], op, pattern[split + 3 ..] });
            defer a.free(stmt);
            const source = try std.fmt.allocPrint(a, "{s}\n{s}", .{ functions, stmt });
            defer a.free(source);
            const asm_text = try emit(source);
            defer a.free(asm_text);
            const code = try apiCode(asm_text);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, code, "    jsr index\n"));
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, code, "    jsr rhs\n"));
            try std.testing.expect(std.mem.indexOf(u8, code, "    jsr index\n").? < std.mem.indexOf(u8, code, "    jsr rhs\n").?);
        }
    }
}

test "compound indexed byte direct ALU keeps Y and needs neither stack nor scratch" {
    const text = try emit("export fn api(index:u8, rhs:u8)u8{var v=[_]u8{7,9};v[index] += rhs;return 0;}export fn main()void{}");
    defer a.free(text);
    const code = try apiCode(text);
    const start = std.mem.indexOf(u8, code, "    lda api_index\n") orelse return error.MissingUpdate;
    const update = code[start..];
    try std.testing.expect(std.mem.startsWith(u8, update, "    lda api_index\n    tay\n    lda api_v,y\n    clc\n    adc api_rhs\n    sta api_v,y\n"));
    try std.testing.expect(std.mem.indexOf(u8, update, "    pha\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, update, "zeropage_math_tmp") == null);
}

test "compound indexed operation holds the old word until its effectful RHS completes" {
    const text = try emit(functions ++ "\nexport fn api()u16{var v=[_]u16{7,9};v[index()] *= rhs();return v[0];}");
    defer a.free(text);
    const code = try apiCode(text);
    const read = std.mem.indexOf(u8, code, "    lda api_v,y\n").?;
    const rhs = std.mem.indexOf(u8, code, "    jsr rhs\n").?;
    const scratch = std.mem.indexOf(u8, code, "    sta zeropage_mul_lhs\n").?;
    try std.testing.expect(read < rhs and rhs < scratch);
}

test "compound indexed dynamic shift reads the old word before the count" {
    const text = try emit(functions ++ "\nexport fn api()u16{var v=[_]u16{7,9};v[index()] <<= rhs();return v[0];}");
    defer a.free(text);
    const code = try apiCode(text);
    const read = std.mem.indexOf(u8, code, "    lda api_v,y\n").?;
    const count = std.mem.indexOf(u8, code, "    jsr rhs\n").?;
    try std.testing.expect(read < count);
}

fn oom(allocator: std.mem.Allocator, program: ast.Program) !void {
    const text = emitter.emitProgram(allocator, program) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    defer allocator.free(text);
}

test "compound target ownership is released on every emission allocation failure" {
    const p = try parser.parseSource(a, functions ++ "\nexport fn api(h:*Holder)u16{h.items[index()] *= rhs();return 0;}");
    defer p.deinit(a);
    try std.testing.checkAllAllocationFailures(a, oom, .{p.program});
}

test "indexed literal multiply reuses the destination registers" {
    const text = try emit(
        "export fn a() u8 { return 42; } " ++
            "export fn api(p:[*]volatile u16, i:u8)u8{p[i] *= 8;return a();}" ++
            "export fn main()void{}",
    );
    defer a.free(text);
    const code = try apiCode(text);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, code, "    lda (zeropage_ptr_tmp),y\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, code, "    sta (zeropage_ptr_tmp),y\n"));
    try std.testing.expect(std.mem.indexOf(u8, code, "    jsr zeropage_mul16\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "    asl\n    pha\n    txa\n    rol\n    tax\n    pla\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "    asl a\n") == null);
}

test "indexed byte multiply by zero preserves the target read" {
    const text = try emit("export fn api(p:[*]volatile u8,i:u8)u8{p[i] *= 0;return 17;}export fn main()void{}");
    defer a.free(text);
    const code = try apiCode(text);
    try std.testing.expect(std.mem.indexOf(u8, code, "    lda (zeropage_ptr_tmp),y\n    lda #0\n    sta (zeropage_ptr_tmp),y\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "    jsr zeropage_mul16\n") == null);
}

test "managed indexed multiply selects a scratch-free power of two" {
    const prefix = "pub const zeropage_options=.{.zero_page=.{.profile=.kernal,.allocation=.scalars}};";
    const fast = try emit(prefix ++ "export fn api(p:[*]u8,i:u8)u8{p[i] *= 4;return 0;}export fn main()void{}");
    defer a.free(fast);
    try std.testing.expect(std.mem.indexOf(u8, try apiCode(fast), "    asl\n    asl\n    sta (zeropage_ptr_tmp),y\n") != null);
    const generic = try emit(prefix ++ "export fn api(p:[*]u8,i:u8)u8{p[i] *= 3;return 0;}export fn main()void{}");
    defer a.free(generic);
    try std.testing.expect(std.mem.indexOf(u8, try apiCode(generic), "    jsr zeropage_mul16\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, generic, "zeropage_math_tmp") == null);
}

test "indexed literal multiply keeps a helper referenced by inline assembly" {
    const text = try emit("export fn main()void{var a=[_]u8{2,3};a[0] *= 3;\nasm {\njsr ZEROPAGE_MUL16\n}\n}");
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "    jsr zeropage_mul16\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\nzeropage_mul16:\n") != null);
}

test "indexed odd word multiplication holds the original destination" {
    const text = try emit("export fn api(p:[*]volatile u16,i:u8)u8{p[i] *= 7;return 17;}export fn main()void{}");
    defer a.free(text);
    const code = try apiCode(text);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, code, "    lda (zeropage_ptr_tmp),y\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, code, "    sta (zeropage_ptr_tmp),y\n"));
    try std.testing.expect(std.mem.indexOf(u8, code, "    sbc zeropage_mul_lhs+1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "    jsr zeropage_mul16\n") == null);
}
