const std = @import("std");
const ast = @import("../../ast.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");
const allocation = @import("zero_page_allocation.zig");
const scalars = @import("zero_page_scalars.zig");

const proof = @import("call_argument_proof.zig");
const Marker = proof.Marker;
const Replacement = union(enum) { capture: Marker, reload_high: Marker };
fn trim(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r\n");
}
const shape = proof.shape;

// No suffix instruction may observe or overwrite a destination before the old
// copy phase. Calls, unknown syntax and noncanonical memory are barriers. The
// final byte keeps its original copy. A final word instead reloads the high
// byte from its proven readable RAM cell at the old copy position.
fn suffixSafe(model: storage.Model, lines: []const []const u8, store: Marker, copy: Marker, end: usize) bool {
    const destination = model.resolve(.{ .name = store.target }, store.width) orelse return false;
    const temporary = model.resolve(.{ .name = store.temp }, store.width) orelse return false;
    if (!model.disjoint(destination, store.width, temporary, store.width)) return false;
    if (!proof.visible(model, destination) or !proof.visible(model, temporary)) return false;
    var index = store.line + 1 + store.width;
    while (index < end) : (index += 1) {
        if (index == copy.line) {
            index += 2 * store.width;
            continue;
        }
        const line = trim(lines[index]);
        if (line.len == 0 or line[0] == ';' or std.mem.endsWith(u8, line, ":")) continue;
        const inst = machine.Instruction.parse(line) orelse return false;
        const effects = inst.effects();
        if (effects.barrier) return false;
        if (effects.memory == .none or effects.memory == .stack) continue;
        if (inst.operand != .direct) return false;
        const other = model.resolve(inst.operand.direct, 1) orelse return false;
        if (!model.disjoint(destination, store.width, other, 1)) return false;
        // The discarded capture is private only if no other suffix operation
        // observes or replaces it. Distinct destination labels alone do not
        // prove that a shared compiler temporary is dead.
        if (!model.disjoint(temporary, store.width, other, 1)) return false;
    }
    return true;
}

// Borrow complete unoptimized assembly; return owned assembly. Source-owned
// ZP relocation and the existing optimizer run only AFTER this proof/rewrite.
pub fn rewrite(allocator: std.mem.Allocator, program: ast.Program, assembly: []const u8) ![]u8 {
    if (program.zeropage_module != null or program.zeropage_options.memory.placements.len != 0 or std.mem.indexOf(u8, assembly, "; zeropage_scalar_call_store ") == null)
        return allocator.dupe(u8, assembly);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var split = std.mem.splitScalar(u8, assembly, '\n');
    while (split.next()) |line| try lines.append(allocator, line);
    const decisions = try allocation.parameterDecisions(allocator, program, lines.items);
    defer scalars.freeDecisions(allocator, decisions);
    var model = storage.Model.init(allocator);
    defer model.deinit();
    try model.collect(assembly);
    const skip = try allocator.alloc(bool, lines.items.len);
    defer allocator.free(skip);
    @memset(skip, false);
    const replacements = try allocator.alloc(?Replacement, lines.items.len);
    defer allocator.free(replacements);
    @memset(replacements, null);
    var selected: usize = 0;
    var final_words: usize = 0;
    const calls = try proof.collect(allocator, program, lines.items, decisions, model);
    defer if (calls) |validated| proof.deinit(allocator, validated);
    if (calls) |validated| for (validated) |call| {
        for (call.arguments) |argument| {
            const decision = decisions[argument.decision];
            // Placement-only layout/domain exclusions may only enter this
            // consumer-specific proof after all other typed/storage exclusions
            // and the complete producer call grammar have been checked.
            if (decision.reason != .eligible and decision.reason != .layout_observer and decision.reason != .unproven_memory_domain) continue;
            const store = argument.store.?;
            const copied = argument.copy.?;
            const later_copy = store.index + 1 < call.arguments.len;
            if (!later_copy and store.width != 2) continue;
            if (!suffixSafe(model, lines.items, store, copied, call.end)) continue;
            replacements[store.line + 1] = .{ .capture = store };
            if (store.width == 2) skip[store.line + 2] = true;
            for (copied.line + 1..copied.line + 1 + 2 * store.width) |removed| skip[removed] = true;
            if (!later_copy) {
                // The validated copy phase contains no intermediate observer.
                // Reload the unchanged visible-RAM high byte at the old final
                // LDA position, preserving exact final A/NZ and all other state.
                skip[copied.line + 1] = false;
                replacements[copied.line + 1] = .{ .reload_high = store };
                final_words += 1;
            }
            selected += 1;
        }
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (lines.items, 0..) |line, index| {
        if (skip[index]) continue;
        // These private proof markers must not become adjacency barriers for
        // existing optimizers, including when no argument was selected.
        if (std.mem.startsWith(u8, trim(line), "; zeropage_scalar_call_")) continue;
        if (replacements[index]) |replacement| {
            switch (replacement) {
                .capture => |store| {
                    try out.writer.print("    sta {s}\n", .{store.target});
                    if (store.width == 2) try out.writer.print("    stx {s}+1\n", .{store.target});
                },
                .reload_high => |store| try out.writer.print("    lda {s}+1\n", .{store.target}),
            }
        } else {
            try out.writer.writeAll(line);
            if (index + 1 < lines.items.len) try out.writer.writeByte('\n');
        }
    }
    if (selected != 0) try out.writer.print("; zeropage_scalar_call_selection direct_arguments={d} final_words={d}\n", .{ selected, final_words });
    return out.toOwnedSlice();
}

test "argument suffix permits disjoint RAM but rejects aliases and unknown memory" {
    var model = storage.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.collect("* = $0801\n; zeropage_section_begin owner=function:f kind=static_frame\nf_x:\n.word 0\nf_y:\n.word 0\ntmp:\n.word 0\n; zeropage_section_end owner=function:f kind=static_frame\n");
    const store: Marker = .{ .id = 0, .index = 0, .width = 2, .temp = "tmp", .target = "f_x", .line = 0 };
    const copy: Marker = .{ .id = 0, .index = 0, .width = 2, .temp = "tmp", .target = "f_x", .line = 5 };
    const safe = [_][]const u8{ "marker", "sta tmp", "stx tmp+1", "lda f_y", "sta f_y", "copy", "lda tmp", "sta f_x", "lda tmp+1", "sta f_x+1", "lda f_y" };
    try std.testing.expect(suffixSafe(model, &safe, store, copy, safe.len));
    for ([_][]const u8{ "lda f_x", "lda f_x+1", "sta f_x", "lda tmp", "lda tmp+1", "sta tmp", "lda ($fb),y", "lda f_y,x", "jsr helper", "lda $d012", "madeup text" }) |barrier| {
        var altered = safe;
        altered[3] = barrier;
        try std.testing.expect(!suffixSafe(model, &altered, store, copy, altered.len));
    }
}

test "store copy matcher rejects partial and mismatched chunks" {
    const store: Marker = .{ .id = 0, .index = 0, .width = 2, .temp = "tmp", .target = "f_x", .line = 0 };
    const copy: Marker = .{ .id = 0, .index = 0, .width = 2, .temp = "tmp", .target = "f_x", .line = 3 };
    const lines = [_][]const u8{ "store", "sta tmp", "stx tmp+1", "copy", "lda tmp", "sta f_x", "lda tmp+1", "sta f_x+1" };
    try std.testing.expect(shape(&lines, store, copy));
    var wrong = lines;
    wrong[7] = "sta f_x";
    try std.testing.expect(!shape(&wrong, store, copy));
    try std.testing.expect(!shape(lines[0..7], store, copy));
}

const R33Source = "fn leaf(a:u16,b:u8)u16{return a;} export fn main()void{_=leaf(0x8134,7);}";
fn r33Selection(source: []const u8, assembly: []const u8, wanted: bool) !void {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);
    const result = try rewrite(std.testing.allocator, parsed.program, assembly);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(wanted, std.mem.indexOf(u8, result, "; zeropage_scalar_call_selection ") != null);
}
fn r33Raw(source: []const u8) ![]u8 {
    const parser = @import("../../parser.zig");
    const emitter = @import("emitter.zig");
    const parsed = try parser.parseSource(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);
    return emitter.emitProgram(std.testing.allocator, parsed.program);
}
test "R33 complete copy phase rejects stack observations labels and extra operations" {
    const raw = try r33Raw(R33Source);
    defer std.testing.allocator.free(raw);
    const needle = "    lda zeropage_call_arg_0+1\n    sta leaf_a+1\n";
    for ([_][]const u8{ "    php\n", "    pha\n", "extra_entry:\n", "    tax\n", "    sta leaf_b\n", "    nop\n" }) |insert| {
        const replacement = try std.mem.concat(std.testing.allocator, u8, &.{ needle, insert });
        defer std.testing.allocator.free(replacement);
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, raw, needle, replacement);
        defer std.testing.allocator.free(changed);
        try r33Selection(R33Source, changed, false);
    }
}
test "R33 complete copy phase rejects missing duplicate malformed and mismatched metadata" {
    const raw = try r33Raw(R33Source);
    defer std.testing.allocator.free(raw);
    const changes = [_][2][]const u8{
        .{ "; zeropage_scalar_call_begin id=0 callee=leaf count=2", "; zeropage_scalar_call_begin id=0 callee=leaf count=1" },
        .{ "; zeropage_scalar_call_copy id=0 index=1", "; zeropage_scalar_call_copy id=0 index=0" },
        .{ "; zeropage_scalar_call_copy id=0 index=1", "; zeropage_scalar_call_copy id=0 index=9" },
        .{ "; zeropage_scalar_call_end id=0", "; zeropage_scalar_call_end id=0 extra=1" },
        .{ "; zeropage_scalar_call_end id=0", "; zeropage_scalar_call_end id=0\n; zeropage_scalar_call_end id=0" },
        .{ "; zeropage_scalar_call_end id=0", "; missing_end id=0" },
        .{ "; zeropage_scalar_call_store id=0 index=1 width=1", "; zeropage_scalar_call_store id=0 index=1 width=2" },
        .{ "; zeropage_scalar_call_store id=0 index=0 width=2", "; zeropage_scalar_call_store id=0 index=0 width=2 extra=1" },
        .{ "    jsr leaf\n", "    jsr other\n" },
        .{ "    jsr leaf\n", "    jsr leaf+1\n" },
        .{ "    jsr leaf\n", "    jsr $2000\n" },
    };
    for (changes) |pair| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, raw, pair[0], pair[1]);
        defer std.testing.allocator.free(changed);
        try r33Selection(R33Source, changed, false);
    }
}
test "R33 local argument proof can recover observer guarded storage without changing scalar eligibility" {
    const source = "fn observer()usize{var local:u8=0;return @intFromPtr(&local);} fn leaf(a:u16,b:u8)u16{return a;} export fn main()void{_=observer();_=leaf(0x8134,7);}";
    const raw = try r33Raw(source);
    defer std.testing.allocator.free(raw);
    try r33Selection(source, raw, true);
}
test "R33 complete call proof preserves first expression calls but blocks later calls" {
    const early = "fn first()u16{return 0x8134;} fn leaf(a:u16,b:u8)u16{return a;} export fn main()void{_=leaf(first(),7);}";
    const late = "fn later()u8{return 7;} fn leaf(a:u16,b:u8)u16{return a;} export fn main()void{_=leaf(0x8134,later());}";
    const e = try r33Raw(early);
    defer std.testing.allocator.free(e);
    try r33Selection(early, e, true);
    const l = try r33Raw(late);
    defer std.testing.allocator.free(l);
    try r33Selection(late, l, false);
}
test "R33 complete call proof requires unique canonical compiler captures" {
    const raw = try r33Raw(R33Source);
    defer std.testing.allocator.free(raw);
    for ([_][2][]const u8{ .{ "zeropage_call_arg_0:\n", "capture_alias:\nzeropage_call_arg_0:\n" }, .{ "zeropage_call_arg_0:\n", "zeropage_call_arg_0:\nzeropage_call_arg_0:\n" }, .{ "zeropage_call_arg_0:\n", "ZEROPAGE_CALL_ARG_0:\nzeropage_call_arg_0:\n" }, .{ "zeropage_call_arg_0:\n    .word 0", "zeropage_call_arg_0:\n    .byte 0,0" } }) |pair| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, raw, pair[0], pair[1]);
        defer std.testing.allocator.free(changed);
        try r33Selection(R33Source, changed, false);
    }
}

test "R33 retained dynamic pointer later volatile read is still a complete call barrier" {
    const source = "fn leaf(a:u16,b:u8)u16{return a;} export fn main()void{const address:usize=0xdc04;const p:*volatile u8=@ptrFromInt(address);_=leaf(0x8134,p.*);}";
    const raw = try r33Raw(source);
    defer std.testing.allocator.free(raw);
    try r33Selection(source, raw, false);
}
test "R33 dynamic pointer first volatile word producer retains reads and final high reload" {
    const source = "fn leaf(a:u16)u16{return a;} export fn main()void{const address:usize=0xdc04;const p:*volatile u16=@ptrFromInt(address);_=leaf(p.*);}";
    const raw = try r33Raw(source);
    defer std.testing.allocator.free(raw);
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);
    const result = try rewrite(std.testing.allocator, parsed.program, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "final_words=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "    lda leaf_a+1\n") != null);
    // Every real producer opcode before its capture remains byte-for-byte.
    const prefix = raw[0..std.mem.indexOf(u8, raw, "; zeropage_scalar_call_store ").?];
    var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected.deinit();
    var split = std.mem.splitScalar(u8, prefix, '\n');
    while (split.next()) |line| {
        if (std.mem.startsWith(u8, trim(line), "; zeropage_scalar_call_")) continue;
        try expected.writer.writeAll(line);
        if (split.index != null) try expected.writer.writeByte('\n');
    }
    try std.testing.expect(std.mem.startsWith(u8, result, expected.written()));
}
test "R33 nested annotated first expressions and pre-copy stack effects remain valid" {
    const source = "fn identity(value:u16)u16{return value;} fn leaf(a:u16,b:u8)u16{return a;} export fn main()void{_=leaf(identity(0x8134),7);}";
    const raw = try r33Raw(source);
    defer std.testing.allocator.free(raw);
    try r33Selection(source, raw, true);
    const ordinary = try r33Raw(R33Source);
    defer std.testing.allocator.free(ordinary);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, ordinary, "; zeropage_scalar_call_copy id=0 index=0", "    php\n    plp\n    pha\n    pla\n; zeropage_scalar_call_copy id=0 index=0");
    defer std.testing.allocator.free(changed);
    try r33Selection(R33Source, changed, true);
}
const R33BoundaryData =
    \\; zeropage_section_begin owner=function:leaf kind=static_frame
    \\leaf_a:
    \\.word 0
    \\leaf_b:
    \\.byte 0
    \\; zeropage_section_end owner=function:leaf kind=static_frame
;
const R33BoundaryScratch =
    \\; zeropage_section_begin owner=compiler kind=scratch
    \\zeropage_call_arg_0:
    \\.word 0
    \\zeropage_call_arg_1:
    \\.word 0
    \\; zeropage_section_end owner=compiler kind=scratch
;
const R33BoundaryCode =
    \\main:
    \\; zeropage_scalar_call_begin id=0 callee=leaf count=2
    \\lda #52
    \\ldx #129
    \\; zeropage_scalar_call_store id=0 index=0 width=2 temp=zeropage_call_arg_0 target=leaf_a
    \\sta zeropage_call_arg_0
    \\stx zeropage_call_arg_0+1
    \\lda #7
    \\; zeropage_scalar_call_store id=0 index=1 width=1 temp=zeropage_call_arg_1 target=leaf_b
    \\sta zeropage_call_arg_1
    \\; zeropage_scalar_call_copy id=0 index=0 width=2 temp=zeropage_call_arg_0 target=leaf_a
    \\lda zeropage_call_arg_0
    \\sta leaf_a
    \\lda zeropage_call_arg_0+1
    \\sta leaf_a+1
    \\; zeropage_scalar_call_copy id=0 index=1 width=1 temp=zeropage_call_arg_1 target=leaf_b
    \\lda zeropage_call_arg_1
    \\sta leaf_b
    \\; zeropage_scalar_call_end id=0
    \\jsr leaf
    \\rts
    \\leaf:
    \\rts
;
test "R33 capture and destination whole-frame visibility rejects ROM shadow and IO crossings" {
    for ([_]struct { origin: u16, fill: u16 = 0, selected: bool }{
        .{ .origin = 0x9ff9, .selected = true },                  .{ .origin = 0x9ffa, .selected = false },
        .{ .origin = 0xcff9, .selected = true },                  .{ .origin = 0xcffa, .selected = false },
        .{ .origin = 0xa000, .selected = false },                 .{ .origin = 0xe000, .selected = false },
        .{ .origin = 0x0801, .fill = 0x9800, .selected = false },
    }) |case| {
        const assembly = try std.fmt.allocPrint(std.testing.allocator, "* = ${x}\n{s}\n.fill {d},0\n{s}\n{s}\n", .{ case.origin, R33BoundaryData, case.fill, R33BoundaryScratch, R33BoundaryCode });
        defer std.testing.allocator.free(assembly);
        try r33Selection(R33Source, assembly, case.selected);
    }
}
test "R33 call proof frees valid and partially invalid nested call inventories on allocation failure" {
    const source = "fn identity(value:u16)u16{return value;} fn leaf(a:u16,b:u8)u16{return a;} export fn main()void{_=leaf(identity(0x8134),7);}";
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);
    const raw = try r33Raw(source);
    defer std.testing.allocator.free(raw);
    const invalid = try std.mem.replaceOwned(u8, std.testing.allocator, raw, "; zeropage_scalar_call_end id=0", "; zeropage_scalar_call_end id=0 extra=1");
    defer std.testing.allocator.free(invalid);
    for ([_][]const u8{ raw, invalid }) |assembly| try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, program: ast.Program, text: []const u8) !void {
            const result = rewrite(allocator, program, text) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => return err,
            };
            defer allocator.free(result);
        }
    }.run, .{ parsed.program, assembly });
}
