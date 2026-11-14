const std = @import("std");

pub const Encoding = enum {
    petscii,
    ascii,
};

pub fn encodeLiteral(allocator: std.mem.Allocator, literal: []const u8) ![]u8 {
    return encodeLiteralAs(allocator, literal, .petscii);
}

pub fn encodeAsciiLiteral(allocator: std.mem.Allocator, literal: []const u8) ![]u8 {
    return encodeLiteralAs(allocator, literal, .ascii);
}

pub fn encodeLiteralAs(allocator: std.mem.Allocator, literal: []const u8, encoding: Encoding) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < literal.len) {
        const ch = literal[i];
        if (ch == '\\') {
            if (i + 1 >= literal.len) return error.UnsupportedStringEscape;
            const escaped = literal[i + 1];
            switch (escaped) {
                'n' => try out.append(allocator, if (encoding == .ascii) 0x0a else 0x0d),
                'r' => try out.append(allocator, 0x0d),
                't' => try out.append(allocator, 0x09),
                '\\' => try out.append(allocator, '\\'),
                '"' => try out.append(allocator, '"'),
                '0' => try out.append(allocator, 0),
                'x' => {
                    if (i + 3 >= literal.len) return error.UnsupportedStringEscape;
                    const byte = try parseHexByte(literal[i + 2 .. i + 4]);
                    try out.append(allocator, byte);
                    i += 4;
                    continue;
                },
                'u' => return error.UnsupportedUnicodeStringEscape,
                else => return error.UnsupportedStringEscape,
            }
            i += 2;
            continue;
        }

        try out.append(allocator, switch (encoding) {
            .petscii => asciiToPetscii(ch),
            .ascii => ch,
        });
        i += 1;
    }

    return try out.toOwnedSlice(allocator);
}

pub fn control(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "clear")) return 0x93;
    if (std.mem.eql(u8, name, "home")) return 0x13;
    if (std.mem.eql(u8, name, "return") or std.mem.eql(u8, name, "return_")) return 0x0d;
    if (std.mem.eql(u8, name, "reverse_on")) return 0x12;
    if (std.mem.eql(u8, name, "reverse_off")) return 0x92;
    if (std.mem.eql(u8, name, "cursor_up")) return 0x91;
    if (std.mem.eql(u8, name, "cursor_down")) return 0x11;
    if (std.mem.eql(u8, name, "cursor_left")) return 0x9d;
    if (std.mem.eql(u8, name, "cursor_right")) return 0x1d;
    if (std.mem.eql(u8, name, "delete")) return 0x14;
    if (std.mem.eql(u8, name, "insert")) return 0x94;
    if (std.mem.eql(u8, name, "black")) return 0x90;
    if (std.mem.eql(u8, name, "white")) return 0x05;
    if (std.mem.eql(u8, name, "red")) return 0x1c;
    if (std.mem.eql(u8, name, "cyan")) return 0x9f;
    if (std.mem.eql(u8, name, "purple")) return 0x9c;
    if (std.mem.eql(u8, name, "green")) return 0x1e;
    if (std.mem.eql(u8, name, "blue")) return 0x1f;
    if (std.mem.eql(u8, name, "yellow")) return 0x9e;
    return null;
}

pub fn key(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "none")) return 0x00;
    if (std.mem.eql(u8, name, "space")) return 0x20;
    if (std.mem.eql(u8, name, "stop")) return 0x03;
    if (std.mem.eql(u8, name, "f1")) return 0x85;
    if (std.mem.eql(u8, name, "f2")) return 0x89;
    if (std.mem.eql(u8, name, "f3")) return 0x86;
    if (std.mem.eql(u8, name, "f4")) return 0x8a;
    if (std.mem.eql(u8, name, "f5")) return 0x87;
    if (std.mem.eql(u8, name, "f6")) return 0x8b;
    if (std.mem.eql(u8, name, "f7")) return 0x88;
    if (std.mem.eql(u8, name, "f8")) return 0x8c;
    return control(name);
}

fn parseHexByte(text: []const u8) !u8 {
    if (text.len != 2) return error.UnsupportedStringEscape;
    return std.fmt.parseInt(u8, text, 16) catch return error.UnsupportedStringEscape;
}

pub fn asciiToPetscii(ch: u8) u8 {
    return switch (ch) {
        'a'...'z' => ch - 'a' + 'A',
        '\n', '\r' => 0x0d,
        else => ch,
    };
}

pub fn petsciiToScreenCode(ch: u8) u8 {
    return switch (ch) {
        'A'...'Z' => ch - 'A' + 1,
        'a'...'z' => ch - 'a' + 1,
        else => ch,
    };
}

test "encodes ASCII source text as uppercase PETSCII without sentinel" {
    const bytes = try encodeLiteral(std.testing.allocator, "hello world");
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualStrings("HELLO WORLD", bytes);
    try std.testing.expectEqual(@as(usize, 11), bytes.len);
}

test "encodes newlines and carriage returns as PETSCII carriage return" {
    const bytes = try encodeLiteral(std.testing.allocator, "a\\nb\\rc");
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, &.{ 'A', 0x0d, 'B', 0x0d, 'C' }, bytes);
}

test "does not append a null terminator" {
    const bytes = try encodeLiteral(std.testing.allocator, "ok");
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, &.{ 'O', 'K' }, bytes);
}

test "hex escape inserts exact 8-bit byte" {
    const bytes = try encodeLiteral(std.testing.allocator, "a\\x9eb");
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, &.{ 'A', 0x9e, 'B' }, bytes);
}

test "ASCII proxy preserves case and uses LF for newline" {
    const bytes = try encodeAsciiLiteral(std.testing.allocator, "ok\\n");
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, &.{ 'o', 'k', 0x0a }, bytes);
}

test "unicode escape is rejected for 8-bit strings" {
    try std.testing.expectError(error.UnsupportedUnicodeStringEscape, encodeLiteral(std.testing.allocator, "\\u{41}"));
}

test "PETSCII control constants are byte values" {
    try std.testing.expectEqual(@as(u8, 0x93), control("clear").?);
    try std.testing.expectEqual(@as(u8, 0x0d), control("return").?);
    try std.testing.expectEqual(@as(u8, 0x9e), control("yellow").?);
}
