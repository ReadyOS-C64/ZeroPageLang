const std = @import("std");
const ast = @import("../../ast.zig");
const policy = @import("../../zero_page.zig");
const machine = @import("instruction.zig");
const storage_model = @import("storage_model.zig");
const scalars = @import("zero_page_scalars.zig");

const Candidate = struct {
    label: []const u8,
    size: u16,
    label_line: usize,
    data_line: usize,
    benefit: u64 = 0,
    pinned: bool = false,
    kind: policy.ClaimKind = .scratch,
    indexed: bool = false,
    address_escapes: bool = false,
    assembly_sensitive: bool = false,
    parameter_reason: ?scalars.Reason = null,
};

fn stackPairs(program: ast.Program) ?policy.StackPairs {
    const stack = program.zeropage_options.stack orelse return null;
    return .{ .sp = stack.zp.sp, .fp = stack.zp.fp };
}

fn zeroSize(line: []const u8) ?u16 {
    if (std.mem.eql(u8, line, ".word 0") or std.mem.eql(u8, line, ".byte 0,0")) return 2;
    if (std.mem.eql(u8, line, ".byte 0")) return 1;
    return null;
}

fn isInlineBegin(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "; inline asm from ZeroPage line ");
}

fn candidateUses(candidate: *Candidate, lines: []const []const u8) void {
    var in_assembly = false;
    var depth: u8 = 0;
    for (lines) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (isInlineBegin(line)) in_assembly = true;
        if (std.mem.eql(u8, line, "; end inline asm")) in_assembly = false;
        if (std.mem.startsWith(u8, line, "; zeropage_loop_begin ")) depth +|= 1;
        if (std.mem.startsWith(u8, line, "; zeropage_loop_end ")) depth -|= 1;
        if (in_assembly) {
            if (std.mem.indexOf(u8, line, candidate.label) != null) {
                candidate.pinned = true;
                candidate.assembly_sensitive = true;
            }
            continue;
        }
        const inst = machine.Instruction.parse(line) orelse {
            // Data/address expressions cannot silently escape a moved cell.
            if (line.len != 0 and line[0] != ';' and !std.mem.endsWith(u8, line, ":") and std.mem.indexOf(u8, line, candidate.label) != null) {
                candidate.pinned = true;
                candidate.address_escapes = true;
            }
            continue;
        };
        switch (inst.operand) {
            .direct => |reference| if (std.mem.eql(u8, reference.name, candidate.label)) {
                if (reference.offset < 0 or reference.offset >= candidate.size) {
                    candidate.pinned = true;
                    candidate.address_escapes = true;
                }
                // Estimate saved instruction bytes and execution frequency;
                // this is a stable heuristic, never a measured-cycle claim.
                candidate.benefit +|= if (depth != 0) 8 else 1;
            },
            .indexed => |reference| if (std.mem.eql(u8, reference.base.name, candidate.label)) {
                candidate.pinned = true; // no automatic zero-page wrap semantics
                candidate.indexed = true;
            },
            .immediate => |operand| if (std.mem.indexOf(u8, operand, candidate.label) != null) {
                candidate.pinned = true; // address escapes
                candidate.address_escapes = true;
            },
            .indirect => |operand| if (std.mem.indexOf(u8, operand, candidate.label) != null) {
                candidate.pinned = true;
                candidate.address_escapes = true;
            },
            .unknown => if (std.mem.indexOf(u8, line, candidate.label) != null) {
                candidate.pinned = true;
                candidate.address_escapes = true;
            },
            else => {},
        }
    }
}

fn collect(allocator: std.mem.Allocator, lines: []const []const u8) !std.ArrayList(Candidate) {
    var candidates: std.ArrayList(Candidate) = .empty;
    errdefer candidates.deinit(allocator);
    var scratch = false;
    var in_assembly = false;
    for (lines, 0..) |raw, index| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (isInlineBegin(line)) in_assembly = true;
        if (std.mem.eql(u8, line, "; end inline asm")) in_assembly = false;
        if (in_assembly) continue;
        if (std.mem.startsWith(u8, line, "; zeropage_section_begin ")) scratch = std.mem.indexOf(u8, line, "owner=compiler kind=scratch ") != null;
        if (std.mem.startsWith(u8, line, "; zeropage_section_end ")) scratch = false;
        if (!scratch or !std.mem.endsWith(u8, line, ":") or index + 1 >= lines.len) continue;
        const size = zeroSize(std.mem.trim(u8, lines[index + 1], " \t\r")) orelse continue;
        const label = line[0 .. line.len - 1];
        if (!std.mem.startsWith(u8, label, "zeropage_")) continue;
        try candidates.append(allocator, .{ .label = label, .size = size, .label_line = index, .data_line = index + 1 });
    }
    for (candidates.items) |*candidate| candidateUses(candidate, lines);
    return candidates;
}

// Collect definitions from real compiler-owned static-frame sections. Every
// colocated label receives an aliased fact; a scalar-looking aggregate child
// cannot become a parameter solely because it has a .byte/.word initializer.
fn collectParameters(allocator: std.mem.Allocator, program: ast.Program, lines: []const []const u8, candidates: *std.ArrayList(Candidate)) ![]scalars.Decision {
    var facts: std.ArrayList(scalars.StorageFact) = .empty;
    defer facts.deinit(allocator);
    var definitions: std.ArrayList(Candidate) = .empty;
    defer definitions.deinit(allocator);
    var pending: std.ArrayList(usize) = .empty;
    defer pending.deinit(allocator);
    var counts: std.StringHashMap(usize) = .init(allocator);
    defer counts.deinit();
    for (lines) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.endsWith(u8, line, ":")) continue;
        const entry = try counts.getOrPut(line[0 .. line.len - 1]);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }
    var owner: ?[]const u8 = null;
    var in_assembly = false;
    for (lines, 0..) |raw, index| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (isInlineBegin(line)) in_assembly = true;
        if (std.mem.eql(u8, line, "; end inline asm")) in_assembly = false;
        if (in_assembly) continue;
        if (std.mem.startsWith(u8, line, "; zeropage_section_")) {
            owner = storage_model.sectionOwner(line, "static_frame");
            pending.clearRetainingCapacity();
            continue;
        }
        const function_name = owner orelse continue;
        if (line.len == 0 or line[0] == ';') continue;
        if (std.mem.endsWith(u8, line, ":")) {
            try pending.append(allocator, index);
            continue;
        }
        if (zeroSize(line)) |size| for (pending.items) |label_line| {
            const label_text = std.mem.trim(u8, lines[label_line], " \t\r");
            const label = label_text[0 .. label_text.len - 1];
            var candidate: Candidate = .{ .label = label, .size = size, .label_line = label_line, .data_line = index, .kind = .parameter };
            candidateUses(&candidate, lines);
            const fact: scalars.StorageFact = .{
                .label = label,
                .owner = function_name,
                .size = size,
                .zero_initialized = true,
                .has_aliases = pending.items.len != 1,
                .indexed = candidate.indexed,
                .address_escapes = candidate.address_escapes,
                .assembly_sensitive = candidate.assembly_sensitive,
            };
            try facts.append(allocator, fact);
            if ((counts.get(label) orelse 0) != 1) try facts.append(allocator, fact);
            try definitions.append(allocator, candidate);
        };
        pending.clearRetainingCapacity();
    }
    const decisions = try scalars.classifyParameters(allocator, program, facts.items);
    errdefer scalars.freeDecisions(allocator, decisions);
    for (decisions) |decision| {
        for (definitions.items) |definition| {
            if (!std.mem.eql(u8, decision.label, definition.label)) continue;
            var candidate = definition;
            candidate.parameter_reason = decision.reason;
            candidate.pinned = !decision.eligible();
            try candidates.append(allocator, candidate);
            break;
        }
    }
    return decisions;
}

// Shared pre-relocation proof for optimizations which need actual typed private
// parameter cells. This neither allocates zero page nor changes application policy.
pub fn parameterDecisions(allocator: std.mem.Allocator, program: ast.Program, lines: []const []const u8) ![]scalars.Decision {
    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(allocator);
    return collectParameters(allocator, program, lines, &candidates);
}

fn spillReason(candidate: Candidate, options: policy.Options) []const u8 {
    if (candidate.parameter_reason) |reason| if (reason != .eligible) return @tagName(reason);
    if (candidate.pinned) return "address_or_index_or_asm";
    if (options.allocation == .off) return "allocation_off";
    if (candidate.benefit == 0) return "unused";
    return "capacity";
}

fn allowedKernal(address: u16) bool {
    return switch (address) {
        0xff90,
        0xff93,
        0xff96,
        0xff99,
        0xff9c,
        0xff9f,
        0xffa2,
        0xffa5,
        0xffa8,
        0xffab,
        0xffae,
        0xffb1,
        0xffb4,
        0xffb7,
        0xffba,
        0xffbd,
        0xffc0,
        0xffc3,
        0xffc6,
        0xffc9,
        0xffcc,
        0xffcf,
        0xffd2,
        0xffd5,
        0xffd8,
        0xffdb,
        0xffde,
        0xffe1,
        0xffe4,
        0xffe7,
        0xffea,
        0xffed,
        0xfff0,
        0xfff3,
        => true,
        else => false,
    };
}

fn validateServices(options: policy.Options, lines: []const []const u8) !void {
    if (options.profile != .bare and options.profile != .kernal) return;
    for (lines) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const split = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const mnemonic = line[0..split];
        if (!std.ascii.eqlIgnoreCase(mnemonic, "jsr") and !std.ascii.eqlIgnoreCase(mnemonic, "jmp")) continue;
        const text = line[split..];
        const end = std.mem.indexOfScalar(u8, text, ';') orelse text.len;
        const operand = machine.parseOperand(std.mem.trim(u8, text[0..end], " \t"));
        if (operand == .unknown or operand == .indirect) return error.UnsupportedZeroPageRomService;
        if (operand == .direct and operand.direct.offset != 0) return error.UnsupportedZeroPageRomService;
        if (operand != .address) continue;
        const address = operand.address;
        const rom = (address >= 0xa000 and address < 0xc000) or address >= 0xe000;
        if (!rom) continue;
        if (options.profile == .bare or !allowedKernal(address)) return error.UnsupportedZeroPageRomService;
    }
}

fn countMask(mask: [256]bool) usize {
    var count: usize = 0;
    for (mask) |selected| if (selected) {
        count += 1;
    };
    return count;
}

fn saveRegisters(writer: anytype) !void {
    try writer.writeAll("    php\n    pha\n    txa\n    pha\n    tya\n    pha\n");
}
fn restoreRegisters(writer: anytype) !void {
    try writer.writeAll("    pla\n    tay\n    pla\n    tax\n    pla\n    plp\n    rts\n");
}

fn emitSnapshot(writer: anytype, mask: [256]bool, restoring: bool) !void {
    var start: usize = 0;
    var saved: usize = 0;
    while (start < 256) {
        if (!mask[start]) {
            start += 1;
            continue;
        }
        var end = start + 1;
        while (end < 256 and mask[end]) : (end += 1) {}
        const size = end - start;
        if (size <= 2) {
            for (start..end) |address| {
                if (restoring) try writer.print("    lda zeropage_zp_snapshot+{d}\n    sta ${x:0>2}\n", .{ saved, address }) else try writer.print("    lda ${x:0>2}\n    sta zeropage_zp_snapshot+{d}\n", .{ address, saved });
                saved += 1;
            }
        } else {
            try writer.print("    ldx #0\nzeropage_zp_{s}_{d}:\n", .{ if (restoring) "restore" else "save", start });
            if (restoring) try writer.print("    lda zeropage_zp_snapshot+{d},x\n    sta ${x:0>2},x\n", .{ saved, start }) else try writer.print("    lda ${x:0>2},x\n    sta zeropage_zp_snapshot+{d},x\n", .{ start, saved });
            try writer.print("    inx\n    cpx #{d}\n    bne zeropage_zp_{s}_{d}\n", .{ size, if (restoring) "restore" else "save", start });
            saved += size;
        }
        start = end;
    }
}

fn emitInitialization(writer: anytype, mask: [256]bool) !void {
    if (countMask(mask) == 0) return;
    try writer.writeAll("    lda #0\n");
    var start: usize = 0;
    while (start < 256) {
        if (!mask[start]) {
            start += 1;
            continue;
        }
        var end = start + 1;
        while (end < 256 and mask[end]) : (end += 1) {}
        const size = end - start;
        if (size < 5) {
            for (start..end) |address| try writer.print("    sta ${x:0>2}\n", .{address});
        } else {
            try writer.print("    ldx #0\nzeropage_zp_zero_{d}:\n    sta ${x:0>2},x\n    inx\n    cpx #{d}\n    bne zeropage_zp_zero_{d}\n", .{ start, start, size, start });
        }
        start = end;
    }
}

fn emitLifecycle(writer: anytype, plan: policy.Plan, initialized: [256]bool) !void {
    try writer.writeAll("; zeropage_section_begin owner=runtime kind=code lifetime=static address=near\nzeropage_zp_enter:\n");
    try saveRegisters(writer);
    try emitSnapshot(writer, plan.restore, false);
    try emitInitialization(writer, initialized);
    try restoreRegisters(writer);
    try writer.writeAll("zeropage_zp_leave:\n");
    try saveRegisters(writer);
    try emitSnapshot(writer, plan.restore, true);
    try restoreRegisters(writer);
    try writer.writeAll("; zeropage_section_end owner=runtime kind=code\n");
    const size = countMask(plan.restore);
    if (size != 0) try writer.print("; zeropage_section_begin owner=compiler kind=data lifetime=static address=near\nzeropage_zp_snapshot:\n    .fill {d},0\n; zeropage_section_end owner=compiler kind=data\n", .{size});
}

fn pointerAlias(line: []const u8, plan: policy.Plan) ?u8 {
    const split = std.mem.indexOf(u8, line, " = ") orelse return null;
    const name = line[0..split];
    for ([_][]const u8{ "zeropage_console_ptr", "zeropage_string_dst_ptr", "zeropage_ptr_tmp" }) |candidate| if (std.mem.eql(u8, name, candidate)) return plan.ptr;
    for ([_][]const u8{ "zeropage_string_ptr", "zeropage_string_src_ptr" }) |candidate| if (std.mem.eql(u8, name, candidate)) return plan.string_ptr;
    for ([_][]const u8{ "zeropage_stack_sp", "zeropage_stack_fp" }) |candidate| if (std.mem.eql(u8, name, candidate)) return if (plan.find(name)) |claim| claim.addr else null;
    return null;
}

// Borrow assembly; only explicit application policy invokes this final pass.
// Existing optimizers analyze the original static storage before it moves.
pub fn apply(allocator: std.mem.Allocator, program: ast.Program, assembly: []const u8) ![]u8 {
    const options = program.zeropage_options.zero_page;
    if (program.zeropage_options.image.load_addr < 0x0200 or program.zeropage_options.image.entry_addr < 0x0200) return error.UnsupportedZeroPageLowImage;
    // A bare caller must establish IRQ/NMI ownership before this entry, which
    // snapshots/initializes workspace before any source main statement runs.
    if (options.profile == .bare and program.zeropage_options.image.basic_stub) return error.UnsupportedZeroPageBareEntry;
    if ((program.zeropage_module != null or program.zeropage_options.modules != null) and
        (options.profile != .compatibility or options.allocation != .off or options.ranges_declared or options.reserve.len != 0)) return error.UnsupportedZeroPageModuleABI;
    var plan = try policy.resolve(allocator, options, stackPairs(program));
    defer plan.deinit(allocator);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var split = std.mem.splitScalar(u8, assembly, '\n');
    while (split.next()) |line| try lines.append(allocator, line);
    try validateServices(options, lines.items);
    var candidates = try collect(allocator, lines.items);
    defer candidates.deinit(allocator);
    const decisions = if (options.allocation == .scalars) try collectParameters(allocator, program, lines.items, &candidates) else try allocator.alloc(scalars.Decision, 0);
    defer scalars.freeDecisions(allocator, decisions);
    var requests: std.ArrayList(policy.Request) = .empty;
    defer requests.deinit(allocator);
    for (candidates.items) |candidate| if (!candidate.pinned and candidate.benefit != 0) {
        try requests.append(allocator, .{ .label = candidate.label, .size = candidate.size, .benefit = candidate.benefit, .kind = candidate.kind });
    };
    if (options.allocation != .off) try plan.allocateScratch(allocator, requests.items);
    var initialized = [_]bool{false} ** 256;
    for (plan.claims.items) |claim| if (claim.kind == .scratch or claim.kind == .parameter) {
        for (claim.addr..@as(u16, claim.addr) + claim.size) |address| initialized[address] = true;
    };
    const lifecycle = countMask(plan.restore) != 0 or countMask(initialized) != 0;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var wrapper = false;
    var anchor = false;
    var in_assembly = false;
    var index: usize = 0;
    while (index < lines.items.len) : (index += 1) {
        const raw = lines.items[index];
        const line = std.mem.trim(u8, raw, " \t\r");
        if (isInlineBegin(line)) in_assembly = true;
        if (std.mem.eql(u8, line, "; end inline asm")) in_assembly = false;
        if (in_assembly) {
            try out.writer.print("{s}\n", .{raw});
            continue;
        }
        if (pointerAlias(line, plan)) |address| {
            const end = std.mem.indexOf(u8, line, " = ").?;
            try out.writer.print("{s} = address(${x:0>2})\n", .{ line[0..end], address });
            continue;
        }
        if (std.mem.eql(u8, line, "; zeropage_zero_page_runtime_anchor")) {
            if (lifecycle) try emitLifecycle(&out.writer, plan, initialized);
            anchor = true;
        }
        if (lifecycle and std.mem.startsWith(u8, line, "; zeropage_section_begin owner=function:main kind=code ")) {
            if (wrapper) return error.InvalidZeroPageEntry;
            try out.writer.writeAll("; zeropage_section_begin owner=runtime kind=code lifetime=static address=near\n    jsr main\n    jmp zeropage_zp_leave\n; zeropage_section_end owner=runtime kind=code\n");
            wrapper = true;
        }
        var moved = false;
        for (candidates.items) |candidate| {
            if (candidate.label_line != index) continue;
            if (plan.find(candidate.label)) |claim| {
                if (claim.kind != candidate.kind) continue;
                try out.writer.print("{s} = address(${x:0>2})\n", .{ candidate.label, claim.addr });
                index = candidate.data_line;
                moved = true;
            }
            break;
        }
        if (moved) continue;
        if (index + 1 < lines.items.len or raw.len != 0) try out.writer.print("{s}\n", .{raw});
        if (lifecycle and std.mem.eql(u8, line, "zeropage_entry:")) try out.writer.writeAll("    jsr zeropage_zp_enter\n");
    }
    if (lifecycle and (!wrapper or !anchor)) return error.InvalidZeroPageEntry;
    try out.writer.print("; zeropage_zp_policy profile={s} allocation={s} restore_basic={s} interrupts={s}\n", .{ @tagName(options.profile), @tagName(options.allocation), if (options.restore_basic) "true" else "false", @tagName(options.interrupts) });
    for (plan.claims.items) |claim| try out.writer.print("; zeropage_zp_claim label={s} addr={d} size={d} kind={s} benefit={d}\n", .{ claim.label, claim.addr, claim.size, @tagName(claim.kind), claim.benefit });
    for (candidates.items) |candidate| if (plan.find(candidate.label) == null) {
        try out.writer.print("; zeropage_zp_spill label={s} size={d} reason={s}\n", .{ candidate.label, candidate.size, spillReason(candidate, options) });
    };
    for (decisions) |decision| try out.writer.print("; zeropage_zp_parameter label={s} size={d} reason={s} status={s}\n", .{ decision.label, decision.size, @tagName(decision.reason), if (plan.find(decision.label) != null) "allocated" else if (decision.eligible()) "spilled" else "excluded" });
    return try out.toOwnedSlice();
}

test "zero scratch shapes accept only individual initialized scalar cells" {
    try std.testing.expectEqual(@as(?u16, 1), zeroSize(".byte 0"));
    try std.testing.expectEqual(@as(?u16, 2), zeroSize(".word 0"));
    try std.testing.expect(zeroSize(".byte 0,0,0") == null);
    try std.testing.expect(zeroSize(".word 1") == null);
}

test "borrowed profiles classify ROM services conservatively" {
    try validateServices(.{ .profile = .kernal }, &.{"    jsr $ffd2"});
    try std.testing.expectError(error.UnsupportedZeroPageRomService, validateServices(.{ .profile = .kernal }, &.{"    jsr $ff87"}));
    try std.testing.expectError(error.UnsupportedZeroPageRomService, validateServices(.{ .profile = .kernal }, &.{"    jmp $a000"}));
    try std.testing.expectError(error.UnsupportedZeroPageRomService, validateServices(.{ .profile = .bare }, &.{"    jsr $ffd2"}));
    try std.testing.expectError(error.UnsupportedZeroPageRomService, validateServices(.{ .profile = .kernal }, &.{"    JSR $FF87"}));
    try std.testing.expectError(error.UnsupportedZeroPageRomService, validateServices(.{ .profile = .kernal }, &.{"    jMp $A000 ; BASIC"}));
    try std.testing.expectError(error.UnsupportedZeroPageRomService, validateServices(.{ .profile = .kernal }, &.{"    JSR $ff00+135"}));
    try std.testing.expectError(error.UnsupportedZeroPageRomService, validateServices(.{ .profile = .kernal }, &.{"    JSR main+$9800"}));
}

test "indexing address escapes and in_assembly assembly pin scratch candidates" {
    for ([_][]const u8{ "    lda scratch,y", "    lda #<scratch", "    lda (scratch),y", "    lda scratch+2", "; inline asm from ZeroPage line 1\n" }) |line| {
        var candidate: Candidate = .{ .label = "scratch", .size = 2, .label_line = 0, .data_line = 1 };
        candidateUses(&candidate, &.{ line, "    lda scratch" });
        try std.testing.expect(candidate.pinned);
    }
}

fn expectFrameReason(definitions: []const u8, uses: []const u8, expected: scalars.Reason) !void {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator,
        \\fn f(value: u16) u16 { return value; }
        \\export fn main() void { _ = f(257); }
    );
    defer parsed.deinit(std.testing.allocator);
    const assembly = try std.fmt.allocPrint(std.testing.allocator,
        \\* = $2000
        \\; zeropage_section_begin owner=function:f kind=code lifetime=static address=near
        \\f:
        \\{s}
        \\    rts
        \\; zeropage_section_end owner=function:f kind=code
        \\; zeropage_section_begin owner=function:f kind=static_frame lifetime=static address=near
        \\{s}
        \\; zeropage_section_end owner=function:f kind=static_frame
        \\
    , .{ uses, definitions });
    defer std.testing.allocator.free(assembly);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(std.testing.allocator);
    var split = std.mem.splitScalar(u8, assembly, '\n');
    while (split.next()) |line| try lines.append(std.testing.allocator, line);
    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(std.testing.allocator);
    const decisions = try collectParameters(std.testing.allocator, parsed.program, lines.items, &candidates);
    defer scalars.freeDecisions(std.testing.allocator, decisions);
    try std.testing.expectEqual(@as(usize, 1), decisions.len);
    try std.testing.expectEqual(expected, decisions[0].reason);
    if (expected == .eligible) {
        try std.testing.expectEqual(@as(usize, 1), candidates.items.len);
        try std.testing.expectEqual(policy.ClaimKind.parameter, candidates.items[0].kind);
        try std.testing.expectEqual(@as(u16, 2), candidates.items[0].size);
        try std.testing.expect(candidates.items[0].benefit != 0);
    }
}

test "parameter extraction needs typed width and a unique scalar frame definition" {
    try expectFrameReason("f_value:\n.word 0", "lda f_value\nldx f_value+1", .eligible);
    try expectFrameReason("f_value:\n.byte 0", "lda f_value", .layout);
    try expectFrameReason("f_value:\nalias:\n.word 0", "lda f_value", .aliased);
    try expectFrameReason("f_value:\n.word 0\nf_value:\n.word 0", "lda f_value", .duplicate_definition);
    try expectFrameReason("f_other:\n.word 0", "lda f_other", .missing_definition);
}

test "parameter extraction retains indexed address-escaped and opaque cell references" {
    try expectFrameReason("f_value:\n.word 0", "lda f_value,y", .indexed);
    try expectFrameReason("f_value:\n.word 0", "lda #<f_value", .address_escape);
    try expectFrameReason("f_value:\n.word 0", "lda (f_value),y", .address_escape);
    try expectFrameReason("f_value:\n.word 0", "lda f_value+2", .address_escape);
    try expectFrameReason("f_value:\n.word 0", ".word f_value", .address_escape);
    try expectFrameReason("f_value:\n.word 0", "; inline asm from ZeroPage line 1\nlda f_value\n; end inline asm", .assembly_sensitive);
}
