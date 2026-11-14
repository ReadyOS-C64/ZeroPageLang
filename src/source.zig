const std = @import("std");

pub const SourceFile = struct {
    path: []const u8,
    bytes: []const u8,

    pub fn deinit(self: SourceFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.bytes);
    }
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !SourceFile {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(16 * 1024 * 1024));
    return .{ .path = owned_path, .bytes = bytes };
}

test "source loader reads fixture" {
    const src = try load(std.testing.allocator, "zeropage_microcompiler_agent_spec.md");
    defer src.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, src.bytes, "# ZeroPage Microcompiler"));
}
