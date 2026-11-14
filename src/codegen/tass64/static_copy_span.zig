const std = @import("std");
const ast = @import("../../ast.zig");
const stream = @import("stream_copy.zig");
const cfg = @import("cfg_dead_values.zig");
const machine = @import("instruction.zig");
const layout = @import("branch_layout.zig");
const image_layout = @import("unreachable_code.zig");

pub const Copy = struct { source: u16, target: u16, count: u16 };
pub const Report = struct {
    copies: []Copy,
    function_name: []const u8,
    read_spans: usize,
    write_spans: usize,
    steps: usize,

    pub fn deinit(self: Report, allocator: std.mem.Allocator) void {
        allocator.free(self.copies);
    }

    // Function names borrow the caller's Program. Copies are owned separately.
    pub fn absolute(self: Report) ?Absolute {
        if (self.copies.len == 0) return null;
        const first = self.copies[0];
        var min_count = first.count;
        var max_count = first.count;
        for (self.copies) |copy| {
            if (copy.source != first.source or copy.target != first.target or copy.count > 257) return null;
            min_count = @min(min_count, copy.count);
            max_count = @max(max_count, copy.count);
        }
        return .{ .source = first.source, .target = first.target, .min_count = min_count, .max_count = max_count };
    }
};
pub const Absolute = struct { source: u16, target: u16, min_count: u16, max_count: u16 };
const Failure = error{ Unproven, OutOfMemory };
const Pointer = struct { base: u16, many: bool, width: u8 };
const Value = union(enum) { unknown, integer: u16, pointer: Pointer, words: []const ast.Expr };
const Binding = struct { name: []const u8, value: Value, mutable: bool, ty: ?ast.Type };
const LabelOwner = struct { name: []const u8, statement: *const ast.Stmt };
const max_steps = 32768;
pub const IndexedSpan = struct {
    function: []const u8,
    pointer_name: []const u8,
    index_name: []const u8,
    base: u16,
    minimum: u16,
    maximum: u16,
    fixed_base: bool = true,
};

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn nameOf(expr: ast.Expr, name: []const u8) bool {
    return expr == .value and expr.value == .ident and same(expr.value.ident, name);
}
fn simpleReturn(fn_decl: ast.Function, shape: stream.Shape) bool {
    const expr = fn_decl.body[2].return_expr;
    return expr == .add and expr.add.lhs.* == .int_from_ptr and
        nameOf(expr.add.lhs.int_from_ptr.*, shape.target) and nameOf(expr.add.rhs.*, shape.index);
}
fn integer(value: Value) Failure!u16 {
    if (value != .integer) return error.Unproven;
    return value.integer;
}
fn pointer(value: Value) Failure!Pointer {
    if (value != .pointer) return error.Unproven;
    return value.pointer;
}
fn width(ty: ast.PointerType) Failure!u8 {
    if (ty.child != .scalar or ty.is_volatile) return error.Unproven;
    return switch (ty.child.scalar) {
        .u8 => 1,
        .u16, .usize => 2,
        else => error.Unproven,
    };
}

fn atType(value: Value, ty: ast.Type) Failure!Value {
    // The emitter permits some implicit conversions. Only carry facts
    // across a storage or call boundary when their representation is known.
    return switch (ty) {
        .u8, .u16, .usize, .bool => switch (value) {
            .unknown => .unknown,
            .integer => |n| if (ty == .bool and n > 1)
                error.Unproven
            else
                .{ .integer = if (ty == .u8) n & 255 else n },
            else => error.Unproven,
        },
        .pointer => blk: {
            const bytes = try width(ty.pointer);
            const p = try pointer(value);
            if (p.width != bytes or p.many != ty.pointer.is_many) return error.Unproven;
            break :blk value;
        },
        .array => |array| if (value == .words and array.elem == .scalar and
            array.elem.scalar == .u16 and array.len == value.words.len) value else error.Unproven,
        .void => if (value == .unknown) .unknown else error.Unproven,
        else => error.Unproven,
    };
}

const Runner = struct {
    allocator: std.mem.Allocator,
    resident_upper: u32,
    function: ast.Function,
    shape: ?stream.Shape = null,
    wide_program: ?ast.Program = null,
    scope_start: usize = 0,
    bindings: std.ArrayList(Binding) = .empty,
    labels: std.ArrayList(LabelOwner) = .empty,
    copies: std.ArrayList(Copy) = .empty,
    indexed_spans: std.ArrayList(IndexedSpan) = .empty,
    steps: usize = 0,
    reads: usize = 0,
    writes: usize = 0,

    fn claimLabel(self: *Runner, name: []const u8, statement: *const ast.Stmt) Failure!void {
        // Source scopes can reuse names, but emitted static storage is
        // flattened and assembler symbols are case insensitive.
        // The For emitter reserves function_for_ID_index even with a
        // single value capture. Refuse names in that generated family.
        if (name.len >= 10 and std.ascii.eqlIgnoreCase(name[0..4], "for_") and
            std.ascii.eqlIgnoreCase(name[name.len - 6 ..], "_index")) return error.Unproven;
        if (self.wide_program != null) for (self.function.params) |param| {
            if (std.ascii.eqlIgnoreCase(name, param.name)) return error.Unproven;
        };
        for (self.labels.items) |prior| {
            if (!std.ascii.eqlIgnoreCase(name, prior.name)) continue;
            if (prior.statement != statement) return error.Unproven;
            return;
        }
        try self.labels.append(self.allocator, .{ .name = name, .statement = statement });
    }

    fn binding(self: *Runner, name: []const u8) Failure!*Binding {
        var i = self.bindings.items.len;
        while (i != self.scope_start) {
            i -= 1;
            if (same(self.bindings.items[i].name, name)) return &self.bindings.items[i];
        }
        return error.Unproven;
    }

    fn checkSpan(self: *Runner, p: Pointer, offset: u16, size: u32) Failure!void {
        const lo = @as(u32, p.base) + @as(u32, offset) * p.width;
        const hi = lo + size;
        // Match the runtime ordinary-RAM policy, including base page guards.
        // Source effects outside the entire loaded image cannot mutate literal
        // bindings, induction counters, count tables or the compiler's scratch.
        if (lo >> 8 <= self.resident_upper >> 8 or lo < 0x200 or hi >= 0x8000) return error.Unproven;
    }

    fn physical(self: *Runner, p: Pointer, offset: u16, size: u32, is_write: bool) Failure!void {
        try self.checkSpan(p, offset, size);
        if (is_write) self.writes += 1 else self.reads += 1;
    }

    fn indexed(self: *Runner, name: []const u8, index: ast.Expr, is_write: bool) Failure!void {
        const offset = try integer(try self.value(index, null));
        const p = try pointer((try self.binding(name)).value);
        if (!p.many) return error.Unproven;
        try self.physical(p, offset, p.width, is_write);
        if (self.wide_program == null or p.width != 1 or index != .value or index.value != .ident) return;
        const index_name = index.value.ident;
        const ty = (try self.binding(index_name)).ty orelse return;
        if (ty != .u16 and ty != .usize) return;
        for (self.indexed_spans.items) |*span| {
            if (!same(span.function, self.function.name) or !same(span.pointer_name, name) or !same(span.index_name, index_name)) continue;
            span.fixed_base = span.fixed_base and span.base == p.base;
            span.minimum = @min(span.minimum, offset);
            span.maximum = @max(span.maximum, offset);
            return;
        }
        try self.indexed_spans.append(self.allocator, .{
            .function = self.function.name,
            .pointer_name = name,
            .index_name = index_name,
            .base = p.base,
            .minimum = offset,
            .maximum = offset,
        });
    }

    fn value(self: *Runner, expr: ast.Expr, context: ?ast.Type) Failure!Value {
        return switch (expr) {
            .value => |v| switch (v) {
                .int => |n| .{ .integer = n },
                .bool => |b| .{ .integer = @intFromBool(b) },
                .ident => |n| (try self.binding(n)).value,
                else => error.Unproven,
            },
            .ptr_from_int => |child| blk: {
                const ty = context orelse return error.Unproven;
                if (ty != .pointer) return error.Unproven;
                const base = if (self.wide_program != null) try integer(try self.value(child.*, .usize)) else if (child.* == .value and child.value == .int) child.value.int else return error.Unproven;
                const p: Pointer = .{ .base = base, .many = ty.pointer.is_many, .width = try width(ty.pointer) };
                try self.checkSpan(p, 0, p.width);
                break :blk .{ .pointer = p };
            },
            .int_from_ptr => |child| .{ .integer = (try pointer(try self.value(child.*, null))).base },
            .deref => |child| blk: {
                const p = try pointer(try self.value(child.*, null));
                if (p.many) return error.Unproven;
                try self.physical(p, 0, p.width, false);
                break :blk .unknown;
            },
            .array_index => |index| blk: {
                try self.indexed(index.name, index.index.*, false);
                break :blk .unknown;
            },
            .array_literal => |literal| blk: {
                const ty = literal.ty orelse return error.Unproven;
                if (ty.elem != .scalar or ty.elem.scalar != .u16 or ty.len > 127 or ty.len != literal.values.len) return error.Unproven;
                for (literal.values) |item| if (item != .value or item.value != .int) return error.Unproven;
                break :blk .{ .words = literal.values };
            },
            .add, .eq, .lt => |binary| blk: {
                const left = try self.value(binary.lhs.*, null);
                const right = try self.value(binary.rhs.*, null);
                if (left != .integer or right != .integer) break :blk .unknown;
                if (expr == .add) break :blk if (self.wide_program != null and context != null and (context.? == .usize or context.? == .u16))
                    .{ .integer = left.integer +% right.integer }
                else
                    .unknown;
                break :blk .{ .integer = @intFromBool(if (expr == .eq) left.integer == right.integer else left.integer < right.integer) };
            },
            .gte, .shr, .sub, .bit_and, .bit_or, .bit_xor, .bool_and => |binary| blk: {
                if (self.wide_program == null) return error.Unproven;
                const left = try self.value(binary.lhs.*, null);
                if (expr == .bool_and) {
                    if (try integer(left) == 0) break :blk .{ .integer = 0 };
                    const right = try self.value(binary.rhs.*, null);
                    break :blk if (right == .integer) .{ .integer = @intFromBool(right.integer != 0) } else .unknown;
                }
                const right = try self.value(binary.rhs.*, null);
                // These data operations contribute their operand effects
                // without authorizing any derived address or control value.
                if (expr != .gte) break :blk .unknown;
                if (left != .integer or right != .integer) break :blk .unknown;
                break :blk .{ .integer = @intFromBool(left.integer >= right.integer) };
            },
            .if_expr => |branch| blk: {
                if (branch.payload_name != null) return error.Unproven;
                const cond = try integer(try self.value(branch.condition.*, null));
                break :blk self.value(if (cond != 0) branch.then_expr.* else branch.else_expr.*, context);
            },
            .call => |invoke| self.call(invoke),
            else => error.Unproven,
        };
    }

    fn call(self: *Runner, expression: ast.CallExpr) Failure!Value {
        if (self.wide_program != null) return self.callLeaf(expression);
        const shape = self.shape.?;
        if (!same(expression.target, self.function.name) or expression.args.len != 3) return error.Unproven;
        var copy: Copy = undefined;
        for (self.function.params, expression.args) |param, argument| {
            const arg = try atType(try self.value(argument, param.ty), param.ty);
            if (same(param.name, shape.count)) {
                copy.count = try integer(arg);
            } else {
                const p = try pointer(arg);
                if (!p.many or p.width != 1) return error.Unproven;
                if (same(param.name, shape.source)) copy.source = p.base else copy.target = p.base;
            }
        }
        if (copy.count != 0) {
            try self.physical(.{ .base = copy.source, .many = true, .width = 1 }, 0, copy.count, false);
            try self.physical(.{ .base = copy.target, .many = true, .width = 1 }, 0, copy.count, true);
        }
        try self.copies.append(self.allocator, copy);
        return atType(.{ .integer = copy.target +% copy.count }, self.function.return_type);
    }

    fn callLeaf(self: *Runner, expression: ast.CallExpr) Failure!Value {
        if (!same(self.function.name, "main")) return error.Unproven;
        const function = self.wide_program.?.findFunction(expression.target) orelse return error.Unproven;
        if (function.exported or same(function.name, "main") or expression.args.len != function.params.len or function.params.len > 16)
            return error.Unproven;
        switch (function.return_type) {
            .void, .u8, .u16, .usize, .bool => {},
            else => return error.Unproven,
        }
        var arguments: [16]Binding = undefined;
        for (function.params, expression.args, 0..) |param, argument, i| {
            switch (param.ty) {
                .u8, .u16, .usize, .bool, .pointer => {},
                else => return error.Unproven,
            }
            const argument_value = try atType(try self.value(argument, param.ty), param.ty);
            arguments[i] = .{ .name = param.name, .value = argument_value, .mutable = false, .ty = param.ty };
        }
        const caller = self.function;
        const start = self.bindings.items.len;
        self.function = function;
        self.scope_start = start;
        defer {
            self.bindings.shrinkRetainingCapacity(start);
            self.function = caller;
            self.scope_start = 0;
        }
        try self.bindings.appendSlice(self.allocator, arguments[0..function.params.len]);
        return atType((try self.runBlock(function.body)) orelse .unknown, function.return_type);
    }

    fn declare(self: *Runner, stmt: ast.VarDecl) Failure!void {
        var evaluated = try self.value(stmt.init, stmt.ty);
        if (stmt.ty) |ty| evaluated = try atType(evaluated, ty);
        if (evaluated == .words and stmt.mutable) return error.Unproven;
        if (stmt.mutable and (stmt.ty == null or (stmt.ty.? != .u8 and stmt.ty.? != .u16 and stmt.ty.? != .usize and
            (self.wide_program == null or stmt.ty.? != .pointer)))) return error.Unproven;
        try self.bindings.append(self.allocator, .{ .name = stmt.name, .value = evaluated, .mutable = stmt.mutable, .ty = stmt.ty });
    }

    fn set(self: *Runner, name: []const u8, input: Value) Failure!void {
        const slot = try self.binding(name);
        if (!slot.mutable) return error.Unproven;
        slot.value = try atType(input, slot.ty orelse return error.Unproven);
    }

    fn checkExpr(self: *Runner, expression: ast.Expr) Failure!void {
        switch (expression) {
            .value => |literal| switch (literal) {
                .int, .bool, .ident => {},
                else => return error.Unproven,
            },
            .ptr_from_int, .int_from_ptr, .deref => |child| try self.checkExpr(child.*),
            .array_index => |index| try self.checkExpr(index.index.*),
            .array_literal => |literal| for (literal.values) |child| try self.checkExpr(child),
            .add, .eq, .lt => |binary| {
                try self.checkExpr(binary.lhs.*);
                try self.checkExpr(binary.rhs.*);
            },
            .gte, .shr, .sub, .bit_and, .bit_or, .bit_xor, .bool_and => |binary| {
                if (self.wide_program == null) return error.Unproven;
                try self.checkExpr(binary.lhs.*);
                try self.checkExpr(binary.rhs.*);
            },
            .if_expr => |conditional| {
                if (conditional.payload_name != null) return error.Unproven;
                try self.checkExpr(conditional.condition.*);
                try self.checkExpr(conditional.then_expr.*);
                try self.checkExpr(conditional.else_expr.*);
            },
            .call => |invoke| {
                if (self.wide_program) |program| {
                    if (!same(self.function.name, "main") or same(invoke.target, "main") or program.findFunction(invoke.target) == null)
                        return error.Unproven;
                } else if (!same(invoke.target, self.function.name) or invoke.args.len != 3) return error.Unproven;
                for (invoke.args) |argument| try self.checkExpr(argument);
            },
            else => return error.Unproven,
        }
    }

    fn registerBlock(self: *Runner, statements: []const ast.Stmt) Failure!void {
        for (statements) |*statement| switch (statement.*) {
            .var_decl => |decl| {
                try self.claimLabel(decl.name, statement);
                try self.checkExpr(decl.init);
            },
            .assign => |assign| try self.checkExpr(assign.value),
            .call => |invoke| try self.checkExpr(.{ .call = invoke }),
            .discard => |discarded| try self.checkExpr(discarded),
            .add_assign => |assign| try self.checkExpr(assign.value),
            .array_assign => |assign| {
                try self.checkExpr(assign.index);
                try self.checkExpr(assign.value);
            },
            .deref_assign => |assign| {
                try self.checkExpr(assign.target);
                try self.checkExpr(assign.value);
            },
            .for_stmt => |loop| {
                if (loop.source != .array or loop.index_name != null) return error.Unproven;
                try self.claimLabel(loop.item_name orelse return error.Unproven, statement);
                try self.registerBlock(loop.body);
            },
            .while_stmt => |loop| {
                try self.checkExpr(loop.condition);
                try self.registerBlock(loop.body);
            },
            .return_expr => |expression| {
                if (self.wide_program == null or same(self.function.name, "main")) return error.Unproven;
                try self.checkExpr(expression);
            },
            .test6502 => |hook| switch (hook) {
                .expect_equal_u8, .expect_equal_u16, .expect_equal_bool => |expect| try self.checkExpr(expect.actual),
                .pass => {},
                else => return error.Unproven,
            },
            else => return error.Unproven,
        };
    }

    fn runBlock(self: *Runner, statements: []const ast.Stmt) Failure!?Value {
        const depth = self.bindings.items.len;
        defer self.bindings.shrinkRetainingCapacity(depth);
        for (statements) |stmt| {
            self.steps += 1;
            if (self.steps > max_steps) return error.Unproven;
            switch (stmt) {
                .var_decl => |decl| try self.declare(decl),
                .assign => |assign| {
                    const ty = if (self.wide_program != null) (try self.binding(assign.name)).ty else null;
                    try self.set(assign.name, try self.value(assign.value, ty));
                },
                .call => |invoke| _ = try self.call(invoke),
                .discard => |discarded| _ = try self.value(discarded, null),
                .add_assign => |assign| {
                    const slot = try self.binding(assign.name);
                    const left = try integer(slot.value);
                    const right = try integer(try self.value(assign.value, null));
                    try self.set(assign.name, .{ .integer = left +% right });
                },
                .array_assign => |assign| {
                    _ = try self.value(assign.value, null);
                    try self.indexed(assign.name, assign.index, true);
                },
                .deref_assign => |assign| {
                    _ = try self.value(assign.value, null);
                    if (assign.target != .deref) return error.Unproven;
                    const p = try pointer(try self.value(assign.target.deref.*, null));
                    if (p.many) return error.Unproven;
                    try self.physical(p, 0, p.width, true);
                },
                .for_stmt => |loop| {
                    if (loop.source != .array or loop.index_name != null) return error.Unproven;
                    const item = loop.item_name orelse return error.Unproven;
                    const array = (try self.binding(loop.source.array)).value;
                    if (array != .words) return error.Unproven;
                    for (array.words) |element| {
                        const saved = self.bindings.items.len;
                        defer self.bindings.shrinkRetainingCapacity(saved);
                        try self.bindings.append(self.allocator, .{ .name = item, .value = .{ .integer = element.value.int }, .mutable = false, .ty = .u16 });
                        if (try self.runBlock(loop.body)) |returned| return returned;
                    }
                },
                .while_stmt => |loop| {
                    if (loop.body.len == 0 or loop.condition != .lt) return error.Unproven;
                    const left = loop.condition.lt.lhs.*;
                    const right = loop.condition.lt.rhs.*;
                    if (left != .value or left.value != .ident or right != .value) return error.Unproven;
                    const counter = try self.binding(left.value.ident);
                    if (!counter.mutable or (counter.ty.? != .u16 and counter.ty.? != .usize)) return error.Unproven;
                    switch (right.value) {
                        .int => {},
                        .ident => |name| if ((try self.binding(name)).mutable) return error.Unproven,
                        else => return error.Unproven,
                    }
                    while (try integer(try self.value(loop.condition, null)) != 0) {
                        if (try self.runBlock(loop.body)) |returned| return returned;
                    }
                },
                .return_expr => |expression| {
                    if (self.wide_program == null) return error.Unproven;
                    return try self.value(expression, self.function.return_type);
                },
                .test6502 => |hook| switch (hook) {
                    .expect_equal_u8, .expect_equal_u16, .expect_equal_bool => |expect| _ = try self.value(expect.actual, null),
                    .pass => {},
                    else => return error.Unproven,
                },
                else => return error.Unproven,
            }
        }
        return null;
    }
};

pub fn prove(a: std.mem.Allocator, program: ast.Program, resident_upper: u32) Failure!Report {
    if (resident_upper < 0x200 or resident_upper >= 0x8000 or program.functions.len != 2 or !stream.allowed(program) or
        program.zeropage_options.abi.functions.len != 0 or program.zeropage_options.image.load_addr < 0x0200 or
        program.zeropage_options.image.entry_addr >= 0x8000) return error.Unproven;
    const main = program.findFunction("main") orelse return error.Unproven;
    if (main.params.len != 0) return error.Unproven;
    const function = for (program.functions) |f| {
        if (!same(f.name, "main")) break f;
    } else return error.Unproven;
    if (function.exported or function.params.len != 3 or function.body.len != 3 or function.body[1] != .while_stmt) return error.Unproven;
    const shape = stream.classify(function, function.body[1].while_stmt) orelse return error.Unproven;
    // This first fixed-input proof expects one actual for each of the three
    // argument roles. A self-copy can share the physical address, but both
    // operands must be declared parameter bindings in the proved shape.
    if (same(shape.source, shape.target) or same(shape.index, shape.source) or same(shape.index, shape.target) or
        same(shape.index, shape.count) or !simpleReturn(function, shape)) return error.Unproven;
    var runner: Runner = .{ .allocator = a, .resident_upper = resident_upper, .function = function, .shape = shape };
    defer runner.bindings.deinit(a);
    defer runner.labels.deinit(a);
    defer runner.copies.deinit(a);
    try runner.registerBlock(main.body);
    _ = try runner.runBlock(main.body);
    if (runner.copies.items.len == 0) return error.Unproven;
    return .{ .copies = try runner.copies.toOwnedSlice(a), .function_name = function.name, .read_spans = runner.reads, .write_spans = runner.writes, .steps = runner.steps };
}

/// Trace admitted main/leaf effects and retain the observed index range for
/// each typed owner, pointer and index. Unknown control or raw aliases reject
/// the proof before any assembly is changed.
pub fn proveIndexed(a: std.mem.Allocator, program: ast.Program, resident_upper: u32) Failure![]IndexedSpan {
    if (resident_upper < 0x200 or resident_upper >= 0x8000 or !stream.allowed(program) or
        program.zeropage_options.abi.functions.len != 0) return error.Unproven;
    const main = program.findFunction("main") orelse return error.Unproven;
    if (main.params.len != 0) return error.Unproven;
    var runner: Runner = .{ .allocator = a, .resident_upper = resident_upper, .function = main, .wide_program = program };
    defer runner.bindings.deinit(a);
    defer runner.labels.deinit(a);
    defer runner.indexed_spans.deinit(a);
    for (program.functions, 0..) |function, i| {
        if (!same(function.name, "main") and function.exported) return error.Unproven;
        for (program.functions[i + 1 ..]) |other| {
            const shorter, const longer = if (function.name.len <= other.name.len)
                .{ function.name, other.name }
            else
                .{ other.name, function.name };
            if (std.ascii.eqlIgnoreCase(shorter, longer[0..shorter.len]) and
                (shorter.len == longer.len or longer[shorter.len] == '_')) return error.Unproven;
        }
        for (function.params, 0..) |param, j| {
            for (function.params[j + 1 ..]) |other| {
                if (std.ascii.eqlIgnoreCase(param.name, other.name)) return error.Unproven;
            }
        }
        runner.function = function;
        runner.labels.clearRetainingCapacity();
        try runner.registerBlock(function.body);
    }
    runner.function = main;
    _ = try runner.runBlock(main.body);
    return try runner.indexed_spans.toOwnedSlice(a);
}

const namespace = "zeropage_static_copy_";
const guarded_namespace = "zeropage_stream_copy_";

fn emitAbsolute(w: *std.Io.Writer, absolute: Absolute, count: []const u8, index: []const u8, done: []const u8) !void {
    const exact_page = absolute.min_count >= 256 and absolute.min_count == absolute.max_count;
    if (!exact_page) {
        if (absolute.max_count >= 256) try w.print("    lda {s}+1\n    bne " ++ namespace ++ "page\n", .{count});
        try w.print(
            \\    ldx {0s}
            \\    beq zeropage_static_copy_zero
            \\    ldy #0
            \\zeropage_static_copy_short:
            \\    lda ${1x:0>4},y
            \\    sta ${2x:0>4},y
            \\    iny
            \\    dex
            \\    bne zeropage_static_copy_short
            \\
        , .{ count, absolute.source, absolute.target });
    }
    if (absolute.max_count >= 256) {
        if (!exact_page) try w.writeAll("    jmp " ++ namespace ++ "finish\n");
        try w.writeAll(namespace ++ "page:\n    ldy #0\n" ++ namespace ++ "full:\n");
        // Four ordered accesses per branch leave a net cycle saving even
        // when every taken back edge crosses a code page.
        const unroll: usize = if (exact_page) 4 else 2;
        for (0..unroll) |_| {
            try w.print("    lda ${0x:0>4},y\n    sta ${1x:0>4},y\n    iny\n", .{ absolute.source, absolute.target });
        }
        try w.writeAll("    bne " ++ namespace ++ "full\n");
        if (absolute.max_count == 257) {
            if (!exact_page) try w.print("    lda {s}\n    beq " ++ namespace ++ "finish\n", .{count});
            try w.print("    lda ${0x:0>4}\n    sta ${1x:0>4}\n    iny\n", .{ absolute.source + 256, absolute.target + 256 });
        }
    }
    if (exact_page) {
        // Keep the index and scratch stores in order. The exit liveness
        // check covers the changed registers and flags. Return with Y zero.
        try w.writeAll(namespace ++ "finish:\n");
        if (absolute.max_count == 256) {
            // The page loop wrapped Y to zero. Last index is $00ff.
            try w.print(
                \\    sty {0s}
                \\    lda #255
                \\    sta zeropage_ptr_value
                \\    ldx #1
                \\    stx {0s}+1
                \\    sty zeropage_ptr_value+1
                \\
            , .{index});
        } else try w.print(
            \\    ldx #1
            \\    stx {0s}
            \\    ldy #0
            \\    sty zeropage_ptr_value
            \\    stx {0s}+1
            \\    stx zeropage_ptr_value+1
            \\
        , .{index});
        const last_target = absolute.target + (absolute.max_count - 1);
        return w.print(
            \\    lda #<${0x:0>4}
            \\    sta zeropage_ptr_tmp
            \\    lda #>${0x:0>4}
            \\    sta zeropage_ptr_tmp+1
            \\
        , .{last_target});
    }
    // The short loop counts bytes in Y, a full page wraps Y to zero,
    // and the optional 257th byte advances it to one.
    // CPY sets carry for the high-byte SBC exactly when DEY needs no
    // borrow. Source arithmetic runs with decimal mode clear.
    try w.print(
        \\zeropage_static_copy_finish:
        \\    sty {1s}
        \\    cpy #1
        \\    dey
        \\    tya
        \\    sta zeropage_ptr_value
        \\    lda {0s}+1
        \\    sta {1s}+1
        \\    sbc #0
        \\    sta zeropage_ptr_value+1
        \\    tax
        \\    tya
        \\    clc
        \\    adc #<${2x:0>4}
        \\    sta zeropage_ptr_tmp
        \\    txa
        \\    adc #>${2x:0>4}
        \\    sta zeropage_ptr_tmp+1
        \\    ldy #0
        \\    jmp {3s}
        \\zeropage_static_copy_zero:
        \\    stx {1s}
        \\    stx {1s}+1
        \\
    , .{ count, index, absolute.target, done });
}

/// Specialize the already validated, allocated and laid-out guarded loop.
/// Recheck the image bound after replacing its body so the proved raw spans
/// are disjoint from both images. Keep the original source label sequence.
pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    if (program.functions.len != 2 or
        std.mem.indexOf(u8, assembly, "\n" ++ guarded_namespace) == null or
        std.ascii.indexOfIgnoreCase(assembly, namespace) != null) return null;
    const upper = (try image_layout.residentUpperBound(a, assembly)) orelse return null;
    const report = prove(a, program, upper) catch |err| switch (err) {
        error.Unproven => return null,
        error.OutOfMemory => return err,
    };
    defer report.deinit(a);
    const absolute = report.absolute() orelse return null;
    const function = program.findFunction(report.function_name).?;
    const shape = stream.classify(function, function.body[1].while_stmt).?;
    const marker = try std.fmt.allocPrint(a, "\n; zeropage_section_begin owner=function:{s} kind=code ", .{function.name});
    defer a.free(marker);
    const section = std.mem.indexOf(u8, assembly, marker) orelse return null;
    const first = (std.mem.indexOfScalarPos(u8, assembly, section + marker.len, '\n') orelse return null) + 1;
    const section_end = std.mem.indexOfPos(u8, assembly, first, "\n; zeropage_section_end ") orelse return null;
    const body = assembly[first..section_end];
    const entry = try std.fmt.allocPrint(a, "{s}:\n", .{function.name});
    defer a.free(entry);
    if (!std.mem.startsWith(u8, body, entry)) return null;
    const bounds = (std.mem.indexOf(u8, body, "\n" ++ guarded_namespace) orelse return null) + 1 + guarded_namespace.len;
    const bounds_label = std.mem.sliceTo(body[bounds..], '\n');
    if (!std.mem.endsWith(u8, bounds_label, "_bounds:")) return null;
    const id = std.fmt.parseInt(usize, bounds_label[0 .. bounds_label.len - "_bounds:".len], 10) catch return null;
    const done = try std.fmt.allocPrint(a, "while_{d}_done", .{id});
    defer a.free(done);
    const exit = try std.fmt.allocPrint(a, "\n{s}:\n", .{done});
    defer a.free(exit);
    const end = first + (std.mem.indexOf(u8, body, exit) orelse return null) + 1;
    // The original return overwrites the loop's accumulator, X and arithmetic
    // flags before using them. Keep the scratch and Y effects regardless.
    const exit_line = std.mem.count(u8, assembly[0..end], "\n");
    if (!try cfg.outputsDeadAfterLine(a, assembly, exit_line, machine.a | machine.x | machine.c | machine.nz | machine.v)) return null;
    const count = try std.fmt.allocPrint(a, "{s}_{s}", .{ function.name, shape.count });
    defer a.free(count);
    const index = try std.fmt.allocPrint(a, "{s}_{s}", .{ function.name, shape.index });
    defer a.free(index);
    const lowered_return = try std.fmt.allocPrint(a,
        \\    ldx {0s}_{1s}+1
        \\    lda {0s}_{1s}
        \\    clc
        \\    adc {2s}
        \\    pha
        \\    txa
        \\    adc {2s}+1
        \\    tax
        \\    pla
        \\    rts
        \\
    , .{ function.name, shape.target, index });
    defer a.free(lowered_return);
    const return_start = end + exit.len - 1;
    const return_body = assembly[return_start..section_end];

    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try out.writer.writeAll(assembly[0..first]);
    try out.writer.writeAll(entry);
    var replaced = std.mem.splitScalar(u8, assembly[first + entry.len .. end], '\n');
    while (replaced.next()) |line| {
        const label = layout.label(line) orelse continue;
        if (std.ascii.indexOfIgnoreCase(assembly[0..first], label) != null or
            std.ascii.indexOfIgnoreCase(assembly[end..], label) != null) return null;
        if (!std.mem.startsWith(u8, label, guarded_namespace)) try out.writer.print("{s}:\n", .{label});
    }
    try emitAbsolute(&out.writer, absolute, count, index, done);
    if (std.mem.startsWith(u8, return_body, lowered_return)) {
        // The admitted calls all pass the same destination and the copy
        // cannot write its parameter slot. Binary ADC is commutative,
        // including C/V. Push and pull the same low result as before.
        try out.writer.writeAll(assembly[end..return_start]);
        try out.writer.print(
            \\    lda {0s}
            \\    clc
            \\    adc #<${1x:0>4}
            \\    pha
            \\    lda {0s}+1
            \\    adc #>${1x:0>4}
            \\    tax
            \\    pla
            \\    rts
            \\
        , .{ index, absolute.target });
        try out.writer.writeAll(assembly[return_start + lowered_return.len ..]);
    } else try out.writer.writeAll(assembly[end..]);
    const candidate_upper = (try image_layout.residentUpperBound(a, out.written())) orelse return null;
    if (candidate_upper >= upper) return null;
    return try out.toOwnedSlice();
}

const TestCopy =
    \\fn transfer(input:[*]u8,output:[*]u8,n:u16)usize {
    \\    var i:u16=0;
    \\    while (i<n) { output[i]=input[i]; i+=1; }
    \\    return @intFromPtr(output)+i;
    \\}
    \\
;
const TestMain =
    \\export fn main()void {
    \\    const s:[*]u8=@ptrFromInt(0x60fd);
    \\    const d:[*]u8=@ptrFromInt(0x68fe);
    \\    const values=[_]u16{0,1,2,255,256,257};
    \\    for (values) |n| {
    \\        var j:u16=0;
    \\        while (j<3) { s[j]=17; j+=1; }
    \\        const result=transfer(s,d,n);
    \\    }
    \\}
    \\
;

test "fixed copy unrolls four bytes only when every retained count is 257" {
    const a = std.testing.allocator;
    for ([_]bool{ true, false }) |exact| {
        const source = try std.mem.replaceOwned(u8, a, TestCopy ++ TestMain, "0,1,2,255,256,257", if (exact) "257,257" else "256,257");
        defer a.free(source);
        const parsed = try parseForTest(a, source);
        defer parsed.deinit(a);
        const assembly = try @import("pipeline.zig").emitProgram(a, parsed.program);
        defer a.free(assembly);
        const loop_start = (std.mem.indexOf(u8, assembly, "zeropage_static_copy_full:\n") orelse return error.TestExpectedEqual);
        const loop_end = (std.mem.indexOfPos(u8, assembly, loop_start, "    bne zeropage_static_copy_full\n") orelse return error.TestExpectedEqual);
        try std.testing.expectEqual(@as(usize, if (exact) 4 else 2), std.mem.count(u8, assembly[loop_start..loop_end], "    iny\n"));
        try std.testing.expectEqual(!exact, std.mem.indexOf(u8, assembly, "    beq zeropage_static_copy_zero\n") != null);
        try std.testing.expectEqual(!exact, std.mem.indexOf(u8, assembly, "    beq zeropage_static_copy_finish\n") != null);
    }
}

fn parseForTest(a: std.mem.Allocator, text: []const u8) !@import("../../parser.zig").ParseResult {
    return @import("../../parser.zig").parseSource(a, text);
}

test "literal caller proof enumerates effects before one fixed-address copy" {
    const a = std.testing.allocator;
    const parsed = try parseForTest(a, TestCopy ++ TestMain);
    defer parsed.deinit(a);
    const report = try prove(a, parsed.program, 0x2000);
    defer report.deinit(a);
    try std.testing.expectEqual(@as(usize, 6), report.copies.len);
    try std.testing.expectEqual(@as(usize, 23), report.write_spans);
    try std.testing.expectEqualDeep(Absolute{ .source = 0x60fd, .target = 0x68fe, .min_count = 0, .max_count = 257 }, report.absolute().?);
    try std.testing.expectError(error.Unproven, prove(a, parsed.program, 0x60ef));
}

test "runtime read and resident write do not establish stable source bindings" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{
        TestCopy ++
            \\export fn main()void {
            \\    const s:[*]u8=@ptrFromInt(0x6000);
            \\    const d:[*]u8=@ptrFromInt(0x6800);
            \\    const input:*u16=@ptrFromInt(0x6100);
            \\    const result=transfer(s,d,input.*);
            \\}
        ,
        TestCopy ++
            \\export fn main()void {
            \\    const s:[*]u8=@ptrFromInt(0x6000);
            \\    const d:[*]u8=@ptrFromInt(0x6800);
            \\    const alias:*u8=@ptrFromInt(0x0900);
            \\    alias.* = 3;
            \\    const result=transfer(s,d,2);
            \\}
        ,
    };
    for (cases) |source| {
        const parsed = try parseForTest(a, source);
        defer parsed.deinit(a);
        try std.testing.expectError(error.Unproven, prove(a, parsed.program, 0x2000));
    }
}

test "copied spans need identical bases and bounded second-page tail for absolute addressing" {
    const a = std.testing.allocator;
    const source = TestCopy ++
        \\export fn main()void {
        \\    const s:[*]u8=@ptrFromInt(0x6000);
        \\    const t:[*]u8=@ptrFromInt(0x6001);
        \\    const d:[*]u8=@ptrFromInt(0x6800);
        \\    const first=transfer(s,d,257);
        \\    const second=transfer(t,d,258);
        \\}
    ;
    const parsed = try parseForTest(a, source);
    defer parsed.deinit(a);
    const report = try prove(a, parsed.program, 0x2000);
    defer report.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), report.copies.len);
    try std.testing.expect(report.absolute() == null);
}

fn allocationProof(a: std.mem.Allocator, program: ast.Program) !void {
    const report = try prove(a, program, 0x2000);
    defer report.deinit(a);
    try std.testing.expectEqual(@as(usize, 6), report.copies.len);
}

test "static span proof releases all partially evaluated binding and copy state" {
    const a = std.testing.allocator;
    const parsed = try parseForTest(a, TestCopy ++ TestMain);
    defer parsed.deinit(a);
    try std.testing.checkAllAllocationFailures(a, allocationProof, .{parsed.program});
}

test "zero-iteration scopes still reserve their flattened machine names" {
    const a = std.testing.allocator;
    const source = TestCopy ++
        \\export fn main()void {
        \\    const s:[*]u8=@ptrFromInt(0x6000);
        \\    const d:[*]u8=@ptrFromInt(0x6800);
        \\    var j:u16=1;
        \\    while (j<1) { const S:[*]u8=@ptrFromInt(0x6100); j+=1; }
        \\    const result=transfer(s,d,257);
        \\}
    ;
    const parsed = try parseForTest(a, source);
    defer parsed.deinit(a);
    try std.testing.expectError(error.Unproven, prove(a, parsed.program, 0x2000));
}

test "discarded returns still contribute their typed copy effects" {
    const a = std.testing.allocator;
    const source = TestCopy ++
        \\export fn main()void {
        \\    const s:[*]u8=@ptrFromInt(0x6000);
        \\    const d:[*]u8=@ptrFromInt(0x6800);
        \\    transfer(s,d,1);
        \\    _ = transfer(s,d,2);
        \\}
    ;
    const parsed = try parseForTest(a, source);
    defer parsed.deinit(a);
    const report = try prove(a, parsed.program, 0x2000);
    defer report.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), report.copies.len);
    try std.testing.expectEqual(@as(u16, 2), report.absolute().?.max_count);
}

test "fixed copy declines noncanonical Boolean selection" {
    const a = std.testing.allocator;
    const parsed = try parseForTest(a, TestCopy ++
        \\export fn main()void {
        \\    const first:[*]u8=@ptrFromInt(0x6000);
        \\    const second:[*]u8=@ptrFromInt(0x6100);
        \\    const dst:[*]u8=@ptrFromInt(0x6800);
        \\    const choose:bool=256;
        \\    const src:[*]u8=if (choose) first else second;
        \\    _=transfer(src,dst,1);
        \\}
    );
    defer parsed.deinit(a);
    try std.testing.expectError(error.Unproven, prove(a, parsed.program, 0x2000));
}

test "fixed copy interprets byte return values at their ABI width" {
    const a = std.testing.allocator;
    const original = TestCopy ++
        \\export fn main()void {
        \\    const src:[*]u8=@ptrFromInt(0x6000);
        \\    const dst:[*]u8=@ptrFromInt(0x6800);
        \\    const first=transfer(src,dst,1);
        \\    const count:u16=if (first==1) 258 else 1;
        \\    _=transfer(src,dst,count);
        \\}
    ;
    const source = try std.mem.replaceOwned(u8, a, original, ")usize", ")u8");
    defer a.free(source);
    const parsed = try parseForTest(a, source);
    defer parsed.deinit(a);
    const report = try prove(a, parsed.program, 0x2000);
    defer report.deinit(a);
    try std.testing.expectEqual(@as(u16, 258), report.copies[1].count);
    try std.testing.expect(report.absolute() == null);
}

test "wide index proof declines pointer reinterpretation and noncanonical Boolean ABI values" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{
        \\export fn main()void {
        \\    const original:[*]u8=@ptrFromInt(0x60fd);
        \\    const narrow:u8=original;
        \\    const target:[*]u8=narrow;
        \\    var i:u16=4608;
        \\    while (i<4612) { target[i]=0x69; i+=1; }
        \\}
        ,
        \\fn choose(flag:bool)u16 { return if (flag) 768 else 256; }
        \\export fn main()void {
        \\    const n:u16=256;
        \\    const target:[*]u8=@ptrFromInt(0x60fd);
        \\    var i:u16=choose(n);
        \\    while (i<769) { target[i]=0x69; i+=1; }
        \\}
        ,
        \\fn choose()bool { return 256; }
        \\export fn main()void {
        \\    const target:[*]u8=@ptrFromInt(0x60fd);
        \\    var i:u16=if (choose()) 768 else 256;
        \\    while (i<769) { target[i]=0x69; i+=1; }
        \\}
        ,
    };
    for (cases) |source| {
        const parsed = try parseForTest(a, source);
        defer parsed.deinit(a);
        try std.testing.expectError(error.Unproven, proveIndexed(a, parsed.program, 0x2000));
    }
}
