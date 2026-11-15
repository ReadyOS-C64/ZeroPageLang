# ZeroPage documentation

Start with the [project README](../README.md), then use the guide that matches the work you are doing.

| Guide | Use it for |
| --- | --- |
| [Programming guide](https://readyos-c64.github.io/ZeroPageLang/guide.html) | Language-first chapters, runnable examples, and worked C64 memory and DLL designs |
| [ZeroPage Sheet showcase](spreadsheet-showcase.md) | An REU-backed spreadsheet with composable micromodules and three disk-loaded overlays |
| [Getting started](getting-started.md) | Installing tools, building `zp64c`, and compiling a first program |
| [Sample disks](sample-disks.md) | Bootable D64s and how to rebuild them |
| [CLI reference](cli.md) | Commands, options, generated files, and tool lookup |
| [Language reference](language.md) | The supported Zig-shaped language subset |
| [Library API](api.md) | `c64` and `ZeroPage` built-ins |
| [Inline assembler](inline-assembler.md) | Embedded 6502 assembly |
| [ABI](abi.md) | Data layout, calls, frames, and module dispatch |
| [Memory model](memory-model.md) | C64, zero-page, heap, REU, and module reservations |
| [REU and DLLs](reu-overlays.md) | Far storage, materialization, and loadable modules |
| [ReadyOS Precog integration](readyos-precog.md) | Hosted app packaging and proposed REU integration |
| [Runtime](runtime.md) | Startup and emitted-on-demand helpers |
| [Testing](testing.md) | Unit, assembler, Peddle, VICE, and size gates |
| [Optimizations](optimizations.md) | Current transformations and measurement contracts |
| [Dependencies](dependencies.md) | Vendored source, external tools, and licenses |
| [Compatibility](compatibility.md) | Versioning and stability policy |
| [Zig reference notes](zig-reference-notes.md) | The pinned Zig parser and parity workflow |

The [implementation specification](../zeropage_microcompiler_agent_spec.md) records architecture and constraints. `AgentWorking/` contains engineering history and future plans; it is useful context, but it is not the public contract.
