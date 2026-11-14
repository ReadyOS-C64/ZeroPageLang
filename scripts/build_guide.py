from html import escape
import re
from pathlib import Path
from textwrap import dedent
from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers import BashLexer, ZigLexer, TasmLexer

repo = "https://github.com/ReadyOS-C64/ZeroPageLang"
blob = repo + "/blob/main/"
raw = "https://raw.githubusercontent.com/ReadyOS-C64/ZeroPageLang/main/"

def block(label, source, lang="zig"):
    lexer = {"zig": ZigLexer, "shell": BashLexer, "asm": TasmLexer}[lang]()
    rendered = highlight(source, lexer, HtmlFormatter(nowrap=True))
    return f'<div class="codebox"><div class="codebar"><span class="mono">{escape(label)}</span></div><pre tabindex="0"><code>{rendered}</code></pre></div>'

def shell(source, title="Build and run", anchor=None):
    code = block("Terminal", dedent(source).strip() + "\n", "shell")
    attr = f' id="commands-{escape(anchor)}"' if anchor else ""
    return f'<details class="terminal"{attr}><summary>{escape(title)}</summary>{code}</details>'

def write_reading_page(path, html):
    commands = []
    number = 0
    pattern = r'<details class="terminal"(?: id="(commands-[a-z0-9-]+)")?><summary>(.*?)</summary>(.*?)</details>'

    def move_commands(match):
        nonlocal number
        anchor, title, code = match.groups()
        if anchor is None:
            number += 1
            anchor = f"commands-{number}"
        commands.append(
            f'<section id="{anchor}"><h2>{title}</h2>{code}'
            f'<p><a href="{path.name}#{anchor}">Return to the guide</a></p></section>'
        )
        return f'<p id="{anchor}" class="command-link"><a href="{path.stem}-commands.html#{anchor}">{title}</a></p>'

    if path.name == "setup.html":
        path.write_text(re.sub(pattern, r'\3', html, flags=re.S))
        return
    reading = re.sub(pattern, move_commands, html, flags=re.S)
    path.write_text(reading)
    if commands:
        source_title = re.search(r'<h1>(.*?)</h1>', html).group(1)
        content = (
            f'<main id="main" class="wrap guide commands"><article>'
            f'<p><a href="{path.name}">← {source_title}</a></p>'
            f'<h1>Commands</h1><p class="lead">{source_title}</p>'
            f'{"".join(commands)}</article></main>'
        )
        path.with_name(f"{path.stem}-commands.html").write_text(
            page("Commands · ZeroPage", f"Build and run commands for {source_title}", "", content)
        )

def sample(path, name=None):
    return block(name or Path(path).name, Path(path).read_text())

def doc(file, title):
    return f'<a href="{blob}docs/{file}.md">{escape(title)}</a>'

def download(path, title):
    return f'<a href="{raw}{path}">{escape(title)}</a>'

def page(title, desc, active, content):
    links = (("tutorial.html", "Tutorial"), ("guide.html", "Guide"),
             ("setup.html", "Setup"), (repo, "GitHub"))
    nav = "".join(f'<a href="{url}"' + (' aria-current="page"' if name == active else '') + f'>{name}</a>' for url, name in links)
    return f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="{escape(desc)}">
<title>{escape(title)}</title>
<link rel="stylesheet" href="site/style.css?v=chapter-navigation">
<script src="site/copy.js?v=chapter-navigation" defer></script>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header><div class="wrap bar"><a class="logo" href="./"><span aria-hidden="true">▸</span> ZeroPage</a><nav aria-label="Main navigation">{nav}</nav></div></header>
{content}
<footer><div class="wrap"><span>ZeroPage · 0.1.0 in progress</span><a href="{blob}LICENSE">MIT license</a></div></footer>
</body>
</html>
'''

features = [
 ("Hardware and I/O", "Write to the VIC-II border register, draw directly into screen RAM, or use the PETSCII console, keyboard, KERNAL, and timing helpers. Volatile pointers expose memory-mapped devices. Inline <code>asm {{ ... }}</code> embeds 6502/6510 instructions in the same source.", [doc("api", "Library API"), doc("inline-assembler", "Inline assembler")]),
 ("Memory and banking", "Name C64 and REU ranges in a <code>memory</code> block. Reserve them for arenas, fixed-block pools, the software stack, or DLL windows. Set the PRG load and entry addresses independently. Place selected code and constant data at fixed addresses or copy them into RAM under ROM at startup.", [doc("memory-model", "Memory model")]),
 ("Zero page and call frames", "Specify which zero-page bytes the compiler may use and which are reserved by your code or the system. Static frames give functions fixed storage. <code>callconv(.stack)</code> enables checked recursive frames in a configured RAM region.", [doc("abi", "Calling conventions"), doc("memory-model", "Zero-page policy")]),
 ("REU and DLLs", "Use explicit DMA transfers and typed views to store data in an REU. A DLL can load from disk into an REU cache, then relocate into a C64 RAM window for execution. DLLs can share a window, and configured state ranges can survive a swap. Typed imports and dependency policies make those calls visible in source.", [doc("reu-overlays", "REU and DLLs")]),
 ("Build artifacts and tests", "The compiler emits only the runtime helpers it uses. Inspect the 64tass assembly, VICE labels, and memory map. Use the Peddle 6510 test runner for target assertions and VICE for emulator integration.", [doc("cli", "CLI reference"), doc("testing", "Testing")]),
]
cards = "".join(f'<article><h3>{title}</h3><p>{body.replace("{{","{").replace("}}","}")} {" · ".join(links)}</p></article>' for title,body,links in features)
index = f'''
<main id="main">
  <div class="wrap hero">
    <div>
      <div class="badge">0.1.0 source preview</div>
      <h1>ZeroPage</h1>
      <p>A Zig-shaped language for writing native Commodore 64 programs with explicit control over memory, hardware, and loadable code.</p>
      <div class="actions"><a class="button primary" href="#examples">See the language</a><a class="button" href="#disks">Try a C64 disk</a></div>
    </div>
    <div class="screen" aria-label="The hello demo prints HELLO FROM ZEROPAGE and returns to READY">
      <p aria-hidden="true">**** COMMODORE 64 BASIC V2 ****</p>
      <p aria-hidden="true">READY.</p>
      <p aria-hidden="true">RUN</p>
      <p aria-hidden="true">HELLO FROM ZEROPAGE</p>
      <p aria-hidden="true">READY.<br><span class="cursor"></span></p>
    </div>
  </div>
  <section id="examples" class="section"><div class="wrap">
    <h2>ZeroPage by example</h2>
    <div class="example-grid">
      <article><h3>A first program</h3><p>Use a built-in API to print PETSCII text and write the VIC-II border register.</p>{sample("examples/hello.zp64")}</article>
      <article><h3>Inline 6510 assembly</h3><p>A block-local loop increments a ZeroPage byte through <code>@color</code>. The compiler restores A, X, and status. The byte and VIC-II writes persist. <a href="guide-assembly.html">Assembly chapter</a></p>{sample("docs/tutorial-examples/asm-border.zp64")}</article>
      <article><h3>Read record fields from assembly</h3><p>The static function reads the nested byte <code>actor.pos.x</code> through its flattened name. It stores the result in a local so ZeroPage can return it after A and status are restored. <a href="guide-assembly.html#bindings">Source operands and storage</a></p>{block("By-value record parameter · excerpt", "fn adjustedX" + Path("docs/tutorial-examples/asm-record.zp64").read_text().split("fn adjustedX", 1)[1].split("export fn main", 1)[0].rstrip() + "\n")}</article>
      <article><h3>Bring a firmware result back into ZeroPage</h3><p>KERNAL GETIN returns a byte in A. Store it before the wrapper restores A, then return it as a typed value. <a href="guide-assembly.html#kernal-result">Firmware calls and register preservation</a></p>{block("Keyboard read · excerpt", "fn readKey" + Path("docs/tutorial-examples/asm-getin.zp64").read_text().split("fn readKey", 1)[1].split("export fn main", 1)[0].rstrip() + "\n")}</article>
      <article><h3>Activate a DLL from REU</h3><p>The typed binding declares the export signature. Loading seeds the REU cache from the resident PRG. A loaded module can be activated again after another module takes its execution window. <a href="guide-modules.html#swap">Cache and window walkthrough</a></p>{block("Load and dispatch · excerpt", """extern module RegionDll = region_dll {
    fn tick(value: u8) u8;
}

// Inside main:
if (RegionDll.load()) {
    if (RegionDll.tick(5)) |value| {
        c64.console.print("TICK {x}\\n", .{value});
    }
}
""")}</article>
      <article><h3>Make memory ownership explicit</h3><p>This declaration reserves visible RAM for short-lived allocations and REU space for far records. <a href="guide-arenas.html">Arena and pool chapter</a></p>{block("Region declaration", Path("docs/tutorial-examples/reu-records.zp64").read_text().split("memory {", 1)[1].split("export fn", 1)[0].join(("memory {", "")))}</article>
      <article><h3>Move records into C64 RAM</h3><p>Bring two records into a scratch arena, edit one, and flush the range back to the REU. The local index is relative to the start of the range. <a href="guide-reu.html">Far-memory chapter</a></p>{block("Materialized range excerpt", dedent(Path("docs/tutorial-examples/reu-records.zp64").read_text().split("        if (enemies.materializeRange", 1)[1].split("\n\n            const saved", 1)[0].join(("        if (enemies.materializeRange", "\n        }\n"))))}</article>
    </div>
    <p><a href="tutorial.html">Read the language introduction</a> · <a href="guide.html">Browse the full guide</a></p>
  </div></section>
  <section id="philosophy" class="section"><div class="wrap split">
    <h2>Philosophy</h2>
    <div><p>Use familiar types, functions, and control flow while keeping the costs of the 6510 visible. The language uses Zig's parser for ordinary syntax. ZeroPage lowers a documented subset and adds declarations for C64 concerns such as banking, zero-page ownership, and module loading.</p>
    <p>A small program needs only a <code>main</code> and the helpers it calls. A larger program can choose where code and data live, and inspect the assembled memory map to check those choices. {doc("language", "Language reference")} · {doc("runtime", "Runtime")}</p></div>
  </div></section>
  <section id="c64" class="section"><div class="wrap split">
    <h2>C64 features</h2><div class="features">{cards}</div>
  </div></section>
  <section id="subset" class="section"><div class="wrap">
    <h2>The Zig subset</h2>
    <div class="grid">
      <article><h3>Values and storage</h3><p><code>bool</code>, <code>u8</code>, <code>i8</code>, <code>u16</code>, <code>i16</code>, 16-bit <code>usize</code>, supported near and volatile pointers, fixed arrays and structs, <code>enum(u8)</code>, scalar and pointer optionals, and narrow tagged unions.</p></article>
      <article><h3>Control flow and composition</h3><p>Typed functions, local <code>@import</code>, <code>if</code>, <code>while</code>, fixed-array and zero-based range <code>for</code>, scalar <code>switch</code>, and layout queries such as <code>@sizeOf</code>.</p></article>
      <article><h3>Target semantics</h3><p>Runtime array indexing is unchecked. Arithmetic retains the low bits of the destination width. Strings have PETSCII helpers and fixed-capacity buffers.</p></article>
      <article><h3>Unsupported forms</h3><p><code>std</code>, generics, general <code>comptime</code>, slices, floating point, division, error unions, <code>try</code>, and <code>defer</code> produce diagnostics. {doc("language", "Full language reference")}</p></article>
    </div>
  </div></section>
  <section id="disks" class="section"><div class="wrap split">
    <h2>Sample disks</h2><div>
    <ul>
      <li>{download("examples/zeropage-demos.d64", "ZeroPage demos")} includes <code>HELLO</code> and a banked-memory example.</li>
      <li>{download("sampleapps/tictactoe/tictactoe.d64", "Tic-Tac-Toe")} includes the standalone and classic variants.</li>
      <li>{download("examples/zeropage-reu.d64", "ZeroPage REU")} boots a disk-loaded DLL example with a 16 MiB REU configured.</li>
    </ul>
    <p>{doc("sample-disks", "Disk commands and rebuild instructions")}</p>
    </div>
  </div></section>
</main>'''
Path("docs/index.html").write_text(page("ZeroPage · A language for the Commodore 64", "ZeroPage is a Zig-shaped programming language and compiler for native C64 programs.", "", index))

lessons = [
    ("hello", "Read your first program"),
    ("language", "Write typed 6510 code"),
    ("records", "Model a small piece of game state"),
    ("hardware", "Talk to the hardware"),
    ("assembly", "Use assembly for one machine operation"),
    ("memory", "Plan the memory layout"),
    ("storage", "Give temporary data a lifetime"),
    ("far-memory", "Edit records stored in REU"),
    ("disk-modules", "Call code loaded from disk"),
    ("inspect", "Check the result on the target"),
    ("next", "Continue into the full guide"),
]
toc = "".join(f'<li><a href="#{anchor}">{title}</a></li>' for anchor, title in lessons)

lesson = {}
lesson["install"] = f'''
<p>Download and unpack Zig <strong>0.16.0</strong> and install 64tass <strong>1.60.3243</strong>. Put the directories containing the two executables on your shell's <code>PATH</code>. Zig builds the host compiler and provides its parser. 64tass assembles the emitted 6510 code. Install VICE for <code>x64sc</code> and the optional <code>c1541</code> disk utility. <a href="https://ziglang.org/download/">Zig downloads</a> · <a href="https://sourceforge.net/projects/tass64/files/">64tass downloads</a> · <a href="https://vice-emu.sourceforge.io/">VICE downloads</a></p>
{shell("""
zig version
64tass --version
git clone https://github.com/ReadyOS-C64/ZeroPageLang.git
cd ZeroPageLang
zig build
./zig-out/bin/zp64c tools
""")}
<p><code>zig build</code> installs <code>zp64c</code> under <code>zig-out/bin/</code>. To use an assembler outside <code>PATH</code>, set <code>ZEROPAGE_64TASS=/absolute/path/to/64tass</code>. {doc("getting-started", "Tool overrides")} · {doc("dependencies", "Dependency reference")}</p>'''

lesson["hello"] = f'''
<p>The compiler starts at <code>export fn main() void</code>. The <code>c64</code> import provides the machine-facing API. <code>.{{}}</code> is an empty argument tuple for the formatter.</p>
{sample("examples/hello.zp64")}
{shell("""
mkdir -p build
./zig-out/bin/zp64c compile examples/hello.zp64 -o build/hello.prg
x64sc -autostart build/hello.prg
""")}
<p>The default image loads at <code>$0801</code>. A BASIC line runs <code>SYS 2061</code>, entering the compiled program at <code>$080d</code>. Expect a greeting and a green border. On hardware, put the PRG on a disk or compatible storage device, load it, and enter <code>RUN</code>.</p>'''

colors_example = "docs/tutorial-examples/colors.zp64"
lesson["language"] = f'''
<p>Open <code>docs/tutorial-examples/colors.zp64</code> in the repository. Each keypress advances to the next color. Return exits the program.</p>
{sample(colors_example)}
{shell("""
mkdir -p build
./zig-out/bin/zp64c compile docs/tutorial-examples/colors.zp64 -o build/tutorial-colors.prg
x64sc -autostart build/tutorial-colors.prg
""")}
<p>The fixed array has three bytes. <code>nextIndex</code> keeps the runtime index within bounds because generated indexing has no runtime bounds check. Use <code>u8</code> for byte values and <code>u16</code> or <code>usize</code> for words and addresses. {doc("language", "Types, control flow, and language limits")}</p>'''

hardware_example = "docs/tutorial-examples/volatile-border.zp64"
lesson["hardware"] = f'''
<p>The border helper maps to the VIC-II register at <code>$d020</code>. The example below uses a volatile pointer to that register, then an assembly block to write the background register at <code>$d021</code>. Build <code>docs/tutorial-examples/volatile-border.zp64</code> using the same command pattern.</p>
{sample(hardware_example)}
<p>Use <code>c64.screen</code> for direct screen writes, <code>c64.console</code> for PETSCII output and formatting, and <code>c64.kernal</code> when you need the ROM routines. The keyboard API reports PETSCII values. Inline assembly has a documented instruction and operand subset. {doc("api", "C64 API")} · {doc("inline-assembler", "Inline assembly rules")}</p>'''

lesson["memory"] = f'''
<p>Open <a href="{blob}examples/small/95_memory_regions_placement.zp64">the memory placement demo</a>. It declares visible code at <code>$2000</code>, an arena at <code>$9000</code>, and a region at <code>$e000</code> behind KERNAL ROM. The resident image starts from its configured entry at <code>$1000</code>.</p>
{block("95_memory_regions_placement.zp64 · placement excerpt", Path("examples/small/95_memory_regions_placement.zp64").read_text().split("export fn main()")[0])}
<p><code>linksection("hidden")</code> places the lookup function and table together. <code>.startup_copy</code> keeps their bytes in the load image and copies them to the run address before <code>main</code>. A resident call gateway exposes the hidden RAM and restores the previous mapping. The demo also uses <code>near_heap.allocBytes(2)</code>, which returns an optional pointer to visible C64 RAM.</p>
{shell("""
mkdir -p build
./zig-out/bin/zp64c compile examples/small/95_memory_regions_placement.zp64 -o build/placement.prg
x64sc -autostart build/placement.prg
""")}
<p>Expect <code>PLACEMENT ARENA OK</code>. Open <code>build/placement.prg.zpmap.json</code> and compare the load and run addresses of the <code>hidden</code> placement. A named pool allocates equal-sized blocks, while an arena releases its allocations together with <code>reset()</code>. The separate <code>zero_page</code> policy governs borrowed bytes and fixed reservations. {doc("memory-model", "Region ownership and zero-page policy")}</p>'''

lesson["stack"] = f'''
<p>Ordinary functions use fixed frame storage. For recursion, reserve RAM for the software stack and mark the recursive function with <code>callconv(.stack)</code>. This example counts down to zero and returns the green border value. An exhausted software stack traps.</p>
{sample("examples/small/32_stack_recursive_border.zp64")}
<p>Compile the file and inspect the generated assembly for the entry and frame setup. The software stack holds the supported call-frame values. The 6510 hardware stack still holds CPU return addresses. {doc("abi", "Frame layouts and ABI limits")}</p>'''

lesson["verify"] = f'''
<p><code>zp64c compile</code> emits a PRG plus <code>.asm</code>, <code>.labels</code>, and <code>.zpmap.json</code> sidecars. Use the assembly to see the generated 6510 instructions, VICE labels to set breakpoints, and the map to inspect section ownership. <code>zp64c asm</code> emits assembly without running 64tass.</p>
{shell("""
zig build test
zig build emu-test
zig build e2e
""")}
<p>The unit suite checks the compiler and runner. The Peddle host suite executes the generated machine code and includes <code>test6502</code> assertions. The end-to-end suite compiles the demos and uses Bash, Perl, and <code>c1541</code> to check build and disk artifacts. Full VICE automation uses an external harness. {doc("testing", "Testing and VICE setup")} · {doc("cli", "CLI and sidecars")}</p>'''

lesson["records"] = f"""
<p>Start by grouping values that change together. A game can keep its cursor position, hit points, and facing in one record. A function that takes the record by value gets a copy. A function that takes its address can update the caller's record. Pick the first when you want an independent snapshot and the second when you want one live game state.</p>
{block("A position and a move · excerpt", '''const Position = struct { x: u8, y: u8 };

fn moveRight(pos: *Position) void {
    if (pos.x < 39) {
        pos.x += 1;
    }
}
''')}
<p>The right edge of the default 40-column screen is column 39. Starting at 38, the first call advances the original position to 39. A second call leaves it there. The <a href="guide-data.html#ownership">record chapter</a> compares this style with returning a new value and explains what happens when a copied field is itself a pointer.</p>"""

lesson["assembly"] = f"""
<p>Keep the application in ZeroPage and use a small assembly block where it helps express the machine operation. Here, <code>@color</code> names a mutable source byte. The block counts three iterations in X and writes the resulting value to the VIC-II border register.</p>
{sample("docs/tutorial-examples/asm-border.zp64")}
<p>Expect <code>BORDER 05</code>. The wrapper restores A, X, and status. The changes to <code>color</code> and the VIC-II register remain. When a firmware routine returns a register value, save it to a source variable inside the block before the wrapper restores the register. The <a href="guide-assembly.html">assembly chapter</a> takes this further with record fields, string addresses, and KERNAL calls.</p>"""

lesson["storage"] = f"""
<p>Suppose your game needs a scratch buffer only while drawing a frame. Name a C64 RAM region and assign it to an arena. Check the optional allocation before using it. When the frame is finished, reset the arena so the next frame can reuse the same space.</p>
{sample("examples/small/34_near_heap_arena.zp64")}
<p>Expect <code>ALLOC OK</code> and <code>RESET OK</code>. Every pointer from the old allocation becomes stale at reset. Use a fixed-block pool instead when objects have independent lifetimes and need to be returned one at a time. The <a href="guide-arenas.html">arena chapter</a> compares those lifetimes and shows how to store a record in allocated bytes.</p>"""

lesson["far-memory"] = """
<p>The CPU can directly address C64 RAM. To use bytes in an REU, copy them into C64 RAM over DMA. A far arena allocates REU storage, and a typed view gives you record-sized reads and writes. If you will edit several fields repeatedly, materialize a range into a near arena, work on it there, then flush it back.</p>
<ol>
<li>Allocate and initialize the far records. In the map example, forty eight-byte sectors take 320 bytes in REU.</li>
<li>Bring four sectors into a 32-byte near arena. Far sector 36 becomes local sector 0 in a range starting at 36.</li>
<li>Edit the local records, flush back to far index 36, then reset the near arena. Check the result with a new far read.</li>
</ol>
<p><a href="tutorial-reu.html">Continue with the guided REU exercise</a> and try a request that crosses the end of the map. Use the <a href="guide-reu.html#capacity">capacity table</a> to choose an emulator or hardware layout before starting transfers.</p>"""

lesson["disk-modules"] = """
<p>A DLL gives you a way to bring in code as well as data. The compiler fixes the export signature and the location of each export in the jump table. At runtime, KERNAL reads a disk payload into staging RAM, the loader keeps a copy in REU, and the CPU executes the relocated code in a C64 RAM window.</p>
<p>Start with the <a href="guide-modules.html#disk">side-by-side disk example</a>. The named version supplies the module and export names at the call site. The typed version declares the signature once and uses ordinary call arguments. Both return an optional because the loader may be unable to make the export available. Read the failure branch before running the disk without its payload.</p>
<p><a href="tutorial-dll.html">Follow a DLL from source to a running disk</a>, then continue with the <a href="guide-memory-plan.html">score updater</a> to see a disk DLL, a far arena, and a near working copy in a single program.</p>"""

lesson["inspect"] = """
<p>Start with what the program should do. Observe the screen or border for a device write, or look at the destination bytes in the VICE monitor for a copy. Read the compiler's assembly when you need to see the instructions and its map when you need to see which code or data owns an address.</p>
<p>For the placement example above, check both the load and run address of the hidden table. For the disk example, check that the disk contains the payload under the declared name. The <a href="guide-verification.html">verification chapter</a> connects each question to a compiler artifact or an emulator observation.</p>"""

lesson["next"] = """
<p>The full guide continues with types, inline assembly, memory maps, arenas, REU records, DLL caching, and target verification. Each chapter links runnable examples and explains the limits that matter on a 6510.</p>
<p><a class="button primary" href="guide.html">Open the full guide</a> <a class="button" href="setup.html">Install and build</a></p>"""
sections = "".join(f'<section id="{anchor}"><h2>{title}</h2>{lesson[anchor]}</section>' for anchor,title in lessons)
def section_menu(links):
    return f'<aside aria-label="Section links"><details class="section-menu" open><summary>In this chapter</summary><ul class="toc">{links}</ul></details></aside>'

tutorial = f'''
<main id="main" class="wrap guide">
  {section_menu(toc)}
  <article>
    <h1>Learn ZeroPage</h1>
    <p class="lead">Start with a small C64 program, then work through typed state, hardware, memory, and code loaded from disk. <a href="setup.html">Install and build</a> when you are ready to run the examples.</p>
    {sections}
  </article>
</main>'''
write_reading_page(Path("docs/tutorial.html"), page("ZeroPage tutorial", "Learn ZeroPage by writing native Commodore 64 programs.", "Tutorial", tutorial))

chapters = [
    ("language", "Types, control flow, and imports", "Read data layout, expressions, and diagnostics through the 6510's byte and word model."),
    ("hardware", "C64 I/O and strings", "Choose between direct screen writes, memory-mapped registers, and KERNAL services."),
    ("assembly", "Inline 6510 assembly", "Use source operands, follow the preservation wrapper, and call a ROM routine or terminal vector."),
    ("memory", "Images, placement, and zero page", "Plan a PRG and its regions, including startup copies, bank gateways, and reserved zero page."),
    ("arenas", "Arenas, pools, and records", "Choose a visible-RAM arena, a fixed-block pool, or an REU arena and work with structured data."),
    ("reu", "Far data and materialized views", "Transfer bytes, fetch typed records, or edit a working range in C64 RAM and flush it."),
    ("modules", "DLLs, caches, and activation", "Build a first DLL, then follow it from disk to REU to a shared execution window."),
    ("module-lifecycle", "DLL loading, ownership, and banking", "Handle missing disk files, share dependencies, preserve state, and use RAM under ROM."),
    ("abi", "Frames, recursion, and interop", "Follow data across static and stack calls, and understand the ReadyOS boundary."),
    ("data", "Record layout, pointers, and variants", "Calculate byte offsets and choose between value copies, pointers, optionals, and tagged unions."),
    ("application", "Read a complete C64 application", "Follow Tic-Tac-Toe through input, state, screen RAM, assembly, and verification."),
    ("testing", "Test a program on the 6510", "Write source, compile-fail, and runtime checks with the emulator appropriate to each behavior."),
    ("verification", "Inspect, test, and compare", "Read generated artifacts and verify execution on the host 6510 runner and VICE."),
    ("memory-plan", "Plan a program that uses disk, REU, and RAM", "Build a score updater that combines a disk DLL, an application REU arena, and a near working copy."),
]
chapters_by_slug = {chapter[0]: chapter for chapter in chapters}
guide_parts = [
    ("Write ZeroPage programs", ("language", "data", "hardware", "assembly")),
    ("Plan memory and move data", ("memory", "abi", "arenas", "reu")),
    ("Load code and build applications", ("modules", "module-lifecycle", "memory-plan", "application")),
    ("Verify what runs", ("testing", "verification")),
]
chapter_order = [chapters_by_slug[slug] for _, slugs in guide_parts for slug in slugs]
chapter_numbers = {slug: i for i, (slug, _, _) in enumerate(chapter_order, 1)}

def chapter_sections(items):
    return "".join(f'<section id="{anchor}"><h2>{heading}</h2>{body}</section>' for anchor, heading, body in items)

def guide_page(slug, title, lead, items, chapters_nav=True):
    local = "".join(f'<li><a href="#{anchor}">{heading}</a></li>' for anchor, heading, _ in items)
    breadcrumb = ""
    footer = ""
    if chapters_nav and slug != "guide":
        breadcrumb = '<p class="guide-breadcrumb"><a href="guide.html#chapters">Guide contents</a></p>'
        i = chapter_numbers[slug] - 1
        prev = "guide.html" if i == 0 else f"guide-{chapter_order[i-1][0]}.html"
        next_link = "guide.html" if i+1 == len(chapter_order) else f"guide-{chapter_order[i+1][0]}.html"
        prev_label = "Guide contents" if i == 0 else chapter_order[i-1][1]
        next_label = "Guide contents" if i+1 == len(chapter_order) else chapter_order[i+1][1]
        footer = f'<nav class="chapter-nav" aria-label="Chapter navigation"><a href="{prev}">← {prev_label}</a><a href="{next_link}">{next_label} →</a></nav>'
    main = f'<main id="main" class="wrap guide">{section_menu(local)}<article>{breadcrumb}<h1>{title}</h1><p class="lead">{lead}</p>{chapter_sections(items)}{footer}</article></main>'
    if slug.startswith("tutorial-"):
        file, active = f"{slug}.html", "Tutorial"
    elif slug in ("setup", "guide"):
        file, active = f"{slug}.html", slug.title()
    else:
        file, active = f"guide-{slug}.html", "Guide"
    write_reading_page(Path("docs",file), page(f"{title} · ZeroPage", lead, active, main))

def example_link(path, title="Open the complete source"):
    target = path.removeprefix("docs/") if path.startswith("docs/tutorial-examples/") else blob + path
    return f'<a href="{target}">{title}</a>'

def example_run(path, name, reu=False, anchor=None):
    flags = " -reu -reusize 16384" if reu else ""
    return f'<p>{example_link(path)}</p>' + shell(f"mkdir -p build\n./zig-out/bin/zp64c compile {path} -o build/{name}.prg\nx64sc{flags} -autostart build/{name}.prg", "Build and run this example", anchor)

guide_page("setup", "Install and build ZeroPage", "Set up the host compiler and build a C64 program from a fresh checkout.", [
    ("tools", "Install the tools", lesson["install"]),
    ("compile", "Compile and run", lesson["hello"]),
    ("gates", "Set up the test tools", lesson["verify"]),
], False)

def chapter_card(slug):
    _, title, lead = chapters_by_slug[slug]
    return f'<article><h4><a href="guide-{slug}.html">{chapter_numbers[slug]}. {title}</a></h4><p>{lead}</p></article>'

toc_cards = "".join(
    f'<h3>{part}</h3><div class="grid">{"".join(chapter_card(slug) for slug in slugs)}</div>'
    for part, slugs in guide_parts
)
guide_page("guide", "The ZeroPage programming guide", "A guide to writing ZeroPage programs, from typed values and C64 hardware to a complete game and relocatable DLLs.", [
    ("approach", "How to follow the guide", '<p>Start with <a href="guide-language.html">types and control flow</a> if you are learning the language. Follow <a href="guide-hardware.html">screen and keyboard I/O</a> into the <a href="guide-application.html">Tic-Tac-Toe case study</a> to see those choices in an application. For memory-intensive projects, read <a href="guide-memory.html">memory placement</a> before <a href="guide-arenas.html">arenas</a> and <a href="guide-reu.html">REU views</a>. The <a href="guide-modules.html">DLL walkthrough</a> starts with one call and works up to a shared execution window.</p><p>Code labelled as an excerpt shows part of a program. Complete source links let you read the surrounding declarations and run the example. Build and run links open commands on a separate page. The <a href="setup.html">setup page</a> collects tool installation.</p>'),
    ("chapters", "Chapters", toc_cards),
    ("workbench", "Find a worked example by task", '''
<ul>
<li><a href="guide-language.html#width">Carry a byte counter into a word</a> and predict its displayed bytes.</li>
<li><a href="guide-data.html#ownership">Choose a snapshot or an in-place update</a> for game state.</li>
<li><a href="guide-hardware.html#polling">Keep a display updating while waiting for a key</a>.</li>
<li><a href="guide-assembly.html#strings">Pass a string address and length to assembly</a> and trace what the wrapper preserves.</li>
<li><a href="guide-assembly.html#kernal-result">Capture a KERNAL register result</a> in a typed function.</li>
<li><a href="guide-assembly.html#kernal-load">Pass a filename to KERNAL and capture carry</a> before the assembly wrapper restores status.</li>
<li><a href="guide-memory.html#reservation">Reserve bytes for application code</a> and read the resulting zero-page map.</li>
<li><a href="guide-arenas.html#record">Encode a record in a near arena</a> or <a href="guide-reu.html#range">edit a range of far records</a> and flush it to the REU.</li>
<li><a href="guide-reu.html#working-set">Reuse one working buffer</a> to update an entire far table.</li>
<li><a href="guide-reu.html#sector-map">Calculate a map's REU and scratch capacity</a> and test both bounds.</li>
<li><a href="guide-reu.html#immutable-assets">Stage tile data in REU</a> and fetch a fixed subrange directly to the screen.</li>
<li><a href="guide-reu.html#split-tables">Keep mutable tile state separate from artwork</a> so the two follow different transfer paths.</li>
<li><a href="guide-modules.html#disk">Call the same disk DLL two ways</a>, then <a href="guide-module-lifecycle.html#relocation">trace an address into the execution window</a>.</li>
<li><a href="guide-module-lifecycle.html#state-cycle">Keep a byte across DLL unload and reload</a>.</li>
<li><a href="guide-module-lifecycle.html#policy-lab">Compare preload, on-demand, and explicit loading</a> for the same exports.</li>
<li><a href="guide-module-lifecycle.html#reuse-producer">Package one DLL build for two applications</a> with different loading policies.</li>
<li><a href="guide-memory-plan.html">Build a disk-backed score updater</a> and diagnose a bad memory plan, signature, or disk.</li>
<li><a href="guide-abi.html#stack-limit">Exercise a stack limit</a> with a passing program and a one-byte-smaller variant.</li>
<li><a href="guide-abi.html#frame-trace">Trace a word argument through a nested call</a>.</li>
<li><a href="guide-abi.html#aggregate-return">Trace a three-byte record through a static call</a>.</li>
<li><a href="guide-verification.html#policy-cost">Measure a zero-page policy</a> with the same source workload and assertions.</li>
</ul>'''),
    ("reference", "Look up a language or machine contract", f'''
<ul>
<li>{doc("language", "Language subset")} · {doc("api", "Built-in APIs")} · {doc("inline-assembler", "Assembly operands and instructions")}</li>
<li>{doc("memory-model", "Memory reservations")} · {doc("abi", "Call frames and ABI")} · {doc("reu-overlays", "REU and DLL contracts")}</li>
<li>{doc("cli", "Compiler commands and generated files")} · {doc("testing", "Test tools and fixture directives")} · {doc("compatibility", "Preview compatibility")}</li>
</ul>'''),
    ("terms", "Find a term used in the guide", '''
<dl>
<dt><a href="guide-arenas.html#choose">Arena and pool</a></dt><dd>An arena reclaims its allocations together. A fixed-block pool also lets you return individual blocks.</dd>
<dt><a href="guide-module-lifecycle.html#registry">DLL registry row and active row</a></dt><dd>The registry row tracks a module's residency and references. An execution window's active row identifies the module whose code occupies that window.</dd>
<dt><a href="guide-reu.html#handles">Far handle and near pointer</a></dt><dd>A far handle identifies an REU allocation. A near pointer addresses the C64's CPU-visible address space.</dd>
<dt><a href="guide-memory.html#image">Load address, entry address, and run address</a></dt><dd>The load address is where the PRG arrives. The entry address is where control starts. A placed section's run address is where its bytes are used after any startup copy.</dd>
<dt><a href="guide-reu.html#range">Materialized view</a></dt><dd>A typed working copy of a whole far view or a range, held in a C64 arena. Flush writes its contents back to REU.</dd>
<dt><a href="guide-module-lifecycle.html#relocation">Relocation</a></dt><dd>Patching encoded addresses so a copied DLL can run in its assigned C64 window.</dd>
<dt><a href="guide-module-lifecycle.html#artifacts">Sidecar</a></dt><dd>A compiler output beside the PRG. Maps and labels support inspection. DLL metadata and relocation files also supply information to caller builds.</dd>
<dt><a href="guide-abi.html#stack">Software stack</a></dt><dd>A reserved C64 RAM range for per-call frames. Machine return addresses still go on the 6510 hardware stack.</dd>
<dt><a href="guide-memory.html#zero-page">Zero-page claim</a></dt><dd>A byte or range below <code>$0100</code> owned by the compiler, system, or application according to the selected policy.</dd>
</dl>'''),
])

def fixture_link(path, title):
    return example_link(f"tests/fixtures/emu/{path}.zp64", title)

def paired_examples(left_title, left_label, left, right_title, right_label, right):
    return (
        '<div class="example-grid dll-pair">'
        f'<div><h3>{left_title}</h3>{block(left_label, left)}</div>'
        f'<div><h3>{right_title}</h3>{block(right_label, right)}</div>'
        '</div>'
    )

guide_page("language", chapters[0][1], chapters[0][2], [
    ("program", "Program shape and imports", f'''
<p>An executable declares <code>export fn main() void</code>. The compiler resolves <code>@import("c64")</code> and <code>@import("ZeroPage")</code> internally. Import local <code>.zp64</code> source files for code compiled into the same PRG. A typed DLL import has a separate lifecycle, covered in the <a href="guide-modules.html">DLL chapter</a>.</p>
{sample("examples/small/06_module_main.zp64")}
<p>{example_link("examples/small/06_module_math.zp64", "Imported source file")}</p>'''),
    ("values", "Values, layout, and arithmetic", f'''
<p>Use <code>u8</code> and <code>i8</code> for byte storage and <code>u16</code>, <code>i16</code>, or <code>usize</code> for words. Pointers are 16-bit near addresses. Words are little-endian and alignment is one byte. The compiler retains the destination width on arithmetic. Signed storage is available with a narrower set of arithmetic and comparison operations.</p>
<p>Fixed arrays are contiguous and limited to 255 bytes per array. Struct fields are flattened. Passing a record by value copies its fields. <code>@sizeOf</code>, <code>@alignOf</code>, and <code>@offsetOf</code> inspect supported layouts at compile time. Arrays serve as storage and have restricted by-value behavior.</p>
{sample("examples/small/25_struct_array_table.zp64")}
<p>{doc("language", "Type and expression rules")} · <a href="guide-data.html">Record layout and pointers in depth</a></p>'''),
    ("width", "Follow the carry from a byte into a word", f'''
<p>Predict the two results for input <code>0xff</code>. <code>nextByte</code> returns a byte, so adding one keeps the low eight bits, <code>00</code>. <code>nextWord</code> widens the input first, so the carry reaches bit 8 and the result is <code>0100</code>. Widening after a byte-valued call would preserve only the byte that call returned.</p>
{sample("docs/tutorial-examples/counter-width.zp64")}
{example_run("docs/tutorial-examples/counter-width.zp64", "counter-width", anchor="counter-width")}
<p>The screen shows <code>BYTE 00 WORD 0100</code> and <code>HIGH 0001 LOW 0000</code>. The inferred bindings from the calls retain the declared return widths. Shifting the word right by eight brings the high byte down. Masking with <code>0x00ff</code> clears its high byte. Both expressions here still have word width.</p>
<p>This is a ZeroPage arithmetic rule. Ordinary supported arithmetic keeps the result bits of its target width, and Zig's explicit wrapping operators such as <code>+%</code> are rejected. Use a word before arithmetic when you need to retain the carry. Use unsigned values for shifts. A literal count must be less than the operand width, so <code>word &gt;&gt; 8</code> works where shifting a byte by eight is rejected.</p>
<p>{fixture_link("lang/pass/parity/scalars/u16_math", "Word carry and borrow assertions")} · {fixture_link("lang/pass/parity/scalars/bitwise_shifts", "Masks and runtime shift counts")} · {fixture_link("lang/pass/parity/scalars/inferred_locals", "Inferred scalar bindings")} · {fixture_link("lang/fail_compile/wrapping_add", "Wrapping operator diagnostic")}</p>'''),
    ("flow", "Branches, loops, and indexes", lesson["language"] + '''
<p><code>and</code> and <code>or</code> short-circuit. <code>switch</code> accepts scalar selectors, supported ranges, and optional or tagged-union payloads. <code>for</code> walks fixed arrays or zero-based fixed ranges. Array payloads are read-only copies. Literal out-of-range indexes fail compilation. Guard runtime indexes in application code.</p>'''),
    ("effects", "Predict what happens when expressions have side effects", f'''
<p><code>takeIndex</code> returns index zero and advances the cursor. The update reads the original total of 5 before calling <code>refresh</code>. That call writes 55 into the same slot and returns 7. The final compound assignment stores 5 + 7, replacing the intermediate write.</p>
{sample("docs/tutorial-examples/indexed-update.zp64")}
{example_run("docs/tutorial-examples/indexed-update.zp64", "indexed-update", anchor="indexed-update")}
<p>Expect <code>TOTAL 000C CURSOR 01</code>. The cursor advances once. In application code, split an update into separate statements when it helps readers see the order.</p>'''),
    ("choose-flow", "Choose a loop, a condition, or a value-producing branch", f'''
<p>Use <code>for (items, 0..)</code> to visit a fixed table with its indexes. The capture is a value, so use the index to write back into mutable storage. Use <code>while</code> when the stopping point comes from input or a changing condition. A range-only <code>for</code> uses the supported zero-based fixed range. The loop and switch examples show the supported grammar in complete programs.</p>
<p>Use an <code>if</code> or <code>switch</code> expression when both paths compute a value. For several steps before the result, a labeled block returns a value with <code>break :label value</code>. Keep the result within the supported scalar subset.</p>
{block("Block expression from the control fixture", """fn byteBlock(value: u8) u8 {
    return blk: {
        const base = value + 1;
        break :blk base + 2;
    };
}
""")}
<p>Short-circuiting also controls whether work happens. A false left operand of <code>and</code> skips the right operand, and a true left operand of <code>or</code> skips it. The host fixture checks both the result and whether a helper ran. Use this pattern to guard an indexed read behind a bounds condition.</p>
<p>{example_link("examples/small/17_for_array_loop.zp64", "Fixed-array loop")} · {example_link("examples/small/18_switch_dispatch.zp64", "Scalar switch dispatch")} · {fixture_link("lang/pass/parity/control/bool_short_circuit", "Short-circuit assertions")}</p>'''),
    ("dispatch", "Dispatch input with exact values, lists, and ranges", f'''
<p>The command table contains Return, Down, Space, and an unrecognized byte. The first switch maps them to 1, 2, 32, and 4. Those add to 39. The word-valued switch returns 512 for that exact value, 16 for values from 0 through 10 inclusive, and 1 for the remaining values.</p>
{sample("examples/small/18_switch_dispatch.zp64")}
{example_run("examples/small/18_switch_dispatch.zp64", "switch-dispatch", anchor="switch-dispatch")}
<p>Expect <code>DISPATCH 27</code>, <code>WORD 0200</code>, and <code>SWITCH OK</code>. The first two lines use hex. A comma list shares one branch body, while an unsigned range covers every selector value between its endpoints. Overlapping labels and ranges are rejected. The final switch is a statement and performs output and I/O in its branches.</p>
<p>{fixture_link("lang/pass/parity/arrays_for_switch/switch_scalars", "Byte, word, Boolean, and signed equality cases")} · {fixture_link("lang/fail_compile/switch_overlapping_range", "Rejected overlapping alternatives")}</p>'''),
    ("sum-types", "Enums, optionals, and tagged unions", f'''
<p>An <code>enum(u8)</code> has byte tags. A scalar optional stores presence and payload. A supported pointer optional uses address zero for null. Narrow tagged unions select a payload through a <code>switch</code> capture. This demo models a small event instead of passing a tag and value separately.</p>
{sample("examples/small/24_optional_union_event.zp64")}'''),
    ("array-table", "Use a fixed table and guard a runtime lookup", f'''
<p>Use <code>[_]u8</code> when the initializer determines the length. A declaration such as <code>var bytes: [4]u8 = .{{ 1, 2, 3, 4 }};</code> gives the initializer its type from the binding. Both allocate four contiguous bytes. A word table with four entries needs eight bytes. <code>.len</code> counts elements, so the same bounds check applies to either table.</p>
{block("Fixed lookup with an early return", """const tile_colors = [_]u8{ 0, 5, 7, 2 };

fn colorFor(tile: u8) u8 {
    if (tile >= tile_colors.len) {
        return 0;
    }
    return tile_colors[tile];
}
""")}
<p>For tile 2 the function returns 7. For tile 4 it returns the fallback before touching the table. A runtime index has no automatic bounds check. A function can return from within a loop or an <code>if</code>. Use <code>break</code> when only the loop should end, and <code>return</code> when the caller should get control back. A discard such as <code>_ = step();</code> still runs <code>step</code> and keeps its effects.</p>
<p>{fixture_link("lang/pass/parity/arrays_for_switch/arrays", "Fixed tables, mutable arrays, and element operations")} · {fixture_link("lang/pass/parity/calls/broad_language_parity_extra", "Early return and discarded-call effects")} · {example_link("examples/small/07_loop_control.zp64", "Break and continue on screen")}</p>'''),
    ("imports", "Share code and tables within one program", f'''
<p>Put reusable declarations in a local source file and use its import alias from the caller. The compiler can include read-only tables from an imported file and refer to them through the same alias. These tables are built into the program, so they have no loader or disk lifecycle. If the feature instead needs its own load window and export ABI, use the module chapter.</p>
{paired_examples("Asset file", "Read-only palette", Path("examples/small/29_module_rodata_assets_data.zp64").read_text(),
          "Caller", "Read a palette entry", Path("examples/small/29_module_rodata_assets.zp64").read_text())}
{example_run("examples/small/29_module_rodata_assets.zp64", "imported-assets", anchor="imported-assets")}
<p>{fixture_link("lang/pass/parity/modules/rodata_imports", "Read-only import fixture")} · {example_link("examples/small/29_module_rodata_assets.zp64", "Runnable read-only import demo")} · <a href="guide-modules.html">DLL walkthrough</a></p>'''),
    ("compile-time", "Use a layout calculation in code that runs on the C64", f'''
<p>The compiler resolves layout queries against the C64 representation. <code>Header</code> is five bytes with alignment one, so the array has six bytes. The Boolean field <code>ok</code> has offset four, which selects the value 4 from that array.</p>
{sample("docs/tutorial-examples/record-layout.zp64")}
{example_run("docs/tutorial-examples/record-layout.zp64", "record-layout", anchor="record-layout")}
<p>Expect <code>SIZE 0005 FLAG 04</code> and <code>NESTED OFFSET 0002</code>. The compiler resolves <code>@sizeOf</code> even when it appears inside a normal runtime function. For a fixed array length, put the query and supported arithmetic directly in the length. General <code>comptime</code> blocks and arbitrary calls in array lengths are outside the subset. <a href="guide-data.html#layout">Calculate the offsets by hand</a>.</p>'''),
    ("boundary", "Syntax and target limits", f'''
<p>Zig's AST validates ordinary syntax before ZeroPage lowers its target subset. ZeroPage adds machine declarations and <code>asm {{ ... }}</code>. It gives <code>callconv</code> and <code>linksection</code> target-specific meanings. Valid Zig can receive a ZeroPage diagnostic for constructs such as slices, floating point, division, generics, error unions, or general <code>comptime</code>.</p><p>{doc("language", "Language reference")} · {doc("zig-reference-notes", "Pinned Zig behavior")}</p>'''),
])

guide_page("hardware", chapters[1][1], chapters[1][2], [
    ("screen", "Screen RAM, color, and VIC-II", f'''
<p><code>c64.screen</code> writes the default screen at <code>$0400</code> and color RAM. Screen codes represent glyphs on screen. <code>c64.console</code> accepts text and manages a cursor, newlines, and scrolling. <code>c64.vic.border</code> maps to <code>$d020</code>. For other registers, use a volatile pointer and the register's hardware contract.</p>
{sample("examples/small/21_pointer_mmio.zp64")}
<p>Use <code>ptr.*</code> for a single-item pointer and <code>ptr[i]</code> for a many-item pointer. Volatile reads and writes reach the device. When your program banks memory or changes VIC-II screen configuration, check the assumptions of built-in helpers.</p>'''),
    ("encoding", "Distinguish screen codes from PETSCII bytes", f'''
<p>In this language, the character literal <code>'A'</code> is screen code <code>$01</code>. In the default screen layout, a store to <code>$0400</code> writes that code directly. <code>putAt</code> takes a screen code and <code>putsAt</code> converts text to screen codes. Each approach puts <code>$01</code> into its destination in the example below.</p>
{sample("docs/tutorial-examples/screen-encoding.zp64")}
{example_run("docs/tutorial-examples/screen-encoding.zp64", "screen-encoding", anchor="screen-encoding")}
<p>Expect <code>AAA</code> and, two rows below, <code>01 01 01</code>. Compare that with <a href="guide-assembly.html#kernal-result">reading A from the keyboard</a>, which returns PETSCII <code>$41</code> in the standard input configuration. If you are matching keyboard input, use the PETSCII value or the appropriate <code>c64.key</code> constant. Use screen codes when writing cells directly and PETSCII text with KERNAL output.</p>
<p>{fixture_link("lang/pass/parity/scalars/char_literals", "Character literal checks")} · {doc("api", "Console, screen, and KERNAL APIs")}</p>'''),
    ("strings", "PETSCII, formatting, and buffers", f'''
<p>String constants and buffers are length-counted. The PETSCII and ASCII wrappers choose byte encoding explicitly. A mutable string has fixed capacity and static storage. Appending beyond capacity truncates. Format fields <code>{{s}}</code>, <code>{{x}}</code>, and <code>{{x16}}</code> take arguments in an anonymous tuple.</p>
{sample("examples/small/12_mutable_strings.zp64")}
<p>Use the <a href="guide-assembly.html#strings">assembly string operands</a> when native code needs the data address or length.</p>'''),
    ("access", "Choose a pointer or a screen helper", f'''
<p>A literal MMIO address is useful when the hardware register itself is part of the program's contract. A screen helper computes an address from a row and column. A many-item volatile pointer lets you step through consecutive registers or RAM cells with explicit offsets. These are target addresses. Confirm the mapped device and keep runtime offsets within its range.</p>
<p>{fixture_link("lang/pass/parity/pointers/volatile_mmio", "Direct volatile access fixture")} · {fixture_link("lang/pass/parity/pointers/volatile_pointer_indexing", "Indexed volatile access fixture")} · {fixture_link("lang/pass/parity/strings_asm/strings", "String encoding and buffer fixtures")}</p>'''),
    ("control-bytes", "Build a line from text and PETSCII controls", f'''
<p>Use <code>c64.petscii</code> constants when a control byte should affect the display. A text line can contain an explicit clear, home, reverse-video, or color control. <code>c64.string.ascii</code> and <code>c64.string.petscii</code> specify how literal bytes are interpreted. Use the wrapper that matches the consumer. The control-string demo appends content to a fixed buffer, so every append shares its capacity limit.</p>
{sample("examples/small/13_string_controls.zp64")}
<p>{example_link("examples/small/13_string_controls.zp64", "Complete control-string demo")} · {fixture_link("lang/pass/parity/strings_asm/strings", "Length, concatenation, and buffer assertions")}</p>'''),
    ("input", "KERNAL, keyboard, and timing", f'''
<p><code>readPetscii()</code> returns zero when the buffer is empty. <code>waitPetscii()</code> waits for the first nonzero byte, drains further buffered bytes until GETIN returns zero, and returns the first byte. The empty-buffer check does not observe physical key release. <code>c64.key</code> provides named keys. Use KERNAL calls with the appropriate ROM mapping and system workspace.</p>
{sample("examples/small/14_keyboard_input.zp64")}
<p>Poll with <code>readPetscii()</code> when the rest of the program must keep running between keys. Use the blocking form for a prompt that can wait. <code>sleepTicks</code> waits for changes in the low byte of CIA1 timer A at <code>$dc04</code>. <code>sleepFrames</code> waits for the low raster register at <code>$d012</code> to leave zero and return to it. These are polling loops over the hardware registers. Their timing depends on the running hardware and its configuration. Use VICE to observe behavior that depends on the VIC-II or CIA.</p>
<p>{doc("api", "Complete C64 API")}</p>'''),
    ("polling", "Keep updating the display while you wait for a key", f'''
<p>Try the running counter below. Each pass asks for one buffered key. A stops the loop. With an empty buffer, the program advances the counter, writes it to the screen, and paces the next poll with a short raster wait. Use the same structure to advance a game, animate a cursor, or keep a status display current.</p>
{sample("docs/tutorial-examples/keyboard-poll.zp64")}
{example_run("docs/tutorial-examples/keyboard-poll.zp64", "keyboard-poll", anchor="keyboard-poll")}
<p>Let the count run, then press A. The screen shows <code>STOPPED</code> and the border turns green. The counter is a byte and wraps. The delay illustrates pacing on the default machine mapping. It gives no exact wall-clock interval and does not let other source code run concurrently.</p>
<p>For a prompt that can pause everything, use <code>waitPetscii()</code>. Use a poll when input should share the loop with drawing or game rules. If each keystroke matters, consume the buffered bytes with <code>readPetscii()</code> so the blocking helper does not drain subsequent keys. <a href="guide-application.html#play">See polling in the Tic-Tac-Toe case study</a>.</p>'''),
])

guide_page("assembly", chapters[2][1], chapters[2][2], [
    ("basics", "Start with a block-local loop", f'''
<p>A statement-level <code>asm {{ ... }}</code> block uses 64tass-style instruction syntax. ZeroPage extracts the block before Zig validates the surrounding source. This loop uses X, modifies the mutable byte <code>color</code>, and writes to the VIC-II border register.</p>
{sample("docs/tutorial-examples/asm-border.zp64")}
{example_run("docs/tutorial-examples/asm-border.zp64", "asm-border")}
<p>Expect <code>BORDER 05</code> and a green border. <code>brighten:</code> belongs to this block. Another block may reuse the label. Branches target labels inside their own block and have a displacement of −128 to +127 bytes from the next instruction. <code>jmp label</code> also stays inside the block.</p>'''),
    ("bindings", "Parameters, locals, enums, and flattened record fields", f'''
<p><code>@delta</code> names a byte parameter cell. <code>@result</code> names a mutable byte local. Use <code>@actor_pos_x</code> for the flattened byte field <code>actor.pos.x</code>. This works for a by-value record parameter and a local record. The enum field uses the byte tag from <code>@mode</code>. The function returns through normal ZeroPage source.</p>
{sample("docs/tutorial-examples/asm-record.zp64")}
{example_run("docs/tutorial-examples/asm-record.zp64", "asm-record")}
<p>Expect <code>X 05 MODE 02</code>. Use <code>u8</code>, <code>i8</code>, <code>bool</code>, or byte enums and byte fields. Keep Boolean and enum values valid. Treat parameter cells as the callee's copies. Plain scalar <code>const</code> bindings and word, pointer, array, or whole-record operands are outside this documented interface. Use ZeroPage code to split wider inputs or prepare pointer accesses. <code>#@delta</code> is invalid because a variable cell is not an immediate.</p>'''),
    ("strings", "String addresses, indexed data, and length cells", f'''
<p><code>@source.data,y</code> reads a byte using Y. <code>@msg.data,y</code> writes the mutable buffer. <code>#@source.len</code> is an immediate length, while <code>@msg.len</code> is a runtime cell. A buffer's capacity is fixed. An assembly copy must respect it and update the length.</p>
{sample("examples/small/16_inline_asm_strings.zp64")}
{block("Load a data address into X/Y · excerpt", "ldx #<@source.data\nldy #>@source.data\n", "asm")}
<p>The same low/high address forms work for a mutable buffer. An offset such as <code>@msg.data+12</code> remains assembler arithmetic. Constant data is read-only. <code>#@msg.len</code> and bare string operands are rejected.</p>
<p>To read indirectly, reserve a zero-page pair, initialize it with the low and high address bytes, then load through <code>($30),y</code>. This example saves and restores the borrowed BASIC bytes itself. The register wrapper preserves CPU state, and the compiler's zero-page cleanup covers its own claims.</p>
{sample("docs/tutorial-examples/asm-indirect.zp64")}
<p>{example_link("docs/tutorial-examples/asm-indirect.zp64")}</p>'''),
    ("preserve", "What the compiler saves and restores", f'''
<p>The wrapper combines clobbers across the whole block. The following table counts wrapper bytes on the hardware stack. A subroutine's return address, nested calls, and interrupts consume additional stack space.</p>
<table><thead><tr><th>Instruction example</th><th>Saved state</th><th>Bytes</th></tr></thead><tbody>
<tr><td><code>sta $d020</code>, <code>nop</code></td><td>None</td><td>0</td></tr>
<tr><td><code>inc @value</code>, <code>cmp #5</code>, <code>clc</code></td><td>P</td><td>1</td></tr>
<tr><td><code>lda #5</code>, <code>asl a</code></td><td>P and A</td><td>2</td></tr>
<tr><td><code>ldx #3</code> or <code>ldy #3</code></td><td>P, A, and the changed index register</td><td>3</td></tr>
<tr><td>Both index registers or any external <code>jsr</code></td><td>P, A, X, Y</td><td>4</td></tr></tbody></table>
<p><code>TXA</code> and <code>TYA</code> use A to push the index values. Restores run in reverse order. <code>PLP</code> is last because the preceding pulls and transfers can change flags. Here is the generated wrapper for a KERNAL CHROUT call:</p>
{block("Emitted 6510 instructions", "php\npha\ntxa\npha\ntya\npha\nlda #$41\njsr $ffd2\npla\ntay\npla\ntax\npla\nplp\n", "asm")}
<p>Prepare call registers and consume results inside the same block. Store a useful result to a source cell before fallthrough. RAM, I/O, and ROM workspace writes survive register restoration. The host fixture primes A, X, Y, and P and checks them after both a clobbering block and an external call. <a href="{blob}tests/fixtures/emu/lang/pass/parity/strings_asm/inline_asm.zp64">Register preservation fixture</a>. Reserve assembly-owned zero-page bytes explicitly and account for IRQ and ROM requirements. A block that writes the processor port also owns the resulting bank mapping.</p>'''),
    ("check-state", "Inspect the assembly wrapper in your own program", f'''
<p>Generate assembly for the border example and find the loop that increments <code>color</code>. The block changes A, X, and status. The wrapper saves those before the first instruction and restores them after the store to <code>$d020</code>. If you single-step the PRG in VICE, compare the registers just before the wrapper and just after it. The border remains green because the wrapper restores CPU state while the device write has already happened.</p>
{shell("""
mkdir -p build
./zig-out/bin/zp64c asm docs/tutorial-examples/asm-border.zp64 -o build/asm-border.asm
""", "Generate the border example's assembly", "border-wrapper")}'''),
    ("word", "Pass a word through byte-sized operands", f'''
<p>Give the two bytes explicit names in a by-value record. The block reads <code>@counter_low</code> and <code>@counter_high</code> and writes two mutable local cells. <code>CLD</code> selects binary arithmetic and <code>CLC</code> clears incoming carry. The first <code>ADC</code> produces the low byte and leaves carry set on overflow. <code>STA</code> and <code>LDA</code> leave carry intact, so <code>ADC #0</code> propagates it into the high byte. At fallthrough the wrapper restores incoming flags, including decimal mode and carry. The two stores are the result.</p>
{sample("docs/tutorial-examples/asm-word.zp64")}
{example_run("docs/tutorial-examples/asm-word.zp64", "asm-word", anchor="asm-word")}
<p>Expect <code>COUNTER 1300</code>. The wrapper function widens the result bytes before shifting and joining them. For a routine that consumes a genuine pointer, use the <a href="#strings">address and indirect forms</a>.</p>'''),
    ("kernal-result", "Capture the result of a KERNAL call", f'''
<p>GETIN at <code>$ffe4</code> returns the next PETSCII byte from the keyboard buffer when the keyboard is the input channel. A zero result means no byte is ready. <code>JSR</code> causes ZeroPage to save A, X, Y, and status. Capture A with <code>STA @key</code> inside the block, then return the byte through ordinary ZeroPage code. If a ROM routine reports a condition in flags, branch on those flags inside the block and store a Boolean byte before fallthrough.</p>
{sample("docs/tutorial-examples/asm-getin.zp64")}
{example_run("docs/tutorial-examples/asm-getin.zp64", "asm-getin", anchor="asm-getin")}
<p>With KERNAL visible and the standard keyboard input selected, press A at the prompt. The unshifted A key on the default C64 keyboard configuration prints <code>KEY 41</code>. For ordinary keyboard reads, <code>c64.keyboard.readPetscii()</code> provides the built-in operation. The assembly example exposes the register boundary you also use with other firmware calls.</p>'''),
    ("kernal-load", "Pass a filename and capture the KERNAL carry flag", f'''
<p>Prepare the inputs and consume the result inside one assembly block. For SETNAM, A holds the filename length and X/Y hold its address, low byte first. The string binding supplies all three without a generated label name. SETLFS selects logical file 1, disk device 8, and secondary address 0. With this setup, LOAD uses the destination in X/Y, here <code>$9000</code>. <a href="https://github.com/mist64/c64ref/blob/main/src/kernal/kernal_prg.txt">Commodore Programmer's Reference Guide, KERNAL routines transcription</a></p>
{sample("docs/tutorial-examples/asm-kernal-load.zp64")}
<p>LOAD reports an error with carry set. Branch immediately with <code>BCS</code>. The error path leaves <code>loaded</code> false, and the success path stores 1 into the Boolean cell. Both paths fall through the wrapper, which restores A, X, Y, and status. The source code reads the result cell after that restoration. KERNAL's writes to workspace and destination RAM survive.</p>
<p>Boot the disk with the one-byte tile to see <code>TILE 55</code>. Boot the version with only <code>boot</code> to see <code>LOAD FAILED</code>. The example expects a known one-byte PRG on device 8 and leaves KERNAL and I/O visible. The staging declaration reserves RAM from other compiler claims. KERNAL LOAD can write beyond that reservation if the input is larger, so use the supplied payload when following the exercise.</p>
{shell(r"""
mkdir -p build
firmware_build=$(mktemp -d build/kernal-load.XXXXXX)
./zig-out/bin/zp64c compile docs/tutorial-examples/asm-kernal-load.zp64 -o "$firmware_build/boot.prg"
printf '\000\220\125' > "$firmware_build/tile.prg"
c1541 -format 'kernal call,01' d64 "$firmware_build/load.d64" \
  -write "$firmware_build/boot.prg" boot -write "$firmware_build/tile.prg" tile
c1541 -format 'missing tile,02' d64 "$firmware_build/missing.d64" \
  -write "$firmware_build/boot.prg" boot
x64sc -autostart "$firmware_build/load.d64:boot"
x64sc -autostart "$firmware_build/missing.d64:boot"
""", "Build and boot the two KERNAL load disks", "kernal-load")}
<p>{example_link("docs/tutorial-examples/asm-kernal-load.zp64", "Complete checked load source")} · <a href="guide-modules.html#disk">Follow a DLL through KERNAL staging into REU</a></p>'''),
    ("control", "External calls, terminal jumps, and rejected forms", f'''
<p>External <code>jsr</code> accepts a numeric address or an assembler-resolved symbol and must return with the hardware stack balanced. Local <code>jsr</code>, inline <code>rts</code>/<code>rti</code>/<code>brk</code>, and stack manipulation such as <code>pha</code> or <code>txs</code> are rejected. Keep directives, includes, macros, and data declarations outside the inline form. Use a static-frame function. Stack frames and DLL exports have stricter body rules.</p>
{block("ReadyOS terminal transfer · requires the resident shim", "asm {\n    jmp $c80c\n}\n")}
<p>This single-instruction absolute block transfers to a documented resident vector and bypasses normal ZeroPage return. Supply the machine state required by the vector. Prepare required memory in ZeroPage. A preceding normal block restores registers and flags at fallthrough. Indirect jumps, external symbolic jumps, and additional instructions in the terminal block are rejected.</p>
<p>{doc("inline-assembler", "Complete Markdown reference")} · {example_link("sampleapps/tictactoe_readyos/readyos_shim.zp64", "ReadyOS shim calls")}</p>'''),
    ("branch-range", "Reach a distant label within an assembly block", f'''
<p>A conditional branch encodes a signed byte displacement measured from the instruction after the branch. If <code>beq finish</code> has to skip more than 127 bytes, invert the condition to skip over a nearby absolute <code>jmp</code>. Both labels remain local to the block. A compiler save wrapper surrounds the block, so its pushes do not change the distance between these two local instructions.</p>
{block("Local control flow · assembly excerpt", """    bne continue_work
    jmp finish
continue_work:
    ; the long fallthrough path goes here
finish:
""", "asm")}
<p>In the original, the equal case reaches <code>finish</code>. In the rewritten version, the equal case falls through to <code>jmp finish</code>, and the unequal case branches to <code>continue_work</code>. Inspect the assembled instructions if you are budgeting cycles. {example_link("tests/fixtures/fail/inline_asm_far_branch.zp64", "Out-of-range branch fixture")} · {doc("inline-assembler", "Label and jump rules")}</p>'''),
])

guide_page("memory", chapters[3][1], chapters[3][2], [
    ("image", "Choose an image and entry point", lesson["memory"] + f'''
<p>A default PRG loads at <code>$0801</code> and supplies a BASIC startup line. A raw image uses <code>basic_stub = false</code> and needs an external caller or emulator to enter the declared address. The <code>address_limit</code> is exclusive. A directly loaded distant segment can pad a contiguous PRG. A startup copy keeps the load image compact while giving the code or data a fixed run address. {doc("memory-model", "Image rules")}</p>'''),
    ("regions", "Declare and claim regions", f'''
<p>A region names a physical address range, its address space, and C64 bank visibility where relevant. The compiler validates bounds, overlap, expected space and bank, and claims against the assembled resident image. A region has one reservation role. The same map can describe arenas, pools, a software stack, fixed code, and DLL windows or staging.</p>
<p>Current resident placement supports static functions and constant strings or arrays. Bank gateways expose RAM under ROM, make the call, and restore the processor mapping. KERNAL-dependent calls require particular care when KERNAL is hidden. A banked table belongs with the code that can access it. {doc("abi", "Entry and placement gateways")}</p>'''),
    ("raw-entry", "Read the raw entry contract before handing off control", f'''
<p>The PRG header gives the load address. The caller must also know where to start executing. This example loads at <code>$1000</code> and enters at <code>$1010</code>. Load the PRG at its embedded address and enter <code>SYS 4112</code> from BASIC. The border turns green and the subroutine returns to BASIC.</p>
{sample("docs/tutorial-examples/raw-entry.zp64")}
{shell("""
mkdir -p build
./zig-out/bin/zp64c compile docs/tutorial-examples/raw-entry.zp64 -o build/raw-entry.prg
""", "Build the raw PRG", "raw-entry")}
<p>A host supplies the C64 mapping and a usable hardware stack. If entry returns with <code>RTS</code>, call it or supply an equivalent return frame. Keep the ROM and workspace available when using firmware. With the bare zero-page profile, the host already owns IRQ and NMI before entry. <a href="guide-application.html#hosted">See the ReadyOS application entry</a>. {doc("abi", "Executable entry and lifecycle")}</p>'''),
    ("placement-repair", "Repair a read from RAM hidden under ROM", f'''
<p>After startup copies a table to RAM at <code>$e000</code>, ordinary resident code still sees KERNAL ROM at that address. A direct table read is therefore rejected. Move the lookup function into the table's placement. The resident caller now calls through a gateway, which exposes the RAM, runs the lookup, and restores the prior mapping while preserving its byte result.</p>
{paired_examples("Rejected resident read", "Host fixture · excerpt", """const table: [2]u8 linksection("cold") = .{ 5, 7 };
export fn main() void {
    const index: u8 = 1;
    const border: *volatile u8 = @ptrFromInt(0xd020);
    border.* = table[index];
}
""", "Lookup in the same placement", "From the placement demo", """fn hiddenLookup(index: u8) linksection("hidden") u8 {
    return hidden_values[index];
}
""")}
<p>In the complete placement demo, the caller uses <code>hiddenLookup(1)</code> and gets <code>$42</code>. Keep both the code and its table in the same named region, check that their assembled run ranges fit, and leave firmware-dependent work in resident code. A declaration with start <code>$f800</code> and size <code>$1000</code> has exclusive end <code>$10800</code>, outside the 16-bit address space. Reduce its size to at most <code>$0800</code> or move its start down while staying wholly within the KERNAL bank.</p>
<p>{fixture_link("lang/fail_compile/machine_placement_hidden_data_from_visible", "Rejected banked table access")} · {fixture_link("lang/fail_compile/module_kernal_bank_window_crosses_kernal", "Rejected window crossing the address-space end")} · {example_link("examples/small/95_memory_regions_placement.zp64", "Complete banked lookup and placement demo")} · <a href="guide-verification.html#map">Inspect the demo's memory map</a></p>'''),
    ("zero-page", "Own zero-page bytes explicitly", f'''
{block("Application zero-page policy · excerpt", Path("docs/language.md").read_text().split("## Application zero-page settings")[1].split("```zig\n")[1].split("```")[0])}
<p>The compatibility profile retains the default pointer and frame conventions. The BASIC profile preserves system workspace. The KERNAL profile can borrow BASIC workspace while retaining documented KERNAL services. Bare mode requires a raw image and a caller that already owns interrupts and ROM policy.</p>
<p><code>range</code> defines candidate bytes and <code>reserve</code> subtracts fixed application claims. Reserve bytes used through literal pointers or assembly. With <code>.scratch</code> or <code>.scalars</code>, allocation still depends on eligibility, space, and proof. The map lists what was actually allocated or spilled. Normal return can restore borrowed bytes. Reset and forced warmstart do not run that cleanup. DLL loader programs currently use the compatibility policy. {doc("memory-model", "Zero-page profiles, IRQ/NMI, and restoration")}</p>
<h3>Read a map before counting bytes</h3>
<p>Candidate ranges describe what the compiler may consider. Actual claims show where it allocated pointer pairs, scratch, and eligible parameters. Reserved bytes belong to the application. A spill stays in ordinary RAM. Under the KERNAL profile, restoration on normal return covers the system bytes the compiler borrowed. When assembly writes reserved bytes, your code owns their lifetime and any restoration.</p>
<p>The stack can use explicitly admitted pointer pairs. In the lifecycle fixture, the stack pointer is at <code>$30/$31</code> and the frame pointer at <code>$32/$33</code>. The test seeds zero page before entry and checks cleanup after the real return. Running only <code>main</code> would skip that entry and exit contract. {example_link("tests/fixtures/optimization/zero_page_lifecycle_stack.zp64", "Stack-pointer configuration fixture")} · {example_link("scripts/verify_zero_page_lifecycle.py", "Entry and exit verification")}</p>
<p>To see the difference in a real program, compare the <a href="{blob}tests/fixtures/optimization/zero_page_scalar_reserved.zp64">fixture that reserves two application bytes</a> and the compiler's reported allocations. Explicit reservations let assembly and generated code coexist, while optional scalar allocation depends on what the compiler can prove. {fixture_link("lang/fail_compile/zero_page_protected_kernal", "Rejected claim on KERNAL workspace")}</p>'''),
    ("reservation", "Check a reservation against the actual allocation", f'''
<p>This example borrows BASIC workspace at <code>$30</code> and lists <code>$30–$31</code> as reserved so the compiler cannot allocate there. It saves the previous byte, writes and reads a value, then restores the previous byte before returning from the helper. Expect <code>INPUT AND STORE 81D4</code>.</p>
{sample("docs/tutorial-examples/zero-page-reservation.zp64")}
{example_run("docs/tutorial-examples/zero-page-reservation.zp64", "zero-page-reservation", anchor="zp-reservation")}
<p>In the map, find <code>reserved_ranges</code> and <code>claims</code>. The preview build places the private parameter <code>useReserved_value</code> at <code>$02</code>, outside the reservation. Read your own map after changes to the program. The normal-return restoration covers the compiler's claims on borrowed workspace. Your code is responsible for any bytes it borrows and reserves itself.</p>
{shell("""
python3 -m json.tool build/zero-page-reservation.prg.zpmap.json
""", "Read the zero-page claims after building", "zp-map")}'''),
    ("choose", "Choose storage by lifetime", f'''
<table><thead><tr><th>Declaration</th><th>Allocation result</th><th>Release</th></tr></thead><tbody>
<tr><td>Near arena in C64 RAM</td><td>Optional many-item byte pointer</td><td>Reset the entire arena</td></tr>
<tr><td>Fixed-block pool in C64 RAM</td><td>Optional many-item byte pointer to one block</td><td>Free a block or reset the pool</td></tr>
<tr><td>Far arena in REU RAM</td><td>Optional opaque far handle</td><td>Reset the entire arena</td></tr></tbody></table>
<p>Handle allocation failure before use. Byte counts can use supported expressions. A zero-byte request fails. Arena reset reclaims the space and makes previous allocations stale. The compiler does not track all aliases held by application code.</p>
<p>{doc("memory-model", "Heap and REU reservations")}</p>'''),
    ("arena", "Use a near arena for work done together", f'''
<p>A near arena advances a cursor through its region. Use it for temporary work that can be discarded together. In this example, an allocation writes two bytes and reset lets the next allocation start again at <code>$9000</code>.</p>
{sample("examples/small/34_near_heap_arena.zp64")}
{example_run("examples/small/34_near_heap_arena.zp64", "near-arena")}'''),
    ("record", "Store a structured record in a byte allocation", f'''
<p><code>allocBytes</code> returns bytes. This example uses <code>@sizeOf</code> to request enough space for an <code>Actor</code> and <code>@offsetOf</code> to encode and decode its fields. Normal typed code works with the reconstructed record. Use explicit low and high bytes when encoding a word. A near allocation does not supply a general typed allocator or an integer-to-struct-pointer cast.</p>
{sample("docs/tutorial-examples/arena-record.zp64")}
{example_run("docs/tutorial-examples/arena-record.zp64", "arena-record")}
<p>Expect <code>X 0C HP 05 FACE 01</code>. For typed records that live in an REU, see the <a href="guide-reu.html#records">nested record example</a>.</p>'''),
    ("pool", "Reuse fixed-size blocks", f'''
<p>A pool divides visible RAM into equal blocks. This one has four 16-byte blocks. An allocation consumes a whole block even when it requests fewer bytes. The demo frees the first block and checks that the next allocation gets it back. Pass only a live pointer from that pool to <code>free</code>. Keep using the pointer only while its block is owned by that allocation.</p>
{sample("examples/small/35_fixed_heap_blocks.zp64")}
{example_run("examples/small/35_fixed_heap_blocks.zp64", "pool")}'''),
    ("plan", "Size a pool for reusable objects", f'''
<p>Suppose you need at most four live messages and each encoded message fits in 16 bytes. Reserve 64 bytes and choose a block size of 16. A six-byte message uses one block, with ten bytes of spare capacity in that block. A seventeen-byte message fails even if the pool is otherwise empty. Choose an arena if the messages can all expire together. Choose a pool if you need to return one block while the other messages stay live.</p>
<p>Give a fixed pool a region whose size divides exactly into blocks. Keep it in visible RAM and outside the assembled PRG, stack, and other claims. Allocate record bytes as in the <a href="#record">near arena example</a>, using <code>@sizeOf</code> and an explicit byte layout. Keep the block pointer alive until you have finished every read or write, then return it to its own pool.</p>
<p>{fixture_link("lang/pass/parity/abi/fixed_heap_blocks", "Allocate, exhaust, free, and reuse blocks")} · {fixture_link("lang/fail_compile/heap_fixed_region_not_divisible", "Rejected uneven block layout")} · {fixture_link("lang/fail_compile/heap_free_on_arena", "Rejected per-allocation free on an arena")}</p>'''),
    ("failure", "Plan for exhaustion and reuse", f'''
<p>Each allocator returns an optional. A failed request gives you a chance to retry after a reset, fall back to another buffer, or report that the requested work does not fit. Resetting an arena is a lifetime decision: finish using every pointer and view from that arena first. Freeing a pool block gives only that block back. A request larger than one pool block cannot span multiple blocks.</p>
<p>{fixture_link("lang/pass/parity/abi/near_heap_arena", "Near arena allocation and reset fixture")} · {fixture_link("lang/pass/parity/abi/fixed_heap_blocks", "Pool exhaustion and reuse fixture")} · {fixture_link("lang/pass/parity/abi/far_reu_arena", "Far allocation, transfer, and reset fixture")}</p>'''),
    ("far", "Use a far arena for bulk data", f'''
<p>A far arena allocates in the REU address space. Its handle carries a far address and length. Read and write through <code>copyFromC64</code>, <code>copyToC64</code>, or a typed view. A far handle cannot be cast to a near pointer. The example copies bytes through two screen RAM locations.</p>
{sample("examples/small/36_far_reu_arena.zp64")}
<p><a href="guide-reu.html">Continue to typed far records and materialized views</a>.</p>'''),
])

guide_page("reu", chapters[5][1], chapters[5][2], [
    ("raw", "Move, compare, fill, and swap bytes", f'''
<p>A C64 pointer addresses the CPU's 64 KiB address space. A far address names a byte in the REU. The REU controller moves bytes between the two spaces using DMA. The CPU can then read the copied bytes in ordinary C64 RAM.</p>
<p>Use <code>ZeroPage.reu.present()</code> before a transfer on a machine where the REU may be absent. Configure the emulator with a 16 MiB REU for the examples in this guide. On hardware, check that every configured range fits the installed capacity. Presence alone gives no capacity guarantee.</p>
<table><thead><tr><th scope="col">Call</th><th scope="col">What changes</th></tr></thead><tbody>
<tr><td><code>copyC64ToReu(c64_addr, reu_addr, len)</code></td><td>The REU receives the bytes.</td></tr>
<tr><td><code>copyReuToC64(reu_addr, c64_addr, len)</code></td><td>The C64 destination receives the bytes.</td></tr>
<tr><td><code>compare(c64_addr, reu_addr, len)</code></td><td>Returns whether the ranges match. Both ranges keep their contents.</td></tr>
<tr><td><code>fill(reu_addr, value, len)</code></td><td>Writes the same byte into every position in the REU range.</td></tr>
<tr><td><code>swap(c64_addr, reu_addr, len)</code></td><td>Exchanges the contents of both ranges.</td></tr>
</tbody></table>
<p>The raw far address is a compile-time value from <code>0x000000</code> to <code>0x00ffffff</code>. The C64 address and byte count accept supported runtime expressions. Supply a nonzero byte count. The REU interprets a zero count as a 64 KiB transfer. The compiler rejects a literal zero. Check a runtime count before issuing DMA.</p>
{sample("docs/tutorial-examples/reu-transfer.zp64")}
{example_run("docs/tutorial-examples/reu-transfer.zp64", "reu-transfer", True)}
<p>The example first copies <code>11 22</code> through the REU and checks the result. It then fills the REU range with <code>55 55</code> and swaps it with the result buffer. The C64 result now holds <code>55 55</code>, and the REU again holds <code>11 22</code>. Expect <strong>REU TRANSFER OK</strong>.</p>
<p>The <code>scratch_reu</code> declaration records the range in the program's memory map. A raw DMA call still uses the address supplied at its call site. Keep raw transfers within the ranges you own, away from far arenas, DLL caches, and saved state. {fixture_link("lang/pass/parity/abi/raw_reu_runtime", "Transfer and compare assertions")} · {fixture_link("lang/fail_compile/reu_zero_length", "Literal zero-count diagnostic")}</p>'''),
    ("capacity", "Choose an REU size from the addresses you use", f'''
<p>For each fixed region, add its size to its base. The sum is the exclusive end, so the expansion must have at least that many bytes. Use the greatest end across raw transfers, far arenas, module caches, and saved-state ranges. An REU that answers the presence check can still be too small for a particular address.</p>
<table><thead><tr><th scope="col">Example</th><th scope="col">Highest exclusive end</th><th scope="col">Smallest tested VICE setting for this layout</th></tr></thead><tbody>
<tr><td><a href="#bounded-copy">Bounded DMA</a></td><td><code>$010008</code></td><td>128 KiB</td></tr>
<tr><td><a href="#split-tables">Artwork and mutable state</a></td><td><code>$021004</code></td><td>256 KiB</td></tr>
<tr><td><a href="guide-memory-plan.html#layout">Score updater and DLL cache</a></td><td><code>$032000</code></td><td>256 KiB</td></tr>
</tbody></table>
<p>The linked commands use 16 MiB so they work across the whole guide. To reproduce the smaller configurations above, replace <code>-reusize 16384</code> with <code>-reusize 128</code> or <code>-reusize 256</code> for the matching example. The original smoke demo touches <code>$100000</code> through <code>$100002</code>, beyond a 1 MiB address range. On physical hardware, choose a layout that fits the installed unit before running any transfers. The compiler validates layouts against the address space, and the program owns the installed-capacity assumption.</p>'''),
    ("bounded-copy", "Check the transfer length before starting DMA", f'''
<p>When a count comes from input or a calculation, check both ends before touching the REU. The example gives the source and destination eight bytes each. It rejects 0 and 9, then copies exactly three bytes. The fourth byte stays zero. For a transfer starting partway through either range, check the count against the remaining capacity of both ranges.</p>
{sample("docs/tutorial-examples/reu-bounded-copy.zp64")}
{example_run("docs/tutorial-examples/reu-bounded-copy.zp64", "reu-bounded-copy", True, anchor="bounded-copy")}
<p>Expect <code>BOUNDED COPY OK</code>. The four bytes starting at <code>$9000</code> are <code>55 55 55 00</code>. This uses ordinary visible RAM and the standard I/O mapping for the REU registers at <code>$df00–$df0a</code>. The raw helpers program those registers directly. They do not select a ROM bank for a buffer or validate its extent against the map. Keep staging in visible RAM unless the calling code explicitly provides and verifies a different mapping.</p>
<p>The older <code>33_reu_copy_smoke</code> demo exercises a far address above one MiB's last byte. The bounded copy here uses <code>$010000</code>. Match the highest address touched to the actual expansion size. {example_link("examples/small/33_reu_copy_smoke.zp64", "Original high-address copy demo")} · {fixture_link("lang/fail_compile/reu_address_runtime", "Rejected runtime far address")} · {doc("reu-overlays", "Raw transfer reference")}</p>'''),
    ("handles", "Allocate far bytes without choosing an address at each call", f'''
<p>A far arena carves allocations out of a named REU region. A successful allocation gives you a <code>FarBytes</code> handle. The handle identifies the allocation and carries its length. Use <code>copyFromC64</code> and <code>copyToC64</code> to move bytes using the handle's base address. Keep the transfer length within the allocation and the C64 buffer. The copy still takes an explicit byte count.</p>
{block("From the far arena demo", """const maybe_far = assets.allocBytes(2);
if (maybe_far) |far| {
    ZeroPage.reu.copyFromC64(far, 0x0500, 2);
    ZeroPage.reu.copyToC64(far, 0x0528, 2);
}
""")}
<p>The first argument stays <code>far</code> in both handle-based operations. Read the verbs from the handle's point of view: <code>copyFromC64</code> writes the handle's range, and <code>copyToC64</code> reads it. When the arena is exhausted, allocation returns <code>null</code>. Reset reclaims the entire arena. Finish using its handles and views before resetting. There is no per-allocation free for a far arena.</p>
<p>Use this approach for raw data such as a tile map or a collection of fixed-size blocks. Use a typed view when you need to read and replace individual records. {example_link("examples/small/36_far_reu_arena.zp64", "Complete far arena copy demo")} · {fixture_link("lang/pass/parity/abi/far_reu_arena", "Exhaustion, reset, and independent arenas")} · {fixture_link("lang/fail_compile/far_handle_deref", "Rejected far pointer dereference")}</p>'''),
    ("records", "Allocate and update rich records", f'''
<p>Allocate <code>@sizeOf(Enemy) * count</code> bytes and bind the handle to the record type and a compile-time count with <code>ZeroPage.reu.view</code>. Initialize the records you plan to read. The view supports 1–255 records of 1–255 bytes each. <code>view.len</code> reports the number of records. The compiler checks literal indexes. Keep runtime <code>get</code> and <code>set</code> indexes within the view yourself.</p>
<p>The example stores nested coordinates, a word score, an enum, and a fixed patrol array. A typed <code>get</code> or <code>set</code> transfers one record through compiler-owned staging. Supported layouts include scalar and enum fields, nested records, and fixed scalar or enum arrays. Pointer, optional, union, string, and array-of-record fields are outside the far-record subset.</p>
{sample("docs/tutorial-examples/reu-records.zp64")}
{example_run("docs/tutorial-examples/reu-records.zp64", "reu-records", True)}
<p>Expect <code>REU RECORDS OK</code>. The working arena is 16 bytes. The two 8-byte records at indexes 1 and 2 fit. The whole three-record view would require 24 bytes.</p>'''),
    ("range", "Materialize, edit, flush, reset", f'''
<ol>
<li><code>materializeRange(scratch, 1, 2)</code> reserves space in a named near arena and copies far indexes 1 and 2 into local indexes 0 and 1. The range count is a compile-time literal. A supported runtime start is allowed.</li>
<li><code>local.get</code> and <code>local.set</code> access C64 RAM. Edits to the near view leave the far records unchanged until a flush.</li>
<li><code>flushRange(1, local)</code> writes the local range back starting at far index 1. Reset the near arena only after the final flush and after you are done with all its live views.</li>
<li>Check results with a fresh far <code>get</code>. Reset the far arena when its handles are no longer needed.</li>
</ol>
<p>When the whole table fits in C64 RAM, <code>materialize(scratch)</code> and <code>flush(local)</code> move all records at once. Whole-view flush requires a near view of the same record type and count. Range flush uses the near view's count and the supplied far start. For a runtime start, preserve the value that succeeded during materialization. The flush emitter checks literal starts, so your code must keep a runtime destination in bounds.</p>
<p>Materialization needs a named near arena and the static-frame subset. Copying a range once can avoid a DMA setup for each record access in a loop. The tradeoff is temporary C64 RAM and the cost of copying every record in the range. If you only read one record, a far <code>get</code> keeps that working memory small. If you make no edits, skip the write-back and reset the arena when the near view is no longer needed.</p>
{sample("examples/small/38_far_reu_materialize_flush.zp64")}
<p>{doc("reu-overlays", "Far view and materialization reference")}</p>'''),
    ("ranges-compared", "Choose how much data to bring near", f'''
<table><thead><tr><th scope="col">Workload</th><th scope="col">Read</th><th scope="col">Write back</th></tr></thead><tbody>
<tr><td>Read or replace one record</td><td><code>enemies.get(index)</code></td><td><code>enemies.set(index, replacement)</code></td></tr>
<tr><td>Edit a small table that fits</td><td><code>enemies.materialize(scratch)</code></td><td><code>enemies.flush(local)</code></td></tr>
<tr><td>Edit part of a large table</td><td><code>enemies.materializeRange(scratch, start, count)</code></td><td><code>enemies.flushRange(start, local)</code></td></tr>
</tbody></table>
<p>For an eight-byte record, far index 2 starts sixteen bytes after the allocation base. If a range starts at far index 1, that same record is local index 1. Keep these two indexes separate when editing. {example_link("examples/small/37_far_reu_struct_view.zp64", "Single-record get and set")} · {example_link("examples/small/38_far_reu_materialize_flush.zp64", "Whole-view round trip")} · {example_link("examples/small/39_far_reu_materialize_range.zp64", "Range round trip with a runtime start")}</p>'''),
    ("range-failure", "Handle a range that does not fit", f'''
<p>A literal range outside the far view is a build error. At runtime, both an out-of-range start and an exhausted near arena can return <code>null</code>. Keep the edit and flush inside the successful capture. Check the range first when the program needs to distinguish the two causes.</p>
{block("Show why a four-sector page was unavailable · excerpt", """if (start > 36) {
    c64.console.print("PAGE OUT OF RANGE\\n", .{});
} else if (sectors.materializeRange(scratch, start, 4)) |page| {
    const sector = page.get(0);
    const visits: u16 = sector.visits;
    c64.console.print("VISITS {x16}\\n", .{visits});
    scratch.reset();
} else {
    c64.console.print("PAGE DOES NOT FIT\\n", .{});
}
""")}
<p>Try both cases with the <a href="#sector-map">complete 40-sector map program</a>. Start at 37 to exceed the view. Start at 36 with only 31 scratch bytes to exhaust the arena.</p>'''),
    ("flush-shape", "Match the source view to the destination", f'''
<p>Whole-view flush requires the same record type and count on both sides. A local view of one <code>Enemy</code> cannot stand in for a far table of two <code>Enemy</code> records. To update just the first record, use <code>two.flushRange(0, local)</code> with that one-record local view. The local count determines the number of records written.</p>
{block("Rejected whole-view flush · excerpt from the count fixture", """if (one.materialize("main")) |local| {
    two.flush(local);
}
""")}
<p>Both forms require the matching record type. Equal byte widths alone give no conversion between types. If you are migrating a record format, read the old fields, construct a new record explicitly, and write it through the new view. When troubleshooting, check type, count, and destination start before looking at DMA or banking.</p>
<p>{fixture_link("lang/fail_compile/far_view_flush_wrong_count", "Whole-view count mismatch")} · {fixture_link("lang/fail_compile/far_view_flush_range_wrong_type", "Range flush record-type mismatch")} · {fixture_link("lang/pass/parity/abi/far_reu_materialize_range", "Successful partial write-back")}</p>'''),
    ("working-set", "Process a table larger than its C64 working space", f'''
<p>Four three-byte sectors occupy twelve bytes in REU. The C64 scratch arena has six bytes, enough for two sectors. Process starts 0 and 2 in sequence. For each range, bring in both records, run three update passes in C64 RAM, and write back once. The same arena serves the next range after reset. This works because the first near view has gone out of use before the second allocation.</p>
{sample("docs/tutorial-examples/reu-working-set.zp64")}
{example_run("docs/tutorial-examples/reu-working-set.zp64", "reu-working-set", True, anchor="reu-working-set")}
<p>Predict the final scores <code>1003</code>, <code>2006</code>, <code>3003</code>, and <code>4006</code>. Every sector has three visits. The repeated edits use only near view operations. A fresh set of far reads checks the flushes. Expect <code>WORKING SET OK</code> and a green border with the REU enabled. Boot with it disabled to see <code>WORKING SET FAILED</code> and a red border.</p>
<p>The range count is fixed at two, and the runtime start advances by two. For a table with an odd record count, handle the last record with a single <code>get</code> and <code>set</code> or a separate range with literal count one. The sample allocates through a far arena and verifies copies through the target REU. It allocates no additional C64 working range for the second pair.</p>'''),
    ("immutable-assets", "Stage read-only tile bytes in a fixed REU range", f'''
<p>The PRG starts with two four-byte tiles. The program copies their screen codes into a near arena, transfers all eight bytes to a fixed REU region, and resets the near arena. Later it fetches the second tile directly into screen RAM. This needs one staging buffer for initialization. No typed record view is needed because the renderer consumes four consecutive bytes.</p>
{sample("docs/tutorial-examples/reu-tiles.zp64")}
{example_run("docs/tutorial-examples/reu-tiles.zp64", "reu-tiles", True, anchor="reu-tiles")}
<p>Expect <code>LAKE</code> at the start of the screen. The second tile starts at <code>$020004</code>, four bytes after the declared base. These bytes were encoded as screen codes in the source. The REU copy preserves bytes exactly. Keep this fixed slot separate from your mutable REU tables. Choose a far arena when the program needs to allocate storage for multiple assets at runtime.</p>
<p>In this exercise the source asset is embedded in the PRG. The copy demonstrates staging and reuse of the C64 work buffer. The original table still occupies its compiled read-only storage. {doc("reu-overlays", "Raw DMA and allocation contracts")}</p>'''),
    ("split-tables", "Keep artwork and frequently edited state in separate tables", f'''
<p>The same tile ID selects two representations. ID 1 means the four bytes of <code>LAKE</code> in a fixed artwork slot and the second record in a far state arena. Artwork goes straight to screen RAM. Visits and flags pass through a typed near view. Editing a tile transfers just its two state bytes in each direction. The artwork stays in its own range until the renderer asks for it.</p>
{sample("docs/tutorial-examples/reu-split-tables.zp64")}
{example_run("docs/tutorial-examples/reu-split-tables.zp64", "reu-split-tables", True, anchor="reu-split-tables")}
<p>Expect <code>LAKE</code> and <code>STATE SAVED</code>. After the flush, the lake has three visits and flag <code>$04</code>. The road still has zero visits. The program reuses one near arena for the initial artwork staging and the later state edit. Its <code>states.reset()</code> ends the state allocation's lifetime after verification. In a game, keep the handle until the map is unloaded.</p>
<p>Combine fields in one record when you routinely need them together. Separate tables help when one path wants raw bytes and another wants structured edits with a different lifetime. In either layout, preserve a stable mapping from tile ID to the data you load or write.</p>'''),
    ("measure", "Compare repeated far updates with a working copy", f'''
<p>The same four sectors can be updated directly in REU. This variant keeps the same initial data, the same three passes over each pair, and the same final checks. Each pass reads and writes both far records. In the materialized version, each pair crosses the bus once in each direction and the passes access C64 RAM.</p>
{block("Direct far updates · excerpt", dedent(Path("docs/tutorial-examples/reu-direct-passes.zp64").read_text().split("        var start: u8 = 0;", 1)[1].split("        const first", 1)[0].join(("        var start: u8 = 0;", ""))))}
<table><thead><tr><th scope="col">Update method</th><th scope="col">DMA transfers during editing</th><th scope="col">Bytes moved during editing</th><th scope="col">Additional near arena</th><th scope="col">PRG bytes</th><th scope="col">VICE stopwatch cycles</th></tr></thead><tbody>
<tr><td>Far <code>get</code> and <code>set</code></td><td>24</td><td>72</td><td>0</td><td>2,675</td><td>20,689</td></tr>
<tr><td>Materialize and flush each pair</td><td>4</td><td>24</td><td>6 bytes</td><td>2,846</td><td>16,507</td></tr>
</tbody></table>
<p>The transfer columns count the edit loop only. Both programs also do four initial writes and four verification reads. The VICE measurement covers <code>main</code> through the generated test-exit label, including setup, verification, and screen output. Both produced <code>WORKING SET OK</code>. This preview build trades 171 more file bytes and six reserved C64 bytes for 4,182 fewer cycles in this run. VIC timing and build layout can change the measured values.</p>
<p>When each record needs one update, copying it into a separate arena adds another representation to manage and may offer little benefit. With repeated accesses, the savings grow with the passes you can keep local. Count the transfers and working RAM first, then time the actual path.</p>
<p>{example_link("docs/tutorial-examples/reu-direct-passes.zp64", "Complete direct-update source")} · {example_link("docs/tutorial-examples/reu-working-set.zp64", "Complete materialized version")}</p>
{shell("""
mkdir -p build
./zig-out/bin/zp64c compile docs/tutorial-examples/reu-direct-passes.zp64 -o build/reu-direct.prg
./zig-out/bin/zp64c compile docs/tutorial-examples/reu-working-set.zp64 -o build/reu-working-set.prg
awk '$3 == ".main" || $3 == ".zeropage_test_exit"' build/reu-direct.prg.labels build/reu-working-set.prg.labels
""", "Build both versions and look up their measurement addresses", "measure-reu")}
<p>In VICE with REU enabled, break at the <code>.main</code> address, note <code>STOPWATCH</code> from the register display, and continue to a breakpoint at <code>.zeropage_test_exit</code>. Subtract the first reading from the second. Use a fresh emulator run with the same configuration for each PRG. The labels use the address chosen by that build.</p>'''),
    ("sector-map", "Size a map and its working pages", f'''
<p>A map with 40 sectors needs 320 REU bytes. Each sector has one byte for terrain, one for flags, two for visits, and four for tiles. The record has no padding. Four sectors at a time fit in 32 bytes of C64 scratch. A request starting at sector 36 covers indexes 36 through 39. The edit marks each sector as visited and preserves its terrain and tile data.</p>
{sample("docs/tutorial-examples/reu-map-sectors.zp64")}
{example_run("docs/tutorial-examples/reu-map-sectors.zp64", "reu-map-sectors", True, anchor="sector-map")}
<p>Expect <code>MAP SECTORS OK</code>. Try start 37 and keep scratch at 32 bytes. The range exceeds the far view and materialization returns <code>null</code>. Restore start 36 and reduce scratch to 31 bytes. The range is valid, but the near allocation fails. Both variations reach <code>MAP SECTORS FAILED</code> before editing. If your real program must report separate errors, validate the input range before making the allocation request.</p>
<p>Store tile IDs and flags as bytes. Keep the visit counter as a word so it can grow past 255. Initialize every far record before reading it. If the table grows beyond a view's supported record count, split the data into separately managed views and choose the view before making the local index. {doc("reu-overlays", "Far record and view constraints")}</p>'''),
])

embedded_source = Path("examples/small/96_memory_regions_dll.zp64").read_text()
producer = "module region_dll" + embedded_source.split("module region_dll", 1)[1].split("export fn main", 1)[0].rstrip() + "\n"
binding = "extern module RegionDll" + embedded_source.split("extern module RegionDll", 1)[1].split("\n\nmemory", 1)[0] + "\n"
layout = "memory {" + embedded_source.split("memory {", 1)[1].split("module region_dll", 1)[0].rstrip() + "\n"

disk_named = Path("examples/small/51_module_disk_load_real.zp64").read_text()
disk_typed = Path("docs/tutorial-examples/dll-disk-typed.zp64").read_text()

guide_page("modules", "Your first DLL on the C64", "Export one function, call it through a typed binding, then watch the same loader use disk and reuse the REU cache.", [
    ("typed", "1. Match the export to the caller", f'''
<p>A ZeroPage DLL is a separately callable block of 6510 code with a declared export list. An app can keep several DLLs in REU storage and give them the same small slice of C64 RAM in which to run. This chapter starts with one export, adds a disk payload, then follows a window swap. The <a href="guide-module-lifecycle.html">companion chapter</a> covers loading policies, failure handling, ownership, banking, and sidecars.</p>
<p>We'll call <code>tick(5)</code> and get <code>6</code>. In the first example, the producer and caller are in one source file. On the left, the producer defines a module called <code>region_dll</code> and lists what it exports. On the right, the caller gives that module the local name <code>RegionDll</code> and declares the signature it expects.</p>
{paired_examples("Producer", "Export table and implementation", producer, "Caller", "Binding and use inside main", binding + """
// Inside main:
if (RegionDll.load()) {{
    if (RegionDll.tick(5)) |value| {{
        ok = value == 6;
    }}
}}
""".replace("{{", "{").replace("}}", "}"))}
<ol>
<li><code>abi 1</code> selects the module's calling contract. <code>export tick</code> puts <code>tick</code> in the first export slot. <code>callconv(.stack)</code> gives the implementation the calling convention required by DLL exports.</li>
<li>Match the module id, export name, argument types, and return type. <code>RegionDll</code> is a local name you choose. The compiler checks the signature against this source, or against the producer's sidecars when you build a separate dependency.</li>
<li><code>load()</code> reports whether the module is ready. <code>tick(5)</code> has type <code>?u8</code>: the signature promises a byte on success, and <code>null</code> represents an unavailable call. <code>|value|</code> gives you the byte only on success.</li>
</ol>
<p>Calling <code>tick(5)</code> directly inside the producer calls its resident implementation. Calling <code>RegionDll.tick(5)</code> goes through the loader and the export table. The compiler resolves the typed call to a module row and an export slot during the build. {doc("api", "Module API reference")}</p>'''),
    ("embedded", "2. Build and run the embedded example", f'''
<p>Start with a working <code>zp64c</code> and VICE. The example declares the memory map below. Follow the names from <code>region</code> to <code>stack</code>, <code>window</code>, and <code>reu_cache</code> to see what owns each range. The near arena is used by the demo for two data bytes alongside the DLL.</p>
{paired_examples("What you declare", "Memory and loader configuration", layout, "How the regions are used", "Embedded load · addresses from this example", """Resident PRG
    ↓ load()
REU payload cache   $030000
    ↓ activate and relocate
C64 code window     $c000
    ↓ call tick through export slot 0
C64 software stack  $c800
""")}
<p>Notice that the REU address and the C64 window address name different address spaces. The first <code>load()</code> copies the export table and payload from the resident PRG into the REU cache at <code>$030000</code>. The loader activates the module by copying it to C64 RAM at <code>$c000</code> and patching addresses for that location. The 6510 runs the code from the C64 window. The software stack at <code>$c800</code> supplies the export's call frame.</p>
{example_run("examples/small/96_memory_regions_dll.zp64", "cache", True)}
<p>Look for <strong>REGION DLL CACHE OK</strong> and a green border. This program needs the PRG and an enabled REU. You can run it without a D64. <a href="setup.html">Install and build</a></p>'''),
    ("disk", "3. Load the same export from disk in two ways", f'''
<p>Both programs below load the disk entry <code>enemyrt</code> and call the <code>border</code> export of <code>enemy_runtime</code>. The export adds two to its argument, so passing <code>3</code> sets the VIC-II border to color <code>5</code>. Each program reports a load failure separately from an unavailable call.</p>
<div class="disk-call-comparison">
{paired_examples("Named invocation", "Complete main from the disk demo",
    "export fn main" + disk_named.split("export fn main", 1)[1],
    "Typed invocation", "Complete main from the typed demo",
    "export fn main" + disk_typed.split("export fn main", 1)[1])}
</div>
<p>The named version supplies three pieces to <code>module.call</code>: the module id, the export name, and the argument tuple <code>.{{3}}</code>. The typed version takes its module id and signature from <code>extern module</code>, then uses normal call arguments. Both resolve the export during compilation. The runtime part is loading the bytes and deciding whether the module can be called. Both calls return <code>?u8</code>.</p>
{paired_examples("Named caller import", "Top of the named source", 'const ZeroPage = @import("ZeroPage");\n',
    "Typed caller binding", "Top of the typed source",
    "extern module EnemyRuntime" + disk_typed.split("extern module EnemyRuntime", 1)[1].split("\n\nmemory", 1)[0] + "\n")}
<h3>Configuration shared by both programs</h3>
<p>Disk loading uses visible C64 staging RAM at <code>$9000</code>. KERNAL reads the disk PRG into staging. The loader copies the payload to the REU cache, activates it at <code>$c000</code>, and applies relocation before dispatch. The public export name <code>border</code> comes from <code>export border = borderColor;</code>.</p>
{block("Shared layout, export declaration, and implementation", "memory {"+disk_named.split("memory {",1)[1].split("export fn main",1)[0].rstrip()+"\n")}
<p>{example_link("examples/small/51_module_disk_load_real.zp64", "Complete named source")} · {example_link("docs/tutorial-examples/dll-disk-typed.zp64", "Complete typed source")}</p>
{shell(r"""
mkdir -p build/dll-tutorial
./zig-out/bin/zp64c compile examples/small/51_module_disk_load_real.zp64 -o build/dll-tutorial/named.prg
./zig-out/bin/zp64c compile docs/tutorial-examples/dll-disk-typed.zp64 -o build/dll-tutorial/typed.prg

c1541 -format 'named dll,51' d64 build/dll-tutorial/named.d64 \
  -write build/dll-tutorial/named.prg boot \
  -write build/dll-tutorial/named.prg.zpmod.disk.prg enemyrt
c1541 -format 'typed dll,64' d64 build/dll-tutorial/typed.d64 \
  -write build/dll-tutorial/typed.prg boot \
  -write build/dll-tutorial/typed.prg.zpmod.disk.prg enemyrt

x64sc -reu -reusize 16384 -autostart build/dll-tutorial/named.d64:boot
x64sc -reu -reusize 16384 -autostart build/dll-tutorial/typed.d64:boot
""", "Build and boot both versions")}
<p>Expect <strong>REAL LOAD OK</strong> and a green border in both versions. Try removing <code>enemyrt</code> from a copy of either disk. The same program should report <strong>REAL LOAD FAIL</strong> and set a red border. For an example that checks <code>null</code> after unloading and then calls successfully after reloading, see the {example_link("examples/small/64_module_typed_current_binding.zp64", "typed lifecycle demo")}.</p>'''),
    ("swap", "4. Reuse the REU cache when two modules share RAM", f'''
<p>Imagine a larger program with two independently built DLLs. Both fit at <code>$6000</code>, but you want to spend RAM on just one execution window. Give each DLL its own REU slot and assign both to the same named window. This example declares <code>FixedMath</code> as a prerequisite of <code>MathCore</code>, so a graph acquire can load both together.</p>
{paired_examples("Where they run", "Excerpt from module_loader", """window aux in aux_window;

dependency math_core {
    file = "mathcore";
    window = aux;
    requires = .{.fixed_math};
    persist_in_reu at 0x0400 size 2;
}

dependency fixed_math {
    file = "fixedmath";
    window = aux;
    requires = .{};
}
""", "When they run", "Call sequence inside main", """if (MathCore.acquireGraph()) {
    const first = MathCore.add(3);   // ?u8: 5
    const second = FixedMath.bias(4); // ?u8: 7
    const third = MathCore.add(4);   // ?u8: 6
    MathCore.releaseGraph();
}
""")}
<table><thead><tr><th scope="col">Step</th><th scope="col">Where the bytes come from</th><th scope="col">What runs at $6000</th></tr></thead><tbody>
<tr><td><code>MathCore.acquireGraph()</code></td><td>Disk fills both REU cache slots.</td><td>Neither DLL needs to be active yet.</td></tr>
<tr><td><code>MathCore.add(3)</code></td><td>MathCore's REU slot</td><td>MathCore</td></tr>
<tr><td><code>FixedMath.bias(4)</code></td><td>FixedMath's REU slot</td><td>FixedMath replaces MathCore.</td></tr>
<tr><td><code>MathCore.add(4)</code></td><td>MathCore's existing REU slot</td><td>MathCore returns without another disk read.</td></tr>
</tbody></table>
<p>The complete demo writes two state bytes at <code>$6400</code> while MathCore is active. <code>persist_in_reu at 0x0400 size 2</code> tells the loader to save those bytes when MathCore leaves the window and restore them when it returns. The offset is relative to the window base. Payload bytes and saved state occupy separate REU slots.</p>
<h3>Build the producers, then the caller</h3>
<p>In this example the producer and caller are separate files. The producer can export several functions. The caller declares the one it uses.</p>
{paired_examples("MathCore producer", "From math_core_dispatch.zp64", """module math_core abi 1 {
    export add;
    export is_five = isFive;
    export wide;
    export table_ptr = tablePtr;
}

fn add(value: u8) callconv(.stack) u8 {
    return bump(value);
}
""", "Application caller", "From 85_module_typed_multi_window_binding.zp64", """extern module MathCore = math_core {
    fn add(value: u8) u8;
}
""")}
<p>Compile each DLL first. The caller's <code>--dependency-module</code> and <code>--dependency-relocsim</code> options use the producer's sidecars to check signatures and prepare relocation. Put the <code>.zpmod.disk.prg</code> payloads on the disk for the C64 to load.</p>
{shell(r"""
mkdir -p build/dll-tutorial
cd build/dll-tutorial
compiler=../../zig-out/bin/zp64c
"$compiler" compile ../../tests/fixtures/emu/modules/math_core_dispatch.zp64 -o math.prg
"$compiler" compile ../../tests/fixtures/emu/modules/fixed_math_runtime.zp64 -o fixed.prg
"$compiler" compile ../../examples/small/85_module_typed_multi_window_binding.zp64 -o swap.prg \
  --dependency-module math_core=math.prg.zpmod.json \
  --dependency-relocsim math_core=math.prg.zpmod.relocsim.json \
  --dependency-module fixed_math=fixed.prg.zpmod.json \
  --dependency-relocsim fixed_math=fixed.prg.zpmod.relocsim.json
c1541 -format 'typed swap,85' d64 swap.d64 \
  -write swap.prg boot \
  -write math.prg.zpmod.disk.prg mathcore \
  -write fixed.prg.zpmod.disk.prg fixedmath
x64sc -reu -reusize 16384 -autostart swap.d64:boot
""", "Build both DLLs and boot the shared-window disk")}
<p>Look for <strong>TYPED WINDOW OK</strong>. Use a new output filename or remove the generated <code>swap.d64</code> before reformatting. The complete source shows the {example_link("tests/fixtures/emu/modules/math_core_dispatch.zp64", "MathCore producer")}, the {example_link("tests/fixtures/emu/modules/fixed_math_runtime.zp64", "FixedMath producer")}, and the {example_link("examples/small/85_module_typed_multi_window_binding.zp64", "caller")}. {doc("testing", "End-to-end tool requirements")}</p>'''),
    ("model", "Keep the four locations straight", f'''
<table><thead><tr><th scope="col">Location</th><th scope="col">Job</th><th scope="col">Example</th></tr></thead><tbody>
<tr><td>Resident PRG or disk</td><td>Supplies the initial module bytes.</td><td>The embedded export, or the <code>enemyrt</code> disk entry.</td></tr>
<tr><td>C64 staging RAM</td><td>Receives the bytes from KERNAL disk load.</td><td><code>$9000</code> in the disk example.</td></tr>
<tr><td>REU cache</td><td>Keeps payloads available while other modules use the window.</td><td>Separate slots for MathCore and FixedMath.</td></tr>
<tr><td>C64 execution window</td><td>Holds relocated code and the export jump table for the active module.</td><td><code>$6000</code> for the shared window.</td></tr>
</tbody></table>
<p>A row can stay loaded in REU while another row owns its window. Sharing a window saves C64 RAM. Switching its owner costs an REU transfer and relocation. A call to an already active row uses its existing jump table. Final release clears the row's callability even if its old bytes are still present. Acquiring it again can require another load. {doc("abi", "Module ABI and sidecar format")}</p>'''),
    ("policy", "Choose what to learn next", f'''
<p>Continue with <a href="guide-module-lifecycle.html">DLL loading, ownership, and banking</a>. Its examples show what happens when a file is missing, how two clients share a dependency, what changes under ROM, and which build artifacts you need to inspect.</p>
<p>{doc("reu-overlays", "REU and DLL reference")} · {doc("abi", "ABI and relocation reference")}</p>'''),
])

def module_fixture(name, title):
    return example_link(f"tests/fixtures/emu/lang/pass/parity/abi/{name}.zp64", title)

guide_page("module-lifecycle", chapters[7][1], chapters[7][2], [
    ("policies", "Decide when disk I/O happens", f'''
<p>Start with an explicit load while you bring up a new module. Preload moves disk I/O to startup. On-demand moves it to the first call that needs the module. Choose based on where the user can tolerate a delay and what your program will do if the disk entry is missing.</p>
{paired_examples("Preload before main", "Current module · configuration excerpt", """current {
    load = .preload;
    load_file = "enemyrt";
}
""", "Load on the first call", "Current module · configuration excerpt", """current {
    load = .on_demand;
    load_file = "enemyrt";
}
""")}
<p>Both are settings inside <code>module_loader</code>. Supply disk staging and a filename. For dependencies, put the policy on the <code>dependency</code> row and supply its <code>file</code>. With <code>.manual</code>, use an explicit load or acquire. With <code>.preload</code>, check availability at entry before relying on the export. With <code>.on_demand</code>, handle <code>null</code> at the call site. A later call to an already loaded module can reuse the cache.</p>
<p>{example_link("examples/small/52_module_preload_policy.zp64", "Current preload demo")} · {example_link("examples/small/53_module_on_demand_policy.zp64", "Current on-demand demo")} · {module_fixture("module_preload_policy_missing_disk", "Preload with a missing disk entry")} · {module_fixture("module_dependency_on_demand_policy_missing_disk", "Dependency call with a missing disk entry")}</p>'''),
    ("policy-lab", "Observe when the same disk DLL becomes callable", f'''
<p>This program checks the registry at entry, then calls three typed exports. Build it as written to see on-demand loading. Change only <code>.on_demand</code> to <code>.preload</code> and rebuild to see startup loading. For manual loading, use <code>.manual</code>, remove <code>load_file</code>, and put <code>_ = Rules.loadFromDisk("rules");</code> immediately before the first call. That keeps the entry check at the same point in all three versions.</p>
{sample("docs/tutorial-examples/dll-policy.zp64")}
<table><thead><tr><th scope="col">Policy</th><th scope="col">What main prints first</th><th scope="col">What starts the disk load</th></tr></thead><tbody>
<tr><td>Preload</td><td><code>ENTRY LOADED</code> when startup found the file</td><td>Generated startup</td></tr>
<tr><td>On demand</td><td><code>ENTRY EMPTY</code></td><td>The first call to <code>Rules.tick</code></td></tr>
<tr><td>Manual</td><td><code>ENTRY EMPTY</code></td><td>The explicit <code>loadFromDisk</code> call</td></tr>
</tbody></table>
<p>In every successful run, the byte is <code>06</code>, the word is <code>1335</code>, and the Boolean export returns <code>false</code>. The capture branch runs for a present Boolean even when its value is false. With the on-demand disk entry absent, the first call returns <code>null</code> and the program prints <code>DLL UNAVAILABLE</code>. An embedded <code>load()</code> instead seeds the current row from the resident PRG, as in the <a href="guide-modules.html#embedded">embedded walkthrough</a>.</p>
<p>{example_link("docs/tutorial-examples/dll-policy.zp64", "Complete on-demand source")}</p>
{shell("""
mkdir -p build
rules_build=$(mktemp -d build/rules-tutorial.XXXXXX)
./zig-out/bin/zp64c compile docs/tutorial-examples/dll-policy.zp64 -o "$rules_build/boot.prg"
c1541 -format 'rules policy,01' d64 "$rules_build/rules.d64" \\
  -write "$rules_build/boot.prg" boot \\
  -write "$rules_build/boot.prg.zpmod.disk.prg" rules
x64sc -reu -reusize 16384 -autostart "$rules_build/rules.d64:boot"
""", "Build and boot the policy exercise", "rules-policy")}'''),
    ("export-types", "Choose an export signature the loader can call", f'''
<p>ABI 1 calls use stack-frame exports with supported scalar parameters and return types. Booleans, bytes, and byte enums occupy one byte. Words and <code>usize</code> occupy two. The return byte comes back in A, and a word uses A for its low byte and X for its high byte. In the policy exercise the typed binding exposes each return as an optional because the row might be unavailable. The optional belongs to the caller-side operation.</p>
<p>Keep structured state in application memory and pass the fields the DLL needs. A source function in a static frame can accept and return a record. DLL dispatch rejects aggregate and optional exports, as well as pointer-shaped interfaces. Use a supported scalar result for status and test availability before interpreting it. The export signature also determines how many bytes the caller passes, so rebuild both ends together when changing widths.</p>
<p>{module_fixture("module_disk_reload_matrix", "Host assertions for byte, Boolean, and word results")} · {fixture_link("lang/fail_compile/zeropage_module_aggregate_export", "Rejected aggregate export")} · {fixture_link("lang/fail_compile/zeropage_module_optional_export", "Rejected optional export")}</p>'''),
    ("ownership", "Keep a module callable while callers still need it", f'''
<p>A successful acquire takes a reference to the dependency. Release it after the work finishes. In this example two clients acquire the graph. The first release leaves the other client able to call MathCore. The last release makes the binding return <code>null</code>. The program then reacquires the graph and calls it again.</p>
{sample("examples/small/79_module_typed_dependency_graph_ownership.zp64")}
<p>Expect <code>TYPED GRAPH OWNERSHIP OK</code>. Follow the <a href="guide-modules.html#swap">disk walkthrough</a> for the producer and packaging steps. Use demo 79 as the caller and keep the two producer payloads on the disk.</p>'''),
    ("graphs", "Load prerequisites and recover from a failed graph load", f'''
<p>Declare graph edges with <code>requires</code> on each participating row, including an empty list for a leaf. The compiler checks missing nodes and cycles. The loader visits prerequisites first. On failure it rolls back rows or references introduced by that operation. A dependency row can opt into the graph path with <code>graph = true</code> under preload or on-demand policy.</p>
{paired_examples("Declare a graph policy", "Dependency row · configuration excerpt", """dependency math_core {
    file = "mathcore";
    load = .on_demand;
    graph = true;
    requires = .{.fixed_math};
}

dependency fixed_math {
    file = "fixedmath";
    requires = .{};
}
""", "Check a missing dependency", "Call site · excerpt", """if (MathCore.add(3)) |sum| {
    c64.console.print("SUM {x}\\n", .{sum});
} else {
    c64.console.print("CHECK MATHCORE AND FIXEDMATH\\n", .{});
}
""")}
<p>Loading a graph makes its modules available in REU. It does not invoke their exports. To call a transitive module such as <code>FixedMath</code>, declare its binding and provide its sidecars at build time. A typed transitive binding can call its exports after a direct dependency loads the graph. It cannot independently acquire that transitive graph through the same binding.</p>
<p>{example_link("examples/small/74_module_dependency_graph_on_demand_policy.zp64", "On-demand graph demo")} · {example_link("examples/small/75_module_dependency_graph_preload_policy.zp64", "Preload graph demo")} · {module_fixture("module_dependency_graph_on_demand_policy_missing_disk", "Rollback when disk load fails")} · {module_fixture("module_typed_graph_node_binding", "Call a typed transitive dependency")}</p>'''),
    ("preloaded-ownership", "Keep startup residency separate from a client's reference", f'''
<p>With <code>load = .preload;</code> and <code>graph = true;</code>, startup loads FixedMath before MathCore. Each starts with one reference. A client can take a separate reference for its work and release it without clearing startup residency.</p>
{block("Use a preloaded dependency · excerpt", """if (MathCore.acquireGraph()) {
    if (MathCore.add(3)) |sum| {
        c64.console.print("SUM {x}\\n", .{sum});
    }
    MathCore.releaseGraph();
}
""")}
<p>Keep the initial references while your program wants the feature available. Release those only when the program owns them and has finished using the graph. The <a href="#policy-lab">loading policy exercise</a> shows when the load happens.</p>'''),
    ("registry", "Read the loader registry while diagnosing a failed call", f'''
<p>Row 0 describes the current module. Direct dependencies follow their declared order. Transitive dependencies follow in first-seen order. In the missing-prerequisite fixture, that makes <code>math_core</code> row 1 and <code>fixed_math</code> row 3. A row can exist before any disk load succeeds. Its loaded byte answers whether the payload is available. Its refcount records ownership. The active-row byte belongs to the C64 execution window and can change without either module losing its REU residency.</p>
<p>Here the disk contains <code>mathcore</code> but omits <code>fixedmath</code>. The loader visits <code>fixed_math</code> first. The graph operation reports failure, and both rows remain unloaded with zero references. Inspect loaded state with the public API or use generated labels to find the registry bytes in the VICE monitor. If your program has already taken a reference, pair its successful acquisition with its own release. A failed operation rolls back the references it took, so an existing owner remains responsible for its reference.</p>
<p>In the registry-initialization fixture, all three rows start unloaded. Their cache slots begin at <code>030000</code>, <code>030800</code>, and <code>031000</code>. Each gets one window-sized slot in that configuration. Increasing the number of rows consumes more REU capacity, even when the disk payloads are small. {module_fixture("module_registry_rows", "Registry rows and initial cache contents")} · {module_fixture("module_dependency_graph_load_missing", "Failed prerequisite load")} · {module_fixture("module_typed_dependency_graph_ownership", "Shared graph ownership")}</p>'''),
    ("rollback", "Preserve an existing owner when a later graph load fails", f'''
<p>MathCore is already available. The program tries to acquire Pathing, which also needs MathCore. The disk contains MathCore and omits Pathing. The failed graph load unwinds its own reference, so the existing MathCore caller can still calculate a result.</p>
{sample("docs/tutorial-examples/dll-rollback.zp64")}
<p>Expect <code>MATH STILL AVAILABLE</code>. The program releases its original MathCore reference when it finishes. Release a graph only after its acquire reports success.</p>
{shell(r"""
mkdir -p build
out=$(mktemp -d build/rollback.XXXXXX)
./zig-out/bin/zp64c compile tests/fixtures/emu/modules/math_core_dispatch.zp64 -o "$out/math.prg"
./zig-out/bin/zp64c compile docs/tutorial-examples/dll-rollback.zp64 -o "$out/boot.prg" \
  --dependency-module "math_core=$out/math.prg.zpmod.json" \
  --dependency-relocsim "math_core=$out/math.prg.zpmod.relocsim.json"
c1541 -format 'rollback,01' d64 "$out/boot.d64" \
  -write "$out/boot.prg" boot -write "$out/math.prg.zpmod.disk.prg" mathcore
x64sc -reu -reusize 16384 -autostart "$out/boot.d64:boot"
""", "Build and boot the missing-dependency disk", "shared-owner")}'''),
    ("banks", "Choose a visible window or RAM under ROM", f'''
<p>A visible RAM window is the easiest place to start. If you need more visible RAM for the main program, put the window under BASIC or KERNAL ROM. The range must fit entirely within the selected bank. The loader restores the processor port after the banked operation.</p>
{paired_examples("Under BASIC ROM", "Region inside memory", """region module_window: c64 at 0xa000 size 0x0800
    bank .ram_under_basic;
""", "Under KERNAL ROM", "Region inside memory", """region module_window: c64 at 0xe000 size 0x0800
    bank .ram_under_kernal;
""")}
<p>The KERNAL path also preserves processor status and masks IRQs while KERNAL is hidden. Keep these exports independent of KERNAL services. ZeroPage supports a resident trampoline for supported console calls. Keyboard, raw KERNAL, disk, and unsupported inline assembly paths are rejected for this bank. Use a visible window when the export needs those services.</p>
<p>{example_link("examples/small/87_module_current_basic_bank.zp64", "BASIC-bank demo")} · {example_link("examples/small/90_module_current_kernal_bank.zp64", "KERNAL-bank demo")} · {example_link("examples/small/93_module_kernal_console_trampoline.zp64", "Console trampoline demo")} · {module_fixture("module_kernal_bank_console_trampoline", "Fixture checking that $0001 is restored")}</p>'''),
    ("banked-console", "Print from a DLL that runs under KERNAL ROM", f'''
<p>Put a simple banner export in a window at <code>$e000</code>. While the DLL runs, KERNAL ROM is hidden so the CPU can fetch the DLL's instructions from RAM. The compiler accepts supported <code>c64.console</code> output in this export and emits a console trampoline path. In this demo the trampoline calls the screen-writing console helpers. A direct call into the hidden ROM would have a different target.</p>
{sample("examples/small/93_module_kernal_console_trampoline.zp64")}
{example_run("examples/small/93_module_kernal_console_trampoline.zp64", "banked-console", True, anchor="banked-console")}
<p>Expect <code>TRAMP EXPORT</code> from the DLL and <code>TRAMP OK</code> from the caller. The bank gateway saves the processor port, masks IRQs, exposes RAM for dispatch, preserves the return value across cleanup, and restores the caller's mapping. The host fixture checks <code>$0001</code> before loading, after loading, and after calling. Its initial and final value is <code>$37</code>.</p>
<p>If the export needs a key, read it in the resident caller and pass a byte argument. The keyboard example below is rejected because it requests the KERNAL-dependent read inside the export. A visible window avoids the bank transition for code that needs supported ROM services. {fixture_link("lang/fail_compile/module_kernal_bank_export_uses_keyboard", "Rejected keyboard read in an export")} · {module_fixture("module_kernal_bank_console_trampoline", "Port and return-value assertions")} · {doc("abi", "Banking contract")}</p>'''),
    ("state", "Choose which state survives activation", f'''
<p>When a new DLL takes a window, the loader copies a fresh image over the old contents. Use <code>persist_in_reu</code> for selected state bytes that must survive. The state offset is relative to the start of the execution window. For state at <code>$c100</code> in a <code>$c000</code> window, the offset is <code>$0100</code>. Use <code>discard_on_unload</code> when an unload should discard that row's state. These policies are mutually exclusive for a row.</p>
{block("Keep two bytes across activations · configuration excerpt", """current {
    persist_in_reu at 0x0100 size 2;
}
""")}
<p>Persistent ranges are saved separately from the payload before replacement or final unload and restored after copy and relocation. They consume REU capacity. The compiler checks bounds, overlap, and available cache space. {example_link("examples/small/66_module_state_runtime.zp64", "Write two bytes, unload, clear the window, and reload")} · {doc("reu-overlays", "State and cache reservations")}</p>'''),
    ("state-cycle", "Trace one byte through unload and reload", f'''
<p>Before loading, <code>tick(5)</code> calls the resident function and returns 6. <code>Counter.tick(5)</code> goes through the export table and returns <code>null</code> while the module is unavailable. After <code>Counter.load()</code>, the binding returns 6. The program writes that value at <code>$c780</code>, an offset of <code>$0780</code> into the active window at <code>$c000</code>.</p>
{sample("docs/tutorial-examples/dll-state-cycle.zp64")}
{example_run("docs/tutorial-examples/dll-state-cycle.zp64", "dll-state-cycle", True, anchor="state-cycle")}
<p>Unload saves the declared byte, then clears the row's callability. The program writes zero to the old location to prove that the next read depends on restoration. The direct function still returns 6. The binding returns <code>null</code> until the next load. Reload activates a fresh copy and restores the saved byte. Expect <code>STATE 06</code> and <code>STATE CYCLE OK</code>.</p>
<p>In the module sidecar, <code>state.current.snapshot_reu_addr</code> gives the snapshot base <code>$030800</code>. Add the declared offset <code>$0780</code> to find the saved byte at <code>$030f80</code>. The payload slot and the snapshot slot have separate jobs. Check the relocation sidecar's payload length before choosing a state offset. In this build, the payload ends before the byte at offset <code>$0780</code>. Declare only the state the DLL must keep.</p>
<p>Replace <code>persist_in_reu at 0x0780 size 1;</code> with <code>discard_on_unload;</code> and rebuild. In this run the byte reads <code>00</code>, and the check reports <code>STATE CYCLE FAILED</code>. The test deliberately clears the window between loads. The discard policy leaves no snapshot for the loader to restore.</p>'''),
    ("window-plan", "Read a two-window memory plan", f'''
<p>The <a href="guide-modules.html#swap">disk and REU cache exercise</a> reserves two independent execution windows. Only the auxiliary one is exercised by the MathCore and FixedMath calls. The current module's <code>tick</code> calls in this example are direct resident calls. A separate window gives the loader room to keep a different row active there if the program uses it.</p>
<table><thead><tr><th scope="col">Resource</th><th scope="col">Address range</th><th scope="col">Role in the example</th></tr></thead><tbody>
<tr><td>Auxiliary window</td><td>C64 <code>$6000–$67ff</code></td><td>MathCore and FixedMath alternate here.</td></tr>
<tr><td>Disk staging</td><td>C64 <code>$9000–$97ff</code></td><td>KERNAL reads each payload here before it goes to REU.</td></tr>
<tr><td>Main window</td><td>C64 <code>$c000–$c7ff</code></td><td>Default window for unassigned rows.</td></tr>
<tr><td>Software stack</td><td>C64 <code>$c800–$cbff</code></td><td>Frames for module calls and scalar helpers.</td></tr>
<tr><td>Cache reservation</td><td>REU <code>$030000–$033fff</code></td><td>Payload slots plus space for declared saved state.</td></tr>
</tbody></table>
<p>Inspect the caller's <code>.zpmod.json</code>. <code>loader.load_windows</code> lists the two address ranges. <code>loader.window_assignments</code> maps MathCore row 1 and FixedMath row 3 to <code>aux</code>. <code>dependency_graph.rows</code> includes the transitive row. <code>state.deps</code> shows the MathCore snapshot address <code>$032800</code> for this configuration. Its two source bytes are at <code>$6400–$6401</code> while MathCore owns the auxiliary window.</p>
<p>Change one declaration at a time while planning your own layout. Moving the window changes where the caller dispatches, where the relocation applies, and where window-relative state lives. Keep the RAM reservations disjoint and rebuild the caller against matching producer artifacts. {example_link("examples/small/85_module_typed_multi_window_binding.zp64", "Complete caller and memory plan")} · {doc("memory-model", "Region overlap and bank rules")}</p>'''),
    ("independent-windows", "Keep two DLLs active at the same time", f'''
<p>Assign Pathing to the main window at <code>$c000</code> and FixedMath to <code>aux</code> at <code>$6000</code>. Acquire and call each one. Both stay active until displaced in their own window or finally released.</p>
{block("Use both windows · excerpt", """if (Pathing.acquire()) {
    if (Pathing.step(5)) |position| {
        c64.console.print("POSITION {x}\\n", .{position});
        if (FixedMath.acquire()) {
            if (FixedMath.bias(4)) |score| {
                c64.console.print("SCORE {x}\\n", .{score});
            }
            FixedMath.release();
        }
    }
    Pathing.release();
}
""")}
<p>The calls produce 8 and 7. Before either release, inspect the export jump tables at <code>$c000</code> and <code>$6000</code>. Separate windows keep more code in C64 RAM. A shared window trades activation work for a smaller RAM reservation.</p>'''),
    ("artifacts", "Know which file goes where", f'''
<table><thead><tr><th scope="col">File</th><th scope="col">Who uses it</th></tr></thead><tbody>
<tr><td><code>.zpmod.json</code></td><td>Caller build and inspection. Describes ids, ABI, export signatures and ordinals.</td></tr>
<tr><td><code>.zpmod.relocsim.json</code></td><td>Caller build and inspection. Records the relocation plan and its simulation.</td></tr>
<tr><td><code>.zpmod</code></td><td>Host tooling. Versioned binary with metadata and payload.</td></tr>
<tr><td><code>.zpmod.disk.prg</code></td><td>C64 disk loader. Put it on the D64 under the declared disk filename.</td></tr>
<tr><td><code>.zpmod.diskmanifest.json</code></td><td>Disk packaging, when configured. Describes filenames and payload placement.</td></tr>
</tbody></table>
<p>Exports are ordered from zero. The payload begins with one three-byte <code>JMP</code> per export, so dispatch uses <code>window_base + ordinal * 3</code>. The compiler emits relocation records for known addresses, including full 16-bit operands and separate low and high bytes. The target uses compiled rows and ordinals. It reads the disk payload without parsing the build sidecars. {example_link("examples/small/43_module_rodata_relocs.zp64", "Read-only data relocation demo")} · {doc("abi", "Format and relocation details")}</p>'''),
    ("relocation", "Trace an internal call and a table pointer into RAM", f'''
<p>Read this module with its execution window at <code>$8000</code>. The first jump at <code>$8000</code> dispatches export 0, <code>tick</code>. The second at <code>$8003</code> dispatches export 1, <code>table_ptr</code>. Moving the payload also moves its private <code>bump</code> helper and <code>reloc_table</code>. Code that refers to them needs their new addresses.</p>
{sample("examples/small/45_module_relocation_sim.zp64", "Complete relocation simulation demo")}
<p>Open <code>applied_relocations</code> in the simulation sidecar. The following records show one build. Addresses and offsets can change after recompiling. Follow the target name and kind in your output.</p>
<table><thead><tr><th scope="col">Target</th><th scope="col">Record</th><th scope="col">Bytes before</th><th scope="col">Bytes after</th></tr></thead><tbody>
<tr><td><code>bump</code></td><td><code>abs16</code></td><td><code>96 08</code></td><td><code>06 80</code></td></tr>
<tr><td><code>reloc_table[1]</code></td><td><code>hi8</code></td><td><code>0a</code></td><td><code>82</code></td></tr>
<tr><td><code>reloc_table[1]</code></td><td><code>lo8</code></td><td><code>c8</code></td><td><code>38</code></td></tr>
</tbody></table>
<p>The first pair changes an absolute operand from <code>$0896</code> to <code>$8006</code>. The table records carry an addend of one for the element index. The adjusted address becomes <code>$8238</code>, with the two bytes patched at separate offsets. The simulation shows the patch plan. For a program that actually activates a DLL, use the runtime window demo. Treat a pointer into a shared window as valid only while that DLL remains active there.</p>
{shell("""
mkdir -p build
./zig-out/bin/zp64c compile examples/small/45_module_relocation_sim.zp64 -o build/reloc.prg
python3 -m json.tool build/reloc.prg.zpmod.relocsim.json
""", "Build the module and inspect its relocation records")}
<p>{example_link("examples/small/46_module_runtime_load_window.zp64", "Runtime load and activation example")} · {doc("abi", "Relocation record reference")}</p>'''),
    ("diagnostics", "Tell a build error from an unavailable call", f'''
<table><thead><tr><th scope="col">What you see</th><th scope="col">What to check</th></tr></thead><tbody>
<tr><td>Binding signature rejected</td><td>Match the export name, argument types, and return type. Rebuild stale sidecars. <a href="{blob}tests/fixtures/emu/lang/fail_compile/module_binding_current_signature_mismatch.zp64">Signature mismatch fixture</a></td></tr>
<tr><td>Graph or placement rejected</td><td>Check graph rows and edges, window visibility, reserved ranges, and REU capacity. <a href="{blob}tests/fixtures/emu/lang/fail_compile/zeropage_module_dependency_graph_cycle.zp64">Cycle fixture</a> · <a href="{blob}tests/fixtures/emu/lang/fail_compile/module_state_cache_too_small.zp64">Cache sizing fixture</a></td></tr>
<tr><td><code>load</code> fails or the call returns <code>null</code></td><td>Check REU setup, the disk entry, and whether the row is still loaded. In manual mode, ensure the load succeeded before calling. {module_fixture("module_dependency_call_missing_load", "Call before loading fixture")}</td></tr>
</tbody></table>
<p>Declare your binding in the caller and call it from a supported static-frame context. DLL export implementations use the software-stack convention. The compiler rejects unsupported loader calls within software-stack functions. The standalone fixed-address cache described here also differs from the proposed ReadyOS host-managed cache. {doc("readyos-precog", "ReadyOS integration boundary")}</p>'''),
    ("reuse-producer", "Package the same DLL for two applications", f'''
<p>Build the <code>fixed_math</code> producer once. Its export accepts one byte, adds three, and returns a byte. The score updater acquires it explicitly while the calculator below loads it on demand. The loading policy belongs to each caller's dependency row. Both bind the same export signature and use the same execution window and staging address. Each disk gets the same producer payload under <code>fixedmath</code>.</p>
{sample("docs/tutorial-examples/dll-reuse.zp64", "Complete calculator caller")}
<p>The calculator passes <code>$20</code> and prints <code>BIAS 23</code>. The <a href="guide-memory-plan.html">score updater</a> passes the current round count, adds the result to a far record, and prints <code>MEMORY PLAN OK</code>. The calculator evaluates <code>base()</code> before calling the binding. The preview rejects a nested user call in an argument to a software-stack bridge.</p>
<table><thead><tr><th scope="col">Producer output</th><th scope="col">Used by</th><th scope="col">What it supplies</th></tr></thead><tbody>
<tr><td><code>math.prg.zpmod.json</code></td><td>Both caller builds</td><td>Module ID, ABI, export signatures and ordinals.</td></tr>
<tr><td><code>math.prg.zpmod.relocsim.json</code></td><td>Both caller builds</td><td>Payload size, window and relocation information.</td></tr>
<tr><td><code>math.prg.zpmod.disk.prg</code></td><td>Both D64 images</td><td>The bytes KERNAL loads when the caller asks for <code>fixedmath</code>.</td></tr>
</tbody></table>
<p>Keep these three outputs together. If you change a signature, export order, or window contract, rebuild the caller and replace the disk entry from the matching producer build. Each caller's disk manifest describes packaging names. The calculator's <code>current.file</code> names its own module row. The boot entry is a separate PRG named <code>boot</code> for this exercise, and the calculator only loads its dependency from disk.</p>
{shell("""
mkdir -p build
reuse_build=$(mktemp -d build/dll-reuse.XXXXXX)
compiler=./zig-out/bin/zp64c
"$compiler" compile docs/tutorial-examples/memory-plan-math.zp64 -o "$reuse_build/math.prg"
for caller in dll-reuse memory-plan; do
  "$compiler" compile "docs/tutorial-examples/$caller.zp64" -o "$reuse_build/$caller.prg" \\
    --dependency-module "fixed_math=$reuse_build/math.prg.zpmod.json" \\
    --dependency-relocsim "fixed_math=$reuse_build/math.prg.zpmod.relocsim.json"
  c1541 -format 'fixed math,01' d64 "$reuse_build/$caller.d64" \\
    -write "$reuse_build/$caller.prg" boot \\
    -write "$reuse_build/math.prg.zpmod.disk.prg" fixedmath
done
x64sc -reu -reusize 16384 -autostart "$reuse_build/dll-reuse.d64:boot"
x64sc -reu -reusize 16384 -autostart "$reuse_build/memory-plan.d64:boot"
""", "Build the producer once and boot both callers", "reuse-producer")}
<p>{example_link("docs/tutorial-examples/memory-plan-math.zp64", "Producer source")} · {example_link("docs/tutorial-examples/dll-reuse.zp64", "Calculator source")} · {doc("cli", "Dependency sidecar options")}</p>'''),
    ("window-compatibility", "Use a producer built for a different window", f'''
<p>By default, the caller expects an unassigned dependency's producer window to match its main window in address and size. In the calculator, that is <code>$6000</code> with <code>$1000</code> bytes. Change the producer to <code>$7000</code> with <code>$0800</code> bytes and the default caller rejects its sidecars.</p>
<p>An explicit window assignment enables relocation to that named destination. Add <code>window = main;</code> to the calculator's <code>dependency fixed_math</code> block. The producer's declared window size must fit within the destination window, and the payload and export requirements must fit too. This example boots with the same <code>BIAS 23</code>. Its first jump instruction at <code>$6000</code> points to <code>$6003</code>, inside the caller's window. The producer still uses disk staging at <code>$9000</code>.</p>
{shell(r"""
mkdir -p build
window_build=$(mktemp -d build/window-fit.XXXXXX)
sed 's/at 0x6000 size 0x1000/at 0x7000 size 0x0800/' \
  docs/tutorial-examples/memory-plan-math.zp64 > "$window_build/producer.zp64"
sed '/        file = "fixedmath";/a\
        window = main;
' docs/tutorial-examples/dll-reuse.zp64 > "$window_build/caller.zp64"
compiler=./zig-out/bin/zp64c
"$compiler" compile "$window_build/producer.zp64" -o "$window_build/math.prg"
"$compiler" compile "$window_build/caller.zp64" -o "$window_build/caller.prg" \
  --dependency-module "fixed_math=$window_build/math.prg.zpmod.json" \
  --dependency-relocsim "fixed_math=$window_build/math.prg.zpmod.relocsim.json"
c1541 -format 'assigned window,01' d64 "$window_build/caller.d64" \
  -write "$window_build/caller.prg" boot \
  -write "$window_build/math.prg.zpmod.disk.prg" fixedmath
x64sc -reu -reusize 256 -autostart "$window_build/caller.d64:boot"
""", "Rebuild the producer and assign its execution window", "window-compatibility")}
<p>To see the diagnostic, use the original calculator source with the same new producer sidecars. A valid assignment only resolves the window constraint. The caller still checks the module ID, ABI, export signatures, and bank requirements. {doc("reu-overlays", "Window compatibility reference")} · <a href="#relocation">How the loader patches addresses</a></p>'''),
    ("disk-audit", "Check what actually made it onto the disk", f'''
<p>A successful build proves the binding and the sidecars agree. The disk can still contain an older file under the right name. Starting with the <a href="guide-modules.html#disk">typed disk exercise</a>, list the D64 directory and extract <code>enemyrt</code>. Compare its bytes with the <code>.zpmod.disk.prg</code> generated by the same build. An empty <code>cmp</code> result with exit status zero means the files match. Rebuild the disk from the matching caller and producer outputs if they differ.</p>
{shell("""
c1541 -attach build/dll-tutorial/typed.d64 -list \\
  -read enemyrt build/dll-tutorial/enemyrt-from-disk.prg
cmp build/dll-tutorial/enemyrt-from-disk.prg build/dll-tutorial/typed.prg.zpmod.disk.prg
od -An -tx1 -N5 build/dll-tutorial/enemyrt-from-disk.prg
wc -c build/dll-tutorial/enemyrt-from-disk.prg
""", "Extract and compare the disk payload", "disk-audit")}
<p>The first two bytes of the disk payload in this example are <code>00 90</code>, the little-endian staging address <code>$9000</code>. The next byte, <code>4c</code>, starts the export jump table. One preview build has a 900-byte disk file, which is an 898-byte payload plus the header. Use your build's file size. Fit the payload inside disk staging as well as its execution window and REU slot. The boot PRG and the payload PRG have separate jobs and their bytes differ.</p>
<p>Use the compiler-generated payload and compare it before booting a suspect disk. The runtime uses the caller's compiled length and relocation plan when activating the module. It does not verify that disk bytes match the producer's sidecars. The dependency load path checks the KERNAL result and the returned byte count against its loader limit after KERNAL has written staging RAM. Keep every packaged payload within the reserved staging range. {doc("abi", "Disk, cache, and activation contracts")}</p>'''),
])

guide_page("abi", chapters[8][1], chapters[8][2], [
    ("static", "Static frames and return registers", f'''
<p>Static calls copy arguments into fixed storage owned by the callee. The frame has program lifetime and is not reentrant. Record arguments copy flattened fields. Byte returns use A. Words and near pointers return low byte in A and high byte in X. Static aggregate results use return storage. Inspect the generated labels to follow the argument cells.</p>
{sample("examples/small/26_static_abi_metadata.zp64")}'''),
    ("aggregate-return", "Follow a record through static return storage", f'''
<p>A <code>Reading</code> occupies three bytes. The caller copies its channel and both total bytes into <code>adjust</code>'s parameter cells. The callee adds the delta to its own copy, writes all three result bytes to its return storage, and returns. The caller copies those bytes into <code>first</code> before calling the function again. The second call reuses the callee cells. The first result remains available in the caller.</p>
{sample("docs/tutorial-examples/aggregate-return.zp64")}
{example_run("docs/tutorial-examples/aggregate-return.zp64", "aggregate-return", anchor="aggregate-return")}
<p>Expect the original total <code>12FF</code> and the two new totals <code>1300</code> and <code>1301</code>. Copy the word fields into named <code>u16</code> locals before formatting. In this preview, a direct field argument to <code>{'{x16}'}</code> prints its low byte with a zero high byte. The named word locals pass both bytes.</p>
<p>In the generated assembly, follow <code>adjust_input_channel</code> and <code>adjust_input_total</code> into the function, then <code>adjust_return_channel</code> and <code>adjust_return_total</code> into the caller's result cells. The high byte lives at <code>adjust_return_total+1</code>. A byte or word return would use registers instead of a record return area.</p>
{shell("""
mkdir -p build
./zig-out/bin/zp64c asm docs/tutorial-examples/aggregate-return.zp64 -o build/aggregate-return.asm
""", "Generate assembly for the aggregate call", "aggregate-asm")}
<p>These static cells belong to the function for the life of the program. They are reused on every call, so a recursive or interrupt-driven re-entry can overwrite a live invocation. Use <a href="guide-data.html#ownership">a pointer when the caller wants in-place mutation</a>. For calls through the software stack or DLL ABI, choose supported scalar interfaces. {fixture_link("lang/pass/parity/pointers/pointer_field_widths", "Record copies with two-byte pointer fields")} · {fixture_link("lang/fail_compile/stack_struct_return", "Rejected software-stack record return")}</p>'''),
    ("stack", "A separate stack for recursion", lesson["stack"] + f'''
<p>Configure a stack region in visible RAM. Its software stack and frame pointers use zero-page pairs. The 6510 hardware stack still holds the machine return address and compiler wrapper saves. The stack convention supports the documented scalar/pointer subset and checks frame bounds. Stack overflow traps. Avoid assuming every static-frame feature is available in a stack frame.</p><p>{doc("abi", "Bridge directions, limits, and register contracts")}</p>
<p>Use the mixed-call examples to see when a bridge is needed. Static code can call a stack function and a stack function can call an eligible static helper. The recursive fixture checks the normal path, and an expected-failure fixture exercises a stack bound. {example_link("examples/small/28_static_calls_stack_helper.zp64", "Static caller to stack helper")} · {example_link("examples/small/30_stack_main_calls_static_helper.zp64", "Stack caller to static helper")} · {fixture_link("lang/pass/parity/abi/stack_recursion", "Recursion fixture")} · {fixture_link("lang/fail_runtime/stack_overflow_recursive", "Expected overflow trap")}</p>'''),
    ("stack-limit", "Exercise a stack limit with two nested calls", f'''
<p>Follow <code>main → relay → identity</code>. The nested calls keep both frames and their saved linkage live. After running the program, open the VICE monitor and look for the returned word <code>5a 80</code> at <code>$c100–$c101</code>.</p>
{sample("docs/tutorial-examples/stack-result.zp64")}
{example_run("docs/tutorial-examples/stack-result.zp64", "stack-result", anchor="stack-result")}
<p>Twelve bytes starting at <code>$c8fc</code> give the exclusive end <code>$c908</code>. Reduce the reservation to eleven and set a breakpoint on <code>.zeropage_stack_overflow_trap</code> to observe the rejected call. The hardware stack has its own budget for JSRs, wrapper saves, and interrupts.</p>'''),
    ("frame-trace", "Follow a word argument through a nested call", f'''
<p>Break at <code>.identity</code>. The frame pointer names the active frame and the software stack pointer names its first free byte. The monitor shows <code>08 c9 06 c9</code> at <code>$00f7–$00fa</code>, which means SP is <code>$c908</code> and FP is <code>$c906</code>.</p>
<table><thead><tr><th>Address</th><th>Bytes</th><th>Purpose</th></tr></thead><tbody>
<tr><td><code>$c8fc</code></td><td>00 00</td><td>Unassigned result in main</td></tr>
<tr><td><code>$c8fe</code></td><td>5a 80</td><td>Pending word in main</td></tr>
<tr><td><code>$c900</code></td><td>fc c8</td><td>Saved main frame pointer</td></tr>
<tr><td><code>$c902</code></td><td>5a 80</td><td>Relay argument</td></tr>
<tr><td><code>$c904</code></td><td>02 c9</td><td>Saved relay frame pointer</td></tr>
<tr><td><code>$c906</code></td><td>5a 80</td><td>Identity argument</td></tr>
</tbody></table>
<p>The bridge checks the new end before writing the saved frame pointer or the argument. The end equals the reservation limit and fits. On return, the bridge saves A and X, restores the previous frame, and reloads the return registers. Continue to see the word stored in visible RAM. Read the generated assembly for the build you are sizing, since private frame layout can change with the source.</p>
{shell("""
mkdir -p build
./zig-out/bin/zp64c compile docs/tutorial-examples/stack-result.zp64 -o build/stack-result.prg
awk '$3 == ".identity" {{ print $2 }}' build/stack-result.prg.labels
""", "Build and find the deepest call address", "frame-trace")}'''),
    ("stack-budget", "Measure both stacks on a nested workload", f'''
<p>Both fixtures run the same 48 updates and assert the same final word. Each update calls a second helper while its own frame is live. The static version gives the two helpers fixed storage. The stack version places their arguments and locals in a configured software stack while keeping the entry and loop driver static.</p>
<table><thead><tr><th scope="col">Frame policy</th><th scope="col">PRG bytes</th><th scope="col">Host CPU cycles</th><th scope="col">Peak hardware stack bytes</th><th scope="col">Software stack write extent</th><th scope="col">Software stack reserved</th></tr></thead><tbody>
<tr><td>Static helpers</td><td>290</td><td>16,046</td><td>5</td><td>0</td><td>0</td></tr>
<tr><td>Stack helpers</td><td>540</td><td>38,190</td><td>6</td><td>21 bytes</td><td>256 bytes</td></tr>
</tbody></table>
<p>The write extent is the distance from the software-stack base to the highest byte written, inclusive. Frames can reserve bytes they never write. To check capacity, exercise the deepest call path and include its frame linkage and any compiler-reserved slots. The measured hardware stack is relative to the host runner's starting point. IRQs and firmware activity can add to it on a C64.</p>
<p>Use static frames when calls run to completion without re-entry. A second invocation of the same static function would share argument and local cells. Software-stack frames allow supported recursion and give each call its own cells. They do not make interrupt re-entry into shared runtime helpers safe. Keep interrupt handlers within a separately defined machine contract.</p>
{shell("""
mkdir -p build
ZEROPAGE_EMU_FILTER=optimization_reference/abi_calls/ zig build emu-test > build/abi-calls.log 2>&1
awk '/^host-(stack-)?metrics/ && $2 ~ /nested_(static|stack)/' build/abi-calls.log
""", "Reproduce the nested call measurements", "stack-budget")}
<p>{fixture_link("lang/pass/optimization_reference/abi_calls/nested_static", "Static fixture")} · {fixture_link("lang/pass/optimization_reference/abi_calls/nested_stack", "Stack fixture")} · {fixture_link("lang/pass/optimization_reference/abi_calls/_nested", "Shared workload")} · {doc("testing", "Metric definitions")}</p>'''),
    ("interop", "Resident code, banking, and ReadyOS", f'''
<p>The raw-image entry and named regions also support hosted applications. The ReadyOS Tic-Tac-Toe example enters at <code>$1000</code>, leaves the resident shim's range available, and uses the shim's documented terminal vectors. The sample starts a fresh game on entry. Host-managed REU resources and resume-aware state are future integration work.</p><p>{doc("readyos-precog", "ReadyOS boundary and proposed host adapter")} · {example_link("sampleapps/tictactoe_readyos/readyos_shim.zp64", "Shim source")}</p>'''),
])

layout_fixture = Path("tests/fixtures/emu/lang/pass/parity/comptime/layout_builtins.zp64").read_text()
optional_pointer_fixture = Path("tests/fixtures/emu/lang/pass/parity/optionals/optional_pointers.zp64").read_text()

guide_page("data", "Lay out records and pass them between functions", "Choose a representation, inspect its byte layout, and decide which code owns the data.", [
    ("layout", "Calculate a record's offsets", f'''
<p>Consider a header you want to copy to a buffer or inspect in the monitor. The compiler lays out fields in declaration order and aligns them to one byte. A two-byte field can start at an odd offset. This is the ZeroPage target layout. Use its layout queries when you write code that depends on these offsets.</p>
{block("Header definitions from the layout fixture", layout_fixture.split("const Cell", 1)[1].split("fn headerSize", 1)[0].join(("const Cell", "")))}
<table><thead><tr><th scope="col">Field in Header</th><th scope="col">Offset</th><th scope="col">Size</th></tr></thead><tbody>
<tr><td><code>tag</code></td><td>0</td><td>1</td></tr>
<tr><td><code>word</code></td><td>1</td><td>2</td></tr>
<tr><td><code>cell</code></td><td>3</td><td>1</td></tr>
<tr><td><code>ok</code></td><td>4</td><td>1</td></tr>
</tbody></table>
<p>With <code>tag = 0x07</code>, <code>word = 0x1234</code>, <code>cell = .x</code>, and <code>ok = true</code>, the bytes are <code>07 34 12 01 01</code>. <code>@offsetOf(Nested, "header.word")</code> gives <code>2</code> because the nested header starts at offset 1. A <code>[2]Header</code> occupies 10 bytes and the second record begins at offset 5. The layout fixture checks these sizes and offsets independently of screen I/O.</p>
<p>The <a href="guide-language.html#compile-time">runnable layout example</a> prints the header size and a nested field offset.</p>
<p>{fixture_link("lang/pass/parity/comptime/layout_builtins", "Full layout fixture")} · {doc("abi", "Value representation")}</p>'''),
    ("ownership", "Choose a snapshot or an in-place update", f'''
<p>Imagine saving a snapshot before playing a move. A by-value copy preserves the old board and lets you return a changed record. For a single live game, a pointer makes changes directly to the record the caller owns. Use the value form when an independent snapshot is part of the design. Use the pointer form when the caller wants to observe the mutation.</p>
{paired_examples("Return a changed value", "From the struct value demo", """fn applyMove(game: Game, index: u8, mark: Cell) Game {
    game.board.cells[index] = mark;
    game.history[game.move_count] = index;
    game.move_count = game.move_count + 1;
    return game;
}
""", "Change the caller's record", "From the struct pointer fixture", """fn setCell(board: *Board, index: u8, cell: Cell) void {
    board.cells[index] = cell;
}
""")}
<p>Both forms use the same field and index syntax. A pointer argument here has two bytes. A record argument carries all the flattened fields. Passing a large record by value can increase storage and copy work. Check the assembled output when the difference matters. Bound the runtime index before calling either helper.</p>
<p>{example_link("examples/small/20_struct_value_helpers.zp64", "Snapshot and value-return example")} · {fixture_link("lang/pass/parity/pointers/struct_pointers", "Nested fields and in-place updates")} · <a href="guide-application.html#state">Game state case study</a></p>'''),
    ("pointers", "Distinguish a pointer, an optional pointer, and a pointer field", f'''
<p><code>*Board</code> refers to one record. Field access through that pointer uses <code>board.score</code>. For scalar pointers, <code>ptr.*</code> reads or writes the value. <code>[*]u8</code> is a many-item pointer and <code>ptr[i]</code> indexes it. Supply a valid address and an index in range. A nullable pointer <code>?*Board</code> occupies two bytes, with address zero representing <code>null</code>.</p>
{block("Optional pointer and payload capture", "fn firstCell" + optional_pointer_fixture.split("fn firstCell",1)[1].split("fn bumpFirst",1)[0].rstrip()+"\n")}
<p>The captured <code>*Board</code> can still refer to mutable data. The optional changes whether the address is available. A pointer field embedded in a copied record keeps its two address bytes, and both copies can refer to the same target. A record copy gives you an independent set of fields while pointed-to data can remain shared.</p>
<p>Use <code>@ptrFromInt</code> for supported scalar addresses such as hardware registers. Form a typed struct pointer using <code>&amp;record</code> or the address of a supported nested field. Integer-to-struct casts, volatile struct pointers, and pointer-to-pointer types are outside this subset.</p>
<p>{fixture_link("lang/pass/parity/optionals/optional_pointers", "Optional pointer branches and updates")} · {fixture_link("lang/pass/parity/pointers/pointer_field_widths", "Two-byte pointer fields across copies and calls")}</p>'''),
    ("pointer-copy", "Copy a record that contains an address", f'''
<p>Predict what changes when <code>advance</code> copies a <code>Link</code>. The tag is copied by value. Changing the callee's tag changes the returned record, while the original keeps tag 1. The pointer's two address bytes are also copied by value. Both initially address the same byte at <code>$c150</code>, so incrementing through the copied pointer is visible through the original.</p>
{sample("docs/tutorial-examples/record-alias.zp64")}
{example_run("docs/tutorial-examples/record-alias.zp64", "record-alias", anchor="record-alias")}
<p>Expect <code>TAGS 01 02</code>, <code>SHARED 06 06</code>, then <code>SPLIT 06 0A</code>. Assigning a new address to <code>result.target</code> changes that field only. The next write goes to <code>$c1f0</code>, where the value becomes <code>$0a</code>. The preview accepts an explicit load followed by a store through a single-item pointer, as in <code>target.* = target.* + 1</code>.</p>
<p>If a snapshot needs independent pointed-to bytes, copy the data into storage you own and set the snapshot's pointer to that storage. A by-value record assignment copies the addresses. {fixture_link("lang/pass/parity/pointers/pointer_field_widths", "Host assertions for copied pointer bytes")} · <a href="guide-abi.html#aggregate-return">Trace the aggregate return storage</a></p>'''),
    ("indexed-pointers", "Pass a base address and an index", f'''
<p>A many-item pointer carries a base address, with no array length alongside it. The indexing demo takes the address of the first scalar element, passes through the supported integer conversion, and constructs a many-item pointer. Mutating element 1 through that pointer changes <code>values[1]</code>. Use a fixed array and its <code>.len</code> while you own the table. If you pass a pointer to another function, pass or otherwise establish the available length as part of the function's contract.</p>
{block("From the indexed pointer demo", """var values = [_]u8{ 1, 2, 3, 4 };
const value_ptr: [*]u8 = @ptrFromInt(@intFromPtr(&values[0]));
value_ptr[1] = 0x20;
value_ptr[1] += 0x0a;
value_ptr[2] = value_ptr[1] + 1;
""")}
<p>The demo also passes a many-item volatile pointer to a screen-writing helper. Use a literal target base for hardware and add an index through the pointer operand. Pointer arithmetic, comparison, and slice formation are outside the supported subset. A mutable scalar or a literal-index scalar array element can supply an address. For an indexed update whose index calculation has side effects, the compiler evaluates the index before loading a direct many-item pointer's value. It captures a struct pointer before evaluating an index into one of its array fields. Keep index calculations simple unless the order is part of what you intend to test.</p>
<p>{example_link("examples/small/22_pointer_indexing.zp64", "Runnable local and volatile pointer example")} · {fixture_link("lang/pass/parity/pointers/pending_index_values", "Index evaluation and pending values")} · {doc("language", "Supported pointer forms")}</p>'''),
    ("variants", "Choose a representation for a missing value or a variant", f'''
<p>A scalar optional uses a presence byte followed by its payload. The byte value zero and the absence of a byte are separate cases. A tagged union has a tag and a fixed payload area. Use an optional for a value that may be absent. Use a tagged union for a value whose payload depends on which event or state you received.</p>
{paired_examples("One payload that can be absent", "Optional scalar · example excerpt", """if (maybe_score) |score| {
    c64.console.print("SCORE {x16}\n", .{score});
} else {
    c64.console.print("NO SCORE\n", .{});
}
""", "Payload selected by a tag", "Tagged union · example excerpt", """switch (event) {
    .key => |key| handleKey(key),
    .none => {},
}
""")}
<p>The union payload becomes available inside the matching <code>switch</code> branch. Captures are read-only. Supported union payloads include scalar, enum, pointer, and payloadless alternatives. The far-record API uses a smaller field subset. Use plain fixed-layout fields when a record must also work in a typed REU view.</p>
<p>{fixture_link("lang/pass/parity/optionals/optionals_scalars", "Absent and present scalar values")} · {fixture_link("lang/pass/parity/unions/tagged_unions", "Tagged payload fixtures")} · <a href="guide-reu.html#records">Far-record field rules</a></p>'''),
    ("casts", "Use widths to express intent", f'''
<p>Widen a byte before arithmetic when the result needs to survive a carry out of bit 7. For example, a word made from byte <code>9</code> plus <code>0x0100</code> is <code>0x0109</code>. An explicit type also helps at the boundary between a fixed address and a volatile pointer.</p>
{block("Widening and a target address from the cast demo", """const word: u16 = @as(u16, values[3]) + @as(u16, 0x0100);
const screen: [*]volatile u8 = @ptrFromInt(0x04c0);
""")}
<p>ZeroPage supports fitting literals, unsigned widening, and exact enum or pointer contexts with <code>@as</code>. Its casts cover the documented target subset. Use explicit data conversion when encoding bytes or moving between different record types. Read <code>@offsetOf</code> as a layout query. It gives a byte offset and does not create or validate an address.</p>
<p>{example_link("examples/small/23_as_casts.zp64", "Complete cast and MMIO demo")} · {fixture_link("lang/pass/parity/scalars/as_casts", "Accepted cast cases")} · {fixture_link("lang/fail_compile/as_out_of_range_u8", "Rejected out-of-range literal")}</p>'''),
])

game_path = "sampleapps/tictactoe/tictactoe_idiomatic.zp64"
game_source = Path(game_path).read_text()

def game_excerpt(start, stop):
    return start + game_source.split(start, 1)[1].split(stop, 1)[0].rstrip() + "\n"

guide_page("application", "Read a complete C64 application", "Follow Tic-Tac-Toe from keyboard input to game state, screen RAM, and the compiled program.", [
    ("play", "Run the game and follow one move", f'''
<p>The standalone Tic-Tac-Toe app has two-player and computer-opponent modes. Choose a mode with F1 or F3, move the cursor with the arrow keys, and place a mark with Space or Return. The disk image includes the idiomatic implementation as <code>TICTACTOE</code> and the other standalone variant as <code>CLASSIC</code>.</p>
<p>Follow one move in the source. <code>main</code> waits for a PETSCII key, hands it to <code>handleKey</code>, and renders the updated game. <code>handleKey</code> decides whether the key changes modes, moves the cursor, or attempts a move. This keeps drawing out of the move rules.</p>
{block("Keyboard dispatch from the game", game_excerpt("fn handleKey(", "export fn main"))}
<p>{download("sampleapps/tictactoe/tictactoe.d64", "Download the Tic-Tac-Toe disk")} · {example_link(game_path, "Read the complete standalone application")}</p>
{shell("""
x64sc -autostart sampleapps/tictactoe/tictactoe.d64:tictactoe
""", "Boot the sample disk")}'''),
    ("state", "Keep one mutable record for the game", f'''
<p><code>Board</code> contains nine one-byte enum cells. <code>Game</code> owns that board plus the move list, history, mode, and cursor. The entry point takes <code>&amp;game</code> once and passes <code>*Game</code> to helpers that update the same record. A by-value argument would copy its fields. A pointer also lets the renderer borrow <code>&amp;game.board</code> without copying the history or depending on its layout.</p>
{paired_examples("State layout", "Source declarations", game_excerpt("const Board =", "const win_a"),
           "Mutation through a pointer", "Excerpt from applyMove", """const board: *Board = &game.board;
const turn = game.turn;
const move_count = game.move_count;
board.cells[index] = turn;
game.moves[move_count] = index;
game.move_count = move_count + 1;
""")}
<p>In the complete function, the index must be below nine, the game must still be playing, and the cell must be empty. These checks happen before the write. The moves and history are bounded arrays because the game has a fixed maximum number of moves. Each new snapshot uses word bit masks to hold up to nine positions.</p>
<p>{example_link(game_path, "Read applyMove and recordSnapshot")} · {fixture_link("lang/pass/parity/pointers/struct_pointer_in_place_game", "Fixture checking in-place state changes")}</p>'''),
    ("draw", "Render screen codes and colors", f'''
<p>The renderer passes a screen pointer at <code>$0400</code> and a color RAM pointer at <code>$d800</code> to each cell-drawing call. The same offset selects the character and its color. <code>drawCell</code> writes nine positions for a glyph using the cell and cursor as inputs. Volatile pointers tell the compiler to emit the actual stores.</p>
{block("Render the board with two target pointers", game_excerpt("fn drawBoard(", "fn renderMode"))}
<p>The app uses a short assembly helper for the border and an assembly badge. The helper reads a byte parameter through <code>@color</code> and writes the VIC-II register at <code>$d020</code>. Typed game code and explicit hardware writes can live in the same program.</p>
{block("Border helper from the game", game_excerpt("fn setBorderAsm(", "fn drawAsmBadge"))}
<p><a href="guide-hardware.html">Screen and keyboard chapter</a> · <a href="guide-assembly.html">Assembly operands and preservation</a></p>'''),
    ("test", "Test the rules separately from the display", f'''
<p>The repository includes a host fixture for the game's rules. It checks state transitions and outcomes independently of the keyboard and screen. The standalone sample exercises keyboard input and rendering in VICE. For a new game, isolate rules that can be verified from memory and check the hardware-facing behavior separately.</p>
<p>{fixture_link("lang/pass/integration/tictactoe_core", "Tic-Tac-Toe rules fixture")} · {doc("testing", "Test layers and fixture conventions")}</p>
{shell("""
zig build
mkdir -p build
./zig-out/bin/zp64c compile sampleapps/tictactoe/tictactoe_idiomatic.zp64 -o build/tictactoe.prg
x64sc -autostart build/tictactoe.prg
""", "Compile and run the application from source")}'''),
    ("hosted", "Read the hosted ReadyOS variant", f'''
<p>Both variants initialize a game, read PETSCII input, and render to the C64 screen. The difference starts at the executable boundary. The standalone PRG loads at <code>$0801</code> and its BASIC stub calls the generated entry. The hosted PRG loads and enters at <code>$1000</code>. ReadyOS provides the resident shim and transfers control there. The hosted program's exclusive limit <code>$c600</code> leaves <code>$c600–$c9ff</code> available to the shim.</p>
{block("Hosted image and reserved shim range", Path("sampleapps/tictactoe_readyos/tictactoe_readyos.zp64").read_text().split("memory {", 1)[1].split("const Cell", 1)[0].join(("memory {", "")))}
<p>Pressing Ctrl-B reaches the shim's launcher vector at <code>$c80c</code>. F2 and F4 look for a loaded application and, when one is found, the selection helper stores its logical token at <code>$c820</code>. The handler then jumps through the switch vector at <code>$c80f</code>. The inline terminal jump lets the handler transfer directly without adding a separate helper call. The shim owns the switch and the host's REU cache.</p>
{block("Hosted key dispatch · excerpt", Path("sampleapps/tictactoe_readyos/tictactoe_readyos.zp64").read_text().split("    if (key == 2) {", 1)[1].split("    } else if (key == c64.key.f1)", 1)[0].join(("    if (key == 2) {", "    }\n")))}
<p>To compare the builds, inspect each map's <code>prg.load</code>, <code>prg.entry</code>, and memory region list. The hosted binary needs ReadyOS for the navigation vectors. Test launcher return and application switching under that host. Re-entry at <code>$1000</code> currently starts a fresh game. The ReadyOS design notes describe the remaining work for resume-aware state and host-managed REU allocation.</p>
{shell("""
mkdir -p build
./zig-out/bin/zp64c compile sampleapps/tictactoe/tictactoe_idiomatic.zp64 -o build/tictactoe.prg
./zig-out/bin/zp64c compile sampleapps/tictactoe_readyos/tictactoe_readyos.zp64 -o build/tictactoe-hosted.prg
python3 -m json.tool build/tictactoe-hosted.prg.zpmap.json
""", "Build both variants and inspect the hosted map", "hosted-map")}
<p>{example_link("sampleapps/tictactoe_readyos/tictactoe_readyos.zp64", "Hosted game source")} · {doc("readyos-precog", "ReadyOS integration and ownership")}</p>'''),
])

guide_page("testing", "Test a program on the 6510", "Write assertions about target behavior, then use the right emulator for each question.", [
    ("first", "Start with a rule you can check without a screen", f'''
<p>Take a function that turns input into an output, such as a coordinate conversion or a game rule. Run it through <code>zp64c</code>, assemble the emitted code, and assert the result on the emulated 6510. This checks code generation as well as source semantics. Put pure fixtures under <code>tests/fixtures/emu/lang/pass/</code> and import <code>test6502</code>.</p>
{block("Layout assertions from the target fixture", """const test6502 = @import("test6502");

// Inside main, using Header from the record layout chapter:
test6502.expectEqualU16(1, 5, @sizeOf(Header));
test6502.expectEqualU16(2, 1, @offsetOf(Header, "word"));
test6502.pass();
""")}
<p>The first argument is an assertion id that helps identify a failing check. For values that depend on runtime code, pass the expression or result as the final argument. For instance, the indexed update fixture runs an effectful right-hand call and checks both the resulting array and the number of index evaluations. {fixture_link("lang/pass/parity/arrays_for_switch/compound_index_once", "Effectful indexed update fixture")} · <a href="guide-data.html#layout">Header definition and byte layout</a></p>'''),
    ("negative", "Test rejected source and runtime failures", f'''
<p>Use a compile-fail fixture when a supported build must reject a construct or a bad machine plan. The expected diagnostic directive names the text the runner should find. Use a runtime-fail fixture for a program that compiles but reaches a checked failure on the target, such as software-stack overflow. These check different stages of the program.</p>
{paired_examples("Build rejection", "From the zero-length REU fixture", Path("tests/fixtures/emu/lang/fail_compile/reu_zero_length.zp64").read_text(),
          "Target failure", "From the recursive overflow fixture", Path("tests/fixtures/emu/lang/fail_runtime/stack_overflow_recursive.zp64").read_text())}
<p>For an unavailable resource that the program handles, use a passing fixture that asserts the failure result. The DLL disk-missing case expects an unavailable module and a null call instead of a crash. {fixture_link("lang/pass/parity/abi/module_dependency_on_demand_policy_missing_disk", "Handled missing-disk fixture")}</p>'''),
    ("observe", "Assert the thing that can actually go wrong", f'''
<table><thead><tr><th scope="col">Question</th><th scope="col">What to observe</th><th scope="col">Example</th></tr></thead><tbody>
<tr><td>Did a function compute the right value?</td><td>A typed return or output byte</td><td>{fixture_link("lang/pass/parity/calls/functions", "Function results")}</td></tr>
<tr><td>Did inline assembly leave live registers intact?</td><td>Prime the registers and compare them at block exit</td><td>{fixture_link("lang/pass/parity/strings_asm/inline_asm", "Register preservation")}</td></tr>
<tr><td>Did banked code restore the machine mapping?</td><td>Check the processor port around the call</td><td>{fixture_link("lang/pass/parity/abi/module_kernal_bank_console_trampoline", "KERNAL bank restoration")}</td></tr>
<tr><td>Did the loader use the expected window and cache?</td><td>Check window RAM, REU bytes, and registry state</td><td>{fixture_link("lang/pass/abi/named_regions_arena_dll", "Named arena and DLL regions")}</td></tr>
<tr><td>Did a typed REU update survive a flush?</td><td>Read the far record again after releasing the near view</td><td>{fixture_link("lang/pass/parity/abi/far_reu_materialize_flush", "Far view round trip")}</td></tr>
</tbody></table>
<p>Use the Peddle host runner for these checks. It models the required KERNAL calls and a 16 MiB REU. Use VICE for behavior involving the full C64 environment, such as an interactive keyboard session, disk autostart, or integration with the actual KERNAL.</p>'''),
    ("reproduce", "Run one group of cases and inspect a failure", f'''
<p>Filter the host run by fixture path to check the behavior you're working on. If the compiler rejects a case unexpectedly, read its diagnostic and open the exact source that ran. If it assembles but behaves incorrectly, inspect the generated assembly, symbols, and map before attributing the failure to the source or runtime.</p>
{shell("""
ZEROPAGE_EMU_FILTER='compound_index_once,far_reu_materialize_range' zig build emu-test
""", "Run the indexed-update and far-range fixtures")}
<p>The full end-to-end gate compiles the demos and checks the assembler and disk artifacts. The optional VICE harness exercises the programs with hardware-facing assertions. For a change that affects both lowering and runtime behavior, use the focused fixture during development and the broader gates before publishing. {doc("testing", "Commands, prerequisites, and VICE harness setup")}</p>'''),
])

scratch_policy_fixture = Path("tests/fixtures/emu/lang/pass/optimization_reference/zero_page_oscar64_short_scalar_calls.zp64")

guide_page("verification", chapters[12][1], chapters[12][2], [
    ("artifacts", "Read the generated program", f'''
<p>Use the PRG header for load address, the assembly for actual instructions, the VICE label file for monitor breakpoints, and the map for ownership and addresses. Compare load and run addresses for copied placements. Check the zero-page policy section for actual claims. For DLLs, inspect the relocation simulation beside the binary and disk payload.</p>
{shell("""
mkdir -p build
./zig-out/bin/zp64c asm docs/tutorial-examples/asm-record.zp64 -o build/record.asm
./zig-out/bin/zp64c compile docs/tutorial-examples/asm-record.zp64 -o build/record.prg
""")}
<p>The compiler emits runtime helpers on demand and retains exported entry points, module interfaces, and other required roots. Inspect a representative build before drawing size or cycle conclusions. {doc("optimizations", "Optimizer contracts")}</p>'''),
    ("map", "Read a real map before changing the memory plan", f'''
<p>Use the placement demo to connect declarations to the final image. The map's <code>image</code> object shows a load address of <code>$0801</code> and an entry of <code>$1000</code>. Those addresses differ because the BASIC stub is loaded first and then starts the program at the declared entry.</p>
<table><thead><tr><th scope="col">Map entry</th><th scope="col">How to read it</th></tr></thead><tbody>
<tr><td><code>memory_regions</code></td><td>Reserved C64 and REU address ranges with bank visibility.</td></tr>
<tr><td><code>memory_placements</code></td><td>Load and run ranges for placed code or data. <code>direct</code> has matching addresses. <code>startup_copy</code> has two ranges.</td></tr>
<tr><td><code>sections</code></td><td>Code, writable storage, and read-only data with ownership, addresses, and symbols.</td></tr>
<tr><td><code>zero_page</code></td><td>When configured, shows the allocation policy, actual claims, and restoration scope.</td></tr>
</tbody></table>
<p>For <code>hidden</code>, the run address is <code>$e000</code>. The load address is inside the PRG and can move as code changes. Read the current map for that value. If a placement grows, compare its recorded size to its named region. The compile gate rejects an assembled image that crosses a configured ceiling or claim.</p>
{example_run("examples/small/95_memory_regions_placement.zp64", "placement")}
<p>{fixture_link("lang/pass/abi/custom_raw_image", "Raw entry fixture")} · {fixture_link("lang/pass/abi/startup_copy_kernal_placement", "Startup-copy fixture")} · {doc("memory-model", "Map fields and region ownership")}</p>'''),
    ("tests", "Prove target behavior", lesson["verify"] + f'''
<p>Pure language assertions belong in the host runner. Hardware smoke tests cover screen, KERNAL, banking, and REU. The section-marker gate checks that ownership markers are byte-neutral. For optimization changes, compare generated size and behavior using the same workload and machine assumptions. {doc("testing", "Testing and measurement workflow")}</p>'''),
    ("compare", "Measure size and speed with a fixed workload", f'''
<p>Start by checking that both programs produce the same behavior. Then record the generated PRG size and compare the assembly for the paths that run. A PRG byte count includes the two-byte load header. Resident RAM, configured stack, zero-page claims, and REU allocations are separate costs. A shorter file may still reserve more memory while running.</p>
<p>Use the repeated-greeting sources to compare output strategies. The console example uses built-in output. The buffered variants keep screen state and do bulk writes. A fair comparison must keep the visible work and stopping condition comparable. In a hot loop, check whether a source change removes repeated DMA setup, copies, or bank switches. Record the behavior and the cost that changed.</p>
<p>{example_link("examples/repeated_hello.zp64", "Console greeting")} · {example_link("examples/repeated_hello_buffered_balanced.zp64", "Buffered greeting")} · {doc("testing", "Baseline and measurement workflow")} · {doc("optimizations", "Optimization contracts")}</p>'''),
    ("policy-cost", "Measure what a zero-page policy costs", f'''
<p>Use the short-scalar-call workload to isolate one change. The second source adds the policy below. Both use the same nested calls, argument values, and assertions, including a pointer write that checks evaluation order. The host runner checks the same results before emitting metrics for each successful run.</p>
{block("Policy added to the second source", "".join(scratch_policy_fixture.read_text().splitlines(keepends=True)[1:4]))}
<table><thead><tr><th scope="col">Policy</th><th scope="col">PRG bytes</th><th scope="col">Host CPU cycles</th><th scope="col">Intercepted calls</th></tr></thead><tbody>
<tr><td>Default</td><td>468</td><td>1,483</td><td>9</td></tr>
<tr><td>KERNAL with scratch allocation</td><td>523</td><td>1,586</td><td>9</td></tr>
</tbody></table>
<p>In this preview build the scratch policy adds 55 file bytes and 103 measured cycles. The fixture measures through its pass hook, so it includes entry work and stops before normal-return cleanup. For a tiny workload, the cost of initializing and managing borrowed cells can outweigh cheaper accesses. Read the map and emitted instructions, then measure a workload with the call frequency you expect in your program. Use the lifecycle runner if the cost of cleanup is part of the question.</p>
{shell("""
mkdir -p build
ZEROPAGE_EMU_FILTER=oscar64_short_scalar_calls zig build emu-test > build/short-calls.log 2>&1
awk '/^host-metrics/ && $2 !~ /scalars_oscar64_short_scalar_calls/' build/short-calls.log
""", "Reproduce the two host measurements")}
<p>These counts cover stepped 6510 instructions in the host fixture. Intercepted hooks, VIC-II stalls, and physical drive or REU timing are outside the measurement. {fixture_link("lang/pass/optimization_reference/oscar64_short_scalar_calls", "Default-policy workload")} · {fixture_link("lang/pass/optimization_reference/zero_page_oscar64_short_scalar_calls", "Same workload with scratch allocation")} · {doc("testing", "Metric columns and lifecycle timing")}</p>'''),
    ("context", "How ZeroPage fits among C64 toolchains", '''
<p>Memory regions and overlays have precedents. Oscar64 documents source pragmas for sections and regions and a linker-generated overlay flow. cc65's ld65 documents memory and segment configuration with separate load and run addresses. <a href="https://github.com/drmortalwombat/oscar64/blob/main/oscar64.md">Oscar64 manual</a> · <a href="https://cc65.github.io/doc/ld65.html">ld65 guide</a></p>
<p>ZeroPage's combination is a Zig-shaped target subset with source-declared ownership shared by the PRG, heaps, zero page, placements, and DLL loader. Typed far views expose explicit copies to and from C64 RAM. The DLL loader combines named REU slots, typed exports, relocations, window activation, and explicit ownership in one model.</p>'''),
])

guide_page("memory-plan", chapters[13][1], chapters[13][2], [
    ("task", "Update a score with rules loaded from disk", '''
<p>Keep a score record in REU, materialize it into C64 RAM, call a scoring rule loaded from disk, then flush the update. The initial total is <code>$0200</code> and the round count is 3. The DLL adds 3 to the round count it receives and returns 6 points. The program adds those points to the total and increments the stored round count to 4. A fresh far read checks both changes.</p>
<p>This exercise brings together <a href="guide-arenas.html">arenas</a>, <a href="guide-reu.html#range">materialized views</a>, and <a href="guide-modules.html#disk">typed disk calls</a>. The score record and the DLL both use REU, and each needs its own address range and lifetime.</p>'''),
    ("layout", "Assign a region to each owner", '''
<table><thead><tr><th scope="col">Region</th><th scope="col">Addresses</th><th scope="col">Contents and lifetime</th></tr></thead><tbody>
<tr><td>Execution</td><td>C64 <code>$6000–$6fff</code></td><td>Active DLL code and its jump table. The CPU executes here.</td></tr>
<tr><td>Scratch</td><td>C64 <code>$8000–$80ff</code></td><td>The three-byte near score view, until the edit and flush finish.</td></tr>
<tr><td>Disk staging</td><td>C64 <code>$9000–$97ff</code></td><td>Temporary buffer for the disk payload.</td></tr>
<tr><td>Frames</td><td>C64 <code>$c800–$cbff</code></td><td>Software-stack frames for the scoring export and other stack calls.</td></tr>
<tr><td>Scores</td><td>REU <code>$010000–$0100ff</code></td><td>Application data. The far arena owns the score record until reset.</td></tr>
<tr><td>Cache</td><td>REU <code>$030000–$031fff</code></td><td>Two window-sized payload slots. FixedMath is row 1, so its slot begins at <code>$031000</code>.</td></tr>
</tbody></table>
<p>The ranges in the table include the last byte. The map records exclusive ends. The application reserves the current module's slot at <code>$030000</code> as part of the registry plan. This run uses only the dependency's slot. The scoring export calls through the execution window while the near score remains live in scratch RAM.</p>'''),
    ("producer", "Compile the scoring DLL first", f'''
<p>The producer declares the <code>fixed_math</code> module and its stack-frame export. Its assembly contains a small <code>bias</code> routine. The compiler writes the metadata and relocation sidecars the caller needs and a disk payload with a load header for the configured staging address. The producer's <code>main</code> is empty because the exercise boots the application.</p>
{sample("docs/tutorial-examples/memory-plan-math.zp64")}
<p>{example_link("docs/tutorial-examples/memory-plan-math.zp64", "Complete scoring DLL source")}</p>'''),
    ("caller", "Acquire, call, flush, and release", f'''
<p>The caller declares the same signature in <code>extern module</code> and names the disk entry in its loader. <code>FixedMath.acquire()</code> gives the caller a reference. <code>FixedMath.bias()</code> activates the DLL as needed and returns an optional value. The near edit is committed with <code>flush</code>. Only then does the program reset scratch and read the score again from REU. It releases FixedMath on both paths after successful acquire.</p>
{sample("docs/tutorial-examples/memory-plan.zp64")}
<p>The current module declaration provides the application row and its own export. The app calls <code>roundLimit()</code> directly from resident code for its final check. Only the FixedMath dependency needs a separate disk entry in this exercise.</p>
<p>{example_link("docs/tutorial-examples/memory-plan.zp64", "Complete score application source")}</p>
{shell("""
mkdir -p build
score_build=$(mktemp -d build/score-tutorial.XXXXXX)
compiler=./zig-out/bin/zp64c
"$compiler" compile docs/tutorial-examples/memory-plan-math.zp64 -o "$score_build/math.prg"
"$compiler" compile docs/tutorial-examples/memory-plan.zp64 -o "$score_build/score.prg" \\
  --dependency-module "fixed_math=$score_build/math.prg.zpmod.json" \\
  --dependency-relocsim "fixed_math=$score_build/math.prg.zpmod.relocsim.json"
c1541 -format 'memory plan,01' d64 "$score_build/score.d64" \\
  -write "$score_build/score.prg" boot \\
  -write "$score_build/math.prg.zpmod.disk.prg" fixedmath
x64sc -reu -reusize 16384 -autostart "$score_build/score.d64:boot"
""", "Build both programs, package the disk, and boot", "score-disk")}
<p>Expect <code>MEMORY PLAN OK</code> and a green border. Inspect <code>memory_regions</code> in the caller's <code>.zpmap.json</code> and <code>loader</code> in its <code>.zpmod.json</code> to connect the layout to the generated artifacts.</p>'''),
    ("repair", "Diagnose three failures at the stage that reports them", f'''
<table><thead><tr><th scope="col">Change to try</th><th scope="col">What you observe</th><th scope="col">Repair</th></tr></thead><tbody>
<tr><td>Move <code>score_reu</code> to <code>0x030000</code>.</td><td>The compiler rejects overlapping regions. Application data would occupy the same REU range as the cache.</td><td>Restore the score arena to <code>0x010000</code> and keep raw transfers within the owning region.</td></tr>
<tr><td>Declare <code>FixedMath.bias</code> with a <code>u16</code> parameter in the caller.</td><td>The compiler rejects the dependency sidecar. The caller expects a word and the producer exports a byte argument.</td><td>Restore <code>u8</code>, or change and rebuild both sides together. Check module id, ABI, and window if the same diagnostic persists.</td></tr>
<tr><td>Build a second disk with only the <code>boot</code> entry.</td><td>The app boots, acquire fails, and the screen shows <code>MEMORY PLAN FAILED</code> with a red border.</td><td>Write the producer's <code>.zpmod.disk.prg</code> under <code>fixedmath</code> and boot again with the REU enabled.</td></tr>
</tbody></table>
{shell("""
c1541 -format 'missing dll,02' d64 "$score_build/missing.d64" \\
  -write "$score_build/score.prg" boot
x64sc -reu -reusize 16384 -autostart "$score_build/missing.d64:boot"
""", "Boot a disk without the scoring DLL", "missing-score-dll")}
<p>The missing-disk command uses the <code>score_build</code> variable from the build command. Use the same shell. If you open a new shell, set it to the directory created by <code>mktemp</code>.</p>
<p>{fixture_link("lang/pass/abi/named_regions_arena_dll", "Host fixture checking the arena and DLL byte locations")} · {fixture_link("lang/fail_compile/zeropage_module_loader_reu_heap_overlap", "Compile-fail fixture for a cache overlap")} · <a href="guide-module-lifecycle.html#diagnostics">DLL diagnostics</a></p>'''),
])

guide_page("tutorial-reu", "Edit one page of a map in REU", "Use a small C64 buffer to edit a table that is larger than the buffer.", [
    ("plan", "Work out the two memory budgets", '''
<p>Each sector contains one byte of terrain, one byte of flags, a two-byte visit counter, and four tile bytes. Forty sectors need 320 bytes of REU. A page of four sectors needs 32 bytes of C64 RAM. Keep those allocations separate so you can reuse the C64 buffer for the next page.</p>
<p><a href="tutorial.html#far-memory">Back to the main tutorial</a> · <a href="guide-reu.html#capacity">Choose an REU capacity</a></p>'''),
    ("edit", "Read, edit, and flush one page", f'''
<p>The program initializes all forty sectors, then selects sectors 36 through 39. Local index zero is far index 36. Update visits and flags in the near view, and pass the original start to <code>flushRange</code> so the result goes back to the right place. Reset scratch once the near view is out of use.</p>
{sample("docs/tutorial-examples/reu-map-sectors.zp64")}
{example_run("docs/tutorial-examples/reu-map-sectors.zp64", "tutorial-reu-map", True, anchor="run-map")}
<p>Expect <code>MAP SECTORS OK</code>. The result comes from a fresh far read after the flush. Sector zero is checked as well because it is outside the edited page.</p>'''),
    ("experiment", "Try two changes that make the page unavailable", '''
<ol><li>Change the requested start from 36 to 37. The four-sector page would cross the end of the view.</li>
<li>Restore start 36 and change the C64 scratch reservation from 32 bytes to 31. The page fits the far view but cannot fit in scratch.</li></ol>
<p>Both changes produce <code>MAP SECTORS FAILED</code>. Restore both values and rerun before continuing. The <a href="guide-reu.html#range-failure">REU guide</a> shows how an application can report the two causes separately. Continue to <a href="tutorial-dll.html">load executable code from disk</a>.</p>'''),
], False)

guide_page("tutorial-dll", "Build and call a disk-loaded DLL", "Follow one export from source declaration to a disk payload and a running C64 call.", [
    ("export", "Start with a function whose result you can predict", '''
<p>The border export takes one byte and adds two. Passing 3 should produce 5, the green border value. A stack-frame function implements that signature. The module declaration gives it the public name <code>border</code>. The disk entry <code>enemyrt</code> carries the payload, and <code>enemy_runtime</code> identifies the module in source.</p>
<p><a href="tutorial.html#disk-modules">Back to the main tutorial</a></p>'''),
    ("call", "Read the complete load and call sequence", f'''
<div class="disk-call-comparison">
{paired_examples("Named invocation", "Complete main from the disk demo",
    "export fn main" + disk_named.split("export fn main", 1)[1],
    "Typed invocation", "Complete main from the typed demo",
    "export fn main" + disk_typed.split("export fn main", 1)[1])}
</div>
<p>In each version, handle the load result before calling. Then unwrap the optional export result. The typed version declares the export signature with <code>extern module</code>. The named version supplies the export name and an argument tuple at the call site. The <a href="guide-modules.html#disk">disk chapter</a> shows the shared configuration, typed binding, and both complete files.</p>'''),
    ("run", "Build the disk and check both outcomes", f'''
<p>Put the boot PRG and the generated DLL payload on the same D64. The payload file ends in <code>.zpmod.disk.prg</code>. Give that entry the name <code>enemyrt</code> so it matches the load call. Start VICE with an REU enabled. The loader stages the disk bytes in visible RAM, caches the payload in REU, and activates it in the C64 execution window.</p>
{shell(r"""
mkdir -p build
out=$(mktemp -d build/first-dll.XXXXXX)
./zig-out/bin/zp64c compile docs/tutorial-examples/dll-disk-typed.zp64 -o "$out/boot.prg"
c1541 -format 'first dll,01' d64 "$out/with-dll.d64" \
  -write "$out/boot.prg" boot -write "$out/boot.prg.zpmod.disk.prg" enemyrt
c1541 -format 'missing dll,02' d64 "$out/without-dll.d64" -write "$out/boot.prg" boot
x64sc -reu -reusize 16384 -autostart "$out/with-dll.d64:boot"
x64sc -reu -reusize 16384 -autostart "$out/without-dll.d64:boot"
""", "Build and boot both disk images", "run-dll")}
<p>Expect <code>REAL LOAD OK</code> with the payload present and <code>REAL LOAD FAIL</code> when it is missing. Next, try the <a href="guide-memory-plan.html">score updater</a>, which combines a separately built DLL with an application-owned REU table.</p>'''),
], False)
