const std = @import("std");
const prg = @import("../prg.zig");

pub const Memory = struct {
    bytes: [65536]u8 = [_]u8{0} ** 65536,

    pub fn loadPrg(self: *Memory, data: []const u8) !void {
        try prg.loadIntoMemory(&self.bytes, data);
    }

    pub fn read(self: *const Memory, addr: u16) u8 {
        return self.bytes[addr];
    }

    pub fn write(self: *Memory, addr: u16, value: u8) void {
        self.bytes[addr] = value;
    }
};

test "host memory loads PRG payload at load address" {
    const bytes = [_]u8{ 0x0d, 0x08, 0xa9, 0x06 };
    var mem = Memory{};
    try mem.loadPrg(&bytes);
    try std.testing.expectEqual(@as(u8, 0xa9), mem.read(0x080d));
    try std.testing.expectEqual(@as(u8, 0x06), mem.read(0x080e));
}

