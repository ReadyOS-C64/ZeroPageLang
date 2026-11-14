# Memory model

ZeroPage targets one 64 KB C64 address space plus optional REU storage. The compiler validates configured regions against each other and against the final assembled PRG.

## Default C64 layout

| Address | Use |
| --- | --- |
| `$0000-$07ff` | C64 low memory; unavailable to configured heaps and module windows |
| `$0801-$080c` | BASIC stub containing `SYS 2061` |
| `$080d+` | Generated program, static storage, and selected runtime helpers |
| `$f7/$f8` | Default software-stack pointer (`sp`) |
| `$f9/$fa` | Default software-stack frame pointer (`fp`) |
| `$fb/$fc` | Compiler pointer scratch |
| `$fd/$fe` | Compiler string pointer scratch |
| `$d000-$dfff` | C64 I/O; unavailable to heaps and ordinary module windows |
| `$df00-$df0a` | REU registers when an REU is used |

`$d020`, used by the border example, is a VIC-II register rather than compiler-owned storage.

## Source-owned zero-page policy

The main application may declare zero-page ownership in its `memory` block.

```zig
memory {
    zero_page {
        profile = .kernal;
        allocation = .scalars;
        range at 0x02 size 0x18;
        range at 0x40 size 0x20;
        range at 0xfb size 4;
        reserve at 0x40 size 4;
        restore_basic = true;
        interrupts = .system;
    }
}
```

Omission preserves existing binaries and fixed pointer/stack conventions.
There are no compiler flags for this policy. The presets describe ownership:

| Profile | Default candidate bytes | System contract |
| --- | --- | --- |
| `.compatibility` | `$fb-$fe` | Existing runtime ABI; automatic allocation is off by default |
| `.basic` | `$fb-$fe` | BASIC/KERNAL workspace remains reserved |
| `.kernal` | `$02-$8f`, `$fb-$fe` | Application borrows BASIC workspace; documented KERNAL services remain available |
| `.bare` | `$02-$fe` | External caller already owns IRQ/NMI and ROM-service policy before entry |

`$00/$01` and `$ff` are always protected. `range` clauses replace the candidates;
omission selects the preset. `reserve` subtracts application/assembly claims.
These fields contain literal start/size pairs with exclusive ends; empty,
wrapping, overlapping or protected ranges are rejected. Explicit ranges cannot
override system reservations. Application fixed-address bytes inside the pool
**must** be listed in `.reserve`, whether used by literal source pointers, inline
assembly, interrupts or foreign code. For example, an application byte at `$02`
needs `reserve at 0x02 size 1;`; admitting `$02` without this reservation
allows the compiler to claim it. Pointer values do not automatically create
reservations or prove disjointness from compiler claims.

The two required pointer pairs prefer `$fb/$fc` and `$fd/$fe` when available,
otherwise use contiguous pairs in the selected pool. Every generated reference,
including startup copying and string operations, follows the selected aliases.
User literal addresses and inline assembly are not silently rewritten.

`allocation = .off;` leaves optional cells in resident storage; `.scratch`
permits profitable compiler-owned one/two-byte scratch cells. `.scalars` includes
scratch and eligible private typed static-frame parameters. Both kinds compete
deterministically by estimated weighted use per byte, with stable label ties.
This score is a placement heuristic, not a measured speed guarantee. Required
pointer and explicit stack claims come first. Each selected parameter occupies
its complete one/two-byte cell; full, unused or pinned candidates retain ordinary
storage. No local/return cells, arrays, aggregates or lifetime overlays are
promoted.

Parameter types are `bool`, byte/word signed and unsigned integers, `usize`,
byte enums and supported near pointer values. The original definition must be a
single uniquely owned zero-initialized scalar cell of the exact declared width.
Entry/exported/configured-ABI functions, fixed placements, nonstatic frames,
module/loader programs and recursive SCC members are excluded. Retained opaque
source assembly disables parameter promotion globally. Unresolved callees,
aliases, indexed references, slot-address escapes and unsupported definition
shapes also exclude promotion. Ordinary known nonleaf functions can qualify;
passing or returning a pointer value alone does not expose its parameter slot.
Explicit-policy images must load and enter at or above `$0200`. DLL packaging and
module-loader apps currently require the compatibility policy.

Strict profiles require configured software-stack SP/FP pairs within the allowed
pool and outside other claims. `$f7-$fa` are RS-232 workspace, not general free
bytes; compatibility retains the existing convention. KERNAL apps can relocate
stack pointers using `stack in call_stack zp sp 0x30 fp 0x32;`, when those
bytes are admitted. BASIC's four default candidate bytes are already consumed by
the two runtime pointer pairs, so that profile has no extra default scratch pool.

Borrowed bytes are snapshotted before startup copies or main initialization.
Moved scratch and parameter cells receive explicit runtime zero initialization;
a PRG cannot load initial values into disjoint ZP bytes. Default `.restore_basic = true` restores
all actually claimed system bytes on **normal executable return**. KERNAL mode
restores borrowed BASIC bytes; bare mode also restores claimed KERNAL bytes.
`.restore_basic = false` explicitly retains ownership across normal return.
Entry and exit preserve live registers and hardware-stack balance. Snapshot storage and lifecycle code can grow small
programs; measurements include that overhead and report ZP separately.

Normal-return restoration does not intercept STOP/RESTORE, reset, cartridge/NMI
hooks or forced BASIC warmstart. Choose `.basic` when asynchronous BASIC workspace
transparency is required, or provide application handlers/restoration. Stock
KERNAL IRQ uses KERNAL workspace; custom handlers must respect application claims.
Do not invoke BASIC with borrowed workspace live. KERNAL borrowing rejects
unclassified/destructive ROM entries and permits documented non-destructive
KERNAL jump-table calls. Bare mode rejects ROM calls, requires `.interrupts =
.application`, and requires `image.basic_stub = false`: interrupt takeover must
already be complete **before** `zeropage_entry`, not in main. The compiler does
not infer ownership from banking or pretend SEI masks NMI.

The `.zpmap.json` `zero_page` object records policy, candidates, reservations,
actual claims, spills, pointer addresses, restored ranges and the normal-exit
scope. Scalar mode adds `parameters`: each source parameter's qualified `label`,
scalar `size` (zero for an unsupported type), `reason` and `status`
(`allocated`, `spilled` or `excluded`). Claims distinguish `parameter` from
`scratch`. Reasons cover source ownership/call-graph barriers and actual storage
shape/addressing exclusions; `eligible` with `spilled` can mean no capacity or
no remaining profitable uses. Map generation checks parameter identity, width,
source eligibility and claim/status agreement as well as physical placement.
Runtime data, PRG bytes, borrowed system bytes and ZP allocation are distinct
quantities. See [ABI](abi.md) and [testing](testing.md) for lifecycle proof.

`unproven_memory_domain` marks otherwise eligible private parameters excluded by
the bounded external-pointer, integer-address DMA, free-metadata and address-wrap
audit. An ordinary u16 REU host address can access zero page even without a
pointer cast. Unknown or zero runtime transfer counts are not treated as empty
transfers, and dynamic indices receive no guessed type/loop bounds. Conservative
cross-products can exclude unrelated pointer/consumer pairs; recovering them
requires actual origin and range proof. Map replay rejects allocated claims for
excluded parameters. This guard enables no additional local allocation.

### Buffered repeated-greeting example

`examples/micromodules/repeated_hello_display.zp64` is an application-owned,
assembly-assisted display module used by `examples/repeated_hello_buffered.zp64`.
Its fixed reservations are not new compiler-wide defaults:

| Address | Use | Bytes |
| --- | --- | ---: |
| `$20-$28`, `$30`, `$32-$35` | Display state and indirect-copy scratch | 14 |
| `$0400-$07e7` | First screen matrix's visible cells | 1,000 |
| `$2400-$27e7` | Second screen matrix's visible cells | 1,000 |
| `$2800-$2bff` | Text ring; initialization clears four pages | 1,024 |
| `$d800-$dbe7` | Shared color RAM cells | 1,000 four-bit cells |

The application assumes the normal VIC bank-0 setup, owns screen selection at
`$d018`, disables CIA1 and VIC interrupt sources, and exits through KERNAL warm
start after RUN/STOP is released. It cannot coexist with unrelated users of its
fixed scratch or buffers. The compile-only comparison script rejects a resident
image reaching `$2400`; these inline-assembly reservations are documented here
rather than automatically inferred by the compiler's memory planner.

Resident figures in the greeting comparison include the loaded image, any BSS
outside that image, zero-page scratch, and all display buffers. Color RAM,
shared system workspace, the hardware stack, and unused software-stack capacity
are separate. Stock C-linker stack budgets are shown independently and also
added in a separate total; they are capacities, not measured stack use.

The alternative `repeated_hello_display_highlevel.zp64` uses the same three
display buffers and IRQ/display ownership, but stores its eight-byte typed state
inside `init`'s ordinary static frame. It returns a pointer to this singleton;
another initialization resets that same object. Its only fixed application ZP
reservation is `$20-$23`, used by the 40-byte row-copy kernel. General compiler
pointer scratch additionally uses `$fb/$fc`. Its other locals, parameters,
greeting storage, and runtime scratch are part of the loaded image. It does not
reserve the older module's `$24-$28`, `$30`, or `$32-$35` state bytes.

The balanced alternative `repeated_hello_display_balanced.zp64` stores its
seven-byte typed singleton in the loaded image. Its fixed application scratch
is `$20-$23` and `$30` (five bytes) for bulk row/page operations, plus compiler
pointer scratch at `$fb/$fc`. Display buffers, color RAM, and IRQ/display
ownership are the same as the other buffered examples. Its `back_page` field
encodes the high byte of one of the fixed `$0400`/`$2400` matrices.

The comparison's portable buffered C source
(`examples/comparison/repeated_hello_buffered.c`) and idiomatic Oscar64 alternative
(`examples/comparison/repeated_hello_buffered_oscar64.c`) own the same screens,
1,024-byte ring, shared color cells, and CIA1/VIC interrupt sources. The compile-only
script also checks their loaded images and BSS end below `$2400`. They allocate
no heap. cc65 reserves its stock 26-byte ZP pool; its four BSS bytes reuse loaded
ONCE storage. Portable Oscar64 uses 13 scratch ZP bytes and four extra BSS bytes;
idiomatic Oscar64 uses 20 scratch ZP bytes and four extra BSS bytes. Software-stack
budgets (cc65 2 KB, Oscar64 4 KB) remain separate from the resident totals.
The idiomatic alternative explicitly configures text mode and VIC bank 0 and
copies the rotated ring as two contiguous `memcpy` spans. The portable C and
ZeroPage variants copy it row by row. No frame timing is established by these builds.

## Program storage

The default image remains byte-compatible with the original layout: PRG load `$0801`, BASIC `SYS 2061`, and entry `$080d`. `image prg` may independently select the PRG load address, program entry, BASIC-stub presence, and an exclusive resident `address_limit`. The compiler checks both the PRG header and the assembled resident end against that declaration.

The load address is where the PRG bytes enter C64 RAM. The entry address is where execution begins. They may differ; a generated BASIC stub contains the configured decimal `SYS` target. With no BASIC stub, the embedding environment or test runner must start the configured entry explicitly.

Static-frame functions normally place their parameters, locals, and return storage beside the function's generated code. Explicit `allocation = .scalars;` may move eligible private parameter cells into admitted zero page. Both forms have static lifetime, so the function is not re-entrant.

The program tail contains global compiler scratch, runtime state, and module-owned read-only data. Runtime helpers and their state are emitted only when referenced. Generated assembly surrounds each ownership group with section markers; the matching `.zpmap.json` records the final addresses.

Fixed arrays are currently limited to 255 bytes. Module-scope strings and fixed scalar arrays live in the owning source module's read-only data section.

## Named regions and placement

`region` declarations in `memory` define the physical ranges used by the program. A region has a name, start, size, address space, and C64 bank visibility. The compiler rejects duplicate, empty, out-of-range, or overlapping regions. It also checks named consumers against their required address space and against the final resident image.

The same C64 region may be selected by exactly one reservation role: software stack, near arena, module window/staging, or a code/data placement. REU regions likewise back far arenas, module caches, and related module storage. This makes Memory Arena and DLL configuration consumers of the region model rather than parallel allocation systems.

Hosted systems may resolve a named REU region through an allocator instead of assigning a fixed physical address. In particular, ReadyOS must remain the authority for schema-5 physical banks, resource records, caching, and eviction. The proposed host boundary and unified claim ledger are described in [ReadyOS Precog integration](readyos-precog.md).

A placement assigns named functions and constants to a C64 region:

- `.direct` sets both load and run address to the region address. It is simple and immediately executable, but a distant address creates padding in a contiguous PRG.
- `.startup_copy` keeps the bytes compact in the load image, gives their labels the region run address, and copies them during `zeropage_memory_init` before `main`.

Startup copying preserves processor status and `$0001`. For RAM under BASIC or KERNAL it temporarily exposes RAM, performs the copy, and restores the original mapping. Calls into banked placement functions use resident gateways that apply the same mapping discipline and preserve scalar return registers.

Current placement limits are deliberate: placed functions use static frames; `main` and module exports are not placement targets; a resident function may not directly reference a constant hidden under ROM; and KERNAL-bank code may not depend on KERNAL/keyboard/disk helpers. Functions and constants in the same banked placement may refer to one another normally.

Direct sparse resident placement and relocatable DLL packaging solve different problems. A directly placed segment extends the contiguous PRG through its address gap, while a DLL payload is compact and relocatable into a module window. Use `.startup_copy` for compact fixed-run-address resident code, and use the module loader/REU cache for independently loadable or evictable DLL code.

## Software stack

Functions declared with `callconv(.stack)` use a compiler-managed software stack in configured C64 RAM. Stack frames support the documented scalar calling convention and recursive calls. The compiler rejects missing stack configuration, frames larger than 255 bytes, and regions that overlap the program, I/O, heaps, or module storage.

The stack pointer and frame-pointer pairs are configurable, but must be valid, non-overlapping zero-page pairs. See [ABI](abi.md) for calls and returns.

## Near heaps

Declare near heaps in `memory` and give them a visible C64 region:

- `arena scratch in work_ram;` advances a two-byte cursor; `reset()` releases the whole region.
- `pool sprites in sprite_ram block 16;` adds a free list for equal-sized blocks; `free()` returns a block to that list.

Heap regions must be non-empty, fit in C64 RAM, and avoid low memory, I/O, the software stack, other heaps, module regions, and the final PRG. Allocation returns `null` for exhaustion or a runtime length of zero. Returned addresses are ordinary near pointers.

## REU storage

REU addresses are 24-bit far addresses in `0x000000..0x00ffffff`. Far heaps, module caches, and state snapshots must not overlap. The 6502 cannot dereference REU storage: bytes move through explicit REU transfers or typed views.

See [REU and modules](reu-overlays.md) for the far-memory and overlay model.

## Module regions

Module configuration may reserve:

- one `.main` C64 load window and additional named windows;
- a C64 disk-staging buffer;
- deterministic REU cache slots for module rows;
- REU snapshot slots for persistent state.

Visible windows must avoid low memory, I/O, the PRG, stack, heaps, staging, and each other. A banked window is valid only when it lies wholly within `$a000-$bfff` with `.ram_under_basic`, or `$e000-$ffff` with `.ram_under_kernal`.

Stale bytes may remain in a load window or REU slot after unload. Registry state and active-window ownership determine whether a module is callable; leftover bytes do not.

## Inspecting a build

Dynamic indexed pointer/optional-pointer record-field stores reserve two resident
bytes per emitted store site (`zeropage_field_value_N`). Their map sections have
owner `runtime`, kind `data`, static lifetime and near addressing. These pending
values survive effectful index evaluation and independently emitted callee
scratch use. They are not automatically enrolled in optional ZP allocation or
overlaid with other temporaries. Literal-index stores do not need this pending
word. Numeric word-field scratch behavior is a separate implementation path.

Complex numeric indexed stores and many-item pointer address calculations use
two hardware-stack bytes for each pending value or base they must preserve.
These are temporary bytes per active operation, in addition to nested calls
and interrupts. They add no resident word or ZP claim and do not establish a
whole-program peak stack bound.

Indexed compound updates preserve their evaluated destination across the
right-hand expression. Simple arithmetic can keep the index in Y. When the
right-hand expression can clobber registers, the compiler can hold up to three
address bytes and two old-value bytes on the hardware stack. These bytes are
temporary per active update, in addition to any nested calls and interrupts.

`zp64c compile source.zp64 -o out.prg` writes:

- `out.prg.asm`: generated assembly and section markers;
- `out.prg.labels`: 64tass/VICE labels;
- `out.prg.zpmap.json`: concrete section ownership and address ranges.

The map also records image load/entry settings, every declared named region, and each placement's load-memory (LMA) and run-memory (VMA) ranges.

Module builds add the sidecars described in [CLI reference](cli.md) and [ABI](abi.md).
