const std = @import("std");
const ast = @import("../../ast.zig");
const policy = @import("../../zero_page.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");

pub const Stats = struct { setups_forwarded: usize = 0, low_loads_removed: usize = 0, high_loads_replaced: usize = 0, bytes_saved: usize = 0, direct_bases_folded: usize = 0 };
pub const Result = struct { assembly: []u8, stats: Stats };
const Value = "zeropage_ptr_value";
const Pointer = "zeropage_ptr_tmp";
fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r\n");
}
fn same(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
fn visible(frame: storage.Frame) bool {
    return frame.valid and frame.ordinary_ram and (frame.upper <= 0xa000 or (frame.lower >= 0xc000 and frame.upper <= 0xd000));
}
fn unchanged(allocator: std.mem.Allocator, assembly: []const u8) !Result {
    return .{ .assembly = try allocator.dupe(u8, assembly), .stats = .{} };
}
fn fixedPair(allocator: std.mem.Allocator, program: ast.Program, lines: []const []const u8) !?u8 {
    const pairs: ?policy.StackPairs = if (program.zeropage_options.stack) |stack| .{ .sp = stack.zp.sp, .fp = stack.zp.fp } else null;
    var plan = try policy.resolve(allocator, program.zeropage_options.zero_page, pairs);
    defer plan.deinit(allocator);
    const owned = plan.find(Pointer) orelse return null;
    if (owned.kind != .pointer or owned.size != 2 or owned.addr != plan.ptr or plan.ptr < 2 or plan.ptr > 0xfd) return null;
    if (!plan.owned[plan.ptr] or !plan.owned[@as(usize, plan.ptr) + 1]) return null;
    for (plan.claims.items) |other| {
        if (same(other.label, Pointer)) continue;
        if (@as(u16, other.addr) < @as(u16, plan.ptr) + 2 and @as(u16, plan.ptr) < @as(u16, other.addr) + other.size) return null;
    }
    var count: usize = 0;
    var address: ?u8 = null;
    for (lines) |raw| {
        const line = trim(raw);
        if (std.mem.endsWith(u8, line, ":") and same(line[0 .. line.len - 1], Pointer)) return null;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!same(trim(line[0..equals]), Pointer)) continue;
        if (!std.mem.eql(u8, trim(line[0..equals]), Pointer)) return null;
        count += 1;
        var expr = trim(line[equals + 1 ..]);
        if (std.mem.startsWith(u8, expr, "address(") and std.mem.endsWith(u8, expr, ")")) expr = trim(expr[8 .. expr.len - 1]);
        const value = machine.integer(expr) orelse return null;
        // This pass precedes late allocation: canonical emitted FB, or an
        // already explicit exact planned pair, never an arbitrary numeric alias.
        if (value < 2 or value > 0xfd or (value != 0xfb and value != plan.ptr)) return null;
        address = @intCast(value);
    }
    return if (count == 1) address else null;
}
fn valueWord(model: storage.Model, lines: []const []const u8) ?storage.Location {
    var found: ?[]const u8 = null;
    var definition: usize = 0;
    for (lines, 0..) |raw, index| {
        const line = trim(raw);
        if (const_index: {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse break :const_index false;
            break :const_index same(trim(line[0..eq]), Value);
        }) return null;
        if (!std.mem.endsWith(u8, line, ":") or !same(line[0 .. line.len - 1], Value)) continue;
        if (found != null) return null;
        found = line[0 .. line.len - 1];
        definition = index;
    }
    const name = found orelse return null;
    if (!std.mem.eql(u8, name, Value)) return null;
    if (definition + 1 >= lines.len or !std.mem.eql(u8, trim(lines[definition + 1]), ".word 0")) return null;
    const loc = model.resolve(.{ .name = name }, 2) orelse return null;
    const frame = model.frames.items[loc.frame];
    if (!visible(frame) or !std.mem.eql(u8, frame.owner, "compiler:scratch")) return null;
    var labels = model.labels.iterator();
    while (labels.next()) |entry| {
        const other = entry.value_ptr.*;
        if (other.frame == loc.frame and other.offset >= loc.offset and other.offset < loc.offset + 2 and !std.mem.eql(u8, entry.key_ptr.*, name)) return null;
    }
    return loc;
}
fn exact(raw: []const u8, op: machine.Op, name: []const u8, offset: i32) bool {
    if (std.mem.indexOfScalar(u8, raw, '@') != null) return false;
    const inst = machine.Instruction.parse(trim(raw)) orelse return false;
    return inst.op == op and inst.operand == .direct and std.mem.eql(u8, inst.operand.direct.name, name) and inst.operand.direct.offset == offset;
}
fn pattern(lines: []const []const u8, index: usize) bool {
    if (index + 9 > lines.len) return false;
    const w = lines[index .. index + 9];
    const carry = machine.Instruction.parse(trim(w[2])) orelse return false;
    return exact(w[0], .sta, Value, 0) and exact(w[1], .stx, Value, 1) and carry.op == .clc and carry.operand == .none and
        exact(w[3], .lda, Pointer, 0) and exact(w[4], .adc, Value, 0) and exact(w[5], .sta, Pointer, 0) and
        exact(w[6], .lda, Pointer, 1) and exact(w[7], .adc, Value, 1) and exact(w[8], .sta, Pointer, 1);
}
fn directBaseLayout(lines: []const []const u8) bool {
    var started_code = false;
    for (lines) |raw| {
        const text = trim(raw);
        if (storage.sectionOwner(text, "code") != null) started_code = true;
        if (started_code and std.mem.startsWith(u8, text, "* = ")) return false;
        const end = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
        for ([_][]const u8{ ".cpu", ".al", ".as", ".xl", ".xs", ".logical", ".here", ".virtual", ".endvirtual" }) |directive| {
            if (same(text[0..end], directive)) return false;
        }
    }
    return true;
}

fn canonicalOperand(raw: []const u8, op: machine.Op, name: []const u8, offset: i32) bool {
    const text = trim(raw);
    const end = std.mem.indexOfAny(u8, text, " \t") orelse return false;
    const operand = trim(text[end..]);
    if (!exact(raw, op, name, offset)) return false;
    return if (offset == 0) std.mem.eql(u8, operand, name) else operand.len == name.len + 2 and std.mem.startsWith(u8, operand, name) and std.mem.eql(u8, operand[name.len..], "+1");
}

fn loadedWord(high: []const u8, low: []const u8) ?[]const u8 {
    const inst = machine.Instruction.parse(trim(low)) orelse return null;
    if (inst.operand != .direct) return null;
    const name = inst.operand.direct.name;
    if (!canonicalOperand(low, .lda, name, 0) or !canonicalOperand(high, .ldx, name, 1)) return null;
    return name;
}

fn ownedDirectWord(model: storage.Model, lines: []const []const u8, owner: []const u8, name: []const u8) ?storage.Location {
    const loc = model.resolve(.{ .name = name }, 2) orelse return null;
    const frame = model.frames.items[loc.frame];
    if (!visible(frame) or !std.mem.eql(u8, frame.owner, owner)) return null;
    var unique = false;
    for (lines, 0..) |raw, i| {
        const line = trim(raw);
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            if (same(trim(line[0..eq]), name)) return null;
        }
        if (!std.mem.endsWith(u8, line, ":") or !same(line[0 .. line.len - 1], name)) continue;
        if (unique or !std.mem.eql(u8, line[0 .. line.len - 1], name) or i + 1 == lines.len or
            !std.mem.eql(u8, trim(lines[i + 1]), ".word 0")) return null;
        unique = true;
    }
    if (!unique) return null;
    var aliases = model.labels.iterator();
    while (aliases.next()) |alias| {
        const other = alias.value_ptr.*;
        if (other.frame == loc.frame and other.offset >= loc.offset and other.offset < loc.offset + 2 and
            !std.mem.eql(u8, alias.key_ptr.*, name)) return null;
    }
    return loc;
}

fn directBase(model: storage.Model, lines: []const []const u8, i: usize, owner: []const u8, value: storage.Location, domain: usize) ?[]const u8 {
    if (domain == 0 or model.frames.items[value.frame].domain != domain) return null;
    if (i + 15 > lines.len) return null;
    const w = lines[i .. i + 15];
    const base = loadedWord(w[0], w[1]) orelse return null;
    const index = loadedWord(w[4], w[5]) orelse return null;
    if (!canonicalOperand(w[2], .sta, Pointer, 0) or !canonicalOperand(w[3], .stx, Pointer, 1) or
        !canonicalOperand(w[6], .sta, Value, 0) or !canonicalOperand(w[7], .stx, Value, 1) or
        !std.mem.eql(u8, trim(w[8]), "clc") or
        !canonicalOperand(w[9], .lda, Pointer, 0) or !canonicalOperand(w[10], .adc, Value, 0) or
        !canonicalOperand(w[11], .sta, Pointer, 0) or !canonicalOperand(w[12], .lda, Pointer, 1) or
        !canonicalOperand(w[13], .adc, Value, 1) or !canonicalOperand(w[14], .sta, Pointer, 1)) return null;
    const base_loc = ownedDirectWord(model, lines, owner, base) orelse return null;
    const index_loc = ownedDirectWord(model, lines, owner, index) orelse return null;
    if (!model.disjoint(base_loc, 2, value, 2) or !model.disjoint(index_loc, 2, value, 2)) return null;
    // B and I may alias one another. Only the old P preload and the V writes
    // occur between their observations, and neither can alias these words.
    return base;
}

fn writeForwarded(writer: anytype, w: []const []const u8, base: []const u8) !void {
    try writer.print("{s}\n{s}\n{s}\n    adc {s}\n{s}\n    txa\n    adc {s}+1\n{s}\n", .{ w[0], w[1], w[2], base, w[5], base, w[8] });
}

/// Preserve all V/P writes and physical endpoint state. No staging data, source
/// operands, dereferences, hardware-stack effects, labels or counters are removed.
pub fn rewrite(allocator: std.mem.Allocator, program: ast.Program, assembly: []const u8) !Result {
    return rewriteInternal(allocator, program, assembly, false);
}

/// Fold an adjacent direct base copy when both loaded words are owned, visible
/// RAM. The final P and V bytes and all machine registers/flags match the old
/// setup before any following pointee access, including volatile addressing.
pub fn rewriteWithDirectBases(allocator: std.mem.Allocator, program: ast.Program, assembly: []const u8) !Result {
    return rewriteInternal(allocator, program, assembly, true);
}

fn rewriteInternal(allocator: std.mem.Allocator, program: ast.Program, assembly: []const u8, fold_bases: bool) !Result {
    if (program.zeropage_module != null or program.zeropage_options.modules != null or program.zeropage_options.memory.placements.len != 0 or std.mem.indexOf(u8, assembly, "; inline asm") != null) return unchanged(allocator, assembly);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var split = std.mem.splitScalar(u8, assembly, '\n');
    while (split.next()) |line| try lines.append(allocator, line);
    const direct_bases = fold_bases and directBaseLayout(lines.items);
    const pair = (try fixedPair(allocator, program, lines.items)) orelse return unchanged(allocator, assembly);
    var model = storage.Model.init(allocator);
    defer model.deinit();
    try model.collect(assembly);
    const value = valueWord(model, lines.items) orelse return unchanged(allocator, assembly);
    // resolve guarantees V is wholly >=0200; both current and planned P pairs
    // are exclusively owned page-zero claims. Late V allocation uses that same
    // policy's free mask and cannot overlap the reserved planned pointer claim.
    if (!visible(model.frames.items[value.frame]) or pair > 0xfd) return unchanged(allocator, assembly);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var stats: Stats = .{};
    var active: ?[]const u8 = null;
    var domain: usize = 0;
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const text = trim(lines.items[i]);
        if (std.mem.startsWith(u8, text, "* = ")) domain += 1;
        if (std.mem.startsWith(u8, text, "; zeropage_section_")) active = storage.sectionOwner(text, "code");
        if (active) |owner| if (program.findFunction(owner) != null) {
            if (direct_bases) if (directBase(model, lines.items, i, owner, value, domain)) |base| {
                try out.writer.print("{s}\n{s}\n", .{ lines.items[i + 4], lines.items[i + 5] });
                try writeForwarded(&out.writer, lines.items[i + 6 .. i + 15], base);
                stats.setups_forwarded += 1;
                stats.low_loads_removed += 1;
                stats.high_loads_replaced += 1;
                stats.direct_bases_folded += 1;
                // The same 5 bytes as ordinary add forwarding plus 8
                // further resident-base bytes at the pre-allocation boundary.
                stats.bytes_saved += 13;
                i += 14;
                continue;
            };
            if (pattern(lines.items, i)) {
                try writeForwarded(&out.writer, lines.items[i .. i + 9], Pointer);
                stats.setups_forwarded += 1;
                stats.low_loads_removed += 1;
                stats.high_loads_replaced += 1;
                stats.bytes_saved += 5;
                i += 8;
                continue;
            }
        };
        try out.writer.writeAll(lines.items[i]);
        if (i + 1 < lines.items.len) try out.writer.writeByte('\n');
    }
    return .{ .assembly = try out.toOwnedSlice(), .stats = stats };
}

const TestCode =
    \\zeropage_ptr_tmp = $fb
    \\* = $2000
    \\; zeropage_section_begin owner=function:main kind=code
    \\main:
    \\    sta zeropage_ptr_value
    \\    stx zeropage_ptr_value+1
    \\    clc
    \\    lda zeropage_ptr_tmp
    \\    adc zeropage_ptr_value
    \\    sta zeropage_ptr_tmp
    \\    lda zeropage_ptr_tmp+1
    \\    adc zeropage_ptr_value+1
    \\    sta zeropage_ptr_tmp+1
    \\    rts
    \\; zeropage_section_end owner=function:main kind=code
;
const TestData =
    \\* = $c100
    \\; zeropage_section_begin owner=compiler kind=scratch
    \\zeropage_ptr_value:
    \\    .word 0
    \\; zeropage_section_end owner=compiler kind=scratch
;
fn testAssembly() ![]u8 {
    return std.mem.concat(std.testing.allocator, u8, &.{ TestCode, "\n", TestData, "\n" });
}
fn testResult(source: []const u8, assembly: []const u8, count: usize) !void {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);
    const result = try rewrite(std.testing.allocator, parsed.program, assembly);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqual(count, result.stats.setups_forwarded);
    try std.testing.expectEqual(5 * count, result.stats.bytes_saved);
    if (count == 0) try std.testing.expectEqualStrings(assembly, result.assembly);
}
const TestSource = "export fn main()void{}";
test "pointer add forwarding preserves writes and uses captured A X in the exact adjacent setup" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, TestSource);
    defer parsed.deinit(std.testing.allocator);
    const assembly = try testAssembly();
    defer std.testing.allocator.free(assembly);
    const result = try rewrite(std.testing.allocator, parsed.program, assembly);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqual(@as(usize, 1), result.stats.setups_forwarded);
    try std.testing.expectEqual(@as(usize, 1), result.stats.low_loads_removed);
    try std.testing.expectEqual(@as(usize, 1), result.stats.high_loads_replaced);
    try std.testing.expect(std.mem.indexOf(u8, result.assembly, "    clc\n    adc zeropage_ptr_tmp\n    sta zeropage_ptr_tmp\n    txa\n    adc zeropage_ptr_tmp+1\n") != null);
    for ([_][]const u8{ "sta zeropage_ptr_value\n", "stx zeropage_ptr_value+1\n", "sta zeropage_ptr_tmp\n", "sta zeropage_ptr_tmp+1\n" }) |store| try std.testing.expectEqual(std.mem.count(u8, assembly, store), std.mem.count(u8, result.assembly, store));
    const again = try rewrite(std.testing.allocator, parsed.program, result.assembly);
    defer std.testing.allocator.free(again.assembly);
    try std.testing.expectEqual(@as(usize, 0), again.stats.setups_forwarded);
    try std.testing.expectEqualStrings(result.assembly, again.assembly);
}
test "pointer add forwarding declines extra observers labels wrong X carry op and addressing modes" {
    const assembly = try testAssembly();
    defer std.testing.allocator.free(assembly);
    const changes = [_][2][]const u8{
        .{ "    clc\n", "    inx\n    clc\n" },                                              .{ "    clc\n", "    sec\n" },
        .{ "    lda zeropage_ptr_tmp\n", "    php\n    lda zeropage_ptr_tmp\n" },            .{ "    lda zeropage_ptr_tmp\n", "inside:\n    lda zeropage_ptr_tmp\n" },
        .{ "    lda zeropage_ptr_tmp\n", "; observer barrier\n    lda zeropage_ptr_tmp\n" }, .{ "    adc zeropage_ptr_value\n", "    sbc zeropage_ptr_value\n" },
        .{ "    adc zeropage_ptr_value\n", "    adc (zeropage_ptr_value),y\n" },             .{ "    adc zeropage_ptr_value\n", "    adc zeropage_ptr_value,x\n" },
        .{ "    adc zeropage_ptr_value\n", "    adc zeropage_ptr_value+1\n" },               .{ "    stx zeropage_ptr_value+1\n", "    sta zeropage_ptr_value+1\n" },
        .{ "    lda zeropage_ptr_tmp\n", "    lda @w zeropage_ptr_tmp\n" },
    };
    for (changes) |pair| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, assembly, pair[0], pair[1]);
        defer std.testing.allocator.free(changed);
        try testResult(TestSource, changed, 0);
    }
}
test "pointer add forwarding requires numeric uniquely owned nonwrapping pointer pair" {
    const assembly = try testAssembly();
    defer std.testing.allocator.free(assembly);
    for ([_][]const u8{ "$00", "$01", "$ff", "$fe", "$fd", "$c100", "$d020", "$20", "other", "$fb+0", "address($fb+0)" }) |alias| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, assembly, "$fb", alias);
        defer std.testing.allocator.free(changed);
        try testResult(TestSource, changed, 0);
    }
    for ([_][]const u8{ "zeropage_ptr_tmp = $fb\n", "ZEROPAGE_PTR_TMP = $fb\n", "zeropage_ptr_tmp:\n" }) |extra| {
        const changed = try std.mem.concat(std.testing.allocator, u8, &.{ extra, assembly });
        defer std.testing.allocator.free(changed);
        try testResult(TestSource, changed, 0);
    }
    const wrapped = try std.mem.replaceOwned(u8, std.testing.allocator, assembly, "$fb", "address($fb)");
    defer std.testing.allocator.free(wrapped);
    try testResult(TestSource, wrapped, 1);
}
test "pointer add forwarding validates planned pair including explicit custom pool and reserves" {
    const source = "pub const zeropage_options=.{.zero_page=.{.profile=.kernal,.allocation=.scratch,.ranges=.{.{.addr=0x20,.size=16}},.reserve=.{.{.addr=0x20,.size=2}}}};export fn main()void{}";
    const assembly = try testAssembly();
    defer std.testing.allocator.free(assembly);
    try testResult(source, assembly, 1);
    const planned = try std.mem.replaceOwned(u8, std.testing.allocator, assembly, "$fb", "address($22)");
    defer std.testing.allocator.free(planned);
    try testResult(source, planned, 1);
    const reserved = try std.mem.replaceOwned(u8, std.testing.allocator, assembly, "$fb", "$20");
    defer std.testing.allocator.free(reserved);
    try testResult(source, reserved, 0);
}
test "pointer add forwarding needs real visible canonical zero initialized compiler word" {
    const assembly = try testAssembly();
    defer std.testing.allocator.free(assembly);
    for ([_][2][]const u8{
        .{ "$c100", "$fb" },                                                               .{ "$c100", "$a000" },               .{ "$c100", "$d000" },                                                       .{ "$c100", "$e000" },                                              .{ "$c100", "$cfff" },
        .{ "    .word 0", "    .word 1" },                                                 .{ "    .word 0", "    .byte 0,0" }, .{ "owner=compiler kind=scratch", "owner=function:main kind=static_frame" }, .{ "zeropage_ptr_value:\n", "root_alias:\nzeropage_ptr_value:\n" }, .{ "zeropage_ptr_value:\n", "zeropage_ptr_value:\nZEROPAGE_PTR_VALUE:\n" },
        .{ "zeropage_ptr_value:\n", "zeropage_ptr_value = $c100\nzeropage_ptr_value:\n" },
    }) |pair| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, assembly, pair[0], pair[1]);
        defer std.testing.allocator.free(changed);
        try testResult(TestSource, changed, 0);
    }
    const edge = try std.mem.replaceOwned(u8, std.testing.allocator, assembly, "$c100", "$cffe");
    defer std.testing.allocator.free(edge);
    try testResult(TestSource, edge, 1);
}
test "pointer add forwarding skips source ASM module placement unknown owners and data zones" {
    const assembly = try testAssembly();
    defer std.testing.allocator.free(assembly);
    const asm_text = try std.mem.concat(std.testing.allocator, u8, &.{ "; inline asm from ZeroPage line 1\n; end inline asm\n", assembly });
    defer std.testing.allocator.free(asm_text);
    try testResult(TestSource, asm_text, 0);
    const owner = try std.mem.replaceOwned(u8, std.testing.allocator, assembly, "owner=function:main kind=code", "owner=function:absent kind=code");
    defer std.testing.allocator.free(owner);
    try testResult(TestSource, owner, 0);
    const zone = try std.mem.replaceOwned(u8, std.testing.allocator, assembly, "owner=function:main kind=code", "owner=compiler kind=rodata");
    defer std.testing.allocator.free(zone);
    try testResult(TestSource, zone, 0);
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, TestSource);
    defer parsed.deinit(std.testing.allocator);
    var program = parsed.program;
    var placements = [_]ast.MemoryPlacement{.{ .name = "fixed", .region_name = "code", .functions = &.{"main"} }};
    program.zeropage_options.memory.placements = &placements;
    const result = try rewrite(std.testing.allocator, program, assembly);
    defer std.testing.allocator.free(result.assembly);
    try std.testing.expectEqual(@as(usize, 0), result.stats.setups_forwarded);
    try testResult("pub const zeropage_module=.{.id=\"m\",.abi=1,.exports=.{.main=main},.deps=.{}};export fn main()void{}", assembly, 0);
}
test "pointer add forwarding frees policy model and output on allocation failure" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, TestSource);
    defer parsed.deinit(std.testing.allocator);
    const assembly = try testAssembly();
    defer std.testing.allocator.free(assembly);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, program: ast.Program, bytes: []const u8) !void {
            const result = rewrite(allocator, program, bytes) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => return err,
            };
            defer allocator.free(result.assembly);
        }
    }.run, .{ parsed.program, assembly });
}

test "pointer add forwarding declines noncanonical symbol spelling without rewriting aliases" {
    const assembly = try testAssembly();
    defer std.testing.allocator.free(assembly);
    const p = try std.mem.replaceOwned(u8, std.testing.allocator, assembly, Pointer, "ZEROPAGE_PTR_TMP");
    defer std.testing.allocator.free(p);
    try testResult(TestSource, p, 0);
    const v = try std.mem.replaceOwned(u8, std.testing.allocator, assembly, Value, "ZEROPAGE_PTR_VALUE");
    defer std.testing.allocator.free(v);
    try testResult(TestSource, v, 0);
}
