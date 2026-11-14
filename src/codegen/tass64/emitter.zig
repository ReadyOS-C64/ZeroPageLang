const std = @import("std");
const ast = @import("../../ast.zig");
const inline_asm = @import("../../inline_asm.zig");
const bindings = @import("bindings.zig");
const c64_emit = @import("c64_emit.zig");
const expr_model = @import("expr.zig");
const inline_asm_emit = @import("inline_asm_emit.zig");
const frame_layout = @import("frame_layout.zig");
const module_sidecars = @import("module_sidecars.zig");
const placement_domains = @import("placement_domains.zig");
const runtime = @import("runtime.zig");
const sections = @import("sections.zig");
const reachability = @import("reachability.zig");
const storage = @import("storage.zig");
const static_local_facts = @import("static_local_facts.zig");
const shift_selection = @import("shift_selection.zig");
const stride_selection = @import("stride_selection.zig");
const stride_rewrite = @import("stride_rewrite.zig");
const switch_lookup = @import("switch_lookup.zig");
const machine = @import("instruction.zig");
const test6502_emit = @import("test6502_emit.zig");
const types = @import("types.zig");
const word_multiply = @import("word_multiply.zig");
const stream_copy = @import("stream_copy.zig");

const AddressTarget = bindings.AddressTarget;
const ArrayRef = bindings.ArrayRef;
const Binding = bindings.Binding;
const StringBufferRef = bindings.StringBufferRef;
const StringSource = bindings.StringSource;
const BitwiseOp = expr_model.BitwiseOp;
const CompareOp = expr_model.CompareOp;
const LogicalOp = expr_model.LogicalOp;
const MathOp = expr_model.MathOp;
const ShiftOp = expr_model.ShiftOp;
const SwitchCoveredRange = types.SwitchCoveredRange;

const arrayElemIsWord = types.arrayElemIsWord;
const arrayElemSize = types.arrayElemSize;
const arrayElemToPointerChild = types.arrayElemToPointerChild;
const arrayElemToType = types.arrayElemToType;
const arrayOffsetLiteral = types.arrayOffsetLiteral;
const arrayStorageBytes = types.arrayStorageBytes;
const arrayTypesEqual = types.arrayTypesEqual;
const coversBoolBoth = types.coversBoolBoth;
const emitBasicStub = runtime.emitBasicStub;
const exprIntLiteral = types.exprIntLiteral;
const findStructFieldDecl = types.findStructFieldDecl;
const findStructFieldInit = types.findStructFieldInit;
const inlineAsmMnemonicWritesMemory = inline_asm_emit.mnemonicWritesMemory;
const isScalarSwitchType = types.isScalarSwitchType;
const prongHasElse = types.prongHasElse;
const rangesOverlap = types.rangesOverlap;
const scalarTypeToType = types.scalarTypeToType;
const screenCode = runtime.screenCode;
const shiftRoutineName = types.shiftRoutineName;
const switchExprElseIndex = types.switchExprElseIndex;
const switchSelectorIsBool = types.switchSelectorIsBool;
const switchSelectorLiteral = types.switchSelectorLiteral;
const switchStmtElseIndex = types.switchStmtElseIndex;

const KernalExportPolicy = enum {
    none,
    trampoline_safe,
    unsupported,

    fn combine(lhs: KernalExportPolicy, rhs: KernalExportPolicy) KernalExportPolicy {
        if (lhs == .unsupported or rhs == .unsupported) return .unsupported;
        if (lhs == .trampoline_safe or rhs == .trampoline_safe) return .trampoline_safe;
        return .none;
    }

    fn requiresKernalRom(self: KernalExportPolicy) bool {
        return self != .none;
    }

    fn isUnsupported(self: KernalExportPolicy) bool {
        return self == .unsupported;
    }
};

pub fn emitProgram(allocator: std.mem.Allocator, program: ast.Program) ![]u8 {
    return emitProgramWithOptions(allocator, program, .{});
}

pub const Emission = struct {
    assembly: []u8,
    inventory: static_local_facts.Inventory,
    pub fn deinit(self: *Emission, allocator: std.mem.Allocator) void {
        allocator.free(self.assembly);
        self.inventory.deinit(allocator);
    }
};
pub fn emitProgramWithFacts(allocator: std.mem.Allocator, program: ast.Program, options: module_sidecars.EmitOptions) !Emission {
    var inventory: static_local_facts.Inventory = .{};
    errdefer inventory.deinit(allocator);
    const assembly = try emitProgramInternal(allocator, program, options, &inventory);
    return .{ .assembly = assembly, .inventory = inventory };
}
pub fn emitProgramWithOptions(allocator: std.mem.Allocator, program: ast.Program, options: module_sidecars.EmitOptions) ![]u8 {
    return emitProgramInternal(allocator, program, options, null);
}
fn emitProgramInternal(allocator: std.mem.Allocator, program: ast.Program, options: module_sidecars.EmitOptions, inventory: ?*static_local_facts.Inventory) ![]u8 {
    var emitter = Emitter{
        .allocator = allocator,
        .program = program,
        .options = options,
        .static_facts = inventory,
        .switch_dispatch_pinned = switch_lookup.referencesDispatch(program.functions),
        .multiply_pinned = inline_asm.referencesText(program.functions, referencesMultiplyRuntime),
        .stream_copy_allowed = stream_copy.allowed(program),
        .out = .init(allocator),
        .test_hook_labels = .init(allocator),
        .heap_alloc_names = .init(allocator),
        .heap_reset_names = .init(allocator),
        .heap_free_names = .init(allocator),
        .reu_heap_alloc_names = .init(allocator),
        .reu_heap_reset_names = .init(allocator),
        .module_dependency_load_rows = .init(allocator),
        .module_dependency_acquire_rows = .init(allocator),
        .module_dependency_activation_rows = .init(allocator),
        .module_dependency_unload_rows = .init(allocator),
    };
    errdefer emitter.out.deinit();
    defer emitter.loop_stack.deinit(allocator);
    defer emitter.switch_tables.deinit(allocator);
    defer emitter.block_stack.deinit(allocator);
    defer emitter.deinitModuleRelocations();
    defer emitter.deinitTestHooks();
    defer emitter.heap_alloc_names.deinit();
    defer emitter.heap_reset_names.deinit();
    defer emitter.heap_free_names.deinit();
    defer emitter.reu_heap_alloc_names.deinit();
    defer emitter.reu_heap_reset_names.deinit();
    defer emitter.module_dependency_load_rows.deinit();
    defer emitter.module_dependency_acquire_rows.deinit();
    defer emitter.module_dependency_activation_rows.deinit();
    defer emitter.module_dependency_unload_rows.deinit();
    defer emitter.module_graph_load_scratch.deinit(allocator);
    try emitter.emit();
    return try emitter.out.toOwnedSlice();
}

fn referencesMultiplyRuntime(source: []const u8) bool {
    const prefix = "zeropage_mul";
    if (source.len < prefix.len) return false;
    for (0..source.len - prefix.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(source[start..][0..prefix.len], prefix)) return true;
    }
    return false;
}

const LoopLabels = struct {
    kind: enum { while_loop, stack_while, for_loop },
    id: usize,
};

const BlockExprLabels = struct {
    label: []const u8,
    id: usize,
    result_ty: ast.Type,
};

const StructPathInfo = struct {
    ty: ast.Type,
    offset: u16,
};

const ArrayFieldRef = struct {
    array_ref: ArrayRef,
    field_ty: ast.Type,
    field_offset: u16,
    elem_size: u16,

    fn deinit(self: ArrayFieldRef, allocator: std.mem.Allocator) void {
        self.array_ref.deinit(allocator);
    }
};

const ReuViewCall = struct {
    name: []const u8,
    view: ast.FarViewType,
};

const PreparedMemoryPlacement = struct {
    placement: ast.MemoryPlacement,
    assembly: []u8,
};

const PointerStructPath = struct {
    pointer_label: []const u8,
    pointer_label_owned: bool = false,
    ty: ast.Type,
    offset: u16,

    fn deinit(self: PointerStructPath, allocator: std.mem.Allocator) void {
        if (self.pointer_label_owned) allocator.free(self.pointer_label);
    }
};

const PointerStructArrayPath = struct {
    pointer_label: []const u8,
    pointer_label_owned: bool = false,
    ty: ast.ArrayType,
    offset: u16,

    fn deinit(self: PointerStructArrayPath, allocator: std.mem.Allocator) void {
        if (self.pointer_label_owned) allocator.free(self.pointer_label);
    }
};

const Emitter = struct {
    static_facts: ?*static_local_facts.Inventory = null,
    allocator: std.mem.Allocator,
    program: ast.Program,
    private_stack_layout: ?bool = null,
    private_stack_bridge: ?bool = null,
    private_nested_stack_return: ?bool = null,
    options: module_sidecars.EmitOptions,
    out: std.Io.Writer.Allocating,
    label_id: usize = 0,
    control_label_id: usize = 0,
    condition_label_id: usize = 0,
    uses_hex: bool = false,
    uses_console_hex: bool = false,
    uses_clear_screen: bool = false,
    uses_math_tmp: bool = false,
    uses_console: bool = false,
    uses_string_runtime: bool = false,
    uses_kernal_string: bool = false,
    uses_sleep: bool = false,
    uses_sleep_frames: bool = false,
    uses_screen_tmp: bool = false,
    uses_multiply: bool = false,
    uses_multiply_lhs: bool = false,
    multiply_pinned: bool = false,
    stream_copy_allowed: bool = false,
    used_stream_copy: bool = false,
    stride_usage: stride_selection.Usage = .{},
    uses_shift: bool = false,
    shift_usage: shift_selection.Usage = .{},
    uses_switch: bool = false,
    switch_dispatch_pinned: bool = false,
    switch_tables: std.ArrayList(struct { id: usize, plan: switch_lookup.Plan }) = .empty,
    uses_union_switch: bool = false,
    uses_pointer: bool = false,
    uses_optional_tmp: bool = false,
    uses_stack_bridge_return: bool = false,
    uses_stack_overflow_trap: bool = false,
    uses_reu_present: bool = false,
    uses_reu_copy_c64_to_reu: bool = false,
    uses_reu_copy_reu_to_c64: bool = false,
    uses_reu_swap: bool = false,
    uses_reu_compare: bool = false,
    uses_reu_fill: bool = false,
    uses_reu_view_runtime: bool = false,
    uses_module_load_runtime: bool = false,
    uses_module_disk_load_runtime: bool = false,
    uses_module_dependency_load_runtime: bool = false,
    uses_module_dependency_activation_runtime: bool = false,
    uses_module_current_activation_runtime: bool = false,
    uses_module_registry_runtime: bool = false,
    uses_module_unload_runtime: bool = false,
    uses_module_dependency_unload_runtime: bool = false,
    uses_module_state_runtime: bool = false,
    uses_module_bank_runtime: bool = false,
    uses_module_kernal_console_trampoline: bool = false,
    uses_module_kernal_console_clear_trampoline: bool = false,
    uses_module_kernal_console_newline_trampoline: bool = false,
    uses_module_kernal_console_put_char_trampoline: bool = false,
    uses_module_kernal_console_put_string_trampoline: bool = false,
    uses_module_kernal_console_put_hex_byte_trampoline: bool = false,
    uses_keyboard_wait: bool = false,
    inline_asm_id: usize = 0,
    call_arg_depth: usize = 0,
    scalar_call_site_id: usize = 0,
    max_call_arg_temps: usize = 0,
    field_value_temp_count: usize = 0,
    stack_guard_id: usize = 0,
    module_relocation_id: usize = 0,
    module_graph_load_id: usize = 0,
    module_graph_load_scratch: std.ArrayList(ModuleGraphLoadScratch) = .empty,
    module_relocations: std.ArrayList(EmittedModuleRelocation) = .empty,
    loop_stack: std.ArrayList(LoopLabels) = .empty,
    block_stack: std.ArrayList(BlockExprLabels) = .empty,
    test_hook_labels: std.StringHashMap(void),
    test_hook_order: std.ArrayList([]const u8) = .empty,
    heap_alloc_names: std.StringHashMap(void),
    heap_reset_names: std.StringHashMap(void),
    heap_free_names: std.StringHashMap(void),
    reu_heap_alloc_names: std.StringHashMap(void),
    reu_heap_reset_names: std.StringHashMap(void),
    module_dependency_load_rows: std.AutoHashMap(usize, void),
    module_dependency_acquire_rows: std.AutoHashMap(usize, void),
    module_dependency_activation_rows: std.AutoHashMap(usize, void),
    module_dependency_unload_rows: std.AutoHashMap(usize, void),

    fn deinitTestHooks(self: *Emitter) void {
        for (self.test_hook_order.items) |label| self.allocator.free(label);
        self.test_hook_order.deinit(self.allocator);
        self.test_hook_labels.deinit();
    }

    const EmittedModuleRelocation = struct {
        id: usize,
        kind: ModuleRelocationKind,
        target: []const u8,
        addend: i16,
    };

    const ModuleGraphLoadScratch = struct {
        id: usize,
        row_count: usize,
    };

    fn deinitModuleRelocations(self: *Emitter) void {
        for (self.module_relocations.items) |relocation| self.allocator.free(relocation.target);
        self.module_relocations.deinit(self.allocator);
    }

    fn emit(self: *Emitter) !void {
        try self.validateDependencySidecars();
        try self.validateCurrentKernalBankExports();
        try self.validateModuleBindings();
        const w = &self.out.writer;
        const program_uses_stack = self.programUsesSoftwareStack();
        self.uses_module_load_runtime = self.programUsesModuleLoader();
        self.uses_module_disk_load_runtime = self.programUsesModuleDiskLoader();
        self.uses_module_registry_runtime = self.uses_module_load_runtime or self.uses_module_disk_load_runtime or self.programUsesModuleRegistry();
        self.uses_module_state_runtime = self.programUsesModuleStateRuntime();
        if (self.programHasBankedModuleWindow()) self.uses_module_bank_runtime = true;
        try self.prepareModuleDependencyPreloadRuntime();
        if (self.uses_module_load_runtime or self.uses_module_disk_load_runtime or self.uses_module_dependency_load_runtime or self.uses_module_dependency_activation_runtime or self.uses_module_current_activation_runtime) {
            self.uses_reu_present = true;
            self.uses_reu_copy_c64_to_reu = true;
            self.uses_reu_copy_reu_to_c64 = true;
        }
        if (self.uses_module_state_runtime) {
            self.uses_reu_copy_c64_to_reu = true;
            self.uses_reu_copy_reu_to_c64 = true;
        }
        const module_payload_start = if (self.usesModulePayloadRuntime()) try self.modulePayloadStartFunctionName() else null;
        const module_payload_tail_end = self.usesModulePayloadRuntime() and (self.modulePayloadHasRodata() or (self.program.zeropage_options.modules != null and self.program.zeropage_options.modules.?.load_window.bank == .ram_under_kernal));
        const module_payload_end_after_function = if (self.usesModulePayloadRuntime() and !module_payload_tail_end) try self.modulePayloadEndFunctionName() else null;
        var prepared_placements = try self.prepareMemoryPlacements();
        defer {
            for (prepared_placements.items) |prepared| self.allocator.free(prepared.assembly);
            prepared_placements.deinit(self.allocator);
        }
        const image = self.program.zeropage_options.image;
        if (image.basic_stub) {
            try emitBasicStub(w, image.load_addr, image.entry_addr);
        } else {
            try w.print("; generated by zp64c\n* = ${x:0>4}\n", .{image.load_addr});
            if (image.entry_addr > image.load_addr) {
                try w.print("    .fill ${x:0>4},0\n", .{image.entry_addr - image.load_addr});
            }
        }
        try w.writeAll("\nzeropage_console_ptr = $fb\nzeropage_string_dst_ptr = $fb\nzeropage_ptr_tmp = $fb\nzeropage_string_ptr = $fd\nzeropage_string_src_ptr = $fd\nzeropage_kernal_ptr = zeropage_string_src_ptr\n");
        if (program_uses_stack) {
            const stack = self.program.zeropage_options.stack.?;
            try w.print("zeropage_stack_sp = ${x:0>2}\nzeropage_stack_fp = ${x:0>2}\n", .{ stack.zp.sp, stack.zp.fp });
        }
        try w.print("* = ${x:0>4}\nzeropage_entry:\n", .{image.entry_addr});
        if (self.hasStartupCopyPlacements()) try w.writeAll("    jsr zeropage_memory_init\n");
        if (self.programUsesModuleDiskPreload()) {
            try sections.emitBegin(w, .runtime, .code, .static, .near);
            try w.writeAll(
                \\zeropage_module_preload_start:
                \\    jsr zeropage_module_load_from_disk_current
                \\
            );
            try sections.emitEnd(w, .runtime, .code);
        }
        if (self.programUsesDependencyModulePreload()) {
            try sections.emitBegin(w, .runtime, .code, .static, .near);
            try w.writeAll("zeropage_module_dependency_preload_start:\n");
            const module = self.program.zeropage_module.?;
            for (module.deps, 0..) |dep, index| {
                if (self.dependencyModulePolicy(dep)) |policy| {
                    if (policy.mode == .preload) {
                        if (policy.graph) {
                            try self.emitModuleDependencyGraphLoad(.{ .id = dep });
                        } else {
                            try w.print("    jsr zeropage_module_load_dependency_row{d}\n", .{index + 1});
                        }
                    }
                }
            }
            try sections.emitEnd(w, .runtime, .code);
        }

        const main = self.program.findFunction("main") orelse return error.MissingMain;
        if (module_payload_start) |name| if (std.mem.eql(u8, main.name, name)) try w.writeAll("zeropage_module_payload_range_start:\n");
        if (self.functionUsesSoftwareStack(main.name)) {
            try self.emitSoftwareStackMain(main);
        } else {
            try self.emitFunction(main);
            try self.emitFunctionStaticFrame(main);
        }
        if (module_payload_end_after_function) |name| if (std.mem.eql(u8, main.name, name)) try w.writeAll("zeropage_module_payload_range_end:\n");
        for (self.program.functions) |function| {
            if (!std.mem.eql(u8, function.name, "main")) {
                if (self.functionHasMemoryPlacement(function.name)) continue;
                if (module_payload_start) |name| if (std.mem.eql(u8, function.name, name)) try w.writeAll("zeropage_module_payload_range_start:\n");
                if (self.functionUsesSoftwareStack(function.name)) {
                    try self.emitSoftwareStackHelper(function);
                } else {
                    try self.emitFunction(function);
                    try self.emitFunctionStaticFrame(function);
                }
                if (module_payload_end_after_function) |name| if (std.mem.eql(u8, function.name, name)) try w.writeAll("zeropage_module_payload_range_end:\n");
            }
        }

        if (self.program.zeropage_module == null and self.uses_multiply) {
            var keep_generic = false;
            var pinned_names = false;
            for (prepared_placements.items) |prepared| {
                if (std.mem.indexOf(u8, prepared.assembly, "zeropage_mul16") != null) keep_generic = true;
                if (std.mem.indexOf(u8, prepared.assembly, "zeropage_stride_mul_") != null) pinned_names = true;
            }
            // Prepared function labels/references are not in the resident
            // prefix inspected by the rewrite. Preserve their source meaning.
            for (self.program.functions) |function| {
                if (std.mem.startsWith(u8, function.name, "zeropage_stride_mul_")) pinned_names = true;
            }
            if (!pinned_names) {
                var rewritten = try stride_rewrite.rewrite(self.allocator, self.out.written(), keep_generic);
                defer rewritten.deinit(self.allocator);
                if (rewritten.stats.replacements != 0) {
                    self.out.deinit();
                    self.out = .init(self.allocator);
                    try self.out.writer.writeAll(rewritten.assembly);
                    self.stride_usage = rewritten.usage;
                    self.uses_multiply = rewritten.generic_needed;
                }
            }
        }
        if (self.stride_usage.usesLhs()) {
            try sections.emitBegin(w, .runtime, .code, .static, .near);
            try self.stride_usage.emitHelpers(w);
            try sections.emitEnd(w, .runtime, .code);
        }
        if (self.uses_clear_screen) try self.emitClearScreenRoutine();
        if (self.uses_console) try self.emitConsoleRoutines();
        if (self.uses_console_hex) try self.emitConsoleHexRoutine();
        if (self.uses_module_kernal_console_trampoline) try self.emitModuleKernalConsoleTrampolines();
        if (self.uses_string_runtime) try self.emitStringRuntimeRoutine();
        if (self.uses_kernal_string) try self.emitKernalStringRoutine();
        if (self.uses_hex) try self.emitHexNibbleRoutine();
        if (self.uses_multiply) try self.emitMultiplyRoutine();
        if (self.uses_shift) try self.emitShiftRoutines();
        if (self.uses_keyboard_wait) try self.emitKeyboardWaitRoutine();
        if (self.uses_sleep) try self.emitSleepRoutine();
        if (self.uses_sleep_frames) try self.emitSleepFramesRoutine();
        try self.emitTest6502Stubs();
        if (self.uses_stack_overflow_trap) try self.emitSoftwareStackOverflowTrap();
        if (self.usesReuRuntime()) try self.emitReuRoutines();
        if (self.usesHeapRuntime()) try self.emitHeapRoutines();
        try self.emitMemoryPlacementGateways();
        try self.emitMemoryPlacementStartupRoutines();
        try self.emitVarSlots();
        try self.emitMemoryPlacementRuntimeData();
        try self.emitRoDataConstants();
        if (self.switch_tables.items.len != 0) {
            try sections.emitBegin(w, .compiler, .rodata, .static, .near);
            for (self.switch_tables.items) |table| try switch_lookup.emitData(w, table.plan, table.id);
            try sections.emitEnd(w, .compiler, .rodata);
        }
        if (module_payload_tail_end) try w.writeAll("zeropage_module_payload_range_end:\n");
        try w.writeAll("; zeropage_zero_page_runtime_anchor\n");
        try self.validateBankedMemoryPlacementReferences(prepared_placements.items);
        try self.emitPreparedMemoryPlacements(prepared_placements.items);
        if (self.used_stream_copy) try w.writeAll("zeropage_stream_copy_image_end:\n");
    }

    fn prepareMemoryPlacements(self: *Emitter) !std.ArrayList(PreparedMemoryPlacement) {
        var prepared: std.ArrayList(PreparedMemoryPlacement) = .empty;
        errdefer {
            for (prepared.items) |item| self.allocator.free(item.assembly);
            prepared.deinit(self.allocator);
        }
        for (self.program.zeropage_options.memory.placements) |placement| {
            const resident_out = self.out;
            self.out = .init(self.allocator);
            var restored = false;
            errdefer if (!restored) {
                self.out.deinit();
                self.out = resident_out;
            };
            for (placement.functions) |name| {
                const function = self.program.findFunction(name) orelse return error.UnknownZeroPageMemoryPlacementDeclaration;
                try self.emitFunction(function);
                try self.emitFunctionStaticFrame(function);
            }
            for (placement.constants) |name| try storage.emitNamedRoDataConstant(self, name);
            const bytes = try self.out.toOwnedSlice();
            self.out = resident_out;
            restored = true;
            try prepared.append(self.allocator, .{ .placement = placement, .assembly = bytes });
        }
        return prepared;
    }

    fn programUsesSoftwareStack(self: *Emitter) bool {
        for (self.program.functions) |function| {
            if (self.functionUsesSoftwareStack(function.name)) return true;
        }
        return false;
    }

    fn functionHasMemoryPlacement(self: *Emitter, name: []const u8) bool {
        return self.program.findFunctionPlacement(name) != null;
    }

    pub fn constantHasMemoryPlacement(self: *Emitter, name: []const u8) bool {
        return self.program.findConstantPlacement(name) != null;
    }

    fn hasStartupCopyPlacements(self: *Emitter) bool {
        for (self.program.zeropage_options.memory.placements) |placement| {
            if (placement.load == .startup_copy) return true;
        }
        return false;
    }

    fn memoryPlacementRegion(self: *Emitter, placement: ast.MemoryPlacement) !ast.MemoryRegion {
        return self.program.findMemoryRegion(placement.region_name) orelse error.UnknownZeroPageMemoryRegion;
    }

    fn functionCallNeedsMemoryGateway(self: *Emitter, caller_name: []const u8, callee_name: []const u8) !bool {
        const callee_placement = self.program.findFunctionPlacement(callee_name) orelse return false;
        const region = try self.memoryPlacementRegion(callee_placement);
        if (region.bank == .visible) return false;
        if (self.program.findFunctionPlacement(caller_name)) |caller_placement| {
            if (std.mem.eql(u8, caller_placement.region_name, callee_placement.region_name)) return false;
        }
        return true;
    }

    fn emitUserFunctionJsr(self: *Emitter, caller_name: []const u8, callee_name: []const u8) !void {
        if (try self.functionCallNeedsMemoryGateway(caller_name, callee_name)) {
            const gateway = try std.fmt.allocPrint(self.allocator, "zeropage_placement_gateway_{s}", .{callee_name});
            defer self.allocator.free(gateway);
            try self.emitModuleRelocationAnchor(gateway);
            try self.out.writer.print("    jsr {s}\n", .{gateway});
        } else {
            try self.emitModuleRelocationAnchor(callee_name);
            try self.out.writer.print("    jsr {s}\n", .{callee_name});
        }
    }

    fn emitMemoryPlacementGateways(self: *Emitter) !void {
        const w = &self.out.writer;
        for (self.program.zeropage_options.memory.placements) |placement| {
            const region = try self.memoryPlacementRegion(placement);
            if (region.bank == .visible) continue;
            for (placement.functions) |name| {
                try sections.emitBegin(w, .runtime, .code, .static, .near);
                try w.print(
                    "zeropage_placement_gateway_{s}:\n    php\n    pla\n    sta zeropage_placement_{s}_status\n    sei\n    lda $01\n    sta zeropage_placement_{s}_port\n",
                    .{ name, name, name },
                );
                switch (region.bank) {
                    .visible => unreachable,
                    .ram_under_basic => try w.writeAll("    and #$fe\n"),
                    .ram_under_kernal => try w.writeAll("    and #$fd\n"),
                }
                try w.print(
                    "    sta $01\n    jsr {s}\n    sta zeropage_placement_{s}_return_a\n    stx zeropage_placement_{s}_return_x\n    lda zeropage_placement_{s}_port\n    sta $01\n    lda zeropage_placement_{s}_status\n    pha\n    lda zeropage_placement_{s}_return_a\n    ldx zeropage_placement_{s}_return_x\n    plp\n    rts\n",
                    .{ name, name, name, name, name, name, name },
                );
                try sections.emitEnd(w, .runtime, .code);
            }
        }
    }

    fn emitMemoryPlacementStartupRoutines(self: *Emitter) !void {
        if (!self.hasStartupCopyPlacements()) return;
        const w = &self.out.writer;
        try sections.emitBegin(w, .runtime, .code, .static, .near);
        try w.writeAll("zeropage_memory_init:\n");
        for (self.program.zeropage_options.memory.placements) |placement| {
            if (placement.load == .startup_copy) try w.print("    jsr zeropage_placement_copy_{s}\n", .{placement.name});
        }
        try w.writeAll("    rts\n");
        try sections.emitEnd(w, .runtime, .code);

        for (self.program.zeropage_options.memory.placements) |placement| {
            if (placement.load != .startup_copy) continue;
            const region = try self.memoryPlacementRegion(placement);
            try sections.emitBegin(w, .runtime, .code, .static, .near);
            try w.print(
                "zeropage_placement_copy_{s}:\n    php\n    pla\n    sta zeropage_placement_{s}_copy_status\n    sei\n    lda $01\n    sta zeropage_placement_{s}_copy_port\n",
                .{ placement.name, placement.name, placement.name },
            );
            switch (region.bank) {
                .visible => {},
                .ram_under_basic => try w.writeAll("    and #$fe\n    sta $01\n"),
                .ram_under_kernal => try w.writeAll("    and #$fd\n    sta $01\n"),
            }
            try w.print(
                "    lda #<zeropage_placement_{s}_load_start\n    sta zeropage_ptr_tmp\n    lda #>zeropage_placement_{s}_load_start\n    sta zeropage_ptr_tmp+1\n    lda #<zeropage_placement_{s}_run_start\n    sta zeropage_string_ptr\n    lda #>zeropage_placement_{s}_run_start\n    sta zeropage_string_ptr+1\n    lda #<(zeropage_placement_{s}_run_end-zeropage_placement_{s}_run_start)\n    sta zeropage_placement_{s}_copy_len\n    lda #>(zeropage_placement_{s}_run_end-zeropage_placement_{s}_run_start)\n    sta zeropage_placement_{s}_copy_len+1\n    ldy #0\nzeropage_placement_{s}_copy_loop:\n    lda (zeropage_ptr_tmp),y\n    sta (zeropage_string_ptr),y\n    lda zeropage_placement_{s}_copy_len\n    bne zeropage_placement_{s}_copy_dec_low\n    dec zeropage_placement_{s}_copy_len+1\nzeropage_placement_{s}_copy_dec_low:\n    dec zeropage_placement_{s}_copy_len\n    lda zeropage_placement_{s}_copy_len\n    ora zeropage_placement_{s}_copy_len+1\n    beq zeropage_placement_{s}_copy_done\n    inc zeropage_ptr_tmp\n    bne zeropage_placement_{s}_copy_src_ok\n    inc zeropage_ptr_tmp+1\nzeropage_placement_{s}_copy_src_ok:\n    inc zeropage_string_ptr\n    bne zeropage_placement_{s}_copy_loop\n    inc zeropage_string_ptr+1\n    jmp zeropage_placement_{s}_copy_loop\nzeropage_placement_{s}_copy_done:\n    lda zeropage_placement_{s}_copy_port\n    sta $01\n    lda zeropage_placement_{s}_copy_status\n    pha\n    plp\n    rts\n",
                .{ placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name, placement.name },
            );
            try sections.emitEnd(w, .runtime, .code);
        }
    }

    fn emitMemoryPlacementRuntimeData(self: *Emitter) !void {
        const w = &self.out.writer;
        var emitted = false;
        for (self.program.zeropage_options.memory.placements) |placement| {
            const region = try self.memoryPlacementRegion(placement);
            if (placement.load == .startup_copy) {
                if (!emitted) try sections.emitBegin(w, .runtime, .data, .static, .near);
                emitted = true;
                try w.print("zeropage_placement_{s}_copy_status:\n    .byte 0\nzeropage_placement_{s}_copy_port:\n    .byte 0\nzeropage_placement_{s}_copy_len:\n    .word 0\n", .{ placement.name, placement.name, placement.name });
            }
            if (region.bank != .visible) {
                if (!emitted) try sections.emitBegin(w, .runtime, .data, .static, .near);
                emitted = true;
                for (placement.functions) |name| {
                    try w.print("zeropage_placement_{s}_status:\n    .byte 0\nzeropage_placement_{s}_port:\n    .byte 0\nzeropage_placement_{s}_return_a:\n    .byte 0\nzeropage_placement_{s}_return_x:\n    .byte 0\n", .{ name, name, name, name });
                }
            }
        }
        if (emitted) try sections.emitEnd(w, .runtime, .data);
    }

    fn emitPreparedMemoryPlacements(self: *Emitter, prepared: []const PreparedMemoryPlacement) !void {
        for (prepared) |item| {
            if (item.placement.load != .startup_copy) continue;
            try self.emitPreparedMemoryPlacement(item);
        }
        for (prepared) |item| {
            if (item.placement.load != .direct) continue;
            try self.emitPreparedMemoryPlacement(item);
        }
    }

    fn validateBankedMemoryPlacementReferences(self: *Emitter, prepared: []const PreparedMemoryPlacement) !void {
        const resident_assembly = self.out.written();
        for (prepared) |item| {
            const region = try self.memoryPlacementRegion(item.placement);
            if (region.bank == .visible) continue;
            for (item.placement.constants) |name| {
                const label = if (self.program.findString(name) != null)
                    try std.fmt.allocPrint(self.allocator, "zeropage_str_{s}", .{name})
                else
                    try std.fmt.allocPrint(self.allocator, "zeropage_arr_{s}", .{name});
                defer self.allocator.free(label);
                if (std.mem.indexOf(u8, resident_assembly, label) != null) return error.UnsafeBankedMemoryPlacementReference;
            }
            if (region.bank == .ram_under_kernal) {
                if (std.mem.indexOf(u8, item.assembly, "$ffd2") != null or
                    std.mem.indexOf(u8, item.assembly, "$ffe4") != null or
                    std.mem.indexOf(u8, item.assembly, "kernal") != null or
                    std.mem.indexOf(u8, item.assembly, "keyboard") != null or
                    std.mem.indexOf(u8, item.assembly, "module_load_from_disk") != null)
                {
                    return error.UnsafeKernalBankMemoryPlacement;
                }
            }
        }
    }

    fn emitPreparedMemoryPlacement(self: *Emitter, item: PreparedMemoryPlacement) !void {
        const w = &self.out.writer;
        const region = try self.memoryPlacementRegion(item.placement);
        try w.print("\n; memory placement {s} in region {s}\n", .{ item.placement.name, item.placement.region_name });
        switch (item.placement.load) {
            .startup_copy => try w.print("zeropage_placement_{s}_load_start:\n    .logical ${x:0>4}\nzeropage_placement_{s}_run_start:\n", .{ item.placement.name, region.addr, item.placement.name }),
            .direct => try w.print("* = ${x:0>4}\nzeropage_placement_{s}_load_start:\nzeropage_placement_{s}_run_start:\n", .{ region.addr, item.placement.name, item.placement.name }),
        }
        try w.writeAll(item.assembly);
        try w.print("zeropage_placement_{s}_run_end:\n", .{item.placement.name});
        if (item.placement.load == .startup_copy) try w.writeAll("    .here\n");
        try w.print("zeropage_placement_{s}_load_end:\n    .cerror (zeropage_placement_{s}_run_end-zeropage_placement_{s}_run_start) > ${x:0>4}, \"ZeroPage memory placement exceeds region\"\n", .{ item.placement.name, item.placement.name, item.placement.name, region.size });
    }

    fn programUsesModuleLoader(self: *Emitter) bool {
        const module = self.program.zeropage_module orelse return false;
        for (self.program.functions) |function| {
            if (stmtsContainModuleLoad(function.body, module.id)) return true;
        }
        return false;
    }

    fn programUsesModuleDiskLoader(self: *Emitter) bool {
        if (self.programUsesModuleDiskPreload()) return true;
        if (self.programUsesModuleOnDemandCalls()) return true;
        for (self.program.functions) |function| {
            if (stmtsContainModuleDiskLoad(function.body)) return true;
        }
        return false;
    }

    fn programUsesModuleDiskPreload(self: *Emitter) bool {
        const modules = self.program.zeropage_options.modules orelse return false;
        const policy = modules.policy orelse return false;
        return policy.current.mode == .preload;
    }

    fn programUsesDependencyModulePreload(self: *Emitter) bool {
        const modules = self.program.zeropage_options.modules orelse return false;
        const policy = modules.policy orelse return false;
        for (policy.deps) |dep_policy| {
            if (dep_policy.policy.mode == .preload) return true;
        }
        return false;
    }

    fn prepareModuleDependencyPreloadRuntime(self: *Emitter) !void {
        if (!self.programUsesDependencyModulePreload()) return;
        const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
        for (module.deps, 0..) |dep, index| {
            if (self.dependencyModulePolicy(dep)) |policy| {
                if (policy.mode == .preload) {
                    if (!policy.graph) {
                        self.uses_module_dependency_load_runtime = true;
                        self.uses_module_registry_runtime = true;
                        try self.module_dependency_load_rows.put(index + 1, {});
                    }
                }
            }
        }
    }

    fn dependencyModulePolicy(self: *Emitter, id: []const u8) ?ast.CurrentModulePolicy {
        const modules = self.program.zeropage_options.modules orelse return null;
        const policy = modules.policy orelse return null;
        for (policy.deps) |dep_policy| {
            if (std.mem.eql(u8, dep_policy.id, id)) return dep_policy.policy;
        }
        return null;
    }

    fn programUsesModuleOnDemandCalls(self: *Emitter) bool {
        const modules = self.program.zeropage_options.modules orelse return false;
        const policy = modules.policy orelse return false;
        if (policy.current.mode != .on_demand) return false;
        for (self.program.functions) |function| {
            if (stmtsContainModuleCall(function.body)) return true;
        }
        return false;
    }

    fn programUsesModuleOnDemandPolicy(self: *Emitter) bool {
        const modules = self.program.zeropage_options.modules orelse return false;
        const policy = modules.policy orelse return false;
        return policy.current.mode == .on_demand;
    }

    fn usesModulePayloadRuntime(self: *Emitter) bool {
        return self.uses_module_load_runtime or self.uses_module_disk_load_runtime;
    }

    fn programUsesModuleStateRuntime(self: *Emitter) bool {
        const modules = self.program.zeropage_options.modules orelse return false;
        const state = modules.state orelse return false;
        const uses_lifecycle = self.programUsesModuleLoader() or
            self.programUsesModuleDiskLoader() or
            self.programUsesModuleRegistry();
        if (!uses_lifecycle) return false;
        if (state.current.mode == .persist_in_reu) return true;
        for (state.deps) |dep_state| {
            if (dep_state.state.mode == .persist_in_reu) return true;
        }
        return false;
    }

    fn programUsesModuleRegistry(self: *Emitter) bool {
        for (self.program.functions) |function| {
            if (stmtsContainModuleRegistry(function.body)) return true;
        }
        return false;
    }

    fn modulePayloadHasRodata(self: *Emitter) bool {
        return self.program.string_constants.len != 0 or self.program.array_constants.len != 0;
    }

    fn modulePayloadStartFunctionName(self: *Emitter) !?[]const u8 {
        var reachable = try self.collectReachableModuleFunctions();
        defer reachable.deinit();
        const main = self.program.findFunction("main") orelse return error.MissingMain;
        if (reachable.contains(main.name)) return main.name;
        for (self.program.functions) |function| {
            if (!std.mem.eql(u8, function.name, "main") and reachable.contains(function.name)) return function.name;
        }
        return null;
    }

    fn modulePayloadEndFunctionName(self: *Emitter) !?[]const u8 {
        var reachable = try self.collectReachableModuleFunctions();
        defer reachable.deinit();
        var last: ?[]const u8 = null;
        const main = self.program.findFunction("main") orelse return error.MissingMain;
        if (reachable.contains(main.name)) last = main.name;
        for (self.program.functions) |function| {
            if (!std.mem.eql(u8, function.name, "main") and reachable.contains(function.name)) last = function.name;
        }
        return last;
    }

    fn collectReachableModuleFunctions(self: *Emitter) !std.StringHashMap(void) {
        return reachability.collectModule(self.allocator, self.program, self.program.zeropage_module orelse return error.UnknownZeroPageModule);
    }

    fn functionKernalExportPolicy(self: *Emitter, function: ast.Function, visited: *std.StringHashMap(void)) anyerror!KernalExportPolicy {
        if (visited.contains(function.name)) return .none;
        try visited.put(function.name, {});
        return try self.stmtsKernalExportPolicy(function.body, visited);
    }

    fn stmtsKernalExportPolicy(self: *Emitter, statements: []const ast.Stmt, visited: *std.StringHashMap(void)) anyerror!KernalExportPolicy {
        var policy: KernalExportPolicy = .none;
        for (statements) |stmt| {
            policy = policy.combine(try self.stmtKernalExportPolicy(stmt, visited));
            if (policy == .unsupported) return policy;
        }
        return policy;
    }

    fn stmtKernalExportPolicy(self: *Emitter, stmt: ast.Stmt, visited: *std.StringHashMap(void)) anyerror!KernalExportPolicy {
        return switch (stmt) {
            .builtin => |builtin| try self.builtinKernalExportPolicy(builtin, visited),
            .var_decl => |decl| try self.exprKernalExportPolicy(decl.init, visited),
            .assign => |assign| try self.exprKernalExportPolicy(assign.value, visited),
            inline .add_assign, .sub_assign, .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => |assign| try self.exprKernalExportPolicy(assign.value, visited),
            .deref_assign => |assign| (try self.exprKernalExportPolicy(assign.target, visited)).combine(try self.exprKernalExportPolicy(assign.value, visited)),
            .array_assign, .array_add_assign, .array_sub_assign, .array_mul_assign, .array_bit_and_assign, .array_bit_or_assign, .array_bit_xor_assign, .array_shl_assign, .array_shr_assign => |assign| (try self.exprKernalExportPolicy(assign.index, visited)).combine(try self.exprKernalExportPolicy(assign.value, visited)),
            .array_field_assign => |assign| (try self.exprKernalExportPolicy(assign.index, visited)).combine(try self.exprKernalExportPolicy(assign.value, visited)),
            .if_stmt => |if_stmt| (try self.exprKernalExportPolicy(if_stmt.condition, visited)).combine(try self.stmtsKernalExportPolicy(if_stmt.then_body, visited)).combine(try self.stmtsKernalExportPolicy(if_stmt.else_body, visited)),
            .while_stmt => |while_stmt| (try self.exprKernalExportPolicy(while_stmt.condition, visited)).combine(try self.stmtsKernalExportPolicy(while_stmt.body, visited)),
            .for_stmt => |for_stmt| try self.stmtsKernalExportPolicy(for_stmt.body, visited),
            .switch_stmt => |switch_stmt| blk: {
                var policy = try self.exprKernalExportPolicy(switch_stmt.operand, visited);
                for (switch_stmt.prongs) |prong| {
                    policy = policy.combine(try self.stmtsKernalExportPolicy(prong.body, visited));
                    if (policy == .unsupported) break;
                }
                break :blk policy;
            },
            .call => |call| try self.callKernalExportPolicy(call, visited),
            .discard, .return_expr => |expr| try self.exprKernalExportPolicy(expr, visited),
            .break_expr => |break_expr| try self.exprKernalExportPolicy(break_expr.value, visited),
            .field_assign => |field| try self.exprKernalExportPolicy(field.value, visited),
            .heap_free => |free| try self.exprKernalExportPolicy(free.ptr.*, visited),
            .struct_var => |struct_var| blk: {
                var policy: KernalExportPolicy = .none;
                for (struct_var.fields) |field| {
                    policy = policy.combine(try self.exprKernalExportPolicy(field.value, visited));
                    if (policy == .unsupported) break;
                }
                break :blk policy;
            },
            .inline_asm => .unsupported,
            .test6502, .reu, .string_var, .string_assign, .reu_heap_reset, .heap_reset, .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph, .break_stmt, .continue_stmt => .none,
        };
    }

    fn exprKernalExportPolicy(self: *Emitter, expr: ast.Expr, visited: *std.StringHashMap(void)) anyerror!KernalExportPolicy {
        return switch (expr) {
            .c64_read_petscii, .c64_wait_petscii, .module_disk_load => .unsupported,
            inline .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| (try self.exprKernalExportPolicy(binary.lhs.*, visited)).combine(try self.exprKernalExportPolicy(binary.rhs.*, visited)),
            .not, .bit_not, .deref, .ptr_from_int, .int_from_ptr => |child| try self.exprKernalExportPolicy(child.*, visited),
            .as_cast => |cast| try self.exprKernalExportPolicy(cast.expr.*, visited),
            .if_expr => |if_expr| (try self.exprKernalExportPolicy(if_expr.condition.*, visited)).combine(try self.exprKernalExportPolicy(if_expr.then_expr.*, visited)).combine(try self.exprKernalExportPolicy(if_expr.else_expr.*, visited)),
            .switch_expr => |switch_expr| blk: {
                var policy = try self.exprKernalExportPolicy(switch_expr.operand.*, visited);
                for (switch_expr.prongs) |prong| {
                    policy = policy.combine(try self.exprKernalExportPolicy(prong.value, visited));
                    if (policy == .unsupported) break;
                }
                break :blk policy;
            },
            .block_expr => |block_expr| try self.stmtsKernalExportPolicy(block_expr.body, visited),
            .call => |call| try self.callKernalExportPolicy(call, visited),
            .array_literal => |literal| blk: {
                var policy: KernalExportPolicy = .none;
                for (literal.values) |value| {
                    policy = policy.combine(try self.exprKernalExportPolicy(value, visited));
                    if (policy == .unsupported) break;
                }
                break :blk policy;
            },
            .struct_literal => |literal| blk: {
                var policy: KernalExportPolicy = .none;
                for (literal.fields) |field| {
                    policy = policy.combine(try self.exprKernalExportPolicy(field.value, visited));
                    if (policy == .unsupported) break;
                }
                break :blk policy;
            },
            .array_index => |index| try self.exprKernalExportPolicy(index.index.*, visited),
            .array_field_index => |index| try self.exprKernalExportPolicy(index.index.*, visited),
            .reu_compare => |transfer| (try self.exprKernalExportPolicy(transfer.c64_addr.*, visited)).combine(try self.exprKernalExportPolicy(transfer.len.*, visited)),
            .reu_heap_alloc => |alloc| try self.exprKernalExportPolicy(alloc.len.*, visited),
            .reu_view => |view| try self.exprKernalExportPolicy(view.far.*, visited),
            .far_view_materialize_range => |range| try self.exprKernalExportPolicy(range.start.*, visited),
            .module_call => |call| blk: {
                var policy: KernalExportPolicy = .none;
                for (call.args) |arg| {
                    policy = policy.combine(try self.exprKernalExportPolicy(arg, visited));
                    if (policy == .unsupported) break;
                }
                break :blk policy;
            },
            .heap_alloc => |alloc| try self.exprKernalExportPolicy(alloc.len.*, visited),
            else => .none,
        };
    }

    fn callKernalExportPolicy(self: *Emitter, call: ast.CallExpr, visited: *std.StringHashMap(void)) anyerror!KernalExportPolicy {
        var policy: KernalExportPolicy = .none;
        const target = self.functionForCall(call) catch null;
        if (target) |function| {
            policy = policy.combine(try self.functionKernalExportPolicy(function, visited));
            if (policy == .unsupported) return policy;
        }
        for (call.args) |arg| {
            policy = policy.combine(try self.exprKernalExportPolicy(arg, visited));
            if (policy == .unsupported) return policy;
        }
        return policy;
    }

    fn builtinKernalExportPolicy(self: *Emitter, builtin: ast.BuiltinCall, visited: *std.StringHashMap(void)) anyerror!KernalExportPolicy {
        return switch (builtin) {
            .console_clear => .trampoline_safe,
            .console_print => |print| blk: {
                var policy: KernalExportPolicy = .trampoline_safe;
                for (print.args) |arg| switch (arg) {
                    .string => {},
                    .value => |expr| {
                        policy = policy.combine(try self.exprKernalExportPolicy(expr, visited));
                        if (policy == .unsupported) break :blk policy;
                    },
                };
                break :blk policy;
            },
            .console_puts => .trampoline_safe,
            .kernal_puts, .kernal_set_name => .unsupported,
            .screen_clear, .puts_at, .put_at, .hex_at, .hex16_at, .string_append, .string_clear, .sleep_ticks, .sleep_frames => .none,
        };
    }

    fn stmtsContainModuleLoad(statements: []const ast.Stmt, module_id: []const u8) bool {
        for (statements) |stmt| {
            if (stmtContainsModuleLoad(stmt, module_id)) return true;
        }
        return false;
    }

    fn stmtContainsModuleLoad(stmt: ast.Stmt, module_id: []const u8) bool {
        return switch (stmt) {
            .var_decl => |decl| exprContainsModuleLoad(decl.init, module_id),
            .assign => |assign| exprContainsModuleLoad(assign.value, module_id),
            inline .add_assign, .sub_assign, .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => |assign| exprContainsModuleLoad(assign.value, module_id),
            .deref_assign => |assign| exprContainsModuleLoad(assign.target, module_id) or exprContainsModuleLoad(assign.value, module_id),
            .array_assign, .array_add_assign, .array_sub_assign, .array_mul_assign, .array_bit_and_assign, .array_bit_or_assign, .array_bit_xor_assign, .array_shl_assign, .array_shr_assign => |assign| exprContainsModuleLoad(assign.index, module_id) or exprContainsModuleLoad(assign.value, module_id),
            .array_field_assign => |assign| exprContainsModuleLoad(assign.index, module_id) or exprContainsModuleLoad(assign.value, module_id),
            .while_stmt => |while_stmt| exprContainsModuleLoad(while_stmt.condition, module_id) or stmtsContainModuleLoad(while_stmt.body, module_id),
            .for_stmt => |for_stmt| stmtsContainModuleLoad(for_stmt.body, module_id),
            .switch_stmt => |switch_stmt| blk: {
                if (exprContainsModuleLoad(switch_stmt.operand, module_id)) break :blk true;
                for (switch_stmt.prongs) |prong| if (stmtsContainModuleLoad(prong.body, module_id)) break :blk true;
                break :blk false;
            },
            .if_stmt => |if_stmt| exprContainsModuleLoad(if_stmt.condition, module_id) or stmtsContainModuleLoad(if_stmt.then_body, module_id) or stmtsContainModuleLoad(if_stmt.else_body, module_id),
            .discard, .return_expr => |expr| exprContainsModuleLoad(expr, module_id),
            .break_expr => |break_expr| exprContainsModuleLoad(break_expr.value, module_id),
            .field_assign => |field| exprContainsModuleLoad(field.value, module_id),
            .heap_free => |free| exprContainsModuleLoad(free.ptr.*, module_id),
            .struct_var => |struct_var| blk: {
                for (struct_var.fields) |field| if (exprContainsModuleLoad(field.value, module_id)) break :blk true;
                break :blk false;
            },
            .test6502 => |call| test6502ContainsModuleLoad(call, module_id),
            .call, .builtin, .reu, .inline_asm, .string_var, .string_assign, .reu_heap_reset, .heap_reset, .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph, .break_stmt, .continue_stmt => false,
        };
    }

    fn exprContainsModuleLoad(expr: ast.Expr, module_id: []const u8) bool {
        return switch (expr) {
            .module_load, .module_disk_load => true,
            .module_load_dependency, .module_acquire_dependency => |load| load.from_binding and std.mem.eql(u8, load.id, module_id),
            inline .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| exprContainsModuleLoad(binary.lhs.*, module_id) or exprContainsModuleLoad(binary.rhs.*, module_id),
            .not, .bit_not, .deref, .ptr_from_int, .int_from_ptr => |child| exprContainsModuleLoad(child.*, module_id),
            .as_cast => |cast| exprContainsModuleLoad(cast.expr.*, module_id),
            .if_expr => |if_expr| exprContainsModuleLoad(if_expr.condition.*, module_id) or exprContainsModuleLoad(if_expr.then_expr.*, module_id) or exprContainsModuleLoad(if_expr.else_expr.*, module_id),
            .switch_expr => |switch_expr| blk: {
                if (exprContainsModuleLoad(switch_expr.operand.*, module_id)) break :blk true;
                for (switch_expr.prongs) |prong| if (exprContainsModuleLoad(prong.value, module_id)) break :blk true;
                break :blk false;
            },
            .block_expr => |block_expr| stmtsContainModuleLoad(block_expr.body, module_id),
            .call => |call| blk: {
                for (call.args) |arg| if (exprContainsModuleLoad(arg, module_id)) break :blk true;
                break :blk false;
            },
            .array_literal => |literal| blk: {
                for (literal.values) |value| if (exprContainsModuleLoad(value, module_id)) break :blk true;
                break :blk false;
            },
            .struct_literal => |literal| blk: {
                for (literal.fields) |field| if (exprContainsModuleLoad(field.value, module_id)) break :blk true;
                break :blk false;
            },
            .array_index => |index| exprContainsModuleLoad(index.index.*, module_id),
            .array_field_index => |index| exprContainsModuleLoad(index.index.*, module_id),
            .reu_compare => |transfer| exprContainsModuleLoad(transfer.c64_addr.*, module_id) or exprContainsModuleLoad(transfer.len.*, module_id),
            .reu_heap_alloc => |alloc| exprContainsModuleLoad(alloc.len.*, module_id),
            .reu_view => |view| exprContainsModuleLoad(view.far.*, module_id),
            .far_view_materialize_range => |range| exprContainsModuleLoad(range.start.*, module_id),
            .module_call => |call| blk: {
                for (call.args) |arg| if (exprContainsModuleLoad(arg, module_id)) break :blk true;
                break :blk false;
            },
            .heap_alloc => |alloc| exprContainsModuleLoad(alloc.len.*, module_id),
            else => false,
        };
    }

    fn stmtsContainModuleDiskLoad(statements: []const ast.Stmt) bool {
        for (statements) |stmt| {
            if (stmtContainsModuleDiskLoad(stmt)) return true;
        }
        return false;
    }

    fn stmtContainsModuleDiskLoad(stmt: ast.Stmt) bool {
        return switch (stmt) {
            .var_decl => |decl| exprContainsModuleDiskLoad(decl.init),
            .assign => |assign| exprContainsModuleDiskLoad(assign.value),
            inline .add_assign, .sub_assign, .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => |assign| exprContainsModuleDiskLoad(assign.value),
            .deref_assign => |assign| exprContainsModuleDiskLoad(assign.target) or exprContainsModuleDiskLoad(assign.value),
            .array_assign, .array_add_assign, .array_sub_assign, .array_mul_assign, .array_bit_and_assign, .array_bit_or_assign, .array_bit_xor_assign, .array_shl_assign, .array_shr_assign => |assign| exprContainsModuleDiskLoad(assign.index) or exprContainsModuleDiskLoad(assign.value),
            .array_field_assign => |assign| exprContainsModuleDiskLoad(assign.index) or exprContainsModuleDiskLoad(assign.value),
            .while_stmt => |while_stmt| exprContainsModuleDiskLoad(while_stmt.condition) or stmtsContainModuleDiskLoad(while_stmt.body),
            .for_stmt => |for_stmt| stmtsContainModuleDiskLoad(for_stmt.body),
            .switch_stmt => |switch_stmt| blk: {
                if (exprContainsModuleDiskLoad(switch_stmt.operand)) break :blk true;
                for (switch_stmt.prongs) |prong| if (stmtsContainModuleDiskLoad(prong.body)) break :blk true;
                break :blk false;
            },
            .if_stmt => |if_stmt| exprContainsModuleDiskLoad(if_stmt.condition) or stmtsContainModuleDiskLoad(if_stmt.then_body) or stmtsContainModuleDiskLoad(if_stmt.else_body),
            .discard, .return_expr => |expr| exprContainsModuleDiskLoad(expr),
            .break_expr => |break_expr| exprContainsModuleDiskLoad(break_expr.value),
            .field_assign => |field| exprContainsModuleDiskLoad(field.value),
            .heap_free => |free| exprContainsModuleDiskLoad(free.ptr.*),
            .struct_var => |struct_var| blk: {
                for (struct_var.fields) |field| if (exprContainsModuleDiskLoad(field.value)) break :blk true;
                break :blk false;
            },
            .test6502 => |call| test6502ContainsModuleDiskLoad(call),
            .call, .builtin, .reu, .inline_asm, .string_var, .string_assign, .reu_heap_reset, .heap_reset, .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph, .break_stmt, .continue_stmt => false,
        };
    }

    fn exprContainsModuleDiskLoad(expr: ast.Expr) bool {
        return switch (expr) {
            .module_disk_load => true,
            inline .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| exprContainsModuleDiskLoad(binary.lhs.*) or exprContainsModuleDiskLoad(binary.rhs.*),
            .not, .bit_not, .deref, .ptr_from_int, .int_from_ptr => |child| exprContainsModuleDiskLoad(child.*),
            .as_cast => |cast| exprContainsModuleDiskLoad(cast.expr.*),
            .if_expr => |if_expr| exprContainsModuleDiskLoad(if_expr.condition.*) or exprContainsModuleDiskLoad(if_expr.then_expr.*) or exprContainsModuleDiskLoad(if_expr.else_expr.*),
            .switch_expr => |switch_expr| blk: {
                if (exprContainsModuleDiskLoad(switch_expr.operand.*)) break :blk true;
                for (switch_expr.prongs) |prong| if (exprContainsModuleDiskLoad(prong.value)) break :blk true;
                break :blk false;
            },
            .block_expr => |block_expr| stmtsContainModuleDiskLoad(block_expr.body),
            .call => |call| blk: {
                for (call.args) |arg| if (exprContainsModuleDiskLoad(arg)) break :blk true;
                break :blk false;
            },
            .array_literal => |literal| blk: {
                for (literal.values) |value| if (exprContainsModuleDiskLoad(value)) break :blk true;
                break :blk false;
            },
            .struct_literal => |literal| blk: {
                for (literal.fields) |field| if (exprContainsModuleDiskLoad(field.value)) break :blk true;
                break :blk false;
            },
            .array_index => |index| exprContainsModuleDiskLoad(index.index.*),
            .array_field_index => |index| exprContainsModuleDiskLoad(index.index.*),
            .reu_compare => |transfer| exprContainsModuleDiskLoad(transfer.c64_addr.*) or exprContainsModuleDiskLoad(transfer.len.*),
            .reu_heap_alloc => |alloc| exprContainsModuleDiskLoad(alloc.len.*),
            .reu_view => |view| exprContainsModuleDiskLoad(view.far.*),
            .far_view_materialize_range => |range| exprContainsModuleDiskLoad(range.start.*),
            .module_call => |call| blk: {
                for (call.args) |arg| if (exprContainsModuleDiskLoad(arg)) break :blk true;
                break :blk false;
            },
            .heap_alloc => |alloc| exprContainsModuleDiskLoad(alloc.len.*),
            else => false,
        };
    }

    fn stmtsContainModuleCall(statements: []const ast.Stmt) bool {
        for (statements) |stmt| {
            if (stmtContainsModuleCall(stmt)) return true;
        }
        return false;
    }

    fn stmtContainsModuleCall(stmt: ast.Stmt) bool {
        return switch (stmt) {
            .var_decl => |decl| exprContainsModuleCall(decl.init),
            .assign => |assign| exprContainsModuleCall(assign.value),
            inline .add_assign, .sub_assign, .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => |assign| exprContainsModuleCall(assign.value),
            .deref_assign => |assign| exprContainsModuleCall(assign.target) or exprContainsModuleCall(assign.value),
            .array_assign, .array_add_assign, .array_sub_assign, .array_mul_assign, .array_bit_and_assign, .array_bit_or_assign, .array_bit_xor_assign, .array_shl_assign, .array_shr_assign => |assign| exprContainsModuleCall(assign.index) or exprContainsModuleCall(assign.value),
            .array_field_assign => |assign| exprContainsModuleCall(assign.index) or exprContainsModuleCall(assign.value),
            .while_stmt => |while_stmt| exprContainsModuleCall(while_stmt.condition) or stmtsContainModuleCall(while_stmt.body),
            .for_stmt => |for_stmt| stmtsContainModuleCall(for_stmt.body),
            .switch_stmt => |switch_stmt| blk: {
                if (exprContainsModuleCall(switch_stmt.operand)) break :blk true;
                for (switch_stmt.prongs) |prong| if (stmtsContainModuleCall(prong.body)) break :blk true;
                break :blk false;
            },
            .if_stmt => |if_stmt| exprContainsModuleCall(if_stmt.condition) or stmtsContainModuleCall(if_stmt.then_body) or stmtsContainModuleCall(if_stmt.else_body),
            .discard, .return_expr => |expr| exprContainsModuleCall(expr),
            .break_expr => |break_expr| exprContainsModuleCall(break_expr.value),
            .field_assign => |field| exprContainsModuleCall(field.value),
            .heap_free => |free| exprContainsModuleCall(free.ptr.*),
            .struct_var => |struct_var| blk: {
                for (struct_var.fields) |field| if (exprContainsModuleCall(field.value)) break :blk true;
                break :blk false;
            },
            .test6502 => |call| test6502ContainsModuleCall(call),
            .call, .builtin, .reu, .inline_asm, .string_var, .string_assign, .reu_heap_reset, .heap_reset, .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph, .break_stmt, .continue_stmt => false,
        };
    }

    fn exprContainsModuleCall(expr: ast.Expr) bool {
        return switch (expr) {
            .module_call => true,
            inline .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| exprContainsModuleCall(binary.lhs.*) or exprContainsModuleCall(binary.rhs.*),
            .not, .bit_not, .deref, .ptr_from_int, .int_from_ptr => |child| exprContainsModuleCall(child.*),
            .as_cast => |cast| exprContainsModuleCall(cast.expr.*),
            .if_expr => |if_expr| exprContainsModuleCall(if_expr.condition.*) or exprContainsModuleCall(if_expr.then_expr.*) or exprContainsModuleCall(if_expr.else_expr.*),
            .switch_expr => |switch_expr| blk: {
                if (exprContainsModuleCall(switch_expr.operand.*)) break :blk true;
                for (switch_expr.prongs) |prong| if (exprContainsModuleCall(prong.value)) break :blk true;
                break :blk false;
            },
            .block_expr => |block_expr| stmtsContainModuleCall(block_expr.body),
            .call => |call| blk: {
                for (call.args) |arg| if (exprContainsModuleCall(arg)) break :blk true;
                break :blk false;
            },
            .array_literal => |literal| blk: {
                for (literal.values) |value| if (exprContainsModuleCall(value)) break :blk true;
                break :blk false;
            },
            .struct_literal => |literal| blk: {
                for (literal.fields) |field| if (exprContainsModuleCall(field.value)) break :blk true;
                break :blk false;
            },
            .array_index => |index| exprContainsModuleCall(index.index.*),
            .array_field_index => |index| exprContainsModuleCall(index.index.*),
            .reu_compare => |transfer| exprContainsModuleCall(transfer.c64_addr.*) or exprContainsModuleCall(transfer.len.*),
            .reu_heap_alloc => |alloc| exprContainsModuleCall(alloc.len.*),
            .reu_view => |view| exprContainsModuleCall(view.far.*),
            .far_view_materialize_range => |range| exprContainsModuleCall(range.start.*),
            .heap_alloc => |alloc| exprContainsModuleCall(alloc.len.*),
            else => false,
        };
    }

    fn stmtsContainModuleRegistry(statements: []const ast.Stmt) bool {
        for (statements) |stmt| {
            if (stmtContainsModuleRegistry(stmt)) return true;
        }
        return false;
    }

    fn stmtContainsModuleRegistry(stmt: ast.Stmt) bool {
        return switch (stmt) {
            .var_decl => |decl| exprContainsModuleRegistry(decl.init),
            .assign => |assign| exprContainsModuleRegistry(assign.value),
            inline .add_assign, .sub_assign, .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => |assign| exprContainsModuleRegistry(assign.value),
            .deref_assign => |assign| exprContainsModuleRegistry(assign.target) or exprContainsModuleRegistry(assign.value),
            .array_assign, .array_add_assign, .array_sub_assign, .array_mul_assign, .array_bit_and_assign, .array_bit_or_assign, .array_bit_xor_assign, .array_shl_assign, .array_shr_assign => |assign| exprContainsModuleRegistry(assign.index) or exprContainsModuleRegistry(assign.value),
            .array_field_assign => |assign| exprContainsModuleRegistry(assign.index) or exprContainsModuleRegistry(assign.value),
            .while_stmt => |while_stmt| exprContainsModuleRegistry(while_stmt.condition) or stmtsContainModuleRegistry(while_stmt.body),
            .for_stmt => |for_stmt| stmtsContainModuleRegistry(for_stmt.body),
            .switch_stmt => |switch_stmt| blk: {
                if (exprContainsModuleRegistry(switch_stmt.operand)) break :blk true;
                for (switch_stmt.prongs) |prong| if (stmtsContainModuleRegistry(prong.body)) break :blk true;
                break :blk false;
            },
            .if_stmt => |if_stmt| exprContainsModuleRegistry(if_stmt.condition) or stmtsContainModuleRegistry(if_stmt.then_body) or stmtsContainModuleRegistry(if_stmt.else_body),
            .discard, .return_expr => |expr| exprContainsModuleRegistry(expr),
            .break_expr => |break_expr| exprContainsModuleRegistry(break_expr.value),
            .field_assign => |field| exprContainsModuleRegistry(field.value),
            .heap_free => |free| exprContainsModuleRegistry(free.ptr.*),
            .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph => true,
            .struct_var => |struct_var| blk: {
                for (struct_var.fields) |field| if (exprContainsModuleRegistry(field.value)) break :blk true;
                break :blk false;
            },
            .test6502 => |call| test6502ContainsModuleRegistry(call),
            .call, .builtin, .reu, .inline_asm, .string_var, .string_assign, .reu_heap_reset, .heap_reset, .break_stmt, .continue_stmt => false,
        };
    }

    fn exprContainsModuleRegistry(expr: ast.Expr) bool {
        return switch (expr) {
            .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded => true,
            inline .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| exprContainsModuleRegistry(binary.lhs.*) or exprContainsModuleRegistry(binary.rhs.*),
            .not, .bit_not, .deref, .ptr_from_int, .int_from_ptr => |child| exprContainsModuleRegistry(child.*),
            .as_cast => |cast| exprContainsModuleRegistry(cast.expr.*),
            .if_expr => |if_expr| exprContainsModuleRegistry(if_expr.condition.*) or exprContainsModuleRegistry(if_expr.then_expr.*) or exprContainsModuleRegistry(if_expr.else_expr.*),
            .switch_expr => |switch_expr| blk: {
                if (exprContainsModuleRegistry(switch_expr.operand.*)) break :blk true;
                for (switch_expr.prongs) |prong| if (exprContainsModuleRegistry(prong.value)) break :blk true;
                break :blk false;
            },
            .block_expr => |block_expr| stmtsContainModuleRegistry(block_expr.body),
            .call => |call| blk: {
                for (call.args) |arg| if (exprContainsModuleRegistry(arg)) break :blk true;
                break :blk false;
            },
            .array_literal => |literal| blk: {
                for (literal.values) |value| if (exprContainsModuleRegistry(value)) break :blk true;
                break :blk false;
            },
            .struct_literal => |literal| blk: {
                for (literal.fields) |field| if (exprContainsModuleRegistry(field.value)) break :blk true;
                break :blk false;
            },
            .array_index => |index| exprContainsModuleRegistry(index.index.*),
            .array_field_index => |index| exprContainsModuleRegistry(index.index.*),
            .reu_compare => |transfer| exprContainsModuleRegistry(transfer.c64_addr.*) or exprContainsModuleRegistry(transfer.len.*),
            .reu_heap_alloc => |alloc| exprContainsModuleRegistry(alloc.len.*),
            .reu_view => |view| exprContainsModuleRegistry(view.far.*),
            .far_view_materialize_range => |range| exprContainsModuleRegistry(range.start.*),
            .module_call => |call| blk: {
                for (call.args) |arg| if (exprContainsModuleRegistry(arg)) break :blk true;
                break :blk false;
            },
            .heap_alloc => |alloc| exprContainsModuleRegistry(alloc.len.*),
            else => false,
        };
    }

    fn test6502ContainsModuleLoad(call: ast.Test6502Call, module_id: []const u8) bool {
        return switch (call) {
            .expect_null => |expect| exprContainsModuleLoad(expect.actual, module_id),
            .expect_some_u8 => |expect| exprContainsModuleLoad(expect.actual, module_id),
            .expect_some_u16 => |expect| exprContainsModuleLoad(expect.actual, module_id),
            .expect_some_bool => |expect| exprContainsModuleLoad(expect.actual, module_id),
            .expect_some_ptr => |expect| exprContainsModuleLoad(expect.actual, module_id),
            .expect_equal_u8 => |expect| exprContainsModuleLoad(expect.actual, module_id),
            .expect_equal_i8 => |expect| exprContainsModuleLoad(expect.actual, module_id),
            .expect_equal_bool => |expect| exprContainsModuleLoad(expect.actual, module_id),
            .expect_equal_u16 => |expect| exprContainsModuleLoad(expect.actual, module_id),
            else => false,
        };
    }

    fn test6502ContainsModuleDiskLoad(call: ast.Test6502Call) bool {
        return switch (call) {
            .expect_null => |expect| exprContainsModuleDiskLoad(expect.actual),
            .expect_some_u8 => |expect| exprContainsModuleDiskLoad(expect.actual),
            .expect_some_u16 => |expect| exprContainsModuleDiskLoad(expect.actual),
            .expect_some_bool => |expect| exprContainsModuleDiskLoad(expect.actual),
            .expect_some_ptr => |expect| exprContainsModuleDiskLoad(expect.actual),
            .expect_equal_u8 => |expect| exprContainsModuleDiskLoad(expect.actual),
            .expect_equal_i8 => |expect| exprContainsModuleDiskLoad(expect.actual),
            .expect_equal_bool => |expect| exprContainsModuleDiskLoad(expect.actual),
            .expect_equal_u16 => |expect| exprContainsModuleDiskLoad(expect.actual),
            else => false,
        };
    }

    fn test6502ContainsModuleCall(call: ast.Test6502Call) bool {
        return switch (call) {
            .expect_null => |expect| exprContainsModuleCall(expect.actual),
            .expect_some_u8 => |expect| exprContainsModuleCall(expect.actual),
            .expect_some_u16 => |expect| exprContainsModuleCall(expect.actual),
            .expect_some_bool => |expect| exprContainsModuleCall(expect.actual),
            .expect_some_ptr => |expect| exprContainsModuleCall(expect.actual),
            .expect_equal_u8 => |expect| exprContainsModuleCall(expect.actual),
            .expect_equal_i8 => |expect| exprContainsModuleCall(expect.actual),
            .expect_equal_bool => |expect| exprContainsModuleCall(expect.actual),
            .expect_equal_u16 => |expect| exprContainsModuleCall(expect.actual),
            else => false,
        };
    }

    fn test6502ContainsModuleRegistry(call: ast.Test6502Call) bool {
        return switch (call) {
            .expect_null => |expect| exprContainsModuleRegistry(expect.actual),
            .expect_some_u8 => |expect| exprContainsModuleRegistry(expect.actual),
            .expect_some_u16 => |expect| exprContainsModuleRegistry(expect.actual),
            .expect_some_bool => |expect| exprContainsModuleRegistry(expect.actual),
            .expect_some_ptr => |expect| exprContainsModuleRegistry(expect.actual),
            .expect_equal_u8 => |expect| exprContainsModuleRegistry(expect.actual),
            .expect_equal_i8 => |expect| exprContainsModuleRegistry(expect.actual),
            .expect_equal_bool => |expect| exprContainsModuleRegistry(expect.actual),
            .expect_equal_u16 => |expect| exprContainsModuleRegistry(expect.actual),
            else => false,
        };
    }

    fn functionUsesSoftwareStack(self: *Emitter, function_name: []const u8) bool {
        return frame_layout.effectivePolicy(self.program, function_name) == .stack;
    }

    fn usesReuRuntime(self: *Emitter) bool {
        return self.uses_reu_present or
            self.usesReuTransferRuntime() or
            self.usesReuHeapRuntime() or
            self.uses_reu_view_runtime or
            self.uses_module_registry_runtime;
    }

    fn currentModuleState(self: *Emitter) ?ast.CurrentModuleState {
        const modules = self.program.zeropage_options.modules orelse return null;
        const state = modules.state orelse return null;
        if (state.current.mode != .persist_in_reu) return null;
        return state.current;
    }

    fn dependencyModuleState(self: *Emitter, row: usize) ?ast.CurrentModuleState {
        if (row == 0) return null;
        const module = self.program.zeropage_module orelse return null;
        if (row > module.deps.len) return null;
        const modules = self.program.zeropage_options.modules orelse return null;
        const state = modules.state orelse return null;
        const dep_id = module.deps[row - 1];
        for (state.deps) |dep_state| {
            if (std.mem.eql(u8, dep_state.id, dep_id)) {
                if (dep_state.state.mode != .persist_in_reu) return null;
                return dep_state.state;
            }
        }
        return null;
    }

    fn hasPersistentDependencyModuleState(self: *Emitter) bool {
        const module = self.program.zeropage_module orelse return false;
        for (1..module.deps.len + 1) |row| {
            if (self.dependencyModuleState(row) != null) return true;
        }
        return false;
    }

    fn moduleStateRegistryRows(self: *Emitter) u32 {
        const modules = self.program.zeropage_options.modules.?;
        return if (modules.registry != null and modules.disk_manifest != null and self.program.zeropage_module != null)
            modules.registry.?.capacity
        else
            1;
    }

    fn moduleStateSnapshotReuAddr(self: *Emitter) u32 {
        const modules = self.program.zeropage_options.modules.?;
        return modules.reu_cache.addr + self.moduleStateRegistryRows() * @as(u32, modules.load_window.size);
    }

    fn moduleDependencyStateSnapshotReuAddr(self: *Emitter, row: usize) u32 {
        const modules = self.program.zeropage_options.modules.?;
        const dep_index: u32 = @intCast(row - 1);
        return modules.reu_cache.addr +
            (self.moduleStateRegistryRows() + 1 + dep_index) * @as(u32, modules.load_window.size);
    }

    pub fn usesReuTransferRuntime(self: *Emitter) bool {
        return self.uses_reu_copy_c64_to_reu or
            self.uses_reu_copy_reu_to_c64 or
            self.uses_reu_swap or
            self.uses_reu_compare or
            self.uses_reu_fill;
    }

    fn usesHeapRuntime(self: *Emitter) bool {
        return self.usesHeapAllocRuntime() or self.usesHeapResetRuntime() or self.usesHeapFreeRuntime();
    }

    fn usesReuHeapRuntime(self: *Emitter) bool {
        return self.usesReuHeapAllocRuntime() or self.usesReuHeapResetRuntime();
    }

    pub fn usesReuHeapAllocRuntime(self: *Emitter) bool {
        return self.reu_heap_alloc_names.count() != 0;
    }

    pub fn usesReuHeapResetRuntime(self: *Emitter) bool {
        return self.reu_heap_reset_names.count() != 0;
    }

    pub fn reuHeapUsesAllocRuntime(self: *Emitter, name: []const u8) bool {
        return self.reu_heap_alloc_names.contains(name);
    }

    pub fn reuHeapUsesResetRuntime(self: *Emitter, name: []const u8) bool {
        return self.reu_heap_reset_names.contains(name);
    }

    pub fn usesHeapAllocRuntime(self: *Emitter) bool {
        return self.heap_alloc_names.count() != 0;
    }

    pub fn usesHeapResetRuntime(self: *Emitter) bool {
        return self.heap_reset_names.count() != 0;
    }

    pub fn usesHeapFreeRuntime(self: *Emitter) bool {
        return self.heap_free_names.count() != 0;
    }

    pub fn heapUsesAllocRuntime(self: *Emitter, name: []const u8) bool {
        return self.heap_alloc_names.contains(name);
    }

    pub fn heapUsesResetRuntime(self: *Emitter, name: []const u8) bool {
        return self.heap_reset_names.contains(name);
    }

    pub fn heapUsesFreeRuntime(self: *Emitter, name: []const u8) bool {
        return self.heap_free_names.contains(name);
    }

    fn emitFunction(self: *Emitter, function: ast.Function) !void {
        const w = &self.out.writer;
        try sections.emitBegin(w, .{ .function = function.name }, .code, .static, .near);
        try w.print("{s}:\n", .{function.name});
        if (std.mem.eql(u8, function.name, "main") and self.programUsesSoftwareStack()) {
            try self.emitSoftwareStackInit();
        }
        try self.emitStmtList(function.name, function.body);
        if (std.mem.eql(u8, function.name, "main")) try w.writeAll("zeropage_test_exit:\n");
        try w.writeAll("    rts\n\n");
        try sections.emitEnd(w, .{ .function = function.name }, .code);
    }

    fn emitSoftwareStackMain(self: *Emitter, function: ast.Function) !void {
        var layout = try frame_layout.planFunction(self.allocator, self.program, function, .stack);
        defer layout.deinit(self.allocator);
        if (layout.byte_size > 255) return error.UnsupportedStackFrameTooLarge;

        const w = &self.out.writer;
        try sections.emitBegin(w, .{ .function = function.name }, .code, .static, .near);
        try w.print("{s}:\n", .{function.name});
        try self.emitSoftwareStackInit();
        try self.emitSoftwareStackPrologue(layout);
        try self.emitSoftwareStackStmtList(function.name, layout, function.body, true);
        try self.emitSoftwareStackEpilogue();
        try w.writeAll("zeropage_test_exit:\n    rts\n\n");
        try sections.emitEnd(w, .{ .function = function.name }, .code);
    }

    fn emitSoftwareStackHelper(self: *Emitter, function: ast.Function) !void {
        var layout = try frame_layout.planFunction(self.allocator, self.program, function, .stack);
        defer layout.deinit(self.allocator);
        if (layout.byte_size > 255) return error.UnsupportedStackFrameTooLarge;

        const w = &self.out.writer;
        try sections.emitBegin(w, .{ .function = function.name }, .code, .static, .near);
        try w.print("{s}:\n", .{function.name});
        try self.emitSoftwareStackStmtList(function.name, layout, function.body, false);
        try w.writeAll("    rts\n\n");
        try sections.emitEnd(w, .{ .function = function.name }, .code);
    }

    fn emitSoftwareStackInit(self: *Emitter) !void {
        const w = &self.out.writer;
        const stack = self.program.zeropage_options.stack.?;
        try w.print(
            \\    lda #${x:0>2}
            \\    sta zeropage_stack_sp
            \\    sta zeropage_stack_fp
            \\    lda #${x:0>2}
            \\    sta zeropage_stack_sp+1
            \\    sta zeropage_stack_fp+1
            \\
        , .{ @as(u8, @truncate(stack.base)), @as(u8, @truncate(stack.base >> 8)) });
    }

    fn emitSoftwareStackPrologue(self: *Emitter, layout: frame_layout.FrameLayout) !void {
        const w = &self.out.writer;
        try w.writeAll(
            \\    lda zeropage_stack_sp
            \\    sta zeropage_stack_fp
            \\    lda zeropage_stack_sp+1
            \\    sta zeropage_stack_fp+1
            \\
        );
        try self.emitSoftwareStackAdvanceStackPointer(layout.byte_size);
    }

    fn emitSoftwareStackEpilogue(self: *Emitter) !void {
        try self.out.writer.writeAll(
            \\    lda zeropage_stack_fp
            \\    sta zeropage_stack_sp
            \\    lda zeropage_stack_fp+1
            \\    sta zeropage_stack_sp+1
            \\
        );
    }

    fn emitSoftwareStackStmtList(self: *Emitter, function_name: []const u8, layout: frame_layout.FrameLayout, statements: []const ast.Stmt, release_stack_on_return: bool) anyerror!void {
        for (statements) |stmt| try self.emitSoftwareStackStmt(function_name, layout, stmt, release_stack_on_return);
    }

    fn emitSoftwareStackStmt(self: *Emitter, function_name: []const u8, layout: frame_layout.FrameLayout, stmt: ast.Stmt, release_stack_on_return: bool) anyerror!void {
        switch (stmt) {
            .var_decl => |decl| {
                const ty = decl.ty orelse try self.exprType(function_name, decl.init);
                try self.emitSoftwareStackExprExpected(function_name, layout, decl.init, ty);
                try self.storeSoftwareStackSlot(layout, decl.name, ty);
            },
            .assign => |assign| {
                const slot = layout.findSlot(assign.name) orelse return error.UnknownVariable;
                try self.emitSoftwareStackExprExpected(function_name, layout, assign.value, slot.ty);
                try self.storeSoftwareStackSlot(layout, assign.name, slot.ty);
            },
            .add_assign => |assign| try self.emitSoftwareStackAddSubAssign(function_name, layout, assign, .add),
            .sub_assign => |assign| try self.emitSoftwareStackAddSubAssign(function_name, layout, assign, .sub),
            .while_stmt => |while_stmt| try self.emitSoftwareStackWhile(function_name, layout, while_stmt, release_stack_on_return),
            .for_stmt => |for_stmt| try self.emitSoftwareStackFor(function_name, layout, for_stmt, release_stack_on_return),
            .if_stmt => |if_stmt| try self.emitSoftwareStackIf(function_name, layout, if_stmt, release_stack_on_return),
            .switch_stmt => |switch_stmt| try self.emitSoftwareStackSwitch(function_name, layout, switch_stmt, release_stack_on_return),
            .discard => |expr| try self.emitSoftwareStackExpr(function_name, layout, expr),
            .return_expr => |expr| {
                const return_ty = try self.exprType(function_name, expr);
                try self.emitSoftwareStackExprExpected(function_name, layout, expr, return_ty);
                if (release_stack_on_return) try self.emitSoftwareStackEpilogue();
                try self.out.writer.writeAll("    rts\n");
            },
            .test6502 => |call| try self.emitSoftwareStackTest6502Call(function_name, layout, call),
            .reu => return error.UnsupportedStackFrameRuntimeCall,
            .reu_heap_reset => return error.UnsupportedStackFrameRuntimeCall,
            .heap_reset => return error.UnsupportedStackFrameRuntimeCall,
            .heap_free => return error.UnsupportedStackFrameRuntimeCall,
            .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph => return error.UnsupportedStackFrameRuntimeCall,
            .field_assign => |field| switch (field.path) {
                .c64_vic_border => {
                    try self.emitSoftwareStackExpr(function_name, layout, field.value);
                    try self.out.writer.writeAll("    sta $d020\n");
                },
            },
            .break_stmt => {
                const loop = self.currentLoop() orelse return error.BreakOutsideLoop;
                try self.emitLoopBreak(loop);
            },
            .continue_stmt => {
                const loop = self.currentLoop() orelse return error.ContinueOutsideLoop;
                try self.emitLoopContinue(loop);
            },
            .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => return error.UnsupportedStackFrameType,
            .string_var, .string_assign => return error.UnsupportedStackFrameString,
            .struct_var, .array_assign, .array_add_assign, .array_sub_assign, .array_mul_assign, .array_bit_and_assign, .array_bit_or_assign, .array_bit_xor_assign, .array_shl_assign, .array_shr_assign, .array_field_assign => return error.UnsupportedStackFrameAggregate,
            .call => |call| try self.emitSoftwareStackCall(function_name, layout, call),
            .builtin => |builtin| try self.emitSoftwareStackBuiltin(function_name, builtin),
            .deref_assign => return error.UnsupportedStackFrameCall,
            .break_expr, .inline_asm => return error.UnsupportedStackFrameType,
        }
    }

    fn emitSoftwareStackBuiltin(self: *Emitter, function_name: []const u8, builtin: ast.BuiltinCall) !void {
        switch (builtin) {
            .console_clear => try self.emitBuiltin(function_name, builtin),
            .console_print => |print| {
                for (print.args) |arg| switch (arg) {
                    .string => {},
                    .value => return error.UnsupportedStackFrameCall,
                };
                try self.emitBuiltin(function_name, builtin);
            },
            .console_puts => try self.emitBuiltin(function_name, builtin),
            else => return error.UnsupportedStackFrameCall,
        }
    }

    const StackMathOp = enum { add, sub };

    fn emitSoftwareStackAddSubAssign(self: *Emitter, function_name: []const u8, layout: frame_layout.FrameLayout, assign: ast.AddAssign, op: StackMathOp) !void {
        const slot = layout.findSlot(assign.name) orelse return error.UnknownVariable;
        if (try self.tryEmitSoftwareStackDirectWord(layout, assign.name, assign.value, op)) {
            return self.storeSoftwareStackSlot(layout, assign.name, slot.ty);
        }
        try self.emitSoftwareStackExprExpected(function_name, layout, assign.value, slot.ty);
        if (self.stackTyIsWide(slot.ty)) {
            try self.storeSoftwareStackScratchAX(layout, "zeropage_math_tmp");
            try self.loadSoftwareStackSlotAX(layout, assign.name);
            try self.emitSoftwareStackMathScratchWord(layout, op);
        } else {
            try self.storeSoftwareStackScratchA(layout, "zeropage_math_tmp");
            try self.loadSoftwareStackSlotA(layout, assign.name);
            const scratch = layout.findSlot("zeropage_math_tmp") orelse return error.MissingStackScratch;
            try self.out.writer.print("    ldy #${x:0>2}\n", .{@as(u8, @truncate(scratch.offset))});
            switch (op) {
                .add => try self.out.writer.writeAll("    clc\n    adc (zeropage_stack_fp),y\n"),
                .sub => try self.out.writer.writeAll("    sec\n    sbc (zeropage_stack_fp),y\n"),
            }
        }
        try self.storeSoftwareStackSlot(layout, assign.name, slot.ty);
    }

    fn emitSoftwareStackWhile(self: *Emitter, function_name: []const u8, layout: frame_layout.FrameLayout, while_stmt: ast.WhileStmt, release_stack_on_return: bool) !void {
        const id = self.nextLabel();
        try self.out.writer.print("while_{d}_start:\n", .{id});
        var target: [64]u8 = undefined;
        try self.emitSoftwareStackCondition(function_name, layout, while_stmt.condition, try std.fmt.bufPrint(&target, "while_{d}_end", .{id}));
        try self.loop_stack.append(self.allocator, .{ .kind = .stack_while, .id = id });
        defer _ = self.loop_stack.pop();
        try self.emitSoftwareStackStmtList(function_name, layout, while_stmt.body, release_stack_on_return);
        try self.out.writer.print("    jmp while_{d}_start\nwhile_{d}_end:\n", .{ id, id });
    }

    fn emitSoftwareStackIf(self: *Emitter, function_name: []const u8, layout: frame_layout.FrameLayout, if_stmt: ast.IfStmt, release_stack_on_return: bool) !void {
        if (if_stmt.payload_name != null) return error.UnsupportedStackFrameOptional;
        const id = self.nextLabel();
        var target: [64]u8 = undefined;
        try self.emitSoftwareStackCondition(function_name, layout, if_stmt.condition, try std.fmt.bufPrint(&target, "if_{d}_else", .{id}));
        try self.emitSoftwareStackStmtList(function_name, layout, if_stmt.then_body, release_stack_on_return);
        try self.out.writer.print("    jmp if_{d}_end\nif_{d}_else:\n", .{ id, id });
        try self.emitSoftwareStackStmtList(function_name, layout, if_stmt.else_body, release_stack_on_return);
        try self.out.writer.print("if_{d}_end:\n", .{id});
    }

    fn emitSoftwareStackCondition(self: *Emitter, function_name: []const u8, layout: frame_layout.FrameLayout, expr: ast.Expr, no: []const u8) !void {
        if (try self.tryEmitSoftwareStackCompareBranch(layout, expr, no)) return;
        try self.emitSoftwareStackExpr(function_name, layout, expr);
        try self.out.writer.print("    cmp #0\n    beq {s}\n", .{no});
    }

    fn stackByteOffset(layout: frame_layout.FrameLayout, expr: ast.Expr) ?u8 {
        if (expr != .value or expr.value != .ident) return null;
        const slot = layout.findSlot(expr.value.ident) orelse return null;
        if (slot.ty != .u8 or (slot.kind != .param and slot.kind != .local)) return null;
        return @intCast(slot.offset);
    }

    fn tryEmitSoftwareStackCompareBranch(self: *Emitter, layout: frame_layout.FrameLayout, expr: ast.Expr, no: []const u8) !bool {
        const op: CompareOp, const binary = switch (expr) {
            inline .eq, .ne, .lt, .lte, .gt, .gte => |pair, tag| .{ @field(CompareOp, @tagName(tag)), pair },
            else => return false,
        };
        const lhs = stackByteOffset(layout, binary.lhs.*) orelse return false;
        if (binary.rhs.* != .value) return false;
        const rhs = binary.rhs.value;
        const rhs_slot: ?u8 = switch (rhs) {
            .int => if (rhs.int <= 255) null else return false,
            .ident => stackByteOffset(layout, binary.rhs.*) orelse return false,
            else => return false,
        };
        if (!try self.hasPrivateStackLayout()) return false;

        // Preserve the expression label sequence used by the fallback.
        _ = self.nextLabel();
        const id = self.condition_label_id;
        self.condition_label_id += 1;
        var label: [64]u8 = undefined;
        const yes = try std.fmt.bufPrint(&label, "zeropage_stack_cond_{d}_body", .{id});
        const w = &self.out.writer;
        try w.print("    ldy #${x:0>2}\n    lda (zeropage_stack_fp),y\n", .{lhs});
        if (rhs_slot) |offset| {
            try w.print("    ldy #${x:0>2}\n    cmp (zeropage_stack_fp),y\n", .{offset});
        } else {
            try w.print("    cmp #${x:0>2}\n", .{@as(u8, @intCast(rhs.int))});
        }
        try self.emitConditionFlags(op, yes, no, true);
        try w.print("{s}:\n", .{yes});
        return true;
    }

    fn emitSoftwareStackFor(self: *Emitter, function_name: []const u8, layout: frame_layout.FrameLayout, for_stmt: ast.ForStmt, release_stack_on_return: bool) !void {
        const range_end = switch (for_stmt.source) {
            .range => |range| switch (range) {
                .int => |n| n,
                .array_len => return error.UnsupportedStackFrameAggregate,
            },
            .array, .array_indexed => return error.UnsupportedStackFrameAggregate,
        };
        if (range_end > 255) return error.UnsupportedStackFrameType;
        const index_name = try std.fmt.allocPrint(self.allocator, "{s}_for_{d}_index", .{ function_name, for_stmt.id });
        defer self.allocator.free(index_name);
        try self.out.writer.writeAll("    lda #0\n    ldx #0\n");
        try self.storeSoftwareStackSlot(layout, index_name, .usize);
        try self.out.writer.print("for_{d}_start:\n", .{for_stmt.id});
        try self.loadSoftwareStackSlotA(layout, index_name);
        try self.out.writer.print("    cmp #${x:0>2}\n    bcs for_{d}_end\n", .{ @as(u8, @truncate(range_end)), for_stmt.id });
        if (for_stmt.item_name) |name| {
            try self.loadSoftwareStackSlotAX(layout, index_name);
            try self.storeSoftwareStackSlot(layout, name, .usize);
        }
        if (for_stmt.index_name) |name| {
            try self.loadSoftwareStackSlotAX(layout, index_name);
            try self.storeSoftwareStackSlot(layout, name, .usize);
        }
        try self.loop_stack.append(self.allocator, .{ .kind = .for_loop, .id = for_stmt.id });
        defer _ = self.loop_stack.pop();
        try self.emitSoftwareStackStmtList(function_name, layout, for_stmt.body, release_stack_on_return);
        try self.loadSoftwareStackSlotAX(layout, index_name);
        try self.out.writer.writeAll("    clc\n    adc #1\n    bcc *+3\n    inx\n");
        try self.storeSoftwareStackSlot(layout, index_name, .usize);
        try self.out.writer.print("    jmp for_{d}_start\nfor_{d}_end:\n", .{ for_stmt.id, for_stmt.id });
    }

    fn emitSoftwareStackSwitch(self: *Emitter, function_name: []const u8, layout: frame_layout.FrameLayout, switch_stmt: ast.SwitchStmt, release_stack_on_return: bool) !void {
        const id = self.nextLabel();
        try self.emitSoftwareStackExpr(function_name, layout, switch_stmt.operand);
        try self.storeSoftwareStackScratchA(layout, "zeropage_switch_value");
        var else_index: ?usize = null;
        for (switch_stmt.prongs, 0..) |prong, prong_index| {
            for (prong.selectors) |selector| switch (selector) {
                .scalar => |value| {
                    if (prong.payload_name != null) return error.UnsupportedStackFrameType;
                    try self.loadSoftwareStackScratchA(layout, "zeropage_switch_value");
                    try self.out.writer.print("    cmp #${x:0>2}\n    beq stack_switch_{d}_prong_{d}\n", .{ try self.stackSelectorByte(value), id, prong_index });
                },
                .else_prong => else_index = prong_index,
                .range => return error.UnsupportedStackFrameType,
            };
        }
        if (else_index) |else_i| {
            try self.out.writer.print("    jmp stack_switch_{d}_prong_{d}\n", .{ id, else_i });
        } else {
            try self.out.writer.print("    jmp stack_switch_{d}_end\n", .{id});
        }
        for (switch_stmt.prongs, 0..) |prong, prong_index| {
            try self.out.writer.print("stack_switch_{d}_prong_{d}:\n", .{ id, prong_index });
            try self.emitSoftwareStackStmtList(function_name, layout, prong.body, release_stack_on_return);
            try self.out.writer.print("    jmp stack_switch_{d}_end\n", .{id});
        }
        try self.out.writer.print("stack_switch_{d}_end:\n", .{id});
    }

    fn stackSelectorByte(self: *Emitter, value: ast.Value) !u8 {
        return switch (value) {
            .int => |n| std.math.cast(u8, n) orelse return error.UnsupportedStackFrameType,
            .bool => |b| @intFromBool(b),
            .char => |c| c,
            .enum_literal => |literal| blk: {
                if (literal.enum_name) |enum_name| {
                    const decl = self.program.findEnum(enum_name) orelse return error.UnsupportedEnumLiteral;
                    for (decl.tags) |tag| if (std.mem.eql(u8, tag.name, literal.tag)) break :blk tag.value;
                }
                return error.UnsupportedEnumLiteral;
            },
            else => error.UnsupportedStackFrameType,
        };
    }

    fn emitSoftwareStackExprExpected(self: *Emitter, function_name: []const u8, layout: frame_layout.FrameLayout, expr: ast.Expr, expected_ty: ast.Type) anyerror!void {
        switch (expr) {
            .as_cast => |as_cast| {
                _ = try self.validateAsCast(function_name, as_cast);
                return try self.emitSoftwareStackExprExpected(function_name, layout, as_cast.expr.*, as_cast.ty);
            },
            else => {},
        }
        if (self.stackTyIsWide(expected_ty)) {
            try self.emitSoftwareStackExprAX(function_name, layout, expr);
        } else {
            try self.emitSoftwareStackExpr(function_name, layout, expr);
        }
    }

    fn emitSoftwareStackExpr(self: *Emitter, function_name: []const u8, layout: frame_layout.FrameLayout, expr: ast.Expr) anyerror!void {
        const w = &self.out.writer;
        switch (expr) {
            .value => |value| try self.emitSoftwareStackValueA(layout, value),
            .add => |binary| try self.emitSoftwareStackBinaryMathA(function_name, layout, binary, .add),
            .sub => |binary| try self.emitSoftwareStackBinaryMathA(function_name, layout, binary, .sub),
            .eq => |binary| try self.emitSoftwareStackCompare(function_name, layout, binary, .eq),
            .ne => |binary| try self.emitSoftwareStackCompare(function_name, layout, binary, .ne),
            .lt => |binary| try self.emitSoftwareStackCompare(function_name, layout, binary, .lt),
            .lte => |binary| try self.emitSoftwareStackCompare(function_name, layout, binary, .lte),
            .gt => |binary| try self.emitSoftwareStackCompare(function_name, layout, binary, .gt),
            .gte => |binary| try self.emitSoftwareStackCompare(function_name, layout, binary, .gte),
            .bool_and => |binary| {
                const id = self.nextLabel();
                try self.emitSoftwareStackExpr(function_name, layout, binary.lhs.*);
                try w.print("    cmp #0\n    beq stack_bool_{d}_false\n", .{id});
                try self.emitSoftwareStackExpr(function_name, layout, binary.rhs.*);
                try w.print("    cmp #0\n    beq stack_bool_{d}_false\n    lda #1\n    jmp stack_bool_{d}_done\nstack_bool_{d}_false:\n    lda #0\nstack_bool_{d}_done:\n", .{ id, id, id, id });
            },
            .bool_or => |binary| {
                const id = self.nextLabel();
                try self.emitSoftwareStackExpr(function_name, layout, binary.lhs.*);
                try w.print("    cmp #0\n    bne stack_bool_{d}_true\n", .{id});
                try self.emitSoftwareStackExpr(function_name, layout, binary.rhs.*);
                try w.print("    cmp #0\n    bne stack_bool_{d}_true\n    lda #0\n    jmp stack_bool_{d}_done\nstack_bool_{d}_true:\n    lda #1\nstack_bool_{d}_done:\n", .{ id, id, id, id });
            },
            .not => |child| {
                const id = self.nextLabel();
                try self.emitSoftwareStackExpr(function_name, layout, child.*);
                try w.print("    cmp #0\n    beq stack_not_{d}_true\n    lda #0\n    jmp stack_not_{d}_done\nstack_not_{d}_true:\n    lda #1\nstack_not_{d}_done:\n", .{ id, id, id, id });
            },
            .size_of, .align_of, .offset_of => {
                const value = try self.layoutComptimeValue(expr);
                try w.print("    lda #${x:0>2}\n", .{@as(u8, @truncate(value))});
            },
            .as_cast => |as_cast| {
                _ = try self.validateAsCast(function_name, as_cast);
                try self.emitSoftwareStackExprExpected(function_name, layout, as_cast.expr.*, as_cast.ty);
            },
            .if_expr, .switch_expr, .block_expr => return error.UnsupportedStackFrameType,
            .call => |call| try self.emitSoftwareStackCall(function_name, layout, call),
            .c64_read_petscii, .c64_wait_petscii, .reu_present, .reu_compare, .reu_heap_alloc, .reu_view, .far_view_materialize, .far_view_materialize_range, .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded, .module_call, .heap_alloc => return error.UnsupportedStackFrameRuntimeCall,
            .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .bit_not, .deref, .ptr_from_int, .int_from_ptr, .array_literal, .array_index, .array_field_index, .struct_literal => return error.UnsupportedStackFrameType,
            .address_of => return error.UnsupportedStackFrameType,
        }
    }

    fn emitSoftwareStackExprAX(self: *Emitter, function_name: []const u8, layout: frame_layout.FrameLayout, expr: ast.Expr) anyerror!void {
        const w = &self.out.writer;
        switch (expr) {
            .value => |value| try self.emitSoftwareStackValueAX(layout, value),
            inline .add, .sub => |binary, tag| {
                const op: StackMathOp = if (tag == .add) .add else .sub;
                if (binary.lhs.* == .value and binary.lhs.value == .ident and
                    try self.tryEmitSoftwareStackDirectWord(layout, binary.lhs.value.ident, binary.rhs.*, op)) return;
                try self.emitSoftwareStackExprAX(function_name, layout, binary.rhs.*);
                try self.storeSoftwareStackScratchAX(layout, "zeropage_math_tmp");
                try self.emitSoftwareStackExprAX(function_name, layout, binary.lhs.*);
                try self.emitSoftwareStackMathScratchWord(layout, op);
            },
            .size_of, .align_of, .offset_of => {
                const value = try self.layoutComptimeValue(expr);
                try w.print("    ldx #${x:0>2}\n    lda #${x:0>2}\n", .{ @as(u8, @truncate(value >> 8)), @as(u8, @truncate(value)) });
            },
            .as_cast => |as_cast| {
                _ = try self.validateAsCast(function_name, as_cast);
                try self.emitSoftwareStackExprExpected(function_name, layout, as_cast.expr.*, as_cast.ty);
            },
            .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or, .not => {
                try self.emitSoftwareStackExpr(function_name, layout, expr);
                try w.writeAll("    ldx #0\n");
            },
            .address_of => |address| {
                if (!self.addressOfTargetsModuleRoData(address)) return error.UnsupportedStackFrameType;
                try self.emitAddressOfToAX(function_name, address, try self.exprType(function_name, .{ .address_of = address }));
            },
            .int_from_ptr => |child| {
                if (child.* != .address_of or !self.addressOfTargetsModuleRoData(child.*.address_of)) return error.UnsupportedStackFrameType;
                try self.emitExprToAXExpected(function_name, child.*, try self.exprType(function_name, child.*));
            },
            .call => |call| try self.emitSoftwareStackCall(function_name, layout, call),
            else => return error.UnsupportedStackFrameType,
        }
    }

    fn emitSoftwareStackValueA(self: *Emitter, layout: frame_layout.FrameLayout, value: ast.Value) !void {
        const w = &self.out.writer;
        switch (value) {
            .int => |n| try w.print("    lda #${x:0>2}\n", .{@as(u8, @truncate(n))}),
            .bool => |b| try w.print("    lda #{d}\n", .{@intFromBool(b)}),
            .char => |c| try w.print("    lda #${x:0>2}\n", .{c}),
            .ident => |name| try self.loadSoftwareStackSlotA(layout, name),
            .enum_literal => |literal| {
                const n = try self.stackSelectorByte(.{ .enum_literal = literal });
                try w.print("    lda #${x:0>2}\n", .{n});
            },
            .null, .field => return error.UnsupportedStackFrameType,
        }
    }

    fn emitSoftwareStackValueAX(self: *Emitter, layout: frame_layout.FrameLayout, value: ast.Value) !void {
        const w = &self.out.writer;
        switch (value) {
            .int => |n| try w.print("    ldx #${x:0>2}\n    lda #${x:0>2}\n", .{ @as(u8, @truncate(n >> 8)), @as(u8, @truncate(n)) }),
            .ident => |name| try self.loadSoftwareStackSlotAX(layout, name),
            .bool, .char, .enum_literal => {
                try self.emitSoftwareStackValueA(layout, value);
                try w.writeAll("    ldx #0\n");
            },
            .null, .field => return error.UnsupportedStackFrameType,
        }
    }

    fn emitSoftwareStackBinaryMathA(self: *Emitter, function_name: []const u8, layout: frame_layout.FrameLayout, binary: ast.BinaryExpr, op: StackMathOp) !void {
        try self.emitSoftwareStackExpr(function_name, layout, binary.rhs.*);
        try self.storeSoftwareStackScratchA(layout, "zeropage_math_tmp");
        try self.emitSoftwareStackExpr(function_name, layout, binary.lhs.*);
        const scratch = layout.findSlot("zeropage_math_tmp") orelse return error.MissingStackScratch;
        try self.out.writer.print("    ldy #${x:0>2}\n", .{@as(u8, @truncate(scratch.offset))});
        switch (op) {
            .add => try self.out.writer.writeAll("    clc\n    adc (zeropage_stack_fp),y\n"),
            .sub => try self.out.writer.writeAll("    sec\n    sbc (zeropage_stack_fp),y\n"),
        }
    }

    fn emitSoftwareStackCompare(self: *Emitter, function_name: []const u8, layout: frame_layout.FrameLayout, binary: ast.BinaryExpr, op: CompareOp) !void {
        const id = self.nextLabel();
        try self.emitSoftwareStackExpr(function_name, layout, binary.rhs.*);
        try self.storeSoftwareStackScratchA(layout, "zeropage_math_tmp");
        try self.emitSoftwareStackExpr(function_name, layout, binary.lhs.*);
        const scratch = layout.findSlot("zeropage_math_tmp") orelse return error.MissingStackScratch;
        try self.out.writer.print("    ldy #${x:0>2}\n    cmp (zeropage_stack_fp),y\n", .{@as(u8, @truncate(scratch.offset))});
        switch (op) {
            .eq => try self.out.writer.print("    beq stack_cmp_{d}_true\n", .{id}),
            .ne => try self.out.writer.print("    bne stack_cmp_{d}_true\n", .{id}),
            .lt => try self.out.writer.print("    bcc stack_cmp_{d}_true\n", .{id}),
            .lte => try self.out.writer.print("    beq stack_cmp_{d}_true\n    bcc stack_cmp_{d}_true\n", .{ id, id }),
            .gt => try self.out.writer.print("    bne stack_cmp_{d}_maybe\n    jmp stack_cmp_{d}_false\nstack_cmp_{d}_maybe:\n    bcs stack_cmp_{d}_true\n", .{ id, id, id, id }),
            .gte => try self.out.writer.print("    bcs stack_cmp_{d}_true\n", .{id}),
        }
        try self.out.writer.print("stack_cmp_{d}_false:\n    lda #0\n    jmp stack_cmp_{d}_done\nstack_cmp_{d}_true:\n    lda #1\nstack_cmp_{d}_done:\n", .{ id, id, id, id });
    }

    fn loadSoftwareStackSlotA(self: *Emitter, layout: frame_layout.FrameLayout, name: []const u8) !void {
        const slot = layout.findSlot(name) orelse return error.UnknownVariable;
        try self.out.writer.print("    ldy #${x:0>2}\n    lda (zeropage_stack_fp),y\n", .{@as(u8, @truncate(slot.offset))});
    }

    fn optimizeSoftwareStack(self: *const Emitter) bool {
        const options = self.program.zeropage_options;
        const stack = options.stack orelse return false;
        return self.program.zeropage_module == null and options.modules == null and
            options.memory.placements.len == 0 and stack.base >= 0x0200;
    }

    fn loadSoftwareStackSlotAX(self: *Emitter, layout: frame_layout.FrameLayout, name: []const u8) !void {
        const slot = layout.findSlot(name) orelse return error.UnknownVariable;
        const w = &self.out.writer;
        // TAX already captures the high byte. Loading the low byte
        // establishes the same A and N/Z that the old PLA restored.
        try w.print("    ldy #${x:0>2}\n    lda (zeropage_stack_fp),y\n    tax\n    ldy #${x:0>2}\n    lda (zeropage_stack_fp),y\n", .{
            @as(u8, @truncate(slot.offset + 1)),
            @as(u8, @truncate(slot.offset)),
        });
        if (!self.optimizeSoftwareStack()) try w.writeAll("    pha\n    txa\n    tax\n    pla\n");
    }

    fn storeSoftwareStackSlot(self: *Emitter, layout: frame_layout.FrameLayout, name: []const u8, ty: ast.Type) !void {
        if (self.stackTyIsWide(ty)) {
            try self.storeSoftwareStackScratchAX(layout, name);
        } else {
            try self.storeSoftwareStackScratchA(layout, name);
        }
    }

    fn storeSoftwareStackScratchA(self: *Emitter, layout: frame_layout.FrameLayout, name: []const u8) !void {
        const slot = layout.findSlot(name) orelse return error.UnknownVariable;
        try self.out.writer.print("    ldy #${x:0>2}\n    sta (zeropage_stack_fp),y\n", .{@as(u8, @truncate(slot.offset))});
    }

    fn storeSoftwareStackScratchAX(self: *Emitter, layout: frame_layout.FrameLayout, name: []const u8) !void {
        const slot = layout.findSlot(name) orelse return error.UnknownVariable;
        try self.storeSoftwareStackPointerAX("zeropage_stack_fp", slot.offset);
    }

    fn storeSoftwareStackPointerA(self: *Emitter, pointer_label: []const u8, offset: u16) !void {
        try self.out.writer.print("    ldy #${x:0>2}\n    sta ({s}),y\n", .{ @as(u8, @truncate(offset)), pointer_label });
    }

    fn storeSoftwareStackPointerAX(self: *Emitter, pointer_label: []const u8, offset: u16) !void {
        const w = &self.out.writer;
        try self.storeSoftwareStackPointerA(pointer_label, offset);
        try w.writeAll("    txa\n");
        if (self.optimizeSoftwareStack()) {
            // The preceding store leaves Y at the low-byte offset.
            // INY sets the same flags as loading the high-byte offset.
            try w.print("    iny\n    sta ({s}),y\n", .{pointer_label});
        } else {
            try self.storeSoftwareStackPointerA(pointer_label, offset + 1);
        }
    }

    fn loadSoftwareStackScratchA(self: *Emitter, layout: frame_layout.FrameLayout, name: []const u8) !void {
        try self.loadSoftwareStackSlotA(layout, name);
    }

    fn stackNumericWord(layout: frame_layout.FrameLayout, name: []const u8) ?frame_layout.FrameSlot {
        const slot = layout.findSlot(name) orelse return null;
        return switch (slot.ty) {
            .u16, .i16, .usize => if ((slot.kind == .param or slot.kind == .local or slot.kind == .hidden) and
                @as(u32, slot.offset) + 2 <= layout.byte_size) slot else null,
            else => null,
        };
    }

    fn tryEmitSoftwareStackDirectWord(self: *Emitter, layout: frame_layout.FrameLayout, lhs: []const u8, rhs: ast.Expr, op: StackMathOp) !bool {
        _ = stackNumericWord(layout, lhs) orelse return false;
        if (rhs != .value) return false;
        const offset: ?u8 = switch (rhs.value) {
            .int => null,
            .ident => |name| @intCast((stackNumericWord(layout, name) orelse return false).offset),
            else => return false,
        };
        if (!try self.hasPrivateStackLayout()) return false;

        // Both operands are stable across the operation. Keep the low result
        // in the existing scratch byte to preserve hardware-stack depth.
        const w = &self.out.writer;
        const carry, const mnemonic = switch (op) {
            .add => .{ "clc", "adc" },
            .sub => .{ "sec", "sbc" },
        };
        try self.loadSoftwareStackSlotAX(layout, lhs);
        try w.print("    {s}\n", .{carry});
        if (offset) |low| {
            try w.print("    ldy #${x:0>2}\n    {s} (zeropage_stack_fp),y\n", .{ low, mnemonic });
        } else {
            try w.print("    {s} #${x:0>2}\n", .{ mnemonic, @as(u8, @truncate(rhs.value.int)) });
        }
        try self.storeSoftwareStackScratchA(layout, "zeropage_math_tmp");
        try w.writeAll("    txa\n");
        if (offset) |low| {
            try w.print("    ldy #${x:0>2}\n    {s} (zeropage_stack_fp),y\n", .{ low + 1, mnemonic });
        } else {
            try w.print("    {s} #${x:0>2}\n", .{ mnemonic, @as(u8, @truncate(rhs.value.int >> 8)) });
        }
        try w.writeAll("    tax\n");
        try self.loadSoftwareStackScratchA(layout, "zeropage_math_tmp");
        return true;
    }

    fn hasPrivateStackLayout(self: *Emitter) !bool {
        if (self.private_stack_layout) |allowed| return allowed;
        const allowed = try frame_layout.hasPrivateStackLayout(self.allocator, self.program);
        self.private_stack_layout = allowed;
        return allowed;
    }

    fn emitSoftwareStackMathScratchWord(self: *Emitter, layout: frame_layout.FrameLayout, op: StackMathOp) !void {
        const scratch = layout.findSlot("zeropage_math_tmp") orelse return error.MissingStackScratch;
        const offset: u8 = @truncate(scratch.offset);
        const w = &self.out.writer;
        const carry, const mnemonic = switch (op) {
            .add => .{ "clc", "adc" },
            .sub => .{ "sec", "sbc" },
        };
        try w.print(
            \\    ldy #${x:0>2}
            \\    {s}
            \\    {s} (zeropage_stack_fp),y
            \\    sta (zeropage_stack_fp),y
            \\    txa
            \\
        , .{ offset, carry, mnemonic });
        const compact = self.optimizeSoftwareStack();
        if (compact) {
            try w.writeAll("    iny\n");
        } else {
            try w.print("    ldy #${x:0>2}\n", .{offset +% 1});
        }
        try w.print("    {s} (zeropage_stack_fp),y\n    tax\n", .{mnemonic});
        if (compact) {
            try w.writeAll("    dey\n");
        } else {
            try w.print("    ldy #${x:0>2}\n", .{offset});
        }
        try w.writeAll("    lda (zeropage_stack_fp),y\n");
    }

    fn stackTyIsWide(self: *Emitter, ty: ast.Type) bool {
        _ = self;
        return switch (ty) {
            .u16, .i16, .usize, .pointer => true,
            else => false,
        };
    }

    fn emitSoftwareStackTest6502Call(self: *Emitter, function_name: []const u8, layout: frame_layout.FrameLayout, call: ast.Test6502Call) !void {
        const label = try self.test6502Label(call);
        const stable_label = try self.ensureTest6502Hook(label);
        switch (call) {
            .expect_equal_u8 => |expect| try self.emitSoftwareStackExpr(function_name, layout, expect.actual),
            .expect_equal_i8 => |expect| try self.emitSoftwareStackExpr(function_name, layout, expect.actual),
            .expect_equal_bool => |expect| try self.emitSoftwareStackExpr(function_name, layout, expect.actual),
            .expect_equal_u16 => |expect| try self.emitSoftwareStackExprAX(function_name, layout, expect.actual),
            .expect_a, .expect_x, .expect_y, .expect_sp, .expect_p, .expect_mem_u8, .expect_mem_u16, .expect_stack_u8, .mark, .prime_regs, .hit, .expect_hit_count, .snapshot, .pass, .fail => {},
            .expect_null, .expect_some_u8, .expect_some_u16, .expect_some_bool, .expect_some_ptr, .expect_string => return error.UnsupportedStackFrameType,
        }
        try self.out.writer.print("    jsr {s}\n", .{stable_label});
    }

    fn emitSoftwareStackCall(self: *Emitter, function_name: []const u8, layout: frame_layout.FrameLayout, call: ast.CallExpr) anyerror!void {
        const callee = try self.functionForCall(call);
        if (callee.params.len != call.args.len) return error.ArgumentCountMismatch;
        if (self.functionUsesSoftwareStack(callee.name)) return try self.emitSoftwareStackToStackCall(function_name, layout, callee, call);
        try self.validateSoftwareStackBridgeType(callee.return_type);

        const w = &self.out.writer;
        for (callee.params, 0..) |param, index| {
            try self.validateSoftwareStackBridgeType(param.ty);
            const arg = call.args[index];
            if (frame_layout.exprContainsCall(arg)) return error.UnsupportedStackFrameBridgeArgument;
            if (isWideValueType(param.ty)) {
                try self.emitSoftwareStackExprExpected(function_name, layout, arg, param.ty);
                try w.print("    sta {s}_{s}\n    stx {s}_{s}+1\n", .{ callee.name, param.name, callee.name, param.name });
            } else {
                try self.emitSoftwareStackExprExpected(function_name, layout, arg, param.ty);
                try w.print("    sta {s}_{s}\n", .{ callee.name, param.name });
            }
        }

        try self.emitSoftwareStackPushFramePointer();
        try self.emitUserFunctionJsr(function_name, callee.name);

        if (callee.return_type == .void) {
            try self.emitSoftwareStackPopFramePointer(.stack);
        } else if (isWideValueType(callee.return_type)) {
            self.uses_stack_bridge_return = true;
            try self.emitRelocatableStackReturnStoreAX();
            try self.emitSoftwareStackPopFramePointer(.stack);
            try self.emitRelocatableStackReturnLoadAX();
        } else {
            self.uses_stack_bridge_return = true;
            try self.emitRelocatableStackReturnStoreA();
            try self.emitSoftwareStackPopFramePointer(.stack);
            try self.emitRelocatableStackReturnLoadA();
        }
    }

    fn emitSoftwareStackToStackCall(self: *Emitter, function_name: []const u8, caller_layout: frame_layout.FrameLayout, callee: ast.Function, call: ast.CallExpr) anyerror!void {
        var callee_layout = try frame_layout.planFunction(self.allocator, self.program, callee, .stack);
        defer callee_layout.deinit(self.allocator);
        if (callee_layout.byte_size > 255) return error.UnsupportedStackFrameTooLarge;
        if (callee.exported) return error.UnsupportedStackFrameBridge;
        try self.validateSoftwareStackBridgeType(callee.return_type);

        const forward_args = frame_layout.canForwardArguments(self.program, caller_layout.slots, caller_layout.byte_size, callee.params, call.args);
        var last_forwarded_word: ?usize = null;
        if (forward_args) {
            for (callee.params, 0..) |param, index| {
                if (isWideValueType(param.ty)) last_forwarded_word = index;
            }
        }
        const copy_words = if (last_forwarded_word) |last| blk: {
            for (callee.params[0..last]) |param| {
                if (isWideValueType(param.ty)) break :blk try self.canRewritePrivateStackBridge();
            }
            break :blk false;
        } else false;
        const w = &self.out.writer;
        for (callee.params, 0..) |param, index| {
            try self.validateSoftwareStackBridgeType(param.ty);
            const arg = call.args[index];
            if (frame_layout.exprContainsCall(arg)) return error.UnsupportedStackFrameBridgeArgument;
            if (forward_args) continue;
            const scratch_name = try std.fmt.allocPrint(self.allocator, "zeropage_call_arg_{d}", .{index});
            defer self.allocator.free(scratch_name);
            try self.emitSoftwareStackExprExpected(function_name, caller_layout, arg, param.ty);
            try self.storeSoftwareStackSlot(caller_layout, scratch_name, param.ty);
        }

        if (self.optimizeSoftwareStack() and callee_layout.byte_size != 0) {
            // Both reservations grow the same stack. Check the full
            // extent before publishing the caller's frame pointer.
            try self.emitSoftwareStackReservationCheck(2 + callee_layout.byte_size);
            try self.emitSoftwareStackPushFramePointerUnchecked();
        } else {
            try self.emitSoftwareStackPushFramePointer();
            try self.emitSoftwareStackEnsureAvailable(callee_layout.byte_size);
        }

        for (callee.params, 0..) |param, index| {
            // FP still addresses the caller. The checked link and every
            // destination slot start at or above the caller's previous SP.
            const scratch_name = if (forward_args) null else try std.fmt.allocPrint(self.allocator, "zeropage_call_arg_{d}", .{index});
            defer if (scratch_name) |name| self.allocator.free(name);
            const source = scratch_name orelse call.args[index].value.ident;
            const slot = callee_layout.findSlot(param.name) orelse return error.UnknownVariable;
            if (isWideValueType(param.ty)) {
                if (copy_words and index != last_forwarded_word.?) {
                    // Only the final wide copy needs to leave its high byte in X.
                    const caller_slot = caller_layout.findSlot(source) orelse return error.UnknownVariable;
                    try self.copySoftwareStackWord(caller_slot.offset, slot.offset);
                } else {
                    try self.loadSoftwareStackSlotAX(caller_layout, source);
                    try self.storeSoftwareStackPointerAX("zeropage_stack_sp", slot.offset);
                }
            } else {
                try self.loadSoftwareStackSlotA(caller_layout, source);
                try self.storeSoftwareStackPointerA("zeropage_stack_sp", slot.offset);
            }
        }

        try self.emitSoftwareStackSetFramePointerToStackPointer();
        try self.emitSoftwareStackAdvanceStackPointerUnchecked(callee_layout.byte_size);
        try self.emitModuleRelocationAnchor(callee.name);
        try w.print("    jsr {s}\n", .{callee.name});

        if (callee.return_type == .void) {
            try self.emitSoftwareStackReleaseNestedFrame();
        } else if (try self.canSpillNestedStackReturn()) {
            // Cleanup uses A and Y but leaves X intact. The one-byte spill
            // sits above the low-water mark already reached by the callee JSR.
            try w.writeAll("    pha\n");
            try self.emitSoftwareStackReleaseNestedFrame();
            try w.writeAll("    pla\n");
        } else if (isWideValueType(callee.return_type)) {
            self.uses_stack_bridge_return = true;
            try self.emitRelocatableStackReturnStoreAX();
            try self.emitSoftwareStackReleaseNestedFrame();
            try self.emitRelocatableStackReturnLoadAX();
        } else {
            self.uses_stack_bridge_return = true;
            try self.emitRelocatableStackReturnStoreA();
            try self.emitSoftwareStackReleaseNestedFrame();
            try self.emitRelocatableStackReturnLoadA();
        }
    }

    fn copySoftwareStackWord(self: *Emitter, source: u16, dest: u16) !void {
        const w = &self.out.writer;
        try w.print("    ldy #${x:0>2}\n    lda (zeropage_stack_fp),y\n", .{source});
        try self.storeSoftwareStackPointerA("zeropage_stack_sp", dest);
        try w.print("    ldy #${x:0>2}\n    lda (zeropage_stack_fp),y\n", .{source + 1});
        try self.storeSoftwareStackPointerA("zeropage_stack_sp", dest + 1);
    }

    fn emitSoftwareStackPushFramePointer(self: *Emitter) !void {
        try self.emitSoftwareStackEnsureAvailable(2);
        try self.emitSoftwareStackPushFramePointerUnchecked();
    }

    fn emitSoftwareStackPushFramePointerUnchecked(self: *Emitter) !void {
        try self.out.writer.writeAll(
            \\    ldy #$00
            \\    lda zeropage_stack_fp
            \\    sta (zeropage_stack_sp),y
            \\    iny
            \\    lda zeropage_stack_fp+1
            \\    sta (zeropage_stack_sp),y
            \\    clc
            \\    lda zeropage_stack_sp
            \\    adc #$02
            \\    sta zeropage_stack_sp
            \\    lda zeropage_stack_sp+1
            \\    adc #0
            \\    sta zeropage_stack_sp+1
            \\
        );
    }

    fn emitSoftwareStackSetFramePointerToStackPointer(self: *Emitter) !void {
        try self.out.writer.writeAll(
            \\    lda zeropage_stack_sp
            \\    sta zeropage_stack_fp
            \\    lda zeropage_stack_sp+1
            \\    sta zeropage_stack_fp+1
            \\
        );
    }

    fn emitModuleRelocationAnchor(self: *Emitter, target: []const u8) !void {
        try self.emitModuleRelocationAnchorKind(.abs16, target, 0);
    }

    fn emitRelocatableAbsInstruction(self: *Emitter, mnemonic: []const u8, target: []const u8) !void {
        try self.emitModuleRelocationAnchor(target);
        try self.out.writer.print("    {s} {s}\n", .{ mnemonic, target });
    }

    fn emitRelocatableAbsInstructionSuffix(self: *Emitter, mnemonic: []const u8, target: []const u8, suffix: []const u8) !void {
        try self.emitModuleRelocationAnchor(target);
        try self.out.writer.print("    {s} {s}{s}\n", .{ mnemonic, target, suffix });
    }

    fn emitRelocatableJsr(self: *Emitter, target: []const u8) !void {
        try self.emitRelocatableAbsInstruction("jsr", target);
    }

    fn emitRelocatableJmp(self: *Emitter, target: []const u8) !void {
        try self.emitRelocatableAbsInstruction("jmp", target);
    }

    const ModuleRelocationKind = enum { abs16, lo8, hi8 };

    fn emitModuleRelocationAnchorKind(self: *Emitter, kind: ModuleRelocationKind, target: []const u8, addend: i16) !void {
        if (self.program.zeropage_module == null) return;
        const id = self.module_relocation_id;
        self.module_relocation_id += 1;
        const owned_target = try self.allocator.dupe(u8, target);
        self.module_relocations.append(self.allocator, .{
            .id = id,
            .kind = kind,
            .target = owned_target,
            .addend = addend,
        }) catch |err| {
            self.allocator.free(owned_target);
            return err;
        };
        try self.out.writer.print(
            "zeropage_module_reloc_{d}:\n; zeropage_relocation kind={s} anchor=zeropage_module_reloc_{d} target={s} addend={d}\n",
            .{ id, @tagName(kind), id, target, addend },
        );
    }

    fn emitRelocatableStackReturnStoreA(self: *Emitter) !void {
        try self.emitModuleRelocationAnchor("zeropage_stack_ret_lo");
        try self.out.writer.writeAll("    sta zeropage_stack_ret_lo\n");
    }

    fn emitRelocatableStackReturnStoreAX(self: *Emitter) !void {
        try self.emitModuleRelocationAnchor("zeropage_stack_ret_lo");
        try self.out.writer.writeAll("    sta zeropage_stack_ret_lo\n");
        try self.emitModuleRelocationAnchor("zeropage_stack_ret_hi");
        try self.out.writer.writeAll("    stx zeropage_stack_ret_hi\n");
    }

    fn emitRelocatableStackReturnLoadA(self: *Emitter) !void {
        try self.emitModuleRelocationAnchor("zeropage_stack_ret_lo");
        try self.out.writer.writeAll("    lda zeropage_stack_ret_lo\n");
    }

    fn emitRelocatableStackReturnLoadAX(self: *Emitter) !void {
        try self.emitModuleRelocationAnchor("zeropage_stack_ret_lo");
        try self.out.writer.writeAll("    lda zeropage_stack_ret_lo\n");
        try self.emitModuleRelocationAnchor("zeropage_stack_ret_hi");
        try self.out.writer.writeAll("    ldx zeropage_stack_ret_hi\n");
    }

    fn emitSoftwareStackAdvanceStackPointer(self: *Emitter, amount: u16) !void {
        try self.emitSoftwareStackEnsureAvailable(amount);
        try self.emitSoftwareStackAdvanceStackPointerUnchecked(amount);
    }

    fn emitSoftwareStackAdvanceStackPointerUnchecked(self: *Emitter, amount: u16) !void {
        if (amount == 0) return;
        try self.out.writer.writeAll("    clc\n    lda zeropage_stack_sp\n");
        try self.out.writer.print("    adc #${x:0>2}\n", .{@as(u8, @truncate(amount))});
        try self.out.writer.writeAll(
            \\    sta zeropage_stack_sp
            \\    lda zeropage_stack_sp+1
            \\    adc #0
            \\    sta zeropage_stack_sp+1
            \\
        );
    }

    fn emitSoftwareStackEnsureAvailable(self: *Emitter, amount: u16) !void {
        if (amount == 0) return;
        if (amount > 255) return error.UnsupportedStackFrameTooLarge;
        try self.emitSoftwareStackReservationCheck(amount);
    }

    fn emitSoftwareStackReservationCheck(self: *Emitter, amount: u16) !void {
        const stack = self.program.zeropage_options.stack.?;
        const stack_end_u32 = @as(u32, stack.base) + @as(u32, stack.size);
        const stack_end: u16 = if (stack_end_u32 > 0xffff) 0xffff else @intCast(stack_end_u32);
        const ok_id = self.nextStackGuardLabel();
        self.uses_stack_overflow_trap = true;

        // A private stack starts at its base, publishes only checked
        // reservations, and restores previously valid frame boundaries.
        const omit_carry = stack_end_u32 + amount <= 0xffff and try self.canRewritePrivateStackBridge();
        const w = &self.out.writer;
        try w.print(
            \\    lda zeropage_stack_sp
            \\    clc
            \\    adc #${x:0>2}
            \\    tax
            \\    lda zeropage_stack_sp+1
            \\    adc #{d}
            \\
        , .{ @as(u8, @truncate(amount)), @as(u8, @truncate(amount >> 8)) });
        if (!omit_carry) try w.print("    bcs zeropage_stack_guard_{d}_overflow\n", .{ok_id});
        try w.print(
            \\    cmp #${x:0>2}
            \\    bcc zeropage_stack_guard_{d}_ok
            \\    bne zeropage_stack_guard_{d}_overflow
            \\    cpx #${x:0>2}
            \\    beq zeropage_stack_guard_{d}_ok
            \\
        , .{
            @as(u8, @truncate(stack_end >> 8)),
            ok_id,
            ok_id,
            @as(u8, @truncate(stack_end)),
            ok_id,
        });
        // The low byte cannot compare below zero. On equality the preceding
        // BEQ preserves the exact-fit path and its original status flags.
        if (!self.optimizeSoftwareStack() or @as(u8, @truncate(stack_end)) != 0) {
            try self.out.writer.print("    bcc zeropage_stack_guard_{d}_ok\n", .{ok_id});
        }
        try self.out.writer.print(
            \\zeropage_stack_guard_{d}_overflow:
            \\    jmp zeropage_stack_overflow_trap
            \\zeropage_stack_guard_{d}_ok:
            \\
        , .{ ok_id, ok_id });
    }

    fn nextStackGuardLabel(self: *Emitter) usize {
        const id = self.stack_guard_id;
        self.stack_guard_id += 1;
        return id;
    }

    fn emitSoftwareStackOverflowTrap(self: *Emitter) !void {
        const w = &self.out.writer;
        try sections.emitBegin(w, .runtime, .code, .static, .near);
        try w.writeAll(
            \\zeropage_stack_overflow_trap:
            \\    brk
            \\    jmp zeropage_stack_overflow_trap
            \\
        );
        try sections.emitEnd(w, .runtime, .code);
    }

    fn emitSoftwareStackReleaseNestedFrame(self: *Emitter) !void {
        if (self.optimizeSoftwareStack()) {
            // The link starts two bytes below the callee frame pointer.
            try self.emitSoftwareStackPopFramePointer(.frame);
        } else {
            try self.emitSoftwareStackEpilogue();
            try self.emitSoftwareStackPopFramePointer(.stack);
        }
    }

    fn emitSoftwareStackPopFramePointer(self: *Emitter, top: enum { stack, frame }) !void {
        const pointer = switch (top) {
            .stack => "zeropage_stack_sp",
            .frame => "zeropage_stack_fp",
        };
        try self.out.writer.print(
            \\    sec
            \\    lda {s}
            \\    sbc #$02
            \\    sta zeropage_stack_sp
            \\    lda {s}+1
            \\    sbc #0
            \\    sta zeropage_stack_sp+1
            \\    ldy #$00
            \\    lda (zeropage_stack_sp),y
            \\    sta zeropage_stack_fp
            \\    iny
            \\    lda (zeropage_stack_sp),y
            \\    sta zeropage_stack_fp+1
            \\
        , .{ pointer, pointer });
    }

    fn validateSoftwareStackBridgeType(self: *Emitter, ty: ast.Type) !void {
        return switch (ty) {
            .void, .u8, .i8, .bool, .u16, .i16, .usize, .pointer => {},
            .far_bytes, .far_view, .near_view => error.UnsupportedStackFrameAggregate,
            .custom => {
                if (self.isStructType(ty)) return error.UnsupportedStackFrameAggregate;
                if (self.isUnionType(ty)) return error.UnsupportedStackFrameUnion;
            },
            .array => error.UnsupportedStackFrameAggregate,
            .optional => error.UnsupportedStackFrameOptional,
        };
    }

    fn emitStmtList(self: *Emitter, function_name: []const u8, statements: []const ast.Stmt) anyerror!void {
        for (statements) |stmt| try self.emitStmt(function_name, stmt);
    }

    fn emitStmt(self: *Emitter, function_name: []const u8, stmt: ast.Stmt) anyerror!void {
        const w = &self.out.writer;
        switch (stmt) {
            .var_decl => |decl| try self.emitVarDecl(function_name, decl),
            .string_var => |decl| try self.emitStringVar(function_name, decl),
            .string_assign => |assign| try self.emitStringAssign(function_name, assign),
            .struct_var => |struct_var| try self.emitStructVar(function_name, struct_var),
            .assign => |assign| {
                if (try self.resolvePointerStructPath(function_name, assign.name)) |path| {
                    path.deinit(self.allocator);
                    try self.emitStorePointerStructPath(function_name, assign.name, assign.value);
                    return;
                }
                const binding = try self.expectBinding(function_name, assign.name);
                if (!binding.mutable) return error.ImmutableLocalMutation;
                if (isArrayType(binding.ty)) return error.UnsupportedArrayByValue;
                if (self.isStructType(binding.ty)) {
                    const type_name = binding.ty.custom;
                    try self.emitStructExprToStorage(function_name, assign.name, type_name, assign.value);
                    return;
                }
                if (self.isUnionType(binding.ty)) {
                    try self.emitUnionExprToStorage(function_name, assign.name, binding.ty.custom, assign.value);
                    return;
                }
                if (isOptionalType(binding.ty)) {
                    try self.emitOptionalExprToStorage(function_name, assign.value, function_name, assign.name, binding.ty.optional);
                    return;
                }
                if (isWideValueType(binding.ty)) {
                    try self.emitExprToAXExpected(function_name, assign.value, binding.ty);
                    try w.print("    sta {s}_{s}\n    stx {s}_{s}+1\n", .{ function_name, assign.name, function_name, assign.name });
                } else {
                    try self.emitExprToAExpected(function_name, assign.value, binding.ty);
                    try w.print("    sta {s}_{s}\n", .{ function_name, assign.name });
                }
            },
            .deref_assign => |assign| try self.emitDerefAssign(function_name, assign),
            .add_assign => |add| {
                if (try self.resolvePointerStructPath(function_name, add.name)) |path| {
                    defer path.deinit(self.allocator);
                    if (isArrayType(path.ty) or self.isStructType(path.ty)) return error.UnsupportedPointerTarget;
                    self.uses_math_tmp = true;
                    if (isWordType(path.ty)) {
                        try self.emitExprToAX(function_name, add.value);
                        try w.writeAll("    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n");
                        try self.emitPointerStructPathToAX(function_name, add.name);
                        try w.writeAll("    clc\n    adc zeropage_math_tmp\n    pha\n    txa\n    adc zeropage_math_tmp+1\n    tax\n    pla\n");
                    } else {
                        try self.emitExprToA(function_name, add.value);
                        try w.writeAll("    sta zeropage_math_tmp\n");
                        try self.emitPointerStructPathToA(function_name, add.name);
                        try w.writeAll("    clc\n    adc zeropage_math_tmp\n");
                    }
                    try self.emitStorePointerStructPathFromResult(function_name, add.name, path.ty);
                    return;
                }
                const binding = try self.expectBinding(function_name, add.name);
                if (!binding.mutable) return error.ImmutableLocalMutation;
                if (isWordType(binding.ty) and self.program.zeropage_module == null) {
                    try self.emitExprToAX(function_name, add.value);
                    try w.print("    clc\n    adc {s}_{s}\n    sta {s}_{s}\n    txa\n    adc {s}_{s}+1\n    sta {s}_{s}+1\n", .{ function_name, add.name, function_name, add.name, function_name, add.name, function_name, add.name });
                } else if (isWordType(binding.ty)) {
                    self.uses_math_tmp = true;
                    try self.emitExprToAX(function_name, add.value);
                    try w.writeAll("    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n");
                    try w.print(
                        "    lda {s}_{s}\n    clc\n    adc zeropage_math_tmp\n    sta {s}_{s}\n    lda {s}_{s}+1\n    adc zeropage_math_tmp+1\n    sta {s}_{s}+1\n",
                        .{ function_name, add.name, function_name, add.name, function_name, add.name, function_name, add.name },
                    );
                } else {
                    try self.emitExprToA(function_name, add.value);
                    try w.print("    clc\n    adc {s}_{s}\n    sta {s}_{s}\n", .{ function_name, add.name, function_name, add.name });
                }
            },
            .sub_assign => |sub| {
                if (try self.resolvePointerStructPath(function_name, sub.name)) |path| {
                    defer path.deinit(self.allocator);
                    if (isArrayType(path.ty) or self.isStructType(path.ty)) return error.UnsupportedPointerTarget;
                    self.uses_math_tmp = true;
                    if (isWordType(path.ty)) {
                        try self.emitExprToAX(function_name, sub.value);
                        try w.writeAll("    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n");
                        try self.emitPointerStructPathToAX(function_name, sub.name);
                        try w.writeAll("    sec\n    sbc zeropage_math_tmp\n    pha\n    txa\n    sbc zeropage_math_tmp+1\n    tax\n    pla\n");
                    } else {
                        try self.emitExprToA(function_name, sub.value);
                        try w.writeAll("    sta zeropage_math_tmp\n");
                        try self.emitPointerStructPathToA(function_name, sub.name);
                        try w.writeAll("    sec\n    sbc zeropage_math_tmp\n");
                    }
                    try self.emitStorePointerStructPathFromResult(function_name, sub.name, path.ty);
                    return;
                }
                const binding = try self.expectBinding(function_name, sub.name);
                if (!binding.mutable) return error.ImmutableLocalMutation;
                self.uses_math_tmp = true;
                if (isWordType(binding.ty)) {
                    try self.emitExprToAX(function_name, sub.value);
                    try w.writeAll("    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n");
                    try w.print(
                        "    lda {s}_{s}\n    sec\n    sbc zeropage_math_tmp\n    sta {s}_{s}\n    lda {s}_{s}+1\n    sbc zeropage_math_tmp+1\n    sta {s}_{s}+1\n",
                        .{ function_name, sub.name, function_name, sub.name, function_name, sub.name, function_name, sub.name },
                    );
                } else {
                    try self.emitExprToA(function_name, sub.value);
                    try w.print("    sta zeropage_math_tmp\n    lda {s}_{s}\n    sec\n    sbc zeropage_math_tmp\n    sta {s}_{s}\n", .{ function_name, sub.name, function_name, sub.name });
                }
            },
            .mul_assign => |mul| {
                if (try self.resolvePointerStructPath(function_name, mul.name)) |path| {
                    defer path.deinit(self.allocator);
                    if (isArrayType(path.ty) or self.isStructType(path.ty)) return error.UnsupportedPointerTarget;
                    try self.validateMultiplicationTypes(path.ty, try self.exprType(function_name, mul.value));
                    self.uses_multiply = true;
                    try self.emitExprToAX(function_name, mul.value);
                    try w.writeAll("    sta zeropage_mul_rhs\n    stx zeropage_mul_rhs+1\n");
                    try self.emitPointerStructPathToAX(function_name, mul.name);
                    try w.writeAll("    sta zeropage_mul_lhs\n    stx zeropage_mul_lhs+1\n    jsr zeropage_mul16\n");
                    try self.emitStorePointerStructPathFromResult(function_name, mul.name, path.ty);
                    return;
                }
                const binding = try self.expectBinding(function_name, mul.name);
                if (!binding.mutable) return error.ImmutableLocalMutation;
                try self.validateMultiplicationTypes(binding.ty, try self.exprType(function_name, mul.value));
                try self.emitMulAssign(function_name, mul, binding);
                if (isWordType(binding.ty)) {
                    try w.print("    sta {s}_{s}\n    stx {s}_{s}+1\n", .{ function_name, mul.name, function_name, mul.name });
                } else {
                    try w.print("    sta {s}_{s}\n", .{ function_name, mul.name });
                }
            },
            .bit_and_assign => |assign| try self.emitBitwiseAssign(function_name, assign, .bit_and),
            .bit_or_assign => |assign| try self.emitBitwiseAssign(function_name, assign, .bit_or),
            .bit_xor_assign => |assign| try self.emitBitwiseAssign(function_name, assign, .bit_xor),
            .shl_assign => |assign| try self.emitShiftAssign(function_name, assign, .shl),
            .shr_assign => |assign| try self.emitShiftAssign(function_name, assign, .shr),
            .array_assign => |assign| try self.emitArrayAssign(function_name, assign),
            .array_add_assign => |assign| try self.emitCompoundIndexed(function_name, assign, .add),
            .array_sub_assign => |assign| try self.emitCompoundIndexed(function_name, assign, .sub),
            .array_mul_assign => |assign| try self.emitCompoundIndexed(function_name, assign, .mul),
            .array_bit_and_assign => |assign| try self.emitCompoundIndexed(function_name, assign, .bit_and),
            .array_bit_or_assign => |assign| try self.emitCompoundIndexed(function_name, assign, .bit_or),
            .array_bit_xor_assign => |assign| try self.emitCompoundIndexed(function_name, assign, .bit_xor),
            .array_shl_assign => |assign| try self.emitCompoundIndexed(function_name, assign, .shl),
            .array_shr_assign => |assign| try self.emitCompoundIndexed(function_name, assign, .shr),
            .array_field_assign => |assign| try self.emitArrayFieldAssign(function_name, assign),
            .while_stmt => |while_stmt| {
                const id = self.nextControlLabel();
                if (self.stream_copy_allowed) {
                    if (self.findFunction(function_name)) |function| {
                        if (stream_copy.classify(function, while_stmt)) |shape| {
                            try stream_copy.emitGuarded(self.allocator, w, function_name, shape, id);
                            self.used_stream_copy = true;
                        }
                    }
                }
                try w.print("while_{d}_top:\n", .{id});
                try self.expectBoolExpr(function_name, while_stmt.condition);
                if (self.program.zeropage_module == null) {
                    const yes = try std.fmt.allocPrint(self.allocator, "while_{d}_body", .{id});
                    defer self.allocator.free(yes);
                    const no = try std.fmt.allocPrint(self.allocator, "while_{d}_done", .{id});
                    defer self.allocator.free(no);
                    try self.emitConditionBranch(function_name, while_stmt.condition, yes, no, true);
                } else {
                    try self.emitExprToA(function_name, while_stmt.condition);
                    try w.print("    cmp #0\n    bne while_{d}_body\n    jmp while_{d}_done\n", .{ id, id });
                }
                try w.print("while_{d}_body:\n", .{id});
                try self.loop_stack.append(self.allocator, .{ .kind = .while_loop, .id = id });
                defer _ = self.loop_stack.pop();
                try self.emitStmtList(function_name, while_stmt.body);
                try w.print("    jmp while_{d}_top\nwhile_{d}_done:\n", .{ id, id });
            },
            .for_stmt => |for_stmt| try self.emitForStmt(function_name, for_stmt),
            .switch_stmt => |switch_stmt| try self.emitSwitchStmt(function_name, switch_stmt),
            .if_stmt => |if_stmt| {
                const id = self.nextControlLabel();
                if (if_stmt.payload_name) |payload_name| {
                    const optional_ty = try self.expectOptionalExpr(function_name, if_stmt.condition);
                    try self.emitOptionalExprToTemp(function_name, if_stmt.condition, optional_ty);
                    try self.emitOptionalPresentFromLabelToA("zeropage_optional_tmp", optional_ty);
                    try w.print("    cmp #0\n    bne if_{d}_then\n", .{id});
                    try w.print("    jmp if_{d}_else\nif_{d}_then:\n", .{ id, id });
                    try self.emitOptionalPayloadFromLabelToSlot("zeropage_optional_tmp", optional_ty, function_name, payload_name);
                } else {
                    try self.expectBoolExpr(function_name, if_stmt.condition);
                    if (self.program.zeropage_module == null) {
                        const yes = try std.fmt.allocPrint(self.allocator, "if_{d}_then", .{id});
                        defer self.allocator.free(yes);
                        const no = try std.fmt.allocPrint(self.allocator, "if_{d}_else", .{id});
                        defer self.allocator.free(no);
                        try self.emitConditionBranch(function_name, if_stmt.condition, yes, no, true);
                    } else {
                        try self.emitExprToA(function_name, if_stmt.condition);
                        try w.print("    cmp #0\n    bne if_{d}_then\n    jmp if_{d}_else\n", .{ id, id });
                    }
                    try w.print("if_{d}_then:\n", .{id});
                }
                try self.emitStmtList(function_name, if_stmt.then_body);
                try w.print("    jmp if_{d}_done\nif_{d}_else:\n", .{ id, id });
                try self.emitStmtList(function_name, if_stmt.else_body);
                try w.print("if_{d}_done:\n", .{id});
            },
            .call => |call| {
                try self.emitCall(function_name, call);
                try w.writeAll("    ; discard return value\n");
            },
            .discard => |expr| {
                if (try self.exprNeedsWord(function_name, expr)) {
                    try self.emitExprToAX(function_name, expr);
                } else {
                    try self.emitExprToA(function_name, expr);
                }
                try w.writeAll("    ; discard expression value\n");
            },
            .return_expr => |expr| {
                const function = self.findFunction(function_name) orelse return error.UnknownFunction;
                if (self.isStructType(function.return_type)) {
                    try self.emitStructExprToStorage(function_name, "return", function.return_type.custom, expr);
                } else if (self.isUnionType(function.return_type)) {
                    try self.emitUnionExprToStorage(function_name, "return", function.return_type.custom, expr);
                } else if (isOptionalType(function.return_type)) {
                    try self.emitOptionalExprToStorage(function_name, expr, function_name, "return", function.return_type.optional);
                } else if (isWideValueType(function.return_type)) {
                    try self.emitExprToAXExpected(function_name, expr, function.return_type);
                } else {
                    try self.emitExprToAExpected(function_name, expr, function.return_type);
                }
                try w.writeAll("    rts\n");
            },
            .break_stmt => {
                const loop = self.currentLoop() orelse return error.BreakOutsideLoop;
                try self.emitLoopBreak(loop);
            },
            .break_expr => |break_expr| try self.emitBlockBreakExpr(function_name, break_expr),
            .continue_stmt => {
                const loop = self.currentLoop() orelse return error.ContinueOutsideLoop;
                try self.emitLoopContinue(loop);
            },
            .inline_asm => |block| try self.emitInlineAsm(function_name, block),
            .test6502 => |call| try self.emitTest6502Call(function_name, call),
            .builtin => |builtin| try self.emitBuiltin(function_name, builtin),
            .reu => |call| try self.emitReuStmt(function_name, call),
            .reu_heap_reset => |name| try self.emitReuHeapReset(name),
            .heap_reset => |name| try self.emitHeapReset(name),
            .heap_free => |free| try self.emitHeapFree(function_name, free),
            .module_unload => |unload| try self.emitModuleUnload(unload),
            .module_unload_dependency => |unload| try self.emitModuleDependencyUnload(unload),
            .module_release_dependency => |release| try self.emitModuleDependencyUnload(release),
            .module_release_dependency_graph => |release| try self.emitModuleDependencyGraphRelease(release),
            .field_assign => |field| {
                switch (field.path) {
                    .c64_vic_border => {
                        try self.emitExprToA(function_name, field.value);
                        try w.writeAll("    sta $d020\n");
                    },
                }
            },
        }
    }

    fn emitVarDecl(self: *Emitter, function_name: []const u8, decl: ast.VarDecl) !void {
        const w = &self.out.writer;
        const ty = try self.localDeclType(function_name, decl);
        switch (ty) {
            .array => |array_ty| try self.emitArrayVarDecl(function_name, decl, array_ty),
            .far_view => {
                const view = switch (decl.init) {
                    .reu_view => |view| view,
                    .value => |value| switch (value) {
                        .ident => |ident| {
                            const source = try self.expectBinding(function_name, ident);
                            if (!typesEqual(source.ty, ty)) return error.UnsupportedPointerType;
                            const dest_label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ function_name, decl.name });
                            defer self.allocator.free(dest_label);
                            try self.emitFarHandleExprToSlot(function_name, decl.init, dest_label);
                            return;
                        },
                        else => return error.UnsupportedPointerType,
                    },
                    else => return error.UnsupportedPointerType,
                };
                try self.emitReuViewToSlot(function_name, view, decl.name);
            },
            .near_view => {
                const source_name = switch (decl.init) {
                    .value => |value| switch (value) {
                        .ident => |ident| ident,
                        else => return error.UnsupportedPointerType,
                    },
                    else => return error.UnsupportedPointerType,
                };
                const source = try self.expectBinding(function_name, source_name);
                if (!typesEqual(source.ty, ty)) return error.UnsupportedPointerType;
                try w.print("    lda {s}_{s}\n    sta {s}_{s}\n    lda {s}_{s}+1\n    sta {s}_{s}+1\n", .{
                    function_name, source_name, function_name, decl.name,
                    function_name, source_name, function_name, decl.name,
                });
            },
            .custom => |custom| {
                if (self.program.findStruct(custom) != null) {
                    try self.emitStructExprToStorage(function_name, decl.name, custom, decl.init);
                } else if (self.program.findUnion(custom) != null) {
                    try self.emitUnionExprToStorage(function_name, decl.name, custom, decl.init);
                } else {
                    try self.emitExprToAExpected(function_name, decl.init, ty);
                    try w.print("    sta {s}_{s}\n", .{ function_name, decl.name });
                }
            },
            .optional => |optional| try self.emitOptionalExprToStorage(function_name, decl.init, function_name, decl.name, optional),
            .u16, .i16, .usize, .pointer => {
                try self.emitExprToAXExpected(function_name, decl.init, ty);
                try w.print("    sta {s}_{s}\n    stx {s}_{s}+1\n", .{ function_name, decl.name, function_name, decl.name });
            },
            else => {
                try self.emitExprToAExpected(function_name, decl.init, ty);
                try w.print("    sta {s}_{s}\n", .{ function_name, decl.name });
            },
        }
    }

    fn emitForStmt(self: *Emitter, function_name: []const u8, for_stmt: ast.ForStmt) !void {
        switch (for_stmt.source) {
            .array => |name| try self.emitArrayForStmt(function_name, for_stmt, name, false),
            .array_indexed => |name| try self.emitArrayForStmt(function_name, for_stmt, name, true),
            .range => |range| try self.emitRangeForStmt(function_name, for_stmt, range),
        }
    }

    fn emitArrayForStmt(self: *Emitter, function_name: []const u8, for_stmt: ast.ForStmt, name: []const u8, indexed: bool) !void {
        const array_ref = try self.resolveArray(function_name, name);
        defer array_ref.deinit(self.allocator);
        const index_label = try self.forIndexLabel(function_name, for_stmt.id);
        defer self.allocator.free(index_label);
        const elem_ty = arrayElemToType(array_ref.ty.elem);

        try self.out.writer.print("    lda #0\n    sta {s}\n    sta {s}+1\n", .{ index_label, index_label });
        if (self.program.zeropage_module == null) try self.out.writer.print("; zeropage_loop_begin id={d} count={d}\n", .{ for_stmt.id, array_ref.ty.len });
        try self.out.writer.print("for_{d}_top:\n", .{for_stmt.id});
        try self.out.writer.print("    lda {s}\n    cmp #{d}\n    bcc for_{d}_body\n    jmp for_{d}_done\nfor_{d}_body:\n", .{ index_label, @as(u8, @truncate(array_ref.ty.len)), for_stmt.id, for_stmt.id, for_stmt.id });

        if (for_stmt.item_name) |item_name| {
            if (isWordType(elem_ty)) {
                try self.out.writer.print("    lda {s}\n    asl\n    tay\n    lda {s},y\n    sta {s}_{s}\n    iny\n    lda {s},y\n    sta {s}_{s}+1\n", .{ index_label, array_ref.label, function_name, item_name, array_ref.label, function_name, item_name });
            } else {
                try self.out.writer.print("    ldy {s}\n    lda {s},y\n    sta {s}_{s}\n", .{ index_label, array_ref.label, function_name, item_name });
            }
        }
        if (indexed) {
            if (for_stmt.index_name) |index_name| {
                if (self.program.zeropage_module == null) try self.out.writer.print("; zeropage_loop_capture source={s}_{s}\n", .{ function_name, index_name });
                try self.out.writer.print("    lda {s}\n    sta {s}_{s}\n    lda #0\n    sta {s}_{s}+1\n", .{ index_label, function_name, index_name, function_name, index_name });
            }
        }

        try self.loop_stack.append(self.allocator, .{ .kind = .for_loop, .id = for_stmt.id });
        defer _ = self.loop_stack.pop();
        try self.emitStmtList(function_name, for_stmt.body);
        try self.out.writer.print("for_{d}_next:\n    inc {s}\n    jmp for_{d}_top\nfor_{d}_done:\n", .{ for_stmt.id, index_label, for_stmt.id, for_stmt.id });
        if (self.program.zeropage_module == null) try self.out.writer.print("; zeropage_loop_end id={d}\n", .{for_stmt.id});
    }

    fn emitRangeForStmt(self: *Emitter, function_name: []const u8, for_stmt: ast.ForStmt, range: ast.ForRangeEnd) !void {
        const end = try self.forRangeEndValue(function_name, range);
        const index_label = try self.forIndexLabel(function_name, for_stmt.id);
        defer self.allocator.free(index_label);

        try self.out.writer.print("    lda #0\n    sta {s}\n    sta {s}+1\n", .{ index_label, index_label });
        if (self.program.zeropage_module == null) try self.out.writer.print("; zeropage_loop_begin id={d} count={d}\n", .{ for_stmt.id, end });
        try self.out.writer.print("for_{d}_top:\n", .{for_stmt.id});
        try self.out.writer.print("    lda {s}\n    cmp #{d}\n    bcc for_{d}_body\n    jmp for_{d}_done\nfor_{d}_body:\n", .{ index_label, end, for_stmt.id, for_stmt.id, for_stmt.id });
        if (for_stmt.item_name) |item_name| {
            if (self.program.zeropage_module == null) try self.out.writer.print("; zeropage_loop_capture source={s}_{s}\n", .{ function_name, item_name });
            try self.out.writer.print("    lda {s}\n    sta {s}_{s}\n    lda #0\n    sta {s}_{s}+1\n", .{ index_label, function_name, item_name, function_name, item_name });
        }

        try self.loop_stack.append(self.allocator, .{ .kind = .for_loop, .id = for_stmt.id });
        defer _ = self.loop_stack.pop();
        try self.emitStmtList(function_name, for_stmt.body);
        try self.out.writer.print("for_{d}_next:\n    inc {s}\n    jmp for_{d}_top\nfor_{d}_done:\n", .{ for_stmt.id, index_label, for_stmt.id, for_stmt.id });
        if (self.program.zeropage_module == null) try self.out.writer.print("; zeropage_loop_end id={d}\n", .{for_stmt.id});
    }

    fn forRangeEndValue(self: *Emitter, function_name: []const u8, range: ast.ForRangeEnd) !u8 {
        return switch (range) {
            .int => |n| std.math.cast(u8, n) orelse error.UnsupportedForRange,
            .array_len => |name| blk: {
                const array_ref = try self.resolveArray(function_name, name);
                defer array_ref.deinit(self.allocator);
                break :blk std.math.cast(u8, array_ref.ty.len) orelse error.UnsupportedForRange;
            },
        };
    }

    fn forIndexLabel(self: *Emitter, function_name: []const u8, id: usize) ![]u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}_for_{d}_index", .{ function_name, id });
    }

    fn emitSwitchStmt(self: *Emitter, function_name: []const u8, switch_stmt: ast.SwitchStmt) !void {
        const id = self.nextLabel();
        const operand_ty = try self.prepareSwitchOperand(function_name, switch_stmt.operand);
        try self.validateSwitchProngs(function_name, operand_ty, switch_stmt.prongs, null);
        const else_index = switchStmtElseIndex(switch_stmt.prongs);
        for (switch_stmt.prongs, 0..) |prong, prong_index| {
            if (prongHasElse(prong.selectors)) continue;
            try self.emitSwitchSelectorTests("switch", operand_ty, prong.selectors, id, prong_index);
        }
        if (else_index) |index| {
            try self.out.writer.print("    jmp switch_{d}_case_{d}\n", .{ id, index });
        } else {
            try self.out.writer.print("    jmp switch_{d}_done\n", .{id});
        }
        for (switch_stmt.prongs, 0..) |prong, prong_index| {
            try self.out.writer.print("switch_{d}_case_{d}:\n", .{ id, prong_index });
            if (prong.payload_name) |payload_name| try self.emitSwitchPayloadToSlot(function_name, payload_name, operand_ty, prong.selectors);
            try self.emitStmtList(function_name, prong.body);
            try self.out.writer.print("    jmp switch_{d}_done\n", .{id});
        }
        try self.out.writer.print("switch_{d}_done:\n", .{id});
    }

    fn emitSwitchPayloadToSlot(self: *Emitter, function_name: []const u8, payload_name: []const u8, operand_ty: ast.Type, selectors: []const ast.SwitchSelector) !void {
        if (operand_ty == .optional) {
            try self.emitOptionalPayloadFromLabelToSlot("zeropage_optional_tmp", operand_ty.optional, function_name, payload_name);
        } else if (self.isUnionType(operand_ty)) {
            const payload_ty = (try self.switchPayloadTypeForSelectors(operand_ty, selectors)) orelse return error.UnsupportedSwitchPayload;
            if (isWordType(payload_ty) or isPointerType(payload_ty)) {
                try self.out.writer.print("    lda zeropage_union_switch_payload\n    sta {s}_{s}\n    lda zeropage_union_switch_payload+1\n    sta {s}_{s}+1\n", .{ function_name, payload_name, function_name, payload_name });
            } else {
                try self.out.writer.print("    lda zeropage_union_switch_payload\n    sta {s}_{s}\n", .{ function_name, payload_name });
            }
        } else if (isWordType(operand_ty)) {
            try self.out.writer.print("    lda zeropage_switch_value\n    sta {s}_{s}\n    lda zeropage_switch_value+1\n    sta {s}_{s}+1\n", .{ function_name, payload_name, function_name, payload_name });
        } else {
            try self.out.writer.print("    lda zeropage_switch_value\n    sta {s}_{s}\n", .{ function_name, payload_name });
        }
    }

    fn prepareSwitchOperand(self: *Emitter, function_name: []const u8, operand: ast.Expr) !ast.Type {
        self.uses_switch = true;
        const operand_ty = try self.exprType(function_name, operand);
        if (operand_ty == .optional) {
            try self.emitOptionalExprToTemp(function_name, operand, operand_ty.optional);
            try self.emitOptionalPresentFromLabelToA("zeropage_optional_tmp", operand_ty.optional);
            try self.out.writer.writeAll("    sta zeropage_switch_value\n    lda #0\n    sta zeropage_switch_value+1\n");
            return operand_ty;
        } else if (self.isUnionType(operand_ty)) {
            self.uses_union_switch = true;
            try self.emitUnionExprToSwitchStorage(function_name, operand, operand_ty.custom);
            return operand_ty;
        }
        if (!isScalarSwitchType(operand_ty)) return error.UnsupportedSwitchType;
        if (operand_ty == .custom and !self.isEnumType(operand_ty)) return error.UnsupportedSwitchType;
        if (isWordType(operand_ty)) {
            try self.emitExprToAX(function_name, operand);
            try self.out.writer.writeAll("    sta zeropage_switch_value\n    stx zeropage_switch_value+1\n");
        } else {
            try self.emitExprToA(function_name, operand);
            try self.out.writer.writeAll("    sta zeropage_switch_value\n    lda #0\n    sta zeropage_switch_value+1\n");
        }
        return operand_ty;
    }

    fn emitStringVar(self: *Emitter, function_name: []const u8, decl: ast.StringVar) !void {
        _ = decl.capacity;
        try self.out.writer.print("    lda #0\n    sta {s}_{s}_len\n", .{ function_name, decl.name });
    }

    fn emitStringAssign(self: *Emitter, function_name: []const u8, assign: ast.StringAssign) !void {
        const buffer = self.findStringBuffer(function_name, assign.name) orelse return error.UnknownStringBuffer;
        try self.out.writer.print("    lda #0\n    sta {s}_{s}_len\n", .{ function_name, assign.name });
        try self.emitAppendStringExpr(function_name, buffer, assign.expr);
    }

    fn emitInlineAsm(self: *Emitter, function_name: []const u8, block: ast.InlineAsm) !void {
        try inline_asm_emit.emitBlock(self, function_name, block);
    }

    fn emitInlineAsmInstruction(self: *Emitter, function: ast.Function, analyzed: inline_asm.AnalyzedBlock, id: usize, inst: inline_asm.Instruction) !void {
        try inline_asm_emit.emitInstruction(self, function, analyzed, id, inst);
    }

    fn emitTest6502Call(self: *Emitter, function_name: []const u8, call: ast.Test6502Call) !void {
        try test6502_emit.emitCall(self, function_name, call);
    }

    fn emitReuStmt(self: *Emitter, function_name: []const u8, call: ast.ReuStmt) !void {
        switch (call) {
            .copy_c64_to_reu => |transfer| {
                self.uses_reu_copy_c64_to_reu = true;
                try self.emitReuTransferSetup(function_name, transfer);
                try self.out.writer.writeAll("    jsr zeropage_reu_copy_c64_to_reu\n");
            },
            .copy_reu_to_c64 => |transfer| {
                self.uses_reu_copy_reu_to_c64 = true;
                try self.emitReuTransferSetup(function_name, transfer);
                try self.out.writer.writeAll("    jsr zeropage_reu_copy_reu_to_c64\n");
            },
            .swap => |transfer| {
                self.uses_reu_swap = true;
                try self.emitReuTransferSetup(function_name, transfer);
                try self.out.writer.writeAll("    jsr zeropage_reu_swap\n");
            },
            .fill => |fill| {
                self.uses_reu_fill = true;
                try self.emitReuFillSetup(function_name, fill);
                try self.out.writer.writeAll("    jsr zeropage_reu_fill\n");
            },
            .copy_from_c64 => |copy| {
                self.uses_reu_copy_c64_to_reu = true;
                try self.emitReuFarCopySetup(function_name, copy);
                try self.out.writer.writeAll("    jsr zeropage_reu_copy_c64_to_reu\n");
            },
            .copy_to_c64 => |copy| {
                self.uses_reu_copy_reu_to_c64 = true;
                try self.emitReuFarCopySetup(function_name, copy);
                try self.out.writer.writeAll("    jsr zeropage_reu_copy_reu_to_c64\n");
            },
        }
    }

    fn emitReuHeapReset(self: *Emitter, name: []const u8) !void {
        _ = self.program.findReuHeap(name) orelse return error.UnknownHeap;
        try self.reu_heap_reset_names.put(name, {});
        try self.out.writer.print("    jsr zeropage_reu_heap_{s}_reset\n", .{name});
    }

    fn emitReuHeapAlloc(self: *Emitter, function_name: []const u8, alloc: ast.ReuHeapAlloc) !void {
        _ = self.program.findReuHeap(alloc.name) orelse return error.UnknownHeap;
        try self.reu_heap_alloc_names.put(alloc.name, {});
        try self.emitExprToAX(function_name, alloc.len.*);
        try self.out.writer.writeAll("    sta zeropage_reu_heap_len\n    stx zeropage_reu_heap_len+1\n");
        try self.out.writer.print("    jsr zeropage_reu_heap_{s}_alloc_bytes\n", .{alloc.name});
    }

    fn emitReuViewToSlot(self: *Emitter, function_name: []const u8, view: ast.ReuView, dest_name: []const u8) !void {
        const view_ty = try self.validateReuView(function_name, view);
        const dest_label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ function_name, dest_name });
        defer self.allocator.free(dest_label);
        _ = view_ty;
        try self.emitFarHandleExprToSlot(function_name, view.far.*, dest_label);
    }

    fn emitFarHandleExprToSlot(self: *Emitter, function_name: []const u8, expr: ast.Expr, dest_label: []const u8) !void {
        const ty = try self.exprType(function_name, expr);
        if (ty != .far_bytes and ty != .far_view) return error.UnsupportedPointerType;
        switch (expr) {
            .value => |value| switch (value) {
                .ident => |ident| {
                    const binding = try self.expectBinding(function_name, ident);
                    if (!typesEqual(binding.ty, ty)) return error.UnsupportedPointerType;
                    for (0..5) |offset| {
                        try self.out.writer.print("    lda {s}_{s}+{d}\n    sta {s}+{d}\n", .{ function_name, ident, offset, dest_label, offset });
                    }
                    return;
                },
                else => {},
            },
            else => {},
        }
        return error.UnsupportedPointerType;
    }

    fn emitHeapReset(self: *Emitter, name: []const u8) !void {
        _ = self.program.findHeap(name) orelse return error.UnknownHeap;
        try self.heap_reset_names.put(name, {});
        try self.out.writer.print("    jsr zeropage_heap_{s}_reset\n", .{name});
    }

    fn emitHeapAllocToAX(self: *Emitter, function_name: []const u8, alloc: ast.HeapAlloc) !void {
        _ = self.program.findHeap(alloc.name) orelse return error.UnknownHeap;
        try self.heap_alloc_names.put(alloc.name, {});
        try self.emitExprToAX(function_name, alloc.len.*);
        try self.out.writer.print("    jsr zeropage_heap_{s}_alloc_bytes\n", .{alloc.name});
    }

    fn emitHeapFree(self: *Emitter, function_name: []const u8, free: ast.HeapFree) !void {
        const heap = self.program.findHeap(free.name) orelse return error.UnknownHeap;
        if (heap.kind != .fixed) return error.UnsupportedHeapFunction;
        const ptr_ty = try self.exprType(function_name, free.ptr.*);
        if (ptr_ty != .pointer) return error.UnsupportedPointerType;
        try self.heap_free_names.put(free.name, {});
        try self.emitExprToAXExpected(function_name, free.ptr.*, ptr_ty);
        try self.out.writer.print("    jsr zeropage_heap_{s}_free\n", .{free.name});
    }

    fn emitReuPresent(self: *Emitter) !void {
        self.uses_reu_present = true;
        try self.out.writer.writeAll("    jsr zeropage_reu_present\n");
    }

    fn emitModuleLoad(self: *Emitter, load: ast.ModuleLoad) !void {
        try self.validateModuleRegistryAccess(load);
        self.uses_module_load_runtime = true;
        self.uses_module_registry_runtime = true;
        self.uses_reu_present = true;
        self.uses_reu_copy_c64_to_reu = true;
        self.uses_reu_copy_reu_to_c64 = true;
        self.uses_module_current_activation_runtime = true;
        try self.out.writer.writeAll("    jsr zeropage_module_load_current\n");
    }

    fn emitModuleDiskLoad(self: *Emitter, load: ast.ModuleDiskLoad) !void {
        try self.validateModuleDiskLoadAccess(load);
        self.uses_module_disk_load_runtime = true;
        self.uses_module_registry_runtime = true;
        self.uses_reu_present = true;
        self.uses_reu_copy_c64_to_reu = true;
        self.uses_reu_copy_reu_to_c64 = true;
        self.uses_module_current_activation_runtime = true;
        try self.out.writer.writeAll("    jsr zeropage_module_load_from_disk_current\n");
    }

    fn emitModuleDependencyLoad(self: *Emitter, load: ast.ModuleLoad) !void {
        if (load.from_binding) {
            if (self.program.zeropage_module) |module| {
                if (std.mem.eql(u8, module.id, load.id)) return try self.emitModuleLoad(load);
            }
        }
        const row = try self.validateModuleDependencyLoadAccess(load);
        self.uses_module_dependency_load_runtime = true;
        self.uses_module_registry_runtime = true;
        self.uses_reu_present = true;
        self.uses_reu_copy_c64_to_reu = true;
        try self.module_dependency_load_rows.put(row, {});
        try self.out.writer.print("    jsr zeropage_module_load_dependency_row{d}\n", .{row});
    }

    fn emitModuleDependencyAcquire(self: *Emitter, load: ast.ModuleLoad) !void {
        if (load.from_binding) {
            if (self.program.zeropage_module) |module| {
                if (std.mem.eql(u8, module.id, load.id)) return try self.emitModuleLoad(load);
            }
        }
        const row = try self.validateModuleDependencyLoadAccess(load);
        self.uses_module_dependency_load_runtime = true;
        self.uses_module_registry_runtime = true;
        self.uses_reu_present = true;
        self.uses_reu_copy_c64_to_reu = true;
        try self.module_dependency_load_rows.put(row, {});
        try self.module_dependency_acquire_rows.put(row, {});
        try self.out.writer.print("    jsr zeropage_module_acquire_dependency_row{d}\n", .{row});
    }

    fn emitModuleDependencyGraphLoad(self: *Emitter, load: ast.ModuleLoad) !void {
        const rows = try self.dependencyGraphLoadRows(load.id);
        defer self.allocator.free(rows);
        self.uses_module_dependency_load_runtime = true;
        self.uses_module_dependency_unload_runtime = true;
        self.uses_module_registry_runtime = true;
        self.uses_reu_present = true;
        self.uses_reu_copy_c64_to_reu = true;
        for (rows) |row| {
            try self.module_dependency_load_rows.put(row, {});
            try self.module_dependency_unload_rows.put(row, {});
        }
        const id = self.module_graph_load_id;
        self.module_graph_load_id += 1;
        const w = &self.out.writer;
        try self.module_graph_load_scratch.append(self.allocator, .{ .id = id, .row_count = rows.len });
        for (rows, 0..) |row, index| {
            try w.print(
                \\    lda #0
                \\    sta zeropage_module_graph_load_{d}_row{d}_new
                \\    lda zeropage_module_registry_row{d}_loaded
                \\    bne module_dependency_graph_load_{d}_row_{d}_already_loaded
                \\    jsr zeropage_module_load_dependency_row{d}
                \\    cmp #0
                \\    beq module_dependency_graph_load_{d}_fail_{d}
                \\    lda #1
                \\    sta zeropage_module_graph_load_{d}_row{d}_new
                \\    jmp module_dependency_graph_load_{d}_row_{d}_done
                \\module_dependency_graph_load_{d}_row_{d}_already_loaded:
                \\    lda #1
                \\module_dependency_graph_load_{d}_row_{d}_done:
                \\
            , .{
                id,
                index,
                row,
                id,
                index,
                row,
                id,
                index,
                id,
                index,
                id,
                index,
                id,
                index,
                id,
                index,
            });
        }
        try w.print(
            \\    lda #1
            \\    jmp module_dependency_graph_load_{d}_done
            \\
        , .{id});
        var fail_index = rows.len;
        while (fail_index > 0) {
            fail_index -= 1;
            try w.print("module_dependency_graph_load_{d}_fail_{d}:\n", .{ id, fail_index });
            var rollback_index = fail_index;
            while (rollback_index > 0) {
                rollback_index -= 1;
                try w.print(
                    \\    lda zeropage_module_graph_load_{d}_row{d}_new
                    \\    beq module_dependency_graph_load_{d}_skip_rollback_{d}
                    \\    jsr zeropage_module_unload_dependency_row{d}
                    \\module_dependency_graph_load_{d}_skip_rollback_{d}:
                    \\
                , .{ id, rollback_index, id, rollback_index, rows[rollback_index], id, rollback_index });
            }
            try w.print(
                \\    lda #0
                \\    jmp module_dependency_graph_load_{d}_done
                \\
            , .{id});
        }
        try w.print("module_dependency_graph_load_{d}_done:\n", .{id});
    }

    fn emitModuleDependencyGraphAcquire(self: *Emitter, load: ast.ModuleLoad) !void {
        const rows = try self.dependencyGraphLoadRows(load.id);
        defer self.allocator.free(rows);
        self.uses_module_dependency_load_runtime = true;
        self.uses_module_dependency_unload_runtime = true;
        self.uses_module_registry_runtime = true;
        self.uses_reu_present = true;
        self.uses_reu_copy_c64_to_reu = true;
        for (rows) |row| {
            try self.module_dependency_load_rows.put(row, {});
            try self.module_dependency_acquire_rows.put(row, {});
            try self.module_dependency_unload_rows.put(row, {});
        }
        const id = self.module_graph_load_id;
        self.module_graph_load_id += 1;
        const w = &self.out.writer;
        try self.module_graph_load_scratch.append(self.allocator, .{ .id = id, .row_count = rows.len });
        for (rows, 0..) |row, index| {
            try w.print(
                \\    lda #0
                \\    sta zeropage_module_graph_load_{d}_row{d}_new
                \\    jsr zeropage_module_acquire_dependency_row{d}
                \\    cmp #0
                \\    beq module_dependency_graph_acquire_{d}_fail_{d}
                \\    lda #1
                \\    sta zeropage_module_graph_load_{d}_row{d}_new
                \\
            , .{ id, index, row, id, index, id, index });
        }
        try w.print(
            \\    lda #1
            \\    jmp module_dependency_graph_acquire_{d}_done
            \\
        , .{id});
        var fail_index = rows.len;
        while (fail_index > 0) {
            fail_index -= 1;
            try w.print("module_dependency_graph_acquire_{d}_fail_{d}:\n", .{ id, fail_index });
            var rollback_index = fail_index;
            while (rollback_index > 0) {
                rollback_index -= 1;
                try w.print(
                    \\    lda zeropage_module_graph_load_{d}_row{d}_new
                    \\    beq module_dependency_graph_acquire_{d}_skip_rollback_{d}
                    \\    jsr zeropage_module_unload_dependency_row{d}
                    \\module_dependency_graph_acquire_{d}_skip_rollback_{d}:
                    \\
                , .{ id, rollback_index, id, rollback_index, rows[rollback_index], id, rollback_index });
            }
            try w.print(
                \\    lda #0
                \\    jmp module_dependency_graph_acquire_{d}_done
                \\
            , .{id});
        }
        try w.print("module_dependency_graph_acquire_{d}_done:\n", .{id});
    }

    fn emitModuleDependencyGraphRelease(self: *Emitter, load: ast.ModuleLoad) !void {
        const rows = try self.dependencyGraphLoadRows(load.id);
        defer self.allocator.free(rows);
        self.uses_module_dependency_unload_runtime = true;
        self.uses_module_registry_runtime = true;
        var index = rows.len;
        while (index > 0) {
            index -= 1;
            const row = rows[index];
            try self.module_dependency_unload_rows.put(row, {});
            try self.out.writer.print("    jsr zeropage_module_unload_dependency_row{d}\n", .{row});
        }
    }

    fn emitModuleDependencyUnload(self: *Emitter, unload: ast.ModuleLoad) !void {
        if (unload.from_binding) {
            if (self.program.zeropage_module) |module| {
                if (std.mem.eql(u8, module.id, unload.id)) return try self.emitModuleUnload(unload);
            }
        }
        const row = try self.validateModuleDependencyLoadAccess(unload);
        self.uses_module_dependency_unload_runtime = true;
        self.uses_module_registry_runtime = true;
        try self.module_dependency_unload_rows.put(row, {});
        try self.out.writer.print("    jsr zeropage_module_unload_dependency_row{d}\n", .{row});
    }

    fn emitModuleIsLoaded(self: *Emitter, load: ast.ModuleLoad) !void {
        const row = try self.validateModuleIsLoadedAccess(load);
        self.uses_module_registry_runtime = true;
        if (row == 0) {
            try self.out.writer.writeAll("    jsr zeropage_module_is_loaded_current\n");
        } else {
            try self.out.writer.print("    lda zeropage_module_registry_row{d}_loaded\n", .{row});
        }
    }

    fn emitModuleUnload(self: *Emitter, unload: ast.ModuleLoad) !void {
        try self.validateModuleRegistryAccess(unload);
        self.uses_module_registry_runtime = true;
        self.uses_module_unload_runtime = true;
        try self.out.writer.writeAll("    jsr zeropage_module_unload_current\n");
    }

    fn emitModuleCallToOptional(self: *Emitter, function_name: []const u8, call: ast.ModuleCall, dest_label: []const u8, optional: ast.OptionalType) !void {
        const target = try self.validateModuleCall(call);
        if (!optionalChildTypesEqual(optional.child, moduleCallOptional(target).child)) return error.UnsupportedZeroPageModuleExport;

        switch (target) {
            .current => |current| try self.emitCurrentModuleCallToOptional(function_name, call, dest_label, optional, current),
            .dependency => |dependency| try self.emitDependencyModuleCallToOptional(function_name, call, dest_label, optional, dependency),
        }
    }

    fn emitCurrentModuleCallToOptional(self: *Emitter, function_name: []const u8, call: ast.ModuleCall, dest_label: []const u8, optional: ast.OptionalType, target: CurrentModuleCallTarget) !void {
        var layout = try frame_layout.planFunction(self.allocator, self.program, target.function, .stack);
        defer layout.deinit(self.allocator);
        if (layout.byte_size > 255) return error.UnsupportedStackFrameTooLarge;
        const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;

        self.uses_module_registry_runtime = true;
        self.uses_module_current_activation_runtime = true;
        self.uses_reu_copy_reu_to_c64 = true;
        const on_demand = self.programUsesModuleOnDemandPolicy();
        if (on_demand) {
            _ = self.program.zeropage_options.modules.?.disk_staging orelse return error.MissingZeroPageModuleLoader;
            self.uses_module_disk_load_runtime = true;
            self.uses_reu_present = true;
            self.uses_reu_copy_c64_to_reu = true;
            self.uses_reu_copy_reu_to_c64 = true;
        }
        const id = self.nextLabel();
        const w = &self.out.writer;
        if (on_demand) {
            try w.print(
                \\    lda zeropage_module_registry_loaded
                \\    cmp #0
                \\    bne module_call_{d}_loaded
                \\    jsr zeropage_module_load_from_disk_current
                \\    lda zeropage_module_registry_loaded
                \\    cmp #0
                \\    bne module_call_{d}_loaded
                \\    jmp module_call_{d}_unloaded
                \\module_call_{d}_loaded:
                \\    lda zeropage_module_registry_active_row
                \\    cmp #0
                \\    beq module_call_{d}_active
                \\    jsr zeropage_module_activate_current
                \\    lda zeropage_module_registry_active_row
                \\    cmp #0
                \\    beq module_call_{d}_active
                \\    jmp module_call_{d}_unloaded
                \\module_call_{d}_active:
                \\    lda zeropage_stack_sp
                \\    sta zeropage_stack_fp
                \\    lda zeropage_stack_sp+1
                \\    sta zeropage_stack_fp+1
                \\
            , .{ id, id, id, id, id, id, id, id });
        } else {
            try w.print(
                \\    lda zeropage_module_registry_loaded
                \\    cmp #0
                \\    bne module_call_{d}_loaded
                \\    jmp module_call_{d}_unloaded
                \\module_call_{d}_loaded:
                \\    lda zeropage_module_registry_active_row
                \\    cmp #0
                \\    beq module_call_{d}_active
                \\    jsr zeropage_module_activate_current
                \\    lda zeropage_module_registry_active_row
                \\    cmp #0
                \\    beq module_call_{d}_active
                \\    jmp module_call_{d}_unloaded
                \\module_call_{d}_active:
                \\    lda zeropage_stack_sp
                \\    sta zeropage_stack_fp
                \\    lda zeropage_stack_sp+1
                \\    sta zeropage_stack_fp+1
                \\
            , .{ id, id, id, id, id, id, id });
        }
        try self.emitSoftwareStackEnsureAvailable(layout.byte_size);

        for (target.function.params, 0..) |param, index| {
            const arg = call.args[index];
            if (frame_layout.exprContainsCall(arg)) return error.UnsupportedStackFrameBridgeArgument;
            const slot = layout.findSlot(param.name) orelse return error.UnknownVariable;
            if (isWideValueType(param.ty)) {
                try self.emitExprToAXExpected(function_name, arg, param.ty);
                try w.print("    ldy #${x:0>2}\n    sta (zeropage_stack_fp),y\n    txa\n    ldy #${x:0>2}\n    sta (zeropage_stack_fp),y\n", .{
                    @as(u8, @truncate(slot.offset)),
                    @as(u8, @truncate(slot.offset + 1)),
                });
            } else {
                try self.emitExprToAExpected(function_name, arg, param.ty);
                try w.print("    ldy #${x:0>2}\n    sta (zeropage_stack_fp),y\n", .{@as(u8, @truncate(slot.offset))});
            }
        }

        try self.emitSoftwareStackAdvanceStackPointerUnchecked(layout.byte_size);
        try self.emitModuleOrdinalDispatch(loader.load_window, target.ordinal);
        self.uses_stack_bridge_return = true;
        if (isWideValueType(target.function.return_type)) {
            try self.emitRelocatableStackReturnStoreAX();
            try self.emitSoftwareStackEpilogue();
            try w.print("    lda #1\n    sta {s}\n", .{dest_label});
            try self.emitRelocatableStackReturnLoadA();
            try w.print("    sta {s}+1\n", .{dest_label});
            try self.emitModuleRelocationAnchor("zeropage_stack_ret_hi");
            try w.print("    lda zeropage_stack_ret_hi\n    sta {s}+2\n", .{dest_label});
        } else {
            try self.emitRelocatableStackReturnStoreA();
            try self.emitSoftwareStackEpilogue();
            try w.print("    lda #1\n    sta {s}\n", .{dest_label});
            try self.emitRelocatableStackReturnLoadA();
            try w.print("    sta {s}+1\n", .{dest_label});
        }
        try w.print(
            \\    jmp module_call_{d}_done
            \\module_call_{d}_unloaded:
            \\    lda #0
            \\
        , .{ id, id });
        for (0..optionalStorageBytes(optional)) |offset| try w.print("    sta {s}+{d}\n", .{ dest_label, offset });
        try w.print("module_call_{d}_done:\n", .{id});
    }

    fn emitDependencyModuleCallToOptional(self: *Emitter, function_name: []const u8, call: ast.ModuleCall, dest_label: []const u8, optional: ast.OptionalType, target: DependencyModuleCallTarget) !void {
        self.uses_module_registry_runtime = true;
        self.uses_module_dependency_activation_runtime = true;
        self.uses_reu_copy_reu_to_c64 = true;
        try self.module_dependency_activation_rows.put(target.row, {});
        const policy = self.dependencyModulePolicy(target.module.id);
        const on_demand = if (policy) |resolved| resolved.mode == .on_demand else false;
        const graph_on_demand = if (policy) |resolved| resolved.mode == .on_demand and resolved.graph else false;
        if (on_demand) {
            _ = self.program.zeropage_options.modules.?.disk_staging orelse return error.MissingZeroPageModuleLoader;
            if (!graph_on_demand) {
                self.uses_module_dependency_load_runtime = true;
                self.uses_reu_present = true;
                self.uses_reu_copy_c64_to_reu = true;
                try self.module_dependency_load_rows.put(target.row, {});
            }
        }

        const window = try self.moduleWindowForRow(target.row);
        const active_label = try self.moduleActiveRowLabelForRow(target.row);
        defer self.allocator.free(active_label);
        const id = self.nextLabel();
        const w = &self.out.writer;
        if (on_demand) {
            try w.print(
                \\    lda zeropage_module_registry_row{d}_loaded
                \\    cmp #0
                \\    bne module_call_{d}_loaded
                \\
            , .{ target.row, id });
            if (graph_on_demand) {
                try self.emitModuleDependencyGraphLoad(.{ .id = target.module.id });
            } else {
                try w.print("    jsr zeropage_module_load_dependency_row{d}\n", .{target.row});
            }
            try w.print(
                \\    lda zeropage_module_registry_row{d}_loaded
                \\    cmp #0
                \\    bne module_call_{d}_loaded
                \\    jmp module_call_{d}_unloaded
                \\module_call_{d}_loaded:
                \\    lda {s}
                \\    cmp #{d}
                \\    beq module_call_{d}_active
                \\    jsr zeropage_module_activate_dependency_row{d}
                \\    lda {s}
                \\    cmp #{d}
                \\    beq module_call_{d}_active
                \\    jmp module_call_{d}_unloaded
                \\module_call_{d}_active:
                \\    lda zeropage_stack_sp
                \\    sta zeropage_stack_fp
                \\    lda zeropage_stack_sp+1
                \\    sta zeropage_stack_fp+1
                \\
            , .{ target.row, id, id, id, active_label, target.row, id, target.row, active_label, target.row, id, id, id });
        } else {
            try w.print(
                \\    lda zeropage_module_registry_row{d}_loaded
                \\    cmp #0
                \\    bne module_call_{d}_loaded
                \\    jmp module_call_{d}_unloaded
                \\module_call_{d}_loaded:
                \\    lda {s}
                \\    cmp #{d}
                \\    beq module_call_{d}_active
                \\    jsr zeropage_module_activate_dependency_row{d}
                \\    lda {s}
                \\    cmp #{d}
                \\    beq module_call_{d}_active
                \\    jmp module_call_{d}_unloaded
                \\module_call_{d}_active:
                \\    lda zeropage_stack_sp
                \\    sta zeropage_stack_fp
                \\    lda zeropage_stack_sp+1
                \\    sta zeropage_stack_fp+1
                \\
            , .{ target.row, id, id, id, active_label, target.row, id, target.row, active_label, target.row, id, id, id });
        }
        try self.emitSoftwareStackEnsureAvailable(target.export_decl.frame_size);

        for (target.export_decl.params, 0..) |param, index| {
            const arg = call.args[index];
            if (frame_layout.exprContainsCall(arg)) return error.UnsupportedStackFrameBridgeArgument;
            if (isWideValueType(param.ty)) {
                try self.emitExprToAXExpected(function_name, arg, param.ty);
                try w.print("    ldy #${x:0>2}\n    sta (zeropage_stack_fp),y\n    txa\n    ldy #${x:0>2}\n    sta (zeropage_stack_fp),y\n", .{
                    @as(u8, @truncate(param.offset)),
                    @as(u8, @truncate(param.offset + 1)),
                });
            } else {
                try self.emitExprToAExpected(function_name, arg, param.ty);
                try w.print("    ldy #${x:0>2}\n    sta (zeropage_stack_fp),y\n", .{@as(u8, @truncate(param.offset))});
            }
        }

        try self.emitSoftwareStackAdvanceStackPointerUnchecked(target.export_decl.frame_size);
        if (window.addr == self.program.zeropage_options.modules.?.load_window.addr) {
            try self.emitModuleOrdinalDispatch(window, target.export_decl.ordinal);
        } else {
            try self.emitModuleAssignedWindowDispatch(window, target.export_decl.ordinal);
        }
        self.uses_stack_bridge_return = true;
        if (isWideValueType(target.export_decl.return_type)) {
            try self.emitRelocatableStackReturnStoreAX();
            try self.emitSoftwareStackEpilogue();
            try w.print("    lda #1\n    sta {s}\n", .{dest_label});
            try self.emitRelocatableStackReturnLoadA();
            try w.print("    sta {s}+1\n", .{dest_label});
            try self.emitModuleRelocationAnchor("zeropage_stack_ret_hi");
            try w.print("    lda zeropage_stack_ret_hi\n    sta {s}+2\n", .{dest_label});
        } else {
            try self.emitRelocatableStackReturnStoreA();
            try self.emitSoftwareStackEpilogue();
            try w.print("    lda #1\n    sta {s}\n", .{dest_label});
            try self.emitRelocatableStackReturnLoadA();
            try w.print("    sta {s}+1\n", .{dest_label});
        }
        try w.print(
            \\    jmp module_call_{d}_done
            \\module_call_{d}_unloaded:
            \\    lda #0
            \\
        , .{ id, id });
        for (0..optionalStorageBytes(optional)) |offset| try w.print("    sta {s}+{d}\n", .{ dest_label, offset });
        try w.print("module_call_{d}_done:\n", .{id});
    }

    fn validateModuleRegistryAccess(self: *Emitter, load: ast.ModuleLoad) !void {
        const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
        if (!std.mem.eql(u8, module.id, load.id)) return error.UnknownZeroPageModule;
        if (module.deps.len != 0) return error.UnsupportedZeroPageModuleDependencyLoad;
        if (self.program.zeropage_options.modules == null) return error.MissingZeroPageModuleLoader;
    }

    fn validateModuleIsLoadedAccess(self: *Emitter, load: ast.ModuleLoad) !usize {
        const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
        _ = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
        if (std.mem.eql(u8, module.id, load.id)) return 0;
        for (module.deps, 0..) |dep, index| {
            if (std.mem.eql(u8, dep, load.id)) {
                const modules = self.program.zeropage_options.modules.?;
                _ = modules.registry orelse return error.MissingZeroPageModuleLoader;
                _ = modules.disk_manifest orelse return error.MissingZeroPageModuleLoader;
                return index + 1;
            }
        }
        const modules = self.program.zeropage_options.modules.?;
        if (modules.dependency_graph != null) {
            _ = modules.registry orelse return error.MissingZeroPageModuleLoader;
            _ = modules.disk_manifest orelse return error.MissingZeroPageModuleLoader;
            return try self.moduleRegistryRowForId(load.id);
        }
        return error.UnknownZeroPageModule;
    }

    fn validateModuleDiskLoadAccess(self: *Emitter, load: ast.ModuleDiskLoad) !void {
        const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
        if (!std.mem.eql(u8, module.id, load.id)) return error.UnknownZeroPageModule;
        if (module.deps.len != 0) return error.UnsupportedZeroPageModuleDependencyLoad;
        const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
        if (loader.disk_staging == null) return error.MissingZeroPageModuleLoader;
    }

    fn validateModuleDependencyLoadAccess(self: *Emitter, load: ast.ModuleLoad) !usize {
        const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
        if (std.mem.eql(u8, module.id, load.id)) return error.UnsupportedZeroPageModuleDependencyLoad;
        const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
        _ = loader.disk_staging orelse return error.MissingZeroPageModuleLoader;
        _ = loader.registry orelse return error.MissingZeroPageModuleLoader;
        _ = loader.disk_manifest orelse return error.MissingZeroPageModuleLoader;
        for (module.deps, 0..) |dep, index| {
            if (std.mem.eql(u8, dep, load.id)) return index + 1;
        }
        return error.UnknownZeroPageModule;
    }

    fn dependencyGraphLoadRows(self: *Emitter, id: []const u8) ![]usize {
        const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
        if (std.mem.eql(u8, module.id, id)) return error.UnsupportedZeroPageModuleDependencyLoad;
        const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
        _ = loader.disk_staging orelse return error.MissingZeroPageModuleLoader;
        _ = loader.registry orelse return error.MissingZeroPageModuleLoader;
        _ = loader.disk_manifest orelse return error.MissingZeroPageModuleLoader;
        const graph = loader.dependency_graph orelse return error.MissingZeroPageModuleLoader;
        var direct = false;
        for (module.deps) |dep| {
            if (std.mem.eql(u8, dep, id)) {
                direct = true;
                break;
            }
        }
        if (!direct) return error.UnknownZeroPageModule;
        var rows: std.ArrayList(usize) = .empty;
        errdefer rows.deinit(self.allocator);
        try self.appendDependencyGraphLoadRows(graph, id, &rows);
        return try rows.toOwnedSlice(self.allocator);
    }

    fn appendDependencyGraphLoadRows(self: *Emitter, graph: ast.ModuleDependencyGraphOptions, id: []const u8, rows: *std.ArrayList(usize)) !void {
        const node = findModuleGraphNode(graph, id) orelse return error.UnknownZeroPageModule;
        for (node.deps) |dep| try self.appendDependencyGraphLoadRows(graph, dep, rows);
        const row = try self.moduleRegistryRowForId(id);
        for (rows.items) |existing| {
            if (existing == row) return;
        }
        try rows.append(self.allocator, row);
    }

    fn moduleRegistryRowForId(self: *Emitter, id: []const u8) !usize {
        const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
        for (module.deps, 0..) |dep, index| {
            if (std.mem.eql(u8, dep, id)) return index + 1;
        }
        const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
        const graph = loader.dependency_graph orelse return error.UnknownZeroPageModule;
        var row: usize = 1 + module.deps.len;
        for (graph.nodes) |node| {
            if (findModuleDependencyOrdinal(module, node.id) != null) continue;
            if (std.mem.eql(u8, node.id, id)) return row;
            row += 1;
        }
        return error.UnknownZeroPageModule;
    }

    fn moduleRegistryIdForRow(self: *Emitter, row: usize) ![]const u8 {
        const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
        if (row == 0) return module.id;
        if (row <= module.deps.len) return module.deps[row - 1];
        const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
        const graph = loader.dependency_graph orelse return error.UnknownZeroPageModule;
        var current_row: usize = 1 + module.deps.len;
        for (graph.nodes) |node| {
            if (findModuleDependencyOrdinal(module, node.id) != null) continue;
            if (current_row == row) return node.id;
            current_row += 1;
        }
        return error.UnknownZeroPageModule;
    }

    fn validateModuleBindings(self: *Emitter) !void {
        if (self.program.module_bindings.len == 0) return;
        const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
        const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
        for (self.program.module_bindings) |binding| {
            if (std.mem.eql(u8, binding.module_id, module.id)) {
                try self.validateCurrentModuleBinding(module, binding);
                continue;
            }
            var binding_id_known = false;
            for (module.deps) |dep| {
                if (std.mem.eql(u8, dep, binding.module_id)) {
                    binding_id_known = true;
                    break;
                }
            }
            if (!binding_id_known) {
                const graph = loader.dependency_graph orelse return error.UnknownZeroPageModule;
                _ = findModuleGraphNode(graph, binding.module_id) orelse return error.UnknownZeroPageModule;
                binding_id_known = true;
            }
            if (binding.methods.len == 0) continue;
            const dependency = self.findDependencySidecar(binding.module_id) orelse return error.MissingZeroPageDependencySidecar;
            try self.validateDependencySidecarShape(loader, dependency);
            for (binding.methods) |method| {
                const export_decl = dependency.findExport(method.name) orelse return error.UnknownZeroPageModuleExport;
                if (!typesEqual(method.return_type, export_decl.return_type)) return error.InvalidZeroPageDependencySidecar;
                if (method.params.len != export_decl.params.len) return error.InvalidZeroPageDependencySidecar;
                for (method.params, 0..) |param_ty, index| {
                    if (!typesEqual(param_ty, export_decl.params[index].ty)) return error.InvalidZeroPageDependencySidecar;
                }
            }
        }
    }

    fn validateDependencySidecars(self: *Emitter) !void {
        if (self.options.dependency_modules.len == 0) return;
        const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
        const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
        for (self.options.dependency_modules) |dependency| {
            if (findModuleDependencyOrdinal(module, dependency.id) == null) {
                const graph = loader.dependency_graph orelse continue;
                _ = findModuleGraphNode(graph, dependency.id) orelse return error.UnknownZeroPageModule;
            }
            try self.validateDependencySidecarShape(loader, dependency);
        }
    }

    fn validateDependencySidecarShape(self: *Emitter, loader: ast.ModuleLoaderOptions, dependency: module_sidecars.DependencyModule) !void {
        const assignment = self.moduleWindowAssignmentForId(dependency.id);
        const assigned_window = self.moduleLoadWindowForName(loader, if (assignment) |entry| entry.window_name else "main") orelse return error.InvalidZeroPageModuleLoadWindow;
        if (assignment == null and (dependency.load_window_addr != loader.load_window.addr or dependency.load_window_size != loader.load_window.size)) return error.InvalidZeroPageDependencySidecar;
        if (assignment != null and dependency.load_window_size > assigned_window.size) return error.InvalidZeroPageDependencySidecar;
        if (dependency.payload_length > assigned_window.size) return error.ZeroPageModulePayloadTooLarge;
        for (dependency.exports) |export_decl| {
            if (assigned_window.bank == .ram_under_kernal and export_decl.requires_kernal_rom and !export_decl.kernal_trampoline_safe) return error.UnsafeKernalBankModuleExport;
            try self.validateModuleDynamicCallType(export_decl.return_type);
            for (export_decl.params) |param| try self.validateModuleDynamicCallType(param.ty);
        }
    }

    fn validateCurrentKernalBankExports(self: *Emitter) !void {
        const module = self.program.zeropage_module orelse return;
        const loader = self.program.zeropage_options.modules orelse return;
        if (loader.load_window.bank != .ram_under_kernal) return;
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();
        for (module.exports) |export_decl| {
            const function = self.program.findFunction(export_decl.function_name) orelse return error.UnknownZeroPageModuleExport;
            visited.clearRetainingCapacity();
            if ((try self.functionKernalExportPolicy(function, &visited)).isUnsupported()) return error.UnsafeKernalBankModuleExport;
        }
    }

    fn moduleWindowAssignmentForId(self: *Emitter, id: []const u8) ?ast.ModuleWindowAssignment {
        const loader = self.program.zeropage_options.modules orelse return null;
        for (loader.window_assignments) |assignment| {
            if (std.mem.eql(u8, assignment.id, id)) return assignment;
        }
        return null;
    }

    fn moduleLoadWindowForName(self: *Emitter, loader: ast.ModuleLoaderOptions, name: []const u8) ?ast.ModuleLoadWindowOptions {
        _ = self;
        if (std.mem.eql(u8, name, "main")) return loader.load_window;
        for (loader.extra_load_windows) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.window;
        }
        return null;
    }

    fn moduleWindowNameForId(self: *Emitter, id: []const u8) []const u8 {
        if (self.moduleWindowAssignmentForId(id)) |assignment| return assignment.window_name;
        return "main";
    }

    fn moduleWindowForRow(self: *Emitter, row: usize) !ast.ModuleLoadWindowOptions {
        const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
        if (row == 0) return loader.load_window;
        const id = try self.moduleRegistryIdForRow(row);
        return self.moduleLoadWindowForName(loader, self.moduleWindowNameForId(id)) orelse error.InvalidZeroPageModuleLoadWindow;
    }

    fn moduleWindowIsBanked(_: *Emitter, window: ast.ModuleLoadWindowOptions) bool {
        return window.bank != .visible;
    }

    fn programHasBankedModuleWindow(self: *Emitter) bool {
        const loader = self.program.zeropage_options.modules orelse return false;
        if (loader.load_window.bank != .visible) return true;
        for (loader.extra_load_windows) |entry| {
            if (entry.window.bank != .visible) return true;
        }
        return false;
    }

    fn emitModuleBankBegin(self: *Emitter, window: ast.ModuleLoadWindowOptions) !void {
        self.uses_module_bank_runtime = true;
        switch (window.bank) {
            .visible => {},
            .ram_under_basic => try self.out.writer.writeAll("    jsr zeropage_module_bank_enter_basic\n"),
            .ram_under_kernal => try self.out.writer.writeAll("    jsr zeropage_module_bank_enter_kernal\n"),
        }
    }

    fn emitModuleBankEnd(self: *Emitter, window: ast.ModuleLoadWindowOptions) !void {
        self.uses_module_bank_runtime = true;
        switch (window.bank) {
            .visible => {},
            .ram_under_basic => try self.out.writer.writeAll("    jsr zeropage_module_bank_exit_basic\n"),
            .ram_under_kernal => try self.out.writer.writeAll("    jsr zeropage_module_bank_exit_kernal\n"),
        }
    }

    fn emitModuleOrdinalDispatch(self: *Emitter, window: ast.ModuleLoadWindowOptions, ordinal: usize) !void {
        const w = &self.out.writer;
        if (!self.moduleWindowIsBanked(window)) {
            try w.print("    jsr zeropage_module_registry_jump_table+{d}\n", .{ordinal * 3});
            return;
        }
        try self.emitModuleDirectWindowDispatch(window, ordinal);
    }

    fn emitModuleAssignedWindowDispatch(self: *Emitter, window: ast.ModuleLoadWindowOptions, ordinal: usize) !void {
        if (!self.moduleWindowIsBanked(window)) {
            try self.out.writer.print("    jsr ${x:0>4}\n", .{@as(u16, @intCast(@as(usize, window.addr) + ordinal * 3))});
            return;
        }
        try self.emitModuleDirectWindowDispatch(window, ordinal);
    }

    fn emitModuleDirectWindowDispatch(self: *Emitter, window: ast.ModuleLoadWindowOptions, ordinal: usize) !void {
        const w = &self.out.writer;
        try self.emitModuleBankBegin(window);
        try w.print("    jsr ${x:0>4}\n", .{@as(u16, @intCast(@as(usize, window.addr) + ordinal * 3))});
        try w.writeAll(
            \\    sta zeropage_module_bank_saved_a
            \\    stx zeropage_module_bank_saved_x
            \\
        );
        try self.emitModuleBankEnd(window);
        try w.writeAll(
            \\    ldx zeropage_module_bank_saved_x
            \\    lda zeropage_module_bank_saved_a
            \\
        );
    }

    fn moduleActiveRowLabelForWindowName(self: *Emitter, window_name: []const u8) ![]const u8 {
        if (std.mem.eql(u8, window_name, "main")) return self.allocator.dupe(u8, "zeropage_module_registry_active_row");
        return std.fmt.allocPrint(self.allocator, "zeropage_module_registry_active_row_{s}", .{window_name});
    }

    fn moduleActiveRowLabelForRow(self: *Emitter, row: usize) ![]const u8 {
        if (row == 0) return self.moduleActiveRowLabelForWindowName("main");
        const id = try self.moduleRegistryIdForRow(row);
        return self.moduleActiveRowLabelForWindowName(self.moduleWindowNameForId(id));
    }

    fn moduleStateSaveActiveDependencyLabelForWindowName(self: *Emitter, window_name: []const u8) ![]const u8 {
        if (std.mem.eql(u8, window_name, "main")) return self.allocator.dupe(u8, "zeropage_module_state_save_active_dependency");
        return std.fmt.allocPrint(self.allocator, "zeropage_module_state_save_active_dependency_{s}", .{window_name});
    }

    fn moduleStateSaveActiveDependencyLabelForRow(self: *Emitter, row: usize) ![]const u8 {
        if (row == 0) return self.moduleStateSaveActiveDependencyLabelForWindowName("main");
        const id = try self.moduleRegistryIdForRow(row);
        return self.moduleStateSaveActiveDependencyLabelForWindowName(self.moduleWindowNameForId(id));
    }

    fn validateCurrentModuleBinding(self: *Emitter, module: ast.ZeroPageModule, binding: ast.ModuleBinding) !void {
        for (binding.methods) |method| {
            var matched_export: ?ast.ModuleExport = null;
            for (module.exports) |export_decl| {
                if (std.mem.eql(u8, export_decl.name, method.name)) {
                    matched_export = export_decl;
                    break;
                }
            }
            const export_decl = matched_export orelse return error.UnknownZeroPageModuleExport;
            const function = self.program.findFunction(export_decl.function_name) orelse return error.UnknownZeroPageModuleExport;
            try self.validateModuleDynamicCallType(function.return_type);
            if (!typesEqual(method.return_type, function.return_type)) return error.UnsupportedZeroPageModuleExport;
            if (method.params.len != function.params.len) return error.UnsupportedZeroPageModuleExport;
            for (method.params, 0..) |param_ty, index| {
                try self.validateModuleDynamicCallType(function.params[index].ty);
                if (!typesEqual(param_ty, function.params[index].ty)) return error.UnsupportedZeroPageModuleExport;
            }
        }
    }

    const CurrentModuleCallTarget = struct {
        function: ast.Function,
        ordinal: usize,
        optional: ast.OptionalType,
    };

    const DependencyModuleCallTarget = struct {
        row: usize,
        module: module_sidecars.DependencyModule,
        export_decl: module_sidecars.DependencyExport,
        optional: ast.OptionalType,
    };

    const ModuleCallTarget = union(enum) {
        current: CurrentModuleCallTarget,
        dependency: DependencyModuleCallTarget,
    };

    fn moduleCallOptional(target: ModuleCallTarget) ast.OptionalType {
        return switch (target) {
            .current => |current| current.optional,
            .dependency => |dependency| dependency.optional,
        };
    }

    fn validateModuleCall(self: *Emitter, call: ast.ModuleCall) !ModuleCallTarget {
        const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
        if (self.program.zeropage_options.modules == null) return error.MissingZeroPageModuleLoader;

        if (!std.mem.eql(u8, module.id, call.id)) return try self.validateDependencyModuleCall(module, call);
        for (module.exports, 0..) |export_decl, ordinal| {
            if (!std.mem.eql(u8, export_decl.name, call.export_name)) continue;
            const function = self.program.findFunction(export_decl.function_name) orelse return error.UnknownZeroPageModuleExport;
            if (function.return_type == .void) return error.UnsupportedZeroPageModuleExport;
            try self.validateModuleDynamicCallType(function.return_type);
            for (function.params) |param| try self.validateModuleDynamicCallType(param.ty);
            if (function.params.len != call.args.len) return error.ArgumentCountMismatch;
            var optional: ast.OptionalType = undefined;
            optional.child = switch (function.return_type) {
                .bool => .{ .scalar = .bool },
                .u8 => .{ .scalar = .u8 },
                .i8 => .{ .scalar = .i8 },
                .u16 => .{ .scalar = .u16 },
                .i16 => .{ .scalar = .i16 },
                .usize => .{ .scalar = .usize },
                .custom => |name| .{ .custom = name },
                else => return error.UnsupportedZeroPageModuleExport,
            };
            return .{ .current = .{ .function = function, .ordinal = ordinal, .optional = optional } };
        }
        return error.UnknownZeroPageModuleExport;
    }

    fn validateDependencyModuleCall(self: *Emitter, module: ast.ZeroPageModule, call: ast.ModuleCall) !ModuleCallTarget {
        const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
        const direct = findModuleDependencyOrdinal(module, call.id) != null;
        if (!direct) {
            const graph = loader.dependency_graph orelse return error.UnknownZeroPageModule;
            _ = findModuleGraphNode(graph, call.id) orelse return error.UnknownZeroPageModule;
        }

        _ = loader.registry orelse return error.MissingZeroPageModuleLoader;
        _ = loader.disk_manifest orelse return error.MissingZeroPageModuleLoader;

        const row = try self.moduleRegistryRowForId(call.id);
        const dependency = self.findDependencySidecar(call.id) orelse return error.MissingZeroPageDependencySidecar;
        try self.validateDependencySidecarShape(loader, dependency);
        const export_decl = dependency.findExport(call.export_name) orelse return error.UnknownZeroPageModuleExport;
        if (export_decl.params.len != call.args.len) return error.ArgumentCountMismatch;
        var optional: ast.OptionalType = undefined;
        optional.child = switch (export_decl.return_type) {
            .bool => .{ .scalar = .bool },
            .u8 => .{ .scalar = .u8 },
            .i8 => .{ .scalar = .i8 },
            .u16 => .{ .scalar = .u16 },
            .i16 => .{ .scalar = .i16 },
            .usize => .{ .scalar = .usize },
            else => return error.UnsupportedZeroPageModuleExport,
        };
        return .{ .dependency = .{ .row = row, .module = dependency, .export_decl = export_decl, .optional = optional } };
    }

    fn findDependencySidecar(self: *Emitter, id: []const u8) ?module_sidecars.DependencyModule {
        for (self.options.dependency_modules) |dependency| {
            if (std.mem.eql(u8, dependency.id, id)) return dependency;
        }
        return null;
    }

    fn validateModuleDynamicCallType(self: *Emitter, ty: ast.Type) !void {
        return switch (ty) {
            .bool, .u8, .i8, .u16, .i16, .usize => {},
            .custom => |name| {
                if (self.program.findEnum(name) == null) return error.UnsupportedZeroPageModuleExport;
            },
            else => error.UnsupportedZeroPageModuleExport,
        };
    }

    fn emitReuCompare(self: *Emitter, function_name: []const u8, transfer: ast.ReuTransfer) !void {
        self.uses_reu_compare = true;
        try self.emitReuTransferSetup(function_name, transfer);
        try self.out.writer.writeAll("    jsr zeropage_reu_compare\n");
    }

    fn emitReuTransferSetup(self: *Emitter, function_name: []const u8, transfer: ast.ReuTransfer) !void {
        try self.emitExprToAXExpected(function_name, transfer.c64_addr.*, .u16);
        try self.out.writer.writeAll("    sta zeropage_reu_c64_addr\n    stx zeropage_reu_c64_addr+1\n");
        try self.emitReuAddrImmediate(transfer.reu_addr);
        try self.emitExprToAXExpected(function_name, transfer.len.*, .u16);
        try self.out.writer.writeAll("    sta zeropage_reu_len\n    stx zeropage_reu_len+1\n");
    }

    fn emitReuFillSetup(self: *Emitter, function_name: []const u8, fill: ast.ReuFill) !void {
        try self.emitReuAddrImmediate(fill.reu_addr);
        try self.emitExprToAExpected(function_name, fill.value.*, .u8);
        try self.out.writer.writeAll("    sta zeropage_reu_fill_byte\n");
        try self.emitExprToAXExpected(function_name, fill.len.*, .u16);
        try self.out.writer.writeAll("    sta zeropage_reu_len\n    stx zeropage_reu_len+1\n");
    }

    fn emitReuFarCopySetup(self: *Emitter, function_name: []const u8, copy: ast.ReuFarCopy) !void {
        try self.emitFarHandleAddrToReuAddr(function_name, copy.far.*);
        try self.emitExprToAXExpected(function_name, copy.c64_addr.*, .u16);
        try self.out.writer.writeAll("    sta zeropage_reu_c64_addr\n    stx zeropage_reu_c64_addr+1\n");
        try self.emitExprToAXExpected(function_name, copy.len.*, .u16);
        try self.out.writer.writeAll("    sta zeropage_reu_len\n    stx zeropage_reu_len+1\n");
    }

    fn emitFarHandleAddrToReuAddr(self: *Emitter, function_name: []const u8, expr: ast.Expr) !void {
        const ty = try self.exprType(function_name, expr);
        if (ty != .far_bytes) return error.UnsupportedPointerType;
        switch (expr) {
            .value => |value| switch (value) {
                .ident => |ident| {
                    try self.out.writer.print(
                        "    lda {s}_{s}\n    sta zeropage_reu_addr\n    lda {s}_{s}+1\n    sta zeropage_reu_addr+1\n    lda {s}_{s}+2\n    sta zeropage_reu_addr+2\n",
                        .{ function_name, ident, function_name, ident, function_name, ident },
                    );
                    return;
                },
                else => {},
            },
            else => {},
        }
        return error.UnsupportedPointerType;
    }

    fn emitReuAddrImmediate(self: *Emitter, reu_addr: u32) !void {
        try self.out.writer.print(
            \\    lda #${x:0>2}
            \\    sta zeropage_reu_addr
            \\    lda #${x:0>2}
            \\    sta zeropage_reu_addr+1
            \\    lda #${x:0>2}
            \\    sta zeropage_reu_addr+2
            \\
        , .{
            @as(u8, @truncate(reu_addr)),
            @as(u8, @truncate(reu_addr >> 8)),
            @as(u8, @truncate(reu_addr >> 16)),
        });
    }

    fn test6502Label(self: *Emitter, call: ast.Test6502Call) ![]const u8 {
        return test6502_emit.labelForCall(self, call);
    }

    fn test6502StringLabel(self: *Emitter, expect: ast.ExpectString) ![]const u8 {
        return test6502_emit.stringLabel(self, expect);
    }

    fn ensureTest6502Hook(self: *Emitter, label: []const u8) ![]const u8 {
        return test6502_emit.ensureHook(self, label);
    }

    fn emitTest6502Stubs(self: *Emitter) !void {
        try test6502_emit.emitStubs(self);
    }

    pub fn emitTest6502ExpectNull(self: *Emitter, function_name: []const u8, expect: ast.ExpectOptional) !void {
        const optional = try self.expectOptionalExpr(function_name, expect.actual);
        try self.emitOptionalPresentToA(function_name, expect.actual, optional);
        const label = try std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_equal_bool_{x:0>4}_0000", .{expect.id});
        const stable_label = try self.ensureTest6502Hook(label);
        try self.out.writer.print("    jsr {s}\n", .{stable_label});
    }

    pub fn emitTest6502ExpectSome(self: *Emitter, function_name: []const u8, expect: ast.ExpectExpr, expected_kind: ast.ScalarType) !void {
        const optional = try self.expectOptionalExpr(function_name, expect.actual);
        const payload_ty = optionalPayloadType(optional);
        switch (expected_kind) {
            .bool => if (payload_ty != .bool) return error.TypeMismatch,
            .u8 => switch (payload_ty) {
                .u8, .i8 => {},
                .custom => {},
                else => return error.TypeMismatch,
            },
            .u16 => switch (payload_ty) {
                .u16, .i16, .usize => {},
                else => return error.TypeMismatch,
            },
            .usize => if (payload_ty != .pointer) return error.TypeMismatch,
            else => return error.TypeMismatch,
        }

        try self.emitOptionalExprToTemp(function_name, expect.actual, optional);
        try self.emitOptionalPresentFromLabelToA("zeropage_optional_tmp", optional);
        if (optional.child == .pointer) {
            const id = self.nextLabel();
            try self.out.writer.print(
                \\    cmp #0
                \\    beq optional_some_{d}_missing
                \\    lda #1
                \\    jmp optional_some_{d}_present_done
                \\optional_some_{d}_missing:
                \\    lda #0
                \\optional_some_{d}_present_done:
                \\
            , .{ id, id, id, id });
        }
        const present_label = try std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_equal_bool_{x:0>4}_0001", .{expect.id});
        const stable_present_label = try self.ensureTest6502Hook(present_label);
        try self.out.writer.print("    jsr {s}\n", .{stable_present_label});

        try self.emitOptionalPayloadFromLabelToAOrAX("zeropage_optional_tmp", optional);
        const value_label = switch (expected_kind) {
            .bool => try std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_equal_bool_{x:0>4}_{x:0>4}", .{ expect.id, expect.expected }),
            .u8 => try std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_equal_u8_{x:0>4}_{x:0>4}", .{ expect.id, expect.expected }),
            .u16, .usize => try std.fmt.allocPrint(self.allocator, "zeropage_test6502_expect_equal_u16_{x:0>4}_{x:0>4}", .{ expect.id, expect.expected }),
            else => unreachable,
        };
        const stable_value_label = try self.ensureTest6502Hook(value_label);
        try self.out.writer.print("    jsr {s}\n", .{stable_value_label});
    }

    fn rewriteInlineAsmOperand(self: *Emitter, function: ast.Function, mnemonic: []const u8, operand: []const u8) ![]u8 {
        return inline_asm_emit.rewriteOperand(self, function, mnemonic, operand);
    }

    pub fn expectBinding(self: *Emitter, function_name: []const u8, name: []const u8) anyerror!Binding {
        return (try self.findBinding(function_name, name)) orelse error.UnknownVariable;
    }

    fn findBinding(self: *Emitter, function_name: []const u8, name: []const u8) anyerror!?Binding {
        const function = self.findFunction(function_name) orelse return error.UnknownFunction;
        for (function.params) |param| {
            if (std.mem.eql(u8, param.name, name)) return .{ .ty = param.ty, .mutable = true };
            if (self.isStructType(param.ty) and std.mem.startsWith(u8, name, param.name) and name.len > param.name.len and name[param.name.len] == '_') {
                const suffix = name[param.name.len + 1 ..];
                if (try self.resolveStructPathType(param.ty.custom, suffix)) |ty| return .{ .ty = ty, .mutable = true };
            }
        }
        return try self.findBindingInStmts(function_name, function.body, name);
    }

    fn findBindingInStmts(self: *Emitter, function_name: []const u8, statements: []const ast.Stmt, name: []const u8) anyerror!?Binding {
        for (statements) |stmt| {
            switch (stmt) {
                .var_decl => |decl| {
                    if (std.mem.eql(u8, decl.name, name)) {
                        const decl_ty = try self.localDeclType(function_name, decl);
                        return .{
                            .ty = decl_ty,
                            .mutable = decl.mutable,
                            .inline_asm_allowed = decl.mutable,
                        };
                    }
                    if (std.mem.startsWith(u8, name, decl.name) and name.len > decl.name.len and name[decl.name.len] == '_') {
                        const decl_ty = try self.localDeclType(function_name, decl);
                        const suffix = name[decl.name.len + 1 ..];
                        if (self.isStructType(decl_ty)) {
                            if (try self.resolveStructPathType(decl_ty.custom, suffix)) |ty| return .{ .ty = ty, .mutable = decl.mutable };
                        }
                    }
                    if (try self.findBindingInExpr(function_name, decl.init, name)) |binding| return binding;
                },
                .assign => |assign| if (try self.findBindingInExpr(function_name, assign.value, name)) |binding| return binding,
                .add_assign => |assign| if (try self.findBindingInExpr(function_name, assign.value, name)) |binding| return binding,
                .sub_assign => |assign| if (try self.findBindingInExpr(function_name, assign.value, name)) |binding| return binding,
                .mul_assign => |assign| if (try self.findBindingInExpr(function_name, assign.value, name)) |binding| return binding,
                .bit_and_assign => |assign| if (try self.findBindingInExpr(function_name, assign.value, name)) |binding| return binding,
                .bit_or_assign => |assign| if (try self.findBindingInExpr(function_name, assign.value, name)) |binding| return binding,
                .bit_xor_assign => |assign| if (try self.findBindingInExpr(function_name, assign.value, name)) |binding| return binding,
                .shl_assign => |assign| if (try self.findBindingInExpr(function_name, assign.value, name)) |binding| return binding,
                .shr_assign => |assign| if (try self.findBindingInExpr(function_name, assign.value, name)) |binding| return binding,
                .deref_assign => |assign| {
                    if (try self.findBindingInExpr(function_name, assign.target, name)) |binding| return binding;
                    if (try self.findBindingInExpr(function_name, assign.value, name)) |binding| return binding;
                },
                .array_assign => |assign| if (try self.findBindingInArrayAssign(function_name, assign, name)) |binding| return binding,
                .array_add_assign => |assign| if (try self.findBindingInArrayAssign(function_name, assign, name)) |binding| return binding,
                .array_sub_assign => |assign| if (try self.findBindingInArrayAssign(function_name, assign, name)) |binding| return binding,
                .array_mul_assign => |assign| if (try self.findBindingInArrayAssign(function_name, assign, name)) |binding| return binding,
                .array_bit_and_assign => |assign| if (try self.findBindingInArrayAssign(function_name, assign, name)) |binding| return binding,
                .array_bit_or_assign => |assign| if (try self.findBindingInArrayAssign(function_name, assign, name)) |binding| return binding,
                .array_bit_xor_assign => |assign| if (try self.findBindingInArrayAssign(function_name, assign, name)) |binding| return binding,
                .array_shl_assign => |assign| if (try self.findBindingInArrayAssign(function_name, assign, name)) |binding| return binding,
                .array_shr_assign => |assign| if (try self.findBindingInArrayAssign(function_name, assign, name)) |binding| return binding,
                .array_field_assign => |assign| {
                    if (try self.findBindingInExpr(function_name, assign.index, name)) |binding| return binding;
                    if (try self.findBindingInExpr(function_name, assign.value, name)) |binding| return binding;
                },
                .discard => |expr| if (try self.findBindingInExpr(function_name, expr, name)) |binding| return binding,
                .while_stmt => |while_stmt| {
                    if (try self.findBindingInExpr(function_name, while_stmt.condition, name)) |binding| return binding;
                    if (try self.findBindingInStmts(function_name, while_stmt.body, name)) |binding| return binding;
                },
                .for_stmt => |for_stmt| {
                    if (for_stmt.item_name) |item_name| {
                        if (std.mem.eql(u8, item_name, name)) return .{ .ty = try self.forItemType(function_name, for_stmt), .mutable = false };
                    }
                    if (for_stmt.index_name) |index_name| {
                        if (std.mem.eql(u8, index_name, name)) return .{ .ty = .usize, .mutable = false };
                    }
                    if (try self.findBindingInStmts(function_name, for_stmt.body, name)) |binding| return binding;
                },
                .switch_stmt => |switch_stmt| {
                    if (try self.findBindingInExpr(function_name, switch_stmt.operand, name)) |binding| return binding;
                    const operand_ty = try self.exprType(function_name, switch_stmt.operand);
                    for (switch_stmt.prongs) |prong| {
                        if (prong.payload_name) |payload_name| {
                            if (std.mem.eql(u8, payload_name, name)) {
                                const payload_ty = (try self.switchPayloadTypeForSelectors(operand_ty, prong.selectors)) orelse return error.UnsupportedSwitchPayload;
                                return .{ .ty = payload_ty, .mutable = false };
                            }
                        }
                        if (try self.findBindingInStmts(function_name, prong.body, name)) |binding| return binding;
                    }
                },
                .if_stmt => |if_stmt| {
                    if (try self.findBindingInExpr(function_name, if_stmt.condition, name)) |binding| return binding;
                    if (if_stmt.payload_name) |payload_name| {
                        if (std.mem.eql(u8, payload_name, name)) {
                            const optional_ty = try self.expectOptionalExpr(function_name, if_stmt.condition);
                            return .{ .ty = optionalPayloadType(optional_ty), .mutable = false };
                        }
                    }
                    if (try self.findBindingInStmts(function_name, if_stmt.then_body, name)) |binding| return binding;
                    if (try self.findBindingInStmts(function_name, if_stmt.else_body, name)) |binding| return binding;
                },
                .call => |call| for (call.args) |arg| {
                    if (try self.findBindingInExpr(function_name, arg, name)) |binding| return binding;
                },
                .return_expr => |expr| if (try self.findBindingInExpr(function_name, expr, name)) |binding| return binding,
                .break_expr => |break_expr| if (try self.findBindingInExpr(function_name, break_expr.value, name)) |binding| return binding,
                .test6502 => |call| if (try self.findBindingInTest6502Call(function_name, call, name)) |binding| return binding,
                .builtin => |builtin| if (try self.findBindingInBuiltin(function_name, builtin, name)) |binding| return binding,
                .reu => |call| if (try self.findBindingInReuStmt(function_name, call, name)) |binding| return binding,
                .heap_free => |free| if (try self.findBindingInExpr(function_name, free.ptr.*, name)) |binding| return binding,
                .field_assign => |field| if (try self.findBindingInExpr(function_name, field.value, name)) |binding| return binding,
                .struct_var => |struct_var| {
                    if (std.mem.eql(u8, struct_var.name, name)) return .{ .ty = .{ .custom = struct_var.type_name }, .mutable = struct_var.mutable };
                    if (std.mem.startsWith(u8, name, struct_var.name) and name.len > struct_var.name.len and name[struct_var.name.len] == '_') {
                        const suffix = name[struct_var.name.len + 1 ..];
                        if (try self.resolveStructPathType(struct_var.type_name, suffix)) |ty| return .{ .ty = ty, .mutable = struct_var.mutable };
                    }
                    for (struct_var.fields) |field| {
                        if (try self.findBindingInExpr(function_name, field.value, name)) |binding| return binding;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn resolveStructPathType(self: *Emitter, struct_name: []const u8, suffix: []const u8) !?ast.Type {
        const decl = self.program.findStruct(struct_name) orelse return error.UnsupportedStruct;
        for (decl.fields) |field| {
            if (std.mem.eql(u8, suffix, field.name)) return field.ty;
            if (std.mem.startsWith(u8, suffix, field.name) and suffix.len > field.name.len and suffix[field.name.len] == '_') {
                const rest = suffix[field.name.len + 1 ..];
                switch (field.ty) {
                    .custom => |nested| {
                        if (self.program.findStruct(nested) != null) {
                            if (try self.resolveStructPathType(nested, rest)) |ty| return ty;
                        }
                    },
                    else => {},
                }
            }
        }
        return null;
    }

    fn typeStorageBytesForOffset(self: *Emitter, ty: ast.Type) anyerror!u16 {
        return switch (ty) {
            .void => 0,
            .u16, .i16, .usize, .pointer => 2,
            .far_bytes, .far_view => 5,
            .near_view => 2,
            .array => |array_ty| try self.arrayStorageBytesForOffset(array_ty),
            .optional => |optional| if (optional.child == .pointer)
                2
            else
                1 + try self.optionalPayloadBytesForOffset(optional.child),
            .custom => |custom| if (self.program.findStruct(custom) != null)
                try self.structStorageBytesForOffset(custom)
            else if (self.program.findUnion(custom) != null)
                try self.unionStorageBytes(custom)
            else if (self.program.findEnum(custom) != null)
                1
            else
                error.UnsupportedStruct,
            else => 1,
        };
    }

    fn optionalPayloadBytesForOffset(self: *Emitter, child: ast.OptionalChildType) anyerror!u16 {
        return switch (child) {
            .scalar => |scalar| switch (scalar) {
                .u16, .i16, .usize => 2,
                else => 1,
            },
            .pointer => 2,
            .far_bytes => 5,
            .near_view => 2,
            .custom => |custom| if (self.program.findEnum(custom) != null)
                1
            else
                error.UnsupportedOptional,
        };
    }

    fn arrayStorageBytesForOffset(self: *Emitter, ty: ast.ArrayType) anyerror!u16 {
        const elem_size = try self.arrayElemStorageBytesForOffset(ty.elem);
        const total = @as(u32, ty.len) * @as(u32, elem_size);
        return std.math.cast(u16, total) orelse error.Overflow;
    }

    fn arrayElemStorageBytesForOffset(self: *Emitter, elem: ast.ArrayElemType) anyerror!u16 {
        return switch (elem) {
            .scalar => |scalar| switch (scalar) {
                .u16, .i16, .usize => 2,
                else => 1,
            },
            .custom => |custom| if (self.program.findEnum(custom) != null)
                1
            else if (self.program.findStruct(custom) != null)
                try self.structStorageBytesForOffset(custom)
            else
                error.UnsupportedArrayType,
        };
    }

    fn structStorageBytesForOffset(self: *Emitter, struct_name: []const u8) anyerror!u16 {
        const decl = self.program.findStruct(struct_name) orelse return error.UnsupportedStruct;
        var total: u16 = 0;
        for (decl.fields) |field| total += try self.typeStorageBytesForOffset(field.ty);
        return total;
    }

    fn offsetOf(self: *Emitter, ty: ast.Type, field_path: []const u8) anyerror!u16 {
        if (ty != .custom or self.program.findStruct(ty.custom) == null) return error.UnsupportedStruct;
        return try self.offsetOfStruct(ty.custom, field_path);
    }

    fn offsetOfStruct(self: *Emitter, struct_name: []const u8, field_path: []const u8) anyerror!u16 {
        const decl = self.program.findStruct(struct_name) orelse return error.UnsupportedStruct;
        const dot = std.mem.indexOfScalar(u8, field_path, '.');
        const head = if (dot) |idx| field_path[0..idx] else field_path;
        if (head.len == 0) return error.UnknownField;
        const tail = if (dot) |idx| field_path[idx + 1 ..] else "";
        var offset: u16 = 0;
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, head)) {
                if (tail.len == 0) return offset;
                if (field.ty != .custom or self.program.findStruct(field.ty.custom) == null) return error.UnknownField;
                return offset + try self.offsetOfStruct(field.ty.custom, tail);
            }
            offset += try self.typeStorageBytesForOffset(field.ty);
        }
        return error.UnknownField;
    }

    fn layoutComptimeValue(self: *Emitter, expr: ast.Expr) anyerror!u16 {
        return switch (expr) {
            .size_of => |ty| try self.typeStorageBytesForOffset(ty),
            .align_of => |ty| blk: {
                _ = try self.typeStorageBytesForOffset(ty);
                break :blk 1;
            },
            .offset_of => |offset| try self.offsetOf(offset.ty, offset.field_path),
            else => unreachable,
        };
    }

    fn resolveStructPathInfo(self: *Emitter, struct_name: []const u8, suffix: []const u8) anyerror!?StructPathInfo {
        const decl = self.program.findStruct(struct_name) orelse return error.UnsupportedStruct;
        var offset: u16 = 0;
        for (decl.fields) |field| {
            if (std.mem.eql(u8, suffix, field.name)) {
                return .{ .ty = field.ty, .offset = offset };
            }
            if (std.mem.startsWith(u8, suffix, field.name) and suffix.len > field.name.len and suffix[field.name.len] == '_') {
                const rest = suffix[field.name.len + 1 ..];
                switch (field.ty) {
                    .custom => |nested| {
                        if (self.program.findStruct(nested) != null) {
                            if (try self.resolveStructPathInfo(nested, rest)) |info| {
                                return .{ .ty = info.ty, .offset = offset + info.offset };
                            }
                        }
                    },
                    else => {},
                }
            }
            offset += try self.typeStorageBytesForOffset(field.ty);
        }
        return null;
    }

    fn pointerStructName(self: *Emitter, ty: ast.Type) ?[]const u8 {
        if (ty != .pointer or ty.pointer.is_many or ty.pointer.is_volatile) return null;
        return switch (ty.pointer.child) {
            .custom => |name| if (self.program.findStruct(name) != null) name else null,
            else => null,
        };
    }

    fn resolvePointerStructPath(self: *Emitter, function_name: []const u8, flat_name: []const u8) anyerror!?PointerStructPath {
        var end = flat_name.len;
        while (std.mem.lastIndexOfScalar(u8, flat_name[0..end], '_')) |split| {
            const prefix = flat_name[0..split];
            const suffix = flat_name[split + 1 ..];
            if (try self.findBinding(function_name, prefix)) |binding| {
                if (self.pointerStructName(binding.ty)) |struct_name| {
                    if (try self.resolveStructPathInfo(struct_name, suffix)) |info| {
                        const pointer_label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ function_name, prefix });
                        return .{ .pointer_label = pointer_label, .pointer_label_owned = true, .ty = info.ty, .offset = info.offset };
                    }
                }
            }
            end = split;
        }
        return null;
    }

    fn resolvePointerStructArrayPath(self: *Emitter, function_name: []const u8, flat_name: []const u8) anyerror!?PointerStructArrayPath {
        const path = (try self.resolvePointerStructPath(function_name, flat_name)) orelse return null;
        if (path.ty != .array) {
            path.deinit(self.allocator);
            return null;
        }
        return .{
            .pointer_label = path.pointer_label,
            .pointer_label_owned = path.pointer_label_owned,
            .ty = path.ty.array,
            .offset = path.offset,
        };
    }

    fn findBindingInExpr(self: *Emitter, function_name: []const u8, expr: ast.Expr, name: []const u8) anyerror!?Binding {
        return switch (expr) {
            .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| blk: {
                if (try self.findBindingInExpr(function_name, binary.lhs.*, name)) |binding| break :blk binding;
                if (try self.findBindingInExpr(function_name, binary.rhs.*, name)) |binding| break :blk binding;
                break :blk null;
            },
            .not, .bit_not, .deref, .ptr_from_int, .int_from_ptr => |child| try self.findBindingInExpr(function_name, child.*, name),
            .as_cast => |as_cast| try self.findBindingInExpr(function_name, as_cast.expr.*, name),
            .address_of, .size_of, .align_of, .offset_of => null,
            .if_expr => |if_expr| blk: {
                if (try self.findBindingInExpr(function_name, if_expr.condition.*, name)) |binding| break :blk binding;
                if (if_expr.payload_name) |payload_name| {
                    if (std.mem.eql(u8, payload_name, name)) {
                        const optional_ty = try self.expectOptionalExpr(function_name, if_expr.condition.*);
                        break :blk .{ .ty = optionalPayloadType(optional_ty), .mutable = false };
                    }
                }
                if (try self.findBindingInExpr(function_name, if_expr.then_expr.*, name)) |binding| break :blk binding;
                if (try self.findBindingInExpr(function_name, if_expr.else_expr.*, name)) |binding| break :blk binding;
                break :blk null;
            },
            .switch_expr => |switch_expr| blk: {
                if (try self.findBindingInExpr(function_name, switch_expr.operand.*, name)) |binding| break :blk binding;
                const operand_ty = try self.exprType(function_name, switch_expr.operand.*);
                for (switch_expr.prongs) |prong| {
                    if (prong.payload_name) |payload_name| {
                        if (std.mem.eql(u8, payload_name, name)) {
                            const payload_ty = (try self.switchPayloadTypeForSelectors(operand_ty, prong.selectors)) orelse return error.UnsupportedSwitchPayload;
                            break :blk .{ .ty = payload_ty, .mutable = false };
                        }
                    }
                    if (try self.findBindingInExpr(function_name, prong.value, name)) |binding| break :blk binding;
                }
                break :blk null;
            },
            .block_expr => |block_expr| try self.findBindingInStmts(function_name, block_expr.body, name),
            .call => |call| blk: {
                for (call.args) |arg| {
                    if (try self.findBindingInExpr(function_name, arg, name)) |binding| break :blk binding;
                }
                break :blk null;
            },
            .array_literal => |literal| blk: {
                for (literal.values) |value| {
                    if (try self.findBindingInExpr(function_name, value, name)) |binding| break :blk binding;
                }
                break :blk null;
            },
            .struct_literal => |literal| blk: {
                for (literal.fields) |field| {
                    if (try self.findBindingInExpr(function_name, field.value, name)) |binding| break :blk binding;
                }
                break :blk null;
            },
            .array_index => |index| try self.findBindingInExpr(function_name, index.index.*, name),
            .array_field_index => |index| try self.findBindingInExpr(function_name, index.index.*, name),
            .reu_compare => |transfer| try self.findBindingInReuTransfer(function_name, transfer, name),
            .reu_heap_alloc => |alloc| try self.findBindingInExpr(function_name, alloc.len.*, name),
            .reu_view => |view| try self.findBindingInExpr(function_name, view.far.*, name),
            .far_view_materialize => null,
            .far_view_materialize_range => |range| try self.findBindingInExpr(function_name, range.start.*, name),
            .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded => null,
            .module_call => |call| blk: {
                for (call.args) |arg| if (try self.findBindingInExpr(function_name, arg, name)) |binding| break :blk binding;
                break :blk null;
            },
            .heap_alloc => |alloc| try self.findBindingInExpr(function_name, alloc.len.*, name),
            .value, .c64_read_petscii, .c64_wait_petscii, .reu_present => null,
        };
    }

    fn findBindingInArrayAssign(self: *Emitter, function_name: []const u8, assign: ast.ArrayAssign, name: []const u8) anyerror!?Binding {
        if (try self.findBindingInExpr(function_name, assign.index, name)) |binding| return binding;
        return try self.findBindingInExpr(function_name, assign.value, name);
    }

    fn findBindingInTest6502Call(self: *Emitter, function_name: []const u8, call: ast.Test6502Call, name: []const u8) anyerror!?Binding {
        return switch (call) {
            .expect_equal_u8 => |expect| try self.findBindingInExpr(function_name, expect.actual, name),
            .expect_equal_i8 => |expect| try self.findBindingInExpr(function_name, expect.actual, name),
            .expect_equal_bool => |expect| try self.findBindingInExpr(function_name, expect.actual, name),
            .expect_equal_u16 => |expect| try self.findBindingInExpr(function_name, expect.actual, name),
            .expect_null => |expect| try self.findBindingInExpr(function_name, expect.actual, name),
            .expect_some_u8 => |expect| try self.findBindingInExpr(function_name, expect.actual, name),
            .expect_some_u16 => |expect| try self.findBindingInExpr(function_name, expect.actual, name),
            .expect_some_bool => |expect| try self.findBindingInExpr(function_name, expect.actual, name),
            .expect_some_ptr => |expect| try self.findBindingInExpr(function_name, expect.actual, name),
            else => null,
        };
    }

    fn findBindingInBuiltin(self: *Emitter, function_name: []const u8, builtin: ast.BuiltinCall, name: []const u8) anyerror!?Binding {
        return switch (builtin) {
            .put_at => |put| try self.findBindingInExpr(function_name, put.ch, name),
            .hex_at => |hex| try self.findBindingInExpr(function_name, hex.value, name),
            .hex16_at => |hex| try self.findBindingInExpr(function_name, hex.value, name),
            .console_print => |print| blk: {
                for (print.args) |arg| switch (arg) {
                    .value => |expr| if (try self.findBindingInExpr(function_name, expr, name)) |binding| break :blk binding,
                    .string => {},
                };
                break :blk null;
            },
            .sleep_ticks => |sleep| try self.findBindingInExpr(function_name, sleep.ticks, name),
            .sleep_frames => |sleep| try self.findBindingInExpr(function_name, sleep.ticks, name),
            else => null,
        };
    }

    fn findBindingInReuStmt(self: *Emitter, function_name: []const u8, call: ast.ReuStmt, name: []const u8) anyerror!?Binding {
        return switch (call) {
            .copy_c64_to_reu, .copy_reu_to_c64, .swap => |transfer| try self.findBindingInReuTransfer(function_name, transfer, name),
            .fill => |fill| blk: {
                if (try self.findBindingInExpr(function_name, fill.value.*, name)) |binding| break :blk binding;
                if (try self.findBindingInExpr(function_name, fill.len.*, name)) |binding| break :blk binding;
                break :blk null;
            },
            .copy_from_c64, .copy_to_c64 => |copy| blk: {
                if (try self.findBindingInExpr(function_name, copy.far.*, name)) |binding| break :blk binding;
                if (try self.findBindingInExpr(function_name, copy.c64_addr.*, name)) |binding| break :blk binding;
                if (try self.findBindingInExpr(function_name, copy.len.*, name)) |binding| break :blk binding;
                break :blk null;
            },
        };
    }

    fn findBindingInReuTransfer(self: *Emitter, function_name: []const u8, transfer: ast.ReuTransfer, name: []const u8) anyerror!?Binding {
        if (try self.findBindingInExpr(function_name, transfer.c64_addr.*, name)) |binding| return binding;
        return try self.findBindingInExpr(function_name, transfer.len.*, name);
    }

    pub fn localDeclType(self: *Emitter, function_name: []const u8, decl: ast.VarDecl) anyerror!ast.Type {
        if (decl.ty) |ty| return ty;
        return try self.exprType(function_name, decl.init);
    }

    fn isWordType(ty: ast.Type) bool {
        return switch (ty) {
            .u16, .i16, .usize => true,
            else => false,
        };
    }

    fn isPointerType(ty: ast.Type) bool {
        return switch (ty) {
            .pointer => true,
            else => false,
        };
    }

    fn isOptionalType(ty: ast.Type) bool {
        return switch (ty) {
            .optional => true,
            else => false,
        };
    }

    fn isOptionalPointerType(ty: ast.Type) bool {
        return switch (ty) {
            .optional => |optional| optional.child == .pointer,
            else => false,
        };
    }

    fn isWideValueType(ty: ast.Type) bool {
        return isWordType(ty) or isPointerType(ty) or isOptionalPointerType(ty);
    }

    fn isArrayType(ty: ast.Type) bool {
        return switch (ty) {
            .array => true,
            else => false,
        };
    }

    fn isSignedType(ty: ast.Type) bool {
        return switch (ty) {
            .i8, .i16 => true,
            else => false,
        };
    }

    fn isBoolType(ty: ast.Type) bool {
        return switch (ty) {
            .bool => true,
            else => false,
        };
    }

    pub fn isEnumType(self: *Emitter, ty: ast.Type) bool {
        return switch (ty) {
            .custom => |name| self.program.findEnum(name) != null,
            else => false,
        };
    }

    pub fn isStructType(self: *Emitter, ty: ast.Type) bool {
        return switch (ty) {
            .custom => |name| self.program.findStruct(name) != null,
            else => false,
        };
    }

    pub fn isUnionType(self: *Emitter, ty: ast.Type) bool {
        return switch (ty) {
            .custom => |name| self.program.findUnion(name) != null,
            else => false,
        };
    }

    fn pointerChildToType(child: ast.PointerChildType) ast.Type {
        return switch (child) {
            .scalar => |scalar| scalarTypeToType(scalar),
            .custom => |name| .{ .custom = name },
        };
    }

    fn optionalChildToType(child: ast.OptionalChildType) ast.Type {
        return switch (child) {
            .scalar => |scalar| scalarTypeToType(scalar),
            .custom => |name| .{ .custom = name },
            .pointer => |ptr| .{ .pointer = ptr },
            .far_bytes => .far_bytes,
            .near_view => |view| .{ .near_view = view },
        };
    }

    fn pointerChildTypesEqual(a: ast.PointerChildType, b: ast.PointerChildType) bool {
        return switch (a) {
            .scalar => |a_scalar| switch (b) {
                .scalar => |b_scalar| a_scalar == b_scalar,
                else => false,
            },
            .custom => |a_name| switch (b) {
                .custom => |b_name| std.mem.eql(u8, a_name, b_name),
                else => false,
            },
        };
    }

    fn optionalChildTypesEqual(a: ast.OptionalChildType, b: ast.OptionalChildType) bool {
        return switch (a) {
            .scalar => |a_scalar| switch (b) {
                .scalar => |b_scalar| a_scalar == b_scalar,
                else => false,
            },
            .custom => |a_name| switch (b) {
                .custom => |b_name| std.mem.eql(u8, a_name, b_name),
                else => false,
            },
            .pointer => |a_ptr| switch (b) {
                .pointer => |b_ptr| a_ptr.is_volatile == b_ptr.is_volatile and a_ptr.is_many == b_ptr.is_many and pointerChildTypesEqual(a_ptr.child, b_ptr.child),
                else => false,
            },
            .far_bytes => b == .far_bytes,
            .near_view => |a_view| switch (b) {
                .near_view => |b_view| a_view.count == b_view.count and std.mem.eql(u8, a_view.type_name, b_view.type_name),
                else => false,
            },
        };
    }

    fn optionalPayloadType(optional: ast.OptionalType) ast.Type {
        return optionalChildToType(optional.child);
    }

    pub fn validatePointerChildType(self: *Emitter, child: ast.PointerChildType) !ast.Type {
        const ty = pointerChildToType(child);
        if (self.isStructType(ty) or isArrayType(ty)) return error.UnsupportedPointerType;
        if (ty == .custom and !self.isEnumType(ty)) return error.UnsupportedPointerType;
        return ty;
    }

    pub fn validatePointerType(self: *Emitter, ptr: ast.PointerType) !ast.Type {
        const ty = pointerChildToType(ptr.child);
        if (self.isStructType(ty)) {
            if (ptr.is_many or ptr.is_volatile) return error.UnsupportedPointerType;
            return ty;
        }
        if (isArrayType(ty)) return error.UnsupportedPointerType;
        if (ty == .custom and !self.isEnumType(ty)) return error.UnsupportedPointerType;
        return ty;
    }

    pub fn validateOptionalType(self: *Emitter, optional: ast.OptionalType) !ast.Type {
        const child_ty = optionalPayloadType(optional);
        if (child_ty == .pointer) {
            _ = try self.validatePointerType(child_ty.pointer);
            return child_ty;
        }
        if (child_ty == .far_bytes or child_ty == .near_view) return child_ty;
        if (self.isStructType(child_ty) or isArrayType(child_ty)) return error.UnsupportedStruct;
        if (child_ty == .custom and !self.isEnumType(child_ty)) return error.UnsupportedEnumLiteral;
        return child_ty;
    }

    fn validateReuView(self: *Emitter, function_name: []const u8, view: ast.ReuView) !ast.Type {
        const far_ty = try self.exprType(function_name, view.far.*);
        if (far_ty != .far_bytes) return error.UnsupportedPointerType;
        _ = try self.validateFarViewStruct(view.type_name, view.count);
        return .{ .far_view = .{ .type_name = view.type_name, .count = view.count } };
    }

    fn validateFarViewMaterialize(self: *Emitter, function_name: []const u8, mat: ast.FarViewMaterialize) !ast.FarViewType {
        const binding = try self.expectBinding(function_name, mat.view_name);
        if (binding.ty != .far_view) return error.UnsupportedPointerType;
        const heap = self.program.findHeap(mat.heap_name) orelse return error.UnknownHeap;
        if (heap.kind != .arena) return error.UnsupportedHeapFunction;
        _ = try self.validateFarViewStruct(binding.ty.far_view.type_name, binding.ty.far_view.count);
        return binding.ty.far_view;
    }

    fn validateFarViewMaterializeRange(self: *Emitter, function_name: []const u8, range: ast.FarViewMaterializeRange) !ast.FarViewType {
        const binding = try self.expectBinding(function_name, range.view_name);
        if (binding.ty != .far_view) return error.UnsupportedPointerType;
        const heap = self.program.findHeap(range.heap_name) orelse return error.UnknownHeap;
        if (heap.kind != .arena) return error.UnsupportedHeapFunction;
        if (range.count == 0 or range.count > binding.ty.far_view.count) return error.UnsupportedArrayIndex;
        try self.validatePointerIndexExpr(function_name, range.start.*);
        if (exprIntLiteral(range.start.*)) |literal| {
            if (literal > binding.ty.far_view.count - range.count) return error.UnsupportedArrayIndex;
        }
        _ = try self.validateFarViewStruct(binding.ty.far_view.type_name, binding.ty.far_view.count);
        return .{ .type_name = binding.ty.far_view.type_name, .count = range.count };
    }

    fn validateFarViewStruct(self: *Emitter, type_name: []const u8, count: u16) !u16 {
        if (count == 0 or count > 255) return error.UnsupportedArraySize;
        const size = try self.validateFarViewStructFields(type_name);
        if (size == 0 or size > 255) return error.UnsupportedStruct;
        const total = @as(u32, size) * @as(u32, count);
        if (total > 0xffff) return error.Overflow;
        return size;
    }

    fn validateFarViewStructFields(self: *Emitter, type_name: []const u8) anyerror!u16 {
        const decl = self.program.findStruct(type_name) orelse return error.UnsupportedStruct;
        var total: u16 = 0;
        for (decl.fields) |field| {
            total += try self.validateFarViewFieldType(field.ty);
        }
        return total;
    }

    fn validateFarViewFieldType(self: *Emitter, ty: ast.Type) anyerror!u16 {
        return switch (ty) {
            .bool, .u8, .i8 => 1,
            .u16, .i16, .usize => 2,
            .custom => |custom| if (self.program.findEnum(custom) != null)
                1
            else if (self.program.findStruct(custom) != null)
                try self.validateFarViewStructFields(custom)
            else
                error.UnsupportedStruct,
            .array => |array_ty| blk: {
                const elem_size: u16 = switch (array_ty.elem) {
                    .scalar => |scalar| switch (scalar) {
                        .u16, .i16, .usize => 2,
                        else => 1,
                    },
                    .custom => |custom| if (self.program.findEnum(custom) != null) 1 else return error.UnsupportedArrayType,
                };
                break :blk std.math.cast(u16, @as(u32, elem_size) * @as(u32, array_ty.len)) orelse error.Overflow;
            },
            else => error.UnsupportedStruct,
        };
    }

    fn validateAsTargetType(self: *Emitter, ty: ast.Type) !void {
        switch (ty) {
            .bool, .u8, .i8, .u16, .i16, .usize => {},
            .custom => {
                if (!self.isEnumType(ty)) return error.UnsupportedCast;
            },
            .pointer => |ptr| {
                _ = try self.validatePointerType(ptr);
            },
            else => return error.UnsupportedCast,
        }
    }

    fn intLiteralFitsType(ty: ast.Type, literal: u16) bool {
        return switch (ty) {
            .u8, .i8 => literal <= 255,
            .u16, .i16, .usize => true,
            else => false,
        };
    }

    fn isUnsignedIntegerType(ty: ast.Type) bool {
        return switch (ty) {
            .u8, .u16, .usize => true,
            else => false,
        };
    }

    fn validateAsCast(self: *Emitter, function_name: []const u8, cast: ast.AsCast) !ast.Type {
        try self.validateAsTargetType(cast.ty);
        if (cast.ty == .pointer) {
            switch (cast.expr.*) {
                .ptr_from_int, .address_of => {
                    _ = try self.exprTypeAllowContext(function_name, cast.expr.*, cast.ty);
                },
                else => {
                    const actual_ty = try self.exprType(function_name, cast.expr.*);
                    if (!typesEqual(actual_ty, cast.ty)) return error.UnsupportedPointerCast;
                },
            }
            return cast.ty;
        }
        if (self.isEnumType(cast.ty)) {
            const actual_ty = try self.exprTypeAllowContext(function_name, cast.expr.*, cast.ty);
            if (!typesEqual(actual_ty, cast.ty)) return error.UnsupportedEnumLiteral;
            return cast.ty;
        }
        if (isBoolType(cast.ty)) {
            if (!isBoolType(try self.exprType(function_name, cast.expr.*))) return error.UnsupportedCast;
            return cast.ty;
        }
        if (exprIntLiteral(cast.expr.*)) |literal| {
            if (!intLiteralFitsType(cast.ty, literal)) return error.Overflow;
            return cast.ty;
        }
        const actual_ty = try self.exprType(function_name, cast.expr.*);
        if (!isNumericScalarType(cast.ty) or !isNumericScalarType(actual_ty)) return error.UnsupportedCast;
        if (typesEqual(cast.ty, actual_ty)) return cast.ty;
        if (isSignedType(cast.ty) or isSignedType(actual_ty)) return error.UnsupportedCast;
        if (isUnsignedIntegerType(cast.ty) and isUnsignedIntegerType(actual_ty)) {
            if (cast.ty == .u8 and actual_ty != .u8) return error.Overflow;
            if (cast.ty == .u16 and actual_ty == .usize) return error.Overflow;
            return cast.ty;
        }
        return error.UnsupportedCast;
    }

    fn canUseTypedValueAs(self: *Emitter, value_ty: ast.Type, expected_ty: ast.Type) bool {
        if (typesEqual(value_ty, expected_ty)) return true;
        if (self.isEnumType(value_ty) or self.isEnumType(expected_ty)) return false;
        if (isBoolType(value_ty) or isBoolType(expected_ty)) return false;
        if (isSignedType(value_ty) or isSignedType(expected_ty)) return false;
        if (!isNumericScalarType(value_ty) or !isNumericScalarType(expected_ty)) return false;
        if (expected_ty == .u8 and value_ty != .u8) return false;
        if (expected_ty == .u16 and value_ty == .usize) return false;
        return true;
    }

    fn maybeManyPointerIndexChildType(self: *Emitter, function_name: []const u8, name: []const u8, index: ast.Expr) !?ast.Type {
        if (try self.findBinding(function_name, name)) |binding| {
            if (binding.ty == .far_view or binding.ty == .near_view) return error.UnsupportedPointerType;
            if (binding.ty == .pointer) {
                if (!binding.ty.pointer.is_many) return error.UnsupportedPointerTarget;
                const child_ty = try self.validatePointerChildType(binding.ty.pointer.child);
                try self.validatePointerIndexExpr(function_name, index);
                return child_ty;
            }
        }
        return null;
    }

    fn expectManyPointerIndex(self: *Emitter, function_name: []const u8, name: []const u8, index: ast.Expr) !struct { ptr_ty: ast.Type, child_ty: ast.Type } {
        const binding = try self.expectBinding(function_name, name);
        if (binding.ty != .pointer or !binding.ty.pointer.is_many) return error.UnsupportedPointerTarget;
        const child_ty = try self.validatePointerChildType(binding.ty.pointer.child);
        try self.validatePointerIndexExpr(function_name, index);
        return .{ .ptr_ty = binding.ty, .child_ty = child_ty };
    }

    fn validatePointerIndexExpr(self: *Emitter, function_name: []const u8, index: ast.Expr) !void {
        const index_ty = try self.exprType(function_name, index);
        if (!isNumericScalarType(index_ty) or isBoolType(index_ty) or isSignedType(index_ty)) return error.UnsupportedArrayIndex;
    }

    pub fn enumTagValue(self: *Emitter, enum_name: []const u8, tag_name: []const u8) !u8 {
        const decl = self.program.findEnum(enum_name) orelse return error.UnsupportedEnumLiteral;
        for (decl.tags) |tag| {
            if (std.mem.eql(u8, tag.name, tag_name)) return tag.value;
        }
        return error.UnsupportedEnumLiteral;
    }

    pub fn enumLiteralValue(self: *Emitter, expected_ty: ast.Type, literal: ast.EnumLiteral) !u8 {
        const enum_name = switch (expected_ty) {
            .custom => |name| name,
            else => return error.UnsupportedEnumLiteral,
        };
        if (literal.enum_name) |actual_name| {
            if (!std.mem.eql(u8, actual_name, enum_name)) return error.UnsupportedEnumLiteral;
        }
        return try self.enumTagValue(enum_name, literal.tag);
    }

    pub fn isInlineAsmByteType(ty: ast.Type) bool {
        return switch (ty) {
            .u8, .i8, .bool => true,
            else => false,
        };
    }

    pub fn forItemType(self: *Emitter, function_name: []const u8, for_stmt: ast.ForStmt) !ast.Type {
        return switch (for_stmt.source) {
            .array => |name| blk: {
                const array_ref = try self.resolveArray(function_name, name);
                defer array_ref.deinit(self.allocator);
                break :blk arrayElemToType(array_ref.ty.elem);
            },
            .array_indexed => |name| blk: {
                const array_ref = try self.resolveArray(function_name, name);
                defer array_ref.deinit(self.allocator);
                break :blk arrayElemToType(array_ref.ty.elem);
            },
            .range => .usize,
        };
    }

    fn emitStructVar(self: *Emitter, function_name: []const u8, struct_var: ast.StructVar) !void {
        try self.emitStructLiteralFields(function_name, struct_var.name, struct_var.type_name, struct_var.fields);
    }

    fn emitStructLiteralFields(self: *Emitter, function_name: []const u8, prefix: []const u8, type_name: []const u8, fields: []const ast.StructFieldInit) anyerror!void {
        try self.emitStructLiteralFieldsFrom(function_name, function_name, prefix, type_name, fields);
    }

    // Preserve the existing untyped pointer-construction boundary in field/
    // block VALUE contexts; nested calls keep their own typed argument rules.
    fn validatePointerValueOnlyContext(expr: ast.Expr) anyerror!void {
        switch (expr) {
            .ptr_from_int, .address_of => return error.UnsupportedPointerCast,
            .heap_alloc => return error.UnsupportedOptional,
            .as_cast => |cast| try validatePointerValueOnlyContext(cast.expr.*),
            .if_expr => |branch| {
                try validatePointerValueOnlyContext(branch.then_expr.*);
                try validatePointerValueOnlyContext(branch.else_expr.*);
            },
            .switch_expr => |selection| for (selection.prongs) |prong| try validatePointerValueOnlyContext(prong.value),
            .block_expr => |block| try validatePointerValueOnlyBreaks(block.body, block.label),
            else => {}, // Call arguments/ordinary statements keep their own typed contexts.
        }
    }

    fn validatePointerValueOnlyBreaks(body: []const ast.Stmt, label: []const u8) anyerror!void {
        for (body) |stmt| switch (stmt) {
            .break_expr => |result| if (std.mem.eql(u8, result.label, label)) {
                try validatePointerValueOnlyContext(result.value);
            },
            .if_stmt => |branch| {
                try validatePointerValueOnlyBreaks(branch.then_body, label);
                try validatePointerValueOnlyBreaks(branch.else_body, label);
            },
            .while_stmt => |loop| try validatePointerValueOnlyBreaks(loop.body, label),
            .for_stmt => |loop| try validatePointerValueOnlyBreaks(loop.body, label),
            .switch_stmt => |selection| for (selection.prongs) |prong| try validatePointerValueOnlyBreaks(prong.body, label),
            else => {},
        };
    }

    fn emitTypedFieldValueToAX(self: *Emitter, function_name: []const u8, expr: ast.Expr, ty: ast.Type) !void {
        if (isPointerType(ty) or isOptionalPointerType(ty)) {
            try validatePointerValueOnlyContext(expr);
            const actual = try self.exprTypeAllowContext(function_name, expr, ty);
            if (!typesEqual(actual, ty)) return error.UnsupportedPointerType;
        }
        try self.emitExprToAXExpected(function_name, expr, ty);
    }

    fn emitStructLiteralFieldsFrom(self: *Emitter, dest_function: []const u8, eval_function: []const u8, prefix: []const u8, type_name: []const u8, fields: []const ast.StructFieldInit) anyerror!void {
        const decl = self.program.findStruct(type_name) orelse return error.UnsupportedStruct;
        for (decl.fields) |field_decl| {
            const init = findStructFieldInit(fields, field_decl.name) orelse return error.UnsupportedStruct;
            const field_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, field_decl.name });
            defer self.allocator.free(field_name);
            switch (field_decl.ty) {
                .array => |array_ty| {
                    const literal = switch (init.value) {
                        .array_literal => |literal| literal,
                        else => return error.UnsupportedArrayLiteral,
                    };
                    try self.validateArrayLiteral(eval_function, array_ty, literal);
                    for (literal.values, 0..) |value, index| {
                        const label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ dest_function, field_name });
                        defer self.allocator.free(label);
                        const array_ref = ArrayRef{ .ty = array_ty, .mutable = true, .label = label };
                        try self.validateArrayElementValue(eval_function, array_ty, value);
                        try self.emitStoreArrayElement(eval_function, array_ref, .{ .value = .{ .int = @as(u16, @intCast(index)) } }, value);
                    }
                },
                .custom => |custom| {
                    if (self.program.findStruct(custom) != null) {
                        try self.emitStructExprToFunctionStorage(dest_function, field_name, eval_function, custom, init.value);
                    } else if (self.program.findEnum(custom) != null) {
                        try self.emitExprToAExpected(eval_function, init.value, field_decl.ty);
                        try self.out.writer.print("    sta {s}_{s}\n", .{ dest_function, field_name });
                    } else {
                        return error.UnsupportedStruct;
                    }
                },
                .optional => |optional| {
                    if (optional.child == .pointer) {
                        try self.emitTypedFieldValueToAX(eval_function, init.value, field_decl.ty);
                        try self.out.writer.print("    sta {s}_{s}\n    stx {s}_{s}+1\n", .{ dest_function, field_name, dest_function, field_name });
                    } else {
                        try self.emitExprToAExpected(eval_function, init.value, field_decl.ty);
                        try self.out.writer.print("    sta {s}_{s}\n", .{ dest_function, field_name });
                    }
                },
                .pointer => {
                    try self.emitTypedFieldValueToAX(eval_function, init.value, field_decl.ty);
                    try self.out.writer.print("    sta {s}_{s}\n    stx {s}_{s}+1\n", .{ dest_function, field_name, dest_function, field_name });
                },
                .u16, .i16, .usize => {
                    try self.emitExprToAX(eval_function, init.value);
                    try self.out.writer.print("    sta {s}_{s}\n    stx {s}_{s}+1\n", .{ dest_function, field_name, dest_function, field_name });
                },
                else => {
                    try self.emitExprToAExpected(eval_function, init.value, field_decl.ty);
                    try self.out.writer.print("    sta {s}_{s}\n", .{ dest_function, field_name });
                },
            }
        }
        for (fields) |init| {
            if (findStructFieldDecl(decl, init.name) == null) return error.UnsupportedStruct;
        }
    }

    fn emitStructExprToStorage(self: *Emitter, function_name: []const u8, dest_prefix: []const u8, type_name: []const u8, expr: ast.Expr) anyerror!void {
        try self.emitStructExprToFunctionStorage(function_name, dest_prefix, function_name, type_name, expr);
    }

    fn unionFieldIndex(self: *Emitter, type_name: []const u8, field_name: []const u8) !u8 {
        const decl = self.program.findUnion(type_name) orelse return error.UnsupportedStruct;
        for (decl.fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name, field_name)) return @as(u8, @intCast(index));
        }
        return error.UnsupportedEnumLiteral;
    }

    fn unionFieldDecl(self: *Emitter, type_name: []const u8, field_name: []const u8) !ast.UnionFieldDecl {
        const decl = self.program.findUnion(type_name) orelse return error.UnsupportedStruct;
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, field_name)) return field;
        }
        return error.UnsupportedEnumLiteral;
    }

    fn unionPayloadType(self: *Emitter, type_name: []const u8, field_name: []const u8) !?ast.Type {
        return (try self.unionFieldDecl(type_name, field_name)).ty;
    }

    pub fn unionPayloadBytes(self: *Emitter, maybe_ty: ?ast.Type) !u16 {
        const ty = maybe_ty orelse return 0;
        try self.validateUnionPayloadType(ty);
        return if (isWordType(ty) or isPointerType(ty)) 2 else 1;
    }

    pub fn unionStorageBytes(self: *Emitter, type_name: []const u8) !u16 {
        const decl = self.program.findUnion(type_name) orelse return error.UnsupportedStruct;
        var max_payload: u16 = 0;
        for (decl.fields) |field| {
            max_payload = @max(max_payload, try self.unionPayloadBytes(field.ty));
        }
        return 1 + max_payload;
    }

    fn validateUnionPayloadType(self: *Emitter, ty: ast.Type) !void {
        switch (ty) {
            .bool, .u8, .i8, .u16, .i16, .usize, .pointer => {},
            .custom => {
                if (!self.isEnumType(ty)) return error.UnsupportedStruct;
            },
            else => return error.UnsupportedStruct,
        }
    }

    fn validateUnionLiteral(self: *Emitter, function_name: []const u8, type_name: []const u8, literal: ast.StructLiteral) !void {
        if (literal.type_name.len != 0 and !std.mem.eql(u8, literal.type_name, type_name)) return error.UnsupportedStruct;
        if (literal.fields.len != 1) return error.UnsupportedStruct;
        const field = literal.fields[0];
        const payload_ty = try self.unionPayloadType(type_name, field.name);
        if (payload_ty) |ty| {
            try self.validateUnionPayloadType(ty);
            _ = try self.exprTypeAllowContext(function_name, field.value, ty);
        }
    }

    fn emitUnionExprToStorage(self: *Emitter, function_name: []const u8, dest_name: []const u8, type_name: []const u8, expr: ast.Expr) anyerror!void {
        try self.emitUnionExprToFunctionStorage(function_name, dest_name, function_name, type_name, expr);
    }

    fn emitUnionExprToFunctionStorage(self: *Emitter, dest_function: []const u8, dest_name: []const u8, source_function: []const u8, type_name: []const u8, expr: ast.Expr) anyerror!void {
        switch (expr) {
            .struct_literal => |literal| try self.emitUnionLiteralToStorage(source_function, dest_function, dest_name, type_name, literal),
            .value => |value| switch (value) {
                .ident => |ident| {
                    const binding = try self.expectBinding(source_function, ident);
                    if (!typesEqual(binding.ty, .{ .custom = type_name })) return error.UnsupportedStruct;
                    try self.emitCopyUnionStorage(dest_function, dest_name, source_function, ident, type_name);
                },
                else => return error.UnsupportedStruct,
            },
            .call => |call| {
                const callee = try self.functionForCall(call);
                if (!typesEqual(callee.return_type, .{ .custom = type_name })) return error.UnsupportedStruct;
                try self.emitCall(source_function, call);
                try self.emitCopyUnionStorage(dest_function, dest_name, callee.name, "return", type_name);
            },
            else => return error.UnsupportedStruct,
        }
    }

    fn emitUnionLiteralToStorage(self: *Emitter, eval_function: []const u8, dest_function: []const u8, dest_name: []const u8, type_name: []const u8, literal: ast.StructLiteral) !void {
        if (literal.type_name.len != 0 and !std.mem.eql(u8, literal.type_name, type_name)) return error.UnsupportedStruct;
        if (literal.fields.len != 1) return error.UnsupportedStruct;
        const field = literal.fields[0];
        const tag = try self.unionFieldIndex(type_name, field.name);
        const payload_ty = try self.unionPayloadType(type_name, field.name);
        const label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ dest_function, dest_name });
        defer self.allocator.free(label);
        try self.out.writer.print("    lda #{d}\n    sta {s}\n", .{ tag, label });
        if (payload_ty) |ty| {
            try self.validateUnionPayloadType(ty);
            if (isWordType(ty) or isPointerType(ty)) {
                try self.emitExprToAXExpected(eval_function, field.value, ty);
                try self.out.writer.print("    sta {s}+1\n    stx {s}+2\n", .{ label, label });
            } else {
                try self.emitExprToAExpected(eval_function, field.value, ty);
                try self.out.writer.print("    sta {s}+1\n", .{label});
            }
        }
    }

    fn emitCopyUnionStorage(self: *Emitter, dest_function: []const u8, dest_name: []const u8, source_function: []const u8, source_name: []const u8, type_name: []const u8) !void {
        const byte_count = try self.unionStorageBytes(type_name);
        const source_label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ source_function, source_name });
        defer self.allocator.free(source_label);
        const dest_label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ dest_function, dest_name });
        defer self.allocator.free(dest_label);
        try storage.emitCopyRangeInline(self, dest_label, source_label, byte_count);
    }

    fn emitUnionExprToSwitchStorage(self: *Emitter, function_name: []const u8, expr: ast.Expr, type_name: []const u8) !void {
        switch (expr) {
            .value => |value| switch (value) {
                .ident => |ident| {
                    const binding = try self.expectBinding(function_name, ident);
                    if (!typesEqual(binding.ty, .{ .custom = type_name })) return error.UnsupportedStruct;
                    try self.out.writer.print(
                        "    lda {s}_{s}\n    sta zeropage_switch_value\n    lda #0\n    sta zeropage_switch_value+1\n    lda {s}_{s}+1\n    sta zeropage_union_switch_payload\n    lda {s}_{s}+2\n    sta zeropage_union_switch_payload+1\n",
                        .{ function_name, ident, function_name, ident, function_name, ident },
                    );
                },
                else => return error.UnsupportedStruct,
            },
            .call => |call| {
                const callee = try self.functionForCall(call);
                if (!typesEqual(callee.return_type, .{ .custom = type_name })) return error.UnsupportedStruct;
                try self.emitCall(function_name, call);
                try self.out.writer.print(
                    "    lda {s}_return\n    sta zeropage_switch_value\n    lda #0\n    sta zeropage_switch_value+1\n    lda {s}_return+1\n    sta zeropage_union_switch_payload\n    lda {s}_return+2\n    sta zeropage_union_switch_payload+1\n",
                    .{ callee.name, callee.name, callee.name },
                );
            },
            else => return error.UnsupportedStruct,
        }
    }

    fn emitStructExprToFunctionStorage(self: *Emitter, dest_function: []const u8, dest_prefix: []const u8, source_function: []const u8, type_name: []const u8, expr: ast.Expr) anyerror!void {
        switch (expr) {
            .struct_literal => |literal| {
                if (!std.mem.eql(u8, literal.type_name, type_name)) return error.UnsupportedStruct;
                try self.emitStructLiteralFieldsFrom(dest_function, source_function, dest_prefix, type_name, literal.fields);
            },
            .value => |value| switch (value) {
                .ident => |ident| {
                    const binding = try self.expectBinding(source_function, ident);
                    if (!typesEqual(binding.ty, .{ .custom = type_name })) return error.UnsupportedStruct;
                    try self.emitCopyStructStorage(dest_function, dest_prefix, source_function, ident, type_name);
                },
                .field => |field| {
                    const source_prefix = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ field.base, field.field });
                    defer self.allocator.free(source_prefix);
                    const source_ty = try self.valueType(source_function, value);
                    if (!typesEqual(source_ty, .{ .custom = type_name })) return error.UnsupportedStruct;
                    try self.emitCopyStructStorage(dest_function, dest_prefix, source_function, source_prefix, type_name);
                },
                else => return error.UnsupportedStruct,
            },
            .call => |call| {
                if (try self.reuViewCall(source_function, call, "get")) |view_call| {
                    if (!std.mem.eql(u8, view_call.view.type_name, type_name)) return error.UnsupportedStruct;
                    try self.emitReuViewGetToStorage(dest_function, dest_prefix, source_function, view_call, call);
                    return;
                }
                if (try self.nearViewCall(source_function, call, "get")) |view_call| {
                    if (!std.mem.eql(u8, view_call.view.type_name, type_name)) return error.UnsupportedStruct;
                    try self.emitNearViewGetToStorage(dest_function, dest_prefix, source_function, view_call, call);
                    return;
                }
                const callee = try self.functionForCall(call);
                if (!typesEqual(callee.return_type, .{ .custom = type_name })) return error.UnsupportedStruct;
                try self.emitCall(source_function, call);
                try self.emitCopyStructStorage(dest_function, dest_prefix, callee.name, "return", type_name);
            },
            else => return error.UnsupportedStruct,
        }
    }

    pub fn emitCopyStructStorage(self: *Emitter, dest_function: []const u8, dest_prefix: []const u8, source_function: []const u8, source_prefix: []const u8, type_name: []const u8) !void {
        try storage.emitCopyStructStorage(self, dest_function, dest_prefix, source_function, source_prefix, type_name);
    }

    fn emitReuViewGetToStorage(self: *Emitter, dest_function: []const u8, dest_prefix: []const u8, source_function: []const u8, view_call: ReuViewCall, call: ast.CallExpr) !void {
        if (call.args.len != 1) return error.ArgumentCountMismatch;
        const record_size = try self.validateFarViewStruct(view_call.view.type_name, view_call.view.count);
        try self.validateReuViewIndexLiteral(view_call.view, call.args[0]);
        try self.emitReuViewAddressSetup(source_function, view_call.name, view_call.view, call.args[0], record_size);
        self.uses_reu_copy_reu_to_c64 = true;
        try self.emitReuViewRecordTransfer(record_size, false);
        const dest_label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ dest_function, dest_prefix });
        defer self.allocator.free(dest_label);
        try storage.emitCopyRangeInline(self, dest_label, "zeropage_reu_view_record", record_size);
    }

    fn emitReuViewSet(self: *Emitter, function_name: []const u8, view_call: ReuViewCall, call: ast.CallExpr) !void {
        if (call.args.len != 2) return error.ArgumentCountMismatch;
        const record_size = try self.validateFarViewStruct(view_call.view.type_name, view_call.view.count);
        try self.validateReuViewIndexLiteral(view_call.view, call.args[0]);
        _ = try self.exprTypeAllowContext(function_name, call.args[1], .{ .custom = view_call.view.type_name });
        try self.emitStructExprToLabel(function_name, "zeropage_reu_view_record", view_call.view.type_name, call.args[1]);
        try self.emitReuViewAddressSetup(function_name, view_call.name, view_call.view, call.args[0], record_size);
        self.uses_reu_copy_c64_to_reu = true;
        try self.emitReuViewRecordTransfer(record_size, true);
    }

    fn emitStructExprToLabel(self: *Emitter, function_name: []const u8, label: []const u8, type_name: []const u8, expr: ast.Expr) !void {
        switch (expr) {
            .struct_literal => |literal| {
                if (!std.mem.eql(u8, literal.type_name, type_name)) return error.UnsupportedStruct;
                try self.emitStructLiteralToArrayElement(function_name, label, type_name, literal.fields, 0);
            },
            .value => |value| switch (value) {
                .ident => |ident| {
                    const binding = try self.expectBinding(function_name, ident);
                    if (!typesEqual(binding.ty, .{ .custom = type_name })) return error.UnsupportedStruct;
                    const source_label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ function_name, ident });
                    defer self.allocator.free(source_label);
                    try storage.emitCopyRangeInline(self, label, source_label, try self.structStorageBytesForOffset(type_name));
                },
                else => return error.UnsupportedStruct,
            },
            else => return error.UnsupportedStruct,
        }
    }

    fn validateReuViewIndexLiteral(self: *Emitter, view: ast.FarViewType, index: ast.Expr) !void {
        _ = self;
        if (exprIntLiteral(index)) |literal| {
            if (literal >= view.count) return error.UnsupportedArrayIndex;
        }
    }

    fn emitReuViewAddressSetup(self: *Emitter, function_name: []const u8, view_name: []const u8, view: ast.FarViewType, index: ast.Expr, record_size: u16) !void {
        self.uses_reu_view_runtime = true;
        const label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ function_name, view_name });
        defer self.allocator.free(label);
        if (exprIntLiteral(index)) |literal| {
            const offset = literal * record_size;
            try self.emitReuViewAddressFromOffsetLabel(label, offset);
            return;
        }
        if (record_size == 1) {
            try self.emitExprToAX(function_name, index);
        } else if (record_size == 2) {
            try self.emitExprToAX(function_name, index);
            try self.out.writer.writeAll("    asl\n    sta zeropage_reu_view_offset\n    txa\n    rol\n    tax\n    lda zeropage_reu_view_offset\n");
        } else {
            self.uses_multiply = true;
            try self.emitExprToAX(function_name, index);
            try self.out.writer.writeAll("    sta zeropage_mul_lhs\n    stx zeropage_mul_lhs+1\n");
            try self.out.writer.print("    lda #{d}\n    ldx #0\n", .{@as(u8, @truncate(record_size))});
            try self.out.writer.writeAll("    sta zeropage_mul_rhs\n    stx zeropage_mul_rhs+1\n    jsr zeropage_mul16\n");
        }
        try self.out.writer.writeAll("    sta zeropage_reu_view_offset\n    stx zeropage_reu_view_offset+1\n");
        _ = view;
        try self.out.writer.print(
            "    clc\n    lda {s}\n    adc zeropage_reu_view_offset\n    sta zeropage_reu_addr\n    lda {s}+1\n    adc zeropage_reu_view_offset+1\n    sta zeropage_reu_addr+1\n    lda {s}+2\n    adc #0\n    sta zeropage_reu_addr+2\n",
            .{ label, label, label },
        );
    }

    fn emitReuViewAddressFromIndexScratch(self: *Emitter, label: []const u8, record_size: u16) !void {
        self.uses_reu_view_runtime = true;
        if (record_size == 1) {
            try self.out.writer.writeAll("    lda zeropage_reu_view_offset\n    ldx zeropage_reu_view_offset+1\n");
        } else if (record_size == 2) {
            try self.out.writer.writeAll("    asl zeropage_reu_view_offset\n    rol zeropage_reu_view_offset+1\n    lda zeropage_reu_view_offset\n    ldx zeropage_reu_view_offset+1\n");
        } else {
            self.uses_multiply = true;
            try self.out.writer.writeAll("    lda zeropage_reu_view_offset\n    ldx zeropage_reu_view_offset+1\n    sta zeropage_mul_lhs\n    stx zeropage_mul_lhs+1\n");
            try self.out.writer.print("    lda #{d}\n    ldx #0\n", .{@as(u8, @truncate(record_size))});
            try self.out.writer.writeAll("    sta zeropage_mul_rhs\n    stx zeropage_mul_rhs+1\n    jsr zeropage_mul16\n");
        }
        try self.out.writer.writeAll("    sta zeropage_reu_view_offset\n    stx zeropage_reu_view_offset+1\n");
        try self.out.writer.print(
            "    clc\n    lda {s}\n    adc zeropage_reu_view_offset\n    sta zeropage_reu_addr\n    lda {s}+1\n    adc zeropage_reu_view_offset+1\n    sta zeropage_reu_addr+1\n    lda {s}+2\n    adc #0\n    sta zeropage_reu_addr+2\n",
            .{ label, label, label },
        );
    }

    fn emitReuViewAddressFromOffsetLabel(self: *Emitter, label: []const u8, offset: u32) !void {
        try self.out.writer.print(
            "    clc\n    lda {s}\n    adc #${x:0>2}\n    sta zeropage_reu_addr\n    lda {s}+1\n    adc #${x:0>2}\n    sta zeropage_reu_addr+1\n    lda {s}+2\n    adc #${x:0>2}\n    sta zeropage_reu_addr+2\n",
            .{ label, @as(u8, @truncate(offset)), label, @as(u8, @truncate(offset >> 8)), label, @as(u8, @truncate(offset >> 16)) },
        );
    }

    fn emitReuViewRecordTransfer(self: *Emitter, record_size: u16, to_reu: bool) !void {
        try self.out.writer.print(
            "    lda #<zeropage_reu_view_record\n    sta zeropage_reu_c64_addr\n    lda #>zeropage_reu_view_record\n    sta zeropage_reu_c64_addr+1\n    lda #{d}\n    sta zeropage_reu_len\n    lda #0\n    sta zeropage_reu_len+1\n",
            .{@as(u8, @truncate(record_size))},
        );
        try self.out.writer.writeAll(if (to_reu) "    jsr zeropage_reu_copy_c64_to_reu\n" else "    jsr zeropage_reu_copy_reu_to_c64\n");
    }

    fn emitFarViewMaterializeToOptional(self: *Emitter, function_name: []const u8, mat: ast.FarViewMaterialize, dest_label: []const u8) !void {
        const view = try self.validateFarViewMaterialize(function_name, mat);
        const record_size = try self.validateFarViewStruct(view.type_name, view.count);
        const total = @as(u32, record_size) * @as(u32, view.count);
        try self.heap_alloc_names.put(mat.heap_name, {});
        self.uses_reu_copy_reu_to_c64 = true;
        const id = self.nextLabel();

        try self.out.writer.print(
            "    lda #<{d}\n    ldx #>{d}\n    jsr zeropage_heap_{s}_alloc_bytes\n    sta {s}+1\n    stx {s}+2\n    ora {s}+2\n    beq far_materialize_{d}_null\n    lda #1\n    sta {s}\n",
            .{ total, total, mat.heap_name, dest_label, dest_label, dest_label, id, dest_label },
        );
        const view_label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ function_name, mat.view_name });
        defer self.allocator.free(view_label);
        try self.emitReuViewAddressFromOffsetLabel(view_label, 0);
        try self.out.writer.print(
            "    lda {s}+1\n    sta zeropage_reu_c64_addr\n    lda {s}+2\n    sta zeropage_reu_c64_addr+1\n    lda #<{d}\n    sta zeropage_reu_len\n    lda #>{d}\n    sta zeropage_reu_len+1\n    jsr zeropage_reu_copy_reu_to_c64\n    jmp far_materialize_{d}_done\nfar_materialize_{d}_null:\n    lda #0\n    sta {s}\nfar_materialize_{d}_done:\n",
            .{ dest_label, dest_label, total, total, id, id, dest_label, id },
        );
    }

    fn emitFarViewMaterializeRangeToOptional(self: *Emitter, function_name: []const u8, range: ast.FarViewMaterializeRange, dest_label: []const u8) !void {
        const local_view = try self.validateFarViewMaterializeRange(function_name, range);
        const source_binding = try self.expectBinding(function_name, range.view_name);
        const source_view = source_binding.ty.far_view;
        const record_size = try self.validateFarViewStruct(source_view.type_name, source_view.count);
        const total = @as(u32, record_size) * @as(u32, local_view.count);
        const max_start = source_view.count - local_view.count;
        try self.heap_alloc_names.put(range.heap_name, {});
        self.uses_reu_copy_reu_to_c64 = true;
        const id = self.nextLabel();

        if (exprIntLiteral(range.start.*)) |literal| {
            if (literal > max_start) return error.UnsupportedArrayIndex;
        } else {
            try self.emitExprToAX(function_name, range.start.*);
            try self.out.writer.print(
                "    sta zeropage_reu_view_offset\n    stx zeropage_reu_view_offset+1\n    cpx #0\n    bne far_materialize_range_{d}_null\n    lda zeropage_reu_view_offset\n    cmp #{d}\n    bcs far_materialize_range_{d}_null\n",
                .{ id, @as(u8, @truncate(max_start + 1)), id },
            );
        }

        try self.out.writer.print(
            "    lda #<{d}\n    ldx #>{d}\n    jsr zeropage_heap_{s}_alloc_bytes\n    sta {s}+1\n    stx {s}+2\n    ora {s}+2\n    beq far_materialize_range_{d}_null\n    lda #1\n    sta {s}\n",
            .{ total, total, range.heap_name, dest_label, dest_label, dest_label, id, dest_label },
        );
        const view_label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ function_name, range.view_name });
        defer self.allocator.free(view_label);
        if (exprIntLiteral(range.start.*)) |literal| {
            try self.emitReuViewAddressFromOffsetLabel(view_label, @as(u32, literal) * @as(u32, record_size));
        } else {
            try self.emitReuViewAddressFromIndexScratch(view_label, record_size);
        }
        try self.out.writer.print(
            "    lda {s}+1\n    sta zeropage_reu_c64_addr\n    lda {s}+2\n    sta zeropage_reu_c64_addr+1\n    lda #<{d}\n    sta zeropage_reu_len\n    lda #>{d}\n    sta zeropage_reu_len+1\n    jsr zeropage_reu_copy_reu_to_c64\n    jmp far_materialize_range_{d}_done\nfar_materialize_range_{d}_null:\n    lda #0\n    sta {s}\nfar_materialize_range_{d}_done:\n",
            .{ dest_label, dest_label, total, total, id, id, dest_label, id },
        );
    }

    fn emitNearViewPointerSetup(self: *Emitter, function_name: []const u8, view_name: []const u8, view: ast.FarViewType, index: ast.Expr, record_size: u16) !void {
        self.uses_pointer = true;
        const label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ function_name, view_name });
        defer self.allocator.free(label);
        try self.validateReuViewIndexLiteral(view, index);
        if (exprIntLiteral(index)) |literal| {
            try self.out.writer.print("    lda {s}\n    sta zeropage_ptr_tmp\n    lda {s}+1\n    sta zeropage_ptr_tmp+1\n", .{ label, label });
            try self.emitAddConstantToPtrTmp(literal * record_size);
            return;
        }
        self.uses_reu_view_runtime = true;
        if (record_size == 1) {
            try self.emitExprToAX(function_name, index);
        } else if (record_size == 2) {
            try self.emitExprToAX(function_name, index);
            try self.out.writer.writeAll("    asl\n    sta zeropage_reu_view_offset\n    txa\n    rol\n    tax\n    lda zeropage_reu_view_offset\n");
        } else {
            self.uses_multiply = true;
            try self.emitExprToAX(function_name, index);
            try self.out.writer.writeAll("    sta zeropage_mul_lhs\n    stx zeropage_mul_lhs+1\n");
            try self.out.writer.print("    lda #{d}\n    ldx #0\n", .{@as(u8, @truncate(record_size))});
            try self.out.writer.writeAll("    sta zeropage_mul_rhs\n    stx zeropage_mul_rhs+1\n    jsr zeropage_mul16\n");
        }
        try self.out.writer.print("    sta zeropage_reu_view_offset\n    stx zeropage_reu_view_offset+1\n    lda {s}\n    sta zeropage_ptr_tmp\n    lda {s}+1\n    sta zeropage_ptr_tmp+1\n", .{ label, label });
        try self.out.writer.writeAll("    clc\n    lda zeropage_ptr_tmp\n    adc zeropage_reu_view_offset\n    sta zeropage_ptr_tmp\n    lda zeropage_ptr_tmp+1\n    adc zeropage_reu_view_offset+1\n    sta zeropage_ptr_tmp+1\n");
    }

    fn emitNearViewGetToStorage(self: *Emitter, dest_function: []const u8, dest_prefix: []const u8, source_function: []const u8, view_call: ReuViewCall, call: ast.CallExpr) !void {
        if (call.args.len != 1) return error.ArgumentCountMismatch;
        const record_size = try self.validateFarViewStruct(view_call.view.type_name, view_call.view.count);
        try self.emitNearViewPointerSetup(source_function, view_call.name, view_call.view, call.args[0], record_size);
        const dest_label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ dest_function, dest_prefix });
        defer self.allocator.free(dest_label);
        for (0..record_size) |offset| {
            try self.out.writer.print("    ldy #{d}\n    lda (zeropage_ptr_tmp),y\n    sta {s}+{d}\n", .{ offset, dest_label, offset });
        }
    }

    fn emitNearViewSet(self: *Emitter, function_name: []const u8, view_call: ReuViewCall, call: ast.CallExpr) !void {
        if (call.args.len != 2) return error.ArgumentCountMismatch;
        const record_size = try self.validateFarViewStruct(view_call.view.type_name, view_call.view.count);
        _ = try self.exprTypeAllowContext(function_name, call.args[1], .{ .custom = view_call.view.type_name });
        self.uses_reu_view_runtime = true;
        try self.emitStructExprToLabel(function_name, "zeropage_reu_view_record", view_call.view.type_name, call.args[1]);
        try self.emitNearViewPointerSetup(function_name, view_call.name, view_call.view, call.args[0], record_size);
        for (0..record_size) |offset| {
            try self.out.writer.print("    ldy #{d}\n    lda zeropage_reu_view_record+{d}\n    sta (zeropage_ptr_tmp),y\n", .{ offset, offset });
        }
    }

    fn emitFarViewFlush(self: *Emitter, function_name: []const u8, view_call: ReuViewCall, call: ast.CallExpr) !void {
        if (call.args.len != 1) return error.ArgumentCountMismatch;
        const arg_ty = try self.exprType(function_name, call.args[0]);
        if (arg_ty != .near_view or !typesEqual(arg_ty, .{ .near_view = view_call.view })) return error.UnsupportedPointerType;
        const record_size = try self.validateFarViewStruct(view_call.view.type_name, view_call.view.count);
        const total = @as(u32, record_size) * @as(u32, view_call.view.count);
        const local_name = switch (call.args[0]) {
            .value => |value| switch (value) {
                .ident => |ident| ident,
                else => return error.UnsupportedPointerType,
            },
            else => return error.UnsupportedPointerType,
        };
        self.uses_reu_copy_c64_to_reu = true;
        const view_label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ function_name, view_call.name });
        defer self.allocator.free(view_label);
        try self.emitReuViewAddressFromOffsetLabel(view_label, 0);
        try self.out.writer.print(
            "    lda {s}_{s}\n    sta zeropage_reu_c64_addr\n    lda {s}_{s}+1\n    sta zeropage_reu_c64_addr+1\n    lda #<{d}\n    sta zeropage_reu_len\n    lda #>{d}\n    sta zeropage_reu_len+1\n    jsr zeropage_reu_copy_c64_to_reu\n",
            .{ function_name, local_name, function_name, local_name, total, total },
        );
    }

    fn emitFarViewFlushRange(self: *Emitter, function_name: []const u8, view_call: ReuViewCall, call: ast.CallExpr) !void {
        if (call.args.len != 2) return error.ArgumentCountMismatch;
        try self.validatePointerIndexExpr(function_name, call.args[0]);
        const arg_ty = try self.exprType(function_name, call.args[1]);
        if (arg_ty != .near_view) return error.UnsupportedPointerType;
        if (!std.mem.eql(u8, arg_ty.near_view.type_name, view_call.view.type_name)) return error.UnsupportedPointerType;
        if (arg_ty.near_view.count > view_call.view.count) return error.UnsupportedArrayIndex;
        if (exprIntLiteral(call.args[0])) |literal| {
            if (literal > view_call.view.count - arg_ty.near_view.count) return error.UnsupportedArrayIndex;
        }
        const record_size = try self.validateFarViewStruct(view_call.view.type_name, view_call.view.count);
        const total = @as(u32, record_size) * @as(u32, arg_ty.near_view.count);
        const local_name = switch (call.args[1]) {
            .value => |value| switch (value) {
                .ident => |ident| ident,
                else => return error.UnsupportedPointerType,
            },
            else => return error.UnsupportedPointerType,
        };
        self.uses_reu_copy_c64_to_reu = true;
        try self.emitReuViewAddressSetup(function_name, view_call.name, view_call.view, call.args[0], record_size);
        try self.out.writer.print(
            "    lda {s}_{s}\n    sta zeropage_reu_c64_addr\n    lda {s}_{s}+1\n    sta zeropage_reu_c64_addr+1\n    lda #<{d}\n    sta zeropage_reu_len\n    lda #>{d}\n    sta zeropage_reu_len+1\n    jsr zeropage_reu_copy_c64_to_reu\n",
            .{ function_name, local_name, function_name, local_name, total, total },
        );
    }

    pub fn emitCopyArrayStorage(self: *Emitter, dest_function: []const u8, dest_name: []const u8, source_function: []const u8, source_name: []const u8, byte_count: u16) !void {
        try storage.emitCopyArrayStorage(self, dest_function, dest_name, source_function, source_name, byte_count);
    }

    fn emitArrayVarDecl(self: *Emitter, function_name: []const u8, decl: ast.VarDecl, array_ty: ast.ArrayType) !void {
        const literal = switch (decl.init) {
            .array_literal => |literal| literal,
            else => return error.UnsupportedArrayLiteral,
        };
        try self.validateArrayLiteral(function_name, array_ty, literal);
        for (literal.values, 0..) |value, index| {
            try self.emitStoreArrayElementImmediate(function_name, decl.name, array_ty, @as(u16, @intCast(index)), value);
        }
    }

    fn emitArrayAssign(self: *Emitter, function_name: []const u8, assign: ast.ArrayAssign) !void {
        if (try self.maybeManyPointerIndexChildType(function_name, assign.name, assign.index)) |elem_ty| {
            try self.emitStorePointerIndexElement(function_name, assign, elem_ty);
            return;
        }
        if (try self.resolvePointerStructArrayPath(function_name, assign.name)) |path| {
            defer path.deinit(self.allocator);
            const elem_ty = arrayElemToType(path.ty.elem);
            try self.validateArrayElementValue(function_name, path.ty, assign.value);
            try self.validateArrayIndexLiteral(path.ty, assign.index);
            try self.emitStorePointerStructArrayElement(function_name, assign, elem_ty);
            return;
        }
        const array_ref = try self.resolveArray(function_name, assign.name);
        defer array_ref.deinit(self.allocator);
        if (!array_ref.mutable) return error.ImmutableLocalMutation;
        try self.validateArrayElementValue(function_name, array_ref.ty, assign.value);
        try self.validateArrayIndexLiteral(array_ref.ty, assign.index);
        try self.emitStoreArrayElement(function_name, array_ref, assign.index, assign.value);
    }

    fn emitArrayFieldAssign(self: *Emitter, function_name: []const u8, assign: ast.ArrayFieldAssign) !void {
        const field_ref = try self.resolveArrayFieldRef(function_name, assign.name, assign.field_path);
        defer field_ref.deinit(self.allocator);
        if (!field_ref.array_ref.mutable) return error.ImmutableLocalMutation;
        if (isWideValueType(field_ref.field_ty)) {
            try self.emitTypedFieldValueToAX(function_name, assign.value, field_ref.field_ty);
        } else {
            try self.emitExprToAExpected(function_name, assign.value, field_ref.field_ty);
        }
        try self.emitStoreArrayFieldFromResult(function_name, field_ref, assign.index);
    }

    fn emitDerefAssign(self: *Emitter, function_name: []const u8, assign: ast.DerefAssign) !void {
        const ptr_expr = switch (assign.target) {
            .deref => |child| child.*,
            else => return error.UnsupportedPointerTarget,
        };
        const ptr_ty = try self.exprType(function_name, ptr_expr);
        if (ptr_ty != .pointer) return error.UnsupportedPointerTarget;
        const child_ty = try self.validatePointerChildType(ptr_ty.pointer.child);
        self.uses_pointer = true;
        if (isWordType(child_ty)) {
            try self.emitExprToAX(function_name, assign.value);
            try self.out.writer.writeAll("    sta zeropage_ptr_value\n    stx zeropage_ptr_value+1\n");
        } else {
            try self.emitExprToAExpected(function_name, assign.value, child_ty);
            try self.out.writer.writeAll("    sta zeropage_ptr_value\n");
        }
        try self.emitExprToAXExpected(function_name, ptr_expr, ptr_ty);
        try self.out.writer.writeAll("    sta zeropage_ptr_tmp\n    stx zeropage_ptr_tmp+1\n    ldy #0\n");
        if (isWordType(child_ty)) {
            try self.out.writer.writeAll("    lda zeropage_ptr_value\n    sta (zeropage_ptr_tmp),y\n    iny\n    lda zeropage_ptr_value+1\n    sta (zeropage_ptr_tmp),y\n");
        } else {
            try self.out.writer.writeAll("    lda zeropage_ptr_value\n    sta (zeropage_ptr_tmp),y\n");
        }
    }

    const CompoundOp = enum {
        add,
        sub,
        mul,
        bit_and,
        bit_or,
        bit_xor,
        shl,
        shr,

        fn alu(op: CompoundOp) ?[]const u8 {
            return switch (op) {
                .add => "adc",
                .sub => "sbc",
                .bit_and => "and",
                .bit_or => "ora",
                .bit_xor => "eor",
                .mul, .shl, .shr => null,
            };
        }

        fn shift(op: CompoundOp) ShiftOp {
            return if (op == .shl) .shl else .shr;
        }
    };

    // An address mode, plus its already evaluated index or pointer registers.
    // The label names are borrowed from the resolved target for this statement.
    const CompoundLocation = union(enum) {
        absolute: struct { label: []const u8, offset: u16 },
        indexed: []const u8, // compiler's existing scaled 8-bit Y index
        indirect, // ptr_tmp + Y=0
        indirect_indexed, // ptr_tmp + captured Y (including byte wrapping)
    };

    fn emitCompoundIndexed(self: *Emitter, function_name: []const u8, assign: ast.ArrayAssign, op: CompoundOp) !void {
        if (try self.maybeManyPointerIndexChildType(function_name, assign.name, assign.index)) |ty| {
            try self.validateCompoundIndexed(function_name, assign, op, ty, null, true);
            // For a direct many-pointer binding, evaluate the index before
            // fetching the pointer value. An index call may change the binding.
            try self.emitCompoundScaledOffset(function_name, assign.index, isWordType(ty));
            const resolved = try self.expectManyPointerIndex(function_name, assign.name, assign.index);
            try self.emitExprToAXExpected(function_name, .{ .value = .{ .ident = assign.name } }, resolved.ptr_ty);
            try self.out.writer.writeAll("    sta zeropage_ptr_tmp\n    stx zeropage_ptr_tmp+1\n");
            try self.emitCompoundAddPointerOffset();
            try self.emitCompoundAt(function_name, assign.value, op, ty, .indirect);
            return;
        }
        if (try self.resolvePointerStructArrayPath(function_name, assign.name)) |path| {
            defer path.deinit(self.allocator);
            const ty = arrayElemToType(path.ty.elem);
            try self.validateCompoundIndexed(function_name, assign, op, ty, path.ty, false);
            const location = try self.emitCompoundPointerArrayLocation(function_name, path, assign.index);
            try self.emitCompoundAt(function_name, assign.value, op, ty, location);
            return;
        }
        const array_ref = try self.resolveArray(function_name, assign.name);
        defer array_ref.deinit(self.allocator);
        if (!array_ref.mutable) return error.ImmutableLocalMutation;
        const ty = arrayElemToType(array_ref.ty.elem);
        try self.validateCompoundIndexed(function_name, assign, op, ty, array_ref.ty, false);
        const location: CompoundLocation = if (arrayOffsetLiteral(array_ref.ty, assign.index)) |offset|
            .{ .absolute = .{ .label = array_ref.label, .offset = offset } }
        else blk: {
            try self.emitExprToA(function_name, assign.index);
            if (isWordType(ty)) try self.out.writer.writeAll("    asl\n");
            try self.out.writer.writeAll("    tay\n");
            break :blk .{ .indexed = array_ref.label };
        };
        try self.emitCompoundAt(function_name, assign.value, op, ty, location);
    }

    fn validateCompoundIndexed(self: *Emitter, function_name: []const u8, assign: ast.ArrayAssign, op: CompoundOp, ty: ast.Type, array_ty: ?ast.ArrayType, many: bool) !void {
        if (array_ty) |array| try self.validateArrayIndexLiteral(array, assign.index);
        switch (op) {
            .add, .sub => {
                if (many) try self.validatePointerElementValue(function_name, ty, assign.value) else try self.validateArrayElementValue(function_name, array_ty.?, assign.value);
                if (isPointerType(ty) or isPointerType(try self.exprType(function_name, assign.value))) return error.UnsupportedPointerCast;
                try validateCompoundExpression(assign.index);
                try validateCompoundExpression(assign.value);
            },
            .bit_and, .bit_or, .bit_xor => {
                try self.validateBitwiseTypes(ty, try self.exprType(function_name, assign.value));
                try validateCompoundExpression(assign.index);
                try validateCompoundExpression(assign.value);
            },
            .mul => try self.validateMultiplicationTypes(ty, try self.exprType(function_name, assign.value)),
            .shl, .shr => try self.validateShiftTypes(ty, try self.exprType(function_name, assign.value), assign.value),
        }
    }

    // These compound ALU paths historically rejected the following expression
    // forms in their AST clone. Dropping that clone is not a grammar expansion.
    fn validateCompoundExpression(expr: ast.Expr) !void {
        switch (expr) {
            .switch_expr, .block_expr, .array_literal => return error.UnsupportedArrayLiteral,
            .struct_literal => return error.UnsupportedStruct,
            .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| {
                try validateCompoundExpression(binary.lhs.*);
                try validateCompoundExpression(binary.rhs.*);
            },
            .not, .bit_not, .deref, .ptr_from_int, .int_from_ptr => |child| try validateCompoundExpression(child.*),
            .as_cast => |cast| try validateCompoundExpression(cast.expr.*),
            .array_index => |index| try validateCompoundExpression(index.index.*),
            .array_field_index => |index| try validateCompoundExpression(index.index.*),
            .if_expr => |cond| {
                try validateCompoundExpression(cond.condition.*);
                try validateCompoundExpression(cond.then_expr.*);
                try validateCompoundExpression(cond.else_expr.*);
            },
            .call => |call| for (call.args) |arg| try validateCompoundExpression(arg),
            .module_call => |call| for (call.args) |arg| try validateCompoundExpression(arg),
            .reu_compare => |transfer| {
                try validateCompoundExpression(transfer.c64_addr.*);
                try validateCompoundExpression(transfer.len.*);
            },
            .reu_heap_alloc => |alloc| try validateCompoundExpression(alloc.len.*),
            .heap_alloc => |alloc| try validateCompoundExpression(alloc.len.*),
            .reu_view => |view| try validateCompoundExpression(view.far.*),
            .far_view_materialize_range => |range| try validateCompoundExpression(range.start.*),
            .value, .address_of, .size_of, .align_of, .offset_of, .c64_read_petscii, .c64_wait_petscii, .reu_present, .far_view_materialize, .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded => {},
        }
    }

    fn emitCompoundScaledOffset(self: *Emitter, function_name: []const u8, index: ast.Expr, word: bool) !void {
        self.uses_pointer = true;
        try self.emitExprToAX(function_name, index);
        if (word) try self.out.writer.writeAll("    asl\n    sta zeropage_ptr_value\n    txa\n    rol\n    tax\n    lda zeropage_ptr_value\n");
        try self.out.writer.writeAll("    sta zeropage_ptr_value\n    stx zeropage_ptr_value+1\n");
    }

    fn emitCompoundAddPointerOffset(self: *Emitter) !void {
        try self.out.writer.writeAll(
            "    clc\n    lda zeropage_ptr_tmp\n    adc zeropage_ptr_value\n    sta zeropage_ptr_tmp\n" ++
                "    lda zeropage_ptr_tmp+1\n    adc zeropage_ptr_value+1\n    sta zeropage_ptr_tmp+1\n    ldy #0\n",
        );
    }

    fn emitCompoundPointerArrayLocation(self: *Emitter, function_name: []const u8, path: PointerStructArrayPath, index: ast.Expr) !CompoundLocation {
        const w = &self.out.writer;
        const hold_base = try self.indexNeedsPointerBaseHold(function_name, index);
        // A pointed struct member captures its enclosing pointer before index
        // evaluation. The indirect read marker is intentionally absent: this
        // setup owns the later write address as well as the read.
        self.uses_pointer = true;
        if (hold_base) {
            try w.print("    lda {s}\n    pha\n    lda {s}+1\n    pha\n", .{ path.pointer_label, path.pointer_label });
        } else try self.emitPointerStructBaseToTmp(path.pointer_label, null);
        const use_y = pointerStructArrayOffsetFitsY(path);
        if (use_y) {
            try self.emitExprToA(function_name, index);
            if (arrayElemIsWord(path.ty.elem)) try w.writeAll("    asl\n");
            if (path.offset != 0) try w.print("    clc\n    adc #{d}\n", .{path.offset});
            try w.writeAll("    tay\n");
        } else try self.emitCompoundScaledOffset(function_name, index, arrayElemIsWord(path.ty.elem));
        if (hold_base) try self.emitCompoundRestorePointer();
        if (use_y) return .indirect_indexed;
        try self.emitAddConstantToPtrTmp(path.offset);
        try self.emitCompoundAddPointerOffset();
        return .indirect;
    }

    fn emitCompoundRestorePointer(self: *Emitter) !void {
        try self.out.writer.writeAll("    pla\n    sta zeropage_ptr_tmp+1\n    pla\n    sta zeropage_ptr_tmp\n");
    }

    fn emitCompoundHoldLocation(self: *Emitter, location: CompoundLocation) !void {
        const w = &self.out.writer;
        if (location == .indirect or location == .indirect_indexed) {
            try w.writeAll("    lda zeropage_ptr_tmp\n    pha\n    lda zeropage_ptr_tmp+1\n    pha\n");
        }
        if (location == .indexed or location == .indirect_indexed) try w.writeAll("    tya\n    pha\n");
    }

    fn emitCompoundLoad(self: *Emitter, location: CompoundLocation, word: bool, hold: bool) !void {
        const w = &self.out.writer;
        switch (location) {
            .absolute => |slot| {
                if (word) try w.print("    ldx {s}+{d}\n", .{ slot.label, slot.offset + 1 });
                try w.print("    lda {s}+{d}\n", .{ slot.label, slot.offset });
            },
            .indexed => |label| {
                try w.print("    lda {s},y\n", .{label});
                if (word) {
                    // Keep the same indexed instruction and bus addresses on
                    // both bytes, including any NMOS indexed dummy read.
                    try w.print("    pha\n    iny\n    lda {s},y\n    tax\n    pla\n", .{label});
                    if (!hold) try w.writeAll("    dey\n");
                }
            },
            .indirect, .indirect_indexed => {
                try w.writeAll("    lda (zeropage_ptr_tmp),y\n");
                if (word) {
                    try w.writeAll("    pha\n    iny\n    lda (zeropage_ptr_tmp),y\n    tax\n    pla\n");
                    if (!hold) try w.writeAll("    dey\n");
                }
            },
        }
    }

    fn emitCompoundStore(self: *Emitter, location: CompoundLocation, word: bool, hold: bool) !void {
        const w = &self.out.writer;
        if (hold) switch (location) {
            .absolute => {},
            .indexed, .indirect_indexed => {
                // Restore Y with A and X already holding the result. Only a
                // word needs a scratch byte, and only after all nested effects.
                if (word) {
                    self.uses_math_tmp = true;
                    try w.writeAll("    sta zeropage_math_tmp\n");
                } else try w.writeAll("    tax\n");
                try w.writeAll("    pla\n    tay\n");
                if (location == .indirect_indexed) try self.emitCompoundRestorePointer();
                try w.writeAll(if (word) "    lda zeropage_math_tmp\n" else "    txa\n");
            },
            .indirect => {
                try w.writeAll("    tay\n");
                try self.emitCompoundRestorePointer();
                try w.writeAll("    tya\n    ldy #0\n");
            },
        };
        switch (location) {
            .absolute => |slot| {
                try w.print("    sta {s}+{d}\n", .{ slot.label, slot.offset });
                if (word) try w.print("    stx {s}+{d}\n", .{ slot.label, slot.offset + 1 });
            },
            .indexed => |label| {
                try w.print("    sta {s},y\n", .{label});
                if (word) try w.print("    iny\n    txa\n    sta {s},y\n", .{label});
            },
            .indirect, .indirect_indexed => {
                try w.writeAll("    sta (zeropage_ptr_tmp),y\n");
                if (word) try w.writeAll("    iny\n    txa\n    sta (zeropage_ptr_tmp),y\n");
            },
        }
    }

    fn emitCompoundAt(self: *Emitter, function_name: []const u8, rhs: ast.Expr, op: CompoundOp, ty: ast.Type, location: CompoundLocation) !void {
        const w = &self.out.writer;
        const word = isWordType(ty);
        const bitwise = op == .bit_and or op == .bit_or or op == .bit_xor;
        const mnemonic = op.alu();
        const direct: ?DirectOperand = if (mnemonic != null) blk: {
            if (exprIntLiteral(rhs)) |n| break :blk .{ .immediate = n };
            break :blk try self.directScalarOperand(function_name, rhs, ty);
        } else null;
        const shift_literal = (op == .shl or op == .shr) and self.program.zeropage_module == null and exprIntLiteral(rhs) != null;
        const multiply = if (op == .mul) self.indexedMultiplyPlan(rhs, word) else null;
        const hold = direct == null and !shift_literal and multiply == null;
        if (hold) try self.emitCompoundHoldLocation(location);
        try self.emitCompoundLoad(location, word, hold);

        if (direct) |operand| {
            if (op == .add or op == .sub) try w.writeAll(if (op == .add) "    clc\n" else "    sec\n");
            try self.emitDirectScalarInstruction(function_name, mnemonic.?, operand, false);
            // A wide direct RHS in the legacy bitwise path reads both bytes,
            // even when the final target is a byte. Preserve that observation.
            const wide_operand = operand == .slot and operand.slot.wide;
            if (word or (bitwise and wide_operand)) {
                if (!word) try w.writeAll("    ldx #0\n");
                try w.writeAll("    pha\n    txa\n");
                try self.emitDirectScalarInstruction(function_name, mnemonic.?, operand, true);
                try w.writeAll("    tax\n    pla\n");
            }
        } else if (shift_literal) {
            if (!word) try w.writeAll("    ldx #0\n");
            const count = try self.prepareShiftCount(function_name, rhs, op.shift());
            // Constant shift lowering and its helper only use A/X and shift
            // cells. Y and both pointer bytes still name the original target.
            try self.finishShift(op.shift(), count);
        } else if (multiply) |plan| {
            switch (plan) {
                .byte => |byte| try self.emitByteMultiplyResult(byte),
                .word => |wide| try self.emitWordMultiplyResult(wide),
                .word_recipe => |recipe| try self.emitWordMultiplyRecipe(function_name, recipe, null),
            }
        } else {
            if (word) try self.emitHoldWordResult() else try w.writeAll("    pha\n");
            switch (op) {
                .mul => {
                    self.uses_multiply = true;
                    try self.emitExprToAX(function_name, rhs);
                    try w.writeAll("    sta zeropage_mul_rhs\n    stx zeropage_mul_rhs+1\n");
                    if (word) try self.emitRestoreWordResult() else try w.writeAll("    pla\n    ldx #0\n");
                    try w.writeAll("    sta zeropage_mul_lhs\n    stx zeropage_mul_lhs+1\n    jsr zeropage_mul16\n");
                },
                .shl, .shr => {
                    const count = try self.prepareShiftCount(function_name, rhs, op.shift());
                    if (word) try self.emitRestoreWordResult() else try w.writeAll("    pla\n    ldx #0\n");
                    try self.finishShift(op.shift(), count);
                },
                else => {
                    self.uses_math_tmp = true;
                    if (word or bitwise) try self.emitExprToAX(function_name, rhs) else try self.emitExprToA(function_name, rhs);
                    try w.writeAll("    sta zeropage_math_tmp\n");
                    if (word) {
                        try w.writeAll("    stx zeropage_math_tmp+1\n");
                        try self.emitRestoreWordResult();
                    } else try w.writeAll("    pla\n");
                    if (op == .add or op == .sub) try w.writeAll(if (op == .add) "    clc\n" else "    sec\n");
                    try w.print("    {s} zeropage_math_tmp\n", .{mnemonic.?});
                    if (word) try w.print("    pha\n    txa\n    {s} zeropage_math_tmp+1\n    tax\n    pla\n", .{mnemonic.?});
                },
            }
        }
        try self.emitCompoundStore(location, word, hold);
    }

    fn emitArrayIndexToAOwned(self: *Emitter, function_name: []const u8, index: ast.ArrayIndex) !void {
        const array_ref = self.resolveArray(function_name, index.name) catch |err| switch (err) {
            error.UnknownVariable => {
                if (try self.resolvePointerStructArrayPath(function_name, index.name)) |path| {
                    path.deinit(self.allocator);
                    try self.emitPointerStructArrayIndexToA(function_name, index);
                } else {
                    try self.emitPointerIndexToA(function_name, index);
                }
                return;
            },
            else => return err,
        };
        defer array_ref.deinit(self.allocator);
        try self.emitArrayIndexToA(function_name, array_ref, index.index.*);
    }

    fn emitArrayIndexToAXOwned(self: *Emitter, function_name: []const u8, index: ast.ArrayIndex) !void {
        const array_ref = self.resolveArray(function_name, index.name) catch |err| switch (err) {
            error.UnknownVariable => {
                if (try self.resolvePointerStructArrayPath(function_name, index.name)) |path| {
                    path.deinit(self.allocator);
                    try self.emitPointerStructArrayIndexToAX(function_name, index);
                } else {
                    try self.emitPointerIndexToAX(function_name, index);
                }
                return;
            },
            else => return err,
        };
        defer array_ref.deinit(self.allocator);
        try self.emitArrayIndexToAX(function_name, array_ref, index.index.*);
    }

    fn emitArrayFieldIndexToAOwned(self: *Emitter, function_name: []const u8, index: ast.ArrayFieldIndex) !void {
        const field_ref = try self.resolveArrayFieldRef(function_name, index.name, index.field_path);
        defer field_ref.deinit(self.allocator);
        try self.emitArrayFieldIndexToA(function_name, field_ref, index.index.*);
    }

    fn emitArrayFieldIndexToAXOwned(self: *Emitter, function_name: []const u8, index: ast.ArrayFieldIndex) !void {
        const field_ref = try self.resolveArrayFieldRef(function_name, index.name, index.field_path);
        defer field_ref.deinit(self.allocator);
        try self.emitArrayFieldIndexToAX(function_name, field_ref, index.index.*);
    }

    fn emitArrayIndexToA(self: *Emitter, function_name: []const u8, array_ref: ArrayRef, index: ast.Expr) !void {
        try self.validateArrayIndexLiteral(array_ref.ty, index);
        const offset = arrayOffsetLiteral(array_ref.ty, index);
        if (offset) |literal_offset| {
            try self.out.writer.print("    lda {s}+{d}\n", .{ array_ref.label, literal_offset });
            return;
        }
        try self.emitExprToA(function_name, index);
        if (arrayElemIsWord(array_ref.ty.elem)) try self.out.writer.writeAll("    asl\n");
        try self.out.writer.print("    tay\n    lda {s},y\n", .{array_ref.label});
    }

    fn emitArrayIndexToAX(self: *Emitter, function_name: []const u8, array_ref: ArrayRef, index: ast.Expr) !void {
        try self.validateArrayIndexLiteral(array_ref.ty, index);
        if (!arrayElemIsWord(array_ref.ty.elem)) {
            try self.emitArrayIndexToA(function_name, array_ref, index);
            try self.out.writer.writeAll("    ldx #0\n");
            return;
        }
        const offset = arrayOffsetLiteral(array_ref.ty, index);
        if (offset) |literal_offset| {
            try self.out.writer.print("    ldx {s}+{d}\n    lda {s}+{d}\n", .{ array_ref.label, literal_offset + 1, array_ref.label, literal_offset });
            return;
        }
        try self.emitExprToA(function_name, index);
        try self.out.writer.print("    asl\n    tay\n    lda {s},y\n    pha\n    iny\n    lda {s},y\n    tax\n    pla\n", .{ array_ref.label, array_ref.label });
    }

    fn arrayFieldOffsetLiteral(self: *Emitter, field_ref: ArrayFieldRef, index: ast.Expr) ?u16 {
        _ = self;
        const literal = exprIntLiteral(index) orelse return null;
        return literal * field_ref.elem_size + field_ref.field_offset;
    }

    fn emitArrayFieldIndexToA(self: *Emitter, function_name: []const u8, field_ref: ArrayFieldRef, index: ast.Expr) !void {
        try self.validateArrayIndexLiteral(field_ref.array_ref.ty, index);
        if (self.arrayFieldOffsetLiteral(field_ref, index)) |literal_offset| {
            try self.out.writer.print("    lda {s}+{d}\n", .{ field_ref.array_ref.label, literal_offset });
            return;
        }
        try self.emitArrayFieldAddressToTmp(function_name, field_ref, index);
        try self.out.writer.writeAll("    ldy #0\n    lda (zeropage_ptr_tmp),y\n");
    }

    fn emitArrayFieldIndexToAX(self: *Emitter, function_name: []const u8, field_ref: ArrayFieldRef, index: ast.Expr) !void {
        if (!isWideValueType(field_ref.field_ty)) {
            try self.emitArrayFieldIndexToA(function_name, field_ref, index);
            try self.out.writer.writeAll("    ldx #0\n");
            return;
        }
        try self.validateArrayIndexLiteral(field_ref.array_ref.ty, index);
        if (self.arrayFieldOffsetLiteral(field_ref, index)) |literal_offset| {
            try self.out.writer.print("    ldx {s}+{d}\n    lda {s}+{d}\n", .{ field_ref.array_ref.label, literal_offset + 1, field_ref.array_ref.label, literal_offset });
            return;
        }
        try self.emitArrayFieldAddressToTmp(function_name, field_ref, index);
        try self.out.writer.writeAll("    ldy #0\n    lda (zeropage_ptr_tmp),y\n    pha\n    iny\n    lda (zeropage_ptr_tmp),y\n    tax\n    pla\n");
    }

    fn emitArrayFieldAddressToTmp(self: *Emitter, function_name: []const u8, field_ref: ArrayFieldRef, index: ast.Expr) !void {
        self.uses_pointer = true;
        if (field_ref.elem_size == 1) {
            try self.emitExprToAX(function_name, index);
        } else if (field_ref.elem_size == 2) {
            try self.emitExprToAX(function_name, index);
            try self.out.writer.writeAll("    asl\n    sta zeropage_ptr_value\n    txa\n    rol\n    tax\n    lda zeropage_ptr_value\n");
        } else {
            self.uses_multiply = true;
            try self.emitExprToAX(function_name, index);
            try self.out.writer.writeAll("    sta zeropage_mul_lhs\n    stx zeropage_mul_lhs+1\n");
            try self.out.writer.print("    lda #{d}\n    ldx #0\n", .{@as(u8, @truncate(field_ref.elem_size))});
            try self.out.writer.writeAll("    sta zeropage_mul_rhs\n    stx zeropage_mul_rhs+1\n    jsr zeropage_mul16\n");
        }
        try self.out.writer.writeAll("    sta zeropage_ptr_value\n    stx zeropage_ptr_value+1\n");
        try self.emitModuleRelocationAnchorKind(.lo8, field_ref.array_ref.label, 0);
        try self.out.writer.print("    lda #<{s}\n", .{field_ref.array_ref.label});
        try self.out.writer.writeAll("    clc\n    adc zeropage_ptr_value\n    sta zeropage_ptr_tmp\n");
        try self.emitModuleRelocationAnchorKind(.hi8, field_ref.array_ref.label, 0);
        try self.out.writer.print(
            "    lda #>{s}\n    adc zeropage_ptr_value+1\n    sta zeropage_ptr_tmp+1\n",
            .{field_ref.array_ref.label},
        );
        try self.emitAddConstantToPtrTmp(field_ref.field_offset);
    }

    fn emitPendingPointerFieldStore(self: *Emitter, function_name: []const u8, field_ref: ArrayFieldRef, index: ast.Expr) !void {
        // Index evaluation can call source functions and arbitrary compiler
        // helpers. Neither shared math scratch nor a lexical call-arg depth
        // protects this pending value from separately emitted callee bodies.
        // Give every store site a distinct resident word; no stack change,
        // overlay or source-frame/noalias assertion is introduced.
        const id = self.field_value_temp_count;
        self.field_value_temp_count += 1;
        const label = try std.fmt.allocPrint(self.allocator, "zeropage_field_value_{d}", .{id});
        defer self.allocator.free(label);
        try self.emitRelocatableAbsInstruction("sta", label);
        try self.emitModuleRelocationAnchorKind(.abs16, label, 1);
        try self.out.writer.print("    stx {s}+1\n", .{label});
        try self.emitArrayFieldAddressToTmp(function_name, field_ref, index);
        try self.out.writer.writeAll("    ldy #0\n");
        try self.emitRelocatableAbsInstruction("lda", label);
        try self.out.writer.writeAll("    sta (zeropage_ptr_tmp),y\n    iny\n");
        try self.emitModuleRelocationAnchorKind(.abs16, label, 1);
        try self.out.writer.print("    lda {s}+1\n    sta (zeropage_ptr_tmp),y\n", .{label});
    }

    fn indexNeedsWordHold(self: *Emitter, function_name: []const u8, index: ast.Expr) !bool {
        return switch (index) {
            .value => false,
            .as_cast => |cast| blk: {
                // Cast validation and value emission still take the ordinary
                // lowering path. Supported casts add loads/widening, not math
                // scratch effects; retain the actual child's clobber boundary.
                _ = try self.validateAsCast(function_name, cast);
                if (!isUnsignedIntegerType(cast.ty)) break :blk true;
                // Exposing math_tmp can change the mixed ZP plan, including
                // startup/restore cost. Preserve the stack route when optional
                // scratch placement is enabled; an emission flag cannot prove
                // the final claim set or its cost.
                const zp = self.program.zeropage_options.zero_page;
                if (zp.declared and zp.allocation != .off) break :blk true;
                break :blk try self.indexNeedsWordHold(function_name, cast.expr.*);
            },
            else => true,
        };
    }

    fn indexNeedsPointerBaseHold(self: *Emitter, function_name: []const u8, index: ast.Expr) !bool {
        return switch (index) {
            .as_cast => |cast| blk: {
                _ = try self.validateAsCast(function_name, cast);
                if (!isUnsignedIntegerType(cast.ty)) break :blk true;
                break :blk try self.indexNeedsPointerBaseHold(function_name, cast.expr.*);
            },
            .value => |value| switch (value) {
                .int, .bool, .char, .ident => false,
                .field => |field| blk: {
                    // Match emitValueToAX/emitFieldToAX's actual path selection.
                    // A Field value can be immediate, direct, or indirect; its
                    // source type alone does not prove pointer scratch effects.
                    if (self.program.findEnum(field.base) != null) break :blk false;
                    if (self.findBinding(function_name, field.base) catch |err| switch (err) {
                        error.UnknownVariable => null,
                        else => return err,
                    }) |binding| {
                        if (self.isUnionType(binding.ty)) return error.UnsupportedStruct;
                    }
                    if (std.mem.eql(u8, field.field, "len")) {
                        if (self.findBinding(function_name, field.base) catch |err| switch (err) {
                            error.UnknownVariable => null,
                            else => return err,
                        }) |binding| {
                            if (binding.ty == .far_view or binding.ty == .near_view) break :blk false;
                        }
                        if (try self.resolvePointerStructArrayPath(function_name, field.base)) |path| {
                            defer path.deinit(self.allocator);
                            break :blk false;
                        }
                        const array_ref = self.resolveArray(function_name, field.base) catch |err| switch (err) {
                            error.UnknownVariable => null,
                            else => return err,
                        };
                        if (array_ref) |ref| {
                            defer ref.deinit(self.allocator);
                            break :blk false;
                        }
                    }
                    const flat_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ field.base, field.field });
                    defer self.allocator.free(flat_name);
                    if (try self.resolvePointerStructPath(function_name, flat_name)) |path| {
                        defer path.deinit(self.allocator);
                        if (isArrayType(path.ty) or self.isStructType(path.ty)) return error.UnsupportedPointerTarget;
                        break :blk true;
                    }
                    break :blk false;
                },
                else => true,
            },
            else => true,
        };
    }

    fn emitHoldWordResult(self: *Emitter) !void {
        try self.out.writer.writeAll("    pha\n    txa\n    pha\n");
    }
    fn emitRestoreWordResult(self: *Emitter) !void {
        try self.out.writer.writeAll("    pla\n    tax\n    pla\n");
    }

    fn emitStoreArrayFieldFromResult(self: *Emitter, function_name: []const u8, field_ref: ArrayFieldRef, index: ast.Expr) !void {
        try self.validateArrayIndexLiteral(field_ref.array_ref.ty, index);
        if ((isPointerType(field_ref.field_ty) or isOptionalPointerType(field_ref.field_ty)) and exprIntLiteral(index) == null) {
            try self.emitPendingPointerFieldStore(function_name, field_ref, index);
            return;
        }
        if (isWordType(field_ref.field_ty) and try self.indexNeedsWordHold(function_name, index)) {
            try self.emitHoldWordResult();
            try self.emitArrayFieldAddressToTmp(function_name, field_ref, index);
            try self.out.writer.writeAll("    ldy #0\n");
            try self.emitRestoreWordResult();
            try self.out.writer.writeAll("    sta (zeropage_ptr_tmp),y\n    iny\n    txa\n    sta (zeropage_ptr_tmp),y\n");
            return;
        }
        if (isWideValueType(field_ref.field_ty)) {
            self.uses_math_tmp = true;
            try self.out.writer.writeAll("    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n");
        } else {
            try self.out.writer.writeAll("    pha\n");
        }
        if (self.arrayFieldOffsetLiteral(field_ref, index)) |literal_offset| {
            if (isWideValueType(field_ref.field_ty)) {
                try self.out.writer.print("    lda zeropage_math_tmp\n    sta {s}+{d}\n    lda zeropage_math_tmp+1\n    sta {s}+{d}\n", .{ field_ref.array_ref.label, literal_offset, field_ref.array_ref.label, literal_offset + 1 });
            } else {
                try self.out.writer.print("    pla\n    sta {s}+{d}\n", .{ field_ref.array_ref.label, literal_offset });
            }
            return;
        }
        try self.emitArrayFieldAddressToTmp(function_name, field_ref, index);
        if (isWideValueType(field_ref.field_ty)) {
            try self.out.writer.writeAll("    ldy #0\n    lda zeropage_math_tmp\n    sta (zeropage_ptr_tmp),y\n    iny\n    lda zeropage_math_tmp+1\n    sta (zeropage_ptr_tmp),y\n");
        } else {
            try self.out.writer.writeAll("    ldy #0\n    pla\n    sta (zeropage_ptr_tmp),y\n");
        }
    }

    fn emitStoreArrayElementImmediate(self: *Emitter, function_name: []const u8, name: []const u8, array_ty: ast.ArrayType, index: u16, value: ast.Expr) !void {
        const label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ function_name, name });
        defer self.allocator.free(label);
        const array_ref = ArrayRef{ .ty = array_ty, .mutable = true, .label = label };
        try self.validateArrayElementValue(function_name, array_ty, value);
        try self.emitStoreArrayElement(function_name, array_ref, .{ .value = .{ .int = index } }, value);
    }

    fn emitStoreArrayElement(self: *Emitter, function_name: []const u8, array_ref: ArrayRef, index: ast.Expr, value: ast.Expr) !void {
        const elem_ty = arrayElemToType(array_ref.ty.elem);
        if (self.isStructType(elem_ty)) {
            try self.emitStoreArrayStructElement(function_name, array_ref, index, elem_ty.custom, value);
            return;
        }
        if (isWordType(elem_ty)) {
            try self.emitExprToAX(function_name, value);
        } else {
            try self.emitExprToAExpected(function_name, value, elem_ty);
        }
        try self.emitStoreArrayElementFromResult(function_name, array_ref, index, elem_ty);
    }

    fn emitStoreArrayStructElement(self: *Emitter, function_name: []const u8, array_ref: ArrayRef, index: ast.Expr, type_name: []const u8, value: ast.Expr) !void {
        const literal_index = exprIntLiteral(index) orelse return error.UnsupportedArrayIndex;
        if (literal_index >= array_ref.ty.len) return error.UnsupportedArrayIndex;
        const literal = switch (value) {
            .struct_literal => |literal| literal,
            else => return error.UnsupportedStruct,
        };
        if (!std.mem.eql(u8, literal.type_name, type_name)) return error.UnsupportedStruct;
        const elem_size = try self.arrayElemStorageBytesForOffset(array_ref.ty.elem);
        try self.emitStructLiteralToArrayElement(function_name, array_ref.label, type_name, literal.fields, literal_index * elem_size);
    }

    fn emitStructLiteralToArrayElement(self: *Emitter, function_name: []const u8, label: []const u8, type_name: []const u8, fields: []const ast.StructFieldInit, base_offset: u16) anyerror!void {
        const decl = self.program.findStruct(type_name) orelse return error.UnsupportedStruct;
        var offset = base_offset;
        for (decl.fields) |field_decl| {
            const init = findStructFieldInit(fields, field_decl.name) orelse return error.UnsupportedStruct;
            try self.emitExprToArrayElementField(function_name, label, field_decl.ty, init.value, offset);
            offset += try self.typeStorageBytesForOffset(field_decl.ty);
        }
        for (fields) |init| {
            if (findStructFieldDecl(decl, init.name) == null) return error.UnsupportedStruct;
        }
    }

    fn emitExprToArrayElementField(self: *Emitter, function_name: []const u8, label: []const u8, ty: ast.Type, value: ast.Expr, offset: u16) anyerror!void {
        switch (ty) {
            .array => |array_ty| {
                const literal = switch (value) {
                    .array_literal => |literal| literal,
                    else => return error.UnsupportedArrayLiteral,
                };
                try self.validateArrayLiteral(function_name, array_ty, literal);
                const elem_size = try self.arrayElemStorageBytesForOffset(array_ty.elem);
                for (literal.values, 0..) |elem_value, elem_index| {
                    try self.emitExprToArrayElementField(function_name, label, arrayElemToType(array_ty.elem), elem_value, offset + @as(u16, @intCast(elem_index)) * elem_size);
                }
            },
            .custom => |custom| {
                if (self.program.findStruct(custom) != null) {
                    const literal = switch (value) {
                        .struct_literal => |literal| literal,
                        else => return error.UnsupportedStruct,
                    };
                    if (!std.mem.eql(u8, literal.type_name, custom)) return error.UnsupportedStruct;
                    try self.emitStructLiteralToArrayElement(function_name, label, custom, literal.fields, offset);
                } else {
                    try self.emitExprToAExpected(function_name, value, ty);
                    try self.out.writer.print("    sta {s}+{d}\n", .{ label, offset });
                }
            },
            .optional => |optional| {
                if (optional.child == .pointer) {
                    try self.emitTypedFieldValueToAX(function_name, value, ty);
                    try self.out.writer.print("    sta {s}+{d}\n    stx {s}+{d}\n", .{ label, offset, label, offset + 1 });
                } else {
                    try self.emitExprToAExpected(function_name, value, ty);
                    try self.out.writer.print("    sta {s}+{d}\n", .{ label, offset });
                }
            },
            .pointer => {
                try self.emitTypedFieldValueToAX(function_name, value, ty);
                try self.out.writer.print("    sta {s}+{d}\n    stx {s}+{d}\n", .{ label, offset, label, offset + 1 });
            },
            .u16, .i16, .usize => {
                try self.emitExprToAXExpected(function_name, value, ty);
                try self.out.writer.print("    sta {s}+{d}\n    stx {s}+{d}\n", .{ label, offset, label, offset + 1 });
            },
            else => {
                try self.emitExprToAExpected(function_name, value, ty);
                try self.out.writer.print("    sta {s}+{d}\n", .{ label, offset });
            },
        }
    }

    fn emitStoreArrayElementFromResult(self: *Emitter, function_name: []const u8, array_ref: ArrayRef, index: ast.Expr, elem_ty: ast.Type) !void {
        try self.validateArrayIndexLiteral(array_ref.ty, index);
        if (isWordType(elem_ty) and try self.indexNeedsWordHold(function_name, index)) {
            try self.emitHoldWordResult();
            try self.emitExprToA(function_name, index);
            try self.out.writer.writeAll("    asl\n    tay\n");
            try self.emitRestoreWordResult();
            try self.out.writer.print("    sta {s},y\n    iny\n    txa\n    sta {s},y\n", .{ array_ref.label, array_ref.label });
            return;
        }
        if (isWordType(elem_ty)) {
            self.uses_math_tmp = true;
            try self.out.writer.writeAll("    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n");
        } else {
            try self.out.writer.writeAll("    pha\n");
        }
        const offset = arrayOffsetLiteral(array_ref.ty, index);
        if (offset) |literal_offset| {
            if (isWordType(elem_ty)) {
                try self.out.writer.print("    lda zeropage_math_tmp\n    sta {s}+{d}\n    lda zeropage_math_tmp+1\n    sta {s}+{d}\n", .{ array_ref.label, literal_offset, array_ref.label, literal_offset + 1 });
            } else {
                try self.out.writer.print("    pla\n    sta {s}+{d}\n", .{ array_ref.label, literal_offset });
            }
            return;
        }
        try self.emitExprToA(function_name, index);
        if (isWordType(elem_ty)) {
            try self.out.writer.print("    asl\n    tay\n    lda zeropage_math_tmp\n    sta {s},y\n    iny\n    lda zeropage_math_tmp+1\n    sta {s},y\n", .{ array_ref.label, array_ref.label });
        } else {
            try self.out.writer.print("    tay\n    pla\n    sta {s},y\n", .{array_ref.label});
        }
    }

    fn resolveArray(self: *Emitter, function_name: []const u8, name: []const u8) !ArrayRef {
        if (try self.findBinding(function_name, name)) |binding| {
            if (binding.ty == .array) {
                const label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ function_name, name });
                return .{ .ty = binding.ty.array, .mutable = binding.mutable, .label = label, .label_owned = true };
            }
        }
        if (self.program.findArray(name)) |constant| {
            const label = try std.fmt.allocPrint(self.allocator, "zeropage_arr_{s}", .{constant.name});
            return .{ .ty = constant.ty, .mutable = false, .label = label, .label_owned = true };
        }
        return error.UnknownVariable;
    }

    fn resolveArrayFieldRef(self: *Emitter, function_name: []const u8, name: []const u8, field_path: []const u8) !ArrayFieldRef {
        const array_ref = try self.resolveArray(function_name, name);
        errdefer array_ref.deinit(self.allocator);
        const struct_name = switch (array_ref.ty.elem) {
            .custom => |custom| if (self.program.findStruct(custom) != null) custom else return error.UnsupportedStruct,
            else => return error.UnsupportedStruct,
        };
        const info = (try self.resolveStructPathInfo(struct_name, field_path)) orelse return error.UnknownField;
        if (isArrayType(info.ty) or self.isStructType(info.ty)) return error.UnsupportedStruct;
        return .{
            .array_ref = array_ref,
            .field_ty = info.ty,
            .field_offset = info.offset,
            .elem_size = try self.arrayElemStorageBytesForOffset(array_ref.ty.elem),
        };
    }

    fn resolveAddressTarget(self: *Emitter, function_name: []const u8, address: ast.AddressOf) !AddressTarget {
        if (address.index) |literal_index| {
            const array_ref = self.resolveArray(function_name, address.name) catch |err| switch (err) {
                error.UnknownVariable => {
                    const ptr_array = (try self.resolvePointerStructArrayPath(function_name, address.name)) orelse return err;
                    if (literal_index >= ptr_array.ty.len) {
                        ptr_array.deinit(self.allocator);
                        return error.UnsupportedArrayIndex;
                    }
                    const pointer_ty = ast.Type{ .pointer = .{
                        .child = arrayElemToPointerChild(ptr_array.ty.elem),
                        .is_volatile = false,
                    } };
                    return .{
                        .pointer_ty = pointer_ty,
                        .label = ptr_array.pointer_label,
                        .label_owned = ptr_array.pointer_label_owned,
                        .offset = ptr_array.offset + literal_index * arrayElemSize(ptr_array.ty.elem),
                        .indirect = true,
                    };
                },
                else => return err,
            };
            if (!array_ref.mutable and !std.mem.startsWith(u8, array_ref.label, "zeropage_arr_")) {
                array_ref.deinit(self.allocator);
                return error.UnsupportedPointerTarget;
            }
            if (literal_index >= array_ref.ty.len) {
                array_ref.deinit(self.allocator);
                return error.UnsupportedArrayIndex;
            }
            const child_ty = arrayElemToType(array_ref.ty.elem);
            if (isArrayType(child_ty) or self.isStructType(child_ty)) {
                array_ref.deinit(self.allocator);
                return error.UnsupportedPointerTarget;
            }
            const pointer_ty = ast.Type{ .pointer = .{
                .child = arrayElemToPointerChild(array_ref.ty.elem),
                .is_volatile = false,
            } };
            return .{ .pointer_ty = pointer_ty, .label = array_ref.label, .offset = literal_index * arrayElemSize(array_ref.ty.elem), .label_owned = array_ref.label_owned };
        }
        const binding = self.expectBinding(function_name, address.name) catch |err| switch (err) {
            error.UnknownVariable => {
                const path = (try self.resolvePointerStructPath(function_name, address.name)) orelse return err;
                if (!self.isStructType(path.ty)) {
                    path.deinit(self.allocator);
                    return error.UnsupportedPointerTarget;
                }
                return .{
                    .pointer_ty = .{ .pointer = .{ .child = .{ .custom = path.ty.custom }, .is_volatile = false } },
                    .label = path.pointer_label,
                    .label_owned = path.pointer_label_owned,
                    .offset = path.offset,
                    .indirect = true,
                };
            },
            else => return err,
        };
        if (!binding.mutable) return error.UnsupportedPointerTarget;
        if (self.isStructType(binding.ty)) {
            const label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ function_name, address.name });
            return .{ .pointer_ty = .{ .pointer = .{ .child = .{ .custom = binding.ty.custom }, .is_volatile = false } }, .label = label, .label_owned = true };
        }
        if (isArrayType(binding.ty)) return error.UnsupportedPointerTarget;
        if (binding.ty == .pointer) return error.UnsupportedPointerTarget;
        const pointer_ty = ast.Type{ .pointer = .{
            .child = try self.typeToPointerChild(binding.ty),
            .is_volatile = false,
        } };
        const label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ function_name, address.name });
        return .{ .pointer_ty = pointer_ty, .label = label, .label_owned = true };
    }

    fn typeToPointerChild(self: *Emitter, ty: ast.Type) !ast.PointerChildType {
        return switch (ty) {
            .bool => .{ .scalar = .bool },
            .u8 => .{ .scalar = .u8 },
            .i8 => .{ .scalar = .i8 },
            .u16 => .{ .scalar = .u16 },
            .i16 => .{ .scalar = .i16 },
            .usize => .{ .scalar = .usize },
            .custom => |name| blk: {
                if (self.program.findEnum(name) == null and self.program.findStruct(name) == null) return error.UnsupportedPointerType;
                break :blk .{ .custom = name };
            },
            else => error.UnsupportedPointerType,
        };
    }

    pub fn emitExprToA(self: *Emitter, function_name: []const u8, expr: ast.Expr) anyerror!void {
        const w = &self.out.writer;
        switch (expr) {
            .value => |value| try self.emitValueToA(function_name, value),
            .add => |add| try self.emitByteBinaryMath(function_name, add, .add),
            .sub => |sub| try self.emitByteBinaryMath(function_name, sub, .sub),
            .mul => |mul| {
                try self.validateMultiplication(function_name, mul);
                if (!try self.emitConstantByteMultiply(function_name, mul)) try self.emitMulToAX(function_name, mul);
            },
            .bit_and => |bit_and| try self.emitBitwiseToAX(function_name, bit_and, .bit_and),
            .bit_or => |bit_or| try self.emitBitwiseToAX(function_name, bit_or, .bit_or),
            .bit_xor => |bit_xor| try self.emitBitwiseToAX(function_name, bit_xor, .bit_xor),
            .shl => |shl| try self.emitShiftToAX(function_name, shl, .shl),
            .shr => |shr| try self.emitShiftToAX(function_name, shr, .shr),
            .eq => |eq| try self.emitCompareToA(function_name, eq, .eq),
            .ne => |ne| try self.emitCompareToA(function_name, ne, .ne),
            .lt => |lt| try self.emitCompareToA(function_name, lt, .lt),
            .lte => |lte| try self.emitCompareToA(function_name, lte, .lte),
            .gt => |gt| try self.emitCompareToA(function_name, gt, .gt),
            .gte => |gte| try self.emitCompareToA(function_name, gte, .gte),
            .bool_and => |and_expr| try self.emitLogicalToA(function_name, and_expr, .bool_and),
            .bool_or => |or_expr| try self.emitLogicalToA(function_name, or_expr, .bool_or),
            .not => |child| {
                const id = self.nextLabel();
                try self.expectBoolExpr(function_name, child.*);
                try self.emitExprToA(function_name, child.*);
                try w.print("    cmp #0\n    beq bool_not_{d}_true\n", .{id});
                try w.print("    jmp bool_not_{d}_false\nbool_not_{d}_true:\n", .{ id, id });
                try w.print("    lda #1\n    jmp bool_not_{d}_done\nbool_not_{d}_false:\n    lda #0\nbool_not_{d}_done:\n", .{ id, id, id });
            },
            .bit_not => |child| try self.emitBitNotToAX(function_name, child),
            .c64_read_petscii => try self.emitKeyboardReadPetscii(),
            .c64_wait_petscii => try self.emitKeyboardWaitPetscii(),
            .reu_present => try self.emitReuPresent(),
            .reu_compare => |transfer| try self.emitReuCompare(function_name, transfer),
            .reu_heap_alloc => return error.UnsupportedOptional,
            .reu_view => return error.UnsupportedPointerType,
            .far_view_materialize => return error.UnsupportedOptional,
            .far_view_materialize_range => return error.UnsupportedOptional,
            .module_load => |load| try self.emitModuleLoad(load),
            .module_disk_load => |load| try self.emitModuleDiskLoad(load),
            .module_load_dependency => |load| try self.emitModuleDependencyLoad(load),
            .module_acquire_dependency => |load| try self.emitModuleDependencyAcquire(load),
            .module_load_dependency_graph => |load| try self.emitModuleDependencyGraphLoad(load),
            .module_acquire_dependency_graph => |load| try self.emitModuleDependencyGraphAcquire(load),
            .module_is_loaded => |load| try self.emitModuleIsLoaded(load),
            .module_call => return error.UnsupportedOptional,
            .heap_alloc => |alloc| try self.emitHeapAllocToAX(function_name, alloc),
            .size_of, .align_of, .offset_of => {
                const value = try self.layoutComptimeValue(expr);
                try w.print("    lda #${x:0>2}\n", .{@as(u8, @truncate(value))});
            },
            .deref => |child| try self.emitDerefToA(function_name, child.*),
            .int_from_ptr => |child| try self.emitExprToAXExpected(function_name, child.*, try self.exprType(function_name, child.*)),
            .address_of, .ptr_from_int => return error.UnsupportedPointerCast,
            .as_cast => |as_cast| {
                _ = try self.validateAsCast(function_name, as_cast);
                if (isWideValueType(as_cast.ty)) {
                    try self.emitExprToAXExpected(function_name, as_cast.expr.*, as_cast.ty);
                } else {
                    try self.emitExprToAExpected(function_name, as_cast.expr.*, as_cast.ty);
                }
            },
            .if_expr => |if_expr| try self.emitIfExprToA(function_name, if_expr),
            .switch_expr => |switch_expr| try self.emitSwitchExprToA(function_name, switch_expr),
            .block_expr => |block_expr| try self.emitBlockExprToA(function_name, block_expr),
            .call => |call| try self.emitCall(function_name, call),
            .array_index => |index| try self.emitArrayIndexToAOwned(function_name, index),
            .array_field_index => |index| try self.emitArrayFieldIndexToAOwned(function_name, index),
            .array_literal => return error.UnsupportedArrayByValue,
            .struct_literal => return error.UnsupportedStruct,
        }
    }

    fn emitExprToAExpected(self: *Emitter, function_name: []const u8, expr: ast.Expr, expected_ty: ast.Type) anyerror!void {
        if (self.isStructType(expected_ty) or self.isUnionType(expected_ty)) return error.UnsupportedStruct;
        switch (expr) {
            .value => |value| switch (value) {
                .enum_literal => |literal| {
                    try self.out.writer.print("    lda #{d}\n", .{try self.enumLiteralValue(expected_ty, literal)});
                    return;
                },
                else => {},
            },
            .if_expr => |if_expr| {
                try self.emitIfExprToAExpected(function_name, if_expr, expected_ty);
                return;
            },
            .switch_expr => |switch_expr| {
                try self.emitSwitchExprToAExpected(function_name, switch_expr, expected_ty);
                return;
            },
            .block_expr => |block_expr| {
                try self.emitBlockExprToAExpected(function_name, block_expr, expected_ty);
                return;
            },
            .as_cast => |as_cast| {
                _ = try self.validateAsCast(function_name, as_cast);
                if (!self.canUseTypedValueAs(as_cast.ty, expected_ty)) return error.UnsupportedCast;
                try self.emitExprToAExpected(function_name, as_cast.expr.*, as_cast.ty);
                return;
            },
            else => {},
        }
        try self.emitExprToA(function_name, expr);
        const actual_ty = try self.exprType(function_name, expr);
        if (self.isEnumType(expected_ty) and !typesEqual(expected_ty, actual_ty)) return error.UnsupportedEnumLiteral;
    }

    fn emitExprToAXExpected(self: *Emitter, function_name: []const u8, expr: ast.Expr, expected_ty: ast.Type) anyerror!void {
        if (expected_ty == .pointer) {
            switch (expr) {
                .ptr_from_int => |child| {
                    _ = try self.validatePointerChildType(expected_ty.pointer.child);
                    const child_ty = try self.exprType(function_name, child.*);
                    if (!isNumericScalarType(child_ty) or isBoolType(child_ty) or isSignedType(child_ty)) return error.UnsupportedPointerCast;
                    try self.emitExprToAX(function_name, child.*);
                    return;
                },
                .address_of => |address| {
                    try self.emitAddressOfToAX(function_name, address, expected_ty);
                    return;
                },
                .heap_alloc => |alloc| {
                    const payload_ty: ast.Type = .{ .pointer = .{ .child = .{ .scalar = .u8 }, .is_many = true, .is_volatile = false } };
                    if (!typesEqual(expected_ty, payload_ty)) return error.UnsupportedPointerType;
                    try self.emitHeapAllocToAX(function_name, alloc);
                    return;
                },
                else => {},
            }
            const actual_ty = try self.exprTypeAllowContext(function_name, expr, expected_ty);
            if (actual_ty == .far_bytes) return error.UnsupportedPointerType;
        }
        switch (expr) {
            .as_cast => |as_cast| {
                _ = try self.validateAsCast(function_name, as_cast);
                if (isPointerType(expected_ty)) {
                    if (!typesEqual(as_cast.ty, expected_ty)) return error.UnsupportedPointerCast;
                    try self.emitExprToAXExpected(function_name, as_cast.expr.*, as_cast.ty);
                    return;
                }
                if (!self.canUseTypedValueAs(as_cast.ty, expected_ty)) return error.UnsupportedCast;
                if (isWideValueType(as_cast.ty)) {
                    try self.emitExprToAXExpected(function_name, as_cast.expr.*, as_cast.ty);
                } else {
                    try self.emitExprToAExpected(function_name, as_cast.expr.*, as_cast.ty);
                    try self.out.writer.writeAll("    ldx #0\n");
                }
                return;
            },
            else => {},
        }
        try self.emitExprToAX(function_name, expr);
    }

    fn emitByteBinaryMath(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr, op: MathOp) !void {
        try self.validateAddSub(function_name, binary);
        if (try self.emitImmediateBinaryMath(function_name, binary, op, false)) return;
        if (try self.emitDirectBinaryMath(function_name, binary, op, false)) return;
        self.uses_math_tmp = true;
        try self.emitExprToA(function_name, binary.lhs.*);
        try self.out.writer.writeAll("    pha\n");
        try self.emitExprToA(function_name, binary.rhs.*);
        try self.out.writer.writeAll("    sta zeropage_math_tmp\n    pla\n");
        switch (op) {
            .add => try self.out.writer.writeAll("    clc\n    adc zeropage_math_tmp\n"),
            .sub => try self.out.writer.writeAll("    sec\n    sbc zeropage_math_tmp\n"),
        }
    }

    fn emitImmediateBinaryMath(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr, op: MathOp, word: bool) !bool {
        // A literal has no effects. Addition can select it on either side;
        // subtraction must preserve the original operand order.
        const literal = exprIntLiteral(binary.rhs.*) orelse
            (if (op == .add) exprIntLiteral(binary.lhs.*) else null) orelse return false;
        const value = if (exprIntLiteral(binary.rhs.*) != null) binary.lhs.* else binary.rhs.*;
        const w = &self.out.writer;
        if (word) {
            try self.emitExprToAX(function_name, value);
        } else {
            try self.emitExprToA(function_name, value);
        }
        const carry = if (op == .add) "clc" else "sec";
        const instruction = if (op == .add) "adc" else "sbc";
        try w.print("    {s}\n    {s} #{d}\n", .{ carry, instruction, @as(u8, @truncate(literal)) });
        if (word) {
            // PHA/TXA preserve carry/borrow between the low and high bytes.
            // Save the low result on the hardware stack, avoiding global scratch
            // and making nested expressions safe without allocating new labels.
            try w.print("    pha\n    txa\n    {s} #{d}\n    tax\n    pla\n", .{ instruction, @as(u8, @truncate(literal >> 8)) });
        }
        return true;
    }

    fn emitDirectBinaryMath(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr, op: MathOp, word: bool) !bool {
        const operand = try self.directScalarOperand(function_name, binary.rhs.*, try self.exprType(function_name, binary.lhs.*)) orelse return false;
        // Evaluate lhs first: calls/indirect stores may change the RHS slot.
        if (word) try self.emitExprToAX(function_name, binary.lhs.*) else try self.emitExprToA(function_name, binary.lhs.*);
        try self.out.writer.print("    {s}\n", .{if (op == .add) "clc" else "sec"});
        const mnemonic = if (op == .add) "adc" else "sbc";
        try self.emitDirectScalarInstruction(function_name, mnemonic, operand, false);
        if (word) {
            try self.out.writer.writeAll("    pha\n    txa\n");
            try self.emitDirectScalarInstruction(function_name, mnemonic, operand, true);
            try self.out.writer.writeAll("    tax\n    pla\n");
        }
        return true;
    }

    fn emitDirectBitwise(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr, op: BitwiseOp) !bool {
        const operand = try self.directScalarOperand(function_name, binary.rhs.*, try self.exprType(function_name, binary.lhs.*)) orelse return false;
        try self.emitExprToAX(function_name, binary.lhs.*);
        const mnemonic = switch (op) {
            .bit_and => "and",
            .bit_or => "ora",
            .bit_xor => "eor",
        };
        try self.emitDirectScalarInstruction(function_name, mnemonic, operand, false);
        try self.out.writer.writeAll("    pha\n    txa\n");
        try self.emitDirectScalarInstruction(function_name, mnemonic, operand, true);
        try self.out.writer.writeAll("    tax\n    pla\n");
        return true;
    }

    fn emitMulAssign(self: *Emitter, function_name: []const u8, assign: ast.AddAssign, binding: Binding) !void {
        const w = &self.out.writer;
        if (isWordType(binding.ty) and self.canSpecializeWordMultiply()) {
            if (exprIntLiteral(assign.value)) |factor| {
                if (word_multiply.choose(factor, false)) |plan| {
                    const value: ast.Expr = .{ .value = .{ .ident = assign.name } };
                    try self.emitExprToAX(function_name, value);
                    try self.emitWordMultiplyRecipe(function_name, plan, .{ .slot = .{ .name = assign.name, .wide = true } });
                    return;
                }
            }
        }
        self.uses_multiply = true;
        try self.emitExprToAX(function_name, assign.value);
        try w.writeAll("    sta zeropage_mul_rhs\n    stx zeropage_mul_rhs+1\n");
        if (isWordType(binding.ty)) {
            try w.print("    lda {s}_{s}\n    sta zeropage_mul_lhs\n    lda {s}_{s}+1\n    sta zeropage_mul_lhs+1\n", .{ function_name, assign.name, function_name, assign.name });
        } else {
            try w.print("    lda {s}_{s}\n    sta zeropage_mul_lhs\n    lda #0\n    sta zeropage_mul_lhs+1\n", .{ function_name, assign.name });
        }
        try w.writeAll("    jsr zeropage_mul16\n");
    }

    fn emitMulToAX(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr) !void {
        try self.validateMultiplication(function_name, binary);
        if (try self.emitConstantWordMultiply(function_name, binary)) return;
        self.uses_multiply = true;
        try self.emitExprToAX(function_name, binary.lhs.*);
        try self.out.writer.writeAll("    pha\n    txa\n    pha\n");
        try self.emitExprToAX(function_name, binary.rhs.*);
        try self.out.writer.writeAll("    sta zeropage_mul_rhs\n    stx zeropage_mul_rhs+1\n    pla\n    sta zeropage_mul_lhs+1\n    pla\n    sta zeropage_mul_lhs\n    jsr zeropage_mul16\n");
    }

    const ConstantMultiply = struct { value: ast.Expr, factor: u16 };
    const ByteMultiplyPlan = struct { factor: u8, shifts: u8, adds: u8 };
    const WordMultiplyPlan = struct { factor: u16, shifts: u16 };
    const MultiplyPlan = union(enum) { byte: ByteMultiplyPlan, word: WordMultiplyPlan, word_recipe: word_multiply.Plan };

    fn constantMultiply(binary: ast.BinaryExpr) ?ConstantMultiply {
        if (exprIntLiteral(binary.rhs.*)) |factor| return .{ .value = binary.lhs.*, .factor = factor };
        if (exprIntLiteral(binary.lhs.*)) |factor| return .{ .value = binary.rhs.*, .factor = factor };
        return null;
    }

    fn byteMultiplyPlan(factor: u8) ?ByteMultiplyPlan {
        const shifts: u8 = if (factor == 0) 0 else 7 - @clz(factor);
        const adds: u8 = if (factor == 0) 0 else @popCount(factor) - 1;
        // Absolute scratch operands: STA=3, ASL A=1, CLC+ADC=4 bytes.
        // The old generic literal-operand setup costs at least 24 bytes.
        const bytes: u16 = @as(u16, shifts) + @as(u16, adds) * 4 + (if (adds != 0) @as(u16, 3) else 0);
        if (bytes > 24) return null;
        return .{ .factor = factor, .shifts = shifts, .adds = adds };
    }

    fn wordMultiplyPlan(factor: u16) ?WordMultiplyPlan {
        if (factor > 1 and !std.math.isPowerOfTwo(factor)) return null;
        const shifts: u16 = if (factor <= 1) 0 else @ctz(factor);
        // Four A/X shifts fit the 24-byte generic operand setup. Shifts >=8
        // discard the old high byte and need at most seven byte ASLs instead.
        if (shifts > 4 and shifts < 8) return null;
        return .{ .factor = factor, .shifts = shifts };
    }

    fn indexedMultiplyPlan(self: *Emitter, rhs: ast.Expr, word: bool) ?MultiplyPlan {
        if (self.program.zeropage_module != null or self.multiply_pinned) return null;
        const factor = exprIntLiteral(rhs) orelse return null;
        if (word) {
            if (wordMultiplyPlan(factor)) |plan| return .{ .word = plan };
            if (!self.canSpecializeWordMultiply()) return null;
            return .{ .word_recipe = word_multiply.choose(factor, true) orelse return null };
        }
        const plan = byteMultiplyPlan(@truncate(factor)) orelse return null;
        // An added arithmetic cell can change the managed snapshot and its
        // startup/return cost. Admit only scratch-free plans in those modes.
        const allocation = self.program.zeropage_options.zero_page.allocation;
        if (plan.adds != 0 and (allocation == .scratch or allocation == .scalars)) return null;
        return .{ .byte = plan };
    }

    fn emitConstantByteMultiply(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr) !bool {
        const constant = constantMultiply(binary) orelse return false;
        // Keep typed volatile word loads at their original width. This path is
        // for a byte-valued operand and an A-only consumer, never an A/X result.
        if (try self.exprType(function_name, constant.value) != .u8) return false;
        const plan = byteMultiplyPlan(@truncate(constant.factor)) orelse return false;
        try self.emitExprToA(function_name, constant.value);
        try self.emitByteMultiplyResult(plan);
        return true;
    }

    // These result operations preserve Y and ptr_tmp, including when a source
    // symbol is named `a`. Bare shifts select the accumulator unambiguously.
    fn emitByteMultiplyResult(self: *Emitter, plan: ByteMultiplyPlan) !void {
        if (plan.factor == 0) {
            try self.out.writer.writeAll("    lda #0\n");
            return;
        }
        if (plan.adds != 0) {
            self.uses_math_tmp = true;
            try self.out.writer.writeAll("    sta zeropage_math_tmp\n");
        }
        var bit = plan.shifts;
        while (bit != 0) {
            bit -= 1;
            try self.out.writer.writeAll("    asl\n");
            if ((plan.factor & (@as(u8, 1) << @intCast(bit))) != 0) try self.out.writer.writeAll("    clc\n    adc zeropage_math_tmp\n");
        }
    }

    fn emitConstantWordMultiply(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr) !bool {
        const constant = constantMultiply(binary) orelse return false;
        if (wordMultiplyPlan(constant.factor)) |plan| {
            try self.emitExprToAX(function_name, constant.value);
            try self.emitWordMultiplyResult(plan);
            return true;
        }
        if (!self.canSpecializeWordMultiply()) return false;
        const direct = try self.directScalarOperand(function_name, constant.value, .u16);
        const plan = word_multiply.choose(constant.factor, direct == null) orelse return false;
        try self.emitExprToAX(function_name, constant.value);
        try self.emitWordMultiplyRecipe(function_name, plan, direct);
        return true;
    }

    fn canSpecializeWordMultiply(self: *const Emitter) bool {
        return self.program.zeropage_module == null and !self.multiply_pinned and
            self.program.zeropage_options.memory.placements.len == 0;
    }

    fn emitWordMultiplyRecipe(self: *Emitter, function_name: []const u8, plan: word_multiply.Plan, direct: ?DirectOperand) !void {
        const w = &self.out.writer;
        if (direct == null) {
            // Reuse the general multiplier's input word. The source operand
            // is fully evaluated before this store, and the recipe calls out
            // to no other code that could replace the pending input.
            self.uses_multiply_lhs = true;
            try w.writeAll("    sta zeropage_mul_lhs\n    stx zeropage_mul_lhs+1\n");
        }
        var bit = plan.shifts;
        while (bit != 0) {
            bit -= 1;
            try self.emitWordMultiplyShift();
            const mask = @as(u16, 1) << bit;
            if ((plan.adds | plan.subtracts) & mask == 0) continue;
            const subtract = plan.subtracts & mask != 0;
            const op = if (subtract) "sbc" else "adc";
            try w.writeAll(if (subtract) "    sec\n" else "    clc\n");
            if (direct) |operand| {
                try self.emitDirectScalarInstruction(function_name, op, operand, false);
                try w.writeAll("    pha\n    txa\n");
                try self.emitDirectScalarInstruction(function_name, op, operand, true);
            } else {
                try w.print("    {s} zeropage_mul_lhs\n    pha\n    txa\n    {s} zeropage_mul_lhs+1\n", .{ op, op });
            }
            try w.writeAll("    tax\n    pla\n");
        }
    }

    fn emitWordMultiplyShift(self: *Emitter) !void {
        // The balanced stack preserves the low byte and leaves Y available
        // to a caller retaining an indexed destination.
        try self.out.writer.writeAll("    asl\n    pha\n    txa\n    rol\n    tax\n    pla\n");
    }

    fn emitWordMultiplyResult(self: *Emitter, plan: WordMultiplyPlan) !void {
        if (plan.factor == 0) {
            try self.out.writer.writeAll("    lda #0\n    ldx #0\n");
        } else if (plan.shifts >= 8) {
            for (0..plan.shifts - 8) |_| try self.out.writer.writeAll("    asl\n");
            try self.out.writer.writeAll("    tax\n    lda #0\n");
        } else {
            for (0..plan.shifts) |_| try self.emitWordMultiplyShift();
        }
    }

    fn emitBitwiseAssign(self: *Emitter, function_name: []const u8, assign: ast.AddAssign, op: BitwiseOp) !void {
        const w = &self.out.writer;
        if (try self.resolvePointerStructPath(function_name, assign.name)) |path| {
            defer path.deinit(self.allocator);
            if (isArrayType(path.ty) or self.isStructType(path.ty)) return error.UnsupportedPointerTarget;
            try self.validateBitwiseTypes(path.ty, try self.exprType(function_name, assign.value));
            self.uses_math_tmp = true;
            try self.emitExprToAX(function_name, assign.value);
            try w.writeAll("    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n");
            if (isWordType(path.ty)) {
                try self.emitPointerStructPathToAX(function_name, assign.name);
                try self.emitBitwiseAccumulatorWithTmp(op, false);
                try w.writeAll("    pha\n    txa\n");
                try self.emitBitwiseAccumulatorWithTmp(op, true);
                try w.writeAll("    tax\n    pla\n");
            } else {
                try self.emitPointerStructPathToA(function_name, assign.name);
                try self.emitBitwiseAccumulatorWithTmp(op, false);
            }
            try self.emitStorePointerStructPathFromResult(function_name, assign.name, path.ty);
            return;
        }
        const binding = try self.expectBinding(function_name, assign.name);
        if (!binding.mutable) return error.ImmutableLocalMutation;
        try self.validateBitwiseTypes(binding.ty, try self.exprType(function_name, assign.value));
        if (self.program.zeropage_module == null) {
            // These operators commute. Keep RHS effects before reading the
            // destination, then use the destination itself as the ALU operand.
            try self.emitExprToAX(function_name, assign.value);
            const mnemonic = switch (op) {
                .bit_and => "and",
                .bit_or => "ora",
                .bit_xor => "eor",
            };
            try w.print("    {s} {s}_{s}\n    sta {s}_{s}\n", .{ mnemonic, function_name, assign.name, function_name, assign.name });
            if (isWordType(binding.ty)) try w.print("    txa\n    {s} {s}_{s}+1\n    sta {s}_{s}+1\n", .{ mnemonic, function_name, assign.name, function_name, assign.name });
            return;
        }
        self.uses_math_tmp = true;
        try self.emitExprToAX(function_name, assign.value);
        try w.writeAll("    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n");
        if (isWordType(binding.ty)) {
            try w.print("    lda {s}_{s}\n", .{ function_name, assign.name });
            try self.emitBitwiseAccumulatorWithTmp(op, false);
            try w.print("    sta {s}_{s}\n    lda {s}_{s}+1\n", .{ function_name, assign.name, function_name, assign.name });
            try self.emitBitwiseAccumulatorWithTmp(op, true);
            try w.print("    sta {s}_{s}+1\n", .{ function_name, assign.name });
        } else {
            try w.print("    lda {s}_{s}\n", .{ function_name, assign.name });
            try self.emitBitwiseAccumulatorWithTmp(op, false);
            try w.print("    sta {s}_{s}\n", .{ function_name, assign.name });
        }
    }

    fn emitShiftAssign(self: *Emitter, function_name: []const u8, assign: ast.AddAssign, op: ShiftOp) !void {
        const w = &self.out.writer;
        if (try self.resolvePointerStructPath(function_name, assign.name)) |path| {
            defer path.deinit(self.allocator);
            if (isArrayType(path.ty) or self.isStructType(path.ty)) return error.UnsupportedPointerTarget;
            try self.validateShiftTypes(path.ty, try self.exprType(function_name, assign.value), assign.value);
            const count = try self.prepareShiftCount(function_name, assign.value, op);
            try self.emitPointerStructPathToAX(function_name, assign.name);
            try self.finishShift(op, count);
            try self.emitStorePointerStructPathFromResult(function_name, assign.name, path.ty);
            return;
        }
        const binding = try self.expectBinding(function_name, assign.name);
        if (!binding.mutable) return error.ImmutableLocalMutation;
        try self.validateShiftTypes(binding.ty, try self.exprType(function_name, assign.value), assign.value);
        const count = try self.prepareShiftCount(function_name, assign.value, op);
        if (isWordType(binding.ty)) {
            try w.print("    lda {s}_{s}\n    ldx {s}_{s}+1\n", .{ function_name, assign.name, function_name, assign.name });
        } else {
            try w.print("    lda {s}_{s}\n    ldx #0\n", .{ function_name, assign.name });
        }
        try self.finishShift(op, count);
        if (isWordType(binding.ty)) {
            try w.print("    sta {s}_{s}\n    stx {s}_{s}+1\n", .{ function_name, assign.name, function_name, assign.name });
        } else {
            try w.print("    sta {s}_{s}\n", .{ function_name, assign.name });
        }
    }

    fn emitBitwiseToAX(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr, op: BitwiseOp) !void {
        try self.validateBitwise(function_name, binary);
        if (try self.emitDirectBitwise(function_name, binary, op)) return;
        self.uses_math_tmp = true;
        try self.emitExprToAX(function_name, binary.lhs.*);
        try self.out.writer.writeAll("    pha\n    txa\n    pha\n");
        try self.emitExprToAX(function_name, binary.rhs.*);
        try self.out.writer.writeAll("    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n    pla\n    tax\n    pla\n");
        try self.emitBitwiseAccumulatorWithTmp(op, false);
        try self.out.writer.writeAll("    pha\n    txa\n");
        try self.emitBitwiseAccumulatorWithTmp(op, true);
        try self.out.writer.writeAll("    tax\n    pla\n");
    }

    fn emitBitNotToAX(self: *Emitter, function_name: []const u8, child: *ast.Expr) !void {
        try self.validateBitwiseUnary(function_name, child.*);
        const ty = try self.exprType(function_name, child.*);
        try self.emitExprToAX(function_name, child.*);
        if (isWordType(ty)) {
            try self.out.writer.writeAll("    eor #$ff\n    pha\n    txa\n    eor #$ff\n    tax\n    pla\n");
        } else {
            try self.out.writer.writeAll("    eor #$ff\n    ldx #0\n");
        }
    }

    fn prepareShiftCount(self: *Emitter, function_name: []const u8, count_expr: ast.Expr, op: ShiftOp) !?u16 {
        self.uses_shift = true;
        if (self.program.zeropage_module == null) {
            if (exprIntLiteral(count_expr)) |count| return count;
            self.shift_usage.dynamic(op);
        }
        try self.emitExprToA(function_name, count_expr);
        try self.out.writer.writeAll("    sta zeropage_shift_count\n");
        return null;
    }

    fn finishShift(self: *Emitter, op: ShiftOp, count: ?u16) !void {
        if (count) |literal| {
            try self.shift_usage.emitConstant(&self.out.writer, op, literal);
        } else try self.out.writer.print("    jsr {s}\n", .{shiftRoutineName(op)});
    }

    fn emitShiftToAX(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr, op: ShiftOp) !void {
        try self.validateShift(function_name, binary);
        try self.emitExprToAX(function_name, binary.lhs.*);
        if (self.program.zeropage_module == null) {
            if (exprIntLiteral(binary.rhs.*)) |count| {
                self.uses_shift = true;
                try self.finishShift(op, count);
                return;
            }
        }
        try self.out.writer.writeAll("    pha\n    txa\n    pha\n");
        const count = try self.prepareShiftCount(function_name, binary.rhs.*, op);
        try self.out.writer.writeAll("    pla\n    tax\n    pla\n");
        try self.finishShift(op, count);
    }

    fn emitBitwiseAccumulatorWithTmp(self: *Emitter, op: BitwiseOp, high: bool) !void {
        const suffix = if (high) "+1" else "";
        switch (op) {
            .bit_and => try self.out.writer.print("    and zeropage_math_tmp{s}\n", .{suffix}),
            .bit_or => try self.out.writer.print("    ora zeropage_math_tmp{s}\n", .{suffix}),
            .bit_xor => try self.out.writer.print("    eor zeropage_math_tmp{s}\n", .{suffix}),
        }
    }

    /// The selected fallthrough label must follow the emitted condition
    /// immediately. Only that nearby target uses relative branches; the other
    /// target uses JMP, so arbitrarily large RHS/statement bodies stay in range.
    fn emitConditionBranch(self: *Emitter, function_name: []const u8, expr: ast.Expr, yes: []const u8, no: []const u8, true_next: bool) anyerror!void {
        try self.expectBoolExpr(function_name, expr);
        const w = &self.out.writer;
        switch (expr) {
            .bool_and, .bool_or => |binary| {
                // Reserve the old materialization ID so later helper/source
                // labels retain their sequences. Scratch branches have their
                // own counter and namespace.
                _ = self.nextLabel();
                const id = self.condition_label_id;
                self.condition_label_id += 1;
                const rhs = try std.fmt.allocPrint(self.allocator, "zeropage_cond_{d}_rhs", .{id});
                defer self.allocator.free(rhs);
                if (expr == .bool_and) {
                    try self.emitConditionBranch(function_name, binary.lhs.*, rhs, no, true);
                } else {
                    try self.emitConditionBranch(function_name, binary.lhs.*, yes, rhs, false);
                }
                try w.print("{s}:\n", .{rhs});
                try self.emitConditionBranch(function_name, binary.rhs.*, yes, no, true_next);
            },
            .not => |child| {
                _ = self.nextLabel();
                try self.emitConditionBranch(function_name, child.*, no, yes, !true_next);
            },
            .eq, .ne, .lt, .lte, .gt, .gte => |binary| {
                const op: CompareOp = switch (expr) {
                    .eq => .eq,
                    .ne => .ne,
                    .lt => .lt,
                    .lte => .lte,
                    .gt => .gt,
                    .gte => .gte,
                    else => unreachable,
                };
                if ((op == .eq or op == .ne) and (exprIsNull(binary.lhs.*) or exprIsNull(binary.rhs.*))) {
                    // Optional presence uses its established storage/ABI path.
                    try self.emitExprToA(function_name, expr);
                    try w.writeAll("    cmp #0\n");
                    try self.emitConditionFlags(.ne, yes, no, true_next);
                    return;
                }
                try self.validateComparison(function_name, binary, op);
                _ = self.nextLabel();
                try self.emitComparisonFlags(function_name, binary);
                try self.emitConditionFlags(op, yes, no, true_next);
            },
            else => {
                try self.emitExprToA(function_name, expr);
                try w.writeAll("    cmp #0\n");
                try self.emitConditionFlags(.ne, yes, no, true_next);
            },
        }
    }

    fn emitConditionFlags(self: *Emitter, op: CompareOp, yes: []const u8, no: []const u8, true_next: bool) !void {
        const predicate: CompareOp = if (true_next) op else switch (op) {
            .eq => .ne,
            .ne => .eq,
            .lt => .gte,
            .lte => .gt,
            .gt => .lte,
            .gte => .lt,
        };
        const nearby = if (true_next) yes else no;
        const distant = if (true_next) no else yes;
        const w = &self.out.writer;
        switch (predicate) {
            .eq => try w.print("    beq {s}\n", .{nearby}),
            .ne => try w.print("    bne {s}\n", .{nearby}),
            .lt => try w.print("    bcc {s}\n", .{nearby}),
            .gte => try w.print("    bcs {s}\n", .{nearby}),
            .lte => try w.print("    beq {s}\n    bcc {s}\n", .{ nearby, nearby }),
            .gt => {
                const id = self.condition_label_id;
                self.condition_label_id += 1;
                try w.print("    beq zeropage_cond_{d}_reject\n    bcs {s}\nzeropage_cond_{d}_reject:\n", .{ id, nearby, id });
            },
        }
        try w.print("    jmp {s}\n", .{distant});
    }

    fn emitComparisonFlags(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr) !void {
        const w = &self.out.writer;
        if (try self.comparisonNeedsWord(function_name, binary)) {
            try self.emitWordCompare(function_name, binary);
        } else {
            const lhs_ty_maybe = self.exprType(function_name, binary.lhs.*) catch |err| switch (err) {
                error.UnsupportedEnumLiteral => null,
                else => return err,
            };
            const rhs_ty_maybe = self.exprType(function_name, binary.rhs.*) catch |err| switch (err) {
                error.UnsupportedEnumLiteral => null,
                else => return err,
            };
            const lhs_ty = if (lhs_ty_maybe) |ty|
                ty
            else if (rhs_ty_maybe) |ty|
                try self.exprTypeAllowContext(function_name, binary.lhs.*, ty)
            else
                return error.UnsupportedEnumLiteral;
            const rhs_ty = if (rhs_ty_maybe) |ty|
                ty
            else
                try self.exprTypeAllowContext(function_name, binary.rhs.*, lhs_ty);
            if (try self.directScalarOperand(function_name, binary.rhs.*, lhs_ty)) |operand| {
                // Evaluate the LHS first: a call may mutate the RHS static slot.
                try self.emitExprToAExpected(function_name, binary.lhs.*, rhs_ty);
                try self.emitDirectOperand(function_name, operand, false);
                return;
            }
            self.uses_math_tmp = true;
            try self.emitExprToAExpected(function_name, binary.lhs.*, rhs_ty);
            try w.writeAll("    pha\n");
            try self.emitExprToAExpected(function_name, binary.rhs.*, lhs_ty);
            try w.writeAll("    sta zeropage_math_tmp\n    pla\n    cmp zeropage_math_tmp\n");
        }
    }

    const DirectOperand = union(enum) {
        immediate: u16,
        slot: struct { name: []const u8, wide: bool },
    };

    fn directScalarOperand(self: *Emitter, function_name: []const u8, expr: ast.Expr, expected_ty: ast.Type) !?DirectOperand {
        // DLL operands require relocation anchors. Keep their established path.
        if (self.program.zeropage_module != null) return null;
        if (expr != .value) return null;
        return switch (expr.value) {
            .int => |n| .{ .immediate = @truncate(n) },
            .bool => |b| .{ .immediate = @intFromBool(b) },
            .char => |ch| .{ .immediate = screenCode(ch) },
            .enum_literal => |literal| .{ .immediate = try self.enumLiteralValue(expected_ty, literal) },
            .field => |field| if (self.program.findEnum(field.base) != null)
                .{ .immediate = try self.enumTagValue(field.base, field.field) }
            else
                null,
            .ident => |ident| blk: {
                const ty = (try self.expectBinding(function_name, ident)).ty;
                if (!isNumericScalarType(ty) and !isBoolType(ty) and !self.isEnumType(ty)) break :blk null;
                break :blk .{ .slot = .{ .name = ident, .wide = isWordType(ty) } };
            },
            .null => null,
        };
    }

    fn emitDirectOperand(self: *Emitter, function_name: []const u8, operand: DirectOperand, high: bool) !void {
        try self.emitDirectScalarInstruction(function_name, if (high) "cpx" else "cmp", operand, high);
    }

    fn emitDirectScalarInstruction(self: *Emitter, function_name: []const u8, mnemonic: []const u8, operand: DirectOperand, high: bool) !void {
        switch (operand) {
            .immediate => |n| try self.out.writer.print("    {s} #{d}\n", .{ mnemonic, @as(u8, @truncate(if (high) n >> 8 else n)) }),
            .slot => |slot| if (high and !slot.wide)
                try self.out.writer.print("    {s} #0\n", .{mnemonic})
            else
                try self.out.writer.print("    {s} {s}_{s}{s}\n", .{ mnemonic, function_name, slot.name, if (high) "+1" else "" }),
        }
    }

    fn emitCompareToA(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr, op: CompareOp) !void {
        const w = &self.out.writer;
        if (try self.emitOptionalNullCompareToA(function_name, binary, op)) return;
        try self.validateComparison(function_name, binary, op);
        const id = self.nextLabel();
        try self.emitComparisonFlags(function_name, binary);
        switch (op) {
            .eq => try w.print("    beq cmp_{d}_true\n", .{id}),
            .ne => try w.print("    bne cmp_{d}_true\n", .{id}),
            .lt => try w.print("    bcc cmp_{d}_true\n", .{id}),
            .lte => try w.print("    beq cmp_{d}_true\n    bcc cmp_{d}_true\n", .{ id, id }),
            .gt => try w.print("    bne cmp_{d}_maybe\n    jmp cmp_{d}_false\ncmp_{d}_maybe:\n    bcs cmp_{d}_true\n", .{ id, id, id, id }),
            .gte => try w.print("    bcs cmp_{d}_true\n", .{id}),
        }
        try w.print("cmp_{d}_false:\n    lda #0\n    jmp cmp_{d}_done\ncmp_{d}_true:\n    lda #1\ncmp_{d}_done:\n", .{ id, id, id, id });
    }

    fn emitOptionalNullCompareToA(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr, op: CompareOp) !bool {
        if (op != .eq and op != .ne) return false;
        const lhs_null = exprIsNull(binary.lhs.*);
        const rhs_null = exprIsNull(binary.rhs.*);
        if (!lhs_null and !rhs_null) return false;
        if (lhs_null and rhs_null) return error.UnsupportedOptional;
        const optional_expr = if (lhs_null) binary.rhs.* else binary.lhs.*;
        const optional_ty = try self.expectOptionalExpr(function_name, optional_expr);
        const id = self.nextLabel();
        try self.emitOptionalPresentToA(function_name, optional_expr, optional_ty);
        try self.out.writer.writeAll("    cmp #0\n");
        const true_on_null = (op == .eq);
        if (true_on_null) {
            try self.out.writer.print("    beq optional_cmp_{d}_true\n    jmp optional_cmp_{d}_false\n", .{ id, id });
        } else {
            try self.out.writer.print("    bne optional_cmp_{d}_true\n    jmp optional_cmp_{d}_false\n", .{ id, id });
        }
        try self.out.writer.print("optional_cmp_{d}_false:\n    lda #0\n    jmp optional_cmp_{d}_done\noptional_cmp_{d}_true:\n    lda #1\noptional_cmp_{d}_done:\n", .{ id, id, id, id });
        return true;
    }

    fn exprIsNull(expr: ast.Expr) bool {
        return switch (expr) {
            .value => |value| value == .null,
            else => false,
        };
    }

    fn emitLogicalToA(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr, op: LogicalOp) !void {
        const w = &self.out.writer;
        try self.expectBoolExpr(function_name, binary.lhs.*);
        try self.expectBoolExpr(function_name, binary.rhs.*);
        const id = self.nextLabel();
        switch (op) {
            .bool_and => {
                try self.emitExprToA(function_name, binary.lhs.*);
                try w.print("    cmp #0\n    bne bool_and_{d}_rhs\n    jmp bool_and_{d}_false\nbool_and_{d}_rhs:\n", .{ id, id, id });
                try self.emitExprToA(function_name, binary.rhs.*);
                try w.print("    cmp #0\n    bne bool_and_{d}_true\n    jmp bool_and_{d}_false\nbool_and_{d}_true:\n    lda #1\n    jmp bool_and_{d}_done\nbool_and_{d}_false:\n    lda #0\nbool_and_{d}_done:\n", .{ id, id, id, id, id, id });
            },
            .bool_or => {
                try self.emitExprToA(function_name, binary.lhs.*);
                try w.print("    cmp #0\n    beq bool_or_{d}_rhs\n    jmp bool_or_{d}_true\nbool_or_{d}_rhs:\n", .{ id, id, id });
                try self.emitExprToA(function_name, binary.rhs.*);
                try w.print("    cmp #0\n    beq bool_or_{d}_false\n    jmp bool_or_{d}_true\nbool_or_{d}_false:\n    lda #0\n    jmp bool_or_{d}_done\nbool_or_{d}_true:\n    lda #1\nbool_or_{d}_done:\n", .{ id, id, id, id, id, id });
            },
        }
    }

    fn emitIfExprToA(self: *Emitter, function_name: []const u8, if_expr: ast.IfExpr) anyerror!void {
        const w = &self.out.writer;
        const result_ty = try self.ifExprType(function_name, if_expr);
        const id = self.nextLabel();
        if (if_expr.payload_name) |payload_name| {
            const optional_ty = try self.expectOptionalExpr(function_name, if_expr.condition.*);
            try self.emitOptionalExprToTemp(function_name, if_expr.condition.*, optional_ty);
            try self.emitOptionalPresentFromLabelToA("zeropage_optional_tmp", optional_ty);
            try w.print("    cmp #0\n    beq if_expr_{d}_else\n", .{id});
            try self.emitOptionalPayloadFromLabelToSlot("zeropage_optional_tmp", optional_ty, function_name, payload_name);
        } else {
            try self.expectBoolExpr(function_name, if_expr.condition.*);
            try self.emitExprToA(function_name, if_expr.condition.*);
            try w.print("    cmp #0\n    beq if_expr_{d}_else\n", .{id});
        }
        try self.emitExprToAExpected(function_name, if_expr.then_expr.*, result_ty);
        try w.print("    jmp if_expr_{d}_done\nif_expr_{d}_else:\n", .{ id, id });
        try self.emitExprToAExpected(function_name, if_expr.else_expr.*, result_ty);
        try w.print("if_expr_{d}_done:\n", .{id});
    }

    fn emitIfExprToAExpected(self: *Emitter, function_name: []const u8, if_expr: ast.IfExpr, expected_ty: ast.Type) anyerror!void {
        const w = &self.out.writer;
        if (if_expr.payload_name == null) try self.expectBoolExpr(function_name, if_expr.condition.*);
        _ = try self.exprTypeAllowContext(function_name, if_expr.then_expr.*, expected_ty);
        _ = try self.exprTypeAllowContext(function_name, if_expr.else_expr.*, expected_ty);
        const id = self.nextLabel();
        if (if_expr.payload_name) |payload_name| {
            const optional_ty = try self.expectOptionalExpr(function_name, if_expr.condition.*);
            try self.emitOptionalExprToTemp(function_name, if_expr.condition.*, optional_ty);
            try self.emitOptionalPresentFromLabelToA("zeropage_optional_tmp", optional_ty);
            try w.print("    cmp #0\n    beq if_expr_{d}_else\n", .{id});
            try self.emitOptionalPayloadFromLabelToSlot("zeropage_optional_tmp", optional_ty, function_name, payload_name);
        } else {
            try self.emitExprToA(function_name, if_expr.condition.*);
            try w.print("    cmp #0\n    beq if_expr_{d}_else\n", .{id});
        }
        try self.emitExprToAExpected(function_name, if_expr.then_expr.*, expected_ty);
        try w.print("    jmp if_expr_{d}_done\nif_expr_{d}_else:\n", .{ id, id });
        try self.emitExprToAExpected(function_name, if_expr.else_expr.*, expected_ty);
        try w.print("if_expr_{d}_done:\n", .{id});
    }

    fn emitBlockExprToA(self: *Emitter, function_name: []const u8, block_expr: ast.BlockExpr) anyerror!void {
        const result_ty = try self.blockExprType(function_name, block_expr);
        if (isPointerType(result_ty) or isOptionalPointerType(result_ty)) try validatePointerValueOnlyBreaks(block_expr.body, block_expr.label);
        const id = self.nextLabel();
        try self.block_stack.append(self.allocator, .{ .label = block_expr.label, .id = id, .result_ty = result_ty });
        defer _ = self.block_stack.pop();
        try self.emitStmtList(function_name, block_expr.body);
        try self.out.writer.print("block_expr_{d}_done:\n", .{id});
    }

    fn emitBlockExprToAExpected(self: *Emitter, function_name: []const u8, block_expr: ast.BlockExpr, expected_ty: ast.Type) anyerror!void {
        _ = try self.blockExprTypeExpected(function_name, block_expr, expected_ty);
        if (isPointerType(expected_ty) or isOptionalPointerType(expected_ty)) try validatePointerValueOnlyBreaks(block_expr.body, block_expr.label);
        const id = self.nextLabel();
        try self.block_stack.append(self.allocator, .{ .label = block_expr.label, .id = id, .result_ty = expected_ty });
        defer _ = self.block_stack.pop();
        try self.emitStmtList(function_name, block_expr.body);
        try self.out.writer.print("block_expr_{d}_done:\n", .{id});
    }

    fn emitAddressOfToAX(self: *Emitter, function_name: []const u8, address: ast.AddressOf, expected_ty: ast.Type) !void {
        const target = try self.resolveAddressTarget(function_name, address);
        defer target.deinit(self.allocator);
        if (!typesEqual(expected_ty, target.pointer_ty)) return error.UnsupportedPointerTarget;
        const offset = target.offset;
        if (target.indirect) {
            self.uses_pointer = true;
            try self.out.writer.print("    lda {s}\n    sta zeropage_ptr_tmp\n    lda {s}+1\n    sta zeropage_ptr_tmp+1\n", .{ target.label, target.label });
            try self.emitAddConstantToPtrTmp(offset);
            try self.out.writer.writeAll("    ldx zeropage_ptr_tmp+1\n    lda zeropage_ptr_tmp\n");
        } else {
            try self.emitModuleRelocationAnchorKind(.hi8, target.label, @intCast(offset));
            try self.out.writer.print("    ldx #>{s}+{d}\n", .{ target.label, offset });
            try self.emitModuleRelocationAnchorKind(.lo8, target.label, @intCast(offset));
            try self.out.writer.print("    lda #<{s}+{d}\n", .{ target.label, offset });
        }
    }

    fn addressOfTargetsModuleRoData(self: *Emitter, address: ast.AddressOf) bool {
        const literal_index = address.index orelse return false;
        const constant = self.program.findArray(address.name) orelse return false;
        if (literal_index >= constant.ty.len) return false;
        const child_ty = arrayElemToType(constant.ty.elem);
        return !isArrayType(child_ty) and !self.isStructType(child_ty);
    }

    fn emitAddConstantToPtrTmp(self: *Emitter, offset: u16) !void {
        if (offset == 0) return;
        try self.out.writer.print(
            "    clc\n    lda zeropage_ptr_tmp\n    adc #{d}\n    sta zeropage_ptr_tmp\n    lda zeropage_ptr_tmp+1\n    adc #{d}\n    sta zeropage_ptr_tmp+1\n",
            .{ @as(u8, @truncate(offset)), @as(u8, @truncate(offset >> 8)) },
        );
    }

    fn optionalPayloadIsWide(optional: ast.OptionalType) bool {
        return isWideValueType(optionalPayloadType(optional));
    }

    fn optionalPayloadBytes(optional: ast.OptionalType) u8 {
        return switch (optional.child) {
            .pointer => 2,
            .far_bytes => 5,
            .near_view => 2,
            else => if (optionalPayloadIsWide(optional)) 2 else 1,
        };
    }

    fn optionalStorageBytes(optional: ast.OptionalType) u8 {
        return if (optional.child == .pointer) 2 else 1 + optionalPayloadBytes(optional);
    }

    fn expectOptionalExpr(self: *Emitter, function_name: []const u8, expr: ast.Expr) !ast.OptionalType {
        const ty = try self.exprType(function_name, expr);
        if (ty != .optional) return error.UnsupportedNonBoolCondition;
        _ = try self.validateOptionalType(ty.optional);
        return ty.optional;
    }

    fn optionalSlotLabel(self: *Emitter, function_name: []const u8, name: []const u8) ![]u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ function_name, name });
    }

    fn emitOptionalNullToStorage(self: *Emitter, dest_function: []const u8, dest_name: []const u8, optional: ast.OptionalType) !void {
        const label = try self.optionalSlotLabel(dest_function, dest_name);
        defer self.allocator.free(label);
        if (optional.child == .pointer) {
            try self.out.writer.print("    lda #0\n    sta {s}\n    sta {s}+1\n", .{ label, label });
        } else {
            const bytes = optionalStorageBytes(optional);
            try self.out.writer.print("    lda #0\n", .{});
            for (0..bytes) |offset| try self.out.writer.print("    sta {s}+{d}\n", .{ label, offset });
        }
    }

    fn emitCopyOptionalStorage(self: *Emitter, source_label: []const u8, dest_label: []const u8, optional: ast.OptionalType) !void {
        const bytes = optionalStorageBytes(optional);
        for (0..bytes) |offset| {
            try self.out.writer.print("    lda {s}+{d}\n    sta {s}+{d}\n", .{ source_label, offset, dest_label, offset });
        }
    }

    fn emitOptionalExprToStorage(self: *Emitter, function_name: []const u8, expr: ast.Expr, dest_function: []const u8, dest_name: []const u8, optional: ast.OptionalType) anyerror!void {
        _ = try self.validateOptionalType(optional);
        const dest_label = try self.optionalSlotLabel(dest_function, dest_name);
        defer self.allocator.free(dest_label);
        try self.emitOptionalExprToStorageByLabel(function_name, expr, dest_label, optional);
    }

    fn emitOptionalExprToStorageByLabel(self: *Emitter, function_name: []const u8, expr: ast.Expr, dest_label: []const u8, optional: ast.OptionalType) anyerror!void {
        _ = try self.validateOptionalType(optional);
        switch (expr) {
            .value => |value| switch (value) {
                .null => {
                    if (optional.child == .pointer) {
                        try self.out.writer.print("    lda #0\n    sta {s}\n    sta {s}+1\n", .{ dest_label, dest_label });
                    } else {
                        const bytes = optionalStorageBytes(optional);
                        try self.out.writer.print("    lda #0\n", .{});
                        for (0..bytes) |offset| try self.out.writer.print("    sta {s}+{d}\n", .{ dest_label, offset });
                    }
                    return;
                },
                .ident => |ident| {
                    const binding = self.findBinding(function_name, ident) catch |err| switch (err) {
                        error.UnknownVariable => null,
                        else => return err,
                    };
                    if (binding) |found| {
                        if (found.ty == .optional and optionalChildTypesEqual(found.ty.optional.child, optional.child)) {
                            const source_label = try self.optionalSlotLabel(function_name, ident);
                            defer self.allocator.free(source_label);
                            try self.emitCopyOptionalStorage(source_label, dest_label, optional);
                            return;
                        }
                    }
                },
                else => {},
            },
            .call => |call| {
                const callee = self.functionForCall(call) catch |err| switch (err) {
                    else => return err,
                };
                if (callee.return_type == .optional and optionalChildTypesEqual(callee.return_type.optional.child, optional.child)) {
                    try self.emitCall(function_name, call);
                    const source_label = try self.optionalSlotLabel(callee.name, "return");
                    defer self.allocator.free(source_label);
                    try self.emitCopyOptionalStorage(source_label, dest_label, optional);
                    return;
                }
            },
            .if_expr => |if_expr| {
                try self.emitOptionalIfExprToStorage(function_name, if_expr, dest_label, optional);
                return;
            },
            .reu_heap_alloc => |alloc| {
                if (optional.child != .far_bytes) return error.UnsupportedOptional;
                try self.emitReuHeapAlloc(function_name, alloc);
                try self.out.writer.print("    sta {s}\n", .{dest_label});
                for (0..5) |offset| {
                    try self.out.writer.print("    lda zeropage_reu_heap_result+{d}\n    sta {s}+{d}\n", .{ offset, dest_label, offset + 1 });
                }
                return;
            },
            .far_view_materialize => |mat| {
                if (optional.child != .near_view) return error.UnsupportedOptional;
                if (!typesEqual(optionalPayloadType(optional), .{ .near_view = try self.validateFarViewMaterialize(function_name, mat) })) return error.UnsupportedPointerType;
                try self.emitFarViewMaterializeToOptional(function_name, mat, dest_label);
                return;
            },
            .far_view_materialize_range => |range| {
                if (optional.child != .near_view) return error.UnsupportedOptional;
                if (!typesEqual(optionalPayloadType(optional), .{ .near_view = try self.validateFarViewMaterializeRange(function_name, range) })) return error.UnsupportedPointerType;
                try self.emitFarViewMaterializeRangeToOptional(function_name, range, dest_label);
                return;
            },
            .module_call => |module_call| {
                try self.emitModuleCallToOptional(function_name, module_call, dest_label, optional);
                return;
            },
            else => {},
        }
        if (optional.child == .pointer) {
            try self.emitExprToAXExpected(function_name, expr, optionalPayloadType(optional));
            try self.out.writer.print("    sta {s}\n    stx {s}+1\n", .{ dest_label, dest_label });
        } else {
            try self.out.writer.print("    lda #1\n    sta {s}\n", .{dest_label});
            const payload_ty = optionalPayloadType(optional);
            if (isWordType(payload_ty)) {
                try self.emitExprToAXExpected(function_name, expr, payload_ty);
                try self.out.writer.print("    sta {s}+1\n    stx {s}+2\n", .{ dest_label, dest_label });
            } else {
                try self.emitExprToAExpected(function_name, expr, payload_ty);
                try self.out.writer.print("    sta {s}+1\n", .{dest_label});
            }
        }
    }

    fn emitOptionalIfExprToStorage(self: *Emitter, function_name: []const u8, if_expr: ast.IfExpr, dest_label: []const u8, optional: ast.OptionalType) anyerror!void {
        const id = self.nextLabel();
        if (if_expr.payload_name) |payload_name| {
            const condition_optional = try self.expectOptionalExpr(function_name, if_expr.condition.*);
            try self.emitOptionalExprToTemp(function_name, if_expr.condition.*, condition_optional);
            try self.emitOptionalPresentFromLabelToA("zeropage_optional_tmp", condition_optional);
            try self.out.writer.print("    cmp #0\n    beq optional_if_{d}_else\n", .{id});
            try self.emitOptionalPayloadFromLabelToSlot("zeropage_optional_tmp", condition_optional, function_name, payload_name);
        } else {
            try self.expectBoolExpr(function_name, if_expr.condition.*);
            try self.emitExprToA(function_name, if_expr.condition.*);
            try self.out.writer.print("    cmp #0\n    beq optional_if_{d}_else\n", .{id});
        }
        try self.emitOptionalExprToStorageByLabel(function_name, if_expr.then_expr.*, dest_label, optional);
        try self.out.writer.print("    jmp optional_if_{d}_done\noptional_if_{d}_else:\n", .{ id, id });
        try self.emitOptionalExprToStorageByLabel(function_name, if_expr.else_expr.*, dest_label, optional);
        try self.out.writer.print("optional_if_{d}_done:\n", .{id});
    }

    fn emitOptionalPresentToA(self: *Emitter, function_name: []const u8, expr: ast.Expr, optional: ast.OptionalType) anyerror!void {
        _ = try self.validateOptionalType(optional);
        switch (expr) {
            .value => |value| switch (value) {
                .null => {
                    try self.out.writer.writeAll("    lda #0\n");
                    return;
                },
                .ident => |ident| {
                    const label = try self.optionalSlotLabel(function_name, ident);
                    defer self.allocator.free(label);
                    try self.emitOptionalPresentFromLabelToA(label, optional);
                    return;
                },
                else => {},
            },
            .call => |call| {
                const callee = try self.functionForCall(call);
                if (callee.return_type != .optional) return error.UnsupportedNonBoolCondition;
                try self.emitCall(function_name, call);
                const label = try self.optionalSlotLabel(callee.name, "return");
                defer self.allocator.free(label);
                try self.emitOptionalPresentFromLabelToA(label, optional);
                return;
            },
            .module_call => {
                try self.emitOptionalExprToTemp(function_name, expr, optional);
                try self.emitOptionalPresentFromLabelToA("zeropage_optional_tmp", optional);
                return;
            },
            else => {},
        }
        return error.UnsupportedNonBoolCondition;
    }

    fn emitOptionalExprToTemp(self: *Emitter, function_name: []const u8, expr: ast.Expr, optional: ast.OptionalType) anyerror!void {
        self.uses_optional_tmp = true;
        try self.emitOptionalExprToStorageByLabel(function_name, expr, "zeropage_optional_tmp", optional);
    }

    fn emitOptionalPresentFromLabelToA(self: *Emitter, label: []const u8, optional: ast.OptionalType) !void {
        if (optional.child == .pointer) {
            try self.out.writer.print("    lda {s}\n    ora {s}+1\n", .{ label, label });
        } else {
            try self.out.writer.print("    lda {s}\n", .{label});
        }
    }

    fn emitOptionalPayloadFromLabelToSlot(self: *Emitter, label: []const u8, optional: ast.OptionalType, dest_function: []const u8, dest_name: []const u8) anyerror!void {
        const dest_label = try self.optionalSlotLabel(dest_function, dest_name);
        defer self.allocator.free(dest_label);
        if (optional.child == .far_bytes or optional.child == .near_view) {
            const bytes: usize = if (optional.child == .far_bytes) 5 else 2;
            for (0..bytes) |offset| {
                try self.out.writer.print("    lda {s}+{d}\n    sta {s}+{d}\n", .{ label, offset + 1, dest_label, offset });
            }
            return;
        }
        try self.emitOptionalPayloadFromLabelToAOrAX(label, optional);
        if (optionalPayloadIsWide(optional)) {
            try self.out.writer.print("    sta {s}\n    stx {s}+1\n", .{ dest_label, dest_label });
        } else {
            try self.out.writer.print("    sta {s}\n", .{dest_label});
        }
    }

    fn emitOptionalPayloadToSlot(self: *Emitter, function_name: []const u8, expr: ast.Expr, optional: ast.OptionalType, dest_function: []const u8, dest_name: []const u8) anyerror!void {
        const dest_label = try self.optionalSlotLabel(dest_function, dest_name);
        defer self.allocator.free(dest_label);
        try self.emitOptionalPayloadToAOrAX(function_name, expr, optional);
        if (optionalPayloadIsWide(optional)) {
            try self.out.writer.print("    sta {s}\n    stx {s}+1\n", .{ dest_label, dest_label });
        } else {
            try self.out.writer.print("    sta {s}\n", .{dest_label});
        }
    }

    fn emitOptionalPayloadToAOrAX(self: *Emitter, function_name: []const u8, expr: ast.Expr, optional: ast.OptionalType) anyerror!void {
        switch (expr) {
            .value => |value| switch (value) {
                .ident => |ident| {
                    const label = try self.optionalSlotLabel(function_name, ident);
                    defer self.allocator.free(label);
                    try self.emitOptionalPayloadFromLabelToAOrAX(label, optional);
                    return;
                },
                else => {},
            },
            .call => |call| {
                const callee = try self.functionForCall(call);
                if (callee.return_type != .optional) return error.UnsupportedNonBoolCondition;
                try self.emitCall(function_name, call);
                const label = try self.optionalSlotLabel(callee.name, "return");
                defer self.allocator.free(label);
                try self.emitOptionalPayloadFromLabelToAOrAX(label, optional);
                return;
            },
            else => {},
        }
        return error.UnsupportedNonBoolCondition;
    }

    fn emitOptionalPayloadFromLabelToAOrAX(self: *Emitter, label: []const u8, optional: ast.OptionalType) !void {
        if (optional.child == .pointer) {
            try self.out.writer.print("    ldx {s}+1\n    lda {s}\n", .{ label, label });
        } else if (optionalPayloadIsWide(optional)) {
            try self.out.writer.print("    ldx {s}+2\n    lda {s}+1\n", .{ label, label });
        } else {
            try self.out.writer.print("    lda {s}+1\n", .{label});
        }
    }

    fn emitPointerStructPathAddressToTmp(self: *Emitter, path: PointerStructPath) !void {
        self.uses_pointer = true;
        try self.emitPointerStructBaseToTmp(path.pointer_label, null);
        try self.emitAddConstantToPtrTmp(path.offset);
    }

    fn emitPointerStructBaseToTmp(self: *Emitter, pointer_label: []const u8, read_bytes: ?u8) !void {
        self.uses_pointer = true;
        // Struct pointers are nonvolatile in the supported subset. This marker
        // identifies a typed read; it does not license arbitrary indirect loads.
        if (self.program.zeropage_module == null) {
            if (read_bytes) |width| try self.out.writer.print("    ; zeropage_pointer_read source={s} bytes={d}\n", .{ pointer_label, width });
        }
        try self.out.writer.print("    lda {s}\n    sta zeropage_ptr_tmp\n    lda {s}+1\n    sta zeropage_ptr_tmp+1\n", .{ pointer_label, pointer_label });
    }

    fn pointerStructScalarOffsetFitsY(path: PointerStructPath) bool {
        return if (isWideValueType(path.ty)) path.offset <= 254 else path.offset <= 255;
    }

    fn pointerStructArrayOffsetFitsY(path: PointerStructArrayPath) bool {
        const bytes = arrayStorageBytes(path.ty);
        if (bytes == 0) return path.offset <= 255;
        return path.offset <= 255 and path.offset + bytes - 1 <= 255;
    }

    fn emitPointerStructPathBaseAndY(self: *Emitter, path: PointerStructPath, read_bytes: ?u8) !bool {
        if (!pointerStructScalarOffsetFitsY(path)) return false;
        try self.emitPointerStructBaseToTmp(path.pointer_label, read_bytes);
        try self.out.writer.print("    ldy #{d}\n", .{path.offset});
        return true;
    }

    fn emitPointerStructArrayBaseAndY(self: *Emitter, function_name: []const u8, path: PointerStructArrayPath, index: ast.Expr, read_bytes: ?u8) !bool {
        if (!pointerStructArrayOffsetFitsY(path)) return false;
        try self.emitExprToA(function_name, index);
        if (arrayElemIsWord(path.ty.elem)) try self.out.writer.writeAll("    asl\n");
        if (path.offset != 0) {
            try self.out.writer.print("    clc\n    adc #{d}\n", .{path.offset});
        }
        try self.out.writer.writeAll("    tay\n");
        try self.emitPointerStructBaseToTmp(path.pointer_label, read_bytes);
        return true;
    }

    fn emitPointerStructArrayAddressToTmp(self: *Emitter, function_name: []const u8, path: PointerStructArrayPath, index: ast.Expr) !void {
        self.uses_pointer = true;
        try self.emitExprToAX(function_name, index);
        if (arrayElemIsWord(path.ty.elem)) {
            try self.out.writer.writeAll("    asl\n    sta zeropage_ptr_value\n    txa\n    rol\n    tax\n    lda zeropage_ptr_value\n");
        }
        try self.out.writer.writeAll("    sta zeropage_ptr_value\n    stx zeropage_ptr_value+1\n");
        try self.out.writer.print("    lda {s}\n    sta zeropage_ptr_tmp\n    lda {s}+1\n    sta zeropage_ptr_tmp+1\n", .{ path.pointer_label, path.pointer_label });
        try self.emitAddConstantToPtrTmp(path.offset);
        try self.out.writer.writeAll(
            "    clc\n    lda zeropage_ptr_tmp\n    adc zeropage_ptr_value\n    sta zeropage_ptr_tmp\n" ++
                "    lda zeropage_ptr_tmp+1\n    adc zeropage_ptr_value+1\n    sta zeropage_ptr_tmp+1\n",
        );
    }

    fn emitPointerStructPathToA(self: *Emitter, function_name: []const u8, flat_name: []const u8) !void {
        const path = (try self.resolvePointerStructPath(function_name, flat_name)) orelse return error.UnknownVariable;
        defer path.deinit(self.allocator);
        if (isArrayType(path.ty) or self.isStructType(path.ty)) return error.UnsupportedPointerTarget;
        if (!try self.emitPointerStructPathBaseAndY(path, 1)) {
            try self.emitPointerStructPathAddressToTmp(path);
            try self.out.writer.writeAll("    ldy #0\n");
        }
        try self.out.writer.writeAll("    lda (zeropage_ptr_tmp),y\n");
    }

    fn emitPointerStructPathToAX(self: *Emitter, function_name: []const u8, flat_name: []const u8) !void {
        const path = (try self.resolvePointerStructPath(function_name, flat_name)) orelse return error.UnknownVariable;
        defer path.deinit(self.allocator);
        if (isArrayType(path.ty) or self.isStructType(path.ty)) return error.UnsupportedPointerTarget;
        const y_ready = try self.emitPointerStructPathBaseAndY(path, if (isWideValueType(path.ty)) 2 else 1);
        if (!y_ready) {
            try self.emitPointerStructPathAddressToTmp(path);
            try self.out.writer.writeAll("    ldy #0\n");
        }
        if (isWideValueType(path.ty)) {
            try self.out.writer.writeAll("    lda (zeropage_ptr_tmp),y\n    pha\n    iny\n    lda (zeropage_ptr_tmp),y\n    tax\n    pla\n");
        } else {
            try self.out.writer.writeAll("    lda (zeropage_ptr_tmp),y\n    ldx #0\n");
        }
    }

    fn emitStorePointerStructPath(self: *Emitter, function_name: []const u8, flat_name: []const u8, value: ast.Expr) !void {
        const path = (try self.resolvePointerStructPath(function_name, flat_name)) orelse return error.UnknownVariable;
        defer path.deinit(self.allocator);
        if (isArrayType(path.ty) or self.isStructType(path.ty)) return error.UnsupportedPointerTarget;
        if (isWideValueType(path.ty)) {
            try self.emitTypedFieldValueToAX(function_name, value, path.ty);
        } else {
            try self.emitExprToAExpected(function_name, value, path.ty);
        }
        try self.emitStorePointerStructPathFromResult(function_name, flat_name, path.ty);
    }

    fn emitStorePointerStructPathFromResult(self: *Emitter, function_name: []const u8, flat_name: []const u8, ty: ast.Type) !void {
        const path = (try self.resolvePointerStructPath(function_name, flat_name)) orelse return error.UnknownVariable;
        defer path.deinit(self.allocator);
        if (!typesEqual(path.ty, ty)) return error.UnsupportedPointerTarget;
        if (isArrayType(path.ty) or self.isStructType(path.ty)) return error.UnsupportedPointerTarget;
        if (isWideValueType(path.ty)) {
            try self.out.writer.writeAll("    sta zeropage_ptr_value\n    stx zeropage_ptr_value+1\n");
        } else {
            try self.out.writer.writeAll("    sta zeropage_ptr_value\n");
        }
        const y_ready = try self.emitPointerStructPathBaseAndY(path, null);
        if (!y_ready) {
            try self.emitPointerStructPathAddressToTmp(path);
            try self.out.writer.writeAll("    ldy #0\n");
        }
        if (isWideValueType(path.ty)) {
            try self.out.writer.writeAll("    lda zeropage_ptr_value\n    sta (zeropage_ptr_tmp),y\n    iny\n    lda zeropage_ptr_value+1\n    sta (zeropage_ptr_tmp),y\n");
        } else {
            try self.out.writer.writeAll("    lda zeropage_ptr_value\n    sta (zeropage_ptr_tmp),y\n");
        }
    }

    fn emitDerefToA(self: *Emitter, function_name: []const u8, ptr_expr: ast.Expr) !void {
        const ptr_ty = try self.exprType(function_name, ptr_expr);
        if (ptr_ty != .pointer) return error.UnsupportedPointerTarget;
        _ = try self.validatePointerChildType(ptr_ty.pointer.child);
        self.uses_pointer = true;
        try self.emitExprToAXExpected(function_name, ptr_expr, ptr_ty);
        try self.out.writer.writeAll("    sta zeropage_ptr_tmp\n    stx zeropage_ptr_tmp+1\n    ldy #0\n    lda (zeropage_ptr_tmp),y\n");
    }

    fn emitDerefToAX(self: *Emitter, function_name: []const u8, ptr_expr: ast.Expr) !void {
        const ptr_ty = try self.exprType(function_name, ptr_expr);
        if (ptr_ty != .pointer) return error.UnsupportedPointerTarget;
        const child_ty = try self.validatePointerChildType(ptr_ty.pointer.child);
        if (!isWordType(child_ty)) {
            try self.emitDerefToA(function_name, ptr_expr);
            try self.out.writer.writeAll("    ldx #0\n");
            return;
        }
        self.uses_pointer = true;
        try self.emitExprToAXExpected(function_name, ptr_expr, ptr_ty);
        try self.out.writer.writeAll("    sta zeropage_ptr_tmp\n    stx zeropage_ptr_tmp+1\n    ldy #0\n    lda (zeropage_ptr_tmp),y\n    pha\n    iny\n    lda (zeropage_ptr_tmp),y\n    tax\n    pla\n");
    }

    fn emitPointerIndexAddressToTmp(self: *Emitter, function_name: []const u8, name: []const u8, index: ast.Expr, ptr_ty: ast.Type, child_ty: ast.Type) !void {
        self.uses_pointer = true;
        try self.emitExprToAXExpected(function_name, .{ .value = .{ .ident = name } }, ptr_ty);
        const hold_base = try self.indexNeedsPointerBaseHold(function_name, index);
        if (hold_base) try self.emitHoldWordResult() else try self.out.writer.writeAll("    sta zeropage_ptr_tmp\n    stx zeropage_ptr_tmp+1\n");
        try self.emitExprToAX(function_name, index);
        if (isWordType(child_ty)) {
            try self.out.writer.writeAll("    asl\n    sta zeropage_ptr_value\n    txa\n    rol\n    tax\n    lda zeropage_ptr_value\n");
        }
        try self.out.writer.writeAll("    sta zeropage_ptr_value\n    stx zeropage_ptr_value+1\n");
        if (hold_base) {
            try self.out.writer.writeAll("    pla\n    sta zeropage_ptr_tmp+1\n    pla\n    sta zeropage_ptr_tmp\n");
        }
        try self.out.writer.writeAll(
            "    clc\n    lda zeropage_ptr_tmp\n    adc zeropage_ptr_value\n    sta zeropage_ptr_tmp\n" ++
                "    lda zeropage_ptr_tmp+1\n    adc zeropage_ptr_value+1\n    sta zeropage_ptr_tmp+1\n",
        );
    }

    fn emitPointerIndexToA(self: *Emitter, function_name: []const u8, index: ast.ArrayIndex) !void {
        const resolved = try self.expectManyPointerIndex(function_name, index.name, index.index.*);
        try self.emitPointerIndexAddressToTmp(function_name, index.name, index.index.*, resolved.ptr_ty, resolved.child_ty);
        try self.out.writer.writeAll("    ldy #0\n    lda (zeropage_ptr_tmp),y\n");
    }

    fn emitPointerIndexToAX(self: *Emitter, function_name: []const u8, index: ast.ArrayIndex) !void {
        const resolved = try self.expectManyPointerIndex(function_name, index.name, index.index.*);
        if (!isWordType(resolved.child_ty)) {
            try self.emitPointerIndexToA(function_name, index);
            try self.out.writer.writeAll("    ldx #0\n");
            return;
        }
        try self.emitPointerIndexAddressToTmp(function_name, index.name, index.index.*, resolved.ptr_ty, resolved.child_ty);
        try self.out.writer.writeAll("    ldy #0\n    lda (zeropage_ptr_tmp),y\n    pha\n    iny\n    lda (zeropage_ptr_tmp),y\n    tax\n    pla\n");
    }

    fn emitPointerStructArrayIndexToA(self: *Emitter, function_name: []const u8, index: ast.ArrayIndex) !void {
        const path = (try self.resolvePointerStructArrayPath(function_name, index.name)) orelse return error.UnknownVariable;
        defer path.deinit(self.allocator);
        try self.validateArrayIndexLiteral(path.ty, index.index.*);
        if (!try self.emitPointerStructArrayBaseAndY(function_name, path, index.index.*, 1)) {
            try self.emitPointerStructArrayAddressToTmp(function_name, path, index.index.*);
            try self.out.writer.writeAll("    ldy #0\n");
        }
        try self.out.writer.writeAll("    lda (zeropage_ptr_tmp),y\n");
    }

    fn emitPointerStructArrayIndexToAX(self: *Emitter, function_name: []const u8, index: ast.ArrayIndex) !void {
        const path = (try self.resolvePointerStructArrayPath(function_name, index.name)) orelse return error.UnknownVariable;
        defer path.deinit(self.allocator);
        try self.validateArrayIndexLiteral(path.ty, index.index.*);
        if (!arrayElemIsWord(path.ty.elem)) {
            try self.emitPointerStructArrayIndexToA(function_name, index);
            try self.out.writer.writeAll("    ldx #0\n");
            return;
        }
        if (!try self.emitPointerStructArrayBaseAndY(function_name, path, index.index.*, 2)) {
            try self.emitPointerStructArrayAddressToTmp(function_name, path, index.index.*);
            try self.out.writer.writeAll("    ldy #0\n");
        }
        try self.out.writer.writeAll("    lda (zeropage_ptr_tmp),y\n    pha\n    iny\n    lda (zeropage_ptr_tmp),y\n    tax\n    pla\n");
    }

    fn emitStorePointerStructArrayElement(self: *Emitter, function_name: []const u8, assign: ast.ArrayAssign, elem_ty: ast.Type) !void {
        if (isWordType(elem_ty)) {
            try self.emitExprToAXExpected(function_name, assign.value, elem_ty);
        } else {
            try self.emitExprToAExpected(function_name, assign.value, elem_ty);
        }
        try self.emitStorePointerStructArrayElementFromResult(function_name, assign.name, assign.index, elem_ty);
    }

    fn emitStorePointerStructArrayElementFromResult(self: *Emitter, function_name: []const u8, name: []const u8, index: ast.Expr, elem_ty: ast.Type) !void {
        const path = (try self.resolvePointerStructArrayPath(function_name, name)) orelse return error.UnknownVariable;
        defer path.deinit(self.allocator);
        if (!typesEqual(elem_ty, arrayElemToType(path.ty.elem))) return error.UnsupportedPointerTarget;
        if (isWordType(elem_ty) and try self.indexNeedsWordHold(function_name, index)) {
            try self.validateArrayIndexLiteral(path.ty, index);
            try self.emitHoldWordResult();
            if (!try self.emitPointerStructArrayBaseAndY(function_name, path, index, null)) {
                try self.emitPointerStructArrayAddressToTmp(function_name, path, index);
                try self.out.writer.writeAll("    ldy #0\n");
            }
            try self.emitRestoreWordResult();
            try self.out.writer.writeAll("    sta (zeropage_ptr_tmp),y\n    iny\n    txa\n    sta (zeropage_ptr_tmp),y\n");
            return;
        }
        if (isWordType(elem_ty)) {
            self.uses_math_tmp = true;
            try self.out.writer.writeAll("    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n");
        } else {
            try self.out.writer.writeAll("    pha\n");
        }
        try self.validateArrayIndexLiteral(path.ty, index);
        const y_ready = try self.emitPointerStructArrayBaseAndY(function_name, path, index, null);
        if (!y_ready) {
            try self.emitPointerStructArrayAddressToTmp(function_name, path, index);
            try self.out.writer.writeAll("    ldy #0\n");
        }
        if (isWordType(elem_ty)) {
            try self.out.writer.writeAll("    lda zeropage_math_tmp\n    sta (zeropage_ptr_tmp),y\n    iny\n    lda zeropage_math_tmp+1\n    sta (zeropage_ptr_tmp),y\n");
        } else {
            try self.out.writer.writeAll("    pla\n    sta (zeropage_ptr_tmp),y\n");
        }
    }

    fn emitStorePointerIndexElement(self: *Emitter, function_name: []const u8, assign: ast.ArrayAssign, elem_ty: ast.Type) !void {
        try self.validatePointerElementValue(function_name, elem_ty, assign.value);
        if (isWordType(elem_ty)) {
            try self.emitExprToAXExpected(function_name, assign.value, elem_ty);
        } else {
            try self.emitExprToAExpected(function_name, assign.value, elem_ty);
        }
        try self.emitStorePointerIndexElementFromResult(function_name, assign.name, assign.index, elem_ty);
    }

    fn emitStorePointerIndexElementFromResult(self: *Emitter, function_name: []const u8, name: []const u8, index: ast.Expr, elem_ty: ast.Type) !void {
        const resolved = try self.expectManyPointerIndex(function_name, name, index);
        if (!typesEqual(elem_ty, resolved.child_ty)) return error.UnsupportedPointerTarget;
        if (isWordType(elem_ty) and try self.indexNeedsWordHold(function_name, index)) {
            try self.emitHoldWordResult();
            try self.emitPointerIndexAddressToTmp(function_name, name, index, resolved.ptr_ty, resolved.child_ty);
            try self.out.writer.writeAll("    ldy #0\n");
            try self.emitRestoreWordResult();
            try self.out.writer.writeAll("    sta (zeropage_ptr_tmp),y\n    iny\n    txa\n    sta (zeropage_ptr_tmp),y\n");
            return;
        }
        if (isWordType(elem_ty)) {
            self.uses_math_tmp = true;
            try self.out.writer.writeAll("    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n");
        } else {
            try self.out.writer.writeAll("    pha\n");
        }
        try self.emitPointerIndexAddressToTmp(function_name, name, index, resolved.ptr_ty, resolved.child_ty);
        if (isWordType(elem_ty)) {
            try self.out.writer.writeAll("    ldy #0\n    lda zeropage_math_tmp\n    sta (zeropage_ptr_tmp),y\n    iny\n    lda zeropage_math_tmp+1\n    sta (zeropage_ptr_tmp),y\n");
        } else {
            try self.out.writer.writeAll("    ldy #0\n    pla\n    sta (zeropage_ptr_tmp),y\n");
        }
    }

    pub fn emitExprToAX(self: *Emitter, function_name: []const u8, expr: ast.Expr) anyerror!void {
        const w = &self.out.writer;
        switch (expr) {
            .value => |value| try self.emitValueToAX(function_name, value),
            .add => |add| {
                try self.validateAddSub(function_name, add);
                if (try self.emitImmediateBinaryMath(function_name, add, .add, true)) return;
                if (try self.emitDirectBinaryMath(function_name, add, .add, true)) return;
                self.uses_math_tmp = true;
                try self.emitExprToAX(function_name, add.lhs.*);
                try w.writeAll("    pha\n    txa\n    pha\n");
                try self.emitExprToAX(function_name, add.rhs.*);
                try w.writeAll("    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n    pla\n    tax\n    pla\n");
                try w.writeAll(
                    \\    clc
                    \\    adc zeropage_math_tmp
                    \\    sta zeropage_math_tmp
                    \\    txa
                    \\    adc zeropage_math_tmp+1
                    \\    tax
                    \\    lda zeropage_math_tmp
                    \\
                );
            },
            .mul => |mul| try self.emitMulToAX(function_name, mul),
            .bit_and => |bit_and| try self.emitBitwiseToAX(function_name, bit_and, .bit_and),
            .bit_or => |bit_or| try self.emitBitwiseToAX(function_name, bit_or, .bit_or),
            .bit_xor => |bit_xor| try self.emitBitwiseToAX(function_name, bit_xor, .bit_xor),
            .shl => |shl| try self.emitShiftToAX(function_name, shl, .shl),
            .shr => |shr| try self.emitShiftToAX(function_name, shr, .shr),
            .sub => |sub| {
                try self.validateAddSub(function_name, sub);
                if (try self.emitImmediateBinaryMath(function_name, sub, .sub, true)) return;
                if (try self.emitDirectBinaryMath(function_name, sub, .sub, true)) return;
                self.uses_math_tmp = true;
                try self.emitExprToAX(function_name, sub.lhs.*);
                try w.writeAll("    pha\n    txa\n    pha\n");
                try self.emitExprToAX(function_name, sub.rhs.*);
                try w.writeAll("    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n    pla\n    tax\n    pla\n");
                try w.writeAll(
                    \\    sec
                    \\    sbc zeropage_math_tmp
                    \\    sta zeropage_math_tmp
                    \\    txa
                    \\    sbc zeropage_math_tmp+1
                    \\    tax
                    \\    lda zeropage_math_tmp
                    \\
                );
            },
            .eq => |eq| {
                try self.emitExprToA(function_name, .{ .eq = eq });
                try w.writeAll("    ldx #0\n");
            },
            .ne => |ne| {
                try self.emitExprToA(function_name, .{ .ne = ne });
                try w.writeAll("    ldx #0\n");
            },
            .lt => |lt| {
                try self.emitExprToA(function_name, .{ .lt = lt });
                try w.writeAll("    ldx #0\n");
            },
            .lte => |lte| {
                try self.emitExprToA(function_name, .{ .lte = lte });
                try w.writeAll("    ldx #0\n");
            },
            .gt => |gt| {
                try self.emitExprToA(function_name, .{ .gt = gt });
                try w.writeAll("    ldx #0\n");
            },
            .gte => |gte| {
                try self.emitExprToA(function_name, .{ .gte = gte });
                try w.writeAll("    ldx #0\n");
            },
            .bool_and => |and_expr| {
                try self.emitExprToA(function_name, .{ .bool_and = and_expr });
                try w.writeAll("    ldx #0\n");
            },
            .bool_or => |or_expr| {
                try self.emitExprToA(function_name, .{ .bool_or = or_expr });
                try w.writeAll("    ldx #0\n");
            },
            .not => |child| {
                try self.emitExprToA(function_name, .{ .not = child });
                try w.writeAll("    ldx #0\n");
            },
            .bit_not => |child| try self.emitBitNotToAX(function_name, child),
            .c64_read_petscii => {
                try self.emitKeyboardReadPetscii();
                try w.writeAll("    ldx #0\n");
            },
            .c64_wait_petscii => {
                try self.emitKeyboardWaitPetscii();
                try w.writeAll("    ldx #0\n");
            },
            .reu_present => {
                try self.emitReuPresent();
                try w.writeAll("    ldx #0\n");
            },
            .reu_compare => |transfer| {
                try self.emitReuCompare(function_name, transfer);
                try w.writeAll("    ldx #0\n");
            },
            .reu_heap_alloc => return error.UnsupportedOptional,
            .reu_view => return error.UnsupportedPointerType,
            .far_view_materialize => return error.UnsupportedOptional,
            .far_view_materialize_range => return error.UnsupportedOptional,
            .module_load => |load| {
                try self.emitModuleLoad(load);
                try w.writeAll("    ldx #0\n");
            },
            .module_disk_load => |load| {
                try self.emitModuleDiskLoad(load);
                try w.writeAll("    ldx #0\n");
            },
            .module_load_dependency => |load| {
                try self.emitModuleDependencyLoad(load);
                try w.writeAll("    ldx #0\n");
            },
            .module_acquire_dependency => |load| {
                try self.emitModuleDependencyAcquire(load);
                try w.writeAll("    ldx #0\n");
            },
            .module_load_dependency_graph => |load| {
                try self.emitModuleDependencyGraphLoad(load);
                try w.writeAll("    ldx #0\n");
            },
            .module_acquire_dependency_graph => |load| {
                try self.emitModuleDependencyGraphAcquire(load);
                try w.writeAll("    ldx #0\n");
            },
            .module_is_loaded => |load| {
                try self.emitModuleIsLoaded(load);
                try w.writeAll("    ldx #0\n");
            },
            .module_call => return error.UnsupportedOptional,
            .heap_alloc => |alloc| try self.emitHeapAllocToAX(function_name, alloc),
            .size_of, .align_of, .offset_of => {
                const value = try self.layoutComptimeValue(expr);
                try w.print("    ldx #${x:0>2}\n    lda #${x:0>2}\n", .{ @as(u8, @truncate(value >> 8)), @as(u8, @truncate(value)) });
            },
            .address_of => |address| try self.emitAddressOfToAX(function_name, address, try self.exprType(function_name, .{ .address_of = address })),
            .ptr_from_int => return error.UnsupportedPointerCast,
            .int_from_ptr => |child| {
                const ptr_ty = try self.exprType(function_name, child.*);
                if (ptr_ty != .pointer) return error.UnsupportedPointerCast;
                try self.emitExprToAXExpected(function_name, child.*, ptr_ty);
            },
            .as_cast => |as_cast| {
                _ = try self.validateAsCast(function_name, as_cast);
                if (isWideValueType(as_cast.ty)) {
                    try self.emitExprToAXExpected(function_name, as_cast.expr.*, as_cast.ty);
                } else {
                    try self.emitExprToAExpected(function_name, as_cast.expr.*, as_cast.ty);
                    try self.out.writer.writeAll("    ldx #0\n");
                }
            },
            .deref => |child| try self.emitDerefToAX(function_name, child.*),
            .if_expr => |if_expr| try self.emitIfExprToAX(function_name, if_expr),
            .switch_expr => |switch_expr| try self.emitSwitchExprToAX(function_name, switch_expr),
            .block_expr => |block_expr| try self.emitBlockExprToAX(function_name, block_expr),
            .call => |call| {
                try self.emitCall(function_name, call);
                // Byte-return ABI leaves X unconstrained. Widening needs zero,
                // just as loading an ordinary byte binding into A/X does.
                if (!isWideValueType(try self.exprType(function_name, expr))) try w.writeAll("    ldx #0\n");
            },
            .array_index => |index| try self.emitArrayIndexToAXOwned(function_name, index),
            .array_field_index => |index| try self.emitArrayFieldIndexToAXOwned(function_name, index),
            .array_literal => return error.UnsupportedArrayByValue,
            .struct_literal => return error.UnsupportedStruct,
        }
    }

    fn emitIfExprToAX(self: *Emitter, function_name: []const u8, if_expr: ast.IfExpr) anyerror!void {
        const w = &self.out.writer;
        _ = try self.ifExprType(function_name, if_expr);
        const id = self.nextLabel();
        if (if_expr.payload_name) |payload_name| {
            const optional_ty = try self.expectOptionalExpr(function_name, if_expr.condition.*);
            try self.emitOptionalExprToTemp(function_name, if_expr.condition.*, optional_ty);
            try self.emitOptionalPresentFromLabelToA("zeropage_optional_tmp", optional_ty);
            try w.print("    cmp #0\n    beq if_expr_{d}_else\n", .{id});
            try self.emitOptionalPayloadFromLabelToSlot("zeropage_optional_tmp", optional_ty, function_name, payload_name);
        } else {
            try self.expectBoolExpr(function_name, if_expr.condition.*);
            try self.emitExprToA(function_name, if_expr.condition.*);
            try w.print("    cmp #0\n    beq if_expr_{d}_else\n", .{id});
        }
        try self.emitExprToAX(function_name, if_expr.then_expr.*);
        try w.print("    jmp if_expr_{d}_done\nif_expr_{d}_else:\n", .{ id, id });
        try self.emitExprToAX(function_name, if_expr.else_expr.*);
        try w.print("if_expr_{d}_done:\n", .{id});
    }

    fn emitBlockExprToAX(self: *Emitter, function_name: []const u8, block_expr: ast.BlockExpr) anyerror!void {
        const result_ty = try self.blockExprType(function_name, block_expr);
        if (isPointerType(result_ty) or isOptionalPointerType(result_ty)) try validatePointerValueOnlyBreaks(block_expr.body, block_expr.label);
        const id = self.nextLabel();
        try self.block_stack.append(self.allocator, .{ .label = block_expr.label, .id = id, .result_ty = result_ty });
        defer _ = self.block_stack.pop();
        try self.emitStmtList(function_name, block_expr.body);
        try self.out.writer.print("block_expr_{d}_done:\n", .{id});
        if (!isWideValueType(result_ty)) try self.out.writer.writeAll("    ldx #0\n");
    }

    fn simpleSwitchConstant(self: *Emitter, expr: ast.Expr) bool {
        return switch (expr) {
            .value => |value| switch (value) {
                .int, .bool, .char, .enum_literal => true,
                .field => |field| self.program.findEnum(field.base) != null,
                else => false,
            },
            .as_cast => |cast| self.simpleSwitchConstant(cast.expr.*),
            else => false,
        };
    }

    // Reuse ordinary constant lowering for type/cast/enum diagnostics. These
    // shapes allocate no source labels and cannot mutate runtime-use flags.
    fn switchConstant(self: *Emitter, function_name: []const u8, expr: ast.Expr, ty: ast.Type) !?struct { value: u16, bytes: u32 } {
        if (!self.simpleSwitchConstant(expr)) return null;
        const saved = self.out;
        self.out = .init(self.allocator);
        defer {
            self.out.deinit();
            self.out = saved;
        }
        const wide = isWordType(ty);
        if (wide) try self.emitExprToAX(function_name, expr) else try self.emitExprToAExpected(function_name, expr, ty);
        var lo: ?u8 = null;
        var hi: ?u8 = if (wide) null else 0;
        var bytes: u32 = 0;
        var lines = std.mem.tokenizeScalar(u8, self.out.written(), '\n');
        while (lines.next()) |line| {
            const inst = machine.Instruction.parse(line) orelse return null;
            if (inst.operand != .immediate) return null;
            const value = machine.integer(inst.operand.immediate) orelse return null;
            if (value > 255) return null;
            if (inst.op == .lda) lo = @intCast(value) else if (inst.op == .ldx) hi = @intCast(value) else return null;
            bytes += 2;
        }
        if (lo == null or hi == null) return null;
        return .{ .value = @as(u16, lo.?) | (@as(u16, hi.?) << 8), .bytes = bytes };
    }

    fn emitConstantResultSwitch(self: *Emitter, function_name: []const u8, expression: ast.SwitchExpr, result_ty: ast.Type, id: usize) anyerror!bool {
        if (self.program.zeropage_module != null or self.switch_dispatch_pinned) return false;
        const operand_ty = try self.exprType(function_name, expression.operand.*);
        if (!isScalarSwitchType(operand_ty) or (operand_ty == .custom and !self.isEnumType(operand_ty))) return false;
        if (!isNumericScalarType(result_ty) and !isBoolType(result_ty) and !self.isEnumType(result_ty)) return false;
        try self.validateSwitchProngs(function_name, operand_ty, null, expression.prongs);
        var intervals: std.ArrayList(switch_lookup.Interval) = .empty;
        defer intervals.deinit(self.allocator);
        var fallback: ?u16 = null;
        var legacy: u32 = if (isWordType(operand_ty)) 4 else 6;
        legacy += 3; // final default dispatch
        for (expression.prongs) |prong| {
            if (prong.payload_name != null) return false;
            _ = try self.exprTypeAllowContext(function_name, prong.value, result_ty);
            const constant = (try self.switchConstant(function_name, prong.value, result_ty)) orelse return false;
            legacy += constant.bytes + 3;
            for (prong.selectors) |selector| switch (selector) {
                .else_prong => fallback = constant.value,
                .scalar => |value| {
                    const key = try self.validateSwitchSelectorValue(operand_ty, value);
                    try intervals.append(self.allocator, .{ .first = key, .last = key, .value = constant.value });
                    legacy += if (isWordType(operand_ty)) @as(u32, 15) else 6;
                },
                .range => |range| {
                    const first = try switchSelectorLiteral(range.first);
                    const last = try switchSelectorLiteral(range.last);
                    try intervals.append(self.allocator, .{ .first = first, .last = last, .value = constant.value });
                    legacy += if (isWordType(operand_ty)) @as(u32, 36) else 12;
                },
            };
        }
        const default = fallback orelse return false;
        const selector_value = try self.switchConstant(function_name, expression.operand.*, operand_ty);
        const plan = switch_lookup.chooseWithLayout(intervals.items, default, isWordType(operand_ty), isWordType(result_ty), legacy, if (selector_value) |value| value.value else null, self.program.zeropage_options.image.entry_addr >= 0x0200) orelse return false;
        // Exactly one selector evaluation; no subtraction, so decimal mode
        // cannot change the table index. Absolute operands are biased instead.
        if (isWordType(operand_ty)) try self.emitExprToAX(function_name, expression.operand.*) else try self.emitExprToA(function_name, expression.operand.*);
        try self.out.writer.writeAll("    ; switch dispatch/case anchors coalesced by constant-result optimization\n");
        for (expression.prongs, 0..) |prong, prong_index| {
            if (prongHasElse(prong.selectors)) continue;
            for (prong.selectors, 0..) |selector, selector_index| {
                if (selector == .range) {
                    try self.out.writer.print("switch_expr_{d}_test_{d}_{d}_next_low_ok:\n", .{ id, prong_index, selector_index });
                    if (isWordType(operand_ty)) try self.out.writer.print("switch_expr_{d}_test_{d}_{d}_next_high_check:\n", .{ id, prong_index, selector_index });
                }
                try self.out.writer.print("switch_expr_{d}_test_{d}_{d}_next:\n", .{ id, prong_index, selector_index });
            }
        }
        for (expression.prongs, 0..) |_, prong_index| try self.out.writer.print("switch_expr_{d}_case_{d}:\n", .{ id, prong_index });
        try switch_lookup.emitCode(&self.out.writer, plan, id);
        if (plan.kind == .lookup) try self.switch_tables.append(self.allocator, .{ .id = id, .plan = plan });
        return true;
    }

    fn emitSwitchExprToA(self: *Emitter, function_name: []const u8, switch_expr: ast.SwitchExpr) anyerror!void {
        const result_ty = try self.switchExprType(function_name, switch_expr);
        const id = self.nextLabel();
        if (try self.emitConstantResultSwitch(function_name, switch_expr, result_ty, id)) return;
        const operand_ty = try self.prepareSwitchOperand(function_name, switch_expr.operand.*);
        try self.validateSwitchProngs(function_name, operand_ty, null, switch_expr.prongs);
        const else_index = switchExprElseIndex(switch_expr.prongs);
        for (switch_expr.prongs, 0..) |prong, prong_index| {
            if (prongHasElse(prong.selectors)) continue;
            try self.emitSwitchSelectorTests("switch_expr", operand_ty, prong.selectors, id, prong_index);
        }
        if (else_index) |index| {
            try self.out.writer.print("    jmp switch_expr_{d}_case_{d}\n", .{ id, index });
        } else {
            try self.out.writer.print("    jmp switch_expr_{d}_done\n", .{id});
        }
        for (switch_expr.prongs, 0..) |prong, prong_index| {
            try self.out.writer.print("switch_expr_{d}_case_{d}:\n", .{ id, prong_index });
            if (prong.payload_name) |payload_name| try self.emitSwitchPayloadToSlot(function_name, payload_name, operand_ty, prong.selectors);
            if (isWideValueType(result_ty)) {
                try self.emitExprToAX(function_name, prong.value);
            } else {
                try self.emitExprToAExpected(function_name, prong.value, result_ty);
            }
            try self.out.writer.print("    jmp switch_expr_{d}_done\n", .{id});
        }
        try self.out.writer.print("switch_expr_{d}_done:\n", .{id});
    }

    fn emitSwitchExprToAExpected(self: *Emitter, function_name: []const u8, switch_expr: ast.SwitchExpr, expected_ty: ast.Type) anyerror!void {
        const id = self.nextLabel();
        if (try self.emitConstantResultSwitch(function_name, switch_expr, expected_ty, id)) return;
        const operand_ty = try self.prepareSwitchOperand(function_name, switch_expr.operand.*);
        try self.validateSwitchProngs(function_name, operand_ty, null, switch_expr.prongs);
        for (switch_expr.prongs) |prong| _ = try self.exprTypeAllowContext(function_name, prong.value, expected_ty);
        const else_index = switchExprElseIndex(switch_expr.prongs);
        for (switch_expr.prongs, 0..) |prong, prong_index| {
            if (prongHasElse(prong.selectors)) continue;
            try self.emitSwitchSelectorTests("switch_expr", operand_ty, prong.selectors, id, prong_index);
        }
        if (else_index) |index| {
            try self.out.writer.print("    jmp switch_expr_{d}_case_{d}\n", .{ id, index });
        } else {
            try self.out.writer.print("    jmp switch_expr_{d}_done\n", .{id});
        }
        for (switch_expr.prongs, 0..) |prong, prong_index| {
            try self.out.writer.print("switch_expr_{d}_case_{d}:\n", .{ id, prong_index });
            if (prong.payload_name) |payload_name| try self.emitSwitchPayloadToSlot(function_name, payload_name, operand_ty, prong.selectors);
            if (isWideValueType(expected_ty)) {
                try self.emitExprToAX(function_name, prong.value);
            } else {
                try self.emitExprToAExpected(function_name, prong.value, expected_ty);
            }
            try self.out.writer.print("    jmp switch_expr_{d}_done\n", .{id});
        }
        try self.out.writer.print("switch_expr_{d}_done:\n", .{id});
    }

    fn emitSwitchExprToAX(self: *Emitter, function_name: []const u8, switch_expr: ast.SwitchExpr) anyerror!void {
        const result_ty = try self.switchExprType(function_name, switch_expr);
        try self.emitSwitchExprToA(function_name, switch_expr);
        if (!isWideValueType(result_ty)) try self.out.writer.writeAll("    ldx #0\n");
    }

    fn emitSwitchSelectorTests(self: *Emitter, prefix: []const u8, operand_ty: ast.Type, selectors: []const ast.SwitchSelector, switch_id: usize, prong_index: usize) !void {
        for (selectors, 0..) |selector, selector_index| {
            const next_label = try std.fmt.allocPrint(self.allocator, "{s}_{d}_test_{d}_{d}_next", .{ prefix, switch_id, prong_index, selector_index });
            defer self.allocator.free(next_label);
            const target_label = try std.fmt.allocPrint(self.allocator, "{s}_{d}_case_{d}", .{ prefix, switch_id, prong_index });
            defer self.allocator.free(target_label);
            switch (selector) {
                .scalar => |value| try self.emitSwitchScalarTest(operand_ty, value, next_label, target_label),
                .range => |range| try self.emitSwitchRangeTest(operand_ty, range, next_label, target_label),
                .else_prong => {},
            }
            try self.out.writer.print("{s}:\n", .{next_label});
        }
    }

    fn emitSwitchScalarTest(self: *Emitter, operand_ty: ast.Type, value: ast.Value, next_label: []const u8, target_label: []const u8) !void {
        if (operand_ty == .optional) {
            if (value != .null) return error.UnsupportedSwitchSelector;
            try self.out.writer.print(
                "    lda zeropage_switch_value\n    cmp #0\n    beq {s}\n",
                .{target_label},
            );
            return;
        }
        const literal = try self.validateSwitchSelectorValue(operand_ty, value);
        if (isWordType(operand_ty)) {
            try self.out.writer.print(
                "    lda zeropage_switch_value+1\n    cmp #{d}\n    bne {s}\n    lda zeropage_switch_value\n    cmp #{d}\n    beq {s}\n    jmp {s}\n",
                .{ @as(u8, @truncate(literal >> 8)), next_label, @as(u8, @truncate(literal)), target_label, next_label },
            );
        } else {
            try self.out.writer.print(
                "    lda zeropage_switch_value\n    cmp #{d}\n    beq {s}\n",
                .{ @as(u8, @truncate(literal)), target_label },
            );
        }
    }

    pub fn switchPayloadTypeForSelectors(self: *Emitter, operand_ty: ast.Type, selectors: []const ast.SwitchSelector) !?ast.Type {
        if (operand_ty == .optional) {
            if (selectors.len != 1) return error.UnsupportedSwitchPayload;
            if (selectors[0] != .else_prong) return null;
            return optionalPayloadType(operand_ty.optional);
        }
        if (!self.isUnionType(operand_ty)) return operand_ty;
        if (selectors.len != 1) return error.UnsupportedSwitchPayload;
        const selector = selectors[0];
        if (selector != .scalar) return error.UnsupportedSwitchPayload;
        const tag_name = try self.unionSelectorName(operand_ty.custom, selector.scalar);
        return try self.unionPayloadType(operand_ty.custom, tag_name);
    }

    fn unionSelectorName(self: *Emitter, type_name: []const u8, value: ast.Value) ![]const u8 {
        return switch (value) {
            .enum_literal => |literal| blk: {
                if (literal.enum_name) |name| {
                    if (!std.mem.eql(u8, name, type_name)) return error.UnsupportedSwitchSelector;
                }
                _ = try self.unionFieldIndex(type_name, literal.tag);
                break :blk literal.tag;
            },
            .field => |field| blk: {
                if (!std.mem.eql(u8, field.base, type_name)) return error.UnsupportedSwitchSelector;
                _ = try self.unionFieldIndex(type_name, field.field);
                break :blk field.field;
            },
            else => return error.UnsupportedSwitchSelector,
        };
    }

    fn emitSwitchRangeTest(self: *Emitter, operand_ty: ast.Type, range: ast.SwitchRange, next_label: []const u8, target_label: []const u8) !void {
        const first = try switchSelectorLiteral(range.first);
        const last = try switchSelectorLiteral(range.last);
        if (isWordType(operand_ty)) {
            const low_ok = try std.fmt.allocPrint(self.allocator, "{s}_low_ok", .{next_label});
            defer self.allocator.free(low_ok);
            const high_check = try std.fmt.allocPrint(self.allocator, "{s}_high_check", .{next_label});
            defer self.allocator.free(high_check);
            try self.out.writer.print(
                "    lda zeropage_switch_value+1\n    cmp #{d}\n    bcc {s}\n    bne {s}\n    lda zeropage_switch_value\n    cmp #{d}\n    bcc {s}\n{s}:\n    lda zeropage_switch_value+1\n    cmp #{d}\n    bcc {s}\n    bne {s}\n    lda zeropage_switch_value\n    cmp #{d}\n    beq {s}\n    bcc {s}\n    jmp {s}\n{s}:\n    jmp {s}\n",
                .{
                    @as(u8, @truncate(first >> 8)), next_label,   low_ok,
                    @as(u8, @truncate(first)),      next_label,   low_ok,
                    @as(u8, @truncate(last >> 8)),  target_label, high_check,
                    @as(u8, @truncate(last)),       target_label, target_label,
                    next_label,                     high_check,   next_label,
                },
            );
        } else {
            const low_ok = try std.fmt.allocPrint(self.allocator, "{s}_low_ok", .{next_label});
            defer self.allocator.free(low_ok);
            try self.out.writer.print(
                "    lda zeropage_switch_value\n    cmp #{d}\n    bcc {s}\n{s}:\n    cmp #{d}\n    beq {s}\n    bcc {s}\n",
                .{ @as(u8, @truncate(first)), next_label, low_ok, @as(u8, @truncate(last)), target_label, target_label },
            );
        }
    }

    fn emitBlockBreakExpr(self: *Emitter, function_name: []const u8, break_expr: ast.BreakExpr) anyerror!void {
        const block = self.currentBlockExpr(break_expr.label) orelse return error.UnsupportedBlockExpressionBreak;
        if (isWideValueType(block.result_ty)) {
            try self.emitExprToAX(function_name, break_expr.value);
        } else {
            try self.emitExprToAExpected(function_name, break_expr.value, block.result_ty);
        }
        try self.out.writer.print("    jmp block_expr_{d}_done\n", .{block.id});
    }

    fn emitCall(self: *Emitter, function_name: []const u8, call: ast.CallExpr) anyerror!void {
        const w = &self.out.writer;
        if (try self.reuViewCall(function_name, call, "set")) |view_call| {
            try self.emitReuViewSet(function_name, view_call, call);
            return;
        }
        if (try self.nearViewCall(function_name, call, "set")) |view_call| {
            try self.emitNearViewSet(function_name, view_call, call);
            return;
        }
        if (try self.reuViewCall(function_name, call, "flush")) |view_call| {
            try self.emitFarViewFlush(function_name, view_call, call);
            return;
        }
        if (try self.reuViewCall(function_name, call, "flushRange")) |view_call| {
            try self.emitFarViewFlushRange(function_name, view_call, call);
            return;
        }
        const target_label = try self.labelForTarget(call.target);
        defer self.allocator.free(target_label);

        const callee = self.findFunction(target_label) orelse return error.UnknownFunction;
        if (callee.params.len != call.args.len) return error.ArgumentCountMismatch;
        if (self.functionUsesSoftwareStack(callee.name)) return try self.emitStaticToStackCall(function_name, callee, call);

        const base = self.call_arg_depth;
        self.call_arg_depth += call.args.len;
        if (self.call_arg_depth > self.max_call_arg_temps) self.max_call_arg_temps = self.call_arg_depth;
        defer self.call_arg_depth = base;

        const site = self.scalar_call_site_id;
        self.scalar_call_site_id += 1;
        var annotate = self.program.zeropage_module == null and
            self.program.zeropage_options.memory.placements.len == 0 and
            !self.functionUsesSoftwareStack(function_name) and call.args.len > 0;
        for (callee.params) |param| {
            if (self.isStructType(param.ty) or self.isUnionType(param.ty) or isOptionalType(param.ty) or
                !(param.ty == .bool or param.ty == .u8 or param.ty == .i8 or param.ty == .u16 or
                    param.ty == .i16 or param.ty == .usize or param.ty == .pointer or
                    (param.ty == .custom and self.program.findEnum(param.ty.custom) != null))) annotate = false;
        }
        if (annotate) try w.print("; zeropage_scalar_call_begin id={d} callee={s} count={d}\n", .{ site, callee.name, callee.params.len });
        for (call.args, 0..) |arg, index| {
            const param = callee.params[index];
            if (self.isStructType(param.ty)) {
                continue;
            } else if (self.isUnionType(param.ty)) {
                continue;
            } else if (isOptionalType(param.ty)) {
                continue;
            } else if (isWideValueType(param.ty)) {
                try self.emitExprToAXExpected(function_name, arg, param.ty);
                if (annotate) try w.print("; zeropage_scalar_call_store id={d} index={d} width=2 temp=zeropage_call_arg_{d} target={s}_{s}\n", .{ site, index, base + index, callee.name, param.name });
                try w.print("    sta zeropage_call_arg_{d}\n    stx zeropage_call_arg_{d}+1\n", .{ base + index, base + index });
            } else {
                try self.emitExprToAExpected(function_name, arg, param.ty);
                if (annotate) try w.print("; zeropage_scalar_call_store id={d} index={d} width=1 temp=zeropage_call_arg_{d} target={s}_{s}\n", .{ site, index, base + index, callee.name, param.name });
                try w.print("    sta zeropage_call_arg_{d}\n", .{base + index});
            }
        }
        for (callee.params, 0..) |param, index| {
            if (annotate) try w.print("; zeropage_scalar_call_copy id={d} index={d} width={d} temp=zeropage_call_arg_{d} target={s}_{s}\n", .{ site, index, @as(u8, if (isWideValueType(param.ty)) 2 else 1), base + index, callee.name, param.name });
            if (self.isStructType(param.ty)) {
                try self.emitStructExprToFunctionStorage(callee.name, param.name, function_name, param.ty.custom, call.args[index]);
            } else if (self.isUnionType(param.ty)) {
                try self.emitUnionExprToFunctionStorage(callee.name, param.name, function_name, param.ty.custom, call.args[index]);
            } else if (isOptionalType(param.ty)) {
                try self.emitOptionalExprToStorage(function_name, call.args[index], callee.name, param.name, param.ty.optional);
            } else if (isWideValueType(param.ty)) {
                try w.print("    lda zeropage_call_arg_{d}\n    sta {s}_{s}\n    lda zeropage_call_arg_{d}+1\n    sta {s}_{s}+1\n", .{ base + index, callee.name, param.name, base + index, callee.name, param.name });
            } else {
                try w.print("    lda zeropage_call_arg_{d}\n    sta {s}_{s}\n", .{ base + index, callee.name, param.name });
            }
        }
        if (annotate) try w.print("; zeropage_scalar_call_end id={d}\n", .{site});
        try self.emitUserFunctionJsr(function_name, target_label);
    }

    fn emitStaticToStackCall(self: *Emitter, function_name: []const u8, callee: ast.Function, call: ast.CallExpr) anyerror!void {
        var layout = try frame_layout.planFunction(self.allocator, self.program, callee, .stack);
        defer layout.deinit(self.allocator);
        if (layout.byte_size > 255) return error.UnsupportedStackFrameTooLarge;

        const w = &self.out.writer;
        try w.writeAll(
            \\    lda zeropage_stack_sp
            \\    sta zeropage_stack_fp
            \\    lda zeropage_stack_sp+1
            \\    sta zeropage_stack_fp+1
            \\
        );
        try self.emitSoftwareStackEnsureAvailable(layout.byte_size);
        const publish_checked_end = layout.byte_size != 0 and
            canPublishStackBeforeArguments(callee.params, call.args) and try self.hasPrivateStackLayout();
        if (publish_checked_end) {
            // On success the guard leaves the checked end in A:X (high:low).
            // FP still names the start of the parameter area.
            try w.writeAll("    stx zeropage_stack_sp\n    sta zeropage_stack_sp+1\n");
        }

        for (callee.params, 0..) |param, index| {
            const arg = call.args[index];
            if (frame_layout.exprContainsCall(arg)) return error.UnsupportedStackFrameBridgeArgument;
            const slot = layout.findSlot(param.name) orelse return error.UnknownVariable;
            if (isWideValueType(param.ty)) {
                try self.emitExprToAXExpected(function_name, arg, param.ty);
                try self.storeSoftwareStackPointerAX("zeropage_stack_fp", slot.offset);
            } else {
                try self.emitExprToAExpected(function_name, arg, param.ty);
                try self.storeSoftwareStackPointerA("zeropage_stack_fp", slot.offset);
            }
        }

        if (!publish_checked_end) try self.emitSoftwareStackAdvanceStackPointerUnchecked(layout.byte_size);
        try self.emitModuleRelocationAnchor(callee.name);
        try w.print("    jsr {s}\n", .{callee.name});

        if (callee.return_type == .void) {
            try self.emitSoftwareStackEpilogue();
        } else if (try self.canRewritePrivateStackBridge()) {
            try w.writeAll(
                \\    ldy zeropage_stack_fp
                \\    sty zeropage_stack_sp
                \\    ldy zeropage_stack_fp+1
                \\    sty zeropage_stack_sp+1
                \\
            );
        } else if (isWideValueType(callee.return_type)) {
            self.uses_stack_bridge_return = true;
            try self.emitRelocatableStackReturnStoreAX();
            try self.emitSoftwareStackEpilogue();
            try self.emitRelocatableStackReturnLoadAX();
        } else {
            self.uses_stack_bridge_return = true;
            try self.emitRelocatableStackReturnStoreA();
            try self.emitSoftwareStackEpilogue();
            try self.emitRelocatableStackReturnLoadA();
        }
    }

    fn canRewritePrivateStackBridge(self: *Emitter) !bool {
        if (self.private_stack_bridge) |allowed| return allowed;
        const image = self.program.zeropage_options.image;
        // Keep the original bridge when source can observe resident addresses
        // that change when its instructions or return cells shrink.
        const allowed = try self.hasPrivateStackLayout() and
            !try placement_domains.observesMovableImage(self.allocator, self.program, .{
                .start = image.load_addr,
                .end = image.address_limit,
            });
        self.private_stack_bridge = allowed;
        return allowed;
    }

    fn canSpillNestedStackReturn(self: *Emitter) !bool {
        if (self.private_nested_stack_return) |allowed| return allowed;
        const allowed = self.program.zeropage_options.image.load_addr >= 0x200 and
            try self.canRewritePrivateStackBridge() and
            !try placement_domains.observesMovableImage(self.allocator, self.program, .{ .start = 0x100, .end = 0x200 });
        self.private_nested_stack_return = allowed;
        return allowed;
    }

    fn canPublishStackBeforeArguments(params: []const ast.Param, args: []const ast.Expr) bool {
        for (params, args) |param, arg| {
            switch (param.ty) {
                .u8, .i8, .u16, .i16, .usize, .bool => {},
                else => return false,
            }
            if (!isPureStackBridgeArgument(arg)) return false;
        }
        return true;
    }

    fn isPureStackBridgeArgument(expr: ast.Expr) bool {
        return switch (expr) {
            .value => |value| switch (value) {
                .int, .bool, .char, .ident => true,
                else => false,
            },
            .add, .sub => |binary| isPureStackBridgeArgument(binary.lhs.*) and isPureStackBridgeArgument(binary.rhs.*),
            else => false,
        };
    }

    pub fn emitValueToA(self: *Emitter, function_name: []const u8, value: ast.Value) !void {
        const w = &self.out.writer;
        switch (value) {
            .int => |n| try w.print("    lda #{d}\n", .{@as(u8, @truncate(n))}),
            .bool => |b| try w.print("    lda #{d}\n", .{@intFromBool(b)}),
            .char => |ch| try w.print("    lda #{d}\n", .{screenCode(ch)}),
            .ident => |ident| {
                const binding = try self.expectBinding(function_name, ident);
                if (isArrayType(binding.ty)) return error.UnsupportedArrayByValue;
                if (binding.ty == .far_view or binding.ty == .near_view) return error.UnsupportedPointerType;
                try w.print("    lda {s}_{s}\n", .{ function_name, ident });
            },
            .field => |field| {
                if (self.program.findEnum(field.base)) |_| {
                    try w.print("    lda #{d}\n", .{try self.enumTagValue(field.base, field.field)});
                } else {
                    try self.emitFieldToA(function_name, field);
                }
            },
            .enum_literal => return error.UnsupportedEnumLiteral,
            .null => return error.UnsupportedOptional,
        }
    }

    fn emitValueToAX(self: *Emitter, function_name: []const u8, value: ast.Value) !void {
        const w = &self.out.writer;
        switch (value) {
            .int => |n| try w.print("    ldx #{d}\n    lda #{d}\n", .{ @as(u8, @truncate(n >> 8)), @as(u8, @truncate(n)) }),
            .bool => |b| try w.print("    ldx #0\n    lda #{d}\n", .{@intFromBool(b)}),
            .char => |ch| try w.print("    ldx #0\n    lda #{d}\n", .{screenCode(ch)}),
            .ident => |ident| {
                const binding = try self.expectBinding(function_name, ident);
                if (isArrayType(binding.ty)) return error.UnsupportedArrayByValue;
                if (binding.ty == .far_view or binding.ty == .near_view) return error.UnsupportedPointerType;
                if (isWideValueType(binding.ty)) {
                    try w.print("    ldx {s}_{s}+1\n    lda {s}_{s}\n", .{ function_name, ident, function_name, ident });
                } else {
                    try w.print("    ldx #0\n    lda {s}_{s}\n", .{ function_name, ident });
                }
            },
            .field => |field| {
                if (self.program.findEnum(field.base)) |_| {
                    try w.print("    ldx #0\n    lda #{d}\n", .{try self.enumTagValue(field.base, field.field)});
                } else {
                    try self.emitFieldToAX(function_name, field);
                }
            },
            .enum_literal => return error.UnsupportedEnumLiteral,
            .null => return error.UnsupportedOptional,
        }
    }

    fn emitFieldToA(self: *Emitter, function_name: []const u8, field: ast.FieldRef) !void {
        if (self.findBinding(function_name, field.base) catch |err| switch (err) {
            error.UnknownVariable => null,
            else => return err,
        }) |binding| {
            if (self.isUnionType(binding.ty)) return error.UnsupportedStruct;
        }
        if (std.mem.eql(u8, field.field, "len")) {
            if (self.findBinding(function_name, field.base) catch |err| switch (err) {
                error.UnknownVariable => null,
                else => return err,
            }) |binding| {
                if (binding.ty == .far_view) {
                    try self.out.writer.print("    lda #{d}\n", .{@as(u8, @truncate(binding.ty.far_view.count))});
                    return;
                }
                if (binding.ty == .near_view) {
                    try self.out.writer.print("    lda #{d}\n", .{@as(u8, @truncate(binding.ty.near_view.count))});
                    return;
                }
            }
            if (try self.resolvePointerStructArrayPath(function_name, field.base)) |path| {
                defer path.deinit(self.allocator);
                try self.out.writer.print("    lda #{d}\n", .{path.ty.len});
                return;
            }
            const array_ref = self.resolveArray(function_name, field.base) catch |err| switch (err) {
                error.UnknownVariable => null,
                else => return err,
            };
            if (array_ref) |ref| {
                defer ref.deinit(self.allocator);
                try self.out.writer.print("    lda #{d}\n", .{@as(u8, @truncate(ref.ty.len))});
                return;
            }
        }
        const flat_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ field.base, field.field });
        defer self.allocator.free(flat_name);
        if (try self.resolvePointerStructPath(function_name, flat_name)) |path| {
            defer path.deinit(self.allocator);
            if (isArrayType(path.ty) or self.isStructType(path.ty)) return error.UnsupportedPointerTarget;
            try self.emitPointerStructPathToA(function_name, flat_name);
            return;
        }
        try self.out.writer.print("    lda {s}_{s}_{s}\n", .{ function_name, field.base, field.field });
    }

    fn emitFieldToAX(self: *Emitter, function_name: []const u8, field: ast.FieldRef) !void {
        if (self.findBinding(function_name, field.base) catch |err| switch (err) {
            error.UnknownVariable => null,
            else => return err,
        }) |binding| {
            if (self.isUnionType(binding.ty)) return error.UnsupportedStruct;
        }
        if (std.mem.eql(u8, field.field, "len")) {
            if (self.findBinding(function_name, field.base) catch |err| switch (err) {
                error.UnknownVariable => null,
                else => return err,
            }) |binding| {
                if (binding.ty == .far_view) {
                    try self.out.writer.print("    ldx #0\n    lda #{d}\n", .{@as(u8, @truncate(binding.ty.far_view.count))});
                    return;
                }
                if (binding.ty == .near_view) {
                    try self.out.writer.print("    ldx #0\n    lda #{d}\n", .{@as(u8, @truncate(binding.ty.near_view.count))});
                    return;
                }
            }
            if (try self.resolvePointerStructArrayPath(function_name, field.base)) |path| {
                defer path.deinit(self.allocator);
                try self.out.writer.print("    ldx #0\n    lda #{d}\n", .{path.ty.len});
                return;
            }
            const array_ref = self.resolveArray(function_name, field.base) catch |err| switch (err) {
                error.UnknownVariable => null,
                else => return err,
            };
            if (array_ref) |ref| {
                defer ref.deinit(self.allocator);
                try self.out.writer.print("    ldx #{d}\n    lda #{d}\n", .{ @as(u8, @truncate(ref.ty.len >> 8)), @as(u8, @truncate(ref.ty.len)) });
                return;
            }
        }
        const flat_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ field.base, field.field });
        defer self.allocator.free(flat_name);
        if (try self.resolvePointerStructPath(function_name, flat_name)) |path| {
            defer path.deinit(self.allocator);
            if (isArrayType(path.ty) or self.isStructType(path.ty)) return error.UnsupportedPointerTarget;
            try self.emitPointerStructPathToAX(function_name, flat_name);
            return;
        }
        const ty = try self.valueType(function_name, .{ .field = field });
        if (isWideValueType(ty)) {
            try self.out.writer.print("    ldx {s}_{s}_{s}+1\n    lda {s}_{s}_{s}\n", .{ function_name, field.base, field.field, function_name, field.base, field.field });
        } else {
            try self.out.writer.print("    ldx #0\n    lda {s}_{s}_{s}\n", .{ function_name, field.base, field.field });
        }
    }

    fn emitWordCompare(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr) !void {
        if (try self.directScalarOperand(function_name, binary.rhs.*, try self.exprType(function_name, binary.lhs.*))) |operand| {
            try self.emitExprToAX(function_name, binary.lhs.*);
            const id = self.nextLabel();
            try self.emitDirectOperand(function_name, operand, true);
            try self.out.writer.print("    bne cmp_word_{d}_done\n", .{id});
            try self.emitDirectOperand(function_name, operand, false);
            try self.out.writer.print("cmp_word_{d}_done:\n", .{id});
            return;
        }
        self.uses_math_tmp = true;
        try self.emitExprToAX(function_name, binary.lhs.*);
        try self.out.writer.writeAll("    pha\n    txa\n    pha\n");
        try self.emitExprToAX(function_name, binary.rhs.*);
        try self.out.writer.writeAll("    sta zeropage_math_tmp\n    stx zeropage_math_tmp+1\n    pla\n    tax\n    pla\n");
        const id = self.nextLabel();
        try self.out.writer.print(
            "    cpx zeropage_math_tmp+1\n    bne cmp_word_{d}_done\n    cmp zeropage_math_tmp\ncmp_word_{d}_done:\n",
            .{ id, id },
        );
    }

    fn comparisonNeedsWord(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr) !bool {
        const lhs_ty_maybe = self.exprType(function_name, binary.lhs.*) catch |err| switch (err) {
            error.UnsupportedEnumLiteral => null,
            else => return err,
        };
        const rhs_ty_maybe = self.exprType(function_name, binary.rhs.*) catch |err| switch (err) {
            error.UnsupportedEnumLiteral => null,
            else => return err,
        };
        const lhs_ty = if (lhs_ty_maybe) |ty|
            ty
        else if (rhs_ty_maybe) |ty|
            try self.exprTypeAllowContext(function_name, binary.lhs.*, ty)
        else
            return error.UnsupportedEnumLiteral;
        const rhs_ty = if (rhs_ty_maybe) |ty|
            ty
        else
            try self.exprTypeAllowContext(function_name, binary.rhs.*, lhs_ty);
        return isWordType(lhs_ty) or isWordType(rhs_ty);
    }

    fn exprNeedsWord(self: *Emitter, function_name: []const u8, expr: ast.Expr) !bool {
        return switch (expr) {
            .value => |value| switch (value) {
                .int => |n| n > 255,
                else => isWideValueType(try self.valueType(function_name, value)),
            },
            .add, .sub => true,
            .mul => |mul| blk: {
                const ty = try self.exprType(function_name, .{ .mul = mul });
                break :blk isWordType(ty);
            },
            .bit_and => |bit_and| isWordType(try self.exprType(function_name, .{ .bit_and = bit_and })),
            .bit_or => |bit_or| isWordType(try self.exprType(function_name, .{ .bit_or = bit_or })),
            .bit_xor => |bit_xor| isWordType(try self.exprType(function_name, .{ .bit_xor = bit_xor })),
            .shl => |shl| isWordType(try self.exprType(function_name, .{ .shl = shl })),
            .shr => |shr| isWordType(try self.exprType(function_name, .{ .shr = shr })),
            .bit_not => |child| isWordType(try self.exprType(function_name, .{ .bit_not = child })),
            .call => |call| blk: {
                if (try self.nearViewCall(function_name, call, "get")) |_| break :blk false;
                break :blk isWideValueType((try self.functionForCall(call)).return_type);
            },
            .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or, .not, .c64_read_petscii, .c64_wait_petscii, .reu_present, .reu_compare, .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded => false,
            .module_call => true,
            .reu_heap_alloc, .reu_view, .far_view_materialize, .far_view_materialize_range, .heap_alloc => true,
            .size_of, .align_of, .offset_of => (try self.layoutComptimeValue(expr)) > 255,
            .address_of, .ptr_from_int, .int_from_ptr => true,
            .as_cast => |as_cast| isWideValueType(try self.validateAsCast(function_name, as_cast)),
            .deref => |child| isWideValueType(try self.exprType(function_name, .{ .deref = child })),
            .if_expr => |if_expr| isWideValueType(try self.ifExprType(function_name, if_expr)),
            .switch_expr => |switch_expr| isWideValueType(try self.switchExprType(function_name, switch_expr)),
            .block_expr => |block_expr| isWideValueType(try self.blockExprType(function_name, block_expr)),
            .array_index => |index| isWordType(try self.exprType(function_name, .{ .array_index = index })),
            .array_field_index => |index| isWordType(try self.exprType(function_name, .{ .array_field_index = index })),
            .array_literal => return error.UnsupportedArrayByValue,
            .struct_literal => return error.UnsupportedStruct,
        };
    }

    fn validateComparison(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr, op: CompareOp) !void {
        const lhs_ty_raw = self.exprType(function_name, binary.lhs.*) catch |err| switch (err) {
            error.UnsupportedEnumLiteral => try self.exprType(function_name, binary.rhs.*),
            else => return err,
        };
        const rhs_ty = try self.exprTypeAllowContext(function_name, binary.rhs.*, lhs_ty_raw);
        const lhs_ty = try self.exprTypeAllowContext(function_name, binary.lhs.*, rhs_ty);
        if (isPointerType(lhs_ty) or isPointerType(rhs_ty)) return error.UnsupportedPointerCast;
        if (self.isUnionType(lhs_ty) or self.isUnionType(rhs_ty)) return error.UnsupportedStruct;
        if ((self.isEnumType(lhs_ty) or self.isEnumType(rhs_ty)) and !typesEqual(lhs_ty, rhs_ty)) return error.UnsupportedEnumLiteral;
        switch (op) {
            .eq, .ne => {
                if (self.isEnumType(lhs_ty) or self.isEnumType(rhs_ty)) return;
            },
            .lt, .lte, .gt, .gte => {
                if (self.isEnumType(lhs_ty) or self.isEnumType(rhs_ty)) return error.UnsupportedSwitchRange;
                if (isBoolType(lhs_ty) or isBoolType(rhs_ty)) return error.UnsupportedBoolOrderedComparison;
                if (isSignedType(lhs_ty) or isSignedType(rhs_ty)) return error.UnsupportedSignedOrderedComparison;
            },
        }
    }

    fn validateMultiplication(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr) !void {
        try self.validateMultiplicationTypes(
            try self.exprType(function_name, binary.lhs.*),
            try self.exprType(function_name, binary.rhs.*),
        );
    }

    fn validateAddSub(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr) !void {
        const lhs_ty = try self.exprType(function_name, binary.lhs.*);
        const rhs_ty = try self.exprType(function_name, binary.rhs.*);
        if (isPointerType(lhs_ty) or isPointerType(rhs_ty)) return error.UnsupportedPointerCast;
    }

    fn validateMultiplicationTypes(self: *Emitter, lhs_ty: ast.Type, rhs_ty: ast.Type) !void {
        _ = self;
        if (isBoolType(lhs_ty) or isBoolType(rhs_ty)) return error.UnsupportedBoolMultiplication;
        if (isSignedType(lhs_ty) or isSignedType(rhs_ty)) return error.UnsupportedSignedMultiplication;
        if (!isNumericScalarType(lhs_ty) or !isNumericScalarType(rhs_ty)) return error.UnsupportedMultiplicationType;
    }

    fn validateBitwise(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr) !void {
        try self.validateBitwiseTypes(
            try self.exprType(function_name, binary.lhs.*),
            try self.exprType(function_name, binary.rhs.*),
        );
    }

    fn validateBitwiseUnary(self: *Emitter, function_name: []const u8, expr: ast.Expr) !void {
        const ty = try self.exprType(function_name, expr);
        if (isBoolType(ty)) return error.UnsupportedBoolBitwise;
        if (isSignedType(ty)) return error.UnsupportedSignedBitwise;
        if (!isNumericScalarType(ty)) return error.UnsupportedBitwiseType;
    }

    fn validateBitwiseTypes(self: *Emitter, lhs_ty: ast.Type, rhs_ty: ast.Type) !void {
        _ = self;
        if (isBoolType(lhs_ty) or isBoolType(rhs_ty)) return error.UnsupportedBoolBitwise;
        if (isSignedType(lhs_ty) or isSignedType(rhs_ty)) return error.UnsupportedSignedBitwise;
        if (!isNumericScalarType(lhs_ty) or !isNumericScalarType(rhs_ty)) return error.UnsupportedBitwiseType;
    }

    fn validateShift(self: *Emitter, function_name: []const u8, binary: ast.BinaryExpr) !void {
        try self.validateShiftTypes(
            try self.exprType(function_name, binary.lhs.*),
            try self.exprType(function_name, binary.rhs.*),
            binary.rhs.*,
        );
    }

    fn validateShiftTypes(self: *Emitter, lhs_ty: ast.Type, rhs_ty: ast.Type, rhs: ast.Expr) !void {
        _ = self;
        if (isBoolType(lhs_ty) or isBoolType(rhs_ty)) return error.UnsupportedBoolShift;
        if (isSignedType(lhs_ty) or isSignedType(rhs_ty)) return error.UnsupportedSignedShift;
        if (!isNumericScalarType(lhs_ty) or !isNumericScalarType(rhs_ty)) return error.UnsupportedShiftType;
        if (exprIntLiteral(rhs)) |count| {
            const width: u16 = if (isWordType(lhs_ty)) 16 else 8;
            if (count >= width) return error.UnsupportedOversizedShift;
        }
    }

    pub fn validateArrayLiteral(self: *Emitter, function_name: []const u8, array_ty: ast.ArrayType, literal: ast.ArrayLiteral) !void {
        if (literal.ty) |literal_ty| {
            if (!arrayTypesEqual(array_ty, literal_ty)) return error.UnsupportedArrayLiteral;
        }
        if (literal.values.len != array_ty.len) return error.UnsupportedArrayLiteral;
        for (literal.values) |value| try self.validateArrayElementValue(function_name, array_ty, value);
    }

    fn validateArrayElementValue(self: *Emitter, function_name: []const u8, array_ty: ast.ArrayType, value: ast.Expr) !void {
        const elem_ty = arrayElemToType(array_ty.elem);
        if (self.isStructType(elem_ty)) {
            _ = try self.exprTypeAllowContext(function_name, value, elem_ty);
            return;
        }
        if (self.isEnumType(elem_ty)) {
            switch (value) {
                .value => |v| switch (v) {
                    .field => |field| {
                        if (self.program.findEnum(field.base)) |_| {
                            _ = try self.enumTagValue(field.base, field.field);
                            if (!typesEqual(elem_ty, .{ .custom = field.base })) return error.UnsupportedArrayLiteral;
                            return;
                        }
                    },
                    .enum_literal => |literal| {
                        _ = try self.enumLiteralValue(elem_ty, literal);
                        return;
                    },
                    else => {},
                },
                else => {},
            }
            const value_ty = try self.exprTypeAllowContext(function_name, value, elem_ty);
            if (!typesEqual(elem_ty, value_ty)) return error.UnsupportedArrayLiteral;
            return;
        }
        const value_ty = try self.exprType(function_name, value);
        if (isBoolType(elem_ty)) {
            if (!isBoolType(value_ty)) return error.UnsupportedArrayLiteral;
            return;
        }
        if (isSignedType(elem_ty)) {
            if (isSignedType(value_ty) or exprIntLiteral(value) != null) return;
            return error.UnsupportedArrayLiteral;
        }
        if (isBoolType(value_ty) or isSignedType(value_ty)) return error.UnsupportedArrayLiteral;
        _ = try commonScalarBranchType(elem_ty, value_ty, error.UnsupportedArrayLiteral);
    }

    fn validatePointerElementValue(self: *Emitter, function_name: []const u8, elem_ty: ast.Type, value: ast.Expr) !void {
        if (self.isEnumType(elem_ty)) {
            const value_ty = try self.exprTypeAllowContext(function_name, value, elem_ty);
            if (!typesEqual(elem_ty, value_ty)) return error.UnsupportedPointerType;
            return;
        }
        const value_ty = try self.exprType(function_name, value);
        if (isBoolType(elem_ty)) {
            if (!isBoolType(value_ty)) return error.UnsupportedPointerType;
            return;
        }
        if (isSignedType(elem_ty)) {
            if (isSignedType(value_ty) or exprIntLiteral(value) != null) return;
            return error.UnsupportedPointerType;
        }
        if (isBoolType(value_ty) or isSignedType(value_ty)) return error.UnsupportedPointerType;
        _ = try commonScalarBranchType(elem_ty, value_ty, error.UnsupportedPointerType);
    }

    fn validateArrayIndexLiteral(self: *Emitter, array_ty: ast.ArrayType, index: ast.Expr) !void {
        _ = self;
        if (exprIntLiteral(index)) |literal| {
            if (literal >= array_ty.len) return error.UnsupportedArrayIndex;
        }
    }

    fn expectBoolExpr(self: *Emitter, function_name: []const u8, expr: ast.Expr) !void {
        if (!isBoolType(try self.exprType(function_name, expr))) return error.UnsupportedNonBoolCondition;
    }

    pub fn exprType(self: *Emitter, function_name: []const u8, expr: ast.Expr) anyerror!ast.Type {
        return switch (expr) {
            .value => |value| try self.valueType(function_name, value),
            .add, .sub => |binary| blk: {
                try self.validateAddSub(function_name, binary);
                const lhs_ty = try self.exprType(function_name, binary.lhs.*);
                const rhs_ty = try self.exprType(function_name, binary.rhs.*);
                if (isWordType(lhs_ty)) break :blk lhs_ty;
                if (isWordType(rhs_ty)) break :blk rhs_ty;
                break :blk .u8;
            },
            .mul => |binary| blk: {
                try self.validateMultiplication(function_name, binary);
                const lhs_ty = try self.exprType(function_name, binary.lhs.*);
                const rhs_ty = try self.exprType(function_name, binary.rhs.*);
                if (isUsizeType(lhs_ty) or isUsizeType(rhs_ty)) break :blk .usize;
                if (isWordType(lhs_ty) or isWordType(rhs_ty)) break :blk .u16;
                break :blk .u8;
            },
            .bit_and, .bit_or, .bit_xor => |binary| blk: {
                try self.validateBitwise(function_name, binary);
                const lhs_ty = try self.exprType(function_name, binary.lhs.*);
                const rhs_ty = try self.exprType(function_name, binary.rhs.*);
                if (isUsizeType(lhs_ty) or isUsizeType(rhs_ty)) break :blk .usize;
                if (isWordType(lhs_ty) or isWordType(rhs_ty)) break :blk .u16;
                break :blk .u8;
            },
            .shl, .shr => |binary| blk: {
                try self.validateShift(function_name, binary);
                break :blk try self.exprType(function_name, binary.lhs.*);
            },
            .bit_not => |child| blk: {
                try self.validateBitwiseUnary(function_name, child.*);
                break :blk try self.exprType(function_name, child.*);
            },
            .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or, .not => .bool,
            .c64_read_petscii, .c64_wait_petscii => .u8,
            .reu_present, .reu_compare, .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded => .bool,
            .module_call => |call| .{ .optional = moduleCallOptional(try self.validateModuleCall(call)) },
            .reu_heap_alloc => .{ .optional = .{ .child = .far_bytes } },
            .reu_view => |view| try self.validateReuView(function_name, view),
            .far_view_materialize => |mat| .{ .optional = .{ .child = .{ .near_view = try self.validateFarViewMaterialize(function_name, mat) } } },
            .far_view_materialize_range => |range| .{ .optional = .{ .child = .{ .near_view = try self.validateFarViewMaterializeRange(function_name, range) } } },
            .heap_alloc => .{ .optional = .{ .child = .{ .pointer = .{ .child = .{ .scalar = .u8 }, .is_many = true, .is_volatile = false } } } },
            .size_of, .align_of, .offset_of => .usize,
            .address_of => |address| blk: {
                const target = try self.resolveAddressTarget(function_name, address);
                defer target.deinit(self.allocator);
                break :blk target.pointer_ty;
            },
            .ptr_from_int => return error.UnsupportedPointerCast,
            .int_from_ptr => |child| blk: {
                const ptr_ty = try self.exprType(function_name, child.*);
                if (ptr_ty != .pointer) return error.UnsupportedPointerCast;
                break :blk ast.Type.usize;
            },
            .as_cast => |as_cast| try self.validateAsCast(function_name, as_cast),
            .deref => |child| blk: {
                const ptr_ty = try self.exprType(function_name, child.*);
                if (ptr_ty != .pointer) return error.UnsupportedPointerTarget;
                break :blk try self.validatePointerChildType(ptr_ty.pointer.child);
            },
            .if_expr => |if_expr| try self.ifExprType(function_name, if_expr),
            .switch_expr => |switch_expr| try self.switchExprType(function_name, switch_expr),
            .block_expr => |block_expr| try self.blockExprType(function_name, block_expr),
            .call => |call| blk: {
                if (try self.reuViewCall(function_name, call, "get")) |view_call| break :blk .{ .custom = view_call.view.type_name };
                if (try self.nearViewCall(function_name, call, "get")) |view_call| break :blk .{ .custom = view_call.view.type_name };
                break :blk (try self.functionForCall(call)).return_type;
            },
            .array_literal => |literal| blk: {
                if (literal.ty) |ty| break :blk .{ .array = ty };
                break :blk error.UnsupportedArrayLiteral;
            },
            .struct_literal => |literal| {
                if (self.program.findUnion(literal.type_name) != null) return .{ .custom = literal.type_name };
                return error.UnsupportedStruct;
            },
            .array_index => |index| blk: {
                const array_ref = self.resolveArray(function_name, index.name) catch |err| switch (err) {
                    error.UnknownVariable => {
                        const binding = self.findBinding(function_name, index.name) catch |binding_err| switch (binding_err) {
                            error.UnknownVariable => null,
                            else => return binding_err,
                        };
                        if (binding) |found| {
                            if (found.ty == .far_bytes) return error.UnsupportedPointerType;
                        }
                        if (try self.maybeManyPointerIndexChildType(function_name, index.name, index.index.*)) |child_ty| break :blk child_ty;
                        if (try self.resolvePointerStructArrayPath(function_name, index.name)) |path| {
                            defer path.deinit(self.allocator);
                            try self.validateArrayIndexLiteral(path.ty, index.index.*);
                            break :blk arrayElemToType(path.ty.elem);
                        }
                        return err;
                    },
                    else => return err,
                };
                defer array_ref.deinit(self.allocator);
                try self.validateArrayIndexLiteral(array_ref.ty, index.index.*);
                break :blk arrayElemToType(array_ref.ty.elem);
            },
            .array_field_index => |index| blk: {
                const field_ref = try self.resolveArrayFieldRef(function_name, index.name, index.field_path);
                defer field_ref.deinit(self.allocator);
                try self.validateArrayIndexLiteral(field_ref.array_ref.ty, index.index.*);
                break :blk field_ref.field_ty;
            },
        };
    }

    fn exprTypeAllowContext(self: *Emitter, function_name: []const u8, expr: ast.Expr, expected_ty: ast.Type) anyerror!ast.Type {
        switch (expr) {
            .value => |value| switch (value) {
                .null => {
                    if (expected_ty != .optional) return error.UnsupportedOptional;
                    _ = try self.validateOptionalType(expected_ty.optional);
                    return expected_ty;
                },
                .enum_literal => |literal| {
                    _ = try self.enumLiteralValue(expected_ty, literal);
                    return expected_ty;
                },
                else => {},
            },
            .if_expr => |if_expr| {
                if (if_expr.payload_name != null) {
                    _ = try self.expectOptionalExpr(function_name, if_expr.condition.*);
                } else {
                    try self.expectBoolExpr(function_name, if_expr.condition.*);
                }
                _ = try self.exprTypeAllowContext(function_name, if_expr.then_expr.*, expected_ty);
                _ = try self.exprTypeAllowContext(function_name, if_expr.else_expr.*, expected_ty);
                return expected_ty;
            },
            .switch_expr => |switch_expr| {
                const operand_ty = try self.exprType(function_name, switch_expr.operand.*);
                try self.validateSwitchProngs(function_name, operand_ty, null, switch_expr.prongs);
                for (switch_expr.prongs) |prong| _ = try self.exprTypeAllowContext(function_name, prong.value, expected_ty);
                return expected_ty;
            },
            .struct_literal => |literal| {
                if (self.isUnionType(expected_ty)) {
                    if (literal.type_name.len != 0 and !std.mem.eql(u8, expected_ty.custom, literal.type_name)) return error.UnsupportedStruct;
                    try self.validateUnionLiteral(function_name, expected_ty.custom, literal);
                    return expected_ty;
                }
                if (self.isStructType(expected_ty)) {
                    if (!std.mem.eql(u8, expected_ty.custom, literal.type_name)) return error.UnsupportedStruct;
                    const decl = self.program.findStruct(expected_ty.custom) orelse return error.UnsupportedStruct;
                    for (decl.fields) |field_decl| {
                        const init = findStructFieldInit(literal.fields, field_decl.name) orelse return error.UnsupportedStruct;
                        _ = try self.exprTypeAllowContext(function_name, init.value, field_decl.ty);
                    }
                    for (literal.fields) |init| {
                        if (findStructFieldDecl(decl, init.name) == null) return error.UnsupportedStruct;
                    }
                    return expected_ty;
                }
            },
            .block_expr => |block_expr| return try self.blockExprTypeExpected(function_name, block_expr, expected_ty),
            .as_cast => |as_cast| {
                _ = try self.validateAsCast(function_name, as_cast);
                if (isPointerType(expected_ty)) {
                    if (!typesEqual(as_cast.ty, expected_ty)) return error.UnsupportedPointerCast;
                    return expected_ty;
                }
                if (!self.canUseTypedValueAs(as_cast.ty, expected_ty)) return error.UnsupportedCast;
                return expected_ty;
            },
            .ptr_from_int => |child| {
                if (expected_ty != .pointer) return error.UnsupportedPointerCast;
                _ = try self.validatePointerChildType(expected_ty.pointer.child);
                const child_ty = try self.exprType(function_name, child.*);
                if (!isNumericScalarType(child_ty) or isBoolType(child_ty) or isSignedType(child_ty)) return error.UnsupportedPointerCast;
                return expected_ty;
            },
            .call => |call| {
                const callee = try self.functionForCall(call);
                if (expected_ty == .optional and typesEqual(callee.return_type, expected_ty)) return expected_ty;
                if (self.isUnionType(expected_ty) and typesEqual(callee.return_type, expected_ty)) return expected_ty;
            },
            .address_of => |address| {
                if (expected_ty != .pointer) return error.UnsupportedPointerTarget;
                const target = try self.resolveAddressTarget(function_name, address);
                defer target.deinit(self.allocator);
                if (!typesEqual(expected_ty, target.pointer_ty)) return error.UnsupportedPointerTarget;
                return expected_ty;
            },
            else => {},
        }
        return try self.exprType(function_name, expr);
    }

    fn ifExprType(self: *Emitter, function_name: []const u8, if_expr: ast.IfExpr) !ast.Type {
        if (if_expr.payload_name != null) {
            _ = try self.expectOptionalExpr(function_name, if_expr.condition.*);
        } else {
            try self.expectBoolExpr(function_name, if_expr.condition.*);
        }
        const then_ty = try self.exprType(function_name, if_expr.then_expr.*);
        const else_ty = try self.exprType(function_name, if_expr.else_expr.*);
        return commonScalarBranchType(then_ty, else_ty, error.UnsupportedIfExpressionBranches);
    }

    fn blockExprType(self: *Emitter, function_name: []const u8, block_expr: ast.BlockExpr) !ast.Type {
        var result_ty: ?ast.Type = null;
        try self.collectBlockBreakTypes(function_name, block_expr.body, block_expr.label, &result_ty);
        return result_ty orelse error.UnsupportedBlockExpressionMissingBreak;
    }

    fn blockExprTypeExpected(self: *Emitter, function_name: []const u8, block_expr: ast.BlockExpr, expected_ty: ast.Type) !ast.Type {
        var found = false;
        try self.collectBlockBreakTypesExpected(function_name, block_expr.body, block_expr.label, expected_ty, &found);
        if (!found) return error.UnsupportedBlockExpressionMissingBreak;
        return expected_ty;
    }

    fn switchExprType(self: *Emitter, function_name: []const u8, switch_expr: ast.SwitchExpr) !ast.Type {
        const operand_ty = try self.exprType(function_name, switch_expr.operand.*);
        try self.validateSwitchProngs(function_name, operand_ty, null, switch_expr.prongs);
        var result_ty: ?ast.Type = null;
        for (switch_expr.prongs) |prong| {
            const next_ty = try self.exprType(function_name, prong.value);
            result_ty = if (result_ty) |existing|
                try commonScalarBranchType(existing, next_ty, error.UnsupportedSwitchResult)
            else
                next_ty;
        }
        return result_ty orelse error.UnsupportedSwitchResult;
    }

    fn validateSwitchProngs(self: *Emitter, function_name: []const u8, operand_ty: ast.Type, stmt_prongs: ?[]const ast.SwitchStmtProng, expr_prongs: ?[]const ast.SwitchExprProng) !void {
        _ = function_name;
        if (operand_ty == .optional) {
            _ = try self.validateOptionalType(operand_ty.optional);
            var has_null = false;
            var has_else = false;
            var else_has_payload = false;
            if (stmt_prongs) |prongs| {
                for (prongs) |prong| {
                    try self.validateOptionalSwitchSelectors(prong.selectors, &has_null, &has_else);
                    if (prong.payload_name != null) {
                        if ((try self.switchPayloadTypeForSelectors(operand_ty, prong.selectors)) == null) return error.UnsupportedSwitchPayload;
                        else_has_payload = true;
                    }
                }
            }
            if (expr_prongs) |prongs| {
                for (prongs) |prong| {
                    try self.validateOptionalSwitchSelectors(prong.selectors, &has_null, &has_else);
                    if (prong.payload_name != null) {
                        if ((try self.switchPayloadTypeForSelectors(operand_ty, prong.selectors)) == null) return error.UnsupportedSwitchPayload;
                        else_has_payload = true;
                    }
                }
            }
            if (!has_else) return error.UnsupportedSwitchMissingElse;
            if (else_has_payload and !has_null) return error.UnsupportedSwitchPayload;
            return;
        }
        if (self.isUnionType(operand_ty)) {
            var ranges: std.ArrayList(SwitchCoveredRange) = .empty;
            defer ranges.deinit(self.allocator);
            var has_else = false;
            if (stmt_prongs) |prongs| {
                for (prongs) |prong| {
                    try self.validateSwitchSelectors(operand_ty, prong.selectors, &ranges, &has_else);
                    if (prong.payload_name != null and (try self.switchPayloadTypeForSelectors(operand_ty, prong.selectors)) == null) return error.UnsupportedSwitchPayload;
                }
            }
            if (expr_prongs) |prongs| {
                for (prongs) |prong| {
                    try self.validateSwitchSelectors(operand_ty, prong.selectors, &ranges, &has_else);
                    if (prong.payload_name != null and (try self.switchPayloadTypeForSelectors(operand_ty, prong.selectors)) == null) return error.UnsupportedSwitchPayload;
                }
            }
            const decl = self.program.findUnion(operand_ty.custom) orelse return error.UnsupportedStruct;
            if (!has_else and ranges.items.len < decl.fields.len) return error.UnsupportedSwitchMissingElse;
            return;
        }
        if (!isScalarSwitchType(operand_ty)) return error.UnsupportedSwitchType;
        if (operand_ty == .custom and !self.isEnumType(operand_ty)) return error.UnsupportedSwitchType;
        var ranges: std.ArrayList(SwitchCoveredRange) = .empty;
        defer ranges.deinit(self.allocator);
        var has_else = false;
        if (stmt_prongs) |prongs| {
            for (prongs) |prong| try self.validateSwitchSelectors(operand_ty, prong.selectors, &ranges, &has_else);
        }
        if (expr_prongs) |prongs| {
            for (prongs) |prong| try self.validateSwitchSelectors(operand_ty, prong.selectors, &ranges, &has_else);
        }
        if (isBoolType(operand_ty)) {
            if (!has_else and !coversBoolBoth(ranges.items)) return error.UnsupportedSwitchMissingElse;
        } else if (!has_else) {
            return error.UnsupportedSwitchMissingElse;
        }
    }

    fn validateOptionalSwitchSelectors(self: *Emitter, selectors: []const ast.SwitchSelector, has_null: *bool, has_else: *bool) !void {
        _ = self;
        for (selectors) |selector| {
            switch (selector) {
                .else_prong => {
                    if (has_else.*) return error.UnsupportedSwitchDuplicateSelector;
                    has_else.* = true;
                },
                .scalar => |value| {
                    if (value != .null) return error.UnsupportedSwitchSelector;
                    if (has_null.*) return error.UnsupportedSwitchDuplicateSelector;
                    has_null.* = true;
                },
                .range => return error.UnsupportedSwitchRange,
            }
        }
    }

    fn validateSwitchSelectors(self: *Emitter, operand_ty: ast.Type, selectors: []const ast.SwitchSelector, ranges: *std.ArrayList(SwitchCoveredRange), has_else: *bool) !void {
        for (selectors) |selector| {
            const covered = switch (selector) {
                .else_prong => blk: {
                    if (has_else.*) return error.UnsupportedSwitchDuplicateSelector;
                    has_else.* = true;
                    break :blk null;
                },
                .scalar => |value| blk: {
                    const literal = try self.validateSwitchSelectorValue(operand_ty, value);
                    break :blk SwitchCoveredRange{ .first = literal, .last = literal };
                },
                .range => |range| blk: {
                    if (self.isUnionType(operand_ty)) return error.UnsupportedSwitchRange;
                    if (isBoolType(operand_ty) or isSignedType(operand_ty)) return error.UnsupportedSwitchRange;
                    const first = try self.validateSwitchSelectorValue(operand_ty, range.first);
                    const last = try self.validateSwitchSelectorValue(operand_ty, range.last);
                    if (first > last) return error.UnsupportedSwitchRange;
                    break :blk SwitchCoveredRange{ .first = first, .last = last };
                },
            };
            if (covered) |range| {
                for (ranges.items) |existing| {
                    if (rangesOverlap(existing, range)) return error.UnsupportedSwitchDuplicateSelector;
                }
                try ranges.append(self.allocator, range);
            }
        }
    }

    fn validateSwitchSelectorValue(self: *Emitter, operand_ty: ast.Type, value: ast.Value) !u16 {
        const literal = if (self.isUnionType(operand_ty))
            @as(u16, try self.unionFieldIndex(operand_ty.custom, try self.unionSelectorName(operand_ty.custom, value)))
        else if (self.isEnumType(operand_ty))
            switch (value) {
                .field => |field| blk: {
                    if (self.program.findEnum(field.base)) |_| {
                        if (!typesEqual(operand_ty, .{ .custom = field.base })) return error.UnsupportedSwitchSelector;
                        break :blk @as(u16, try self.enumTagValue(field.base, field.field));
                    }
                    return error.UnsupportedSwitchSelector;
                },
                .enum_literal => |enum_literal| @as(u16, try self.enumLiteralValue(operand_ty, enum_literal)),
                else => return error.UnsupportedSwitchSelector,
            }
        else
            try switchSelectorLiteral(value);
        switch (operand_ty) {
            .bool => if (literal > 1) return error.UnsupportedSwitchSelector,
            .u8, .i8 => if (literal > 255) return error.UnsupportedSwitchSelector,
            .u16, .i16, .usize => {},
            .custom => {},
            else => return error.UnsupportedSwitchType,
        }
        if (isBoolType(operand_ty) and !switchSelectorIsBool(value)) return error.UnsupportedSwitchSelector;
        if (!isBoolType(operand_ty) and switchSelectorIsBool(value)) return error.UnsupportedSwitchSelector;
        return literal;
    }

    fn collectBlockBreakTypes(self: *Emitter, function_name: []const u8, statements: []const ast.Stmt, label: []const u8, result_ty: *?ast.Type) anyerror!void {
        for (statements) |stmt| {
            switch (stmt) {
                .break_expr => |break_expr| {
                    if (!std.mem.eql(u8, break_expr.label, label)) continue;
                    const next_ty = try self.exprType(function_name, break_expr.value);
                    result_ty.* = if (result_ty.*) |existing|
                        try commonScalarBranchType(existing, next_ty, error.UnsupportedBlockExpressionResult)
                    else
                        next_ty;
                },
                .while_stmt => |while_stmt| try self.collectBlockBreakTypes(function_name, while_stmt.body, label, result_ty),
                .for_stmt => |for_stmt| try self.collectBlockBreakTypes(function_name, for_stmt.body, label, result_ty),
                .switch_stmt => |switch_stmt| for (switch_stmt.prongs) |prong| try self.collectBlockBreakTypes(function_name, prong.body, label, result_ty),
                .if_stmt => |if_stmt| {
                    try self.collectBlockBreakTypes(function_name, if_stmt.then_body, label, result_ty);
                    try self.collectBlockBreakTypes(function_name, if_stmt.else_body, label, result_ty);
                },
                else => {},
            }
        }
    }

    fn collectBlockBreakTypesExpected(self: *Emitter, function_name: []const u8, statements: []const ast.Stmt, label: []const u8, expected_ty: ast.Type, found: *bool) anyerror!void {
        for (statements) |stmt| {
            switch (stmt) {
                .break_expr => |break_expr| {
                    if (!std.mem.eql(u8, break_expr.label, label)) continue;
                    _ = try self.exprTypeAllowContext(function_name, break_expr.value, expected_ty);
                    found.* = true;
                },
                .while_stmt => |while_stmt| try self.collectBlockBreakTypesExpected(function_name, while_stmt.body, label, expected_ty, found),
                .for_stmt => |for_stmt| try self.collectBlockBreakTypesExpected(function_name, for_stmt.body, label, expected_ty, found),
                .switch_stmt => |switch_stmt| for (switch_stmt.prongs) |prong| try self.collectBlockBreakTypesExpected(function_name, prong.body, label, expected_ty, found),
                .if_stmt => |if_stmt| {
                    try self.collectBlockBreakTypesExpected(function_name, if_stmt.then_body, label, expected_ty, found);
                    try self.collectBlockBreakTypesExpected(function_name, if_stmt.else_body, label, expected_ty, found);
                },
                else => {},
            }
        }
    }

    fn commonScalarBranchType(then_ty: ast.Type, else_ty: ast.Type, incompatible_err: anyerror) !ast.Type {
        if (typesEqual(then_ty, else_ty)) return then_ty;
        if (isBoolType(then_ty) or isBoolType(else_ty)) return incompatible_err;
        if (isSignedType(then_ty) or isSignedType(else_ty)) return incompatible_err;
        if (!isNumericScalarType(then_ty) or !isNumericScalarType(else_ty)) return incompatible_err;
        if (isUsizeType(then_ty) or isUsizeType(else_ty)) return .usize;
        if (isWordType(then_ty) or isWordType(else_ty)) return .u16;
        return .u8;
    }

    fn typesEqual(a: ast.Type, b: ast.Type) bool {
        return switch (a) {
            .void => b == .void,
            .bool => b == .bool,
            .u8 => b == .u8,
            .i8 => b == .i8,
            .u16 => b == .u16,
            .i16 => b == .i16,
            .usize => b == .usize,
            .far_bytes => b == .far_bytes,
            .far_view => |a_view| switch (b) {
                .far_view => |b_view| a_view.count == b_view.count and std.mem.eql(u8, a_view.type_name, b_view.type_name),
                else => false,
            },
            .near_view => |a_view| switch (b) {
                .near_view => |b_view| a_view.count == b_view.count and std.mem.eql(u8, a_view.type_name, b_view.type_name),
                else => false,
            },
            .array => |a_array| switch (b) {
                .array => |b_array| arrayTypesEqual(a_array, b_array),
                else => false,
            },
            .pointer => |a_ptr| switch (b) {
                .pointer => |b_ptr| a_ptr.is_volatile == b_ptr.is_volatile and a_ptr.is_many == b_ptr.is_many and pointerChildTypesEqual(a_ptr.child, b_ptr.child),
                else => false,
            },
            .optional => |a_optional| switch (b) {
                .optional => |b_optional| optionalChildTypesEqual(a_optional.child, b_optional.child),
                else => false,
            },
            .custom => |a_name| switch (b) {
                .custom => |b_name| std.mem.eql(u8, a_name, b_name),
                else => false,
            },
        };
    }

    fn isNumericScalarType(ty: ast.Type) bool {
        return switch (ty) {
            .u8, .i8, .u16, .i16, .usize => true,
            else => false,
        };
    }

    fn isUsizeType(ty: ast.Type) bool {
        return switch (ty) {
            .usize => true,
            else => false,
        };
    }

    fn valueType(self: *Emitter, function_name: []const u8, value: ast.Value) anyerror!ast.Type {
        return switch (value) {
            .int => |n| if (n > 255) ast.Type.u16 else ast.Type.u8,
            .bool => .bool,
            .char => .u8,
            .null => error.UnsupportedOptional,
            .ident => |ident| blk: {
                break :blk (try self.expectBinding(function_name, ident)).ty;
            },
            .field => |field| blk: {
                if (self.program.findEnum(field.base)) |_| break :blk .{ .custom = field.base };
                const maybe_binding = self.findBinding(function_name, field.base) catch |err| switch (err) {
                    error.UnknownVariable => null,
                    else => return err,
                };
                if (maybe_binding) |binding| {
                    if (binding.ty == .pointer and std.mem.eql(u8, field.field, "len")) return error.UnsupportedPointerTarget;
                    if (binding.ty == .far_view and std.mem.eql(u8, field.field, "len")) break :blk ast.Type.usize;
                    if (binding.ty == .near_view and std.mem.eql(u8, field.field, "len")) break :blk ast.Type.usize;
                    if (self.isUnionType(binding.ty)) return error.UnsupportedStruct;
                    if (self.isStructType(binding.ty)) {
                        if (try self.resolveStructPathType(binding.ty.custom, field.field)) |ty| break :blk ty;
                    }
                }
                const flat_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ field.base, field.field });
                defer self.allocator.free(flat_name);
                if (std.mem.eql(u8, field.field, "len")) {
                    if (try self.resolvePointerStructArrayPath(function_name, field.base)) |path| {
                        path.deinit(self.allocator);
                        break :blk ast.Type.usize;
                    }
                }
                if (try self.resolvePointerStructPath(function_name, flat_name)) |path| {
                    defer path.deinit(self.allocator);
                    if (isArrayType(path.ty) or self.isStructType(path.ty)) return error.UnsupportedPointerTarget;
                    break :blk path.ty;
                }
                if (std.mem.eql(u8, field.field, "len")) {
                    const maybe_ref: ?ArrayRef = self.resolveArray(function_name, field.base) catch |err| switch (err) {
                        error.UnknownVariable => null,
                        else => return err,
                    };
                    if (maybe_ref) |ref| {
                        defer ref.deinit(self.allocator);
                        break :blk ast.Type.usize;
                    }
                }
                break :blk ast.Type.u8;
            },
            .enum_literal => return error.UnsupportedEnumLiteral,
        };
    }

    fn functionForCall(self: *Emitter, call: ast.CallExpr) !ast.Function {
        const target_label = try self.labelForTarget(call.target);
        defer self.allocator.free(target_label);
        return self.findFunction(target_label) orelse error.UnknownFunction;
    }

    fn reuViewCall(self: *Emitter, function_name: []const u8, call: ast.CallExpr, expected_member: []const u8) !?ReuViewCall {
        const dot = std.mem.indexOfScalar(u8, call.target, '.') orelse return null;
        const view_name = call.target[0..dot];
        const member = call.target[dot + 1 ..];
        if (!std.mem.eql(u8, member, expected_member)) return null;
        const binding = self.findBinding(function_name, view_name) catch |err| switch (err) {
            error.UnknownVariable => return null,
            else => return err,
        };
        const found = binding orelse return null;
        if (found.ty != .far_view) return null;
        _ = try self.validateFarViewStruct(found.ty.far_view.type_name, found.ty.far_view.count);
        return .{ .name = view_name, .view = found.ty.far_view };
    }

    fn nearViewCall(self: *Emitter, function_name: []const u8, call: ast.CallExpr, expected_member: []const u8) !?ReuViewCall {
        const dot = std.mem.indexOfScalar(u8, call.target, '.') orelse return null;
        const view_name = call.target[0..dot];
        const member = call.target[dot + 1 ..];
        if (!std.mem.eql(u8, member, expected_member)) return null;
        const binding = self.findBinding(function_name, view_name) catch |err| switch (err) {
            error.UnknownVariable => return null,
            else => return err,
        };
        const found = binding orelse return null;
        if (found.ty != .near_view) return null;
        _ = try self.validateFarViewStruct(found.ty.near_view.type_name, found.ty.near_view.count);
        return .{ .name = view_name, .view = found.ty.near_view };
    }

    fn emitCmp(self: *Emitter, function_name: []const u8, value: ast.Value) !void {
        const w = &self.out.writer;
        switch (value) {
            .int => |n| try w.print("    cmp #{d}\n", .{@as(u8, @truncate(n))}),
            .bool => |b| try w.print("    cmp #{d}\n", .{@intFromBool(b)}),
            .char => |ch| try w.print("    cmp #{d}\n", .{screenCode(ch)}),
            .ident => |ident| try w.print("    cmp {s}_{s}\n", .{ function_name, ident }),
            .field => |field| {
                const flat_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ field.base, field.field });
                defer self.allocator.free(flat_name);
                if (try self.resolvePointerStructPath(function_name, flat_name)) |path| {
                    defer path.deinit(self.allocator);
                    if (isArrayType(path.ty) or self.isStructType(path.ty)) return error.UnsupportedPointerTarget;
                    self.uses_math_tmp = true;
                    try w.writeAll("    pha\n");
                    try self.emitPointerStructPathToA(function_name, flat_name);
                    try w.writeAll("    sta zeropage_math_tmp\n    pla\n    cmp zeropage_math_tmp\n");
                } else {
                    try w.print("    cmp {s}_{s}_{s}\n", .{ function_name, field.base, field.field });
                }
            },
            .enum_literal => return error.UnsupportedEnumLiteral,
        }
    }

    fn emitAdc(self: *Emitter, function_name: []const u8, value: ast.Value) !void {
        const w = &self.out.writer;
        switch (value) {
            .int => |n| try w.print("    adc #{d}\n", .{@as(u8, @truncate(n))}),
            .bool => |b| try w.print("    adc #{d}\n", .{@intFromBool(b)}),
            .char => |ch| try w.print("    adc #{d}\n", .{screenCode(ch)}),
            .ident => |ident| try w.print("    adc {s}_{s}\n", .{ function_name, ident }),
            .field => |field| {
                const flat_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ field.base, field.field });
                defer self.allocator.free(flat_name);
                if (try self.resolvePointerStructPath(function_name, flat_name)) |path| {
                    defer path.deinit(self.allocator);
                    if (isArrayType(path.ty) or self.isStructType(path.ty)) return error.UnsupportedPointerTarget;
                    self.uses_math_tmp = true;
                    try w.writeAll("    pha\n");
                    try self.emitPointerStructPathToA(function_name, flat_name);
                    try w.writeAll("    sta zeropage_math_tmp\n    pla\n    adc zeropage_math_tmp\n");
                } else {
                    try w.print("    adc {s}_{s}_{s}\n", .{ function_name, field.base, field.field });
                }
            },
            .enum_literal => return error.UnsupportedEnumLiteral,
        }
    }

    fn emitBuiltin(self: *Emitter, function_name: []const u8, builtin: ast.BuiltinCall) !void {
        try c64_emit.emitBuiltin(self, function_name, builtin);
    }

    fn emitConsoleClear(self: *Emitter, function_name: []const u8) !void {
        try c64_emit.emitConsoleClear(self, function_name);
    }

    fn emitConsolePrint(self: *Emitter, function_name: []const u8, print: ast.ConsolePrint) !void {
        try c64_emit.emitConsolePrint(self, function_name, print);
    }

    fn emitConsoleLiteral(self: *Emitter, function_name: []const u8, text: []const u8) !void {
        try c64_emit.emitConsoleLiteral(self, function_name, text);
    }

    fn emitConsoleChar(self: *Emitter, function_name: []const u8, ch: u8) !void {
        try c64_emit.emitConsoleChar(self, function_name, ch);
    }

    fn emitConsolePuts(self: *Emitter, function_name: []const u8, value: ast.Value) !void {
        try c64_emit.emitConsolePuts(self, function_name, value);
    }

    fn emitConsoleStringExpr(self: *Emitter, function_name: []const u8, expr: ast.Expr) !void {
        try c64_emit.emitConsoleStringExpr(self, function_name, expr);
    }

    pub fn emitConsoleRuntimeCall(self: *Emitter, function_name: []const u8, routine: []const u8) !void {
        const label = try self.consoleRuntimeLabel(function_name, routine);
        if (try self.functionIsReachableModuleFunction(function_name)) {
            try self.emitRelocatableJsr(label);
            return;
        }
        try self.out.writer.print("    jsr {s}\n", .{label});
    }

    fn consoleRuntimeLabel(self: *Emitter, function_name: []const u8, routine: []const u8) ![]const u8 {
        if (!try self.functionUsesKernalConsoleTrampoline(function_name)) return routine;
        self.uses_module_bank_runtime = true;
        self.uses_module_kernal_console_trampoline = true;
        self.uses_clear_screen = true;
        if (std.mem.eql(u8, routine, "consolePutHexByte")) {
            self.uses_hex = true;
            self.uses_console_hex = true;
        }
        if (std.mem.eql(u8, routine, "consoleClear")) {
            self.uses_module_kernal_console_clear_trampoline = true;
            return "zeropage_module_kernal_trampoline_console_clear";
        }
        if (std.mem.eql(u8, routine, "consoleNewline")) {
            self.uses_module_kernal_console_newline_trampoline = true;
            return "zeropage_module_kernal_trampoline_console_newline";
        }
        if (std.mem.eql(u8, routine, "consolePutChar")) {
            self.uses_module_kernal_console_put_char_trampoline = true;
            return "zeropage_module_kernal_trampoline_console_put_char";
        }
        if (std.mem.eql(u8, routine, "consolePutString")) {
            self.uses_module_kernal_console_put_string_trampoline = true;
            return "zeropage_module_kernal_trampoline_console_put_string";
        }
        if (std.mem.eql(u8, routine, "consolePutHexByte")) {
            self.uses_module_kernal_console_put_hex_byte_trampoline = true;
            return "zeropage_module_kernal_trampoline_console_put_hex_byte";
        }
        return routine;
    }

    fn functionUsesKernalConsoleTrampoline(self: *Emitter, function_name: []const u8) !bool {
        const loader = self.program.zeropage_options.modules orelse return false;
        if (loader.load_window.bank != .ram_under_kernal) return false;
        return try self.functionIsReachableModuleFunction(function_name);
    }

    fn functionIsReachableModuleFunction(self: *Emitter, function_name: []const u8) !bool {
        _ = self.program.zeropage_module orelse return false;
        var reachable = try self.collectReachableModuleFunctions();
        defer reachable.deinit();
        return reachable.contains(function_name);
    }

    fn emitStringAppend(self: *Emitter, function_name: []const u8, append: ast.StringAppend) !void {
        try c64_emit.emitStringAppend(self, function_name, append);
    }

    fn emitStringClear(self: *Emitter, function_name: []const u8, value: ast.Value) !void {
        try c64_emit.emitStringClear(self, function_name, value);
    }

    fn emitKernalPuts(self: *Emitter, function_name: []const u8, value: ast.Value) !void {
        try c64_emit.emitKernalPuts(self, function_name, value);
    }

    fn emitKernalSetName(self: *Emitter, function_name: []const u8, value: ast.Value) !void {
        try c64_emit.emitKernalSetName(self, function_name, value);
    }

    fn emitAppendStringExpr(self: *Emitter, function_name: []const u8, buffer: StringBufferRef, expr: ast.StringExpr) !void {
        try c64_emit.emitAppendStringExpr(self, function_name, buffer, expr);
    }

    fn emitAppendByteToBuffer(self: *Emitter, buffer: StringBufferRef, byte: u8) !void {
        try c64_emit.emitAppendByteToBuffer(self, buffer, byte);
    }

    fn emitAppendStringSource(self: *Emitter, buffer: StringBufferRef, source: StringSource) !void {
        try c64_emit.emitAppendStringSource(self, buffer, source);
    }

    pub fn emitLoadStringSourcePointer(self: *Emitter, pointer_name: []const u8, source: StringSource) !void {
        try c64_emit.emitLoadStringSourcePointer(self, pointer_name, source);
    }

    pub fn emitStringSourceLenToA(self: *Emitter, source: StringSource) !void {
        try c64_emit.emitStringSourceLenToA(self, source);
    }

    pub fn resolveStringSource(self: *Emitter, function_name: []const u8, value: ast.Value) !StringSource {
        return c64_emit.resolveStringSource(self, function_name, value);
    }

    fn emitConsoleHexExpr(self: *Emitter, function_name: []const u8, expr: ast.Expr) !void {
        try c64_emit.emitConsoleHexExpr(self, function_name, expr);
    }

    fn emitConsoleHex16Expr(self: *Emitter, function_name: []const u8, expr: ast.Expr) !void {
        try c64_emit.emitConsoleHex16Expr(self, function_name, expr);
    }

    fn emitSleepTicks(self: *Emitter, function_name: []const u8, sleep: ast.SleepTicks) !void {
        try c64_emit.emitSleepTicks(self, function_name, sleep);
    }

    fn emitSleepFrames(self: *Emitter, function_name: []const u8, sleep: ast.SleepTicks) !void {
        try c64_emit.emitSleepFrames(self, function_name, sleep);
    }

    fn emitKeyboardReadPetscii(self: *Emitter) !void {
        try c64_emit.emitKeyboardReadPetscii(self);
    }

    fn emitKeyboardWaitPetscii(self: *Emitter) !void {
        try c64_emit.emitKeyboardWaitPetscii(self);
    }

    fn emitPutsAt(self: *Emitter, puts: ast.PutsAt) !void {
        try c64_emit.emitPutsAt(self, puts);
    }

    fn emitPutAt(self: *Emitter, function_name: []const u8, put: ast.PutAt) !void {
        try c64_emit.emitPutAt(self, function_name, put);
    }

    fn emitHexAt(self: *Emitter, function_name: []const u8, hex: ast.HexAt) !void {
        try c64_emit.emitHexAt(self, function_name, hex);
    }

    fn emitHex16At(self: *Emitter, function_name: []const u8, hex: ast.HexAt) !void {
        try c64_emit.emitHex16At(self, function_name, hex);
    }

    fn emitHexByteAt(self: *Emitter, screen_start: u16) !void {
        try c64_emit.emitHexByteAt(self, screen_start);
    }

    fn emitValueToX(self: *Emitter, function_name: []const u8, value: ast.Value) !void {
        try c64_emit.emitValueToX(self, function_name, value);
    }

    fn emitClearScreenRoutine(self: *Emitter) !void {
        try runtime.emitClearScreenRoutine(&self.out.writer);
    }

    fn emitConsoleRoutines(self: *Emitter) !void {
        if (self.uses_module_kernal_console_trampoline) return self.emitRelocatableConsoleRoutines();
        try runtime.emitConsoleRoutines(&self.out.writer);
    }

    fn emitConsoleHexRoutine(self: *Emitter) !void {
        if (self.uses_module_kernal_console_trampoline) return self.emitRelocatableConsoleHexRoutine();
        try runtime.emitConsoleHexRoutine(&self.out.writer);
    }

    fn emitRelocatableConsoleRoutines(self: *Emitter) !void {
        const w = &self.out.writer;
        try w.writeAll("consoleClear:\n");
        try self.emitRelocatableJsr("clearScreen");
        try w.writeAll("    lda #0\n");
        try self.emitRelocatableAbsInstruction("sta", "zeropage_console_x");
        try self.emitRelocatableAbsInstruction("sta", "zeropage_console_y");
        try w.writeAll(
            \\    rts
            \\
            \\consolePutChar:
            \\
        );
        try self.emitRelocatableAbsInstruction("sta", "zeropage_console_char_tmp");
        try self.emitRelocatableAbsInstruction("ldy", "zeropage_console_y");
        try self.emitRelocatableAbsInstructionSuffix("lda", "consoleScreenRowLo", ",y");
        try w.writeAll("    sta zeropage_console_ptr\n");
        try self.emitRelocatableAbsInstructionSuffix("lda", "consoleScreenRowHi", ",y");
        try w.writeAll("    sta zeropage_console_ptr+1\n");
        try self.emitRelocatableAbsInstruction("ldy", "zeropage_console_x");
        try self.emitRelocatableAbsInstruction("lda", "zeropage_console_char_tmp");
        try w.writeAll("    sta (zeropage_console_ptr),y\n");
        try self.emitRelocatableAbsInstruction("ldy", "zeropage_console_y");
        try self.emitRelocatableAbsInstructionSuffix("lda", "consoleColorRowLo", ",y");
        try w.writeAll("    sta zeropage_console_ptr\n");
        try self.emitRelocatableAbsInstructionSuffix("lda", "consoleColorRowHi", ",y");
        try w.writeAll("    sta zeropage_console_ptr+1\n");
        try self.emitRelocatableAbsInstruction("ldy", "zeropage_console_x");
        try w.writeAll("    lda #1\n    sta (zeropage_console_ptr),y\n");
        try self.emitRelocatableAbsInstruction("inc", "zeropage_console_x");
        try self.emitRelocatableAbsInstruction("lda", "zeropage_console_x");
        try w.writeAll("    cmp #40\n    bcc consolePutCharDone\n");
        try self.emitRelocatableJsr("consoleNewline");
        try w.writeAll(
            \\consolePutCharDone:
            \\    rts
            \\
            \\consoleNewline:
            \\    lda #0
            \\
        );
        try self.emitRelocatableAbsInstruction("sta", "zeropage_console_x");
        try self.emitRelocatableAbsInstruction("inc", "zeropage_console_y");
        try self.emitRelocatableAbsInstruction("lda", "zeropage_console_y");
        try w.writeAll("    cmp #25\n    bcc consoleNewlineDone\n    lda #24\n");
        try self.emitRelocatableAbsInstruction("sta", "zeropage_console_y");
        try self.emitRelocatableJsr("consoleScroll");
        try w.writeAll(
            \\consoleNewlineDone:
            \\    rts
            \\
            \\consolePutString:
            \\
        );
        try self.emitRelocatableAbsInstruction("sta", "zeropage_console_string_len");
        try w.writeAll("    lda #0\n");
        try self.emitRelocatableAbsInstruction("sta", "zeropage_console_string_index");
        try w.writeAll("consolePutStringLoop:\n");
        try self.emitRelocatableAbsInstruction("lda", "zeropage_console_string_index");
        try self.emitRelocatableAbsInstruction("cmp", "zeropage_console_string_len");
        try w.writeAll("    beq consolePutStringDone\n    tay\n    lda (zeropage_string_ptr),y\n    cmp #10\n    beq consolePutStringNewline\n    cmp #13\n    beq consolePutStringNewline\n");
        try self.emitRelocatableJsr("petsciiToScreen");
        try self.emitRelocatableJsr("consolePutChar");
        try self.emitRelocatableJmp("consolePutStringNext");
        try w.writeAll("consolePutStringNewline:\n");
        try self.emitRelocatableJsr("consoleNewline");
        try w.writeAll("consolePutStringNext:\n");
        try self.emitRelocatableAbsInstruction("inc", "zeropage_console_string_index");
        try self.emitRelocatableJmp("consolePutStringLoop");
        try w.writeAll(
            \\consolePutStringDone:
            \\    rts
            \\
            \\petsciiToScreen:
            \\    cmp #65
            \\    bcc petsciiToScreenMaybeLower
            \\    cmp #91
            \\    bcs petsciiToScreenMaybeLower
            \\    sec
            \\    sbc #64
            \\    rts
            \\petsciiToScreenMaybeLower:
            \\    cmp #97
            \\    bcc petsciiToScreenDone
            \\    cmp #123
            \\    bcs petsciiToScreenDone
            \\    sec
            \\    sbc #96
            \\petsciiToScreenDone:
            \\    rts
            \\
            \\consoleScroll:
            \\    ldx #0
            \\consoleScrollPage:
            \\    lda $0428,x
            \\    sta $0400,x
            \\    lda $0528,x
            \\    sta $0500,x
            \\    lda $0628,x
            \\    sta $0600,x
            \\    lda $d828,x
            \\    sta $d800,x
            \\    lda $d928,x
            \\    sta $d900,x
            \\    lda $da28,x
            \\    sta $da00,x
            \\    inx
            \\    bne consoleScrollPage
            \\    ldx #0
            \\consoleScrollTail:
            \\    lda $0728,x
            \\    sta $0700,x
            \\    lda $db28,x
            \\    sta $db00,x
            \\    inx
            \\    cpx #192
            \\    bne consoleScrollTail
            \\    ldx #0
            \\    lda #32
            \\consoleClearLastLine:
            \\    sta $07c0,x
            \\    inx
            \\    cpx #40
            \\    bne consoleClearLastLine
            \\    ldx #0
            \\    lda #1
            \\consoleColorLastLine:
            \\    sta $dbc0,x
            \\    inx
            \\    cpx #40
            \\    bne consoleColorLastLine
            \\    rts
            \\
            \\consoleScreenRowLo:
            \\    .byte <$0400,<$0428,<$0450,<$0478,<$04a0,<$04c8,<$04f0,<$0518,<$0540,<$0568,<$0590,<$05b8,<$05e0,<$0608,<$0630,<$0658,<$0680,<$06a8,<$06d0,<$06f8,<$0720,<$0748,<$0770,<$0798,<$07c0
            \\consoleScreenRowHi:
            \\    .byte >$0400,>$0428,>$0450,>$0478,>$04a0,>$04c8,>$04f0,>$0518,>$0540,>$0568,>$0590,>$05b8,>$05e0,>$0608,>$0630,>$0658,>$0680,>$06a8,>$06d0,>$06f8,>$0720,>$0748,>$0770,>$0798,>$07c0
            \\consoleColorRowLo:
            \\    .byte <$d800,<$d828,<$d850,<$d878,<$d8a0,<$d8c8,<$d8f0,<$d918,<$d940,<$d968,<$d990,<$d9b8,<$d9e0,<$da08,<$da30,<$da58,<$da80,<$daa8,<$dad0,<$daf8,<$db20,<$db48,<$db70,<$db98,<$dbc0
            \\consoleColorRowHi:
            \\    .byte >$d800,>$d828,>$d850,>$d878,>$d8a0,>$d8c8,>$d8f0,>$d918,>$d940,>$d968,>$d990,>$d9b8,>$d9e0,>$da08,>$da30,>$da58,>$da80,>$daa8,>$dad0,>$daf8,>$db20,>$db48,>$db70,>$db98,>$dbc0
            \\
        );
    }

    fn emitRelocatableConsoleHexRoutine(self: *Emitter) !void {
        const w = &self.out.writer;
        try w.writeAll("consolePutHexByte:\n");
        try self.emitRelocatableAbsInstruction("sta", "zeropage_hex_tmp");
        try w.writeAll("    lsr\n    lsr\n    lsr\n    lsr\n");
        try self.emitRelocatableJsr("hexNibbleToScreen");
        try self.emitRelocatableJsr("consolePutChar");
        try self.emitRelocatableAbsInstruction("lda", "zeropage_hex_tmp");
        try self.emitRelocatableJsr("hexNibbleToScreen");
        try self.emitRelocatableJsr("consolePutChar");
        try w.writeAll("    rts\n\n");
    }

    fn emitKernalStringRoutine(self: *Emitter) !void {
        try runtime.emitKernalStringRoutine(&self.out.writer);
    }

    fn emitKeyboardWaitRoutine(self: *Emitter) !void {
        try runtime.emitKeyboardWaitRoutine(&self.out.writer);
    }

    fn emitStringRuntimeRoutine(self: *Emitter) !void {
        try runtime.emitStringRuntimeRoutine(&self.out.writer);
    }

    fn emitHexNibbleRoutine(self: *Emitter) !void {
        try runtime.emitHexNibbleRoutine(&self.out.writer);
    }

    fn emitMultiplyRoutine(self: *Emitter) !void {
        try runtime.emitMultiplyRoutine(&self.out.writer);
    }

    fn emitShiftRoutines(self: *Emitter) !void {
        if (self.program.zeropage_module != null) {
            try runtime.emitShiftRoutines(&self.out.writer);
        } else try self.shift_usage.emitHelpers(&self.out.writer);
    }

    fn emitSleepRoutine(self: *Emitter) !void {
        try runtime.emitSleepRoutine(&self.out.writer);
    }

    fn emitSleepFramesRoutine(self: *Emitter) !void {
        try runtime.emitSleepFramesRoutine(&self.out.writer);
    }

    fn emitReuRoutines(self: *Emitter) !void {
        const w = &self.out.writer;
        try sections.emitBegin(w, .runtime, .code, .static, .near);
        if (self.uses_reu_present) {
            try w.writeAll(
                \\zeropage_reu_present:
                \\    lda $df00
                \\    cmp #$ff
                \\    beq zeropage_reu_present_no
                \\    lda #1
                \\    rts
                \\zeropage_reu_present_no:
                \\    lda #0
                \\    rts
                \\
            );
        }
        if (self.uses_reu_copy_c64_to_reu) {
            try w.writeAll(
                \\zeropage_reu_copy_c64_to_reu:
                \\    jsr zeropage_reu_setup_increment
                \\    lda #$90
                \\    sta $df01
                \\    rts
                \\
            );
        }
        if (self.uses_reu_copy_reu_to_c64) {
            try w.writeAll(
                \\zeropage_reu_copy_reu_to_c64:
                \\    jsr zeropage_reu_setup_increment
                \\    lda #$91
                \\    sta $df01
                \\    rts
                \\
            );
        }
        if (self.uses_reu_swap) {
            try w.writeAll(
                \\zeropage_reu_swap:
                \\    jsr zeropage_reu_setup_increment
                \\    lda #$92
                \\    sta $df01
                \\    rts
                \\
            );
        }
        if (self.uses_reu_compare) {
            try w.writeAll(
                \\zeropage_reu_compare:
                \\    jsr zeropage_reu_setup_increment
                \\    lda #$93
                \\    sta $df01
                \\    lda $df00
                \\    and #$20
                \\    beq zeropage_reu_compare_equal
                \\    lda #0
                \\    rts
                \\zeropage_reu_compare_equal:
                \\    lda #1
                \\    rts
                \\
            );
        }
        if (self.uses_reu_fill) {
            try w.writeAll(
                \\zeropage_reu_fill:
                \\    lda #<zeropage_reu_fill_byte
                \\    sta zeropage_reu_c64_addr
                \\    lda #>zeropage_reu_fill_byte
                \\    sta zeropage_reu_c64_addr+1
                \\    jsr zeropage_reu_setup_fixed_c64
                \\    lda #$90
                \\    sta $df01
                \\    rts
                \\
            );
        }
        if (self.usesReuTransferRuntime()) {
            try w.writeAll(
                \\zeropage_reu_setup_increment:
                \\    lda #$00
                \\    sta $df0a
                \\    jmp zeropage_reu_setup_common
                \\zeropage_reu_setup_fixed_c64:
                \\    lda #$80
                \\    sta $df0a
                \\zeropage_reu_setup_common:
                \\    lda zeropage_reu_c64_addr
                \\    sta $df02
                \\    lda zeropage_reu_c64_addr+1
                \\    sta $df03
                \\    lda zeropage_reu_addr
                \\    sta $df04
                \\    lda zeropage_reu_addr+1
                \\    sta $df05
                \\    lda zeropage_reu_addr+2
                \\    sta $df06
                \\    lda zeropage_reu_len
                \\    sta $df07
                \\    lda zeropage_reu_len+1
                \\    sta $df08
                \\    lda #$00
                \\    sta $df09
                \\    rts
                \\
            );
        }
        if (self.uses_module_bank_runtime) try self.emitModuleBankRoutines();
        if (self.uses_module_load_runtime) try self.emitModuleLoaderRoutine();
        if (self.uses_module_disk_load_runtime) try self.emitModuleDiskLoaderRoutine();
        if (self.uses_module_dependency_load_runtime) try self.emitModuleDependencyLoaderRoutines();
        if (self.uses_module_state_runtime) try self.emitModuleStateRoutines();
        if (self.uses_module_current_activation_runtime) try self.emitModuleCurrentActivationRoutine();
        if (self.uses_module_dependency_activation_runtime) try self.emitModuleDependencyActivationRoutines();
        if (self.uses_module_dependency_unload_runtime) try self.emitModuleDependencyUnloadRoutines();
        if (self.uses_module_registry_runtime) try self.emitModuleIsLoadedRoutine();
        if (self.uses_module_unload_runtime) try self.emitModuleUnloadRoutine();
        if (self.usesReuHeapRuntime()) try self.emitReuHeapRoutines();
        try sections.emitEnd(w, .runtime, .code);
    }

    fn emitModuleBankRoutines(self: *Emitter) !void {
        try self.out.writer.writeAll(
            \\zeropage_module_bank_enter_basic:
            \\    lda $0001
            \\    sta zeropage_module_bank_saved_port
            \\    and #$fe
            \\    sta $0001
            \\    rts
            \\zeropage_module_bank_exit_basic:
            \\    lda zeropage_module_bank_saved_port
            \\    sta $0001
            \\    rts
            \\zeropage_module_bank_enter_kernal:
            \\    php
            \\    pla
            \\    sta zeropage_module_bank_saved_status
            \\    sei
            \\    lda $0001
            \\    sta zeropage_module_bank_saved_port
            \\    and #$fd
            \\    sta $0001
            \\    rts
            \\zeropage_module_bank_exit_kernal:
            \\    lda zeropage_module_bank_saved_port
            \\    sta $0001
            \\    lda zeropage_module_bank_saved_status
            \\    pha
            \\    plp
            \\    rts
            \\
        );
    }

    fn emitModuleKernalConsoleTrampolines(self: *Emitter) !void {
        try self.out.writer.writeAll(
            \\zeropage_module_kernal_trampoline_enter:
            \\    php
            \\    pla
            \\
        );
        try self.emitRelocatableAbsInstruction("sta", "zeropage_module_kernal_trampoline_saved_status");
        try self.out.writer.writeAll(
            \\    rts
            \\zeropage_module_kernal_trampoline_exit:
            \\
        );
        try self.emitRelocatableAbsInstruction("lda", "zeropage_module_kernal_trampoline_saved_status");
        try self.out.writer.writeAll(
            \\    pha
            \\    plp
            \\    rts
            \\
        );
        if (self.uses_module_kernal_console_clear_trampoline) {
            try self.out.writer.writeAll("zeropage_module_kernal_trampoline_console_clear:\n");
            try self.emitRelocatableJsr("zeropage_module_kernal_trampoline_enter");
            try self.emitRelocatableJsr("consoleClear");
            try self.emitRelocatableJsr("zeropage_module_kernal_trampoline_exit");
            try self.out.writer.writeAll("    rts\n");
        }
        if (self.uses_module_kernal_console_newline_trampoline) {
            try self.out.writer.writeAll("zeropage_module_kernal_trampoline_console_newline:\n");
            try self.emitRelocatableJsr("zeropage_module_kernal_trampoline_enter");
            try self.emitRelocatableJsr("consoleNewline");
            try self.emitRelocatableJsr("zeropage_module_kernal_trampoline_exit");
            try self.out.writer.writeAll("    rts\n");
        }
        if (self.uses_module_kernal_console_put_char_trampoline) {
            try self.out.writer.writeAll("zeropage_module_kernal_trampoline_console_put_char:\n");
            try self.emitRelocatableAbsInstruction("sta", "zeropage_module_bank_saved_a");
            try self.emitRelocatableJsr("zeropage_module_kernal_trampoline_enter");
            try self.emitRelocatableAbsInstruction("lda", "zeropage_module_bank_saved_a");
            try self.emitRelocatableJsr("consolePutChar");
            try self.emitRelocatableJsr("zeropage_module_kernal_trampoline_exit");
            try self.out.writer.writeAll("    rts\n");
        }
        if (self.uses_module_kernal_console_put_string_trampoline) {
            try self.out.writer.writeAll("zeropage_module_kernal_trampoline_console_put_string:\n");
            try self.emitRelocatableAbsInstruction("sta", "zeropage_module_bank_saved_a");
            try self.emitRelocatableJsr("zeropage_module_kernal_trampoline_enter");
            try self.emitRelocatableAbsInstruction("lda", "zeropage_module_bank_saved_a");
            try self.emitRelocatableJsr("consolePutString");
            try self.emitRelocatableJsr("zeropage_module_kernal_trampoline_exit");
            try self.out.writer.writeAll("    rts\n");
        }
        if (self.uses_module_kernal_console_put_hex_byte_trampoline) {
            try self.out.writer.writeAll("zeropage_module_kernal_trampoline_console_put_hex_byte:\n");
            try self.emitRelocatableAbsInstruction("sta", "zeropage_module_bank_saved_a");
            try self.emitRelocatableJsr("zeropage_module_kernal_trampoline_enter");
            try self.emitRelocatableAbsInstruction("lda", "zeropage_module_bank_saved_a");
            try self.emitRelocatableJsr("consolePutHexByte");
            try self.emitRelocatableJsr("zeropage_module_kernal_trampoline_exit");
            try self.out.writer.writeAll("    rts\n");
        }
        try self.out.writer.writeAll("\n");
    }

    fn emitModuleLoaderRoutine(self: *Emitter) !void {
        const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
        const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
        const jump_table_len: u16 = @intCast(module.exports.len * 3);
        const cache_body_addr = loader.reu_cache.addr + jump_table_len;
        const w = &self.out.writer;
        try w.writeAll(
            \\zeropage_module_load_current:
            \\    lda zeropage_module_registry_loaded
            \\    beq zeropage_module_load_current_not_loaded
            \\    jsr zeropage_module_activate_current
            \\    rts
            \\zeropage_module_load_current_not_loaded:
            \\    jsr zeropage_reu_present
            \\    cmp #0
            \\    bne zeropage_module_load_current_present
            \\    lda #0
            \\    rts
            \\zeropage_module_load_current_present:
            \\
        );
        try self.emitModuleLoaderCopySetup("zeropage_module_payload_jump_table", loader.reu_cache.addr, "zeropage_module_payload_jump_table_end-zeropage_module_payload_jump_table");
        try w.writeAll("    jsr zeropage_reu_copy_c64_to_reu\n");
        try self.emitModuleLoaderCopySetup("zeropage_module_payload_range_start", cache_body_addr, "zeropage_module_payload_range_end-zeropage_module_payload_range_start");
        try w.writeAll("    jsr zeropage_reu_copy_c64_to_reu\n");
        if (self.moduleWindowIsBanked(loader.load_window)) try self.emitModuleBankBegin(loader.load_window);
        if (self.hasPersistentDependencyModuleState()) try w.writeAll("    jsr zeropage_module_state_save_active_dependency\n");
        try self.emitModuleLoaderFetchSetup(loader.load_window.addr, loader.reu_cache.addr, jump_table_len);
        try w.writeAll("    jsr zeropage_reu_copy_reu_to_c64\n");
        try self.emitModuleLoaderJumpTablePatches(loader.load_window.addr, jump_table_len);
        for (self.module_relocations.items) |relocation| try self.emitModuleLoaderRelocationPatch(loader.load_window.addr, jump_table_len, relocation);
        if (self.currentModuleState() != null) try w.writeAll("    jsr zeropage_module_state_restore_current\n");
        if (self.moduleWindowIsBanked(loader.load_window)) try self.emitModuleBankEnd(loader.load_window);
        try w.writeAll(
            \\    lda #1
            \\    sta zeropage_module_registry_loaded
            \\    sta zeropage_module_registry_refcount
            \\    lda #0
            \\    sta zeropage_module_registry_active_row
            \\    lda #1
            \\    rts
            \\
        );
    }

    fn emitModuleDiskLoaderRoutine(self: *Emitter) !void {
        const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
        const staging = loader.disk_staging orelse return error.MissingZeroPageModuleLoader;
        const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
        const jump_table_len: u16 = @intCast(module.exports.len * 3);
        const w = &self.out.writer;
        try w.print(
            \\zeropage_module_load_from_disk_current:
            \\    lda zeropage_module_registry_loaded
            \\    beq zeropage_module_load_from_disk_not_loaded
            \\    jsr zeropage_module_activate_current
            \\    rts
            \\zeropage_module_load_from_disk_not_loaded:
            \\    jsr zeropage_reu_present
            \\    cmp #0
            \\    bne zeropage_module_load_from_disk_present
            \\    lda #0
            \\    rts
            \\zeropage_module_load_from_disk_present:
            \\    lda #<(zeropage_module_disk_filename_end-zeropage_module_disk_filename)
            \\    ldx #<zeropage_module_disk_filename
            \\    ldy #>zeropage_module_disk_filename
            \\    jsr $ffbd
            \\    lda #1
            \\    ldx #8
            \\    ldy #0
            \\    jsr $ffba
            \\    lda #0
            \\    ldx #${x:0>2}
            \\    ldy #${x:0>2}
            \\    jsr $ffd5
            \\    bcc zeropage_module_load_from_disk_loaded
            \\    lda #0
            \\    rts
            \\zeropage_module_load_from_disk_loaded:
            \\
        , .{ @as(u8, @truncate(staging.addr)), @as(u8, @truncate(staging.addr >> 8)) });
        try self.emitModuleLoaderCopySetupImmediate(staging.addr, loader.reu_cache.addr, "zeropage_module_registry_payload_size");
        try w.writeAll("    jsr zeropage_reu_copy_c64_to_reu\n");
        if (self.moduleWindowIsBanked(loader.load_window)) try self.emitModuleBankBegin(loader.load_window);
        if (self.hasPersistentDependencyModuleState()) try w.writeAll("    jsr zeropage_module_state_save_active_dependency\n");
        try self.emitModuleLoaderFetchSetup(loader.load_window.addr, loader.reu_cache.addr, jump_table_len);
        try w.writeAll("    jsr zeropage_reu_copy_reu_to_c64\n");
        try self.emitModuleLoaderJumpTablePatches(loader.load_window.addr, jump_table_len);
        for (self.module_relocations.items) |relocation| try self.emitModuleLoaderRelocationPatch(loader.load_window.addr, jump_table_len, relocation);
        if (self.currentModuleState() != null) try w.writeAll("    jsr zeropage_module_state_restore_current\n");
        if (self.moduleWindowIsBanked(loader.load_window)) try self.emitModuleBankEnd(loader.load_window);
        try w.writeAll(
            \\    lda #1
            \\    sta zeropage_module_registry_loaded
            \\    sta zeropage_module_registry_refcount
            \\    lda #0
            \\    sta zeropage_module_registry_active_row
            \\    lda #1
            \\    rts
            \\
        );
    }

    fn emitModuleDependencyLoaderRoutines(self: *Emitter) !void {
        var it = self.module_dependency_load_rows.iterator();
        while (it.next()) |entry| try self.emitModuleDependencyLoaderRoutine(entry.key_ptr.*);
        var acquire_it = self.module_dependency_acquire_rows.iterator();
        while (acquire_it.next()) |entry| try self.emitModuleDependencyAcquireRoutine(entry.key_ptr.*);
    }

    fn emitModuleDependencyLoaderRoutine(self: *Emitter, row: usize) !void {
        const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
        const staging = loader.disk_staging orelse return error.MissingZeroPageModuleLoader;
        if (row == 0) return error.UnknownZeroPageModule;
        _ = try self.moduleRegistryIdForRow(row);
        const max_len = loader.load_window.size;
        const reu_cache_addr = loader.reu_cache.addr + @as(u32, @intCast(row)) * @as(u32, loader.load_window.size);
        const w = &self.out.writer;
        try w.print("zeropage_module_load_dependency_row{d}:\n", .{row});
        try w.print(
            \\    lda zeropage_module_registry_row{d}_loaded
            \\    beq zeropage_module_load_dependency_row{d}_not_loaded
            \\    lda #1
            \\    rts
            \\zeropage_module_load_dependency_row{d}_not_loaded:
            \\    jsr zeropage_reu_present
            \\    cmp #0
            \\    bne zeropage_module_load_dependency_row{d}_present
            \\    lda #0
            \\    rts
            \\zeropage_module_load_dependency_row{d}_present:
            \\
        , .{ row, row, row, row, row });
        try w.print(
            \\    lda #<(zeropage_module_dependency_row{d}_filename_end-zeropage_module_dependency_row{d}_filename)
            \\    ldx #<zeropage_module_dependency_row{d}_filename
            \\    ldy #>zeropage_module_dependency_row{d}_filename
            \\    jsr $ffbd
            \\    lda #1
            \\    ldx #8
            \\    ldy #0
            \\    jsr $ffba
            \\    lda #0
            \\    ldx #${x:0>2}
            \\    ldy #${x:0>2}
            \\    jsr $ffd5
            \\    bcc zeropage_module_load_dependency_row{d}_loaded
            \\    lda #0
            \\    rts
            \\zeropage_module_load_dependency_row{d}_loaded:
            \\
        , .{ row, row, row, row, @as(u8, @truncate(staging.addr)), @as(u8, @truncate(staging.addr >> 8)), row, row });
        try w.print(
            \\    txa
            \\    sec
            \\    sbc #${x:0>2}
            \\    sta zeropage_reu_len
            \\    tya
            \\    sbc #${x:0>2}
            \\    sta zeropage_reu_len+1
            \\    lda zeropage_reu_len
            \\    ora zeropage_reu_len+1
            \\    bne zeropage_module_load_dependency_row{d}_nonzero
            \\    lda #0
            \\    rts
            \\zeropage_module_load_dependency_row{d}_nonzero:
            \\
        , .{ @as(u8, @truncate(staging.addr)), @as(u8, @truncate(staging.addr >> 8)), row, row });
        try w.print(
            \\    lda zeropage_reu_len+1
            \\    cmp #${x:0>2}
            \\    bcc zeropage_module_load_dependency_row{d}_len_ok
            \\    bne zeropage_module_load_dependency_row{d}_len_fail
            \\    lda zeropage_reu_len
            \\    cmp #${x:0>2}
            \\    beq zeropage_module_load_dependency_row{d}_len_ok
            \\    bcc zeropage_module_load_dependency_row{d}_len_ok
            \\zeropage_module_load_dependency_row{d}_len_fail:
            \\    lda #0
            \\    rts
            \\zeropage_module_load_dependency_row{d}_len_ok:
            \\
        , .{ @as(u8, @truncate(max_len >> 8)), row, row, @as(u8, @truncate(max_len)), row, row, row, row });
        try self.emitModuleLoaderCopyAddressSetupImmediate(staging.addr, reu_cache_addr);
        try w.print(
            \\    jsr zeropage_reu_copy_c64_to_reu
            \\    lda #1
            \\    sta zeropage_module_registry_row{d}_loaded
            \\    sta zeropage_module_registry_row{d}_refcount
            \\    rts
            \\
        , .{ row, row });
    }

    fn emitModuleDependencyAcquireRoutine(self: *Emitter, row: usize) !void {
        if (row == 0) return error.UnknownZeroPageModule;
        _ = try self.moduleRegistryIdForRow(row);
        const w = &self.out.writer;
        try w.print("zeropage_module_acquire_dependency_row{d}:\n", .{row});
        try w.print(
            \\    lda zeropage_module_registry_row{d}_loaded
            \\    bne zeropage_module_acquire_dependency_row{d}_loaded
            \\    jsr zeropage_module_load_dependency_row{d}
            \\    rts
            \\zeropage_module_acquire_dependency_row{d}_loaded:
            \\    lda zeropage_module_registry_row{d}_refcount
            \\    cmp #$ff
            \\    bne zeropage_module_acquire_dependency_row{d}_inc
            \\    lda #0
            \\    rts
            \\zeropage_module_acquire_dependency_row{d}_inc:
            \\    inc zeropage_module_registry_row{d}_refcount
            \\    lda #1
            \\    rts
            \\
        , .{ row, row, row, row, row, row, row, row });
    }

    fn emitModuleCurrentActivationRoutine(self: *Emitter) !void {
        const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
        const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
        const jump_table_len: u16 = @intCast(module.exports.len * 3);
        const w = &self.out.writer;
        try w.writeAll(
            \\zeropage_module_activate_current:
            \\    lda zeropage_module_registry_loaded
            \\    bne zeropage_module_activate_current_loaded
            \\    lda #0
            \\    rts
            \\zeropage_module_activate_current_loaded:
            \\
        );
        if (self.currentModuleState() != null) {
            try w.writeAll(
                \\    lda zeropage_module_registry_active_row
                \\    cmp #0
                \\    bne zeropage_module_activate_current_fetch
                \\    lda #1
                \\    rts
                \\zeropage_module_activate_current_fetch:
                \\
            );
        }
        try w.writeAll(
            \\
        );
        if (self.moduleWindowIsBanked(loader.load_window)) try self.emitModuleBankBegin(loader.load_window);
        if (self.hasPersistentDependencyModuleState()) try w.writeAll("    jsr zeropage_module_state_save_active_dependency\n");
        try self.emitModuleLoaderFetchSetup(loader.load_window.addr, loader.reu_cache.addr, jump_table_len);
        try w.writeAll("    jsr zeropage_reu_copy_reu_to_c64\n");
        try self.emitModuleLoaderJumpTablePatches(loader.load_window.addr, jump_table_len);
        for (self.module_relocations.items) |relocation| try self.emitModuleLoaderRelocationPatch(loader.load_window.addr, jump_table_len, relocation);
        if (self.currentModuleState() != null) try w.writeAll("    jsr zeropage_module_state_restore_current\n");
        if (self.moduleWindowIsBanked(loader.load_window)) try self.emitModuleBankEnd(loader.load_window);
        try w.writeAll(
            \\    lda #0
            \\    sta zeropage_module_registry_active_row
            \\    lda #1
            \\    rts
            \\
        );
    }

    fn emitModuleDependencyActivationRoutines(self: *Emitter) !void {
        var it = self.module_dependency_activation_rows.iterator();
        while (it.next()) |entry| try self.emitModuleDependencyActivationRoutine(entry.key_ptr.*);
    }

    fn emitModuleDependencyActivationRoutine(self: *Emitter, row: usize) !void {
        const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
        const dependency = self.dependencySidecarForRow(row) orelse return error.MissingZeroPageDependencySidecar;
        const reu_cache_addr = loader.reu_cache.addr + @as(u32, @intCast(row)) * @as(u32, loader.load_window.size);
        const window = try self.moduleWindowForRow(row);
        const active_label = try self.moduleActiveRowLabelForRow(row);
        defer self.allocator.free(active_label);
        const banked_window = self.moduleWindowIsBanked(window);
        const w = &self.out.writer;
        try w.print(
            \\zeropage_module_activate_dependency_row{d}:
            \\    lda zeropage_module_registry_row{d}_loaded
            \\    bne zeropage_module_activate_dependency_row{d}_loaded
            \\    lda #0
            \\    rts
            \\zeropage_module_activate_dependency_row{d}_loaded:
            \\
        , .{ row, row, row, row });
        if (banked_window) try self.emitModuleBankBegin(window);
        if (self.currentModuleState() != null and window.addr == loader.load_window.addr) {
            try w.print(
                \\    lda zeropage_module_registry_active_row
                \\    cmp #0
                \\    bne zeropage_module_activate_dependency_row{d}_skip_state_save
                \\    jsr zeropage_module_state_save_current
                \\zeropage_module_activate_dependency_row{d}_skip_state_save:
                \\
            , .{ row, row });
        }
        if (self.hasPersistentDependencyModuleState()) {
            const save_label = try self.moduleStateSaveActiveDependencyLabelForRow(row);
            defer self.allocator.free(save_label);
            try w.print("    jsr {s}\n", .{save_label});
        }
        try self.emitModuleLoaderFetchSetupFixedLength(window.addr, reu_cache_addr, dependency.payload_length);
        try w.writeAll("    jsr zeropage_reu_copy_reu_to_c64\n");
        for (dependency.exports) |export_decl| {
            const operand = window.addr + @as(u16, @intCast(export_decl.ordinal * 3)) + 1;
            const relative = @as(i64, export_decl.target_original) - @as(i64, dependency.payload_start);
            const runtime_addr_i64 = @as(i64, window.addr) + @as(i64, dependency.jump_table_bytes) + relative;
            if (runtime_addr_i64 < 0 or runtime_addr_i64 > 0xffff) return error.InvalidZeroPageModuleRelocation;
            const runtime_addr: u16 = @intCast(runtime_addr_i64);
            try w.print(
                \\    lda #${x:0>2}
                \\    sta ${x:0>4}
                \\    lda #${x:0>2}
                \\    sta ${x:0>4}
                \\
            , .{
                @as(u8, @truncate(runtime_addr)),
                operand,
                @as(u8, @truncate(runtime_addr >> 8)),
                @as(u16, @intCast(operand + 1)),
            });
        }
        for (dependency.relocations) |patch| {
            const addr = window.addr + patch.payload_offset;
            if (patch.target_original == 0 and patch.addend == 0) {
                try w.print("    lda #${x:0>2}\n    sta ${x:0>4}\n", .{ patch.after[0], @as(u16, @intCast(addr)) });
                if (patch.size == 2) try w.print("    lda #${x:0>2}\n    sta ${x:0>4}\n", .{ patch.after[1], @as(u16, @intCast(addr + 1)) });
                continue;
            }
            const relative = @as(i64, patch.target_original) - @as(i64, dependency.payload_start) + @as(i64, patch.addend);
            const runtime_addr_i64 = @as(i64, window.addr) + @as(i64, dependency.jump_table_bytes) + relative;
            if (runtime_addr_i64 < 0 or runtime_addr_i64 > 0xffff) return error.InvalidZeroPageModuleRelocation;
            const runtime_addr: u16 = @intCast(runtime_addr_i64);
            const low: u8 = @truncate(runtime_addr);
            const high: u8 = @truncate(runtime_addr >> 8);
            switch (patch.kind) {
                .abs16 => {
                    try w.print("    lda #${x:0>2}\n    sta ${x:0>4}\n", .{ low, @as(u16, @intCast(addr)) });
                    try w.print("    lda #${x:0>2}\n    sta ${x:0>4}\n", .{ high, @as(u16, @intCast(addr + 1)) });
                },
                .lo8 => try w.print("    lda #${x:0>2}\n    sta ${x:0>4}\n", .{ low, @as(u16, @intCast(addr)) }),
                .hi8 => try w.print("    lda #${x:0>2}\n    sta ${x:0>4}\n", .{ high, @as(u16, @intCast(addr)) }),
            }
        }
        if (self.dependencyModuleState(row) != null) try w.print("    jsr zeropage_module_state_restore_dependency_row{d}\n", .{row});
        if (banked_window) try self.emitModuleBankEnd(window);
        try w.print(
            \\    lda #{d}
            \\    sta {s}
            \\    lda #1
            \\    rts
            \\
        , .{ row, active_label });
    }

    fn dependencySidecarForRow(self: *Emitter, row: usize) ?module_sidecars.DependencyModule {
        if (row == 0) return null;
        const id = self.moduleRegistryIdForRow(row) catch return null;
        return self.findDependencySidecar(id);
    }

    fn emitModuleLoaderJumpTablePatches(self: *Emitter, load_window_addr: u16, jump_table_len: u16) !void {
        const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
        const w = &self.out.writer;
        for (module.exports, 0..) |export_decl, ordinal| {
            const operand_addr = @as(u16, @intCast(load_window_addr + @as(u16, @intCast(ordinal * 3)) + 1));
            try w.print(
                \\    lda #<(zeropage_module_registry_jump_table+{d}+{s}-zeropage_module_payload_range_start)
                \\    sta ${x:0>4}
                \\    lda #>(zeropage_module_registry_jump_table+{d}+{s}-zeropage_module_payload_range_start)
                \\    sta ${x:0>4}
                \\
            , .{
                jump_table_len,
                export_decl.function_name,
                operand_addr,
                jump_table_len,
                export_decl.function_name,
                @as(u16, @intCast(operand_addr + 1)),
            });
        }
    }

    fn emitModuleIsLoadedRoutine(self: *Emitter) !void {
        try self.out.writer.writeAll(
            \\zeropage_module_is_loaded_current:
            \\    lda zeropage_module_registry_loaded
            \\    rts
            \\
        );
    }

    fn emitModuleUnloadRoutine(self: *Emitter) !void {
        const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
        const w = &self.out.writer;
        try w.writeAll(
            \\zeropage_module_unload_current:
            \\
        );
        if (self.currentModuleState() != null) {
            try w.writeAll(
                \\    lda zeropage_module_registry_loaded
                \\    beq zeropage_module_unload_current_clear
                \\    lda zeropage_module_registry_active_row
                \\    cmp #0
                \\    bne zeropage_module_unload_current_clear
            );
            if (self.moduleWindowIsBanked(loader.load_window)) try self.emitModuleBankBegin(loader.load_window);
            try w.writeAll(
                \\
                \\    jsr zeropage_module_state_save_current
            );
            if (self.moduleWindowIsBanked(loader.load_window)) try self.emitModuleBankEnd(loader.load_window);
            try w.writeAll(
                \\
                \\zeropage_module_unload_current_clear:
                \\
            );
        }
        try w.writeAll(
            \\
            \\    lda #0
            \\    sta zeropage_module_registry_loaded
            \\    sta zeropage_module_registry_refcount
            \\    lda zeropage_module_registry_active_row
            \\    cmp #0
            \\    bne zeropage_module_unload_current_done
            \\    lda #$ff
            \\    sta zeropage_module_registry_active_row
            \\zeropage_module_unload_current_done:
            \\    rts
            \\
        );
    }

    fn emitModuleStateRoutines(self: *Emitter) !void {
        const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
        const w = &self.out.writer;
        if (self.currentModuleState()) |state| {
            const snapshot = self.moduleStateSnapshotReuAddr();
            try w.writeAll(
                \\zeropage_module_state_save_current:
                \\    lda zeropage_module_registry_loaded
                \\    beq zeropage_module_state_save_current_done
                \\    lda zeropage_module_registry_active_row
                \\    cmp #0
                \\    bne zeropage_module_state_save_current_done
                \\
            );
            for (state.ranges) |range| {
                const c64_addr: u16 = @intCast(loader.load_window.addr + range.offset);
                const reu_addr = snapshot + range.offset;
                try self.emitModuleLoaderCopySetupImmediateFixedLength(c64_addr, reu_addr, range.size);
                try w.writeAll("    jsr zeropage_reu_copy_c64_to_reu\n");
            }
            try w.writeAll(
                \\    lda #1
                \\    sta zeropage_module_state_current_saved
                \\zeropage_module_state_save_current_done:
                \\    rts
                \\
                \\zeropage_module_state_restore_current:
                \\    lda zeropage_module_state_current_saved
                \\    beq zeropage_module_state_restore_current_done
                \\
            );
            for (state.ranges) |range| {
                const c64_addr: u16 = @intCast(loader.load_window.addr + range.offset);
                const reu_addr = snapshot + range.offset;
                try self.emitModuleLoaderFetchSetupFixedLength(c64_addr, reu_addr, range.size);
                try w.writeAll("    jsr zeropage_reu_copy_reu_to_c64\n");
            }
            try w.writeAll(
                \\zeropage_module_state_restore_current_done:
                \\    rts
                \\
            );
        }
        if (self.hasPersistentDependencyModuleState()) {
            const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
            try self.emitModuleStateSaveActiveDependencyForWindow("main");
            for (loader.extra_load_windows) |entry| try self.emitModuleStateSaveActiveDependencyForWindow(entry.name);
            for (1..module.deps.len + 1) |row| {
                const state = self.dependencyModuleState(row) orelse continue;
                try self.emitModuleDependencyStateRoutines(row, state);
            }
        }
    }

    fn emitModuleStateSaveActiveDependencyForWindow(self: *Emitter, window_name: []const u8) !void {
        const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
        const w = &self.out.writer;
        const routine_label = try self.moduleStateSaveActiveDependencyLabelForWindowName(window_name);
        defer self.allocator.free(routine_label);
        const active_label = try self.moduleActiveRowLabelForWindowName(window_name);
        defer self.allocator.free(active_label);
        try w.print("{s}:\n", .{routine_label});
        for (1..module.deps.len + 1) |row| {
            if (self.dependencyModuleState(row) == null) continue;
            const row_id = try self.moduleRegistryIdForRow(row);
            if (!std.mem.eql(u8, self.moduleWindowNameForId(row_id), window_name)) continue;
            try w.print(
                \\    lda {s}
                \\    cmp #{d}
                \\    bne {s}_not_row{d}
                \\    jsr zeropage_module_state_save_dependency_row{d}
                \\    rts
                \\{s}_not_row{d}:
                \\
            , .{ active_label, row, routine_label, row, row, routine_label, row });
        }
        try w.writeAll("    rts\n");
    }

    fn emitModuleDependencyStateRoutines(self: *Emitter, row: usize, state: ast.CurrentModuleState) !void {
        const window = try self.moduleWindowForRow(row);
        const snapshot = self.moduleDependencyStateSnapshotReuAddr(row);
        const active_label = try self.moduleActiveRowLabelForRow(row);
        defer self.allocator.free(active_label);
        const w = &self.out.writer;
        try w.print(
            \\zeropage_module_state_save_dependency_row{d}:
            \\    lda zeropage_module_registry_row{d}_loaded
            \\    beq zeropage_module_state_save_dependency_row{d}_done
            \\    lda {s}
            \\    cmp #{d}
            \\    bne zeropage_module_state_save_dependency_row{d}_done
            \\
        , .{ row, row, row, active_label, row, row });
        for (state.ranges) |range| {
            const c64_addr: u16 = @intCast(window.addr + range.offset);
            const reu_addr = snapshot + range.offset;
            try self.emitModuleLoaderCopySetupImmediateFixedLength(c64_addr, reu_addr, range.size);
            try w.writeAll("    jsr zeropage_reu_copy_c64_to_reu\n");
        }
        try w.print(
            \\    lda #1
            \\    sta zeropage_module_state_dep{d}_saved
            \\zeropage_module_state_save_dependency_row{d}_done:
            \\    rts
            \\
            \\zeropage_module_state_restore_dependency_row{d}:
            \\    lda zeropage_module_state_dep{d}_saved
            \\    beq zeropage_module_state_restore_dependency_row{d}_done
            \\
        , .{ row, row, row, row, row });
        for (state.ranges) |range| {
            const c64_addr: u16 = @intCast(window.addr + range.offset);
            const reu_addr = snapshot + range.offset;
            try self.emitModuleLoaderFetchSetupFixedLength(c64_addr, reu_addr, range.size);
            try w.writeAll("    jsr zeropage_reu_copy_reu_to_c64\n");
        }
        try w.print(
            \\zeropage_module_state_restore_dependency_row{d}_done:
            \\    rts
            \\
        , .{row});
    }

    fn emitModuleDependencyUnloadRoutines(self: *Emitter) !void {
        var it = self.module_dependency_unload_rows.iterator();
        while (it.next()) |entry| {
            const row = entry.key_ptr.*;
            try self.emitModuleDependencyUnloadRoutine(row);
        }
    }

    fn emitModuleDependencyUnloadRoutine(self: *Emitter, row: usize) !void {
        const w = &self.out.writer;
        if (row == 0) return error.UnknownZeroPageModule;
        _ = try self.moduleRegistryIdForRow(row);
        const window = try self.moduleWindowForRow(row);
        const active_label = try self.moduleActiveRowLabelForRow(row);
        defer self.allocator.free(active_label);
        try w.print("zeropage_module_unload_dependency_row{d}:\n", .{row});
        try w.print(
            \\    lda zeropage_module_registry_row{d}_loaded
            \\    beq zeropage_module_unload_dependency_row{d}_done
            \\    lda zeropage_module_registry_row{d}_refcount
            \\    beq zeropage_module_unload_dependency_row{d}_final_release
            \\    cmp #1
            \\    beq zeropage_module_unload_dependency_row{d}_final_release
            \\    dec zeropage_module_registry_row{d}_refcount
            \\    rts
            \\zeropage_module_unload_dependency_row{d}_final_release:
            \\
        , .{ row, row, row, row, row, row, row });
        if (self.dependencyModuleState(row) != null) {
            try w.print(
                \\    lda {s}
                \\    cmp #{d}
                \\    bne zeropage_module_unload_dependency_row{d}_skip_state_save
                \\
            , .{ active_label, row, row });
            if (self.moduleWindowIsBanked(window)) try self.emitModuleBankBegin(window);
            try w.print("    jsr zeropage_module_state_save_dependency_row{d}\n", .{row});
            if (self.moduleWindowIsBanked(window)) try self.emitModuleBankEnd(window);
            try w.print(
                \\zeropage_module_unload_dependency_row{d}_skip_state_save:
                \\
            , .{row});
        }
        try w.print(
            \\    lda #0
            \\    sta zeropage_module_registry_row{d}_loaded
            \\    sta zeropage_module_registry_row{d}_refcount
            \\    lda {s}
            \\    cmp #{d}
            \\    bne zeropage_module_unload_dependency_row{d}_done
            \\    lda #$ff
            \\    sta {s}
            \\zeropage_module_unload_dependency_row{d}_done:
            \\    rts
            \\
        , .{ row, row, active_label, row, row, active_label, row });
    }

    fn emitModuleLoaderCopySetup(self: *Emitter, c64_label: []const u8, reu_addr: u32, len_expr: []const u8) !void {
        const w = &self.out.writer;
        try w.print(
            \\    lda #<{s}
            \\    sta zeropage_reu_c64_addr
            \\    lda #>{s}
            \\    sta zeropage_reu_c64_addr+1
            \\
        , .{ c64_label, c64_label });
        try self.emitReuAddrImmediate(reu_addr);
        try w.print(
            \\    lda #<({s})
            \\    sta zeropage_reu_len
            \\    lda #>({s})
            \\    sta zeropage_reu_len+1
            \\
        , .{ len_expr, len_expr });
    }

    fn emitModuleLoaderCopySetupImmediate(self: *Emitter, c64_addr: u16, reu_addr: u32, len_expr: []const u8) !void {
        const w = &self.out.writer;
        try self.emitModuleLoaderCopyAddressSetupImmediate(c64_addr, reu_addr);
        try w.print(
            \\    lda #<({s})
            \\    sta zeropage_reu_len
            \\    lda #>({s})
            \\    sta zeropage_reu_len+1
            \\
        , .{ len_expr, len_expr });
    }

    fn emitModuleLoaderCopySetupImmediateFixedLength(self: *Emitter, c64_addr: u16, reu_addr: u32, len: u16) !void {
        const w = &self.out.writer;
        try self.emitModuleLoaderCopyAddressSetupImmediate(c64_addr, reu_addr);
        try w.print(
            \\    lda #${x:0>2}
            \\    sta zeropage_reu_len
            \\    lda #${x:0>2}
            \\    sta zeropage_reu_len+1
            \\
        , .{ @as(u8, @truncate(len)), @as(u8, @truncate(len >> 8)) });
    }

    fn emitModuleLoaderCopyAddressSetupImmediate(self: *Emitter, c64_addr: u16, reu_addr: u32) !void {
        const w = &self.out.writer;
        try w.print(
            \\    lda #${x:0>2}
            \\    sta zeropage_reu_c64_addr
            \\    lda #${x:0>2}
            \\    sta zeropage_reu_c64_addr+1
            \\
        , .{ @as(u8, @truncate(c64_addr)), @as(u8, @truncate(c64_addr >> 8)) });
        try self.emitReuAddrImmediate(reu_addr);
    }

    fn emitModuleLoaderFetchSetup(self: *Emitter, load_window: u16, reu_addr: u32, jump_table_len: u16) !void {
        const w = &self.out.writer;
        try w.print(
            \\    lda #${x:0>2}
            \\    sta zeropage_reu_c64_addr
            \\    lda #${x:0>2}
            \\    sta zeropage_reu_c64_addr+1
            \\
        , .{ @as(u8, @truncate(load_window)), @as(u8, @truncate(load_window >> 8)) });
        try self.emitReuAddrImmediate(reu_addr);
        try w.print(
            \\    lda #<({d}+(zeropage_module_payload_range_end-zeropage_module_payload_range_start))
            \\    sta zeropage_reu_len
            \\    lda #>({d}+(zeropage_module_payload_range_end-zeropage_module_payload_range_start))
            \\    sta zeropage_reu_len+1
            \\
        , .{ jump_table_len, jump_table_len });
    }

    fn emitModuleLoaderFetchSetupFixedLength(self: *Emitter, load_window: u16, reu_addr: u32, len: u16) !void {
        const w = &self.out.writer;
        try w.print(
            \\    lda #${x:0>2}
            \\    sta zeropage_reu_c64_addr
            \\    lda #${x:0>2}
            \\    sta zeropage_reu_c64_addr+1
            \\
        , .{ @as(u8, @truncate(load_window)), @as(u8, @truncate(load_window >> 8)) });
        try self.emitReuAddrImmediate(reu_addr);
        try w.print(
            \\    lda #${x:0>2}
            \\    sta zeropage_reu_len
            \\    lda #${x:0>2}
            \\    sta zeropage_reu_len+1
            \\
        , .{ @as(u8, @truncate(len)), @as(u8, @truncate(len >> 8)) });
    }

    fn emitModuleLoaderRelocationPatch(self: *Emitter, load_window: u16, jump_table_len: u16, relocation: EmittedModuleRelocation) !void {
        const w = &self.out.writer;
        const operand_expr = try std.fmt.allocPrint(self.allocator, "${x:0>4}+{d}+(zeropage_module_reloc_{d}+1-zeropage_module_payload_range_start)", .{ load_window, jump_table_len, relocation.id });
        defer self.allocator.free(operand_expr);
        const target_expr = try std.fmt.allocPrint(self.allocator, "${x:0>4}+{d}+({s}-zeropage_module_payload_range_start)+{d}", .{ load_window, jump_table_len, relocation.target, relocation.addend });
        defer self.allocator.free(target_expr);
        try w.print(
            \\.if zeropage_module_reloc_{d} >= zeropage_module_payload_range_start
            \\.if zeropage_module_reloc_{d}+2 <= zeropage_module_payload_range_end
            \\
        , .{ relocation.id, relocation.id });
        switch (relocation.kind) {
            .abs16 => try w.print(
                \\    lda #<({s})
                \\    sta {s}
                \\    lda #>({s})
                \\    sta {s}+1
                \\
            , .{ target_expr, operand_expr, target_expr, operand_expr }),
            .lo8 => try w.print(
                \\    lda #<({s})
                \\    sta {s}
                \\
            , .{ target_expr, operand_expr }),
            .hi8 => try w.print(
                \\    lda #>({s})
                \\    sta {s}
                \\
            , .{ target_expr, operand_expr }),
        }
        try w.writeAll(
            \\.endif
            \\.endif
            \\
        );
    }

    fn emitReuHeapRoutines(self: *Emitter) !void {
        for (self.program.zeropage_options.reu.heaps) |heap| {
            if (self.reuHeapUsesAllocRuntime(heap.name)) try self.emitReuHeapAllocRoutine(heap);
            if (self.reuHeapUsesResetRuntime(heap.name)) try self.emitReuHeapResetRoutine(heap);
        }
    }

    fn emitReuHeapAllocRoutine(self: *Emitter, heap: ast.ReuHeapOptions) !void {
        const w = &self.out.writer;
        const name = heap.name;
        const heap_end = heap.addr + heap.size;
        try w.print(
            \\zeropage_reu_heap_{s}_alloc_bytes:
            \\    lda zeropage_reu_heap_len
            \\    ora zeropage_reu_heap_len+1
            \\    bne zeropage_reu_heap_{s}_len_ok
            \\    jmp zeropage_reu_heap_{s}_oom
            \\zeropage_reu_heap_{s}_len_ok:
            \\    lda zeropage_reu_heap_{s}_cursor
            \\    sta zeropage_reu_heap_result
            \\    lda zeropage_reu_heap_{s}_cursor+1
            \\    sta zeropage_reu_heap_result+1
            \\    lda zeropage_reu_heap_{s}_cursor+2
            \\    sta zeropage_reu_heap_result+2
            \\    lda zeropage_reu_heap_len
            \\    sta zeropage_reu_heap_result+3
            \\    lda zeropage_reu_heap_len+1
            \\    sta zeropage_reu_heap_result+4
            \\    clc
            \\    lda zeropage_reu_heap_{s}_cursor
            \\    adc zeropage_reu_heap_len
            \\    sta zeropage_reu_heap_new_cursor
            \\    lda zeropage_reu_heap_{s}_cursor+1
            \\    adc zeropage_reu_heap_len+1
            \\    sta zeropage_reu_heap_new_cursor+1
            \\    lda zeropage_reu_heap_{s}_cursor+2
            \\    adc #0
            \\    sta zeropage_reu_heap_new_cursor+2
            \\    lda zeropage_reu_heap_{s}_cursor+3
            \\    adc #0
            \\    sta zeropage_reu_heap_new_cursor+3
            \\    cmp #${x:0>2}
            \\    bcc zeropage_reu_heap_{s}_ok
            \\    bne zeropage_reu_heap_{s}_oom
            \\    lda zeropage_reu_heap_new_cursor+2
            \\    cmp #${x:0>2}
            \\    bcc zeropage_reu_heap_{s}_ok
            \\    bne zeropage_reu_heap_{s}_oom
            \\    lda zeropage_reu_heap_new_cursor+1
            \\    cmp #${x:0>2}
            \\    bcc zeropage_reu_heap_{s}_ok
            \\    bne zeropage_reu_heap_{s}_oom
            \\    lda zeropage_reu_heap_new_cursor
            \\    cmp #${x:0>2}
            \\    bcc zeropage_reu_heap_{s}_ok
            \\    beq zeropage_reu_heap_{s}_ok
            \\    jmp zeropage_reu_heap_{s}_oom
            \\zeropage_reu_heap_{s}_ok:
            \\    lda zeropage_reu_heap_new_cursor
            \\    sta zeropage_reu_heap_{s}_cursor
            \\    lda zeropage_reu_heap_new_cursor+1
            \\    sta zeropage_reu_heap_{s}_cursor+1
            \\    lda zeropage_reu_heap_new_cursor+2
            \\    sta zeropage_reu_heap_{s}_cursor+2
            \\    lda zeropage_reu_heap_new_cursor+3
            \\    sta zeropage_reu_heap_{s}_cursor+3
            \\    lda #1
            \\    rts
            \\zeropage_reu_heap_{s}_oom:
            \\    lda #0
            \\    sta zeropage_reu_heap_result
            \\    sta zeropage_reu_heap_result+1
            \\    sta zeropage_reu_heap_result+2
            \\    sta zeropage_reu_heap_result+3
            \\    sta zeropage_reu_heap_result+4
            \\    rts
            \\
        , .{
            name,
            name,
            name,
            name,
            name,
            name,
            name,
            name,
            name,
            name,
            name,
            @as(u8, @truncate(heap_end >> 24)),
            name,
            name,
            @as(u8, @truncate(heap_end >> 16)),
            name,
            name,
            @as(u8, @truncate(heap_end >> 8)),
            name,
            name,
            @as(u8, @truncate(heap_end)),
            name,
            name,
            name,
            name,
            name,
            name,
            name,
            name,
            name,
        });
    }

    fn emitReuHeapResetRoutine(self: *Emitter, heap: ast.ReuHeapOptions) !void {
        try self.out.writer.print(
            \\zeropage_reu_heap_{s}_reset:
            \\    lda #${x:0>2}
            \\    sta zeropage_reu_heap_{s}_cursor
            \\    lda #${x:0>2}
            \\    sta zeropage_reu_heap_{s}_cursor+1
            \\    lda #${x:0>2}
            \\    sta zeropage_reu_heap_{s}_cursor+2
            \\    lda #${x:0>2}
            \\    sta zeropage_reu_heap_{s}_cursor+3
            \\    rts
            \\
        , .{
            heap.name,
            @as(u8, @truncate(heap.addr)),
            heap.name,
            @as(u8, @truncate(heap.addr >> 8)),
            heap.name,
            @as(u8, @truncate(heap.addr >> 16)),
            heap.name,
            @as(u8, @truncate(heap.addr >> 24)),
            heap.name,
        });
    }

    fn emitHeapRoutines(self: *Emitter) !void {
        const w = &self.out.writer;
        try sections.emitBegin(w, .runtime, .code, .static, .near);
        for (self.program.zeropage_options.heaps) |heap| {
            if (self.heapUsesAllocRuntime(heap.name)) try self.emitHeapAllocRoutine(heap);
            if (self.heapUsesResetRuntime(heap.name)) try self.emitHeapResetRoutine(heap);
            if (self.heapUsesFreeRuntime(heap.name)) try self.emitHeapFreeRoutine(heap);
        }
        try sections.emitEnd(w, .runtime, .code);
    }

    fn emitHeapAllocRoutine(self: *Emitter, heap: ast.HeapOptions) !void {
        switch (heap.kind) {
            .arena => try self.emitArenaHeapAllocRoutine(heap),
            .fixed => try self.emitFixedHeapAllocRoutine(heap),
        }
    }

    fn emitArenaHeapAllocRoutine(self: *Emitter, heap: ast.HeapOptions) !void {
        const w = &self.out.writer;
        const heap_end = @as(u32, heap.addr) + @as(u32, heap.size);
        try w.print(
            \\zeropage_heap_{s}_alloc_bytes:
            \\    sta zeropage_heap_len
            \\    stx zeropage_heap_len+1
            \\    lda zeropage_heap_len
            \\    ora zeropage_heap_len+1
            \\    beq zeropage_heap_{s}_oom
            \\    lda zeropage_heap_{s}_cursor
            \\    sta zeropage_heap_result
            \\    lda zeropage_heap_{s}_cursor+1
            \\    sta zeropage_heap_result+1
            \\    clc
            \\    lda zeropage_heap_{s}_cursor
            \\    adc zeropage_heap_len
            \\    sta zeropage_heap_new_cursor
            \\    lda zeropage_heap_{s}_cursor+1
            \\    adc zeropage_heap_len+1
            \\    bcs zeropage_heap_{s}_oom
            \\    sta zeropage_heap_new_cursor+1
            \\    cmp #${x:0>2}
            \\    bcc zeropage_heap_{s}_ok
            \\    bne zeropage_heap_{s}_oom
            \\    lda zeropage_heap_new_cursor
            \\    cmp #${x:0>2}
            \\    bcc zeropage_heap_{s}_ok
            \\    beq zeropage_heap_{s}_ok
            \\    jmp zeropage_heap_{s}_oom
            \\zeropage_heap_{s}_ok:
            \\    lda zeropage_heap_new_cursor
            \\    sta zeropage_heap_{s}_cursor
            \\    lda zeropage_heap_new_cursor+1
            \\    sta zeropage_heap_{s}_cursor+1
            \\    ldx zeropage_heap_result+1
            \\    lda zeropage_heap_result
            \\    rts
            \\zeropage_heap_{s}_oom:
            \\    lda #0
            \\    tax
            \\    rts
            \\
        , .{
            heap.name,
            heap.name,
            heap.name,
            heap.name,
            heap.name,
            heap.name,
            heap.name,
            @as(u8, @truncate(heap_end >> 8)),
            heap.name,
            heap.name,
            @as(u8, @truncate(heap_end)),
            heap.name,
            heap.name,
            heap.name,
            heap.name,
            heap.name,
            heap.name,
            heap.name,
        });
    }

    fn emitHeapResetRoutine(self: *Emitter, heap: ast.HeapOptions) !void {
        switch (heap.kind) {
            .arena => try self.emitArenaHeapResetRoutine(heap),
            .fixed => try self.emitFixedHeapResetRoutine(heap),
        }
    }

    fn emitArenaHeapResetRoutine(self: *Emitter, heap: ast.HeapOptions) !void {
        try self.out.writer.print(
            \\zeropage_heap_{s}_reset:
            \\    lda #${x:0>2}
            \\    sta zeropage_heap_{s}_cursor
            \\    lda #${x:0>2}
            \\    sta zeropage_heap_{s}_cursor+1
            \\    rts
            \\
        , .{ heap.name, @as(u8, @truncate(heap.addr)), heap.name, @as(u8, @truncate(heap.addr >> 8)), heap.name });
    }

    fn emitFixedHeapAllocRoutine(self: *Emitter, heap: ast.HeapOptions) !void {
        const w = &self.out.writer;
        const name = heap.name;
        const heap_end = @as(u32, heap.addr) + @as(u32, heap.size);
        const block = heap.block.?;
        try w.print(
            \\zeropage_heap_{s}_alloc_bytes:
            \\    sta zeropage_heap_len
            \\    stx zeropage_heap_len+1
            \\    lda zeropage_heap_len
            \\    ora zeropage_heap_len+1
            \\    beq zeropage_heap_{s}_oom
            \\    lda zeropage_heap_len+1
            \\    cmp #${x:0>2}
            \\    bcc zeropage_heap_{s}_len_ok
            \\    bne zeropage_heap_{s}_oom
            \\    lda zeropage_heap_len
            \\    cmp #${x:0>2}
            \\    beq zeropage_heap_{s}_len_ok
            \\    bcc zeropage_heap_{s}_len_ok
            \\    jmp zeropage_heap_{s}_oom
            \\zeropage_heap_{s}_len_ok:
            \\
        , .{
            name,
            name,
            @as(u8, @truncate(block >> 8)),
            name,
            name,
            @as(u8, @truncate(block)),
            name,
            name,
            name,
            name,
        });
        try w.print(
            \\    lda zeropage_heap_{s}_free_head
            \\    ora zeropage_heap_{s}_free_head+1
            \\    beq zeropage_heap_{s}_fresh
            \\    lda zeropage_heap_{s}_free_head
            \\    sta zeropage_heap_result
            \\    sta zeropage_ptr_tmp
            \\    lda zeropage_heap_{s}_free_head+1
            \\    sta zeropage_heap_result+1
            \\    sta zeropage_ptr_tmp+1
            \\    ldy #0
            \\    lda (zeropage_ptr_tmp),y
            \\    sta zeropage_heap_{s}_free_head
            \\    iny
            \\    lda (zeropage_ptr_tmp),y
            \\    sta zeropage_heap_{s}_free_head+1
            \\    ldx zeropage_heap_result+1
            \\    lda zeropage_heap_result
            \\    rts
            \\
        , .{
            name,
            name,
            name,
            name,
            name,
            name,
            name,
        });
        try w.print(
            \\zeropage_heap_{s}_fresh:
            \\    lda zeropage_heap_{s}_cursor+1
            \\    cmp #${x:0>2}
            \\    bcc zeropage_heap_{s}_fresh_ok
            \\    bne zeropage_heap_{s}_oom
            \\    lda zeropage_heap_{s}_cursor
            \\    cmp #${x:0>2}
            \\    bcc zeropage_heap_{s}_fresh_ok
            \\    jmp zeropage_heap_{s}_oom
            \\zeropage_heap_{s}_fresh_ok:
            \\    lda zeropage_heap_{s}_cursor
            \\    sta zeropage_heap_result
            \\    lda zeropage_heap_{s}_cursor+1
            \\    sta zeropage_heap_result+1
            \\    clc
            \\    lda zeropage_heap_{s}_cursor
            \\    adc #${x:0>2}
            \\    sta zeropage_heap_{s}_cursor
            \\    lda zeropage_heap_{s}_cursor+1
            \\    adc #${x:0>2}
            \\    sta zeropage_heap_{s}_cursor+1
            \\    ldx zeropage_heap_result+1
            \\    lda zeropage_heap_result
            \\    rts
            \\zeropage_heap_{s}_oom:
            \\    lda #0
            \\    tax
            \\    rts
            \\
        , .{
            name,
            name,
            @as(u8, @truncate(heap_end >> 8)),
            name,
            name,
            name,
            @as(u8, @truncate(heap_end)),
            name,
            name,
            name,
            name,
            name,
            name,
            @as(u8, @truncate(block)),
            name,
            name,
            @as(u8, @truncate(block >> 8)),
            name,
            name,
        });
    }

    fn emitFixedHeapResetRoutine(self: *Emitter, heap: ast.HeapOptions) !void {
        try self.out.writer.print(
            \\zeropage_heap_{s}_reset:
            \\    lda #${x:0>2}
            \\    sta zeropage_heap_{s}_cursor
            \\    lda #${x:0>2}
            \\    sta zeropage_heap_{s}_cursor+1
            \\    lda #0
            \\    sta zeropage_heap_{s}_free_head
            \\    sta zeropage_heap_{s}_free_head+1
            \\    rts
            \\
        , .{ heap.name, @as(u8, @truncate(heap.addr)), heap.name, @as(u8, @truncate(heap.addr >> 8)), heap.name, heap.name, heap.name });
    }

    fn emitHeapFreeRoutine(self: *Emitter, heap: ast.HeapOptions) !void {
        if (heap.kind != .fixed) return;
        try self.out.writer.print(
            \\zeropage_heap_{s}_free:
            \\    sta zeropage_heap_result
            \\    sta zeropage_ptr_tmp
            \\    stx zeropage_heap_result+1
            \\    stx zeropage_ptr_tmp+1
            \\    ldy #0
            \\    lda zeropage_heap_{s}_free_head
            \\    sta (zeropage_ptr_tmp),y
            \\    iny
            \\    lda zeropage_heap_{s}_free_head+1
            \\    sta (zeropage_ptr_tmp),y
            \\    lda zeropage_heap_result
            \\    sta zeropage_heap_{s}_free_head
            \\    lda zeropage_heap_result+1
            \\    sta zeropage_heap_{s}_free_head+1
            \\    rts
            \\
        , .{ heap.name, heap.name, heap.name, heap.name, heap.name });
    }

    pub fn emitVarSlots(self: *Emitter) !void {
        try storage.emitVarSlots(self);
        if (self.field_value_temp_count != 0) {
            // Resident runtime data is intentionally outside automatic ZP and
            // call-capture optimizers. It belongs in DLL runtime payloads too.
            try sections.emitBegin(&self.out.writer, .runtime, .data, .static, .near);
            for (0..self.field_value_temp_count) |id| try self.out.writer.print("zeropage_field_value_{d}:\n    .word 0\n", .{id});
            try sections.emitEnd(&self.out.writer, .runtime, .data);
        }
    }

    pub fn emitFunctionStaticFrame(self: *Emitter, function: ast.Function) !void {
        try storage.emitFunctionStaticFrame(self, function);
    }

    pub fn emitRoDataConstants(self: *Emitter) !void {
        try storage.emitRoDataConstants(self);
    }

    pub fn emitArrayData(self: *Emitter, ty: ast.ArrayType, values: []const ast.Expr) !void {
        try storage.emitArrayData(self, ty, values);
    }

    pub fn arrayConstValue(self: *Emitter, ty: ast.ArrayType, expr: ast.Expr) !u16 {
        return storage.arrayConstValue(self, ty, expr);
    }

    pub fn emitVarSlotsFor(self: *Emitter, function_name: []const u8, statements: []const ast.Stmt) !void {
        try storage.emitVarSlotsFor(self, function_name, statements);
    }

    pub fn emitVarSlotsForExpr(self: *Emitter, function_name: []const u8, expr: ast.Expr) anyerror!void {
        try storage.emitVarSlotsForExpr(self, function_name, expr);
    }

    pub fn emitStructSlots(self: *Emitter, function_name: []const u8, prefix: []const u8, type_name: []const u8) !void {
        try storage.emitStructSlots(self, function_name, prefix, type_name);
    }

    pub fn emitVarSlotsForArrayAssign(self: *Emitter, function_name: []const u8, assign: ast.ArrayAssign) anyerror!void {
        try storage.emitVarSlotsForArrayAssign(self, function_name, assign);
    }

    pub fn emitVarSlotsForTest6502Call(self: *Emitter, function_name: []const u8, call: ast.Test6502Call) anyerror!void {
        try storage.emitVarSlotsForTest6502Call(self, function_name, call);
    }

    pub fn emitVarSlotsForBuiltin(self: *Emitter, function_name: []const u8, builtin: ast.BuiltinCall) anyerror!void {
        try storage.emitVarSlotsForBuiltin(self, function_name, builtin);
    }

    pub fn emitSlot(self: *Emitter, function_name: []const u8, name: []const u8, ty: ast.Type) !void {
        try storage.emitSlot(self, function_name, name, ty);
    }

    pub fn emitForSlots(self: *Emitter, function_name: []const u8, for_stmt: ast.ForStmt) !void {
        try storage.emitForSlots(self, function_name, for_stmt);
    }

    pub fn emitZeroBytes(self: *Emitter, count: u16) !void {
        try storage.emitZeroBytes(self, count);
    }

    pub fn emitStringSlot(self: *Emitter, function_name: []const u8, decl: ast.StringVar) !void {
        try storage.emitStringSlot(self, function_name, decl);
    }

    pub fn findFunction(self: *Emitter, label: []const u8) ?ast.Function {
        for (self.program.functions) |function| {
            if (std.mem.eql(u8, function.name, label)) return function;
        }
        return null;
    }

    pub fn findStringBuffer(self: *Emitter, function_name: []const u8, name: []const u8) ?StringBufferRef {
        const function = self.findFunction(function_name) orelse return null;
        return findStringBufferInStmts(function.name, function.body, name);
    }

    fn findStringBufferInStmts(function_name: []const u8, statements: []const ast.Stmt, name: []const u8) ?StringBufferRef {
        for (statements) |stmt| {
            switch (stmt) {
                .string_var => |decl| if (std.mem.eql(u8, decl.name, name)) {
                    return .{ .function_name = function_name, .name = decl.name, .capacity = decl.capacity };
                },
                .while_stmt => |while_stmt| if (findStringBufferInStmts(function_name, while_stmt.body, name)) |buffer| return buffer,
                .for_stmt => |for_stmt| if (findStringBufferInStmts(function_name, for_stmt.body, name)) |buffer| return buffer,
                .switch_stmt => |switch_stmt| for (switch_stmt.prongs) |prong| {
                    if (findStringBufferInStmts(function_name, prong.body, name)) |buffer| return buffer;
                },
                .if_stmt => |if_stmt| {
                    if (findStringBufferInStmts(function_name, if_stmt.then_body, name)) |buffer| return buffer;
                    if (findStringBufferInStmts(function_name, if_stmt.else_body, name)) |buffer| return buffer;
                },
                else => {},
            }
        }
        return null;
    }

    fn labelForTarget(self: *Emitter, target: []const u8) ![]u8 {
        const label = try self.allocator.dupe(u8, target);
        for (label) |*ch| {
            if (ch.* == '.') ch.* = '_';
        }
        return label;
    }

    pub fn nextLabel(self: *Emitter) usize {
        const id = self.label_id;
        self.label_id += 1;
        return id;
    }

    fn nextControlLabel(self: *Emitter) usize {
        const id = self.control_label_id;
        self.control_label_id += 1;
        return id;
    }

    fn currentLoop(self: *Emitter) ?LoopLabels {
        if (self.loop_stack.items.len == 0) return null;
        return self.loop_stack.items[self.loop_stack.items.len - 1];
    }

    fn emitLoopBreak(self: *Emitter, loop: LoopLabels) !void {
        switch (loop.kind) {
            .while_loop => try self.out.writer.print("    jmp while_{d}_done\n", .{loop.id}),
            .stack_while => try self.out.writer.print("    jmp while_{d}_end\n", .{loop.id}),
            .for_loop => try self.out.writer.print("    jmp for_{d}_done\n", .{loop.id}),
        }
    }

    fn emitLoopContinue(self: *Emitter, loop: LoopLabels) !void {
        switch (loop.kind) {
            .while_loop => try self.out.writer.print("    jmp while_{d}_top\n", .{loop.id}),
            .stack_while => try self.out.writer.print("    jmp while_{d}_start\n", .{loop.id}),
            .for_loop => try self.out.writer.print("    jmp for_{d}_next\n", .{loop.id}),
        }
    }

    fn currentBlockExpr(self: *Emitter, label: []const u8) ?BlockExprLabels {
        var index = self.block_stack.items.len;
        while (index > 0) {
            index -= 1;
            const block = self.block_stack.items[index];
            if (std.mem.eql(u8, block.label, label)) return block;
        }
        return null;
    }

    fn findModuleDependencyOrdinal(module: ast.ZeroPageModule, id: []const u8) ?usize {
        for (module.deps, 0..) |dep, index| {
            if (std.mem.eql(u8, dep, id)) return index;
        }
        return null;
    }

    fn findModuleGraphNode(graph: ast.ModuleDependencyGraphOptions, id: []const u8) ?ast.ModuleDependencyGraphNode {
        for (graph.nodes) |node| {
            if (std.mem.eql(u8, node.id, id)) return node;
        }
        return null;
    }
};
