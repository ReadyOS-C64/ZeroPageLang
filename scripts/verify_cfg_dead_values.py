#!/usr/bin/env python3
"""Execute actual CFG-pass synthetic graph pairs with Peddle.

The Zig generator calls the production pure pass and records its source hash.
This script assembles those exact before/after texts, then compares all physical
CPU state and application RAM across all64 C/Z/I/D/V/N patterns and register
edge seeds. It does not use removal decisions as correctness oracles.
"""
import argparse
import ctypes as c
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from verify_pointer_reuse import Image

EDGES = (0, 1, 0x7f, 0x80, 0xff)
REGISTERS = [(EDGES[i], EDGES[(i + 1) % 5], EDGES[(i + 2) % 5]) for i in range(5)] + [
    (0, 0, 0), (0xff, 0xff, 0xff), (0x80, 0x80, 0x80)]
LIVE_STACK = dict(enumerate((0x34, 0x12, 0xa5, 0x5a, 0x69, 0x96), 0x1fa))
RAM = range(0xc100, 0xc400)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def flags(bits):
    return (bits & 15) | ((bits & 16) << 2) | ((bits & 32) << 2)


def source_path(manifest, value):
    p = Path(value)
    if p.is_absolute() or p.exists():
        return p
    return manifest.parent / p


def assembler(explicit):
    if explicit:
        return str(explicit)
    if os.environ.get('ZEROPAGE_64TASS'):
        return os.environ['ZEROPAGE_64TASS']
    sibling = Path('../zeropage-tooling/bin/64tass')
    if sibling.exists():
        return str(sibling)
    found = shutil.which('64tass')
    assert found, 'Set ZEROPAGE_64TASS or --assembler to pinned64tass'
    return found


def assemble(manifest, case, phase, output, tool):
    assembly = source_path(manifest, case[phase + '_asm'])
    output.mkdir(parents=True, exist_ok=True)
    prg = output / (case['name'] + '-' + phase + '.prg')
    command = [tool, '-q', '--cbm-prg', '--vice-labels', '-l', str(prg) + '.labels', '-o', str(prg), str(assembly)]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    Path(str(prg) + '.log').write_text(result.stdout)
    assert result.returncode == 0, (case['name'], phase, result.stdout)
    # Shared Image only requires a static-frame list, which synthetic assembly
    # intentionally lacks. This is harness metadata, not compiler-emitted proof.
    Path(str(prg) + '.zpmap.json').write_text('{"format":"synthetic-cfg-graph","sections":[]}\n')
    return prg, dict(phase=phase, assembly=str(assembly), assembly_sha256=digest(assembly),
                     prg=str(prg), prg_sha256=digest(prg), bytes=prg.stat().st_size, command=command)


def run(im, entry, bits, registers, seed):
    m = im.machine
    im.reset(m)
    im.set_pc(m, im.labels[entry]); im.set_sp(m, 0xf9)
    a, x, y = registers
    im.set_a(m, a); im.set_x(m, x); im.set_y(m, y); im.set_p(m, 0x20 | flags(bits))
    for address in range(256):
        im.write(m, address, (address * 73 + seed) & 255)
    # The graph protocol reserves the default pointer for indirect-index probes.
    im.write(m, 0xfb, 0); im.write(m, 0xfc, 0xc1)
    for address in RAM:
        im.write(m, address, ((address & 255) * 37 + seed) & 255)
    for address, value in LIVE_STACK.items():
        im.write(m, address, value)
    status = im.run(m, 0xf9, 100000)
    assert status == 0, (im.path, bits, registers, 'BRK/budget', status)
    r = im.regs(m)
    assert r.sp == 0xf9 and all(im.read(m, a) == v for a, v in LIVE_STACK.items()), (im.path, 'live stack damage')
    return r, (r.a, r.x, r.y, r.p, r.sp), bytes(im.read(m, a) for a in range(256)), bytes(im.read(m, a) for a in RAM)


def verify(args):
    manifest = json.loads(args.manifest.read_text())
    library = c.CDLL(str(args.library.resolve()))
    tool = assembler(args.assembler)
    rows, artifacts = [], []
    selected = set(args.cases.split(',')) if args.cases else {case['name'] for case in manifest['cases']}
    assert selected <= {case['name'] for case in manifest['cases']}
    for case in manifest['cases']:
        if case['name'] not in selected:
            continue
        paths = []
        for phase in ('before', 'after'):
            prg, record = assemble(args.manifest, case, phase, args.artifacts, tool)
            artifacts.append(dict(case=case['name'], **record)); paths.append(prg)
        if 'expected_changed' in case:
            changed = paths[0].read_bytes() != paths[1].read_bytes()
            assert changed == case['expected_changed'], (case['name'], 'unexpected graph rewrite', changed, case['expected_changed'])
        pair = [Image(library, path) for path in paths]
        row = dict(name=case['name'], features=case.get('features', []), pass_stats=case.get('stats', {}),
                   cases=0, decimal_cases=0, before_cycles=0, after_cycles=0, before_instructions=0,
                   after_instructions=0, slower_cases=0)
        try:
            for bits in range(64):
                for index, registers in enumerate(REGISTERS):
                    seed = (bits * 17 + index * 29) & 255
                    results = [run(im, case.get('entry', 'probe_entry'), bits, registers, seed) for im in pair]
                    assert results[0][1:] == results[1][1:], (case['name'], bits, registers, 'full CPU/ZP/RAM mismatch', results[0][1], results[1][1])
                    for oracle in case.get('oracles', []):
                        address = oracle.get('address', oracle.get('addr'))
                        expected = oracle.get('expected_constant', oracle.get('expected', oracle.get('value')))
                        assert address is not None and expected is not None, ('unsupported independent oracle', oracle)
                        for im in pair:
                            assert im.read(im.machine, address) == expected, (case['name'], 'independent graph oracle', address, expected)
                    b, a = results[0][0], results[1][0]
                    row['cases'] += 1; row['decimal_cases'] += bool(flags(bits) & 8)
                    row['before_cycles'] += b.cycles; row['after_cycles'] += a.cycles
                    row['before_instructions'] += b.instructions; row['after_instructions'] += a.instructions
                    row['slower_cases'] += a.cycles > b.cycles
        finally:
            for im in pair:
                im.close()
        rows.append(row)
        print(case['name'], 'PASS', row['cases'], 'cases; cycles', row['before_cycles'], '->', row['after_cycles'], flush=True)
    report = dict(format='zeropage-cfg-dead-values-native-v1', status='success', generator_manifest=str(args.manifest),
                  generator_manifest_sha256=digest(args.manifest), generator_metadata={k:v for k,v in manifest.items() if k!='cases'},
                  graph_count=len(rows), cases=sum(r['cases'] for r in rows), decimal_cases=sum(r['decimal_cases'] for r in rows),
                  graphs=rows, artifacts=artifacts, register_seeds=REGISTERS,
                  checks=['all64 C/Z/I/D/V/N input patterns', 'complete endpoint A/X/Y/P/SP, no register/flag masks',
                          'all256 ZP bytes and complete application RAM C100–C3FF exact', 'live caller stack canaries',
                          'independent constant oracles declared by graph generator', 'positive rewrite and negative byte-identity controls'],
                  scope='Actual production pure-pass graph transformation, assembled with64tass then independently executed by Peddle. D-set cases compare real ADC/RMW behavior without assuming binary arithmetic. Every register edge value appears in each register across8 mixed/common seeds; this is not the full125-way A/X/Y Cartesian product.',
                  cycle_scope='Peddle cycles exclude final top-level RTS. Fixed graph origins/leaf addresses keep cross-graph code shrinkage separate.')
    args.output.parent.mkdir(parents=True, exist_ok=True); args.output.write_text(json.dumps(report, indent=2)+'\n')
    print('PASS', report['graph_count'], 'graphs;', report['cases'], 'pairs;', report['decimal_cases'], 'D-set', flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest', type=Path, required=True); p.add_argument('--library', type=Path, required=True)
    p.add_argument('--artifacts', type=Path, required=True); p.add_argument('--output', type=Path, required=True)
    p.add_argument('--assembler', type=Path); p.add_argument('--cases')
    verify(p.parse_args())


if __name__ == '__main__':
    main()
