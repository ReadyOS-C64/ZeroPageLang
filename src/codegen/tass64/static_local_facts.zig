const std = @import("std");
const ast = @import("../../ast.zig");

pub const Origin = enum { parameter, return_buffer, local, hidden_counter, item_capture, index_capture, payload, string_buffer, constant_array, constant_string };
pub const Section = enum { static_frame, rodata };
pub const Shape = enum { scalar, array, structure, tagged_union, optional, pointer, string_buffer, string_constant, other };
pub const Spec = struct {
    owner: []const u8,
    label: []const u8,
    binding: []const u8,
    origin: Origin,
    width: u32,
    ty: ?ast.Type,
    enum_name: ?[]const u8 = null,
    type_name: ?[]const u8 = null,
    loop_id: ?usize = null,
    section: Section = .static_frame,
    shape: Shape = .scalar,
    array_length: ?u16 = null,
    element_width: ?u16 = null,
    child_kind: ?[]const u8 = null,
    child_name: ?[]const u8 = null,
};

// All returned data is owned independently of emitter AND Program. Resolved
// ast.Type is consumed transiently, never retained from a resolver context.
pub const Root = struct {
    owner: []const u8,
    label: []const u8,
    binding: []const u8,
    origin: Origin,
    width: u32,
    type_kind: ?std.meta.Tag(ast.Type),
    enum_name: ?[]const u8,
    type_name: ?[]const u8,
    metadata_id: usize,
    loop_id: ?usize,
    section: Section,
    shape: Shape,
    array_length: ?u16,
    element_width: ?u16,
    child_kind: ?[]const u8,
    child_name: ?[]const u8,

    fn init(a: std.mem.Allocator, s: Spec, id: usize) !Root {
        const owner = try a.dupe(u8, s.owner);
        errdefer a.free(owner);
        const label = try a.dupe(u8, s.label);
        errdefer a.free(label);
        const binding = try a.dupe(u8, s.binding);
        errdefer a.free(binding);
        const enum_name = if (s.enum_name) |n| try a.dupe(u8, n) else null;
        errdefer if (enum_name) |n| a.free(n);
        const type_name = if (s.type_name) |n| try a.dupe(u8, n) else null;
        errdefer if (type_name) |n| a.free(n);
        const child_kind = if (s.child_kind) |n| try a.dupe(u8, n) else null;
        errdefer if (child_kind) |n| a.free(n);
        const child_name = if (s.child_name) |n| try a.dupe(u8, n) else null;
        return .{ .owner = owner, .label = label, .binding = binding, .origin = s.origin, .width = s.width, .type_kind = if (s.ty) |ty| std.meta.activeTag(ty) else null, .enum_name = enum_name, .type_name = type_name, .metadata_id = id, .loop_id = s.loop_id, .section = s.section, .shape = s.shape, .array_length = s.array_length, .element_width = s.element_width, .child_kind = child_kind, .child_name = child_name };
    }
    fn deinit(self: Root, a: std.mem.Allocator) void {
        a.free(self.owner);
        a.free(self.label);
        a.free(self.binding);
        if (self.enum_name) |n| a.free(n);
        if (self.type_name) |n| a.free(n);
        if (self.child_kind) |n| a.free(n);
        if (self.child_name) |n| a.free(n);
    }
};
// Cell text borrows OWNED Root text, never the emitter or original AST. It is
// valid until Inventory.deinit; cells never acquire independent ownership.
pub const Cell = struct {
    root_index: usize,
    owner: []const u8,
    label: []const u8,
    binding: []const u8,
    origin: Origin,
    width: u16,
    type_kind: std.meta.Tag(ast.Type),
    enum_name: ?[]const u8,
    metadata_id: usize,
    loop_id: ?usize,
};
pub const Inventory = struct {
    roots: std.ArrayList(Root) = .empty,
    cells: std.ArrayList(Cell) = .empty,

    pub fn deinit(self: *Inventory, a: std.mem.Allocator) void {
        for (self.roots.items) |r| r.deinit(a);
        self.roots.deinit(a);
        self.cells.deinit(a);
        self.* = .{};
    }
    // Capacity/string allocation completes before commit. On OOM lengths and
    // existing cells are unchanged; no handoff or duplicate-string leak.
    pub fn append(self: *Inventory, a: std.mem.Allocator, s: Spec) !void {
        const cell = isLocalScalar(s);
        try self.roots.ensureUnusedCapacity(a, 1);
        if (cell) try self.cells.ensureUnusedCapacity(a, 1);
        const root = try Root.init(a, s, self.roots.items.len);
        const index = self.roots.items.len;
        self.roots.appendAssumeCapacity(root);
        if (cell) self.cells.appendAssumeCapacity(.{ .root_index = index, .owner = root.owner, .label = root.label, .binding = root.binding, .origin = root.origin, .width = @intCast(root.width), .type_kind = root.type_kind.?, .enum_name = root.enum_name, .metadata_id = root.metadata_id, .loop_id = root.loop_id });
    }
};
fn isLocalScalar(s: Spec) bool {
    if (s.section != .static_frame) return false;
    switch (s.origin) {
        .local, .hidden_counter, .item_capture, .index_capture => {},
        else => return false,
    }
    const ty = s.ty orelse return false;
    return switch (ty) {
        .bool, .u8, .i8 => s.width == 1,
        .u16, .i16, .usize => s.width == 2,
        .custom => s.enum_name != null and s.width == 1,
        else => false,
    };
}
fn allocationProof(a: std.mem.Allocator) !void {
    var inventory: Inventory = .{};
    defer inventory.deinit(a);
    try inventory.append(a, .{ .owner = "worker", .label = "worker_value", .binding = "value", .origin = .local, .width = 1, .ty = .{ .custom = "Mode" }, .enum_name = "Mode", .type_name = "Mode" });
    try inventory.append(a, .{ .owner = "worker", .label = "worker_board", .binding = "board", .origin = .local, .width = 9, .ty = .{ .custom = "Board" }, .type_name = "Board", .shape = .structure, .child_kind = "custom", .child_name = "Cell" });
    try std.testing.expectEqual(@as(usize, 2), inventory.roots.items.len);
    try std.testing.expectEqual(@as(usize, 1), inventory.cells.items.len);
}
test "static local facts own labels names and arrays through every OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProof, .{});
}
test "static local facts distinguish roots from independently typed scalar local origins" {
    var inventory: Inventory = .{};
    defer inventory.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    for ([_]Origin{ .parameter, .return_buffer, .local, .hidden_counter, .item_capture, .index_capture, .payload, .string_buffer, .constant_array, .constant_string }) |origin|
        try inventory.append(a, .{ .owner = "f", .label = "f_same", .binding = "same", .origin = origin, .width = 2, .ty = .usize, .loop_id = 7 });
    try std.testing.expectEqual(@as(usize, 10), inventory.roots.items.len);
    try std.testing.expectEqual(@as(usize, 4), inventory.cells.items.len);
    for (inventory.cells.items) |cell| {
        try std.testing.expectEqual(@as(?usize, 7), cell.loop_id);
        try std.testing.expectEqualStrings("f_same", cell.label);
        try std.testing.expectEqual(cell.metadata_id, cell.root_index);
    }
}
