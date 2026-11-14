const std = @import("std");

pub const ToolName = enum {
    zig,
    tass64,
    vice_x64sc,

    pub fn envVar(self: ToolName) []const u8 {
        return switch (self) {
            .zig => "ZEROPAGE_ZIG",
            .tass64 => "ZEROPAGE_64TASS",
            .vice_x64sc => "ZEROPAGE_VICE_X64SC",
        };
    }

    pub fn executableName(self: ToolName) []const u8 {
        return switch (self) {
            .zig => "zig",
            .tass64 => "64tass",
            .vice_x64sc => "x64sc",
        };
    }
};

pub const ResolvedTool = struct {
    path: []const u8,
    source: Source,

    pub const Source = enum { env, local, path };
};

pub fn resolve(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map, name: ToolName) !?ResolvedTool {
    if (env_map.get(name.envVar())) |env_path| {
        if (isExecutable(io, env_path)) return .{ .path = try allocator.dupe(u8, env_path), .source = .env };
    }

    const local = localCandidates(name);
    for (local) |candidate| {
        if (isExecutable(io, candidate)) {
            return .{ .path = try allocator.dupe(u8, candidate), .source = .local };
        }
    }

    if (try findOnPath(allocator, io, env_map, name.executableName())) |path| {
        return .{ .path = path, .source = .path };
    }
    return null;
}

pub fn freeResolved(allocator: std.mem.Allocator, tool: ResolvedTool) void {
    allocator.free(tool.path);
}

fn localCandidates(name: ToolName) []const []const u8 {
    return switch (name) {
        .zig => &[_][]const u8{
            "../zeropage-tooling/bin/zig",
            "../zeropage-tooling/zig/0.16.0/zig",
            "../zeropage-tooling/zig/0.16.0/zig-macos-aarch64-0.16.0/zig",
            "../zeropage-tooling/zig/0.16.0/zig-aarch64-macos-0.16.0/zig",
        },
        .tass64 => &[_][]const u8{
            "../zeropage-tooling/bin/64tass",
            "../zeropage-tooling/tass64/1.60.3243/bin/64tass",
            "../zeropage-tooling/tass64/1.60.3243/64tass",
        },
        .vice_x64sc => &[_][]const u8{
            "../zeropage-tooling/bin/x64sc",
            "/opt/homebrew/bin/x64sc",
        },
    };
}

fn isExecutable(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn findOnPath(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map, exe: []const u8) !?[]const u8 {
    const path_env = env_map.get("PATH") orelse return null;

    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ dir, exe });
        if (isExecutable(io, candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

pub fn describe(tool: ?ResolvedTool) []const u8 {
    if (tool == null) return "missing";
    return switch (tool.?.source) {
        .env => "env",
        .local => "local",
        .path => "path",
    };
}

test "tool source descriptions include env local path and missing" {
    try std.testing.expectEqualStrings("missing", describe(null));
    try std.testing.expectEqualStrings("env", describe(.{ .path = "/tmp/tool", .source = .env }));
    try std.testing.expectEqualStrings("local", describe(.{ .path = "/tmp/tool", .source = .local }));
    try std.testing.expectEqualStrings("path", describe(.{ .path = "/tmp/tool", .source = .path }));
}
