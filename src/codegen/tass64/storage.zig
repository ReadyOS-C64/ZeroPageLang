const std = @import("std");
const ast = @import("../../ast.zig");
const facts = @import("static_local_facts.zig");
const runtime = @import("runtime.zig");
const sections = @import("sections.zig");
const types = @import("types.zig");

const arrayElemIsWord = types.arrayElemIsWord;
const arrayElemToType = types.arrayElemToType;
const arrayTypesEqual = types.arrayTypesEqual;
const findStructFieldDecl = types.findStructFieldDecl;
const findStructFieldInit = types.findStructFieldInit;
const optionalChildToType = types.optionalChildToType;
const screenCode = runtime.screenCode;

const copy_loop_threshold = 8;

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

fn optionalChildStorageBytes(child: ast.OptionalChildType) u16 {
    return switch (child) {
        .scalar => |scalar| switch (scalar) {
            .u16, .i16, .usize => 2,
            else => 1,
        },
        .pointer => 2,
        .far_bytes => 5,
        .near_view => 2,
        .custom => 1,
    };
}

fn arrayElemStorageBytes(self: anytype, elem: ast.ArrayElemType) anyerror!u16 {
    return switch (elem) {
        .scalar => |scalar| switch (scalar) {
            .u16, .i16, .usize => 2,
            else => 1,
        },
        .custom => |custom| if (self.program.findStruct(custom) != null)
            try structStorageBytes(self, custom)
        else if (self.program.findEnum(custom) != null)
            1
        else
            error.UnsupportedArrayType,
    };
}

fn arrayStorageBytes(self: anytype, ty: ast.ArrayType) anyerror!u16 {
    const elem_bytes = try arrayElemStorageBytes(self, ty.elem);
    const bytes = @as(u32, ty.len) * @as(u32, elem_bytes);
    return std.math.cast(u16, bytes) orelse error.Overflow;
}

fn arrayElemStructName(self: anytype, elem: ast.ArrayElemType) ?[]const u8 {
    return switch (elem) {
        .custom => |custom| if (self.program.findStruct(custom) != null) custom else null,
        else => null,
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

pub fn emitCopyStructStorage(self: anytype, dest_function: []const u8, dest_prefix: []const u8, source_function: []const u8, source_prefix: []const u8, type_name: []const u8) !void {
    const byte_count = try structStorageBytes(self, type_name);
    if (byte_count >= copy_loop_threshold and byte_count <= 255) {
        const source_label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ source_function, source_prefix });
        defer self.allocator.free(source_label);
        const dest_label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ dest_function, dest_prefix });
        defer self.allocator.free(dest_label);
        try emitCopyRange(self, dest_label, source_label, byte_count);
        return;
    }
    try emitCopyStructFieldsInline(self, dest_function, dest_prefix, source_function, source_prefix, type_name);
}

fn emitCopyStructFieldsInline(self: anytype, dest_function: []const u8, dest_prefix: []const u8, source_function: []const u8, source_prefix: []const u8, type_name: []const u8) !void {
    const decl = self.program.findStruct(type_name) orelse return error.UnsupportedStruct;
    for (decl.fields) |field| {
        const dest_field = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ dest_prefix, field.name });
        defer self.allocator.free(dest_field);
        const source_field = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ source_prefix, field.name });
        defer self.allocator.free(source_field);
        switch (field.ty) {
            .array => |array_ty| try emitCopyArrayStorage(self, dest_function, dest_field, source_function, source_field, try arrayStorageBytes(self, array_ty)),
            .custom => |custom| {
                if (self.program.findStruct(custom) != null) {
                    try emitCopyStructFieldsInline(self, dest_function, dest_field, source_function, source_field, custom);
                } else {
                    try self.out.writer.print("    lda {s}_{s}\n    sta {s}_{s}\n", .{ source_function, source_field, dest_function, dest_field });
                }
            },
            .u16, .i16, .usize, .pointer => try self.out.writer.print(
                "    lda {s}_{s}\n    sta {s}_{s}\n    lda {s}_{s}+1\n    sta {s}_{s}+1\n",
                .{ source_function, source_field, dest_function, dest_field, source_function, source_field, dest_function, dest_field },
            ),
            .optional => |optional| if (optional.child == .pointer) {
                try self.out.writer.print(
                    "    lda {s}_{s}\n    sta {s}_{s}\n    lda {s}_{s}+1\n    sta {s}_{s}+1\n",
                    .{ source_function, source_field, dest_function, dest_field, source_function, source_field, dest_function, dest_field },
                );
            } else {
                // Preserve the separate existing optional representation paths.
                try self.out.writer.print("    lda {s}_{s}\n    sta {s}_{s}\n", .{ source_function, source_field, dest_function, dest_field });
            },
            else => try self.out.writer.print("    lda {s}_{s}\n    sta {s}_{s}\n", .{ source_function, source_field, dest_function, dest_field }),
        }
    }
}

pub fn emitCopyArrayStorage(self: anytype, dest_function: []const u8, dest_name: []const u8, source_function: []const u8, source_name: []const u8, byte_count: u16) !void {
    const source_label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ source_function, source_name });
    defer self.allocator.free(source_label);
    const dest_label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ dest_function, dest_name });
    defer self.allocator.free(dest_label);
    if (byte_count >= copy_loop_threshold and byte_count <= 255) {
        try emitCopyRange(self, dest_label, source_label, byte_count);
        return;
    }
    try emitCopyRangeInline(self, dest_label, source_label, byte_count);
}

pub fn emitCopyRangeInline(self: anytype, dest_label: []const u8, source_label: []const u8, byte_count: u16) !void {
    for (0..byte_count) |offset| {
        try self.out.writer.print("    lda {s}+{d}\n    sta {s}+{d}\n", .{ source_label, offset, dest_label, offset });
    }
}

fn emitCopyRange(self: anytype, dest_label: []const u8, source_label: []const u8, byte_count: u16) !void {
    if (std.mem.eql(u8, dest_label, source_label) or byte_count == 0) return;
    if (byte_count < copy_loop_threshold or byte_count > 255) {
        try emitCopyRangeInline(self, dest_label, source_label, byte_count);
        return;
    }
    const id = self.nextLabel();
    try self.out.writer.print(
        "    ldx #0\nzeropage_copy_{d}_loop:\n    lda {s},x\n    sta {s},x\n    inx\n    cpx #{d}\n    bne zeropage_copy_{d}_loop\n",
        .{ id, source_label, dest_label, byte_count, id },
    );
}

pub fn typeStorageBytes(self: anytype, ty: ast.Type) anyerror!u16 {
    return switch (ty) {
        .void => 0,
        .u16, .i16, .usize, .pointer => 2,
        .far_bytes, .far_view => 5,
        .near_view => 2,
        .optional => |optional| if (optional.child == .pointer) 2 else 1 + optionalChildStorageBytes(optional.child),
        .array => |array_ty| try arrayStorageBytes(self, array_ty),
        .custom => |custom| if (self.program.findStruct(custom) != null)
            try structStorageBytes(self, custom)
        else if (self.program.findUnion(custom) != null)
            try self.unionStorageBytes(custom)
        else
            1,
        else => 1,
    };
}

fn structStorageBytes(self: anytype, type_name: []const u8) anyerror!u16 {
    const decl = self.program.findStruct(type_name) orelse return error.UnsupportedStruct;
    var total: u16 = 0;
    for (decl.fields) |field| {
        total += try typeStorageBytes(self, field.ty);
    }
    return total;
}

pub fn emitVarSlots(self: anytype) !void {
    try self.out.writer.writeAll("\n; global static compiler/runtime slots\n");
    if (self.uses_math_tmp) try emitCompilerScratch(self, "zeropage_math_tmp:\n    .word 0\n");
    if (self.uses_multiply) try emitCompilerScratch(self, "zeropage_mul_lhs:\n    .word 0\nzeropage_mul_rhs:\n    .word 0\nzeropage_mul_result:\n    .word 0\n");
    if (!self.uses_multiply and self.stride_usage.usesLhs()) try emitCompilerScratch(self, "zeropage_mul_lhs:\n    .word 0\nzeropage_mul_result:\n    .word 0\n");
    if (self.uses_multiply_lhs and !self.uses_multiply and !self.stride_usage.usesLhs()) try emitCompilerScratch(self, "zeropage_mul_lhs:\n    .word 0\n");
    if (self.uses_shift) {
        if (self.program.zeropage_module != null) {
            try emitCompilerScratch(self, "zeropage_shift_value:\n    .word 0\nzeropage_shift_count:\n    .byte 0\n");
        } else {
            if (self.shift_usage.uses_value) try emitCompilerScratch(self, "zeropage_shift_value:\n    .word 0\n");
            if (self.shift_usage.needsCount()) try emitCompilerScratch(self, "zeropage_shift_count:\n    .byte 0\n");
        }
    }
    if (self.uses_hex) try emitCompilerScratch(self, "zeropage_hex_tmp:\n    .byte 0\n");
    if (self.uses_console) try emitRuntimeData(self, "zeropage_console_x:\n    .byte 0\nzeropage_console_y:\n    .byte 0\nzeropage_console_char_tmp:\n    .byte 0\nzeropage_console_string_len:\n    .byte 0\nzeropage_console_string_index:\n    .byte 0\n");
    if (self.uses_kernal_string) try emitRuntimeData(self, "zeropage_kernal_string_len:\n    .byte 0\nzeropage_kernal_string_index:\n    .byte 0\n");
    if (self.uses_keyboard_wait) try emitRuntimeData(self, "zeropage_keyboard_key:\n    .byte 0\n");
    if (self.uses_string_runtime) try emitRuntimeData(self, "zeropage_string_src_len:\n    .byte 0\nzeropage_string_dst_len:\n    .byte 0\nzeropage_string_dst_cap:\n    .byte 0\nzeropage_string_index:\n    .byte 0\n");
    if (self.uses_sleep or self.uses_sleep_frames) try emitRuntimeData(self, "zeropage_sleep_count:\n    .byte 0\n");
    if (self.uses_screen_tmp) try emitCompilerScratch(self, "zeropage_screen_tmp:\n    .byte 0\n");
    if (self.uses_switch) try emitCompilerScratch(self, "zeropage_switch_value:\n    .word 0\n");
    if (self.uses_union_switch) try emitCompilerScratch(self, "zeropage_union_switch_payload:\n    .word 0\n");
    if (self.uses_pointer) try emitCompilerScratch(self, "zeropage_ptr_value:\n    .word 0\n");
    if (self.uses_optional_tmp) try emitCompilerScratch(self, "zeropage_optional_tmp:\n    .byte 0,0,0,0,0,0\n");
    if (self.uses_stack_bridge_return) try emitCompilerScratch(self, "zeropage_stack_ret_lo:\n    .byte 0\nzeropage_stack_ret_hi:\n    .byte 0\n");
    if (self.usesReuTransferRuntime()) try emitRuntimeData(self, "zeropage_reu_c64_addr:\n    .word 0\nzeropage_reu_addr:\n    .byte 0,0,0\nzeropage_reu_len:\n    .word 0\n");
    if (self.uses_module_bank_runtime) try emitRuntimeData(self, "zeropage_module_bank_saved_port:\n    .byte 0\nzeropage_module_bank_saved_status:\n    .byte 0\nzeropage_module_bank_saved_a:\n    .byte 0\nzeropage_module_bank_saved_x:\n    .byte 0\n");
    if (self.uses_module_kernal_console_trampoline) try emitRuntimeData(self, "zeropage_module_kernal_trampoline_saved_status:\n    .byte 0\n");
    if (self.uses_module_registry_runtime) try emitModuleRegistryState(self);
    if (self.uses_module_state_runtime) try emitModuleStateRuntimeData(self);
    if (self.uses_module_load_runtime or self.uses_module_disk_load_runtime) try emitModuleLoaderSeed(self);
    if (self.uses_module_disk_load_runtime) try emitModuleDiskFilename(self);
    if (self.uses_module_dependency_load_runtime) try emitModuleDependencyDiskFilenames(self);
    if (self.module_graph_load_scratch.items.len != 0) {
        try sections.emitBegin(&self.out.writer, .runtime, .data, .static, .near);
        for (self.module_graph_load_scratch.items) |scratch| {
            for (0..scratch.row_count) |index| {
                try self.out.writer.print("zeropage_module_graph_load_{d}_row{d}_new:\n    .byte 0\n", .{ scratch.id, index });
            }
        }
        try sections.emitEnd(&self.out.writer, .runtime, .data);
    }
    if (self.uses_reu_fill) try emitRuntimeData(self, "zeropage_reu_fill_byte:\n    .byte 0\n");
    if (self.usesReuHeapAllocRuntime()) try emitRuntimeData(self, "zeropage_reu_heap_len:\n    .word 0\nzeropage_reu_heap_new_cursor:\n    .byte 0,0,0,0\nzeropage_reu_heap_result:\n    .byte 0,0,0,0,0\n");
    if (self.uses_reu_view_runtime) {
        try sections.emitBegin(&self.out.writer, .runtime, .data, .static, .near);
        try self.out.writer.writeAll("zeropage_reu_view_offset:\n    .word 0\nzeropage_reu_view_record:\n");
        try emitZeroBytes(self, 255);
        try sections.emitEnd(&self.out.writer, .runtime, .data);
    }
    if (self.usesReuHeapAllocRuntime() or self.usesReuHeapResetRuntime()) {
        try sections.emitBegin(&self.out.writer, .runtime, .data, .static, .near);
        for (self.program.zeropage_options.reu.heaps) |heap| {
            if (self.reuHeapUsesAllocRuntime(heap.name) or self.reuHeapUsesResetRuntime(heap.name)) {
                try self.out.writer.print("zeropage_reu_heap_{s}_cursor:\n    .byte ${x:0>2},${x:0>2},${x:0>2},${x:0>2}\n", .{
                    heap.name,
                    @as(u8, @truncate(heap.addr)),
                    @as(u8, @truncate(heap.addr >> 8)),
                    @as(u8, @truncate(heap.addr >> 16)),
                    @as(u8, @truncate(heap.addr >> 24)),
                });
            }
        }
        try sections.emitEnd(&self.out.writer, .runtime, .data);
    }
    if (self.usesHeapAllocRuntime() or self.usesHeapFreeRuntime()) try emitRuntimeData(self, "zeropage_heap_len:\n    .word 0\nzeropage_heap_new_cursor:\n    .word 0\nzeropage_heap_result:\n    .word 0\n");
    if (self.usesHeapAllocRuntime() or self.usesHeapResetRuntime() or self.usesHeapFreeRuntime()) {
        try sections.emitBegin(&self.out.writer, .runtime, .data, .static, .near);
        for (self.program.zeropage_options.heaps) |heap| {
            if (self.heapUsesAllocRuntime(heap.name) or self.heapUsesResetRuntime(heap.name) or self.heapUsesFreeRuntime(heap.name)) {
                try self.out.writer.print("zeropage_heap_{s}_cursor:\n    .word ${x:0>4}\n", .{ heap.name, heap.addr });
                if (heap.kind == .fixed) try self.out.writer.print("zeropage_heap_{s}_free_head:\n    .word 0\n", .{heap.name});
            }
        }
        try sections.emitEnd(&self.out.writer, .runtime, .data);
    }
    if (self.max_call_arg_temps != 0) try sections.emitBegin(&self.out.writer, .compiler, .scratch, .static, .near);
    for (0..self.max_call_arg_temps) |index| {
        try self.out.writer.print("zeropage_call_arg_{d}:\n    .word 0\n", .{index});
    }
    if (self.max_call_arg_temps != 0) try sections.emitEnd(&self.out.writer, .compiler, .scratch);
}

pub fn emitFunctionStaticFrame(self: anytype, function: ast.Function) !void {
    try sections.emitBegin(&self.out.writer, .{ .function = function.name }, .static_frame, .static, .near);
    for (function.params) |param| {
        try recordTypedRoot(self, function.name, param.name, param.ty, .parameter, null);
        if (self.isStructType(param.ty)) {
            try emitStructSlots(self, function.name, param.name, param.ty.custom);
        } else if (self.isUnionType(param.ty)) {
            try emitSlot(self, function.name, param.name, param.ty);
        } else {
            try emitSlot(self, function.name, param.name, param.ty);
        }
    }
    if (self.isStructType(function.return_type) or self.isUnionType(function.return_type) or function.return_type == .optional) try recordTypedRoot(self, function.name, "return", function.return_type, .return_buffer, null);
    if (self.isStructType(function.return_type)) {
        try emitStructSlots(self, function.name, "return", function.return_type.custom);
    } else if (self.isUnionType(function.return_type)) {
        try emitSlot(self, function.name, "return", function.return_type);
    } else if (function.return_type == .optional) {
        try emitSlot(self, function.name, "return", function.return_type);
    }
    try emitVarSlotsFor(self, function.name, function.body);
    try sections.emitEnd(&self.out.writer, .{ .function = function.name }, .static_frame);
}

fn emitModuleLoaderSeed(self: anytype) !void {
    const module = self.program.zeropage_module orelse return error.UnsupportedZeroPageModule;
    try sections.emitBegin(&self.out.writer, .runtime, .data, .static, .near);
    try self.out.writer.writeAll("zeropage_module_payload_jump_table:\n");
    for (module.exports) |export_decl| {
        try self.out.writer.print("    jmp {s}\n", .{export_decl.function_name});
    }
    try self.out.writer.writeAll("zeropage_module_payload_jump_table_end:\n");
    try sections.emitEnd(&self.out.writer, .runtime, .data);
}

const ModuleRegistryRowInfo = struct {
    id: []const u8,
    role: u8,
    role_name: []const u8,
    dependency_ordinal_value: u16,
    dependency_ordinal_text: []const u8,
};

fn moduleRegistryEntryCount(module: ast.ZeroPageModule, graph: ?ast.ModuleDependencyGraphOptions) usize {
    if (graph) |g| {
        var count: usize = 1 + module.deps.len;
        for (g.nodes) |node| {
            if (findModuleDependencyOrdinal(module, node.id) == null) count += 1;
        }
        return count;
    }
    return 1 + module.deps.len;
}

fn moduleRegistryRowInfo(module: ast.ZeroPageModule, graph: ?ast.ModuleDependencyGraphOptions, row: usize) !ModuleRegistryRowInfo {
    if (row == 0) return .{ .id = module.id, .role = 0, .role_name = "current", .dependency_ordinal_value = 0xffff, .dependency_ordinal_text = "none" };
    if (row <= module.deps.len) {
        const dep_index = row - 1;
        return .{ .id = module.deps[dep_index], .role = 1, .role_name = "dependency", .dependency_ordinal_value = @intCast(dep_index), .dependency_ordinal_text = "direct" };
    }
    const g = graph orelse return error.UnknownZeroPageModule;
    var current_row: usize = 1 + module.deps.len;
    for (g.nodes) |node| {
        if (findModuleDependencyOrdinal(module, node.id) != null) continue;
        if (current_row == row) {
            return .{ .id = node.id, .role = 2, .role_name = "transitive", .dependency_ordinal_value = 0xffff, .dependency_ordinal_text = "none" };
        }
        current_row += 1;
    }
    return error.UnknownZeroPageModule;
}

fn findModuleDependencyOrdinal(module: ast.ZeroPageModule, id: []const u8) ?usize {
    for (module.deps, 0..) |dep, index| {
        if (std.mem.eql(u8, dep, id)) return index;
    }
    return null;
}

fn emitModuleRegistryState(self: anytype) !void {
    const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
    const module = self.program.zeropage_module;
    const registry = loader.registry;
    const manifest = loader.disk_manifest;
    const has_registry_plan = module != null and registry != null and manifest != null;
    const capacity: usize = if (has_registry_plan) registry.?.capacity else 1;
    const entry_count: usize = if (has_registry_plan) moduleRegistryEntryCount(module.?, loader.dependency_graph) else 1;

    try sections.emitBegin(&self.out.writer, .runtime, .data, .static, .near);
    try self.out.writer.print(
        \\zeropage_module_registry_load_window = ${x:0>4}
        \\zeropage_module_registry_load_window_size = ${x:0>4}
        \\zeropage_module_registry_reu_cache = ${x:0>6}
        \\zeropage_module_registry_jump_table = ${x:0>4}
        \\zeropage_module_registry_capacity = {d}
        \\zeropage_module_registry_entry_count = {d}
        \\zeropage_module_registry_row_size = 2
        \\
    , .{
        loader.load_window.addr,
        loader.load_window.size,
        loader.reu_cache.addr,
        loader.load_window.addr,
        capacity,
        entry_count,
    });
    if (self.uses_module_load_runtime or self.uses_module_disk_load_runtime) {
        try self.out.writer.writeAll("zeropage_module_registry_payload_size = zeropage_module_payload_jump_table_end-zeropage_module_payload_jump_table+zeropage_module_payload_range_end-zeropage_module_payload_range_start\n");
    } else {
        try self.out.writer.writeAll("zeropage_module_registry_payload_size = 0\n");
    }
    if (loader.state) |state| {
        if (state.current.mode == .persist_in_reu) {
            const rows: u32 = if (has_registry_plan) registry.?.capacity else 1;
            const snapshot_reu = loader.reu_cache.addr + rows * @as(u32, loader.load_window.size);
            try self.out.writer.print(
                \\zeropage_module_state_current_snapshot_reu = ${x:0>6}
                \\zeropage_module_state_current_range_count = {d}
                \\
            , .{ snapshot_reu, state.current.ranges.len });
        }
        if (module) |module_decl| {
            const rows: u32 = if (has_registry_plan) registry.?.capacity else 1;
            for (module_decl.deps, 0..) |dep_id, dep_index| {
                const dep_state = findModuleStateDependency(state, dep_id) orelse continue;
                if (dep_state.state.mode != .persist_in_reu) continue;
                const row = dep_index + 1;
                const snapshot_reu = loader.reu_cache.addr + (rows + 1 + @as(u32, @intCast(dep_index))) * @as(u32, loader.load_window.size);
                try self.out.writer.print(
                    \\zeropage_module_state_dep{d}_snapshot_reu = ${x:0>6}
                    \\zeropage_module_state_dep{d}_range_count = {d}
                    \\
                , .{ row, snapshot_reu, row, dep_state.state.ranges.len });
            }
        }
    }

    try self.out.writer.writeAll("; zeropage_module_registry rows: loaded/refcount pairs\n");
    try self.out.writer.writeAll("zeropage_module_registry_active_row:\n    .byte $ff\n");
    for (loader.extra_load_windows) |entry| {
        try self.out.writer.print("zeropage_module_registry_active_row_{s}:\n    .byte $ff\n", .{entry.name});
    }
    try self.out.writer.writeAll("zeropage_module_registry_rows:\n");
    for (0..capacity) |row| {
        const reu_cache_addr = loader.reu_cache.addr + @as(u32, @intCast(row)) * @as(u32, loader.load_window.size);
        if (has_registry_plan and row == 0) {
            try self.out.writer.print(
                \\; zeropage_module_registry_row {d} id={s} role=current dependency_ordinal=none filename={s} reu_cache=${x:0>6} load_window=${x:0>4}
                \\zeropage_module_registry_row{d}_role = 0
                \\zeropage_module_registry_row{d}_dependency_ordinal = $ffff
                \\zeropage_module_registry_row{d}_reu_cache = ${x:0>6}
                \\
            , .{ row, module.?.id, manifest.?.current, reu_cache_addr, loader.load_window.addr, row, row, row, reu_cache_addr });
        } else if (has_registry_plan and row < entry_count) {
            const row_info = try moduleRegistryRowInfo(module.?, loader.dependency_graph, row);
            const dep_manifest = findModuleRegistryManifestDependency(manifest.?, row_info.id) orelse return error.InvalidZeroPageModuleDiskManifest;
            try self.out.writer.print(
                \\; zeropage_module_registry_row {d} id={s} role={s} dependency_ordinal={s} filename={s} reu_cache=${x:0>6} load_window=${x:0>4}
                \\zeropage_module_registry_row{d}_role = {d}
                \\zeropage_module_registry_row{d}_dependency_ordinal = {d}
                \\zeropage_module_registry_row{d}_reu_cache = ${x:0>6}
                \\
            , .{ row, row_info.id, row_info.role_name, row_info.dependency_ordinal_text, dep_manifest.filename, reu_cache_addr, loader.load_window.addr, row, row_info.role, row, row_info.dependency_ordinal_value, row, reu_cache_addr });
        } else {
            try self.out.writer.print(
                \\; zeropage_module_registry_row {d} id=<reserved> role=reserved dependency_ordinal=none reu_cache=${x:0>6} load_window=${x:0>4}
                \\zeropage_module_registry_row{d}_role = 2
                \\zeropage_module_registry_row{d}_dependency_ordinal = $ffff
                \\zeropage_module_registry_row{d}_reu_cache = ${x:0>6}
                \\
            , .{ row, reu_cache_addr, loader.load_window.addr, row, row, row, reu_cache_addr });
        }

        try self.out.writer.print("zeropage_module_registry_row{d}_loaded:\n", .{row});
        if (row == 0) try self.out.writer.writeAll("zeropage_module_registry_loaded:\n");
        try self.out.writer.writeAll("    .byte 0\n");
        try self.out.writer.print("zeropage_module_registry_row{d}_refcount:\n", .{row});
        if (row == 0) try self.out.writer.writeAll("zeropage_module_registry_refcount:\n");
        try self.out.writer.writeAll("    .byte 0\n");
    }
    try self.out.writer.writeAll("zeropage_module_registry_rows_end:\n");
    try sections.emitEnd(&self.out.writer, .runtime, .data);
}

fn emitModuleStateRuntimeData(self: anytype) !void {
    const loader = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
    const state = loader.state orelse return;
    try sections.emitBegin(&self.out.writer, .runtime, .data, .static, .near);
    if (state.current.mode == .persist_in_reu) {
        try self.out.writer.writeAll("zeropage_module_state_current_saved:\n    .byte 0\n");
    }
    if (self.program.zeropage_module) |module| {
        for (module.deps, 0..) |dep_id, dep_index| {
            const dep_state = findModuleStateDependency(state, dep_id) orelse continue;
            if (dep_state.state.mode != .persist_in_reu) continue;
            try self.out.writer.print("zeropage_module_state_dep{d}_saved:\n    .byte 0\n", .{dep_index + 1});
        }
    }
    try sections.emitEnd(&self.out.writer, .runtime, .data);
}

fn findModuleStateDependency(state: ast.ModuleStateOptions, id: []const u8) ?ast.DependencyModuleState {
    for (state.deps) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

fn findModuleRegistryManifestDependency(manifest: ast.ModuleDiskManifestOptions, id: []const u8) ?ast.ModuleDiskManifestDependency {
    for (manifest.deps) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

fn emitModuleDiskFilename(self: anytype) !void {
    const filename = findModuleDiskFilename(self.program) orelse return error.UnsupportedZeroPageModule;
    try sections.emitBegin(&self.out.writer, .runtime, .rodata, .static, .near);
    try self.out.writer.writeAll("zeropage_module_disk_filename:\n");
    for (filename) |byte| try self.out.writer.print("    .byte ${x:0>2}\n", .{moduleDiskFilenameByte(byte)});
    try self.out.writer.writeAll("zeropage_module_disk_filename_end:\n");
    try sections.emitEnd(&self.out.writer, .runtime, .rodata);
}

fn emitModuleDependencyDiskFilenames(self: anytype) !void {
    const module = self.program.zeropage_module orelse return error.UnknownZeroPageModule;
    const modules = self.program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
    const manifest = modules.disk_manifest orelse return error.MissingZeroPageModuleLoader;
    try sections.emitBegin(&self.out.writer, .runtime, .rodata, .static, .near);
    var it = self.module_dependency_load_rows.iterator();
    while (it.next()) |entry| {
        const row = entry.key_ptr.*;
        if (row == 0) return error.UnknownZeroPageModule;
        const row_info = try moduleRegistryRowInfo(module, modules.dependency_graph, row);
        const dep_id = row_info.id;
        const dep_manifest = findModuleRegistryManifestDependency(manifest, dep_id) orelse return error.InvalidZeroPageModuleDiskManifest;
        try self.out.writer.print("zeropage_module_dependency_row{d}_filename:\n", .{row});
        for (dep_manifest.filename) |byte| try self.out.writer.print("    .byte ${x:0>2}\n", .{moduleDiskFilenameByte(byte)});
        try self.out.writer.print("zeropage_module_dependency_row{d}_filename_end:\n", .{row});
    }
    try sections.emitEnd(&self.out.writer, .runtime, .rodata);
}

fn moduleDiskFilenameByte(byte: u8) u8 {
    return if (byte >= 'a' and byte <= 'z') byte - ('a' - 'A') else byte;
}

fn findModuleDiskFilename(program: ast.Program) ?[]const u8 {
    if (program.zeropage_options.modules) |modules| {
        if (modules.policy) |policy| {
            if (policy.current.mode == .preload or policy.current.mode == .on_demand) return policy.current.filename;
        }
    }
    for (program.functions) |function| {
        if (findModuleDiskFilenameInStmts(function.body)) |filename| return filename;
    }
    return null;
}

fn findModuleDiskFilenameInStmts(statements: []const ast.Stmt) ?[]const u8 {
    for (statements) |stmt| switch (stmt) {
        .var_decl => |decl| if (findModuleDiskFilenameInExpr(decl.init)) |filename| return filename,
        .assign => |assign| if (findModuleDiskFilenameInExpr(assign.value)) |filename| return filename,
        inline .add_assign, .sub_assign, .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => |assign| if (findModuleDiskFilenameInExpr(assign.value)) |filename| return filename,
        .if_stmt => |if_stmt| {
            if (findModuleDiskFilenameInExpr(if_stmt.condition)) |filename| return filename;
            if (findModuleDiskFilenameInStmts(if_stmt.then_body)) |filename| return filename;
            if (findModuleDiskFilenameInStmts(if_stmt.else_body)) |filename| return filename;
        },
        .while_stmt => |while_stmt| {
            if (findModuleDiskFilenameInExpr(while_stmt.condition)) |filename| return filename;
            if (findModuleDiskFilenameInStmts(while_stmt.body)) |filename| return filename;
        },
        .for_stmt => |for_stmt| if (findModuleDiskFilenameInStmts(for_stmt.body)) |filename| return filename,
        .switch_stmt => |switch_stmt| {
            if (findModuleDiskFilenameInExpr(switch_stmt.operand)) |filename| return filename;
            for (switch_stmt.prongs) |prong| if (findModuleDiskFilenameInStmts(prong.body)) |filename| return filename;
        },
        .discard, .return_expr => |expr| if (findModuleDiskFilenameInExpr(expr)) |filename| return filename,
        .break_expr => |break_expr| if (findModuleDiskFilenameInExpr(break_expr.value)) |filename| return filename,
        .field_assign => |field| if (findModuleDiskFilenameInExpr(field.value)) |filename| return filename,
        else => {},
    };
    return null;
}

fn findModuleDiskFilenameInExpr(expr: ast.Expr) ?[]const u8 {
    return switch (expr) {
        .module_disk_load => |load| load.filename,
        inline .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| findModuleDiskFilenameInExpr(binary.lhs.*) orelse findModuleDiskFilenameInExpr(binary.rhs.*),
        .not, .bit_not, .deref, .ptr_from_int, .int_from_ptr => |child| findModuleDiskFilenameInExpr(child.*),
        .as_cast => |cast| findModuleDiskFilenameInExpr(cast.expr.*),
        .if_expr => |if_expr| findModuleDiskFilenameInExpr(if_expr.condition.*) orelse findModuleDiskFilenameInExpr(if_expr.then_expr.*) orelse findModuleDiskFilenameInExpr(if_expr.else_expr.*),
        .block_expr => |block_expr| findModuleDiskFilenameInStmts(block_expr.body),
        .call => |call| blk: {
            for (call.args) |arg| if (findModuleDiskFilenameInExpr(arg)) |filename| break :blk filename;
            break :blk null;
        },
        .module_call => |call| blk: {
            for (call.args) |arg| if (findModuleDiskFilenameInExpr(arg)) |filename| break :blk filename;
            break :blk null;
        },
        else => null,
    };
}

fn emitCompilerScratch(self: anytype, text: []const u8) !void {
    try sections.emitBegin(&self.out.writer, .compiler, .scratch, .static, .near);
    try self.out.writer.writeAll(text);
    try sections.emitEnd(&self.out.writer, .compiler, .scratch);
}

fn emitRuntimeData(self: anytype, text: []const u8) !void {
    try sections.emitBegin(&self.out.writer, .runtime, .data, .static, .near);
    try self.out.writer.writeAll(text);
    try sections.emitEnd(&self.out.writer, .runtime, .data);
}

pub fn emitRoDataConstants(self: anytype) !void {
    if (self.program.string_constants.len == 0 and self.program.array_constants.len == 0) return;

    var owners: std.ArrayList([]const u8) = .empty;
    defer owners.deinit(self.allocator);
    for (self.program.string_constants) |constant| try appendUniqueOwner(self.allocator, &owners, constant.module_owner);
    for (self.program.array_constants) |constant| try appendUniqueOwner(self.allocator, &owners, constant.module_owner);

    try self.out.writer.writeAll("\n; module rodata constants\n");
    for (owners.items) |owner| {
        try sections.emitBegin(&self.out.writer, .{ .module = owner }, .rodata, .static, .near);
        for (self.program.string_constants) |constant| {
            if (!std.mem.eql(u8, constant.module_owner, owner)) continue;
            if (self.constantHasMemoryPlacement(constant.name)) continue;
            try emitStringConstant(self, constant);
        }
        for (self.program.array_constants) |constant| {
            if (!std.mem.eql(u8, constant.module_owner, owner)) continue;
            if (self.constantHasMemoryPlacement(constant.name)) continue;
            try self.validateArrayLiteral("main", constant.ty, .{ .ty = constant.ty, .values = constant.values });
            try recordRoDataArray(self, constant);
            try self.out.writer.print("zeropage_arr_{s}:\n", .{constant.name});
            try emitArrayData(self, constant.ty, constant.values);
        }
        try sections.emitEnd(&self.out.writer, .{ .module = owner }, .rodata);
    }
}

pub fn emitNamedRoDataConstant(self: anytype, name: []const u8) !void {
    if (self.program.findString(name)) |constant| {
        try sections.emitBegin(&self.out.writer, .{ .module = constant.module_owner }, .rodata, .static, .near);
        try emitStringConstant(self, constant);
        try sections.emitEnd(&self.out.writer, .{ .module = constant.module_owner }, .rodata);
        return;
    }
    if (self.program.findArray(name)) |constant| {
        try sections.emitBegin(&self.out.writer, .{ .module = constant.module_owner }, .rodata, .static, .near);
        try self.validateArrayLiteral("main", constant.ty, .{ .ty = constant.ty, .values = constant.values });
        try recordRoDataArray(self, constant);
        try self.out.writer.print("zeropage_arr_{s}:\n", .{constant.name});
        try emitArrayData(self, constant.ty, constant.values);
        try sections.emitEnd(&self.out.writer, .{ .module = constant.module_owner }, .rodata);
        return;
    }
    return error.UnknownZeroPageMemoryPlacementDeclaration;
}

fn appendUniqueOwner(allocator: std.mem.Allocator, owners: *std.ArrayList([]const u8), owner: []const u8) !void {
    for (owners.items) |existing| {
        if (std.mem.eql(u8, existing, owner)) return;
    }
    try owners.append(allocator, owner);
}

fn emitStringConstant(self: anytype, constant: ast.StringConstant) !void {
    if (self.static_facts) |inventory| {
        const label = try std.fmt.allocPrint(self.allocator, "zeropage_str_{s}", .{constant.name});
        defer self.allocator.free(label);
        try inventory.append(self.allocator, .{ .owner = constant.module_owner, .label = label, .binding = constant.name, .origin = .constant_string, .width = @intCast(constant.bytes.len), .ty = null, .shape = .string_constant, .section = .rodata });
    }
    try self.out.writer.print("zeropage_str_{s}:\n", .{constant.name});
    if (constant.bytes.len == 0) return;
    try self.out.writer.writeAll("    .byte ");
    for (constant.bytes, 0..) |byte, i| {
        if (i != 0) try self.out.writer.writeAll(",");
        try self.out.writer.print("${x:0>2}", .{byte});
    }
    try self.out.writer.writeAll("\n");
}

pub fn emitArrayData(self: anytype, ty: ast.ArrayType, values: []const ast.Expr) !void {
    if (arrayElemStructName(self, ty.elem)) |struct_name| {
        for (values) |value| try emitLiteralDataForType(self, .{ .custom = struct_name }, value);
        return;
    }
    var column: usize = 0;
    for (values) |value| {
        const literal = try arrayConstValue(self, ty, value);
        if (column == 0) {
            try self.out.writer.writeAll("    .byte ");
        } else {
            try self.out.writer.writeAll(",");
        }
        if (arrayElemIsWord(ty.elem)) {
            try self.out.writer.print("<{d},>{d}", .{ literal, literal });
            column += 2;
        } else {
            try self.out.writer.print("{d}", .{@as(u8, @truncate(literal))});
            column += 1;
        }
        if (column >= 16) {
            try self.out.writer.writeAll("\n");
            column = 0;
        }
    }
    if (column != 0 or values.len == 0) try self.out.writer.writeAll("\n");
}

pub fn arrayConstValue(self: anytype, ty: ast.ArrayType, expr: ast.Expr) !u16 {
    return switch (expr) {
        .value => |value| switch (value) {
            .int => |n| n,
            .bool => |b| @as(u16, @intFromBool(b)),
            .char => |ch| screenCode(ch),
            .field => |field| blk: {
                const elem_ty = arrayElemToType(ty.elem);
                if (!self.isEnumType(elem_ty)) break :blk error.UnsupportedArrayLiteral;
                if (self.program.findEnum(field.base)) |_| {
                    if (!typesEqual(elem_ty, .{ .custom = field.base })) break :blk error.UnsupportedArrayLiteral;
                    break :blk try self.enumTagValue(field.base, field.field);
                }
                break :blk error.UnsupportedArrayLiteral;
            },
            .enum_literal => |literal| try self.enumLiteralValue(arrayElemToType(ty.elem), literal),
            else => error.UnsupportedArrayLiteral,
        },
        else => error.UnsupportedArrayLiteral,
    };
}

fn emitLiteralDataForType(self: anytype, ty: ast.Type, expr: ast.Expr) anyerror!void {
    switch (ty) {
        .array => |array_ty| {
            const literal = switch (expr) {
                .array_literal => |literal| literal,
                else => return error.UnsupportedArrayLiteral,
            };
            try self.validateArrayLiteral("main", array_ty, literal);
            for (literal.values) |value| try emitLiteralDataForType(self, arrayElemToType(array_ty.elem), value);
        },
        .custom => |custom| {
            if (self.program.findStruct(custom)) |decl| {
                const literal = switch (expr) {
                    .struct_literal => |literal| literal,
                    else => return error.UnsupportedStruct,
                };
                if (!std.mem.eql(u8, literal.type_name, custom)) return error.UnsupportedStruct;
                for (decl.fields) |field| {
                    const init = findStructFieldInit(literal.fields, field.name) orelse return error.UnsupportedStruct;
                    try emitLiteralDataForType(self, field.ty, init.value);
                }
                for (literal.fields) |init| {
                    if (findStructFieldDecl(decl, init.name) == null) return error.UnsupportedStruct;
                }
                return;
            }
            const value = try scalarConstValue(self, ty, expr);
            try emitScalarData(self, ty, value);
        },
        else => {
            const value = try scalarConstValue(self, ty, expr);
            try emitScalarData(self, ty, value);
        },
    }
}

fn scalarConstValue(self: anytype, expected_ty: ast.Type, expr: ast.Expr) anyerror!u16 {
    if (self.isEnumType(expected_ty)) {
        return switch (expr) {
            .value => |value| switch (value) {
                .field => |field| blk: {
                    if (self.program.findEnum(field.base)) |_| {
                        if (!typesEqual(expected_ty, .{ .custom = field.base })) break :blk error.UnsupportedArrayLiteral;
                        break :blk try self.enumTagValue(field.base, field.field);
                    }
                    break :blk error.UnsupportedArrayLiteral;
                },
                .enum_literal => |literal| try self.enumLiteralValue(expected_ty, literal),
                else => error.UnsupportedArrayLiteral,
            },
            else => error.UnsupportedArrayLiteral,
        };
    }
    return switch (expr) {
        .value => |value| switch (value) {
            .int => |n| n,
            .bool => |b| @as(u16, @intFromBool(b)),
            .char => |ch| screenCode(ch),
            else => error.UnsupportedArrayLiteral,
        },
        else => error.UnsupportedArrayLiteral,
    };
}

fn emitScalarData(self: anytype, ty: ast.Type, value: u16) !void {
    if (ty == .u16 or ty == .i16 or ty == .usize) {
        try self.out.writer.print("    .byte <{d},>{d}\n", .{ value, value });
    } else {
        try self.out.writer.print("    .byte {d}\n", .{@as(u8, @truncate(value))});
    }
}

pub fn emitVarSlotsFor(self: anytype, function_name: []const u8, statements: []const ast.Stmt) !void {
    for (statements) |stmt| {
        switch (stmt) {
            .var_decl => |decl| {
                const decl_ty = try self.localDeclType(function_name, decl);
                try recordTypedRoot(self, function_name, decl.name, decl_ty, .local, null);
                if (self.isStructType(decl_ty)) {
                    try emitStructSlots(self, function_name, decl.name, decl_ty.custom);
                } else {
                    try emitSlot(self, function_name, decl.name, decl_ty);
                }
                try emitVarSlotsForExpr(self, function_name, decl.init);
            },
            .string_var => |decl| try emitStringSlot(self, function_name, decl),
            .assign => |assign| try emitVarSlotsForExpr(self, function_name, assign.value),
            .add_assign => |assign| try emitVarSlotsForExpr(self, function_name, assign.value),
            .sub_assign => |assign| try emitVarSlotsForExpr(self, function_name, assign.value),
            .mul_assign => |assign| try emitVarSlotsForExpr(self, function_name, assign.value),
            .bit_and_assign => |assign| try emitVarSlotsForExpr(self, function_name, assign.value),
            .bit_or_assign => |assign| try emitVarSlotsForExpr(self, function_name, assign.value),
            .bit_xor_assign => |assign| try emitVarSlotsForExpr(self, function_name, assign.value),
            .shl_assign => |assign| try emitVarSlotsForExpr(self, function_name, assign.value),
            .shr_assign => |assign| try emitVarSlotsForExpr(self, function_name, assign.value),
            .deref_assign => |assign| {
                try emitVarSlotsForExpr(self, function_name, assign.target);
                try emitVarSlotsForExpr(self, function_name, assign.value);
            },
            .array_assign => |assign| try emitVarSlotsForArrayAssign(self, function_name, assign),
            .array_add_assign => |assign| try emitVarSlotsForArrayAssign(self, function_name, assign),
            .array_sub_assign => |assign| try emitVarSlotsForArrayAssign(self, function_name, assign),
            .array_mul_assign => |assign| try emitVarSlotsForArrayAssign(self, function_name, assign),
            .array_bit_and_assign => |assign| try emitVarSlotsForArrayAssign(self, function_name, assign),
            .array_bit_or_assign => |assign| try emitVarSlotsForArrayAssign(self, function_name, assign),
            .array_bit_xor_assign => |assign| try emitVarSlotsForArrayAssign(self, function_name, assign),
            .array_shl_assign => |assign| try emitVarSlotsForArrayAssign(self, function_name, assign),
            .array_shr_assign => |assign| try emitVarSlotsForArrayAssign(self, function_name, assign),
            .array_field_assign => |assign| {
                try emitVarSlotsForExpr(self, function_name, assign.index);
                try emitVarSlotsForExpr(self, function_name, assign.value);
            },
            .discard => |expr| try emitVarSlotsForExpr(self, function_name, expr),
            .struct_var => |struct_var| {
                try recordTypedRoot(self, function_name, struct_var.name, .{ .custom = struct_var.type_name }, .local, null);
                try emitStructSlots(self, function_name, struct_var.name, struct_var.type_name);
                for (struct_var.fields) |field| try emitVarSlotsForExpr(self, function_name, field.value);
            },
            .while_stmt => |while_stmt| {
                try emitVarSlotsForExpr(self, function_name, while_stmt.condition);
                try emitVarSlotsFor(self, function_name, while_stmt.body);
            },
            .for_stmt => |for_stmt| {
                try emitForSlots(self, function_name, for_stmt);
                try emitVarSlotsFor(self, function_name, for_stmt.body);
            },
            .switch_stmt => |switch_stmt| {
                try emitVarSlotsForExpr(self, function_name, switch_stmt.operand);
                const operand_ty = try self.exprType(function_name, switch_stmt.operand);
                for (switch_stmt.prongs) |prong| {
                    if (prong.payload_name) |payload_name| {
                        const payload_ty = if (self.isUnionType(operand_ty))
                            (try self.switchPayloadTypeForSelectors(operand_ty, prong.selectors)) orelse return error.UnsupportedSwitchPayload
                        else
                            operand_ty;
                        try recordTypedRoot(self, function_name, payload_name, payload_ty, .payload, null);
                        try emitSlot(self, function_name, payload_name, payload_ty);
                    }
                    try emitVarSlotsFor(self, function_name, prong.body);
                }
            },
            .if_stmt => |if_stmt| {
                try emitVarSlotsForExpr(self, function_name, if_stmt.condition);
                if (if_stmt.payload_name) |payload_name| {
                    const condition_ty = try self.exprType(function_name, if_stmt.condition);
                    if (condition_ty != .optional) return error.UnsupportedOptional;
                    try recordTypedRoot(self, function_name, payload_name, optionalChildToType(condition_ty.optional.child), .payload, null);
                    try emitSlot(self, function_name, payload_name, optionalChildToType(condition_ty.optional.child));
                }
                try emitVarSlotsFor(self, function_name, if_stmt.then_body);
                try emitVarSlotsFor(self, function_name, if_stmt.else_body);
            },
            .call => |call| for (call.args) |arg| try emitVarSlotsForExpr(self, function_name, arg),
            .return_expr => |expr| try emitVarSlotsForExpr(self, function_name, expr),
            .break_expr => |break_expr| try emitVarSlotsForExpr(self, function_name, break_expr.value),
            .test6502 => |call| try emitVarSlotsForTest6502Call(self, function_name, call),
            .builtin => |builtin| try emitVarSlotsForBuiltin(self, function_name, builtin),
            .reu => |call| try emitVarSlotsForReuStmt(self, function_name, call),
            .reu_heap_reset => {},
            .heap_reset => {},
            .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph => {},
            .heap_free => |free| try emitVarSlotsForExpr(self, function_name, free.ptr.*),
            .field_assign => |field| try emitVarSlotsForExpr(self, function_name, field.value),
            else => {},
        }
    }
}

pub fn emitVarSlotsForExpr(self: anytype, function_name: []const u8, expr: ast.Expr) anyerror!void {
    switch (expr) {
        .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| {
            try emitVarSlotsForExpr(self, function_name, binary.lhs.*);
            try emitVarSlotsForExpr(self, function_name, binary.rhs.*);
        },
        .not, .bit_not, .deref, .ptr_from_int, .int_from_ptr => |child| try emitVarSlotsForExpr(self, function_name, child.*),
        .as_cast => |as_cast| try emitVarSlotsForExpr(self, function_name, as_cast.expr.*),
        .address_of, .size_of, .align_of, .offset_of => {},
        .if_expr => |if_expr| {
            try emitVarSlotsForExpr(self, function_name, if_expr.condition.*);
            if (if_expr.payload_name) |payload_name| {
                const condition_ty = try self.exprType(function_name, if_expr.condition.*);
                if (condition_ty != .optional) return error.UnsupportedOptional;
                try recordTypedRoot(self, function_name, payload_name, optionalChildToType(condition_ty.optional.child), .payload, null);
                try emitSlot(self, function_name, payload_name, optionalChildToType(condition_ty.optional.child));
            }
            try emitVarSlotsForExpr(self, function_name, if_expr.then_expr.*);
            try emitVarSlotsForExpr(self, function_name, if_expr.else_expr.*);
        },
        .switch_expr => |switch_expr| {
            try emitVarSlotsForExpr(self, function_name, switch_expr.operand.*);
            const operand_ty = try self.exprType(function_name, switch_expr.operand.*);
            for (switch_expr.prongs) |prong| {
                if (prong.payload_name) |payload_name| {
                    const payload_ty = if (self.isUnionType(operand_ty))
                        (try self.switchPayloadTypeForSelectors(operand_ty, prong.selectors)) orelse return error.UnsupportedSwitchPayload
                    else
                        operand_ty;
                    try recordTypedRoot(self, function_name, payload_name, payload_ty, .payload, null);
                    try emitSlot(self, function_name, payload_name, payload_ty);
                }
                try emitVarSlotsForExpr(self, function_name, prong.value);
            }
        },
        .block_expr => |block_expr| try emitVarSlotsFor(self, function_name, block_expr.body),
        .call => |call| for (call.args) |arg| try emitVarSlotsForExpr(self, function_name, arg),
        .array_literal => |literal| for (literal.values) |value| try emitVarSlotsForExpr(self, function_name, value),
        .array_index => |index| try emitVarSlotsForExpr(self, function_name, index.index.*),
        .array_field_index => |index| try emitVarSlotsForExpr(self, function_name, index.index.*),
        .struct_literal => |literal| for (literal.fields) |field| try emitVarSlotsForExpr(self, function_name, field.value),
        .reu_compare => |transfer| try emitVarSlotsForReuTransfer(self, function_name, transfer),
        .reu_heap_alloc => |alloc| try emitVarSlotsForExpr(self, function_name, alloc.len.*),
        .reu_view => |view| try emitVarSlotsForExpr(self, function_name, view.far.*),
        .far_view_materialize => {},
        .far_view_materialize_range => |range| try emitVarSlotsForExpr(self, function_name, range.start.*),
        .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded => {},
        .module_call => |call| for (call.args) |arg| try emitVarSlotsForExpr(self, function_name, arg),
        .heap_alloc => |alloc| try emitVarSlotsForExpr(self, function_name, alloc.len.*),
        .value, .c64_read_petscii, .c64_wait_petscii, .reu_present => {},
    }
}

pub fn emitVarSlotsForReuStmt(self: anytype, function_name: []const u8, call: ast.ReuStmt) anyerror!void {
    switch (call) {
        .copy_c64_to_reu, .copy_reu_to_c64, .swap => |transfer| try emitVarSlotsForReuTransfer(self, function_name, transfer),
        .fill => |fill| {
            try emitVarSlotsForExpr(self, function_name, fill.value.*);
            try emitVarSlotsForExpr(self, function_name, fill.len.*);
        },
        .copy_from_c64, .copy_to_c64 => |copy| {
            try emitVarSlotsForExpr(self, function_name, copy.far.*);
            try emitVarSlotsForExpr(self, function_name, copy.c64_addr.*);
            try emitVarSlotsForExpr(self, function_name, copy.len.*);
        },
    }
}

fn emitVarSlotsForReuTransfer(self: anytype, function_name: []const u8, transfer: ast.ReuTransfer) anyerror!void {
    try emitVarSlotsForExpr(self, function_name, transfer.c64_addr.*);
    try emitVarSlotsForExpr(self, function_name, transfer.len.*);
}

pub fn emitStructSlots(self: anytype, function_name: []const u8, prefix: []const u8, type_name: []const u8) !void {
    const decl = self.program.findStruct(type_name) orelse return error.UnsupportedStruct;
    try self.out.writer.print("{s}_{s}:\n", .{ function_name, prefix });
    for (decl.fields) |field| {
        const name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, field.name });
        defer self.allocator.free(name);
        switch (field.ty) {
            .custom => |custom| {
                if (self.program.findStruct(custom) != null) {
                    try emitStructSlots(self, function_name, name, custom);
                } else if (self.program.findUnion(custom) != null) {
                    return error.UnsupportedStruct;
                } else {
                    try emitSlot(self, function_name, name, field.ty);
                }
            },
            else => try emitSlot(self, function_name, name, field.ty),
        }
    }
}

pub fn emitVarSlotsForArrayAssign(self: anytype, function_name: []const u8, assign: ast.ArrayAssign) anyerror!void {
    try emitVarSlotsForExpr(self, function_name, assign.index);
    try emitVarSlotsForExpr(self, function_name, assign.value);
}

pub fn emitVarSlotsForTest6502Call(self: anytype, function_name: []const u8, call: ast.Test6502Call) anyerror!void {
    switch (call) {
        .expect_equal_u8 => |expect| try emitVarSlotsForExpr(self, function_name, expect.actual),
        .expect_equal_i8 => |expect| try emitVarSlotsForExpr(self, function_name, expect.actual),
        .expect_equal_bool => |expect| try emitVarSlotsForExpr(self, function_name, expect.actual),
        .expect_equal_u16 => |expect| try emitVarSlotsForExpr(self, function_name, expect.actual),
        .expect_null => |expect| try emitVarSlotsForExpr(self, function_name, expect.actual),
        .expect_some_u8 => |expect| try emitVarSlotsForExpr(self, function_name, expect.actual),
        .expect_some_u16 => |expect| try emitVarSlotsForExpr(self, function_name, expect.actual),
        .expect_some_bool => |expect| try emitVarSlotsForExpr(self, function_name, expect.actual),
        .expect_some_ptr => |expect| try emitVarSlotsForExpr(self, function_name, expect.actual),
        else => {},
    }
}

pub fn emitVarSlotsForBuiltin(self: anytype, function_name: []const u8, builtin: ast.BuiltinCall) anyerror!void {
    switch (builtin) {
        .put_at => |put| try emitVarSlotsForExpr(self, function_name, put.ch),
        .hex_at => |hex| try emitVarSlotsForExpr(self, function_name, hex.value),
        .hex16_at => |hex| try emitVarSlotsForExpr(self, function_name, hex.value),
        .console_print => |print| for (print.args) |arg| switch (arg) {
            .value => |expr| try emitVarSlotsForExpr(self, function_name, expr),
            .string => {},
        },
        .sleep_ticks => |sleep| try emitVarSlotsForExpr(self, function_name, sleep.ticks),
        .sleep_frames => |sleep| try emitVarSlotsForExpr(self, function_name, sleep.ticks),
        else => {},
    }
}

pub fn emitSlot(self: anytype, function_name: []const u8, name: []const u8, ty: ast.Type) !void {
    switch (ty) {
        .array => |array_ty| {
            try self.out.writer.print("{s}_{s}:\n", .{ function_name, name });
            try emitZeroBytes(self, try arrayStorageBytes(self, array_ty));
        },
        .custom => |custom| {
            if (self.program.findStruct(custom) != null) return error.UnsupportedStruct;
            if (self.program.findUnion(custom) != null) {
                try self.out.writer.print("{s}_{s}:\n", .{ function_name, name });
                try emitZeroBytes(self, try self.unionStorageBytes(custom));
                return;
            }
            try self.out.writer.print("{s}_{s}:\n    .byte 0\n", .{ function_name, name });
        },
        .pointer => |ptr| {
            _ = try self.validatePointerType(ptr);
            try self.out.writer.print("{s}_{s}:\n    .word 0\n", .{ function_name, name });
        },
        .far_bytes, .far_view => try self.out.writer.print("{s}_{s}:\n    .byte 0,0,0,0,0\n", .{ function_name, name }),
        .near_view => try self.out.writer.print("{s}_{s}:\n    .word 0\n", .{ function_name, name }),
        .optional => |optional| {
            _ = try self.validateOptionalType(optional);
            try self.out.writer.print("{s}_{s}:\n", .{ function_name, name });
            if (optional.child == .pointer) {
                try self.out.writer.writeAll("    .word 0\n");
            } else {
                try self.out.writer.writeAll("    .byte 0\n");
                try emitZeroBytes(self, optionalChildStorageBytes(optional.child));
            }
        },
        .u16, .i16, .usize => try self.out.writer.print("{s}_{s}:\n    .word 0\n", .{ function_name, name }),
        else => try self.out.writer.print("{s}_{s}:\n    .byte 0\n", .{ function_name, name }),
    }
}

pub fn emitForSlots(self: anytype, function_name: []const u8, for_stmt: ast.ForStmt) !void {
    if (self.static_facts != null) {
        const hidden = try std.fmt.allocPrint(self.allocator, "for_{d}_index", .{for_stmt.id});
        defer self.allocator.free(hidden);
        try recordTypedRoot(self, function_name, hidden, .usize, .hidden_counter, for_stmt.id);
    }
    try self.out.writer.print("{s}_for_{d}_index:\n    .word 0\n", .{ function_name, for_stmt.id });
    if (for_stmt.item_name) |item_name| {
        const item_ty = try self.forItemType(function_name, for_stmt);
        try recordTypedRoot(self, function_name, item_name, item_ty, .item_capture, for_stmt.id);
        try emitSlot(self, function_name, item_name, item_ty);
    }
    if (for_stmt.index_name) |index_name| {
        try recordTypedRoot(self, function_name, index_name, .usize, .index_capture, for_stmt.id);
        try emitSlot(self, function_name, index_name, .usize);
    }
}

pub fn emitZeroBytes(self: anytype, count: u16) !void {
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        if (i % 16 == 0) {
            if (i != 0) try self.out.writer.writeAll("\n");
            try self.out.writer.writeAll("    .byte ");
        } else {
            try self.out.writer.writeAll(",");
        }
        try self.out.writer.writeAll("0");
    }
    if (count != 0) try self.out.writer.writeAll("\n");
}

pub fn emitStringSlot(self: anytype, function_name: []const u8, decl: ast.StringVar) !void {
    if (self.static_facts) |inventory| {
        const label = try std.fmt.allocPrint(self.allocator, "{s}_{s}_len", .{ function_name, decl.name });
        defer self.allocator.free(label);
        try inventory.append(self.allocator, .{ .owner = function_name, .label = label, .binding = decl.name, .origin = .string_buffer, .width = @as(u32, decl.capacity) + 1, .ty = null, .shape = .string_buffer });
    }
    try self.out.writer.print("{s}_{s}_len:\n    .byte 0\n{s}_{s}_data:\n", .{ function_name, decl.name, function_name, decl.name });
    var i: u8 = 0;
    while (i < decl.capacity) : (i += 1) {
        if (i % 16 == 0) {
            if (i != 0) try self.out.writer.writeAll("\n");
            try self.out.writer.writeAll("    .byte ");
        } else {
            try self.out.writer.writeAll(",");
        }
        try self.out.writer.writeAll("0");
    }
    if (decl.capacity != 0) try self.out.writer.writeAll("\n");
}

fn typedSpec(self: anytype, owner: []const u8, binding: []const u8, label: []const u8, ty: ast.Type, origin: facts.Origin, loop_id: ?usize) !facts.Spec {
    var spec: facts.Spec = .{ .owner = owner, .binding = binding, .label = label, .ty = ty, .origin = origin, .loop_id = loop_id, .width = try typeStorageBytes(self, ty) };
    switch (ty) {
        .custom => |name| {
            spec.type_name = name;
            if (self.program.findEnum(name) != null) spec.enum_name = name else if (self.program.findStruct(name) != null) spec.shape = .structure else if (self.program.findUnion(name) != null) spec.shape = .tagged_union;
        },
        .array => |arr| {
            spec.shape = .array;
            spec.array_length = arr.len;
            spec.element_width = try typeStorageBytes(self, arrayElemToType(arr.elem));
            spec.child_kind = switch (arr.elem) {
                .scalar => |t| @tagName(t),
                .custom => "custom",
            };
            if (arr.elem == .custom) spec.child_name = arr.elem.custom;
        },
        .pointer => |ptr| {
            spec.shape = .pointer;
            spec.child_kind = switch (ptr.child) {
                .scalar => |t| @tagName(t),
                .custom => "custom",
            };
            if (ptr.child == .custom) spec.child_name = ptr.child.custom;
        },
        .optional => |optional| {
            spec.shape = .optional;
            spec.child_kind = @tagName(optional.child);
        },
        .void, .far_bytes, .far_view, .near_view => spec.shape = .other,
        else => {},
    }
    return spec;
}
fn recordTypedRoot(self: anytype, owner: []const u8, binding: []const u8, ty: ast.Type, origin: facts.Origin, loop_id: ?usize) !void {
    const inventory = self.static_facts orelse return;
    const label = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ owner, binding });
    defer self.allocator.free(label);
    try inventory.append(self.allocator, try typedSpec(self, owner, binding, label, ty, origin, loop_id));
}
fn recordRoDataArray(self: anytype, constant: ast.ArrayConstant) !void {
    const inventory = self.static_facts orelse return;
    const label = try std.fmt.allocPrint(self.allocator, "zeropage_arr_{s}", .{constant.name});
    defer self.allocator.free(label);
    var spec = try typedSpec(self, constant.module_owner, constant.name, label, .{ .array = constant.ty }, .constant_array, null);
    spec.section = .rodata;
    try inventory.append(self.allocator, spec);
}
