# Agent Guidelines

Use `zeropage_microcompiler_agent_spec.md` as the north star for architecture, milestones, and constraints.

Operational rules:

- Work in the smallest testable increments.
- Add tests before or with every feature.
- Keep unsupported ZeroPage syntax explicitly rejected.
- Use “ZeroPage”, `zp64c`, package `.zeropage`, source extension `.zp64`, and `@import("ZeroPage")` for new project, compiler, package, source-language, and built-in-module references. Do not reintroduce legacy project, compiler, source-extension, or built-in-module terminology except when quoting historical notes or old commits. Treat `../zeropage-tooling` as the sibling tooling path.
- Treat Zig's own parser/AST as the authoritative syntax front door. Valid Zig syntax may still be rejected by ZeroPage semantic/lowering when outside the supported subset.
- When auditing language behavior against Zig, use the pinned local `../zeropage-tooling/reference/zig-0.16.0/test/behavior` files as the release source of truth, and use RepoQL's `github://ziglang/zig` import for broad indexed search when helpful.
- Keep ZeroPage source Zig-shaped whenever possible: prefer real Zig grammar and idioms over C-like convenience forms. For example, formatter-style APIs should use Zig's anonymous tuple argument shape (`.{value}`), not variadic-looking calls.
- Balance Zig syntax with 6502/C64 viability explicitly. If an API argument represents an ordinary value, allow the supported expression grammar there. If an argument maps directly to a fixed C64 addressing mode, compile-time address, zero-page convention, or other machine constraint, keep it narrower and document why.
- When a construct intentionally departs from normal Zig semantics, name the exception in docs and tests. Current intentional exceptions include ZeroPage inline `asm { ... }`, which is preprocessed before Zig parser validation so 6502/6510 assembly can live in a Zig-like source file while still keeping the surrounding language parser-led.
- Vendor the Zig compiler/parser source files needed for reference or adaptation under `third_party/zig-parser/`, preserving license notes and pinning them to the toolchain release. Prefer copying coherent Zig subtrees, not isolated files with hidden dependencies.
- Keep VICE tests optional and environment-gated.
- Keep fast host-emulated language tests independent from C64 IO when possible: put pure `test6502` assertion fixtures under `tests/fixtures/emu/lang/`, and keep screen/KERNAL/MMIO behavior under `tests/fixtures/emu/smoke/` or the small-demo VICE smoke layer.
- When adding internal codegen labels, avoid perturbing stable statement/helper label sequences that tests, docs, or debugging workflows rely on. Use separate counters or namespaces for scratch labels versus source-structure labels such as `while_N` and `if_N`.
- Resolve host tools from explicit env vars, then `../zeropage-tooling`, then `PATH`.
- Record implementation notes and tradeoffs in `AgentWorking/`.
- Record durable design learnings and future-agent guidance in `AgentWorking/LEARNINGS.md`.
- Record language decisions in `docs/language.md`.
- Record ABI decisions in `docs/abi.md`.
- Record C64 memory reservations in `docs/memory-model.md`.
- After the core language and `c64` module functionality are mostly working, add unused helper/library pruning so PRGs only include runtime or module routines that are actually referenced. Keep the early implementation simple, such as a codegen usage pass that emits helpers on demand, then evolve toward finer symbol-level dead-code elimination if the runtime grows.
- For optimization work, keep behavior proof stronger than size proof: host emu and VICE must still pass, and size reports must compare against the saved pre-optimization and prior-round baselines. If an idiomatic source feature grows a sample, document the tradeoff instead of hiding it; the next optimizer target should follow from measured output.
- Keep `AgentWorking/NEXT_FEATURE_PLAN.md` current after a feature lands. It should describe the next likely language or optimizer step, not the feature that just shipped.

Pinned external references:

- Zig release: `0.16.0`
- 64tass release: `1.60.3243`
- VICE local executable: `/opt/homebrew/bin/x64sc`

Parser/lowering approach:

1. Parse source with `std.zig.Ast.parse` from the pinned host Zig first.
2. If Zig parser reports syntax errors, reject before any ZeroPage lowering.
3. Lower only the supported ZeroPage subset into the project AST in `src/ast.zig`.
4. Reject unsupported-but-valid Zig constructs with clear diagnostics rather than guessing.
5. Use `third_party/zig-parser/std-zig` as the local authoritative reference for Zig parser/AST support code.
