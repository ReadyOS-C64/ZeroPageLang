#!/usr/bin/env python3
"""Compile and inspect repeated-greeting artifacts. Never execute target code."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/repeated_hello_comparison'


def resolve(env, name):
    explicit = os.environ.get(env)
    candidates = [explicit] if explicit else []
    candidates += [str(ROOT.parent / 'zeropage-tooling/bin' / name), shutil.which(name)]
    for path in candidates:
        if path and Path(path).is_file() and os.access(path, os.X_OK):
            return path
    raise SystemExit(f'Missing {name}; configure {env}.')


def run(args):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise SystemExit(f'Command failed ({result.returncode}): {args}\n{result.stdout}')
    return result.stdout.strip()


def prg(name):
    path = OUT / (name + '.prg')
    data = path.read_bytes()
    assert len(data) > 2
    load = int.from_bytes(data[:2], 'little')
    assert load == 0x0801
    return data, load, load + len(data) - 2


def cc65_segments(key='cc65'):
    text = (OUT / (key + '.map')).read_text()
    block = text.split('Segment list:')[1].split('Exports list by name:')[0]
    segments = {}
    for name, start, end, size in re.findall(
            r'^(\w+)\s+([0-9A-F]{6})\s+([0-9A-F]{6})\s+([0-9A-F]{6})', block, re.M):
        segments[name] = (int(start, 16), int(end, 16) + 1, int(size, 16))
    return segments


def outside_image(start, end, load, image_end):
    """BSS can overlap discardable startup bytes; do not count it twice."""
    return max(0, end - start - max(0, min(end, image_end) - max(start, load)))


def asm_instructions(source):
    """Count handwritten source mnemonics, not generated CPU instructions."""
    return [line.strip() for block in re.findall(r'\basm\s*\{(.*?)\}', source, re.S)
            for line in block.splitlines()
            if line.strip() and not line.strip().endswith(':')
            and not line.lstrip().startswith('//')]


def main():
    os.chdir(ROOT)
    OUT.mkdir(parents=True, exist_ok=True)
    zig = resolve('ZEROPAGE_ZIG', 'zig')
    cl65 = resolve('ZEROPAGE_CL65', 'cl65')
    oscar = resolve('ZEROPAGE_OSCAR64', 'oscar64')
    run([zig, 'build'])
    zp64c = ROOT / 'zig-out/bin/zp64c'
    for source, output in [('repeated_hello.zp64', 'zeropage_console'),
                           ('repeated_hello_buffered.zp64', 'zeropage_buffered'),
                           ('repeated_hello_buffered_highlevel.zp64', 'zeropage_buffered_highlevel'),
                           ('repeated_hello_buffered_balanced.zp64', 'zeropage_buffered_balanced')]:
        run([zp64c, 'compile', ROOT / 'examples' / source, '-o', OUT / (output + '.prg')])
    c_source = ROOT / 'examples/comparison/repeated_hello.c'
    buffered_source = ROOT / 'examples/comparison/repeated_hello_buffered.c'
    for suffix, source in [('', c_source), ('_buffered', buffered_source)]:
        # Stage assembly in build/ so cl65 leaves no objects beside the source.
        cc_key, oscar_key = 'cc65' + suffix, 'oscar64' + suffix
        run([cl65, '-t', 'c64', '-O', '--codesize', '100', '--standard', 'c99', '-g',
             '-S', '-o', OUT / (cc_key + '.s'), source])
        run([cl65, '-t', 'c64', '-g', '-m', OUT / (cc_key + '.map'),
             '-Ln', OUT / (cc_key + '.labels'), '-o', OUT / (cc_key + '.prg'),
             OUT / (cc_key + '.s')])
        oscar_log = run([oscar, '-n', '-Os', '-tm=c64', '-tf=prg', '-g', '-v',
                         '-o=' + str(OUT / (oscar_key + '.prg')), source])
    idiomatic_source = ROOT / 'examples/comparison/repeated_hello_buffered_oscar64.c'
    run([oscar, '-n', '-Os', '-tm=c64', '-tf=prg', '-g', '-v',
         '-o=' + str(OUT / 'oscar64_buffered_idiomatic.prg'), idiomatic_source])

    # A differently named import must still produce identical executable bytes.
    alias_source = (ROOT / 'examples/repeated_hello_buffered.zp64').read_text()
    alias_source = re.sub(r'\bdisplay\.', 'page.', alias_source.replace('const display =', 'const page ='))
    alias_source = alias_source.replace('"micromodules/repeated_hello_display.zp64"',
                                       '"../../examples/micromodules/repeated_hello_display.zp64"')
    (OUT / 'alias_check.zp64').write_text(alias_source)
    run([zp64c, 'compile', OUT / 'alias_check.zp64', '-o', OUT / 'alias_check.prg'])
    assert (OUT / 'alias_check.prg').read_bytes() == (OUT / 'zeropage_buffered.prg').read_bytes()
    highlevel = ROOT / 'examples/repeated_hello_buffered_highlevel.zp64'
    alias = re.sub(r'\bdisplay\.', 'page.', highlevel.read_text().replace('const display =', 'const page ='))
    alias = alias.replace('"micromodules/', '"../../examples/micromodules/')
    (OUT / 'alias_check_highlevel.zp64').write_text(alias)
    run([zp64c, 'compile', OUT / 'alias_check_highlevel.zp64', '-o', OUT / 'alias_check_highlevel.prg'])
    assert (OUT / 'alias_check_highlevel.prg').read_bytes() == (OUT / 'zeropage_buffered_highlevel.prg').read_bytes()
    balanced = ROOT / 'examples/repeated_hello_buffered_balanced.zp64'
    alias = re.sub(r'\bdisplay\.', 'page.', balanced.read_text().replace('const display =', 'const page ='))
    alias = alias.replace('"micromodules/', '"../../examples/micromodules/')
    (OUT / 'alias_check_balanced.zp64').write_text(alias)
    run([zp64c, 'compile', OUT / 'alias_check_balanced.zp64', '-o', OUT / 'alias_check_balanced.prg'])
    assert (OUT / 'alias_check_balanced.prg').read_bytes() == (OUT / 'zeropage_buffered_balanced.prg').read_bytes()
    highlevel_module = ROOT / 'examples/micromodules/repeated_hello_display_highlevel.zp64'
    highlevel_asm = asm_instructions(highlevel_module.read_text())
    original_asm = asm_instructions((ROOT / 'examples/micromodules/repeated_hello_display.zp64').read_text())
    assert 0 < len(highlevel_asm) < len(original_asm) / 10
    balanced_asm = asm_instructions((ROOT / 'examples/micromodules/repeated_hello_display_balanced.zp64').read_text())
    assert len(highlevel_asm) < len(balanced_asm) < len(original_asm)

    rows = []
    for key, label, zp, buffers in [
            ('zeropage_console', 'ZeroPage console', 4, 1000),
            ('zeropage_buffered', 'ZeroPage buffered module', 14, 3024),
            ('zeropage_buffered_highlevel', 'ZeroPage mostly high-level module', 6, 3024),
            ('zeropage_buffered_balanced', 'ZeroPage balanced module', 7, 3024)]:
        data, load, end = prg(key)
        mapping = json.loads((OUT / (key + '.prg.zpmap.json')).read_text())
        assert mapping['prg']['bytes'] == len(data)
        assert mapping['prg']['load'] == load
        assert end < 0x2400
        if key == 'zeropage_buffered':
            assembly = (OUT / (key + '.prg.asm')).read_text()
            direct = {int(n,16) for n in re.findall(r'^\s+\w+ \$([0-9a-f]{2})(?![0-9a-f])', assembly, re.M)}
            assert direct == set(range(0x20,0x29)) | {0x30,0x32,0x33,0x34,0x35}, direct
            for address in ('$2800,x', '$2900,x', '$2a00,x', '$2b00,x', '$d018'):
                assert address in assembly
            assert 'sta ($22),y' in assembly
        if key == 'zeropage_buffered_highlevel':
            assembly = (OUT / (key + '.prg.asm')).read_text()
            assert not re.search(r'^\s+\w+ .*zeropage_string_(?:src_|dst_)?ptr', assembly, re.M)
            assert 'lda ($20),y' in assembly and 'sta ($22),y' in assembly
        if key == 'zeropage_buffered_balanced':
            assembly = (OUT / (key + '.prg.asm')).read_text()
            assert not re.search(r'^\s+\w+ .*zeropage_string_(?:src_|dst_)?ptr', assembly, re.M)
            direct = {int(n,16) for n in re.findall(r'^\s+\w+ \$([0-9a-f]{2})(?![0-9a-f])', assembly, re.M)}
            assert direct == {0x20,0x21,0x22,0x23,0x30}, direct
        rows.append(dict(key=key, name=label, prg=len(data), image=len(data)-2,
                         extra_bss=0, zp=zp, display=buffers,
                         resident=len(data)-2+zp+buffers, stack_budget=0,
                         status='Compiled here', sha256=hashlib.sha256(data).hexdigest()))
        if key.startswith('zeropage_buffered'):
            suffix = key.removeprefix('zeropage_buffered')
            module = ROOT / f'examples/micromodules/repeated_hello_display{suffix}.zp64'
            driver = ROOT / f'examples/repeated_hello_buffered{suffix}.zp64'
            rows[-1]['module_asm_instructions'] = len(asm_instructions(module.read_text()))
            rows[-1]['driver_asm_instructions'] = len(asm_instructions(driver.read_text()))

    for buffered in (False, True):
        key = 'cc65_buffered' if buffered else 'cc65'
        display = 3024 if buffered else 1000
        data, load, end = prg(key)
        segments = cc65_segments(key)
        bss = segments['BSS']
        extra = outside_image(bss[0], bss[1], load, end)
        zp = segments['ZEROPAGE'][2]
        assert zp == 26
        cc65_map = (OUT / (key + '.map')).read_text()
        stack_budget = int(re.search(r'__STACKSIZE__\s+([0-9A-F]{6})', cc65_map)[1], 16)
        assert segments['ONCE'][1] == end
        assert end < 0x2400 and bss[1] < 0x2400
        if not buffered: assert extra == 0
        if not buffered: assert b'HELLO, WORLD!' in data
        if buffered:
            assembly = (OUT / (key + '.s')).read_text().lower()
            assert b'\x48\x05\x0c\x0c\x0f\x2c\x20\x57\x0f\x12\x0c\x04\x21' in data
            assert re.search(r'\bld[axy]\s+\$dc0d', assembly)
            assert re.search(r'\bjmp\s+\$fe66', assembly)
            assert '_copy_page' in assembly and 'sta     (ptr1),y' in assembly
            assert bss[2] == 4
        rows.append(dict(key=key, name='cc65 buffered -O' if buffered else 'cc65 -O', prg=len(data), image=len(data)-2,
                         extra_bss=extra, zp=zp, display=display,
                         resident=len(data)-2+extra+zp+display, stack_budget=stack_budget,
                         status='Compiled here', sha256=hashlib.sha256(data).hexdigest()))

    for key, label in [('oscar64', 'Oscar64 -Os'),
                       ('oscar64_buffered', 'Oscar64 portable buffered -Os'),
                       ('oscar64_buffered_idiomatic', 'Oscar64 idiomatic buffered -Os')]:
        buffered = key != 'oscar64'
        idiomatic = key == 'oscar64_buffered_idiomatic'
        display = 3024 if buffered else 1000
        data, load, end = prg(key)
        omap = (OUT / (key + '.map')).read_text()
        bss_start, bss_end = re.search(r'^([0-9a-f]+) - ([0-9a-f]+) : BSS, bss$', omap, re.M).groups()
        stack_start, stack_end = re.search(r'^([0-9a-f]+) - ([0-9a-f]+) : STACK, stack$', omap, re.M).groups()
        stack_budget = int(stack_end,16) - int(stack_start,16)
        extra = outside_image(int(bss_start,16), int(bss_end,16), load, end)
        asm = (OUT / (key + '.asm')).read_text()
        # Oscar's pseudo-register scratch is omitted from the map's ZEROPAGE section.
        # Count fixed compiler scratch operands from the native listing, including
        # both bytes of indirect pointers. Exclude BASIC repair workspace on return.
        zp_set = set()
        for line in asm.splitlines():
            match = re.match(r'^[0-9a-f]{4} : (?:[0-9a-f]{2}|__) (?:[0-9a-f]{2}|__) (?:[0-9a-f]{2}|__) (\w+) (.*)', line)
            if not match:
                continue
            operand = match[2]
            if operand.startswith('#'):
                continue
            for addr in re.findall(r'\$([0-9a-f]{2})(?![0-9a-f])', operand.split(';')[0]):
                value = int(addr,16)
                if value not in (0, 0x13, 0x16, 0x54):
                    zp_set.add(value)
                    if '(' in operand:
                        zp_set.add((value+1) & 255)
            # The listing names register operands symbolically after the opcode.
            opbytes = line.split(':',1)[1].strip().split()[:3]
            if opbytes[0] in ('85','86','84','a5','a6','a4','c6','e6'):
                value = int(opbytes[1],16)
                if value not in (0x13,0x16,0x54): zp_set.add(value)
            if opbytes[0] in ('91','b1'):
                value = int(opbytes[1],16)
                zp_set.update((value,value+1))
        assert end < 0x2400 and int(bss_end,16) < 0x2400
        if not buffered:
            assert zp_set == {0x19,0x1a,0x1b,0x1c,0x23,0x24,0x43,0x44}, zp_set
            assert extra == 2 and b'HELLO, WORLD!' in data
        else:
            expected = {0x19,0x1a,0x1b,0x1f,0x20,0x23,0x24,
                        0x43,0x44,0x45,0x46,0x47,0x48}
            if idiomatic:
                expected |= set(range(0x0d,0x13)) | {0x49}
            assert zp_set == expected, zp_set
            assert extra == 4
            assert b'\x48\x05\x0c\x0c\x0f\x2c\x20\x57\x0f\x12\x0c\x04\x21' in data
            assert 'LDA $dc0d' in asm and 'JMP $fe66' in asm
            if idiomatic:
                assert 'LDA (P2),y' in asm and 'STA (P0),y' in asm
                assert re.search(r' : memcpy, NATIVE_CODE:code$', omap, re.M)
                assert 'BIT $d011' in asm and 'STA $dd00' in asm
            else:
                assert 'LDA (T1 + 0),y' in asm and 'STA (T0 + 0),y' in asm
            # Native application frames allocate no software-stack bytes.
            for start, finish in re.findall(r'^([0-9a-f]+) - ([0-9a-f]+) : SSTACK, .+@stack$', omap, re.M):
                assert start == finish
        rows.append(dict(key=key, name=label, prg=len(data), image=len(data)-2,
                         extra_bss=extra, zp=len(zp_set), zp_addresses=sorted(zp_set), display=display,
                         resident=len(data)-2+extra+len(zp_set)+display, stack_budget=stack_budget,
                         status='Compiled here', sha256=hashlib.sha256(data).hexdigest()))

    # Reference values remain explicitly distinct from our locally built samples.
    references = [dict(name='Handwritten ASM', prg=522, resident=520+19+3024,
                       status='Gist file size; RAM reconstructed from source', stack_budget=0),
                  dict(name='Adder', prg=2895, resident=5083,
                       status='Gist-reported; RAM accounting unverified', stack_budget=None)]
    for row in rows + references:
        row['ram_with_stack_budget'] = (row['resident'] + row['stack_budget']
                                        if row['stack_budget'] is not None else None)
    payload = dict(
        method='Compile and static inspection only; no target code was executed.',
        resident_definition='Loaded image union extra BSS + compiler/application ZP scratch + display RAM. Excludes shared system workspace, hardware stack, color RAM, unused heap and software-stack capacity.',
        color_ram_cells=1000,
        software_stack_note='Stock linker budgets, not measured use: cc65 2048 B, Oscar64 4096 B. Capacity is not measured usage.',
        versions=dict(cc65=run([cl65,'--version']), oscar64=oscar_log.splitlines()[0],
                      zig=run([zig,'version'])),
        flags=dict(cc65='-t c64 -O --codesize 100 --standard c99',
                   oscar64='-n -Os -tm=c64 -tf=prg'),
        buffered_source_sha256=hashlib.sha256(buffered_source.read_bytes()).hexdigest(),
        idiomatic_source_sha256=hashlib.sha256(idiomatic_source.read_bytes()).hexdigest(),
        source_sha256=hashlib.sha256(c_source.read_bytes()).hexdigest(),
        rows=rows, references=references,
        reference_url='https://gist.github.com/dylan/d69fe4defda1456b4d2cb0f13c393b73/')
    (OUT / 'results.json').write_text(json.dumps(payload, indent=2)+'\n')
    table = '| Version | PRG bytes | Resident RAM bytes* | Stack budget** | RAM incl. stack budget |\n| --- | ---: | ---: | ---: | ---: |\n'
    for row in rows + references:
        budget = '?' if row['stack_budget'] is None else f"{row['stack_budget']:,}"
        total = '?' if row['ram_with_stack_budget'] is None else f"{row['ram_with_stack_budget']:,}"
        table += f"| {row['name']} | {row['prg']:,} | {row['resident']:,} | {budget} | {total} |\n"
    (OUT / 'results.md').write_text(table+'\n*'+payload['resident_definition']+'\n\n**'+payload['software_stack_note']+'\n')
    print(table)
    print('Static artifact checks passed, including imported-module alias independence. No target execution.')


if __name__ == '__main__':
    main()
