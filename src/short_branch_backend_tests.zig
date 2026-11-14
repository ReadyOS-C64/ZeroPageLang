const std = @import("std");
const parser = @import("parser.zig");
const emitter = @import("codegen/tass64/emitter.zig");
const pipeline = @import("codegen/tass64/pipeline.zig");
const a = std.testing.allocator;
const body =
    \\export fn entry(value:u8)u8 { if(value<7) {return 3;} return 9; }
    \\export fn main()void { _=entry(2); }
;
fn labels(text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.endsWith(u8, line, ":") and (std.mem.startsWith(u8, line, "if_") or std.mem.startsWith(u8, line, "for_") or std.mem.startsWith(u8, line, "while_"))) try out.writer.print("{s}\n", .{line});
    }
    return out.toOwnedSlice();
}
test "short branch backend composes after actual allocation under all source policies" {
    for ([_][]const u8{ "", "pub const zeropage_options=.{.zero_page=.{.profile=.kernal,.allocation=.scratch}};", "pub const zeropage_options=.{.zero_page=.{.profile=.kernal,.allocation=.scalars}};" }) |prefix| {
        const source = try std.mem.concat(a, u8, &.{ prefix, "\n", body });
        defer a.free(source);
        const parsed = try parser.parseSource(a, source);
        defer parsed.deinit(a);
        const raw = try emitter.emitProgram(a, parsed.program);
        defer a.free(raw);
        const final = try pipeline.emitProgram(a, parsed.program);
        defer a.free(final);
        try std.testing.expect(std.mem.indexOf(u8, raw, "bcc if_0_then\n    jmp if_0_else") != null);
        try std.testing.expect(std.mem.indexOf(u8, final, "bcs if_0_else\nif_0_then:") != null);
        try std.testing.expect(std.mem.indexOf(u8, final, "jmp if_0_else") == null);
        const old_labels = try labels(raw);
        defer a.free(old_labels);
        const new_labels = try labels(final);
        defer a.free(new_labels);
        // Lifecycle labels may be appended after allocation. Every original
        // source/helper label must remain in its original sequence.
        var old = std.mem.tokenizeScalar(u8, old_labels, '\n');
        var next: usize = 0;
        while (old.next()) |name| {
            const found = std.mem.indexOfPos(u8, new_labels, next, name) orelse return error.MissingOriginalLabel;
            next = found + name.len;
        }
    }
}
test "short branch backend retains existing module placement and inline assembly controls" {
    const module =
        \\pub const zeropage_options=.{.stack=.{.base=0xc800,.size=0x400},.abi=.{.functions=.{.root=.{.frame=.stack}}}};
        \\pub const zeropage_module=.{.id="branch_guard",.abi=1,.exports=.{.root=root},.deps=.{}};
        \\fn root(value:u8)u8{return entry(value);}
    ;
    const placement =
        \\pub const zeropage_options=.{.memory=.{.regions=.{.fixed=.{.addr=0x2000,.size=0x100}},.placements=.{.fixed=.{.region=.fixed,.load=.direct,.functions=.{placed}}}}};
        \\fn placed()u8{return 7;}
    ;
    const assembly = try std.mem.replaceOwned(u8, a, body, "_=entry(2);", "_=entry(2);\nasm {\nnop\n}\n");
    defer a.free(assembly);
    for ([_][]const u8{ module, placement, "" }, 0..) |prefix, index| {
        const source = try std.mem.concat(a, u8, &.{ prefix, "\n", if (index == 2) assembly else body });
        defer a.free(source);
        const parsed = try parser.parseSource(a, source);
        defer parsed.deinit(a);
        const final = try pipeline.emitProgram(a, parsed.program);
        defer a.free(final);
        try std.testing.expect(std.mem.indexOf(u8, final, "    jmp if_0_else\nif_0_then:") != null);
        try std.testing.expect(std.mem.indexOf(u8, final, "bcs if_0_else") == null);
    }
}
