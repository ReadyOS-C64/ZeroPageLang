const std = @import("std");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const scalars = @import("codegen/tass64/zero_page_scalars.zig");
const a = std.testing.allocator;
fn reasonFor(source: []const u8, label: []const u8, owner: []const u8, width: u16, wanted: []const u8) !void {
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    const facts = [_]scalars.StorageFact{.{ .label = label, .owner = owner, .size = width, .zero_initialized = true }};
    const decisions = try scalars.classifyParameters(a, parsed.program, &facts);
    defer scalars.freeDecisions(a, decisions);
    for (decisions) |d| if (std.mem.eql(u8, d.label, label)) {
        try std.testing.expectEqualStrings(wanted, @tagName(d.reason));
        return;
    };
    return error.MissingDecision;
}
test "domain rejects exported and configured native pointer observation" {
    try reasonFor(@embedFile("testdata/placement_domain/public_pointer_read.zp64"), "read_tag", "read", 1, "unproven_memory_domain");
    try reasonFor(@embedFile("testdata/placement_domain/configured_pointer_read.zp64"), "read_tag", "read", 1, "unproven_memory_domain");
}
test "domain rejects external optional struct and union pointer payload observation" {
    try reasonFor(@embedFile("testdata/placement_domain/public_optional_pointer.zp64"), "read_tag", "read", 1, "unproven_memory_domain");
    try reasonFor(@embedFile("testdata/placement_domain/public_struct_pointer.zp64"), "read_tag", "read", 1, "unproven_memory_domain");
    try reasonFor(@embedFile("testdata/placement_domain/public_union_pointer.zp64"), "read_tag", "read", 1, "unproven_memory_domain");
}
test "domain rejects integer address DMA without a pointer cast" {
    try reasonFor(@embedFile("testdata/placement_domain/reu_dynamic_u16_address.zp64"), "copy_tag", "copy", 1, "unproven_memory_domain");
}
test "domain rejects fixed heap free unknown target" {
    try reasonFor(@embedFile("testdata/placement_domain/native_heap_free.zp64"), "release_tag", "release", 1, "unproven_memory_domain");
}
test "domain rejects screen indexed wrap and literal word indexed wrap" {
    try reasonFor(@embedFile("testdata/placement_domain/screen_index_wrap.zp64"), "paint_tag", "paint", 1, "unproven_memory_domain");
    try reasonFor(@embedFile("testdata/placement_domain/literal_word_wrap.zp64"), "read_tag", "read", 1, "unproven_memory_domain");
    try reasonFor(@embedFile("testdata/placement_domain/literal_index_wrap.zp64"), "read_tag", "read", 1, "unproven_memory_domain");
}
test "domain preserves pure pointer value passthrough and unreachable observers" {
    try reasonFor(@embedFile("testdata/placement_domain/public_pointer_passthrough.zp64"), "identity_p", "identity", 2, "eligible");
    try reasonFor("fn leaf(tag:u8)u8{return tag;}fn dead(p:*u8)u8{return p.*;}export fn main()void{_=leaf(7);}", "leaf_tag", "leaf", 1, "eligible");
}
test "domain preserves earlier owner storage escape and layout observer precedence" {
    const source = "fn read(p:*u8,tag:u8)u8{_=p.*;_= &tag;return tag;}export fn api(p:*u8)u8{return read(p,1);}export fn main()void{}";
    try reasonFor(source, "read_tag", "read", 1, "address_escape");
    try reasonFor(source, "api_p", "api", 2, "exported");
    try reasonFor("fn read(p:*u8,tag:u8)u8{_=p.*;_= @intFromPtr(p);return tag;}export fn api(p:*u8)u8{return read(p,1);}export fn main()void{}", "read_tag", "read", 1, "layout_observer");
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    const facts = [_]scalars.StorageFact{.{ .label = "read_tag", .owner = "read", .size = 1, .zero_initialized = true, .indexed = true }};
    const decisions = try scalars.classifyParameters(a, parsed.program, &facts);
    defer scalars.freeDecisions(a, decisions);
    for (decisions) |d| if (std.mem.eql(u8, d.label, "read_tag")) try std.testing.expectEqualStrings("indexed", @tagName(d.reason));
}
test "domain baseline finite literal byte and nonwrapping screen controls" {
    try reasonFor("fn read(tag:u8)u8{const p:*volatile u8=@ptrFromInt(0xc100);_=p.*;return tag;}export fn main()void{_=read(7);}", "read_tag", "read", 1, "eligible");
    try reasonFor("const c64=@import(\"ZeroPage\");fn paint(x:u8,tag:u8)u8{c64.screen.putAt(x,24,tag);return tag;}export fn api(x:u8)u8{return paint(x,7);}export fn main()void{}", "paint_tag", "paint", 1, "eligible");
}

const domains = @import("codegen/tass64/placement_domains.zig");

test "record argument origins cover retained calls and distinguish unknown values" {
    const parsed = try parser.parseSource(a,
        \\const Board = struct { cells: [3]u8 };
        \\const Game = struct { board: Board };
        \\fn read(board: *Board) u8 { return board.cells[0]; }
        \\fn forward(board: *Board) u8 { return read(board); }
        \\fn project(game: *Game) u8 { return forward(&game.board); }
        \\fn select(board: *Board, flag: bool) u8 { return read(if (flag) board else board); }
        \\fn dead(board: *Board) void { _ = read(board); }
        \\export fn main() void {
        \\    var game: Game = .{ .board = .{ .cells = [_]u8{1, 2, 3} } };
        \\    var board: Board = .{ .cells = [_]u8{4, 5, 6} };
        \\    _ = project(&game);
        \\    _ = select(&board, true);
        \\}
    );
    defer parsed.deinit(a);
    const args = try domains.recordArguments(a, parsed.program);
    defer a.free(args);
    try std.testing.expectEqual(@as(usize, 5), args.len);
    const functions = parsed.program.functions;
    for (args) |edge| {
        try std.testing.expectEqual(@as(usize, 0), edge.parameter);
        const caller = functions[edge.caller].name;
        const callee = functions[edge.callee].name;
        if (std.mem.eql(u8, caller, "main")) {
            try std.testing.expectEqualStrings(if (std.mem.eql(u8, callee, "project")) "game" else "board", edge.source.local);
        } else if (std.mem.eql(u8, caller, "select")) {
            try std.testing.expectEqual(.unknown, std.meta.activeTag(edge.source));
        } else {
            try std.testing.expectEqual(@as(usize, 0), edge.source.forwarded.parameter);
            try std.testing.expectEqualStrings(if (std.mem.eql(u8, caller, "project")) "board" else "", edge.source.forwarded.path);
        }
    }
}

fn expectDomain(source: []const u8, expected: bool) !void {
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    var summary = try domains.analyze(a, parsed.program);
    defer summary.deinit(a);
    try std.testing.expectEqual(expected, summary.unproven);
}
test "domain distinguishes pointer values copied assigned passed and returned from actual pointees" {
    try expectDomain("fn id(p:*u8)*u8{var copy:*u8=p;copy=p;return copy;}export fn api(p:*u8)*u8{return id(p);}export fn main()void{}", false);
    try expectDomain("const Holder=struct{p:*u8};fn id(p:*u8)*u8{return p;}export fn api(h:Holder)*u8{return id(h.p);}export fn main()void{}", false);
    try expectDomain("fn id(p:*u8)*u8{return p;}export fn api(p:?*u8)?*u8{if(p)|value|{return id(value);}return null;}export fn main()void{}", false);
    try expectDomain("const Holder=union(enum){none,p:*u8};fn id(p:*u8)*u8{return p;}export fn api(h:Holder)?*u8{return switch(h){.none=>null,.p=>|value|id(value)};}export fn main()void{}", false);
}
test "domain catches implicit pointer struct field writes and nested payload consumers" {
    try expectDomain("const Holder=struct{byte:u8};fn read(tag:u8)u8{return tag;}export fn api(h:*Holder)u8{h.byte=7;return read(1);}export fn main()void{}", true);
    try expectDomain("const Holder=struct{byte:u8};fn read(tag:u8)u8{return tag;}export fn api(h:*Holder)u8{h.byte+=7;return read(h.byte);}export fn main()void{}", true);
    try expectDomain("const Holder=struct{p:*u8};const Outer=struct{data:[1]Holder};fn read(tag:u8)u8{return tag;}export fn api(h:Outer)u8{const p:*u8=h.data[0].p;return p.*+read(1);}export fn main()void{}", true);
}
test "domain REU integer endpoints cover all transfer forms and zero wrap cases" {
    for ([_][]const u8{
        "ZeroPage.reu.copyC64ToReu(address,0x10000,len);",
        "ZeroPage.reu.copyReuToC64(0x10000,address,len);",
        "ZeroPage.reu.swap(address,0x10000,len);",
        "_=ZeroPage.reu.compare(address,0x10000,len);",
        "ZeroPage.reu.copyC64ToReu(0xffff,0x10000,2);",
    }) |statement| {
        const text = try std.fmt.allocPrint(a, "const ZeroPage=@import(\"ZeroPage\");export fn api(address:u16,len:u16)void{{{s}}}export fn main()void{{}}", .{statement});
        defer a.free(text);
        try expectDomain(text, true);
    }
    try expectDomain("const ZeroPage=@import(\"ZeroPage\");export fn main()void{ZeroPage.reu.copyC64ToReu(0xc100,0x10000,4);}", false);
    try std.testing.expectError(error.UnsupportedReuLength, parser.parseSource(a, "const ZeroPage=@import(\"ZeroPage\");export fn main()void{ZeroPage.reu.copyC64ToReu(0xc100,0x10000,0);}"));
}
test "domain literal width known pointer arguments and byte nonwrapping edge remain bounded" {
    try expectDomain("fn read(p:*volatile u16)void{_=p.*;}export fn main()void{read(@ptrFromInt(0xffff));}", true);
    try expectDomain("fn read(p:*volatile u8)void{_=p.*;}export fn main()void{read(@ptrFromInt(0xffff));}", false);
    try expectDomain("export fn main()void{const p:[*]volatile u16=@ptrFromInt(0xfffe);_=p[1];}", true);
    try expectDomain("export fn main()void{const p:[*]volatile u16=@ptrFromInt(0xfffe);_=p[0];}", false);
    try expectDomain("export fn main()void{const p:*volatile u16=@ptrFromInt(0xffff);_=p;}", false);
}
test "domain screen footprint includes indexed base plus and multichar wrap" {
    try expectDomain("const c64=@import(\"ZeroPage\");export fn api(x:u8)void{c64.screen.putAt(1+x,255,7);}export fn main()void{}", true);
    try expectDomain("const c64=@import(\"ZeroPage\");export fn main()void{c64.screen.putsAt(39,255,\"AB\");}", true);
    try expectDomain("const c64=@import(\"ZeroPage\");export fn main()void{c64.screen.hexAt(39,255,7);}", true);
    try expectDomain("const c64=@import(\"ZeroPage\");export fn main()void{c64.screen.hex16At(37,255,7);}", true);
}
test "domain evidence owns numeric identities after AST destruction" {
    const parsed = try parser.parseSource(a, @embedFile("testdata/placement_domain/public_optional_pointer.zp64"));
    var summary = try domains.analyze(a, parsed.program);
    parsed.deinit(a);
    defer summary.deinit(a);
    try std.testing.expect(summary.unproven);
    var input = false;
    var observed = false;
    for (summary.evidence) |item| {
        if (item.kind == .external_pointer_input) {
            input = true;
            try std.testing.expect(item.parameter_index != null);
        }
        if (item.kind == .external_pointee_observation) {
            observed = true;
            try std.testing.expect(item.site != 0);
        }
    }
    try std.testing.expect(input and observed);
}
fn oomDomain(allocator: std.mem.Allocator, program: ast.Program) !void {
    var summary = try domains.analyze(allocator, program);
    defer summary.deinit(allocator);
    try std.testing.expect(summary.unproven);
}
test "domain cleanup survives every input binding literal evidence allocation failure" {
    const source = "const ZeroPage=@import(\"ZeroPage\");const R=struct{p:*u8};fn helper(p:*u8,tag:u8)u8{const a:*volatile u16=@ptrFromInt(0xffff);_=a.*;const b:[*]volatile u8=@ptrFromInt(0xfff0);_=b[tag];ZeroPage.reu.copyReuToC64(0x10000,tag,1);return p.*;}export fn api(r:R)u8{return helper(r.p,7);}export fn main()void{}";
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    try std.testing.checkAllAllocationFailures(a, oomDomain, .{parsed.program});
}

const policy = @import("zero_page.zig");
const claim_map = @import("codegen/tass64/zero_page_parameter_map.zig");
test "domain map rejects forged allocations and preserves only earlier storage exclusions" {
    const parsed = try parser.parseSource(a, @embedFile("testdata/placement_domain/public_pointer_read.zp64"));
    defer parsed.deinit(a);
    var markers = [_]claim_map.Marker{
        .{ .label = "read_p", .size = 2, .reason = .unproven_memory_domain, .status = .excluded },
        .{ .label = "read_tag", .size = 1, .reason = .unproven_memory_domain, .status = .excluded },
        .{ .label = "api_p", .size = 2, .reason = .exported, .status = .excluded },
    };
    try claim_map.validate(a, parsed.program, &.{}, &markers);
    for ([_]scalars.Reason{ .missing_definition, .duplicate_definition, .owner_mismatch, .layout, .aliased, .indexed, .address_escape, .assembly_sensitive }) |reason| {
        markers[0].reason = reason;
        try claim_map.validate(a, parsed.program, &.{}, &markers);
    }
    markers[0].reason = .unproven_memory_domain;
    const claim = [_]policy.Claim{.{ .label = "read_tag", .addr = 2, .size = 1, .kind = .parameter }};
    markers[1].reason = .eligible;
    markers[1].status = .allocated;
    try std.testing.expectError(error.InvalidZeroPageClaimMap, claim_map.validate(a, parsed.program, &claim, &markers));
    markers[1].reason = .layout_observer;
    markers[1].status = .excluded;
    try std.testing.expectError(error.InvalidZeroPageClaimMap, claim_map.validate(a, parsed.program, &.{}, &markers));
}

const emitter = @import("codegen/tass64/emitter.zig");
const call_rewrite = @import("codegen/tass64/call_argument_rewrite.zig");
fn rewriteArgs(source: []const u8) ![]u8 {
    const parsed = try parser.parseSource(a, source);
    defer parsed.deinit(a);
    const raw = try emitter.emitProgram(a, parsed.program);
    defer a.free(raw);
    return call_rewrite.rewrite(a, parsed.program, raw);
}
fn stripMarkers(raw: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(a);
    errdefer writer.deinit();
    var split = std.mem.splitScalar(u8, raw, '\n');
    while (split.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t\r"), "; zeropage_scalar_call_")) continue;
        try writer.writer.writeAll(line);
        if (split.index != null) try writer.writer.writeByte('\n');
    }
    return writer.toOwnedSlice();
}
test "domain exclusion does not erase R33 earlier volatile producer proof or final word endpoint" {
    for ([_]struct { source: []const u8, selection: []const u8 }{
        .{ .source = "fn leaf(a:u16,b:u8)u16{_=b;return a;}export fn api(p:*volatile u16)u16{return leaf(p.*,7);}export fn main()void{}", .selection = "direct_arguments=1 final_words=0" },
        .{ .source = "fn leaf(a:u16)u16{return a;}export fn api(p:*volatile u16)u16{return leaf(p.*);}export fn main()void{}", .selection = "direct_arguments=1 final_words=1" },
    }) |row| {
        const rewritten = try rewriteArgs(row.source);
        defer a.free(rewritten);
        try std.testing.expect(std.mem.indexOf(u8, rewritten, row.selection) != null);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rewritten, "lda (zeropage_ptr_tmp),y"));
        if (std.mem.indexOf(u8, row.selection, "final_words=1") != null) try std.testing.expect(std.mem.indexOf(u8, rewritten, "lda leaf_a+1") != null);
    }
}
test "domain R33 later indirect byte and integer DMA remain mandatory suffix barriers" {
    for ([_][]const u8{
        "fn leaf(a:u16,b:u8)u16{_=b;return a;}export fn api(p:*volatile u8)u16{return leaf(0x8134,p.*);}export fn main()void{}",
        "const ZeroPage=@import(\"ZeroPage\");fn leaf(a:u16,b:bool)u16{_=b;return a;}export fn api(address:u16)u16{return leaf(0x8134,ZeroPage.reu.compare(address,0x10000,1));}export fn main()void{}",
    }) |source| {
        const parsed = try parser.parseSource(a, source);
        defer parsed.deinit(a);
        const raw = try emitter.emitProgram(a, parsed.program);
        defer a.free(raw);
        const expected = try stripMarkers(raw);
        defer a.free(expected);
        const rewritten = try call_rewrite.rewrite(a, parsed.program, raw);
        defer a.free(rewritten);
        try std.testing.expectEqualStrings(expected, rewritten);
    }
}

const packets = @import("codegen/tass64/record_call_packets.zig");
const branch_layout = @import("codegen/tass64/branch_layout.zig");
const storage = @import("codegen/tass64/storage_model.zig");

test "record call packets match native entry and reject incomplete or altered writes" {
    const parsed = try parser.parseSource(a,
        \\const Board = struct { cells: [2]u8 };
        \\const Game = struct { board: Board, tag: u8 };
        \\fn read(board: *Board) u8 { return board.cells[1]; }
        \\fn forward(game: *Game) u8 { return read(&game.board); }
        \\export fn main() void {
        \\    var game: Game = .{ .board = .{ .cells = [_]u8{1, 2} }, .tag = 3 };
        \\    _ = forward(&game);
        \\}
    );
    defer parsed.deinit(a);
    const args = try domains.recordArguments(a, parsed.program);
    defer a.free(args);
    const assembly =
        \\* = $2000
        \\zeropage_ptr_tmp = $fb
        \\; zeropage_section_begin owner=function:main kind=code
        \\main:
        \\    ldx #>main_game+0
        \\    lda #<main_game+0
        \\    sta forward_game
        \\    stx forward_game+1
        \\    jsr forward
        \\    rts
        \\; zeropage_section_end owner=function:main kind=code
        \\; zeropage_section_begin owner=function:main kind=static_frame
        \\main_game:
        \\    .byte 0,0,0
        \\; zeropage_section_end owner=function:main kind=static_frame
        \\; zeropage_section_begin owner=function:forward kind=code
        \\forward:
        \\    lda forward_game
        \\    sta zeropage_ptr_tmp
        \\    lda forward_game+1
        \\    sta zeropage_ptr_tmp+1
        \\    ldx zeropage_ptr_tmp+1
        \\    lda zeropage_ptr_tmp
        \\    sta read_board
        \\    stx read_board+1
        \\    txa
        \\    jmp read
        \\; zeropage_section_end owner=function:forward kind=code
        \\; zeropage_section_begin owner=function:forward kind=static_frame
        \\forward_game:
        \\    .word 0
        \\; zeropage_section_end owner=function:forward kind=static_frame
        \\; zeropage_section_begin owner=function:read kind=code
        \\read:
        \\    lda read_board
        \\    sta zeropage_ptr_tmp
        \\    lda read_board+1
        \\    sta zeropage_ptr_tmp+1
        \\    ldy #1
        \\    sta (zeropage_ptr_tmp),y
        \\    iny
        \\    sta (zeropage_ptr_tmp),y
        \\    rts
        \\; zeropage_section_end owner=function:read kind=code
        \\; zeropage_section_begin owner=function:read kind=static_frame
        \\read_board = address($10)
        \\; zeropage_section_end owner=function:read kind=static_frame
        \\; zeropage_zp_claim label=read_board addr=$10 size=2 kind=parameter
    ;
    for ([_][2][]const u8{
        .{ "", "" },
        .{ "size=2 kind=parameter", "size=1 kind=parameter" },
        .{ "    sta zeropage_ptr_tmp+1", "    sta zeropage_ptr_tmp" },
        .{ "    jmp read", "    bne read" },
        .{ "main:\n", "main:\n    inc read_board\n" },
        .{ "main:\n", "main:\n    sta $11\n" },
        .{ "    stx read_board+1", "    stx read_board" },
        .{ "    ldx #>main_game+0", "    ldx #1" },
    }, 0..) |change, case| {
        const text = if (case == 0) try a.dupe(u8, assembly) else try std.mem.replaceOwned(u8, a, assembly, change[0], change[1]);
        defer a.free(text);
        var graph = try branch_layout.parseForSize(a, text);
        defer graph.deinit(a);
        var model = storage.Model.init(a);
        defer model.deinit();
        try model.collectWithPromotedParameters(text, graph.raw.items);
        const matched = try packets.match(a, parsed.program, graph, model, args, .{ .function = 0, .index = 0 });
        defer if (matched) |result| a.free(result);
        try std.testing.expectEqual(case == 0 or case == 7, matched != null);
        const origins = try packets.trace(a, parsed.program, graph, model, args, .{ .function = 0, .index = 0 });
        defer if (origins) |result| a.free(result);
        try std.testing.expectEqual(case == 0, origins != null);
        if (case == 0) {
            const result = matched.?;
            try std.testing.expectEqual(@as(usize, 1), origins.?.len);
            try std.testing.expectEqualStrings("main", parsed.program.functions[origins.?[0].caller].name);
            try std.testing.expectEqualStrings("game", origins.?[0].local);
            try std.testing.expectEqual(@as(usize, 1), result.len);
            try std.testing.expectEqualStrings("    jmp read", graph.raw.items[result[0].transfer]);
            try std.testing.expectEqualStrings("    lda forward_game", graph.raw.items[result[0].first_line]);
            var stores: usize = 0;
            for (graph.raw.items, 0..) |line, line_index| {
                if (!std.mem.eql(u8, line, "    sta (zeropage_ptr_tmp),y")) continue;
                const store = packets.indirectStoreAt(parsed.program, graph, model, line_index) orelse return error.MissingStoreOrigin;
                try std.testing.expectEqual(packets.Parameter{ .function = 0, .index = 0 }, store.parameter);
                stores += 1;
            }
            try std.testing.expectEqual(@as(usize, 2), stores);
            try std.testing.expect(!try packets.originWriteDisjoint(a, parsed.program, graph, model, origins.?[0], .{ .label = "main_game", .last = 2 }));
            try std.testing.expect(try packets.originWriteDisjointFromParameter(a, parsed.program, graph, model, origins.?[0], .{ .function = 0, .index = 0 }));
            const changed = try std.mem.replaceOwned(u8, a, text, "    iny\n    sta (zeropage_ptr_tmp),y", "    iny\n    sta zeropage_ptr_tmp\n    sta (zeropage_ptr_tmp),y");
            defer a.free(changed);
            var altered = try branch_layout.parseForSize(a, changed);
            defer altered.deinit(a);
            var altered_model = storage.Model.init(a);
            defer altered_model.deinit();
            try altered_model.collectWithPromotedParameters(changed, altered.raw.items);
            var second: usize = 0;
            for (altered.raw.items, 0..) |line, line_index| {
                if (std.mem.eql(u8, line, "    sta (zeropage_ptr_tmp),y")) second = line_index;
            }
            try std.testing.expect(packets.indirectStoreAt(parsed.program, altered, altered_model, second) == null);
            const read_only = try std.mem.replaceOwned(u8, a, text, "    sta (zeropage_ptr_tmp),y", "    lda (zeropage_ptr_tmp),y");
            defer a.free(read_only);
            var read_graph = try branch_layout.parseForSize(a, read_only);
            defer read_graph.deinit(a);
            const reader: packets.Parameter = .{ .function = 0, .index = 0 };
            try std.testing.expect(try packets.stableReadScratch(a, parsed.program, read_graph, model, reader));
            try std.testing.expect(!try packets.stableReadScratch(a, parsed.program, graph, model, reader));
            for ([_][2][]const u8{
                .{ "    ldy #1", "bypass:\n    ldy #1" },
                .{ "    ldy #1", "    ldy #1\n    sta $fb" },
            }, 0..) |mutation, index| {
                const variant = try std.mem.replaceOwned(u8, a, read_only, mutation[0], mutation[1]);
                defer a.free(variant);
                const input = if (index == 0) try std.mem.replaceOwned(u8, a, variant, "    jmp read", "    jmp bypass") else try a.dupe(u8, variant);
                defer a.free(input);
                var unsafe = try branch_layout.parseForSize(a, input);
                defer unsafe.deinit(a);
                try std.testing.expect(!try packets.stableReadScratch(a, parsed.program, unsafe, model, reader));
            }
            const direct = (try packets.match(a, parsed.program, graph, model, args, .{ .function = 1, .index = 0 })) orelse return error.MissingDirectPacket;
            defer a.free(direct);
            try std.testing.expectEqual(@as(usize, 1), direct.len);
            try std.testing.expectEqualStrings("    jsr forward", graph.raw.items[direct[0].transfer]);
        }
    }
}
