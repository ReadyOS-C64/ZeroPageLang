const std = @import("std");
const ast = @import("../../ast.zig");
const calls = @import("call_argument_proof.zig");
const frames = @import("frame_layout.zig");
const layout = @import("branch_layout.zig");
const literal_io = @import("literal_pointer_io.zig");
const machine = @import("instruction.zig");
const reachability = @import("reachability.zig");
const scalars = @import("zero_page_scalars.zig");
const storage = @import("storage_model.zig");

fn same(first: []const u8, second: []const u8) bool {
    return std.mem.eql(u8, first, second);
}

fn pure(expr: ast.Expr, parameter: []const u8) bool {
    return switch (expr) {
        .value => |value| value == .int or (value == .ident and same(value.ident, parameter)),
        .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr => |binary| pure(binary.lhs.*, parameter) and pure(binary.rhs.*, parameter),
        .bit_not => |inner| pure(inner.*, parameter),
        else => false,
    };
}

fn eligible(program: ast.Program, function: ast.Function) bool {
    return reachability.rootReason(program, function) == null and function.params.len == 1 and
        function.params[0].ty == .u16 and function.return_type == .u16 and function.body.len == 1 and
        function.body[0] == .return_expr and pure(function.body[0].return_expr, function.params[0].name);
}

fn functionEntry(graph: layout.Analysis, name: []const u8) ?usize {
    const entry = graph.target(name) orelse return null;
    const node = graph.nodes.items[entry];
    if (node.zone != .code or node.index == 0 or
        !same(storage.sectionOwner(graph.raw.items[node.index - 1], "code") orelse return null, name)) return null;
    return entry;
}

fn onlyCall(graph: layout.Analysis, callee: []const u8) ?usize {
    var call: ?usize = null;
    for (graph.nodes.items, 0..) |node, i| {
        const inst = machine.Instruction.parse(node.text) orelse continue;
        if (inst.op != .jsr and inst.op != .jmp and !layout.conditional(inst.op)) continue;
        if (inst.operand != .direct or !std.ascii.eqlIgnoreCase(inst.operand.direct.name, callee)) continue;
        if (call != null or !calls.exact(node.text, .jsr, callee, 0)) return null;
        call = i;
    }
    return call;
}

fn frameWord(model: storage.Model, owner: []const u8, name: []const u8) ?storage.Location {
    const location = model.resolveObject(.{ .name = name }, 2) orelse return null;
    return if (same(model.frames.items[location.frame].owner, owner) and calls.visible(model, location)) location else null;
}

fn uniqueWord(graph: layout.Analysis, model: storage.Model, name: []const u8, location: storage.Location) ?usize {
    const definition = graph.target(name) orelse return null;
    const index = graph.nodes.items[definition].index;
    if (index + 1 >= graph.raw.items.len or !same(std.mem.trim(u8, graph.raw.items[index + 1], " \t\r"), ".word 0")) return null;
    var names = model.labels.iterator();
    while (names.next()) |other| {
        const alias = other.value_ptr.*;
        if (!same(other.key_ptr.*, name) and alias.frame == location.frame and
            alias.offset >= location.offset and alias.offset < location.offset + 2) return null;
    }
    return index;
}

const Window = struct {
    setup: usize,
    call: usize,
    definition: usize,
    entry: usize,
    end: usize,
};

fn verifyLeaf(graph: layout.Analysis, model: storage.Model, function: ast.Function, site: scalars.DirectCallSite, actual: []const u8, formal: []const u8, managed: bool) ?Window {
    if (same(function.name, site.caller)) return null;
    const entry = functionEntry(graph, function.name) orelse return null;
    const caller = functionEntry(graph, site.caller) orelse return null;
    const call = onlyCall(graph, function.name) orelse return null;
    const nodes = graph.nodes.items;
    if (call < 3 or nodes[call].scope != nodes[caller].scope) return null;
    const stores = call - (if (same(nodes[call - 1].text, "txa")) @as(usize, 3) else 2);
    if (!calls.exact(nodes[stores].text, .sta, formal, 0) or !calls.exact(nodes[stores + 1].text, .stx, formal, 1)) return null;
    var setup = stores;
    const reload_low = setup > 0 and calls.exact(nodes[setup - 1].text, .lda, actual, 0);
    if (reload_low) setup -= 1;
    const reload_high = setup > 0 and calls.exact(nodes[setup - 1].text, .ldx, actual, 1);
    if (reload_high) setup -= 1;
    var proof_start = setup;
    if (!reload_low or !reload_high) {
        // Value forwarding may already reuse A or X from publishing the
        // actual. Keep that publication and prove the surviving values.
        if (setup < 2 or !calls.exact(nodes[setup - 2].text, .sta, actual, 0) or
            !calls.exact(nodes[setup - 1].text, .stx, actual, 1)) return null;
        proof_start -= 2;
    }
    if (nodes[proof_start].scope != nodes[caller].scope or
        nodes[call].index - nodes[proof_start].index != call - proof_start) return null;
    const source = frameWord(model, site.caller, actual) orelse return null;
    const target = frameWord(model, function.name, formal) orelse return null;
    const definition = uniqueWord(graph, model, formal, target) orelse return null;
    if (!model.disjoint(source, 2, target, 2)) return null;

    // The first two instructions kill exactly the register and N/Z
    // results removed from the caller before any consumer sees them.
    if (entry + 2 >= nodes.len or nodes[entry + 2].scope != nodes[entry].scope or
        !calls.exact(nodes[entry + 1].text, .ldx, formal, 1) or
        !calls.exact(nodes[entry + 2].text, .lda, formal, 0)) return null;
    var depth: usize = 0;
    var end = entry + 1;
    while (end < nodes.len and nodes[end].scope == nodes[entry].scope) : (end += 1) {
        const inst = machine.Instruction.parse(nodes[end].text) orelse return null;
        if (same(nodes[end].text, "rts")) {
            if (depth != 0 or (end + 1 < nodes.len and nodes[end + 1].scope == nodes[entry].scope)) return null;
            break;
        }
        if (same(nodes[end].text, "pha")) {
            depth += 1;
            continue;
        }
        if (same(nodes[end].text, "pla")) {
            if (depth == 0) return null;
            depth -= 1;
            continue;
        }
        const effects = inst.effects();
        if (effects.barrier or effects.memory == .stack or effects.writes & machine.sp != 0) return null;
        if (inst.operand == .none or inst.operand == .immediate) continue;
        if (inst.operand != .direct) return null;
        const ref = inst.operand.direct;
        if (same(ref.name, formal)) {
            if (ref.offset < 0 or ref.offset > 1 or effects.memory != .read) return null;
        } else if (model.resolveObject(ref, 1)) |scratch| {
            if (!same(model.frames.items[scratch.frame].owner, "compiler:scratch") or
                !model.disjoint(source, 2, scratch, 1) or !model.disjoint(target, 2, scratch, 1)) return null;
        } else if (!managed or !storage.claimedScratch(graph.raw.items, ref)) return null;
    }
    if (end == nodes.len or nodes[end].scope != nodes[entry].scope or !same(nodes[end].text, "rts")) return null;
    for (nodes, 0..) |node, i| {
        if (node.index == definition or i == stores or i == stores + 1) continue;
        if (!layout.tokenPresent(node.text, formal)) continue;
        if (i <= entry or i >= end) return null;
        const inst = machine.Instruction.parse(node.text) orelse return null;
        if (inst.operand != .direct or !same(inst.operand.direct.name, formal)) return null;
    }
    return .{ .setup = setup, .call = call, .definition = definition, .entry = entry, .end = end };
}

const Edit = struct {
    index: usize,
    replacement: ?[]const u8 = null,

    fn lessThan(_: void, first: Edit, second: Edit) bool {
        return first.index < second.index;
    }
};

/// Remove the copy into a private leaf's formal when its sole caller word
/// remains stable for the complete verified leaf body.
pub fn rewrite(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    const options = program.zeropage_options;
    if (program.zeropage_module != null or options.modules != null or options.stack != null or
        options.memory.placements.len != 0 or options.abi.functions.len != 0 or options.zero_page.allocation == .scalars or
        std.mem.indexOf(u8, assembly, "zeropage_test6502_expect_stack_") != null or
        std.mem.indexOf(u8, assembly, "zeropage_test6502_expect_mem_") != null) return null;
    var have_leaf = false;
    for (program.functions) |function| {
        if (function.exported and !same(function.name, "main")) return null;
        if (eligible(program, function)) have_leaf = true;
    }
    if (!have_leaf) return null;
    const sites = try scalars.singleDirectCalls(a, program);
    defer a.free(sites);
    var graph = try layout.parseForSize(a, assembly);
    defer graph.deinit(a);
    if (!graph.complete) return null;
    var model = storage.Model.init(a);
    defer model.deinit();
    try model.collect(assembly);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var edits: std.ArrayList(Edit) = .empty;
    for (program.functions, sites) |function, maybe_site| {
        const site = maybe_site orelse continue;
        if (!eligible(program, function) or frames.effectivePolicy(program, site.caller) != .static) continue;
        const formal = try std.fmt.allocPrint(temp, "{s}_{s}", .{ function.name, function.params[0].name });
        const actual = try std.fmt.allocPrint(temp, "{s}_{s}", .{ site.caller, site.argument });
        const window = verifyLeaf(graph, model, function, site, actual, formal, options.zero_page.declared) orelse continue;
        for (graph.nodes.items[window.setup..window.call]) |node| try edits.append(temp, .{ .index = node.index });
        try edits.append(temp, .{ .index = window.definition });
        try edits.append(temp, .{ .index = window.definition + 1 });
        for (graph.nodes.items[window.entry + 1 .. window.end]) |node| {
            const inst = machine.Instruction.parse(node.text).?;
            if (inst.operand != .direct or !same(inst.operand.direct.name, formal)) continue;
            const replacement = try std.fmt.allocPrint(temp, "    {s} {s}{s}", .{
                @tagName(inst.op), actual, if (inst.operand.direct.offset == 0) "" else "+1",
            });
            try edits.append(temp, .{ .index = node.index, .replacement = replacement });
        }
    }
    if (edits.items.len == 0 or !try literal_io.closedImage(a, program, assembly, graph, model)) return null;
    std.mem.sort(Edit, edits.items, {}, Edit.lessThan);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var copied: usize = 0;
    for (edits.items) |edit| {
        if (edit.index < copied) return null;
        for (graph.raw.items[copied..edit.index]) |line| try out.writer.print("{s}\n", .{line});
        if (edit.replacement) |line| try out.writer.print("{s}\n", .{line});
        copied = edit.index + 1;
    }
    for (graph.raw.items[copied..], copied..) |line, i| {
        try out.writer.writeAll(line);
        if (i + 1 < graph.raw.items.len) try out.writer.writeByte('\n');
    }
    return try out.toOwnedSlice();
}
