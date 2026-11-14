#!/usr/bin/env python3
"""Render the verified static-build results as an exact, shareable PNG chart."""
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/repeated_hello_comparison'
DATA = json.loads((OUT / 'results.json').read_text())
W, H = 2000, 2497
image = Image.new('RGB', (W, H), '#0b1220')
draw = ImageDraw.Draw(image)
BG, PANEL, WHITE, MUTED = '#0b1220', '#141f32', '#f3f6ff', '#acb9cf'
CYAN, GREEN, GOLD = '#70e2e8', '#a5ebc2', '#f4c778'


def font(size, bold=False):
    name = 'Arial Bold.ttf' if bold else 'Arial.ttf'
    local = Path('/System/Library/Fonts/Supplemental') / name
    return ImageFont.truetype(str(local) if local.exists() else
                              ('DejaVuSans-Bold.ttf' if bold else 'DejaVuSans.ttf'), size)


def text(x, y, value, size=30, color=WHITE, bold=False, anchor=None):
    draw.text((x, y), value, font=font(size, bold), fill=color, anchor=anchor)


def pill(x, y, value, color=CYAN):
    f = font(21, True)
    width = draw.textlength(value, font=f) + 30
    draw.rounded_rectangle((x, y, x+width, y+34), radius=9, fill='#223248')
    text(x+15, y+5, value, 21, color, True)


text(80, 55, 'COMMODORE 64  /  STATIC BUILD COMPARISON', 27, CYAN, True)
text(75, 104, 'HELLO, WORLD!', 112, WHITE, True)
text(82, 239, 'A greeting every 9 frames. How much space does it take?', 37, MUTED)
draw.line((80, 306, 1920, 306), fill='#334259', width=2)
text(105, 330, 'VERSION', 25, MUTED, True)
text(735, 330, 'PRG FILE / BYTES', 24, MUTED, True)
text(1335, 330, 'RESIDENT RAM*', 24, MUTED, True, 'ra')
text(1580, 330, 'STACK BUDGET', 24, MUTED, True, 'ra')
text(1865, 330, 'RAM + STACK', 24, MUTED, True, 'ra')

rows = {r['key']: r for r in DATA['rows']}
refs = DATA['references']


def row(y, item, label, subtitle, reference=False, emphasis=False):
    draw.rounded_rectangle((80, y, 1920, y+112), radius=16,
                           fill=PANEL, outline=CYAN if emphasis else None, width=2)
    color = GOLD if reference else CYAN
    text(105, y+18, label, 37, WHITE, True)
    text(106, y+68, subtitle, 24, MUTED)
    text(1070, y+20, f"{item['prg']:,}", 48, color, True, 'ra')
    # Every PRG bar uses the same 0..3000-byte scale, across both groups.
    draw.rounded_rectangle((735, y+81, 1070, y+92), radius=5, fill='#2c3a50')
    draw.rounded_rectangle((735, y+81, 735+335*item['prg']/3000, y+92),
                           radius=5, fill=color)
    suffix = '†' if item['name'] == 'Adder' else ''
    text(1335, y+31, f"{item['resident']:,}{suffix}", 44, GREEN, True, 'ra')
    budget = item['stack_budget']
    text(1580, y+35, 'unknown' if budget is None else f'{budget:,}',
         29 if budget is None else 36, MUTED, False, 'ra')
    total = item['ram_with_stack_budget']
    text(1865, y+31, 'unknown' if total is None else f'{total:,}',
         29 if total is None else 44, WHITE, True, 'ra')


text(104, 385, 'DIRECT CONSOLE  /  ONE VISIBLE SCREEN', 25, CYAN, True)
row(430, rows['oscar64'], 'Oscar64', 'C port · native · -Os · built locally')
row(554, rows['zeropage_console'], 'ZeroPage console', 'Original ZeroPage example · built locally')
row(678, rows['cc65'], 'cc65', 'Same C port · -O / codesize 100 · built locally')

text(104, 826, 'BUFFERED DISPLAY  /  TWO SCREENS + A TEXT RING', 25, CYAN, True)
row(871, refs[0], 'Handwritten ASM', 'Gist file size · RAM reconstructed from source', reference=True)
row(995, rows['zeropage_buffered'], 'ZeroPage buffered module', 'Assembly-heavy · 202 handwritten asm instructions', emphasis=True)
row(1119, rows['oscar64_buffered'], 'Oscar64 portable buffered', 'Shared C · -Os · one terminal asm jump')
row(1243, rows['oscar64_buffered_idiomatic'], 'Oscar64 idiomatic', 'VIC/CIA APIs · screen-code string · bulk memcpy')
row(1367, rows['cc65_buffered'], 'cc65 buffered', 'Same buffered C · -O · one terminal asm jump')
row(1491, rows['zeropage_buffered_balanced'], 'ZeroPage balanced', 'Typed state + bulk memory asm · 66 asm instructions', emphasis=True)
row(1615, rows['zeropage_buffered_highlevel'], 'ZeroPage mostly high-level', 'Same buffers · 10 handwritten asm instructions in module', emphasis=True)
row(1739, refs[1], 'Adder', 'Gist-reported results · not rebuilt here', reference=True)

draw.rounded_rectangle((80, 1891, 1920, 1999), radius=16, fill='#1a2c3c')
text(108, 1910, 'BUFFERED DISPLAY STORAGE', 23, CYAN, True)
text(108, 1948, '1,000 front + 1,000 back + 1,024 ring = 3,024 bytes of display RAM',
     33, WHITE, True)

notes = [
    '* Resident RAM = loaded image + extra BSS + compiler/application ZP scratch + display buffers.',
    '  Excludes 1,000 color RAM cells, shared system workspace, hardware stack and SW-stack capacity.',
    '  SW stack budgets are stock linker capacities, not measured usage; Oscar64 has no app SW-stack frame.',
    '  Portable C / ZeroPage: row copies. Idiomatic Oscar64: two memcpy spans. Timing unverified.',
    '† Adder RAM is reported by the gist; its accounting could not be independently verified.',
    '  The ASM RAM figure corrects the gist count using all three buffers and 19 zero-page bytes.',
    'Different implementations and compiler defaults. Compile-only: no execution or speed claims.'
]
for n, line in enumerate(notes):
    text(82, 2032+n*39, line, 26, WHITE if n == len(notes)-1 else MUTED, n == len(notes)-1)
draw.line((80, 2326, 1920, 2326), fill='#334259', width=2)
text(82, 2350, 'Builds: cc65 2.18 / Oscar64 1.32.268 / ZeroPage working tree', 25, MUTED)
text(1918, 2350, '21 OCT 2026', 25, CYAN, True, 'ra')
publication = OUT / 'publication.json'
share = (json.loads(publication.read_text())['gist_url'].removeprefix('https://')
         if publication.exists() else 'Source bundle and methodology in the accompanying gist')
text(82, 2394, 'Sources: ' + share, 23, CYAN)
text(82, 2436, 'Reference: gist.github.com/dylan/d69fe4defda1456b4d2cb0f13c393b73', 23, MUTED)

image.save(OUT / 'repeated_hello_comparison.png', dpi=(160,160))
print(OUT / 'repeated_hello_comparison.png')
