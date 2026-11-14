const std = @import("std");
const ast = @import("../../ast.zig");

pub fn emitCall(self: anytype, function_name: []const u8, call: ast.Test6502Call) !void {
    switch (call) {
        .expect_null => |expect| return try self.emitTest6502ExpectNull(function_name, expect),
        .expect_some_u8 => |expect| return try self.emitTest6502ExpectSome(function_name, expect, .u8),
        .expect_some_u16 => |expect| return try self.emitTest6502ExpectSome(function_name, expect, .u16),
        .expect_some_bool => |expect| return try self.emitTest6502ExpectSome(function_name, expect, .bool),
        .expect_some_ptr => |expect| return try self.emitTest6502ExpectSome(function_name, expect, .usize),
        else => {},
    }
    const label = try labelForCall(self, call);
    const stable_label = try ensureHook(self, label);
    switch (call) {
        .expect_equal_u8 => |expect| try self.emitExprToA(function_name, expect.actual),
        .expect_equal_i8 => |expect| try self.emitExprToA(function_name, expect.actual),
        .expect_equal_bool => |expect| try self.emitExprToA(function_name, expect.actual),
        .expect_equal_u16 => |expect| try self.emitExprToAX(function_name, expect.actual),
        .expect_string => |expect| {
            const source = try self.resolveStringSource(function_name, expect.actual);
            try self.emitLoadStringSourcePointer("zeropage_string_ptr", source);
            try self.emitStringSourceLenToA(source);
        },
        else => {},
    }
    try self.out.writer.print("    jsr {s}\n", .{stable_label});
}

pub fn labelForCall(self: anytype, call: ast.Test6502Call) ![]const u8 {
    return switch (call) {
        .mark => |id| std.fmt.allocPrint(self.allocator, "zeropage_test6502_mark_{x:0>4}", .{id}),
        .prime_regs => |prime| std.fmt.allocPrint(self.allocator, "zeropage_test6502_prime_regs_{x:0>4}_{x:0>4}_{x:0>4}_{x:0>4}_{x:0>4}", .{ prime.id, prime.a, prime.x, prime.y, prime.p }),
        .hit => |id| std.fmt.allocPrint(self.allocator, "zeropage_test6502_hit_{x:0>4}", .{id}),
        .expect_hit_count => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_hit_count_{x:0>4}_{x:0>4}", .{ expect.id, expect.expected }),
        .snapshot => |id| std.fmt.allocPrint(self.allocator, "zeropage_test6502_snapshot_{x:0>4}", .{id}),
        .expect_equal_u8 => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_equal_u8_{x:0>4}_{x:0>4}", .{ expect.id, expect.expected }),
        .expect_equal_i8 => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_equal_i8_{x:0>4}_{x:0>4}", .{ expect.id, expect.expected }),
        .expect_equal_bool => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_equal_bool_{x:0>4}_{x:0>4}", .{ expect.id, expect.expected }),
        .expect_equal_u16 => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_equal_u16_{x:0>4}_{x:0>4}", .{ expect.id, expect.expected }),
        .expect_null => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_equal_bool_{x:0>4}_0000", .{expect.id}),
        .expect_some_u8 => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_equal_u8_{x:0>4}_{x:0>4}", .{ expect.id, expect.expected }),
        .expect_some_u16 => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_equal_u16_{x:0>4}_{x:0>4}", .{ expect.id, expect.expected }),
        .expect_some_bool => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_equal_bool_{x:0>4}_{x:0>4}", .{ expect.id, expect.expected }),
        .expect_some_ptr => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_equal_u16_{x:0>4}_{x:0>4}", .{ expect.id, expect.expected }),
        .expect_string => |expect| try stringLabel(self, expect),
        .expect_a => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_a_{x:0>4}_{x:0>4}", .{ expect.id, expect.expected }),
        .expect_x => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_x_{x:0>4}_{x:0>4}", .{ expect.id, expect.expected }),
        .expect_y => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_y_{x:0>4}_{x:0>4}", .{ expect.id, expect.expected }),
        .expect_sp => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_sp_{x:0>4}_{x:0>4}", .{ expect.id, expect.expected }),
        .expect_p => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_p_{x:0>4}_{x:0>4}_{x:0>4}", .{ expect.id, expect.mask, expect.expected }),
        .expect_mem_u8 => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_mem_u8_{x:0>4}_{x:0>4}_{x:0>4}", .{ expect.id, expect.addr, expect.expected }),
        .expect_mem_u16 => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_mem_u16_{x:0>4}_{x:0>4}_{x:0>4}", .{ expect.id, expect.addr, expect.expected }),
        .expect_stack_u8 => |expect| std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_stack_u8_{x:0>4}_{x:0>4}_{x:0>4}", .{ expect.id, expect.offset, expect.expected }),
        .pass => std.fmt.allocPrint(self.allocator, "zeropage_test6502_pass", .{}),
        .fail => |code| std.fmt.allocPrint(self.allocator, "zeropage_test6502_fail_{x:0>4}", .{code}),
    };
}

pub fn stringLabel(self: anytype, expect: ast.ExpectString) ![]const u8 {
    var hex: std.ArrayList(u8) = .empty;
    defer hex.deinit(self.allocator);
    for (expect.expected) |byte| {
        var buf: [2]u8 = undefined;
        _ = try std.fmt.bufPrint(&buf, "{x:0>2}", .{byte});
        try hex.appendSlice(self.allocator, &buf);
    }
    return std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_string_{x:0>4}_{x:0>4}_{s}", .{ expect.id, expect.expected.len, hex.items });
}

pub fn ensureHook(self: anytype, label: []const u8) ![]const u8 {
    if (self.test_hook_labels.getKey(label)) |existing| {
        self.allocator.free(label);
        return existing;
    }
    try self.test_hook_labels.put(label, {});
    try self.test_hook_order.append(self.allocator, label);
    return label;
}

pub fn emitStubs(self: anytype) !void {
    if (self.test_hook_order.items.len == 0) return;
    const w = &self.out.writer;
    try w.writeAll("\n; host emulator test hooks\n");
    for (self.test_hook_order.items) |label| {
        try w.print("{s}:\n    rts\n", .{label});
    }
}
