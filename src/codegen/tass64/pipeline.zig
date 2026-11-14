const std = @import("std");
const ast = @import("../../ast.zig");
const emitter = @import("emitter.zig");
const module_sidecars = @import("module_sidecars.zig");
const static_facts = @import("static_local_facts.zig");
const optimizer = @import("optimizer.zig");
const reachability = @import("reachability.zig");
const zero_page_allocation = @import("zero_page_allocation.zig");
const call_argument_rewrite = @import("call_argument_rewrite.zig");
const boolean_materialization = @import("boolean_materialization.zig");
const cfg_dead_values = @import("cfg_dead_values.zig");
const dead_call_storage = @import("dead_call_storage.zig");
const dead_call_writes = @import("dead_call_writes.zig");
const x_value_forwarding = @import("x_value_forwarding.zig");
const branch_a_forwarding = @import("branch_a_forwarding.zig");
const word_zero_compare = @import("word_zero_compare_rewrite.zig");
const pointer_add = @import("pointer_add_forwarding.zig");
const zero_values = @import("zero_test_values.zig");
const short_branches = @import("short_branches.zig");
const frame_layout = @import("frame_layout.zig");
const placement_domains = @import("placement_domains.zig");
const unreachable_code = @import("unreachable_code.zig");
const literal_increment = @import("literal_increment.zig");
const static_copy_span = @import("static_copy_span.zig");
const stream_copy = @import("stream_copy.zig");
const wide_index = @import("wide_index.zig");
const page_range = @import("page_range.zig");
const literal_pointer_io = @import("literal_pointer_io.zig");
const affine_reduction = @import("affine_reduction.zig");
const leaf_coalescing = @import("leaf_coalescing.zig");
const masked_multiply = @import("masked_multiply.zig");
const local_folds = @import("local_folds.zig");
const counted_copy = @import("counted_copy.zig");
const compare_zero = @import("compare_zero.zig");
const counted_latch = @import("counted_latch.zig");
const boolean_call_not = @import("boolean_call_not.zig");
const boolean_not_branch = @import("boolean_not_branch.zig");
const word_high_load = @import("word_high_load.zig");
const word_rotate = @import("word_rotate.zig");
const single_call_leaf = @import("single_call_leaf.zig");
const word_y_bridge = @import("word_y_bridge.zig");
const short_saves = @import("short_saves.zig");
const word_store = @import("word_store.zig");
const fixed_word_load = @import("fixed_word_load.zig");
const fixed_word_store = @import("fixed_word_store.zig");
const shifted_product_reuse = @import("shifted_product_reuse.zig");
const multiply_helper = @import("multiply_helper.zig");
const tail_call = @import("tail_call.zig");
const array_fill = @import("array_fill.zig");
const index_loads = @import("index_loads.zig");

pub const EmitOptions = module_sidecars.EmitOptions;

pub fn emitProgram(allocator: std.mem.Allocator, program: ast.Program) ![]u8 {
    return emitProgramWithOptions(allocator, program, .{});
}

pub const Emission = emitter.Emission;

/// Finalized assembly plus original pre-relocation source inventory from the
/// retained emission. Both are owned independently of Program and EmitOptions.
/// Facts describe storage events, not allocation or post-optimizer eligibility.
pub fn emitProgramWithFacts(allocator: std.mem.Allocator, program: ast.Program, options: EmitOptions) !Emission {
    var inventory: static_facts.Inventory = .{};
    errdefer inventory.deinit(allocator);
    const assembly = try emitProgramInternal(allocator, program, options, &inventory, .final);
    return .{ .assembly = assembly, .inventory = inventory };
}

pub fn emitProgramWithOptions(allocator: std.mem.Allocator, program: ast.Program, options: EmitOptions) ![]u8 {
    return emitProgramInternal(allocator, program, options, null, .final);
}

// Internal proof/measurement stage: same selected retained emission, real options,
// and allocator. No copied optimizer pipeline or source/CLI configuration.
pub fn emitBeforeUnreachableWithOptions(allocator: std.mem.Allocator, program: ast.Program, options: EmitOptions) ![]u8 {
    return emitProgramInternal(allocator, program, options, null, .before_unreachable);
}

// Internal checkpoint for tests that assert earlier calling-convention and
// machine rewrite behavior while the actual call is still present.
pub fn emitBeforeSingleCallLeaf(allocator: std.mem.Allocator, program: ast.Program) ![]u8 {
    return emitProgramInternal(allocator, program, .{}, null, .before_single_call_leaf);
}

const Stop = enum { before_unreachable, before_single_call_leaf, final };

fn emitProgramInternal(allocator: std.mem.Allocator, program: ast.Program, options: EmitOptions, inventory: ?*static_facts.Inventory, stop: Stop) ![]u8 {
    // Validate every declaration before removing any. Until semantic checking is
    // separate from code generation, a full dry emission preserves diagnostics
    // for invalid-but-unused code. This costs host work, not C64 bytes or cycles.
    var assembly = try emitUnoptimizedWithInventory(allocator, program, options, inventory);
    var assembly_owned = true;
    errdefer if (assembly_owned) allocator.free(assembly);
    var reachable = try reachability.collectProgram(allocator, program);
    defer reachable.deinit();
    if (reachable.count() != program.functions.len) {
        var retained: std.ArrayList(ast.Function) = .empty;
        defer retained.deinit(allocator);
        for (program.functions) |function| {
            if (reachable.contains(function.name)) try retained.append(allocator, function);
        }
        var reduced = program;
        reduced.functions = retained.items;
        // Full emission above remains authoritative semantic validation, but
        // its dead-function storage events must never authorize retained cells.
        // Discard that owning inventory before constructing the selected one.
        if (inventory) |facts| facts.deinit(allocator);
        const selected = try emitUnoptimizedWithInventory(allocator, reduced, options, inventory);
        defer allocator.free(selected);
        var report: std.Io.Writer.Allocating = .init(allocator);
        errdefer report.deinit();
        try report.writer.writeAll(selected);
        for (program.functions) |function| {
            try report.writer.print("; zeropage_liveness function={s} status={s} reason={s}\n", .{
                function.name,
                if (reachable.contains(function.name)) "retained" else "removed",
                reachability.rootReason(program, function) orelse
                    (if (reachable.contains(function.name)) "call_or_assembly_reference" else "unreachable"),
            });
        }
        const optimized = try report.toOwnedSlice();
        allocator.free(assembly);
        assembly = optimized;
    }
    const arguments_rewritten = try call_argument_rewrite.rewrite(allocator, program, assembly);
    allocator.free(assembly);
    assembly = arguments_rewritten;
    var optimized = try optimizer.finalizeAssemblyWithOptions(allocator, assembly, .{
        // DLL absolute operands and relocation anchors remain on their existing
        // path until their removal is modeled together.
        .reuse_pointer_bases = program.zeropage_module == null,
        .cleanup_values = program.zeropage_module == null,
        .hoist_loop_pointers = program.zeropage_module == null,
        .reduce_loop_ranges = program.zeropage_module == null,
    });
    assembly_owned = false; // finalizeAssembly consumed the old buffer.
    // Reuse normalized values and simplify their consumers after existing
    // optimizers. Relocated module and placement anchors keep their old path.
    if (program.zeropage_module == null and program.zeropage_options.memory.placements.len == 0) {
        const addresses = pointer_add.rewriteWithDirectBases(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        allocator.free(optimized);
        optimized = addresses.assembly;
        const forwarded = x_value_forwarding.rewrite(allocator, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        allocator.free(optimized);
        optimized = forwarded.assembly;
        const edge_reused = branch_a_forwarding.rewrite(allocator, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        allocator.free(optimized);
        optimized = edge_reused.assembly;
        const folded = boolean_materialization.rewrite(allocator, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        allocator.free(optimized);
        optimized = folded.assembly;
        if (program.zeropage_options.modules == null) {
            const materialized = zero_values.rewrite(allocator, optimized) catch |err| {
                allocator.free(optimized);
                return err;
            };
            allocator.free(optimized);
            optimized = materialized.assembly;
        }
        const dead = cfg_dead_values.rewrite(allocator, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        allocator.free(optimized);
        optimized = dead.assembly;
        if (program.zeropage_options.modules == null) {
            const ordinary_edges = branch_a_forwarding.rewriteOrdinary(allocator, optimized) catch |err| {
                allocator.free(optimized);
                return err;
            };
            allocator.free(optimized);
            optimized = ordinary_edges.assembly;
            if (ordinary_edges.stats.reloads_replaced != 0) {
                const edge_cleaned = cfg_dead_values.rewrite(allocator, optimized) catch |err| {
                    allocator.free(optimized);
                    return err;
                };
                allocator.free(optimized);
                optimized = edge_cleaned.assembly;
            }
        }
        const reduced_words = word_zero_compare.rewrite(allocator, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        allocator.free(optimized);
        optimized = reduced_words.assembly;
        const unwritten = dead_call_writes.rewrite(allocator, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        allocator.free(optimized);
        optimized = unwritten.assembly;
        const pruned = dead_call_storage.rewrite(allocator, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        allocator.free(optimized);
        optimized = pruned.assembly;
        const incremented = literal_increment.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (incremented) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
    }
    if (program.zeropage_options.zero_page.declared) {
        const allocated = zero_page_allocation.apply(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        allocator.free(optimized);
        optimized = allocated;
    }
    if (stop == .before_unreachable) return optimized;
    if (program.zeropage_module == null and program.zeropage_options.modules == null and program.zeropage_options.memory.placements.len == 0) {
        const dead_code = unreachable_code.rewriteProgram(allocator, optimized, program) catch |err| {
            allocator.free(optimized);
            return err;
        };
        allocator.free(optimized);
        optimized = dead_code.assembly;
        const shortened = short_branches.rewrite(allocator, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        allocator.free(optimized);
        optimized = shortened.assembly;
        const fixed_copy = static_copy_span.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (fixed_copy) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        } else {
            const indexed = wide_index.rewrite(allocator, program, optimized) catch |err| {
                allocator.free(optimized);
                return err;
            };
            if (indexed) |rewritten| {
                allocator.free(optimized);
                optimized = rewritten;
            }
        }
        const selected_pages = page_range.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (selected_pages) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
            const cloned_pages = wide_index.cloneSelectedPages(allocator, program, optimized) catch |err| {
                allocator.free(optimized);
                return err;
            };
            if (cloned_pages) |cloned| {
                allocator.free(optimized);
                optimized = cloned;
            }
            const shared_pages = page_range.shareStored(allocator, program, optimized) catch |err| {
                allocator.free(optimized);
                return err;
            };
            if (shared_pages) |shared| {
                allocator.free(optimized);
                optimized = shared;
            }
        }
        const literal_io = literal_pointer_io.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (literal_io) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const reduced = affine_reduction.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (reduced) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const coalesced = leaf_coalescing.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (coalesced) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const pruned_stores = literal_pointer_io.rewriteDeadStoreScratch(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (pruned_stores) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const narrowed = masked_multiply.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (narrowed) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const folded_locals = local_folds.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (folded_locals) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const copied = counted_copy.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (copied) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const compared = compare_zero.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (compared) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const latched = counted_latch.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (latched) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const inverted = boolean_call_not.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (inverted) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const masked_reads = masked_multiply.rewriteDeadHighReads(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (masked_reads) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const branched_not = boolean_not_branch.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (branched_not) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const high_loads = word_high_load.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (high_loads) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const rotated = word_rotate.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (rotated) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        if (stop == .before_single_call_leaf) return optimized;
        const inlined = single_call_leaf.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (inlined) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const y_bridges = word_y_bridge.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (y_bridges) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const saves = short_saves.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (saves) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const stores = word_store.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (stores) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const tails = tail_call.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (tails) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const late_values = cfg_dead_values.rewriteLate(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (late_values) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const fixed_word_loads = fixed_word_load.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (fixed_word_loads) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const dead_scratch = literal_pointer_io.rewriteDeadScratch(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (dead_scratch) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
            const initializers = cfg_dead_values.rewriteLate(allocator, program, optimized) catch |err| {
                allocator.free(optimized);
                return err;
            };
            if (initializers) |cleaned| {
                allocator.free(optimized);
                optimized = cleaned;
            }
        }
        const fixed_word_stores = fixed_word_store.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (fixed_word_stores) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const shared_products = shifted_product_reuse.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (shared_products) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const high_products = shifted_product_reuse.rewriteHigh(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (high_products) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const known_high = literal_pointer_io.rewriteKnownHighStack(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (known_high) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const zero_high = masked_multiply.rewriteZeroHighRotate(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (zero_high) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const products = multiply_helper.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (products) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const fills = array_fill.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (fills) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const register_latches = counted_latch.rewriteRegister(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (register_latches) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const indexes = index_loads.rewrite(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (indexes) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const shift_stores = fixed_word_store.rewriteShiftStores(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (shift_stores) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const known_index_stores = fixed_word_store.rewriteKnownIndex(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (known_index_stores) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
            // Absolute stores no longer consume the index register.
            const dead_initializers = cfg_dead_values.rewriteLate(allocator, program, optimized) catch |err| {
                allocator.free(optimized);
                return err;
            };
            if (dead_initializers) |cleaned| {
                allocator.free(optimized);
                optimized = cleaned;
            }
        }
        const fallback_index = stream_copy.reuseFallbackIndex(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (fallback_index) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const backedges = short_branches.threadBackedges(allocator, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (backedges) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
        const stack_shortened = shortenStackBranches(allocator, program, optimized) catch |err| {
            allocator.free(optimized);
            return err;
        };
        if (stack_shortened) |rewritten| {
            allocator.free(optimized);
            optimized = rewritten;
        }
    }
    return optimized;
}

fn shortenStackBranches(allocator: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, assembly, "\nzeropage_stack_overflow_trap:\n") == null) return null;
    const image = program.zeropage_options.image;
    if (image.load_addr < 0x0200 or !try frame_layout.hasPrivateStackLayout(allocator, program)) return null;
    if (try placement_domains.observesPrivateStack(allocator, program, .{ .start = image.load_addr, .end = image.address_limit }) or
        try placement_domains.observesMovableImage(allocator, program, .{ .start = 0x0100, .end = 0x0200 })) return null;
    const result = try short_branches.rewriteWithStackOverflowTrap(allocator, assembly);
    if (result.stats.folds != 0) return result.assembly;
    allocator.free(result.assembly);
    return null;
}

fn emitUnoptimizedWithInventory(allocator: std.mem.Allocator, program: ast.Program, options: EmitOptions, inventory: ?*static_facts.Inventory) ![]u8 {
    if (inventory) |facts| {
        std.debug.assert(facts.roots.items.len == 0 and facts.cells.items.len == 0);
        const emission = try emitter.emitProgramWithFacts(allocator, program, options);
        facts.* = emission.inventory; // move both owned results to their owners
        return emission.assembly;
    }
    // Ordinary compilation never constructs facts or calls inventory append.
    return emitUnoptimizedAssemblyWithOptions(allocator, program, options);
}

pub fn emitUnoptimizedAssembly(allocator: std.mem.Allocator, program: ast.Program) ![]u8 {
    return emitter.emitProgram(allocator, program);
}

pub fn emitUnoptimizedAssemblyWithOptions(allocator: std.mem.Allocator, program: ast.Program, options: EmitOptions) ![]u8 {
    return emitter.emitProgramWithOptions(allocator, program, options);
}

pub fn finalizeAssembly(allocator: std.mem.Allocator, assembly: []u8) ![]u8 {
    return optimizer.finalizeAssembly(allocator, assembly);
}
