const std = @import("std");
const parser = @import("../../parser.zig");
const emitter = @import("emitter.zig");
const rewrite = @import("call_argument_rewrite.zig");
const allocator = std.testing.allocator;

fn check(source: []const u8, selected: bool) !void {
    const parsed = try parser.parseSource(allocator, source);
    defer parsed.deinit(allocator);
    const before = try emitter.emitProgram(allocator, parsed.program);
    defer allocator.free(before);
    const after = try rewrite.rewrite(allocator, parsed.program, before);
    defer allocator.free(after);
    if (!selected) {
        var expected: std.Io.Writer.Allocating = .init(allocator);
        defer expected.deinit();
        var lines = std.mem.splitScalar(u8, before, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "; zeropage_scalar_call_")) continue;
            try expected.writer.writeAll(line);
            if (lines.index != null) try expected.writer.writeByte('\n');
        }
        try std.testing.expectEqualStrings(expected.written(), after);
        return;
    }
    try std.testing.expect(std.mem.indexOf(u8, after, "; zeropage_scalar_call_selection direct_arguments=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "sta leaf_a\n    stx leaf_a+1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "lda zeropage_call_arg_0\n    sta leaf_a") == null);
    // The untouched physical last copy guarantees the old final A/NZ, while
    // earlier STA/STX do not change X/Y or any status bits.
    try std.testing.expect(std.mem.indexOf(u8, after, "lda zeropage_call_arg_1\n    sta leaf_b\n") != null);
}

test "static argument rewrite removes an early word copy and keeps last byte staging" {
    try check("fn leaf(a: u16, b: u8) u16 { return a; } export fn main() void { _ = leaf(0x8134, 7); }", true);
}

test "first expression call is before capture but a later call is a barrier" {
    try check("fn first() u16 { return 0x8134; } fn leaf(a: u16, b: u8) u16 { return a; } export fn main() void { _ = leaf(first(), 7); }", true);
    try check("fn later() u8 { return 7; } fn leaf(a: u16, b: u8) u16 { return a; } export fn main() void { _ = leaf(0x8134, later()); }", false);
}

test "public and escaped parameter storage stays on existing call path" {
    try check("export fn leaf(a: u16, b: u8) u16 { return a; } export fn main() void { _ = leaf(0x8134, 7); }", false);
    try check("fn leaf(a: u16, b: u8) u16 { const p: *u16 = &a; return p.*; } export fn main() void { _ = leaf(0x8134, 7); }", false);
}

test "word target under visible BASIC ROM is excluded conservatively" {
    try check("pub const zeropage_options = .{ .image = .{ .basic_stub = false, .load_addr = 0xa000, .entry_addr = 0xa000 } }; fn leaf(a: u16, b: u8) u16 { return a; } export fn main() void { _ = leaf(0x8134, 7); }", false);
}

test "argument rewrite allocation failures release proof and output storage" {
    const parsed = try parser.parseSource(allocator, "fn leaf(a: u16, b: u8) u16 { return a; } export fn main() void { _ = leaf(0x8134, 7); }");
    defer parsed.deinit(allocator);
    const before = try emitter.emitProgram(allocator, parsed.program);
    defer allocator.free(before);
    try std.testing.checkAllAllocationFailures(allocator, allocationFailure, .{ parsed.program, before });
}

fn allocationFailure(failing: std.mem.Allocator, program: @import("../../ast.zig").Program, before: []const u8) !void {
    const after = rewrite.rewrite(failing, program, before) catch |err| switch (err) {
        // Allocating Writer reports its allocator failure as WriteFailed.
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer failing.free(after);
}
