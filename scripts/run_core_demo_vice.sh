#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLING_DIR="$(cd "$ROOT_DIR/.." && pwd)/zeropage-tooling"

ZIG="${ZEROPAGE_ZIG:-$TOOLING_DIR/bin/zig}"
X64SC="${ZEROPAGE_VICE_X64SC:-$TOOLING_DIR/bin/x64sc}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: scripts/run_core_demo_vice.sh [--build-only]"
  exit 0
fi

BUILD_ONLY=0
if [[ "${1:-}" == "--build-only" ]]; then
  BUILD_ONLY=1
fi

cd "$ROOT_DIR"
"$ZIG" build run -- compile examples/core_demo.zp64 -o build/core_demo.prg

if [[ "$BUILD_ONLY" == "1" ]]; then
  echo "Built $ROOT_DIR/build/core_demo.prg"
  exit 0
fi

exec "$X64SC" -autostart "$ROOT_DIR/build/core_demo.prg"
