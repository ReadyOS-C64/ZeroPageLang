const std = @import("std");
const parser = @import("../../parser.zig");
const emitter = @import("emitter.zig");
const pipeline = @import("pipeline.zig");
const a = std.testing.allocator;
const body =
    \\fn invert(value: bool) bool { return !value; }
    \\export fn entry(value: bool) bool { return invert(value); }
    \\export fn main() void { _ = entry(true); _ = entry(false); }
;
fn sourceLabels(text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "bool_not_") and std.mem.endsWith(u8, line, ":")) try out.writer.print("{s}\n", .{line});
    }
    return out.toOwnedSlice();
}
test "zero test backend folds actual boolean inversion under all source ZP policies" {
    for ([_][]const u8{ "", "pub const zeropage_options=.{.zero_page=.{.profile=.kernal,.allocation=.scratch}};", "pub const zeropage_options=.{.zero_page=.{.profile=.kernal,.allocation=.scalars}};" }) |prefix| {
        const source = try std.mem.concat(a, u8, &.{ prefix, "\n", body });
        defer a.free(source);
        const parsed = try parser.parseSource(a, source);
        defer parsed.deinit(a);
        const raw = try emitter.emitProgram(a, parsed.program);
        defer a.free(raw);
        const final = try pipeline.emitProgram(a, parsed.program);
        defer a.free(final);
        try std.testing.expect(std.mem.indexOf(u8, raw, "beq bool_not_") != null);
        try std.testing.expect(std.mem.indexOf(u8, final, "bcs bool_not_") != null);
        try std.testing.expect(std.mem.indexOf(u8, final, "beq bool_not_") == null);
        const old_labels = try sourceLabels(raw);
        defer a.free(old_labels);
        const new_labels = try sourceLabels(final);
        defer a.free(new_labels);
        try std.testing.expect(old_labels.len > 0);
        try std.testing.expectEqualStrings(old_labels, new_labels);
    }
}
test "zero test backend retains a real volatile producer call and pointee read" {
    const source =
        \\fn read(p: *volatile u8) bool { return p.* != 0; }
        \\fn invert(p: *volatile u8) bool { return !read(p); }
        \\export fn main() void { const p: *volatile u8 = @ptrFromInt(0xc100); _ = invert(p); }
    ;
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    const final = try pipeline.emitProgram(a, parsed.program);
    defer a.free(final);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, final, "    jsr read\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, final, "lda (zeropage_ptr_tmp),y"));
    try std.testing.expect(std.mem.indexOf(u8, final, "bcs bool_not_") != null);
}
test "zero test backend retains original materializers for modules placements and source ASM" {
    const module =
        \\pub const zeropage_options=.{.stack=.{.base=0xc800,.size=0x400},.abi=.{.functions=.{.root=.{.frame=.stack}}}};
        \\pub const zeropage_module=.{.id="zero_test_guard",.abi=1,.exports=.{.root=root},.deps=.{}};
        \\fn root(value:bool)bool{return invert(value);}
    ;
    const placement =
        \\pub const zeropage_options=.{.memory=.{.regions=.{.fixed=.{.addr=0x2000,.size=0x100}},.placements=.{.fixed=.{.region=.fixed,.load=.direct,.functions=.{placed}}}}};
        \\fn placed()u8{return 7;}
    ;
    const assembly = try std.mem.replaceOwned(u8, a, body, "_ = entry(false);", "_ = entry(false);\nasm {\nnop\n}\n");
    defer a.free(assembly);
    for ([_][]const u8{ module, placement, "" }, 0..) |prefix, index| {
        const source = try std.mem.concat(a, u8, &.{ prefix, "\n", if (index == 2) assembly else body });
        defer a.free(source);
        const parsed = try parser.parseSource(a, source);
        defer parsed.deinit(a);
        const final = try pipeline.emitProgram(a, parsed.program);
        defer a.free(final);
        try std.testing.expect(std.mem.indexOf(u8, final, "beq bool_not_") != null);
        try std.testing.expect(std.mem.indexOf(u8, final, "bcs bool_not_") == null);
    }
}
