const std = @import("std");

pub const Diagnostic = struct {
    path: []const u8,
    line: usize = 1,
    column: usize = 1,
    severity: Severity = .err,
    message: []const u8,
    note: ?[]const u8 = null,

    pub const Severity = enum { err, warning, note };

    pub fn render(self: Diagnostic, writer: anytype) !void {
        const sev = switch (self.severity) {
            .err => "error",
            .warning => "warning",
            .note => "note",
        };
        try writer.print("{s}:{}:{}: {s}: {s}\n", .{ self.path, self.line, self.column, sev, self.message });
        if (self.note) |note| try writer.print("note: {s}\n", .{note});
    }
};

pub fn unsupportedStdImport(path: []const u8) Diagnostic {
    return .{
        .path = path,
        .message = "full Zig standard library is not available for target c64-6510; use @import(\"c64\") or @import(\"ZeroPage\")",
    };
}

pub fn unsupportedFeature(path: []const u8, feature: []const u8, note: []const u8) Diagnostic {
    return .{
        .path = path,
        .message = feature,
        .note = note,
    };
}

test "diagnostic renders zig-like location and note" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try (Diagnostic{
        .path = "bad.zp64",
        .line = 12,
        .column = 17,
        .message = "unsupported feature: generic function",
        .note = "ZeroPage v0 does not support generic functions; use a concrete type",
    }).render(&out.writer);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "bad.zp64:12:17: error") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "note: ZeroPage v0") != null);
}
