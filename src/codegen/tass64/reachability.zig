const std = @import("std");
const ast = @import("../../ast.zig");

/// Explicit externally observable declarations are roots even without callers.
pub fn rootReason(program: ast.Program, function: ast.Function) ?[]const u8 {
    if (std.mem.eql(u8, function.name, "main")) return "entry";
    if (function.exported) return "source_export";
    if (program.zeropage_module) |module| {
        for (module.exports) |entry| {
            if (std.mem.eql(u8, entry.function_name, function.name)) return "module_export";
        }
    }
    if (program.findFunctionPlacement(function.name) != null) return "fixed_placement";
    for (program.zeropage_options.abi.functions) |policy| {
        if (std.mem.eql(u8, policy.name, function.name)) return "explicit_abi_policy";
    }
    return null;
}

pub fn collectProgram(allocator: std.mem.Allocator, program: ast.Program) !std.StringHashMap(void) {
    var reachable = std.StringHashMap(void).init(allocator);
    errdefer reachable.deinit();
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);
    for (program.functions) |function| {
        if (rootReason(program, function) != null) {
            try reachable.put(function.name, {});
            try queue.append(allocator, function.name);
        }
    }
    var index: usize = 0;
    while (index < queue.items.len) : (index += 1) {
        const function = program.findFunction(queue.items[index]) orelse continue;
        try collectReachableCallsFromStmts(allocator, program, function.body, &reachable, &queue);
    }
    return reachable;
}

pub fn collectModule(allocator: std.mem.Allocator, program: ast.Program, module: ast.ZeroPageModule) !std.StringHashMap(void) {
    var reachable = std.StringHashMap(void).init(allocator);
    errdefer reachable.deinit();

    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);

    for (module.exports) |export_decl| {
        const function = program.findFunction(export_decl.function_name) orelse return error.UnknownZeroPageModuleExport;
        if (!reachable.contains(function.name)) {
            try reachable.put(function.name, {});
            try queue.append(allocator, function.name);
        }
    }

    var index: usize = 0;
    while (index < queue.items.len) : (index += 1) {
        const function = program.findFunction(queue.items[index]) orelse continue;
        try collectReachableCallsFromStmts(allocator, program, function.body, &reachable, &queue);
    }
    return reachable;
}

fn collectReachableCallsFromStmts(
    allocator: std.mem.Allocator,
    program: ast.Program,
    statements: []const ast.Stmt,
    reachable: *std.StringHashMap(void),
    queue: *std.ArrayList([]const u8),
) !void {
    for (statements) |stmt| switch (stmt) {
        .var_decl => |decl| try collectReachableCallsFromExpr(allocator, program, decl.init, reachable, queue),
        .assign => |assign| try collectReachableCallsFromExpr(allocator, program, assign.value, reachable, queue),
        inline .add_assign, .sub_assign, .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => |assign| try collectReachableCallsFromExpr(allocator, program, assign.value, reachable, queue),
        .deref_assign => |assign| {
            try collectReachableCallsFromExpr(allocator, program, assign.target, reachable, queue);
            try collectReachableCallsFromExpr(allocator, program, assign.value, reachable, queue);
        },
        .array_assign, .array_add_assign, .array_sub_assign, .array_mul_assign, .array_bit_and_assign, .array_bit_or_assign, .array_bit_xor_assign, .array_shl_assign, .array_shr_assign => |assign| {
            try collectReachableCallsFromExpr(allocator, program, assign.index, reachable, queue);
            try collectReachableCallsFromExpr(allocator, program, assign.value, reachable, queue);
        },
        .array_field_assign => |assign| {
            try collectReachableCallsFromExpr(allocator, program, assign.index, reachable, queue);
            try collectReachableCallsFromExpr(allocator, program, assign.value, reachable, queue);
        },
        .while_stmt => |while_stmt| {
            try collectReachableCallsFromExpr(allocator, program, while_stmt.condition, reachable, queue);
            try collectReachableCallsFromStmts(allocator, program, while_stmt.body, reachable, queue);
        },
        .for_stmt => |for_stmt| try collectReachableCallsFromStmts(allocator, program, for_stmt.body, reachable, queue),
        .switch_stmt => |switch_stmt| {
            try collectReachableCallsFromExpr(allocator, program, switch_stmt.operand, reachable, queue);
            for (switch_stmt.prongs) |prong| try collectReachableCallsFromStmts(allocator, program, prong.body, reachable, queue);
        },
        .if_stmt => |if_stmt| {
            try collectReachableCallsFromExpr(allocator, program, if_stmt.condition, reachable, queue);
            try collectReachableCallsFromStmts(allocator, program, if_stmt.then_body, reachable, queue);
            try collectReachableCallsFromStmts(allocator, program, if_stmt.else_body, reachable, queue);
        },
        .call => |call| try collectReachableCall(allocator, program, call, reachable, queue),
        .discard, .return_expr => |expr| try collectReachableCallsFromExpr(allocator, program, expr, reachable, queue),
        .break_expr => |break_expr| try collectReachableCallsFromExpr(allocator, program, break_expr.value, reachable, queue),
        .field_assign => |field| try collectReachableCallsFromExpr(allocator, program, field.value, reachable, queue),
        .heap_free => |free| try collectReachableCallsFromExpr(allocator, program, free.ptr.*, reachable, queue),
        .builtin => |builtin| try collectReachableCallsFromBuiltin(allocator, program, builtin, reachable, queue),
        .reu => |call| try collectReachableCallsFromReuStmt(allocator, program, call, reachable, queue),
        .test6502 => |call| try collectReachableCallsFromTest6502(allocator, program, call, reachable, queue),
        .struct_var => |struct_var| for (struct_var.fields) |field| try collectReachableCallsFromExpr(allocator, program, field.value, reachable, queue),
        .inline_asm => {
            // Opaque assembly can name source functions directly. Retain them
            // until explicit assembly symbol/escape metadata exists.
            for (program.functions) |function| {
                if (!reachable.contains(function.name)) {
                    try reachable.put(function.name, {});
                    try queue.append(allocator, function.name);
                }
            }
        },
        .string_var, .string_assign, .reu_heap_reset, .heap_reset, .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph, .break_stmt, .continue_stmt => {},
    };
}

fn collectReachableCallsFromExpr(
    allocator: std.mem.Allocator,
    program: ast.Program,
    expr: ast.Expr,
    reachable: *std.StringHashMap(void),
    queue: *std.ArrayList([]const u8),
) anyerror!void {
    switch (expr) {
        .value, .size_of, .align_of, .offset_of, .c64_read_petscii, .c64_wait_petscii, .reu_present, .address_of => {},
        inline .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| {
            try collectReachableCallsFromExpr(allocator, program, binary.lhs.*, reachable, queue);
            try collectReachableCallsFromExpr(allocator, program, binary.rhs.*, reachable, queue);
        },
        .bit_not, .not, .deref, .ptr_from_int, .int_from_ptr => |child| try collectReachableCallsFromExpr(allocator, program, child.*, reachable, queue),
        .as_cast => |as_cast| try collectReachableCallsFromExpr(allocator, program, as_cast.expr.*, reachable, queue),
        .reu_compare => |transfer| try collectReachableCallsFromReuTransfer(allocator, program, transfer, reachable, queue),
        .reu_heap_alloc => |alloc| try collectReachableCallsFromExpr(allocator, program, alloc.len.*, reachable, queue),
        .reu_view => |view| try collectReachableCallsFromExpr(allocator, program, view.far.*, reachable, queue),
        .far_view_materialize => {},
        .far_view_materialize_range => |range| try collectReachableCallsFromExpr(allocator, program, range.start.*, reachable, queue),
        .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded => {},
        .module_call => |call| for (call.args) |arg| try collectReachableCallsFromExpr(allocator, program, arg, reachable, queue),
        .heap_alloc => |alloc| try collectReachableCallsFromExpr(allocator, program, alloc.len.*, reachable, queue),
        .if_expr => |if_expr| {
            try collectReachableCallsFromExpr(allocator, program, if_expr.condition.*, reachable, queue);
            try collectReachableCallsFromExpr(allocator, program, if_expr.then_expr.*, reachable, queue);
            try collectReachableCallsFromExpr(allocator, program, if_expr.else_expr.*, reachable, queue);
        },
        .switch_expr => |switch_expr| {
            try collectReachableCallsFromExpr(allocator, program, switch_expr.operand.*, reachable, queue);
            for (switch_expr.prongs) |prong| try collectReachableCallsFromExpr(allocator, program, prong.value, reachable, queue);
        },
        .block_expr => |block_expr| try collectReachableCallsFromStmts(allocator, program, block_expr.body, reachable, queue),
        .call => |call| try collectReachableCall(allocator, program, call, reachable, queue),
        .array_literal => |literal| for (literal.values) |value| try collectReachableCallsFromExpr(allocator, program, value, reachable, queue),
        .array_index => |index| try collectReachableCallsFromExpr(allocator, program, index.index.*, reachable, queue),
        .array_field_index => |index| try collectReachableCallsFromExpr(allocator, program, index.index.*, reachable, queue),
        .struct_literal => |literal| for (literal.fields) |field| try collectReachableCallsFromExpr(allocator, program, field.value, reachable, queue),
    }
}

fn collectReachableCall(
    allocator: std.mem.Allocator,
    program: ast.Program,
    call: ast.CallExpr,
    reachable: *std.StringHashMap(void),
    queue: *std.ArrayList([]const u8),
) !void {
    if (findFunctionForCall(program, call.target)) |function| {
        if (!reachable.contains(function.name)) {
            try reachable.put(function.name, {});
            try queue.append(allocator, function.name);
        }
    }
    for (call.args) |arg| try collectReachableCallsFromExpr(allocator, program, arg, reachable, queue);
}

fn collectReachableCallsFromBuiltin(
    allocator: std.mem.Allocator,
    program: ast.Program,
    builtin: ast.BuiltinCall,
    reachable: *std.StringHashMap(void),
    queue: *std.ArrayList([]const u8),
) !void {
    switch (builtin) {
        .put_at => |put| try collectReachableCallsFromExpr(allocator, program, put.ch, reachable, queue),
        .hex_at, .hex16_at => |hex| try collectReachableCallsFromExpr(allocator, program, hex.value, reachable, queue),
        .console_print => |print| for (print.args) |arg| if (arg == .value) try collectReachableCallsFromExpr(allocator, program, arg.value, reachable, queue),
        .string_append => {},
        .sleep_ticks, .sleep_frames => |sleep| try collectReachableCallsFromExpr(allocator, program, sleep.ticks, reachable, queue),
        .screen_clear, .puts_at, .console_clear, .console_puts, .string_clear, .kernal_puts, .kernal_set_name => {},
    }
}

fn collectReachableCallsFromReuStmt(
    allocator: std.mem.Allocator,
    program: ast.Program,
    call: ast.ReuStmt,
    reachable: *std.StringHashMap(void),
    queue: *std.ArrayList([]const u8),
) !void {
    switch (call) {
        .copy_c64_to_reu, .copy_reu_to_c64, .swap => |transfer| try collectReachableCallsFromReuTransfer(allocator, program, transfer, reachable, queue),
        .fill => |fill| {
            try collectReachableCallsFromExpr(allocator, program, fill.value.*, reachable, queue);
            try collectReachableCallsFromExpr(allocator, program, fill.len.*, reachable, queue);
        },
        .copy_from_c64, .copy_to_c64 => |copy| {
            try collectReachableCallsFromExpr(allocator, program, copy.far.*, reachable, queue);
            try collectReachableCallsFromExpr(allocator, program, copy.c64_addr.*, reachable, queue);
            try collectReachableCallsFromExpr(allocator, program, copy.len.*, reachable, queue);
        },
    }
}

fn collectReachableCallsFromReuTransfer(
    allocator: std.mem.Allocator,
    program: ast.Program,
    transfer: ast.ReuTransfer,
    reachable: *std.StringHashMap(void),
    queue: *std.ArrayList([]const u8),
) !void {
    try collectReachableCallsFromExpr(allocator, program, transfer.c64_addr.*, reachable, queue);
    try collectReachableCallsFromExpr(allocator, program, transfer.len.*, reachable, queue);
}

fn collectReachableCallsFromTest6502(
    allocator: std.mem.Allocator,
    program: ast.Program,
    call: ast.Test6502Call,
    reachable: *std.StringHashMap(void),
    queue: *std.ArrayList([]const u8),
) !void {
    switch (call) {
        .expect_null => |expect| try collectReachableCallsFromExpr(allocator, program, expect.actual, reachable, queue),
        .expect_some_u8, .expect_some_u16, .expect_some_bool, .expect_some_ptr, .expect_equal_u8, .expect_equal_i8, .expect_equal_bool, .expect_equal_u16 => |expect| try collectReachableCallsFromExpr(allocator, program, expect.actual, reachable, queue),
        .mark, .prime_regs, .hit, .expect_hit_count, .snapshot, .expect_string, .expect_a, .expect_x, .expect_y, .expect_sp, .expect_p, .expect_mem_u8, .expect_mem_u16, .expect_stack_u8, .pass, .fail => {},
    }
}

pub fn findFunctionForCall(program: ast.Program, target: []const u8) ?ast.Function {
    for (program.functions) |function| {
        if (functionNameMatchesCallTarget(function.name, target)) return function;
    }
    return null;
}

fn functionNameMatchesCallTarget(function_name: []const u8, target: []const u8) bool {
    if (function_name.len != target.len) return false;
    for (target, 0..) |ch, index| {
        const expected = if (ch == '.') '_' else ch;
        if (function_name[index] != expected) return false;
    }
    return true;
}

test "program closure traverses every call argument and preserves source exports" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn identity(value: u8) u8 { return value; }
        \\fn first() u8 { return 1; }
        \\fn second() u8 { return 2; }
        \\fn dead() u8 { return 9; }
        \\export fn externalEntry() u8 { return 3; }
        \\export fn main() void {
        \\    _ = identity(first());
        \\    _ = identity(second());
        \\}
    );
    defer parsed.deinit(std.testing.allocator);
    var live = try collectProgram(std.testing.allocator, parsed.program);
    defer live.deinit();
    for ([_][]const u8{ "main", "externalEntry", "identity", "first", "second" }) |name| try std.testing.expect(live.contains(name));
    try std.testing.expect(!live.contains("dead"));
}

test "module exports are roots without a resident caller and recursive closure terminates" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_module = .{ .id = "closure", .abi = 1, .exports = .{ .entry = entry }, .deps = .{} };
        \\fn leaf() u8 { return 1; }
        \\fn identity(value: u8) u8 { return value; }
        \\fn entry() u8 { return identity(leaf()); }
        \\fn dead() u8 { return dead(); }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);
    var live = try collectModule(std.testing.allocator, parsed.program, parsed.program.zeropage_module.?);
    defer live.deinit();
    try std.testing.expectEqual(@as(u32, 3), live.count());
    for ([_][]const u8{ "entry", "identity", "leaf" }) |name| try std.testing.expect(live.contains(name));
    try std.testing.expect(!live.contains("main"));
    var entry = parsed.program;
    entry.zeropage_module = null;
    // Root a recursive cycle explicitly to prove graph visitation terminates.
    entry.functions[3].exported = true;
    var recursive = try collectProgram(std.testing.allocator, entry);
    defer recursive.deinit();
    try std.testing.expect(recursive.contains("dead"));
}

test "reachable opaque assembly conservatively keeps source symbols" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn fromAssembly() u8 { return 3; }
        \\export fn main() void {
        \\    asm {
        \\        jsr fromAssembly
        \\    }
        \\}
    );
    defer parsed.deinit(std.testing.allocator);
    var live = try collectProgram(std.testing.allocator, parsed.program);
    defer live.deinit();
    try std.testing.expect(live.contains("fromAssembly"));
}

test "explicit placement and ABI policy retain address-visible declarations" {
    var functions = [_]ast.Function{
        .{ .name = "main", .exported = true, .params = &.{}, .return_type = .void, .body = &.{} },
        .{ .name = "placed", .exported = false, .params = &.{}, .return_type = .void, .body = &.{} },
        .{ .name = "configured", .exported = false, .params = &.{}, .return_type = .void, .body = &.{} },
        .{ .name = "dead", .exported = false, .params = &.{}, .return_type = .void, .body = &.{} },
    };
    var placements = [_]ast.MemoryPlacement{.{ .name = "fixed", .region_name = "code", .functions = &.{"placed"} }};
    var policies = [_]ast.FunctionFramePolicy{.{ .name = "configured", .frame = .stack }};
    const program = ast.Program{ .functions = &functions, .zeropage_options = .{
        .memory = .{ .placements = &placements },
        .abi = .{ .functions = &policies },
    } };
    var live = try collectProgram(std.testing.allocator, program);
    defer live.deinit();
    try std.testing.expect(live.contains("placed"));
    try std.testing.expect(live.contains("configured"));
    try std.testing.expect(!live.contains("dead"));
    try std.testing.expectEqualStrings("fixed_placement", rootReason(program, functions[1]).?);
}
