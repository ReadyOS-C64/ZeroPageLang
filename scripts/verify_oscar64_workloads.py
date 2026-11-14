#!/usr/bin/env python3
"""Check precompiled Oscar64-inspired workloads with Peddle and independent oracles.

This does not compile/install anything or write build/emu. Whole-fixture timing
includes setup and checks but excludes intercepted hooks; kernel timing is
reported separately. Compare our own saved/current artifacts before competitors.
"""
import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path
from verify_pointer_reuse import Image


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_fixture(im):
    m = im.machine
    im.reset(m)
    im.set_pc(m, im.labels['main'])
    im.set_sp(m, 255)
    im.set_p(m, 0x20)
    im.write(m, 1, 0x37)
    hooks = {v: k for k, v in im.labels.items() if k.startswith('zeropage_test6502_')}
    hits = 0
    for _ in range(2_000_000):
        regs = im.regs(m)
        opcode = im.read(m, regs.pc)
        if opcode == 0x20:
            target = im.read(m, regs.pc + 1) | (im.read(m, regs.pc + 2) << 8)
            name = hooks.get(target)
            if name:
                hits += 1
                if name == 'zeropage_test6502_pass':
                    return dict(cycles=regs.cycles, instructions=regs.instructions, intercepted_calls=hits)
                prefix = 'zeropage_test6502_expect_equal_'
                assert name.startswith(prefix), (im.path, 'unsupported hook', name)
                kind = name[len(prefix):].split('_')[0]
                expected = int(name.rsplit('_', 1)[1], 16)
                actual = regs.a | (regs.x << 8) if kind == 'u16' else regs.a
                assert actual == expected, (im.path, name, hex(regs.pc), actual, expected)
                im.set_pc(m, regs.pc + 3)
                continue
        assert opcode != 0, (im.path, 'BRK', hex(regs.pc))
        assert not (opcode == 0x60 and regs.sp == 255), (im.path, 'returned without pass hook')
        im.step(m)
    raise AssertionError((im.path, 'fixture instruction budget exceeded'))


def verify(args):
    lib = c.CDLL(str(args.library.resolve()))
    images, fixture_rows, kernels = {}, [], {}
    try:
        sources = sorted(Path('tests/fixtures/emu/lang/pass/optimization_reference').glob('oscar64_*.zp64'))
        assert sources, 'no workload sources'
        for source in sources:
            path = args.prg_dir / (source.stem + '.prg')
            data = path.read_bytes()
            assert int.from_bytes(data[:2], 'little') + len(data) - 2 < 0x6000, (path, 'test RAM window overlaps image')
            im = Image(lib, path)
            # Wide-loop stress kernels intentionally exceed Image's small default.
            original_run = im.run
            assert original_run is not None, 'Peddle batch ABI required'
            im.run = lambda machine, sp, limit, run=original_run: run(machine, sp, 500_000)
            images[source.stem.removeprefix('oscar64_')] = im
            metrics = run_fixture(im)
            if source.stem in ('oscar64_records_aos', 'oscar64_records_soa'):
                particles = [dict(x=(i * 257 + 250 + (i + 1) * 3) & 65535,
                                  y=(65500 - i * 61 + (i * 3 + 7) * 3) & 65535,
                                  vx=i + 1, vy=i * 3 + 7, life=max(0, i - 1)) for i in range(8)]
                if source.stem.endswith('_aos'):
                    expected = b''.join(b''.join(row[field].to_bytes(2 if field != 'life' else 1, 'little')
                                                 for field in ('x', 'y', 'vx', 'vy', 'life')) for row in particles)
                    address = im.labels['main_records']
                else:
                    expected = b''.join(b''.join(row[field].to_bytes(2 if field != 'life' else 1, 'little')
                                                 for row in particles) for field in ('x', 'y', 'vx', 'vy', 'life'))
                    address = im.labels['main_fields']
                actual = bytes(im.read(im.machine, address + i) for i in range(len(expected)))
                assert actual == expected, (source, 'complete particle state mismatch', actual, expected)
            fixture_rows.append(dict(source=str(source), source_sha256=digest(source), artifact=str(path),
                                     prg_sha256=digest(path), prg_bytes=len(data), **metrics))
            print(f"{source.stem}: {metrics['intercepted_calls']} hooks, {metrics['cycles']} cycles", flush=True)

        def call(workload, function, arguments, expected, memory=None, result_width=2, check_memory=None):
            im = images[workload]
            result = im.call(function, arguments, memory or {}, 0, False)[0]
            actual = result.a if result_width == 1 else result.a | (result.x << 8)
            if expected is not None:
                assert actual == expected, (workload, function, arguments, actual, expected)
            if check_memory is not None:
                for address, value in check_memory.items():
                    assert im.read(im.machine, address) == value, (workload, function, arguments, hex(address), im.read(im.machine, address), value)
            row = kernels.setdefault(workload + ':' + function, dict(cases=0, cycles=0, instructions=0,
                                                                    minimum_cycles=None, maximum_cycles=0))
            row['cases'] += 1
            row['cycles'] += result.cycles
            row['instructions'] += result.instructions
            row['minimum_cycles'] = min(row['minimum_cycles'] or result.cycles, result.cycles)
            row['maximum_cycles'] = max(row['maximum_cycles'], result.cycles)
            assert result.sp == 0xf9, (workload, function, 'unbalanced hardware stack')
            return im, result

        values = list(range(256)) + [256, 257, 32767, 32768, 65534, 65535]
        for value in values:
            for factor in (3, 5, 7, 9, 10):
                call('odd_constant_multiply', 'times' + str(factor), {'value': (value, 2)}, value * factor & 65535)
            call('odd_constant_multiply', 'masked', {'value': (value, 2)}, (value & 31) * 3 + (value & 63) * 7 + (value & 127) * 9)
        for count in range(256):
            for seed in (0, 1, 65535):
                expected = (seed + 3 * count * (count - 1) // 2 + 7 * count) & 65535
                for function in ('rolled', 'grouped'):
                    call('bounded_reduction', function, {'count': (count, 1), 'seed': (seed, 2)}, expected)
            call('bounded_reduction', 'exits', {'count': (count, 1)}, sum(i for i in range(min(count, 10)) if i != 3))
        links = [3, 5, 7, 6, 1, 255, 2, 4]
        for start in list(range(8)) + [255]:
            for seed in (0, 1, 65535):
                cursor, total = start, seed
                for _ in range(8):
                    if cursor == 255:
                        break
                    total += 10 * (cursor + 1)
                    cursor = links[cursor]
                call('active_index_chain', 'walk', {'start': (start, 1), 'seed': (seed, 2)}, total & 65535)
        def combine(left, right):
            return ((left ^ 0x8100) + right) & 65535
        for value in range(256):
            for other in (0, 255, 256, 32767, 32768, 65535):
                byte = (value + 3) & 255
                expected = combine(byte, combine(other, 257))
                params = {'value': (value, 1), 'other': (other, 2)}
                call('short_scalar_calls', 'caller', params, expected)
                call('short_scalar_calls', 'choose', params, combine(other, byte) if value & 1 else expected)
            address = 0xc100 + value
            call('short_scalar_calls', 'ordered', {'location': (address, 2)}, combine(value, 30), {address: value}, check_memory={address: 29})
        for low in (0, 1, 127, 254, 255):
            source, target = 0x6000 + low, 0x6800 + ((low + 1) & 255)
            data = {source + i: (i * 17 + 9) & 255 for i in range(258)}
            data |= {target - 1: 0x4b} | {target + i: 0x73 for i in range(258)}
            for count in (0, 1, 2, 255, 256, 257):
                expected = data | {target + i: data[source + i] for i in range(count)}
                call('page_cross_copy', 'copyWindow', {'source': (source, 2), 'target': (target, 2), 'count': (count, 2)}, target + count, data, check_memory=expected)
        for low in (0, 1, 127, 254, 255):
            a, b = 0x6000 + low, 0x6800 + low
            data = {a + i: 0x35 for i in range(1280)} | {b + i: 0xc6 for i in range(1280)}
            expected = data | {a + i: 0x69 for i in range(768, 1024)} | {b + i: 0x96 for i in range(768, 1024)}
            call('wide_index_rebase', 'fill', {'a': (a, 2), 'b': (b, 2)}, None, data, check_memory=expected)
            expected[a + 1023] = 0xa7
            call('wide_index_rebase', 'retainLast', {'a': (a, 2)}, a + 1023, data, check_memory={addr: val for addr, val in expected.items() if a <= addr < a + 1280})
            expected = data | {a + i: i & 255 for i in range(768, 1024)} | {b + i: i >> 8 for i in range(768, 1024)}
            call('wide_index_rebase', 'indexBytes', {'a': (a, 2), 'b': (b, 2)}, None, data, check_memory=expected)
        im = images['bounded_relations']
        for start, end in ((0, 0), (0, 1), (5, 15), (250, 260), (65530, 65535)):
            for threshold in (0, 4, 5, 10, 14, 15, 255, 256, 65535):
                call('bounded_relations', 'countRelations', {'start': (start, 2), 'end': (end, 2), 'threshold': (threshold, 2)}, None)
                expected = dict(lt=sum(i < threshold for i in range(start, end)),
                                le=sum(i <= threshold for i in range(start, end)),
                                gt=sum(i > threshold for i in range(start, end)),
                                ge=sum(i >= threshold for i in range(start, end)),
                                eq=sum(i == threshold for i in range(start, end)),
                                ne=sum(i != threshold for i in range(start, end)))
                for field, value in expected.items():
                    addr = im.labels['countRelations_return_' + field]
                    actual = im.read(im.machine, addr) | (im.read(im.machine, addr + 1) << 8)
                    assert actual == value, ('countRelations', start, end, threshold, field, actual, value)
        output = dict(format='zeropage-oscar64-workload-proof-v1', status='success',
                      timing_model='Peddle CPU cycles, intercepted test hooks excluded, no VIC/CIA/ROM timing',
                      kernel_cycle_scope='Excludes final top-level RTS, includes internal calls; binary arithmetic mode',
                      fixtures=fixture_rows, kernels=kernels, native_cases=sum(row['cases'] for row in kernels.values()),
                      checks=['all fixture assertions', 'independent Python arithmetic and traversal results',
                              'full RAM windows and guard bytes', 'retained last address and post-copy cursor',
                              'page-boundary placements', 'all reduction trip counts and byte call inputs',
                              'all six relation counts including near $ffff', 'live SP balance', 'complete equal-input particle states including unchanged velocities'],
                      notes='Whole-fixture layout variants use equal inputs/rounds/checks; source layout is itself an experimental variable.')
        args.output.write_text(json.dumps(output, indent=2) + '\n')
        print(f"Passed {len(fixture_rows)} fixtures and {output['native_cases']} native oracle calls", flush=True)
    finally:
        for im in images.values():
            im.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prg-dir', type=Path, required=True)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    verify(parser.parse_args())
