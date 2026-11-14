# ZeroPage

ZeroPage is a Zig-shaped programming language for the Commodore 64. Write typed functions and fixed-layout data, choose where they live in C64 memory, and build a native 6510 program you can inspect in assembly. The compiler, `zp64c`, turns `.zp64` source into 64tass assembly and a runnable C64 PRG.

```zig
const c64 = @import("c64");

export fn main() void {
    c64.console.clear();
    c64.console.print("HELLO FROM ZEROPAGE\n", .{});
    c64.vic.border = 5;
}
```

The example prints a line to the C64 screen and changes the VIC-II border color. ZeroPage uses Zig's parser for ordinary source syntax and defines a small target language with 8- and 16-bit integers, 16-bit pointers, fixed arrays, structs, enums, and optionals. This repository is the in-progress 0.1.0 source preview. The language, ABI, and module formats may change. [Example source](examples/hello.zp64) · [Language reference](docs/language.md)

[Documentation site](https://readyos-c64.github.io/ZeroPageLang/) · [Programming tutorial](https://readyos-c64.github.io/ZeroPageLang/tutorial.html) · [Full programming guide](https://readyos-c64.github.io/ZeroPageLang/guide.html) · [Install and build](https://readyos-c64.github.io/ZeroPageLang/setup.html)

## What makes ZeroPage different on the C64

- **Use the hardware from source.** The built-in `c64` module exposes VIC-II registers, screen and color RAM, PETSCII console output, keyboard input, and KERNAL routines. Use volatile pointers for memory-mapped I/O and `asm { ... }` for native 6502/6510 instructions. [Library API](docs/api.md) · [Inline assembler](docs/inline-assembler.md)
- **Make the memory layout part of the program.** Declare named C64 and REU regions in a `memory` block and assign them to code, data, arenas, fixed-block pools, the software stack, or DLL loading. The compiler checks address ranges and overlapping claims. You can set the PRG load and entry addresses and copy selected code or tables into RAM under ROM at startup. [Memory model](docs/memory-model.md) · [Placement example](examples/small/95_memory_regions_placement.zp64)
- **Choose the cost of a call.** Functions use fixed storage for their frames by default. Mark functions that need recursion with `callconv(.stack)` and reserve a software stack in C64 RAM. You can also declare which zero-page bytes the compiler may use. The compiler emits runtime helpers on demand, so a program that only changes the border carries no console, heap, or module routines. [ABI](docs/abi.md) · [Runtime](docs/runtime.md)
- **Use the REU for data and loadable code.** The built-in `@import("ZeroPage")` API supports explicit transfers to the RAM Expansion Unit (REU) and typed views of data stored there. A dynamically loadable module (DLL) can load from disk into an REU cache, then relocate into a C64 RAM window to run. Multiple DLLs can share a window, including supported windows under ROM, leaving more resident RAM for the main program. Typed imports, dependency policies, and state snapshots let you control when modules load and what survives a window swap. [REU and DLLs](docs/reu-overlays.md) · [DLL example](examples/small/96_memory_regions_dll.zp64)

## Build and run

Install Zig 0.16.0 and 64tass 1.60.3243 and put them on your `PATH`. [Zig downloads](https://ziglang.org/download/) · [64tass downloads](https://sourceforge.net/projects/tass64/files/)

`zig version` should report `0.16.0`, and `64tass --version` should report `1.60.3243`. For an assembler installed outside `PATH`, set `ZEROPAGE_64TASS` to its absolute path. VICE is optional for the quick start. The full small-demo test also uses Bash, Perl, and VICE's `c1541` utility. [Tool setup](docs/getting-started.md) · [Dependency details](docs/dependencies.md)

Clone the repository and build the compiler:

```sh
git clone https://github.com/ReadyOS-C64/ZeroPageLang.git
cd ZeroPageLang
```

```sh
zig build
mkdir -p build
./zig-out/bin/zp64c compile examples/hello.zp64 -o build/hello.prg
```

Autostart the PRG in VICE, or load it from your C64's disk device and type `RUN`. The default PRG includes a BASIC startup line. [VICE command-line guide](https://vice-emu.sourceforge.io/vice_2.html)

```sh
x64sc -autostart build/hello.prg
```

You should see `HELLO FROM ZEROPAGE` and a green border. Alongside the PRG, `compile` writes `hello.prg.asm`, `hello.prg.labels` for the VICE monitor, and `hello.prg.zpmap.json` with section addresses and memory ownership. DLL sources also produce module metadata and payload files. Use `zp64c asm` to generate assembly alone. For tool overrides and command options, see [Getting started](docs/getting-started.md) and the [CLI reference](docs/cli.md).

## Try the sample disks

| Disk | Programs |
| --- | --- |
| [ZeroPage demos](examples/zeropage-demos.d64) | `HELLO` prints a greeting. `MEMORY` demonstrates named regions, an arena, and code under KERNAL ROM. |
| [Tic-Tac-Toe](sampleapps/tictactoe/tictactoe.d64) | `TICTACTOE` and `CLASSIC` are the two standalone variants. |
| [ZeroPage REU](examples/zeropage-reu.d64) | `BOOT` loads a DLL from the disk. `MEMORY-DLL` demonstrates activation from the REU cache. Enable a 16 MiB REU for this disk. |

Autostart a disk in VICE to run its first program. On a C64, load a named program with `LOAD "HELLO",8`, then enter `RUN`. [Disk sources and rebuild instructions](docs/sample-disks.md)

## Explore and test

The small demos show individual features. Tic-Tac-Toe shows how keyboard input, screen drawing, and game state fit together. [Small demos](examples/small/) · [Tic-Tac-Toe](sampleapps/tictactoe/tictactoe_idiomatic.zp64)

- `zig build test` runs the compiler and host runner unit tests.
- `zig build emu-test` assembles and runs generated PRGs on the bundled Peddle-based 6510 runner. ZeroPage test fixtures use `@import("test6502")` for assertions.
- `zig build e2e` assembles the small demos and checks their artifacts, including disk images built with `c1541`. The optional `zig build vice-test` gate exercises C64 behavior in VICE with the external automation harness.

See [Testing](docs/testing.md) for setup and [the documentation index](docs/README.md) for the full reference. ZeroPage is [MIT licensed](LICENSE). Vendored code retains its own licenses. [Dependencies and attribution](docs/dependencies.md)
