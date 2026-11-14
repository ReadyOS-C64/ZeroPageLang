// Standalone native-QA generator, not a compiler entry point:
// zig run src/cfg_probe.zig -- build/cfg-probe-agent/graphs
const std = @import("std");
const cfg = @import("codegen/tass64/cfg_dead_values.zig");

const Oracle = struct { addr: u16, expected_constant: u8 };
const Case = struct {
    name: []const u8,
    body: []const u8,
    expected_removed: usize,
    features: []const []const u8,
    leaf: ?[]const u8 = null,
    oracles: []const Oracle = &.{},
};
const cases = [_]Case{
    .{ .name = "dead_a_nz", .body = "    lda #0\n    lda input\n    rts\n", .expected_removed = 1, .features = &.{ "dead_A_NZ", "memory_read_retained" } },
    .{ .name = "dead_x_nz", .body = "    ldx #0\n    ldx input\n    rts\n", .expected_removed = 1, .features = &.{"dead_X_NZ"} },
    .{ .name = "dead_y_nz", .body = "    ldy #0\n    ldy input\n    rts\n", .expected_removed = 1, .features = &.{"dead_Y_NZ"} },
    .{ .name = "mixed_dead_registers", .body = "    lda #0\n    ldx #1\n    ldy #2\n    lda input\n    ldx input2\n    ldy scratch\n    rts\n", .expected_removed = 3, .features = &.{ "dead_A_X_Y_NZ", "partial_flag_kills" } },
    .{ .name = "diamond_both_kill", .body = "    lda #0\n    ldx input\n    beq left\n    lda input2\n    jmp done\nleft:\n    lda scratch\ndone:\n    rts\n", .expected_removed = 1, .features = &.{ "diamond_both_dead", "branch_Z_killed_before_read" } },
    .{ .name = "diamond_one_live", .body = "    lda #0\n    ldx input\n    beq left\n    lda input2\n    jmp done\nleft:\n    sta result\ndone:\n    rts\n", .expected_removed = 0, .features = &.{ "diamond_one_live", "store_observes_A" } },
    .{ .name = "shared_suffix", .body = "    lda #0\n    ldx input\n    beq left\n    nop\n    jmp join\nleft:\n    nop\njoin:\n    lda input2\n    rts\n", .expected_removed = 1, .features = &.{ "shared_join", "memoized_dead_suffix" } },
    .{ .name = "unwritten_v_branch", .body = "    lda #0\n    ldx input\n    bvs left\n    lda input2\n    jmp done\nleft:\n    lda scratch\ndone:\n    rts\n", .expected_removed = 1, .features = &.{ "V_preserved", "V_branch_not_written_by_candidate", "D_I_preserved" } },
    .{ .name = "live_z_branch", .body = "    lda #0\n    beq zero\n    sta result\nzero:\n    rts\n", .expected_removed = 0, .features = &.{ "Z_read_before_kill", "final_A_NZ_live" } },
    .{ .name = "live_n_branch", .body = "    lda #128\n    bmi negative\n    sta result\nnegative:\n    rts\n", .expected_removed = 0, .features = &.{ "N_read_before_kill", "final_A_NZ_live" } },
    .{ .name = "live_c_branch", .body = "    sec\n    bcc left\n    lda input\n    jmp done\nleft:\n    lda input2\ndone:\n    rts\n", .expected_removed = 0, .features = &.{"C_branch_read_before_kill"} },
    .{ .name = "carry_dead_both_paths", .body = "    sec\n    ldx input\n    beq left\n    clc\n    jmp done\nleft:\n    clc\ndone:\n    rts\n", .expected_removed = 1, .features = &.{ "C_dead_both_successors", "final_C_live" } },
    .{ .name = "carry_adc_decimal", .body = "    sec\n    clc\n    adc input\n    rts\n", .expected_removed = 1, .features = &.{ "dead_C", "ADC_reads_C_A_D", "decimal_boundary_data" } },
    .{ .name = "carry_rmw_live", .body = "    sec\n    ror input\n    clc\n    rts\n", .expected_removed = 0, .features = &.{ "RMW_reads_C", "RMW_memory_retained" } },
    .{ .name = "php_flags_live", .body = "    lda #0\n    php\n    pla\n    lda input\n    rts\n", .expected_removed = 0, .features = &.{ "PHP_observes_N_Z", "stack_instructions_retained" } },
    .{ .name = "bit_a_live", .body = "    lda #0\n    bit input\n    lda input2\n    rts\n", .expected_removed = 0, .features = &.{ "BIT_reads_A_before_NZ_kill", "BIT_V_retained" } },
    .{ .name = "bit_index_dead", .body = "    ldx #0\n    bit input\n    ldx input2\n    rts\n", .expected_removed = 1, .features = &.{ "BIT_kills_NZ_not_X", "BIT_reads_seed_A", "V_preserved_from_BIT" } },
    .{ .name = "rmw_dead_a", .body = "    lda #0\n    inc input\n    lda input2\n    rts\n", .expected_removed = 1, .features = &.{ "RMW_kills_NZ", "RMW_memory_retained" } },
    .{ .name = "index_x_live", .body = "    ldx #3\n    lda table,x\n    ldx input\n    rts\n", .expected_removed = 0, .features = &.{ "indexed_X_read", "indexed_memory_retained" } },
    .{ .name = "index_y_live", .body = "    ldy #3\n    lda (pointer),y\n    ldy input\n    rts\n", .expected_removed = 0, .features = &.{ "indirect_Y_read", "pointer_zero_page_unchanged" } },
    .{ .name = "partial_index_dead", .body = "    ldx #3\n    lda input\n    sta result\n    ldx input2\n    rts\n", .expected_removed = 1, .features = &.{ "NZ_killed_before_X", "unrelated_A_store_retained" } },
    .{ .name = "boolean_false_cleanup", .body = "    lda #0\n    sec\n    jmp false\nfalse:\n    lda #0\n    sec\n    rts\n", .expected_removed = 2, .features = &.{ "R23_false_materialization", "dead_A_NZ_C", "final_A_NZ_C_live" } },
    .{ .name = "loop_cycle_barrier", .body = "    lda #0\nloop:\n    dex\n    bne loop\n    lda input\n    rts\n", .expected_removed = 0, .features = &.{ "finite_DEX_loop", "cycle_with_A_live", "seed_X_zero_means_256_iterations" } },
    .{ .name = "call_all_live", .body = "    lda #0\n    jsr leaf\n    lda input\n    rts\n", .expected_removed = 0, .features = &.{ "JSR_all_CPU_state_live", "fixed_leaf_origin", "unchanged_call_target" }, .leaf = "    ldx #7\n    ldy #9\n    lda #11\n    rts\n" },
    .{ .name = "return_all_live", .body = "    lda #0\n    rts\n    lda #7\n    rts\n", .expected_removed = 0, .features = &.{ "RTS_all_CPU_state_live", "unreachable_tail_not_deleted" } },
    .{ .name = "unknown_nop_barrier", .body = "    lda #0\n    .byte $ea\n    lda input\n    rts\n", .expected_removed = 0, .features = &.{ "unknown_directive_barrier", "actual_NOP_executes" } },
    .{ .name = "computed_jump_barrier", .body = "    lda #0\n    jmp target+1\ntarget:\n    .byte $ea\n    lda input\n    rts\n", .expected_removed = 0, .features = &.{ "nonzero_target_offset_barrier", "actual_target_skips_NOP" } },
    .{ .name = "section_jump_barrier", .body = "    lda #0\n    jmp leaf\n", .expected_removed = 0, .features = &.{ "cross_section_JMP_barrier", "fixed_leaf_origin" }, .leaf = "    lda input\n    rts\n" },
    .{ .name = "mode_barrier", .body = "    lda #0\n    sed\n    sei\n    lda input\n    rts\n", .expected_removed = 0, .features = &.{ "D_I_mode_barrier", "D_I_final_flags" } },
    .{ .name = "global_asm_barrier", .body = "    lda #0\n    lda input\n; inline asm from ZeroPage line 1\n    nop\n; end inline asm\n    rts\n", .expected_removed = 0, .features = &.{ "global_retained_ASM_barrier", "otherwise_dead_A_NZ" } },
    .{ .name = "volatile_reads_retained", .body = "    lda #0\n    lda $dc04\n    sta result\n    lda $dc04\n    sta result2\n    lda $dc04\n    sta result3\n    lda #7\n    rts\n", .expected_removed = 1, .features = &.{ "three_stateful_MMIO_reads", "ordered_results_1_2_3", "final_read_value_overwritten" }, .oracles = &.{ .{ .addr = 0xc200, .expected_constant = 1 }, .{ .addr = 0xc201, .expected_constant = 2 }, .{ .addr = 0xc202, .expected_constant = 3 } } },
    .{ .name = "volatile_overwritten_xy", .body = "    ldx $dc04\n    ldx #0\n    ldy $dc04\n    ldy #0\n    lda $dc04\n    sta result3\n    rts\n", .expected_removed = 0, .features = &.{ "volatile_X_Y_reads_retained", "loaded_X_Y_values_overwritten", "third_device_read_is_3", "final_X_Y_zero_live" }, .oracles = &.{.{ .addr = 0xc202, .expected_constant = 3 }} },
};

const Metadata = struct {
    name: []const u8,
    before_asm: []const u8,
    after_asm: []const u8,
    entry: []const u8 = "probe_entry",
    entry_addr: u16 = 0x2000,
    expected_changed: bool,
    expected_removed: usize,
    stats: cfg.Stats,
    features: []const []const u8,
    oracles: []const Oracle,
};

fn sourceHash(comptime source: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}
fn assembly(allocator: std.mem.Allocator, case: Case) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(
        \\; generated by cfg_probe using the actual CFG optimizer
        \\* = $2000
        \\input = $c100
        \\input2 = $c101
        \\scratch = $c102
        \\result = $c200
        \\result2 = $c201
        \\result3 = $c202
        \\table = $c300
        \\pointer = $fb
        \\; zeropage_section_begin owner=function:probe kind=code lifetime=static address=near
        \\probe_entry:
        \\
    );
    try out.writer.writeAll(case.body);
    try out.writer.writeAll("; zeropage_section_end owner=function:probe kind=code\n");
    if (case.leaf) |leaf| {
        try out.writer.writeAll("* = $2800\n; zeropage_section_begin owner=function:leaf kind=code lifetime=static address=near\nleaf:\n");
        try out.writer.writeAll(leaf);
        try out.writer.writeAll("; zeropage_section_end owner=function:leaf kind=code\n");
    }
    return out.toOwnedSlice();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    defer arguments.deinit();
    _ = arguments.next();
    const output_dir = arguments.next() orelse "build/cfg-probe-agent/graphs";
    if (arguments.next() != null) return error.TooManyArguments;
    try std.Io.Dir.cwd().createDirPath(init.io, output_dir);
    var metadata: std.ArrayList(Metadata) = .empty;
    defer {
        for (metadata.items) |row| {
            allocator.free(row.before_asm);
            allocator.free(row.after_asm);
        }
        metadata.deinit(allocator);
    }
    for (cases) |case| {
        const before = try assembly(allocator, case);
        defer allocator.free(before);
        const after = try cfg.rewrite(allocator, before);
        defer allocator.free(after.assembly);
        if (after.stats.removed != case.expected_removed) {
            std.debug.print("{s}: expected {d} removals, found {d}\n", .{ case.name, case.expected_removed, after.stats.removed });
            return error.UnexpectedGraphSelection;
        }
        const before_path = try std.fmt.allocPrint(allocator, "{s}/{s}-before.asm", .{ output_dir, case.name });
        errdefer allocator.free(before_path);
        const after_path = try std.fmt.allocPrint(allocator, "{s}/{s}-after.asm", .{ output_dir, case.name });
        errdefer allocator.free(after_path);
        try writeFile(init.io, before_path, before);
        try writeFile(init.io, after_path, after.assembly);
        try metadata.append(allocator, .{
            .name = case.name,
            .before_asm = before_path,
            .after_asm = after_path,
            .expected_changed = case.expected_removed != 0,
            .expected_removed = case.expected_removed,
            .stats = after.stats,
            .features = case.features,
            .oracles = case.oracles,
        });
    }
    const pass_hash = sourceHash(@embedFile("codegen/tass64/cfg_dead_values.zig"));
    const instruction_hash = sourceHash(@embedFile("codegen/tass64/instruction.zig"));
    const generator_hash = sourceHash(@embedFile("cfg_probe.zig"));
    const manifest = try std.json.Stringify.valueAlloc(allocator, .{
        .format = "zeropage-cfg-native-graphs-v1",
        .pass_source_sha256 = pass_hash[0..],
        .instruction_source_sha256 = instruction_hash[0..],
        .generator_source_sha256 = generator_hash[0..],
        .data = .{ .input = @as(u16, 0xc100), .input2 = @as(u16, 0xc101), .scratch = @as(u16, 0xc102), .result = @as(u16, 0xc200), .result2 = @as(u16, 0xc201), .result3 = @as(u16, 0xc202), .table = @as(u16, 0xc300), .pointer = @as(u16, 0xfb) },
        .cycle_scope = "Native CPU before final top-level RTS; compare complete A/X/Y/P/SP and RAM, not PC or code bytes.",
        .cases = metadata.items,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(manifest);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{output_dir});
    defer allocator.free(manifest_path);
    try writeFile(init.io, manifest_path, manifest);
    var buffer: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print("Generated {d} CFG graph pairs: {s}\n", .{ cases.len, manifest_path });
    try stdout.interface.flush();
}

test "CFG probe graph inventory agrees with the actual pass" {
    for (cases) |case| {
        const before = try assembly(std.testing.allocator, case);
        defer std.testing.allocator.free(before);
        const after = try cfg.rewrite(std.testing.allocator, before);
        defer std.testing.allocator.free(after.assembly);
        try std.testing.expectEqual(case.expected_removed, after.stats.removed);
        if (case.expected_removed == 0) try std.testing.expectEqualStrings(before, after.assembly);
    }
}
