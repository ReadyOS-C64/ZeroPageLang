const std = @import("std");
const ast = @import("../../ast.zig");

pub const StringBufferRef = struct {
    function_name: []const u8,
    name: []const u8,
    capacity: u8,
};

pub const StringSource = union(enum) {
    constant: ast.StringConstant,
    buffer: StringBufferRef,
};

pub const Binding = struct {
    ty: ast.Type,
    mutable: bool,
    inline_asm_allowed: bool = true,
};

pub const ArrayRef = struct {
    ty: ast.ArrayType,
    mutable: bool,
    label: []const u8,
    label_owned: bool = false,

    pub fn deinit(self: ArrayRef, allocator: std.mem.Allocator) void {
        if (self.label_owned) allocator.free(self.label);
    }
};

pub const AddressTarget = struct {
    pointer_ty: ast.Type,
    label: []const u8,
    offset: u16 = 0,
    indirect: bool = false,
    label_owned: bool = false,

    pub fn deinit(self: AddressTarget, allocator: std.mem.Allocator) void {
        if (self.label_owned) allocator.free(self.label);
    }
};
