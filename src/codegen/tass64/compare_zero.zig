const std = @import("std");
const ast = @import("../../ast.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const image = @import("unreachable_code.zig");
const cfg = @import("cfg_dead_values.zig");

fn setsAccumulatorFlags(raw: []const u8) bool {
    const instruction = machine.Instruction.parse(raw) orelse return false;
    if (instruction.operand == .unknown) return false;
    // NMOS decimal ADC/SBC can leave N/Z from an intermediate result.
    return switch (instruction.op) {
        .lda, .ora, .eor, .@"and", .pla, .txa, .tya => true,
        else => false,
    };
}

pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.functions.len != 0 or
        std.mem.indexOf(u8, assembly, "    cmp #0\n") == null or
        std.mem.indexOf(u8, assembly, "zeropage_test6502_expect_stack_") != null) return null;
    for (program.functions) |function| {
        if (function.exported and !std.mem.eql(u8, function.name, "main")) return null;
    }
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    const lines = graph.raw.items;
    const nodes = graph.nodes.items;
    var edits: std.ArrayList(usize) = .empty;
    defer edits.deinit(a);
    // No label or boundary may lead directly to CMP without its producer.
    for (nodes) |node| {
        if (node.zone != .code or node.index == 0 or !std.mem.eql(u8, node.text, "cmp #0")) continue;
        if (setsAccumulatorFlags(lines[node.index - 1])) try edits.append(a, node.index);
    }
    if (edits.items.len == 0 or !try image.permitsLocalShrink(a, graph, program)) return null;
    var query = try cfg.OutputQuery.init(a, assembly);
    defer query.deinit();
    var i = edits.items.len;
    while (i != 0) {
        i -= 1;
        const line = edits.items[i];
        // SEC and CMP #0 both set C. A deletion instead needs liveness
        // against the decisions already made later in the same image.
        if (try query.deadAfterLine(line, machine.c)) query.markRemoved(line);
    }
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var edit: usize = 0;
    for (lines, 0..) |raw, line| {
        if (edit < edits.items.len and edits.items[edit] == line) {
            if (!query.removed[line]) try output.writer.writeAll("    sec\n");
            edit += 1;
            continue;
        }
        try output.writer.writeAll(raw);
        if (line + 1 < lines.len) try output.writer.writeByte('\n');
    }
    return try output.toOwnedSlice();
}

const parser = @import("../../parser.zig");
const test_source = "export fn main() void {}";
const test_header = "* = $2000\n; zeropage_section_begin owner=function:main kind=code\nmain:\n";
const test_footer = "    rts\n; zeropage_section_end owner=function:main kind=code\n";

test "compare zero removes dead carry or preserves live carry with SEC" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, test_source);
    defer parsed.deinit(a);
    const body =
        "    lda #1\n    cmp #0\n    beq second\nsecond:\n    txa\n    cmp #0\n    clc\n" ++
        "    tya\n    cmp #0\n    bcs done\ndone:\n";
    const expected =
        "    lda #1\n    beq second\nsecond:\n    txa\n    clc\n" ++
        "    tya\n    sec\n    bcs done\ndone:\n";
    const output = (try rewrite(a, parsed.program, test_header ++ body ++ test_footer)) orelse return error.ExpectedCompareFold;
    defer a.free(output);
    try std.testing.expectEqualStrings(test_header ++ expected ++ test_footer, output);
}

test "compare zero preserves comparisons after decimal arithmetic or alternate entries" {
    const a = std.testing.allocator;
    const parsed = try parser.parseSource(a, test_source);
    defer parsed.deinit(a);
    const body =
        "    sed\n    lda #$99\n    clc\n    adc #1\n    cmp #0\n" ++
        "    bne entry\n    lda #0\nentry:\n    cmp #0\n";
    const output = try rewrite(a, parsed.program, test_header ++ body ++ test_footer);
    defer if (output) |bytes| a.free(bytes);
    try std.testing.expect(output == null);
}
