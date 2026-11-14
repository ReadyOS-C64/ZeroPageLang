const std = @import("std");
const parser = @import("parser.zig");
const emitter = @import("codegen/tass64/emitter.zig");
const a = std.testing.allocator;
fn emit(source: []const u8) ![]u8 {
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    return emitter.emitProgram(a, parsed.program);
}
fn contains(source: []const u8, expected: []const u8) !void {
    const assembly = try emit(source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, expected) != null);
}
test "pointer field direct and nested VALUE reads retain high address byte" {
    try contains("const H=struct{ptr:*u8};export fn api(h:H)*u8{return h.ptr;}export fn main()void{}", "ldx api_h_ptr+1\n    lda api_h_ptr");
    try contains("const I=struct{pad:u8,ptr:*u8};const H=struct{head:u16,inner:I};export fn api(h:H)*u8{return h.inner.ptr;}export fn main()void{}", "ldx api_h_inner_ptr+1\n    lda api_h_inner_ptr");
}
test "pointer field constructor and call forwarding store both typed bytes" {
    try contains("const H=struct{ptr:*u8};fn identity(p:*u8)*u8{return p;}export fn api(p:*u8)*u8{const h=H{.ptr=p};return identity(h.ptr);}export fn main()void{}", "sta api_h_ptr\n    stx api_h_ptr+1");
}
test "pointer struct field getter copies low and high through indirect loads" {
    try contains("const H=struct{ptr:*u8};export fn api(h:*H)*u8{return h.ptr;}export fn main()void{}", "lda (zeropage_ptr_tmp),y\n    pha\n    iny\n    lda (zeropage_ptr_tmp),y\n    tax\n    pla");
}
test "pointer struct field store writes low and high and uses two byte extent" {
    try contains("const H=struct{ptr:*u8};export fn api(h:*H,p:*u8)void{h.ptr=p;}export fn main()void{}", "lda zeropage_ptr_value\n    sta (zeropage_ptr_tmp),y\n    iny\n    lda zeropage_ptr_value+1\n    sta (zeropage_ptr_tmp),y");
    for ([_]u16{ 254, 255, 256 }) |offset| {
        const source = try std.fmt.allocPrint(a, "const H=struct{{pad:[{d}]u8,extra:u8,ptr:*u8}};export fn api(h:*H)*u8{{return h.ptr;}}export fn main()void{{}}", .{offset - 1});
        defer a.free(source);
        const assembly = try emit(source);
        defer a.free(assembly);
        if (offset == 254) {
            try std.testing.expect(std.mem.indexOf(u8, assembly, "ldy #254") != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, assembly, "ldy #255") == null);
            try std.testing.expect(std.mem.indexOf(u8, assembly, "ldy #0") != null);
        }
    }
}
test "AoS pointer field initialization read and assignment keep two bytes" {
    try contains("const H=struct{pad:u8,ptr:*u8};export fn api(index:u8,p:*u8)*u8{var items=[_]H{H{.pad=1,.ptr=p},H{.pad=2,.ptr=p}};items[index].ptr=p;return items[index].ptr;}export fn main()void{}", "stx zeropage_field_value_0+1");
}
test "plain byte word and enum field VALUE widths remain explicit" {
    try contains("const H=struct{byte:u8,word:u16};export fn api(h:H)u16{return h.word;}export fn main()void{}", "ldx api_h_word+1\n    lda api_h_word");
    try contains("const H=struct{byte:u8};export fn api(h:H)u16{return h.byte;}export fn main()void{}", "ldx #0\n    lda api_h_byte");
    try contains("const E=enum(u8){one,two};const H=struct{e:E};export fn api(h:H)E{return h.e;}export fn main()void{}", "lda api_h_e");
}

test "pointer field VALUE reads support existing pointer qualifiers and enum struct pointees" {
    for ([_][]const u8{ "*volatile u8", "[*]u8", "*u16", "*E", "*R" }) |ty| {
        const source = try std.fmt.allocPrint(a, "const E=enum(u8){{a,b}};const R=struct{{value:u8}};const H=struct{{ptr:{s}}};export fn api(h:H){s}{{return h.ptr;}}export fn main()void{{}}", .{ ty, ty });
        defer a.free(source);
        try contains(source, "ldx api_h_ptr+1\n    lda api_h_ptr");
    }
}
test "pointer field raw construction and unsupported arithmetic remain rejected" {
    for ([_][]const u8{
        "const H=struct{ptr:*u8};export fn api()*u8{const h=H{.ptr=@ptrFromInt(0xc150)};return h.ptr;}export fn main()void{}",
        "const H=struct{ptr:*u8};export fn api(flag:bool,p:*u8)*u8{const h=H{.ptr=if(flag)p else @ptrFromInt(0xc150)};return h.ptr;}export fn main()void{}",
        "const H=struct{ptr:*u8};export fn api(p:*u8)*u8{const h=H{.ptr=@as(*u8,@ptrFromInt(0xc150))};_=p;return h.ptr;}export fn main()void{}",
    }) |source| try std.testing.expectError(error.UnsupportedPointerCast, emit(source));
    const parsed = try parser.parseSource(a, "const H=struct{ptr:*u8};export fn api(h:H)*u8{return h.ptr+1;}export fn main()void{}");
    defer parsed.deinit(a);
    try std.testing.expectError(error.UnsupportedPointerCast, emitter.emitProgram(a, parsed.program));
}
test "pointer field constructor permits previously admitted nested call argument typed contexts" {
    try contains("const H=struct{ptr:*u8};fn identity(p:*u8)*u8{return p;}export fn api()*u8{const h=H{.ptr=identity(@ptrFromInt(0xc150))};return h.ptr;}export fn main()void{}", "sta api_h_ptr\n    stx api_h_ptr+1");
}
fn oomEmit(allocator: std.mem.Allocator, program: @import("ast.zig").Program) !void {
    const assembly = emitter.emitProgram(allocator, program) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer allocator.free(assembly);
}
test "pointer field type resolution and emitted buffers clean every allocation failure" {
    const source = "const H=struct{pad:u8,ptr:*u8};fn identity(p:*u8)*u8{return p;}export fn api(index:u8,p:*u8)*u8{var items=[_]H{H{.pad=1,.ptr=p},H{.pad=2,.ptr=p}};items[index].ptr=identity(p);return items[index].ptr;}export fn main()void{}";
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    try std.testing.checkAllAllocationFailures(a, oomEmit, .{parsed.program});
}

test "admitted nullable pointer field copies preserve both bytes without adding null constructors" {
    try contains("const H=struct{ptr:?*u8};export fn api(p:?*u8)H{return H{.ptr=p};}export fn main()void{}", "sta api_return_ptr\n    stx api_return_ptr+1");
    try std.testing.expectError(error.UnsupportedOptional, emit("const H=struct{ptr:?*u8};export fn api()H{return H{.ptr=null};}export fn main()void{}"));
}

test "admitted pointer valued block field initializer keeps AX width" {
    try contains("const H=struct{ptr:*u8};export fn api(p:*u8)*u8{const h=H{.ptr=blk:{break:blk p;}};return h.ptr;}export fn main()void{}", "ldx api_p+1\n    lda api_p");
}

test "pointer field control expressions keep full values and legacy block raw casts reject" {
    for ([_][]const u8{
        "const H=struct{ptr:*u8};export fn api(flag:bool,p:*u8,q:*u8)*u8{const h=H{.ptr=if(flag)p else q};return h.ptr;}export fn main()void{}",
        "const H=struct{ptr:*u8};export fn api(flag:bool,p:*u8,q:*u8)*u8{const h=H{.ptr=switch(flag){true=>p,false=>q}};return h.ptr;}export fn main()void{}",
        "const H=struct{ptr:*u8};export fn api(flag:bool,p:*u8,q:*u8)*u8{const h=H{.ptr=blk:{if(flag){break:blk p;}break:blk q;}};return h.ptr;}export fn main()void{}",
    }) |source| try contains(source, "stx api_h_ptr+1");
    try std.testing.expectError(error.UnsupportedPointerCast, emit("const H=struct{ptr:*u8};export fn api()*u8{const h=H{.ptr=blk:{break:blk @as(*u8,@ptrFromInt(0xc150));}};return h.ptr;}export fn main()void{}"));
    try std.testing.expectError(error.UnsupportedPointerCast, emit("export fn api()*u8{return blk:{break:blk @as(*u8,@ptrFromInt(0xc150));};}export fn main()void{}"));
}

test "typed pointer field values reject implicit integer and mismatched pointer coercions" {
    try std.testing.expectError(error.UnsupportedPointerType, emit("const H=struct{ptr:*u8};export fn api()H{return H{.ptr=0xc150};}export fn main()void{}"));
    try std.testing.expectError(error.UnsupportedPointerType, emit("const H=struct{ptr:*u8};export fn api(p:*u16)H{return H{.ptr=p};}export fn main()void{}"));
}

test "pending pointer array field VALUE has unique resident site storage across index calls" {
    const source = "const H=struct{ptr:*u8};fn choose(a:u16,b:u16)u8{if(a==b+1){return 0;}return 1;}export fn api(p:*u8,q:*u8)*u8{var items=[_]H{H{.ptr=p},H{.ptr=p}};items[choose(2,1)].ptr=q;return items[0].ptr;}export fn main()void{}";
    try contains(source, "zeropage_field_value_0:\n    .word 0");
    try contains(source, "sta zeropage_field_value_0\n    stx zeropage_field_value_0+1");
}

const nested_index_source =
    \\const H=struct{ptr:*u8};
    \\export fn mirror(value:u16,tag:u8)u16{_=tag;return value;}
    \\fn choose(a:u16,b:u16,change:*u16)u8{
    \\ const keep:*u8=@ptrFromInt(0xc777);var inner=[_]H{H{.ptr=keep},H{.ptr=keep}};
    \\ var slot:u8=0;inner[slot].ptr=keep;
    \\ const probe:*volatile u8=@ptrFromInt(0xc300);const value:u16=mirror(a,probe.*);
    \\ change.* = 0xc777;if(value==b+1){return 0;}return 1;
    \\}
    \\export fn api(p:*u8,q:*u8,change:*u16)*u8{
    \\ var items=[_]H{H{.ptr=q},H{.ptr=q}};items[choose(2,1,change)].ptr=p;return items[0].ptr;
    \\}
    \\export fn main()void{}
;
test "pending pointer field sites are distinct across separately emitted callee bodies" {
    const assembly = try emit(nested_index_source);
    defer a.free(assembly);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_field_value_0:\n    .word 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_field_value_1:\n    .word 0") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, "sta zeropage_field_value_"));
    try std.testing.expect(std.mem.indexOf(u8, assembly, "owner=runtime kind=data") != null);
}
test "pending field resident words clean all allocations through nested code emission" {
    const parsed = try parser.parseSource(a, nested_index_source);
    defer parsed.deinit(a);
    try std.testing.checkAllAllocationFailures(a, oomEmit, .{parsed.program});
}
test "module pending field words bind both byte operands with relocation addends" {
    const source =
        \\const H=struct{ptr:*u8};
        \\pub const zeropage_options=.{.stack=.{.base=0xc800,.size=0x400},.abi=.{.functions=.{.tick=.{.frame=.stack}}}};
        \\pub const zeropage_module=.{.id="fieldword",.abi=1,.flags=.{},.exports=.{.tick=tick},.deps=.{}};
        \\fn helper(index:u8,p:*u8)*u8{var items=[_]H{H{.ptr=p},H{.ptr=p}};items[index].ptr=p;return items[0].ptr;}
        \\fn tick(value:*u8)*u8{return helper(0,value);}
        \\export fn main()void{}
    ;
    const assembly = try emit(source);
    defer a.free(assembly);
    const parsed_module = try parser.parseSource(a, source);
    defer parsed_module.deinit(a);
    try std.testing.checkAllAllocationFailures(a, oomEmit, .{parsed_module.program});
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, "target=zeropage_field_value_0 addend=0"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assembly, "target=zeropage_field_value_0 addend=1"));
    try std.testing.expect(std.mem.indexOf(u8, assembly, "zeropage_field_value_0:\n    .word 0") != null);
}
