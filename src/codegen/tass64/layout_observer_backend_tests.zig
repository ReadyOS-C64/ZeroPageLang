// R32 actual parser/emitter/pipeline coverage. This file is imported only by tests.
const std = @import("std");
const parser = @import("../../parser.zig");
const emitter = @import("emitter.zig");
const pipeline = @import("pipeline.zig");
const arguments = @import("call_argument_rewrite.zig");
const allocation = @import("zero_page_allocation.zig");
const scalars = @import("zero_page_scalars.zig");
const map = @import("map.zig");
const a = std.testing.allocator;

const settings =
    \\pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scalars } };
;
const same_byte =
    \\fn leaf(value: u8, neighbor: u8) u8 {
    \\    const previous: *u8 = @ptrFromInt(@intFromPtr(&neighbor) - 1);
    \\    previous.* = value;
    \\    return value ^ neighbor;
    \\}
    \\export fn main() void { _ = leaf(0x81, 0x42); }
;
const same_word =
    \\fn leaf(value: u16, neighbor: u16) u16 {
    \\    const previous: *u16 = @ptrFromInt(@intFromPtr(&neighbor) - 2);
    \\    previous.* = value;
    \\    return value ^ neighbor;
    \\}
    \\export fn main() void { _ = leaf(0x81ff, 0x5242); }
;
const separate_observer =
    \\fn leaf(value: u16) u16 { return value ^ 0x8152; }
    \\fn observer() u16 {
    \\    var neighbor: u16 = 0x4281;
    \\    return @intFromPtr(&neighbor) - 1;
    \\}
    \\export fn main() void { _ = leaf(0x81ff); _ = observer(); }
;
const computed_pointer =
    \\fn leaf(value: u16) u16 { return value ^ 0x8152; }
    \\fn callLeaf(location: *volatile u16) u16 { return leaf(location.*); }
    \\fn readAddress(address: u16) u8 {
    \\    const location: *volatile u8 = @ptrFromInt(address);
    \\    return location.*;
    \\}
    \\export fn main() void {
    \\    const location: *volatile u16 = @ptrFromInt(0xc1ff);
    \\    location.* = 0x81ff;
    \\    _ = callLeaf(location);
    \\    _ = readAddress(0xc500);
    \\}
;
const literal_control =
    \\fn leaf(value: u16) u16 { return value ^ 0x8152; }
    \\fn unusedObserver() u16 {
    \\    var neighbor: u16 = 7;
    \\    return @intFromPtr(&neighbor);
    \\}
    \\export fn main() void {
    \\    const location: *volatile u16 = @ptrFromInt(0xc1ff);
    \\    location.* = 0x81ff;
    \\    _ = leaf(location.*);
    \\}
;
const precedence_settings =
    \\pub const zeropage_options = .{
    \\    .zero_page = .{ .profile = .kernal, .allocation = .scalars },
    \\    .stack = .{ .base = 0xc800, .size = 0x100, .zp = .{ .sp = 0x70, .fp = 0x72 } },
    \\    .abi = .{ .functions = .{ .stackLeaf = .{ .frame = .stack } } },
    \\};
;
const precedence_body =
    \\export fn publicLeaf(value: u16) u16 { return value; }
    \\fn addressed(value: u16) u16 { const location: *u16 = &value; return location.*; }
    \\fn stackLeaf(value: u16) u16 { return value; }
    \\fn observer() u16 { var neighbor: u16 = 7; return @intFromPtr(&neighbor); }
    \\export fn main() void {
    \\    _ = publicLeaf(0x81ff);
    \\    _ = addressed(0x5242);
    \\    _ = stackLeaf(0x8134);
    \\    _ = observer();
    \\}
;
const module_source =
    \\pub const zeropage_options = .{
    \\    .zero_page = .{},
    \\    .stack = .{ .base = 0xc800, .size = 0x100 },
    \\    .abi = .{ .functions = .{ .entry = .{ .frame = .stack } } },
    \\};
    \\pub const zeropage_module = .{ .id = "layout_observer", .abi = 1, .exports = .{ .entry = entry }, .deps = .{} };
    \\fn leaf(value: u16) u16 { return value; }
    \\fn entry(value: u16) u16 { return value; }
    \\fn observer() u16 { var neighbor: u16 = 7; return @intFromPtr(&neighbor); }
    \\export fn main() void { _ = leaf(0x5242); _ = entry(0x81ff); _ = observer(); }
;

fn sourceWith(prefix: []const u8, body: []const u8) ![]u8 {
    return std.mem.concat(a, u8, &.{ prefix, "\n", body });
}
fn has(text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("missing layout-observer assembly: {s}\n", .{needle});
        return error.ExpectedLayoutObserverAssembly;
    }
}
fn lacks(text: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, text, needle) == null);
}
fn ordered(text: []const u8, needles: []const []const u8) !void {
    var at: usize = 0;
    for (needles) |needle| {
        const next = std.mem.indexOfPos(u8, text, at, needle) orelse return error.ExpectedInstructionOrder;
        at = next + needle.len;
    }
}
fn marker(assembly: []const u8, label: []const u8, size: u8, reason: []const u8, status: []const u8) !void {
    const text = try std.fmt.allocPrint(a, "; zeropage_zp_parameter label={s} size={d} reason={s} status={s}", .{ label, size, reason, status });
    defer a.free(text);
    try has(assembly, text);
}
fn resident(assembly: []const u8, label: []const u8, size: u8) !void {
    const text = try std.fmt.allocPrint(a, "{s}:\n    {s} 0", .{ label, if (size == 1) ".byte" else ".word" });
    defer a.free(text);
    try has(assembly, text);
    const claim = try std.fmt.allocPrint(a, "; zeropage_zp_claim label={s} ", .{label});
    defer a.free(claim);
    try lacks(assembly, claim);
}
fn functionCode(assembly: []const u8, name: []const u8) ![]const u8 {
    const begin = try std.fmt.allocPrint(a, "{s}:\n", .{name});
    defer a.free(begin);
    const end = try std.fmt.allocPrint(a, "; zeropage_section_end owner=function:{s}", .{name});
    defer a.free(end);
    const start = std.mem.indexOf(u8, assembly, begin) orelse return error.MissingFunction;
    const finish = std.mem.indexOfPos(u8, assembly, start, end) orelse return error.MissingFunctionEnd;
    return assembly[start..finish];
}
fn field(line: []const u8, key: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeAny(u8, line, " \t");
    while (words.next()) |word| if (word.len > key.len and std.mem.startsWith(u8, word, key) and word[key.len] == '=') return word[key.len + 1 ..];
    return null;
}
// Synthetic real-claim labels exercise actual map validation, not geometry or
// emulation. No synthetic ordinary frame addresses or adjacency are asserted.
fn checkedMap(program: @import("../../ast.zig").Program, assembly: []const u8) !std.json.Parsed(std.json.Value) {
    var labels: std.Io.Writer.Allocating = .init(a);
    defer labels.deinit();
    var lines = std.mem.splitScalar(u8, assembly, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "; zeropage_zp_claim ")) continue;
        const address = try std.fmt.parseInt(u16, field(line, "addr").?, 10);
        try labels.writer.print("al {x:0>6} .{s}\n", .{ address, field(line, "label").? });
    }
    if (std.mem.indexOf(u8, assembly, "zeropage_zp_enter:") != null) try labels.writer.writeAll("al 004000 .zeropage_zp_enter\n");
    const bytes = try map.emitProgramJson(a, program, assembly, labels.written(), "layout-observer.prg", 0x0801, 0);
    defer a.free(bytes);
    return std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always });
}
fn mapReason(value: std.json.Value, label: []const u8, reason: []const u8) !void {
    const zp = value.object.get("zero_page").?.object;
    for (zp.get("parameters").?.array.items) |p| {
        if (!std.mem.eql(u8, p.object.get("label").?.string, label)) continue;
        try std.testing.expectEqualStrings(reason, p.object.get("reason").?.string);
        try std.testing.expectEqualStrings("excluded", p.object.get("status").?.string);
        return;
    }
    return error.MissingParameterDecision;
}

test "layout observer backend excludes same-frame neighbor-derived byte and word formals" {
    for ([_]struct { body: []const u8, width: u8 }{ .{ .body = same_byte, .width = 1 }, .{ .body = same_word, .width = 2 } }) |case| {
        const source = try sourceWith(settings, case.body);
        defer a.free(source);
        const parsed = try parser.parseSource(a, source);
        defer parsed.deinit(a);
        const assembly = try pipeline.emitProgram(a, parsed.program);
        defer a.free(assembly);
        try marker(assembly, "leaf_value", case.width, "layout_observer", "excluded");
        try marker(assembly, "leaf_neighbor", case.width, "address_escape", "excluded");
        try resident(assembly, "leaf_value", case.width);
        try resident(assembly, "leaf_neighbor", case.width);
        try lacks(assembly, "kind=parameter benefit=");
        try has(assembly, "sta (zeropage_ptr_tmp),y");
        const json = try checkedMap(parsed.program, assembly);
        defer json.deinit();
        try mapReason(json.value, "leaf_value", "layout_observer");
        try mapReason(json.value, "leaf_neighbor", "address_escape");
    }
}

test "layout observer backend retained observer blocks placement but permits fully proved argument transfer" {
    for ([_][]const u8{ "off", "scratch", "scalars" }) |mode| {
        const prefix = try std.fmt.allocPrint(a, "pub const zeropage_options = .{{ .zero_page = .{{ .profile = .kernal, .allocation = .{s} }} }};", .{mode});
        defer a.free(prefix);
        const source = try sourceWith(prefix, separate_observer);
        defer a.free(source);
        const parsed = try parser.parseSource(a, source);
        defer parsed.deinit(a);
        const before = try emitter.emitProgram(a, parsed.program);
        defer a.free(before);
        const rewritten = try arguments.rewrite(a, parsed.program, before);
        defer a.free(rewritten);
        try ordered(rewritten, &.{ "sta leaf_value\n    stx leaf_value+1\n", "lda leaf_value+1\n", "jsr leaf\n", "jsr observer\n" });
        try lacks(rewritten, "sta zeropage_call_arg_0\n");
        try has(rewritten, "direct_arguments=1 final_words=1");
        const assembly = try pipeline.emitProgram(a, parsed.program);
        defer a.free(assembly);
        try resident(assembly, "leaf_value", 2);
        if (std.mem.eql(u8, mode, "scalars")) try marker(assembly, "leaf_value", 2, "layout_observer", "excluded");
        try has(assembly, "observer:\n");
    }
}

test "layout observer backend nonliteral pointer preserves volatile producer reads and formal writes" {
    const source = try sourceWith(settings, computed_pointer);
    defer a.free(source);
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    const before = try emitter.emitProgram(a, parsed.program);
    defer a.free(before);
    const rewritten = try arguments.rewrite(a, parsed.program, before);
    defer a.free(rewritten);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, try functionCode(before, "callLeaf"), "lda (zeropage_ptr_tmp),y\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, try functionCode(rewritten, "callLeaf"), "lda (zeropage_ptr_tmp),y\n"));
    // The u16 volatile read remains two byte loads in source evaluation order;
    // direct formal writes and the final high reload follow. No numeric
    // adjacency oracle is needed, and parameter placement stays excluded.
    try ordered(rewritten, &.{ "callLeaf:\n", "lda (zeropage_ptr_tmp),y\n", "iny\n", "lda (zeropage_ptr_tmp),y\n", "sta leaf_value\n    stx leaf_value+1\n", "lda leaf_value+1\n", "jsr leaf\n" });
    const assembly = try pipeline.emitProgram(a, parsed.program);
    defer a.free(assembly);
    for ([_][]const u8{ "leaf_value", "callLeaf_location", "readAddress_address" }) |label| {
        try marker(assembly, label, 2, "layout_observer", "excluded");
        try resident(assembly, label, 2);
    }
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, try functionCode(assembly, "callLeaf"), "lda (zeropage_ptr_tmp),y\n"));
    try ordered(assembly, &.{ "jsr callLeaf\n", "jsr readAddress\n" });
    const json = try checkedMap(parsed.program, assembly);
    defer json.deinit();
    try mapReason(json.value, "leaf_value", "layout_observer");
}

test "layout observer backend literal C64 pointers and unreachable observer keep private promotion" {
    const source = try sourceWith(settings, literal_control);
    defer a.free(source);
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    const assembly = try pipeline.emitProgram(a, parsed.program);
    defer a.free(assembly);
    try marker(assembly, "leaf_value", 2, "eligible", "allocated");
    try has(assembly, "leaf_value = address($");
    try lacks(assembly, "unusedObserver:\n");
    try lacks(assembly, "reason=layout_observer");
    const json = try checkedMap(parsed.program, assembly);
    defer json.deinit();
    var found = false;
    for (json.value.object.get("zero_page").?.object.get("claims").?.array.items) |claim| {
        if (std.mem.eql(u8, claim.object.get("label").?.string, "leaf_value")) {
            try std.testing.expectEqualStrings("parameter", claim.object.get("kind").?.string);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "layout observer backend keeps address export and software-stack exclusion precedence" {
    const source = try sourceWith(precedence_settings, precedence_body);
    defer a.free(source);
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    const assembly = try pipeline.emitProgram(a, parsed.program);
    defer a.free(assembly);
    try marker(assembly, "publicLeaf_value", 2, "exported", "excluded");
    try marker(assembly, "addressed_value", 2, "address_escape", "excluded");
    try marker(assembly, "stackLeaf_value", 2, "abi_root", "excluded");
    try resident(assembly, "publicLeaf_value", 2);
    try resident(assembly, "addressed_value", 2);
    const json = try checkedMap(parsed.program, assembly);
    defer json.deinit();
    try mapReason(json.value, "publicLeaf_value", "exported");
    try mapReason(json.value, "addressed_value", "address_escape");
    try mapReason(json.value, "stackLeaf_value", "abi_root");
}

test "layout observer backend module ownership precedes global observation and keeps ABI path" {
    const parsed = try parser.parseSource(a, module_source);
    defer parsed.deinit(a);
    const before = try emitter.emitProgram(a, parsed.program);
    defer a.free(before);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    var split = std.mem.splitScalar(u8, before, '\n');
    while (split.next()) |line| try lines.append(a, line);
    const decisions = try allocation.parameterDecisions(a, parsed.program, lines.items);
    defer scalars.freeDecisions(a, decisions);
    try std.testing.expect(decisions.len >= 2);
    for (decisions) |decision| try std.testing.expectEqualStrings("module_abi", @tagName(decision.reason));
    const rewritten = try arguments.rewrite(a, parsed.program, before);
    defer a.free(rewritten);
    try std.testing.expectEqualStrings(before, rewritten);
    const assembly = try pipeline.emitProgram(a, parsed.program);
    defer a.free(assembly);
    try lacks(assembly, "kind=parameter benefit=");
    try lacks(assembly, "reason=layout_observer");
    try has(assembly, "; zeropage_section_begin owner=function:entry kind=code");
    try has(assembly, "zeropage_stack_");
}
