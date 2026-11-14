# ZeroPage sample disks

The repository includes three C64 disk images built from its standalone samples. The ReadyOS-hosted sample uses a separate ReadyOS image and packaging workflow. [ReadyOS integration](readyos-precog.md)

| Disk | Entries in disk order |
| --- | --- |
| `examples/zeropage-demos.d64` | `HELLO`, `MEMORY` |
| `sampleapps/tictactoe/tictactoe.d64` | `TICTACTOE`, `CLASSIC` |
| `examples/zeropage-reu.d64` | `BOOT`, `ENEMYRT` (DLL payload), `MEMORY-DLL` |

Run `x64sc -autostart examples/zeropage-demos.d64` to boot the first disk. Use `x64sc -reu -reusize 16384 -autostart examples/zeropage-reu.d64` for the REU disk. A physical C64 needs compatible REU hardware with enough memory for the configured cache at `$030000`.

## Rebuild the disks

Install the compiler dependencies and VICE's `c1541`. From the repository root:

```sh
zig build
bash scripts/build_sample_disks.sh
```

Use `ZEROPAGE_C1541` for a `c1541` executable outside `PATH`. The script compiles the programs into `build/sample-disks/` and replaces the three sample images.
