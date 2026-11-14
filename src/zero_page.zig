const std = @import("std");

// Physical page-zero ownership is declared by the root application. This module
// has no AST/backend dependencies, so parsing and late allocation share rules.
pub const Range = struct { addr: u16, size: u16 };
pub const StackPairs = struct { sp: u8, fp: u8 };
pub const Profile = enum { compatibility, basic, kernal, bare };
pub const Allocation = enum { off, scratch, scalars };
pub const Interrupts = enum { system, application };
pub const Mask = [256]bool;

pub const Options = struct {
    declared: bool = false,
    profile: Profile = .compatibility,
    allocation: Allocation = .off,
    ranges: []Range = &.{},
    ranges_declared: bool = false,
    reserve: []Range = &.{},
    restore_basic: bool = true,
    interrupts: Interrupts = .system,

    pub fn deinit(self: Options, allocator: std.mem.Allocator) void {
        if (self.ranges.len != 0) allocator.free(self.ranges);
        if (self.reserve.len != 0) allocator.free(self.reserve);
    }
};

pub const Error = error{
    InvalidZeroPageRange,
    OverlappingZeroPageRanges,
    ProtectedZeroPageRange,
    InvalidZeroPageInterruptPolicy,
    ConflictingZeroPageStack,
    ZeroPagePointerSpaceExhausted,
};
pub const AllocationError = Error || std.mem.Allocator.Error || error{
    DuplicateZeroPageClaim,
    InvalidZeroPageRequestKind,
    InvalidZeroPageParameterSize,
};
pub const ClaimKind = enum { pointer, string_pointer, stack_pointer, frame_pointer, scratch, parameter };
pub const Claim = struct { label: []const u8, addr: u8, size: u16, kind: ClaimKind, benefit: u64 = 0 };
pub const Request = struct { label: []const u8, size: u16, benefit: u64, kind: ClaimKind = .scratch };

pub const Plan = struct {
    ptr: u8,
    string_ptr: u8,
    candidates: Mask,
    free: Mask,
    owned: Mask,
    restore: Mask,
    claims: std.ArrayList(Claim) = .empty,
    profile: Profile,
    allocation: Allocation,
    restore_basic: bool,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        for (self.claims.items) |claim| allocator.free(claim.label);
        self.claims.deinit(allocator);
    }

    pub fn find(self: Plan, label: []const u8) ?Claim {
        for (self.claims.items) |claim| if (std.mem.eql(u8, label, claim.label)) return claim;
        return null;
    }

    // A null address means ordinary-RAM spill, never wrap or partial allocation.
    // The caller may use allocateScratch for deterministic benefit/byte ordering.
    pub fn claimScratch(self: *Plan, allocator: std.mem.Allocator, label: []const u8, size: u16, benefit: u64) AllocationError!?u8 {
        if (size == 0 or label.len == 0) return error.InvalidZeroPageRange;
        if (self.find(label) != null) return error.DuplicateZeroPageClaim;
        if (self.allocation == .off) return null;
        const addr = firstFit(self.free, size) orelse return null;
        try self.appendClaim(allocator, label, addr, size, .scratch, benefit);
        return addr;
    }

    // Source eligibility and argument initialization are proved by the backend.
    // This policy layer enforces only scalar width, mode, ownership and capacity.
    pub fn claimParameter(self: *Plan, allocator: std.mem.Allocator, label: []const u8, size: u16, benefit: u64) AllocationError!?u8 {
        if (size != 1 and size != 2) return error.InvalidZeroPageParameterSize;
        if (label.len == 0) return error.InvalidZeroPageRange;
        if (self.find(label) != null) return error.DuplicateZeroPageClaim;
        if (self.allocation != .scalars) return null;
        const addr = firstFit(self.free, size) orelse return null;
        try self.appendClaim(allocator, label, addr, size, .parameter, benefit);
        return addr;
    }

    pub fn allocateScratch(self: *Plan, allocator: std.mem.Allocator, requests: []const Request) AllocationError!void {
        // Reject invalid/duplicate requests before mutating the plan.
        for (requests, 0..) |request, index| {
            if (request.kind != .scratch and request.kind != .parameter) return error.InvalidZeroPageRequestKind;
            if (request.kind == .parameter and request.size != 1 and request.size != 2) return error.InvalidZeroPageParameterSize;
            if (request.size == 0 or request.label.len == 0) return error.InvalidZeroPageRange;
            if (self.find(request.label) != null) return error.DuplicateZeroPageClaim;
            for (requests[0..index]) |prior| if (std.mem.eql(u8, prior.label, request.label)) return error.DuplicateZeroPageClaim;
        }
        const sorted = try allocator.dupe(Request, requests);
        defer allocator.free(sorted);
        std.mem.sort(Request, sorted, {}, struct {
            fn less(_: void, a: Request, b: Request) bool {
                const left = @as(u128, a.benefit) * b.size;
                const right = @as(u128, b.benefit) * a.size;
                if (left != right) return left > right;
                return std.mem.order(u8, a.label, b.label) == .lt;
            }
        }.less);
        for (sorted) |request| {
            if (request.benefit == 0) continue;
            switch (request.kind) {
                .scratch => _ = try self.claimScratch(allocator, request.label, request.size, request.benefit),
                .parameter => _ = try self.claimParameter(allocator, request.label, request.size, request.benefit),
                else => unreachable, // all requests were validated before allocation
            }
        }
    }

    fn appendClaim(self: *Plan, allocator: std.mem.Allocator, label: []const u8, addr: u8, size: u16, kind: ClaimKind, benefit: u64) std.mem.Allocator.Error!void {
        const name = try allocator.dupe(u8, label);
        errdefer allocator.free(name);
        try self.claims.append(allocator, .{ .label = name, .addr = addr, .size = size, .kind = kind, .benefit = benefit });
        for (@as(usize, addr)..@as(usize, addr) + size) |byte| {
            self.free[byte] = false;
            self.owned[byte] = true;
            self.restore[byte] = self.restore_basic and switch (self.profile) {
                .compatibility, .basic => false,
                .kernal => byte >= 2 and byte < 0x90,
                .bare => byte >= 2 and byte < 0xfb,
            };
        }
    }
};

pub fn validate(options: Options, stack: ?StackPairs) Error!void {
    _ = try layout(options, stack);
}

pub fn resolve(allocator: std.mem.Allocator, options: Options, stack: ?StackPairs) (Error || std.mem.Allocator.Error)!Plan {
    const fixed = try layout(options, stack);
    var plan: Plan = .{
        .ptr = fixed.ptr,
        .string_ptr = fixed.string_ptr,
        .candidates = fixed.candidates,
        .free = fixed.free,
        .owned = [_]bool{false} ** 256,
        .restore = [_]bool{false} ** 256,
        .profile = options.profile,
        .allocation = options.allocation,
        .restore_basic = options.restore_basic,
    };
    errdefer plan.deinit(allocator);
    try plan.appendClaim(allocator, "zeropage_ptr_tmp", fixed.ptr, 2, .pointer, 0);
    try plan.appendClaim(allocator, "zeropage_string_ptr", fixed.string_ptr, 2, .string_pointer, 0);
    if (stack) |pairs| {
        try plan.appendClaim(allocator, "zeropage_stack_sp", pairs.sp, 2, .stack_pointer, 0);
        try plan.appendClaim(allocator, "zeropage_stack_fp", pairs.fp, 2, .frame_pointer, 0);
    }
    return plan;
}

const Fixed = struct { candidates: Mask, free: Mask, ptr: u8, string_ptr: u8 };

fn layout(options: Options, stack: ?StackPairs) Error!Fixed {
    if (options.profile == .bare and options.interrupts != .application) return error.InvalidZeroPageInterruptPolicy;
    try validateRanges(options.ranges);
    try validateRanges(options.reserve);
    if (options.ranges_declared and options.ranges.len == 0) return error.InvalidZeroPageRange;
    const explicit = options.ranges_declared or options.ranges.len != 0;
    var candidates: Mask = [_]bool{false} ** 256;
    if (explicit) {
        for (options.ranges) |range| for (range.addr..@as(usize, range.addr) + range.size) |byte| {
            if (!admitted(options.profile, byte)) return error.ProtectedZeroPageRange;
            candidates[byte] = true;
        };
    } else {
        for (2..255) |byte| candidates[byte] = admitted(options.profile, byte);
    }
    var free = candidates;
    var reserved: Mask = [_]bool{false} ** 256;
    for (options.reserve) |range| for (range.addr..@as(usize, range.addr) + range.size) |byte| {
        reserved[byte] = true;
        free[byte] = false;
    };
    if (stack) |pairs| {
        const starts = [_]usize{ pairs.sp, pairs.fp };
        if (pairs.sp < 2 or pairs.fp < 2 or pairs.sp > 0xfd or pairs.fp > 0xfd) return error.ConflictingZeroPageStack;
        if (@as(usize, pairs.sp) < @as(usize, pairs.fp) + 2 and @as(usize, pairs.fp) < @as(usize, pairs.sp) + 2) return error.ConflictingZeroPageStack;
        for (starts) |start| for (start..start + 2) |byte| {
            if (reserved[byte]) return error.ConflictingZeroPageStack;
            if (options.profile == .compatibility and !explicit) {
                // Preserve the old explicitly configured stack convention as
                // well as F7/F9 defaults. It did not share the pointer pairs.
                if (byte >= 0xfb) return error.ConflictingZeroPageStack;
            } else if (!candidates[byte]) return error.ConflictingZeroPageStack;
            free[byte] = false;
        };
    }
    const ptr = preferredPair(&free, 0xfb) orelse return error.ZeroPagePointerSpaceExhausted;
    const string_ptr = preferredPair(&free, 0xfd) orelse return error.ZeroPagePointerSpaceExhausted;
    return .{ .candidates = candidates, .free = free, .ptr = ptr, .string_ptr = string_ptr };
}

fn admitted(profile: Profile, byte: usize) bool {
    if (byte < 2 or byte >= 255) return false;
    return switch (profile) {
        .compatibility, .basic => byte >= 0xfb,
        .kernal => byte < 0x90 or byte >= 0xfb,
        .bare => true,
    };
}

fn validateRanges(ranges: []const Range) Error!void {
    for (ranges, 0..) |range, index| {
        const end = @as(u32, range.addr) + range.size;
        if (range.size == 0 or range.addr < 2 or end > 255) return error.InvalidZeroPageRange;
        for (ranges[0..index]) |prior| {
            if (@as(u32, range.addr) < @as(u32, prior.addr) + prior.size and @as(u32, prior.addr) < end) return error.OverlappingZeroPageRanges;
        }
    }
}

fn firstFit(free: Mask, size: u16) ?u8 {
    if (size == 0 or size > 253) return null;
    var start: usize = 2;
    while (start + size <= 255) : (start += 1) {
        for (free[start .. start + size]) |available| if (!available) break else {} else return @intCast(start);
    }
    return null;
}

fn preferredPair(free: *Mask, preferred: u8) ?u8 {
    const addr = if (free[preferred] and free[@as(usize, preferred) + 1]) preferred else firstFit(free.*, 2) orelse return null;
    free[addr] = false;
    free[@as(usize, addr) + 1] = false;
    return addr;
}

fn count(mask: Mask) usize {
    var n: usize = 0;
    for (mask) |present| n += @intFromBool(present);
    return n;
}

test "omitted policy retains fixed pointers and legacy configured stack pairs" {
    const allocator = std.testing.allocator;
    for ([_]?StackPairs{ null, .{ .sp = 0xf7, .fp = 0xf9 }, .{ .sp = 0x20, .fp = 0x22 } }) |stack| {
        var plan = try resolve(allocator, .{}, stack);
        defer plan.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 0xfb), plan.ptr);
        try std.testing.expectEqual(@as(u8, 0xfd), plan.string_ptr);
        try std.testing.expectEqual(@as(usize, 0), count(plan.free));
        try std.testing.expectEqual(@as(usize, 0), count(plan.restore));
        try std.testing.expectEqual(@as(usize, if (stack != null) 8 else 4), count(plan.owned));
    }
}

test "strict profiles reserve hardware BASIC and KERNAL storage" {
    try std.testing.expectError(error.ProtectedZeroPageRange, validate(.{ .ranges = @constCast(&[_]Range{.{ .addr = 2, .size = 4 }}) }, null));
    try std.testing.expectError(error.ConflictingZeroPageStack, validate(.{ .profile = .basic }, .{ .sp = 0xf7, .fp = 0xf9 }));
    try std.testing.expectError(error.ConflictingZeroPageStack, validate(.{ .profile = .kernal }, .{ .sp = 0xf7, .fp = 0xf9 }));
    try std.testing.expectError(error.InvalidZeroPageInterruptPolicy, validate(.{ .profile = .bare }, null));
    for ([_]Profile{ .basic, .kernal, .bare }) |profile| {
        var plan = try resolve(std.testing.allocator, .{ .profile = profile, .interrupts = if (profile == .bare) .application else .system }, null);
        defer plan.deinit(std.testing.allocator);
        try std.testing.expect(!plan.candidates[0] and !plan.candidates[1] and !plan.candidates[255]);
        if (profile != .bare) try std.testing.expect(!plan.candidates[0x90] and !plan.candidates[0xfa]);
        try std.testing.expectEqual(@as(usize, switch (profile) {
            .basic => 0,
            .kernal => 142,
            .bare => 249,
            else => unreachable,
        }), count(plan.free));
    }
}

test "explicit ranges replace defaults while reserves subtract and relocate pointer pairs" {
    const ranges = [_]Range{ .{ .addr = 0x10, .size = 8 }, .{ .addr = 0xfb, .size = 4 } };
    const reserved = [_]Range{.{ .addr = 0xfb, .size = 4 }};
    var plan = try resolve(std.testing.allocator, .{ .profile = .kernal, .allocation = .scratch, .ranges = @constCast(&ranges), .ranges_declared = true, .reserve = @constCast(&reserved) }, null);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0x10), plan.ptr);
    try std.testing.expectEqual(@as(u8, 0x12), plan.string_ptr);
    try std.testing.expectEqual(@as(usize, 4), count(plan.free));
    try std.testing.expect(!plan.free[2] and !plan.owned[0xfb]);
    try std.testing.expectEqual(@as(?u8, 0x14), try plan.claimScratch(std.testing.allocator, "math", 4, 10));
    try std.testing.expectEqual(@as(usize, 8), count(plan.restore));
    try std.testing.expectEqual(@as(?u8, null), try plan.claimScratch(std.testing.allocator, "spill", 1, 100));
}

test "malformed overlapping protected and empty ranges reject explicitly" {
    for ([_]Range{ .{ .addr = 0, .size = 2 }, .{ .addr = 1, .size = 4 }, .{ .addr = 255, .size = 1 }, .{ .addr = 2, .size = 0 }, .{ .addr = 0xffff, .size = 2 }, .{ .addr = 2, .size = 65535 } }) |bad| {
        var ranges = [_]Range{bad};
        try std.testing.expectError(error.InvalidZeroPageRange, validate(.{ .profile = .kernal, .ranges = &ranges }, null));
    }
    try std.testing.expectError(error.InvalidZeroPageRange, validate(.{ .ranges_declared = true }, null));
    var overlapping = [_]Range{ .{ .addr = 2, .size = 8 }, .{ .addr = 9, .size = 3 } };
    try std.testing.expectError(error.OverlappingZeroPageRanges, validate(.{ .profile = .kernal, .ranges = &overlapping }, null));
    try std.testing.expectError(error.OverlappingZeroPageRanges, validate(.{ .profile = .kernal, .reserve = &overlapping }, null));
    var protected = [_]Range{.{ .addr = 0x8f, .size = 2 }};
    try std.testing.expectError(error.ProtectedZeroPageRange, validate(.{ .profile = .kernal, .ranges = &protected }, null));
    var too_small = [_]Range{.{ .addr = 0xfb, .size = 3 }};
    try std.testing.expectError(error.ZeroPagePointerSpaceExhausted, validate(.{ .profile = .basic, .ranges = &too_small }, null));
}

test "stack claims are disjoint in admitted ranges and retain restore ownership" {
    var plan = try resolve(std.testing.allocator, .{ .profile = .kernal }, .{ .sp = 0x20, .fp = 0x22 });
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(plan.owned[0x20] and plan.restore[0x23] and !plan.free[0x20]);
    try std.testing.expectEqual(@as(usize, 4), count(plan.restore));
    try std.testing.expectError(error.ConflictingZeroPageStack, validate(.{ .profile = .kernal }, .{ .sp = 0x20, .fp = 0x21 }));
    var reserve = [_]Range{.{ .addr = 0x21, .size = 1 }};
    try std.testing.expectError(error.ConflictingZeroPageStack, validate(.{ .profile = .kernal, .reserve = &reserve }, .{ .sp = 0x20, .fp = 0x22 }));
    var moved = try resolve(std.testing.allocator, .{ .profile = .kernal }, .{ .sp = 0xfb, .fp = 0xfd });
    defer moved.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), moved.ptr);
    try std.testing.expectEqual(@as(u8, 4), moved.string_ptr);
}

test "scratch ranking is overflow safe deterministic and spills whole slots" {
    var ranges = [_]Range{ .{ .addr = 2, .size = 5 }, .{ .addr = 0xfb, .size = 4 } };
    var plan = try resolve(std.testing.allocator, .{ .profile = .kernal, .allocation = .scratch, .ranges = &ranges }, null);
    defer plan.deinit(std.testing.allocator);
    try plan.allocateScratch(std.testing.allocator, &.{
        .{ .label = "zword", .size = 2, .benefit = 20 },
        .{ .label = "aword", .size = 2, .benefit = 20 },
        .{ .label = "hot", .size = 1, .benefit = std.math.maxInt(u64) },
        .{ .label = "spill", .size = 2, .benefit = 1 },
        .{ .label = "unused", .size = 1, .benefit = 0 },
    });
    try std.testing.expectEqual(@as(u8, 2), plan.find("hot").?.addr);
    try std.testing.expectEqual(@as(u8, 3), plan.find("aword").?.addr);
    try std.testing.expectEqual(@as(u8, 5), plan.find("zword").?.addr);
    try std.testing.expect(plan.find("spill") == null and plan.find("unused") == null);
    try std.testing.expectEqual(@as(usize, 0), count(plan.free));
    try std.testing.expectError(error.DuplicateZeroPageClaim, plan.claimScratch(std.testing.allocator, "hot", 1, 1));
}

test "fragmented ranges cannot wrap a word across a hole or page end" {
    var ranges = [_]Range{ .{ .addr = 2, .size = 1 }, .{ .addr = 4, .size = 1 }, .{ .addr = 0xfb, .size = 4 } };
    var plan = try resolve(std.testing.allocator, .{ .profile = .kernal, .allocation = .scratch, .ranges = &ranges }, null);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u8, null), try plan.claimScratch(std.testing.allocator, "word", 2, 20));
    try std.testing.expectEqual(@as(?u8, 2), try plan.claimScratch(std.testing.allocator, "byte", 1, 10));
    try std.testing.expectEqual(@as(?u8, 4), try plan.claimScratch(std.testing.allocator, "byte2", 1, 10));
    var end_ranges = [_]Range{.{ .addr = 0xfa, .size = 5 }};
    var end = try resolve(std.testing.allocator, .{ .profile = .bare, .interrupts = .application, .allocation = .scratch, .ranges = &end_ranges }, null);
    defer end.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u8, 0xfa), try end.claimScratch(std.testing.allocator, "last", 1, 1));
    try std.testing.expectEqual(@as(?u8, null), try end.claimScratch(std.testing.allocator, "overflow", 2, 1));
}

test "restoration masks cover owned system bytes and omit free bytes and exclusions" {
    for ([_]bool{ false, true }) |restore_basic| {
        var plan = try resolve(std.testing.allocator, .{ .profile = .bare, .interrupts = .application, .restore_basic = restore_basic, .allocation = .scratch }, null);
        defer plan.deinit(std.testing.allocator);
        _ = try plan.claimScratch(std.testing.allocator, "full_system_pool", 249, 1);
        try std.testing.expectEqual(@as(usize, 0), count(plan.free));
        try std.testing.expectEqual(@as(usize, if (restore_basic) 249 else 0), count(plan.restore));
        if (!restore_basic) try std.testing.expectEqual(@as(usize, 0), count(plan.restore));
        try std.testing.expect(!plan.restore[0xfb] and !plan.restore[0xfe] and !plan.restore[0xff]);
    }
}

test "off leaves scratch in RAM and empty explicit options deinitialize" {
    var plan = try resolve(std.testing.allocator, .{ .profile = .kernal }, null);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u8, null), try plan.claimScratch(std.testing.allocator, "off", 2, 1));
    const options: Options = .{ .ranges = try std.testing.allocator.dupe(Range, &.{.{ .addr = 0xfb, .size = 4 }}), .reserve = try std.testing.allocator.dupe(Range, &.{.{ .addr = 2, .size = 1 }}) };
    defer options.deinit(std.testing.allocator);
    try validate(options, null);
}

test "scalar mode preserves fixed claims and keeps scratch mode parameter requests resident" {
    for ([_]Allocation{ .off, .scratch, .scalars }) |mode| {
        var plan = try resolve(std.testing.allocator, .{ .profile = .kernal, .allocation = mode }, null);
        defer plan.deinit(std.testing.allocator);
        const parameter = try plan.claimParameter(std.testing.allocator, "f_value", 2, 100);
        const scratch = try plan.claimScratch(std.testing.allocator, "temporary", 2, 50);
        try std.testing.expectEqual(@as(u8, 0xfb), plan.ptr);
        try std.testing.expectEqual(@as(u8, 0xfd), plan.string_ptr);
        switch (mode) {
            .off => {
                try std.testing.expect(parameter == null and scratch == null);
                try std.testing.expectEqual(@as(usize, 142), count(plan.free));
            },
            .scratch => {
                try std.testing.expect(parameter == null);
                try std.testing.expectEqual(@as(?u8, 2), scratch);
                try std.testing.expectEqual(@as(usize, 140), count(plan.free));
            },
            .scalars => {
                try std.testing.expectEqual(@as(?u8, 2), parameter);
                try std.testing.expectEqual(@as(?u8, 4), scratch);
                try std.testing.expectEqual(ClaimKind.parameter, plan.find("f_value").?.kind);
                try std.testing.expectEqual(ClaimKind.scratch, plan.find("temporary").?.kind);
                try std.testing.expectEqual(@as(usize, 138), count(plan.free));
            },
        }
        try std.testing.expectEqual(@as(usize, switch (mode) {
            .off => 0,
            .scratch => 2,
            .scalars => 4,
        }), count(plan.restore));
    }
}

test "mixed scalar requests keep benefit per byte ordering and source labels deterministic" {
    var ranges = [_]Range{ .{ .addr = 2, .size = 5 }, .{ .addr = 0xfb, .size = 4 } };
    var plan = try resolve(std.testing.allocator, .{ .profile = .kernal, .allocation = .scalars, .ranges = &ranges }, null);
    defer plan.deinit(std.testing.allocator);
    try plan.allocateScratch(std.testing.allocator, &.{
        .{ .label = "z_parameter", .size = 2, .benefit = 40, .kind = .parameter },
        .{ .label = "a_parameter", .size = 2, .benefit = 40, .kind = .parameter },
        .{ .label = "hot_scratch", .size = 1, .benefit = 25 },
        .{ .label = "spill_parameter", .size = 2, .benefit = 1, .kind = .parameter },
        .{ .label = "unused_parameter", .size = 1, .benefit = 0, .kind = .parameter },
    });
    try std.testing.expectEqual(@as(u8, 2), plan.find("hot_scratch").?.addr);
    try std.testing.expectEqual(@as(u8, 3), plan.find("a_parameter").?.addr);
    try std.testing.expectEqual(@as(u8, 5), plan.find("z_parameter").?.addr);
    try std.testing.expectEqual(ClaimKind.parameter, plan.find("a_parameter").?.kind);
    try std.testing.expect(plan.find("spill_parameter") == null and plan.find("unused_parameter") == null);
    try std.testing.expectEqual(@as(usize, 5), count(plan.restore));
    try std.testing.expectEqual(@as(usize, 9), count(plan.owned));
}

test "invalid fixed request kinds duplicate labels and non scalar widths reject before mutation" {
    for ([_]ClaimKind{ .pointer, .string_pointer, .stack_pointer, .frame_pointer }) |kind| {
        var plan = try resolve(std.testing.allocator, .{ .profile = .kernal, .allocation = .scalars }, null);
        defer plan.deinit(std.testing.allocator);
        const free = plan.free;
        const owned = plan.owned;
        const restore = plan.restore;
        try std.testing.expectError(error.InvalidZeroPageRequestKind, plan.allocateScratch(std.testing.allocator, &.{
            .{ .label = "valid_first", .size = 1, .benefit = 100 },
            .{ .label = "invalid_later", .size = 2, .benefit = 1, .kind = kind },
        }));
        try std.testing.expectEqual(@as(usize, 2), plan.claims.items.len);
        try std.testing.expectEqual(free, plan.free);
        try std.testing.expectEqual(owned, plan.owned);
        try std.testing.expectEqual(restore, plan.restore);
    }
    var plan = try resolve(std.testing.allocator, .{ .profile = .kernal, .allocation = .scalars }, null);
    defer plan.deinit(std.testing.allocator);
    for ([_]u16{ 0, 3, 253, 65535 }) |size| {
        try std.testing.expectError(error.InvalidZeroPageParameterSize, plan.claimParameter(std.testing.allocator, "bad", size, 1));
        try std.testing.expectError(error.InvalidZeroPageParameterSize, plan.allocateScratch(std.testing.allocator, &.{
            .{ .label = "valid_first", .size = 1, .benefit = 100 },
            .{ .label = "bad", .size = size, .benefit = 1, .kind = .parameter },
        }));
    }
    try std.testing.expectError(error.DuplicateZeroPageClaim, plan.allocateScratch(std.testing.allocator, &.{
        .{ .label = "same", .size = 1, .benefit = 100 },
        .{ .label = "same", .size = 1, .benefit = 1, .kind = .parameter },
    }));
    try std.testing.expectError(error.DuplicateZeroPageClaim, plan.claimParameter(std.testing.allocator, "zeropage_ptr_tmp", 2, 1));
    try std.testing.expectEqual(@as(usize, 2), plan.claims.items.len);
    try std.testing.expectEqual(@as(usize, 142), count(plan.free));
}

test "parameter claims respect fragmented capacity BASIC restrictions and fixed stack ownership" {
    var ranges = [_]Range{ .{ .addr = 2, .size = 1 }, .{ .addr = 4, .size = 1 }, .{ .addr = 0xfb, .size = 4 } };
    var fragmented = try resolve(std.testing.allocator, .{ .profile = .kernal, .allocation = .scalars, .ranges = &ranges }, null);
    defer fragmented.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u8, null), try fragmented.claimParameter(std.testing.allocator, "word", 2, 100));
    try std.testing.expectEqual(@as(?u8, 2), try fragmented.claimParameter(std.testing.allocator, "byte", 1, 1));
    try std.testing.expectEqual(@as(?u8, 4), try fragmented.claimScratch(std.testing.allocator, "scratch", 1, 1));
    try std.testing.expectEqual(@as(?u8, null), try fragmented.claimParameter(std.testing.allocator, "full", 1, 1));
    var basic = try resolve(std.testing.allocator, .{ .profile = .basic, .allocation = .scalars }, null);
    defer basic.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u8, null), try basic.claimParameter(std.testing.allocator, "value", 1, 100));
    var stack = try resolve(std.testing.allocator, .{ .profile = .kernal, .allocation = .scalars }, .{ .sp = 2, .fp = 4 });
    defer stack.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u8, 6), try stack.claimParameter(std.testing.allocator, "parameter", 2, 1));
    try std.testing.expectEqual(@as(usize, 6), count(stack.restore));
    try std.testing.expectEqual(@as(usize, 10), count(stack.owned));
}

test "parameter restore masks track actual borrowed bytes independently of initialization policy" {
    for ([_]bool{ false, true }) |restore_basic| {
        var plan = try resolve(std.testing.allocator, .{ .profile = .kernal, .allocation = .scalars, .restore_basic = restore_basic }, null);
        defer plan.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?u8, 2), try plan.claimParameter(std.testing.allocator, "f_word", 2, 1));
        try std.testing.expect(plan.owned[2] and plan.owned[3]);
        try std.testing.expectEqual(restore_basic, plan.restore[2]);
        try std.testing.expectEqual(restore_basic, plan.restore[3]);
        try std.testing.expect(!plan.restore[0xfb] and !plan.restore[0xfd]);
    }
}

test "scratch only mode retains request placements when valid parameter requests are present" {
    var scratch = try resolve(std.testing.allocator, .{ .profile = .kernal, .allocation = .scratch }, null);
    defer scratch.deinit(std.testing.allocator);
    var mixed = try resolve(std.testing.allocator, .{ .profile = .kernal, .allocation = .scratch }, null);
    defer mixed.deinit(std.testing.allocator);
    const requests = [_]Request{
        .{ .label = "low_scratch", .size = 2, .benefit = 1 },
        .{ .label = "hot_scratch", .size = 1, .benefit = 100 },
    };
    try scratch.allocateScratch(std.testing.allocator, &requests);
    try mixed.allocateScratch(std.testing.allocator, &.{
        requests[0],
        .{ .label = "hot_parameter", .size = 2, .benefit = std.math.maxInt(u64), .kind = .parameter },
        requests[1],
    });
    for (requests) |request| {
        try std.testing.expectEqual(scratch.find(request.label).?.addr, mixed.find(request.label).?.addr);
        try std.testing.expectEqual(ClaimKind.scratch, mixed.find(request.label).?.kind);
    }
    try std.testing.expect(mixed.find("hot_parameter") == null);
    try std.testing.expectEqual(scratch.free, mixed.free);
    try std.testing.expectEqual(scratch.restore, mixed.restore);
}

test "mixed scalar claim allocation failures release fixed and partial claims" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var plan = try resolve(allocator, .{ .profile = .kernal, .allocation = .scalars }, .{ .sp = 0x20, .fp = 0x22 });
            defer plan.deinit(allocator);
            try plan.allocateScratch(allocator, &.{
                .{ .label = "scratch", .size = 2, .benefit = 12 },
                .{ .label = "f_value", .size = 2, .benefit = 100, .kind = .parameter },
                .{ .label = "f_flag", .size = 1, .benefit = 10, .kind = .parameter },
            });
            try std.testing.expectEqual(@as(usize, 7), plan.claims.items.len);
            try std.testing.expectEqual(ClaimKind.parameter, plan.find("f_value").?.kind);
        }
    }.run, .{});
}
