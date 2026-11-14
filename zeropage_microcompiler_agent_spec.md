# ZeroPage Microcompiler — Autonomous Agent Implementation Specification

Version: 0.1 draft  
Target machine: Commodore 64 / 6510, NMOS 6502 instruction subset by default  
Host implementation language: Zig  
Primary output path: ZeroPage source -> generated 64tass assembly -> CBM `.prg`
Secondary output path: generated Kick Assembler assembly -> `.prg`  
Primary verification: Zig unit tests, host-side 6502/6510 emulator, assembler round-trips, VICE binary monitor integration

Status note, August 2026: this is the north-star architecture and roadmap, not the exact implementation ledger. Start with the [documentation index](docs/README.md) for current behavior. The language, API, ABI, memory, module, and testing references define the implemented contracts; `AgentWorking/` records design history and future plans.

Development uses the pinned tools described in [Dependencies](docs/dependencies.md). VICE automation is external and configured with `ZEROPAGE_VICE_TASKS`; no developer-specific path is part of the project contract.

---

## 1. Mission

Build a small Zig-flavored cross-compiler, hereafter `zp64c`, that runs on macOS using normal host Zig and produces tight Commodore 64 programs. It is not a full Zig port and not binary/source compatible with the full Zig compiler. It should preserve the parts of Zig that are valuable for C64 work: explicit integer widths, simple structs, arrays, pointers, memory-mapped I/O, explicit allocation, compile-time constants, and explicit feature selection.

The compiler must be implementable autonomously by an AI coding agent. Every stage must have unit tests and every emitted 6502/6510 program must be verifiable on the host before optional VICE execution.

---

## 2. Hard constraints

1. The compiler itself is written in Zig.
2. The compiler runs on macOS as the primary host.
3. Generated C64 code must be small by default.
4. The full Zig standard library is not available on the C64 target.
5. The target source language is `ZeroPage`, a deliberately restricted Zig-like subset.
6. The initial backend emits assembler, not raw machine code.
7. `64tass` is the primary assembler backend.
8. Kick Assembler is supported later through a dialect layer.
9. VICE integration is optional for local developer machines but must be implemented as an integration-test path.
10. The host-side 6502/6510 emulator is mandatory so the core test suite can run without launching VICE.
11. The compiler must link only the target runtime functions actually used by the program.
12. No target-side GC, threads, async, goroutines, reflection, full package manager, or full Zig generics.
13. REU support must be designed in from the start, but only simple copy/swap operations are required for the first REU milestone.
14. Overlay/banked libraries must be represented in metadata from the beginning, even if automatic overlaying is future work.

---

## 3. External reference facts

Use the current Zig compiler source as a reference for style, diagnostics, token naming, parser architecture, and build system habits. Do not initially fork the real Zig compiler. The public Zig repository has moved to Codeberg; the old GitHub page reports the move and indicates the source tree is overwhelmingly Zig by language percentage. Zig's own overview describes Zig as self-hosted and discusses building the compiler from source. The project should pin a Zig release and not chase Zig master automatically.

Zig's standard library has cross-platform abstractions that require per-platform implementations. `zp64c` must not try to port `std` wholesale to C64. Instead it will provide a tiny C64-native micro-library.

VICE has a built-in monitor and a binary remote monitor. The binary monitor can read/write memory, set checkpoints, feed keyboard data, autostart programs, dump/restore state, and query registers. The integration harness must use the binary monitor rather than parsing interactive GUI output.

64tass is a command-line assembler and can output CBM PRG files with the first two bytes containing the load address. It also supports target CPU selection and labels usable by VICE. Kick Assembler has command-line output options, library paths, memory map output, emulator execution, VICE symbols, and binary-vs-PRG output modes.

The C64 memory map has screen memory at `$0400-$07FF` in the normal startup configuration and color RAM at `$D800-$DBFF`. The 6510 processor port at `$0001` controls visibility of BASIC ROM, KERNAL ROM, character ROM, and I/O. KERNAL routines include `CHROUT` at `$FFD2` and `GETIN` at `$FFE4`. REU memory is not directly executable by the CPU; code/data must be copied or swapped into normal C64 addressable memory.

---

## 4. Project name and command names

The project and language are ZeroPage. The compiler is `zp64c`, the Zig package is `.zeropage`, and source files use `.zp64`. The target runtime API is available through `@import("ZeroPage")`.

CLI command plan. See the [CLI reference](docs/cli.md) for implemented commands:

```text
zp64c compile input.zp64 -o out.prg
zp64c asm input.zp64 -o out.asm
zp64c test tests/fixtures/foo.zp64
zp64c run-vice input.prg -o plan.vice.yaml
zp64c size input.zp64
zp64c explain feature-name
```

Build commands:

```text
zig build
zig build test
zig build e2e
zig build asm-test
zig build vice-test
zig build size-report
```

Environment variables:

```text
ZEROPAGE_64TASS=/path/to/64tass
ZEROPAGE_KICKASS_JAR=/path/to/KickAss.jar
ZEROPAGE_VICE_X64SC=/path/to/x64sc
ZEROPAGE_VICE_MONITOR_ADDR=127.0.0.1:6502
```

---

## 5. Repository layout

```text
zp64c/
  build.zig
  build.zig.zon
  README.md
  docs/
    language.md
    memory-model.md
    abi.md
    runtime.md
    reu-overlays.md
    testing.md
    zig-reference-notes.md
  src/
    main.zig
    cli.zig
    diag.zig
    source.zig
    lexer.zig
    parser.zig
    ast.zig
    sema.zig
    types.zig
    comptime_eval.zig
    ir.zig
    lower.zig
    codegen/
      asm.zig
      tass64.zig
      kick.zig
      m6502.zig
      peephole.zig
    target/
      c64.zig
      memory_map.zig
      abi.zig
      features.zig
    runtime_linker.zig
    prg.zig
    mapfile.zig
    vice/
      binary_monitor.zig
      runner.zig
    cpu6502/
      cpu.zig
      memory.zig
      disasm.zig
      trace.zig
  runtime/
    c64/
      startup.asm64
      kernal_io.asm64
      direct_screen.asm64
      input.asm64
      mem.asm64
      math8.asm64
      math16.asm64
      alloc_arena.asm64
      alloc_fixed.asm64
      reu.asm64
      debug_ring.asm64
      panic.asm64
  examples/
    hello.zp64
    input_name.zp64
    border.zp64
    reu_copy.zp64
  tests/
    unit/
    fixtures/
      pass/
      fail/
      codegen/
      vice/
      reu/
    golden/
    runtime/
```

---

## 6. Language: ZeroPage v0 subset

### 6.1 File extension

Use `.zp64` for target source files. This prevents users from assuming full Zig compatibility and avoids the existing `.zp` language-extension collision.

### 6.2 Included syntax

Required in v0:

```zig
const c64 = @import("c64");

const Player = struct {
    x: u8,
    y: u8,
    color: u8,
};

var player = Player{ .x = 10, .y = 12, .color = 1 };

export fn main() void {
    c64.screen.clear();
    c64.screen.puts("READY");
}
```

Supported declarations:

```text
const name = constant_expr;
var name: Type = initializer;
const Name = struct { ... };
fn name(args...) ReturnType { ... }
export fn main() void { ... }
```

Supported control flow:

```text
if / else
while
while with simple increment expression
break
continue
return
```

Supported expressions:

```text
integer literals
character literals
string literals
boolean literals
binary arithmetic: + - & | ^ << >>
comparison: == != < <= > >=
logical: and or not
assignment: = += -= &= |= ^=
field access: x.y
array indexing: a[i]
address-of: &x
pointer dereference: p.*
function call: f(a, b)
casts: @intCast(T, x), @as(T, x)
address conversion: @ptrFromInt(T, addr), @intFromPtr(ptr)
```

### 6.3 Types

Required in v0:

```text
void
bool
u8, i8
u16, i16
usize = u16
isize = i16
[N]T fixed arrays
*T single pointer
*volatile T pointer or volatile memory object
struct with fixed fields
```

Optional later:

```text
u24/u32/i32, only if feature math32 is enabled
enum with explicit integer tag
packed struct
slice: []T as ptr+len, feature gated
error sets and error unions, feature gated
```

Excluded in v0:

```text
float
anytype
interfaces/traits
full generics
union
async/await
threads
reflection/typeinfo except minimal @sizeOf and @offsetOf
full Zig error semantics
full Zig defer/errdefer
full Zig comptime execution
full Zig stdlib
```

---

## 7. Comptime model

ZeroPage has compile-time evaluation because the compiler runs on the host, but it is deliberately narrower than real Zig.

### Included in v0

```text
constant integer arithmetic
constant boolean expressions
array lengths
struct field offsets
@sizeOf(T)
@offsetOf(T, "field")
@alignOf(T), initially always 1 unless target config says otherwise
@import("c64") built-in module
@import("file.zp64") local module import
@embedFile("path") as compile-time bytes
@addr(0xD020) or @ptrFromInt for memory-mapped registers
@zeropage annotation
@bank / @overlay annotations as metadata
```

### Excluded in v0

```text
comptime parameters of type `type`
generic functions
arbitrary compile-time loops over types
compile-time reflection over declarations
compile-time execution of target functions
```

### Rule

Any expression marked as compile-time must fully disappear from target code. If a compile-time value would require target runtime behavior, the compiler emits an error.

---

## 8. Imports and target micro-library

### 8.1 Imports

Allowed:

```zig
const c64 = @import("c64");
const math = @import("math16");
const local = @import("localfile.zp64");
```

Disallowed:

```zig
const std = @import("std");
```

`@import("std")` must emit:

```text
error: full Zig standard library is not available for target c64-6510; use @import("c64") or @import("ZeroPage")
```

### 8.2 Micro-library modules

Minimum built-in target modules:

```text
c64.vic
c64.sid
c64.cia
c64.kernal
c64.screen
c64.keyboard
c64.input
c64.mem
c64.debug
c64.reu
c64.overlay
ZeroPage.alloc
ZeroPage.math8
ZeroPage.math16 optional
ZeroPage.str optional minimal helpers
```

The micro-library is not linked whole. Each function is a separate linkable unit where practical.

---

## 9. C64 memory model

### 9.1 Profiles

#### `prg_kernal` default profile

Use a normal `.prg` that can be loaded from BASIC. Include a BASIC SYS stub unless `--no-basic-stub` is passed.

Default layout:

```text
$0801-$080C  BASIC SYS stub, optional
$080D-...    code
...          rodata
...          data initializers
...          bss
...          optional heap
$C000-$CFFF  preferred debug/test scratch area unless program config reserves it
$D000-$DFFF  I/O visible by default; RAM under I/O usable only in raw/banked modes
$E000-$FFFF  KERNAL visible by default
```

#### `raw_ram` profile

No BASIC stub. No KERNAL assumptions. Program controls `$0001` and may use RAM under ROM. KERNAL I/O routines are not available unless ROM is switched in before calling them.

#### `readyos_overlay` future profile

Reserve a resident runtime and one or more overlay windows. Overlay code/data can be copied or swapped from REU into C64 RAM windows.

### 9.2 Zero page policy

Default reserved zero-page slots:

```text
$FB-$FC  ptr0
$FD-$FE  ptr1
```

Expanded zero-page allocation is selected by source artifacts in the main
application, alongside memory arenas/regions, not compiler flags:

```zig
pub const zeropage_options = .{
    .zero_page = .{
        .profile = .kernal,
        .allocation = .scratch,
        .ranges = .{ .{ .addr = 0x02, .size = 0x18 }, .{ .addr = 0xfb, .size = 4 } },
        .reserve = .{},
        .restore_basic = true,
        .interrupts = .system,
    },
};
```

Omission preserves the compatibility layout. BASIC, KERNAL and bare ownership
profiles provide documented ceilings; explicit ranges replace candidates and
reservations subtract application claims. Never allocate $00/$01 or $FF, overlap
fixed pointers, or infer safety merely because ROM is banked out. KERNAL-mode
borrowing snapshots actual BASIC claims before startup and restores on normal
return; asynchronous STOP/RESTORE/reset is a separately documented boundary.
Bare ownership requires application IRQ/NMI control and rejects generated ROM
services. Public module/DLL interfaces and unsupported relocation paths remain
protected. Stage deterministic scratch allocation before private scalar placement
and lifetime overlays. The detailed requirements and current implementation
status live in `AgentWorking/ZERO_PAGE_OPTIMIZATION_REQUIREMENTS.md` and the next
feature plan. This section replaces the historical `--zp-range` proposal.

The current scalar-placement track extends typed private parameters toward
independent non-escaping locals/captures/counters, then an explicit main-entry
local tier. Use actual emitter types, retained-owner knowledge and canonical
whole-image alias proof; never infer local ownership from data-label spelling.
Keep full cell widths, source operations, fixed reservations, public ABI and
normal-return lifecycle. Structured local map provenance must be independently
replayed. This is a design track, not a claim that local placement is enabled;
see `AgentWorking/ZERO_PAGE_LOCALS_IMPLEMENTATION_PLAN.md` for testable slices
and measured-before cost projections. Default/off/scratch modes stay unchanged.

### 9.3 Stack policy

Default v0 policy is stack-minimal:

```text
hardware stack $0100-$01FF: return addresses and KERNAL compatibility only
function locals: statically allocated frame slots when recursion is disabled
parameters: A/X/Y or fixed param slots depending ABI choice
software stack: only when --feature stack or recursive functions are enabled
```

Recursion is rejected unless explicitly enabled:

```zig
recursive fn walk(n: u8) void { ... }
```

If recursion is enabled, the function uses the software stack ABI and emits larger/slower code.

---

## 10. ABI and calling conventions

### 10.1 Default ABI: `c64_static`

Optimized for small, non-recursive C64 programs.

```text
return u8/bool: A
return u16/pointer: A=low, X=high
return struct: caller-provided return slot
first u8 arg: A when possible
second u8 arg: X when possible
first u16/pointer arg: A=low, X=high when possible
additional args: compiler-generated fixed parameter slots
locals: compiler-generated fixed frame slots
A/X/Y are caller-clobbered unless function is marked preserving
```

This ABI is not reentrant by default. It is suitable for ordinary application code, small tools, and tight generated output.

### 10.2 Optional ABI: `c64_stack`

Required for recursion and reentrant callbacks.

```text
software stack pointer in zero page
args pushed right-to-left or compiler-chosen internal order
locals allocated from software stack
A/X return as above
larger code size and slower runtime
```

### 10.3 Interrupt ABI: future

```zig
@interrupt fn raster_irq() void { ... }
```

Not required in v0. When implemented, it must save and restore A/X/Y/status and acknowledge VIC/CIA interrupts according to the selected interrupt source.

---

## 11. Code generation and tightness rules

1. Emit legal NMOS 6502/6510 opcodes by default.
2. Illegal opcodes are forbidden unless `--feature illegal-opcodes` is explicitly set.
3. Prefer immediate, zero-page, and absolute addressing over generic helper calls.
4. Do not emit stack frames for leaf/simple functions unless required.
5. Do not link panic strings in release-small mode.
6. Do not link 16-bit multiply/divide unless used and feature-enabled.
7. Fold constants aggressively before codegen.
8. Use `BIT`, branch, and zero-page idioms only when smaller or faster and covered by emulator tests.
9. Track code size per function and emit a size report with `zp64c size`.
10. Use a peephole pass over generated assembly/instruction IR.

Peephole examples:

```text
lda #0; cmp #0 -> lda #0 with known zero flag if safe
sta tmp; lda tmp -> remove if no clobber
clc; adc #0 -> remove if carry known clear and flags not needed
lda #imm; tax; txa -> lda #imm; tax, if A remains imm
```

---

## 12. Feature profiles and estimated runtime budgets

These are engineering budgets, not promises. The test suite should track actual sizes.

| Feature profile | Meaning | Target overhead |
|---|---|---:|
| `bare` | no I/O, no heap, no checks | 0-64 bytes beyond app code |
| `basic_stub` | BASIC SYS loader line | 10-32 bytes |
| `kernal_io` | CHROUT/GETIN wrappers, puts, waitKey | 100-600 bytes |
| `readline` | fixed-buffer line input with delete/return handling | +150-500 bytes |
| `direct_screen` | clear, putAt, puts to screen RAM | 150-900 bytes |
| `debug_ring` | memory log and test status | 64-512 bytes plus ring buffer |
| `panic_tiny` | set border / write code / loop | 8-64 bytes |
| `panic_text` | print panic code/message | 200-1200 bytes |
| `math16_addsub` | 16-bit add/sub/compare | mostly inline, 0-80 bytes helpers |
| `math16_muldiv` | 16-bit multiply/divide/mod | +200-900 bytes |
| `arena_alloc` | bump allocator | +32-128 bytes |
| `fixed_alloc` | fixed-block allocator | +80-300 bytes |
| `free_list_alloc` | general free-list allocator | +250-900 bytes |
| `reu_basic` | REU copy/swap/verify helpers | +100-400 bytes |
| `overlay_loader` | REU overlay metadata/copy/call | +300-1500 bytes |

Default for examples:

```text
basic_stub + kernal_io + readline + debug_ring in test builds
basic_stub + kernal_io in release examples
```

---

## 13. Target runtime library

### 13.1 Startup

Variants:

```text
startup_basic_stub
startup_raw
startup_test
```

Startup responsibilities:

```text
set load address
optionally include BASIC SYS stub
initialize bss to zero if needed
copy data initializers if needed
initialize debug ring in test builds
call main
on return: either RTS to BASIC, loop, or jump to test exit label
```

### 13.2 KERNAL I/O module

Functions:

```zig
pub fn putChar(ch: u8) void;
pub fn puts(s: []const u8) void;       // optional slice support, else ptr+len internal
pub fn getKey() u8;                    // returns 0 if none
pub fn waitKey() u8;
```

Implementation uses KERNAL routines:

```text
CHROUT $FFD2
GETIN  $FFE4
```

The compiler must preserve registers according to the runtime ABI wrapper, not according to raw KERNAL behavior.

### 13.3 Direct screen module

Functions:

```zig
pub fn clear() void;
pub fn putAt(x: u8, y: u8, ch: u8) void;
pub fn putsAt(x: u8, y: u8, text: []const u8) void;
pub fn setColorAt(x: u8, y: u8, color: u8) void;
```

Default normal-mode addresses:

```text
screen RAM: $0400-$07E7 for 1000 chars
color RAM:  $D800-$DBE7 for 1000 color nibbles
```

### 13.4 Input module

```zig
pub fn readLine(buf: *[N]u8) u8;
pub fn readLineMax(ptr: *u8, max: u8) u8;
```

Rules:

```text
Return length in A.
Never allocate.
Never write past buffer.
Echo printable chars when feature echo is enabled.
Handle RETURN and DELETE.
Use PETSCII semantics, not ASCII, unless explicitly configured.
```

### 13.5 Memory module

```zig
pub fn fill(dst: *u8, value: u8, len: u16) void;
pub fn copy(dst: *u8, src: *const u8, len: u16) void;
pub fn zero(dst: *u8, len: u16) void;
```

`len: u8` variants should be generated when the compiler knows the length fits in one byte.

### 13.6 Allocators

Allocator API must be Zig-like but minimal:

```zig
const arena = ZeroPage.alloc.Arena.init(&heap_buf);
const p = try arena.alloc(u8, 32);
arena.reset();
```

Implementation may lower to runtime calls, but no hidden allocation is permitted.

Arena/bump allocator is v0. Fixed-block allocator is v1. Free-list allocator is optional and must not be linked unless directly imported.

---

## 14. REU support and overlay design

### 14.1 REU facts used by the design

The REU appears in I/O space at `$DF00-$DF0A`. It transfers between normal C64 memory and external RAM via DMA. REU memory is not directly executable by the C64 CPU, so code in REU must be copied or swapped into normal addressable RAM before execution.

### 14.2 REU runtime functions

```zig
pub fn present() bool;
pub fn copyC64ToReu(c64_addr: u16, reu_addr: u24, len: u16) void;
pub fn copyReuToC64(reu_addr: u24, c64_addr: u16, len: u16) void;
pub fn swap(c64_addr: u16, reu_addr: u24, len: u16) void;
pub fn compare(c64_addr: u16, reu_addr: u24, len: u16) bool;
```

`u24` is permitted internally for REU addresses even if user-level `u24` is not generally exposed yet.

### 14.3 Overlay model

Overlay metadata is emitted in every build that uses `@overlay` or `@bank`.

Source annotation example:

```zig
@overlay(.reu, .id = 3, .window = 0xA000)
pub fn drawHelpScreen() void {
    // ...
}
```

Overlay file metadata:

```text
magic: "ZPOB"
version: u8
id: u8
flags: u16
reu_addr: u24
c64_window: u16
load_size: u16
bss_size: u16
entry_offset: u16
checksum: u16
symbols...
```

Initial implementation does not need automatic overlay scheduling. It must generate metadata and provide manual runtime APIs:

```zig
c64.overlay.load(3);
c64.overlay.call(3, .drawHelpScreen);
```

Future implementation may add whole-program overlay planning.

---

## 15. Assembler backends

### 15.1 Primary: 64tass

Generated command example:

```text
64tass --m65xx --cbm-prg --vice-labels -l build/out.labels -o build/out.prg build/out.asm
```

Use `--m65xx` by default for standard opcodes. Do not use `--m6502` illegal opcode mode unless enabled.

### 15.2 Secondary: Kick Assembler

Generated command example:

```text
java -jar KickAss.jar -o build/out.prg -vicesymbols build/out.asm
```

Kick support is a dialect backend, not the primary path. Do not block core compiler progress on Kick support.

### 15.3 Internal PRG writer

The compiler should eventually be able to write a PRG directly for simple single-segment outputs:

```text
2-byte little-endian load address
raw program bytes
```

This is future work after the assembler path and host emulator tests are stable.

---

## 16. Host 6502/6510 emulator for verification

### 16.1 Required scope

Implement a deterministic host-side emulator sufficient for all legal NMOS 6502 opcodes emitted by the compiler and runtime.

Required features:

```text
A/X/Y/SP/PC/P status
64 KiB memory
legal NMOS 6502 instructions used by codegen
BRK/RTS/JSR/JMP/branches
zero-page, absolute, indexed, indirect addressing
cycle count optional in v0, required later for performance tests
memory hooks for KERNAL calls used by tests
memory hooks for REU registers used by REU tests
```

### 16.2 KERNAL stubs in host emulator

The host emulator does not need a full C64 ROM. It may trap JSR to known KERNAL addresses:

```text
$FFD2 CHROUT: append A to host output buffer
$FFE4 GETIN: pop from host keyboard queue or return 0
```

### 16.3 Test exit convention

Every generated test program includes:

```text
__zeropage_test_status: byte
__zeropage_test_exit: label
```

The emulator runs until one of:

```text
PC == __zeropage_test_exit
instruction budget exceeded
BRK encountered in test mode
panic flag set
```

---

## 17. VICE automation

### 17.1 Runner design

Implement `src/vice/binary_monitor.zig` as a client for VICE binary monitor API.

Required operations:

```text
connect(host, port)
ping()
autostart(prg, run=true)
memGet(start, end, bank=main)
memSet(start, bytes, bank=main)
registersGet()
registersSet()
checkpointSetExec(addr, temporary=true)
keyboardFeed(petscii_bytes)
dumpSnapshot(path)
quit()
```

### 17.2 Launch pattern

The runner must support configurable VICE command lines. Default attempt:

```text
x64sc -binarymonitor -binarymonitoraddress 127.0.0.1:6502 -sounddev dummy -warp
```

Do not hard-code the path to `x64sc`. On macOS, discover it from `ZEROPAGE_VICE_X64SC` first.

### 17.3 Debug ring

In test builds, reserve a debug ring in C64 RAM:

```text
magic:       4 bytes  "ZPDB"
version:     1 byte
write_idx:   1 byte
status:      1 byte  0=running, 1=pass, 2=fail, 3=panic
reserved:    1 byte
entries:     N records
```

Entry format v0:

```text
tag: u8
arg0: u8
arg1: u8
arg2: u8
pc_lo: u8
pc_hi: u8
```

The host runner reads the ring through VICE memory-get and decodes it using the generated map file.

### 17.4 Memory dumps

Each VICE test must be able to dump:

```text
screen RAM
color RAM
result buffer
zero page temp range
runtime debug ring
optional REU-visible overlay window after copy-back
```

### 17.5 VICE REU tests

VICE command-line flags for REU vary by version and platform. The runner must accept a full override string and must also support setting emulator resources through the binary monitor if available.

The tests must verify:

```text
copy C64 -> REU -> different C64 address
swap C64 <-> REU
overlay load into fixed window
```

---

## 18. Compilation pipeline

```text
source files
  -> lexer
  -> parser
  -> AST
  -> semantic analysis / type checking
  -> comptime evaluation
  -> typed IR
  -> feature/liveness analysis
  -> 6502 backend IR
  -> peephole optimizer
  -> assembler dialect emitter
  -> runtime linker
  -> assembler invocation
  -> PRG/map/labels/debug metadata
```

### 18.1 Diagnostics

Use Zig-like diagnostics:

```text
path/file.zp64:12:17: error: unsupported feature: generic function
    fn list(comptime T: type) void { }
                ^~~~~~~~
note: ZeroPage v0 does not support generic functions; use a concrete type
```

Unsupported full-Zig syntax must produce helpful errors rather than parser crashes.

### 18.2 Debug metadata

Emit `out.zpmap.json`:

```json
{
  "load_addr": 2049,
  "entry": 2061,
  "symbols": {
    "main": 2074,
    "__zeropage_test_exit": 49152,
    "__zeropage_debug_ring": 49168
  },
  "sections": [
    {"name":"text", "start":2061, "end":2400},
    {"name":"rodata", "start":2401, "end":2480},
    {"name":"bss", "start":2481, "end":2600}
  ],
  "features": ["basic_stub", "kernal_io", "debug_ring"]
}
```

---

## 19. Testing requirements

### 19.1 Unit tests

Required test classes:

```text
lexer tests
parser tests
AST pretty/snapshot tests
type checker pass/fail tests
constant evaluator tests
IR lowering tests
codegen instruction tests
assembler dialect tests
PRG writer/reader tests
mapfile tests
6502 emulator instruction tests
VICE binary monitor packet encode/decode tests
runtime linker liveness tests
```

### 19.2 Golden codegen tests

For every language construct, include:

```text
source fixture
expected assembly pattern or exact output where stable
expected PRG size budget
expected host emulator result
```

Do not make golden assembly too brittle before the peephole optimizer stabilizes. Prefer semantic expectations plus size ceilings.

### 19.3 End-to-end host tests

Each fixture compiles, assembles, loads into the host emulator, runs to exit, and verifies memory/output.

Initial fixtures:

```text
border_color.zp64
hello_chrouT.zp64
screen_putat.zp64
if_else.zp64
while_loop.zp64
function_u8.zp64
function_u16.zp64
struct_fields.zp64
array_index.zp64
pointer_deref.zp64
volatile_mmio.zp64
readline_fake_keyboard.zp64
arena_alloc.zp64
math16_add_sub.zp64
math16_mul_optional.zp64
reu_copy_model.zp64
```

### 19.4 VICE integration tests

Run only when VICE is available. Required initial tests:

```text
vice_hello_chrouT
vice_direct_screen
vice_keyboard_feed_readline
vice_debug_ring
vice_reu_copy, if REU can be enabled
```

Every VICE test must have a timeout and an instruction/raster fallback. No test may depend on human interaction.

### 19.5 Size tests

Track and fail on large regressions:

```text
bare_border <= 128 bytes including PRG load bytes and optional stub excluded
hello_kernal <= 512 bytes
readline <= 1536 bytes
arena_alloc_example <= 2048 bytes
reu_copy_example <= 2048 bytes
```

Budgets can be adjusted only by changing `tests/size_budgets.zig` with an explanatory note.

---

## 20. Milestones for autonomous implementation

### M0 — Scaffold and tools

Deliver:

```text
build.zig
CLI skeleton
source loader
diagnostics module
64tass discovery
basic PRG reader/writer helpers
unit test harness
```

Acceptance:

```text
zig build test passes
zp64c --help works
```

### M1 — Lexer, parser, and AST

Deliver:

```text
lexer for v0 tokens
parser for declarations, statements, expressions
AST data model
basic diagnostics
```

Acceptance:

```text
50+ lexer/parser tests
unsupported full-Zig features produce clear errors
```

### M2 — Types, constants, and IR

Deliver:

```text
type checker for v0 types
constant evaluator
module import for c64 and local files
typed IR
```

Acceptance:

```text
30+ semantic tests
@sizeOf/@offsetOf work
@import("std") fails with intended message
```

### M3 — Minimal 6502 backend

Deliver:

```text
u8 ops
globals
functions
if/while
return
64tass assembly emission
startup_basic_stub
host 6502 emulator enough to run generated programs
```

Acceptance:

```text
border_color and loops run in host emulator
PRGs assemble with 64tass
```

### M4 — Micro I/O library

Deliver:

```text
KERNAL CHROUT/GETIN wrappers
puts
waitKey
readLine fixed buffer
screen direct clear/putAt
runtime liveness linker
```

Acceptance:

```text
hello/input fixtures pass in host emulator
first VICE hello/readline tests pass
```

### M5 — Structs, arrays, pointers, volatile

Deliver:

```text
struct layout
array indexing
pointer deref/address-of
volatile MMIO
zero-page temp allocation
peephole v0
```

Acceptance:

```text
all listed M5 fixtures pass
size budgets active
```

### M6 — Optional 16-bit math and allocators

Deliver:

```text
u16/i16 add/sub/compare
optional mul/div helpers
arena allocator
fixed allocator optional
```

Acceptance:

```text
math and allocator tests pass
unused math helpers not linked
```

### M7 — VICE binary monitor harness

Deliver:

```text
binary monitor client
VICE runner
autostart/checkpoint/memory dump/keyboard feed
screen/debug ring inspection
```

Acceptance:

```text
zig build vice-test passes when VICE env var is set
```

### M8 — REU and overlays v0

Deliver:

```text
REU register helpers
host REU memory model
copy/swap/compare runtime
manual overlay metadata and manual load/call API
VICE REU test when configured
```

Acceptance:

```text
REU host tests pass
VICE REU copy test passes when REU enabled
out.zpmap.json contains overlay metadata
```

---

## 21. Non-goals

Do not implement in v0:

```text
full Zig compiler fork
LLVM backend
raw object/linker format
full Zig stdlib
full generic functions
async/threading
floating point
closures
runtime reflection
GC
automatic overlay scheduling
full C64 OS/ReadyOS ABI integration
full VIC/SID/CIA high-level library
D64 disk image builder
cartridge CRT builder
source-level debugger UI
```

Some of these may become future projects, but they must not block the microcompiler.

---

## 22. Agent operating rules

1. Implement the smallest testable unit first.
2. Add tests before or with every feature.
3. Keep unsupported features explicitly rejected.
4. Never silently lower unsupported Zig syntax into wrong code.
5. Preserve tight-code goals with size tests.
6. Prefer semantic E2E tests over brittle textual assembly snapshots.
7. Keep runtime functions separately linkable.
8. Never link a feature library unless liveness analysis marks it used.
9. Keep VICE tests optional but implemented.
10. Keep macOS paths configurable through environment variables.
11. Pin tool versions in docs and print detected versions in test logs.
12. Record every accepted feature in `docs/language.md`.
13. Record every target ABI decision in `docs/abi.md`.
14. Record every C64 memory reservation in `docs/memory-model.md`.

---

## 23. Example target program

```zig
const c64 = @import("c64");

export fn main() void {
    c64.screen.clear();
    c64.screen.puts("NAME? ");

    var buf: [32]u8 = undefined;
    const len: u8 = c64.input.readLine(&buf);

    c64.screen.puts("\nHELLO, ");
    c64.screen.putSlice(&buf, len);
    _ = c64.keyboard.waitKey();
}
```

Expected behavior:

```text
compile -> assemble -> PRG
host emulator can feed keyboard bytes and capture CHROUT output
VICE runner can feed keyboard bytes and read screen RAM/debug ring
runtime links: startup, kernal_io, input/readline, debug_ring in test mode
runtime does not link: REU, allocator, math16 mul/div, direct screen if unused
```

---

## 24. Reference URLs

- Zig documentation: https://ziglang.org/documentation/master/
- Zig overview: https://ziglang.org/learn/overview/
- Zig 0.15.1 release notes: https://ziglang.org/download/0.15.1/release-notes.html
- Zig 0.16.0 release notes: https://ziglang.org/download/0.16.0/release-notes.html
- Old GitHub Zig repository page: https://github.com/ziglang/zig
- VICE monitor manual: https://vice-emu.sourceforge.io/vice_12.html
- VICE binary monitor manual: https://vice-emu.sourceforge.io/vice_13.html
- 64tass manual: https://tass64.sourceforge.net/
- Kick Assembler manual: https://www.nightfallcrew.com/wp-content/uploads/downloads/2011/10/KickAssembler_321_Manual.pdf
- C64 memory map: https://www.c64-wiki.com/wiki/Memory_Map
- Ultimate C64 memory reference: https://www.pagetable.com/c64ref/c64mem/
- KERNAL routines: https://www.zimmers.net/anonftp/pub/cbm/c64/programming/documents/c64-kernal.txt
- REU registers: https://codebase64.net/doku.php?id=base%3Areu_registers
- REU programming: https://codebase64.net/doku.php?id=base%3Areu_programming
