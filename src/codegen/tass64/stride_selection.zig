const std = @import("std");

// Specialize the existing fixed-factor mul16 address calculation, not source
// integer semantics. The initial ADC into zero matters on NMOS decimal input.
// Complete A/X/Y/P/SP matches the generic helper, including its final carry.
pub const Kind = enum { power_of_two, shifted_add };
pub const CostModel = enum {
    // Correct even if earlier/later placement gives old operands zero-page size
    // while the new helper uses absolute operands.
    conservative,
    // Caller proved ordinary absolute scratch (no automatic ZP placement).
    absolute,
};
pub const Plan = struct {
    factor: u16,
    kind: Kind,
    shift: u4,
    helper_bytes: u16,
    call_sites: u32,
    legacy_bytes: u64,
    selected_bytes: u64,
};

// Scratch labels intentionally reuse mul16's private operands/results. A caller
// can retain these four bytes while pruning RHS and the generic loop if no other
// multiply remains. No pointer, source frame or application reservation is used.
pub const Usage = struct {
    powers: u16 = 0,
    odds: u16 = 0,
    call_sites: u64 = 0,

    pub fn usesLhs(self: Usage) bool {
        return self.powers != 0 or self.odds != 0;
    }
    pub fn usesResult(self: Usage) bool {
        return self.usesLhs();
    }
    pub fn emitCall(self: *Usage, writer: anytype, plan: Plan) !void {
        std.debug.assert(plan.factor > 2);
        const mask = @as(u16, 1) << plan.shift;
        if (plan.kind == .power_of_two) self.powers |= mask else self.odds |= mask;
        self.call_sites += 1;
        try writer.print("    jsr zeropage_stride_mul_{d}\n", .{plan.factor});
    }
    pub fn emitHelpers(self: Usage, writer: anytype) !void {
        // Sorted numeric factors, stable labels, one body per selected factor.
        for (1..16) |amount| {
            const shift: u4 = @intCast(amount);
            const mask = @as(u16, 1) << shift;
            if (self.powers & mask != 0) try emitHelper(writer, mask, .power_of_two, shift);
            if (self.odds & mask != 0) try emitHelper(writer, mask + 1, .shifted_add, shift);
        }
    }
};

pub fn choose(factor: u16, call_sites: u32, generic_needed_elsewhere: bool) ?Plan {
    return chooseWithCost(factor, call_sites, generic_needed_elsewhere, .conservative);
}

// Cost includes all selected call sites and the complete shared body. Comparing
// one factor in isolation can conservatively miss a multi-factor/global win;
// it must never pretend the generic helper disappears if another user remains.
pub fn chooseWithCost(factor: u16, call_sites: u32, generic_needed_elsewhere: bool, model: CostModel) ?Plan {
    const plan = estimate(factor, call_sites, generic_needed_elsewhere, model) orelse return null;
    return if (plan.selected_bytes < plan.legacy_bytes) plan else null;
}

// Eligible shape plus costs, even when not profitable in isolation. Portfolio
// selection must account for shared generic-helper removal only once.
pub fn estimate(factor: u16, call_sites: u32, generic_needed_elsewhere: bool, model: CostModel) ?Plan {
    // One/two already have distinct inline legacy address paths. Do not silently
    // introduce mul16 decimal behavior at those integration sites.
    if (factor <= 2 or call_sites == 0) return null;
    const kind: Kind = if (std.math.isPowerOfTwo(factor)) .power_of_two else if (std.math.isPowerOfTwo(factor - 1)) .shifted_add else return null;
    const shift: u4 = @intCast(@ctz(if (kind == .power_of_two) factor else factor - 1));
    const helper_bytes: u16 = (if (kind == .power_of_two) @as(u16, 34) else 53) + shiftBytes(shift);
    const legacy_site: u64 = if (model == .absolute) 19 else 15;
    const legacy_helper: u64 = if (generic_needed_elsewhere) 0 else if (model == .absolute) 53 else 39;
    const legacy_bytes = @as(u64, call_sites) * legacy_site + legacy_helper;
    const selected_bytes = @as(u64, call_sites) * 3 + helper_bytes;
    return .{ .factor = factor, .kind = kind, .shift = shift, .helper_bytes = helper_bytes, .call_sites = call_sites, .legacy_bytes = legacy_bytes, .selected_bytes = selected_bytes };
}

fn shiftBytes(shift: u4) u16 {
    return if (shift < 8) @as(u16, shift) * 6 else 11 + @as(u16, shift) - 8;
}

fn emitSourceShift(writer: anytype, shift: u4) !void {
    if (shift >= 8) {
        // Modulo-16-bit product discards original high, but the initial odd
        // add already consumed it. Keep the original low on the private stack.
        try writer.writeAll("    lda zeropage_mul_lhs\n");
        for (8..@as(usize, shift)) |_| try writer.writeAll("    asl\n");
        try writer.writeAll("    sta zeropage_mul_lhs+1\n    lda #0\n    sta zeropage_mul_lhs\n");
    } else {
        for (0..@as(usize, shift)) |_| try writer.writeAll("    asl zeropage_mul_lhs\n    rol zeropage_mul_lhs+1\n");
    }
}

fn emitHelper(writer: anytype, factor: u16, kind: Kind, shift: u4) !void {
    try writer.print("zeropage_stride_mul_{d}:\n", .{factor});
    try writer.writeAll("    sta zeropage_mul_lhs\n    stx zeropage_mul_lhs+1\n    pha\n");
    if (kind == .shifted_add) {
        // Exactly the generic bit-zero addition, including decimal adjustment
        // of invalid BCD digits. A plain copy is not equivalent under SED.
        try writer.writeAll(
            \\    lda #0
            \\    clc
            \\    adc zeropage_mul_lhs
            \\    sta zeropage_mul_result
            \\    lda #0
            \\    adc zeropage_mul_lhs+1
            \\    sta zeropage_mul_result+1
            \\
        );
    }
    try emitSourceShift(writer, shift);
    if (kind == .power_of_two) {
        try writer.writeAll("    lda #0\n    clc\n    adc zeropage_mul_lhs\n    sta zeropage_mul_result\n    lda #0\n    adc zeropage_mul_lhs+1\n    tax\n");
    } else {
        // Same operand order and carry chain as the generic highest-set-bit
        // addition. All skipped rounds have no add and cannot change V or D.
        try writer.writeAll("    lda zeropage_mul_result\n    clc\n    adc zeropage_mul_lhs\n    sta zeropage_mul_result\n    lda zeropage_mul_result+1\n    adc zeropage_mul_lhs+1\n    tax\n");
    }
    // The generic loop always shifts the original LHS sixteen times, so its
    // final C is original input bit zero. Final loads establish NZ from high.
    // LSR/PLA/LDA/LDX preserve the last ADC's NMOS V and the entry I/D flags.
    try writer.writeAll("    pla\n    lsr\n    lda zeropage_mul_result\n    stx zeropage_mul_result+1\n    ldx zeropage_mul_result+1\n    rts\n\n");
}

test "stride plans cost complete shared bodies and retain unsupported legacy paths" {
    try std.testing.expect(choose(1, 100, false) == null);
    try std.testing.expect(choose(2, 100, false) == null);
    try std.testing.expect(choose(7, 100, false) == null);
    try std.testing.expect(choose(9, 0, false) == null);
    try std.testing.expect(choose(9, 5, true) == null);
    const reused = choose(9, 6, true).?;
    try std.testing.expectEqual(@as(u16, 71), reused.helper_bytes);
    try std.testing.expectEqual(@as(u64, 90), reused.legacy_bytes);
    try std.testing.expectEqual(@as(u64, 89), reused.selected_bytes);
    const sole = chooseWithCost(3, 1, false, .absolute).?;
    try std.testing.expectEqual(@as(u16, 59), sole.helper_bytes);
    try std.testing.expectEqual(@as(u64, 72), sole.legacy_bytes);
    try std.testing.expectEqual(@as(u64, 62), sole.selected_bytes);
    try std.testing.expect(chooseWithCost(3, 1, true, .absolute) == null);
}

test "stride helpers deduplicate and keep source carry and full decimal additions" {
    var usage: Usage = .{};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const plan = choose(9, 100, true).?;
    try usage.emitCall(&out.writer, plan);
    try usage.emitCall(&out.writer, plan);
    try usage.emitHelpers(&out.writer);
    try std.testing.expect(usage.usesLhs() and usage.usesResult());
    try std.testing.expectEqual(@as(u64, 2), usage.call_sites);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "zeropage_stride_mul_9:"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.written(), "    adc zeropage_mul_lhs+1\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "    pla\n    lsr\n    lda zeropage_mul_result\n    stx zeropage_mul_result+1\n    ldx zeropage_mul_result+1\n") != null);
    for ([_][]const u8{ "cld", "sed", "tay", "tya", "zeropage_mul_rhs", "jsr zeropage_mul16" }) |forbidden| try std.testing.expect(std.mem.indexOf(u8, out.written(), forbidden) == null);
}

test "high stride shifts discard only bits beyond modulo word addressing" {
    const plan = chooseWithCost(256, 1, false, .absolute).?;
    try std.testing.expectEqual(@as(u16, 45), plan.helper_bytes);
    var usage: Usage = .{};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try usage.emitCall(&out.writer, plan);
    try usage.emitHelpers(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "    lda zeropage_mul_lhs\n    sta zeropage_mul_lhs+1\n    lda #0\n    sta zeropage_mul_lhs\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "    adc zeropage_mul_lhs+1\n") != null);
}
