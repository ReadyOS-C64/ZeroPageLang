const std = @import("std");
const parser = @import("parser.zig");
const emitter = @import("codegen/tass64/emitter.zig");
const facts = @import("codegen/tass64/static_local_facts.zig");
const a = std.testing.allocator;
fn root(inventory: facts.Inventory, label: []const u8) !facts.Root {
    for (inventory.roots.items) |r| if (std.mem.eql(u8, r.label, label)) return r;
    return error.MissingRoot;
}
const typed_source =
    \\const Mode=enum(u8){idle,active};
    \\const Record=struct{flag:bool,count:u16,data:[3]u8};
    \\const table=[_]u16{1,2,3};
    \\const greeting="ok";
    \\fn make(value:u8) Record {return Record{.flag=true,.count=value,.data=[_]u8{1,2,3}};}
    \\fn work(input:u8)u16 {
    \\ var flag:bool=true;var byte:u8=input;var signed:i8=0x81;
    \\ var word:u16=0x81ff;var signed_word:i16=0x8134;var size:usize=3;
    \\ var mode:Mode=.active;var bytes=[_]u8{1,2,3};var record=make(input);
    \\ for(0..3)|n|{word+=n;}
    \\ for(bytes,0..)|item,index|{word+=item;size+=index;}
    \\ _=flag;_=byte;_=signed;_=signed_word;_=mode;_=record;
    \\ return word+size;
    \\}
    \\export fn main()void{_=work(1);}
;
test "typed static facts use actual scalar capture and aggregate storage resolution with identical assembly" {
    const parsed = try parser.parseSource(a, typed_source);
    defer parsed.deinit(a);
    const ordinary = try emitter.emitProgramWithOptions(a, parsed.program, .{});
    defer a.free(ordinary);
    var emission = try emitter.emitProgramWithFacts(a, parsed.program, .{});
    defer emission.deinit(a);
    try std.testing.expectEqualStrings(ordinary, emission.assembly);
    const cases = [_]struct { label: []const u8, width: u32 }{ .{ .label = "work_flag", .width = 1 }, .{ .label = "work_byte", .width = 1 }, .{ .label = "work_signed", .width = 1 }, .{ .label = "work_word", .width = 2 }, .{ .label = "work_signed_word", .width = 2 }, .{ .label = "work_size", .width = 2 }, .{ .label = "work_mode", .width = 1 } };
    for (cases) |c| try std.testing.expectEqual(c.width, (try root(emission.inventory, c.label)).width);
    try std.testing.expectEqualStrings("Mode", (try root(emission.inventory, "work_mode")).enum_name.?);
    const record = try root(emission.inventory, "work_record");
    try std.testing.expectEqual(facts.Shape.structure, record.shape);
    try std.testing.expectEqual(@as(u32, 6), record.width);
    const returned = try root(emission.inventory, "make_return");
    try std.testing.expectEqual(facts.Origin.return_buffer, returned.origin);
    try std.testing.expectEqual(@as(u32, 6), returned.width);
    const array = try root(emission.inventory, "work_bytes");
    try std.testing.expectEqual(@as(?u16, 3), array.array_length);
    try std.testing.expectEqual(@as(?u16, 1), array.element_width);
    const table = try root(emission.inventory, "zeropage_arr_table");
    try std.testing.expectEqual(facts.Section.rodata, table.section);
    try std.testing.expectEqual(@as(u32, 6), table.width);
    try std.testing.expectEqual(@as(u32, 2), (try root(emission.inventory, "zeropage_str_greeting")).width);
    var hidden: usize = 0;
    var captures: usize = 0;
    for (emission.inventory.cells.items) |cell| {
        try std.testing.expect(!std.mem.startsWith(u8, cell.label, "work_record_"));
        try std.testing.expect(!std.mem.startsWith(u8, cell.label, "make_return_"));
        if (cell.origin == .hidden_counter) {
            hidden += 1;
            try std.testing.expect(cell.loop_id != null);
            try std.testing.expectEqual(@as(u16, 2), cell.width);
        }
        if (cell.origin == .item_capture or cell.origin == .index_capture) captures += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), hidden);
    try std.testing.expectEqual(@as(usize, 3), captures);
}
test "typed static facts own all text after Program teardown without borrowing resolver Types" {
    const parsed = try parser.parseSource(a, typed_source);
    var emission = try emitter.emitProgramWithFacts(a, parsed.program, .{});
    parsed.deinit(a);
    defer emission.deinit(a);
    const r = try root(emission.inventory, "work_record");
    try std.testing.expectEqualStrings("Record", r.type_name.?);
    try std.testing.expectEqualStrings("work", r.owner);
    try std.testing.expectEqualStrings("record", r.binding);
    const hidden = try root(emission.inventory, "work_for_0_index");
    try std.testing.expectEqualStrings("for_0_index", hidden.binding);
    const e = try root(emission.inventory, "work_mode");
    try std.testing.expectEqualStrings("Mode", e.enum_name.?);
}
test "typed static facts do not fabricate scalar storage for software stack functions" {
    const parsed = try parser.parseSource(a,
        \\pub const zeropage_options=.{.stack=.{.base=0xc800,.size=0x100},.abi=.{.functions=.{.stacked=.{.frame=.stack}}}};
        \\fn stacked(value:u16)u16{var copy:u16=value;return copy;}
        \\export fn main()void{_=stacked(0x81ff);}
    );
    defer parsed.deinit(a);
    const ordinary = try emitter.emitProgramWithOptions(a, parsed.program, .{});
    defer a.free(ordinary);
    var emission = try emitter.emitProgramWithFacts(a, parsed.program, .{});
    defer emission.deinit(a);
    try std.testing.expectEqualStrings(ordinary, emission.assembly);
    for (emission.inventory.roots.items) |r| try std.testing.expect(!std.mem.eql(u8, r.owner, "stacked"));
}
test {
    _ = @import("codegen/tass64/static_local_facts.zig");
}
