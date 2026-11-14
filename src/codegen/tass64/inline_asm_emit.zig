const std = @import("std");
const ast = @import("../../ast.zig");
const inline_asm = @import("../../inline_asm.zig");

pub fn emitBlock(self: anytype, function_name: []const u8, block: ast.InlineAsm) !void {
    const analyzed = try inline_asm.analyze(self.allocator, block);
    defer analyzed.deinit(self.allocator);

    const function = self.findFunction(function_name) orelse return error.UnknownFunction;
    const id = self.inline_asm_id;
    self.inline_asm_id += 1;

    const save_a = analyzed.clobbers.a or analyzed.clobbers.x or analyzed.clobbers.y;
    const save_x = analyzed.clobbers.x;
    const save_y = analyzed.clobbers.y;
    const save_p = analyzed.clobbers.flags or save_a or save_x or save_y;
    const w = &self.out.writer;

    try w.print("    ; inline asm from ZeroPage line {d}\n", .{block.source_line});
    if (save_p) try w.writeAll("    php\n");
    if (save_a) try w.writeAll("    pha\n");
    if (save_x) try w.writeAll("    txa\n    pha\n");
    if (save_y) try w.writeAll("    tya\n    pha\n");

    for (analyzed.lines) |line| {
        switch (line) {
            .label => |label| try w.print("zeropage_asm_{d}_{s}:\n", .{ id, label }),
            .instruction => |inst| try emitInstruction(self, function, analyzed, id, inst),
        }
    }

    if (save_y) try w.writeAll("    pla\n    tay\n");
    if (save_x) try w.writeAll("    pla\n    tax\n");
    if (save_a) try w.writeAll("    pla\n");
    if (save_p) try w.writeAll("    plp\n");
    try w.writeAll("    ; end inline asm\n");
}

pub fn emitInstruction(self: anytype, function: ast.Function, analyzed: inline_asm.AnalyzedBlock, id: usize, inst: inline_asm.Instruction) !void {
    const w = &self.out.writer;
    if (inst.operand.len != 0 and inline_asm.isLabelReference(analyzed, inst.operand)) {
        try w.print("    {s} zeropage_asm_{d}_{s}\n", .{ inst.mnemonic, id, inst.operand });
    } else if (inst.operand.len != 0) {
        const operand = try rewriteOperand(self, function, inst.mnemonic, inst.operand);
        defer self.allocator.free(operand);
        try w.print("    {s} {s}\n", .{ inst.mnemonic, operand });
    } else {
        try w.print("    {s}\n", .{inst.mnemonic});
    }
}

pub fn rewriteOperand(self: anytype, function: ast.Function, mnemonic: []const u8, operand: []const u8) ![]u8 {
    var rewritten: std.ArrayList(u8) = .empty;
    errdefer rewritten.deinit(self.allocator);

    var i: usize = 0;
    while (i < operand.len) {
        if (operand[i] != '@') {
            try rewritten.append(self.allocator, operand[i]);
            i += 1;
            continue;
        }

        const plain_immediate = i > 0 and operand[i - 1] == '#';
        const pointer_immediate = i >= 2 and operand[i - 2] == '#' and (operand[i - 1] == '<' or operand[i - 1] == '>');
        const any_immediate = plain_immediate or pointer_immediate;
        const name_start = i + 1;
        var name_end = name_start;
        while (name_end < operand.len and (std.ascii.isAlphanumeric(operand[name_end]) or operand[name_end] == '_')) : (name_end += 1) {}
        if (name_end == name_start) return error.InvalidInlineAsmVariableOperand;

        const name = operand[name_start..name_end];
        if (name_end < operand.len and operand[name_end] == '.') {
            const suffix_start = name_end + 1;
            var suffix_end = suffix_start;
            while (suffix_end < operand.len and (std.ascii.isAlphanumeric(operand[suffix_end]) or operand[suffix_end] == '_')) : (suffix_end += 1) {}
            if (suffix_end == suffix_start) return error.UnsupportedInlineAsmStringOperand;

            const suffix = operand[suffix_start..suffix_end];
            if (std.mem.eql(u8, suffix, "data")) {
                if (plain_immediate) return error.UnsupportedInlineAsmStringOperand;
                if (self.program.findString(name)) |_| {
                    if (mnemonicWritesMemory(mnemonic, operand)) return error.UnsupportedInlineAsmConstStringWrite;
                    const symbol = try std.fmt.allocPrint(self.allocator, "zeropage_str_{s}", .{name});
                    defer self.allocator.free(symbol);
                    try rewritten.appendSlice(self.allocator, symbol);
                } else if (self.findStringBuffer(function.name, name)) |buffer| {
                    const symbol = try std.fmt.allocPrint(self.allocator, "{s}_{s}_data", .{ buffer.function_name, buffer.name });
                    defer self.allocator.free(symbol);
                    try rewritten.appendSlice(self.allocator, symbol);
                } else {
                    return error.UnknownInlineAsmStringOperand;
                }
                i = suffix_end;
                continue;
            }

            if (std.mem.eql(u8, suffix, "len")) {
                if (self.program.findString(name)) |constant| {
                    if (!plain_immediate) return error.UnsupportedInlineAsmStringOperand;
                    const len_text = try std.fmt.allocPrint(self.allocator, "{d}", .{constant.bytes.len});
                    defer self.allocator.free(len_text);
                    try rewritten.appendSlice(self.allocator, len_text);
                } else if (self.findStringBuffer(function.name, name)) |buffer| {
                    if (any_immediate) return error.UnsupportedInlineAsmRuntimeStringLenImmediate;
                    const symbol = try std.fmt.allocPrint(self.allocator, "{s}_{s}_len", .{ buffer.function_name, buffer.name });
                    defer self.allocator.free(symbol);
                    try rewritten.appendSlice(self.allocator, symbol);
                } else {
                    return error.UnknownInlineAsmStringOperand;
                }
                i = suffix_end;
                continue;
            }

            return error.UnsupportedInlineAsmStringOperand;
        }

        if (any_immediate) return error.InvalidInlineAsmVariableOperand;
        if (self.program.findString(name) != null or self.findStringBuffer(function.name, name) != null) return error.UnsupportedInlineAsmStringOperand;
        const binding = try self.expectBinding(function.name, name);
        if (!binding.inline_asm_allowed) return error.UnsupportedInlineAsmConstOperand;
        if (!isInlineAsmByteType(binding.ty)) return error.UnsupportedInlineAsmVariableType;
        const symbol = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ function.name, name });
        defer self.allocator.free(symbol);
        try rewritten.appendSlice(self.allocator, symbol);
        i = name_end;
    }

    return try rewritten.toOwnedSlice(self.allocator);
}

pub fn mnemonicWritesMemory(mnemonic: []const u8, operand: []const u8) bool {
    if (mnemonicIn(mnemonic, &.{ "sta", "stx", "sty", "inc", "dec" })) return true;
    if (mnemonicIn(mnemonic, &.{ "asl", "lsr", "rol", "ror" })) {
        const trimmed = std.mem.trim(u8, operand, " \t\r");
        return trimmed.len != 0 and !std.ascii.eqlIgnoreCase(trimmed, "a");
    }
    return false;
}

fn mnemonicIn(mnemonic: []const u8, list: []const []const u8) bool {
    for (list) |candidate| {
        if (std.ascii.eqlIgnoreCase(mnemonic, candidate)) return true;
    }
    return false;
}

fn isInlineAsmByteType(ty: ast.Type) bool {
    return switch (ty) {
        .bool, .u8, .i8, .custom => true,
        else => false,
    };
}
