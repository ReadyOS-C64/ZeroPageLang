const std = @import("std");
const ast = @import("../../ast.zig");
const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");

const Site = struct {
    call: usize,
    ret: usize,
    target: []const u8,
};

fn isStaticEntry(graph: layout.Analysis, program: ast.Program, target: []const u8) bool {
    const node = graph.nodes.items[graph.target(target) orelse return false];
    if (node.zone == .unsectioned) {
        if (std.mem.eql(u8, target, "zeropage_mul16") or
            std.mem.eql(u8, target, "zeropage_shl16") or
            std.mem.eql(u8, target, "zeropage_shr16")) return true;
        for ([_][]const u8{ "zeropage_shl16_const_", "zeropage_shr16_const_" }) |prefix| {
            if (!std.mem.startsWith(u8, target, prefix)) continue;
            const suffix = target[prefix.len..];
            if (suffix.len == 0) return false;
            for (suffix) |c| if (!std.ascii.isDigit(c)) return false;
            return true;
        }
        return false;
    }
    if (node.zone != .code or node.index == 0) return false;
    const function = program.findFunction(target) orelse return false;
    if (function.exported or std.mem.eql(u8, target, "main")) return false;
    const marker = std.mem.trim(u8, graph.raw.items[node.index - 1], " \t\r");
    return std.mem.eql(u8, storage.sectionOwner(marker, "code") orelse return false, target);
}

pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.default_frame != .static or options.abi.functions.len != 0 or
        std.mem.indexOf(u8, assembly, "    jsr ") == null or
        std.mem.indexOf(u8, assembly, "zeropage_test6502_expect_sp_") != null or
        std.mem.indexOf(u8, assembly, "zeropage_test6502_expect_stack_") != null) return null;
    for (program.functions) |function| {
        if (function.exported and !std.mem.eql(u8, function.name, "main")) return null;
    }

    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    const nodes = graph.nodes.items;
    if (!graph.complete or nodes.len < 2) return null;
    var sites: std.ArrayList(Site) = .empty;
    defer sites.deinit(a);
    for (nodes, 0..) |node, index| {
        const inst = machine.Instruction.parse(node.text) orelse continue;
        // A callee would see a different hardware SP after reusing the
        // caller's return address. Reject explicit stack-pointer operations.
        if (inst.op == .tsx or inst.op == .txs) return null;
        if (inst.op != .jsr or inst.operand != .direct or inst.operand.direct.offset != 0 or
            node.zone != .code or index + 1 == nodes.len) continue;
        const ret = nodes[index + 1];
        if (ret.scope != node.scope or !std.mem.eql(u8, ret.text, "rts")) continue;
        const target = inst.operand.direct.name;
        if (isStaticEntry(graph, program, target)) try sites.append(a, .{ .call = node.index, .ret = ret.index, .target = target });
    }
    if (sites.items.len == 0) return null;
    const proof = (try image.tailCallLayout(a, graph, program)) orelse return null;

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var first: usize = 0;
    const lines = graph.raw.items;
    for (sites.items) |site| {
        for (lines[first..site.call]) |line| try out.writer.print("{s}\n", .{line});
        try out.writer.print("    jmp {s}\n", .{site.target});
        for (lines[site.call + 1 .. site.ret]) |line| try out.writer.print("{s}\n", .{line});
        if (site.ret < proof.padding_end) try out.writer.print("{s}\n", .{lines[site.ret]});
        first = site.ret + 1;
    }
    // Keep the original final-newline convention.
    if (first < lines.len) {
        try out.writer.writeAll(lines[first]);
        for (lines[first + 1 ..]) |line| try out.writer.print("\n{s}", .{line});
    } else if (out.written().len != 0) {
        out.shrinkRetainingCapacity(out.written().len - 1);
    }
    return try out.toOwnedSlice();
}

const parser = @import("../../parser.zig");
const a_test = std.testing.allocator;
const test_program =
    \\fn leaf(value: u8) u8 { return value; }
    \\fn wrapper(value: u8) u8 { return leaf(value); }
    \\export fn main() void { _ = wrapper(4); }
;
const test_header = "* = $2000\n; zeropage_section_begin owner=function:main kind=code\nmain:\n" ++
    "    jsr wrapper\nzeropage_test_exit:\n    rts\n; zeropage_section_end owner=function:main kind=code\n" ++
    "; zeropage_section_begin owner=function:wrapper kind=code\nwrapper:\n";
const test_leaf = "; zeropage_section_end owner=function:wrapper kind=code\n" ++
    "; zeropage_section_begin owner=function:leaf kind=code\nleaf:\n    lda #4\n    rts\n" ++
    "; zeropage_section_end owner=function:leaf kind=code\n";
const test_call = "    jsr leaf\n    ; return the callee result\n    rts\n";
const test_padding =
    "zeropage_mul16:\n    lda #0\n    sta zeropage_mul_result\n    sta zeropage_mul_result+1\n    ldx #16\n" ++
    "    ; The 36-byte loop's branch PC must not cross the page either.\n" ++
    ".if (* & $ff) > $db\n    jmp zeropage_mul16_loop\n.if (* & $ff) > $db\n" ++
    "    .fill (($100 - (* & $ff)) & $ff),0\n.endif\n.endif\n" ++
    "zeropage_mul16_loop:\n    rts\n" ++
    "; zeropage_section_begin owner=compiler kind=scratch\nzeropage_mul_result:\n    .word 0\n" ++
    "; zeropage_section_end owner=compiler kind=scratch\n";

test "static tail calls reuse the return address and preserve the executable exit hook" {
    const parsed = try parser.parseSource(a_test, test_program);
    defer parsed.deinit(a_test);
    const result = (try rewrite(a_test, parsed.program, test_header ++ test_call ++ test_leaf)) orelse
        return error.ExpectedTailCall;
    defer a_test.free(result);
    try std.testing.expectEqualStrings(test_header ++ "    jmp leaf\n    ; return the callee result\n" ++ test_leaf, result);
}

test "static tail calls retain widths before canonical multiply padding" {
    const parsed = try parser.parseSource(a_test, test_program);
    defer parsed.deinit(a_test);
    const result = (try rewrite(a_test, parsed.program, test_header ++ test_call ++ test_leaf ++ test_padding)) orelse
        return error.ExpectedTailCall;
    defer a_test.free(result);
    try std.testing.expectEqualStrings(test_header ++ "    jmp leaf\n    ; return the callee result\n    rts\n" ++
        test_leaf ++ test_padding, result);
    const wrong = try std.mem.replaceOwned(u8, a_test, test_padding, " > $db", " > $dc");
    defer a_test.free(wrong);
    const text = try std.mem.concat(a_test, u8, &.{ test_header, test_call, test_leaf, wrong });
    defer a_test.free(text);
    try std.testing.expect((try rewrite(a_test, parsed.program, text)) == null);
}

test "static tail calls keep alternate entries and code that observes stack state" {
    const parsed = try parser.parseSource(a_test, test_program);
    defer parsed.deinit(a_test);
    for ([_][]const u8{
        test_header ++ "    jsr leaf\nentry:\n    rts\n" ++ test_leaf,
        test_header ++ "    tsx\n" ++ test_call ++ test_leaf,
        test_header ++ "    txs\n" ++ test_call ++ test_leaf,
        test_header ++ "    lda $01ff\n" ++ test_call ++ test_leaf,
        test_header ++ "    jsr $ffd2\n    rts\n" ++ test_leaf,
    }) |text| try std.testing.expect((try rewrite(a_test, parsed.program, text)) == null);
}
