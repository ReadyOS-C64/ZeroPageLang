const std = @import("std");
const ShiftOp = @import("expr.zig").ShiftOp;

pub const Usage = struct {
    dynamic_left: bool = false,
    dynamic_right: bool = false,
    left_counts: u16 = 0,
    right_counts: u16 = 0,
    uses_value: bool = false,

    pub fn dynamic(self: *Usage, op: ShiftOp) void {
        self.uses_value = true;
        if (op == .shl) self.dynamic_left = true else self.dynamic_right = true;
    }
    pub fn needsCount(self: Usage) bool {
        return self.dynamic_left or self.dynamic_right;
    }

    // Preserve the old helper's final NZ (high byte), carry, A/X/Y and SP.
    // These inline forms never exceed the old 14-byte literal call setup.
    pub fn emitConstant(self: *Usage, writer: anytype, op: ShiftOp, count: u16) !void {
        std.debug.assert(count < 16);
        if (op == .shr and count >= 8) {
            if (count == 8) try writer.writeAll("    asl\n"); // carry = original low byte bit 7
            try writer.writeAll("    txa\n");
            for (8..count) |_| try writer.writeAll("    lsr\n");
            try writer.writeAll("    ldx #0\n");
            return;
        }
        self.uses_value = true;
        if (count == 0) {
            try writer.writeAll("    stx zeropage_shift_value+1\n    ldx zeropage_shift_value+1\n");
            return;
        }
        if (count == 1) {
            if (op == .shl) {
                try writer.writeAll("    asl\n    pha\n    txa\n    rol\n    tax\n    pla\n");
            } else try writer.writeAll("    pha\n    txa\n    lsr\n    tax\n    pla\n    ror\n");
            try writer.writeAll("    stx zeropage_shift_value+1\n    ldx zeropage_shift_value+1\n");
            return;
        }
        if (op == .shl and count >= 8 and count <= 13) {
            if (count == 8) {
                // A is the old low byte. Recover carry from the old high byte.
                try writer.writeAll("    pha\n    txa\n    lsr\n    pla\n");
            } else for (8..count) |_| try writer.writeAll("    asl\n");
            try writer.writeAll("    tax\n    lda #0\n    stx zeropage_shift_value+1\n    ldx zeropage_shift_value+1\n");
            return;
        }
        if (op == .shl) self.left_counts |= @as(u16, 1) << @intCast(count) else self.right_counts |= @as(u16, 1) << @intCast(count);
        try writer.print("    jsr zeropage_{s}16_const_{d}\n", .{ if (op == .shl) "shl" else "shr", count });
    }

    pub fn emitHelpers(self: Usage, writer: anytype) !void {
        try emitLargeLeft(writer, self.left_counts);
        try emitDirection(writer, "shl", "asl", "rol", self.dynamic_left, self.left_counts & 0x3fff);
        try emitDirection(writer, "shr", "lsr", "ror", self.dynamic_right, self.right_counts);
    }
};

fn emitLargeLeft(writer: anytype, counts: u16) !void {
    if (counts & 0xc000 == 0) return;
    // Left 15 falls through left 14's six byte shifts. With both counts this
    // costs 17 bytes total, less than two ordinary shared-kernel prologues.
    // The final ASL supplies the old loop's carry; reloading X supplies NZ.
    if (counts & 0x8000 != 0) try writer.writeAll("zeropage_shl16_const_15:\n    asl\n");
    if (counts & 0x4000 != 0) try writer.writeAll("zeropage_shl16_const_14:\n");
    for (0..6) |_| try writer.writeAll("    asl\n");
    try writer.writeAll("    tax\n    lda #0\n    stx zeropage_shift_value+1\n    ldx zeropage_shift_value+1\n    rts\n\n");
}

fn emitDirection(writer: anytype, name: []const u8, first: []const u8, second: []const u8, dynamic: bool, counts: u16) !void {
    if (!dynamic and counts == 0) return;
    for (1..16) |count| {
        if (counts & (@as(u16, 1) << @intCast(count)) == 0) continue;
        try writer.print("zeropage_{s}16_const_{d}:\n    sta zeropage_shift_value\n    stx zeropage_shift_value+1\n    ldx #{d}\n", .{ name, count, count });
        // The final constant prologue can fall into the kernel if no dynamic
        // entry needs to load a count. Other prologues share that same kernel.
        if (dynamic or counts >> @intCast(count) != 1) try writer.print("    jmp zeropage_{s}16_loop\n", .{name});
    }
    if (dynamic) try writer.print("zeropage_{s}16:\n    sta zeropage_shift_value\n    stx zeropage_shift_value+1\n    ldx zeropage_shift_count\n    beq zeropage_{s}16_done\n", .{ name, name });
    try writer.print("zeropage_{s}16_loop:\n", .{name});
    if (std.mem.eql(u8, name, "shl")) {
        try writer.print("    {s} zeropage_shift_value\n    {s} zeropage_shift_value+1\n", .{ first, second });
    } else try writer.print("    {s} zeropage_shift_value+1\n    {s} zeropage_shift_value\n", .{ first, second });
    try writer.print("    dex\n    bne zeropage_{s}16_loop\nzeropage_{s}16_done:\n    lda zeropage_shift_value\n    ldx zeropage_shift_value+1\n    rts\n\n", .{ name, name });
}

test "large right shifts need no helper or scratch and retain carry" {
    var usage: Usage = .{};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try usage.emitConstant(&out.writer, .shr, 8);
    try std.testing.expectEqualStrings("    asl\n    txa\n    ldx #0\n", out.written());
    try std.testing.expect(!usage.uses_value and !usage.needsCount());
    try usage.emitHelpers(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "zeropage_") == null);
}

test "constant entries share kernels and unused directions or counts are absent" {
    var usage: Usage = .{};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try usage.emitConstant(&out.writer, .shl, 2);
    try usage.emitConstant(&out.writer, .shl, 2);
    try usage.emitConstant(&out.writer, .shl, 3);
    try usage.emitHelpers(&out.writer);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "zeropage_shl16_const_2:"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "zeropage_shl16_loop:"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "zeropage_shr16") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "zeropage_shift_count") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "ldx #3\nzeropage_shl16_loop:") != null);
}

test "dynamic helpers use X as counter and remain independent by direction" {
    var usage: Usage = .{};
    usage.dynamic(.shr);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try usage.emitHelpers(&out.writer);
    try std.testing.expect(usage.needsCount() and usage.uses_value);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "ldx zeropage_shift_count") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "dex\n    bne zeropage_shr16_loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "dec zeropage_shift_count") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "zeropage_shl16") == null);
}

test "large left counts share a fallthrough byte helper without a loop" {
    var usage: Usage = .{};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try usage.emitConstant(&out.writer, .shl, 14);
    try usage.emitConstant(&out.writer, .shl, 15);
    try usage.emitHelpers(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "zeropage_shl16_const_15:\n    asl\nzeropage_shl16_const_14:\n") != null);
    try std.testing.expectEqual(@as(usize, 7), std.mem.count(u8, out.written(), "    asl\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "zeropage_shl16_loop") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "zeropage_shift_count") == null);
    try std.testing.expect(usage.uses_value);
}

test "a single large left helper coexists with a dynamic kernel" {
    var usage: Usage = .{};
    usage.dynamic(.shl);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try usage.emitConstant(&out.writer, .shl, 15);
    try usage.emitHelpers(&out.writer);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "zeropage_shl16_const_15:"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "zeropage_shl16_const_14:") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "zeropage_shl16_loop:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "ldx #15") == null);
}
