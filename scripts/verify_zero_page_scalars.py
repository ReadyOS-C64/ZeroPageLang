#!/usr/bin/env python3
"""Paired Peddle proof for source-configured private parameter placement.

Checks complete CPU state, individually named source objects and explicit pointer
identities. It never compares guessed frame offsets or masks whole frame ranges.
Compile identical fixtures with the pinned before/after compilers separately.
"""
import argparse
import ctypes as c
from dataclasses import dataclass
import hashlib
import json
import re
from pathlib import Path
from verify_pointer_reuse import Image


@dataclass(frozen=True)
class Object:
    label: str
    width: int
    parameter: bool = False
    pointer: bool = False


@dataclass(frozen=True)
class Ref:
    label: str
    offset: int = 0


def objects(function, params=(), locals=()):
    return [Object(function + '_' + name, width, True, pointer) for name, width, pointer in params] + [
        Object(function + '_' + name, width, False, pointer) for name, width, pointer in locals]


VALUES = (
    objects('byteMix', [('left', 1, False), ('right', 1, False)], [('saved', 1, False)]) +
    objects('wordMix', [('left', 2, False), ('right', 2, False)], [('saved', 2, False)]) +
    objects('boolean', [('left', 1, False), ('right', 1, False)], [('saved', 1, False)]) +
    objects('enumMask', [('state', 1, False), ('value', 2, False)], [('result', 2, False)]) +
    objects('readPair', [('location', 2, True), ('mask', 2, False)], [('loaded', 2, False)]) +
    objects('identityPointer', [('location', 2, True)]) +
    objects('nonleaf', [('value', 2, False), ('mask', 2, False)], [('first', 2, False), ('second', 2, False)]) +
    objects('main', [], [('location', 2, True)])
)
ALIASES = (
    objects('aliasByte', [('value', 1, False), ('location', 2, True)], [('before', 1, False), ('reread', 1, False)]) +
    objects('aliasWord', [('value', 2, False), ('location', 2, True)], [('before', 2, False), ('reread', 2, False)]) +
    objects('main', [], [('location', 2, True)])
)
BARRIERS = (
    objects('eligible', [('value', 2, False)]) + objects('publicValue', [('value', 2, False)]) +
    objects('configured', [('value', 2, False)], [('saved', 2, False)]) +
    objects('placed', [('value', 2, False)]) +
    objects('escaped', [('value', 1, False)], [('location', 2, True)]) +
    objects('cycle', [('value', 1, False)]) + objects('stackCall', [('value', 2, False)])
)
ASM = objects('otherwiseEligible', [('value', 2, False)]) + objects('asmBarrier', [('value', 1, False)])
MAIN = objects('main', [('value', 1, False)])
BRIDGE = objects('leaf', [('value', 2, False), ('mask', 1, False)]) + objects('invoke', [('value', 2, False)])
RESERVED = objects('reservedStore', [('value', 1, False)], [('saved', 1, False), ('app', 2, True), ('reread', 1, False)]) + objects('main', [], [('app', 2, True)])
OBJECTS = {'values': VALUES, 'scratch_control': VALUES, 'alias': ALIASES, 'barriers': BARRIERS, 'asm': ASM, 'main_export': MAIN,
           'stack_bridge': BRIDGE, 'reserved': RESERVED}
LIVE_STACK = {0x1fa: 0x34, 0x1fb: 0x12, 0x1fc: 0xa5, 0x1fd: 0x5a, 0x1fe: 0x69, 0x1ff: 0x96}
BOUNDARIES = (0, 1, 2, 7, 15, 127, 128, 255, 256, 257, 0x7fff, 0x8000, 0x80ff, 0xff00, 0xfffe, 0xffff)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def flags(bits):
    return (bits & 15) | ((bits & 16) << 2) | ((bits & 32) << 2)


def metadata(im, variant, phase):
    mapping = json.loads(Path(str(im.path) + '.zpmap.json').read_text())
    info = mapping['zero_page']
    assert info['profile'] == 'kernal'
    assert info['allocation'] == ('scratch' if variant == 'scratch_control' else 'scalars')
    claims = {claim['label']: claim for claim in info['claims']}
    assert len(claims) == len(info['claims']), (variant, phase, 'duplicate claim labels')
    occupied = set()
    admitted = set(range(2, 0x90)) | set(range(0xfb, 0xff))
    for claim in claims.values():
        slots = set(range(claim['addr'], claim['addr'] + claim['size']))
        assert claim['size'] > 0 and slots <= admitted and not occupied & slots, (variant, phase, 'invalid/overlapping KERNAL claims', claim)
        occupied |= slots
    if variant == 'reserved':
        reserved = {address for item in info['reserved_ranges'] for address in range(item['addr'], item['addr'] + item['size'])}
        assert reserved == {2, 3} and not occupied & reserved, (phase, 'application reservation became a compiler claim')
    if variant == 'stack_bridge':
        fixed = {claim['kind']: claim['addr'] for claim in claims.values() if claim['kind'] in ('stack_pointer', 'frame_pointer')}
        assert fixed == {'stack_pointer': 0x70, 'frame_pointer': 0x72}, (phase, 'stack pair relocation/reservation')
    assembly = Path(str(im.path) + '.asm').read_text()
    descriptors = OBJECTS[variant]
    expected = {obj.label for obj in descriptors}
    present = set()
    for section in mapping['sections']:
        if section['kind'] != 'static_frame' or not section['owner'].startswith('function:'):
            continue
        for label in section['labels']:
            assert label in expected, (variant, phase, 'unmodeled source/static object', label)
            present.add(label)
        expected_bytes = sum(obj.width for obj in descriptors if obj.label in section['labels'])
        assert section['size'] == expected_bytes, (variant, phase, 'source frame extent differs from individually declared objects', section, expected_bytes)
    present |= {name for name, claim in claims.items() if claim['kind'] == 'parameter'}
    assert present == expected, (variant, phase, 'object coverage mismatch', present ^ expected)
    for obj in descriptors:
        assert obj.label in im.labels, (variant, phase, 'missing source label', obj)
        claim = claims.get(obj.label)
        if claim:
            assert obj.parameter and claim['kind'] == 'parameter' and claim['size'] == obj.width, (variant, phase, obj, claim)
            assert claim['addr'] == im.labels[obj.label], (variant, phase, 'claim/VICE label mismatch', obj)
        else:
            assert im.labels[obj.label] >= 0x0200, (variant, phase, 'unreported source-object promotion', obj)
            data = re.search(r'^' + re.escape(obj.label) + r':\s*\n\s*(\.word 0|\.byte 0(?:,0)?)\s*$', assembly, re.M)
            assert data is not None, (variant, phase, 'unverified source storage form', obj)
            width = 2 if data[1] in ('.word 0', '.byte 0,0') else 1
            assert width == obj.width, (variant, phase, 'source-object width mismatch', obj, width)
    parameters = {name for name, claim in claims.items() if claim['kind'] == 'parameter'}
    if phase == 'before':
        assert not parameters, (variant, 'before compiler unexpectedly promotes parameters', parameters)
    elif variant in ('scratch_control', 'asm', 'main_export'):
        assert not parameters, (variant, 'protected/control parameters promoted', parameters)
    elif variant == 'barriers':
        assert parameters == {'eligible_value'}, (variant, 'wrong boundary classification', parameters)
    else:
        assert parameters == {obj.label for obj in descriptors if obj.parameter}, (variant, 'positive typed parameter coverage', parameters)
    if variant == 'barriers':
        assert not any(name.startswith('stacked_') for name in parameters)
        assert 'stacked_value' not in im.labels, 'stack parameter manufactured as static/ZP slot'
    return mapping, info, claims


def pointer_identity(im, descriptors, value):
    for obj in descriptors:
        address = im.labels[obj.label]
        if address <= value < address + obj.width:
            return 'source_object', obj.label, value - address
    return 'absolute', value


def snapshots(im, descriptors):
    output = {}
    for obj in descriptors:
        address = im.labels[obj.label]
        data = bytes(im.read(im.machine, address + offset) for offset in range(obj.width))
        output[obj.label] = pointer_identity(im, descriptors, int.from_bytes(data, 'little')) if obj.pointer else data.hex()
    return output


def seed_call(im, descriptors, info, function, arguments, seed, status, memory):
    m = im.machine
    im.reset(m)
    im.set_pc(m, im.labels[function])
    im.set_sp(m, 0xf9)
    im.set_a(m, (seed + 0x23) & 255)
    im.set_x(m, (seed ^ 0x89) & 255)
    im.set_y(m, (seed ^ 0x67) & 255)
    im.set_p(m, 0x20 | status)
    # Native function entry explicitly initializes private state; it does not
    # pretend to execute the app's snapshot/restore lifecycle.
    for claim in info['claims']:
        if claim['kind'] == 'scratch':
            for address in range(claim['addr'], claim['addr'] + claim['size']):
                im.write(m, address, 0)
    for index, obj in enumerate(descriptors):
        value = 0xc300 + index * 2 if obj.pointer else ((seed * 257) ^ (index * 131 + 0x8155))
        for offset in range(obj.width):
            im.write(m, im.labels[obj.label] + offset, (value >> (offset * 8)) & 255)
    for name, value in arguments.items():
        obj = next(o for o in descriptors if o.label == function + '_' + name)
        actual = im.labels[value.label] + value.offset if isinstance(value, Ref) else value
        if isinstance(value, Ref):
            target = next(o for o in descriptors if o.label == value.label)
            assert 0 <= value.offset < target.width
        for offset in range(obj.width):
            im.write(m, im.labels[obj.label] + offset, (actual >> (offset * 8)) & 255)
    for address, value in memory.items():
        im.write(m, address, value)
    for address, value in LIVE_STACK.items():
        im.write(m, address, value)
    for label, value in (('zeropage_ptr_tmp', 0xc5a5), ('zeropage_string_ptr', 0xc55a)):
        address = im.labels[label]
        im.write(m, address, value & 255)
        im.write(m, address + 1, value >> 8)
    for claim in info['claims']:
        if claim['kind'] in ('stack_pointer', 'frame_pointer'):
            im.write(m, claim['addr'], 0)
            im.write(m, claim['addr'] + 1, 0xc8)
    status_code = im.run(m, 0xf9, 250_000)
    assert status_code == 0, (im.path, function, seed, status, 'BRK/budget', status_code)
    result = im.regs(m)
    assert result.sp == 0xf9 and all(im.read(m, address) == value for address, value in LIVE_STACK.items()), (im.path, function, 'live stack/caller return corruption')
    pointers = {}
    for label in ('zeropage_ptr_tmp', 'zeropage_string_ptr'):
        address = im.labels[label]
        raw = im.read(m, address) | (im.read(m, address + 1) << 8)
        pointers[label] = pointer_identity(im, descriptors, raw)
    return result, snapshots(im, descriptors), pointers, bytes(im.read(m, address) for address in sorted(memory))


def run_entry(im, mapping, info, variant):
    m = im.machine
    im.reset(m)
    im.set_pc(m, im.labels['zeropage_entry'])
    im.set_sp(m, 0xf9)
    im.set_p(m, 0x20)
    initial = bytes((address * 73 + 0x35) & 255 for address in range(256))
    for address, value in enumerate(initial):
        im.write(m, address, value)
    if variant == 'main_export':
        im.write(m, im.labels['main_value'], 0)
    for address, value in LIVE_STACK.items():
        im.write(m, address, value)
    hooks = {v: k for k, v in im.labels.items() if k.startswith('zeropage_test6502_')}
    main = next(s for s in mapping['sections'] if s['owner'] == 'function:main' and s['kind'] == 'code')
    hits, main_return, main_enter = 0, None, None
    for _ in range(500_000):
        regs = im.regs(m)
        opcode = im.read(m, regs.pc)
        if regs.pc == im.labels['main'] and main_enter is None:
            main_enter = regs.cycles
        if opcode == 0x20:
            target = im.read(m, regs.pc + 1) | (im.read(m, regs.pc + 2) << 8)
            name = hooks.get(target)
            if name:
                hits += 1
                if name != 'zeropage_test6502_pass':
                    prefix = 'zeropage_test6502_expect_equal_'
                    assert name.startswith(prefix), (im.path, name)
                    kind = name[len(prefix):].split('_')[0]
                    expected = int(name.rsplit('_', 1)[1], 16)
                    actual = regs.a | (regs.x << 8) if kind == 'u16' else regs.a
                    assert actual == expected, (im.path, name, actual, expected)
                im.set_pc(m, regs.pc + 3)
                continue
        assert opcode != 0, (im.path, 'entry BRK', hex(regs.pc))
        if opcode == 0x60 and main['start'] <= regs.pc < main['end'] and regs.sp in (0xf7, 0xf9):
            main_return = regs
        if opcode == 0x60 and regs.sp == 0xf9:
            assert main_return is not None
            assert (main_return.a, main_return.x, main_return.y, main_return.p) == (regs.a, regs.x, regs.y, regs.p), (im.path, 'cleanup register/status change')
            break
        im.step(m)
    else:
        raise AssertionError((im.path, 'entry budget'))
    if variant == 'main_export':
        assert regs.a == 0x55
    else:
        assert hits >= 3
    owned = {address for claim in info['claims'] for address in range(claim['addr'], claim['addr'] + claim['size'])}
    restore = owned & set(range(2, 0x90))
    for address in range(256):
        if variant == 'reserved' and address == 2:
            assert im.read(m, address) == 0xaa, (im.path, 'compiler clobbered/restored application-owned low byte')
        elif address not in owned or address in restore:
            assert im.read(m, address) == initial[address], (im.path, 'entry/exit ZP canary/restoration', hex(address))
    assert all(im.read(m, address) == value for address, value in LIVE_STACK.items())
    assert main_enter is not None
    return dict(cycles=regs.cycles, instructions=regs.instructions, hooks=hits, restored_bytes=len(restore),
                enter_cycles=main_enter, body_cycles=main_return.cycles - main_enter, leave_cycles=regs.cycles - main_return.cycles)


def verify(args):
    lib = c.CDLL(str(args.library.resolve()))
    images, facts, totals, entry = {}, {}, {}, []
    try:
        selected = set(args.variants.split(',')) if args.variants else set(OBJECTS)
        assert selected <= OBJECTS.keys(), ('unknown selected fixture', selected - OBJECTS.keys())
        for variant, descriptors in OBJECTS.items():
            if variant not in selected:
                continue
            pair, variant_facts = [], []
            for phase, directory in (('before', args.before), ('after', args.after)):
                path = directory / ('zero_page_scalar_' + variant + '.prg')
                im = Image(lib, path)
                assert im.run is not None, 'Peddle batch ABI required'
                pair.append(im)
                variant_facts.append(metadata(im, variant, phase))
                mapping, info, claims = variant_facts[-1]
                entry.append(dict(variant=variant, phase=phase, artifact=str(path), prg_sha256=digest(path), **run_entry(im, mapping, info, variant)))
                # Explicitly initialize compact fixed placements for subsequent
                # direct native calls. Full entry proof above executed the real copier.
                payload = path.read_bytes()
                load = int.from_bytes(payload[:2], 'little')
                for placement in mapping.get('memory_placements', []):
                    if placement['load'] == 'startup_copy':
                        for offset in range(placement['size']):
                            im.write(im.machine, placement['run_start'] + offset, payload[2 + placement['load_start'] - load + offset])
            images[variant] = pair
            facts[variant] = variant_facts
            if variant in ('scratch_control', 'asm', 'main_export'):
                assert pair[0].path.read_bytes() == pair[1].path.read_bytes(), (variant, 'protected/default scratch binary changed')

        def check(variant, function, arguments, seed, status, expected, memory=None, byte=False, expected_memory=None):
            if variant not in images:
                return
            memory = memory or {}
            results = [seed_call(im, OBJECTS[variant], fact[1], function, arguments, seed, status, memory)
                       for im, fact in zip(images[variant], facts[variant])]
            states = [(r[0].a, r[0].x, r[0].y, r[0].p, r[0].sp) for r in results]
            assert states[0] == states[1], (variant, function, arguments, seed, status, 'A/X/Y/P/SP mismatch', states)
            assert results[0][1:] == results[1][1:], (variant, function, arguments, seed, status, 'named source objects/pointer/RAM mismatch', results[0][1:], results[1][1:])
            if function == 'readPair':
                expected_memory = memory
            if expected_memory is not None:
                expected_bytes = bytes(expected_memory[address] for address in sorted(memory))
                assert results[0][3] == expected_bytes and results[1][3] == expected_bytes, (variant, function, 'independent visible-memory oracle')
            if function in ('aliasByte', 'aliasWord') and isinstance(arguments.get('location'), Ref):
                ref = arguments['location']
                width = 1 if function == 'aliasByte' else 2
                mask = (0x55 if width == 1 else 0x5a) << (8 * ref.offset)
                expected_value = ((arguments['value'] ^ mask) & ((1 << (width * 8)) - 1)).to_bytes(width, 'little').hex()
                assert results[0][1][ref.label] == expected_value and results[1][1][ref.label] == expected_value, (variant, function, 'independent aliased parameter store oracle')
            actual = results[1][0].a if byte else results[1][0].a | (results[1][0].x << 8)
            assert actual == expected, (variant, function, arguments, seed, status, 'independent oracle', actual, expected)
            key = variant + ':' + function + (':alias' if any(isinstance(value, Ref) for value in arguments.values()) else '')
            row = totals.setdefault(key, dict(cases=0, decimal_cases=0, before_cycles=0, after_cycles=0, slower_cases=0))
            row['cases'] += 1
            row['decimal_cases'] += bool(status & 8)
            row['before_cycles'] += results[0][0].cycles
            row['after_cycles'] += results[1][0].cycles
            row['slower_cases'] += results[1][0].cycles > results[0][0].cycles

        def word_mix(value, mask):
            return ((((value << 3) & 65535) ^ 0x55aa) & mask) | 0x0100

        for variant in ('values', 'scratch_control'):
            for value in range(256):
                for bits in range(64):
                    status = flags(bits)
                    other = value ^ 0xa5
                    check(variant, 'byteMix', {'left': value, 'right': other}, value, status, ((value ^ 0x55) | other) & 0xdf, byte=True)
                    address = 0xc100 + value
                    word = (value * 257) ^ 0x81ff
                    data = {address: word & 255, address + 1: word >> 8}
                    check(variant, 'readPair', {'location': address, 'mask': 0x55aa}, value, status, word ^ 0x55aa, data)
                    check(variant, 'identityPointer', {'location': address}, value, status, address)
            for value in BOUNDARIES:
                for mask in (0, 0x00ff, 0x8100, 0xffff):
                    for bits in range(64):
                        status = flags(bits)
                        check(variant, 'wordMix', {'left': value, 'right': mask}, value ^ mask, status, word_mix(value, mask))
                        check(variant, 'nonleaf', {'value': value, 'mask': mask}, value ^ mask, status, word_mix(value, mask) ^ word_mix(mask, value))
                for state in (0, 2, 7):
                    for bits in range(64):
                        check(variant, 'enumMask', {'state': state, 'value': value}, value, flags(bits), value ^ 0x55aa if state == 2 else value | 0x0101)
            for left in (0, 1):
                for right in (0, 1):
                    for bits in range(64):
                        check(variant, 'boolean', {'left': left, 'right': right}, bits, flags(bits), int(not left or right), byte=True)
            if variant in images:
                print(variant + ': byte/word/bool/enum/pointer/nonleaf combinations passed', flush=True)
        for value in range(256):
            for bits in range(64):
                status = flags(bits)
                check('alias', 'aliasByte', {'value': value, 'location': Ref('aliasByte_value')}, value, status, 0x55)
                check('alias', 'aliasByte', {'value': value, 'location': 0xc1ff}, value, status, 0,
                      {0xc1fe: 0x12, 0xc1ff: value, 0xc200: 0x34},
                      expected_memory={0xc1fe: 0x12, 0xc1ff: value ^ 0x55, 0xc200: 0x34})
        for value in range(65536):
            status = flags(value & 63)
            for offset, expected in ((0, 0x005a), (1, 0x5a00)):
                check('alias', 'aliasWord', {'value': value, 'location': Ref('aliasWord_value', offset)}, value, status, expected)
            if 'alias' in images and (value + 1) % 16384 == 0:
                print(f'aliasWord: all low/high byte aliases through {value}', flush=True)
        for value in BOUNDARIES:
            for bits in range(64):
                status = flags(bits)
                for function, expected in (('eligible', value ^ 0x1111), ('publicValue', value ^ 0x55aa),
                                           ('configured', value ^ 0x2222), ('placed', value | 0x0101)):
                    check('barriers', function, {'value': value}, value, status, expected)
                if status & 8 == 0:
                    check('barriers', 'stackCall', {'value': value}, value, status, (value + 1) & 65535,
                          {0xc800 + offset: (offset * 17 + 3) & 255 for offset in range(256)})
                check('asm', 'otherwiseEligible', {'value': value}, value, status, value ^ 0x55aa)
        for value in range(256):
            for bits in range(64):
                status = flags(bits)
                check('barriers', 'escaped', {'value': value}, value, status, value ^ 0x55)
                check('asm', 'asmBarrier', {'value': value}, value, status, value ^ 0x55, byte=True)
                check('main_export', 'main', {'value': value}, value, status, value ^ 0x55, byte=True)
        for bits in range(64):
            check('barriers', 'cycle', {'value': 0}, bits, flags(bits), 3, byte=True)
        if 'stack_bridge' in images:
            for value in BOUNDARIES:
                for bits in range(64):
                    status = flags(bits)
                    check('stack_bridge', 'leaf', {'value': value, 'mask': 0x55}, value, status, value ^ 0x55)
                    if status & 8 == 0:
                        check('stack_bridge', 'invoke', {'value': value}, value, status, value ^ 0x55,
                              {0xc800 + offset: (offset * 17 + 3) & 255 for offset in range(256)})
        if 'reserved' in images:
            for value in range(256):
                for bits in range(64):
                    check('reserved', 'reservedStore', {'value': value}, value, flags(bits), value * 257,
                          {2: (value + 17) & 255, 3: 0xa7}, expected_memory={2: value ^ 0x55, 3: 0xa7})
        report = dict(format='zeropage-private-scalar-proof-v1', status='success',
                      pairs=sum(row['cases'] for row in totals.values()), decimal_pairs=sum(row['decimal_cases'] for row in totals.values()),
                      functions=totals, entry=entry, selected_variants=sorted(selected),
                      objects={variant: [obj.__dict__ for obj in descriptors] for variant, descriptors in OBJECTS.items()},
                      checks=['complete A/X/Y/P/SP', 'every individually named source parameter/local', 'source-object label/claim/static-frame coverage',
                              'explicit pointer object identity', 'fixed external word page crossings', 'all word values at both byte aliases',
                              'all byte/64-flag combinations', 'typed bool/enum/word/pointer arguments', 'known nonleaf calls',
                              'export/main/ABI/placement/address/ASM/SCC/stack exclusions', 'unchanged scratch-control binary',
                              'actual entry/return restoration including promoted parameters', 'live caller stack canaries',
                              'software-stack caller to promoted static callee', 'explicit app-owned low-byte reservation and persistent source store'],
                      normalization='Pointer-typed object values and compiler pointer scratch compare verified named source-object identity/byte offset; all nonpointer object bytes compare exactly. No frame-relative masking.',
                      decimal_scope='Pure ALU and fixed-address dereference cases test exact CPU state and independent results with D set; software-stack bridge runs binary mode only because decimal stack-address arithmetic is outside this pass.',
                      cycle_scope='Direct kernel CPU cycles excluding final top-level RTS; full entry rows include lifecycle and exclude intercepted test hooks.')
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        print(f"Passed {report['pairs']} paired calls, {report['decimal_pairs']} decimal; slower cases {sum(row['slower_cases'] for row in totals.values())}", flush=True)
    finally:
        for pair in images.values():
            for im in pair:
                im.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', type=Path, required=True)
    parser.add_argument('--after', type=Path, required=True)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--variants', help='Optional comma-separated fixture subset; report remains explicitly targeted')
    verify(parser.parse_args())
