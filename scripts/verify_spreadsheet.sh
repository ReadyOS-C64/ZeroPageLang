#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="${ZEROPAGE_SHEET_OUTPUT:-$ROOT/build/spreadsheet}"
TARGET=both
ARGS=()
if [[ "$#" -gt 1 || ("$#" == 1 && "$1" != "--vice") ]]; then
  echo "Usage: $0 [--vice]" >&2
  exit 2
fi
if [[ -n "${ZEROPAGE_READYOS_MANIFEST:-}" ]]; then
  ARGS+=(--readyos-manifest "$ZEROPAGE_READYOS_MANIFEST")
elif [[ ! -f ../readyosprecog/Releases/0.5/precog-d81/manifest.json ]]; then
  TARGET=standalone
fi
if [[ "${1:-}" == "--vice" ]]; then
  ARGS+=(--test-fixtures)
fi
python3 -B scripts/build_spreadsheet.py --target "$TARGET" --output-dir "$OUT" ${ARGS[@]+"${ARGS[@]}"}

if [[ "${1:-}" != "--vice" ]]; then
  exit 0
fi
VICE_TASKS="${ZEROPAGE_VICE_TASKS:-}"
if [[ -z "$VICE_TASKS" ]]; then
  VICE_TASKS="$(python3 -B scripts/prepare_vice_harness.py)"
fi
DOTNET="${ZEROPAGE_DOTNET:-}"
if [[ -z "$DOTNET" ]]; then
  DOTNET="$(command -v dotnet || true)"
fi
if [[ -z "$DOTNET" ]]; then
  echo "dotnet is required for VICE; set ZEROPAGE_DOTNET or add it to PATH" >&2
  exit 1
fi
"$DOTNET" run --project "$VICE_TASKS" -- run-plan --plan "$OUT/standalone.vice.yaml" --no-tui --close-vice
python3 -B scripts/build_spreadsheet.py --verify-save "$OUT/zeropage-sheet.d64"
if [[ "$TARGET" == both ]]; then
  "$DOTNET" run --project "$VICE_TASKS" -- run-plan --plan "$OUT/readyos.vice.yaml" --no-tui --close-vice
  python3 -B scripts/build_spreadsheet.py --verify-save "$OUT/readyos-zeropage-sheet.d81"
else
  echo "ReadyOS image skipped; set ZEROPAGE_READYOS_MANIFEST to its Precog 0.5 D81 manifest."
fi
