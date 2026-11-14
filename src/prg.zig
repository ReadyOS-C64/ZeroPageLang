const std = @import("std");

pub const Prg = struct {
    load_address: u16,
    payload: []const u8,
};

pub fn read(bytes: []const u8) !Prg {
    if (bytes.len < 2) return error.InvalidPrg;
    return .{
        .load_address = @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8),
        .payload = bytes[2..],
    };
}

pub fn write(allocator: std.mem.Allocator, load_address: u16, payload: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, payload.len + 2);
    out[0] = @intCast(load_address & 0x00ff);
    out[1] = @intCast(load_address >> 8);
    @memcpy(out[2..], payload);
    return out;
}

pub fn loadIntoMemory(memory: *[65536]u8, bytes: []const u8) !void {
    const parsed = try read(bytes);
    const start: usize = parsed.load_address;
    const end = start + parsed.payload.len;
    if (end > memory.len) return error.PrgTooLarge;
    @memcpy(memory[start..end], parsed.payload);
}

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) !PrgFile {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(16 * 1024 * 1024));
    errdefer allocator.free(bytes);
    const parsed = try read(bytes);
    return .{ .bytes = bytes, .prg = parsed };
}

pub const PrgFile = struct {
    bytes: []u8,
    prg: Prg,

    pub fn deinit(self: PrgFile, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

test "PRG helper reads two byte little endian load address" {
    const bytes = [_]u8{ 0x01, 0x08, 0xaa, 0xbb };
    const parsed = try read(&bytes);
    try std.testing.expectEqual(@as(u16, 0x0801), parsed.load_address);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, parsed.payload);
}

test "PRG helper writes and loads into 64 KiB memory" {
    const bytes = try write(std.testing.allocator, 0x0801, &.{ 0xa9, 0x06, 0x8d, 0x20, 0xd0 });
    defer std.testing.allocator.free(bytes);

    var memory = [_]u8{0} ** 65536;
    try loadIntoMemory(&memory, bytes);
    try std.testing.expectEqual(@as(u8, 0xa9), memory[0x0801]);
    try std.testing.expectEqual(@as(u8, 0xd0), memory[0x0805]);
}
