#!/usr/bin/env python3
"""Paired native ABI/source proof for final-word argument capture.

Preserves complete pre-JSR and exit AXYP/SP. Only explicitly typed source pointer
objects use logical object identity; CPU registers/flags are never masked. ROM
fixture compilation/direct consume proof is separate from the deferred real-ROM
SYS/return gate. Compile identical sources before/after into private directories.
"""
import argparse
import ctypes as c
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
from verify_pointer_reuse import Image

@dataclass(frozen=True)
class Object:
    label: str
    width: int
    pointer: bool = False
    parameter: bool = False

@dataclass(frozen=True)
class Ref:
    label: str
    offset: int = 0

def objects(function, params=(), locals=()):
    return [Object(function + '_' + n, w, p, True) for n, w, p in params] + [
        Object(function + '_' + n, w, p) for n, w, p in locals]

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def flags(bits):
    return (bits & 15) | ((bits & 16) << 2) | ((bits & 32) << 2)

def metadata(im, variant):
    mapping = json.loads(Path(str(im.path) + '.zpmap.json').read_text())
    info = mapping.get('zero_page', {})
    claims = info.get('claims', [])
    descriptors = OBJECTS[variant]
    expected = {o.label for o in descriptors}
    present = set()
    asm = Path(str(im.path) + '.asm').read_text()
    # Legacy integer-valued runtime aliases are omitted by 64tass VICE labels.
    # Resolve only these explicit literal aliases, checking any label agreement.
    for name in ('zeropage_ptr_tmp', 'zeropage_string_ptr', 'zeropage_stack_sp', 'zeropage_stack_fp'):
        alias = re.search(r'^' + name + r' = (?:address\()?\$([0-9a-fA-F]+)\)?$', asm, re.M)
        if alias:
            address = int(alias[1], 16)
            assert name not in im.labels or im.labels[name] == address
            im.labels[name] = address
    for section in mapping['sections']:
        if section['kind'] != 'static_frame':
            continue
        names = set(section['labels'])
        assert names <= expected, (variant, 'unmodeled source objects', names - expected)
        assert section['size'] == sum(o.width for o in descriptors if o.label in names), (variant, 'source frame extent', section)
        present |= names
    parameter_claims = {cl['label']: cl for cl in claims if cl['kind'] == 'parameter'}
    present |= set(parameter_claims)
    assert present == expected, (variant, 'incomplete source object manifest', present ^ expected)
    for obj in descriptors:
        assert obj.label in im.labels, (variant, 'missing typed source object', obj)
        if obj.label in parameter_claims:
            cl = parameter_claims[obj.label]
            assert obj.parameter and cl['size'] == obj.width and cl['addr'] == im.labels[obj.label], (variant, obj, cl)
        else:
            form = re.search(r'^' + re.escape(obj.label) + r':\s*\n\s*(\.word 0|\.byte 0(?:,0)?)\s*$', asm, re.M)
            assert form and (2 if form[1] in ('.word 0', '.byte 0,0') else 1) == obj.width, (variant, 'source storage width', obj)
    occupied = set()
    for claim in claims:
        addresses = set(range(claim['addr'], claim['addr'] + claim['size']))
        assert not occupied & addresses and addresses <= set(range(2, 256)), (variant, 'overlapping/invalid claims', claim)
        occupied |= addresses
    functions = {s['owner'][9:]: s['start'] for s in mapping['sections'] if s['kind'] == 'code' and s['owner'].startswith('function:')}
    return mapping, info, functions

def identity(im, descriptors, value):
    for obj in descriptors:
        start = im.labels[obj.label]
        if start <= value < start + obj.width:
            return ('source_object', obj.label, value - start)
    return ('absolute', value)

def snapshots(im, descriptors):
    result = {}
    for obj in descriptors:
        data = bytes(im.read(im.machine, im.labels[obj.label] + j) for j in range(obj.width))
        result[obj.label] = identity(im, descriptors, int.from_bytes(data, 'little')) if obj.pointer else data.hex()
    return result

def scalar_seed(index, seed):
    return ((seed * 257) ^ (index * 131 + 0x8155)) & 65535

def seed(im, variant, info, function, arguments, memory, case_seed, status):
    m = im.machine
    im.reset(m)
    im.set_pc(m, im.labels[function])
    im.set_sp(m, 0xf9)
    im.set_a(m, (case_seed + 0x23) & 255)
    im.set_x(m, (case_seed ^ 0x89) & 255)
    im.set_y(m, (case_seed ^ 0x67) & 255)
    im.set_p(m, 0x20 | status)
    for address in range(256):
        im.write(m, address, (address * 73 + case_seed) & 255)
    for claim in info.get('claims', []):
        if claim['kind'] == 'scratch':
            for address in range(claim['addr'], claim['addr'] + claim['size']):
                im.write(m, address, 0)
    for index, obj in enumerate(OBJECTS[variant]):
        value = 0xc600 + index * 2 if obj.pointer else scalar_seed(index, case_seed)
        for offset in range(obj.width):
            im.write(m, im.labels[obj.label] + offset, (value >> (offset * 8)) & 255)
    for name, value in arguments.items():
        obj = next(o for o in OBJECTS[variant] if o.label == function + '_' + name and o.parameter)
        if isinstance(value, Ref):
            target = next(o for o in OBJECTS[variant] if o.label == value.label)
            assert 0 <= value.offset < target.width
            value = im.labels[value.label] + value.offset
        for offset in range(obj.width):
            im.write(m, im.labels[obj.label] + offset, (value >> (offset * 8)) & 255)
    for address, value in memory.items():
        im.write(m, address, value)
    for address, value in (LIVE_STACK | GUARDS).items():
        im.write(m, address, value)
    for name, value in (('zeropage_ptr_tmp', 0xc5a5), ('zeropage_string_ptr', 0xc55a),
                        ('zeropage_stack_sp', 0xc800), ('zeropage_stack_fp', 0xc800)):
        if name in im.labels:
            address = im.labels[name]
            im.write(m, address, value & 255)
            im.write(m, address + 1, value >> 8)
    return snapshots(im, OBJECTS[variant])

def execute(im, variant, functions):
    """Trace user-callee entry AXYP/SP, then stop before the native top RTS."""
    m = im.machine
    descriptors = OBJECTS[variant]
    by_address = {address: name for name, address in functions.items()}
    events = []
    for _ in range(10000):
        regs = im.regs(m)
        opcode = im.read(m, regs.pc)
        if opcode == 0x20:
            target = im.read(m, regs.pc + 1) | im.read(m, regs.pc + 2) << 8
            if target in by_address:
                name = by_address[target]
                # JSR changes SP by two and PC only. Record the actual pre-JSR
                # state without copying/masking any live register or flag.
                all_objects = snapshots(im, descriptors)
                params = {o.label: all_objects[o.label] for o in descriptors
                          if o.parameter and o.label.startswith(name + '_')}
                events.append((name, (regs.a, regs.x, regs.y, regs.p, regs.sp), params))
        assert opcode != 0, (im.path, 'BRK', hex(regs.pc))
        if opcode == 0x60 and regs.sp == 0xf9:
            break
        im.step(m)
    else:
        raise AssertionError((im.path, 'instruction budget'))
    state = (regs.a, regs.x, regs.y, regs.p, regs.sp)
    assert regs.sp == 0xf9
    for address, value in (LIVE_STACK | GUARDS).items():
        assert im.read(m, address) == value, (im.path, 'caller/external canary changed', hex(address))
    pointers = {}
    for name in ('zeropage_ptr_tmp', 'zeropage_string_ptr', 'zeropage_stack_sp', 'zeropage_stack_fp'):
        if name in im.labels:
            address = im.labels[name]
            raw = im.read(m, address) | im.read(m, address + 1) << 8
            pointers[name] = identity(im, descriptors, raw)
    return regs, state, events, snapshots(im, descriptors), pointers

def run_main(im, variant):
    """Run assertion hooks as independent results, to the normal final RTS boundary."""
    m = im.machine
    mapping, info, _ = metadata(im, variant)
    entry = 'zeropage_entry' if 'zeropage_entry' in im.labels else 'main'
    seed(im, variant, info, 'main', {}, {}, 0x42, 0)
    im.set_pc(m, im.labels[entry])
    hooks = {address: name for name, address in im.labels.items() if name.startswith('zeropage_test6502_')}
    hits = 0
    for _ in range(100000):
        regs = im.regs(m); opcode = im.read(m, regs.pc)
        if opcode == 0x20:
            target = im.read(m, regs.pc + 1) | im.read(m, regs.pc + 2) << 8
            if target in hooks:
                name = hooks[target]; hits += 1
                if name != 'zeropage_test6502_pass':
                    match = re.fullmatch('zeropage_test6502_expect_equal_(u8|u16|i8)_[0-9a-f]+_([0-9a-f]+)', name)
                    assert match, (im.path, 'unknown assertion hook', name)
                    expected = int(match[2], 16)
                    actual = regs.a | regs.x << 8 if match[1] == 'u16' else regs.a
                    assert actual == expected, (im.path, name, actual, expected)
                im.set_pc(m, regs.pc + 3)
                continue
        assert opcode != 0, (im.path, 'main BRK', hex(regs.pc))
        if opcode == 0x60 and regs.sp == 0xf9:
            assert hits >= 2
            return dict(cycles=regs.cycles, instructions=regs.instructions, assertion_hooks=hits)
        im.step(m)
    raise AssertionError((im.path, 'main budget'))

VALUES = (
    objects('singleWord', [('value', 2, False)]) + objects('singleSize', [('value', 2, False)]) +
    objects('singleSigned', [('value', 2, False)]) + objects('singlePointer', [('location', 2, True)]) +
    objects('wordCase', [('location', 2, True)]) + objects('sizeCase', [('location', 2, True)]) +
    objects('signedCase', [('location', 2, True)]) + objects('pointerCase', [('location', 2, True)]) +
    objects('main', locals=[('word', 2, True), ('size', 2, True), ('signed', 2, True), ('byte', 2, True)])
)
MIXED = (
    objects('mixed', [('byte', 1, False), ('word', 2, False)]) + objects('identity', [('value', 2, False)]) +
    objects('mixedCase', [('location', 2, True), ('byte', 1, False)]) +
    objects('twoPointers', [('first', 2, True), ('second', 2, True)]) +
    objects('nestedCase', [('location', 2, True), ('byte', 1, False)]) +
    objects('main', locals=[('word', 2, True), ('byte', 2, True)])
)
RESERVED = (objects('reservedWord', [('value', 2, False)], [('application', 2, True)]) +
            objects('reservedCase', [('location', 2, True)]) +
            objects('main', locals=[('word', 2, True), ('application', 2, True)]))
ROM = (objects('consume', [('value', 2, False)]) +
       objects('liveAcrossRom', [('value', 2, False), ('mask', 2, False)],
               [('key', 1, False), ('observed_key', 2, True), ('tick', 2, True), ('before', 1, False),
                ('tick_before', 2, True), ('tick_after', 2, True)]) +
       objects('main', locals=[('complete', 2, True), ('output', 2, True)]))
OBJECTS = dict(values=VALUES, mixed=MIXED, reserved=RESERVED, rom_roundtrip=ROM)
BOUNDARIES16 = (0, 1, 2, 7, 127, 128, 255, 256, 257, 0x7fff, 0x8000, 0x80ff, 0xff00, 0xfffe, 0xffff)
LIVE_STACK = dict(enumerate((0x34, 0x12, 0xa5, 0x5a, 0x69, 0x96), 0x1fa))
GUARDS = {0xc0ff: 0xa6, 0xc300: 0x59, 0xc3ff: 0x96, 0xc401: 0x69, 0xc700: 0x3c, 0xc7ff: 0xc3, 0xc900: 0x5a}


def verify(args):
    lib = c.CDLL(str(args.library.resolve())); pairs, totals, entries, artifacts = {}, {}, [], []
    try:
        for variant in OBJECTS:
            pair = []
            for phase, folder in (('before', args.before), ('after', args.after)):
                path = folder / ('last_word_argument_' + variant + '.prg')
                im = Image(lib, path); facts = metadata(im, variant); pair.append((im, facts))
                artifacts.append(dict(variant=variant, phase=phase, path=str(path), prg_sha256=digest(path), bytes=path.stat().st_size))
                if variant in ('reserved', 'rom_roundtrip'):
                    claimed = {a for cl in facts[1]['claims'] for a in range(cl['addr'], cl['addr'] + cl['size'])}
                    assert claimed <= set(range(0x24, 0x70)) and not claimed & set(range(0x20, 0x24))
                if variant != 'rom_roundtrip':
                    entries.append(dict(variant=variant, phase=phase, **run_main(im, variant)))
                    if variant == 'reserved':
                        assert im.read(im.machine, 0x20) == 0xa5
                        for a in range(0x21, 0x24):
                            assert im.read(im.machine, a) == (a * 73 + 0x42) & 255, (phase, 'app reservation canary', a)
            pairs[variant] = pair

        def check(variant, function, arguments, expected, seed_value, status, memory, width=2, mutated=None, suffix=''):
            results = []
            for im, facts in pairs[variant]:
                seed(im, variant, facts[1], function, arguments, memory, seed_value, status)
                r = execute(im, variant, facts[2]); actual = r[0].a | r[0].x << 8 if width == 2 else r[0].a
                assert actual == expected, (variant, function, arguments, status, 'source result', actual, expected)
                observed = {a: im.read(im.machine, a) for a in memory}
                assert observed == (memory if mutated is None else memory | mutated), (variant, function, 'independent RAM effects', observed)
                results.append(r)
            b, a = results
            assert b[1:] == a[1:], (variant, function, arguments, status, 'pre-JSR/exit AXYP/SP, named source objects, typed pointer mismatch', b[1:], a[1:])
            key = variant + ':' + function + suffix
            row = totals.setdefault(key, dict(cases=0, decimal_cases=0, before_cycles=0, after_cycles=0,
                                             before_instructions=0, after_instructions=0, traced_user_calls=0, slower_cases=0))
            row['cases'] += 1; row['decimal_cases'] += bool(status & 8)
            row['before_cycles'] += b[0].cycles; row['after_cycles'] += a[0].cycles
            row['before_instructions'] += b[0].instructions; row['after_instructions'] += a[0].instructions
            row['traced_user_calls'] += len(a[2]); row['slower_cases'] += a[0].cycles > b[0].cycles

        for bits in range(64):
            status = flags(bits)
            for index, word in enumerate(BOUNDARIES16):
                seed_value = (index * 17 + bits) & 255; address = 0xc100 + (0, 1, 254, 255)[index % 4]
                byte = (word ^ 0x55 ^ bits) & 255
                memory = {address: word & 255, address + 1: word >> 8, 0xc400: byte}
                for function, expected in [('wordCase', word ^ 0x55aa), ('sizeCase', word ^ 0x0101), ('signedCase', word)]:
                    check('values', function, dict(location=address), expected, seed_value, status, memory)
                check('values', 'pointerCase', dict(location=address), word & 255, seed_value, status, memory, 1)
                for function in ('mixedCase', 'nestedCase'):
                    check('mixed', function, dict(location=address, byte=byte), word ^ ((byte ^ 0x55) << 8), seed_value, status, memory)
                check('mixed', 'twoPointers', dict(first=0xc400, second=address), word ^ (byte << 8), seed_value, status, memory)
                target = 'mixed_word'; initial = scalar_seed(next(i for i,o in enumerate(MIXED) if o.label == target), seed_value)
                check('mixed', 'twoPointers', dict(first=Ref(target), second=address), word ^ ((initial & 255) << 8), seed_value, status, memory, suffix=':early_alias')
                check('mixed', 'mixedCase', dict(location=Ref(target), byte=byte), initial ^ ((byte ^ 0x55) << 8), seed_value, status, memory, suffix=':final_alias')
                low_memory = memory | {0x20: 0x69, 0x21: 0x96, 0x22: 0x3c, 0x23: 0xc3}
                check('reserved', 'reservedCase', dict(location=address), word ^ 0x0101, seed_value, status, low_memory, mutated={0x20: 0xa5})
                check('rom_roundtrip', 'consume', dict(value=word), word, seed_value, status, memory)
            if (bits + 1) % 16 == 0:
                print('Verified flag combinations', bits + 1, 'of64', flush=True)
        report = dict(format='zeropage-final-word-argument-native-v1', status='success',
                      cases=sum(r['cases'] for r in totals.values()), decimal_cases=sum(r['decimal_cases'] for r in totals.values()),
                      functions=totals, entries=entries, artifacts=artifacts,
                      checks=['complete physical pre-JSR and exit A/X/Y/P/SP', 'all named source object widths/frame coverage',
                              'canonical identity only for pointer-typed source values; raw CPU registers unmasked',
                              'independent expected scalar returns and reserved application byte effects',
                              'callee parameter alias reads before final capture overwrites', 'live caller stack and fixed RAM guards'],
                      scope='All64 C/Z/I/D/V/N combinations at15 word boundaries, explicit low-byte0/1/FE/FF external pointers. Signed16 uses storage/identity only; pure XOR/shift and fixed external pointer reads avoid decimal frame arithmetic. ROM source is compiled and consume is tested directly; real CHROUT/GETIN/IRQ/SYS gate is deferred and not claimed here.',
                      cycle_scope='Native cycles exclude final top-level RTS; main assertion hooks are independently checked then intercepted.')
        args.output.parent.mkdir(parents=True, exist_ok=True); args.output.write_text(json.dumps(report, indent=2)+'\n')
        print('PASS', report['cases'], 'pairs;', report['decimal_cases'], 'D-set;', sum(r['slower_cases'] for r in totals.values()), 'slower cases', flush=True)
    finally:
        for pair in pairs.values():
            for im, _ in pair:im.close()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('before','after','library','output'):p.add_argument('--'+name,type=Path,required=True)
    verify(p.parse_args())


if __name__ == '__main__':main()
