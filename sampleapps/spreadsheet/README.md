# ZeroPage Sheet

A 40-column C64 spreadsheet in ZeroPage, inspired by ReadyOS SimpleCells. The
same grid, editor, formula engine, file dialogs, and help browser run as a
standalone BASIC-loadable program and as a ReadyOS Precog 0.5 app. The ReadyOS
version uses the shell's boot, storage-drive, and app-switch conventions.

[Illustrated tutorial](https://readyos-c64.github.io/ZeroPageLang/tutorial-spreadsheet.html) · [Architecture](../../docs/spreadsheet-showcase.md)

| | ZeroPage Sheet |
| --- | --- |
| Sheet | A1:P96, 1,536 cells, each with up to 31 input bytes |
| Values | Text and C64 BASIC 5-byte floats, with an exact 16-bit integer fast path |
| Formulas | References, parentheses, unary signs, `+ - * /`, comparisons, `ABS`, `IF`, and `LOOKUP` |
| Range functions | `SUM`, `AVG`, `MIN`, `MAX`, `COUNT`, and `PROD` |
| Dependency depth | Up to the number of cells, including forward references |
| Help | Eight indexed topics; one 512-byte REU transfer per page |

Build with the pinned Zig and 64tass:

```sh
zig build spreadsheet
```

The standalone image is `build/spreadsheet/zeropage-sheet.d64`. Enable a 256 KB
or larger REU, mount it on drive 8, then enter `LOAD"ZSHEET",8` and `RUN`. For
ReadyOS, the build uses the Precog 0.5 D81 release from the sibling
`../readyosprecog` checkout, or the manifest supplied by
`ZEROPAGE_READYOS_MANIFEST`. Mount `build/spreadsheet/readyos-zeropage-sheet.d81`
on a 1581 drive 8, enable at least 1 MB REU for ReadyOS, and boot `PREBOOT`.
The focused catalog starts in ZeroPage Sheet and also includes Editor for
app switching. Keep the program disk in drive 8 until the editor, file and
help modules have each been opened once. Use a **copy** of the generated disk for your
workbooks; rebuilding recreates the packaged images.

Use arrows to move and scroll. F6 switches automatic columns between
six and nine characters. The screen uses fixed-size C64 characters. Text
is cyan, positive numbers green, negative numbers light red, zero gray,
and errors light red. The selection uses reverse video with yellow ink
for valid values. Press F for the selected column's format menu. Use Up/Down
for general, text, rounded integer, two decimal places, or dollar currency.
Use Left/Right for the automatic width or 4, 6, 8, 10, or 12 characters.
Imported columns can also retain a width of 5, 7, 9, or 11 characters.
Press F3 in the format menu for cell color. Choose automatic, yellow,
green, red, or light blue. Copy, paste, and fill carry the chosen color.
Text mode preserves literal inputs such as `007`. Formulas still evaluate.
Fixed formats round halfway values away from zero and show `#` across a field
when the formatted value is too wide. Formulas continue to use the stored
numeric value. Return edits a cell in the raw bar; F3 opens
the formula dialog. Left, Right, and Home move within the input. Return
commits, Del deletes before the cursor, and Run/Stop cancels.
In the grid, Del clears the cell. C copies and V pastes. D fills the
rectangle from the copied cell to the cursor, which must be at or below
and to the right of the source. Formulas shift with each destination.
Use `$A1` to lock the column, `A$1` to lock the row, or `$A$1` to lock both.
Both endpoints of a range are adjusted independently. An off-sheet reference
becomes `#REF!`. If any translated formula exceeds 31 bytes, the edit is
cancelled. F1 rebuilds the full calculation cache. Normal edits automatically
recalculate visible cells and the dependencies they need.

Try `7` in A1, `=A1*3` in B1, `=B1+8` in C1, and `=SUM(A1:C1)` in D1.
The computed values are 7, 21, 29, and 57. The included `CHAIN` workbook
contains a formula in each of the first 1,535 cells, each referring to the
next. A1 evaluates to 1536 after the engine reaches P96.

Both app disks include all ten examples. The build also produces
`sheet-examples.d81`, which you can mount as a separate data disk on drive 9.

| File | What to try |
| --- | --- |
| `BUDGET` | Press F6 to see longer labels. Variances show positive, negative, and zero colors. |
| `STOCK` | Inventory quantities, shortfalls, and costs computed from referenced cells. |
| `LAB` | Select F14 to see a formula chain that combines `ABS`, `PROD`, `MAX`, `SUM`, and `COUNT`, with a fractional result. |
| `ERRORS` | Compare cycles, divide by zero, invalid references, text operands, and overflow. |
| `CHAIN` | Evaluate A1 through all 1,536 cells. |
| `RATES` | Fractional prices, scientific notation, an `IF` threshold, and `LOOKUP` with a numeric rate table. |
| `MARKET` | A four-column sales report with mixed widths, dollar formats, totals, and an `IF` fee. |
| `SHIPPING` | A quote worksheet with decimal weights, currency rates, and a chained `LOOKUP`. |
| `FORECAST` | A cash plan with highlighted headings and totals, a negative week, and a reserve formula. |
| `ORDERS` | A dispatch board with mixed column formats, a locked rate reference, and labels built from other cells. |

See the [editable sample inputs](workbooks/) and the [VICE screenshot gallery](screenshots/).

F5 saves and F7 loads. Enter a filename of 1–15 letters, digits, or hyphens.
In the save dialog, Return creates a new file and F3 replaces a file with
the same name. In the load dialog, F3 browses sequential files. Up/Down
selects a name, Left/Right moves between pages, and Return opens the
selected file. F1 switches drives in either dialog. A failed load leaves
the current sheet and its unsaved changes intact. Saves write compact ZPSH
[SEQ files](FILE_FORMAT.md) with one record per populated cell and one
short record per manual color. A workbook
stores the column settings, selection, and scroll position in a 21-byte
metadata header. The app opens earlier ZPSH versions and imports ReadyOS
SimpleCells v2 workbooks. F8 opens help. Use 1–8 or Left/Right to choose
a topic. Return, F8,
or Run/Stop closes help. In ReadyOS, F2/F4 switch loaded apps and Ctrl-B or
Run/Stop returns home. The workbook and view resume while the app remains
loaded. In standalone, Run/Stop returns to BASIC; the next RUN starts a
fresh workbook.

Whole-number calculations use a fast integer path when the result fits.
Fractional division and averages, as well as sums and products outside
the signed 16-bit range, use floating point.
Decimal and scientific literals, such as `19.95` and `1.2E-4`, and larger
whole literals use C64 BASIC floating point. Arithmetic, comparisons and
range arithmetic promote mixed operands to float. Numeric overflow is `#NUM`
and division by zero is `#DIV0`. Range functions ignore text and blanks,
and propagate formula errors. A direct blank reference is zero.
Range aggregates accept either corner first, including `SUM(D7:D4)`.
Aggregates also accept a numeric expression, such as `SUM(A1*3)`.

`=A4+" #"+B4` joins text from A4 with a quoted string and the value in B4.
When either operand is text, `+` joins the values using general number
formatting and treating blank cells as empty text. A calculated label can
feed other formulas. Text formula results can hold up to 14 characters.
Longer results show `#LONG`.

`=IF(B2>=10,2.5,1)` chooses a number or text (zero is false). Both result
expressions are evaluated, so an error in either expression propagates.
`=LOOKUP(B2,A5:A9,C5:C9)` finds the first exact numeric match for `B2` in a
vertical range and returns the numeric value at the same offset in an
equally tall result column. An absent key produces `#N/A`.
Formula names and references appear in uppercase in the raw bar and editor.
Text and the displayed digits of longer float results are clipped to the
active column width. The C64 BASIC float retains its full precision in
the result cache. The grid uses automatic color rules and right-aligns numbers.

The engine and TUI are resident. After editing, one REU DMA clears the
9 KiB result cache. An explicit depth-first walk stores the packed traversal
frames in REU, computes each visited cell once, and records circular
dependencies. Scrolling renders cached values and evaluates newly visible
cells as needed; moving within the viewport redraws two cells and the raw
bar. The file dialog and sequential disk I/O share one cold module. A
second handles help, disk browsing, and the format and color menus.
A third handles the editor and paste/fill commands.
They share a single 7.75 KiB window under BASIC ROM. The last overlay stays
in its window for consecutive calls. Rendering and recalculation do not swap
code from REU. The resident float bridge briefly exposes BASIC ROM.

| Storage | Reservation |
| --- | --- |
| Resident C64 image | Standalone: $0801 onward; ReadyOS: $1000 onward; both end before $A000 |
| Cold module execution | $A000–$BEFF; used by just one module at a time |
| C64 work area | $C000–$C2FF scratch, $C300 DMA zero, $C310–$C31F format mirror, $C320–$C33F column offsets and widths, $C340–$C3CF visible colors, $C3E0–$C49F BASIC ROM bridge |
| C64 formula text | $C500–$C5FF, up to 16 temporary operands |
| Live workbook bank | $0000–$BFFF input; $C000–$E3FF cached values; $E400–$FBFF DFS frames; $FC00+ session; $FC40–$FC4F column formats; $FD00–$FFFF cell colors |
| File staging bank | $0000–$BFFF cell records and $FD00–$FFFF color table |
| Module cache bank | $0000–$5FFF inactive code; $6000–$6003 cache markers; $7000–$7FFF help; $8000–$DFFF formula text results |

Standalone uses physical banks 0–2. In ReadyOS, the app resolves its
logical identity and claims three schema 5 `APP_ALLOC` resources. The
launcher owns the bank table and frees these resources when it unloads
the app. The cold modules use a fixed mailbox and normal KERNAL calls.
They do not require the compiler's standalone DLL allocator to be active
inside ReadyOS. The production images do not link test hooks.

```sh
ZEROPAGE_EMU_FILTER=spreadsheet zig build emu-test
zig build spreadsheet-vice
```

The second command rebuilds test disks and runs the same VICE task-plan
harness used by ReadyOS. It requires VICE, c1541, the external harness, and
.NET; see [test setup](../../docs/testing.md). Set `ZEROPAGE_DOTNET` if
`dotnet` is not on PATH. The hosted plan also checks that changes to a
loaded workbook survive a trip through the launcher and Editor, then
edits it again, saves a copy, and verifies the disk file. Both plans enter
formulas, check screen values, round-trip native and imported workbooks,
reject malformed files, browse help, and check the full-sheet chain.
