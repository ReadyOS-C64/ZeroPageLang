const std = @import("std");

pub const Program = struct {
    zeropage_options: ZeroPageOptions = .{},
    zeropage_module: ?ZeroPageModule = null,
    module_bindings: []ModuleBinding = &.{},
    type_decls: []TypeDecl = &.{},
    string_constants: []StringConstant = &.{},
    array_constants: []ArrayConstant = &.{},
    functions: []Function,

    pub fn deinit(self: Program, allocator: std.mem.Allocator) void {
        self.zeropage_options.deinit(allocator);
        if (self.zeropage_module) |module| module.deinit(allocator);
        for (self.module_bindings) |binding| binding.deinit(allocator);
        if (self.module_bindings.len != 0) allocator.free(self.module_bindings);
        for (self.type_decls) |decl| decl.deinit(allocator);
        if (self.type_decls.len != 0) allocator.free(self.type_decls);
        for (self.string_constants) |constant| constant.deinit(allocator);
        if (self.string_constants.len != 0) allocator.free(self.string_constants);
        for (self.array_constants) |constant| constant.deinit(allocator);
        if (self.array_constants.len != 0) allocator.free(self.array_constants);
        for (self.functions) |function| function.deinit(allocator);
        if (self.functions.len != 0) allocator.free(self.functions);
    }

    pub fn findFunction(self: Program, name: []const u8) ?Function {
        for (self.functions) |function| {
            if (std.mem.eql(u8, function.name, name)) return function;
        }
        return null;
    }

    pub fn findString(self: Program, name: []const u8) ?StringConstant {
        for (self.string_constants) |constant| {
            if (std.mem.eql(u8, constant.name, name)) return constant;
        }
        return null;
    }

    pub fn findArray(self: Program, name: []const u8) ?ArrayConstant {
        for (self.array_constants) |constant| {
            if (std.mem.eql(u8, constant.name, name)) return constant;
        }
        return null;
    }

    pub fn findTypeDecl(self: Program, name: []const u8) ?TypeDecl {
        for (self.type_decls) |decl| {
            if (std.mem.eql(u8, decl.name(), name)) return decl;
        }
        return null;
    }

    pub fn findEnum(self: Program, name: []const u8) ?EnumDecl {
        if (self.findTypeDecl(name)) |decl| {
            if (decl == .@"enum") return decl.@"enum";
        }
        return null;
    }

    pub fn findStruct(self: Program, name: []const u8) ?StructDecl {
        if (self.findTypeDecl(name)) |decl| {
            if (decl == .@"struct") return decl.@"struct";
        }
        return null;
    }

    pub fn findUnion(self: Program, name: []const u8) ?UnionDecl {
        if (self.findTypeDecl(name)) |decl| {
            if (decl == .@"union") return decl.@"union";
        }
        return null;
    }

    pub fn findHeap(self: Program, name: []const u8) ?HeapOptions {
        for (self.zeropage_options.heaps) |heap| {
            if (std.mem.eql(u8, heap.name, name)) return heap;
        }
        return null;
    }

    pub fn findMemoryRegion(self: Program, name: []const u8) ?MemoryRegion {
        return self.zeropage_options.memory.findRegion(name);
    }

    pub fn findFunctionPlacement(self: Program, name: []const u8) ?MemoryPlacement {
        return self.zeropage_options.memory.findFunctionPlacement(name);
    }

    pub fn findConstantPlacement(self: Program, name: []const u8) ?MemoryPlacement {
        return self.zeropage_options.memory.findConstantPlacement(name);
    }

    pub fn findReuHeap(self: Program, name: []const u8) ?ReuHeapOptions {
        for (self.zeropage_options.reu.heaps) |heap| {
            if (std.mem.eql(u8, heap.name, name)) return heap;
        }
        return null;
    }

    pub fn findModuleBinding(self: Program, name: []const u8) ?ModuleBinding {
        for (self.module_bindings) |binding| {
            if (std.mem.eql(u8, binding.name, name)) return binding;
        }
        return null;
    }
};

pub const ModuleBinding = struct {
    name: []const u8,
    module_id: []const u8,
    methods: []ModuleBindingMethod = &.{},

    pub fn deinit(self: ModuleBinding, allocator: std.mem.Allocator) void {
        for (self.methods) |method| method.deinit(allocator);
        if (self.methods.len != 0) allocator.free(self.methods);
    }

    pub fn findMethod(self: ModuleBinding, name: []const u8) ?ModuleBindingMethod {
        for (self.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return method;
        }
        return null;
    }
};

pub const ModuleBindingMethod = struct {
    name: []const u8,
    params: []Type = &.{},
    return_type: Type,

    pub fn deinit(self: ModuleBindingMethod, allocator: std.mem.Allocator) void {
        if (self.params.len != 0) allocator.free(self.params);
    }
};

pub const ZeroPageModule = struct {
    id: []const u8,
    abi: u16,
    exports: []ModuleExport = &.{},
    deps: []const []const u8 = &.{},

    pub fn deinit(self: ZeroPageModule, allocator: std.mem.Allocator) void {
        if (self.exports.len != 0) allocator.free(self.exports);
        if (self.deps.len != 0) allocator.free(self.deps);
    }
};

pub const ModuleExport = struct {
    name: []const u8,
    function_name: []const u8,
};

pub const ModuleCall = struct {
    id: []const u8,
    export_name: []const u8,
    args: []Expr = &.{},
};

pub const FramePolicy = enum {
    static,
    stack,
    auto,
};

pub const StackOptions = struct {
    base: u16,
    size: u16,
    region_name: ?[]const u8 = null,
    zp: StackZeroPageOptions = .{},
};

pub const StackZeroPageOptions = struct {
    sp: u8 = 0xf7,
    fp: u8 = 0xf9,
};

pub const FunctionFramePolicy = struct {
    name: []const u8,
    frame: FramePolicy,
};

pub const AbiOptions = struct {
    default_frame: FramePolicy = .static,
    functions: []FunctionFramePolicy = &.{},

    pub fn deinit(self: AbiOptions, allocator: std.mem.Allocator) void {
        if (self.functions.len != 0) allocator.free(self.functions);
    }
};

pub const ZeroPageOptions = struct {
    declared: bool = false,
    zero_page: @import("zero_page.zig").Options = .{},
    image: ImageOptions = .{},
    memory: MemoryOptions = .{},
    stack: ?StackOptions = null,
    abi: AbiOptions = .{},
    heaps: []HeapOptions = &.{},
    reu: ReuOptions = .{},
    modules: ?ModuleLoaderOptions = null,

    pub fn deinit(self: ZeroPageOptions, allocator: std.mem.Allocator) void {
        self.zero_page.deinit(allocator);
        self.memory.deinit(allocator);
        self.abi.deinit(allocator);
        if (self.heaps.len != 0) allocator.free(self.heaps);
        self.reu.deinit(allocator);
        if (self.modules) |modules| modules.deinit(allocator);
    }
};

pub const MemoryAddressSpace = enum {
    c64,
    reu,
};

pub const MemoryOptions = struct {
    regions: []MemoryRegion = &.{},
    placements: []MemoryPlacement = &.{},

    pub fn deinit(self: MemoryOptions, allocator: std.mem.Allocator) void {
        if (self.regions.len != 0) allocator.free(self.regions);
        for (self.placements) |placement| placement.deinit(allocator);
        if (self.placements.len != 0) allocator.free(self.placements);
    }

    pub fn findRegion(self: MemoryOptions, name: []const u8) ?MemoryRegion {
        for (self.regions) |region| {
            if (std.mem.eql(u8, region.name, name)) return region;
        }
        return null;
    }

    pub fn findFunctionPlacement(self: MemoryOptions, name: []const u8) ?MemoryPlacement {
        for (self.placements) |placement| {
            for (placement.functions) |function_name| {
                if (std.mem.eql(u8, function_name, name)) return placement;
            }
        }
        return null;
    }

    pub fn findConstantPlacement(self: MemoryOptions, name: []const u8) ?MemoryPlacement {
        for (self.placements) |placement| {
            for (placement.constants) |constant_name| {
                if (std.mem.eql(u8, constant_name, name)) return placement;
            }
        }
        return null;
    }
};

pub const MemoryRegion = struct {
    name: []const u8,
    addr: u32,
    size: u32,
    space: MemoryAddressSpace = .c64,
    bank: ModuleWindowBank = .visible,
};

pub const MemoryPlacementLoad = enum {
    direct,
    startup_copy,
};

pub const MemoryPlacement = struct {
    name: []const u8,
    region_name: []const u8,
    load: MemoryPlacementLoad = .direct,
    functions: []const []const u8 = &.{},
    constants: []const []const u8 = &.{},

    pub fn deinit(self: MemoryPlacement, allocator: std.mem.Allocator) void {
        if (self.functions.len != 0) allocator.free(self.functions);
        if (self.constants.len != 0) allocator.free(self.constants);
    }
};

pub const ImageFormat = enum {
    prg,
};

pub const ImageOptions = struct {
    format: ImageFormat = .prg,
    load_addr: u16 = 0x0801,
    entry_addr: u16 = 0x080d,
    basic_stub: bool = true,
    /// Exclusive upper bound for every byte carried by the resident PRG.
    /// u32 is intentional so $10000 can represent the end of C64 memory.
    address_limit: u32 = 0x10000,
};

pub const ModuleLoaderOptions = struct {
    load_window: ModuleLoadWindowOptions,
    extra_load_windows: []ModuleNamedLoadWindow = &.{},
    window_assignments: []ModuleWindowAssignment = &.{},
    reu_cache: ModuleReuCacheOptions,
    disk_staging: ?ModuleLoadWindowOptions = null,
    policy: ?ModulePolicyOptions = null,
    registry: ?ModuleRegistryOptions = null,
    disk_manifest: ?ModuleDiskManifestOptions = null,
    dependency_graph: ?ModuleDependencyGraphOptions = null,
    state: ?ModuleStateOptions = null,

    pub fn deinit(self: ModuleLoaderOptions, allocator: std.mem.Allocator) void {
        if (self.extra_load_windows.len != 0) allocator.free(self.extra_load_windows);
        if (self.window_assignments.len != 0) allocator.free(self.window_assignments);
        if (self.policy) |policy| policy.deinit(allocator);
        if (self.disk_manifest) |manifest| manifest.deinit(allocator);
        if (self.dependency_graph) |graph| graph.deinit(allocator);
        if (self.state) |state| state.deinit(allocator);
    }
};

pub const ModuleNamedLoadWindow = struct {
    name: []const u8,
    window: ModuleLoadWindowOptions,
};

pub const ModuleWindowAssignment = struct {
    id: []const u8,
    window_name: []const u8,
};

pub const ModuleRegistryOptions = struct {
    capacity: u8,
};

pub const ModuleDiskManifestOptions = struct {
    current: []const u8,
    deps: []ModuleDiskManifestDependency = &.{},

    pub fn deinit(self: ModuleDiskManifestOptions, allocator: std.mem.Allocator) void {
        if (self.deps.len != 0) allocator.free(self.deps);
    }
};

pub const ModuleDiskManifestDependency = struct {
    id: []const u8,
    filename: []const u8,
};

pub const ModuleDependencyGraphOptions = struct {
    nodes: []ModuleDependencyGraphNode = &.{},

    pub fn deinit(self: ModuleDependencyGraphOptions, allocator: std.mem.Allocator) void {
        for (self.nodes) |node| node.deinit(allocator);
        if (self.nodes.len != 0) allocator.free(self.nodes);
    }
};

pub const ModuleDependencyGraphNode = struct {
    id: []const u8,
    deps: []const []const u8 = &.{},

    pub fn deinit(self: ModuleDependencyGraphNode, allocator: std.mem.Allocator) void {
        if (self.deps.len != 0) allocator.free(self.deps);
    }
};

pub const ModuleLoadMode = enum { manual, preload, on_demand };

pub const ModulePolicyOptions = struct {
    current: CurrentModulePolicy,

    deps: []const DependencyModulePolicy = &.{},

    pub fn deinit(self: ModulePolicyOptions, allocator: std.mem.Allocator) void {
        if (self.deps.len != 0) allocator.free(self.deps);
    }
};

pub const CurrentModulePolicy = struct {
    mode: ModuleLoadMode,
    filename: ?[]const u8 = null,
    graph: bool = false,
};

pub const DependencyModulePolicy = struct {
    id: []const u8,
    policy: CurrentModulePolicy,
};

pub const ModuleStateMode = enum { discard_on_unload, persist_in_reu };

pub const ModuleStateOptions = struct {
    current: CurrentModuleState,
    deps: []const DependencyModuleState = &.{},

    pub fn deinit(self: ModuleStateOptions, allocator: std.mem.Allocator) void {
        self.current.deinit(allocator);
        for (self.deps) |dep| dep.deinit(allocator);
        if (self.deps.len != 0) allocator.free(self.deps);
    }
};

pub const DependencyModuleState = struct {
    id: []const u8,
    state: CurrentModuleState,

    pub fn deinit(self: DependencyModuleState, allocator: std.mem.Allocator) void {
        self.state.deinit(allocator);
    }
};

pub const CurrentModuleState = struct {
    mode: ModuleStateMode,
    ranges: []const ModuleStateRange = &.{},

    pub fn deinit(self: CurrentModuleState, allocator: std.mem.Allocator) void {
        if (self.ranges.len != 0) allocator.free(self.ranges);
    }
};

pub const ModuleStateRange = struct {
    offset: u16,
    size: u16,
};

pub const ModuleWindowBank = enum { visible, ram_under_basic, ram_under_kernal };

pub const ModuleLoadWindowOptions = struct {
    addr: u16,
    size: u16,
    bank: ModuleWindowBank = .visible,
    region_name: ?[]const u8 = null,
};

pub const ModuleReuCacheOptions = struct {
    addr: u32,
    size: u32,
    region_name: ?[]const u8 = null,
};

pub const HeapKind = enum { arena, fixed };

pub const HeapOptions = struct {
    name: []const u8,
    addr: u16,
    size: u16,
    region_name: ?[]const u8 = null,
    kind: HeapKind,
    block: ?u16 = null,
};

pub const ReuOptions = struct {
    heaps: []ReuHeapOptions = &.{},

    pub fn deinit(self: ReuOptions, allocator: std.mem.Allocator) void {
        if (self.heaps.len != 0) allocator.free(self.heaps);
    }
};

pub const ReuHeapOptions = struct {
    name: []const u8,
    addr: u32,
    size: u32,
    region_name: ?[]const u8 = null,
    kind: HeapKind,
};

pub const StringConstant = struct {
    name: []const u8,
    name_owned: bool = false,
    module_owner: []const u8 = "main",
    bytes: []const u8,

    pub fn deinit(self: StringConstant, allocator: std.mem.Allocator) void {
        if (self.name_owned) allocator.free(self.name);
        if (self.bytes.len != 0) allocator.free(self.bytes);
    }
};

pub const Type = union(enum) {
    void,
    bool,
    u8,
    i8,
    u16,
    i16,
    usize,
    far_bytes,
    far_view: FarViewType,
    near_view: FarViewType,
    array: ArrayType,
    pointer: PointerType,
    optional: OptionalType,
    custom: []const u8,
};

pub const FarViewType = struct {
    type_name: []const u8,
    count: u16,
};

pub const OptionalType = struct {
    child: OptionalChildType,
};

pub const OptionalChildType = union(enum) {
    scalar: ScalarType,
    custom: []const u8,
    pointer: PointerType,
    far_bytes,
    near_view: FarViewType,
};

pub const PointerType = struct {
    child: PointerChildType,
    is_volatile: bool = false,
    is_many: bool = false,
};

pub const PointerChildType = union(enum) {
    scalar: ScalarType,
    custom: []const u8,
};

pub const TypeDecl = union(enum) {
    @"enum": EnumDecl,
    @"struct": StructDecl,
    @"union": UnionDecl,

    pub fn name(self: TypeDecl) []const u8 {
        return switch (self) {
            .@"enum" => |decl| decl.name,
            .@"struct" => |decl| decl.name,
            .@"union" => |decl| decl.name,
        };
    }

    pub fn deinit(self: TypeDecl, allocator: std.mem.Allocator) void {
        switch (self) {
            .@"enum" => |decl| decl.deinit(allocator),
            .@"struct" => |decl| decl.deinit(allocator),
            .@"union" => |decl| decl.deinit(allocator),
        }
    }
};

pub const EnumDecl = struct {
    name: []const u8,
    tags: []EnumTag,

    pub fn deinit(self: EnumDecl, allocator: std.mem.Allocator) void {
        if (self.tags.len != 0) allocator.free(self.tags);
    }
};

pub const EnumTag = struct {
    name: []const u8,
    value: u8,
};

pub const StructDecl = struct {
    name: []const u8,
    fields: []StructFieldDecl,

    pub fn deinit(self: StructDecl, allocator: std.mem.Allocator) void {
        if (self.fields.len != 0) allocator.free(self.fields);
    }
};

pub const StructFieldDecl = struct {
    name: []const u8,
    ty: Type,
};

pub const UnionDecl = struct {
    name: []const u8,
    fields: []UnionFieldDecl,

    pub fn deinit(self: UnionDecl, allocator: std.mem.Allocator) void {
        if (self.fields.len != 0) allocator.free(self.fields);
    }
};

pub const UnionFieldDecl = struct {
    name: []const u8,
    ty: ?Type = null,
};

pub const ScalarType = enum {
    bool,
    u8,
    i8,
    u16,
    i16,
    usize,
};

pub const ArrayType = struct {
    len: u16,
    elem: ArrayElemType,
};

pub const ArrayElemType = union(enum) {
    scalar: ScalarType,
    custom: []const u8,
};

pub const ArrayConstant = struct {
    name: []const u8,
    name_owned: bool = false,
    module_owner: []const u8 = "main",
    ty: ArrayType,
    values: []Expr,

    pub fn deinit(self: ArrayConstant, allocator: std.mem.Allocator) void {
        if (self.name_owned) allocator.free(self.name);
        for (self.values) |value| freeExpr(allocator, value);
        if (self.values.len != 0) allocator.free(self.values);
    }
};

pub const Function = struct {
    name: []const u8,
    name_owned: bool = false,
    exported: bool,
    params: []Param,
    return_type: Type,
    body: []Stmt,

    pub fn deinit(self: Function, allocator: std.mem.Allocator) void {
        if (self.name_owned) allocator.free(self.name);
        if (self.params.len != 0) allocator.free(self.params);
        freeStmtList(allocator, self.body);
    }
};

pub const Param = struct {
    name: []const u8,
    ty: Type,
};

pub const Stmt = union(enum) {
    var_decl: VarDecl,
    string_var: StringVar,
    string_assign: StringAssign,
    struct_var: StructVar,
    assign: Assign,
    add_assign: AddAssign,
    sub_assign: AddAssign,
    mul_assign: AddAssign,
    bit_and_assign: AddAssign,
    bit_or_assign: AddAssign,
    bit_xor_assign: AddAssign,
    shl_assign: AddAssign,
    shr_assign: AddAssign,
    deref_assign: DerefAssign,
    array_assign: ArrayAssign,
    array_add_assign: ArrayAssign,
    array_sub_assign: ArrayAssign,
    array_mul_assign: ArrayAssign,
    array_bit_and_assign: ArrayAssign,
    array_bit_or_assign: ArrayAssign,
    array_bit_xor_assign: ArrayAssign,
    array_shl_assign: ArrayAssign,
    array_shr_assign: ArrayAssign,
    array_field_assign: ArrayFieldAssign,
    while_stmt: WhileStmt,
    for_stmt: ForStmt,
    switch_stmt: SwitchStmt,
    if_stmt: IfStmt,
    call: CallExpr,
    discard: Expr,
    return_expr: Expr,
    break_stmt,
    break_expr: BreakExpr,
    continue_stmt,
    inline_asm: InlineAsm,
    test6502: Test6502Call,
    builtin: BuiltinCall,
    reu: ReuStmt,
    reu_heap_reset: []const u8,
    heap_reset: []const u8,
    heap_free: HeapFree,
    module_unload: ModuleLoad,
    module_unload_dependency: ModuleLoad,
    module_release_dependency: ModuleLoad,
    module_release_dependency_graph: ModuleLoad,
    field_assign: FieldAssign,
};

pub const InlineAsm = struct {
    source: []const u8,
    source_line: usize,
    source_column: usize,
};

pub const Test6502Call = union(enum) {
    mark: u16,
    prime_regs: PrimeRegs,
    hit: u16,
    expect_hit_count: ExpectHitCount,
    snapshot: u16,
    expect_null: ExpectOptional,
    expect_some_u8: ExpectExpr,
    expect_some_u16: ExpectExpr,
    expect_some_bool: ExpectExpr,
    expect_some_ptr: ExpectExpr,
    expect_equal_u8: ExpectExpr,
    expect_equal_i8: ExpectExpr,
    expect_equal_bool: ExpectExpr,
    expect_equal_u16: ExpectExpr,
    expect_string: ExpectString,
    expect_a: ExpectReg,
    expect_x: ExpectReg,
    expect_y: ExpectReg,
    expect_sp: ExpectReg,
    expect_p: ExpectP,
    expect_mem_u8: ExpectMem,
    expect_mem_u16: ExpectMem,
    expect_stack_u8: ExpectStack,
    pass,
    fail: u16,
};

pub const ExpectHitCount = struct {
    id: u16,
    expected: u16,
};

pub const PrimeRegs = struct {
    id: u16,
    a: u16,
    x: u16,
    y: u16,
    p: u16,
};

pub const ExpectOptional = struct {
    id: u16,
    actual: Expr,
};

pub const ExpectReg = struct {
    id: u16,
    expected: u16,
};

pub const ExpectExpr = struct {
    id: u16,
    expected: u16,
    actual: Expr,
};

pub const ExpectString = struct {
    id: u16,
    actual: Value,
    expected: []const u8,
};

pub const ExpectP = struct {
    id: u16,
    mask: u16,
    expected: u16,
};

pub const ExpectMem = struct {
    id: u16,
    addr: u16,
    expected: u16,
};

pub const ExpectStack = struct {
    id: u16,
    offset: u16,
    expected: u16,
};

pub const VarDecl = struct {
    name: []const u8,
    ty: ?Type,
    init: Expr,
    mutable: bool = true,
};

pub const StringVar = struct {
    name: []const u8,
    capacity: u8,
};

pub const StringAssign = struct {
    name: []const u8,
    expr: StringExpr,
};

pub const StringExpr = struct {
    parts: []StringPart,

    pub fn deinit(self: StringExpr, allocator: std.mem.Allocator) void {
        for (self.parts) |part| {
            switch (part) {
                .literal => |bytes| if (bytes.len != 0) allocator.free(bytes),
                .ident => {},
            }
        }
        if (self.parts.len != 0) allocator.free(self.parts);
    }
};

pub const StringPart = union(enum) {
    literal: []const u8,
    ident: []const u8,
};

pub const StructVar = struct {
    name: []const u8,
    type_name: []const u8,
    mutable: bool = true,
    fields: []StructFieldInit,
};

pub const StructFieldInit = struct {
    name: []const u8,
    value: Expr,
};

pub const AddAssign = struct {
    name: []const u8,
    value: Expr,
    name_owned: bool = false,
};

pub const Assign = struct {
    name: []const u8,
    value: Expr,
    name_owned: bool = false,
};

pub const ArrayAssign = struct {
    name: []const u8,
    index: Expr,
    value: Expr,
    name_owned: bool = false,
};

pub const ArrayFieldAssign = struct {
    name: []const u8,
    index: Expr,
    field_path: []const u8,
    value: Expr,
    name_owned: bool = false,
    field_owned: bool = false,
};

pub const DerefAssign = struct {
    target: Expr,
    value: Expr,
};

pub const WhileStmt = struct {
    condition: Expr,
    body: []Stmt,
};

pub const ForStmt = struct {
    id: usize,
    source: ForSource,
    item_name: ?[]const u8,
    index_name: ?[]const u8,
    body: []Stmt,
};

pub const ForSource = union(enum) {
    array: []const u8,
    array_indexed: []const u8,
    range: ForRangeEnd,
};

pub const ForRangeEnd = union(enum) {
    int: u16,
    array_len: []const u8,
};

pub const IfStmt = struct {
    condition: Expr,
    payload_name: ?[]const u8 = null,
    then_body: []Stmt,
    else_body: []Stmt,
};

pub const SwitchStmt = struct {
    operand: Expr,
    prongs: []SwitchStmtProng,
};

pub const SwitchStmtProng = struct {
    selectors: []SwitchSelector,
    payload_name: ?[]const u8 = null,
    body: []Stmt,
};

pub const SwitchExpr = struct {
    operand: *Expr,
    prongs: []SwitchExprProng,
};

pub const SwitchExprProng = struct {
    selectors: []SwitchSelector,
    payload_name: ?[]const u8 = null,
    value: Expr,
};

pub const SwitchSelector = union(enum) {
    scalar: Value,
    range: SwitchRange,
    else_prong,
};

pub const SwitchRange = struct {
    first: Value,
    last: Value,
};

pub const FieldAssign = struct {
    path: FieldPath,
    value: Expr,
};

pub const FieldPath = enum {
    c64_vic_border,
};

pub const BreakExpr = struct {
    label: []const u8,
    value: Expr,
};

pub const Expr = union(enum) {
    value: Value,
    add: BinaryExpr,
    sub: BinaryExpr,
    mul: BinaryExpr,
    bit_and: BinaryExpr,
    bit_or: BinaryExpr,
    bit_xor: BinaryExpr,
    shl: BinaryExpr,
    shr: BinaryExpr,
    eq: BinaryExpr,
    ne: BinaryExpr,
    lt: BinaryExpr,
    lte: BinaryExpr,
    gt: BinaryExpr,
    gte: BinaryExpr,
    bool_and: BinaryExpr,
    bool_or: BinaryExpr,
    bit_not: *Expr,
    not: *Expr,
    address_of: AddressOf,
    deref: *Expr,
    ptr_from_int: *Expr,
    int_from_ptr: *Expr,
    size_of: Type,
    align_of: Type,
    offset_of: OffsetOf,
    as_cast: AsCast,
    c64_read_petscii,
    c64_wait_petscii,
    reu_present,
    reu_compare: ReuTransfer,
    reu_heap_alloc: ReuHeapAlloc,
    reu_view: ReuView,
    far_view_materialize: FarViewMaterialize,
    far_view_materialize_range: FarViewMaterializeRange,
    module_load: ModuleLoad,
    module_disk_load: ModuleDiskLoad,
    module_load_dependency: ModuleLoad,
    module_acquire_dependency: ModuleLoad,
    module_load_dependency_graph: ModuleLoad,
    module_acquire_dependency_graph: ModuleLoad,
    module_is_loaded: ModuleLoad,
    module_call: ModuleCall,
    heap_alloc: HeapAlloc,
    if_expr: IfExpr,
    switch_expr: SwitchExpr,
    block_expr: BlockExpr,
    call: CallExpr,
    array_literal: ArrayLiteral,
    array_index: ArrayIndex,
    array_field_index: ArrayFieldIndex,
    struct_literal: StructLiteral,
};

pub const BinaryExpr = struct {
    lhs: *Expr,
    rhs: *Expr,
};

pub const IfExpr = struct {
    condition: *Expr,
    payload_name: ?[]const u8 = null,
    then_expr: *Expr,
    else_expr: *Expr,
};

pub const BlockExpr = struct {
    label: []const u8,
    body: []Stmt,
};

pub const ArrayLiteral = struct {
    ty: ?ArrayType,
    values: []Expr,
};

pub const ArrayIndex = struct {
    name: []const u8,
    name_owned: bool = false,
    index: *Expr,
};

pub const ArrayFieldIndex = struct {
    name: []const u8,
    name_owned: bool = false,
    index: *Expr,
    field_path: []const u8,
    field_owned: bool = false,
};

pub const AddressOf = struct {
    name: []const u8,
    name_owned: bool = false,
    index: ?u16 = null,
};

pub const AsCast = struct {
    ty: Type,
    expr: *Expr,
};

pub const OffsetOf = struct {
    ty: Type,
    field_path: []const u8,
};

pub const StructLiteral = struct {
    type_name: []const u8,
    fields: []StructFieldInit,
};

pub const Value = union(enum) {
    int: u16,
    bool: bool,
    char: u8,
    null,
    ident: []const u8,
    field: FieldRef,
    enum_literal: EnumLiteral,
};

pub const FieldRef = struct {
    base: []const u8,
    base_owned: bool = false,
    field: []const u8,
};

pub const EnumLiteral = struct {
    enum_name: ?[]const u8,
    tag: []const u8,
};

pub const CallExpr = struct {
    target: []const u8,
    args: []Expr,
};

pub const BuiltinCall = union(enum) {
    screen_clear,
    puts_at: PutsAt,
    put_at: PutAt,
    hex_at: HexAt,
    hex16_at: HexAt,
    console_clear,
    console_print: ConsolePrint,
    console_puts: Value,
    string_append: StringAppend,
    string_clear: Value,
    kernal_puts: Value,
    kernal_set_name: Value,
    sleep_ticks: SleepTicks,
    sleep_frames: SleepTicks,
};

pub const ReuStmt = union(enum) {
    copy_c64_to_reu: ReuTransfer,
    copy_reu_to_c64: ReuTransfer,
    swap: ReuTransfer,
    fill: ReuFill,
    copy_from_c64: ReuFarCopy,
    copy_to_c64: ReuFarCopy,
};

pub const ReuTransfer = struct {
    c64_addr: *Expr,
    reu_addr: u32,
    len: *Expr,
};

pub const ReuFill = struct {
    reu_addr: u32,
    value: *Expr,
    len: *Expr,
};

pub const HeapAlloc = struct {
    name: []const u8,
    len: *Expr,
};

pub const ReuHeapAlloc = struct {
    name: []const u8,
    len: *Expr,
};

pub const ReuView = struct {
    type_name: []const u8,
    far: *Expr,
    count: u16,
};

pub const FarViewMaterialize = struct {
    view_name: []const u8,
    heap_name: []const u8,
};

pub const FarViewMaterializeRange = struct {
    view_name: []const u8,
    heap_name: []const u8,
    start: *Expr,
    count: u16,
};

pub const ModuleLoad = struct {
    id: []const u8,
    from_binding: bool = false,
};

pub const ModuleDiskLoad = struct {
    id: []const u8,
    filename: []const u8,
    from_binding: bool = false,
};

pub const ReuFarCopy = struct {
    far: *Expr,
    c64_addr: *Expr,
    len: *Expr,
};

pub const HeapFree = struct {
    name: []const u8,
    ptr: *Expr,
};

pub const PutsAt = struct {
    x: Value,
    y: Value,
    text: []const u8,
};

pub const PutAt = struct {
    x: Coord,
    y: Value,
    ch: Expr,
};

pub const HexAt = struct {
    x: Value,
    y: Value,
    value: Expr,
};

pub const ConsolePrint = struct {
    format: []const u8,
    args: []PrintArg,
};

pub const StringAppend = struct {
    target: Value,
    expr: StringExpr,
};

pub const PrintArg = union(enum) {
    string: []const u8,
    value: Expr,
};

pub const SleepTicks = struct {
    ticks: Expr,
};

pub const Coord = union(enum) {
    value: Value,
    base_plus: BasePlus,
};

pub const BasePlus = struct {
    base: u8,
    offset: Value,
};

pub fn freeStmtList(allocator: std.mem.Allocator, list: []Stmt) void {
    for (list) |stmt| freeStmt(allocator, stmt);
    if (list.len != 0) allocator.free(list);
}

pub fn freeStmt(allocator: std.mem.Allocator, stmt: Stmt) void {
    switch (stmt) {
        .var_decl => |var_decl| freeExpr(allocator, var_decl.init),
        .assign => |assign| freeNamedValueAssign(allocator, assign),
        .add_assign => |assign| freeNamedValueAssign(allocator, assign),
        .sub_assign => |assign| freeNamedValueAssign(allocator, assign),
        .mul_assign => |assign| freeNamedValueAssign(allocator, assign),
        .bit_and_assign => |assign| freeNamedValueAssign(allocator, assign),
        .bit_or_assign => |assign| freeNamedValueAssign(allocator, assign),
        .bit_xor_assign => |assign| freeNamedValueAssign(allocator, assign),
        .shl_assign => |assign| freeNamedValueAssign(allocator, assign),
        .shr_assign => |assign| freeNamedValueAssign(allocator, assign),
        .deref_assign => |assign| {
            freeExpr(allocator, assign.target);
            freeExpr(allocator, assign.value);
        },
        .array_assign => |assign| freeArrayAssign(allocator, assign),
        .array_add_assign => |assign| freeArrayAssign(allocator, assign),
        .array_sub_assign => |assign| freeArrayAssign(allocator, assign),
        .array_mul_assign => |assign| freeArrayAssign(allocator, assign),
        .array_bit_and_assign => |assign| freeArrayAssign(allocator, assign),
        .array_bit_or_assign => |assign| freeArrayAssign(allocator, assign),
        .array_bit_xor_assign => |assign| freeArrayAssign(allocator, assign),
        .array_shl_assign => |assign| freeArrayAssign(allocator, assign),
        .array_shr_assign => |assign| freeArrayAssign(allocator, assign),
        .array_field_assign => |assign| freeArrayFieldAssign(allocator, assign),
        .string_assign => |assign| assign.expr.deinit(allocator),
        .struct_var => |struct_var| {
            for (struct_var.fields) |field| freeExpr(allocator, field.value);
            if (struct_var.fields.len != 0) allocator.free(struct_var.fields);
        },
        .while_stmt => |while_stmt| {
            freeExpr(allocator, while_stmt.condition);
            freeStmtList(allocator, while_stmt.body);
        },
        .for_stmt => |for_stmt| freeStmtList(allocator, for_stmt.body),
        .switch_stmt => |switch_stmt| {
            freeExpr(allocator, switch_stmt.operand);
            for (switch_stmt.prongs) |prong| {
                if (prong.selectors.len != 0) allocator.free(prong.selectors);
                freeStmtList(allocator, prong.body);
            }
            if (switch_stmt.prongs.len != 0) allocator.free(switch_stmt.prongs);
        },
        .if_stmt => |if_stmt| {
            freeExpr(allocator, if_stmt.condition);
            freeStmtList(allocator, if_stmt.then_body);
            freeStmtList(allocator, if_stmt.else_body);
        },
        .call => |call| freeCall(allocator, call),
        .discard => |expr| freeExpr(allocator, expr),
        .return_expr => |expr| freeExpr(allocator, expr),
        .break_expr => |break_expr| freeExpr(allocator, break_expr.value),
        .builtin => |builtin| switch (builtin) {
            .console_print => |print| {
                for (print.args) |arg| freePrintArg(allocator, arg);
                if (print.args.len != 0) allocator.free(print.args);
            },
            .string_append => |append| append.expr.deinit(allocator),
            .put_at => |put| freeExpr(allocator, put.ch),
            .hex_at => |hex| freeExpr(allocator, hex.value),
            .hex16_at => |hex| freeExpr(allocator, hex.value),
            .sleep_ticks => |sleep| freeExpr(allocator, sleep.ticks),
            .sleep_frames => |sleep| freeExpr(allocator, sleep.ticks),
            else => {},
        },
        .reu => |call| freeReuStmt(allocator, call),
        .reu_heap_reset => {},
        .heap_reset => {},
        .heap_free => |free| {
            freeExpr(allocator, free.ptr.*);
            allocator.destroy(free.ptr);
        },
        .module_unload, .module_unload_dependency, .module_release_dependency, .module_release_dependency_graph => {},
        .field_assign => |field| freeExpr(allocator, field.value),
        .test6502 => |call| freeTest6502Call(allocator, call),
        else => {},
    }
}

pub fn freeExpr(allocator: std.mem.Allocator, expr: Expr) void {
    switch (expr) {
        .value => |value| freeValue(allocator, value),
        .call => |call| freeCall(allocator, call),
        .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .lte, .gt, .gte, .bool_and, .bool_or => |binary| {
            freeExpr(allocator, binary.lhs.*);
            allocator.destroy(binary.lhs);
            freeExpr(allocator, binary.rhs.*);
            allocator.destroy(binary.rhs);
        },
        .not, .bit_not, .deref, .ptr_from_int, .int_from_ptr => |child| {
            freeExpr(allocator, child.*);
            allocator.destroy(child);
        },
        .size_of, .align_of, .offset_of => {},
        .address_of => |address| if (address.name_owned) allocator.free(address.name),
        .as_cast => |as_cast| {
            freeExpr(allocator, as_cast.expr.*);
            allocator.destroy(as_cast.expr);
        },
        .if_expr => |if_expr| {
            freeExpr(allocator, if_expr.condition.*);
            allocator.destroy(if_expr.condition);
            freeExpr(allocator, if_expr.then_expr.*);
            allocator.destroy(if_expr.then_expr);
            freeExpr(allocator, if_expr.else_expr.*);
            allocator.destroy(if_expr.else_expr);
        },
        .switch_expr => |switch_expr| {
            freeExpr(allocator, switch_expr.operand.*);
            allocator.destroy(switch_expr.operand);
            for (switch_expr.prongs) |prong| {
                if (prong.selectors.len != 0) allocator.free(prong.selectors);
                freeExpr(allocator, prong.value);
            }
            if (switch_expr.prongs.len != 0) allocator.free(switch_expr.prongs);
        },
        .block_expr => |block_expr| freeStmtList(allocator, block_expr.body),
        .array_literal => |literal| {
            for (literal.values) |value| freeExpr(allocator, value);
            if (literal.values.len != 0) allocator.free(literal.values);
        },
        .struct_literal => |literal| {
            for (literal.fields) |field| freeExpr(allocator, field.value);
            if (literal.fields.len != 0) allocator.free(literal.fields);
        },
        .array_index => |index| {
            freeExpr(allocator, index.index.*);
            allocator.destroy(index.index);
            if (index.name_owned) allocator.free(index.name);
        },
        .array_field_index => |index| {
            freeExpr(allocator, index.index.*);
            allocator.destroy(index.index);
            if (index.name_owned) allocator.free(index.name);
            if (index.field_owned) allocator.free(index.field_path);
        },
        .reu_compare => |transfer| freeReuTransfer(allocator, transfer),
        .reu_heap_alloc => |alloc| {
            freeExpr(allocator, alloc.len.*);
            allocator.destroy(alloc.len);
        },
        .reu_view => |view| {
            freeExpr(allocator, view.far.*);
            allocator.destroy(view.far);
        },
        .far_view_materialize => {},
        .far_view_materialize_range => |range| {
            freeExpr(allocator, range.start.*);
            allocator.destroy(range.start);
        },
        .module_load, .module_disk_load, .module_load_dependency, .module_acquire_dependency, .module_load_dependency_graph, .module_acquire_dependency_graph, .module_is_loaded => {},
        .module_call => |call| {
            for (call.args) |arg| freeExpr(allocator, arg);
            if (call.args.len != 0) allocator.free(call.args);
        },
        .heap_alloc => |alloc| {
            freeExpr(allocator, alloc.len.*);
            allocator.destroy(alloc.len);
        },
        .c64_read_petscii, .c64_wait_petscii, .reu_present => {},
    }
}

fn freeValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .field => |field| if (field.base_owned) allocator.free(field.base),
        else => {},
    }
}

fn freeArrayAssign(allocator: std.mem.Allocator, assign: ArrayAssign) void {
    freeExpr(allocator, assign.index);
    freeExpr(allocator, assign.value);
    if (assign.name_owned) allocator.free(assign.name);
}

fn freeArrayFieldAssign(allocator: std.mem.Allocator, assign: ArrayFieldAssign) void {
    freeExpr(allocator, assign.index);
    freeExpr(allocator, assign.value);
    if (assign.name_owned) allocator.free(assign.name);
    if (assign.field_owned) allocator.free(assign.field_path);
}

fn freeNamedValueAssign(allocator: std.mem.Allocator, assign: anytype) void {
    freeExpr(allocator, assign.value);
    if (assign.name_owned) allocator.free(assign.name);
}

fn freeCall(allocator: std.mem.Allocator, call: CallExpr) void {
    for (call.args) |arg| freeExpr(allocator, arg);
    if (call.args.len != 0) allocator.free(call.args);
}

pub fn freePrintArg(allocator: std.mem.Allocator, arg: PrintArg) void {
    switch (arg) {
        .value => |expr| freeExpr(allocator, expr),
        .string => {},
    }
}

fn freeTest6502Call(allocator: std.mem.Allocator, call: Test6502Call) void {
    switch (call) {
        .expect_null => |expect| freeExpr(allocator, expect.actual),
        .expect_some_u8 => |expect| freeExpr(allocator, expect.actual),
        .expect_some_u16 => |expect| freeExpr(allocator, expect.actual),
        .expect_some_bool => |expect| freeExpr(allocator, expect.actual),
        .expect_some_ptr => |expect| freeExpr(allocator, expect.actual),
        .expect_equal_u8 => |expect| freeExpr(allocator, expect.actual),
        .expect_equal_i8 => |expect| freeExpr(allocator, expect.actual),
        .expect_equal_bool => |expect| freeExpr(allocator, expect.actual),
        .expect_equal_u16 => |expect| freeExpr(allocator, expect.actual),
        .expect_string => |expect| if (expect.expected.len != 0) allocator.free(expect.expected),
        else => {},
    }
}

fn freeReuStmt(allocator: std.mem.Allocator, call: ReuStmt) void {
    switch (call) {
        .copy_c64_to_reu, .copy_reu_to_c64, .swap => |transfer| freeReuTransfer(allocator, transfer),
        .fill => |fill| {
            freeExpr(allocator, fill.value.*);
            allocator.destroy(fill.value);
            freeExpr(allocator, fill.len.*);
            allocator.destroy(fill.len);
        },
        .copy_from_c64, .copy_to_c64 => |copy| {
            freeExpr(allocator, copy.far.*);
            allocator.destroy(copy.far);
            freeExpr(allocator, copy.c64_addr.*);
            allocator.destroy(copy.c64_addr);
            freeExpr(allocator, copy.len.*);
            allocator.destroy(copy.len);
        },
    }
}

fn freeReuTransfer(allocator: std.mem.Allocator, transfer: ReuTransfer) void {
    freeExpr(allocator, transfer.c64_addr.*);
    allocator.destroy(transfer.c64_addr);
    freeExpr(allocator, transfer.len.*);
    allocator.destroy(transfer.len);
}
