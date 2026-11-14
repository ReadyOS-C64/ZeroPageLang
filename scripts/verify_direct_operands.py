#!/usr/bin/env python3
"""Peddle differential proof: direct ALU operands, full byte pairs and word values."""
import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path
from verify_pointer_reuse import Image


def verify(args):
    lib = c.CDLL(str(args.library.resolve()))
    images = [Image(lib, p) for p in (args.before, args.after)]
    frames = {im: {f['owner']: f for f in im.frames} for im in images}
    totals = {}
    decimal_cases = 0
    byte_functions = {'addByte', 'subByte', 'andByte', 'orByte', 'xorByte', 'volatilePair'}

    def check(function, arguments, seed, expected=None, decimal=False, memory=None):
        nonlocal decimal_cases
        results = [im.call(function, arguments, memory or {}, seed, decimal) for im in images]
        assert results[0][1:] == results[1][1:], (function, seed, decimal, 'state mismatch', results[0][1:], results[1][1:])
        observed = []
        for im in images:
            f = frames[im]['function:' + function]
            observed.append(bytes(im.read(im.machine, addr) for addr in range(f['start'], f['end'])))
        assert observed[0] == observed[1], (function, seed, decimal, 'frame mismatch')
        if expected is not None and not decimal:
            r = results[1][0]
            value = r.a if function in byte_functions else r.a | (r.x << 8)
            assert value == expected, (function, seed, value, expected)
        row = totals.setdefault(function, dict(cases=0, before_cycles=0, after_cycles=0, before_instructions=0,
                                              after_instructions=0, slower_cases=0))
        row['cases'] += 1
        for phase, r in zip(('before', 'after'), results):
            row[phase + '_cycles'] += r[0].cycles
            row[phase + '_instructions'] += r[0].instructions
        row['slower_cases'] += results[1][0].cycles > results[0][0].cycles
        decimal_cases += decimal

    binary = {'add': lambda a, b: a + b, 'sub': lambda a, b: a - b,
              'and': lambda a, b: a & b, 'or': lambda a, b: a | b, 'xor': lambda a, b: a ^ b}
    try:
        for a in range(256):
            for b in range(256):
                for name, operation in binary.items():
                    check(name + 'Byte', {'a': (a, 1), 'b': (b, 1)}, a ^ b, operation(a, b) & 255)
            if (a + 1) % 64 == 0:
                print(f'Verified all byte pairs through lhs={a}', flush=True)
        for a in range(65536):
            b = (a * 257 + 0x81ff) & 65535
            decimal = bool(a & 8)
            for name, operation in binary.items():
                check(name + 'Word', {'a': (a, 2), 'b': (b, 2)}, a >> 8, operation(a, b) & 65535, decimal)
            check('constantMask', {'a': (a, 2)}, a, (a & 0x81ff) | 0x1200, decimal)
            if (a + 1) % 16384 == 0:
                print(f'Verified {a + 1} word values', flush=True)
        boundaries = (0, 1, 9, 15, 16, 99, 127, 128, 255, 256, 257, 0x7fff, 0x8000, 0x80ff, 0xff00, 0xffff)
        for a in boundaries:
            for b in boundaries:
                for decimal in (False, True):
                    for name, operation in binary.items():
                        check(name + 'Word', {'a': (a, 2), 'b': (b, 2)}, a ^ b, operation(a, b) & 65535, decimal)
                    for name, operation in [('add', binary['add']), ('sub', binary['sub'])]:
                        check(name + 'Mixed', {'a': (a, 2), 'b': (b & 255, 1)}, a ^ b, operation(a, b & 255) & 65535, decimal)
                    for name in ('add', 'and', 'or', 'xor'):
                        check(name + 'Assign', {'a': (a, 2), 'b': (b, 2)}, a ^ b, binary[name](a, b) & 65535, decimal)
        for initial in range(256):
            for name, expected in [('withEffect', 307), ('bitwiseEffect', 303), ('effectAssign', 303)]:
                check(name, {'initial': (initial, 2)}, initial, expected)
            check('rhsEffect', {'a': (initial, 2)}, initial, initial + 257)
            check('indirect', {'a': (initial, 2), 'location': (0xc1ff, 2)}, initial,
                  (initial - 0x80ff) & 65535, memory={0xc1ff: 255, 0xc200: 128})
            check('volatilePair', {'location': (0xdc04, 2)}, initial, 3)
    finally:
        for im in images:
            im.close()
    result = dict(format='zeropage-direct-alu-equivalence-v1', status='success', cases=sum(r['cases'] for r in totals.values()),
                  decimal_cases=decimal_cases, functions=totals,
                  before_sha256=hashlib.sha256(args.before.read_bytes()).hexdigest(),
                  after_sha256=hashlib.sha256(args.after.read_bytes()).hexdigest(),
                  checks=['A/X/Y/P/SP', 'complete current function frame', 'visible RAM', 'pointer scratch identity',
                          'all byte pairs', 'all word values against permuted RHS', 'word boundary cross product',
                          'decimal/binary equivalence', 'host expected binary results', 'mutable RHS after lhs effects',
                          'assignment RHS mutates destination', 'indirect RHS', 'two CIA timer reads'],
                  cycle_scope='Peddle CPU cycles excluding final top-level RTS')
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('before', 'after', 'library', 'output'):
        p.add_argument('--' + name, type=Path, required=True)
    verify(p.parse_args())
