"""Pack the in-app help into independently DMA-addressable screen pages."""
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "sampleapps/spreadsheet/help.txt"
PAGE_BYTES = 512
WIDTH = 36
HEIGHT = 14


def generate() -> bytes:
    pages = SOURCE.read_text(encoding="ascii").strip().split("\n---\n")
    if len(pages) != 8:
        raise ValueError("help ABI expects eight pages")
    output = bytearray()
    for page in pages:
        lines = page.splitlines()
        if len(lines) > HEIGHT or any(len(line) > WIDTH for line in lines):
            raise ValueError(f"help page does not fit: {lines[0]}")
        padded = lines + [""] * (HEIGHT - len(lines))
        chars = "".join(line.ljust(WIDTH) for line in padded)
        output.extend(ord(c) & 31 if "a" <= c <= "z" else ord(c) for c in chars)
        output.extend(bytes(PAGE_BYTES - WIDTH * HEIGHT))
    return output
