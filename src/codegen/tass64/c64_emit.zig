const std = @import("std");
const ast = @import("../../ast.zig");
const bindings = @import("bindings.zig");
const runtime = @import("runtime.zig");
const types = @import("types.zig");

const StringBufferRef = bindings.StringBufferRef;
const StringSource = bindings.StringSource;

const colorAddress = runtime.colorAddress;
const colorAddressFromScreen = runtime.colorAddressFromScreen;
const constU8 = types.constU8;
const exprAsValue = types.exprAsValue;
const nextPrintArg = runtime.nextPrintArg;
const screenAddress = runtime.screenAddress;
const screenCode = runtime.screenCode;

pub fn emitBuiltin(self: anytype, function_name: []const u8, builtin: ast.BuiltinCall) !void {
    switch (builtin) {
        .screen_clear => {
            self.uses_clear_screen = true;
            try self.out.writer.writeAll("    jsr clearScreen\n");
        },
        .puts_at => |puts| try emitPutsAt(self, puts),
        .put_at => |put| try emitPutAt(self, function_name, put),
        .hex_at => |hex| try emitHexAt(self, function_name, hex),
        .hex16_at => |hex| try emitHex16At(self, function_name, hex),
        .console_clear => try emitConsoleClear(self, function_name),
        .console_print => |print| try emitConsolePrint(self, function_name, print),
        .console_puts => |value| try emitConsolePuts(self, function_name, value),
        .string_append => |append| try emitStringAppend(self, function_name, append),
        .string_clear => |value| try emitStringClear(self, function_name, value),
        .kernal_puts => |value| try emitKernalPuts(self, function_name, value),
        .kernal_set_name => |value| try emitKernalSetName(self, function_name, value),
        .sleep_ticks => |sleep| try emitSleepTicks(self, function_name, sleep),
        .sleep_frames => |sleep| try emitSleepFrames(self, function_name, sleep),
    }
}

pub fn emitConsoleClear(self: anytype, function_name: []const u8) !void {
    self.uses_console = true;
    self.uses_clear_screen = true;
    try self.emitConsoleRuntimeCall(function_name, "consoleClear");
}

pub fn emitConsolePrint(self: anytype, function_name: []const u8, print: ast.ConsolePrint) !void {
    self.uses_console = true;
    var arg_index: usize = 0;
    var i: usize = 0;
    while (i < print.format.len) {
        if (print.format[i] == '\\' and i + 1 < print.format.len and print.format[i + 1] == 'n') {
            try self.emitConsoleRuntimeCall(function_name, "consoleNewline");
            i += 2;
        } else if (print.format[i] == '{') {
            if (std.mem.startsWith(u8, print.format[i..], "{s}")) {
                const arg = try nextPrintArg(print, &arg_index);
                switch (arg) {
                    .string => |text| try emitConsoleLiteral(self, function_name, text),
                    .value => |expr| try emitConsoleStringExpr(self, function_name, expr),
                }
                i += 3;
            } else if (std.mem.startsWith(u8, print.format[i..], "{x16}")) {
                const arg = try nextPrintArg(print, &arg_index);
                switch (arg) {
                    .value => |expr| try emitConsoleHex16Expr(self, function_name, expr),
                    else => return error.UnsupportedFormatArgument,
                }
                i += 5;
            } else if (std.mem.startsWith(u8, print.format[i..], "{x}")) {
                const arg = try nextPrintArg(print, &arg_index);
                switch (arg) {
                    .value => |expr| try emitConsoleHexExpr(self, function_name, expr),
                    else => return error.UnsupportedFormatArgument,
                }
                i += 3;
            } else {
                return error.UnsupportedFormatString;
            }
        } else {
            try emitConsoleChar(self, function_name, print.format[i]);
            i += 1;
        }
    }
    if (arg_index != print.args.len) return error.UnusedFormatArgument;
}

pub fn emitConsoleLiteral(self: anytype, function_name: []const u8, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == 'n') {
            try self.emitConsoleRuntimeCall(function_name, "consoleNewline");
            i += 2;
        } else {
            try emitConsoleChar(self, function_name, text[i]);
            i += 1;
        }
    }
}

pub fn emitConsoleChar(self: anytype, function_name: []const u8, ch: u8) !void {
    try self.out.writer.print("    lda #{d}\n", .{screenCode(ch)});
    try self.emitConsoleRuntimeCall(function_name, "consolePutChar");
}

pub fn emitConsolePuts(self: anytype, function_name: []const u8, value: ast.Value) !void {
    self.uses_console = true;
    const source = try resolveStringSource(self, function_name, value);
    try emitLoadStringSourcePointer(self, "zeropage_string_ptr", source);
    try emitStringSourceLenToA(self, source);
    try self.emitConsoleRuntimeCall(function_name, "consolePutString");
}

pub fn emitConsoleStringExpr(self: anytype, function_name: []const u8, expr: ast.Expr) !void {
    const value = try exprAsValue(expr);
    try emitConsolePuts(self, function_name, value);
}

pub fn emitStringAppend(self: anytype, function_name: []const u8, append: ast.StringAppend) !void {
    const buffer = try expectStringBuffer(self, function_name, append.target);
    try emitAppendStringExpr(self, function_name, buffer, append.expr);
}

pub fn emitStringClear(self: anytype, function_name: []const u8, value: ast.Value) !void {
    const buffer = try expectStringBuffer(self, function_name, value);
    try self.out.writer.print("    lda #0\n    sta {s}_{s}_len\n", .{ buffer.function_name, buffer.name });
}

pub fn emitKernalPuts(self: anytype, function_name: []const u8, value: ast.Value) !void {
    self.uses_kernal_string = true;
    const source = try resolveStringSource(self, function_name, value);
    try emitLoadStringSourcePointer(self, "zeropage_kernal_ptr", source);
    try emitStringSourceLenToA(self, source);
    try self.out.writer.writeAll("    jsr kernalPutString\n");
}

pub fn emitKernalSetName(self: anytype, function_name: []const u8, value: ast.Value) !void {
    const source = try resolveStringSource(self, function_name, value);
    try emitStringSourceLenToA(self, source);
    switch (source) {
        .constant => |constant| try self.out.writer.print(
            "    ldx #<zeropage_str_{s}\n    ldy #>zeropage_str_{s}\n    jsr $ffbd\n",
            .{ constant.name, constant.name },
        ),
        .buffer => |buffer| try self.out.writer.print(
            "    ldx #<{s}_{s}_data\n    ldy #>{s}_{s}_data\n    jsr $ffbd\n",
            .{ buffer.function_name, buffer.name, buffer.function_name, buffer.name },
        ),
    }
}

pub fn emitAppendStringExpr(self: anytype, function_name: []const u8, buffer: StringBufferRef, expr: ast.StringExpr) !void {
    for (expr.parts) |part| {
        switch (part) {
            .literal => |bytes| {
                for (bytes) |byte| try emitAppendByteToBuffer(self, buffer, byte);
            },
            .ident => |ident| {
                const source = try resolveStringIdent(self, function_name, ident);
                try emitAppendStringSource(self, buffer, source);
            },
        }
    }
}

pub fn emitAppendByteToBuffer(self: anytype, buffer: StringBufferRef, byte: u8) !void {
    const w = &self.out.writer;
    const id = self.nextLabel();
    try w.print("    lda {s}_{s}_len\n    cmp #{d}\n    bcs string_byte_{d}_done\n", .{ buffer.function_name, buffer.name, buffer.capacity, id });
    try w.print("    tay\n    lda #{d}\n    sta {s}_{s}_data,y\n", .{ byte, buffer.function_name, buffer.name });
    try w.print("    inc {s}_{s}_len\nstring_byte_{d}_done:\n", .{ buffer.function_name, buffer.name, id });
}

pub fn emitAppendStringSource(self: anytype, buffer: StringBufferRef, source: StringSource) !void {
    self.uses_string_runtime = true;
    try emitLoadStringSourcePointer(self, "zeropage_string_src_ptr", source);
    try self.out.writer.print(
        "    lda #<{s}_{s}_data\n    sta zeropage_string_dst_ptr\n    lda #>{s}_{s}_data\n    sta zeropage_string_dst_ptr+1\n",
        .{ buffer.function_name, buffer.name, buffer.function_name, buffer.name },
    );
    try emitStringSourceLenToA(self, source);
    try self.out.writer.writeAll("    sta zeropage_string_src_len\n");
    try self.out.writer.print(
        "    lda {s}_{s}_len\n    sta zeropage_string_dst_len\n    lda #{d}\n    sta zeropage_string_dst_cap\n    jsr stringAppend\n    lda zeropage_string_dst_len\n    sta {s}_{s}_len\n",
        .{ buffer.function_name, buffer.name, buffer.capacity, buffer.function_name, buffer.name },
    );
}

pub fn emitLoadStringSourcePointer(self: anytype, pointer_name: []const u8, source: StringSource) !void {
    switch (source) {
        .constant => |constant| try self.out.writer.print(
            "    lda #<zeropage_str_{s}\n    sta {s}\n    lda #>zeropage_str_{s}\n    sta {s}+1\n",
            .{ constant.name, pointer_name, constant.name, pointer_name },
        ),
        .buffer => |buffer| try self.out.writer.print(
            "    lda #<{s}_{s}_data\n    sta {s}\n    lda #>{s}_{s}_data\n    sta {s}+1\n",
            .{ buffer.function_name, buffer.name, pointer_name, buffer.function_name, buffer.name, pointer_name },
        ),
    }
}

pub fn emitStringSourceLenToA(self: anytype, source: StringSource) !void {
    switch (source) {
        .constant => |constant| try self.out.writer.print("    lda #{d}\n", .{constant.bytes.len}),
        .buffer => |buffer| try self.out.writer.print("    lda {s}_{s}_len\n", .{ buffer.function_name, buffer.name }),
    }
}

pub fn resolveStringSource(self: anytype, function_name: []const u8, value: ast.Value) !StringSource {
    return switch (value) {
        .ident => |ident| try resolveStringIdent(self, function_name, ident),
        else => error.UnsupportedFormatArgument,
    };
}

fn resolveStringIdent(self: anytype, function_name: []const u8, ident: []const u8) !StringSource {
    if (self.program.findString(ident)) |constant| return .{ .constant = constant };
    if (self.findStringBuffer(function_name, ident)) |buffer| return .{ .buffer = buffer };
    return error.UnknownStringConstant;
}

fn expectStringBuffer(self: anytype, function_name: []const u8, value: ast.Value) !StringBufferRef {
    return switch (value) {
        .ident => |ident| self.findStringBuffer(function_name, ident) orelse return error.UnknownStringBuffer,
        else => error.UnsupportedFormatArgument,
    };
}

pub fn emitConsoleHexExpr(self: anytype, function_name: []const u8, expr: ast.Expr) !void {
    self.uses_hex = true;
    self.uses_console_hex = true;
    if (exprNamesStringConstant(self, expr)) return error.UnsupportedFormatArgument;
    try self.emitExprToA(function_name, expr);
    try self.emitConsoleRuntimeCall(function_name, "consolePutHexByte");
}

pub fn emitConsoleHex16Expr(self: anytype, function_name: []const u8, expr: ast.Expr) !void {
    self.uses_hex = true;
    self.uses_console_hex = true;
    const value = try exprAsValue(expr);
    if (valueNamesStringConstant(self, value)) return error.UnsupportedFormatArgument;
    switch (value) {
        .int => |n| {
            try self.out.writer.print("    lda #{d}\n", .{@as(u8, @truncate(n >> 8))});
            try self.emitConsoleRuntimeCall(function_name, "consolePutHexByte");
            try self.out.writer.print("    lda #{d}\n", .{@as(u8, @truncate(n))});
            try self.emitConsoleRuntimeCall(function_name, "consolePutHexByte");
        },
        .ident => |ident| {
            try self.out.writer.print("    lda {s}_{s}+1\n", .{ function_name, ident });
            try self.emitConsoleRuntimeCall(function_name, "consolePutHexByte");
            try self.out.writer.print("    lda {s}_{s}\n", .{ function_name, ident });
            try self.emitConsoleRuntimeCall(function_name, "consolePutHexByte");
        },
        .field => |field| {
            try self.out.writer.writeAll("    lda #0\n");
            try self.emitConsoleRuntimeCall(function_name, "consolePutHexByte");
            try self.out.writer.print("    lda {s}_{s}_{s}\n", .{ function_name, field.base, field.field });
            try self.emitConsoleRuntimeCall(function_name, "consolePutHexByte");
        },
        else => return error.UnsupportedExpression,
    }
}

fn exprNamesStringConstant(self: anytype, expr: ast.Expr) bool {
    return switch (expr) {
        .value => |value| valueNamesStringConstant(self, value),
        else => false,
    };
}

fn valueNamesStringConstant(self: anytype, value: ast.Value) bool {
    return switch (value) {
        .ident => |ident| self.program.findString(ident) != null,
        else => false,
    };
}

pub fn emitSleepTicks(self: anytype, function_name: []const u8, sleep: ast.SleepTicks) !void {
    self.uses_sleep = true;
    try self.emitExprToA(function_name, sleep.ticks);
    try self.out.writer.writeAll("    jsr sleepTicks\n");
}

pub fn emitSleepFrames(self: anytype, function_name: []const u8, sleep: ast.SleepTicks) !void {
    self.uses_sleep_frames = true;
    try self.emitExprToA(function_name, sleep.ticks);
    try self.out.writer.writeAll("    jsr sleepFrames\n");
}

pub fn emitKeyboardReadPetscii(self: anytype) !void {
    try self.out.writer.writeAll("    jsr $ffe4\n");
}

pub fn emitKeyboardWaitPetscii(self: anytype) !void {
    self.uses_keyboard_wait = true;
    try self.out.writer.writeAll("    jsr keyboardWaitPetscii\n");
}

pub fn emitPutsAt(self: anytype, puts: ast.PutsAt) !void {
    const w = &self.out.writer;
    const x = try constU8(puts.x);
    const y = try constU8(puts.y);
    const screen_start = screenAddress(x, y);
    const color_start = colorAddress(x, y);
    for (puts.text, 0..) |ch, i| {
        try w.print("    lda #{d}\n    sta ${x:0>4}\n", .{ screenCode(ch), screen_start + @as(u16, @intCast(i)) });
        try w.print("    lda #1\n    sta ${x:0>4}\n", .{color_start + @as(u16, @intCast(i))});
    }
}

pub fn emitPutAt(self: anytype, function_name: []const u8, put: ast.PutAt) !void {
    const w = &self.out.writer;
    const y = try constU8(put.y);
    switch (put.x) {
        .value => |value| switch (value) {
            .int => |n| {
                const x = std.math.cast(u8, n) orelse return error.Overflow;
                try self.emitExprToA(function_name, put.ch);
                try w.print("    sta ${x:0>4}\n", .{screenAddress(x, y)});
                try w.print("    lda #3\n    sta ${x:0>4}\n", .{colorAddress(x, y)});
            },
            else => {
                self.uses_screen_tmp = true;
                try self.emitExprToA(function_name, put.ch);
                try w.writeAll("    sta zeropage_screen_tmp\n");
                try emitValueToX(self, function_name, value);
                try w.writeAll("    lda zeropage_screen_tmp\n");
                try w.print("    sta ${x:0>4},x\n", .{screenAddress(0, y)});
                try w.print("    lda #3\n    sta ${x:0>4},x\n", .{colorAddress(0, y)});
            },
        },
        .base_plus => |base_plus| {
            self.uses_screen_tmp = true;
            try self.emitExprToA(function_name, put.ch);
            try w.writeAll("    sta zeropage_screen_tmp\n");
            try emitValueToX(self, function_name, base_plus.offset);
            try w.writeAll("    lda zeropage_screen_tmp\n");
            try w.print("    sta ${x:0>4},x\n", .{screenAddress(base_plus.base, y)});
            try w.print("    lda #3\n    sta ${x:0>4},x\n", .{colorAddress(base_plus.base, y)});
        },
    }
}

pub fn emitHexAt(self: anytype, function_name: []const u8, hex: ast.HexAt) !void {
    self.uses_hex = true;
    const x = try constU8(hex.x);
    const y = try constU8(hex.y);
    try self.emitExprToA(function_name, hex.value);
    try emitHexByteAt(self, screenAddress(x, y));
}

pub fn emitHex16At(self: anytype, function_name: []const u8, hex: ast.HexAt) !void {
    self.uses_hex = true;
    const x = try constU8(hex.x);
    const y = try constU8(hex.y);
    const screen_start = screenAddress(x, y);
    const value = try exprAsValue(hex.value);

    switch (value) {
        .int => |n| {
            try self.out.writer.print("    lda #{d}\n", .{@as(u8, @truncate(n >> 8))});
            try emitHexByteAt(self, screen_start);
            try self.out.writer.print("    lda #{d}\n", .{@as(u8, @truncate(n))});
            try emitHexByteAt(self, screen_start + 2);
        },
        .ident => |ident| {
            try self.out.writer.print("    lda {s}_{s}+1\n", .{ function_name, ident });
            try emitHexByteAt(self, screen_start);
            try self.out.writer.print("    lda {s}_{s}\n", .{ function_name, ident });
            try emitHexByteAt(self, screen_start + 2);
        },
        .field => |field| {
            try self.out.writer.writeAll("    lda #0\n");
            try emitHexByteAt(self, screen_start);
            try self.out.writer.print("    lda {s}_{s}_{s}\n", .{ function_name, field.base, field.field });
            try emitHexByteAt(self, screen_start + 2);
        },
        else => return error.UnsupportedExpression,
    }
}

pub fn emitHexByteAt(self: anytype, screen_start: u16) !void {
    const w = &self.out.writer;
    try w.writeAll("    sta zeropage_hex_tmp\n");
    try w.writeAll("    lsr\n    lsr\n    lsr\n    lsr\n    jsr hexNibbleToScreen\n");
    try w.print("    sta ${x:0>4}\n", .{screen_start});
    try w.writeAll("    lda zeropage_hex_tmp\n    jsr hexNibbleToScreen\n");
    try w.print("    sta ${x:0>4}\n", .{screen_start + 1});
    try w.print("    lda #7\n    sta ${x:0>4}\n    sta ${x:0>4}\n", .{ colorAddressFromScreen(screen_start), colorAddressFromScreen(screen_start + 1) });
}

pub fn emitValueToX(self: anytype, function_name: []const u8, value: ast.Value) !void {
    try self.emitValueToA(function_name, value);
    try self.out.writer.writeAll("    tax\n");
}
