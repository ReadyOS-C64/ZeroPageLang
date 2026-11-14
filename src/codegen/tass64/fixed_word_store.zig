const std = @import("std");
const ast = @import("../../ast.zig");

const cfg = @import("cfg_dead_values.zig");
const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const literal_io = @import("literal_pointer_io.zig");
const machine = @import("instruction.zig");

const packet_len = 3;
const Edit = struct { start: usize, base: u16, set_y: bool };

fn supportsStandalone(program: ast.Program) bool {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.default_frame != .static or options.abi.functions.len != 0) return false;
    for (program.functions) |function| {
        if (function.exported and !std.mem.eql(u8, function.name, "main")) return false;
    }
    return true;
}

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn indexedStoreBase(line: []const u8) ?u16 {
    const store = trim(line);
    if (!std.mem.startsWith(u8, store, "sta $")) return null;
    const indexed = layout.literalIndex(store) orelse return null;
    if (indexed.register != machine.y) return null;
    return indexed.address;
}

fn fixedBase(lines: []const []const u8) ?u16 {
    if (lines.len < packet_len or !std.mem.eql(u8, trim(lines[2]), "iny")) return null;
    const base = indexedStoreBase(lines[1]) orelse return null;
    return if (base & 255 != 0) base else null;
}

fn reachingY(value: ?u8, inst: machine.Instruction, text: []const u8) ?u8 {
    if (inst.op == .ldy and inst.operand == .immediate) {
        const immediate = machine.integer(inst.operand.immediate) orelse return null;
        return std.math.cast(u8, immediate);
    }
    if (inst.operand == .none) {
        if (inst.op == .iny) return (value orelse return null) +% 1;
        if (inst.op == .dey) return (value orelse return null) -% 1;
    }
    const effects = inst.effects();
    if (effects.writes & machine.y != 0) return null;
    if (effects.barrier and layout.literalIndex(text) == null) return null;
    return value;
}

/// Use the final index for both bytes. For the low store, base-1 stays
/// on the same page so both the target and the NMOS dummy read match.
pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (!supportsStandalone(program) or
        std.mem.indexOf(u8, assembly, "    ldy #0\n    sta $") == null) return null;
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    const upper = (try image.residentLayoutUpperBound(a, assembly)) orelse return null;
    const resident: literal_io.Range = .{ .start = options.image.load_addr, .end = upper };
    const lines = graph.raw.items;
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(a);
    var value_y: ?u8 = null;
    var scope: usize = 0;
    for (graph.nodes.items) |node| {
        if (scope != node.scope) {
            scope = node.scope;
            value_y = null;
        }
        if (node.zone != .code) continue;
        const inst = machine.Instruction.parse(node.text) orelse {
            value_y = null; // including all labels and alternate entries
            continue;
        };
        if (std.mem.eql(u8, node.text, "ldy #0")) {
            if (fixedBase(lines[node.index..])) |base| {
                if (resident.external(base - 1, 1)) try edits.append(a, .{
                    .start = node.index,
                    .base = base,
                    .set_y = value_y != 1,
                });
            }
        }
        value_y = reachingY(value_y, inst, node.text);
    }
    if (edits.items.len == 0 or !try image.permitsLocalShrink(a, graph, program)) return null;

    var query = try cfg.OutputQuery.initWithLiteralIndex(a, assembly);
    defer query.deinit();
    var i = edits.items.len;
    while (i > 0) {
        i -= 1;
        const edit = &edits.items[i];
        const increment = edit.start + packet_len - 1;
        if (!edit.set_y) edit.set_y = !try query.deadAfterLine(increment, machine.nz);
        query.markRemoved(increment);
        // An earlier candidate can use the flags kill only when the
        // replacement still emits LDY. Y itself remains one at exit.
        if (!edit.set_y) query.markRemoved(edit.start);
    }

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var copied: usize = 0;
    for (edits.items) |edit| {
        for (lines[copied..edit.start]) |line| try out.writer.print("{s}\n", .{line});
        if (edit.set_y) try out.writer.writeAll("    ldy #1\n");
        try out.writer.print("    sta ${x:0>4},y\n", .{edit.base - 1});
        copied = edit.start + packet_len;
    }
    for (lines[copied..], copied..) |line, index| {
        try out.writer.writeAll(line);
        if (index + 1 < lines.len) try out.writer.writeByte('\n');
    }
    return try out.toOwnedSlice();
}

const ShiftStores = struct {
    load_y: usize,
    high_store: usize,
    low_address: u16,
    selected: bool = false,
};

fn shiftStoresAt(lines: []const []const u8, start: usize, resident: literal_io.Range) ?ShiftStores {
    const span = lines[start..];
    if (span.len < 6 or !std.mem.eql(u8, trim(span[0]), "asl") or
        !std.mem.eql(u8, trim(span[1]), "ldy #1") or !std.mem.eql(u8, trim(span[3]), "txa") or
        !std.mem.eql(u8, trim(span[4]), "rol")) return null;
    const high_index: usize = if (std.mem.startsWith(u8, trim(span[5]), "; zeropage_inline_end function=")) 6 else 5;
    if (high_index >= span.len) return null;
    const low = indexedStoreBase(span[2]) orelse return null;
    const high = indexedStoreBase(span[high_index]) orelse return null;
    // Each bound covers the effective address and the NMOS indexed-store
    // dummy address, including the old-page read when adding Y crosses.
    if (@as(u32, low) + 1 != high or !resident.external(low, 1) or !resident.external(high, 1)) return null;
    return .{ .load_y = start + 1, .high_store = start + high_index, .low_address = low + 1 };
}

/// The two writes stay in order and TXA overwrites LDY's N/Z before any
/// consumer. Elide Y only if every subsequent path kills it before use.
pub fn rewriteShiftStores(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    if (!supportsStandalone(program) or
        std.mem.indexOf(u8, assembly, "    asl\n    ldy #1\n    sta $") == null) return null;
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    const upper = (try image.residentLayoutUpperBound(a, assembly)) orelse return null;
    const resident: literal_io.Range = .{ .start = program.zeropage_options.image.load_addr, .end = upper };
    const lines = graph.raw.items;
    var edits: std.ArrayList(ShiftStores) = .empty;
    defer edits.deinit(a);
    for (graph.nodes.items) |node| {
        if (node.zone != .code or !std.mem.eql(u8, node.text, "asl")) continue;
        if (shiftStoresAt(lines, node.index, resident)) |edit| try edits.append(a, edit);
    }
    if (edits.items.len == 0 or !try image.permitsLocalShrink(a, graph, program)) return null;

    var query = try cfg.OutputQuery.initWithLiteralIndex(a, assembly);
    defer query.deinit();
    // A whole packet either kills incoming Y before either use or has no Y
    // effects. Model the second case for every candidate, including on loops,
    // so no edit can depend on a Y kill that another edit removes.
    for (edits.items) |edit| {
        query.markRemoved(edit.load_y);
        query.markRemoved(edit.load_y + 1);
        query.markRemoved(edit.high_store);
    }

    var selected = false;
    for (edits.items) |*edit| {
        edit.selected = try query.deadAfterLine(edit.high_store, machine.y);
        selected = selected or edit.selected;
    }
    if (!selected) return null;
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var copied: usize = 0;
    for (edits.items) |edit| {
        if (!edit.selected) continue;
        for (lines[copied..edit.load_y]) |line| try out.writer.print("{s}\n", .{line});
        try out.writer.print("    sta ${x:0>4}\n", .{edit.low_address});
        for (lines[edit.load_y + 2 .. edit.high_store]) |line| try out.writer.print("{s}\n", .{line});
        try out.writer.print("    sta ${x:0>4}\n", .{edit.low_address + 1});
        copied = edit.high_store + 1;
    }
    for (lines[copied..], copied..) |line, index| {
        try out.writer.writeAll(line);
        if (index + 1 < lines.len) try out.writer.writeByte('\n');
    }
    return try out.toOwnedSlice();
}

/// An absolute store keeps the effective write and leaves the same registers
/// and flags. The eliminated NMOS dummy read must stay in ordinary RAM.
pub fn rewriteKnownIndex(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    if (!supportsStandalone(program) or std.mem.indexOf(u8, assembly, "    sta $") == null or
        std.mem.indexOf(u8, assembly, "    ldy #") == null) return null;
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    const upper = (try image.residentLayoutUpperBound(a, assembly)) orelse return null;
    const resident: literal_io.Range = .{ .start = program.zeropage_options.image.load_addr, .end = upper };
    const lines = graph.raw.items;
    const Store = struct { line: usize, address: u16 };
    var stores: std.ArrayList(Store) = .empty;
    defer stores.deinit(a);
    var value_y: ?u8 = null;
    var scope: usize = 0;
    for (graph.nodes.items) |node| {
        if (node.zone != .code or scope != node.scope) value_y = null;
        scope = node.scope;
        if (node.zone != .code) continue;
        const inst = machine.Instruction.parse(node.text) orelse {
            value_y = null;
            continue;
        };
        if (value_y) |y| {
            if (indexedStoreBase(node.text)) |base| {
                if (resident.external(base, y)) try stores.append(a, .{ .line = node.index, .address = base + y });
            }
        }
        value_y = reachingY(value_y, inst, node.text);
    }
    if (stores.items.len == 0 or !try image.permitsLocalShrink(a, graph, program)) return null;

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var copied: usize = 0;
    for (stores.items) |store| {
        for (lines[copied..store.line]) |line| try out.writer.print("{s}\n", .{line});
        try out.writer.print("    sta ${x:0>4}\n", .{store.address});
        copied = store.line + 1;
    }
    for (lines[copied..], copied..) |line, index| {
        try out.writer.writeAll(line);
        if (index + 1 < lines.len) try out.writer.writeByte('\n');
    }
    return try out.toOwnedSlice();
}

const parser = @import("../../parser.zig");
const test_allocator = std.testing.allocator;
const test_header = "* = $0801\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
const test_end = "    rts\n; zeropage_section_end owner=function:main kind=code\n";
const packet = "    ldy #0\n    sta $c110,y\n    iny\n";
const high_store = "    lda $c104\n    sta $c110,y\n";

fn expectRewrite(body: []const u8, expected: []const u8) !void {
    const parsed = try parser.parseSource(test_allocator, "export fn main() void {}");
    defer parsed.deinit(test_allocator);
    const input = try std.mem.concat(test_allocator, u8, &.{ test_header, body, test_end });
    defer test_allocator.free(input);
    const output = (try rewrite(test_allocator, parsed.program, input)) orelse
        return error.ExpectedFixedStore;
    defer test_allocator.free(output);
    const want = try std.mem.concat(test_allocator, u8, &.{ test_header, expected, test_end });
    defer test_allocator.free(want);
    try std.testing.expectEqualStrings(want, output);
}

test "fixed stores keep the original crossing high store and the returned Y and NZ" {
    try expectRewrite(
        "    ldy #0\n    sta $c1ff,y\n    iny\n    sta $c1ff,y\n",
        "    ldy #1\n    sta $c1fe,y\n    sta $c1ff,y\n",
    );
}

test "fixed stores reuse Y across literal memory operands when NZ dies" {
    try expectRewrite(packet ++ high_store ++ packet ++ high_store, "    ldy #1\n    sta $c10f,y\n" ++ high_store ++ "    sta $c10f,y\n" ++ high_store);
}

test "fixed stores reload Y to supply flags at either branch arm" {
    const consumer = "    beq observed\n    lda $c100\nobserved:\n    sta $c110,y\n";
    const incoming = "    ldy #1\n    lda #0\n";
    try expectRewrite(incoming ++ packet ++ consumer, incoming ++ "    ldy #1\n    sta $c10f,y\n" ++ consumer);
}

test "fixed stores do not propagate Y through calls or alternate entries" {
    const subroutine = "    jmp done\nleaf:\n    dey\n    rts\ndone:\n";
    const caller = "    ldy #1\n    jsr leaf\n";
    try expectRewrite(caller ++ packet ++ high_store ++ subroutine, caller ++ "    ldy #1\n    sta $c10f,y\n" ++ high_store ++ subroutine);
    try expectRewrite(
        "    ldy #1\n    jsr leaf\n    bcc alternate\n    ldy #1\nalternate:\n" ++ packet ++ high_store ++ "    jmp done\nleaf:\n    dey\n    rts\ndone:\n",
        "    ldy #1\n    jsr leaf\n    bcc alternate\n    ldy #1\nalternate:\n    ldy #1\n    sta $c10f,y\n" ++ high_store ++ "    jmp done\nleaf:\n    dey\n    rts\ndone:\n",
    );
}

test "fixed stores leave page starts MMIO and interior labels alone" {
    const parsed = try parser.parseSource(test_allocator, "export fn main() void {}");
    defer parsed.deinit(test_allocator);
    for ([_][]const u8{
        "    ldy #0\n    sta $c100,y\n    iny\n",
        "    ldy #0\n    sta $d020,y\n    iny\n",
        "    ldy #0\nalternate:\n    sta $c110,y\n    iny\n",
        "    ldy #0\n    sta $c110,y\nalternate:\n    iny\n",
        "    ldy #0\n    sta $0803,y\n    iny\n",
    }) |body| {
        const input = try std.mem.concat(test_allocator, u8, &.{ test_header, body, test_end });
        defer test_allocator.free(input);
        const result = try rewrite(test_allocator, parsed.program, input);
        defer if (result) |output| test_allocator.free(output);
        try std.testing.expect(result == null);
    }
}

test "fixed stores keep visible ABI roots and opaque code unchanged" {
    const parsed = try parser.parseSource(test_allocator, "export fn main() void {}\nexport fn entry() void {}");
    defer parsed.deinit(test_allocator);
    try std.testing.expect((try rewrite(test_allocator, parsed.program, test_header ++ packet ++ test_end)) == null);

    const standalone = try parser.parseSource(test_allocator, "export fn main() void {}");
    defer standalone.deinit(test_allocator);
    const asm_block = "; inline asm from ZeroPage line 1\n    nop\n; end inline asm\n";
    try std.testing.expect((try rewrite(test_allocator, standalone.program, test_header ++ asm_block ++ packet ++ test_end)) == null);
}

const shift_stores = "    asl\n    ldy #1\n    sta $c1ff,y\n    txa\n    rol\n" ++
    "; zeropage_inline_end function=scale\n    sta $c200,y\n";
const absolute_stores = "    asl\n    sta $c200\n    txa\n    rol\n" ++
    "; zeropage_inline_end function=scale\n    sta $c201\n";

test "fixed shift stores keep both writes and the flags across a page" {
    const parsed = try parser.parseSource(test_allocator, "export fn main() void {}");
    defer parsed.deinit(test_allocator);
    const suffix = "    beq alternate\n    ldy #2\n    jmp done\nalternate:\n    ldy #3\ndone:\n" ++ test_end;
    const output = (try rewriteShiftStores(test_allocator, parsed.program, test_header ++ shift_stores ++ suffix)) orelse
        return error.ExpectedAbsoluteShiftStores;
    defer test_allocator.free(output);
    try std.testing.expectEqualStrings(test_header ++ absolute_stores ++ suffix, output);
}

test "fixed shift stores preserve Y at a live branch or opaque return" {
    const parsed = try parser.parseSource(test_allocator, "export fn main() void {}");
    defer parsed.deinit(test_allocator);
    for ([_][]const u8{
        "    beq alternate\n    ldy #2\n    jmp done\nalternate:\n    tya\ndone:\n" ++ test_end,
        test_end,
    }) |suffix| {
        const input = try std.mem.concat(test_allocator, u8, &.{ test_header, shift_stores, suffix });
        defer test_allocator.free(input);
        const output = try rewriteShiftStores(test_allocator, parsed.program, input);
        defer if (output) |result| test_allocator.free(result);
        try std.testing.expect(output == null);
    }
}

test "fixed shift stores exclude MMIO banked RAM and a dummy read into the image" {
    const parsed = try parser.parseSource(test_allocator, "export fn main() void {}");
    defer parsed.deinit(test_allocator);
    for ([_][]const u8{
        "    sta $cfff,y\n    txa\n    rol\n    sta $d000,y\n",
        "    sta $9fff,y\n    txa\n    rol\n    sta $a000,y\n",
        "    sta $08ff,y\n    txa\n    rol\n    sta $0900,y\n",
        "    sta $c110,y\nalternate:\n    txa\n    rol\n    sta $c111,y\n",
    }) |pair| {
        const input = try std.mem.concat(test_allocator, u8, &.{ test_header, "    asl\n    ldy #1\n", pair, "    ldy #2\n", test_end });
        defer test_allocator.free(input);
        const output = try rewriteShiftStores(test_allocator, parsed.program, input);
        defer if (output) |result| test_allocator.free(result);
        try std.testing.expect(output == null);
    }
}

test "known indexed stores preserve Y setup and flag consumers" {
    const parsed = try parser.parseSource(test_allocator, "export fn main() void {}");
    defer parsed.deinit(test_allocator);
    const prefix = "    ldy #255\n    iny\n    lda $c100\n";
    const middle = "    iny\n    adc $c101\n";
    const suffix = "    tya\n    beq done\ndone:\n" ++ test_end;
    const input = test_header ++ prefix ++ "    sta $c101,y\n" ++ middle ++ "    sta $c1ff,y\n" ++ suffix;
    const output = (try rewriteKnownIndex(test_allocator, parsed.program, input)) orelse
        return error.ExpectedAbsoluteStores;
    defer test_allocator.free(output);
    try std.testing.expectEqualStrings(test_header ++ prefix ++ "    sta $c101\n" ++ middle ++ "    sta $c200\n" ++ suffix, output);
}

test "known indexed stores decline observable dummy reads and unknown Y" {
    const parsed = try parser.parseSource(test_allocator, "export fn main() void {}");
    defer parsed.deinit(test_allocator);
    for ([_][]const u8{
        "    ldy #1\n    sta $cfff,y\n",
        "    ldy #1\n    sta $9fff,y\n",
        "    ldy #1\n    sta $08ff,y\n",
        "    ldy #1\n    sta $ffff,y\n",
        "    ldy #1\n    bne alternate\n    dey\nalternate:\n    sta $c100,y\n",
        "    ldy #1\n    tay\n    sta $c100,y\n",
        "    ldy #1\n    jsr leaf\n    sta $c100,y\n    jmp done\nleaf:\n    dey\n    rts\ndone:\n",
    }) |body| {
        const input = try std.mem.concat(test_allocator, u8, &.{ test_header, body, test_end });
        defer test_allocator.free(input);
        const output = try rewriteKnownIndex(test_allocator, parsed.program, input);
        defer if (output) |result| test_allocator.free(result);
        try std.testing.expect(output == null);
    }
}
