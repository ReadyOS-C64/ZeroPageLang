#!/usr/bin/env python3
"""Verify source-owned zero-page lifecycle on precompiled PRGs using Peddle.

Executes through the actual entry/normal-return path; no pass hook can bypass
cleanup. Independent source-result and seeded-byte oracles supplement map/label
cross-checks. Compile fixtures separately; this script never installs a compiler.
"""
import argparse
import ctypes as c
import hashlib
import json
import re
from pathlib import Path
from verify_pointer_reuse import Image


STATUS_FLAGS = 0xcf  # N/V/D/I/Z/C; B/U are not independent physical flags.
LIVE_STACK = {0x1fa: 0x34, 0x1fb: 0x12, 0x1fc: 0xa5, 0x1fd: 0x5a, 0x1fe: 0x69, 0x1ff: 0x96}
CONFIG = {
    'omitted': dict(profile='compatibility', allocation='off'),
    'compatibility': dict(profile='compatibility', allocation='off'),
    'basic': dict(profile='basic', allocation='scratch'),
    'kernal': dict(profile='kernal', allocation='scratch'),
    'custom': dict(profile='kernal', allocation='scratch', ranges=[(0x20, 0x20), (0x60, 0x10)], reserve=[(0x20, 4), (0x60, 4)]),
    'no_restore': dict(profile='kernal', allocation='scratch', ranges=[(0x20, 0x20), (0x60, 0x10)], reserve=[(0x20, 4), (0x60, 4)], restore=False),
    'fragmented': dict(profile='kernal', allocation='scratch', ranges=[(0x10, 2), (0x14, 2), (0x18, 1), (0x1a, 1)]),
    'bare': dict(profile='bare', allocation='scratch', interrupts='application'),
    'stack': dict(profile='kernal', allocation='scratch', ranges=[(0x20, 0x40)], reserve=[(0x20, 4)], stack=(0x30, 0x32)),
    'startup_copy': dict(profile='kernal', allocation='scratch', ranges=[(0x20, 0x20), (0x60, 0x10)], reserve=[(0x20, 4), (0x60, 4)]),
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def expanded(ranges):
    result = set()
    for address, size in ranges:
        assert 2 <= address and size > 0 and address + size <= 255
        part = set(range(address, address + size))
        assert not result & part, ('overlapping reported ranges', ranges)
        result |= part
    return result


def from_map(ranges):
    for row in ranges:
        assert row.get('end', row['addr'] + row['size']) == row['addr'] + row['size'], ('inconsistent range end', row)
    return expanded([(row['addr'], row['size']) for row in ranges])


def allowed(profile):
    if profile in ('compatibility', 'basic'):
        return set(range(0xfb, 0xff))
    if profile == 'kernal':
        return set(range(2, 0x90)) | set(range(0xfb, 0xff))
    assert profile == 'bare'
    return set(range(2, 0xff))


def validate_metadata(im, name, mapping):
    config = CONFIG[name]
    info = mapping.get('zero_page')
    omitted = name == 'omitted' and info is None
    if omitted:
        claims = [dict(label='zeropage_ptr_tmp', addr=0xfb, size=2, kind='pointer'),
                  dict(label='zeropage_string_ptr', addr=0xfd, size=2, kind='string_pointer')]
    else:
        assert info is not None, (name, 'declared policy missing map metadata')
        assert info['profile'] == config['profile'], (name, info)
        assert info['allocation'] == config['allocation'], (name, info)
        assert info['interrupts'] == config.get('interrupts', 'system'), (name, info)
        assert info['restore_basic'] == config.get('restore', True), (name, info)
        assert info['restoration_scope'] == 'normal_exit' and info['async_basic_restore'] is False, (name, info)
        claims = info['claims']
    candidates = expanded(config['ranges']) if 'ranges' in config else allowed(config['profile'])
    reserved = expanded(config.get('reserve', []))
    admitted = candidates - reserved
    assert candidates <= allowed(config['profile'])
    if not omitted:
        assert from_map(info['candidate_ranges']) == candidates, (name, 'candidate map mismatch')
        assert from_map(info['reserved_ranges']) == reserved, (name, 'reservation map mismatch')
    owned, scratch, restore = set(), set(), set()
    labels = set()
    for claim in claims:
        label, address, size = claim['label'], claim['addr'], claim['size']
        assert label not in labels, (name, 'duplicate claim', label)
        labels.add(label)
        slots = set(range(address, address + size))
        assert size > 0 and slots <= admitted and not slots & owned, (name, 'invalid/overlapping/out-of-pool claim', claim)
        assert address + size <= 255, (name, 'page wrap', claim)
        actual_address = im.labels.get(label)
        if omitted and actual_address is None:
            # Legacy untyped numeric aliases are intentionally absent from
            # 64tass's VICE label list; retain byte-identical default assembly.
            alias = re.search(r'^' + re.escape(label) + r' = \$([0-9a-fA-F]+)$', Path(str(im.path) + '.asm').read_text(), re.M)
            actual_address = int(alias[1], 16) if alias else None
        assert actual_address == address, (name, label, 'label/alias mismatch', actual_address, address)
        if claim['kind'] in ('pointer', 'string_pointer', 'stack_pointer', 'frame_pointer'):
            assert size == 2, (name, 'noncontiguous pointer pair', claim)
        elif claim['kind'] == 'scratch':
            assert config['allocation'] == 'scratch' and size in (1, 2), (name, claim)
            scratch |= slots
        else:
            raise AssertionError((name, 'unexpected claim kind', claim))
        owned |= slots
        if config.get('restore', True):
            if config['profile'] == 'kernal':
                restore |= slots & set(range(2, 0x90))
            elif config['profile'] == 'bare':
                restore |= slots & set(range(2, 0xfb))
    assert len([claim for claim in claims if claim['kind'] == 'pointer']) == 1
    assert len([claim for claim in claims if claim['kind'] == 'string_pointer']) == 1
    ptr = next(claim['addr'] for claim in claims if claim['kind'] == 'pointer')
    string_ptr = next(claim['addr'] for claim in claims if claim['kind'] == 'string_pointer')
    for alias in ('zeropage_ptr_tmp', 'zeropage_console_ptr', 'zeropage_string_dst_ptr'):
        if alias in im.labels:
            assert im.labels[alias] == ptr, (name, alias, 'general-pointer remap mismatch')
    for alias in ('zeropage_string_ptr', 'zeropage_string_src_ptr', 'zeropage_kernal_ptr'):
        if alias in im.labels:
            assert im.labels[alias] == string_ptr, (name, alias, 'string-pointer remap mismatch')
    if 'ranges' in config:
        assert not owned & set(range(0xfb, 0xff)), (name, 'custom range silently used FB-FE')
    if 'stack' in config:
        for kind, address in zip(('stack_pointer', 'frame_pointer'), config['stack']):
            match = [claim for claim in claims if claim['kind'] == kind]
            assert len(match) == 1 and match[0]['addr'] == address, (name, kind, match)
    else:
        assert not any(claim['kind'] in ('stack_pointer', 'frame_pointer') for claim in claims)
    if not omitted:
        assert info['general_pointer'] == ptr and info['string_pointer'] == string_ptr
        markers = {match[1]: (int(match[2]), int(match[3]), match[4]) for match in re.finditer(
            r'; zeropage_zp_claim label=(\w+) addr=(\d+) size=(\d+) kind=(\w+)', Path(str(im.path) + '.asm').read_text())}
        assert markers == {claim['label']: (claim['addr'], claim['size'], claim['kind']) for claim in claims}, (name, 'assembly/map claim disagreement')
    lifecycle = bool(restore or scratch)
    if not omitted:
        assert info['owned_bytes'] == len(owned) and info['restored_bytes'] == len(restore), (name, 'map byte totals')
        assert info['entry_lifecycle'] == lifecycle and from_map(info['restored_ranges']) == restore, (name, 'map restoration/lifecycle')
        for spill in info['spills']:
            assert spill['label'] not in labels and spill['size'] in (1, 2), (name, 'invalid spill', spill)
            assert spill['reason'] in ('address_or_index_or_asm', 'allocation_off', 'unused', 'capacity'), (name, spill)
            assert 0x0200 <= im.labels[spill['label']] < 0x10000, (name, 'spill not in resident memory', spill)
    assert ('zeropage_zp_enter' in im.labels) == lifecycle, (name, 'missing/spurious enter')
    assert ('zeropage_zp_leave' in im.labels) == lifecycle, (name, 'missing/spurious leave')
    if name == 'fragmented':
        assert not any(claim['kind'] == 'scratch' and claim['size'] == 2 for claim in claims), (name, 'word crosses fragmented pool')
        assert any(spill['size'] == 2 and spill['reason'] == 'capacity' for spill in info['spills']), (name, 'missing whole-word spill')
    return claims, owned, scratch, restore


def setup(im, function, memory, seed, flags):
    m = im.machine
    im.reset(m)
    im.set_pc(m, im.labels[function])
    im.set_sp(m, 0xf9)
    im.set_a(m, (seed + 0x23) & 255)
    im.set_x(m, (seed ^ 0x89) & 255)
    im.set_y(m, (seed ^ 0x67) & 255)
    im.set_p(m, 0x20 | flags)
    for address, value in memory.items():
        im.write(m, address, value)
    for address, value in LIVE_STACK.items():
        im.write(m, address, value)
    return im.regs(m)


def registers(regs):
    return regs.a, regs.x, regs.y, regs.p & STATUS_FLAGS, regs.sp


def page(im):
    return bytes(im.read(im.machine, address) for address in range(256))


def run_helper(im, function, flags, seed):
    im.set_pc(im.machine, im.labels[function])
    im.set_a(im.machine, (seed + 0x23) & 255)
    im.set_x(im.machine, (seed ^ 0x89) & 255)
    im.set_y(im.machine, (seed ^ 0x67) & 255)
    im.set_p(im.machine, 0x20 | flags)
    before = im.regs(im.machine)
    status = im.run(im.machine, 0xf9, 500_000)
    assert status == 0, (im.path, function, 'BRK/budget', status)
    after = im.regs(im.machine)
    assert registers(before) == registers(after), (im.path, function, flags, registers(before), registers(after))
    assert all(im.read(im.machine, address) == value for address, value in LIVE_STACK.items()), (im.path, function, 'live caller stack overwritten')
    return after


def run_entry(im, mapping):
    main = next(section for section in mapping['sections'] if section['owner'] == 'function:main' and section['kind'] == 'code')
    main_return = None
    for _ in range(1_000_000):
        regs = im.regs(im.machine)
        opcode = im.read(im.machine, regs.pc)
        assert opcode != 0, (im.path, 'BRK', hex(regs.pc))
        if opcode == 0x60 and main['start'] <= regs.pc < main['end'] and regs.sp in (0xf7, 0xf9):
            main_return = regs
        if opcode == 0x60 and regs.sp == 0xf9:
            assert main_return is not None, (im.path, 'returned without main')
            assert (main_return.a, main_return.x, main_return.y, main_return.p & STATUS_FLAGS) == (regs.a, regs.x, regs.y, regs.p & STATUS_FLAGS), (im.path, 'normal-exit cleanup changed main results', registers(main_return), registers(regs))
            return regs
        im.step(im.machine)
    raise AssertionError((im.path, 'entry instruction budget'))


def verify(args):
    lib = c.CDLL(str(args.library.resolve()))
    files = sorted(args.prg_dir.glob('zero_page_lifecycle_*.prg'))
    assert files, ('no lifecycle PRGs', args.prg_dir)
    rows, helper_cases, entry_cases = [], 0, 0
    for path in files:
        name = path.stem.removeprefix('zero_page_lifecycle_')
        assert name in CONFIG, ('unknown lifecycle fixture', path)
        source = Path('tests/fixtures/optimization') / (path.stem + '.zp64')
        mapping = json.loads(Path(str(path) + '.zpmap.json').read_text())
        im = Image(lib, path)
        try:
            claims, owned, scratch, restore = validate_metadata(im, name, mapping)
            if restore:
                snapshot = im.labels['zeropage_zp_snapshot']
                assert 0x0200 <= snapshot < 0xd000 or 0xe000 <= snapshot < 0x10000, (name, 'snapshot outside ordinary RAM')
            for seed in (0, 1, 37, 127, 128, 255):
                initial = bytes((address * 73 + seed * 29 + 0x35) & 255 for address in range(256))
                memory = dict(enumerate(initial)) | {0xc0ff: 0xb1, 0xc100: 0, 0xc101: 0, 0xc102: 0,
                                                     0xc103: 0xc9, 0xc1fe: 0xd2, 0xc1ff: 0, 0xc200: 0, 0xc201: 0xe3,
                                                     0xc5ff: 0x9b, 0xc700: 0x9c, 0xc7ff: 0x9d, 0xc900: 0x9e}
                if name == 'startup_copy':
                    memory |= {address: 0xa5 for address in range(0xc600, 0xc700)}
                setup(im, 'zeropage_entry', memory, seed, seed & 0xc7)
                # Source arithmetic is checked in binary mode; decimal helper
                # preservation is covered separately below.
                im.set_p(im.machine, 0x20 | (seed & 0xc7))
                result = run_entry(im, mapping)
                expected = 0x5ca0 if name == 'stack' else 0x7de4 if name == 'startup_copy' else 0x5ba0
                actual = im.read(im.machine, 0xc100) | (im.read(im.machine, 0xc101) << 8)
                assert actual == expected, (name, seed, 'source result', actual, expected)
                assert im.read(im.machine, 0xc102) == 0x5a
                assert (im.read(im.machine, 0xc1ff) | (im.read(im.machine, 0xc200) << 8)) == 0x10f9
                for address in (0xc0ff, 0xc103, 0xc1fe, 0xc201, 0xc5ff, 0xc700, 0xc7ff, 0xc900):
                    assert im.read(im.machine, address) == memory[address], (name, seed, 'RAM guard overwritten', hex(address))
                for buffer_name, expected_text in (('message', b'ZP ABI'), ('source', b'UNUSED')):
                    length = im.labels['main_' + buffer_name + '_len']
                    data = im.labels['main_' + buffer_name + '_data']
                    assert im.read(im.machine, length) == len(expected_text), (name, buffer_name, 'length')
                    assert bytes(im.read(im.machine, data + i) for i in range(len(expected_text))) == expected_text, (name, buffer_name, 'buffer copy/remap')
                current = page(im)
                for address in range(256):
                    if address not in owned or address in restore:
                        assert current[address] == initial[address], (name, seed, 'ZP canary/restoration', hex(address), current[address], initial[address])
                if name == 'no_restore':
                    assert any(current[address] != initial[address] for address in owned), 'restore=false did not exercise mutable claimed state'
                if name == 'startup_copy':
                    payload = path.read_bytes()
                    load = int.from_bytes(payload[:2], 'little')
                    placement = next(p for p in mapping['memory_placements'] if p['name'] == 'copy')
                    assert placement['load'] == 'startup_copy' and placement['run_start'] == 0xc600
                    # Only code is invariant after execution; placed parameter
                    # storage is deliberately written by the call.
                    code = next(s for s in mapping['sections'] if s['owner'] == 'function:moved' and s['kind'] == 'code')
                    for address in range(code['start'], code['end']):
                        offset = placement['load_start'] + address - placement['run_start'] - load + 2
                        assert im.read(im.machine, address) == payload[offset], (name, seed, 'startup copy failed', hex(address))
                assert result.sp == 0xf9
                assert all(im.read(im.machine, address) == value for address, value in LIVE_STACK.items()), (name, seed, 'live caller stack overwritten')
                entry_cases += 1
            if scratch or restore:
                for bits in range(64):
                    flags = (bits & 15) | ((bits & 16) << 2) | ((bits & 32) << 2)
                    initial = bytes((address * 73 + bits * 29 + 0x35) & 255 for address in range(256))
                    setup(im, 'zeropage_zp_enter', dict(enumerate(initial)), bits, flags)
                    run_helper(im, 'zeropage_zp_enter', flags, bits)
                    after_enter = page(im)
                    for address in range(256):
                        expected = 0 if address in scratch else initial[address]
                        assert after_enter[address] == expected, (name, bits, 'enter init/canary', hex(address), after_enter[address], expected)
                    changed = bytearray(after_enter)
                    for address in owned:
                        changed[address] = initial[address] ^ 0xff
                        im.write(im.machine, address, changed[address])
                    run_helper(im, 'zeropage_zp_leave', flags, bits ^ 0xa5)
                    after_leave = page(im)
                    for address in range(256):
                        expected = initial[address] if address in restore else changed[address]
                        assert after_leave[address] == expected, (name, bits, 'leave restore/canary', hex(address), after_leave[address], expected)
                    helper_cases += 1
            rows.append(dict(fixture=name, source=str(source), source_sha256=digest(source),
                             artifact=str(path), prg_sha256=digest(path), map_sha256=digest(Path(str(path) + '.zpmap.json')),
                             prg_bytes=path.stat().st_size, claims=claims, owned_bytes=len(owned),
                             initialized_bytes=len(scratch), restored_bytes=len(restore), entry_cases=6,
                             helper_pairs=64 if scratch or restore else 0))
            print(f'{name}: entry/return, source results, {len(owned)} claimed / {len(scratch)} initialized / {len(restore)} restored bytes passed', flush=True)
        finally:
            im.close()
    report = dict(format='zeropage-lifecycle-proof-v1', status='success', fixtures=rows,
                  entry_cases=entry_cases, helper_pairs=helper_cases,
                  checks=['independent arithmetic and page-cross word result', 'real entry through normal return',
                          'main A/X/Y and N/V/D/I/Z/C preserved through cleanup', 'helper A/X/Y/SP and all 64 flag combinations',
                          'all 256 seeded ZP bytes', 'unclaimed/reserved/hardware/KERNAL canaries',
                          'all scratch initialization', 'only claimed system state restored', 'restore=false retains changed claims',
                          'custom pools omit FB-FE', 'contiguous pointer pairs and fragmented word spills',
                          'all pointer aliases and map/VICE/assembly consistency', 'complete buffer-to-buffer string effects',
                          'low software-stack pairs', 'startup copy executes after snapshot', 'live caller return-address/stack canaries',
                          'map byte totals, restoration ranges and resident spills'],
                  status_scope='N/V/D/I/Z/C; B/U are not independent physical status flags.',
                  timing_scope='Behavior proof; no CPU timing or real IRQ/NMI/ROM coexistence claim.')
    if args.compiler:
        report['compiler_sha256'] = digest(args.compiler)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f'Passed {len(rows)} fixtures, {entry_cases} entry returns and {helper_cases} helper pairs', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prg-dir', type=Path, required=True)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--compiler', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    verify(parser.parse_args())
