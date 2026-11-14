# ZPSH workbook format

ZeroPage Sheet saves ZPSH v6 and opens v1 through v6.
Package the logical byte stream as a Commodore SEQ directory entry. The
stream starts at the magic bytes and contains no PRG address or disk block
headers.

| File offset | Size | Contents |
| --- | ---: | --- |
| `0x0000` | 4 | Magic bytes `5A 50 53 48` (`ZPSH`) |
| `0x0004` | 1 | Version byte `02` |
| `0x0005` | Variable | One record per populated cell, in ascending cell ID order |
| After records | 2 | End marker `FF FF`, followed immediately by end of file |

Version 3 uses version byte `03` and inserts 16 column-format bytes at
offset `0x0005`, one for each column A through P. The same sparse records
start at offset `0x0015` and use the same end marker. A format byte may be
`00` (general), `02` (rounded integer), `03` (two decimal places), or
`04` (dollar currency). Other codes are rejected. Loading v1 or v2 sets
all columns to general formatting. A v3 workbook adds exactly 16 bytes to
the corresponding v2 stream.

Version 4 uses the same 16-byte header. The low nibble uses the v3 type codes
and adds `1` for text. The high nibble stores the width in characters, one of
`4`, `6`, `8`, `10`, or `12`, with `0` using the current F6 default.
For example, `A4` (hexadecimal) is a ten-character currency column.
The v1–v3 readers use automatic widths.

Version 5 adds five bytes after the 16-byte column table at offset
`0x0015`. They are the selected row, selected column, first visible row,
first visible column, and the automatic width (6 or 9). Indices are
zero-based. The selected row must be within the 18-row viewport. Sparse
cell records begin at `0x001A`. Older workbooks retain the current view
when opened.

Version 6 keeps the v5 header and cell records and also accepts explicit
widths of 5, 7, 9, and 11 for imported columns. After the last cell record,
it adds one three-byte record per manual cell color, in ascending cell ID
order. Each record holds the little-endian cell ID with bit 15 set,
followed by a VIC-II ink value from 1 to 15. For example, `01 80 02` sets
B1 to red. A manual color may be stored for an empty cell. Unlisted
colors are automatic. The same `FF FF` marker ends the stream.

Each record starts with a little-endian 16-bit cell ID, followed by a
one-byte length from 1 through 31 and exactly that many raw PETSCII
bytes. IDs are zero-based and run from 0 (A1) through 1535 (P96).
For one-based row `r` and zero-based column `c`, the ID is
`16 * (r - 1) + c`. Unlisted cells are blank. Duplicate and out-of-order
IDs are invalid.

An empty workbook is seven bytes. A workbook containing `7` in A1 and
`=A1*3` in B1 is 19 bytes.

```text
5A 50 53 48 02    header
00 00 01 37       A1
01 00 05 3D 41 31 2A 33    B1
FF FF             end marker
```

A v6 workbook takes 28 bytes plus three bytes and the text length for
each populated cell, plus three bytes per manual color.

The loader accepts raw bytes in `0x20–0x7E` and `0xC1–0xDA`. Formulas
include the leading equals sign. The loader requires KERNAL's
end-of-information flag on the last byte of the end marker. Invalid
records, premature EOF, and trailing bytes leave the open workbook
intact. The reader clears and fills a separate REU staging bank, then
copies the validated sheet into the live bank.

Decimals, scientific notation, absolute references, quoted strings, and
text formulas are stored as ordinary raw cell text. Numeric and text
result caches are rebuilt from the workbook inputs after a load.

The app rebuilds formula results, errors, and automatic colors from the
stored cells.

## Legacy v1

Version `01` uses the same magic followed by 1,536 records of exactly
32 bytes each, in row order, for 49,157 bytes total. Each record has
a length byte from 0 through 31, that many raw data bytes, and zero
padding through byte 31. A blank is 32 zero bytes. KERNAL must signal
EOF on the last byte of the final record. Re-saving a legacy workbook
writes a sparse v6 file.

## Importing ReadyOS SimpleCells

Load an `SCLS1` version 2 SEQ workbook through the ordinary load dialog
or workbook browser. The importer reads the 18×10 grid into A1:J18 and
retains each column’s width and number format, cell colors, raw PETSCII,
and the selected cell and first visible column. The saved file uses
ZPSH v6.

The importer accepts rows in the order produced by SimpleCells and checks
the formula flag against the leading equals sign. It requires the
one-byte `FF` terminator to be the final byte. A failed import leaves the
open workbook intact.

The editable sample sources use one address and one raw value separated
by a tab. A directive such as `# column C 10 currency` sets a column's width
and type. A directive such as `# color A1 yellow` sets a cell's ink.
Other lines beginning with `#` are comments. See the
[example generator](../../scripts/spreadsheet_examples.py).
