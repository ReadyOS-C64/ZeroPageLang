# Testing

The test suite separates compiler behavior, generated 6502 behavior, assembler integration, and full C64 integration. Most language work can be checked without launching VICE.

## Test commands

| Command | Purpose | Required tools |
| --- | --- | --- |
| `zig build test` | Unit tests for the compiler and host emulator runner | Zig |
| `zig build e2e` | Assemble the small demos and verify their artifacts, including D64 images | Zig, 64tass, Bash, Perl, `c1541` |
| `zig build asm-test` | Run the same small-demo gate as `e2e` | Zig, 64tass, Bash, Perl, `c1541` |
| `zig build emu-test` | Compile fixtures and run PRGs in the Peddle-backed host runner | Zig, 64tass |
| `zig build section-marker-test` | Verify ownership markers and `.zpmap.json` without changing PRG bytes | Zig, 64tass, Bash |
| `zig build size-report` | Build PRGs and write size reports under `build/size-report/` | `e2e` tools, Python 3 |
| `zig build vice-test` | Run optional headless C64/REU integration plans | `e2e` tools, `x64sc`, .NET SDK, VICE task harness |

Run `zig build test`, `zig build emu-test`, and `zig build e2e` for a normal language or backend change. Add the focused section, size, or VICE gate when the change affects that contract.

## Fixture layout

```text
tests/fixtures/emu/
  lang/pass/          pure language behavior
  lang/fail_compile/  expected compiler diagnostics
  lang/fail_runtime/  expected target-side assertion failures
  smoke/              screen, KERNAL, keyboard, MMIO, and REU behavior
  modules/            separately compiled module payloads
```

Pure language fixtures use `@import("test6502")` and belong under `lang/`. Keep C64 I/O out of them so failures identify language or code-generation problems. Use `smoke/` for visible hardware behavior. Larger parity sweeps should live in a named subdirectory rather than a new catch-all file.

Compile-negative fixtures include a matching directive:

```zig
// zeropage-emu-error: expected diagnostic text
```

## Host 6502/6510 runner

`emu-test` assembles each fixture, loads the PRG into a Peddle-backed 6510 runner, and starts at `main` or the generated `$080d` entry point. It stops at the generated test exit or an explicit `test6502` pass/fail hook.

The runner observes target memory, labels, test snapshots, KERNAL output, and a simulated 16 MB REU. It models the KERNAL calls used by the project: `CHROUT`, `GETIN`, `SETNAM`, `SETLFS`, and `LOAD`.

Leading comments can configure a case:

```text
zeropage-emu-start: program_entry
zeropage-emu-disk: enemyrt
zeropage-emu-module: filename=enemyrt source=tests/fixtures/emu/modules/enemy_runtime.zp64
zeropage-emu-memory: $c000=$4c
zeropage-emu-label-memory: zeropage_module_registry_loaded=$01
zeropage-emu-reu: $030000=$4c
```

`zeropage-emu-module` compiles a separate source into a module disk payload and supplies its sidecars to the consuming build. This proves the real packaging and relocation path without target-side metadata parsing.

## Demo and application gates

`scripts/verify_small_demos.sh` compiles the numbered examples under `examples/small/`, validates their expected artifacts, and checks the PRG load address. It uses `c1541` to package and inspect module-loading D64s even without launching `x64sc`. If needed, set `ZEROPAGE_C1541` to the executable's absolute path.

`scripts/verify_sampleapps.sh` compiles application-sized examples separately. Use `--skip-build` when `zp64c` is already built, and `--vice` to run their UI plans.

Examples demonstrate features, but assertions belong in unit or emulated fixtures as well. A new supported construct should normally have:

- a successful compiler or emulator case;
- a rejection case for unsupported or invalid forms;
- a C64 smoke case only when hardware-visible behavior matters;
- documentation in the language, API, ABI, or memory reference it changes.

## Optional VICE tests

VICE tests exercise generated programs in `x64sc`, including real screen output, keyboard input, KERNAL disk loading, banking, and a 16 MB REU. They are intentionally environment-gated because the UI task harness is maintained outside this repository.

Configure tools with:

```sh
export ZEROPAGE_VICE_X64SC=/path/to/x64sc
export ZEROPAGE_C1541=/path/to/c1541
# Optional: prepare a source harness outside the default sibling location.
python3 scripts/prepare_vice_harness.py --source /path/to/ViceTasks.Binary.csproj
export ZEROPAGE_VICE_TASKS="$PWD/build/vice-harness/ViceTasks.Binary/ViceTasks.Binary.csproj"
zig build vice-test
```

The repository includes generated-plan code and verification scripts. It does not include VICE, .NET, the external task harness, ROM images, or disk images.

With the default sibling harness, `zig build vice-test` prepares an isolated,
pinned bridge with the established macOS monitor-readiness fix. The original
bridge can misreport an available monitor as unreachable because it relies on
TCP-listener enumeration. A monitor timeout alone is not evidence of an emulator
crash. See [test dependencies](dependencies.md#optional-and-test-only-tools).
An explicit `ZEROPAGE_VICE_TASKS` overrides that prepared project; the example
above prepares the platform fix before selecting the override. Border-only
plans use bounded retries on the actual expected MMIO value, allowing autostart
to complete without relying on a fixed delay or injected keypress.

Image and region behavior has fast Peddle coverage in `tests/fixtures/emu/lang/pass/abi/`: custom raw image entry, direct placement, startup copy under KERNAL ROM, and named arena/DLL/REU-cache integration. Matching compile-fail fixtures cover invalid image limits and entry points, overlapping or wrong-space regions, invalid bank modes and reservations, unknown placement sections, unsafe resident reads of banked constants, invalid pools and far materialization targets, and invalid DLL declarations and loader policies.

Small demos `95_memory_regions_placement.zp64` and `96_memory_regions_dll.zp64` are the UI automation proofs. Their VICE plans assert screen completion, direct-placement and arena bytes, processor-port restoration, the active DLL window, and an REU dump.

## Backend changes

For a behavior-preserving refactor, save hashes of the generated PRGs before editing and require byte-for-byte equality afterward. Assembly and label snapshots are useful for diagnosis, but PRG bytes are the gate.

For an optimization, behavior is the stronger proof. Save a pre-change size table, run the normal behavior suites, then compare `zig build size-report` with `ZEROPAGE_SIZE_BASELINE=/path/to/prg-sizes.tsv`. Document intentional growth instead of hiding it.

## Optimization measurements

Use Peddle for the fast inner loop. Select related fixtures with comma-separated
path substrings, for example:

```sh
ZEROPAGE_EMU_FILTER='tictactoe_core,optimization_' zig build emu-test
```

An empty selection fails. Targeted runs print a distinct `targeted-peddle`
completion line and cannot be mistaken for a full-corpus snapshot. Run broader
host and VICE gates after substantial optimization batches, following the user's
requested cadence. Record deferred gates and the last green VICE checkpoint.

`zig build emu-test` emits tab-separated `host-metrics` rows after each successful
case: source, PRG path, PRG file bytes (including the two-byte load header),
stepped CPU cycles, stepped instructions, and intercepted call count. Peddle's
host advances its clock once per microcycle, including idle and page-crossing
cycles. Counters begin after reset/setup and end when the fixture completes.

KERNAL and test hooks are intercepted without executing their `JSR`, callee,
or `RTS`; their costs are excluded. This is useful for comparisons of pure
language fixtures with identical inputs and hooks. It is not whole-C64 timing:
VIC stalls, real CIA/ROM/drive behavior, and REU transfer timing are not modeled.
Smoke-case counters are observations only. Use VICE for hardware-facing proof
and separately designed timing plans for wall-clock or raster/frame claims.

Use immutable snapshots for each pass (choose a new round name each time):

```sh
zig build emu-test > build/round-before.log 2> build/round-before.err
python3 scripts/optimization_report.py snapshot --label before \
  --emu-log build/round-before.log --output build/round-before.jsonl
# Apply the optimization, then repeat the behavior suites.
zig build emu-test > build/round-after.log 2> build/round-after.err
python3 scripts/optimization_report.py snapshot --label after \
  --emu-log build/round-after.log --output build/round-after.jsonl
python3 scripts/optimization_report.py compare \
  build/round-before.jsonl build/round-after.jsonl --output build/round-comparison.md
zig build optimization-report-test
```

Snapshots require a completed host suite and fresh artifacts whose byte sizes
match the log. They save source/import and binary SHA-256 values plus compiler
hashes. `--extra source.zp64=output.prg` adds a freshly compiled size-only sample;
compile that artifact with the corresponding before/after compiler first.
Counters are absent for size-only samples. The report compares common inputs,
rejects source/import or interceptor-count changes, and lists added/missing
artifacts separately. It refuses to overwrite prior snapshots/reports. Back up
the pre-change compiler and assembly under `build/opt-baseline/` when deeper
binary diagnosis may be needed.

### Calling convention benchmarks

The `optimization_reference/abi_calls/` fixtures pair the same scalar workload
and expected checksum with static parameters and software-stack parameters.
Both variants keep the harness and driver static. The nested benchmark
also exercises a stack-to-stack call while the caller has live local values.
The full host suite includes all six variants, and optimization comparisons
print both conventions for each workload even when a compiler round leaves
their measurements unchanged.
The standalone size report also shows the static and stack PRG sizes side by
side, with separate deltas when the selected size baseline contains those
artifacts. Full and targeted measurement snapshots require every variant.

For a fast, standalone before/after comparison, collect each run with
`ZEROPAGE_EMU_FILTER=optimization_reference/abi_calls/ zig build emu-test` and
pass `--abi-only` to the snapshot command above. Set
`ZEROPAGE_TEST_COMPILER` to the pinned compiler for the baseline. Save the
first snapshot before running the second compiler because the runner writes
to the same artifact paths. Use separate log and snapshot paths. The targeted
snapshot requires the complete matched suite.

The fixture metadata enables stack measurement. `host-stack-metrics` records
the source, peak 6502 hardware-stack depth, highest byte written in the
software-stack region, and the region's reserved size. The write extent can
be smaller than the space reserved by live frames. The static-frame column
sums the assembler map's resident static-frame sections, already included in
the PRG size. The software-stack reservation is additional RAM. The stack
variants also use two zero-page pointer pairs for their stack and frame
pointers. The comparisons use the same Peddle timing model as the full suite.

Save durable round data and interpretation in `AgentWorking/optimization/` and
`AgentWorking/OPTIMIZATION_FINDINGS.md`. Retain both favorable and unfavorable
rows. Source-import hashing follows local `.zp64` imports; built-in compiler
changes are identified by the compiler hash. Source-level size reports do not
measure total resident RAM, BSS, zero-page usage, or stack capacity.

For an optimization baseline, set
`ZEROPAGE_TEST_COMPILER=/absolute/path/to/saved/zp64c` during `zig build emu-test`.
Both passing and negative fixtures then use that exact saved compiler even if
the build installs a newer `zig-out/bin/zp64c`. Pass the same executable to the
snapshot tool's `--compiler` option. Omit the override for after measurements.

Capture metrics from a dedicated `emu-test` stream. When recording a parallel
build log, pipe through `tee` and enable shell `pipefail`; direct multi-process
redirection can leave incomplete metric data. The snapshot tool checks that
metric rows equal the reported language-pass plus smoke counts, even when a
completion footer is present. A partial corpus must not become a size/performance
claim merely because missing rows were excluded from a comparison.

For runtime page-layout changes, `scripts/verify_runtime_loop_pages.py` assembles
the actual clear-screen and multiplication bodies at every low-byte origin and
executes all 512 cases through the Peddle C ABI. It checks results, filler skips,
branch pages, cycle counts, and bounded padding. On macOS, build its shared shim
with an available C++ compiler, then run:

```sh
c++ -dynamiclib -std=c++20 -O2 -Ithird_party/peddle -Ithird_party/peddle/Peddle \
  third_party/peddle/zeropage_peddle.cpp third_party/peddle/Peddle/Peddle.cpp \
  third_party/peddle/Peddle/PeddleDebugger.cpp \
  third_party/peddle/Peddle/PeddleDisassembler.cpp third_party/peddle/Peddle/StrWriter.cpp \
  -o build/peddle-loops.dylib
python3 -B scripts/verify_runtime_loop_pages.py --library build/peddle-loops.dylib
```

Assembler resolution uses `--assembler`, `ZEROPAGE_64TASS`, sibling tooling,
then `PATH`. Outputs remain under `build/runtime-loop-pages/` by default.

Use the same shared shim for exhaustive runtime multiplication verification:

```sh
python3 -B scripts/verify_runtime_products.py --library build/peddle-loops.dylib
```

This assembles the real helper and checks all 65,536 byte operand pairs, 256 word
boundary pairs, and 4,096 deterministic word pairs against host integer products.
It varies incoming carry and checks A/X, result and consumed scratch slots, Y,
hardware stack pointer, instruction counts, and CPU cycles excluding final RTS.
`--runtime`, `--base-cycles`, and `--base-instructions` permit testing a saved
pre-pass runtime with its original timing contract. Normal source fixtures also
check literal host-calculated expected products through the full compiler path.

`scripts/verify_pointer_reuse.py` uses the same shared shim to compare PRGs from
saved/current compilers for `optimization_pointer_base_reuse.zp64` and
`optimization_pointer_alias_barriers.zp64`. Compile each fixture with each
compiler, retaining its `.labels` file, then run:

```sh
python3 -B scripts/verify_pointer_reuse.py --library build/peddle-loops.dylib \
  --before-read build/before-read.prg --after-read build/after-read.prg \
  --before-alias build/before-alias.prg --after-alias build/after-alias.prg \
  --output build/pointer-equivalence.json
```

The 6,656 paired cases cover every pointer low byte, word page crossings,
all four-by-four byte index pairs, calls, branches, volatile accesses, and
assembly clobbers. Native-only cases also make an indirect store overwrite the
pointer parameter slot itself; this does not extend source address-of syntax.
Checks compare host-calculated results, A/X/Y/P/SP, record writes, and final
pointer scratch. CPU counts exclude the final top-level RTS. These focused
equivalence tests supplement the normal host suite and configured VICE gates.

For value/stack cleanup, compile `optimization_value_cleanup.zp64` and
`optimization_stack_cleanup.zp64` with saved/current compilers, then use:

```sh
python3 -B scripts/verify_value_cleanup.py --library build/peddle-loops.dylib \
  --before build/before-values.prg --after build/after-values.prg \
  --before-stack build/before-stack.prg --after-stack build/after-stack.prg \
  --output build/value-equivalence.json
```

The 262,144 paired cases cover all byte values with 64 input-flag combinations
and every 16-bit value in both word probes. Checks compare A/X/Y/P/SP, complete
function-frame RAM, host expected results where applicable, and pointer scratch.
Private frame addresses are compared by owner/byte offset because code shrinkage
can relocate them; fixed RAM/IO addresses remain literal. The earlier pointer
verifier uses the same address-identity rule. Two CPU reads of the modeled CIA
timer must still produce separate values. Half the value cases set decimal mode
to challenge flag handling; this compares NMOS behavior and does not add a source
decimal-arithmetic guarantee. Dead hardware-stack bytes are excluded under the
existing private-stack ABI; the live SP is checked exactly.


For loop-invariant bases and direct ALU operands, compile the matching
`optimization_loop_invariants.zp64` or `optimization_direct_operands.zp64`
fixture with saved/current compilers, then run:

```sh
python3 -B scripts/verify_loop_invariants.py --library build/peddle-loops.dylib \
  --before build/before-loops.prg --after build/after-loops.prg \
  --output build/loop-equivalence.json
python3 -B scripts/verify_direct_operands.py --library build/peddle-loops.dylib \
  --before build/before-direct.prg --after build/after-direct.prg \
  --output build/direct-equivalence.json
```

The loop matrix has 26,624 paired cases across all pointer low bytes, with
nested/zero-trip loops, early returns, scalar callees, aliasing stores, source
reassignment, and volatile callees. The ALU matrix has 728,064 paired cases,
including all byte pairs for each of five operators and all word values against
a permuted RHS. Both compare A/X/Y/P/SP, current function frame RAM, visible RAM,
and pointer-scratch identity, plus binary-mode host result oracles. Decimal
cases compare actual NMOS execution rather than assume binary arithmetic.

Rebuild the shared library after changing the C wrapper. Its bounded native
`run_until_rts` entry point accelerates these matrices using exactly the same
microcycle stepper; nested calls execute normally and the final top-level RTS
is excluded. BRK/budget stops fail the matrix. A unit test compares registers
and exact cycle/instruction counts with ordinary stepping. Python retains a
stepping fallback for older shared libraries. This entry point does not replace
the normal hook-aware fixture runner.


For bounded capture ranges and shifts, compile the corresponding
`optimization_loop_ranges.zp64` and `optimization_shifts.zp64` with the pinned
before/current compilers, then use:

```sh
python3 -B scripts/verify_loop_ranges.py --library build/peddle-loops.dylib \
  --before build/before-ranges.prg --after build/after-ranges.prg \
  --output build/range-equivalence.json
python3 -B scripts/verify_shifts.py --library build/peddle-loops.dylib \
  --before build/before-shifts.prg --after build/after-shifts.prg \
  --output build/shift-equivalence.json
```

The 647,680 range pairs seed complete current frames, exercise all word seeds
in eight functions, and test direct/callee aliases to both capture bytes. Only
private-pointer argument address bytes are normalized, with the pointed-to
identity and all other frame bytes checked. The 2,807,808 shift pairs include
all word inputs at every legal literal count, byte/count/flag cross products,
all runtime byte counts, nested shifts, all assignment forms, operand effects,
and volatile word reads even at count zero. Both compare complete A/X/Y/P/SP,
visible RAM, pointer scratch identity, and binary host oracles. CPU decimal
cases compare actual execution without adding a source decimal-mode guarantee.

For constant-result switches, `scripts/verify_switch_results.py` accepts normal
before/after PRGs, supplementary `--before-large`/`--after-large` PRGs, the Peddle
`--library`, and an `--output` JSON path. It checks 623,616 paired calls, including
311,808 decimal cases: every word selector, all byte/64-flag combinations,
biased/holey/full tables, raw signed keys, casts/enums/bools/chars, direct ranges,
known/uniform outputs, payload fallback, selector effects, and volatile read width.
A second CIA read independently proves an otherwise discarded selector still ran.
The proof compares A/X/SP, I/D/V, complete current frames, visible RAM and pointer
identity. It explicitly counts changes in caller-clobbered Y/C/N/Z rather than
claiming those accidental outputs are preserved. Source callers also consume the
results under normal assertion tests. The supplementary large probes use the
same pinned 64tass `-B` on both sides; their metrics are excluded from the normal
corpus because the previous CLI did not relax those large legacy branches.

`scripts/verify_index_register.py --before BEFORE.prg --after AFTER.prg
--library PEDDLE.dylib --output REPORT.json` checks 131,072 index-reuse pairs,
including 65,536 decimal cases. It compares exact A/X/Y/P/SP, current frames,
visible RAM, canonical pointer scratch and independent binary results over
all byte inputs/64 flag combinations. Cases include alternative indexes,
mutation, control flow, calls, pointer stores aliasing the cached index and two
real CIA reads. Only explicitly seeded private-frame pointer argument bytes
are normalized after checking the target owner/field identity.

Oscar64-inspired source workloads live under
`tests/fixtures/emu/lang/pass/optimization_reference/`. The adjacent `zero_page_`
variants declare application-owned policy and retain the same algorithm. Pure
fixtures use current supported expressions, loops and pointers; no C extensions
are accepted. `scripts/verify_oscar64_workloads.py --prg-dir DIR --library LIB
--output REPORT.json` checks nine precompiled PRGs, independent results/RAM and
6,809 direct kernel cases, separately from hook-aware fixture execution.

`scripts/verify_zero_page_lifecycle.py --prg-dir DIR --library LIB --compiler BIN
--output REPORT.json` executes the ten `tests/fixtures/optimization/zero_page_lifecycle_*`
PRGs through actual entry/normal return. It seeds all ZP and checks reservations,
BASIC/KERNAL protection, moved-cell initialization, pointer/string aliases,
fragmented capacity, strict stack pointers, startup copies, restore=false,
current main-return registers/physical flags and live caller-stack bytes. Its
60 entry cases and448 helper pairs supplement host language assertions.

The normal host pass hook and `zeropage_test_exit` stop BEFORE lifecycle leave.
Thus configured host counters include entry setup but exclude subsequent
restoration. Do not label them complete program costs. Native entry proofs
continue beyond pass hooks, report body/entry/exit separately, and verify restored
system state after cleanup. Small programs may lose overall speed despite better
kernels. VICE is still needed for real ROM/IRQ/BASIC-return proof; Peddle does not
simulate ROM execution or stock interrupt behavior.

Private parameter promotion has a paired native proof:

```sh
python3 scripts/verify_zero_page_scalars.py --before BEFORE_PRGS --after AFTER_PRGS \
  --library PEDDLE_LIBRARY --output REPORT.json
```

Compile identical `.allocation = .scalars` fixtures with the saved scratch-only
checkpoint and the promotion-enabled compiler. The verifier checks exact
A/X/Y/P/SP, individually named parameters/locals, canonical pointer identity,
independent results and reserved RAM. It checks typed byte/word/bool/enum/pointer
values, known nonleaf calls, pointer aliases into parameter low/high bytes,
software-stack-to-static bridges, fixed application reservations and exclusion
boundaries. Its scratch-only control must remain byte-identical. Full-entry
cases start at `zeropage_entry` and continue through initialization, source
return and restoration; native direct calls measure kernel costs separately.
Source code still requires binary arithmetic mode. Decimal-mode machine proofs
cover their reported cases and do not extend the source or software-stack ABI.

The accepted R21 evidence is
[`round21-native-scalars.json`](../AgentWorking/optimization/round21-native-scalars.json)
(357,952 paired calls, including 178,464 decimal cases) with
[`native provenance`](../AgentWorking/optimization/round21-native-provenance.json).
[`round21-entry-partitions.json`](../AgentWorking/optimization/round21-entry-partitions.json)
separates body, entry and exit costs for eight before/after complete entries.
[`round21-targeted-vice.json`](../AgentWorking/optimization/round21-targeted-vice.json)
and its [provenance](../AgentWorking/optimization/round21-targeted-vice-provenance.json)
record two normal BASIC `SYS` runs with promoted values live across real
CHROUT/GETIN and stock IRQ activity, followed by return and usable BASIC. These
are normal-return proofs; STOP/RESTORE and arbitrary NMI exits remain outside
the preservation contract. Compare sizes and host cycle counts using the saved
[`R21 comparison`](../AgentWorking/optimization/round21-comparison.md), retaining
slower complete-entry cases alongside kernel improvements.

Fixed-stride helper proof can be regenerated directly from compiler code:

```sh
zig run src/stride_probe.zig > build/stride-probe.asm
64tass --m65xx --cbm-prg --vice-labels -l build/stride-probe.prg.labels \
  -o build/stride-probe.prg build/stride-probe.asm
python3 scripts/verify_stride_helpers.py --prg build/stride-probe.prg \
  --library build/peddle-loops.dylib --output build/stride-helpers.json
```

It checks 3,039,680 paired calls (1,519,840 decimal), all word values at23 factors,
flag boundary cross-products, exact A/X/Y/P/SP/result scratch/canaries and actual
helper byte lengths. The durable generator's PRG matches the accepted proof.
`scripts/verify_stride_addresses.py` accepts precompiled before/after PRGs and
runs the supplemental `stride_address_equivalence.zp64` source matrix. Its
786,432 production binary pairs compare all word inputs, valid indexes, exact
state, current frames, independent row/result oracles and canaries. Another
30,464 flag cases use explicitly normalized private-frame addresses, including
15,232 decimal. Production-D frame-relocation diagnostics are recorded separately;
they are not counted as passed production-program parity.


### Scalar call argument optimization (round22)

The accepted same-source comparison is
[round22-comparison.md](../AgentWorking/optimization/round22-comparison.md):
288 artifacts, 83 smaller, 7,195 fewer bytes, no size increases; 81 faster and
2 slower host cases. Exact instruction-page branch penalties for both slower
cases are preserved in
[round22-final-regressions.json](../AgentWorking/optimization/round22-final-regressions.json).
Early marker-barrier candidates are separately named and are not acceptance data.

[Native call proof](../AgentWorking/optimization/round22-native-call-arguments.json)
covers 18,240 paired calls, including 8,640 decimal-mode cases: pre-JSR and exit
A/X/Y/P/SP, typed source objects/pointers, canaries, nested/alias/ABI barriers and
ordered stateful CIA/raster reads. Seven full normal-return fixtures improve or
stay equal. `scripts/verify_call_arguments.py` reproduces the private proof with
explicit compiler/artifact inputs. Dead compiler captures are not source objects;
normalization is restricted to verified typed private pointers, never broad RAM.

The pass is covered by actual parser/emitter backend tests and suffix machine
barriers; 461 combined unit tests pass. Full173 language/109 smoke,546 compile-fail,
7 runtime-fail,74 section cases,96 demos and8 report tests pass. No additional
VICE sweep was run for this pure call-copy change; R21's actual ROM restoration
proof remains the latest system gate. Optional source-effect call planning is
unit-tested but does not authorize production rewrites without lowered checks.


### Boolean branch materialization (round23)

[Round23 comparison](../AgentWorking/optimization/round23-comparison.md) retains
288 unchanged sources:16smaller/-187bytes,15faster/one+1cycle row, no size growth.
The [native proof](../AgentWorking/optimization/round23-native-booleans.json) and
[provenance](../AgentWorking/optimization/round23-native-provenance.json) cover
419,200 paired calls,209,600decimal-mode cases, complete physical CPU state,
independent C/V/I/D invariants, named objects/guards and ordered XOR/CIA effects.
Both byte functions exhaust every pair with Dclear/set. Six complete entries
improve or remain equal; ASM and value-only controls are complete-PRG identical.
475unit/fullhost/74sections/96demos/eightreport tests pass. No additional VICE
sweep was needed for this pure fold. The flag proof does not extend the language
ABI to BCD arithmetic or unsupported signed ordering.


Timing boundary clarification for R22/R23 native entry tables: they run through
main return and all lifecycle cleanup, then stop immediately before the final
top-level RTS. That shared six-cycle RTS is excluded from both columns. Source
assertion hooks are intercepted; VIC/CIA/ROM elapsed time is not included. These
are full entry/body/cleanup CPU partitions, not actual ROM SYS-return timing.
R21's separate real-ROM VICE proof executes the genuine SYS/RTS return and
subsequent BASIC commands. Kernel paired calls retain their stated native-call
scope. See each native provenance entry_scope for exact boundaries.


R23's one-cycle slower row is explained in
[round23-regressions.json](../AgentWorking/optimization/round23-regressions.json):
8 saved main cycles are outweighed by the existing multiply-alignment JMP on
three calls (9 cycles). This is retained acceptance data, not a filtered outlier.


### CFG dead register assignments (round24)

[Round24 comparison](../AgentWorking/optimization/round24-comparison.md) covers
288 unchanged sources:20smaller/-234bytes,21faster,no size or host-cycle increase.
489unit/fullhost/74sections/96demos/eightreport tests pass.
[Source proof](../AgentWorking/optimization/round24-native-source.json) has419,200
paired probes; [graph proof](../AgentWorking/optimization/round24-native-graphs.json)
adds16,384 pairs over32 actual-pass graphs, total435,584. Both retain exact CPU
state; graph data/ZP/live-stack and independent MMIO oracles supplement named
source objects/effects. Dead loaded values never authorize removing device reads.
Provenance and exact entry/RTS timing boundaries are linked from
[the native summary](../AgentWorking/optimization/round24-native-SUMMARY.md).
No additional VICE run was made for this pure machine-state optimization.


### Final word call arguments (round25)

[Round25 comparison](../AgentWorking/optimization/round25-comparison.md) uses the
same 288 source hashes as accepted round24: 68 smaller PRGs, 2,017 fewer bytes,
no size increases, 65 faster host cases and three retained layout regressions.
The default core improves from 4,716 to 4,662 bytes and 589,726 to 586,022 host
cycles; its scalars variant improves from 4,274 to 4,238 bytes and 571,544 to
569,257 host cycles. These host counters retain the pass-hook/lifecycle timing
boundary described above.

The final-word extension preserves exact pre-JSR A/X/Y/P/SP by keeping a
high-byte destination reload at the old copy position. Final-byte staging stays
unchanged. Actual parser/emitter/pipeline tests cover single u16/i16/usize/pointer
arguments, nested calls, retained earlier copies, typed ownership and exclusions.
A fully direct word call with no other borrowed ZP state has no call-argument
claim or lifecycle shim; map validation checks zero restored bytes. The shared
allocation/corrupt-map workload deliberately retains a final byte capture so
those tests continue to exercise real scratch claims.

The [focused native proof](../AgentWorking/optimization/round25-native-focused.json)
adds 10,560 paired cases, including 5,280 with D set; the
[reused call-argument corpus](../AgentWorking/optimization/round25-native-reused.json)
adds 18,240 pairs, including 8,640 with D set.
Together these are 28,800 pairs, 13,920 decimal-mode cases, with exact CPU state,
source objects and aliases and no slower native case.
[Provenance](../AgentWorking/optimization/round25-native-provenance.json) fixes
compiler/source/artifact hashes and exact input domains. The
[entry partitions](../AgentWorking/optimization/round25-native-entry-partitions.json)
cover ten before/after entries through main return and lifecycle cleanup,
stopping before the final top-level RTS; these intercepted-hook CPU timings
must not be reported as real ROM SYS-return timings. The
[native summary](../AgentWorking/optimization/round25-native-SUMMARY.md) collects
the partitions and proof scope.

All 499 combined unit tests pass, together with 173 language cases, 546
compile-fail cases, seven runtime-fail cases, 109 smoke cases, 74 section cases,
96 demo end-to-end cases and eight report tests. Exactly one new
[targeted real-ROM VICE gate](../AgentWorking/optimization/round25-targeted-vice.json)
with [provenance](../AgentWorking/optimization/round25-targeted-vice-provenance.json)
verifies keyboard SYS entry, actual RTS into ROM, and subsequent BASIC
POKE/PRINT `1000`/READY. Live values `$81ff` and `$da5f` survive CHROUT/GETIN and
stock IRQ activity; `consume` receives `$5ba0` with entry A=X=`$5b`. All 142 BASIC
bytes at `$02`–`$8f` and 12 borrowed bytes across six claims are restored.
Successful harness cleanup leaves no owned VICE/runner process. An earlier
boot-only working-directory correction executed zero app cases and is not an
additional passed gate. Normal-return preservation does not extend to arbitrary
NMI/forced exits.


### Dead compiler call-capture storage (round26)

[Round26 comparison](../AgentWorking/optimization/round26-comparison.md) records
63smaller artifacts/-184bytes/92unused compiler words over288unchanged sources,
with no size growth and unchanged host cycles.514unit/fullhost/74sections/96demos/
8report tests pass. The [storage audit](../AgentWorking/optimization/round26-storage-proof.json)
independently verifies identical instructions and all other source/data records;
[native proofs and scope](../AgentWorking/optimization/round26-native-SUMMARY.md)
cover28,800 pairs/13,920decimal cases and20entry-only endpoints.
[Alias-validator mocks](../AgentWorking/optimization/round26-alias-validator.json)
are separately counted. Zero own-symbol uses alone cannot authorize removal:
neighbor offsets/address/index/data references and aliases must be excluded.
Latest actual-ROM checkpoint remainsR25; this pass removed data only.

### Unread private capture stores (round27)

[Round27 comparison](../AgentWorking/optimization/round27-comparison.md) covers
288 unchanged sources: 88 smaller artifacts, 2,022 fewer bytes, no size growth,
87 faster cases and one retained 23-cycle data-layout regression. The default
core reaches 4,439 bytes and 579,147 host cycles. All 529 unit tests and the full
host, section, demo and report suites pass.

[The native proof](../AgentWorking/optimization/round27-native-SUMMARY.md) covers
46,208 paired executions, including 22,624 decimal-mode cases, plus 26 complete
entry phase runs. Raw pre-call and endpoint CPU state, source/formal objects,
and every still-read private capture byte remain exact; only independently
proved unread private bytes may disappear or differ. The
[store audit](../AgentWorking/optimization/round27-store-proof.json) verifies
638 removed private stores, 139 logical capture words and map-derived lifecycle
changes over the corpus. Actual lifecycle execution validates ownership,
initialization, snapshots and restoration before generated bindings are
normalized. Seventeen verifier-only mocks are separately counted. The latest
actual ROM SYS/RTS checkpoint remains round25.

### X-held RAM forwarding (round28)

[Round28 comparison](../AgentWorking/optimization/round28-comparison.md) covers
288 unchanged sources: 89 smaller programs, 2,199 fewer bytes, no growth,
85 faster host cases and one retained 250-cycle branch-page regression. All
545 unit tests and full host/section/demo/report suites pass. Default core is
4,381 bytes/578,022 host cycles, versus the original 6,767/949,154 baseline.

[The native summary](../AgentWorking/optimization/round28-native-SUMMARY.md)
scopes 68,736 paired executions, including 33,888 decimal-mode cases, plus
26 entry runs. Actual real-CLI stage traces have complete PRG identity to the
pinned compiler and frozen corpus. Independent checks prove all 1,303 corpus
LDA→TXA substitutions, recompute necessary private bytes, and validate typed
pointer bindings and actual lifecycle execution before normalizing generated
text. Source/formal bytes and physical CPU flags are never blanket-masked.
[The regression trace](../AgentWorking/optimization/round28-regressions.json)
retains +256 branch-page penalties minus six saved reload cycles. No new VICE
run; round25 remains the latest actual ROM SYS/RTS checkpoint.

### Unique loop edge A reuse (round29)

[Round29 comparison](../AgentWorking/optimization/round29-comparison.md) measures
27 smaller/faster programs, 74 fewer bytes and no size/cycle regressions over
288 unchanged sources. All 566 unit and full host/section/demo/report tests pass.
Default core reaches 4,374 bytes and 568,816 host cycles, 40.07% fewer cycles than
the original same-source baseline.

[The native summary](../AgentWorking/optimization/round29-native-SUMMARY.md)
records 835,584 pairs, including 417,792 decimal-mode cases, plus 12 entry runs.
All 74 corpus substitutions are independently proved from actual CLI stages;
only the approved counter LDA→ORA #0 changes meaningful assembly. Data, claims,
parameter facts, lifecycle and labels remain identical. ORA retains the exact
physical flags the removed load would produce; dead-N/Z cleanup is a separate
future increment. No new VICE run in this round.

### Logical identities with dead N/Z (round30)

[Round30 comparison](../AgentWorking/optimization/round30-comparison.md) measures
38 smaller PRGs, 208 fewer bytes, no growth, 37 faster cases and two retained
small branch-page regressions over 288 unchanged sources. All 577 unit and full
host/section/demo/report suites pass. Default core reaches 4,360 bytes/559,969
host cycles, 41.00% fewer cycles than its original same-source baseline.

[The native summary](../AgentWorking/optimization/round30-native-SUMMARY.md)
records 2,828,096 pairs, including 1,413,792 D-set pairs, separate entry runs,
exact CPU/source/ZP/stack checks and independent word-value oracles. Actual CLI
stages prove all 107 new corpus identity removals against the surviving CFG;
only N/Z are outputs of unchanged-A identities. All other raw assembly, data,
labels, claims and lifecycle plans stay identical. New literal elimination
unlocked by identities is separately tested, not mislabeled as identity removal.

Exactly one new [actual ROM gate](../AgentWorking/optimization/round30-targeted-vice.json)
with [provenance](../AgentWorking/optimization/round30-targeted-vice-provenance.json)
passes SYS/CHROUT/GETIN/stock IRQ, real RTS into ROM and subsequent BASIC
POKE/PRINT 1000/READY. All 142 BASIC bytes and 14 borrowed bytes across seven
claims restore; process cleanup is observed. This actual driver does not have a
separate pre-leave AXYP checkpoint; exact cleanup CPU preservation is covered
by native entries. [Regression evidence](../AgentWorking/optimization/round30-regressions.json)
retains +10/+11 branch penalties and the arrays fixture's six-byte fill growth.

### HH00 word carry reduction (round31)

[Round31 comparison](../AgentWorking/optimization/round31-comparison.md) records
14 smaller programs, 148 fewer bytes, no growth, 13 faster cases and one retained
132-cycle indexed-data layout regression. All 618 unit and complete host/section/
demo/report suites pass. Wide-index variants save 32 bytes and about20–21k host
cycles each; all three core binaries remain identical.

[The native proof](../AgentWorking/optimization/round31-native-SUMMARY.md) covers
2,544,512 pairs, including 1,272,256 D-set pairs, plus six entry pairs. Actual CLI
stage identity and independent carry/entry/N/Z liveness checks prove every one
of the 37 corpus reductions. Final raw text differs only by approved BNE/CMP #0
pairs; source objects, physical flags, ZP, stack, data, claims and lifecycle stay
exact. [Regression evidence](../AgentWorking/optimization/round31-regressions.json)
replays all385 assertions: +135 indexed-page cycles minus three removed branch
cycles. No R31 VICE run; R30 is the latest actual ROM checkpoint.


### R32 address-observer safety checkpoint

The frozen R32 compiler is `4078433861fd0ceb29e63fe131f824fced1c6ab8144267aba598e5a9cfb0097a`.
All 637 units and full host/section/demo/report suites pass. The unchanged
288-source comparison records eighteen larger PRGs (+1,109 bytes), sixteen
slower and two faster tests; the three core binaries remain identical. This is
a conservative safety fallback, not a new speedup. Twelve native page/wide
profile replays explain both faster rows by branch-page changes.

Targeted QA adds 42 source pairs, 84 actual-stage PRG identity compiles, 2,460
per-image source/address-oracle calls, 78 entry runs, 312 exact lifecycle
component executions and 78 map replays. Recorded call AXYP is distinguished
from independently checked return/SP/source results; exact CPU preservation is
proved for lifecycle cleanup and same-image scalar/scratch fallback. Older
unsafe physical-layout observations are classified, not treated as equivalence
or permanent ABI. Unknown-pointer/index domains remain explicit frontiers.
See `AgentWorking/optimization/round32-native-SUMMARY.md` and the build, stage,
native and layout-cost reports. R30 remains the latest actual-ROM VICE gate.


### R33 independent argument proof checkpoint

Compiler b75db3fb15cdd854c2b0d22735edf01020656a1efd5a432113213a1e2c677a95
passes 649 units and all full suites. Eighteen corpus PRGs shrink 1,063 bytes
versus R32; sixteen tests improve and two reverse already traced page effects.
All core binaries, 103 module/placement binaries and 288 parameter-policy maps
remain exact. The 104 recovered selections/33 final words are bound to 45,056
paired native suffix executions by actual production module and nineteen corpus
stage hashes. Integrated QA adds 78 triple-identity stages, 28 entry phases,
78 maps and separate 140/52 lifecycle component runs. Raw address values and
volatile read order are checked without address normalization. See
AgentWorking/optimization/round33-argument-SUMMARY.md and build-verification.
No new VICE run; R30 remains the latest actual-ROM checkpoint.


### R34 pointer-address forwarding checkpoint

Compiler e9ead98687c635baa951341ba4e8344a2b7ac17e4c9b5b04738ada121aef22d3
passes661 units and full suites. Twenty of288 PRGs shrink716 bytes and run faster;
none regress. Page/wide default workloads improve about5.9%/5.8%, with exact
instruction/page and kernel/harness decomposition in round34-layout-profiles.
The three core binaries,103 guarded binaries and288 parameter-policy maps stay
identical. All four pointer/scratch stores are retained. Native proof checks
12,730,368 paired executions including invalid BCD and fullCPU/all64K RAM at two
checkpoints without masks. Integrated actual-stage/source/native/map/entry gates
are in AgentWorking/optimization/round34-pointer-cli-SUMMARY.md; do not merge
these separate execution categories. R30 remains the latest actual-ROM VICE gate.


### R35 ordinary edge reuse checkpoint

Compiler1eb9d43cfd93efd39f41b3395331e6773e5202de37cbf7fee8b93826cb7db46d
passes678units/fullsuites.7/288programs shrink99B and runfaster;none regress.
Core default4332B/552730steppedcycles is36.0%smaller/41.8%fewer cycles than the
fixedR3same-source baseline. Actuallegacy output42graphs remains exact;
newordinary pass followsfirstCFG withconditionalcleanup. See round35-build-
verification/ordinary-cli-SUMMARY and overall-through-round35 for detailed
counts/scopes, superseded-probe correction and typedpointer relocation binding.
R30 remains latest actualROMgate; no new VICE or wall-clock/competitor claim.

### R36–R38 retained facts, domains and zero-test values

R36 owned retained typed inventory passes691 units; R37 bounded memory-domain
rejection passes709. Both preserve all288 complete PRG/ASM/label triples, maps
apart from output path, and timings. R37's new adversarial domain probes are
separate from that original corpus; eleven actual-main PRGs match its reviewed
private compiler. The initial fixture-receiver cleanup failure and excluded
MOS6510 DDR raw-memory oracle attempt remain explicit in the proof history.

R38 compilerab822c696bcfa4dac1295d51afca4c92531150a734a4f91087cf8de1ca883932
passes718 units,173language/546compilefail/7runtimefail/109smoke host fixtures,
74 section checks,96 demos and eight report tests. Of288 same-input programs,
nine shrink136B, eight run faster and none grow or slow. All source labels and
parameter-policy arrays match;103 saved module/placement controls stay identical.

Standalone nativegraph65536pairs/32768D and separate actual-CLI-source49152pairs/
24576D compare exactAXYP/SP and all64K RAM without masks. The actual source
manifest binds typed one-byte formal and internal-code relocations to encoded
original PRG instructions. It does not normalize arbitrary native pointers or
raw machine state. Final guarded graphASM/PRG identity authorizes reuse of the
standalone proof; independent symbolic65536cases are not extraCPU executions.
Six application profiles are reused only after complete integrated PRG/ASM/label
identity and decompose structural cycles from branch/table page penalties.
See AgentWorking/optimization/round38-build-verification.json and linked proof
manifests. Rejected slower inverse and mixed-case control counterexample are
excluded history. R30 remains latest realVICE/ROM checkpoint; no competitor
parity or wall-clock claim. New local placement/width fixes remain private.

The R39–R40 optimization checkpoints are recorded in
`AgentWorking/optimization/round39-build-verification.json` and
`round40-build-verification.json`. R39 adds a real host fixture composing pointer
field construction, aggregate arguments/returns, indirect access and an effectful
index; opaque pointer VALUE matrices remain distinct from scoped alias tests.
R40 runs 756 units, the full host corpus, 74 section fixtures, 96 demos and eight
report tests. Its 76 final assembler adversaries check inverse predicates and
encoded spans, including named-A/parenthesized expressions and range fallbacks.
The saved 40-graph native proof is reused only after exact final generator/PRG
binding. SoA layout regressions have fresh source assertions and per-instruction
cycle traces. See `AgentWorking/SHORT_BRANCH_STRATEGY.md`; real VICE remains an
optional separate gate, last run at R30.

R41 composes numeric array and field stores, many-pointer reads and stores,
volatile index evaluation, nested pending stores and a recursive software-stack
index helper in `pending_index_values.zp64`. Its accepted R40 output fails the
source oracle; R41 passes. Native matrices and independent QA bind exact final
CLI artifacts, check live caller stack and source effects, and retain the
conservative cast/direct-field costs. See `AgentWorking/PENDING_INDEX_VALUE_REPAIR.md`.

## Spreadsheet sample

`ZEROPAGE_EMU_FILTER=spreadsheet zig build emu-test` runs the production formula
engine with separate Peddle fixtures. `zig build spreadsheet` builds the
standalone disk and the ReadyOS disk when the Precog 0.5 release manifest is
available. `zig build spreadsheet-vice` rebuilds the disks and runs their
keyboard and screen plans serially. The gallery requests full VIC-II frames
using the harness’s `include_border` option. The plans cover decimal and
currency formatting, native and SimpleCells loads, rejected files, text
results after edits and reloading, help, and a 1,536-cell forward reference
chain. The ReadyOS plan also checks app switching and resume.
