const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const petscii = @import("petscii.zig");
const zero_page = @import("zero_page.zig");

const Token = lexer.Token;

const ParseError = error{
    OutOfMemory,
    UnexpectedToken,
    UnexpectedEof,
    UnsupportedStatement,
    UnsupportedBuiltin,
    UnsupportedDefer,
    UnsupportedSwitch,
    UnsupportedSwitchPayload,
    UnsupportedSwitchRange,
    UnsupportedSwitchSelector,
    UnsupportedFor,
    UnsupportedForElse,
    UnsupportedForPointerCapture,
    UnsupportedForRange,
    UnsupportedForSource,
    UnsupportedU32,
    UnsupportedStringConcat,
    UnsupportedStringSlice,
    UnsupportedStringSentinel,
    UnsupportedRuntimeString,
    UnsupportedStringEscape,
    UnsupportedUnicodeStringEscape,
    UnsupportedCharLiteral,
    UnsupportedChainedComparison,
    UnsupportedArrayType,
    UnsupportedArrayByValue,
    UnsupportedArrayLiteral,
    UnsupportedArraySize,
    UnsupportedArrayRepeat,
    UnsupportedOptional,
    UnsupportedPointerType,
    UnsupportedPointerTarget,
    UnsupportedPointerCast,
    UnsupportedEnum,
    UnsupportedEnumLiteral,
    UnsupportedStruct,
    UnsupportedCompositeField,
    UnsupportedZeroPageOptions,
    UnsupportedZeroPagePolicy,
    InvalidZeroPagePolicy,
    UnsupportedImportedZeroPageOptions,
    UnsupportedZeroPageModule,
    UnsupportedImportedZeroPageModule,
    UnsupportedZeroPageStackAbi,
    UnsupportedFrameCallconv,
    InvalidMachineDeclaration,
    UnknownPlacementSection,
    UnsupportedReuAddress,
    UnsupportedReuLength,
    InvalidZeroPageReuHeapRegion,
    UnsupportedHeapName,
    UnsupportedHeapFunction,
    UnsupportedHeapLength,
    InvalidZeroPageHeapRegion,
    InvalidZeroPageHeapBlock,
    UnknownZeroPageMemoryRegion,
    InvalidZeroPageMemoryRegion,
    DuplicateZeroPageHeapOption,
    InvalidZeroPageStackRegion,
    InvalidZeroPageStackZeroPage,
    DuplicateZeroPageOptions,
    DuplicateZeroPageModule,
    InvalidZeroPageModuleId,
    InvalidZeroPageModuleAbi,
    DuplicateZeroPageModuleExport,
    UnknownZeroPageModuleExport,
    DuplicateZeroPageModuleDependency,
    DuplicateZeroPageFunctionOption,
    InvalidCharacter,
    Overflow,
    UnterminatedInlineAsm,
};

pub const ParseResult = struct {
    source: []u8,
    tokens: []Token,
    program: ast.Program,

    pub fn deinit(self: ParseResult, allocator: std.mem.Allocator) void {
        self.program.deinit(allocator);
        allocator.free(self.tokens);
        allocator.free(self.source);
    }
};

pub const InlineAsmBlock = struct {
    source: []const u8,
    line: usize,
    column: usize,
};

pub const AsmPreparseResult = struct {
    source: []u8,
    blocks: []InlineAsmBlock,

    pub fn deinit(self: AsmPreparseResult, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        if (self.blocks.len != 0) allocator.free(self.blocks);
    }
};

pub fn parseSource(allocator: std.mem.Allocator, source: []const u8) !ParseResult {
    return parseSourceWithPrefix(allocator, source, "");
}

pub fn parseSourceWithPrefix(allocator: std.mem.Allocator, source: []const u8, prefix: []const u8) !ParseResult {
    var prepared = try extractInlineAsmBlocks(allocator, source);
    errdefer prepared.deinit(allocator);

    const tokens = try lexer.lex(allocator, prepared.source);
    errdefer allocator.free(tokens);
    var memory_start: ?usize = null;
    const masked = try maskMachineDeclarations(allocator, prepared.source, tokens, &memory_start);
    defer if (masked) |bytes| allocator.free(bytes);
    const zig_source = masked orelse prepared.source;
    try validateWithZigParser(allocator, zig_source);
    if (std.mem.indexOf(u8, zig_source, "@import(\"std\")") != null) return error.UnsupportedStdImport;
    if (unsupportedFeatureError(zig_source)) |err| return err;
    var parser = Parser{
        .allocator = allocator,
        .source = prepared.source,
        .tokens = tokens,
        .function_prefix = prefix,
        .inline_asm_blocks = prepared.blocks,
    };
    const program = try parser.parseProgram(memory_start);
    const rewritten_source = prepared.source;
    if (prepared.blocks.len != 0) allocator.free(prepared.blocks);
    prepared.source = &.{};
    prepared.blocks = &.{};
    return .{ .source = rewritten_source, .tokens = tokens, .program = program };
}

pub fn extractInlineAsmBlocks(allocator: std.mem.Allocator, source: []const u8) !AsmPreparseResult {
    var rewritten: std.ArrayList(u8) = .empty;
    errdefer rewritten.deinit(allocator);
    var blocks: std.ArrayList(InlineAsmBlock) = .empty;
    errdefer blocks.deinit(allocator);

    var i: usize = 0;
    var line: usize = 1;
    var column: usize = 1;
    while (i < source.len) {
        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len) : (i += 1) {
                try rewritten.append(allocator, source[i]);
                const ch = source[i];
                advancePosition(ch, &line, &column);
                if (ch == '\n') break;
            }
            continue;
        }
        const return_magic = "c64.petscii.return";
        if (std.mem.startsWith(u8, source[i..], return_magic) and
            (i + return_magic.len >= source.len or !isIdent(source[i + return_magic.len])))
        {
            try rewritten.appendSlice(allocator, "c64.petscii.return_");
            for (0..return_magic.len) |offset| advancePosition(source[i + offset], &line, &column);
            i += return_magic.len;
            continue;
        }
        if (source[i] == '"' or source[i] == '\'') {
            const quote = source[i];
            try rewritten.append(allocator, source[i]);
            advancePosition(source[i], &line, &column);
            i += 1;
            while (i < source.len) : (i += 1) {
                try rewritten.append(allocator, source[i]);
                const ch = source[i];
                advancePosition(ch, &line, &column);
                if (ch == quote) {
                    i += 1;
                    break;
                }
            }
            continue;
        }
        if (isInlineAsmStart(source, i)) {
            var open_index = i + "asm".len;
            while (open_index < source.len and std.ascii.isWhitespace(source[open_index])) : (open_index += 1) {}
            const block_start_line = line;
            const block_start_column = column;
            const content_start = open_index + 1;
            const close_index = findInlineAsmClose(source, content_start) orelse return error.UnterminatedInlineAsm;
            const content = trimAsmBlock(source[content_start..close_index]);
            try blocks.append(allocator, .{ .source = content, .line = block_start_line, .column = block_start_column });
            const placeholder = try std.fmt.allocPrint(allocator, "zeropage_inline_asm_{d}();", .{blocks.items.len - 1});
            defer allocator.free(placeholder);
            try rewritten.appendSlice(allocator, placeholder);
            var preserve_lines = i;
            while (preserve_lines <= close_index) : (preserve_lines += 1) {
                if (source[preserve_lines] == '\n') try rewritten.append(allocator, '\n');
            }

            while (i <= close_index) : (i += 1) {
                advancePosition(source[i], &line, &column);
            }
            continue;
        }

        try rewritten.append(allocator, source[i]);
        advancePosition(source[i], &line, &column);
        i += 1;
    }

    return .{
        .source = try rewritten.toOwnedSlice(allocator),
        .blocks = try blocks.toOwnedSlice(allocator),
    };
}

fn isInlineAsmStart(source: []const u8, index: usize) bool {
    if (!std.mem.startsWith(u8, source[index..], "asm")) return false;
    if (index != 0 and isIdent(source[index - 1])) return false;
    if (!isStatementBoundaryBefore(source, index)) return false;
    const after = index + "asm".len;
    if (after < source.len and isIdent(source[after])) return false;
    var open_index = after;
    while (open_index < source.len and std.ascii.isWhitespace(source[open_index])) : (open_index += 1) {}
    return open_index < source.len and source[open_index] == '{';
}

fn isStatementBoundaryBefore(source: []const u8, index: usize) bool {
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (source[cursor]) {
            ' ', '\t', '\r' => continue,
            '\n', '{', ';' => return true,
            else => return false,
        }
    }
    return true;
}

fn findInlineAsmClose(source: []const u8, content_start: usize) ?usize {
    var line_start = content_start;
    while (line_start < source.len) {
        var line_end = line_start;
        while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}
        var cursor = line_start;
        while (cursor < line_end and (source[cursor] == ' ' or source[cursor] == '\t' or source[cursor] == '\r')) : (cursor += 1) {}
        if (cursor < line_end and source[cursor] == '}') {
            var after = cursor + 1;
            while (after < line_end and (source[after] == ' ' or source[after] == '\t' or source[after] == '\r')) : (after += 1) {}
            if (after == line_end) return cursor;
        }
        if (line_end >= source.len) break;
        line_start = line_end + 1;
    }
    return null;
}

fn trimAsmBlock(source: []const u8) []const u8 {
    var start: usize = 0;
    while (start < source.len and (source[start] == '\n' or source[start] == '\r')) start += 1;
    var end = source.len;
    while (end > start and (source[end - 1] == '\n' or source[end - 1] == '\r' or source[end - 1] == ' ' or source[end - 1] == '\t')) end -= 1;
    return source[start..end];
}

fn advancePosition(ch: u8, line: *usize, column: *usize) void {
    if (ch == '\n') {
        line.* += 1;
        column.* = 1;
    } else {
        column.* += 1;
    }
}

pub fn unsupportedFeatureError(source: []const u8) ?anyerror {
    if (containsWord(source, "defer")) return error.UnsupportedDefer;
    if (containsWord(source, "u32")) return error.UnsupportedU32;
    if (std.mem.indexOf(u8, source, "[:0]") != null or std.mem.indexOf(u8, source, "[*:0]") != null) return error.UnsupportedStringSentinel;
    if (std.mem.indexOf(u8, source, "[]const u8") != null or std.mem.indexOf(u8, source, "[]u8") != null) return error.UnsupportedStringSlice;
    if (std.mem.indexOf(u8, source, "**") != null) return error.UnsupportedArrayRepeat;
    if (containsWord(source, "undefined")) return error.UnsupportedStatement;
    return null;
}

pub fn unsupportedFeatureMessage(err: anyerror) ?struct { []const u8, []const u8 } {
    return switch (err) {
        error.UnsupportedDefer => .{
            "unsupported feature: defer",
            "ZeroPage v0 does not support defer/errdefer; write explicit cleanup or keep control flow simple",
        },
        error.UnsupportedSwitch => .{
            "unsupported feature: switch",
            "ZeroPage supports only scalar switch over bool, byte, and word values",
        },
        error.UnsupportedSwitchPayload => .{
            "unsupported switch payload",
            "ZeroPage scalar switch prongs do not support payload captures",
        },
        error.UnsupportedSwitchRange => .{
            "unsupported switch range",
            "ZeroPage switch ranges are unsigned scalar constant ranges only",
        },
        error.UnsupportedSwitchSelector => .{
            "unsupported switch selector",
            "ZeroPage switch prongs require scalar constant selectors",
        },
        error.UnsupportedFor => .{
            "unsupported feature: for",
            "ZeroPage supports only fixed-array for loops and fixed 0..N range loops",
        },
        error.UnsupportedForElse => .{
            "unsupported feature: for else",
            "ZeroPage for loops are statement-only loops without Zig's for-else result form",
        },
        error.UnsupportedForPointerCapture => .{
            "unsupported feature: for pointer capture",
            "ZeroPage for payloads are read-only scalar copies; mutate arrays through an index capture",
        },
        error.UnsupportedForRange => .{
            "unsupported for range",
            "ZeroPage range loops currently support 0..N where N is a byte-sized literal or fixed_array.len",
        },
        error.UnsupportedForSource => .{
            "unsupported for source",
            "ZeroPage for loops currently iterate fixed scalar arrays or 0..N ranges only",
        },
        error.UnsupportedU32 => .{
            "unsupported type: u32",
            "ZeroPage v0 supports u8/i8 and u16/i16; 32-bit math is feature-gated for later work",
        },
        error.UnsupportedReuAddress => .{
            "unsupported REU address",
            "Raw REU v1 requires the REU address argument to be a comptime integer literal in 0..0x00ff_ffff",
        },
        error.UnsupportedReuLength => .{
            "unsupported REU transfer length",
            "Raw REU v1 rejects literal length 0; the hardware 64K special case will be added deliberately later",
        },
        error.InvalidZeroPageReuHeapRegion => .{
            "invalid zeropage_options REU heap region",
            "REU heap metadata requires nonzero size, 24-bit address fit, 16 MB REU fit, and no far-heap overlap",
        },
        error.UnsupportedStringConcat => .{
            "unsupported string expression: ++",
            "ZeroPage string concat currently supports literals, known string constants, string buffers, and PETSCII control constants",
        },
        error.UnsupportedStringSlice => .{
            "unsupported string type: slice",
            "ZeroPage strings are fixed 8-bit constants or fixed-capacity buffers; string slices are planned for a later runtime model",
        },
        error.UnsupportedStringSentinel => .{
            "unsupported string type: sentinel",
            "ZeroPage strings are length-counted PETSCII by default; use a future explicit sentinel API when C-style strings are needed",
        },
        error.UnsupportedRuntimeString => .{
            "unsupported runtime string variable",
            "Use c64.string.buffer(capacity) for mutable strings or top-level const declarations for fixed string data",
        },
        error.UnsupportedStringEscape => .{
            "unsupported string escape",
            "ZeroPage 8-bit strings currently support \\\\xNN, \\\\n, \\\\r, \\\\t, \\\\\\\\, \\\", and \\\\0 escapes",
        },
        error.UnsupportedUnicodeStringEscape => .{
            "unsupported string escape: unicode",
            "ZeroPage strings are 8-bit only; use \\\\xNN byte escapes or PETSCII control constants",
        },
        error.UnsupportedChainedComparison => .{
            "unsupported comparison expression: chained comparison",
            "ZeroPage v0 supports one comparison per boolean expression; split chained comparisons into named bools",
        },
        error.UnsupportedArrayType => .{
            "unsupported array type",
            "ZeroPage arrays currently support fixed-size scalar element types only",
        },
        error.UnsupportedArrayByValue => .{
            "unsupported array by-value use",
            "ZeroPage arrays are fixed storage for locals and module constants; params, returns, and by-value copies are deferred",
        },
        error.UnsupportedArrayLiteral => .{
            "unsupported array literal",
            "ZeroPage array literals require a fixed scalar destination type or [_]T literal with matching element count",
        },
        error.UnsupportedArraySize => .{
            "unsupported array size",
            "ZeroPage array v1 keeps each fixed array within one 6502 indexed-addressing page",
        },
        error.UnsupportedArrayRepeat => .{
            "unsupported array repetition",
            "ZeroPage fixed arrays do not yet support Zig's ** repetition syntax",
        },
        error.UnsupportedOptional => .{
            "unsupported optional type",
            "ZeroPage optionals currently support scalar, enum(u8), and exact supported pointer payloads only",
        },
        error.UnsupportedPointerType => .{
            "unsupported pointer type",
            "ZeroPage pointer v1 supports *T, *volatile T, [*]T, and [*]volatile T for scalar or enum storage only",
        },
        error.UnsupportedPointerTarget => .{
            "unsupported pointer target",
            "ZeroPage address-of currently targets mutable scalar storage or literal-index array elements",
        },
        error.UnsupportedPointerCast => .{
            "unsupported pointer builtin",
            "ZeroPage pointer v1 supports only @ptrFromInt in typed pointer contexts and @intFromPtr for scalar pointers",
        },
        error.UnsupportedEnum => .{
            "unsupported enum",
            "ZeroPage enums currently require explicit enum(u8) tags with byte-sized values",
        },
        error.UnsupportedEnumLiteral => .{
            "unsupported enum literal",
            "ZeroPage enum values must name a known enum tag and match the destination enum type",
        },
        error.UnsupportedStruct => .{
            "unsupported struct",
            "ZeroPage structs currently support fixed fields over scalar, enum, fixed array, or nested struct storage",
        },
        error.UnsupportedCompositeField => .{
            "unsupported composite field",
            "ZeroPage composite fields must resolve to a known flattened scalar or fixed-array field",
        },
        error.UnsupportedZeroPageOptions => .{
            "unsupported zeropage_options metadata",
            "ZeroPage currently accepts .image, .memory.regions, .zero_page, .stack, .abi, .heaps, .reu.heaps, and .modules metadata",
        },
        error.UnsupportedZeroPagePolicy => .{
            "unsupported zeropage_options zero-page policy",
            "Zero-page policy accepts .profile, .allocation, .ranges, .reserve, .restore_basic, and .interrupts with literal metadata values",
        },
        error.InvalidZeroPagePolicy => .{
            "invalid zeropage_options zero-page policy",
            "Zero-page ranges and fixed pointers must be nonoverlapping, fit the declared system profile, preserve protected bytes, and leave contiguous compiler pointer pairs; bare mode requires application interrupt ownership",
        },
        error.UnknownZeroPageMemoryRegion => .{
            "unknown zeropage_options memory region",
            "Named region references must match a declaration in .memory.regions and use the required C64 or REU address space",
        },
        error.InvalidZeroPageMemoryRegion => .{
            "invalid zeropage_options memory region",
            "Memory regions require a unique name, nonzero bounded address range, compatible address space, and valid ROM banking mode",
        },
        error.UnsupportedImportedZeroPageOptions => .{
            "unsupported imported zeropage_options metadata",
            "ZeroPage options are main-source metadata until module descriptors land",
        },
        error.UnsupportedZeroPageModule => .{
            "unsupported zeropage_module metadata",
            "ZeroPage module metadata currently accepts .id, .abi = 1, empty .flags, .exports, and .deps only",
        },
        error.UnsupportedImportedZeroPageModule => .{
            "unsupported imported zeropage_module metadata",
            "ZeroPage loadable module metadata is main-source-only until separately compiled modules land",
        },
        error.UnsupportedZeroPageStackAbi => .{
            "unsupported stack frame ABI",
            "ZeroPage supports static and scalar software-stack frames",
        },
        error.UnsupportedFrameCallconv => .{
            "unsupported ZeroPage calling convention",
            "Use callconv(.static) or callconv(.stack) with a literal convention",
        },
        error.InvalidMachineDeclaration => .{
            "invalid ZeroPage machine declaration",
            "Check the declaration's clauses, names, and literal values",
        },
        error.UnknownPlacementSection => .{
            "unknown ZeroPage placement section",
            "linksection requires the literal name of a declared memory placement",
        },
        error.InvalidZeroPageStackRegion => .{
            "invalid zeropage_options stack region",
            "Stack metadata requires nonzero size and base + size within 64K C64 address space",
        },
        error.InvalidZeroPageStackZeroPage => .{
            "invalid zeropage_options stack zero-page",
            "ZeroPage software stack .zp.sp and .zp.fp are two-byte zero-page pointers and must not overlap reserved zero-page storage",
        },
        error.DuplicateZeroPageOptions => .{
            "duplicate zeropage_options metadata",
            "Declare zeropage_options at most once in the main source file",
        },
        error.DuplicateZeroPageModule => .{
            "duplicate zeropage_module metadata",
            "Declare zeropage_module at most once in the main source file",
        },
        error.InvalidZeroPageModuleId => .{
            "invalid zeropage_module id",
            "Module ids and dependencies must be lowercase ASCII identifiers with optional '-', '_', and digits after the first character",
        },
        error.DuplicateZeroPageModuleDependency => .{
            "duplicate zeropage_module dependency",
            "Dependency ids must be unique and remain in declaration order",
        },
        error.InvalidZeroPageModuleAbi => .{
            "invalid zeropage_module ABI",
            "ZeroPage module sidecars support ABI version 1 only",
        },
        error.DuplicateZeroPageModuleExport => .{
            "duplicate zeropage_module export",
            "Each module export name may be declared at most once",
        },
        error.DuplicateZeroPageFunctionOption => .{
            "duplicate zeropage_options function frame metadata",
            "Each function may have at most one frame policy override",
        },
        error.UnsupportedHeapName => .{
            "unsupported heap name",
            "Use a declared near arena for materialization or a compile-time name with the legacy heap API",
        },
        error.UnsupportedHeapFunction => .{
            "unsupported heap function",
            "Near heap v1 supports ZeroPage.heap(\"name\").allocBytes(len), reset(), and fixed-heap free(ptr) only",
        },
        error.UnsupportedHeapLength => .{
            "unsupported heap allocation length",
            "Near heap v1 rejects literal length 0; use a positive scalar length expression",
        },
        error.InvalidZeroPageHeapRegion => .{
            "invalid zeropage_options heap region",
            "Heap metadata requires nonzero size, base + size within 64K, and no reserved-region overlap",
        },
        error.InvalidZeroPageHeapBlock => .{
            "invalid zeropage_options heap block",
            "Fixed heap metadata requires .block >= 2, .block <= region size, and region size divisible by block",
        },
        error.DuplicateZeroPageHeapOption => .{
            "duplicate zeropage_options heap metadata",
            "Each named heap may be declared at most once",
        },
        else => null,
    };
}

fn containsWord(source: []const u8, word: []const u8) bool {
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, source, index, word)) |found| {
        const before_ok = found == 0 or !isIdent(source[found - 1]);
        const after_index = found + word.len;
        const after_ok = after_index >= source.len or !isIdent(source[after_index]);
        if (before_ok and after_ok) return true;
        index = after_index;
    }
    return false;
}

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn isValidModuleId(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text[0] < 'a' or text[0] > 'z') return false;
    for (text[1..]) |ch| {
        if (ch >= 'a' and ch <= 'z') continue;
        if (ch >= '0' and ch <= '9') continue;
        if (ch == '_' or ch == '-') continue;
        return false;
    }
    return true;
}

fn memoryRegionU16(value: u32) ParseError!u16 {
    if (value == 0 or value > 0xffff) return error.InvalidZeroPageMemoryRegion;
    return @intCast(value);
}

fn validateWithZigParser(allocator: std.mem.Allocator, source: []const u8) !void {
    const sentinel_source = try allocator.dupeZ(u8, source);
    defer allocator.free(sentinel_source);

    var tree = try std.zig.Ast.parse(allocator, sentinel_source, .zig);
    defer tree.deinit(allocator);

    if (tree.errors.len != 0) return error.ZigSyntaxError;
}

fn machineDeclaration(source: []const u8, tokens: []const Token) bool {
    if (tokens.len < 3 or tokens[0].tag != .identifier) return false;
    const word = source[tokens[0].start..tokens[0].end];
    if (std.mem.eql(u8, word, "memory") or std.mem.eql(u8, word, "module_loader")) return tokens[1].tag == .l_brace;
    if (std.mem.eql(u8, word, "module")) return tokens[1].tag == .identifier or tokens[1].tag == .string_literal;
    return std.mem.eql(u8, word, "extern") and std.mem.eql(u8, source[tokens[1].start..tokens[1].end], "module");
}

// The Zig parser receives the ordinary source at its existing offsets. The
// ZeroPage parser separately validates the closed declaration grammar.
fn maskMachineDeclarations(allocator: std.mem.Allocator, source: []const u8, tokens: []const Token, memory_start: *?usize) !?[]u8 {
    var masked: ?[]u8 = null;
    errdefer if (masked) |bytes| allocator.free(bytes);
    var index: usize = 0;
    var depth: usize = 0;
    var at_declaration_boundary = true;
    while (index + 1 < tokens.len) : (index += 1) {
        const token = tokens[index];
        if (depth == 0 and at_declaration_boundary and machineDeclaration(source, tokens[index..])) {
            if (std.mem.eql(u8, source[token.start..token.end], "memory")) {
                if (memory_start.* != null) return error.DuplicateZeroPageOptions;
                memory_start.* = index;
            }
            var end = index + 1;
            while (tokens[end].tag != .l_brace) : (end += 1) {
                if (tokens[end].tag == .eof or tokens[end].tag == .semicolon) return error.InvalidMachineDeclaration;
            }
            const body_start = tokens[end].end;
            depth = 1;
            while (depth != 0) {
                end += 1;
                switch (tokens[end].tag) {
                    .l_brace => depth += 1,
                    .r_brace => depth -= 1,
                    .eof => return error.InvalidMachineDeclaration,
                    else => {},
                }
            }
            if (masked == null) masked = try allocator.dupe(u8, source);
            for (masked.?[token.start..tokens[end].end]) |*byte| {
                if (byte.* != '\n' and byte.* != '\r') byte.* = ' ';
            }
            if (std.mem.eql(u8, source[token.start..token.end], "extern")) {
                // Zig already accepts standalone function prototypes. Keep
                // the import interface visible to its syntax parser.
                const body_end = tokens[end].start;
                @memcpy(masked.?[body_start..body_end], source[body_start..body_end]);
            }
            index = end;
        } else {
            switch (token.tag) {
                .l_brace, .l_paren, .l_bracket => depth += 1,
                .r_brace, .r_paren, .r_bracket => depth -|= 1,
                else => {},
            }
            if (depth == 0) at_declaration_boundary = token.tag == .semicolon or token.tag == .r_brace;
        }
    }
    return masked;
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    function_prefix: []const u8,
    inline_asm_blocks: []const InlineAsmBlock,
    index: usize = 0,
    for_id: usize = 0,
    known_unions: std.ArrayList([]const u8) = .empty,
    parsed_type_decls: ?*std.ArrayList(ast.TypeDecl) = null,
    parsed_module_bindings: ?*std.ArrayList(ast.ModuleBinding) = null,
    machine_memory: ast.ZeroPageOptions = .{},
    placement_members: std.ArrayList(PlacementMember) = .empty,
    legacy_memory_options: bool = false,

    const PlacementMember = struct { name: []const u8, section: []const u8, is_function: bool };

    fn expectMachineSemicolon(self: *Parser) ParseError!void {
        if (!self.eat(.semicolon)) return error.InvalidMachineDeclaration;
    }

    fn parseProgram(self: *Parser, memory_start: ?usize) ParseError!ast.Program {
        defer self.known_unions.deinit(self.allocator);
        var zeropage_options: ast.ZeroPageOptions = .{};
        defer self.machine_memory.deinit(self.allocator);
        defer self.placement_members.deinit(self.allocator);
        var zeropage_module: ?ast.ZeroPageModule = null;
        var machine_loader: ?ast.ModuleLoaderOptions = null;
        defer if (machine_loader) |loader| loader.deinit(self.allocator);
        var module_bindings: std.ArrayList(ast.ModuleBinding) = .empty;
        self.parsed_module_bindings = &module_bindings;
        defer self.parsed_module_bindings = null;
        var type_decls: std.ArrayList(ast.TypeDecl) = .empty;
        self.parsed_type_decls = &type_decls;
        defer self.parsed_type_decls = null;
        var string_constants: std.ArrayList(ast.StringConstant) = .empty;
        var array_constants: std.ArrayList(ast.ArrayConstant) = .empty;
        var functions: std.ArrayList(ast.Function) = .empty;
        var callconvs: std.ArrayList(ast.FunctionFramePolicy) = .empty;
        defer callconvs.deinit(self.allocator);
        errdefer {
            for (module_bindings.items) |binding| binding.deinit(self.allocator);
            module_bindings.deinit(self.allocator);
            for (type_decls.items) |decl| decl.deinit(self.allocator);
            type_decls.deinit(self.allocator);
            for (string_constants.items) |constant| constant.deinit(self.allocator);
            string_constants.deinit(self.allocator);
            for (array_constants.items) |constant| constant.deinit(self.allocator);
            array_constants.deinit(self.allocator);
            for (functions.items) |function| function.deinit(self.allocator);
            functions.deinit(self.allocator);
            zeropage_options.deinit(self.allocator);
            if (zeropage_module) |module| module.deinit(self.allocator);
        }

        var memory_end: usize = 0;
        if (memory_start) |start| {
            if (self.function_prefix.len != 0) return error.UnsupportedImportedZeroPageOptions;
            self.index = start;
            self.machine_memory = try self.parseMemoryDeclaration();
            memory_end = self.index;
            self.index = 0;
        }

        while (!self.peek(.eof)) {
            if (self.index == memory_start) {
                self.index = memory_end;
                continue;
            }
            if (self.peekAheadText(0, "module") and (self.peekNext(.identifier) or self.peekNext(.string_literal))) {
                if (self.function_prefix.len != 0) return error.UnsupportedImportedZeroPageModule;
                if (zeropage_module != null) return error.DuplicateZeroPageModule;
                zeropage_module = try self.parseModuleDeclaration();
                continue;
            }
            if (self.peekAheadText(0, "extern") and self.peekAheadText(1, "module")) {
                if (self.function_prefix.len != 0) return error.UnsupportedImportedZeroPageModule;
                const binding = try self.parseExternModule();
                errdefer binding.deinit(self.allocator);
                if (self.findModuleBinding(binding.name) != null) return error.UnsupportedZeroPageModule;
                if (self.namedHeapIsFar(binding.name) != null) return error.InvalidMachineDeclaration;
                try module_bindings.append(self.allocator, binding);
                continue;
            }
            if (self.peekAheadText(0, "module_loader") and self.peekNext(.l_brace)) {
                if (self.function_prefix.len != 0) return error.UnsupportedImportedZeroPageOptions;
                if (machine_loader != null) return error.DuplicateZeroPageOptions;
                machine_loader = try self.parseModuleLoaderDeclaration();
                continue;
            }
            const is_pub = self.eat(.keyword_pub);
            if (self.eat(.keyword_const)) {
                if (try self.parseTopLevelConst(string_constants.items)) |constant| {
                    switch (constant) {
                        .options => |options| {
                            if (zeropage_options.declared) {
                                options.deinit(self.allocator);
                                return error.DuplicateZeroPageOptions;
                            }
                            zeropage_options = options;
                        },
                        .module => |module| {
                            if (zeropage_module != null) {
                                module.deinit(self.allocator);
                                return error.DuplicateZeroPageModule;
                            }
                            zeropage_module = module;
                        },
                        .module_binding => |binding| {
                            errdefer binding.deinit(self.allocator);
                            if (self.namedHeapIsFar(binding.name) != null) return error.InvalidMachineDeclaration;
                            try module_bindings.append(self.allocator, binding);
                        },
                        .type_decl => |decl| {
                            errdefer decl.deinit(self.allocator);
                            if (decl == .@"union") try self.known_unions.append(self.allocator, decl.@"union".name);
                            try type_decls.append(self.allocator, decl);
                        },
                        .string => |string| {
                            errdefer string.deinit(self.allocator);
                            try string_constants.append(self.allocator, string);
                        },
                        .array => |array| {
                            errdefer array.deinit(self.allocator);
                            try array_constants.append(self.allocator, array);
                        },
                    }
                }
            } else if (is_pub) {
                return error.UnsupportedStatement;
            } else {
                var convention: ?ast.FramePolicy = null;
                const function = try self.parseFunction(&convention);
                errdefer function.deinit(self.allocator);
                if (convention) |frame| try callconvs.append(self.allocator, .{ .name = function.name, .frame = frame });
                try functions.append(self.allocator, function);
            }
        }

        if (self.machine_memory.declared and self.legacy_memory_options) return error.DuplicateZeroPageOptions;
        mergeMemoryDeclaration(&zeropage_options, &self.machine_memory);
        if (machine_loader) |loader| {
            if (zeropage_options.modules != null) return error.DuplicateZeroPageOptions;
            zeropage_options.modules = loader;
            zeropage_options.declared = true;
            machine_loader = null;
        }
        try self.applyPlacementMembers(zeropage_options.memory.placements);
        try self.finishZeroPageOptions(&zeropage_options);

        if (callconvs.items.len != 0) {
            for (zeropage_options.abi.functions) |policy| {
                for (callconvs.items) |decl| {
                    if (std.mem.eql(u8, policy.name, decl.name)) return error.DuplicateZeroPageFunctionOption;
                }
            }
            const old = zeropage_options.abi.functions;
            zeropage_options.abi.functions = try std.mem.concat(self.allocator, ast.FunctionFramePolicy, &.{ old, callconvs.items });
            if (old.len != 0) self.allocator.free(old);
        }

        // Each successful conversion empties its ArrayList. Own those slices
        // explicitly until all later conversions succeed, so a later OOM does
        // not strand payloads outside the lists' error cleanup above.
        const owned_bindings = try module_bindings.toOwnedSlice(self.allocator);
        errdefer {
            for (owned_bindings) |binding| binding.deinit(self.allocator);
            self.allocator.free(owned_bindings);
        }
        const owned_types = try type_decls.toOwnedSlice(self.allocator);
        errdefer {
            for (owned_types) |decl| decl.deinit(self.allocator);
            self.allocator.free(owned_types);
        }
        const owned_strings = try string_constants.toOwnedSlice(self.allocator);
        errdefer {
            for (owned_strings) |constant| constant.deinit(self.allocator);
            self.allocator.free(owned_strings);
        }
        const owned_arrays = try array_constants.toOwnedSlice(self.allocator);
        errdefer {
            for (owned_arrays) |constant| constant.deinit(self.allocator);
            self.allocator.free(owned_arrays);
        }
        const owned_functions = try functions.toOwnedSlice(self.allocator);
        return .{
            .zeropage_options = zeropage_options,
            .zeropage_module = zeropage_module,
            .module_bindings = owned_bindings,
            .type_decls = owned_types,
            .string_constants = owned_strings,
            .array_constants = owned_arrays,
            .functions = owned_functions,
        };
    }

    const TopLevelConst = union(enum) {
        options: ast.ZeroPageOptions,
        module: ast.ZeroPageModule,
        module_binding: ast.ModuleBinding,
        type_decl: ast.TypeDecl,
        string: ast.StringConstant,
        array: ast.ArrayConstant,
    };

    fn parseTopLevelConst(self: *Parser, known_strings: []const ast.StringConstant) ParseError!?TopLevelConst {
        const name = try self.expectIdent();
        if (self.namedHeapIsFar(name) != null) return error.InvalidMachineDeclaration;
        if (std.mem.eql(u8, name, "zeropage_options")) {
            if (self.function_prefix.len != 0) return error.UnsupportedImportedZeroPageOptions;
            try self.expect(.equal);
            const options = try self.parseZeroPageOptions();
            errdefer options.deinit(self.allocator);
            try self.expect(.semicolon);
            return .{ .options = options };
        }
        if (std.mem.eql(u8, name, "zeropage_module")) {
            if (self.function_prefix.len != 0) return error.UnsupportedImportedZeroPageModule;
            try self.expect(.equal);
            const module = try self.parseZeroPageModule();
            errdefer module.deinit(self.allocator);
            try self.expect(.semicolon);
            return .{ .module = module };
        }
        if (self.peek(.equal) and self.isZPMDoduleImportStartAt(1)) {
            if (self.function_prefix.len != 0) return error.UnsupportedImportedZeroPageModule;
            try self.expect(.equal);
            const binding = try self.parseZPMDoduleBinding(name);
            errdefer binding.deinit(self.allocator);
            try self.expect(.semicolon);
            if (self.parsed_module_bindings) |bindings| {
                for (bindings.items) |existing| {
                    if (std.mem.eql(u8, existing.name, name)) return error.UnsupportedZeroPageModule;
                }
            }
            return .{ .module_binding = binding };
        }
        if (self.peek(.equal) and self.peekAheadText(1, "enum")) {
            try self.expect(.equal);
            return .{ .type_decl = .{ .@"enum" = try self.parseEnumDecl(name) } };
        }
        if (self.peek(.equal) and self.peekAheadText(1, "struct")) {
            try self.expect(.equal);
            return .{ .type_decl = .{ .@"struct" = try self.parseStructDecl(name) } };
        }
        if (self.peek(.equal) and self.peekAheadText(1, "union")) {
            try self.expect(.equal);
            return .{ .type_decl = .{ .@"union" = try self.parseUnionDecl(name) } };
        }
        const untyped_section = try self.parsePlacementSection();
        if (self.peek(.equal) and self.isTopLevelStringExprStartAt(1, known_strings)) {
            try self.expect(.equal);
            var bytes_list: std.ArrayList(u8) = .empty;
            errdefer bytes_list.deinit(self.allocator);
            try self.appendCompileTimeStringPart(&bytes_list, known_strings);
            while (self.eat(.plus_plus)) {
                try self.appendCompileTimeStringPart(&bytes_list, known_strings);
            }
            try self.expect(.semicolon);
            const constant_name = if (self.function_prefix.len == 0)
                name
            else
                try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ self.function_prefix, name });
            errdefer if (self.function_prefix.len != 0) self.allocator.free(constant_name);
            const bytes = try bytes_list.toOwnedSlice(self.allocator);
            errdefer if (bytes.len != 0) self.allocator.free(bytes);
            if (bytes.len > 255) return error.Overflow;
            try self.recordPlacementSection(constant_name, untyped_section, false);
            return .{ .string = .{
                .name = constant_name,
                .name_owned = self.function_prefix.len != 0,
                .module_owner = self.moduleOwner(),
                .bytes = bytes,
            } };
        }

        if ((self.peek(.colon) and self.peekAhead(1, .l_bracket)) or (self.peek(.equal) and self.isArrayLiteralStartAt(1))) {
            var explicit_ty: ?ast.Type = null;
            if (self.eat(.colon)) explicit_ty = try self.parseType();
            const section = untyped_section orelse try self.parsePlacementSection();
            try self.expect(.equal);
            const literal = try self.parseArrayLiteral();
            errdefer ast.freeExpr(self.allocator, .{ .array_literal = literal });
            try self.expect(.semicolon);
            const array_ty = try self.resolveArrayLiteralType(explicit_ty, literal);
            try self.validateArrayLiteral(array_ty, literal);
            const constant_name = if (self.function_prefix.len == 0)
                name
            else
                try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ self.function_prefix, name });
            errdefer if (self.function_prefix.len != 0) self.allocator.free(constant_name);
            try self.recordPlacementSection(constant_name, section, false);
            return .{ .array = .{
                .name = constant_name,
                .name_owned = self.function_prefix.len != 0,
                .module_owner = self.moduleOwner(),
                .ty = array_ty,
                .values = literal.values,
            } };
        }
        if (untyped_section != null) return error.InvalidMachineDeclaration;

        while (!self.peek(.semicolon) and !self.peek(.eof)) self.index += 1;
        try self.expect(.semicolon);
        return null;
    }

    fn parseZeroPageOptions(self: *Parser) ParseError!ast.ZeroPageOptions {
        try self.expect(.period);
        try self.expect(.l_brace);
        var options: ast.ZeroPageOptions = .{ .declared = true };
        errdefer options.deinit(self.allocator);
        var seen_image = false;
        var seen_memory = false;
        var seen_zero_page = false;
        var seen_stack = false;
        var seen_abi = false;
        var seen_heaps = false;
        var seen_reu = false;
        var seen_modules = false;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "image")) {
                if (seen_image) return error.UnsupportedZeroPageOptions;
                seen_image = true;
                self.legacy_memory_options = true;
                options.image = try self.parseZeroPageImageOptions();
            } else if (std.mem.eql(u8, field, "memory")) {
                if (seen_memory) return error.UnsupportedZeroPageOptions;
                seen_memory = true;
                self.legacy_memory_options = true;
                options.memory = try self.parseZeroPageMemoryOptions();
            } else if (std.mem.eql(u8, field, "zero_page")) {
                if (seen_zero_page) return error.UnsupportedZeroPagePolicy;
                seen_zero_page = true;
                self.legacy_memory_options = true;
                options.zero_page = try self.parseZeroPagePolicy();
            } else if (std.mem.eql(u8, field, "stack")) {
                if (seen_stack) return error.UnsupportedZeroPageOptions;
                seen_stack = true;
                self.legacy_memory_options = true;
                options.stack = try self.parseZeroPageStackOptions();
            } else if (std.mem.eql(u8, field, "abi")) {
                if (seen_abi) return error.UnsupportedZeroPageOptions;
                seen_abi = true;
                options.abi = try self.parseZeroPageAbiOptions();
            } else if (std.mem.eql(u8, field, "heaps")) {
                if (seen_heaps) return error.UnsupportedZeroPageOptions;
                seen_heaps = true;
                self.legacy_memory_options = true;
                options.heaps = try self.parseZeroPageHeapOptions();
            } else if (std.mem.eql(u8, field, "reu")) {
                if (seen_reu) return error.UnsupportedZeroPageOptions;
                seen_reu = true;
                self.legacy_memory_options = true;
                options.reu = try self.parseZeroPageReuOptions();
            } else if (std.mem.eql(u8, field, "modules")) {
                if (seen_modules) return error.UnsupportedZeroPageOptions;
                seen_modules = true;
                options.modules = try self.parseZeroPageModuleLoaderOptions();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return options;
    }

    fn finishZeroPageOptions(self: *Parser, options: *ast.ZeroPageOptions) ParseError!void {
        if (!options.declared) return;
        try self.resolveZeroPageMemoryReferences(options);
        // All fields are available now, so policy validation is independent of
        // the source ordering of .stack and .zero_page. Legacy configurations
        // retain their existing reserved-pointer diagnostic.
        if (options.stack) |stack| {
            if (!options.zero_page.declared or options.zero_page.profile == .compatibility) {
                validateZeroPageStackZeroPage(stack.zp) catch return error.InvalidZeroPageStackZeroPage;
            }
        }
        zero_page.validate(options.zero_page, if (options.stack) |stack| .{ .sp = stack.zp.sp, .fp = stack.zp.fp } else null) catch return error.InvalidZeroPagePolicy;
    }

    fn parsePlacementSection(self: *Parser) ParseError!?[]const u8 {
        if (!self.eatWord("linksection")) return null;
        try self.expect(.l_paren);
        const section = self.parseString() catch return error.UnknownPlacementSection;
        if (!self.eat(.r_paren)) return error.UnknownPlacementSection;
        return section;
    }

    fn recordPlacementSection(self: *Parser, name: []const u8, section: ?[]const u8, is_function: bool) ParseError!void {
        if (section) |value| {
            if (self.function_prefix.len != 0) return error.UnsupportedImportedZeroPageOptions;
            try self.placement_members.append(self.allocator, .{ .name = name, .section = value, .is_function = is_function });
        }
    }

    fn applyPlacementMembers(self: *Parser, placements: []ast.MemoryPlacement) ParseError!void {
        for (self.placement_members.items) |member| {
            for (placements) |*placement| {
                if (!std.mem.eql(u8, member.section, placement.name)) continue;
                const names = if (member.is_function) &placement.functions else &placement.constants;
                for (names.*) |name| {
                    if (std.mem.eql(u8, member.name, name)) return error.InvalidMachineDeclaration;
                }
                const old = names.*;
                names.* = try std.mem.concat(self.allocator, []const u8, &.{ old, &.{member.name} });
                if (old.len != 0) self.allocator.free(old);
                break;
            } else return error.UnknownPlacementSection;
        }
    }

    fn parseMemoryDeclaration(self: *Parser) ParseError!ast.ZeroPageOptions {
        try self.expectWord("memory");
        try self.expect(.l_brace);
        var options: ast.ZeroPageOptions = .{ .declared = true };
        errdefer options.deinit(self.allocator);
        var regions: std.ArrayList(ast.MemoryRegion) = .empty;
        defer regions.deinit(self.allocator);
        var placements: std.ArrayList(ast.MemoryPlacement) = .empty;
        defer placements.deinit(self.allocator);
        var heaps: std.ArrayList(ast.HeapOptions) = .empty;
        defer heaps.deinit(self.allocator);
        var near_heaps: std.ArrayList(ast.HeapOptions) = .empty;
        defer near_heaps.deinit(self.allocator);
        var far_heaps: std.ArrayList(ast.ReuHeapOptions) = .empty;
        defer far_heaps.deinit(self.allocator);
        var seen_image = false;
        while (!self.eat(.r_brace)) {
            const Clause = enum { region, stack, placement, arena, pool, image, zero_page };
            const clause = std.meta.stringToEnum(Clause, try self.expectIdent()) orelse return error.InvalidMachineDeclaration;
            switch (clause) {
                .region => {
                    const name = try self.expectIdent();
                    for (regions.items) |region| {
                        if (std.mem.eql(u8, name, region.name)) return error.InvalidZeroPageMemoryRegion;
                    }
                    try self.expect(.colon);
                    const space = std.meta.stringToEnum(ast.MemoryAddressSpace, try self.expectIdent()) orelse return error.InvalidZeroPageMemoryRegion;
                    try self.expectWord("at");
                    const addr = try self.parseU32();
                    try self.expectWord("size");
                    const size = try self.parseU32();
                    const bank = if (self.eatWord("bank")) try self.parseZeroPageModuleWindowBank() else .visible;
                    try regions.append(self.allocator, .{ .name = name, .addr = addr, .size = size, .space = space, .bank = bank });
                },
                .stack => {
                    if (options.stack != null) return error.InvalidMachineDeclaration;
                    try self.expectWord("in");
                    const name = try self.expectIdent();
                    var zp: ast.StackZeroPageOptions = .{};
                    if (self.eatWord("zp")) {
                        try self.expectWord("sp");
                        zp.sp = try self.parseU8();
                        try self.expectWord("fp");
                        zp.fp = try self.parseU8();
                    }
                    options.stack = .{ .base = 0, .size = 0, .region_name = name, .zp = zp };
                },
                .placement => {
                    const name = try self.expectIdent();
                    for (placements.items) |placement| {
                        if (std.mem.eql(u8, name, placement.name)) return error.InvalidMachineDeclaration;
                    }
                    try self.expectWord("in");
                    const region_name = try self.expectIdent();
                    const load: ast.MemoryPlacementLoad = if (self.eatWord("load")) blk: {
                        try self.expect(.period);
                        break :blk std.meta.stringToEnum(ast.MemoryPlacementLoad, try self.expectIdent()) orelse return error.InvalidMachineDeclaration;
                    } else .direct;
                    try placements.append(self.allocator, .{ .name = name, .region_name = region_name, .load = load });
                },
                .arena, .pool => {
                    const name = try self.expectIdent();
                    for ([_][]const u8{ "c64", "ZeroPage", "test6502" }) |builtin| {
                        if (std.mem.eql(u8, name, builtin)) return error.InvalidMachineDeclaration;
                    }
                    for (heaps.items) |heap| {
                        if (std.mem.eql(u8, name, heap.name)) return error.DuplicateZeroPageHeapOption;
                    }
                    try self.expectWord("in");
                    const region_name = try self.expectIdent();
                    const block = if (clause == .pool) blk: {
                        try self.expectWord("block");
                        break :blk try self.parseU16();
                    } else null;
                    try heaps.append(self.allocator, .{ .name = name, .addr = 0, .size = 0, .region_name = region_name, .kind = if (clause == .pool) .fixed else .arena, .block = block });
                },
                .image => {
                    if (seen_image) return error.InvalidMachineDeclaration;
                    seen_image = true;
                    try self.expectWord("prg");
                    options.image = try self.parseZeroPageImageFields(true);
                    continue;
                },
                .zero_page => {
                    if (options.zero_page.declared) return error.InvalidMachineDeclaration;
                    options.zero_page = try self.parseZeroPagePolicyFields(true);
                    continue;
                },
            }
            try self.expectMachineSemicolon();
        }

        for (heaps.items) |heap| {
            for (regions.items) |region| {
                if (!std.mem.eql(u8, region.name, heap.region_name.?)) continue;
                switch (region.space) {
                    .c64 => try near_heaps.append(self.allocator, heap),
                    .reu => {
                        if (heap.kind != .arena) return error.InvalidZeroPageMemoryRegion;
                        try far_heaps.append(self.allocator, .{ .name = heap.name, .addr = 0, .size = 0, .region_name = region.name, .kind = .arena });
                    },
                }
                break;
            } else return error.UnknownZeroPageMemoryRegion;
        }
        options.memory.regions = try regions.toOwnedSlice(self.allocator);
        options.memory.placements = try placements.toOwnedSlice(self.allocator);
        options.heaps = try near_heaps.toOwnedSlice(self.allocator);
        options.reu.heaps = try far_heaps.toOwnedSlice(self.allocator);
        return options;
    }

    fn mergeMemoryDeclaration(options: *ast.ZeroPageOptions, declared: *ast.ZeroPageOptions) void {
        if (!declared.declared) return;
        options.declared = true;
        options.memory = declared.memory;
        options.stack = declared.stack;
        options.image = declared.image;
        options.zero_page = declared.zero_page;
        options.heaps = declared.heaps;
        options.reu = declared.reu;
        declared.* = .{};
    }

    fn parseZeroPagePolicy(self: *Parser) ParseError!zero_page.Options {
        try self.expect(.period);
        return self.parseZeroPagePolicyFields(false);
    }

    fn parseZeroPagePolicyFields(self: *Parser, machine: bool) ParseError!zero_page.Options {
        try self.expect(.l_brace);
        var options: zero_page.Options = .{ .declared = true };
        errdefer options.deinit(self.allocator);
        var ranges: std.ArrayList(zero_page.Range) = .empty;
        defer ranges.deinit(self.allocator);
        var reserve: std.ArrayList(zero_page.Range) = .empty;
        defer reserve.deinit(self.allocator);
        const Field = enum { profile, allocation, ranges, reserve, restore_basic, interrupts };
        var seen: u8 = 0;
        while (!self.peek(.r_brace)) {
            if (machine and (self.peekAheadText(0, "range") or self.peekAheadText(0, "reserve"))) {
                const list = if (self.eatWord("range")) blk: {
                    options.ranges_declared = true;
                    break :blk &ranges;
                } else blk: {
                    try self.expectWord("reserve");
                    break :blk &reserve;
                };
                try self.expectWord("at");
                const addr = try self.parseU16();
                try self.expectWord("size");
                const size = try self.parseU16();
                try self.expectMachineSemicolon();
                try list.append(self.allocator, .{ .addr = addr, .size = size });
                continue;
            }
            const name = try self.parseDeclarationFieldName(machine);
            const field = std.meta.stringToEnum(Field, name) orelse return error.UnsupportedZeroPagePolicy;
            const bit = @as(u8, 1) << @intFromEnum(field);
            if (seen & bit != 0) return error.UnsupportedZeroPagePolicy;
            seen |= bit;
            switch (field) {
                .profile => {
                    try self.expect(.period);
                    options.profile = std.meta.stringToEnum(@TypeOf(options.profile), try self.expectIdent()) orelse return error.UnsupportedZeroPagePolicy;
                },
                .allocation => {
                    try self.expect(.period);
                    options.allocation = std.meta.stringToEnum(@TypeOf(options.allocation), try self.expectIdent()) orelse return error.UnsupportedZeroPagePolicy;
                },
                .ranges => {
                    if (machine) return error.UnsupportedZeroPagePolicy;
                    options.ranges = try self.parseZeroPagePolicyRanges();
                    options.ranges_declared = true;
                },
                .reserve => options.reserve = try self.parseZeroPagePolicyRanges(),
                .restore_basic => options.restore_basic = self.parseBoolLiteral() catch return error.UnsupportedZeroPagePolicy,
                .interrupts => {
                    try self.expect(.period);
                    options.interrupts = std.meta.stringToEnum(@TypeOf(options.interrupts), try self.expectIdent()) orelse return error.UnsupportedZeroPagePolicy;
                },
            }
            try self.endDeclarationField(machine);
        }
        try self.expect(.r_brace);
        if (machine) {
            options.ranges = try ranges.toOwnedSlice(self.allocator);
            options.reserve = try reserve.toOwnedSlice(self.allocator);
        }
        return options;
    }

    fn parseZeroPagePolicyRanges(self: *Parser) ParseError![]zero_page.Range {
        try self.expect(.period);
        try self.expect(.l_brace);
        var ranges: std.ArrayList(zero_page.Range) = .empty;
        errdefer ranges.deinit(self.allocator);
        while (!self.peek(.r_brace)) {
            try self.expect(.period);
            try self.expect(.l_brace);
            var addr: ?u16 = null;
            var size: ?u16 = null;
            while (!self.peek(.r_brace)) {
                const field = try self.parseMetadataFieldName();
                if (std.mem.eql(u8, field, "addr")) {
                    if (addr != null) return error.UnsupportedZeroPagePolicy;
                    addr = self.parseU16() catch return error.UnsupportedZeroPagePolicy;
                } else if (std.mem.eql(u8, field, "size")) {
                    if (size != null) return error.UnsupportedZeroPagePolicy;
                    size = self.parseU16() catch return error.UnsupportedZeroPagePolicy;
                } else return error.UnsupportedZeroPagePolicy;
                try self.consumeMetadataCommaOrEnd();
            }
            try self.expect(.r_brace);
            try ranges.append(self.allocator, .{ .addr = addr orelse return error.UnsupportedZeroPagePolicy, .size = size orelse return error.UnsupportedZeroPagePolicy });
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return try ranges.toOwnedSlice(self.allocator);
    }

    fn parseZeroPageMemoryOptions(self: *Parser) ParseError!ast.MemoryOptions {
        try self.expect(.period);
        try self.expect(.l_brace);
        var options: ast.MemoryOptions = .{};
        errdefer options.deinit(self.allocator);
        var seen_regions = false;
        var seen_placements = false;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "regions")) {
                if (seen_regions) return error.UnsupportedZeroPageOptions;
                seen_regions = true;
                options.regions = try self.parseZeroPageMemoryRegions();
            } else if (std.mem.eql(u8, field, "placements")) {
                if (seen_placements) return error.UnsupportedZeroPageOptions;
                seen_placements = true;
                options.placements = try self.parseZeroPageMemoryPlacements();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return options;
    }

    fn parseZeroPageMemoryPlacements(self: *Parser) ParseError![]ast.MemoryPlacement {
        try self.expect(.period);
        try self.expect(.l_brace);
        var placements: std.ArrayList(ast.MemoryPlacement) = .empty;
        errdefer {
            for (placements.items) |placement| placement.deinit(self.allocator);
            placements.deinit(self.allocator);
        }
        while (!self.peek(.r_brace)) {
            const name = try self.parseMetadataFieldName();
            for (placements.items) |placement| {
                if (std.mem.eql(u8, placement.name, name)) return error.InvalidZeroPageMemoryRegion;
            }
            try placements.append(self.allocator, try self.parseZeroPageMemoryPlacement(name));
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return try placements.toOwnedSlice(self.allocator);
    }

    fn parseZeroPageMemoryPlacement(self: *Parser, name: []const u8) ParseError!ast.MemoryPlacement {
        try self.expect(.period);
        try self.expect(.l_brace);
        var region_name: ?[]const u8 = null;
        var load: ast.MemoryPlacementLoad = .direct;
        var seen_load = false;
        var functions: ?[]const []const u8 = null;
        var constants: ?[]const []const u8 = null;
        errdefer if (functions) |items| self.allocator.free(items);
        errdefer if (constants) |items| self.allocator.free(items);
        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "region")) {
                if (region_name != null) return error.UnsupportedZeroPageOptions;
                try self.expect(.period);
                region_name = try self.expectIdent();
            } else if (std.mem.eql(u8, field, "load")) {
                if (seen_load) return error.UnsupportedZeroPageOptions;
                seen_load = true;
                try self.expect(.period);
                const value = try self.expectIdent();
                if (std.mem.eql(u8, value, "direct")) {
                    load = .direct;
                } else if (std.mem.eql(u8, value, "startup_copy")) {
                    load = .startup_copy;
                } else {
                    return error.UnsupportedZeroPageOptions;
                }
            } else if (std.mem.eql(u8, field, "functions")) {
                if (functions != null) return error.UnsupportedZeroPageOptions;
                functions = try self.parseMetadataIdentifierTuple();
            } else if (std.mem.eql(u8, field, "constants")) {
                if (constants != null) return error.UnsupportedZeroPageOptions;
                constants = try self.parseMetadataIdentifierTuple();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        const resolved_functions = functions orelse &.{};
        const resolved_constants = constants orelse &.{};
        if (resolved_functions.len == 0 and resolved_constants.len == 0) return error.InvalidZeroPageMemoryRegion;
        return .{
            .name = name,
            .region_name = region_name orelse return error.UnsupportedZeroPageOptions,
            .load = load,
            .functions = resolved_functions,
            .constants = resolved_constants,
        };
    }

    fn parseMetadataIdentifierTuple(self: *Parser) ParseError![]const []const u8 {
        try self.expect(.period);
        try self.expect(.l_brace);
        var values: std.ArrayList([]const u8) = .empty;
        errdefer values.deinit(self.allocator);
        while (!self.peek(.r_brace)) {
            const value = try self.expectIdent();
            for (values.items) |existing| {
                if (std.mem.eql(u8, existing, value)) return error.InvalidZeroPageMemoryRegion;
            }
            try values.append(self.allocator, value);
            if (!self.eat(.comma)) break;
        }
        try self.expect(.r_brace);
        return try values.toOwnedSlice(self.allocator);
    }

    fn parseZeroPageMemoryRegions(self: *Parser) ParseError![]ast.MemoryRegion {
        try self.expect(.period);
        try self.expect(.l_brace);
        var regions: std.ArrayList(ast.MemoryRegion) = .empty;
        errdefer regions.deinit(self.allocator);
        while (!self.peek(.r_brace)) {
            const name = try self.parseMetadataFieldName();
            for (regions.items) |region| {
                if (std.mem.eql(u8, region.name, name)) return error.InvalidZeroPageMemoryRegion;
            }
            try regions.append(self.allocator, try self.parseZeroPageMemoryRegion(name));
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return try regions.toOwnedSlice(self.allocator);
    }

    fn parseZeroPageMemoryRegion(self: *Parser, name: []const u8) ParseError!ast.MemoryRegion {
        try self.expect(.period);
        try self.expect(.l_brace);
        var addr: ?u32 = null;
        var size: ?u32 = null;
        var space: ast.MemoryAddressSpace = .c64;
        var bank: ast.ModuleWindowBank = .visible;
        var seen_space = false;
        var seen_bank = false;
        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "addr")) {
                if (addr != null) return error.UnsupportedZeroPageOptions;
                addr = try self.parseU32();
            } else if (std.mem.eql(u8, field, "size")) {
                if (size != null) return error.UnsupportedZeroPageOptions;
                size = try self.parseU32();
            } else if (std.mem.eql(u8, field, "space")) {
                if (seen_space) return error.UnsupportedZeroPageOptions;
                seen_space = true;
                try self.expect(.period);
                const value = try self.expectIdent();
                if (std.mem.eql(u8, value, "c64")) {
                    space = .c64;
                } else if (std.mem.eql(u8, value, "reu")) {
                    space = .reu;
                } else {
                    return error.InvalidZeroPageMemoryRegion;
                }
            } else if (std.mem.eql(u8, field, "bank")) {
                if (seen_bank) return error.UnsupportedZeroPageOptions;
                seen_bank = true;
                bank = try self.parseZeroPageModuleWindowBank();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        if (space == .reu and bank != .visible) return error.InvalidZeroPageMemoryRegion;
        return .{ .name = name, .addr = addr orelse return error.UnsupportedZeroPageOptions, .size = size orelse return error.UnsupportedZeroPageOptions, .space = space, .bank = bank };
    }

    fn parseZeroPageImageOptions(self: *Parser) ParseError!ast.ImageOptions {
        try self.expect(.period);
        return self.parseZeroPageImageFields(false);
    }

    fn parseZeroPageImageFields(self: *Parser, machine: bool) ParseError!ast.ImageOptions {
        try self.expect(.l_brace);
        var options: ast.ImageOptions = .{};
        var seen_format = false;
        var seen_load_addr = false;
        var seen_entry_addr = false;
        var seen_basic_stub = false;
        var seen_address_limit = false;

        while (!self.peek(.r_brace)) {
            const field = try self.parseDeclarationFieldName(machine);
            if (std.mem.eql(u8, field, "format")) {
                if (machine or seen_format) return error.UnsupportedZeroPageOptions;
                seen_format = true;
                try self.expect(.period);
                const name = try self.expectIdent();
                if (!std.mem.eql(u8, name, "prg")) return error.UnsupportedZeroPageOptions;
                options.format = .prg;
            } else if (std.mem.eql(u8, field, "load_addr")) {
                if (seen_load_addr) return error.UnsupportedZeroPageOptions;
                seen_load_addr = true;
                options.load_addr = try self.parseU16();
            } else if (std.mem.eql(u8, field, "entry_addr")) {
                if (seen_entry_addr) return error.UnsupportedZeroPageOptions;
                seen_entry_addr = true;
                options.entry_addr = try self.parseU16();
            } else if (std.mem.eql(u8, field, "basic_stub")) {
                if (seen_basic_stub) return error.UnsupportedZeroPageOptions;
                seen_basic_stub = true;
                options.basic_stub = try self.parseBoolLiteral();
            } else if (std.mem.eql(u8, field, "address_limit")) {
                if (seen_address_limit) return error.UnsupportedZeroPageOptions;
                seen_address_limit = true;
                options.address_limit = try self.parseU32();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.endDeclarationField(machine);
        }
        try self.expect(.r_brace);
        return options;
    }

    fn resolveZeroPageMemoryReferences(self: *Parser, options: *ast.ZeroPageOptions) ParseError!void {
        if (options.stack) |*stack| {
            if (stack.region_name) |name| {
                const region = try self.requireMemoryRegion(options.memory, name, .c64);
                if (region.bank != .visible) return error.InvalidZeroPageMemoryRegion;
                stack.base = try memoryRegionU16(region.addr);
                stack.size = try memoryRegionU16(region.size);
            }
        }
        for (options.heaps) |*heap| {
            if (heap.region_name) |name| {
                const region = try self.requireMemoryRegion(options.memory, name, .c64);
                if (region.bank != .visible) return error.InvalidZeroPageMemoryRegion;
                heap.addr = try memoryRegionU16(region.addr);
                heap.size = try memoryRegionU16(region.size);
            }
        }
        for (options.reu.heaps) |*heap| {
            if (heap.region_name) |name| {
                const region = try self.requireMemoryRegion(options.memory, name, .reu);
                heap.addr = region.addr;
                heap.size = region.size;
            }
        }
        if (options.modules) |*modules| {
            try self.resolveModuleWindowReference(options.memory, &modules.load_window);
            for (modules.extra_load_windows) |*entry| try self.resolveModuleWindowReference(options.memory, &entry.window);
            if (modules.disk_staging) |*staging| try self.resolveModuleWindowReference(options.memory, staging);
            if (modules.reu_cache.region_name) |name| {
                const region = try self.requireMemoryRegion(options.memory, name, .reu);
                modules.reu_cache.addr = region.addr;
                modules.reu_cache.size = region.size;
            }
        }
    }

    fn resolveModuleWindowReference(self: *Parser, memory: ast.MemoryOptions, window: *ast.ModuleLoadWindowOptions) ParseError!void {
        if (window.region_name) |name| {
            const region = try self.requireMemoryRegion(memory, name, .c64);
            window.addr = try memoryRegionU16(region.addr);
            window.size = try memoryRegionU16(region.size);
            window.bank = region.bank;
        }
    }

    fn requireMemoryRegion(self: *Parser, memory: ast.MemoryOptions, name: []const u8, space: ast.MemoryAddressSpace) ParseError!ast.MemoryRegion {
        _ = self;
        const region = memory.findRegion(name) orelse return error.UnknownZeroPageMemoryRegion;
        if (region.space != space) return error.InvalidZeroPageMemoryRegion;
        return region;
    }

    const ModuleRowDeclaration = struct {
        file: ?[]const u8 = null,
        load_file: ?[]const u8 = null,
        window: ?[]const u8 = null,
        mode: ?ast.ModuleLoadMode = null,
        graph_load: bool = false,
        deps: ?[]const []const u8 = null,
        ranges: []ast.ModuleStateRange = &.{},
        discard: bool = false,

        fn deinit(self: ModuleRowDeclaration, allocator: std.mem.Allocator) void {
            if (self.deps) |deps| allocator.free(deps);
            allocator.free(self.ranges);
        }
    };

    fn parseModuleRowDeclaration(self: *Parser, current: bool) ParseError!ModuleRowDeclaration {
        const Field = enum { file, load_file, window, load, graph, requires, persist_in_reu, discard_on_unload };
        var row: ModuleRowDeclaration = .{};
        errdefer row.deinit(self.allocator);
        var ranges: std.ArrayList(ast.ModuleStateRange) = .empty;
        defer ranges.deinit(self.allocator);
        var seen: u8 = 0;
        try self.expect(.l_brace);
        while (!self.eat(.r_brace)) {
            const field = std.meta.stringToEnum(Field, try self.expectIdent()) orelse return error.InvalidMachineDeclaration;
            const bit = @as(u8, 1) << @intFromEnum(field);
            if (field != .persist_in_reu and seen & bit != 0) return error.InvalidMachineDeclaration;
            seen |= bit;
            switch (field) {
                .file => {
                    try self.expect(.equal);
                    row.file = try self.parseString();
                },
                .load_file => {
                    if (!current) return error.InvalidMachineDeclaration;
                    try self.expect(.equal);
                    row.load_file = try self.parseString();
                },
                .window => {
                    try self.expect(.equal);
                    row.window = try self.expectIdent();
                },
                .load => {
                    try self.expect(.equal);
                    row.mode = try self.parseZeroPageModuleLoadMode();
                },
                .graph => {
                    if (current) return error.InvalidMachineDeclaration;
                    try self.expect(.equal);
                    row.graph_load = try self.parseBoolLiteral();
                },
                .requires => {
                    if (current) return error.InvalidMachineDeclaration;
                    try self.expect(.equal);
                    row.deps = try self.parseZeroPageModuleDependencyGraphDeps();
                },
                .persist_in_reu => {
                    try self.expectWord("at");
                    const offset = try self.parseU16();
                    try self.expectWord("size");
                    const size = try self.parseU16();
                    try ranges.append(self.allocator, .{ .offset = offset, .size = size });
                },
                .discard_on_unload => row.discard = true,
            }
            try self.expectMachineSemicolon();
        }
        if (seen == 0 or (row.discard and ranges.items.len != 0) or (row.graph_load and row.mode == null)) return error.InvalidMachineDeclaration;
        row.ranges = try ranges.toOwnedSlice(self.allocator);
        return row;
    }

    fn parseModuleLoaderDeclaration(self: *Parser) ParseError!ast.ModuleLoaderOptions {
        const Row = struct { id: []const u8, decl: ModuleRowDeclaration };
        var rows: std.ArrayList(Row) = .empty;
        defer {
            for (rows.items) |row| row.decl.deinit(self.allocator);
            rows.deinit(self.allocator);
        }
        var current: ?ModuleRowDeclaration = null;
        defer if (current) |row| row.deinit(self.allocator);
        var windows: std.ArrayList(ast.ModuleNamedLoadWindow) = .empty;
        defer windows.deinit(self.allocator);
        var main: ?ast.ModuleLoadWindowOptions = null;
        var cache: ?ast.ModuleReuCacheOptions = null;
        var staging: ?ast.ModuleLoadWindowOptions = null;
        var registry: ?ast.ModuleRegistryOptions = null;
        try self.expectWord("module_loader");
        try self.expect(.l_brace);
        while (!self.eat(.r_brace)) {
            const Field = enum { window, reu_cache, disk_staging, capacity, current, dependency };
            const field = std.meta.stringToEnum(Field, try self.expectIdent()) orelse return error.InvalidMachineDeclaration;
            switch (field) {
                .window => {
                    const name = try self.expectIdent();
                    try self.expectWord("in");
                    const window: ast.ModuleLoadWindowOptions = .{ .addr = 0, .size = 0, .region_name = try self.expectIdent() };
                    if (std.mem.eql(u8, name, "main")) {
                        if (main != null) return error.InvalidMachineDeclaration;
                        main = window;
                    } else {
                        for (windows.items) |existing| {
                            if (std.mem.eql(u8, name, existing.name)) return error.InvalidMachineDeclaration;
                        }
                        try windows.append(self.allocator, .{ .name = name, .window = window });
                    }
                },
                .reu_cache => {
                    if (cache != null) return error.InvalidMachineDeclaration;
                    try self.expectWord("in");
                    cache = .{ .addr = 0, .size = 0, .region_name = try self.expectIdent() };
                },
                .disk_staging => {
                    if (staging != null) return error.InvalidMachineDeclaration;
                    try self.expectWord("in");
                    staging = .{ .addr = 0, .size = 0, .region_name = try self.expectIdent() };
                },
                .capacity => {
                    if (registry != null) return error.InvalidMachineDeclaration;
                    try self.expect(.equal);
                    const capacity = try self.parseU8();
                    if (capacity == 0) return error.InvalidMachineDeclaration;
                    registry = .{ .capacity = capacity };
                },
                .current => {
                    if (current != null) return error.InvalidMachineDeclaration;
                    current = try self.parseModuleRowDeclaration(true);
                    continue;
                },
                .dependency => {
                    const name = if (self.peek(.string_literal)) try self.parseString() else try self.expectIdent();
                    const id = if (self.findModuleBinding(name)) |binding| binding.module_id else name;
                    if (!isValidModuleId(id)) return error.InvalidZeroPageModuleId;
                    for (rows.items) |existing| {
                        if (std.mem.eql(u8, id, existing.id)) return error.DuplicateZeroPageModuleDependency;
                    }
                    const row = try self.parseModuleRowDeclaration(false);
                    errdefer row.deinit(self.allocator);
                    try rows.append(self.allocator, .{ .id = id, .decl = row });
                    continue;
                },
            }
            try self.expectMachineSemicolon();
        }

        var loader: ast.ModuleLoaderOptions = .{
            .load_window = main orelse return error.InvalidMachineDeclaration,
            .reu_cache = cache orelse return error.InvalidMachineDeclaration,
            .disk_staging = staging,
            .registry = registry,
        };
        errdefer loader.deinit(self.allocator);
        const own = current orelse ModuleRowDeclaration{};
        if (own.load_file != null and (own.mode == null or own.mode == .manual)) return error.InvalidMachineDeclaration;
        if (own.window) |window| {
            if (!std.mem.eql(u8, window, "main")) return error.InvalidMachineDeclaration;
        }
        var assignments: std.ArrayList(ast.ModuleWindowAssignment) = .empty;
        defer assignments.deinit(self.allocator);
        var filenames: std.ArrayList(ast.ModuleDiskManifestDependency) = .empty;
        defer filenames.deinit(self.allocator);
        var policies: std.ArrayList(ast.DependencyModulePolicy) = .empty;
        defer policies.deinit(self.allocator);
        var nodes: std.ArrayList(ast.ModuleDependencyGraphNode) = .empty;
        defer nodes.deinit(self.allocator);
        errdefer for (nodes.items) |node| node.deinit(self.allocator);
        var states: std.ArrayList(ast.DependencyModuleState) = .empty;
        defer states.deinit(self.allocator);
        errdefer for (states.items) |state| state.state.deinit(self.allocator);
        for (rows.items) |row| {
            const decl = row.decl;
            if (decl.window) |name| try assignments.append(self.allocator, .{ .id = row.id, .window_name = name });
            if (decl.file) |file| try filenames.append(self.allocator, .{ .id = row.id, .filename = file });
            if (decl.mode) |mode| try policies.append(self.allocator, .{ .id = row.id, .policy = .{ .mode = mode, .graph = decl.graph_load } });
            if (decl.deps) |deps| {
                const copied = try self.allocator.dupe([]const u8, deps);
                errdefer self.allocator.free(copied);
                try nodes.append(self.allocator, .{ .id = row.id, .deps = copied });
            }
            if (decl.discard or decl.ranges.len != 0) {
                const copied = try self.allocator.dupe(ast.ModuleStateRange, decl.ranges);
                errdefer self.allocator.free(copied);
                try states.append(self.allocator, .{ .id = row.id, .state = .{ .mode = if (decl.discard) .discard_on_unload else .persist_in_reu, .ranges = copied } });
            }
        }
        loader.extra_load_windows = try windows.toOwnedSlice(self.allocator);
        loader.window_assignments = try assignments.toOwnedSlice(self.allocator);
        if (own.mode != null or policies.items.len != 0) loader.policy = .{
            .current = .{ .mode = own.mode orelse .manual, .filename = if (own.mode != null and own.mode != .manual) own.load_file orelse own.file else null },
            .deps = try policies.toOwnedSlice(self.allocator),
        };
        if (filenames.items.len != 0 or own.file != null) loader.disk_manifest = .{
            .current = own.file orelse return error.InvalidMachineDeclaration,
            .deps = try filenames.toOwnedSlice(self.allocator),
        };
        if (nodes.items.len != 0) loader.dependency_graph = .{ .nodes = try nodes.toOwnedSlice(self.allocator) };
        if (own.discard or own.ranges.len != 0 or states.items.len != 0) {
            const ranges = try self.allocator.dupe(ast.ModuleStateRange, own.ranges);
            errdefer self.allocator.free(ranges);
            loader.state = .{
                .current = .{ .mode = if (own.ranges.len != 0) .persist_in_reu else .discard_on_unload, .ranges = ranges },
                .deps = try states.toOwnedSlice(self.allocator),
            };
        }
        return loader;
    }

    fn parseZeroPageModuleLoaderOptions(self: *Parser) ParseError!ast.ModuleLoaderOptions {
        try self.expect(.period);
        try self.expect(.l_brace);
        var load_window: ?ast.ModuleLoadWindowOptions = null;
        var extra_load_windows: ?[]ast.ModuleNamedLoadWindow = null;
        var window_assignments: ?[]ast.ModuleWindowAssignment = null;
        var reu_cache: ?ast.ModuleReuCacheOptions = null;
        var disk_staging: ?ast.ModuleLoadWindowOptions = null;
        var policy: ?ast.ModulePolicyOptions = null;
        var registry: ?ast.ModuleRegistryOptions = null;
        var disk_manifest: ?ast.ModuleDiskManifestOptions = null;
        var dependency_graph: ?ast.ModuleDependencyGraphOptions = null;
        var state: ?ast.ModuleStateOptions = null;
        errdefer if (extra_load_windows) |windows| self.allocator.free(windows);
        errdefer if (window_assignments) |assignments| self.allocator.free(assignments);
        errdefer if (disk_manifest) |manifest| manifest.deinit(self.allocator);
        errdefer if (dependency_graph) |graph| graph.deinit(self.allocator);
        errdefer if (state) |module_state| module_state.deinit(self.allocator);

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "load_window")) {
                if (load_window != null) return error.UnsupportedZeroPageOptions;
                load_window = try self.parseZeroPageModuleLoadWindow(true);
            } else if (std.mem.eql(u8, field, "extra_load_windows")) {
                if (extra_load_windows != null) return error.UnsupportedZeroPageOptions;
                extra_load_windows = try self.parseZeroPageModuleExtraLoadWindows();
            } else if (std.mem.eql(u8, field, "window_assignments")) {
                if (window_assignments != null) return error.UnsupportedZeroPageOptions;
                window_assignments = try self.parseZeroPageModuleWindowAssignments();
            } else if (std.mem.eql(u8, field, "reu_cache")) {
                if (reu_cache != null) return error.UnsupportedZeroPageOptions;
                reu_cache = try self.parseZeroPageModuleReuCache();
            } else if (std.mem.eql(u8, field, "disk_staging")) {
                if (disk_staging != null) return error.UnsupportedZeroPageOptions;
                disk_staging = try self.parseZeroPageModuleLoadWindow(false);
            } else if (std.mem.eql(u8, field, "policy")) {
                if (policy != null) return error.UnsupportedZeroPageOptions;
                policy = try self.parseZeroPageModulePolicy();
            } else if (std.mem.eql(u8, field, "registry")) {
                if (registry != null) return error.UnsupportedZeroPageOptions;
                registry = try self.parseZeroPageModuleRegistry();
            } else if (std.mem.eql(u8, field, "disk_manifest")) {
                if (disk_manifest != null) return error.UnsupportedZeroPageOptions;
                disk_manifest = try self.parseZeroPageModuleDiskManifest();
            } else if (std.mem.eql(u8, field, "dependency_graph")) {
                if (dependency_graph != null) return error.UnsupportedZeroPageOptions;
                dependency_graph = try self.parseZeroPageModuleDependencyGraph();
            } else if (std.mem.eql(u8, field, "state")) {
                if (state != null) return error.UnsupportedZeroPageOptions;
                state = try self.parseZeroPageModuleState();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return .{
            .load_window = load_window orelse return error.UnsupportedZeroPageOptions,
            .extra_load_windows = extra_load_windows orelse &.{},
            .window_assignments = window_assignments orelse &.{},
            .reu_cache = reu_cache orelse return error.UnsupportedZeroPageOptions,
            .disk_staging = disk_staging,
            .policy = policy,
            .registry = registry,
            .disk_manifest = disk_manifest,
            .dependency_graph = dependency_graph,
            .state = state,
        };
    }

    fn parseZeroPageModuleExtraLoadWindows(self: *Parser) ParseError![]ast.ModuleNamedLoadWindow {
        try self.expect(.period);
        try self.expect(.l_brace);
        var windows: std.ArrayList(ast.ModuleNamedLoadWindow) = .empty;
        errdefer windows.deinit(self.allocator);

        while (!self.peek(.r_brace)) {
            const name = try self.parseMetadataFieldName();
            for (windows.items) |existing| {
                if (std.mem.eql(u8, existing.name, name)) return error.UnsupportedZeroPageOptions;
            }
            if (std.mem.eql(u8, name, "main")) return error.UnsupportedZeroPageOptions;
            try windows.append(self.allocator, .{
                .name = name,
                .window = try self.parseZeroPageModuleLoadWindow(true),
            });
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return try windows.toOwnedSlice(self.allocator);
    }

    fn parseZeroPageModuleWindowAssignments(self: *Parser) ParseError![]ast.ModuleWindowAssignment {
        try self.expect(.period);
        try self.expect(.l_brace);
        var assignments: std.ArrayList(ast.ModuleWindowAssignment) = .empty;
        errdefer assignments.deinit(self.allocator);

        while (!self.peek(.r_brace)) {
            const id = try self.parseMetadataFieldName();
            for (assignments.items) |existing| {
                if (std.mem.eql(u8, existing.id, id)) return error.UnsupportedZeroPageOptions;
            }
            try self.expect(.period);
            const window_name = try self.expectIdent();
            try assignments.append(self.allocator, .{ .id = id, .window_name = window_name });
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return try assignments.toOwnedSlice(self.allocator);
    }

    fn parseZeroPageModuleDependencyGraph(self: *Parser) ParseError!ast.ModuleDependencyGraphOptions {
        try self.expect(.period);
        try self.expect(.l_brace);
        var nodes: std.ArrayList(ast.ModuleDependencyGraphNode) = .empty;
        errdefer {
            for (nodes.items) |node| node.deinit(self.allocator);
            nodes.deinit(self.allocator);
        }

        while (!self.peek(.r_brace)) {
            const id = try self.parseMetadataFieldName();
            for (nodes.items) |existing| {
                if (std.mem.eql(u8, existing.id, id)) return error.UnsupportedZeroPageOptions;
            }
            const deps = try self.parseZeroPageModuleDependencyGraphNode();
            try nodes.append(self.allocator, .{ .id = id, .deps = deps });
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return .{ .nodes = try nodes.toOwnedSlice(self.allocator) };
    }

    fn parseZeroPageModuleDependencyGraphNode(self: *Parser) ParseError![]const []const u8 {
        try self.expect(.period);
        try self.expect(.l_brace);
        var deps: ?[]const []const u8 = null;
        errdefer if (deps) |items| self.allocator.free(items);

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "deps")) {
                if (deps != null) return error.UnsupportedZeroPageOptions;
                deps = try self.parseZeroPageModuleDependencyGraphDeps();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return deps orelse return error.UnsupportedZeroPageOptions;
    }

    fn parseZeroPageModuleDependencyGraphDeps(self: *Parser) ParseError![]const []const u8 {
        try self.expect(.period);
        try self.expect(.l_brace);
        var deps: std.ArrayList([]const u8) = .empty;
        errdefer deps.deinit(self.allocator);

        while (!self.peek(.r_brace)) {
            try self.expect(.period);
            const id = try self.expectIdent();
            for (deps.items) |existing| {
                if (std.mem.eql(u8, existing, id)) return error.UnsupportedZeroPageOptions;
            }
            try deps.append(self.allocator, id);
            if (!self.eat(.comma)) break;
        }
        try self.expect(.r_brace);
        return try deps.toOwnedSlice(self.allocator);
    }

    fn parseZeroPageModuleState(self: *Parser) ParseError!ast.ModuleStateOptions {
        try self.expect(.period);
        try self.expect(.l_brace);
        var current: ?ast.CurrentModuleState = null;
        var deps: ?[]const ast.DependencyModuleState = null;
        errdefer if (current) |state| state.deinit(self.allocator);
        errdefer if (deps) |items| {
            for (items) |item| item.deinit(self.allocator);
            self.allocator.free(items);
        };

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "current")) {
                if (current != null) return error.UnsupportedZeroPageOptions;
                current = try self.parseZeroPageCurrentModuleState();
            } else if (std.mem.eql(u8, field, "deps")) {
                if (deps != null) return error.UnsupportedZeroPageOptions;
                deps = try self.parseZeroPageDependencyModuleStates();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return .{
            .current = current orelse return error.UnsupportedZeroPageOptions,
            .deps = deps orelse &.{},
        };
    }

    fn parseZeroPageDependencyModuleStates(self: *Parser) ParseError![]const ast.DependencyModuleState {
        try self.expect(.period);
        try self.expect(.l_brace);
        var deps: std.ArrayList(ast.DependencyModuleState) = .empty;
        errdefer {
            for (deps.items) |dep| dep.deinit(self.allocator);
            deps.deinit(self.allocator);
        }

        while (!self.peek(.r_brace)) {
            const id = try self.parseMetadataFieldName();
            for (deps.items) |existing| {
                if (std.mem.eql(u8, existing.id, id)) return error.UnsupportedZeroPageOptions;
            }
            const state = try self.parseZeroPageCurrentModuleState();
            try deps.append(self.allocator, .{ .id = id, .state = state });
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return try deps.toOwnedSlice(self.allocator);
    }

    fn parseZeroPageCurrentModuleState(self: *Parser) ParseError!ast.CurrentModuleState {
        try self.expect(.period);
        try self.expect(.l_brace);
        var mode: ?ast.ModuleStateMode = null;
        var ranges: ?[]const ast.ModuleStateRange = null;
        errdefer if (ranges) |items| self.allocator.free(items);

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "mode")) {
                if (mode != null) return error.UnsupportedZeroPageOptions;
                mode = try self.parseZeroPageModuleStateMode();
            } else if (std.mem.eql(u8, field, "ranges")) {
                if (ranges != null) return error.UnsupportedZeroPageOptions;
                ranges = try self.parseZeroPageModuleStateRanges();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        const resolved_mode = mode orelse return error.UnsupportedZeroPageOptions;
        const resolved_ranges = ranges orelse &.{};
        if (resolved_mode == .persist_in_reu and resolved_ranges.len == 0) return error.UnsupportedZeroPageOptions;
        if (resolved_mode == .discard_on_unload and resolved_ranges.len != 0) return error.UnsupportedZeroPageOptions;
        return .{ .mode = resolved_mode, .ranges = resolved_ranges };
    }

    fn parseZeroPageModuleStateMode(self: *Parser) ParseError!ast.ModuleStateMode {
        try self.expect(.period);
        const name = try self.expectIdent();
        if (std.mem.eql(u8, name, "discard_on_unload")) return .discard_on_unload;
        if (std.mem.eql(u8, name, "persist_in_reu")) return .persist_in_reu;
        return error.UnsupportedZeroPageOptions;
    }

    fn parseZeroPageModuleStateRanges(self: *Parser) ParseError![]ast.ModuleStateRange {
        try self.expect(.period);
        try self.expect(.l_brace);
        var ranges: std.ArrayList(ast.ModuleStateRange) = .empty;
        errdefer ranges.deinit(self.allocator);

        while (!self.peek(.r_brace)) {
            try ranges.append(self.allocator, try self.parseZeroPageModuleStateRange());
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return try ranges.toOwnedSlice(self.allocator);
    }

    fn parseZeroPageModuleStateRange(self: *Parser) ParseError!ast.ModuleStateRange {
        try self.expect(.period);
        try self.expect(.l_brace);
        var offset: ?u16 = null;
        var size: ?u16 = null;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "offset")) {
                if (offset != null) return error.UnsupportedZeroPageOptions;
                offset = try self.parseU16();
            } else if (std.mem.eql(u8, field, "size")) {
                if (size != null) return error.UnsupportedZeroPageOptions;
                size = try self.parseU16();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return .{
            .offset = offset orelse return error.UnsupportedZeroPageOptions,
            .size = size orelse return error.UnsupportedZeroPageOptions,
        };
    }

    fn parseZeroPageModuleDiskManifest(self: *Parser) ParseError!ast.ModuleDiskManifestOptions {
        try self.expect(.period);
        try self.expect(.l_brace);
        var current: ?[]const u8 = null;
        var deps: ?[]ast.ModuleDiskManifestDependency = null;
        errdefer if (deps) |items| self.allocator.free(items);

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "current")) {
                if (current != null) return error.UnsupportedZeroPageOptions;
                current = try self.parseString();
            } else if (std.mem.eql(u8, field, "deps")) {
                if (deps != null) return error.UnsupportedZeroPageOptions;
                deps = try self.parseZeroPageModuleDiskManifestDeps();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return .{
            .current = current orelse return error.UnsupportedZeroPageOptions,
            .deps = deps orelse return error.UnsupportedZeroPageOptions,
        };
    }

    fn parseZeroPageModuleDiskManifestDeps(self: *Parser) ParseError![]ast.ModuleDiskManifestDependency {
        try self.expect(.period);
        try self.expect(.l_brace);
        var deps: std.ArrayList(ast.ModuleDiskManifestDependency) = .empty;
        errdefer deps.deinit(self.allocator);

        while (!self.peek(.r_brace)) {
            const id = try self.parseMetadataFieldName();
            const filename = try self.parseString();
            for (deps.items) |existing| {
                if (std.mem.eql(u8, existing.id, id)) return error.UnsupportedZeroPageOptions;
            }
            try deps.append(self.allocator, .{ .id = id, .filename = filename });
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return try deps.toOwnedSlice(self.allocator);
    }

    fn parseZeroPageModuleRegistry(self: *Parser) ParseError!ast.ModuleRegistryOptions {
        try self.expect(.period);
        try self.expect(.l_brace);
        var capacity: ?u8 = null;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "capacity")) {
                if (capacity != null) return error.UnsupportedZeroPageOptions;
                const value = try self.parseU8();
                if (value == 0) return error.UnsupportedZeroPageOptions;
                capacity = value;
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return .{ .capacity = capacity orelse return error.UnsupportedZeroPageOptions };
    }

    fn parseZeroPageModulePolicy(self: *Parser) ParseError!ast.ModulePolicyOptions {
        try self.expect(.period);
        try self.expect(.l_brace);
        var current: ?ast.CurrentModulePolicy = null;
        var deps: ?[]const ast.DependencyModulePolicy = null;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "current")) {
                if (current != null) return error.UnsupportedZeroPageOptions;
                current = try self.parseZeroPageCurrentModulePolicy();
            } else if (std.mem.eql(u8, field, "deps")) {
                if (deps != null) return error.UnsupportedZeroPageOptions;
                deps = try self.parseZeroPageDependencyModulePolicies();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return .{
            .current = current orelse return error.UnsupportedZeroPageOptions,
            .deps = deps orelse &.{},
        };
    }

    fn parseZeroPageDependencyModulePolicies(self: *Parser) ParseError![]const ast.DependencyModulePolicy {
        try self.expect(.period);
        try self.expect(.l_brace);
        var deps: std.ArrayList(ast.DependencyModulePolicy) = .empty;
        errdefer deps.deinit(self.allocator);

        while (!self.peek(.r_brace)) {
            const id = try self.parseMetadataFieldName();
            for (deps.items) |dep| {
                if (std.mem.eql(u8, dep.id, id)) return error.UnsupportedZeroPageOptions;
            }
            const policy = try self.parseZeroPageDependencyModulePolicy();
            try deps.append(self.allocator, .{ .id = id, .policy = policy });
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return try deps.toOwnedSlice(self.allocator);
    }

    fn parseZeroPageDependencyModulePolicy(self: *Parser) ParseError!ast.CurrentModulePolicy {
        try self.expect(.period);
        try self.expect(.l_brace);
        var mode: ?ast.ModuleLoadMode = null;
        var filename: ?[]const u8 = null;
        var graph: ?bool = null;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "mode")) {
                if (mode != null) return error.UnsupportedZeroPageOptions;
                mode = try self.parseZeroPageModuleLoadMode();
            } else if (std.mem.eql(u8, field, "filename")) {
                if (filename != null) return error.UnsupportedZeroPageOptions;
                filename = try self.parseString();
            } else if (std.mem.eql(u8, field, "graph")) {
                if (graph != null) return error.UnsupportedZeroPageOptions;
                graph = try self.parseBoolLiteral();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return .{ .mode = mode orelse return error.UnsupportedZeroPageOptions, .filename = filename, .graph = graph orelse false };
    }

    fn parseZeroPageCurrentModulePolicy(self: *Parser) ParseError!ast.CurrentModulePolicy {
        try self.expect(.period);
        try self.expect(.l_brace);
        var mode: ?ast.ModuleLoadMode = null;
        var filename: ?[]const u8 = null;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "mode")) {
                if (mode != null) return error.UnsupportedZeroPageOptions;
                mode = try self.parseZeroPageModuleLoadMode();
            } else if (std.mem.eql(u8, field, "filename")) {
                if (filename != null) return error.UnsupportedZeroPageOptions;
                filename = try self.parseString();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        const resolved_mode = mode orelse return error.UnsupportedZeroPageOptions;
        if ((resolved_mode == .preload or resolved_mode == .on_demand) and filename == null) return error.UnsupportedZeroPageOptions;
        return .{ .mode = resolved_mode, .filename = filename };
    }

    fn parseZeroPageModuleLoadMode(self: *Parser) ParseError!ast.ModuleLoadMode {
        try self.expect(.period);
        const name = try self.expectIdent();
        if (std.mem.eql(u8, name, "manual")) return .manual;
        if (std.mem.eql(u8, name, "preload")) return .preload;
        if (std.mem.eql(u8, name, "on_demand")) return .on_demand;
        return error.UnsupportedZeroPageOptions;
    }

    fn parseZeroPageModuleLoadWindow(self: *Parser, allow_bank: bool) ParseError!ast.ModuleLoadWindowOptions {
        if (self.peek(.period) and !self.peekAhead(1, .l_brace)) {
            try self.expect(.period);
            return .{ .addr = 0, .size = 0, .region_name = try self.expectIdent() };
        }
        try self.expect(.period);
        try self.expect(.l_brace);
        var addr: ?u16 = null;
        var size: ?u16 = null;
        var bank: ast.ModuleWindowBank = .visible;
        var seen_bank = false;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "addr")) {
                if (addr != null) return error.UnsupportedZeroPageOptions;
                addr = try self.parseU16();
            } else if (std.mem.eql(u8, field, "size")) {
                if (size != null) return error.UnsupportedZeroPageOptions;
                size = try self.parseU16();
            } else if (std.mem.eql(u8, field, "bank")) {
                if (!allow_bank or seen_bank) return error.UnsupportedZeroPageOptions;
                bank = try self.parseZeroPageModuleWindowBank();
                seen_bank = true;
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return .{ .addr = addr orelse return error.UnsupportedZeroPageOptions, .size = size orelse return error.UnsupportedZeroPageOptions, .bank = bank };
    }

    fn parseZeroPageModuleReuCache(self: *Parser) ParseError!ast.ModuleReuCacheOptions {
        if (self.peek(.period) and !self.peekAhead(1, .l_brace)) {
            try self.expect(.period);
            return .{ .addr = 0, .size = 0, .region_name = try self.expectIdent() };
        }
        const region = try self.parseZeroPageModuleRegionU32();
        return .{ .addr = region.addr, .size = region.size };
    }

    fn parseZeroPageModuleWindowBank(self: *Parser) ParseError!ast.ModuleWindowBank {
        try self.expect(.period);
        const name = try self.expectIdent();
        if (std.mem.eql(u8, name, "visible")) return .visible;
        if (std.mem.eql(u8, name, "ram_under_basic")) return .ram_under_basic;
        if (std.mem.eql(u8, name, "ram_under_kernal")) return .ram_under_kernal;
        return error.UnsupportedZeroPageOptions;
    }

    fn parseZeroPageModuleRegionU16(self: *Parser) ParseError!struct { addr: u16, size: u16 } {
        try self.expect(.period);
        try self.expect(.l_brace);
        var addr: ?u16 = null;
        var size: ?u16 = null;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "addr")) {
                if (addr != null) return error.UnsupportedZeroPageOptions;
                addr = try self.parseU16();
            } else if (std.mem.eql(u8, field, "size")) {
                if (size != null) return error.UnsupportedZeroPageOptions;
                size = try self.parseU16();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return .{ .addr = addr orelse return error.UnsupportedZeroPageOptions, .size = size orelse return error.UnsupportedZeroPageOptions };
    }

    fn parseZeroPageModuleRegionU32(self: *Parser) ParseError!struct { addr: u32, size: u32 } {
        try self.expect(.period);
        try self.expect(.l_brace);
        var addr: ?u32 = null;
        var size: ?u32 = null;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "addr")) {
                if (addr != null) return error.UnsupportedZeroPageOptions;
                addr = try self.parseU32();
            } else if (std.mem.eql(u8, field, "size")) {
                if (size != null) return error.UnsupportedZeroPageOptions;
                size = try self.parseU32();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return .{ .addr = addr orelse return error.UnsupportedZeroPageOptions, .size = size orelse return error.UnsupportedZeroPageOptions };
    }

    fn parseZeroPageModule(self: *Parser) ParseError!ast.ZeroPageModule {
        try self.expect(.period);
        try self.expect(.l_brace);
        var id: ?[]const u8 = null;
        var abi: ?u16 = null;
        var exports: []ast.ModuleExport = &.{};
        var deps: []const []const u8 = &.{};
        var seen_flags = false;
        var seen_exports = false;
        var seen_deps = false;
        errdefer {
            if (exports.len != 0) self.allocator.free(exports);
            if (deps.len != 0) self.allocator.free(deps);
        }

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "id")) {
                if (id != null) return error.UnsupportedZeroPageModule;
                const value = try self.parseString();
                if (!isValidModuleId(value)) return error.InvalidZeroPageModuleId;
                id = value;
            } else if (std.mem.eql(u8, field, "abi")) {
                if (abi != null) return error.UnsupportedZeroPageModule;
                const value = try self.parseU16();
                if (value != 1) return error.InvalidZeroPageModuleAbi;
                abi = value;
            } else if (std.mem.eql(u8, field, "flags")) {
                if (seen_flags) return error.UnsupportedZeroPageModule;
                seen_flags = true;
                try self.parseEmptyMetadataObject();
            } else if (std.mem.eql(u8, field, "exports")) {
                if (seen_exports) return error.UnsupportedZeroPageModule;
                seen_exports = true;
                exports = try self.parseZeroPageModuleExports();
                if (exports.len == 0) return error.UnsupportedZeroPageModule;
            } else if (std.mem.eql(u8, field, "deps")) {
                if (seen_deps) return error.UnsupportedZeroPageModule;
                seen_deps = true;
                deps = try self.parseZeroPageModuleDeps();
            } else {
                return error.UnsupportedZeroPageModule;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);

        return .{
            .id = id orelse return error.UnsupportedZeroPageModule,
            .abi = abi orelse return error.UnsupportedZeroPageModule,
            .exports = if (seen_exports) exports else return error.UnsupportedZeroPageModule,
            .deps = deps,
        };
    }

    fn parseModuleId(self: *Parser) ParseError![]const u8 {
        const id = if (self.peek(.string_literal)) try self.parseString() else try self.expectIdent();
        if (!isValidModuleId(id)) return error.InvalidZeroPageModuleId;
        return id;
    }

    fn parseModuleDeclaration(self: *Parser) ParseError!ast.ZeroPageModule {
        try self.expectWord("module");
        const id = try self.parseModuleId();
        try self.expectWord("abi");
        const abi = try self.parseU16();
        if (abi != 1) return error.InvalidZeroPageModuleAbi;
        try self.expect(.l_brace);
        var exports: std.ArrayList(ast.ModuleExport) = .empty;
        defer exports.deinit(self.allocator);
        var deps: std.ArrayList([]const u8) = .empty;
        defer deps.deinit(self.allocator);
        while (!self.eat(.r_brace)) {
            if (self.eat(.keyword_export)) {
                const name = try self.expectIdent();
                if (!isValidModuleId(name)) return error.InvalidZeroPageModuleId;
                for (exports.items) |entry| {
                    if (std.mem.eql(u8, name, entry.name)) return error.DuplicateZeroPageModuleExport;
                }
                const implementation = if (self.eat(.equal)) try self.expectIdent() else name;
                try exports.append(self.allocator, .{ .name = name, .function_name = implementation });
            } else if (self.eatWord("dependency")) {
                const dep = try self.parseModuleId();
                for (deps.items) |entry| {
                    if (std.mem.eql(u8, dep, entry)) return error.DuplicateZeroPageModuleDependency;
                }
                try deps.append(self.allocator, dep);
            } else return error.InvalidMachineDeclaration;
            try self.expectMachineSemicolon();
        }
        if (exports.items.len == 0) return error.UnsupportedZeroPageModule;
        const owned_exports = try exports.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_exports);
        return .{ .id = id, .abi = abi, .exports = owned_exports, .deps = try deps.toOwnedSlice(self.allocator) };
    }

    fn parseExternModule(self: *Parser) ParseError!ast.ModuleBinding {
        try self.expectWord("extern");
        try self.expectWord("module");
        const name = try self.expectIdent();
        try self.expect(.equal);
        const module_id = try self.parseModuleId();
        try self.expect(.l_brace);
        var methods: std.ArrayList(ast.ModuleBindingMethod) = .empty;
        defer methods.deinit(self.allocator);
        errdefer for (methods.items) |method| method.deinit(self.allocator);
        while (!self.eat(.r_brace)) {
            try self.expect(.keyword_fn);
            const method_name = try self.expectIdent();
            for (methods.items) |method| {
                if (std.mem.eql(u8, method.name, method_name)) return error.DuplicateZeroPageModuleExport;
            }
            try self.expect(.l_paren);
            const params = try self.parseParams();
            defer self.allocator.free(params);
            try self.expect(.r_paren);
            const return_type = try self.parseType();
            try self.expect(.semicolon);
            const types = try self.allocator.alloc(ast.Type, params.len);
            errdefer self.allocator.free(types);
            for (types, params) |*ty, param| ty.* = param.ty;
            try methods.append(self.allocator, .{ .name = method_name, .params = types, .return_type = return_type });
        }
        return .{ .name = name, .module_id = module_id, .methods = try methods.toOwnedSlice(self.allocator) };
    }

    fn parseEmptyMetadataObject(self: *Parser) ParseError!void {
        try self.expect(.period);
        try self.expect(.l_brace);
        if (!self.peek(.r_brace)) return error.UnsupportedZeroPageModule;
        try self.expect(.r_brace);
    }

    fn parseZeroPageModuleExports(self: *Parser) ParseError![]ast.ModuleExport {
        try self.expect(.period);
        try self.expect(.l_brace);
        var exports: std.ArrayList(ast.ModuleExport) = .empty;
        errdefer exports.deinit(self.allocator);

        while (!self.peek(.r_brace)) {
            const export_name = try self.parseMetadataFieldName();
            if (!isValidModuleId(export_name)) return error.InvalidZeroPageModuleId;
            for (exports.items) |existing| {
                if (std.mem.eql(u8, existing.name, export_name)) return error.DuplicateZeroPageModuleExport;
            }
            const function_name = try self.expectIdent();
            try exports.append(self.allocator, .{ .name = export_name, .function_name = function_name });
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return try exports.toOwnedSlice(self.allocator);
    }

    fn parseZeroPageModuleDeps(self: *Parser) ParseError![]const []const u8 {
        try self.expect(.period);
        try self.expect(.l_brace);
        var deps: std.ArrayList([]const u8) = .empty;
        errdefer deps.deinit(self.allocator);

        while (!self.peek(.r_brace)) {
            const dep = try self.parseString();
            if (!isValidModuleId(dep)) return error.InvalidZeroPageModuleId;
            for (deps.items) |existing| {
                if (std.mem.eql(u8, existing, dep)) return error.DuplicateZeroPageModuleDependency;
            }
            try deps.append(self.allocator, dep);
            if (!self.eat(.comma)) break;
        }
        try self.expect(.r_brace);
        return try deps.toOwnedSlice(self.allocator);
    }

    fn isZPMDoduleImportStartAt(self: *Parser, offset: usize) bool {
        return self.peekAheadText(offset, "ZeroPage") and
            self.peekAhead(offset + 1, .period) and
            self.peekAheadText(offset + 2, "module") and
            self.peekAhead(offset + 3, .period) and
            self.peekAheadText(offset + 4, "import") and
            self.peekAhead(offset + 5, .l_paren);
    }

    fn parseZPMDoduleBinding(self: *Parser, name: []const u8) ParseError!ast.ModuleBinding {
        _ = try self.expectIdent();
        try self.expect(.period);
        _ = try self.expectIdent();
        try self.expect(.period);
        const member = try self.expectIdent();
        if (!std.mem.eql(u8, member, "import")) return error.UnsupportedZeroPageModule;
        try self.expect(.l_paren);
        try self.expect(.period);
        const module_id = try self.expectIdent();
        if (!isValidModuleId(module_id)) return error.InvalidZeroPageModuleId;
        try self.expect(.comma);
        const methods = try self.parseZPMDoduleBindingMethods();
        try self.expect(.r_paren);
        return .{ .name = name, .module_id = module_id, .methods = methods };
    }

    fn parseZPMDoduleBindingMethods(self: *Parser) ParseError![]ast.ModuleBindingMethod {
        try self.expect(.period);
        try self.expect(.l_brace);
        var methods: std.ArrayList(ast.ModuleBindingMethod) = .empty;
        errdefer {
            for (methods.items) |method| method.deinit(self.allocator);
            methods.deinit(self.allocator);
        }
        while (!self.peek(.r_brace)) {
            const method_name = try self.parseMetadataFieldName();
            for (methods.items) |existing| {
                if (std.mem.eql(u8, existing.name, method_name)) return error.DuplicateZeroPageModuleExport;
            }
            try self.expect(.keyword_fn);
            try self.expect(.l_paren);
            var params: std.ArrayList(ast.Type) = .empty;
            errdefer params.deinit(self.allocator);
            while (!self.peek(.r_paren)) {
                try params.append(self.allocator, try self.parseType());
                if (!self.eat(.comma)) break;
            }
            try self.expect(.r_paren);
            const return_type = try self.parseType();
            const owned_params = try params.toOwnedSlice(self.allocator);
            errdefer if (owned_params.len != 0) self.allocator.free(owned_params);
            try methods.append(self.allocator, .{ .name = method_name, .params = owned_params, .return_type = return_type });
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        if (methods.items.len == 0) return error.UnsupportedZeroPageModule;
        return try methods.toOwnedSlice(self.allocator);
    }

    fn parseZeroPageHeapOptions(self: *Parser) ParseError![]ast.HeapOptions {
        try self.expect(.period);
        try self.expect(.l_brace);
        var heaps: std.ArrayList(ast.HeapOptions) = .empty;
        errdefer heaps.deinit(self.allocator);

        while (!self.peek(.r_brace)) {
            const heap_name = try self.parseMetadataFieldName();
            for (heaps.items) |existing| {
                if (std.mem.eql(u8, existing.name, heap_name)) return error.DuplicateZeroPageHeapOption;
            }
            try heaps.append(self.allocator, try self.parseZeroPageHeapOption(heap_name));
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return try heaps.toOwnedSlice(self.allocator);
    }

    fn parseZeroPageReuOptions(self: *Parser) ParseError!ast.ReuOptions {
        try self.expect(.period);
        try self.expect(.l_brace);
        var options: ast.ReuOptions = .{};
        errdefer options.deinit(self.allocator);
        var seen_heaps = false;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "heaps")) {
                if (seen_heaps) return error.UnsupportedZeroPageOptions;
                seen_heaps = true;
                options.heaps = try self.parseZeroPageReuHeapOptions();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return options;
    }

    fn parseZeroPageReuHeapOptions(self: *Parser) ParseError![]ast.ReuHeapOptions {
        try self.expect(.period);
        try self.expect(.l_brace);
        var heaps: std.ArrayList(ast.ReuHeapOptions) = .empty;
        errdefer heaps.deinit(self.allocator);

        while (!self.peek(.r_brace)) {
            const heap_name = try self.parseMetadataFieldName();
            for (heaps.items) |existing| {
                if (std.mem.eql(u8, existing.name, heap_name)) return error.DuplicateZeroPageHeapOption;
            }
            try heaps.append(self.allocator, try self.parseZeroPageReuHeapOption(heap_name));
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return try heaps.toOwnedSlice(self.allocator);
    }

    fn parseZeroPageReuHeapOption(self: *Parser, name: []const u8) ParseError!ast.ReuHeapOptions {
        try self.expect(.period);
        try self.expect(.l_brace);
        var addr: ?u32 = null;
        var size: ?u32 = null;
        var kind: ?ast.HeapKind = null;
        var region_name: ?[]const u8 = null;
        var seen_region = false;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "region")) {
                if (seen_region) return error.UnsupportedZeroPageOptions;
                seen_region = true;
                if (self.peek(.period) and self.peekAhead(1, .l_brace)) {
                    const region = try self.parseZeroPageReuHeapRegion();
                    addr = region.addr;
                    size = region.size;
                } else {
                    try self.expect(.period);
                    region_name = try self.expectIdent();
                }
            } else if (std.mem.eql(u8, field, "kind")) {
                if (kind != null) return error.UnsupportedZeroPageOptions;
                kind = try self.parseZeroPageHeapKind();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        const heap_addr = addr orelse if (region_name != null) 0 else return error.UnsupportedZeroPageOptions;
        const heap_size = size orelse if (region_name != null) 0 else return error.UnsupportedZeroPageOptions;
        if (region_name == null) {
            if (heap_size == 0) return error.InvalidZeroPageReuHeapRegion;
            if (heap_addr > 0x00ff_ffff) return error.InvalidZeroPageReuHeapRegion;
            if (@as(u64, heap_addr) + @as(u64, heap_size) > 0x0100_0000) return error.InvalidZeroPageReuHeapRegion;
        }
        const heap_kind = kind orelse return error.UnsupportedZeroPageOptions;
        if (heap_kind != .arena) return error.UnsupportedZeroPageOptions;
        return .{ .name = name, .addr = heap_addr, .size = heap_size, .region_name = region_name, .kind = heap_kind };
    }

    fn parseZeroPageReuHeapRegion(self: *Parser) ParseError!struct { addr: u32, size: u32 } {
        try self.expect(.period);
        try self.expect(.l_brace);
        var addr: ?u32 = null;
        var size: ?u32 = null;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "addr")) {
                if (addr != null) return error.UnsupportedZeroPageOptions;
                addr = try self.parseU32();
            } else if (std.mem.eql(u8, field, "size")) {
                if (size != null) return error.UnsupportedZeroPageOptions;
                size = try self.parseU32();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return .{ .addr = addr orelse return error.UnsupportedZeroPageOptions, .size = size orelse return error.UnsupportedZeroPageOptions };
    }

    fn parseZeroPageHeapOption(self: *Parser, name: []const u8) ParseError!ast.HeapOptions {
        try self.expect(.period);
        try self.expect(.l_brace);
        var addr: ?u16 = null;
        var size: ?u16 = null;
        var kind: ?ast.HeapKind = null;
        var block: ?u16 = null;
        var region_name: ?[]const u8 = null;
        var seen_region = false;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "region")) {
                if (seen_region) return error.UnsupportedZeroPageOptions;
                seen_region = true;
                if (self.peek(.period) and self.peekAhead(1, .l_brace)) {
                    const region = try self.parseZeroPageHeapRegion();
                    addr = region.addr;
                    size = region.size;
                } else {
                    try self.expect(.period);
                    region_name = try self.expectIdent();
                }
            } else if (std.mem.eql(u8, field, "kind")) {
                if (kind != null) return error.UnsupportedZeroPageOptions;
                kind = try self.parseZeroPageHeapKind();
            } else if (std.mem.eql(u8, field, "block")) {
                if (block != null) return error.UnsupportedZeroPageOptions;
                block = try self.parseU16();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        const heap_addr = addr orelse if (region_name != null) 0 else return error.UnsupportedZeroPageOptions;
        const heap_size = size orelse if (region_name != null) 0 else return error.UnsupportedZeroPageOptions;
        if (region_name == null) {
            if (heap_size == 0) return error.InvalidZeroPageHeapRegion;
            if (@as(u32, heap_addr) + @as(u32, heap_size) > 0xffff) return error.InvalidZeroPageHeapRegion;
        }
        const heap_kind = kind orelse return error.UnsupportedZeroPageOptions;
        switch (heap_kind) {
            .arena => {
                if (block != null) return error.InvalidZeroPageHeapBlock;
            },
            .fixed => {
                const heap_block = block orelse return error.InvalidZeroPageHeapBlock;
                if (heap_block < 2) return error.InvalidZeroPageHeapBlock;
                if (region_name == null) {
                    if (heap_block > heap_size) return error.InvalidZeroPageHeapBlock;
                    if (@mod(heap_size, heap_block) != 0) return error.InvalidZeroPageHeapBlock;
                }
            },
        }
        return .{ .name = name, .addr = heap_addr, .size = heap_size, .region_name = region_name, .kind = heap_kind, .block = block };
    }

    fn parseZeroPageHeapRegion(self: *Parser) ParseError!struct { addr: u16, size: u16 } {
        try self.expect(.period);
        try self.expect(.l_brace);
        var addr: ?u16 = null;
        var size: ?u16 = null;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "addr")) {
                if (addr != null) return error.UnsupportedZeroPageOptions;
                addr = try self.parseU16();
            } else if (std.mem.eql(u8, field, "size")) {
                if (size != null) return error.UnsupportedZeroPageOptions;
                size = try self.parseU16();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return .{ .addr = addr orelse return error.UnsupportedZeroPageOptions, .size = size orelse return error.UnsupportedZeroPageOptions };
    }

    fn parseZeroPageHeapKind(self: *Parser) ParseError!ast.HeapKind {
        try self.expect(.period);
        const name = try self.expectIdent();
        if (std.mem.eql(u8, name, "arena")) return .arena;
        if (std.mem.eql(u8, name, "fixed")) return .fixed;
        return error.UnsupportedZeroPageOptions;
    }

    fn parseZeroPageStackOptions(self: *Parser) ParseError!ast.StackOptions {
        try self.expect(.period);
        try self.expect(.l_brace);
        var base: ?u16 = null;
        var size: ?u16 = null;
        var region_name: ?[]const u8 = null;
        var zp: ast.StackZeroPageOptions = .{};
        var seen_zp = false;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "base")) {
                if (base != null or region_name != null) return error.UnsupportedZeroPageOptions;
                base = try self.parseU16();
            } else if (std.mem.eql(u8, field, "size")) {
                if (size != null or region_name != null) return error.UnsupportedZeroPageOptions;
                size = try self.parseU16();
            } else if (std.mem.eql(u8, field, "region")) {
                if (region_name != null or base != null or size != null) return error.UnsupportedZeroPageOptions;
                try self.expect(.period);
                region_name = try self.expectIdent();
            } else if (std.mem.eql(u8, field, "zp")) {
                if (seen_zp) return error.UnsupportedZeroPageOptions;
                seen_zp = true;
                zp = try self.parseZeroPageStackZeroPageOptions();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        const stack_base = base orelse if (region_name != null) 0 else return error.UnsupportedZeroPageOptions;
        const stack_size = size orelse if (region_name != null) 0 else return error.UnsupportedZeroPageOptions;
        if (region_name == null) {
            if (stack_size == 0) return error.InvalidZeroPageStackRegion;
            if (@as(u32, stack_base) + @as(u32, stack_size) > 0x10000) return error.InvalidZeroPageStackRegion;
        }
        return .{ .base = stack_base, .size = stack_size, .region_name = region_name, .zp = zp };
    }

    fn parseZeroPageStackZeroPageOptions(self: *Parser) ParseError!ast.StackZeroPageOptions {
        try self.expect(.period);
        try self.expect(.l_brace);
        var sp: ?u8 = null;
        var fp: ?u8 = null;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "sp")) {
                if (sp != null) return error.UnsupportedZeroPageOptions;
                sp = try self.parseU8();
            } else if (std.mem.eql(u8, field, "fp")) {
                if (fp != null) return error.UnsupportedZeroPageOptions;
                fp = try self.parseU8();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return .{
            .sp = sp orelse return error.UnsupportedZeroPageOptions,
            .fp = fp orelse return error.UnsupportedZeroPageOptions,
        };
    }

    fn parseU8(self: *Parser) ParseError!u8 {
        return std.math.cast(u8, try self.parseU16()) orelse return error.Overflow;
    }

    fn parseZeroPageAbiOptions(self: *Parser) ParseError!ast.AbiOptions {
        try self.expect(.period);
        try self.expect(.l_brace);
        var abi: ast.AbiOptions = .{};
        errdefer abi.deinit(self.allocator);
        var seen_default = false;
        var seen_functions = false;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (std.mem.eql(u8, field, "default_frame")) {
                if (seen_default) return error.UnsupportedZeroPageOptions;
                seen_default = true;
                abi.default_frame = try self.parseZeroPageFramePolicy();
            } else if (std.mem.eql(u8, field, "functions")) {
                if (seen_functions) return error.UnsupportedZeroPageOptions;
                seen_functions = true;
                abi.functions = try self.parseZeroPageFunctionFramePolicies();
            } else {
                return error.UnsupportedZeroPageOptions;
            }
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return abi;
    }

    fn parseZeroPageFunctionFramePolicies(self: *Parser) ParseError![]ast.FunctionFramePolicy {
        try self.expect(.period);
        try self.expect(.l_brace);
        var policies: std.ArrayList(ast.FunctionFramePolicy) = .empty;
        errdefer policies.deinit(self.allocator);

        while (!self.peek(.r_brace)) {
            const function_name = try self.parseMetadataFieldName();
            for (policies.items) |existing| {
                if (std.mem.eql(u8, existing.name, function_name)) return error.DuplicateZeroPageFunctionOption;
            }
            try policies.append(self.allocator, .{ .name = function_name, .frame = try self.parseZeroPageFunctionFramePolicy() });
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return try policies.toOwnedSlice(self.allocator);
    }

    fn parseZeroPageFunctionFramePolicy(self: *Parser) ParseError!ast.FramePolicy {
        try self.expect(.period);
        try self.expect(.l_brace);
        var frame: ?ast.FramePolicy = null;

        while (!self.peek(.r_brace)) {
            const field = try self.parseMetadataFieldName();
            if (!std.mem.eql(u8, field, "frame")) return error.UnsupportedZeroPageOptions;
            if (frame != null) return error.UnsupportedZeroPageOptions;
            frame = try self.parseZeroPageFramePolicy();
            try self.consumeMetadataCommaOrEnd();
        }
        try self.expect(.r_brace);
        return frame orelse error.UnsupportedZeroPageOptions;
    }

    fn parseZeroPageFramePolicy(self: *Parser) ParseError!ast.FramePolicy {
        try self.expect(.period);
        const name = try self.expectIdent();
        if (std.mem.eql(u8, name, "static")) return .static;
        if (std.mem.eql(u8, name, "stack")) return .stack;
        if (std.mem.eql(u8, name, "auto")) return .auto;
        return error.UnsupportedZeroPageOptions;
    }

    fn parseMetadataFieldName(self: *Parser) ParseError![]const u8 {
        return self.parseDeclarationFieldName(false);
    }

    fn parseDeclarationFieldName(self: *Parser, machine: bool) ParseError![]const u8 {
        if (!machine) try self.expect(.period);
        const name = try self.expectIdent();
        try self.expect(.equal);
        return name;
    }

    fn endDeclarationField(self: *Parser, machine: bool) ParseError!void {
        if (machine) return self.expectMachineSemicolon();
        return self.consumeMetadataCommaOrEnd();
    }

    fn consumeMetadataCommaOrEnd(self: *Parser) ParseError!void {
        if (self.eat(.comma)) return;
        if (self.peek(.r_brace)) return;
        return error.UnexpectedToken;
    }

    fn moduleOwner(self: *Parser) []const u8 {
        return if (self.function_prefix.len == 0) "main" else self.function_prefix;
    }

    fn parseEnumDecl(self: *Parser, name: []const u8) ParseError!ast.EnumDecl {
        const enum_word = try self.expectIdent();
        if (!std.mem.eql(u8, enum_word, "enum")) return error.UnsupportedEnum;
        try self.expect(.l_paren);
        if (!self.eat(.keyword_u8)) return error.UnsupportedEnum;
        try self.expect(.r_paren);
        try self.expect(.l_brace);
        var tags: std.ArrayList(ast.EnumTag) = .empty;
        errdefer tags.deinit(self.allocator);
        var next_value: u16 = 0;
        while (!self.peek(.r_brace)) {
            const tag_name = try self.expectIdent();
            var value = next_value;
            if (self.eat(.equal)) value = try self.parseU16();
            if (value > 255) return error.UnsupportedEnum;
            for (tags.items) |existing| {
                if (std.mem.eql(u8, existing.name, tag_name)) return error.UnsupportedEnum;
                if (existing.value == @as(u8, @intCast(value))) return error.UnsupportedEnum;
            }
            try tags.append(self.allocator, .{ .name = tag_name, .value = @intCast(value) });
            next_value = value + 1;
            _ = self.eat(.comma);
        }
        try self.expect(.r_brace);
        try self.expect(.semicolon);
        return .{ .name = name, .tags = try tags.toOwnedSlice(self.allocator) };
    }

    fn parseStructDecl(self: *Parser, name: []const u8) ParseError!ast.StructDecl {
        const struct_word = try self.expectIdent();
        if (!std.mem.eql(u8, struct_word, "struct")) return error.UnsupportedStruct;
        try self.expect(.l_brace);
        var fields: std.ArrayList(ast.StructFieldDecl) = .empty;
        errdefer fields.deinit(self.allocator);
        while (!self.peek(.r_brace)) {
            const field_name = try self.expectIdent();
            try self.expect(.colon);
            const ty = try self.parseType();
            try fields.append(self.allocator, .{ .name = field_name, .ty = ty });
            _ = self.eat(.comma);
        }
        try self.expect(.r_brace);
        try self.expect(.semicolon);
        return .{ .name = name, .fields = try fields.toOwnedSlice(self.allocator) };
    }

    fn parseUnionDecl(self: *Parser, name: []const u8) ParseError!ast.UnionDecl {
        const union_word = try self.expectIdent();
        if (!std.mem.eql(u8, union_word, "union")) return error.UnsupportedStruct;
        try self.expect(.l_paren);
        const enum_word = try self.expectIdent();
        if (!std.mem.eql(u8, enum_word, "enum")) return error.UnsupportedStruct;
        try self.expect(.r_paren);
        try self.expect(.l_brace);
        var fields: std.ArrayList(ast.UnionFieldDecl) = .empty;
        errdefer fields.deinit(self.allocator);
        while (!self.peek(.r_brace)) {
            const field_name = try self.expectIdent();
            const ty: ?ast.Type = if (self.eat(.colon)) try self.parseType() else null;
            try fields.append(self.allocator, .{ .name = field_name, .ty = ty });
            _ = self.eat(.comma);
        }
        try self.expect(.r_brace);
        try self.expect(.semicolon);
        return .{ .name = name, .fields = try fields.toOwnedSlice(self.allocator) };
    }

    fn isKnownUnion(self: *Parser, name: []const u8) bool {
        for (self.known_unions.items) |known| {
            if (std.mem.eql(u8, known, name)) return true;
        }
        return false;
    }

    fn parseFunction(self: *Parser, convention: *?ast.FramePolicy) ParseError!ast.Function {
        const exported = self.eat(.keyword_export);
        try self.expect(.keyword_fn);
        const raw_name = try self.expectIdent();
        if (self.namedHeapIsFar(raw_name) != null) return error.InvalidMachineDeclaration;
        const name = if (self.function_prefix.len == 0)
            raw_name
        else
            try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ self.function_prefix, raw_name });
        errdefer if (self.function_prefix.len != 0) self.allocator.free(name);

        try self.expect(.l_paren);
        const params = try self.parseParams();
        errdefer if (params.len != 0) self.allocator.free(params);
        try self.expect(.r_paren);
        const section = try self.parsePlacementSection();
        if (self.eatWord("callconv")) {
            try self.expect(.l_paren);
            const frame = self.parseZeroPageFramePolicy() catch return error.UnsupportedFrameCallconv;
            if (frame == .auto or !self.eat(.r_paren)) return error.UnsupportedFrameCallconv;
            convention.* = frame;
        }
        const return_type = try self.parseType();
        if (isArrayType(return_type)) return error.UnsupportedArrayByValue;
        try self.recordPlacementSection(name, section, true);
        const body = try self.parseBlock();
        return .{
            .name = name,
            .name_owned = self.function_prefix.len != 0,
            .exported = exported,
            .params = params,
            .return_type = return_type,
            .body = body,
        };
    }

    fn parseParams(self: *Parser) ParseError![]ast.Param {
        var params: std.ArrayList(ast.Param) = .empty;
        errdefer params.deinit(self.allocator);

        while (!self.peek(.r_paren)) {
            const name = try self.expectIdent();
            try self.expect(.colon);
            const ty = try self.parseType();
            if (isArrayType(ty)) return error.UnsupportedArrayByValue;
            try params.append(self.allocator, .{ .name = name, .ty = ty });
            if (!self.eat(.comma)) break;
        }

        return try params.toOwnedSlice(self.allocator);
    }

    fn parseType(self: *Parser) ParseError!ast.Type {
        if (self.eat(.question_mark)) {
            const child_ty = try self.parseType();
            return .{ .optional = .{ .child = try self.typeToOptionalChild(child_ty) } };
        }
        if (self.eat(.star)) {
            var is_volatile = false;
            if (self.peek(.identifier) and std.mem.eql(u8, self.text(self.tokens[self.index]), "volatile")) {
                self.index += 1;
                is_volatile = true;
            }
            if (self.peek(.identifier) and std.mem.eql(u8, self.text(self.tokens[self.index]), "const")) return error.UnsupportedPointerType;
            return .{ .pointer = .{
                .child = try self.parsePointerChildType(),
                .is_volatile = is_volatile,
            } };
        }
        if (self.eat(.l_bracket)) {
            if (self.eat(.star)) {
                try self.expect(.r_bracket);
                var is_volatile = false;
                if (self.peek(.identifier) and std.mem.eql(u8, self.text(self.tokens[self.index]), "volatile")) {
                    self.index += 1;
                    is_volatile = true;
                }
                if (self.peek(.identifier) and std.mem.eql(u8, self.text(self.tokens[self.index]), "const")) return error.UnsupportedPointerType;
                return .{ .pointer = .{
                    .child = try self.parsePointerChildType(),
                    .is_volatile = is_volatile,
                    .is_many = true,
                } };
            }
            const len = try self.parseComptimeU16();
            if (self.eat(.colon)) return error.UnsupportedArrayType;
            try self.expect(.r_bracket);
            const elem = try self.parseArrayElemType();
            const array_ty = ast.ArrayType{ .len = len, .elem = elem };
            try validateArrayStorageSize(self, array_ty);
            return .{ .array = array_ty };
        }
        if (self.eat(.keyword_void)) return .void;
        if (self.eat(.keyword_bool)) return .bool;
        if (self.eat(.keyword_u8)) return .u8;
        if (self.eat(.keyword_i8)) return .i8;
        if (self.eat(.keyword_u16)) return .u16;
        if (self.eat(.keyword_i16)) return .i16;
        if (self.eat(.keyword_usize)) return .usize;
        return .{ .custom = try self.expectIdent() };
    }

    fn typeToOptionalChild(self: *Parser, ty: ast.Type) ParseError!ast.OptionalChildType {
        _ = self;
        return switch (ty) {
            .bool => .{ .scalar = .bool },
            .u8 => .{ .scalar = .u8 },
            .i8 => .{ .scalar = .i8 },
            .u16 => .{ .scalar = .u16 },
            .i16 => .{ .scalar = .i16 },
            .usize => .{ .scalar = .usize },
            .custom => |name| .{ .custom = name },
            .pointer => |ptr| .{ .pointer = ptr },
            else => error.UnsupportedOptional,
        };
    }

    fn parsePointerChildType(self: *Parser) ParseError!ast.PointerChildType {
        if (self.eat(.keyword_bool)) return .{ .scalar = .bool };
        if (self.eat(.keyword_u8)) return .{ .scalar = .u8 };
        if (self.eat(.keyword_i8)) return .{ .scalar = .i8 };
        if (self.eat(.keyword_u16)) return .{ .scalar = .u16 };
        if (self.eat(.keyword_i16)) return .{ .scalar = .i16 };
        if (self.eat(.keyword_usize)) return .{ .scalar = .usize };
        if (self.peek(.identifier)) return .{ .custom = try self.expectIdent() };
        return error.UnsupportedPointerType;
    }

    fn parseArrayElemType(self: *Parser) ParseError!ast.ArrayElemType {
        if (self.eat(.keyword_bool)) return .{ .scalar = .bool };
        if (self.eat(.keyword_u8)) return .{ .scalar = .u8 };
        if (self.eat(.keyword_i8)) return .{ .scalar = .i8 };
        if (self.eat(.keyword_u16)) return .{ .scalar = .u16 };
        if (self.eat(.keyword_i16)) return .{ .scalar = .i16 };
        if (self.eat(.keyword_usize)) return .{ .scalar = .usize };
        if (self.peek(.identifier)) return .{ .custom = try self.expectIdent() };
        return error.UnsupportedArrayType;
    }

    fn parseBlock(self: *Parser) ParseError![]ast.Stmt {
        try self.expect(.l_brace);
        var statements: std.ArrayList(ast.Stmt) = .empty;
        errdefer {
            for (statements.items) |stmt| ast.freeStmt(self.allocator, stmt);
            statements.deinit(self.allocator);
        }

        while (!self.peek(.r_brace)) {
            if (self.peek(.eof)) return error.UnexpectedEof;
            const statement = try self.parseStmt();
            errdefer ast.freeStmt(self.allocator, statement);
            try statements.append(self.allocator, statement);
        }
        try self.expect(.r_brace);
        return try statements.toOwnedSlice(self.allocator);
    }

    fn parseStmt(self: *Parser) ParseError!ast.Stmt {
        if (self.peek(.keyword_var)) return try self.parseVar();
        if (self.peek(.keyword_const)) return try self.parseLocalConst();
        if (self.peek(.keyword_while)) return try self.parseWhile();
        if (self.peek(.keyword_for)) return try self.parseFor();
        if (self.peek(.keyword_switch)) return try self.parseSwitchStmt();
        if (self.peek(.keyword_if)) return try self.parseIf();
        if (self.peek(.keyword_return)) return try self.parseReturn();
        if (self.eat(.keyword_break)) {
            if (self.eat(.colon)) {
                const label = try self.expectIdent();
                const value = try self.parseExpr();
                try self.expect(.semicolon);
                return .{ .break_expr = .{ .label = label, .value = value } };
            }
            try self.expect(.semicolon);
            return .break_stmt;
        }
        if (self.eat(.keyword_continue)) {
            try self.expect(.semicolon);
            return .continue_stmt;
        }

        const first_token = try self.expectToken(.identifier);
        const first = self.text(first_token);
        if (self.peek(.period) and self.peekAhead(2, .l_paren) and
            (self.peekAheadText(1, "reset") or self.peekAheadText(1, "free")))
        {
            if (self.namedHeapIsFar(first)) |far| {
                try self.expect(.period);
                return self.parseHeapOperation(first, far);
            }
        }
        if (self.peek(.period) and self.peekNext(.star)) return try self.parseDerefAssign(first);
        if (self.peek(.l_bracket)) return try self.parseArrayAssign(first, false);
        if (self.peek(.period) and self.dottedPathAssignOrIndexStart() and !std.mem.eql(u8, first, "c64") and !std.mem.eql(u8, first, "test6502") and !std.mem.eql(u8, first, "ZeroPage")) {
            const path = try self.parseDottedPathName(first);
            defer if (path.owned) self.allocator.free(path.name);
            if (self.peek(.l_bracket)) {
                const stable_name = if (path.owned) try self.allocator.dupe(u8, path.name) else path.name;
                return try self.parseArrayAssign(stable_name, path.owned);
            }
            if (self.eat(.equal)) {
                const stable_name = if (path.owned) try self.allocator.dupe(u8, path.name) else path.name;
                errdefer if (path.owned) self.allocator.free(stable_name);
                const value = try self.parseExpr();
                try self.expect(.semicolon);
                return .{ .assign = .{ .name = stable_name, .value = value, .name_owned = path.owned } };
            }
            const tag = self.tokens[self.index].tag;
            switch (tag) {
                .plus_equal, .minus_equal, .star_equal, .ampersand_equal, .pipe_equal, .caret_equal, .angle_left_angle_left_equal, .angle_right_angle_right_equal => self.index += 1,
                else => return error.UnsupportedStatement,
            }
            const stable_name = if (path.owned) try self.allocator.dupe(u8, path.name) else path.name;
            errdefer if (path.owned) self.allocator.free(stable_name);
            const value = try self.parseExpr();
            try self.expect(.semicolon);
            const assign = ast.AddAssign{ .name = stable_name, .value = value, .name_owned = path.owned };
            return switch (tag) {
                .plus_equal => .{ .add_assign = assign },
                .minus_equal => .{ .sub_assign = assign },
                .star_equal => .{ .mul_assign = assign },
                .ampersand_equal => .{ .bit_and_assign = assign },
                .pipe_equal => .{ .bit_or_assign = assign },
                .caret_equal => .{ .bit_xor_assign = assign },
                .angle_left_angle_left_equal => .{ .shl_assign = assign },
                .angle_right_angle_right_equal => .{ .shr_assign = assign },
                else => unreachable,
            };
        }
        if (self.eat(.equal)) {
            if (std.mem.eql(u8, first, "_")) {
                if (self.peek(.string_literal)) return error.UnsupportedStatement;
                const value = try self.parseExpr();
                try self.expect(.semicolon);
                return .{ .discard = value };
            }
            if (self.peek(.string_literal) or self.peekStringConcatStart()) {
                const expr = try self.parseStringExpr();
                try self.expect(.semicolon);
                return .{ .string_assign = .{ .name = first, .expr = expr } };
            }
            const value = try self.parseExpr();
            try self.expect(.semicolon);
            return .{ .assign = .{ .name = first, .value = value } };
        }
        if (self.eat(.plus_equal)) {
            const value = try self.parseExpr();
            try self.expect(.semicolon);
            return .{ .add_assign = .{ .name = first, .value = value } };
        }
        if (self.eat(.minus_equal)) {
            const value = try self.parseExpr();
            try self.expect(.semicolon);
            return .{ .sub_assign = .{ .name = first, .value = value } };
        }
        if (self.eat(.star_equal)) {
            const value = try self.parseExpr();
            try self.expect(.semicolon);
            return .{ .mul_assign = .{ .name = first, .value = value } };
        }
        if (self.eat(.ampersand_equal)) {
            const value = try self.parseExpr();
            try self.expect(.semicolon);
            return .{ .bit_and_assign = .{ .name = first, .value = value } };
        }
        if (self.eat(.pipe_equal)) {
            const value = try self.parseExpr();
            try self.expect(.semicolon);
            return .{ .bit_or_assign = .{ .name = first, .value = value } };
        }
        if (self.eat(.caret_equal)) {
            const value = try self.parseExpr();
            try self.expect(.semicolon);
            return .{ .bit_xor_assign = .{ .name = first, .value = value } };
        }
        if (self.eat(.angle_left_angle_left_equal)) {
            const value = try self.parseExpr();
            try self.expect(.semicolon);
            return .{ .shl_assign = .{ .name = first, .value = value } };
        }
        if (self.eat(.angle_right_angle_right_equal)) {
            const value = try self.parseExpr();
            try self.expect(.semicolon);
            return .{ .shr_assign = .{ .name = first, .value = value } };
        }

        if (self.peek(.period)) {
            if (std.mem.eql(u8, first, "c64")) return try self.parseC64Stmt(first);
            if (std.mem.eql(u8, first, "test6502")) return try self.parseTest6502Stmt();
            if (std.mem.eql(u8, first, "ZeroPage")) return try self.parseZeroPageStmt();
            if (self.findModuleBinding(first) != null) return try self.parseModuleBindingStmt(first);
            const target = try self.parseDottedTarget(first_token);
            const call = try self.parseCallAfterTarget(target);
            try self.expect(.semicolon);
            return .{ .call = call };
        }

        if (self.peek(.l_paren)) {
            if (inlineAsmPlaceholderIndex(first)) |asm_index| return try self.parseInlineAsmPlaceholder(asm_index);
            const call = try self.parseCallAfterTarget(first);
            try self.expect(.semicolon);
            return .{ .call = call };
        }

        return error.UnsupportedStatement;
    }

    fn parseArrayAssign(self: *Parser, name: []const u8, name_owned: bool) ParseError!ast.Stmt {
        errdefer if (name_owned) self.allocator.free(name);
        const index = try self.parseArrayIndexExpr();
        errdefer ast.freeExpr(self.allocator, index);
        if (self.peek(.period)) return try self.parseArrayFieldAssign(name, name_owned, index);
        const tag = self.tokens[self.index].tag;
        switch (tag) {
            .equal, .plus_equal, .minus_equal, .star_equal, .ampersand_equal, .pipe_equal, .caret_equal, .angle_left_angle_left_equal, .angle_right_angle_right_equal => self.index += 1,
            else => return error.UnsupportedStatement,
        }
        const value = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, value);
        try self.expect(.semicolon);
        const assign = ast.ArrayAssign{ .name = name, .index = index, .value = value, .name_owned = name_owned };
        return switch (tag) {
            .equal => .{ .array_assign = assign },
            .plus_equal => .{ .array_add_assign = assign },
            .minus_equal => .{ .array_sub_assign = assign },
            .star_equal => .{ .array_mul_assign = assign },
            .ampersand_equal => .{ .array_bit_and_assign = assign },
            .pipe_equal => .{ .array_bit_or_assign = assign },
            .caret_equal => .{ .array_bit_xor_assign = assign },
            .angle_left_angle_left_equal => .{ .array_shl_assign = assign },
            .angle_right_angle_right_equal => .{ .array_shr_assign = assign },
            else => unreachable,
        };
    }

    fn parseArrayFieldAssign(self: *Parser, name: []const u8, name_owned: bool, index: ast.Expr) ParseError!ast.Stmt {
        const field_path = try self.parseDottedSuffixName();
        errdefer self.allocator.free(field_path);
        const tag = self.tokens[self.index].tag;
        switch (tag) {
            .equal => self.index += 1,
            .plus_equal, .minus_equal, .star_equal, .ampersand_equal, .pipe_equal, .caret_equal, .angle_left_angle_left_equal, .angle_right_angle_right_equal => return error.UnsupportedStruct,
            else => return error.UnsupportedStatement,
        }
        const value = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, value);
        try self.expect(.semicolon);
        return .{ .array_field_assign = .{
            .name = name,
            .index = index,
            .field_path = field_path,
            .value = value,
            .name_owned = name_owned,
            .field_owned = true,
        } };
    }

    fn parseDerefAssign(self: *Parser, first: []const u8) ParseError!ast.Stmt {
        try self.expect(.period);
        try self.expect(.star);
        const tag = self.tokens[self.index].tag;
        switch (tag) {
            .equal => self.index += 1,
            else => return error.UnsupportedPointerTarget,
        }
        const ident_node = try self.allocator.create(ast.Expr);
        ident_node.* = .{ .value = .{ .ident = first } };
        errdefer {
            ast.freeExpr(self.allocator, ident_node.*);
            self.allocator.destroy(ident_node);
        }
        const target = ast.Expr{ .deref = ident_node };
        errdefer ast.freeExpr(self.allocator, target);
        const value = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, value);
        try self.expect(.semicolon);
        return .{ .deref_assign = .{ .target = target, .value = value } };
    }

    const DottedPath = struct {
        name: []const u8,
        owned: bool,
    };

    fn parseDottedPathName(self: *Parser, first: []const u8) ParseError!DottedPath {
        var joined = std.ArrayList(u8).empty;
        errdefer joined.deinit(self.allocator);
        try joined.appendSlice(self.allocator, first);
        while (self.eat(.period)) {
            try joined.append(self.allocator, '_');
            try joined.appendSlice(self.allocator, try self.expectIdent());
        }
        return .{ .name = try joined.toOwnedSlice(self.allocator), .owned = true };
    }

    fn parseDottedSuffixName(self: *Parser) ParseError![]const u8 {
        var joined = std.ArrayList(u8).empty;
        errdefer joined.deinit(self.allocator);
        var first = true;
        while (self.eat(.period)) {
            if (!first) try joined.append(self.allocator, '_');
            try joined.appendSlice(self.allocator, try self.expectIdent());
            first = false;
        }
        if (first) return error.UnexpectedToken;
        return try joined.toOwnedSlice(self.allocator);
    }

    fn dottedPathAssignOrIndexStart(self: *Parser) bool {
        var cursor = self.index;
        if (cursor >= self.tokens.len or self.tokens[cursor].tag != .period) return false;
        while (cursor < self.tokens.len and self.tokens[cursor].tag == .period) {
            cursor += 1;
            if (cursor >= self.tokens.len or self.tokens[cursor].tag != .identifier) return false;
            cursor += 1;
        }
        if (cursor >= self.tokens.len) return false;
        return switch (self.tokens[cursor].tag) {
            .l_bracket, .equal, .plus_equal, .minus_equal, .star_equal, .ampersand_equal, .pipe_equal, .caret_equal, .angle_left_angle_left_equal, .angle_right_angle_right_equal => true,
            else => false,
        };
    }

    fn dottedPathIndexExprStart(self: *Parser) bool {
        if (!self.peek(.identifier) or !self.peekNext(.period)) return false;
        var cursor = self.index + 1;
        while (cursor < self.tokens.len and self.tokens[cursor].tag == .period) {
            cursor += 1;
            if (cursor >= self.tokens.len or self.tokens[cursor].tag != .identifier) return false;
            cursor += 1;
        }
        return cursor < self.tokens.len and self.tokens[cursor].tag == .l_bracket;
    }

    fn parseTest6502Stmt(self: *Parser) ParseError!ast.Stmt {
        try self.expect(.period);
        const member = try self.expectIdent();
        try self.expect(.l_paren);

        const call: ast.Test6502Call = if (std.mem.eql(u8, member, "mark"))
            .{ .mark = try self.parseTest6502Arg1() }
        else if (std.mem.eql(u8, member, "primeRegs"))
            .{ .prime_regs = .{
                .id = try self.parseTest6502Arg(),
                .a = try self.parseTest6502ArgAfterComma(),
                .x = try self.parseTest6502ArgAfterComma(),
                .y = try self.parseTest6502ArgAfterComma(),
                .p = try self.parseTest6502ArgAfterComma(),
            } }
        else if (std.mem.eql(u8, member, "hit"))
            .{ .hit = try self.parseTest6502Arg1() }
        else if (std.mem.eql(u8, member, "expectHitCount"))
            .{ .expect_hit_count = .{ .id = try self.parseTest6502Arg(), .expected = try self.parseTest6502ArgAfterComma() } }
        else if (std.mem.eql(u8, member, "snapshot"))
            .{ .snapshot = try self.parseTest6502Arg1() }
        else if (std.mem.eql(u8, member, "expectNull"))
            .{ .expect_null = .{ .id = try self.parseTest6502Arg(), .actual = blk: {
                try self.expect(.comma);
                break :blk try self.parseExpr();
            } } }
        else if (std.mem.eql(u8, member, "expectSomeU8"))
            .{ .expect_some_u8 = try self.parseTest6502ExpectExpr(.number) }
        else if (std.mem.eql(u8, member, "expectSomeU16"))
            .{ .expect_some_u16 = try self.parseTest6502ExpectExpr(.number) }
        else if (std.mem.eql(u8, member, "expectSomeBool"))
            .{ .expect_some_bool = try self.parseTest6502ExpectExpr(.bool) }
        else if (std.mem.eql(u8, member, "expectSomePtr"))
            .{ .expect_some_ptr = try self.parseTest6502ExpectExpr(.number) }
        else if (std.mem.eql(u8, member, "expectEqualU8"))
            .{ .expect_equal_u8 = try self.parseTest6502ExpectExpr(.number) }
        else if (std.mem.eql(u8, member, "expectEqualI8"))
            .{ .expect_equal_i8 = try self.parseTest6502ExpectExpr(.number) }
        else if (std.mem.eql(u8, member, "expectEqualBool"))
            .{ .expect_equal_bool = try self.parseTest6502ExpectExpr(.bool) }
        else if (std.mem.eql(u8, member, "expectEqualU16"))
            .{ .expect_equal_u16 = try self.parseTest6502ExpectExpr(.number) }
        else if (std.mem.eql(u8, member, "expectString"))
            .{ .expect_string = try self.parseTest6502ExpectString() }
        else if (std.mem.eql(u8, member, "expectA"))
            .{ .expect_a = .{ .id = try self.parseTest6502Arg(), .expected = try self.parseTest6502ArgAfterComma() } }
        else if (std.mem.eql(u8, member, "expectX"))
            .{ .expect_x = .{ .id = try self.parseTest6502Arg(), .expected = try self.parseTest6502ArgAfterComma() } }
        else if (std.mem.eql(u8, member, "expectY"))
            .{ .expect_y = .{ .id = try self.parseTest6502Arg(), .expected = try self.parseTest6502ArgAfterComma() } }
        else if (std.mem.eql(u8, member, "expectSP"))
            .{ .expect_sp = .{ .id = try self.parseTest6502Arg(), .expected = try self.parseTest6502ArgAfterComma() } }
        else if (std.mem.eql(u8, member, "expectP"))
            .{ .expect_p = .{ .id = try self.parseTest6502Arg(), .mask = try self.parseTest6502ArgAfterComma(), .expected = try self.parseTest6502ArgAfterComma() } }
        else if (std.mem.eql(u8, member, "expectMemU8"))
            .{ .expect_mem_u8 = .{ .id = try self.parseTest6502Arg(), .addr = try self.parseTest6502ArgAfterComma(), .expected = try self.parseTest6502ArgAfterComma() } }
        else if (std.mem.eql(u8, member, "expectMemU16"))
            .{ .expect_mem_u16 = .{ .id = try self.parseTest6502Arg(), .addr = try self.parseTest6502ArgAfterComma(), .expected = try self.parseTest6502ArgAfterComma() } }
        else if (std.mem.eql(u8, member, "expectStackU8"))
            .{ .expect_stack_u8 = .{ .id = try self.parseTest6502Arg(), .offset = try self.parseTest6502ArgAfterComma(), .expected = try self.parseTest6502ArgAfterComma() } }
        else if (std.mem.eql(u8, member, "pass"))
            .pass
        else if (std.mem.eql(u8, member, "fail"))
            .{ .fail = try self.parseTest6502Arg1() }
        else
            return error.UnsupportedBuiltin;

        try self.expect(.r_paren);
        try self.expect(.semicolon);
        return .{ .test6502 = call };
    }

    fn parseTest6502Arg1(self: *Parser) ParseError!u16 {
        return try self.parseTest6502Arg();
    }

    fn parseTest6502ArgAfterComma(self: *Parser) ParseError!u16 {
        try self.expect(.comma);
        return try self.parseTest6502Arg();
    }

    fn parseTest6502Arg(self: *Parser) ParseError!u16 {
        return try self.parseU16();
    }

    const Test6502ExpectedKind = enum { number, bool };

    fn parseTest6502ExpectExpr(self: *Parser, comptime kind: Test6502ExpectedKind) ParseError!ast.ExpectExpr {
        const id = try self.parseTest6502Arg();
        try self.expect(.comma);
        const expected = switch (kind) {
            .number => try self.parseTest6502Arg(),
            .bool => @as(u16, @intFromBool(try self.parseBoolLiteral())),
        };
        try self.expect(.comma);
        return .{ .id = id, .expected = expected, .actual = try self.parseExpr() };
    }

    fn parseTest6502ExpectString(self: *Parser) ParseError!ast.ExpectString {
        const id = try self.parseTest6502Arg();
        try self.expect(.comma);
        const actual = try self.parseValue();
        try self.expect(.comma);
        return .{ .id = id, .actual = actual, .expected = try self.parseStringBytes(.petscii) };
    }

    fn parseBoolLiteral(self: *Parser) ParseError!bool {
        if (self.eat(.keyword_true)) return true;
        if (self.eat(.keyword_false)) return false;
        return error.UnexpectedToken;
    }

    fn parseInlineAsmPlaceholder(self: *Parser, asm_index: usize) ParseError!ast.Stmt {
        if (asm_index >= self.inline_asm_blocks.len) return error.UnsupportedStatement;
        try self.expect(.l_paren);
        try self.expect(.r_paren);
        try self.expect(.semicolon);
        const block = self.inline_asm_blocks[asm_index];
        return .{ .inline_asm = .{
            .source = block.source,
            .source_line = block.line,
            .source_column = block.column,
        } };
    }

    fn parseVar(self: *Parser) ParseError!ast.Stmt {
        try self.expect(.keyword_var);
        return try self.parseLocalBinding(true);
    }

    fn parseLocalConst(self: *Parser) ParseError!ast.Stmt {
        try self.expect(.keyword_const);
        return try self.parseLocalBinding(false);
    }

    fn parseLocalBinding(self: *Parser, mutable: bool) ParseError!ast.Stmt {
        const name = try self.expectIdent();
        if (self.peek(.equal) and self.peekAhead(1, .string_literal)) return error.UnsupportedRuntimeString;
        if (self.peek(.equal) and self.isStringBufferInit()) {
            if (!mutable) return error.UnsupportedRuntimeString;
            try self.expect(.equal);
            _ = try self.expectIdent();
            try self.expect(.period);
            _ = try self.expectIdent();
            try self.expect(.period);
            _ = try self.expectIdent();
            try self.expect(.l_paren);
            const capacity = std.math.cast(u8, try self.parseU16()) orelse return error.Overflow;
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return .{ .string_var = .{ .name = name, .capacity = capacity } };
        }
        if (self.eat(.colon)) {
            const ty = try self.parseType();
            try self.expect(.equal);
            if (self.peek(.string_literal)) return error.UnsupportedRuntimeString;
            const init = try self.parseExpr();
            try self.expect(.semicolon);
            if (init == .struct_literal) {
                if (ty != .custom) return error.UnsupportedStruct;
                if (self.isKnownUnion(ty.custom)) {
                    if (init.struct_literal.type_name.len != 0 and !std.mem.eql(u8, ty.custom, init.struct_literal.type_name)) return error.UnsupportedStruct;
                    return .{ .var_decl = .{ .name = name, .ty = ty, .init = init, .mutable = mutable } };
                }
                if (init.struct_literal.type_name.len != 0 and !std.mem.eql(u8, ty.custom, init.struct_literal.type_name)) return error.UnsupportedStruct;
                return .{ .struct_var = .{
                    .name = name,
                    .type_name = ty.custom,
                    .mutable = mutable,
                    .fields = init.struct_literal.fields,
                } };
            }
            return .{ .var_decl = .{ .name = name, .ty = ty, .init = init, .mutable = mutable } };
        }

        try self.expect(.equal);
        if (self.peek(.identifier) and self.peekNext(.l_brace)) {
            const literal = try self.parseStructLiteral();
            try self.expect(.semicolon);
            if (self.isKnownUnion(literal.type_name)) {
                return .{ .var_decl = .{ .name = name, .ty = .{ .custom = literal.type_name }, .init = .{ .struct_literal = literal }, .mutable = mutable } };
            }
            return .{ .struct_var = .{
                .name = name,
                .type_name = literal.type_name,
                .mutable = mutable,
                .fields = literal.fields,
            } };
        }
        if (!mutable) {
            if (self.peek(.string_literal)) return error.UnsupportedRuntimeString;
            const init = try self.parseExpr();
            try self.expect(.semicolon);
            return .{ .var_decl = .{ .name = name, .ty = null, .init = init, .mutable = false } };
        }
        if (self.peek(.string_literal)) return error.UnsupportedRuntimeString;
        if (self.isArrayLiteralStart()) {
            const init = try self.parseExpr();
            try self.expect(.semicolon);
            return .{ .var_decl = .{ .name = name, .ty = null, .init = init, .mutable = true } };
        }
        const init = try self.parseExpr();
        try self.expect(.semicolon);
        return .{ .var_decl = .{ .name = name, .ty = null, .init = init, .mutable = true } };
    }

    fn parseWhile(self: *Parser) ParseError!ast.Stmt {
        try self.expect(.keyword_while);
        try self.expect(.l_paren);
        const condition = try self.parseExpr();
        try self.expect(.r_paren);
        const body = try self.parseBlock();
        return .{ .while_stmt = .{ .condition = condition, .body = body } };
    }

    fn parseFor(self: *Parser) ParseError!ast.Stmt {
        try self.expect(.keyword_for);
        const id = self.nextForId();
        try self.expect(.l_paren);
        const source = try self.parseForSource();
        try self.expect(.r_paren);

        const captures = try self.parseForCaptures(source);
        const body = try self.parseBlock();
        errdefer ast.freeStmtList(self.allocator, body);
        if (self.eat(.keyword_else)) return error.UnsupportedForElse;

        return .{ .for_stmt = .{
            .id = id,
            .source = source,
            .item_name = captures.item,
            .index_name = captures.index,
            .body = body,
        } };
    }

    const ForCaptures = struct {
        item: ?[]const u8,
        index: ?[]const u8,
    };

    fn parseForSource(self: *Parser) ParseError!ast.ForSource {
        if (self.peek(.number)) {
            const start = try self.parseU16();
            if (start != 0) return error.UnsupportedForRange;
            try self.expect(.period_period);
            return .{ .range = try self.parseForRangeEnd() };
        }

        if (!self.peek(.identifier)) return error.UnsupportedForSource;
        const name = try self.expectIdent();
        if (self.eat(.comma)) {
            const start = try self.parseU16();
            if (start != 0) return error.UnsupportedForRange;
            try self.expect(.period_period);
            return .{ .array_indexed = name };
        }
        return .{ .array = name };
    }

    fn parseForRangeEnd(self: *Parser) ParseError!ast.ForRangeEnd {
        if (self.peek(.number)) {
            const end = try self.parseU16();
            if (end > 255) return error.UnsupportedForRange;
            return .{ .int = end };
        }
        if (self.peek(.identifier) and self.peekNext(.period) and self.peekAheadText(2, "len")) {
            const name = try self.expectIdent();
            try self.expect(.period);
            const field = try self.expectIdent();
            if (!std.mem.eql(u8, field, "len")) return error.UnsupportedForRange;
            return .{ .array_len = name };
        }
        return error.UnsupportedForRange;
    }

    fn parseForCaptures(self: *Parser, source: ast.ForSource) ParseError!ForCaptures {
        try self.expect(.pipe);
        if (self.peek(.star)) return error.UnsupportedForPointerCapture;
        const item = try self.parseForCaptureName();
        var index: ?[]const u8 = null;
        if (self.eat(.comma)) {
            if (self.peek(.star)) return error.UnsupportedForPointerCapture;
            index = try self.parseForCaptureName();
        }
        try self.expect(.pipe);

        switch (source) {
            .array_indexed => if (index == null) return error.UnsupportedFor,
            .array, .range => if (index != null) return error.UnsupportedFor,
        }
        return .{ .item = item, .index = index };
    }

    fn parseForCaptureName(self: *Parser) ParseError!?[]const u8 {
        const name = try self.expectIdent();
        if (std.mem.eql(u8, name, "_")) return null;
        return name;
    }

    fn parseSwitchStmt(self: *Parser) ParseError!ast.Stmt {
        const operand = try self.parseSwitchOperandStart();
        errdefer ast.freeExpr(self.allocator, operand);
        var prongs: std.ArrayList(ast.SwitchStmtProng) = .empty;
        errdefer {
            for (prongs.items) |prong| {
                if (prong.selectors.len != 0) self.allocator.free(prong.selectors);
                ast.freeStmtList(self.allocator, prong.body);
            }
            prongs.deinit(self.allocator);
        }
        while (!self.peek(.r_brace)) {
            const selectors = try self.parseSwitchSelectors();
            errdefer if (selectors.len != 0) self.allocator.free(selectors);
            try self.expectSwitchArrow();
            const payload_name = try self.parseOptionalPayloadCapture();
            const body = try self.parseBlock();
            errdefer ast.freeStmtList(self.allocator, body);
            try prongs.append(self.allocator, .{ .selectors = selectors, .payload_name = payload_name, .body = body });
            _ = self.eat(.comma);
        }
        try self.expect(.r_brace);
        return .{ .switch_stmt = .{ .operand = operand, .prongs = try prongs.toOwnedSlice(self.allocator) } };
    }

    fn parseIf(self: *Parser) ParseError!ast.Stmt {
        try self.expect(.keyword_if);
        try self.expect(.l_paren);
        const condition = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, condition);
        try self.expect(.r_paren);
        const payload_name = try self.parseOptionalPayloadCapture();
        const then_body = try self.parseBlock();
        errdefer ast.freeStmtList(self.allocator, then_body);
        var else_body: []ast.Stmt = &.{};
        errdefer ast.freeStmtList(self.allocator, else_body);
        if (self.eat(.keyword_else)) {
            if (self.peek(.keyword_if)) {
                const nested_if = try self.parseIf();
                errdefer ast.freeStmt(self.allocator, nested_if);
                else_body = try self.allocator.alloc(ast.Stmt, 1);
                else_body[0] = nested_if;
            } else {
                else_body = try self.parseBlock();
            }
        }
        return .{ .if_stmt = .{ .condition = condition, .payload_name = payload_name, .then_body = then_body, .else_body = else_body } };
    }

    fn parseOptionalPayloadCapture(self: *Parser) ParseError!?[]const u8 {
        if (!self.eat(.pipe)) return null;
        const name = try self.expectIdent();
        try self.expect(.pipe);
        return name;
    }

    fn parseReturn(self: *Parser) ParseError!ast.Stmt {
        try self.expect(.keyword_return);
        const expr = try self.parseExpr();
        try self.expect(.semicolon);
        return .{ .return_expr = expr };
    }

    fn parseC64Stmt(self: *Parser, first: []const u8) ParseError!ast.Stmt {
        _ = first;
        try self.expect(.period);
        const module = try self.expectIdent();
        try self.expect(.period);
        const member = try self.expectIdent();

        if (std.mem.eql(u8, module, "vic") and std.mem.eql(u8, member, "border")) {
            try self.expect(.equal);
            const value = try self.parseExpr();
            try self.expect(.semicolon);
            return .{ .field_assign = .{ .path = .c64_vic_border, .value = value } };
        }

        if (std.mem.eql(u8, module, "console")) return try self.parseConsoleStmt(member);
        if (std.mem.eql(u8, module, "kernal")) return try self.parseKernalStmt(member);
        if (std.mem.eql(u8, module, "string")) return try self.parseStringStmt(member);
        if (std.mem.eql(u8, module, "time")) return try self.parseTimeStmt(member);
        if (!std.mem.eql(u8, module, "screen")) return error.UnsupportedBuiltin;

        try self.expect(.l_paren);
        if (std.mem.eql(u8, member, "clear")) {
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return .{ .builtin = .screen_clear };
        }
        if (std.mem.eql(u8, member, "putsAt")) {
            const x = try self.parseValue();
            try self.expect(.comma);
            const y = try self.parseValue();
            try self.expect(.comma);
            const literal_text = try self.parseString();
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return .{ .builtin = .{ .puts_at = .{ .x = x, .y = y, .text = literal_text } } };
        }
        if (std.mem.eql(u8, member, "putAt")) {
            const x = try self.parseCoord();
            try self.expect(.comma);
            const y = try self.parseValue();
            try self.expect(.comma);
            const ch = try self.parseExpr();
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return .{ .builtin = .{ .put_at = .{ .x = x, .y = y, .ch = ch } } };
        }
        if (std.mem.eql(u8, member, "hexAt")) {
            const x = try self.parseValue();
            try self.expect(.comma);
            const y = try self.parseValue();
            try self.expect(.comma);
            const value = try self.parseExpr();
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return .{ .builtin = .{ .hex_at = .{ .x = x, .y = y, .value = value } } };
        }
        if (std.mem.eql(u8, member, "hex16At")) {
            const x = try self.parseValue();
            try self.expect(.comma);
            const y = try self.parseValue();
            try self.expect(.comma);
            const value = try self.parseExpr();
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return .{ .builtin = .{ .hex16_at = .{ .x = x, .y = y, .value = value } } };
        }

        return error.UnsupportedBuiltin;
    }

    fn parseConsoleStmt(self: *Parser, member: []const u8) ParseError!ast.Stmt {
        try self.expect(.l_paren);
        if (std.mem.eql(u8, member, "clear")) {
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return .{ .builtin = .console_clear };
        }

        if (std.mem.eql(u8, member, "print")) {
            const format = try self.parseString();
            var args: std.ArrayList(ast.PrintArg) = if (self.eat(.comma)) try self.parsePrintArgTuple() else .empty;
            errdefer {
                for (args.items) |arg| ast.freePrintArg(self.allocator, arg);
                args.deinit(self.allocator);
            }
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return .{ .builtin = .{ .console_print = .{ .format = format, .args = try args.toOwnedSlice(self.allocator) } } };
        }

        if (std.mem.eql(u8, member, "puts")) {
            const value = try self.parseValue();
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return .{ .builtin = .{ .console_puts = value } };
        }

        return error.UnsupportedBuiltin;
    }

    fn parseKernalStmt(self: *Parser, member: []const u8) ParseError!ast.Stmt {
        try self.expect(.l_paren);
        const value = try self.parseValue();
        try self.expect(.r_paren);
        try self.expect(.semicolon);
        if (std.mem.eql(u8, member, "puts")) return .{ .builtin = .{ .kernal_puts = value } };
        if (std.mem.eql(u8, member, "setName")) return .{ .builtin = .{ .kernal_set_name = value } };
        return error.UnsupportedBuiltin;
    }

    fn parseStringStmt(self: *Parser, member: []const u8) ParseError!ast.Stmt {
        try self.expect(.l_paren);
        const target = try self.parseValue();
        if (std.mem.eql(u8, member, "append")) {
            try self.expect(.comma);
            const expr = try self.parseStringExpr();
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return .{ .builtin = .{ .string_append = .{ .target = target, .expr = expr } } };
        }
        if (std.mem.eql(u8, member, "clear")) {
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return .{ .builtin = .{ .string_clear = target } };
        }
        return error.UnsupportedBuiltin;
    }

    fn parseTimeStmt(self: *Parser, member: []const u8) ParseError!ast.Stmt {
        const is_sleep_ticks = std.mem.eql(u8, member, "sleepTicks");
        const is_sleep_frames = std.mem.eql(u8, member, "sleepFrames");
        if (!is_sleep_ticks and !is_sleep_frames) return error.UnsupportedBuiltin;
        try self.expect(.l_paren);
        const ticks = try self.parseExpr();
        try self.expect(.r_paren);
        try self.expect(.semicolon);
        if (is_sleep_frames) return .{ .builtin = .{ .sleep_frames = .{ .ticks = ticks } } };
        return .{ .builtin = .{ .sleep_ticks = .{ .ticks = ticks } } };
    }

    fn parseZeroPageStmt(self: *Parser) ParseError!ast.Stmt {
        try self.expect(.period);
        const module = try self.expectIdent();
        if (std.mem.eql(u8, module, "heap")) return try self.parseZeroPageHeapStmt();
        try self.expect(.period);
        const member = try self.expectIdent();
        if (std.mem.eql(u8, module, "module")) return try self.parseZPMDoduleStmt(member);
        if (!std.mem.eql(u8, module, "reu")) return error.UnsupportedBuiltin;

        if (std.mem.eql(u8, member, "copyC64ToReu")) return .{ .reu = .{ .copy_c64_to_reu = try self.parseReuTransferArgs(.c64_first) } };
        if (std.mem.eql(u8, member, "copyReuToC64")) return .{ .reu = .{ .copy_reu_to_c64 = try self.parseReuTransferArgs(.reu_first) } };
        if (std.mem.eql(u8, member, "swap")) return .{ .reu = .{ .swap = try self.parseReuTransferArgs(.c64_first) } };
        if (std.mem.eql(u8, member, "fill")) return .{ .reu = .{ .fill = try self.parseReuFillArgs() } };
        if (std.mem.eql(u8, member, "copyFromC64")) return .{ .reu = .{ .copy_from_c64 = try self.parseReuFarCopyArgs() } };
        if (std.mem.eql(u8, member, "copyToC64")) return .{ .reu = .{ .copy_to_c64 = try self.parseReuFarCopyArgs() } };
        if (std.mem.eql(u8, member, "heap")) return try self.parseZeroPageReuHeapStmt();
        return error.UnsupportedBuiltin;
    }

    fn parseZeroPageReuHeapStmt(self: *Parser) ParseError!ast.Stmt {
        try self.expect(.l_paren);
        const heap_name = try self.parseHeapNameLiteral();
        try self.expect(.r_paren);
        try self.expect(.period);
        return self.parseHeapOperation(heap_name, true);
    }

    fn parseZeroPageHeapStmt(self: *Parser) ParseError!ast.Stmt {
        try self.expect(.l_paren);
        const heap_name = try self.parseHeapNameLiteral();
        try self.expect(.r_paren);
        try self.expect(.period);
        return self.parseHeapOperation(heap_name, false);
    }

    fn parseHeapOperation(self: *Parser, heap_name: []const u8, far: bool) ParseError!ast.Stmt {
        const member = try self.expectIdent();
        if (std.mem.eql(u8, member, "reset")) {
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return if (far) .{ .reu_heap_reset = heap_name } else .{ .heap_reset = heap_name };
        }
        if (!far and std.mem.eql(u8, member, "free")) {
            try self.expect(.l_paren);
            const ptr = try self.parseExpr();
            errdefer ast.freeExpr(self.allocator, ptr);
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            const ptr_node = try self.allocator.create(ast.Expr);
            ptr_node.* = ptr;
            return .{ .heap_free = .{ .name = heap_name, .ptr = ptr_node } };
        }
        return error.UnsupportedHeapFunction;
    }

    const ReuTransferArgOrder = enum { c64_first, reu_first };

    fn parseReuTransferArgs(self: *Parser, order: ReuTransferArgOrder) ParseError!ast.ReuTransfer {
        try self.expect(.l_paren);
        var c64_addr: ast.Expr = undefined;
        var reu_addr: u32 = 0;
        switch (order) {
            .c64_first => {
                c64_addr = try self.parseExpr();
                errdefer ast.freeExpr(self.allocator, c64_addr);
                try self.expect(.comma);
                reu_addr = try self.parseReuAddressLiteral();
            },
            .reu_first => {
                reu_addr = try self.parseReuAddressLiteral();
                try self.expect(.comma);
                c64_addr = try self.parseExpr();
                errdefer ast.freeExpr(self.allocator, c64_addr);
            },
        }
        try self.expect(.comma);
        const len = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, len);
        try self.validateReuLengthExpr(len);
        try self.expect(.r_paren);
        try self.expect(.semicolon);
        const c64_node = try self.allocator.create(ast.Expr);
        c64_node.* = c64_addr;
        errdefer {
            ast.freeExpr(self.allocator, c64_node.*);
            self.allocator.destroy(c64_node);
        }
        const len_node = try self.allocator.create(ast.Expr);
        len_node.* = len;
        return .{ .c64_addr = c64_node, .reu_addr = reu_addr, .len = len_node };
    }

    fn parseReuFillArgs(self: *Parser) ParseError!ast.ReuFill {
        try self.expect(.l_paren);
        const reu_addr = try self.parseReuAddressLiteral();
        try self.expect(.comma);
        const value = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, value);
        try self.expect(.comma);
        const len = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, len);
        try self.validateReuLengthExpr(len);
        try self.expect(.r_paren);
        try self.expect(.semicolon);
        const value_node = try self.allocator.create(ast.Expr);
        value_node.* = value;
        errdefer {
            ast.freeExpr(self.allocator, value_node.*);
            self.allocator.destroy(value_node);
        }
        const len_node = try self.allocator.create(ast.Expr);
        len_node.* = len;
        return .{ .reu_addr = reu_addr, .value = value_node, .len = len_node };
    }

    fn parseReuCompareArgs(self: *Parser) ParseError!ast.ReuTransfer {
        try self.expect(.l_paren);
        const c64_addr = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, c64_addr);
        try self.expect(.comma);
        const reu_addr = try self.parseReuAddressLiteral();
        try self.expect(.comma);
        const len = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, len);
        try self.validateReuLengthExpr(len);
        try self.expect(.r_paren);
        const c64_node = try self.allocator.create(ast.Expr);
        c64_node.* = c64_addr;
        errdefer {
            ast.freeExpr(self.allocator, c64_node.*);
            self.allocator.destroy(c64_node);
        }
        const len_node = try self.allocator.create(ast.Expr);
        len_node.* = len;
        return .{ .c64_addr = c64_node, .reu_addr = reu_addr, .len = len_node };
    }

    fn parseReuFarCopyArgs(self: *Parser) ParseError!ast.ReuFarCopy {
        try self.expect(.l_paren);
        const far = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, far);
        try self.expect(.comma);
        const c64_addr = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, c64_addr);
        try self.expect(.comma);
        const len = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, len);
        try self.validateReuLengthExpr(len);
        try self.expect(.r_paren);
        try self.expect(.semicolon);

        const far_node = try self.allocator.create(ast.Expr);
        far_node.* = far;
        errdefer {
            ast.freeExpr(self.allocator, far_node.*);
            self.allocator.destroy(far_node);
        }
        const c64_node = try self.allocator.create(ast.Expr);
        c64_node.* = c64_addr;
        errdefer {
            ast.freeExpr(self.allocator, c64_node.*);
            self.allocator.destroy(c64_node);
        }
        const len_node = try self.allocator.create(ast.Expr);
        len_node.* = len;
        return .{ .far = far_node, .c64_addr = c64_node, .len = len_node };
    }

    fn parseReuAddressLiteral(self: *Parser) ParseError!u32 {
        if (!self.peek(.number)) return error.UnsupportedReuAddress;
        const token = try self.expectToken(.number);
        const literal = self.text(token);
        const value = if (std.mem.startsWith(u8, literal, "0x") or std.mem.startsWith(u8, literal, "0X"))
            std.fmt.parseInt(u32, literal[2..], 16) catch return error.UnsupportedReuAddress
        else
            std.fmt.parseInt(u32, literal, 10) catch return error.UnsupportedReuAddress;
        if (value > 0x00ff_ffff) return error.UnsupportedReuAddress;
        return value;
    }

    fn validateReuLengthExpr(self: *Parser, expr: ast.Expr) ParseError!void {
        _ = self;
        switch (expr) {
            .value => |value| switch (value) {
                .int => |n| if (n == 0) return error.UnsupportedReuLength,
                else => {},
            },
            else => {},
        }
    }

    fn validateHeapLengthExpr(self: *Parser, expr: ast.Expr) ParseError!void {
        _ = self;
        switch (expr) {
            .value => |value| switch (value) {
                .int => |n| if (n == 0) return error.UnsupportedHeapLength,
                else => {},
            },
            else => {},
        }
    }

    fn parsePrintArgTuple(self: *Parser) ParseError!std.ArrayList(ast.PrintArg) {
        try self.expect(.period);
        try self.expect(.l_brace);
        var args: std.ArrayList(ast.PrintArg) = .empty;
        errdefer {
            for (args.items) |arg| ast.freePrintArg(self.allocator, arg);
            args.deinit(self.allocator);
        }

        while (!self.peek(.r_brace)) {
            const arg: ast.PrintArg = if (self.peek(.string_literal))
                .{ .string = try self.parseString() }
            else
                .{ .value = try self.parseExpr() };
            args.append(self.allocator, arg) catch |err| {
                ast.freePrintArg(self.allocator, arg);
                return err;
            };
            if (!self.eat(.comma)) break;
        }

        try self.expect(.r_brace);
        return args;
    }

    fn parseCoord(self: *Parser) ParseError!ast.Coord {
        const first = try self.parseValue();
        if (self.eat(.plus)) {
            return .{ .base_plus = .{ .base = try valueAsU8(first), .offset = try self.parseValue() } };
        }
        return .{ .value = first };
    }

    fn parseExpr(self: *Parser) ParseError!ast.Expr {
        return try self.parseBoolOr();
    }

    fn parseBoolOr(self: *Parser) ParseError!ast.Expr {
        var lhs = try self.parseBoolAnd();
        errdefer ast.freeExpr(self.allocator, lhs);
        while (self.eat(.keyword_or)) {
            const lhs_node = try self.allocator.create(ast.Expr);
            lhs_node.* = lhs;
            errdefer {
                ast.freeExpr(self.allocator, lhs_node.*);
                self.allocator.destroy(lhs_node);
            }
            const rhs = try self.parseBoolAnd();
            const rhs_node = try self.allocator.create(ast.Expr);
            rhs_node.* = rhs;
            lhs = .{ .bool_or = .{ .lhs = lhs_node, .rhs = rhs_node } };
        }
        return lhs;
    }

    fn parseBoolAnd(self: *Parser) ParseError!ast.Expr {
        var lhs = try self.parseComparison();
        errdefer ast.freeExpr(self.allocator, lhs);
        while (self.eat(.keyword_and)) {
            const lhs_node = try self.allocator.create(ast.Expr);
            lhs_node.* = lhs;
            errdefer {
                ast.freeExpr(self.allocator, lhs_node.*);
                self.allocator.destroy(lhs_node);
            }
            const rhs = try self.parseComparison();
            const rhs_node = try self.allocator.create(ast.Expr);
            rhs_node.* = rhs;
            lhs = .{ .bool_and = .{ .lhs = lhs_node, .rhs = rhs_node } };
        }
        return lhs;
    }

    fn parseComparison(self: *Parser) ParseError!ast.Expr {
        const lhs = try self.parseBitOr();
        errdefer ast.freeExpr(self.allocator, lhs);
        const op = self.comparisonOp() orelse {
            return lhs;
        };
        self.index += 1;

        const lhs_node = try self.allocator.create(ast.Expr);
        lhs_node.* = lhs;
        errdefer {
            ast.freeExpr(self.allocator, lhs_node.*);
            self.allocator.destroy(lhs_node);
        }

        const rhs = try self.parseBitOr();
        errdefer ast.freeExpr(self.allocator, rhs);
        if (self.comparisonOp() != null) return error.UnsupportedChainedComparison;
        const rhs_node = try self.allocator.create(ast.Expr);
        rhs_node.* = rhs;

        return switch (op) {
            .equal_equal => .{ .eq = .{ .lhs = lhs_node, .rhs = rhs_node } },
            .bang_equal => .{ .ne = .{ .lhs = lhs_node, .rhs = rhs_node } },
            .angle_left => .{ .lt = .{ .lhs = lhs_node, .rhs = rhs_node } },
            .angle_left_equal => .{ .lte = .{ .lhs = lhs_node, .rhs = rhs_node } },
            .angle_right => .{ .gt = .{ .lhs = lhs_node, .rhs = rhs_node } },
            .angle_right_equal => .{ .gte = .{ .lhs = lhs_node, .rhs = rhs_node } },
            else => unreachable,
        };
    }

    fn parseBitOr(self: *Parser) ParseError!ast.Expr {
        var lhs = try self.parseBitXor();
        errdefer ast.freeExpr(self.allocator, lhs);
        while (self.eat(.pipe)) {
            const lhs_node = try self.allocator.create(ast.Expr);
            lhs_node.* = lhs;
            errdefer {
                ast.freeExpr(self.allocator, lhs_node.*);
                self.allocator.destroy(lhs_node);
            }
            const rhs = try self.parseBitXor();
            const rhs_node = try self.allocator.create(ast.Expr);
            rhs_node.* = rhs;
            lhs = .{ .bit_or = .{ .lhs = lhs_node, .rhs = rhs_node } };
        }
        return lhs;
    }

    fn parseBitXor(self: *Parser) ParseError!ast.Expr {
        var lhs = try self.parseBitAnd();
        errdefer ast.freeExpr(self.allocator, lhs);
        while (self.eat(.caret)) {
            const lhs_node = try self.allocator.create(ast.Expr);
            lhs_node.* = lhs;
            errdefer {
                ast.freeExpr(self.allocator, lhs_node.*);
                self.allocator.destroy(lhs_node);
            }
            const rhs = try self.parseBitAnd();
            const rhs_node = try self.allocator.create(ast.Expr);
            rhs_node.* = rhs;
            lhs = .{ .bit_xor = .{ .lhs = lhs_node, .rhs = rhs_node } };
        }
        return lhs;
    }

    fn parseBitAnd(self: *Parser) ParseError!ast.Expr {
        var lhs = try self.parseShift();
        errdefer ast.freeExpr(self.allocator, lhs);
        while (self.eat(.ampersand)) {
            const lhs_node = try self.allocator.create(ast.Expr);
            lhs_node.* = lhs;
            errdefer {
                ast.freeExpr(self.allocator, lhs_node.*);
                self.allocator.destroy(lhs_node);
            }
            const rhs = try self.parseShift();
            const rhs_node = try self.allocator.create(ast.Expr);
            rhs_node.* = rhs;
            lhs = .{ .bit_and = .{ .lhs = lhs_node, .rhs = rhs_node } };
        }
        return lhs;
    }

    fn parseShift(self: *Parser) ParseError!ast.Expr {
        var lhs = try self.parseAddSub();
        errdefer ast.freeExpr(self.allocator, lhs);
        while (self.peek(.angle_left_angle_left) or self.peek(.angle_right_angle_right)) {
            const tag = self.tokens[self.index].tag;
            self.index += 1;
            const lhs_node = try self.allocator.create(ast.Expr);
            lhs_node.* = lhs;
            errdefer {
                ast.freeExpr(self.allocator, lhs_node.*);
                self.allocator.destroy(lhs_node);
            }
            const rhs = try self.parseAddSub();
            const rhs_node = try self.allocator.create(ast.Expr);
            rhs_node.* = rhs;
            lhs = switch (tag) {
                .angle_left_angle_left => .{ .shl = .{ .lhs = lhs_node, .rhs = rhs_node } },
                .angle_right_angle_right => .{ .shr = .{ .lhs = lhs_node, .rhs = rhs_node } },
                else => unreachable,
            };
        }
        return lhs;
    }

    fn parseAddSub(self: *Parser) ParseError!ast.Expr {
        var lhs = try self.parseMul();
        errdefer ast.freeExpr(self.allocator, lhs);
        while (true) {
            if (self.peek(.plus_plus)) return error.UnsupportedStringConcat;
            if (!self.peek(.plus) and !self.peek(.minus)) break;
            const tag = self.tokens[self.index].tag;
            self.index += 1;
            const lhs_node = try self.allocator.create(ast.Expr);
            lhs_node.* = lhs;
            errdefer {
                ast.freeExpr(self.allocator, lhs_node.*);
                self.allocator.destroy(lhs_node);
            }
            const rhs = try self.parseMul();
            const rhs_node = try self.allocator.create(ast.Expr);
            rhs_node.* = rhs;
            lhs = switch (tag) {
                .plus => .{ .add = .{ .lhs = lhs_node, .rhs = rhs_node } },
                .minus => .{ .sub = .{ .lhs = lhs_node, .rhs = rhs_node } },
                else => unreachable,
            };
        }
        return lhs;
    }

    fn parseMul(self: *Parser) ParseError!ast.Expr {
        var lhs = try self.parseUnary();
        errdefer ast.freeExpr(self.allocator, lhs);
        while (self.eat(.star)) {
            const lhs_node = try self.allocator.create(ast.Expr);
            lhs_node.* = lhs;
            errdefer {
                ast.freeExpr(self.allocator, lhs_node.*);
                self.allocator.destroy(lhs_node);
            }
            const rhs = try self.parseUnary();
            const rhs_node = try self.allocator.create(ast.Expr);
            rhs_node.* = rhs;
            lhs = .{ .mul = .{ .lhs = lhs_node, .rhs = rhs_node } };
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) ParseError!ast.Expr {
        if (self.eat(.ampersand)) {
            return .{ .address_of = try self.parseAddressOfTarget() };
        }
        if (self.eat(.bang)) {
            const child = try self.allocator.create(ast.Expr);
            child.* = try self.parseUnary();
            return .{ .not = child };
        }
        if (self.eat(.tilde)) {
            const child = try self.allocator.create(ast.Expr);
            child.* = try self.parseUnary();
            return .{ .bit_not = child };
        }
        return try self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) ParseError!ast.Expr {
        if (self.eat(.l_paren)) {
            const expr = try self.parseExpr();
            try self.expect(.r_paren);
            return expr;
        }
        if (self.peek(.keyword_if)) {
            return try self.parseIfExpr();
        }
        if (self.peek(.keyword_switch)) {
            return try self.parseSwitchExpr();
        }
        if (self.peek(.identifier) and self.peekNext(.colon) and self.peekAhead(2, .l_brace)) {
            return try self.parseBlockExpr();
        }
        if (self.isC64KeyboardCall()) {
            return try self.parseC64KeyboardExpr();
        }
        if (self.isZeroPageReuExpr()) {
            return try self.parseZeroPageReuExpr();
        }
        if (self.isZeroPageHeapExpr()) {
            return try self.parseZeroPageHeapExpr();
        }
        if (self.peek(.identifier) and self.peekNext(.period) and self.peekAheadText(2, "allocBytes") and self.peekAhead(3, .l_paren)) {
            const name = self.text(self.tokens[self.index]);
            if (self.namedHeapIsFar(name)) |far| {
                self.index += 2;
                return self.parseHeapAllocation(name, far);
            }
        }
        if (self.isZPMDoduleExpr()) {
            return try self.parseZPMDoduleExpr();
        }
        if (self.peek(.at)) {
            return try self.parseBuiltinExpr();
        }
        if (self.peek(.identifier) and self.peekNext(.period) and self.peekAhead(2, .star)) {
            const child = try self.allocator.create(ast.Expr);
            const name = try self.expectIdent();
            try self.expect(.period);
            try self.expect(.star);
            child.* = .{ .value = .{ .ident = name } };
            return .{ .deref = child };
        }
        if (self.isAnonymousStructLiteralStart()) {
            return .{ .struct_literal = try self.parseAnonymousStructLiteral() };
        }
        if (self.isArrayLiteralStart()) {
            return .{ .array_literal = try self.parseArrayLiteral() };
        }
        if (self.peek(.identifier) and self.peekNext(.l_brace)) {
            return .{ .struct_literal = try self.parseStructLiteral() };
        }
        if (self.isFarViewMaterializeExpr()) {
            return try self.parseFarViewMaterializeExpr();
        }
        if (self.isModuleBindingCallExpr()) {
            return try self.parseModuleBindingCallExpr();
        }
        if (self.dottedPathIndexExprStart()) {
            const first = try self.expectIdent();
            const path = try self.parseDottedPathName(first);
            const index = try self.allocator.create(ast.Expr);
            index.* = try self.parseArrayIndexExpr();
            if (self.peek(.period)) {
                const field_path = try self.parseDottedSuffixName();
                return .{ .array_field_index = .{
                    .name = path.name,
                    .name_owned = true,
                    .index = index,
                    .field_path = field_path,
                    .field_owned = true,
                } };
            }
            return .{ .array_index = .{ .name = path.name, .name_owned = true, .index = index } };
        }
        if (self.peek(.identifier) and self.peekNext(.l_bracket)) {
            const name = try self.expectIdent();
            const index = try self.allocator.create(ast.Expr);
            index.* = try self.parseArrayIndexExpr();
            if (self.peek(.period)) {
                const field_path = try self.parseDottedSuffixName();
                return .{ .array_field_index = .{
                    .name = name,
                    .index = index,
                    .field_path = field_path,
                    .field_owned = true,
                } };
            }
            return .{ .array_index = .{ .name = name, .index = index } };
        }
        if (self.peek(.identifier) and (self.peekNext(.l_paren) or (self.peekNext(.period) and self.peekAhead(3, .l_paren)))) {
            const target = try self.parseCallTarget();
            return .{ .call = try self.parseCallAfterTarget(target) };
        }
        return .{ .value = try self.parseValue() };
    }

    fn isModuleBindingCallExpr(self: *Parser) bool {
        if (!self.peek(.identifier) or !self.peekNext(.period) or !self.peekAhead(3, .l_paren)) return false;
        const bindings = self.parsed_module_bindings orelse return false;
        const binding_name = self.text(self.tokens[self.index]);
        for (bindings.items) |binding| {
            if (std.mem.eql(u8, binding.name, binding_name)) return true;
        }
        return false;
    }

    fn parseModuleBindingCallExpr(self: *Parser) ParseError!ast.Expr {
        const binding_name = try self.expectIdent();
        const binding = self.findModuleBinding(binding_name) orelse return error.UnsupportedZeroPageModule;
        try self.expect(.period);
        const method_name = try self.expectIdent();
        if (std.mem.eql(u8, method_name, "load") or std.mem.eql(u8, method_name, "acquire") or std.mem.eql(u8, method_name, "loadGraph") or std.mem.eql(u8, method_name, "acquireGraph") or std.mem.eql(u8, method_name, "isLoaded")) {
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            if (std.mem.eql(u8, method_name, "load")) return .{ .module_load_dependency = .{ .id = binding.module_id, .from_binding = true } };
            if (std.mem.eql(u8, method_name, "acquire")) return .{ .module_acquire_dependency = .{ .id = binding.module_id, .from_binding = true } };
            if (std.mem.eql(u8, method_name, "loadGraph")) return .{ .module_load_dependency_graph = .{ .id = binding.module_id, .from_binding = true } };
            if (std.mem.eql(u8, method_name, "acquireGraph")) return .{ .module_acquire_dependency_graph = .{ .id = binding.module_id, .from_binding = true } };
            return .{ .module_is_loaded = .{ .id = binding.module_id } };
        }
        if (std.mem.eql(u8, method_name, "loadFromDisk")) {
            try self.expect(.l_paren);
            const filename = try self.parseString();
            try self.expect(.r_paren);
            return .{ .module_disk_load = .{ .id = binding.module_id, .filename = filename, .from_binding = true } };
        }
        if (std.mem.eql(u8, method_name, "unload")) return error.UnsupportedZeroPageModule;
        if (binding.findMethod(method_name) == null) return error.UnknownZeroPageModuleExport;
        try self.expect(.l_paren);
        var args: std.ArrayList(ast.Expr) = .empty;
        errdefer {
            for (args.items) |arg| ast.freeExpr(self.allocator, arg);
            args.deinit(self.allocator);
        }
        while (!self.peek(.r_paren)) {
            const arg = try self.parseExpr();
            args.append(self.allocator, arg) catch |err| {
                ast.freeExpr(self.allocator, arg);
                return err;
            };
            if (!self.eat(.comma)) break;
        }
        try self.expect(.r_paren);
        return .{ .module_call = .{ .id = binding.module_id, .export_name = method_name, .args = try args.toOwnedSlice(self.allocator) } };
    }

    fn parseModuleBindingStmt(self: *Parser, binding_name: []const u8) ParseError!ast.Stmt {
        const binding = self.findModuleBinding(binding_name) orelse return error.UnsupportedZeroPageModule;
        try self.expect(.period);
        const method_name = try self.expectIdent();
        if (std.mem.eql(u8, method_name, "load")) {
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return .{ .discard = .{ .module_load_dependency = .{ .id = binding.module_id, .from_binding = true } } };
        }
        if (std.mem.eql(u8, method_name, "acquire")) {
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return .{ .discard = .{ .module_acquire_dependency = .{ .id = binding.module_id, .from_binding = true } } };
        }
        if (std.mem.eql(u8, method_name, "loadGraph")) {
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return .{ .discard = .{ .module_load_dependency_graph = .{ .id = binding.module_id, .from_binding = true } } };
        }
        if (std.mem.eql(u8, method_name, "acquireGraph")) {
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return .{ .discard = .{ .module_acquire_dependency_graph = .{ .id = binding.module_id, .from_binding = true } } };
        }
        if (std.mem.eql(u8, method_name, "loadFromDisk")) {
            try self.expect(.l_paren);
            const filename = try self.parseString();
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return .{ .discard = .{ .module_disk_load = .{ .id = binding.module_id, .filename = filename, .from_binding = true } } };
        }
        if (std.mem.eql(u8, method_name, "isLoaded")) {
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            return .{ .discard = .{ .module_is_loaded = .{ .id = binding.module_id } } };
        }
        if (std.mem.eql(u8, method_name, "unload") or std.mem.eql(u8, method_name, "release") or std.mem.eql(u8, method_name, "releaseGraph")) {
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            try self.expect(.semicolon);
            if (std.mem.eql(u8, method_name, "releaseGraph")) return .{ .module_release_dependency_graph = .{ .id = binding.module_id, .from_binding = true } };
            if (std.mem.eql(u8, method_name, "release")) return .{ .module_release_dependency = .{ .id = binding.module_id, .from_binding = true } };
            return .{ .module_unload_dependency = .{ .id = binding.module_id, .from_binding = true } };
        }
        return error.UnsupportedZeroPageModule;
    }

    fn findModuleBinding(self: *Parser, name: []const u8) ?ast.ModuleBinding {
        const bindings = self.parsed_module_bindings orelse return null;
        for (bindings.items) |binding| {
            if (std.mem.eql(u8, binding.name, name)) return binding;
        }
        return null;
    }

    fn parseAddressOfTarget(self: *Parser) ParseError!ast.AddressOf {
        const first = try self.expectIdent();
        var name = first;
        var owned = false;
        if (self.peek(.period) and self.peekNext(.star)) return error.UnsupportedPointerTarget;
        if (self.peek(.period)) {
            const path = try self.parseDottedPathName(first);
            name = path.name;
            owned = path.owned;
        }
        var index: ?u16 = null;
        if (self.eat(.l_bracket)) {
            if (!self.peek(.number)) {
                if (owned) self.allocator.free(name);
                return error.UnsupportedPointerTarget;
            }
            index = try self.parseU16();
            try self.expect(.r_bracket);
        }
        return .{ .name = name, .name_owned = owned, .index = index };
    }

    fn parseBuiltinExpr(self: *Parser) ParseError!ast.Expr {
        try self.expect(.at);
        const name = try self.expectIdent();
        try self.expect(.l_paren);
        if (std.mem.eql(u8, name, "sizeOf")) {
            const ty = try self.parseType();
            try self.expect(.r_paren);
            return .{ .size_of = ty };
        }
        if (std.mem.eql(u8, name, "alignOf")) {
            const ty = try self.parseType();
            try self.expect(.r_paren);
            return .{ .align_of = ty };
        }
        if (std.mem.eql(u8, name, "offsetOf")) {
            const ty = try self.parseType();
            try self.expect(.comma);
            const field_path = try self.parseString();
            try self.expect(.r_paren);
            return .{ .offset_of = .{ .ty = ty, .field_path = field_path } };
        }
        if (std.mem.eql(u8, name, "as")) {
            const ty = try self.parseType();
            try self.expect(.comma);
            const child = try self.allocator.create(ast.Expr);
            errdefer self.allocator.destroy(child);
            child.* = try self.parseExpr();
            errdefer ast.freeExpr(self.allocator, child.*);
            try self.expect(.r_paren);
            return .{ .as_cast = .{ .ty = ty, .expr = child } };
        }
        const child = try self.allocator.create(ast.Expr);
        errdefer self.allocator.destroy(child);
        child.* = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, child.*);
        try self.expect(.r_paren);
        if (std.mem.eql(u8, name, "ptrFromInt")) return .{ .ptr_from_int = child };
        if (std.mem.eql(u8, name, "intFromPtr")) return .{ .int_from_ptr = child };
        return error.UnsupportedStatement;
    }

    fn parseIfExpr(self: *Parser) ParseError!ast.Expr {
        try self.expect(.keyword_if);
        try self.expect(.l_paren);
        const condition = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, condition);
        try self.expect(.r_paren);

        const condition_node = try self.allocator.create(ast.Expr);
        condition_node.* = condition;
        errdefer {
            ast.freeExpr(self.allocator, condition_node.*);
            self.allocator.destroy(condition_node);
        }

        const payload_name = try self.parseOptionalPayloadCapture();
        const then_expr = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, then_expr);
        const then_node = try self.allocator.create(ast.Expr);
        then_node.* = then_expr;
        errdefer {
            ast.freeExpr(self.allocator, then_node.*);
            self.allocator.destroy(then_node);
        }

        try self.expect(.keyword_else);
        const else_expr = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, else_expr);
        const else_node = try self.allocator.create(ast.Expr);
        else_node.* = else_expr;

        return .{ .if_expr = .{
            .condition = condition_node,
            .payload_name = payload_name,
            .then_expr = then_node,
            .else_expr = else_node,
        } };
    }

    fn parseSwitchExpr(self: *Parser) ParseError!ast.Expr {
        const operand = try self.parseSwitchOperandStart();
        errdefer ast.freeExpr(self.allocator, operand);
        const operand_node = try self.allocator.create(ast.Expr);
        operand_node.* = operand;
        errdefer {
            ast.freeExpr(self.allocator, operand_node.*);
            self.allocator.destroy(operand_node);
        }

        var prongs: std.ArrayList(ast.SwitchExprProng) = .empty;
        errdefer {
            for (prongs.items) |prong| {
                if (prong.selectors.len != 0) self.allocator.free(prong.selectors);
                ast.freeExpr(self.allocator, prong.value);
            }
            prongs.deinit(self.allocator);
        }
        while (!self.peek(.r_brace)) {
            const selectors = try self.parseSwitchSelectors();
            errdefer if (selectors.len != 0) self.allocator.free(selectors);
            try self.expectSwitchArrow();
            const payload_name = try self.parseOptionalPayloadCapture();
            const value = try self.parseExpr();
            errdefer ast.freeExpr(self.allocator, value);
            try prongs.append(self.allocator, .{ .selectors = selectors, .payload_name = payload_name, .value = value });
            _ = self.eat(.comma);
        }
        try self.expect(.r_brace);
        return .{ .switch_expr = .{ .operand = operand_node, .prongs = try prongs.toOwnedSlice(self.allocator) } };
    }

    fn parseSwitchOperandStart(self: *Parser) ParseError!ast.Expr {
        try self.expect(.keyword_switch);
        try self.expect(.l_paren);
        const operand = try self.parseExpr();
        try self.expect(.r_paren);
        try self.expect(.l_brace);
        return operand;
    }

    fn parseSwitchSelectors(self: *Parser) ParseError![]ast.SwitchSelector {
        var selectors: std.ArrayList(ast.SwitchSelector) = .empty;
        errdefer selectors.deinit(self.allocator);
        if (self.eat(.keyword_else)) {
            try selectors.append(self.allocator, .else_prong);
            return try selectors.toOwnedSlice(self.allocator);
        }
        while (true) {
            const first = try self.parseSwitchScalarSelector();
            if (self.eat(.period_period_period)) {
                const last = try self.parseSwitchScalarSelector();
                try selectors.append(self.allocator, .{ .range = .{ .first = first, .last = last } });
            } else {
                try selectors.append(self.allocator, .{ .scalar = first });
            }
            if (!self.eat(.comma)) break;
            if (self.peek(.equal)) break;
        }
        return try selectors.toOwnedSlice(self.allocator);
    }

    fn parseSwitchScalarSelector(self: *Parser) ParseError!ast.Value {
        if (self.peek(.number)) return .{ .int = try self.parseU16() };
        if (self.eat(.keyword_true)) return .{ .bool = true };
        if (self.eat(.keyword_false)) return .{ .bool = false };
        if (self.peek(.identifier) and std.mem.eql(u8, self.text(self.tokens[self.index]), "null")) {
            _ = try self.expectIdent();
            return .null;
        }
        if (self.peek(.char_literal)) return .{ .char = try self.parseChar() };
        if (self.isC64KeyConstant()) return .{ .int = try self.parseC64KeyConstant() };
        if (self.isC64PetsciiControl()) return .{ .int = try self.parseC64PetsciiControl() };
        if (self.eat(.period)) return .{ .enum_literal = .{ .enum_name = null, .tag = try self.expectIdent() } };
        if (self.peek(.identifier) and self.peekNext(.period)) {
            const enum_name = try self.expectIdent();
            try self.expect(.period);
            return .{ .enum_literal = .{ .enum_name = enum_name, .tag = try self.expectIdent() } };
        }
        return error.UnsupportedSwitchSelector;
    }

    fn expectSwitchArrow(self: *Parser) ParseError!void {
        try self.expect(.equal);
        try self.expect(.angle_right);
    }

    fn parseBlockExpr(self: *Parser) ParseError!ast.Expr {
        const label = try self.expectIdent();
        try self.expect(.colon);
        const body = try self.parseBlock();
        return .{ .block_expr = .{ .label = label, .body = body } };
    }

    fn parseArrayIndexExpr(self: *Parser) ParseError!ast.Expr {
        try self.expect(.l_bracket);
        const index = try self.parseExpr();
        try self.expect(.r_bracket);
        return index;
    }

    fn parseArrayLiteral(self: *Parser) ParseError!ast.ArrayLiteral {
        var ty: ?ast.ArrayType = null;
        if (self.eat(.l_bracket)) {
            var inferred_len = false;
            var len: u16 = 0;
            if (self.peek(.identifier) and std.mem.eql(u8, self.text(self.tokens[self.index]), "_")) {
                _ = try self.expectIdent();
                inferred_len = true;
            } else {
                len = try self.parseComptimeU16();
            }
            if (self.eat(.colon)) return error.UnsupportedArrayType;
            try self.expect(.r_bracket);
            const elem = try self.parseArrayElemType();
            ty = .{ .len = len, .elem = elem };
            if (!inferred_len) try validateArrayStorageSize(self, ty.?);
        } else {
            try self.expect(.period);
        }
        try self.expect(.l_brace);
        var values: std.ArrayList(ast.Expr) = .empty;
        errdefer {
            for (values.items) |value| ast.freeExpr(self.allocator, value);
            values.deinit(self.allocator);
        }
        while (!self.peek(.r_brace)) {
            const value = try self.parseExpr();
            try values.append(self.allocator, value);
            if (!self.eat(.comma)) break;
        }
        try self.expect(.r_brace);
        const owned_values = try values.toOwnedSlice(self.allocator);
        if (ty) |*array_ty| {
            if (array_ty.len == 0) array_ty.len = std.math.cast(u16, owned_values.len) orelse return error.UnsupportedArraySize;
            if (array_ty.len != owned_values.len) return error.UnsupportedArrayLiteral;
            try validateArrayStorageSize(self, array_ty.*);
        }
        return .{ .ty = ty, .values = owned_values };
    }

    fn isAnonymousStructLiteralStart(self: *Parser) bool {
        return self.peek(.period) and
            self.peekNext(.l_brace) and
            self.peekAhead(2, .period) and
            self.peekAhead(3, .identifier) and
            self.peekAhead(4, .equal);
    }

    fn parseAnonymousStructLiteral(self: *Parser) ParseError!ast.StructLiteral {
        try self.expect(.period);
        try self.expect(.l_brace);
        return try self.parseStructLiteralBody("");
    }

    fn parseStructLiteral(self: *Parser) ParseError!ast.StructLiteral {
        const type_name = try self.expectIdent();
        try self.expect(.l_brace);
        return try self.parseStructLiteralBody(type_name);
    }

    fn parseStructLiteralBody(self: *Parser, type_name: []const u8) ParseError!ast.StructLiteral {
        var fields: std.ArrayList(ast.StructFieldInit) = .empty;
        errdefer fields.deinit(self.allocator);
        while (!self.peek(.r_brace)) {
            try self.expect(.period);
            const field_name = try self.expectIdent();
            try self.expect(.equal);
            const value: ast.Expr = if (self.eat(.l_brace)) blk: {
                try self.expect(.r_brace);
                break :blk .{ .value = .{ .int = 0 } };
            } else try self.parseExpr();
            try fields.append(self.allocator, .{ .name = field_name, .value = value });
            _ = self.eat(.comma);
        }
        try self.expect(.r_brace);
        return .{ .type_name = type_name, .fields = try fields.toOwnedSlice(self.allocator) };
    }

    fn resolveArrayLiteralType(self: *Parser, explicit_ty: ?ast.Type, literal: ast.ArrayLiteral) ParseError!ast.ArrayType {
        if (explicit_ty) |ty| {
            if (ty != .array) return error.UnsupportedArrayType;
            return ty.array;
        }
        if (literal.ty) |ty| return ty;
        _ = self;
        return error.UnsupportedArrayLiteral;
    }

    fn validateArrayLiteral(self: *Parser, array_ty: ast.ArrayType, literal: ast.ArrayLiteral) ParseError!void {
        _ = self;
        if (array_ty.len != literal.values.len) return error.UnsupportedArrayLiteral;
    }

    fn comparisonOp(self: *Parser) ?Token.Tag {
        const tag = self.tokens[self.index].tag;
        return switch (tag) {
            .equal_equal, .bang_equal, .angle_left, .angle_left_equal, .angle_right, .angle_right_equal => tag,
            else => null,
        };
    }

    fn parseStringExpr(self: *Parser) ParseError!ast.StringExpr {
        var parts: std.ArrayList(ast.StringPart) = .empty;
        errdefer {
            for (parts.items) |part| switch (part) {
                .literal => |bytes| if (bytes.len != 0) self.allocator.free(bytes),
                .ident => {},
            };
            parts.deinit(self.allocator);
        }

        try parts.append(self.allocator, try self.parseStringPart());
        while (self.eat(.plus_plus)) {
            try parts.append(self.allocator, try self.parseStringPart());
        }
        return .{ .parts = try parts.toOwnedSlice(self.allocator) };
    }

    fn parseStringPart(self: *Parser) ParseError!ast.StringPart {
        if (self.peek(.string_literal)) {
            const bytes = try self.parseStringBytes(.petscii);
            errdefer if (bytes.len != 0) self.allocator.free(bytes);
            if (bytes.len > 255) return error.Overflow;
            return .{ .literal = bytes };
        }
        if (self.isC64StringContext()) {
            const bytes = try self.parseC64StringContext();
            errdefer if (bytes.len != 0) self.allocator.free(bytes);
            if (bytes.len > 255) return error.Overflow;
            return .{ .literal = bytes };
        }
        if (self.isC64PetsciiControl()) {
            const byte = try self.parseC64PetsciiControl();
            const bytes = try self.allocator.dupe(u8, &.{byte});
            errdefer self.allocator.free(bytes);
            return .{ .literal = bytes };
        }
        return .{ .ident = try self.expectIdent() };
    }

    fn appendEncodedStringLiteral(self: *Parser, bytes_list: *std.ArrayList(u8)) ParseError!void {
        const bytes = try self.parseStringBytes(.petscii);
        defer if (bytes.len != 0) self.allocator.free(bytes);
        try bytes_list.appendSlice(self.allocator, bytes);
        if (bytes_list.items.len > 255) return error.Overflow;
    }

    fn appendCompileTimeStringPart(self: *Parser, bytes_list: *std.ArrayList(u8), known_strings: []const ast.StringConstant) ParseError!void {
        if (self.peek(.string_literal)) return try self.appendEncodedStringLiteral(bytes_list);
        if (self.isC64StringContext()) {
            const bytes = try self.parseC64StringContext();
            defer if (bytes.len != 0) self.allocator.free(bytes);
            try bytes_list.appendSlice(self.allocator, bytes);
            if (bytes_list.items.len > 255) return error.Overflow;
            return;
        }
        if (self.isC64PetsciiControl()) {
            try bytes_list.append(self.allocator, try self.parseC64PetsciiControl());
            if (bytes_list.items.len > 255) return error.Overflow;
            return;
        }
        const name = try self.expectIdent();
        for (known_strings) |constant| {
            if (std.mem.eql(u8, constant.name, name)) {
                try bytes_list.appendSlice(self.allocator, constant.bytes);
                if (bytes_list.items.len > 255) return error.Overflow;
                return;
            }
        }
        return error.UnsupportedStringConcat;
    }

    fn parseC64StringContext(self: *Parser) ParseError![]u8 {
        _ = try self.expectIdent();
        try self.expect(.period);
        _ = try self.expectIdent();
        try self.expect(.period);
        const mode_name = try self.expectIdent();
        const encoding: petscii.Encoding = if (std.mem.eql(u8, mode_name, "ascii"))
            .ascii
        else if (std.mem.eql(u8, mode_name, "petscii"))
            .petscii
        else
            return error.UnsupportedBuiltin;
        try self.expect(.l_paren);
        const bytes = try self.parseStringBytes(encoding);
        errdefer if (bytes.len != 0) self.allocator.free(bytes);
        try self.expect(.r_paren);
        return bytes;
    }

    fn parseC64PetsciiControl(self: *Parser) ParseError!u8 {
        _ = try self.expectIdent();
        try self.expect(.period);
        _ = try self.expectIdent();
        try self.expect(.period);
        const name = try self.expectIdent();
        return petscii.control(name) orelse error.UnsupportedBuiltin;
    }

    fn parseStringBytes(self: *Parser, encoding: petscii.Encoding) ParseError![]u8 {
        const token = try self.expectToken(.string_literal);
        if (self.source[token.start] == '\\') {
            return try self.encodeMultilineString(token, encoding);
        }
        return try petscii.encodeLiteralAs(self.allocator, self.source[token.start + 1 .. token.end - 1], encoding);
    }

    fn encodeMultilineString(self: *Parser, token: Token, encoding: petscii.Encoding) ParseError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var line_start = token.start;
        var first_line = true;
        while (line_start < token.end) {
            var cursor = line_start;
            while (cursor < token.end and (self.source[cursor] == ' ' or self.source[cursor] == '\t')) : (cursor += 1) {}
            if (cursor + 1 < token.end and self.source[cursor] == '/' and self.source[cursor + 1] == '/') {
                while (cursor < token.end and self.source[cursor] != '\n') : (cursor += 1) {}
                if (cursor >= token.end) break;
                line_start = cursor + 1;
                continue;
            }
            if (!(cursor + 1 < token.end and self.source[cursor] == '\\' and self.source[cursor + 1] == '\\')) return error.UnsupportedStringEscape;
            cursor += 2;
            const content_start = cursor;
            while (cursor < token.end and self.source[cursor] != '\n') : (cursor += 1) {}
            if (!first_line) try out.append(self.allocator, if (encoding == .ascii) 0x0a else 0x0d);
            const bytes = try petscii.encodeLiteralAs(self.allocator, self.source[content_start..cursor], encoding);
            defer if (bytes.len != 0) self.allocator.free(bytes);
            try out.appendSlice(self.allocator, bytes);
            first_line = false;
            if (cursor >= token.end) break;
            line_start = cursor + 1;
        }

        return try out.toOwnedSlice(self.allocator);
    }

    fn parseCallTarget(self: *Parser) ParseError![]const u8 {
        const first = try self.expectToken(.identifier);
        if (self.peek(.period)) return try self.parseDottedTarget(first);
        return self.text(first);
    }

    fn parseDottedTarget(self: *Parser, first: Token) ParseError![]const u8 {
        try self.expect(.period);
        const second = try self.expectToken(.identifier);
        return self.source[first.start..second.end];
    }

    fn parseCallAfterTarget(self: *Parser, target: []const u8) ParseError!ast.CallExpr {
        try self.expect(.l_paren);
        var args: std.ArrayList(ast.Expr) = .empty;
        errdefer {
            for (args.items) |arg| ast.freeExpr(self.allocator, arg);
            args.deinit(self.allocator);
        }
        while (!self.peek(.r_paren)) {
            const arg = try self.parseExpr();
            args.append(self.allocator, arg) catch |err| {
                ast.freeExpr(self.allocator, arg);
                return err;
            };
            if (!self.eat(.comma)) break;
        }
        try self.expect(.r_paren);
        return .{ .target = target, .args = try args.toOwnedSlice(self.allocator) };
    }

    fn parseValue(self: *Parser) ParseError!ast.Value {
        if (self.peek(.number)) return .{ .int = try self.parseU16() };
        if (self.eat(.keyword_true)) return .{ .bool = true };
        if (self.eat(.keyword_false)) return .{ .bool = false };
        if (self.peek(.char_literal)) return .{ .char = try self.parseChar() };
        if (self.isC64KeyConstant()) return .{ .int = try self.parseC64KeyConstant() };
        if (self.eat(.period)) return .{ .enum_literal = .{ .enum_name = null, .tag = try self.expectIdent() } };

        const first = try self.expectIdent();
        if (std.mem.eql(u8, first, "null")) return .null;
        if (self.eat(.period)) {
            const second = try self.expectIdent();
            if (self.eat(.period)) {
                var joined = std.ArrayList(u8).empty;
                errdefer joined.deinit(self.allocator);
                try joined.appendSlice(self.allocator, first);
                try joined.append(self.allocator, '_');
                try joined.appendSlice(self.allocator, second);
                var last = try self.expectIdent();
                while (self.eat(.period)) {
                    try joined.append(self.allocator, '_');
                    try joined.appendSlice(self.allocator, last);
                    last = try self.expectIdent();
                }
                const base = try joined.toOwnedSlice(self.allocator);
                return .{ .field = .{ .base = base, .base_owned = true, .field = last } };
            }
            return .{ .field = .{ .base = first, .field = second } };
        }
        return .{ .ident = first };
    }

    fn parseU16(self: *Parser) ParseError!u16 {
        const token = try self.expectToken(.number);
        const literal = self.text(token);
        if (std.mem.startsWith(u8, literal, "0x") or std.mem.startsWith(u8, literal, "0X")) {
            return std.fmt.parseInt(u16, literal[2..], 16);
        }
        return std.fmt.parseInt(u16, literal, 10);
    }

    fn parseU32(self: *Parser) ParseError!u32 {
        const token = try self.expectToken(.number);
        const literal = self.text(token);
        if (std.mem.startsWith(u8, literal, "0x") or std.mem.startsWith(u8, literal, "0X")) {
            return std.fmt.parseInt(u32, literal[2..], 16);
        }
        return std.fmt.parseInt(u32, literal, 10);
    }

    fn parseComptimeU16(self: *Parser) ParseError!u16 {
        const value = try self.parseComptimeAddSub();
        return std.math.cast(u16, value) orelse error.Overflow;
    }

    fn parseComptimeAddSub(self: *Parser) ParseError!u32 {
        var value = try self.parseComptimeMul();
        while (self.peek(.plus) or self.peek(.minus)) {
            const tag = self.tokens[self.index].tag;
            self.index += 1;
            const rhs = try self.parseComptimeMul();
            value = switch (tag) {
                .plus => value + rhs,
                .minus => if (value >= rhs) value - rhs else return error.Overflow,
                else => unreachable,
            };
            if (value > 65535) return error.Overflow;
        }
        return value;
    }

    fn parseComptimeMul(self: *Parser) ParseError!u32 {
        var value = try self.parseComptimePrimary();
        while (self.eat(.star)) {
            const rhs = try self.parseComptimePrimary();
            value *= rhs;
            if (value > 65535) return error.Overflow;
        }
        return value;
    }

    fn parseComptimePrimary(self: *Parser) ParseError!u32 {
        if (self.eat(.l_paren)) {
            const value = try self.parseComptimeAddSub();
            try self.expect(.r_paren);
            return value;
        }
        if (self.peek(.number)) return try self.parseU16();
        if (self.peek(.at)) return try self.parseLayoutBuiltinValue();
        return error.UnsupportedArraySize;
    }

    fn parseLayoutBuiltinValue(self: *Parser) ParseError!u32 {
        try self.expect(.at);
        const name = try self.expectIdent();
        try self.expect(.l_paren);
        if (std.mem.eql(u8, name, "sizeOf")) {
            const ty = try self.parseType();
            try self.expect(.r_paren);
            return try self.typeStorageBytes(ty);
        }
        if (std.mem.eql(u8, name, "alignOf")) {
            const ty = try self.parseType();
            try self.expect(.r_paren);
            _ = try self.typeStorageBytes(ty);
            return 1;
        }
        if (std.mem.eql(u8, name, "offsetOf")) {
            const ty = try self.parseType();
            try self.expect(.comma);
            const field_path = try self.parseString();
            try self.expect(.r_paren);
            return try self.offsetOf(ty, field_path);
        }
        return error.UnsupportedStatement;
    }

    fn typeStorageBytes(self: *Parser, ty: ast.Type) ParseError!u16 {
        return switch (ty) {
            .void => 0,
            .bool, .u8, .i8 => 1,
            .u16, .i16, .usize, .pointer => 2,
            .far_bytes, .far_view => 5,
            .near_view => 2,
            .optional => |optional| if (optional.child == .pointer) 2 else 1 + try self.optionalPayloadBytes(optional.child),
            .array => |array_ty| blk: {
                const bytes = @as(u32, array_ty.len) * try self.arrayElemStorageBytes(array_ty.elem);
                if (bytes > 65535) return error.Overflow;
                break :blk @intCast(bytes);
            },
            .custom => |name| if (try self.findTypeDecl(name)) |decl| switch (decl) {
                .@"enum" => 1,
                .@"struct" => try self.structStorageBytes(decl.@"struct"),
                .@"union" => try self.unionStorageBytes(decl.@"union"),
            } else error.UnsupportedStruct,
        };
    }

    fn optionalPayloadBytes(self: *Parser, child: ast.OptionalChildType) ParseError!u16 {
        return switch (child) {
            .scalar => |scalar| switch (scalar) {
                .u16, .i16, .usize => 2,
                else => 1,
            },
            .pointer => 2,
            .far_bytes => 5,
            .near_view => 2,
            .custom => |name| if (try self.findTypeDecl(name)) |decl| switch (decl) {
                .@"enum" => 1,
                else => error.UnsupportedOptional,
            } else error.UnsupportedOptional,
        };
    }

    fn arrayElemStorageBytes(self: *Parser, elem: ast.ArrayElemType) ParseError!u16 {
        return switch (elem) {
            .scalar => |scalar| switch (scalar) {
                .u16, .i16, .usize => 2,
                else => 1,
            },
            .custom => |name| if (try self.findTypeDecl(name)) |decl| switch (decl) {
                .@"enum" => 1,
                .@"struct" => try self.structStorageBytes(decl.@"struct"),
                else => error.UnsupportedArrayType,
            } else error.UnsupportedArrayType,
        };
    }

    fn structStorageBytes(self: *Parser, decl: ast.StructDecl) ParseError!u16 {
        var total: u32 = 0;
        for (decl.fields) |field| total += try self.typeStorageBytes(field.ty);
        if (total > 65535) return error.Overflow;
        return @intCast(total);
    }

    fn unionStorageBytes(self: *Parser, decl: ast.UnionDecl) ParseError!u16 {
        var payload: u16 = 0;
        for (decl.fields) |field| {
            const bytes: u16 = if (field.ty) |ty| try self.typeStorageBytes(ty) else 0;
            if (bytes > payload) payload = bytes;
        }
        return 1 + payload;
    }

    fn offsetOf(self: *Parser, ty: ast.Type, field_path: []const u8) ParseError!u16 {
        if (ty != .custom) return error.UnsupportedStruct;
        const decl = (try self.findTypeDecl(ty.custom)) orelse return error.UnsupportedStruct;
        if (decl != .@"struct") return error.UnsupportedStruct;
        return try self.offsetOfStruct(decl.@"struct", field_path);
    }

    const FieldPathSplit = struct { head: []const u8, tail: []const u8 };

    fn splitFieldPath(field_path: []const u8) FieldPathSplit {
        if (std.mem.indexOfScalar(u8, field_path, '.')) |dot| {
            return .{ .head = field_path[0..dot], .tail = field_path[dot + 1 ..] };
        }
        return .{ .head = field_path, .tail = "" };
    }

    fn offsetOfStruct(self: *Parser, decl: ast.StructDecl, field_path: []const u8) ParseError!u16 {
        const split = splitFieldPath(field_path);
        var offset: u16 = 0;
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, split.head)) {
                if (split.tail.len == 0) return offset;
                if (field.ty != .custom) return error.UnsupportedStruct;
                const child = (try self.findTypeDecl(field.ty.custom)) orelse return error.UnsupportedStruct;
                if (child != .@"struct") return error.UnsupportedStruct;
                return offset + try self.offsetOfStruct(child.@"struct", split.tail);
            }
            offset += try self.typeStorageBytes(field.ty);
        }
        return error.UnsupportedStruct;
    }

    fn findTypeDecl(self: *Parser, name: []const u8) ParseError!?ast.TypeDecl {
        const list = self.parsed_type_decls orelse return null;
        for (list.items) |decl| {
            if (std.mem.eql(u8, decl.name(), name)) return decl;
        }
        return null;
    }

    fn parseString(self: *Parser) ParseError![]const u8 {
        const token = try self.expectToken(.string_literal);
        return self.source[token.start + 1 .. token.end - 1];
    }

    fn parseChar(self: *Parser) ParseError!u8 {
        const token = try self.expectToken(.char_literal);
        const literal_text = self.source[token.start + 1 .. token.end - 1];
        if (literal_text.len != 1) return error.UnsupportedCharLiteral;
        return literal_text[0];
    }

    fn expectIdent(self: *Parser) ParseError![]const u8 {
        const token = try self.expectToken(.identifier);
        return self.text(token);
    }

    fn expect(self: *Parser, tag: Token.Tag) ParseError!void {
        _ = try self.expectToken(tag);
    }

    fn expectToken(self: *Parser, tag: Token.Tag) ParseError!Token {
        if (!self.peek(tag)) return error.UnexpectedToken;
        const token = self.tokens[self.index];
        self.index += 1;
        return token;
    }

    fn eat(self: *Parser, tag: Token.Tag) bool {
        if (!self.peek(tag)) return false;
        self.index += 1;
        return true;
    }

    fn eatWord(self: *Parser, word: []const u8) bool {
        if (!self.peekAheadText(0, word)) return false;
        self.index += 1;
        return true;
    }

    fn expectWord(self: *Parser, word: []const u8) ParseError!void {
        if (!self.eatWord(word)) return error.InvalidMachineDeclaration;
    }

    fn peek(self: *Parser, tag: Token.Tag) bool {
        return self.tokens[self.index].tag == tag;
    }

    fn peekNext(self: *Parser, tag: Token.Tag) bool {
        return self.peekAhead(1, tag);
    }

    fn peekAhead(self: *Parser, offset: usize, tag: Token.Tag) bool {
        return self.index + offset < self.tokens.len and self.tokens[self.index + offset].tag == tag;
    }

    fn peekAheadText(self: *Parser, offset: usize, expected: []const u8) bool {
        if (self.index + offset >= self.tokens.len) return false;
        return std.mem.eql(u8, self.text(self.tokens[self.index + offset]), expected);
    }

    fn peekStringConcatStart(self: *Parser) bool {
        return self.peek(.identifier) and self.peekNext(.plus_plus);
    }

    fn isTopLevelStringExprStart(self: *Parser, known_strings: []const ast.StringConstant) bool {
        return self.isTopLevelStringExprStartAt(0, known_strings);
    }

    fn isTopLevelStringExprStartAt(self: *Parser, offset: usize, known_strings: []const ast.StringConstant) bool {
        if (self.index + offset >= self.tokens.len) return false;
        const saved = self.index;
        self.index += offset;
        defer self.index = saved;
        if (self.peek(.string_literal) or self.isC64StringContext() or self.isC64PetsciiControl()) return true;
        if (!self.peek(.identifier)) return false;
        if (self.peekNext(.plus_plus)) return true;
        const name = self.text(self.tokens[self.index]);
        for (known_strings) |constant| {
            if (std.mem.eql(u8, constant.name, name)) return true;
        }
        return false;
    }

    fn isC64StringContext(self: *Parser) bool {
        return self.peekAheadText(0, "c64") and
            self.peekAhead(1, .period) and
            self.peekAheadText(2, "string") and
            self.peekAhead(3, .period) and
            (self.peekAheadText(4, "petscii") or self.peekAheadText(4, "ascii")) and
            self.peekAhead(5, .l_paren);
    }

    fn isC64PetsciiControl(self: *Parser) bool {
        return self.peekAheadText(0, "c64") and
            self.peekAhead(1, .period) and
            self.peekAheadText(2, "petscii") and
            self.peekAhead(3, .period) and
            self.index + 4 < self.tokens.len and
            (self.tokens[self.index + 4].tag == .identifier or self.tokens[self.index + 4].tag == .keyword_return);
    }

    fn isC64KeyConstant(self: *Parser) bool {
        return self.peekAheadText(0, "c64") and
            self.peekAhead(1, .period) and
            self.peekAheadText(2, "key") and
            self.peekAhead(3, .period) and
            self.peekAhead(4, .identifier);
    }

    fn parseC64KeyConstant(self: *Parser) ParseError!u8 {
        _ = try self.expectIdent();
        try self.expect(.period);
        _ = try self.expectIdent();
        try self.expect(.period);
        const name = try self.expectIdent();
        return petscii.key(name) orelse error.UnsupportedBuiltin;
    }

    fn isC64KeyboardCall(self: *Parser) bool {
        return self.peekAheadText(0, "c64") and
            self.peekAhead(1, .period) and
            self.peekAheadText(2, "keyboard") and
            self.peekAhead(3, .period) and
            (self.peekAheadText(4, "readPetscii") or self.peekAheadText(4, "waitPetscii")) and
            self.peekAhead(5, .l_paren);
    }

    fn isArrayLiteralStart(self: *Parser) bool {
        return self.isArrayLiteralStartAt(0);
    }

    fn isArrayLiteralStartAt(self: *Parser, offset: usize) bool {
        return self.peekAhead(offset, .l_bracket) or (self.peekAhead(offset, .period) and self.peekAhead(offset + 1, .l_brace));
    }

    fn parseC64KeyboardExpr(self: *Parser) ParseError!ast.Expr {
        _ = try self.expectIdent();
        try self.expect(.period);
        _ = try self.expectIdent();
        try self.expect(.period);
        const member = try self.expectIdent();
        try self.expect(.l_paren);
        try self.expect(.r_paren);
        if (std.mem.eql(u8, member, "readPetscii")) return .c64_read_petscii;
        if (std.mem.eql(u8, member, "waitPetscii")) return .c64_wait_petscii;
        return error.UnsupportedBuiltin;
    }

    fn isZeroPageReuExpr(self: *Parser) bool {
        return self.peekAheadText(0, "ZeroPage") and
            self.peekAhead(1, .period) and
            self.peekAheadText(2, "reu") and
            self.peekAhead(3, .period) and
            (self.peekAheadText(4, "present") or self.peekAheadText(4, "compare") or self.peekAheadText(4, "heap") or self.peekAheadText(4, "view")) and
            self.peekAhead(5, .l_paren);
    }

    fn isZeroPageHeapExpr(self: *Parser) bool {
        return self.peekAheadText(0, "ZeroPage") and
            self.peekAhead(1, .period) and
            self.peekAheadText(2, "heap") and
            self.peekAhead(3, .l_paren);
    }

    fn isZPMDoduleExpr(self: *Parser) bool {
        return self.peekAheadText(0, "ZeroPage") and
            self.peekAhead(1, .period) and
            self.peekAheadText(2, "module") and
            self.peekAhead(3, .period) and
            (self.peekAheadText(4, "load") or self.peekAheadText(4, "loadFromDisk") or self.peekAheadText(4, "loadDependency") or self.peekAheadText(4, "acquireDependency") or self.peekAheadText(4, "loadDependencyGraph") or self.peekAheadText(4, "acquireDependencyGraph") or self.peekAheadText(4, "isLoaded") or self.peekAheadText(4, "call")) and
            self.peekAhead(5, .l_paren);
    }

    fn isFarViewMaterializeExpr(self: *Parser) bool {
        return self.peek(.identifier) and
            self.peekNext(.period) and
            (self.peekAheadText(2, "materialize") or self.peekAheadText(2, "materializeRange")) and
            self.peekAhead(3, .l_paren);
    }

    fn parseFarViewMaterializeExpr(self: *Parser) ParseError!ast.Expr {
        const view_name = try self.expectIdent();
        try self.expect(.period);
        const member = try self.expectIdent();
        try self.expect(.l_paren);
        const heap_name = if (self.peek(.identifier)) blk: {
            const name = try self.expectIdent();
            if (self.namedHeapIsFar(name) != false) return error.UnsupportedHeapName;
            break :blk name;
        } else try self.parseHeapNameLiteral();
        if (std.mem.eql(u8, member, "materialize")) {
            try self.expect(.r_paren);
            return .{ .far_view_materialize = .{ .view_name = view_name, .heap_name = heap_name } };
        }
        if (!std.mem.eql(u8, member, "materializeRange")) return error.UnsupportedHeapFunction;
        try self.expect(.comma);
        const start = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, start);
        try self.expect(.comma);
        const count = try self.parseU16();
        if (count == 0 or count > 255) return error.UnsupportedArraySize;
        try self.expect(.r_paren);
        const start_node = try self.allocator.create(ast.Expr);
        start_node.* = start;
        return .{ .far_view_materialize_range = .{ .view_name = view_name, .heap_name = heap_name, .start = start_node, .count = count } };
    }

    fn parseZeroPageReuExpr(self: *Parser) ParseError!ast.Expr {
        _ = try self.expectIdent();
        try self.expect(.period);
        _ = try self.expectIdent();
        try self.expect(.period);
        const member = try self.expectIdent();
        if (std.mem.eql(u8, member, "present")) {
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            return .reu_present;
        }
        if (std.mem.eql(u8, member, "compare")) return .{ .reu_compare = try self.parseReuCompareArgs() };
        if (std.mem.eql(u8, member, "heap")) return try self.parseZeroPageReuHeapExpr();
        if (std.mem.eql(u8, member, "view")) return try self.parseZeroPageReuViewExpr();
        return error.UnsupportedBuiltin;
    }

    fn parseZeroPageReuViewExpr(self: *Parser) ParseError!ast.Expr {
        try self.expect(.l_paren);
        const type_name = try self.expectIdent();
        try self.expect(.comma);
        const far = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, far);
        try self.expect(.comma);
        const count = try self.parseU16();
        if (count == 0 or count > 255) return error.UnsupportedArraySize;
        try self.expect(.r_paren);

        const far_node = try self.allocator.create(ast.Expr);
        far_node.* = far;
        return .{ .reu_view = .{ .type_name = type_name, .far = far_node, .count = count } };
    }

    fn parseZeroPageReuHeapExpr(self: *Parser) ParseError!ast.Expr {
        try self.expect(.l_paren);
        const heap_name = try self.parseHeapNameLiteral();
        try self.expect(.r_paren);
        try self.expect(.period);
        return self.parseHeapAllocation(heap_name, true);
    }

    fn parseZeroPageHeapExpr(self: *Parser) ParseError!ast.Expr {
        _ = try self.expectIdent();
        try self.expect(.period);
        _ = try self.expectIdent();
        try self.expect(.l_paren);
        const heap_name = try self.parseHeapNameLiteral();
        try self.expect(.r_paren);
        try self.expect(.period);
        return self.parseHeapAllocation(heap_name, false);
    }

    fn namedHeapIsFar(self: *Parser, name: []const u8) ?bool {
        for (self.machine_memory.heaps) |heap| {
            if (std.mem.eql(u8, heap.name, name)) return false;
        }
        for (self.machine_memory.reu.heaps) |heap| {
            if (std.mem.eql(u8, heap.name, name)) return true;
        }
        return null;
    }

    fn parseHeapAllocation(self: *Parser, heap_name: []const u8, far: bool) ParseError!ast.Expr {
        const member = try self.expectIdent();
        if (!std.mem.eql(u8, member, "allocBytes")) return error.UnsupportedHeapFunction;
        try self.expect(.l_paren);
        const len = try self.parseExpr();
        errdefer ast.freeExpr(self.allocator, len);
        try self.validateHeapLengthExpr(len);
        try self.expect(.r_paren);
        const len_node = try self.allocator.create(ast.Expr);
        len_node.* = len;
        return if (far) .{ .reu_heap_alloc = .{ .name = heap_name, .len = len_node } } else .{ .heap_alloc = .{ .name = heap_name, .len = len_node } };
    }

    fn parseZPMDoduleExpr(self: *Parser) ParseError!ast.Expr {
        _ = try self.expectIdent();
        try self.expect(.period);
        _ = try self.expectIdent();
        try self.expect(.period);
        const member = try self.expectIdent();
        const kind: enum { load, load_from_disk, load_dependency, acquire_dependency, load_dependency_graph, acquire_dependency_graph, is_loaded, call } = if (std.mem.eql(u8, member, "load"))
            .load
        else if (std.mem.eql(u8, member, "loadFromDisk"))
            .load_from_disk
        else if (std.mem.eql(u8, member, "loadDependency"))
            .load_dependency
        else if (std.mem.eql(u8, member, "acquireDependency"))
            .acquire_dependency
        else if (std.mem.eql(u8, member, "loadDependencyGraph"))
            .load_dependency_graph
        else if (std.mem.eql(u8, member, "acquireDependencyGraph"))
            .acquire_dependency_graph
        else if (std.mem.eql(u8, member, "isLoaded"))
            .is_loaded
        else if (std.mem.eql(u8, member, "call"))
            .call
        else
            return error.UnsupportedZeroPageModule;
        try self.expect(.l_paren);
        if (!self.peek(.string_literal)) return error.UnsupportedZeroPageModule;
        const id = try self.parseString();
        if (kind == .call) {
            try self.expect(.comma);
            if (!self.peek(.string_literal)) return error.UnsupportedZeroPageModule;
            const export_name = try self.parseString();
            try self.expect(.comma);
            const args = try self.parseAnonymousTupleExprs();
            try self.expect(.r_paren);
            return .{ .module_call = .{ .id = id, .export_name = export_name, .args = args } };
        }
        if (kind == .load_from_disk) {
            try self.expect(.comma);
            if (!self.peek(.string_literal)) return error.UnsupportedZeroPageModule;
            const filename = try self.parseString();
            try self.expect(.r_paren);
            return .{ .module_disk_load = .{ .id = id, .filename = filename } };
        }
        try self.expect(.r_paren);
        return switch (kind) {
            .load => .{ .module_load = .{ .id = id } },
            .load_from_disk => unreachable,
            .load_dependency => .{ .module_load_dependency = .{ .id = id } },
            .acquire_dependency => .{ .module_acquire_dependency = .{ .id = id } },
            .load_dependency_graph => .{ .module_load_dependency_graph = .{ .id = id } },
            .acquire_dependency_graph => .{ .module_acquire_dependency_graph = .{ .id = id } },
            .is_loaded => .{ .module_is_loaded = .{ .id = id } },
            .call => unreachable,
        };
    }

    fn parseAnonymousTupleExprs(self: *Parser) ParseError![]ast.Expr {
        try self.expect(.period);
        try self.expect(.l_brace);
        var args: std.ArrayList(ast.Expr) = .empty;
        errdefer {
            for (args.items) |arg| ast.freeExpr(self.allocator, arg);
            args.deinit(self.allocator);
        }
        while (!self.peek(.r_brace)) {
            const arg = try self.parseExpr();
            args.append(self.allocator, arg) catch |err| {
                ast.freeExpr(self.allocator, arg);
                return err;
            };
            if (!self.eat(.comma)) break;
        }
        try self.expect(.r_brace);
        return try args.toOwnedSlice(self.allocator);
    }

    fn parseZPMDoduleStmt(self: *Parser, member: []const u8) ParseError!ast.Stmt {
        const is_unload = std.mem.eql(u8, member, "unload");
        const is_unload_dependency = std.mem.eql(u8, member, "unloadDependency");
        const is_release_dependency = std.mem.eql(u8, member, "releaseDependency");
        const is_release_dependency_graph = std.mem.eql(u8, member, "releaseDependencyGraph");
        if (!is_unload and !is_unload_dependency and !is_release_dependency and !is_release_dependency_graph) return error.UnsupportedZeroPageModule;
        try self.expect(.l_paren);
        if (!self.peek(.string_literal)) return error.UnsupportedZeroPageModule;
        const id = try self.parseString();
        try self.expect(.r_paren);
        try self.expect(.semicolon);
        if (is_release_dependency_graph) return .{ .module_release_dependency_graph = .{ .id = id } };
        if (is_release_dependency) return .{ .module_release_dependency = .{ .id = id } };
        if (is_unload_dependency) return .{ .module_unload_dependency = .{ .id = id } };
        return .{ .module_unload = .{ .id = id } };
    }

    fn parseHeapNameLiteral(self: *Parser) ParseError![]const u8 {
        if (!self.peek(.string_literal)) return error.UnsupportedHeapName;
        return try self.parseString();
    }

    fn isStringBufferInit(self: *Parser) bool {
        return self.peekAheadText(1, "c64") and
            self.peekAhead(2, .period) and
            self.peekAheadText(3, "string") and
            self.peekAhead(4, .period) and
            self.peekAheadText(5, "buffer");
    }

    fn nextForId(self: *Parser) usize {
        const id = self.for_id;
        self.for_id += 1;
        return id;
    }

    fn text(self: *Parser, token: Token) []const u8 {
        return self.source[token.start..token.end];
    }
};

fn validateZeroPageStackZeroPage(zp: ast.StackZeroPageOptions) !void {
    if (zp.sp > 0xfe or zp.fp > 0xfe) return error.InvalidZeroPageStackZeroPage;
    if (zpPairsOverlap(zp.sp, zp.fp)) return error.InvalidZeroPageStackZeroPage;
    if (zpPairOverlapsReserved(zp.sp) or zpPairOverlapsReserved(zp.fp)) return error.InvalidZeroPageStackZeroPage;
}

fn zpPairsOverlap(a: u8, b: u8) bool {
    return zpRangesOverlap(a, @as(u16, a) + 1, b, @as(u16, b) + 1);
}

fn zpPairOverlapsReserved(start: u8) bool {
    return zpRangesOverlap(start, @as(u16, start) + 1, 0xfb, 0xfe);
}

fn zpRangesOverlap(a_start: u8, a_end: u16, b_start: u8, b_end: u16) bool {
    return @as(u16, a_start) <= b_end and @as(u16, b_start) <= a_end;
}

fn valueAsU8(value: ast.Value) ParseError!u8 {
    return switch (value) {
        .int => |n| std.math.cast(u8, n) orelse error.Overflow,
        else => error.UnexpectedToken,
    };
}

fn isArrayType(ty: ast.Type) bool {
    return switch (ty) {
        .array => true,
        else => false,
    };
}

fn arrayElemSize(elem: ast.ArrayElemType) u16 {
    return switch (elem) {
        .scalar => |scalar| switch (scalar) {
            .u16, .i16, .usize => 2,
            else => 1,
        },
        .custom => 1,
    };
}

fn validateArrayStorageSize(parser: *Parser, ty: ast.ArrayType) ParseError!void {
    const elem_size = try parser.arrayElemStorageBytes(ty.elem);
    if (@as(u32, ty.len) * elem_size > 255) return error.UnsupportedArraySize;
}

fn inlineAsmPlaceholderIndex(name: []const u8) ?usize {
    const prefix = "zeropage_inline_asm_";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    if (name.len == prefix.len) return null;
    return std.fmt.parseInt(usize, name[prefix.len..], 10) catch null;
}

test "inline asm preparser extracts blocks and rewrites placeholders" {
    const prepared = try extractInlineAsmBlocks(std.testing.allocator,
        \\const c64 = @import("c64");
        \\export fn main() void {
        \\    asm {
        \\        lda #$00
        \\        sta $d020
        \\    }
        \\    asm {
        \\loop:
        \\        inc $d021
        \\        bne loop
        \\    }
        \\}
    );
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), prepared.blocks.len);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "zeropage_inline_asm_0();") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "zeropage_inline_asm_1();") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.blocks[0].source, "sta $d020") != null);
    try std.testing.expectEqual(@as(usize, 3), prepared.blocks[0].line);
}

test "inline asm preparser rejects unterminated block" {
    try std.testing.expectError(error.UnterminatedInlineAsm, extractInlineAsmBlocks(std.testing.allocator,
        \\export fn main() void {
        \\    asm {
        \\        nop
    ));
}

test "inline asm preparser ignores comments and strings" {
    const prepared = try extractInlineAsmBlocks(std.testing.allocator,
        \\export fn main() void {
        \\    // asm {
        \\    c64.console.print("asm {", .{});
        \\}
    );
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), prepared.blocks.len);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "asm {") != null);
}

test "parses top-level string constants as PETSCII without null terminator" {
    const parsed = try parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\const prefix = "hello";
        \\const greeting = prefix ++ ", " ++ "world\n";
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.program.string_constants.len);
    try std.testing.expectEqualStrings("main", parsed.program.string_constants[0].module_owner);
    try std.testing.expectEqualStrings("greeting", parsed.program.string_constants[1].name);
    try std.testing.expectEqualStrings("main", parsed.program.string_constants[1].module_owner);
    try std.testing.expectEqualSlices(u8, &.{ 'H', 'E', 'L', 'L', 'O', ',', ' ', 'W', 'O', 'R', 'L', 'D', 0x0d }, parsed.program.string_constants[1].bytes);
}

test "prefixes imported module rodata and records module owner" {
    const parsed = try parseSourceWithPrefix(std.testing.allocator,
        \\const msg = "module";
        \\const table = [_]u8{ 1, 2, 3 };
        \\export fn show() void {}
    , "mod");
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), parsed.program.string_constants.len);
    try std.testing.expectEqualStrings("mod_msg", parsed.program.string_constants[0].name);
    try std.testing.expectEqualStrings("mod", parsed.program.string_constants[0].module_owner);
    try std.testing.expectEqualSlices(u8, &.{ 'M', 'O', 'D', 'U', 'L', 'E' }, parsed.program.string_constants[0].bytes);
    try std.testing.expectEqual(@as(usize, 1), parsed.program.array_constants.len);
    try std.testing.expectEqualStrings("mod_table", parsed.program.array_constants[0].name);
    try std.testing.expectEqualStrings("mod", parsed.program.array_constants[0].module_owner);
}

test "parses explicit string contexts and PETSCII controls as bytes" {
    const parsed = try parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\const petscii_text = c64.petscii.clear ++ c64.string.petscii("go\x21");
        \\const ascii_text = c64.string.ascii("go\n");
        \\const ret = c64.petscii.return;
        \\const ret_alias = c64.petscii.return_;
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), parsed.program.string_constants.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x93, 'G', 'O', '!' }, parsed.program.string_constants[0].bytes);
    try std.testing.expectEqualSlices(u8, &.{ 'g', 'o', 0x0a }, parsed.program.string_constants[1].bytes);
    try std.testing.expectEqualSlices(u8, &.{0x0d}, parsed.program.string_constants[2].bytes);
    try std.testing.expectEqualSlices(u8, &.{0x0d}, parsed.program.string_constants[3].bytes);
}

test "parses multiline PETSCII string constants as return-joined bytes" {
    const parsed = try parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\const text = c64.string.petscii(
        \\    \\one
        \\    \\two
        \\);
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &.{ 'O', 'N', 'E', 0x0d, 'T', 'W', 'O' }, parsed.program.string_constants[0].bytes);
}

test "parses multiline ASCII string constants as LF-joined bytes" {
    const parsed = try parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\const text = c64.string.ascii(
        \\    \\one
        \\    \\two
        \\);
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &.{ 'o', 'n', 'e', 0x0a, 't', 'w', 'o' }, parsed.program.string_constants[0].bytes);
}

test "parser lowers inline asm placeholder to AST statement" {
    const parsed = try parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\export fn main() void {
        \\    asm {
        \\        lda #$00
        \\        sta $d020
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const main = parsed.program.findFunction("main").?;
    try std.testing.expectEqual(@as(usize, 1), main.body.len);
    switch (main.body[0]) {
        .inline_asm => |block| try std.testing.expect(std.mem.indexOf(u8, block.source, "lda #$00") != null),
        else => return error.TestExpectedInlineAsm,
    }
}

test "parser lowers supported for loop forms" {
    const parsed = try parseSource(std.testing.allocator,
        \\const test6502 = @import("test6502");
        \\const values = [_]u8{ 1, 2 };
        \\export fn main() void {
        \\    for (values) |item| { _ = item; }
        \\    for (values, 0..) |value, index| { _ = value + index; }
        \\    for (0..values.len) |i| { _ = i; }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const main = parsed.program.findFunction("main").?;
    try std.testing.expectEqual(@as(usize, 3), main.body.len);
    switch (main.body[0]) {
        .for_stmt => |for_stmt| {
            try std.testing.expectEqual(@as(usize, 0), for_stmt.id);
            try std.testing.expectEqualStrings("item", for_stmt.item_name.?);
            try std.testing.expect(for_stmt.index_name == null);
        },
        else => return error.TestExpectedForStmt,
    }
    switch (main.body[1]) {
        .for_stmt => |for_stmt| {
            try std.testing.expectEqual(@as(usize, 1), for_stmt.id);
            try std.testing.expectEqualStrings("value", for_stmt.item_name.?);
            try std.testing.expectEqualStrings("index", for_stmt.index_name.?);
        },
        else => return error.TestExpectedForStmt,
    }
    switch (main.body[2]) {
        .for_stmt => |for_stmt| {
            try std.testing.expectEqual(@as(usize, 2), for_stmt.id);
            switch (for_stmt.source) {
                .range => |range| switch (range) {
                    .array_len => |name| try std.testing.expectEqualStrings("values", name),
                    else => return error.TestExpectedForRange,
                },
                else => return error.TestExpectedForRange,
            }
        },
        else => return error.TestExpectedForStmt,
    }
}

test "parser lowers scalar switch statements and expressions" {
    const parsed = try parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\const test6502 = @import("test6502");
        \\export fn main() void {
        \\    var x: u8 = 2;
        \\    switch (x) {
        \\        1, 2...3 => { test6502.hit(1); },
        \\        else => { test6502.hit(2); },
        \\    }
        \\    const y = switch (x) {
        \\        'A' => 1,
        \\        c64.key.return_ => 2,
        \\        else => 3,
        \\    };
        \\    _ = y;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const main = parsed.program.findFunction("main").?;
    try std.testing.expectEqual(@as(usize, 4), main.body.len);
    switch (main.body[1]) {
        .switch_stmt => |switch_stmt| {
            try std.testing.expectEqual(@as(usize, 2), switch_stmt.prongs.len);
            try std.testing.expectEqual(@as(usize, 2), switch_stmt.prongs[0].selectors.len);
            switch (switch_stmt.prongs[0].selectors[1]) {
                .range => |range| {
                    try std.testing.expectEqual(@as(u16, 2), range.first.int);
                    try std.testing.expectEqual(@as(u16, 3), range.last.int);
                },
                else => return error.TestExpectedSwitchRange,
            }
        },
        else => return error.TestExpectedSwitchStmt,
    }
    switch (main.body[2]) {
        .var_decl => |decl| switch (decl.init) {
            .switch_expr => |switch_expr| {
                try std.testing.expectEqual(@as(usize, 3), switch_expr.prongs.len);
                switch (switch_expr.prongs[1].selectors[0]) {
                    .scalar => |value| try std.testing.expectEqual(@as(u16, 13), value.int),
                    else => return error.TestExpectedSwitchSelector,
                }
            },
            else => return error.TestExpectedSwitchExpr,
        },
        else => return error.TestExpectedLocalDecl,
    }
}

test "parser lowers many-item pointer types and indexed access" {
    const parsed = try parseSource(std.testing.allocator,
        \\const test6502 = @import("test6502");
        \\fn peek(ptr: [*]volatile u8, index: u8) u8 {
        \\    return ptr[index];
        \\}
        \\export fn main() void {
        \\    const screen: [*]volatile u8 = @ptrFromInt(0x0400);
        \\    screen[1] = 7;
        \\    test6502.expectEqualU8(1, 7, peek(screen, 1));
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const peek_fn = parsed.program.findFunction("peek").?;
    switch (peek_fn.params[0].ty) {
        .pointer => |ptr| {
            try std.testing.expect(ptr.is_many);
            try std.testing.expect(ptr.is_volatile);
            try std.testing.expectEqual(ast.PointerChildType{ .scalar = .u8 }, ptr.child);
        },
        else => return error.TestExpectedPointer,
    }
    switch (peek_fn.body[0]) {
        .return_expr => |expr| switch (expr) {
            .array_index => |index| try std.testing.expectEqualStrings("ptr", index.name),
            else => return error.TestExpectedArrayIndex,
        },
        else => return error.TestExpectedReturn,
    }
    const main = parsed.program.findFunction("main").?;
    switch (main.body[1]) {
        .array_assign => |assign| try std.testing.expectEqualStrings("screen", assign.name),
        else => return error.TestExpectedArrayAssign,
    }
}

test "parser lowers limited as casts" {
    const parsed = try parseSource(std.testing.allocator,
        \\const test6502 = @import("test6502");
        \\export fn main() void {
        \\    const byte = @as(u8, 3);
        \\    const screen: [*]volatile u8 = @as([*]volatile u8, @ptrFromInt(0x0400));
        \\    test6502.expectEqualU8(1, 3, byte);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const main = parsed.program.findFunction("main").?;
    switch (main.body[0]) {
        .var_decl => |decl| switch (decl.init) {
            .as_cast => |cast| try std.testing.expectEqual(ast.Type.u8, cast.ty),
            else => return error.TestExpectedAsCast,
        },
        else => return error.TestExpectedVarDecl,
    }
    switch (main.body[1]) {
        .var_decl => |decl| switch (decl.init) {
            .as_cast => |cast| switch (cast.ty) {
                .pointer => |ptr| {
                    try std.testing.expect(ptr.is_many);
                    try std.testing.expect(ptr.is_volatile);
                },
                else => return error.TestExpectedPointer,
            },
            else => return error.TestExpectedAsCast,
        },
        else => return error.TestExpectedVarDecl,
    }
}

test "parser lowers enum declarations and flattened composite paths" {
    const parsed = try parseSource(std.testing.allocator,
        \\const test6502 = @import("test6502");
        \\const Cell = enum(u8) { empty = 0, x = 1, o };
        \\const Board = struct { cells: [9]Cell };
        \\const Game = struct { board: Board, history: [9]u8, move_count: u8 };
        \\export fn main() void {
        \\    var game = Game{
        \\        .board = Board{ .cells = [_]Cell{ .empty, .x, .o, .empty, .empty, .empty, .empty, .empty, .empty } },
        \\        .history = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8 },
        \\        .move_count = 0,
        \\    };
        \\    game.board.cells[0] = Cell.x;
        \\    game.move_count = game.history.len;
        \\    test6502.expectEqualU8(1, 1, game.board.cells[0]);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), parsed.program.type_decls.len);
    switch (parsed.program.type_decls[0]) {
        .@"enum" => |decl| {
            try std.testing.expectEqualStrings("Cell", decl.name);
            try std.testing.expectEqual(@as(usize, 3), decl.tags.len);
            try std.testing.expectEqual(@as(u8, 2), decl.tags[2].value);
        },
        else => return error.TestExpectedEnumDecl,
    }
    switch (parsed.program.type_decls[2]) {
        .@"struct" => |decl| {
            try std.testing.expectEqualStrings("Game", decl.name);
            try std.testing.expectEqual(@as(usize, 3), decl.fields.len);
            try std.testing.expectEqualStrings("board", decl.fields[0].name);
        },
        else => return error.TestExpectedStructDecl,
    }
    const main = parsed.program.findFunction("main").?;
    switch (main.body[1]) {
        .array_assign => |assign| try std.testing.expectEqualStrings("game_board_cells", assign.name),
        else => return error.TestExpectedArrayAssign,
    }
    switch (main.body[2]) {
        .assign => |assign| try std.testing.expectEqualStrings("game_move_count", assign.name),
        else => return error.TestExpectedAssign,
    }
}

test "parser lowers fixed arrays of struct field paths" {
    const parsed = try parseSource(std.testing.allocator,
        \\const test6502 = @import("test6502");
        \\const Point = struct { x: u8, y: u8 };
        \\export fn main() void {
        \\    var points: [2]Point = .{ Point{ .x = 1, .y = 2 }, Point{ .x = 3, .y = 4 } };
        \\    points[1].x = points[0].y;
        \\    test6502.expectEqualU8(1, 2, points[1].x);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const main = parsed.program.findFunction("main").?;
    switch (main.body[1]) {
        .array_field_assign => |assign| {
            try std.testing.expectEqualStrings("points", assign.name);
            try std.testing.expectEqualStrings("x", assign.field_path);
        },
        else => return error.TestExpectedArrayAssign,
    }
    switch (main.body[2]) {
        .test6502 => |call| switch (call) {
            .expect_equal_u8 => |expect| switch (expect.actual) {
                .array_field_index => |index| {
                    try std.testing.expectEqualStrings("points", index.name);
                    try std.testing.expectEqualStrings("x", index.field_path);
                },
                else => return error.TestExpectedArrayIndex,
            },
            else => return error.TestExpectedArrayIndex,
        },
        else => return error.TestExpectedTest6502,
    }
}

test "parser lowers struct pointers and auto-deref field paths" {
    const parsed = try parseSource(std.testing.allocator,
        \\const test6502 = @import("test6502");
        \\const Board = struct { cells: [3]u8, count: u8 };
        \\const Game = struct { board: Board, score: u16 };
        \\fn touch(game: *Game, index: u8) void {
        \\    game.board.cells[index] = 7;
        \\    game.board.cells[2] += 1;
        \\    game.score = 0x1234;
        \\}
        \\export fn main() void {
        \\    var game = Game{ .board = Board{ .cells = [_]u8{ 0, 0, 0 }, .count = 0 }, .score = 0 };
        \\    const game_ptr: *Game = &game;
        \\    const board_ptr: *Board = &game.board;
        \\    touch(game_ptr, 1);
        \\    test6502.expectEqualU8(1, 7, game.board.cells[1]);
        \\    test6502.expectEqualU8(2, 1, board_ptr.cells[2]);
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const touch = parsed.program.findFunction("touch").?;
    switch (touch.params[0].ty) {
        .pointer => |ptr| {
            try std.testing.expect(!ptr.is_many);
            try std.testing.expect(!ptr.is_volatile);
            switch (ptr.child) {
                .custom => |name| try std.testing.expectEqualStrings("Game", name),
                else => return error.TestExpectedPointer,
            }
        },
        else => return error.TestExpectedPointer,
    }
    switch (touch.body[0]) {
        .array_assign => |assign| try std.testing.expectEqualStrings("game_board_cells", assign.name),
        else => return error.TestExpectedArrayAssign,
    }
    switch (touch.body[1]) {
        .array_add_assign => |assign| try std.testing.expectEqualStrings("game_board_cells", assign.name),
        else => return error.TestExpectedArrayAssign,
    }
    switch (touch.body[2]) {
        .assign => |assign| try std.testing.expectEqualStrings("game_score", assign.name),
        else => return error.TestExpectedAssign,
    }

    const main = parsed.program.findFunction("main").?;
    switch (main.body[1]) {
        .var_decl => |decl| switch (decl.init) {
            .address_of => |address| try std.testing.expectEqualStrings("game", address.name),
            else => return error.TestExpectedAddressOf,
        },
        else => return error.TestExpectedVarDecl,
    }
    switch (main.body[2]) {
        .var_decl => |decl| switch (decl.init) {
            .address_of => |address| try std.testing.expectEqualStrings("game_board", address.name),
            else => return error.TestExpectedAddressOf,
        },
        else => return error.TestExpectedVarDecl,
    }
}

test "parser lowers layout comptime builtins and arithmetic array lengths" {
    const parsed = try parseSource(std.testing.allocator,
        \\const test6502 = @import("test6502");
        \\const Cell = enum(u8) { empty, x, o };
        \\const Header = struct { tag: u8, word: u16, cell: Cell, ok: bool };
        \\const Nested = struct { a: u8, header: Header, tail: u16 };
        \\export fn main() void {
        \\    var bytes: [@sizeOf(Header) + @alignOf(Header)]u8 = .{ 0, 1, 2, 3, 4, 5 };
        \\    test6502.expectEqualU16(1, 6, bytes.len);
        \\    test6502.expectEqualU16(2, 1, @offsetOf(Header, "word"));
        \\    test6502.expectEqualU16(3, 4, @offsetOf(Header, "ok"));
        \\    test6502.expectEqualU16(4, 2, @offsetOf(Nested, "header.word"));
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const main = parsed.program.findFunction("main").?;
    switch (main.body[0]) {
        .var_decl => |decl| switch (decl.ty.?) {
            .array => |array_ty| try std.testing.expectEqual(@as(u16, 6), array_ty.len),
            else => return error.TestExpectedArray,
        },
        else => return error.TestExpectedVarDecl,
    }
    switch (main.body[2]) {
        .test6502 => |call| switch (call) {
            .expect_equal_u16 => |expect| switch (expect.actual) {
                .offset_of => |offset| try std.testing.expectEqualStrings("word", offset.field_path),
                else => return error.TestExpectedOffsetOf,
            },
            else => return error.TestExpectedOffsetOf,
        },
        else => return error.TestExpectedTest6502,
    }
}

test "parser accepts configurable PRG image metadata" {
    const parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .image = .{
        \\        .format = .prg,
        \\        .load_addr = 0x1000,
        \\        .entry_addr = 0x1010,
        \\        .basic_stub = false,
        \\        .address_limit = 0xc600,
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const image = parsed.program.zeropage_options.image;
    try std.testing.expectEqual(ast.ImageFormat.prg, image.format);
    try std.testing.expectEqual(@as(u16, 0x1000), image.load_addr);
    try std.testing.expectEqual(@as(u16, 0x1010), image.entry_addr);
    try std.testing.expect(!image.basic_stub);
    try std.testing.expectEqual(@as(u32, 0xc600), image.address_limit);
}

test "parser resolves named regions for arenas stack and DLL storage" {
    const parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .memory = .{ .regions = .{
        \\        .stack_ram = .{ .addr = 0x8000, .size = 0x0400 },
        \\        .arena_ram = .{ .addr = 0x9000, .size = 0x0100 },
        \\        .dll_main = .{ .addr = 0xa000, .size = 0x0800, .bank = .ram_under_basic },
        \\        .dll_aux = .{ .addr = 0xe000, .size = 0x0800, .bank = .ram_under_kernal },
        \\        .dll_stage = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .far_arena = .{ .addr = 0x010000, .size = 0x0100, .space = .reu },
        \\        .dll_cache = .{ .addr = 0x030000, .size = 0x2000, .space = .reu },
        \\    } },
        \\    .stack = .{ .region = .stack_ram },
        \\    .heaps = .{ .main = .{ .region = .arena_ram, .kind = .arena } },
        \\    .reu = .{ .heaps = .{ .assets = .{ .region = .far_arena, .kind = .arena } } },
        \\    .modules = .{
        \\        .load_window = .dll_main,
        \\        .extra_load_windows = .{ .aux = .dll_aux },
        \\        .reu_cache = .dll_cache,
        \\        .disk_staging = .dll_stage,
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 7), parsed.program.zeropage_options.memory.regions.len);
    try std.testing.expectEqual(@as(u16, 0x8000), parsed.program.zeropage_options.stack.?.base);
    try std.testing.expectEqual(@as(u16, 0x9000), parsed.program.zeropage_options.heaps[0].addr);
    try std.testing.expectEqual(@as(u32, 0x010000), parsed.program.zeropage_options.reu.heaps[0].addr);
    const modules = parsed.program.zeropage_options.modules.?;
    try std.testing.expectEqual(@as(u16, 0xa000), modules.load_window.addr);
    try std.testing.expectEqual(ast.ModuleWindowBank.ram_under_basic, modules.load_window.bank);
    try std.testing.expectEqual(@as(u16, 0xe000), modules.extra_load_windows[0].window.addr);
    try std.testing.expectEqual(ast.ModuleWindowBank.ram_under_kernal, modules.extra_load_windows[0].window.bank);
    try std.testing.expectEqual(@as(u16, 0xc000), modules.disk_staging.?.addr);
    try std.testing.expectEqual(@as(u32, 0x030000), modules.reu_cache.addr);
}

test "parser records direct and startup-copy memory placements" {
    const parsed = try parseSource(std.testing.allocator,
        \\const table = [_]u8{ 1, 2 };
        \\pub const zeropage_options = .{
        \\    .memory = .{
        \\        .regions = .{
        \\            .visible_code = .{ .addr = 0x2000, .size = 0x0100 },
        \\            .hidden_code = .{ .addr = 0xe000, .size = 0x0100, .bank = .ram_under_kernal },
        \\        },
        \\        .placements = .{
        \\            .fast = .{ .region = .visible_code, .functions = .{ helper } },
        \\            .cold = .{ .region = .hidden_code, .load = .startup_copy, .functions = .{ hidden }, .constants = .{ table } },
        \\        },
        \\    },
        \\};
        \\fn helper() u8 { return 1; }
        \\fn hidden() u8 { return table[0]; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const placements = parsed.program.zeropage_options.memory.placements;
    try std.testing.expectEqual(@as(usize, 2), placements.len);
    try std.testing.expectEqual(ast.MemoryPlacementLoad.direct, placements[0].load);
    try std.testing.expectEqualStrings("helper", placements[0].functions[0]);
    try std.testing.expectEqual(ast.MemoryPlacementLoad.startup_copy, placements[1].load);
    try std.testing.expectEqualStrings("hidden", placements[1].functions[0]);
    try std.testing.expectEqualStrings("table", placements[1].constants[0]);
}

test "parser rejects unknown and address-space-mismatched named regions" {
    try std.testing.expectError(error.UnknownZeroPageMemoryRegion, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{ .heaps = .{ .main = .{ .region = .missing, .kind = .arena } } };
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.InvalidZeroPageMemoryRegion, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .memory = .{ .regions = .{ .far = .{ .addr = 0x010000, .size = 0x100, .space = .reu } } },
        \\    .heaps = .{ .main = .{ .region = .far, .kind = .arena } },
        \\};
        \\export fn main() void {}
    ));
}

test "parser preserves the default BASIC PRG image" {
    const parsed = try parseSource(std.testing.allocator,
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const image = parsed.program.zeropage_options.image;
    try std.testing.expectEqual(@as(u16, 0x0801), image.load_addr);
    try std.testing.expectEqual(@as(u16, 0x080d), image.entry_addr);
    try std.testing.expect(image.basic_stub);
    try std.testing.expectEqual(@as(u32, 0x10000), image.address_limit);
}

test "parser accepts ZeroPage static frame metadata" {
    const parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{
        \\        .default_frame = .static,
        \\        .functions = .{
        \\            .main = .{ .frame = .static },
        \\            .helper = .{ .frame = .static },
        \\        },
        \\    },
        \\};
        \\fn helper() u8 { return 7; }
        \\export fn main() void {
        \\    _ = helper();
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expect(parsed.program.zeropage_options.declared);
    try std.testing.expectEqual(@as(u16, 0xc800), parsed.program.zeropage_options.stack.?.base);
    try std.testing.expectEqual(@as(u16, 0x0400), parsed.program.zeropage_options.stack.?.size);
    try std.testing.expectEqual(@as(u8, 0xf7), parsed.program.zeropage_options.stack.?.zp.sp);
    try std.testing.expectEqual(@as(u8, 0xf9), parsed.program.zeropage_options.stack.?.zp.fp);
    try std.testing.expectEqual(ast.FramePolicy.static, parsed.program.zeropage_options.abi.default_frame);
    try std.testing.expectEqual(@as(usize, 2), parsed.program.zeropage_options.abi.functions.len);
    try std.testing.expectEqualStrings("main", parsed.program.zeropage_options.abi.functions[0].name);
    try std.testing.expectEqual(ast.FramePolicy.static, parsed.program.zeropage_options.abi.functions[0].frame);
}

test "parser accepts ZeroPage software stack zero-page metadata" {
    const parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400, .zp = .{ .sp = 0xf3, .fp = 0xf5 } },
        \\    .abi = .{ .functions = .{ .main = .{ .frame = .stack } } },
        \\};
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0xf3), parsed.program.zeropage_options.stack.?.zp.sp);
    try std.testing.expectEqual(@as(u8, 0xf5), parsed.program.zeropage_options.stack.?.zp.fp);
}

test "parser accepts ZeroPage module loader window metadata" {
    const parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xa000, .size = 0x1000, .bank = .ram_under_basic },
        \\        .reu_cache = .{ .addr = 0x020000, .size = 0x010000 },
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const modules = parsed.program.zeropage_options.modules.?;
    try std.testing.expectEqual(@as(u16, 0xa000), modules.load_window.addr);
    try std.testing.expectEqual(@as(u16, 0x1000), modules.load_window.size);
    try std.testing.expectEqual(ast.ModuleWindowBank.ram_under_basic, modules.load_window.bank);
    try std.testing.expectEqual(@as(u32, 0x020000), modules.reu_cache.addr);
    try std.testing.expectEqual(@as(u32, 0x010000), modules.reu_cache.size);
}

test "parser accepts ZeroPage KERNAL-bank module window metadata" {
    const parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xe000, .size = 0x1000, .bank = .ram_under_kernal },
        \\        .reu_cache = .{ .addr = 0x020000, .size = 0x010000 },
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const modules = parsed.program.zeropage_options.modules.?;
    try std.testing.expectEqual(@as(u16, 0xe000), modules.load_window.addr);
    try std.testing.expectEqual(@as(u16, 0x1000), modules.load_window.size);
    try std.testing.expectEqual(ast.ModuleWindowBank.ram_under_kernal, modules.load_window.bank);
}

test "parser accepts ZeroPage module registry plan metadata" {
    const parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .registry = .{ .capacity = 3 },
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const registry = parsed.program.zeropage_options.modules.?.registry.?;
    try std.testing.expectEqual(@as(u8, 3), registry.capacity);
}

test "parser rejects malformed ZeroPage module registry metadata" {
    try std.testing.expectError(error.UnsupportedZeroPageOptions, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .registry = .{},
        \\    },
        \\};
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.UnsupportedZeroPageOptions, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .registry = .{ .capacity = 0 },
        \\    },
        \\};
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.UnsupportedZeroPageOptions, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .registry = .{ .capacity = 3, .rows = 3 },
        \\    },
        \\};
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.Overflow, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .registry = .{ .capacity = 256 },
        \\    },
        \\};
        \\export fn main() void {}
    ));
}

test "parser accepts ZeroPage module disk manifest metadata" {
    const parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .registry = .{ .capacity = 3 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{
        \\                .math_core = "mathcore",
        \\                .pathing = "pathing",
        \\            },
        \\        },
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const manifest = parsed.program.zeropage_options.modules.?.disk_manifest.?;
    try std.testing.expectEqualStrings("enemyrt", manifest.current);
    try std.testing.expectEqual(@as(usize, 2), manifest.deps.len);
    try std.testing.expectEqualStrings("math_core", manifest.deps[0].id);
    try std.testing.expectEqualStrings("mathcore", manifest.deps[0].filename);
    try std.testing.expectEqualStrings("pathing", manifest.deps[1].id);
    try std.testing.expectEqualStrings("pathing", manifest.deps[1].filename);
}

test "parser accepts ZeroPage module dependency graph metadata" {
    const parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .dependency_graph = .{
        \\            .math_core = .{ .deps = .{ .fixed_math } },
        \\            .pathing = .{ .deps = .{} },
        \\            .fixed_math = .{ .deps = .{} },
        \\        },
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const graph = parsed.program.zeropage_options.modules.?.dependency_graph.?;
    try std.testing.expectEqual(@as(usize, 3), graph.nodes.len);
    try std.testing.expectEqualStrings("math_core", graph.nodes[0].id);
    try std.testing.expectEqualStrings("fixed_math", graph.nodes[0].deps[0]);
    try std.testing.expectEqualStrings("pathing", graph.nodes[1].id);
}

test "parser rejects malformed ZeroPage module dependency graph metadata" {
    try std.testing.expectError(error.UnsupportedZeroPageOptions, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .dependency_graph = .{ .math_core = .{} },
        \\    },
        \\};
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.UnsupportedZeroPageOptions, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .dependency_graph = .{ .math_core = .{ .deps = .{}, .extra = .{} } },
        \\    },
        \\};
        \\export fn main() void {}
    ));
}

test "parser rejects malformed ZeroPage module disk manifest metadata" {
    try std.testing.expectError(error.UnsupportedZeroPageOptions, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .registry = .{ .capacity = 3 },
        \\        .disk_manifest = .{ .deps = .{} },
        \\    },
        \\};
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.UnsupportedZeroPageOptions, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .registry = .{ .capacity = 3 },
        \\        .disk_manifest = .{ .current = "enemyrt", .files = .{} },
        \\    },
        \\};
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.UnsupportedZeroPageOptions, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .registry = .{ .capacity = 3 },
        \\        .disk_manifest = .{ .current = "enemyrt", .deps = .{ .math_core = "mathcore", .math_core = "math2" } },
        \\    },
        \\};
        \\export fn main() void {}
    ));
}

test "parser lowers typed module dependency binding calls to module calls" {
    const parsed = try parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\const MathCore = ZeroPage.module.import(.math_core, .{
        \\    .add = fn (u8) u8,
        \\    .wide = fn (u16) u16,
        \\});
        \\export fn main() void {
        \\    const maybe = MathCore.add(3);
        \\    _ = maybe;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), parsed.program.module_bindings.len);
    const binding = parsed.program.module_bindings[0];
    try std.testing.expectEqualStrings("MathCore", binding.name);
    try std.testing.expectEqualStrings("math_core", binding.module_id);
    try std.testing.expectEqual(@as(usize, 2), binding.methods.len);
    try std.testing.expectEqualStrings("add", binding.methods[0].name);
    try std.testing.expectEqual(ast.Type.u8, binding.methods[0].params[0]);
    try std.testing.expectEqual(ast.Type.u8, binding.methods[0].return_type);

    const main = parsed.program.findFunction("main").?;
    switch (main.body[0]) {
        .var_decl => |decl| switch (decl.init) {
            .module_call => |call| {
                try std.testing.expectEqualStrings("math_core", call.id);
                try std.testing.expectEqualStrings("add", call.export_name);
                try std.testing.expectEqual(@as(usize, 1), call.args.len);
            },
            else => return error.TestExpectedModuleCall,
        },
        else => return error.TestExpectedLocalDecl,
    }
}

test "parser lowers typed dependency lifecycle binding methods" {
    const parsed = try parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\const MathCore = ZeroPage.module.import(.math_core, .{
        \\    .add = fn (u8) u8,
        \\});
        \\export fn main() void {
        \\    const loaded = MathCore.load();
        \\    const acquired = MathCore.acquire();
        \\    const graph = MathCore.loadGraph();
        \\    const owned_graph = MathCore.acquireGraph();
        \\    const present = MathCore.isLoaded();
        \\    MathCore.releaseGraph();
        \\    MathCore.release();
        \\    MathCore.unload();
        \\    _ = loaded;
        \\    _ = acquired;
        \\    _ = graph;
        \\    _ = owned_graph;
        \\    _ = present;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const main = parsed.program.findFunction("main").?;
    try std.testing.expectEqual(@as(usize, 13), main.body.len);
    switch (main.body[0]) {
        .var_decl => |decl| switch (decl.init) {
            .module_load_dependency => |load| try std.testing.expectEqualStrings("math_core", load.id),
            else => return error.TestExpectedModuleLoadDependency,
        },
        else => return error.TestExpectedLocalDecl,
    }
    switch (main.body[1]) {
        .var_decl => |decl| switch (decl.init) {
            .module_acquire_dependency => |load| try std.testing.expectEqualStrings("math_core", load.id),
            else => return error.TestExpectedModuleAcquireDependency,
        },
        else => return error.TestExpectedLocalDecl,
    }
    switch (main.body[2]) {
        .var_decl => |decl| switch (decl.init) {
            .module_load_dependency_graph => |load| try std.testing.expectEqualStrings("math_core", load.id),
            else => return error.TestExpectedModuleLoadDependencyGraph,
        },
        else => return error.TestExpectedLocalDecl,
    }
    switch (main.body[3]) {
        .var_decl => |decl| switch (decl.init) {
            .module_acquire_dependency_graph => |load| try std.testing.expectEqualStrings("math_core", load.id),
            else => return error.TestExpectedModuleAcquireDependencyGraph,
        },
        else => return error.TestExpectedLocalDecl,
    }
    switch (main.body[4]) {
        .var_decl => |decl| switch (decl.init) {
            .module_is_loaded => |load| try std.testing.expectEqualStrings("math_core", load.id),
            else => return error.TestExpectedModuleIsLoaded,
        },
        else => return error.TestExpectedLocalDecl,
    }
    switch (main.body[5]) {
        .module_release_dependency_graph => |release| try std.testing.expectEqualStrings("math_core", release.id),
        else => return error.TestExpectedModuleReleaseDependencyGraph,
    }
    switch (main.body[6]) {
        .module_release_dependency => |release| try std.testing.expectEqualStrings("math_core", release.id),
        else => return error.TestExpectedModuleReleaseDependency,
    }
    switch (main.body[7]) {
        .module_unload_dependency => |unload| try std.testing.expectEqualStrings("math_core", unload.id),
        else => return error.TestExpectedModuleUnloadDependency,
    }
}

test "parser lowers dependency graph load and acquire expressions" {
    const parsed = try parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\export fn main() void {
        \\    const ok = ZeroPage.module.loadDependencyGraph("math_core");
        \\    const owned = ZeroPage.module.acquireDependencyGraph("math_core");
        \\    ZeroPage.module.releaseDependencyGraph("math_core");
        \\    _ = ok;
        \\    _ = owned;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const main = parsed.program.findFunction("main").?;
    switch (main.body[0]) {
        .var_decl => |decl| switch (decl.init) {
            .module_load_dependency_graph => |load| try std.testing.expectEqualStrings("math_core", load.id),
            else => return error.TestExpectedModuleLoadDependencyGraph,
        },
        else => return error.TestExpectedLocalDecl,
    }
    switch (main.body[1]) {
        .var_decl => |decl| switch (decl.init) {
            .module_acquire_dependency_graph => |load| try std.testing.expectEqualStrings("math_core", load.id),
            else => return error.TestExpectedModuleAcquireDependencyGraph,
        },
        else => return error.TestExpectedLocalDecl,
    }
    switch (main.body[2]) {
        .module_release_dependency_graph => |release| try std.testing.expectEqualStrings("math_core", release.id),
        else => return error.TestExpectedModuleReleaseDependencyGraph,
    }
}

test "parser lowers typed current binding disk lifecycle method" {
    const parsed = try parseSource(std.testing.allocator,
        \\const ZeroPage = @import("ZeroPage");
        \\const EnemyRuntime = ZeroPage.module.import(.enemy_runtime, .{
        \\    .border = fn (u8) u8,
        \\});
        \\export fn main() void {
        \\    const loaded = EnemyRuntime.loadFromDisk("enemyrt");
        \\    _ = loaded;
        \\}
    );
    defer parsed.deinit(std.testing.allocator);

    const main = parsed.program.findFunction("main").?;
    try std.testing.expectEqual(@as(usize, 2), main.body.len);
    switch (main.body[0]) {
        .var_decl => |decl| switch (decl.init) {
            .module_disk_load => |load| {
                try std.testing.expectEqualStrings("enemy_runtime", load.id);
                try std.testing.expectEqualStrings("enemyrt", load.filename);
                try std.testing.expect(load.from_binding);
            },
            else => return error.TestExpectedModuleDiskLoad,
        },
        else => return error.TestExpectedLocalDecl,
    }
}

test "parser accepts current module load policy metadata" {
    const parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .policy = .{
        \\            .current = .{ .mode = .preload, .filename = "enemyrt" },
        \\        },
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const policy = parsed.program.zeropage_options.modules.?.policy.?.current;
    try std.testing.expectEqual(ast.ModuleLoadMode.preload, policy.mode);
    try std.testing.expectEqualStrings("enemyrt", policy.filename.?);
}

test "parser accepts dependency module preload policy metadata" {
    const parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x020000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .policy = .{
        \\            .current = .{ .mode = .manual },
        \\            .deps = .{
        \\                .math_core = .{ .mode = .preload, .graph = true },
        \\                .pathing = .{ .mode = .manual },
        \\                .ai = .{ .mode = .on_demand, .graph = true },
        \\            },
        \\        },
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const policy = parsed.program.zeropage_options.modules.?.policy.?;
    try std.testing.expectEqual(ast.ModuleLoadMode.manual, policy.current.mode);
    try std.testing.expectEqual(@as(usize, 3), policy.deps.len);
    try std.testing.expectEqualStrings("math_core", policy.deps[0].id);
    try std.testing.expectEqual(ast.ModuleLoadMode.preload, policy.deps[0].policy.mode);
    try std.testing.expect(policy.deps[0].policy.graph);
    try std.testing.expectEqualStrings("pathing", policy.deps[1].id);
    try std.testing.expectEqual(ast.ModuleLoadMode.manual, policy.deps[1].policy.mode);
    try std.testing.expectEqualStrings("ai", policy.deps[2].id);
    try std.testing.expectEqual(ast.ModuleLoadMode.on_demand, policy.deps[2].policy.mode);
    try std.testing.expect(policy.deps[2].policy.graph);
}

test "parser accepts current module state snapshot metadata" {
    const parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x020000 },
        \\        .state = .{ .current = .{ .mode = .persist_in_reu, .ranges = .{ .{ .offset = 0x0100, .size = 2 } } } },
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const state = parsed.program.zeropage_options.modules.?.state.?.current;
    try std.testing.expectEqual(ast.ModuleStateMode.persist_in_reu, state.mode);
    try std.testing.expectEqual(@as(usize, 1), state.ranges.len);
    try std.testing.expectEqual(@as(u16, 0x0100), state.ranges[0].offset);
    try std.testing.expectEqual(@as(u16, 2), state.ranges[0].size);
}

test "parser accepts dependency module state snapshot metadata" {
    const parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x040000 },
        \\        .state = .{
        \\            .current = .{ .mode = .discard_on_unload },
        \\            .deps = .{
        \\                .math_core = .{ .mode = .persist_in_reu, .ranges = .{ .{ .offset = 0x0020, .size = 4 } } },
        \\            },
        \\        },
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const state = parsed.program.zeropage_options.modules.?.state.?;
    try std.testing.expectEqual(ast.ModuleStateMode.discard_on_unload, state.current.mode);
    try std.testing.expectEqual(@as(usize, 1), state.deps.len);
    try std.testing.expectEqualStrings("math_core", state.deps[0].id);
    try std.testing.expectEqual(ast.ModuleStateMode.persist_in_reu, state.deps[0].state.mode);
    try std.testing.expectEqual(@as(u16, 0x0020), state.deps[0].state.ranges[0].offset);
    try std.testing.expectEqual(@as(u16, 4), state.deps[0].state.ranges[0].size);
}

test "parser rejects malformed current module state metadata" {
    try std.testing.expectError(error.UnsupportedZeroPageOptions, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x020000 },
        \\        .state = .{ .current = .{ .mode = .persist_in_reu } },
        \\    },
        \\};
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.UnsupportedZeroPageOptions, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x020000 },
        \\        .state = .{ .current = .{ .mode = .discard_on_unload, .ranges = .{ .{ .offset = 1, .size = 1 } } } },
        \\    },
        \\};
        \\export fn main() void {}
    ));
}

test "parser accepts on-demand module load policy metadata" {
    const parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .policy = .{ .current = .{ .mode = .on_demand, .filename = "enemyrt" } },
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const policy = parsed.program.zeropage_options.modules.?.policy.?.current;
    try std.testing.expectEqual(ast.ModuleLoadMode.on_demand, policy.mode);
    try std.testing.expectEqualStrings("enemyrt", policy.filename.?);
}

test "parser rejects load policies without filename and unknown policy mode" {
    try std.testing.expectError(error.UnsupportedZeroPageOptions, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .policy = .{ .current = .{ .mode = .preload } },
        \\    },
        \\};
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.UnsupportedZeroPageOptions, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .policy = .{ .current = .{ .mode = .on_demand } },
        \\    },
        \\};
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.UnsupportedZeroPageOptions, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .policy = .{ .current = .{ .mode = .lazy, .filename = "enemyrt" } },
        \\    },
        \\};
        \\export fn main() void {}
    ));
}

test "parser accepts reserved stack and auto frame policy syntax" {
    const parsed = try parseSource(std.testing.allocator,
        \\const zeropage_options = .{
        \\    .abi = .{
        \\        .default_frame = .stack,
        \\        .functions = .{ .callback = .{ .frame = .auto } },
        \\    },
        \\};
        \\fn callback() void {}
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(ast.FramePolicy.stack, parsed.program.zeropage_options.abi.default_frame);
    try std.testing.expectEqual(ast.FramePolicy.auto, parsed.program.zeropage_options.abi.functions[0].frame);
}

test "parser accepts ZeroPage module metadata" {
    var parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_module = .{
        \\    .id = "enemy_ai",
        \\    .abi = 1,
        \\    .flags = .{},
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math", "path-finding" },
        \\};
        \\fn tick(value: u8) u8 { return value + 1; }
    );
    defer parsed.deinit(std.testing.allocator);

    const module = parsed.program.zeropage_module.?;
    try std.testing.expectEqualStrings("enemy_ai", module.id);
    try std.testing.expectEqual(@as(u16, 1), module.abi);
    try std.testing.expectEqual(@as(usize, 1), module.exports.len);
    try std.testing.expectEqualStrings("tick", module.exports[0].name);
    try std.testing.expectEqualStrings("tick", module.exports[0].function_name);
    try std.testing.expectEqual(@as(usize, 2), module.deps.len);
    try std.testing.expectEqualStrings("math", module.deps[0]);
    try std.testing.expectEqualStrings("path-finding", module.deps[1]);
}

test "parser rejects invalid ZeroPage module metadata" {
    try std.testing.expectError(error.InvalidZeroPageModuleId, parseSource(std.testing.allocator,
        \\pub const zeropage_module = .{ .id = "EnemyAI", .abi = 1, .exports = .{ .tick = tick } };
        \\fn tick(value: u8) u8 { return value; }
    ));
    try std.testing.expectError(error.InvalidZeroPageModuleAbi, parseSource(std.testing.allocator,
        \\pub const zeropage_module = .{ .id = "enemy_ai", .abi = 2, .exports = .{ .tick = tick } };
        \\fn tick(value: u8) u8 { return value; }
    ));
    try std.testing.expectError(error.DuplicateZeroPageModuleExport, parseSource(std.testing.allocator,
        \\pub const zeropage_module = .{ .id = "enemy_ai", .abi = 1, .exports = .{ .tick = tick, .tick = tick2 } };
        \\fn tick(value: u8) u8 { return value; }
        \\fn tick2(value: u8) u8 { return value; }
    ));
    try std.testing.expectError(error.DuplicateZeroPageModuleDependency, parseSource(std.testing.allocator,
        \\pub const zeropage_module = .{ .id = "enemy_ai", .abi = 1, .exports = .{ .tick = tick }, .deps = .{ "math", "math" } };
        \\fn tick(value: u8) u8 { return value; }
    ));
}

test "parser rejects malformed ZeroPage metadata" {
    try std.testing.expectError(error.UnsupportedZeroPageOptions, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{ .heap = .{} };
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.InvalidZeroPageStackRegion, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{ .stack = .{ .base = 0xfff0, .size = 0x20 } };
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.InvalidZeroPageStackZeroPage, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{ .stack = .{ .base = 0xc800, .size = 0x0400, .zp = .{ .sp = 0xfa, .fp = 0xf7 } } };
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.DuplicateZeroPageFunctionOption, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .abi = .{ .functions = .{
        \\        .main = .{ .frame = .static },
        \\        .main = .{ .frame = .static },
        \\    } },
        \\};
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.DuplicateZeroPageOptions, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{ .abi = .{ .default_frame = .static } };
        \\const zeropage_options = .{ .abi = .{ .default_frame = .static } };
        \\export fn main() void {}
    ));
}

test "parser records source-owned zero-page policy ranges and reservations" {
    const parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .zero_page = .{
        \\        .profile = .kernal,
        \\        .allocation = .scratch,
        \\        .ranges = .{ .{ .addr = 0x02, .size = 0x18 }, .{ .addr = 0x40, .size = 0x20 }, .{ .addr = 0xfb, .size = 4 } },
        \\        .reserve = .{ .{ .addr = 0x40, .size = 4 } },
        \\        .restore_basic = false,
        \\        .interrupts = .system,
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);
    const policy = parsed.program.zeropage_options.zero_page;
    try std.testing.expect(policy.declared and policy.ranges_declared);
    try std.testing.expectEqual(zero_page.Profile.kernal, policy.profile);
    try std.testing.expectEqual(@as(usize, 3), policy.ranges.len);
    try std.testing.expectEqual(@as(u16, 0xfb), policy.ranges[2].addr);
    try std.testing.expectEqual(@as(usize, 1), policy.reserve.len);
    try std.testing.expectEqual(@as(u16, 4), policy.reserve[0].size);
    try std.testing.expectEqualStrings("scratch", @tagName(policy.allocation));
    try std.testing.expect(!policy.restore_basic);
}

test "zero-page metadata defaults preserve compatibility and distinguish omitted ranges" {
    const omitted = try parseSource(std.testing.allocator, "export fn main() void {}");
    defer omitted.deinit(std.testing.allocator);
    try std.testing.expect(!omitted.program.zeropage_options.zero_page.declared);
    try std.testing.expectEqualStrings("compatibility", @tagName(omitted.program.zeropage_options.zero_page.profile));
    for ([_][]const u8{
        ".{}",                                                                       ".{ .profile = .basic, .allocation = .scratch }", ".{ .profile = .kernal, .allocation = .scratch }",
        ".{ .profile = .bare, .interrupts = .application, .restore_basic = false }",
    }) |policy| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "pub const zeropage_options = .{{ .zero_page = {s} }}; export fn main() void {{}}", .{policy});
        defer std.testing.allocator.free(source);
        const parsed = try parseSource(std.testing.allocator, source);
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expect(parsed.program.zeropage_options.zero_page.declared);
        try std.testing.expect(!parsed.program.zeropage_options.zero_page.ranges_declared);
    }
}

test "strict zero-page validation sees stack metadata in either field order" {
    const policy = ".zero_page = .{ .profile = .kernal, .ranges = .{ .{ .addr = 0x20, .size = 8 } } }";
    const stack = ".stack = .{ .base = 0xc800, .size = 0x100, .zp = .{ .sp = 0x20, .fp = 0x22 } }";
    for ([_][2][]const u8{ .{ policy, stack }, .{ stack, policy } }) |fields| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "pub const zeropage_options = .{{ {s}, {s} }}; export fn main() void {{}}", .{ fields[0], fields[1] });
        defer std.testing.allocator.free(source);
        const parsed = try parseSource(std.testing.allocator, source);
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0x20), parsed.program.zeropage_options.stack.?.zp.sp);
        try std.testing.expectEqual(@as(u8, 0x22), parsed.program.zeropage_options.stack.?.zp.fp);
    }
}

test "zero-page metadata rejects unknown duplicate and nonliteral settings" {
    for ([_][]const u8{
        ".{ .profile = .unknown }",            ".{ .profile = .kernal, .profile = .basic }",               ".{ .allocation = .hot_scalars }",
        ".{ .interrupts = .disabled }",        ".{ .restore_basic = 1 }",                                  ".{ .unknown = .{} }",
        ".{ .ranges = .{ .{ .addr = 2 } } }",  ".{ .ranges = .{ .{ .addr = 2, .addr = 4, .size = 4 } } }", ".{ .ranges = .{ .{ .addr = 2, .size = 4, .bank = .main } } }",
        ".{ .reserve = .{}, .reserve = .{} }", ".{ .ranges = .{ .{ .addr = address, .size = 4 } } }",
    }) |policy| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "pub const zeropage_options = .{{ .zero_page = {s} }}; export fn main() void {{}}", .{policy});
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.UnsupportedZeroPagePolicy, parseSource(std.testing.allocator, source));
    }
    try std.testing.expectError(error.UnsupportedZeroPagePolicy, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{ .zero_page = .{}, .zero_page = .{} };
        \\export fn main() void {}
    ));
}

test "zero-page policy rejects unsafe ownership ranges reservations and fixed claims" {
    for ([_][]const u8{
        ".{ .profile = .bare }",
        ".{ .profile = .kernal, .ranges = .{} }",
        ".{ .profile = .kernal, .ranges = .{ .{ .addr = 0, .size = 8 } } }",
        ".{ .profile = .kernal, .ranges = .{ .{ .addr = 2, .size = 0 } } }",
        ".{ .profile = .kernal, .ranges = .{ .{ .addr = 0xfe, .size = 4 } } }",
        ".{ .profile = .kernal, .ranges = .{ .{ .addr = 0xff, .size = 1 } } }",
        ".{ .profile = .kernal, .ranges = .{ .{ .addr = 2, .size = 8 }, .{ .addr = 9, .size = 4 } } }",
        ".{ .profile = .kernal, .ranges = .{ .{ .addr = 0x90, .size = 8 } } }",
        ".{ .profile = .basic, .ranges = .{ .{ .addr = 2, .size = 8 } } }",
        ".{ .profile = .kernal, .reserve = .{ .{ .addr = 2, .size = 4 }, .{ .addr = 4, .size = 4 } } }",
        ".{ .profile = .kernal, .ranges = .{ .{ .addr = 2, .size = 1 }, .{ .addr = 4, .size = 1 }, .{ .addr = 0xfb, .size = 2 } } }",
    }) |policy| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "pub const zeropage_options = .{{ .zero_page = {s} }}; export fn main() void {{}}", .{policy});
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.InvalidZeroPagePolicy, parseSource(std.testing.allocator, source));
    }
    try std.testing.expectError(error.InvalidZeroPagePolicy, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .zero_page = .{ .profile = .kernal },
        \\    .stack = .{ .base = 0xc800, .size = 0x100 },
        \\};
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.InvalidZeroPagePolicy, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x100, .zp = .{ .sp = 2, .fp = 4 } },
        \\    .zero_page = .{ .profile = .kernal, .reserve = .{ .{ .addr = 2, .size = 2 } } },
        \\};
        \\export fn main() void {}
    ));
}

test "new zero-page policy remains main-source metadata" {
    try std.testing.expectError(error.UnsupportedImportedZeroPageOptions, parseSourceWithPrefix(std.testing.allocator,
        \\pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scratch } };
        \\fn touch() void {}
    , "imported"));
}

test "strict zero-page policy can relocate compiler pointers around explicit stack pairs" {
    const parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x100, .zp = .{ .sp = 0xfb, .fp = 0xfd } },
        \\    .zero_page = .{
        \\        .profile = .kernal,
        \\        .ranges = .{ .{ .addr = 0x20, .size = 4 }, .{ .addr = 0xfb, .size = 4 } },
        \\    },
        \\};
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0xfb), parsed.program.zeropage_options.stack.?.zp.sp);
    try std.testing.expectEqual(@as(u8, 0xfd), parsed.program.zeropage_options.stack.?.zp.fp);
}

test "parser records scalar allocation with explicit replacement ranges and reservations" {
    const parsed = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .zero_page = .{
        \\        .profile = .kernal,
        \\        .allocation = .scalars,
        \\        .ranges = .{ .{ .addr = 0x20, .size = 0x20 }, .{ .addr = 0xfb, .size = 4 } },
        \\        .reserve = .{ .{ .addr = 0x30, .size = 4 } },
        \\        .restore_basic = true,
        \\    },
        \\};
        \\fn private(value: u16) u16 { return value + 1; }
        \\export fn main() void { _ = private(255); }
    );
    defer parsed.deinit(std.testing.allocator);
    const policy = parsed.program.zeropage_options.zero_page;
    try std.testing.expectEqualStrings("scalars", @tagName(policy.allocation));
    try std.testing.expect(policy.declared and policy.ranges_declared and policy.restore_basic);
    try std.testing.expectEqual(@as(usize, 2), policy.ranges.len);
    try std.testing.expectEqual(@as(u16, 0x20), policy.ranges[0].addr);
    try std.testing.expectEqual(@as(usize, 1), policy.reserve.len);
    try std.testing.expectEqual(@as(u16, 0x30), policy.reserve[0].addr);
    try std.testing.expectEqual(@as(u16, 4), policy.reserve[0].size);
    try std.testing.expectEqualStrings("kernal", @tagName(policy.profile));
    try std.testing.expectEqualStrings("system", @tagName(policy.interrupts));
}

test "scalar policy parsing is stack-field order independent and keeps basic ownership" {
    const policy = ".zero_page = .{ .profile = .kernal, .allocation = .scalars, .ranges = .{ .{ .addr = 0x20, .size = 0x20 }, .{ .addr = 0xfb, .size = 4 } }, .reserve = .{ .{ .addr = 0x30, .size = 4 } } }";
    const stack = ".stack = .{ .base = 0xc800, .size = 0x100, .zp = .{ .sp = 0x20, .fp = 0x22 } }";
    for ([_][2][]const u8{ .{ policy, stack }, .{ stack, policy } }) |fields| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "pub const zeropage_options = .{{ {s}, {s} }}; export fn main() void {{}}", .{ fields[0], fields[1] });
        defer std.testing.allocator.free(source);
        const parsed = try parseSource(std.testing.allocator, source);
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("scalars", @tagName(parsed.program.zeropage_options.zero_page.allocation));
        try std.testing.expectEqual(@as(u8, 0x20), parsed.program.zeropage_options.stack.?.zp.sp);
        try std.testing.expectEqual(@as(u8, 0x22), parsed.program.zeropage_options.stack.?.zp.fp);
    }
    const basic = try parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .zero_page = .{ .profile = .basic, .allocation = .scalars, .ranges = .{ .{ .addr = 0xfb, .size = 4 } } },
        \\};
        \\export fn main() void {}
    );
    defer basic.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("basic", @tagName(basic.program.zeropage_options.zero_page.profile));
    try std.testing.expectEqualStrings("scalars", @tagName(basic.program.zeropage_options.zero_page.allocation));
    try std.testing.expectError(error.InvalidZeroPagePolicy, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{ .zero_page = .{
        \\    .profile = .basic, .allocation = .scalars, .ranges = .{ .{ .addr = 0x20, .size = 8 } },
        \\} };
        \\export fn main() void {}
    ));
    try std.testing.expectError(error.UnsupportedZeroPagePolicy, parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{ .zero_page = .{ .allocation = .scalar } };
        \\export fn main() void {}
    ));
}

fn parseFunctionAppendAllocationProof(allocator: std.mem.Allocator) !void {
    const parsed = try parseSource(allocator, "fn leaf(a: u16, b: u8) u16 { return a; } export fn main() void { _ = leaf(0x8134, 7); }");
    defer parsed.deinit(allocator);
}

test "parsed functions remain owned when the program function list cannot append" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseFunctionAppendAllocationProof, .{});
}

fn parseProgramHandoffAllocationProof(allocator: std.mem.Allocator) !void {
    const source =
        \\const Tag = enum(u8) { first, second };
        \\const Record = struct { value: u16 };
        \\const title = "hello";
        \\const values = [_]u8{ 1, 2, 3 };
        \\fn identity(value: u16) u16 { return value; }
        \\export fn main() void {}
    ;
    for ([_][]const u8{ "", "library" }) |prefix| {
        const parsed = try parseSourceWithPrefix(allocator, source, prefix);
        defer parsed.deinit(allocator);
    }
}

test "program constants types and functions retain ownership through slice handoff OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseProgramHandoffAllocationProof, .{});
}

test "nested if rejection releases conditions and completed branches" {
    try std.testing.expectError(error.UnexpectedToken, parseSource(std.testing.allocator,
        \\export fn main() void {
        \\    const flag: u8 = 1;
        \\    if (flag == 1) {
        \\        const saved: u16 = flag + 255;
        \\    } else if (flag != 0) {
        \\        const child: u16 = flag + 1;
        \\    } else {
        \\        return;
        \\    }
        \\}
    ));
}

fn parseNestedIfAllocationProof(allocator: std.mem.Allocator) !void {
    const parsed = try parseSource(allocator,
        \\fn choose(flag: bool) u8 {
        \\    if (flag) { return 1; }
        \\    else if (flag) { return 2; }
        \\    else { return 3; }
        \\}
        \\export fn main() void {}
    );
    defer parsed.deinit(allocator);
}

test "nested if branches retain ownership through allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseNestedIfAllocationProof, .{});
}

test "function callconv uses existing frame policies and validates the literal" {
    const allocator = std.testing.allocator;
    var parsed = try parseSourceWithPrefix(allocator,
        \\fn worker(x: u8) callconv(.stack) u8 { return x; }
        \\fn quick() callconv(.static) void {}
    , "math");
    defer parsed.deinit(allocator);
    const policies = parsed.program.zeropage_options.abi.functions;
    try std.testing.expectEqual(@as(usize, 2), policies.len);
    try std.testing.expectEqualStrings("math_worker", policies[0].name);
    try std.testing.expectEqual(ast.FramePolicy.stack, policies[0].frame);
    try std.testing.expectEqual(ast.FramePolicy.static, policies[1].frame);
    for ([_][]const u8{
        "fn f() callconv(.c) void {}",
        "fn f() callconv(.auto) void {}",
        "fn f() callconv(if (true) .static else .stack) void {}",
    }) |source| {
        try std.testing.expectError(error.UnsupportedFrameCallconv, parseSource(allocator, source));
    }
    try std.testing.expectError(error.DuplicateZeroPageFunctionOption, parseSource(allocator,
        \\fn worker() callconv(.static) void {}
        \\pub const zeropage_options = .{ .abi = .{ .functions = .{ .worker = .{ .frame = .stack } } } };
    ));
}

test "machine declarations resolve late memory and use existing metadata" {
    var parsed = try parseSource(std.testing.allocator,
        \\const bytes: [2]u8 linksection("cold") = .{ 3, 7 };
        \\fn get(index: u8) linksection("cold") u8 { return bytes[index]; }
        \\export fn main() void { _ = scratch.allocBytes(2); scratch.reset(); }
        \\memory {
        \\    arena scratch in work;
        \\    placement cold in hidden load .startup_copy;
        \\    region work: c64 at 0x9000 size 0x80;
        \\    region hidden: c64 at 0xe000 size 0x100 bank .ram_under_kernal;
        \\    zero_page { profile = .kernal; range at 0x20 size 16; reserve at 0x20 size 2; }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);
    const program = parsed.program;
    try std.testing.expectEqual(@as(u16, 0x9000), program.findHeap("scratch").?.addr);
    try std.testing.expectEqual(ast.MemoryPlacementLoad.startup_copy, program.findFunctionPlacement("get").?.load);
    try std.testing.expectEqualStrings("cold", program.findConstantPlacement("bytes").?.name);
    try std.testing.expectEqual(@as(u16, 0x20), program.zeropage_options.zero_page.ranges[0].addr);
    try std.testing.expectEqual(@as(u16, 2), program.zeropage_options.zero_page.reserve[0].size);
}

test "machine declaration masking preserves Zig syntax validation" {
    try std.testing.expectError(error.ZigSyntaxError, parseSource(std.testing.allocator,
        \\memory { region scratch: c64 at 0x9000 size 0x80; }
        \\export fn main() void { var x: u8 = ; }
    ));
    var parsed = try parseSource(std.testing.allocator,
        \\// memory { missing
        \\const text = "module example abi 1 {";
        \\export fn main() void { var memory: u8 = 1; var region: u8 = memory; }
    );
    defer parsed.deinit(std.testing.allocator);
}

test "module loader declarations map typed aliases to registry ids" {
    var parsed = try parseSource(std.testing.allocator,
        \\extern module Math = math_core { fn add(arg: u8) u8; }
        \\memory {
        \\    region run: c64 at 0xc000 size 0x800;
        \\    region cache: reu at 0x30000 size 0x2000;
        \\    region staging: c64 at 0x9000 size 0x800;
        \\}
        \\module_loader {
        \\    window main in run;
        \\    reu_cache in cache;
        \\    disk_staging in staging;
        \\    capacity = 2;
        \\    current { file = "enemy"; }
        \\    dependency Math { file = "math"; load = .on_demand; persist_in_reu at 0x400 size 2; }
        \\}
        \\module enemy abi 1 { export advance = tick; dependency math_core; }
        \\fn tick(value: u8) callconv(.stack) u8 { return value; }
    );
    defer parsed.deinit(std.testing.allocator);
    const loader = parsed.program.zeropage_options.modules.?;
    try std.testing.expectEqualStrings("math_core", loader.disk_manifest.?.deps[0].id);
    try std.testing.expectEqual(ast.ModuleLoadMode.on_demand, loader.policy.?.deps[0].policy.mode);
    try std.testing.expectEqual(@as(u16, 0x400), loader.state.?.deps[0].state.ranges[0].offset);
    try std.testing.expectEqualStrings("tick", parsed.program.zeropage_module.?.exports[0].function_name);
}
