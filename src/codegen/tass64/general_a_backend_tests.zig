const std = @import("std");
const parser = @import("../../parser.zig");
const emitter = @import("emitter.zig");
const arguments = @import("call_argument_rewrite.zig");
const optimizer = @import("optimizer.zig");
const pointers = @import("pointer_add_forwarding.zig");
const x_values = @import("x_value_forwarding.zig");
const branch = @import("branch_a_forwarding.zig");
const booleans = @import("boolean_materialization.zig");
const cfg = @import("cfg_dead_values.zig");
const pipeline = @import("pipeline.zig");
const a = std.testing.allocator;
const direct =
    \\fn choose(value: u8, other: u8) u8 { if (value == other) { return value; } return 42; }
    \\export fn main() void { _ = choose(0x81,0x81); _ = choose(0,1); }
;
const chain =
    \\fn choose(value: u8, other: u8, third: u8) u8 {
    \\    if (value != 0 and value == other and value == third) { return value; }
    \\    return 42;
    \\}
    \\export fn main() void { _ = choose(0x81,0x81,0x81); _ = choose(0,1,2); }
;
fn text(prefix: []const u8, body: []const u8) ![]u8 {
    return std.mem.concat(a, u8, &.{ prefix, "\n", body });
}
fn prepared(program: @import("../../ast.zig").Program) ![]u8 {
    const raw = try emitter.emitProgram(a, program);
    defer a.free(raw);
    const copied = try arguments.rewrite(a, program, raw);
    var current = try optimizer.finalizeAssemblyWithOptions(a, copied, .{
        .reuse_pointer_bases = program.zeropage_module == null,
        .cleanup_values = program.zeropage_module == null,
        .hoist_loop_pointers = program.zeropage_module == null,
        .reduce_loop_ranges = program.zeropage_module == null,
    });
    errdefer a.free(current);
    if (program.zeropage_module == null and program.zeropage_options.memory.placements.len == 0) {
        const address = try pointers.rewriteWithDirectBases(a, program, current);
        a.free(current);
        current = address.assembly;
        const forwarded = try x_values.rewrite(a, current);
        a.free(current);
        current = forwarded.assembly;
        const legacy = try branch.rewrite(a, current);
        a.free(current);
        current = legacy.assembly;
        const folded = try booleans.rewrite(a, current);
        a.free(current);
        current = folded.assembly;
        const cleaned = try cfg.rewrite(a, current);
        a.free(current);
        current = cleaned.assembly;
    }
    return current;
}
fn has(s: []const u8, n: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, s, n) != null);
}
fn function(s: []const u8, name: []const u8) ![]const u8 {
    const begin = try std.fmt.allocPrint(a, "{s}:\n", .{name});
    defer a.free(begin);
    const end = try std.fmt.allocPrint(a, "; zeropage_section_end owner=function:{s}", .{name});
    defer a.free(end);
    const start = std.mem.indexOf(u8, s, begin) orelse return error.FunctionMissing;
    const finish = std.mem.indexOfPos(u8, s, start, end) orelse return error.FunctionEndMissing;
    return s[start..finish];
}
fn positive(body: []const u8, minimum: usize) !void {
    for ([_][]const u8{ "", "pub const zeropage_options=.{.zero_page=.{.profile=.kernal,.allocation=.scratch}};", "pub const zeropage_options=.{.zero_page=.{.profile=.kernal,.allocation=.scalars}};" }) |prefix| {
        const source = try text(prefix, body);
        defer a.free(source);
        const parsed = try parser.parseSource(a, source);
        defer parsed.deinit(a);
        const before = try prepared(parsed.program);
        defer a.free(before);
        const result = if (@hasDecl(branch, "rewriteOrdinary")) try branch.rewriteOrdinary(a, before) else branch.Result{ .assembly = try a.dupe(u8, before), .stats = .{} };
        defer a.free(result.assembly);
        try std.testing.expect(result.stats.reloads_replaced >= minimum);
        const final = try pipeline.emitProgram(a, parsed.program);
        defer a.free(final);
        // A byte return exposes N/Z at RTS; its exact restoring identity stays.
        try has(try function(final, "choose"), "    ora #0\n    rts");
    }
}
test "ordinary A backend reuses value across direct RAM comparison with live return flags" {
    try positive(direct, 1);
}
test "ordinary A backend forward predicate chain is rooted and restores final return flags" {
    try positive(chain, 3);
}
test "ordinary A backend volatile reads and retained source ASM stay on original path" {
    const volatile_body =
        \\fn read(pointer: *volatile u8) u8 { if (pointer.* != 0) { return pointer.*; } return 42; }
        \\export fn main() void { const pointer: *volatile u8 = @ptrFromInt(0xdc04); _ = read(pointer); }
    ;
    const asm_body =
        \\fn choose(value: u8, other: u8) u8 { if (value == other) { return value; } return 42; }
        \\export fn main() void {
        \\    _ = choose(0x81,0x81);
        \\    asm {
        \\        nop
        \\    }
        \\}
    ;
    for ([_][]const u8{ volatile_body, asm_body }) |body| {
        const parsed = try parser.parseSource(a, body);
        defer parsed.deinit(a);
        const before = try prepared(parsed.program);
        defer a.free(before);
        const result = if (@hasDecl(branch, "rewriteOrdinary")) try branch.rewriteOrdinary(a, before) else branch.Result{ .assembly = try a.dupe(u8, before), .stats = .{} };
        defer a.free(result.assembly);
        try std.testing.expectEqual(@as(usize, 0), result.stats.reloads_replaced);
        try std.testing.expectEqualStrings(before, result.assembly);
        const final = try pipeline.emitProgram(a, parsed.program);
        defer a.free(final);
        if (std.mem.eql(u8, body, volatile_body)) try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, try function(final, "read"), "lda (zeropage_ptr_tmp),y\n"));
    }
}
test "ordinary A backend module and fixed placement retain final value reload" {
    const module_prefix =
        \\pub const zeropage_options=.{.stack=.{.base=0xc800,.size=0x400},.abi=.{.functions=.{.entry=.{.frame=.stack}}}};
        \\pub const zeropage_module=.{.id="ordinary_a_guard",.abi=1,.exports=.{.entry=entry},.deps=.{}};
        \\fn entry(value:u8)u8{return value;}
    ;
    const placement_prefix =
        \\pub const zeropage_options=.{.memory=.{.regions=.{.fixed=.{.addr=0x2000,.size=0x100}},.placements=.{.fixed=.{.region=.fixed,.load=.direct,.functions=.{placed}}}}};
        \\fn placed()u8{return 7;}
    ;
    for ([_][]const u8{ module_prefix, placement_prefix }) |prefix| {
        const source = try text(prefix, direct);
        defer a.free(source);
        const parsed = try parser.parseSource(a, source);
        defer parsed.deinit(a);
        const final = try pipeline.emitProgram(a, parsed.program);
        defer a.free(final);
        try has(try function(final, "choose"), "    lda choose_value\n    rts");
    }
}
