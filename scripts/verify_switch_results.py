#!/usr/bin/env python3
"""Verify switch optimization against declared ABI results and source memory.

Y and C/N/Z are call-clobbered implementation state. Check A/X/SP and I/D/V,
complete source frames, RAM/selector effects, and independent result oracles.
Supplementary large switches use identical 64tass -B relaxation on both sides.
"""
import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path
from verify_pointer_reuse import Image


def verify(args):
    lib = c.CDLL(str(args.library.resolve()))
    normal = [Image(lib, p) for p in (args.before, args.after)]
    large = [Image(lib, p) for p in (args.before_large, args.after_large)]
    frames = {im: {f['owner']: f for f in im.frames} for im in normal + large}
    totals, decimal_cases = {}, 0

    def check(function, arguments, seed, expected, decimal=False, memory=None, supplementary=False, binary_only=False):
        nonlocal decimal_cases
        images = large if supplementary else normal
        result = [im.call(function, arguments, memory or {}, seed, decimal) for im in images]
        a, b = result[0][0], result[1][0]
        assert (a.a, a.x, a.sp, a.p & 0x4c) == (b.a, b.x, b.sp, b.p & 0x4c), (function, arguments, seed, decimal, 'ABI/register mismatch', result[0][1], result[1][1])
        assert result[0][2:] == result[1][2:], (function, arguments, 'RAM/pointer mismatch')
        observed = []
        for im in images:
            frame = frames[im].get('function:' + function)
            observed.append(bytes(im.read(im.machine, address) for address in range(frame['start'], frame['end'])) if frame else b'')
        assert observed[0] == observed[1], (function, arguments, 'frame mismatch', observed)
        byte_functions = {'holes', 'signedByte', 'adjacentRanges', 'boolean', 'enumResult', 'charResult', 'fullByte', 'crossPage'}
        actual = b.a if function in byte_functions else b.a | (b.x << 8)
        if not binary_only or not decimal:
            assert actual == expected, (function, arguments, seed, decimal, actual, expected)
        row = totals.setdefault(function, dict(cases=0, before_cycles=0, after_cycles=0,
                                              before_instructions=0, after_instructions=0, slower_cases=0,
                                              changed_y=0, changed_cnz=0))
        row['cases'] += 1
        for phase, r in zip(('before', 'after'), result):
            row[phase + '_cycles'] += r[0].cycles
            row[phase + '_instructions'] += r[0].instructions
        row['slower_cases'] += b.cycles > a.cycles
        row['changed_y'] += b.y != a.y
        row['changed_cnz'] += bool((b.p ^ a.p) & 0x83)
        decimal_cases += decimal

    try:
        holes = {v: v ^ 0x55 for v in (10, 12, 16, 20, 22, 24, 27, 30)}
        for value in range(256):
            for bits in range(64):
                flags = (bits & 15) | ((bits & 16) << 2) | ((bits & 32) << 2)
                decimal = bool(flags & 8)
                arg = {'value': (value, 1)}
                dense = 1 << value if value < 9 else 0
                for function, expected in [
                    ('dense', dense), ('biased', 0x8100 + (value - 224) * 17 if 224 <= value <= 231 else 65535),
                    ('holes', holes.get(value, 99)), ('signedByte', value - 118 if 128 <= value <= 135 else 77),
                    ('adjacentRanges', 8 if 10 <= value <= 14 else 0), ('boolean', 0 if value == 1 else 1),
                    ('enumResult', value + 20 if value < 5 else 25),
                    ('enumSelector', (value - 19) * 11 if 20 <= value <= 24 else 99),
                    ('charResult', value + 1 if value < 3 else 4),
                    ('castResults', value + 257 if value < 4 else 999),
                    ('nested', (value + 1) * 10 if value < 4 else 77),
                ]:
                    check(function, arg, flags, expected, decimal)
                other = (value * 257) ^ 0x81ff
                check('dynamicValue', arg | {'other': (other, 2)}, flags, other if value == 0 else 8 if value == 1 else 9, decimal)
                check('consume', arg | {'other': (dense, 2)}, flags, (dense + 1) & 65535, decimal, binary_only=True)
                check('fullByte', arg, flags, value ^ 0x55, decimal, supplementary=True)
            if (value + 1) % 64 == 0:
                print(f'Verified byte/flag combinations through {value}', flush=True)
        for value in range(65536):
            flags, decimal = value >> 8, bool(value & 8)
            arg = {'value': (value, 2)}
            for function, expected in [
                ('wordPage', 0x9000 + value - 0x8100 if 0x8100 <= value <= 0x8107 else 123),
                ('signedWord', 65535 - (value - 0x8000) if 0x8000 <= value <= 0x8007 else 99),
                ('wordInterval', 999 if 250 <= value <= 300 else 77), ('uniform', 555),
                ('payload', 2 if value == 1 else (value + 2) & 65535),
            ]:
                check(function, arg, flags, expected, decimal, binary_only=function == 'payload')
            check('crossPage', arg, flags, (value - 250) // 32 + 1 if 250 <= value <= 505 else 99, decimal, supplementary=True)
            if (value + 1) % 16384 == 0:
                print(f'Verified {value + 1} word selectors', flush=True)
        for seed in range(256):
            check('knownSelector', {}, seed, 902, bool(seed & 8))
            address = 0xc100 + seed
            check('selectorEffect', {'location': (address, 2)}, seed, 777, bool(seed & 8), {address: seed}, binary_only=True)
            check('volatileLookup', {'location': (0xdc04, 2)}, seed, 500, bool(seed & 8), {0xdc05: 0x81})
            # The second timer read must be 2; folding away the selector makes
            # the independently expected result one less in binary mode.
            check('volatileUniform', {'location': (0xdc04, 2)}, seed, 777 + 0x8102, bool(seed & 8), {0xdc05: 0x81}, binary_only=True)
    finally:
        for im in normal + large:
            im.close()
    result = dict(format='zeropage-switch-result-equivalence-v1', status='success',
                  cases=sum(v['cases'] for v in totals.values()), decimal_cases=decimal_cases, functions=totals,
                  before_sha256=hashlib.sha256(args.before.read_bytes()).hexdigest(),
                  after_sha256=hashlib.sha256(args.after.read_bytes()).hexdigest(),
                  before_large_sha256=hashlib.sha256(args.before_large.read_bytes()).hexdigest(),
                  after_large_sha256=hashlib.sha256(args.after_large.read_bytes()).hexdigest(),
                  checks=['A/X/SP', 'I/D/V', 'complete current frame', 'visible RAM', 'pointer scratch identity',
                          'independent result oracles', 'all byte/64-flag combinations', 'all word selectors',
                          'signed raw representations', 'bool/enum/char and cast results', 'holes and biased tables',
                          'full byte table', 'full 256-entry cross-page word window', 'uniform and known-selector folding',
                          'range merging', 'payload/dynamic-result fallback', 'selector effects', 'volatile word read width',
                          'second CIA read proves selector was evaluated', 'source caller consumes results'],
                  clobber_contract='Y and C/N/Z are not ABI return results; their changes are counted explicitly, not compared as invariants.',
                  supplementary_assembler='Both large probes use pinned 64tass -B; excluded from normal-corpus size/cycle claims because old CLI did not relax large switches.',
                  cycle_scope='Peddle CPU cycles excluding final top-level RTS')
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('before', 'after', 'before-large', 'after-large', 'library', 'output'):
        p.add_argument('--' + name, type=Path, required=True)
    verify(p.parse_args())
