const std = @import("std");
const ast = @import("../../ast.zig");
const placement_domains = @import("placement_domains.zig");
const reachability = @import("reachability.zig");

pub const FrameSlotKind = enum {
    param,
    local,
    hidden,
    compiler_scratch,
};

pub const FrameSlot = struct {
    name: []const u8,
    ty: ast.Type,
    kind: FrameSlotKind,
    offset: u16,
    size: u16,
    name_owned: bool = false,
};

pub const FrameLayout = struct {
    function_name: []const u8,
    policy: ast.FramePolicy,
    slots: []FrameSlot,
    byte_size: u16,

    pub fn deinit(self: FrameLayout, allocator: std.mem.Allocator) void {
        for (self.slots) |slot| {
            if (slot.name_owned) allocator.free(slot.name);
        }
        if (self.slots.len != 0) allocator.free(self.slots);
    }

    pub fn findSlot(self: FrameLayout, name: []const u8) ?FrameSlot {
        return findSlotIn(self.slots, name);
    }
};

fn findSlotIn(slots: []const FrameSlot, name: []const u8) ?FrameSlot {
    for (slots) |slot| {
        if (std.mem.eql(u8, slot.name, name)) return slot;
    }
    return null;
}

pub fn effectivePolicy(program: ast.Program, function_name: []const u8) ast.FramePolicy {
    for (program.zeropage_options.abi.functions) |policy| {
        if (std.mem.eql(u8, policy.name, function_name)) return policy.frame;
    }
    return program.zeropage_options.abi.default_frame;
}

// The same decision controls bridge emission and the slots it reserves.
pub fn canForwardArguments(program: ast.Program, slots: []const FrameSlot, size: u16, params: []const ast.Param, args: []const ast.Expr) bool {
    const options = program.zeropage_options;
    const stack = options.stack orelse return false;
    if (program.zeropage_module != null or options.modules != null or options.memory.placements.len != 0 or
        stack.base < 0x0200 or stack.zp.sp < 2 or stack.zp.fp < 2 or args.len == 0 or params.len != args.len) return false;
    const end = @as(u32, stack.base) + stack.size;
    // Keep effective and wrong-page indexed reads in ordinary C64 RAM.
    if (!(end <= 0xa000 or (stack.base >= 0xc000 and end <= 0xd000))) return false;
    for (params, args) |param, arg| {
        if (arg != .value or arg.value != .ident) return false;
        const slot = findSlotIn(slots, arg.value.ident) orelse return false;
        if (slot.kind != .param and slot.kind != .local) return false;
        if (std.meta.activeTag(slot.ty) != std.meta.activeTag(param.ty)) return false;
        const width: u16 = switch (param.ty) {
            .bool, .u8, .i8 => 1,
            .u16, .i16, .usize => 2,
            .custom => |name| if (std.mem.eql(u8, slot.ty.custom, name) and program.findEnum(name) != null) 1 else return false,
            else => return false,
        };
        if (slot.size != width or @as(u32, slot.offset) + width > size) return false;
    }
    return true;
}

pub fn hasPrivateStackLayout(allocator: std.mem.Allocator, program: ast.Program) !bool {
    const options = program.zeropage_options;
    const stack = options.stack orelse return false;
    if (program.zeropage_module != null or options.modules != null or options.memory.placements.len != 0) return false;
    const end = @as(u32, stack.base) + stack.size;
    // Restrict layout changes to the standalone RAM window above BASIC ROM.
    if (stack.base < 0xc000 or end > 0xd000) return false;
    for (program.functions) |function| {
        if (function.exported and !std.mem.eql(u8, function.name, "main")) return false;
    }
    // Literal memory operations or foreign code can observe private
    // frame addresses or the compiler's zero-page stack pointers.
    return !try placement_domains.observesPrivateStack(allocator, program, .{
        .start = stack.base,
        .end = end,
    });
}

pub fn planStackFrames(allocator: std.mem.Allocator, program: ast.Program) ![]FrameLayout {
    var layouts: std.ArrayList(FrameLayout) = .empty;
    errdefer {
        for (layouts.items) |layout| layout.deinit(allocator);
        layouts.deinit(allocator);
    }

    for (program.functions) |function| {
        const policy = effectivePolicy(program, function.name);
        if (policy == .stack) {
            try layouts.append(allocator, try planFunction(allocator, program, function, policy));
        }
    }

    return try layouts.toOwnedSlice(allocator);
}

pub fn planFunction(allocator: std.mem.Allocator, program: ast.Program, function: ast.Function, policy: ast.FramePolicy) !FrameLayout {
    var planner = Planner{
        .allocator = allocator,
        .program = program,
        .function = function,
    };
    defer planner.deinitScratch();

    for (function.params) |param| try planner.addSlot(param.name, param.ty, .param, false);
    try validateReturnType(program, function.return_type);
    for (function.body) |stmt| try planner.planStmt(stmt);
    try planner.addScratchSlots();

    return .{
        .function_name = function.name,
        .policy = policy,
        .slots = try planner.slots.toOwnedSlice(allocator),
        .byte_size = planner.next_offset,
    };
}

const Planner = struct {
    allocator: std.mem.Allocator,
    program: ast.Program,
    function: ast.Function,
    slots: std.ArrayList(FrameSlot) = .empty,
    next_offset: u16 = 0,
    max_call_arg_temps: usize = 0,
    max_staged_call_args: usize = 0,
    uses_math_tmp: bool = false,
    uses_switch_tmp: bool = false,
    uses_pointer_tmp: bool = false,
    uses_optional_tmp: bool = false,

    fn deinitScratch(self: *Planner) void {
        for (self.slots.items) |slot| {
            if (slot.name_owned) self.allocator.free(slot.name);
        }
        self.slots.deinit(self.allocator);
    }

    fn addSlot(self: *Planner, name: []const u8, ty: ast.Type, kind: FrameSlotKind, name_owned: bool) !void {
        const size = try stackSlotSize(self.program, ty);
        try self.addSizedSlot(name, ty, kind, size, name_owned);
    }

    fn addSizedSlot(self: *Planner, name: []const u8, ty: ast.Type, kind: FrameSlotKind, size: u16, name_owned: bool) !void {
        try self.slots.append(self.allocator, .{
            .name = name,
            .ty = ty,
            .kind = kind,
            .offset = self.next_offset,
            .size = size,
            .name_owned = name_owned,
        });
        self.next_offset = try std.math.add(u16, self.next_offset, size);
    }

    fn addGeneratedSlot(self: *Planner, comptime fmt: []const u8, args: anytype, ty: ast.Type, kind: FrameSlotKind) !void {
        const name = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(name);
        try self.addSlot(name, ty, kind, true);
    }

    fn addScratchSlots(self: *Planner) !void {
        const count = if (self.max_staged_call_args < self.max_call_arg_temps and
            try hasPrivateStackLayout(self.allocator, self.program))
            self.max_staged_call_args
        else
            self.max_call_arg_temps;
        for (0..count) |index| {
            const name = try std.fmt.allocPrint(self.allocator, "zeropage_call_arg_{d}", .{index});
            errdefer self.allocator.free(name);
            try self.addSizedSlot(name, .u16, .compiler_scratch, 2, true);
        }
        if (self.uses_math_tmp) try self.addSizedSlot("zeropage_math_tmp", .u16, .compiler_scratch, 2, false);
        if (self.uses_switch_tmp) try self.addSizedSlot("zeropage_switch_value", .u16, .compiler_scratch, 2, false);
        if (self.uses_pointer_tmp) try self.addSizedSlot("zeropage_ptr_tmp", .usize, .compiler_scratch, 2, false);
        if (self.uses_optional_tmp) try self.addSizedSlot("zeropage_optional_tmp", .u8, .compiler_scratch, 3, false);
    }

    fn planStmt(self: *Planner, stmt: ast.Stmt) anyerror!void {
        switch (stmt) {
            .var_decl => |decl| {
                const ty = decl.ty orelse try self.inferExprType(decl.init);
                try self.addSlot(decl.name, ty, .local, false);
                try self.scanExpr(decl.init);
            },
            .string_var => return error.UnsupportedStackFrameString,
            .string_assign => |assign| try self.scanStringExpr(assign.expr),
            .struct_var => return error.UnsupportedStackFrameAggregate,
            .assign => |assign| try self.scanExpr(assign.value),
            inline .add_assign, .sub_assign, .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => |assign| {
                self.uses_math_tmp = true;
                try self.scanExpr(assign.value);
            },
            .deref_assign => |assign| {
                self.uses_pointer_tmp = true;
                try self.scanExpr(assign.target);
                try self.scanExpr(assign.value);
            },
            .array_assign, .array_add_assign, .array_sub_assign, .array_mul_assign, .array_bit_and_assign, .array_bit_or_assign, .array_bit_xor_assign, .array_shl_assign, .array_shr_assign => |assign| {
                self.uses_pointer_tmp = true;
                try self.scanExpr(assign.index);
                try self.scanExpr(assign.value);
            },
            .array_field_assign => |assign| {
                self.uses_pointer_tmp = true;
                try self.scanExpr(assign.index);
                try self.scanExpr(assign.value);
            },
            .while_stmt => |while_stmt| {
                try self.scanExpr(while_stmt.condition);
                try self.planStmts(while_stmt.body);
            },
            .for_stmt => |for_stmt| {
                try self.planForSlots(for_stmt);
                try self.planStmts(for_stmt.body);
            },
            .switch_stmt => |switch_stmt| {
                self.uses_switch_tmp = true;
                const payload_ty = try self.inferExprType(switch_stmt.operand);
                try self.scanExpr(switch_stmt.operand);
                for (switch_stmt.prongs) |prong| {
                    if (prong.payload_name) |name| try self.addPayloadSlot(name, payload_ty);
                    try self.planStmts(prong.body);
                }
            },
            .if_stmt => |if_stmt| {
                try self.scanExpr(if_stmt.condition);
                if (if_stmt.payload_name) |name| try self.addOptionalPayloadSlot(name, if_stmt.condition);
                try self.planStmts(if_stmt.then_body);
                try self.planStmts(if_stmt.else_body);
            },
            .call => |call| try self.scanCall(call),
            .discard, .return_expr => |expr| try self.scanExpr(expr),
            .break_expr => |break_expr| try self.scanExpr(break_expr.value),
            .break_stmt, .continue_stmt, .inline_asm => {},
            .test6502 => |call| try self.scanTest6502(call),
            .builtin => |builtin| try self.scanBuiltin(builtin),
            .reu => return error.UnsupportedStackFrameRuntimeCall,
            .reu_heap_reset => return error.UnsupportedStackFrameRuntimeCall,
            .heap_reset => return error.UnsupportedStackFrameRuntimeCall,
            .heap_free => return error.UnsupportedStackFrameRuntimeCall,
            .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph => return error.UnsupportedStackFrameRuntimeCall,
            .field_assign => |field| try self.scanExpr(field.value),
        }
    }

    fn planStmts(self: *Planner, stmts: []const ast.Stmt) anyerror!void {
        for (stmts) |stmt| try self.planStmt(stmt);
    }

    fn planForSlots(self: *Planner, for_stmt: ast.ForStmt) !void {
        try self.addGeneratedSlot("{s}_for_{d}_index", .{ self.function.name, for_stmt.id }, .usize, .hidden);
        if (for_stmt.item_name) |name| try self.addSlot(name, try self.forItemType(for_stmt), .hidden, false);
        if (for_stmt.index_name) |name| try self.addSlot(name, .usize, .hidden, false);
    }

    fn forItemType(self: *Planner, for_stmt: ast.ForStmt) !ast.Type {
        return switch (for_stmt.source) {
            .range => .usize,
            .array, .array_indexed => |name| blk: {
                const array = self.program.findArray(name) orelse return error.UnsupportedStackFrameAggregate;
                break :blk arrayElemToType(array.ty.elem);
            },
        };
    }

    fn addPayloadSlot(self: *Planner, name: []const u8, ty: ast.Type) !void {
        switch (ty) {
            .optional => return error.UnsupportedStackFrameOptional,
            .custom => |type_name| {
                if (self.program.findUnion(type_name) != null) return error.UnsupportedStackFrameUnion;
                try self.addSlot(name, ty, .hidden, false);
            },
            .array => return error.UnsupportedStackFrameAggregate,
            else => try self.addSlot(name, ty, .hidden, false),
        }
    }

    fn addOptionalPayloadSlot(self: *Planner, name: []const u8, condition: ast.Expr) !void {
        const ty = try self.inferExprType(condition);
        switch (ty) {
            .optional => |optional| {
                self.uses_optional_tmp = true;
                try self.addSlot(name, optionalChildToType(optional.child), .hidden, false);
            },
            else => {},
        }
    }

    fn scanExpr(self: *Planner, expr: ast.Expr) anyerror!void {
        switch (expr) {
            .value => {},
            .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte => |binary| {
                self.uses_math_tmp = true;
                try self.scanExpr(binary.lhs.*);
                try self.scanExpr(binary.rhs.*);
            },
            .bool_and, .bool_or => |binary| {
                try self.scanExpr(binary.lhs.*);
                try self.scanExpr(binary.rhs.*);
            },
            .bit_not => |child| {
                self.uses_math_tmp = true;
                try self.scanExpr(child.*);
            },
            .not => |child| try self.scanExpr(child.*),
            .address_of => {
                self.uses_pointer_tmp = true;
            },
            .deref, .ptr_from_int, .int_from_ptr => |child| {
                self.uses_pointer_tmp = true;
                try self.scanExpr(child.*);
            },
            .size_of, .align_of, .offset_of => {},
            .as_cast => |as_cast| try self.scanExpr(as_cast.expr.*),
            .c64_read_petscii, .c64_wait_petscii, .reu_present => {},
            .reu_compare => |transfer| {
                try self.scanExpr(transfer.c64_addr.*);
                try self.scanExpr(transfer.len.*);
            },
            .reu_heap_alloc, .reu_view, .far_view_materialize, .far_view_materialize_range, .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded, .module_call, .heap_alloc => return error.UnsupportedStackFrameRuntimeCall,
            .if_expr => |if_expr| {
                try self.scanExpr(if_expr.condition.*);
                if (if_expr.payload_name) |name| try self.addOptionalPayloadSlot(name, if_expr.condition.*);
                try self.scanExpr(if_expr.then_expr.*);
                try self.scanExpr(if_expr.else_expr.*);
            },
            .switch_expr => |switch_expr| {
                self.uses_switch_tmp = true;
                const payload_ty = try self.inferExprType(switch_expr.operand.*);
                try self.scanExpr(switch_expr.operand.*);
                for (switch_expr.prongs) |prong| {
                    if (prong.payload_name) |name| try self.addPayloadSlot(name, payload_ty);
                    try self.scanExpr(prong.value);
                }
            },
            .block_expr => |block_expr| try self.planStmts(block_expr.body),
            .call => |call| try self.scanCall(call),
            .array_literal => return error.UnsupportedStackFrameAggregate,
            .array_index => |index| {
                self.uses_pointer_tmp = true;
                try self.scanExpr(index.index.*);
            },
            .array_field_index => |index| {
                self.uses_pointer_tmp = true;
                try self.scanExpr(index.index.*);
            },
            .struct_literal => return error.UnsupportedStackFrameAggregate,
        }
    }

    fn scanCall(self: *Planner, call: ast.CallExpr) !void {
        if (reachability.findFunctionForCall(self.program, call.target)) |callee| {
            if (effectivePolicy(self.program, callee.name) == .stack) {
                self.max_call_arg_temps = @max(self.max_call_arg_temps, call.args.len);
                if (!canForwardArguments(self.program, self.slots.items, self.next_offset, callee.params, call.args))
                    self.max_staged_call_args = @max(self.max_staged_call_args, call.args.len);
            }
        }
        for (call.args) |arg| {
            if (exprContainsCall(arg)) {
                self.max_call_arg_temps = @max(self.max_call_arg_temps, 1);
                self.max_staged_call_args = @max(self.max_staged_call_args, 1);
            }
            try self.scanExpr(arg);
        }
    }

    fn scanStringExpr(self: *Planner, expr: ast.StringExpr) !void {
        for (expr.parts) |part| {
            if (part == .ident) self.uses_pointer_tmp = true;
        }
    }

    fn scanBuiltin(self: *Planner, builtin: ast.BuiltinCall) !void {
        switch (builtin) {
            .put_at => |put| try self.scanExpr(put.ch),
            .hex_at, .hex16_at => |hex| try self.scanExpr(hex.value),
            .console_print => |print| {
                for (print.args) |arg| {
                    if (arg == .value) try self.scanExpr(arg.value);
                }
            },
            .string_append => |append| try self.scanStringExpr(append.expr),
            .sleep_ticks, .sleep_frames => |sleep| try self.scanExpr(sleep.ticks),
            else => {},
        }
    }

    fn scanTest6502(self: *Planner, call: ast.Test6502Call) !void {
        switch (call) {
            .expect_null => |expect| try self.scanExpr(expect.actual),
            .expect_some_u8, .expect_some_u16, .expect_some_bool, .expect_some_ptr, .expect_equal_u8, .expect_equal_i8, .expect_equal_bool, .expect_equal_u16 => |expect| try self.scanExpr(expect.actual),
            .expect_string => {},
            else => {},
        }
    }

    fn inferExprType(self: *Planner, expr: ast.Expr) anyerror!ast.Type {
        return switch (expr) {
            .value => |value| self.valueType(value),
            .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr => |binary| blk: {
                const lhs = try self.inferExprType(binary.lhs.*);
                const rhs = try self.inferExprType(binary.rhs.*);
                break :blk if (isWordType(lhs) or isWordType(rhs)) ast.Type.u16 else ast.Type.u8;
            },
            .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or, .not => .bool,
            .bit_not => |child| try self.inferExprType(child.*),
            .deref => |child| blk: {
                const ptr_ty = try self.inferExprType(child.*);
                break :blk switch (ptr_ty) {
                    .pointer => |ptr| pointerChildToType(ptr.child),
                    else => error.UnsupportedStackFrameType,
                };
            },
            .ptr_from_int, .int_from_ptr, .address_of => .usize,
            .size_of, .align_of, .offset_of => .usize,
            .as_cast => |as_cast| as_cast.ty,
            .c64_read_petscii, .c64_wait_petscii => .u8,
            .reu_present, .reu_compare => .bool,
            .reu_heap_alloc, .reu_view, .far_view_materialize, .far_view_materialize_range, .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded, .module_call, .heap_alloc => error.UnsupportedStackFrameRuntimeCall,
            .if_expr => |if_expr| try self.inferExprType(if_expr.then_expr.*),
            .switch_expr => |switch_expr| if (switch_expr.prongs.len == 0) error.UnsupportedStackFrameType else try self.inferExprType(switch_expr.prongs[0].value),
            .block_expr => error.UnsupportedStackFrameType,
            .call => |call| blk: {
                const target = reachability.findFunctionForCall(self.program, call.target) orelse return error.UnsupportedStackFrameType;
                break :blk target.return_type;
            },
            .array_literal => error.UnsupportedStackFrameAggregate,
            .array_index => |index| blk: {
                const array = self.program.findArray(index.name) orelse return error.UnsupportedStackFrameAggregate;
                break :blk arrayElemToType(array.ty.elem);
            },
            .array_field_index => error.UnsupportedStackFrameAggregate,
            .struct_literal => error.UnsupportedStackFrameAggregate,
        };
    }

    fn valueType(self: *Planner, value: ast.Value) !ast.Type {
        return switch (value) {
            .int => |n| if (n > 255) ast.Type.u16 else ast.Type.u8,
            .bool => .bool,
            .char => .u8,
            .null => error.UnsupportedStackFrameOptional,
            .ident => |name| self.lookupSlotType(name) orelse error.UnsupportedStackFrameType,
            .field => error.UnsupportedStackFrameAggregate,
            .enum_literal => .u8,
        };
    }

    fn lookupSlotType(self: *Planner, name: []const u8) ?ast.Type {
        for (self.slots.items) |slot| {
            if (std.mem.eql(u8, slot.name, name)) return slot.ty;
        }
        return null;
    }
};

fn validateReturnType(program: ast.Program, ty: ast.Type) !void {
    _ = try stackSlotSize(program, ty);
}

fn stackSlotSize(program: ast.Program, ty: ast.Type) !u16 {
    return switch (ty) {
        .void => 0,
        .bool, .u8, .i8 => 1,
        .u16, .i16, .usize, .pointer => 2,
        .far_bytes, .far_view, .near_view => error.UnsupportedStackFrameAggregate,
        .optional => error.UnsupportedStackFrameOptional,
        .array => error.UnsupportedStackFrameAggregate,
        .custom => |name| {
            if (program.findEnum(name) != null) return 1;
            if (program.findUnion(name) != null) return error.UnsupportedStackFrameUnion;
            return error.UnsupportedStackFrameAggregate;
        },
    };
}

fn arrayElemToType(elem: ast.ArrayElemType) ast.Type {
    return switch (elem) {
        .scalar => |scalar| scalarToType(scalar),
        .custom => |name| .{ .custom = name },
    };
}

fn optionalChildToType(child: ast.OptionalChildType) ast.Type {
    return switch (child) {
        .scalar => |scalar| scalarToType(scalar),
        .custom => |name| .{ .custom = name },
        .pointer => |ptr| .{ .pointer = ptr },
        .far_bytes => .far_bytes,
        .near_view => |view| .{ .near_view = view },
    };
}

fn pointerChildToType(child: ast.PointerChildType) ast.Type {
    return switch (child) {
        .scalar => |scalar| scalarToType(scalar),
        .custom => |name| .{ .custom = name },
    };
}

fn scalarToType(scalar: ast.ScalarType) ast.Type {
    return switch (scalar) {
        .bool => .bool,
        .u8 => .u8,
        .i8 => .i8,
        .u16 => .u16,
        .i16 => .i16,
        .usize => .usize,
    };
}

fn isWordType(ty: ast.Type) bool {
    return switch (ty) {
        .u16, .i16, .usize, .pointer => true,
        else => false,
    };
}

pub fn exprContainsCall(expr: ast.Expr) bool {
    return switch (expr) {
        .call => true,
        .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| exprContainsCall(binary.lhs.*) or exprContainsCall(binary.rhs.*),
        .bit_not, .not, .deref, .ptr_from_int, .int_from_ptr => |child| exprContainsCall(child.*),
        .as_cast => |as_cast| exprContainsCall(as_cast.expr.*),
        .if_expr => |if_expr| exprContainsCall(if_expr.condition.*) or exprContainsCall(if_expr.then_expr.*) or exprContainsCall(if_expr.else_expr.*),
        .switch_expr => |switch_expr| blk: {
            if (exprContainsCall(switch_expr.operand.*)) break :blk true;
            for (switch_expr.prongs) |prong| if (exprContainsCall(prong.value)) break :blk true;
            break :blk false;
        },
        .block_expr => |block_expr| blk: {
            for (block_expr.body) |stmt| if (stmtContainsCall(stmt)) break :blk true;
            break :blk false;
        },
        .array_literal => |array| blk: {
            for (array.values) |value| if (exprContainsCall(value)) break :blk true;
            break :blk false;
        },
        .array_index => |index| exprContainsCall(index.index.*),
        .array_field_index => |index| exprContainsCall(index.index.*),
        .struct_literal => |literal| blk: {
            for (literal.fields) |field| if (exprContainsCall(field.value)) break :blk true;
            break :blk false;
        },
        .reu_compare => |transfer| exprContainsCall(transfer.c64_addr.*) or exprContainsCall(transfer.len.*),
        .reu_heap_alloc, .reu_view, .far_view_materialize, .far_view_materialize_range, .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded, .module_call, .heap_alloc => true,
        else => false,
    };
}

pub fn stmtContainsCall(stmt: ast.Stmt) bool {
    return switch (stmt) {
        .var_decl => |decl| exprContainsCall(decl.init),
        inline .assign, .add_assign, .sub_assign, .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => |assign| exprContainsCall(assign.value),
        .deref_assign => |assign| exprContainsCall(assign.target) or exprContainsCall(assign.value),
        .array_assign, .array_add_assign, .array_sub_assign, .array_mul_assign, .array_bit_and_assign, .array_bit_or_assign, .array_bit_xor_assign, .array_shl_assign, .array_shr_assign => |assign| exprContainsCall(assign.index) or exprContainsCall(assign.value),
        .array_field_assign => |assign| exprContainsCall(assign.index) or exprContainsCall(assign.value),
        .while_stmt => |while_stmt| exprContainsCall(while_stmt.condition),
        .if_stmt => |if_stmt| exprContainsCall(if_stmt.condition),
        .switch_stmt => |switch_stmt| exprContainsCall(switch_stmt.operand),
        .call => true,
        .discard, .return_expr => |expr| exprContainsCall(expr),
        .break_expr => |break_expr| exprContainsCall(break_expr.value),
        .field_assign => |field| exprContainsCall(field.value),
        .reu => |call| switch (call) {
            .copy_c64_to_reu, .copy_reu_to_c64, .swap => |transfer| exprContainsCall(transfer.c64_addr.*) or exprContainsCall(transfer.len.*),
            .fill => |fill| exprContainsCall(fill.value.*) or exprContainsCall(fill.len.*),
            .copy_from_c64, .copy_to_c64 => |copy| exprContainsCall(copy.far.*) or exprContainsCall(copy.c64_addr.*) or exprContainsCall(copy.len.*),
        },
        .reu_heap_reset => true,
        .heap_reset => true,
        .heap_free => true,
        .module_unload => true,
        else => false,
    };
}

test "stack frame planner resolves default and per-function policies" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{
        \\        .default_frame = .stack,
        \\        .functions = .{ .math_add8 = .{ .frame = .static } },
        \\    },
        \\};
        \\fn math_add8(a: u8, b: u8) u8 { return a + b; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(ast.FramePolicy.stack, effectivePolicy(parsed.program, "main"));
    try std.testing.expectEqual(ast.FramePolicy.static, effectivePolicy(parsed.program, "math_add8"));
}

test "stack frame planner lays out scalar params locals and scratch" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .default_frame = .stack },
        \\};
        \\fn helper(a: u8, b: u16, c: *u8) u16 {
        \\    var x: bool = true;
        \\    var y: usize = 1024;
        \\    return b + y;
        \\}
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const helper = parsed.program.findFunction("helper") orelse return error.TestExpectedEqual;
    var layout = try planFunction(std.testing.allocator, parsed.program, helper, .stack);
    defer layout.deinit(std.testing.allocator);

    try expectSlot(layout, "a", .param, 0, 1);
    try expectSlot(layout, "b", .param, 1, 2);
    try expectSlot(layout, "c", .param, 3, 2);
    try expectSlot(layout, "x", .local, 5, 1);
    try expectSlot(layout, "y", .local, 6, 2);
    try expectSlot(layout, "zeropage_math_tmp", .compiler_scratch, 8, 2);
    try std.testing.expectEqual(@as(u16, 10), layout.byte_size);
}

test "stack frame planner captures hidden for slots and nested call scratch" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .default_frame = .stack },
        \\};
        \\fn add(a: u8, b: u8) u8 { return a + b; }
        \\fn worker(a: u8) u8 {
        \\    var total: u8 = add(add(a, 1), 2);
        \\    for (0..3) |i| {
        \\        total += i;
        \\    }
        \\    return total;
        \\}
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const worker = parsed.program.findFunction("worker") orelse return error.TestExpectedEqual;
    var layout = try planFunction(std.testing.allocator, parsed.program, worker, .stack);
    defer layout.deinit(std.testing.allocator);

    try expectSlot(layout, "a", .param, 0, 1);
    try expectSlot(layout, "total", .local, 1, 1);
    try expectSlot(layout, "worker_for_0_index", .hidden, 2, 2);
    try expectSlot(layout, "i", .hidden, 4, 2);
    try expectSlot(layout, "zeropage_call_arg_0", .compiler_scratch, 6, 2);
    try expectSlot(layout, "zeropage_call_arg_1", .compiler_scratch, 8, 2);
    try expectSlot(layout, "zeropage_math_tmp", .compiler_scratch, 10, 2);
    try std.testing.expectEqual(@as(u16, 12), layout.byte_size);
}

test "stack frame keeps scratch for staged calls and observable layouts" {
    const parser = @import("../../parser.zig");
    const prefix =
        \\const test6502 = @import("test6502");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0100 },
        \\    .abi = .{ .default_frame = .stack, .functions = .{ .main = .{ .frame = .static } } },
        \\};
        \\fn pair(a: u8, b: u16) u16 { if (a == 0) { return 0; } return b; }
        \\fn word(a: u16) u16 { return a; }
        \\fn worker(a: u8, b: u16) u16 {
        \\    const left: u16 = pair(a, b);
        \\    return word(left + 1);
        \\}
        \\fn observe() void {
        \\    asm {
        \\        nop
        \\    }
        \\}
        \\export fn main() void {
        \\    _ = worker(1, 2);
    ;
    for ([_][]const u8{
        prefix ++ "\n}",
        prefix ++ "\n    test6502.expectMemU8(1, 0xc807, 0);\n}",
        prefix ++ "\n    test6502.expectY(1, 0);\n}",
        prefix ++ "\n    observe();\n}",
    }, 0..) |source, index| {
        const parsed = try parser.parseSource(std.testing.allocator, source);
        defer parsed.deinit(std.testing.allocator);
        const worker = parsed.program.findFunction("worker").?;
        const layout = try planFunction(std.testing.allocator, parsed.program, worker, .stack);
        defer layout.deinit(std.testing.allocator);
        try expectSlot(layout, "zeropage_call_arg_0", .compiler_scratch, 5, 2);
        try std.testing.expectEqual(index != 0, layout.findSlot("zeropage_call_arg_1") != null);
        try std.testing.expectEqual(@as(u16, if (index == 0) 7 else 9) + 2, layout.byte_size);
    }
}

test "stack frame planner reserves switch pointer and optional scratch categories" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .default_frame = .stack },
        \\};
        \\fn maybe() ?u8 {
        \\    return 7;
        \\}
        \\fn worker(ptr: *u8, mode: u8) u8 {
        \\    var total: u8 = if (maybe()) |payload| payload else 0;
        \\    total += ptr.*;
        \\    return switch (mode) {
        \\        0 => total,
        \\        else => 1,
        \\    };
        \\}
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const worker = parsed.program.findFunction("worker") orelse return error.TestExpectedEqual;
    var layout = try planFunction(std.testing.allocator, parsed.program, worker, .stack);
    defer layout.deinit(std.testing.allocator);

    try expectSlot(layout, "payload", .hidden, 4, 1);
    try std.testing.expect(layout.findSlot("zeropage_switch_value") != null);
    try std.testing.expect(layout.findSlot("zeropage_ptr_tmp") != null);
    try std.testing.expect(layout.findSlot("zeropage_optional_tmp") != null);
}

test "stack frame planner rejects aggregate stack contents" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .default_frame = .stack },
        \\};
        \\const Point = struct { x: u8, y: u8 };
        \\fn worker(point: Point) u8 { return point.x; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const worker = parsed.program.findFunction("worker") orelse return error.TestExpectedEqual;
    try std.testing.expectError(error.UnsupportedStackFrameAggregate, planFunction(std.testing.allocator, parsed.program, worker, .stack));
}

fn expectSlot(layout: FrameLayout, name: []const u8, kind: FrameSlotKind, offset: u16, size: u16) !void {
    const slot = layout.findSlot(name) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(kind, slot.kind);
    try std.testing.expectEqual(offset, slot.offset);
    try std.testing.expectEqual(size, slot.size);
}
