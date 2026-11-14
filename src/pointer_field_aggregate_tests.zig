const std = @import("std");
const parser = @import("parser.zig");
const emitter = @import("codegen/tass64/emitter.zig");
const a = std.testing.allocator;
fn emit(source: []const u8) ![]u8 {
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    return emitter.emitProgram(a, parsed.program);
}
fn copied(source: []const u8, high_source: []const u8, high_dest: []const u8) !void {
    const assembly = try emit(source);
    defer a.free(assembly);
    const expected = try std.fmt.allocPrint(a, "lda {s}+1\n    sta {s}+1", .{ high_source, high_dest });
    defer a.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, assembly, expected) != null);
}
test "ordinary aggregate copy preserves pointer field high byte" {
    try copied("const H=struct{ptr:*u8};export fn api(h:H)H{const copy:H=h;return copy;}export fn main()void{}", "api_h_ptr", "api_copy_ptr");
}
test "ordinary nested aggregate copy preserves pointer field high byte" {
    try copied("const I=struct{ptr:*u8};const H=struct{tag:u8,inner:I};export fn api(h:H)H{const copy:H=h;return copy;}export fn main()void{}", "api_h_inner_ptr", "api_copy_inner_ptr");
}
test "ordinary aggregate copy preserves nullable pointer representation" {
    try copied("const H=struct{ptr:?*u8};export fn api(h:H)H{const copy:H=h;return copy;}export fn main()void{}", "api_h_ptr", "api_copy_ptr");
}
test "ordinary aggregate argument and return copy preserve complete pointers" {
    try copied("const H=struct{ptr:*u8};fn read(h:H)*u8{return h.ptr;}export fn api(h:H)*u8{return read(h);}export fn main()void{}", "api_h_ptr", "read_h_ptr");
    try copied("const H=struct{ptr:*u8};fn make(p:*u8)H{return H{.ptr=p};}export fn api(p:*u8)*u8{const h:H=make(p);return h.ptr;}export fn main()void{}", "make_return_ptr", "api_h_ptr");
}
test "large struct range copy remains full physical byte copy" {
    const assembly = try emit("const H=struct{pad:[16]u8,ptr:*u8};export fn api(h:H)H{const copy:H=h;return copy;}export fn main()void{}");
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "cpx #18") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "lda api_h,x\n    sta api_copy,x") != null);
}
fn oom(a_fail: std.mem.Allocator, program: @import("ast.zig").Program) !void {
    const assembly = emitter.emitProgram(a_fail, program) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    defer a_fail.free(assembly);
}
test "pointer aggregate copy retains cleanup on all allocation failures" {
    const parsed = try parser.parseSource(a, "const H=struct{ptr:?*u8};export fn api(h:H)H{const copy:H=h;return copy;}export fn main()void{}");
    defer parsed.deinit(a);
    try std.testing.checkAllAllocationFailures(a, oom, .{parsed.program});
}
