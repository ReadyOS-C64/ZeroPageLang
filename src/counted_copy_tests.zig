const std = @import("std");
const parser = @import("parser.zig");
const pipeline = @import("codegen/tass64/pipeline.zig");

const a = std.testing.allocator;
const sample =
    \\const Buffer = struct { bytes: [9]u8 };
    \\fn copy(source: *Buffer) u8 {
    \\    var dest = Buffer{ .bytes = [_]u8{0,0,0,0,0,0,0,0,0} };
    \\    for (0..9) |i| { dest.bytes[i] = source.bytes[i]; }
    \\    return dest.bytes[8];
    \\}
    \\export fn main() void {
    \\    var source = Buffer{ .bytes = [_]u8{9,82,155,228,45,118,191,8,81} };
    \\    _ = copy(&source);
    \\}
;

fn emit(source: []const u8) ![]u8 {
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    return pipeline.emitProgram(a, parsed.program);
}

test "counted copy keeps its real accesses and reconstructs the original loop exit" {
    const assembly = try emit(sample);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    ldy #0\nfor_0_body:\n; zeropage_loop_capture source=copy_i\n    sty copy_i\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda (zeropage_ptr_tmp),y\n    sta copy_dest_bytes,y\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    inc copy_for_0_index\n    iny\n    cpy #9\n    bcc for_0_body\n    dey\n    lda copy_for_0_index\n    cmp #9\nfor_0_done:\n") != null);
}

test "counted copy resolves remapped compiler and parameter zero-page words" {
    const policy = "pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scalars, .ranges = .{.{ .addr = 0x20, .size = 16 }} } };\n";
    const assembly = try emit(policy ++ sample);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_ptr_tmp = address($20)") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "copy_source = address($24)") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    cpy #9\n    bcc for_0_body\n") != null);
}

test "counted copy leaves loops with another memory effect alone" {
    const changed = try std.mem.replaceOwned(u8, a, sample, "dest.bytes[i] = source.bytes[i];", "dest.bytes[i] = source.bytes[i]; source.bytes[i] = 0;");
    defer a.free(changed);
    const assembly = try emit(changed);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    cpy #9\n    bcc for_0_body\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    sta (zeropage_ptr_tmp),y\nfor_0_next:\n    inc copy_for_0_index\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "    lda copy_for_0_index\n    cmp #9\n    bcc for_0_body\n") != null);
}
