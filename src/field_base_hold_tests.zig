const std = @import("std");
const parser = @import("parser.zig");
const emitter = @import("codegen/tass64/emitter.zig");
const a = std.testing.allocator;
const held = "    ldx api_p+1\n    lda api_p\n    pha\n    txa\n    pha\n";
fn emit(source: []const u8) ![]u8 {
    const p = try parser.parseSource(a, source);
    defer p.deinit(a);
    return emitter.emitProgram(a, p.program);
}
fn countHeld(source: []const u8, expected: usize) !void {
    const text = try emit(source);
    defer a.free(text);
    try std.testing.expectEqual(expected, std.mem.count(u8, text, held));
}
test "field hold TDD direct static and nested fields avoid base capture stack" {
    try countHeld("const H=struct{index:u8};export fn api(p:[*]u8)u8{var h=H{.index=1};return p[h.index];}export fn main()void{}", 0);
    try countHeld("const Inner=struct{index:u16};const H=struct{head:u8,inner:Inner};export fn api(p:[*]u16)u16{var h=H{.head=7,.inner=Inner{.index=1}};return p[h.inner.index];}export fn main()void{}", 0);
}
test "field hold TDD ordinary and pointer-array lengths retain getter early constant path" {
    try countHeld("export fn api(p:[*]u8)u8{var bytes=[_]u8{1,2,3};return p[bytes.len];}export fn main()void{}", 0);
    try countHeld("const H=struct{items:[2]u8};export fn api(p:[*]u16,h:*H)u16{return p[h.items.len];}export fn main()void{}", 0);
}
test "field hold actual indirect getter still protects read and byte store base" {
    try countHeld("const H=struct{index:u8};export fn api(p:[*]u8,h:*H)u8{return p[h.index];}export fn main()void{}", 1);
    try countHeld("const H=struct{index:u8};export fn api(p:[*]u8,h:*H,value:u8)u8{p[h.index]=value;return value;}export fn main()void{}", 1);
    try countHeld("const Inner=struct{index:u8};const H=struct{head:u8,inner:Inner};export fn api(p:[*]u16,h:*H)u16{return p[h.inner.index];}export fn main()void{}", 1);
}
test "field hold enum index retains unsupported subset diagnostic" {
    try std.testing.expectError(error.UnsupportedArrayIndex, emit("const E=enum(u8){a,b};export fn api(p:[*]u8)u8{return p[E.b];}export fn main()void{}"));
}
fn oom(allocator: std.mem.Allocator, program: @import("ast.zig").Program) !void {
    const text = emitter.emitProgram(allocator, program) catch |err| {
        if (err == error.WriteFailed) return error.OutOfMemory;
        return err;
    };
    defer allocator.free(text);
}
test "field hold actual flat-name path classification releases all OOM ownership" {
    for ([_][]const u8{
        "const Inner=struct{index:u8};const H=struct{head:u8,inner:Inner};export fn api(p:[*]u8)u8{var h=H{.head=7,.inner=Inner{.index=1}};return p[h.inner.index];}export fn main()void{}",
        "const H=struct{pad:[254]u8,index:u16};export fn api(p:[*]u16,h:*H)u16{return p[h.index];}export fn main()void{}",
        "const H=struct{items:[2]u8};export fn api(p:[*]u8,h:*H)u8{return p[h.items.len];}export fn main()void{}",
    }) |source| {
        const p = try parser.parseSource(a, source);
        defer p.deinit(a);
        try std.testing.checkAllAllocationFailures(a, oom, .{p.program});
    }
}
fn apiCode(text: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, text, "api:\n") orelse return error.MissingApi;
    const end = std.mem.indexOfPos(u8, text, start, "; zeropage_section_end owner=function:api kind=code") orelse return error.MissingApi;
    return text[start..end];
}
test "cast hold TDD transparent literal identifier and static field casts avoid base hold" {
    try countHeld("export fn api(p:[*]u8)u8{return p[@as(u8,1)];}export fn main()void{}", 0);
    try countHeld("export fn api(p:[*]u8,index:u8)u8{return p[@as(u16,index)];}export fn main()void{}", 0);
    try countHeld("const H=struct{index:u8};export fn api(p:[*]u8)u8{var h=H{.index=1};return p[@as(usize,@as(u16,h.index))];}export fn main()void{}", 0);
}
test "cast hold TDD transparent literal and identifier casts avoid numeric RHS hold" {
    for ([_][]const u8{
        "export fn api(value:u16)u16{var items=[_]u16{11,22};items[@as(u8,1)]=value;return items[1];}export fn main()void{}",
        "export fn api(value:u16,index:u8)u16{var items=[_]u16{11,22};items[@as(u16,index)]=value;return items[1];}export fn main()void{}",
        "pub const zeropage_options=.{.zero_page=.{.profile=.kernal,.allocation=.off}};export fn api(value:u16)u16{var items=[_]u16{11,22};items[@as(u8,1)]=value;return items[1];}export fn main()void{}",
    }) |source| {
        const text = try emit(source);
        defer a.free(text);
        const code = try apiCode(text);
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, code, "    pha\n    txa\n    pha\n"));
        try std.testing.expect(std.mem.indexOf(u8, code, "sta zeropage_math_tmp") != null);
    }
}
test "cast hold indirect fields calls and unmodeled pointer arithmetic keep required captures" {
    try countHeld("const H=struct{index:u8};export fn api(p:[*]u8,h:*H)u8{return p[@as(u16,h.index)];}export fn main()void{}", 1);
    try countHeld("fn choose()u8{return 0;}export fn api(p:[*]u8)u8{return p[@as(u16,choose())];}export fn main()void{}", 1);
    try countHeld("export fn api(p:[*]u8,q:*u8)u8{return p[@as(usize,@intFromPtr(q))];}export fn main()void{}", 1);
    const text = try emit("fn choose()u8{return 0;}export fn api(p:[*]u16,value:u16)u16{p[@as(u16,choose())]=value;return value;}export fn main()void{}");
    defer a.free(text);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, try apiCode(text), "    pha\n    txa\n    pha\n"));
}
test "cast hold unsupported casts are still validated normally" {
    try std.testing.expectError(error.Overflow, emit("export fn api(p:[*]u8)u8{return p[@as(u8,256)];}export fn main()void{}"));
    try std.testing.expectError(error.Overflow, emit("export fn api(p:[*]u8,index:u16)u8{return p[@as(u8,index)];}export fn main()void{}"));
    try std.testing.expectError(error.UnsupportedCast, emit("export fn api(p:[*]u8,flag:bool)u8{return p[@as(u8,flag)];}export fn main()void{}"));
}
test "cast hold transparent and retained complex children free every allocation failure" {
    for ([_][]const u8{
        "const H=struct{index:u8};export fn api(p:[*]u16,value:u16)u16{var h=H{.index=1};p[@as(usize,@as(u16,h.index))]=value;return p[1];}export fn main()void{}",
        "const H=struct{index:u8};export fn api(p:[*]u16,value:u16,h:*H)u16{p[@as(u16,h.index)]=value;return value;}export fn main()void{}",
    }) |source| {
        const p = try parser.parseSource(a, source);
        defer p.deinit(a);
        try std.testing.checkAllAllocationFailures(a, oom, .{p.program});
    }
}

test "field hold far and materialized near view lengths keep the actual constant getter path" {
    try countHeld(
        \\const ZeroPage=@import("ZeroPage");
        \\const R=struct{x:u8};
        \\pub const zeropage_options=.{.heaps=.{.main=.{.region=.{.addr=0x9000,.size=16},.kind=.arena}},.reu=.{.heaps=.{.assets=.{.region=.{.addr=0x10000,.size=0x100},.kind=.arena}}}};
        \\export fn api(p:[*]u8)u8{
        \\ const maybe=ZeroPage.reu.heap("assets").allocBytes(3);
        \\ if(maybe)|far|{var view=ZeroPage.reu.view(R,far,3);const local_opt=view.materialize("main");if(local_opt)|local|{return p[local.len];}return p[view.len];}
        \\ return 0;
        \\}
        \\export fn main()void{}
    , 0);
}
test "cast cost TDD optional ZP scratch policies keep pending RHS off the allocator" {
    for ([_][]const u8{ "scratch", "scalars" }) |mode| {
        const source = try std.fmt.allocPrint(
            a,
            "pub const zeropage_options=.{{.zero_page=.{{.profile=.kernal,.allocation=.{s}}}}};export fn main()void{{const p:[*]u16=@ptrFromInt(0xc100);p[@as(u8,1)]=0xc1f0;_=p[1];}}",
            .{mode},
        );
        defer a.free(source);
        const p = try parser.parseSource(a, source);
        defer p.deinit(a);
        const text = try @import("codegen/tass64/pipeline.zig").emitProgram(a, p.program);
        defer a.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "zeropage_zp_claim label=zeropage_ptr_value") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "zeropage_zp_claim label=zeropage_math_tmp") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "zeropage_zp_snapshot:\n    .fill 2,0") != null);
    }
}
