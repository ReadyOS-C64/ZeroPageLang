# ZeroPage Design Learnings

Typed current-module `load()` and `acquire()` share AST variants with dependency
operations. The early payload scan must recognize those variants when
`from_binding` is set and the target id matches the current module. The
disk-backed path can mask a missing embedded-payload scan because it requests
the same payload labels. Keep an embedded-only typed example in assembler and
host-emulator coverage.

## Optimization Measurements And Export Roots

VICE launch diagnosis: use the established isolated harness bridge from the
sibling compiler projects. The default test scripts prepare it through
`scripts/prepare_vice_harness.py`, pinned and checksum-verified under `build/`.
The unpatched bridge can fail TCP-listener enumeration on macOS and report
`binary monitor not reachable` even though the emulator is running. Check
the working project's connection path before diagnosing a broken VICE install.
Border-only plans must observe the expected register value with bounded
retries; an injected SPACE and a one-second delay can run before autostart.

Optimization is the current priority; use `OPTIMIZATION_ROADMAP.md` for research
and sequencing. Keep one transformation per measured round, with unchanged
source/import hashes and immutable before/after data under `optimization/`.
Generated-artifact scans can include stale PRGs from earlier names/runs; use
the fresh host-metrics corpus for aggregate claims and list missing/new rows.

Peddle's `executeInstruction()` does not advance `clock`; its integration host
must do that per microcycle. The ZeroPage shim now steps through `execute()` and
advances the clock, with indexed and branch page-crossing tests. Counters exclude
intercepted KERNAL/test calls and are not VIC/CIA/REU/ROM timing.

For DCE, DLL `.exports` are external roots even when no resident application
calls them. Sidecar ordinals/signatures, relocations, state, bank policy, fixed
placements, startup routines, and opaque assembly boundaries constrain pruning.
Unify the emitter/map reachability walkers before relying on them for broad
pruning: the emitter's current walker misses nested call arguments and several
statement families. Record root reasons and traverse all AST variants explicitly.

Bounded source replay has to use the emitter's storage and calling widths.
ZeroPage currently admits a Boolean initialized from 256 and stores its low
byte, zero. A source interpreter that treats 256 as true can specialize the
wrong pointer. Apply byte width to declared returns before inferring the
caller's local type. Reject cross-domain conversions and incompatible pointer
shapes unless the replay explicitly models their lowering. Check both the
current and older consumers of a shared proof against executable regressions.

An adjacent indexed store can retire the previous address setup's scratch
only when the intervening instructions and the next setup read no affected
scratch or registers before redefining them. Prove physical disjointness
after zero-page allocation, including partially overlapping aliases, and
keep the full overwrite as the proof for the first store. When switching to
hardware Y indexing, prove that the NMOS wrong-page dummy read stays in
ordinary RAM as well as proving the final address. Test the exact emitted
bus accesses at carry boundaries.

Full-page loop selection can keep X as the actual index high byte and Y
as the low byte. That makes wrap the only point needing a high-byte update.
Bind the entry and trip count to the emitted initializer, comparison and
backedge. An aggregate span across repeated accesses proves range and
storage, but cannot alone identify a loop's entry. Preserve the final
pending stack byte with one balanced PHA/PLA. Protect relative branches
across each splice, even if the sum of code sizes decreases. When index
scratch already lives in zero page, its two bytes can serve as a pointer
until the exit restores the captured index.

An unsigned half-open interval with aligned endpoints depends only on
the high byte. When folding its materialized Boolean into a literal
selector, preserve the carry of the final CMP #0 separately from the
carry used to branch. Keep movable-label and raw image observation checks.
The ordinary placement scan deliberately declines unknown indexed spans.
Reuse closed source replay when it can prove the actual accessed RAM
domain for the whole program.

A full indexed store can close an earlier read's scratch lifetime.
Preserve the loaded A/N/Z and the gap's exact byte operand. CLC or SEC
must dominate any arithmetic that reads carry. Bitwise operators can
leave the changed C/V live until the store setup overwrites them, since
the gap does not read those flags. A whole-loop variant that keeps the
index in registers also has to prove the direct byte operand disjoint
from the source counter, whose resident bytes no longer change on each
iteration.

Full-page loop analysis must recognize the unit increments produced by
earlier passes. For an INC backedge, final V comes from the preceding
destination-high ADC, whose operands and sum stay positive in the proved
RAM span. The final loop compare still sets C/Z. Preserve the internal
increment label and reject outside references before moving it. Record
PRG growth separately when recognizing the shorter original backedge
makes a large timing win cost a few bytes.

For simple instruction selection, use typed operand identity before serializing
assembly. Literal RHS add/sub and literal LHS add can avoid global scratch while
preserving operand effects; constant-left subtraction cannot be commuted. Word
carry/borrow must survive low/high transfer instructions. Reuse source-label
counters only for source control flow; this immediate pass needs no labels.

This file captures durable guidance for future agents. `SESSION_NOTES.md` is the timeline; this file is the compass.

## Keep Contracts Separate From History

Public reference pages should answer what works, how to use it, and where its boundaries are. Do not turn them into chronological lists of every demo or milestone. Keep proof in tests and examples, architecture and future direction in the spec, and implementation history in `AgentWorking/`.

Dependency docs must distinguish packages, external tools, and vendored source. In particular, the vendored Zig parser is a reference copy rather than a linked dependency, while Peddle is compiled only into host tests.

## Loop And ALU Optimization Guidance

Oscar64's `InterCode.cpp` loop prefix/dependency analysis is a useful model:
move loop work only after proving source and scratch stability across every
write and callee. A positive bound alone does not make a conditional read
unconditional. Keep target reads in place, prove first-read dominance, and
track scratch clobbers through callees. Unknown/recursive calls and asm remain
barriers. Preserve label namespaces with explicit metadata rather than guessing
loops from label spelling alone.

Canonical frame offsets prove aliases within a section. Separate sections are
disjoint only within one monotonic origin domain. New origins/logical mappings
can overlap physical storage and must revoke that cross-section proof. Numeric
rodata may be RAM, but an indexed RAM base is insufficient near IO/wrap: bound
the full index range. DLL and software-stack loops remain separate work.

Direct ADC/SBC/AND/ORA/EOR operands are selected from typed scalar values.
Evaluate LHS effects before reading a mutable RHS. For commutative compound
assignments, preserve RHS effects before reading the destination. Low/high
word carry and decimal flags need native equivalence, not just result checks.
Byte-return ABI does not define X: A/X expression widening must explicitly
zero-extend, as ordinary byte bindings do. Never rely on a callee accidentally
leaving X zero. Preserve explicit unsupported syntax diagnostics.

Use the bounded Peddle run-to-RTS API for large paired matrices; it uses the same
microcycle stepper and excludes only the final top-level RTS. It is not suitable
for fixtures that need intercepted hooks. The normal host runner retains its
hook-aware stepping. Keep partial reports explicitly partial, and never reuse
old metrics with a new compiler hash without rerunning the measured cases.

## Bounded Ranges And Shift Selection

A loop-invariant *store* needs stronger proof than a moved pointer copy: it can
change earlier alias reads. Check every pre-capture read against the protected
byte, including the complete indexed range. Track small register upper bounds
through LDY/ASL/TAY/INY for byte/word foreach prefixes. Keep low capture stores
and complete frames so hidden read aliases remain correct; unknown writes must
reject hoisting, even if source captures are immutable. Module/stack lowering
remains separate. Pure numeric low/high extraction in .byte directives has a
known byte count; unresolved symbols or assembler vectors do not.

For shifts, preserve full A/X and carry plus the old final NZ-from-high-byte
behavior in native proofs. Right-shift by eight needs original low bit 7 as
carry even though only the high byte becomes the result. Larger right shifts
get carry from the residual high-byte LSR. Left eight must recover original
high bit 0 before discarding that byte; residual left shifts above eight get
carry from the original low byte. STX/LDX flag restoration can be intentional,
not redundant, when PLA or LDA #0 last changed NZ to describe the low byte.

Use X after spilling input A/X to count memory shifts: DEX costs fewer cycles
than absolute DEC and keeps carry intact. The final load restores result X/NZ.
Shared literal-count entries remove per-site staging; one-bit/byte extraction
forms are inlined under a 14-byte bound. Counts 14/15 on the left still use the
shared loop under that size bound, leaving a measured speed/size decision for
a later pass. Private count slots need not finish at zero. Prune only unused
nonmodule directions/count storage; retain legacy DLL sections and relocations.

## Zig Syntax First, ZeroPage Subset Second

ZeroPage should keep using Zig's own parser as the syntax front door. If source is not valid Zig syntax after ZeroPage's documented preprocessing steps, reject it before lowering. After that, ZeroPage may still reject valid Zig constructs when they are outside the supported subset or do not yet have a clear 6502/C64 lowering.

The preferred shape is "real Zig syntax, smaller semantics." Do not invent C-like shortcuts just because they are easy to parse.

Concrete example: `c64.console.print` uses Zig's formatter convention:

```zig
c64.console.print("LINE {x}\n", .{line});
c64.console.print("READY\n", .{});
```

Do not accept or add new examples using variadic-looking calls such as:

```zig
c64.console.print("LINE {x}\n", line);
```

That call shape is not Zig-ish, even though it would be easy for a tiny compiler.

## C64 APIs Should Reveal Machine Constraints

The `c64` module is not a generic host abstraction. It is a C64-facing library with APIs that should make the machine model visible without making normal code needlessly awkward.

Rules of thumb:

- Ordinary value arguments should accept the currently supported expression grammar, including nested function calls when codegen can preserve values safely.
- Arguments that are really compile-time placement, fixed screen addresses, or 6502 addressing-mode choices may stay narrower. Keep those restrictions explicit and tested.
- If a helper exists mostly for observability, such as `screen.hexAt`, favor predictable lowering and test clarity over pretending it is a general UI library.
- Keep unsupported-but-valid Zig forms rejected with direct diagnostics instead of guessing.

Current examples of this balance:

- `c64.vic.border = expr`, `c64.screen.putAt(x, y, expr)`, `c64.screen.hexAt(x, y, expr)`, `c64.console.print("{x}", .{expr})`, and `c64.time.sleepTicks(expr)` accept value expressions.
- `c64.screen.putsAt(x, y, "TEXT")` keeps the text as a compile-time literal because it lowers directly to fixed screen/color writes.
- Coordinate forms remain intentionally limited where they map to direct or indexed C64 screen addressing.

## Inline Assembly Is An Intentional Exception

Inline assembly is the clearest place where ZeroPage straddles two languages. The user-facing form is Zig-like:

```zig
asm {
    lda #$00
    sta $d020
}
```

The block body is not Zig syntax. ZeroPage extracts asm blocks in a preparser, replaces them with placeholder calls for Zig parser validation, then lowers the original block with 6502/6510-specific validation.

This exception is acceptable because it is named, scoped, documented, and tested. Future exceptions should meet the same bar:

- The syntax boundary is obvious to the programmer.
- The parser/lowering behavior is documented.
- Invalid forms fail clearly.
- Host/unit tests cover both accepted behavior and rejected unsafe cases.

## ABI Simplicity Is A Constraint, Not A Style Preference

ZeroPage currently uses static locals/params, scalar returns in `A`, and compiler-owned scratch slots. This makes generated PRGs simple and inspectable, but it means features such as nested calls need deliberate codegen support.

When broadening expression support, check whether evaluation order can clobber:

- callee static parameter slots,
- `A`, `X`, `Y`,
- zero-page pointers,
- helper scratch bytes,
- C64 memory-mapped registers.

The nested-call fix uses depth-indexed `zeropage_call_arg_N` scratch bytes before copying into callee param slots. Keep that pattern in mind before accepting richer expression forms in more C64 APIs.

## Ownership Metadata Comes Before Physical Colocation

Section ownership markers are the first REU/module roadmap slice. They make ownership visible in generated assembly without moving bytes: function code, function static frames, compiler scratch, runtime data, and module rodata are wrapped in comment-only `zeropage_section_begin` / `zeropage_section_end` markers.

Keep this distinction clear:

- marker ownership is observable metadata for tests and future map output;
- params, locals, returns, hidden payloads, and scratch still have static lifetime under `c64_static`;
- comments must not change PRG bytes, so representative PRG hashes should stay identical;
- physical colocation is the next slice and should build on the marker coverage rather than mixing both changes together.

Use `zig build section-marker-test` for the durable marker proof. It checks marker presence, strips only those comments, reassembles with 64tass, and compares PRG bytes. VICE cannot observe comments directly, so pair this with `zig build vice-test` at major phases to prove the full generated programs still run through the headless VICE UI automation harness.

## Function Static Frames Are Colocated, Not Stack Frames

The second memory-roadmap slice moves function-owned static frame storage to live immediately after each function's emitted code. This is physical placement only. Params, locals, mutable string buffers, fixed local arrays, hidden loop/payload slots, and storage-backed return records still have static lifetime and are still non-reentrant.

Keep this distinction clear:

- scalar returns stay in `A` or `A`/`X`; do not invent static return slots just to satisfy section shape;
- compiler scratch, call-arg temps, runtime data, module strings, and module arrays remain global tail storage;
- PRG bytes and symbol addresses are expected to change after colocation, so compare against a saved baseline and document the movement instead of treating byte differences as regressions;
- this is still not the software stack ABI, heap model, REU far storage, or dynamic module loader.

## Section Maps Are Observability, Not Linker Policy

`.zpmap.json` is emitted from assembly section comments plus 64tass labels after the PRG assembles. It is a concrete address map for tooling and future memory validation, but it does not drive layout yet.

Keep this distinction clear:

- map sections should mirror real emitted labels and addresses, including function-colocated static frames;
- unsectioned helper routines can sit between sections, so map range ends must use the first label after a section end marker, not merely the next section start;
- empty sections are allowed and should use `null` start/end with size `0`;
- adding or changing map output must not change PRG bytes.

## Source Module RoData Uses Real Owners

Module-scope string constants and fixed array constants now carry source-module ownership in the AST. Imported constants use the import alias as their owner, while main-source constants use `main`.

Keep this distinction clear:

- labels stay prefixed exactly as before, such as `zeropage_str_assets_title`, so existing references remain stable;
- rodata is physically grouped by source owner, which is intentional preparation for future module images;
- this is still static linking, not `.zpmod`, relocation, REU caching, or dynamic module loading;
- PRG size should not grow just because ownership becomes more precise, even when label addresses move.

## Local Const Is Not Comptime

ZeroPage local `const` should feel like Zig source syntax, but under the current ABI it is immutable scalar storage in the same static-slot model as `var`. It is not a promise of full Zig comptime evaluation, value propagation, or address-free constants.

Consequences:

- Enforce immutability at ZeroPage lowering/codegen boundaries (`=`, `+=`, `-=`), even though the backing slot is ordinary memory.
- Keep top-level scalar constants and local string/struct constants rejected until the compiler has a real semantic model for them.
- Keep inline asm conservative: `@name` operands should refer to mutable byte locals or params until the asm layer can distinguish read-only operands from write targets.

## Layout Comptime Is ABI Introspection

ZeroPage `@sizeOf`, `@alignOf`, and `@offsetOf` are host-known layout facts over the current static 6502 ABI, not general comptime execution. They should disappear into immediate scalar values and must not become a back door for arbitrary constant evaluation.

Keep the boundary crisp:

- `@sizeOf(T)` returns flattened storage bytes for supported ZeroPage types.
- `@offsetOf(T, "field.path")` follows flattened struct field paths and reports byte offsets from the aggregate anchor.
- `@alignOf(T)` is currently `1` because the ABI is byte-aligned.
- Array lengths can use literal/layout arithmetic, but runtime values, local constants, type reflection, `@TypeOf`, and `comptime {}` stay rejected until a real semantic/comptime model exists.

## Scalar If Expressions Need Explicit Branch Rules

Expression-valued `if` is Zig-shaped and useful immediately after local `const`/inference, but ZeroPage does not yet have Zig's peer type resolution or comptime model. Keep v1 scalar-only and make branch compatibility explicit:

- A bool condition is required, just like statement `if`/`while`.
- Matching bool or matching signed branch types are accepted.
- Unsigned byte/word scalar branches may widen to a word result, with `usize` preserved when either branch is `usize`.
- Mixed signed/unsigned, strings, structs, and payload-capture forms stay rejected until there is a richer semantic layer.

This avoids silently inventing type coercions that would later fight real Zig behavior.

## Block Expressions Are Still Static-Slot Code

ZeroPage scalar block expressions make source look much more like ordinary Zig, but they are not a full lexical-scope model yet. A block-local `var` or `const` is still emitted as a function-static slot under the current ABI.

Consequences:

- Use block expressions for scalar control flow and result selection, not for hiding storage lifetime or enabling shadowing.
- Require explicit `break :label scalar_expr` results so codegen can route all result paths through internal labels.
- Keep string/struct results, payload captures, standalone block scopes, and mixed signedness rejected until a semantic layer can model them deliberately.
- Treat `_ = scalar_expr;` as scalar side-effect evaluation only; pointer, tuple, and string discards stay out of scope.

## Signed Arithmetic Needs Explicit Semantics

Do not treat `i8`/`i16` arithmetic as "just the same bytes" when adding operators whose meaning depends on signed interpretation. Equality and storage can preserve byte patterns, but ordered comparison and multiplication need deliberate signed lowering and tests.

For multiplication v1, ZeroPage supports unsigned `u8`/`u16`/`usize` `*` and `*=` with low-byte/low-word wrap behavior, and rejects signed operands. Future signed arithmetic should define result width, overflow behavior, and 6502 lowering explicitly before enabling `i8`/`i16` operators.

Unsigned bitwise and shift operators are highly useful for C64 code because registers, screen/PETSCII bytes, packed flags, and address math all want masks. They still need explicit type boundaries. ZeroPage supports `u8`/`u16`/`usize` `&`, `|`, `^`, `~`, `<<`, and `>>`, but keeps signed `i8`/`i16` operands rejected until signed integer semantics, casts, and intent are modeled deliberately. Do not enable signed bitwise or shifts just because the same bytes could be manipulated on the 6502.

## Codegen Labels Have Two Audiences

Generated assembly labels are both machine plumbing and human/debug/test anchors. Structural labels that describe source statements, such as `while_N` and `if_N`, should have their own stable counter when tests or debugging workflows rely on their shape.

Internal helper labels introduced by expression lowering, comparison branches, bool materialization, string loops, or other scratch code should use a separate internal counter. This keeps adding one internal branch from renumbering unrelated statement labels.

When unit tests fail on label numbers after a codegen feature, first distinguish "assembly anchor changed" from "behavior changed." If the behavior is fine, preserve the stable structural anchors and move the new helper labels to an internal namespace/counter.

## Language Tests Should Not Depend On The C64 Library

Fast emulator tests now have two jobs, and keeping them separate matters:

- `tests/fixtures/emu/lang/` tests the ZeroPage language subset with only `@import("test6502")`.
- `tests/fixtures/emu/smoke/` and `examples/small/` test C64-facing behavior such as screen RAM, KERNAL calls, VIC/CIA hooks, and convenience libraries.

When adding a language feature, first write a pure `test6502` fixture that asserts values directly. Then add C64 smoke coverage only if the feature changes an IO-facing contract. This keeps the fast suite about compiler semantics instead of accidentally proving that a demo happened to draw the right text.

For low-level compiler contracts such as inline asm preservation, it is acceptable for `test6502` to grow small host-only control hooks. `primeRegs` is the model: it makes the precondition explicit, has no production meaning, and exists so tests can prove the compiler restored `A`/`X`/`Y`/`P` rather than guessing from startup state.

## C64 Keyboard Input Has Two Layers

Buffered PETSCII input and physical keyboard-matrix state are different APIs. `c64.keyboard.readPetscii()` and `waitPetscii()` are KERNAL `GETIN` helpers: they return PETSCII/control bytes from the input buffer, with `0` as no key. They are right for menus, prompts, and simple command input.

Do not describe this as full key-up/key-down matrix scanning. A future held-key or game-control API should read the keyboard matrix or joystick state explicitly and document repeat/debounce behavior separately.

## Arrays Are Fixed Storage First

ZeroPage fixed arrays should look like Zig source where that is useful, but v1 is deliberately storage-oriented. They are C64 lookup tables and small mutable buffers over the existing static-slot ABI, not slices, pointers, stack lifetimes, or full by-value Zig arrays.

Consequences:

- Keep array params, returns, assignment copies, address-of, slices, sentinel arrays, nested arrays, and non-scalar element arrays rejected until the ABI and semantic layer can model them deliberately.
- Use module-scope `const` arrays for lookup tables and local arrays for function-static mutable buffers.
- Keep each fixed array within 255 bytes while runtime indexing lowers through simple 6502 `,Y` addressing.
- Literal indexes should be bounds-checked at compile time; runtime indexes are unchecked until ZeroPage has a runtime-safety story.

## Pointers Are Explicit Storage Addresses

ZeroPage pointers are a narrow bridge to fixed storage and C64 memory-mapped IO. They are word-sized addresses over the static-slot ABI, not a full Zig pointer/slice/lifetime model.

Consequences:

- Keep pointer targets deliberate: scalar and `enum(u8)` pointers cover direct machine addresses; nonvolatile `*Struct` covers mutable flattened struct storage and in-place helpers. Whole arrays, strings, pointer-to-pointer, volatile struct pointers, and many-item struct pointers remain out of scope until their semantics are explicitly designed.
- Keep address-of narrow and obvious. `&local_scalar`, `&array[literal]`, `&local_struct`, and `&local_struct.nested` are stable fixed-storage addresses; `&const`, runtime-index address-of, and temporary address-of should remain rejected.
- `@ptrFromInt` should require an explicit pointer destination type and should stay scalar/enum-only for now so MMIO intent is visible in source. Inferred integer-to-pointer casts and raw integer-to-struct pointers are too easy to misread.
- `*volatile T` means each source dereference emits a real load/store. It is useful for VIC/CIA/KERNAL-facing MMIO, but it is not a substitute for a richer memory model, alias analysis, or runtime safety.
- `[*]T` and `[*]volatile T` are unchecked fixed-address indexing tools. They are for C64 screen/color/MMIO tables and explicit pointer-backed buffers, not slices, array decay, provenance, or lifetime semantics.
- `*Struct` uses Zig-style auto-deref field access over flattened byte offsets. It enables in-place helpers like `applyMove(game: *Game)`, but it does not imply struct-valued field copies, explicit `ptr.*.field` syntax, pointer arithmetic, or full lifetime/provenance semantics.
- Prefer `@intFromPtr` for observability and tests. Do not add pointer comparison or arithmetic until there is a deliberate semantic model beyond indexed fixed-address access.
- Be careful choosing MMIO readback proofs. Host hooks may model simple register reads as RAM-like for test convenience, while real C64/VICE register read semantics can differ by chip/register. For VICE-visible examples, prove volatile reads through known readable memory such as screen RAM unless the specific hardware register's read behavior is part of the contract being tested.
- In-place source shape and smaller output are related but not identical. Pointer-to-struct field lowering can be more verbose than copy-compacted value flow until the backend learns to cache/materialize pointer field addresses more efficiently.

## `@as` Is Type-Shaping, Not Reinterpretation

ZeroPage should accept `@as` where it makes already-supported Zig-shaped source clearer, especially because Zig's behavior tests use it constantly to pin widths. It should not become a back door to casts the compiler has not modeled.

Consequences:

- Allow fitting numeric literals, unsigned widening, matching enum values, bool no-op annotations, and exact same-type pointer annotations.
- Keep runtime narrowing, signed reinterpretation, bool/integer conversion, raw integer-to-enum conversion, enum-to-integer conversion, pointer child/volatile conversion, aggregate casts, slices, strings, and other cast builtins rejected until each has a deliberate semantic model.
- Treat exact pointer `@as` as documentation for an existing pointer type. Pointer provenance, array decay, pointer casts, and lifetime semantics are still out of scope.
- Prefer diagnostics that say "unsupported @as cast" for cast boundary failures; reusing arithmetic or pointer helper errors hides the actual source construct the user wrote.

## For Loops Follow The Storage Model

ZeroPage `for` should feel Zig-shaped where arrays and small count ranges are already supported, but it is still built over static slots. The v1 model is fixed-array and `0..N` iteration, not slices, pointers, iterator protocols, expression-valued `for`, or full lexical scoping.

Consequences:

- Treat payload captures as read-only scalar copies. Mutating the source array should go through `array[index]`, not a pointer payload.
- Keep `for ... else`, pointer captures, labels, string iteration, and general zip iteration rejected until their semantics are deliberately modeled.
- Avoid reusing payload/index names in the same function until ZeroPage has a true lexical-scope model or unique scoped storage mapping.
- Keep `for_N` labels structural and separate from internal scratch labels, like `while_N` and `if_N`.

## Switch Is Scalar Dispatch, Not Full Zig Switching

ZeroPage `switch` should be useful for byte tables, PETSCII commands, state machines, and small word dispatch, but v1 is deliberately scalar. It evaluates the operand once into compiler-owned static scratch storage and compares constant prongs in source order.

Consequences:

- Keep selectors compile-time and scalar: literals, chars, bools, C64 key/PETSCII constants, lists, and unsigned ranges.
- Require `else` for integer switches until a richer exhaustiveness model exists; bool may cover both values directly.
- Reject pointer captures, payload mutation, type/error switches, switch loops, labeled switch control, signed ranges, non-scalar results, and peer-type cleverness until those semantics are explicitly designed. Optional and tagged-union switches are now narrow special cases with explicit payload-copy rules, not a general Zig switch model.
- Keep switch comparison/helper labels internal so adding switch lowering does not perturb structural `if_N`, `while_N`, or `for_N` anchors.

## Composites Are Flattened Storage

ZeroPage structs and enums should unlock useful Zig-shaped state models, but the ABI is still static storage. `enum(u8)` is a named byte tag type, and supported structs flatten their scalar, enum, fixed-array, and nested-struct fields into labels such as `main_game_board_cells`.

Consequences:

- Treat enum tags as typed bytes. Qualified tags and context-typed `.tag` literals are fine, but raw integer assignment, mixed enum comparison, casts, payloads, methods, and reflection stay rejected.
- Treat struct variables as storage aggregates with a narrow value surface. Field-path reads/writes are supported; exact-type struct params, returns, assignment, and const snapshots copy flattened static storage byte-for-byte; and nonvolatile `*Struct` can mutate flattened field paths in place. Arrays of structs, layout-compatible conversion between different struct names, struct-valued pointer-field copies, and full Zig value lifetime semantics are not.
- Const composite locals make all flattened fields immutable. That is source-level immutability over static slots, not a full Zig comptime constant model.
- When adding composite tests, include both direct field paths and nested indexed field paths such as `game.board.cells[i]`, because that is where parser flattening, type lookup, storage labels, and array lowering all meet.
- Include word-sized nested fields in composite tests. A field path such as `board.row.weight` still needs the normal `A`/`X` word convention; otherwise low-byte-only field loading can hide until a host-emulated `expectEqualU16` checks the actual machine result.
- Fixed arrays of structs are array-of-records storage, not parallel field arrays. `items[i].field` must lower as `base + i * @sizeOf(Item) + @offsetOf(Item, "field")`; flattening it to `items_field[i]` would silently change layout and would make later interop/layout builtins lie.
- Keep struct-array payload captures conservative until scoped aggregate payload storage is designed. `for (items, 0..) |_, i| { items[i].field ... }` is the v1 idiom; `for (items) |item|` would imply a read-only struct copy payload and a new static-slot naming story.

## Optionals Use Explicit Presence Storage

ZeroPage optionals are Zig-shaped syntax over simple storage, not the full Zig optional model. Scalar and enum optionals are `{present, payload}` records. Optional pointers use `$0000` as `null`, which is practical on C64 for ordinary user objects but must stay documented: ultra-low-level zero-page code that truly needs address `$0000` should use a non-optional pointer and a separate flag.

When adding optional payload captures, materialize the optional expression exactly once before branching. This matters for call-return optionals because checking presence and then loading payload by re-emitting the expression would call the helper twice. Use compiler-owned scratch storage and emu tests with call-return optionals to prove the capture semantics.

Payload captures are read-only copies under the current static-slot model. Reusing the same payload name multiple times in one function can collide with static labels until ZeroPage grows real lexical scopes, so fixtures should either use unique capture names or add compile-negative coverage for the boundary.

Optional switches use the same exact-once materialization rule as optional `if`: copy the optional into `zeropage_optional_tmp`, switch on presence, and only allow an `else` payload capture when a separate `null` prong handles the null case. This keeps `else => |value|` from accidentally treating `null` as a payload-bearing case.

## Tagged Unions Are Tag Plus Fixed Payload

ZeroPage `union(enum)` is a small static-storage construct, not the full Zig union/comptime/reflection model. Store byte 0 as the tag, reserve fixed payload bytes for the widest scalar/enum/pointer payload, and expose payloads only through `switch` captures.

Consequences:

- Keep union fields out of structs and arrays for v1; nested aggregate storage would need a separate layout and copy audit.
- Reject payload field access like `event.key`. A switch capture is the source contract because it proves the active tag before exposing the payload copy.
- Allow destination-typed `.{ .tag = value }` where the destination union is explicit, but do not generalize anonymous aggregate literals into full peer type resolution.
- Keep payload captures read-only and exact-copy. Mutating a captured union payload would imply references into variant storage, which this ABI deliberately does not provide.

## Unit Tests Need Runtime Pudding

Assembly-shape unit tests are useful, but any unit source snippet that embeds observable `test6502` behavior should have matching host-emulated coverage. The unit can prove labels, helper emission, or absence of bloat; the emu fixture proves the generated machine code actually does the thing.

When auditing a unit test, ask: "If this source contains a value assertion, where does emu execute that assertion?" If the answer is nowhere, add or extend a pure `lang/pass` fixture. This catches stale expectations in unit-only snippets before they fossilize as misleading documentation.

Keep parity fixtures categorized by language area once they grow beyond a focused scenario. Broad catchall files make it harder to tell whether a new compiler-unit behavior has an emu proof, and they make failures harder to bisect. Prefer `parity/scalars`, `parity/control`, `parity/calls`, `parity/arrays_for_switch`, `parity/composites`, `parity/pointers`, `parity/strings_asm`, and `parity/unit_lowering` over new `zig_behavior_recent_*` accumulators.

Keep doing the same after each language pass against Zig's own behavior tests. The valuable misses are often edge shapes rather than headline features: empty fixed arrays, zero-iteration loops, bool switches without `else`, exact-once operands, immutable element writes, and discarded expressions with side effects. Those are cheap to emulate and good at catching lowering assumptions.

## First Optimizations Need Behavioral Proof

Once optimization is enabled, PRG byte identity is no longer the contract. The contract becomes: the host and VICE behavior stays the same, existing PRGs do not grow without an explicit tradeoff, and the size report explains what changed.

Consequences:

- Take a size baseline before changing output, including sample apps and host-emulated fixtures. Keep the generated PRGs, assembly, labels, and VICE plans untracked for diagnosis.
- Add emu fixtures around any pattern the optimizer touches. Unit tests can prove a peephole or helper-pruning rule, but generated machine-code behavior still needs pudding.
- Peepholes must be local and conservative at first. Do not optimize across labels, calls, branches, stack operations, inline asm, volatile pointer accesses, or `test6502` hooks.
- Helper pruning should be driven by feature-use flags, not by hopeful assumptions about which library calls are "nearby." For example, console output should not drag in hex formatting unless a hex formatter is actually referenced.
- Aggregate copy compaction is a backend size optimization over the existing static-slot ABI. It is not hidden return-slot aliasing, not in-place mutation, and not a new struct pointer model.

## Refactors Preserve Bytes First

Before optimization work, backend refactors should treat current PRG bytes as the contract, even when the current assembly looks redundant or suboptimal. Capture a baseline manifest for generated `.prg` files, perform the smallest mechanical moves possible, and compare post-refactor hashes before committing.

Do not fix discovered codegen bugs or clean up inefficient output inside a behavior-preserving refactor. Write the finding down, keep output byte-identical, and handle the bug or optimization in a separate pass with its own tests and intentional output delta.

When splitting the 64tass backend, preserve `tass64.emitProgram(...)` as the public API. It is fine for the first split to keep behavior-bearing methods on the `Emitter` while extracting stateless type/layout helpers, binding data shapes, inline-asm helpers, and literal runtime routine text. Deeper statement/expression/storage extraction should stay mechanical and be guarded by PRG hash comparison.

For the optimization seam, add a pipeline layer before adding the optimizer: `emitUnoptimizedAssembly(...)` should produce the existing assembly, and `finalizeAssembly(...)` should remain a no-op until a dedicated optimization pass. This keeps the API shape ready for peepholes without mixing refactor risk with intentional output changes.

When moving recursive backend helpers out of `Emitter`, avoid wrapper-to-wrapper recursion through inferred error sets. Let extracted modules call their sibling extracted functions directly, and keep `Emitter` wrappers as compatibility shims for existing call sites.

The final pre-optimization refactor should leave expression lowering in place and only isolate low-risk library/runtime call-site emission. Put the optimizer behind an explicit module even while it is a no-op, then make the first real peephole pass a separate intentional output-changing commit with focused tests and PRG diff review.

## Inline Asm Should Use Stable Symbolic Operands

Do not teach users to reach for generated labels such as `zeropage_str_name` or `main_msg_data` from source. Those names are backend details. When inline asm needs compiler-managed storage, add a narrow symbolic operand surface and test the rewriting.

String interop follows that rule: `@name.data`, `#<@name.data`, `#>@name.data`, `#@const.len`, and `@buffer.len` are source contracts. Module string constants stay read-only; mutable string buffers expose raw data and length bytes because that is exactly the fixed storage model the C64 programmer is asking to touch.

## Sample Apps Can Be Larger Than Examples

Use `sampleapps/<name>/` for app-scale ZeroPage programs that are meant to be played or driven end-to-end, and keep `examples/small/` focused on compact language/runtime demonstrations. Give each sample app its own verification path so app flows can use longer VICE automation without slowing or cluttering the small-demo loop.

When a sample app has meaningful pure logic, mirror that logic in a `tests/fixtures/emu/lang/pass/integration/` fixture that imports only `test6502`. ZeroPage cannot yet share arrays of structs, slices, or multi-file app modules ergonomically enough for a single reusable game-core module, so duplicating a one-file core between the playable app and pure fixture is an acceptable v1 tradeoff when the test fixture asserts the duplicated rules exhaustively.

## Future ABI Metadata Should Be Visible Before It Is Executable

For memory-roadmap work, introduce the Zig-shaped source contract before changing generated code. `zeropage_options` now accepts stack region and frame-policy metadata, but only `.static` is executable; `.stack` and `.auto` intentionally fail until the scalar stack ABI exists. This keeps future-facing examples honest and gives diagnostics, import/module boundaries, and tests a stable place to grow.

Keep metadata parsing narrow and strict. Unknown fields, duplicate function overrides, invalid stack regions, imported-module options, and unknown function names should fail loudly rather than silently compiling under the current static ABI.

## Stack Layout Should Be Validated Before Stack Codegen

For the memory roadmap, planning and diagnostics can land before executable ABI changes. The scalar stack planner now proves effective frame policies, offset ordering, slot sizes, hidden loop/payload slots, and scratch reservations while `.stack` still fails before 64tass emission. This gives negative fixtures a real compiler path and keeps `.static` programs byte-stable until the prologue/epilogue slice intentionally changes output.

Keep planner metadata internal until there is a runtime stack implementation. Frame offsets are not C64 addresses and should not be documented as a `.zpmap.json` contract until the stack pointer, growth direction, and bridge rules exist.

## Software Stack Vocabulary Matters

When implementing stack ABI work, say "ZeroPage software stack" for compiler-managed frames in normal C64 RAM, and reserve "6502 hardware stack" for `$0100-$01ff` return addresses and KERNAL compatibility. The first executable stack slice deliberately initializes `sp`/`fp` zero-page pairs, grows upward from the configured base, and supports only leaf `export fn main`; that wording keeps future bridge, recursion, interrupt, and module ABI discussions from blending two very different stacks.

Keep stack slices behavior-first. Unit tests should prove emitted prologue/epilogue and frame-relative load/store shape, but every executable stack feature also needs host-emulated fixtures and at least one C64-visible small demo through VICE. Negative fixtures are just as important: calls, runtime helpers, bad zero-page reservations, oversized frames, and aggregate stack storage must fail before codegen can accidentally produce half-valid assembly.

## Static-To-Stack Bridges Must Preserve Returns While Releasing Frames

The first static-to-stack bridge keeps stack helpers leaf-only and lets the static caller own frame setup/release. That means scalar return registers are live exactly when the caller still needs to restore `sp = fp`; releasing the ZeroPage software stack clobbers `A`, so byte and word returns must be saved in compiler-owned scratch before the release and reloaded afterward.

Do not use the 6502 hardware stack as the easy answer here. Keeping return preservation in explicit compiler scratch matches the current static ABI, keeps KERNAL/hardware-stack assumptions narrow, and makes the memory reservation visible in section markers, docs, and tests.

## Stack-To-Static Bridges Must Save FP On The Software Stack

When stack code calls a static helper, one global `fp` scratch slot is not enough. A static callee may itself use the existing static-to-stack bridge, which rewrites `zeropage_stack_fp`; the original stack caller frame must survive that nested path. Save the caller `fp` pair at the current ZeroPage software-stack `sp`, advance `sp` by two bytes before `jsr`, then pop/restore `fp` after the static call. Scalar returns still need compiler scratch while the bridge pops/restores `fp`, because those pointer operations clobber `A`.

Keep the v1 boundary narrow: scalar params and scalar/void returns only, and no nested call expressions in bridge arguments until nested argument evaluation has a stronger temporary model.

## Stack-To-Stack Bridges Must Evaluate Before Switching FP

Direct stack-to-stack calls need a different ordering from stack-to-static calls. Evaluate bridge arguments while `zeropage_stack_fp` still points at the caller frame, store them in caller-frame compiler scratch slots planned by `frame_layout`, then save the caller `fp` pair on the ZeroPage software stack. Only after those values are secure should the bridge copy args into the callee frame through `zeropage_stack_sp`, set `fp = sp`, reserve the callee frame, and `jsr`.

As with the earlier bridges, return registers cannot be trusted across frame cleanup. Save scalar returns in `zeropage_stack_ret_lo` / `zeropage_stack_ret_hi`, release the callee frame, pop/restore the caller `fp`, then reload `A` or `A`/`X`. This keeps nested stack frames explicit and still avoids the 6502 hardware stack.

## Recursive Stack Calls Need Checked Growth

Recursive ZeroPage software-stack calls should land with overflow guards, not as an unchecked curiosity. Every stack reservation must verify the next-free `sp` against `.stack.base + .stack.size` before writing frame bytes or saved `fp` state. Use a nearby guard-local branch target followed by an absolute `jmp` to the shared trap; direct conditional branches to the trap can exceed the 6502 branch range in larger generated programs.

## Raw REU Must Be Tested Through The Real Register Path

The first REU surface should stay bulk-transfer-shaped and register-driven. `ZeroPage.reu` calls now lower through `$DF00-$DF0A` helper code, and the Peddle host runner models command execution on `$DF01` writes against a 16 MB buffer. That catches the same setup-order mistakes as real code better than a host-only shortcut API would.

VICE REU tests should use the existing full automation harness, not a one-off runner. The sibling harness already launches with `-reu -reusize 16384`; keep future REU demos on that path so host, e2e, and VICE all exercise the same generated PRG.

Do not let raw REU convenience blur the memory model. REU addresses are far storage and not ordinary near pointers; v1 intentionally accepts literal addresses only and rejects zero-length transfers until the 64K hardware special case has a designed source contract.

## Near Heap Allocation Starts Explicit And Nullable

The first near heap slice deliberately exposes only named arena heaps, `allocBytes`, `reset`, and `?[*]u8`. That keeps allocation visible in source, gives out-of-memory a normal `null` result before ZeroPage has error unions and `try`, and avoids promising typed allocation or slices before the ABI can represent them cleanly.

Metadata-only heap declarations should not perturb assembly. Emit heap state and helper code only when a heap API is referenced, and validate final PRG overlap from parsed metadata after assembly instead of relying on emitted heap labels.

Optional pointer test hooks need normalized presence values. A successful pointer like `$9000` is truthy for source `if`, but `test6502.expectSomePtr` should pass `1` for present rather than the pointer high byte; otherwise host tests can fail even when the generated optional pointer value is correct.

Under the current static ABI, repeated optional payload names in one function still collide in generated storage labels. Use distinct payload names in demos and fixtures until lexical static-slot scoping improves.

## Fixed Pools Use Explicit Free Without Ownership Checks Yet

Fixed-block near heaps are useful enough to justify explicit `free`, but the first implementation keeps validation out of runtime code. A fixed free writes the old free-list head into the freed block's first two bytes and makes that block the new head. That gives LIFO reuse with tiny helpers, but wrong-heap pointers, unaligned pointers, double frees, null frees, and non-heap pointers remain documented invalid behavior.

Keep tests honest about that boundary. Positive fixtures should prove allocation order, OOM, reset, and free/reallocate reuse. Negative coverage should reject bad metadata and source-level misuse such as `free` on an arena heap or `free` of a non-pointer. Runtime ownership checking can be a later debug-profile feature if the code-size tradeoff is worth it.

## First Far Handles Stay Opaque And Transfer-Only

The first far REU heap slice should not make REU memory feel like near RAM. `FarBytes` is useful only because it is opaque: it can be captured from `?FarBytes`, copied to or from C64 RAM, and reset through its owning heap, but it cannot be dereferenced, indexed, cast with pointer builtins, assigned to `[*]u8`, or freed through near heaps.

There is still no public `u24` or user-namable far-handle type in ZeroPage. Internally, the compiler can carry a far allocation as a plain storage record: `reu_addr_lo`, `reu_addr_mid`, `reu_addr_hi`, `len_lo`, and `len_hi`. Existing optional machinery is enough for this as long as `?FarBytes` is treated as presence byte plus that non-pointer payload, rather than trying to pretend the handle is a near pointer or a Zig integer type.

Keep the byte arena deliberately boring. Nullable `allocBytes`, explicit transfer helpers, on-demand runtime-owned cursor state, and 16 MB host/VICE coverage establish the memory tier without promising typed far pointers, slices, or direct field access too early. The next typed storage-view slice can add `get`/`set` on top of this handle discipline instead of weakening it.

## Typed Far Views Are Structured Transfers, Not Far Pointers

The first typed REU view layer should make arrays of structs convenient without weakening the far-handle boundary. `ZeroPage.reu.view(Enemy, far, count)` is a compiler-known opaque view over a `FarBytes` allocation: it carries the same internal five-byte payload plus compile-time element type/count metadata, but source still cannot name it as `FarPtr`, index it as `view[i]`, dereference it, cast it, or pass it to near APIs.

`get` and `set` are explicit record transfers. They compute a far address, stage exactly one flattened struct record through runtime-owned C64 storage, and reuse the raw REU copy helpers. That keeps the cost visible and sets up the next bulk `materialize`/`flush` slice, where hot loops can work in near RAM and copy back in larger REU-friendly chunks.

## Far View Materialization Is Explicit Heap-Backed Near RAM

Whole-view materialization should stay explicit: `FarView.materialize("main")` allocates `count * @sizeOf(T)` bytes from a named near arena heap, returns opaque `?NearView(T)`, and copies the full REU view into normal C64 RAM only after allocation succeeds. `NearView(T)` is internally just a two-byte C64 address plus compile-time struct/count metadata, not a user-namable pointer or slice.

`NearView.get` and `NearView.set` use direct C64 RAM loads/stores through pointer scratch and must not invoke REU transfers. `FarView.flush(local)` copies the whole compatible near view back to the original far base. Users own heap lifetime: materialization performs no hidden cleanup, and demos/tests should reset or otherwise manage the chosen near heap explicitly.

## Range Materialization Keeps Near RAM Pressure Honest

`FarView.materializeRange("main", start, count)` should be the default shape for working on large REU collections in small near-RAM windows. It preserves the explicit transfer cost model, but avoids allocating an entire far table when gameplay logic only needs a page-sized working set. Literal bad ranges fail at compile time; runtime out-of-bounds materialization returns `null` before near heap allocation, while runtime out-of-bounds `flushRange` is still documented invalid behavior because the API returns `void`.

Keep `NearView(T)` opaque even for ranges. Its payload remains a two-byte C64 address plus compile-time struct/count metadata; the reduced count is what lets `flushRange` copy exactly the materialized window back to `far_base + start * @sizeOf(T)`. Tests should prove both literal and runtime starts, OOM/null behavior, and high REU addresses so the range path stays a transfer API rather than a disguised far pointer.

## Module Metadata Before Module Loading

Dynamic-module work should start with validated, inspectable metadata before binary `.zpmod` loading. `zeropage_module` now proves the source contract, scalar stack-export boundary, dependency ids, section references, and empty relocation-table shape through `out.prg.zpmod.json`, while deliberately avoiding loader/runtime behavior. That keeps errors compiler-side while the ABI is still cheap to adjust.

Keep the export boundary narrow until executable module objects exist. Stack-frame scalar functions are allowed because their call lifetime is explicit; static-frame-only helpers, aggregate storage, far handles, far views, near views, and heap-owned opaque values stay rejected so a future jump-table/export ABI does not inherit hidden global-storage assumptions.

## Binary Modules Start As Format Contracts, Not Loaders

The first `.zpmod` binary writer should be treated as an observable file-format contract. It now records deterministic little-endian metadata, a simple additive checksum, exported jump-table entries, and selected code/rodata bytes, but it does not relocate, reserve a RAM window, allocate REU cache, or make exports dynamically callable.

Keep tests focused on inspectability: magic/version, counts, offsets, checksum, export order, jump-table `JMP absolute` bytes, dependency/section parity with JSON, and no sidecars for non-module programs. Loader work can then evolve from a locked binary shape instead of trying to debug format and runtime behavior at the same time.

## Relocation Discovery Should Be Explicit Compiler Metadata

Do not discover module relocations by scanning payload bytes. ZeroPage controls codegen, so the compiler can emit zero-byte labels plus `; zeropage_relocation ...` comments immediately before supported absolute operands such as module-local `JSR helper`. 64tass preserves the labels for address calculation, ignores the comments for PRG bytes, and the sidecar writer can compute `payload_offset` from labels instead of guessing from opcode patterns.

Export ordinals are now generated from `zeropage_module.exports` declaration order. Keep that order stable and visible in JSON, binary export records, and the jump table until there is a deliberate explicit-ordinal source syntax. Module-export call graphs should stay narrow: reachable helpers must be scalar stack functions, and static-frame helpers, runtime/C64 helper calls, inline asm, and opaque storage boundaries should fail before the sidecar silently omits a relocation.

`#<label` and `#>label` must be modeled as separate byte relocations, not fake `abs16` records. The loader will patch distinct operand bytes, so ZeroPage now records `lo8` and `hi8` independently with their own `payload_offset`, target, and addend. Keep address-taking inside module export call graphs deliberately narrow until loader-owned mutable state exists: immutable module rodata scalar/enum array element addresses are valid, while locals, static-frame slots, mutable string buffers, compiler/runtime scratch, heap state, and labels outside the selected payload should fail before sidecar emission.

## Loader Windows Should Be Validated Before Loading Exists

`zeropage_options.modules` now records the future C64 load window and REU module cache as source-level ABI metadata, but still emits no loader code. That is the right order: page alignment, reserved-memory overlap, stack/heap overlap, REU-heap overlap, final PRG overlap, and selected `.zpmod` payload fit are all cheap compiler-side checks and painful runtime surprises.

Keep loader records as contracts until relocation application is proven. JSON sidecars expose readable load-window/cache requirements; binary `.zpmod` files set a loader flag and append a fixed loader record before the payload. The next useful proof is an off-target relocation-application simulator that can patch a window image from sidecar records before any KERNAL disk IO, REU cache population, banking, registry, or dynamic calls land.

Relocation patching should be proven off-target before loader code exists. The non-executing simulator now builds the same jump-table-first payload image as the binary writer, applies `abs16`, `lo8`, and `hi8` records against the configured load-window base, and reports target math plus before/after operand bytes in `.zpmod.relocsim.json`. Keep this as the debug oracle when the runtime loader starts copying bytes into RAM; if simulator and loader disagree, the loader is suspect first.

## Runtime Loader Must Stay Matched To The Simulator

The first `ZeroPage.module.load("id")` implementation should use the relocation simulator as its contract, not as adjacent documentation. The runtime helper now stages the current module's jump-table-first payload through the configured REU cache, copies it into one C64 load window, and applies `abs16`, `lo8`, and `hi8` patches with the same target formula as `.zpmod.relocsim.json`.

Keep this loader intentionally single-module and current-module-only until registry state exists. It returns `false` for missing REU and `true` after copy/patch, but it does not resolve dependencies, unload, expose `isLoaded`, dispatch dynamic export calls, stream from disk, use UCI, or bank ROM out. Host tests should compare loaded window bytes against simulator-predicted patches before trusting broader VICE smoke results.

## Registry State Before Module Calls

Make the loaded window observable before generating export-call stubs. The first registry is deliberately one current-module record: a loaded byte plus a reserved refcount byte, with ids still validated at compile time rather than stored on target. `load` is idempotent once the loaded flag is set, and `isLoaded` reads that flag; unload, dependency ownership, refcount decrement, disk loading, banking, and dynamic calls remain separate future slices.

## Unload Clears Lifecycle State, Not Memory

The first `ZeroPage.module.unload("id")` should be honest about what it owns. It clears the one loaded byte and reserved refcount byte so `isLoaded` becomes false and a later `load` takes the full copy/relocation path again, but it does not erase the load window, reclaim the REU cache, snapshot mutable state, or imply dependency ownership. Tests should prove reload repairs stale or corrupted window bytes so the registry flag, not leftover memory contents, remains the callability contract.

## Dynamic Calls Must Use The Relocated Window

The first `ZeroPage.module.call` path must not accidentally call the original statically linked export label. Runtime `load` now patches the copied jump-table operands in the load window, and dynamic call sites `JSR` through that window entry only after checking the registry loaded byte. Unloaded calls return `null`, so stale bytes left behind by `unload` remain non-callable. Keep host tests proving `$c000` jump-table operands point at relocated payload addresses, not original PRG labels.

## Disk Loading Starts With Explicit Staging

The first `ZeroPage.module.loadFromDisk("id", "filename")` path uses an explicit C64 staging buffer, not direct disk-to-REU magic. The compiler emits a `.zpmod.disk.prg` whose load address is the configured `.modules.disk_staging.addr`; runtime KERNAL `LOAD` places bytes there, then the existing REU-cache-to-load-window relocation path takes over. This keeps file IO, REU transfer, and relocation patching as separate observable contracts.

Host emulation should not lag behind VICE once a loader path is meant to work. The Peddle runner now models enough KERNAL disk state for modules: `SETNAM`, `SETLFS`, successful `LOAD` from a virtual mounted file table, carry-set failure for missing files, C64 staging bytes, REU-cache bytes, and registry/load-window assertions. Keep both paths: host EMU should prove deterministic success and failure quickly, while VICE remains the proof that the same generated payload works through the real mounted-D64 harness.

Separate module-payload host tests are useful before the runtime can load arbitrary external packages, but they are transitional. The target still never consumes sidecars; the compiler may consume them to prove export ordinals, relocation records, and ABI shape, so `zeropage-emu-module` fixtures must mount separately compiled payload sources that match the sidecars supplied to the host build. This is still valuable: it proves the host app really loads disk bytes from another compiled source instead of its own embedded sidecar.

## KERNAL Disk Filenames Are C64 Bytes

`loadFromDisk("id", "enemyrt")` should let source stay readable, but the bytes handed to KERNAL `SETNAM` must match the CBM directory entry. `c1541` stores that filename as uppercase PETSCII/CBM bytes (`ENEMYRT`), so emitting lowercase ASCII made the mounted-D64 VICE proof fail with a real file-not-found path. Keep disk filename encoding explicit and tested at the assembly-byte level whenever expanding KERNAL file APIs.

## Preload Is Startup Policy, Not Autoload

`.modules.policy.current.mode = .preload` should lower to one explicit startup call to the existing disk loader before `main`, not to hidden dynamic-call autoload. `ZeroPage.module.call` must stay checked against the registry loaded byte, so host tests can still observe the unloaded path when the Peddle runner starts at `main` and VICE can prove the BASIC-entry preload path with a mounted D64.

## On-Demand Loading Belongs At Explicit Calls

`.modules.policy.current.mode = .on_demand` should be lazy only at explicit `ZeroPage.module.call("id", "export", .{...})` sites. The call site checks the current-module loaded flag, invokes the existing disk loader only when needed, rechecks the flag, and still returns `null` if loading fails. Do not hide this behind ordinary dotted-call lowering; the source should keep module-loading cost and failure visible until a real multi-module resolver exists.

## Dependency Metadata Can Precede Dependency Loading

Dependency ids are now valid, ordered, inspectable module metadata before they are executable loader inputs. Keep source-order dependency ordinals stable in JSON and binary sidecars, reject duplicates early, and continue making `load`, `loadFromDisk`, `isLoaded`, `unload`, `call`, `.preload`, and `.on_demand` require empty `.deps` until a real multi-module registry and resolver own dependency lifetimes.

## Registry Shape Before Dependency Loading

The first multi-module registry should be a validated, inspectable plan before it owns runtime rows or file IO. `.modules.registry.capacity` now commits source to enough rows for the current module plus dependencies, rejects self-dependencies, and emits JSON/binary current/dependency rows plus edges. Keep dependency loading, D64 search, refcount ownership, and dynamic dependency calls separate so tests can prove the ABI shape without pretending dependencies are executable.

## Package Filenames Before Dependency Resolution

Dependency filenames and package order should be validated and inspectable before a resolver owns loading. `.modules.disk_manifest` now records the current module filename and exactly one filename per declared dependency, emits JSON/binary plus `.zpmod.diskmanifest.json` rows in dependency ordinal order, and keeps executable APIs empty-deps-only. This gives tooling and future D64 packaging a stable contract without implying dependency REU cache slices, target registry rows, or dynamic dependency calls exist yet.

Dependency graph shape should be validated before it owns runtime behavior. `.modules.dependency_graph` now proves direct/transitive ids, deterministic row order, manifest coverage, self-dependency rejection, and cycle detection entirely in parser/sidecar/fixture coverage. That keeps future graph loaders from discovering bad package shape on a C64 target where diagnostics and rollback are expensive.

## 2026-05-17 - Dependency Rows Can Be Observable Before They Are Loadable

Target-side registry rows are useful before dependency loading exists. Row `0` remains the current module and keeps the legacy `zeropage_module_registry_loaded/refcount` labels; dependency rows follow dependency ordinals, start unloaded, and can be read by `ZeroPage.module.isLoaded("dep_id")`. Each row records planned REU cache slot math from the manifest and load-window size, but only current-module load/unload/call mutate row `0`. Keep this separation: dependency rows are observability and ABI shape before later slices give them loading, activation, call, and refcount behavior one step at a time.

## Dependency Cache Residency Is Not Callability

Manifest-driven dependency loading should stop at the REU cache boundary first. `ZeroPage.module.loadDependency("dep_id")` can prove filename lookup, KERNAL staging, loaded-length calculation, staging-to-REU copy, and dependency row loaded/refcount state without implying the dependency is relocated, resident in the C64 load window, export-resolved, or dynamically callable. Keep host and VICE tests checking both sides of that boundary: REU bytes and row flags may change, but row `0` and the shared load window remain current-module territory until a dedicated activation design lands.

## Dependency Dispatch Is Compile-Time Known, Not Reflection

The DLL path should stay small enough for 6502 realities: dependency export names, ordinals, scalar signatures, stack-frame offsets, payload length, and relocation patch bytes are compiler-side facts from sidecars. Runtime late dispatch should only check whether a registry row is loaded, activate that row from REU into the shared load window when needed, and `JSR` through `load_window + ordinal * 3`. Do not add target-side method-name lookup, signature parsing, JSON/binary metadata parsing, or reflective dispatch tables; the source-visible `ZeroPage.module.call("dep", "export", .{...})` is checked at compile time and remains nullable only because loading/activation can fail at runtime.

## Typed Module Bindings Are The Ergonomic End State

The current string-literal `ZeroPage.module.call("dep", "export", .{...})` shape is a useful bring-up surface because it makes late dispatch, sidecar validation, nullable failure, and loader cost obvious while the ABI is still moving. It should not be mistaken for the final user-facing style. The long-term goal is a typed binding such as `const EnemyAI = ZeroPage.module.import(.enemy_ai, .{ .score = fn (u8) u8 });` with calls like `EnemyAI.score(value)` lowering to the same compile-time-known row/ordinal/signature path. Module ids can become comptime identifiers/tags in source; target code still must not store or compare names. Now that dependency unload and active-window ownership have concrete semantics, typed bindings are the right next ergonomic layer as long as they do not change the underlying ABI.

## Dependency Unload Clears Callability, Not Bytes

`ZeroPage.module.unloadDependency("dep_id")` should release dependency ownership and clear `zeropage_module_registry_active_row` only on the final release when that row owns the shared load window. It must not pretend to erase the C64 load window, REU cache slot, staging buffer, or payload bytes. Tests should prove the sharp edge directly: after final release, stale bytes can remain visible, but dependency calls return `null` until `loadDependency` or `acquireDependency` restores the row state.

Typed module bindings must stay compile-time sugar, not a second module ABI. `ZeroPage.module.import(.dep_id, .{ .method = fn (T) U })` is useful because it removes stringly source calls and catches signature drift against dependency sidecars, but the generated target code should be the same row/ordinal/relocation path as `ZeroPage.module.call`. Do not let bindings introduce target-side method-name strings, signature tables, JSON parsing, or reflection; the C64 runtime should still only manage loaded rows, active-window ownership, and jump-table dispatch.

Typed dependency lifecycle methods should be boring aliases, not new state. `Binding.load()`, `Binding.acquire()`, `Binding.isLoaded()`, `Binding.release()`, and `Binding.unload()` are clearer source spelling for the same dependency ensure, explicit acquire, loaded-byte read, and release helpers. Tests should keep proving that final release clears callability while leaving stale bytes alone, and that reload restores the same row/active-window behavior as the low-level API.

Typed current-module bindings should be the same kind of boring alias over row `0`. `Binding.load()`, `Binding.loadFromDisk("file")`, `Binding.isLoaded()`, `Binding.unload()`, and typed export calls are easier to read than the stringly bring-up API, but they must still lower to the existing current-module helpers and checked ordinal dispatch. Keep proving the generated assembly does not contain binding names, because that is the easiest way to catch accidental target-side reflection.

Persistent module state needs an explicit byte-range contract before runtime copying. `.modules.state.current` records load-window-relative ranges and an REU snapshot slot, while code and rodata stay immutable payload bytes. Keep snapshot ranges nonzero, non-overlapping, and sidecar-visible before adding save/restore helpers, so unload semantics remain honest about which mutable bytes are preserved and which stale bytes are merely leftovers.

Current-module state must be saved before losing active ownership of the shared window. The runtime now snapshots row `0` ranges before current unload clears callability and before dependency activation overwrites the window, then restores those ranges after current load/loadFromDisk/reactivation patches the payload. Keep that order: payload copy and relocation rebuild immutable code/rodata, then the saved mutable ranges overlay the restored module image.

Dependency state should become sidecar-visible before it becomes executable. `.modules.state.deps` reserves deterministic per-dependency snapshot slots in dependency ordinal order and records explicit load-window-relative byte ranges, but runtime hooks should land separately so dependency activation does not start guessing which stale bytes are meaningful.

Executable dependency state must be saved before the shared load window changes hands. Dependency activation should save the currently active persistent row, rebuild the target payload and relocation patches, then restore the target row's saved ranges. Active dependency unload should also snapshot before clearing callability. This keeps explicit byte ranges meaningful without dirty tracking, runtime metadata parsing, or pretending stale bytes are authoritative.

Dependency preload should mean REU-cache residency, not callability. Startup dependency policy should call the same manifest-driven row loaders in dependency ordinal order, set loaded/refcount bytes on success, and leave the shared C64 load window inactive until an explicit dependency call performs activation and ordinal dispatch.

Dependency on-demand should live only on explicit dependency call paths. A low-level `ZeroPage.module.call` or typed binding call may run the manifest-driven row loader when its direct dependency row is unloaded, but it must recheck the loaded byte and still return `null` on failure; the target runtime still does no name lookup, signature reflection, transitive dependency resolution, or ordinary dotted-call autoload.

## Dependency Refcounts Are Ownership, Not Call Counts

Direct dependency rows now separate idempotent residency from explicit ownership. `loadDependency`, typed `Binding.load`, dependency preload, dependency on-demand, and `loadDependencyGraph` are ensure paths: they load an unloaded row and set refcount `1`, but already-loaded rows stay unchanged. `acquireDependency` and typed `Binding.acquire` are the only repeated ownership increment paths, capped at `255`; `releaseDependency`, typed `Binding.release`, and compatibility `unloadDependency` decrement, with only final release clearing callability and active-window ownership. Keep this split: goals/policies should make modules resident, while ownership APIs should be opt-in so ordinary calls and graph/policy helpers do not silently consume refs.

## Graph Loading Stops At REU Residency

Manifest-driven dependency graph loading should reuse the ordinary ensure row loaders in topological order and roll back only the rows newly loaded by that API call. It must not imply transitive exports are callable: `loadDependencyGraph` gets prerequisite payloads into REU cache slots, while activation and ordinal dispatch remain limited to direct dependencies with compile-time sidecars. Separate module payload fixtures also need ABI-equivalent loader metadata, including the same staging address, because KERNAL `LOAD` honors the payload PRG's load address in both host EMU and VICE.

Idempotency is worth preserving as a first-class loader contract. Policy-driven loading and graph loading are about satisfying residency goals, not claiming ownership, so they should be small and fast no-ops when rows are already loaded. The target runtime can still support explicit ownership through one refcount byte and acquire/release helpers; there is no need for goal bitsets, target-side names, or reflection to make those concepts coexist.

## Module Scratch Must Relocate With Payload Code

When a module payload uses compiler stack-return scratch such as `zeropage_stack_ret_lo` / `zeropage_stack_ret_hi`, those operands must be relocation records and the compiler scratch section must be selected into the module payload. Otherwise relocated dependency code can write to the original PRG address range instead of payload-local scratch, corrupting the host program after activation.

## Graph-Aware On-Demand Is A Cold-Path Policy

Graph-aware dependency on-demand should not make every dependency call pay for graph logic. The call site should first read the direct dependency row's loaded byte; only the cold unloaded branch should run `loadDependencyGraph`, and even then it activates only the direct dependency for ordinal dispatch. That preserves the fast already-loaded path and keeps transitive prerequisites as REU-cache residency, not target-side names, reflection, or transitive callability.

Graph-aware dependency preload is still a residency goal, not callability. Startup may use the graph loader to cache prerequisites before the direct dependency, but it must leave `zeropage_module_registry_active_row` alone and wait for an explicit direct dependency call to copy the row into the shared window and dispatch by ordinal.

Typed `Binding.loadGraph()` should stay as boring as the other typed lifecycle methods. It is source ergonomics over `loadDependencyGraph`, not a new graph binding ABI: the target still sees only row bytes, manifest filenames, graph loader scratch, and ordinal dispatch after an explicit direct dependency call.

## Graph Acquire Is Ownership, Not Residency

Keep `loadDependencyGraph` idempotent as the fast residency goal: it ensures graph rows are cached in REU and leaves already-loaded rows alone. `acquireDependencyGraph` is the explicit ownership path and must increment every already-loaded row in the requested graph, roll back only refs acquired by that call on failure, and still avoid target-side graph names, reflection, or transitive export callability.

## Graph Release Clears Ownership, Not Bytes

`releaseDependencyGraph` should mirror graph acquire in reverse topological order and delegate final-release behavior to the existing row release helpers. It clears callability and active-window ownership only when refcounts reach zero; it must not erase REU cache slots, staging bytes, or stale load-window bytes, because registry state remains the authority for whether a dependency can be called.

Typed graph ownership bindings must stay boring sugar. `Binding.acquireGraph()` and `Binding.releaseGraph()` lower directly to the low-level graph ownership helpers, so the runtime still sees only row indexes, refcount bytes, REU cache slots, and jump-table ordinals. No target-side binding names, graph names, signatures, or reflection tables are introduced for the ergonomic form.

Graph-node callability should begin with compile-time sidecar acceptance, not runtime behavior. Accepting sidecars for transitive graph rows lets the compiler validate ids, load-window compatibility, scalar signatures, payload size, and relocations before any dispatch path exists. That keeps the eventual call path row/ordinal-known and prevents graph metadata from becoming target-side reflection.

Low-level graph-node calls should be explicit and cold-path honest. A transitive row can be dispatched only when source names it, compile-time sidecars validate its scalar export ABI, and some earlier residency path has loaded the row into REU. The runtime still only checks the row loaded byte, activates the row into the shared window when needed, patches known relocation bytes, and jumps by ordinal; it should not autoload transitive rows or inspect graph metadata on target.

Typed graph-node bindings are just compile-time sugar over explicit graph-node calls. Allowing `FixedMath.bias(value)` improves source readability, but the binding must still be module-scope, sidecar-validated, and row/ordinal-known; lifecycle roots stay on direct dependencies so transitive-only bindings cannot secretly become loaders, graph owners, or target-side reflection points.

## Multi-Window Metadata Is Residency Planning, Not Banking

Extra load windows should land first as validated, sidecar-visible C64 RAM contracts. `.main` stays the compatibility window and current-module home, while dependency rows can be assigned to named ordinary RAM windows before runtime activation uses them. Keep the mental model clean: this is compile-time row/window planning for future relocation and dispatch, not target-side window names, reflection, ROM banking, or automatic allocation heuristics.

Window-aware activation should stay row/ordinal-known and per-window small. A dependency assigned to `.aux` should save only the row currently active in `.aux`, copy and relocate into `.aux`, set `zeropage_module_registry_active_row_aux`, and dispatch through the configured visible-RAM aux base plus `ordinal * 3`; it should not evict row `0` from `.main` or make the target parse window names. Multi-window support is ordinary RAM residency planning, not banking.

Typed multi-window bindings must remain exactly the ergonomic layer, not a second ABI. `MathCore.add(value)` and `FixedMath.bias(value)` should lower through the same assigned-window activation helpers as low-level `ZeroPage.module.call`: compile-time sidecars pick row/window/ordinal, runtime checks loaded and active bytes, then jumps through the assigned window. Tests should keep looking for leaked binding names so this never drifts into target-side reflection.

VICE caught the important distinction between "RAM exists underneath" and "RAM is currently visible to the CPU." Extra load windows must use ordinary visible RAM until a banking slice explicitly owns BASIC/KERNAL ROM mapping. `$a000` is tempting for a large window, but without processor-port banking a `JSR $a000` enters BASIC ROM in VICE; use visible RAM such as `$6000` for current multi-window tests.

BASIC-under-RAM support should start as explicit metadata, not implicit address magic. `.bank = .ram_under_basic` makes the `$a000-$bfff` contract sidecar-visible and testable before runtime helpers toggle `$0001`; default `.visible` windows keep rejecting ROM ranges for extra windows so accidental BASIC ROM dispatch stays caught.

Current-module `$a000` execution needs banking around every CPU-visible touch, not just the final `JSR`. The row-`0` loader has to expose RAM under BASIC for REU copy, relocation patches, state save/restore, and ordinal dispatch, then restore `$0001` immediately. Banked dispatch must preserve returned `A`/`X` while `$0001` is restored, and tests should assert the processor port returns to `$37` so the rest of the program is not left in a surprising memory map.

Dependency BASIC-bank windows should be treated as just another assigned-window mode, not a separate dispatch ABI. The compiler still chooses row/window/ordinal at compile time; runtime only wraps that window's activation, state save/restore, and `JSR assigned_window + ordinal * 3` in local `$0001` save/restore. Host tests should inspect underlying `$a000` RAM, while VICE should mostly prove behavior and port restoration because monitor reads after restore see BASIC ROM again.

KERNAL-under-RAM support should start with the same explicit metadata discipline as BASIC banking. `.bank = .ram_under_kernal` is a sidecar-visible `$e000-$ffff` contract first; executable support then has to prove HIRAM toggling, interrupt-state preservation, return-register preservation, and `$0001` restoration around every CPU-visible copy, patch, state, and dispatch operation.

Current-module KERNAL-bank runtime has a stricter stack hazard than BASIC banking. Because `php` leaves status on the 6502 hardware stack until the wrapper restores it, banked dispatch must preserve returned `A`/`X` in runtime scratch bytes rather than pushing them above the saved status. Keep any KERNAL-call surface from `$e000` explicit and metadata-gated; the first accepted surface is the narrow console trampoline ABI.

Dependency KERNAL-bank windows should reuse the same compile-time assignment model as visible and BASIC windows. The runtime only needs the assigned active-row byte, REU cache slot, relocation patch bytes, and ordinal; the HIRAM wrapper is local around activation/state/dispatch and must leave `$0001` plus processor status restored before returning to ordinary program code.

## KERNAL-Bank Export Safety Is Compile-Time Metadata

Exports that execute from `.ram_under_kernal` cannot call KERNAL-backed helpers while HIRAM is hidden unless a dedicated trampoline ABI exists. Keep this as compiler-known metadata: JSON and binary sidecars record `requires_kernal_rom` and `kernal_trampoline_safe`, dependency sidecar readers default older metadata to false, and current-module/dependency validation rejects unsafe KERNAL-bank placements before codegen. The C64 target should never inspect export safety flags at runtime.

Shared KERNAL-bank wrappers must not leave saved processor status on the hardware stack across a module `JSR`. Save status into runtime-owned data before entering hidden-KERNAL code, then restore it with `pha`/`plp` after `$0001` is restored. Banked dispatch can preserve returned `A`/`X` in runtime scratch across wrapper exit, but that restore changes flags; do not document final status flags as an export-return guarantee until a later ABI explicitly preserves them through optional-result packaging.

## KERNAL Console Trampoline Relocation

KERNAL console trampolines are not just alternate `JSR` targets. Once a console helper body executes from `$e000-$ffff`, every absolute data operand and every internal helper `JSR`/`JMP` in that helper body must be relocation-tracked against the assigned KERNAL-bank window. Selecting only the export function code is not enough; runtime console data such as cursor slots and saved status must be selected into the module payload too.

The trampoline wrapper itself must be bank-stable. It runs while HIRAM remains hidden, so it cannot restore `$0001` before returning to code that still lives under KERNAL ROM. Let the outer KERNAL-bank dispatch wrapper own `$0001` restoration after the export returns.

Module-local console output has module-local console state. Current and dependency exports that print through the KERNAL-bank trampoline use payload-local cursor/string state, independent from the caller's ordinary console runtime. Demos that need both banners visible should position output deliberately rather than assuming shared cursor state.

Runtime loader relocation patchers may see anchors that belong to the main program as well as selected payload anchors. Guard patch stores so only addresses inside the active load-window payload are written; otherwise a main-program relocation anchor can corrupt KERNAL-bank window bytes during activation.

## Product Renames Include Protocol Surfaces

A complete compiler/language rename is broader than user-facing prose and executable names. Treat source extensions, package names, built-in imports, options/module declarations, environment variables, generated sidecar suffixes and schema ids, binary magic values, test directives, assembly/runtime symbol namespaces, C bridge names, VICE plan ids, fixture paths, and sample-app slugs as one coordinated compatibility surface. Audit both file contents and filenames after the change, while excluding the host Zig compiler's own legitimate terminology.

VICE disk automation must put the owning demo PRG first in generated D64 directory order. The harness autostarts `LOAD"*",8,1` when a disk is mounted; if a module payload is the first entry, VICE loads that payload and returns to BASIC instead of starting the test program. Write a `boot` entry first, followed by the module payloads that the running demo loads through KERNAL.

## Named Regions Are Shared Reservations, Not A New Allocator

Keep one declarative region table and make stack, near/far Memory Arenas, resident placement, DLL windows/staging, and REU caches consume it. The region layer owns names, address spaces, bank visibility, range validation, and overlap rejection. Each consumer still owns its lifecycle and runtime semantics. This prevents arena configuration and DLL configuration from becoming competing memory planners.

Load address, entry address, load-memory address, and run-memory address are separate concepts. Preserve that distinction in source options, generated labels, maps, tests, and documentation. Startup-copy placement can stay tiny on 6502 when labels are assembled at VMA with a logical segment and the runtime only copies exact LMA bytes before `main`.

Banked resident placement needs the same discipline as banked module dispatch: save status and `$0001`, expose RAM only for the copy or call, preserve returned `A`/`X`, then restore the machine mapping. Do not allow resident code to retain an ordinary pointer to a hidden constant; keep hidden references within the same placement until a bank-aware data access API exists.

Sparse direct placement and relocatable DLL payloads should not be conflated. A contiguous PRG must represent the gap to a far direct segment, while a DLL payload must remain compact and relocatable. Use direct placement for genuinely resident absolute bytes, startup-copy for compact fixed-VMA resident bytes, and the module/REU cache for loadable or evictable code.

## Hosted REU Allocation Must Have One Authority

ReadyOS compatibility proves that a ZeroPage application can reimplement TUI/input micro-modules and use the resident shim's terminal vectors without linking the C modules. The harder boundary is REU ownership: schema-5 logical tokens, physical-bank mappings, resource types, loaded status, and eviction are ReadyOS state. A hosted ZeroPage loader must consume opaque ReadyOS allocations and map module acquire/release to the ReadyOS registry; it must not reserve a parallel fixed `.reu_cache` range or maintain competing loaded bits.

ReadyOS snapshot restore and application resume are different operations. Restoring `$1000-$c5ff` followed by an unconditional cold `main` produces a clean restart, which is correct for the current sample but not stateful resume. Keep a fixed `$1000` host trampoline, distinguish cold/resume lifecycle hooks, and resolve any per-app REU tail through the logical-token mapping rather than caching a physical bank number.

## ReadyOS Visual Tests Must Wait For A Completed Frame

ReadyOS-style 40-column screens with live mode/state read best with the common three-row title window: title embedded in the top edge, one status row inside the box, and a continuous bottom edge. Use one coherent content structure and bottom command text rather than an application-wide border plus unrelated panel fragments. Help should use the established F8 centered-window vocabulary and keep ReadyOS navigation visible.

Screen automation can match a header while the remainder of a ZeroPage frame is still being painted. Gate visual captures on content emitted at the end of `render`, such as the final status or command row, rather than on the first title/subheader text. Keep UI/gameplay, cached F2/F4 switching, and Ctrl-B return in fresh VICE sessions when the remote monitor is prone to cumulative REU-transition pipe failures; this isolates transport state without replacing real key inputs.

Do not stride a C64 screen column with an 8-bit index until it reaches a guessed wrapped sentinel. A +40 sequence cycles through offsets modulo 256 and can paint unrelated rows before termination. For fixed ReadyOS popup rectangles, either use a true 16-bit address/row counter or make the fourteen interior row addresses explicit and audit all four edge endpoints.

## ReadyOS Gameplay Rendering Should Be Damage-Driven

On a 1 MHz C64, clearing and repainting a 1000-cell text screen after every key is both visibly wrong and unnecessary. Keep a tiny previous-state snapshot and make the normal input path update only changed board cells, the one-character turn value, or the one status row. Reserve a full render for initialization, mode replacement, and restoration after a destructive overlay.

Persistent game-over overlays need their own redraw boundary. Paint changed game cells first, then the modal once; after that, suppress board damage until restart. Otherwise an ignored queued key can still redraw the selected cell through the popup even though game state no longer changes.

## Frame Polling And Static Display Accounting

For one video-frame event, poll the ninth raster bit in `$d011` through a low/high transition. The current `sleepFrames` helper polls only `$d012 == 0`, which also matches line 256; do not assume it counts full video frames. `examples/repeated_hello.zp64` avoids that helper without changing the runtime. A future helper fix needs dedicated timing coverage.

When comparing tiny display programs, derive instruction/table spans from assembled labels as well as section maps: the current console runtime is not separately mapped into code and row-table sections. Count the PRG header only on disk, writable static slots only once inside the loaded image, additional zero-page scratch separately, and screen/color storage explicitly. Console output currently folds letter case. A direct console example cannot substantiate a buffered reference's visual timing or cycle claims through static inspection alone; see `AgentWorking/REPEATED_HELLO_ANALYSIS.md`.

Compile-only C comparisons need memory interval accounting. cc65 can overlay BSS on discardable ONCE startup bytes, so adding BSS size to the whole loaded image double-counts those addresses. Oscar64's map ZEROPAGE section does not include native pseudo-register scratch: inspect its native listing too. Keep stock software-stack budgets separate from actual usage, and provide an additional capacity-inclusive total when reporting reserved RAM.

Imported micromodules currently expose two relevant limitations: unqualified internal function calls do not automatically gain the import prefix, and raw inline-asm `@string.data` names are not prefixed with the importing alias. The repeated-greeting module avoids both by exposing separate functions to its caller and using immediate glyphs plus arithmetic row addresses. Its build checks compile under a second import alias and compare PRG bytes. Do not silently tie a reusable asm module to a particular caller alias or generated label namespace.

Standalone inline `asm { sei }` cannot persistently disable IRQs: the compiler restores the saved processor status at block exit. A self-contained display module can instead mask its owned CIA/VIC interrupt sources and document the takeover. Do not remove preservation wrappers or use forbidden stack operations to escape the inline-asm contract just to match a handwritten listing.

Reducing handwritten asm and reducing generated code are different objectives. The repeated-greeting high-level alternative reduces module source mnemonics from 202 to 10 while growing the PRG from 592 to 2,247 bytes and resident RAM from 3,628 to 5,275 bytes. Keep this as a separate variant and preserve the assembly-heavy baseline. Typed state may live in an initializer's static frame and be returned by pointer under the existing static-lifetime ABI; document singleton/non-reentrant lifetime explicitly. A tiny row-copy asm kernel can coexist with high-level ring/state orchestration without pretending the higher-level code preserves the original timing.

The third, balanced greeting variant keeps the typed high-level state machine but moves bulk fills and the complete screen copy into asm: 66 handwritten module instructions, 1,836-byte PRG, 4,865-byte resident RAM. It is 411 file bytes smaller than the mostly high-level variant while remaining far larger than the specialized assembly-heavy one. Treat fixed screen high-byte fields as machine-constrained page selectors, not generic pointers, and keep all three baselines visible when documenting the tradeoff.

For the buffered C comparison, inspect I/O reads in optimized listings rather than trusting a discarded volatile expression. cc65 -O forwarded a CIA ICR write into a following read; Oscar64 removed a discarded ICR read. A separate read helper plus a volatile result byte retains an actual load in both final builds. The four BSS bytes are counted once (cc65 overlays ONCE; Oscar64 extends the image). An integer-cast ROM function-pointer call crashed Oscar64 1.32.268 at compile time; one explicit terminal `JMP $fe66` avoids that call-graph/ABI issue. These observations do not establish general volatile semantics or target behavior beyond the inspected output.

Keep the original portable buffered Oscar64 build (593-byte PRG, 3,632 resident bytes) beside the idiomatic native-API variant (656/3,702). Oscar64's named VIC/CIA registers, screen-code literal, `vic_waitFrame`, and memory intrinsics improve source expression; two variable-length `memcpy` spans link a native helper and need more pseudo-register bytes (20 versus 13). Compare the emitted result, not a presumption that idiomatic code must shrink. cc65's corresponding buffered build is 1,249/4,297 with its 2 KB software-stack capacity reported separately. None were executed.

## Private-Function Pruning Uses Shared Exhaustive Reachability

`src/codegen/tass64/reachability.zig` is the common executable/DLL call-graph
walker. Keep its AST switches exhaustive. Traverse call arguments even when the
callee is already in the visited set. DLL roots are every manifest export,
independent of resident callers; root traversal also protects fixed placements,
source exports, and explicit ABI policies. Reachable opaque inline asm keeps
all source functions until explicit reference metadata is available.

Do not silently skip semantic errors in dead declarations. The initial pipeline
validates the full program through a dry emission, then re-emits a shallow
function-filtered program when anything is dead. All referenced AST data remains
owned by the original parsed program. Fresh emitter state ensures helper/storage
liveness is recomputed. This may cost host compilation time; separate semantic
validation is the eventual cleaner boundary. Global data remains unpruned.

Use `ZEROPAGE_TEST_COMPILER=/absolute/saved/zp64c` for controlled host baselines.
Otherwise `zig build emu-test` can install a newly built compiler while measuring
an alleged old baseline. A saved binary hash alone is insufficient unless that
binary actually compiled the measured cases. Compare against local ZeroPage
baselines first; competitor like-for-like benchmarks are deferred by user request.

## Measure Consumer Width And Branch Costs Separately

Constant multiplication can use byte Horner chains only for an A-only consumer
and byte-valued operand. A declared u8 expression is not automatically proof
that an A/X intermediate can be truncated: existing widening multiplication
paths intentionally retain high bits. Word volatile accesses must retain their
full read width even when the final product is zero or discards a high byte.
Keep value evaluation for factors zero and one, and validate unsupported types
before choosing an optimized path. Prefer a target byte/cycle cost bound over
blindly unrolling every constant.

A parallel build's redirected output can lose metric rows while leaving the
suite completion footer. Require the metric count to equal language-pass plus
smoke counts, capture a dedicated emu-test stream, and pipe through tee rather
than trusting a mixed parallel size-report log. Keep incomplete attempts out of
the durable comparison corpus and preserve them under ignored build artifacts.

The pure Tic Tac Toe profile in round 5 matches normal Peddle totals exactly.
Its largest function cost is winner's condition-heavy scan, not multiplication.
Direct comparison/short-circuit branching should precede speculative register
or pointer-cache work. Retain the normal behavior suites as the proof; an
analysis-only hook-skipping profile is not a test harness replacement.

## Page Layout Can Reverse A Small Speed Win

Round 6's smaller code moved clearScreenLoop's BNE across a page (+255 cycles)
and mul16's loop/skip branches across pages (+29). Instruction counts fell while
cycles rose. Exact per-PC Peddle profiles identified the causes. Conditional
padding with a jump over filler corrects them, at an explicit PRG-byte cost.

Check the taken branch's PC after its operand, not just the instruction bytes.
For a 15-byte loop ending in BNE, low-byte start $f1 already incurs a page-cross
penalty, so the safe threshold is $f0. After inserting a skip JMP at $fd-$ff,
recheck whether padding is still needed: the JMP may already cross to a usable
next-page address. Otherwise a naive alignment can add 257 bytes. Sweep all
256 origins per helper; the round-7 accepted caps are 15 and 41 extra bytes.

On the proved exact 257-byte copy, four-way unrolling removes 64 taken
branches per full page. Those branches cost 192 cycles even before
accounting for branch page crossings. The new loop can pay at most 63
extra page-cross cycles, so its speedup survives every branch placement.
The 14 bytes for two extra copy packets fit within the 39 bytes recovered
from unreachable dispatch and exit paths. Keep the original read/write
order within the unrolled loop because overlapping copies can observe
the previous store.

An exact copy count and a fixed destination also determine the final
index, last index and last destination. Publish those values in the
original store order. Reuse the exit liveness proof for changed
registers and flags, and keep the Y value observed by the return.

When several indices are staged before a run of indirect reads, the
first index can stay in Y while its store remains in place. The other
table loads must use X and their stores must be disjoint from the first
index slot. The first indirect LDA then overwrites A and N/Z. This
preserves later reads of the index slot and leaves the indirect access
sequence intact even when the pointee is I/O.

Removing those index stores needs a separate alias proof. The eager
winner-loop prototype matched every board state at its two actual
origins, yet returned a different result when a synthetic ABI caller
pointed the board at an index slot. Track forwarded record arguments
through tail-call jumps as well as JSR, and include wrong-page reads
when checking the indexed address range.

## Direct Comparison Operands Preserve Evaluation Boundaries

Selecting immediate/static CMP/CPX operands removes staging, but a mutable RHS
must be read after the LHS is evaluated: an LHS call may change that very slot.
Do not preload or hoist it based only on its simple syntax. High-first word
comparison can omit the low-byte read for compiler-owned ordinary RAM, but an
indirect/volatile RHS must keep its complete access before either comparison.
The direct path is currently disabled for module programs until absolute
comparison operands have explicit relocation coverage. Preserve word guard
label allocation even when operand staging disappears.

Prog8 is a continuing primary reference, including AST width-aware expression
simplification, root/call-graph unused-code removal, and IO-aware assembly
scratch/load/store cleanup. Borrow the proof boundaries as well as the shorter
sequences; ZeroPage's typed operand selection avoids needing to infer those
identities back from arbitrary assembly text.


## Use Shift Carry Without Leaking It Into Addition

General multiplication can shift its multiplier before the conditional add,
using carry instead of a separate LDA/AND test. Always clear carry before the
low-byte ADC: the shifted-out selector bit is not an arithmetic carry-in. Keep
carry propagation between low/high additions intact. This saves five native
bytes, 32 instructions, and 96 cycles per 16-bit multiply in the current helper.
Update page-span tests alongside instruction changes (41 -> 36 bytes, safe start
threshold $d6 -> $db), preserving the nested near-page-end padding guard.

The durable runtime product verifier accepts saved runtime sources and timing
bases. It checks 69,888 host-calculated products, incoming carry variation,
consumed scratch, preserved Y/SP, and per-product cycle/instruction formulas.
Use this together with normal compiler fixtures and the all-origin sweep;
standalone helper correctness alone does not prove calling, placement, or
relocation behavior. Source expected arrays must fit the existing 255-byte
aggregate bound; keep larger exhaustive tables in the host verifier instead
of weakening language constraints for a test.


## Pointer-Base Reuse Needs Storage Identity And Dead Output Proofs

`instruction.zig` is the small NMOS register/flag/memory-effect model.
`storage_model.zig` derives frame offsets from actual emitted storage rather
than guessing aliasing from label text. Root and field labels can share an
address; `frame+offset` writes must resolve canonically. Unknown layouts revoke
RAM bounds, and source slots must be ordinary RAM above $01ff and outside IO.
The current same-frame restriction makes disjoint local stores provable without
pretending an arbitrary symbolic store is harmless.

A pointer copy also defines A/N/Z. Removing it is valid only when those outputs
die before a consumer; LDY alone does not kill A, and PHP/branches/TAX/stores
can observe removed outputs. Typed read markers identify exact compiler-owned
read sequences; malformed/changed sequences fall back instead of being guessed.
Only nonvolatile struct reads get this provenance. Preserve every target read
and full word byte order. Module programs bypass this pass until relocation
anchors and operands can be removed as one operation. Keep all unknown calls,
control-flow joins, scratch aliases, indirect writes, and opaque assembly as
invalidation boundaries.

`scripts/verify_pointer_reuse.py` checks real saved/current PRGs with 6,656
native paired cases, including aliases the source subset cannot spell directly.
It compares full A/X/Y/P/SP and memory effects, not just a final word. Normal
fixtures remain the language proof. Round 10's larger-than-instruction-cost core
win was traced to a shifted trial board avoiding indexed page crossings; its
small +4-cycle internal deadBoard regression is also recorded. Keep operand
layout/page effects separate from the direct transformation's fixed cost.


## Flag Facts Describe Retained Instructions Only

Round 11's stack/reload cleanup preserves N/Z or proves it dead; removing a
reload/PLA does not make its hypothetical flag outputs available to subsequent
rewrites. Decimal ADC/SBC is deliberately excluded from N/Z-to-A correlation.
Forward only canonical ordinary-RAM frame/scratch bytes; unknown aliases, calls,
IO/volatile reads, and asm revoke facts. Run this pass after legacy peepholes,
which cannot safely be re-triggered by arbitrary newly exposed adjacency.
The exact masked page filler is bounded by 255; count conditional bodies
conservatively and revoke RAM bounds on conditional origins/unknown fills.

For native comparisons, private frame addresses move with code. Compare such
pointer scratch by owner/byte offset, while comparing fixed RAM/IO literally
and A/X/Y/P/SP exactly. The value verifier also compares full current-function
frame bytes. Dead hardware-stack bytes are private ABI scratch, not stable
results. Keep actual CIA reads in tests, including decimal flag cases.

The user now explicitly prioritizes fast Peddle checks and substantial aggressive
optimization batches, with VICE deferred until several passes/milestones. Do not
return to one full VICE run per small pass. Label deferred gates honestly and
retain the last green checkpoint; reuse hash-identical measured baselines.

## Costed Switch Results (Round 16)

Oscar64's pinned `InterCodeGenerator.cpp::BuildSwitchTree` normalizes intervals,
uses short chains for small switches, and balanced tests for larger ones; it
also merges adjacent intervals sharing a destination. Constant-result tables
are our further specialization, not a claim about that inspected Oscar64 code.
Account for the complete guard/default/data cost, keep high-byte word checks,
and use raw-low-byte slots for cross-page windows (including exactly 256 keys).
Guarded biased absolute operands avoid SBC's decimal behavior. Force `@w` so
64tass cannot silently narrow a biased operand and invalidate modeled bytes.
Custom images below $0200 need unbiassed prefix storage or the legacy path.
Keep indexed-read RAM proof separate from strict object/alias resolution.

Evaluate every selector once even for known/uniform outputs, and validate every
constant prong through the ordinary cast/enum path. Avoid probing arbitrary
expressions: they may allocate labels or mutate helper-use state. Put lookup
data in compiler-owned rodata, outside function instruction blocks, so earlier
callee-effect/loop passes continue to work. Preserve source-label allocation and
coalesce old switch anchors; opaque asm mentioning `switch_expr_` must pin old
blocks. DLL relocation paths remain unchanged. The native switch proof checks
ABI outputs, source storage and I/D/V, explicitly recording clobbered Y/C/N/Z;
this differs from earlier passes' stronger full-register equivalence matrices.

## Large Shift Entry Sharing (Round 17)

Left-15 can fall through a left-14 entry, sharing six ASLs and the exact-flag
result sequence. Model whole helper/kernel usage, not just each call site's
setup: removing the last loop user can save more bytes than an inline budget
predicts. Keep the measured +5/+6-byte mixed-one-count tradeoff visible instead
of claiming universal size wins. Count-14/15 outlines retain full A/X/Y/P/SP;
private shift scratch contents remain outside the return contract.

## Cache Values In Their Actual Registers (Round 18)

Winner's repeated `LDA index; TAY` sequences survived earlier A-only forwarding
because intervening table loads replace A but leave Y intact. Track Y's canonical
ordinary-RAM cell separately, retain it only through proven RAM reads/disjoint
writes, and invalidate on aliases, unknown/IO accesses, Y writes, calls, joins
and asm. TYA preserves the removed load's complete A/NZ outputs; remove a whole
load/TAY pair only with A/NZ dead. Never forward the hypothetical outputs of a
removed instruction. Existing strict object resolution, physical RAM bounds and
NMOS effect modeling are reusable proof infrastructure; DLL lowering stays
separate. Native alias cases should point directly at the cached source slot,
normalizing only explicitly seeded moved private-frame pointer bytes after
checking their owner/field identity.

## Source Ownership And Measurement Boundaries (Round 19)

Oscar64's low pseudo-register workspace is borrowed BASIC state; its ordinary
KERNAL workspace is separate, and its actual default global ZP range differs
from stale manual wording. Verify compiler/runtime and original ROM sources.
Safe BASIC and KERNAL profiles differ; do not equate ROM bank state with ownership
or use RS-232 F7-FA bytes silently. Normal return needs a snapshot of all claimed
system bytes, not the narrower historical CRT repair. Bare takeover must happen
before entry initialization, not later in main; SEI cannot mask NMI. Keep forced
warmstart/stock RESTORE limitations explicit.

A PRG does not initialize disjoint zero-page data. Moving private cells requires
runtime initialization and complete pointer remapping (startup copies too).
Use 64tass address($xx) to export typed address aliases through normal VICE labels;
plain numeric equates are omitted. Place after old memory proofs initially,
exclude indexed/escaping/opaqueASM-sensitive objects and preserve source labels.
Main+three available workers used isolated files and private compiler outputs;
main alone installs/freezes shared corpora. Late policy errors must not free
assembly already consumed by finalization. ROM checks must handle opcode case,
numeric expressions and symbol offsets, not only one parsed literal spelling.

Test pass hooks stop before cleanup! Keep host counters explicitly early-pass,
and separately execute all the way through main RTS/exit for restoration and
complete timing. Short kernels can improve while whole-app lifecycle overhead
regresses. Keep both in history. Same-syntax before policy compiler plus exact
reference PRG hashes gives an honest baseline when the older compiler cannot
parse a new metadata field; do not compare changed source as if unchanged.

## Exact Fixed Strides And Global Helper Cost (Round 20)

The new AoS workload exposed generic multiplication for every nine-byte record
field, bypassing expression-level constant strength reduction. Count exact
compiler-owned address setups before helper emission; size their complete shared
bodies and credit generic-helper removal once for the whole portfolio. Preserve
unmatched users, prepared placements, opaque assembly and namespace collisions.
Keep LHS/result scratch when the generic flag drops; only RHS/loop become dead.

On NMOS, generic zero-plus-source ADC adjusts invalid BCD digits. Plain copy then
shift/add is not equivalent even for some power-of-two factors. Skip only empty
multiplier rounds, retain the exact ADC-zero/add sequence and recover original
low bit0 for the generic loop's final carry; high-byte reload restores NZ, ADC's
V and entry I/D survive. Exhaustive actual emitted helpers verify full state.

A source-level D matrix also changes private frame base immediates when code
shrinks; decimal ADC of those addresses is layout-sensitive before this pass.
Keep production binary sweeps and normalized-frame flag probes separate, retain
all diagnostics and never claim full production-D parity from normalized data.
Ordinary source ABI is binary mode. Save probe generators/verifiers durably,
not only build-directory scripts; exact PRG hashes can reuse the existing proof.


### Round21: parameter placement needs typed provenance and lifecycle accounting

Do not infer private scalars from `.byte 0`/`.word 0`: aggregate aliases and hidden
fields share those shapes. Match actual ASTparameters to one exact owned static
cell, then prove no alias/index/address/ASM escape and retain ABI/graph exclusions.
Parameter map checking must distinguish source eligibility from removed-storage
facts; never manufacture a post-relocation storage proof. Semantic marker replay
checks widths, graph/root identity and allocation status separately.

Caller stores and reads benefit from ZP, but normal-return preservation scales
with actual claimed bytes. Keep entry/body/leave partitions; early-pass hostcounts
exclude leave. Round21core improves17119cycles, but tiny entries can lose hundreds
of cycles despite faster bodies. Preserve alternate `.scratch` policy, saved
baseline sources and unfavorable rows. Numeric app addresses inside declared
compiler-owned pool require explicit reserves; relocation cannot preserve an
unreserved alias accident. Stock KERNAL/IRQ behavior needs actualROM checkpoints
with private values live after calls, plus BASIC state and real SYS/RTS verification.


### Round22: optimization metadata must not block existing optimizers

Strip transient call store/copy proof comments before adjacency-based passes,
including unselected candidates. Byte-neutral assembly comments can still change
optimizer output. Marker-only UI regressions disappeared only after checking
full PRG comparisons, not local transformed sequences. Keep candidate records
separate and regenerate native proof when a pipeline correction changes PRGs.

When removing a temporary capture, prove suffix effects disjoint from BOTH its
old temporary and early parameter destination, with full canonical widths. A
second read of the old temporary outside the matched copy invalidates removal.
Source-only expression effects cannot account for all lowered helper calls or
shared scratch; require explicit lowered checks before accepting such plans.

Shrinking code can move a hot taken branch across a page and increase cycles.
Record actual branch PC/target/counts and full entry/body/leave timings. Do not
infer runtime improvement from bytes alone or erase unfavorable rows.


### Round23: a materializer branch fold must preserve physical carry

Replacing CMP#0 after LDA#0/1 requires C=1, not just the same boolean and branch.
SEC preserves that carry alongside the identical A/N/Z and unchanged V/I/D/X/Y.
Fold only the exact materializer/consumer and reject extra join-label uses;
retain source labels and all producer evaluation. Module/placement relocation
anchors and opaque ASM stay outside the first pass. Prove actual eligible and
ineligible backend cases, not fixtures with no opportunity. Keep whole flag
matrices and independent invariants as well as production host assertions.


### Round24: deadness is per register/flag bit and per control-flow path

Track the remaining A/X/Y/N/Z/C outputs, reads-before-writes and both branch
successors. Killing NZ with LDX does not make an earlier A value dead. Calls,
returns, unknown syntax, ambiguous targets and unresolved cycles expose all
remaining outputs. Reverse progressive deletion avoids using removed kills.
Keep every memory read even when its loaded value is unused: overwritten X/Y
CIA reads still advance the device. Fixed-address graph probes supplement real
source endpoints; preserve named storage and full CPU state without blanket masks.

Source-only constant parameter unanimity is not enough for specialization:
callee/descendant indirect writes may alias the slot, and existing arbitrary
private native-entry tests leave the closed-source-call domain. The measured
strict census is small; final-word call staging is the next broader opportunity.


### Round25: final-word capture can avoid staging without changing entry CPU state

A final STA/STX into an owned visible-RAM parameter followed by LDA high at the
old copy position reproduces A/NZ exactly after every earlier retained copy.
Word-only admission is profitable even after old low-load forwarding; byte-last
is often neutral and stays staged. Prove the new reload's readability, whole-cell
ownership and all suffix/temp/destination disjointness, not just store validity.

Keep tests scoped to their purpose: new caller reloads can invalidate a global
count intended to measure one callee's pointer reuse. If all word captures vanish,
ZP allocation fixtures need a real remaining capture, while a separate test must
verify the newly absent scratch claim/lifecycle. Native raw pre-JSR CPU checks
plus a real-ROM live-value/SYS-return gate are stronger than size estimates.


### Round26: zero uses of one label is not a physical liveness proof

Neighbor expressions arg0+2 or arg1-1 can reach a cell with no own-name uses.
Frame bounds are insufficient when a large scratch frame contains many objects;
use per-object extents and conservative family address/index/data/indirect/unknown
escape guards. Respect 64tass case-insensitive symbols. Never let pruning hide a
duplicate/invalid layout. Post-ZP declarational aliases backed by actual claim
metadata are not address-taking; independent verifier must model that stage.

Store-only references are a stronger next target than byte packing: if ordinary
owned capture bytes are never read anywhere, their register stores have no source
observable effect, but producers/formal writes/volatile reads still do. Share
ownership/alias facts between passes so safety contracts cannot drift. Source
arrays' unchecked runtime indexes do not justify arbitrary no-alias assumptions;
compiler-private scratch ownership is the explicit narrow ABI boundary.


### Round27: byte-level private scratch dead stores compose with prior forwarding

A stage store can become unobservable when its matching load was already
forwarded. Analyze complete program bytes, not whole-word only: an unread low
byte can lose STA while high STX/LDA and the word remain. Preserve all producers,
source/formal writes and volatile reads. Scope private-scratch exclusions to exact
validated unread bytes, adversarially seed still-read bytes and check raw CPU.
Claim elimination can change lifecycle code and allocator ranking; independently
validate map-derived masks/ranges/text and execute the components rather than
requiring an obsolete identical physical pool layout or masking whole runtime.

Size reductions also move DATA across indexed-read pages: R27's sole +23cycle
row is +42-7 indexed penalties-12savedstores, not a branch issue. Classify from
actual traces rather than assuming every layout effect is a branch penalty.

### Register facts need actual intermediate compiler buffers

A final assembly file cannot establish facts for an earlier pass: later CFG,
private-store/data and ZP transforms can remove the very read that originally
made a byte live. Record actual stage buffers in a private coherent CLI copy,
preserve source hashes and the instrumentation diff, and require complete PRG
identity to the pinned real compiler before accepting those buffers as evidence.
Recompute byte-read obligations after independently validating forwarding.
Validate actual pointer aliases and ownership/lifecycle bindings explicitly;
never normalize arbitrary generated text or mask all scratch bytes/CPU flags.

### Unique-edge register reuse must restore physical flags

A loop header LDA/CMP/branch can establish A for the sole body entry, but CMP's
N/Z need not describe A. ORA #0 reproduces the removed reload's A/N/Z exactly;
measure its removal separately using actual all-path dead-N/Z proof. Check every
co-located label, header bypass, fallthrough and address/control reference.
Unsectioned compiler runtime/test hooks are real code: validate their reachable
instructions through returns/code entries instead of banning every unsectioned
label or accepting named raw-data entries. Opaque source ASM remains a barrier.

Source range-for captures can set N/Z again while clearing a usize high byte;
an ordinary source assertion then cannot honestly observe the earlier counter
reload's flags. Mark injected emitter-derived PHP controls as synthetic, and
use arbitrary actual-pass native graphs for physical flag coverage. Never call
those injected controls ordinary source-language behavior.

### Identity outputs differ from generic instruction writes

ORA #0/EOR #0/AND #255 preserve A: candidate deletion needs only a dead-N/Z
proof. Keep ordinary A reads in downstream effects when proving earlier values.
Removing an identity can expose a formerly protected literal definition, so
independent validation must prove each new deletion with its own output mask on
the final surviving CFG. Do not restrict all new deltas to identity mnemonics or
count identities as literal loads. Separate nominal instruction bytes from PRG
bytes: existing alignment fill can absorb savings with no runtime slowdown.

### Rejection-path issue observed during word-comparison QA

Bare `return;` is still outside the current lowering subset (`parseReturn`
expects an expression). An unsupported bare return nested in `if` also exposed
an existing partial-ownership leak in `parseIf`'s error path. QA kept the syntax
rejected and used supported finite void loops for flag-live controls. Preserve
that distinction when fixing the ownership cleanup; do not silently introduce
new language syntax as part of an optimizer test. R31 notes/private QA retain
the reproduction; this is separate from accepted R30 valid-program proofs.

### Carry equivalence does not imply complete flag equivalence

For CPX #H/BNE join/CMP #0, C already equals CPX's result on every A/X input;
N/Z differ when high bytes match. Keep CPX and query actual remaining N/Z uses
before dropping the branch/low compare. A saved matcher plan is scheduling data,
not a liveness grant: revalidate the current buffer and process progressively.
Prove helper refactors byte/stat-identical separately from optimization effects.
A four-byte shrink can move a small array from low byte $03 to $ff and add many
indexed penalties, so trace data reads as well as branches when timing regresses.

The confirmed parseIf rejection leak above is now fixed by three errdefer owners
(condition, completed then body, else body). The original regression showed ten
leaked allocations; parser84 and combined620 tests pass, including a narrow
nested-if allocation-failure sweep. Grammar and UnexpectedToken rejection stay
unchanged. Evidence: parser-if-ownership-fix.json. This cleanup is separate from
the immutable measured R31 compiler.


## R32: shared safety classification is not a substitute for each consumer's proof

A parameter's own-label use scan misses integer-derived neighbor/cross-frame
aliases. Retained @intFromPtr and nonliteral @ptrFromInt now cause a global
layout_observer exclusion only after earlier owner/type/storage reasons. Dead
observers do not taint live code; parameter-map replay may preserve genuine
physical exclusions but must never admit claims under this reason.

The safety repair deliberately loses shared argument rewrites and costs 1,109
bytes over eighteen corpus images. Record that cost rather than hiding it.
Argument-store motion and object relocation have different proof obligations:
recover the former only with its own typed target/capture, complete copy-phase,
matching callee, suffix disjointness and BOTH-frame visible-RAM proof. Forged PHP
between copies observes different intermediate A/NZ; generic hardware-stack
permission during argument evaluation cannot authorize such a copy phase.
Generic ordinary-RAM resolution alone also admits captures beneath visible ROM.

Per-image source/address oracles are the right test for layout-sensitive safety
repairs: do not assert equivalence with old unsafe addresses or promise private
frame adjacency. Raw AXYP recording is not an independent flags oracle. Exact
lifecycle preservation and same-image scalar/scratch fallback are separate,
stronger CPU checks. Unknown public/native pointers, literal wrapping and
indexed/indirect aliases remain broader proof obligations for existing parameter
placement as well as future locals. The 38-cell core census is a ceiling.


## R33: independent consumers can recover precision without weakening placement

A global source layout observer blocks relocation; it need not block a fixed
resident early argument store when a complete consumer-specific proof succeeds.
Keep the exception local to the actual validated rewrite. Unique typed/capture
metadata, full copy-phase grammar, matching callee, BOTH-frame visible RAM and
suffix disjointness all matter. Actual source volatile reads before a capture
can stay intact while it moves; a later indirect/volatile read must still fail
proof. Two intentionally changed old staging expectations are justified by
stronger native/stage proof, not by deleting behavior assertions.

Reuse native evidence only when exact actual production modules and retained/
post-stage buffers bind it. R33's nineteen corpus inputs do; the 45,056 pairs
are referenced once, not rerun or added to integrated entry/component counts.
Exact whole PRG identity also lets reversed layout regressions reuse prior
traces honestly. Keep distinct per-image numeric-address oracles instead of
normalizing ordinary usize address values or asserting old/private adjacency.


## R34: preserve scratch effects while forwarding captured operands

A useful 6502 optimization need not delete the temporary itself. Keep STA V/
STX V+1 and all pointer stores; use incoming A and unchanged X to exchange ADC
operands and remove reloads. This avoids a private-scratch or stack-byte exception.
Prove both bytes visible, real pointer alias/mandatory planned pair ownership,
nonwrap/disjointness and exact adjacency. Later allocation must reserve the same
pair before placing V. Native NMOS decimal proof must include invalid BCD and
both high-byte carry states; binary addition intuition is not evidence.

Count kernel and harness gains separately: page-copy's41,742 saved cycles contain
only9,252 in copyWindow. Wide-index's40,984 contains39,960 instruction savings
and1,024 layout savings. Final static sizes160setups (42 ZP) explain716 bytes
exactly. Full64K proof is possible by loading both code images in both machines;
compare complete physical memory instead of broad masks. Full-source entries
with relinked nested JSR still compare live caller stack rather than pretending
dead internal return addresses are equal. Keep execution counts distinct.


## Whole-image alias prototype checkpoint: facts do not authorize allocation

Durable review archive: AgentWorking/local-alias-prototype/ (private R32 identities,
not current compiler certification). Actual71roots/38cells/24fieldviews; thirteen
pointer bindings converge conditionally to two aggregate roots. Twenty-two closed
copy-loop certificates cover33indexed machine effects only partly. Seventy of73
source accesses are conditionally inside whole roots; exact lowering linkage,
pointer/capture/table-clobber induction and three counter accesses remain.
All38locals and25 existing scalar parameters are still explicitly NOT PROVEN.
A bounded-copy fixture proves one candidate path; no local has been allocated.

Existing unknown public/native pointer inputs can invalidate parameter placement,
not only future locals. Main's literal argument must not erase other public inputs.
The mutable count example has fieldoffset58, histories18/38 and actual object64B.
Second history index10 overwrites count/turn bytes58–59 while remaining in the
whole object. A max10 call summary is not inductive unless overlapping stores
kill the fact and every subsequent access is checked until constructor reset.
Use the documented D-clear source ABI; do not demand nonexistent D1 source bounds
or invent any pointer/native-input restrictions. Machine equivalence remains fullD.

Next production prerequisite is owned retained inventory handoff (discard semantic
validation-only inventories), then structured source-access IDs/provenance at actual
lowering, certificate-preserving optimization/revalidation and owning Zig proof plans.
Separate field views never become root/cell candidates. Source clause/type/owner
matching alone cannot discharge the actual34indirect/11remainingindexed effects.


## Context-sensitive counter/access refinement checkpoint

AgentWorking/counter-access-prototype/ archives the new private effect trace and
11 tests. Constructor resets, context-sensitive call effects and explicit overlap
KILL close all3 source-counter gaps: moves max9, histories max10; after the one
abstract overlap no later count-indexed access occurs before reset. Inserted later
calls/indexed writes correctly decline. Nine resets/189 transfer evaluations are
ABSTRACT analysis events, not runtime performance counts. Whole Game is64B (the
older alias README prose said65; actual inventory and refinement use64).
All73 source-access containments remain conditional; lowering linkage, switch
bounds and pointer/capture/table clobber induction still gate all38locals/25params.
No production allocation or speed result follows from closing these source gaps.


## R35: proof roots and actual phase order are part of the optimization

Keep legacy and ordinary edge reuse as separateinvocations; ordinaryafterfirstCFG
protects all possible legacy roots and explicitly audits its own final realLDA
roots. Header-as-body forwardchains need accepted acyclic proof dependencies;
even an apparently unreachable backward cycle must failclosed. Preserve memory
CMP reads and visible/canonical disjointness; never remove a volatile/unknownread.

A finalASM census is not a proof that a pattern exists at an earlier stage.
Private defaultoptimizerflags produced a wrong11-site count; exactWithOptions +
triplePRG CLI capture corrected9preCFG/10postCFG. Existing firstCFG creates the
hot blocksLine edge. A secondCFG onlyafternewidentities uses actual all-path NZ
liveness and removes9/10, exceeding an immediate-next-op projection. Preserve
old backend label/assertions while updating explicit stage helpers. Graph
boundednontermination, sourcepairs, entries and lifecycle executions staydistinct.

Relinked pointer bytes may be compared only through explicit AST-typed parameter
and real object/extent bindings. R35's winner_board bindings refer to Trial9B,
not an inferred same-shape scratch. Raw CPU and general integer/RAM values are
not normalized. Snapshot/restore timing has its own boundary; losing3restore-loop
page penalties improves full-entry scratch timing by3beyond the through-pass win.
# R36 retained inventory and memory reporting

Retained typed metadata must come from the selected emitted image, with its own
strings/type summaries and dense IDs; discard full semantic dry-emission facts
before collecting reduced-program facts. Returning original pre-optimization
inventory alongside finalized assembly does not establish final instruction
identity or placement safety. All 288 complete output triples remain identical
after this integration; normal emission uses a null inventory sink.

Report PRG, loaded image, external buffers, ZP claims and snapshots separately.
The R35 core scalar policy removes 42 resident parameter/scratch bytes but adds
a 42-byte snapshot, then borrows 42 extra ZP bytes. Its 315-byte PRG saving becomes
a 273-byte image-plus-ZP saving. This is chiefly instruction-size reduction,
not storage elimination. Greeting buffers also dilute the RAM percentage:
15.2% smaller PRG means 6.5% smaller owned resident total with fixed 3,024-byte
buffers. Capacity is not measured stack or heap peak.

## R37 memory-domain and verification lessons

Pointer-bearing external roots include nested supported aggregate/optional
shapes. Passing a pointer value is not a pointee observation; ordinary-u16 REU
host addresses and free metadata can observe memory without any cast. Keep a
bounded rejection summary separate from a complete origin/alias certificate.
Flattened pointer-field writes take precedence over same-spelled ordinary
bindings; inspecting all matching prefixes avoids the p.value / p_value trap.
Earlier exclusion reasons and independent R33 suffix proofs must survive a
new global placement barrier.

Source/controller types do not certify actual emitted byte widths. The existing
struct-pointer field bug lost C150's high byte; partial raw metadata correctly
records actual one-byte reads rather than inventing a second read. A separate
lowering fix must carry its own source/native proof. For MOS6510 low addresses,
raw backing memory is not an oracle for CPU DDR/port reads at0000/0001; retain
failed-oracle evidence and repair the model instead of filtering inputs.

The supported screen receiver is c64, even when new probe imports use the
ZeroPage module spelling. Do not mechanically replace receivers with
ZeroPage.screen, and do not expand parser syntax to make test naming cleanup
pass. The fresh full checks resolved that fixture-only failure; both complete
host metric streams were identical.

## R38 zero-test materializer lessons

CMP#1 encodes every opaque byte's nonzero predicate in carry; ROL ofzero can
materialize it without ADC/decimal assumptions. Restoring C explicitly keeps a
full endpoint theorem, then CFG may remove dead carry setup independently.
The inverse ROL/EOR version was smaller but slower; the carry-branch inverse
preserves flags and wins both measured core speed and size. Measure alternative
instruction sequences before preferring the fewest bytes.

64tass symbol identity is case-insensitive. Counting exact-case references can
miss an actual JMP into a rewritten arm; one real rejected-control pair exposed
that bug. All internal target/duplicate checks must casefold, preserve scopes
and reject unresolved/numeric/raw-data control instead of assuming labels alone
prove reachability. Existing named unsectioned runtime helpers need actual parsed
paths, not a label-to-data shortcut.

Native local sequences can be faster for every input at fixed layout while full
applications gain differently because code/table placement changes. R38 has the
same1356 structural-cycle win in three core policies, but page effects change
the measured saving to1110/974/1389. Bind reused profiles/native cases to exact
final compiler artifacts, separate symbolic vs CPU and graph vs actual source
counts, and keep failed alternatives/counterexamples out of acceptance totals.


R39 pointer-width tests must compose actual aggregate return and argument copies.
An isolated getter can preserve AX while a caller's record copy still discards
its high byte. Check both numeric and pointer representation predicates at every
copy layer; optional pointers remain two bytes without a separate present tag.
The first integrated host fixture exposed a hole missed by exhaustive isolated
VALUE matrices. Preserve those distinct proof scopes instead of adding their
counts into a broad pointer-alias claim.

A pending two-byte field value cannot live in global arithmetic scratch across
an index expression that calls another function. Lexical capture depth does not
protect against separately compiled callees reusing that scratch. R39 uses unique
resident words per emitted dynamic pointer-field store; generic numeric word
stores remain a separate audit target. New temporary labels use an independent
namespace, cost two bytes per site, and do not imply re-entrancy or native noalias.

R40 encoded-size analysis must not treat the effects parser as an assembler.
64tass can encode `lda a` or `asl a` as three-byte symbol accesses; `(cell)+0` can
be an absolute expression despite a leading parenthesis. Size-only bounds inspect
raw syntax independently and can recognize numeric indexed lifecycle operands
without granting memory-effect/alias authority. Keep all eight inverse predicates,
PC-after-branch displacement and exact boundary/fallback assembler cases tested.

Smaller code can slow indexed data reads. The R40 SoA variants save 25 structural
cycles but relocate data so indexed reads cost 39 more page-cross cycles: net
14 slower with three bytes saved. Four actual source traces checked all asserts
and instruction-cycle buckets. Preserve regressions and derive layout work from
them; avoid source-name or benchmark-specific exceptions. Local allocation must
also charge actual entry/restore work: positive static use counts alone do not
pay the measured cold-start cost. Oscar64's inspected use ranking is a reference;
our exact borrowed-byte BASIC restoration has a different lifecycle contract.

The numeric pending-word audit is now a reproduced target failure, not merely a
possible scratch concern. Four admitted R40 paths (ordinary word array, AoS word
field, pointer-backed struct array and many-pointer element) return/store 2 instead
of unchanged RHS 0xc1f0 when index evaluation calls a word comparison. The callee
clobbers shared arithmetic scratch. Source-visible arguments are not mutated, so
this is independent of assignment evaluation-order disputes. Saved red Peddle
oracles are in build/word-field-pending-repair/audit-before.json. Repair all four
paths, retain simple/literal-index cost controls, and record any resident-word
cost separately from the accepted R40 branch win.

R41 repaired numeric pending stores in all four observed lowering paths and
many-pointer base clobber in reads and byte stores. Use balanced hardware-stack
holds when a source operation must survive another expression or call; no static
site word is needed. Preserve original base/index and volatile low/high order.
Pointer-struct array base evaluation order is separate. Actual current Value
lowering does not write arithmetic scratch, but an indirect field can overwrite
pointer scratch. The broad base guard also catches harmless casts/direct fields:
R41 measures those costs and makes their actual clobber classification the next
optimizer target. Do not generalize stack scratch to a new recursive source ABI
or infer whole-memory equivalence from a source oracle. Compound indexed RMW
still duplicates index evaluation and remains a separate correctness target.

## Index holds and zero-page profitability

Use the actual field resolver to distinguish direct and indirect reads before
eliding a many-pointer base hold. A validated unsigned numeric cast can inherit
its operand's effect. Reopening a word scratch path may enroll `math_tmp` and
change the full entry and exit cost under managed zero-page allocation. Measure
cold normal entries and physical claims alongside direct-call instruction costs.

## Late code layout and physical address observations

Deleting unreachable instructions can change what a live numeric operand reads
or make an invalid address fit. Prove original address bounds and possible
moved bounds. Cover fixed direct and indexed memory operands and retained raw
pointer origins. Numeric pointers can lower to plain immediate bytes, so the
assembly text alone can lose the distinction between an integer and an address.
Preserve exact PRGs for guarded cases and use the assembler as the diagnostic
oracle. Trace branch and indexed page penalties separately from opcode costs.

## Indexed compound assignment

Prepare the addressing mode once and load the old element before running the
right-hand expression. A pointed struct captures the base before its index.
A direct many-item pointer binding loads the base after its index. Keep live
addresses and values on the hardware stack across nested effects. Use operation
scratch after the RHS completes. For a proved register-preserving ALU or shift,
reuse the original address registers and preserve the NMOS indexed bus modes.

## Literal multiplication and runtime references

Share the constant multiplication plans with indexed updates once the old
value is in A/X and the address registers are live. Use bare `asl` and `rol`
for the accumulator on 64tass. A source symbol named `a` can change the meaning
of an explicit operand. When eliminating a helper, account for explicit
inline assembly references to the helper and its scratch storage. Measure the
actual managed claim and entry/return costs along with the arithmetic sequence.

## Reachability and fallthrough

On the unsigned word-copy fallback, CPX and CMP preserve the compared
index in X/A. A branch that exits on set carry proves clear carry on
the loop-body edge. Keep the scratch publications and consume that
index directly when the body and comparison join have no other entries.
The second index read follows an indirect load and needs its own alias
and effects proof.

Root function entries and all external transfers into a function's code. Keep
both successors of a conditional and the continuation of a call. A forward
jump can become fallthrough when every intervening instruction is removed
and the target is in the same function. Keep named anchors and compare actual
executed opcode sequences. Code motion can change a restore loop's page
crossings after a fixture's pass hook, so also trace normal return for managed
zero-page builds.

## Word constant multiply planning

Compare signed-digit and binary encodings using actual 6502 operand costs.
Account for operand capture at the site and measure helper removal at the
whole-image level. Stable ordinary scalar bindings may supply repeated reads.
Capture computed or volatile words once, preserve live indexed addressing
registers, and account for each scratch word in the managed lifecycle map.
Removing the last general multiply can change the profitability of shared
stride helpers elsewhere in the same image.

## Direct indexed address setup

An adjacent direct base staging copy can disappear when both words belong to
visible static storage, the pointer pair is exclusively owned, and index
scratch is disjoint. Keep the actual final indirect addressing mode to retain
the device-facing address sequence. Require one monotonic image origin for
the code and storage involved. A section owner and a valid word definition
alone cannot rule out a later overlapping origin.

## In-place literal increments

The NMOS `INC` write sequence requires visible ordinary RAM. In D-clear mode
the byte form keeps N/Z and can reload the result if A stays live. Word N/Z
can differ when the high byte is skipped. Prove A, X and arithmetic flags dead
before observers, including both branch paths. When checking more than one
replacement, close the entry to an already changed sequence so the later
proof cannot use its old register or flag kills.

## Guarded page-indexed copies

The NMOS `(zp),Y` read can issue a wrong-page dummy read and the indexed
store always reads its intermediate address. Bound whole touched pages to
ordinary RAM outside the complete final PRG before enabling page indexing.
That permits both directions of forward-copy overlap while avoiding alias
with the loop's pointer, index and count cells. Include managed lifecycle
data in the image end label. Preserve the string pair, final index, and
scratch at the exit and keep small and unsafe spans on the original loop.
When a test detects fast-path entry, resolve labels from the owning code
section because earlier source control flow consumes label IDs.

## Static copy spans

Prove fixed pointer values and counts from the caller after full semantic
emission. Admit only tracked control and effects. Include unexecuted scopes
when checking names because the emitter still reserves their static cells.
Check every observed raw span against a conservative bound on the finalized
resident PRG, then check the new layout against that same bound. Preserve
source label order and reject references from outside a replacement. A fixed
span removes both the runtime guard and fallback, and absolute indexing avoids
staging a second pointer pair.


## Cost fixed-page specialization after the local passes

For closed loops with several page-dependent operations, clone whole
pages only when the encoded output fits the actual fallback after
selector folding and local address setup. Resolve zero-page versus
resident operand widths at the comparison stage. Keep the original
read and write sequence even if one output feeds the next read or
iteration. Prove each fixed address and its dummy-read page. Save no
additional scratch when the final counter, selectors, pending stack
byte and original destination/index scratch can be reconstructed.

## Share adjacent range selectors after cloning

The first compact predicate can select both literals if the pair has
no intervening effect, the destination bytes are mutually disjoint and
neither aliases the index word. Preserve the two ordered stores and
the final carry set. Keep all old labels in order and prove that
nothing enters or observes the interior. Run sharing after page
cloning so the chosen clone remains available even when sharing the
fallback would save a few more bytes.

## Close retained memory before deleting a literal pointer cell

Typed immutability alone does not close raw memory or an escaped
address. Match the initialized cell and all actual access packets,
prove single entry after initialization, and resolve other instructions
to owned object bounds or fixed visible RAM. Include NMOS dummy
addresses in the domain check. Keep indexed stores and the original
base even at Y zero to preserve target dummy reads. Treat managed
snapshot loops as bounded packets with a separately checked data
extent. When removing initialization stores, track A, X and N/Z
independently through the following instructions, preserving values
still live at a call, branch, label or return.

## Preserve the original loop-exit state in affine strength reduction

Carry the modular term in a private induction slot only after proving
the exact loop and closed retained memory. Reconstruct the counter
before the exit label. A zero-trip compare preserves incoming overflow
and leaves the stack alone. The ADC backedge clears overflow on a
nonempty exit, while the INC backedge retains the last high sum's
overflow. The final pending stack byte comes from the low bias sum,
and a single balanced push and pull recreates it at the original depth.

## Group affine reductions and replay the original failed header

The sum of three F*i+B terms starts at 3F+3B and advances by 9F.
The source induction cell can hold this group term privately while
X counts down by three. Restore the consumed index and the last
captured original offset before entering the remainder loop. A
failed i+3 comparison still evaluates a ninth bit at count 255 and
writes its pending low byte even when there were no groups.
Specialize that empty path to avoid precheck overhead. Count actual
ZP capture widths and bound every new branch independently when
the complete replacement exceeds one short-branch span.

## Prove a private leaf's argument lifetime at its only call

Count retained typed call sites before deduplicating graph edges. Verify
the actual JSR separately and reject alternate entries and other formal
references. If the leaf starts by loading both formal bytes, redirect those
loads to the caller's owned word and remove the caller capture. Preserve
earlier forwarding only when the retained publication proves the incoming
register values. Resolve managed arithmetic scratch through actual claims
and retain both the original call depth and the arithmetic stack sequence.

## Anchor scratch-store removal at an untouched kill

Scan back from a retained complete publication. Decline at labels,
control, unknown effects, or scratch access through any spelling of a
physical alias. A proved straight-line balanced leaf can be transparent.
Never justify another deletion with a write that will also disappear.
Keep the indexed target address modes and both store states so that NMOS
dummy reads and ordered target writes stay exact across page boundaries.

## Keep the decimal correction in a masked-product bound

A zero high capture can feed immediate high arithmetic. An early shift
can leave X untouched only when the shifted upper bound fits in one byte.
Before replacing a high ADC with the low ADC's C/V state, include the
NMOS decimal low-digit correction in the positive signed bound. The
remaining PHA/PLA must preserve the physical pending byte at the original
depth. Keep the original input-read width until a separate storage and
effects proof can remove a read.

## Prove local entry and branch range independently of global liveness

An unrelated trailing source label can prevent a whole-image reachability
proof even when a local packet has known control and complete exits.
Share the layout and address-observation checks. Prove the edited
window's interior references and new relative distances separately.
Preserve the original stack bus traffic when deleting only high-byte
register operations.

## Keep native proof checks active in optimized builds

The pinned `zig c++ -O3` defines NDEBUG. Build assertion-based
verification harnesses with `-UNDEBUG` and a compile-time check that
rejects NDEBUG, or use explicit failure returns for proof predicates.
Record the exact compiler command in the provenance so a reported
iteration count can be traced to checks that actually executed.

## Resolve a mixed frame with its actual zero-page claims

When an allocated parameter becomes an equate inside a static frame,
it contributes no resident bytes. Use its exact allocation record to
bound the remaining frame objects. Keep this relaxation local to passes
that understand promoted parameters. For a counted copy, also prove the
entire destination byte extent and keep the indexed access modes and
counter RMW. Exit reconstruction must include the last compare flags
and the pending stack byte.

## Separate accumulator flags from compare carry

CMP against zero recreates N/Z from A and sets carry. A matched
adjacent producer can supply the first two flags. Preserve carry
with SEC unless every reachable path overwrites it before reading
it, accounting for instructions already selected for deletion.
NMOS decimal arithmetic can leave N/Z from an intermediate value.
An A write alone is insufficient evidence for this fold.

## Check both sides of a moved loop comparison

A first trip with a proved zero index can bypass the condition when
the byte limit is nonzero. Preserve the initial flags if any path
observes them before a kill. The repeat compare can supply a kill
on paths that reach the new latch. A path that returns early or
branches around the latch needs its own proof.

A loop can shrink overall while an individual relative branch grows
across the new latch. Bound the new backward branch separately and
keep other retained relative targets within the unchanged body span.
For emulator assertions into a relocated image, rebind by symbol
and preserve the original assertion width and value.

## Prove physical return values before inverting them

An inversion ladder based on CMP #1 accepts any byte. EOR #1
produces the same Boolean value only when the accumulator is known
to contain zero or one. Prove that at each return and prove carry
separately. A typed return alone leaves room for a value loaded
from externally observable storage. When carry can differ, check
every successor for an overwrite before any read.

## Prove the physical source before deleting an overwritten load

When a masked product overwrites X, the high input byte can disappear
only if its read is from ordinary resident storage or a verified
zero-page claim. Retain reads through volatile pointers, including
those that fill an eligible local. Match the final common packet
after all passes that produce it, and verify that the remaining
ordered stack and data bus transfers match.

## Preserve short-circuit reads and restore flags at the final return

For a closed terminal NOT test, the original CMP #1 can drive the
false branch directly. Preserve the same ordered input loads and
short-circuit skip. Literal return loads overwrite A and N/Z, and
SEC restores the old retest's carry at the join. Validate all entry
labels and the new relative branches. Count real operand reads
separately from an RTS dummy fetch into an adjacent static frame.

## Load the high byte where the arithmetic consumes it

With a proved ordinary word, the initial LDX and later TXA can become
one LDA at the high-byte operation. Keep the carry-producing instruction
and stack transfer between the two byte loads. Verify the new read
order, exact carry and pending stack byte. Location-dependent assembler
padding in an otherwise unrelated helper needs a separate layout proof.

## Price memory shifts with the allocated addressing mode

An absolute ROL can replace a stack bridge profitably across
consecutive word shifts. A zero-page ROL costs one byte and one cycle
less, so the same change pays off with fewer shifts when a claim is
available. Count the initial spill, the final high-byte read and any
save/restore cost. The scratch byte needs an ownership and liveness
proof because the rotate reads and writes it on every shift.

## Prove borrowed scratch dies before later reads

A terminal packet can borrow an existing compiler scratch byte when
each original read starts from a write in the same straight-line block.
Labels, calls, branches and section boundaries reset the proof. The
packet must reach return without reading that scratch byte again, and
its inputs must be distinct from the borrowed storage. This lets the
allocator and restoration code keep their existing claims.

## Charge each inlining expansion to the relative branches it crosses

Inlining one call removes four bytes overall and can still grow a
particular branch span. Bound the instructions at the call site and
reserve the resulting growth for every crossing branch. Reuse that
budget for subsequent candidates. Keep static-frame ownership and
track the moved source function in assembly even after the private
entry disappears.

## Distinguish zero-page indexed encodings from absolute indexed encodings

On the pinned assembler a bare byte literal selects zero-page
indexing when the NMOS opcode has that mode. LDA and STA with Y
use absolute indexing even for byte literals. Explicit @w also
selects absolute addressing. A stack-observer check needs the
actual wrapping rule before allowing a low indexed operand.

## Keep the flag refresh when NMOS decimal arithmetic precedes a pull

PLA and TYA set N/Z from the byte they restore. NMOS ADC and SBC
can leave flags that differ from the adjusted A. Use ORA #0 to
reproduce the pull's flag result when moving an immediate LDX or
removing a redundant adjacent push/pull. A preceding ordinary load
or accumulator logic operation already provides those N/Z flags.

## Include the indexed store's uncorrected page in alias checks

Moving a fixed indexed store across ordinary reads preserves the
port sequence when its base and index stay the same. For a base
ending in $FF, the high-byte store dummy-reads the original
page's first byte before writing the next page. Include that
address when proving the output disjoint from the resident image
and the operands that move across the store.

## Tail calls can save cycles with the original layout

An eligible terminal JSR/RTS pair can jump to its callee and reuse
the caller's return address. Callees see a different hardware stack
depth. Treat TSX, TXS, explicit stack-page reads and emulator SP/stack
assertions as observers. A label on the RTS makes it an independent
entry. Preserve unreachable instruction width when it pins the PC
of a later conditional assembler padding block.

## Model literal index reads in final liveness

A literal absolute indexed LDA reads X or Y and kills N/Z. STA
reads A and the index and leaves N/Z intact. Final word-store
streaming exposes dead literal loads and ORA #0 refreshes across
these instructions. Keep the refresh when a successor observes
physical flags. The original indexed memory instruction, including
its page-dependent dummy read, can stay byte-for-byte intact.

## LDX absolute,Y preserves the crossing word-load bus sequence

An absolute LDA replaces the low-byte LDA absolute,Y with Y=0.
For a crossing high byte, LDX absolute,Y with Y=1 reads the same
uncorrected page and the same final address as LDA absolute,Y.
LDX absolute can load the high byte directly when it stays on
the same page. Refresh N/Z from the low byte in A when those
flags remain live after removing the original pull.

## Track overwritten scratch by physical byte

Keep the final write in a block and prove each intervening operand
disjoint before removing an earlier store. Both numeric zero-page
addresses and assembler aliases can observe the managed byte.
An absolute indexed access can also read the uncorrected page.
Hardware pushes and pulls use page 1, disjoint from managed zero
page and ordinary resident scratch.

## Keep the byte-level overwrite proof independent for each cell

A read through a fixed pointer alias can keep the low byte live
while the high byte is overwritten. An indirect access observes
both bytes of the pointer and can reach other tracked cells.
Rerun register liveness after deleting scratch stores. LDX
absolute,Y consumes Y and overwrites X and N/Z.

## Preserve the last word shift's carry when using eight iterations

With a proved-zero high multiplier, the last eight word iterations
only shift a zero right operand and clear the remaining left byte.
After eight iterations the left high byte holds the original low
byte. LSR recovers the final carry and STX clears that cell using
the exhausted counter. The final result loads restore N/Z.

## Preserve the padding decision when the loop setup changes width

The sentinel byte helper's SEC is one byte shorter than the old
LDX immediate. Evaluate the old padding at PC+1 to keep its JMP
and fill width. The new loop label sits one byte earlier. Check
page containment from the actual repeated branch target after the
new prefix, including helpers whose padding ends at a page boundary.

## Reuse the consumed right operand to preserve word multiply carry

The register sentinel leaves A at zero after eight shifts. A nonzero
right high byte can start a second phase after clearing its cell.
Keep the original left low byte in the consumed right low cell
until the exit shift recovers the counter helper's carry. The final
result loads recover N/Z. Prove both phases in decimal mode and
compute page penalties from assembled relative branches. Holding the
padding size constant bounds the cost where static call structure
suggests enough repeated use to spend the extra bytes.

## Save the incoming register in a private slot the loop already owns

An affine kernel can use Y for the running low term and preserve the
incoming Y in the old low-term slot. Prove that the exact generated
loop has no intermediate observer and that all entered paths restore
the register before publishing the final index. Keep zero-trip paths
outside the save and restore. The register form avoids stack traffic,
including changes to inactive stack bytes. Measure one-trip paths
separately, since the restore cost can outweigh the first saved load.

## Use the grouped exit carry to publish adjacent values

A taken BCC after CPX #3 guarantees clear carry and X in 0…2.
Adding the complemented X to count gives the previous index
and sets carry whenever an entered group consumed at least
three elements. An intervening store preserves that carry for
ADC #0, which recovers the consumed index. When an exit
sequence shrinks, check the empty path too. Its taken branch
can move across a page even though the changed code is skipped.

## Rebase a fixed indexed store without changing its dummy read

When the low address byte is nonzero, base-1 remains on the same
page. STA base-1,Y with Y=1 keeps both bus addresses of STA base,Y
with Y=0. A page-start address lacks that property. To omit index
setup in a later packet, require both a reaching Y=1 and dead
N/Z. During the backwards proof, remove any original flag kills
whose replacements no longer emit them.

## Drop a fixed index when its bus read and register effects are dead

An absolute STA takes one cycle less than STA abs,Y. The indexed form
always reads the uncorrected page before writing. Bound that read as
well as the effective address to ordinary RAM outside the loaded image.
The ASL/STA/TXA/ROL/STA word-shift sequence can also omit its LDY when
TXA overwrites the intermediate N/Z and Y dies on all outgoing paths.
Model every candidate as transparent to Y during that proof, so a
backedge cannot rely on an index load that the same pass removes.

For a single indexed STA with known Y, an absolute STA preserves all
registers and flags while saving one cycle. Track literal Y only through
known instructions and invalidate it at labels, control transfers,
unknown effects and section boundaries. This also covers stores whose Y
setup is still needed elsewhere. Check new liveness only after the
converted store no longer reads Y.

## Extend a shared shift when the next product needs more bits

Two products can reuse the same modular shifted word even when
the second needs more shifts. Resume the ASL and ROL sequence
from the first shifted word, then publish the extended low byte
if a third product uses it. Pairwise greedy selection can
consume a middle product and miss the larger saving from a
chain. Each link must preserve source, scratch and X. Restore
X at the end if the following code can observe it.

## Reuse a shifted high byte and recompute the cheaper low byte

When X still holds the high byte of a word shift, reloading
and shifting the low source byte costs less than saving and
restoring a second temporary. The register form produces the
same low N/Z and needs a dead-carry proof. The scratch form
originally leaves N/Z from its ROL, so it needs both flag
proofs and must restore X if the original unshifted high
value is still live.

## Fold a known saved high byte into the word add

A stack-held word with a known high byte can keep only the low
push. Add the known byte to the right high register after the
low-byte carry. Verify the reversed operands for NMOS decimal
flags, including invalid BCD digits. Shorten the stack interval
only when stack accesses are private, and keep each scratch
write until a separate overwrite proof makes it removable.

## Materialize a carry in a proved-zero high register

After shifting the low byte, BCC over INX computes the original
ROL result in X when X starts at zero. The low byte can stay in
A. Require dead carry, N/Z and Y after the original bridge.
The one-byte forward branch can still cross a page when the
branch opcode starts at offset 253. Include that cycle in the
minimum savings.

## Form two high bits from consecutive low carries

When the high byte starts at zero, two consecutive shifts can
set bit 1 with a conditional LDX and bit 0 with a conditional
INX. This leaves A on the low byte throughout. Prove the flags
and Y at the end of the pair. If they are live, still try the
single-bridge rewrite using its own liveness proof.

## Keep carry while shortening an exclusive page check

Use BCC after comparing against the first page above the image.
The success path leaves carry set for the upper-bound ADC. Clamp
the assembly-time threshold at $ff when the image ends at
$10000. The subsequent upper check rejects that final page.
The pinned assembler spells minimum as `<?`.

## Track immediate register values separately from N/Z

A 6502 store can use the known value in a register without modifying its
flags. Another register load can change N/Z while leaving the first register
unchanged. Track both facts and prove only the flag bits that may differ dead
after a redundant load. Walk the retained instructions after backward DCE and
exclude the candidate itself when following backedges. Layout can still
shift another hot branch across a page. The R97 bitwise-shift replay counted
26 new crossings against six cycles saved by the removed loads.

## Group uniform initializer stores by actual storage span

Equal-byte word initializers can share one scratch update and write each
destination byte from A. Adjacent fields may share a run when every original
store is inside its own static object and the offsets prove the combined
span contiguous. Compare with the actual preceding implementation. At
five words the indexed loop can tie the old per-word setup with zero-page
scratch and a crossing branch. Six words still gains cycles under that
layout. A pure byte run starts with less overhead and needs a separate cost.

## Keep a counted index in a free register

An existing short counted latch can replace INC and LDA with INX and
replace CMP with CPX. TXA gives the body its original index value and N/Z
from that value. Check the first iteration separately and prove its possible
N/Z difference dead. A private byte return can clobber X under the static
ABI. Keep the conservative return barrier for other register queries and
guard simultaneous edits against relying on old instructions in another loop.

## Load a register directly while retaining bus accesses

Replacing LDA and TAY with LDY keeps the physical flags and memory access
when the addressing mode is shared. The following load must kill the old A
before a consumer. When a table can use the X value already in the counter,
absolute X and Y indexing have the same bus behavior. Check that Y is dead
and that a zero-page encoding cannot change wraparound. Both forms retain
indirect read order and can run without narrowing the pointer's domain.

## Reuse a guarded copy count and restore equal flags

The high count byte loaded for the small-count guard survives the two
bounds checks and pointer setup. After initializing Y, TXA can test the
count without a second memory read. The final LDY #0 sets the equal
comparison's N/Z and SEC sets its carry while keeping A on the low count.
Leave SEC in the emitted sequence so ordinary liveness can remove it only
when the actual continuation kills carry.

## Let the fill matcher accept retained constant values

Register propagation can remove repeated LDA and TXA instructions before
the array-fill pass sees them. Require the first packet to establish A,
then track that same value through the exact stores and any retained TXA.
Match both emitted shapes so eliminating a local instruction cannot
disable the larger fill optimization.


## Matched calling convention measurements

Keep the workload and checksum shared between each static and software-stack
parameter benchmark. Measure the hardware stack separately from software-stack
writes, and report the software-stack reservation even if few bytes are touched.
A write watcher counts stores of the pre-existing byte value. A final memory
comparison would miss those stores. The write high-water mark can still fall
below the maximum extent reserved by active frames. See
`ABI_CALL_BENCHMARKS.md` for fixture scope and the mixed-width stack repro.

When eliding caller argument scratch, compute the maximum staged arity
across the whole frame. A function may forward one call and stage the next.
Share the forwarding predicate between frame planning and code emission.
Use the same retained call graph when checking for frame observers, so the
validation emission and pruned emission select consistent offsets. Exercise
overflow boundaries and inspect SP at actual callee entry, after both bytes
of the new software pointer have been written.

On 6502 software-stack word loads, TAX can capture the high byte before
the final LDA establishes low A and N/Z. A later PHA/TXA/TAX/PLA
reconstructs the same registers and costs cycles and one transient
hardware-stack byte. Adjacent INY/DEY changes N/Z like the equivalent
LDY immediate and preserves the carry used by the word add or subtract.
See `SOFTWARE_STACK_WORD_TRAFFIC.md`.

Direct word arithmetic on frame slots can keep the low result in existing
frame scratch while X carries the high byte. LDY, STA and TXA preserve the
carry from the low addition or subtraction. The final LDA restores N/Z
from the low result while leaving the high operation's carry and overflow.
Retaining that single scratch write avoids an extra hardware-stack byte.

When lowering a condition directly to flags, use a nearby body target
and an absolute jump for the potentially distant path. The general short
branch proof rejects a whole image containing the software-stack `BRK`
trap. A measured direct relative-branch prototype may therefore be smaller
than the range-safe emitter output even for a small body.

The software-stack overflow guard keeps the checked end in A:X on every
success path. A private static-to-stack bridge can publish that pair before
evaluating pure scalar arguments and still address their destination via FP.
Audit both the argument operands and the callee's ability to observe entry
registers before moving the store. A failed guard must reach the trap before
the new SP or parameters are written.

Static-to-stack cleanup copies FP to SP without indexing the frame. Use
LDY/STY for that copy when A and X carry the result and Y is unobserved.
Keep resident return cells available for the remaining nested and module
bridges. Nested cleanup uses Y to load the saved frame pointer and needs a
different way to preserve the low return byte.

A nested return can reuse a hardware-stack byte after JSR has returned.
The one-byte spill adds no depth beyond the two-byte call return address.
Audit raw reads of `$0100–$01FF` separately from the software stack area
and its zero-page pointers because the spill overwrites an inactive byte.

In a nested stack bridge, the last forwarded word's high byte remains in
X at callee entry. Later byte arguments leave X intact. Earlier forwarded
words can copy bytewise directly between the disjoint caller and callee
frames, while preserving that last register effect and the flags set by
the final destination index.

Allow the compiler-owned stack overflow BRK only in the branch-shortening
proof. Recognize its exact runtime section and keep arbitrary BRK, RTI, and
other control targets opaque. Keep this check separate from consumers that
use the same branch layout parser to justify data-flow rewrites.

Count a stack pointer access as two bytes only after verifying the
literal zero-page pair and raw operand spelling. The instruction parser
strips absolute width hints for its effects model. A direct symbol in
that model can still encode as a three-byte instruction.

A checked private software-stack SP stays at or below the configured
end. Use the complete reservation size when proving a 16-bit addition
cannot wrap. Nested calls can reserve 257 bytes because their link is
additional to a 255-byte callee frame. The carry proof only removes the
machine wrap check. The configured capacity check remains.


For upward-growing standalone software stacks, one unsigned check on
SP plus the saved link and callee frame proves both nested reservations.
A 255-byte frame plus its two-byte link needs a high-byte add even though
each frame size alone fits in an immediate byte. Keep the argument
evaluation before this check and test exact fits across a page boundary.

On a standalone stack-to-stack return, FP still denotes the callee
frame. The saved caller link starts at FP minus two. Use SP for the
stack-to-static bridge because its callee may itself call a stack
function and leave FP pointing at that frame.

A checked upward-growing stack keeps the callee's link and parameter
writes above the active caller frame. Plain matching scalar arguments
can read the caller slots after that check while FP still denotes the
caller. A size change to private scratch needs the same layout
selection in validation, bridge emission, and frame metadata.

## Inline machine declarations

Keep `memory`, `module`, `extern module`, and `module_loader` contextual at root declaration boundaries. Mask only the extension syntax for the pinned Zig parser. Preserve offsets and retain typed DLL prototypes for Zig grammar validation. Put frame selection in `callconv` and placement membership in `linksection` so the Zig grammar checks their position. Lower declarations to the existing options, ABI, and module records so pruning, relocation, and bank switching use the same configuration as legacy sources. Names used by runtime-looking heap calls bind to configured storage and have no runtime object representation. Preserve explicit near materialization and write-back operations. A named banked region requires an explicit ROM mode, and only the supported placement and DLL operations gain bank gateways.
