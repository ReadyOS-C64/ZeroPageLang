const std = @import("std");
const ast = @import("../../ast.zig");
const reachability = @import("reachability.zig");

/// Rejection-only bounded audit. No absent evidence is a disjointness proof.
/// Site ordinals are deterministic AST traversal diagnostics, NOT machine or
/// source-offset anchors. All returned evidence is owned numeric data.
pub const Kind = enum {
    external_pointer_input,
    external_pointee_observation,
    unproved_reu_endpoint,
    unproved_heap_free,
    literal_pointer_wrap,
    literal_index_wrap,
    screen_wrap,
};
pub const Evidence = struct {
    function_index: usize,
    site: usize,
    kind: Kind,
    parameter_index: ?usize = null,
};
pub const Summary = struct {
    unproven: bool,
    evidence: []Evidence,
    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.evidence);
        self.* = .{ .unproven = false, .evidence = &.{} };
    }
};
const Literal = struct { base: u16, width: u32, evidence: Evidence };

pub const ImageRange = struct {
    start: u32,
    end: u32,

    fn couldObserve(self: ImageRange, base: u16, width: u64) bool {
        const end = @as(u64, base) + width;
        return end > 65536 or (base < self.end and self.start < end);
    }
};

fn scanProgram(allocator: std.mem.Allocator, program: ast.Program, image: ?ImageRange, record_arguments: bool, private_stack: bool) !Scan {
    var retained = try reachability.collectProgram(allocator, program);
    defer retained.deinit();
    var scan: Scan = .{ .allocator = allocator, .program = program, .image = image, .record_arguments = record_arguments, .private_stack = private_stack };
    errdefer scan.deinit();
    for (program.functions, 0..) |function, index| {
        if (!retained.contains(function.name)) continue;
        if (reachability.rootReason(program, function) != null) for (function.params, 0..) |parameter, parameter_index| {
            if (pointerBearing(program, parameter.ty, 0)) {
                scan.external_input = true;
                try scan.evidence.append(allocator, .{ .function_index = index, .site = 0, .kind = .external_pointer_input, .parameter_index = parameter_index });
            }
        };
    }
    for (program.functions, 0..) |function, index| {
        if (!retained.contains(function.name)) continue;
        scan.function_index = index;
        scan.site = 0;
        scan.bindings.clearRetainingCapacity();
        for (function.params) |param| try scan.bindings.put(allocator, param.name, param.ty);
        try scan.statements(function.body);
    }
    return scan;
}

pub fn analyze(allocator: std.mem.Allocator, program: ast.Program) !Summary {
    var scan = try scanProgram(allocator, program, null, false, false);
    defer scan.deinit();
    if (scan.external_input) if (scan.first_pointee) |site| try scan.block(site, .external_pointee_observation);
    if (scan.first_pointee != null) for (scan.literals.items) |literal| {
        if (@as(u64, literal.base) + literal.width > 0x10000) try scan.block(literal.evidence, .literal_pointer_wrap);
        // Deliberately do not infer a loop/type bound for a runtime index. A
        // literal pointer in this retained image plus an unbounded syntactic
        // index is enough to reject; this is not an origin certificate.
        if (scan.first_dynamic_index) |site| {
            try scan.block(site, .literal_index_wrap);
        } else if (scan.max_literal_index) |index| {
            if (@as(u64, literal.base) + @as(u64, index) * literal.width + literal.width > 0x10000)
                try scan.block(literal.evidence, .literal_index_wrap);
        }
    };
    return .{ .unproven = scan.unproven, .evidence = try scan.evidence.toOwnedSlice(allocator) };
}

/// Integer-to-pointer conversions can lower to ordinary immediate bytes. Audit
/// their retained source origins before moving bytes that they might access.
pub fn observesMovableImage(allocator: std.mem.Allocator, program: ast.Program, image: ImageRange) !bool {
    return observesRange(allocator, program, image, false);
}

pub fn observesPrivateStack(allocator: std.mem.Allocator, program: ast.Program, stack: ImageRange) !bool {
    return observesRange(allocator, program, stack, true);
}

fn observesRange(allocator: std.mem.Allocator, program: ast.Program, image: ImageRange, private_stack: bool) !bool {
    var scan = try scanProgram(allocator, program, image, false, private_stack);
    defer scan.deinit();
    if (scan.observes_image or (scan.external_input and scan.first_pointee != null)) return true;
    for (scan.literals.items) |literal| {
        if (scan.first_dynamic_index != null) return true;
        const count = @as(u64, scan.max_literal_index orelse 0) + 1;
        if (scan.observesAddress(literal.base, count * literal.width)) return true;
    }
    return false;
}

pub const RecordArgument = struct {
    caller: usize,
    callee: usize,
    parameter: usize,
    source: union(enum) {
        unknown,
        local: []const u8,
        forwarded: struct { parameter: usize, path: []const u8 },
    },
};

/// Candidate origins in retained source, including an explicit unknown at
/// each unmatched edge. This does not certify the backing machine storage.
/// Names and paths borrow the Program. The caller owns the returned slice.
pub fn recordArguments(allocator: std.mem.Allocator, program: ast.Program) ![]RecordArgument {
    var scan = try scanProgram(allocator, program, null, true, false);
    defer scan.deinit();
    return scan.arguments.toOwnedSlice(allocator);
}

fn pointerBearing(program: ast.Program, ty: ast.Type, depth: usize) bool {
    if (depth >= 64) return true;
    return switch (ty) {
        .pointer, .near_view => true,
        .optional => |optional| switch (optional.child) {
            .pointer, .near_view => true,
            .custom => |name| pointerBearing(program, .{ .custom = name }, depth + 1),
            .scalar, .far_bytes => false,
        },
        .array => |array| switch (array.elem) {
            .custom => |name| pointerBearing(program, .{ .custom = name }, depth + 1),
            .scalar => false,
        },
        .custom => |name| blk: {
            if (program.findStruct(name)) |record| {
                for (record.fields) |field| if (pointerBearing(program, field.ty, depth + 1)) break :blk true;
                break :blk false;
            }
            if (program.findUnion(name)) |choice| {
                for (choice.fields) |field| if (field.ty) |payload| {
                    if (pointerBearing(program, payload, depth + 1)) break :blk true;
                };
                break :blk false;
            }
            break :blk program.findEnum(name) == null;
        },
        .void, .bool, .u8, .i8, .u16, .i16, .usize, .far_bytes, .far_view => false,
    };
}
fn int(expr: ast.Expr) ?u16 {
    return if (expr == .value and expr.value == .int) expr.value.int else null;
}
fn valueInt(value: ast.Value) ?u16 {
    return if (value == .int) value.int else null;
}
fn pointerWidth(program: ast.Program, context: ?ast.Type) u32 {
    const ty = context orelse return 2;
    const ptr = switch (ty) {
        .pointer => |p| p,
        .optional => |optional| if (optional.child == .pointer) optional.child.pointer else return 2,
        else => return 2,
    };
    return switch (ptr.child) {
        .scalar => |scalar| switch (scalar) {
            .u16, .i16, .usize => 2,
            .bool, .u8, .i8 => 1,
        },
        .custom => |name| if (program.findEnum(name) != null) 1 else 0x10000,
    };
}
const Scan = struct {
    allocator: std.mem.Allocator,
    program: ast.Program,
    image: ?ImageRange,
    bindings: std.StringHashMapUnmanaged(?ast.Type) = .empty,
    evidence: std.ArrayList(Evidence) = .empty,
    literals: std.ArrayList(Literal) = .empty,
    function_index: usize = 0,
    site: usize = 0,
    external_input: bool = false,
    observes_image: bool = false,
    unproven: bool = false,
    first_pointee: ?Evidence = null,
    first_dynamic_index: ?Evidence = null,
    max_literal_index: ?u16 = null,
    record_arguments: bool = false,
    private_stack: bool = false,
    arguments: std.ArrayList(RecordArgument) = .empty,

    fn observesAddress(self: Scan, base: u16, width: u64) bool {
        const image = self.image orelse return false;
        return image.couldObserve(base, width) or (self.private_stack and base < 0x100);
    }

    fn deinit(self: *Scan) void {
        self.bindings.deinit(self.allocator);
        self.evidence.deinit(self.allocator);
        self.literals.deinit(self.allocator);
        self.arguments.deinit(self.allocator);
    }
    fn next(self: *Scan) Evidence {
        self.site += 1;
        return .{ .function_index = self.function_index, .site = self.site, .kind = .external_pointee_observation };
    }
    fn block(self: *Scan, site: Evidence, kind: Kind) !void {
        var actual = site;
        actual.kind = kind;
        self.unproven = true;
        if (self.private_stack and kind == .screen_wrap) self.observes_image = true;
        try self.evidence.append(self.allocator, actual);
    }
    fn pointee(self: *Scan, site: Evidence) void {
        if (self.first_pointee == null) self.first_pointee = site;
    }
    fn index(self: *Scan, site: Evidence, expr: ast.Expr) void {
        self.pointee(site);
        if (int(expr)) |number| {
            self.max_literal_index = @max(self.max_literal_index orelse 0, number);
        } else if (self.first_dynamic_index == null) {
            self.first_dynamic_index = site;
        }
    }
    // Only distinguishes plain source binding VALUE writes from possible
    // auto-deref paths. Unresolved binding/path forms conservatively observe.
    fn fieldPointee(self: Scan, ty: ?ast.Type, suffix: []const u8, depth: usize) bool {
        if (depth >= 64) return true;
        const actual = ty orelse return true;
        if (actual == .pointer) return true;
        if (actual != .custom) return true;
        const record = self.program.findStruct(actual.custom) orelse return true;
        for (record.fields) |field| {
            if (std.mem.eql(u8, suffix, field.name)) return false;
            if (std.mem.startsWith(u8, suffix, field.name) and suffix.len > field.name.len and suffix[field.name.len] == '_')
                return self.fieldPointee(field.ty, suffix[field.name.len + 1 ..], depth + 1);
        }
        return true;
    }
    fn namedWrite(self: *Scan, site: Evidence, name: []const u8) void {
        // Lowering resolves pointer-struct prefixes BEFORE a plain binding,
        // including names which also contain underscores. Inspect every prefix
        // rather than relying on hash iteration or a same-name shortcut.
        var matched = self.bindings.contains(name);
        var bindings = self.bindings.iterator();
        while (bindings.next()) |binding| {
            const base = binding.key_ptr.*;
            if (std.mem.startsWith(u8, name, base) and name.len > base.len and name[base.len] == '_') {
                matched = true;
                if (self.fieldPointee(binding.value_ptr.*, name[base.len + 1 ..], 0)) {
                    self.pointee(site);
                    return;
                }
            }
        }
        if (!matched) self.pointee(site);
    }
    fn observeValue(self: *Scan, site: Evidence, value: ast.Value) void {
        switch (value) {
            .field => |field| {
                const ty = if (self.bindings.get(field.base)) |known| known else null;
                if (self.fieldPointee(ty, field.field, 0)) self.pointee(site);
            },
            .int, .bool, .char, .null, .ident, .enum_literal => {},
        }
    }
    fn inferred(self: Scan, value: ast.Expr) ?ast.Type {
        return switch (value) {
            .as_cast => |cast| cast.ty,
            .struct_literal => |record| .{ .custom = record.type_name },
            .call => |target| if (reachability.findFunctionForCall(self.program, target.target)) |function| function.return_type else null,
            .value => |v| if (v == .ident) self.bindings.get(v.ident) orelse null else null,
            else => null,
        };
    }
    fn call(self: *Scan, site: Evidence, value: ast.CallExpr) anyerror!void {
        const function = reachability.findFunctionForCall(self.program, value.target);
        if (function == null) self.pointee(site); // typed view/foreign effect, not a pure call guess
        if (self.record_arguments) if (function) |target| {
            for (self.program.functions, 0..) |candidate, callee_index| {
                if (!std.mem.eql(u8, target.name, candidate.name)) continue;
                for (target.params, 0..) |param, parameter| {
                    const ty = param.ty;
                    if (ty != .pointer or ty.pointer.child != .custom or self.program.findStruct(ty.pointer.child.custom) == null) continue;
                    var edge: RecordArgument = .{ .caller = self.function_index, .callee = callee_index, .parameter = parameter, .source = .unknown };
                    if (parameter < value.args.len) edge.source = self.recordSource(value.args[parameter], ty.pointer.child.custom);
                    try self.arguments.append(self.allocator, edge);
                }
                break;
            }
        };
        for (value.args, 0..) |arg, i| try self.expression(arg, if (function) |f| if (i < f.params.len) f.params[i].ty else null else null);
    }
    fn recordSource(self: Scan, arg: ast.Expr, record: []const u8) @FieldType(RecordArgument, "source") {
        const params = self.program.functions[self.function_index].params;
        if (arg == .value and arg.value == .ident) {
            for (params, 0..) |param, param_index| {
                if (param.ty == .pointer and param.ty.pointer.child == .custom and
                    std.mem.eql(u8, param.name, arg.value.ident) and std.mem.eql(u8, param.ty.pointer.child.custom, record))
                    return .{ .forwarded = .{ .parameter = param_index, .path = "" } };
            }
        }
        if (arg != .address_of or arg.address_of.index != null) return .unknown;
        const name = arg.address_of.name;
        if (self.bindings.get(name)) |binding| {
            const ty = binding orelse return .unknown;
            if (ty != .custom or !std.mem.eql(u8, ty.custom, record)) return .unknown;
            for (params) |param| if (std.mem.eql(u8, param.name, name)) return .unknown;
            return .{ .local = name };
        }
        var candidate: @FieldType(RecordArgument, "source") = .unknown;
        for (params, 0..) |param, param_index| {
            if (param.ty != .pointer or param.ty.pointer.child != .custom or name.len <= param.name.len + 1 or
                !std.mem.startsWith(u8, name, param.name) or name[param.name.len] != '_') continue;
            const path = name[param.name.len + 1 ..];
            if (!recordPathMatches(self.program, param.ty.pointer.child.custom, path, record)) continue;
            if (candidate != .unknown) return .unknown;
            candidate = .{ .forwarded = .{ .parameter = param_index, .path = path } };
        }
        return candidate;
    }
    fn fieldContext(self: Scan, type_name: []const u8, field_name: []const u8) ?ast.Type {
        if (self.program.findStruct(type_name)) |record| for (record.fields) |field| {
            if (std.mem.eql(u8, field.name, field_name)) return field.ty;
        };
        if (self.program.findUnion(type_name)) |choice| for (choice.fields) |field| {
            if (std.mem.eql(u8, field.name, field_name)) return field.ty;
        };
        return null;
    }
    fn statements(self: *Scan, body: []const ast.Stmt) anyerror!void {
        for (body) |stmt| {
            const site = self.next();
            switch (stmt) {
                .var_decl => |decl| {
                    try self.expression(decl.init, decl.ty);
                    try self.bindings.put(self.allocator, decl.name, decl.ty orelse self.inferred(decl.init));
                },
                .struct_var => |record| {
                    for (record.fields) |field| try self.expression(field.value, self.fieldContext(record.type_name, field.name));
                    try self.bindings.put(self.allocator, record.name, .{ .custom = record.type_name });
                },
                .string_var => |decl| try self.bindings.put(self.allocator, decl.name, null),
                .string_assign => {},
                .assign => |assign| {
                    self.namedWrite(site, assign.name);
                    try self.expression(assign.value, self.bindings.get(assign.name) orelse null);
                },
                inline .add_assign, .sub_assign, .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => |assign| {
                    self.namedWrite(site, assign.name);
                    try self.expression(assign.value, null);
                },
                .deref_assign => |assign| {
                    self.pointee(site);
                    try self.expression(assign.target, null);
                    try self.expression(assign.value, null);
                },
                inline .array_assign, .array_add_assign, .array_sub_assign, .array_mul_assign, .array_bit_and_assign, .array_bit_or_assign, .array_bit_xor_assign, .array_shl_assign, .array_shr_assign, .array_field_assign => |assign| {
                    self.index(site, assign.index);
                    try self.expression(assign.index, null);
                    try self.expression(assign.value, null);
                },
                .while_stmt => |loop| {
                    try self.expression(loop.condition, null);
                    try self.statements(loop.body);
                },
                .for_stmt => |loop| {
                    switch (loop.source) {
                        .array, .array_indexed => self.pointee(site),
                        .range => {},
                    }
                    if (loop.item_name) |name| try self.bindings.put(self.allocator, name, null);
                    if (loop.index_name) |name| try self.bindings.put(self.allocator, name, .usize);
                    try self.statements(loop.body);
                },
                .switch_stmt => |selection| {
                    try self.expression(selection.operand, null);
                    for (selection.prongs) |prong| {
                        if (prong.payload_name) |name| try self.bindings.put(self.allocator, name, null);
                        try self.statements(prong.body);
                    }
                },
                .if_stmt => |branch| {
                    try self.expression(branch.condition, null);
                    if (branch.payload_name) |name| try self.bindings.put(self.allocator, name, null);
                    try self.statements(branch.then_body);
                    try self.statements(branch.else_body);
                },
                .call => |v| try self.call(site, v),
                .discard => |v| try self.expression(v, null),
                .return_expr => |v| try self.expression(v, self.program.functions[self.function_index].return_type),
                .break_expr => |v| try self.expression(v.value, null),
                .inline_asm => if (self.private_stack) {
                    self.observes_image = true;
                },
                .test6502 => |v| try self.testCall(v),
                .builtin => |v| try self.builtin(site, v),
                .reu => |v| try self.reu(site, v),
                .heap_free => |free| {
                    self.pointee(site);
                    try self.block(site, .unproved_heap_free);
                    try self.expression(free.ptr.*, null);
                },
                .field_assign => |assign| try self.expression(assign.value, null),
                .reu_heap_reset, .heap_reset, .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph, .break_stmt, .continue_stmt => {},
            }
        }
    }
    fn expression(self: *Scan, expr: ast.Expr, context: ?ast.Type) anyerror!void {
        const site = self.next();
        switch (expr) {
            .value => |v| self.observeValue(site, v),
            inline .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| {
                try self.expression(binary.lhs.*, null);
                try self.expression(binary.rhs.*, null);
            },
            .bit_not, .not => |child| try self.expression(child.*, null),
            .int_from_ptr => |child| {
                if (self.image != null) self.observes_image = true;
                try self.expression(child.*, null);
            },
            .deref => |child| {
                self.pointee(site);
                try self.expression(child.*, null);
            },
            .ptr_from_int => |child| {
                if (int(child.*)) |base| {
                    try self.literals.append(self.allocator, .{ .base = base, .width = pointerWidth(self.program, context), .evidence = site });
                } else if (self.image != null) {
                    self.observes_image = true;
                }
                try self.expression(child.*, null);
            },
            .as_cast => |cast| try self.expression(cast.expr.*, cast.ty),
            .address_of, .size_of, .align_of, .offset_of, .c64_read_petscii, .c64_wait_petscii, .reu_present => {},
            .reu_compare => |v| try self.transfer(site, v.c64_addr.*, v.len.*),
            inline .reu_heap_alloc, .heap_alloc => |v| try self.expression(v.len.*, null),
            .reu_view => |v| try self.expression(v.far.*, null),
            .far_view_materialize => self.pointee(site),
            .far_view_materialize_range => |v| {
                self.pointee(site);
                try self.expression(v.start.*, null);
            },
            .module_call => |v| {
                self.pointee(site);
                for (v.args) |arg| try self.expression(arg, null);
            },
            .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded => {},
            .if_expr => |v| {
                try self.expression(v.condition.*, null);
                if (v.payload_name) |name| try self.bindings.put(self.allocator, name, null);
                try self.expression(v.then_expr.*, context);
                try self.expression(v.else_expr.*, context);
            },
            .switch_expr => |v| {
                try self.expression(v.operand.*, null);
                for (v.prongs) |prong| {
                    if (prong.payload_name) |name| try self.bindings.put(self.allocator, name, null);
                    try self.expression(prong.value, context);
                }
            },
            .block_expr => |v| try self.statements(v.body),
            .call => |v| try self.call(site, v),
            .array_literal => |v| for (v.values) |element| try self.expression(element, null),
            inline .array_index, .array_field_index => |v| {
                self.index(site, v.index.*);
                try self.expression(v.index.*, null);
            },
            .struct_literal => |v| {
                const name = if (v.type_name.len != 0) v.type_name else if (context) |ty| if (ty == .custom) ty.custom else "" else "";
                for (v.fields) |field| try self.expression(field.value, self.fieldContext(name, field.name));
            },
        }
    }
    fn transfer(self: *Scan, site: Evidence, address: ast.Expr, length: ast.Expr) !void {
        const base = int(address);
        const size = int(length);
        if (base == null or size == null or size.? == 0 or @as(u64, base.?) + size.? > 0x10000)
            try self.block(site, .unproved_reu_endpoint);
        if (self.image != null) {
            if (base == null or size == null or size.? == 0 or self.observesAddress(base.?, size.?)) self.observes_image = true;
        }
        try self.expression(address, .u16);
        try self.expression(length, .u16);
    }
    fn reu(self: *Scan, site: Evidence, value: ast.ReuStmt) !void {
        switch (value) {
            .copy_c64_to_reu, .copy_reu_to_c64, .swap => |v| try self.transfer(site, v.c64_addr.*, v.len.*),
            .copy_from_c64, .copy_to_c64 => |v| {
                try self.transfer(site, v.c64_addr.*, v.len.*);
                try self.expression(v.far.*, null);
            },
            .fill => |v| {
                try self.expression(v.value.*, .u8);
                try self.expression(v.len.*, .u16);
            },
        }
    }
    fn screen(self: *Scan, site: Evidence, x: ast.Value, y: ast.Value, count: u64) !void {
        const xx = valueInt(x);
        const yy = valueInt(y);
        if (xx == null or yy == null or @as(u64, 0xd800) + @as(u64, yy.?) * 40 + xx.? + count > 0x10000)
            try self.block(site, .screen_wrap);
        if (self.private_stack) {
            if (xx == null or yy == null or xx.? > 255 or yy.? > 255) {
                self.observes_image = true;
            } else {
                self.screenAddresses(@as(u16, yy.?) * 40 + xx.?, count);
            }
        }
        self.observeValue(site, x);
        self.observeValue(site, y);
    }

    fn screenAddresses(self: *Scan, offset: u16, count: u64) void {
        const screen_addr = 0x0400 + offset;
        const color_addr = @as(u32, 0xd800) + offset;
        if (color_addr > 0xffff or self.observesAddress(screen_addr, count) or
            self.observesAddress(@intCast(color_addr), count)) self.observes_image = true;
    }
    fn builtin(self: *Scan, site: Evidence, value: ast.BuiltinCall) !void {
        switch (value) {
            .puts_at => |v| try self.screen(site, v.x, v.y, v.text.len),
            .put_at => |v| {
                const y = valueInt(v.y);
                const base: u64 = switch (v.x) {
                    .value => |x| valueInt(x) orelse 0,
                    .base_plus => |x| x.base,
                };
                const max: u64 = switch (v.x) {
                    .value => |x| if (valueInt(x) == null) 255 else 0,
                    .base_plus => 255,
                };
                if (y == null or @as(u64, 0xd800) + @as(u64, y.?) * 40 + base + max + 1 > 0x10000) try self.block(site, .screen_wrap);
                if (self.private_stack) {
                    if (y == null or y.? > 255 or @as(u64, 0xd800) + @as(u64, y.?) * 40 + base > 0xffff) {
                        self.observes_image = true;
                    } else {
                        self.screenAddresses(y.? * 40 + @as(u16, @intCast(base)), max + 1);
                    }
                }
                switch (v.x) {
                    .value => |x| self.observeValue(site, x),
                    .base_plus => |x| self.observeValue(site, x.offset),
                }
                self.observeValue(site, v.y);
                try self.expression(v.ch, .u8);
            },
            .hex_at, .hex16_at => |v| {
                try self.screen(site, v.x, v.y, if (value == .hex_at) 2 else 4);
                try self.expression(v.value, null);
            },
            .console_print => |v| for (v.args) |arg| switch (arg) {
                .value => |e| try self.expression(e, null),
                .string => {},
            },
            .console_puts, .string_clear, .kernal_puts, .kernal_set_name => |v| self.observeValue(site, v),
            .string_append => |v| self.observeValue(site, v.target),
            .sleep_ticks, .sleep_frames => |v| try self.expression(v.ticks, .u16),
            .screen_clear, .console_clear => {},
        }
    }
    fn testCall(self: *Scan, value: ast.Test6502Call) !void {
        switch (value) {
            inline .expect_null, .expect_some_u8, .expect_some_u16, .expect_some_bool, .expect_some_ptr, .expect_equal_u8, .expect_equal_i8, .expect_equal_bool, .expect_equal_u16 => |v| try self.expression(v.actual, null),
            .expect_string => |v| self.observeValue(self.next(), v.actual),
            .expect_mem_u8, .expect_mem_u16 => |v| {
                if (self.observesAddress(v.addr, if (value == .expect_mem_u8) 1 else 2)) self.observes_image = true;
            },
            .prime_regs, .snapshot, .expect_a, .expect_x, .expect_y, .expect_sp, .expect_p, .expect_stack_u8 => {
                if (self.private_stack) self.observes_image = true;
            },
            .mark, .hit, .expect_hit_count, .pass, .fail => {},
        }
    }
};

fn recordPathMatches(program: ast.Program, root: []const u8, path: []const u8, target: []const u8) bool {
    const decl = program.findStruct(root) orelse return false;
    for (decl.fields) |field| {
        if (std.mem.eql(u8, field.name, path)) return field.ty == .custom and std.mem.eql(u8, field.ty.custom, target);
        if (field.ty == .custom and path.len > field.name.len + 1 and
            std.mem.startsWith(u8, path, field.name) and path[field.name.len] == '_' and
            recordPathMatches(program, field.ty.custom, path[field.name.len + 1 ..], target)) return true;
    }
    return false;
}
