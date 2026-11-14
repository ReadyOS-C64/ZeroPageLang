#!/usr/bin/env python3
"""Differential source-level Peddle proof for constant record strides.

Uses precompiled PRGs only. Production binary-mode sweeps keep their original
layout. A separate, explicitly labelled probe gives both compilations identical
private-frame RAM addresses for ambient-decimal integration checks; decimal ADC
of relocated frame bases is otherwise a pre-existing layout-dependent behavior.
No compiler installation, build/emu writes or competitor measurements occur.
"""
import argparse
import ctypes as c
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

from verify_pointer_reuse import Image
from verify_runtime_loop_pages import bind
from verify_oscar64_workloads import run_fixture

ROOT = Path(__file__).resolve().parent.parent
FACTORS = (3, 4, 5, 9)
WIDTHS = {3: (2,), 4: (2, 1), 5: (2, 2), 9: (2, 2, 2, 2)}
BOUNDARIES = (0, 1, 9, 10, 15, 99, 127, 128, 153, 255, 256, 257,
              0x7fff, 0x8000, 0x80ff, 0xff00, 0xffff)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def tool(explicit, env, sibling, fallback):
    if explicit:
        return [str(explicit)]
    if os.environ.get(env):
        return shlex.split(os.environ[env])
    local = ROOT.parent / 'zeropage-tooling' / 'bin' / sibling
    if local.exists():
        return [str(local)]
    found = shutil.which(fallback)
    if not found:
        raise RuntimeError(f'{env} or {fallback} is required')
    return [found]


def normalized_frames(path, output, assembler):
    """Retain emitted instructions but give source frames identical RAM labels."""
    text = Path(str(path) + '.asm').read_text()
    addresses = {f'record{factor}': 0x5000 + number * 0x200 for number, factor in enumerate(FACTORS)}
    active = None
    lines = []
    for raw in text.splitlines(keepends=True):
        line = raw.strip()
        begin = re.fullmatch(r'; zeropage_section_begin owner=function:(\w+) kind=static_frame.*', line)
        end = re.fullmatch(r'; zeropage_section_end owner=function:(\w+) kind=static_frame', line)
        if begin and begin[1] in addresses:
            assert active is None
            active = begin[1]
            lines.append(raw)
            lines.append(f'.logical ${addresses[active]:04x}\n')
        elif end and end[1] == active:
            lines.append('.here\n')
            lines.append(raw)
            active = None
        else:
            lines.append(raw)
    assert active is None
    output.parent.mkdir(parents=True, exist_ok=True)
    assembly = Path(str(output) + '.asm')
    assembly.write_text(''.join(lines))
    command = assembler + ['-q', '--cbm-prg', '--vice-labels', '-l', str(output) + '.labels', '-o', str(output), str(assembly)]
    result = subprocess.run(command, capture_output=True, text=True)
    Path(str(output) + '.assemble.log').write_text(result.stdout + result.stderr)
    assert result.returncode == 0, (command, result.stderr)
    metadata = json.loads(Path(str(path) + '.zpmap.json').read_text())
    metadata['prg']['path'] = str(output)
    metadata['prg']['bytes'] = output.stat().st_size
    for section in metadata['sections']:
        if section['kind'] == 'static_frame' and section['owner'].startswith('function:'):
            name = section['owner'].removeprefix('function:')
            if name in addresses:
                section['start'] = addresses[name]
                section['end'] = addresses[name] + section['size']
    metadata['native_probe'] = 'Private static-frame run addresses normalized for decimal equivalence only; no whole-C64 or PRG-startup claim.'
    Path(str(output) + '.zpmap.json').write_text(json.dumps(metadata, indent=2) + '\n')
    return output


def bulk_reader(work_dir, library):
    """Optional tiny native loop avoids hundreds of Python FFI calls per frame."""
    source = work_dir / 'read_frame.c'
    source.write_text('''#include <stdint.h>
#include <stddef.h>
typedef struct ZeroPagePeddle ZeroPagePeddle;
typedef uint8_t (*Reader)(const ZeroPagePeddle *, uint16_t);
void zp_stride_read_frame(const ZeroPagePeddle *machine, uint16_t address, uint8_t *out, size_t length, Reader read_byte) {
    for (size_t i = 0; i < length; ++i) out[i] = read_byte(machine, (uint16_t)(address + i));
}
''')
    extension = '.dylib' if sys.platform == 'darwin' else '.so'
    output = work_dir / ('read_frame' + extension)
    try:
        compiler = tool(None, 'ZEROPAGE_CC', 'clang', 'cc')
        flags = ['-dynamiclib'] if sys.platform == 'darwin' else ['-shared', '-fPIC']
        environment = dict(os.environ)
        if sys.platform == 'darwin' and 'DEVELOPER_DIR' not in environment and Path('/Library/Developer/CommandLineTools').is_dir():
            environment['DEVELOPER_DIR'] = '/Library/Developer/CommandLineTools'
        result = subprocess.run(compiler + flags + ['-O2', str(source), '-o', str(output)], env=environment, capture_output=True, text=True)
        (work_dir / 'read_frame.log').write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(result.stderr)
        bridge = c.CDLL(str(output.resolve()))
        read = bridge.zp_stride_read_frame
        read.argtypes = [c.c_void_p, c.c_uint16, c.POINTER(c.c_uint8), c.c_size_t, c.c_void_p]
        read.restype = None
        native_read = c.cast(getattr(library, 'zeropage_peddle_read'), c.c_void_p)
        def frame(im, start, size):
            data = (c.c_uint8 * size)()
            read(im.machine, start, data, size, native_read)
            return bytes(data)
        return frame, 'native C ABI read loop'
    except (OSError, RuntimeError):
        return lambda im, start, size: bytes(im.read(im.machine, address) for address in range(start, start + size)), 'Python C ABI read loop'


def oracle(factor, value, index):
    selected = index & 7
    original_tag = 10 + selected * 7
    tag = (original_tag + 3) ^ 0x5a
    final = ((((value + original_tag + 3) & 65535) ^ 0x55aa) + value) & 65535
    rows = bytearray()
    for number in range(8):
        for field, width in enumerate(WIDTHS[factor]):
            data = (0x1000 + number * 257) if field == 0 else (13 + number) if width == 1 else ((field + 1) * 0x1000 + number * (17 + field))
            if number == selected and field == 0:
                data = final
            rows.extend(data.to_bytes(width, 'little'))
        rows.append(tag if number == selected else 10 + number * 7)
    return (2 * (final + tag)) & 65535, rows


def verify(args):
    args.work_dir.mkdir(parents=True, exist_ok=True)
    library = c.CDLL(str(args.library.resolve()))
    assembler = tool(args.assembler, 'ZEROPAGE_64TASS', '64tass', '64tass')
    paths = (args.before.resolve(), args.after.resolve())
    normalized_paths = tuple(normalized_frames(path, args.work_dir / (phase + '-normalized.prg'), assembler)
                             for phase, path in zip(('before', 'after'), paths))
    production = [Image(library, path) for path in paths]
    normalized = [Image(library, path) for path in normalized_paths]
    images = production + normalized
    frames = {im: {frame['owner'].removeprefix('function:'): frame for frame in im.frames} for im in images}
    read_frame, read_mode = bulk_reader(args.work_dir, library)
    load = bind(library, 'load', [c.c_void_p, c.c_uint16, c.POINTER(c.c_uint8), c.c_size_t])
    seeds = {}
    totals = {}
    fixture_rows = []
    decimal_probe = []

    def seed_frame(im, function, seed):
        frame = frames[im][function]
        size = frame['end'] - frame['start']
        key = (size, seed & 255)
        if key not in seeds:
            seeds[key] = (c.c_uint8 * size)(*((offset * 29 + (seed & 255) * 17 + 3) & 255 for offset in range(size)))
        load(im.machine, frame['start'], seeds[key], size)
        return frame

    def check(pair, factor, value, index, flags, scope):
        function = f'record{factor}'
        decimal = bool(flags & 8)
        results, contents = [], []
        for im in pair:
            frame = seed_frame(im, function, value >> 8)
            outside = (frame['start'] - 2, frame['start'] - 1, frame['end'], frame['end'] + 1)
            canaries = bytes(im.read(im.machine, addr) for addr in outside)
            result = im.call(function, {'value': (value, 2), 'index': (index, 2)}, {}, flags, decimal)
            assert bytes(im.read(im.machine, addr) for addr in outside) == canaries, (scope, function, value, index, flags, 'adjacent canary changed')
            results.append(result)
            contents.append(read_frame(im, frame['start'], frame['end'] - frame['start']))
        assert results[0][1:] == results[1][1:], (scope, function, value, index, flags, 'CPU/pointer state mismatch', results[0][1:], results[1][1:])
        assert contents[0] == contents[1], (scope, function, value, index, flags, 'complete current-frame mismatch')
        if not decimal:
            expected, expected_rows = oracle(factor, value, index)
            r = results[1][0]
            assert r.a | (r.x << 8) == expected, (scope, function, value, index, flags, 'return oracle', r.a | (r.x << 8), expected)
            for im, observed in zip(pair, contents):
                frame = frames[im][function]
                start = im.labels[function + '_rows'] - frame['start']
                assert observed[start:start + len(expected_rows)] == expected_rows, (scope, function, value, index, 'row/field oracle')
                guard = im.labels[function + '_guard'] - frame['start']
                assert observed[guard:guard + 128] == bytes(128), (scope, function, 'binary guard')
        row = totals.setdefault(scope + ':' + function, dict(cases=0, decimal_cases=0, before_cycles=0, after_cycles=0,
                                                           before_instructions=0, after_instructions=0, slower_cases=0))
        row['cases'] += 1
        row['decimal_cases'] += decimal
        for phase, result in zip(('before', 'after'), results):
            row[phase + '_cycles'] += result[0].cycles
            row[phase + '_instructions'] += result[0].instructions
        row['slower_cases'] += results[1][0].cycles > results[0][0].cycles

    try:
        for im in production:
            fixture_rows.append(dict(artifact=str(im.path), prg_sha256=digest(im.path), prg_bytes=im.path.stat().st_size) | run_fixture(im))
        for im in images:
            for address in range(2, 0xfb):
                im.write(im.machine, address, (address * 17 + 3) & 255)
            im.write(im.machine, 0xff, 0x6b)
        for factor in FACTORS:
            assert frames[production[0]][f'record{factor}']['size'] == frames[production[1]][f'record{factor}']['size']
            for value in range(65536):
                flags = (value >> 8) & 0xc7
                for index in (0, 3, 7):
                    check(production, factor, value, index, flags, 'production_binary')
            print(f'Passed all word values at production stride {factor}, indexes 0/3/7', flush=True)
        for factor in FACTORS:
            for value in BOUNDARIES:
                for index in (0, 1, 3, 7, 0x100, 0x8007, 0xffff):
                    for bits in range(64):
                        flags = (bits & 15) | ((bits & 16) << 2) | ((bits & 32) << 2)
                        check(normalized, factor, value, index, flags, 'normalized_frame_flags')
            print(f'Passed normalized-frame binary/decimal flag boundaries at stride {factor}', flush=True)
        for im in images:
            assert all(im.read(im.machine, address) == (address * 17 + 3) & 255 for address in range(2, 0xfb)), (im.path, 'unowned ZP changed')
            assert im.read(im.machine, 0xff) == 0x6b
        # Diagnostic only: ambient-decimal address calculation of relocated frame
        # bases can leave the source frame even before this optimization. Reload
        # a fresh PRG per case so such legacy stores cannot contaminate later tests.
        for factor in FACTORS:
            pair = [Image(library, path) for path in paths]
            try:
                for im in pair:
                    frame = next(f for f in im.frames if f['owner'] == f'function:record{factor}')
                    size = frame['end'] - frame['start']
                    seed = (c.c_uint8 * size)(*((offset * 29 + 3) & 255 for offset in range(size)))
                    load(im.machine, frame['start'], seed, size)
                returned = []
                for im in pair:
                    try:
                        result = im.call(f'record{factor}', {'value': (0x1234, 2), 'index': (3, 2)}, {}, 8, True)
                        frame = next(f for f in im.frames if f['owner'] == f'function:record{factor}')
                        returned.append(dict(state=result[1], pointer=result[3], frame_sha256=hashlib.sha256(read_frame(im, frame['start'], frame['end'] - frame['start'])).hexdigest()))
                    except AssertionError as error:
                        returned.append(dict(error=str(error)))
                decimal_probe.append(dict(factor=factor, equivalent=returned[0] == returned[1], before=returned[0], after=returned[1]))
            finally:
                for im in pair:
                    im.close()
    finally:
        for im in images:
            im.close()
    report = dict(format='zeropage-stride-address-equivalence-v1', status='success',
                  cases=sum(row['cases'] for row in totals.values()), decimal_cases=sum(row['decimal_cases'] for row in totals.values()),
                  source='tests/fixtures/optimization/stride_address_equivalence.zp64',
                  source_sha256=digest(ROOT / 'tests/fixtures/optimization/stride_address_equivalence.zp64'),
                  before_sha256=digest(args.before), after_sha256=digest(args.after), fixtures=fixture_rows,
                  matrices=totals, frame_read_mode=read_mode,
                  normalized_probes=[dict(artifact=str(path), prg_sha256=digest(path)) for path in normalized_paths],
                  production_decimal_probe=decimal_probe,
                  checks=['actual production PRGs: every word input at three indexes', 'exact A/X/Y/P/SP',
                          'complete seeded current frames', 'independent binary return and every row/field oracle',
                          'binary guard bytes and adjacent-frame canaries', 'unowned ZP canaries',
                          'canonical pointer scratch identity', 'full flag cross products at word/BCD/page boundaries',
                          'high-word index masks', 'separate normalized-frame decimal source integration'],
                  scopes=dict(production_binary='Unmodified compiler PRGs, main hooks and full source state.',
                              normalized_frame_flags='64tass .logical moves only private static-frame run addresses to identical valid-BCD RAM. Not production PRG/startup or whole-application timing.',
                              production_decimal_probe='Diagnostic only, not equivalence invariant: existing decimal ADC of relocated frame bases is layout-dependent. Exact helper decimal proof is separate.'),
                  cycle_scope='Peddle CPU cycles excluding final outer RTS and intercepted fixture hooks; normalized metrics never mixed with production claims')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f"Passed {report['cases']} integration pairs ({report['decimal_cases']} decimal); production layout decimal mismatches: {sum(not row['equivalent'] for row in decimal_probe)}", flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('before', 'after', 'library', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--work-dir', type=Path, default=Path('build/stride-address-proof'))
    parser.add_argument('--assembler', type=Path)
    arguments = parser.parse_args()
    if arguments.output.exists():
        parser.error('output exists; choose a new proof path to preserve results')
    verify(arguments)
