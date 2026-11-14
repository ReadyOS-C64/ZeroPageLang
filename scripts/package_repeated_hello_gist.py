#!/usr/bin/env python3
"""Prepare a whitelisted gist bundle locally. Does not publish anything."""
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/repeated_hello_comparison'
STAGE = ROOT / 'build/repeated_hello_gist'
STAGE.mkdir(parents=True, exist_ok=True)
results = json.loads((OUT / 'results.json').read_text())
publication = OUT / 'publication.json'
share = json.loads(publication.read_text()) if publication.exists() else None
groups = [
    ('Original Adder example (reference)', ['examples/comparison/hello-world.adder']),
    ('Original ZeroPage console', ['examples/repeated_hello.zp64']),
    ('Assembly-heavy ZeroPage buffered version', ['examples/repeated_hello_buffered.zp64', 'examples/micromodules/repeated_hello_display.zp64']),
    ('Balanced ZeroPage buffered version', ['examples/repeated_hello_buffered_balanced.zp64', 'examples/micromodules/repeated_hello_display_balanced.zp64']),
    ('Mostly high-level ZeroPage buffered version', ['examples/repeated_hello_buffered_highlevel.zp64', 'examples/micromodules/repeated_hello_display_highlevel.zp64']),
    ('Shared Oscar64 and cc65 direct-console C source', ['examples/comparison/repeated_hello.c']),
    ('Portable buffered C for Oscar64 and cc65', ['examples/comparison/repeated_hello_buffered.c']),
    ('Idiomatic Oscar64 buffered alternative', ['examples/comparison/repeated_hello_buffered_oscar64.c']),
]
layout = {}
for _, files in groups:
    for relative in files:
        source = ROOT / relative
        layout[source.name] = relative
        shutil.copy2(source, STAGE / source.name)
for name in ('compare_repeated_hello.py', 'render_repeated_hello_comparison.py'):
    layout[name] = 'scripts/' + name
    shutil.copy2(ROOT / 'scripts' / name, STAGE / name)
old_packer = STAGE / 'package_repeated_hello_gist.py'
if old_packer.exists():
    old_packer.unlink()
report = (ROOT / 'AgentWorking/REPEATED_HELLO_COMPARISON.md').read_text()
(STAGE / 'METHODOLOGY.md').write_text(report)
(STAGE / 'source_layout.json').write_text(json.dumps(layout, indent=2)+'\n')
shutil.copy2(OUT / 'results.json', STAGE / 'results.json')
shutil.copy2(OUT / 'repeated_hello_comparison.png', STAGE / 'repeated_hello_comparison.png')
for row in results['rows']:
    shutil.copy2(OUT / (row['key']+'.prg'), STAGE / (row['key']+'.prg'))
(STAGE / 'restore_layout.py').write_text('''#!/usr/bin/env python3
"""Copy flat gist sources into an existing ZeroPage compiler checkout."""
import json
from pathlib import Path
import sys
if len(sys.argv) != 2:
    raise SystemExit('Usage: python3 restore_layout.py /path/to/ZeroPage/checkout')
here = Path(__file__).resolve().parent
target = Path(sys.argv[1]).expanduser().resolve()
if not (target / 'build.zig').is_file():
    raise SystemExit('Target must be an existing ZeroPage compiler checkout.')
pending = []
for flat, relative in json.loads((here / 'source_layout.json').read_text()).items():
    data = (here / flat).read_bytes()
    dest = target / relative
    if dest.exists() and dest.read_bytes() != data:
        raise SystemExit('Refusing to overwrite a different file: ' + str(dest))
    pending.append((dest, data))
for dest, data in pending:
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
print('Restored source layout into ' + str(target))
''')
text = '''# C64 repeated greeting: Adder, ZeroPage, cc65 and Oscar64

Compile-only comparison, updated 21 October 2026. **None of the target programs were executed.**
No cycle measurements, speed claims or frame-timing equivalence claims are made.
These are different rendering/runtime choices, not an isolated compiler benchmark.

This bundle includes the original Adder executable example, the original console
version and all three ZeroPage buffered styles, plus direct-console and buffered C sources, each shared unchanged between
Oscar64 and cc65, plus a separate idiomatic Oscar64 buffered alternative. Complete highlighted listings are below. ZeroPage uses Zig
highlighting and Adder uses Ruby highlighting for its similar keywords. ZeroPage's
inline 6502 asm blocks are an intentional language extension.

'''
if share:
    text += '![C64 static size and resident RAM comparison](' + share['image_url'] + ')\n\n'
else:
    text += 'The sharing image is included as `repeated_hello_comparison.png`.\n\n'
text += '## Results\n\n' + (OUT / 'results.md').read_text() + '''
All sizes are bytes. Resident RAM includes the loaded image, additional BSS,
compiler/application ZP scratch and display buffers. It excludes shared system
workspace/hardware stack, 1,000 four-bit color cells, unused heap and the separately
shown software-stack capacity. Stack budgets are capacities, not measured use.
All Oscar64 native listings have no application software-stack frame despite
the stock 4 KB budget. C buffered startup clears the screen/color cells explicitly
and masks CIA1/VIC IRQ sources; ZeroPage uses a KERNAL screen clear. Timing is
unverified, including whether a copy completes within one frame.

Reference figures come from [the original gist](https://gist.github.com/dylan/d69fe4defda1456b4d2cb0f13c393b73/).
ASM RAM is reconstructed from all three buffers and 19 ZP bytes, correcting the
original table. Adder RAM is reported and unverified, and its accounting may differ.
Neither reference was rebuilt. The three-line Adder executable source is included
below, attributed to Dylan's reference gist; its introductory comments are omitted.
The handwritten assembler reference remains linked rather than republished.

## Three buffered ZeroPage styles

| Style | Handwritten module asm instructions | PRG bytes | Resident RAM bytes |
| --- | ---: | ---: | ---: |
'''
bykey = {r['key']:r for r in results['rows']}
for key, title in [('zeropage_buffered','Assembly-heavy'), ('zeropage_buffered_balanced','Balanced'), ('zeropage_buffered_highlevel','Mostly high-level')]:
    row = bykey[key]
    text += f"| {title} | {row['module_asm_instructions']} | {row['prg']:,} | {row['resident']:,} |\n"
text += '''
Each ZeroPage driver adds one terminal warm-start jump. Counts exclude labels and generated
preservation wrappers. Balanced is 411 file bytes (18.3%) smaller than mostly
high-level while keeping typed state/control flow. All buffered variants use
1,000 front-screen bytes, 1,000 back-screen bytes and a 1,024-byte ring. The C buffered source uses ordinary C for display logic and one terminal asm
jump, with compiler-specific syntax selected by a preprocessor guard. The portable C and ZeroPage buffered copies are row-wise and indirect; the original ASM copy self-modifies. Timing remains unverified.
Direct variants display uppercase text; buffered variants use mixed-case codes.

## Idiomatic Oscar64 alternative

The portable buffered source and its 593-byte Oscar64 build are retained.
`repeated_hello_buffered_oscar64.c` separately uses Oscar64's `byte`/`word`,
`bool`, typed 40-cell rows, `vic_setmode`, `vic_waitFrame`, named VIC/CIA
registers, `s"Hello, World!"` screen-code literal, and `memset`/`memcpy` intrinsics.
The rotated ring is copied as two contiguous spans, using a linked native
`memcpy` helper. Only the terminal ROM jump is handwritten assembly.

This version compiles to **656 PRG bytes and 3,702 resident RAM bytes**:
63 more file bytes and 70 more resident bytes than portable Oscar64. Idiomatic
library use is not automatically the smallest output. It explicitly sets the
text mode and VIC bank; the portable version assumes the normal bank-0 setup.
No timing or runtime behavior equivalence has been measured.

## Reproduce

The gist is flat; source imports require `examples/micromodules/`. Restore the
layout into an **existing ZeroPage compiler checkout** (the compiler is not bundled):

```sh
python3 restore_layout.py /path/to/ZeroPage/checkout
cd /path/to/ZeroPage/checkout
ZEROPAGE_OSCAR64=/path/to/oscar64 python3 scripts/compare_repeated_hello.py
python3 scripts/render_repeated_hello_comparison.py
```

The renderer needs Pillow. The restore helper refuses to overwrite different files.
The build script compiles and inspects files only; it never starts target programs.
Tool versions: Zig 0.16.0, 64tass 1.60.3243, cc65 reporting V2.18 (Homebrew package
path 2.19), Oscar64 1.32.268. C flags: `-t c64 -O --codesize 100 --standard c99`
for cc65 and `-n -Os -tm=c64 -tf=prg` for Oscar64. ZeroPage uses the working-tree
compiler. See `METHODOLOGY.md` for assumptions, accounting, and tool revision.

Nine compiled PRGs are included for inspection. `results.json` records their SHA-256
values. Sources, PNG and PRGs can be downloaded without running them. References:
[cc65 manual](https://cc65.github.io/doc/cc65.html),
[Oscar64 manual](https://github.com/drmortalwombat/oscar64/blob/main/oscar64.md).

## Complete source listings

'''
for title, files in groups:
    text += '### ' + title + '\n\n'
    for relative in files:
        lang = 'c' if relative.endswith('.c') else ('ruby' if relative.endswith('.adder') else 'zig')
        text += f'**`{relative}`**\n\n```{lang}\n' + (ROOT / relative).read_text().rstrip() + '\n```\n\n'
(STAGE / 'README.md').write_text(text)
print('Prepared whitelisted gist bundle:', STAGE)
print('Files:', len(list(STAGE.iterdir())))
