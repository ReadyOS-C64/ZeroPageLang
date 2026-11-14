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
      echo "Usage: scripts/verify_sampleapps.sh [--skip-build] [--vice]"
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

SAMPLE_APPS=(
  "sampleapps/tictactoe/tictactoe.zp64"
  "sampleapps/tictactoe/tictactoe_idiomatic.zp64"
)

cd "$ROOT_DIR"
if [[ "$SKIP_BUILD" == "0" ]]; then
  "$ZIG" build
fi

mkdir -p build/sampleapps
for app in "${SAMPLE_APPS[@]}"; do
  name="$(basename "$app" .zp64)"
  prg="build/sampleapps/$name.prg"
  ./zig-out/bin/zp64c compile "$app" -o "$prg"
done

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

  for app in "${SAMPLE_APPS[@]}"; do
    name="$(basename "$app" .zp64)"
    prg="build/sampleapps/$name.prg"
    plan="build/sampleapps/$name.vice.yaml"
    ./zig-out/bin/zp64c run-vice "$prg" -o "$plan"
    run_vice_plan "$plan"
  done
fi

echo "verified ${#SAMPLE_APPS[@]} sample app(s)"
