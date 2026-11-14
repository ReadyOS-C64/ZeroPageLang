const std = @import("std");
const ast = @import("../../ast.zig");
const layout = @import("branch_layout.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");
const image = @import("unreachable_code.zig");
const placement = @import("placement_domains.zig");
const source_spans = @import("static_copy_span.zig");

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn operand(line: []const u8, prefix: []const u8) ?[]const u8 {
    const text = trim(line);
    return if (std.mem.startsWith(u8, text, prefix)) text[prefix.len..] else null;
}

fn direct(line: []const u8, prefix: []const u8) ?[]const u8 {
    const text = operand(line, prefix) orelse return null;
    const parsed = machine.parseOperand(text);
    return if (parsed == .direct and std.mem.eql(u8, parsed.direct.name, text)) text else null;
}

fn byte(line: []const u8, prefix: []const u8) ?u8 {
    return std.math.cast(u8, machine.integer(operand(line, prefix) orelse return null) orelse return null);
}

fn named(line: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, layout.label(trim(line)) orelse return false, name);
}

const Comparison = struct { slot: []const u8, high: u8, failure: []const u8, end: usize };

fn comparison(lines: []const []const u8, success_branch: []const u8) ?Comparison {
    if (lines.len < 9) return null;
    const slot = direct(lines[1], "lda ") orelse return null;
    const high_load = operand(lines[0], "ldx ") orelse return null;
    if (high_load.len != slot.len + 2 or !std.mem.startsWith(u8, high_load, slot) or
        !std.mem.endsWith(u8, high_load, "+1")) return null;
    const high = byte(lines[2], "cpx #") orelse return null;
    var i: usize = 3;
    if (direct(lines[i], "bne ")) |join| {
        if (lines.len < 11 or byte(lines[i + 1], "cmp #") != 0 or !named(lines[i + 2], join)) return null;
        i += 2;
    }
    const join = layout.label(trim(lines[i])) orelse return null;
    if (!std.mem.startsWith(u8, join, "cmp_word_")) return null;
    const success = direct(lines[i + 1], success_branch) orelse return null;
    _ = layout.label(trim(lines[i + 2])) orelse return null;
    const failure = direct(lines[i + 3], "jmp ") orelse return null;
    if (!named(lines[i + 4], success)) return null;
    _ = layout.label(trim(lines[i + 5])) orelse return null;
    return .{ .slot = slot, .high = high, .failure = failure, .end = i + 6 };
}

const Selector = struct {
    slot: []const u8,
    lower: u8,
    upper: u8,
    else_label: []const u8,
    then_line: usize,
    end: usize,
};

pub const StoredSelector = struct {
    lower: u8,
    upper: u8,
    inside: u8,
    outside: u8,
    destination: []const u8,
    then_line: usize,
    end: usize,

    pub fn valueAt(self: StoredSelector, page: u8) u8 {
        return if (page >= self.lower and page < self.upper) self.inside else self.outside;
    }
};

fn indexWord(line: []const u8) ?[]const u8 {
    const load = operand(line, "ldx ") orelse return null;
    const reference = machine.parseOperand(load);
    if (reference != .direct or reference.direct.offset != 1 or
        !std.mem.endsWith(u8, load, "+1") or load.len != reference.direct.name.len + 2) return null;
    return reference.direct.name;
}

/// Read the compact selector followed by its ordinary byte store.
pub fn matchStored(lines: []const []const u8, index: []const u8) ?StoredSelector {
    if (lines.len < 11) return null;
    if (!std.mem.eql(u8, indexWord(lines[0]) orelse return null, index)) return null;
    const bound = byte(lines[1], "cpx #") orelse return null;
    var lower: u8 = 0;
    var upper = bound;
    var i: usize = 3;
    const otherwise = if (direct(lines[2], "bne ")) |target| blk: {
        lower = bound;
        upper = std.math.add(u8, bound, 1) catch return null;
        break :blk target;
    } else if (direct(lines[2], "bcc ")) |target| blk: {
        lower = bound;
        upper = byte(lines[3], "cpx #") orelse return null;
        if (!std.mem.eql(u8, direct(lines[4], "bcs ") orelse return null, target)) return null;
        i = 5;
        break :blk target;
    } else direct(lines[2], "bcs ") orelse return null;
    if (lower >= upper or !std.mem.startsWith(u8, otherwise, "if_expr_")) return null;
    while (i < lines.len and layout.label(trim(lines[i])) != null) : (i += 1) {}
    const tail = lines[i..];
    if (tail.len < 7 or !named(tail[2], otherwise) or !std.mem.eql(u8, trim(tail[5]), "sec")) return null;
    const done = direct(tail[1], "jmp ") orelse return null;
    if (!named(tail[4], done)) return null;
    return .{
        .lower = lower,
        .upper = upper,
        .inside = byte(tail[0], "lda #") orelse return null,
        .outside = byte(tail[3], "lda #") orelse return null,
        .destination = direct(tail[6], "sta ") orelse return null,
        .then_line = i,
        .end = i + 7,
    };
}

fn match(lines: []const []const u8) ?Selector {
    const lower = comparison(lines, "bcs ") orelse return null;
    if (lines.len <= lower.end) return null;
    const rhs = layout.label(trim(lines[lower.end])) orelse return null;
    if (!std.mem.startsWith(u8, rhs, "bool_and_") or !std.mem.endsWith(u8, rhs, "_rhs")) return null;
    const upper = comparison(lines[lower.end + 1 ..], "bcc ") orelse return null;
    if (lower.high >= upper.high or !std.mem.eql(u8, lower.slot, upper.slot) or
        !std.mem.eql(u8, lower.failure, upper.failure)) return null;
    const then = lower.end + 1 + upper.end;
    const tail = lines[then..];
    if (tail.len < 14 or byte(tail[1], "lda #") != 1 or !named(tail[3], lower.failure) or
        byte(tail[4], "lda #") != 0 or byte(tail[6], "cmp #") != 0) return null;
    _ = layout.label(trim(tail[0])) orelse return null;
    const bool_done = direct(tail[2], "jmp ") orelse return null;
    if (!named(tail[5], bool_done)) return null;
    const else_label = direct(tail[7], "beq ") orelse return null;
    if (!std.mem.startsWith(u8, else_label, "if_expr_") or !named(tail[10], else_label)) return null;
    const done = direct(tail[9], "jmp ") orelse return null;
    if (byte(tail[8], "lda #") == null or byte(tail[11], "lda #") == null or !named(tail[12], done)) return null;
    return .{ .slot = lower.slot, .lower = lower.high, .upper = upper.high, .else_label = else_label, .then_line = then + 8, .end = then + 13 };
}

fn isolatedLabels(lines: []const []const u8, start: usize, end: usize) bool {
    for (lines[start..end]) |raw| {
        const label = layout.label(trim(raw)) orelse continue;
        for (lines[0..start]) |line| {
            const text = trim(line);
            if (!std.mem.startsWith(u8, text, ";") and layout.tokenPresent(text, label)) return false;
        }
        for (lines[end..]) |line| {
            const text = trim(line);
            if (!std.mem.startsWith(u8, text, ";") and layout.tokenPresent(text, label)) return false;
        }
    }
    return true;
}

fn unobserved(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !bool {
    const upper = (try image.residentLayoutUpperBound(a, assembly)) orelse return false;
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!try layout.controlsUnobserved(a, graph)) return false;
    if (!try placement.observesMovableImage(a, program, .{ .start = program.zeropage_options.image.load_addr, .end = upper })) return true;
    const replay = source_spans.proveIndexed(a, program, upper) catch |err| switch (err) {
        error.Unproven => return false,
        error.OutOfMemory => return err,
    };
    a.free(replay);
    return true;
}

fn writeSelector(w: *std.Io.Writer, lines: []const []const u8, selector: Selector) !void {
    try w.print("{s}\n", .{lines[0]});
    if (selector.upper - selector.lower == 1) {
        try w.print("    cpx #${x:0>2}\n    bne {s}\n", .{ selector.lower, selector.else_label });
    } else {
        if (selector.lower != 0) try w.print("    cpx #${x:0>2}\n    bcc {s}\n", .{ selector.lower, selector.else_label });
        try w.print("    cpx #${x:0>2}\n    bcs {s}\n", .{ selector.upper, selector.else_label });
    }
    for (lines[1..selector.then_line]) |line| {
        if (layout.label(trim(line)) != null) try w.print("{s}\n", .{line});
    }
    for (lines[selector.then_line..selector.end]) |line| try w.print("{s}\n", .{line});
    // The original CMP #0 of a Boolean sets C on both paths. The selected
    // LDA sets N/Z, and none of the omitted instructions changes V.
    try w.writeAll("    sec\n");
}

fn ownedCell(model: storage.Model, function: []const u8, name: []const u8, width: u32) ?storage.Location {
    const location = model.resolve(.{ .name = name }, width) orelse return null;
    const frame = model.frames.items[location.frame];
    return if (frame.upper <= 0x8000 and std.mem.eql(u8, frame.owner, function)) location else null;
}

/// Fold two aligned word bounds feeding a byte selector. The matched
/// comparisons read the same owned RAM word and have no intervening writes.
pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, assembly, "bool_and_") == null or
        std.mem.indexOf(u8, assembly, "if_expr_") == null or
        std.mem.indexOf(u8, assembly, ".fill ((") != null) return null;
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    var input = std.mem.splitScalar(u8, assembly, '\n');
    while (input.next()) |line| try lines.append(a, line);
    var model = storage.Model.init(a);
    defer model.deinit();
    var checked = false;
    var result: std.Io.Writer.Allocating = .init(a);
    defer result.deinit();
    var owner: ?[]const u8 = null;
    var changed = false;
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const line = lines.items[i];
        if (std.mem.startsWith(u8, line, "; zeropage_section_")) owner = storage.sectionOwner(line, "code");
        if (owner) |function| if (match(lines.items[i..])) |selector| {
            if (!checked) {
                if (!try unobserved(a, program, assembly)) return null;
                try model.collect(assembly);
                checked = true;
            }
            if (ownedCell(model, function, selector.slot, 2) != null and isolatedLabels(lines.items, i, i + selector.end)) {
                try writeSelector(&result.writer, lines.items[i..], selector);
                i += selector.end - 1;
                changed = true;
                continue;
            }
        };
        try result.writer.writeAll(line);
        if (i + 1 < lines.items.len) try result.writer.writeByte('\n');
    }
    if (!changed) return null;
    return try result.toOwnedSlice();
}

fn writeShared(w: *std.Io.Writer, lines: []const []const u8, first: StoredSelector, second: StoredSelector) !void {
    const first_inside, _, const first_else, const first_outside, const first_done, _, const first_store =
        lines[first.then_line..][0..7].*;
    const second_lines = lines[first.end..][0..second.end];
    const second_tail = second_lines[second.then_line..];
    // Keep the first predicate. Both paths store the first byte, then load
    // the second. The second LDA gives the original A/N/Z and the shared
    // SEC gives the final carry. Neither path changes X/Y/V or the stack.
    for (lines[0..first.then_line]) |line| try w.print("{s}\n", .{line});
    try w.print("{s}\n{s}\n{s}\n{s}\n", .{ first_inside, first_store, second_tail[0], second_tail[1] });
    try w.print("{s}\n{s}\n{s}\n{s}\n", .{ first_else, first_outside, first_store, first_done });
    for (second_lines[0..second.then_line]) |line| {
        if (layout.label(trim(line)) != null) try w.print("{s}\n", .{line});
    }
    for (second_tail[2..]) |line| try w.print("{s}\n", .{line});
}

/// Share identical adjacent predicates after fixed-page cloning has selected
/// its loops. The pair has no alternate entry or observable code address.
pub fn shareStored(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    if (std.mem.count(u8, assembly, "    sec\n    sta ") < 2) return null;
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    var input = std.mem.splitScalar(u8, assembly, '\n');
    while (input.next()) |line| try lines.append(a, line);
    var model = storage.Model.init(a);
    defer model.deinit();
    var checked = false;
    var result: std.Io.Writer.Allocating = .init(a);
    defer result.deinit();
    var owner: ?[]const u8 = null;
    var copied: usize = 0;
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const line = lines.items[i];
        if (std.mem.startsWith(u8, line, "; zeropage_section_")) owner = storage.sectionOwner(line, "code");
        const function = owner orelse continue;
        const index = indexWord(line) orelse continue;
        const first = matchStored(lines.items[i..], index) orelse continue;
        const second = matchStored(lines.items[i + first.end ..], index) orelse continue;
        if (first.lower != second.lower or first.upper != second.upper) continue;
        if (!checked) {
            if (!try unobserved(a, program, assembly)) return null;
            try model.collect(assembly);
            checked = true;
        }
        const counter = ownedCell(model, function, index, 2) orelse continue;
        const lhs = ownedCell(model, function, first.destination, 1) orelse continue;
        const rhs = ownedCell(model, function, second.destination, 1) orelse continue;
        const end = i + first.end + second.end;
        if (!model.disjoint(counter, 2, lhs, 1) or !model.disjoint(counter, 2, rhs, 1) or
            !model.disjoint(lhs, 1, rhs, 1) or !isolatedLabels(lines.items, i, end)) continue;
        for (lines.items[copied..i]) |unchanged| try result.writer.print("{s}\n", .{unchanged});
        try writeShared(&result.writer, lines.items[i..end], first, second);
        copied = end;
        i = end - 1;
    }
    if (copied == 0) return null;
    for (lines.items[copied..], copied..) |line, index| {
        try result.writer.writeAll(line);
        if (index + 1 < lines.items.len) try result.writer.writeByte('\n');
    }
    return try result.toOwnedSlice();
}
