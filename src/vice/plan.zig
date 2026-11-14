const std = @import("std");

pub fn emitBorderPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, prg_path, "core_demo") != null) return emitCoreDemoPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "text_demo") != null) return emitTextDemoPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "tictactoe") != null) return emitTicTacToePlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "02_flow") != null) return emitTwoTextPlan(allocator, prg_path, "zeropage_small_flow_smoke", "FLOW DEMO", "IF WHILE OK");
    if (std.mem.indexOf(u8, prg_path, "03_functions") != null) return emitThreeTextPlan(allocator, prg_path, "zeropage_small_functions_smoke", "FUNCTION DEMO", "FUNCTION OK", "TOTAL=06");
    if (std.mem.indexOf(u8, prg_path, "04_types") != null) return emitThreeTextPlan(allocator, prg_path, "zeropage_small_types_smoke", "TYPES DEMO", "BOOL U8 I8 U16", "U16=0400");
    if (std.mem.indexOf(u8, prg_path, "05_struct_fields") != null) return emitThreeTextPlan(allocator, prg_path, "zeropage_small_struct_smoke", "STRUCT DEMO", "FIELDS OK", "X Y CH");
    if (std.mem.indexOf(u8, prg_path, "06_module_main") != null) return emitThreeTextPlan(allocator, prg_path, "zeropage_small_module_smoke", "MODULE DEMO", "IMPORT CALL OK", "TOTAL=07");
    if (std.mem.indexOf(u8, prg_path, "07_loop_control") != null) return emitThreeTextPlan(allocator, prg_path, "zeropage_small_loop_control_smoke", "LOOP CONTROL DEMO", "BREAK CONTINUE OK", "X=05");
    if (std.mem.indexOf(u8, prg_path, "08_assignment_math") != null) return emitThreeTextPlan(allocator, prg_path, "zeropage_small_assignment_math_smoke", "ASSIGN MATH DEMO", "SUB ASSIGN OK", "X=05");
    if (std.mem.indexOf(u8, prg_path, "09_console_scroll") != null) return emitThreeTextPlan(allocator, prg_path, "zeropage_small_console_scroll_smoke", "LINE 1D", "DONE 1E", "LINE 1C");
    if (std.mem.indexOf(u8, prg_path, "10_inline_asm") != null) return emitFourTextPlan(allocator, prg_path, "zeropage_small_inline_asm_smoke", "INLINE ASM DEMO", "LABEL LOOP OK", "JSR PRESERVE OK", "ASM PARAMS OK");
    if (std.mem.indexOf(u8, prg_path, "11_strings_petscii") != null) return emitFiveTextPlan(allocator, prg_path, "zeropage_small_strings_petscii_smoke", "STRING DEMO", "HELLO, WORLD", "CONSOLE PUTS OK", "KERNAL CHROUT OK", "SETNAM OK");
    if (std.mem.indexOf(u8, prg_path, "12_mutable_strings") != null) return emitFiveTextPlan(allocator, prg_path, "zeropage_small_mutable_strings_smoke", "MUTABLE STRING DEMO", "HELLO, MUTABLE OK", "RUNTIME APPEND", "KERNAL BUFFER OK", "BUFFER SETNAM OK");
    if (std.mem.indexOf(u8, prg_path, "13_string_controls") != null) return emitFiveTextPlan(allocator, prg_path, "zeropage_small_string_controls_smoke", "CONTROLS DEMO", "REVERSE", "RAW BYTE: A", "BUFFER", "ASCII PROXY: OK");
    if (std.mem.indexOf(u8, prg_path, "14_keyboard_input") != null) return emitKeyboardInputPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "15_array_lookup") != null) return emitFourTextPlan(allocator, prg_path, "zeropage_small_array_lookup_smoke", "ARRAY DEMO", "LOOKUP 04 07 09", "WORD 0101", "ARRAY OK");
    if (std.mem.indexOf(u8, prg_path, "16_inline_asm_strings") != null) return emitThreeTextPlan(allocator, prg_path, "zeropage_small_inline_asm_strings_smoke", "INLINE ASM STRINGS", "ASM STRING O!", "ASM STRING DONE");
    if (std.mem.indexOf(u8, prg_path, "17_for_array_loop") != null) return emitFourTextPlan(allocator, prg_path, "zeropage_small_for_array_loop_smoke", "FOR LOOP DEMO", "SUM 20", "INDEXED 04 08 0B", "FOR OK");
    if (std.mem.indexOf(u8, prg_path, "18_switch_dispatch") != null) return emitFourTextPlan(allocator, prg_path, "zeropage_small_switch_dispatch_smoke", "SWITCH DISPATCH", "DISPATCH 27", "WORD 0200", "SWITCH OK");
    if (std.mem.indexOf(u8, prg_path, "19_enum_struct_game") != null) return emitEnumStructGamePlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "20_struct_value_helpers") != null) return emitFourTextPlan(allocator, prg_path, "zeropage_small_struct_value_helpers_smoke", "STRUCT VALUES", "CELLS 01 02 01", "HIST 00 04 08", "STRUCT VALUE OK");
    if (std.mem.indexOf(u8, prg_path, "21_pointer_mmio") != null) return emitFourTextPlan(allocator, prg_path, "zeropage_small_pointer_mmio_smoke", "POINTER MMIO", "LOCAL 21", "MMIO!", "POKE OK");
    if (std.mem.indexOf(u8, prg_path, "22_pointer_indexing") != null) return emitFourTextPlan(allocator, prg_path, "zeropage_small_pointer_indexing_smoke", "POINTER INDEXING", "LOCAL 2A 2B", "INDEX! OK", "INDEX OK");
    if (std.mem.indexOf(u8, prg_path, "23_as_casts") != null) return emitFourTextPlan(allocator, prg_path, "zeropage_small_as_casts_smoke", "AS CASTS", "BYTE 09 WORD 0109", "AO!", "AS OK");
    if (std.mem.indexOf(u8, prg_path, "24_optional_union_event") != null) return emitOptionalUnionEventPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "26_static_abi_metadata") != null) return emitTwoTextPlan(allocator, prg_path, "zeropage_small_static_abi_metadata_smoke", "ABI METADATA", "STATIC OK");
    if (std.mem.indexOf(u8, prg_path, "27_stack_main_border") != null) return emitBorderAssertPlan(allocator, prg_path, "zeropage_small_stack_main_border_smoke", 5);
    if (std.mem.indexOf(u8, prg_path, "28_static_calls_stack_helper") != null) return emitBorderAssertPlan(allocator, prg_path, "zeropage_small_static_to_stack_bridge_smoke", 5);
    if (std.mem.indexOf(u8, prg_path, "29_module_rodata_assets") != null) return emitTwoTextPlan(allocator, prg_path, "zeropage_small_module_rodata_assets_smoke", "RODATA MODULE", "ASSET OK");
    if (std.mem.indexOf(u8, prg_path, "30_stack_main_calls_static_helper") != null) return emitBorderAssertPlan(allocator, prg_path, "zeropage_small_stack_to_static_bridge_smoke", 5);
    if (std.mem.indexOf(u8, prg_path, "31_stack_calls_stack_helper") != null) return emitBorderAssertPlan(allocator, prg_path, "zeropage_small_stack_to_stack_bridge_smoke", 5);
    if (std.mem.indexOf(u8, prg_path, "32_stack_recursive_border") != null) return emitBorderAssertPlan(allocator, prg_path, "zeropage_small_stack_recursion_smoke", 5);
    if (std.mem.indexOf(u8, prg_path, "33_reu_copy_smoke") != null) return emitReuCopySmokePlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "34_near_heap_arena") != null) return emitNearHeapArenaPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "35_fixed_heap_blocks") != null) return emitFixedHeapBlocksPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "36_far_reu_arena") != null) return emitFarReuArenaPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "37_far_reu_struct_view") != null) return emitFarReuStructViewPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "38_far_reu_materialize_flush") != null) return emitFarReuMaterializeFlushPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "39_far_reu_materialize_range") != null) return emitFarReuMaterializeRangePlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "40_module_metadata") != null) return emitModuleMetadataPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "41_module_binary") != null) return emitModuleBinaryPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "42_module_ordinals_relocs") != null) return emitModuleOrdinalsRelocsPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "43_module_rodata_relocs") != null) return emitModuleRodataRelocsPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "44_module_loader_window") != null) return emitModuleLoaderWindowPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "45_module_relocation_sim") != null) return emitModuleRelocationSimPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "46_module_runtime_load_window") != null) return emitModuleRuntimeLoadWindowPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "47_module_registry_state") != null) return emitModuleRegistryStatePlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "48_module_unload_state") != null) return emitModuleUnloadStatePlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "49_module_dynamic_call") != null) return emitModuleDynamicCallPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "50_module_disk_load") != null) return emitModuleDiskLoadPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "51_module_disk_load_real") != null) return emitModuleDiskLoadRealPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "52_module_preload_policy") != null) return emitModulePreloadPolicyPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "53_module_on_demand_policy") != null) return emitModuleOnDemandPolicyPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "54_module_dependency_metadata") != null) return emitModuleDependencyMetadataPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "55_module_registry_plan") != null) return emitModuleRegistryPlanPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "56_module_disk_reload_matrix") != null) return emitModuleDiskReloadMatrixPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "57_module_disk_manifest") != null) return emitModuleDiskManifestPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "58_module_registry_rows") != null) return emitModuleRegistryRowsPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "59_module_dependency_disk_load") != null) return emitModuleDependencyDiskLoadPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "60_module_dependency_call") != null) return emitModuleDependencyCallPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "61_module_dependency_unload") != null) return emitModuleDependencyUnloadPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "62_module_typed_dependency_call") != null) return emitModuleTypedDependencyCallPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "63_module_typed_dependency_lifecycle") != null) return emitModuleTypedDependencyLifecyclePlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "64_module_typed_current_binding") != null) return emitModuleTypedCurrentBindingPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "65_module_state_metadata") != null) return emitModuleStateMetadataPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "66_module_state_runtime") != null) return emitModuleStateRuntimePlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "67_module_dependency_state_metadata") != null) return emitModuleDependencyStateMetadataPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "68_module_dependency_state_runtime") != null) return emitModuleDependencyStateRuntimePlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "69_module_dependency_preload_policy") != null) return emitModuleDependencyPreloadPolicyPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "70_module_dependency_on_demand_policy") != null) return emitModuleDependencyOnDemandPolicyPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "71_module_dependency_refcount") != null) return emitModuleDependencyRefcountPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "72_module_dependency_graph_metadata") != null) return emitModuleDependencyGraphMetadataPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "73_module_dependency_graph_load") != null) return emitModuleDependencyGraphLoadPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "74_module_dependency_graph_on_demand_policy") != null) return emitModuleDependencyGraphOnDemandPolicyPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "75_module_dependency_graph_preload_policy") != null) return emitModuleDependencyGraphPreloadPolicyPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "76_module_typed_dependency_graph_lifecycle") != null) return emitModuleTypedDependencyGraphLifecyclePlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "77_module_dependency_graph_acquire") != null) return emitModuleDependencyGraphAcquirePlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "78_module_dependency_graph_release") != null) return emitModuleDependencyGraphReleasePlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "79_module_typed_dependency_graph_ownership") != null) return emitModuleTypedDependencyGraphOwnershipPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "80_module_graph_node_sidecars") != null) return emitTwoTextPlan(allocator, prg_path, "zeropage_small_module_graph_node_sidecars_smoke", "MODULE GRAPH SIDECARS", "GRAPH SIDECARS OK");
    if (std.mem.indexOf(u8, prg_path, "81_module_graph_node_call") != null) return emitModuleGraphNodeCallPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "82_module_typed_graph_node_binding") != null) return emitModuleTypedGraphNodeBindingPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "83_module_multi_window_metadata") != null) return emitTwoTextPlan(allocator, prg_path, "zeropage_small_module_multi_window_metadata_smoke", "MODULE MULTI WINDOW", "WINDOW METADATA OK");
    if (std.mem.indexOf(u8, prg_path, "84_module_multi_window_dispatch") != null) return emitModuleMultiWindowDispatchPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "85_module_typed_multi_window_binding") != null) return emitModuleTypedMultiWindowBindingPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "86_module_basic_bank_metadata") != null) return emitTwoTextPlan(allocator, prg_path, "zeropage_small_module_basic_bank_metadata_smoke", "MODULE BASIC BANK", "BANK METADATA OK");
    if (std.mem.indexOf(u8, prg_path, "87_module_current_basic_bank") != null) return emitModuleCurrentBasicBankPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "88_module_typed_basic_bank_window") != null) return emitModuleTypedBasicBankWindowPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "89_module_kernal_bank_metadata") != null) return emitTwoTextPlan(allocator, prg_path, "zeropage_small_module_kernal_bank_metadata_smoke", "MODULE KERNAL BANK", "BANK METADATA OK");
    if (std.mem.indexOf(u8, prg_path, "90_module_current_kernal_bank") != null) return emitModuleCurrentKernalBankPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "91_module_typed_kernal_bank_window") != null) return emitModuleTypedKernalBankWindowPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "92_module_kernal_bank_hardening") != null) return emitModuleKernalBankHardeningPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "93_module_kernal_console_trampoline") != null) return emitModuleKernalConsoleTrampolinePlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "94_module_dependency_kernal_console_trampoline") != null) return emitModuleDependencyKernalConsoleTrampolinePlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "95_memory_regions_placement") != null) return emitMemoryRegionsPlacementPlan(allocator, prg_path);
    if (std.mem.indexOf(u8, prg_path, "96_memory_regions_dll") != null) return emitMemoryRegionsDllPlan(allocator, prg_path);
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_border_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch_border
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: dump_border
        \\    type: dump.memory_ranges
        \\    params:
        \\      ranges:
        \\        - label: border_register
        \\          start: 53280
        \\          end: 53280
        \\
    , .{prg_path});
}

fn emitMemoryRegionsPlacementPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_memory_regions_placement_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MEMORY REGIONS"
        \\      wait_timeout_s: 10
        \\  - id: assert_result
        \\    type: assert.screen
        \\    params:
        \\      contains: "PLACEMENT ARENA OK"
        \\  - id: assert_direct_code
        \\    type: assert.memory
        \\    params:
        \\      start: 8192
        \\      end: 8192
        \\      equals_hex: "ad"
        \\  - id: assert_arena_byte0
        \\    type: assert.memory
        \\    params:
        \\      start: 36864
        \\      end: 36864
        \\      equals_hex: "55"
        \\  - id: assert_arena_byte1
        \\    type: assert.memory
        \\    params:
        \\      start: 36865
        \\      end: 36865
        \\      equals_hex: "aa"
        \\  - id: assert_port_restored
        \\    type: assert.memory
        \\    params:
        \\      start: 1
        \\      end: 1
        \\      equals_hex: "37"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitMemoryRegionsDllPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_memory_regions_dll_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "REGION ARENA DLL"
        \\      wait_timeout_s: 10
        \\  - id: assert_result
        \\    type: assert.screen
        \\    params:
        \\      contains: "REGION DLL CACHE OK"
        \\  - id: assert_arena_byte0
        \\    type: assert.memory
        \\    params:
        \\      start: 36864
        \\      end: 36864
        \\      equals_hex: "55"
        \\  - id: assert_arena_byte1
        \\    type: assert.memory
        \\    params:
        \\      start: 36865
        \\      end: 36865
        \\      equals_hex: "aa"
        \\  - id: assert_module_window
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: dump_reu_cache
        \\    type: dump.reu
        \\    params:
        \\      mode: sampled
        \\      deep_reu: false
        \\
    , .{prg_path});
}

fn emitReuCopySmokePlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_reu_copy_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_success
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "REU OK"
        \\      wait_timeout_s: 10
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      mode: sampled
        \\      deep_reu: false
        \\
    , .{prg_path});
}

fn emitNearHeapArenaPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_near_heap_arena_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "NEAR HEAP ARENA"
        \\      wait_timeout_s: 10
        \\  - id: assert_alloc
        \\    type: assert.screen
        \\    params:
        \\      contains: "ALLOC OK"
        \\  - id: assert_reset
        \\    type: assert.screen
        \\    params:
        \\      contains: "RESET OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitFixedHeapBlocksPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_fixed_heap_blocks_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "FIXED HEAP BLOCKS"
        \\      wait_timeout_s: 10
        \\  - id: assert_reuse
        \\    type: assert.screen
        \\    params:
        \\      contains: "FREE REUSE OK"
        \\  - id: assert_reset
        \\    type: assert.screen
        \\    params:
        \\      contains: "RESET OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitFarReuArenaPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_far_reu_arena_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "FAR REU ARENA"
        \\      wait_timeout_s: 10
        \\  - id: assert_copy
        \\    type: assert.screen
        \\    params:
        \\      contains: "FAR COPY OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      mode: sampled
        \\      deep_reu: false
        \\
    , .{prg_path});
}

fn emitFarReuStructViewPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_far_reu_struct_view_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "FAR STRUCT VIEW"
        \\      wait_timeout_s: 10
        \\  - id: assert_enemy
        \\    type: assert.screen
        \\    params:
        \\      contains: "ENEMY OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      mode: sampled
        \\      deep_reu: false
        \\
    , .{prg_path});
}

fn emitFarReuMaterializeFlushPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_far_reu_materialize_flush_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "FAR MATERIALIZE"
        \\      wait_timeout_s: 10
        \\  - id: assert_flush
        \\    type: assert.screen
        \\    params:
        \\      contains: "FLUSH OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      mode: sampled
        \\      deep_reu: false
        \\
    , .{prg_path});
}

fn emitFarReuMaterializeRangePlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_far_reu_materialize_range_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "FAR RANGE"
        \\      wait_timeout_s: 10
        \\  - id: assert_range
        \\    type: assert.screen
        \\    params:
        \\      contains: "RANGE OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      mode: sampled
        \\      deep_reu: false
        \\
    , .{prg_path});
}

fn emitBorderAssertPlan(allocator: std.mem.Allocator, prg_path: []const u8, plan_id: []const u8, border: u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: {s}
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: assert_border
        \\    type: assert.memory
        \\    retry:
        \\      max_attempts: 10
        \\      backoff_ms: 250
        \\      jitter: false
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f{x:0>1}"
        \\
    , .{ plan_id, prg_path, border & 0x0f });
}

fn emitModuleMetadataPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_metadata_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE METADATA"
        \\      wait_timeout_s: 10
        \\  - id: assert_metadata
        \\    type: assert.screen
        \\    params:
        \\      contains: "METADATA OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleStateMetadataPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_state_metadata_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE STATE META"
        \\      wait_timeout_s: 10
        \\  - id: assert_metadata
        \\    type: assert.screen
        \\    params:
        \\      contains: "STATE META OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleStateRuntimePlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_state_runtime_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE STATE RUNTIME"
        \\      wait_timeout_s: 10
        \\  - id: assert_runtime
        \\    type: assert.screen
        \\    params:
        \\      contains: "STATE RESTORE OK"
        \\  - id: assert_state_byte0
        \\    type: assert.memory
        \\    params:
        \\      start: 49408
        \\      end: 49408
        \\      equals_hex: "2a"
        \\  - id: assert_state_byte1
        \\    type: assert.memory
        \\    params:
        \\      start: 49409
        \\      end: 49409
        \\      equals_hex: "37"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleDependencyStateMetadataPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_dependency_state_metadata_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE DEP STATE"
        \\      wait_timeout_s: 10
        \\  - id: assert_metadata
        \\    type: assert.screen
        \\    params:
        \\      contains: "DEP STATE META OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleDependencyStateRuntimePlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_dependency_state_runtime_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE DEP STATE RUNTIME"
        \\      wait_timeout_s: 10
        \\  - id: assert_runtime
        \\    type: assert.screen
        \\    params:
        \\      contains: "DEP STATE RESTORE OK"
        \\  - id: assert_math_state_byte0
        \\    type: assert.memory
        \\    params:
        \\      start: 50176
        \\      end: 50176
        \\      equals_hex: "2a"
        \\  - id: assert_path_state_byte0
        \\    type: assert.memory
        \\    params:
        \\      start: 50432
        \\      end: 50432
        \\      equals_hex: "44"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleDependencyPreloadPolicyPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_dependency_preload_policy_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE DEP PRELOAD"
        \\      wait_timeout_s: 10
        \\  - id: assert_preload
        \\    type: assert.screen
        \\    params:
        \\      contains: "DEP PRELOAD OK"
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleDependencyOnDemandPolicyPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_dependency_on_demand_policy_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE DEP ON DEMAND"
        \\      wait_timeout_s: 10
        \\  - id: assert_on_demand
        \\    type: assert.screen
        \\    params:
        \\      contains: "DEP ON DEMAND OK"
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_patched_reloc
        \\    type: assert.memory
        \\    params:
        \\      start: 49297
        \\      end: 49297
        \\      equals_hex: "0c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleDependencyRefcountPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_dependency_refcount_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE DEP REFCOUNT"
        \\      wait_timeout_s: 10
        \\  - id: assert_refcount
        \\    type: assert.screen
        \\    params:
        \\      contains: "REFCOUNT OK"
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_patched_reloc
        \\    type: assert.memory
        \\    params:
        \\      start: 49297
        \\      end: 49297
        \\      equals_hex: "0c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleDependencyGraphMetadataPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_dependency_graph_metadata_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE DEP GRAPH"
        \\      wait_timeout_s: 10
        \\  - id: assert_graph
        \\    type: assert.screen
        \\    params:
        \\      contains: "GRAPH META OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleTypedDependencyGraphLifecyclePlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_typed_dependency_graph_lifecycle_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE TYPED GRAPH"
        \\      wait_timeout_s: 10
        \\  - id: assert_typed_graph
        \\    type: assert.screen
        \\    params:
        \\      contains: "TYPED GRAPH OK"
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_patched_reloc
        \\    type: assert.memory
        \\    params:
        \\      start: 49297
        \\      end: 49297
        \\      equals_hex: "0c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      max_bytes: 384
        \\      deep_reu: false
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleDependencyGraphPreloadPolicyPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_dependency_graph_preload_policy_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE GRAPH PRELOAD"
        \\      wait_timeout_s: 10
        \\  - id: assert_graph_preload
        \\    type: assert.screen
        \\    params:
        \\      contains: "GRAPH PRELOAD OK"
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_patched_reloc
        \\    type: assert.memory
        \\    params:
        \\      start: 49297
        \\      end: 49297
        \\      equals_hex: "0c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      max_bytes: 384
        \\      deep_reu: false
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleDependencyGraphOnDemandPolicyPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_dependency_graph_on_demand_policy_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE GRAPH ON DEMAND"
        \\      wait_timeout_s: 10
        \\  - id: assert_graph_on_demand
        \\    type: assert.screen
        \\    params:
        \\      contains: "GRAPH ON DEMAND OK"
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_patched_reloc
        \\    type: assert.memory
        \\    params:
        \\      start: 49297
        \\      end: 49297
        \\      equals_hex: "0c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      max_bytes: 384
        \\      deep_reu: false
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleDependencyGraphLoadPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_dependency_graph_load_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE GRAPH LOAD"
        \\      wait_timeout_s: 10
        \\  - id: assert_graph_load
        \\    type: assert.screen
        \\    params:
        \\      contains: "GRAPH LOAD OK"
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_patched_reloc
        \\    type: assert.memory
        \\    params:
        \\      start: 49297
        \\      end: 49297
        \\      equals_hex: "0c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      max_bytes: 384
        \\      deep_reu: false
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleDependencyGraphAcquirePlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_dependency_graph_acquire_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE GRAPH ACQUIRE"
        \\      wait_timeout_s: 10
        \\  - id: assert_graph_acquire
        \\    type: assert.screen
        \\    params:
        \\      contains: "GRAPH ACQUIRE OK"
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_patched_reloc
        \\    type: assert.memory
        \\    params:
        \\      start: 49297
        \\      end: 49297
        \\      equals_hex: "0c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      max_bytes: 384
        \\      deep_reu: false
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleDependencyGraphReleasePlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_dependency_graph_release_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE GRAPH RELEASE"
        \\      wait_timeout_s: 10
        \\  - id: assert_graph_release
        \\    type: assert.screen
        \\    params:
        \\      contains: "GRAPH RELEASE OK"
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_patched_reloc
        \\    type: assert.memory
        \\    params:
        \\      start: 49297
        \\      end: 49297
        \\      equals_hex: "0c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      max_bytes: 384
        \\      deep_reu: false
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleTypedDependencyGraphOwnershipPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_typed_dependency_graph_ownership_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE TYPED GRAPH OWNERSHIP"
        \\      wait_timeout_s: 10
        \\  - id: assert_typed_graph_ownership
        \\    type: assert.screen
        \\    params:
        \\      contains: "TYPED GRAPH OWNERSHIP OK"
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_patched_reloc
        \\    type: assert.memory
        \\    params:
        \\      start: 49297
        \\      end: 49297
        \\      equals_hex: "0c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      max_bytes: 384
        \\      deep_reu: false
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleGraphNodeCallPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_graph_node_call_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE GRAPH NODE CALL"
        \\      wait_timeout_s: 10
        \\  - id: assert_graph_node_call
        \\    type: assert.screen
        \\    params:
        \\      contains: "GRAPH NODE CALL OK"
        \\  - id: assert_stale_window_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      max_bytes: 384
        \\      deep_reu: false
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleTypedMultiWindowBindingPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_typed_multi_window_binding_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE TYPED MULTI WINDOW"
        \\      wait_timeout_s: 10
        \\  - id: assert_dispatch
        \\    type: assert.screen
        \\    params:
        \\      contains: "TYPED WINDOW OK"
        \\  - id: assert_aux_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 24576
        \\      end: 24576
        \\      equals_hex: "4c"
        \\  - id: assert_aux_state
        \\    type: assert.memory
        \\    params:
        \\      start: 25600
        \\      end: 25600
        \\      equals_hex: "2a"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleTypedBasicBankWindowPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_typed_basic_bank_window_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE TYPED BASIC BANK"
        \\      wait_timeout_s: 10
        \\  - id: assert_dispatch
        \\    type: assert.screen
        \\    params:
        \\      contains: "BASIC BANK OK"
        \\  - id: assert_processor_port_restored
        \\    type: assert.memory
        \\    params:
        \\      start: 1
        \\      end: 1
        \\      equals_hex: "37"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleTypedKernalBankWindowPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_typed_kernal_bank_window_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE TYPED KERNAL BANK"
        \\      wait_timeout_s: 10
        \\  - id: assert_dispatch
        \\    type: assert.screen
        \\    params:
        \\      contains: "KERNAL BANK OK"
        \\  - id: assert_processor_port_restored
        \\    type: assert.memory
        \\    params:
        \\      start: 1
        \\      end: 1
        \\      equals_hex: "37"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleMultiWindowDispatchPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_multi_window_dispatch_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE MULTI WINDOW DISPATCH"
        \\      wait_timeout_s: 10
        \\  - id: assert_dispatch
        \\    type: assert.screen
        \\    params:
        \\      contains: "WINDOW DISPATCH OK"
        \\  - id: assert_aux_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 24576
        \\      end: 24576
        \\      equals_hex: "4c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleTypedGraphNodeBindingPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_typed_graph_node_binding_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE TYPED GRAPH NODE"
        \\      wait_timeout_s: 10
        \\  - id: assert_typed_graph_node
        \\    type: assert.screen
        \\    params:
        \\      contains: "TYPED GRAPH NODE OK"
        \\  - id: assert_active_window_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      max_bytes: 384
        \\      deep_reu: false
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleDependencyMetadataPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_dependency_metadata_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE DEPS"
        \\      wait_timeout_s: 10
        \\  - id: assert_deps
        \\    type: assert.screen
        \\    params:
        \\      contains: "DEPS OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleRegistryPlanPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_registry_plan_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE REGISTRY PLAN"
        \\      wait_timeout_s: 10
        \\  - id: assert_registry
        \\    type: assert.screen
        \\    params:
        \\      contains: "REGISTRY PLAN OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleBinaryPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_binary_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE BINARY"
        \\      wait_timeout_s: 10
        \\  - id: assert_binary
        \\    type: assert.screen
        \\    params:
        \\      contains: "BINARY OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleOrdinalsRelocsPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_ordinals_relocs_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE RELOCS"
        \\      wait_timeout_s: 10
        \\  - id: assert_ordinals
        \\    type: assert.screen
        \\    params:
        \\      contains: "ORDINALS OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleRodataRelocsPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_rodata_relocs_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE RODATA RELOCS"
        \\      wait_timeout_s: 10
        \\  - id: assert_relocs
        \\    type: assert.screen
        \\    params:
        \\      contains: "RODATA RELOCS OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleLoaderWindowPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_loader_window_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE WINDOW"
        \\      wait_timeout_s: 10
        \\  - id: assert_window
        \\    type: assert.screen
        \\    params:
        \\      contains: "WINDOW OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleRelocationSimPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_relocation_sim_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE RELOC SIM"
        \\      wait_timeout_s: 10
        \\  - id: assert_sim
        \\    type: assert.screen
        \\    params:
        \\      contains: "SIM OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleRuntimeLoadWindowPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_runtime_load_window_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE LOAD WINDOW"
        \\      wait_timeout_s: 10
        \\  - id: assert_load
        \\    type: assert.screen
        \\    params:
        \\      contains: "LOAD OK"
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleCurrentBasicBankPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_current_basic_bank_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE CURRENT BASIC BANK"
        \\      wait_timeout_s: 10
        \\  - id: assert_load
        \\    type: assert.screen
        \\    params:
        \\      contains: "CURRENT BANK OK"
        \\  - id: assert_port_restored
        \\    type: assert.memory
        \\    params:
        \\      start: 1
        \\      end: 1
        \\      equals_hex: "37"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleCurrentKernalBankPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_current_kernal_bank_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE CURRENT KERNAL BANK"
        \\      wait_timeout_s: 10
        \\  - id: assert_load
        \\    type: assert.screen
        \\    params:
        \\      contains: "CURRENT KERNAL OK"
        \\  - id: assert_port_restored
        \\    type: assert.memory
        \\    params:
        \\      start: 1
        \\      end: 1
        \\      equals_hex: "37"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleKernalBankHardeningPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_kernal_bank_hardening_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE KERNAL HARDEN"
        \\      wait_timeout_s: 10
        \\  - id: assert_load_dispatch_unload
        \\    type: assert.screen
        \\    params:
        \\      contains: "KERNAL HARDEN OK"
        \\  - id: assert_port_restored
        \\    type: assert.memory
        \\    params:
        \\      start: 1
        \\      end: 1
        \\      equals_hex: "37"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleKernalConsoleTrampolinePlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return emitKernalConsoleTrampolinePlan(allocator, prg_path, "zeropage_small_module_kernal_console_trampoline_smoke", "MODULE KERNAL TRAMP", "TRAMP EXPORT", "TRAMP OK", false);
}

fn emitModuleDependencyKernalConsoleTrampolinePlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return emitKernalConsoleTrampolinePlan(allocator, prg_path, "zeropage_small_module_dependency_kernal_console_trampoline_smoke", "MODULE DEP KERNAL TRAMP", "DEP TRAMP EXPORT", "DEP TRAMP OK", true);
}

fn emitKernalConsoleTrampolinePlan(
    allocator: std.mem.Allocator,
    prg_path: []const u8,
    plan_id: []const u8,
    title: []const u8,
    export_text: []const u8,
    ok_text: []const u8,
    attach_disk: bool,
) ![]u8 {
    if (attach_disk) {
        return std.fmt.allocPrint(allocator,
            \\version: 1
            \\kind: vice_task_plan
            \\plan_id: {s}
            \\run_mode: gui_vice
            \\global_defaults:
            \\  monitor_host: 127.0.0.1
            \\  monitor_port_start: 6702
            \\  monitor_port_span: 40
            \\  retry_policy:
            \\    max_attempts: 1
            \\    backoff_ms: 250
            \\    jitter: false
            \\  timeouts:
            \\    launch_s: 45
            \\    step_s: 45
            \\    read_s: 2
            \\  artifact_policy:
            \\    capture_screen: true
            \\    capture_state: true
            \\    capture_dump: false
            \\  vice:
            \\    autostart_prg: "{s}"
            \\    disk8: "{s}.disk.d64"
            \\    close_vice: true
            \\    headless: true
            \\steps:
            \\  - id: launch
            \\    type: vice.launch
            \\    params:
            \\      kill_stale: true
            \\  - id: wait_export_text
            \\    type: screen.wait_contains
            \\    params:
            \\      text: "{s}"
            \\      wait_timeout_s: 10
            \\  - id: assert_title
            \\    type: assert.screen
            \\    params:
            \\      contains: "{s}"
            \\  - id: assert_ok
            \\    type: assert.screen
            \\    params:
            \\      contains: "{s}"
            \\  - id: assert_port_restored
            \\    type: assert.memory
            \\    params:
            \\      start: 1
            \\      end: 1
            \\      equals_hex: "37"
            \\  - id: assert_border
            \\    type: assert.memory
            \\    params:
            \\      start: 53280
            \\      end: 53280
            \\      equals_hex: "f5"
            \\
        , .{ plan_id, prg_path, prg_path, export_text, title, ok_text });
    }

    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: {s}
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_export_text
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "{s}"
        \\      wait_timeout_s: 10
        \\  - id: assert_title
        \\    type: assert.screen
        \\    params:
        \\      contains: "{s}"
        \\  - id: assert_ok
        \\    type: assert.screen
        \\    params:
        \\      contains: "{s}"
        \\  - id: assert_port_restored
        \\    type: assert.memory
        \\    params:
        \\      start: 1
        \\      end: 1
        \\      equals_hex: "37"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{ plan_id, prg_path, export_text, title, ok_text });
}

fn emitModuleRegistryStatePlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_registry_state_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE REGISTRY"
        \\      wait_timeout_s: 10
        \\  - id: assert_loaded
        \\    type: assert.screen
        \\    params:
        \\      contains: "LOADED OK"
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleUnloadStatePlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_unload_state_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE UNLOAD"
        \\      wait_timeout_s: 10
        \\  - id: assert_unloaded
        \\    type: assert.screen
        \\    params:
        \\      contains: "UNLOAD OK"
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleDynamicCallPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_dynamic_call_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE CALL"
        \\      wait_timeout_s: 10
        \\  - id: assert_call
        \\    type: assert.screen
        \\    params:
        \\      contains: "CALL OK"
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleDiskLoadPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_disk_load_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE DISK LOAD"
        \\      wait_timeout_s: 10
        \\  - id: wait_disk
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "DISK LOAD OK"
        \\      wait_timeout_s: 10
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleDiskLoadRealPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_disk_load_real_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "DISK LOAD REAL"
        \\      wait_timeout_s: 10
        \\  - id: wait_disk
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "REAL LOAD OK"
        \\      wait_timeout_s: 10
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{ prg_path, prg_path });
}

fn emitModulePreloadPolicyPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_preload_policy_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE PRELOAD"
        \\      wait_timeout_s: 10
        \\  - id: wait_preload
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "PRELOAD OK"
        \\      wait_timeout_s: 10
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleOnDemandPolicyPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_on_demand_policy_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE ON DEMAND"
        \\      wait_timeout_s: 10
        \\  - id: wait_on_demand
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "ON DEMAND OK"
        \\      wait_timeout_s: 10
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleDiskReloadMatrixPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_disk_reload_matrix_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE DISK RELOAD"
        \\      wait_timeout_s: 10
        \\  - id: wait_reload
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "RELOAD OK"
        \\      wait_timeout_s: 10
        \\  - id: assert_jump_table
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleDiskManifestPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_disk_manifest_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE DISK MANIFEST"
        \\      wait_timeout_s: 10
        \\  - id: assert_manifest
        \\    type: assert.screen
        \\    params:
        \\      contains: "MANIFEST OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleRegistryRowsPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_registry_rows_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE REGISTRY ROWS"
        \\      wait_timeout_s: 10
        \\  - id: assert_rows
        \\    type: assert.screen
        \\    params:
        \\      contains: "ROWS OK"
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\
    , .{prg_path});
}

fn emitModuleDependencyDiskLoadPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_dependency_disk_load_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE DEP LOAD"
        \\      wait_timeout_s: 10
        \\  - id: wait_loaded
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "DEP LOAD OK"
        \\      wait_timeout_s: 10
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      mode: sampled
        \\      deep_reu: false
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleDependencyCallPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_dependency_call_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE DEP CALL"
        \\      wait_timeout_s: 10
        \\  - id: wait_called
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "DEP CALL OK"
        \\      wait_timeout_s: 10
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: assert_window_jump
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_patched_abs16_low
        \\    type: assert.memory
        \\    params:
        \\      start: 49297
        \\      end: 49297
        \\      equals_hex: "0c"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      mode: sampled
        \\      deep_reu: false
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleDependencyUnloadPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_dependency_unload_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE DEP UNLOAD"
        \\      wait_timeout_s: 10
        \\  - id: wait_unloaded
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "DEP UNLOAD OK"
        \\      wait_timeout_s: 10
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: assert_window_jump
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_patched_abs16_low
        \\    type: assert.memory
        \\    params:
        \\      start: 49297
        \\      end: 49297
        \\      equals_hex: "0c"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      mode: sampled
        \\      deep_reu: false
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleTypedDependencyCallPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_typed_dependency_call_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE TYPED CALL"
        \\      wait_timeout_s: 10
        \\  - id: wait_called
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "TYPED CALL OK"
        \\      wait_timeout_s: 10
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: assert_window_jump
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_patched_abs16_low
        \\    type: assert.memory
        \\    params:
        \\      start: 49297
        \\      end: 49297
        \\      equals_hex: "0c"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      mode: sampled
        \\      deep_reu: false
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleTypedDependencyLifecyclePlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_typed_dependency_lifecycle_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE TYPED LIFE"
        \\      wait_timeout_s: 10
        \\  - id: wait_called
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "TYPED LIFE OK"
        \\      wait_timeout_s: 10
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: assert_window_jump
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: assert_patched_abs16_low
        \\    type: assert.memory
        \\    params:
        \\      start: 49297
        \\      end: 49297
        \\      equals_hex: "0c"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      mode: sampled
        \\      deep_reu: false
        \\
    , .{ prg_path, prg_path });
}

fn emitModuleTypedCurrentBindingPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_module_typed_current_binding_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    disk8: "{s}.disk.d64"
        \\    drive8_type: 1541
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "MODULE TYPED CURRENT"
        \\      wait_timeout_s: 10
        \\  - id: wait_called
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "TYPED CURRENT OK"
        \\      wait_timeout_s: 10
        \\  - id: assert_border
        \\    type: assert.memory
        \\    params:
        \\      start: 53280
        \\      end: 53280
        \\      equals_hex: "f5"
        \\  - id: assert_window_jump
        \\    type: assert.memory
        \\    params:
        \\      start: 49152
        \\      end: 49152
        \\      equals_hex: "4c"
        \\  - id: dump_reu
        \\    type: dump.reu
        \\    params:
        \\      mode: sampled
        \\      deep_reu: false
        \\
    , .{ prg_path, prg_path });
}

fn emitOptionalUnionEventPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_optional_union_event_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch_demo
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "OPTIONAL UNION EVENT"
        \\      wait_timeout_s: 10
        \\  - id: send_events
        \\    type: input.sequence
        \\    params:
        \\      keys: [49, 50]
        \\      inter_key_delay_s: 0.12
        \\  - id: wait_success
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "UNION OPTIONAL OK"
        \\      wait_timeout_s: 10
        \\  - id: assert_result
        \\    type: assert.screen
        \\    params:
        \\      contains: "RESULT 17"
        \\
    , .{prg_path});
}

fn emitTicTacToePlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_sample_tictactoe
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch_tictactoe
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_ready
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "CURSORS MOVE"
        \\      wait_timeout_s: 10
        \\  - id: assert_title
        \\    type: assert.screen
        \\    params:
        \\      contains: "TICTACTOE"
        \\  - id: invalid_move
        \\    type: input.sequence
        \\    params:
        \\      keys: [133, 32, 32]
        \\      inter_key_delay_s: 0.10
        \\  - id: wait_invalid_move
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "INVALID MOVE"
        \\      wait_timeout_s: 10
        \\      capture_label: tictactoe_invalid_move
        \\  - id: assert_selected_x_block
        \\    type: assert.memory
        \\    params:
        \\      start: 1238
        \\      end: 1238
        \\      equals_hex: "A0"
        \\  - id: play_2p_x_win
        \\    type: input.sequence
        \\    params:
        \\      keys: [133, 32, 29, 32, 157, 17, 32, 157, 145, 32, 29, 145, 32]
        \\      inter_key_delay_s: 0.10
        \\  - id: wait_2p_x_win
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "2P X WINS"
        \\      wait_timeout_s: 10
        \\      capture_label: tictactoe_2p_x_win
        \\  - id: play_2p_o_win
        \\    type: input.sequence
        \\    params:
        \\      keys: [133, 32, 29, 32, 29, 32, 157, 17, 32, 157, 32, 29, 17, 32]
        \\      inter_key_delay_s: 0.10
        \\  - id: wait_2p_o_win
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "2P O WINS"
        \\      wait_timeout_s: 10
        \\  - id: play_2p_draw
        \\    type: input.sequence
        \\    params:
        \\      keys: [133, 32, 29, 32, 29, 32, 29, 17, 32, 29, 32, 157, 17, 32, 157, 145, 32, 17, 32, 157, 32]
        \\      inter_key_delay_s: 0.10
        \\  - id: wait_2p_draw
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "2P DRAW"
        \\      wait_timeout_s: 10
        \\      capture_label: tictactoe_2p_draw
        \\  - id: play_2p_dead_draw
        \\    type: input.sequence
        \\    params:
        \\      keys: [133, 32, 29, 32, 29, 32, 29, 17, 32, 29, 32, 157, 17, 32, 29, 32, 29, 32]
        \\      inter_key_delay_s: 0.10
        \\  - id: wait_2p_dead_draw
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "2P DEAD DRAW"
        \\      wait_timeout_s: 10
        \\  - id: play_ai_x_win
        \\    type: input.sequence
        \\    params:
        \\      keys: [134, 32, 29, 145, 32, 157, 32, 157, 32]
        \\      inter_key_delay_s: 0.10
        \\  - id: wait_ai_x_win
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "AI X WINS"
        \\      wait_timeout_s: 10
        \\  - id: play_ai_o_win
        \\    type: input.sequence
        \\    params:
        \\      keys: [134, 32, 29, 32, 157, 17, 32]
        \\      inter_key_delay_s: 0.10
        \\  - id: wait_ai_o_win
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "AI O WINS"
        \\      wait_timeout_s: 10
        \\      capture_label: tictactoe_ai_o_win
        \\  - id: play_ai_draw
        \\    type: input.sequence
        \\    params:
        \\      keys: [134, 32, 157, 32, 157, 145, 32, 29, 32, 29, 145, 32]
        \\      inter_key_delay_s: 0.10
        \\  - id: wait_ai_draw
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "AI DRAW"
        \\      wait_timeout_s: 10
        \\  - id: play_ai_dead_draw
        \\    type: input.sequence
        \\    params:
        \\      keys: [134, 32, 29, 32, 157, 145, 32, 157, 145, 32]
        \\      inter_key_delay_s: 0.10
        \\  - id: wait_ai_dead_draw
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "AI DEAD DRAW"
        \\      wait_timeout_s: 10
        \\      capture_label: tictactoe_ai_dead_draw
        \\  - id: dump_board
        \\    type: dump.memory_ranges
        \\    params:
        \\      ranges:
        \\        - label: tictactoe_screen
        \\          start: 1238
        \\          end: 1648
        \\        - label: tictactoe_color
        \\          start: 55510
        \\          end: 55920
        \\
    , .{prg_path});
}

fn emitTwoTextPlan(allocator: std.mem.Allocator, prg_path: []const u8, plan_id: []const u8, first_text: []const u8, second_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: {s}
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch_demo
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_primary_text
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "{s}"
        \\      wait_timeout_s: 10
        \\  - id: assert_secondary_text
        \\    type: assert.screen
        \\    params:
        \\      contains: "{s}"
        \\
    , .{ plan_id, prg_path, first_text, second_text });
}

fn emitThreeTextPlan(allocator: std.mem.Allocator, prg_path: []const u8, plan_id: []const u8, first_text: []const u8, second_text: []const u8, third_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: {s}
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch_demo
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_primary_text
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "{s}"
        \\      wait_timeout_s: 10
        \\  - id: assert_secondary_text
        \\    type: assert.screen
        \\    params:
        \\      contains: "{s}"
        \\  - id: assert_value_text
        \\    type: assert.screen
        \\    params:
        \\      contains: "{s}"
        \\
    , .{ plan_id, prg_path, first_text, second_text, third_text });
}

fn emitFourTextPlan(allocator: std.mem.Allocator, prg_path: []const u8, plan_id: []const u8, first_text: []const u8, second_text: []const u8, third_text: []const u8, fourth_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: {s}
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch_demo
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_primary_text
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "{s}"
        \\      wait_timeout_s: 10
        \\  - id: assert_secondary_text
        \\    type: assert.screen
        \\    params:
        \\      contains: "{s}"
        \\  - id: assert_third_text
        \\    type: assert.screen
        \\    params:
        \\      contains: "{s}"
        \\  - id: assert_fourth_text
        \\    type: assert.screen
        \\    params:
        \\      contains: "{s}"
        \\
    , .{ plan_id, prg_path, first_text, second_text, third_text, fourth_text });
}

fn emitFiveTextPlan(allocator: std.mem.Allocator, prg_path: []const u8, plan_id: []const u8, first_text: []const u8, second_text: []const u8, third_text: []const u8, fourth_text: []const u8, fifth_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: {s}
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch_demo
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_primary_text
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "{s}"
        \\      wait_timeout_s: 10
        \\  - id: assert_secondary_text
        \\    type: assert.screen
        \\    params:
        \\      contains: "{s}"
        \\  - id: assert_third_text
        \\    type: assert.screen
        \\    params:
        \\      contains: "{s}"
        \\  - id: assert_fourth_text
        \\    type: assert.screen
        \\    params:
        \\      contains: "{s}"
        \\  - id: assert_fifth_text
        \\    type: assert.screen
        \\    params:
        \\      contains: "{s}"
        \\
    , .{ plan_id, prg_path, first_text, second_text, third_text, fourth_text, fifth_text });
}

fn emitKeyboardInputPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_keyboard_input_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch_demo
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_poll_prompt
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "POLL A"
        \\      wait_timeout_s: 10
        \\  - id: send_a
        \\    type: input.sequence
        \\    params:
        \\      keys: [65]
        \\      inter_key_delay_s: 0.05
        \\  - id: wait_read_result
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "READ A OK"
        \\      wait_timeout_s: 10
        \\  - id: send_cursor_down
        \\    type: input.sequence
        \\    params:
        \\      keys: [17]
        \\      inter_key_delay_s: 0.05
        \\  - id: wait_wait_result
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "WAIT DOWN OK"
        \\      wait_timeout_s: 10
        \\  - id: assert_title
        \\    type: assert.screen
        \\    params:
        \\      contains: "KEYBOARD DEMO"
        \\
    , .{prg_path});
}

fn emitEnumStructGamePlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_small_enum_struct_game_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch_demo
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_prompt
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "PRESS 1 5 9"
        \\      wait_timeout_s: 10
        \\  - id: send_moves
        \\    type: input.sequence
        \\    params:
        \\      keys: [49, 53, 57]
        \\      inter_key_delay_s: 0.12
        \\  - id: wait_success
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "GAME OK"
        \\      wait_timeout_s: 10
        \\  - id: assert_cells
        \\    type: assert.screen
        \\    params:
        \\      contains: "CELLS 01 02 01"
        \\  - id: assert_history
        \\    type: assert.screen
        \\    params:
        \\      contains: "HIST 00 04 08"
        \\  - id: assert_moves
        \\    type: assert.screen
        \\    params:
        \\      contains: "MOVES 03"
        \\
    , .{prg_path});
}

pub fn emitCoreDemoPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_core_demo_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch_core_demo
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "CORE LANGUAGE DEMO"
        \\      wait_timeout_s: 10
        \\  - id: assert_module_call
        \\    type: assert.screen
        \\    params:
        \\      contains: "MODULE PARAM RETURN"
        \\  - id: assert_bool_branch
        \\    type: assert.screen
        \\    params:
        \\      contains: "BOOL IF OK"
        \\  - id: dump_screen
        \\    type: dump.memory_ranges
        \\    params:
        \\      ranges:
        \\        - label: screen
        \\          start: 1024
        \\          end: 2023
        \\        - label: color
        \\          start: 55296
        \\          end: 56295
        \\
    , .{prg_path});
}

pub fn emitTextDemoPlan(allocator: std.mem.Allocator, prg_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\version: 1
        \\kind: vice_task_plan
        \\plan_id: zeropage_text_demo_smoke
        \\run_mode: gui_vice
        \\global_defaults:
        \\  monitor_host: 127.0.0.1
        \\  monitor_port_start: 6702
        \\  monitor_port_span: 40
        \\  retry_policy:
        \\    max_attempts: 1
        \\    backoff_ms: 250
        \\    jitter: false
        \\  timeouts:
        \\    launch_s: 45
        \\    step_s: 45
        \\    read_s: 2
        \\  artifact_policy:
        \\    capture_screen: true
        \\    capture_state: true
        \\    capture_dump: false
        \\  vice:
        \\    autostart_prg: "{s}"
        \\    close_vice: true
        \\    headless: true
        \\steps:
        \\  - id: launch_text_demo
        \\    type: vice.launch
        \\    params:
        \\      kill_stale: true
        \\  - id: wait_title
        \\    type: screen.wait_contains
        \\    params:
        \\      text: "ZEROPAGE TEXT DEMO"
        \\      wait_timeout_s: 10
        \\  - id: assert_branch
        \\    type: assert.screen
        \\    params:
        \\      contains: "IF BRANCH OK"
        \\  - id: dump_screen
        \\    type: dump.memory_ranges
        \\    params:
        \\      ranges:
        \\        - label: screen
        \\          start: 1024
        \\          end: 2023
        \\        - label: color
        \\          start: 55296
        \\          end: 56295
        \\
    , .{prg_path});
}

test "VICE plan uses supported task schema" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/border.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: vice.launch") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: dump.memory_ranges") != null);
}

test "VICE text demo plan asserts visible text" {
    const yaml = try emitTextDemoPlan(std.testing.allocator, "/tmp/text_demo.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "ZEROPAGE TEXT DEMO") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "IF BRANCH OK") != null);
}

test "VICE TicTacToe sample plan drives UI scenarios" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/sampleapps/tictactoe.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_sample_tictactoe") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "TICTACTOE") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "keys: [133, 32, 32]") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "INVALID MOVE") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "2P X WINS") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "2P O WINS") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "2P DRAW") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "2P DEAD DRAW") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "AI X WINS") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "AI O WINS") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "AI DRAW") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "AI DEAD DRAW") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "capture_label: tictactoe_2p_x_win") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "capture_label: tictactoe_ai_dead_draw") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: assert.memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"A0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "tictactoe_color") != null);
}

test "VICE core demo plan asserts module and bool output" {
    const yaml = try emitCoreDemoPlan(std.testing.allocator, "/tmp/core_demo.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "CORE LANGUAGE DEMO") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE PARAM RETURN") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "BOOL IF OK") != null);
}

test "VICE small demo plans assert visible text" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/06_module_main.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE DEMO") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "IMPORT CALL OK") != null);
}

test "VICE keyboard demo plan injects PETSCII keys" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/14_keyboard_input.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_keyboard_input_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: input.sequence") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "keys: [65]") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "keys: [17]") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "WAIT DOWN OK") != null);
}

test "VICE array lookup demo plan asserts visible text" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/15_array_lookup.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_array_lookup_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "ARRAY DEMO") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "LOOKUP 04 07 09") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "WORD 0101") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "ARRAY OK") != null);
}

test "VICE inline asm strings demo plan asserts visible text" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/16_inline_asm_strings.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_inline_asm_strings_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "INLINE ASM STRINGS") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "ASM STRING O!") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "ASM STRING DONE") != null);
}

test "VICE for array loop demo plan asserts visible text" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/17_for_array_loop.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_for_array_loop_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "FOR LOOP DEMO") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "SUM 20") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "INDEXED 04 08 0B") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "FOR OK") != null);
}

test "VICE switch dispatch demo plan asserts visible text" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/18_switch_dispatch.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_switch_dispatch_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "SWITCH DISPATCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "DISPATCH 27") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "WORD 0200") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "SWITCH OK") != null);
}

test "VICE enum struct game demo plan injects moves and asserts visible state" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/19_enum_struct_game.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_enum_struct_game_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: input.sequence") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "keys: [49, 53, 57]") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "CELLS 01 02 01") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "HIST 00 04 08") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "GAME OK") != null);
}

test "VICE optional union event demo plan injects keys and asserts visible state" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/24_optional_union_event.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_optional_union_event_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "keys: [49, 50]") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "OPTIONAL UNION EVENT") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "RESULT 17") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "UNION OPTIONAL OK") != null);
}

test "VICE struct value helper demo plan asserts visible text" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/20_struct_value_helpers.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_struct_value_helpers_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "STRUCT VALUES") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "CELLS 01 02 01") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "HIST 00 04 08") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "STRUCT VALUE OK") != null);
}

test "VICE pointer MMIO demo plan asserts visible text" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/21_pointer_mmio.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_pointer_mmio_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "POINTER MMIO") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "LOCAL 21") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MMIO!") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "POKE OK") != null);
}

test "VICE pointer indexing demo plan asserts visible text" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/22_pointer_indexing.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_pointer_indexing_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "POINTER INDEXING") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "LOCAL 2A 2B") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "INDEX! OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "INDEX OK") != null);
}

test "VICE as casts demo plan asserts visible text" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/23_as_casts.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_as_casts_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "AS CASTS") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "BYTE 09 WORD 0109") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "AO!") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "AS OK") != null);
}

test "VICE static ABI metadata demo plan asserts visible text" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/26_static_abi_metadata.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_static_abi_metadata_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "ABI METADATA") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "STATIC OK") != null);
}

test "VICE stack main demo plan asserts border register" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/27_stack_main_border.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_stack_main_border_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: assert.memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "max_attempts: 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: input.key") == null);
}

test "VICE static-to-stack bridge demo plan asserts border register" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/28_static_calls_stack_helper.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_static_to_stack_bridge_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: assert.memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module rodata assets demo plan asserts visible text" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/29_module_rodata_assets.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_rodata_assets_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "RODATA MODULE") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "ASSET OK") != null);
}

test "VICE stack-to-static bridge demo plan asserts border register" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/30_stack_main_calls_static_helper.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_stack_to_static_bridge_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: assert.memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE stack-to-stack bridge demo plan asserts border register" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/31_stack_calls_stack_helper.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_stack_to_stack_bridge_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: assert.memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE recursive stack demo plan asserts border register" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/32_stack_recursive_border.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_stack_recursion_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: assert.memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module metadata demo plan asserts visible text and border register" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/40_module_metadata.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_metadata_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE METADATA") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "METADATA OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: assert.memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module binary demo plan asserts visible text and border register" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/41_module_binary.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_binary_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE BINARY") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "BINARY OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: assert.memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module ordinals relocation demo plan asserts visible text and border register" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/42_module_ordinals_relocs.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_ordinals_relocs_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE RELOCS") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "ORDINALS OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: assert.memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module rodata relocation demo plan asserts visible text and border register" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/43_module_rodata_relocs.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_rodata_relocs_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE RODATA RELOCS") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "RODATA RELOCS OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: assert.memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module loader window demo plan asserts visible text and border register" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/44_module_loader_window.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_loader_window_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE WINDOW") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "WINDOW OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: assert.memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module relocation simulator demo plan asserts visible text and border register" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/45_module_relocation_sim.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_relocation_sim_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE RELOC SIM") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "SIM OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: assert.memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module runtime load window demo plan asserts visible text, window, and border register" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/46_module_runtime_load_window.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_runtime_load_window_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE LOAD WINDOW") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "LOAD OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module registry state demo plan asserts visible text, window, and border register" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/47_module_registry_state.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_registry_state_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE REGISTRY") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "LOADED OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module unload state demo plan asserts visible text, window, and border register" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/48_module_unload_state.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_unload_state_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE UNLOAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "UNLOAD OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module dynamic call demo plan asserts visible text, window, and border register" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/49_module_dynamic_call.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_dynamic_call_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE CALL") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "CALL OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module real disk load demo plan attaches disk and asserts success" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/51_module_disk_load_real.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_disk_load_real_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/51_module_disk_load_real.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "drive8_type: 1541") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "DISK LOAD REAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "REAL LOAD OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module preload policy demo plan attaches disk and asserts success" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/52_module_preload_policy.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_preload_policy_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/52_module_preload_policy.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "drive8_type: 1541") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE PRELOAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "PRELOAD OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module on-demand policy demo plan attaches disk and asserts success" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/53_module_on_demand_policy.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_on_demand_policy_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/53_module_on_demand_policy.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "drive8_type: 1541") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE ON DEMAND") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "ON DEMAND OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module dependency metadata demo plan asserts visible metadata proof" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/54_module_dependency_metadata.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_dependency_metadata_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE DEPS") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "DEPS OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module registry plan demo asserts visible metadata proof" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/55_module_registry_plan.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_registry_plan_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE REGISTRY PLAN") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "REGISTRY PLAN OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module disk reload matrix demo attaches disk and asserts reload success" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/56_module_disk_reload_matrix.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_disk_reload_matrix_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/56_module_disk_reload_matrix.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "drive8_type: 1541") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE DISK RELOAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "RELOAD OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module disk manifest demo asserts visible metadata proof" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/57_module_disk_manifest.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_disk_manifest_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE DISK MANIFEST") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MANIFEST OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module registry rows demo asserts visible row proof" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/58_module_registry_rows.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_registry_rows_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE REGISTRY ROWS") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "ROWS OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module dependency disk load demo attaches disk and dumps REU proof" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/59_module_dependency_disk_load.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_dependency_disk_load_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/59_module_dependency_disk_load.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "drive8_type: 1541") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE DEP LOAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "DEP LOAD OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "dump.reu") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module dependency call demo attaches disk and asserts ordinal dispatch proof" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/60_module_dependency_call.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_dependency_call_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/60_module_dependency_call.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "drive8_type: 1541") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE DEP CALL") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "DEP CALL OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "dump.reu") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"4c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49297") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"0c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module dependency unload demo attaches disk and asserts reload proof" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/61_module_dependency_unload.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_dependency_unload_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/61_module_dependency_unload.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "drive8_type: 1541") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE DEP UNLOAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "DEP UNLOAD OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "dump.reu") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"4c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49297") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"0c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE typed dependency call demo attaches disk and asserts ordinal dispatch proof" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/62_module_typed_dependency_call.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_typed_dependency_call_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/62_module_typed_dependency_call.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "drive8_type: 1541") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE TYPED CALL") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "TYPED CALL OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "dump.reu") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"4c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49297") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"0c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE typed dependency lifecycle demo attaches disk and asserts reload proof" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/63_module_typed_dependency_lifecycle.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_typed_dependency_lifecycle_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/63_module_typed_dependency_lifecycle.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "drive8_type: 1541") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE TYPED LIFE") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "TYPED LIFE OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "dump.reu") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"4c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49297") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"0c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE typed current binding demo attaches disk and asserts loaded window" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/64_module_typed_current_binding.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_typed_current_binding_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/64_module_typed_current_binding.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "drive8_type: 1541") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE TYPED CURRENT") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "TYPED CURRENT OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "dump.reu") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"4c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module state metadata demo asserts visible output" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/65_module_state_metadata.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_state_metadata_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE STATE META") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "STATE META OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE module state runtime demo asserts restored window bytes" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/66_module_state_runtime.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_state_runtime_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE STATE RUNTIME") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "STATE RESTORE OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49408") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"2a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49409") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"37\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
}

test "VICE dependency module state metadata demo asserts visible output" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/67_module_dependency_state_metadata.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_dependency_state_metadata_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE DEP STATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "DEP STATE META OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 53280") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE dependency module state runtime demo attaches disk and asserts restored bytes" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/68_module_dependency_state_runtime.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_dependency_state_runtime_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/68_module_dependency_state_runtime.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE DEP STATE RUNTIME") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "DEP STATE RESTORE OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 50176") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 50432") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE dependency preload policy demo attaches disk and asserts loaded window" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/69_module_dependency_preload_policy.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_dependency_preload_policy_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/69_module_dependency_preload_policy.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE DEP PRELOAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "DEP PRELOAD OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE dependency on-demand policy demo attaches disk and asserts loaded window" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/70_module_dependency_on_demand_policy.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_dependency_on_demand_policy_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/70_module_dependency_on_demand_policy.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE DEP ON DEMAND") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "DEP ON DEMAND OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49297") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE dependency refcount demo attaches disk and asserts loaded window" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/71_module_dependency_refcount.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_dependency_refcount_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/71_module_dependency_refcount.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE DEP REFCOUNT") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "REFCOUNT OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49297") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE dependency graph metadata demo asserts visible output" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/72_module_dependency_graph_metadata.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_dependency_graph_metadata_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE DEP GRAPH") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "GRAPH META OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE dependency graph load demo attaches disk and asserts active window" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/73_module_dependency_graph_load.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_dependency_graph_load_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/73_module_dependency_graph_load.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE GRAPH LOAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "GRAPH LOAD OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49297") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "dump.reu") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE graph on-demand dependency policy demo attaches disk and asserts active window" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/74_module_dependency_graph_on_demand_policy.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_dependency_graph_on_demand_policy_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/74_module_dependency_graph_on_demand_policy.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE GRAPH ON DEMAND") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "GRAPH ON DEMAND OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49297") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "dump.reu") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE graph preload dependency policy demo attaches disk and asserts active window" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/75_module_dependency_graph_preload_policy.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_dependency_graph_preload_policy_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/75_module_dependency_graph_preload_policy.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE GRAPH PRELOAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "GRAPH PRELOAD OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49297") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "dump.reu") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE typed dependency graph lifecycle demo attaches disk and asserts active window" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/76_module_typed_dependency_graph_lifecycle.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_typed_dependency_graph_lifecycle_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/76_module_typed_dependency_graph_lifecycle.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE TYPED GRAPH") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "TYPED GRAPH OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49297") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "dump.reu") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE dependency graph acquire demo attaches disk and asserts active window" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/77_module_dependency_graph_acquire.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_dependency_graph_acquire_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/77_module_dependency_graph_acquire.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE GRAPH ACQUIRE") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "GRAPH ACQUIRE OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49297") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "dump.reu") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE dependency graph release demo attaches disk and asserts active window" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/78_module_dependency_graph_release.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_dependency_graph_release_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/78_module_dependency_graph_release.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE GRAPH RELEASE") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "GRAPH RELEASE OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49297") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "dump.reu") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE typed dependency graph ownership demo attaches disk and asserts active window" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/79_module_typed_dependency_graph_ownership.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_typed_dependency_graph_ownership_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/79_module_typed_dependency_graph_ownership.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE TYPED GRAPH OWNERSHIP") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "TYPED GRAPH OWNERSHIP OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49297") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "dump.reu") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE graph node sidecar demo asserts visible success" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/80_module_graph_node_sidecars.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_graph_node_sidecars_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE GRAPH SIDECARS") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "GRAPH SIDECARS OK") != null);
}

test "VICE graph node call demo attaches disk and asserts stale active window" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/81_module_graph_node_call.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_graph_node_call_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/81_module_graph_node_call.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE GRAPH NODE CALL") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "GRAPH NODE CALL OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "dump.reu") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE typed graph node binding demo attaches disk and asserts active window" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/82_module_typed_graph_node_binding.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_typed_graph_node_binding_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/82_module_typed_graph_node_binding.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE TYPED GRAPH NODE") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "TYPED GRAPH NODE OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "start: 49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "dump.reu") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE current KERNAL console trampoline demo asserts visible export text" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/93_module_kernal_console_trampoline.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_kernal_console_trampoline_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8:") == null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE KERNAL TRAMP") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "TRAMP EXPORT") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "TRAMP OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"37\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE dependency KERNAL console trampoline demo attaches disk and asserts visible export text" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/94_module_dependency_kernal_console_trampoline.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_module_dependency_kernal_console_trampoline_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "disk8: \"/tmp/94_module_dependency_kernal_console_trampoline.prg.disk.d64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "MODULE DEP KERNAL TRAMP") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "DEP TRAMP EXPORT") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "DEP TRAMP OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"37\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"f5\"") != null);
}

test "VICE named memory placement demo asserts direct, arena, and bank restoration" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/95_memory_regions_placement.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_memory_regions_placement_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "PLACEMENT ARENA OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"55\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"aa\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"37\"") != null);
}

test "VICE named memory DLL demo asserts arena, load window, and REU dump" {
    const yaml = try emitBorderPlan(std.testing.allocator, "/tmp/96_memory_regions_dll.prg");
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "zeropage_small_memory_regions_dll_smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "REGION DLL CACHE OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "equals_hex: \"4c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "type: dump.reu") != null);
}
