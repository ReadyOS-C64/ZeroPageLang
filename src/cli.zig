const std = @import("std");
const diag = @import("diag.zig");
const source = @import("source.zig");
const tooling = @import("tooling.zig");
const prg = @import("prg.zig");
const tass64 = @import("codegen/tass64.zig");
const vice_plan = @import("vice/plan.zig");
const parser = @import("parser.zig");
const ast = @import("ast.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    if (args.len <= 1 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        try printHelp(stdout);
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "asm")) {
        try commandAsm(allocator, args[2..], stdout, stderr);
    } else if (std.mem.eql(u8, command, "compile")) {
        try commandCompile(allocator, io, env_map, args[2..], stdout, stderr);
    } else if (std.mem.eql(u8, command, "test")) {
        try stdout.print("zp64c test is not implemented; use `zig build test` or `zig build emu-test`.\n", .{});
    } else if (std.mem.eql(u8, command, "run-vice")) {
        try commandRunVicePlan(allocator, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "size")) {
        try stdout.print("zp64c size is not implemented; use `zig build size-report`.\n", .{});
    } else if (std.mem.eql(u8, command, "explain")) {
        try commandExplain(args[2..], stdout);
    } else if (std.mem.eql(u8, command, "tools")) {
        try commandTools(allocator, io, env_map, stdout);
    } else {
        try stderr.print("unknown command: {s}\n\n", .{command});
        try printHelp(stderr);
        return error.UnknownCommand;
    }
}

fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\zp64c - ZeroPage microcompiler
        \\
        \\Usage:
        \\  zp64c compile input.zp64 -o out.prg
        \\  zp64c asm input.zp64 -o out.asm
        \\  zp64c run-vice input.prg -o plan.vice.yaml
        \\  zp64c explain feature-name
        \\  zp64c tools
        \\
        \\Environment:
        \\  ZEROPAGE_ZIG=/path/to/zig
        \\  ZEROPAGE_64TASS=/path/to/64tass
        \\  ZEROPAGE_VICE_X64SC=/path/to/x64sc
        \\
    );
}

fn commandAsm(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const parsed = try parseInputOutput(args, "build/out.asm");
    const src = try source.load(allocator, parsed.input);
    defer src.deinit(allocator);
    var dependency_sidecars = try loadDependencySidecarsFromArgs(allocator, args);
    defer dependency_sidecars.deinit(allocator);

    const asm_text = try lowerSourceToAsmWithOptions(allocator, src.path, src.bytes, stderr, .{ .dependency_modules = dependency_sidecars.modules });
    defer allocator.free(asm_text);
    try writeFile(parsed.output, asm_text);
    try stdout.print("wrote {s}\n", .{parsed.output});
}

const LoadedProgram = struct {
    allocator: std.mem.Allocator,
    loaded_imports: std.ArrayList(source.SourceFile),
    parsed_sources: std.ArrayList(parser.ParseResult),
    program: ast.Program,

    fn deinit(self: *LoadedProgram) void {
        self.program.deinit(self.allocator);
        for (self.parsed_sources.items) |parsed| parsed.deinit(self.allocator);
        self.parsed_sources.deinit(self.allocator);
        for (self.loaded_imports.items) |src| src.deinit(self.allocator);
        self.loaded_imports.deinit(self.allocator);
    }
};

fn lowerSourceToAsm(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, stderr: anytype) ![]u8 {
    return lowerSourceToAsmWithOptions(allocator, path, bytes, stderr, .{});
}

fn lowerSourceToAsmWithOptions(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, stderr: anytype, options: tass64.EmitOptions) ![]u8 {
    var loaded = try loadProgram(allocator, path, bytes, stderr);
    defer loaded.deinit();

    try validateProgramMetadata(allocator, loaded.program, path, stderr);
    return tass64.emitProgramWithOptions(allocator, loaded.program, options) catch |err| {
        try renderLowerError(path, err, stderr);
        return err;
    };
}

fn loadProgram(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, stderr: anytype) !LoadedProgram {
    var loaded_imports: std.ArrayList(source.SourceFile) = .empty;
    errdefer {
        for (loaded_imports.items) |src| src.deinit(allocator);
        loaded_imports.deinit(allocator);
    }
    var parsed_sources: std.ArrayList(parser.ParseResult) = .empty;
    errdefer {
        for (parsed_sources.items) |parsed| parsed.deinit(allocator);
        parsed_sources.deinit(allocator);
    }

    const imports = try collectLocalImports(allocator, path, bytes);
    defer {
        for (imports) |item| allocator.free(item.path);
        allocator.free(imports);
    }

    var functions: std.ArrayList(ast.Function) = .empty;
    var module_bindings: std.ArrayList(ast.ModuleBinding) = .empty;
    var string_constants: std.ArrayList(ast.StringConstant) = .empty;
    var array_constants: std.ArrayList(ast.ArrayConstant) = .empty;
    var type_decls: std.ArrayList(ast.TypeDecl) = .empty;
    errdefer {
        for (module_bindings.items) |binding| binding.deinit(allocator);
        module_bindings.deinit(allocator);
        for (string_constants.items) |constant| constant.deinit(allocator);
        string_constants.deinit(allocator);
        for (array_constants.items) |constant| constant.deinit(allocator);
        array_constants.deinit(allocator);
        for (type_decls.items) |decl| decl.deinit(allocator);
        type_decls.deinit(allocator);
        for (functions.items) |function| function.deinit(allocator);
        functions.deinit(allocator);
    }

    for (imports) |item| {
        const imported = try source.load(allocator, item.path);
        loaded_imports.append(allocator, imported) catch |err| {
            imported.deinit(allocator);
            return err;
        };
        const parsed_import = parser.parseSourceWithPrefix(allocator, imported.bytes, item.alias) catch |err| {
            try renderParseError(imported.path, err, stderr);
            return err;
        };
        parsed_sources.append(allocator, parsed_import) catch |err| {
            parsed_import.deinit(allocator);
            return err;
        };
        const imported_source = &parsed_sources.items[parsed_sources.items.len - 1];
        try moveTypeDecls(allocator, &type_decls, imported_source);
        try moveStringConstants(allocator, &string_constants, imported_source);
        try moveArrayConstants(allocator, &array_constants, imported_source);
        try moveFunctions(allocator, &functions, imported_source);
    }

    const parsed_main = parser.parseSource(allocator, bytes) catch |err| {
        try renderParseError(path, err, stderr);
        return err;
    };
    parsed_sources.append(allocator, parsed_main) catch |err| {
        parsed_main.deinit(allocator);
        return err;
    };
    // The list owns this source while declarations are transferred below.
    const main_source = &parsed_sources.items[parsed_sources.items.len - 1];
    try moveTypeDecls(allocator, &type_decls, main_source);
    try moveStringConstants(allocator, &string_constants, main_source);
    try moveArrayConstants(allocator, &array_constants, main_source);
    try moveFunctions(allocator, &functions, main_source);

    const main_policies = main_source.program.zeropage_options.abi.functions;
    var policy_count = main_policies.len;
    for (parsed_sources.items[0 .. parsed_sources.items.len - 1]) |imported| {
        policy_count += imported.program.zeropage_options.abi.functions.len;
    }
    if (policy_count != main_policies.len) {
        const policies = try allocator.alloc(ast.FunctionFramePolicy, policy_count);
        @memcpy(policies[0..main_policies.len], main_policies);
        var offset = main_policies.len;
        for (parsed_sources.items[0 .. parsed_sources.items.len - 1]) |imported| {
            const imported_policies = imported.program.zeropage_options.abi.functions;
            @memcpy(policies[offset..][0..imported_policies.len], imported_policies);
            offset += imported_policies.len;
        }
        main_source.program.zeropage_options.abi.functions = policies;
        if (main_policies.len != 0) allocator.free(main_policies);
    }

    module_bindings = .fromOwnedSlice(main_source.program.module_bindings);
    main_source.program.module_bindings = &.{};
    const zeropage_options = main_source.program.zeropage_options;
    main_source.program.zeropage_options = .{};
    errdefer zeropage_options.deinit(allocator);
    const zeropage_module = main_source.program.zeropage_module;
    main_source.program.zeropage_module = null;
    errdefer if (zeropage_module) |module| module.deinit(allocator);

    // Keep error cleanup for each slice as it leaves its list.
    const owned_bindings = try module_bindings.toOwnedSlice(allocator);
    errdefer {
        for (owned_bindings) |binding| binding.deinit(allocator);
        allocator.free(owned_bindings);
    }
    const owned_types = try type_decls.toOwnedSlice(allocator);
    errdefer {
        for (owned_types) |decl| decl.deinit(allocator);
        allocator.free(owned_types);
    }
    const owned_strings = try string_constants.toOwnedSlice(allocator);
    errdefer {
        for (owned_strings) |constant| constant.deinit(allocator);
        allocator.free(owned_strings);
    }
    const owned_arrays = try array_constants.toOwnedSlice(allocator);
    errdefer {
        for (owned_arrays) |constant| constant.deinit(allocator);
        allocator.free(owned_arrays);
    }

    const program = ast.Program{
        .zeropage_options = zeropage_options,
        .zeropage_module = zeropage_module,
        .module_bindings = owned_bindings,
        .type_decls = owned_types,
        .string_constants = owned_strings,
        .array_constants = owned_arrays,
        .functions = try functions.toOwnedSlice(allocator),
    };

    return .{
        .allocator = allocator,
        .loaded_imports = loaded_imports,
        .parsed_sources = parsed_sources,
        .program = program,
    };
}

fn validateProgramMetadata(allocator: std.mem.Allocator, program: ast.Program, path: []const u8, stderr: anytype) !void {
    validateZeroPageOptions(allocator, program) catch |err| {
        try renderLowerError(path, err, stderr);
        return err;
    };
    validateZeroPageModule(allocator, program) catch |err| {
        try renderLowerError(path, err, stderr);
        return err;
    };
}

fn validateZeroPageOptions(allocator: std.mem.Allocator, program: ast.Program) !void {
    if (!program.zeropage_options.declared and program.zeropage_options.abi.functions.len == 0) return;
    try validateMemoryOptions(program.zeropage_options.memory);
    try validateMemoryPlacements(program);
    try validateImageOptions(program.zeropage_options.image);
    try validateHeapOptions(program);
    try validateReuOptions(program);
    try validateModuleLoaderOptions(program);
    for (program.zeropage_options.abi.functions, 0..) |policy, index| {
        if (program.findFunction(policy.name) == null) return error.UnknownZeroPageOptionsFunction;
        for (program.zeropage_options.abi.functions[0..index]) |previous| {
            if (std.mem.eql(u8, policy.name, previous.name)) return error.DuplicateZeroPageFunctionOption;
        }
    }
    var needs_stack = false;
    for (program.functions) |function| {
        switch (tass64.effectiveFramePolicy(program, function.name)) {
            .static => {},
            .auto => return error.UnsupportedZeroPageStackAbi,
            .stack => needs_stack = true,
        }
    }
    if (!needs_stack) return;
    if (program.zeropage_options.stack == null) return error.MissingZeroPageStackRegion;

    const layouts = try tass64.planStackFrames(allocator, program);
    defer {
        for (layouts) |layout| layout.deinit(allocator);
        if (layouts.len != 0) allocator.free(layouts);
    }
    for (layouts) |layout| {
        if (layout.byte_size > 255) return error.UnsupportedStackFrameTooLarge;
    }
    for (program.functions) |function| {
        if (tass64.effectiveFramePolicy(program, function.name) == .stack) {
            if (function.exported and !std.mem.eql(u8, function.name, "main")) return error.UnsupportedStackFrameBridge;
            try validateLeafStackFunction(program, function);
        } else {
            try validateStaticToStackBridgeCalls(program, function);
        }
    }
}

fn validateMemoryPlacements(program: ast.Program) !void {
    var last_direct_addr: u32 = 0;
    for (program.zeropage_options.memory.placements, 0..) |placement, placement_index| {
        if (!isValidModuleId(placement.name)) return error.InvalidZeroPageMemoryPlacement;
        const region = program.findMemoryRegion(placement.region_name) orelse return error.UnknownZeroPageMemoryRegion;
        if (region.space != .c64) return error.InvalidZeroPageMemoryPlacement;
        for (program.zeropage_options.memory.placements[0..placement_index]) |previous| {
            if (std.mem.eql(u8, previous.region_name, placement.region_name)) return error.InvalidZeroPageMemoryPlacement;
        }
        if (placement.load == .direct) {
            if (region.addr < last_direct_addr) return error.InvalidZeroPageMemoryPlacement;
            last_direct_addr = region.addr;
        }
        for (placement.functions) |name| {
            if (std.mem.eql(u8, name, "main")) return error.InvalidZeroPageMemoryPlacement;
            const function = program.findFunction(name) orelse return error.UnknownZeroPageMemoryPlacementDeclaration;
            if (tass64.effectiveFramePolicy(program, function.name) != .static) return error.InvalidZeroPageMemoryPlacement;
            if (region.bank != .visible) {
                for (function.params) |param| if (!isModuleExportType(program, param.ty)) return error.InvalidZeroPageMemoryPlacement;
                if (!isModuleExportType(program, function.return_type)) return error.InvalidZeroPageMemoryPlacement;
            }
            if (program.zeropage_module) |module| {
                for (module.exports) |export_decl| {
                    if (std.mem.eql(u8, export_decl.function_name, name)) return error.InvalidZeroPageMemoryPlacement;
                }
            }
            for (program.zeropage_options.memory.placements[0..placement_index]) |previous| {
                for (previous.functions) |previous_name| {
                    if (std.mem.eql(u8, previous_name, name)) return error.InvalidZeroPageMemoryPlacement;
                }
            }
        }
        for (placement.constants) |name| {
            if (program.findString(name) == null and program.findArray(name) == null) return error.UnknownZeroPageMemoryPlacementDeclaration;
            for (program.zeropage_options.memory.placements[0..placement_index]) |previous| {
                for (previous.constants) |previous_name| {
                    if (std.mem.eql(u8, previous_name, name)) return error.InvalidZeroPageMemoryPlacement;
                }
            }
        }
        try validatePlacementRegionConflicts(program, region);
    }
}

fn validatePlacementRegionConflicts(program: ast.Program, region: ast.MemoryRegion) !void {
    const region_end = @as(u32, region.addr) + region.size;
    if (program.zeropage_options.stack) |stack| {
        const stack_end = @as(u32, stack.base) + stack.size;
        if (rangesOverlap(@intCast(region.addr), region_end, stack.base, stack_end)) return error.InvalidZeroPageMemoryPlacement;
    }
    for (program.zeropage_options.heaps) |heap| {
        const heap_end = @as(u32, heap.addr) + heap.size;
        if (rangesOverlap(@intCast(region.addr), region_end, heap.addr, heap_end)) return error.InvalidZeroPageMemoryPlacement;
    }
    if (program.zeropage_options.modules) |modules| {
        const main_end = @as(u32, modules.load_window.addr) + modules.load_window.size;
        if (rangesOverlap(@intCast(region.addr), region_end, modules.load_window.addr, main_end)) return error.InvalidZeroPageMemoryPlacement;
        for (modules.extra_load_windows) |entry| {
            const end = @as(u32, entry.window.addr) + entry.window.size;
            if (rangesOverlap(@intCast(region.addr), region_end, entry.window.addr, end)) return error.InvalidZeroPageMemoryPlacement;
        }
        if (modules.disk_staging) |staging| {
            const end = @as(u32, staging.addr) + staging.size;
            if (rangesOverlap(@intCast(region.addr), region_end, staging.addr, end)) return error.InvalidZeroPageMemoryPlacement;
        }
    }
}

fn validateMemoryOptions(memory: ast.MemoryOptions) !void {
    for (memory.regions, 0..) |region, index| {
        if (!isValidModuleId(region.name) or region.size == 0) return error.InvalidZeroPageMemoryRegion;
        const end = @as(u64, region.addr) + @as(u64, region.size);
        switch (region.space) {
            .c64 => {
                if (end > 0x10000) return error.InvalidZeroPageMemoryRegion;
                if (region.addr < 0x0800) return error.InvalidZeroPageMemoryRegion;
                if (@as(u64, region.addr) < 0xe000 and end > 0xd000) return error.InvalidZeroPageMemoryRegion;
                switch (region.bank) {
                    .visible => {
                        if (@as(u64, region.addr) < 0xc000 and end > 0xa000) return error.InvalidZeroPageMemoryRegion;
                        if (end > 0xe000) return error.InvalidZeroPageMemoryRegion;
                    },
                    .ram_under_basic => if (region.addr < 0xa000 or end > 0xc000) return error.InvalidZeroPageMemoryRegion,
                    .ram_under_kernal => if (region.addr < 0xe000 or end > 0x10000) return error.InvalidZeroPageMemoryRegion,
                }
            },
            .reu => {
                if (region.bank != .visible or end > 0x0100_0000) return error.InvalidZeroPageMemoryRegion;
            },
        }
        for (memory.regions[index + 1 ..]) |other| {
            if (region.space != other.space) continue;
            const other_end = @as(u64, other.addr) + @as(u64, other.size);
            if (@as(u64, region.addr) < other_end and @as(u64, other.addr) < end) return error.InvalidZeroPageMemoryRegion;
        }
    }
}

fn validateImageOptions(image: ast.ImageOptions) !void {
    if (image.address_limit == 0 or image.address_limit > 0x10000) return error.InvalidZeroPageImage;
    if (@as(u32, image.load_addr) >= image.address_limit) return error.InvalidZeroPageImage;
    if (@as(u32, image.entry_addr) >= image.address_limit) return error.InvalidZeroPageImage;
    if (image.entry_addr < image.load_addr) return error.InvalidZeroPageImage;
    if (image.basic_stub) {
        if (image.load_addr != 0x0801) return error.InvalidZeroPageImage;
        const stub_end = @as(u32, image.load_addr) + 8 + decimalDigits(image.entry_addr);
        if (@as(u32, image.entry_addr) < stub_end) return error.InvalidZeroPageImage;
    }
}

fn decimalDigits(value: u16) u32 {
    if (value < 10) return 1;
    if (value < 100) return 2;
    if (value < 1000) return 3;
    if (value < 10000) return 4;
    return 5;
}

fn validateZeroPageModule(allocator: std.mem.Allocator, program: ast.Program) !void {
    const module = program.zeropage_module orelse return;
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();
    for (module.deps) |dep| {
        if (!isValidModuleId(dep)) return error.InvalidZeroPageModuleId;
    }
    if (program.zeropage_options.modules) |modules| {
        if (modules.dependency_graph) |graph| try validateZeroPageModuleDependencyGraph(module, graph);
        if (modules.registry) |registry| try validateZeroPageModuleRegistry(module, registry, modules.dependency_graph);
    }
    for (module.exports) |export_decl| {
        if (!isValidModuleId(export_decl.name)) return error.InvalidZeroPageModuleId;
        const function = program.findFunction(export_decl.function_name) orelse return error.UnknownZeroPageModuleExport;
        if (tass64.effectiveFramePolicy(program, function.name) != .stack) return error.UnsupportedZeroPageModuleExport;
        for (function.params) |param| {
            if (!isModuleExportType(program, param.ty)) return error.UnsupportedZeroPageModuleExport;
        }
        if (!isModuleExportType(program, function.return_type)) return error.UnsupportedZeroPageModuleExport;
        if (program.zeropage_options.modules) |modules| {
            if (modules.load_window.bank == .ram_under_kernal) {
                var kernal_visited = std.StringHashMap(void).init(allocator);
                defer kernal_visited.deinit();
                if (try moduleFunctionRequiresKernalRom(program, function, &kernal_visited)) return error.UnsafeKernalBankModuleExport;
            }
        }
        try validateZeroPageModuleReachableFunction(program, function, &visited);
    }
}

fn validateZeroPageModuleRegistry(module: ast.ZeroPageModule, registry: ast.ModuleRegistryOptions, graph: ?ast.ModuleDependencyGraphOptions) !void {
    const required: usize = 1 + moduleGraphNodeCount(module, graph);
    if (registry.capacity < required) return error.InvalidZeroPageModuleRegistry;
    for (module.deps) |dep| {
        if (std.mem.eql(u8, dep, module.id)) return error.InvalidZeroPageModuleRegistry;
    }
}

fn validateZeroPageModuleDependencyGraph(module: ast.ZeroPageModule, graph: ast.ModuleDependencyGraphOptions) !void {
    for (module.deps) |dep| {
        if (std.mem.eql(u8, dep, module.id)) return error.InvalidZeroPageModuleRegistry;
        _ = findModuleGraphNode(graph, dep) orelse return error.InvalidZeroPageModuleRegistry;
    }
    for (graph.nodes, 0..) |node, index| {
        if (!isValidModuleId(node.id)) return error.InvalidZeroPageModuleRegistry;
        if (std.mem.eql(u8, node.id, module.id)) return error.InvalidZeroPageModuleRegistry;
        for (graph.nodes[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, node.id)) return error.InvalidZeroPageModuleRegistry;
        }
        for (node.deps) |dep| {
            if (!isValidModuleId(dep)) return error.InvalidZeroPageModuleRegistry;
            if (std.mem.eql(u8, dep, node.id)) return error.InvalidZeroPageModuleRegistry;
            _ = findModuleGraphNode(graph, dep) orelse return error.InvalidZeroPageModuleRegistry;
        }
    }
    const states = try std.heap.page_allocator.alloc(u8, graph.nodes.len);
    defer std.heap.page_allocator.free(states);
    @memset(states, 0);
    for (graph.nodes, 0..) |_, index| try validateModuleGraphAcyclic(graph, index, states);
}

fn validateModuleGraphAcyclic(graph: ast.ModuleDependencyGraphOptions, index: usize, states: []u8) !void {
    if (states[index] == 1) return error.InvalidZeroPageModuleRegistry;
    if (states[index] == 2) return;
    states[index] = 1;
    for (graph.nodes[index].deps) |dep| {
        const dep_index = findModuleGraphNodeIndex(graph, dep) orelse return error.InvalidZeroPageModuleRegistry;
        try validateModuleGraphAcyclic(graph, dep_index, states);
    }
    states[index] = 2;
}

fn validateZeroPageModuleReachableFunction(program: ast.Program, function: ast.Function, visited: *std.StringHashMap(void)) anyerror!void {
    if (visited.contains(function.name)) return;
    try visited.put(function.name, {});
    if (tass64.effectiveFramePolicy(program, function.name) != .stack) return error.UnsupportedZeroPageModuleExport;
    for (function.params) |param| {
        if (!isModuleExportType(program, param.ty)) return error.UnsupportedZeroPageModuleExport;
    }
    if (!isModuleExportType(program, function.return_type)) return error.UnsupportedZeroPageModuleExport;
    for (function.body) |stmt| try validateZeroPageModuleStmt(program, stmt, visited);
}

fn validateZeroPageModuleStmt(program: ast.Program, stmt: ast.Stmt, visited: *std.StringHashMap(void)) anyerror!void {
    switch (stmt) {
        .var_decl => |decl| try validateZeroPageModuleExpr(program, decl.init, visited),
        .assign => |assign| try validateZeroPageModuleExpr(program, assign.value, visited),
        inline .add_assign, .sub_assign, .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => |assign| try validateZeroPageModuleExpr(program, assign.value, visited),
        .deref_assign => |assign| {
            try validateZeroPageModuleExpr(program, assign.target, visited);
            try validateZeroPageModuleExpr(program, assign.value, visited);
        },
        .array_assign, .array_add_assign, .array_sub_assign, .array_mul_assign, .array_bit_and_assign, .array_bit_or_assign, .array_bit_xor_assign, .array_shl_assign, .array_shr_assign => |assign| {
            try validateZeroPageModuleExpr(program, assign.index, visited);
            try validateZeroPageModuleExpr(program, assign.value, visited);
        },
        .array_field_assign => |assign| {
            try validateZeroPageModuleExpr(program, assign.index, visited);
            try validateZeroPageModuleExpr(program, assign.value, visited);
        },
        .while_stmt => |while_stmt| {
            try validateZeroPageModuleExpr(program, while_stmt.condition, visited);
            for (while_stmt.body) |child| try validateZeroPageModuleStmt(program, child, visited);
        },
        .for_stmt => |for_stmt| for (for_stmt.body) |child| try validateZeroPageModuleStmt(program, child, visited),
        .switch_stmt => |switch_stmt| {
            try validateZeroPageModuleExpr(program, switch_stmt.operand, visited);
            for (switch_stmt.prongs) |prong| for (prong.body) |child| try validateZeroPageModuleStmt(program, child, visited);
        },
        .if_stmt => |if_stmt| {
            try validateZeroPageModuleExpr(program, if_stmt.condition, visited);
            for (if_stmt.then_body) |child| try validateZeroPageModuleStmt(program, child, visited);
            for (if_stmt.else_body) |child| try validateZeroPageModuleStmt(program, child, visited);
        },
        .call => |call| try validateZeroPageModuleCall(program, call, visited),
        .discard, .return_expr => |expr| try validateZeroPageModuleExpr(program, expr, visited),
        .break_expr => |break_expr| try validateZeroPageModuleExpr(program, break_expr.value, visited),
        .builtin => |builtin| try validateZeroPageModuleBuiltin(program, builtin, visited),
        .break_stmt, .continue_stmt => {},
        .inline_asm, .test6502, .reu, .reu_heap_reset, .heap_reset, .heap_free, .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph, .field_assign, .string_var, .string_assign, .struct_var => return error.UnsupportedZeroPageModuleExport,
    }
}

fn validateZeroPageModuleBuiltin(program: ast.Program, builtin: ast.BuiltinCall, visited: *std.StringHashMap(void)) anyerror!void {
    switch (builtin) {
        .console_clear, .console_puts => {},
        .console_print => |print| {
            for (print.args) |arg| switch (arg) {
                .string => {},
                .value => |expr| try validateZeroPageModuleExpr(program, expr, visited),
            };
        },
        else => return error.UnsupportedZeroPageModuleExport,
    }
}

fn validateZeroPageModuleExpr(program: ast.Program, expr: ast.Expr, visited: *std.StringHashMap(void)) anyerror!void {
    switch (expr) {
        .value, .size_of, .align_of, .offset_of => {},
        .address_of => |address| try validateZeroPageModuleAddressOf(program, address),
        inline .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| {
            try validateZeroPageModuleExpr(program, binary.lhs.*, visited);
            try validateZeroPageModuleExpr(program, binary.rhs.*, visited);
        },
        .bit_not, .not, .deref, .ptr_from_int, .int_from_ptr => |child| try validateZeroPageModuleExpr(program, child.*, visited),
        .as_cast => |as_cast| try validateZeroPageModuleExpr(program, as_cast.expr.*, visited),
        .if_expr => |if_expr| {
            try validateZeroPageModuleExpr(program, if_expr.condition.*, visited);
            try validateZeroPageModuleExpr(program, if_expr.then_expr.*, visited);
            try validateZeroPageModuleExpr(program, if_expr.else_expr.*, visited);
        },
        .switch_expr => |switch_expr| {
            try validateZeroPageModuleExpr(program, switch_expr.operand.*, visited);
            for (switch_expr.prongs) |prong| try validateZeroPageModuleExpr(program, prong.value, visited);
        },
        .block_expr => |block_expr| for (block_expr.body) |stmt| try validateZeroPageModuleStmt(program, stmt, visited),
        .call => |call| try validateZeroPageModuleCall(program, call, visited),
        .array_literal, .array_index, .array_field_index, .struct_literal, .c64_read_petscii, .c64_wait_petscii, .reu_present, .reu_compare, .reu_heap_alloc, .reu_view, .far_view_materialize, .far_view_materialize_range, .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded, .module_call, .heap_alloc => return error.UnsupportedZeroPageModuleExport,
    }
}

fn validateZeroPageModuleAddressOf(program: ast.Program, address: ast.AddressOf) !void {
    const literal_index = address.index orelse return error.UnsupportedZeroPageModuleRelocation;
    const constant = program.findArray(address.name) orelse return error.UnsupportedZeroPageModuleRelocation;
    if (literal_index >= constant.ty.len) return error.UnsupportedArrayIndex;
    switch (constant.ty.elem) {
        .scalar => {},
        .custom => |name| if (program.findEnum(name) == null) return error.UnsupportedZeroPageModuleRelocation,
    }
}

fn validateZeroPageModuleCall(program: ast.Program, call: ast.CallExpr, visited: *std.StringHashMap(void)) anyerror!void {
    const target = findFunctionForCall(program, call.target) orelse return error.UnsupportedZeroPageModuleExport;
    if (target.params.len != call.args.len) return error.ArgumentCountMismatch;
    for (call.args) |arg| {
        if (tass64.exprContainsCall(arg)) return error.UnsupportedStackFrameBridgeArgument;
        try validateZeroPageModuleExpr(program, arg, visited);
    }
    try validateZeroPageModuleReachableFunction(program, target, visited);
}

fn moduleFunctionRequiresKernalRom(program: ast.Program, function: ast.Function, visited: *std.StringHashMap(void)) anyerror!bool {
    if (visited.contains(function.name)) return false;
    try visited.put(function.name, {});
    for (function.body) |stmt| {
        if (try moduleStmtRequiresKernalRom(program, stmt, visited)) return true;
    }
    return false;
}

fn moduleStmtRequiresKernalRom(program: ast.Program, stmt: ast.Stmt, visited: *std.StringHashMap(void)) anyerror!bool {
    return switch (stmt) {
        .builtin => |builtin| try moduleBuiltinRequiresKernalRom(program, builtin, visited),
        .var_decl => |decl| try moduleExprRequiresKernalRom(program, decl.init, visited),
        .assign => |assign| try moduleExprRequiresKernalRom(program, assign.value, visited),
        inline .add_assign, .sub_assign, .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => |assign| try moduleExprRequiresKernalRom(program, assign.value, visited),
        .deref_assign => |assign| (try moduleExprRequiresKernalRom(program, assign.target, visited)) or (try moduleExprRequiresKernalRom(program, assign.value, visited)),
        .array_assign, .array_add_assign, .array_sub_assign, .array_mul_assign, .array_bit_and_assign, .array_bit_or_assign, .array_bit_xor_assign, .array_shl_assign, .array_shr_assign => |assign| (try moduleExprRequiresKernalRom(program, assign.index, visited)) or (try moduleExprRequiresKernalRom(program, assign.value, visited)),
        .array_field_assign => |assign| (try moduleExprRequiresKernalRom(program, assign.index, visited)) or (try moduleExprRequiresKernalRom(program, assign.value, visited)),
        .while_stmt => |while_stmt| (try moduleExprRequiresKernalRom(program, while_stmt.condition, visited)) or blk: {
            for (while_stmt.body) |child| if (try moduleStmtRequiresKernalRom(program, child, visited)) break :blk true;
            break :blk false;
        },
        .for_stmt => |for_stmt| blk: {
            for (for_stmt.body) |child| if (try moduleStmtRequiresKernalRom(program, child, visited)) break :blk true;
            break :blk false;
        },
        .switch_stmt => |switch_stmt| blk: {
            if (try moduleExprRequiresKernalRom(program, switch_stmt.operand, visited)) break :blk true;
            for (switch_stmt.prongs) |prong| for (prong.body) |child| if (try moduleStmtRequiresKernalRom(program, child, visited)) break :blk true;
            break :blk false;
        },
        .if_stmt => |if_stmt| blk: {
            if (try moduleExprRequiresKernalRom(program, if_stmt.condition, visited)) break :blk true;
            for (if_stmt.then_body) |child| if (try moduleStmtRequiresKernalRom(program, child, visited)) break :blk true;
            for (if_stmt.else_body) |child| if (try moduleStmtRequiresKernalRom(program, child, visited)) break :blk true;
            break :blk false;
        },
        .call => |call| try moduleCallRequiresKernalRom(program, call, visited),
        .discard, .return_expr => |expr| try moduleExprRequiresKernalRom(program, expr, visited),
        .break_expr => |break_expr| try moduleExprRequiresKernalRom(program, break_expr.value, visited),
        .field_assign => |field| try moduleExprRequiresKernalRom(program, field.value, visited),
        .heap_free => |free| try moduleExprRequiresKernalRom(program, free.ptr.*, visited),
        .struct_var => |struct_var| blk: {
            for (struct_var.fields) |field| if (try moduleExprRequiresKernalRom(program, field.value, visited)) break :blk true;
            break :blk false;
        },
        .inline_asm => true,
        .test6502, .reu, .reu_heap_reset, .heap_reset, .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph, .string_var, .string_assign, .break_stmt, .continue_stmt => false,
    };
}

fn moduleExprRequiresKernalRom(program: ast.Program, expr: ast.Expr, visited: *std.StringHashMap(void)) anyerror!bool {
    return switch (expr) {
        .c64_read_petscii, .c64_wait_petscii, .module_disk_load => true,
        inline .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| (try moduleExprRequiresKernalRom(program, binary.lhs.*, visited)) or (try moduleExprRequiresKernalRom(program, binary.rhs.*, visited)),
        .bit_not, .not, .deref, .ptr_from_int, .int_from_ptr => |child| try moduleExprRequiresKernalRom(program, child.*, visited),
        .as_cast => |as_cast| try moduleExprRequiresKernalRom(program, as_cast.expr.*, visited),
        .if_expr => |if_expr| (try moduleExprRequiresKernalRom(program, if_expr.condition.*, visited)) or (try moduleExprRequiresKernalRom(program, if_expr.then_expr.*, visited)) or (try moduleExprRequiresKernalRom(program, if_expr.else_expr.*, visited)),
        .switch_expr => |switch_expr| blk: {
            if (try moduleExprRequiresKernalRom(program, switch_expr.operand.*, visited)) break :blk true;
            for (switch_expr.prongs) |prong| if (try moduleExprRequiresKernalRom(program, prong.value, visited)) break :blk true;
            break :blk false;
        },
        .block_expr => |block_expr| blk: {
            for (block_expr.body) |stmt| if (try moduleStmtRequiresKernalRom(program, stmt, visited)) break :blk true;
            break :blk false;
        },
        .call => |call| try moduleCallRequiresKernalRom(program, call, visited),
        .array_literal => |literal| blk: {
            for (literal.values) |value| if (try moduleExprRequiresKernalRom(program, value, visited)) break :blk true;
            break :blk false;
        },
        .struct_literal => |literal| blk: {
            for (literal.fields) |field| if (try moduleExprRequiresKernalRom(program, field.value, visited)) break :blk true;
            break :blk false;
        },
        .array_index => |index| try moduleExprRequiresKernalRom(program, index.index.*, visited),
        .array_field_index => |index| try moduleExprRequiresKernalRom(program, index.index.*, visited),
        .reu_compare => |transfer| (try moduleExprRequiresKernalRom(program, transfer.c64_addr.*, visited)) or (try moduleExprRequiresKernalRom(program, transfer.len.*, visited)),
        .reu_heap_alloc => |alloc| try moduleExprRequiresKernalRom(program, alloc.len.*, visited),
        .reu_view => |view| try moduleExprRequiresKernalRom(program, view.far.*, visited),
        .far_view_materialize_range => |range| try moduleExprRequiresKernalRom(program, range.start.*, visited),
        .module_call => |call| blk: {
            for (call.args) |arg| if (try moduleExprRequiresKernalRom(program, arg, visited)) break :blk true;
            break :blk false;
        },
        .heap_alloc => |alloc| try moduleExprRequiresKernalRom(program, alloc.len.*, visited),
        else => false,
    };
}

fn moduleCallRequiresKernalRom(program: ast.Program, call: ast.CallExpr, visited: *std.StringHashMap(void)) anyerror!bool {
    if (findFunctionForCall(program, call.target)) |target| {
        if (try moduleFunctionRequiresKernalRom(program, target, visited)) return true;
    }
    for (call.args) |arg| if (try moduleExprRequiresKernalRom(program, arg, visited)) return true;
    return false;
}

fn moduleBuiltinRequiresKernalRom(program: ast.Program, builtin: ast.BuiltinCall, visited: *std.StringHashMap(void)) anyerror!bool {
    return switch (builtin) {
        .console_print => |print| blk: {
            for (print.args) |arg| switch (arg) {
                .string => {},
                .value => |expr| if (try moduleExprRequiresKernalRom(program, expr, visited)) break :blk true,
            };
            break :blk false;
        },
        .kernal_puts, .kernal_set_name => true,
        .console_clear, .console_puts => false,
        .screen_clear, .puts_at, .put_at, .hex_at, .hex16_at, .string_append, .string_clear, .sleep_ticks, .sleep_frames => false,
    };
}

fn isModuleExportType(program: ast.Program, ty: ast.Type) bool {
    return switch (ty) {
        .void, .bool, .u8, .i8, .u16, .i16, .usize, .pointer => true,
        .custom => |name| program.findEnum(name) != null,
        .far_bytes, .far_view, .near_view, .array, .optional => false,
    };
}

fn isValidModuleId(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text[0] < 'a' or text[0] > 'z') return false;
    for (text[1..]) |ch| {
        if (ch >= 'a' and ch <= 'z') continue;
        if (ch >= '0' and ch <= '9') continue;
        if (ch == '_' or ch == '-') continue;
        return false;
    }
    return true;
}

fn validateHeapOptions(program: ast.Program) !void {
    const heaps = program.zeropage_options.heaps;
    for (heaps, 0..) |heap, index| {
        try validateHeapRegion(heap.addr, heap.size);
        try validateHeapBlock(heap);
        const heap_end = @as(u32, heap.addr) + @as(u32, heap.size);
        if (program.zeropage_options.stack) |stack| {
            const stack_end = @as(u32, stack.base) + @as(u32, stack.size);
            if (rangesOverlap(heap.addr, heap_end, stack.base, stack_end)) return error.InvalidZeroPageHeapRegion;
        }
        for (heaps[index + 1 ..]) |other| {
            const other_end = @as(u32, other.addr) + @as(u32, other.size);
            if (rangesOverlap(heap.addr, heap_end, other.addr, other_end)) return error.InvalidZeroPageHeapRegion;
        }
    }
}

fn validateHeapBlock(heap: ast.HeapOptions) !void {
    switch (heap.kind) {
        .arena => if (heap.block != null) return error.InvalidZeroPageHeapBlock,
        .fixed => {
            const block = heap.block orelse return error.InvalidZeroPageHeapBlock;
            if (block < 2) return error.InvalidZeroPageHeapBlock;
            if (block > heap.size) return error.InvalidZeroPageHeapBlock;
            if (@mod(heap.size, block) != 0) return error.InvalidZeroPageHeapBlock;
        },
    }
}

fn validateHeapRegion(addr: u16, size: u16) !void {
    if (size == 0) return error.InvalidZeroPageHeapRegion;
    const end = @as(u32, addr) + @as(u32, size);
    if (end > 0xffff) return error.InvalidZeroPageHeapRegion;
    if (rangesOverlap(addr, end, 0x0000, 0x0800)) return error.InvalidZeroPageHeapRegion;
    if (rangesOverlap(addr, end, 0xd000, 0xe000)) return error.InvalidZeroPageHeapRegion;
}

fn rangesOverlap(a_start: u16, a_end: u32, b_start: u16, b_end: u32) bool {
    return @as(u32, a_start) < b_end and @as(u32, b_start) < a_end;
}

fn validateReuOptions(program: ast.Program) !void {
    const heaps = program.zeropage_options.reu.heaps;
    for (heaps, 0..) |heap, index| {
        try validateReuHeapRegion(heap.addr, heap.size);
        if (heap.kind != .arena) return error.UnsupportedZeroPageOptions;
        const heap_end = @as(u64, heap.addr) + @as(u64, heap.size);
        for (heaps[index + 1 ..]) |other| {
            const other_end = @as(u64, other.addr) + @as(u64, other.size);
            if (rangesOverlap64(heap.addr, heap_end, other.addr, other_end)) return error.InvalidZeroPageReuHeapRegion;
        }
    }
}

fn validateReuHeapRegion(addr: u32, size: u32) !void {
    if (size == 0) return error.InvalidZeroPageReuHeapRegion;
    if (addr > 0x00ff_ffff) return error.InvalidZeroPageReuHeapRegion;
    const end = @as(u64, addr) + @as(u64, size);
    if (end > 0x0100_0000) return error.InvalidZeroPageReuHeapRegion;
}

fn rangesOverlap64(a_start: u32, a_end: u64, b_start: u32, b_end: u64) bool {
    return @as(u64, a_start) < b_end and @as(u64, b_start) < a_end;
}

fn validateModuleLoaderOptions(program: ast.Program) !void {
    const modules = program.zeropage_options.modules orelse return;
    try validateModuleLoadWindow(program, modules.load_window);
    try validateModuleReuCache(program, modules.reu_cache);
    if (modules.disk_staging) |staging| try validateModuleDiskStaging(program, modules.load_window, staging);
    try validateModuleExtraLoadWindows(program, modules);
    try validateModuleWindowAssignments(program, modules);
    if (modules.policy) |policy| try validateModuleLoadPolicy(program, modules, policy);
    if (modules.disk_manifest) |manifest| try validateModuleDiskManifest(program, manifest);
    if (modules.state) |state| try validateModuleState(program, modules, state);
    try validateModuleRegistryRuntimePlan(program, modules);
}

fn validateModuleExtraLoadWindows(program: ast.Program, modules: ast.ModuleLoaderOptions) !void {
    const main_end = @as(u32, modules.load_window.addr) + @as(u32, modules.load_window.size);
    for (modules.extra_load_windows, 0..) |entry, index| {
        if (!isValidModuleId(entry.name)) return error.InvalidZeroPageModuleLoadWindow;
        if (std.mem.eql(u8, entry.name, "main")) return error.InvalidZeroPageModuleLoadWindow;
        try validateModuleLoadWindow(program, entry.window);
        const window_end = @as(u32, entry.window.addr) + @as(u32, entry.window.size);
        switch (entry.window.bank) {
            .visible => {
                if (rangesOverlap(entry.window.addr, window_end, 0xa000, 0xc000)) return error.InvalidZeroPageModuleLoadWindow;
                if (rangesOverlap(entry.window.addr, window_end, 0xe000, 0x10000)) return error.InvalidZeroPageModuleLoadWindow;
            },
            .ram_under_basic => {
                if (entry.window.addr < 0xa000 or window_end > 0xc000) return error.InvalidZeroPageModuleLoadWindow;
            },
            .ram_under_kernal => {
                if (entry.window.addr < 0xe000 or window_end > 0x10000) return error.InvalidZeroPageModuleLoadWindow;
            },
        }
        if (rangesOverlap(entry.window.addr, window_end, modules.load_window.addr, main_end)) return error.InvalidZeroPageModuleLoadWindow;
        if (modules.disk_staging) |staging| {
            const staging_end = @as(u32, staging.addr) + @as(u32, staging.size);
            if (rangesOverlap(entry.window.addr, window_end, staging.addr, staging_end)) return error.InvalidZeroPageModuleLoadWindow;
        }
        for (modules.extra_load_windows[index + 1 ..]) |other| {
            if (std.mem.eql(u8, entry.name, other.name)) return error.InvalidZeroPageModuleLoadWindow;
            const other_end = @as(u32, other.window.addr) + @as(u32, other.window.size);
            if (rangesOverlap(entry.window.addr, window_end, other.window.addr, other_end)) return error.InvalidZeroPageModuleLoadWindow;
        }
    }
}

fn validateModuleWindowAssignments(program: ast.Program, modules: ast.ModuleLoaderOptions) !void {
    const module = program.zeropage_module orelse {
        if (modules.window_assignments.len != 0) return error.UnknownZeroPageModule;
        return;
    };
    for (modules.window_assignments, 0..) |assignment, index| {
        if (!isValidModuleId(assignment.id)) return error.InvalidZeroPageModuleLoadWindow;
        if (std.mem.eql(u8, assignment.id, module.id)) {
            if (!std.mem.eql(u8, assignment.window_name, "main")) return error.InvalidZeroPageModuleLoadWindow;
        } else if (!moduleRowIdExists(module, modules.dependency_graph, assignment.id)) {
            return error.UnknownZeroPageModule;
        }
        if (!moduleWindowNameExists(modules, assignment.window_name)) return error.InvalidZeroPageModuleLoadWindow;
        for (modules.window_assignments[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, assignment.id)) return error.InvalidZeroPageModuleLoadWindow;
        }
    }
}

fn moduleRowIdExists(module: ast.ZeroPageModule, graph: ?ast.ModuleDependencyGraphOptions, id: []const u8) bool {
    if (findModuleDependencyOrdinal(module, id) != null) return true;
    if (graph) |resolved| return findModuleGraphNode(resolved, id) != null;
    return false;
}

fn moduleWindowNameExists(modules: ast.ModuleLoaderOptions, name: []const u8) bool {
    if (std.mem.eql(u8, name, "main")) return true;
    for (modules.extra_load_windows) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

fn validateModuleRegistryRuntimePlan(program: ast.Program, modules: ast.ModuleLoaderOptions) !void {
    const module = program.zeropage_module orelse return;
    const registry = modules.registry orelse return;
    _ = modules.disk_manifest orelse return;
    const required_cache = @as(u64, registry.capacity) * @as(u64, modules.load_window.size);
    if (required_cache > modules.reu_cache.size) return error.InvalidZeroPageModuleRegistry;
    const planned_end = @as(u64, modules.reu_cache.addr) + required_cache;
    if (planned_end > 0x0100_0000) return error.InvalidZeroPageModuleRegistry;
    if (registry.capacity < 1 + moduleGraphNodeCount(module, modules.dependency_graph)) return error.InvalidZeroPageModuleRegistry;
}

fn validateModuleState(program: ast.Program, modules: ast.ModuleLoaderOptions, state: ast.ModuleStateOptions) !void {
    const module = program.zeropage_module orelse return error.InvalidZeroPageModuleState;
    try validateModuleStateRanges(modules.load_window, state.current);
    for (state.deps, 0..) |dep_state, index| {
        if (findModuleDependencyOrdinal(module, dep_state.id) == null) return error.InvalidZeroPageModuleState;
        for (state.deps[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, dep_state.id)) return error.InvalidZeroPageModuleState;
        }
        try validateModuleStateRanges(modules.load_window, dep_state.state);
    }
    if (moduleStateAnyPersistent(state)) {
        const rows = moduleRegistryRows(program, modules);
        const required_slots: u64 = @as(u64, rows) + 1 + @as(u64, module.deps.len);
        const required_cache = required_slots * @as(u64, modules.load_window.size);
        if (required_cache > modules.reu_cache.size) return error.InvalidZeroPageModuleState;
        const planned_end = @as(u64, modules.reu_cache.addr) + required_cache;
        if (planned_end > 0x0100_0000) return error.InvalidZeroPageModuleState;
    }
}

fn moduleStateAnyPersistent(state: ast.ModuleStateOptions) bool {
    if (state.current.mode == .persist_in_reu) return true;
    for (state.deps) |dep_state| {
        if (dep_state.state.mode == .persist_in_reu) return true;
    }
    return false;
}

fn findModuleDependencyOrdinal(module: ast.ZeroPageModule, id: []const u8) ?usize {
    for (module.deps, 0..) |dep, index| {
        if (std.mem.eql(u8, dep, id)) return index;
    }
    return null;
}

fn moduleGraphNodeCount(module: ast.ZeroPageModule, graph: ?ast.ModuleDependencyGraphOptions) usize {
    if (graph) |resolved| return resolved.nodes.len;
    return module.deps.len;
}

fn findModuleGraphNode(graph: ast.ModuleDependencyGraphOptions, id: []const u8) ?ast.ModuleDependencyGraphNode {
    for (graph.nodes) |node| {
        if (std.mem.eql(u8, node.id, id)) return node;
    }
    return null;
}

fn findModuleGraphNodeIndex(graph: ast.ModuleDependencyGraphOptions, id: []const u8) ?usize {
    for (graph.nodes, 0..) |node, index| {
        if (std.mem.eql(u8, node.id, id)) return index;
    }
    return null;
}

fn findManifestDependency(manifest: ast.ModuleDiskManifestOptions, id: []const u8) ?ast.ModuleDiskManifestDependency {
    for (manifest.deps) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

fn validateModuleStateRanges(load_window: ast.ModuleLoadWindowOptions, state: ast.CurrentModuleState) !void {
    for (state.ranges, 0..) |range, index| {
        if (range.size == 0) return error.InvalidZeroPageModuleState;
        const end = @as(u32, range.offset) + @as(u32, range.size);
        if (end > load_window.size) return error.InvalidZeroPageModuleState;
        for (state.ranges[index + 1 ..]) |other| {
            const other_end = @as(u32, other.offset) + @as(u32, other.size);
            if (rangesOverlap(range.offset, end, other.offset, other_end)) return error.InvalidZeroPageModuleState;
        }
    }
}

fn moduleRegistryRows(program: ast.Program, modules: ast.ModuleLoaderOptions) u16 {
    if (modules.registry) |registry| {
        if (modules.disk_manifest != null and program.zeropage_module != null) return registry.capacity;
    }
    return 1;
}

fn validateModuleDiskManifest(program: ast.Program, manifest: ast.ModuleDiskManifestOptions) !void {
    const module = program.zeropage_module orelse return error.InvalidZeroPageModuleDiskManifest;
    if (!isValidModuleDiskFilename(manifest.current)) return error.InvalidZeroPageModuleDiskManifest;
    const graph = if (program.zeropage_options.modules) |modules| modules.dependency_graph else null;
    const required_count = moduleGraphNodeCount(module, graph);
    if (manifest.deps.len != required_count) return error.InvalidZeroPageModuleDiskManifest;
    for (manifest.deps) |entry| {
        if (!isValidModuleId(entry.id)) return error.InvalidZeroPageModuleDiskManifest;
        if (!isValidModuleDiskFilename(entry.filename)) return error.InvalidZeroPageModuleDiskManifest;
        if (graph) |resolved_graph| {
            if (findModuleGraphNode(resolved_graph, entry.id) == null) return error.InvalidZeroPageModuleDiskManifest;
        } else if (findModuleDependencyOrdinal(module, entry.id) == null) return error.InvalidZeroPageModuleDiskManifest;
    }
    if (graph) |resolved_graph| {
        for (resolved_graph.nodes) |node| {
            if (findManifestDependency(manifest, node.id) == null) return error.InvalidZeroPageModuleDiskManifest;
        }
    } else {
        for (module.deps) |dep| {
            if (findManifestDependency(manifest, dep) == null) return error.InvalidZeroPageModuleDiskManifest;
        }
    }
    for (manifest.deps, 0..) |entry, index| {
        if (std.mem.eql(u8, manifest.current, entry.filename)) return error.InvalidZeroPageModuleDiskManifest;
        for (manifest.deps[index + 1 ..]) |other| {
            if (std.mem.eql(u8, entry.filename, other.filename)) return error.InvalidZeroPageModuleDiskManifest;
        }
    }
}

fn isValidModuleDiskFilename(filename: []const u8) bool {
    if (filename.len == 0 or filename.len > 16) return false;
    for (filename) |ch| {
        if (ch >= 'a' and ch <= 'z') continue;
        if (ch >= 'A' and ch <= 'Z') continue;
        if (ch >= '0' and ch <= '9') continue;
        if (ch == '_' or ch == '-') continue;
        return false;
    }
    return true;
}

fn validateModuleLoadPolicy(program: ast.Program, modules: ast.ModuleLoaderOptions, policy: ast.ModulePolicyOptions) !void {
    switch (policy.current.mode) {
        .manual => {},
        .preload, .on_demand => {
            _ = policy.current.filename orelse return error.UnsupportedZeroPageOptions;
            if (program.zeropage_module == null) return error.UnknownZeroPageModule;
            if (program.zeropage_module.?.deps.len != 0) return error.UnsupportedZeroPageModuleDependencyLoad;
            if (modules.disk_staging == null) return error.MissingZeroPageModuleLoader;
        },
    }
    if (policy.deps.len != 0) {
        const module = program.zeropage_module orelse return error.UnknownZeroPageModule;
        _ = modules.registry orelse return error.MissingZeroPageModuleLoader;
        _ = modules.disk_manifest orelse return error.MissingZeroPageModuleLoader;
        _ = modules.disk_staging orelse return error.MissingZeroPageModuleLoader;
        for (policy.deps, 0..) |dep_policy, index| {
            if (dep_policy.policy.filename != null) return error.UnsupportedZeroPageOptions;
            switch (dep_policy.policy.mode) {
                .manual, .preload, .on_demand => {},
            }
            if (dep_policy.policy.graph) {
                if (dep_policy.policy.mode != .on_demand and dep_policy.policy.mode != .preload) return error.UnsupportedZeroPageOptions;
                _ = modules.dependency_graph orelse return error.MissingZeroPageModuleLoader;
            }
            var found = false;
            for (module.deps) |dep| {
                if (std.mem.eql(u8, dep, dep_policy.id)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.UnknownZeroPageModule;
            for (policy.deps[0..index]) |prev| {
                if (std.mem.eql(u8, prev.id, dep_policy.id)) return error.UnsupportedZeroPageOptions;
            }
        }
    }
}

fn validateModuleLoadWindow(program: ast.Program, window: ast.ModuleLoadWindowOptions) !void {
    if (!isPageAligned16(window.addr) or !isPageAligned16(window.size) or window.size == 0) return error.InvalidZeroPageModuleLoadWindow;
    const window_end = @as(u32, window.addr) + @as(u32, window.size);
    if (window_end > 0x10000) return error.InvalidZeroPageModuleLoadWindow;
    switch (window.bank) {
        .visible => {},
        .ram_under_basic => if (window.addr < 0xa000 or window_end > 0xc000) return error.InvalidZeroPageModuleLoadWindow,
        .ram_under_kernal => if (window.addr < 0xe000 or window_end > 0x10000) return error.InvalidZeroPageModuleLoadWindow,
    }
    if (rangesOverlap(window.addr, window_end, 0x0000, 0x0800)) return error.InvalidZeroPageModuleLoadWindow;
    if (rangesOverlap(window.addr, window_end, 0xd000, 0xe000)) return error.InvalidZeroPageModuleLoadWindow;
    if (program.zeropage_options.stack) |stack| {
        const stack_end = @as(u32, stack.base) + @as(u32, stack.size);
        if (rangesOverlap(window.addr, window_end, stack.base, stack_end)) return error.InvalidZeroPageModuleLoadWindow;
    }
    for (program.zeropage_options.heaps) |heap| {
        const heap_end = @as(u32, heap.addr) + @as(u32, heap.size);
        if (rangesOverlap(window.addr, window_end, heap.addr, heap_end)) return error.InvalidZeroPageModuleLoadWindow;
    }
}

fn validateModuleDiskStaging(program: ast.Program, load_window: ast.ModuleLoadWindowOptions, staging: ast.ModuleLoadWindowOptions) !void {
    if (staging.bank != .visible) return error.InvalidZeroPageModuleLoadWindow;
    if (!isPageAligned16(staging.addr) or !isPageAligned16(staging.size) or staging.size == 0) return error.InvalidZeroPageModuleLoadWindow;
    const staging_end = @as(u32, staging.addr) + @as(u32, staging.size);
    if (staging_end > 0x10000) return error.InvalidZeroPageModuleLoadWindow;
    if (rangesOverlap(staging.addr, staging_end, 0x0000, 0x0800)) return error.InvalidZeroPageModuleLoadWindow;
    if (rangesOverlap(staging.addr, staging_end, 0xd000, 0xe000)) return error.InvalidZeroPageModuleLoadWindow;
    const load_end = @as(u32, load_window.addr) + @as(u32, load_window.size);
    if (rangesOverlap(staging.addr, staging_end, load_window.addr, load_end)) return error.InvalidZeroPageModuleLoadWindow;
    if (program.zeropage_options.stack) |stack| {
        const stack_end = @as(u32, stack.base) + @as(u32, stack.size);
        if (rangesOverlap(staging.addr, staging_end, stack.base, stack_end)) return error.InvalidZeroPageModuleLoadWindow;
    }
    for (program.zeropage_options.heaps) |heap| {
        const heap_end = @as(u32, heap.addr) + @as(u32, heap.size);
        if (rangesOverlap(staging.addr, staging_end, heap.addr, heap_end)) return error.InvalidZeroPageModuleLoadWindow;
    }
}

fn validateModuleReuCache(program: ast.Program, cache: ast.ModuleReuCacheOptions) !void {
    if (!isPageAligned32(cache.addr) or !isPageAligned32(cache.size) or cache.size == 0) return error.InvalidZeroPageModuleReuCache;
    if (cache.addr > 0x00ff_ffff) return error.InvalidZeroPageModuleReuCache;
    const cache_end = @as(u64, cache.addr) + @as(u64, cache.size);
    if (cache_end > 0x0100_0000) return error.InvalidZeroPageModuleReuCache;
    for (program.zeropage_options.reu.heaps) |heap| {
        const heap_end = @as(u64, heap.addr) + @as(u64, heap.size);
        if (rangesOverlap64(cache.addr, cache_end, heap.addr, heap_end)) return error.InvalidZeroPageModuleReuCache;
    }
}

fn isPageAligned16(value: u16) bool {
    return (value & 0x00ff) == 0;
}

fn isPageAligned32(value: u32) bool {
    return (value & 0x000000ff) == 0;
}

fn validateLeafStackFunction(program: ast.Program, function: ast.Function) !void {
    for (function.body) |stmt| try validateLeafStackStmt(program, stmt);
}

fn validateStaticToStackBridgeCalls(program: ast.Program, function: ast.Function) !void {
    for (function.body) |stmt| try validateStaticToStackBridgeStmt(program, stmt);
}

fn validateStaticToStackBridgeStmt(program: ast.Program, stmt: ast.Stmt) anyerror!void {
    switch (stmt) {
        .var_decl => |decl| try validateStaticToStackBridgeExpr(program, decl.init),
        inline .assign, .add_assign, .sub_assign, .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => |assign| try validateStaticToStackBridgeExpr(program, assign.value),
        .deref_assign => |assign| {
            try validateStaticToStackBridgeExpr(program, assign.target);
            try validateStaticToStackBridgeExpr(program, assign.value);
        },
        .array_assign, .array_add_assign, .array_sub_assign, .array_mul_assign, .array_bit_and_assign, .array_bit_or_assign, .array_bit_xor_assign, .array_shl_assign, .array_shr_assign => |assign| {
            try validateStaticToStackBridgeExpr(program, assign.index);
            try validateStaticToStackBridgeExpr(program, assign.value);
        },
        .array_field_assign => |assign| {
            try validateStaticToStackBridgeExpr(program, assign.index);
            try validateStaticToStackBridgeExpr(program, assign.value);
        },
        .while_stmt => |while_stmt| {
            try validateStaticToStackBridgeExpr(program, while_stmt.condition);
            for (while_stmt.body) |child| try validateStaticToStackBridgeStmt(program, child);
        },
        .for_stmt => |for_stmt| for (for_stmt.body) |child| try validateStaticToStackBridgeStmt(program, child),
        .switch_stmt => |switch_stmt| {
            try validateStaticToStackBridgeExpr(program, switch_stmt.operand);
            for (switch_stmt.prongs) |prong| for (prong.body) |child| try validateStaticToStackBridgeStmt(program, child);
        },
        .if_stmt => |if_stmt| {
            try validateStaticToStackBridgeExpr(program, if_stmt.condition);
            for (if_stmt.then_body) |child| try validateStaticToStackBridgeStmt(program, child);
            for (if_stmt.else_body) |child| try validateStaticToStackBridgeStmt(program, child);
        },
        .call => |call| try validateStaticToStackBridgeCall(program, call),
        .discard, .return_expr => |expr| try validateStaticToStackBridgeExpr(program, expr),
        .break_expr => |break_expr| try validateStaticToStackBridgeExpr(program, break_expr.value),
        .test6502 => |call| try validateStaticToStackBridgeTest6502(program, call),
        .builtin => |builtin| try validateStaticToStackBridgeBuiltin(program, builtin),
        .reu => |call| try validateStaticToStackBridgeReu(program, call),
        .reu_heap_reset => {},
        .heap_reset => {},
        .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph => {},
        .heap_free => |free| try validateStaticToStackBridgeExpr(program, free.ptr.*),
        .field_assign => |field| try validateStaticToStackBridgeExpr(program, field.value),
        .string_assign => |assign| try validateStaticToStackBridgeStringExpr(program, assign.expr),
        .string_var, .struct_var, .break_stmt, .continue_stmt, .inline_asm => {},
    }
}

fn validateStaticToStackBridgeExpr(program: ast.Program, expr: ast.Expr) anyerror!void {
    switch (expr) {
        .value, .size_of, .align_of, .offset_of => {},
        inline .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| {
            try validateStaticToStackBridgeExpr(program, binary.lhs.*);
            try validateStaticToStackBridgeExpr(program, binary.rhs.*);
        },
        .bit_not, .not, .deref, .ptr_from_int, .int_from_ptr => |child| try validateStaticToStackBridgeExpr(program, child.*),
        .as_cast => |as_cast| try validateStaticToStackBridgeExpr(program, as_cast.expr.*),
        .if_expr => |if_expr| {
            try validateStaticToStackBridgeExpr(program, if_expr.condition.*);
            try validateStaticToStackBridgeExpr(program, if_expr.then_expr.*);
            try validateStaticToStackBridgeExpr(program, if_expr.else_expr.*);
        },
        .switch_expr => |switch_expr| {
            try validateStaticToStackBridgeExpr(program, switch_expr.operand.*);
            for (switch_expr.prongs) |prong| try validateStaticToStackBridgeExpr(program, prong.value);
        },
        .block_expr => |block_expr| for (block_expr.body) |stmt| try validateStaticToStackBridgeStmt(program, stmt),
        .call => |call| try validateStaticToStackBridgeCall(program, call),
        .reu_compare => |transfer| try validateStaticToStackBridgeReuTransfer(program, transfer),
        .reu_heap_alloc => |alloc| try validateStaticToStackBridgeExpr(program, alloc.len.*),
        .reu_view => |view| try validateStaticToStackBridgeExpr(program, view.far.*),
        .far_view_materialize => {},
        .far_view_materialize_range => |range| try validateStaticToStackBridgeExpr(program, range.start.*),
        .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded => {},
        .module_call => |call| for (call.args) |arg| try validateStaticToStackBridgeExpr(program, arg),
        .heap_alloc => |alloc| try validateStaticToStackBridgeExpr(program, alloc.len.*),
        .array_literal => |array| for (array.values) |value| try validateStaticToStackBridgeExpr(program, value),
        .array_index => |index| try validateStaticToStackBridgeExpr(program, index.index.*),
        .array_field_index => |index| try validateStaticToStackBridgeExpr(program, index.index.*),
        .struct_literal => |literal| for (literal.fields) |field| try validateStaticToStackBridgeExpr(program, field.value),
        .c64_read_petscii, .c64_wait_petscii, .reu_present, .address_of => {},
    }
}

fn validateStaticToStackBridgeCall(program: ast.Program, call: ast.CallExpr) !void {
    const target = findFunctionForCall(program, call.target) orelse return;
    if (tass64.effectiveFramePolicy(program, target.name) != .stack) {
        for (call.args) |arg| try validateStaticToStackBridgeExpr(program, arg);
        return;
    }
    for (call.args) |arg| {
        if (tass64.exprContainsCall(arg)) return error.UnsupportedStackFrameBridgeArgument;
        try validateStaticToStackBridgeExpr(program, arg);
    }
}

fn validateStaticToStackBridgeTest6502(program: ast.Program, call: ast.Test6502Call) !void {
    switch (call) {
        .expect_null => |expect| try validateStaticToStackBridgeExpr(program, expect.actual),
        .expect_some_u8, .expect_some_u16, .expect_some_bool, .expect_some_ptr, .expect_equal_u8, .expect_equal_i8, .expect_equal_bool, .expect_equal_u16 => |expect| try validateStaticToStackBridgeExpr(program, expect.actual),
        else => {},
    }
}

fn validateStaticToStackBridgeBuiltin(program: ast.Program, builtin: ast.BuiltinCall) !void {
    switch (builtin) {
        .put_at => |put| try validateStaticToStackBridgeExpr(program, put.ch),
        .hex_at, .hex16_at => |hex| try validateStaticToStackBridgeExpr(program, hex.value),
        .console_print => |print| for (print.args) |arg| if (arg == .value) try validateStaticToStackBridgeExpr(program, arg.value),
        .string_append => |append| try validateStaticToStackBridgeStringExpr(program, append.expr),
        .sleep_ticks, .sleep_frames => |sleep| try validateStaticToStackBridgeExpr(program, sleep.ticks),
        else => {},
    }
}

fn validateStaticToStackBridgeReu(program: ast.Program, call: ast.ReuStmt) !void {
    switch (call) {
        .copy_c64_to_reu, .copy_reu_to_c64, .swap => |transfer| try validateStaticToStackBridgeReuTransfer(program, transfer),
        .fill => |fill| {
            try validateStaticToStackBridgeExpr(program, fill.value.*);
            try validateStaticToStackBridgeExpr(program, fill.len.*);
        },
        .copy_from_c64, .copy_to_c64 => |copy| {
            try validateStaticToStackBridgeExpr(program, copy.far.*);
            try validateStaticToStackBridgeExpr(program, copy.c64_addr.*);
            try validateStaticToStackBridgeExpr(program, copy.len.*);
        },
    }
}

fn validateStaticToStackBridgeReuTransfer(program: ast.Program, transfer: ast.ReuTransfer) !void {
    try validateStaticToStackBridgeExpr(program, transfer.c64_addr.*);
    try validateStaticToStackBridgeExpr(program, transfer.len.*);
}

fn validateStaticToStackBridgeStringExpr(program: ast.Program, expr: ast.StringExpr) !void {
    _ = program;
    _ = expr;
}

fn validateLeafStackStmt(program: ast.Program, stmt: ast.Stmt) anyerror!void {
    switch (stmt) {
        .var_decl => |decl| try validateLeafStackExpr(program, decl.init),
        .assign => |assign| try validateLeafStackExpr(program, assign.value),
        inline .add_assign, .sub_assign, .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => |assign| try validateLeafStackExpr(program, assign.value),
        .while_stmt => |while_stmt| {
            try validateLeafStackExpr(program, while_stmt.condition);
            for (while_stmt.body) |child| try validateLeafStackStmt(program, child);
        },
        .for_stmt => |for_stmt| {
            switch (for_stmt.source) {
                .range => {},
                .array, .array_indexed => return error.UnsupportedStackFrameAggregate,
            }
            for (for_stmt.body) |child| try validateLeafStackStmt(program, child);
        },
        .switch_stmt => |switch_stmt| {
            try validateLeafStackExpr(program, switch_stmt.operand);
            for (switch_stmt.prongs) |prong| {
                for (prong.body) |child| try validateLeafStackStmt(program, child);
            }
        },
        .if_stmt => |if_stmt| {
            try validateLeafStackExpr(program, if_stmt.condition);
            for (if_stmt.then_body) |child| try validateLeafStackStmt(program, child);
            for (if_stmt.else_body) |child| try validateLeafStackStmt(program, child);
        },
        .discard, .return_expr => |expr| try validateLeafStackExpr(program, expr),
        .field_assign => |field| try validateLeafStackExpr(program, field.value),
        .test6502 => |call| try validateLeafStackTest6502(program, call),
        .call => |call| try validateStackToStaticBridgeCall(program, call),
        .builtin => |builtin| try validateLeafStackBuiltin(program, builtin),
        .reu, .reu_heap_reset, .heap_reset, .heap_free, .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph => return error.UnsupportedStackFrameRuntimeCall,
        .string_var, .string_assign => return error.UnsupportedStackFrameString,
        .struct_var, .array_assign, .array_add_assign, .array_sub_assign, .array_mul_assign, .array_bit_and_assign, .array_bit_or_assign, .array_bit_xor_assign, .array_shl_assign, .array_shr_assign, .array_field_assign => return error.UnsupportedStackFrameAggregate,
        .deref_assign, .break_expr, .inline_asm => return error.UnsupportedStackFrameType,
        .break_stmt, .continue_stmt => {},
    }
}

fn validateLeafStackBuiltin(program: ast.Program, builtin: ast.BuiltinCall) anyerror!void {
    switch (builtin) {
        .console_clear, .console_puts => {},
        .console_print => |print| {
            for (print.args) |arg| switch (arg) {
                .string => {},
                .value => return error.UnsupportedStackFrameRuntimeCall,
            };
        },
        else => return error.UnsupportedStackFrameRuntimeCall,
    }
    _ = program;
}

fn validateLeafStackExpr(program: ast.Program, expr: ast.Expr) anyerror!void {
    switch (expr) {
        .value, .size_of, .align_of, .offset_of => {},
        inline .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| {
            try validateLeafStackExpr(program, binary.lhs.*);
            try validateLeafStackExpr(program, binary.rhs.*);
        },
        .bit_not, .not, .deref, .ptr_from_int, .int_from_ptr => |child| try validateLeafStackExpr(program, child.*),
        .as_cast => |as_cast| try validateLeafStackExpr(program, as_cast.expr.*),
        .if_expr => |if_expr| {
            try validateLeafStackExpr(program, if_expr.condition.*);
            try validateLeafStackExpr(program, if_expr.then_expr.*);
            try validateLeafStackExpr(program, if_expr.else_expr.*);
        },
        .switch_expr => |switch_expr| {
            try validateLeafStackExpr(program, switch_expr.operand.*);
            for (switch_expr.prongs) |prong| try validateLeafStackExpr(program, prong.value);
        },
        .block_expr => |block_expr| {
            for (block_expr.body) |stmt| try validateLeafStackStmt(program, stmt);
        },
        .call => |call| try validateStackToStaticBridgeCall(program, call),
        .c64_read_petscii, .c64_wait_petscii, .reu_present, .reu_compare, .reu_heap_alloc, .reu_view, .far_view_materialize, .far_view_materialize_range, .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded, .module_call, .heap_alloc => return error.UnsupportedStackFrameRuntimeCall,
        .array_literal, .array_index, .array_field_index, .struct_literal => return error.UnsupportedStackFrameAggregate,
        .address_of => {},
    }
}

fn validateLeafStackTest6502(program: ast.Program, call: ast.Test6502Call) !void {
    switch (call) {
        .expect_null => |expect| try validateLeafStackExpr(program, expect.actual),
        .expect_some_u8, .expect_some_u16, .expect_some_bool, .expect_some_ptr, .expect_equal_u8, .expect_equal_i8, .expect_equal_bool, .expect_equal_u16 => |expect| try validateLeafStackExpr(program, expect.actual),
        .expect_string => return error.UnsupportedStackFrameRuntimeCall,
        else => {},
    }
}

fn validateStackToStaticBridgeCall(program: ast.Program, call: ast.CallExpr) !void {
    const target = findFunctionForCall(program, call.target) orelse return error.UnknownFunction;
    if (target.params.len != call.args.len) return error.ArgumentCountMismatch;
    if (tass64.effectiveFramePolicy(program, target.name) == .stack) {
        if (target.exported) return error.UnsupportedStackFrameBridge;
        try validateStackBridgeBoundaryType(program, target.return_type);
        for (target.params, 0..) |param, index| {
            try validateStackBridgeBoundaryType(program, param.ty);
            if (tass64.exprContainsCall(call.args[index])) return error.UnsupportedStackFrameBridgeArgument;
            try validateLeafStackExpr(program, call.args[index]);
        }
        return;
    }
    try validateStackBridgeBoundaryType(program, target.return_type);
    for (target.params, 0..) |param, index| {
        try validateStackBridgeBoundaryType(program, param.ty);
        if (tass64.exprContainsCall(call.args[index])) return error.UnsupportedStackFrameBridgeArgument;
        try validateLeafStackExpr(program, call.args[index]);
    }
}

fn findFunctionForCall(program: ast.Program, target: []const u8) ?ast.Function {
    for (program.functions) |function| {
        if (functionNameMatchesCallTarget(function.name, target)) return function;
    }
    return null;
}

fn functionNameMatchesCallTarget(function_name: []const u8, target: []const u8) bool {
    if (function_name.len != target.len) return false;
    for (target, 0..) |ch, index| {
        const expected = if (ch == '.') '_' else ch;
        if (function_name[index] != expected) return false;
    }
    return true;
}

fn validateStackBridgeBoundaryType(program: ast.Program, ty: ast.Type) !void {
    return switch (ty) {
        .void, .u8, .i8, .bool, .u16, .i16, .usize, .pointer => {},
        .far_bytes, .far_view, .near_view => error.UnsupportedStackFrameAggregate,
        .custom => |name| {
            if (program.findStruct(name) != null) return error.UnsupportedStackFrameAggregate;
            if (program.findUnion(name) != null) return error.UnsupportedStackFrameUnion;
        },
        .array => error.UnsupportedStackFrameAggregate,
        .optional => error.UnsupportedStackFrameOptional,
    };
}

fn moveTypeDecls(allocator: std.mem.Allocator, type_decls: *std.ArrayList(ast.TypeDecl), parsed_program: *parser.ParseResult) !void {
    try type_decls.appendSlice(allocator, parsed_program.program.type_decls);
    if (parsed_program.program.type_decls.len != 0) allocator.free(parsed_program.program.type_decls);
    parsed_program.program.type_decls = &.{};
}

fn moveStringConstants(allocator: std.mem.Allocator, string_constants: *std.ArrayList(ast.StringConstant), parsed_program: *parser.ParseResult) !void {
    try string_constants.appendSlice(allocator, parsed_program.program.string_constants);
    if (parsed_program.program.string_constants.len != 0) allocator.free(parsed_program.program.string_constants);
    parsed_program.program.string_constants = &.{};
}

fn moveArrayConstants(allocator: std.mem.Allocator, array_constants: *std.ArrayList(ast.ArrayConstant), parsed_program: *parser.ParseResult) !void {
    try array_constants.appendSlice(allocator, parsed_program.program.array_constants);
    if (parsed_program.program.array_constants.len != 0) allocator.free(parsed_program.program.array_constants);
    parsed_program.program.array_constants = &.{};
}

fn moveFunctions(allocator: std.mem.Allocator, functions: *std.ArrayList(ast.Function), parsed_program: *parser.ParseResult) !void {
    try functions.appendSlice(allocator, parsed_program.program.functions);
    if (parsed_program.program.functions.len != 0) allocator.free(parsed_program.program.functions);
    parsed_program.program.functions = &.{};
}

const LocalImport = struct {
    alias: []const u8,
    path: []const u8,
};

fn isZeroPageSourcePath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zp64");
}

fn collectLocalImports(allocator: std.mem.Allocator, owner_path: []const u8, bytes: []const u8) ![]LocalImport {
    var imports: std.ArrayList(LocalImport) = .empty;
    errdefer {
        for (imports.items) |item| allocator.free(item.path);
        imports.deinit(allocator);
    }

    var index: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, index, "@import(\"")) |found| {
        const literal_start = found + "@import(\"".len;
        const maybe_end = std.mem.indexOfScalarPos(u8, bytes, literal_start, '"') orelse return error.UnexpectedEof;
        const import_text = bytes[literal_start..maybe_end];
        index = maybe_end + 1;
        if (!isZeroPageSourcePath(import_text)) continue;

        const alias = findConstAliasBeforeImport(bytes, found) orelse return error.UnsupportedStatement;
        const dir = std.fs.path.dirname(owner_path) orelse ".";
        const import_path = try std.fs.path.join(allocator, &.{ dir, import_text });
        try imports.append(allocator, .{ .alias = alias, .path = import_path });
    }

    return try imports.toOwnedSlice(allocator);
}

fn findConstAliasBeforeImport(bytes: []const u8, import_offset: usize) ?[]const u8 {
    const line_start = if (std.mem.lastIndexOfScalar(u8, bytes[0..import_offset], '\n')) |pos| pos + 1 else 0;
    var cursor = line_start;
    while (cursor < import_offset and std.ascii.isWhitespace(bytes[cursor])) cursor += 1;
    if (!std.mem.startsWith(u8, bytes[cursor..import_offset], "const")) return null;
    cursor += "const".len;
    while (cursor < import_offset and std.ascii.isWhitespace(bytes[cursor])) cursor += 1;
    const alias_start = cursor;
    while (cursor < import_offset and (std.ascii.isAlphanumeric(bytes[cursor]) or bytes[cursor] == '_')) cursor += 1;
    if (cursor == alias_start) return null;
    return bytes[alias_start..cursor];
}

fn renderParseError(path: []const u8, err: anyerror, stderr: anytype) !void {
    if (err == error.UnsupportedStdImport) {
        try diag.unsupportedStdImport(path).render(stderr);
    } else if (parser.unsupportedFeatureMessage(err)) |message| {
        try diag.unsupportedFeature(path, message[0], message[1]).render(stderr);
    } else if (err == error.ZigSyntaxError) {
        try stderr.print("{s}: error: Zig parser rejected source syntax\n", .{path});
    } else {
        try stderr.print("{s}: error: valid Zig syntax, but unsupported ZeroPage subset construct\n", .{path});
    }
}

fn renderLowerError(path: []const u8, err: anyerror, stderr: anytype) !void {
    switch (err) {
        error.UnknownStringConstant => try stderr.print(
            "{s}: error: unknown string value; use a known string constant, fixed-capacity buffer, or PETSCII control constant\n",
            .{path},
        ),
        error.UnsupportedFormatArgument => try stderr.print(
            "{s}: error: unsupported format argument; use strings/buffers for {{s}} and scalar values for {{x}}/{{x16}}\n",
            .{path},
        ),
        error.UnsupportedSignedOrderedComparison => try stderr.print(
            "{s}: error: unsupported signed ordered comparison; i8/i16 ordering is deferred until signed semantics are explicit\n",
            .{path},
        ),
        error.UnsupportedBoolOrderedComparison => try stderr.print(
            "{s}: error: unsupported bool ordered comparison; use ==, !=, if (flag), or !flag\n",
            .{path},
        ),
        error.UnsupportedSignedMultiplication => try stderr.print(
            "{s}: error: unsupported signed multiplication; i8/i16 multiplication is deferred until signed arithmetic semantics are explicit\n",
            .{path},
        ),
        error.UnsupportedBoolMultiplication => try stderr.print(
            "{s}: error: unsupported bool multiplication; use boolean operators for bool expressions\n",
            .{path},
        ),
        error.UnsupportedMultiplicationType => try stderr.print(
            "{s}: error: unsupported multiplication operands; * currently supports unsigned scalar values only\n",
            .{path},
        ),
        error.UnsupportedSignedBitwise => try stderr.print(
            "{s}: error: unsupported signed bitwise operation; i8/i16 bitwise operators are deferred until signed integer semantics are explicit\n",
            .{path},
        ),
        error.UnsupportedBoolBitwise => try stderr.print(
            "{s}: error: unsupported bool bitwise operation; use boolean operators for bool expressions\n",
            .{path},
        ),
        error.UnsupportedBitwiseType => try stderr.print(
            "{s}: error: unsupported bitwise operands; bitwise operators currently support unsigned scalar values only\n",
            .{path},
        ),
        error.UnsupportedSignedShift => try stderr.print(
            "{s}: error: unsupported signed shift; i8/i16 shifts are deferred until signed integer semantics are explicit\n",
            .{path},
        ),
        error.UnsupportedBoolShift => try stderr.print(
            "{s}: error: unsupported bool shift; shift operators require unsigned scalar values\n",
            .{path},
        ),
        error.UnsupportedShiftType => try stderr.print(
            "{s}: error: unsupported shift operands; shift operators currently support unsigned scalar values only\n",
            .{path},
        ),
        error.UnsupportedOversizedShift => try stderr.print(
            "{s}: error: unsupported oversized literal shift; literal shift counts must be smaller than the left operand width\n",
            .{path},
        ),
        error.UnsupportedNonBoolCondition => try stderr.print(
            "{s}: error: unsupported non-bool condition; if/while, !, and/or require bool expressions\n",
            .{path},
        ),
        error.UnsupportedForRange => try stderr.print(
            "{s}: error: unsupported for range; ZeroPage range loops currently support 0..N with a byte-sized literal or fixed array .len\n",
            .{path},
        ),
        error.UnsupportedSwitchType => try stderr.print(
            "{s}: error: unsupported switch operand; scalar switch currently supports bool, u8, i8, u16, i16, and usize\n",
            .{path},
        ),
        error.UnsupportedSwitchSelector => try stderr.print(
            "{s}: error: unsupported switch selector; switch prongs require compatible scalar constants\n",
            .{path},
        ),
        error.UnsupportedSwitchPayload => try stderr.print(
            "{s}: error: unsupported switch payload; payload captures require scalar switch operands or union prongs with payloads\n",
            .{path},
        ),
        error.UnsupportedSwitchRange => try stderr.print(
            "{s}: error: unsupported switch range; ranges are unsigned scalar constant ranges only\n",
            .{path},
        ),
        error.UnsupportedSwitchMissingElse => try stderr.print(
            "{s}: error: unsupported non-exhaustive switch; integer switches require else and bool switches require true/false or else\n",
            .{path},
        ),
        error.UnsupportedSwitchDuplicateSelector => try stderr.print(
            "{s}: error: unsupported duplicate switch selector; scalar switch prongs must not overlap\n",
            .{path},
        ),
        error.UnsupportedSwitchResult => try stderr.print(
            "{s}: error: unsupported switch expression result types; scalar switch expressions require compatible bool or numeric prong values\n",
            .{path},
        ),
        error.UnsupportedIfExpressionBranches => try stderr.print(
            "{s}: error: unsupported if expression branch types; scalar if expressions require compatible bool or numeric branches\n",
            .{path},
        ),
        error.UnsupportedBlockExpressionMissingBreak => try stderr.print(
            "{s}: error: unsupported block expression; scalar block expressions require a matching break value\n",
            .{path},
        ),
        error.UnsupportedBlockExpressionBreak => try stderr.print(
            "{s}: error: unsupported block expression break; labeled break values must target an active scalar block expression\n",
            .{path},
        ),
        error.UnsupportedBlockExpressionResult => try stderr.print(
            "{s}: error: unsupported block expression result types; scalar block breaks require compatible bool or numeric values\n",
            .{path},
        ),
        error.ImmutableLocalMutation => try stderr.print(
            "{s}: error: immutable local binding cannot be assigned; use var for mutable storage\n",
            .{path},
        ),
        error.UnsupportedInlineAsmConstOperand => try stderr.print(
            "{s}: error: unsupported inline asm const operand; @name operands must refer to mutable byte locals or params\n",
            .{path},
        ),
        error.UnsupportedInlineAsmStringOperand => try stderr.print(
            "{s}: error: unsupported inline asm string operand; use @name.data, #<@name.data, #>@name.data, #@const.len, or @buffer.len\n",
            .{path},
        ),
        error.UnknownInlineAsmStringOperand => try stderr.print(
            "{s}: error: unknown inline asm string operand; use a module string constant or mutable string buffer name\n",
            .{path},
        ),
        error.UnsupportedInlineAsmConstStringWrite => try stderr.print(
            "{s}: error: unsupported inline asm const string write; module string constants are read-only\n",
            .{path},
        ),
        error.UnsupportedInlineAsmRuntimeStringLenImmediate => try stderr.print(
            "{s}: error: unsupported inline asm runtime string length immediate; mutable buffer length lives in runtime storage\n",
            .{path},
        ),
        error.UnsupportedArrayByValue => try stderr.print(
            "{s}: error: unsupported array by-value use; fixed arrays are storage only in v1, not params, returns, or scalar values\n",
            .{path},
        ),
        error.UnsupportedArrayLiteral => try stderr.print(
            "{s}: error: unsupported array literal; fixed arrays require scalar elements and a matching fixed length\n",
            .{path},
        ),
        error.UnsupportedArrayIndex => try stderr.print(
            "{s}: error: unsupported array index; literal indexes must be within the fixed array length\n",
            .{path},
        ),
        error.UnsupportedEnum => try stderr.print(
            "{s}: error: unsupported enum; ZeroPage enums currently require explicit enum(u8) byte tags\n",
            .{path},
        ),
        error.UnsupportedEnumLiteral => try stderr.print(
            "{s}: error: unsupported enum literal; enum tags must exist and match the destination enum type\n",
            .{path},
        ),
        error.UnsupportedStruct => try stderr.print(
            "{s}: error: unsupported struct; ZeroPage structs currently flatten scalar, enum, fixed array, and nested struct fields\n",
            .{path},
        ),
        error.UnsupportedCompositeField => try stderr.print(
            "{s}: error: unsupported composite field; field paths must resolve to known flattened scalar or fixed-array storage\n",
            .{path},
        ),
        error.UnsupportedPointerType => try stderr.print(
            "{s}: error: unsupported pointer type; ZeroPage pointer v1 supports *T and *volatile T for scalar or enum storage only\n",
            .{path},
        ),
        error.UnsupportedPointerTarget => try stderr.print(
            "{s}: error: unsupported pointer target; address-of targets mutable scalar storage or literal-index array elements\n",
            .{path},
        ),
        error.UnsupportedPointerCast => try stderr.print(
            "{s}: error: unsupported pointer builtin; use @ptrFromInt in a typed pointer context or @intFromPtr on a scalar pointer\n",
            .{path},
        ),
        error.UnknownHeap => try stderr.print(
            "{s}: error: unknown heap; ZeroPage.heap and ZeroPage.reu.heap require names declared in main-source zeropage_options\n",
            .{path},
        ),
        error.InvalidZeroPageImage => try stderr.print(
            "{s}: error: invalid zeropage_options image; PRG load/entry addresses must be ordered below the exclusive address_limit, and a BASIC stub must load at $0801 without overlapping entry code\n",
            .{path},
        ),
        error.UnsupportedZeroPageRomService => try stderr.print(
            "{s}: error: unsupported ROM service for zero-page policy; KERNAL borrowing allows documented non-destructive KERNAL jump-table calls, while bare ownership disallows ROM services\n",
            .{path},
        ),
        error.UnsupportedZeroPageModuleABI => try stderr.print(
            "{s}: error: unsupported zero-page module ABI; DLL packaging and module loaders currently require the compatibility policy\n",
            .{path},
        ),
        error.UnsupportedZeroPageBareEntry => try stderr.print(
            "{s}: error: unsupported bare zero-page entry; omit the BASIC stub and establish application IRQ/NMI ownership before zeropage_entry\n",
            .{path},
        ),
        error.UnsupportedZeroPageLowImage => try stderr.print(
            "{s}: error: unsupported zero-page image overlap; explicit zero-page policies require image load and entry at or above $0200\n",
            .{path},
        ),
        error.InvalidZeroPageMemoryRegion, error.UnknownZeroPageMemoryRegion => try stderr.print(
            "{s}: error: invalid zeropage_options memory region; named C64/REU regions must be unique, nonempty, non-overlapping, bounded, and use a compatible banking mode\n",
            .{path},
        ),
        error.InvalidZeroPageMemoryPlacement, error.UnknownZeroPageMemoryPlacementDeclaration => try stderr.print(
            "{s}: error: invalid zeropage_options memory placement; declarations must be unique known non-main functions/constants in a compatible C64 region that does not conflict with stacks, arenas, or DLL windows\n",
            .{path},
        ),
        error.UnsafeBankedMemoryPlacementReference => try stderr.print(
            "{s}: error: unsafe banked memory placement reference; constants under BASIC/KERNAL ROM may only be referenced by functions in the same placement\n",
            .{path},
        ),
        error.UnsafeKernalBankMemoryPlacement => try stderr.print(
            "{s}: error: unsafe KERNAL-bank memory placement; code running under KERNAL ROM cannot use KERNAL, keyboard, disk, or unsupported ROM-backed helpers\n",
            .{path},
        ),
        error.ZeroPageImageAddressLimitExceeded => try stderr.print(
            "{s}: error: resident PRG exceeds zeropage_options.image.address_limit\n",
            .{path},
        ),
        error.InvalidZeroPageHeapRegion => try stderr.print(
            "{s}: error: invalid zeropage_options heap region; heap regions must be nonzero, fit in C64 RAM, and avoid reserved/generated memory\n",
            .{path},
        ),
        error.InvalidZeroPageHeapBlock => try stderr.print(
            "{s}: error: invalid zeropage_options heap block; fixed heap blocks must be >= 2, fit the heap region, and divide it evenly\n",
            .{path},
        ),
        error.InvalidZeroPageReuHeapRegion => try stderr.print(
            "{s}: error: invalid zeropage_options REU heap region; far heap regions must be nonzero, fit the 16 MB REU address space, and not overlap\n",
            .{path},
        ),
        error.UnsupportedHeapFunction => try stderr.print(
            "{s}: error: unsupported heap function; near heaps support allocBytes/reset, plus free on fixed heaps only\n",
            .{path},
        ),
        error.UnsupportedZeroPageStackAbi => try stderr.print(
            "{s}: error: unsupported stack frame ABI; ZeroPage supports static and scalar software-stack frames\n",
            .{path},
        ),
        error.MissingZeroPageStackRegion => try stderr.print(
            "{s}: error: missing zeropage_options stack region; callconv(.stack) requires a configured software stack\n",
            .{path},
        ),
        error.InvalidZeroPageStackRegion => try stderr.print(
            "{s}: error: invalid software stack region; the named stack overlaps the resident PRG\n",
            .{path},
        ),
        error.UnsupportedStackFrameBridge => try stderr.print(
            "{s}: error: unsupported stack frame bridge; ZeroPage software stack functions are limited to leaf export main or non-exported leaf helpers called from static code in this slice\n",
            .{path},
        ),
        error.UnsupportedStackFrameBridgeArgument => try stderr.print(
            "{s}: error: unsupported stack frame bridge argument; software stack bridge calls cannot contain nested user calls in their arguments yet\n",
            .{path},
        ),
        error.UnsupportedStackFrameCall => try stderr.print(
            "{s}: error: unsupported stack frame call; this ZeroPage software stack call shape is not supported by the current scalar bridge ABI\n",
            .{path},
        ),
        error.UnsupportedStackFrameRuntimeCall => try stderr.print(
            "{s}: error: unsupported stack frame runtime helper; ZeroPage software stack functions cannot call C64 helper/runtime APIs in this slice\n",
            .{path},
        ),
        error.UnsupportedStackFrameTooLarge => try stderr.print(
            "{s}: error: unsupported stack frame size; first ZeroPage software stack codegen requires frames of 255 bytes or less\n",
            .{path},
        ),
        error.UnsupportedStackFrameAggregate => try stderr.print(
            "{s}: error: unsupported stack frame aggregate; stack frames currently support scalar values and near pointers only\n",
            .{path},
        ),
        error.UnsupportedStackFrameOptional => try stderr.print(
            "{s}: error: unsupported stack frame optional; optional stack storage is deferred until scalar stack codegen is proven\n",
            .{path},
        ),
        error.UnsupportedStackFrameString => try stderr.print(
            "{s}: error: unsupported stack frame string buffer; mutable strings remain static until stack ABI supports aggregates\n",
            .{path},
        ),
        error.UnsupportedStackFrameUnion => try stderr.print(
            "{s}: error: unsupported stack frame union; union storage remains static until stack ABI supports aggregates\n",
            .{path},
        ),
        error.UnsupportedStackFrameType => try stderr.print(
            "{s}: error: unsupported stack frame type inference; add an explicit scalar type or keep the function static\n",
            .{path},
        ),
        error.UnknownZeroPageOptionsFunction => try stderr.print(
            "{s}: error: unknown zeropage_options function override; names must match emitted function labels\n",
            .{path},
        ),
        error.UnsupportedZeroPageModule => try stderr.print(
            "{s}: error: unsupported zeropage_module metadata; use .id, .abi = 1, empty .flags, .exports, and .deps only\n",
            .{path},
        ),
        error.UnsupportedImportedZeroPageModule => try stderr.print(
            "{s}: error: unsupported imported zeropage_module metadata; loadable module descriptors are main-source-only until separately compiled modules land\n",
            .{path},
        ),
        error.DuplicateZeroPageModule => try stderr.print(
            "{s}: error: duplicate zeropage_module metadata; declare zeropage_module at most once\n",
            .{path},
        ),
        error.InvalidZeroPageModuleId => try stderr.print(
            "{s}: error: invalid zeropage_module id; ids and deps must be lowercase ASCII with optional '-', '_', and digits after the first character\n",
            .{path},
        ),
        error.InvalidZeroPageModuleAbi => try stderr.print(
            "{s}: error: invalid zeropage_module ABI; module sidecars support ABI version 1 only\n",
            .{path},
        ),
        error.DuplicateZeroPageModuleExport => try stderr.print(
            "{s}: error: duplicate zeropage_module export; export names must be unique\n",
            .{path},
        ),
        error.DuplicateZeroPageModuleDependency => try stderr.print(
            "{s}: error: duplicate zeropage_module dependency; dependency ids must be unique and remain in declaration order\n",
            .{path},
        ),
        error.UnknownZeroPageModuleExport => try stderr.print(
            "{s}: error: unknown zeropage_module export; exports must name emitted functions in the flattened program\n",
            .{path},
        ),
        error.UnsupportedZeroPageModuleExport => try stderr.print(
            "{s}: error: unsupported zeropage_module export; module exports must be scalar .stack ABI functions\n",
            .{path},
        ),
        error.UnsafeKernalBankModuleExport => try stderr.print(
            "{s}: error: unsafe KERNAL-bank module export; exports assigned to .ram_under_kernal may only use trampoline-safe console KERNAL paths\n",
            .{path},
        ),
        error.UnsupportedZeroPageModuleRelocation => try stderr.print(
            "{s}: error: unsupported zeropage_module relocation; module export call graphs may only take addresses of immutable module rodata selected into the module payload\n",
            .{path},
        ),
        error.InvalidZeroPageModuleRelocation => try stderr.print(
            "{s}: error: invalid zeropage_module relocation; relocation anchors and targets must resolve inside the selected module payload\n",
            .{path},
        ),
        error.InvalidZeroPageModuleLoadWindow => try stderr.print(
            "{s}: error: invalid zeropage_options module load window; load windows must be page-aligned, nonzero, fit C64 RAM, and avoid reserved/generated memory\n",
            .{path},
        ),
        error.InvalidZeroPageModuleReuCache => try stderr.print(
            "{s}: error: invalid zeropage_options module REU cache; module caches must be page-aligned, nonzero, fit the 16 MB REU address space, and avoid REU heaps\n",
            .{path},
        ),
        error.ZeroPageModulePayloadTooLarge => try stderr.print(
            "{s}: error: zeropage module payload too large; selected module payload must fit the configured load window and REU cache\n",
            .{path},
        ),
        error.UnknownZeroPageModule => try stderr.print(
            "{s}: error: unknown ZeroPage.module id; ZeroPage.module.load currently supports only the current main-source zeropage_module id\n",
            .{path},
        ),
        error.MissingZeroPageModuleLoader => try stderr.print(
            "{s}: error: missing zeropage_options module loader metadata; ZeroPage.module.load requires .modules.load_window and .modules.reu_cache\n",
            .{path},
        ),
        error.UnsupportedZeroPageModuleDependencyLoad => try stderr.print(
            "{s}: error: unsupported ZeroPage.module.load dependency graph; first runtime loading supports only the current module with an empty .deps set\n",
            .{path},
        ),
        error.InvalidZeroPageModuleRegistry => try stderr.print(
            "{s}: error: invalid zeropage_options module registry; capacity must fit the current module plus dependency graph rows, dependencies may not name the current module, graph edges must be acyclic, and planned REU cache rows must fit\n",
            .{path},
        ),
        error.InvalidZeroPageModuleDiskManifest => try stderr.print(
            "{s}: error: invalid zeropage_options module disk manifest; filenames must be unique C64-safe strings and deps must exactly match zeropage_module.deps or every .modules.dependency_graph node\n",
            .{path},
        ),
        error.InvalidZeroPageModuleState => try stderr.print(
            "{s}: error: invalid zeropage_options module state; persistent state ranges must be nonzero, non-overlapping load-window offsets with enough REU cache space\n",
            .{path},
        ),
        error.MissingZeroPageDependencySidecar, error.MissingDependencySidecar => try stderr.print(
            "{s}: error: missing dependency module sidecar; dependency calls require --dependency-module dep=path and --dependency-relocsim dep=path\n",
            .{path},
        ),
        error.InvalidZeroPageDependencySidecar, error.InvalidDependencySidecarArg => try stderr.print(
            "{s}: error: invalid dependency module sidecar; sidecars must match dependency ids, ABI 1, scalar stack exports, loader window, payload size, and supported relocations\n",
            .{path},
        ),
        error.UnsupportedCast => try stderr.print(
            "{s}: error: unsupported @as cast; ZeroPage @as is a type annotation over existing scalar, enum, and exact pointer storage, not reinterpretation\n",
            .{path},
        ),
        error.Overflow => try stderr.print(
            "{s}: error: integer value out of range for target storage\n",
            .{path},
        ),
        else => try stderr.print("{s}: error: ZeroPage lowering/codegen failed: {s}\n", .{ path, @errorName(err) }),
    }
}

fn commandCompile(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const parsed = try parseInputOutput(args, "build/out.prg");
    const asm_path = try std.fmt.allocPrint(allocator, "{s}.asm", .{parsed.output});
    defer allocator.free(asm_path);
    var dependency_sidecars = try loadDependencySidecarsFromArgs(allocator, args);
    defer dependency_sidecars.deinit(allocator);

    const src_for_asm = try source.load(allocator, parsed.input);
    defer src_for_asm.deinit(allocator);
    const asm_text_for_write = try lowerSourceToAsmWithOptions(allocator, src_for_asm.path, src_for_asm.bytes, stderr, .{ .dependency_modules = dependency_sidecars.modules });
    defer allocator.free(asm_text_for_write);
    try writeFile(asm_path, asm_text_for_write);
    try stdout.print("wrote {s}\n", .{asm_path});

    const maybe_tass = try tooling.resolve(allocator, io, env_map, .tass64);
    if (maybe_tass == null) {
        try stderr.writeAll("error: 64tass not found; set ZEROPAGE_64TASS or install ../zeropage-tooling/bin/64tass\n");
        return error.ToolMissing;
    }
    const tass_tool = maybe_tass.?;
    defer tooling.freeResolved(allocator, tass_tool);

    const labels_path = try std.fmt.allocPrint(allocator, "{s}.labels", .{parsed.output});
    defer allocator.free(labels_path);

    const argv = [_][]const u8{
        tass_tool.path,
        "--m65xx",
        "--cbm-prg",
        "--vice-labels",
        "-l",
        labels_path,
        "-o",
        parsed.output,
        asm_path,
    };
    try runChild(allocator, io, &argv);

    const prg_file = try prg.readFile(allocator, parsed.output);
    defer prg_file.deinit(allocator);

    const asm_text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, asm_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(asm_text);
    const src = try source.load(allocator, parsed.input);
    defer src.deinit(allocator);
    var loaded = try loadProgram(allocator, src.path, src.bytes, stderr);
    defer loaded.deinit();
    try validateProgramMetadata(allocator, loaded.program, parsed.input, stderr);
    const image = loaded.program.zeropage_options.image;
    if (prg_file.prg.load_address != image.load_addr) return error.UnexpectedLoadAddress;
    const resident_end = @as(u32, prg_file.prg.load_address) + @as(u32, @intCast(prg_file.prg.payload.len));
    if (resident_end > image.address_limit) {
        try renderLowerError(parsed.input, error.ZeroPageImageAddressLimitExceeded, stderr);
        return error.ZeroPageImageAddressLimitExceeded;
    }
    validateHeapRegionsAgainstPrg(loaded.program, prg_file.prg.load_address, prg_file.prg.payload.len) catch |err| {
        try renderLowerError(parsed.input, err, stderr);
        return err;
    };
    validateModuleLoadWindowAgainstPrg(loaded.program, prg_file.prg.load_address, prg_file.prg.payload.len) catch |err| {
        try renderLowerError(parsed.input, err, stderr);
        return err;
    };
    const labels_text = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, labels_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(labels_text);
    validateMemoryPlacementsAgainstPrg(allocator, loaded.program, labels_text, prg_file.prg.load_address, prg_file.prg.payload.len) catch |err| {
        try renderLowerError(parsed.input, err, stderr);
        return err;
    };
    const map_path = try std.fmt.allocPrint(allocator, "{s}.zpmap.json", .{parsed.output});
    defer allocator.free(map_path);
    const map_json = try tass64.emitProgramMapJson(allocator, loaded.program, asm_text, labels_text, parsed.output, prg_file.prg.load_address, prg_file.bytes.len);
    defer allocator.free(map_json);
    try writeFile(map_path, map_json);

    if (loaded.program.zeropage_module != null) {
        tass64.validateModuleLoaderRequirements(allocator, loaded.program, asm_text, labels_text, prg_file.prg.load_address, prg_file.bytes.len) catch |err| {
            try renderLowerError(parsed.input, err, stderr);
            return err;
        };

        const module_path = try std.fmt.allocPrint(allocator, "{s}.zpmod.json", .{parsed.output});
        defer allocator.free(module_path);
        const module_json = try tass64.emitModuleMetadataJson(allocator, loaded.program, asm_text, labels_text, parsed.output, prg_file.prg.load_address, prg_file.bytes.len);
        defer allocator.free(module_json);
        try writeFile(module_path, module_json);

        const module_binary_path = try std.fmt.allocPrint(allocator, "{s}.zpmod", .{parsed.output});
        defer allocator.free(module_binary_path);
        const module_binary = try tass64.emitModuleBinary(allocator, loaded.program, asm_text, labels_text, prg_file.prg.load_address, prg_file.bytes);
        defer allocator.free(module_binary);
        try writeFile(module_binary_path, module_binary);

        if (loaded.program.zeropage_options.modules) |modules| if (modules.disk_manifest != null) {
            const disk_manifest_path = try std.fmt.allocPrint(allocator, "{s}.zpmod.diskmanifest.json", .{parsed.output});
            defer allocator.free(disk_manifest_path);
            const disk_manifest_json = try tass64.emitModuleDiskManifestJson(allocator, loaded.program);
            defer allocator.free(disk_manifest_json);
            try writeFile(disk_manifest_path, disk_manifest_json);
        };

        if (loaded.program.zeropage_options.modules) |modules| if (modules.disk_staging) |staging| {
            const disk_payload_path = try std.fmt.allocPrint(allocator, "{s}.zpmod.disk.prg", .{parsed.output});
            defer allocator.free(disk_payload_path);
            const disk_payload = try moduleDiskPayloadPrg(allocator, module_binary, staging.addr);
            defer allocator.free(disk_payload);
            try writeFile(disk_payload_path, disk_payload);
        };

        if (loaded.program.zeropage_options.modules != null) {
            const relocation_sim_path = try std.fmt.allocPrint(allocator, "{s}.zpmod.relocsim.json", .{parsed.output});
            defer allocator.free(relocation_sim_path);
            const relocation_sim_json = try tass64.emitModuleRelocationSimulationJson(allocator, loaded.program, asm_text, labels_text, prg_file.prg.load_address, prg_file.bytes);
            defer allocator.free(relocation_sim_json);
            try writeFile(relocation_sim_path, relocation_sim_json);
        }
    }

    try stdout.print("wrote {s} load=${x:0>4} bytes={d}\n", .{ parsed.output, prg_file.prg.load_address, prg_file.bytes.len });
}

fn moduleDiskPayloadPrg(allocator: std.mem.Allocator, module_binary: []const u8, load_addr: u16) ![]u8 {
    if (module_binary.len < 38) return error.InvalidZeroPageModuleBinary;
    const payload_offset: usize = @intCast(readLe32(module_binary, 30));
    const payload_len: usize = @intCast(readLe32(module_binary, 34));
    if (payload_offset > module_binary.len or payload_len > module_binary.len - payload_offset) return error.InvalidZeroPageModuleBinary;
    var out = try std.ArrayList(u8).initCapacity(allocator, payload_len + 2);
    errdefer out.deinit(allocator);
    try out.append(allocator, @as(u8, @truncate(load_addr)));
    try out.append(allocator, @as(u8, @truncate(load_addr >> 8)));
    try out.appendSlice(allocator, module_binary[payload_offset .. payload_offset + payload_len]);
    return try out.toOwnedSlice(allocator);
}

fn readLe32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn commandRunVicePlan(allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype) !void {
    const parsed = try parseInputOutput(args, "build/zeropage_vice_plan.yaml");
    const yaml = try vice_plan.emitBorderPlan(allocator, parsed.input);
    defer allocator.free(yaml);
    try writeFile(parsed.output, yaml);
    try stdout.print("wrote VICE harness plan {s}\n", .{parsed.output});
}

fn validateHeapRegionsAgainstPrg(program: ast.Program, load_address: u16, payload_len: usize) !void {
    const prg_start = load_address;
    const prg_end = @as(u32, load_address) + @as(u32, @intCast(payload_len));
    for (program.zeropage_options.heaps) |heap| {
        const heap_end = @as(u32, heap.addr) + @as(u32, heap.size);
        if (rangesOverlap(heap.addr, heap_end, prg_start, prg_end)) return error.InvalidZeroPageHeapRegion;
    }
}

fn validateModuleLoadWindowAgainstPrg(program: ast.Program, load_address: u16, payload_len: usize) !void {
    const modules = program.zeropage_options.modules orelse return;
    const prg_start = load_address;
    const prg_end = @as(u32, load_address) + @as(u32, @intCast(payload_len));
    const window_end = @as(u32, modules.load_window.addr) + @as(u32, modules.load_window.size);
    if (rangesOverlap(modules.load_window.addr, window_end, prg_start, prg_end)) return error.InvalidZeroPageModuleLoadWindow;
    for (modules.extra_load_windows) |entry| {
        const extra_end = @as(u32, entry.window.addr) + entry.window.size;
        if (rangesOverlap(entry.window.addr, extra_end, prg_start, prg_end)) return error.InvalidZeroPageModuleLoadWindow;
    }
    if (modules.disk_staging) |staging| {
        const staging_end = @as(u32, staging.addr) + @as(u32, staging.size);
        if (rangesOverlap(staging.addr, staging_end, prg_start, prg_end)) return error.InvalidZeroPageModuleLoadWindow;
    }
}

fn validateMemoryPlacementsAgainstPrg(allocator: std.mem.Allocator, program: ast.Program, labels_text: []const u8, load_address: u16, payload_len: usize) !void {
    const prg_end = @as(u32, load_address) + @as(u32, @intCast(payload_len));
    if (program.zeropage_options.stack) |stack| {
        if (stack.region_name != null) {
            const stack_end = @as(u32, stack.base) + stack.size;
            if (rangesOverlap(stack.base, stack_end, load_address, prg_end)) return error.InvalidZeroPageStackRegion;
        }
    }
    for (program.zeropage_options.memory.placements) |placement| {
        const region = program.findMemoryRegion(placement.region_name) orelse return error.UnknownZeroPageMemoryRegion;
        const load_start = try placementLabelAddress(allocator, labels_text, placement.name, "load_start");
        const load_end = try placementLabelAddress(allocator, labels_text, placement.name, "load_end");
        const run_start = try placementLabelAddress(allocator, labels_text, placement.name, "run_start");
        const run_end = try placementLabelAddress(allocator, labels_text, placement.name, "run_end");
        if (@as(u32, run_start) != region.addr or run_end < run_start or load_end < load_start) return error.InvalidZeroPageMemoryPlacement;
        const run_size = @as(u32, run_end) - run_start;
        const load_size = @as(u32, load_end) - load_start;
        if (run_size == 0 or run_size > region.size or run_size != load_size) return error.InvalidZeroPageMemoryPlacement;
        switch (placement.load) {
            .direct => if (load_start != run_start or load_end != run_end) return error.InvalidZeroPageMemoryPlacement,
            .startup_copy => {
                if (load_start < load_address or @as(u32, load_end) > prg_end) return error.InvalidZeroPageMemoryPlacement;
                const run_region_end = @as(u32, run_start) + run_size;
                if (rangesOverlap(run_start, run_region_end, load_address, prg_end)) return error.InvalidZeroPageMemoryPlacement;
            },
        }
    }
}

fn placementLabelAddress(allocator: std.mem.Allocator, labels_text: []const u8, placement_name: []const u8, suffix: []const u8) !u16 {
    const wanted = try std.fmt.allocPrint(allocator, "zeropage_placement_{s}_{s}", .{ placement_name, suffix });
    defer allocator.free(wanted);
    var lines = std.mem.splitScalar(u8, labels_text, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeAny(u8, line, " \t\r");
        const kind = parts.next() orelse continue;
        if (!std.mem.eql(u8, kind, "al")) continue;
        const address = parts.next() orelse continue;
        const raw_name = parts.next() orelse continue;
        const name = if (std.mem.startsWith(u8, raw_name, ".")) raw_name[1..] else raw_name;
        if (std.mem.eql(u8, name, wanted)) return std.fmt.parseInt(u16, address, 16);
    }
    return error.InvalidZeroPageMemoryPlacement;
}

fn commandExplain(args: []const []const u8, stdout: anytype) !void {
    if (args.len == 0) {
        try stdout.writeAll("feature names: tools, parser, modules, vice\n");
        return;
    }
    if (std.mem.eql(u8, args[0], "tools")) {
        try stdout.writeAll("Tools resolve from env vars, ../zeropage-tooling, then PATH.\n");
    } else if (std.mem.eql(u8, args[0], "parser")) {
        try stdout.writeAll("ZeroPage parses with Zig 0.16.0 first, then lowers the supported subset.\n");
    } else if (std.mem.eql(u8, args[0], "modules")) {
        try stdout.writeAll("Module ids, signatures, ordinals, windows, and relocations are resolved at compile time; the C64 runtime performs no reflection.\n");
    } else if (std.mem.eql(u8, args[0], "vice")) {
        try stdout.writeAll("VICE integration is optional and uses generated YAML plans plus the external vice_tasks_dotnet harness.\n");
    } else {
        try stdout.print("no explanation for feature: {s}\n", .{args[0]});
    }
}

fn commandTools(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map, stdout: anytype) !void {
    try printTool(allocator, io, env_map, stdout, .zig);
    try printTool(allocator, io, env_map, stdout, .tass64);
    try printTool(allocator, io, env_map, stdout, .vice_x64sc);
}

fn printTool(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map, stdout: anytype, name: tooling.ToolName) !void {
    const resolved = try tooling.resolve(allocator, io, env_map, name);
    defer if (resolved) |tool| tooling.freeResolved(allocator, tool);
    if (resolved) |tool| {
        try stdout.print("{s}: {s} ({s})\n", .{ name.executableName(), tool.path, tooling.describe(tool) });
    } else {
        try stdout.print("{s}: missing\n", .{name.executableName()});
    }
}

const InputOutput = struct {
    input: []const u8,
    output: []const u8,
};

const DependencySidecarSet = struct {
    modules: []tass64.DependencyModule = &.{},

    fn deinit(self: *DependencySidecarSet, allocator: std.mem.Allocator) void {
        for (self.modules) |module| module.deinit(allocator);
        allocator.free(self.modules);
    }
};

const DependencySidecarSpec = struct {
    id: []const u8,
    path: []const u8,
};

fn loadDependencySidecarsFromArgs(allocator: std.mem.Allocator, args: []const []const u8) !DependencySidecarSet {
    var module_specs: std.ArrayList(DependencySidecarSpec) = .empty;
    defer module_specs.deinit(allocator);
    var reloc_specs: std.ArrayList(DependencySidecarSpec) = .empty;
    defer reloc_specs.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dependency-module") or std.mem.eql(u8, args[i], "--dependency-relocsim")) {
            const is_module = std.mem.eql(u8, args[i], "--dependency-module");
            i += 1;
            if (i >= args.len) return error.MissingDependencySidecar;
            const spec = try parseDependencySidecarSpec(args[i]);
            if (is_module) {
                try module_specs.append(allocator, spec);
            } else {
                try reloc_specs.append(allocator, spec);
            }
        }
    }

    if (module_specs.items.len == 0 and reloc_specs.items.len == 0) return .{};
    if (module_specs.items.len != reloc_specs.items.len) return error.MissingDependencySidecar;

    var modules: std.ArrayList(tass64.DependencyModule) = .empty;
    errdefer {
        for (modules.items) |module| module.deinit(allocator);
        modules.deinit(allocator);
    }

    for (module_specs.items) |module_spec| {
        const reloc_spec = findDependencySidecarSpec(reloc_specs.items, module_spec.id) orelse return error.MissingDependencySidecar;
        const metadata_bytes = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, module_spec.path, allocator, .limited(1024 * 1024));
        defer allocator.free(metadata_bytes);
        const reloc_bytes = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, reloc_spec.path, allocator, .limited(1024 * 1024));
        defer allocator.free(reloc_bytes);
        var metadata = try tass64.parseDependencyModuleJson(allocator, metadata_bytes);
        defer metadata.deinit(allocator);
        var relocsim = try tass64.parseDependencyRelocSimJson(allocator, reloc_bytes);
        defer relocsim.deinit(allocator);
        if (!std.mem.eql(u8, module_spec.id, metadata.id) or !std.mem.eql(u8, module_spec.id, relocsim.id)) return error.InvalidZeroPageDependencySidecar;
        try modules.append(allocator, try tass64.mergeDependencySidecars(allocator, metadata, relocsim));
    }
    return .{ .modules = try modules.toOwnedSlice(allocator) };
}

fn parseDependencySidecarSpec(spec: []const u8) !DependencySidecarSpec {
    const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.InvalidDependencySidecarArg;
    if (eq == 0 or eq + 1 >= spec.len) return error.InvalidDependencySidecarArg;
    return .{ .id = spec[0..eq], .path = spec[eq + 1 ..] };
}

fn findDependencySidecarSpec(specs: []const DependencySidecarSpec, id: []const u8) ?DependencySidecarSpec {
    for (specs) |spec| {
        if (std.mem.eql(u8, spec.id, id)) return spec;
    }
    return null;
}

fn parseInputOutput(args: []const []const u8, default_output: []const u8) !InputOutput {
    if (args.len == 0) return error.MissingInput;
    var input: ?[]const u8 = null;
    var output: []const u8 = default_output;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o")) {
            i += 1;
            if (i >= args.len) return error.MissingOutput;
            output = args[i];
        } else if (std.mem.eql(u8, args[i], "--dependency-module") or std.mem.eql(u8, args[i], "--dependency-relocsim")) {
            i += 1;
            if (i >= args.len) return error.MissingDependencySidecar;
        } else if (input == null) {
            input = args[i];
        } else {
            return error.UnexpectedArgument;
        }
    }

    return .{ .input = input orelse return error.MissingInput, .output = output };
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const io = std.Options.debug_io;
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn runChild(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.stdout.len > 0) std.debug.print("{s}", .{result.stdout});
    if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ChildFailed,
        else => return error.ChildFailed,
    }
}

test "help lists implemented commands" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try printHelp(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "zp64c compile") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "input.zp64") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "zp64c run-vice") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "input.prg") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "zp64c test") == null);
}

test "parse input and output" {
    const parsed = try parseInputOutput(&.{ "examples/border.zp64", "-o", "build/border.asm" }, "build/out.asm");
    try std.testing.expectEqualStrings("examples/border.zp64", parsed.input);
    try std.testing.expectEqualStrings("build/border.asm", parsed.output);
}

test "local zeropage imports lower as prefixed module functions" {
    const src = try source.load(std.testing.allocator, "tests/fixtures/pass/module_main.zp64");
    defer src.deinit(std.testing.allocator);

    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const asm_text = try lowerSourceToAsm(std.testing.allocator, src.path, src.bytes, &stderr.writer);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_inline_begin function=math_add8") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_inline_end function=math_add8") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=function:math_add8 kind=static_frame lifetime=static address=near") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "math_isEqual8") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "MODULE OK") == null);
}

test "local ZeroPage imports lower as prefixed module functions" {
    const src = try source.load(std.testing.allocator, "tests/fixtures/pass/module_main_zp64.zp64");
    defer src.deinit(std.testing.allocator);

    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const asm_text = try lowerSourceToAsm(std.testing.allocator, src.path, src.bytes, &stderr.writer);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_inline_begin function=math_add8") != null);
}

test "local imports preserve source module rodata owners" {
    const src = try source.load(std.testing.allocator, "tests/fixtures/pass/module_rodata_main.zp64");
    defer src.deinit(std.testing.allocator);

    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const asm_text = try lowerSourceToAsm(std.testing.allocator, src.path, src.bytes, &stderr.writer);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=module:assets kind=rodata lifetime=static address=near") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=module:main kind=rodata lifetime=static address=near") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_str_assets_title:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_arr_assets_table:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_str_title:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_arr_table:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "owner=module:flattened") == null);
}

test "static ZeroPage options are assembly-neutral" {
    const without_options =
        \\fn helper(value: u8) u8 {
        \\    return value + 1;
        \\}
        \\export fn main() void {
        \\    var x: u8 = helper(6);
        \\    _ = x;
        \\    _ = helper(7);
        \\}
    ;
    const with_options =
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{
        \\        .default_frame = .static,
        \\        .functions = .{
        \\            .helper = .{ .frame = .static },
        \\            .main = .{ .frame = .static },
        \\        },
        \\    },
        \\};
        \\fn helper(value: u8) u8 {
        \\    return value + 1;
        \\}
        \\export fn main() void {
        \\    var x: u8 = helper(6);
        \\    _ = x;
        \\    _ = helper(7);
        \\}
    ;
    var stderr_without: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_without.deinit();
    var stderr_with: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_with.deinit();

    const asm_without = try lowerSourceToAsm(std.testing.allocator, "tests/fixtures/pass/no_options.zp64", without_options, &stderr_without.writer);
    defer std.testing.allocator.free(asm_without);
    const asm_with = try lowerSourceToAsm(std.testing.allocator, "tests/fixtures/pass/static_options.zp64", with_options, &stderr_with.writer);
    defer std.testing.allocator.free(asm_with);

    try std.testing.expectEqualStrings(asm_without, asm_with);
}

test "ZeroPage options validate emitted function labels and reserved frame policies" {
    var unknown_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer unknown_stderr.deinit();
    try std.testing.expectError(error.UnknownZeroPageOptionsFunction, lowerSourceToAsm(std.testing.allocator, "tests/fixtures/fail/options_unknown.zp64",
        \\pub const zeropage_options = .{
        \\    .abi = .{ .functions = .{ .missing = .{ .frame = .static } } },
        \\};
        \\export fn main() void {}
    , &unknown_stderr.writer));
    try std.testing.expect(std.mem.indexOf(u8, unknown_stderr.written(), "unknown zeropage_options function override") != null);

    var stack_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stack_stderr.deinit();
    const recursive_asm = try lowerSourceToAsm(std.testing.allocator, "tests/fixtures/fail/options_stack.zp64",
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .default_frame = .stack },
        \\};
        \\fn helper(value: u8) u8 {
        \\    if (value == 0) {
        \\        return 5;
        \\    }
        \\    return helper(value - 1);
        \\}
        \\export fn main() void { _ = helper(3); }
    , &stack_stderr.writer);
    defer std.testing.allocator.free(recursive_asm);
    try std.testing.expect(std.mem.indexOf(u8, recursive_asm, "jsr helper") != null);
    try std.testing.expect(std.mem.indexOf(u8, recursive_asm, "zeropage_stack_overflow_trap") != null);
    try std.testing.expectEqual(@as(usize, 0), stack_stderr.written().len);
}

test "ZeroPage options can target imported prefixed function labels" {
    const src = try source.load(std.testing.allocator, "tests/fixtures/pass/zeropage_options_prefixed_import_main.zp64");
    defer src.deinit(std.testing.allocator);

    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const asm_text = try lowerSourceToAsm(std.testing.allocator, src.path, src.bytes, &stderr.writer);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr math_add8") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.written().len);
}

test "ZeroPage options can make imported prefixed helpers stack callees" {
    const src = try source.load(std.testing.allocator, "tests/fixtures/pass/zeropage_options_prefixed_import_stack_main.zp64");
    defer src.deinit(std.testing.allocator);

    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const asm_text = try lowerSourceToAsm(std.testing.allocator, src.path, src.bytes, &stderr.writer);
    defer std.testing.allocator.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_stack_sp = $f7") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr math_add8") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=function:math_add8 kind=code lifetime=static address=near") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "; zeropage_section_begin owner=function:math_add8 kind=static_frame") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr.written().len);
}

test "imported ZeroPage options are rejected until module descriptors land" {
    const src = try source.load(std.testing.allocator, "tests/fixtures/pass/zeropage_options_import_main.zp64");
    defer src.deinit(std.testing.allocator);

    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectError(error.UnsupportedImportedZeroPageOptions, lowerSourceToAsm(std.testing.allocator, src.path, src.bytes, &stderr.writer));
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "unsupported imported zeropage_options metadata") != null);
}

test "small demos lower to expected assembly features" {
    const Case = struct {
        path: []const u8,
        expected: []const []const u8,
    };
    const cases = [_]Case{
        .{ .path = "examples/small/01_border.zp64", .expected = &.{"sta $d020"} },
        .{ .path = "examples/small/02_flow.zp64", .expected = &.{ "while_0_top", "if_1_then", "hexNibbleToScreen" } },
        .{ .path = "examples/small/03_functions.zp64", .expected = &.{ "jsr add8", "jsr paintStatus", "hexNibbleToScreen" } },
        .{ .path = "examples/small/04_types.zp64", .expected = &.{ "main_signed_step", "main_signed_base", "main_screen_ptr", "hexNibbleToScreen" } },
        .{ .path = "examples/small/05_struct_fields.zp64", .expected = &.{ "main_marker_x", "main_marker_y", "jsr drawMarker", "hexNibbleToScreen" } },
        .{ .path = "examples/small/06_module_main.zp64", .expected = &.{ "jsr math_add8", "jsr math_isEqual8", "hexNibbleToScreen" } },
        .{ .path = "examples/small/07_loop_control.zp64", .expected = &.{ "jmp while_0_top", "jmp while_0_done", "hexNibbleToScreen" } },
        .{ .path = "examples/small/08_assignment_math.zp64", .expected = &.{ "jsr sub8", "sbc zeropage_math_tmp", "hexNibbleToScreen" } },
        .{ .path = "examples/small/09_console_scroll.zp64", .expected = &.{ "consoleScroll", "consolePutHexByte", "sleepTicks", "$dc04" } },
        .{ .path = "examples/small/10_inline_asm.zp64", .expected = &.{ "zeropage_asm_0_loop", "jsr $ffd2", "sta $d020" } },
        .{ .path = "examples/small/11_strings_petscii.zp64", .expected = &.{ "zeropage_str_greeting", "consolePutString", "kernalPutString", "jsr $ffbd" } },
        .{ .path = "examples/small/12_mutable_strings.zp64", .expected = &.{ "main_msg_len", "main_msg_data", "stringAppend", "ldx #<main_msg_data" } },
        .{ .path = "examples/small/13_string_controls.zp64", .expected = &.{ "zeropage_str_title", "$93,$13", "$41", "stringAppend" } },
        .{ .path = "examples/small/14_keyboard_input.zp64", .expected = &.{ "jsr $ffe4", "keyboardWaitPetscii", "zeropage_keyboard_key", "sta $d020" } },
        .{ .path = "examples/small/15_array_lookup.zp64", .expected = &.{ "zeropage_arr_lookup_table", "main_values", "main_words", "consolePutHexByte" } },
        .{ .path = "examples/small/16_inline_asm_strings.zp64", .expected = &.{ "zeropage_str_source", "sta main_msg_data,y", "sta main_msg_len", "cpy #14" } },
        .{ .path = "examples/small/17_for_array_loop.zp64", .expected = &.{ "for_0_top", "for_1_top", "zeropage_arr_lookup_table", "consolePutHexByte" } },
        .{ .path = "examples/small/18_switch_dispatch.zp64", .expected = &.{ "switch_0_case", "switch_expr_", "zeropage_switch_value", "consolePutHexByte" } },
        .{ .path = "examples/small/19_enum_struct_game.zp64", .expected = &.{ "main_game_board_cells", "main_game_history", "keyboardWaitPetscii", "switch_" } },
        .{ .path = "examples/small/20_struct_value_helpers.zp64", .expected = &.{ "newGame", "boardScore", "main_snapshot_board_cells", "consolePutHexByte" } },
        .{ .path = "examples/small/21_pointer_mmio.zp64", .expected = &.{ "zeropage_ptr_tmp", "sta (zeropage_ptr_tmp),y", "main_local_ptr", "consolePutHexByte" } },
        .{ .path = "examples/small/22_pointer_indexing.zp64", .expected = &.{ "zeropage_arr_message", "sta (zeropage_ptr_tmp),y", "main_value_ptr", "for_0_top" } },
        .{ .path = "examples/small/23_as_casts.zp64", .expected = &.{ "zeropage_arr_table", "sta (zeropage_ptr_tmp),y", "switch_", "main_values" } },
        .{ .path = "examples/small/24_optional_union_event.zp64", .expected = &.{ "switch_", "zeropage_optional_tmp", "zeropage_union_switch_payload", "consolePutHexByte" } },
        .{ .path = "examples/small/25_struct_array_table.zp64", .expected = &.{ "zeropage_arr_table", "main_rows", "tableValue", "consolePutHexByte" } },
        .{ .path = "examples/small/26_static_abi_metadata.zp64", .expected = &.{ "jsr helper", "consolePutString", "sta $d020" } },
        .{ .path = "examples/small/27_stack_main_border.zp64", .expected = &.{ "zeropage_stack_sp = $f7", "zeropage_stack_fp = $f9", "sta (zeropage_stack_fp),y", "sta $d020" } },
        .{ .path = "examples/small/28_static_calls_stack_helper.zp64", .expected = &.{ "zeropage_stack_sp = $f7", "zeropage_stack_fp = $f9", "jsr borderFrom", "sty zeropage_stack_sp+1", "sta $d020" } },
        .{ .path = "examples/small/29_module_rodata_assets.zp64", .expected = &.{ "owner=module:assets", "zeropage_str_assets_title", "zeropage_arr_assets_values", "consolePutString", "sta $d020" } },
        .{ .path = "examples/small/30_stack_main_calls_static_helper.zp64", .expected = &.{ "zeropage_stack_sp = $f7", "zeropage_stack_fp = $f9", "sta borderFrom_a", "sta (zeropage_stack_sp),y", "jsr borderFrom", "sta zeropage_stack_ret_lo", "lda (zeropage_stack_sp),y", "sta $d020" } },
        .{ .path = "examples/small/31_stack_calls_stack_helper.zp64", .expected = &.{ "zeropage_stack_sp = $f7", "zeropage_stack_fp = $f9", "sta (zeropage_stack_sp),y", "jsr borderFrom\n    pha", "lda (zeropage_stack_sp),y", "sta $d020" } },
        .{ .path = "examples/small/32_stack_recursive_border.zp64", .expected = &.{ "zeropage_stack_sp = $f7", "zeropage_stack_fp = $f9", "zeropage_stack_guard_", "jsr borderFrom", "zeropage_stack_overflow_trap", "sta $d020" } },
        .{ .path = "examples/small/33_reu_copy_smoke.zp64", .expected = &.{ "jsr zeropage_reu_present", "jsr zeropage_reu_copy_c64_to_reu", "jsr zeropage_reu_copy_reu_to_c64", "jsr zeropage_reu_compare", "sta $df01", "sta $d020" } },
        .{ .path = "examples/small/34_near_heap_arena.zp64", .expected = &.{ "jsr zeropage_heap_near_heap_alloc_bytes", "jsr zeropage_heap_near_heap_reset", "zeropage_heap_near_heap_cursor", "owner=runtime kind=code", "owner=runtime kind=data", "sta $d020" } },
        .{ .path = "examples/small/35_fixed_heap_blocks.zp64", .expected = &.{ "jsr zeropage_heap_sprites_alloc_bytes", "jsr zeropage_heap_sprites_free", "jsr zeropage_heap_sprites_reset", "zeropage_heap_sprites_free_head", "owner=runtime kind=code", "owner=runtime kind=data", "sta $d020" } },
        .{ .path = "examples/small/36_far_reu_arena.zp64", .expected = &.{ "jsr zeropage_reu_heap_assets_alloc_bytes", "jsr zeropage_reu_copy_c64_to_reu", "jsr zeropage_reu_copy_reu_to_c64", "zeropage_reu_heap_assets_cursor", "owner=runtime kind=code", "owner=runtime kind=data", "sta $df01", "sta $d020" } },
        .{ .path = "examples/small/37_far_reu_struct_view.zp64", .expected = &.{ "jsr zeropage_reu_heap_assets_alloc_bytes", "zeropage_reu_view_record", "zeropage_reu_view_offset", "jsr zeropage_reu_copy_c64_to_reu", "jsr zeropage_reu_copy_reu_to_c64", "owner=runtime kind=code", "owner=runtime kind=data", "sta $d020" } },
        .{ .path = "examples/small/38_far_reu_materialize_flush.zp64", .expected = &.{ "jsr zeropage_heap_near_heap_alloc_bytes", "jsr zeropage_reu_copy_reu_to_c64", "sta (zeropage_ptr_tmp),y", "jsr zeropage_reu_copy_c64_to_reu", "zeropage_heap_near_heap_cursor", "owner=runtime kind=code", "owner=runtime kind=data", "sta $d020" } },
        .{ .path = "examples/small/39_far_reu_materialize_range.zp64", .expected = &.{ "jsr zeropage_heap_near_heap_alloc_bytes", "zeropage_reu_view_offset", "jsr zeropage_stride_mul_4", "jsr zeropage_reu_copy_reu_to_c64", "sta (zeropage_ptr_tmp),y", "jsr zeropage_reu_copy_c64_to_reu", "owner=runtime kind=code", "owner=runtime kind=data", "sta $d020" } },
        .{ .path = "examples/small/40_module_metadata.zp64", .expected = &.{ "zeropage_stack_sp = $f7", "; zeropage_section_begin owner=function:tick kind=code", "consolePutChar", "sta $d020" } },
        .{ .path = "examples/small/41_module_binary.zp64", .expected = &.{ "zeropage_stack_sp = $f7", "; zeropage_section_begin owner=function:tick kind=code", "consolePutChar", "sta $d020" } },
        .{ .path = "examples/small/42_module_ordinals_relocs.zp64", .expected = &.{ "zeropage_stack_sp = $f7", "; zeropage_section_begin owner=function:tick kind=code", "; zeropage_section_begin owner=function:bump kind=code", "zeropage_module_reloc_", "; zeropage_relocation kind=abs16", "jsr bump", "sta $d020" } },
        .{ .path = "examples/small/43_module_rodata_relocs.zp64", .expected = &.{ "zeropage_stack_sp = $f7", "; zeropage_section_begin owner=function:tablePtr kind=code", "; zeropage_relocation kind=hi8", "; zeropage_relocation kind=lo8", "target=zeropage_arr_reloc_table", "ldx #>zeropage_arr_reloc_table+1", "lda #<zeropage_arr_reloc_table+1", "sta $d020" } },
        .{ .path = "examples/small/44_module_loader_window.zp64", .expected = &.{ "zeropage_stack_sp = $f7", "; zeropage_section_begin owner=function:tick kind=code", "consolePutChar", "sta $d020" } },
        .{ .path = "examples/small/45_module_relocation_sim.zp64", .expected = &.{ "zeropage_stack_sp = $f7", "; zeropage_section_begin owner=function:tick kind=code", "; zeropage_section_begin owner=function:tablePtr kind=code", "; zeropage_section_begin owner=function:bump kind=code", "; zeropage_relocation kind=abs16", "; zeropage_relocation kind=hi8", "; zeropage_relocation kind=lo8", "sta $d020" } },
        .{ .path = "examples/small/46_module_runtime_load_window.zp64", .expected = &.{ "jsr zeropage_module_load_current", "zeropage_module_payload_range_start", "zeropage_module_load_current:", "zeropage_module_registry_loaded", "zeropage_module_load_current_not_loaded", "jsr zeropage_reu_copy_c64_to_reu", "jsr zeropage_reu_copy_reu_to_c64", "zeropage_module_payload_jump_table", "sta $d020" } },
        .{ .path = "examples/small/47_module_registry_state.zp64", .expected = &.{ "jsr zeropage_module_is_loaded_current", "jsr zeropage_module_load_current", "zeropage_module_registry_loaded", "zeropage_module_registry_refcount", "zeropage_module_load_current_not_loaded", "zeropage_module_payload_jump_table", "sta $d020" } },
        .{ .path = "examples/small/48_module_unload_state.zp64", .expected = &.{ "jsr zeropage_module_load_current", "jsr zeropage_module_unload_current", "zeropage_module_unload_current:", "sta zeropage_module_registry_loaded", "sta zeropage_module_registry_refcount", "zeropage_module_payload_jump_table", "sta $d020" } },
        .{ .path = "examples/small/49_module_dynamic_call.zp64", .expected = &.{ "jsr zeropage_module_load_current", "lda zeropage_module_registry_loaded", "jsr zeropage_module_registry_jump_table+0", "module_call_", "zeropage_module_payload_jump_table", "sta $d020" } },
        .{ .path = "examples/small/50_module_disk_load.zp64", .expected = &.{ "jsr zeropage_module_load_from_disk_current", "jsr $ffbd", "jsr $ffba", "jsr $ffd5", "zeropage_module_disk_filename", "jsr zeropage_module_registry_jump_table+0", "sta $d020" } },
        .{ .path = "examples/small/51_module_disk_load_real.zp64", .expected = &.{ "jsr zeropage_module_load_from_disk_current", "jsr $ffbd", "jsr $ffba", "jsr $ffd5", "zeropage_module_disk_filename", "jsr zeropage_module_registry_jump_table+0", "sta $d020" } },
        .{ .path = "examples/small/52_module_preload_policy.zp64", .expected = &.{ "zeropage_module_preload_start:", "jsr zeropage_module_load_from_disk_current", "main:", "jsr $ffbd", "jsr $ffba", "jsr $ffd5", "zeropage_module_disk_filename", "jsr zeropage_module_registry_jump_table+0", "sta $d020" } },
        .{ .path = "examples/small/53_module_on_demand_policy.zp64", .expected = &.{ "lda zeropage_module_registry_loaded", "jsr zeropage_module_load_from_disk_current", "jsr $ffbd", "jsr $ffba", "jsr $ffd5", "zeropage_module_disk_filename", "jsr zeropage_module_registry_jump_table+0", "sta $d020" } },
        .{ .path = "examples/small/54_module_dependency_metadata.zp64", .expected = &.{ "zeropage_stack_sp = $f7", "; zeropage_section_begin owner=function:tick kind=code", "consolePutChar", "sta $d020" } },
        .{ .path = "examples/small/55_module_registry_plan.zp64", .expected = &.{ "zeropage_stack_sp = $f7", "; zeropage_section_begin owner=function:tick kind=code", "consolePutChar", "sta $d020" } },
        .{ .path = "examples/small/56_module_disk_reload_matrix.zp64", .expected = &.{ "jsr zeropage_module_load_from_disk_current", "jsr zeropage_module_unload_current", "jsr zeropage_module_is_loaded_current", "jsr $ffd5", "jsr zeropage_module_registry_jump_table+0", "zeropage_module_disk_filename", "sta $d020" } },
        .{ .path = "examples/small/57_module_disk_manifest.zp64", .expected = &.{ "zeropage_stack_sp = $f7", "; zeropage_section_begin owner=function:tick kind=code", "consolePutChar", "sta $d020" } },
        .{ .path = "examples/small/58_module_registry_rows.zp64", .expected = &.{ "zeropage_module_registry_capacity = 3", "zeropage_module_registry_row1_reu_cache = $030800", "zeropage_module_registry_row2_reu_cache = $031000", "lda zeropage_module_registry_row1_loaded", "lda zeropage_module_registry_row2_loaded", "sta $d020" } },
        .{ .path = "examples/small/59_module_dependency_disk_load.zp64", .expected = &.{ "jsr zeropage_module_load_dependency_row1", "jsr zeropage_module_load_dependency_row2", "zeropage_module_dependency_row1_filename", "zeropage_module_dependency_row2_filename", "zeropage_module_registry_row1_reu_cache = $030800", "zeropage_module_registry_row2_reu_cache = $031000", "jsr zeropage_reu_copy_c64_to_reu", "sta zeropage_module_registry_row1_loaded", "sta zeropage_module_registry_row2_loaded", "sta $d020" } },
        .{ .path = "examples/small/64_module_typed_current_binding.zp64", .expected = &.{ "jsr zeropage_module_load_current", "jsr zeropage_module_unload_current", "jsr zeropage_module_load_from_disk_current", "jsr zeropage_module_registry_jump_table+0", "zeropage_module_disk_filename", "sta $d020" } },
        .{ .path = "examples/small/65_module_state_metadata.zp64", .expected = &.{ "tick:", "owner=function:tick", "sta $d020" } },
        .{ .path = "examples/small/66_module_state_runtime.zp64", .expected = &.{ "zeropage_module_state_current_snapshot_reu = $030800", "zeropage_module_state_current_saved", "zeropage_module_state_save_current", "zeropage_module_state_restore_current", "jsr zeropage_module_state_save_current", "jsr zeropage_module_state_restore_current", "sta $d020" } },
        .{ .path = "examples/small/67_module_dependency_state_metadata.zp64", .expected = &.{ "tick:", "owner=function:tick", "consolePutChar", "sta $d020" } },
        .{ .path = "examples/small/72_module_dependency_graph_metadata.zp64", .expected = &.{ "tick:", "owner=function:tick", "consolePutChar", "sta $d020" } },
        .{ .path = "examples/small/80_module_graph_node_sidecars.zp64", .expected = &.{ "tick:", "owner=function:tick", "consolePutChar", "sta $d020" } },
        .{ .path = "examples/small/83_module_multi_window_metadata.zp64", .expected = &.{ "tick:", "owner=function:tick", "consolePutChar", "sta $d020" } },
        .{ .path = "examples/small/89_module_kernal_bank_metadata.zp64", .expected = &.{ "tick:", "owner=function:tick", "consolePutChar", "sta $d020" } },
    };

    for (cases) |case| {
        const src = try source.load(std.testing.allocator, case.path);
        defer src.deinit(std.testing.allocator);

        var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer stderr.deinit();

        const asm_text = try lowerSourceToAsm(std.testing.allocator, src.path, src.bytes, &stderr.writer);
        defer std.testing.allocator.free(asm_text);
        const old_prefix = "zig" ++ "64_";
        try std.testing.expect(std.mem.indexOf(u8, asm_text, old_prefix) == null);
        for (case.expected) |needle| {
            try std.testing.expect(std.mem.indexOf(u8, asm_text, needle) != null);
        }
    }
}

test "dependency call small demo lowers with compile-time sidecars" {
    const math_metadata_json =
        \\{
        \\  "format": "zeropage-module-metadata",
        \\  "version": 1,
        \\  "module_id": "math_core",
        \\  "abi_version": 1,
        \\  "payload": { "start": 2074, "length": 272, "jump_table_bytes": 12 },
        \\  "exports": [
        \\    { "name": "add", "ordinal": 0, "label": "add", "target_original": 2091, "frame": "stack", "frame_size": 3, "params": [{ "name": "value", "type": "u8", "offset": 0 }], "return": "u8" },
        \\    { "name": "is_five", "ordinal": 1, "label": "isFive", "target_original": 2249, "frame": "stack", "frame_size": 3, "params": [{ "name": "value", "type": "u8", "offset": 0 }], "return": "bool" },
        \\    { "name": "wide", "ordinal": 2, "label": "wide", "target_original": 2274, "frame": "stack", "frame_size": 4, "params": [{ "name": "value", "type": "u16", "offset": 0 }], "return": "u16" }
        \\  ]
        \\}
    ;
    const math_reloc_json =
        \\{
        \\  "format": "zeropage-module-relocation-sim",
        \\  "version": 1,
        \\  "module_id": "math_core",
        \\  "load_window": { "addr": 49152, "size": 2048 },
        \\  "payload_length": 272,
        \\  "applied_relocations": [
        \\    { "payload_offset": 145, "kind": "abs16", "after": [12, 192] },
        \\    { "payload_offset": 257, "kind": "hi8", "after": [193] },
        \\    { "payload_offset": 259, "kind": "lo8", "after": [13] }
        \\  ]
        \\}
    ;
    const path_metadata_json =
        \\{
        \\  "format": "zeropage-module-metadata",
        \\  "version": 1,
        \\  "module_id": "pathing",
        \\  "abi_version": 1,
        \\  "payload": { "start": 2074, "length": 20, "jump_table_bytes": 3 },
        \\  "exports": [
        \\    { "name": "step", "ordinal": 0, "label": "step", "target_original": 2074, "frame": "stack", "frame_size": 3, "params": [{ "name": "value", "type": "u8", "offset": 0 }], "return": "u8" }
        \\  ]
        \\}
    ;
    const path_reloc_json =
        \\{
        \\  "format": "zeropage-module-relocation-sim",
        \\  "version": 1,
        \\  "module_id": "pathing",
        \\  "load_window": { "addr": 49152, "size": 2048 },
        \\  "payload_length": 20,
        \\  "applied_relocations": []
        \\}
    ;
    const fixed_metadata_json =
        \\{
        \\  "format": "zeropage-module-metadata",
        \\  "version": 1,
        \\  "module_id": "fixed_math",
        \\  "abi_version": 1,
        \\  "payload": { "start": 2074, "length": 20, "jump_table_bytes": 3 },
        \\  "exports": [
        \\    { "name": "bias", "ordinal": 0, "label": "bias", "target_original": 2074, "frame": "stack", "frame_size": 3, "params": [{ "name": "value", "type": "u8", "offset": 0 }], "return": "u8" }
        \\  ]
        \\}
    ;
    const fixed_reloc_json =
        \\{
        \\  "format": "zeropage-module-relocation-sim",
        \\  "version": 1,
        \\  "module_id": "fixed_math",
        \\  "load_window": { "addr": 49152, "size": 2048 },
        \\  "payload_length": 20,
        \\  "applied_relocations": []
        \\}
    ;

    var math_metadata = try tass64.parseDependencyModuleJson(std.testing.allocator, math_metadata_json);
    defer math_metadata.deinit(std.testing.allocator);
    var math_reloc = try tass64.parseDependencyRelocSimJson(std.testing.allocator, math_reloc_json);
    defer math_reloc.deinit(std.testing.allocator);
    var path_metadata = try tass64.parseDependencyModuleJson(std.testing.allocator, path_metadata_json);
    defer path_metadata.deinit(std.testing.allocator);
    var path_reloc = try tass64.parseDependencyRelocSimJson(std.testing.allocator, path_reloc_json);
    defer path_reloc.deinit(std.testing.allocator);
    var fixed_metadata = try tass64.parseDependencyModuleJson(std.testing.allocator, fixed_metadata_json);
    defer fixed_metadata.deinit(std.testing.allocator);
    var fixed_reloc = try tass64.parseDependencyRelocSimJson(std.testing.allocator, fixed_reloc_json);
    defer fixed_reloc.deinit(std.testing.allocator);

    var modules = [_]tass64.DependencyModule{
        try tass64.mergeDependencySidecars(std.testing.allocator, math_metadata, math_reloc),
        try tass64.mergeDependencySidecars(std.testing.allocator, path_metadata, path_reloc),
        try tass64.mergeDependencySidecars(std.testing.allocator, fixed_metadata, fixed_reloc),
    };
    defer for (&modules) |*module| module.deinit(std.testing.allocator);

    const src = try source.load(std.testing.allocator, "examples/small/60_module_dependency_call.zp64");
    defer src.deinit(std.testing.allocator);
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const asm_text = try lowerSourceToAsmWithOptions(std.testing.allocator, src.path, src.bytes, &stderr.writer, .{ .dependency_modules = &modules });
    defer std.testing.allocator.free(asm_text);
    try std.testing.expectEqual(@as(usize, 0), stderr.written().len);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr zeropage_module_load_dependency_row1") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr zeropage_module_activate_dependency_row1") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr zeropage_module_activate_dependency_row2") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "jsr zeropage_module_registry_jump_table+6") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "zeropage_module_registry_active_row:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "sta $c091") != null);

    const unload_src = try source.load(std.testing.allocator, "examples/small/61_module_dependency_unload.zp64");
    defer unload_src.deinit(std.testing.allocator);
    var unload_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer unload_stderr.deinit();

    const unload_asm = try lowerSourceToAsmWithOptions(std.testing.allocator, unload_src.path, unload_src.bytes, &unload_stderr.writer, .{ .dependency_modules = &modules });
    defer std.testing.allocator.free(unload_asm);
    try std.testing.expectEqual(@as(usize, 0), unload_stderr.written().len);
    try std.testing.expect(std.mem.indexOf(u8, unload_asm, "jsr zeropage_module_unload_dependency_row1") != null);
    try std.testing.expect(std.mem.indexOf(u8, unload_asm, "zeropage_module_unload_dependency_row1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, unload_asm, "sta zeropage_module_registry_row1_loaded") != null);
    try std.testing.expect(std.mem.indexOf(u8, unload_asm, "sta zeropage_module_registry_active_row") != null);

    const typed_src = try source.load(std.testing.allocator, "examples/small/62_module_typed_dependency_call.zp64");
    defer typed_src.deinit(std.testing.allocator);
    var typed_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer typed_stderr.deinit();

    const typed_asm = try lowerSourceToAsmWithOptions(std.testing.allocator, typed_src.path, typed_src.bytes, &typed_stderr.writer, .{ .dependency_modules = &modules });
    defer std.testing.allocator.free(typed_asm);
    try std.testing.expectEqual(@as(usize, 0), typed_stderr.written().len);
    try std.testing.expect(std.mem.indexOf(u8, typed_asm, "jsr zeropage_module_load_dependency_row1") != null);
    try std.testing.expect(std.mem.indexOf(u8, typed_asm, "jsr zeropage_module_activate_dependency_row1") != null);
    try std.testing.expect(std.mem.indexOf(u8, typed_asm, "jsr zeropage_module_activate_dependency_row2") != null);
    try std.testing.expect(std.mem.indexOf(u8, typed_asm, "jsr zeropage_module_registry_jump_table+6") != null);
    try std.testing.expect(std.mem.indexOf(u8, typed_asm, "MathCore") == null);
    try std.testing.expect(std.mem.indexOf(u8, typed_asm, "Pathing") == null);

    const lifecycle_src = try source.load(std.testing.allocator, "examples/small/63_module_typed_dependency_lifecycle.zp64");
    defer lifecycle_src.deinit(std.testing.allocator);
    var lifecycle_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer lifecycle_stderr.deinit();

    const lifecycle_asm = try lowerSourceToAsmWithOptions(std.testing.allocator, lifecycle_src.path, lifecycle_src.bytes, &lifecycle_stderr.writer, .{ .dependency_modules = &modules });
    defer std.testing.allocator.free(lifecycle_asm);
    try std.testing.expectEqual(@as(usize, 0), lifecycle_stderr.written().len);
    try std.testing.expect(std.mem.indexOf(u8, lifecycle_asm, "jsr zeropage_module_load_dependency_row1") != null);
    try std.testing.expect(std.mem.indexOf(u8, lifecycle_asm, "jsr zeropage_module_unload_dependency_row1") != null);
    try std.testing.expect(std.mem.indexOf(u8, lifecycle_asm, "lda zeropage_module_registry_row1_loaded") != null);
    try std.testing.expect(std.mem.indexOf(u8, lifecycle_asm, "jsr zeropage_module_activate_dependency_row2") != null);
    try std.testing.expect(std.mem.indexOf(u8, lifecycle_asm, "MathCore") == null);
    try std.testing.expect(std.mem.indexOf(u8, lifecycle_asm, "Pathing") == null);

    const dep_state_src = try source.load(std.testing.allocator, "examples/small/68_module_dependency_state_runtime.zp64");
    defer dep_state_src.deinit(std.testing.allocator);
    var dep_state_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer dep_state_stderr.deinit();

    const dep_state_asm = try lowerSourceToAsmWithOptions(std.testing.allocator, dep_state_src.path, dep_state_src.bytes, &dep_state_stderr.writer, .{ .dependency_modules = &modules });
    defer std.testing.allocator.free(dep_state_asm);
    try std.testing.expectEqual(@as(usize, 0), dep_state_stderr.written().len);
    try std.testing.expect(std.mem.indexOf(u8, dep_state_asm, "zeropage_module_state_dep1_snapshot_reu = $032000") != null);
    try std.testing.expect(std.mem.indexOf(u8, dep_state_asm, "zeropage_module_state_dep2_snapshot_reu = $032800") != null);
    try std.testing.expect(std.mem.indexOf(u8, dep_state_asm, "zeropage_module_state_save_active_dependency") != null);
    try std.testing.expect(std.mem.indexOf(u8, dep_state_asm, "zeropage_module_state_restore_dependency_row1") != null);
    try std.testing.expect(std.mem.indexOf(u8, dep_state_asm, "zeropage_module_state_restore_dependency_row2") != null);

    const dep_preload_src = try source.load(std.testing.allocator, "examples/small/69_module_dependency_preload_policy.zp64");
    defer dep_preload_src.deinit(std.testing.allocator);
    var dep_preload_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer dep_preload_stderr.deinit();

    const dep_preload_asm = try lowerSourceToAsmWithOptions(std.testing.allocator, dep_preload_src.path, dep_preload_src.bytes, &dep_preload_stderr.writer, .{ .dependency_modules = &modules });
    defer std.testing.allocator.free(dep_preload_asm);
    try std.testing.expectEqual(@as(usize, 0), dep_preload_stderr.written().len);
    try std.testing.expect(std.mem.indexOf(u8, dep_preload_asm, "zeropage_module_dependency_preload_start:") != null);
    try std.testing.expect(std.mem.indexOf(u8, dep_preload_asm, "jsr zeropage_module_load_dependency_row1") != null);
    try std.testing.expect(std.mem.indexOf(u8, dep_preload_asm, "zeropage_module_load_dependency_row1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, dep_preload_asm, "zeropage_module_load_dependency_row2:") == null);

    const dep_on_demand_src = try source.load(std.testing.allocator, "examples/small/70_module_dependency_on_demand_policy.zp64");
    defer dep_on_demand_src.deinit(std.testing.allocator);
    var dep_on_demand_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer dep_on_demand_stderr.deinit();

    const dep_on_demand_asm = try lowerSourceToAsmWithOptions(std.testing.allocator, dep_on_demand_src.path, dep_on_demand_src.bytes, &dep_on_demand_stderr.writer, .{ .dependency_modules = &modules });
    defer std.testing.allocator.free(dep_on_demand_asm);
    try std.testing.expectEqual(@as(usize, 0), dep_on_demand_stderr.written().len);
    try std.testing.expect(std.mem.indexOf(u8, dep_on_demand_asm, "jsr zeropage_module_load_dependency_row1") != null);
    try std.testing.expect(std.mem.indexOf(u8, dep_on_demand_asm, "zeropage_module_load_dependency_row1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, dep_on_demand_asm, "jsr zeropage_module_activate_dependency_row1") != null);
    try std.testing.expect(std.mem.indexOf(u8, dep_on_demand_asm, "zeropage_module_dependency_preload_start:") == null);
    try std.testing.expect(std.mem.indexOf(u8, dep_on_demand_asm, "MathCore") == null);

    const graph_on_demand_src = try source.load(std.testing.allocator, "examples/small/74_module_dependency_graph_on_demand_policy.zp64");
    defer graph_on_demand_src.deinit(std.testing.allocator);
    var graph_on_demand_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer graph_on_demand_stderr.deinit();

    const graph_on_demand_asm = try lowerSourceToAsmWithOptions(std.testing.allocator, graph_on_demand_src.path, graph_on_demand_src.bytes, &graph_on_demand_stderr.writer, .{ .dependency_modules = &modules });
    defer std.testing.allocator.free(graph_on_demand_asm);
    try std.testing.expectEqual(@as(usize, 0), graph_on_demand_stderr.written().len);
    try std.testing.expect(std.mem.indexOf(u8, graph_on_demand_asm, "lda zeropage_module_registry_row1_loaded") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph_on_demand_asm, "jsr zeropage_module_load_dependency_row3") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph_on_demand_asm, "jsr zeropage_module_load_dependency_row1") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph_on_demand_asm, "jsr zeropage_module_unload_dependency_row3") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph_on_demand_asm, "jsr zeropage_module_activate_dependency_row1") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph_on_demand_asm, "MathCore") == null);

    const graph_preload_src = try source.load(std.testing.allocator, "examples/small/75_module_dependency_graph_preload_policy.zp64");
    defer graph_preload_src.deinit(std.testing.allocator);
    var graph_preload_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer graph_preload_stderr.deinit();

    const graph_preload_asm = try lowerSourceToAsmWithOptions(std.testing.allocator, graph_preload_src.path, graph_preload_src.bytes, &graph_preload_stderr.writer, .{ .dependency_modules = &modules });
    defer std.testing.allocator.free(graph_preload_asm);
    try std.testing.expectEqual(@as(usize, 0), graph_preload_stderr.written().len);
    try std.testing.expect(std.mem.indexOf(u8, graph_preload_asm, "zeropage_module_dependency_preload_start:") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph_preload_asm, "jsr zeropage_module_load_dependency_row3") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph_preload_asm, "jsr zeropage_module_load_dependency_row1") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph_preload_asm, "jsr zeropage_module_activate_dependency_row1") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph_preload_asm, "MathCore") == null);

    const dep_refcount_src = try source.load(std.testing.allocator, "examples/small/71_module_dependency_refcount.zp64");
    defer dep_refcount_src.deinit(std.testing.allocator);
    var dep_refcount_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer dep_refcount_stderr.deinit();

    const dep_refcount_asm = try lowerSourceToAsmWithOptions(std.testing.allocator, dep_refcount_src.path, dep_refcount_src.bytes, &dep_refcount_stderr.writer, .{ .dependency_modules = &modules });
    defer std.testing.allocator.free(dep_refcount_asm);
    try std.testing.expectEqual(@as(usize, 0), dep_refcount_stderr.written().len);
    try std.testing.expect(std.mem.indexOf(u8, dep_refcount_asm, "inc zeropage_module_registry_row1_refcount") != null);
    try std.testing.expect(std.mem.indexOf(u8, dep_refcount_asm, "dec zeropage_module_registry_row1_refcount") != null);
    try std.testing.expect(std.mem.indexOf(u8, dep_refcount_asm, "cmp #$ff") != null);
    try std.testing.expect(std.mem.indexOf(u8, dep_refcount_asm, "zeropage_module_unload_dependency_row1_final_release:") != null);
    try std.testing.expect(std.mem.indexOf(u8, dep_refcount_asm, "MathCore") == null);

    const graph_node_call_src = try source.load(std.testing.allocator, "examples/small/81_module_graph_node_call.zp64");
    defer graph_node_call_src.deinit(std.testing.allocator);
    var graph_node_call_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer graph_node_call_stderr.deinit();

    const graph_node_call_asm = try lowerSourceToAsmWithOptions(std.testing.allocator, graph_node_call_src.path, graph_node_call_src.bytes, &graph_node_call_stderr.writer, .{ .dependency_modules = &modules });
    defer std.testing.allocator.free(graph_node_call_asm);
    try std.testing.expectEqual(@as(usize, 0), graph_node_call_stderr.written().len);
    try std.testing.expect(std.mem.indexOf(u8, graph_node_call_asm, "lda zeropage_module_registry_row3_loaded") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph_node_call_asm, "jsr zeropage_module_activate_dependency_row3") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph_node_call_asm, "zeropage_module_activate_dependency_row3:") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph_node_call_asm, "jsr zeropage_module_load_dependency_row3") != null);

    const typed_graph_node_src = try source.load(std.testing.allocator, "examples/small/82_module_typed_graph_node_binding.zp64");
    defer typed_graph_node_src.deinit(std.testing.allocator);
    var typed_graph_node_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer typed_graph_node_stderr.deinit();

    const typed_graph_node_asm = try lowerSourceToAsmWithOptions(std.testing.allocator, typed_graph_node_src.path, typed_graph_node_src.bytes, &typed_graph_node_stderr.writer, .{ .dependency_modules = &modules });
    defer std.testing.allocator.free(typed_graph_node_asm);
    try std.testing.expectEqual(@as(usize, 0), typed_graph_node_stderr.written().len);
    try std.testing.expect(std.mem.indexOf(u8, typed_graph_node_asm, "jsr zeropage_module_acquire_dependency_row3") != null);
    try std.testing.expect(std.mem.indexOf(u8, typed_graph_node_asm, "jsr zeropage_module_activate_dependency_row3") != null);
    try std.testing.expect(std.mem.indexOf(u8, typed_graph_node_asm, "jsr zeropage_module_registry_jump_table+0") != null);
    try std.testing.expect(std.mem.indexOf(u8, typed_graph_node_asm, "FixedMath") == null);

    const current_src = try source.load(std.testing.allocator, "examples/small/64_module_typed_current_binding.zp64");
    defer current_src.deinit(std.testing.allocator);
    var current_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer current_stderr.deinit();

    const current_asm = try lowerSourceToAsm(std.testing.allocator, current_src.path, current_src.bytes, &current_stderr.writer);
    defer std.testing.allocator.free(current_asm);
    try std.testing.expectEqual(@as(usize, 0), current_stderr.written().len);
    try std.testing.expect(std.mem.indexOf(u8, current_asm, "jsr zeropage_module_load_current") != null);
    try std.testing.expect(std.mem.indexOf(u8, current_asm, "jsr zeropage_module_load_from_disk_current") != null);
    try std.testing.expect(std.mem.indexOf(u8, current_asm, "jsr zeropage_module_unload_current") != null);
    try std.testing.expect(std.mem.indexOf(u8, current_asm, "jsr zeropage_module_registry_jump_table+0") != null);
    try std.testing.expect(std.mem.indexOf(u8, current_asm, "EnemyRuntime") == null);
}

test "negative diagnostic rejects std import after Zig syntax parses" {
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectError(error.UnsupportedStdImport, lowerSourceToAsm(std.testing.allocator, "tests/fixtures/fail/std_import.zp64",
        \\const std = @import("std");
        \\export fn main() void {}
    , &stderr.writer));
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "full Zig standard library is not available") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "use @import(\"c64\")") != null);
}

test "negative diagnostic rejects valid Zig defer as unsupported ZeroPage feature" {
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectError(error.UnsupportedDefer, lowerSourceToAsm(std.testing.allocator, "tests/fixtures/fail/defer.zp64",
        \\const c64 = @import("c64");
        \\fn cleanup() void {}
        \\export fn main() void {
        \\    defer cleanup();
        \\}
    , &stderr.writer));
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "unsupported feature: defer") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "ZeroPage v0 does not support defer/errdefer") != null);
}

test "negative diagnostic rejects inline asm branch outside relative range" {
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    var source_text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source_text.deinit();
    try source_text.writer.writeAll(
        \\const c64 = @import("c64");
        \\export fn main() void {
        \\    asm {
        \\        beq far
        \\
    );
    for (0..140) |_| try source_text.writer.writeAll("        nop\n");
    try source_text.writer.writeAll(
        \\far:
        \\        nop
        \\    }
        \\}
    );

    try std.testing.expectError(error.InlineAsmBranchOutOfRange, lowerSourceToAsm(std.testing.allocator, "tests/fixtures/fail/inline_asm_far_branch.zp64", source_text.written(), &stderr.writer));
}

test "negative diagnostic rejects unsupported valid Zig integer width" {
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectError(error.UnsupportedU32, lowerSourceToAsm(std.testing.allocator, "tests/fixtures/fail/u32.zp64",
        \\const c64 = @import("c64");
        \\export fn main() void {
        \\    var wide: u32 = 1;
        \\    _ = wide;
        \\}
    , &stderr.writer));
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "unsupported type: u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "32-bit math is feature-gated") != null);
}

test "negative diagnostic rejects unsupported non-literal const string concat" {
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectError(error.UnsupportedStringConcat, lowerSourceToAsm(std.testing.allocator, "tests/fixtures/fail/string_concat.zp64",
        \\const c64 = @import("c64");
        \\const msg = missing ++ "b";
        \\export fn main() void {}
    , &stderr.writer));
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "unsupported string expression: ++") != null);
}

test "negative diagnostic rejects sentinel string type" {
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectError(error.UnsupportedStringSentinel, lowerSourceToAsm(std.testing.allocator, "tests/fixtures/fail/string_sentinel.zp64",
        \\const c64 = @import("c64");
        \\const msg: [:0]const u8 = "hello";
        \\export fn main() void {}
    , &stderr.writer));
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "unsupported string type: sentinel") != null);
}

test "negative diagnostic rejects bad string format arguments" {
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectError(error.UnsupportedFormatArgument, lowerSourceToAsm(std.testing.allocator, "tests/fixtures/fail/bad_string_format.zp64",
        \\const c64 = @import("c64");
        \\export fn main() void {
        \\    c64.console.print("{s}", .{1});
        \\}
    , &stderr.writer));
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "unsupported format argument") != null);
}

test "negative diagnostic rejects unicode string escape" {
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectError(error.UnsupportedUnicodeStringEscape, lowerSourceToAsm(std.testing.allocator, "tests/fixtures/fail/unicode_string_escape.zp64",
        \\const c64 = @import("c64");
        \\const msg = "bad \u{41}";
        \\export fn main() void {
        \\    c64.console.puts(msg);
        \\}
    , &stderr.writer));
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "8-bit only") != null);
}
