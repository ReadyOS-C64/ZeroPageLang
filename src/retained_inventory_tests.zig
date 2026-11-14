const std = @import("std");
const parser = @import("parser.zig");
const pipeline = @import("codegen/tass64/pipeline.zig");
const emitter = @import("codegen/tass64/emitter.zig");
const facts = @import("codegen/tass64/static_local_facts.zig");
const ast = @import("ast.zig");
const a = std.testing.allocator;
fn hasOwner(inventory: facts.Inventory, owner: []const u8) bool {
    for (inventory.roots.items) |root| if (std.mem.eql(u8, root.owner, owner)) return true;
    return false;
}
const reduced_source =
    \\const Mode=enum(u8){idle,active};
    \\fn live(value:u8)u8{var copy:u8=value;var mode:Mode=.active;_=mode;return copy;}
    \\fn dead(value:u16)u16{var copy:u16=value;for(0..3)|index|{copy+=index;}return copy;}
    \\export fn main()void{_=live(7);}
;
test "retained inventory selects reduced emission rather than full semantic dry objects" {
    const parsed = try parser.parseSource(a, reduced_source);
    defer parsed.deinit(a);
    var raw = try emitter.emitProgramWithFacts(a, parsed.program, .{});
    defer raw.deinit(a);
    try std.testing.expect(hasOwner(raw.inventory, "dead"));
    const plain = try pipeline.emitProgramWithOptions(a, parsed.program, .{});
    defer a.free(plain);
    var selected = try pipeline.emitProgramWithFacts(a, parsed.program, .{});
    defer selected.deinit(a);
    try std.testing.expectEqualStrings(plain, selected.assembly);
    try std.testing.expect(!hasOwner(selected.inventory, "dead"));
    try std.testing.expect(hasOwner(selected.inventory, "live"));
    try std.testing.expect(std.mem.indexOf(u8, selected.assembly, "function=dead status=removed") != null);
    for (selected.inventory.roots.items, 0..) |root, index| try std.testing.expectEqual(index, root.metadata_id);
    for (selected.inventory.cells.items) |cell| {
        try std.testing.expect(cell.root_index < selected.inventory.roots.items.len);
        try std.testing.expect(std.mem.eql(u8, cell.owner, "live"));
    }
}
test "retained inventory preserves full validation errors for unsupported unused code" {
    for ([_][]const u8{
        "fn live(value:u8)u8{var copy:u8=value;return copy;} fn dead()u8{return missingFunction();} export fn main()void{_=live(7);}",
        "fn live(value:u8)u8{var copy:u8=value;return copy;} fn dead()u8{return @ptrFromInt(0xc100);} export fn main()void{_=live(7);}",
    }, [_]anyerror{ error.UnknownFunction, error.UnsupportedPointerCast }) |source, wanted| {
        const parsed = try parser.parseSource(a, source);
        defer parsed.deinit(a);
        try std.testing.expectError(wanted, pipeline.emitProgramWithOptions(a, parsed.program, .{}));
        try std.testing.expectError(wanted, pipeline.emitProgramWithFacts(a, parsed.program, .{}));
    }
}
test "retained inventory owns names after Program free on selected and all retained paths" {
    for ([_][]const u8{ reduced_source, "const Mode=enum(u8){idle,active}; export fn main()void{var state:Mode=.active;_=state;}" }) |source| {
        const owned_source = try a.dupe(u8, source);
        const parsed = try parser.parseSource(a, owned_source);
        var result = try pipeline.emitProgramWithFacts(a, parsed.program, .{});
        parsed.deinit(a);
        @memset(owned_source, 0xa5);
        a.free(owned_source);
        defer result.deinit(a);
        var enum_found = false;
        for (result.inventory.roots.items) |root| {
            try std.testing.expect(root.owner.len != 0 and root.label.len != 0 and root.binding.len != 0);
            if (root.enum_name) |name| {
                try std.testing.expectEqualStrings("Mode", name);
                enum_found = true;
            }
        }
        try std.testing.expect(enum_found);
        for (result.inventory.cells.items) |cell| try std.testing.expectEqualStrings(result.inventory.roots.items[cell.root_index].label, cell.label);
    }
}
test "retained inventory can discard all dry facts for an empty selected frame" {
    const parsed = try parser.parseSource(a, "fn dead()u8{var byte:u8=7;return byte;}export fn main()void{}");
    defer parsed.deinit(a);
    var result = try pipeline.emitProgramWithFacts(a, parsed.program, .{});
    defer result.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), result.inventory.roots.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.inventory.cells.items.len);
}
fn oomFacts(allocator: std.mem.Allocator, program: ast.Program) !void {
    var result = pipeline.emitProgramWithFacts(allocator, program, .{}) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer result.deinit(allocator);
    try std.testing.expect(!hasOwner(result.inventory, "dead"));
}
test "retained inventory releases selected discarded and all retained results at every allocation failure" {
    for ([_][]const u8{ reduced_source, "export fn main()void{var value:u16=257;_=value;}" }) |source| {
        const parsed = try parser.parseSource(a, source);
        defer parsed.deinit(a);
        try std.testing.checkAllAllocationFailures(a, oomFacts, .{parsed.program});
    }
}

test "retained inventory includes externally rooted exports without source calls" {
    const parsed = try parser.parseSource(a, "export fn kept(value:u8)u8{var copy:u8=value;return copy;}fn dead(value:u8)u8{return value;}export fn main()void{}");
    defer parsed.deinit(a);
    var result = try pipeline.emitProgramWithFacts(a, parsed.program, .{});
    defer result.deinit(a);
    try std.testing.expect(hasOwner(result.inventory, "kept"));
    try std.testing.expect(!hasOwner(result.inventory, "dead"));
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "kept:\n") != null);
}
test "retained inventory releases dry facts when invalid unused emission fails under every OOM" {
    const parsed = try parser.parseSource(a, "fn live(value:u8)u8{var copy:u8=value;return copy;}fn dead()u8{return missingFunction();}export fn main()void{_=live(7);}");
    defer parsed.deinit(a);
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(allocator: std.mem.Allocator, program: ast.Program) !void {
            if (pipeline.emitProgramWithFacts(allocator, program, .{})) |emission| {
                var unexpected = emission;
                unexpected.deinit(allocator);
                return error.ExpectedSemanticFailure;
            } else |err| switch (err) {
                error.UnknownFunction => return,
                error.WriteFailed => return error.OutOfMemory,
                else => return err,
            }
        }
    }.run, .{parsed.program});
}
