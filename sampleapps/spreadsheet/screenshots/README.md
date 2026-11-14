# ZeroPage Sheet in VICE

These are full VIC-II frames from the ReadyOS and standalone automation plans, including the C64 border.
The app uses ReadyOS’s lowercase character set, with mixed-case titles.
The gallery steps request `include_border: true` from the VICE harness.
Run `zig build spreadsheet-vice` to regenerate captures under `logs/`.

| Workbook | What the screen shows |
| --- | --- |
| [Saturday market](market-sales.png) | Mixed column widths, two currency columns, a sales summary, and the `IF` formula for the stall fee. |
| [Dispatch board](dispatch-board.png) | A chained shipping label built from text, a box count, and `IF`, alongside integer, decimal, and currency columns. |
| [Parcel quote](parcel-quote.png) | Decimal weights, currency quotes, and a `LOOKUP` against a rate table on the same sheet. |
| [Cash forecast](cash-forecast.png) | Manual highlights, a negative week, dollar totals, and a chained cash balance with `SUM(D11+D8-D12)`. |
| [SimpleCells import](simplecells-import.png) | A ReadyOS-format workbook with an imported nine-character column, manual colors, and a currency result. |
| [Budget, narrow](budget-compact.png) and [Budget, wide](budget-wide.png) | The same workbook with six and four visible columns. Text is cyan, positive values green, negative values light red, and zero gray. |
| [Stock](stock.png) | Inventory counts, floors, shortfalls, and calculated cost. |
| [Lab](lab-chain.png) | F14 derives a fractional value from other calculated cells and shows its source formula. |
| [Rates](rates.png) and [saved currency format](rates-currency.png) | Decimal calculations, `IF`, and a lookup table with rates entered in scientific notation. The second capture shows the dollar format restored from disk. |
| [Currency](format-currency.png) | The currency format renders `$11.00` and `$1.50` in column F. |
| [Formula errors](formula-errors.png) | Circular references, division by zero, and other errors alongside valid results. |
| [Full sheet chain](full-sheet-chain.png) | A1 displays 1536 after evaluating through P96. |
| [Restored workbook view](saved-view.png) | Loading the saved chain restores the scroll position, wide columns, and the selection at P21. |

[Formula editor](formula-editor.png) · [Column format](market-format.png) · [Save](save-dialog.png) · [Replace a workbook](replace-workbook.png) · [Load](load-dialog.png) · [Discard confirmation](discard-dialog.png)

[Help index](help-index.png) · [Range function help](help-functions.png)

[Workbook browser](workbook-browser.png) · [Workbook browser on drive 9](workbook-browser-drive9.png)

[Cell color picker](cell-color.png)

The raw bar shows the highlighted cell's source formula in these captures.

| Selected formula | Screenshots |
| --- | --- |
| Pricing and rates | [`IF`](formula-if.png) · [`LOOKUP`](formula-lookup.png) · [Decimal charge calculation](formula-charge.png) |
| Range calculations | [`SUM`](formula-sum.png) · [`AVG`](formula-avg.png) · [`MIN`](formula-min.png) · [`MAX`](formula-max.png) · [`PROD` and division](formula-prod.png) |
| Arithmetic | [`ABS`](formula-abs.png) · [Decimal and scientific notation in Rates](rates.png) |
| Formula references | [Original `$` range](formula-fill-source.png) · [One row down](formula-fill.png) · [Two rows down](formula-fill-last.png) · [Chained `SUM` and `COUNT`](lab-chain.png) |
