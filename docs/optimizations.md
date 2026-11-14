# Optimizations

Within generated function blocks, flag-aware cleanup removes redundant
hardware-stack push/pop pairs and RAM reloads. It tracks whether N/Z describes
A, or proves the affected flags unused before their next definition. Reloads
require canonical compiler-owned frame/scratch storage and an unchanged byte
already held in A. Calls, aliases, unknown accesses, volatile reads, assembly,
and control-flow joins revoke the relevant facts. Decimal ADC/SBC does not
establish the N/Z-to-A relation. Module relocation paths retain their existing
lowering. Assembly records the removed pair/reload counts in a trailing comment.

Adjacent typed struct/array reads can reuse a pointer already held in `$fb/$fc`.
The pass uses explicit NMOS register/flag/memory effects and frame byte offsets,
including overlapping root/field labels. It proves the pointer source lies in
ordinary RAM using conservative layout bounds; names alone are insufficient.
The removed copy's A/N/Z outputs must die before use. Target reads retain their
width and order, and proven disjoint local stores can keep the cached base.
Source/scratch writes, unknown or indirect stores, calls, control-flow joins,
unmarked indirect/volatile accesses, opaque assembly, and unknown instructions
invalidate it. Module images keep their existing relocation-covered path.

Ordinary static comparisons select immediate or compiler-owned static-slot
`CMP`/`CPX` operands when possible. The left operand is evaluated first, so a
call can still change the right operand before it is read. Word comparisons
test high bytes before low bytes. Indirect/volatile right operands keep their
full-width reads; module images retain relocation-compatible staging.

Static `if`/`while` comparisons and logical conditions branch directly without
materializing intermediate booleans. Short-circuit effects and stable source
control labels are preserved. Module and software-stack conditions keep their
established paths. Tight clear-screen/multiply helper loops use bounded page
padding when necessary to prevent taken-branch page-cross penalties; this can
increase PRG size, as recorded in the measurement history.

Suitable literal multiplications use target-cost-bounded shift/add sequences.
Byte-result operations retain low-byte behavior; A/X word-result operations
preserve full-width results. Zero/one factors still evaluate the other operand,
and word volatile accesses retain their original read width. Dense constants
and sequences that would exceed the byte-cost bound use the general helper.
That helper consumes multiplier bits through the shift carry flag, avoiding a
separate load-and-mask test on each of its 16 iterations.

`zp64c` selects immediate `ADC`/`SBC` instructions for integer literal addition
and subtraction. Addition accepts the literal on either side; subtraction
preserves operand order. Word operations propagate low-byte carry/borrow into
the high byte and return the result in A/X under the existing ABI. This avoids
temporary memory and excess hardware-stack traffic. It does not change the
accepted language or promise register/status preservation beyond the ABI.

Static bounded loops can hoist a proven-zero index capture high byte and substitute
immediate zero for high-byte reads. Captures remain `usize` in source and retain
their complete static frame representation. Initialization, prefix read ranges,
callee effects, aliases, and dead setup registers/flags are checked before
moving a store. The low capture byte is still written each iteration. Zero/one
trips, unknown writes/calls, recursive callees, and opaque assembly retain the
original stores. Module and software-stack lowering remain separate paths.

Direct ALU operands avoid stack/scratch staging for scalar ADC/SBC/AND/ORA/EOR.
Mutable right operands are read after left-side effects. Commutative compound
assignments keep right-side effects before reading the destination. Loops can
also hoist invariant pointer-base setup through proven scalar callees while
leaving every target read at its original position.

Literal unsigned shifts select small target sequences for zero, one, byte
extraction, and residual byte shifts. Other constant counts share specialized
entry points and kernels, avoiding repeated count staging. Dynamic kernels
use X as a counter instead of modifying a memory byte every iteration. Unused
directions, count storage, and helper bodies are omitted. Operands, including
volatile word loads and zero-shift effects, are still evaluated once, and
oversized/signed/unsupported literal shifts remain rejected. Module images
retain their relocation-compatible shift routines. See the engineering history
for complete register/flag proofs and cost tradeoffs. Left 14/15 share a fast
byte-operation outline; a single such count alongside a dynamic left kernel
can cost five/six additional bytes for the measured CPU saving.

Existing code generation also prunes helpers through feature-use flags,
compacts large aggregate copies, and applies conservative adjacent assembly
peepholes. Private-function tree shaking follows an exhaustive AST call graph;
unused function code, static frames, and helpers used only by those functions
are omitted. All declarations are still validated before pruning.
Roots include `main`, explicit source and DLL exports, fixed function placements,
and explicitly configured ABI functions. Reachable opaque assembly conservatively
retains all source functions. Generated assembly records removal/retention
reasons when pruning occurs. Global constant-data pruning is a later pass.
DLL exports must remain callable by external clients even when the compiling
application contains no direct call. See [module contracts](reu-overlays.md).

Optimization work is measured against fresh unchanged-source baselines.
[Testing](testing.md#optimization-measurements) describes report generation and
timing limits. The engineering [roadmap](../AgentWorking/OPTIMIZATION_ROADMAP.md)
and [history](../AgentWorking/OPTIMIZATION_FINDINGS.md) record research, tradeoffs,
and measured results.

Constant-result scalar switch expressions choose between constant output,
a guarded interval, and a bounded byte-indexed table using a complete byte
cost, including bounds, defaults, holes, and data. Selectors execute exactly
once, including volatile word accesses and selectors whose result is discarded.
Word bounds check both bytes; signed scalar keys retain their raw representation.
Biased absolute operands avoid decimal-sensitive index subtraction. Low custom
images account for an unbiassed prefix instead. Every constant prong is validated
through ordinary lowering before selection. Dynamic results, captures, module
relocations, and explicitly assembly-referenced dispatch blocks keep the existing
path. Tables have compiler-owned readonly sections; source control-label counters
and names remain stable, with optimized dispatch anchors coalesced.

Y can retain the value of a canonical ordinary-RAM byte across unchanged RAM
reads and proven disjoint local stores. Reloads of that byte become TYA; a
redundant load/TAY pair disappears when A/N/Z die before use. Facts describe
retained instructions only. Source writes, aliases, index changes, calls,
control-flow joins, IO/unknown reads, opaque assembly, and uncertain layout revoke
them. Volatile reads remain in place. This extends the explicit NMOS register
and memory model rather than relying on register-name text matches.

Constant record strides can share fixed-factor multiplication helpers after
counting their actual generated call sites. The complete helper/call cost and
one global generic-helper credit determine selection. Supported factors are
powers of two or one more than a power of two; small/excess-cost cases retain
existing lowering. Source indexes still evaluate once at full supported width.
Unmatched/placed users keep the generic helper; assembly/private-helper name
references pin the old path. Removing the last generic user prunes its RHS and
loop while retaining required LHS/result scratch. DLL lowering stays unchanged.

The helpers specialize the generic NMOS sequence, including decimal zero-plus-
source adjustment, final carry, overflow and high-byte NZ; they do not insert CLD
or alter Y/stack balance. This exact helper proof is stronger than ordinary
binary-source semantics. Source address calculations under external decimal mode
can depend on relocated frame addresses; normalized-frame probes are explicitly
separate from untouched production-PRG checks in the engineering history.
