const std = @import("std");

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,

    pub const Tag = enum {
        invalid,
        eof,
        identifier,
        number,
        string_literal,
        char_literal,
        keyword_const,
        keyword_pub,
        keyword_export,
        keyword_fn,
        keyword_void,
        keyword_bool,
        keyword_var,
        keyword_for,
        keyword_switch,
        keyword_u8,
        keyword_i8,
        keyword_u16,
        keyword_i16,
        keyword_usize,
        keyword_return,
        keyword_break,
        keyword_continue,
        keyword_true,
        keyword_false,
        keyword_while,
        keyword_if,
        keyword_else,
        l_paren,
        r_paren,
        l_brace,
        r_brace,
        l_bracket,
        r_bracket,
        semicolon,
        colon,
        comma,
        period,
        period_period,
        period_period_period,
        equal,
        equal_equal,
        bang,
        bang_equal,
        question_mark,
        plus,
        plus_plus,
        plus_equal,
        minus,
        minus_equal,
        star,
        star_equal,
        ampersand,
        ampersand_equal,
        at,
        pipe,
        pipe_equal,
        caret,
        caret_equal,
        tilde,
        angle_left,
        angle_left_equal,
        angle_left_angle_left,
        angle_left_angle_left_equal,
        angle_right,
        angle_right_equal,
        angle_right_angle_right,
        angle_right_angle_right_equal,
        keyword_and,
        keyword_or,
    };
};

pub fn lex(allocator: std.mem.Allocator, source: []const u8) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);

    var i: usize = 0;
    while (i < source.len) {
        const ch = source[i];
        switch (ch) {
            ' ', '\t', '\r', '\n' => {
                i += 1;
            },
            '/' => {
                if (i + 1 < source.len and source[i + 1] == '/') {
                    i += 2;
                    while (i < source.len and source[i] != '\n') i += 1;
                } else {
                    try tokens.append(allocator, .{ .tag = .invalid, .start = i, .end = i + 1 });
                    i += 1;
                }
            },
            '\\' => {
                if (i + 1 < source.len and source[i + 1] == '\\') {
                    i = try multilineString(allocator, &tokens, source, i);
                } else {
                    try tokens.append(allocator, .{ .tag = .invalid, .start = i, .end = i + 1 });
                    i += 1;
                }
            },
            '(' => i = try one(allocator, &tokens, .l_paren, i),
            ')' => i = try one(allocator, &tokens, .r_paren, i),
            '{' => i = try one(allocator, &tokens, .l_brace, i),
            '}' => i = try one(allocator, &tokens, .r_brace, i),
            '[' => i = try one(allocator, &tokens, .l_bracket, i),
            ']' => i = try one(allocator, &tokens, .r_bracket, i),
            ';' => i = try one(allocator, &tokens, .semicolon, i),
            ':' => i = try one(allocator, &tokens, .colon, i),
            ',' => i = try one(allocator, &tokens, .comma, i),
            '.' => {
                if (i + 2 < source.len and source[i + 1] == '.' and source[i + 2] == '.') {
                    try tokens.append(allocator, .{ .tag = .period_period_period, .start = i, .end = i + 3 });
                    i += 3;
                } else if (i + 1 < source.len and source[i + 1] == '.') {
                    try tokens.append(allocator, .{ .tag = .period_period, .start = i, .end = i + 2 });
                    i += 2;
                } else {
                    i = try one(allocator, &tokens, .period, i);
                }
            },
            '<' => {
                if (i + 2 < source.len and source[i + 1] == '<' and source[i + 2] == '=') {
                    try tokens.append(allocator, .{ .tag = .angle_left_angle_left_equal, .start = i, .end = i + 3 });
                    i += 3;
                } else if (i + 1 < source.len and source[i + 1] == '<') {
                    try tokens.append(allocator, .{ .tag = .angle_left_angle_left, .start = i, .end = i + 2 });
                    i += 2;
                } else if (i + 1 < source.len and source[i + 1] == '=') {
                    try tokens.append(allocator, .{ .tag = .angle_left_equal, .start = i, .end = i + 2 });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .angle_left, .start = i, .end = i + 1 });
                    i += 1;
                }
            },
            '>' => {
                if (i + 2 < source.len and source[i + 1] == '>' and source[i + 2] == '=') {
                    try tokens.append(allocator, .{ .tag = .angle_right_angle_right_equal, .start = i, .end = i + 3 });
                    i += 3;
                } else if (i + 1 < source.len and source[i + 1] == '>') {
                    try tokens.append(allocator, .{ .tag = .angle_right_angle_right, .start = i, .end = i + 2 });
                    i += 2;
                } else if (i + 1 < source.len and source[i + 1] == '=') {
                    try tokens.append(allocator, .{ .tag = .angle_right_equal, .start = i, .end = i + 2 });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .angle_right, .start = i, .end = i + 1 });
                    i += 1;
                }
            },
            '!' => {
                if (i + 1 < source.len and source[i + 1] == '=') {
                    try tokens.append(allocator, .{ .tag = .bang_equal, .start = i, .end = i + 2 });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .bang, .start = i, .end = i + 1 });
                    i += 1;
                }
            },
            '?' => i = try one(allocator, &tokens, .question_mark, i),
            '=' => {
                if (i + 1 < source.len and source[i + 1] == '=') {
                    try tokens.append(allocator, .{ .tag = .equal_equal, .start = i, .end = i + 2 });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .equal, .start = i, .end = i + 1 });
                    i += 1;
                }
            },
            '+' => {
                if (i + 1 < source.len and source[i + 1] == '+') {
                    try tokens.append(allocator, .{ .tag = .plus_plus, .start = i, .end = i + 2 });
                    i += 2;
                } else if (i + 1 < source.len and source[i + 1] == '=') {
                    try tokens.append(allocator, .{ .tag = .plus_equal, .start = i, .end = i + 2 });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .plus, .start = i, .end = i + 1 });
                    i += 1;
                }
            },
            '-' => {
                if (i + 1 < source.len and source[i + 1] == '=') {
                    try tokens.append(allocator, .{ .tag = .minus_equal, .start = i, .end = i + 2 });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .minus, .start = i, .end = i + 1 });
                    i += 1;
                }
            },
            '*' => {
                if (i + 1 < source.len and source[i + 1] == '=') {
                    try tokens.append(allocator, .{ .tag = .star_equal, .start = i, .end = i + 2 });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .star, .start = i, .end = i + 1 });
                    i += 1;
                }
            },
            '&' => {
                if (i + 1 < source.len and source[i + 1] == '=') {
                    try tokens.append(allocator, .{ .tag = .ampersand_equal, .start = i, .end = i + 2 });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .ampersand, .start = i, .end = i + 1 });
                    i += 1;
                }
            },
            '@' => i = try one(allocator, &tokens, .at, i),
            '|' => {
                if (i + 1 < source.len and source[i + 1] == '=') {
                    try tokens.append(allocator, .{ .tag = .pipe_equal, .start = i, .end = i + 2 });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .pipe, .start = i, .end = i + 1 });
                    i += 1;
                }
            },
            '^' => {
                if (i + 1 < source.len and source[i + 1] == '=') {
                    try tokens.append(allocator, .{ .tag = .caret_equal, .start = i, .end = i + 2 });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .caret, .start = i, .end = i + 1 });
                    i += 1;
                }
            },
            '~' => i = try one(allocator, &tokens, .tilde, i),
            '"' => {
                const start = i;
                i += 1;
                while (i < source.len and source[i] != '"') : (i += 1) {
                    if (source[i] == '\\' and i + 1 < source.len) i += 1;
                }
                if (i >= source.len) return error.UnterminatedString;
                i += 1;
                try tokens.append(allocator, .{ .tag = .string_literal, .start = start, .end = i });
            },
            '\'' => {
                const start = i;
                i += 1;
                while (i < source.len and source[i] != '\'') : (i += 1) {
                    if (source[i] == '\\' and i + 1 < source.len) i += 1;
                }
                if (i >= source.len) return error.UnterminatedChar;
                i += 1;
                try tokens.append(allocator, .{ .tag = .char_literal, .start = start, .end = i });
            },
            '0'...'9' => {
                const start = i;
                if (i + 1 < source.len and source[i] == '0' and (source[i + 1] == 'x' or source[i + 1] == 'X')) {
                    i += 2;
                    while (i < source.len and std.ascii.isHex(source[i])) : (i += 1) {}
                } else {
                    while (i < source.len and std.ascii.isDigit(source[i])) : (i += 1) {}
                }
                try tokens.append(allocator, .{ .tag = .number, .start = start, .end = i });
            },
            'A'...'Z', 'a'...'z', '_' => {
                const start = i;
                while (i < source.len and isIdentContinue(source[i])) : (i += 1) {}
                try tokens.append(allocator, .{ .tag = keywordTag(source[start..i]), .start = start, .end = i });
            },
            else => {
                try tokens.append(allocator, .{ .tag = .invalid, .start = i, .end = i + 1 });
                i += 1;
            },
        }
    }
    try tokens.append(allocator, .{ .tag = .eof, .start = source.len, .end = source.len });
    return try tokens.toOwnedSlice(allocator);
}

fn one(allocator: std.mem.Allocator, tokens: *std.ArrayList(Token), tag: Token.Tag, i: usize) !usize {
    try tokens.append(allocator, .{ .tag = tag, .start = i, .end = i + 1 });
    return i + 1;
}

fn multilineString(allocator: std.mem.Allocator, tokens: *std.ArrayList(Token), source: []const u8, start: usize) !usize {
    var i = start;
    while (i < source.len) {
        if (!(i + 1 < source.len and source[i] == '\\' and source[i + 1] == '\\')) break;
        i += 2;
        while (i < source.len and source[i] != '\n') : (i += 1) {}
        if (i >= source.len) break;
        const after_newline = i + 1;
        var next = after_newline;
        while (true) {
            while (next < source.len and (source[next] == ' ' or source[next] == '\t')) : (next += 1) {}
            if (!(next + 1 < source.len and source[next] == '/' and source[next + 1] == '/')) break;
            while (next < source.len and source[next] != '\n') : (next += 1) {}
            if (next >= source.len) break;
            next += 1;
        }
        if (!(next + 1 < source.len and source[next] == '\\' and source[next + 1] == '\\')) {
            i = after_newline;
            break;
        }
        i = next;
    }
    try tokens.append(allocator, .{ .tag = .string_literal, .start = start, .end = i });
    return i;
}

fn isIdentContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn keywordTag(text: []const u8) Token.Tag {
    if (std.mem.eql(u8, text, "const")) return .keyword_const;
    if (std.mem.eql(u8, text, "pub")) return .keyword_pub;
    if (std.mem.eql(u8, text, "export")) return .keyword_export;
    if (std.mem.eql(u8, text, "fn")) return .keyword_fn;
    if (std.mem.eql(u8, text, "void")) return .keyword_void;
    if (std.mem.eql(u8, text, "bool")) return .keyword_bool;
    if (std.mem.eql(u8, text, "var")) return .keyword_var;
    if (std.mem.eql(u8, text, "for")) return .keyword_for;
    if (std.mem.eql(u8, text, "switch")) return .keyword_switch;
    if (std.mem.eql(u8, text, "u8")) return .keyword_u8;
    if (std.mem.eql(u8, text, "i8")) return .keyword_i8;
    if (std.mem.eql(u8, text, "u16")) return .keyword_u16;
    if (std.mem.eql(u8, text, "i16")) return .keyword_i16;
    if (std.mem.eql(u8, text, "usize")) return .keyword_usize;
    if (std.mem.eql(u8, text, "return")) return .keyword_return;
    if (std.mem.eql(u8, text, "break")) return .keyword_break;
    if (std.mem.eql(u8, text, "continue")) return .keyword_continue;
    if (std.mem.eql(u8, text, "true")) return .keyword_true;
    if (std.mem.eql(u8, text, "false")) return .keyword_false;
    if (std.mem.eql(u8, text, "while")) return .keyword_while;
    if (std.mem.eql(u8, text, "if")) return .keyword_if;
    if (std.mem.eql(u8, text, "else")) return .keyword_else;
    if (std.mem.eql(u8, text, "and")) return .keyword_and;
    if (std.mem.eql(u8, text, "or")) return .keyword_or;
    return .identifier;
}

test "lexer recognizes ZeroPage subset tokens" {
    const tokens = try lex(std.testing.allocator, "fn main() void { var x: u8 = 0; while (x < 2) { x += 1; } for (0..2) |i| { _ = i; } switch (x) { 1...2 => {}, else => {}, } }");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(Token.Tag.keyword_fn, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.identifier, tokens[1].tag);
    var found_while = false;
    var found_for = false;
    var found_range = false;
    var found_switch = false;
    var found_ellipsis = false;
    for (tokens) |token| {
        if (token.tag == .keyword_while) found_while = true;
        if (token.tag == .keyword_for) found_for = true;
        if (token.tag == .period_period) found_range = true;
        if (token.tag == .keyword_switch) found_switch = true;
        if (token.tag == .period_period_period) found_ellipsis = true;
    }
    try std.testing.expect(found_while);
    try std.testing.expect(found_for);
    try std.testing.expect(found_range);
    try std.testing.expect(found_switch);
    try std.testing.expect(found_ellipsis);
}
