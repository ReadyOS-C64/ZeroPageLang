# ZeroPage Sheet implementation notes

SimpleCells reserves a 320-byte shared input pool and uses a recursion limit
of three. ZeroPage Sheet uses separately addressable 32-byte cell records,
four-byte result records, and six-byte traversal frames. The REU layout
holds 1,536 of each. An edit clears the result region with one DMA. The
walker marks a cell on arrival, saves a cursor and a range continuation before
descending, and computes a value only after its dependencies finish. This
avoids a recursive software frame per expression or a resident dependency
graph. The cost is two token passes and some extra DMA when descending through
a formula; the grid never swaps code to calculate a value.

The use of one 64 KiB bank for the entire live sheet limits the grid to
16 by 96, but lets each record own its maximum length. A second 64 KiB bank
isolates file staging from edits. The 256-byte KERNAL window streams it in
one page at a time. Loads check the signature, length, record boundaries,
printable input, and exact EOF before publishing the new workbook. Stored
results and DFS frames are rebuilt, never imported. The simple fixed-size
format favors bounded, auditable I/O over compact files or legacy import.
The third bank reserves space for two cold modules and eight REU help pages.
The two micromodules link their own small TUI helpers and execute at $8000;
this avoids exchanging relocations or static frame labels between images.

The ReadyOS build uses schema 5 allocation and the stable shim exits. The
regenerated catalog advertises only Editor and the sheet, and retains
Editor help. Standalone uses banks 0–2 and probes bank aliasing. Both retain
the stock interrupt policy and use the compiler's default pointer ABI.
The compiler needed no changes: the app uses explicitly qualified calls in
flat local imports, avoids duplicate imported range-loop labels, and keeps
KERNAL byte transfers within small inline assembly routines. Some call sites
use byte counters because range captures are `usize`. The formula evaluator
does signed operations explicitly on `u16` bit patterns, including a pair of
words for signed AVG. The production builds are linked without test6502.

Measured with the pinned compiler/assembler: 26,139-byte standalone PRG,
28,435-byte ReadyOS PRG, and unpadded file/help payloads of 7,795/6,344 bytes.
The two package files are each padded to 8,192 payload bytes. The named
workspace excluding cold code is 769 bytes; ReadyOS's resident shim and
stock screen/zero-page work are separate. A 32-level Peddle fixture steps
882,826 CPU cycles, including constructing the chain and checking the
far corner. The VICE plans exercise the all-cell forward reference chain
and check A1=1536. On the ReadyOS VICE run, loading that synthetic 49 KiB
workbook and rendering the dependent first viewport took about four wall
seconds in the warp-configured harness; this is not a real C64 benchmark.

The workbook gallery adds an F6 view choice and color rules derived
from value kind and sign. Both layouts consume the same 36 visible
characters, which keeps the grid at 40 columns. Width is session state
and stays out of v1 workbook bytes. The ReadyOS resident grew into page
$80, so the cold window now begins at $8100 and ends at $9fff. Both
payloads fit with the new start address. The activation marker changed
to prevent reusing a cached payload linked at the old address.

ZeroPage Sheet uses ReadyOS's lowercase character ROM for interface text
and workbook display. With that ROM, screen codes $01–$1A display lowercase
and $41–$5A display uppercase. Raw PETSCII and the ZPSH file format keep
their existing bytes. The VICE plans assert the character ROM selection
and mixed-case title bytes because the monitor's text decoder cannot
represent the uppercase glyph range. The code and help cache markers were
advanced together so old REU pages cannot reintroduce the old presentation.

ZPSH v2 streams sorted cell IDs and length-prefixed PETSCII, with a
terminal marker for explicit EOF validation. It retains v1 reads.
The ReadyOS and standalone builds use the same ZeroPage and KERNAL
file code. ReadyOS supplies the visual reference and hosted lifecycle.
The v2 save and both readers share the existing cold overlay. Small
6502 loops walk the REU page and draw fixed modal captions so the
second reader fits the window. The VICE gallery requests the full VIC framebuffer through the
harness capture option.

Full grid draws repaint the spacer between the row numbers and the
vertical divider. The spacer overlaps the save/load and help frames, so
leaving it out let dialog characters survive after dismissal. The VICE
plans check the row label, spacer, and divider bytes after saving and
after closing help. The fix adds 56 resident bytes to each build. The
ReadyOS resident still ends below the $8100 overlay window.

The hosted VICE test reloads PROOF, changes A1, and opens Editor from
the ReadyOS launcher. It returns through the launcher to the sheet and
checks the selected calculation and unsaved marker, then edits B1 and
checks the dependent result. The test reloads RESUME-PROOF in the app
and verifies the extracted v2 stream byte for byte after VICE exits.

Formula copy and fill use the shared lexer for relative and `$`-locked
references. Fill checks every destination length before writing. The
resident BASIC ROM bridge preserves the memory port, BASIC zero page,
and error vector, and maps a ROM math error back into the sheet. Cache
records are six bytes (kind plus five-byte payload). Packing the DFS
cursor and cell ID into a word reduces each spill frame from six bytes
to four, keeping all 1,536 frames and results within the original live bank.
Editor, file and help overlays share $A000–$BEFF, with BASIC ROM mapped
out while the overlay runs. Repeated calls to the current overlay skip DMA.
The arithmetic and dependency walk stay resident.

The measured images contain 35,211 resident bytes standalone and 36,820
under ReadyOS. The file, help, and edit overlays use 4,981, 3,448, and
7,066 bytes before packaging. The hosted image leaves 44 bytes below
the window. Source modules imported by a build with opaque inline asm
are conservatively retained, so separating resident numeric drawing from
the shared paint primitives matters. The targeted 32-cell Peddle chain
took about 613,000 cycles after the direct DMA and lexer changes.

## Calculation and column number formats

Integer add/subtract and range SUM promote on signed overflow. Integer
multiplication uses a conservative magnitude cutoff of 181 per operand
to avoid a separate wide multiply. AVG accumulates an exact signed
32-bit sum and uses the remainder to decide whether to replay through
the BASIC floating-point path. The editor can position its cursor
inside the source and insert or delete there.

Column modes live at workbook REU offset $FC40 with a 16-byte C64
mirror at $C310. Loading stages the mode header separately at $C260
and applies it only after validating the cell records and EOF.
General-mode books retain the v2 stream. Custom number formats use
ZPSH v3, with 16 mode bytes and the same sparse cell records. The
format menu shares the file overlay. Numeric drawing stays resident
and uses BASIC FOUT followed by decimal digit rounding in $C200–$C248.
This uses the decimal precision emitted by BASIC and never modifies a
cached formula result. Fixed widths that cannot hold a value fill
with hash marks. Save/load and drawing perform no per-cell code swaps.

This build uses 35,242 resident bytes standalone and 36,852 under ReadyOS.
The file/format, help, and editor overlays use 6,473, 3,448, and 7,663 bytes
before packaging. The hosted resident has 12 bytes below the cold window.

The next pass packs each explicit width into the upper nibble of the
existing 16-byte format table and adds literal text mode to the lower
nibble. V4 uses the same byte count as v3. The renderer prepares the
visible starts and widths once per redraw in $C320–$C33F, clips text and
errors to the active field, and marks integer overflows in narrow fields.
It clears uncovered row tails when fewer columns fit. Switching to or
from text invalidates cached dependents. Both the evaluator and its DFS
dependency scanner normalize reversed rectangular aggregate ranges.

V5 saves the selection, scroll origin, and automatic width. Its 21-byte
metadata header is followed by the existing sparse cell stream. The file
overlay stages the view next to the column types and widths in cold scratch.
It updates the live mailbox only after validating the full cell stream and
end marker. Earlier workbooks retain the active view on load. The VICE plans
move to a different viewport before reloading, reject an invalid V5 viewport,
and verify that saved stream bytes include the original position.

The save dialog uses Return for a new file and F3 for an explicit
same-name replacement. It sends the drive a DOS `@0:` name and checks
command-channel status after closing. The old file is not scratched in
a separate command. A rejected save keeps the in-memory edits marked
dirty. Tests first try a regular save against an existing name, then
replace it and verify the reopened value and sparse stream on both disks.

F3 in the load dialog opens the disk browser. It reads eight SEQ names
and one lookahead into shared cold scratch, rescanning for another page.
The help and browser share one overlay. A selection returns through the
resident dispatcher to the file overlay for full workbook validation.
The PRG loader builds its own filename in $C280, leaving the selected
workbook name in the file mailbox intact across the overlay swap.

Cell colors occupy $FD00–$FFFF in the live and staging REU banks.
Zero is automatic. A redraw fetches the 144 packed bytes for its
18 visible rows once. Selection and error colors retain priority.
The ReadyOS clipboard keeps its color with the existing source ID.
ZPSH v6 appends sorted, three-byte color records ahead of the end
marker. Colors on empty cells survive a save so they apply to later
input, and a load validates the entire color stream before replacing
the live workbook. The format and color menus share the help/browser
overlay to leave room for the disk codec in the file overlay.

The file overlay also reads the original ReadyOS SimpleCells SCLS1 v2
stream. It validates the selection and column table, converts row/column
coordinates to the resident grid's IDs, and stages raw records and colors
in the same REU bank used by the native reader. The file dialog's filename
rendering uses direct screen writes to make room for the importer. Saving
an imported sheet writes ZPSH v6, including odd imported column widths.

Numeric arguments to range functions are parsed by the same operator
stack as ordinary expressions. The parser holds a function marker until
it sees the closing parenthesis. The range path still visits the
normalized rectangle directly. The overlay installer and lexer use
bounded byte loops to recover enough resident space to add this path.
This revision measures 35,036 resident bytes standalone and 36,647 in
ReadyOS. Before disk padding, file, help, and edit code use 7,753, 7,806,
and 7,518 bytes. The ReadyOS image leaves 217 bytes below the shared
overlay window.

Formula text follows the original SimpleCells 14-byte result limit.
The operator stack distinguishes integers, floats, text, and blanks.
Quoted strings and cell text use a 16-byte slot per operand at $C500.
The three ReadyOS allocations still suffice. Calculated text uses
16 bytes per cell at $8000–$DFFF of the module cache bank. The live
result tag controls validity, so a single existing REU clear invalidates
both caches. Rendering and recalculation use direct REU transfers and
keep all code resident. The overlay marker moved to $C0CF, outside the
32-byte clipboard buffer. Numeric formatting uses compact ROM argument
setup to keep the new expression code inside the resident window.
The combined build uses 35,056 resident bytes standalone and 36,677 in
ReadyOS, with 187 bytes below the shared window. The three cold module
sizes are unchanged from the scalar-aggregate build. Peddle measured
607,316 cycles on the 32-cell chain versus 603,611 before text support.
