const std = @import("std");
const parser = @import("../../parser.zig");
const pipeline = @import("pipeline.zig");
const allocation = @import("zero_page_allocation.zig");
const map = @import("map.zig");

const allocator = std.testing.allocator;
const kernel =
    \\pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scratch } };
;
const work =
    // Public ABI slots keep complete word staging across call optimizations,
    // so allocation, capacity, lifecycle and corrupt-map checks stay active.
    \\export fn work(a: u16, b: u16) u16 { return a + b; }
    \\export fn main() void { _ = work(0x8100, 257); }
;

fn emit(settings: []const u8, body: []const u8) ![]u8 {
    const source = try std.mem.concat(allocator, u8, &.{ settings, "\n", body });
    defer allocator.free(source);
    const parsed = try parser.parseSource(allocator, source);
    defer parsed.deinit(allocator);
    return pipeline.emitProgram(allocator, parsed.program);
}

fn has(text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("missing zero-page assembly: {s}\n", .{needle});
        return error.TestExpectedEqual;
    }
}

fn lacks(text: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, text, needle) == null);
}

fn ordered(text: []const u8, needles: []const []const u8) !void {
    var cursor: usize = 0;
    for (needles) |needle| {
        const next = std.mem.indexOfPos(u8, text, cursor, needle) orelse return error.TestExpectedEqual;
        cursor = next + needle.len;
    }
}

// Compare instruction/data/label structure, allowing equivalent typed-address
// aliases and the added byte-neutral policy comments. Binary equivalence is a
// separate assembler-backed fixture check, not claimed by this text helper.
fn normalized(text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == ';') continue;
        if (std.mem.indexOf(u8, line, " = address(")) |at| {
            try std.testing.expect(std.mem.endsWith(u8, line, ")"));
            try out.writer.print("{s} = {s}\n", .{ line[0..at], line[at + " = address(".len .. line.len - 1] });
        } else try out.writer.print("{s}\n", .{line});
    }
    return out.toOwnedSlice();
}

test "zero page backend explicit compatibility retains ordinary calls and instruction data structure" {
    const before = try emit("", work);
    defer allocator.free(before);
    const after = try emit("pub const zeropage_options = .{ .zero_page = .{} };", work);
    defer allocator.free(after);
    const a = try normalized(before);
    defer allocator.free(a);
    const b = try normalized(after);
    defer allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
    try has(after, "jsr work");
    try has(after, "zeropage_call_arg_0:\n    .word 0");
    try lacks(after, "zeropage_zp_enter:");
}

test "zero page backend kernel moves scalar scratch initializes it and wraps every normal main return" {
    const assembly = try emit(kernel, work);
    defer allocator.free(assembly);
    try has(assembly, "zeropage_call_arg_1 = address($");
    try lacks(assembly, "zeropage_call_arg_1:\n");
    try has(assembly, "zeropage_zp_claim label=zeropage_call_arg_1");
    try ordered(assembly, &.{ "zeropage_entry:\n    jsr zeropage_zp_enter", "    jsr main\n    jmp zeropage_zp_leave", "main:", "jsr work" });
    try ordered(assembly, &.{ "zeropage_zp_enter:", "php\n    pha\n    txa\n    pha\n    tya\n    pha", "zeropage_zp_snapshot", "lda #0", "plp\n    rts", "zeropage_zp_leave:", "zeropage_zp_snapshot", "plp\n    rts" });
}

test "zero page backend strict BASIC keeps scalar scratch in RAM when its pool is exhausted" {
    const before = try emit("", work);
    defer allocator.free(before);
    const after = try emit("pub const zeropage_options = .{ .zero_page = .{ .profile = .basic, .allocation = .scratch } };", work);
    defer allocator.free(after);
    const a = try normalized(before);
    defer allocator.free(a);
    const b = try normalized(after);
    defer allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
    try has(after, "zeropage_zp_spill label=zeropage_call_arg_1 size=2 reason=capacity");
    try lacks(after, "zeropage_zp_enter:");
}

test "zero page backend custom pointer pairs remap all aliases even when scalar allocation is off" {
    const assembly = try emit(
        \\pub const zeropage_options = .{ .zero_page = .{
        \\    .profile = .kernal, .ranges = .{ .{ .addr = 0x20, .size = 8 } },
        \\} };
    , work);
    defer allocator.free(assembly);
    for ([_][]const u8{ "zeropage_console_ptr", "zeropage_string_dst_ptr", "zeropage_ptr_tmp" }) |label| {
        const needle = try std.fmt.allocPrint(allocator, "{s} = address($20)", .{label});
        defer allocator.free(needle);
        try has(assembly, needle);
    }
    for ([_][]const u8{ "zeropage_string_ptr", "zeropage_string_src_ptr" }) |label| {
        const needle = try std.fmt.allocPrint(allocator, "{s} = address($22)", .{label});
        defer allocator.free(needle);
        try has(assembly, needle);
    }
    try has(assembly, "zeropage_kernal_ptr = zeropage_string_src_ptr");
    try has(assembly, "zeropage_zp_enter:");
    try lacks(assembly, "zeropage_zp_zero_");
    try has(assembly, "zeropage_call_arg_0:\n");
}

test "zero page backend indexed immediate indirect and opaque address references pin scratch definitions" {
    const parsed = try parser.parseSource(allocator, kernel ++ "\nexport fn main() void {}\n");
    defer parsed.deinit(allocator);
    for ([_][]const u8{
        "    lda zeropage_call_arg_0,y",
        "    lda #<zeropage_call_arg_0",
        "    lda (zeropage_call_arg_0),y",
        "    lda zeropage_call_arg_0+2",
        "; inline asm from ZeroPage line 1\n    LDA zeropage_call_arg_0\n; end inline asm",
    }) |instruction| {
        const input = try std.mem.concat(allocator, u8, &.{
            "* = $080d\nzeropage_entry:\n; zeropage_section_begin owner=function:main kind=code lifetime=static address=near\nmain:\n",
            instruction,
            "\n    rts\n; zeropage_section_end owner=function:main kind=code\n; zeropage_section_begin owner=compiler kind=scratch lifetime=static address=near\nzeropage_call_arg_0:\n    .word 0\n; zeropage_section_end owner=compiler kind=scratch\n; zeropage_zero_page_runtime_anchor\n",
        });
        defer allocator.free(input);
        const output = try allocation.apply(allocator, parsed.program, input);
        defer allocator.free(output);
        try has(output, "zeropage_call_arg_0:\n    .word 0");
        try has(output, "zeropage_zp_spill label=zeropage_call_arg_0 size=2 reason=address_or_index_or_asm");
        try lacks(output, "zeropage_call_arg_0 = address(");
    }
}

test "zero page backend real inline assembly references retain their private scratch cell" {
    const body =
        \\fn work(a: u16, b: u16) u16 { return a + b; }
        \\export fn main() void {
        \\    _ = work(1, 257);
        \\    asm {
        \\        lda #<zeropage_call_arg_0
        \\    }
        \\}
    ;
    const assembly = try emit(kernel, body);
    defer allocator.free(assembly);
    try has(assembly, "zeropage_call_arg_0:\n    .word 0");
    try has(assembly, "zeropage_zp_spill label=zeropage_call_arg_0 size=2 reason=address_or_index_or_asm");
}

test "zero page backend forbidden ROM policies diagnose through public emission without double freeing" {
    for ([_][]const u8{ "jsr $ff87", "JSR $FF87", "JsR $A000", "JSR $ff00+135", "jsr main+$9800" }) |instruction| {
        const body = try std.mem.concat(allocator, u8, &.{ "export fn main() void {\n    asm {\n        ", instruction, "\n    }\n}\n" });
        defer allocator.free(body);
        try std.testing.expectError(error.UnsupportedZeroPageRomService, emit(kernel, body));
    }
}

test "zero page backend kernel permits ordinary public KERNAL jump table entries" {
    const assembly = try emit(kernel,
        \\export fn main() void {
        \\    asm {
        \\        jsr $ffd2
        \\    }
        \\}
    );
    defer allocator.free(assembly);
    try has(assembly, "jsr $ffd2");
}

test "zero page backend bare requires external takeover before entry and a non BASIC image" {
    try std.testing.expectError(error.UnsupportedZeroPageBareEntry, emit(
        "pub const zeropage_options = .{ .zero_page = .{ .profile = .bare, .interrupts = .application } };",
        "export fn main() void {}",
    ));
    const raw =
        \\pub const zeropage_options = .{
        \\    .image = .{ .basic_stub = false },
        \\    .zero_page = .{ .profile = .bare, .interrupts = .application, .allocation = .scratch },
        \\};
    ;
    const assembly = try emit(raw, work);
    defer allocator.free(assembly);
    try has(assembly, "zeropage_call_arg_1 = address($");
    try lacks(assembly, "basic_next");
    try std.testing.expectError(error.UnsupportedZeroPageRomService, emit(raw,
        \\export fn main() void {
        \\    asm {
        \\        jsr $ffd2
        \\    }
        \\}
    ));
}

test "zero page backend low origin cannot overlap compiler owned physical page zero" {
    try std.testing.expectError(error.UnsupportedZeroPageLowImage, emit(
        \\pub const zeropage_options = .{
        \\    .image = .{ .load_addr = 0x10, .entry_addr = 0x10, .basic_stub = false },
        \\    .zero_page = .{},
        \\};
    , "export fn main() void {}"));
}

const module_body =
    \\pub const zeropage_module = .{ .id = "zero_page_abi", .abi = 1, .exports = .{ .entry = entry }, .deps = .{} };
    \\fn entry(value: u8) u8 { return value + 1; }
    \\export fn main() void {}
;
const module_settings =
    \\pub const zeropage_options = .{
    \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
    \\    .abi = .{ .functions = .{ .entry = .{ .frame = .stack } } },
;

test "zero page backend module ABI keeps compatibility output and rejects automatic ownership" {
    const old = try emit(module_settings ++ "\n};", module_body);
    defer allocator.free(old);
    const compatible = try emit(module_settings ++ "\n.zero_page = .{},\n};", module_body);
    defer allocator.free(compatible);
    const a = try normalized(old);
    defer allocator.free(a);
    const b = try normalized(compatible);
    defer allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
    try lacks(compatible, "zeropage_zp_enter:");
    try std.testing.expectError(error.UnsupportedZeroPageModuleABI, emit(module_settings ++ "\n.zero_page = .{ .allocation = .scratch },\n};", module_body));
}

fn claimField(line: []const u8, key: []const u8) ?[]const u8 {
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    while (fields.next()) |field| {
        if (std.mem.startsWith(u8, field, key) and field.len > key.len and field[key.len] == '=') return field[key.len + 1 ..];
    }
    return null;
}

// Synthetic label output tests map validation only. Real assembler geometry and
// startup execution are covered by the integration/native worker's fixtures.
fn syntheticClaimLabels(assembly: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, assembly, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "; zeropage_zp_claim ")) continue;
        const label = claimField(line, "label").?;
        const address = try std.fmt.parseInt(u16, claimField(line, "addr").?, 10);
        try out.writer.print("al {x:0>6} .{s}\n", .{ address, label });
    }
    if (std.mem.indexOf(u8, assembly, "zeropage_zp_enter:") != null)
        try out.writer.writeAll("al 004000 .zeropage_zp_enter\n");
    return out.toOwnedSlice();
}

test "zero page backend fully direct word call needs no capture claim or entry lifecycle" {
    const parsed = try parser.parseSource(allocator, kernel ++
        \\
        \\fn identity(value: u16) u16 { return value; }
        \\export fn main() void { _ = identity(0x8134); }
    );
    defer parsed.deinit(allocator);
    const assembly = try pipeline.emitBeforeSingleCallLeaf(allocator, parsed.program);
    defer allocator.free(assembly);
    try has(assembly, "sta identity_value\n    stx identity_value+1\n");
    try has(assembly, "txa\n    jsr identity\n");
    try lacks(assembly, "sta zeropage_call_arg_0\n");
    try lacks(assembly, "zeropage_call_arg_0:\n");
    try lacks(assembly, "zeropage_zp_claim label=zeropage_call_arg_");
    try lacks(assembly, "zeropage_zp_enter:");
    try lacks(assembly, "zeropage_zp_leave:");
    try lacks(assembly, "zeropage_zp_snapshot:");
    // Unused capture data is pruned before ZP planning. It must neither borrow
    // system bytes nor create initialization/snapshot/lifecycle obligations.
    const labels = try syntheticClaimLabels(assembly);
    defer allocator.free(labels);
    const output = try map.emitProgramJson(allocator, parsed.program, assembly, labels, "synthetic-direct.prg", 0x0801, 0);
    defer allocator.free(output);
    const json = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer json.deinit();
    const zp = json.value.object.get("zero_page").?.object;
    try std.testing.expect(!zp.get("entry_lifecycle").?.bool);
    try std.testing.expectEqual(@as(i64, 0), zp.get("restored_bytes").?.integer);
    for (zp.get("claims").?.array.items) |claim| {
        try std.testing.expect(!std.mem.startsWith(u8, claim.object.get("label").?.string, "zeropage_call_arg_"));
    }
}

test "zero page backend map verifies actual claim aliases and normal exit restoration contract" {
    const parsed = try parser.parseSource(allocator, kernel ++ "\n" ++ work);
    defer parsed.deinit(allocator);
    const assembly = try pipeline.emitProgram(allocator, parsed.program);
    defer allocator.free(assembly);
    const labels = try syntheticClaimLabels(assembly);
    defer allocator.free(labels);
    const output = try map.emitProgramJson(allocator, parsed.program, assembly, labels, "synthetic.prg", 0x0801, 0);
    defer allocator.free(output);
    const json = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer json.deinit();
    const zp = json.value.object.get("zero_page").?.object;
    try std.testing.expectEqualStrings("kernal", zp.get("profile").?.string);
    try std.testing.expectEqualStrings("normal_exit", zp.get("restoration_scope").?.string);
    try std.testing.expect(!zp.get("async_basic_restore").?.bool);
    try std.testing.expect(zp.get("entry_lifecycle").?.bool);
    try std.testing.expect(zp.get("restored_bytes").?.integer > 0);
    const bad_labels = try std.mem.concat(allocator, u8, &.{ labels, "al 000000 .zeropage_call_arg_1\n" });
    defer allocator.free(bad_labels);
    const unexpected = map.emitProgramJson(allocator, parsed.program, assembly, bad_labels, "synthetic.prg", 0x0801, 0) catch |err| {
        try std.testing.expectEqual(error.InvalidZeroPageClaimMap, err);
        return;
    };
    allocator.free(unexpected);
    return error.TestExpectedError;
}
