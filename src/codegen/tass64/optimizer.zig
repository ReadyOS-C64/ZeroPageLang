const std = @import("std");
const pointer_reuse = @import("pointer_reuse.zig");
const value_cleanup = @import("value_cleanup.zig");
const loop_invariants = @import("loop_invariants.zig");
const loop_ranges = @import("loop_ranges.zig");

pub fn finalizeAssembly(allocator: std.mem.Allocator, assembly: []u8) ![]u8 {
    return finalizeAssemblyWithOptions(allocator, assembly, .{});
}

pub const Options = struct { reuse_pointer_bases: bool = false, cleanup_values: bool = false, hoist_loop_pointers: bool = false, reduce_loop_ranges: bool = false };

pub fn finalizeAssemblyWithOptions(allocator: std.mem.Allocator, assembly: []u8, options: Options) ![]u8 {
    const loops = if (options.hoist_loop_pointers) try loop_invariants.optimize(allocator, assembly) else null;
    defer if (loops) |text| allocator.free(text);
    const ranges = if (options.reduce_loop_ranges) try loop_ranges.optimize(allocator, loops orelse assembly) else null;
    defer if (ranges) |text| allocator.free(text);
    const selected = if (options.reuse_pointer_bases) try pointer_reuse.optimize(allocator, ranges orelse loops orelse assembly) else null;
    defer if (selected) |text| allocator.free(text);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var previous_significant: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, selected orelse ranges orelse loops orelse assembly, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            try out.writer.writeByte('\n');
            previous_significant = null;
            continue;
        }

        if (isPeepholeBoundary(trimmed)) {
            try out.writer.print("{s}\n", .{line});
            previous_significant = trimmed;
            continue;
        }

        if (previous_significant) |previous| {
            if (isRedundantDuplicateLoad(previous, trimmed) or isRedundantTransferPair(previous, trimmed)) {
                continue;
            }
        }

        try out.writer.print("{s}\n", .{line});
        previous_significant = trimmed;
    }

    const adjacent = try out.toOwnedSlice();
    errdefer allocator.free(adjacent);
    const result = if (options.cleanup_values) try value_cleanup.optimize(allocator, adjacent) else adjacent;
    if (options.cleanup_values) allocator.free(adjacent);
    allocator.free(assembly);
    return result;
}

fn isPeepholeBoundary(trimmed: []const u8) bool {
    if (trimmed[0] == ';') return true;
    if (std.mem.endsWith(u8, trimmed, ":")) return true;
    if (std.mem.startsWith(u8, trimmed, ".")) return true;
    if (std.mem.startsWith(u8, trimmed, "*")) return true;
    return false;
}

fn isSimpleLoad(trimmed: []const u8) bool {
    if (!(std.mem.startsWith(u8, trimmed, "lda ") or std.mem.startsWith(u8, trimmed, "ldx "))) return false;
    const operand = trimmed[4..];
    if (operand.len == 0) return false;
    if (operand[0] == '(') return false;
    if (std.mem.indexOfScalar(u8, operand, ',') != null) return false;
    if (operand.len >= 2 and operand[0] == '$' and std.ascii.toLower(operand[1]) == 'd') return false;
    return true;
}

fn isRedundantDuplicateLoad(previous: []const u8, current: []const u8) bool {
    return std.mem.eql(u8, previous, current) and isSimpleLoad(current);
}

fn isRedundantTransferPair(previous: []const u8, current: []const u8) bool {
    return (std.mem.eql(u8, previous, "tax") and std.mem.eql(u8, current, "txa")) or
        (std.mem.eql(u8, previous, "txa") and std.mem.eql(u8, current, "tax")) or
        (std.mem.eql(u8, previous, "tay") and std.mem.eql(u8, current, "tya")) or
        (std.mem.eql(u8, previous, "tya") and std.mem.eql(u8, current, "tay"));
}

test "removes adjacent duplicate simple loads" {
    const input = try std.testing.allocator.dupe(u8,
        \\main:
        \\    lda main_value
        \\    lda main_value
        \\    ldx #0
        \\    ldx #0
        \\
    );
    const optimized = try finalizeAssembly(std.testing.allocator, input);
    defer std.testing.allocator.free(optimized);

    try std.testing.expect(std.mem.indexOf(u8, optimized, "lda main_value\n    lda main_value") == null);
    try std.testing.expect(std.mem.indexOf(u8, optimized, "ldx #0\n    ldx #0") == null);
}

test "does not remove loads across labels or volatile-shaped operands" {
    const input = try std.testing.allocator.dupe(u8,
        \\main:
        \\    lda main_value
        \\next:
        \\    lda main_value
        \\    lda (zeropage_ptr_tmp),y
        \\    lda (zeropage_ptr_tmp),y
        \\    lda $d012
        \\    lda $d012
        \\
    );
    const optimized = try finalizeAssembly(std.testing.allocator, input);
    defer std.testing.allocator.free(optimized);

    try std.testing.expect(std.mem.indexOf(u8, optimized, "lda main_value\nnext:\n    lda main_value") != null);
    try std.testing.expect(std.mem.indexOf(u8, optimized, "lda (zeropage_ptr_tmp),y\n    lda (zeropage_ptr_tmp),y") != null);
    try std.testing.expect(std.mem.indexOf(u8, optimized, "lda $d012\n    lda $d012") != null);
}

test "collapses adjacent inverse transfer pairs" {
    const input = try std.testing.allocator.dupe(u8,
        \\main:
        \\    tax
        \\    txa
        \\    tay
        \\    tya
        \\
    );
    const optimized = try finalizeAssembly(std.testing.allocator, input);
    defer std.testing.allocator.free(optimized);

    try std.testing.expect(std.mem.indexOf(u8, optimized, "tax\n    txa") == null);
    try std.testing.expect(std.mem.indexOf(u8, optimized, "tay\n    tya") == null);
}
