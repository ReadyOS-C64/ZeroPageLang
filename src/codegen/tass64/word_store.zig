const std = @import("std");
const ast = @import("../../ast.zig");

const image = @import("unreachable_code.zig");
const layout = @import("branch_layout.zig");
const literal_io = @import("literal_pointer_io.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");
const word_y = @import("word_y_bridge.zig");

const result_word = "zeropage_ptr_value";
const pointer_word = "zeropage_ptr_tmp";
const math_word = "zeropage_math_tmp";

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn same(line: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, trim(line), expected);
}

fn matches(lines: []const []const u8, packet: []const []const u8) bool {
    if (lines.len < packet.len) return false;
    for (lines[0..packet.len], packet) |line, expected| {
        if (!same(line, expected)) return false;
    }
    return true;
}

fn number(line: []const u8, prefix: []const u8) ?u32 {
    const text = trim(line);
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    return machine.integer(text[prefix.len..]);
}

const Word = union(enum) {
    resident: storage.Location,
    zero_page: u32,

    fn disjoint(first: Word, second: Word, model: storage.Model) bool {
        return switch (first) {
            .resident => |location| second != .resident or model.disjoint(location, 2, second.resident, 2),
            .zero_page => |address| second != .zero_page or
                address + 2 <= second.zero_page or second.zero_page + 2 <= address,
        };
    }
};

fn scratchWord(model: storage.Model, lines: []const []const u8, managed: bool, name: []const u8) ?Word {
    if (model.resolveObject(.{ .name = name }, 2)) |location| {
        if (!std.mem.eql(u8, model.frames.items[location.frame].owner, "compiler:scratch")) return null;
        return .{ .resident = location };
    }
    if (!managed) return null;
    const claim = storage.claimedAddress(lines, name, "scratch") orelse return null;
    return if (claim.width == 2) .{ .zero_page = claim.address } else null;
}

fn pointerWord(lines: []const []const u8, managed: bool) ?Word {
    if (managed) {
        const claim = storage.claimedAddress(lines, pointer_word, "pointer") orelse return null;
        return if (claim.width == 2) .{ .zero_page = claim.address } else null;
    }
    for (lines) |line| {
        if (same(line, pointer_word ++ " = $fb")) return .{ .zero_page = 0xfb };
    }
    return null;
}

const Output = struct {
    base: u32,
    store: []const u8,
};

fn outputAt(lines: []const []const u8, resident: literal_io.Range) ?Output {
    if (lines.len < 5 or !same(lines[0], "ldy #0") or !same(lines[2], "iny") or
        !same(lines[3], "lda " ++ result_word ++ "+1") or !same(lines[4], trim(lines[1]))) return null;
    const store = trim(lines[1]);
    const prefix = "sta $";
    if (!std.mem.startsWith(u8, store, prefix) or !std.mem.endsWith(u8, store, ",y")) return null;
    const base = machine.integer(store["sta ".len .. store.len - 2]) orelse return null;
    if (base >= 65535 or !resident.external(base, 1)) return null;
    return .{ .base = base, .store = store };
}

fn hasInlineEnd(line: []const u8) bool {
    return std.mem.startsWith(u8, trim(line), "; zeropage_inline_end function=");
}

const Edit = struct {
    start: usize,
    end: usize,
    output: Output,
    marker: ?[]const u8,
    load_x: []const u8,
    load_y: ?[]const u8 = null,
    load_high: []const u8,
    high_op: []const u8,
    refresh_nz: bool,
    uses_stack: bool = false,
};

fn bridgedStore(lines: []const []const u8, start: usize, model: storage.Model, managed: bool, resident: literal_io.Range) ?Edit {
    const packet = lines[start..];
    if (packet.len < 13 or !same(packet[4], "tax")) return null;
    const stack = same(packet[1], "pha");
    if (stack) {
        if (!same(packet[5], "pla")) return null;
    } else if (!same(packet[1], "tay") or !same(packet[5], "tya")) return null;
    const load = machine.Instruction.parse(packet[2]) orelse return null;
    if (!same(packet[2], "txa") and !(load.op == .lda and word_y.ordinaryByte(load.operand, lines, model, managed))) return null;
    const low = machine.Instruction.parse(packet[0]) orelse return null;
    const high = machine.Instruction.parse(packet[3]) orelse return null;
    const refresh = switch (low.op) {
        .asl => if (same(packet[0], "asl") and same(packet[3], "rol")) false else return null,
        .adc, .sbc => if (low.op == high.op and word_y.ordinaryByte(low.operand, lines, model, managed) and
            word_y.ordinaryByte(high.operand, lines, model, managed)) true else return null,
        else => return null,
    };
    const has_marker = hasInlineEnd(packet[6]);
    const publish: usize = if (has_marker) 7 else 6;
    if (!same(packet[publish], "stx " ++ result_word ++ "+1")) return null;
    const output = outputAt(packet[publish + 2 ..], resident) orelse return null;
    if (number(packet[publish + 1], "ldx #") != output.base >> 8) return null;
    return .{
        .start = start,
        .end = start + publish + 7,
        .output = output,
        .marker = if (has_marker) packet[6] else null,
        .load_x = packet[publish + 1],
        .load_high = packet[2],
        .high_op = packet[3],
        .refresh_nz = refresh,
        .uses_stack = stack,
    };
}

fn maskedStore(lines: []const []const u8, start: usize, resident: literal_io.Range) ?Edit {
    const packet = lines[start..];
    if (packet.len < 17 or !matches(packet, &.{
        "adc " ++ math_word,
        "sta " ++ math_word,
        "txa",
        "adc " ++ math_word ++ "+1",
        "tax",
        "lda " ++ math_word,
    })) return null;
    const has_marker = hasInlineEnd(packet[6]);
    const publish: usize = if (has_marker) 7 else 6;
    if (!matches(packet[publish..], &.{ "sta " ++ result_word, "stx " ++ result_word ++ "+1" }) or
        !same(packet[publish + 3], "sty " ++ pointer_word) or
        !same(packet[publish + 5], "stx " ++ pointer_word ++ "+1")) return null;
    const output = outputAt(packet[publish + 6 ..], resident) orelse return null;
    if (number(packet[publish + 2], "ldy #") != output.base & 255 or
        number(packet[publish + 4], "ldx #") != output.base >> 8) return null;
    return .{
        .start = start,
        .end = start + publish + 11,
        .output = output,
        .marker = if (has_marker) packet[6] else null,
        .load_x = packet[publish + 4],
        .load_y = packet[publish + 2],
        .load_high = packet[2],
        .high_op = packet[3],
        .refresh_nz = true,
    };
}

fn writeEdit(w: *std.Io.Writer, edit: Edit, low: []const u8) !void {
    try w.print("{s}\n", .{low});
    if (edit.load_y) |load_y| {
        try w.print("    sta " ++ math_word ++ "\n    sta " ++ result_word ++ "\n{s}\n    sty " ++ pointer_word ++ "\n", .{load_y});
    }
    try w.print("    ldy #0\n    {s}\n    iny\n{s}\n{s}\n", .{ edit.output.store, edit.load_high, edit.load_x });
    if (edit.load_y != null) try w.writeAll("    stx " ++ pointer_word ++ "+1\n");
    try w.print("{s}\n", .{edit.high_op});
    if (edit.refresh_nz) try w.writeAll("    ora #0\n");
    if (edit.marker) |marker| try w.print("{s}\n", .{marker});
    try w.print("    sta " ++ result_word ++ "+1\n    {s}\n", .{edit.output.store});
}

/// Stream the low result before computing the high byte. Both indexed
/// stores keep their original base and Y value, including the dummy
/// read when base+1 crosses a page. Carry survives the intervening stores.
pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.functions.len != 0 or
        std.mem.indexOf(u8, assembly, "    lda " ++ result_word ++ "+1\n    sta $") == null) return null;
    for (program.functions) |function| {
        if (function.exported and !same(function.name, "main")) return null;
    }
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    const lines = graph.raw.items;
    const upper = (try image.residentLayoutUpperBound(a, assembly)) orelse return null;
    const resident: literal_io.Range = .{ .start = options.image.load_addr, .end = upper };
    var model = storage.Model.init(a);
    defer model.deinit();
    try model.collectWithPromotedParameters(assembly, lines);
    const managed = options.zero_page.declared;
    const result = scratchWord(model, lines, managed, result_word) orelse return null;
    const masked_safe = if (scratchWord(model, lines, managed, math_word)) |accumulator|
        if (pointerWord(lines, managed)) |pointer|
            result.disjoint(accumulator, model) and pointer.disjoint(accumulator, model) and pointer.disjoint(result, model)
        else
            false
    else
        false;
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(a);
    var consumed: usize = 0;
    var has_stack = false;
    for (graph.nodes.items) |node| {
        if (node.zone != .code or node.index < consumed) continue;
        const edit = bridgedStore(lines, node.index, model, managed, resident) orelse
            (if (masked_safe) maskedStore(lines, node.index, resident) else null) orelse continue;
        try edits.append(a, edit);
        consumed = edit.end;
        has_stack = has_stack or edit.uses_stack;
    }
    if (edits.items.len == 0 or !try image.permitsLocalShrink(a, graph, program)) return null;
    const stack_safe = has_stack and std.mem.indexOf(u8, assembly, "zeropage_test6502_expect_stack_") == null and
        try image.permitsPrivateStackRewrite(a, graph, program);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const w = &out.writer;
    var copied: usize = 0;
    for (edits.items) |edit| {
        if (edit.uses_stack and !stack_safe) continue;
        for (lines[copied..edit.start]) |line| try w.print("{s}\n", .{line});
        try writeEdit(w, edit, lines[edit.start]);
        copied = edit.end;
    }
    if (copied == 0) return null;
    for (lines[copied..], copied..) |line, index| {
        try w.writeAll(line);
        if (index + 1 < lines.len) try w.writeByte('\n');
    }
    return try out.toOwnedSlice();
}

const parser = @import("../../parser.zig");
const a_test = std.testing.allocator;
const head = "* = $2000\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
const tail = "    rts\n; zeropage_section_end owner=function:main kind=code\n" ++
    "; zeropage_section_begin owner=function:main kind=static_frame\nmain_word:\n    .word 0\n" ++
    "; zeropage_section_end owner=function:main kind=static_frame\n" ++
    "; zeropage_section_begin owner=compiler kind=scratch\nzeropage_ptr_value:\n    .word 0\n" ++
    "; zeropage_section_end owner=compiler kind=scratch\n";
const add = "    adc main_word\n    tay\n    txa\n    adc main_word+1\n    tax\n    tya\n" ++
    "; zeropage_inline_end function=calc\n";
const shift = "    asl\n    pha\n    txa\n    rol\n    tax\n    pla\n";
const test_publish = "    stx zeropage_ptr_value+1\n";
const stores = "    ldx #$c1\n    ldy #0\n    sta $c1ff,y\n    iny\n" ++
    "    lda zeropage_ptr_value+1\n    sta $c1ff,y\n";

test "word stores preserve indexed stores and the decimal flag refresh" {
    const parsed = try parser.parseSource(a_test, "export fn main() void {}");
    defer parsed.deinit(a_test);
    const result = (try rewrite(a_test, parsed.program, head ++ add ++ test_publish ++ stores ++ tail)) orelse
        return error.ExpectedWordStore;
    defer a_test.free(result);
    try std.testing.expectEqualStrings(head ++
        "    adc main_word\n    ldy #0\n    sta $c1ff,y\n    iny\n    txa\n    ldx #$c1\n" ++
        "    adc main_word+1\n    ora #0\n; zeropage_inline_end function=calc\n" ++
        "    sta zeropage_ptr_value+1\n    sta $c1ff,y\n" ++ tail, result);
}

test "word stores stream a left shift and keep its final flags" {
    const parsed = try parser.parseSource(a_test, "export fn main() void {}");
    defer parsed.deinit(a_test);
    const result = (try rewrite(a_test, parsed.program, head ++ shift ++ test_publish ++ stores ++ tail)) orelse
        return error.ExpectedWordStore;
    defer a_test.free(result);
    try std.testing.expectEqualStrings(head ++
        "    asl\n    ldy #0\n    sta $c1ff,y\n    iny\n    txa\n    ldx #$c1\n" ++
        "    rol\n    sta zeropage_ptr_value+1\n    sta $c1ff,y\n" ++ tail, result);
}

test "word stores decline output aliases, unsafe dummy reads and alternate entries" {
    const parsed = try parser.parseSource(a_test, "export fn main() void {}");
    defer parsed.deinit(a_test);
    for ([_][2][]const u8{
        .{ "adc main_word+1", "adc $c1ff" },
        .{ "adc main_word+1", "adc port" },
        .{ "    tax\n", "alternate:\n    tax\n" },
        .{ "$c1ff", "$cfff" },
    }) |change| {
        const text = try std.mem.replaceOwned(u8, a_test, head ++ add ++ test_publish ++ stores ++ tail ++ "port = $c1ff\n", change[0], change[1]);
        defer a_test.free(text);
        try std.testing.expect((try rewrite(a_test, parsed.program, text)) == null);
    }
    // The two writes are outside the image, but the second store
    // dummy-reads $2000 before carrying into $2100.
    const indexed = "    ldx #$20\n    ldy #0\n    sta $20ff,y\n    iny\n" ++
        "    lda zeropage_ptr_value+1\n    sta $20ff,y\n";
    try std.testing.expect((try rewrite(a_test, parsed.program, head ++ add ++ test_publish ++ indexed ++ tail)) == null);
}

const math = "; zeropage_section_begin owner=compiler kind=scratch\nzeropage_math_tmp:\n    .word 0\n" ++
    "; zeropage_section_end owner=compiler kind=scratch\n";
const masked = "    adc zeropage_math_tmp\n    sta zeropage_math_tmp\n    txa\n" ++
    "    adc zeropage_math_tmp+1\n    tax\n    lda zeropage_math_tmp\n" ++
    "    sta zeropage_ptr_value\n    stx zeropage_ptr_value+1\n" ++
    "    ldy #$ff\n    sty zeropage_ptr_tmp\n    ldx #$c1\n    stx zeropage_ptr_tmp+1\n" ++
    "    ldy #0\n    sta $c1ff,y\n    iny\n    lda zeropage_ptr_value+1\n    sta $c1ff,y\n";

test "word stores retain the masked result and both pointer publications" {
    const parsed = try parser.parseSource(a_test, "export fn main() void {}");
    defer parsed.deinit(a_test);
    const pointer = "zeropage_ptr_tmp = $fb\n";
    const result = (try rewrite(a_test, parsed.program, head ++ masked ++ tail ++ math ++ pointer)) orelse
        return error.ExpectedWordStore;
    defer a_test.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "    sta zeropage_ptr_value\n    ldy #$ff\n    sty zeropage_ptr_tmp\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "    ldx #$c1\n    stx zeropage_ptr_tmp+1\n    adc zeropage_math_tmp+1\n    ora #0\n") != null);
    try std.testing.expect((try rewrite(a_test, parsed.program, head ++ masked ++ tail ++ math ++
        "zeropage_ptr_tmp = zeropage_math_tmp\n")) == null);
}
