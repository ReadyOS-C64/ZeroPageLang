#!/usr/bin/env python3
"""Peddle proof for bounded induction high-byte hoisting and range operands."""
import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path
from verify_pointer_reuse import Image


def verify(args):
    lib = c.CDLL(str(args.library.resolve()))
    images = [Image(lib, path) for path in (args.before, args.after)]
    frames = {im: {f['owner']: f for f in im.frames} for im in images}
    totals = {}
    decimal_cases = 0

    def check(function, arguments, seed, expected=None, decimal=False, memory=None, alias=None):
        nonlocal decimal_cases
        results, observed = [], []
        for im in images:
            frame = frames[im]['function:' + function]
            for offset, address in enumerate(range(frame['start'], frame['end'])):
                im.write(im.machine, address, (seed * 17 + offset * 37) & 255)
            params = dict(arguments)
            if alias is not None:
                params['location'] = (im.labels[function + '_i'] + alias, 2)
            result = im.call(function, params, memory or {}, seed, decimal)
            results.append(result)
            ram = bytearray(im.read(im.machine, a) for a in range(frame['start'], frame['end']))
            if alias is not None:
                slot = im.labels[function + '_location']
                actual = im.read(im.machine, slot) | (im.read(im.machine, slot + 1) << 8)
                assert actual == params['location'][0], (function, 'changed alias argument')
                # The argument points into a moved private frame; normalize only
                # those two address bytes, retaining every other frame byte.
                ram[slot - frame['start']:slot - frame['start'] + 2] = b'\0\0'
            observed.append(bytes(ram))
        assert results[0][1:] == results[1][1:], (function, seed, decimal, alias, 'CPU/RAM/scratch mismatch', results[0][1:], results[1][1:])
        assert observed[0] == observed[1], (function, seed, decimal, alias, 'frame mismatch', observed)
        if expected is not None and not decimal:
            r = results[1][0]
            actual = r.a | (r.x << 8)
            assert actual == expected, (function, seed, alias, actual, expected)
        row = totals.setdefault(function, dict(cases=0, before_cycles=0, after_cycles=0,
                                              before_instructions=0, after_instructions=0, slower_cases=0))
        row['cases'] += 1
        for phase, result in zip(('before', 'after'), results):
            row[phase + '_cycles'] += result[0].cycles
            row[phase + '_instructions'] += result[0].instructions
        row['slower_cases'] += results[1][0].cycles > results[0][0].cycles
        decimal_cases += decimal

    try:
        offsets = dict(shortIndexes=6, scalarCalls=10, byteArray=42, wordArray=517,
                       nested=30, earlyContinue=12, empty=0, oneTrip=0)
        for word in range(65536):
            for function, offset in offsets.items():
                check(function, {'seed': (word, 2)}, word, (word + offset) & 65535, bool(word & 8))
            if (word + 1) % 16384 == 0:
                print(f'Verified {word + 1} complete word seeds', flush=True)
        for value in range(256):
            for bits in range(64):
                flags = (bits & 15) | ((bits & 16) << 2) | ((bits & 32) << 2)
                decimal = bool(flags & 8)
                seed = value * 257
                if bits < 16:
                    check('sumIndexes', {'seed': (seed, 2)}, flags, (seed + 32385) & 65535, decimal)
                    check('firstIndex', {'target': (value, 1)}, flags, value if value < 255 else 65535, decimal)
                check('shortIndexes', {'seed': (seed, 2)}, flags, (seed + 6) & 65535, decimal)
                for function in ('aliasRead', 'aliasWrite', 'calleeWrite'):
                    for alias in (0, 1):
                        expected = (12 if alias == 0 else 6) if function == 'aliasRead' else 6
                        check(function, {}, flags ^ value, expected, decimal, alias=alias)
            address = 0xc100 + value
            memory = dict(enumerate([(value + i * 17) & 255 for i in range(4)], address))
            check('pointerReads', {'record': (address, 2)}, value, sum(memory.values()) + 6, memory=memory)
            check('asmBarrier', {}, value, 6)
    finally:
        for im in images:
            im.close()
    result = dict(format='zeropage-loop-range-equivalence-v1', status='success',
                  cases=sum(row['cases'] for row in totals.values()), decimal_cases=decimal_cases, functions=totals,
                  before_sha256=hashlib.sha256(args.before.read_bytes()).hexdigest(),
                  after_sha256=hashlib.sha256(args.after.read_bytes()).hexdigest(),
                  checks=['A/X/Y/P/SP', 'complete seeded current frame', 'private pointer argument normalization',
                          'visible RAM', 'canonical pointer scratch', 'host expected binary results',
                          'all 65536 word seeds in eight functions', 'all 64 input flag combinations',
                          'all 255 induction values', 'byte/word foreach prefix', 'nested loops', 'early returns',
                          'continue/break', 'zero/one trip', 'all pointer low bytes',
                          'capture low/high read aliases', 'capture low/high direct and callee write aliases', 'opaque asm callee'],
                  cycle_scope='Peddle CPU cycles excluding final top-level RTS')
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('before', 'after', 'library', 'output'):
        p.add_argument('--' + name, type=Path, required=True)
    verify(p.parse_args())
