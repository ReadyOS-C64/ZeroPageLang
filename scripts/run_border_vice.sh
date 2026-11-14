#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLING_DIR="$(cd "$ROOT_DIR/.." && pwd)/zeropage-tooling"

ZIG="${ZEROPAGE_ZIG:-$TOOLING_DIR/bin/zig}"
TASS64="${ZEROPAGE_64TASS:-$TOOLING_DIR/bin/64tass}"
X64SC="${ZEROPAGE_VICE_X64SC:-$TOOLING_DIR/bin/x64sc}"

BUILD_ONLY=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/run_border_vice.sh [--build-only] [source.zp64] [out.prg]

Builds the ZeroPage border sample and launches it in interactive VICE x64sc.

Environment overrides:
  ZEROPAGE_ZIG=/path/to/zig
  ZEROPAGE_64TASS=/path/to/64tass
  ZEROPAGE_VICE_X64SC=/path/to/x64sc
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--build-only" ]]; then
  BUILD_ONLY=1
  shift
fi

SRC="${1:-$ROOT_DIR/examples/border.zp64}"
OUT="${2:-$ROOT_DIR/build/border.prg}"

if [[ ! -x "$ZIG" ]]; then
  echo "zig not found or not executable: $ZIG" >&2
  exit 1
fi

if [[ ! -x "$TASS64" ]]; then
  echo "64tass not found or not executable: $TASS64" >&2
  exit 1
fi

if [[ ! -x "$X64SC" ]]; then
  echo "x64sc not found or not executable: $X64SC" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

export ZEROPAGE_ZIG="$ZIG"
export ZEROPAGE_64TASS="$TASS64"
export ZEROPAGE_VICE_X64SC="$X64SC"

cd "$ROOT_DIR"
"$ZIG" build run -- compile "$SRC" -o "$OUT"

if [[ "$BUILD_ONLY" == "1" ]]; then
  echo "Built $OUT"
  exit 0
fi

echo "Launching interactive VICE with $OUT"
exec "$X64SC" -autostart "$OUT"
