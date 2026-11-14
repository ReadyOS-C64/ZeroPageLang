#!/usr/bin/env python3
"""Peddle equivalence/performance proof for loop pointer hoisting on real PRGs."""
import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path
from verify_pointer_reuse import Image


def verify(args):
    lib = c.CDLL(str(args.library.resolve()))
    images = [Image(lib, path) for path in (args.before, args.after)]
    totals = {}
    decimal_cases = 0

    def check(function, arguments, memory, seed, expected=None, decimal=False):
        nonlocal decimal_cases
        results = [im.call(function, arguments, memory, seed, decimal) for im in images]
        assert results[0][1:] == results[1][1:], (function, seed, decimal, 'state mismatch', results[0][1:], results[1][1:])
        frames = []
        for im in images:
            frame = next(f for f in im.frames if f['owner'] == 'function:' + function)
            frames.append(bytes(im.read(im.machine, addr) for addr in range(frame['start'], frame['end'])))
        assert frames[0] == frames[1], (function, seed, decimal, 'frame mismatch')
        if expected is not None and not decimal:
            r = results[1][0]
            actual = r.a if function in ('firstMatch', 'emptyLoop') else r.a | (r.x << 8)
            assert actual == expected, (function, seed, actual, expected)
        row = totals.setdefault(function, dict(cases=0, before_cycles=0, after_cycles=0,
                                              before_instructions=0, after_instructions=0, slower_cases=0))
        row['cases'] += 1
        for phase, result in zip(('before', 'after'), results):
            row[phase + '_cycles'] += result[0].cycles
            row[phase + '_instructions'] += result[0].instructions
        row['slower_cases'] += results[1][0].cycles > results[0][0].cycles
        decimal_cases += decimal

    try:
        for low in range(256):
            address = 0xc100 + low
            for pattern in range(8):
                values = [(low + i * (pattern + 1)) & 255 for i in range(4)]
                words = [((low << 8) + pattern * 8191 + i * 257) & 65535 for i in range(4)]
                data = values + [b for value in words for b in (value & 255, value >> 8)]
                memory = dict(enumerate(data, address)) | dict(enumerate([11, 22, 33, 44] + [0] * 8, 0xc500))
                seed = (low * 17 + pattern * 37) & 255
                decimal = bool(pattern & 4)
                param = {'record': (address, 2)}
                for function, expected in [('sumBytes', sum(values)), ('sumWords', sum(words) & 65535),
                                           ('scalarCalls', sum(v ^ 0x55 for v in values)), ('nested', 3 * sum(values))]:
                    check(function, param, memory, seed, expected, decimal)
                for target in (values[pattern & 3], (low - 1) & 255):
                    check('firstMatch', param | {'target': (target, 1)}, memory, seed,
                          values.index(target) if target in values else 255, decimal)
                for skip in (0, 1):
                    check('conditional', param | {'skip': (skip, 1)}, memory, seed, 0 if skip else sum(values), decimal)
                check('redirect', {'first': (address, 2), 'second': (0xc500, 2)}, memory, seed, values[0] + 99, decimal)
                check('aliasWrite', param | {'location': (address + 3, 2)}, memory, seed, sum(values[:3]) + 31, decimal)
                check('clobberCall', param, memory, seed, sum(values[:3]) + 22, decimal)
                check('volatileScan', param | {'location': (0xdc04, 2)}, memory, seed, None, decimal)
                check('emptyLoop', param, memory, seed, 7, decimal)
            if (low + 1) % 64 == 0:
                print(f'Verified pointer low bytes through {low}', flush=True)
    finally:
        for im in images:
            im.close()
    result = dict(format='zeropage-loop-equivalence-v1', status='success',
                  cases=sum(row['cases'] for row in totals.values()), decimal_cases=decimal_cases,
                  functions=totals,
                  before_sha256=hashlib.sha256(args.before.read_bytes()).hexdigest(),
                  after_sha256=hashlib.sha256(args.after.read_bytes()).hexdigest(),
                  checks=['A/X/Y/P/SP', 'complete current function frame', 'input/output RAM', 'pointer scratch identity',
                          'host expected values in binary mode', 'all 256 pointer low bytes', 'nested loops',
                          'early returns', 'source reassignments', 'indirect alias writes', 'callee scratch clobbers', 'volatile callee', 'zero iterations'],
                  cycle_scope='Peddle CPU cycles excluding final top-level RTS')
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('before', 'after', 'library', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    verify(parser.parse_args())
