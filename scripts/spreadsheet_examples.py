"""Generate the human-readable ZeroPage Sheet examples as ZPSH SEQ files."""
from pathlib import Path
import re

ROWS, COLS = 96, 16
SAMPLES = Path(__file__).resolve().parents[1] / "sampleapps/spreadsheet/workbooks"


def cell_id(address: str) -> int:
    match = re.fullmatch(r"([A-P])([1-9][0-9]?)", address)
    if not match or int(match[2]) > ROWS:
        raise ValueError(f"cell outside A1:P96: {address}")
    return (int(match[2]) - 1) * COLS + ord(match[1]) - ord("A")


def workbook(cells: dict[str, str], *, legacy: bool = False, formats: dict[str, int] | None = None,
             widths: dict[str, int] | None = None, view: tuple[int, int, int, int, int] | None = None,
             colors: dict[str, int] | None = None) -> bytes:
    records = {}
    for address, value in cells.items():
        index = cell_id(address)
        data = value.encode("ascii")
        if len(data) > 31 or any(not 0x20 <= c <= 0x5E for c in data):
            raise ValueError(f"use up to 31 printable PETSCII characters: {address}")
        if data:
            records[index] = data

    metadata = bytearray(COLS)
    for column, mode in (formats or {}).items():
        if len(column) != 1 or not "A" <= column <= "P" or mode not in range(5):
            raise ValueError(f"invalid column format: {column}={mode}")
        metadata[ord(column) - ord("A")] = mode
    for column, width in (widths or {}).items():
        if len(column) != 1 or not "A" <= column <= "P" or (width != 0 and not 4 <= width <= 12):
            raise ValueError(f"invalid column width: {column}={width}")
        metadata[ord(column) - ord("A")] |= width << 4

    if legacy:
        if any(metadata) or view is not None or colors:
            raise ValueError("legacy workbooks have no column settings")
        return b"ZPSH\x01" + b"".join(
            bytes([len(data)]) + data.ljust(31, b"\0")
            for data in (records.get(index, b"") for index in range(ROWS * COLS))
        )

    version = 2
    if any(metadata):
        version = 4 if any(value == 1 or value >= 16 for value in metadata) else 3
    if view is None and (colors or any(value & 0x10 for value in metadata)):
        view = (0, 0, 0, 0, 6)
    if view is not None:
        row, col, top, left, width = view
        if not (0 <= top <= 78 and top <= row < min(top + 18, ROWS)
                and 0 <= left <= col < COLS and width in (6, 9)):
            raise ValueError("invalid workbook view")
        version = 6
    header = b"ZPSH" + bytes([version]) + (bytes(metadata) if version >= 3 else b"")
    if view is not None:
        header += bytes(view)
    color_records = {}
    for address, ink in (colors or {}).items():
        if not 1 <= ink <= 15:
            raise ValueError(f"invalid cell color: {address}={ink}")
        color_records[cell_id(address)] = ink
    return header + b"".join(
        index.to_bytes(2, "little") + bytes([len(data)]) + data
        for index, data in sorted(records.items())
    ) + b"".join(
        (index | 0x8000).to_bytes(2, "little") + bytes([ink])
        for index, ink in sorted(color_records.items())
    ) + b"\xff\xff"


def from_text(path: Path) -> bytes:
    cells = {}
    formats = {}
    widths = {}
    colors = {}
    for line in path.read_text(encoding="ascii").splitlines():
        if line.startswith("# color "):
            _, _, address, ink = line.split()
            if address in colors:
                raise ValueError(f"{path.name}: repeated cell color: {address}")
            colors[address] = {"yellow": 7, "green": 5, "red": 2, "light-blue": 14}[ink]
            continue
        if line.startswith("# column "):
            _, _, column, width, mode = line.split()
            if column in widths:
                raise ValueError(f"{path.name}: repeated column settings: {column}")
            widths[column] = int(width)
            formats[column] = {"general": 0, "text": 1, "integer": 2, "decimal": 3, "currency": 4}[mode]
            continue
        if not line or line.startswith("#"):
            continue
        address, sep, value = line.partition("\t")
        if not sep or address in cells:
            raise ValueError(f"{path.name}: expected a unique address and tab: {line}")
        cells[address] = value
    return workbook(cells, formats=formats, widths=widths, colors=colors)


def chain_workbook() -> bytes:
    cells = {}
    for index in range(ROWS * COLS):
        row, col = divmod(index, COLS)
        next_row, next_col = divmod(index + 1, COLS)
        cells[f"{chr(65 + col)}{row + 1}"] = (
            "1" if next_row == ROWS else f"={chr(65 + next_col)}{next_row + 1}+1"
        )
    return workbook(cells)
