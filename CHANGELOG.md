# Changelog

ZeroPage is pre-release. This file records user-visible changes; implementation history remains in `AgentWorking/`.

## Unreleased

### Added

- Source declarations for named memory, arenas, pools, zero-page policy, images, DLLs, and REU-backed loaders. Functions and constants can declare frame and placement policy with `callconv` and `linksection`.

- ZeroPage project identity, `zp64c`, `.zp64` sources, and the `.zeropage` package.
- Zig-parser-led language front end, 64tass backend, Peddle host emulation, and optional VICE automation.
- Static and software-stack call paths, C64 library helpers, inline assembly, near heaps, REU storage, module sidecars, relocation, dependency graphs, multi-window dispatch, and RAM-under-ROM module execution.
- Public CLI, API, runtime, testing, dependency, and compatibility documentation.

### Changed

- Public documentation now separates current behavior from architecture history and future plans.

## 0.1.0 source preview

The initial public repository publishes ongoing development. See the README for the pinned toolchain, sample disks, and supported features.
