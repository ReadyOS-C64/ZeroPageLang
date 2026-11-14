const std = @import("std");
const ast = @import("../../ast.zig");
const runtime = @import("runtime.zig");

pub const SwitchCoveredRange = struct {
    first: u16,
    last: u16,
};

pub fn constU8(value: ast.Value) !u8 {
    return switch (value) {
        .int => |n| std.math.cast(u8, n) orelse error.Overflow,
        else => error.ExpectedConstant,
    };
}

pub fn scalarTypeToType(ty: ast.ScalarType) ast.Type {
    return switch (ty) {
        .bool => .bool,
        .u8 => .u8,
        .i8 => .i8,
        .u16 => .u16,
        .i16 => .i16,
        .usize => .usize,
    };
}

pub fn arrayElemToType(elem: ast.ArrayElemType) ast.Type {
    return switch (elem) {
        .scalar => |scalar| scalarTypeToType(scalar),
        .custom => |name| .{ .custom = name },
    };
}

pub fn arrayElemToPointerChild(elem: ast.ArrayElemType) ast.PointerChildType {
    return switch (elem) {
        .scalar => |scalar| .{ .scalar = scalar },
        .custom => |name| .{ .custom = name },
    };
}

pub fn optionalChildToType(child: ast.OptionalChildType) ast.Type {
    return switch (child) {
        .scalar => |scalar| scalarTypeToType(scalar),
        .custom => |name| .{ .custom = name },
        .pointer => |ptr| .{ .pointer = ptr },
        .far_bytes => .far_bytes,
        .near_view => |view| .{ .near_view = view },
    };
}

pub fn arrayTypesEqual(a: ast.ArrayType, b: ast.ArrayType) bool {
    if (a.len != b.len) return false;
    return switch (a.elem) {
        .scalar => |a_scalar| switch (b.elem) {
            .scalar => |b_scalar| a_scalar == b_scalar,
            else => false,
        },
        .custom => |a_name| switch (b.elem) {
            .custom => |b_name| std.mem.eql(u8, a_name, b_name),
            else => false,
        },
    };
}

pub fn arrayElemIsWord(elem: ast.ArrayElemType) bool {
    return switch (elem) {
        .scalar => |scalar| switch (scalar) {
            .u16, .i16, .usize => true,
            else => false,
        },
        else => false,
    };
}

pub fn arrayElemSize(elem: ast.ArrayElemType) u16 {
    return if (arrayElemIsWord(elem)) 2 else 1;
}

pub fn arrayStorageBytes(ty: ast.ArrayType) u16 {
    return ty.len * arrayElemSize(ty.elem);
}

pub fn arrayOffsetLiteral(ty: ast.ArrayType, index: ast.Expr) ?u16 {
    const literal = exprIntLiteral(index) orelse return null;
    return literal * arrayElemSize(ty.elem);
}

pub fn isScalarSwitchType(ty: ast.Type) bool {
    return switch (ty) {
        .bool, .u8, .i8, .u16, .i16, .usize, .custom => true,
        else => false,
    };
}

pub fn switchSelectorLiteral(value: ast.Value) !u16 {
    return switch (value) {
        .int => |n| n,
        .bool => |b| @as(u16, @intFromBool(b)),
        .char => |ch| runtime.screenCode(ch),
        else => error.UnsupportedSwitchSelector,
    };
}

pub fn switchSelectorIsBool(value: ast.Value) bool {
    return switch (value) {
        .bool => true,
        else => false,
    };
}

pub fn rangesOverlap(a: SwitchCoveredRange, b: SwitchCoveredRange) bool {
    return a.first <= b.last and b.first <= a.last;
}

pub fn coversBoolBoth(ranges: []const SwitchCoveredRange) bool {
    var covers_false = false;
    var covers_true = false;
    for (ranges) |range| {
        if (range.first <= 0 and range.last >= 0) covers_false = true;
        if (range.first <= 1 and range.last >= 1) covers_true = true;
    }
    return covers_false and covers_true;
}

pub fn findStructFieldInit(fields: []const ast.StructFieldInit, name: []const u8) ?ast.StructFieldInit {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field;
    }
    return null;
}

pub fn findStructFieldDecl(decl: ast.StructDecl, name: []const u8) ?ast.StructFieldDecl {
    for (decl.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field;
    }
    return null;
}

pub fn prongHasElse(selectors: []const ast.SwitchSelector) bool {
    for (selectors) |selector| {
        if (selector == .else_prong) return true;
    }
    return false;
}

pub fn switchStmtElseIndex(prongs: []const ast.SwitchStmtProng) ?usize {
    for (prongs, 0..) |prong, index| {
        if (prongHasElse(prong.selectors)) return index;
    }
    return null;
}

pub fn switchExprElseIndex(prongs: []const ast.SwitchExprProng) ?usize {
    for (prongs, 0..) |prong, index| {
        if (prongHasElse(prong.selectors)) return index;
    }
    return null;
}

pub fn exprAsValue(expr: ast.Expr) !ast.Value {
    return switch (expr) {
        .value => |value| value,
        else => error.UnsupportedExpression,
    };
}

pub fn exprIntLiteral(expr: ast.Expr) ?u16 {
    return switch (expr) {
        .value => |value| switch (value) {
            .int => |n| n,
            else => null,
        },
        else => null,
    };
}

pub fn shiftRoutineName(op: anytype) []const u8 {
    return switch (op) {
        .shl => "zeropage_shl16",
        .shr => "zeropage_shr16",
    };
}
