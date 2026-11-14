#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VICE_TASKS="${ZEROPAGE_VICE_TASKS:-}"
if [[ -z "$VICE_TASKS" ]]; then
  VICE_TASKS_CANDIDATE="$(cd "$ROOT_DIR/.." && pwd)/agenticdevharness/tools/vice_tasks_dotnet/src/ViceTasks.Binary/ViceTasks.Binary.csproj"
  if [[ -f "$VICE_TASKS_CANDIDATE" ]]; then
    VICE_TASKS="$VICE_TASKS_CANDIDATE"
  fi
fi

if [[ -z "$VICE_TASKS" || ! -f "$VICE_TASKS" ]]; then
  echo "VICE task harness not found; set ZEROPAGE_VICE_TASKS=/path/to/ViceTasks.Binary.csproj" >&2
  exit 1
fi

if [[ -z "${ZEROPAGE_VICE_TASKS:-}" ]]; then
  VICE_TASKS="$(python3 "$ROOT_DIR/scripts/prepare_vice_harness.py" --source "$VICE_TASKS")"
fi
export ZEROPAGE_VICE_TASKS="$VICE_TASKS"

cd "$ROOT_DIR"
if [[ ! -x ./zig-out/bin/zp64c ]]; then
  "${ZEROPAGE_ZIG:-../zeropage-tooling/bin/zig}" build >/dev/null
fi

bash scripts/verify_small_demos.sh --skip-build --vice
bash scripts/verify_sampleapps.sh --skip-build --vice

small_vice_count=95
sampleapp_vice_count=2
total=$((small_vice_count + sampleapp_vice_count))
echo "VICE automation passed: $small_vice_count small-demo plans + $sampleapp_vice_count sample-app plan = $total headless VICE UI plans"
