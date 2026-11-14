const std = @import("std");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");

pub const Read = struct { source: []const u8, next: usize, load_start: usize };

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn same(a: storage.Location, b: storage.Location) bool {
    return a.frame == b.frame and a.offset == b.offset;
}

fn matches(line: []const u8, op: machine.Op, reference: machine.Symbol) bool {
    const inst = machine.Instruction.parse(line) orelse return false;
    return inst.op == op and inst.operand == .direct and
        std.mem.eql(u8, inst.operand.direct.name, reference.name) and inst.operand.direct.offset == reference.offset;
}

pub fn readAt(lines: []const []const u8, start: usize) ?Read {
    const prefix = "; zeropage_pointer_read source=";
    const marker = trim(lines[start]);
    if (!std.mem.startsWith(u8, marker, prefix)) return null;
    const separator = std.mem.indexOf(u8, marker[prefix.len..], " bytes=") orelse return null;
    const source = marker[prefix.len .. prefix.len + separator];
    const width = machine.integer(marker[prefix.len + separator + 7 ..]) orelse return null;
    if (width != 1 and width != 2) return null;
    if (lines.len - start < 6) return null;
    if (!matches(lines[start + 1], .lda, .{ .name = source }) or
        !matches(lines[start + 2], .sta, .{ .name = "zeropage_ptr_tmp" }) or
        !matches(lines[start + 3], .lda, .{ .name = source, .offset = 1 }) or
        !matches(lines[start + 4], .sta, .{ .name = "zeropage_ptr_tmp", .offset = 1 })) return null;
    var load = start + 5;
    var consumers: [2]machine.Instruction = undefined;
    var count: usize = 0;
    const first = machine.Instruction.parse(lines[load]) orelse return null;
    if (first.op == .ldy and first.operand == .immediate) {
        consumers[count] = first;
        count += 1;
        load += 1;
    }
    const byte_body = [_][]const u8{"lda (zeropage_ptr_tmp),y"};
    const word_body = [_][]const u8{ "lda (zeropage_ptr_tmp),y", "pha", "iny", "lda (zeropage_ptr_tmp),y", "tax", "pla" };
    const body: []const []const u8 = if (width == 1) &byte_body else &word_body;
    if (lines.len - load < body.len) return null;
    for (body, 0..) |text, offset| if (!std.mem.eql(u8, trim(lines[load + offset]), text)) return null;
    consumers[count] = machine.Instruction.parse(lines[load]).?;
    count += 1;
    if (!machine.outputsDeadBeforeRead(consumers[0..count], machine.a | machine.nz)) return null;
    return .{ .source = source, .load_start = start + 5, .next = load + body.len };
}

fn retainFact(model: storage.Model, fact: storage.Location, inst: machine.Instruction) bool {
    const effect = inst.effects();
    if (effect.barrier) return false;
    switch (effect.memory) {
        .none, .stack => return true,
        .read, .write, .read_write => {
            if (inst.operand != .direct) return false;
            const location = model.resolve(inst.operand.direct, 1) orelse return false;
            if (location.frame != fact.frame) return false;
            if (effect.memory == .read) return true;
            return location.offset < fact.offset or location.offset >= fact.offset + 2;
        },
    }
}

// Borrow input; return a separately owned assembly buffer. The pass only knows
// compiler-owned frame storage and explicitly identified nonvolatile reads.
pub fn optimize(allocator: std.mem.Allocator, assembly: []const u8) ![]u8 {
    var model = storage.Model.init(allocator);
    defer model.deinit();
    try model.collect(assembly);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var split = std.mem.splitScalar(u8, assembly, '\n');
    while (split.next()) |line| try lines.append(allocator, line);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var owner: ?[]const u8 = null;
    var fact: ?storage.Location = null;
    var inline_assembly = false;
    var index: usize = 0;
    while (index < lines.items.len) {
        const raw = lines.items[index];
        const line = trim(raw);
        if (std.mem.startsWith(u8, line, "; inline asm from ZeroPage line ")) {
            inline_assembly = true;
            fact = null;
        } else if (std.mem.eql(u8, line, "; end inline asm")) {
            inline_assembly = false;
            fact = null;
        }
        if (!inline_assembly) {
            if (storage.sectionOwner(line, "code")) |name| {
                owner = name;
                fact = null;
            } else if (std.mem.startsWith(u8, line, "; zeropage_section_")) {
                owner = null;
                fact = null;
            } else if (owner) |name| {
                if (readAt(lines.items, index)) |read| {
                    const location = model.resolve(.{ .name = read.source }, 2);
                    if (location) |current| {
                        if (std.mem.eql(u8, model.frames.items[current.frame].owner, name)) {
                            const redundant = if (fact) |previous| same(current, previous) else false;
                            if (redundant) {
                                try output.writer.print("    ; zeropage_pointer_reuse source={s}\n", .{read.source});
                            }
                            const first = if (redundant) read.load_start else index;
                            for (lines.items[first..read.next]) |kept| try output.writer.print("{s}\n", .{kept});
                            fact = current;
                            index = read.next;
                            continue;
                        }
                    }
                }
                if (fact) |previous| {
                    const inst = machine.Instruction.parse(line);
                    if (inst == null or !retainFact(model, previous, inst.?)) fact = null;
                }
            }
        }
        // Avoid manufacturing an extra blank line from splitScalar's final item.
        if (index + 1 < lines.items.len or raw.len != 0) try output.writer.print("{s}\n", .{raw});
        index += 1;
    }
    return try output.toOwnedSlice();
}

fn testProgram(allocator: std.mem.Allocator, between: []const u8, width: u8, second_source: []const u8) ![]u8 {
    const body = if (width == 2) "lda (zeropage_ptr_tmp),y\n    pha\n    iny\n    lda (zeropage_ptr_tmp),y\n    tax\n    pla" else "lda (zeropage_ptr_tmp),y";
    return std.fmt.allocPrint(allocator,
        \\* = $2000
        \\; zeropage_section_begin owner=function:f kind=code lifetime=static address=near
        \\f:
        \\    ; zeropage_pointer_read source=f_pointer bytes={d}
        \\    lda f_pointer
        \\    sta zeropage_ptr_tmp
        \\    lda f_pointer+1
        \\    sta zeropage_ptr_tmp+1
        \\    ldy #0
        \\    {s}
        \\    sta f_value
        \\    {s}
        \\    ; zeropage_pointer_read source={s} bytes={d}
        \\    lda {s}
        \\    sta zeropage_ptr_tmp
        \\    lda {s}+1
        \\    sta zeropage_ptr_tmp+1
        \\    ldy #2
        \\    {s}
        \\    rts
        \\; zeropage_section_end owner=function:f kind=code
        \\; zeropage_section_begin owner=function:f kind=static_frame lifetime=static address=near
        \\f_root:
        \\f_pointer:
        \\    .word 0
        \\f_value:
        \\    .byte 0
        \\f_other:
        \\    .word 0
        \\; zeropage_section_end owner=function:f kind=static_frame
        \\
    , .{ width, body, between, second_source, width, second_source, second_source, body });
}

test "pointer reuse follows storage identity across disjoint stores and full word reads" {
    for ([_]u8{ 1, 2 }) |width| {
        const input = try testProgram(std.testing.allocator, "lda #7\n    sta f_other+1", width, "f_root");
        defer std.testing.allocator.free(input);
        const result = try optimize(std.testing.allocator, input);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result, "zeropage_pointer_reuse source=f_root"));
        try std.testing.expectEqual(@as(usize, if (width == 2) 4 else 2), std.mem.count(u8, result, "lda (zeropage_ptr_tmp),y"));
    }
}

test "pointer facts stop at aliases unknown memory control flow and opaque assembly" {
    for ([_][]const u8{
        "sta f_root",               "sta f_root+1",                                                     "inc f_pointer+1",          "sta f_value-1",
        "sta zeropage_ptr_tmp",     "sta zeropage_ptr_tmp+1",                                           "sta zeropage_console_ptr", "sta $fb",
        "sta (zeropage_ptr_tmp),y", "sta f_other,x",                                                    "lda (other),y",            "lda $d012",
        "ldx unknown",              "jsr helper",                                                       "beq join\njoin:",          ".byte 0",
        "madeup operand",           "; inline asm from ZeroPage line 1\n    nop\n    ; end inline asm",
    }) |between| {
        const input = try testProgram(std.testing.allocator, between, 1, "f_pointer");
        defer std.testing.allocator.free(input);
        const result = try optimize(std.testing.allocator, input);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, result, "zeropage_pointer_reuse"));
    }
}

test "unproven IO layout and visible A or flag consumers retain pointer copies" {
    const input = try testProgram(std.testing.allocator, "nop", 1, "f_pointer");
    defer std.testing.allocator.free(input);
    for ([_][]const u8{ "* = $d000", "* = $01ff" }) |origin| {
        const variant = try std.mem.replaceOwned(u8, std.testing.allocator, input, "* = $2000", origin);
        defer std.testing.allocator.free(variant);
        const result = try optimize(std.testing.allocator, variant);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, result, "zeropage_pointer_reuse"));
    }
    for ([_][]const u8{ "sta f_value", "bne target", "tax", "adc #0" }) |consumer| {
        const replacement = try std.fmt.allocPrint(std.testing.allocator, "{s}\n    ldy #2", .{consumer});
        defer std.testing.allocator.free(replacement);
        const variant = try std.mem.replaceOwned(u8, std.testing.allocator, input, "ldy #2", replacement);
        defer std.testing.allocator.free(variant);
        const result = try optimize(std.testing.allocator, variant);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, result, "zeropage_pointer_reuse"));
    }
}
