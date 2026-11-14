const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const pipe = @import("codegen/tass64/pipeline.zig");
const pass = @import("codegen/tass64/unreachable_code.zig");
const layout = @import("codegen/tass64/branch_layout.zig");
const branches = @import("codegen/tass64/short_branches.zig");
const machine = @import("codegen/tass64/instruction.zig");
const a = std.testing.allocator;
const body = "fn leaf(value:u16)u16{if(value<256){return 3;}return 9;}export fn entry(value:u8)u8{if(value<7){return 3;}return 9;}export fn main()void{_=entry(2);_=leaf(257);}";
test "relative footprints include the wrong-page read and reject unknown layout" {
    const prefix = "* = $2000\nfirst:\n    .byte 1\n";
    const room = "    .word 0\n" ** 128;
    const tail = "later:\n    .byte 2\n";
    var graph = try layout.parseForSize(a, prefix ++ room ++ tail);
    defer graph.deinit(a);
    try std.testing.expect(pass.footprintsDisjoint(graph, .{ .label = "first" }, pass.Footprint.indexed("later", 8, true)));
    try std.testing.expect(!pass.footprintsDisjoint(graph, .{ .label = "first", .last = 2 }, pass.Footprint.indexed("later", 8, true)));
    try std.testing.expect(pass.footprintsDisjoint(graph, .{ .label = "first", .first = 2, .last = 2 }, .{ .label = "first" }));
    var remapped = try layout.parseForSize(a, prefix ++ "* = $3000\n" ++ room ++ tail);
    defer remapped.deinit(a);
    try std.testing.expect(!pass.footprintsDisjoint(remapped, .{ .label = "first" }, .{ .label = "later" }));
}
fn selected(text: []const u8, sections: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var split = std.mem.splitScalar(u8, text, '\n');
    while (split.next()) |raw| {
        const s = std.mem.trim(u8, raw, " \t\r");
        if ((sections and std.mem.startsWith(u8, s, "; zeropage_section_")) or (!sections and std.mem.endsWith(u8, s, ":"))) try out.writer.print("{s}\n", .{s});
    }
    return out.toOwnedSlice();
}
fn onlyRemovedInstructions(before: []const u8, after: []const u8, count: usize) !void {
    var old = std.mem.splitScalar(u8, before, '\n');
    var new = std.mem.splitScalar(u8, after, '\n');
    var next = new.next();
    var removed: usize = 0;
    while (old.next()) |line| {
        if (next != null and std.mem.eql(u8, line, next.?)) {
            next = new.next();
            continue;
        }
        try std.testing.expect(machine.Instruction.parse(std.mem.trim(u8, line, " \t\r")) != null);
        removed += 1;
    }
    try std.testing.expect(next == null);
    try std.testing.expectEqual(count, removed);
}
test "unreachable backend composes actual pre-layout emission under all existing allocation policies" {
    for ([_][]const u8{ "", "pub const zeropage_options=.{.zero_page=.{.profile=.kernal,.allocation=.off}};", "pub const zeropage_options=.{.zero_page=.{.profile=.kernal,.allocation=.scratch}};", "pub const zeropage_options=.{.zero_page=.{.profile=.kernal,.allocation=.scalars}};" }) |prefix| {
        const source = try std.mem.concat(a, u8, &.{ prefix, body });
        defer a.free(source);
        const p = try parser.parseSource(a, source);
        defer p.deinit(a);
        const before = try pipe.emitBeforeUnreachableWithOptions(a, p.program, .{});
        defer a.free(before);
        if (std.mem.indexOf(u8, prefix, ".scalars") != null) try std.testing.expect(std.mem.indexOf(u8, before, "zeropage_zp_enter:") != null);
        const rewritten = try pass.rewriteProgram(a, before, p.program);
        defer a.free(rewritten.assembly);
        try std.testing.expect(rewritten.stats.rts_removed > 0);
        try std.testing.expect(rewritten.stats.jumps_removed > 0);
        try onlyRemovedInstructions(before, rewritten.assembly, rewritten.stats.instructions_removed);
        for ([_]bool{ false, true }) |sections| {
            const old = try selected(before, sections);
            defer a.free(old);
            const new = try selected(rewritten.assembly, sections);
            defer a.free(new);
            try std.testing.expectEqualStrings(old, new);
        }
        const expected = try branches.rewrite(a, rewritten.assembly);
        defer a.free(expected.assembly);
        const actual = try pipe.emitProgram(a, p.program);
        defer a.free(actual);
        try std.testing.expectEqualStrings(expected.assembly, actual);
    }
}
test "unreachable backend preserves inline ASM modules loaders and explicit placements" {
    const module = "pub const zeropage_options=.{.stack=.{.base=0xc800,.size=0x400},.abi=.{.functions=.{.root=.{.frame=.stack}}}};pub const zeropage_module=.{.id=\"dead_guard\",.abi=1,.exports=.{.root=root},.deps=.{}};fn root(value:u8)u8{return entry(value);}";
    const placement = "pub const zeropage_options=.{.memory=.{.regions=.{.fixed=.{.addr=0x2000,.size=0x100}},.placements=.{.fixed=.{.region=.fixed,.load=.direct,.functions=.{placed}}}}};fn placed()u8{return 7;}";
    const loader = "pub const zeropage_options=.{.modules=.{.load_window=.{.addr=0xc000,.size=0x800},.reu_cache=.{.addr=0x20000,.size=0x10000}}};";
    const assembly = try std.mem.replaceOwned(u8, a, body, "_=entry(2);", "_=entry(2);\nasm {\nnop\n}\n");
    defer a.free(assembly);
    for ([_][]const u8{ module, placement, loader, "" }, 0..) |prefix, i| {
        const source = try std.mem.concat(a, u8, &.{ prefix, if (i == 3) assembly else body });
        defer a.free(source);
        const p = try parser.parseSource(a, source);
        defer p.deinit(a);
        const before = try pipe.emitBeforeUnreachableWithOptions(a, p.program, .{});
        defer a.free(before);
        const final = try pipe.emitProgram(a, p.program);
        defer a.free(final);
        try std.testing.expectEqualStrings(before, final);
    }
}
fn oom(a_fail: std.mem.Allocator, program: ast.Program) !void {
    const final = pipe.emitProgram(a_fail, program) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    defer a_fail.free(final);
}
test "unreachable backend preserves semantic dry validation and allocation failure cleanup" {
    const invalid = try parser.parseSource(a, "fn dead()void{_=missing();}export fn main()void{}");
    defer invalid.deinit(a);
    try std.testing.expectError(error.UnknownFunction, pipe.emitProgram(a, invalid.program));
    const p = try parser.parseSource(a, body);
    defer p.deinit(a);
    try std.testing.checkAllAllocationFailures(a, oom, .{p.program});
}

test "unreachable backend accounts for raw pointer conversions lowered to immediate bytes" {
    const template = "const c64=@import(\"c64\");fn observe()u8{const p:*volatile u8=@ptrFromInt(ADDRESS);return p.*;}export fn main()void{c64.vic.border=observe();}";
    for ([_][]const u8{ "0x081c", "0xc100" }, 0..) |address, index| {
        const source = try std.mem.replaceOwned(u8, a, template, "ADDRESS", address);
        defer a.free(source);
        const p = try parser.parseSource(a, source);
        defer p.deinit(a);
        const before = try pipe.emitBeforeUnreachableWithOptions(a, p.program, .{});
        defer a.free(before);
        const actual = try pipe.emitProgram(a, p.program);
        defer a.free(actual);
        if (index == 0) {
            try std.testing.expectEqualStrings(before, actual);
        } else {
            try onlyRemovedInstructions(before, actual, 1);
        }
    }
}
