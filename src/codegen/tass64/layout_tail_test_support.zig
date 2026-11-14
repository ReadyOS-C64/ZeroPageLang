// Test-only composition of the current post-allocation layout tail. Earlier
// optimization tests retain their independent phase-only instruction proofs.
const std = @import("std");
const ast = @import("../../ast.zig");
const dead_code = @import("unreachable_code.zig");
const branches = @import("short_branches.zig");
const local_folds = @import("local_folds.zig");
const compare_zero = @import("compare_zero.zig");
const counted_latch = @import("counted_latch.zig");
const boolean_call_not = @import("boolean_call_not.zig");
const boolean_not_branch = @import("boolean_not_branch.zig");
const word_high_load = @import("word_high_load.zig");
const word_rotate = @import("word_rotate.zig");
pub fn finish(a: std.mem.Allocator, program: ast.Program, assembly: []const u8) ![]u8 {
    if (program.zeropage_module != null or program.zeropage_options.modules != null or program.zeropage_options.memory.placements.len != 0) return a.dupe(u8, assembly);
    const cleaned = try dead_code.rewriteProgram(a, assembly, program);
    defer a.free(cleaned.assembly);
    var current = (try branches.rewrite(a, cleaned.assembly)).assembly;
    errdefer a.free(current);
    if (try local_folds.rewrite(a, program, current)) |folded| {
        a.free(current);
        current = folded;
    }
    if (try compare_zero.rewrite(a, program, current)) |folded| {
        a.free(current);
        current = folded;
    }
    if (try counted_latch.rewrite(a, program, current)) |folded| {
        a.free(current);
        current = folded;
    }
    if (try boolean_call_not.rewrite(a, program, current)) |folded| {
        a.free(current);
        current = folded;
    }
    if (try boolean_not_branch.rewrite(a, program, current)) |folded| {
        a.free(current);
        current = folded;
    }
    if (try word_high_load.rewrite(a, program, current)) |folded| {
        a.free(current);
        current = folded;
    }
    if (try word_rotate.rewrite(a, program, current)) |folded| {
        a.free(current);
        current = folded;
    }
    return current;
}
