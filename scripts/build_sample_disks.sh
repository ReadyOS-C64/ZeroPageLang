#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

assembler=./zig-out/bin/zp64c
c1541="${ZEROPAGE_C1541:-}"
if [[ -z "$c1541" ]]; then
  c1541=../zeropage-tooling/bin/c1541
  if [[ ! -x "$c1541" ]]; then
    c1541="$(command -v c1541 || true)"
  fi
fi
if [[ ! -x "$assembler" || ! -x "$c1541" ]]; then
  echo "Build zp64c with zig build and install VICE's c1541 first." >&2
  exit 1
fi

out=build/sample-disks
mkdir -p "$out"
"$assembler" compile examples/hello.zp64 -o "$out/hello.prg"
"$assembler" compile examples/small/95_memory_regions_placement.zp64 -o "$out/memory.prg"
"$assembler" compile examples/small/51_module_disk_load_real.zp64 -o "$out/boot.prg"
"$assembler" compile examples/small/96_memory_regions_dll.zp64 -o "$out/memory-dll.prg"
"$assembler" compile sampleapps/tictactoe/tictactoe_idiomatic.zp64 -o "$out/tictactoe.prg"
"$assembler" compile sampleapps/tictactoe/tictactoe.zp64 -o "$out/classic.prg"

rm -f "$out/demos.d64" "$out/tictactoe.d64" "$out/reu.d64"
"$c1541" -format 'zeropage demos,01' d64 "$out/demos.d64" \
  -write "$out/hello.prg" hello -write "$out/memory.prg" memory
"$c1541" -format 'tic tac toe,02' d64 "$out/tictactoe.d64" \
  -write "$out/tictactoe.prg" tictactoe -write "$out/classic.prg" classic
"$c1541" -format 'zeropage reu,03' d64 "$out/reu.d64" \
  -write "$out/boot.prg" boot -write "$out/boot.prg.zpmod.disk.prg" enemyrt \
  -write "$out/memory-dll.prg" memory-dll
cp "$out/demos.d64" examples/zeropage-demos.d64
cp "$out/tictactoe.d64" sampleapps/tictactoe/tictactoe.d64
cp "$out/reu.d64" examples/zeropage-reu.d64
