# Next Feature Plan: Local Placement, Access Lineage and Measured Passes

Extend the machine declaration checks with precise source spans for bad region claims, section names, and DLL row references. Keep the pinned Zig parser and existing runtime records. The next language design question is whether an explicit placement annotation in a local source import should resolve against the root application map. The current application-owned placement rule keeps ownership local.

Connect the record-pointer and footprint checks to table forwarding.
Audit direct and indexed memory operands for aliases of the staged
indices and table bytes. Treat an unknown write or observer as a
reason to keep the staged code. Bound X at the table accesses and
recheck the read footprints after shrinking the image. Then use the
measured table rewrite, which saves 15
bytes and 27,909–29,112 cycles in the three core layouts. The exhaustive
winner replay covers both board locations. See `INDEX_LOAD_FORWARDING.md`.

The Round 122 table prototype selects the managed scalar layout. Its
whole-image write audit still needs to rule out writes to executable
bytes outside the staged slots and parameter pairs. A full-byte write
bound can extend beyond a record into following code. Use source
bounds or a retained-instruction index proof before enabling the pass.
The prototype and diffs are in `build/opt-after/round122/`.

Initialize SP and FP directly for private stack-mode main frames that fit
their configured regions at compile time. The assembled prototypes save
42–46 PRG bytes and 47–51 Peddle cycles across three demos. Verify page
crossings, exact fit, undersized regions, and stable nested guard labels.
See `SOFTWARE_STACK_GUARD_CARRY.md`.

The fallback's repeated index publication still needs a source-domain
proof. The rebased prototype saves six bytes and 30 cycles, but raw
source reads can reach device space. Keep the existing fallback until
the source read is proved unable to change the index or scratch.

The direct word-read wrapper prototype saves three bytes and 594 cycles.
It needs literal-binding and image proofs before removing the stack
bridge. The dynamic copy can address resident code, static pointer slots
and inactive stack bytes. See `POST_STORE_LIVENESS.md`.

Keep the short-circuit table prototype under consideration when retained
call-site proof can authorize skipping indirect reads. Exercise mutable
tables, live index captures and MMIO reads in both selection paths.

Together, the repeated wrapper loads and duplicate fallback scratch
writes save ten bytes and 96 cycles in the R105 copy prototype. Check
the image guard's page threshold and pointer aliases before integrating
either. The fallback source read can observe scratch and can alter
an aliased value through I/O effects. See `GUARDED_COPY_COUNT_REUSE.md`.

The five archived assertion-dependent tools passed their strict reruns.
The R63 proof now counts ordinary RTS fetches separately. See
`NATIVE_PROOF_ASSERTION_AUDIT.md`.

Track the preexisting parser error-path double free separately. An
out-of-range literal assigned through a pointer registers two owners
for the target allocation in `parseDerefAssign`. Both the R63 and R64
compiler pins reproduce the allocator report before rejecting the source.
The minimized input and exact traces are in
`build/dead-store-r64-qa-agent/parser-repro/`.

Rebase the cost-selected local allocator onto the current guarded layout
tail. Continue the typed address proof for hot core locals, and measure
target RAM, cycles through normal return, and host compiler overhead. The
rebased page layout candidate has measured R46 gains on scalar and scratch
cores. Continue the code-only address-observer proof before integration.

R45 indexed literal multiplication is accepted. Three programs save 305 bytes
and run faster. The managed multiply-by-four probe releases six zero-page
bytes and its snapshot. The changed array demo passed VICE. See
`INDEXED_LITERAL_MULTIPLY.md` and the exact R46 baseline.

R44 indexed compound updates are accepted. Twelve images save 633 bytes and
all twelve run faster. The 103 saved module and placement controls and all
physical zero-page claims match. Both changed VICE demos pass. See
`INDEXED_COMPOUND_UPDATES.md` and the exact R45 baseline.

R43 unreachable instruction removal is accepted. It saves 743 bytes across
61 of 290 builds and 58 bytes in each core layout. The scalar core saves
1,435 cycles. Default and scratch add 1,111 and 337 cycles from page effects.
798 tests and the full host suite passed. The 97 R42 VICE runs bind to R43 by
identical regenerated plans and input binaries. See
`UNREACHABLE_CODE_STRATEGY.md` and the exact R44 baseline.

R42 index hold refinement is accepted. Both cast fixtures recover 80 PRG bytes
and 176 cycles in total. The other 288 PRGs and measurements match R41. All
103 module and placement controls, 290 label sequences and 290 zero-page
records match. See `INDEX_HOLD_REFINEMENT.md` and the exact R43 baseline.
The R42 VICE batch passed all 97 plans and 512 steps.

R41 pending-index correctness repair accepted at
`a04be736eacb0a8e3b3834455d45e66e4f27501b339cd66396befaac2405b95c`.
760 units, full host, 74 sections, 96 demos and eight report tests pass.
Four numeric store paths and affected many-pointer reads/byte stores now keep
their values/bases across index evaluation. No new resident/ZP word; two to four
temporary hardware-stack bytes. Source freeze has 113 files. Core unchanged;
two prior cast fixtures grow 80 bytes combined and slow 132 / 44 cycles. Next
optimizer step removes unnecessary holds for actual direct fields and transparent
numeric casts, then unreachable code removal. See PENDING_INDEX_VALUE_REPAIR.md.

R40 branch shortening accepted at
`efe4fcad17c309eff3bbbd2731202541fdf9b8ae71ff0219524c57c505a0197b`.
756units/fullhost/74sections/96demos/8reports pass.72of289 shrink1746B;70faster,
twoSoA policy images3Bsmaller/14cyclesslower from39extraindexedpage penalties
versus25structuralcycles saved. Core saves147B/12865–14402cycles across3policies;
all289labels/ZP policies and103module/placementPRGs preserved. See
SHORT_BRANCH_STRATEGY.md and optimization/round40 reports; source100files frozen.
Current parallel work: unreachable machine-code removal, reviewed local placement
and lifecycle profitability selection, and corrected access v2. The R40 producer
checkpoint is frozen; rebase to repaired actual stack/field instructions before
using it in production. It remains provenance, not EA/value/placement authority.

R39 pointer-field representation repair is accepted at
`34b994f92b2be98a0c8b6f5afa37c236666c285f85944782011e5b3d26cc5c61`.
742units/fullhost/74sections/96demos/8reports pass. All288 prior complete
outputs/policies/timings match R38; the new289th regression now passes. No target
optimization gain is claimed. See POINTER_FIELD_WIDTH_REPAIR.md and round39
reports. Final source97files is frozen separately from the failed first candidate.
Next measured pass is final branch/JMP inversion with encoded range proof;
private fullclosure local placement and corrected access v2 remain under review.
When composing local-map replay with post-ZP layout, reconstruct and validate
the same final stage; do not silently omit final-assembly validation.

R38 compact zero-test values are accepted at compiler
`ab822c696bcfa4dac1295d51afca4c92531150a734a4f91087cf8de1ca883932`.
718 units, full host, 74 sections, 96 demos and eight report tests pass. Nine
of 288 programs shrink136B, eight run faster and none grow or slow. Core saves
28B and974–1389 cycles by policy; structural1356 cycles and page effects are
separated. All source labels/parameter policies and103 saved module/placement
control PRGs are preserved. Native graph65536pairs/32768D and actual CLI source
49152pairs/24576D have exactCPU/all64K/no masks. The slower inverse and casefold
counterexample remain excluded history. Exact R39 baseline is frozen.
See optimization/round38-build-verification.json and ZERO_TEST_VALUE_STRATEGY.md.
R30 was the real ROM checkpoint at this stage. The full batch was rerun at R42.

Next implementation work has isolated owners:

- Profile branch and indexed page crossings on the guarded R43 core. Use measured
  sites to test bounded layout changes with independently checked address and
  section constraints. Keep hot improvements and any size costs visible.
- Correct raw access producer structure before integration: copied source For
  context, real/optional evaluation windows, statement/anchor structural replay,
  and truthful separation of index/prelude/counter widths from final 16-bit EA.
  Preserve original retained-inventory API and ordinary null-sink behavior.
- Carry explicit position lineage through actual stride writer edits and runtime
  appends. Bind old/new snapshots, preserve/replace/append events and anchor IDs;
  never rebind repeated instructions by text/owner/ordinal. EA, dependency,
  guard, clobber and final-pipeline proof remain separate and unresolved.
- Implement typed ordinary/capture/counter local placement and the planned
  main-entry tier under existing .scalars. A first gate may authorize only a
  complete simple canonical machine-memory closure; unknown indirect/indexed,
  external/native pointer, DMA, ASM and helper effects pin globally. Independent
  map replay, full widths, policy/ranges/reserves, deterministic ranking, cold
  lifecycle costs and tight-pool evictions are required before new claims. The
  first active prototype and independent QA are green privately, including real
  parameter eviction. Rebase final-map replay to R40 before integration, then add
  measured lifecycle profitability selection so cold functions stay resident.

Keep the full broader allocation goal: a pure/direct first gate is not the end
state. The core's 38 local cells / 53 bytes / 41,427 measured accesses remain a
ceiling, NOT PROVEN. Actual source counters and object bounds are conditional;
overlapping writes KILL field facts. Game is 64B (the old65B note has an erratum).
Do not assume a private numeric frame ABI, native input masks, enum/type bounds,
constructor invariants after clobber, or existing parameter safety as an axiom.

R36 provides independently owned original typed roots/cells from the selected
retained emission; discard dry semantic facts and still reject invalid unused
code. R37 adds bounded rejection-only domain evidence, preserving older reasons
and R33's separate strict local copy proof. Neither is a relocation certificate.
Broader closure joins real origin/index/counter bounds, machine/source spans,
optimizer lineage, mutual-clobber induction and future-pool binding. Private
archives local-alias-prototype and counter-access-prototype remain diagnostic.

Reference-kernel comparison against Oscar64/Prog8 follows more internal
progress; do not replace saved original/prior compiler baselines with competitor
numbers. Preserve public module/DLL roots, ordinals, relocations and placement
paths. Original controlled totals through R40 remain in
optimization/overall-through-round40.md and overall-memory-through-round40.md;
R36/R37 changed no target output. Keep regressions and measurement limits visible.

## Deferred module and comparison backlog

### Recommendation

The dynamic-module roadmap is now through slice 59: multi-window activation, BASIC/KERNAL banked windows, KERNAL export hardening, and console-only KERNAL-bank trampolines are implemented for current-module and dependency exports.

Configurable image origins, shared named C64/REU regions, direct/startup-copy placement, and arena/DLL region consumers have also landed. They are now baseline infrastructure rather than the next feature: preserve their map schema and focused Peddle/VICE proofs while continuing the module roadmap.

When module work resumes after the optimization priority, finish the final pre-UCI/Ultimate stabilization sequence. UCI/Ultimate direct loading remains deferred until that sequence passes.

The ReadyOS proof adds a subsequent hosted-runtime track, documented in `docs/readyos-precog.md`. It should begin only after the current stabilization gate: first a `$1000` lifecycle trampoline, then a shared host-allocation interface used by both Memory Arenas and DLL caches. ReadyOS remains the physical REU allocation authority; named regions remain the common claim vocabulary.

### Immediate Next Slice: 60

Add a focused KERNAL trampoline ABI cleanup and payload-size pass:

- document and enforce the current payload-local console state behavior for KERNAL-bank module trampolines;
- emit only the console helper bodies needed by reachable KERNAL-bank exports so literal console output does not carry unused clear/string/hex helpers;
- keep every payload-local helper operand covered by relocation anchors, including helper data references and internal `JSR`/`JMP` instructions;
- add a small size report for KERNAL-bank console exports so the trampoline cost is measured before adding any broader KERNAL-backed APIs;
- preserve the current compile-time safety split: console literal/string paths are trampoline-safe, while keyboard, raw KERNAL, disk, inline asm, and unsupported helper paths remain rejected until explicitly lowered.

### Follow-Up Slices

- 61: close relocation/imported-stub/selected-payload gaps, including multi-window and KERNAL-trampoline activation edge cases.
- 62: consolidate the banked module safety matrix across visible, BASIC-under-RAM, and KERNAL-under-RAM windows for current, dependency, and graph-node rows.
- 63: reconcile roadmap, overlay, memory-model, language, ABI, testing, and learning docs with the final pre-UCI state.
- 64: run the pre-UCI stabilization gate with full relevant build, host emu, sidecar/section-marker, optional VICE, and size/liveness checks.

### Tests To Preserve

- Current-module `.ram_under_kernal` exports without KERNAL calls still load and dispatch normally.
- Current-module console exports print through the trampoline, restore `$0001`, and return scalar values.
- Dependency console exports assigned to `.ram_under_kernal` load from disk, activate into the assigned window, print through relocated helper code, restore `$0001`, and return scalar values.
- Sidecars continue to record `requires_kernal_rom` and `kernal_trampoline_safe`; older sidecars default the trampoline flag to false.
- Stack-frame code still rejects unsupported runtime helpers except the narrow literal/string console allowance.
- Host emu remains the fast proof for relocated payload bytes; VICE coverage stays optional and environment-gated, but the full VICE small-demo pass should run once after the next runtime/banking change.

### Boundaries

- No UCI/Ultimate direct loading in the final pre-UCI sequence.
- No target-side JSON/binary sidecar parsing.
- No automatic dependency graph resolution or transitive autoload.
- No broad disk, keyboard, raw-KERNAL, or inline-asm trampoline in the same cleanup slice.
- No final status-flag return guarantee beyond preserving processor status across bank wrappers.

### Independent Small Follow-Up From The Greeting Comparison

The compile-only greeting examples do not change the loader roadmap above.
The next small timing-runtime fix should make `sleepFrames` distinguish raster
lines 0 and 256, with dedicated host/VICE timing coverage when execution is
authorized. The new buffered display micromodule remains assembly-assisted;
future ordinary MMIO-loop optimization should be guided by the saved console
and buffered baselines rather than by PRG size alone.

The mostly high-level buffered variant now provides an additional measured
code-size baseline (2,247-byte PRG; 5,275-byte resident RAM; ten handwritten
module asm instructions). When this deferred comparison resumes, the likely
optimizer target is repeated typed-struct pointer materialization and constant
row-stride arithmetic, rather than converting more source back into assembly.

Keep the balanced typed-state/bulk-asm variant as a third baseline as well
(1,836-byte PRG, 4,865-byte resident RAM, 66 handwritten module instructions).
Future optimization should compare all three rather than replacing the
source-readability tradeoff with an assembly-only result.

The buffered C comparisons now include cc65 (1,249/4,297 PRG/resident bytes),
portable Oscar64 (593/3,632), and a separate idiomatic Oscar64 (656/3,702).
Keep both Oscar64 styles: native APIs and two-span `memcpy` are a readability
and implementation choice, not automatically a file-size improvement. These
compile-only additions stay separate from the active same-source ZeroPage
optimization measurements above.
