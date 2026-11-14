# ABI

ZeroPage uses a byte-aligned, little-endian ABI designed for predictable 6502 code. Static frames are the default. A separate software-stack ABI is available for supported scalar functions and module exports.

## Value representation

| Value | Representation |
| --- | --- |
| `bool`, `u8`, `i8`, `enum(u8)` | One byte |
| `u16`, `i16`, `usize` | Two bytes, low byte first |
| Near pointer | 16-bit C64 address, low byte first |
| Optional scalar | Present byte followed by payload |
| Optional pointer | 16-bit pointer; `$0000` is `null` |
| Tagged union | One-byte tag followed by fixed payload area |
| Fixed array | Contiguous elements |
| Struct | Flattened fields in declaration order |

All supported types have alignment `1`. Struct layout is recursive and contains no implicit padding.

## Return registers

- Byte values and `bool` return in `A`; X is unconstrained. A caller widening a byte result into A/X explicitly sets X to zero, matching ordinary byte-load widening.
- Word values and pointers return low byte in `A`, high byte in `X`.
- `void` has no return value.
- Static aggregate returns use compiler-owned return storage.

Callable functions are 6502 subroutines and return with `RTS`. The
compiler can inline a private function at its only call site. Its
static-frame storage retains program lifetime, and the inlined body
preserves the caller's live stack and the function's return values.

## Static frames

Static is the default frame policy. Parameters, locals, aggregate fields, loop captures, and return records live in labels owned by the function.

```text
function_param
function_local
function_return_field
```

Static calls copy arguments into the callee's parameter slots before `JSR`. Aggregate calls copy each flattened field. Static frames have program lifetime and are not re-entrant.

Near-pointer and nullable-pointer fields retain both representation bytes across
field access, nested aggregate copies, arguments and aggregate return storage.
This repairs the implementation of the existing representation; it adds no
module export or software-stack aggregate ABI.

A dynamic indexed store to a pointer-valued record field retains its pending
two-byte value in a distinct resident `zeropage_field_value_N` word while the
index is evaluated. Separate emitted sites cannot clobber one another through
compiler scratch reuse. These are static temporaries, not re-entrant storage or
a promise of disjointness from arbitrary native writes.

Function-owned static storage is emitted next to the function's code. Global compiler scratch and runtime state are emitted in the program tail.

## Software-stack frames

`callconv(.stack)` selects the ZeroPage software stack. `callconv(.static)` explicitly selects the default static ABI.

```zig
memory {
    region call_stack: c64 at 0xc800 size 0x0400;
    stack in call_stack;
}

fn worker(value: u8) callconv(.stack) u8 {
    return value + 1;
}
```

The stack grows upward in normal C64 RAM. Default zero-page pointer pairs are:

- `$F7/$F8` — stack pointer
- `$F9/$FA` — frame pointer

Call bridges reserve the callee frame, copy scalar arguments into frame offsets, issue `JSR`, restore the caller frame, and preserve scalar return registers through cleanup. Reservations are checked against the configured stack limit. Overflow enters
`zeropage_stack_overflow_trap`. A standalone stack-to-stack bridge can check
the saved frame-pointer pair and the callee frame together before writing
the link. Storage and pointer values at the terminal trap depend on the
bridge and the point where the reservation fails.

The current stack subset supports scalar parameters and scalar or `void` returns. Aggregate locals, strings, arrays, optionals, unions, and opaque heap or REU handles remain static-only. Stack functions may call supported scalar static or stack helpers through generated bridges. Recursive and mutually recursive scalar stack calls are supported.

The 6502 hardware stack remains reserved for return addresses, status preservation, and KERNAL compatibility.

Complex indexed operations can hold a pending numeric word and/or a many-item
pointer base on the hardware stack across index evaluation. Each hold uses two
bytes and is released before the operation finishes. This preserves the existing
evaluation order and live caller stack; it does not extend the software-stack
array-store subset. Physical SP observers inside a called index expression can
see the temporary depth.

Compiler temporary pushes/pops may be optimized away. Unused hardware-stack
bytes at or below the current SP have no stable content guarantee; they are
private scratch, rather than source-visible storage. Optimizations preserve
live stack balance and the documented register/memory results.

Standalone software-stack word loads read the high byte into X and then
the low byte into A. Adjacent word stores use Y for both byte offsets.
These sequences retain the frame offsets, byte order and return registers.
An exact-fit reservation is allowed, including when the stack limit is
page-aligned. A standalone nested call can copy matching scalar parameters
and locals directly from the still-active caller frame once the reservation
succeeds. The callee uses the same parameter offsets. The compiler may
omit writes to its private argument scratch. For a standalone private stack
in `$C000–$CFFF`, the compiler may also omit scratch slots unused by all
staged calls in a frame. This reduces the size of live frames within the
configured stack reservation. Explicit observation of the stack region or
its pointers, retained inline assembly, and external entry points preserve
the original frame layout.

Private static-to-stack bridges can restore the software stack pointer
using Y while the return value stays in A or A/X. Y and N/Z remain
caller-clobbered. Bridges that need resident return scratch continue to
use it. A private nested bridge can hold the low result on the hardware
stack while restoring the software frame link. The balanced spill uses
one byte after the callee's return, within the depth reached by its JSR.

## Image entry and placed-code gateways

`zeropage_entry` is the configured executable entry label. It runs startup memory copies before entering `main`. The traditional default remains `$080d`; custom images may put the label elsewhere and may omit the BASIC launcher.

A `.startup_copy` placement has distinct load-memory and run-memory addresses. The startup copier uses the selected general/string pointer pairs (`$fb/$fc` and `$fd/$fe` under compatibility) as source and destination pointers, copies the exact assembled placement size, and restores `$0001` and processor status. Its labels resolve to the run address, so internal calls and constant references need no relocation at startup.

Calls from resident code into a BASIC- or KERNAL-hidden placement go through a generated resident gateway. The gateway saves processor status and `$0001`, exposes the required RAM, calls the run-address label, saves returned `A` and `X`, restores mapping and status, then restores the return registers. Calls within the same placement are direct. Status flags after return are not an ABI result.

Placed functions currently require the static-frame ABI. Banked calls are limited to scalar, pointer, and enum boundaries; aggregate and software-stack placement are rejected until their ownership and re-entrancy rules are explicit.

## Pointers and volatile access

Pointer storage is one little-endian word. Dereference code materializes the address in compiler-owned zero-page scratch and uses indirect indexed addressing.

Many-item pointer indexes scale by element size. Word values remain low-byte first. Struct-pointer field access adds the compile-time flattened field offset.

Volatile pointers use the same representation, but every source access emits a load or store. There is no separate volatile calling convention.

## Arrays and aggregates

Scalar arrays are contiguous. Arrays of structs use array-of-records layout. There are no array bounds or ownership fields.

Exact-type struct copies move all flattened bytes. Small copies are emitted inline; larger contiguous copies may use a generated loop. Different struct names are never ABI-compatible merely because their fields happen to match.

## Compiler scratch

The backend uses named scratch for pending call arguments, arithmetic, shifts, pointer materialization, optional/union switches, stack returns, and runtime helpers. Scratch labels use their own namespace so adding an expression helper does not renumber structural labels such as `if_N` and `while_N`. Temporary value spills and runtime counters have no post-expression content guarantee; use declared return registers/storage. Optimizations can reuse or omit this private scratch, including replacing memory counters with registers.

Generated section markers identify code, static frames, scratch, runtime data, and read-only data. The markers are byte-neutral and feed `.zpmap.json`.

## Module ABI

A `module` declaration produces JSON and binary sidecars. Module exports must use the supported software-stack scalar ABI.

```zig
module math_core abi 1 {
    export add;
}

fn add(value: u8) callconv(.stack) u8 {
    return value + 2;
}
```

Exports receive stable zero-based ordinals in source order. The binary payload starts with one three-byte absolute `JMP` per export, followed by selected code, read-only data, and required scratch/runtime storage.

The `.zpmod` binary uses magic `ZPMD`, format version `1`, little-endian records, and an additive checksum. Its tables describe exports, dependencies, sections, relocation records, registry rows, graph edges, windows, state, and package data when those features are configured.

### Relocation

Relocation records are emitted from known compiler anchors, not discovered by scanning bytes. Supported kinds are:

- `abs16` — little-endian absolute operand
- `lo8` — low byte of a relocated address
- `hi8` — high byte of a relocated address

`.zpmod.relocsim.json` applies the same records to an in-memory payload at the configured window. It is the host-side oracle for runtime patching.

### Registry and ownership

Registry row `0` is the current module. Direct dependencies follow source order; transitive graph rows follow in deterministic first-seen order.

Each row has a loaded byte and a refcount byte. Loading ensures residency and initializes ownership to one. Repeated ensure operations do not increment. Explicit acquire operations increment up to `255`. Final release clears callability but does not erase cached or window bytes.

Each configured C64 load window has an active-row byte. Activating a row copies its REU cache payload into the assigned window, applies relocations, restores persistent ranges, records the active row, and dispatches through `window.addr + ordinal * 3`.

Dependency sidecars are compile-time inputs. The compiler validates ids, ABI versions, signatures, payload length, window compatibility, KERNAL safety, and relocations. The C64 runtime performs no name lookup, signature reflection, graph parsing, or sidecar parsing.

### Banked windows

Windows may use visible RAM, RAM under BASIC, or RAM under KERNAL.

- BASIC-bank operations save `$0001`, hide BASIC ROM, perform the operation, then restore `$0001`.
- KERNAL-bank operations also preserve processor status and mask interrupts while HIRAM is clear.
- KERNAL-bank exports must be KERNAL-independent or limited to the supported console trampoline path.

Returned `A` and `X` values survive bank restoration. Final status flags are not part of the export-return contract.

## ABI boundaries

The following are not ABI promises:

- compiler scratch addresses;
- generated helper presence or order;
- static storage labels not documented as compatibility labels;
- full status-flag preservation across calls;
- layout compatibility between distinct named types;
- runtime interpretation of module names or metadata.

The supported contracts are enforced by unit, Peddle, sidecar, section-marker, and VICE tests.

## Hosted application lifecycle

The current executable ABI has one `zeropage_entry`, but an application host may require a fixed public entry independently of the resident body's placement. The proposed ReadyOS profile keeps a small `$1000` trampoline and distinguishes cold entry, resume entry, and optional suspend handling without exposing ZeroPage's segment layout to the resident OS shim.

ReadyOS application switching is a terminal ABI transfer: F2/F4 select a logical application token and jump through `$c80f`; Ctrl-B jumps through `$c80c`. Physical REU banks and loaded state remain host-owned. ZeroPage DLL ordinals and relocation records remain compiler-owned. The full ownership boundary is in [ReadyOS Precog integration](readyos-precog.md).

## Optimization and public roots

Function pruning retains every declared DLL export regardless of resident call
sites, preserving export order, ordinals, signatures, state contracts, and
relocation metadata. Source exports, explicit function placements, and explicitly
configured ABI functions are roots too. Reachable opaque assembly conservatively
retains source symbols. Unused private code/static frames may be absent from
output; all declarations are still semantically validated. This does not change
calling conventions or reserve additional memory.

Scalar switch lowering may use Y for a table index and C/N/Z for bounds tests.
These are caller-clobbered implementation state, not return values; callers must
use the declared A or A/X result and establish their own condition flags. The
constant-result switch pass preserves I/D/V, stack balance, source storage, and
selector effects. Opaque assembly referencing `switch_expr_` dispatch labels
pins their original blocks, because coalesced debug anchors are not independent
case entry points.


## Configured zero-page ownership

Main-app `.zero_page` policy may relocate the two compiler indirect-pointer pairs
and place private compiler scratch in admitted ZP bytes. `.allocation = .scalars`
additionally permits eligible private scalar parameter slots there. Their aliases
and claims are recorded in the map; code must not assume `$fb/$fd` outside the compatibility
ABI. Literal source/asm addresses remain literal. Strict stack SP/FP claims use
the configured admitted set. DLLs/module loaders retain the compatibility ABI
until a shared host/module ZP contract exists.

Static calls and stack-to-static bridges still initialize the same named callee
slots before `JSR`; scalar returns keep the existing register ABI. Promotion
changes physical storage, not the parameter's type or call convention. Only
uniquely owned one/two-byte static parameter cells qualify. Entry/exported
functions, configured ABI roots, fixed placements, recursive SCC members,
software-stack frames and module/loader programs are excluded. Retained opaque
assembly disables parameter promotion globally; unresolved callees, slot-address
escapes, aliases and indexed references also prevent affected promotions.
Pointer values remain eligible when their slot address does not escape. Locals,
return cells and aggregates remain in their existing storage. Slots are never
overlaid, and capacity fallback preserves the original resident cell.

Code and external handlers using fixed addresses within the admitted pool must
reserve those bytes explicitly. Literal pointers and assembly addresses do not
track compiler aliases. Private parameter addresses may differ between builds;
exported/configured ABI frames retain their existing contract.

With lifecycle work, entry snapshots claimed system bytes before all startup,
initializes moved scratch and parameter cells, calls main, then restores system
bytes on normal return.
The source function returns first. Enter/leave preserve A/X/Y and
physical C/Z/I/D/V/N flags plus stack balance. This contract concerns the
lifecycle shim; ordinary source calls keep their existing caller-clobbered ABI.
Normal-return restoration does not cover forced warmstart/reset/NMI exits or make
user ISR code reentrant. Bare callers must establish IRQ/NMI ownership before
entry. Snapshot buffers are resident, not extra undocumented ZP claims.

Ordinary source arithmetic and address calculation use the binary-mode ABI
(D clear), as at normal C64 BASIC SYS entry. Foreign/bare callers must establish
that mode before running source code. Inline assembly saves/restores its analyzed
processor-status clobbers. Native helper tests under ambient decimal mode verify
machine transformations without adding a source BCD arithmetic/addressing contract;
relinking private frame addresses can affect decimal ADC of their bases.


Private static scalar calls may eliminate an earlier compiler capture/copy after
proving that later instructions cannot access its parameter destination or the
removed temporary. Left-to-right argument evaluation and all source parameter
writes remain. A final word argument, including a single-argument call, may be
stored directly with STA/STX after its expression is evaluated. At the old final
copy position, a high-byte reload preserves the exact pre-JSR A/NZ result,
X/Y/C/V/I/D and SP. Any retained earlier copies finish before that reload.
When canonical RAM analysis proves X still holds the same byte, TXA may establish
the identical state instead of LDA. A final byte argument keeps its original copy.

The complete destination and capture frames must have proved unique ownership
and visible, readable/writable RAM; MMIO and RAM beneath visible ROM cannot
justify replacing a capture load. Actual typed storage, canonical interval disjointness, and suffix checks
cover both destination and removed temporary. Unknown or aliasing effects retain
staging. Public/configured ABI roots, escaped or recursive cells, source ASM,
software-stack, module and placement paths keep their existing guards. Source
effect summaries alone cannot authorize the rewrite without lowered machine,
storage and helper/scratch proofs. This introduces no source setting or public
calling-convention change. The store/load transformation itself also preserves
decimal mode; ordinary source arithmetic retains its documented D-clear ABI.

Retained `@intFromPtr` and nonliteral `@ptrFromInt` expressions currently exclude
otherwise eligible private parameters from zero-page relocation. A numeric
literal passed directly to `@ptrFromInt`
does not trigger this extra exclusion. The map records `layout_observer`;
unreachable functions do not taint retained code. This conservative guard covers
observations through another object's address, rather than assuming that only
references spelling the parameter's own label can reach it. Existing export,
address-escape, storage and calling-convention exclusions take precedence.
Private frame adjacency remains an implementation detail. This guard is not a
complete proof for arbitrary literal-address, indexed or external pointer aliases.

The additional `unproven_memory_domain` exclusion covers bounded cases that can
reach borrowed zero-page bytes without an explicit address cast: a retained
public/configured pointer-bearing input together with a possible pointee access,
unproved C64 endpoints/counts of REU transfers, heap-free metadata effects and
potential pointer/index/screen address wrap. Pointer-bearing inputs include
supported nested optional/record/union shapes. Pure pointer-value forwarding
alone does not trigger this exclusion. Earlier owner/storage reasons and
`layout_observer` retain precedence. This is a conservative rejection rule;
absence of the reason is not a whole-program alias certificate.

Argument-store motion may independently prove a fixed resident write safe under
`layout_observer` or `unproven_memory_domain`; this does not make the parameter
eligible for relocation.
The compiler validates the entire scalar capture/copy phase against actual
typed parameters, unique compiler captures and the matching direct callee.
Only the exact scalar copy chunks and byte-free comments may occur during the
copy phase. Labels, stack/status observations, extra operations, malformed or
duplicate metadata and unknown calls decline the rewrite. The machine suffix
proof must still exclude every intervening access to either the destination or
discarded capture. Later indirect/unknown reads retain staging; a volatile word
read completed before capture remains two byte reads in its original order.
