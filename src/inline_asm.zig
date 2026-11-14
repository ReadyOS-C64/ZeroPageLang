const std = @import("std");
const ast = @import("ast.zig");

/// Find assembly text in AST payloads, including nested block expressions.
pub fn referencesText(value: anytype, comptime matches: fn ([]const u8) bool) bool {
    const T = @TypeOf(value);
    if (T == ast.InlineAsm) return matches(value.source);
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => if (pointer.child == u8) false else blk: {
                for (value) |child| if (referencesText(child, matches)) break :blk true;
                break :blk false;
            },
            .one => if (pointer.child == u8 or pointer.child == anyopaque) false else referencesText(value.*, matches),
            else => false,
        },
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| if (referencesText(@field(value, field.name), matches)) break :blk true;
            break :blk false;
        },
        .@"union" => |info| if (info.tag_type != null) switch (value) {
            inline else => |payload| referencesText(payload, matches),
        } else false,
        .optional => if (value) |child| referencesText(child, matches) else false,
        .array => blk: {
            for (value) |child| if (referencesText(child, matches)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

pub const Clobbers = struct {
    a: bool = false,
    x: bool = false,
    y: bool = false,
    flags: bool = false,
};

pub const Instruction = struct {
    mnemonic: []const u8,
    operand: []const u8,
    source_line: usize,
    offset: isize,
};

pub const Line = union(enum) {
    label: []const u8,
    instruction: Instruction,
};

pub const AnalyzedBlock = struct {
    lines: []Line,
    clobbers: Clobbers,

    pub fn deinit(self: AnalyzedBlock, allocator: std.mem.Allocator) void {
        if (self.lines.len != 0) allocator.free(self.lines);
    }
};

pub fn analyze(allocator: std.mem.Allocator, block: ast.InlineAsm) !AnalyzedBlock {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(allocator);
    var labels: std.StringHashMap(isize) = .init(allocator);
    defer labels.deinit();

    var clobbers = Clobbers{};
    var offset: isize = 0;
    var line_number = block.source_line + 1;
    var it = std.mem.splitScalar(u8, block.source, '\n');
    while (it.next()) |raw_line| : (line_number += 1) {
        const code = stripCommentAndTrim(raw_line);
        if (code.len == 0) continue;
        if (isDirectiveLike(code)) return error.UnsupportedInlineAsmDirective;

        if (std.mem.endsWith(u8, code, ":")) {
            const label = std.mem.trim(u8, code[0 .. code.len - 1], " \t\r");
            if (!isLabelName(label)) return error.InvalidInlineAsmLabel;
            if (labels.contains(label)) return error.DuplicateInlineAsmLabel;
            try labels.put(label, offset);
            try lines.append(allocator, .{ .label = label });
            continue;
        }

        const parsed = try parseInstruction(code, line_number, offset);
        try lines.append(allocator, .{ .instruction = parsed });
        applyClobbers(&clobbers, parsed);
        offset += instructionSize(parsed.mnemonic, parsed.operand);
    }

    for (lines.items) |line| {
        switch (line) {
            .instruction => |inst| {
                if (eqlMnemonic(inst.mnemonic, "jmp") and isAbsoluteAddressLiteral(inst.operand) and lines.items.len != 1) {
                    return error.UnsupportedInlineAsmInstruction;
                }
                try validateInstructionTarget(inst, labels);
            },
            else => {},
        }
    }

    return .{ .lines = try lines.toOwnedSlice(allocator), .clobbers = clobbers };
}

fn stripCommentAndTrim(line: []const u8) []const u8 {
    const without_comment = if (std.mem.indexOfScalar(u8, line, ';')) |pos| line[0..pos] else line;
    return std.mem.trim(u8, without_comment, " \t\r");
}

fn isDirectiveLike(code: []const u8) bool {
    return code[0] == '.' or code[0] == '*' or code[0] == '!';
}

fn parseInstruction(code: []const u8, source_line: usize, offset: isize) !Instruction {
    var end: usize = 0;
    while (end < code.len and !std.ascii.isWhitespace(code[end])) : (end += 1) {}
    const mnemonic = code[0..end];
    const operand = std.mem.trim(u8, code[end..], " \t\r");
    if (!isKnownMnemonic(mnemonic)) return error.UnknownInlineAsmMnemonic;
    if (isForbiddenInstruction(mnemonic)) return error.UnsupportedInlineAsmInstruction;
    if (isStackInstruction(mnemonic)) return error.UnsupportedInlineAsmStackInstruction;
    return .{ .mnemonic = mnemonic, .operand = operand, .source_line = source_line, .offset = offset };
}

fn validateInstructionTarget(inst: Instruction, labels: std.StringHashMap(isize)) !void {
    if (isBranch(inst.mnemonic)) {
        if (!isLabelName(inst.operand)) return error.InlineAsmJumpOutsideBlock;
        const target_offset = labels.get(inst.operand) orelse return error.InlineAsmJumpOutsideBlock;
        const delta = target_offset - (inst.offset + 2);
        if (delta < -128 or delta > 127) return error.InlineAsmBranchOutOfRange;
    } else if (eqlMnemonic(inst.mnemonic, "jmp")) {
        if (isLabelName(inst.operand)) {
            _ = labels.get(inst.operand) orelse return error.InlineAsmJumpOutsideBlock;
        } else if (!isAbsoluteAddressLiteral(inst.operand)) {
            return error.InlineAsmJumpOutsideBlock;
        }
    } else if (eqlMnemonic(inst.mnemonic, "jsr")) {
        if (labels.contains(inst.operand)) return error.UnsupportedInlineAsmInstruction;
    }
}

fn isAbsoluteAddressLiteral(operand: []const u8) bool {
    if (operand.len != 5 or operand[0] != '$') return false;
    for (operand[1..]) |digit| {
        if (!std.ascii.isHex(digit)) return false;
    }
    return true;
}

fn applyClobbers(clobbers: *Clobbers, inst: Instruction) void {
    if (eqlMnemonic(inst.mnemonic, "jsr")) {
        clobbers.* = .{ .a = true, .x = true, .y = true, .flags = true };
        return;
    }

    if (mnemonicIn(inst.mnemonic, &.{ "lda", "adc", "sbc", "and", "ora", "eor", "txa", "tya" })) clobbers.a = true;
    if (mnemonicIn(inst.mnemonic, &.{ "ldx", "inx", "dex", "tax" })) clobbers.x = true;
    if (mnemonicIn(inst.mnemonic, &.{ "ldy", "iny", "dey", "tay" })) clobbers.y = true;
    if (mnemonicIn(inst.mnemonic, &.{
        "lda", "ldx", "ldy", "adc", "sbc", "and", "ora", "eor", "asl", "lsr", "rol", "ror",
        "cmp", "cpx", "cpy", "inc", "dec", "inx", "dex", "iny", "dey", "tax", "txa", "tay",
        "tya", "clc", "sec", "cli", "sei", "clv", "cld", "sed", "bit",
    })) clobbers.flags = true;
    if (mnemonicIn(inst.mnemonic, &.{ "asl", "lsr", "rol", "ror" }) and (inst.operand.len == 0 or eqlMnemonic(inst.operand, "a"))) {
        clobbers.a = true;
    }
}

fn instructionSize(mnemonic: []const u8, operand: []const u8) isize {
    if (isBranch(mnemonic)) return 2;
    if (mnemonicIn(mnemonic, &.{ "jsr", "jmp" })) return 3;
    if (operand.len == 0) return 1;
    if (mnemonicIn(mnemonic, &.{ "asl", "lsr", "rol", "ror" }) and eqlMnemonic(operand, "a")) return 1;
    if (operand[0] == '#') return 2;
    if (isLikelyZeroPage(operand)) return 2;
    return 3;
}

fn isLikelyZeroPage(operand: []const u8) bool {
    const first = operandBeforeIndex(operand);
    if (first.len == 0) return false;
    if (first[0] == '$') {
        if (first.len <= 3) return true;
        return false;
    }
    const value = std.fmt.parseInt(u16, first, 10) catch return false;
    return value <= 0xff;
}

fn operandBeforeIndex(operand: []const u8) []const u8 {
    const comma = std.mem.indexOfScalar(u8, operand, ',') orelse operand.len;
    return std.mem.trim(u8, operand[0..comma], " \t\r()");
}

pub fn isLabelReference(block: AnalyzedBlock, text: []const u8) bool {
    for (block.lines) |line| {
        switch (line) {
            .label => |label| if (std.mem.eql(u8, label, text)) return true,
            else => {},
        }
    }
    return false;
}

fn isLabelName(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!std.ascii.isAlphabetic(text[0]) and text[0] != '_') return false;
    for (text[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

fn isKnownMnemonic(mnemonic: []const u8) bool {
    return mnemonicIn(mnemonic, &.{
        "adc", "and", "asl", "bcc", "bcs", "beq", "bit", "bmi", "bne", "bpl", "brk", "bvc",
        "bvs", "clc", "cld", "cli", "clv", "cmp", "cpx", "cpy", "dec", "dex", "dey", "eor",
        "inc", "inx", "iny", "jmp", "jsr", "lda", "ldx", "ldy", "lsr", "nop", "ora", "pha",
        "php", "pla", "plp", "rol", "ror", "rti", "rts", "sbc", "sec", "sed", "sei", "sta",
        "stx", "sty", "tax", "tay", "tsx", "txa", "txs", "tya",
    });
}

fn isForbiddenInstruction(mnemonic: []const u8) bool {
    return mnemonicIn(mnemonic, &.{ "brk", "rti", "rts" });
}

fn isStackInstruction(mnemonic: []const u8) bool {
    return mnemonicIn(mnemonic, &.{ "pha", "php", "pla", "plp", "tsx", "txs" });
}

fn isBranch(mnemonic: []const u8) bool {
    return mnemonicIn(mnemonic, &.{ "bcc", "bcs", "beq", "bmi", "bne", "bpl", "bvc", "bvs" });
}

fn mnemonicIn(mnemonic: []const u8, list: []const []const u8) bool {
    for (list) |candidate| {
        if (eqlMnemonic(mnemonic, candidate)) return true;
    }
    return false;
}

fn eqlMnemonic(lhs: []const u8, rhs: []const u8) bool {
    return std.ascii.eqlIgnoreCase(lhs, rhs);
}

test "inline asm rejects duplicate labels" {
    try std.testing.expectError(error.DuplicateInlineAsmLabel, analyze(std.testing.allocator, .{
        .source = "loop:\nloop:\n    nop",
        .source_line = 1,
        .source_column = 5,
    }));
}

test "inline asm rejects jumps outside block" {
    try std.testing.expectError(error.InlineAsmJumpOutsideBlock, analyze(std.testing.allocator, .{
        .source = "    jmp outside",
        .source_line = 1,
        .source_column = 5,
    }));
}

test "inline asm accepts absolute terminal jump" {
    const analyzed = try analyze(std.testing.allocator, .{
        .source = "    jmp $c80f",
        .source_line = 1,
        .source_column = 5,
    });
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analyzed.lines.len);
}

test "inline asm rejects an absolute jump mixed with other lines" {
    try std.testing.expectError(error.UnsupportedInlineAsmInstruction, analyze(std.testing.allocator, .{
        .source = "    sei\n    jmp $c80f",
        .source_line = 1,
        .source_column = 5,
    }));
}

test "inline asm detects far branch" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("    beq far\n");
    for (0..140) |_| try source.writer.writeAll("    nop\n");
    try source.writer.writeAll("far:\n    nop\n");
    try std.testing.expectError(error.InlineAsmBranchOutOfRange, analyze(std.testing.allocator, .{
        .source = source.written(),
        .source_line = 1,
        .source_column = 5,
    }));
}
