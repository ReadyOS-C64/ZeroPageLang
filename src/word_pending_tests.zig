const std = @import("std");
const parser = @import("parser.zig");
const emitter = @import("codegen/tass64/emitter.zig");
const a = std.testing.allocator;
fn emit(source: []const u8) ![]u8 {
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    return emitter.emitProgram(a, parsed.program);
}
test "pending word capture spans actual index calls in all four lowering paths" {
    for ([_][]const u8{
        @embedFile("testdata/word_pending/ordinary_word_array-word_call.zp64"),
        @embedFile("testdata/word_pending/record_word_field-word_call.zp64"),
        @embedFile("testdata/word_pending/pointer_struct_word_array-word_call.zp64"),
        @embedFile("testdata/word_pending/many_pointer_word_element-word_call.zp64"),
    }) |source| {
        const text = try emit(source);
        defer a.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "ldx api_value+1\n    lda api_value\n    pha\n    txa\n    pha\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "zeropage_field_value_") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "    pla\n    tax\n    pla\n    sta ") != null);
    }
}
test "pending word direct identifier and field index preserve the existing math scratch fast path" {
    for ([_][]const u8{
        @embedFile("testdata/word_pending/ordinary_word_array-identifier.zp64"),
        @embedFile("testdata/word_pending/record_word_field-identifier.zp64"),
        @embedFile("testdata/word_pending/pointer_struct_word_array-identifier.zp64"),
        @embedFile("testdata/word_pending/many_pointer_word_element-identifier.zp64"),
        @embedFile("testdata/word_pending/ordinary_word_array-field_value.zp64"),
        @embedFile("testdata/word_pending/record_word_field-field_value.zp64"),
        @embedFile("testdata/word_pending/pointer_struct_word_array-field_value.zp64"),
        @embedFile("testdata/word_pending/many_pointer_word_element-field_value.zp64"),
    }) |source| {
        const text = try emit(source);
        defer a.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "ldx api_value+1\n    lda api_value\n    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "zeropage_field_value_") == null);
    }
}
test "pending base preservation distinguishes indirect field evaluation from direct Value" {
    const complex = try emit(@embedFile("testdata/word_pending/many_pointer_word_element-field_value.zp64"));
    defer a.free(complex);
    try std.testing.expect(std.mem.indexOf(u8, complex, "ldx api_ptr+1\n    lda api_ptr\n    pha\n    txa\n    pha\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, complex, "pla\n    sta zeropage_ptr_tmp+1\n    pla\n    sta zeropage_ptr_tmp\n") != null);
    const simple = try emit(@embedFile("testdata/word_pending/many_pointer_word_element-identifier.zp64"));
    defer a.free(simple);
    try std.testing.expect(std.mem.indexOf(u8, simple, "ldx api_ptr+1\n    lda api_ptr\n    sta zeropage_ptr_tmp\n    stx zeropage_ptr_tmp+1\n") != null);
}
fn allocationProof(fail: std.mem.Allocator, program: @import("ast.zig").Program) !void {
    const text = emitter.emitProgram(fail, program) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    defer fail.free(text);
}
test "pending word and pointer base stack capture retains all allocation cleanup" {
    const parsed = try parser.parseSource(a, @embedFile("testdata/word_pending/many_pointer_word_element-word_call.zp64"));
    defer parsed.deinit(a);
    try std.testing.checkAllAllocationFailures(a, allocationProof, .{parsed.program});
}
