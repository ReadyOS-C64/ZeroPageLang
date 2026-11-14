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

def shell(source, title="Build and run"):
    code = block("Terminal", dedent(source).strip() + "\n", "shell")
    return f'<details class="terminal"><summary>{escape(title)}</summary>{code}</details>'

def write_reading_page(path, html):
    commands = []
    def move_commands(match):
        title, code = match.groups()
        number = len(commands) + 1
        anchor = f"commands-{number}"
        commands.append(
            f'<section id="{anchor}"><h2>{title}</h2>{code}'
            f'<p><a href="{path.name}#{anchor}">Return to the guide</a></p></section>'
        )
        return f'<p id="{anchor}" class="command-link"><a href="{path.stem}-commands.html#{anchor}">{title}</a></p>'

    if path.name == "setup.html":
        path.write_text(re.sub(r'<details class="terminal"><summary>(.*?)</summary>(.*?)</details>', r'\2', html, flags=re.S))
        return
    reading = re.sub(r'<details class="terminal"><summary>(.*?)</summary>(.*?)</details>', move_commands, html, flags=re.S)
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
    links = (("index.html#examples", "Examples"), ("index.html#c64", "C64 features"),
             ("tutorial.html", "Intro"), ("guide.html", "Full guide"), ("setup.html", "Setup"), (repo, "GitHub"))
    nav = "".join(f'<a href="{url}"' + (' aria-current="page"' if name == active else '') + f'>{name}</a>' for url, name in links)
    return f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="{escape(desc)}">
<title>{escape(title)}</title>
<link rel="stylesheet" href="site/style.css?v=command-pages">
<script src="site/copy.js" defer></script>
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
    ("hardware", "Talk to the hardware"),
    ("memory", "Plan the memory layout"),
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

lesson["next"] = """
<p>The full guide continues with types, inline assembly, memory maps, arenas, REU records, DLL caching, and target verification. Each chapter links runnable examples and explains the limits that matter on a 6510.</p>
<p><a class="button primary" href="guide.html">Open the full guide</a> <a class="button" href="setup.html">Install and build</a></p>"""
sections = "".join(f'<section id="{anchor}"><h2>{title}</h2>{lesson[anchor]}</section>' for anchor,title in lessons)
tutorial = f'''
<main id="main" class="wrap guide">
  <aside aria-label="Tutorial contents"><h3>On this page</h3><ol class="toc">{toc}</ol></aside>
  <article>
    <h1>ZeroPage introduction</h1>
    <p class="lead">Read a first program, then follow the language into the C64 hardware and memory model. <a href="setup.html">Install and build</a> when you are ready to run the examples.</p>
    {sections}
  </article>
</main>'''
write_reading_page(Path("docs/tutorial.html"), page("ZeroPage · Language introduction", "A short language-first introduction to ZeroPage for the Commodore 64.", "Intro", tutorial))

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
]

def chapter_sections(items):
    return "".join(f'<section id="{anchor}"><h2>{heading}</h2>{body}</section>' for anchor, heading, body in items)

def guide_page(slug, title, lead, items, chapters_nav=True):
    local = "".join(f'<li><a href="#{anchor}">{heading}</a></li>' for anchor, heading, _ in items)
    contents = f'<h3>On this page</h3><ul class="toc">{local}</ul>'
    footer = ""
    if chapters_nav:
        chapter_links = "".join(f'<li><a href="guide-{name}.html"' + (' aria-current="page"' if name == slug else '') + f'>{i}. {heading}</a></li>' for i, (name, heading, _) in enumerate(chapters, 1))
        contents += f'<h3 class="chapter-label"><a href="guide.html">All chapters</a></h3><ol class="toc">{chapter_links}</ol>'
        if slug != "guide":
            i = [name for name, _, _ in chapters].index(slug)
            prev = "guide.html" if i == 0 else f"guide-{chapters[i-1][0]}.html"
            next_link = "guide.html" if i+1 == len(chapters) else f"guide-{chapters[i+1][0]}.html"
            prev_label = "Guide contents" if i == 0 else chapters[i-1][1]
            next_label = "Guide contents" if i+1 == len(chapters) else chapters[i+1][1]
            footer = f'<nav class="chapter-nav" aria-label="Chapter navigation"><a href="{prev}">← {prev_label}</a><a href="{next_link}">{next_label} →</a></nav>'
    main = f'<main id="main" class="wrap guide"><aside aria-label="Guide navigation">{contents}</aside><article><h1>{title}</h1><p class="lead">{lead}</p>{chapter_sections(items)}{footer}</article></main>'
    file = "setup.html" if slug == "setup" else "guide.html" if slug == "guide" else f"guide-{slug}.html"
    write_reading_page(Path("docs",file), page(f"{title} · ZeroPage", lead, "Setup" if slug == "setup" else "Full guide", main))

def example_link(path, title="Open the complete source"):
    target = path.removeprefix("docs/") if path.startswith("docs/tutorial-examples/") else blob + path
    return f'<a href="{target}">{title}</a>'

def example_run(path, name, reu=False):
    flags = " -reu -reusize 16384" if reu else ""
    return f'<p>{example_link(path)}</p>' + shell(f"mkdir -p build\n./zig-out/bin/zp64c compile {path} -o build/{name}.prg\nx64sc{flags} -autostart build/{name}.prg", "Build and run this example")

guide_page("setup", "Install and build ZeroPage", "Set up the host compiler and build a C64 program from a fresh checkout.", [
    ("tools", "Install the tools", lesson["install"]),
    ("compile", "Compile and run", lesson["hello"]),
    ("gates", "Set up the test tools", lesson["verify"]),
], False)

toc_cards = "".join(f'<article><h3><a href="guide-{name}.html">{i}. {title}</a></h3><p>{lead}</p></article>' for i,(name,title,lead) in enumerate(chapters,1))
guide_page("guide", "The ZeroPage programming guide", "A guide to writing ZeroPage programs, from typed values and C64 hardware to a complete game and relocatable DLLs.", [
    ("chapters", "Chapters", f'<div class="grid">{toc_cards}</div>'),
    ("approach", "How to follow the guide", '<p>Start with <a href="guide-language.html">types and control flow</a> if you are learning the language. Follow <a href="guide-hardware.html">screen and keyboard I/O</a> into the <a href="guide-application.html">Tic-Tac-Toe case study</a> to see those choices in an application. For memory-intensive projects, read <a href="guide-memory.html">memory placement</a> before <a href="guide-arenas.html">arenas</a> and <a href="guide-reu.html">REU views</a>. The <a href="guide-modules.html">DLL walkthrough</a> starts with one call and works up to a shared execution window.</p><p>Code labelled as an excerpt shows part of a program. Complete source links let you read the surrounding declarations and run the example. Build and run links open commands on a separate page. The <a href="setup.html">setup page</a> collects tool installation.</p>'),
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
    ("flow", "Branches, loops, and indexes", lesson["language"] + '''
<p><code>and</code> and <code>or</code> short-circuit. <code>switch</code> accepts scalar selectors, supported ranges, and optional or tagged-union payloads. <code>for</code> walks fixed arrays or zero-based fixed ranges. Array payloads are read-only copies. Literal out-of-range indexes fail compilation. Guard runtime indexes in application code.</p>'''),
    ("effects", "Predict what happens when expressions have side effects", f'''
<p>An indexed compound update first evaluates the index once and reads the old value. It evaluates the right-hand expression next, then stores the result to the captured destination. The fixture below makes both sides observable. The right-hand call writes <code>55</code> to the destination, but the update still adds to the original <code>5</code> and stores <code>60</code>. The assertion on <code>count</code> verifies a single index evaluation.</p>
{block("From the indexed update fixture", """values[index(&count)] += nested(&log, &values[0]);
test6502.expectEqualU16(1, 60, values[0]);
test6502.expectEqualU16(2, 20, values[1]);
test6502.expectEqualU8(3, 1, count);
""")}
<p>{fixture_link("lang/pass/parity/arrays_for_switch/compound_index_once", "Full indexed update fixture")} · {fixture_link("lang/pass/parity/control/block_expressions", "Labeled blocks and expression results")}</p>'''),
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
    ("sum-types", "Enums, optionals, and tagged unions", f'''
<p>An <code>enum(u8)</code> has byte tags. A scalar optional stores presence and payload. A supported pointer optional uses address zero for null. Narrow tagged unions select a payload through a <code>switch</code> capture. This demo models a small event instead of passing a tag and value separately.</p>
{sample("examples/small/24_optional_union_event.zp64")}'''),
    ("imports", "Share code and tables within one program", f'''
<p>Put reusable declarations in a local source file and use its import alias from the caller. The compiler can include read-only tables from an imported file and refer to them through the same alias. These tables are built into the program, so they have no loader or disk lifecycle. If the feature instead needs its own load window and export ABI, use the module chapter.</p>
{paired_examples("Asset file", "Excerpt from the imported data fixture", Path("tests/fixtures/emu/lang/pass/parity/modules/_rodata_assets.zp64").read_text(),
          "Caller", "Fixture reading imported data", Path("tests/fixtures/emu/lang/pass/parity/modules/rodata_imports.zp64").read_text())}
<p>{fixture_link("lang/pass/parity/modules/rodata_imports", "Read-only import fixture")} · {example_link("examples/small/29_module_rodata_assets.zp64", "Runnable read-only import demo")} · <a href="guide-modules.html">DLL walkthrough</a></p>'''),
    ("boundary", "Syntax and target limits", f'''
<p>Zig's AST validates ordinary syntax before ZeroPage lowers its target subset. ZeroPage adds machine declarations and <code>asm {{ ... }}</code>. It gives <code>callconv</code> and <code>linksection</code> target-specific meanings. Valid Zig can receive a ZeroPage diagnostic for constructs such as slices, floating point, division, generics, error unions, or general <code>comptime</code>.</p><p>{doc("language", "Language reference")} · {doc("zig-reference-notes", "Pinned Zig behavior")}</p>'''),
])

guide_page("hardware", chapters[1][1], chapters[1][2], [
    ("screen", "Screen RAM, color, and VIC-II", f'''
<p><code>c64.screen</code> writes the default screen at <code>$0400</code> and color RAM. Screen codes represent glyphs on screen. <code>c64.console</code> accepts text and manages a cursor, newlines, and scrolling. <code>c64.vic.border</code> maps to <code>$d020</code>. For other registers, use a volatile pointer and the register's hardware contract.</p>
{sample("examples/small/21_pointer_mmio.zp64")}
<p>Use <code>ptr.*</code> for a single-item pointer and <code>ptr[i]</code> for a many-item pointer. Volatile reads and writes reach the device. When your program banks memory or changes VIC-II screen configuration, check the assumptions of built-in helpers.</p>'''),
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
<p><code>readPetscii()</code> returns zero when the buffer is empty. <code>waitPetscii()</code> waits for a press and release. <code>c64.key</code> provides named keys. <code>c64.time.sleepTicks</code> and <code>sleepFrames</code> busy-wait. Use KERNAL calls with the appropriate ROM mapping and system workspace.</p>
{sample("examples/small/14_keyboard_input.zp64")}
<p>{doc("api", "Complete C64 API")}</p>'''),
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
    ("check-state", "Read an actual register preservation test", f'''
<p>The host runner can set registers before entering a block and sample them afterward. This excerpt starts with A, X, Y, and P set to known values. The block changes each register, plus carry and overflow. The assertions check the restored registers and selected flags. The mask in <code>expectP</code> selects which status bits to compare.</p>
{block("From the inline assembly fixture", Path("tests/fixtures/emu/lang/pass/parity/strings_asm/inline_asm.zp64").read_text().split("    test6502.primeRegs(15,",1)[1].split("    test6502.primeRegs(20,",1)[0].join(("    test6502.primeRegs(15,", "")).strip() + "\n")}
<p>{fixture_link("lang/pass/parity/strings_asm/inline_asm", "Full fixture including a KERNAL call and parameter mutation")} · {fixture_link("lang/fail_compile/inline_asm_buffer_len_immediate", "Rejected immediate buffer length")}</p>'''),
    ("control", "External calls, terminal jumps, and rejected forms", f'''
<p>External <code>jsr</code> accepts a numeric address or an assembler-resolved symbol and must return with the hardware stack balanced. Local <code>jsr</code>, inline <code>rts</code>/<code>rti</code>/<code>brk</code>, and stack manipulation such as <code>pha</code> or <code>txs</code> are rejected. Keep directives, includes, macros, and data declarations outside the inline form. Use a static-frame function. Stack frames and DLL exports have stricter body rules.</p>
{block("ReadyOS terminal transfer · requires the resident shim", "asm {\n    jmp $c80c\n}\n")}
<p>This single-instruction absolute block transfers to a documented resident vector and bypasses normal ZeroPage return. Supply the machine state required by the vector. Prepare required memory in ZeroPage. A preceding normal block restores registers and flags at fallthrough. Indirect jumps, external symbolic jumps, and additional instructions in the terminal block are rejected.</p>
<p>{doc("inline-assembler", "Complete Markdown reference")} · {example_link("sampleapps/tictactoe_readyos/readyos_shim.zp64", "ReadyOS shim calls")}</p>'''),
])

guide_page("memory", chapters[3][1], chapters[3][2], [
    ("image", "Choose an image and entry point", lesson["memory"] + f'''
<p>A default PRG loads at <code>$0801</code> and supplies a BASIC startup line. A raw image uses <code>basic_stub = false</code> and needs an external caller or emulator to enter the declared address. The <code>address_limit</code> is exclusive. A directly loaded distant segment can pad a contiguous PRG. A startup copy keeps the load image compact while giving the code or data a fixed run address. {doc("memory-model", "Image rules")}</p>'''),
    ("regions", "Declare and claim regions", f'''
<p>A region names a physical address range, its address space, and C64 bank visibility where relevant. The compiler validates bounds, overlap, expected space and bank, and claims against the assembled resident image. A region has one reservation role. The same map can describe arenas, pools, a software stack, fixed code, and DLL windows or staging.</p>
<p>Current resident placement supports static functions and constant strings or arrays. Bank gateways expose RAM under ROM, make the call, and restore the processor mapping. KERNAL-dependent calls require particular care when KERNAL is hidden. A banked table belongs with the code that can access it. {doc("abi", "Entry and placement gateways")}</p>'''),
    ("zero-page", "Own zero-page bytes explicitly", f'''
{block("Application zero-page policy · excerpt", Path("docs/language.md").read_text().split("## Application zero-page settings")[1].split("```zig\n")[1].split("```")[0])}
<p>The compatibility profile retains the default pointer and frame conventions. The BASIC profile preserves system workspace. The KERNAL profile can borrow BASIC workspace while retaining documented KERNAL services. Bare mode requires a raw image and a caller that already owns interrupts and ROM policy.</p>
<p><code>range</code> defines candidate bytes and <code>reserve</code> subtracts fixed application claims. Reserve bytes used through literal pointers or assembly. With <code>.scratch</code> or <code>.scalars</code>, allocation still depends on eligibility, space, and proof. The map lists what was actually allocated or spilled. Normal return can restore borrowed bytes. Reset and forced warmstart do not run that cleanup. DLL loader programs currently use the compatibility policy. {doc("memory-model", "Zero-page profiles, IRQ/NMI, and restoration")}</p>
<h3>Read a map before counting bytes</h3>
<p>Candidate ranges describe what the compiler may consider. Actual claims show where it allocated pointer pairs, scratch, and eligible parameters. Reserved bytes belong to the application. A spill stays in ordinary RAM. Under the KERNAL profile, restoration on normal return covers the system bytes the compiler borrowed. When assembly writes reserved bytes, your code owns their lifetime and any restoration.</p>
<p>The stack can use explicitly admitted pointer pairs. In the lifecycle fixture, the stack pointer is at <code>$30/$31</code> and the frame pointer at <code>$32/$33</code>. The test seeds zero page before entry and checks cleanup after the real return. Running only <code>main</code> would skip that entry and exit contract. {example_link("tests/fixtures/optimization/zero_page_lifecycle_stack.zp64", "Stack-pointer configuration fixture")} · {example_link("scripts/verify_zero_page_lifecycle.py", "Entry and exit verification")}</p>
<p>To see the difference in a real program, compare the <a href="{blob}tests/fixtures/optimization/zero_page_scalar_reserved.zp64">fixture that reserves two application bytes</a> and the compiler's reported allocations. Explicit reservations let assembly and generated code coexist, while optional scalar allocation depends on what the compiler can prove. {fixture_link("lang/fail_compile/zero_page_protected_kernal", "Rejected claim on KERNAL workspace")}</p>'''),
])

guide_page("arenas", chapters[4][1], chapters[4][2], [
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
<p>A literal range outside the far view is a build error. With a runtime start, a range beyond the view returns <code>null</code>. Running out of space in the near arena also returns <code>null</code>. Keep the success capture around any editing and flush operations. The host fixture distinguishes the two failures by first testing a bad runtime start, then requesting a valid range after consuming the arena's space.</p>
{block("Runtime range and exhaustion assertions", """var bad_start: u8 = 5;
const bad = enemies.materializeRange(near_heap, bad_start, 2);
test6502.expectNull(11, bad);

const oom = enemies.materializeRange(near_heap, 0, 2);
test6502.expectNull(12, oom);
""")}
<p>{fixture_link("lang/pass/parity/abi/far_reu_materialize_range", "Full fixture with runtime starts, flush, and failure cases")} · {fixture_link("lang/fail_compile/far_view_materialize_range_end_oob", "Compile-time range rejection")} · {fixture_link("lang/fail_compile/far_view_materialize_range_fixed_heap", "Why a fixed-block pool is not a materialization arena")}</p>'''),
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
{paired_examples("Named invocation", "Complete main from the disk demo",
    "export fn main" + disk_named.split("export fn main", 1)[1],
    "Typed invocation", "Complete main from the typed demo",
    "export fn main" + disk_typed.split("export fn main", 1)[1])}
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
    ("ownership", "Keep a module callable while callers still need it", f'''
<p>Loading establishes residency and its initial reference. Repeating an ensure-load leaves the reference count alone. For a dependency, a successful <code>acquire()</code> or <code>acquireGraph()</code> takes a reference, including when the payload is already loaded. Pair those calls with <code>release()</code> or <code>releaseGraph()</code>. Releasing the final reference clears callability. This is separate from a window swap, which can displace a DLL while its references and cached payload remain valid.</p>
{paired_examples("Two owners take references", "Typed graph ownership fixture · excerpt", """test6502.expectEqualBool(1, true, MathCore.acquireGraph());
test6502.expectEqualBool(2, true, MathCore.acquireGraph());
MathCore.releaseGraph();
// MathCore still has an owner.
""", "The last owner releases", "Typed graph ownership fixture · excerpt", """MathCore.releaseGraph();
test6502.expectEqualBool(7, false, ZeroPage.module.isLoaded("math_core"));
test6502.expectNull(8, MathCore.add(3));
""")}
<p>The fixture calls the module between the two releases and gets a value. After the final release it gets <code>null</code>, even though bytes may remain in the REU and window. It then acquires the graph again and calls successfully. These <code>test6502</code> statements are assertions for the host runner. {module_fixture("module_typed_dependency_graph_ownership", "Full ownership fixture")} · {module_fixture("module_dependency_graph_refcount", "Repeated ensure-load fixture")} · {module_fixture("module_disk_reload_matrix", "Unload and reload with byte, bool, and word exports")}</p>'''),
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
""", "Check a missing dependency", "Host fixture · assertions", """test6502.expectNull(2, MathCore.add(3));
test6502.expectEqualBool(3, false, ZeroPage.module.isLoaded("math_core"));
test6502.expectEqualBool(4, false, ZeroPage.module.isLoaded("fixed_math"));
""")}
<p>Loading a graph makes its modules available in REU. It does not invoke their exports. To call a transitive module such as <code>FixedMath</code>, declare its binding and provide its sidecars at build time. A typed transitive binding can call its exports after a direct dependency loads the graph. It cannot independently acquire that transitive graph through the same binding.</p>
<p>{example_link("examples/small/74_module_dependency_graph_on_demand_policy.zp64", "On-demand graph demo")} · {example_link("examples/small/75_module_dependency_graph_preload_policy.zp64", "Preload graph demo")} · {module_fixture("module_dependency_graph_on_demand_policy_missing_disk", "Rollback when disk load fails")} · {module_fixture("module_typed_graph_node_binding", "Call a typed transitive dependency")}</p>'''),
    ("banks", "Choose a visible window or RAM under ROM", f'''
<p>A visible RAM window is the easiest place to start. If you need more visible RAM for the main program, put the window under BASIC or KERNAL ROM. The range must fit entirely within the selected bank. The loader restores the processor port after the banked operation.</p>
{paired_examples("Under BASIC ROM", "Region inside memory", """region module_window: c64 at 0xa000 size 0x0800
    bank .ram_under_basic;
""", "Under KERNAL ROM", "Region inside memory", """region module_window: c64 at 0xe000 size 0x0800
    bank .ram_under_kernal;
""")}
<p>The KERNAL path also preserves processor status and masks IRQs while KERNAL is hidden. Keep these exports independent of KERNAL services. ZeroPage supports a resident trampoline for supported console calls. Keyboard, raw KERNAL, disk, and unsupported inline assembly paths are rejected for this bank. Use a visible window when the export needs those services.</p>
<p>{example_link("examples/small/87_module_current_basic_bank.zp64", "BASIC-bank demo")} · {example_link("examples/small/90_module_current_kernal_bank.zp64", "KERNAL-bank demo")} · {example_link("examples/small/93_module_kernal_console_trampoline.zp64", "Console trampoline demo")} · {module_fixture("module_kernal_bank_console_trampoline", "Fixture checking that $0001 is restored")}</p>'''),
    ("state", "Choose which state survives activation", f'''
<p>When a new DLL takes a window, the loader copies a fresh image over the old contents. Use <code>persist_in_reu</code> for selected state bytes that must survive. The state offset is relative to the start of the execution window. For state at <code>$c100</code> in a <code>$c000</code> window, the offset is <code>$0100</code>. Use <code>discard_on_unload</code> when an unload should discard that row's state. These policies are mutually exclusive for a row.</p>
{block("Keep two bytes across activations · configuration excerpt", """current {
    persist_in_reu at 0x0100 size 2;
}
""")}
<p>Persistent ranges are saved separately from the payload before replacement or final unload and restored after copy and relocation. They consume REU capacity. The compiler checks bounds, overlap, and available cache space. {example_link("examples/small/66_module_state_runtime.zp64", "Write two bytes, unload, clear the window, and reload")} · {doc("reu-overlays", "State and cache reservations")}</p>'''),
    ("artifacts", "Know which file goes where", f'''
<table><thead><tr><th scope="col">File</th><th scope="col">Who uses it</th></tr></thead><tbody>
<tr><td><code>.zpmod.json</code></td><td>Caller build and inspection. Describes ids, ABI, export signatures and ordinals.</td></tr>
<tr><td><code>.zpmod.relocsim.json</code></td><td>Caller build and inspection. Records the relocation plan and its simulation.</td></tr>
<tr><td><code>.zpmod</code></td><td>Host tooling. Versioned binary with metadata and payload.</td></tr>
<tr><td><code>.zpmod.disk.prg</code></td><td>C64 disk loader. Put it on the D64 under the declared disk filename.</td></tr>
<tr><td><code>.zpmod.diskmanifest.json</code></td><td>Disk packaging, when configured. Describes filenames and payload placement.</td></tr>
</tbody></table>
<p>Exports are ordered from zero. The payload begins with one three-byte <code>JMP</code> per export, so dispatch uses <code>window_base + ordinal * 3</code>. The compiler emits relocation records for known addresses, including full 16-bit operands and separate low and high bytes. The target uses compiled rows and ordinals. It reads the disk payload without parsing the build sidecars. {example_link("examples/small/43_module_rodata_relocs.zp64", "Read-only data relocation demo")} · {doc("abi", "Format and relocation details")}</p>'''),
    ("diagnostics", "Tell a build error from an unavailable call", f'''
<table><thead><tr><th scope="col">What you see</th><th scope="col">What to check</th></tr></thead><tbody>
<tr><td>Binding signature rejected</td><td>Match the export name, argument types, and return type. Rebuild stale sidecars. <a href="{blob}tests/fixtures/emu/lang/fail_compile/module_binding_current_signature_mismatch.zp64">Signature mismatch fixture</a></td></tr>
<tr><td>Graph or placement rejected</td><td>Check graph rows and edges, window visibility, reserved ranges, and REU capacity. <a href="{blob}tests/fixtures/emu/lang/fail_compile/zeropage_module_dependency_graph_cycle.zp64">Cycle fixture</a> · <a href="{blob}tests/fixtures/emu/lang/fail_compile/module_state_cache_too_small.zp64">Cache sizing fixture</a></td></tr>
<tr><td><code>load</code> fails or the call returns <code>null</code></td><td>Check REU setup, the disk entry, and whether the row is still loaded. In manual mode, ensure the load succeeded before calling. {module_fixture("module_dependency_call_missing_load", "Call before loading fixture")}</td></tr>
</tbody></table>
<p>Declare your binding in the caller and call it from a supported static-frame context. DLL export implementations use the software-stack convention. The compiler rejects unsupported loader calls within software-stack functions. The standalone fixed-address cache described here also differs from the proposed ReadyOS host-managed cache. {doc("readyos-precog", "ReadyOS integration boundary")}</p>'''),
])

guide_page("abi", chapters[8][1], chapters[8][2], [
    ("static", "Static frames and return registers", f'''
<p>Static calls copy arguments into fixed storage owned by the callee. The frame has program lifetime and is not reentrant. Record arguments copy flattened fields. Byte returns use A. Words and near pointers return low byte in A and high byte in X. Static aggregate results use return storage. Inspect the generated labels to follow the argument cells.</p>
{sample("examples/small/26_static_abi_metadata.zp64")}'''),
    ("stack", "A separate stack for recursion", lesson["stack"] + f'''
<p>Configure a stack region in visible RAM. Its software stack and frame pointers use zero-page pairs. The 6510 hardware stack still holds the machine return address and compiler wrapper saves. The stack convention supports the documented scalar/pointer subset and checks frame bounds. Stack overflow traps. Avoid assuming every static-frame feature is available in a stack frame.</p><p>{doc("abi", "Bridge directions, limits, and register contracts")}</p>
<p>Use the mixed-call examples to see when a bridge is needed. Static code can call a stack function and a stack function can call an eligible static helper. The recursive fixture checks the normal path, and an expected-failure fixture exercises a stack bound. {example_link("examples/small/28_static_calls_stack_helper.zp64", "Static caller to stack helper")} · {example_link("examples/small/30_stack_main_calls_static_helper.zp64", "Stack caller to static helper")} · {fixture_link("lang/pass/parity/abi/stack_recursion", "Recursion fixture")} · {fixture_link("lang/fail_runtime/stack_overflow_recursive", "Expected overflow trap")}</p>'''),
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
{block("Queries from the layout fixture", """test6502.expectEqualU16(8, 5, @sizeOf(Header));
test6502.expectEqualU16(13, 1, @alignOf(Header));
test6502.expectEqualU16(17, 10, @sizeOf([2]Header));
test6502.expectEqualU16(25, 2, @offsetOf(Nested, "header.word"));
""")}
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
<p>The repository includes a host fixture for the game's rules. It checks state transitions and outcomes using <code>test6502</code>. The standalone sample exercises keyboard input and rendering in VICE. For a new game, isolate rules that can be verified from memory and check the hardware-facing behavior separately.</p>
<p>{fixture_link("lang/pass/integration/tictactoe_core", "Tic-Tac-Toe rules fixture")} · {doc("testing", "Test layers and fixture conventions")}</p>
{shell("""
zig build
mkdir -p build
./zig-out/bin/zp64c compile sampleapps/tictactoe/tictactoe_idiomatic.zp64 -o build/tictactoe.prg
x64sc -autostart build/tictactoe.prg
""", "Compile and run the application from source")}'''),
    ("hosted", "Read the hosted ReadyOS variant", f'''
<p>The standalone app begins from a BASIC stub. The ReadyOS variant uses a raw PRG at <code>$1000</code> and transfers through documented resident shim vectors when switching apps or returning to the launcher. Its memory map must respect the shim's reserved range. It currently initializes the game on entry. The ReadyOS design notes describe the remaining work for resume-aware state and host-managed REU allocation.</p>
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
    ("context", "How ZeroPage fits among C64 toolchains", '''
<p>Memory regions and overlays have precedents. Oscar64 documents source pragmas for sections and regions and a linker-generated overlay flow. cc65's ld65 documents memory and segment configuration with separate load and run addresses. <a href="https://github.com/drmortalwombat/oscar64/blob/main/oscar64.md">Oscar64 manual</a> · <a href="https://cc65.github.io/doc/ld65.html">ld65 guide</a></p>
<p>ZeroPage's combination is a Zig-shaped target subset with source-declared ownership shared by the PRG, heaps, zero page, placements, and DLL loader. Typed far views expose explicit copies to and from C64 RAM. The DLL loader combines named REU slots, typed exports, relocations, window activation, and explicit ownership in one model.</p>'''),
])
