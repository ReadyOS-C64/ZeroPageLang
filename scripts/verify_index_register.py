#!/usr/bin/env python3
"""Peddle equivalence/performance proof for canonical RAM values cached in Y."""
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

    def check(function, arguments, flags, expected, memory=None):
        nonlocal decimal_cases
        decimal = bool(flags & 8)
        results = [im.call(function, arguments, memory or {}, flags, decimal) for im in images]
        assert results[0][1:] == results[1][1:], (function, arguments, flags, 'CPU/RAM/pointer mismatch', results[0][1:], results[1][1:])
        observed = []
        for im in images:
            frame = frames[im]['function:' + function]
            data = bytearray(im.read(im.machine, a) for a in range(frame['start'], frame['end']))
            for name, (value, width) in arguments.items():
                if isinstance(value, str):
                    offset = im.labels[function + '_' + name] - frame['start']
                    assert width == 2 and int.from_bytes(data[offset:offset + width], 'little') == im.labels[value]
                    # Only the explicitly seeded pointer to moved private
                    # storage is normalized. Its owner/field identity is fixed.
                    data[offset:offset + width] = b'\0\0'
            observed.append(data)
        assert observed[0] == observed[1], (function, arguments, flags, 'source frame mismatch', observed)
        r = results[1][0]
        if not decimal:
            assert r.a | (r.x << 8) == expected, (function, arguments, flags, r.a | (r.x << 8), expected)
        key = function + ('_alias' if any(isinstance(v, str) for v, _ in arguments.values()) else '')
        row = totals.setdefault(key, dict(cases=0, before_cycles=0, after_cycles=0,
                                         before_instructions=0, after_instructions=0, slower_cases=0))
        row['cases'] += 1
        for phase, result in zip(('before', 'after'), results):
            row[phase + '_cycles'] += result[0].cycles
            row[phase + '_instructions'] += result[0].instructions
        row['slower_cases'] += results[1][0].cycles > results[0][0].cycles
        decimal_cases += decimal

    try:
        for value in range(256):
            index, other = value & 127, value ^ 0xa5
            a, b, cc = index ^ 0x55, (index * 17 + 3) & 255, 255 - index
            for bits in range(64):
                flags = (bits & 15) | ((bits & 16) << 2) | ((bits & 32) << 2)
                arg = {'index': (value, 1)}
                check('gather', arg, flags, a + b + cc)
                check('reverse', arg | {'other': (other, 1)}, flags, a + (((other & 127) * 17 + 3) & 255) + cc)
                check('mutate', arg, flags, a + ((((index + 1) & 127) * 17 + 3) & 255))
                check('branch', arg, flags, b if a < 64 else a + cc)
                check('callBarrier', arg, flags, a + (((((value + 1) & 255) & 127) * 17 + 3) & 255) + cc)
                address = 0xc100 + value
                check('store', arg | {'location': (address, 2)}, flags, a + b, {address: value})
                check('store', arg | {'location': ('store_i', 2)}, flags, a + ((a * 17 + 3) & 255))
                check('volatileReads', arg | {'location': (0xdc04, 2)}, flags, a + b + 3)
            if (value + 1) % 64 == 0:
                print(f'Verified index/flag/alias combinations through {value}', flush=True)
    finally:
        for im in images:
            im.close()
    output = dict(format='zeropage-index-register-equivalence-v1', status='success',
                  cases=sum(row['cases'] for row in totals.values()), decimal_cases=decimal_cases, functions=totals,
                  before_sha256=hashlib.sha256(args.before.read_bytes()).hexdigest(),
                  after_sha256=hashlib.sha256(args.after.read_bytes()).hexdigest(),
                  checks=['exact A/X/Y/P/SP', 'complete source frames', 'visible RAM', 'canonical pointer scratch',
                          'all byte inputs/64 flag combinations', 'index mutation and other-index invalidation',
                          'pointer writes aliasing the cached index', 'calls and control flow', 'two real CIA reads',
                          'binary independent result oracles'],
                  normalization='Only explicitly seeded private-frame pointer argument bytes are normalized after checking owner/field identity.',
                  cycle_scope='Peddle CPU cycles excluding final top-level RTS')
    args.output.write_text(json.dumps(output, indent=2) + '\n')
    print(f"Passed {output['cases']} pairs, {decimal_cases} decimal; slower cases: {sum(r['slower_cases'] for r in totals.values())}", flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('before', 'after', 'library', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    verify(parser.parse_args())
