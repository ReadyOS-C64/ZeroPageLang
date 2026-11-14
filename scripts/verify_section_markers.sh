#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLING_DIR="$(cd "$ROOT_DIR/.." && pwd)/zeropage-tooling"
ZIG="${ZEROPAGE_ZIG:-$TOOLING_DIR/bin/zig}"
if [[ ! -x "$ZIG" && -z "${ZEROPAGE_ZIG:-}" ]]; then
  ZIG="$(command -v zig || true)"
fi
TASS64="${ZEROPAGE_64TASS:-$TOOLING_DIR/bin/64tass}"
if [[ ! -x "$TASS64" && -z "${ZEROPAGE_64TASS:-}" ]]; then
  TASS64="$(command -v 64tass || true)"
fi

if [[ ! -x "$TASS64" ]]; then
  echo "64tass not found or not executable: $TASS64" >&2
  exit 1
fi

cd "$ROOT_DIR"
if [[ ! -x ./zig-out/bin/zp64c ]]; then
  "$ZIG" build >/dev/null
fi

OUT_DIR="build/section-marker-test"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

SOURCES=(
  "examples/small/03_functions.zp64"
  "examples/small/06_module_main.zp64"
  "examples/small/11_strings_petscii.zp64"
  "examples/small/18_switch_dispatch.zp64"
  "tests/fixtures/pass/module_rodata_main.zp64"
  "tests/fixtures/emu/lang/pass/parity/calls/function_params_locals.zp64"
  "tests/fixtures/emu/lang/pass/parity/abi/static_frame_metadata.zp64"
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
)

check_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    echo "missing section marker in $file: $needle" >&2
    exit 1
  fi
}

checked=0
for src in "${SOURCES[@]}"; do
  name="$(basename "$src" .zp64)"
  asm="$OUT_DIR/$name.asm"
  stripped="$OUT_DIR/$name.no-section-comments.asm"
  prg="$OUT_DIR/$name.prg"
  cli_prg="$OUT_DIR/$name.cli.prg"
  map="$cli_prg.zpmap.json"
  stripped_prg="$OUT_DIR/$name.no-section-comments.prg"

  if [[ "$name" == "60_module_dependency_call" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/60_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/pathing_dispatch.zp64 -o "$OUT_DIR/60_pathing.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/60_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/60_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module pathing="$OUT_DIR/60_pathing.prg.zpmod.json" \
      --dependency-relocsim pathing="$OUT_DIR/60_pathing.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/60_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/60_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module pathing="$OUT_DIR/60_pathing.prg.zpmod.json" \
      --dependency-relocsim pathing="$OUT_DIR/60_pathing.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "61_module_dependency_unload" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/61_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/61_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/61_mathcore.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/61_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/61_mathcore.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "62_module_typed_dependency_call" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/62_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/pathing_dispatch.zp64 -o "$OUT_DIR/62_pathing.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/62_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/62_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module pathing="$OUT_DIR/62_pathing.prg.zpmod.json" \
      --dependency-relocsim pathing="$OUT_DIR/62_pathing.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/62_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/62_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module pathing="$OUT_DIR/62_pathing.prg.zpmod.json" \
      --dependency-relocsim pathing="$OUT_DIR/62_pathing.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "63_module_typed_dependency_lifecycle" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/63_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/pathing_dispatch.zp64 -o "$OUT_DIR/63_pathing.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/63_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/63_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module pathing="$OUT_DIR/63_pathing.prg.zpmod.json" \
      --dependency-relocsim pathing="$OUT_DIR/63_pathing.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/63_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/63_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module pathing="$OUT_DIR/63_pathing.prg.zpmod.json" \
      --dependency-relocsim pathing="$OUT_DIR/63_pathing.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "68_module_dependency_state_runtime" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/68_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/pathing_dispatch.zp64 -o "$OUT_DIR/68_pathing.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/68_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/68_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module pathing="$OUT_DIR/68_pathing.prg.zpmod.json" \
      --dependency-relocsim pathing="$OUT_DIR/68_pathing.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/68_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/68_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module pathing="$OUT_DIR/68_pathing.prg.zpmod.json" \
      --dependency-relocsim pathing="$OUT_DIR/68_pathing.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "69_module_dependency_preload_policy" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/69_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/69_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/69_mathcore.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/69_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/69_mathcore.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "70_module_dependency_on_demand_policy" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/70_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/70_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/70_mathcore.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/70_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/70_mathcore.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "71_module_dependency_refcount" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/71_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/71_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/71_mathcore.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/71_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/71_mathcore.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "73_module_dependency_graph_load" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/73_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o "$OUT_DIR/73_fixedmath.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/73_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/73_mathcore.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/73_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/73_mathcore.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "74_module_dependency_graph_on_demand_policy" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/74_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o "$OUT_DIR/74_fixedmath.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/74_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/74_mathcore.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/74_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/74_mathcore.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "75_module_dependency_graph_preload_policy" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/75_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o "$OUT_DIR/75_fixedmath.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/75_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/75_mathcore.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/75_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/75_mathcore.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "76_module_typed_dependency_graph_lifecycle" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/76_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o "$OUT_DIR/76_fixedmath.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/76_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/76_mathcore.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/76_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/76_mathcore.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "77_module_dependency_graph_acquire" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/77_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o "$OUT_DIR/77_fixedmath.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/77_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/77_mathcore.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/77_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/77_mathcore.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "78_module_dependency_graph_release" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/78_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o "$OUT_DIR/78_fixedmath.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/78_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/78_mathcore.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/78_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/78_mathcore.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "79_module_typed_dependency_graph_ownership" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/79_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o "$OUT_DIR/79_fixedmath.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/79_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/79_mathcore.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/79_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/79_mathcore.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "80_module_graph_node_sidecars" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/80_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o "$OUT_DIR/80_fixedmath.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/80_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/80_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module fixed_math="$OUT_DIR/80_fixedmath.prg.zpmod.json" \
      --dependency-relocsim fixed_math="$OUT_DIR/80_fixedmath.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/80_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/80_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module fixed_math="$OUT_DIR/80_fixedmath.prg.zpmod.json" \
      --dependency-relocsim fixed_math="$OUT_DIR/80_fixedmath.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "81_module_graph_node_call" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/81_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o "$OUT_DIR/81_fixedmath.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/81_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/81_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module fixed_math="$OUT_DIR/81_fixedmath.prg.zpmod.json" \
      --dependency-relocsim fixed_math="$OUT_DIR/81_fixedmath.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/81_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/81_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module fixed_math="$OUT_DIR/81_fixedmath.prg.zpmod.json" \
      --dependency-relocsim fixed_math="$OUT_DIR/81_fixedmath.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "82_module_typed_graph_node_binding" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/82_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o "$OUT_DIR/82_fixedmath.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/82_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/82_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module fixed_math="$OUT_DIR/82_fixedmath.prg.zpmod.json" \
      --dependency-relocsim fixed_math="$OUT_DIR/82_fixedmath.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/82_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/82_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module fixed_math="$OUT_DIR/82_fixedmath.prg.zpmod.json" \
      --dependency-relocsim fixed_math="$OUT_DIR/82_fixedmath.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "84_module_multi_window_dispatch" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/84_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o "$OUT_DIR/84_fixedmath.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/84_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/84_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module fixed_math="$OUT_DIR/84_fixedmath.prg.zpmod.json" \
      --dependency-relocsim fixed_math="$OUT_DIR/84_fixedmath.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/84_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/84_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module fixed_math="$OUT_DIR/84_fixedmath.prg.zpmod.json" \
      --dependency-relocsim fixed_math="$OUT_DIR/84_fixedmath.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "85_module_typed_multi_window_binding" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/85_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o "$OUT_DIR/85_fixedmath.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/85_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/85_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module fixed_math="$OUT_DIR/85_fixedmath.prg.zpmod.json" \
      --dependency-relocsim fixed_math="$OUT_DIR/85_fixedmath.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/85_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/85_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module fixed_math="$OUT_DIR/85_fixedmath.prg.zpmod.json" \
      --dependency-relocsim fixed_math="$OUT_DIR/85_fixedmath.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "88_module_typed_basic_bank_window" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/88_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o "$OUT_DIR/88_fixedmath.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/88_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/88_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module fixed_math="$OUT_DIR/88_fixedmath.prg.zpmod.json" \
      --dependency-relocsim fixed_math="$OUT_DIR/88_fixedmath.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/88_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/88_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module fixed_math="$OUT_DIR/88_fixedmath.prg.zpmod.json" \
      --dependency-relocsim fixed_math="$OUT_DIR/88_fixedmath.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "91_module_typed_kernal_bank_window" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$OUT_DIR/91_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o "$OUT_DIR/91_fixedmath.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/91_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/91_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module fixed_math="$OUT_DIR/91_fixedmath.prg.zpmod.json" \
      --dependency-relocsim fixed_math="$OUT_DIR/91_fixedmath.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/91_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/91_mathcore.prg.zpmod.relocsim.json" \
      --dependency-module fixed_math="$OUT_DIR/91_fixedmath.prg.zpmod.json" \
      --dependency-relocsim fixed_math="$OUT_DIR/91_fixedmath.prg.zpmod.relocsim.json" >/dev/null
  elif [[ "$name" == "94_module_dependency_kernal_console_trampoline" ]]; then
    ./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_kernal_console.zp64 -o "$OUT_DIR/94_mathcore.prg" >/dev/null
    ./zig-out/bin/zp64c asm "$src" -o "$asm" \
      --dependency-module math_core="$OUT_DIR/94_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/94_mathcore.prg.zpmod.relocsim.json" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" \
      --dependency-module math_core="$OUT_DIR/94_mathcore.prg.zpmod.json" \
      --dependency-relocsim math_core="$OUT_DIR/94_mathcore.prg.zpmod.relocsim.json" >/dev/null
  else
    ./zig-out/bin/zp64c asm "$src" -o "$asm" >/dev/null
    ./zig-out/bin/zp64c compile "$src" -o "$cli_prg" >/dev/null
  fi
  check_contains "$asm" "; zeropage_section_begin owner=function:main kind=code lifetime=static address=near"
  check_contains "$map" '"format": "zeropage-map"'
  check_contains "$map" '"owner": "function:main"'
  check_contains "$map" '"kind": "code"'
  if [[ "$name" != "31_stack_calls_stack_helper" && "$name" != "32_stack_recursive_border" ]]; then
    check_contains "$map" '"kind": "static_frame"'
  fi

  sed '/^; zeropage_section_/d' "$asm" > "$stripped"
  "$TASS64" --m65xx --cbm-prg -o "$prg" "$asm" >/dev/null
  "$TASS64" --m65xx --cbm-prg -o "$stripped_prg" "$stripped" >/dev/null
  cmp -s "$cli_prg" "$prg"
  cmp -s "$prg" "$stripped_prg"
  checked=$((checked + 1))
done

check_contains "$OUT_DIR/03_functions.asm" "; zeropage_section_begin owner=function:add8 kind=code lifetime=static address=near"
check_contains "$OUT_DIR/03_functions.asm" "; zeropage_section_begin owner=function:add8 kind=static_frame lifetime=static address=near"
check_contains "$OUT_DIR/03_functions.asm" "; zeropage_section_begin owner=compiler kind=scratch lifetime=static address=near"
check_contains "$OUT_DIR/06_module_main.cli.prg.zpmap.json" '"owner": "function:math_add8"'
check_contains "$OUT_DIR/06_module_main.cli.prg.zpmap.json" '"owner": "function:math_isEqual8"'
check_contains "$OUT_DIR/11_strings_petscii.asm" "; zeropage_section_begin owner=runtime kind=data lifetime=static address=near"
check_contains "$OUT_DIR/11_strings_petscii.asm" "; zeropage_section_begin owner=module:main kind=rodata lifetime=static address=near"
check_contains "$OUT_DIR/11_strings_petscii.asm" "zeropage_str_greeting:"
check_contains "$OUT_DIR/18_switch_dispatch.asm" "; zeropage_section_begin owner=compiler kind=scratch lifetime=static address=near"
check_contains "$OUT_DIR/module_rodata_main.asm" "; zeropage_section_begin owner=module:assets kind=rodata lifetime=static address=near"
check_contains "$OUT_DIR/module_rodata_main.asm" "; zeropage_section_begin owner=module:main kind=rodata lifetime=static address=near"
check_contains "$OUT_DIR/module_rodata_main.cli.prg.zpmap.json" '"owner": "module:assets"'
check_contains "$OUT_DIR/module_rodata_main.cli.prg.zpmap.json" '"owner": "module:main"'
check_contains "$OUT_DIR/29_module_rodata_assets.asm" "; zeropage_section_begin owner=module:assets kind=rodata lifetime=static address=near"
check_contains "$OUT_DIR/29_module_rodata_assets.asm" "zeropage_str_assets_title:"
check_contains "$OUT_DIR/29_module_rodata_assets.asm" "zeropage_arr_assets_values:"
check_contains "$OUT_DIR/29_module_rodata_assets.cli.prg.zpmap.json" '"owner": "module:assets"'
check_contains "$OUT_DIR/function_params_locals.asm" "; zeropage_section_begin owner=compiler kind=scratch lifetime=static address=near"
check_contains "$OUT_DIR/28_static_calls_stack_helper.asm" "; zeropage_section_begin owner=function:borderFrom kind=code lifetime=static address=near"
if grep -Fq "; zeropage_section_begin owner=function:borderFrom kind=static_frame" "$OUT_DIR/28_static_calls_stack_helper.asm"; then
  echo "stack helper unexpectedly emitted a static_frame marker" >&2
  exit 1
fi
check_contains "$OUT_DIR/30_stack_main_calls_static_helper.asm" "; zeropage_section_begin owner=function:borderFrom kind=static_frame lifetime=static address=near"
if grep -Fq "; zeropage_section_begin owner=function:main kind=static_frame" "$OUT_DIR/30_stack_main_calls_static_helper.asm"; then
  echo "stack main unexpectedly emitted a static_frame marker" >&2
  exit 1
fi
check_contains "$OUT_DIR/31_stack_calls_stack_helper.asm" "; zeropage_section_begin owner=function:borderFrom kind=code lifetime=static address=near"
if grep -Fq "; zeropage_section_begin owner=function:borderFrom kind=static_frame" "$OUT_DIR/31_stack_calls_stack_helper.asm"; then
  echo "stack-to-stack helper unexpectedly emitted a static_frame marker" >&2
  exit 1
fi
if grep -Fq "; zeropage_section_begin owner=function:main kind=static_frame" "$OUT_DIR/31_stack_calls_stack_helper.asm"; then
  echo "stack-to-stack main unexpectedly emitted a static_frame marker" >&2
  exit 1
fi
if grep -Fq '"kind": "static_frame"' "$OUT_DIR/31_stack_calls_stack_helper.cli.prg.zpmap.json"; then
  echo "stack-to-stack demo unexpectedly emitted a static_frame map section" >&2
  exit 1
fi
check_contains "$OUT_DIR/32_stack_recursive_border.asm" "; zeropage_section_begin owner=function:borderFrom kind=code lifetime=static address=near"
check_contains "$OUT_DIR/32_stack_recursive_border.asm" "zeropage_stack_overflow_trap:"
if grep -Fq "; zeropage_section_begin owner=function:borderFrom kind=static_frame" "$OUT_DIR/32_stack_recursive_border.asm"; then
  echo "recursive stack helper unexpectedly emitted a static_frame marker" >&2
  exit 1
fi
if grep -Fq "; zeropage_section_begin owner=function:main kind=static_frame" "$OUT_DIR/32_stack_recursive_border.asm"; then
  echo "recursive stack main unexpectedly emitted a static_frame marker" >&2
  exit 1
fi
if grep -Fq '"kind": "static_frame"' "$OUT_DIR/32_stack_recursive_border.cli.prg.zpmap.json"; then
  echo "recursive stack demo unexpectedly emitted a static_frame map section" >&2
  exit 1
fi
check_contains "$OUT_DIR/33_reu_copy_smoke.asm" "; zeropage_section_begin owner=runtime kind=code lifetime=static address=near"
check_contains "$OUT_DIR/33_reu_copy_smoke.asm" "zeropage_reu_copy_c64_to_reu:"
check_contains "$OUT_DIR/33_reu_copy_smoke.asm" "zeropage_reu_copy_reu_to_c64:"
check_contains "$OUT_DIR/33_reu_copy_smoke.asm" "zeropage_reu_compare:"
check_contains "$OUT_DIR/33_reu_copy_smoke.cli.prg.zpmap.json" '"owner": "runtime"'
check_contains "$OUT_DIR/33_reu_copy_smoke.cli.prg.zpmap.json" '"kind": "code"'
check_contains "$OUT_DIR/34_near_heap_arena.asm" "; zeropage_section_begin owner=runtime kind=code lifetime=static address=near"
check_contains "$OUT_DIR/34_near_heap_arena.asm" "; zeropage_section_begin owner=runtime kind=data lifetime=static address=near"
check_contains "$OUT_DIR/34_near_heap_arena.asm" "zeropage_heap_near_heap_alloc_bytes:"
check_contains "$OUT_DIR/34_near_heap_arena.asm" "zeropage_heap_near_heap_cursor:"
check_contains "$OUT_DIR/34_near_heap_arena.cli.prg.zpmap.json" '"owner": "runtime"'
check_contains "$OUT_DIR/34_near_heap_arena.cli.prg.zpmap.json" '"kind": "data"'
check_contains "$OUT_DIR/35_fixed_heap_blocks.asm" "; zeropage_section_begin owner=runtime kind=code lifetime=static address=near"
check_contains "$OUT_DIR/35_fixed_heap_blocks.asm" "; zeropage_section_begin owner=runtime kind=data lifetime=static address=near"
check_contains "$OUT_DIR/35_fixed_heap_blocks.asm" "zeropage_heap_sprites_alloc_bytes:"
check_contains "$OUT_DIR/35_fixed_heap_blocks.asm" "zeropage_heap_sprites_free:"
check_contains "$OUT_DIR/35_fixed_heap_blocks.asm" "zeropage_heap_sprites_free_head:"
check_contains "$OUT_DIR/35_fixed_heap_blocks.cli.prg.zpmap.json" '"owner": "runtime"'
check_contains "$OUT_DIR/35_fixed_heap_blocks.cli.prg.zpmap.json" '"kind": "data"'
check_contains "$OUT_DIR/36_far_reu_arena.asm" "; zeropage_section_begin owner=runtime kind=code lifetime=static address=near"
check_contains "$OUT_DIR/36_far_reu_arena.asm" "; zeropage_section_begin owner=runtime kind=data lifetime=static address=near"
check_contains "$OUT_DIR/36_far_reu_arena.asm" "zeropage_reu_heap_assets_alloc_bytes:"
check_contains "$OUT_DIR/36_far_reu_arena.asm" "zeropage_reu_heap_assets_cursor:"
check_contains "$OUT_DIR/36_far_reu_arena.asm" "zeropage_reu_copy_c64_to_reu:"
check_contains "$OUT_DIR/36_far_reu_arena.asm" "zeropage_reu_copy_reu_to_c64:"
check_contains "$OUT_DIR/36_far_reu_arena.cli.prg.zpmap.json" '"owner": "runtime"'
check_contains "$OUT_DIR/36_far_reu_arena.cli.prg.zpmap.json" '"kind": "data"'
check_contains "$OUT_DIR/37_far_reu_struct_view.asm" "; zeropage_section_begin owner=runtime kind=code lifetime=static address=near"
check_contains "$OUT_DIR/37_far_reu_struct_view.asm" "; zeropage_section_begin owner=runtime kind=data lifetime=static address=near"
check_contains "$OUT_DIR/37_far_reu_struct_view.asm" "zeropage_reu_heap_assets_alloc_bytes:"
check_contains "$OUT_DIR/37_far_reu_struct_view.asm" "zeropage_reu_view_offset:"
check_contains "$OUT_DIR/37_far_reu_struct_view.asm" "zeropage_reu_view_record:"
check_contains "$OUT_DIR/37_far_reu_struct_view.asm" "zeropage_reu_copy_c64_to_reu:"
check_contains "$OUT_DIR/37_far_reu_struct_view.asm" "zeropage_reu_copy_reu_to_c64:"
check_contains "$OUT_DIR/37_far_reu_struct_view.cli.prg.zpmap.json" '"owner": "runtime"'
check_contains "$OUT_DIR/37_far_reu_struct_view.cli.prg.zpmap.json" '"kind": "data"'
check_contains "$OUT_DIR/38_far_reu_materialize_flush.asm" "; zeropage_section_begin owner=runtime kind=code lifetime=static address=near"
check_contains "$OUT_DIR/38_far_reu_materialize_flush.asm" "; zeropage_section_begin owner=runtime kind=data lifetime=static address=near"
check_contains "$OUT_DIR/38_far_reu_materialize_flush.asm" "zeropage_heap_near_heap_alloc_bytes:"
check_contains "$OUT_DIR/38_far_reu_materialize_flush.asm" "zeropage_heap_near_heap_reset:"
check_contains "$OUT_DIR/38_far_reu_materialize_flush.asm" "zeropage_reu_view_record:"
check_contains "$OUT_DIR/38_far_reu_materialize_flush.asm" "zeropage_reu_copy_c64_to_reu:"
check_contains "$OUT_DIR/38_far_reu_materialize_flush.asm" "zeropage_reu_copy_reu_to_c64:"
check_contains "$OUT_DIR/38_far_reu_materialize_flush.cli.prg.zpmap.json" '"owner": "runtime"'
check_contains "$OUT_DIR/38_far_reu_materialize_flush.cli.prg.zpmap.json" '"kind": "data"'
check_contains "$OUT_DIR/39_far_reu_materialize_range.asm" "; zeropage_section_begin owner=runtime kind=code lifetime=static address=near"
check_contains "$OUT_DIR/39_far_reu_materialize_range.asm" "; zeropage_section_begin owner=runtime kind=data lifetime=static address=near"
check_contains "$OUT_DIR/39_far_reu_materialize_range.asm" "zeropage_heap_near_heap_alloc_bytes:"
check_contains "$OUT_DIR/39_far_reu_materialize_range.asm" "zeropage_heap_near_heap_reset:"
check_contains "$OUT_DIR/39_far_reu_materialize_range.asm" "zeropage_reu_view_offset:"
check_contains "$OUT_DIR/39_far_reu_materialize_range.asm" "zeropage_reu_view_record:"
check_contains "$OUT_DIR/39_far_reu_materialize_range.asm" "zeropage_reu_copy_c64_to_reu:"
check_contains "$OUT_DIR/39_far_reu_materialize_range.asm" "zeropage_reu_copy_reu_to_c64:"
check_contains "$OUT_DIR/39_far_reu_materialize_range.cli.prg.zpmap.json" '"owner": "runtime"'
check_contains "$OUT_DIR/39_far_reu_materialize_range.cli.prg.zpmap.json" '"kind": "data"'
check_contains "$OUT_DIR/40_module_metadata.cli.prg.zpmod.json" '"format": "zeropage-module-metadata"'
check_contains "$OUT_DIR/40_module_metadata.cli.prg.zpmod.json" '"module_id": "enemy_ai"'
check_contains "$OUT_DIR/40_module_metadata.cli.prg.zpmod.json" '"label": "tick"'
check_contains "$OUT_DIR/40_module_metadata.cli.prg.zpmod.json" '"id": "math"'
check_contains "$OUT_DIR/40_module_metadata.cli.prg.zpmod.json" '"sections": ['
check_contains "$OUT_DIR/40_module_metadata.cli.prg.zpmod.json" '"relocations": []'
check_contains "$OUT_DIR/41_module_binary.cli.prg.zpmod.json" '"module_id": "enemy_bin"'
check_contains "$OUT_DIR/41_module_binary.cli.prg.zpmod.json" '"label": "tick"'
if [[ ! -f "$OUT_DIR/41_module_binary.cli.prg.zpmod" ]]; then
  echo "missing module binary sidecar for section marker fixture" >&2
  exit 1
fi
if [[ "$(LC_ALL=C head -c 4 "$OUT_DIR/41_module_binary.cli.prg.zpmod")" != "ZPMD" ]]; then
  echo "module binary sidecar missing ZPMD magic" >&2
  exit 1
fi
check_contains "$OUT_DIR/42_module_ordinals_relocs.asm" "zeropage_module_reloc_"
check_contains "$OUT_DIR/42_module_ordinals_relocs.asm" "; zeropage_relocation kind=abs16"
check_contains "$OUT_DIR/42_module_ordinals_relocs.cli.prg.zpmod.json" '"module_id": "enemy_relocs"'
check_contains "$OUT_DIR/42_module_ordinals_relocs.cli.prg.zpmod.json" '"name": "tick", "ordinal": 0'
check_contains "$OUT_DIR/42_module_ordinals_relocs.cli.prg.zpmod.json" '"name": "score", "ordinal": 1'
check_contains "$OUT_DIR/42_module_ordinals_relocs.cli.prg.zpmod.json" '"kind": "abs16"'
check_contains "$OUT_DIR/42_module_ordinals_relocs.cli.prg.zpmod.json" '"target": "bump"'
if [[ ! -f "$OUT_DIR/42_module_ordinals_relocs.cli.prg.zpmod" ]]; then
  echo "missing module ordinal/relocation binary sidecar" >&2
  exit 1
fi
check_contains "$OUT_DIR/43_module_rodata_relocs.asm" "zeropage_module_reloc_"
check_contains "$OUT_DIR/43_module_rodata_relocs.asm" "; zeropage_relocation kind=hi8"
check_contains "$OUT_DIR/43_module_rodata_relocs.asm" "; zeropage_relocation kind=lo8"
check_contains "$OUT_DIR/43_module_rodata_relocs.asm" "target=zeropage_arr_reloc_table addend=1"
check_contains "$OUT_DIR/43_module_rodata_relocs.cli.prg.zpmod.json" '"module_id": "enemy_rodata_relocs"'
check_contains "$OUT_DIR/43_module_rodata_relocs.cli.prg.zpmod.json" '"name": "table_ptr", "ordinal": 0'
check_contains "$OUT_DIR/43_module_rodata_relocs.cli.prg.zpmod.json" '"name": "bias", "ordinal": 1'
check_contains "$OUT_DIR/43_module_rodata_relocs.cli.prg.zpmod.json" '"kind": "hi8"'
check_contains "$OUT_DIR/43_module_rodata_relocs.cli.prg.zpmod.json" '"kind": "lo8"'
check_contains "$OUT_DIR/43_module_rodata_relocs.cli.prg.zpmod.json" '"target": "zeropage_arr_reloc_table"'
if [[ ! -f "$OUT_DIR/43_module_rodata_relocs.cli.prg.zpmod" ]]; then
  echo "missing module rodata relocation binary sidecar" >&2
  exit 1
fi
check_contains "$OUT_DIR/44_module_loader_window.cli.prg.zpmod.json" '"module_id": "enemy_window"'
check_contains "$OUT_DIR/44_module_loader_window.cli.prg.zpmod.json" '"loader": {'
check_contains "$OUT_DIR/44_module_loader_window.cli.prg.zpmod.json" '"load_window": { "addr": 32768, "size": 4096, "alignment": 256 }'
check_contains "$OUT_DIR/44_module_loader_window.cli.prg.zpmod.json" '"reu_cache": { "addr": 131072, "size": 65536, "alignment": 256 }'
if [[ ! -f "$OUT_DIR/44_module_loader_window.cli.prg.zpmod" ]]; then
  echo "missing module loader binary sidecar" >&2
  exit 1
fi
check_contains "$OUT_DIR/44_module_loader_window.cli.prg.zpmod.relocsim.json" '"format": "zeropage-module-relocation-sim"'
check_contains "$OUT_DIR/44_module_loader_window.cli.prg.zpmod.relocsim.json" '"applied_relocations": []'
check_contains "$OUT_DIR/45_module_relocation_sim.asm" "; zeropage_relocation kind=abs16"
check_contains "$OUT_DIR/45_module_relocation_sim.asm" "; zeropage_relocation kind=hi8"
check_contains "$OUT_DIR/45_module_relocation_sim.asm" "; zeropage_relocation kind=lo8"
check_contains "$OUT_DIR/45_module_relocation_sim.cli.prg.zpmod.relocsim.json" '"module_id": "enemy_reloc_sim"'
check_contains "$OUT_DIR/45_module_relocation_sim.cli.prg.zpmod.relocsim.json" '"kind": "abs16"'
check_contains "$OUT_DIR/45_module_relocation_sim.cli.prg.zpmod.relocsim.json" '"kind": "hi8"'
check_contains "$OUT_DIR/45_module_relocation_sim.cli.prg.zpmod.relocsim.json" '"kind": "lo8"'
check_contains "$OUT_DIR/45_module_relocation_sim.cli.prg.zpmod.relocsim.json" '"target": "bump"'
check_contains "$OUT_DIR/45_module_relocation_sim.cli.prg.zpmod.relocsim.json" '"target": "zeropage_arr_reloc_table"'
check_contains "$OUT_DIR/46_module_runtime_load_window.asm" "jsr zeropage_module_load_current"
check_contains "$OUT_DIR/46_module_runtime_load_window.asm" "zeropage_module_payload_jump_table:"
check_contains "$OUT_DIR/46_module_runtime_load_window.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/46_module_runtime_load_window.asm" "; zeropage_section_begin owner=runtime kind=data"
check_contains "$OUT_DIR/46_module_runtime_load_window.cli.prg.zpmod.relocsim.json" '"module_id": "enemy_runtime"'
check_contains "$OUT_DIR/46_module_runtime_load_window.cli.prg.zpmod.relocsim.json" '"load_window": { "addr": 49152, "size": 2048 }'
check_contains "$OUT_DIR/46_module_runtime_load_window.cli.prg.zpmod.relocsim.json" '"kind": "abs16"'
check_contains "$OUT_DIR/46_module_runtime_load_window.cli.prg.zpmod.relocsim.json" '"kind": "hi8"'
check_contains "$OUT_DIR/46_module_runtime_load_window.cli.prg.zpmod.relocsim.json" '"kind": "lo8"'
check_contains "$OUT_DIR/47_module_registry_state.asm" "jsr zeropage_module_is_loaded_current"
check_contains "$OUT_DIR/47_module_registry_state.asm" "zeropage_module_registry_loaded:"
check_contains "$OUT_DIR/47_module_registry_state.asm" "zeropage_module_registry_refcount:"
check_contains "$OUT_DIR/47_module_registry_state.asm" "zeropage_module_load_current_not_loaded:"
check_contains "$OUT_DIR/47_module_registry_state.asm" "; zeropage_section_begin owner=runtime kind=data"
check_contains "$OUT_DIR/47_module_registry_state.cli.prg.zpmod.relocsim.json" '"module_id": "enemy_runtime"'
check_contains "$OUT_DIR/47_module_registry_state.cli.prg.zpmod.relocsim.json" '"kind": "abs16"'
check_contains "$OUT_DIR/47_module_registry_state.cli.prg.zpmod.relocsim.json" '"kind": "hi8"'
check_contains "$OUT_DIR/47_module_registry_state.cli.prg.zpmod.relocsim.json" '"kind": "lo8"'
check_contains "$OUT_DIR/48_module_unload_state.asm" "jsr zeropage_module_unload_current"
check_contains "$OUT_DIR/48_module_unload_state.asm" "zeropage_module_unload_current:"
check_contains "$OUT_DIR/48_module_unload_state.asm" "sta zeropage_module_registry_loaded"
check_contains "$OUT_DIR/48_module_unload_state.asm" "sta zeropage_module_registry_refcount"
check_contains "$OUT_DIR/48_module_unload_state.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/48_module_unload_state.asm" "; zeropage_section_begin owner=runtime kind=data"
check_contains "$OUT_DIR/48_module_unload_state.cli.prg.zpmod.relocsim.json" '"module_id": "enemy_runtime"'
check_contains "$OUT_DIR/48_module_unload_state.cli.prg.zpmod.relocsim.json" '"kind": "abs16"'
check_contains "$OUT_DIR/48_module_unload_state.cli.prg.zpmod.relocsim.json" '"kind": "hi8"'
check_contains "$OUT_DIR/48_module_unload_state.cli.prg.zpmod.relocsim.json" '"kind": "lo8"'
check_contains "$OUT_DIR/49_module_dynamic_call.asm" "jsr zeropage_module_registry_jump_table+0"
check_contains "$OUT_DIR/49_module_dynamic_call.asm" "module_call_"
check_contains "$OUT_DIR/49_module_dynamic_call.asm" "zeropage_module_registry_loaded"
check_contains "$OUT_DIR/49_module_dynamic_call.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/49_module_dynamic_call.asm" "; zeropage_section_begin owner=runtime kind=data"
check_contains "$OUT_DIR/49_module_dynamic_call.cli.prg.zpmod.relocsim.json" '"module_id": "enemy_runtime"'
check_contains "$OUT_DIR/50_module_disk_load.asm" "jsr zeropage_module_load_from_disk_current"
check_contains "$OUT_DIR/50_module_disk_load.asm" "zeropage_module_disk_filename:"
check_contains "$OUT_DIR/50_module_disk_load.asm" 'jsr $ffbd'
check_contains "$OUT_DIR/50_module_disk_load.asm" 'jsr $ffba'
check_contains "$OUT_DIR/50_module_disk_load.asm" 'jsr $ffd5'
check_contains "$OUT_DIR/50_module_disk_load.asm" "; zeropage_section_begin owner=runtime kind=rodata"
check_contains "$OUT_DIR/51_module_disk_load_real.asm" "jsr zeropage_module_load_from_disk_current"
check_contains "$OUT_DIR/51_module_disk_load_real.asm" "zeropage_module_disk_filename:"
check_contains "$OUT_DIR/51_module_disk_load_real.asm" 'jsr $ffbd'
check_contains "$OUT_DIR/51_module_disk_load_real.asm" 'jsr $ffba'
check_contains "$OUT_DIR/51_module_disk_load_real.asm" 'jsr $ffd5'
check_contains "$OUT_DIR/51_module_disk_load_real.asm" "; zeropage_section_begin owner=runtime kind=rodata"
check_contains "$OUT_DIR/52_module_preload_policy.asm" "zeropage_module_preload_start:"
check_contains "$OUT_DIR/52_module_preload_policy.asm" "jsr zeropage_module_load_from_disk_current"
check_contains "$OUT_DIR/52_module_preload_policy.asm" "zeropage_module_disk_filename:"
check_contains "$OUT_DIR/52_module_preload_policy.asm" 'jsr $ffbd'
check_contains "$OUT_DIR/52_module_preload_policy.asm" 'jsr $ffba'
check_contains "$OUT_DIR/52_module_preload_policy.asm" 'jsr $ffd5'
check_contains "$OUT_DIR/52_module_preload_policy.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/52_module_preload_policy.cli.prg.zpmod.json" '"policy": { "current": { "mode": "preload", "filename": "enemyrt" } }'
check_contains "$OUT_DIR/53_module_on_demand_policy.asm" "jsr zeropage_module_load_from_disk_current"
check_contains "$OUT_DIR/53_module_on_demand_policy.asm" "module_call_"
check_contains "$OUT_DIR/53_module_on_demand_policy.asm" "zeropage_module_disk_filename:"
check_contains "$OUT_DIR/53_module_on_demand_policy.asm" 'jsr $ffbd'
check_contains "$OUT_DIR/53_module_on_demand_policy.asm" 'jsr $ffba'
check_contains "$OUT_DIR/53_module_on_demand_policy.asm" 'jsr $ffd5'
check_contains "$OUT_DIR/53_module_on_demand_policy.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/53_module_on_demand_policy.cli.prg.zpmod.json" '"policy": { "current": { "mode": "on_demand", "filename": "enemyrt" } }'
if grep -Fq "zeropage_module_preload_start:" "$OUT_DIR/53_module_on_demand_policy.asm"; then
  echo "on-demand policy unexpectedly emitted startup preload" >&2
  exit 1
fi
check_contains "$OUT_DIR/54_module_dependency_metadata.cli.prg.zpmod.json" '"module_id": "enemy_deps"'
check_contains "$OUT_DIR/54_module_dependency_metadata.cli.prg.zpmod.json" '"ordinal": 0, "id": "math_core"'
check_contains "$OUT_DIR/54_module_dependency_metadata.cli.prg.zpmod.json" '"ordinal": 1, "id": "pathing"'
check_contains "$OUT_DIR/55_module_registry_plan.cli.prg.zpmod.json" '"module_id": "enemy_registry"'
check_contains "$OUT_DIR/55_module_registry_plan.cli.prg.zpmod.json" '"registry": {'
check_contains "$OUT_DIR/55_module_registry_plan.cli.prg.zpmod.json" '"capacity": 3'
check_contains "$OUT_DIR/55_module_registry_plan.cli.prg.zpmod.json" '"ordinal": 0, "id": "enemy_registry", "role": "current"'
check_contains "$OUT_DIR/55_module_registry_plan.cli.prg.zpmod.json" '"ordinal": 1, "id": "math_core", "role": "dependency", "dependency_ordinal": 0'
check_contains "$OUT_DIR/55_module_registry_plan.cli.prg.zpmod.json" '"ordinal": 2, "id": "pathing", "role": "dependency", "dependency_ordinal": 1'
check_contains "$OUT_DIR/56_module_disk_reload_matrix.asm" "jsr zeropage_module_load_from_disk_current"
check_contains "$OUT_DIR/56_module_disk_reload_matrix.asm" "jsr zeropage_module_unload_current"
check_contains "$OUT_DIR/56_module_disk_reload_matrix.asm" "jsr zeropage_module_is_loaded_current"
check_contains "$OUT_DIR/56_module_disk_reload_matrix.asm" "zeropage_module_disk_filename:"
check_contains "$OUT_DIR/56_module_disk_reload_matrix.asm" 'jsr $ffd5'
check_contains "$OUT_DIR/56_module_disk_reload_matrix.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/56_module_disk_reload_matrix.asm" "; zeropage_section_begin owner=runtime kind=data"
check_contains "$OUT_DIR/56_module_disk_reload_matrix.asm" "; zeropage_section_begin owner=runtime kind=rodata"
check_contains "$OUT_DIR/57_module_disk_manifest.cli.prg.zpmod.json" '"module_id": "enemy_manifest"'
check_contains "$OUT_DIR/57_module_disk_manifest.cli.prg.zpmod.json" '"disk_manifest": {'
check_contains "$OUT_DIR/57_module_disk_manifest.cli.prg.zpmod.json" '"ordinal": 0, "id": "enemy_manifest", "role": "current", "dependency_ordinal": null, "filename": "enemyrt", "cbm_filename": "ENEMYRT"'
check_contains "$OUT_DIR/57_module_disk_manifest.cli.prg.zpmod.json" '"ordinal": 1, "id": "math_core", "role": "dependency", "dependency_ordinal": 0, "filename": "mathcore", "cbm_filename": "MATHCORE"'
check_contains "$OUT_DIR/57_module_disk_manifest.cli.prg.zpmod.json" '"ordinal": 2, "id": "pathing", "role": "dependency", "dependency_ordinal": 1, "filename": "pathing", "cbm_filename": "PATHING"'
check_contains "$OUT_DIR/57_module_disk_manifest.cli.prg.zpmod.diskmanifest.json" '"format": "zeropage-module-disk-manifest"'
check_contains "$OUT_DIR/57_module_disk_manifest.cli.prg.zpmod.diskmanifest.json" '"module_id": "enemy_manifest"'

check_contains "$OUT_DIR/58_module_registry_rows.asm" "zeropage_module_registry_capacity = 3"
check_contains "$OUT_DIR/58_module_registry_rows.asm" "zeropage_module_registry_entry_count = 3"
check_contains "$OUT_DIR/58_module_registry_rows.asm" "zeropage_module_registry_row0_loaded:"
check_contains "$OUT_DIR/58_module_registry_rows.asm" "zeropage_module_registry_loaded:"
check_contains "$OUT_DIR/58_module_registry_rows.asm" 'zeropage_module_registry_row1_reu_cache = $030800'
check_contains "$OUT_DIR/58_module_registry_rows.asm" 'zeropage_module_registry_row2_reu_cache = $031000'
check_contains "$OUT_DIR/58_module_registry_rows.asm" "lda zeropage_module_registry_row1_loaded"
check_contains "$OUT_DIR/58_module_registry_rows.asm" "lda zeropage_module_registry_row2_loaded"
check_contains "$OUT_DIR/58_module_registry_rows.cli.prg.zpmod.json" '"module_id": "enemy_rows"'
check_contains "$OUT_DIR/58_module_registry_rows.cli.prg.zpmod.json" '"ordinal": 1, "id": "math_core", "role": "dependency", "dependency_ordinal": 0'
check_contains "$OUT_DIR/58_module_registry_rows.cli.prg.zpmod.diskmanifest.json" '"module_id": "enemy_rows"'

check_contains "$OUT_DIR/59_module_dependency_disk_load.asm" "jsr zeropage_module_load_dependency_row1"
check_contains "$OUT_DIR/59_module_dependency_disk_load.asm" "jsr zeropage_module_load_dependency_row2"
check_contains "$OUT_DIR/59_module_dependency_disk_load.asm" "zeropage_module_dependency_row1_filename:"
check_contains "$OUT_DIR/59_module_dependency_disk_load.asm" "zeropage_module_dependency_row2_filename:"
check_contains "$OUT_DIR/59_module_dependency_disk_load.asm" 'zeropage_module_registry_row1_reu_cache = $030800'
check_contains "$OUT_DIR/59_module_dependency_disk_load.asm" 'zeropage_module_registry_row2_reu_cache = $031000'
check_contains "$OUT_DIR/59_module_dependency_disk_load.asm" "sta zeropage_module_registry_row1_loaded"
check_contains "$OUT_DIR/59_module_dependency_disk_load.asm" "sta zeropage_module_registry_row2_loaded"

check_contains "$OUT_DIR/60_module_dependency_call.asm" "zeropage_module_registry_active_row:"
check_contains "$OUT_DIR/60_module_dependency_call.asm" "jsr zeropage_module_load_dependency_row1"
check_contains "$OUT_DIR/60_module_dependency_call.asm" "jsr zeropage_module_activate_dependency_row1"
check_contains "$OUT_DIR/60_module_dependency_call.asm" "jsr zeropage_module_activate_dependency_row2"
check_contains "$OUT_DIR/60_module_dependency_call.asm" "jsr zeropage_module_registry_jump_table+6"
check_contains "$OUT_DIR/60_module_dependency_call.asm" 'sta $c091'
check_contains "$OUT_DIR/60_module_dependency_call.cli.prg.zpmap.json" '"owner": "runtime"'
check_contains "$OUT_DIR/61_module_dependency_unload.asm" "jsr zeropage_module_unload_dependency_row1"
check_contains "$OUT_DIR/61_module_dependency_unload.asm" "zeropage_module_unload_dependency_row1:"
check_contains "$OUT_DIR/61_module_dependency_unload.asm" "sta zeropage_module_registry_row1_loaded"
check_contains "$OUT_DIR/61_module_dependency_unload.asm" "sta zeropage_module_registry_row1_refcount"
check_contains "$OUT_DIR/61_module_dependency_unload.asm" "sta zeropage_module_registry_active_row"
check_contains "$OUT_DIR/61_module_dependency_unload.cli.prg.zpmap.json" '"owner": "runtime"'
check_contains "$OUT_DIR/62_module_typed_dependency_call.asm" "zeropage_module_registry_active_row:"
check_contains "$OUT_DIR/62_module_typed_dependency_call.asm" "jsr zeropage_module_load_dependency_row1"
check_contains "$OUT_DIR/62_module_typed_dependency_call.asm" "jsr zeropage_module_activate_dependency_row1"
check_contains "$OUT_DIR/62_module_typed_dependency_call.asm" "jsr zeropage_module_activate_dependency_row2"
check_contains "$OUT_DIR/62_module_typed_dependency_call.asm" "jsr zeropage_module_registry_jump_table+6"
check_contains "$OUT_DIR/62_module_typed_dependency_call.asm" 'sta $c091'
check_contains "$OUT_DIR/62_module_typed_dependency_call.cli.prg.zpmap.json" '"owner": "runtime"'
check_contains "$OUT_DIR/63_module_typed_dependency_lifecycle.asm" "jsr zeropage_module_load_dependency_row1"
check_contains "$OUT_DIR/63_module_typed_dependency_lifecycle.asm" "jsr zeropage_module_unload_dependency_row1"
check_contains "$OUT_DIR/63_module_typed_dependency_lifecycle.asm" "lda zeropage_module_registry_row1_loaded"
check_contains "$OUT_DIR/63_module_typed_dependency_lifecycle.asm" "jsr zeropage_module_activate_dependency_row1"
check_contains "$OUT_DIR/63_module_typed_dependency_lifecycle.asm" "jsr zeropage_module_activate_dependency_row2"
check_contains "$OUT_DIR/63_module_typed_dependency_lifecycle.cli.prg.zpmap.json" '"owner": "runtime"'
check_contains "$OUT_DIR/64_module_typed_current_binding.asm" "jsr zeropage_module_load_current"
check_contains "$OUT_DIR/64_module_typed_current_binding.asm" "jsr zeropage_module_load_from_disk_current"
check_contains "$OUT_DIR/64_module_typed_current_binding.asm" "jsr zeropage_module_unload_current"
check_contains "$OUT_DIR/64_module_typed_current_binding.asm" "jsr zeropage_module_registry_jump_table+0"
check_contains "$OUT_DIR/64_module_typed_current_binding.cli.prg.zpmap.json" '"owner": "runtime"'
check_contains "$OUT_DIR/65_module_state_metadata.asm" "; zeropage_section_begin owner=function:tick"
check_contains "$OUT_DIR/65_module_state_metadata.cli.prg.zpmod.json" '"state"'
check_contains "$OUT_DIR/65_module_state_metadata.cli.prg.zpmod.json" '"snapshot_reu_addr": 198656'
check_contains "$OUT_DIR/65_module_state_metadata.cli.prg.zpmod.json" '"offset": 256, "size": 2'
check_contains "$OUT_DIR/66_module_state_runtime.asm" "zeropage_module_state_save_current:"
check_contains "$OUT_DIR/66_module_state_runtime.asm" "zeropage_module_state_restore_current:"
check_contains "$OUT_DIR/66_module_state_runtime.asm" "zeropage_module_state_current_saved:"
check_contains "$OUT_DIR/66_module_state_runtime.asm" "; zeropage_section_begin owner=runtime kind=data"
check_contains "$OUT_DIR/66_module_state_runtime.cli.prg.zpmod.json" '"state"'
check_contains "$OUT_DIR/66_module_state_runtime.cli.prg.zpmod.json" '"snapshot_reu_addr": 198656'
check_contains "$OUT_DIR/67_module_dependency_state_metadata.asm" "; zeropage_section_begin owner=function:tick"
check_contains "$OUT_DIR/67_module_dependency_state_metadata.cli.prg.zpmod.json" '"deps"'
check_contains "$OUT_DIR/67_module_dependency_state_metadata.cli.prg.zpmod.json" '"id": "math_core"'
check_contains "$OUT_DIR/67_module_dependency_state_metadata.cli.prg.zpmod.json" '"snapshot_reu_addr": 204800'
check_contains "$OUT_DIR/67_module_dependency_state_metadata.cli.prg.zpmod.json" '"id": "pathing"'
check_contains "$OUT_DIR/67_module_dependency_state_metadata.cli.prg.zpmod.json" '"snapshot_reu_addr": 206848'
check_contains "$OUT_DIR/68_module_dependency_state_runtime.asm" "zeropage_module_state_save_active_dependency:"
check_contains "$OUT_DIR/68_module_dependency_state_runtime.asm" "zeropage_module_state_restore_dependency_row1:"
check_contains "$OUT_DIR/68_module_dependency_state_runtime.asm" "zeropage_module_state_restore_dependency_row2:"
check_contains "$OUT_DIR/68_module_dependency_state_runtime.asm" "zeropage_module_state_dep1_saved:"
check_contains "$OUT_DIR/68_module_dependency_state_runtime.asm" "zeropage_module_state_dep2_saved:"
check_contains "$OUT_DIR/68_module_dependency_state_runtime.asm" "; zeropage_section_begin owner=runtime kind=data"
check_contains "$OUT_DIR/69_module_dependency_preload_policy.asm" "zeropage_module_dependency_preload_start:"
check_contains "$OUT_DIR/69_module_dependency_preload_policy.asm" "jsr zeropage_module_load_dependency_row1"
check_contains "$OUT_DIR/69_module_dependency_preload_policy.asm" "zeropage_module_dependency_row1_filename:"
check_contains "$OUT_DIR/69_module_dependency_preload_policy.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/70_module_dependency_on_demand_policy.asm" "lda zeropage_module_registry_row1_loaded"
check_contains "$OUT_DIR/70_module_dependency_on_demand_policy.asm" "jsr zeropage_module_load_dependency_row1"
check_contains "$OUT_DIR/70_module_dependency_on_demand_policy.asm" "jsr zeropage_module_activate_dependency_row1"
check_contains "$OUT_DIR/70_module_dependency_on_demand_policy.asm" "zeropage_module_dependency_row1_filename:"
check_contains "$OUT_DIR/70_module_dependency_on_demand_policy.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/71_module_dependency_refcount.asm" "inc zeropage_module_registry_row1_refcount"
check_contains "$OUT_DIR/71_module_dependency_refcount.asm" "dec zeropage_module_registry_row1_refcount"
check_contains "$OUT_DIR/71_module_dependency_refcount.asm" 'cmp #$ff'
check_contains "$OUT_DIR/71_module_dependency_refcount.asm" "zeropage_module_unload_dependency_row1_final_release:"
check_contains "$OUT_DIR/71_module_dependency_refcount.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/72_module_dependency_graph_metadata.cli.prg.zpmod.json" '"dependency_graph"'
check_contains "$OUT_DIR/72_module_dependency_graph_metadata.cli.prg.zpmod.json" '"row": 3, "id": "fixed_math", "role": "transitive"'
check_contains "$OUT_DIR/72_module_dependency_graph_metadata.cli.prg.zpmod.diskmanifest.json" '"ordinal": 3, "id": "fixed_math", "role": "transitive"'
check_contains "$OUT_DIR/73_module_dependency_graph_load.asm" "jsr zeropage_module_load_dependency_row3"
check_contains "$OUT_DIR/73_module_dependency_graph_load.asm" "jsr zeropage_module_load_dependency_row1"
check_contains "$OUT_DIR/73_module_dependency_graph_load.asm" "jsr zeropage_module_unload_dependency_row3"
check_contains "$OUT_DIR/73_module_dependency_graph_load.asm" 'zeropage_module_registry_row3_reu_cache = $031800'
check_contains "$OUT_DIR/73_module_dependency_graph_load.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/74_module_dependency_graph_on_demand_policy.asm" "lda zeropage_module_registry_row1_loaded"
check_contains "$OUT_DIR/74_module_dependency_graph_on_demand_policy.asm" "jsr zeropage_module_load_dependency_row3"
check_contains "$OUT_DIR/74_module_dependency_graph_on_demand_policy.asm" "jsr zeropage_module_load_dependency_row1"
check_contains "$OUT_DIR/74_module_dependency_graph_on_demand_policy.asm" "jsr zeropage_module_activate_dependency_row1"
check_contains "$OUT_DIR/74_module_dependency_graph_on_demand_policy.cli.prg.zpmod.json" '"graph": true'
check_contains "$OUT_DIR/74_module_dependency_graph_on_demand_policy.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/75_module_dependency_graph_preload_policy.asm" "zeropage_module_dependency_preload_start:"
check_contains "$OUT_DIR/75_module_dependency_graph_preload_policy.asm" "jsr zeropage_module_load_dependency_row3"
check_contains "$OUT_DIR/75_module_dependency_graph_preload_policy.asm" "jsr zeropage_module_load_dependency_row1"
check_contains "$OUT_DIR/75_module_dependency_graph_preload_policy.asm" "jsr zeropage_module_activate_dependency_row1"
check_contains "$OUT_DIR/75_module_dependency_graph_preload_policy.cli.prg.zpmod.json" '"graph": true'
check_contains "$OUT_DIR/75_module_dependency_graph_preload_policy.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/76_module_typed_dependency_graph_lifecycle.asm" "jsr zeropage_module_load_dependency_row3"
check_contains "$OUT_DIR/76_module_typed_dependency_graph_lifecycle.asm" "jsr zeropage_module_load_dependency_row1"
check_contains "$OUT_DIR/76_module_typed_dependency_graph_lifecycle.asm" "jsr zeropage_module_activate_dependency_row1"
check_contains "$OUT_DIR/76_module_typed_dependency_graph_lifecycle.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/77_module_dependency_graph_acquire.asm" "jsr zeropage_module_acquire_dependency_row3"
check_contains "$OUT_DIR/77_module_dependency_graph_acquire.asm" "jsr zeropage_module_acquire_dependency_row1"
check_contains "$OUT_DIR/77_module_dependency_graph_acquire.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/78_module_dependency_graph_release.asm" "jsr zeropage_module_unload_dependency_row1"
check_contains "$OUT_DIR/78_module_dependency_graph_release.asm" "jsr zeropage_module_unload_dependency_row3"
check_contains "$OUT_DIR/78_module_dependency_graph_release.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/79_module_typed_dependency_graph_ownership.asm" "jsr zeropage_module_acquire_dependency_row3"
check_contains "$OUT_DIR/79_module_typed_dependency_graph_ownership.asm" "jsr zeropage_module_acquire_dependency_row1"
check_contains "$OUT_DIR/79_module_typed_dependency_graph_ownership.asm" "jsr zeropage_module_unload_dependency_row1"
check_contains "$OUT_DIR/79_module_typed_dependency_graph_ownership.asm" "jsr zeropage_module_unload_dependency_row3"
check_contains "$OUT_DIR/79_module_typed_dependency_graph_ownership.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/80_module_graph_node_sidecars.asm" "tick:"
check_contains "$OUT_DIR/80_module_graph_node_sidecars.asm" "owner=function:tick"
check_contains "$OUT_DIR/80_module_graph_node_sidecars.cli.prg.zpmod.json" '"module_id": "enemy_graph_sidecars"'
check_contains "$OUT_DIR/80_module_graph_node_sidecars.cli.prg.zpmod.json" '"id": "fixed_math"'
check_contains "$OUT_DIR/81_module_graph_node_call.asm" "jsr zeropage_module_activate_dependency_row3"
check_contains "$OUT_DIR/81_module_graph_node_call.asm" "zeropage_module_activate_dependency_row3:"
check_contains "$OUT_DIR/81_module_graph_node_call.asm" "jsr zeropage_module_registry_jump_table+0"
check_contains "$OUT_DIR/81_module_graph_node_call.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/82_module_typed_graph_node_binding.asm" "jsr zeropage_module_acquire_dependency_row3"
check_contains "$OUT_DIR/82_module_typed_graph_node_binding.asm" "jsr zeropage_module_activate_dependency_row3"
check_contains "$OUT_DIR/82_module_typed_graph_node_binding.asm" "jsr zeropage_module_registry_jump_table+0"
check_contains "$OUT_DIR/82_module_typed_graph_node_binding.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/86_module_basic_bank_metadata.cli.prg.zpmod.json" '"name": "basic", "addr": 40960, "size": 2048, "alignment": 256, "bank": "ram_under_basic"'
check_contains "$OUT_DIR/86_module_basic_bank_metadata.cli.prg.zpmod.json" '"id": "math_core", "window": "basic", "row": 1'
check_contains "$OUT_DIR/87_module_current_basic_bank.asm" "zeropage_module_bank_saved_port"
check_contains "$OUT_DIR/87_module_current_basic_bank.asm" 'and #$fe'
check_contains "$OUT_DIR/87_module_current_basic_bank.asm" 'jsr $a000'
check_contains "$OUT_DIR/87_module_current_basic_bank.cli.prg.zpmod.json" '"name": "main", "addr": 40960, "size": 2048, "alignment": 256, "bank": "ram_under_basic"'
check_contains "$OUT_DIR/90_module_current_kernal_bank.asm" "zeropage_module_bank_saved_port"
check_contains "$OUT_DIR/90_module_current_kernal_bank.asm" 'php'
check_contains "$OUT_DIR/90_module_current_kernal_bank.asm" 'sei'
check_contains "$OUT_DIR/90_module_current_kernal_bank.asm" 'and #$fd'
check_contains "$OUT_DIR/90_module_current_kernal_bank.asm" 'plp'
check_contains "$OUT_DIR/90_module_current_kernal_bank.asm" 'jsr $e000'
check_contains "$OUT_DIR/90_module_current_kernal_bank.cli.prg.zpmod.json" '"name": "main", "addr": 57344, "size": 2048, "alignment": 256, "bank": "ram_under_kernal"'
check_contains "$OUT_DIR/88_module_typed_basic_bank_window.asm" "zeropage_module_registry_active_row_basic:"
check_contains "$OUT_DIR/88_module_typed_basic_bank_window.asm" "zeropage_module_bank_saved_port"
check_contains "$OUT_DIR/88_module_typed_basic_bank_window.asm" 'and #$fe'
check_contains "$OUT_DIR/88_module_typed_basic_bank_window.asm" 'jsr zeropage_module_state_save_active_dependency_basic'
check_contains "$OUT_DIR/88_module_typed_basic_bank_window.asm" 'jsr $a000'
check_contains "$OUT_DIR/88_module_typed_basic_bank_window.asm" 'sta $a001'
check_contains "$OUT_DIR/88_module_typed_basic_bank_window.cli.prg.zpmod.json" '"name": "basic", "addr": 40960, "size": 2048, "alignment": 256, "bank": "ram_under_basic"'
check_contains "$OUT_DIR/91_module_typed_kernal_bank_window.asm" "zeropage_module_registry_active_row_kernal:"
check_contains "$OUT_DIR/91_module_typed_kernal_bank_window.asm" "zeropage_module_bank_saved_port"
check_contains "$OUT_DIR/91_module_typed_kernal_bank_window.asm" 'php'
check_contains "$OUT_DIR/91_module_typed_kernal_bank_window.asm" 'sei'
check_contains "$OUT_DIR/91_module_typed_kernal_bank_window.asm" 'and #$fd'
check_contains "$OUT_DIR/91_module_typed_kernal_bank_window.asm" 'plp'
check_contains "$OUT_DIR/91_module_typed_kernal_bank_window.asm" 'jsr zeropage_module_state_save_active_dependency_kernal'
check_contains "$OUT_DIR/91_module_typed_kernal_bank_window.asm" 'jsr $e000'
check_contains "$OUT_DIR/91_module_typed_kernal_bank_window.asm" 'sta $e001'
check_contains "$OUT_DIR/91_module_typed_kernal_bank_window.cli.prg.zpmod.json" '"name": "kernal", "addr": 57344, "size": 2048, "alignment": 256, "bank": "ram_under_kernal"'
check_contains "$OUT_DIR/92_module_kernal_bank_hardening.asm" "zeropage_module_bank_enter_kernal:"
check_contains "$OUT_DIR/92_module_kernal_bank_hardening.asm" "zeropage_module_bank_exit_kernal:"
check_contains "$OUT_DIR/92_module_kernal_bank_hardening.asm" "zeropage_module_bank_saved_status"
check_contains "$OUT_DIR/92_module_kernal_bank_hardening.asm" 'jsr $e000'
check_contains "$OUT_DIR/92_module_kernal_bank_hardening.asm" "; zeropage_section_begin owner=runtime kind=code"
check_contains "$OUT_DIR/92_module_kernal_bank_hardening.asm" "; zeropage_section_begin owner=runtime kind=data"
check_contains "$OUT_DIR/92_module_kernal_bank_hardening.cli.prg.zpmod.json" '"requires_kernal_rom": false'
check_contains "$OUT_DIR/92_module_kernal_bank_hardening.cli.prg.zpmod.json" '"name": "main", "addr": 57344, "size": 2048, "alignment": 256, "bank": "ram_under_kernal"'
check_contains "$OUT_DIR/89_module_kernal_bank_metadata.cli.prg.zpmod.json" '"name": "kernal", "addr": 57344, "size": 4096, "alignment": 256, "bank": "ram_under_kernal"'
check_contains "$OUT_DIR/89_module_kernal_bank_metadata.cli.prg.zpmod.json" '"id": "math_core", "window": "kernal", "row": 1'
check_contains "$OUT_DIR/93_module_kernal_console_trampoline.asm" "zeropage_module_kernal_trampoline_console_put_char:"
check_contains "$OUT_DIR/93_module_kernal_console_trampoline.asm" "zeropage_module_kernal_trampoline_saved_status:"
check_contains "$OUT_DIR/93_module_kernal_console_trampoline.asm" "jsr zeropage_module_kernal_trampoline_console_put_char"
check_contains "$OUT_DIR/93_module_kernal_console_trampoline.cli.prg.zpmod.json" '"requires_kernal_rom": true'
check_contains "$OUT_DIR/93_module_kernal_console_trampoline.cli.prg.zpmod.json" '"kernal_trampoline_safe": true'
check_contains "$OUT_DIR/94_module_dependency_kernal_console_trampoline.asm" "zeropage_module_registry_active_row_kernal:"
check_contains "$OUT_DIR/94_mathcore.prg.zpmod.json" '"requires_kernal_rom": true'
check_contains "$OUT_DIR/94_mathcore.prg.zpmod.json" '"kernal_trampoline_safe": true'

echo "section marker verification passed: $checked fixtures, PRG bytes identical after stripping section comments"
