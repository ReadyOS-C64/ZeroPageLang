# ZeroPage sample disks

The repository includes three C64 disk images built from its standalone samples. The ReadyOS-hosted sample uses a separate ReadyOS image and packaging workflow. [ReadyOS integration](readyos-precog.md)

| Disk | Entries in disk order |
| --- | --- |
| `examples/zeropage-demos.d64` | `HELLO`, `MEMORY` |
| `sampleapps/tictactoe/tictactoe.d64` | `TICTACTOE`, `CLASSIC` |
| `examples/zeropage-reu.d64` | `BOOT`, `ENEMYRT` (DLL payload), `MEMORY-DLL` |

Run `x64sc -autostart examples/zeropage-demos.d64` to boot the first disk. Use `x64sc -reu -reusize 16384 -autostart examples/zeropage-reu.d64` for the REU disk. A physical C64 needs compatible REU hardware with enough memory for the configured cache at `$030000`.

## ZeroPage Sheet

The [standalone D64](../sampleapps/spreadsheet/zeropage-sheet.d64) includes
the app, overlays, and ten workbooks. Enable at least 256 KiB of REU and
boot with `x64sc -reu -reusize 256 -autostart zeropage-sheet.d64:zsheet`.
Open a workbook with F7. A separate [workbook D81](../sampleapps/spreadsheet/sheet-examples.d81)
can be mounted on a 1581 data drive.

Run `zig build spreadsheet` to rebuild both disks and, if the ReadyOS
Precog release manifest is available, package the hosted variant.
[Showcase tutorial](https://readyos-c64.github.io/ZeroPageLang/tutorial-spreadsheet.html) ·
[Build and boot instructions](../sampleapps/spreadsheet/README.md)

## Rebuild the disks

Install the compiler dependencies and VICE's `c1541`. From the repository root:

```sh
zig build
bash scripts/build_sample_disks.sh
```

Use `ZEROPAGE_C1541` for a `c1541` executable outside `PATH`. The script compiles the programs into `build/sample-disks/` and replaces the three sample images.
