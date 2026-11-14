#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLING_DIR="$(cd "$ROOT_DIR/.." && pwd)/zeropage-tooling"
VICE_TASKS="${ZEROPAGE_VICE_TASKS:-}"
if [[ -z "$VICE_TASKS" ]]; then
  VICE_TASKS_CANDIDATE="$(cd "$ROOT_DIR/.." && pwd)/agenticdevharness/tools/vice_tasks_dotnet/src/ViceTasks.Binary/ViceTasks.Binary.csproj"
  if [[ -f "$VICE_TASKS_CANDIDATE" ]]; then
    VICE_TASKS="$VICE_TASKS_CANDIDATE"
  fi
fi

ZIG="${ZEROPAGE_ZIG:-$TOOLING_DIR/bin/zig}"
if [[ ! -x "$ZIG" && -z "${ZEROPAGE_ZIG:-}" ]]; then
  ZIG="$(command -v zig || true)"
fi
RUN_VICE=0
SKIP_BUILD=0

for arg in "$@"; do
  case "$arg" in
    --vice) RUN_VICE=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --help|-h)
      echo "Usage: scripts/verify_small_demos.sh [--skip-build] [--vice]"
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

DEMOS=(
  "examples/small/01_border.zp64"
  "examples/small/02_flow.zp64"
  "examples/small/03_functions.zp64"
  "examples/small/04_types.zp64"
  "examples/small/05_struct_fields.zp64"
  "examples/small/06_module_main.zp64"
  "examples/small/07_loop_control.zp64"
  "examples/small/08_assignment_math.zp64"
  "examples/small/09_console_scroll.zp64"
  "examples/small/10_inline_asm.zp64"
  "examples/small/11_strings_petscii.zp64"
  "examples/small/12_mutable_strings.zp64"
  "examples/small/13_string_controls.zp64"
  "examples/small/14_keyboard_input.zp64"
  "examples/small/15_array_lookup.zp64"
  "examples/small/16_inline_asm_strings.zp64"
  "examples/small/17_for_array_loop.zp64"
  "examples/small/18_switch_dispatch.zp64"
  "examples/small/19_enum_struct_game.zp64"
  "examples/small/20_struct_value_helpers.zp64"
  "examples/small/21_pointer_mmio.zp64"
  "examples/small/22_pointer_indexing.zp64"
  "examples/small/23_as_casts.zp64"
  "examples/small/24_optional_union_event.zp64"
  "examples/small/25_struct_array_table.zp64"
  "examples/small/26_static_abi_metadata.zp64"
  "examples/small/27_stack_main_border.zp64"
  "examples/small/28_static_calls_stack_helper.zp64"
  "examples/small/29_module_rodata_assets.zp64"
  "examples/small/30_stack_main_calls_static_helper.zp64"
  "examples/small/31_stack_calls_stack_helper.zp64"
  "examples/small/32_stack_recursive_border.zp64"
  "examples/small/33_reu_copy_smoke.zp64"
  "examples/small/34_near_heap_arena.zp64"
  "examples/small/35_fixed_heap_blocks.zp64"
  "examples/small/36_far_reu_arena.zp64"
  "examples/small/37_far_reu_struct_view.zp64"
  "examples/small/38_far_reu_materialize_flush.zp64"
  "examples/small/39_far_reu_materialize_range.zp64"
  "examples/small/40_module_metadata.zp64"
  "examples/small/41_module_binary.zp64"
  "examples/small/42_module_ordinals_relocs.zp64"
  "examples/small/43_module_rodata_relocs.zp64"
  "examples/small/44_module_loader_window.zp64"
  "examples/small/45_module_relocation_sim.zp64"
  "examples/small/46_module_runtime_load_window.zp64"
  "examples/small/47_module_registry_state.zp64"
  "examples/small/48_module_unload_state.zp64"
  "examples/small/49_module_dynamic_call.zp64"
  "examples/small/50_module_disk_load.zp64"
  "examples/small/51_module_disk_load_real.zp64"
  "examples/small/52_module_preload_policy.zp64"
  "examples/small/53_module_on_demand_policy.zp64"
  "examples/small/54_module_dependency_metadata.zp64"
  "examples/small/55_module_registry_plan.zp64"
  "examples/small/56_module_disk_reload_matrix.zp64"
  "examples/small/57_module_disk_manifest.zp64"
  "examples/small/58_module_registry_rows.zp64"
  "examples/small/59_module_dependency_disk_load.zp64"
  "examples/small/60_module_dependency_call.zp64"
  "examples/small/61_module_dependency_unload.zp64"
  "examples/small/62_module_typed_dependency_call.zp64"
  "examples/small/63_module_typed_dependency_lifecycle.zp64"
  "examples/small/64_module_typed_current_binding.zp64"
  "examples/small/65_module_state_metadata.zp64"
  "examples/small/66_module_state_runtime.zp64"
  "examples/small/67_module_dependency_state_metadata.zp64"
  "examples/small/68_module_dependency_state_runtime.zp64"
  "examples/small/69_module_dependency_preload_policy.zp64"
  "examples/small/70_module_dependency_on_demand_policy.zp64"
  "examples/small/71_module_dependency_refcount.zp64"
  "examples/small/72_module_dependency_graph_metadata.zp64"
  "examples/small/73_module_dependency_graph_load.zp64"
  "examples/small/74_module_dependency_graph_on_demand_policy.zp64"
  "examples/small/75_module_dependency_graph_preload_policy.zp64"
  "examples/small/76_module_typed_dependency_graph_lifecycle.zp64"
  "examples/small/77_module_dependency_graph_acquire.zp64"
  "examples/small/78_module_dependency_graph_release.zp64"
  "examples/small/79_module_typed_dependency_graph_ownership.zp64"
  "examples/small/80_module_graph_node_sidecars.zp64"
  "examples/small/81_module_graph_node_call.zp64"
  "examples/small/82_module_typed_graph_node_binding.zp64"
  "examples/small/83_module_multi_window_metadata.zp64"
  "examples/small/84_module_multi_window_dispatch.zp64"
  "examples/small/85_module_typed_multi_window_binding.zp64"
  "examples/small/86_module_basic_bank_metadata.zp64"
  "examples/small/87_module_current_basic_bank.zp64"
  "examples/small/88_module_typed_basic_bank_window.zp64"
  "examples/small/89_module_kernal_bank_metadata.zp64"
  "examples/small/90_module_current_kernal_bank.zp64"
  "examples/small/91_module_typed_kernal_bank_window.zp64"
  "examples/small/92_module_kernal_bank_hardening.zp64"
  "examples/small/93_module_kernal_console_trampoline.zp64"
  "examples/small/94_module_dependency_kernal_console_trampoline.zp64"
  "examples/small/95_memory_regions_placement.zp64"
  "examples/small/96_memory_regions_dll.zp64"
)

cd "$ROOT_DIR"
if [[ "$SKIP_BUILD" == "0" ]]; then
  "$ZIG" build
fi

mkdir -p build/small
rm -f build/small/*.zpmod build/small/*.zpmod.json build/small/*.zpmod.relocsim.json build/small/*.zpmod.diskmanifest.json
for demo in "${DEMOS[@]}"; do
  name="$(basename "$demo" .zp64)"
  prg="build/small/$name.prg"
  if [[ "$name" == "60_module_dependency_call" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/60_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/pathing_dispatch.zp64 -o build/small/60_pathing.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/60_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/60_mathcore.prg.zpmod.relocsim.json \
      --dependency-module pathing=build/small/60_pathing.prg.zpmod.json \
      --dependency-relocsim pathing=build/small/60_pathing.prg.zpmod.relocsim.json
  elif [[ "$name" == "61_module_dependency_unload" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/61_mathcore.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/61_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/61_mathcore.prg.zpmod.relocsim.json
  elif [[ "$name" == "62_module_typed_dependency_call" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/62_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/pathing_dispatch.zp64 -o build/small/62_pathing.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/62_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/62_mathcore.prg.zpmod.relocsim.json \
      --dependency-module pathing=build/small/62_pathing.prg.zpmod.json \
      --dependency-relocsim pathing=build/small/62_pathing.prg.zpmod.relocsim.json
  elif [[ "$name" == "63_module_typed_dependency_lifecycle" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/63_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/pathing_dispatch.zp64 -o build/small/63_pathing.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/63_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/63_mathcore.prg.zpmod.relocsim.json \
      --dependency-module pathing=build/small/63_pathing.prg.zpmod.json \
      --dependency-relocsim pathing=build/small/63_pathing.prg.zpmod.relocsim.json
  elif [[ "$name" == "68_module_dependency_state_runtime" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/68_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/pathing_dispatch.zp64 -o build/small/68_pathing.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/68_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/68_mathcore.prg.zpmod.relocsim.json \
      --dependency-module pathing=build/small/68_pathing.prg.zpmod.json \
      --dependency-relocsim pathing=build/small/68_pathing.prg.zpmod.relocsim.json
  elif [[ "$name" == "69_module_dependency_preload_policy" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/69_mathcore.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/69_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/69_mathcore.prg.zpmod.relocsim.json
  elif [[ "$name" == "70_module_dependency_on_demand_policy" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/70_mathcore.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/70_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/70_mathcore.prg.zpmod.relocsim.json
  elif [[ "$name" == "71_module_dependency_refcount" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/71_mathcore.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/71_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/71_mathcore.prg.zpmod.relocsim.json
  elif [[ "$name" == "73_module_dependency_graph_load" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/73_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o build/small/73_fixedmath.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/73_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/73_mathcore.prg.zpmod.relocsim.json
  elif [[ "$name" == "74_module_dependency_graph_on_demand_policy" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/74_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o build/small/74_fixedmath.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/74_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/74_mathcore.prg.zpmod.relocsim.json
  elif [[ "$name" == "75_module_dependency_graph_preload_policy" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/75_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o build/small/75_fixedmath.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/75_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/75_mathcore.prg.zpmod.relocsim.json
  elif [[ "$name" == "76_module_typed_dependency_graph_lifecycle" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/76_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o build/small/76_fixedmath.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/76_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/76_mathcore.prg.zpmod.relocsim.json
  elif [[ "$name" == "77_module_dependency_graph_acquire" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/77_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o build/small/77_fixedmath.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/77_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/77_mathcore.prg.zpmod.relocsim.json
  elif [[ "$name" == "78_module_dependency_graph_release" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/78_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o build/small/78_fixedmath.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/78_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/78_mathcore.prg.zpmod.relocsim.json
  elif [[ "$name" == "79_module_typed_dependency_graph_ownership" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/79_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o build/small/79_fixedmath.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/79_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/79_mathcore.prg.zpmod.relocsim.json
  elif [[ "$name" == "80_module_graph_node_sidecars" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/80_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o build/small/80_fixedmath.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/80_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/80_mathcore.prg.zpmod.relocsim.json \
      --dependency-module fixed_math=build/small/80_fixedmath.prg.zpmod.json \
      --dependency-relocsim fixed_math=build/small/80_fixedmath.prg.zpmod.relocsim.json
  elif [[ "$name" == "81_module_graph_node_call" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/81_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o build/small/81_fixedmath.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/81_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/81_mathcore.prg.zpmod.relocsim.json \
      --dependency-module fixed_math=build/small/81_fixedmath.prg.zpmod.json \
      --dependency-relocsim fixed_math=build/small/81_fixedmath.prg.zpmod.relocsim.json
  elif [[ "$name" == "82_module_typed_graph_node_binding" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/82_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o build/small/82_fixedmath.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/82_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/82_mathcore.prg.zpmod.relocsim.json \
      --dependency-module fixed_math=build/small/82_fixedmath.prg.zpmod.json \
      --dependency-relocsim fixed_math=build/small/82_fixedmath.prg.zpmod.relocsim.json
  elif [[ "$name" == "84_module_multi_window_dispatch" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/84_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o build/small/84_fixedmath.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/84_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/84_mathcore.prg.zpmod.relocsim.json \
      --dependency-module fixed_math=build/small/84_fixedmath.prg.zpmod.json \
      --dependency-relocsim fixed_math=build/small/84_fixedmath.prg.zpmod.relocsim.json
  elif [[ "$name" == "85_module_typed_multi_window_binding" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/85_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o build/small/85_fixedmath.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/85_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/85_mathcore.prg.zpmod.relocsim.json \
      --dependency-module fixed_math=build/small/85_fixedmath.prg.zpmod.json \
      --dependency-relocsim fixed_math=build/small/85_fixedmath.prg.zpmod.relocsim.json
  elif [[ "$name" == "88_module_typed_basic_bank_window" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/88_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o build/small/88_fixedmath.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/88_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/88_mathcore.prg.zpmod.relocsim.json \
      --dependency-module fixed_math=build/small/88_fixedmath.prg.zpmod.json \
      --dependency-relocsim fixed_math=build/small/88_fixedmath.prg.zpmod.relocsim.json
  elif [[ "$name" == "91_module_typed_kernal_bank_window" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o build/small/91_mathcore.prg
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o build/small/91_fixedmath.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/91_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/91_mathcore.prg.zpmod.relocsim.json \
      --dependency-module fixed_math=build/small/91_fixedmath.prg.zpmod.json \
      --dependency-relocsim fixed_math=build/small/91_fixedmath.prg.zpmod.relocsim.json
  elif [[ "$name" == "94_module_dependency_kernal_console_trampoline" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_kernal_console.zp64 -o build/small/94_mathcore.prg
    ./zig-out/bin/zp64c compile "$demo" -o "$prg" \
      --dependency-module math_core=build/small/94_mathcore.prg.zpmod.json \
      --dependency-relocsim math_core=build/small/94_mathcore.prg.zpmod.relocsim.json
  else
    ./zig-out/bin/zp64c compile "$demo" -o "$prg"
  fi
done

metadata_json="build/small/40_module_metadata.prg.zpmod.json"
if [[ ! -f "$metadata_json" ]]; then
  echo "missing module metadata sidecar: $metadata_json" >&2
  exit 1
fi
grep -Fq '"format": "zeropage-module-metadata"' "$metadata_json" || { echo "module metadata sidecar missing format" >&2; exit 1; }
grep -Fq '"module_id": "enemy_ai"' "$metadata_json" || { echo "module metadata sidecar missing module id" >&2; exit 1; }
grep -Fq '"name": "tick"' "$metadata_json" || { echo "module metadata sidecar missing export" >&2; exit 1; }
grep -Fq '"ordinal": 0, "id": "math"' "$metadata_json" || { echo "module metadata sidecar missing dependency ordinal" >&2; exit 1; }
grep -Fq '"sections": [' "$metadata_json" || { echo "module metadata sidecar missing sections" >&2; exit 1; }
grep -Fq '"relocations": []' "$metadata_json" || { echo "module metadata sidecar missing empty relocations" >&2; exit 1; }

if [[ -f "build/small/01_border.prg.zpmod.json" ]]; then
  echo "unexpected module metadata sidecar for non-module demo" >&2
  exit 1
fi
if [[ -f "build/small/01_border.prg.zpmod" ]]; then
  echo "unexpected module binary sidecar for non-module demo" >&2
  exit 1
fi
if [[ -f "build/small/01_border.prg.zpmod.relocsim.json" ]]; then
  echo "unexpected module relocation simulator sidecar for non-module demo" >&2
  exit 1
fi
if [[ -f "build/small/01_border.prg.zpmod.diskmanifest.json" ]]; then
  echo "unexpected module disk manifest sidecar for non-module demo" >&2
  exit 1
fi

module_binary="build/small/41_module_binary.prg.zpmod"
if [[ ! -f "$module_binary" ]]; then
  echo "missing module binary sidecar: $module_binary" >&2
  exit 1
fi
perl - "$module_binary" <<'PERL'
use strict;
use warnings;
my ($path) = @ARGV;
open my $fh, '<:raw', $path or die "open $path: $!";
local $/;
my $bytes = <$fh>;
die "module binary too small\n" if length($bytes) < 40;
die "module binary bad magic\n" if substr($bytes, 0, 4) ne "ZPMD";
die "module binary bad version\n" if ord(substr($bytes, 4, 1)) != 1;
my $total = unpack('V', substr($bytes, 10, 4));
die "module binary total size mismatch\n" if $total != length($bytes);
my $stored = unpack('v', substr($bytes, 14, 2));
my $sum = 0;
for my $i (0 .. length($bytes) - 1) {
  next if $i == 14 || $i == 15;
  $sum = ($sum + ord(substr($bytes, $i, 1))) & 0xffff;
}
die "module binary checksum mismatch\n" if $sum != $stored;
my $payload_len = unpack('V', substr($bytes, 34, 4));
die "module binary empty payload\n" if $payload_len == 0;
PERL

module_reloc_json="build/small/42_module_ordinals_relocs.prg.zpmod.json"
module_reloc_binary="build/small/42_module_ordinals_relocs.prg.zpmod"
if [[ ! -f "$module_reloc_json" ]]; then
  echo "missing module relocation metadata sidecar: $module_reloc_json" >&2
  exit 1
fi
grep -Fq '"module_id": "enemy_relocs"' "$module_reloc_json" || { echo "module relocation sidecar missing module id" >&2; exit 1; }
grep -Fq '"name": "tick", "ordinal": 0' "$module_reloc_json" || { echo "module relocation sidecar missing tick ordinal" >&2; exit 1; }
grep -Fq '"name": "score", "ordinal": 1' "$module_reloc_json" || { echo "module relocation sidecar missing score ordinal" >&2; exit 1; }
grep -Fq '"kind": "abs16"' "$module_reloc_json" || { echo "module relocation sidecar missing abs16 relocation" >&2; exit 1; }
grep -Fq '"target": "bump"' "$module_reloc_json" || { echo "module relocation sidecar missing bump target" >&2; exit 1; }
if [[ ! -f "$module_reloc_binary" ]]; then
  echo "missing module relocation binary sidecar: $module_reloc_binary" >&2
  exit 1
fi
perl - "$module_reloc_binary" <<'PERL'
use strict;
use warnings;
my ($path) = @ARGV;
open my $fh, '<:raw', $path or die "open $path: $!";
local $/;
my $bytes = <$fh>;
die "module relocation binary bad magic\n" if substr($bytes, 0, 4) ne "ZPMD";
my $total = unpack('V', substr($bytes, 10, 4));
die "module relocation binary total size mismatch\n" if $total != length($bytes);
my $stored = unpack('v', substr($bytes, 14, 2));
my $sum = 0;
for my $i (0 .. length($bytes) - 1) {
  next if $i == 14 || $i == 15;
  $sum = ($sum + ord(substr($bytes, $i, 1))) & 0xffff;
}
die "module relocation binary checksum mismatch\n" if $sum != $stored;
my $exports = unpack('v', substr($bytes, 16, 2));
my $relocs = unpack('v', substr($bytes, 22, 2));
my $payload_len = unpack('V', substr($bytes, 34, 4));
die "module relocation binary expected two exports\n" if $exports != 2;
die "module relocation binary expected relocations\n" if $relocs == 0;
die "module relocation binary empty payload\n" if $payload_len == 0;
PERL

module_rodata_reloc_json="build/small/43_module_rodata_relocs.prg.zpmod.json"
module_rodata_reloc_binary="build/small/43_module_rodata_relocs.prg.zpmod"
if [[ ! -f "$module_rodata_reloc_json" ]]; then
  echo "missing module rodata relocation metadata sidecar: $module_rodata_reloc_json" >&2
  exit 1
fi
grep -Fq '"module_id": "enemy_rodata_relocs"' "$module_rodata_reloc_json" || { echo "module rodata relocation sidecar missing module id" >&2; exit 1; }
grep -Fq '"name": "table_ptr", "ordinal": 0' "$module_rodata_reloc_json" || { echo "module rodata relocation sidecar missing table_ptr ordinal" >&2; exit 1; }
grep -Fq '"name": "bias", "ordinal": 1' "$module_rodata_reloc_json" || { echo "module rodata relocation sidecar missing bias ordinal" >&2; exit 1; }
grep -Fq '"kind": "hi8"' "$module_rodata_reloc_json" || { echo "module rodata relocation sidecar missing hi8 relocation" >&2; exit 1; }
grep -Fq '"kind": "lo8"' "$module_rodata_reloc_json" || { echo "module rodata relocation sidecar missing lo8 relocation" >&2; exit 1; }
grep -Fq '"target": "zeropage_arr_reloc_table"' "$module_rodata_reloc_json" || { echo "module rodata relocation sidecar missing rodata target" >&2; exit 1; }
grep -Fq '"addend": 1' "$module_rodata_reloc_json" || { echo "module rodata relocation sidecar missing addend" >&2; exit 1; }
if [[ ! -f "$module_rodata_reloc_binary" ]]; then
  echo "missing module rodata relocation binary sidecar: $module_rodata_reloc_binary" >&2
  exit 1
fi
perl - "$module_rodata_reloc_binary" <<'PERL'
use strict;
use warnings;
my ($path) = @ARGV;
open my $fh, '<:raw', $path or die "open $path: $!";
local $/;
my $bytes = <$fh>;
die "module rodata relocation binary bad magic\n" if substr($bytes, 0, 4) ne "ZPMD";
my $total = unpack('V', substr($bytes, 10, 4));
die "module rodata relocation binary total size mismatch\n" if $total != length($bytes);
my $stored = unpack('v', substr($bytes, 14, 2));
my $sum = 0;
for my $i (0 .. length($bytes) - 1) {
  next if $i == 14 || $i == 15;
  $sum = ($sum + ord(substr($bytes, $i, 1))) & 0xffff;
}
die "module rodata relocation binary checksum mismatch\n" if $sum != $stored;
sub read_str {
  my ($bytes_ref, $cursor_ref) = @_;
  my $len = unpack('v', substr($$bytes_ref, $$cursor_ref, 2));
  $$cursor_ref += 2;
  my $s = substr($$bytes_ref, $$cursor_ref, $len);
  $$cursor_ref += $len;
  return $s;
}
my $exports = unpack('v', substr($bytes, 16, 2));
my $deps = unpack('v', substr($bytes, 18, 2));
my $sections = unpack('v', substr($bytes, 20, 2));
my $relocs = unpack('v', substr($bytes, 22, 2));
my $payload_len = unpack('V', substr($bytes, 34, 4));
die "module rodata relocation binary expected two exports\n" if $exports != 2;
die "module rodata relocation binary expected relocations\n" if $relocs < 2;
die "module rodata relocation binary empty payload\n" if $payload_len == 0;
my $cursor = 38;
read_str(\$bytes, \$cursor);
for my $i (0 .. $exports - 1) {
  $cursor += 2;
  read_str(\$bytes, \$cursor);
  read_str(\$bytes, \$cursor);
  $cursor += 2;
  my $params = ord(substr($bytes, $cursor, 1));
  $cursor += 1;
  for my $p (0 .. $params - 1) {
    read_str(\$bytes, \$cursor);
    $cursor += 1;
  }
  $cursor += 1;
}
for my $i (0 .. $deps - 1) {
  $cursor += 2;
  read_str(\$bytes, \$cursor);
}
for my $i (0 .. $sections - 1) {
  read_str(\$bytes, \$cursor);
  read_str(\$bytes, \$cursor);
  $cursor += 6;
}
my ($saw_lo, $saw_hi) = (0, 0);
for my $i (0 .. $relocs - 1) {
  $cursor += 4;
  my $kind = ord(substr($bytes, $cursor, 1));
  $cursor += 1;
  $cursor += 2;
  my $addend = unpack('v', substr($bytes, $cursor, 2));
  $cursor += 2;
  my $target = read_str(\$bytes, \$cursor);
  if ($target eq "zeropage_arr_reloc_table" && $addend == 1 && $kind == 2) { $saw_lo = 1; }
  if ($target eq "zeropage_arr_reloc_table" && $addend == 1 && $kind == 3) { $saw_hi = 1; }
}
die "module rodata relocation binary missing lo8 record\n" unless $saw_lo;
die "module rodata relocation binary missing hi8 record\n" unless $saw_hi;
PERL

module_loader_json="build/small/44_module_loader_window.prg.zpmod.json"
module_loader_binary="build/small/44_module_loader_window.prg.zpmod"
module_loader_sim_json="build/small/44_module_loader_window.prg.zpmod.relocsim.json"
if [[ ! -f "$module_loader_json" ]]; then
  echo "missing module loader metadata sidecar: $module_loader_json" >&2
  exit 1
fi
grep -Fq '"module_id": "enemy_window"' "$module_loader_json" || { echo "module loader sidecar missing module id" >&2; exit 1; }
grep -Fq '"loader": {' "$module_loader_json" || { echo "module loader sidecar missing loader object" >&2; exit 1; }
grep -Fq '"load_window": { "addr": 32768, "size": 4096, "alignment": 256 }' "$module_loader_json" || { echo "module loader sidecar missing load window" >&2; exit 1; }
grep -Fq '"reu_cache": { "addr": 131072, "size": 65536, "alignment": 256 }' "$module_loader_json" || { echo "module loader sidecar missing REU cache" >&2; exit 1; }
if [[ ! -f "$module_loader_binary" ]]; then
  echo "missing module loader binary sidecar: $module_loader_binary" >&2
  exit 1
fi
if [[ ! -f "$module_loader_sim_json" ]]; then
  echo "missing module loader relocation simulator sidecar: $module_loader_sim_json" >&2
  exit 1
fi
grep -Fq '"format": "zeropage-module-relocation-sim"' "$module_loader_sim_json" || { echo "module loader relocation simulator missing format" >&2; exit 1; }
grep -Fq '"module_id": "enemy_window"' "$module_loader_sim_json" || { echo "module loader relocation simulator missing module id" >&2; exit 1; }
grep -Fq '"applied_relocations": []' "$module_loader_sim_json" || { echo "module loader relocation simulator should have empty relocation list" >&2; exit 1; }
perl - "$module_loader_binary" <<'PERL'
use strict;
use warnings;
my ($path) = @ARGV;
open my $fh, '<:raw', $path or die "open $path: $!";
local $/;
my $bytes = <$fh>;
die "module loader binary bad magic\n" if substr($bytes, 0, 4) ne "ZPMD";
my $flags = unpack('v', substr($bytes, 6, 2));
die "module loader binary missing loader flag\n" if ($flags & 0x0001) == 0;
my $payload_offset = unpack('V', substr($bytes, 30, 4));
die "module loader binary payload offset too small\n" if $payload_offset < 14;
my $record = substr($bytes, $payload_offset - 14, 14);
die "module loader binary wrong load window addr\n" if unpack('v', substr($record, 0, 2)) != 0x8000;
die "module loader binary wrong load window size\n" if unpack('v', substr($record, 2, 2)) != 0x1000;
die "module loader binary wrong REU cache addr\n" if unpack('V', substr($record, 4, 4)) != 0x020000;
die "module loader binary wrong REU cache size\n" if unpack('V', substr($record, 8, 4)) != 0x010000;
die "module loader binary wrong alignment\n" if unpack('v', substr($record, 12, 2)) != 0x0100;
PERL

module_sim_json="build/small/45_module_relocation_sim.prg.zpmod.relocsim.json"
if [[ ! -f "$module_sim_json" ]]; then
  echo "missing module relocation simulator sidecar: $module_sim_json" >&2
  exit 1
fi
grep -Fq '"format": "zeropage-module-relocation-sim"' "$module_sim_json" || { echo "module relocation simulator missing format" >&2; exit 1; }
grep -Fq '"module_id": "enemy_reloc_sim"' "$module_sim_json" || { echo "module relocation simulator missing module id" >&2; exit 1; }
grep -Fq '"relocated_payload_checksum"' "$module_sim_json" || { echo "module relocation simulator missing checksum" >&2; exit 1; }
grep -Fq '"kind": "abs16"' "$module_sim_json" || { echo "module relocation simulator missing abs16 relocation" >&2; exit 1; }
grep -Fq '"kind": "hi8"' "$module_sim_json" || { echo "module relocation simulator missing hi8 relocation" >&2; exit 1; }
grep -Fq '"kind": "lo8"' "$module_sim_json" || { echo "module relocation simulator missing lo8 relocation" >&2; exit 1; }
grep -Fq '"target": "bump"' "$module_sim_json" || { echo "module relocation simulator missing code target" >&2; exit 1; }
grep -Fq '"target": "zeropage_arr_reloc_table"' "$module_sim_json" || { echo "module relocation simulator missing rodata target" >&2; exit 1; }
grep -Fq '"before": [' "$module_sim_json" || { echo "module relocation simulator missing before bytes" >&2; exit 1; }
grep -Fq '"after": [' "$module_sim_json" || { echo "module relocation simulator missing after bytes" >&2; exit 1; }

module_runtime_json="build/small/46_module_runtime_load_window.prg.zpmod.relocsim.json"
if [[ ! -f "$module_runtime_json" ]]; then
  echo "missing module runtime loader relocation simulator sidecar: $module_runtime_json" >&2
  exit 1
fi
grep -Fq '"module_id": "enemy_runtime"' "$module_runtime_json" || { echo "module runtime loader simulator missing module id" >&2; exit 1; }
grep -Fq '"load_window": { "addr": 49152, "size": 2048 }' "$module_runtime_json" || { echo "module runtime loader simulator missing load window" >&2; exit 1; }
grep -Fq '"kind": "abs16"' "$module_runtime_json" || { echo "module runtime loader simulator missing abs16 relocation" >&2; exit 1; }
grep -Fq '"kind": "hi8"' "$module_runtime_json" || { echo "module runtime loader simulator missing hi8 relocation" >&2; exit 1; }
grep -Fq '"kind": "lo8"' "$module_runtime_json" || { echo "module runtime loader simulator missing lo8 relocation" >&2; exit 1; }
grep -Fq '"after": [6, 192]' "$module_runtime_json" || { echo "module runtime loader simulator missing relocated abs16 bytes for window" >&2; exit 1; }

module_registry_json="build/small/47_module_registry_state.prg.zpmod.relocsim.json"
if [[ ! -f "$module_registry_json" ]]; then
  echo "missing module registry relocation simulator sidecar: $module_registry_json" >&2
  exit 1
fi
grep -Fq '"module_id": "enemy_runtime"' "$module_registry_json" || { echo "module registry simulator missing module id" >&2; exit 1; }
grep -Fq '"load_window": { "addr": 49152, "size": 2048 }' "$module_registry_json" || { echo "module registry simulator missing load window" >&2; exit 1; }
grep -Fq '"kind": "abs16"' "$module_registry_json" || { echo "module registry simulator missing abs16 relocation" >&2; exit 1; }
grep -Fq '"kind": "hi8"' "$module_registry_json" || { echo "module registry simulator missing hi8 relocation" >&2; exit 1; }
grep -Fq '"kind": "lo8"' "$module_registry_json" || { echo "module registry simulator missing lo8 relocation" >&2; exit 1; }

module_unload_json="build/small/48_module_unload_state.prg.zpmod.relocsim.json"
if [[ ! -f "$module_unload_json" ]]; then
  echo "missing module unload relocation simulator sidecar: $module_unload_json" >&2
  exit 1
fi
grep -Fq '"module_id": "enemy_runtime"' "$module_unload_json" || { echo "module unload simulator missing module id" >&2; exit 1; }
grep -Fq '"load_window": { "addr": 49152, "size": 2048 }' "$module_unload_json" || { echo "module unload simulator missing load window" >&2; exit 1; }
grep -Fq '"kind": "abs16"' "$module_unload_json" || { echo "module unload simulator missing abs16 relocation" >&2; exit 1; }
grep -Fq '"kind": "hi8"' "$module_unload_json" || { echo "module unload simulator missing hi8 relocation" >&2; exit 1; }
grep -Fq '"kind": "lo8"' "$module_unload_json" || { echo "module unload simulator missing lo8 relocation" >&2; exit 1; }

module_call_json="build/small/49_module_dynamic_call.prg.zpmod.relocsim.json"
if [[ ! -f "$module_call_json" ]]; then
  echo "missing module dynamic call relocation simulator sidecar: $module_call_json" >&2
  exit 1
fi
grep -Fq '"module_id": "enemy_runtime"' "$module_call_json" || { echo "module dynamic call simulator missing module id" >&2; exit 1; }
grep -Fq '"load_window": { "addr": 49152, "size": 2048 }' "$module_call_json" || { echo "module dynamic call simulator missing load window" >&2; exit 1; }

module_disk_payload="build/small/50_module_disk_load.prg.zpmod.disk.prg"
if [[ ! -f "$module_disk_payload" ]]; then
  echo "missing module disk payload PRG: $module_disk_payload" >&2
  exit 1
fi
perl - "$module_disk_payload" <<'PERL'
use strict;
use warnings;
my ($path) = @ARGV;
open my $fh, '<:raw', $path or die "open $path: $!";
read($fh, my $hdr, 2) == 2 or die "short disk payload\n";
my $addr = unpack('v', $hdr);
die "disk payload load address mismatch\n" if $addr != 0x9000;
PERL

module_disk_real_payload="build/small/51_module_disk_load_real.prg.zpmod.disk.prg"
module_disk_real_d64="build/small/51_module_disk_load_real.prg.disk.d64"
module_preload_payload="build/small/52_module_preload_policy.prg.zpmod.disk.prg"
module_preload_d64="build/small/52_module_preload_policy.prg.disk.d64"
module_preload_json="build/small/52_module_preload_policy.prg.zpmod.json"
module_on_demand_payload="build/small/53_module_on_demand_policy.prg.zpmod.disk.prg"
module_on_demand_d64="build/small/53_module_on_demand_policy.prg.disk.d64"
module_on_demand_json="build/small/53_module_on_demand_policy.prg.zpmod.json"
module_deps_json="build/small/54_module_dependency_metadata.prg.zpmod.json"
module_deps_binary="build/small/54_module_dependency_metadata.prg.zpmod"
module_registry_plan_json="build/small/55_module_registry_plan.prg.zpmod.json"
module_registry_plan_binary="build/small/55_module_registry_plan.prg.zpmod"
module_disk_reload_payload="build/small/56_module_disk_reload_matrix.prg.zpmod.disk.prg"
module_disk_reload_d64="build/small/56_module_disk_reload_matrix.prg.disk.d64"
module_disk_manifest_json="build/small/57_module_disk_manifest.prg.zpmod.json"
module_disk_manifest_binary="build/small/57_module_disk_manifest.prg.zpmod"
module_disk_manifest_packaging="build/small/57_module_disk_manifest.prg.zpmod.diskmanifest.json"
module_registry_rows_asm="build/small/58_module_registry_rows.prg.asm"
module_registry_rows_json="build/small/58_module_registry_rows.prg.zpmod.json"
module_dependency_load_asm="build/small/59_module_dependency_disk_load.prg.asm"
module_dependency_load_math_payload="build/small/59_mathcore.prg.zpmod.disk.prg"
module_dependency_load_pathing_payload="build/small/59_pathing.prg.zpmod.disk.prg"
module_dependency_load_d64="build/small/59_module_dependency_disk_load.prg.disk.d64"
module_dependency_call_asm="build/small/60_module_dependency_call.prg.asm"
module_dependency_call_math_payload="build/small/60_mathcore.prg.zpmod.disk.prg"
module_dependency_call_pathing_payload="build/small/60_pathing.prg.zpmod.disk.prg"
module_dependency_call_d64="build/small/60_module_dependency_call.prg.disk.d64"
module_dependency_unload_asm="build/small/61_module_dependency_unload.prg.asm"
module_dependency_unload_math_payload="build/small/61_mathcore.prg.zpmod.disk.prg"
module_dependency_unload_d64="build/small/61_module_dependency_unload.prg.disk.d64"
module_typed_dependency_call_asm="build/small/62_module_typed_dependency_call.prg.asm"
module_typed_dependency_call_math_payload="build/small/62_mathcore.prg.zpmod.disk.prg"
module_typed_dependency_call_pathing_payload="build/small/62_pathing.prg.zpmod.disk.prg"
module_typed_dependency_call_d64="build/small/62_module_typed_dependency_call.prg.disk.d64"
module_typed_dependency_lifecycle_asm="build/small/63_module_typed_dependency_lifecycle.prg.asm"
module_typed_dependency_lifecycle_math_payload="build/small/63_mathcore.prg.zpmod.disk.prg"
module_typed_dependency_lifecycle_pathing_payload="build/small/63_pathing.prg.zpmod.disk.prg"
module_typed_dependency_lifecycle_d64="build/small/63_module_typed_dependency_lifecycle.prg.disk.d64"
module_typed_current_asm="build/small/64_module_typed_current_binding.prg.asm"
module_typed_current_payload="build/small/64_module_typed_current_binding.prg.zpmod.disk.prg"
module_typed_current_d64="build/small/64_module_typed_current_binding.prg.disk.d64"
module_state_metadata_json="build/small/65_module_state_metadata.prg.zpmod.json"
module_state_metadata_binary="build/small/65_module_state_metadata.prg.zpmod"
module_state_runtime_asm="build/small/66_module_state_runtime.prg.asm"
module_state_runtime_json="build/small/66_module_state_runtime.prg.zpmod.json"
module_dependency_state_json="build/small/67_module_dependency_state_metadata.prg.zpmod.json"
module_dependency_state_runtime_asm="build/small/68_module_dependency_state_runtime.prg.asm"
module_dependency_state_runtime_math_payload="build/small/68_mathcore.prg.zpmod.disk.prg"
module_dependency_state_runtime_pathing_payload="build/small/68_pathing.prg.zpmod.disk.prg"
module_dependency_state_runtime_d64="build/small/68_module_dependency_state_runtime.prg.disk.d64"
module_dependency_preload_asm="build/small/69_module_dependency_preload_policy.prg.asm"
module_dependency_preload_math_payload="build/small/69_mathcore.prg.zpmod.disk.prg"
module_dependency_preload_d64="build/small/69_module_dependency_preload_policy.prg.disk.d64"
module_dependency_on_demand_asm="build/small/70_module_dependency_on_demand_policy.prg.asm"
module_dependency_on_demand_math_payload="build/small/70_mathcore.prg.zpmod.disk.prg"
module_dependency_on_demand_d64="build/small/70_module_dependency_on_demand_policy.prg.disk.d64"
module_dependency_refcount_asm="build/small/71_module_dependency_refcount.prg.asm"
module_dependency_refcount_math_payload="build/small/71_mathcore.prg.zpmod.disk.prg"
module_dependency_refcount_d64="build/small/71_module_dependency_refcount.prg.disk.d64"
module_dependency_graph_json="build/small/72_module_dependency_graph_metadata.prg.zpmod.json"
module_dependency_graph_binary="build/small/72_module_dependency_graph_metadata.prg.zpmod"
module_dependency_graph_manifest="build/small/72_module_dependency_graph_metadata.prg.zpmod.diskmanifest.json"
module_dependency_graph_load_asm="build/small/73_module_dependency_graph_load.prg.asm"
module_dependency_graph_load_math_payload="build/small/73_mathcore.prg.zpmod.disk.prg"
module_dependency_graph_load_fixed_payload="build/small/73_fixedmath.prg.zpmod.disk.prg"
module_dependency_graph_load_d64="build/small/73_module_dependency_graph_load.prg.disk.d64"
module_dependency_graph_on_demand_asm="build/small/74_module_dependency_graph_on_demand_policy.prg.asm"
module_dependency_graph_on_demand_json="build/small/74_module_dependency_graph_on_demand_policy.prg.zpmod.json"
module_dependency_graph_on_demand_math_payload="build/small/74_mathcore.prg.zpmod.disk.prg"
module_dependency_graph_on_demand_fixed_payload="build/small/74_fixedmath.prg.zpmod.disk.prg"
module_dependency_graph_on_demand_d64="build/small/74_module_dependency_graph_on_demand_policy.prg.disk.d64"
module_dependency_graph_preload_asm="build/small/75_module_dependency_graph_preload_policy.prg.asm"
module_dependency_graph_preload_json="build/small/75_module_dependency_graph_preload_policy.prg.zpmod.json"
module_dependency_graph_preload_math_payload="build/small/75_mathcore.prg.zpmod.disk.prg"
module_dependency_graph_preload_fixed_payload="build/small/75_fixedmath.prg.zpmod.disk.prg"
module_dependency_graph_preload_d64="build/small/75_module_dependency_graph_preload_policy.prg.disk.d64"
module_typed_dependency_graph_asm="build/small/76_module_typed_dependency_graph_lifecycle.prg.asm"
module_typed_dependency_graph_math_payload="build/small/76_mathcore.prg.zpmod.disk.prg"
module_typed_dependency_graph_fixed_payload="build/small/76_fixedmath.prg.zpmod.disk.prg"
module_typed_dependency_graph_d64="build/small/76_module_typed_dependency_graph_lifecycle.prg.disk.d64"
module_dependency_graph_acquire_asm="build/small/77_module_dependency_graph_acquire.prg.asm"
module_dependency_graph_acquire_math_payload="build/small/77_mathcore.prg.zpmod.disk.prg"
module_dependency_graph_acquire_fixed_payload="build/small/77_fixedmath.prg.zpmod.disk.prg"
module_dependency_graph_acquire_d64="build/small/77_module_dependency_graph_acquire.prg.disk.d64"
module_dependency_graph_release_asm="build/small/78_module_dependency_graph_release.prg.asm"
module_dependency_graph_release_math_payload="build/small/78_mathcore.prg.zpmod.disk.prg"
module_dependency_graph_release_fixed_payload="build/small/78_fixedmath.prg.zpmod.disk.prg"
module_dependency_graph_release_d64="build/small/78_module_dependency_graph_release.prg.disk.d64"
module_typed_dependency_graph_ownership_asm="build/small/79_module_typed_dependency_graph_ownership.prg.asm"
module_typed_dependency_graph_ownership_math_payload="build/small/79_mathcore.prg.zpmod.disk.prg"
module_typed_dependency_graph_ownership_fixed_payload="build/small/79_fixedmath.prg.zpmod.disk.prg"
module_typed_dependency_graph_ownership_d64="build/small/79_module_typed_dependency_graph_ownership.prg.disk.d64"
module_graph_node_call_asm="build/small/81_module_graph_node_call.prg.asm"
module_graph_node_call_math_payload="build/small/81_mathcore.prg.zpmod.disk.prg"
module_graph_node_call_fixed_payload="build/small/81_fixedmath.prg.zpmod.disk.prg"
module_graph_node_call_d64="build/small/81_module_graph_node_call.prg.disk.d64"
module_typed_graph_node_binding_asm="build/small/82_module_typed_graph_node_binding.prg.asm"
module_typed_graph_node_binding_math_payload="build/small/82_mathcore.prg.zpmod.disk.prg"
module_typed_graph_node_binding_fixed_payload="build/small/82_fixedmath.prg.zpmod.disk.prg"
module_typed_graph_node_binding_d64="build/small/82_module_typed_graph_node_binding.prg.disk.d64"
module_multi_window_dispatch_asm="build/small/84_module_multi_window_dispatch.prg.asm"
module_multi_window_dispatch_math_payload="build/small/84_mathcore.prg.zpmod.disk.prg"
module_multi_window_dispatch_fixed_payload="build/small/84_fixedmath.prg.zpmod.disk.prg"
module_multi_window_dispatch_d64="build/small/84_module_multi_window_dispatch.prg.disk.d64"
module_typed_multi_window_binding_asm="build/small/85_module_typed_multi_window_binding.prg.asm"
module_typed_multi_window_binding_math_payload="build/small/85_mathcore.prg.zpmod.disk.prg"
module_typed_multi_window_binding_fixed_payload="build/small/85_fixedmath.prg.zpmod.disk.prg"
module_typed_multi_window_binding_d64="build/small/85_module_typed_multi_window_binding.prg.disk.d64"
module_typed_basic_bank_window_asm="build/small/88_module_typed_basic_bank_window.prg.asm"
module_typed_basic_bank_window_json="build/small/88_module_typed_basic_bank_window.prg.zpmod.json"
module_typed_basic_bank_window_math_payload="build/small/88_mathcore.prg.zpmod.disk.prg"
module_typed_basic_bank_window_fixed_payload="build/small/88_fixedmath.prg.zpmod.disk.prg"
module_typed_basic_bank_window_d64="build/small/88_module_typed_basic_bank_window.prg.disk.d64"
module_typed_kernal_bank_window_asm="build/small/91_module_typed_kernal_bank_window.prg.asm"
module_typed_kernal_bank_window_json="build/small/91_module_typed_kernal_bank_window.prg.zpmod.json"
module_typed_kernal_bank_window_math_payload="build/small/91_mathcore.prg.zpmod.disk.prg"
module_typed_kernal_bank_window_fixed_payload="build/small/91_fixedmath.prg.zpmod.disk.prg"
module_typed_kernal_bank_window_d64="build/small/91_module_typed_kernal_bank_window.prg.disk.d64"
module_kernal_console_trampoline_asm="build/small/93_module_kernal_console_trampoline.prg.asm"
module_kernal_console_trampoline_json="build/small/93_module_kernal_console_trampoline.prg.zpmod.json"
module_dependency_kernal_console_trampoline_asm="build/small/94_module_dependency_kernal_console_trampoline.prg.asm"
module_dependency_kernal_console_trampoline_json="build/small/94_mathcore.prg.zpmod.json"
module_dependency_kernal_console_trampoline_payload="build/small/94_mathcore.prg.zpmod.disk.prg"
module_dependency_kernal_console_trampoline_d64="build/small/94_module_dependency_kernal_console_trampoline.prg.disk.d64"
if [[ ! -f "$module_disk_real_payload" ]]; then
  echo "missing real module disk payload PRG: $module_disk_real_payload" >&2
  exit 1
fi
if [[ ! -f "$module_preload_payload" ]]; then
  echo "missing preload module disk payload PRG: $module_preload_payload" >&2
  exit 1
fi
if [[ ! -f "$module_on_demand_payload" ]]; then
  echo "missing on-demand module disk payload PRG: $module_on_demand_payload" >&2
  exit 1
fi
if [[ ! -f "$module_disk_reload_payload" ]]; then
  echo "missing disk reload module payload PRG: $module_disk_reload_payload" >&2
  exit 1
fi
if [[ ! -f "$module_typed_current_payload" ]]; then
  echo "missing typed current module disk payload PRG: $module_typed_current_payload" >&2
  exit 1
fi
if [[ ! -f "$module_dependency_kernal_console_trampoline_payload" ]]; then
  echo "missing dependency KERNAL console trampoline payload PRG: $module_dependency_kernal_console_trampoline_payload" >&2
  exit 1
fi
if [[ ! -f "$module_state_metadata_json" || ! -f "$module_state_metadata_binary" ]]; then
  echo "missing module state metadata sidecars" >&2
  exit 1
fi
grep -Fq '"policy": { "current": { "mode": "preload", "filename": "enemyrt" } }' "$module_preload_json" || { echo "module preload JSON missing policy" >&2; exit 1; }
grep -Fq '"policy": { "current": { "mode": "on_demand", "filename": "enemyrt" } }' "$module_on_demand_json" || { echo "module on-demand JSON missing policy" >&2; exit 1; }
grep -Fq '"state": {' "$module_state_metadata_json" || { echo "module state metadata JSON missing state object" >&2; exit 1; }
grep -Fq '"mode": "persist_in_reu"' "$module_state_metadata_json" || { echo "module state metadata JSON missing persist mode" >&2; exit 1; }
grep -Fq '"snapshot_reu_addr": 198656' "$module_state_metadata_json" || { echo "module state metadata JSON missing snapshot slot" >&2; exit 1; }
grep -Fq '"offset": 256, "size": 2' "$module_state_metadata_json" || { echo "module state metadata JSON missing state range" >&2; exit 1; }
if [[ ! -f "$module_state_runtime_json" ]]; then
  echo "missing module state runtime sidecar" >&2
  exit 1
fi
grep -Fq 'zeropage_module_state_save_current:' "$module_state_runtime_asm" || { echo "module state runtime asm missing save helper" >&2; exit 1; }
grep -Fq 'zeropage_module_state_restore_current:' "$module_state_runtime_asm" || { echo "module state runtime asm missing restore helper" >&2; exit 1; }
grep -Fq 'zeropage_module_state_current_saved:' "$module_state_runtime_asm" || { echo "module state runtime asm missing saved flag" >&2; exit 1; }
grep -Fq 'zeropage_module_state_current_snapshot_reu = $030800' "$module_state_runtime_asm" || { echo "module state runtime asm missing snapshot constant" >&2; exit 1; }
grep -Fq '"snapshot_reu_addr": 198656' "$module_state_runtime_json" || { echo "module state runtime JSON missing snapshot slot" >&2; exit 1; }
grep -Fq 'zeropage_module_kernal_trampoline_console_put_char:' "$module_kernal_console_trampoline_asm" || { echo "module KERNAL console trampoline asm missing char wrapper" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_kernal_trampoline_console_put_char' "$module_kernal_console_trampoline_asm" || { echo "module KERNAL console export missing trampoline call" >&2; exit 1; }
grep -Fq '"requires_kernal_rom": true' "$module_kernal_console_trampoline_json" || { echo "module KERNAL console JSON missing KERNAL flag" >&2; exit 1; }
grep -Fq '"kernal_trampoline_safe": true' "$module_kernal_console_trampoline_json" || { echo "module KERNAL console JSON missing trampoline-safe flag" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_bank_enter_kernal' "$module_dependency_kernal_console_trampoline_asm" || { echo "dependency KERNAL console asm missing KERNAL bank dispatch" >&2; exit 1; }
grep -Fq '"requires_kernal_rom": true' "$module_dependency_kernal_console_trampoline_json" || { echo "dependency KERNAL console JSON missing KERNAL flag" >&2; exit 1; }
grep -Fq '"kernal_trampoline_safe": true' "$module_dependency_kernal_console_trampoline_json" || { echo "dependency KERNAL console JSON missing trampoline-safe flag" >&2; exit 1; }
if [[ ! -f "$module_dependency_state_json" ]]; then
  echo "missing module dependency state sidecar" >&2
  exit 1
fi
grep -Fq '"id": "math_core"' "$module_dependency_state_json" || { echo "dependency state JSON missing math_core" >&2; exit 1; }
grep -Fq '"snapshot_reu_addr": 204800' "$module_dependency_state_json" || { echo "dependency state JSON missing math_core snapshot slot" >&2; exit 1; }
grep -Fq '"id": "pathing"' "$module_dependency_state_json" || { echo "dependency state JSON missing pathing" >&2; exit 1; }
grep -Fq '"snapshot_reu_addr": 206848' "$module_dependency_state_json" || { echo "dependency state JSON missing pathing snapshot slot" >&2; exit 1; }
grep -Fq '"offset": 64, "size": 2' "$module_dependency_state_json" || { echo "dependency state JSON missing pathing range" >&2; exit 1; }
if [[ ! -f "$module_dependency_state_runtime_asm" ]]; then
  echo "missing dependency state runtime asm" >&2
  exit 1
fi
grep -Fq 'zeropage_module_state_dep1_snapshot_reu = $032000' "$module_dependency_state_runtime_asm" || { echo "dependency state runtime asm missing dep1 snapshot" >&2; exit 1; }
grep -Fq 'zeropage_module_state_dep2_snapshot_reu = $032800' "$module_dependency_state_runtime_asm" || { echo "dependency state runtime asm missing dep2 snapshot" >&2; exit 1; }
grep -Fq 'zeropage_module_state_save_active_dependency:' "$module_dependency_state_runtime_asm" || { echo "dependency state runtime asm missing active save helper" >&2; exit 1; }
grep -Fq 'zeropage_module_state_restore_dependency_row1:' "$module_dependency_state_runtime_asm" || { echo "dependency state runtime asm missing dep1 restore helper" >&2; exit 1; }
grep -Fq 'zeropage_module_state_restore_dependency_row2:' "$module_dependency_state_runtime_asm" || { echo "dependency state runtime asm missing dep2 restore helper" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_state_save_dependency_row2' "$module_dependency_state_runtime_asm" || { echo "dependency state runtime asm missing unload save call" >&2; exit 1; }
if [[ ! -f "$module_dependency_preload_asm" ]]; then
  echo "missing dependency preload asm" >&2
  exit 1
fi
grep -Fq 'zeropage_module_dependency_preload_start:' "$module_dependency_preload_asm" || { echo "dependency preload asm missing startup label" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_load_dependency_row1' "$module_dependency_preload_asm" || { echo "dependency preload asm missing row1 startup load" >&2; exit 1; }
grep -Fq 'zeropage_module_load_dependency_row1:' "$module_dependency_preload_asm" || { echo "dependency preload asm missing row1 loader" >&2; exit 1; }
grep -Fq 'zeropage_module_dependency_row1_filename:' "$module_dependency_preload_asm" || { echo "dependency preload asm missing row1 filename" >&2; exit 1; }
if [[ ! -f "$module_dependency_on_demand_asm" ]]; then
  echo "missing dependency on-demand asm" >&2
  exit 1
fi
grep -Fq 'lda zeropage_module_registry_row1_loaded' "$module_dependency_on_demand_asm" || { echo "dependency on-demand asm missing loaded check" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_load_dependency_row1' "$module_dependency_on_demand_asm" || { echo "dependency on-demand asm missing lazy row load" >&2; exit 1; }
grep -Fq 'zeropage_module_load_dependency_row1:' "$module_dependency_on_demand_asm" || { echo "dependency on-demand asm missing row loader" >&2; exit 1; }
grep -Fq 'zeropage_module_dependency_row1_filename:' "$module_dependency_on_demand_asm" || { echo "dependency on-demand asm missing row filename" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_activate_dependency_row1' "$module_dependency_on_demand_asm" || { echo "dependency on-demand asm missing activation" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_registry_jump_table+0' "$module_dependency_on_demand_asm" || { echo "dependency on-demand asm missing ordinal dispatch" >&2; exit 1; }
if grep -Fq 'zeropage_module_dependency_preload_start:' "$module_dependency_on_demand_asm"; then
  echo "dependency on-demand asm unexpectedly emitted preload startup" >&2
  exit 1
fi
if [[ ! -f "$module_dependency_refcount_asm" ]]; then
  echo "missing dependency refcount asm" >&2
  exit 1
fi
grep -Fq 'inc zeropage_module_registry_row1_refcount' "$module_dependency_refcount_asm" || { echo "dependency refcount asm missing acquire increment" >&2; exit 1; }
grep -Fq 'dec zeropage_module_registry_row1_refcount' "$module_dependency_refcount_asm" || { echo "dependency refcount asm missing release decrement" >&2; exit 1; }
grep -Fq 'cmp #$ff' "$module_dependency_refcount_asm" || { echo "dependency refcount asm missing overflow guard" >&2; exit 1; }
grep -Fq 'zeropage_module_unload_dependency_row1_final_release:' "$module_dependency_refcount_asm" || { echo "dependency refcount asm missing final release label" >&2; exit 1; }
if [[ ! -f "$module_dependency_graph_json" || ! -f "$module_dependency_graph_binary" || ! -f "$module_dependency_graph_manifest" ]]; then
  echo "missing module dependency graph sidecars" >&2
  exit 1
fi
grep -Fq '"dependency_graph"' "$module_dependency_graph_json" || { echo "dependency graph JSON missing graph object" >&2; exit 1; }
grep -Fq '"row": 3, "id": "fixed_math", "role": "transitive"' "$module_dependency_graph_json" || { echo "dependency graph JSON missing transitive row" >&2; exit 1; }
grep -Fq '"edges": [{ "from": 1, "to": 3 }]' "$module_dependency_graph_json" || { echo "dependency graph JSON missing edge" >&2; exit 1; }
grep -Fq '"ordinal": 3, "id": "fixed_math", "role": "transitive"' "$module_dependency_graph_manifest" || { echo "dependency graph disk manifest missing transitive file" >&2; exit 1; }
if [[ ! -f "$module_dependency_graph_load_asm" ]]; then
  echo "missing dependency graph load asm" >&2
  exit 1
fi
grep -Fq 'jsr zeropage_module_load_dependency_row3' "$module_dependency_graph_load_asm" || { echo "dependency graph load asm missing prerequisite row load" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_load_dependency_row1' "$module_dependency_graph_load_asm" || { echo "dependency graph load asm missing target row load" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_unload_dependency_row3' "$module_dependency_graph_load_asm" || { echo "dependency graph load asm missing rollback unload" >&2; exit 1; }
grep -Fq 'zeropage_module_registry_row3_reu_cache = $031800' "$module_dependency_graph_load_asm" || { echo "dependency graph load asm missing transitive cache constant" >&2; exit 1; }
grep -Fq 'zeropage_module_dependency_row3_filename:' "$module_dependency_graph_load_asm" || { echo "dependency graph load asm missing transitive filename" >&2; exit 1; }
if [[ ! -f "$module_dependency_graph_on_demand_asm" ]]; then
  echo "missing dependency graph on-demand asm" >&2
  exit 1
fi
grep -Fq '"graph": true' "$module_dependency_graph_on_demand_json" || { echo "dependency graph on-demand JSON missing graph policy bit" >&2; exit 1; }
grep -Fq 'lda zeropage_module_registry_row1_loaded' "$module_dependency_graph_on_demand_asm" || { echo "dependency graph on-demand asm missing loaded check" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_load_dependency_row3' "$module_dependency_graph_on_demand_asm" || { echo "dependency graph on-demand asm missing prerequisite graph load" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_load_dependency_row1' "$module_dependency_graph_on_demand_asm" || { echo "dependency graph on-demand asm missing target graph load" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_unload_dependency_row3' "$module_dependency_graph_on_demand_asm" || { echo "dependency graph on-demand asm missing rollback unload" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_activate_dependency_row1' "$module_dependency_graph_on_demand_asm" || { echo "dependency graph on-demand asm missing direct dependency activation" >&2; exit 1; }
if [[ ! -f "$module_dependency_graph_preload_asm" ]]; then
  echo "missing dependency graph preload asm" >&2
  exit 1
fi
grep -Fq '"graph": true' "$module_dependency_graph_preload_json" || { echo "dependency graph preload JSON missing graph policy bit" >&2; exit 1; }
grep -Fq 'zeropage_module_dependency_preload_start:' "$module_dependency_graph_preload_asm" || { echo "dependency graph preload asm missing startup label" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_load_dependency_row3' "$module_dependency_graph_preload_asm" || { echo "dependency graph preload asm missing prerequisite graph load" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_load_dependency_row1' "$module_dependency_graph_preload_asm" || { echo "dependency graph preload asm missing target graph load" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_unload_dependency_row3' "$module_dependency_graph_preload_asm" || { echo "dependency graph preload asm missing rollback unload" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_activate_dependency_row1' "$module_dependency_graph_preload_asm" || { echo "dependency graph preload asm missing later activation" >&2; exit 1; }
if [[ ! -f "$module_typed_dependency_graph_asm" ]]; then
  echo "missing typed dependency graph lifecycle asm" >&2
  exit 1
fi
grep -Fq 'jsr zeropage_module_load_dependency_row3' "$module_typed_dependency_graph_asm" || { echo "typed dependency graph asm missing prerequisite graph load" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_load_dependency_row1' "$module_typed_dependency_graph_asm" || { echo "typed dependency graph asm missing target graph load" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_unload_dependency_row3' "$module_typed_dependency_graph_asm" || { echo "typed dependency graph asm missing rollback unload" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_activate_dependency_row1' "$module_typed_dependency_graph_asm" || { echo "typed dependency graph asm missing typed call activation" >&2; exit 1; }
if grep -Fq "MathCore" "$module_typed_dependency_graph_asm"; then
  echo "typed dependency graph asm leaked binding name" >&2
  exit 1
fi
if [[ ! -f "$module_dependency_graph_acquire_asm" ]]; then
  echo "missing dependency graph acquire asm" >&2
  exit 1
fi
grep -Fq 'jsr zeropage_module_acquire_dependency_row3' "$module_dependency_graph_acquire_asm" || { echo "dependency graph acquire asm missing prerequisite acquire" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_acquire_dependency_row1' "$module_dependency_graph_acquire_asm" || { echo "dependency graph acquire asm missing target acquire" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_unload_dependency_row3' "$module_dependency_graph_acquire_asm" || { echo "dependency graph acquire asm missing rollback release" >&2; exit 1; }
grep -Fq 'inc zeropage_module_registry_row3_refcount' "$module_dependency_graph_acquire_asm" || { echo "dependency graph acquire asm missing transitive refcount increment" >&2; exit 1; }
grep -Fq 'inc zeropage_module_registry_row1_refcount' "$module_dependency_graph_acquire_asm" || { echo "dependency graph acquire asm missing direct refcount increment" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_activate_dependency_row1' "$module_dependency_graph_acquire_asm" || { echo "dependency graph acquire asm missing direct dependency activation" >&2; exit 1; }
if [[ ! -f "$module_dependency_graph_release_asm" ]]; then
  echo "missing dependency graph release asm" >&2
  exit 1
fi
grep -Fq 'jsr zeropage_module_unload_dependency_row1' "$module_dependency_graph_release_asm" || { echo "dependency graph release asm missing direct row release" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_unload_dependency_row3' "$module_dependency_graph_release_asm" || { echo "dependency graph release asm missing prerequisite row release" >&2; exit 1; }
grep -Fq 'dec zeropage_module_registry_row1_refcount' "$module_dependency_graph_release_asm" || { echo "dependency graph release asm missing direct refcount decrement" >&2; exit 1; }
grep -Fq 'dec zeropage_module_registry_row3_refcount' "$module_dependency_graph_release_asm" || { echo "dependency graph release asm missing prerequisite refcount decrement" >&2; exit 1; }
grep -Fq 'zeropage_module_unload_dependency_row1_final_release:' "$module_dependency_graph_release_asm" || { echo "dependency graph release asm missing direct final release" >&2; exit 1; }
grep -Fq 'zeropage_module_unload_dependency_row3_final_release:' "$module_dependency_graph_release_asm" || { echo "dependency graph release asm missing prerequisite final release" >&2; exit 1; }
if [[ ! -f "$module_typed_dependency_graph_ownership_asm" ]]; then
  echo "missing typed dependency graph ownership asm" >&2
  exit 1
fi
grep -Fq 'jsr zeropage_module_acquire_dependency_row3' "$module_typed_dependency_graph_ownership_asm" || { echo "typed graph ownership asm missing prerequisite acquire" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_acquire_dependency_row1' "$module_typed_dependency_graph_ownership_asm" || { echo "typed graph ownership asm missing target acquire" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_unload_dependency_row1' "$module_typed_dependency_graph_ownership_asm" || { echo "typed graph ownership asm missing direct row release" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_unload_dependency_row3' "$module_typed_dependency_graph_ownership_asm" || { echo "typed graph ownership asm missing prerequisite row release" >&2; exit 1; }
if grep -Fq "MathCore" "$module_typed_dependency_graph_ownership_asm"; then
  echo "typed graph ownership asm leaked binding name" >&2
  exit 1
fi
if [[ ! -f "$module_graph_node_call_asm" ]]; then
  echo "missing graph node call asm" >&2
  exit 1
fi
grep -Fq 'jsr zeropage_module_activate_dependency_row3' "$module_graph_node_call_asm" || { echo "graph node call asm missing transitive activation" >&2; exit 1; }
grep -Fq 'zeropage_module_activate_dependency_row3:' "$module_graph_node_call_asm" || { echo "graph node call asm missing transitive activation helper" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_registry_jump_table+0' "$module_graph_node_call_asm" || { echo "graph node call asm missing ordinal jump-table dispatch" >&2; exit 1; }
if [[ ! -f "$module_typed_graph_node_binding_asm" ]]; then
  echo "missing typed graph node binding asm" >&2
  exit 1
fi
grep -Fq 'jsr zeropage_module_acquire_dependency_row3' "$module_typed_graph_node_binding_asm" || { echo "typed graph node binding asm missing prerequisite acquire" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_activate_dependency_row3' "$module_typed_graph_node_binding_asm" || { echo "typed graph node binding asm missing transitive activation" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_registry_jump_table+0' "$module_typed_graph_node_binding_asm" || { echo "typed graph node binding asm missing ordinal jump-table dispatch" >&2; exit 1; }
if grep -Fq "FixedMath" "$module_typed_graph_node_binding_asm"; then
  echo "typed graph node binding asm leaked binding name" >&2
  exit 1
fi
if [[ ! -f "$module_multi_window_dispatch_asm" ]]; then
  echo "missing multi-window dispatch asm" >&2
  exit 1
fi
grep -Fq 'zeropage_module_registry_active_row_aux:' "$module_multi_window_dispatch_asm" || { echo "multi-window dispatch asm missing aux active row" >&2; exit 1; }
grep -Fq 'lda zeropage_module_registry_active_row_aux' "$module_multi_window_dispatch_asm" || { echo "multi-window dispatch asm missing aux active check" >&2; exit 1; }
grep -Fq 'jsr $6000' "$module_multi_window_dispatch_asm" || { echo "multi-window dispatch asm missing aux ordinal dispatch" >&2; exit 1; }
grep -Fq 'sta $6001' "$module_multi_window_dispatch_asm" || { echo "multi-window dispatch asm missing aux relocation patch" >&2; exit 1; }
module_basic_bank_json="build/small/86_module_basic_bank_metadata.prg.zpmod.json"
module_basic_bank_bin="build/small/86_module_basic_bank_metadata.prg.zpmod"
module_kernal_bank_json="build/small/89_module_kernal_bank_metadata.prg.zpmod.json"
module_kernal_bank_bin="build/small/89_module_kernal_bank_metadata.prg.zpmod"
if [[ ! -f "$module_basic_bank_json" || ! -f "$module_basic_bank_bin" ]]; then
  echo "missing BASIC-bank metadata sidecars" >&2
  exit 1
fi
grep -Fq '"name": "basic", "addr": 40960, "size": 2048, "alignment": 256, "bank": "ram_under_basic"' "$module_basic_bank_json" || { echo "BASIC-bank metadata JSON missing banked window" >&2; exit 1; }
grep -Fq '"id": "math_core", "window": "basic", "row": 1' "$module_basic_bank_json" || { echo "BASIC-bank metadata JSON missing row assignment" >&2; exit 1; }
if [[ ! -f "$module_kernal_bank_json" || ! -f "$module_kernal_bank_bin" ]]; then
  echo "missing KERNAL-bank metadata sidecars" >&2
  exit 1
fi
grep -Fq '"name": "kernal", "addr": 57344, "size": 4096, "alignment": 256, "bank": "ram_under_kernal"' "$module_kernal_bank_json" || { echo "KERNAL-bank metadata JSON missing banked window" >&2; exit 1; }
grep -Fq '"id": "math_core", "window": "kernal", "row": 1' "$module_kernal_bank_json" || { echo "KERNAL-bank metadata JSON missing row assignment" >&2; exit 1; }
module_current_basic_asm="build/small/87_module_current_basic_bank.prg.asm"
module_current_basic_json="build/small/87_module_current_basic_bank.prg.zpmod.json"
module_current_kernal_asm="build/small/90_module_current_kernal_bank.prg.asm"
module_current_kernal_json="build/small/90_module_current_kernal_bank.prg.zpmod.json"
if [[ ! -f "$module_current_basic_asm" || ! -f "$module_current_basic_json" ]]; then
  echo "missing current BASIC-bank runtime outputs" >&2
  exit 1
fi
grep -Fq '"name": "main", "addr": 40960, "size": 2048, "alignment": 256, "bank": "ram_under_basic"' "$module_current_basic_json" || { echo "current BASIC-bank JSON missing banked main window" >&2; exit 1; }
grep -Fq 'sta zeropage_module_bank_saved_port' "$module_current_basic_asm" || { echo "current BASIC-bank asm missing port save" >&2; exit 1; }
grep -Fq 'and #$fe' "$module_current_basic_asm" || { echo "current BASIC-bank asm missing LORAM clear" >&2; exit 1; }
grep -Fq 'sta $0001' "$module_current_basic_asm" || { echo "current BASIC-bank asm missing processor-port restore/write" >&2; exit 1; }
grep -Fq 'jsr $a000' "$module_current_basic_asm" || { echo "current BASIC-bank asm missing banked ordinal dispatch" >&2; exit 1; }
if [[ ! -f "$module_current_kernal_asm" || ! -f "$module_current_kernal_json" ]]; then
  echo "missing current KERNAL-bank runtime outputs" >&2
  exit 1
fi
grep -Fq '"name": "main", "addr": 57344, "size": 2048, "alignment": 256, "bank": "ram_under_kernal"' "$module_current_kernal_json" || { echo "current KERNAL-bank JSON missing banked main window" >&2; exit 1; }
grep -Fq 'php' "$module_current_kernal_asm" || { echo "current KERNAL-bank asm missing processor-status save" >&2; exit 1; }
grep -Fq 'sei' "$module_current_kernal_asm" || { echo "current KERNAL-bank asm missing interrupt mask" >&2; exit 1; }
grep -Fq 'and #$fd' "$module_current_kernal_asm" || { echo "current KERNAL-bank asm missing HIRAM clear" >&2; exit 1; }
grep -Fq 'plp' "$module_current_kernal_asm" || { echo "current KERNAL-bank asm missing processor-status restore" >&2; exit 1; }
grep -Fq 'jsr $e000' "$module_current_kernal_asm" || { echo "current KERNAL-bank asm missing banked ordinal dispatch" >&2; exit 1; }
if [[ ! -f "$module_typed_basic_bank_window_asm" || ! -f "$module_typed_basic_bank_window_json" ]]; then
  echo "missing typed BASIC-bank window outputs" >&2
  exit 1
fi
grep -Fq '"name": "basic", "addr": 40960, "size": 2048, "alignment": 256, "bank": "ram_under_basic"' "$module_typed_basic_bank_window_json" || { echo "typed BASIC-bank JSON missing banked dependency window" >&2; exit 1; }
grep -Fq 'zeropage_module_registry_active_row_basic:' "$module_typed_basic_bank_window_asm" || { echo "typed BASIC-bank asm missing basic active row" >&2; exit 1; }
grep -Fq 'sta zeropage_module_bank_saved_port' "$module_typed_basic_bank_window_asm" || { echo "typed BASIC-bank asm missing port save" >&2; exit 1; }
grep -Fq 'and #$fe' "$module_typed_basic_bank_window_asm" || { echo "typed BASIC-bank asm missing LORAM clear" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_state_save_active_dependency_basic' "$module_typed_basic_bank_window_asm" || { echo "typed BASIC-bank asm missing basic-window state save" >&2; exit 1; }
grep -Fq 'jsr $a000' "$module_typed_basic_bank_window_asm" || { echo "typed BASIC-bank asm missing banked dependency dispatch" >&2; exit 1; }
grep -Fq 'sta $a001' "$module_typed_basic_bank_window_asm" || { echo "typed BASIC-bank asm missing banked relocation patch" >&2; exit 1; }
if grep -Fq "MathCore" "$module_typed_basic_bank_window_asm" || grep -Fq "FixedMath" "$module_typed_basic_bank_window_asm"; then
  echo "typed BASIC-bank asm leaked binding name" >&2
  exit 1
fi
if [[ ! -f "$module_typed_kernal_bank_window_asm" || ! -f "$module_typed_kernal_bank_window_json" ]]; then
  echo "missing typed KERNAL-bank window outputs" >&2
  exit 1
fi
grep -Fq '"name": "kernal", "addr": 57344, "size": 2048, "alignment": 256, "bank": "ram_under_kernal"' "$module_typed_kernal_bank_window_json" || { echo "typed KERNAL-bank JSON missing banked dependency window" >&2; exit 1; }
grep -Fq 'zeropage_module_registry_active_row_kernal:' "$module_typed_kernal_bank_window_asm" || { echo "typed KERNAL-bank asm missing kernal active row" >&2; exit 1; }
grep -Fq 'php' "$module_typed_kernal_bank_window_asm" || { echo "typed KERNAL-bank asm missing processor-status save" >&2; exit 1; }
grep -Fq 'sei' "$module_typed_kernal_bank_window_asm" || { echo "typed KERNAL-bank asm missing interrupt mask" >&2; exit 1; }
grep -Fq 'and #$fd' "$module_typed_kernal_bank_window_asm" || { echo "typed KERNAL-bank asm missing HIRAM clear" >&2; exit 1; }
grep -Fq 'plp' "$module_typed_kernal_bank_window_asm" || { echo "typed KERNAL-bank asm missing processor-status restore" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_state_save_active_dependency_kernal' "$module_typed_kernal_bank_window_asm" || { echo "typed KERNAL-bank asm missing kernal-window state save" >&2; exit 1; }
grep -Fq 'jsr $e000' "$module_typed_kernal_bank_window_asm" || { echo "typed KERNAL-bank asm missing banked dependency dispatch" >&2; exit 1; }
grep -Fq 'sta $e001' "$module_typed_kernal_bank_window_asm" || { echo "typed KERNAL-bank asm missing banked relocation patch" >&2; exit 1; }
if grep -Fq "MathCore" "$module_typed_kernal_bank_window_asm" || grep -Fq "FixedMath" "$module_typed_kernal_bank_window_asm"; then
  echo "typed KERNAL-bank asm leaked binding name" >&2
  exit 1
fi
if [[ ! -f "$module_typed_multi_window_binding_asm" ]]; then
  echo "missing typed multi-window binding asm" >&2
  exit 1
fi
grep -Fq 'zeropage_module_registry_active_row_aux:' "$module_typed_multi_window_binding_asm" || { echo "typed multi-window binding asm missing aux active row" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_acquire_dependency_row3' "$module_typed_multi_window_binding_asm" || { echo "typed multi-window binding asm missing prerequisite acquire" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_acquire_dependency_row1' "$module_typed_multi_window_binding_asm" || { echo "typed multi-window binding asm missing direct acquire" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_unload_dependency_row1' "$module_typed_multi_window_binding_asm" || { echo "typed multi-window binding asm missing direct release" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_unload_dependency_row3' "$module_typed_multi_window_binding_asm" || { echo "typed multi-window binding asm missing prerequisite release" >&2; exit 1; }
grep -Fq 'jsr zeropage_module_state_save_active_dependency_aux' "$module_typed_multi_window_binding_asm" || { echo "typed multi-window binding asm missing aux state save" >&2; exit 1; }
grep -Fq 'jsr $6000' "$module_typed_multi_window_binding_asm" || { echo "typed multi-window binding asm missing aux ordinal dispatch" >&2; exit 1; }
grep -Fq 'sta $6001' "$module_typed_multi_window_binding_asm" || { echo "typed multi-window binding asm missing aux relocation patch" >&2; exit 1; }
if grep -Fq "MathCore" "$module_typed_multi_window_binding_asm" || grep -Fq "FixedMath" "$module_typed_multi_window_binding_asm"; then
  echo "typed multi-window binding asm leaked binding name" >&2
  exit 1
fi
if [[ ! -f "$module_deps_json" || ! -f "$module_deps_binary" ]]; then
  echo "missing module dependency metadata sidecar" >&2
  exit 1
fi
grep -Fq '"module_id": "enemy_deps"' "$module_deps_json" || { echo "module dependency sidecar missing module id" >&2; exit 1; }
grep -Fq '"ordinal": 0, "id": "math_core"' "$module_deps_json" || { echo "module dependency sidecar missing first dependency ordinal" >&2; exit 1; }
grep -Fq '"ordinal": 1, "id": "pathing"' "$module_deps_json" || { echo "module dependency sidecar missing second dependency ordinal" >&2; exit 1; }
perl - "$module_deps_binary" <<'PERL'
use strict;
use warnings;
my ($path) = @ARGV;
open my $fh, '<:raw', $path or die "open $path: $!";
local $/;
my $bytes = <$fh>;
die "module dependency binary bad magic\n" if substr($bytes, 0, 4) ne "ZPMD";
my $exports = unpack('v', substr($bytes, 16, 2));
my $deps = unpack('v', substr($bytes, 18, 2));
die "module dependency binary expected one export\n" if $exports != 1;
die "module dependency binary expected two deps\n" if $deps != 2;
sub read_str {
  my ($bytes_ref, $cursor_ref) = @_;
  my $len = unpack('v', substr($$bytes_ref, $$cursor_ref, 2));
  $$cursor_ref += 2;
  my $s = substr($$bytes_ref, $$cursor_ref, $len);
  $$cursor_ref += $len;
  return $s;
}
my $cursor = 38;
read_str(\$bytes, \$cursor);
for my $i (0 .. $exports - 1) {
  $cursor += 2;
  read_str(\$bytes, \$cursor);
  read_str(\$bytes, \$cursor);
  $cursor += 2;
  my $params = ord(substr($bytes, $cursor, 1));
  $cursor += 1;
  for my $p (0 .. $params - 1) {
    read_str(\$bytes, \$cursor);
    $cursor += 1;
  }
  $cursor += 1;
}
my $first_ordinal = unpack('v', substr($bytes, $cursor, 2));
$cursor += 2;
my $first_id = read_str(\$bytes, \$cursor);
my $second_ordinal = unpack('v', substr($bytes, $cursor, 2));
$cursor += 2;
my $second_id = read_str(\$bytes, \$cursor);
die "module dependency binary first dep mismatch\n" if $first_ordinal != 0 || $first_id ne "math_core";
die "module dependency binary second dep mismatch\n" if $second_ordinal != 1 || $second_id ne "pathing";
PERL
if [[ ! -f "$module_registry_plan_json" || ! -f "$module_registry_plan_binary" ]]; then
  echo "missing module registry plan sidecar" >&2
  exit 1
fi
grep -Fq '"module_id": "enemy_registry"' "$module_registry_plan_json" || { echo "module registry plan sidecar missing module id" >&2; exit 1; }
grep -Fq '"registry": {' "$module_registry_plan_json" || { echo "module registry plan JSON missing registry object" >&2; exit 1; }
grep -Fq '"capacity": 3' "$module_registry_plan_json" || { echo "module registry plan JSON missing capacity" >&2; exit 1; }
grep -Fq '"ordinal": 0, "id": "enemy_registry", "role": "current"' "$module_registry_plan_json" || { echo "module registry plan JSON missing current row" >&2; exit 1; }
grep -Fq '"ordinal": 1, "id": "math_core", "role": "dependency", "dependency_ordinal": 0' "$module_registry_plan_json" || { echo "module registry plan JSON missing first dependency row" >&2; exit 1; }
grep -Fq '"ordinal": 2, "id": "pathing", "role": "dependency", "dependency_ordinal": 1' "$module_registry_plan_json" || { echo "module registry plan JSON missing second dependency row" >&2; exit 1; }
grep -Fq '"edges": [{ "from": 0, "to": 1, "dependency_ordinal": 0 }, { "from": 0, "to": 2, "dependency_ordinal": 1 }]' "$module_registry_plan_json" || { echo "module registry plan JSON missing dependency edges" >&2; exit 1; }
perl - "$module_registry_plan_binary" <<'PERL'
use strict;
use warnings;
my ($path) = @ARGV;
open my $fh, '<:raw', $path or die "open $path: $!";
local $/;
my $bytes = <$fh>;
die "module registry plan binary bad magic\n" if substr($bytes, 0, 4) ne "ZPMD";
my $flags = unpack('v', substr($bytes, 6, 2));
die "module registry plan binary missing loader flag\n" if ($flags & 0x0001) == 0;
die "module registry plan binary missing registry flag\n" if ($flags & 0x0002) == 0;
my $exports = unpack('v', substr($bytes, 16, 2));
my $deps = unpack('v', substr($bytes, 18, 2));
my $sections = unpack('v', substr($bytes, 20, 2));
my $relocs = unpack('v', substr($bytes, 22, 2));
die "module registry plan binary expected one export\n" if $exports != 1;
die "module registry plan binary expected two deps\n" if $deps != 2;
sub read_str {
  my ($bytes_ref, $cursor_ref) = @_;
  my $len = unpack('v', substr($$bytes_ref, $$cursor_ref, 2));
  $$cursor_ref += 2;
  my $s = substr($$bytes_ref, $$cursor_ref, $len);
  $$cursor_ref += $len;
  return $s;
}
my $cursor = 38;
die "module registry plan binary wrong module id\n" if read_str(\$bytes, \$cursor) ne "enemy_registry";
for my $i (0 .. $exports - 1) {
  $cursor += 2;
  read_str(\$bytes, \$cursor);
  read_str(\$bytes, \$cursor);
  $cursor += 2;
  my $params = ord(substr($bytes, $cursor, 1));
  $cursor += 1;
  for my $p (0 .. $params - 1) {
    read_str(\$bytes, \$cursor);
    $cursor += 1;
  }
  $cursor += 1;
}
for my $i (0 .. $deps - 1) {
  $cursor += 2;
  read_str(\$bytes, \$cursor);
}
for my $i (0 .. $sections - 1) {
  read_str(\$bytes, \$cursor);
  read_str(\$bytes, \$cursor);
  $cursor += 6;
}
for my $i (0 .. $relocs - 1) {
  $cursor += 9;
  read_str(\$bytes, \$cursor);
}
$cursor += 14;
my $version = ord(substr($bytes, $cursor, 1)); $cursor += 1;
my $capacity = ord(substr($bytes, $cursor, 1)); $cursor += 1;
my $entries = ord(substr($bytes, $cursor, 1)); $cursor += 1;
my $edges = ord(substr($bytes, $cursor, 1)); $cursor += 1;
die "module registry plan binary wrong registry header\n" if $version != 1 || $capacity != 3 || $entries != 3 || $edges != 2;
my $ord0 = ord(substr($bytes, $cursor, 1)); $cursor += 1;
my $id0 = read_str(\$bytes, \$cursor);
my $role0 = ord(substr($bytes, $cursor, 1)); $cursor += 1;
my $dep0 = unpack('v', substr($bytes, $cursor, 2)); $cursor += 2;
$cursor += 2;
die "module registry current row mismatch\n" if $ord0 != 0 || $id0 ne "enemy_registry" || $role0 != 0 || $dep0 != 0xffff;
my $ord1 = ord(substr($bytes, $cursor, 1)); $cursor += 1;
my $id1 = read_str(\$bytes, \$cursor);
my $role1 = ord(substr($bytes, $cursor, 1)); $cursor += 1;
my $dep1 = unpack('v', substr($bytes, $cursor, 2)); $cursor += 4;
my $ord2 = ord(substr($bytes, $cursor, 1)); $cursor += 1;
my $id2 = read_str(\$bytes, \$cursor);
my $role2 = ord(substr($bytes, $cursor, 1)); $cursor += 1;
my $dep2 = unpack('v', substr($bytes, $cursor, 2)); $cursor += 4;
die "module registry dependency rows mismatch\n" if $ord1 != 1 || $id1 ne "math_core" || $role1 != 1 || $dep1 != 0 || $ord2 != 2 || $id2 ne "pathing" || $role2 != 1 || $dep2 != 1;
die "module registry first edge mismatch\n" if ord(substr($bytes, $cursor, 1)) != 0 || ord(substr($bytes, $cursor + 1, 1)) != 1 || unpack('v', substr($bytes, $cursor + 2, 2)) != 0;
$cursor += 4;
die "module registry second edge mismatch\n" if ord(substr($bytes, $cursor, 1)) != 0 || ord(substr($bytes, $cursor + 1, 1)) != 2 || unpack('v', substr($bytes, $cursor + 2, 2)) != 1;
PERL
if [[ ! -f "$module_disk_manifest_json" || ! -f "$module_disk_manifest_binary" || ! -f "$module_disk_manifest_packaging" ]]; then
  echo "missing module disk manifest sidecar" >&2
  exit 1
fi
grep -Fq '"module_id": "enemy_manifest"' "$module_disk_manifest_json" || { echo "module disk manifest JSON missing module id" >&2; exit 1; }
grep -Fq '"disk_manifest": {' "$module_disk_manifest_json" || { echo "module disk manifest JSON missing disk_manifest object" >&2; exit 1; }
grep -Fq '"ordinal": 0, "id": "enemy_manifest", "role": "current", "dependency_ordinal": null, "filename": "enemyrt", "cbm_filename": "ENEMYRT"' "$module_disk_manifest_json" || { echo "module disk manifest JSON missing current file row" >&2; exit 1; }
grep -Fq '"ordinal": 1, "id": "math_core", "role": "dependency", "dependency_ordinal": 0, "filename": "mathcore", "cbm_filename": "MATHCORE"' "$module_disk_manifest_json" || { echo "module disk manifest JSON missing first dependency file row" >&2; exit 1; }
grep -Fq '"ordinal": 2, "id": "pathing", "role": "dependency", "dependency_ordinal": 1, "filename": "pathing", "cbm_filename": "PATHING"' "$module_disk_manifest_json" || { echo "module disk manifest JSON missing second dependency file row" >&2; exit 1; }
grep -Fq '"format": "zeropage-module-disk-manifest"' "$module_disk_manifest_packaging" || { echo "module disk manifest packaging sidecar missing format" >&2; exit 1; }
grep -Fq '"module_id": "enemy_manifest"' "$module_disk_manifest_packaging" || { echo "module disk manifest packaging sidecar missing module id" >&2; exit 1; }
grep -Fq '"cbm_filename": "ENEMYRT"' "$module_disk_manifest_packaging" || { echo "module disk manifest packaging sidecar missing current CBM filename" >&2; exit 1; }
perl - "$module_disk_manifest_binary" <<'PERL'
use strict;
use warnings;
my ($path) = @ARGV;
open my $fh, '<:raw', $path or die "open $path: $!";
local $/;
my $bytes = <$fh>;
die "module disk manifest binary bad magic\n" if substr($bytes, 0, 4) ne "ZPMD";
my $flags = unpack('v', substr($bytes, 6, 2));
die "module disk manifest binary missing loader flag\n" if ($flags & 0x0001) == 0;
die "module disk manifest binary missing registry flag\n" if ($flags & 0x0002) == 0;
die "module disk manifest binary missing disk-manifest flag\n" if ($flags & 0x0004) == 0;
my $exports = unpack('v', substr($bytes, 16, 2));
my $deps = unpack('v', substr($bytes, 18, 2));
my $sections = unpack('v', substr($bytes, 20, 2));
my $relocs = unpack('v', substr($bytes, 22, 2));
sub read_str {
  my ($bytes_ref, $cursor_ref) = @_;
  my $len = unpack('v', substr($$bytes_ref, $$cursor_ref, 2));
  $$cursor_ref += 2;
  my $s = substr($$bytes_ref, $$cursor_ref, $len);
  $$cursor_ref += $len;
  return $s;
}
my $cursor = 38;
die "module disk manifest binary wrong module id\n" if read_str(\$bytes, \$cursor) ne "enemy_manifest";
for my $i (0 .. $exports - 1) {
  $cursor += 2;
  read_str(\$bytes, \$cursor);
  read_str(\$bytes, \$cursor);
  $cursor += 2;
  my $params = ord(substr($bytes, $cursor, 1)); $cursor += 1;
  for my $p (0 .. $params - 1) {
    read_str(\$bytes, \$cursor);
    $cursor += 1;
  }
  $cursor += 1;
}
for my $i (0 .. $deps - 1) {
  $cursor += 2;
  read_str(\$bytes, \$cursor);
}
for my $i (0 .. $sections - 1) {
  read_str(\$bytes, \$cursor);
  read_str(\$bytes, \$cursor);
  $cursor += 6;
}
for my $i (0 .. $relocs - 1) {
  $cursor += 9;
  read_str(\$bytes, \$cursor);
}
$cursor += 14;
my $registry_version = ord(substr($bytes, $cursor, 1)); $cursor += 1;
my $registry_capacity = ord(substr($bytes, $cursor, 1)); $cursor += 1;
my $registry_entries = ord(substr($bytes, $cursor, 1)); $cursor += 1;
my $registry_edges = ord(substr($bytes, $cursor, 1)); $cursor += 1;
die "module disk manifest binary wrong registry header\n" if $registry_version != 1 || $registry_capacity != 3 || $registry_entries != 3 || $registry_edges != 2;
for my $i (0 .. $registry_entries - 1) {
  $cursor += 1;
  read_str(\$bytes, \$cursor);
  $cursor += 5;
}
$cursor += 4 * $registry_edges;
my $manifest_version = ord(substr($bytes, $cursor, 1)); $cursor += 1;
my $manifest_entries = ord(substr($bytes, $cursor, 1)); $cursor += 1;
die "module disk manifest binary wrong manifest header\n" if $manifest_version != 1 || $manifest_entries != 3;
my $ord0 = ord(substr($bytes, $cursor, 1)); my $role0 = ord(substr($bytes, $cursor + 1, 1)); my $dep0 = unpack('v', substr($bytes, $cursor + 2, 2)); $cursor += 4;
my $id0 = read_str(\$bytes, \$cursor); my $file0 = read_str(\$bytes, \$cursor); my $cbm0 = read_str(\$bytes, \$cursor);
die "module disk manifest current row mismatch\n" if $ord0 != 0 || $role0 != 0 || $dep0 != 0xffff || $id0 ne "enemy_manifest" || $file0 ne "enemyrt" || $cbm0 ne "ENEMYRT";
my $ord1 = ord(substr($bytes, $cursor, 1)); my $role1 = ord(substr($bytes, $cursor + 1, 1)); my $dep1 = unpack('v', substr($bytes, $cursor + 2, 2)); $cursor += 4;
my $id1 = read_str(\$bytes, \$cursor); my $file1 = read_str(\$bytes, \$cursor); my $cbm1 = read_str(\$bytes, \$cursor);
die "module disk manifest first dep row mismatch\n" if $ord1 != 1 || $role1 != 1 || $dep1 != 0 || $id1 ne "math_core" || $file1 ne "mathcore" || $cbm1 ne "MATHCORE";
my $ord2 = ord(substr($bytes, $cursor, 1)); my $role2 = ord(substr($bytes, $cursor + 1, 1)); my $dep2 = unpack('v', substr($bytes, $cursor + 2, 2)); $cursor += 4;
my $id2 = read_str(\$bytes, \$cursor); my $file2 = read_str(\$bytes, \$cursor); my $cbm2 = read_str(\$bytes, \$cursor);
die "module disk manifest second dep row mismatch\n" if $ord2 != 2 || $role2 != 1 || $dep2 != 1 || $id2 ne "pathing" || $file2 ne "pathing" || $cbm2 ne "PATHING";
PERL
if [[ ! -f "$module_registry_rows_asm" || ! -f "$module_registry_rows_json" ]]; then
  echo "missing module registry rows outputs" >&2
  exit 1
fi
grep -Fq "zeropage_module_registry_capacity = 3" "$module_registry_rows_asm" || { echo "module registry rows asm missing capacity" >&2; exit 1; }
grep -Fq "zeropage_module_registry_entry_count = 3" "$module_registry_rows_asm" || { echo "module registry rows asm missing entry count" >&2; exit 1; }
grep -Fq "zeropage_module_registry_row0_loaded:" "$module_registry_rows_asm" || { echo "module registry rows asm missing current row" >&2; exit 1; }
grep -Fq "zeropage_module_registry_loaded:" "$module_registry_rows_asm" || { echo "module registry rows asm missing current loaded alias" >&2; exit 1; }
grep -Fq 'zeropage_module_registry_row1_reu_cache = $030800' "$module_registry_rows_asm" || { echo "module registry rows asm missing first dependency cache slot" >&2; exit 1; }
grep -Fq 'zeropage_module_registry_row2_reu_cache = $031000' "$module_registry_rows_asm" || { echo "module registry rows asm missing second dependency cache slot" >&2; exit 1; }
grep -Fq "lda zeropage_module_registry_row1_loaded" "$module_registry_rows_asm" || { echo "module registry rows asm missing first dependency isLoaded read" >&2; exit 1; }
grep -Fq "lda zeropage_module_registry_row2_loaded" "$module_registry_rows_asm" || { echo "module registry rows asm missing second dependency isLoaded read" >&2; exit 1; }
grep -Fq '"module_id": "enemy_rows"' "$module_registry_rows_json" || { echo "module registry rows JSON missing module id" >&2; exit 1; }
grep -Fq '"ordinal": 1, "id": "math_core", "role": "dependency", "dependency_ordinal": 0' "$module_registry_rows_json" || { echo "module registry rows JSON missing first dependency row" >&2; exit 1; }
if [[ ! -f "$module_dependency_load_asm" ]]; then
  echo "missing module dependency load asm" >&2
  exit 1
fi
grep -Fq "jsr zeropage_module_load_dependency_row1" "$module_dependency_load_asm" || { echo "module dependency load asm missing first dependency call" >&2; exit 1; }
grep -Fq "jsr zeropage_module_load_dependency_row2" "$module_dependency_load_asm" || { echo "module dependency load asm missing second dependency call" >&2; exit 1; }
grep -Fq "zeropage_module_dependency_row1_filename:" "$module_dependency_load_asm" || { echo "module dependency load asm missing first dependency filename" >&2; exit 1; }
grep -Fq "zeropage_module_dependency_row2_filename:" "$module_dependency_load_asm" || { echo "module dependency load asm missing second dependency filename" >&2; exit 1; }
grep -Fq 'zeropage_module_registry_row1_reu_cache = $030800' "$module_dependency_load_asm" || { echo "module dependency load asm missing first cache slot" >&2; exit 1; }
grep -Fq 'zeropage_module_registry_row2_reu_cache = $031000' "$module_dependency_load_asm" || { echo "module dependency load asm missing second cache slot" >&2; exit 1; }
./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_runtime.zp64 -o build/small/59_mathcore.prg
./zig-out/bin/zp64c compile tests/fixtures/emu/modules/pathing_runtime.zp64 -o build/small/59_pathing.prg
if [[ ! -f "$module_dependency_call_asm" ]]; then
  echo "missing module dependency call asm" >&2
  exit 1
fi
grep -Fq "jsr zeropage_module_load_dependency_row1" "$module_dependency_call_asm" || { echo "module dependency call asm missing dependency load" >&2; exit 1; }
grep -Fq "jsr zeropage_module_activate_dependency_row1" "$module_dependency_call_asm" || { echo "module dependency call asm missing first dependency activation" >&2; exit 1; }
grep -Fq "jsr zeropage_module_activate_dependency_row2" "$module_dependency_call_asm" || { echo "module dependency call asm missing second dependency activation" >&2; exit 1; }
grep -Fq "jsr zeropage_module_registry_jump_table+0" "$module_dependency_call_asm" || { echo "module dependency call asm missing ordinal 0 dispatch" >&2; exit 1; }
grep -Fq "jsr zeropage_module_registry_jump_table+3" "$module_dependency_call_asm" || { echo "module dependency call asm missing ordinal 1 dispatch" >&2; exit 1; }
grep -Fq "jsr zeropage_module_registry_jump_table+6" "$module_dependency_call_asm" || { echo "module dependency call asm missing ordinal 2 dispatch" >&2; exit 1; }
grep -Fq "zeropage_module_registry_active_row:" "$module_dependency_call_asm" || { echo "module dependency call asm missing active-row registry byte" >&2; exit 1; }
grep -Fq 'sta $c091' "$module_dependency_call_asm" || { echo "module dependency call asm missing relocation patch store" >&2; exit 1; }
if [[ ! -f "$module_dependency_unload_asm" ]]; then
  echo "missing module dependency unload asm" >&2
  exit 1
fi
grep -Fq "jsr zeropage_module_unload_dependency_row1" "$module_dependency_unload_asm" || { echo "module dependency unload asm missing unload call" >&2; exit 1; }
grep -Fq "zeropage_module_unload_dependency_row1:" "$module_dependency_unload_asm" || { echo "module dependency unload asm missing unload helper" >&2; exit 1; }
grep -Fq "sta zeropage_module_registry_row1_loaded" "$module_dependency_unload_asm" || { echo "module dependency unload asm missing loaded clear" >&2; exit 1; }
grep -Fq "sta zeropage_module_registry_row1_refcount" "$module_dependency_unload_asm" || { echo "module dependency unload asm missing refcount clear" >&2; exit 1; }
grep -Fq "sta zeropage_module_registry_active_row" "$module_dependency_unload_asm" || { echo "module dependency unload asm missing active row clear" >&2; exit 1; }
if [[ ! -f "$module_typed_dependency_call_asm" ]]; then
  echo "missing typed dependency call asm" >&2
  exit 1
fi
grep -Fq "jsr zeropage_module_load_dependency_row1" "$module_typed_dependency_call_asm" || { echo "typed dependency call asm missing dependency load" >&2; exit 1; }
grep -Fq "jsr zeropage_module_activate_dependency_row1" "$module_typed_dependency_call_asm" || { echo "typed dependency call asm missing first dependency activation" >&2; exit 1; }
grep -Fq "jsr zeropage_module_activate_dependency_row2" "$module_typed_dependency_call_asm" || { echo "typed dependency call asm missing second dependency activation" >&2; exit 1; }
grep -Fq "jsr zeropage_module_registry_jump_table+6" "$module_typed_dependency_call_asm" || { echo "typed dependency call asm missing ordinal dispatch" >&2; exit 1; }
grep -Fq "zeropage_module_registry_active_row:" "$module_typed_dependency_call_asm" || { echo "typed dependency call asm missing active-row registry byte" >&2; exit 1; }
grep -Fq 'sta $c091' "$module_typed_dependency_call_asm" || { echo "typed dependency call asm missing relocation patch store" >&2; exit 1; }
if grep -Fq "MathCore" "$module_typed_dependency_call_asm"; then
  echo "typed dependency call asm leaked binding name" >&2
  exit 1
fi
if [[ ! -f "$module_typed_dependency_lifecycle_asm" ]]; then
  echo "missing typed dependency lifecycle asm" >&2
  exit 1
fi
grep -Fq "jsr zeropage_module_load_dependency_row1" "$module_typed_dependency_lifecycle_asm" || { echo "typed dependency lifecycle asm missing dependency load" >&2; exit 1; }
grep -Fq "jsr zeropage_module_unload_dependency_row1" "$module_typed_dependency_lifecycle_asm" || { echo "typed dependency lifecycle asm missing dependency unload" >&2; exit 1; }
grep -Fq "lda zeropage_module_registry_row1_loaded" "$module_typed_dependency_lifecycle_asm" || { echo "typed dependency lifecycle asm missing dependency isLoaded read" >&2; exit 1; }
grep -Fq "jsr zeropage_module_activate_dependency_row1" "$module_typed_dependency_lifecycle_asm" || { echo "typed dependency lifecycle asm missing first dependency activation" >&2; exit 1; }
grep -Fq "jsr zeropage_module_activate_dependency_row2" "$module_typed_dependency_lifecycle_asm" || { echo "typed dependency lifecycle asm missing second dependency activation" >&2; exit 1; }
grep -Fq "zeropage_module_registry_active_row:" "$module_typed_dependency_lifecycle_asm" || { echo "typed dependency lifecycle asm missing active-row registry byte" >&2; exit 1; }
if grep -Fq "MathCore" "$module_typed_dependency_lifecycle_asm"; then
  echo "typed dependency lifecycle asm leaked binding name" >&2
  exit 1
fi
if [[ ! -f "$module_typed_current_asm" ]]; then
  echo "missing typed current binding asm" >&2
  exit 1
fi
grep -Fq "jsr zeropage_module_load_current" "$module_typed_current_asm" || { echo "typed current asm missing embedded load" >&2; exit 1; }
grep -Fq "jsr zeropage_module_load_from_disk_current" "$module_typed_current_asm" || { echo "typed current asm missing disk load" >&2; exit 1; }
grep -Fq "jsr zeropage_module_unload_current" "$module_typed_current_asm" || { echo "typed current asm missing unload" >&2; exit 1; }
grep -Fq "jsr zeropage_module_registry_jump_table+0" "$module_typed_current_asm" || { echo "typed current asm missing ordinal dispatch" >&2; exit 1; }
if grep -Fq "EnemyRuntime" "$module_typed_current_asm"; then
  echo "typed current asm leaked binding name" >&2
  exit 1
fi
if [[ ! -f "$module_dependency_load_math_payload" || ! -f "$module_dependency_load_pathing_payload" ]]; then
  echo "missing compiled dependency module disk payloads" >&2
  exit 1
fi
perl - "$module_disk_real_payload" <<'PERL'
use strict;
use warnings;
my ($path) = @ARGV;
open my $fh, '<:raw', $path or die "open $path: $!";
read($fh, my $hdr, 2) == 2 or die "short real disk payload\n";
my $addr = unpack('v', $hdr);
die "real disk payload load address mismatch\n" if $addr != 0x9000;
PERL
perl - "$module_preload_payload" <<'PERL'
use strict;
use warnings;
my ($path) = @ARGV;
open my $fh, '<:raw', $path or die "open $path: $!";
read($fh, my $hdr, 2) == 2 or die "short preload disk payload\n";
my $addr = unpack('v', $hdr);
die "preload disk payload load address mismatch\n" if $addr != 0x9000;
PERL
perl - "$module_on_demand_payload" <<'PERL'
use strict;
use warnings;
my ($path) = @ARGV;
open my $fh, '<:raw', $path or die "open $path: $!";
read($fh, my $hdr, 2) == 2 or die "short on-demand disk payload\n";
my $addr = unpack('v', $hdr);
die "on-demand disk payload load address mismatch\n" if $addr != 0x9000;
PERL
perl - "$module_disk_reload_payload" <<'PERL'
use strict;
use warnings;
my ($path) = @ARGV;
open my $fh, '<:raw', $path or die "open $path: $!";
read($fh, my $hdr, 2) == 2 or die "short disk reload payload\n";
my $addr = unpack('v', $hdr);
die "disk reload payload load address mismatch\n" if $addr != 0x9000;
PERL
perl - "$module_typed_current_payload" <<'PERL'
use strict;
use warnings;
my ($path) = @ARGV;
open my $fh, '<:raw', $path or die "open $path: $!";
read($fh, my $hdr, 2) == 2 or die "short typed current payload\n";
my $addr = unpack('v', $hdr);
die "typed current payload load address mismatch\n" if $addr != 0x9000;
PERL
for dep_payload in "$module_dependency_load_math_payload" "$module_dependency_load_pathing_payload" "$module_dependency_call_math_payload" "$module_dependency_call_pathing_payload" "$module_dependency_unload_math_payload" "$module_typed_dependency_call_math_payload" "$module_typed_dependency_call_pathing_payload" "$module_typed_dependency_lifecycle_math_payload" "$module_typed_dependency_lifecycle_pathing_payload" "$module_dependency_state_runtime_math_payload" "$module_dependency_state_runtime_pathing_payload" "$module_dependency_preload_math_payload" "$module_dependency_on_demand_math_payload" "$module_dependency_refcount_math_payload" "$module_dependency_graph_on_demand_math_payload" "$module_dependency_graph_on_demand_fixed_payload" "$module_dependency_graph_preload_math_payload" "$module_dependency_graph_preload_fixed_payload" "$module_typed_dependency_graph_math_payload" "$module_typed_dependency_graph_fixed_payload" "$module_dependency_graph_acquire_math_payload" "$module_dependency_graph_acquire_fixed_payload" "$module_dependency_graph_release_math_payload" "$module_dependency_graph_release_fixed_payload" "$module_typed_dependency_graph_ownership_math_payload" "$module_typed_dependency_graph_ownership_fixed_payload" "$module_graph_node_call_math_payload" "$module_graph_node_call_fixed_payload" "$module_typed_graph_node_binding_math_payload" "$module_typed_graph_node_binding_fixed_payload" "$module_multi_window_dispatch_math_payload" "$module_multi_window_dispatch_fixed_payload" "$module_typed_multi_window_binding_math_payload" "$module_typed_multi_window_binding_fixed_payload" "$module_typed_basic_bank_window_math_payload" "$module_typed_basic_bank_window_fixed_payload" "$module_typed_kernal_bank_window_math_payload" "$module_typed_kernal_bank_window_fixed_payload"; do
  perl - "$dep_payload" <<'PERL'
use strict;
use warnings;
my ($path) = @ARGV;
open my $fh, '<:raw', $path or die "open $path: $!";
read($fh, my $hdr, 2) == 2 or die "short dependency payload\n";
my $addr = unpack('v', $hdr);
die "dependency payload load address mismatch\n" if $addr != 0x9000;
PERL
done

C1541="${ZEROPAGE_C1541:-/opt/homebrew/bin/c1541}"
if [[ ! -x "$C1541" ]]; then
  C1541="$(command -v c1541 || true)"
fi
if [[ -z "$C1541" || ! -x "$C1541" ]]; then
  echo "c1541 not found; required to package module disk-load VICE proof" >&2
  exit 1
fi
rm -f "$module_disk_real_d64"
"$C1541" -format "zeropage,51" d64 "$module_disk_real_d64" -write "${module_disk_real_d64%.disk.d64}" boot -write "$module_disk_real_payload" enemyrt >/dev/null
module_disk_real_dir="$("$C1541" "$module_disk_real_d64" -list)"
if [[ "$module_disk_real_dir" != *'"enemyrt"'* ]]; then
  echo "module disk D64 missing enemyrt entry" >&2
  exit 1
fi
rm -f "$module_preload_d64"
"$C1541" -format "zeropage,52" d64 "$module_preload_d64" -write "${module_preload_d64%.disk.d64}" boot -write "$module_preload_payload" enemyrt >/dev/null
module_preload_dir="$("$C1541" "$module_preload_d64" -list)"
if [[ "$module_preload_dir" != *'"enemyrt"'* ]]; then
  echo "module preload D64 missing enemyrt entry" >&2
  exit 1
fi
rm -f "$module_on_demand_d64"
"$C1541" -format "zeropage,53" d64 "$module_on_demand_d64" -write "${module_on_demand_d64%.disk.d64}" boot -write "$module_on_demand_payload" enemyrt >/dev/null
module_on_demand_dir="$("$C1541" "$module_on_demand_d64" -list)"
if [[ "$module_on_demand_dir" != *'"enemyrt"'* ]]; then
  echo "module on-demand D64 missing enemyrt entry" >&2
  exit 1
fi
rm -f "$module_disk_reload_d64"
"$C1541" -format "zeropage,56" d64 "$module_disk_reload_d64" -write "${module_disk_reload_d64%.disk.d64}" boot -write "$module_disk_reload_payload" enemyrt >/dev/null
module_disk_reload_dir="$("$C1541" "$module_disk_reload_d64" -list)"
if [[ "$module_disk_reload_dir" != *'"enemyrt"'* ]]; then
  echo "module disk reload D64 missing enemyrt entry" >&2
  exit 1
fi
rm -f "$module_dependency_load_d64"
"$C1541" -format "zeropage,59" d64 "$module_dependency_load_d64" -write "${module_dependency_load_d64%.disk.d64}" boot -write "$module_dependency_load_math_payload" mathcore -write "$module_dependency_load_pathing_payload" pathing >/dev/null
module_dependency_load_dir="$("$C1541" "$module_dependency_load_d64" -list)"
if [[ "$module_dependency_load_dir" != *'"mathcore"'* || "$module_dependency_load_dir" != *'"pathing"'* ]]; then
  echo "module dependency load D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_dependency_call_d64"
"$C1541" -format "zeropage,60" d64 "$module_dependency_call_d64" -write "${module_dependency_call_d64%.disk.d64}" boot -write "$module_dependency_call_math_payload" mathcore -write "$module_dependency_call_pathing_payload" pathing >/dev/null
module_dependency_call_dir="$("$C1541" "$module_dependency_call_d64" -list)"
if [[ "$module_dependency_call_dir" != *'"mathcore"'* || "$module_dependency_call_dir" != *'"pathing"'* ]]; then
  echo "module dependency call D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_dependency_unload_d64"
"$C1541" -format "zeropage,61" d64 "$module_dependency_unload_d64" -write "${module_dependency_unload_d64%.disk.d64}" boot -write "$module_dependency_unload_math_payload" mathcore >/dev/null
module_dependency_unload_dir="$("$C1541" "$module_dependency_unload_d64" -list)"
if [[ "$module_dependency_unload_dir" != *'"mathcore"'* ]]; then
  echo "module dependency unload D64 missing dependency entry" >&2
  exit 1
fi
rm -f "$module_typed_dependency_call_d64"
"$C1541" -format "zeropage,62" d64 "$module_typed_dependency_call_d64" -write "${module_typed_dependency_call_d64%.disk.d64}" boot -write "$module_typed_dependency_call_math_payload" mathcore -write "$module_typed_dependency_call_pathing_payload" pathing >/dev/null
module_typed_dependency_call_dir="$("$C1541" "$module_typed_dependency_call_d64" -list)"
if [[ "$module_typed_dependency_call_dir" != *'"mathcore"'* || "$module_typed_dependency_call_dir" != *'"pathing"'* ]]; then
  echo "typed dependency call D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_typed_dependency_lifecycle_d64"
"$C1541" -format "zeropage,63" d64 "$module_typed_dependency_lifecycle_d64" -write "${module_typed_dependency_lifecycle_d64%.disk.d64}" boot -write "$module_typed_dependency_lifecycle_math_payload" mathcore -write "$module_typed_dependency_lifecycle_pathing_payload" pathing >/dev/null
module_typed_dependency_lifecycle_dir="$("$C1541" "$module_typed_dependency_lifecycle_d64" -list)"
if [[ "$module_typed_dependency_lifecycle_dir" != *'"mathcore"'* || "$module_typed_dependency_lifecycle_dir" != *'"pathing"'* ]]; then
  echo "typed dependency lifecycle D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_dependency_state_runtime_d64"
"$C1541" -format "zeropage,68" d64 "$module_dependency_state_runtime_d64" -write "${module_dependency_state_runtime_d64%.disk.d64}" boot -write "$module_dependency_state_runtime_math_payload" mathcore -write "$module_dependency_state_runtime_pathing_payload" pathing >/dev/null
module_dependency_state_runtime_dir="$("$C1541" "$module_dependency_state_runtime_d64" -list)"
if [[ "$module_dependency_state_runtime_dir" != *'"mathcore"'* || "$module_dependency_state_runtime_dir" != *'"pathing"'* ]]; then
  echo "dependency state runtime D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_dependency_preload_d64"
"$C1541" -format "zeropage,69" d64 "$module_dependency_preload_d64" -write "${module_dependency_preload_d64%.disk.d64}" boot -write "$module_dependency_preload_math_payload" mathcore >/dev/null
module_dependency_preload_dir="$("$C1541" "$module_dependency_preload_d64" -list)"
if [[ "$module_dependency_preload_dir" != *'"mathcore"'* ]]; then
  echo "dependency preload D64 missing mathcore entry" >&2
  exit 1
fi
rm -f "$module_dependency_on_demand_d64"
"$C1541" -format "zeropage,70" d64 "$module_dependency_on_demand_d64" -write "${module_dependency_on_demand_d64%.disk.d64}" boot -write "$module_dependency_on_demand_math_payload" mathcore >/dev/null
module_dependency_on_demand_dir="$("$C1541" "$module_dependency_on_demand_d64" -list)"
if [[ "$module_dependency_on_demand_dir" != *'"mathcore"'* ]]; then
  echo "dependency on-demand D64 missing mathcore entry" >&2
  exit 1
fi
rm -f "$module_dependency_refcount_d64"
"$C1541" -format "zeropage,71" d64 "$module_dependency_refcount_d64" -write "${module_dependency_refcount_d64%.disk.d64}" boot -write "$module_dependency_refcount_math_payload" mathcore >/dev/null
module_dependency_refcount_dir="$("$C1541" "$module_dependency_refcount_d64" -list)"
if [[ "$module_dependency_refcount_dir" != *'"mathcore"'* ]]; then
  echo "dependency refcount D64 missing mathcore entry" >&2
  exit 1
fi
rm -f "$module_dependency_graph_load_d64"
"$C1541" -format "zeropage,73" d64 "$module_dependency_graph_load_d64" \
  -write "${module_dependency_graph_load_d64%.disk.d64}" boot \
  -write "$module_dependency_graph_load_math_payload" mathcore \
  -write "$module_dependency_graph_load_fixed_payload" fixedmath >/dev/null
module_dependency_graph_load_dir="$("$C1541" "$module_dependency_graph_load_d64" -list)"
if [[ "$module_dependency_graph_load_dir" != *'"mathcore"'* || "$module_dependency_graph_load_dir" != *'"fixedmath"'* ]]; then
  echo "dependency graph load D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_dependency_graph_on_demand_d64"
"$C1541" -format "zeropage,74" d64 "$module_dependency_graph_on_demand_d64" \
  -write "${module_dependency_graph_on_demand_d64%.disk.d64}" boot \
  -write "$module_dependency_graph_on_demand_math_payload" mathcore \
  -write "$module_dependency_graph_on_demand_fixed_payload" fixedmath >/dev/null
module_dependency_graph_on_demand_dir="$("$C1541" "$module_dependency_graph_on_demand_d64" -list)"
if [[ "$module_dependency_graph_on_demand_dir" != *'"mathcore"'* || "$module_dependency_graph_on_demand_dir" != *'"fixedmath"'* ]]; then
  echo "dependency graph on-demand D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_dependency_graph_preload_d64"
"$C1541" -format "zeropage,75" d64 "$module_dependency_graph_preload_d64" \
  -write "${module_dependency_graph_preload_d64%.disk.d64}" boot \
  -write "$module_dependency_graph_preload_math_payload" mathcore \
  -write "$module_dependency_graph_preload_fixed_payload" fixedmath >/dev/null
module_dependency_graph_preload_dir="$("$C1541" "$module_dependency_graph_preload_d64" -list)"
if [[ "$module_dependency_graph_preload_dir" != *'"mathcore"'* || "$module_dependency_graph_preload_dir" != *'"fixedmath"'* ]]; then
  echo "dependency graph preload D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_typed_dependency_graph_d64"
"$C1541" -format "zeropage,76" d64 "$module_typed_dependency_graph_d64" \
  -write "${module_typed_dependency_graph_d64%.disk.d64}" boot \
  -write "$module_typed_dependency_graph_math_payload" mathcore \
  -write "$module_typed_dependency_graph_fixed_payload" fixedmath >/dev/null
module_typed_dependency_graph_dir="$("$C1541" "$module_typed_dependency_graph_d64" -list)"
if [[ "$module_typed_dependency_graph_dir" != *'"mathcore"'* || "$module_typed_dependency_graph_dir" != *'"fixedmath"'* ]]; then
  echo "typed dependency graph D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_dependency_graph_acquire_d64"
"$C1541" -format "zeropage,77" d64 "$module_dependency_graph_acquire_d64" \
  -write "${module_dependency_graph_acquire_d64%.disk.d64}" boot \
  -write "$module_dependency_graph_acquire_math_payload" mathcore \
  -write "$module_dependency_graph_acquire_fixed_payload" fixedmath >/dev/null
module_dependency_graph_acquire_dir="$("$C1541" "$module_dependency_graph_acquire_d64" -list)"
if [[ "$module_dependency_graph_acquire_dir" != *'"mathcore"'* || "$module_dependency_graph_acquire_dir" != *'"fixedmath"'* ]]; then
  echo "dependency graph acquire D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_dependency_graph_release_d64"
"$C1541" -format "zeropage,78" d64 "$module_dependency_graph_release_d64" \
  -write "${module_dependency_graph_release_d64%.disk.d64}" boot \
  -write "$module_dependency_graph_release_math_payload" mathcore \
  -write "$module_dependency_graph_release_fixed_payload" fixedmath >/dev/null
module_dependency_graph_release_dir="$("$C1541" "$module_dependency_graph_release_d64" -list)"
if [[ "$module_dependency_graph_release_dir" != *'"mathcore"'* || "$module_dependency_graph_release_dir" != *'"fixedmath"'* ]]; then
  echo "dependency graph release D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_typed_dependency_graph_ownership_d64"
"$C1541" -format "zeropage,79" d64 "$module_typed_dependency_graph_ownership_d64" \
  -write "${module_typed_dependency_graph_ownership_d64%.disk.d64}" boot \
  -write "$module_typed_dependency_graph_ownership_math_payload" mathcore \
  -write "$module_typed_dependency_graph_ownership_fixed_payload" fixedmath >/dev/null
module_typed_dependency_graph_ownership_dir="$("$C1541" "$module_typed_dependency_graph_ownership_d64" -list)"
if [[ "$module_typed_dependency_graph_ownership_dir" != *'"mathcore"'* || "$module_typed_dependency_graph_ownership_dir" != *'"fixedmath"'* ]]; then
  echo "typed graph ownership D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_graph_node_call_d64"
"$C1541" -format "zeropage,81" d64 "$module_graph_node_call_d64" \
  -write "${module_graph_node_call_d64%.disk.d64}" boot \
  -write "$module_graph_node_call_math_payload" mathcore \
  -write "$module_graph_node_call_fixed_payload" fixedmath >/dev/null
module_graph_node_call_dir="$("$C1541" "$module_graph_node_call_d64" -list)"
if [[ "$module_graph_node_call_dir" != *'"mathcore"'* || "$module_graph_node_call_dir" != *'"fixedmath"'* ]]; then
  echo "graph node call D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_typed_graph_node_binding_d64"
"$C1541" -format "zeropage,82" d64 "$module_typed_graph_node_binding_d64" \
  -write "${module_typed_graph_node_binding_d64%.disk.d64}" boot \
  -write "$module_typed_graph_node_binding_math_payload" mathcore \
  -write "$module_typed_graph_node_binding_fixed_payload" fixedmath >/dev/null
module_typed_graph_node_binding_dir="$("$C1541" "$module_typed_graph_node_binding_d64" -list)"
if [[ "$module_typed_graph_node_binding_dir" != *'"mathcore"'* || "$module_typed_graph_node_binding_dir" != *'"fixedmath"'* ]]; then
  echo "typed graph node binding D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_multi_window_dispatch_d64"
"$C1541" -format "zeropage,84" d64 "$module_multi_window_dispatch_d64" \
  -write "${module_multi_window_dispatch_d64%.disk.d64}" boot \
  -write "$module_multi_window_dispatch_math_payload" mathcore \
  -write "$module_multi_window_dispatch_fixed_payload" fixedmath >/dev/null
module_multi_window_dispatch_dir="$("$C1541" "$module_multi_window_dispatch_d64" -list)"
if [[ "$module_multi_window_dispatch_dir" != *'"mathcore"'* || "$module_multi_window_dispatch_dir" != *'"fixedmath"'* ]]; then
  echo "multi-window dispatch D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_typed_multi_window_binding_d64"
"$C1541" -format "zeropage,85" d64 "$module_typed_multi_window_binding_d64" \
  -write "${module_typed_multi_window_binding_d64%.disk.d64}" boot \
  -write "$module_typed_multi_window_binding_math_payload" mathcore \
  -write "$module_typed_multi_window_binding_fixed_payload" fixedmath >/dev/null
module_typed_multi_window_binding_dir="$("$C1541" "$module_typed_multi_window_binding_d64" -list)"
if [[ "$module_typed_multi_window_binding_dir" != *'"mathcore"'* || "$module_typed_multi_window_binding_dir" != *'"fixedmath"'* ]]; then
  echo "typed multi-window binding D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_typed_basic_bank_window_d64"
"$C1541" -format "zeropage,88" d64 "$module_typed_basic_bank_window_d64" \
  -write "${module_typed_basic_bank_window_d64%.disk.d64}" boot \
  -write "$module_typed_basic_bank_window_math_payload" mathcore \
  -write "$module_typed_basic_bank_window_fixed_payload" fixedmath >/dev/null
module_typed_basic_bank_window_dir="$("$C1541" "$module_typed_basic_bank_window_d64" -list)"
if [[ "$module_typed_basic_bank_window_dir" != *'"mathcore"'* || "$module_typed_basic_bank_window_dir" != *'"fixedmath"'* ]]; then
  echo "typed BASIC-bank window D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_typed_kernal_bank_window_d64"
"$C1541" -format "zeropage,91" d64 "$module_typed_kernal_bank_window_d64" \
  -write "${module_typed_kernal_bank_window_d64%.disk.d64}" boot \
  -write "$module_typed_kernal_bank_window_math_payload" mathcore \
  -write "$module_typed_kernal_bank_window_fixed_payload" fixedmath >/dev/null
module_typed_kernal_bank_window_dir="$("$C1541" "$module_typed_kernal_bank_window_d64" -list)"
if [[ "$module_typed_kernal_bank_window_dir" != *'"mathcore"'* || "$module_typed_kernal_bank_window_dir" != *'"fixedmath"'* ]]; then
  echo "typed KERNAL-bank window D64 missing dependency entries" >&2
  exit 1
fi
rm -f "$module_dependency_kernal_console_trampoline_d64"
"$C1541" -format "zeropage,94" d64 "$module_dependency_kernal_console_trampoline_d64" \
  -write "${module_dependency_kernal_console_trampoline_d64%.disk.d64}" boot \
  -write "$module_dependency_kernal_console_trampoline_payload" mathcore >/dev/null
module_dependency_kernal_console_trampoline_dir="$("$C1541" "$module_dependency_kernal_console_trampoline_d64" -list)"
if [[ "$module_dependency_kernal_console_trampoline_dir" != *'"mathcore"'* ]]; then
  echo "dependency KERNAL console trampoline D64 missing mathcore entry" >&2
  exit 1
fi
rm -f "$module_typed_current_d64"
"$C1541" -format "zeropage,64" d64 "$module_typed_current_d64" -write "${module_typed_current_d64%.disk.d64}" boot -write "$module_typed_current_payload" enemyrt >/dev/null
module_typed_current_dir="$("$C1541" "$module_typed_current_d64" -list)"
if [[ "$module_typed_current_dir" != *'"enemyrt"'* ]]; then
  echo "typed current binding D64 missing enemyrt entry" >&2
  exit 1
fi

if [[ "$RUN_VICE" == "1" ]]; then
  if [[ -z "$VICE_TASKS" || ! -f "$VICE_TASKS" ]]; then
    echo "VICE task harness not found; set ZEROPAGE_VICE_TASKS=/path/to/ViceTasks.Binary.csproj" >&2
    exit 1
  fi

  if [[ -z "${ZEROPAGE_VICE_TASKS:-}" ]]; then
    VICE_TASKS="$(python3 "$ROOT_DIR/scripts/prepare_vice_harness.py" --source "$VICE_TASKS")"
  fi

  run_vice_plan() {
    local plan="$1"
    if dotnet run --project "$VICE_TASKS" -- run-plan --plan "$plan" --no-tui --close-vice; then
      return 0
    fi

    local manifest
    manifest="$(ls -t logs/vice_auto_*/manifest.json 2>/dev/null | head -1 || true)"
    if [[ -n "$manifest" ]] \
      && grep -Fq '"status": "partial"' "$manifest" \
      && grep -Fq '"failed_step": null' "$manifest" \
      && grep -Fq '"failure_message": null' "$manifest" \
      && grep -Fq '"final_dump_error": "Unable to write data to the transport connection: Broken pipe."' "$manifest" \
      && ! grep -Fq '"status": "failed"' "$manifest"; then
      echo "VICE plan assertions passed; tolerating final dump broken pipe for $plan ($manifest)" >&2
      return 0
    fi

    return 1
  }

  for name in 02_flow 03_functions 04_types 05_struct_fields 06_module_main 07_loop_control 08_assignment_math 09_console_scroll 10_inline_asm 11_strings_petscii 12_mutable_strings 13_string_controls 14_keyboard_input 15_array_lookup 16_inline_asm_strings 17_for_array_loop 18_switch_dispatch 19_enum_struct_game 20_struct_value_helpers 21_pointer_mmio 22_pointer_indexing 23_as_casts 24_optional_union_event 25_struct_array_table 26_static_abi_metadata 27_stack_main_border 28_static_calls_stack_helper 29_module_rodata_assets 30_stack_main_calls_static_helper 31_stack_calls_stack_helper 32_stack_recursive_border 33_reu_copy_smoke 34_near_heap_arena 35_fixed_heap_blocks 36_far_reu_arena 37_far_reu_struct_view 38_far_reu_materialize_flush 39_far_reu_materialize_range 40_module_metadata 41_module_binary 42_module_ordinals_relocs 43_module_rodata_relocs 44_module_loader_window 45_module_relocation_sim 46_module_runtime_load_window 47_module_registry_state 48_module_unload_state 49_module_dynamic_call 50_module_disk_load 51_module_disk_load_real 52_module_preload_policy 53_module_on_demand_policy 54_module_dependency_metadata 55_module_registry_plan 56_module_disk_reload_matrix 57_module_disk_manifest 58_module_registry_rows 59_module_dependency_disk_load 60_module_dependency_call 61_module_dependency_unload 62_module_typed_dependency_call 63_module_typed_dependency_lifecycle 64_module_typed_current_binding 65_module_state_metadata 66_module_state_runtime 67_module_dependency_state_metadata 68_module_dependency_state_runtime 69_module_dependency_preload_policy 70_module_dependency_on_demand_policy 71_module_dependency_refcount 72_module_dependency_graph_metadata 73_module_dependency_graph_load 74_module_dependency_graph_on_demand_policy 75_module_dependency_graph_preload_policy 76_module_typed_dependency_graph_lifecycle 77_module_dependency_graph_acquire 78_module_dependency_graph_release 79_module_typed_dependency_graph_ownership 80_module_graph_node_sidecars 81_module_graph_node_call 82_module_typed_graph_node_binding 83_module_multi_window_metadata 84_module_multi_window_dispatch 85_module_typed_multi_window_binding 86_module_basic_bank_metadata 87_module_current_basic_bank 88_module_typed_basic_bank_window 89_module_kernal_bank_metadata 90_module_current_kernal_bank 91_module_typed_kernal_bank_window 92_module_kernal_bank_hardening 93_module_kernal_console_trampoline 94_module_dependency_kernal_console_trampoline 95_memory_regions_placement; do
    prg="build/small/$name.prg"
    plan="build/small/$name.vice.yaml"
    ./zig-out/bin/zp64c run-vice "$prg" -o "$plan"
    run_vice_plan "$plan"
  done

  for name in 96_memory_regions_dll; do
    prg="build/small/$name.prg"
    plan="build/small/$name.vice.yaml"
    ./zig-out/bin/zp64c run-vice "$prg" -o "$plan"
    run_vice_plan "$plan"
  done
fi

echo "verified ${#DEMOS[@]} small demos"
