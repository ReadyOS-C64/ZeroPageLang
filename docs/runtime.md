# Runtime

ZeroPage has no separately distributed target runtime. `zp64c` emits the startup code, data, and helper routines required by each program into its generated assembly.

## Startup

A normal PRG starts at `$0801` with a BASIC line that runs `SYS 2061`. Generated code begins at `$080D`, initializes configured software-stack or preload state, calls `main`, and returns with `RTS`.

The 6502 hardware stack remains available for return addresses and KERNAL compatibility. Functions declared with `callconv(.stack)` use a separate software stack in C64 RAM.

## Emission model

Helpers are emitted only when referenced. A border-only program does not carry console, heap, REU, or module code. Current helper families include:

- screen, console, string, keyboard, and timing support;
- 16-bit multiply and shift helpers;
- software-stack bridges and overflow trapping;
- near-heap allocation and fixed-block free lists;
- REU transfers, far heaps, typed views, and materialization;
- module loading, relocation, registry, state, banking, and ordinal dispatch;
- test hooks used by the Peddle host runner.

Compiler scratch and runtime state are emitted in named sections. `zp64c compile` records their final addresses in `.zpmap.json`.

The internal unsigned 16-bit multiplication helper consumes its private operand
slots and returns the low 16 product bits in A/X. It shifts the multiplier before
each addition, using the shifted-out carry bit as the selector. Y and the hardware
stack pointer remain unchanged; status flags are scratch, not a helper result.
The compiler clears carry explicitly before the low-byte addition. Conditional
padding keeps its 36-byte loop and branch-after-PC within a page.

## Failure behavior

Operations that can fail return `bool`, an optional pointer or handle, or an optional module result. Checked software-stack overflow enters a generated `BRK` trap. Unsupported source constructs and invalid memory plans fail at compile time rather than falling back to undefined runtime behavior.

Runtime code does not parse JSON or binary module metadata. Sidecars are compiler and packaging inputs; target code receives fixed rows, addresses, ordinals, and relocation bytes.

## Host verification

The Peddle runner loads generated PRGs and models the KERNAL calls and REU registers needed by fixtures. VICE tests provide the real C64 integration layer. See [Testing](testing.md).
