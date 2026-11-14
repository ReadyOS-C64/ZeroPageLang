const std = @import("std");
const ast = @import("../../ast.zig");
const frame_layout = @import("frame_layout.zig");
const reachability = @import("reachability.zig");
const placement_domains = @import("placement_domains.zig");

/// Facts must describe definitions in actual pre-allocation static_frame
/// sections. owner is their source function, optionally prefixed "function:".
/// A scalar-looking directive is insufficient without the AST parameter check.
pub const StorageFact = struct {
    label: []const u8,
    owner: []const u8,
    size: u16,
    zero_initialized: bool = false,
    has_aliases: bool = false,
    indexed: bool = false,
    address_escapes: bool = false,
    assembly_sensitive: bool = false,
};
pub const Reason = enum {
    eligible,
    entry,
    exported,
    abi_root,
    fixed_placement,
    module_abi,
    nonstatic,
    not_retained,
    unsupported_type,
    missing_definition,
    duplicate_definition,
    owner_mismatch,
    layout,
    aliased,
    indexed,
    address_escape,
    assembly_sensitive,
    opaque_assembly,
    unknown_call,
    recursive,
    layout_observer,
    unproven_memory_domain,
};
pub const Decision = struct {
    label: []const u8,
    function_name: []const u8,
    parameter_name: []const u8,
    size: u16,
    reason: Reason,

    pub fn eligible(self: Decision) bool {
        return self.reason == .eligible;
    }
};

/// Returned qualified labels are owned; source function/parameter names borrow
/// the AST. Every AST parameter gets one decision, including excluded objects.
pub fn classifyParameters(allocator: std.mem.Allocator, program: ast.Program, facts: []const StorageFact) ![]Decision {
    var graph = try Graph.init(allocator, program, null);
    defer graph.deinit();
    var domains = try placement_domains.analyze(allocator, program);
    defer domains.deinit(allocator);
    var decisions: std.ArrayList(Decision) = .empty;
    errdefer {
        for (decisions.items) |decision| allocator.free(decision.label);
        decisions.deinit(allocator);
    }
    for (program.functions, 0..) |function, index| {
        const owner_reason = graph.ownerReason(index);
        for (function.params) |parameter| {
            const label = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ function.name, parameter.name });
            errdefer allocator.free(label);
            const width = scalarSize(program, parameter.ty);
            var reason = owner_reason orelse if (width == null)
                Reason.unsupported_type
            else
                classifyStorage(function.name, parameter.name, label, width.?, graph.nodes[index], facts);
            // Integerized addresses can observe another frame through an
            // otherwise unrelated base. Until whole-image provenance proves
            // that domain disjoint, keep both placement and argument-copy
            // consumers behind the same retained-program barrier. Preserve
            // every older, more specific exclusion reason.
            if (reason == .eligible and graph.layout_observer) reason = .layout_observer;
            if (reason == .eligible and domains.unproven) reason = .unproven_memory_domain;
            try decisions.append(allocator, .{ .label = label, .function_name = function.name, .parameter_name = parameter.name, .size = width orelse 0, .reason = reason });
        }
    }
    return decisions.toOwnedSlice(allocator);
}

pub fn freeDecisions(allocator: std.mem.Allocator, decisions: []Decision) void {
    for (decisions) |decision| allocator.free(decision.label);
    allocator.free(decisions);
}

pub const DirectCallSite = struct { caller: []const u8, argument: []const u8 };
const SiteCount = struct { seen: bool = false, site: ?DirectCallSite = null };

/// One entry per source function. Count actual retained source sites before
/// deduplicating call-graph edges, and keep only a plain one-argument call.
pub fn singleDirectCalls(allocator: std.mem.Allocator, program: ast.Program) ![]?DirectCallSite {
    const counts = try allocator.alloc(SiteCount, program.functions.len);
    defer allocator.free(counts);
    @memset(counts, .{});
    var graph = try Graph.init(allocator, program, counts);
    defer graph.deinit();
    const result = try allocator.alloc(?DirectCallSite, counts.len);
    for (counts, result, 0..) |count, *site, index| {
        site.* = if (graph.ownerReason(index) == null and !graph.layout_observer) count.site else null;
    }
    return result;
}

fn scalarSize(program: ast.Program, ty: ast.Type) ?u16 {
    return switch (ty) {
        .bool, .u8, .i8 => 1,
        .u16, .i16, .usize, .pointer => 2,
        .custom => |name| if (program.findEnum(name) != null) 1 else null,
        else => null,
    };
}

fn classifyStorage(function_name: []const u8, parameter_name: []const u8, label: []const u8, width: u16, node: Node, facts: []const StorageFact) Reason {
    var found: ?StorageFact = null;
    for (facts) |fact| {
        if (!std.mem.eql(u8, fact.label, label)) continue;
        if (found != null) return .duplicate_definition;
        found = fact;
    }
    const fact = found orelse return .missing_definition;
    const owner = if (std.mem.startsWith(u8, fact.owner, "function:")) fact.owner["function:".len..] else fact.owner;
    if (!std.mem.eql(u8, owner, function_name)) return .owner_mismatch;
    if (fact.size != width or !fact.zero_initialized) return .layout;
    if (fact.has_aliases) return .aliased;
    if (fact.indexed) return .indexed;
    if (fact.address_escapes) return .address_escape;
    for (node.addresses.items) |address| if (std.mem.eql(u8, address, parameter_name)) return .address_escape;
    if (fact.assembly_sensitive) return .assembly_sensitive;
    return .eligible;
}

const Node = struct {
    calls: std.ArrayList(usize) = .empty,
    addresses: std.ArrayList([]const u8) = .empty,
    in_assembly: bool = false,
    unknown: bool = false,
    unknown_reachable: bool = false,
    recursive: bool = false,
    layout_observer: bool = false,
};

const Graph = struct {
    allocator: std.mem.Allocator,
    program: ast.Program,
    nodes: []Node,
    retained: std.StringHashMap(void),
    opaque_retained: bool = false,
    layout_observer: bool = false,
    sites: ?[]SiteCount = null,

    fn init(allocator: std.mem.Allocator, program: ast.Program, sites: ?[]SiteCount) !Graph {
        var retained = try reachability.collectProgram(allocator, program);
        errdefer retained.deinit();
        const nodes = try allocator.alloc(Node, program.functions.len);
        for (nodes) |*node| node.* = .{};
        var graph: Graph = .{ .allocator = allocator, .program = program, .nodes = nodes, .retained = retained, .sites = sites };
        errdefer {
            for (graph.nodes) |*node| {
                node.calls.deinit(allocator);
                node.addresses.deinit(allocator);
            }
            allocator.free(nodes);
        }
        for (program.functions, 0..) |function, index| {
            try graph.statements(index, function.body);
            if (graph.retained.contains(function.name)) {
                if (graph.nodes[index].in_assembly) graph.opaque_retained = true;
                if (graph.nodes[index].layout_observer) graph.layout_observer = true;
            }
        }
        // Program globals currently contain only types, strings and literal
        // array data. Nonliteral scalar array initializers fail emission before
        // optimization (covered below); there is no executable global-init AST.
        // Any future executable initializer must join this retained traversal.
        const visited = try allocator.alloc(bool, nodes.len);
        defer allocator.free(visited);
        const queue = try allocator.alloc(usize, nodes.len);
        defer allocator.free(queue);
        // Each traversal marks only cycle membership for its own start node;
        // an ordinary caller of a recursive SCC is not itself recursive.
        for (nodes, 0..) |*node, start| {
            @memset(visited, false);
            visited[start] = true;
            queue[0] = start;
            var head: usize = 0;
            var tail: usize = 1;
            while (head < tail) : (head += 1) {
                const current = queue[head];
                node.unknown_reachable = node.unknown_reachable or nodes[current].unknown;
                for (nodes[current].calls.items) |callee| {
                    if (callee == start) node.recursive = true;
                    if (visited[callee]) continue;
                    visited[callee] = true;
                    queue[tail] = callee;
                    tail += 1;
                }
            }
        }
        return graph;
    }

    fn deinit(self: *Graph) void {
        for (self.nodes) |*node| {
            node.calls.deinit(self.allocator);
            node.addresses.deinit(self.allocator);
        }
        self.allocator.free(self.nodes);
        self.retained.deinit();
    }

    fn ownerReason(self: Graph, index: usize) ?Reason {
        const function = self.program.functions[index];
        if (self.program.zeropage_module != null or self.program.zeropage_options.modules != null) return .module_abi;
        if (std.mem.eql(u8, function.name, "main")) return .entry;
        if (function.exported) return .exported;
        if (self.program.findFunctionPlacement(function.name) != null) return .fixed_placement;
        for (self.program.zeropage_options.abi.functions) |configured| if (std.mem.eql(u8, configured.name, function.name)) return .abi_root;
        if (frame_layout.effectivePolicy(self.program, function.name) != .static) return .nonstatic;
        if (!self.retained.contains(function.name)) return .not_retained;
        if (self.opaque_retained) return .opaque_assembly;
        if (self.nodes[index].recursive) return .recursive;
        if (self.nodes[index].unknown_reachable) return .unknown_call;
        return null;
    }

    fn call(self: *Graph, owner: usize, value: ast.CallExpr) anyerror!void {
        if (reachability.findFunctionForCall(self.program, value.target)) |function| {
            for (self.program.functions, 0..) |candidate, index| {
                if (!std.mem.eql(u8, function.name, candidate.name)) continue;
                if (self.sites) |sites| {
                    const caller = self.program.functions[owner].name;
                    if (self.retained.contains(caller)) {
                        const count = &sites[index];
                        count.site = if (!count.seen and value.args.len == 1 and
                            value.args[0] == .value and value.args[0].value == .ident)
                            .{ .caller = caller, .argument = value.args[0].value.ident }
                        else
                            null;
                        count.seen = true;
                    }
                }
                if (std.mem.indexOfScalar(usize, self.nodes[owner].calls.items, index) == null) try self.nodes[owner].calls.append(self.allocator, index);
                break;
            }
        } else self.nodes[owner].unknown = true;
        for (value.args) |argument| try self.expression(owner, argument);
    }

    fn statements(self: *Graph, owner: usize, body: []const ast.Stmt) anyerror!void {
        for (body) |statement| switch (statement) {
            .var_decl => |decl| try self.expression(owner, decl.init),
            .assign => |assign| try self.expression(owner, assign.value),
            inline .add_assign, .sub_assign, .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => |assign| try self.expression(owner, assign.value),
            .deref_assign => |assign| {
                try self.expression(owner, assign.target);
                try self.expression(owner, assign.value);
            },
            inline .array_assign, .array_add_assign, .array_sub_assign, .array_mul_assign, .array_bit_and_assign, .array_bit_or_assign, .array_bit_xor_assign, .array_shl_assign, .array_shr_assign, .array_field_assign => |assign| {
                try self.expression(owner, assign.index);
                try self.expression(owner, assign.value);
            },
            .while_stmt => |loop| {
                try self.expression(owner, loop.condition);
                try self.statements(owner, loop.body);
            },
            .for_stmt => |loop| try self.statements(owner, loop.body),
            .switch_stmt => |selection| {
                try self.expression(owner, selection.operand);
                for (selection.prongs) |prong| try self.statements(owner, prong.body);
            },
            .if_stmt => |branch| {
                try self.expression(owner, branch.condition);
                try self.statements(owner, branch.then_body);
                try self.statements(owner, branch.else_body);
            },
            .call => |value| try self.call(owner, value),
            .discard, .return_expr => |value| try self.expression(owner, value),
            .break_expr => |value| try self.expression(owner, value.value),
            .field_assign => |assign| try self.expression(owner, assign.value),
            .heap_free => |free| try self.expression(owner, free.ptr.*),
            .builtin => |value| try self.builtin(owner, value),
            .reu => |value| try self.reu(owner, value),
            .test6502 => |value| try self.testCall(owner, value),
            .struct_var => |record| for (record.fields) |field| try self.expression(owner, field.value),
            .inline_asm => self.nodes[owner].in_assembly = true,
            .string_var, .string_assign, .reu_heap_reset, .heap_reset, .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph, .break_stmt, .continue_stmt => {},
        };
    }

    fn expression(self: *Graph, owner: usize, value: ast.Expr) anyerror!void {
        switch (value) {
            .value, .size_of, .align_of, .offset_of, .c64_read_petscii, .c64_wait_petscii, .reu_present => {},
            .address_of => |address| try self.nodes[owner].addresses.append(self.allocator, address.name),
            inline .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| {
                try self.expression(owner, binary.lhs.*);
                try self.expression(owner, binary.rhs.*);
            },
            .bit_not, .not, .deref => |child| try self.expression(owner, child.*),
            .int_from_ptr => |child| {
                self.nodes[owner].layout_observer = true;
                try self.expression(owner, child.*);
            },
            .ptr_from_int => |child| {
                // A syntactic integer literal is the existing fixed-address
                // ownership contract. Identifiers, casts and expressions are
                // unproved even when a later constant folder could reduce them.
                if (child.* != .value or child.value != .int) self.nodes[owner].layout_observer = true;
                try self.expression(owner, child.*);
            },
            .as_cast => |cast| try self.expression(owner, cast.expr.*),
            .reu_compare => |comparison| try self.transfer(owner, comparison),
            .reu_heap_alloc => |alloc| try self.expression(owner, alloc.len.*),
            .reu_view => |view| try self.expression(owner, view.far.*),
            .far_view_materialize => {},
            .far_view_materialize_range => |range| try self.expression(owner, range.start.*),
            .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded => {},
            .module_call => |target| for (target.args) |argument| try self.expression(owner, argument),
            .heap_alloc => |alloc| try self.expression(owner, alloc.len.*),
            .if_expr => |branch| {
                try self.expression(owner, branch.condition.*);
                try self.expression(owner, branch.then_expr.*);
                try self.expression(owner, branch.else_expr.*);
            },
            .switch_expr => |selection| {
                try self.expression(owner, selection.operand.*);
                for (selection.prongs) |prong| try self.expression(owner, prong.value);
            },
            .block_expr => |block| try self.statements(owner, block.body),
            .call => |target| try self.call(owner, target),
            .array_literal => |array| for (array.values) |element| try self.expression(owner, element),
            inline .array_index, .array_field_index => |index| try self.expression(owner, index.index.*),
            .struct_literal => |record| for (record.fields) |field| try self.expression(owner, field.value),
        }
    }

    fn builtin(self: *Graph, owner: usize, value: ast.BuiltinCall) anyerror!void {
        switch (value) {
            .put_at => |put| try self.expression(owner, put.ch),
            .hex_at, .hex16_at => |hex| try self.expression(owner, hex.value),
            .console_print => |print| for (print.args) |argument| if (argument == .value) try self.expression(owner, argument.value),
            .sleep_ticks, .sleep_frames => |sleep| try self.expression(owner, sleep.ticks),
            .screen_clear, .puts_at, .console_clear, .console_puts, .string_clear, .string_append, .kernal_puts, .kernal_set_name => {},
        }
    }

    fn transfer(self: *Graph, owner: usize, value: ast.ReuTransfer) anyerror!void {
        try self.expression(owner, value.c64_addr.*);
        try self.expression(owner, value.len.*);
    }

    fn reu(self: *Graph, owner: usize, value: ast.ReuStmt) anyerror!void {
        switch (value) {
            .copy_c64_to_reu, .copy_reu_to_c64, .swap => |copy| try self.transfer(owner, copy),
            .fill => |fill| {
                try self.expression(owner, fill.value.*);
                try self.expression(owner, fill.len.*);
            },
            .copy_from_c64, .copy_to_c64 => |copy| {
                try self.expression(owner, copy.far.*);
                try self.expression(owner, copy.c64_addr.*);
                try self.expression(owner, copy.len.*);
            },
        }
    }

    fn testCall(self: *Graph, owner: usize, value: ast.Test6502Call) anyerror!void {
        switch (value) {
            inline .expect_null, .expect_some_u8, .expect_some_u16, .expect_some_bool, .expect_some_ptr, .expect_equal_u8, .expect_equal_i8, .expect_equal_bool, .expect_equal_u16 => |expect| try self.expression(owner, expect.actual),
            .mark, .prime_regs, .hit, .expect_hit_count, .snapshot, .expect_string, .expect_a, .expect_x, .expect_y, .expect_sp, .expect_p, .expect_mem_u8, .expect_mem_u16, .expect_stack_u8, .pass, .fail => {},
        }
    }
};

fn decisionFor(decisions: []const Decision, label: []const u8) Decision {
    for (decisions) |decision| if (std.mem.eql(u8, decision.label, label)) return decision;
    unreachable;
}

fn expectReason(source: []const u8, facts: []const StorageFact, label: []const u8, reason: Reason) !void {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);
    const decisions = try classifyParameters(std.testing.allocator, parsed.program, facts);
    defer freeDecisions(std.testing.allocator, decisions);
    try std.testing.expectEqual(reason, decisionFor(decisions, label).reason);
}

fn expectReasonName(source: []const u8, facts: []const StorageFact, label: []const u8, name: []const u8) !void {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);
    const decisions = try classifyParameters(std.testing.allocator, parsed.program, facts);
    defer freeDecisions(std.testing.allocator, decisions);
    try std.testing.expectEqualStrings(name, @tagName(decisionFor(decisions, label).reason));
}

test "private scalar eligibility supports typed primitives byte enums and pointer values through known DAG calls" {
    const source =
        \\const Color = enum(u8) { a, b };
        \\fn leaf(flag: bool, byte: u8, signed: i8, word: u16, signed_word: i16, index: usize, color: Color, pointer: *u8, volatile_pointer: *volatile u16, many: [*]u8) u8 { return byte; }
        \\fn middle(value: u8) u8 { return leaf(true, value, 1, 2, 3, 4, .a, @ptrFromInt(0xc100), @ptrFromInt(0xc200), @ptrFromInt(0xc300)); }
        \\export fn main() void { _ = middle(7); }
    ;
    const facts = [_]StorageFact{
        .{ .label = "leaf_flag", .owner = "leaf", .size = 1, .zero_initialized = true },
        .{ .label = "leaf_byte", .owner = "function:leaf", .size = 1, .zero_initialized = true },
        .{ .label = "leaf_signed", .owner = "leaf", .size = 1, .zero_initialized = true },
        .{ .label = "leaf_word", .owner = "leaf", .size = 2, .zero_initialized = true },
        .{ .label = "leaf_signed_word", .owner = "leaf", .size = 2, .zero_initialized = true },
        .{ .label = "leaf_index", .owner = "leaf", .size = 2, .zero_initialized = true },
        .{ .label = "leaf_color", .owner = "leaf", .size = 1, .zero_initialized = true },
        .{ .label = "leaf_pointer", .owner = "leaf", .size = 2, .zero_initialized = true },
        .{ .label = "leaf_volatile_pointer", .owner = "leaf", .size = 2, .zero_initialized = true },
        .{ .label = "leaf_many", .owner = "leaf", .size = 2, .zero_initialized = true },
        .{ .label = "middle_value", .owner = "middle", .size = 1, .zero_initialized = true },
    };
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);
    const decisions = try classifyParameters(std.testing.allocator, parsed.program, &facts);
    defer freeDecisions(std.testing.allocator, decisions);
    try std.testing.expectEqual(facts.len, decisions.len);
    for (decisions) |decision| try std.testing.expect(decision.eligible());
    try std.testing.expectEqual(@as(u16, 2), decisionFor(decisions, "leaf_volatile_pointer").size);
}

test "private scalar eligibility rejects aggregate and optional parameters despite scalar looking definitions" {
    const source =
        \\const Record = struct { byte: u8 };
        \\const Choice = union(enum) { empty, byte: u8 };
        \\fn f(record: Record, array: u8, optional: ?u8, choice: Choice) void {}
        \\export fn main() void { f(Record{ .byte = 1 }, 1, 1, Choice{ .byte = 2 }); }
    ;
    const facts = [_]StorageFact{
        .{ .label = "f_record", .owner = "f", .size = 1, .zero_initialized = true },
        .{ .label = "f_array", .owner = "f", .size = 1, .zero_initialized = true },
        .{ .label = "f_optional", .owner = "f", .size = 1, .zero_initialized = true },
        .{ .label = "f_choice", .owner = "f", .size = 1, .zero_initialized = true },
    };
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);
    // Arrays by value are rejected by today's parser. Mutate only this test
    // AST to verify the allowlist still rejects a future one-byte array shape.
    for (parsed.program.functions) |function| if (std.mem.eql(u8, function.name, "f")) {
        function.params[1].ty = .{ .array = .{ .len = 1, .elem = .{ .scalar = .u8 } } };
    };
    const decisions = try classifyParameters(std.testing.allocator, parsed.program, &facts);
    defer freeDecisions(std.testing.allocator, decisions);
    for (decisions) |decision| try std.testing.expectEqual(Reason.unsupported_type, decision.reason);
}

test "private scalar eligibility cross checks frame owner width initialization aliases and addressing facts" {
    const source = "fn f(value: u16) u16 { return value; } export fn main() void { _ = f(1); }";
    const good: StorageFact = .{ .label = "f_value", .owner = "f", .size = 2, .zero_initialized = true };
    try expectReason(source, &.{good}, "f_value", .eligible);
    try expectReason(source, &.{}, "f_value", .missing_definition);
    try expectReason(source, &.{ good, good }, "f_value", .duplicate_definition);
    var fact = good;
    fact.owner = "other";
    try expectReason(source, &.{fact}, "f_value", .owner_mismatch);
    fact = good;
    fact.size = 1;
    try expectReason(source, &.{fact}, "f_value", .layout);
    fact = good;
    fact.zero_initialized = false;
    try expectReason(source, &.{fact}, "f_value", .layout);
    fact = good;
    fact.has_aliases = true;
    try expectReason(source, &.{fact}, "f_value", .aliased);
    fact = good;
    fact.indexed = true;
    try expectReason(source, &.{fact}, "f_value", .indexed);
    fact = good;
    fact.address_escapes = true;
    try expectReason(source, &.{fact}, "f_value", .address_escape);
    fact = good;
    fact.assembly_sensitive = true;
    try expectReason(source, &.{fact}, "f_value", .assembly_sensitive);
}

test "private scalar eligibility scans nested source address escapes but not pointee fields" {
    const fact: StorageFact = .{ .label = "f_value", .owner = "f", .size = 1, .zero_initialized = true };
    try expectReason(
        \\fn f(value: u8) u8 { return blk: { if (value == 1) { _ = &value; } break :blk value; }; }
        \\export fn main() void { _ = f(1); }
    , &.{fact}, "f_value", .address_escape);
    try expectReason(
        \\const Record = struct { byte: u8 };
        \\fn f(value: *Record) u8 { _ = &value.byte; return value.byte; }
        \\export fn main() void { var record = Record{ .byte = 1 }; _ = f(&record); }
    , &.{.{ .label = "f_value", .owner = "f", .size = 2, .zero_initialized = true }}, "f_value", .eligible);
}

test "private scalar eligibility rejects external configured stack module and removed roots" {
    const fact: StorageFact = .{ .label = "f_value", .owner = "f", .size = 1, .zero_initialized = true };
    try expectReason("export fn f(value: u8) u8 { return value; } export fn main() void {}", &.{fact}, "f_value", .exported);
    try expectReason("fn f(value: u8) u8 { return value; } export fn main() void {}", &.{fact}, "f_value", .not_retained);
    try expectReason(
        \\pub const zeropage_options = .{ .abi = .{ .functions = .{ .f = .{ .frame = .static } } } };
        \\fn f(value: u8) u8 { return value; }
        \\export fn main() void { _ = f(1); }
    , &.{fact}, "f_value", .abi_root);
    try expectReason(
        \\pub const zeropage_options = .{ .stack = .{ .base = 0xc800, .size = 0x100 }, .abi = .{ .default_frame = .stack } };
        \\fn f(value: u8) u8 { return value; }
        \\export fn main() void { _ = f(1); }
    , &.{fact}, "f_value", .nonstatic);
    try expectReason(
        \\pub const zeropage_module = .{ .id = "module", .abi = 1, .exports = .{ .f = f }, .deps = .{} };
        \\fn f(value: u8) u8 { return value; }
        \\export fn main() void { _ = f(1); }
    , &.{fact}, "f_value", .module_abi);
}

test "private scalar eligibility detects self and mutual recursion without rejecting known nonleaf DAG callers" {
    const source =
        \\fn self(value: u8) u8 { if (value == 0) { return 0; } return self(value - 1); }
        \\fn left(value: u8) u8 { if (value == 0) { return 0; } return right(value - 1); }
        \\fn right(value: u8) u8 { return left(value); }
        \\fn caller(value: u8) u8 { return left(value); }
        \\export fn main() void { _ = self(1); _ = caller(1); }
    ;
    const facts = [_]StorageFact{
        .{ .label = "self_value", .owner = "self", .size = 1, .zero_initialized = true },
        .{ .label = "left_value", .owner = "left", .size = 1, .zero_initialized = true },
        .{ .label = "right_value", .owner = "right", .size = 1, .zero_initialized = true },
        .{ .label = "caller_value", .owner = "caller", .size = 1, .zero_initialized = true },
    };
    for (facts[0..3]) |fact| try expectReason(source, &facts, fact.label, .recursive);
    try expectReason(source, &facts, "caller_value", .eligible);
}

test "private scalar eligibility propagates unknown calls through nested actual arguments and leaves unrelated helpers eligible" {
    const source =
        \\fn leaf(value: u8) u8 { return value; }
        \\fn unknown(value: u8) u8 { return leaf(unresolved(value)); }
        \\fn caller(value: u8) u8 { return unknown(value); }
        \\export fn main() void { _ = leaf(1); _ = caller(1); }
    ;
    const facts = [_]StorageFact{
        .{ .label = "leaf_value", .owner = "leaf", .size = 1, .zero_initialized = true },
        .{ .label = "unknown_value", .owner = "unknown", .size = 1, .zero_initialized = true },
        .{ .label = "caller_value", .owner = "caller", .size = 1, .zero_initialized = true },
    };
    try expectReason(source, &facts, "leaf_value", .eligible);
    try expectReason(source, &facts, "unknown_value", .unknown_call);
    try expectReason(source, &facts, "caller_value", .unknown_call);
}

test "private scalar eligibility treats only retained opaque assembly as an untyped entry boundary" {
    const fact: StorageFact = .{ .label = "f_value", .owner = "f", .size = 1, .zero_initialized = true };
    try expectReason(
        \\fn f(value: u8) u8 { return value; }
        \\fn unused() void {
        \\    asm {
        \\        nop
        \\    }
        \\}
        \\export fn main() void { _ = f(1); }
    , &.{fact}, "f_value", .eligible);
    try expectReason(
        \\fn f(value: u8) u8 { return value; }
        \\export fn main() void {
        \\    _ = f(1);
        \\    asm {
        \\        nop
        \\    }
        \\}
    , &.{fact}, "f_value", .opaque_assembly);
}

test "private scalar eligibility excludes fixed placements and entry parameters" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, "fn placed(value: u8) u8 { return value; } export fn main(argument: u8) void {}");
    defer parsed.deinit(std.testing.allocator);
    var program = parsed.program;
    var placements = [_]ast.MemoryPlacement{.{ .name = "fixed", .region_name = "code", .functions = &.{"placed"} }};
    program.zeropage_options.memory.placements = &placements;
    const facts = [_]StorageFact{
        .{ .label = "placed_value", .owner = "placed", .size = 1, .zero_initialized = true },
        .{ .label = "main_argument", .owner = "main", .size = 1, .zero_initialized = true },
    };
    const decisions = try classifyParameters(std.testing.allocator, program, &facts);
    defer freeDecisions(std.testing.allocator, decisions);
    try std.testing.expectEqual(Reason.fixed_placement, decisionFor(decisions, "placed_value").reason);
    try std.testing.expectEqual(Reason.entry, decisionFor(decisions, "main_argument").reason);
}

test "private scalar eligibility does not accept far or near view handles as ordinary words" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, "fn f(value: u8) u8 { return value; } export fn main() void { _ = f(1); }");
    defer parsed.deinit(std.testing.allocator);
    const facts = [_]StorageFact{.{ .label = "f_value", .owner = "f", .size = 2, .zero_initialized = true }};
    for ([_]ast.Type{ .void, .far_bytes, .{ .far_view = .{ .type_name = "Record", .count = 1 } }, .{ .near_view = .{ .type_name = "Record", .count = 1 } } }) |unsupported| {
        for (parsed.program.functions) |function| if (std.mem.eql(u8, function.name, "f")) {
            function.params[0].ty = unsupported;
        };
        const decisions = try classifyParameters(std.testing.allocator, parsed.program, &facts);
        defer freeDecisions(std.testing.allocator, decisions);
        try std.testing.expectEqual(Reason.unsupported_type, decisionFor(decisions, "f_value").reason);
    }
}

test "private scalar eligibility releases partially built graphs decisions and qualified names on allocation failure" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn leaf(value: u8) u8 { _ = &value; return value; }
        \\fn caller(value: u8) u8 { return leaf(value); }
        \\export fn main() void { _ = caller(1); }
    );
    defer parsed.deinit(std.testing.allocator);
    const facts = [_]StorageFact{
        .{ .label = "leaf_value", .owner = "leaf", .size = 1, .zero_initialized = true },
        .{ .label = "caller_value", .owner = "caller", .size = 1, .zero_initialized = true },
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: std.mem.Allocator, program: ast.Program, definitions: []const StorageFact) !void {
            const decisions = try classifyParameters(alloc, program, definitions);
            defer freeDecisions(alloc, decisions);
            try std.testing.expectEqual(Reason.address_escape, decisionFor(decisions, "leaf_value").reason);
            try std.testing.expect(decisionFor(decisions, "caller_value").eligible());
        }
    }.run, .{ parsed.program, @as([]const StorageFact, &facts) });
}

test "private scalar layout observer blocks cross base neighbor arithmetic before promotion" {
    const source =
        \\fn alias(value: u8) u8 {
        \\    var next: u8 = 0;
        \\    const pointer: *u8 = @ptrFromInt(@intFromPtr(&next) - 1);
        \\    return pointer.*;
        \\}
        \\export fn main() void { _ = alias(5); }
    ;
    try expectReasonName(source, &.{.{ .label = "alias_value", .owner = "alias", .size = 1, .zero_initialized = true }}, "alias_value", "layout_observer");
}

test "private scalar layout observer applies across all retained owners including parameterless observers" {
    const source =
        \\fn leaf(value: u16) u16 { return value; }
        \\fn observer() void { var local: u8 = 0; _ = @intFromPtr(&local); }
        \\export fn main() void { observer(); _ = leaf(257); }
    ;
    try expectReasonName(source, &.{.{ .label = "leaf_value", .owner = "leaf", .size = 2, .zero_initialized = true }}, "leaf_value", "layout_observer");
}

test "private scalar layout observer distinguishes only literal integer pointer construction" {
    const prefix = "fn f(value: u8) u8 { return value; } ";
    const fact: StorageFact = .{ .label = "f_value", .owner = "f", .size = 1, .zero_initialized = true };
    try expectReasonName(prefix ++ "export fn main() void { const p: *volatile u8 = @ptrFromInt(0xd020); p.* = f(1); }", &.{fact}, "f_value", "eligible");
    try expectReasonName(prefix ++ "export fn main() void { const address: u16 = 0xc100; const p: *u8 = @ptrFromInt(address); p.* = f(1); }", &.{fact}, "f_value", "layout_observer");
    try expectReasonName(prefix ++ "export fn main() void { const p: *u8 = @ptrFromInt(0xc100 + 1); p.* = f(1); }", &.{fact}, "f_value", "layout_observer");
    try expectReasonName(prefix ++ "export fn main() void { const p: *u8 = @ptrFromInt(@as(u16, 0xc100)); p.* = f(1); }", &.{fact}, "f_value", "layout_observer");
    try expectReasonName(prefix ++ "fn unused() void { var local: u8 = 0; _ = @intFromPtr(&local); } export fn main() void { _ = f(1); }", &.{fact}, "f_value", "eligible");
    try expectReasonName(prefix ++ "fn unused(address: u16) void { const p: *u8 = @ptrFromInt(address); _ = p; } export fn main() void { _ = f(1); }", &.{fact}, "f_value", "eligible");
}

test "private scalar layout observer follows nested expression and statement containers" {
    const prefix = "fn f(value: u8) u8 { return value; } ";
    const fact: StorageFact = .{ .label = "f_value", .owner = "f", .size = 1, .zero_initialized = true };
    const bodies = [_][]const u8{
        "var local: u8 = 0; const address: u16 = blk: { if (local == 0) { break :blk @intFromPtr(&local); } break :blk 0; }; _ = address;",
        "var local: u8 = 0; const address: u16 = if (local == 0) @intFromPtr(&local) else 0; _ = address;",
        "var local: u8 = 0; const address: u16 = switch (local) { 0 => @intFromPtr(&local), else => 0 }; _ = address;",
        "var local: u8 = 0; while (local == 1) { _ = @intFromPtr(&local); local = 0; }",
        "var local: u8 = 0; var cells = [_]u16{ @intFromPtr(&local) }; _ = cells[0];",
        "var local: u8 = 0; const pointer: *u8 = @ptrFromInt(if (local == 0) @as(u16, 0xc100) else @as(u16, 0xc101)); _ = pointer;",
    };
    for (bodies) |body| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}export fn main() void {{ {s} _ = f(1); }}", .{ prefix, body });
        defer std.testing.allocator.free(source);
        try expectReasonName(source, &.{fact}, "f_value", "layout_observer");
    }
}

test "private scalar layout observer preserves every existing storage and address exclusion" {
    const source =
        \\fn f(value: u16) u16 { return value; }
        \\export fn main() void { var local: u8 = 0; _ = @intFromPtr(&local); _ = f(1); }
    ;
    const good: StorageFact = .{ .label = "f_value", .owner = "f", .size = 2, .zero_initialized = true };
    try expectReasonName(source, &.{}, "f_value", "missing_definition");
    try expectReasonName(source, &.{ good, good }, "f_value", "duplicate_definition");
    var fact = good;
    fact.owner = "other";
    try expectReasonName(source, &.{fact}, "f_value", "owner_mismatch");
    fact = good;
    fact.size = 1;
    try expectReasonName(source, &.{fact}, "f_value", "layout");
    fact = good;
    fact.has_aliases = true;
    try expectReasonName(source, &.{fact}, "f_value", "aliased");
    fact = good;
    fact.indexed = true;
    try expectReasonName(source, &.{fact}, "f_value", "indexed");
    fact = good;
    fact.address_escapes = true;
    try expectReasonName(source, &.{fact}, "f_value", "address_escape");
    fact = good;
    fact.assembly_sensitive = true;
    try expectReasonName(source, &.{fact}, "f_value", "assembly_sensitive");
    try expectReasonName("fn f(value: u16) u16 { _ = &value; _ = @intFromPtr(&value); return value; } export fn main() void { _ = f(1); }", &.{good}, "f_value", "address_escape");
}

test "private scalar layout observer preserves public module software stack and graph reason precedence" {
    const fact: StorageFact = .{ .label = "f_value", .owner = "f", .size = 1, .zero_initialized = true };
    const entry = "export fn main() void { var local: u8 = 0; _ = @intFromPtr(&local); _ = f(1); }";
    try expectReasonName("export fn f(value: u8) u8 { return value; } " ++ entry, &.{fact}, "f_value", "exported");
    try expectReasonName("pub const zeropage_module = .{ .id = \"m\", .abi = 1, .exports = .{ .f = f }, .deps = .{} }; fn f(value: u8) u8 { return value; } " ++ entry, &.{fact}, "f_value", "module_abi");
    try expectReasonName("pub const zeropage_options = .{ .stack = .{ .base = 0xc800, .size = 0x100 }, .abi = .{ .default_frame = .stack } }; fn f(value: u8) u8 { return value; } " ++ entry, &.{fact}, "f_value", "nonstatic");
    try expectReasonName("pub const zeropage_options = .{ .abi = .{ .functions = .{ .f = .{ .frame = .static } } } }; fn f(value: u8) u8 { return value; } " ++ entry, &.{fact}, "f_value", "abi_root");
    try expectReasonName("fn f(value: u8) u8 { return f(value); } " ++ entry, &.{fact}, "f_value", "recursive");
    try expectReasonName("fn f(value: u8) u8 { return unresolved(value); } " ++ entry, &.{fact}, "f_value", "unknown_call");
}

test "private scalar layout observer global initializer boundary rejects executable pointer conversions" {
    const parser = @import("../../parser.zig");
    const emitter = @import("emitter.zig");
    // Global scalar/aggregate data is emitted before optimizer eligibility.
    // Nonliteral scalar initializers have no runtime execution path today.
    const invalid = try parser.parseSource(std.testing.allocator,
        \\const values = [_]u16{ @intFromPtr(@ptrFromInt(0xc100)) };
        \\fn f(value: u8) u8 { return value; }
        \\export fn main() void { _ = values[0]; _ = f(1); }
    );
    defer invalid.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedPointerCast, emitter.emitProgram(std.testing.allocator, invalid.program));
    const address_initializer = try parser.parseSource(std.testing.allocator,
        \\const base = [_]u8{ 0 };
        \\const values = [_]u16{ @intFromPtr(&base) };
        \\export fn main() void { _ = values[0]; }
    );
    defer address_initializer.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnknownVariable, emitter.emitProgram(std.testing.allocator, address_initializer.program));
    const source =
        \\const values = [_]u16{ 1, 2 };
        \\const text = "constant";
        \\fn f(value: u8) u8 { return value; }
        \\export fn main() void { _ = values[0]; _ = f(1); }
    ;
    const valid = try parser.parseSource(std.testing.allocator, source);
    defer valid.deinit(std.testing.allocator);
    const assembly = try emitter.emitProgram(std.testing.allocator, valid.program);
    defer std.testing.allocator.free(assembly);
    try expectReasonName(source, &.{.{ .label = "f_value", .owner = "f", .size = 1, .zero_initialized = true }}, "f_value", "eligible");
}

test "private scalar layout observer cleans retained observer graphs and decisions on allocation failure" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn leaf(value: u8) u8 { return value; }
        \\fn observer(address: u16) void { const pointer: *u8 = @ptrFromInt(address); _ = pointer; }
        \\export fn main() void { observer(0xc100); _ = leaf(1); }
    );
    defer parsed.deinit(std.testing.allocator);
    const facts = [_]StorageFact{.{ .label = "leaf_value", .owner = "leaf", .size = 1, .zero_initialized = true }};
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: std.mem.Allocator, program: ast.Program, definitions: []const StorageFact) !void {
            const decisions = try classifyParameters(alloc, program, definitions);
            defer freeDecisions(alloc, decisions);
            try std.testing.expectEqualStrings("layout_observer", @tagName(decisionFor(decisions, "leaf_value").reason));
            try std.testing.expectEqualStrings("missing_definition", @tagName(decisionFor(decisions, "observer_address").reason));
        }
    }.run, .{ parsed.program, @as([]const StorageFact, &facts) });
}

test "private scalar layout observer preserves unsupported entry placement removed and opaque exclusions" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn f(value: u8) u8 { return value; }
        \\fn removed(value: u8) u8 { return value; }
        \\export fn main(argument: u8) void { var local: u8 = 0; _ = @intFromPtr(&local); _ = f(1); }
    );
    defer parsed.deinit(std.testing.allocator);
    const facts = [_]StorageFact{
        .{ .label = "f_value", .owner = "f", .size = 1, .zero_initialized = true },
        .{ .label = "removed_value", .owner = "removed", .size = 1, .zero_initialized = true },
        .{ .label = "main_argument", .owner = "main", .size = 1, .zero_initialized = true },
    };
    for (parsed.program.functions) |function| if (std.mem.eql(u8, function.name, "f")) {
        function.params[0].ty = .void;
    };
    const unsupported = try classifyParameters(std.testing.allocator, parsed.program, &facts);
    defer freeDecisions(std.testing.allocator, unsupported);
    try std.testing.expectEqual(Reason.unsupported_type, decisionFor(unsupported, "f_value").reason);
    try std.testing.expectEqual(Reason.entry, decisionFor(unsupported, "main_argument").reason);
    try std.testing.expectEqual(Reason.not_retained, decisionFor(unsupported, "removed_value").reason);
    var program = parsed.program;
    var placements = [_]ast.MemoryPlacement{.{ .name = "fixed", .region_name = "code", .functions = &.{"f"} }};
    program.zeropage_options.memory.placements = &placements;
    const placed = try classifyParameters(std.testing.allocator, program, &facts);
    defer freeDecisions(std.testing.allocator, placed);
    try std.testing.expectEqual(Reason.fixed_placement, decisionFor(placed, "f_value").reason);
    try expectReasonName(
        \\fn f(value: u8) u8 { return value; }
        \\export fn main() void {
        \\    var local: u8 = 0;
        \\    _ = @intFromPtr(&local);
        \\    _ = f(1);
        \\    asm {
        \\        nop
        \\    }
        \\}
    , facts[0..1], "f_value", "opaque_assembly");
}
