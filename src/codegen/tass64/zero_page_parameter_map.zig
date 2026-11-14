const std = @import("std");
const ast = @import("../../ast.zig");
const policy = @import("../../zero_page.zig");
const scalars = @import("zero_page_scalars.zig");

pub const Status = enum { allocated, spilled, excluded };
pub const Marker = struct {
    label: []const u8,
    size: u16,
    reason: scalars.Reason,
    status: Status,
};

/// Recheck source identity, scalar width and source/call-graph ownership after
/// allocation. Synthetic facts describe only declared scalar parameters; they
/// DO NOT prove the shape/indexing of the original, now-removed frame storage.
/// Those facts remain the late assembly producer's responsibility. Physical
/// address/capacity agreement is separately checked by the map's policy replay.
pub fn validate(allocator: std.mem.Allocator, program: ast.Program, claims: []const policy.Claim, markers: []const Marker) !void {
    if (program.zeropage_options.zero_page.allocation != .scalars) return error.InvalidZeroPageClaimMap;
    const declared = try scalars.classifyParameters(allocator, program, &.{});
    defer scalars.freeDecisions(allocator, declared);
    var facts: std.ArrayList(scalars.StorageFact) = .empty;
    defer facts.deinit(allocator);
    for (declared) |decision| if (decision.size == 1 or decision.size == 2) {
        try facts.append(allocator, .{
            .label = decision.label,
            .owner = decision.function_name,
            .size = decision.size,
            .zero_initialized = true,
        });
    };
    const source = try scalars.classifyParameters(allocator, program, facts.items);
    defer scalars.freeDecisions(allocator, source);
    if (markers.len != source.len) return error.InvalidZeroPageClaimMap;
    for (markers, 0..) |marker, index| {
        for (markers[0..index]) |prior| if (std.mem.eql(u8, prior.label, marker.label)) return error.InvalidZeroPageClaimMap;
        if (findDecision(source, marker.label) == null) return error.InvalidZeroPageClaimMap;
    }
    for (claims, 0..) |claim, index| {
        for (claims[0..index]) |prior| if (std.mem.eql(u8, prior.label, claim.label)) return error.InvalidZeroPageClaimMap;
        if (claim.kind != .parameter) continue;
        if (claim.size != 1 and claim.size != 2) return error.InvalidZeroPageClaimMap;
        const decision = findDecision(source, claim.label) orelse return error.InvalidZeroPageClaimMap;
        if (!decision.eligible() or decision.size != claim.size) return error.InvalidZeroPageClaimMap;
    }
    for (source) |decision| {
        // Unique equal cardinality and known labels above guarantee a marker.
        const marker = findMarker(markers, decision.label) orelse return error.InvalidZeroPageClaimMap;
        if (marker.size != decision.size) return error.InvalidZeroPageClaimMap;
        const claim = findClaim(claims, decision.label);
        if (claim) |actual| {
            if (actual.kind != .parameter or actual.size != decision.size) return error.InvalidZeroPageClaimMap;
        }
        if (!decision.eligible()) {
            // The real extractor can reject storage before classifyStorage's
            // AST &slot check. Clean synthetic facts must not erase that valid
            // earlier exclusion. A retained layout observer likewise overrides
            // only otherwise eligible cells, after real storage exclusions.
            // Other graph/owner/type reasons still match exactly.
            const same_reason = marker.reason == decision.reason or
                (decision.reason == .address_escape and precedesSourceEscape(marker.reason)) or
                ((decision.reason == .layout_observer or decision.reason == .unproven_memory_domain) and storageReason(marker.reason));
            if (!same_reason or marker.status != .excluded or claim != null) return error.InvalidZeroPageClaimMap;
        } else if (marker.reason == .eligible) {
            const expected: Status = if (claim != null) .allocated else .spilled;
            if (marker.status != expected) return error.InvalidZeroPageClaimMap;
        } else {
            if (!storageReason(marker.reason) or marker.status != .excluded or claim != null) return error.InvalidZeroPageClaimMap;
        }
    }
}

fn precedesSourceEscape(reason: scalars.Reason) bool {
    return switch (reason) {
        .missing_definition, .duplicate_definition, .owner_mismatch, .layout, .aliased, .indexed => true,
        else => false,
    };
}

fn storageReason(reason: scalars.Reason) bool {
    return switch (reason) {
        .missing_definition, .duplicate_definition, .owner_mismatch, .layout, .aliased, .indexed, .address_escape, .assembly_sensitive => true,
        else => false,
    };
}
fn findDecision(decisions: []const scalars.Decision, label: []const u8) ?scalars.Decision {
    for (decisions) |decision| if (std.mem.eql(u8, decision.label, label)) return decision;
    return null;
}
fn findMarker(markers: []const Marker, label: []const u8) ?Marker {
    for (markers) |marker| if (std.mem.eql(u8, marker.label, label)) return marker;
    return null;
}
fn findClaim(claims: []const policy.Claim, label: []const u8) ?policy.Claim {
    for (claims) |claim| if (std.mem.eql(u8, claim.label, label)) return claim;
    return null;
}

const test_source =
    \\pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scalars } };
    \\fn leaf(value: u16) u16 { return value; }
    \\fn middle(value: u8) u16 { return leaf(value); }
    \\export fn public(value: u8) u8 { return value; }
    \\export fn main() void { _ = middle(7); }
;
const test_claims = [_]policy.Claim{.{ .label = "leaf_value", .addr = 2, .size = 2, .kind = .parameter }};
const test_markers = [_]Marker{
    .{ .label = "leaf_value", .size = 2, .reason = .eligible, .status = .allocated },
    .{ .label = "middle_value", .size = 1, .reason = .eligible, .status = .spilled },
    .{ .label = "public_value", .size = 1, .reason = .exported, .status = .excluded },
};

test "parameter map validates typed private allocation spill and exported exclusions" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, test_source);
    defer parsed.deinit(std.testing.allocator);
    try validate(std.testing.allocator, parsed.program, &test_claims, &test_markers);
    var markers = test_markers;
    for ([_]scalars.Reason{ .missing_definition, .duplicate_definition, .owner_mismatch, .layout, .aliased, .indexed, .address_escape, .assembly_sensitive }) |reason| {
        markers[1].reason = reason;
        markers[1].status = .excluded;
        try validate(std.testing.allocator, parsed.program, &test_claims, &markers);
    }
}

test "parameter map rejects phantom duplicate missing width and status markers" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, test_source);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &test_claims, test_markers[0..2]));
    var markers = test_markers;
    markers[1].label = "phantom_value";
    try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &test_claims, &markers));
    markers = test_markers;
    markers[1] = markers[0];
    try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &test_claims, &markers));
    markers = test_markers;
    markers[0].size = 1;
    try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &test_claims, &markers));
    markers = test_markers;
    markers[1].status = .allocated;
    try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &test_claims, &markers));
    markers = test_markers;
    markers[0].status = .spilled;
    try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &test_claims, &markers));
}

test "parameter map rejects public phantom bad width and duplicate claims" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, test_source);
    defer parsed.deinit(std.testing.allocator);
    var claims = test_claims;
    for ([_][]const u8{ "public_value", "phantom_value" }) |label| {
        claims[0].label = label;
        claims[0].size = 1;
        try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &claims, &test_markers));
    }
    for ([_]u16{ 0, 1, 3 }) |size| {
        claims = test_claims;
        claims[0].size = size;
        try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &claims, &test_markers));
    }
    try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &.{ test_claims[0], test_claims[0] }, &test_markers));
    claims = test_claims;
    claims[0].kind = .scratch;
    try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &claims, &test_markers));
    var markers = test_markers;
    markers[2].reason = .layout;
    try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &test_claims, &markers));
    markers = test_markers;
    markers[1].reason = .not_retained;
    markers[1].status = .excluded;
    try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &test_claims, &markers));
}

test "parameter map rechecks source slot escapes recursive SCC and unretained owners" {
    const parser = @import("../../parser.zig");
    const source =
        \\pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scalars } };
        \\fn escape(value: u8) u8 { _ = &value; return value; }
        \\fn cycle(value: u8) u8 { if (value == 0) { return value; } return cycle(value-1); }
        \\fn unused(value: u8) u8 { return value; }
        \\export fn main() void { _ = escape(1); _ = cycle(1); }
    ;
    const parsed = try parser.parseSource(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);
    const good = [_]Marker{
        .{ .label = "escape_value", .size = 1, .reason = .address_escape, .status = .excluded },
        .{ .label = "cycle_value", .size = 1, .reason = .recursive, .status = .excluded },
        .{ .label = "unused_value", .size = 1, .reason = .not_retained, .status = .excluded },
    };
    try validate(std.testing.allocator, parsed.program, &.{}, &good);
    for (good, 0..) |marker, index| {
        var bad = good;
        bad[index].reason = .eligible;
        bad[index].status = .allocated;
        const claim: policy.Claim = .{ .label = marker.label, .addr = 2, .size = 1, .kind = .parameter };
        try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &.{claim}, &bad));
    }
    var bad = good;
    bad[0].reason = .indexed;
    try validate(std.testing.allocator, parsed.program, &.{}, &bad);
    // A colocated alias fact is checked before the source &slot expression;
    // its legitimate excluded marker must survive synthetic clean facts.
    bad[0].reason = .aliased;
    try validate(std.testing.allocator, parsed.program, &.{}, &bad);
    bad[0].reason = .assembly_sensitive;
    try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &.{}, &bad));
    var wrong_mode = parsed.program;
    wrong_mode.zeropage_options.zero_page.allocation = .scratch;
    try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, wrong_mode, &.{}, &good));
}

fn allocationFailureCase(allocator: std.mem.Allocator, program: ast.Program) !void {
    try validate(allocator, program, &test_claims, &test_markers);
}
test "parameter map releases partial graph facts and decisions on every allocation failure" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, test_source);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureCase, .{parsed.program});
}

const layout_observer_source =
    \\pub const zeropage_options = .{ .zero_page = .{ .profile = .kernal, .allocation = .scalars } };
    \\fn leaf(value: u8) u8 { return value; }
    \\fn observe() u16 { var neighbor: u8 = 0; return @intFromPtr(&neighbor); }
    \\export fn main() void { _ = leaf(7); _ = observe(); }
;

test "parameter map rejects allocations with retained layout observers" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, layout_observer_source);
    defer parsed.deinit(std.testing.allocator);
    const claims = [_]policy.Claim{.{ .label = "leaf_value", .addr = 2, .size = 1, .kind = .parameter }};
    const markers = [_]Marker{.{ .label = "leaf_value", .size = 1, .reason = .eligible, .status = .allocated }};
    try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &claims, &markers));
}

test "parameter map retains earlier storage exclusions under a layout observer" {
    const parser = @import("../../parser.zig");
    const parsed = try parser.parseSource(std.testing.allocator, layout_observer_source);
    defer parsed.deinit(std.testing.allocator);
    const reason = std.meta.stringToEnum(scalars.Reason, "layout_observer") orelse return error.MissingLayoutObserverReason;
    var markers = [_]Marker{.{ .label = "leaf_value", .size = 1, .reason = reason, .status = .excluded }};
    try validate(std.testing.allocator, parsed.program, &.{}, &markers);
    // These facts belonged to the real pre-relocation producer. Clean facts in
    // semantic replay must not erase a stronger, earlier storage exclusion.
    for ([_]scalars.Reason{ .missing_definition, .duplicate_definition, .owner_mismatch, .layout, .aliased, .indexed, .address_escape, .assembly_sensitive }) |earlier| {
        markers[0].reason = earlier;
        try validate(std.testing.allocator, parsed.program, &.{}, &markers);
    }
    markers[0].reason = .entry;
    try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &.{}, &markers));
    markers[0].reason = .eligible;
    markers[0].status = .spilled;
    try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &.{}, &markers));
    markers[0].reason = reason;
    markers[0].status = .allocated;
    try std.testing.expectError(error.InvalidZeroPageClaimMap, validate(std.testing.allocator, parsed.program, &.{}, &markers));
}
