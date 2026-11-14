const std = @import("std");
const ast = @import("../../ast.zig");
const inline_asm = @import("../../inline_asm.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const image = @import("unreachable_code.zig");
const storage = @import("storage_model.zig");

pub const Shape = struct {
    source: []const u8,
    target: []const u8,
    count: []const u8,
    index: []const u8,
};

fn anyAsm(_: []const u8) bool {
    return true;
}

pub fn allowed(program: ast.Program) bool {
    for (program.functions) |function| {
        const prefix = "zeropage_stream_copy";
        const name = function.name;
        // A static slot is emitted as function_local. These shorter function
        // names can also produce a label in the generated namespace.
        if (std.ascii.eqlIgnoreCase(name, "zeropage") or std.ascii.eqlIgnoreCase(name, "zeropage_stream") or
            (name.len >= prefix.len and std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix))) return false;
    }
    return program.zeropage_module == null and program.zeropage_options.modules == null and
        program.zeropage_options.memory.placements.len == 0 and program.zeropage_options.stack == null and
        program.zeropage_options.image.load_addr >= 0x0200 and program.zeropage_options.image.entry_addr < 0x8000 and
        !inline_asm.referencesText(program.functions, anyAsm);
}

fn ident(expression: ast.Expr) ?[]const u8 {
    return if (expression == .value and expression.value == .ident) expression.value.ident else null;
}

fn integer(expression: ast.Expr, value: u16) bool {
    return expression == .value and expression.value == .int and expression.value.int == value;
}

fn named(expression: ast.Expr, name: []const u8) bool {
    return std.mem.eql(u8, ident(expression) orelse return false, name);
}

fn paramType(function: ast.Function, name: []const u8) ?ast.Type {
    for (function.params) |parameter| {
        if (std.mem.eql(u8, parameter.name, name)) return parameter.ty;
    }
    return null;
}

fn manyByte(ty: ast.Type) bool {
    return ty == .pointer and ty.pointer.is_many and !ty.pointer.is_volatile and
        ty.pointer.child == .scalar and ty.pointer.child.scalar == .u8;
}

fn unsignedWord(ty: ast.Type) bool {
    return ty == .u16 or ty == .usize;
}

// The caller emits the original loop as fallback, including its original type
// checking and source labels. No user expression is evaluated or deleted here.
pub fn classify(function: ast.Function, loop: ast.WhileStmt) ?Shape {
    if (function.exported or function.body.len != 3 or function.body[0] != .var_decl or
        function.body[1] != .while_stmt or function.body[2] != .return_expr) return null;
    const canonical = function.body[1].while_stmt;
    if (canonical.body.ptr != loop.body.ptr or canonical.body.len != loop.body.len) return null;
    const index = function.body[0].var_decl;
    if (!index.mutable or !unsignedWord(index.ty orelse return null) or !integer(index.init, 0)) return null;
    if (loop.condition != .lt or !named(loop.condition.lt.lhs.*, index.name)) return null;
    const count = ident(loop.condition.lt.rhs.*) orelse return null;
    if (!unsignedWord(paramType(function, count) orelse return null)) return null;
    if (loop.body.len != 2 or loop.body[0] != .array_assign or loop.body[1] != .add_assign) return null;
    const assign = loop.body[0].array_assign;
    const increment = loop.body[1].add_assign;
    if (!named(assign.index, index.name) or assign.value != .array_index) return null;
    const read = assign.value.array_index;
    if (!named(read.index.*, index.name) or !std.mem.eql(u8, increment.name, index.name) or
        !integer(increment.value, 1)) return null;
    if (!manyByte(paramType(function, read.name) orelse return null) or
        !manyByte(paramType(function, assign.name) orelse return null)) return null;
    return .{ .source = read.name, .target = assign.name, .count = count, .index = index.name };
}

const Labels = struct {
    source: []const u8,
    target: []const u8,
    count: []const u8,
    index: []const u8,
    stem: []const u8,
};

// Require pages above the last loaded byte and below $8000. CMP leaves
// carry set on the success path. Adding the count's high byte plus one
// upper-bounds the pages reached by both the copy and its dummy reads.
// Clamp the exclusive page to a byte. If the image reaches page $ff,
// the later upper-bound checks reject that page too.
fn emitBounds(w: *std.Io.Writer, base: []const u8, count: []const u8, stem: []const u8) !void {
    try w.print(
        "    lda {s}+1\n" ++
            "    cmp #(((>(zeropage_stream_copy_image_end-1))+1) <? $ff)\n" ++
            "    bcc {s}_fallback\n" ++
            "    adc {s}+1\n" ++
            "    bcs {s}_fallback\n" ++
            "    bmi {s}_fallback\n",
        .{ base, stem, count, stem, stem },
    );
}

fn emitRamY(w: *std.Io.Writer, labels: Labels) !void {
    const stem = labels.stem;
    // X counts full 256-byte chunks first. A wrap of Y advances both
    // logical base highs without changing either original low byte.
    try w.print(
        // The bounds checks and pointer setup preserve the high count in X.
        "    txa\n" ++
            "    beq {s}_tail_setup\n" ++
            "{s}_page:\n" ++
            // Y starts at zero and a full page has an even byte count.
            // Test the wrap after two ordered read/write pairs.
            "    lda (zeropage_string_ptr),y\n" ++
            "    sta (zeropage_ptr_tmp),y\n" ++
            "    iny\n" ++
            "    lda (zeropage_string_ptr),y\n" ++
            "    sta (zeropage_ptr_tmp),y\n" ++
            "    iny\n" ++
            "    bne {s}_page\n" ++
            "    inc zeropage_string_ptr+1\n" ++
            "    inc zeropage_ptr_tmp+1\n" ++
            "    dex\n" ++
            "    bne {s}_page\n" ++
            "{s}_tail_setup:\n" ++
            "    ldx {s}\n" ++
            "    beq {s}_finish\n" ++
            "{s}_tail:\n" ++
            "    lda (zeropage_string_ptr),y\n" ++
            "    sta (zeropage_ptr_tmp),y\n" ++
            "    iny\n" ++
            "    dex\n" ++
            "    bne {s}_tail\n" ++
            // X is zero after the last tail byte. Only the empty-tail
            // path needs to back up the high byte of the destination.
            "    beq {s}_last_page\n" ++
            "{s}_finish:\n" ++
            "    dec zeropage_ptr_tmp+1\n" ++
            "{s}_last_page:\n" ++
            "    dey\n" ++
            "    tya\n" ++
            "    clc\n" ++
            "    adc zeropage_ptr_tmp\n" ++
            "    sta zeropage_ptr_tmp\n" ++
            "    bcc {s}_last_address\n" ++
            "    inc zeropage_ptr_tmp+1\n" ++
            "{s}_last_address:\n",
        .{ stem, stem, stem, stem, stem, labels.count, stem, stem, stem, stem, stem, stem, stem, stem },
    );
}

fn emitFinish(w: *std.Io.Writer, labels: Labels, while_id: usize) !void {
    try w.print(
        "    pla\n" ++
            "    sta zeropage_string_ptr+1\n" ++
            "    pla\n" ++
            "    sta zeropage_string_ptr\n" ++
            // Restore the last-index scratch, the final source index and
            // the A/X/C/N/Z of the original equal-count loop exit.
            "    lda {s}\n" ++
            "    sta {s}\n" ++
            // Preserve the count low byte while A computes the last index.
            "    tay\n" ++
            "    sec\n" ++
            "    sbc #1\n" ++
            "    sta zeropage_ptr_value\n" ++
            "    ldx {s}+1\n" ++
            "    stx {s}+1\n" ++
            "    txa\n" ++
            "    sbc #0\n" ++
            "    sta zeropage_ptr_value+1\n" ++
            "    tya\n" ++
            // LDY supplies the equal comparison's N/Z and SEC its carry.
            "    ldy #0\n" ++
            "    sec\n" ++
            "    jmp while_{d}_done\n",
        .{ labels.count, labels.index, labels.count, labels.index, while_id },
    );
}

pub fn emitGuarded(a: std.mem.Allocator, w: *std.Io.Writer, function: []const u8, shape: Shape, while_id: usize) !void {
    const source = try std.fmt.allocPrint(a, "{s}_{s}", .{ function, shape.source });
    defer a.free(source);
    const target = try std.fmt.allocPrint(a, "{s}_{s}", .{ function, shape.target });
    defer a.free(target);
    const count = try std.fmt.allocPrint(a, "{s}_{s}", .{ function, shape.count });
    defer a.free(count);
    const index = try std.fmt.allocPrint(a, "{s}_{s}", .{ function, shape.index });
    defer a.free(index);
    const stem = try std.fmt.allocPrint(a, "zeropage_stream_copy_{d}", .{while_id});
    defer a.free(stem);
    const labels: Labels = .{ .source = source, .target = target, .count = count, .index = index, .stem = stem };
    try w.print(
        "    ldx {s}+1\n    bne {s}_bounds\n    lda {s}\n    cmp #2\n    bcc {s}_fallback\n{s}_bounds:\n",
        .{ count, stem, count, stem, stem },
    );
    try emitBounds(w, source, count, stem);
    try emitBounds(w, target, count, stem);
    try w.print("    jmp {s}_fast\n{s}_fallback:\n    jmp while_{d}_top\n{s}_fast:\n", .{ stem, stem, while_id, stem });
    try w.print(
        "    lda zeropage_string_ptr\n" ++
            "    pha\n" ++
            "    lda zeropage_string_ptr+1\n" ++
            "    pha\n" ++
            "    lda {s}\n" ++
            "    sta zeropage_string_ptr\n" ++
            "    lda {s}+1\n" ++
            "    sta zeropage_string_ptr+1\n" ++
            "    lda {s}\n" ++
            "    sta zeropage_ptr_tmp\n" ++
            "    lda {s}+1\n" ++
            "    sta zeropage_ptr_tmp+1\n" ++
            "    ldy #0\n",
        .{ source, source, target, target },
    );
    try emitRamY(w, labels);
    try emitFinish(w, labels, while_id);
}

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn tail(line: []const u8, prefix: []const u8) ?[]const u8 {
    const text = trim(line);
    return if (std.mem.startsWith(u8, text, prefix)) text[prefix.len..] else null;
}

fn labelUses(nodes: []const layout.Line, label: []const u8, expected: usize) bool {
    var count: usize = 0;
    for (nodes) |node| if (layout.tokenPresent(node.text, label)) {
        count += 1;
        if (count > expected) return false;
    };
    return count == expected;
}

const FallbackEdit = struct { reload: usize, carry_clear: usize };

fn fallbackEdit(a: std.mem.Allocator, graph: layout.Analysis, at: usize, shape: Shape, owner: []const u8, id: []const u8) !?FallbackEdit {
    const lines = graph.raw.items;
    if (lines.len - at < 15) return null;
    const packet = lines[at..][0..13];
    const compare = tail(packet[4], "bne ") orelse return null;
    if (!std.mem.startsWith(u8, compare, "cmp_word_") or
        !std.mem.eql(u8, layout.label(trim(packet[6])) orelse return null, compare)) return null;

    var expected: std.Io.Writer.Allocating = .init(a);
    defer expected.deinit();
    try expected.writer.print("ldx {0s}_{1s}+1\nlda {0s}_{1s}\ncpx {0s}_{2s}+1\n", .{ owner, shape.index, shape.count });
    try expected.writer.print("bne {s}\ncmp {s}_{s}\n{s}:\nbcs while_{s}_done\nwhile_{s}_body:\n", .{ compare, owner, shape.count, compare, id, id });
    try expected.writer.print("ldx {0s}_{1s}+1\nlda {0s}_{1s}\n", .{ owner, shape.index });
    try expected.writer.print("sta zeropage_ptr_value\nstx zeropage_ptr_value+1\nclc\nadc {s}_{s}\n", .{ owner, shape.source });
    var instructions = std.mem.splitScalar(u8, expected.written(), '\n');
    for (lines[at + 1 .. at + 15]) |line| {
        if (!std.mem.eql(u8, trim(line), instructions.next().?)) return null;
    }
    const body = layout.label(trim(packet[8])).?;
    if (!labelUses(graph.nodes.items, compare, 2) or !labelUses(graph.nodes.items, body, 1)) return null;
    return .{ .reload = at + 9, .carry_clear = at + 13 };
}

/// On the fallback's comparison fallthrough, AX still contains the index
/// and C is clear. The scratch stores preserve those values and ADC sets NZ.
pub fn reuseFallbackIndex(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, assembly, "zeropage_stream_copy_image_end:\n") == null or
        std.mem.indexOf(u8, assembly, ".fill (($100 - (* & $ff)) & $ff),0") != null or !allowed(program)) return null;
    var graph = try layout.parse(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    // The removed loads read the same private index slots as the compare.
    // In ordinary RAM those repeated reads have no device side effects.
    const upper = (try image.residentLayoutUpperBound(a, assembly)) orelse return null;
    if (upper > 0x8000) return null;

    const lines = graph.raw.items;
    var edits: std.ArrayList(FallbackEdit) = .empty;
    defer edits.deinit(a);
    var owner: ?[]const u8 = null;
    var shape: ?Shape = null;
    for (lines, 0..) |line, at| {
        if (std.mem.startsWith(u8, trim(line), "; zeropage_section_")) {
            owner = storage.sectionOwner(trim(line), "code");
            shape = null;
            if (owner) |name| if (program.findFunction(name)) |function| {
                if (function.body.len == 3 and function.body[1] == .while_stmt) shape = classify(function, function.body[1].while_stmt);
            };
        }
        const copy_shape = shape orelse continue;
        const label = layout.label(trim(line)) orelse continue;
        if (!std.mem.startsWith(u8, label, "while_") or !std.mem.endsWith(u8, label, "_top")) continue;
        const id = label["while_".len .. label.len - "_top".len];
        if (machine.integer(id) == null) continue;
        const guard = try std.fmt.allocPrint(a, "zeropage_stream_copy_{s}_fallback", .{id});
        defer a.free(guard);
        if (graph.target(guard) == null) continue;
        if (try fallbackEdit(a, graph, at, copy_shape, owner.?, id)) |edit| try edits.append(a, edit);
    }
    if (edits.items.len == 0) return null;

    var output: std.Io.Writer.Allocating = .init(a);
    errdefer output.deinit();
    var copied: usize = 0;
    for (edits.items) |edit| {
        for (lines[copied..edit.reload]) |line| try output.writer.print("{s}\n", .{line});
        for (lines[edit.reload + 2 .. edit.carry_clear]) |line| try output.writer.print("{s}\n", .{line});
        copied = edit.carry_clear + 1;
    }
    for (lines[copied..], copied..) |line, index| {
        try output.writer.writeAll(line);
        if (index + 1 < lines.len) try output.writer.writeByte('\n');
    }
    return try output.toOwnedSlice();
}
