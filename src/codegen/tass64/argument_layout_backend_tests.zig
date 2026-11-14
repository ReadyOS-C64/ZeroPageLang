const std = @import("std");
const parser = @import("../../parser.zig");
const emitter = @import("emitter.zig");
const pipeline = @import("pipeline.zig");
const arguments = @import("call_argument_rewrite.zig");
const a = std.testing.allocator;

fn has(text: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, text, needle) != null);
}
fn lacks(text: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, text, needle) == null);
}
fn source(mode: []const u8, body: []const u8) ![]u8 {
    if (std.mem.eql(u8, mode, "default")) return a.dupe(u8, body);
    return std.fmt.allocPrint(a, "pub const zeropage_options = .{{ .zero_page = .{{ .profile = .kernal, .allocation = .{s} }} }};\n{s}", .{mode, body});
}

// The private argument consumer may prove a fixed resident write safe while
// parameter relocation must continue to decline the same layout observer.
test "argument layout backend recovers final word without relocating its formal" {
    const body =
        \\fn leaf(value: u16) u16 { return value ^ 0x8152; }
        \\fn observer() u16 { var neighbor: u16 = 7; return @intFromPtr(&neighbor); }
        \\export fn main() void { _ = leaf(0x81ff); _ = observer(); }
    ;
    for ([_][]const u8{"default", "off", "scratch", "scalars"}) |mode| {
        const text = try source(mode, body);
        defer a.free(text);
        const parsed = try parser.parseSource(a, text);
        defer parsed.deinit(a);
        const before = try emitter.emitProgram(a, parsed.program);
        defer a.free(before);
        const after = try arguments.rewrite(a, parsed.program, before);
        defer a.free(after);
        try has(after, "sta leaf_value\n    stx leaf_value+1\n");
        try has(after, "lda leaf_value+1\n    jsr leaf\n");
        try lacks(after, "lda zeropage_call_arg_0\n    sta leaf_value\n");
        try has(after, "direct_arguments=1 final_words=1");
        const final = try pipeline.emitProgram(a, parsed.program);
        defer a.free(final);
        try has(final, "leaf_value:\n    .word 0");
        try lacks(final, "; zeropage_zp_claim label=leaf_value ");
        if (std.mem.eql(u8, mode, "scalars")) try has(final, "; zeropage_zp_parameter label=leaf_value size=2 reason=layout_observer status=excluded");
    }
}

test "argument layout backend later indirect volatile read still forbids early word store" {
    const body =
        \\fn leaf(value: u16, last: u8) u16 { return value; }
        \\export fn main() void {
        \\    var address: u16 = 0xc500;
        \\    const location: *volatile u8 = @ptrFromInt(address);
        \\    _ = leaf(0x8134, location.*);
        \\}
    ;
    for ([_][]const u8{"default", "off", "scratch", "scalars"}) |mode| {
        const text = try source(mode, body);
        defer a.free(text);
        const parsed = try parser.parseSource(a, text);
        defer parsed.deinit(a);
        const before = try emitter.emitProgram(a, parsed.program);
        defer a.free(before);
        const after = try arguments.rewrite(a, parsed.program, before);
        defer a.free(after);
        try has(after, "lda (zeropage_ptr_tmp),y\n");
        try has(after, "lda zeropage_call_arg_0\n    sta leaf_value\n");
        try lacks(after, "sta leaf_value\n    stx leaf_value+1\n");
        try lacks(after, "; zeropage_scalar_call_selection ");
        // Independently rebuild the only allowed change: strip private markers.
        var expected: std.Io.Writer.Allocating = .init(a);
        defer expected.deinit();
        var lines = std.mem.splitScalar(u8, before, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "; zeropage_scalar_call_")) continue;
            try expected.writer.writeAll(line);
            if (lines.index != null) try expected.writer.writeByte('\n');
        }
        try std.testing.expectEqualStrings(expected.written(), after);
    }
}
