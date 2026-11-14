const std = @import("std");

pub const Plan = struct {
    shifts: u4,
    adds: u16,
    subtracts: u16 = 0,

    fn bytes(self: Plan) u16 {
        // A/X shift is six bytes. A carry-chained add or subtract of the
        // original word is at most eleven with absolute operands.
        return @as(u16, self.shifts) * 6 + @as(u16, @popCount(self.adds | self.subtracts)) * 11;
    }
};

fn signedDigits(factor: u16) ?Plan {
    var remaining: u32 = factor;
    var adds: u16 = 0;
    var subtracts: u16 = 0;
    for (0..16) |bit| {
        if (remaining == 0) break;
        const mask = @as(u16, 1) << @as(u4, @intCast(bit));
        switch (remaining & 3) {
            1 => adds |= mask,
            3 => {
                subtracts |= mask;
                remaining += 1;
            },
            else => {},
        }
        remaining >>= 1;
    }
    if (remaining != 0) return null;
    const top: u4 = @intCast(15 - @clz(adds));
    return .{ .shifts = top, .adds = adds ^ (@as(u16, 1) << top), .subtracts = subtracts };
}

pub fn choose(factor: u16, capture: bool) ?Plan {
    if (factor < 3 or std.math.isPowerOfTwo(factor)) return null;
    const top: u4 = @intCast(15 - @clz(factor));
    const binary: Plan = .{ .shifts = top, .adds = factor ^ (@as(u16, 1) << top) };
    const signed = signedDigits(factor) orelse binary;
    const best = if (signed.bytes() < binary.bytes()) signed else binary;
    // Allow a bounded site-size tradeoff against the general setup and call.
    // A program can also drop the shared helper when its final use disappears.
    const capture_bytes: u16 = if (capture) 6 else 0;
    return if (best.bytes() + capture_bytes <= 35) best else null;
}

test "word multiply chooses compact binary and signed digit sequences" {
    try std.testing.expectEqualDeep(Plan{ .shifts = 1, .adds = 1 }, choose(3, true).?);
    try std.testing.expectEqualDeep(Plan{ .shifts = 2, .adds = 1 }, choose(5, true).?);
    try std.testing.expectEqualDeep(Plan{ .shifts = 3, .adds = 0, .subtracts = 1 }, choose(7, true).?);
    try std.testing.expectEqualDeep(Plan{ .shifts = 3, .adds = 1 }, choose(9, true).?);
    try std.testing.expectEqualDeep(Plan{ .shifts = 3, .adds = 2 }, choose(10, true).?);
    try std.testing.expect(choose(0x5555, false) == null);
    try std.testing.expect(choose(256, false) == null);
}

test "every selected word recipe reconstructs its factor" {
    for (3..65536) |raw| {
        const factor: u16 = @intCast(raw);
        const plan = choose(factor, false) orelse continue;
        try std.testing.expectEqual(@as(u16, 0), plan.adds & plan.subtracts);
        try std.testing.expectEqual(factor, (@as(u16, 1) << plan.shifts) +% plan.adds -% plan.subtracts);
    }
}
