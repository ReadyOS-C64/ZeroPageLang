# Getting started

ZeroPage compiles `.zp64` source into 64tass assembly and Commodore 64 PRG files. The compiler itself is a host program built with Zig.

## Requirements

- Zig 0.16.0 builds `zp64c`. [Zig downloads](https://ziglang.org/download/)
- 64tass 1.60.3243 assembles PRGs. [64tass downloads](https://sourceforge.net/projects/tass64/files/)
- VICE provides the optional `x64sc` emulator for running PRGs. The demo suite also uses its `c1541` disk-image utility. [VICE downloads](https://vice-emu.sourceforge.io/)

See [Dependencies](dependencies.md) for what is vendored and what must be installed separately.

## Build the compiler

```sh
zig build
./zig-out/bin/zp64c --help
```

If Zig is not on `PATH`, invoke the pinned binary directly:

```sh
../zeropage-tooling/bin/zig build
```

## Compile a first program

The included `examples/hello.zp64` is a complete program:

```zig
const c64 = @import("c64");

export fn main() void {
    c64.console.clear();
    c64.console.print("HELLO FROM ZEROPAGE\n", .{});
    c64.vic.border = 5;
}
```

Compile it:

```sh
mkdir -p build
./zig-out/bin/zp64c compile examples/hello.zp64 -o build/hello.prg
```

The command writes:

- `build/hello.prg` — loadable C64 program
- `build/hello.prg.asm` — generated 64tass source
- `build/hello.prg.labels` — VICE labels
- `build/hello.prg.zpmap.json` — section and address map

Run the PRG with VICE:

```sh
x64sc -autostart build/hello.prg
```

On a C64 with the PRG on a disk in device 8, enter `LOAD "HELLO",8` using its disk filename, then enter `RUN`.

## Tool lookup

`zp64c` resolves tools in this order:

1. Explicit environment variable
2. The optional sibling `../zeropage-tooling` layout or the Homebrew VICE location on macOS
3. `PATH`

```sh
export ZEROPAGE_ZIG=/path/to/zig
export ZEROPAGE_64TASS=/path/to/64tass
export ZEROPAGE_VICE_X64SC=/path/to/x64sc
```

Check the resolved paths with:

```sh
./zig-out/bin/zp64c tools
```

Repository scripts may also accept `ZEROPAGE_C1541`, `ZEROPAGE_VICE_TASKS`, and `ZEROPAGE_SIZE_BASELINE`. Use an absolute path when setting a tool override.

## Next steps

- [CLI reference](cli.md)
- [Language reference](language.md)
- [Library API](api.md)
- [Testing](testing.md)
- `examples/small/` for focused, executable examples
- `sampleapps/tictactoe/` for an application-sized example
