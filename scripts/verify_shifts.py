#!/usr/bin/env python3
"""Peddle equivalence/performance matrix for constant/dynamic unsigned shifts."""
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
    totals, decimal_cases = {}, 0

    def check(function, arguments, seed, expected=None, decimal=False, memory=None, byte=False):
        nonlocal decimal_cases
        results = [im.call(function, arguments, memory or {}, seed, decimal) for im in images]
        assert results[0][1:] == results[1][1:], (function, arguments, seed, decimal, 'state mismatch', results[0][1:], results[1][1:])
        observed = []
        for im in images:
            frame = frames[im]['function:' + function]
            observed.append(bytes(im.read(im.machine, a) for a in range(frame['start'], frame['end'])))
        assert observed[0] == observed[1], (function, arguments, seed, decimal, 'frame mismatch')
        if expected is not None and not decimal:
            r = results[1][0]
            actual = r.a if byte else r.a | (r.x << 8)
            assert actual == expected, (function, arguments, actual, expected)
        row = totals.setdefault(function, dict(cases=0, before_cycles=0, after_cycles=0,
                                              before_instructions=0, after_instructions=0, slower_cases=0))
        row['cases'] += 1
        for phase, r in zip(('before', 'after'), results):
            row[phase + '_cycles'] += r[0].cycles
            row[phase + '_instructions'] += r[0].instructions
        row['slower_cases'] += results[1][0].cycles > results[0][0].cycles
        decimal_cases += decimal

    try:
        for count in range(16):
            for value in range(65536):
                param = {'value': (value, 2)}
                seed, decimal = value >> 8, bool(value & 8)
                check('left' + str(count), param, seed, (value << count) & 65535, decimal)
                check('right' + str(count), param, seed, value >> count, decimal)
            print(f'Verified all word values at constant count {count}', flush=True)
        for value in range(256):
            for count in range(8):
                for bits in range(64):
                    flags = (bits & 15) | ((bits & 16) << 2) | ((bits & 32) << 2)
                    decimal = bool(flags & 8)
                    check('leftByte' + str(count), {'value': (value, 1)}, flags, (value << count) & 255, decimal, byte=True)
                    check('rightByte' + str(count), {'value': (value, 1)}, flags, value >> count, decimal, byte=True)
            if (value + 1) % 64 == 0:
                print(f'Verified byte/flag/count combinations through {value}', flush=True)
        boundaries = (0, 1, 9, 15, 16, 127, 128, 255, 256, 257, 0x7fff, 0x8000, 0x80ff, 0xff00, 0xffff)
        for count in range(256):
            for value in boundaries:
                for decimal in (False, True):
                    params = {'value': (value, 2), 'count': (count, 1)}
                    check('dynamicLeft', params, value ^ count, (value << count) & 65535, decimal)
                    check('dynamicRight', params, value ^ count, value >> count, decimal)
                    check('compoundDynamic', params, value ^ count, (value << count) & 65535, decimal)
                    check('countExpression', params, value ^ count, value >> (count >> 1), decimal)
                    check('wideCount', {'value': (value, 2), 'count': (count + 256, 2)}, value, value >> count, decimal)
                    for direction, expected in [('Left', (value << count) & 255), ('Right', (value & 255) >> count)]:
                        check('dynamicByte' + direction, {'value': (value & 255, 1), 'count': (count, 1)}, value ^ count, expected, decimal, byte=True)
        for value in range(65536):
            seed, decimal = value >> 8, bool(value & 8)
            for function, expected in [('nestedLeft', (value << 12) & 65535), ('nestedRight', ((value << 3) & 65535) >> 9),
                                       ('arithmeticZero', (value + 257) & 65535), ('compoundLeft', (value << 8) & 65535),
                                       ('compoundRight', value >> 9), ('localArray', value >> 8)]:
                check(function, {'value': (value, 2)}, seed, expected, decimal)
        for low in range(256):
            address = 0xc100 + low
            value = (low * 257) ^ 0x81ff
            data = [3, value & 255, value >> 8, 255, 255, value & 255, value >> 8]
            memory = dict(enumerate(data, address))
            record = {'record': (address, 2)}
            check('pointerWord', record, low, (value << 8) & 65535, memory=memory)
            check('pointerArray', record | {'i': (1, 1)}, low, value >> 9, memory=memory)
            check('sideEffect', record, low, value, memory=memory)
            check('manyArray', {'values': (address + 1, 2), 'i': (0, 1)}, low, (value << 1) & 65535, memory=memory)
            check('volatileZero', {'location': (0xdc04, 2)}, low, 0x8101, memory={0xdc05: 0x81})
            check('volatileRight', {'location': (0xdc04, 2)}, low, 0x81, memory={0xdc05: 0x81})
    finally:
        for im in images:
            im.close()
    result = dict(format='zeropage-shift-equivalence-v1', status='success',
                  cases=sum(row['cases'] for row in totals.values()), decimal_cases=decimal_cases, functions=totals,
                  before_sha256=hashlib.sha256(args.before.read_bytes()).hexdigest(),
                  after_sha256=hashlib.sha256(args.after.read_bytes()).hexdigest(),
                  checks=['A/X/Y/P/SP', 'complete current function frame', 'visible RAM', 'pointer scratch identity',
                          'all word values at every legal literal word count', 'all byte/flag/count combinations',
                          'all runtime count byte values', 'wide runtime count low-byte behavior', 'nested shifts',
                          'compound/local-array/pointer-array/many-pointer assignments', 'operand side effects',
                          'all pointer low bytes', 'word volatile read width including zero shift', 'binary host oracles'],
                  notes='Private runtime shift value/count scratch is not a public return contract; X-count kernels leave the count slot unchanged.',
                  cycle_scope='Peddle CPU cycles excluding final top-level RTS')
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('before', 'after', 'library', 'output'):
        p.add_argument('--' + name, type=Path, required=True)
    verify(p.parse_args())
