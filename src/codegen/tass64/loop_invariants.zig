const std = @import("std");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");
const pointers = @import("pointer_reuse.zig");

pub const Function = struct { name: []const u8, first: usize, end: usize };
const Plan = struct { start: usize, source: []const u8 };

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r");
}

fn fieldNumber(line: []const u8, key: []const u8) ?u32 {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    while (fields.next()) |field| if (std.mem.startsWith(u8, field, key)) return machine.integer(field[key.len..]);
    return null;
}

fn hasLabel(lines: []const []const u8, name: []const u8) bool {
    for (lines) |raw| {
        const text = trim(raw);
        if (text.len == name.len + 1 and text[text.len - 1] == ':' and std.mem.eql(u8, text[0..name.len], name)) return true;
    }
    return false;
}

fn isFlow(op: machine.Op) bool {
    return switch (op) {
        .jmp, .bcc, .bcs, .beq, .bne, .bmi, .bpl, .bvc, .bvs => true,
        else => false,
    };
}

pub const Analysis = struct {
    allocator: std.mem.Allocator,
    model: *const storage.Model,
    lines: []const []const u8,
    functions: []const Function,
    source: storage.Location,
    source_width: u32 = 2,
    allow_unknown_reads: bool = false,
    allow_pointer_scratch_writes: bool = false,
    callers: std.ArrayList([]const u8) = .empty,

    fn callSafe(self: *Analysis, name: []const u8) anyerror!bool {
        for (self.callers.items) |active| if (std.mem.eql(u8, active, name)) return false;
        const function = for (self.functions) |function| {
            if (std.mem.eql(u8, function.name, name)) break function;
        } else return false;
        try self.callers.append(self.allocator, name);
        defer _ = self.callers.pop();
        for (self.lines[function.first..function.end]) |raw| {
            const line = trim(raw);
            if (std.mem.startsWith(u8, line, "; inline asm")) return false;
            if (line.len == 0 or line[0] == ';' or std.mem.endsWith(u8, line, ":")) continue;
            const inst = machine.Instruction.parse(line) orelse return false;
            if (!try self.instructionSafe(inst, function)) return false;
        }
        return true;
    }

    pub fn instructionSafe(self: *Analysis, inst: machine.Instruction, function: Function) anyerror!bool {
        if (inst.op == .jsr) return inst.operand == .direct and inst.operand.direct.offset == 0 and try self.callSafe(inst.operand.direct.name);
        if (inst.op == .rts) return true;
        if (isFlow(inst.op)) return inst.operand == .direct and inst.operand.direct.offset == 0 and hasLabel(self.lines[function.first..function.end], inst.operand.direct.name);
        const effect = inst.effects();
        if (effect.barrier) return false;
        switch (effect.memory) {
            .none, .stack => return true,
            .write, .read_write => {
                if (inst.operand != .direct) return false;
                if (self.allow_pointer_scratch_writes and std.mem.eql(u8, inst.operand.direct.name, "zeropage_ptr_tmp") and
                    (inst.operand.direct.offset == 0 or inst.operand.direct.offset == 1)) return true;
                const written = self.model.resolve(inst.operand.direct, 1) orelse return false;
                return self.model.disjoint(self.source, self.source_width, written, 1);
            },
            .read => return self.allow_unknown_reads or switch (inst.operand) {
                .direct => |reference| self.model.resolve(reference, 1) != null,
                .indexed => |indexed| self.model.indexedReadIsRam(indexed.base),
                .address => |address| address >= 0x0200 and (address < 0xd000 or address >= 0xe000),
                else => false,
            },
        }
    }
};

// Shared source-function boundaries. Opaque asm cannot manufacture sections.
pub fn collectFunctions(allocator: std.mem.Allocator, lines: []const []const u8) !std.ArrayList(Function) {
    var functions: std.ArrayList(Function) = .empty;
    errdefer functions.deinit(allocator);
    var active: ?Function = null;
    var function_inline_assembly = false;
    for (lines, 0..) |raw, index| {
        const line = trim(raw);
        if (std.mem.startsWith(u8, line, "; inline asm")) function_inline_assembly = true;
        if (std.mem.eql(u8, line, "; end inline asm")) {
            function_inline_assembly = false;
            continue;
        }
        if (function_inline_assembly) continue;
        if (storage.sectionOwner(line, "code")) |name| active = .{ .name = name, .first = index + 1, .end = 0 };
        if (std.mem.startsWith(u8, line, "; zeropage_section_end ")) {
            if (active) |function| {
                var complete = function;
                complete.end = index;
                try functions.append(allocator, complete);
                active = null;
            }
        }
    }
    return functions;
}

// Hoist only the compiler-owned base copy; target reads remain inside the loop.
// Interprocedural checks prove source/scratch stability through scalar callees.
pub fn optimize(allocator: std.mem.Allocator, assembly: []const u8) ![]u8 {
    var model = storage.Model.init(allocator);
    defer model.deinit();
    try model.collect(assembly);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var split = std.mem.splitScalar(u8, assembly, '\n');
    while (split.next()) |line| try lines.append(allocator, line);
    var functions = try collectFunctions(allocator, lines.items);
    defer functions.deinit(allocator);
    const removed = try allocator.alloc(bool, lines.items.len);
    defer allocator.free(removed);
    @memset(removed, false);
    const read_markers = try allocator.alloc(bool, lines.items.len);
    defer allocator.free(read_markers);
    @memset(read_markers, false);
    var plans: std.ArrayList(Plan) = .empty;
    defer plans.deinit(allocator);
    for (functions.items) |function| {
        var inline_assembly = false;
        for (function.first..function.end) |start| {
            const marker = trim(lines.items[start]);
            if (std.mem.startsWith(u8, marker, "; inline asm")) inline_assembly = true;
            if (std.mem.eql(u8, marker, "; end inline asm")) {
                inline_assembly = false;
                continue;
            }
            if (inline_assembly) continue;
            if (!std.mem.startsWith(u8, marker, "; zeropage_loop_begin ")) continue;
            const id = fieldNumber(marker, "id=") orelse continue;
            const count = fieldNumber(marker, "count=") orelse continue;
            if (count == 0 or count > 255) continue;
            const body_name = try std.fmt.allocPrint(allocator, "for_{d}_body:", .{id});
            defer allocator.free(body_name);
            var end: ?usize = null;
            var body: ?usize = null;
            for (start + 1..function.end) |index| {
                const line = trim(lines.items[index]);
                if (std.mem.eql(u8, line, body_name)) body = index;
                if (std.mem.startsWith(u8, line, "; zeropage_loop_end ") and fieldNumber(line, "id=") == id) {
                    end = index;
                    break;
                }
            }
            if (end == null or body == null) continue;
            // The existing for header begins with a private index load, killing
            // setup A/NZ before any consumer. It must not observe the ZP pair.
            if (start + 2 >= body.?) continue;
            const header = machine.Instruction.parse(lines.items[start + 2]) orelse continue;
            if (header.op != .lda or header.operand != .direct or model.resolve(header.operand.direct, 1) == null) continue;
            const killed = [_]machine.Instruction{header};
            if (!machine.outputsDeadBeforeRead(&killed, machine.a | machine.nz)) continue;
            var first_read: ?usize = null;
            for (body.? + 1..end.?) |index| if (pointers.readAt(lines.items, index) != null) {
                first_read = index;
                break;
            };
            if (first_read == null) continue;
            const initial = pointers.readAt(lines.items, first_read.?).?;
            const source = model.resolve(.{ .name = initial.source }, 2) orelse continue;
            if (!std.mem.eql(u8, model.frames.items[source.frame].owner, function.name)) continue;
            var analysis: Analysis = .{ .allocator = allocator, .model = &model, .lines = lines.items, .functions = functions.items, .source = source };
            defer analysis.callers.deinit(allocator);
            var reads: std.ArrayList(usize) = .empty;
            defer reads.deinit(allocator);
            var safe = true;
            var index = start + 1;
            while (index < end.?) {
                const line = trim(lines.items[index]);
                if (std.mem.startsWith(u8, line, "; inline asm")) {
                    safe = false;
                    break;
                }
                if (pointers.readAt(lines.items, index)) |read| {
                    const location = model.resolve(.{ .name = read.source }, 2) orelse {
                        safe = false;
                        break;
                    };
                    if (removed[index + 1] or location.frame != source.frame or location.offset != source.offset) {
                        safe = false;
                        break;
                    }
                    try reads.append(allocator, index);
                    index = read.next;
                    continue;
                }
                if (line.len == 0 or line[0] == ';' or std.mem.endsWith(u8, line, ":")) {
                    index += 1;
                    continue;
                }
                const inst = machine.Instruction.parse(line) orelse {
                    safe = false;
                    break;
                };
                // First read dominates body exits/continues, making setup useful
                // on every initial iteration, rather than speculating a scan.
                if (index > body.? and index < first_read.? and (isFlow(inst.op) or inst.op == .rts)) {
                    safe = false;
                    break;
                }
                if (!try analysis.instructionSafe(inst, function)) {
                    safe = false;
                    break;
                }
                index += 1;
            }
            if (!safe or reads.items.len == 0 or (count == 1 and reads.items.len == 1)) continue;
            try plans.append(allocator, .{ .start = start, .source = initial.source });
            for (reads.items) |read| {
                read_markers[read] = true;
                @memset(removed[read + 1 .. read + 5], true);
            }
        }
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (lines.items, 0..) |line, index| {
        if (removed[index]) continue;
        if (read_markers[index]) {
            try output.writer.writeAll("    ; zeropage_loop_pointer_read\n");
        } else if (index + 1 < lines.items.len or line.len != 0) try output.writer.print("{s}\n", .{line});
        for (plans.items) |plan| if (plan.start == index) {
            try output.writer.print("    ; zeropage_loop_invariant source={s}\n    lda {s}\n    sta zeropage_ptr_tmp\n    lda {s}+1\n    sta zeropage_ptr_tmp+1\n", .{ plan.source, plan.source, plan.source });
        };
    }
    return try output.toOwnedSlice();
}

fn testProgram(allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8, callee: []const u8, count: u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\* = $2000
        \\; zeropage_section_begin owner=function:f kind=code
        \\f:
        \\    lda #0
        \\    sta f_index
        \\; zeropage_loop_begin id=1 count={d}
        \\for_1_top:
        \\    lda f_index
        \\    cmp #{d}
        \\    bcc for_1_body
        \\    jmp for_1_done
        \\for_1_body:
        \\    {s}
        \\    ; zeropage_pointer_read source=f_pointer bytes=1
        \\    lda f_pointer
        \\    sta zeropage_ptr_tmp
        \\    lda f_pointer+1
        \\    sta zeropage_ptr_tmp+1
        \\    ldy #0
        \\    lda (zeropage_ptr_tmp),y
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
        \\f_alias:
        \\f_pointer:
        \\    .word 0
        \\f_index:
        \\    .byte 0
        \\f_result:
        \\    .byte 0
        \\; zeropage_section_end owner=function:f kind=static_frame
        \\; zeropage_section_begin owner=function:g kind=static_frame
        \\g_value:
        \\    .byte 0
        \\; zeropage_section_end owner=function:g kind=static_frame
        \\; zeropage_section_begin owner=compiler kind=rodata
        \\table:
        \\    .byte 0,1,2,3
        \\; zeropage_section_end owner=compiler kind=rodata
        \\
    , .{ count, count, prefix, suffix, callee });
}

test "loop bases hoist through scalar calls and branches after the first read" {
    for ([_][]const u8{ "", "jsr g", "beq for_1_done" }) |suffix| {
        const input = try testProgram(std.testing.allocator, "", suffix, "lda table,x\n    sta g_value", 4);
        defer std.testing.allocator.free(input);
        const result = try optimize(std.testing.allocator, input);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result, "zeropage_loop_invariant source=f_pointer"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result, "lda (zeropage_ptr_tmp),y"));
        try std.testing.expect(std.mem.indexOf(u8, result, "sta zeropage_ptr_tmp+1\nfor_1_top:") != null);
    }
}

test "loop bases reject aliases unknown stores callee clobbers recursion and volatile reads" {
    for ([_][]const u8{
        "sta f_pointer",                           "inc f_alias+1", "sta (zeropage_ptr_tmp),y", "sta g_value,x",
        "sta zeropage_ptr_tmp",                    "jsr missing",   "jsr g",                    "lda $dc04",
        "; inline asm from ZeroPage line 1\n nop",
    }) |unsafe| {
        const input = try testProgram(std.testing.allocator, "", unsafe, "sta f_alias", 4);
        defer std.testing.allocator.free(input);
        const result = try optimize(std.testing.allocator, input);
        defer std.testing.allocator.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "zeropage_loop_invariant") == null);
    }
    for ([_][]const u8{ "sta zeropage_ptr_tmp+1", "sta f_alias+1", "jsr g", "jsr missing", "lda $dc04", "lda zeropage_ptr_tmp" }) |callee| {
        const input = try testProgram(std.testing.allocator, "", "jsr g", callee, 4);
        defer std.testing.allocator.free(input);
        const result = try optimize(std.testing.allocator, input);
        defer std.testing.allocator.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "zeropage_loop_invariant") == null);
    }
}

test "loop bases require useful positive iterations and a dominating first read" {
    for ([_]u8{ 0, 1 }) |count| {
        const input = try testProgram(std.testing.allocator, "", "", "", count);
        defer std.testing.allocator.free(input);
        const result = try optimize(std.testing.allocator, input);
        defer std.testing.allocator.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "zeropage_loop_invariant") == null);
    }
    for ([_][]const u8{ "beq for_1_next", "jmp for_1_done", "rts" }) |prefix| {
        const input = try testProgram(std.testing.allocator, prefix, "", "", 4);
        defer std.testing.allocator.free(input);
        const result = try optimize(std.testing.allocator, input);
        defer std.testing.allocator.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "zeropage_loop_invariant") == null);
    }
}

test "loop metadata inside opaque assembly cannot authorize hoisting" {
    const input = try testProgram(std.testing.allocator, "", "", "", 4);
    defer std.testing.allocator.free(input);
    const wrapped = try std.mem.replaceOwned(u8, std.testing.allocator, input, "f:\n", "f:\n; inline asm from ZeroPage line 1\n");
    defer std.testing.allocator.free(wrapped);
    const closed = try std.mem.replaceOwned(u8, std.testing.allocator, wrapped, "; zeropage_loop_end id=1", "; zeropage_loop_end id=1\n; end inline asm");
    defer std.testing.allocator.free(closed);
    const result = try optimize(std.testing.allocator, closed);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "zeropage_loop_invariant") == null);
}
