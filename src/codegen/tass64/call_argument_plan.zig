const std = @import("std");
const ast = @import("../../ast.zig");
const frame_layout = @import("frame_layout.zig");
const reachability = @import("reachability.zig");
const scalar_eligibility = @import("zero_page_scalars.zig");

pub const Mode = enum { stage_last, direct_with_reload };
pub const Boundary = enum { eligible, unproven, module_abi, nonstatic, external_abi, recursive, opaque_assembly, unknown_call, unsupported_type };
pub const Reason = enum {
    direct,
    boundary,
    arity,
    nonscalar,
    staging_alias,
    parameter_alias,
    final_staged,
    unowned_destination,
    destination_not_ram,
    later_call,
    later_unknown_read,
    later_unknown_write,
    later_unproven_read,
    later_unproven_write,
    later_read_alias,
    later_write_alias,
    later_staging_read,
    later_staging_write,
};

/// Canonical *verified* storage identity, not merely a generated label spelling.
/// identity names one source storage object/alias group; offsets are bytes.
/// Distinct identities may be treated disjoint only with owned_scalar proofs.
pub const Cell = struct {
    identity: []const u8,
    offset: u32 = 0,
    size: u16,
    owned_scalar: bool = false,
    readable_ram: bool = false,
    writable_ram: bool = false,
};
pub const Binding = struct { owner: []const u8, name: []const u8, cell: Cell };
pub const Effects = struct {
    reads: []const Cell = &.{},
    writes: []const Cell = &.{},
    unknown_read: bool = false,
    unknown_write: bool = false,
    calls: bool = false,
    has_opaque_assembly: bool = false,
    /// Source expressions do not describe all lowered helper/scratch accesses.
    /// Such effects can suggest candidates, but cannot authorize rewriting.
    source_only: bool = false,
    owned: bool = false,

    pub fn deinit(self: *Effects, allocator: std.mem.Allocator) void {
        if (self.owned) {
            if (self.reads.len != 0) allocator.free(self.reads);
            if (self.writes.len != 0) allocator.free(self.writes);
        }
    }
};
pub const Options = struct {
    mode: Mode = .stage_last,
    boundary: Boundary = .unproven,
    all_scalar_parameters: bool = false,
    staging_temporaries_disjoint: bool = false,
    staging_temporaries: []const Cell = &.{},
    /// false produces a symbolic candidate only, requiring a later real RAM
    /// proof before code can be rewritten. Defaults must not enable optimism.
    require_ram: bool = true,
};
pub const Argument = struct { direct: bool = false, reason: Reason = .boundary };
pub const Reload = struct { parameter: usize, byte_offset: u16 };
pub const Plan = struct {
    arguments: []Argument,
    direct_count: usize = 0,
    reload: ?Reload = null,
    boundary: Boundary,
    requires_ram_check: bool,
    requires_lowering_check: bool = false,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.arguments);
    }
};

/// The current expression is evaluated exactly once before its store. Only
/// suffix effects can observe or clobber that prematurely written destination.
/// Keep existing temporary indexes/depth; skip copies only for direct entries.
pub fn schedule(allocator: std.mem.Allocator, parameters: []const Cell, effects: []const Effects, options: Options) !Plan {
    const arguments = try allocator.alloc(Argument, effects.len);
    @memset(arguments, .{});
    var result: Plan = .{ .arguments = arguments, .boundary = options.boundary, .requires_ram_check = !options.require_ram };
    for (effects) |effect| result.requires_lowering_check = result.requires_lowering_check or effect.source_only;
    if (options.boundary != .eligible) return result;
    if (parameters.len != effects.len) {
        for (arguments) |*argument| argument.reason = .arity;
        return result;
    }
    if (!options.all_scalar_parameters) {
        for (arguments) |*argument| argument.reason = .nonscalar;
        return result;
    }
    if (!options.staging_temporaries_disjoint or options.staging_temporaries.len < parameters.len) {
        for (arguments) |*argument| argument.reason = .staging_alias;
        return result;
    }
    for (effects) |effect| if (effect.has_opaque_assembly) {
        result.boundary = .opaque_assembly;
        return result;
    };
    for (parameters, 0..) |parameter, index| {
        if (!valid(parameter)) {
            for (arguments) |*argument| argument.reason = .unowned_destination;
            return result;
        }
        for (parameters[0..index]) |prior| if (!disjoint(parameter, prior)) {
            for (arguments) |*argument| argument.reason = .parameter_alias;
            return result;
        };
    }
    const staging = options.staging_temporaries[0..parameters.len];
    for (staging, parameters, 0..) |temporary, parameter, index| {
        if (!valid(temporary) or temporary.size < parameter.size or (options.require_ram and (!temporary.readable_ram or !temporary.writable_ram))) {
            for (arguments) |*argument| argument.reason = .staging_alias;
            return result;
        }
        for (parameters) |destination| if (!disjoint(temporary, destination)) {
            for (arguments) |*argument| argument.reason = .staging_alias;
            return result;
        };
        for (staging[0..index]) |prior| if (!disjoint(temporary, prior)) {
            for (arguments) |*argument| argument.reason = .staging_alias;
            return result;
        };
    }
    for (parameters, arguments, 0..) |parameter, *argument, index| {
        if (options.mode == .stage_last and index + 1 == parameters.len) {
            argument.reason = .final_staged;
            continue;
        }
        if (options.require_ram and (!parameter.writable_ram or (options.mode == .direct_with_reload and index + 1 == parameters.len and !parameter.readable_ram))) {
            argument.reason = .destination_not_ram;
            continue;
        }
        argument.* = .{ .direct = true, .reason = .direct };
        for (effects[index + 1 ..]) |effect| {
            // A known source-call effect set alone is insufficient: callees may
            // clobber compiler argument temporaries at their own nesting depth.
            const failure: ?Reason = if (effect.calls) .later_call else if (effect.unknown_write) .later_unknown_write else if (effect.unknown_read) .later_unknown_read else checkCells(parameter, staging[index], effect, options.require_ram);
            if (failure) |reason| {
                argument.* = .{ .reason = reason };
                break;
            }
        }
        if (argument.direct) result.direct_count += 1;
    }
    if (options.mode == .direct_with_reload and arguments.len != 0 and arguments[arguments.len - 1].direct) {
        result.reload = .{ .parameter = arguments.len - 1, .byte_offset = parameters[parameters.len - 1].size - 1 };
    }
    return result;
}

fn valid(cell: Cell) bool {
    return cell.owned_scalar and cell.identity.len != 0 and cell.size >= 1 and cell.size <= 2 and @as(u64, cell.offset) + cell.size <= std.math.maxInt(u32);
}
fn disjoint(a: Cell, b: Cell) bool {
    if (!valid(a) or !valid(b)) return false;
    if (!std.mem.eql(u8, a.identity, b.identity)) return true;
    return @as(u64, a.offset) + a.size <= b.offset or @as(u64, b.offset) + b.size <= a.offset;
}
fn checkCells(parameter: Cell, temporary: Cell, effect: Effects, require_ram: bool) ?Reason {
    for (effect.reads) |cell| {
        if (require_ram and !cell.readable_ram) return .later_unproven_read;
        if (!disjoint(parameter, cell)) return .later_read_alias;
        if (!disjoint(temporary, cell)) return .later_staging_read;
    }
    for (effect.writes) |cell| {
        if (require_ram and !cell.writable_ram) return .later_unproven_write;
        if (!disjoint(parameter, cell)) return .later_write_alias;
        if (!disjoint(temporary, cell)) return .later_staging_write;
    }
    return null;
}

/// Reuse actual typed eligibility decisions produced with complete parameter
/// storage facts. Never treat missing_definition as a successful owner guard.
/// Caller SCC proof is explicit because exported main has no parameter decision.
pub fn typedBoundary(program: ast.Program, caller_name: []const u8, callee_name: []const u8, decisions: []const scalar_eligibility.Decision, caller_acyclic: bool) Boundary {
    if (program.zeropage_module != null or program.zeropage_options.modules != null) return .module_abi;
    const caller = program.findFunction(caller_name) orelse return .unknown_call;
    const callee = program.findFunction(callee_name) orelse return .unknown_call;
    if (frame_layout.effectivePolicy(program, caller.name) != .static or frame_layout.effectivePolicy(program, callee.name) != .static) return .nonstatic;
    if (program.findFunctionPlacement(caller.name) != null or reachability.rootReason(program, callee) != null) return .external_abi;
    if (!caller_acyclic) return .recursive;
    for (callee.params) |parameter| {
        const width = scalarSize(program, parameter.ty) orelse return .unsupported_type;
        var found: ?scalar_eligibility.Decision = null;
        for (decisions) |decision| {
            if (!std.mem.eql(u8, decision.function_name, callee.name) or !std.mem.eql(u8, decision.parameter_name, parameter.name)) continue;
            if (found != null) return .unproven;
            found = decision;
        }
        const proof = found orelse return .unproven;
        if (proof.size != width) return .unproven;
        switch (proof.reason) {
            .eligible => {},
            .opaque_assembly => return .opaque_assembly,
            .recursive => return .recursive,
            .unknown_call => return .unknown_call,
            .nonstatic => return .nonstatic,
            .module_abi => return .module_abi,
            else => return .unproven,
        }
    }
    return .eligible;
}
fn scalarSize(program: ast.Program, ty: ast.Type) ?u16 {
    return switch (ty) {
        .bool, .u8, .i8 => 1,
        .u16, .i16, .usize, .pointer => 2,
        .custom => |name| if (program.findEnum(name) != null) 1 else null,
        else => null,
    };
}

/// Analyze source effects without lowering or type guessing. Binding identities
/// must be supplied by the ordinary resolver/model. Unknown things stay unknown;
/// no volatile load or argument is evaluated by this analysis.
pub fn expressionEffects(allocator: std.mem.Allocator, program: ast.Program, caller: []const u8, expression: ast.Expr, bindings: []const Binding) !Effects {
    var collector: Collector = .{ .allocator = allocator, .program = program, .caller = caller, .bindings = bindings };
    defer collector.reads.deinit(allocator);
    try collector.expression(expression);
    return .{ .reads = try collector.reads.toOwnedSlice(allocator), .unknown_read = collector.unknown_read, .unknown_write = collector.unknown_write, .calls = collector.calls, .has_opaque_assembly = collector.has_opaque_assembly, .source_only = true, .owned = true };
}
const Collector = struct {
    allocator: std.mem.Allocator,
    program: ast.Program,
    caller: []const u8,
    bindings: []const Binding,
    reads: std.ArrayList(Cell) = .empty,
    unknown_read: bool = false,
    unknown_write: bool = false,
    calls: bool = false,
    has_opaque_assembly: bool = false,

    fn readBinding(self: *Collector, name: []const u8) !void {
        var found: ?Cell = null;
        for (self.bindings) |binding| {
            if (!std.mem.eql(u8, binding.owner, self.caller) or !std.mem.eql(u8, binding.name, name)) continue;
            if (found != null) {
                self.unknown_read = true;
                return;
            }
            found = binding.cell;
        }
        const cell = found orelse {
            self.unknown_read = true;
            return;
        };
        if (!valid(cell)) {
            self.unknown_read = true;
            return;
        }
        try self.reads.append(self.allocator, cell);
    }
    fn expression(self: *Collector, expr: ast.Expr) anyerror!void {
        switch (expr) {
            .value => |value| switch (value) {
                .ident => |name| try self.readBinding(name),
                .field => |field| if (self.program.findEnum(field.base) == null) {
                    self.unknown_read = true;
                },
                .int, .bool, .char, .null, .enum_literal => {},
            },
            inline .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| {
                try self.expression(binary.lhs.*);
                try self.expression(binary.rhs.*);
            },
            .bit_not, .not, .ptr_from_int, .int_from_ptr => |inner| try self.expression(inner.*),
            .as_cast => |cast| try self.expression(cast.expr.*),
            .size_of, .align_of, .offset_of => {},
            .if_expr => |branch| {
                try self.expression(branch.condition.*);
                try self.expression(branch.then_expr.*);
                try self.expression(branch.else_expr.*);
                if (branch.payload_name != null) self.unknown_write = true;
            },
            .switch_expr => |choice| {
                try self.expression(choice.operand.*);
                for (choice.prongs) |prong| {
                    try self.expression(prong.value);
                    if (prong.payload_name != null) self.unknown_write = true;
                }
            },
            .deref => |inner| {
                try self.expression(inner.*);
                self.unknown_read = true;
                self.unknown_write = true; // An IO read may itself have effects.
            },
            .array_index => |index| {
                try self.expression(index.index.*);
                self.unknown_read = true;
                self.unknown_write = true;
            },
            .array_field_index => |index| {
                try self.expression(index.index.*);
                self.unknown_read = true;
                self.unknown_write = true;
            },
            .call => |call| {
                for (call.args) |arg| try self.expression(arg);
                self.calls = true;
                self.unknown_read = true;
                self.unknown_write = true;
            },
            .address_of => self.unknown_read = true,
            .block_expr => |block| {
                self.unknown_read = true;
                self.unknown_write = true;
                self.has_opaque_assembly = self.has_opaque_assembly or containsAssembly(block.body);
            },
            .c64_read_petscii, .c64_wait_petscii, .reu_present, .reu_compare, .reu_heap_alloc, .reu_view, .far_view_materialize, .far_view_materialize_range, .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded, .module_call, .heap_alloc, .array_literal, .struct_literal => {
                self.unknown_read = true;
                self.unknown_write = true;
                self.calls = true;
            },
        }
    }
};

fn containsAssembly(value: anytype) bool {
    const T = @TypeOf(value);
    if (T == ast.InlineAsm) return true;
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => if (pointer.child == u8) false else blk: {
                for (value) |child| if (containsAssembly(child)) break :blk true;
                break :blk false;
            },
            .one => if (pointer.child == u8 or pointer.child == anyopaque) false else containsAssembly(value.*),
            else => false,
        },
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| if (containsAssembly(@field(value, field.name))) break :blk true;
            break :blk false;
        },
        .@"union" => |info| if (info.tag_type != null) switch (value) {
            inline else => |payload| containsAssembly(payload),
        } else false,
        .optional => if (value) |child| containsAssembly(child) else false,
        .array => blk: {
            for (value) |child| if (containsAssembly(child)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

const test_temporaries = [_]Cell{ testCell("call_temporaries", 0, 2), testCell("call_temporaries", 2, 2), testCell("call_temporaries", 4, 2) };
const test_options: Options = .{ .boundary = .eligible, .all_scalar_parameters = true, .staging_temporaries_disjoint = true, .staging_temporaries = &test_temporaries };
fn testCell(identity: []const u8, offset: u32, size: u16) Cell {
    return .{ .identity = identity, .offset = offset, .size = size, .owned_scalar = true, .readable_ram = true, .writable_ram = true };
}

test "first pointer read or call can feed a direct parameter before a distinct static mark" {
    const parameters = [_]Cell{ testCell("callee", 0, 1), testCell("callee", 1, 1) };
    const reads = [_]Cell{testCell("caller", 0, 1)};
    for ([_]Effects{ .{ .unknown_read = true, .unknown_write = true }, .{ .calls = true, .unknown_read = true, .unknown_write = true } }) |first| {
        const effects = [_]Effects{ first, .{ .reads = &reads } };
        var plan = try schedule(std.testing.allocator, &parameters, &effects, test_options);
        defer plan.deinit(std.testing.allocator);
        try std.testing.expect(plan.arguments[0].direct);
        try std.testing.expect(!plan.arguments[1].direct and plan.arguments[1].reason == .final_staged);
        try std.testing.expectEqual(@as(usize, 1), plan.direct_count);
        try std.testing.expect(plan.reload == null and !plan.requires_ram_check);
    }
}

test "later alias high bytes calls unknown reads and writes prevent early stores" {
    const parameters = [_]Cell{ testCell("callee", 0, 2), testCell("callee", 2, 2) };
    const high_byte = [_]Cell{testCell("callee", 1, 1)};
    for ([_]Effects{
        .{ .reads = &high_byte }, .{ .writes = &high_byte }, .{ .calls = true }, .{ .unknown_read = true }, .{ .unknown_write = true },
    }) |later| {
        var plan = try schedule(std.testing.allocator, &parameters, &.{ .{}, later }, test_options);
        defer plan.deinit(std.testing.allocator);
        try std.testing.expect(!plan.arguments[0].direct);
    }
    const disjoint_byte = [_]Cell{testCell("callee", 5, 1)};
    var plan = try schedule(std.testing.allocator, &parameters, &.{ .{}, .{ .reads = &disjoint_byte, .writes = &disjoint_byte } }, test_options);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(plan.arguments[0].direct);
    try std.testing.expect(!plan.requires_lowering_check);
}

test "direct with reload specifies final word high and requires readable RAM" {
    const parameters = [_]Cell{ testCell("callee", 0, 1), testCell("callee", 1, 2) };
    var options = test_options;
    options.mode = .direct_with_reload;
    var plan = try schedule(std.testing.allocator, &parameters, &.{ .{}, .{} }, options);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), plan.direct_count);
    try std.testing.expectEqual(@as(usize, 1), plan.reload.?.parameter);
    try std.testing.expectEqual(@as(u16, 1), plan.reload.?.byte_offset);
    var hidden = parameters;
    hidden[1].readable_ram = false;
    var fallback = try schedule(std.testing.allocator, &hidden, &.{ .{}, .{} }, options);
    defer fallback.deinit(std.testing.allocator);
    try std.testing.expect(!fallback.arguments[1].direct and fallback.reload == null);
}

test "unproved or aliased storage and mixed aggregates keep the original path" {
    const parameters = [_]Cell{ testCell("callee", 0, 1), testCell("callee", 1, 1) };
    var options = test_options;
    options.staging_temporaries_disjoint = false;
    var aliases = try schedule(std.testing.allocator, &parameters, &.{ .{}, .{} }, options);
    defer aliases.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), aliases.direct_count);
    options = test_options;
    options.all_scalar_parameters = false;
    var aggregate = try schedule(std.testing.allocator, &parameters, &.{ .{}, .{} }, options);
    defer aggregate.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), aggregate.direct_count);
    var same = parameters;
    same[1].offset = 0;
    var shared = try schedule(std.testing.allocator, &same, &.{ .{}, .{} }, test_options);
    defer shared.deinit(std.testing.allocator);
    try std.testing.expectEqual(Reason.parameter_alias, shared.arguments[0].reason);
    var opaque_plan = try schedule(std.testing.allocator, &parameters, &.{ .{ .has_opaque_assembly = true }, .{} }, test_options);
    defer opaque_plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(Boundary.opaque_assembly, opaque_plan.boundary);
    var unowned = parameters;
    unowned[0].writable_ram = false;
    var physical = try schedule(std.testing.allocator, &unowned, &.{ .{}, .{} }, test_options);
    defer physical.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), physical.direct_count);
    options = test_options;
    options.require_ram = false;
    var symbolic = try schedule(std.testing.allocator, &unowned, &.{ .{}, .{} }, options);
    defer symbolic.deinit(std.testing.allocator);
    try std.testing.expect(symbolic.arguments[0].direct and symbolic.requires_ram_check);
}

test "all later arguments are considered while unrelated stages retain order" {
    const parameters = [_]Cell{ testCell("callee", 0, 1), testCell("callee", 1, 1), testCell("callee", 2, 1) };
    const reads = [_]Cell{testCell("callee", 0, 1)};
    var plan = try schedule(std.testing.allocator, &parameters, &.{ .{}, .{}, .{ .reads = &reads } }, test_options);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(!plan.arguments[0].direct);
    try std.testing.expect(plan.arguments[1].direct);
    try std.testing.expect(!plan.arguments[2].direct);
}

test "AST source effects preserve pointer read widths and distinguish suffix calls" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn take(value: u16, mark: u8) u16 { return value + mark; }
        \\fn change(location: *u8) u8 { location.* = 9; return 7; }
        \\fn caller(location: *volatile u16, mark: u8) u16 { return take(location.*, mark + 1); }
        \\fn nested(location: *u8) u16 { return take(1, change(location)); }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);
    const bindings = [_]Binding{
        .{ .owner = "caller", .name = "location", .cell = testCell("caller", 0, 2) },
        .{ .owner = "caller", .name = "mark", .cell = testCell("caller", 2, 1) },
        .{ .owner = "nested", .name = "location", .cell = testCell("nested", 0, 2) },
    };
    const call = parsed.program.findFunction("caller").?.body[0].return_expr.call;
    var first = try expressionEffects(std.testing.allocator, parsed.program, "caller", call.args[0], &bindings);
    defer first.deinit(std.testing.allocator);
    var second = try expressionEffects(std.testing.allocator, parsed.program, "caller", call.args[1], &bindings);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(first.unknown_read and first.reads.len == 1 and first.reads[0].size == 2);
    try std.testing.expect(!second.unknown_read and !second.unknown_write and !second.calls and second.reads.len == 1);
    const nested = parsed.program.findFunction("nested").?.body[0].return_expr.call;
    var later = try expressionEffects(std.testing.allocator, parsed.program, "nested", nested.args[1], &bindings);
    defer later.deinit(std.testing.allocator);
    try std.testing.expect(later.calls and later.unknown_read and later.unknown_write);
    var plan = try schedule(std.testing.allocator, &.{ testCell("take", 0, 2), testCell("take", 2, 1) }, &.{ first, second }, test_options);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(plan.arguments[0].direct);
    try std.testing.expect(plan.requires_lowering_check);
    var fallback = try schedule(std.testing.allocator, &.{ testCell("take", 0, 2), testCell("take", 2, 1) }, &.{ .{}, later }, test_options);
    defer fallback.deinit(std.testing.allocator);
    try std.testing.expect(!fallback.arguments[0].direct);
}

test "typed boundaries reject missing escape recursive and exported evidence" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn leaf(value: u8, other: u8) u8 { return value + other; }
        \\export fn public(value: u8) u8 { return value; }
        \\export fn main() void { _ = leaf(1, 2); }
    );
    defer parsed.deinit(std.testing.allocator);
    const decisions = [_]scalar_eligibility.Decision{
        .{ .label = "leaf_value", .function_name = "leaf", .parameter_name = "value", .size = 1, .reason = .eligible },
        .{ .label = "leaf_other", .function_name = "leaf", .parameter_name = "other", .size = 1, .reason = .eligible },
    };
    try std.testing.expectEqual(Boundary.eligible, typedBoundary(parsed.program, "main", "leaf", &decisions, true));
    try std.testing.expectEqual(Boundary.unproven, typedBoundary(parsed.program, "main", "leaf", &.{}, true));
    try std.testing.expectEqual(Boundary.external_abi, typedBoundary(parsed.program, "main", "public", &.{}, true));
    try std.testing.expectEqual(Boundary.recursive, typedBoundary(parsed.program, "main", "leaf", &decisions, false));
    var escaped = decisions;
    escaped[0].reason = .address_escape;
    try std.testing.expectEqual(Boundary.unproven, typedBoundary(parsed.program, "main", "leaf", &escaped, true));
    escaped[0].reason = .recursive;
    try std.testing.expectEqual(Boundary.recursive, typedBoundary(parsed.program, "main", "leaf", &escaped, true));
}

fn allocationProof(allocator: std.mem.Allocator) !void {
    const expression: ast.Expr = .{ .value = .{ .ident = "mark" } };
    const binding = [_]Binding{.{ .owner = "caller", .name = "mark", .cell = testCell("caller", 0, 1) }};
    var effect = try expressionEffects(allocator, .{ .functions = &.{} }, "caller", expression, &binding);
    defer effect.deinit(allocator);
    var plan = try schedule(allocator, &.{ testCell("callee", 0, 1), testCell("callee", 1, 1) }, &.{ .{}, effect }, test_options);
    defer plan.deinit(allocator);
}
test "effect and schedule ownership survives allocation failure at every point" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProof, .{});
}

test "suffix uses of removed captures and real temporary aliases block scheduling" {
    const parameters = [_]Cell{ testCell("callee", 0, 2), testCell("callee", 2, 1) };
    const temporary = [_]Cell{testCell("call_temporaries", 1, 1)};
    for ([_]Effects{ .{ .reads = &temporary }, .{ .writes = &temporary } }) |later| {
        var plan = try schedule(std.testing.allocator, &parameters, &.{ .{}, later }, test_options);
        defer plan.deinit(std.testing.allocator);
        try std.testing.expect(!plan.arguments[0].direct);
        try std.testing.expect(plan.arguments[0].reason == .later_staging_read or plan.arguments[0].reason == .later_staging_write);
    }
    var options = test_options;
    var bad = test_temporaries;
    bad[0] = parameters[0];
    options.staging_temporaries = &bad;
    var aliased = try schedule(std.testing.allocator, &parameters, &.{ .{}, .{} }, options);
    defer aliased.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), aliased.direct_count);
    bad = test_temporaries;
    bad[0].readable_ram = false;
    options.staging_temporaries = &bad;
    var hidden = try schedule(std.testing.allocator, &parameters, &.{ .{}, .{} }, options);
    defer hidden.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), hidden.direct_count);
}
