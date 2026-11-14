#!/usr/bin/env python3
"""Paired Peddle source/ABI proof for call-argument staging.

Compile the same seven call_argument_*.zp64 fixtures into --before/--after.
No compiler options or assembly-shape oracle are involved. Explicit named source
objects are checked independently of code/frame relocation. Software-stack cases
use D=0; static pure-ALU cases cover every C/Z/I/D/V/N input combination.
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


VALUES = (
    objects('byteFold', [('value', 1, False), ('mask', 1, False), ('tail', 1, False)]) +
    objects('wordFold', [('value', 2, False), ('mask', 2, False), ('tail', 1, False)]) +
    objects('enumFold', [('value', 1, False), ('state', 1, False), ('mask', 1, False)]) +
    objects('pointerFold', [('value', 1, False), ('location', 2, True), ('mask', 1, False)]) +
    objects('byteCase', [('location', 2, True), ('mask', 1, False)], [('saved', 1, False)]) +
    objects('wordCase', [('location', 2, True), ('mask', 2, False)], [('saved', 2, False)]) +
    objects('enumCase', [('location', 2, True), ('state', 1, False), ('mask', 1, False)]) +
    objects('pointerCase', [('location', 2, True), ('other', 2, True), ('mask', 1, False)]) +
    objects('main', locals=[('location', 2, True), ('byte_location', 2, True), ('other', 2, True)])
)
NESTED = (
    objects('combine', [('value', 2, False), ('mask', 2, False)]) +
    objects('inner', [('value', 2, False), ('mask', 2, False)]) +
    objects('nested', [('location', 2, True), ('mask', 2, False)]) +
    objects('rotate', [('left', 2, False), ('right', 2, False), ('depth', 1, False)]) +
    objects('swapCase', [('left', 2, False), ('right', 2, False)]) +
    objects('main', locals=[('location', 2, True)])
)
ALIASES = (
    objects('pair', [('value', 2, False), ('mask', 2, False)]) +
    objects('mutate', [('location', 2, True)]) + objects('aliasCase', [('location', 2, True)]) +
    objects('escapedCase', [('value', 2, False)], [('location', 2, True)]) +
    objects('volatilePair', [('value', 1, False), ('mask', 1, False)]) +
    objects('volatileCase', [('location', 2, True), ('other', 2, True)]) +
    objects('main', locals=[('location', 2, True), ('first', 2, True), ('second', 2, True)])
)
ASM = (objects('opaqueLeaf', [('value', 2, False), ('mask', 2, False)]) +
       objects('asmCase', [('location', 2, True), ('mask', 2, False)]) +
       objects('main', locals=[('location', 2, True)]))
BOUNDARIES = (objects('publicLeaf', [('value', 2, False), ('mask', 2, False)]) +
              objects('publicCase', [('location', 2, True), ('mask', 2, False)]) +
              objects('stackCase', [('location', 2, True), ('mask', 2, False)]) +
              objects('main', locals=[('location', 2, True)]))
MODULE = objects('moduleCase', [('location', 2, True), ('mask', 2, False)]) + objects('main', locals=[('location', 2, True)])
OBJECTS = dict(values=VALUES, resident=VALUES, nested=NESTED, alias=ALIASES,
               asm=ASM, boundaries=BOUNDARIES, module=MODULE)
BOUNDARIES16 = (0, 1, 2, 7, 127, 128, 255, 256, 257, 0x7fff, 0x8000, 0x80ff, 0xff00, 0xfffe, 0xffff)
LIVE_STACK = dict(enumerate((0x34, 0x12, 0xa5, 0x5a, 0x69, 0x96), 0x1fa))
GUARDS = {0xc0ff: 0xa6, 0xc300: 0x59, 0xc3ff: 0x96, 0xc401: 0x69, 0xc700: 0x3c, 0xc7ff: 0xc3, 0xc900: 0x5a}


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
                    match = re.fullmatch('zeropage_test6502_expect_equal_(u8|u16)_[0-9a-f]+_([0-9a-f]+)', name)
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


def verify(args):
    library = c.CDLL(str(args.library.resolve()))
    selected = set(args.variants.split(',')) if args.variants else set(OBJECTS)
    assert selected <= OBJECTS.keys(), selected - OBJECTS.keys()
    pairs, totals, entries, artifacts = {}, {}, [], []
    decimal_cases = 0
    try:
        for variant in OBJECTS:
            if variant not in selected:
                continue
            pair = []
            for phase, directory in (('before', args.before), ('after', args.after)):
                path = directory / ('call_argument_' + variant + '.prg')
                im = Image(library, path); facts = metadata(im, variant)
                pair.append((im, facts))
                artifacts.append(dict(variant=variant, phase=phase, prg=str(path), prg_sha256=digest(path), bytes=path.stat().st_size))
                entries.append(dict(variant=variant, phase=phase, **run_main(im, variant)))
            pairs[variant] = pair

        def check(variant, function, arguments, memory, value, case_seed, status, width=2,
                  expected_memory=None, named_oracles=None, suffix=''):
            nonlocal decimal_cases
            if variant not in pairs:
                return
            results = []
            for im, facts in pairs[variant]:
                seed(im, variant, facts[1], function, arguments, memory, case_seed, status)
                r = execute(im, variant, facts[2])
                actual = r[0].a | (r[0].x << 8) if width == 2 else r[0].a
                assert actual == value, (variant, function, arguments, case_seed, status, 'source result', actual, value)
                observed = {a: im.read(im.machine, a) for a in memory}
                assert observed == (memory if expected_memory is None else expected_memory), (variant, function, 'visible memory oracle', observed, expected_memory)
                for label, expected in (named_oracles or {}).items():
                    assert r[3][label] == expected, (variant, function, 'named object oracle', label, r[3][label], expected)
                results.append((r, observed))
            b, a = results[0][0], results[1][0]
            assert b[1:] == a[1:], (variant, function, arguments, case_seed, status, 'AXYP/SP, pre-JSR state, named object or pointer mismatch', b[1:], a[1:])
            key = variant + ':' + function + suffix
            row = totals.setdefault(key, dict(cases=0, decimal_cases=0, before_cycles=0, after_cycles=0, before_instructions=0, after_instructions=0, slower_cases=0, traced_user_calls=0))
            row['cases'] += 1; row['decimal_cases'] += bool(status & 8); decimal_cases += bool(status & 8)
            row['before_cycles'] += b[0].cycles; row['after_cycles'] += a[0].cycles
            row['before_instructions'] += b[0].instructions; row['after_instructions'] += a[0].instructions
            row['slower_cases'] += a[0].cycles > b[0].cycles
            row['traced_user_calls'] += len(a[2])

        for bits in range(64):
            status = flags(bits)
            for index, word in enumerate(BOUNDARIES16):
                seed_value = index * 17 + bits
                low = (index * 37) & 255
                address = 0xc100 + low
                mask = BOUNDARIES16[(index + 5) % len(BOUNDARIES16)]
                memory = {address: word & 255, address + 1: word >> 8, 0xc400: 0x42}
                byte_mask = mask & 255
                for variant in ('values', 'resident'):
                    check(variant, 'byteCase', {'location': address, 'mask': byte_mask}, memory,
                          (word & 255) ^ byte_mask ^ 0x55 ^ 0x81, seed_value, status, 1)
                    check(variant, 'wordCase', {'location': address, 'mask': mask}, memory,
                          word ^ mask ^ 0xa55a ^ 0x81, seed_value, status)
                    mode = (0, 2, 7)[index % 3]
                    check(variant, 'enumCase', {'location': address, 'state': mode, 'mask': byte_mask}, memory,
                          ((word & 255) ^ byte_mask) if mode == 2 else ((word & 255) | byte_mask), seed_value, status, 1)
                    check(variant, 'pointerCase', {'location': address, 'other': 0xc400, 'mask': byte_mask}, memory,
                          (word & 255) ^ 0x42 ^ byte_mask, seed_value, status, 1)
                    # A native caller may alias a callee parameter that direct
                    # stores are about to overwrite. The first load must happen first.
                    target = 'wordFold_mask'
                    initial = scalar_seed(next(i for i, o in enumerate(OBJECTS[variant]) if o.label == target), seed_value)
                    check(variant, 'wordCase', {'location': Ref(target), 'mask': mask}, memory,
                          initial ^ mask ^ 0xa55a ^ 0x81, seed_value, status, suffix=':native_alias')
                check('nested', 'nested', {'location': address, 'mask': mask}, memory,
                      word ^ mask ^ 0xa55a, seed_value, status)
                check('nested', 'swapCase', {'left': word, 'right': mask}, memory,
                      ((mask << 1) & 65535) ^ word, seed_value, status)
                changed = dict(memory); changed[address] ^= 0xaa; changed[address + 1] ^= 0x55
                check('alias', 'aliasCase', {'location': address}, memory, 0x55aa, seed_value, status,
                      expected_memory=changed)
                check('alias', 'escapedCase', {'value': word}, memory, 0x55aa, seed_value, status,
                      named_oracles={'escapedCase_value': (word ^ 0x55aa).to_bytes(2, 'little').hex()})
                # Peddle's bridge toggles raster reads and increments CIA timer
                # reads. These independent stateful models expose missing/reordered
                # volatile accesses without claiming complete VIC/CIA emulation.
                volatile = {0xd012: word & 255, 0xd020: byte_mask}
                check('alias', 'volatileCase', {'location': 0xd012, 'other': 0xd020}, volatile,
                      1 ^ byte_mask, seed_value, status, 1)
                check('alias', 'volatileCase', {'location': 0xdc04, 'other': 0xdc04}, {},
                      3, seed_value, status, 1, suffix=':stateful_read_order',
                      named_oracles={'volatilePair_value': '01', 'volatilePair_mask': '02'})
                check('asm', 'asmCase', {'location': address, 'mask': mask}, memory,
                      word ^ mask, seed_value, status)
                check('boundaries', 'publicCase', {'location': address, 'mask': mask}, memory,
                      word ^ mask, seed_value, status)
                if not status & 8:
                    check('boundaries', 'stackCase', {'location': address, 'mask': mask}, memory,
                          (word + mask) & 65535, seed_value, status)
                    check('module', 'moduleCase', {'location': address, 'mask': mask}, memory,
                          (word + mask) & 65535, seed_value, status)
            if (bits + 1) % 16 == 0:
                print('Verified status combinations', bits + 1, 'of64', flush=True)
        result = dict(format='zeropage-call-argument-equivalence-v1', status='success',
                      selected_variants=sorted(selected), cases=sum(r['cases'] for r in totals.values()),
                      decimal_cases=decimal_cases, functions=totals, entries=entries, artifacts=artifacts,
                      checks=['independent source arithmetic and mutation oracles', 'complete exit A/X/Y/P/SP',
                              'actual pre-JSR A/X/Y/P/SP and each named static callee parameter',
                              'every individually declared source parameter/local with verified width/frame extent',
                              'named-object identity for explicitly pointer-typed values only; no broad frame masks',
                              'external RAM/MMIO-injected value canaries and live caller stack',
                              'main assertion hooks continue to final top-level RTS boundary'],
                      scope='Static pure-ALU cases cover all64 C/Z/I/D/V/N combinations, including D. Software-stack/module cases use D=0 because stack-address ADC is binary ABI arithmetic. Pointer reads use fixed external addresses or explicitly named private objects; no BCD arithmetic on moving private frame bases. Peddle bridge models raster reads as alternating1/0 and CIA timer reads as incrementing1/2; these targeted stateful MMIO oracles do not claim complete VIC/CIA behavior.',
                      cycle_scope='Peddle CPU cycles excluding final native top RTS; source main entries include lifecycle costs.')
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
        print('PASS', result['cases'], 'paired calls;', decimal_cases, 'D-set cases;', sum(r['slower_cases'] for r in totals.values()), 'slower cases', flush=True)
    finally:
        for pair in pairs.values():
            for im, _ in pair:
                im.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('before', 'after', 'library', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--variants', help='comma-separated subset; default all seven fixtures')
    verify(parser.parse_args())


if __name__ == '__main__':
    main()
