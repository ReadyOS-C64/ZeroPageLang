# ZeroPage Sheet architecture

[Read the illustrated tutorial on GitHub Pages](https://readyos-c64.github.io/ZeroPageLang/tutorial-spreadsheet.html)

ZeroPage Sheet is a Commodore 64 spreadsheet with 1,536 cells, from A1 to P96.
Open `ORDERS` to see text formulas, integer counts, decimal weights, dollar
charges, and absolute references in one workbook. The standalone build starts
from BASIC. The hosted build uses the same spreadsheet code and follows the
ReadyOS launcher and application-switch conventions.

## Keep the workbook in the REU

Each cell occupies a 32-byte record in the live REU bank. A record holds a
length byte and up to 31 PETSCII bytes. The grid maps the zero-based row and
column to a 16-bit cell ID with four bits for the column. The storage
micromodule uses the ID to fetch exactly one record into a CPU-visible buffer.

```zig
fn read(bank: u8, id: u16) void {
    dma.fetch(bank, id << 5, 0xc000, 32);
}
```

This excerpt from [`store.zp64`](../sampleapps/spreadsheet/store.zp64) calls an
ordinary local import. [`dma.zp64`](../sampleapps/spreadsheet/dma.zp64) takes the
physical bank at runtime. Its inline 6510 assembly programs the REU controller.
The standalone build uses fixed bank numbers. The ReadyOS build gets them from
its app-side schema-5 resource adapter.

| Location | Contents |
| --- | --- |
| Live REU bank | 48 KiB of cell input, 9 KiB of tagged results, a 6 KiB dependency stack, and workbook settings and session state |
| Staging REU bank | Scratch copy of workbook data and colors for disk I/O |
| Cache REU bank | Three code slots, eight independently fetched help pages, and cached formula text |
| C64 RAM below `$A000` | Resident grid, input, evaluator, and floating-point bridge |
| C64 RAM `$A000–$BEFF` | One active overlay under BASIC ROM |
| C64 RAM starting at `$C000` | Small working buffers, screen layout and format mirrors, and temporary formula operands |

The formula engine walks dependencies iteratively. It spills four-byte
frames to REU and reuses a near buffer while walking the chain. Visiting tags
detect cycles, and finished results can be reused across redraws. Editing
invalidates the result tags with one DMA clear. Values that need fractional
arithmetic or exceed the exact integer fast path use C64 BASIC ROM's five-byte
floating-point format. Currency and decimal rounding apply at display time.

## Share one execution window

The file, help, and editor images each declare the same load and entry address,
`$A000`, with an exclusive limit of `$BF00`. Their responsibilities are chosen
by when they run.

| Image | Responsibility |
| --- | --- |
| `ZSFILE` | Load and save dialogs, native workbook files, and SimpleCells import |
| `ZSHELP` | Help topics, disk browser, and column and cell formatting |
| `ZSEDIT` | Cell and formula editing, paste, and fill with adjusted references |

The loader maps out BASIC ROM while keeping KERNAL and I/O visible. On first
use, it reads and checks the image from drive 8 and caches it in REU. On a
later change of overlay, DMA copies the cached image into the window. Repeated
calls to the current overlay skip that copy. Arguments and results pass through
a small shared RAM mailbox. Grid rendering and recalculation stay resident.

These images use the application's fixed-address PRG convention. For the
compiler-managed DLL mechanism with typed imports, relocation, and declared
load policies, see the [shared DLL window lesson](https://readyos-c64.github.io/ZeroPageLang/tutorial-dll-cache.html)
and the [REU and DLL reference](reu-overlays.md).

## Follow the disk and host boundaries

On load, the file overlay validates the sparse stream in the staging bank
before copying it into the live workbook. On save, it transfers staged data
through a single page of C64 scratch and writes occupied cells, metadata, and
manual colors to a compact SEQ file. ReadyOS app switches retain workbook data
in the live bank and restore the saved view and clipboard on return.

[App controls and build steps](../sampleapps/spreadsheet/README.md) ·
[Workbook format](../sampleapps/spreadsheet/FILE_FORMAT.md) ·
[Full-border screenshots](../sampleapps/spreadsheet/screenshots/README.md) ·
[Verification commands](testing.md#spreadsheet-sample)
