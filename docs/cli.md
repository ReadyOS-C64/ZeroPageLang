# CLI reference

`zp64c` has two compilation commands and a small set of development utilities.

```text
zp64c <command> [arguments]
```

## `compile`

Compile a `.zp64` program through 64tass:

```sh
zp64c compile input.zp64 -o out.prg
```

The default output is `build/out.prg`. Create the output directory before running the command. A successful compile writes `out.prg.asm`, `out.prg.labels`, and `out.prg.zpmap.json` beside the PRG.

The map includes the configured image load/entry/ceiling, named C64 and REU regions, and placement LMA/VMA ranges in addition to ordinary section ownership. This is the machine-readable handoff for an embedding OS or packaging tool; no environment-specific profile is required in the compiler.

Programs with a `module` declaration also produce module sidecars:

| File | Contents |
| --- | --- |
| `.zpmod.json` | Human-readable module metadata |
| `.zpmod` | Versioned binary metadata and module payload |
| `.zpmod.relocsim.json` | Relocation simulation, when loader metadata is present |
| `.zpmod.disk.prg` | Disk-loadable payload, when disk staging is configured |
| `.zpmod.diskmanifest.json` | Package filenames, when a disk manifest is configured |

Dependency calls require one metadata pair per dependency:

```sh
zp64c compile app.zp64 -o app.prg \
  --dependency-module math_core=math.prg.zpmod.json \
  --dependency-relocsim math_core=math.prg.zpmod.relocsim.json
```

The two options must use matching module ids and must be supplied together.

## `asm`

Lower source to 64tass assembly without invoking the assembler:

```sh
zp64c asm input.zp64 -o out.asm
```

The default output is `build/out.asm`. Create the output directory first. The dependency-sidecar options accepted by `compile` are also accepted here.

## `run-vice`

Generate a YAML plan for the external VICE task harness. Create the output directory first:

```sh
zp64c run-vice build/demo.prg -o build/demo.vice.yaml
```

This command generates a plan; it does not launch VICE. Repository scripts compile and execute plans when `ZEROPAGE_VICE_TASKS` is configured.

## `tools`

Print the resolved Zig, 64tass, and VICE executables:

```sh
zp64c tools
```

## `explain`

Print a short note about an implementation topic:

```sh
zp64c explain tools
zp64c explain parser
zp64c explain modules
zp64c explain vice
```

## Reserved commands

`zp64c test` and `zp64c size` are not implemented. Use repository build steps instead:

```sh
zig build test
zig build emu-test
zig build size-report
```

## Diagnostics

Syntax is checked by Zig's parser first. ZeroPage then reports unsupported language constructs, invalid memory plans, and code-generation failures with the source path and a focused diagnostic. Final assembly errors come from 64tass.
