#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLING_DIR="$(cd "$ROOT_DIR/.." && pwd)/zeropage-tooling"

ZIG="${ZEROPAGE_ZIG:-$TOOLING_DIR/bin/zig}"
TASS64="${ZEROPAGE_64TASS:-$TOOLING_DIR/bin/64tass}"
VICE_BIN="${VICE_BIN:-${ZEROPAGE_VICE_X64SC:-}}"
VICE_CONSOLE="${VICE_CONSOLE:-0}"
VICE_DEBUG="${VICE_DEBUG:-0}"
BUILD_ONLY=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/run_console_scroll_vice.sh [--build-only]

Builds examples/small/09_console_scroll.zp64 and launches it in interactive VICE x64sc.

Environment overrides:
  ZEROPAGE_ZIG=/path/to/zig
  ZEROPAGE_64TASS=/path/to/64tass
  ZEROPAGE_VICE_X64SC=/path/to/x64sc
  VICE_BIN=x64sc|x64|/path/to/vice
  VICE_CONSOLE=1        Add VICE -console for terminal-oriented launches
  VICE_DEBUG=1          Print the exact VICE command before launching
USAGE
}

configure_vice_env() {
  if [[ -z "${GSETTINGS_SCHEMA_DIR:-}" && -f "/opt/homebrew/share/glib-2.0/schemas/gschemas.compiled" ]]; then
    export GSETTINGS_SCHEMA_DIR="/opt/homebrew/share/glib-2.0/schemas"
  fi

  if [[ -d "/opt/homebrew/share" ]]; then
    if [[ -n "${XDG_DATA_DIRS:-}" ]]; then
      case ":$XDG_DATA_DIRS:" in
        *":/opt/homebrew/share:"*) ;;
        *) export XDG_DATA_DIRS="/opt/homebrew/share:$XDG_DATA_DIRS" ;;
      esac
    else
      export XDG_DATA_DIRS="/opt/homebrew/share:/usr/local/share:/usr/share"
    fi
  fi
}

resolve_vice() {
  if [[ -n "$VICE_BIN" ]]; then
    if [[ -x "$VICE_BIN" ]]; then
      printf '%s\n' "$VICE_BIN"
      return
    fi
    if command -v "$VICE_BIN" >/dev/null 2>&1; then
      command -v "$VICE_BIN"
      return
    fi
    echo "Error: VICE_BIN is set to '$VICE_BIN' but it is not executable or on PATH." >&2
    exit 1
  fi

  if [[ -x "$TOOLING_DIR/bin/x64sc" ]]; then
    printf '%s\n' "$TOOLING_DIR/bin/x64sc"
  elif command -v x64sc >/dev/null 2>&1; then
    command -v x64sc
  elif command -v x64 >/dev/null 2>&1; then
    command -v x64
  else
    echo "Error: VICE emulator not found (tried local tooling, x64sc, x64)." >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) BUILD_ONLY=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

configure_vice_env
VICE="$(resolve_vice)"

if [[ ! -x "$ZIG" ]]; then
  echo "zig not found or not executable: $ZIG" >&2
  exit 1
fi

if [[ ! -x "$TASS64" ]]; then
  echo "64tass not found or not executable: $TASS64" >&2
  exit 1
fi

SRC="$ROOT_DIR/examples/small/09_console_scroll.zp64"
OUT="$ROOT_DIR/build/small/09_console_scroll.prg"
mkdir -p "$(dirname "$OUT")" "$ROOT_DIR/logs"

export ZEROPAGE_ZIG="$ZIG"
export ZEROPAGE_64TASS="$TASS64"
export ZEROPAGE_VICE_X64SC="$VICE"

cd "$ROOT_DIR"
"$ZIG" build run -- compile "$SRC" -o "$OUT"

if [[ "$BUILD_ONLY" == "1" ]]; then
  echo "Built $OUT"
  exit 0
fi

CMD=("$VICE" -logfile "$ROOT_DIR/logs/vice_console_scroll.log" -autostartprgmode 1 -autostart "$OUT")
if [[ "$VICE_CONSOLE" == "1" ]]; then
  CMD+=(-console)
fi

if [[ "$VICE_DEBUG" == "1" ]]; then
  printf 'VICE command:' >&2
  printf ' %q' "${CMD[@]}" >&2
  echo >&2
fi

echo "Launching interactive VICE with $OUT"
exec "${CMD[@]}"
