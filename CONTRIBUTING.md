# Contributing to ZeroPage

ZeroPage is a small compiler for a small machine. Changes should keep the language predictable and the generated code explainable.

## Setup

Use Zig 0.16.0 and 64tass 1.60.3243. The [getting-started guide](docs/getting-started.md) describes tool lookup and environment variables.

```sh
zig build
zig build test
```

## Change workflow

1. Add or update a focused fixture with the implementation.
2. Reject unsupported syntax explicitly; do not silently reinterpret it.
3. Update the relevant language, ABI, memory, or API document.
4. Run the smallest relevant test first, then the broader gate.

Common gates:

```sh
zig build test
zig build e2e
zig build emu-test
zig build section-marker-test
zig build size-report
```

Use `zig build vice-test` when the optional VICE environment is configured. Optimization work must preserve host-emulator and VICE behavior and compare PRG sizes against the saved baseline.

## Documentation style

Write for someone using or maintaining the compiler. Lead with the contract, show one useful example, state important limits, and link to deeper material. Keep milestone history in `AgentWorking/`, not in user guides.

## Architecture

The [implementation specification](zeropage_microcompiler_agent_spec.md) is the architectural north star. Durable decisions belong in `docs/`; implementation findings belong in `AgentWorking/LEARNINGS.md`.
