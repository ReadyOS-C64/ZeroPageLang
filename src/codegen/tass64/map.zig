const std = @import("std");
const ast = @import("../../ast.zig");
const frame_layout = @import("frame_layout.zig");
const reachability = @import("reachability.zig");
const zero_page_policy = @import("../../zero_page.zig");
const zero_page_parameter_map = @import("zero_page_parameter_map.zig");
const zero_page_scalars = @import("zero_page_scalars.zig");

const SectionMarker = struct {
    owner: []const u8,
    kind: []const u8,
    lifetime: ?[]const u8 = null,
    address_space: ?[]const u8 = null,
};

const Label = struct {
    name: []const u8,
    address: u16,
};

const RelocationKind = enum(u8) {
    abs16 = 1,
    lo8 = 2,
    hi8 = 3,
};

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

    fn trampolineSafe(self: KernalExportPolicy) bool {
        return self == .trampoline_safe;
    }
};

const RelocationMarker = struct {
    anchor: []const u8,
    target: []const u8,
    kind: RelocationKind,
    addend: i16,
};

const Relocation = struct {
    payload_offset: u32,
    kind: RelocationKind,
    target: []const u8,
    target_section: ?u16,
    addend: i16,

    fn deinit(self: Relocation, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
    }
};

const Section = struct {
    owner: []const u8,
    kind: []const u8,
    lifetime: []const u8,
    address_space: []const u8,
    end_address: ?u16 = null,
    labels: std.ArrayList(Label),

    fn deinit(self: *Section, allocator: std.mem.Allocator) void {
        allocator.free(self.owner);
        allocator.free(self.kind);
        allocator.free(self.lifetime);
        allocator.free(self.address_space);
        for (self.labels.items) |label| allocator.free(label.name);
        self.labels.deinit(allocator);
    }
};

const LabelMap = struct {
    bytes: []u8,
    map: std.StringHashMap(u16),

    fn load(allocator: std.mem.Allocator, labels_text: []const u8) !LabelMap {
        const bytes = try allocator.dupe(u8, labels_text);
        errdefer allocator.free(bytes);

        var label_map = std.StringHashMap(u16).init(allocator);
        errdefer label_map.deinit();

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            var parts = std.mem.tokenizeAny(u8, line, " \t\r");
            const kind = parts.next() orelse continue;
            if (!std.mem.eql(u8, kind, "al")) continue;
            const addr_text = parts.next() orelse continue;
            const raw_label = parts.next() orelse continue;
            const label = if (std.mem.startsWith(u8, raw_label, ".")) raw_label[1..] else raw_label;
            const addr = try std.fmt.parseInt(u16, addr_text, 16);
            try label_map.put(label, addr);
        }

        return .{ .bytes = bytes, .map = label_map };
    }

    fn deinit(self: *LabelMap, allocator: std.mem.Allocator) void {
        self.map.deinit();
        allocator.free(self.bytes);
    }
};

pub fn emitJson(
    allocator: std.mem.Allocator,
    asm_text: []const u8,
    labels_text: []const u8,
    prg_path: []const u8,
    load_address: u16,
    prg_bytes: usize,
) ![]u8 {
    return emitJsonInternal(allocator, null, asm_text, labels_text, prg_path, load_address, prg_bytes);
}

pub fn emitProgramJson(
    allocator: std.mem.Allocator,
    program: ast.Program,
    asm_text: []const u8,
    labels_text: []const u8,
    prg_path: []const u8,
    load_address: u16,
    prg_bytes: usize,
) ![]u8 {
    return emitJsonInternal(allocator, program, asm_text, labels_text, prg_path, load_address, prg_bytes);
}

fn emitJsonInternal(
    allocator: std.mem.Allocator,
    program: ?ast.Program,
    asm_text: []const u8,
    labels_text: []const u8,
    prg_path: []const u8,
    load_address: u16,
    prg_bytes: usize,
) ![]u8 {
    var label_map = try LabelMap.load(allocator, labels_text);
    defer label_map.deinit(allocator);

    var sections = try parseSections(allocator, asm_text, &label_map);
    defer {
        for (sections.items) |*section| section.deinit(allocator);
        sections.deinit(allocator);
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\n  \"format\": \"zeropage-map\",\n  \"version\": 1,\n  \"prg\": { \"path\": ");
    try writeJsonString(w, prg_path);
    try w.print(", \"load\": {d}, \"entry\": {d}, \"bytes\": {d} }},\n  \"sections\": [\n", .{ load_address, label_map.map.get("zeropage_entry") orelse label_map.map.get("main") orelse load_address, prg_bytes });

    for (sections.items, 0..) |section, index| {
        if (index != 0) try w.writeAll(",\n");
        const start = sectionStart(section);
        const end = sectionEnd(section, prgEnd(load_address, prg_bytes));
        try w.writeAll("    {\n      \"owner\": ");
        try writeJsonString(w, section.owner);
        try w.writeAll(",\n      \"kind\": ");
        try writeJsonString(w, section.kind);
        try w.writeAll(",\n      \"lifetime\": ");
        try writeJsonString(w, section.lifetime);
        try w.writeAll(",\n      \"address_space\": ");
        try writeJsonString(w, section.address_space);
        try w.writeAll(",\n      \"start\": ");
        try writeJsonNullableU16(w, start);
        try w.writeAll(",\n      \"end\": ");
        try writeJsonNullableU16(w, end);
        try w.writeAll(",\n      \"size\": ");
        if (start != null and end != null and end.? >= start.?) {
            try w.print("{d}", .{end.? - start.?});
        } else {
            try w.writeAll("0");
        }
        try w.writeAll(",\n      \"labels\": [");
        for (section.labels.items, 0..) |label, label_index| {
            if (label_index != 0) try w.writeAll(", ");
            try writeJsonString(w, label.name);
        }
        try w.writeAll("]\n    }");
    }

    try w.writeAll("\n  ]");
    if (program) |resolved_program| {
        const image = resolved_program.zeropage_options.image;
        try w.print(",\n  \"image\": {{ \"format\": \"{s}\", \"load_addr\": {d}, \"entry_addr\": {d}, \"basic_stub\": {s}, \"address_limit\": {d} }},\n  \"memory_regions\": [", .{
            @tagName(image.format),
            image.load_addr,
            image.entry_addr,
            if (image.basic_stub) "true" else "false",
            image.address_limit,
        });
        for (resolved_program.zeropage_options.memory.regions, 0..) |region, index| {
            if (index != 0) try w.writeAll(",");
            try w.writeAll("\n    { \"name\": ");
            try writeJsonString(w, region.name);
            try w.print(", \"space\": \"{s}\", \"bank\": \"{s}\", \"start\": {d}, \"end\": {d}, \"size\": {d} }}", .{
                @tagName(region.space),
                @tagName(region.bank),
                region.addr,
                @as(u64, region.addr) + @as(u64, region.size),
                region.size,
            });
        }
        if (resolved_program.zeropage_options.memory.regions.len != 0) try w.writeAll("\n  ");
        try w.writeAll("],\n  \"memory_placements\": [");
        for (resolved_program.zeropage_options.memory.placements, 0..) |placement, index| {
            if (index != 0) try w.writeAll(",");
            const load_start_name = try std.fmt.allocPrint(allocator, "zeropage_placement_{s}_load_start", .{placement.name});
            defer allocator.free(load_start_name);
            const load_end_name = try std.fmt.allocPrint(allocator, "zeropage_placement_{s}_load_end", .{placement.name});
            defer allocator.free(load_end_name);
            const run_start_name = try std.fmt.allocPrint(allocator, "zeropage_placement_{s}_run_start", .{placement.name});
            defer allocator.free(run_start_name);
            const run_end_name = try std.fmt.allocPrint(allocator, "zeropage_placement_{s}_run_end", .{placement.name});
            defer allocator.free(run_end_name);
            const load_start = label_map.map.get(load_start_name) orelse return error.InvalidZeroPageMemoryPlacement;
            const load_end = label_map.map.get(load_end_name) orelse return error.InvalidZeroPageMemoryPlacement;
            const run_start = label_map.map.get(run_start_name) orelse return error.InvalidZeroPageMemoryPlacement;
            const run_end = label_map.map.get(run_end_name) orelse return error.InvalidZeroPageMemoryPlacement;
            try w.writeAll("\n    { \"name\": ");
            try writeJsonString(w, placement.name);
            try w.writeAll(", \"region\": ");
            try writeJsonString(w, placement.region_name);
            try w.print(", \"load\": \"{s}\", \"load_start\": {d}, \"load_end\": {d}, \"run_start\": {d}, \"run_end\": {d}, \"size\": {d} }}", .{
                @tagName(placement.load),
                load_start,
                load_end,
                run_start,
                run_end,
                run_end -% run_start,
            });
        }
        if (resolved_program.zeropage_options.memory.placements.len != 0) try w.writeAll("\n  ");
        try w.writeAll("]");
    }
    if (program) |resolved_program| if (resolved_program.zeropage_options.zero_page.declared) {
        try writeZeroPageJson(allocator, w, resolved_program, asm_text, &label_map);
    };
    try w.writeAll("\n}\n");
    return try out.toOwnedSlice();
}

pub fn emitModuleMetadataJson(
    allocator: std.mem.Allocator,
    program: ast.Program,
    asm_text: []const u8,
    labels_text: []const u8,
    prg_path: []const u8,
    load_address: u16,
    prg_bytes: usize,
) ![]u8 {
    const module = program.zeropage_module orelse return error.UnsupportedZeroPageModule;
    if (program.zeropage_options.modules) |loader| {
        if (loader.dependency_graph) |graph| try validateModuleDependencyGraphMetadata(module, graph);
        if (loader.registry) |registry| try validateModuleRegistryMetadata(module, registry, loader.dependency_graph);
        if (loader.disk_manifest) |manifest| try validateModuleDiskManifestMetadata(module, loader, manifest);
        if (loader.state) |state| try validateModuleStateMetadata(module, loader, state);
        try validateModuleRegistryRuntimePlan(module, loader);
    }
    var label_map = try LabelMap.load(allocator, labels_text);
    defer label_map.deinit(allocator);

    var sections = try parseSections(allocator, asm_text, &label_map);
    defer {
        for (sections.items) |*section| section.deinit(allocator);
        sections.deinit(allocator);
    }
    const payload_range = try selectModulePayloadRange(allocator, program, module, sections.items, load_address, prg_bytes);
    const payload_len = modulePayloadLength(payload_range, @intCast(module.exports.len * 3));
    try validateModuleLoaderPayload(program, payload_len);
    var relocations = try collectRelocations(allocator, asm_text, &label_map, sections.items, payload_range, @intCast(module.exports.len * 3));
    defer {
        for (relocations.items) |relocation| relocation.deinit(allocator);
        relocations.deinit(allocator);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\n  \"format\": \"zeropage-module-metadata\",\n  \"version\": 1,\n  \"module_id\": ");
    try writeJsonString(w, module.id);
    try w.print(",\n  \"abi_version\": {d},\n  \"prg\": {{ \"path\": ", .{module.abi});
    try writeJsonString(w, prg_path);
    const jump_table_bytes: u32 = @intCast(module.exports.len * 3);
    try w.print(", \"load\": {d}, \"bytes\": {d} }},\n  \"payload\": {{ \"start\": ", .{ load_address, prg_bytes });
    if (payload_range) |range| {
        try w.print("{d}", .{range.start});
    } else {
        try w.writeAll("null");
    }
    try w.print(", \"length\": {d}, \"jump_table_bytes\": {d} }},\n  \"flags\": [],\n  \"exports\": [\n", .{ payload_len, jump_table_bytes });

    for (module.exports, 0..) |export_decl, index| {
        if (index != 0) try w.writeAll(",\n");
        const function = program.findFunction(export_decl.function_name) orelse return error.UnknownZeroPageModuleExport;
        const target_original = label_map.map.get(function.name) orelse return error.UnknownZeroPageModuleExport;
        try w.writeAll("    { \"name\": ");
        try writeJsonString(w, export_decl.name);
        try w.print(", \"ordinal\": {d}", .{index});
        try w.writeAll(", \"label\": ");
        try writeJsonString(w, function.name);
        try w.print(", \"target_original\": {d}", .{target_original});
        const kernal_policy = try moduleExportKernalPolicy(allocator, program, function);
        try w.print(", \"requires_kernal_rom\": {}", .{kernal_policy.requiresKernalRom()});
        try w.print(", \"kernal_trampoline_safe\": {}", .{kernal_policy.trampolineSafe()});
        try w.writeAll(", \"frame\": ");
        try writeJsonString(w, @tagName(frame_layout.effectivePolicy(program, function.name)));
        if (frame_layout.effectivePolicy(program, function.name) == .stack) {
            var layout = try frame_layout.planFunction(allocator, program, function, .stack);
            defer layout.deinit(allocator);
            try w.print(", \"frame_size\": {d}", .{layout.byte_size});
        }
        try w.writeAll(", \"params\": [");
        for (function.params, 0..) |param, param_index| {
            if (param_index != 0) try w.writeAll(", ");
            try w.writeAll("{ \"name\": ");
            try writeJsonString(w, param.name);
            try w.writeAll(", \"type\": ");
            try writeJsonType(w, program, param.ty);
            if (frame_layout.effectivePolicy(program, function.name) == .stack) {
                var layout = try frame_layout.planFunction(allocator, program, function, .stack);
                defer layout.deinit(allocator);
                const slot = layout.findSlot(param.name) orelse return error.UnknownVariable;
                try w.print(", \"offset\": {d}", .{slot.offset});
            }
            try w.writeAll(" }");
        }
        try w.writeAll("], \"return\": ");
        try writeJsonType(w, program, function.return_type);
        try w.writeAll(" }");
    }

    try w.writeAll("\n  ],\n  \"deps\": [");
    for (module.deps, 0..) |dep, index| {
        if (index != 0) try w.writeAll(", ");
        try w.print("{{ \"ordinal\": {d}, \"id\": ", .{index});
        try writeJsonString(w, dep);
        try w.writeAll(" }");
    }
    try w.writeAll("],\n  \"sections\": [\n");

    for (sections.items, 0..) |section, index| {
        if (index != 0) try w.writeAll(",\n");
        const start = sectionStart(section);
        const end = sectionEnd(section, prgEnd(load_address, prg_bytes));
        try w.writeAll("    { \"owner\": ");
        try writeJsonString(w, section.owner);
        try w.writeAll(", \"kind\": ");
        try writeJsonString(w, section.kind);
        try w.writeAll(", \"start\": ");
        try writeJsonNullableU16(w, start);
        try w.writeAll(", \"end\": ");
        try writeJsonNullableU16(w, end);
        try w.writeAll(", \"size\": ");
        if (start != null and end != null and end.? >= start.?) {
            try w.print("{d}", .{end.? - start.?});
        } else {
            try w.writeAll("0");
        }
        try w.writeAll(" }");
    }

    try w.writeAll("\n  ]");
    if (program.zeropage_options.modules) |loader| {
        try w.writeAll(",\n  \"loader\": {\n    \"load_window\": { \"addr\": ");
        try w.print("{d}", .{loader.load_window.addr});
        try w.writeAll(", \"size\": ");
        try w.print("{d}", .{loader.load_window.size});
        try w.writeAll(", \"alignment\": 256 },\n    \"reu_cache\": { \"addr\": ");
        try w.print("{d}", .{loader.reu_cache.addr});
        try w.writeAll(", \"size\": ");
        try w.print("{d}", .{loader.reu_cache.size});
        try w.writeAll(", \"alignment\": 256 }");
        if (hasModuleMultiWindowMetadata(loader)) {
            try w.writeAll(",\n    \"load_windows\": [\n      { \"name\": \"main\", \"addr\": ");
            try w.print("{d}", .{loader.load_window.addr});
            try w.writeAll(", \"size\": ");
            try w.print("{d}", .{loader.load_window.size});
            try w.writeAll(", \"alignment\": 256, \"bank\": ");
            try writeJsonString(w, moduleWindowBankName(loader.load_window.bank));
            try w.writeAll(" }");
            for (loader.extra_load_windows) |entry| {
                try w.writeAll(",\n      { \"name\": ");
                try writeJsonString(w, entry.name);
                try w.writeAll(", \"addr\": ");
                try w.print("{d}", .{entry.window.addr});
                try w.writeAll(", \"size\": ");
                try w.print("{d}", .{entry.window.size});
                try w.writeAll(", \"alignment\": 256, \"bank\": ");
                try writeJsonString(w, moduleWindowBankName(entry.window.bank));
                try w.writeAll(" }");
            }
            try w.writeAll("\n    ]");
            if (loader.window_assignments.len != 0) {
                try w.writeAll(",\n    \"window_assignments\": [");
                for (loader.window_assignments, 0..) |assignment, index| {
                    if (index != 0) try w.writeAll(",");
                    try w.writeAll("\n      { \"id\": ");
                    try writeJsonString(w, assignment.id);
                    try w.writeAll(", \"window\": ");
                    try writeJsonString(w, assignment.window_name);
                    if (moduleWindowAssignmentRow(module, loader, assignment.id)) |row| {
                        try w.writeAll(", \"row\": ");
                        try w.print("{d}", .{row});
                    }
                    try w.writeAll(" }");
                }
                try w.writeAll("\n    ]");
            }
        }
        if (loader.policy) |policy| {
            try w.writeAll(",\n    \"policy\": { \"current\": { \"mode\": ");
            try writeJsonString(w, moduleLoadModeName(policy.current.mode));
            if (policy.current.filename) |filename| {
                try w.writeAll(", \"filename\": ");
                try writeJsonString(w, filename);
            }
            try w.writeAll(" }");
            if (policy.deps.len != 0) {
                try w.writeAll(", \"deps\": [");
                for (policy.deps, 0..) |dep_policy, index| {
                    if (index != 0) try w.writeAll(", ");
                    try w.writeAll("{ \"id\": ");
                    try writeJsonString(w, dep_policy.id);
                    try w.writeAll(", \"mode\": ");
                    try writeJsonString(w, moduleLoadModeName(dep_policy.policy.mode));
                    if (dep_policy.policy.graph) try w.writeAll(", \"graph\": true");
                    try w.writeAll(" }");
                }
                try w.writeAll("]");
            }
            try w.writeAll(" }");
        }
        try w.writeAll("\n  }");
    }
    if (program.zeropage_options.modules) |loader| {
        if (loader.registry) |registry| try writeRegistryJson(w, module, registry);
        if (loader.disk_manifest) |manifest| try writeDiskManifestJson(w, module, loader, manifest);
        if (loader.dependency_graph) |graph| try writeDependencyGraphJson(w, module, graph);
        if (loader.state) |state| try writeModuleStateJson(w, module, loader, state);
    }
    if (relocations.items.len == 0) {
        try w.writeAll(",\n  \"relocations\": []\n}\n");
    } else {
        try w.writeAll(",\n  \"relocations\": [");
        for (relocations.items, 0..) |relocation, index| {
            if (index != 0) try w.writeAll(",");
            try w.writeAll("\n    { \"payload_offset\": ");
            try w.print("{d}", .{relocation.payload_offset});
            try w.writeAll(", \"kind\": ");
            try writeJsonString(w, relocationKindName(relocation.kind));
            try w.writeAll(", \"target\": ");
            try writeJsonString(w, relocation.target);
            try w.writeAll(", \"target_section\": ");
            if (relocation.target_section) |section_index| {
                try w.print("{d}", .{section_index});
            } else {
                try w.writeAll("null");
            }
            try w.print(", \"addend\": {d} }}", .{relocation.addend});
        }
        try w.writeAll("\n  ]\n}\n");
    }
    return try out.toOwnedSlice();
}

pub fn emitModuleDiskManifestJson(
    allocator: std.mem.Allocator,
    program: ast.Program,
) ![]u8 {
    const module = program.zeropage_module orelse return error.UnsupportedZeroPageModule;
    const loader = program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
    const manifest = loader.disk_manifest orelse return error.InvalidZeroPageModuleDiskManifest;
    try validateModuleDiskManifestMetadata(module, loader, manifest);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\n  \"format\": \"zeropage-module-disk-manifest\",\n  \"version\": 1,\n  \"module_id\": ");
    try writeJsonString(w, module.id);
    try w.writeAll(",\n  \"entries\": [\n");
    try writeDiskManifestEntryJson(w, 0, module.id, "current", null, manifest.current);
    for (module.deps, 0..) |dep, dep_ordinal| {
        const entry = findManifestDependency(manifest, dep) orelse return error.InvalidZeroPageModuleDiskManifest;
        try w.writeAll(",\n");
        try writeDiskManifestEntryJson(w, dep_ordinal + 1, dep, "dependency", dep_ordinal, entry.filename);
    }
    if (loader.dependency_graph) |graph| {
        for (graph.nodes) |node| {
            if (findDependencyOrdinal(module, node.id) != null) continue;
            const row = graphRowForId(module, graph, node.id) orelse return error.InvalidZeroPageModuleRegistry;
            const entry = findManifestDependency(manifest, node.id) orelse return error.InvalidZeroPageModuleDiskManifest;
            try w.writeAll(",\n");
            try writeDiskManifestEntryJson(w, row, node.id, "transitive", null, entry.filename);
        }
    }
    try w.writeAll("\n  ]\n}\n");
    return try out.toOwnedSlice();
}

const module_binary_magic = "ZPMD";
const module_binary_version: u8 = 1;
const module_binary_header_size: u16 = 40;
const module_binary_flag_loader_requirements: u16 = 0x0001;
const module_binary_flag_registry_requirements: u16 = 0x0002;
const module_binary_flag_disk_manifest: u16 = 0x0004;
const module_binary_flag_state_snapshot: u16 = 0x0008;
const module_binary_flag_dependency_graph: u16 = 0x0010;
const module_binary_flag_multi_window: u16 = 0x0020;
const module_binary_checksum_offset: usize = 14;
const module_binary_total_size_offset: usize = 10;
const module_binary_jump_table_offset_offset: usize = 26;
const module_binary_payload_offset_offset: usize = 30;
const module_binary_payload_len_offset: usize = 34;

pub fn emitModuleBinary(
    allocator: std.mem.Allocator,
    program: ast.Program,
    asm_text: []const u8,
    labels_text: []const u8,
    load_address: u16,
    prg_bytes: []const u8,
) ![]u8 {
    const module = program.zeropage_module orelse return error.UnsupportedZeroPageModule;
    if (program.zeropage_options.modules) |loader| {
        if (loader.dependency_graph) |graph| try validateModuleDependencyGraphMetadata(module, graph);
        if (loader.registry) |registry| try validateModuleRegistryMetadata(module, registry, loader.dependency_graph);
        if (loader.disk_manifest) |manifest| try validateModuleDiskManifestMetadata(module, loader, manifest);
        if (loader.state) |state| try validateModuleStateMetadata(module, loader, state);
        try validateModuleRegistryRuntimePlan(module, loader);
    }
    var label_map = try LabelMap.load(allocator, labels_text);
    defer label_map.deinit(allocator);

    var sections = try parseSections(allocator, asm_text, &label_map);
    defer {
        for (sections.items) |*section| section.deinit(allocator);
        sections.deinit(allocator);
    }

    const payload_range = try selectModulePayloadRange(allocator, program, module, sections.items, load_address, prg_bytes.len);
    const jump_table_bytes: u32 = @intCast(module.exports.len * 3);
    try validateModuleLoaderPayload(program, modulePayloadLength(payload_range, jump_table_bytes));
    var relocations = try collectRelocations(allocator, asm_text, &label_map, sections.items, payload_range, jump_table_bytes);
    defer {
        for (relocations.items) |relocation| relocation.deinit(allocator);
        relocations.deinit(allocator);
    }
    const selected_payload = try selectedPayloadSlice(prg_bytes, load_address, payload_range);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, module_binary_magic);
    try out.append(allocator, module_binary_version);
    try out.append(allocator, @intCast(module.abi));
    const flags: u16 = moduleBinaryFlags(program);
    try appendLe16(allocator, &out, flags);
    try appendLe16(allocator, &out, module_binary_header_size);
    try appendLe32(allocator, &out, 0);
    try appendLe16(allocator, &out, 0);
    try appendLe16(allocator, &out, @intCast(module.exports.len));
    try appendLe16(allocator, &out, @intCast(module.deps.len));
    try appendLe16(allocator, &out, @intCast(sections.items.len));
    try appendLe16(allocator, &out, @intCast(relocations.items.len));
    try appendLe16(allocator, &out, @intCast(module.exports.len));
    try appendLe32(allocator, &out, 0);
    try appendLe32(allocator, &out, 0);
    try appendLe32(allocator, &out, 0);
    try appendString(allocator, &out, module.id);

    for (module.exports, 0..) |export_decl, ordinal| {
        const function = program.findFunction(export_decl.function_name) orelse return error.UnknownZeroPageModuleExport;
        try appendLe16(allocator, &out, @intCast(ordinal));
        try appendString(allocator, &out, export_decl.name);
        try appendString(allocator, &out, function.name);
        try out.append(allocator, framePolicyByte(frame_layout.effectivePolicy(program, function.name)));
        const kernal_policy = try moduleExportKernalPolicy(allocator, program, function);
        try out.append(allocator, (if (kernal_policy.requiresKernalRom()) @as(u8, 1) else 0) | (if (kernal_policy.trampolineSafe()) @as(u8, 2) else 0));
        if (function.params.len > 255) return error.UnsupportedZeroPageModuleExport;
        try out.append(allocator, @intCast(function.params.len));
        for (function.params) |param| {
            try appendString(allocator, &out, param.name);
            try out.append(allocator, try typeByte(program, param.ty));
        }
        try out.append(allocator, try typeByte(program, function.return_type));
    }

    for (module.deps, 0..) |dep, ordinal| {
        try appendLe16(allocator, &out, @intCast(ordinal));
        try appendString(allocator, &out, dep);
    }

    const final_end = prgEnd(load_address, prg_bytes.len);
    for (sections.items) |section| {
        const start = sectionStart(section);
        const end = sectionEnd(section, final_end);
        const size: u16 = if (start != null and end != null and end.? >= start.?) end.? - start.? else 0;
        try appendString(allocator, &out, section.owner);
        try appendString(allocator, &out, section.kind);
        try appendNullableU16(allocator, &out, start);
        try appendNullableU16(allocator, &out, end);
        try appendLe16(allocator, &out, size);
    }

    for (relocations.items) |relocation| {
        try appendLe32(allocator, &out, relocation.payload_offset);
        try out.append(allocator, @intFromEnum(relocation.kind));
        try appendLe16(allocator, &out, relocation.target_section orelse 0xffff);
        try appendLe16(allocator, &out, @bitCast(relocation.addend));
        try appendString(allocator, &out, relocation.target);
    }
    if (program.zeropage_options.modules) |loader| {
        try appendModuleLoaderRecord(allocator, &out, loader);
        if (hasModuleMultiWindowMetadata(loader)) try appendModuleMultiWindowRecord(allocator, &out, module, loader);
        if (loader.registry) |registry| try appendModuleRegistryRecord(allocator, &out, module, registry);
        if (loader.disk_manifest) |manifest| try appendModuleDiskManifestRecord(allocator, &out, module, loader, manifest);
        if (loader.dependency_graph) |graph| try appendModuleDependencyGraphRecord(allocator, &out, module, graph);
        if (loader.state) |state| try appendModuleStateRecord(allocator, &out, module, loader, state);
    }

    const payload_offset: u32 = @intCast(out.items.len);
    var payload_image = try buildModulePayloadImage(allocator, program, module, &label_map, selected_payload);
    defer payload_image.deinit(allocator);
    try out.appendSlice(allocator, payload_image.items);

    const payload_len: u32 = @intCast(out.items.len - payload_offset);
    patchLe32(out.items, module_binary_total_size_offset, @intCast(out.items.len));
    patchLe32(out.items, module_binary_jump_table_offset_offset, payload_offset);
    patchLe32(out.items, module_binary_payload_offset_offset, payload_offset);
    patchLe32(out.items, module_binary_payload_len_offset, payload_len);
    patchLe16(out.items, module_binary_checksum_offset, moduleBinaryChecksum(out.items));

    return try out.toOwnedSlice(allocator);
}

pub fn emitModuleRelocationSimulationJson(
    allocator: std.mem.Allocator,
    program: ast.Program,
    asm_text: []const u8,
    labels_text: []const u8,
    load_address: u16,
    prg_bytes: []const u8,
) ![]u8 {
    const module = program.zeropage_module orelse return error.UnsupportedZeroPageModule;
    const loader = program.zeropage_options.modules orelse return error.MissingZeroPageModuleLoader;
    var label_map = try LabelMap.load(allocator, labels_text);
    defer label_map.deinit(allocator);

    var sections = try parseSections(allocator, asm_text, &label_map);
    defer {
        for (sections.items) |*section| section.deinit(allocator);
        sections.deinit(allocator);
    }

    const payload_range = try selectModulePayloadRange(allocator, program, module, sections.items, load_address, prg_bytes.len);
    const jump_table_bytes: u32 = @intCast(module.exports.len * 3);
    const payload_len = modulePayloadLength(payload_range, jump_table_bytes);
    try validateModuleLoaderPayload(program, payload_len);
    var relocations = try collectRelocations(allocator, asm_text, &label_map, sections.items, payload_range, jump_table_bytes);
    defer {
        for (relocations.items) |relocation| relocation.deinit(allocator);
        relocations.deinit(allocator);
    }

    const selected_payload = try selectedPayloadSlice(prg_bytes, load_address, payload_range);
    var payload_image = try buildModulePayloadImage(allocator, program, module, &label_map, selected_payload);
    defer payload_image.deinit(allocator);
    try applySimulatedJumpTableRelocations(&payload_image, program, module, &label_map, payload_range, loader.load_window.addr, jump_table_bytes);

    var applied: std.ArrayList(AppliedRelocation) = .empty;
    defer applied.deinit(allocator);
    for (relocations.items, 0..) |relocation, index| {
        const applied_record = try applySimulatedRelocation(&payload_image, relocation, index, &label_map, payload_range, loader.load_window.addr, jump_table_bytes);
        try applied.append(allocator, applied_record);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\n  \"format\": \"zeropage-module-relocation-sim\",\n  \"version\": 1,\n  \"module_id\": ");
    try writeJsonString(w, module.id);
    try w.print(",\n  \"load_window\": {{ \"addr\": {d}, \"size\": {d} }},\n", .{ loader.load_window.addr, loader.load_window.size });
    try w.print("  \"payload_length\": {d},\n  \"relocated_payload_checksum\": {d},\n  \"applied_relocations\": [", .{
        payload_image.items.len,
        moduleBinaryChecksum(payload_image.items),
    });
    for (applied.items, 0..) |record, record_index| {
        const relocation = relocations.items[record.relocation_index];
        if (record_index != 0) try w.writeAll(",");
        try w.writeAll("\n    { \"payload_offset\": ");
        try w.print("{d}", .{relocation.payload_offset});
        try w.writeAll(", \"kind\": ");
        try writeJsonString(w, relocationKindName(relocation.kind));
        try w.writeAll(", \"target\": ");
        try writeJsonString(w, relocation.target);
        try w.print(", \"target_original\": {d}, \"target_runtime\": {d}, \"addend\": {d}, \"before\": ", .{
            record.target_original,
            record.target_runtime,
            relocation.addend,
        });
        try writeJsonByteArray(w, record.before, record.size);
        try w.writeAll(", \"after\": ");
        try writeJsonByteArray(w, record.after, record.size);
        try w.writeAll(" }");
    }
    if (applied.items.len != 0) try w.writeAll("\n  ");
    try w.writeAll("]\n}\n");
    return try out.toOwnedSlice();
}

fn applySimulatedJumpTableRelocations(
    payload_image: *std.ArrayList(u8),
    program: ast.Program,
    module: ast.ZeroPageModule,
    label_map: *const LabelMap,
    payload_range: ?PayloadRange,
    load_window_addr: u16,
    jump_table_bytes: u32,
) !void {
    const range = payload_range orelse return error.InvalidZeroPageModulePayloadRange;
    for (module.exports, 0..) |export_decl, ordinal| {
        const function = program.findFunction(export_decl.function_name) orelse return error.UnknownZeroPageModuleExport;
        const target_original = label_map.map.get(function.name) orelse return error.UnknownZeroPageModuleExport;
        const target_relative = @as(i64, target_original) - @as(i64, range.start);
        const target_runtime_i64 = @as(i64, load_window_addr) + @as(i64, jump_table_bytes) + target_relative;
        if (target_runtime_i64 < 0 or target_runtime_i64 > 0xffff) return error.InvalidZeroPageModuleRelocation;
        const target_runtime: u16 = @intCast(target_runtime_i64);
        const offset = ordinal * 3 + 1;
        if (offset + 1 >= payload_image.items.len) return error.InvalidZeroPageModulePayloadRange;
        payload_image.items[offset] = @intCast(target_runtime & 0x00ff);
        payload_image.items[offset + 1] = @intCast(target_runtime >> 8);
    }
}

pub fn validateModuleLoaderRequirements(
    allocator: std.mem.Allocator,
    program: ast.Program,
    asm_text: []const u8,
    labels_text: []const u8,
    load_address: u16,
    prg_bytes: usize,
) !void {
    const module = program.zeropage_module orelse return;
    if (program.zeropage_options.modules == null) return;
    var label_map = try LabelMap.load(allocator, labels_text);
    defer label_map.deinit(allocator);

    var sections = try parseSections(allocator, asm_text, &label_map);
    defer {
        for (sections.items) |*section| section.deinit(allocator);
        sections.deinit(allocator);
    }
    const payload_range = try selectModulePayloadRange(allocator, program, module, sections.items, load_address, prg_bytes);
    try validateModuleLoaderPayload(program, modulePayloadLength(payload_range, @intCast(module.exports.len * 3)));
}

fn validateModuleLoaderPayload(program: ast.Program, payload_len: u32) !void {
    const loader = program.zeropage_options.modules orelse return;
    if (payload_len > loader.load_window.size) return error.ZeroPageModulePayloadTooLarge;
    if (payload_len > loader.reu_cache.size) return error.ZeroPageModulePayloadTooLarge;
}

fn modulePayloadLength(payload_range: ?PayloadRange, jump_table_bytes: u32) u32 {
    const selected_bytes: u32 = if (payload_range) |range| @intCast(range.end - range.start) else 0;
    return jump_table_bytes + selected_bytes;
}

fn selectedPayloadSlice(prg_bytes: []const u8, load_address: u16, payload_range: ?PayloadRange) ![]const u8 {
    const prg_payload = if (prg_bytes.len >= 2) prg_bytes[2..] else prg_bytes[0..0];
    return if (payload_range) |range| blk: {
        if (range.start < load_address or range.end < range.start) return error.InvalidZeroPageModulePayloadRange;
        const start_index = @as(usize, range.start - load_address);
        const len = @as(usize, range.end - range.start);
        if (start_index > prg_payload.len or start_index + len > prg_payload.len) return error.InvalidZeroPageModulePayloadRange;
        break :blk prg_payload[start_index .. start_index + len];
    } else prg_payload[0..0];
}

fn buildModulePayloadImage(
    allocator: std.mem.Allocator,
    program: ast.Program,
    module: ast.ZeroPageModule,
    label_map: *const LabelMap,
    selected_payload: []const u8,
) !std.ArrayList(u8) {
    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(allocator);
    for (module.exports) |export_decl| {
        const function = program.findFunction(export_decl.function_name) orelse return error.UnknownZeroPageModuleExport;
        const addr = label_map.map.get(function.name) orelse return error.UnknownZeroPageModuleExport;
        try payload.append(allocator, 0x4c);
        try appendLe16(allocator, &payload, addr);
    }
    try payload.appendSlice(allocator, selected_payload);
    return payload;
}

const AppliedRelocation = struct {
    relocation_index: usize,
    target_original: u16,
    target_runtime: u16,
    before: [2]u8,
    after: [2]u8,
    size: u8,
};

fn applySimulatedRelocation(
    payload_image: *std.ArrayList(u8),
    relocation: Relocation,
    relocation_index: usize,
    label_map: *const LabelMap,
    payload_range: ?PayloadRange,
    load_window_addr: u16,
    jump_table_bytes: u32,
) !AppliedRelocation {
    const range = payload_range orelse return error.InvalidZeroPageModuleRelocation;
    const target_original = label_map.map.get(relocation.target) orelse return error.InvalidZeroPageModuleRelocation;
    const target_relative = @as(i64, target_original) - @as(i64, range.start) + @as(i64, relocation.addend);
    const target_runtime_i64 = @as(i64, load_window_addr) + @as(i64, jump_table_bytes) + target_relative;
    if (target_runtime_i64 < 0 or target_runtime_i64 > 0xffff) return error.InvalidZeroPageModuleRelocation;
    const target_runtime: u16 = @intCast(target_runtime_i64);

    const offset: usize = @intCast(relocation.payload_offset);
    const size: u8 = switch (relocation.kind) {
        .abs16 => 2,
        .lo8, .hi8 => 1,
    };
    if (offset + size > payload_image.items.len) return error.InvalidZeroPageModuleRelocation;

    var before = [_]u8{ 0, 0 };
    var after = [_]u8{ 0, 0 };
    for (0..size) |index| before[index] = payload_image.items[offset + index];
    switch (relocation.kind) {
        .abs16 => {
            payload_image.items[offset] = @intCast(target_runtime & 0x00ff);
            payload_image.items[offset + 1] = @intCast(target_runtime >> 8);
        },
        .lo8 => payload_image.items[offset] = @intCast(target_runtime & 0x00ff),
        .hi8 => payload_image.items[offset] = @intCast(target_runtime >> 8),
    }
    for (0..size) |index| after[index] = payload_image.items[offset + index];

    return .{
        .relocation_index = relocation_index,
        .target_original = target_original,
        .target_runtime = target_runtime,
        .before = before,
        .after = after,
        .size = size,
    };
}

fn appendModuleLoaderRecord(allocator: std.mem.Allocator, out: *std.ArrayList(u8), loader: ast.ModuleLoaderOptions) !void {
    try appendLe16(allocator, out, loader.load_window.addr);
    try appendLe16(allocator, out, loader.load_window.size);
    try appendLe32(allocator, out, loader.reu_cache.addr);
    try appendLe32(allocator, out, loader.reu_cache.size);
    try appendLe16(allocator, out, 0x0100);
}

fn appendModuleMultiWindowRecord(allocator: std.mem.Allocator, out: *std.ArrayList(u8), module: ast.ZeroPageModule, loader: ast.ModuleLoaderOptions) !void {
    const window_count = 1 + loader.extra_load_windows.len;
    if (window_count > 255 or loader.window_assignments.len > 255) return error.InvalidZeroPageModuleLoadWindow;
    try out.append(allocator, @intCast(window_count));
    try appendString(allocator, out, "main");
    try appendLe16(allocator, out, loader.load_window.addr);
    try appendLe16(allocator, out, loader.load_window.size);
    try out.append(allocator, moduleWindowBankByte(loader.load_window.bank));
    for (loader.extra_load_windows) |entry| {
        try appendString(allocator, out, entry.name);
        try appendLe16(allocator, out, entry.window.addr);
        try appendLe16(allocator, out, entry.window.size);
        try out.append(allocator, moduleWindowBankByte(entry.window.bank));
    }
    try out.append(allocator, @intCast(loader.window_assignments.len));
    for (loader.window_assignments) |assignment| {
        const row = moduleWindowAssignmentRow(module, loader, assignment.id) orelse return error.InvalidZeroPageModuleLoadWindow;
        const window_index = moduleWindowIndex(loader, assignment.window_name) orelse return error.InvalidZeroPageModuleLoadWindow;
        try appendLe16(allocator, out, @intCast(row));
        try out.append(allocator, @intCast(window_index));
    }
}

fn moduleBinaryFlags(program: ast.Program) u16 {
    const loader = program.zeropage_options.modules orelse return 0;
    var flags: u16 = module_binary_flag_loader_requirements;
    if (loader.registry != null) flags |= module_binary_flag_registry_requirements;
    if (loader.disk_manifest != null) flags |= module_binary_flag_disk_manifest;
    if (loader.state != null) flags |= module_binary_flag_state_snapshot;
    if (loader.dependency_graph != null) flags |= module_binary_flag_dependency_graph;
    if (hasModuleMultiWindowMetadata(loader)) flags |= module_binary_flag_multi_window;
    return flags;
}

fn moduleWindowBankName(bank: ast.ModuleWindowBank) []const u8 {
    return switch (bank) {
        .visible => "visible",
        .ram_under_basic => "ram_under_basic",
        .ram_under_kernal => "ram_under_kernal",
    };
}

fn moduleWindowBankByte(bank: ast.ModuleWindowBank) u8 {
    return switch (bank) {
        .visible => 0,
        .ram_under_basic => 1,
        .ram_under_kernal => 2,
    };
}

fn hasModuleMultiWindowMetadata(loader: ast.ModuleLoaderOptions) bool {
    return loader.load_window.bank != .visible or loader.extra_load_windows.len != 0 or loader.window_assignments.len != 0;
}

fn validateModuleRegistryMetadata(module: ast.ZeroPageModule, registry: ast.ModuleRegistryOptions, graph: ?ast.ModuleDependencyGraphOptions) !void {
    if (registry.capacity < 1 + moduleGraphNodeCount(module, graph)) return error.InvalidZeroPageModuleRegistry;
    for (module.deps) |dep| {
        if (std.mem.eql(u8, dep, module.id)) return error.InvalidZeroPageModuleRegistry;
    }
}

fn validateModuleDiskManifestMetadata(module: ast.ZeroPageModule, loader: ast.ModuleLoaderOptions, manifest: ast.ModuleDiskManifestOptions) !void {
    const registry = loader.registry orelse return error.InvalidZeroPageModuleDiskManifest;
    const required_count = moduleGraphNodeCount(module, loader.dependency_graph);
    if (registry.capacity < 1 + required_count) return error.InvalidZeroPageModuleRegistry;
    if (!isValidModuleDiskFilename(manifest.current)) return error.InvalidZeroPageModuleDiskManifest;
    if (manifest.deps.len != required_count) return error.InvalidZeroPageModuleDiskManifest;
    for (manifest.deps) |entry| {
        if (!isValidModuleDiskFilename(entry.filename)) return error.InvalidZeroPageModuleDiskManifest;
        if (loader.dependency_graph) |graph| {
            if (findModuleGraphNode(graph, entry.id) == null) return error.InvalidZeroPageModuleDiskManifest;
        } else if (findDependencyOrdinal(module, entry.id) == null) return error.InvalidZeroPageModuleDiskManifest;
    }
    if (loader.dependency_graph) |graph| {
        for (graph.nodes) |node| {
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

fn validateModuleStateMetadata(module: ast.ZeroPageModule, loader: ast.ModuleLoaderOptions, state: ast.ModuleStateOptions) !void {
    try validateModuleStateRanges(loader.load_window, state.current);
    for (state.deps, 0..) |dep_state, index| {
        if (findDependencyOrdinal(module, dep_state.id) == null) return error.InvalidZeroPageModuleState;
        for (state.deps[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, dep_state.id)) return error.InvalidZeroPageModuleState;
        }
        try validateModuleStateRanges(loader.load_window, dep_state.state);
    }
    if (moduleStateAnyPersistent(state)) {
        const rows = moduleRegistryRows(loader);
        const required_slots: u64 = @as(u64, rows) + 1 + @as(u64, module.deps.len);
        const required_cache = required_slots * @as(u64, loader.load_window.size);
        if (required_cache > loader.reu_cache.size) return error.InvalidZeroPageModuleState;
        const planned_end = @as(u64, loader.reu_cache.addr) + required_cache;
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

fn validateModuleStateRanges(load_window: ast.ModuleLoadWindowOptions, state: ast.CurrentModuleState) !void {
    for (state.ranges, 0..) |range, index| {
        if (range.size == 0) return error.InvalidZeroPageModuleState;
        const end = @as(u32, range.offset) + @as(u32, range.size);
        if (end > load_window.size) return error.InvalidZeroPageModuleState;
        for (state.ranges[index + 1 ..]) |other| {
            const other_end = @as(u32, other.offset) + @as(u32, other.size);
            if (rangesOverlap16(range.offset, end, other.offset, other_end)) return error.InvalidZeroPageModuleState;
        }
    }
}

fn rangesOverlap16(a_start: u16, a_end: u32, b_start: u16, b_end: u32) bool {
    return @as(u32, a_start) < b_end and @as(u32, b_start) < a_end;
}

fn moduleRegistryRows(loader: ast.ModuleLoaderOptions) u16 {
    if (loader.registry) |registry| {
        if (loader.disk_manifest != null) return registry.capacity;
    }
    return 1;
}

fn validateModuleRegistryRuntimePlan(module: ast.ZeroPageModule, loader: ast.ModuleLoaderOptions) !void {
    const registry = loader.registry orelse return;
    _ = loader.disk_manifest orelse return;
    if (registry.capacity < 1 + moduleGraphNodeCount(module, loader.dependency_graph)) return error.InvalidZeroPageModuleRegistry;
    const required_cache = @as(u64, registry.capacity) * @as(u64, loader.load_window.size);
    if (required_cache > loader.reu_cache.size) return error.InvalidZeroPageModuleRegistry;
    const planned_end = @as(u64, loader.reu_cache.addr) + required_cache;
    if (planned_end > 0x0100_0000) return error.InvalidZeroPageModuleRegistry;
}

fn validateModuleDependencyGraphMetadata(module: ast.ZeroPageModule, graph: ast.ModuleDependencyGraphOptions) !void {
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

fn moduleGraphNodeCount(module: ast.ZeroPageModule, graph: ?ast.ModuleDependencyGraphOptions) usize {
    if (graph) |resolved| return resolved.nodes.len;
    return module.deps.len;
}

fn findDependencyOrdinal(module: ast.ZeroPageModule, id: []const u8) ?usize {
    for (module.deps, 0..) |dep, ordinal| {
        if (std.mem.eql(u8, dep, id)) return ordinal;
    }
    return null;
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

fn graphRowForId(module: ast.ZeroPageModule, graph: ast.ModuleDependencyGraphOptions, id: []const u8) ?usize {
    if (findDependencyOrdinal(module, id)) |ordinal| return ordinal + 1;
    var row: usize = 1 + module.deps.len;
    for (graph.nodes) |node| {
        if (findDependencyOrdinal(module, node.id) != null) continue;
        if (std.mem.eql(u8, node.id, id)) return row;
        row += 1;
    }
    return null;
}

fn moduleWindowAssignmentRow(module: ast.ZeroPageModule, loader: ast.ModuleLoaderOptions, id: []const u8) ?usize {
    if (std.mem.eql(u8, id, module.id)) return 0;
    if (loader.dependency_graph) |graph| return graphRowForId(module, graph, id);
    if (findDependencyOrdinal(module, id)) |ordinal| return ordinal + 1;
    return null;
}

fn moduleWindowIndex(loader: ast.ModuleLoaderOptions, name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "main")) return 0;
    for (loader.extra_load_windows, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, name)) return index + 1;
    }
    return null;
}

fn findManifestDependency(manifest: ast.ModuleDiskManifestOptions, id: []const u8) ?ast.ModuleDiskManifestDependency {
    for (manifest.deps) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
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

fn cbmFilenameByte(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - 32;
    return ch;
}

fn writeRegistryJson(w: anytype, module: ast.ZeroPageModule, registry: ast.ModuleRegistryOptions) !void {
    try w.writeAll(",\n  \"registry\": {\n    \"version\": 1,\n    \"capacity\": ");
    try w.print("{d}", .{registry.capacity});
    try w.writeAll(",\n    \"entries\": [\n");
    try w.writeAll("      { \"ordinal\": 0, \"id\": ");
    try writeJsonString(w, module.id);
    try w.writeAll(", \"role\": \"current\", \"dependency_ordinal\": null, \"initial_state\": \"unloaded\", \"refcount\": 0 }");
    for (module.deps, 0..) |dep, dep_ordinal| {
        try w.writeAll(",\n      { \"ordinal\": ");
        try w.print("{d}", .{dep_ordinal + 1});
        try w.writeAll(", \"id\": ");
        try writeJsonString(w, dep);
        try w.writeAll(", \"role\": \"dependency\", \"dependency_ordinal\": ");
        try w.print("{d}", .{dep_ordinal});
        try w.writeAll(", \"initial_state\": \"unloaded\", \"refcount\": 0 }");
    }
    try w.writeAll("\n    ],\n    \"edges\": [");
    for (module.deps, 0..) |_, dep_ordinal| {
        if (dep_ordinal != 0) try w.writeAll(", ");
        try w.print("{{ \"from\": 0, \"to\": {d}, \"dependency_ordinal\": {d} }}", .{ dep_ordinal + 1, dep_ordinal });
    }
    try w.writeAll("]\n  }");
}

fn writeDiskManifestJson(w: anytype, module: ast.ZeroPageModule, loader: ast.ModuleLoaderOptions, manifest: ast.ModuleDiskManifestOptions) !void {
    try w.writeAll(",\n  \"disk_manifest\": {\n    \"version\": 1,\n    \"entries\": [\n");
    try writeDiskManifestEntryJson(w, 0, module.id, "current", null, manifest.current);
    for (module.deps, 0..) |dep, dep_ordinal| {
        const entry = findManifestDependency(manifest, dep) orelse return error.InvalidZeroPageModuleDiskManifest;
        try w.writeAll(",\n");
        try writeDiskManifestEntryJson(w, dep_ordinal + 1, dep, "dependency", dep_ordinal, entry.filename);
    }
    if (loader.dependency_graph) |graph| {
        for (graph.nodes) |node| {
            if (findDependencyOrdinal(module, node.id) != null) continue;
            const row = graphRowForId(module, graph, node.id) orelse return error.InvalidZeroPageModuleRegistry;
            const entry = findManifestDependency(manifest, node.id) orelse return error.InvalidZeroPageModuleDiskManifest;
            try w.writeAll(",\n");
            try writeDiskManifestEntryJson(w, row, node.id, "transitive", null, entry.filename);
        }
    }
    try w.writeAll("\n    ]\n  }");
}

fn writeDependencyGraphJson(w: anytype, module: ast.ZeroPageModule, graph: ast.ModuleDependencyGraphOptions) !void {
    try w.writeAll(",\n  \"dependency_graph\": {\n    \"version\": 1,\n    \"rows\": [");
    var wrote_row = false;
    for (module.deps, 0..) |dep, dep_ordinal| {
        if (wrote_row) try w.writeAll(",");
        wrote_row = true;
        try writeDependencyGraphRowJson(w, dep_ordinal + 1, dep, "dependency", dep_ordinal);
    }
    for (graph.nodes) |node| {
        if (findDependencyOrdinal(module, node.id) != null) continue;
        if (wrote_row) try w.writeAll(",");
        wrote_row = true;
        const row = graphRowForId(module, graph, node.id) orelse return error.InvalidZeroPageModuleRegistry;
        try writeDependencyGraphRowJson(w, row, node.id, "transitive", null);
    }
    try w.writeAll("\n    ],\n    \"edges\": [");
    var wrote_edge = false;
    for (graph.nodes) |node| {
        const from = graphRowForId(module, graph, node.id) orelse return error.InvalidZeroPageModuleRegistry;
        for (node.deps) |dep| {
            const to = graphRowForId(module, graph, dep) orelse return error.InvalidZeroPageModuleRegistry;
            if (wrote_edge) try w.writeAll(", ");
            wrote_edge = true;
            try w.print("{{ \"from\": {d}, \"to\": {d} }}", .{ from, to });
        }
    }
    try w.writeAll("]\n  }");
}

fn writeDependencyGraphRowJson(w: anytype, row: usize, id: []const u8, role: []const u8, dependency_ordinal: ?usize) !void {
    try w.writeAll("\n      { \"row\": ");
    try w.print("{d}", .{row});
    try w.writeAll(", \"id\": ");
    try writeJsonString(w, id);
    try w.writeAll(", \"role\": ");
    try writeJsonString(w, role);
    try w.writeAll(", \"dependency_ordinal\": ");
    if (dependency_ordinal) |ordinal| {
        try w.print("{d}", .{ordinal});
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(" }");
}

fn writeModuleStateJson(w: anytype, module: ast.ZeroPageModule, loader: ast.ModuleLoaderOptions, state: ast.ModuleStateOptions) !void {
    try w.writeAll(",\n  \"state\": {\n    \"version\": 1,\n    \"current\": { \"mode\": ");
    try writeJsonString(w, moduleStateModeName(state.current.mode));
    if (state.current.mode == .persist_in_reu) {
        try w.writeAll(", \"snapshot_reu_addr\": ");
        try w.print("{d}", .{moduleStateCurrentSnapshotAddr(loader)});
    }
    try w.writeAll(", \"ranges\": [");
    for (state.current.ranges, 0..) |range, index| {
        if (index != 0) try w.writeAll(",");
        try w.print("\n      {{ \"offset\": {d}, \"size\": {d} }}", .{ range.offset, range.size });
    }
    if (state.current.ranges.len != 0) try w.writeAll("\n    ");
    try w.writeAll("] }");
    if (state.deps.len != 0) {
        try w.writeAll(",\n    \"deps\": [");
        var wrote_dep = false;
        for (module.deps, 0..) |dep, dep_ordinal| {
            const dep_state = findModuleStateDependency(state, dep) orelse continue;
            if (wrote_dep) try w.writeAll(",");
            wrote_dep = true;
            try w.writeAll("\n      { \"ordinal\": ");
            try w.print("{d}", .{dep_ordinal});
            try w.writeAll(", \"id\": ");
            try writeJsonString(w, dep);
            try w.writeAll(", \"mode\": ");
            try writeJsonString(w, moduleStateModeName(dep_state.state.mode));
            if (dep_state.state.mode == .persist_in_reu) {
                try w.writeAll(", \"snapshot_reu_addr\": ");
                try w.print("{d}", .{moduleStateDependencySnapshotAddr(loader, dep_ordinal)});
            }
            try w.writeAll(", \"ranges\": [");
            for (dep_state.state.ranges, 0..) |range, index| {
                if (index != 0) try w.writeAll(",");
                try w.print("\n        {{ \"offset\": {d}, \"size\": {d} }}", .{ range.offset, range.size });
            }
            if (dep_state.state.ranges.len != 0) try w.writeAll("\n      ");
            try w.writeAll("] }");
        }
        try w.writeAll("\n    ]");
    }
    try w.writeAll("\n  }");
}

fn moduleStateModeName(mode: ast.ModuleStateMode) []const u8 {
    return switch (mode) {
        .discard_on_unload => "discard_on_unload",
        .persist_in_reu => "persist_in_reu",
    };
}

fn moduleStateCurrentSnapshotAddr(loader: ast.ModuleLoaderOptions) u32 {
    return loader.reu_cache.addr + @as(u32, moduleRegistryRows(loader)) * @as(u32, loader.load_window.size);
}

fn moduleStateDependencySnapshotAddr(loader: ast.ModuleLoaderOptions, dep_ordinal: usize) u32 {
    return loader.reu_cache.addr +
        @as(u32, moduleRegistryRows(loader) + 1 + @as(u16, @intCast(dep_ordinal))) * @as(u32, loader.load_window.size);
}

fn findModuleStateDependency(state: ast.ModuleStateOptions, id: []const u8) ?ast.DependencyModuleState {
    for (state.deps) |dep_state| {
        if (std.mem.eql(u8, dep_state.id, id)) return dep_state;
    }
    return null;
}

fn writeDiskManifestEntryJson(w: anytype, ordinal: usize, id: []const u8, role: []const u8, dependency_ordinal: ?usize, filename: []const u8) !void {
    try w.writeAll("      { \"ordinal\": ");
    try w.print("{d}", .{ordinal});
    try w.writeAll(", \"id\": ");
    try writeJsonString(w, id);
    try w.writeAll(", \"role\": ");
    try writeJsonString(w, role);
    try w.writeAll(", \"dependency_ordinal\": ");
    if (dependency_ordinal) |dep_ordinal| {
        try w.print("{d}", .{dep_ordinal});
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(", \"filename\": ");
    try writeJsonString(w, filename);
    try w.writeAll(", \"cbm_filename\": \"");
    for (filename) |ch| try w.writeByte(cbmFilenameByte(ch));
    try w.writeAll("\" }");
}

fn appendModuleRegistryRecord(allocator: std.mem.Allocator, out: *std.ArrayList(u8), module: ast.ZeroPageModule, registry: ast.ModuleRegistryOptions) !void {
    const entry_count = 1 + module.deps.len;
    if (entry_count > 255) return error.InvalidZeroPageModuleRegistry;
    try out.append(allocator, 1);
    try out.append(allocator, registry.capacity);
    try out.append(allocator, @intCast(entry_count));
    try out.append(allocator, @intCast(module.deps.len));

    try out.append(allocator, 0);
    try appendString(allocator, out, module.id);
    try out.append(allocator, 0);
    try appendLe16(allocator, out, 0xffff);
    try out.append(allocator, 0);
    try out.append(allocator, 0);

    for (module.deps, 0..) |dep, dep_ordinal| {
        try out.append(allocator, @intCast(dep_ordinal + 1));
        try appendString(allocator, out, dep);
        try out.append(allocator, 1);
        try appendLe16(allocator, out, @intCast(dep_ordinal));
        try out.append(allocator, 0);
        try out.append(allocator, 0);
    }
    for (module.deps, 0..) |_, dep_ordinal| {
        try out.append(allocator, 0);
        try out.append(allocator, @intCast(dep_ordinal + 1));
        try appendLe16(allocator, out, @intCast(dep_ordinal));
    }
}

fn appendModuleDiskManifestRecord(allocator: std.mem.Allocator, out: *std.ArrayList(u8), module: ast.ZeroPageModule, loader: ast.ModuleLoaderOptions, manifest: ast.ModuleDiskManifestOptions) !void {
    const entry_count = 1 + moduleGraphNodeCount(module, loader.dependency_graph);
    if (entry_count > 255) return error.InvalidZeroPageModuleDiskManifest;
    try out.append(allocator, 1);
    try out.append(allocator, @intCast(entry_count));
    try appendModuleDiskManifestEntry(allocator, out, 0, module.id, 0, null, manifest.current);
    for (module.deps, 0..) |dep, dep_ordinal| {
        const entry = findManifestDependency(manifest, dep) orelse return error.InvalidZeroPageModuleDiskManifest;
        try appendModuleDiskManifestEntry(allocator, out, dep_ordinal + 1, dep, 1, dep_ordinal, entry.filename);
    }
    if (loader.dependency_graph) |graph| {
        for (graph.nodes) |node| {
            if (findDependencyOrdinal(module, node.id) != null) continue;
            const row = graphRowForId(module, graph, node.id) orelse return error.InvalidZeroPageModuleRegistry;
            const entry = findManifestDependency(manifest, node.id) orelse return error.InvalidZeroPageModuleDiskManifest;
            try appendModuleDiskManifestEntry(allocator, out, row, node.id, 2, null, entry.filename);
        }
    }
}

fn appendModuleDependencyGraphRecord(allocator: std.mem.Allocator, out: *std.ArrayList(u8), module: ast.ZeroPageModule, graph: ast.ModuleDependencyGraphOptions) !void {
    const row_count = graph.nodes.len;
    if (row_count > 255) return error.InvalidZeroPageModuleRegistry;
    var edge_count: usize = 0;
    for (graph.nodes) |node| edge_count += node.deps.len;
    if (edge_count > 255) return error.InvalidZeroPageModuleRegistry;
    try out.append(allocator, 1);
    try out.append(allocator, @intCast(row_count));
    try out.append(allocator, @intCast(edge_count));
    for (module.deps, 0..) |dep, dep_ordinal| {
        try appendModuleDependencyGraphRow(allocator, out, dep_ordinal + 1, dep, 1, dep_ordinal);
    }
    for (graph.nodes) |node| {
        if (findDependencyOrdinal(module, node.id) != null) continue;
        const row = graphRowForId(module, graph, node.id) orelse return error.InvalidZeroPageModuleRegistry;
        try appendModuleDependencyGraphRow(allocator, out, row, node.id, 2, null);
    }
    for (graph.nodes) |node| {
        const from = graphRowForId(module, graph, node.id) orelse return error.InvalidZeroPageModuleRegistry;
        for (node.deps) |dep| {
            const to = graphRowForId(module, graph, dep) orelse return error.InvalidZeroPageModuleRegistry;
            try out.append(allocator, @intCast(from));
            try out.append(allocator, @intCast(to));
        }
    }
}

fn appendModuleDependencyGraphRow(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    row: usize,
    id: []const u8,
    role: u8,
    dependency_ordinal: ?usize,
) !void {
    try out.append(allocator, @intCast(row));
    try out.append(allocator, role);
    try appendLe16(allocator, out, if (dependency_ordinal) |ordinal| @intCast(ordinal) else 0xffff);
    try appendString(allocator, out, id);
}

fn appendModuleStateRecord(allocator: std.mem.Allocator, out: *std.ArrayList(u8), module: ast.ZeroPageModule, loader: ast.ModuleLoaderOptions, state: ast.ModuleStateOptions) !void {
    try out.append(allocator, 1);
    try out.append(allocator, switch (state.current.mode) {
        .discard_on_unload => 0,
        .persist_in_reu => 1,
    });
    if (state.current.ranges.len > 255) return error.InvalidZeroPageModuleState;
    try out.append(allocator, @intCast(state.current.ranges.len));
    try appendLe32(allocator, out, if (state.current.mode == .persist_in_reu) moduleStateCurrentSnapshotAddr(loader) else 0);
    for (state.current.ranges) |range| {
        try appendLe16(allocator, out, range.offset);
        try appendLe16(allocator, out, range.size);
    }
    if (state.deps.len > 255) return error.InvalidZeroPageModuleState;
    try out.append(allocator, @intCast(state.deps.len));
    for (module.deps, 0..) |dep, dep_ordinal| {
        const dep_state = findModuleStateDependency(state, dep) orelse continue;
        try out.append(allocator, @intCast(dep_ordinal));
        try appendString(allocator, out, dep);
        try out.append(allocator, switch (dep_state.state.mode) {
            .discard_on_unload => 0,
            .persist_in_reu => 1,
        });
        if (dep_state.state.ranges.len > 255) return error.InvalidZeroPageModuleState;
        try out.append(allocator, @intCast(dep_state.state.ranges.len));
        try appendLe32(allocator, out, if (dep_state.state.mode == .persist_in_reu) moduleStateDependencySnapshotAddr(loader, dep_ordinal) else 0);
        for (dep_state.state.ranges) |range| {
            try appendLe16(allocator, out, range.offset);
            try appendLe16(allocator, out, range.size);
        }
    }
}

fn appendModuleDiskManifestEntry(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ordinal: usize,
    id: []const u8,
    role: u8,
    dependency_ordinal: ?usize,
    filename: []const u8,
) !void {
    try out.append(allocator, @intCast(ordinal));
    try out.append(allocator, role);
    try appendLe16(allocator, out, if (dependency_ordinal) |dep_ordinal| @intCast(dep_ordinal) else 0xffff);
    try appendString(allocator, out, id);
    try appendString(allocator, out, filename);
    try appendLe16(allocator, out, @intCast(filename.len));
    for (filename) |ch| try out.append(allocator, cbmFilenameByte(ch));
}

fn moduleLoadModeName(mode: ast.ModuleLoadMode) []const u8 {
    return switch (mode) {
        .manual => "manual",
        .preload => "preload",
        .on_demand => "on_demand",
    };
}

const PayloadRange = struct {
    start: u16,
    end: u16,
};

fn selectModulePayloadRange(allocator: std.mem.Allocator, program: ast.Program, module: ast.ZeroPageModule, sections: []const Section, load_address: u16, prg_bytes: usize) !?PayloadRange {
    var reachable = try collectReachableModuleFunctions(allocator, program, module);
    defer reachable.deinit();

    var selected: ?PayloadRange = null;
    const final_end = prgEnd(load_address, prg_bytes);
    for (sections) |section| {
        if (!sectionContributesToModulePayload(section, &reachable)) continue;
        const start = sectionStart(section) orelse continue;
        const end = sectionEnd(section, final_end) orelse continue;
        if (end < start) continue;
        if (selected) |*range| {
            range.start = @min(range.start, start);
            range.end = @max(range.end, end);
        } else {
            selected = .{ .start = start, .end = end };
        }
    }
    return selected;
}

fn sectionContributesToModulePayload(section: Section, reachable: *const std.StringHashMap(void)) bool {
    if (std.mem.eql(u8, section.kind, "rodata")) return true;
    if (std.mem.eql(u8, section.owner, "compiler") and std.mem.eql(u8, section.kind, "scratch")) return true;
    if (std.mem.eql(u8, section.owner, "runtime") and std.mem.eql(u8, section.kind, "data")) return true;
    if (!std.mem.eql(u8, section.kind, "code")) return false;
    if (!std.mem.startsWith(u8, section.owner, "function:")) return false;
    const owner_function = section.owner["function:".len..];
    return reachable.contains(owner_function);
}

fn moduleExportKernalPolicy(allocator: std.mem.Allocator, program: ast.Program, root: ast.Function) !KernalExportPolicy {
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();
    return try functionKernalExportPolicy(allocator, program, root, &visited);
}

fn functionKernalExportPolicy(
    allocator: std.mem.Allocator,
    program: ast.Program,
    function: ast.Function,
    visited: *std.StringHashMap(void),
) anyerror!KernalExportPolicy {
    if (visited.contains(function.name)) return .none;
    try visited.put(function.name, {});
    return try stmtsKernalExportPolicy(allocator, program, function.body, visited);
}

fn stmtsKernalExportPolicy(
    allocator: std.mem.Allocator,
    program: ast.Program,
    statements: []const ast.Stmt,
    visited: *std.StringHashMap(void),
) anyerror!KernalExportPolicy {
    var policy: KernalExportPolicy = .none;
    for (statements) |stmt| {
        policy = policy.combine(try stmtKernalExportPolicy(allocator, program, stmt, visited));
        if (policy == .unsupported) return policy;
    }
    return policy;
}

fn stmtKernalExportPolicy(
    allocator: std.mem.Allocator,
    program: ast.Program,
    stmt: ast.Stmt,
    visited: *std.StringHashMap(void),
) anyerror!KernalExportPolicy {
    return switch (stmt) {
        .builtin => |builtin| try builtinKernalExportPolicy(allocator, program, builtin, visited),
        .var_decl => |decl| try exprKernalExportPolicy(allocator, program, decl.init, visited),
        .assign => |assign| try exprKernalExportPolicy(allocator, program, assign.value, visited),
        inline .add_assign, .sub_assign, .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => |assign| try exprKernalExportPolicy(allocator, program, assign.value, visited),
        .deref_assign => |assign| (try exprKernalExportPolicy(allocator, program, assign.target, visited)).combine(try exprKernalExportPolicy(allocator, program, assign.value, visited)),
        .array_assign, .array_add_assign, .array_sub_assign, .array_mul_assign, .array_bit_and_assign, .array_bit_or_assign, .array_bit_xor_assign, .array_shl_assign, .array_shr_assign => |assign| (try exprKernalExportPolicy(allocator, program, assign.index, visited)).combine(try exprKernalExportPolicy(allocator, program, assign.value, visited)),
        .array_field_assign => |assign| (try exprKernalExportPolicy(allocator, program, assign.index, visited)).combine(try exprKernalExportPolicy(allocator, program, assign.value, visited)),
        .while_stmt => |while_stmt| (try exprKernalExportPolicy(allocator, program, while_stmt.condition, visited)).combine(try stmtsKernalExportPolicy(allocator, program, while_stmt.body, visited)),
        .for_stmt => |for_stmt| try stmtsKernalExportPolicy(allocator, program, for_stmt.body, visited),
        .switch_stmt => |switch_stmt| blk: {
            var policy = try exprKernalExportPolicy(allocator, program, switch_stmt.operand, visited);
            for (switch_stmt.prongs) |prong| {
                policy = policy.combine(try stmtsKernalExportPolicy(allocator, program, prong.body, visited));
                if (policy == .unsupported) break;
            }
            break :blk policy;
        },
        .if_stmt => |if_stmt| (try exprKernalExportPolicy(allocator, program, if_stmt.condition, visited)).combine(try stmtsKernalExportPolicy(allocator, program, if_stmt.then_body, visited)).combine(try stmtsKernalExportPolicy(allocator, program, if_stmt.else_body, visited)),
        .call => |call| try callKernalExportPolicy(allocator, program, call, visited),
        .discard, .return_expr => |expr| try exprKernalExportPolicy(allocator, program, expr, visited),
        .break_expr => |break_expr| try exprKernalExportPolicy(allocator, program, break_expr.value, visited),
        .field_assign => |field| try exprKernalExportPolicy(allocator, program, field.value, visited),
        .heap_free => |free| try exprKernalExportPolicy(allocator, program, free.ptr.*, visited),
        .test6502 => |call| try test6502CallKernalExportPolicy(allocator, program, call, visited),
        .struct_var => |struct_var| blk: {
            var policy: KernalExportPolicy = .none;
            for (struct_var.fields) |field| {
                policy = policy.combine(try exprKernalExportPolicy(allocator, program, field.value, visited));
                if (policy == .unsupported) break;
            }
            break :blk policy;
        },
        .inline_asm => .unsupported,
        .reu, .reu_heap_reset, .heap_reset, .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph, .string_var, .string_assign, .break_stmt, .continue_stmt => .none,
    };
}

fn exprKernalExportPolicy(
    allocator: std.mem.Allocator,
    program: ast.Program,
    expr: ast.Expr,
    visited: *std.StringHashMap(void),
) anyerror!KernalExportPolicy {
    return switch (expr) {
        .c64_read_petscii, .c64_wait_petscii, .module_disk_load => .unsupported,
        inline .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| (try exprKernalExportPolicy(allocator, program, binary.lhs.*, visited)).combine(try exprKernalExportPolicy(allocator, program, binary.rhs.*, visited)),
        .bit_not, .not, .deref, .ptr_from_int, .int_from_ptr => |child| try exprKernalExportPolicy(allocator, program, child.*, visited),
        .as_cast => |as_cast| try exprKernalExportPolicy(allocator, program, as_cast.expr.*, visited),
        .reu_compare => |transfer| (try exprKernalExportPolicy(allocator, program, transfer.c64_addr.*, visited)).combine(try exprKernalExportPolicy(allocator, program, transfer.len.*, visited)),
        .reu_heap_alloc => |alloc| try exprKernalExportPolicy(allocator, program, alloc.len.*, visited),
        .reu_view => |view| try exprKernalExportPolicy(allocator, program, view.far.*, visited),
        .far_view_materialize_range => |range| try exprKernalExportPolicy(allocator, program, range.start.*, visited),
        .module_call => |call| blk: {
            var policy: KernalExportPolicy = .none;
            for (call.args) |arg| {
                policy = policy.combine(try exprKernalExportPolicy(allocator, program, arg, visited));
                if (policy == .unsupported) break;
            }
            break :blk policy;
        },
        .heap_alloc => |alloc| try exprKernalExportPolicy(allocator, program, alloc.len.*, visited),
        .if_expr => |if_expr| (try exprKernalExportPolicy(allocator, program, if_expr.condition.*, visited)).combine(try exprKernalExportPolicy(allocator, program, if_expr.then_expr.*, visited)).combine(try exprKernalExportPolicy(allocator, program, if_expr.else_expr.*, visited)),
        .switch_expr => |switch_expr| blk: {
            var policy = try exprKernalExportPolicy(allocator, program, switch_expr.operand.*, visited);
            for (switch_expr.prongs) |prong| {
                policy = policy.combine(try exprKernalExportPolicy(allocator, program, prong.value, visited));
                if (policy == .unsupported) break;
            }
            break :blk policy;
        },
        .block_expr => |block_expr| try stmtsKernalExportPolicy(allocator, program, block_expr.body, visited),
        .call => |call| try callKernalExportPolicy(allocator, program, call, visited),
        .array_literal => |literal| blk: {
            var policy: KernalExportPolicy = .none;
            for (literal.values) |value| {
                policy = policy.combine(try exprKernalExportPolicy(allocator, program, value, visited));
                if (policy == .unsupported) break;
            }
            break :blk policy;
        },
        .array_index => |index| try exprKernalExportPolicy(allocator, program, index.index.*, visited),
        .array_field_index => |index| try exprKernalExportPolicy(allocator, program, index.index.*, visited),
        .struct_literal => |literal| blk: {
            var policy: KernalExportPolicy = .none;
            for (literal.fields) |field| {
                policy = policy.combine(try exprKernalExportPolicy(allocator, program, field.value, visited));
                if (policy == .unsupported) break;
            }
            break :blk policy;
        },
        .value, .size_of, .align_of, .offset_of, .reu_present, .address_of, .far_view_materialize, .module_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded => .none,
    };
}

fn callKernalExportPolicy(
    allocator: std.mem.Allocator,
    program: ast.Program,
    call: ast.CallExpr,
    visited: *std.StringHashMap(void),
) !KernalExportPolicy {
    var policy: KernalExportPolicy = .none;
    if (findFunctionForCall(program, call.target)) |function| {
        policy = policy.combine(try functionKernalExportPolicy(allocator, program, function, visited));
        if (policy == .unsupported) return policy;
    }
    for (call.args) |arg| {
        policy = policy.combine(try exprKernalExportPolicy(allocator, program, arg, visited));
        if (policy == .unsupported) return policy;
    }
    return policy;
}

fn builtinKernalExportPolicy(
    allocator: std.mem.Allocator,
    program: ast.Program,
    builtin: ast.BuiltinCall,
    visited: *std.StringHashMap(void),
) anyerror!KernalExportPolicy {
    return switch (builtin) {
        .console_clear => .trampoline_safe,
        .console_print => |print| blk: {
            var policy: KernalExportPolicy = .trampoline_safe;
            for (print.args) |arg| switch (arg) {
                .string => {},
                .value => |expr| {
                    policy = policy.combine(try exprKernalExportPolicy(allocator, program, expr, visited));
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

fn test6502CallKernalExportPolicy(
    allocator: std.mem.Allocator,
    program: ast.Program,
    call: ast.Test6502Call,
    visited: *std.StringHashMap(void),
) anyerror!KernalExportPolicy {
    return switch (call) {
        .expect_equal_u8, .expect_equal_i8, .expect_equal_bool => |expect| try exprKernalExportPolicy(allocator, program, expect.actual, visited),
        .expect_equal_u16, .expect_some_ptr => |expect| try exprKernalExportPolicy(allocator, program, expect.actual, visited),
        .expect_null => |expect| try exprKernalExportPolicy(allocator, program, expect.actual, visited),
        .expect_some_u8 => |expect| try exprKernalExportPolicy(allocator, program, expect.actual, visited),
        .expect_some_u16 => |expect| try exprKernalExportPolicy(allocator, program, expect.actual, visited),
        .expect_some_bool => |expect| try exprKernalExportPolicy(allocator, program, expect.actual, visited),
        .expect_string => .none,
        else => .none,
    };
}

fn moduleExportRequiresKernalRom(allocator: std.mem.Allocator, program: ast.Program, root: ast.Function) !bool {
    return (try moduleExportKernalPolicy(allocator, program, root)).requiresKernalRom();
}

fn moduleExportRequiresKernalRomLegacy(allocator: std.mem.Allocator, program: ast.Program, root: ast.Function) !bool {
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();
    return try functionRequiresKernalRom(allocator, program, root, &visited);
}

fn functionRequiresKernalRom(
    allocator: std.mem.Allocator,
    program: ast.Program,
    function: ast.Function,
    visited: *std.StringHashMap(void),
) anyerror!bool {
    if (visited.contains(function.name)) return false;
    try visited.put(function.name, {});
    return try stmtsRequireKernalRom(allocator, program, function.body, visited);
}

fn stmtsRequireKernalRom(
    allocator: std.mem.Allocator,
    program: ast.Program,
    statements: []const ast.Stmt,
    visited: *std.StringHashMap(void),
) anyerror!bool {
    for (statements) |stmt| {
        if (try stmtRequiresKernalRom(allocator, program, stmt, visited)) return true;
    }
    return false;
}

fn stmtRequiresKernalRom(
    allocator: std.mem.Allocator,
    program: ast.Program,
    stmt: ast.Stmt,
    visited: *std.StringHashMap(void),
) anyerror!bool {
    return switch (stmt) {
        .builtin => |builtin| builtinRequiresKernalRom(builtin),
        .var_decl => |decl| try exprRequiresKernalRom(allocator, program, decl.init, visited),
        .assign => |assign| try exprRequiresKernalRom(allocator, program, assign.value, visited),
        inline .add_assign, .sub_assign, .mul_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign, .shl_assign, .shr_assign => |assign| try exprRequiresKernalRom(allocator, program, assign.value, visited),
        .deref_assign => |assign| (try exprRequiresKernalRom(allocator, program, assign.target, visited)) or (try exprRequiresKernalRom(allocator, program, assign.value, visited)),
        .array_assign, .array_add_assign, .array_sub_assign, .array_mul_assign, .array_bit_and_assign, .array_bit_or_assign, .array_bit_xor_assign, .array_shl_assign, .array_shr_assign => |assign| (try exprRequiresKernalRom(allocator, program, assign.index, visited)) or (try exprRequiresKernalRom(allocator, program, assign.value, visited)),
        .array_field_assign => |assign| (try exprRequiresKernalRom(allocator, program, assign.index, visited)) or (try exprRequiresKernalRom(allocator, program, assign.value, visited)),
        .while_stmt => |while_stmt| (try exprRequiresKernalRom(allocator, program, while_stmt.condition, visited)) or (try stmtsRequireKernalRom(allocator, program, while_stmt.body, visited)),
        .for_stmt => |for_stmt| try stmtsRequireKernalRom(allocator, program, for_stmt.body, visited),
        .switch_stmt => |switch_stmt| blk: {
            if (try exprRequiresKernalRom(allocator, program, switch_stmt.operand, visited)) break :blk true;
            for (switch_stmt.prongs) |prong| {
                if (try stmtsRequireKernalRom(allocator, program, prong.body, visited)) break :blk true;
            }
            break :blk false;
        },
        .if_stmt => |if_stmt| (try exprRequiresKernalRom(allocator, program, if_stmt.condition, visited)) or
            (try stmtsRequireKernalRom(allocator, program, if_stmt.then_body, visited)) or
            (try stmtsRequireKernalRom(allocator, program, if_stmt.else_body, visited)),
        .call => |call| try callRequiresKernalRom(allocator, program, call, visited),
        .discard, .return_expr => |expr| try exprRequiresKernalRom(allocator, program, expr, visited),
        .break_expr => |break_expr| try exprRequiresKernalRom(allocator, program, break_expr.value, visited),
        .field_assign => |field| try exprRequiresKernalRom(allocator, program, field.value, visited),
        .heap_free => |free| try exprRequiresKernalRom(allocator, program, free.ptr.*, visited),
        .test6502 => |call| test6502CallRequiresKernalRom(allocator, program, call, visited),
        .struct_var => |struct_var| blk: {
            for (struct_var.fields) |field| if (try exprRequiresKernalRom(allocator, program, field.value, visited)) break :blk true;
            break :blk false;
        },
        .inline_asm, .reu, .reu_heap_reset, .heap_reset, .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph, .string_var, .string_assign, .break_stmt, .continue_stmt => false,
    };
}

fn exprRequiresKernalRom(
    allocator: std.mem.Allocator,
    program: ast.Program,
    expr: ast.Expr,
    visited: *std.StringHashMap(void),
) anyerror!bool {
    return switch (expr) {
        .c64_read_petscii, .c64_wait_petscii, .module_disk_load => true,
        inline .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| (try exprRequiresKernalRom(allocator, program, binary.lhs.*, visited)) or (try exprRequiresKernalRom(allocator, program, binary.rhs.*, visited)),
        .bit_not, .not, .deref, .ptr_from_int, .int_from_ptr => |child| try exprRequiresKernalRom(allocator, program, child.*, visited),
        .as_cast => |as_cast| try exprRequiresKernalRom(allocator, program, as_cast.expr.*, visited),
        .reu_compare => |transfer| (try exprRequiresKernalRom(allocator, program, transfer.c64_addr.*, visited)) or (try exprRequiresKernalRom(allocator, program, transfer.len.*, visited)),
        .reu_heap_alloc => |alloc| try exprRequiresKernalRom(allocator, program, alloc.len.*, visited),
        .reu_view => |view| try exprRequiresKernalRom(allocator, program, view.far.*, visited),
        .far_view_materialize_range => |range| try exprRequiresKernalRom(allocator, program, range.start.*, visited),
        .module_call => |call| blk: {
            for (call.args) |arg| if (try exprRequiresKernalRom(allocator, program, arg, visited)) break :blk true;
            break :blk false;
        },
        .heap_alloc => |alloc| try exprRequiresKernalRom(allocator, program, alloc.len.*, visited),
        .if_expr => |if_expr| (try exprRequiresKernalRom(allocator, program, if_expr.condition.*, visited)) or
            (try exprRequiresKernalRom(allocator, program, if_expr.then_expr.*, visited)) or
            (try exprRequiresKernalRom(allocator, program, if_expr.else_expr.*, visited)),
        .switch_expr => |switch_expr| blk: {
            if (try exprRequiresKernalRom(allocator, program, switch_expr.operand.*, visited)) break :blk true;
            for (switch_expr.prongs) |prong| if (try exprRequiresKernalRom(allocator, program, prong.value, visited)) break :blk true;
            break :blk false;
        },
        .block_expr => |block_expr| try stmtsRequireKernalRom(allocator, program, block_expr.body, visited),
        .call => |call| try callRequiresKernalRom(allocator, program, call, visited),
        .array_literal => |literal| blk: {
            for (literal.values) |value| if (try exprRequiresKernalRom(allocator, program, value, visited)) break :blk true;
            break :blk false;
        },
        .array_index => |index| try exprRequiresKernalRom(allocator, program, index.index.*, visited),
        .array_field_index => |index| try exprRequiresKernalRom(allocator, program, index.index.*, visited),
        .struct_literal => |literal| blk: {
            for (literal.fields) |field| if (try exprRequiresKernalRom(allocator, program, field.value, visited)) break :blk true;
            break :blk false;
        },
        .value, .size_of, .align_of, .offset_of, .reu_present, .address_of, .far_view_materialize, .module_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded => false,
    };
}

fn callRequiresKernalRom(
    allocator: std.mem.Allocator,
    program: ast.Program,
    call: ast.CallExpr,
    visited: *std.StringHashMap(void),
) !bool {
    if (findFunctionForCall(program, call.target)) |function| {
        if (try functionRequiresKernalRom(allocator, program, function, visited)) return true;
    }
    for (call.args) |arg| if (try exprRequiresKernalRom(allocator, program, arg, visited)) return true;
    return false;
}

fn builtinRequiresKernalRom(builtin: ast.BuiltinCall) bool {
    return switch (builtin) {
        .console_clear, .console_print, .console_puts, .kernal_puts, .kernal_set_name => true,
        .screen_clear, .puts_at, .put_at, .hex_at, .hex16_at, .string_append, .string_clear, .sleep_ticks, .sleep_frames => false,
    };
}

fn test6502CallRequiresKernalRom(
    allocator: std.mem.Allocator,
    program: ast.Program,
    call: ast.Test6502Call,
    visited: *std.StringHashMap(void),
) anyerror!bool {
    return switch (call) {
        .expect_equal_u8, .expect_equal_i8, .expect_equal_bool => |expect| try exprRequiresKernalRom(allocator, program, expect.actual, visited),
        .expect_equal_u16, .expect_some_ptr => |expect| try exprRequiresKernalRom(allocator, program, expect.actual, visited),
        .expect_null => |expect| try exprRequiresKernalRom(allocator, program, expect.actual, visited),
        .expect_some_u8 => |expect| try exprRequiresKernalRom(allocator, program, expect.actual, visited),
        .expect_some_u16 => |expect| try exprRequiresKernalRom(allocator, program, expect.actual, visited),
        .expect_some_bool => |expect| try exprRequiresKernalRom(allocator, program, expect.actual, visited),
        .expect_string => false,
        else => false,
    };
}

const collectReachableModuleFunctions = reachability.collectModule;
const findFunctionForCall = reachability.findFunctionForCall;

fn collectRelocations(
    allocator: std.mem.Allocator,
    asm_text: []const u8,
    label_map: *const LabelMap,
    sections: []const Section,
    payload_range: ?PayloadRange,
    jump_table_bytes: u32,
) !std.ArrayList(Relocation) {
    var relocations: std.ArrayList(Relocation) = .empty;
    errdefer {
        for (relocations.items) |relocation| relocation.deinit(allocator);
        relocations.deinit(allocator);
    }
    const range = payload_range orelse return relocations;

    var lines = std.mem.splitScalar(u8, asm_text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        const marker = try parseRelocationMarker(line) orelse continue;
        const anchor_addr = label_map.map.get(marker.anchor) orelse return error.InvalidZeroPageModuleRelocation;
        const operand_addr = anchor_addr +% 1;
        const operand_size: u16 = switch (marker.kind) {
            .abs16 => 2,
            .lo8, .hi8 => 1,
        };
        if (operand_addr < range.start or operand_addr + operand_size > range.end) continue;
        const target_section = try relocationTargetSection(sections, label_map, marker.target);
        if (label_map.map.get(marker.target)) |target_addr| {
            if (target_addr < range.start or target_addr >= range.end) return error.InvalidZeroPageModuleRelocation;
        }
        try relocations.append(allocator, .{
            .payload_offset = jump_table_bytes + @as(u32, operand_addr - range.start),
            .kind = marker.kind,
            .target = try allocator.dupe(u8, marker.target),
            .target_section = target_section,
            .addend = marker.addend,
        });
    }

    return relocations;
}

fn relocationTargetSection(sections: []const Section, label_map: *const LabelMap, target: []const u8) !?u16 {
    const target_addr = label_map.map.get(target) orelse return null;
    for (sections, 0..) |section, index| {
        const start = sectionStart(section) orelse continue;
        const end = section.end_address orelse 0xffff;
        if (target_addr >= start and target_addr < end) return @intCast(index);
    }
    return null;
}

fn parseRelocationMarker(line: []const u8) !?RelocationMarker {
    const prefix = "; zeropage_relocation ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var kind: ?RelocationKind = null;
    var anchor: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var addend: i16 = 0;

    var parts = std.mem.tokenizeScalar(u8, line[prefix.len..], ' ');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = part[0..eq];
        const value = part[eq + 1 ..];
        if (std.mem.eql(u8, key, "kind")) {
            if (std.mem.eql(u8, value, "abs16")) {
                kind = .abs16;
            } else if (std.mem.eql(u8, value, "lo8")) {
                kind = .lo8;
            } else if (std.mem.eql(u8, value, "hi8")) {
                kind = .hi8;
            } else {
                return error.UnsupportedZeroPageModuleRelocation;
            }
        } else if (std.mem.eql(u8, key, "anchor")) {
            anchor = value;
        } else if (std.mem.eql(u8, key, "target")) {
            target = value;
        } else if (std.mem.eql(u8, key, "addend")) {
            addend = try std.fmt.parseInt(i16, value, 10);
        }
    }

    return .{
        .kind = kind orelse return error.InvalidZeroPageModuleRelocation,
        .anchor = anchor orelse return error.InvalidZeroPageModuleRelocation,
        .target = target orelse return error.InvalidZeroPageModuleRelocation,
        .addend = addend,
    };
}

fn relocationKindName(kind: RelocationKind) []const u8 {
    return switch (kind) {
        .abs16 => "abs16",
        .lo8 => "lo8",
        .hi8 => "hi8",
    };
}

fn appendString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try appendLe16(allocator, out, @intCast(text.len));
    try out.appendSlice(allocator, text);
}

fn appendNullableU16(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: ?u16) !void {
    try appendLe16(allocator, out, value orelse 0xffff);
}

fn appendLe16(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u16) !void {
    try out.append(allocator, @intCast(value & 0x00ff));
    try out.append(allocator, @intCast(value >> 8));
}

fn appendLe32(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    try out.append(allocator, @intCast(value & 0x000000ff));
    try out.append(allocator, @intCast((value >> 8) & 0x000000ff));
    try out.append(allocator, @intCast((value >> 16) & 0x000000ff));
    try out.append(allocator, @intCast((value >> 24) & 0x000000ff));
}

fn patchLe16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @intCast(value & 0x00ff);
    bytes[offset + 1] = @intCast(value >> 8);
}

fn patchLe32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @intCast(value & 0x000000ff);
    bytes[offset + 1] = @intCast((value >> 8) & 0x000000ff);
    bytes[offset + 2] = @intCast((value >> 16) & 0x000000ff);
    bytes[offset + 3] = @intCast((value >> 24) & 0x000000ff);
}

fn moduleBinaryChecksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    for (bytes, 0..) |byte, index| {
        if (index == module_binary_checksum_offset or index == module_binary_checksum_offset + 1) continue;
        sum = (sum + byte) & 0xffff;
    }
    return @intCast(sum);
}

fn readLe16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn readLe32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn readBinaryString(bytes: []const u8, cursor: *usize) []const u8 {
    const len = readLe16(bytes, cursor.*);
    cursor.* += 2;
    const text = bytes[cursor.* .. cursor.* + len];
    cursor.* += len;
    return text;
}

fn framePolicyByte(policy: ast.FramePolicy) u8 {
    return switch (policy) {
        .static => 0,
        .stack => 1,
        .auto => 2,
    };
}

fn typeByte(program: ast.Program, ty: ast.Type) !u8 {
    return switch (ty) {
        .void => 0,
        .bool => 1,
        .u8 => 2,
        .i8 => 3,
        .u16 => 4,
        .i16 => 5,
        .usize => 6,
        .pointer => 7,
        .custom => |name| if (program.findEnum(name) != null) 8 else error.UnsupportedZeroPageModuleExport,
        else => error.UnsupportedZeroPageModuleExport,
    };
}

fn parseSections(allocator: std.mem.Allocator, asm_text: []const u8, label_map: *const LabelMap) !std.ArrayList(Section) {
    var sections: std.ArrayList(Section) = .empty;
    var pending_end: std.ArrayList(usize) = .empty;
    defer pending_end.deinit(allocator);
    errdefer {
        for (sections.items) |*section| section.deinit(allocator);
        sections.deinit(allocator);
    }

    var active: ?usize = null;
    var lines = std.mem.splitScalar(u8, asm_text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (try parseBegin(line)) |marker| {
            var section = Section{
                .owner = try allocator.dupe(u8, marker.owner),
                .kind = try allocator.dupe(u8, marker.kind),
                .lifetime = try allocator.dupe(u8, marker.lifetime orelse "static"),
                .address_space = try allocator.dupe(u8, marker.address_space orelse "near"),
                .end_address = null,
                .labels = .empty,
            };
            errdefer section.deinit(allocator);
            try sections.append(allocator, section);
            active = sections.items.len - 1;
            continue;
        }
        if (parseEnd(line) != null) {
            if (active) |section_index| {
                if (sectionStart(sections.items[section_index]) != null) {
                    try pending_end.append(allocator, section_index);
                }
            }
            active = null;
            continue;
        }
        if (parseAsmLabel(line)) |name| {
            if (label_map.map.get(name)) |addr| {
                for (pending_end.items) |section_index| {
                    if (sections.items[section_index].end_address == null) {
                        sections.items[section_index].end_address = addr;
                    }
                }
                pending_end.clearRetainingCapacity();
                if (active) |section_index| {
                    try sections.items[section_index].labels.append(allocator, .{
                        .name = try allocator.dupe(u8, name),
                        .address = addr,
                    });
                }
            }
        }
    }

    for (sections.items) |*section| {
        std.mem.sort(Label, section.labels.items, {}, compareLabels);
    }
    return sections;
}

fn compareLabels(_: void, a: Label, b: Label) bool {
    if (a.address != b.address) return a.address < b.address;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn parseBegin(line: []const u8) !?SectionMarker {
    const prefix = "; zeropage_section_begin ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    return try parseMarkerFields(line[prefix.len..], true);
}

fn parseEnd(line: []const u8) ?SectionMarker {
    const prefix = "; zeropage_section_end ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    return parseMarkerFields(line[prefix.len..], false) catch null;
}

fn parseMarkerFields(text: []const u8, require_lifetime: bool) !SectionMarker {
    var marker = SectionMarker{ .owner = "", .kind = "" };
    var parts = std.mem.tokenizeScalar(u8, text, ' ');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = part[0..eq];
        const value = part[eq + 1 ..];
        if (std.mem.eql(u8, key, "owner")) {
            marker.owner = value;
        } else if (std.mem.eql(u8, key, "kind")) {
            marker.kind = value;
        } else if (std.mem.eql(u8, key, "lifetime")) {
            marker.lifetime = value;
        } else if (std.mem.eql(u8, key, "address")) {
            marker.address_space = value;
        }
    }
    if (marker.owner.len == 0 or marker.kind.len == 0) return error.InvalidSectionMarker;
    if (require_lifetime and (marker.lifetime == null or marker.address_space == null)) return error.InvalidSectionMarker;
    return marker;
}

fn parseAsmLabel(line: []const u8) ?[]const u8 {
    if (line.len == 0 or std.ascii.isWhitespace(line[0])) return null;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    if (colon == 0) return null;
    const name = line[0..colon];
    for (name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.')) return null;
    }
    return if (std.mem.startsWith(u8, name, ".")) name[1..] else name;
}

fn sectionStart(section: Section) ?u16 {
    if (section.labels.items.len == 0) return null;
    return section.labels.items[0].address;
}

fn sectionEnd(section: Section, final_end: u16) ?u16 {
    if (sectionStart(section) == null) return null;
    return section.end_address orelse final_end;
}

fn prgEnd(load_address: u16, prg_bytes: usize) u16 {
    const payload_bytes = if (prg_bytes >= 2) prg_bytes - 2 else 0;
    const end = @as(u32, load_address) + @as(u32, @intCast(payload_bytes));
    return @as(u16, @intCast(@min(end, 0xffff)));
}

fn writeJsonNullableU16(writer: anytype, value: ?u16) !void {
    if (value) |addr| {
        try writer.print("{d}", .{addr});
    } else {
        try writer.writeAll("null");
    }
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (ch < 0x20)
                try writer.print("\\u{x:0>4}", .{ch})
            else
                try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

fn writeJsonByteArray(writer: anytype, bytes: [2]u8, size: u8) !void {
    try writer.writeByte('[');
    for (0..size) |index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("{d}", .{bytes[index]});
    }
    try writer.writeByte(']');
}

fn writeJsonType(writer: anytype, program: ast.Program, ty: ast.Type) !void {
    switch (ty) {
        .void => try writeJsonString(writer, "void"),
        .bool => try writeJsonString(writer, "bool"),
        .u8 => try writeJsonString(writer, "u8"),
        .i8 => try writeJsonString(writer, "i8"),
        .u16 => try writeJsonString(writer, "u16"),
        .i16 => try writeJsonString(writer, "i16"),
        .usize => try writeJsonString(writer, "usize"),
        .pointer => |ptr| {
            try writer.writeByte('"');
            if (ptr.is_many) try writer.writeAll("[*]") else try writer.writeByte('*');
            if (ptr.is_volatile) try writer.writeAll("volatile ");
            switch (ptr.child) {
                .scalar => |scalar| try writer.writeAll(@tagName(scalar)),
                .custom => |name| try writer.writeAll(name),
            }
            try writer.writeByte('"');
        },
        .custom => |name| {
            _ = program;
            try writeJsonString(writer, name);
        },
        .far_bytes => try writeJsonString(writer, "FarBytes"),
        .far_view => try writeJsonString(writer, "FarView"),
        .near_view => try writeJsonString(writer, "NearView"),
        .array => try writeJsonString(writer, "array"),
        .optional => try writeJsonString(writer, "optional"),
    }
}

test "emits section map json from assembly and labels" {
    const asm_text =
        \\; generated
        \\; zeropage_section_begin owner=function:main kind=code lifetime=static address=near
        \\main:
        \\    jsr helper
        \\if_0_done:
        \\    rts
        \\; zeropage_section_end owner=function:main kind=code
        \\; zeropage_section_begin owner=function:main kind=static_frame lifetime=static address=near
        \\main_value:
        \\    .byte 0
        \\; zeropage_section_end owner=function:main kind=static_frame
        \\helper:
        \\    rts
        \\; zeropage_section_begin owner=function:empty kind=static_frame lifetime=static address=near
        \\; zeropage_section_end owner=function:empty kind=static_frame
        \\
    ;
    const labels_text =
        \\al 080d .main
        \\al 0810 .if_0_done
        \\al 0813 .main_value
        \\al 0814 .helper
        \\
    ;

    const json = try emitJson(std.testing.allocator, asm_text, labels_text, "build/foo.prg", 0x0801, 32);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"format\": \"zeropage-map\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"owner\": \"function:main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\": \"code\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"start\": 2061") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"end\": 2067") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"labels\": [\"main\", \"if_0_done\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"labels\": [\"main_value\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"size\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"start\": null") != null);
}

test "emits module metadata json from assembly sections and export declarations" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{
        \\        .tick = .{ .frame = .stack },
        \\        .score = .{ .frame = .stack },
        \\        .bump = .{ .frame = .stack },
        \\    } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_ai",
        \\    .abi = 1,
        \\    .exports = .{ .tick = tick, .score = score },
        \\    .deps = .{ "math", "pathing" },
        \\};
        \\fn bump(value: u8) u8 { return value + 1; }
        \\fn tick(value: u8) u8 { return bump(value); }
        \\fn score(value: u8) u8 { return value + 2; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text =
        \\; generated
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\zeropage_module_reloc_0:
        \\; zeropage_relocation kind=abs16 anchor=zeropage_module_reloc_0 target=bump addend=0
        \\    jsr bump
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\; zeropage_section_begin owner=function:score kind=code lifetime=static address=near
        \\score:
        \\    rts
        \\; zeropage_section_end owner=function:score kind=code
        \\; zeropage_section_begin owner=function:bump kind=code lifetime=static address=near
        \\bump:
        \\    rts
        \\; zeropage_section_end owner=function:bump kind=code
        \\; zeropage_section_begin owner=function:main kind=code lifetime=static address=near
        \\main:
        \\    rts
        \\; zeropage_section_end owner=function:main kind=code
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\al 080d .zeropage_module_reloc_0
        \\al 0811 .score
        \\al 0812 .bump
        \\al 0813 .main
        \\
    ;
    const json = try emitModuleMetadataJson(std.testing.allocator, parsed.program, asm_text, labels_text, "out.prg", 0x0801, 32);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"format\": \"zeropage-module-metadata\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"module_id\": \"enemy_ai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"tick\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ordinal\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"score\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ordinal\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"label\": \"tick\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"frame\": \"stack\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"params\": [{ \"name\": \"value\", \"type\": \"u8\", \"offset\": 0 }]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"frame_size\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"target_original\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requires_kernal_rom\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kernal_trampoline_safe\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"payload\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"return\": \"u8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ordinal\": 0, \"id\": \"math\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ordinal\": 1, \"id\": \"pathing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"owner\": \"function:tick\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"payload_offset\": 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\": \"abs16\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"target\": \"bump\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"target_section\": 2") != null);
}

test "module metadata marks console exports trampoline safe" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\const c64 = @import("c64");
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack }, .log = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_kernal_metadata",
        \\    .abi = 1,
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{},
        \\};
        \\fn log() void { c64.console.print("LOG\n", .{}); }
        \\fn tick(value: u8) u8 { log(); return value + 1; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text =
        \\; generated
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\; zeropage_section_begin owner=function:log kind=code lifetime=static address=near
        \\log:
        \\    rts
        \\; zeropage_section_end owner=function:log kind=code
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\al 080e .log
        \\
    ;
    const json = try emitModuleMetadataJson(std.testing.allocator, parsed.program, asm_text, labels_text, "out.prg", 0x0801, 8);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requires_kernal_rom\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kernal_trampoline_safe\": true") != null);
}

test "emits binary zp64mod sidecar with jump-table-first payload" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{
        \\        .tick = .{ .frame = .stack },
        \\        .score = .{ .frame = .stack },
        \\        .bump = .{ .frame = .stack },
        \\    } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_ai",
        \\    .abi = 1,
        \\    .exports = .{ .tick = tick, .score = score },
        \\    .deps = .{ "math", "pathing" },
        \\};
        \\fn bump(value: u8) u8 { return value + 1; }
        \\fn tick(value: u8) u8 { return bump(value); }
        \\fn score(value: u8) u8 { return value + 2; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text =
        \\; generated
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\zeropage_module_reloc_0:
        \\; zeropage_relocation kind=abs16 anchor=zeropage_module_reloc_0 target=bump addend=0
        \\    jsr bump
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\; zeropage_section_begin owner=function:score kind=code lifetime=static address=near
        \\score:
        \\    rts
        \\; zeropage_section_end owner=function:score kind=code
        \\; zeropage_section_begin owner=function:bump kind=code lifetime=static address=near
        \\bump:
        \\    rts
        \\; zeropage_section_end owner=function:bump kind=code
        \\; zeropage_section_begin owner=module:main kind=rodata lifetime=static address=near
        \\zeropage_str_title:
        \\    .byte 1
        \\; zeropage_section_end owner=module:main kind=rodata
        \\main:
        \\    rts
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\al 080d .zeropage_module_reloc_0
        \\al 0811 .score
        \\al 0812 .bump
        \\al 0813 .zeropage_str_title
        \\al 0814 .main
        \\
    ;
    var prg_bytes = [_]u8{0} ** 32;
    prg_bytes[0] = 0x01;
    prg_bytes[1] = 0x08;
    prg_bytes[14] = 0x20;
    prg_bytes[15] = 0x12;
    prg_bytes[16] = 0x08;
    prg_bytes[17] = 0x60;
    prg_bytes[18] = 0x60;
    prg_bytes[19] = 0x60;
    prg_bytes[20] = 0x42;
    prg_bytes[21] = 0xea;
    const binary = try emitModuleBinary(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, &prg_bytes);
    defer std.testing.allocator.free(binary);

    try std.testing.expectEqualStrings("ZPMD", binary[0..4]);
    try std.testing.expectEqual(module_binary_version, binary[4]);
    try std.testing.expectEqual(@as(u8, 1), binary[5]);
    try std.testing.expectEqual(@as(u16, module_binary_header_size), readLe16(binary, 8));
    try std.testing.expectEqual(@as(u32, @intCast(binary.len)), readLe32(binary, module_binary_total_size_offset));
    try std.testing.expectEqual(moduleBinaryChecksum(binary), readLe16(binary, module_binary_checksum_offset));
    try std.testing.expectEqual(@as(u16, 2), readLe16(binary, 16));
    try std.testing.expectEqual(@as(u16, 2), readLe16(binary, 18));
    try std.testing.expectEqual(@as(u16, 4), readLe16(binary, 20));
    try std.testing.expectEqual(@as(u16, 1), readLe16(binary, 22));
    try std.testing.expectEqual(@as(u16, 2), readLe16(binary, 24));
    try std.testing.expectEqualStrings("enemy_ai", binary[40..48]);

    var cursor: usize = 38;
    try std.testing.expectEqualStrings("enemy_ai", readBinaryString(binary, &cursor));
    try std.testing.expectEqual(@as(u16, 0), readLe16(binary, cursor));
    cursor += 2;
    try std.testing.expectEqualStrings("tick", readBinaryString(binary, &cursor));
    try std.testing.expectEqualStrings("tick", readBinaryString(binary, &cursor));
    cursor += 2;
    const first_param_count = binary[cursor];
    cursor += 1;
    try std.testing.expectEqual(@as(u8, 1), first_param_count);
    try std.testing.expectEqualStrings("value", readBinaryString(binary, &cursor));
    cursor += 1;
    cursor += 1;
    try std.testing.expectEqual(@as(u16, 1), readLe16(binary, cursor));
    cursor += 2;
    try std.testing.expectEqualStrings("score", readBinaryString(binary, &cursor));
    try std.testing.expectEqualStrings("score", readBinaryString(binary, &cursor));
    cursor += 2;
    const second_param_count = binary[cursor];
    cursor += 1;
    try std.testing.expectEqual(@as(u8, 1), second_param_count);
    try std.testing.expectEqualStrings("value", readBinaryString(binary, &cursor));
    cursor += 1;
    cursor += 1;
    try std.testing.expectEqual(@as(u16, 0), readLe16(binary, cursor));
    cursor += 2;
    try std.testing.expectEqualStrings("math", readBinaryString(binary, &cursor));
    try std.testing.expectEqual(@as(u16, 1), readLe16(binary, cursor));
    cursor += 2;
    try std.testing.expectEqualStrings("pathing", readBinaryString(binary, &cursor));
    for (0..4) |_| {
        _ = readBinaryString(binary, &cursor);
        _ = readBinaryString(binary, &cursor);
        cursor += 6;
    }
    try std.testing.expectEqual(@as(u32, 7), readLe32(binary, cursor));
    cursor += 4;
    try std.testing.expectEqual(@as(u8, @intFromEnum(RelocationKind.abs16)), binary[cursor]);
    cursor += 1;
    try std.testing.expectEqual(@as(u16, 2), readLe16(binary, cursor));
    cursor += 2;
    try std.testing.expectEqual(@as(u16, 0), readLe16(binary, cursor));
    cursor += 2;
    try std.testing.expectEqualStrings("bump", readBinaryString(binary, &cursor));

    const payload_offset: usize = @intCast(readLe32(binary, module_binary_payload_offset_offset));
    try std.testing.expectEqual(readLe32(binary, module_binary_jump_table_offset_offset), readLe32(binary, module_binary_payload_offset_offset));
    try std.testing.expect(readLe32(binary, module_binary_payload_len_offset) > 6);
    try std.testing.expectEqual(@as(u8, 0x4c), binary[payload_offset]);
    try std.testing.expectEqual(@as(u16, 0x080d), readLe16(binary, payload_offset + 1));
    try std.testing.expectEqual(@as(u8, 0x4c), binary[payload_offset + 3]);
    try std.testing.expectEqual(@as(u16, 0x0811), readLe16(binary, payload_offset + 4));
    try std.testing.expect(std.mem.indexOf(u8, binary, "bump") != null);
}

test "emits module loader requirements in json and binary sidecars" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xa000, .size = 0x1000 },
        \\        .reu_cache = .{ .addr = 0x020000, .size = 0x010000 },
        \\        .disk_staging = .{ .addr = 0x9000, .size = 0x0800 },
        \\        .policy = .{ .current = .{ .mode = .preload, .filename = "enemyrt" } },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_window",
        \\    .abi = 1,
        \\    .exports = .{ .tick = tick },
        \\};
        \\fn tick(value: u8) u8 { return value + 1; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text =
        \\; generated
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\main:
        \\    rts
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\al 080e .main
        \\
    ;
    var prg_bytes = [_]u8{0} ** 32;
    prg_bytes[0] = 0x01;
    prg_bytes[1] = 0x08;

    const json = try emitModuleMetadataJson(std.testing.allocator, parsed.program, asm_text, labels_text, "out.prg", 0x0801, prg_bytes.len);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"loader\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"load_window\": { \"addr\": 40960, \"size\": 4096, \"alignment\": 256 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reu_cache\": { \"addr\": 131072, \"size\": 65536, \"alignment\": 256 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"policy\": { \"current\": { \"mode\": \"preload\", \"filename\": \"enemyrt\" } }") != null);

    const binary = try emitModuleBinary(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, &prg_bytes);
    defer std.testing.allocator.free(binary);
    try std.testing.expectEqual(module_binary_flag_loader_requirements, readLe16(binary, 6));
    const payload_offset: usize = @intCast(readLe32(binary, module_binary_payload_offset_offset));
    try std.testing.expect(payload_offset >= 14);
    const record = binary[payload_offset - 14 .. payload_offset];
    try std.testing.expectEqual(@as(u16, 0xa000), readLe16(record, 0));
    try std.testing.expectEqual(@as(u16, 0x1000), readLe16(record, 2));
    try std.testing.expectEqual(@as(u32, 0x020000), readLe32(record, 4));
    try std.testing.expectEqual(@as(u32, 0x010000), readLe32(record, 8));
    try std.testing.expectEqual(@as(u16, 0x0100), readLe16(record, 12));
    try validateModuleLoaderRequirements(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, prg_bytes.len);
}

test "emits module multi-window metadata in json and binary sidecars" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .extra_load_windows = .{
        \\            .aux = .{ .addr = 0x6000, .size = 0x0800 },
        \\            .basic = .{ .addr = 0xa000, .size = 0x0800, .bank = .ram_under_basic },
        \\        },
        \\        .window_assignments = .{
        \\            .math_core = .aux,
        \\        },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x002000 },
        \\        .registry = .{ .capacity = 2 },
        \\        .disk_manifest = .{ .current = "enemy", .deps = .{ .math_core = "mathcore" } },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_multi_window",
        \\    .abi = 1,
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core" },
        \\};
        \\fn tick(value: u8) u8 { return value + 1; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text =
        \\; generated
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\main:
        \\    rts
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\al 080e .main
        \\
    ;
    var prg_bytes = [_]u8{0} ** 32;
    prg_bytes[0] = 0x01;
    prg_bytes[1] = 0x08;

    const json = try emitModuleMetadataJson(std.testing.allocator, parsed.program, asm_text, labels_text, "out.prg", 0x0801, prg_bytes.len);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"load_windows\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"aux\", \"addr\": 24576, \"size\": 2048, \"alignment\": 256, \"bank\": \"visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"basic\", \"addr\": 40960, \"size\": 2048, \"alignment\": 256, \"bank\": \"ram_under_basic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"window_assignments\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\": \"math_core\", \"window\": \"aux\", \"row\": 1") != null);

    const binary = try emitModuleBinary(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, &prg_bytes);
    defer std.testing.allocator.free(binary);
    try std.testing.expectEqual(@as(u16, module_binary_flag_loader_requirements | module_binary_flag_registry_requirements | module_binary_flag_disk_manifest | module_binary_flag_multi_window), readLe16(binary, 6));
    try std.testing.expect(std.mem.indexOf(u8, binary, "aux") != null);
}

test "emits KERNAL-bank module window metadata in sidecars" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .extra_load_windows = .{
        \\            .kernal = .{ .addr = 0xe000, .size = 0x1000, .bank = .ram_under_kernal },
        \\        },
        \\        .window_assignments = .{ .math_core = .kernal },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x002000 },
        \\        .registry = .{ .capacity = 2 },
        \\        .disk_manifest = .{ .current = "enemy", .deps = .{ .math_core = "mathcore" } },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_kernal_bank",
        \\    .abi = 1,
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core" },
        \\};
        \\fn tick(value: u8) u8 { return value + 1; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text =
        \\; generated
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\main:
        \\    rts
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\al 080e .main
        \\
    ;
    var prg_bytes = [_]u8{0} ** 32;
    prg_bytes[0] = 0x01;
    prg_bytes[1] = 0x08;

    const json = try emitModuleMetadataJson(std.testing.allocator, parsed.program, asm_text, labels_text, "out.prg", 0x0801, prg_bytes.len);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"kernal\", \"addr\": 57344, \"size\": 4096, \"alignment\": 256, \"bank\": \"ram_under_kernal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\": \"math_core\", \"window\": \"kernal\", \"row\": 1") != null);

    const binary = try emitModuleBinary(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, &prg_bytes);
    defer std.testing.allocator.free(binary);
    try std.testing.expectEqual(@as(u16, module_binary_flag_loader_requirements | module_binary_flag_registry_requirements | module_binary_flag_disk_manifest | module_binary_flag_multi_window), readLe16(binary, 6));
    try std.testing.expect(std.mem.indexOf(u8, binary, "kernal") != null);
}

test "emits module state snapshot plan in json and binary sidecars" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x020000 },
        \\        .state = .{ .current = .{ .mode = .persist_in_reu, .ranges = .{ .{ .offset = 0x0100, .size = 2 } } } },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_state",
        \\    .abi = 1,
        \\    .exports = .{ .tick = tick },
        \\};
        \\fn tick(value: u8) u8 { return value + 1; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text =
        \\; generated
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\main:
        \\    rts
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\al 080e .main
        \\
    ;
    var prg_bytes = [_]u8{0} ** 32;
    prg_bytes[0] = 0x01;
    prg_bytes[1] = 0x08;

    const json = try emitModuleMetadataJson(std.testing.allocator, parsed.program, asm_text, labels_text, "out.prg", 0x0801, prg_bytes.len);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mode\": \"persist_in_reu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"snapshot_reu_addr\": 198656") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"offset\": 256, \"size\": 2") != null);

    const binary = try emitModuleBinary(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, &prg_bytes);
    defer std.testing.allocator.free(binary);
    try std.testing.expectEqual(@as(u16, module_binary_flag_loader_requirements | module_binary_flag_state_snapshot), readLe16(binary, 6));
    try std.testing.expect(std.mem.indexOf(u8, binary, &.{ 1, 1, 1, 0x00, 0x08, 0x03, 0x00, 0x00, 0x01, 0x02, 0x00 }) != null);
}

test "emits dependency module state snapshot plan in json and binary sidecars" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x020000 },
        \\        .state = .{
        \\            .current = .{ .mode = .discard_on_unload },
        \\            .deps = .{
        \\                .math_core = .{ .mode = .persist_in_reu, .ranges = .{ .{ .offset = 0x0020, .size = 4 } } },
        \\            },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_state",
        \\    .abi = 1,
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core" },
        \\};
        \\fn tick(value: u8) u8 { return value + 1; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text =
        \\; generated
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\main:
        \\    rts
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\al 080e .main
        \\
    ;
    var prg_bytes = [_]u8{0} ** 32;
    prg_bytes[0] = 0x01;
    prg_bytes[1] = 0x08;

    const json = try emitModuleMetadataJson(std.testing.allocator, parsed.program, asm_text, labels_text, "out.prg", 0x0801, prg_bytes.len);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"current\": { \"mode\": \"discard_on_unload\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"deps\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\": \"math_core\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"snapshot_reu_addr\": 200704") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"offset\": 32, \"size\": 4") != null);

    const binary = try emitModuleBinary(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, &prg_bytes);
    defer std.testing.allocator.free(binary);
    try std.testing.expectEqual(@as(u16, module_binary_flag_loader_requirements | module_binary_flag_state_snapshot), readLe16(binary, 6));
    try std.testing.expect(std.mem.indexOf(u8, binary, "math_core") != null);
    try std.testing.expect(std.mem.indexOf(u8, binary, &.{ 0x00, 0x10, 0x03, 0x00, 0x20, 0x00, 0x04, 0x00 }) != null);
}

test "emits module registry plan in json and binary sidecars" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .registry = .{ .capacity = 3 },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_registry",
        \\    .abi = 1,
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core", "pathing" },
        \\};
        \\fn tick(value: u8) u8 { return value + 1; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text =
        \\; generated
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\main:
        \\    rts
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\al 080e .main
        \\
    ;
    var prg_bytes = [_]u8{0} ** 32;
    prg_bytes[0] = 0x01;
    prg_bytes[1] = 0x08;

    const json = try emitModuleMetadataJson(std.testing.allocator, parsed.program, asm_text, labels_text, "out.prg", 0x0801, prg_bytes.len);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"registry\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"capacity\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ordinal\": 0, \"id\": \"enemy_registry\", \"role\": \"current\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ordinal\": 1, \"id\": \"math_core\", \"role\": \"dependency\", \"dependency_ordinal\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ordinal\": 2, \"id\": \"pathing\", \"role\": \"dependency\", \"dependency_ordinal\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"edges\": [{ \"from\": 0, \"to\": 1, \"dependency_ordinal\": 0 }, { \"from\": 0, \"to\": 2, \"dependency_ordinal\": 1 }]") != null);

    const binary = try emitModuleBinary(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, &prg_bytes);
    defer std.testing.allocator.free(binary);
    try std.testing.expectEqual(@as(u16, module_binary_flag_loader_requirements | module_binary_flag_registry_requirements), readLe16(binary, 6));

    var cursor: usize = 38;
    try std.testing.expectEqualStrings("enemy_registry", readBinaryString(binary, &cursor));
    cursor += 2;
    try std.testing.expectEqualStrings("tick", readBinaryString(binary, &cursor));
    try std.testing.expectEqualStrings("tick", readBinaryString(binary, &cursor));
    cursor += 2;
    const param_count = binary[cursor];
    cursor += 1;
    for (0..param_count) |_| {
        _ = readBinaryString(binary, &cursor);
        cursor += 1;
    }
    cursor += 1;
    for (0..2) |ordinal| {
        try std.testing.expectEqual(@as(u16, @intCast(ordinal)), readLe16(binary, cursor));
        cursor += 2;
        _ = readBinaryString(binary, &cursor);
    }
    for (0..readLe16(binary, 20)) |_| {
        _ = readBinaryString(binary, &cursor);
        _ = readBinaryString(binary, &cursor);
        cursor += 6;
    }
    for (0..readLe16(binary, 22)) |_| {
        cursor += 9;
        _ = readBinaryString(binary, &cursor);
    }
    cursor += 14;
    try std.testing.expectEqual(@as(u8, 1), binary[cursor]);
    cursor += 1;
    try std.testing.expectEqual(@as(u8, 3), binary[cursor]);
    cursor += 1;
    try std.testing.expectEqual(@as(u8, 3), binary[cursor]);
    cursor += 1;
    try std.testing.expectEqual(@as(u8, 2), binary[cursor]);
    cursor += 1;

    try std.testing.expectEqual(@as(u8, 0), binary[cursor]);
    cursor += 1;
    try std.testing.expectEqualStrings("enemy_registry", readBinaryString(binary, &cursor));
    try std.testing.expectEqual(@as(u8, 0), binary[cursor]);
    cursor += 1;
    try std.testing.expectEqual(@as(u16, 0xffff), readLe16(binary, cursor));
    cursor += 2;
    try std.testing.expectEqual(@as(u8, 0), binary[cursor]);
    cursor += 1;
    try std.testing.expectEqual(@as(u8, 0), binary[cursor]);
    cursor += 1;

    try std.testing.expectEqual(@as(u8, 1), binary[cursor]);
    cursor += 1;
    try std.testing.expectEqualStrings("math_core", readBinaryString(binary, &cursor));
    try std.testing.expectEqual(@as(u8, 1), binary[cursor]);
    cursor += 1;
    try std.testing.expectEqual(@as(u16, 0), readLe16(binary, cursor));
    cursor += 4;

    try std.testing.expectEqual(@as(u8, 2), binary[cursor]);
    cursor += 1;
    try std.testing.expectEqualStrings("pathing", readBinaryString(binary, &cursor));
    try std.testing.expectEqual(@as(u8, 1), binary[cursor]);
    cursor += 1;
    try std.testing.expectEqual(@as(u16, 1), readLe16(binary, cursor));
    cursor += 4;

    try std.testing.expectEqual(@as(u8, 0), binary[cursor]);
    try std.testing.expectEqual(@as(u8, 1), binary[cursor + 1]);
    try std.testing.expectEqual(@as(u16, 0), readLe16(binary, cursor + 2));
    cursor += 4;
    try std.testing.expectEqual(@as(u8, 0), binary[cursor]);
    try std.testing.expectEqual(@as(u8, 2), binary[cursor + 1]);
    try std.testing.expectEqual(@as(u16, 1), readLe16(binary, cursor + 2));
}

test "emits module disk manifest in json binary and packaging sidecar" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .registry = .{ .capacity = 3 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{
        \\                .pathing = "pathing",
        \\                .math_core = "mathcore",
        \\            },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_manifest",
        \\    .abi = 1,
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core", "pathing" },
        \\};
        \\fn tick(value: u8) u8 { return value + 1; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text =
        \\; generated
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\
    ;
    var prg_bytes = [_]u8{0} ** 32;
    prg_bytes[0] = 0x01;
    prg_bytes[1] = 0x08;

    const json = try emitModuleMetadataJson(std.testing.allocator, parsed.program, asm_text, labels_text, "out.prg", 0x0801, prg_bytes.len);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"disk_manifest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ordinal\": 0, \"id\": \"enemy_manifest\", \"role\": \"current\", \"dependency_ordinal\": null, \"filename\": \"enemyrt\", \"cbm_filename\": \"ENEMYRT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ordinal\": 1, \"id\": \"math_core\", \"role\": \"dependency\", \"dependency_ordinal\": 0, \"filename\": \"mathcore\", \"cbm_filename\": \"MATHCORE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ordinal\": 2, \"id\": \"pathing\", \"role\": \"dependency\", \"dependency_ordinal\": 1, \"filename\": \"pathing\", \"cbm_filename\": \"PATHING\"") != null);

    const manifest_json = try emitModuleDiskManifestJson(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(manifest_json);
    try std.testing.expect(std.mem.indexOf(u8, manifest_json, "\"format\": \"zeropage-module-disk-manifest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_json, "\"module_id\": \"enemy_manifest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_json, "\"cbm_filename\": \"ENEMYRT\"") != null);

    const binary = try emitModuleBinary(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, &prg_bytes);
    defer std.testing.allocator.free(binary);
    try std.testing.expectEqual(@as(u16, module_binary_flag_loader_requirements | module_binary_flag_registry_requirements | module_binary_flag_disk_manifest), readLe16(binary, 6));

    var cursor: usize = 38;
    try std.testing.expectEqualStrings("enemy_manifest", readBinaryString(binary, &cursor));
    cursor += 2;
    try std.testing.expectEqualStrings("tick", readBinaryString(binary, &cursor));
    try std.testing.expectEqualStrings("tick", readBinaryString(binary, &cursor));
    cursor += 2;
    const param_count = binary[cursor];
    cursor += 1;
    for (0..param_count) |_| {
        _ = readBinaryString(binary, &cursor);
        cursor += 1;
    }
    cursor += 1;
    for (0..2) |_| {
        cursor += 2;
        _ = readBinaryString(binary, &cursor);
    }
    for (0..readLe16(binary, 20)) |_| {
        _ = readBinaryString(binary, &cursor);
        _ = readBinaryString(binary, &cursor);
        cursor += 6;
    }
    for (0..readLe16(binary, 22)) |_| {
        cursor += 9;
        _ = readBinaryString(binary, &cursor);
    }
    cursor += 14;
    const registry_entries = binary[cursor + 2];
    const registry_edges = binary[cursor + 3];
    cursor += 4;
    for (0..registry_entries) |_| {
        cursor += 1;
        _ = readBinaryString(binary, &cursor);
        cursor += 5;
    }
    cursor += @as(usize, registry_edges) * 4;

    try std.testing.expectEqual(@as(u8, 1), binary[cursor]);
    try std.testing.expectEqual(@as(u8, 3), binary[cursor + 1]);
    cursor += 2;
    try std.testing.expectEqual(@as(u8, 0), binary[cursor]);
    try std.testing.expectEqual(@as(u8, 0), binary[cursor + 1]);
    try std.testing.expectEqual(@as(u16, 0xffff), readLe16(binary, cursor + 2));
    cursor += 4;
    try std.testing.expectEqualStrings("enemy_manifest", readBinaryString(binary, &cursor));
    try std.testing.expectEqualStrings("enemyrt", readBinaryString(binary, &cursor));
    try std.testing.expectEqualStrings("ENEMYRT", readBinaryString(binary, &cursor));
    try std.testing.expectEqual(@as(u8, 1), binary[cursor]);
    try std.testing.expectEqual(@as(u8, 1), binary[cursor + 1]);
    try std.testing.expectEqual(@as(u16, 0), readLe16(binary, cursor + 2));
    cursor += 4;
    try std.testing.expectEqualStrings("math_core", readBinaryString(binary, &cursor));
    try std.testing.expectEqualStrings("mathcore", readBinaryString(binary, &cursor));
    try std.testing.expectEqualStrings("MATHCORE", readBinaryString(binary, &cursor));
    try std.testing.expectEqual(@as(u8, 2), binary[cursor]);
    try std.testing.expectEqual(@as(u8, 1), binary[cursor + 1]);
    try std.testing.expectEqual(@as(u16, 1), readLe16(binary, cursor + 2));
    cursor += 4;
    try std.testing.expectEqualStrings("pathing", readBinaryString(binary, &cursor));
    try std.testing.expectEqualStrings("pathing", readBinaryString(binary, &cursor));
    try std.testing.expectEqualStrings("PATHING", readBinaryString(binary, &cursor));
}

test "emits module dependency graph plan in json and binary sidecars" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x020000 },
        \\        .registry = .{ .capacity = 4 },
        \\        .disk_manifest = .{
        \\            .current = "enemyrt",
        \\            .deps = .{
        \\                .math_core = "mathcore",
        \\                .pathing = "pathing",
        \\                .fixed_math = "fixedmath",
        \\            },
        \\        },
        \\        .dependency_graph = .{
        \\            .math_core = .{ .deps = .{ .fixed_math } },
        \\            .pathing = .{ .deps = .{} },
        \\            .fixed_math = .{ .deps = .{} },
        \\        },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_graph",
        \\    .abi = 1,
        \\    .exports = .{ .tick = tick },
        \\    .deps = .{ "math_core", "pathing" },
        \\};
        \\fn tick(value: u8) u8 { return value + 1; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text =
        \\; generated
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\
    ;
    var prg_bytes = [_]u8{0} ** 32;
    prg_bytes[0] = 0x01;
    prg_bytes[1] = 0x08;

    const json = try emitModuleMetadataJson(std.testing.allocator, parsed.program, asm_text, labels_text, "out.prg", 0x0801, prg_bytes.len);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dependency_graph\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"row\": 1, \"id\": \"math_core\", \"role\": \"dependency\", \"dependency_ordinal\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"row\": 2, \"id\": \"pathing\", \"role\": \"dependency\", \"dependency_ordinal\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"row\": 3, \"id\": \"fixed_math\", \"role\": \"transitive\", \"dependency_ordinal\": null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"edges\": [{ \"from\": 1, \"to\": 3 }]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ordinal\": 3, \"id\": \"fixed_math\", \"role\": \"transitive\"") != null);

    const manifest_json = try emitModuleDiskManifestJson(std.testing.allocator, parsed.program);
    defer std.testing.allocator.free(manifest_json);
    try std.testing.expect(std.mem.indexOf(u8, manifest_json, "\"ordinal\": 3, \"id\": \"fixed_math\", \"role\": \"transitive\"") != null);

    const binary = try emitModuleBinary(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, &prg_bytes);
    defer std.testing.allocator.free(binary);
    try std.testing.expectEqual(@as(u16, module_binary_flag_loader_requirements | module_binary_flag_registry_requirements | module_binary_flag_disk_manifest | module_binary_flag_dependency_graph), readLe16(binary, 6));
    try std.testing.expect(std.mem.indexOf(u8, binary, "fixed_math") != null);
    try std.testing.expect(std.mem.indexOf(u8, binary, "fixedmath") != null);
}

test "rejects invalid module registry plans in sidecar emission" {
    const parser = @import("../../parser.zig");
    const asm_text =
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\
    ;
    var prg_bytes = [_]u8{0} ** 16;
    prg_bytes[0] = 0x01;
    prg_bytes[1] = 0x08;

    var too_small = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .registry = .{ .capacity = 2 },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{ .id = "enemy_registry", .abi = 1, .exports = .{ .tick = tick }, .deps = .{ "math_core", "pathing" } };
        \\fn tick(value: u8) u8 { return value + 1; }
    );
    defer too_small.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidZeroPageModuleRegistry, emitModuleMetadataJson(std.testing.allocator, too_small.program, asm_text, labels_text, "out.prg", 0x0801, prg_bytes.len));
    try std.testing.expectError(error.InvalidZeroPageModuleRegistry, emitModuleBinary(std.testing.allocator, too_small.program, asm_text, labels_text, 0x0801, &prg_bytes));

    var self_dep = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xc000, .size = 0x0800 },
        \\        .reu_cache = .{ .addr = 0x030000, .size = 0x010000 },
        \\        .registry = .{ .capacity = 2 },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{ .id = "enemy_registry", .abi = 1, .exports = .{ .tick = tick }, .deps = .{ "enemy_registry" } };
        \\fn tick(value: u8) u8 { return value + 1; }
    );
    defer self_dep.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidZeroPageModuleRegistry, emitModuleMetadataJson(std.testing.allocator, self_dep.program, asm_text, labels_text, "out.prg", 0x0801, prg_bytes.len));
    try std.testing.expectError(error.InvalidZeroPageModuleRegistry, emitModuleBinary(std.testing.allocator, self_dep.program, asm_text, labels_text, 0x0801, &prg_bytes));
}

test "emits relocation simulation report for loader modules" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\const reloc_table = [_]u8{ 3, 5, 8, 13 };
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xa000, .size = 0x1000 },
        \\        .reu_cache = .{ .addr = 0x020000, .size = 0x010000 },
        \\    },
        \\    .abi = .{ .functions = .{
        \\        .tick = .{ .frame = .stack },
        \\        .tablePtr = .{ .frame = .stack },
        \\        .bump = .{ .frame = .stack },
        \\    } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_reloc_sim",
        \\    .abi = 1,
        \\    .exports = .{ .tick = tick, .table_ptr = tablePtr },
        \\};
        \\fn bump(value: u8) u8 { return value + 1; }
        \\fn tick(value: u8) u8 { return bump(value); }
        \\fn tablePtr() usize { return @intFromPtr(&reloc_table[1]); }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text =
        \\; generated
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\zeropage_module_reloc_0:
        \\; zeropage_relocation kind=abs16 anchor=zeropage_module_reloc_0 target=bump addend=0
        \\    jsr bump
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\; zeropage_section_begin owner=function:tablePtr kind=code lifetime=static address=near
        \\tablePtr:
        \\zeropage_module_reloc_1:
        \\; zeropage_relocation kind=hi8 anchor=zeropage_module_reloc_1 target=zeropage_arr_reloc_table addend=1
        \\    ldx #>zeropage_arr_reloc_table+1
        \\zeropage_module_reloc_2:
        \\; zeropage_relocation kind=lo8 anchor=zeropage_module_reloc_2 target=zeropage_arr_reloc_table addend=1
        \\    lda #<zeropage_arr_reloc_table+1
        \\    rts
        \\; zeropage_section_end owner=function:tablePtr kind=code
        \\; zeropage_section_begin owner=function:bump kind=code lifetime=static address=near
        \\bump:
        \\    rts
        \\; zeropage_section_end owner=function:bump kind=code
        \\; zeropage_section_begin owner=module:main kind=rodata lifetime=static address=near
        \\zeropage_arr_reloc_table:
        \\    .byte 3,5,8,13
        \\; zeropage_section_end owner=module:main kind=rodata
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\al 080d .zeropage_module_reloc_0
        \\al 0811 .tablePtr
        \\al 0811 .zeropage_module_reloc_1
        \\al 0813 .zeropage_module_reloc_2
        \\al 0816 .bump
        \\al 0817 .zeropage_arr_reloc_table
        \\
    ;
    var prg_bytes = [_]u8{0} ** 32;
    prg_bytes[0] = 0x01;
    prg_bytes[1] = 0x08;
    prg_bytes[14] = 0x20;
    prg_bytes[15] = 0x16;
    prg_bytes[16] = 0x08;
    prg_bytes[17] = 0x60;
    prg_bytes[18] = 0xa2;
    prg_bytes[19] = 0x18;
    prg_bytes[20] = 0xa9;
    prg_bytes[21] = 0x18;
    prg_bytes[22] = 0x60;
    prg_bytes[23] = 0x60;
    prg_bytes[24] = 3;
    prg_bytes[25] = 5;
    prg_bytes[26] = 8;
    prg_bytes[27] = 13;

    const json = try emitModuleRelocationSimulationJson(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, &prg_bytes);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"format\": \"zeropage-module-relocation-sim\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"module_id\": \"enemy_reloc_sim\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"payload_length\": ") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\": \"abs16\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\": \"hi8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\": \"lo8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"target_original\": 2070, \"target_runtime\": 40975") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"before\": [22, 8], \"after\": [15, 160]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"target\": \"zeropage_arr_reloc_table\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"target_runtime\": 40977") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"before\": [24], \"after\": [160]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"before\": [24], \"after\": [17]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"relocated_payload_checksum\"") != null);
}

test "relocation simulation uses configured load window base" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xb000, .size = 0x1000 },
        \\        .reu_cache = .{ .addr = 0x020000, .size = 0x010000 },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack }, .bump = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{ .id = "enemy_reloc_sim", .abi = 1, .exports = .{ .tick = tick } };
        \\fn bump(value: u8) u8 { return value + 1; }
        \\fn tick(value: u8) u8 { return bump(value); }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);
    const asm_text =
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\zeropage_module_reloc_0:
        \\; zeropage_relocation kind=abs16 anchor=zeropage_module_reloc_0 target=bump addend=0
        \\    jsr bump
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\; zeropage_section_begin owner=function:bump kind=code lifetime=static address=near
        \\bump:
        \\    rts
        \\; zeropage_section_end owner=function:bump kind=code
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\al 080d .zeropage_module_reloc_0
        \\al 0811 .bump
        \\
    ;
    var prg_bytes = [_]u8{0} ** 24;
    prg_bytes[0] = 0x01;
    prg_bytes[1] = 0x08;
    prg_bytes[14] = 0x20;
    prg_bytes[15] = 0x11;
    prg_bytes[16] = 0x08;
    prg_bytes[17] = 0x60;
    prg_bytes[18] = 0x60;
    const json = try emitModuleRelocationSimulationJson(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, &prg_bytes);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"target_runtime\": 45063") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"after\": [7, 176]") != null);
}

test "relocation simulation emits empty report without relocations" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xa000, .size = 0x1000 },
        \\        .reu_cache = .{ .addr = 0x020000, .size = 0x010000 },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{ .id = "enemy_empty_sim", .abi = 1, .exports = .{ .tick = tick } };
        \\fn tick(value: u8) u8 { return value + 1; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);
    const asm_text =
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\
    ;
    var prg_bytes = [_]u8{0} ** 16;
    prg_bytes[0] = 0x01;
    prg_bytes[1] = 0x08;
    prg_bytes[14] = 0x60;
    const json = try emitModuleRelocationSimulationJson(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, &prg_bytes);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"applied_relocations\": []") != null);
}

test "relocation simulation rejects missing loader metadata and unsupported marker kinds" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack }, .bump = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{ .id = "enemy_no_loader", .abi = 1, .exports = .{ .tick = tick } };
        \\fn bump(value: u8) u8 { return value + 1; }
        \\fn tick(value: u8) u8 { return bump(value); }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);
    const asm_text =
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\zeropage_module_reloc_0:
        \\; zeropage_relocation kind=bank8 anchor=zeropage_module_reloc_0 target=bump addend=0
        \\    jsr bump
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\; zeropage_section_begin owner=function:bump kind=code lifetime=static address=near
        \\bump:
        \\    rts
        \\; zeropage_section_end owner=function:bump kind=code
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\al 080d .zeropage_module_reloc_0
        \\al 0811 .bump
        \\
    ;
    var prg_bytes = [_]u8{0} ** 24;
    prg_bytes[0] = 0x01;
    prg_bytes[1] = 0x08;
    try std.testing.expectError(error.MissingZeroPageModuleLoader, emitModuleRelocationSimulationJson(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, &prg_bytes));

    parsed.program.zeropage_options.modules = .{
        .load_window = .{ .addr = 0xa000, .size = 0x1000 },
        .reu_cache = .{ .addr = 0x020000, .size = 0x010000 },
    };
    try std.testing.expectError(error.UnsupportedZeroPageModuleRelocation, emitModuleRelocationSimulationJson(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, &prg_bytes));
}

test "relocation simulation rejects targets outside selected payload" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xa000, .size = 0x1000 },
        \\        .reu_cache = .{ .addr = 0x020000, .size = 0x010000 },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{ .id = "enemy_bad_reloc", .abi = 1, .exports = .{ .tick = tick } };
        \\fn tick(value: u8) u8 { return value + 1; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);
    const asm_text =
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\zeropage_module_reloc_0:
        \\; zeropage_relocation kind=abs16 anchor=zeropage_module_reloc_0 target=main addend=0
        \\    jsr main
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\; zeropage_section_begin owner=function:main kind=code lifetime=static address=near
        \\main:
        \\    rts
        \\; zeropage_section_end owner=function:main kind=code
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\al 080d .zeropage_module_reloc_0
        \\al 0811 .main
        \\
    ;
    var prg_bytes = [_]u8{0} ** 24;
    prg_bytes[0] = 0x01;
    prg_bytes[1] = 0x08;
    try std.testing.expectError(error.InvalidZeroPageModuleRelocation, emitModuleRelocationSimulationJson(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, &prg_bytes));
}

test "rejects module payload larger than configured loader regions" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .modules = .{
        \\        .load_window = .{ .addr = 0xa000, .size = 1 },
        \\        .reu_cache = .{ .addr = 0x020000, .size = 1 },
        \\    },
        \\    .abi = .{ .functions = .{ .tick = .{ .frame = .stack } } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_window",
        \\    .abi = 1,
        \\    .exports = .{ .tick = tick },
        \\};
        \\fn tick(value: u8) u8 { return value + 1; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text =
        \\; generated
        \\; zeropage_section_begin owner=function:tick kind=code lifetime=static address=near
        \\tick:
        \\    rts
        \\; zeropage_section_end owner=function:tick kind=code
        \\
    ;
    const labels_text =
        \\al 080d .tick
        \\
    ;
    try std.testing.expectError(
        error.ZeroPageModulePayloadTooLarge,
        validateModuleLoaderRequirements(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, 32),
    );
}

test "emits split address immediate relocations for module rodata" {
    const parser = @import("../../parser.zig");
    var parsed = try parser.parseSource(std.testing.allocator,
        \\const reloc_table = [_]u8{ 3, 5, 8, 13 };
        \\pub const zeropage_options = .{
        \\    .stack = .{ .base = 0xc800, .size = 0x0400 },
        \\    .abi = .{ .functions = .{
        \\        .tablePtr = .{ .frame = .stack },
        \\        .bias = .{ .frame = .stack },
        \\    } },
        \\};
        \\pub const zeropage_module = .{
        \\    .id = "enemy_rodata_relocs",
        \\    .abi = 1,
        \\    .exports = .{ .table_ptr = tablePtr, .bias = bias },
        \\};
        \\fn tablePtr() usize { return @intFromPtr(&reloc_table[1]); }
        \\fn bias(value: u8) u8 { return value + 1; }
        \\export fn main() void {}
    );
    defer parsed.deinit(std.testing.allocator);

    const asm_text =
        \\; generated
        \\; zeropage_section_begin owner=function:tablePtr kind=code lifetime=static address=near
        \\tablePtr:
        \\zeropage_module_reloc_0:
        \\; zeropage_relocation kind=hi8 anchor=zeropage_module_reloc_0 target=zeropage_arr_reloc_table addend=1
        \\    ldx #>zeropage_arr_reloc_table+1
        \\zeropage_module_reloc_1:
        \\; zeropage_relocation kind=lo8 anchor=zeropage_module_reloc_1 target=zeropage_arr_reloc_table addend=1
        \\    lda #<zeropage_arr_reloc_table+1
        \\    rts
        \\; zeropage_section_end owner=function:tablePtr kind=code
        \\; zeropage_section_begin owner=function:bias kind=code lifetime=static address=near
        \\bias:
        \\    rts
        \\; zeropage_section_end owner=function:bias kind=code
        \\; zeropage_section_begin owner=module:main kind=rodata lifetime=static address=near
        \\zeropage_arr_reloc_table:
        \\    .byte 3,5,8,13
        \\; zeropage_section_end owner=module:main kind=rodata
        \\; zeropage_section_begin owner=function:main kind=code lifetime=static address=near
        \\main:
        \\    rts
        \\; zeropage_section_end owner=function:main kind=code
        \\
    ;
    const labels_text =
        \\al 080d .tablePtr
        \\al 080d .zeropage_module_reloc_0
        \\al 080f .zeropage_module_reloc_1
        \\al 0812 .bias
        \\al 0813 .zeropage_arr_reloc_table
        \\al 0817 .main
        \\
    ;

    const json = try emitModuleMetadataJson(std.testing.allocator, parsed.program, asm_text, labels_text, "out.prg", 0x0801, 32);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"table_ptr\", \"ordinal\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"bias\", \"ordinal\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"payload_offset\": 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\": \"hi8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"payload_offset\": 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\": \"lo8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"target\": \"zeropage_arr_reloc_table\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"addend\": 1") != null);

    var prg_bytes = [_]u8{0} ** 32;
    prg_bytes[0] = 0x01;
    prg_bytes[1] = 0x08;
    const binary = try emitModuleBinary(std.testing.allocator, parsed.program, asm_text, labels_text, 0x0801, &prg_bytes);
    defer std.testing.allocator.free(binary);

    try std.testing.expectEqual(@as(u16, 2), readLe16(binary, 16));
    try std.testing.expectEqual(@as(u16, 2), readLe16(binary, 22));
    var cursor: usize = 38;
    try std.testing.expectEqualStrings("enemy_rodata_relocs", readBinaryString(binary, &cursor));
    for (0..2) |_| {
        cursor += 2;
        _ = readBinaryString(binary, &cursor);
        _ = readBinaryString(binary, &cursor);
        cursor += 2;
        const param_count = binary[cursor];
        cursor += 1;
        for (0..param_count) |_| {
            _ = readBinaryString(binary, &cursor);
            cursor += 1;
        }
        cursor += 1;
    }
    const section_count = readLe16(binary, 20);
    for (0..section_count) |_| {
        _ = readBinaryString(binary, &cursor);
        _ = readBinaryString(binary, &cursor);
        cursor += 6;
    }
    try std.testing.expectEqual(@as(u32, 7), readLe32(binary, cursor));
    cursor += 4;
    try std.testing.expectEqual(@as(u8, @intFromEnum(RelocationKind.hi8)), binary[cursor]);
    cursor += 1;
    cursor += 2;
    try std.testing.expectEqual(@as(u16, 1), readLe16(binary, cursor));
    cursor += 2;
    try std.testing.expectEqualStrings("zeropage_arr_reloc_table", readBinaryString(binary, &cursor));
    try std.testing.expectEqual(@as(u32, 9), readLe32(binary, cursor));
    cursor += 4;
    try std.testing.expectEqual(@as(u8, @intFromEnum(RelocationKind.lo8)), binary[cursor]);
    cursor += 1;
    cursor += 2;
    try std.testing.expectEqual(@as(u16, 1), readLe16(binary, cursor));
    cursor += 2;
    try std.testing.expectEqualStrings("zeropage_arr_reloc_table", readBinaryString(binary, &cursor));
}

test "escapes json strings" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeJsonString(&out.writer, "a\"b\\c");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\"", out.written());
}

fn zeroPageMarkerField(line: []const u8, key: []const u8) ?[]const u8 {
    var fields = std.mem.tokenizeAny(u8, line, " \t\r");
    while (fields.next()) |field| {
        if (field.len > key.len and std.mem.startsWith(u8, field, key) and field[key.len] == '=') return field[key.len + 1 ..];
    }
    return null;
}

fn writeZeroPageMask(writer: anytype, mask: [256]bool) !void {
    try writer.writeAll("[");
    var start: usize = 0;
    var count: usize = 0;
    while (start < 256) {
        if (!mask[start]) {
            start += 1;
            continue;
        }
        var end = start + 1;
        while (end < 256 and mask[end]) : (end += 1) {}
        if (count != 0) try writer.writeAll(", ");
        try writer.print("{{\"addr\":{d},\"size\":{d},\"end\":{d}}}", .{ start, end - start, end });
        count += 1;
        start = end;
    }
    try writer.writeAll("]");
}

fn writeZeroPageJson(allocator: std.mem.Allocator, writer: anytype, program: ast.Program, assembly: []const u8, labels: *const LabelMap) !void {
    const options = program.zeropage_options.zero_page;
    const stack: ?zero_page_policy.StackPairs = if (program.zeropage_options.stack) |configured| .{ .sp = configured.zp.sp, .fp = configured.zp.fp } else null;
    var plan = try zero_page_policy.resolve(allocator, options, stack);
    defer plan.deinit(allocator);
    var markers: usize = 0;
    var names: std.StringHashMap(void) = .init(allocator);
    defer names.deinit();
    var in_assembly = false;
    var lines = std.mem.splitScalar(u8, assembly, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "; inline asm from ZeroPage line ")) in_assembly = true;
        if (std.mem.eql(u8, line, "; end inline asm")) in_assembly = false;
        if (in_assembly or !std.mem.startsWith(u8, line, "; zeropage_zp_claim ")) continue;
        const name = zeroPageMarkerField(line, "label") orelse return error.InvalidZeroPageClaimMap;
        const addr = try std.fmt.parseInt(u16, zeroPageMarkerField(line, "addr") orelse return error.InvalidZeroPageClaimMap, 10);
        const size = try std.fmt.parseInt(u16, zeroPageMarkerField(line, "size") orelse return error.InvalidZeroPageClaimMap, 10);
        const benefit = try std.fmt.parseInt(u64, zeroPageMarkerField(line, "benefit") orelse return error.InvalidZeroPageClaimMap, 10);
        const kind = std.meta.stringToEnum(zero_page_policy.ClaimKind, zeroPageMarkerField(line, "kind") orelse return error.InvalidZeroPageClaimMap) orelse return error.InvalidZeroPageClaimMap;
        if ((try names.getOrPut(name)).found_existing) return error.InvalidZeroPageClaimMap;
        if (plan.find(name)) |claim| {
            if (claim.addr != addr or claim.size != size or claim.kind != kind) return error.InvalidZeroPageClaimMap;
        } else {
            const address = switch (kind) {
                .scratch => try plan.claimScratch(allocator, name, size, benefit),
                .parameter => if (size == 1 or size == 2) try plan.claimParameter(allocator, name, size, benefit) else return error.InvalidZeroPageClaimMap,
                else => return error.InvalidZeroPageClaimMap,
            };
            const allocated = address orelse return error.InvalidZeroPageClaimMap;
            if (allocated != addr) return error.InvalidZeroPageClaimMap;
        }
        if (labels.map.get(name) != addr) return error.InvalidZeroPageClaimMap;
        markers += 1;
    }
    if (markers != plan.claims.items.len) return error.InvalidZeroPageClaimMap;
    var owned: usize = 0;
    var restored: usize = 0;
    for (plan.owned) |selected| if (selected) {
        owned += 1;
    };
    for (plan.restore) |selected| if (selected) {
        restored += 1;
    };
    try writer.print(",\n  \"zero_page\": {{\"profile\":\"{s}\",\"allocation\":\"{s}\",\"interrupts\":\"{s}\",\"restore_basic\":{s},\"restoration_scope\":\"normal_exit\",\"async_basic_restore\":false,\"general_pointer\":{d},\"string_pointer\":{d},\"owned_bytes\":{d},\"restored_bytes\":{d},\"entry_lifecycle\":{s},\"candidate_ranges\":", .{
        @tagName(options.profile), @tagName(options.allocation), @tagName(options.interrupts), if (options.restore_basic) "true" else "false", plan.ptr, plan.string_ptr, owned, restored, if (labels.map.get("zeropage_zp_enter") != null) "true" else "false",
    });
    try writeZeroPageMask(writer, plan.candidates);
    try writer.writeAll(",\"reserved_ranges\":[");
    for (options.reserve, 0..) |range, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{{\"addr\":{d},\"size\":{d},\"end\":{d}}}", .{ range.addr, range.size, @as(u32, range.addr) + range.size });
    }
    try writer.writeAll("],\"restored_ranges\":");
    try writeZeroPageMask(writer, plan.restore);
    try writer.writeAll(",\"claims\":[");
    for (plan.claims.items, 0..) |claim, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("{\"label\":");
        try writeJsonString(writer, claim.label);
        try writer.print(",\"addr\":{d},\"size\":{d},\"kind\":\"{s}\",\"benefit\":{d}}}", .{ claim.addr, claim.size, @tagName(claim.kind), claim.benefit });
    }
    try writer.writeAll("],\"spills\":[");
    lines = std.mem.splitScalar(u8, assembly, '\n');
    var spill_count: usize = 0;
    in_assembly = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "; inline asm from ZeroPage line ")) in_assembly = true;
        if (std.mem.eql(u8, line, "; end inline asm")) in_assembly = false;
        if (in_assembly or !std.mem.startsWith(u8, line, "; zeropage_zp_spill ")) continue;
        if (spill_count != 0) try writer.writeAll(",");
        try writer.writeAll("{\"label\":");
        try writeJsonString(writer, zeroPageMarkerField(line, "label") orelse return error.InvalidZeroPageClaimMap);
        const size = try std.fmt.parseInt(u16, zeroPageMarkerField(line, "size") orelse return error.InvalidZeroPageClaimMap, 10);
        try writer.print(",\"size\":{d},\"reason\":", .{size});
        try writeJsonString(writer, zeroPageMarkerField(line, "reason") orelse return error.InvalidZeroPageClaimMap);
        try writer.writeAll("}");
        spill_count += 1;
    }
    try writer.writeAll("]");
    if (options.allocation == .scalars) {
        var parameter_markers: std.ArrayList(zero_page_parameter_map.Marker) = .empty;
        defer parameter_markers.deinit(allocator);
        try writer.writeAll(",\"parameters\":[");
        var parameter_count: usize = 0;
        in_assembly = false;
        lines = std.mem.splitScalar(u8, assembly, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, line, "; inline asm from ZeroPage line ")) in_assembly = true;
            if (std.mem.eql(u8, line, "; end inline asm")) in_assembly = false;
            if (in_assembly or !std.mem.startsWith(u8, line, "; zeropage_zp_parameter ")) continue;
            if (parameter_count != 0) try writer.writeAll(",");
            try writer.writeAll("{\"label\":");
            const label = zeroPageMarkerField(line, "label") orelse return error.InvalidZeroPageClaimMap;
            try writeJsonString(writer, label);
            const size = try std.fmt.parseInt(u16, zeroPageMarkerField(line, "size") orelse return error.InvalidZeroPageClaimMap, 10);
            const reason = std.meta.stringToEnum(zero_page_scalars.Reason, zeroPageMarkerField(line, "reason") orelse return error.InvalidZeroPageClaimMap) orelse return error.InvalidZeroPageClaimMap;
            const status = std.meta.stringToEnum(zero_page_parameter_map.Status, zeroPageMarkerField(line, "status") orelse return error.InvalidZeroPageClaimMap) orelse return error.InvalidZeroPageClaimMap;
            try parameter_markers.append(allocator, .{ .label = label, .size = size, .reason = reason, .status = status });
            try writer.print(",\"size\":{d},\"reason\":", .{size});
            try writeJsonString(writer, zeroPageMarkerField(line, "reason") orelse return error.InvalidZeroPageClaimMap);
            try writer.writeAll(",\"status\":");
            try writeJsonString(writer, zeroPageMarkerField(line, "status") orelse return error.InvalidZeroPageClaimMap);
            try writer.writeAll("}");
            parameter_count += 1;
        }
        try zero_page_parameter_map.validate(allocator, program, plan.claims.items, parameter_markers.items);
        try writer.writeAll("]");
    }
    try writer.writeAll("}");
}

test "zero page masks retain explicit gaps and exclusive endpoints" {
    var mask = [_]bool{false} ** 256;
    mask[2] = true;
    mask[3] = true;
    mask[0xfe] = true;
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeZeroPageMask(&out.writer, mask);
    try std.testing.expectEqualStrings("[{\"addr\":2,\"size\":2,\"end\":4}, {\"addr\":254,\"size\":1,\"end\":255}]", out.written());
}
