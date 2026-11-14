const std = @import("std");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");
const loops = @import("loop_invariants.zig");

const Plan = struct { start: usize, capture: usize, end: usize, name: []const u8, high: storage.Location };

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r");
}
fn number(line: []const u8, key: []const u8) ?u32 {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    while (fields.next()) |field| if (std.mem.startsWith(u8, field, key)) return machine.integer(field[key.len..]);
    return null;
}
fn same(a: storage.Location, b: storage.Location) bool {
    return a.frame == b.frame and a.offset == b.offset;
}
fn direct(inst: machine.Instruction, op: machine.Op, name: []const u8, offset: i32) bool {
    return inst.op == op and inst.operand == .direct and inst.operand.direct.offset == offset and std.mem.eql(u8, inst.operand.direct.name, name);
}
fn immediate(inst: machine.Instruction, op: machine.Op, value: u32) bool {
    return inst.op == op and inst.operand == .immediate and machine.integer(inst.operand.immediate) == value;
}
fn readImmediate(op: machine.Op) bool {
    return switch (op) {
        .lda, .ldx, .ldy, .adc, .sbc, .@"and", .ora, .eor, .cmp, .cpx, .cpy => true,
        else => false,
    };
}
fn setupDead(lines: []const []const u8) bool {
    var needed: u16 = machine.a | machine.nz;
    for (lines) |raw| {
        const line = trim(raw);
        if (std.mem.startsWith(u8, line, "; inline asm")) return false;
        if (line.len == 0 or line[0] == ';') continue;
        const inst = machine.Instruction.parse(line) orelse return false;
        const effect = inst.effects();
        if (effect.barrier or effect.reads & needed != 0) return false;
        needed &= ~effect.writes;
        if (needed == 0) return true;
    }
    return false;
}

// Upper bounds are sufficient to prove that pre-capture array reads cannot
// observe the high-byte store moved earlier. Values remain full-width in RAM.
const PrefixRanges = struct {
    a: ?u32 = null,
    x: ?u32 = null,
    y: ?u32 = null,
    fn loadBound(inst: machine.Instruction, index: machine.Symbol, count: u32) ?u32 {
        if (inst.operand == .immediate) {
            const value = machine.integer(inst.operand.immediate) orelse return null;
            return if (value <= 255) value else null;
        }
        if (inst.operand == .direct and std.mem.eql(u8, inst.operand.direct.name, index.name) and inst.operand.direct.offset == index.offset) return count - 1;
        return null;
    }
    fn observe(self: *PrefixRanges, inst: machine.Instruction, index: machine.Symbol, count: u32) void {
        const old = self.*;
        const effects = inst.effects();
        if (effects.writes & machine.a != 0) self.a = null;
        if (effects.writes & machine.x != 0) self.x = null;
        if (effects.writes & machine.y != 0) self.y = null;
        switch (inst.op) {
            .lda => self.a = loadBound(inst, index, count),
            .ldx => self.x = loadBound(inst, index, count),
            .ldy => self.y = loadBound(inst, index, count),
            .tax => self.x = old.a,
            .tay => self.y = old.a,
            .txa => self.a = old.x,
            .tya => self.a = old.y,
            .asl => if (inst.operand == .none) {
                self.a = if (old.a) |v| @min(255, v * 2) else null;
            },
            .lsr => if (inst.operand == .none) {
                self.a = if (old.a) |v| v / 2 else null;
            },
            .iny => self.y = if (old.y) |v| @min(255, v + 1) else null,
            .inx => self.x = if (old.x) |v| @min(255, v + 1) else null,
            else => {},
        }
    }
};

fn prefixSafe(model: storage.Model, lines: []const []const u8, high: storage.Location, index: machine.Symbol, count: u32) bool {
    var ranges: PrefixRanges = .{};
    for (lines) |raw| {
        const line = trim(raw);
        if (std.mem.startsWith(u8, line, "; inline asm")) return false;
        if (line.len == 0 or line[0] == ';') continue;
        const inst = machine.Instruction.parse(line) orelse return false;
        const effects = inst.effects();
        if (effects.barrier) return false;
        if (effects.memory != .none) {
            const location: storage.Location, const width: u32 = switch (inst.operand) {
                .direct => |ref| .{ model.resolve(ref, 1) orelse return false, 1 },
                .indexed => |indexed| blk: {
                    if (effects.memory != .read) return false;
                    const bound = (if (indexed.register == machine.y) ranges.y else ranges.x) orelse return false;
                    if (bound > 255) return false;
                    break :blk .{ model.resolve(indexed.base, bound + 1) orelse return false, bound + 1 };
                },
                else => return false,
            };
            if (!model.disjoint(high, 1, location, width)) return false;
        }
        ranges.observe(inst, index, count);
    }
    return true;
}

// Positive bounded induction gives a constant-zero high byte. Hoist only when
// every memory effect preserves it, and no earlier body read can observe it.
pub fn optimize(allocator: std.mem.Allocator, assembly: []const u8) ![]u8 {
    var model = storage.Model.init(allocator);
    defer model.deinit();
    try model.collect(assembly);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var split = std.mem.splitScalar(u8, assembly, '\n');
    while (split.next()) |line| try lines.append(allocator, line);
    var functions = try loops.collectFunctions(allocator, lines.items);
    defer functions.deinit(allocator);
    var plans: std.ArrayList(Plan) = .empty;
    defer plans.deinit(allocator);
    const removed = try allocator.alloc(bool, lines.items.len);
    defer allocator.free(removed);
    @memset(removed, false);
    for (functions.items) |function| {
        var in_assembly = false;
        for (function.first..function.end) |start| {
            const marker = trim(lines.items[start]);
            if (std.mem.startsWith(u8, marker, "; inline asm")) in_assembly = true;
            if (std.mem.eql(u8, marker, "; end inline asm")) {
                in_assembly = false;
                continue;
            }
            if (in_assembly or !std.mem.startsWith(u8, marker, "; zeropage_loop_begin ")) continue;
            const id = number(marker, "id=") orelse continue;
            const count = number(marker, "count=") orelse continue;
            if (count < 2 or count > 255 or start < 3) continue;
            const body_label = try std.fmt.allocPrint(allocator, "for_{d}_body:", .{id});
            defer allocator.free(body_label);
            const top_label = try std.fmt.allocPrint(allocator, "for_{d}_top:", .{id});
            defer allocator.free(top_label);
            var top: ?usize = null;
            var body: ?usize = null;
            var end: ?usize = null;
            for (start + 1..function.end) |index| {
                const line = trim(lines.items[index]);
                if (std.mem.eql(u8, line, top_label)) top = index;
                if (std.mem.eql(u8, line, body_label)) body = index;
                if (std.mem.startsWith(u8, line, "; zeropage_loop_end ") and number(line, "id=") == id) {
                    end = index;
                    break;
                }
            }
            if (top == null or body == null or end == null or top.? + 2 >= body.?) continue;
            const header = machine.Instruction.parse(lines.items[top.? + 1]) orelse continue;
            if (header.op != .lda or header.operand != .direct) continue;
            const index_ref = header.operand.direct;
            if (index_ref.offset != 0 or model.resolve(index_ref, 2) == null) continue;
            if (!immediate(machine.Instruction.parse(lines.items[top.? + 2]) orelse continue, .cmp, count)) continue;
            if (!immediate(machine.Instruction.parse(lines.items[start - 3]) orelse continue, .lda, 0) or
                !direct(machine.Instruction.parse(lines.items[start - 2]) orelse continue, .sta, index_ref.name, 0) or
                !direct(machine.Instruction.parse(lines.items[start - 1]) orelse continue, .sta, index_ref.name, 1)) continue;
            const prefix = "; zeropage_loop_capture source=";
            for (body.? + 1..end.?) |capture| {
                const line = trim(lines.items[capture]);
                if (!std.mem.startsWith(u8, line, prefix) or capture + 4 >= end.?) continue;
                const name = line[prefix.len..];
                const high = model.resolve(.{ .name = name, .offset = 1 }, 1) orelse continue;
                if (!std.mem.eql(u8, model.frames.items[high.frame].owner, function.name)) continue;
                if (!direct(machine.Instruction.parse(lines.items[capture + 1]) orelse continue, .lda, index_ref.name, 0) or
                    !direct(machine.Instruction.parse(lines.items[capture + 2]) orelse continue, .sta, name, 0) or
                    !immediate(machine.Instruction.parse(lines.items[capture + 3]) orelse continue, .lda, 0) or
                    !direct(machine.Instruction.parse(lines.items[capture + 4]) orelse continue, .sta, name, 1)) continue;
                if (!prefixSafe(model, lines.items[body.? + 1 .. capture], high, index_ref, count) or
                    !setupDead(lines.items[capture + 5 .. end.?])) continue;
                var analysis: loops.Analysis = .{ .allocator = allocator, .model = &model, .lines = lines.items, .functions = functions.items, .source = high, .source_width = 1, .allow_unknown_reads = true, .allow_pointer_scratch_writes = true };
                defer analysis.callers.deinit(allocator);
                var safe = true;
                for (start + 1..end.?) |index| {
                    if (index == capture + 3 or index == capture + 4) continue;
                    const text = trim(lines.items[index]);
                    if (std.mem.startsWith(u8, text, "; inline asm")) {
                        safe = false;
                        break;
                    }
                    if (text.len == 0 or text[0] == ';' or std.mem.endsWith(u8, text, ":")) continue;
                    const inst = machine.Instruction.parse(text) orelse {
                        safe = false;
                        break;
                    };
                    if (!try analysis.instructionSafe(inst, function)) {
                        safe = false;
                        break;
                    }
                }
                if (!safe) continue;
                try plans.append(allocator, .{ .start = start, .capture = capture, .end = end.?, .name = name, .high = high });
                removed[capture + 3] = true;
                removed[capture + 4] = true;
            }
        }
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (lines.items, 0..) |line, index| {
        if (removed[index]) continue;
        var replaced = false;
        if (machine.Instruction.parse(line)) |inst| {
            if (readImmediate(inst.op) and inst.operand == .direct) {
                if (model.resolve(inst.operand.direct, 1)) |location| for (plans.items) |plan| {
                    if (index > plan.capture + 4 and index < plan.end and same(location, plan.high)) {
                        try out.writer.print("    {s} #0\n", .{@tagName(inst.op)});
                        replaced = true;
                        break;
                    }
                };
            }
        }
        if (!replaced and (index + 1 < lines.items.len or line.len != 0)) try out.writer.print("{s}\n", .{line});
        for (plans.items) |plan| if (plan.start == index) {
            try out.writer.print("    ; zeropage_loop_range source={s} high=0\n    lda #0\n    sta {s}+1\n", .{ plan.name, plan.name });
        };
    }
    return try out.toOwnedSlice();
}

fn testProgram(allocator: std.mem.Allocator, count: u8, prefix: []const u8, suffix: []const u8, callee: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\* = $2000
        \\; zeropage_section_begin owner=function:f kind=code
        \\f:
        \\    lda #0
        \\    sta f_index
        \\    sta f_index+1
        \\; zeropage_loop_begin id=1 count={d}
        \\for_1_top:
        \\    lda f_index
        \\    cmp #{d}
        \\    bcc for_1_body
        \\    jmp for_1_done
        \\for_1_body:
        \\    {s}
        \\; zeropage_loop_capture source=f_capture
        \\    lda f_index
        \\    sta f_capture
        \\    lda #0
        \\    sta f_capture+1
        \\    lda f_capture
        \\    ldx f_root+1
        \\    sta f_result
        \\    {s}
        \\for_1_next:
        \\    inc f_index
        \\    jmp for_1_top
        \\for_1_done:
        \\; zeropage_loop_end id=1
        \\    rts
        \\; zeropage_section_end owner=function:f kind=code
        \\; zeropage_section_begin owner=function:g kind=code
        \\g:
        \\    {s}
        \\    rts
        \\; zeropage_section_end owner=function:g kind=code
        \\; zeropage_section_begin owner=function:f kind=static_frame
        \\f_index:
        \\    .word 0
        \\f_root:
        \\f_capture:
        \\    .word 0
        \\f_result:
        \\    .byte 0
        \\f_item:
        \\    .byte 0
        \\f_other:
        \\    .byte 0
        \\f_array:
        \\    .byte 1,2,3,4
        \\f_words:
        \\    .word 0,255,256,65535
        \\; zeropage_section_end owner=function:f kind=static_frame
        \\; zeropage_section_begin owner=function:g kind=static_frame
        \\g_value:
        \\    .byte 0
        \\; zeropage_section_end owner=function:g kind=static_frame
        \\; zeropage_section_begin owner=module:main kind=rodata
        \\table:
        \\    .byte 1,2,3,4
        \\; zeropage_section_end owner=module:main kind=rodata
        \\
    , .{ count, count, prefix, suffix, callee });
}

test "bounded captures hoist their zero high byte and select canonical immediate reads" {
    for ([_][]const u8{ "", "jsr g", "sta zeropage_ptr_tmp\n    lda (zeropage_ptr_tmp),y", "lda $dc04" }) |suffix| {
        const input = try testProgram(std.testing.allocator, 4, "", suffix, "lda f_capture+1\n    sta g_value");
        defer std.testing.allocator.free(input);
        const output = try optimize(std.testing.allocator, input);
        defer std.testing.allocator.free(output);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "zeropage_loop_range source=f_capture high=0"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "sta f_capture+1"));
        try std.testing.expect(std.mem.indexOf(u8, output, "ldx f_root+1") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "ldx #0") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "sta f_capture+1\nfor_1_top:") != null);
    }
}

test "prefix array read ranges must be disjoint from the hoisted capture" {
    for ([_][]const u8{
        "ldy f_index\n    lda table,y\n    sta f_item",
        "ldy f_index\n    lda f_array,y\n    sta f_item",
        "lda f_index\n    asl\n    tay\n    lda f_words,y\n    sta f_item\n    iny\n    lda f_words,y\n    sta f_other",
    }) |prefix| {
        const input = try testProgram(std.testing.allocator, 4, prefix, "", "");
        defer std.testing.allocator.free(input);
        const output = try optimize(std.testing.allocator, input);
        defer std.testing.allocator.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "zeropage_loop_range") != null);
    }
    for ([_][]const u8{
        "ldy f_index\n    lda f_capture,y\n    sta f_item",                   "lda f_root+1\n    sta f_item",
        "lda (zeropage_ptr_tmp),y\n    sta f_item",                           "bne for_1_next",
        "ldy f_result\n    lda table,y\n    sta f_item",                      "ldy f_index\n    lda $dc04\n    sta f_item",
        "lda #4294967295\n    asl\n    tay\n    lda table,y\n    sta f_item",
    }) |prefix| {
        const input = try testProgram(std.testing.allocator, 4, prefix, "", "");
        defer std.testing.allocator.free(input);
        const output = try optimize(std.testing.allocator, input);
        defer std.testing.allocator.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "zeropage_loop_range") == null);
    }
}

test "capture ranges stop at aliases opaque effects unknown calls and unprofitable bounds" {
    for ([_][]const u8{
        "inc f_root+1", "sta f_capture+1",                                              "sta (zeropage_ptr_tmp),y", "sta f_result,x", "sta $0001", "jsr missing",
        "jsr g",        "; inline asm from ZeroPage line 1\n    nop\n; end inline asm",
    }) |suffix| {
        const input = try testProgram(std.testing.allocator, 4, "", suffix, "sta f_root+1");
        defer std.testing.allocator.free(input);
        const output = try optimize(std.testing.allocator, input);
        defer std.testing.allocator.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "zeropage_loop_range") == null);
    }
    for ([_][]const u8{ "sta f_root+1", "sta (zeropage_ptr_tmp),y", "jsr g", "jsr missing" }) |callee| {
        const input = try testProgram(std.testing.allocator, 4, "", "jsr g", callee);
        defer std.testing.allocator.free(input);
        const output = try optimize(std.testing.allocator, input);
        defer std.testing.allocator.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "zeropage_loop_range") == null);
    }
    for ([_]u8{ 0, 1 }) |count| {
        const input = try testProgram(std.testing.allocator, count, "", "", "");
        defer std.testing.allocator.free(input);
        const output = try optimize(std.testing.allocator, input);
        defer std.testing.allocator.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "zeropage_loop_range") == null);
    }
}

test "removed capture setup must have dead A and NZ outputs" {
    const input = try testProgram(std.testing.allocator, 4, "", "", "");
    defer std.testing.allocator.free(input);
    for ([_][]const u8{ "php", "beq for_1_next", "sta f_result", "tax", "jsr g" }) |consumer| {
        const replacement = try std.fmt.allocPrint(std.testing.allocator, "sta f_capture+1\n    {s}\n", .{consumer});
        defer std.testing.allocator.free(replacement);
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, input, "sta f_capture+1\n", replacement);
        defer std.testing.allocator.free(changed);
        const output = try optimize(std.testing.allocator, changed);
        defer std.testing.allocator.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "zeropage_loop_range") == null);
    }
}

test "capture ranges require the actual zero initialized index and RAM identity" {
    const input = try testProgram(std.testing.allocator, 4, "", "", "");
    defer std.testing.allocator.free(input);
    for ([_][2][]const u8{
        .{ "lda #0\n    sta f_index", "lda #1\n    sta f_index" },
        .{ "cmp #4", "cmp #3" },
        .{ "* = $2000", "* = $d000" },
        .{ "sta f_capture\n", "sta f_result\n" },
        .{ "; zeropage_loop_begin", "; inline asm from ZeroPage line 1\n; zeropage_loop_begin" },
    }) |change| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, input, change[0], change[1]);
        defer std.testing.allocator.free(changed);
        const output = try optimize(std.testing.allocator, changed);
        defer std.testing.allocator.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "zeropage_loop_range") == null);
    }
}

test "explicit origin domains revoke cross function write disjointness" {
    const input = try testProgram(std.testing.allocator, 4, "", "jsr g", "sta g_value");
    defer std.testing.allocator.free(input);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, input, "; zeropage_section_begin owner=function:g kind=static_frame", "* = $2000\n; zeropage_section_begin owner=function:g kind=static_frame");
    defer std.testing.allocator.free(changed);
    const output = try optimize(std.testing.allocator, changed);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "zeropage_loop_range") == null);
}
