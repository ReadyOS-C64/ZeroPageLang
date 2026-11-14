const std = @import("std");
const ast = @import("../../ast.zig");
const cfg = @import("cfg_dead_values.zig");
const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const literal_io = @import("literal_pointer_io.zig");
const machine = @import("instruction.zig");

const packet_len = 7;
const Edit = struct {
    start: usize,
    base: u16,
    set_y: bool,
    refresh_nz: bool,
};

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn same(line: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, trim(line), expected);
}

fn fixedBase(lines: []const []const u8) ?u16 {
    if (lines.len < packet_len or !same(lines[0], "ldy #0") or
        !same(lines[2], "pha") or !same(lines[3], "iny") or
        !same(lines[4], trim(lines[1])) or !same(lines[5], "tax") or !same(lines[6], "pla")) return null;
    const first_load = trim(lines[1]);
    if (!std.mem.startsWith(u8, first_load, "lda $")) return null;
    const operand = layout.literalIndex(first_load) orelse return null;
    return if (operand.register == machine.y) operand.address else null;
}

/// Load the low byte into A and the high byte directly into X. A crossing
/// high byte still uses absolute,Y so the NMOS dummy read is preserved.
pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.default_frame != .static or options.abi.functions.len != 0 or
        std.mem.indexOf(u8, assembly, "    ldy #0\n    lda $") == null or
        std.mem.indexOf(u8, assembly, "    pha\n    iny\n    lda $") == null or
        std.mem.indexOf(u8, assembly, "zeropage_test6502_expect_stack_") != null) return null;
    for (program.functions) |function| {
        if (function.exported and !std.mem.eql(u8, function.name, "main")) return null;
    }

    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    const upper = (try image.residentLayoutUpperBound(a, assembly)) orelse return null;
    const resident: literal_io.Range = .{ .start = options.image.load_addr, .end = upper };
    const lines = graph.raw.items;
    var candidates: std.ArrayList(Edit) = .empty;
    defer candidates.deinit(a);
    for (graph.nodes.items) |node| {
        if (node.zone != .code or !same(node.text, "ldy #0")) continue;
        const base = fixedBase(lines[node.index..]) orelse continue;
        if (resident.external(base, 1)) try candidates.append(a, .{
            .start = node.index,
            .base = base,
            .set_y = true,
            .refresh_nz = true,
        });
    }
    if (candidates.items.len == 0 or !try image.permitsPrivateStackRewrite(a, graph, program)) return null;

    var query = try cfg.OutputQuery.init(a, assembly);
    defer query.deinit();
    var i = candidates.items.len;
    while (i > 0) {
        i -= 1;
        const edit = &candidates.items[i];
        const pull = edit.start + packet_len - 1;
        edit.set_y = edit.base & 255 == 255 or !try query.deadAfterLine(pull, machine.y);
        edit.refresh_nz = !try query.deadAfterLine(pull, machine.nz);
        // An earlier edit cannot rely on the original kills in this packet.
        query.closeEntry(edit.start);
    }

    var output: std.Io.Writer.Allocating = .init(a);
    errdefer output.deinit();
    const writer = &output.writer;
    var copied: usize = 0;
    for (candidates.items) |edit| {
        for (lines[copied..edit.start]) |line| try writer.print("{s}\n", .{line});
        if (edit.set_y) try writer.writeAll("    ldy #1\n");
        try writer.print("    lda ${x:0>4}\n", .{edit.base});
        if (edit.base & 255 == 255) {
            try writer.print("    ldx ${x:0>4},y\n", .{edit.base});
        } else {
            try writer.print("    ldx ${x:0>4}\n", .{edit.base + 1});
        }
        if (edit.refresh_nz) try writer.writeAll("    ora #0\n");
        copied = edit.start + packet_len;
    }
    for (lines[copied..], copied..) |line, index| {
        try writer.writeAll(line);
        if (index + 1 < lines.len) try writer.writeByte('\n');
    }
    return try output.toOwnedSlice();
}

const parser = @import("../../parser.zig");
const test_allocator = std.testing.allocator;
const test_header = "* = $0801\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
const test_end = "    rts\n; zeropage_section_end owner=function:main kind=code\n";
const test_packet = "    ldy #0\n    lda $c100,y\n    pha\n    iny\n    lda $c100,y\n    tax\n    pla\n";
const test_kills = "    sta $c300\n    stx $c301\n    lda #8\n    tay\n";

test "fixed word loads keep Y and low-byte flags only when live" {
    const parsed = try parser.parseSource(test_allocator, "export fn main() void {}");
    defer parsed.deinit(test_allocator);
    const dead = (try rewrite(test_allocator, parsed.program, test_header ++ test_packet ++ test_kills ++ test_end)) orelse
        return error.ExpectedFixedWordLoad;
    defer test_allocator.free(dead);
    try std.testing.expectEqualStrings(test_header ++ "    lda $c100\n    ldx $c101\n" ++ test_kills ++ test_end, dead);
    const live = (try rewrite(test_allocator, parsed.program, test_header ++ test_packet ++ test_end)) orelse
        return error.ExpectedFixedWordLoad;
    defer test_allocator.free(live);
    try std.testing.expectEqualStrings(test_header ++ "    ldy #1\n    lda $c100\n    ldx $c101\n    ora #0\n" ++ test_end, live);
}

test "fixed word loads keep the page-crossing read indexed" {
    const parsed = try parser.parseSource(test_allocator, "export fn main() void {}");
    defer parsed.deinit(test_allocator);
    const packet = "    ldy #0\n    lda $c1ff,y\n    pha\n    iny\n    lda $c1ff,y\n    tax\n    pla\n";
    const result = (try rewrite(test_allocator, parsed.program, test_header ++ packet ++ test_kills ++ test_end)) orelse
        return error.ExpectedFixedWordLoad;
    defer test_allocator.free(result);
    try std.testing.expectEqualStrings(test_header ++ "    ldy #1\n    lda $c1ff\n    ldx $c1ff,y\n" ++ test_kills ++ test_end, result);
}

test "fixed word loads keep alternate entries and physical stack observers" {
    const parsed = try parser.parseSource(test_allocator, "export fn main() void {}");
    defer parsed.deinit(test_allocator);
    const alternate = "    ldy #0\n    lda $c100,y\nalternate:\n    pha\n    iny\n    lda $c100,y\n    tax\n    pla\n";
    for ([_][]const u8{
        test_header ++ alternate ++ test_kills ++ test_end,
        test_header ++ test_packet ++ "    lda $01ff\n" ++ test_kills ++ test_end,
        test_header ++ test_packet ++ test_end ++ "zeropage_test6502_expect_stack_u8_0001_0000_0000:\n    rts\n",
        test_header ++ test_packet ++ test_end ++ ".if (* & $ff) > $db\n.fill 1,0\n.endif\n",
    }) |input| try std.testing.expect((try rewrite(test_allocator, parsed.program, input)) == null);
}
