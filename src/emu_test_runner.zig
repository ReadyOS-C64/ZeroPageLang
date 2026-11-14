const std = @import("std");
const prg = @import("prg.zig");
const tass64 = @import("codegen/tass64.zig");

const c = @cImport({
    @cInclude("zeropage_peddle.h");
});

const ScreenStart = 0x0400;
const ScreenLen = 1000;
const BorderColor = 0xd020;
const KernalChrout = 0xffd2;
const KernalGetin = 0xffe4;
const KernalSetnam = 0xffbd;
const KernalSetlfs = 0xffba;
const KernalLoad = 0xffd5;
const TestStringPtr = 0x00fd;

const LangPassDir = "tests/fixtures/emu/lang/pass";
const LangCompileFailDir = "tests/fixtures/emu/lang/fail_compile";
const LangRuntimeFailDir = "tests/fixtures/emu/lang/fail_runtime";
const CompileErrorMarker = "zeropage-emu-error:";
const EmuMarkerPrefix = "zeropage-emu-";
var compiler_executable: []const u8 = "./zig-out/bin/zp64c";
var fixture_filter: ?[]const u8 = null;

const StartMode = enum { main, program_entry };

const DiskFileSource = union(enum) {
    output_suffix: []const u8,
    path: []const u8,
    module_source: []const u8,
};

const DiskFile = struct {
    name: []const u8,
    source: DiskFileSource = .{ .output_suffix = ".zpmod.disk.prg" },
};

const MemoryAssert = struct {
    addr: u16,
    value: u8,
};

const LabelMemoryAssert = struct {
    label: []const u8,
    offset: u16 = 0,
    value: u8,
};

const ReuAssert = struct {
    addr: u32,
    value: u8,
};

const StackRange = struct { base: u16, size: u16 };

const Case = struct {
    path: []const u8,
    contains: []const []const u8 = &.{},
    kernal_contains: []const []const u8 = &.{},
    keyboard: []const u8 = &.{},
    border: ?u8 = null,
    expect_failure: bool = false,
    start: StartMode = .main,
    disk_files: []const DiskFile = &.{},
    sidecar_modules: []const DiskFile = &.{},
    memory: []const MemoryAssert = &.{},
    label_memory: []const LabelMemoryAssert = &.{},
    reu: []const ReuAssert = &.{},
    benchmark_stack: ?StackRange = null,
};

const smoke_cases = [_]Case{
    .{ .path = "examples/small/01_border.zp64", .border = 6 },
    .{ .path = "examples/small/02_flow.zp64", .contains = &.{ "FLOW DEMO", "IF WHILE OK" } },
    .{ .path = "examples/small/03_functions.zp64", .contains = &.{ "FUNCTION DEMO", "FUNCTION OK", "TOTAL=06" } },
    .{ .path = "examples/small/04_types.zp64", .contains = &.{ "TYPES DEMO", "BOOL U8 I8 U16", "U16=0400" } },
    .{ .path = "examples/small/05_struct_fields.zp64", .contains = &.{ "STRUCT DEMO", "FIELDS OK", "X Y CH" } },
    .{ .path = "examples/small/06_module_main.zp64", .contains = &.{ "MODULE DEMO", "IMPORT CALL OK", "TOTAL=07" } },
    .{ .path = "examples/small/07_loop_control.zp64", .contains = &.{ "LOOP CONTROL DEMO", "BREAK CONTINUE OK", "X=05" } },
    .{ .path = "examples/small/08_assignment_math.zp64", .contains = &.{ "ASSIGN MATH DEMO", "SUB ASSIGN OK", "X=05" } },
    .{ .path = "examples/small/09_console_scroll.zp64", .contains = &.{ "LINE 1C", "LINE 1D", "DONE 1E" } },
    .{ .path = "examples/small/10_inline_asm.zp64", .contains = &.{ "INLINE ASM DEMO", "LABEL LOOP OK", "JSR PRESERVE OK", "ASM PARAMS OK" } },
    .{ .path = "examples/small/11_strings_petscii.zp64", .contains = &.{ "STRING DEMO", "HELLO, WORLD", "CONSOLE PUTS OK", "SETNAM OK" }, .kernal_contains = &.{"KERNAL CHROUT OK"} },
    .{ .path = "examples/small/12_mutable_strings.zp64", .contains = &.{ "MUTABLE STRING DEMO", "HELLO, MUTABLE OK", "RUNTIME APPEND", "BUFFER SETNAM OK" }, .kernal_contains = &.{"KERNAL BUFFER OK"} },
    .{ .path = "examples/small/13_string_controls.zp64", .contains = &.{ "CONTROLS DEMO", "REVERSE", "RAW BYTE: A", "BUFFER", "ASCII PROXY: OK" } },
    .{ .path = "examples/small/14_keyboard_input.zp64", .contains = &.{ "KEYBOARD DEMO", "READ A OK", "WAIT DOWN OK" }, .keyboard = &.{ 'A', 0, 0x11, 0 }, .border = 5 },
    .{ .path = "examples/small/15_array_lookup.zp64", .contains = &.{ "ARRAY DEMO", "LOOKUP 04 07 09", "WORD 0101", "ARRAY OK" }, .border = 5 },
    .{ .path = "examples/small/16_inline_asm_strings.zp64", .contains = &.{ "INLINE ASM STRINGS", "ASM STRING O!", "ASM STRING DONE" }, .border = 5 },
    .{ .path = "examples/small/17_for_array_loop.zp64", .contains = &.{ "FOR LOOP DEMO", "SUM 20", "INDEXED 04 08 0B", "FOR OK" }, .border = 5 },
    .{ .path = "examples/small/18_switch_dispatch.zp64", .contains = &.{ "SWITCH DISPATCH", "DISPATCH 27", "WORD 0200", "SWITCH OK" }, .border = 5 },
    .{ .path = "examples/small/19_enum_struct_game.zp64", .contains = &.{ "ENUM STRUCT GAME", "CELLS 01 02 01", "HIST 00 04 08", "GAME OK" }, .keyboard = &.{ '1', 0, '5', 0, '9', 0 }, .border = 5 },
    .{ .path = "examples/small/20_struct_value_helpers.zp64", .contains = &.{ "STRUCT VALUES", "CELLS 01 02 01", "HIST 00 04 08", "STRUCT VALUE OK" }, .border = 5 },
    .{ .path = "examples/small/21_pointer_mmio.zp64", .contains = &.{ "POINTER MMIO", "LOCAL 21", "MMIO!", "POKE OK" }, .border = 5 },
    .{ .path = "examples/small/22_pointer_indexing.zp64", .contains = &.{ "POINTER INDEXING", "LOCAL 2A 2B", "INDEX! OK", "INDEX OK" }, .border = 5 },
    .{ .path = "examples/small/23_as_casts.zp64", .contains = &.{ "AS CASTS", "BYTE 09 WORD 0109", "AO!", "AS OK" }, .border = 5 },
    .{ .path = "examples/small/24_optional_union_event.zp64", .contains = &.{ "OPTIONAL UNION EVENT", "RESULT 17", "UNION OPTIONAL OK" }, .keyboard = &.{ '1', 0, '2', 0 }, .border = 5 },
    .{ .path = "examples/small/25_struct_array_table.zp64", .contains = &.{ "STRUCT ARRAY TABLE", "SUM 2D", "MUT 19 33", "STRUCT ARRAY OK" }, .border = 5 },
    .{ .path = "examples/small/26_static_abi_metadata.zp64", .contains = &.{ "ABI METADATA", "STATIC OK" }, .border = 5 },
    .{ .path = "examples/small/27_stack_main_border.zp64", .border = 5 },
    .{ .path = "examples/small/28_static_calls_stack_helper.zp64", .border = 5 },
    .{ .path = "examples/small/29_module_rodata_assets.zp64", .contains = &.{ "RODATA MODULE", "ASSET OK" }, .border = 5 },
    .{ .path = "examples/small/30_stack_main_calls_static_helper.zp64", .border = 5 },
    .{ .path = "examples/small/31_stack_calls_stack_helper.zp64", .border = 5 },
    .{ .path = "examples/small/32_stack_recursive_border.zp64", .border = 5 },
    .{ .path = "examples/small/33_reu_copy_smoke.zp64", .contains = &.{ "REU COPY SMOKE", "REU OK" }, .border = 5 },
    .{ .path = "examples/small/34_near_heap_arena.zp64", .contains = &.{ "NEAR HEAP ARENA", "ALLOC OK", "RESET OK" }, .border = 5 },
    .{ .path = "examples/small/35_fixed_heap_blocks.zp64", .contains = &.{ "FIXED HEAP BLOCKS", "FREE REUSE OK", "RESET OK" }, .border = 5 },
    .{ .path = "examples/small/36_far_reu_arena.zp64", .contains = &.{ "FAR REU ARENA", "FAR COPY OK" }, .border = 5 },
    .{ .path = "examples/small/37_far_reu_struct_view.zp64", .contains = &.{ "FAR STRUCT VIEW", "ENEMY OK" }, .border = 5 },
    .{ .path = "examples/small/38_far_reu_materialize_flush.zp64", .contains = &.{ "FAR MATERIALIZE", "FLUSH OK" }, .border = 5 },
    .{ .path = "examples/small/39_far_reu_materialize_range.zp64", .contains = &.{ "FAR RANGE", "RANGE OK" }, .border = 5 },
    .{ .path = "examples/small/40_module_metadata.zp64", .contains = &.{ "MODULE METADATA", "METADATA OK" }, .border = 5 },
    .{ .path = "examples/small/41_module_binary.zp64", .contains = &.{ "MODULE BINARY", "BINARY OK" }, .border = 5 },
    .{ .path = "examples/small/42_module_ordinals_relocs.zp64", .contains = &.{ "MODULE RELOCS", "ORDINALS OK" }, .border = 5 },
    .{ .path = "examples/small/43_module_rodata_relocs.zp64", .contains = &.{ "MODULE RODATA RELOCS", "RODATA RELOCS OK" }, .border = 5 },
    .{ .path = "examples/small/44_module_loader_window.zp64", .contains = &.{ "MODULE WINDOW", "WINDOW OK" }, .border = 5 },
    .{ .path = "examples/small/45_module_relocation_sim.zp64", .contains = &.{ "MODULE RELOC SIM", "SIM OK" }, .border = 5 },
    .{ .path = "examples/small/46_module_runtime_load_window.zp64", .contains = &.{ "MODULE LOAD WINDOW", "LOAD OK" }, .border = 5 },
    .{ .path = "examples/small/47_module_registry_state.zp64", .contains = &.{ "MODULE REGISTRY", "LOADED OK" }, .border = 5 },
    .{ .path = "examples/small/48_module_unload_state.zp64", .contains = &.{ "MODULE UNLOAD", "UNLOAD OK" }, .border = 5 },
    .{ .path = "examples/small/49_module_dynamic_call.zp64", .contains = &.{ "MODULE CALL", "CALL OK" }, .border = 5 },
    .{ .path = "examples/small/50_module_disk_load.zp64", .contains = &.{ "MODULE DISK LOAD", "DISK LOAD OK" }, .border = 5 },
    .{ .path = "examples/small/51_module_disk_load_real.zp64", .contains = &.{ "DISK LOAD REAL", "REAL LOAD OK" }, .border = 5, .disk_files = &.{.{ .name = "enemyrt" }}, .memory = &.{.{ .addr = 0xc000, .value = 0x4c }}, .label_memory = &.{ .{ .label = "zeropage_module_registry_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_refcount", .value = 1 } }, .reu = &.{.{ .addr = 0x030000, .value = 0x4c }} },
    .{ .path = "examples/small/52_module_preload_policy.zp64", .contains = &.{ "MODULE PRELOAD", "PRELOAD OK" }, .border = 5, .start = .program_entry, .disk_files = &.{.{ .name = "enemyrt" }}, .memory = &.{.{ .addr = 0xc000, .value = 0x4c }}, .label_memory = &.{ .{ .label = "zeropage_module_registry_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_refcount", .value = 1 } }, .reu = &.{.{ .addr = 0x030000, .value = 0x4c }} },
    .{ .path = "examples/small/53_module_on_demand_policy.zp64", .contains = &.{ "MODULE ON DEMAND", "ON DEMAND OK" }, .border = 5, .disk_files = &.{.{ .name = "enemyrt" }}, .memory = &.{.{ .addr = 0xc000, .value = 0x4c }}, .label_memory = &.{ .{ .label = "zeropage_module_registry_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_refcount", .value = 1 } }, .reu = &.{.{ .addr = 0x030000, .value = 0x4c }} },
    .{ .path = "examples/small/54_module_dependency_metadata.zp64", .contains = &.{ "MODULE DEPS", "DEPS OK" }, .border = 5 },
    .{ .path = "examples/small/55_module_registry_plan.zp64", .contains = &.{ "MODULE REGISTRY PLAN", "REGISTRY PLAN OK" }, .border = 5 },
    .{ .path = "examples/small/56_module_disk_reload_matrix.zp64", .contains = &.{ "MODULE DISK RELOAD", "RELOAD OK" }, .border = 5, .disk_files = &.{.{ .name = "enemyrt" }}, .memory = &.{.{ .addr = 0xc000, .value = 0x4c }}, .label_memory = &.{ .{ .label = "zeropage_module_registry_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_refcount", .value = 1 } }, .reu = &.{.{ .addr = 0x030000, .value = 0x4c }} },
    .{ .path = "examples/small/57_module_disk_manifest.zp64", .contains = &.{ "MODULE DISK MANIFEST", "MANIFEST OK" }, .border = 5 },
    .{ .path = "examples/small/58_module_registry_rows.zp64", .contains = &.{ "MODULE REGISTRY ROWS", "ROWS OK" }, .border = 5, .label_memory = &.{ .{ .label = "zeropage_module_registry_row0_loaded", .value = 0 }, .{ .label = "zeropage_module_registry_row1_loaded", .value = 0 }, .{ .label = "zeropage_module_registry_row2_loaded", .value = 0 } } },
    .{ .path = "examples/small/59_module_dependency_disk_load.zp64", .contains = &.{ "MODULE DEP LOAD", "DEP LOAD OK" }, .border = 5, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_runtime.zp64" } }, .{ .name = "pathing", .source = .{ .module_source = "tests/fixtures/emu/modules/pathing_runtime.zp64" } } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row0_loaded", .value = 0 }, .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row1_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_row2_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row2_refcount", .value = 1 } }, .reu = &.{ .{ .addr = 0x030800, .value = 0x4c }, .{ .addr = 0x031000, .value = 0x4c } } },
    .{ .path = "examples/small/60_module_dependency_call.zp64", .contains = &.{ "MODULE DEP CALL", "DEP CALL OK" }, .border = 5, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "pathing", .source = .{ .module_source = "tests/fixtures/emu/modules/pathing_dispatch.zp64" } } }, .memory = &.{ .{ .addr = 0xc000, .value = 0x4c }, .{ .addr = 0xc091, .value = 0x0c } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row2_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 1 } }, .reu = &.{ .{ .addr = 0x030800, .value = 0x4c }, .{ .addr = 0x031000, .value = 0x4c } } },
    .{ .path = "examples/small/61_module_dependency_unload.zp64", .contains = &.{ "MODULE DEP UNLOAD", "DEP UNLOAD OK" }, .border = 5, .disk_files = &.{.{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }}, .memory = &.{ .{ .addr = 0xc000, .value = 0x4c }, .{ .addr = 0xc091, .value = 0x0c } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row1_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 1 } }, .reu = &.{.{ .addr = 0x030800, .value = 0x4c }} },
    .{ .path = "examples/small/62_module_typed_dependency_call.zp64", .contains = &.{ "MODULE TYPED CALL", "TYPED CALL OK" }, .border = 5, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "pathing", .source = .{ .module_source = "tests/fixtures/emu/modules/pathing_dispatch.zp64" } } }, .memory = &.{ .{ .addr = 0xc000, .value = 0x4c }, .{ .addr = 0xc091, .value = 0x0c } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row2_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 1 } }, .reu = &.{ .{ .addr = 0x030800, .value = 0x4c }, .{ .addr = 0x031000, .value = 0x4c } } },
    .{ .path = "examples/small/63_module_typed_dependency_lifecycle.zp64", .contains = &.{ "MODULE TYPED LIFE", "TYPED LIFE OK" }, .border = 5, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "pathing", .source = .{ .module_source = "tests/fixtures/emu/modules/pathing_dispatch.zp64" } } }, .memory = &.{ .{ .addr = 0xc000, .value = 0x4c }, .{ .addr = 0xc091, .value = 0x0c } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row2_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 2 } }, .reu = &.{ .{ .addr = 0x030800, .value = 0x4c }, .{ .addr = 0x031000, .value = 0x4c } } },
    .{ .path = "examples/small/64_module_typed_current_binding.zp64", .contains = &.{ "MODULE TYPED CURRENT", "TYPED CURRENT OK" }, .border = 5, .disk_files = &.{.{ .name = "enemyrt" }}, .memory = &.{.{ .addr = 0xc000, .value = 0x4c }}, .label_memory = &.{ .{ .label = "zeropage_module_registry_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 0 } }, .reu = &.{.{ .addr = 0x030000, .value = 0x4c }} },
    .{ .path = "examples/small/65_module_state_metadata.zp64", .contains = &.{ "MODULE STATE META", "STATE META OK" }, .border = 5 },
    .{ .path = "examples/small/66_module_state_runtime.zp64", .contains = &.{ "MODULE STATE RUNTIME", "STATE RESTORE OK" }, .border = 5, .memory = &.{ .{ .addr = 0xc100, .value = 0x2a }, .{ .addr = 0xc101, .value = 0x37 } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 0 }, .{ .label = "zeropage_module_state_current_saved", .value = 1 } }, .reu = &.{ .{ .addr = 0x030000, .value = 0x4c }, .{ .addr = 0x030900, .value = 0x2a }, .{ .addr = 0x030901, .value = 0x37 } } },
    .{ .path = "examples/small/67_module_dependency_state_metadata.zp64", .contains = &.{ "MODULE DEP STATE", "DEP STATE META OK" }, .border = 5 },
    .{ .path = "examples/small/68_module_dependency_state_runtime.zp64", .contains = &.{ "MODULE DEP STATE RUNTIME", "DEP STATE RESTORE OK" }, .border = 5, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "pathing", .source = .{ .module_source = "tests/fixtures/emu/modules/pathing_dispatch.zp64" } } }, .memory = &.{ .{ .addr = 0xc400, .value = 0x2a }, .{ .addr = 0xc401, .value = 0x37 }, .{ .addr = 0xc500, .value = 0x44 }, .{ .addr = 0xc501, .value = 0x55 } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row2_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 2 }, .{ .label = "zeropage_module_state_dep1_saved", .value = 1 }, .{ .label = "zeropage_module_state_dep2_saved", .value = 1 } }, .reu = &.{ .{ .addr = 0x032400, .value = 0x2a }, .{ .addr = 0x032401, .value = 0x37 }, .{ .addr = 0x032d00, .value = 0x44 }, .{ .addr = 0x032d01, .value = 0x55 } } },
    .{ .path = "examples/small/69_module_dependency_preload_policy.zp64", .contains = &.{ "MODULE DEP PRELOAD", "DEP PRELOAD OK" }, .border = 5, .start = .program_entry, .disk_files = &.{.{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }}, .memory = &.{.{ .addr = 0xc000, .value = 0x4c }}, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row1_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_row2_loaded", .value = 0 }, .{ .label = "zeropage_module_registry_active_row", .value = 1 } }, .reu = &.{.{ .addr = 0x030800, .value = 0x4c }} },
    .{ .path = "examples/small/70_module_dependency_on_demand_policy.zp64", .contains = &.{ "MODULE DEP ON DEMAND", "DEP ON DEMAND OK" }, .border = 5, .disk_files = &.{.{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }}, .memory = &.{ .{ .addr = 0x9000, .value = 0x4c }, .{ .addr = 0xc000, .value = 0x4c }, .{ .addr = 0xc091, .value = 0x0c } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row1_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 1 } }, .reu = &.{.{ .addr = 0x030800, .value = 0x4c }} },
    .{ .path = "examples/small/71_module_dependency_refcount.zp64", .contains = &.{ "MODULE DEP REFCOUNT", "REFCOUNT OK" }, .border = 5, .disk_files = &.{.{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }}, .memory = &.{ .{ .addr = 0xc000, .value = 0x4c }, .{ .addr = 0xc091, .value = 0x0c } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row1_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 1 } }, .reu = &.{.{ .addr = 0x030800, .value = 0x4c }} },
    .{ .path = "examples/small/72_module_dependency_graph_metadata.zp64", .contains = &.{ "MODULE DEP GRAPH", "GRAPH META OK" }, .border = 5 },
    .{ .path = "examples/small/73_module_dependency_graph_load.zp64", .contains = &.{ "MODULE GRAPH LOAD", "GRAPH LOAD OK" }, .border = 5, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "fixedmath", .source = .{ .module_source = "tests/fixtures/emu/modules/fixed_math_runtime.zp64" } } }, .memory = &.{ .{ .addr = 0xc000, .value = 0x4c }, .{ .addr = 0xc091, .value = 0x0c } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row1_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_row3_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row3_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 1 } }, .reu = &.{ .{ .addr = 0x030800, .value = 0x4c }, .{ .addr = 0x031800, .value = 0x4c } } },
    .{ .path = "examples/small/74_module_dependency_graph_on_demand_policy.zp64", .contains = &.{ "MODULE GRAPH ON DEMAND", "GRAPH ON DEMAND OK" }, .border = 5, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "fixedmath", .source = .{ .module_source = "tests/fixtures/emu/modules/fixed_math_runtime.zp64" } } }, .memory = &.{ .{ .addr = 0xc000, .value = 0x4c }, .{ .addr = 0xc091, .value = 0x0c } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row1_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_row3_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row3_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 1 } }, .reu = &.{ .{ .addr = 0x030800, .value = 0x4c }, .{ .addr = 0x031800, .value = 0x4c } } },
    .{ .path = "examples/small/75_module_dependency_graph_preload_policy.zp64", .contains = &.{ "MODULE GRAPH PRELOAD", "GRAPH PRELOAD OK" }, .border = 5, .start = .program_entry, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "fixedmath", .source = .{ .module_source = "tests/fixtures/emu/modules/fixed_math_runtime.zp64" } } }, .memory = &.{ .{ .addr = 0xc000, .value = 0x4c }, .{ .addr = 0xc091, .value = 0x0c } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row1_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_row3_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row3_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 1 } }, .reu = &.{ .{ .addr = 0x030800, .value = 0x4c }, .{ .addr = 0x031800, .value = 0x4c } } },
    .{ .path = "examples/small/76_module_typed_dependency_graph_lifecycle.zp64", .contains = &.{ "MODULE TYPED GRAPH", "TYPED GRAPH OK" }, .border = 5, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "fixedmath", .source = .{ .module_source = "tests/fixtures/emu/modules/fixed_math_runtime.zp64" } } }, .memory = &.{ .{ .addr = 0xc000, .value = 0x4c }, .{ .addr = 0xc091, .value = 0x0c } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row1_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_row3_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row3_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 1 } }, .reu = &.{ .{ .addr = 0x030800, .value = 0x4c }, .{ .addr = 0x031800, .value = 0x4c } } },
    .{ .path = "examples/small/77_module_dependency_graph_acquire.zp64", .contains = &.{ "MODULE GRAPH ACQUIRE", "GRAPH ACQUIRE OK" }, .border = 5, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "fixedmath", .source = .{ .module_source = "tests/fixtures/emu/modules/fixed_math_runtime.zp64" } } }, .memory = &.{ .{ .addr = 0xc000, .value = 0x4c }, .{ .addr = 0xc091, .value = 0x0c } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row1_refcount", .value = 2 }, .{ .label = "zeropage_module_registry_row3_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row3_refcount", .value = 2 }, .{ .label = "zeropage_module_registry_active_row", .value = 1 } }, .reu = &.{ .{ .addr = 0x030800, .value = 0x4c }, .{ .addr = 0x031800, .value = 0x4c } } },
    .{ .path = "examples/small/78_module_dependency_graph_release.zp64", .contains = &.{ "MODULE GRAPH RELEASE", "GRAPH RELEASE OK" }, .border = 5, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "fixedmath", .source = .{ .module_source = "tests/fixtures/emu/modules/fixed_math_runtime.zp64" } } }, .memory = &.{ .{ .addr = 0xc000, .value = 0x4c }, .{ .addr = 0xc091, .value = 0x0c } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row1_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_row3_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row3_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 1 } }, .reu = &.{ .{ .addr = 0x030800, .value = 0x4c }, .{ .addr = 0x031800, .value = 0x4c } } },
    .{ .path = "examples/small/79_module_typed_dependency_graph_ownership.zp64", .contains = &.{ "MODULE TYPED GRAPH OWNERSHIP", "TYPED GRAPH OWNERSHIP OK" }, .border = 5, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "fixedmath", .source = .{ .module_source = "tests/fixtures/emu/modules/fixed_math_runtime.zp64" } } }, .memory = &.{ .{ .addr = 0xc000, .value = 0x4c }, .{ .addr = 0xc091, .value = 0x0c } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row1_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_row3_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row3_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 1 } }, .reu = &.{ .{ .addr = 0x030800, .value = 0x4c }, .{ .addr = 0x031800, .value = 0x4c } } },
    .{ .path = "examples/small/80_module_graph_node_sidecars.zp64", .contains = &.{ "MODULE GRAPH SIDECARS", "GRAPH SIDECARS OK" }, .border = 5, .sidecar_modules = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "fixedmath", .source = .{ .module_source = "tests/fixtures/emu/modules/fixed_math_runtime.zp64" } } } },
    .{ .path = "examples/small/81_module_graph_node_call.zp64", .contains = &.{ "MODULE GRAPH NODE CALL", "GRAPH NODE CALL OK" }, .border = 5, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "fixedmath", .source = .{ .module_source = "tests/fixtures/emu/modules/fixed_math_runtime.zp64" } } }, .memory = &.{.{ .addr = 0xc000, .value = 0x4c }}, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 0 }, .{ .label = "zeropage_module_registry_row3_loaded", .value = 0 }, .{ .label = "zeropage_module_registry_active_row", .value = 0xff } }, .reu = &.{ .{ .addr = 0x030800, .value = 0x4c }, .{ .addr = 0x031800, .value = 0x4c } } },
    .{ .path = "examples/small/82_module_typed_graph_node_binding.zp64", .contains = &.{ "MODULE TYPED GRAPH NODE", "TYPED GRAPH NODE OK" }, .border = 5, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "fixedmath", .source = .{ .module_source = "tests/fixtures/emu/modules/fixed_math_runtime.zp64" } } }, .memory = &.{.{ .addr = 0xc000, .value = 0x4c }}, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row1_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_row3_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row3_refcount", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 3 } }, .reu = &.{ .{ .addr = 0x030800, .value = 0x4c }, .{ .addr = 0x031800, .value = 0x4c } } },
    .{ .path = "examples/small/83_module_multi_window_metadata.zp64", .contains = &.{ "MODULE MULTI WINDOW", "WINDOW METADATA OK" }, .border = 5 },
    .{ .path = "examples/small/84_module_multi_window_dispatch.zp64", .contains = &.{ "MODULE MULTI WINDOW DISPATCH", "WINDOW DISPATCH OK" }, .border = 5, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "fixedmath", .source = .{ .module_source = "tests/fixtures/emu/modules/fixed_math_runtime.zp64" } } }, .memory = &.{.{ .addr = 0x6000, .value = 0x4c }}, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row3_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 0xff }, .{ .label = "zeropage_module_registry_active_row_aux", .value = 3 } }, .reu = &.{ .{ .addr = 0x030800, .value = 0x4c }, .{ .addr = 0x031800, .value = 0x4c } } },
    .{ .path = "examples/small/85_module_typed_multi_window_binding.zp64", .contains = &.{ "MODULE TYPED MULTI WINDOW", "TYPED WINDOW OK" }, .border = 5, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "fixedmath", .source = .{ .module_source = "tests/fixtures/emu/modules/fixed_math_runtime.zp64" } } }, .memory = &.{ .{ .addr = 0x6000, .value = 0x4c }, .{ .addr = 0x6400, .value = 0x2a }, .{ .addr = 0x6401, .value = 0x37 } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row3_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 0xff }, .{ .label = "zeropage_module_registry_active_row_aux", .value = 1 }, .{ .label = "zeropage_module_state_dep1_saved", .value = 1 } }, .reu = &.{ .{ .addr = 0x030800, .value = 0x4c }, .{ .addr = 0x031800, .value = 0x4c }, .{ .addr = 0x032c00, .value = 0x2a }, .{ .addr = 0x032c01, .value = 0x37 } } },
    .{ .path = "examples/small/86_module_basic_bank_metadata.zp64", .contains = &.{ "MODULE BASIC BANK", "BANK METADATA OK" }, .border = 5 },
    .{ .path = "examples/small/87_module_current_basic_bank.zp64", .contains = &.{ "MODULE CURRENT BASIC BANK", "CURRENT BANK OK" }, .border = 5, .memory = &.{ .{ .addr = 0xa000, .value = 0x4c }, .{ .addr = 0x0001, .value = 0x37 } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 0 } }, .reu = &.{.{ .addr = 0x030000, .value = 0x4c }} },
    .{ .path = "examples/small/88_module_typed_basic_bank_window.zp64", .contains = &.{ "MODULE TYPED BASIC BANK", "BASIC BANK OK" }, .border = 5, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "fixedmath", .source = .{ .module_source = "tests/fixtures/emu/modules/fixed_math_runtime.zp64" } } }, .memory = &.{ .{ .addr = 0xa000, .value = 0x4c }, .{ .addr = 0xa400, .value = 0x2a }, .{ .addr = 0xa401, .value = 0x37 }, .{ .addr = 0x0001, .value = 0x37 } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row3_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 0xff }, .{ .label = "zeropage_module_registry_active_row_basic", .value = 1 }, .{ .label = "zeropage_module_state_dep1_saved", .value = 1 } }, .reu = &.{ .{ .addr = 0x030800, .value = 0x4c }, .{ .addr = 0x031800, .value = 0x4c }, .{ .addr = 0x032c00, .value = 0x2a }, .{ .addr = 0x032c01, .value = 0x37 } } },
    .{ .path = "examples/small/89_module_kernal_bank_metadata.zp64", .contains = &.{ "MODULE KERNAL BANK", "BANK METADATA OK" }, .border = 5 },
    .{ .path = "examples/small/90_module_current_kernal_bank.zp64", .contains = &.{ "MODULE CURRENT KERNAL BANK", "CURRENT KERNAL OK" }, .border = 5, .memory = &.{ .{ .addr = 0xe000, .value = 0x4c }, .{ .addr = 0x0001, .value = 0x37 } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 0 } }, .reu = &.{.{ .addr = 0x030000, .value = 0x4c }} },
    .{ .path = "examples/small/91_module_typed_kernal_bank_window.zp64", .contains = &.{ "MODULE TYPED KERNAL BANK", "KERNAL BANK OK" }, .border = 5, .disk_files = &.{ .{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_dispatch.zp64" } }, .{ .name = "fixedmath", .source = .{ .module_source = "tests/fixtures/emu/modules/fixed_math_runtime.zp64" } } }, .memory = &.{ .{ .addr = 0xe000, .value = 0x4c }, .{ .addr = 0xe400, .value = 0x2a }, .{ .addr = 0xe401, .value = 0x37 }, .{ .addr = 0x0001, .value = 0x37 } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_row3_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 0xff }, .{ .label = "zeropage_module_registry_active_row_kernal", .value = 1 }, .{ .label = "zeropage_module_state_dep1_saved", .value = 1 } }, .reu = &.{ .{ .addr = 0x030800, .value = 0x4c }, .{ .addr = 0x031800, .value = 0x4c }, .{ .addr = 0x032c00, .value = 0x2a }, .{ .addr = 0x032c01, .value = 0x37 } } },
    .{ .path = "examples/small/92_module_kernal_bank_hardening.zp64", .contains = &.{ "MODULE KERNAL HARDEN", "KERNAL HARDEN OK" }, .border = 5, .memory = &.{ .{ .addr = 0xe000, .value = 0x4c }, .{ .addr = 0x0001, .value = 0x37 } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_loaded", .value = 0 }, .{ .label = "zeropage_module_registry_active_row", .value = 0xff } }, .reu = &.{.{ .addr = 0x030000, .value = 0x4c }} },
    .{ .path = "examples/small/93_module_kernal_console_trampoline.zp64", .contains = &.{ "TRAMP EXPORT", "MODULE KERNAL TRAMP", "TRAMP OK" }, .border = 5, .memory = &.{ .{ .addr = 0xe000, .value = 0x4c }, .{ .addr = 0x0001, .value = 0x37 } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 0 } }, .reu = &.{.{ .addr = 0x030000, .value = 0x4c }} },
    .{ .path = "examples/small/94_module_dependency_kernal_console_trampoline.zp64", .contains = &.{ "DEP TRAMP EXPORT", "MODULE DEP KERNAL TRAMP", "DEP TRAMP OK" }, .border = 5, .disk_files = &.{.{ .name = "mathcore", .source = .{ .module_source = "tests/fixtures/emu/modules/math_core_kernal_console.zp64" } }}, .memory = &.{ .{ .addr = 0xe000, .value = 0x4c }, .{ .addr = 0x0001, .value = 0x37 } }, .label_memory = &.{ .{ .label = "zeropage_module_registry_row1_loaded", .value = 1 }, .{ .label = "zeropage_module_registry_active_row", .value = 0xff }, .{ .label = "zeropage_module_registry_active_row_kernal", .value = 1 } }, .reu = &.{.{ .addr = 0x030800, .value = 0x4c }} },
    .{ .path = "examples/small/95_memory_regions_placement.zp64", .contains = &.{ "MEMORY REGIONS", "PLACEMENT ARENA OK" }, .border = 5, .start = .program_entry, .memory = &.{ .{ .addr = 0x0001, .value = 0x37 }, .{ .addr = 0x2000, .value = 0xad }, .{ .addr = 0x9000, .value = 0x55 }, .{ .addr = 0xe000, .value = 0xad } } },
    .{ .path = "examples/small/96_memory_regions_dll.zp64", .contains = &.{ "REGION ARENA DLL", "REGION DLL CACHE OK" }, .border = 5, .memory = &.{ .{ .addr = 0x9000, .value = 0x55 }, .{ .addr = 0xc000, .value = 0x4c } }, .reu = &.{.{ .addr = 0x030000, .value = 0x4c }} },
    .{ .path = "tests/fixtures/emu/smoke/scalars_assignments.zp64", .contains = &.{ "SCALARS", "05 FF 01", "0400 0401 0402" } },
    .{ .path = "tests/fixtures/emu/smoke/control_flow.zp64", .contains = &.{ "CONTROL", "06 05" } },
    .{ .path = "tests/fixtures/emu/smoke/functions_calls.zp64", .contains = &.{ "CALLS", "06 01 09" } },
    .{ .path = "tests/fixtures/emu/smoke/nested_calls.zp64", .contains = &.{ "NESTED", "06 06 0A 09 06 06" } },
    .{ .path = "tests/fixtures/emu/smoke/struct_fields.zp64", .contains = &.{ "STRUCT", "04 02 13" } },
    .{ .path = "tests/fixtures/emu/smoke/strings_concat.zp64", .contains = &.{ "STRINGS", "HELLO, WORLD", "PETSCII", "ASCII PROXY: OK" } },
    .{ .path = "tests/fixtures/emu/smoke/mutable_strings.zp64", .contains = &.{ "MUT STR", "MUTABLE BUFFER OK", "AFTER CLEAR" } },
    .{ .path = "tests/fixtures/emu/smoke/module_main.zp64", .contains = &.{ "MODULE", "07 01" } },
    .{ .path = "tests/fixtures/emu/smoke/inline_asm.zp64", .contains = &.{ "ASM", "08" }, .kernal_contains = &.{"*"}, .border = 6 },
    .{ .path = "tests/fixtures/emu/smoke/inline_asm_strings.zp64" },
    .{ .path = "tests/fixtures/emu/smoke/c64_builtins.zp64", .contains = &.{ "CONSOLE 0B 0401", "BUILTINS", "A 0A 0400" }, .kernal_contains = &.{"KERNAL OK"}, .border = 14 },
    .{ .path = "tests/fixtures/emu/smoke/keyboard_input.zp64", .keyboard = &.{ 'A', 0, 0x11, 0, 0x9e, 0 }, .border = 5 },
    .{ .path = "tests/fixtures/emu/smoke/test6502_pass.zp64", .expect_failure = false },
};

pub fn main(init: std.process.Init) u8 {
    compiler_executable = init.environ_map.get("ZEROPAGE_TEST_COMPILER") orelse compiler_executable;
    fixture_filter = init.environ_map.get("ZEROPAGE_EMU_FILTER");
    if (fixture_filter != null and fixture_filter.?.len == 0) fixture_filter = null;
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    defer stdout.interface.flush() catch {};
    defer stderr.interface.flush() catch {};

    run(init.gpa, init.io, &stdout.interface, &stderr.interface) catch |err| {
        stderr.interface.print("emu-test failed: {s}\n", .{@errorName(err)}) catch {};
        return 1;
    };
    return 0;
}

fn run(allocator: std.mem.Allocator, io: std.Io, stdout: anytype, stderr: anytype) !void {
    try std.Io.Dir.cwd().createDirPath(io, "build/emu");

    const lang_pass_count = try runLangPassFixtures(allocator, io, stdout, stderr);
    const lang_compile_fail_count = try runCompileFailFixtures(allocator, io, stdout, stderr);
    const lang_runtime_fail_count = try runRuntimeFailFixtures(allocator, io, stdout, stderr);

    var smoke_count: usize = 0;
    for (smoke_cases) |case| {
        if (!matchesFixture(fixture_filter, case.path)) continue;
        try runCase(allocator, io, case, stdout, stderr);
        smoke_count += 1;
    }

    if (lang_pass_count + lang_compile_fail_count + lang_runtime_fail_count + smoke_count == 0) return error.NoMatchingFixtures;
    if (fixture_filter) |filter| {
        try stdout.print("targeted-peddle filter={s}: {d} language pass, {d} compile-fail, {d} runtime-fail, {d} smoke cases\n", .{ filter, lang_pass_count, lang_compile_fail_count, lang_runtime_fail_count, smoke_count });
        return;
    }

    try stdout.print(
        "host-emulated {d} language pass, {d} language compile-fail, {d} language runtime-fail, {d} smoke cases\n",
        .{ lang_pass_count, lang_compile_fail_count, lang_runtime_fail_count, smoke_count },
    );
}

fn runLangPassFixtures(allocator: std.mem.Allocator, io: std.Io, stdout: anytype, stderr: anytype) !usize {
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        freePathList(allocator, paths.items);
        paths.deinit(allocator);
    }
    try collectFixtures(allocator, io, LangPassDir, &paths);
    var count: usize = 0;
    for (paths.items) |path| {
        if (!matchesFixture(fixture_filter, path)) continue;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const case = try caseForLangPassFixture(arena.allocator(), io, path);
        try runCase(allocator, io, case, stdout, stderr);
        count += 1;
    }
    return count;
}

fn runCompileFailFixtures(allocator: std.mem.Allocator, io: std.Io, stdout: anytype, stderr: anytype) !usize {
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        freePathList(allocator, paths.items);
        paths.deinit(allocator);
    }
    try collectFixtures(allocator, io, LangCompileFailDir, &paths);
    var count: usize = 0;
    for (paths.items) |path| {
        if (!matchesFixture(fixture_filter, path)) continue;
        try runCompileFailCase(allocator, io, path, stdout, stderr);
        count += 1;
    }
    return count;
}

fn runRuntimeFailFixtures(allocator: std.mem.Allocator, io: std.Io, stdout: anytype, stderr: anytype) !usize {
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        freePathList(allocator, paths.items);
        paths.deinit(allocator);
    }
    try collectFixtures(allocator, io, LangRuntimeFailDir, &paths);
    var count: usize = 0;
    for (paths.items) |path| {
        if (!matchesFixture(fixture_filter, path)) continue;
        try runRuntimeFailCase(allocator, io, path, stdout, stderr);
        count += 1;
    }
    return count;
}

fn matchesFixture(filter: ?[]const u8, path: []const u8) bool {
    const selection = filter orelse return true;
    var terms = std.mem.splitScalar(u8, selection, ',');
    while (terms.next()) |term| {
        const value = std.mem.trim(u8, term, " \t");
        if (value.len != 0 and std.mem.indexOf(u8, path, value) != null) return true;
    }
    return false;
}

test "targeted Peddle selection is an explicit comma separated path union" {
    try std.testing.expect(matchesFixture(null, "any.zp64"));
    try std.testing.expect(matchesFixture("tictactoe, optimization_", "tests/optimization_flags.zp64"));
    try std.testing.expect(matchesFixture("tictactoe, optimization_", "integration/tictactoe_core.zp64"));
    try std.testing.expect(!matchesFixture("tictactoe, optimization_", "module_loader.zp64"));
    try std.testing.expect(!matchesFixture(" , ", "any.zp64"));
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, case: Case, stdout: anytype, stderr: anytype) !void {
    const out_path = try outputPathFor(allocator, case.path);
    defer allocator.free(out_path);

    var sidecar_args = try dependencySidecarArgsForCase(allocator, io, out_path, case.disk_files, case.sidecar_modules, stderr);
    defer sidecar_args.deinit(allocator);
    defer freeStringList(allocator, sidecar_args.items);

    try compileFixtureWithArgs(allocator, io, case.path, out_path, sidecar_args.items, stderr);

    const prg_file = try prg.readFile(allocator, out_path);
    defer prg_file.deinit(allocator);

    const labels_path = try std.fmt.allocPrint(allocator, "{s}.labels", .{out_path});
    defer allocator.free(labels_path);
    var labels = try Labels.load(allocator, labels_path);
    defer labels.deinit(allocator);

    const disk_files = try prepareDiskFiles(allocator, io, out_path, case.disk_files, stderr);
    defer freeMountedDiskFiles(allocator, disk_files);

    var result = runPrg(allocator, prg_file.bytes, &labels, .{
        .keyboard = case.keyboard,
        .start = case.start,
        .disk_files = disk_files,
        .reu_assertions = case.reu,
        .benchmark_stack = case.benchmark_stack,
    }) catch |err| switch (err) {
        error.Test6502Failure, error.InstructionBudgetExceeded, error.BrkEncountered => {
            if (case.expect_failure) {
                try stdout.print("expected host-emulation failure: {s}\n", .{case.path});
                return;
            }
            try stderr.print("{s}: host-emulation failed: {s}\n", .{ case.path, @errorName(err) });
            return err;
        },
        else => return err,
    };
    defer result.deinit(allocator);

    if (case.expect_failure) {
        try stderr.print("expected host-emulation failure but case passed: {s}\n", .{case.path});
        return error.ExpectedFailureDidNotFail;
    }

    if (case.border) |expected| {
        if (result.border != expected) {
            try stderr.print("{s}: expected border {d}, got {d}\n{s}\n", .{ case.path, expected, result.border, result.screen_text });
            return error.HostAssertionFailed;
        }
    }
    for (case.contains) |needle| {
        if (std.mem.indexOf(u8, result.screen_text, needle) == null) {
            try stderr.print("{s}: screen missing '{s}'\n{s}\n", .{ case.path, needle, result.screen_text });
            return error.HostAssertionFailed;
        }
    }
    for (case.memory) |assertion| {
        if (result.memory[assertion.addr] != assertion.value) {
            try stderr.print("{s}: memory ${x:0>4} expected ${x:0>2}, got ${x:0>2}\n", .{ case.path, assertion.addr, assertion.value, result.memory[assertion.addr] });
            return error.HostAssertionFailed;
        }
    }
    for (case.label_memory) |assertion| {
        const base = labels.get(assertion.label) orelse {
            try stderr.print("{s}: missing label for memory assertion: {s}\n", .{ case.path, assertion.label });
            return error.HostAssertionFailed;
        };
        const addr = base +% assertion.offset;
        if (result.memory[addr] != assertion.value) {
            try stderr.print("{s}: label {s}+{d} (${x:0>4}) expected ${x:0>2}, got ${x:0>2}\n", .{ case.path, assertion.label, assertion.offset, addr, assertion.value, result.memory[addr] });
            return error.HostAssertionFailed;
        }
    }
    for (case.reu, result.reu_values) |assertion, actual| {
        if (actual != assertion.value) {
            try stderr.print("{s}: REU ${x:0>6} expected ${x:0>2}, got ${x:0>2}\n", .{ case.path, assertion.addr, assertion.value, actual });
            return error.HostAssertionFailed;
        }
    }
    for (case.kernal_contains) |needle| {
        if (std.mem.indexOf(u8, result.kernal_output, needle) == null) {
            try stderr.print("{s}: KERNAL output missing '{s}', got '{s}'\n", .{ case.path, needle, result.kernal_output });
            return error.HostAssertionFailed;
        }
    }

    try stdout.print("host-emulated {s}\n", .{case.path});
    // Counters cover CPU instructions actually stepped, excluding intercepted
    // test/KERNAL calls. Keep those counts separate from real C64 timing.
    try stdout.print("host-metrics\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\n", .{
        case.path, out_path, prg_file.bytes.len, result.cycles, result.instructions, result.intercepted_calls,
    });
    if (case.benchmark_stack) |range| {
        if (range.size != 0 and result.software_stack_written == 0) return error.BenchmarkDidNotUseSoftwareStack;
        try stdout.print("host-stack-metrics\t{s}\t{d}\t{d}\t{d}\n", .{
            case.path, result.hardware_stack_peak, result.software_stack_written, range.size,
        });
    }
}

fn runRuntimeFailCase(allocator: std.mem.Allocator, io: std.Io, path: []const u8, stdout: anytype, stderr: anytype) !void {
    const out_path = try outputPathFor(allocator, path);
    defer allocator.free(out_path);
    try compileFixture(allocator, io, path, out_path, stderr);

    const prg_file = try prg.readFile(allocator, out_path);
    defer prg_file.deinit(allocator);

    const labels_path = try std.fmt.allocPrint(allocator, "{s}.labels", .{out_path});
    defer allocator.free(labels_path);
    var labels = try Labels.load(allocator, labels_path);
    defer labels.deinit(allocator);

    var result = runPrg(allocator, prg_file.bytes, &labels, .{}) catch |err| switch (err) {
        error.Test6502Failure, error.BrkEncountered => {
            try stdout.print("expected language runtime failure: {s}\n", .{path});
            return;
        },
        else => return err,
    };
    defer result.deinit(allocator);

    try stderr.print("expected language runtime failure but case passed: {s}\n", .{path});
    return error.ExpectedFailureDidNotFail;
}

fn runCompileFailCase(allocator: std.mem.Allocator, io: std.Io, path: []const u8, stdout: anytype, stderr: anytype) !void {
    const expected = try expectedCompileError(allocator, io, path);
    defer allocator.free(expected);
    const out_path = try outputPathFor(allocator, path);
    defer allocator.free(out_path);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const case = try caseForLangPassFixture(arena.allocator(), io, path);
    var sidecar_args = try dependencySidecarArgsForCase(allocator, io, out_path, case.disk_files, case.sidecar_modules, stderr);
    defer sidecar_args.deinit(allocator);
    defer freeStringList(allocator, sidecar_args.items);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ compiler_executable, "compile", path, "-o", out_path });
    try argv.appendSlice(allocator, sidecar_args.items);
    const result = try std.process.run(allocator, io, .{ .argv = argv.items });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term == .exited and result.term.exited == 0) {
        try stderr.print("expected compile failure but case compiled: {s}\n", .{path});
        return error.ExpectedCompileFailureDidNotFail;
    }
    if (std.mem.indexOf(u8, result.stderr, expected) == null and std.mem.indexOf(u8, result.stdout, expected) == null) {
        try stderr.print("compile failure for {s} did not contain '{s}'\nstderr:\n{s}\nstdout:\n{s}\n", .{ path, expected, result.stderr, result.stdout });
        return error.ExpectedCompileErrorMissing;
    }
    try stdout.print("expected language compile failure: {s}\n", .{path});
}

fn compileFixture(allocator: std.mem.Allocator, io: std.Io, input: []const u8, out_path: []const u8, stderr: anytype) !void {
    try compileFixtureWithArgs(allocator, io, input, out_path, &.{}, stderr);
}

fn compileFixtureWithArgs(allocator: std.mem.Allocator, io: std.Io, input: []const u8, out_path: []const u8, extra_args: []const []const u8, stderr: anytype) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ compiler_executable, "compile", input, "-o", out_path });
    try argv.appendSlice(allocator, extra_args);
    const result = try std.process.run(allocator, io, .{ .argv = argv.items });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        try stderr.print("compile failed for {s}\nstdout:\n{s}\nstderr:\n{s}\n", .{ input, result.stdout, result.stderr });
        return error.CompileFailed;
    }
}

fn dependencySidecarArgsForCase(allocator: std.mem.Allocator, io: std.Io, out_path: []const u8, disk_files: []const DiskFile, sidecar_modules: []const DiskFile, stderr: anytype) !std.ArrayList([]const u8) {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer {
        freeStringList(allocator, args.items);
        args.deinit(allocator);
    }
    for (disk_files) |disk_file| try appendDependencySidecarArgsForModuleSource(allocator, io, out_path, disk_file, &args, stderr);
    for (sidecar_modules) |disk_file| try appendDependencySidecarArgsForModuleSource(allocator, io, out_path, disk_file, &args, stderr);
    return args;
}

fn appendDependencySidecarArgsForModuleSource(allocator: std.mem.Allocator, io: std.Io, out_path: []const u8, disk_file: DiskFile, args: *std.ArrayList([]const u8), stderr: anytype) !void {
    switch (disk_file.source) {
        .module_source => |source_path| {
            const module_out_path = try moduleOutputPathFor(allocator, out_path, disk_file.name);
            defer allocator.free(module_out_path);
            try compileFixture(allocator, io, source_path, module_out_path, stderr);

            const metadata_path = try std.fmt.allocPrint(allocator, "{s}.zpmod.json", .{module_out_path});
            defer allocator.free(metadata_path);
            const relocsim_path = try std.fmt.allocPrint(allocator, "{s}.zpmod.relocsim.json", .{module_out_path});
            defer allocator.free(relocsim_path);
            const metadata_bytes = try std.Io.Dir.cwd().readFileAlloc(io, metadata_path, allocator, .limited(1024 * 1024));
            defer allocator.free(metadata_bytes);
            var metadata = try tass64.parseDependencyModuleJson(allocator, metadata_bytes);
            defer metadata.deinit(allocator);

            const module_spec = try std.fmt.allocPrint(allocator, "{s}={s}", .{ metadata.id, metadata_path });
            errdefer allocator.free(module_spec);
            const reloc_spec = try std.fmt.allocPrint(allocator, "{s}={s}", .{ metadata.id, relocsim_path });
            errdefer allocator.free(reloc_spec);
            const module_flag = try allocator.dupe(u8, "--dependency-module");
            errdefer allocator.free(module_flag);
            const reloc_flag = try allocator.dupe(u8, "--dependency-relocsim");
            errdefer allocator.free(reloc_flag);
            try args.appendSlice(allocator, &.{ module_flag, module_spec, reloc_flag, reloc_spec });
        },
        else => {},
    }
}

fn outputPathFor(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const name = try allocator.dupe(u8, path);
    defer allocator.free(name);
    for (name) |*ch| switch (ch.*) {
        '/', '\\', '.' => ch.* = '_',
        else => {},
    };
    return std.fmt.allocPrint(allocator, "build/emu/{s}.prg", .{name});
}

fn caseForLangPassFixture(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Case {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    var disks: std.ArrayList(DiskFile) = .empty;
    var sidecar_modules: std.ArrayList(DiskFile) = .empty;
    var memory: std.ArrayList(MemoryAssert) = .empty;
    var label_memory: std.ArrayList(LabelMemoryAssert) = .empty;
    var reu: std.ArrayList(ReuAssert) = .empty;
    var start: StartMode = .main;
    var benchmark_stack: ?StackRange = null;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "//")) continue;
        const comment = std.mem.trim(u8, line[2..], " \t");
        if (!std.mem.startsWith(u8, comment, EmuMarkerPrefix)) continue;

        const marker = comment[EmuMarkerPrefix.len..];
        if (std.mem.startsWith(u8, marker, "error:")) {
            continue;
        } else if (std.mem.startsWith(u8, marker, "start:")) {
            const value = std.mem.trim(u8, marker["start:".len..], " \t");
            if (std.mem.eql(u8, value, "main")) {
                start = .main;
            } else if (std.mem.eql(u8, value, "program_entry")) {
                start = .program_entry;
            } else {
                return error.InvalidEmuFixtureMetadata;
            }
        } else if (std.mem.startsWith(u8, marker, "benchmark-stack:")) {
            if (benchmark_stack != null) return error.InvalidEmuFixtureMetadata;
            benchmark_stack = try parseStackRange(marker["benchmark-stack:".len..]);
        } else if (std.mem.startsWith(u8, marker, "disk:")) {
            const value = std.mem.trim(u8, marker["disk:".len..], " \t");
            if (value.len == 0) return error.InvalidEmuFixtureMetadata;
            try disks.append(allocator, .{ .name = try allocator.dupe(u8, value) });
        } else if (std.mem.startsWith(u8, marker, "module:")) {
            try disks.append(allocator, try parseModuleDiskFile(allocator, marker["module:".len..]));
        } else if (std.mem.startsWith(u8, marker, "sidecar-module:")) {
            try sidecar_modules.append(allocator, try parseModuleDiskFile(allocator, marker["sidecar-module:".len..]));
        } else if (std.mem.startsWith(u8, marker, "memory:")) {
            try memory.append(allocator, try parseMemoryAssert(marker["memory:".len..]));
        } else if (std.mem.startsWith(u8, marker, "label-memory:")) {
            try label_memory.append(allocator, try parseLabelMemoryAssert(allocator, marker["label-memory:".len..]));
        } else if (std.mem.startsWith(u8, marker, "reu:")) {
            try reu.append(allocator, try parseReuAssert(marker["reu:".len..]));
        } else {
            return error.InvalidEmuFixtureMetadata;
        }
    }

    return .{
        .path = path,
        .start = start,
        .benchmark_stack = benchmark_stack,
        .disk_files = try disks.toOwnedSlice(allocator),
        .sidecar_modules = try sidecar_modules.toOwnedSlice(allocator),
        .memory = try memory.toOwnedSlice(allocator),
        .label_memory = try label_memory.toOwnedSlice(allocator),
        .reu = try reu.toOwnedSlice(allocator),
    };
}

fn parseStackRange(text: []const u8) !StackRange {
    const value = std.mem.trim(u8, text, " \t");
    if (std.mem.eql(u8, value, "none")) return .{ .base = 0, .size = 0 };
    const plus = std.mem.indexOfScalar(u8, value, '+') orelse return error.InvalidEmuFixtureMetadata;
    const base = try parsePrefixedInt(u16, value[0..plus]);
    const size = try parsePrefixedInt(u16, value[plus + 1 ..]);
    if (base < 0x0200 or size == 0 or @as(u32, base) + size > 0x10000) return error.InvalidEmuFixtureMetadata;
    return .{ .base = base, .size = size };
}

fn parseModuleDiskFile(allocator: std.mem.Allocator, text: []const u8) !DiskFile {
    var filename: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    var fields = std.mem.tokenizeAny(u8, text, " \t");
    while (fields.next()) |field| {
        if (std.mem.startsWith(u8, field, "filename=")) {
            if (filename != null) return error.InvalidEmuFixtureMetadata;
            const value = field["filename=".len..];
            if (value.len == 0) return error.InvalidEmuFixtureMetadata;
            filename = try allocator.dupe(u8, value);
        } else if (std.mem.startsWith(u8, field, "source=")) {
            if (source != null) return error.InvalidEmuFixtureMetadata;
            const value = field["source=".len..];
            if (value.len == 0) return error.InvalidEmuFixtureMetadata;
            source = try allocator.dupe(u8, value);
        } else {
            return error.InvalidEmuFixtureMetadata;
        }
    }
    return .{
        .name = filename orelse return error.InvalidEmuFixtureMetadata,
        .source = .{ .module_source = source orelse return error.InvalidEmuFixtureMetadata },
    };
}

fn parseMemoryAssert(text: []const u8) !MemoryAssert {
    var parts = std.mem.splitScalar(u8, text, '=');
    const addr_text = std.mem.trim(u8, parts.next() orelse return error.InvalidEmuFixtureMetadata, " \t");
    const value_text = std.mem.trim(u8, parts.next() orelse return error.InvalidEmuFixtureMetadata, " \t");
    if (parts.next() != null) return error.InvalidEmuFixtureMetadata;
    return .{
        .addr = try parsePrefixedInt(u16, addr_text),
        .value = try parsePrefixedInt(u8, value_text),
    };
}

fn parseReuAssert(text: []const u8) !ReuAssert {
    var parts = std.mem.splitScalar(u8, text, '=');
    const addr_text = std.mem.trim(u8, parts.next() orelse return error.InvalidEmuFixtureMetadata, " \t");
    const value_text = std.mem.trim(u8, parts.next() orelse return error.InvalidEmuFixtureMetadata, " \t");
    if (parts.next() != null) return error.InvalidEmuFixtureMetadata;
    return .{
        .addr = try parsePrefixedInt(u32, addr_text),
        .value = try parsePrefixedInt(u8, value_text),
    };
}

fn parseLabelMemoryAssert(allocator: std.mem.Allocator, text: []const u8) !LabelMemoryAssert {
    var parts = std.mem.splitScalar(u8, text, '=');
    const lhs = std.mem.trim(u8, parts.next() orelse return error.InvalidEmuFixtureMetadata, " \t");
    const value_text = std.mem.trim(u8, parts.next() orelse return error.InvalidEmuFixtureMetadata, " \t");
    if (parts.next() != null or lhs.len == 0) return error.InvalidEmuFixtureMetadata;

    var label = lhs;
    var offset: u16 = 0;
    if (std.mem.indexOfScalar(u8, lhs, '+')) |plus| {
        label = std.mem.trim(u8, lhs[0..plus], " \t");
        offset = try parsePrefixedInt(u16, std.mem.trim(u8, lhs[plus + 1 ..], " \t"));
    }
    if (label.len == 0) return error.InvalidEmuFixtureMetadata;
    return .{
        .label = try allocator.dupe(u8, label),
        .offset = offset,
        .value = try parsePrefixedInt(u8, value_text),
    };
}

fn parsePrefixedInt(comptime T: type, text: []const u8) !T {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return error.InvalidEmuFixtureMetadata;
    if (std.mem.startsWith(u8, trimmed, "$")) {
        return std.fmt.parseInt(T, trimmed[1..], 16);
    }
    if (std.mem.startsWith(u8, trimmed, "0x")) {
        return std.fmt.parseInt(T, trimmed[2..], 16);
    }
    return std.fmt.parseInt(T, trimmed, 10);
}

const MountedDiskFile = struct {
    name: []u8,
    bytes: []u8,
};

fn prepareDiskFiles(allocator: std.mem.Allocator, io: std.Io, out_path: []const u8, specs: []const DiskFile, stderr: anytype) ![]MountedDiskFile {
    const files = try allocator.alloc(MountedDiskFile, specs.len);
    var initialized: usize = 0;
    errdefer {
        freeMountedDiskFileContents(allocator, files[0..initialized]);
        allocator.free(files);
    }

    for (specs, 0..) |spec, i| {
        const path = try diskFilePath(allocator, io, out_path, spec.name, spec.source, stderr);
        defer allocator.free(path);
        files[i] = .{
            .name = try normalizeDiskName(allocator, spec.name),
            .bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)),
        };
        initialized += 1;
    }
    return files;
}

fn diskFilePath(allocator: std.mem.Allocator, io: std.Io, out_path: []const u8, disk_name: []const u8, source_spec: DiskFileSource, stderr: anytype) ![]u8 {
    return switch (source_spec) {
        .output_suffix => |suffix| std.fmt.allocPrint(allocator, "{s}{s}", .{ out_path, suffix }),
        .path => |path| allocator.dupe(u8, path),
        .module_source => |source_path| blk: {
            const module_out_path = try moduleOutputPathFor(allocator, out_path, disk_name);
            defer allocator.free(module_out_path);
            try compileFixture(allocator, io, source_path, module_out_path, stderr);
            break :blk std.fmt.allocPrint(allocator, "{s}.zpmod.disk.prg", .{module_out_path});
        },
    };
}

fn moduleOutputPathFor(allocator: std.mem.Allocator, out_path: []const u8, disk_name: []const u8) ![]u8 {
    const normalized = try normalizeDiskName(allocator, disk_name);
    defer allocator.free(normalized);
    return std.fmt.allocPrint(allocator, "{s}.{s}.module.prg", .{ out_path, normalized });
}

fn freeMountedDiskFiles(allocator: std.mem.Allocator, files: []const MountedDiskFile) void {
    freeMountedDiskFileContents(allocator, files);
    allocator.free(files);
}

fn freeMountedDiskFileContents(allocator: std.mem.Allocator, files: []const MountedDiskFile) void {
    for (files) |file| {
        allocator.free(file.name);
        allocator.free(file.bytes);
    }
}

fn normalizeDiskName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, name.len);
    for (name, 0..) |ch, i| out[i] = normalizeDiskByte(ch);
    return out;
}

fn normalizeDiskByte(ch: u8) u8 {
    return switch (ch) {
        'a'...'z' => ch - ('a' - 'A'),
        else => ch,
    };
}

fn findMountedDiskFile(files: []const MountedDiskFile, filename: []const u8) ?*const MountedDiskFile {
    for (files) |*file| {
        if (std.mem.eql(u8, file.name, filename)) return file;
    }
    return null;
}

fn expectedCompileError(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const marker_index = std.mem.indexOf(u8, bytes, CompileErrorMarker) orelse return error.MissingCompileErrorMarker;
    const text_start = marker_index + CompileErrorMarker.len;
    const line_end = std.mem.indexOfScalarPos(u8, bytes, text_start, '\n') orelse bytes.len;
    const expected = std.mem.trim(u8, bytes[text_start..line_end], " \t\r");
    if (expected.len == 0) return error.MissingCompileErrorMarker;
    return try allocator.dupe(u8, expected);
}

fn collectFixtures(allocator: std.mem.Allocator, io: std.Io, root: []const u8, paths: *std.ArrayList([]const u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".") or std.mem.startsWith(u8, entry.name, "_")) continue;
        const child = try std.fs.path.join(allocator, &.{ root, entry.name });
        if (entry.kind == .directory) {
            defer allocator.free(child);
            try collectFixtures(allocator, io, child, paths);
        } else if (entry.kind == .file and isZeroPageSourcePath(entry.name)) {
            try paths.append(allocator, child);
        } else {
            allocator.free(child);
        }
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanString);
}

fn isZeroPageSourcePath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zp64");
}

fn lessThanString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn freePathList(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
}

fn freeStringList(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator.free(string);
}

const Labels = struct {
    bytes: []u8,
    map: std.StringHashMap(u16),
    hooks: std.AutoHashMap(u16, []const u8),

    fn load(allocator: std.mem.Allocator, path: []const u8) !Labels {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(1024 * 1024));
        errdefer allocator.free(bytes);
        var map = std.StringHashMap(u16).init(allocator);
        errdefer map.deinit();
        var hooks = std.AutoHashMap(u16, []const u8).init(allocator);
        errdefer hooks.deinit();

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            var parts = std.mem.tokenizeAny(u8, line, " \t\r");
            const kind = parts.next() orelse continue;
            if (!std.mem.eql(u8, kind, "al")) continue;
            const addr_text = parts.next() orelse continue;
            const raw_label = parts.next() orelse continue;
            const label = if (std.mem.startsWith(u8, raw_label, ".")) raw_label[1..] else raw_label;
            const addr = try std.fmt.parseInt(u16, addr_text, 16);
            try map.put(label, addr);
            if (std.mem.startsWith(u8, label, "zeropage_test6502_")) {
                try hooks.put(addr, label);
            }
        }

        return .{ .bytes = bytes, .map = map, .hooks = hooks };
    }

    fn deinit(self: *Labels, allocator: std.mem.Allocator) void {
        self.hooks.deinit();
        self.map.deinit();
        allocator.free(self.bytes);
    }

    fn get(self: *const Labels, name: []const u8) ?u16 {
        return self.map.get(name);
    }

    fn hook(self: *const Labels, addr: u16) ?[]const u8 {
        return self.hooks.get(addr);
    }
};

const RunResult = struct {
    screen_text: []u8,
    kernal_output: []u8,
    memory: []u8,
    reu_values: []u8,
    border: u8,
    cycles: u64,
    instructions: u64,
    intercepted_calls: u64,
    hardware_stack_peak: u8,
    software_stack_written: u16,

    fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.screen_text);
        allocator.free(self.kernal_output);
        allocator.free(self.memory);
        allocator.free(self.reu_values);
    }
};

const RunOptions = struct {
    keyboard: []const u8 = &.{},
    start: StartMode = .main,
    disk_files: []const MountedDiskFile = &.{},
    reu_assertions: []const ReuAssert = &.{},
    benchmark_stack: ?StackRange = null,
};

const TestState = struct {
    allocator: std.mem.Allocator,
    hit_counts: std.AutoHashMap(u16, u32),
    kernal_output: std.ArrayList(u8) = .empty,
    keyboard: []const u8 = &.{},
    keyboard_index: usize = 0,
    passed: bool = false,
    failed: bool = false,
    string_ptr: u16 = TestStringPtr,
    disk_files: []const MountedDiskFile = &.{},
    kernal_filename: std.ArrayList(u8) = .empty,
    kernal_lfn: u8 = 0,
    kernal_device: u8 = 0,
    kernal_secondary: u8 = 0,

    fn init(allocator: std.mem.Allocator) TestState {
        return .{ .allocator = allocator, .hit_counts = .init(allocator) };
    }

    fn deinit(self: *TestState) void {
        self.hit_counts.deinit();
        self.kernal_output.deinit(self.allocator);
        self.kernal_filename.deinit(self.allocator);
    }
};

fn runPrg(allocator: std.mem.Allocator, bytes: []const u8, labels: *const Labels, options: RunOptions) !RunResult {
    const parsed = try prg.read(bytes);
    const machine = c.zeropage_peddle_create() orelse return error.EmulatorCreateFailed;
    defer c.zeropage_peddle_destroy(machine);

    c.zeropage_peddle_clear_memory(machine);
    c.zeropage_peddle_load(machine, parsed.load_address, parsed.payload.ptr, parsed.payload.len);
    c.zeropage_peddle_reset(machine);
    c.zeropage_peddle_set_sp(machine, 0xff);
    c.zeropage_peddle_write(machine, 0x0001, 0x37);
    const start_pc = switch (options.start) {
        .main => if (labels.get("zeropage_zp_enter") != null) labels.get("zeropage_entry") orelse 0x080d else labels.get("main") orelse 0x080d,
        .program_entry => labels.get("zeropage_entry") orelse labels.get("main") orelse 0x080d,
    };
    c.zeropage_peddle_set_pc(machine, start_pc);
    const initial_regs = c.zeropage_peddle_regs(machine);
    var intercepted_calls: u64 = 0;
    var minimum_sp = initial_regs.sp;
    if (options.benchmark_stack) |range| c.zeropage_peddle_watch_writes(machine, range.base, range.size);

    var state = TestState.init(allocator);
    defer state.deinit();
    state.keyboard = options.keyboard;
    state.string_ptr = labels.get("zeropage_string_ptr") orelse TestStringPtr;
    state.disk_files = options.disk_files;

    const exit = labels.get("zeropage_test_exit");
    var budget: usize = 1_000_000;
    while (budget > 0) : (budget -= 1) {
        const regs = c.zeropage_peddle_regs(machine);
        minimum_sp = @min(minimum_sp, regs.sp);
        const pc: u16 = @intCast(regs.pc);
        if (exit != null and pc == exit.?) break;
        if (state.passed) break;
        if (state.failed) return error.Test6502Failure;

        const opcode = c.zeropage_peddle_read(machine, pc);
        if (opcode == 0x00) return error.BrkEncountered;
        if (opcode == 0x20) {
            const target = read16(machine, pc +% 1);
            if (target == KernalChrout) {
                intercepted_calls += 1;
                try state.kernal_output.append(allocator, screenDecode(@intCast(regs.a)));
                c.zeropage_peddle_set_pc(machine, pc + 3);
                continue;
            }
            if (target == KernalGetin) {
                intercepted_calls += 1;
                const value: u8 = if (state.keyboard_index < state.keyboard.len) blk: {
                    const ch = state.keyboard[state.keyboard_index];
                    state.keyboard_index += 1;
                    break :blk ch;
                } else 0;
                c.zeropage_peddle_set_a(machine, value);
                c.zeropage_peddle_set_pc(machine, pc + 3);
                continue;
            }
            if (target == KernalSetnam) {
                intercepted_calls += 1;
                try handleKernalSetnam(machine, &state, regs);
                c.zeropage_peddle_set_pc(machine, pc + 3);
                continue;
            }
            if (target == KernalSetlfs) {
                intercepted_calls += 1;
                handleKernalSetlfs(&state, regs);
                c.zeropage_peddle_set_pc(machine, pc + 3);
                continue;
            }
            if (target == KernalLoad) {
                intercepted_calls += 1;
                try handleKernalLoad(machine, &state, regs);
                c.zeropage_peddle_set_pc(machine, pc + 3);
                continue;
            }
            if (labels.hook(target)) |label| {
                intercepted_calls += 1;
                try handleTest6502Hook(machine, &state, label, regs);
                c.zeropage_peddle_set_pc(machine, pc + 3);
                continue;
            }
        }

        c.zeropage_peddle_step_instruction(machine);
    } else {
        return error.InstructionBudgetExceeded;
    }

    const final_regs = c.zeropage_peddle_regs(machine);
    return .{
        .screen_text = try readScreenText(allocator, machine),
        .kernal_output = try state.kernal_output.toOwnedSlice(allocator),
        .memory = try readMemory(allocator, machine),
        .reu_values = try readReuValues(allocator, machine, options.reu_assertions),
        .border = c.zeropage_peddle_read(machine, BorderColor),
        .cycles = final_regs.cycles - initial_regs.cycles,
        .instructions = final_regs.instructions - initial_regs.instructions,
        .intercepted_calls = intercepted_calls,
        .hardware_stack_peak = initial_regs.sp - minimum_sp,
        .software_stack_written = c.zeropage_peddle_write_high_water(machine),
    };
}

fn handleKernalSetnam(machine: *c.ZeroPagePeddle, state: *TestState, regs: c.ZeroPagePeddleRegs) !void {
    state.kernal_filename.clearRetainingCapacity();
    const len: usize = regs.a;
    const ptr = @as(u16, regs.x) | (@as(u16, regs.y) << 8);
    for (0..len) |offset| {
        const ch = c.zeropage_peddle_read(machine, ptr +% @as(u16, @intCast(offset)));
        try state.kernal_filename.append(state.allocator, normalizeDiskByte(ch));
    }
}

fn handleKernalSetlfs(state: *TestState, regs: c.ZeroPagePeddleRegs) void {
    state.kernal_lfn = regs.a;
    state.kernal_device = regs.x;
    state.kernal_secondary = regs.y;
}

fn handleKernalLoad(machine: *c.ZeroPagePeddle, state: *const TestState, regs: c.ZeroPagePeddleRegs) !void {
    const file = findMountedDiskFile(state.disk_files, state.kernal_filename.items) orelse {
        c.zeropage_peddle_set_p(machine, @intCast(regs.p | 0x01));
        return;
    };
    _ = state.kernal_lfn;
    _ = state.kernal_device;
    _ = state.kernal_secondary;

    const parsed = try prg.read(file.bytes);
    const requested_addr = @as(u16, regs.x) | (@as(u16, regs.y) << 8);
    const load_addr = if (regs.a == 0) parsed.load_address else requested_addr;
    if (@as(usize, load_addr) + parsed.payload.len > 65536) return error.PrgTooLarge;
    c.zeropage_peddle_load(machine, load_addr, parsed.payload.ptr, parsed.payload.len);
    const end_addr = @as(u32, load_addr) + @as(u32, @intCast(parsed.payload.len));
    c.zeropage_peddle_set_x(machine, @intCast(end_addr & 0x00ff));
    c.zeropage_peddle_set_y(machine, @intCast((end_addr >> 8) & 0x00ff));
    c.zeropage_peddle_set_p(machine, @intCast(regs.p & 0xfe));
}

fn handleTest6502Hook(machine: *c.ZeroPagePeddle, state: *TestState, label: []const u8, regs: c.ZeroPagePeddleRegs) !void {
    const prefix = "zeropage_test6502_";
    const body = label[prefix.len..];
    if (std.mem.startsWith(u8, body, "mark_")) {
        return;
    }
    if (std.mem.startsWith(u8, body, "prime_regs_")) {
        const parts = try parseHookParts(body["prime_regs_".len..], 5);
        _ = parts[0];
        c.zeropage_peddle_set_a(machine, @intCast(parts[1] & 0xff));
        c.zeropage_peddle_set_x(machine, @intCast(parts[2] & 0xff));
        c.zeropage_peddle_set_y(machine, @intCast(parts[3] & 0xff));
        c.zeropage_peddle_set_p(machine, @intCast(parts[4] & 0xff));
        return;
    }
    if (std.mem.startsWith(u8, body, "snapshot_")) {
        return;
    }
    if (std.mem.startsWith(u8, body, "hit_")) {
        const id = try parseHookPart(body["hit_".len..]);
        const result = try state.hit_counts.getOrPut(id);
        if (!result.found_existing) result.value_ptr.* = 0;
        result.value_ptr.* += 1;
        return;
    }
    if (std.mem.startsWith(u8, body, "expect_hit_count_")) {
        const parts = try parseHookParts(body["expect_hit_count_".len..], 2);
        const actual = state.hit_counts.get(parts[0]) orelse 0;
        if (actual != parts[1]) return error.Test6502Failure;
        return;
    }
    if (std.mem.startsWith(u8, body, "expect_equal_u8_")) return expectReg(body["expect_equal_u8_".len..], regs.a);
    if (std.mem.startsWith(u8, body, "expect_equal_i8_")) return expectReg(body["expect_equal_i8_".len..], regs.a);
    if (std.mem.startsWith(u8, body, "expect_equal_bool_")) return expectReg(body["expect_equal_bool_".len..], regs.a);
    if (std.mem.startsWith(u8, body, "expect_equal_u16_")) {
        const parts = try parseHookParts(body["expect_equal_u16_".len..], 2);
        _ = parts[0];
        const actual = @as(u16, @intCast(regs.a)) | (@as(u16, @intCast(regs.x)) << 8);
        if (actual != parts[1]) return error.Test6502Failure;
        return;
    }
    if (std.mem.startsWith(u8, body, "expect_string_")) {
        try expectString(machine, body["expect_string_".len..], regs, state.string_ptr);
        return;
    }
    if (std.mem.startsWith(u8, body, "expect_a_")) return expectReg(body["expect_a_".len..], regs.a);
    if (std.mem.startsWith(u8, body, "expect_x_")) return expectReg(body["expect_x_".len..], regs.x);
    if (std.mem.startsWith(u8, body, "expect_y_")) return expectReg(body["expect_y_".len..], regs.y);
    if (std.mem.startsWith(u8, body, "expect_sp_")) return expectReg(body["expect_sp_".len..], regs.sp);
    if (std.mem.startsWith(u8, body, "expect_p_")) {
        const parts = try parseHookParts(body["expect_p_".len..], 3);
        if ((regs.p & @as(u8, @intCast(parts[1] & 0xff))) != @as(u8, @intCast(parts[2] & 0xff))) return error.Test6502Failure;
        return;
    }
    if (std.mem.startsWith(u8, body, "expect_mem_u8_")) {
        const parts = try parseHookParts(body["expect_mem_u8_".len..], 3);
        if (c.zeropage_peddle_read(machine, parts[1]) != @as(u8, @intCast(parts[2] & 0xff))) return error.Test6502Failure;
        return;
    }
    if (std.mem.startsWith(u8, body, "expect_mem_u16_")) {
        const parts = try parseHookParts(body["expect_mem_u16_".len..], 3);
        if (read16(machine, parts[1]) != parts[2]) return error.Test6502Failure;
        return;
    }
    if (std.mem.startsWith(u8, body, "expect_stack_u8_")) {
        const parts = try parseHookParts(body["expect_stack_u8_".len..], 3);
        const addr: u16 = 0x0100 + @as(u16, @intCast((@as(u16, regs.sp) + 1 + parts[1]) & 0xff));
        if (c.zeropage_peddle_read(machine, addr) != @as(u8, @intCast(parts[2] & 0xff))) return error.Test6502Failure;
        return;
    }
    if (std.mem.eql(u8, body, "pass")) {
        state.passed = true;
        return;
    }
    if (std.mem.startsWith(u8, body, "fail_")) {
        state.failed = true;
        return;
    }
    return error.UnknownTest6502Hook;
}

fn expectReg(text: []const u8, actual: anytype) !void {
    const parts = try parseHookParts(text, 2);
    _ = parts[0];
    if (@as(u16, @intCast(actual)) != parts[1]) return error.Test6502Failure;
}

fn expectString(machine: *c.ZeroPagePeddle, text: []const u8, regs: c.ZeroPagePeddleRegs, string_ptr: u16) !void {
    var it = std.mem.splitScalar(u8, text, '_');
    _ = try parseHookPart(it.next() orelse return error.InvalidTest6502Hook);
    const expected_len = try parseHookPart(it.next() orelse return error.InvalidTest6502Hook);
    const expected_hex = it.next() orelse return error.InvalidTest6502Hook;
    if (it.next() != null) return error.InvalidTest6502Hook;
    if (expected_hex.len != expected_len * 2) return error.InvalidTest6502Hook;
    if (@as(u16, @intCast(regs.a)) != expected_len) return error.Test6502Failure;
    const actual_ptr = read16(machine, string_ptr);
    for (0..expected_len) |offset| {
        const expected = try std.fmt.parseInt(u8, expected_hex[offset * 2 .. offset * 2 + 2], 16);
        if (c.zeropage_peddle_read(machine, actual_ptr +% @as(u16, @intCast(offset))) != expected) return error.Test6502Failure;
    }
}

fn parseHookPart(text: []const u8) !u16 {
    return std.fmt.parseInt(u16, text, 16);
}

fn parseHookParts(text: []const u8, comptime count: usize) ![count]u16 {
    var out: [count]u16 = undefined;
    var it = std.mem.splitScalar(u8, text, '_');
    for (0..count) |i| {
        out[i] = try parseHookPart(it.next() orelse return error.InvalidTest6502Hook);
    }
    return out;
}

fn read16(machine: *c.ZeroPagePeddle, addr: u16) u16 {
    return @as(u16, c.zeropage_peddle_read(machine, addr)) | (@as(u16, c.zeropage_peddle_read(machine, addr +% 1)) << 8);
}

fn readMemory(allocator: std.mem.Allocator, machine: *c.ZeroPagePeddle) ![]u8 {
    const out = try allocator.alloc(u8, 65536);
    for (out, 0..) |*byte, addr| byte.* = c.zeropage_peddle_read(machine, @intCast(addr));
    return out;
}

fn readReuValues(allocator: std.mem.Allocator, machine: *c.ZeroPagePeddle, assertions: []const ReuAssert) ![]u8 {
    const out = try allocator.alloc(u8, assertions.len);
    for (assertions, out) |assertion, *value| value.* = c.zeropage_peddle_read_reu(machine, assertion.addr);
    return out;
}

fn readScreenText(allocator: std.mem.Allocator, machine: *c.ZeroPagePeddle) ![]u8 {
    var out = try allocator.alloc(u8, (40 + 1) * 25);
    var index: usize = 0;
    for (0..25) |row| {
        for (0..40) |col| {
            out[index] = screenDecode(c.zeropage_peddle_read(machine, ScreenStart + @as(u16, @intCast(row * 40 + col))));
            index += 1;
        }
        out[index] = '\n';
        index += 1;
    }
    return out;
}

fn screenDecode(code: u8) u8 {
    return switch (code) {
        1...26 => 'A' + code - 1,
        32...95 => code,
        else => '.',
    };
}

test "Peddle stack write extent counts CPU stores of unchanged bytes" {
    const machine = c.zeropage_peddle_create() orelse return error.EmulatorCreateFailed;
    defer c.zeropage_peddle_destroy(machine);
    const code = [_]u8{ 0xa9, 0x00, 0x8d, 0x04, 0xc8, 0x8d, 0x00, 0xc9 };
    c.zeropage_peddle_load(machine, 0x2000, &code, code.len);
    c.zeropage_peddle_set_pc(machine, 0x2000);
    c.zeropage_peddle_watch_writes(machine, 0xc800, 0x100);
    c.zeropage_peddle_write(machine, 0xc8ff, 42);
    try std.testing.expectEqual(@as(u16, 0), c.zeropage_peddle_write_high_water(machine));
    for (0..3) |_| c.zeropage_peddle_step_instruction(machine);
    try std.testing.expectEqual(@as(u16, 5), c.zeropage_peddle_write_high_water(machine));
}

test "Peddle counters include branch and indexed page crossing cycles" {
    const machine = c.zeropage_peddle_create() orelse return error.EmulatorCreateFailed;
    defer c.zeropage_peddle_destroy(machine);
    c.zeropage_peddle_reset(machine);
    // LDX #1; LDA $20ff,X (page cross); BNE +0 (taken); NOP.
    const code = [_]u8{ 0xa2, 1, 0xbd, 0xff, 0x20, 0xd0, 0, 0xea };
    c.zeropage_peddle_load(machine, 0x2000, &code, code.len);
    c.zeropage_peddle_write(machine, 0x2100, 1);
    c.zeropage_peddle_set_pc(machine, 0x2000);
    for (0..4) |_| c.zeropage_peddle_step_instruction(machine);
    const regs = c.zeropage_peddle_regs(machine);
    try std.testing.expectEqual(@as(u64, 12), regs.cycles);
    try std.testing.expectEqual(@as(u64, 4), regs.instructions);
}

test "Peddle counters include taken branch page crossing" {
    const machine = c.zeropage_peddle_create() orelse return error.EmulatorCreateFailed;
    defer c.zeropage_peddle_destroy(machine);
    c.zeropage_peddle_reset(machine);
    const code = [_]u8{ 0xd0, 2 }; // BNE from $20fc to $2100.
    c.zeropage_peddle_load(machine, 0x20fc, &code, code.len);
    c.zeropage_peddle_set_pc(machine, 0x20fc);
    c.zeropage_peddle_set_p(machine, 0x20);
    c.zeropage_peddle_step_instruction(machine);
    try std.testing.expectEqual(@as(u64, 4), c.zeropage_peddle_regs(machine).cycles);
}

test "virtual disk names normalize and resolve multiple mounted files" {
    const allocator = std.testing.allocator;
    var files = try allocator.alloc(MountedDiskFile, 2);
    files[0] = .{ .name = try normalizeDiskName(allocator, "enemyrt"), .bytes = try allocator.dupe(u8, &.{ 0x00, 0x90, 0x4c }) };
    files[1] = .{ .name = try normalizeDiskName(allocator, "mathmod"), .bytes = try allocator.dupe(u8, &.{ 0x00, 0x91, 0x60 }) };
    defer freeMountedDiskFiles(allocator, files);

    const first_name = try normalizeDiskName(allocator, "ENEMYRT");
    defer allocator.free(first_name);
    const second_name = try normalizeDiskName(allocator, "MATHMOD");
    defer allocator.free(second_name);

    try std.testing.expectEqual(@as(u8, 0x4c), findMountedDiskFile(files, first_name).?.bytes[2]);
    try std.testing.expectEqual(@as(u8, 0x60), findMountedDiskFile(files, second_name).?.bytes[2]);
    try std.testing.expect(findMountedDiskFile(files, "MISSING") == null);
}

test "virtual disk name normalization preserves supported punctuation" {
    const normalized = try normalizeDiskName(std.testing.allocator, "enemy-rt_1");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("ENEMY-RT_1", normalized);
}

test "virtual disk output suffix resolves beside compiled PRG path" {
    var stderr_buffer: [128]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(std.Options.debug_io, &stderr_buffer);
    const path = try diskFilePath(
        std.testing.allocator,
        std.Options.debug_io,
        "build/emu/demo.prg",
        "enemyrt",
        .{ .output_suffix = ".zpmod.disk.prg" },
        &stderr.interface,
    );
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("build/emu/demo.prg.zpmod.disk.prg", path);
}

test "module fixture metadata parses mounted module source" {
    const allocator = std.testing.allocator;
    const spec = try parseModuleDiskFile(allocator, "filename=enemyrt source=tests/fixtures/emu/modules/enemy_runtime.zp64");
    defer allocator.free(spec.name);
    defer switch (spec.source) {
        .module_source => |source| allocator.free(source),
        else => {},
    };

    try std.testing.expectEqualStrings("enemyrt", spec.name);
    try std.testing.expectEqualStrings("tests/fixtures/emu/modules/enemy_runtime.zp64", spec.source.module_source);
}

test "language fixture metadata parses sidecar-only module source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const case = try caseForLangPassFixture(arena.allocator(), std.Options.debug_io, "tests/fixtures/emu/lang/pass/parity/abi/module_dependency_on_demand_policy_missing_disk.zp64");

    try std.testing.expectEqual(@as(usize, 1), case.sidecar_modules.len);
    try std.testing.expectEqualStrings("mathcore", case.sidecar_modules[0].name);
    try std.testing.expectEqualStrings("tests/fixtures/emu/modules/math_core_dispatch.zp64", case.sidecar_modules[0].source.module_source);
}

test "module output path is stable per disk filename" {
    const path = try moduleOutputPathFor(std.testing.allocator, "build/emu/host.prg", "enemyrt");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("build/emu/host.prg.ENEMYRT.module.prg", path);
}

test "KERNAL LOAD missing virtual file sets carry" {
    const machine = c.zeropage_peddle_create() orelse return error.EmulatorCreateFailed;
    defer c.zeropage_peddle_destroy(machine);
    c.zeropage_peddle_clear_memory(machine);
    c.zeropage_peddle_set_p(machine, 0x20);

    var state = TestState.init(std.testing.allocator);
    defer state.deinit();
    try state.kernal_filename.appendSlice(std.testing.allocator, "MISSING");

    try handleKernalLoad(machine, &state, .{
        .pc = 0,
        .pc0 = 0,
        .sp = 0,
        .a = 0,
        .x = 0,
        .y = 0,
        .p = 0x20,
        .cycles = 0,
        .instructions = 0,
    });
    try std.testing.expectEqual(@as(u8, 0x21), c.zeropage_peddle_regs(machine).p);
}

test "KERNAL LOAD virtual file honors PRG and requested addresses" {
    const allocator = std.testing.allocator;
    const machine = c.zeropage_peddle_create() orelse return error.EmulatorCreateFailed;
    defer c.zeropage_peddle_destroy(machine);
    c.zeropage_peddle_clear_memory(machine);

    var files = try allocator.alloc(MountedDiskFile, 1);
    files[0] = .{
        .name = try normalizeDiskName(allocator, "enemyrt"),
        .bytes = try allocator.dupe(u8, &.{ 0x00, 0x90, 0x4c, 0xaa, 0x60 }),
    };
    defer freeMountedDiskFiles(allocator, files);

    var state = TestState.init(allocator);
    defer state.deinit();
    state.disk_files = files;
    try state.kernal_filename.appendSlice(allocator, "ENEMYRT");

    try handleKernalLoad(machine, &state, .{
        .pc = 0,
        .pc0 = 0,
        .sp = 0,
        .a = 0,
        .x = 0x00,
        .y = 0x91,
        .p = 0x21,
        .cycles = 0,
        .instructions = 0,
    });
    var regs = c.zeropage_peddle_regs(machine);
    try std.testing.expectEqual(@as(u8, 0x4c), c.zeropage_peddle_read(machine, 0x9000));
    try std.testing.expectEqual(@as(u8, 0x03), regs.x);
    try std.testing.expectEqual(@as(u8, 0x90), regs.y);
    try std.testing.expectEqual(@as(u8, 0x20), regs.p);

    c.zeropage_peddle_write(machine, 0x9000, 0);
    try handleKernalLoad(machine, &state, .{
        .pc = 0,
        .pc0 = 0,
        .sp = 0,
        .a = 1,
        .x = 0x00,
        .y = 0x91,
        .p = 0x21,
        .cycles = 0,
        .instructions = 0,
    });
    regs = c.zeropage_peddle_regs(machine);
    try std.testing.expectEqual(@as(u8, 0), c.zeropage_peddle_read(machine, 0x9000));
    try std.testing.expectEqual(@as(u8, 0x4c), c.zeropage_peddle_read(machine, 0x9100));
    try std.testing.expectEqual(@as(u8, 0x03), regs.x);
    try std.testing.expectEqual(@as(u8, 0x91), regs.y);
    try std.testing.expectEqual(@as(u8, 0x20), regs.p);
}

test "Peddle bounded native runner matches instruction stepping and honors traps" {
    const machine = c.zeropage_peddle_create() orelse return error.EmulatorCreateFailed;
    defer c.zeropage_peddle_destroy(machine);
    // LDA #1; PHA; PLA; JSR $200a; RTS; NOP; NOP; INX; RTS.
    const code = [_]u8{ 0xa9, 1, 0x48, 0x68, 0x20, 0x0a, 0x20, 0x60, 0xea, 0xea, 0xe8, 0x60 };
    c.zeropage_peddle_load(machine, 0x2000, &code, code.len);
    c.zeropage_peddle_reset(machine);
    c.zeropage_peddle_set_pc(machine, 0x2000);
    c.zeropage_peddle_set_sp(machine, 0xf9);
    for (0..6) |_| c.zeropage_peddle_step_instruction(machine);
    const stepped = c.zeropage_peddle_regs(machine);
    c.zeropage_peddle_reset(machine);
    c.zeropage_peddle_set_pc(machine, 0x2000);
    c.zeropage_peddle_set_sp(machine, 0xf9);
    try std.testing.expectEqual(@as(c_int, 0), c.zeropage_peddle_run_until_rts(machine, 0xf9, 6));
    const batched = c.zeropage_peddle_regs(machine);
    inline for (.{ "pc", "pc0", "a", "x", "y", "p", "sp", "cycles", "instructions" }) |field| try std.testing.expectEqual(@field(stepped, field), @field(batched, field));
    try std.testing.expectEqual(@as(u64, 23), batched.cycles);
    c.zeropage_peddle_set_pc(machine, 0x2000);
    try std.testing.expectEqual(@as(c_int, 2), c.zeropage_peddle_run_until_rts(machine, 0xf9, 1));
    c.zeropage_peddle_set_pc(machine, 0x3000);
    try std.testing.expectEqual(@as(c_int, 1), c.zeropage_peddle_run_until_rts(machine, 0xf9, 1));
    c.zeropage_peddle_set_pc(machine, 0x2007);
    try std.testing.expectEqual(@as(c_int, 0), c.zeropage_peddle_run_until_rts(machine, 0xf9, 0));
}
