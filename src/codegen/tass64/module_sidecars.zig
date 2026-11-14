const std = @import("std");
const ast = @import("../../ast.zig");

pub const RelocationKind = enum { abs16, lo8, hi8 };

pub const DependencyParam = struct {
    ty: ast.Type,
    offset: u16,
};

pub const DependencyExport = struct {
    name: []const u8,
    ordinal: usize,
    target_original: u16,
    return_type: ast.Type,
    params: []const DependencyParam,
    frame_size: u16,
    requires_kernal_rom: bool = false,
    kernal_trampoline_safe: bool = false,

    pub fn deinit(self: DependencyExport, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.params);
    }
};

pub const RelocationPatch = struct {
    payload_offset: u16,
    kind: RelocationKind,
    target_original: u16 = 0,
    addend: i16 = 0,
    after: [2]u8,
    size: u8,
};

pub const DependencyModule = struct {
    id: []const u8,
    payload_start: u16,
    jump_table_bytes: u16,
    load_window_addr: u16,
    load_window_size: u16,
    payload_length: u16,
    exports: []const DependencyExport,
    relocations: []const RelocationPatch,

    pub fn deinit(self: DependencyModule, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        for (self.exports) |export_decl| export_decl.deinit(allocator);
        allocator.free(self.exports);
        allocator.free(self.relocations);
    }

    pub fn findExport(self: DependencyModule, name: []const u8) ?DependencyExport {
        for (self.exports) |export_decl| {
            if (std.mem.eql(u8, export_decl.name, name)) return export_decl;
        }
        return null;
    }
};

pub const EmitOptions = struct {
    dependency_modules: []const DependencyModule = &.{},
};

pub const MetadataSidecar = struct {
    id: []const u8,
    payload_start: u16,
    jump_table_bytes: u16,
    exports: []const DependencyExport,

    pub fn deinit(self: MetadataSidecar, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        for (self.exports) |export_decl| export_decl.deinit(allocator);
        allocator.free(self.exports);
    }
};

pub const RelocSimSidecar = struct {
    id: []const u8,
    load_window_addr: u16,
    load_window_size: u16,
    payload_length: u16,
    relocations: []const RelocationPatch,

    pub fn deinit(self: RelocSimSidecar, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.relocations);
    }
};

pub fn mergeSidecars(allocator: std.mem.Allocator, metadata: MetadataSidecar, relocsim: RelocSimSidecar) !DependencyModule {
    if (!std.mem.eql(u8, metadata.id, relocsim.id)) return error.InvalidZeroPageDependencySidecar;
    return .{
        .id = try allocator.dupe(u8, metadata.id),
        .payload_start = metadata.payload_start,
        .jump_table_bytes = metadata.jump_table_bytes,
        .load_window_addr = relocsim.load_window_addr,
        .load_window_size = relocsim.load_window_size,
        .payload_length = relocsim.payload_length,
        .exports = try cloneExports(allocator, metadata.exports),
        .relocations = try allocator.dupe(RelocationPatch, relocsim.relocations),
    };
}

pub fn parseMetadataJson(allocator: std.mem.Allocator, json: []const u8) !MetadataSidecar {
    try expectStringField(json, "format", "zeropage-module-metadata");
    const version = try intField(json, "version");
    if (version != 1) return error.InvalidZeroPageDependencySidecar;
    const abi = try intField(json, "abi_version");
    if (abi != 1) return error.InvalidZeroPageDependencySidecar;
    const id = try stringFieldOwned(allocator, json, "module_id");
    errdefer allocator.free(id);
    const payload = try objectBody(json, "payload");
    const payload_start = try intField(payload, "start");
    const jump_table_bytes = try intField(payload, "jump_table_bytes");
    if (payload_start > 0xffff or jump_table_bytes > 0xffff) return error.InvalidZeroPageDependencySidecar;

    const exports_body = try arrayBody(json, "exports");
    var exports: std.ArrayList(DependencyExport) = .empty;
    errdefer {
        for (exports.items) |export_decl| export_decl.deinit(allocator);
        exports.deinit(allocator);
    }
    var it = ObjectIterator{ .body = exports_body };
    while (try it.next()) |object| {
        const name = try stringFieldOwned(allocator, object, "name");
        errdefer allocator.free(name);
        const ordinal = try intField(object, "ordinal");
        const target_original = try intField(object, "target_original");
        if (target_original > 0xffff) return error.InvalidZeroPageDependencySidecar;
        const frame = try stringField(object, "frame");
        if (!std.mem.eql(u8, frame, "stack")) return error.UnsupportedZeroPageModuleExport;
        const return_type = try typeField(object, "return");
        try validateScalarModuleType(return_type);
        const frame_size = try intField(object, "frame_size");
        if (frame_size > 255) return error.UnsupportedStackFrameTooLarge;

        const params_body = try arrayBody(object, "params");
        var params: std.ArrayList(DependencyParam) = .empty;
        errdefer params.deinit(allocator);
        var param_it = ObjectIterator{ .body = params_body };
        while (try param_it.next()) |param_object| {
            const ty = try typeField(param_object, "type");
            try validateScalarModuleType(ty);
            const offset = try intField(param_object, "offset");
            if (offset > 255) return error.UnsupportedStackFrameTooLarge;
            try params.append(allocator, .{ .ty = ty, .offset = @intCast(offset) });
        }

        try exports.append(allocator, .{
            .name = name,
            .ordinal = ordinal,
            .target_original = @intCast(target_original),
            .return_type = return_type,
            .params = try params.toOwnedSlice(allocator),
            .frame_size = @intCast(frame_size),
            .requires_kernal_rom = optionalBoolField(object, "requires_kernal_rom") catch |err| switch (err) {
                error.InvalidZeroPageDependencySidecar => false,
            },
            .kernal_trampoline_safe = optionalBoolField(object, "kernal_trampoline_safe") catch |err| switch (err) {
                error.InvalidZeroPageDependencySidecar => false,
            },
        });
    }
    return .{
        .id = id,
        .payload_start = @intCast(payload_start),
        .jump_table_bytes = @intCast(jump_table_bytes),
        .exports = try exports.toOwnedSlice(allocator),
    };
}

pub fn parseRelocSimJson(allocator: std.mem.Allocator, json: []const u8) !RelocSimSidecar {
    try expectStringField(json, "format", "zeropage-module-relocation-sim");
    const version = try intField(json, "version");
    if (version != 1) return error.InvalidZeroPageDependencySidecar;
    const id = try stringFieldOwned(allocator, json, "module_id");
    errdefer allocator.free(id);
    const load_window = try objectBody(json, "load_window");
    const addr = try intField(load_window, "addr");
    const size = try intField(load_window, "size");
    if (addr > 0xffff or size == 0 or size > 0xffff) return error.InvalidZeroPageDependencySidecar;
    const payload_length = try intField(json, "payload_length");
    if (payload_length == 0 or payload_length > 0xffff) return error.ZeroPageModulePayloadTooLarge;

    const relocs_body = try arrayBody(json, "applied_relocations");
    var relocs: std.ArrayList(RelocationPatch) = .empty;
    errdefer relocs.deinit(allocator);
    var it = ObjectIterator{ .body = relocs_body };
    while (try it.next()) |object| {
        const offset = try intField(object, "payload_offset");
        if (offset >= payload_length or offset > 0xffff) return error.InvalidZeroPageModuleRelocation;
        const kind_name = try stringField(object, "kind");
        const kind = parseRelocationKind(kind_name) orelse return error.UnsupportedZeroPageModuleRelocation;
        const target_original = intField(object, "target_original") catch |err| switch (err) {
            error.InvalidZeroPageDependencySidecar => 0,
            else => return err,
        };
        if (target_original > 0xffff) return error.InvalidZeroPageModuleRelocation;
        const addend_value = signedIntField(object, "addend") catch |err| switch (err) {
            error.InvalidZeroPageDependencySidecar => 0,
            else => return err,
        };
        if (addend_value < -32768 or addend_value > 32767) return error.InvalidZeroPageModuleRelocation;
        const after = try byteArrayField(object, "after");
        const expected_size: u8 = if (kind == .abs16) 2 else 1;
        if (after.size != expected_size) return error.InvalidZeroPageModuleRelocation;
        try relocs.append(allocator, .{
            .payload_offset = @intCast(offset),
            .kind = kind,
            .target_original = @intCast(target_original),
            .addend = @intCast(addend_value),
            .after = after.bytes,
            .size = after.size,
        });
    }

    return .{
        .id = id,
        .load_window_addr = @intCast(addr),
        .load_window_size = @intCast(size),
        .payload_length = @intCast(payload_length),
        .relocations = try relocs.toOwnedSlice(allocator),
    };
}

fn cloneExports(allocator: std.mem.Allocator, exports: []const DependencyExport) ![]DependencyExport {
    var out = try allocator.alloc(DependencyExport, exports.len);
    errdefer allocator.free(out);
    for (exports, 0..) |export_decl, index| {
        out[index] = .{
            .name = try allocator.dupe(u8, export_decl.name),
            .ordinal = export_decl.ordinal,
            .target_original = export_decl.target_original,
            .return_type = export_decl.return_type,
            .params = try allocator.dupe(DependencyParam, export_decl.params),
            .frame_size = export_decl.frame_size,
            .requires_kernal_rom = export_decl.requires_kernal_rom,
            .kernal_trampoline_safe = export_decl.kernal_trampoline_safe,
        };
    }
    return out;
}

fn validateScalarModuleType(ty: ast.Type) !void {
    return switch (ty) {
        .bool, .u8, .i8, .u16, .i16, .usize => {},
        else => error.UnsupportedZeroPageModuleExport,
    };
}

fn parseRelocationKind(name: []const u8) ?RelocationKind {
    if (std.mem.eql(u8, name, "abs16")) return .abs16;
    if (std.mem.eql(u8, name, "lo8")) return .lo8;
    if (std.mem.eql(u8, name, "hi8")) return .hi8;
    return null;
}

fn typeField(json: []const u8, key: []const u8) !ast.Type {
    const name = try stringField(json, key);
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "u8")) return .u8;
    if (std.mem.eql(u8, name, "i8")) return .i8;
    if (std.mem.eql(u8, name, "u16")) return .u16;
    if (std.mem.eql(u8, name, "i16")) return .i16;
    if (std.mem.eql(u8, name, "usize")) return .usize;
    return error.UnsupportedZeroPageModuleExport;
}

const ByteArray = struct { bytes: [2]u8, size: u8 };

fn byteArrayField(json: []const u8, key: []const u8) !ByteArray {
    const body = try arrayBody(json, key);
    var result: [2]u8 = .{ 0, 0 };
    var count: usize = 0;
    var i: usize = 0;
    while (i < body.len) {
        skipSpaces(body, &i);
        if (i >= body.len) break;
        if (count >= 2) return error.InvalidZeroPageModuleRelocation;
        const value = try parseIntAt(body, &i);
        if (value > 255) return error.InvalidZeroPageModuleRelocation;
        result[count] = @intCast(value);
        count += 1;
        skipSpaces(body, &i);
        if (i < body.len and body[i] == ',') i += 1;
    }
    if (count == 0) return error.InvalidZeroPageModuleRelocation;
    return .{ .bytes = result, .size = @intCast(count) };
}

fn expectStringField(json: []const u8, key: []const u8, expected: []const u8) !void {
    const actual = try stringField(json, key);
    if (!std.mem.eql(u8, actual, expected)) return error.InvalidZeroPageDependencySidecar;
}

fn stringFieldOwned(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ![]u8 {
    return try allocator.dupe(u8, try stringField(json, key));
}

fn stringField(json: []const u8, key: []const u8) ![]const u8 {
    var i = try fieldValueIndex(json, key);
    skipSpaces(json, &i);
    if (i >= json.len or json[i] != '"') return error.InvalidZeroPageDependencySidecar;
    i += 1;
    const start = i;
    while (i < json.len and json[i] != '"') : (i += 1) {}
    if (i >= json.len) return error.InvalidZeroPageDependencySidecar;
    return json[start..i];
}

fn intField(json: []const u8, key: []const u8) !usize {
    var i = try fieldValueIndex(json, key);
    skipSpaces(json, &i);
    return try parseIntAt(json, &i);
}

fn signedIntField(json: []const u8, key: []const u8) !isize {
    var i = try fieldValueIndex(json, key);
    skipSpaces(json, &i);
    var negative = false;
    if (i < json.len and json[i] == '-') {
        negative = true;
        i += 1;
    }
    const value = try parseIntAt(json, &i);
    if (value > @as(usize, @intCast(std.math.maxInt(isize)))) return error.InvalidZeroPageDependencySidecar;
    const signed: isize = @intCast(value);
    return if (negative) -signed else signed;
}

fn optionalBoolField(json: []const u8, key: []const u8) !bool {
    var i = try fieldValueIndex(json, key);
    skipSpaces(json, &i);
    if (std.mem.startsWith(u8, json[i..], "true")) return true;
    if (std.mem.startsWith(u8, json[i..], "false")) return false;
    return error.InvalidZeroPageDependencySidecar;
}

fn objectBody(json: []const u8, key: []const u8) ![]const u8 {
    var i = try fieldValueIndex(json, key);
    skipSpaces(json, &i);
    if (i >= json.len or json[i] != '{') return error.InvalidZeroPageDependencySidecar;
    const end = try matching(json, i, '{', '}');
    return json[i + 1 .. end];
}

fn arrayBody(json: []const u8, key: []const u8) ![]const u8 {
    var i = try fieldValueIndex(json, key);
    skipSpaces(json, &i);
    if (i >= json.len or json[i] != '[') return error.InvalidZeroPageDependencySidecar;
    const end = try matching(json, i, '[', ']');
    return json[i + 1 .. end];
}

fn fieldValueIndex(json: []const u8, key: []const u8) !usize {
    var needle_buf: [128]u8 = undefined;
    if (key.len + 2 > needle_buf.len) return error.InvalidZeroPageDependencySidecar;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + key.len], key);
    needle_buf[1 + key.len] = '"';
    const needle = needle_buf[0 .. key.len + 2];
    const field = std.mem.indexOf(u8, json, needle) orelse return error.InvalidZeroPageDependencySidecar;
    var i = field + needle.len;
    skipSpaces(json, &i);
    if (i >= json.len or json[i] != ':') return error.InvalidZeroPageDependencySidecar;
    return i + 1;
}

fn parseIntAt(json: []const u8, i: *usize) !usize {
    skipSpaces(json, i);
    const start = i.*;
    while (i.* < json.len and json[i.*] >= '0' and json[i.*] <= '9') : (i.* += 1) {}
    if (i.* == start) return error.InvalidZeroPageDependencySidecar;
    return try std.fmt.parseInt(usize, json[start..i.*], 10);
}

fn skipSpaces(bytes: []const u8, i: *usize) void {
    while (i.* < bytes.len and std.ascii.isWhitespace(bytes[i.*])) : (i.* += 1) {}
}

fn matching(bytes: []const u8, start: usize, open: u8, close: u8) !usize {
    var depth: usize = 0;
    var in_string = false;
    var i = start;
    while (i < bytes.len) : (i += 1) {
        const ch = bytes[i];
        if (ch == '"' and (i == 0 or bytes[i - 1] != '\\')) {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;
        if (ch == open) depth += 1;
        if (ch == close) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return error.InvalidZeroPageDependencySidecar;
}

const ObjectIterator = struct {
    body: []const u8,
    index: usize = 0,

    fn next(self: *ObjectIterator) !?[]const u8 {
        while (self.index < self.body.len and self.body[self.index] != '{') : (self.index += 1) {}
        if (self.index >= self.body.len) return null;
        const start = self.index;
        const end = try matching(self.body, start, '{', '}');
        self.index = end + 1;
        return self.body[start + 1 .. end];
    }
};

test "metadata sidecar parses optional KERNAL ROM export flags" {
    const json =
        \\{
        \\  "format": "zeropage-module-metadata",
        \\  "version": 1,
        \\  "module_id": "math_core",
        \\  "abi_version": 1,
        \\  "payload": { "start": 8192, "length": 8, "jump_table_bytes": 6 },
        \\  "exports": [
        \\    { "name": "add", "ordinal": 0, "label": "add", "target_original": 8192, "requires_kernal_rom": true, "kernal_trampoline_safe": true, "frame": "stack", "frame_size": 3, "params": [{ "name": "value", "type": "u8", "offset": 0 }], "return": "u8" },
        \\    { "name": "sub", "ordinal": 1, "label": "sub", "target_original": 8195, "frame": "stack", "frame_size": 3, "params": [{ "name": "value", "type": "u8", "offset": 0 }], "return": "u8" }
        \\  ]
        \\}
    ;
    const parsed = try parseMetadataJson(std.testing.allocator, json);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.exports[0].requires_kernal_rom);
    try std.testing.expect(parsed.exports[0].kernal_trampoline_safe);
    try std.testing.expect(!parsed.exports[1].requires_kernal_rom);
    try std.testing.expect(!parsed.exports[1].kernal_trampoline_safe);
}
