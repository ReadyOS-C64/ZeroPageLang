#!/usr/bin/env python3
"""Paired Peddle proof for boolean materialization and ordered side effects.

The source corpus is Zig-shaped and uses only supported equality for signed
storage. Full byte-pair probes run in both D states; flag/word edge matrices
compare complete CPU state, verified named source objects and fixed RAM effects.
No assembly shape decides correctness. Compile the same sources in each phase.
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

def seed(im, variant, info, function, arguments, memory, case_seed, status, full_zp=False):
    m = im.machine
    im.reset(m)
    im.set_pc(m, im.labels[function])
    im.set_sp(m, 0xf9)
    im.set_a(m, (case_seed + 0x23) & 255)
    im.set_x(m, (case_seed ^ 0x89) & 255)
    im.set_y(m, (case_seed ^ 0x67) & 255)
    im.set_p(m, 0x20 | status)
    for address in (range(256) if full_zp else NATIVE_ZP_GUARDS):
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

VALUES = (
    objects('andBytes', [('left', 1, False), ('right', 1, False)]) +
    objects('orBytes', [('left', 1, False), ('right', 1, False)]) +
    objects('chooseByte', [('left', 1, False), ('right', 1, False)], [('selected', 1, False)]) +
    objects('mixedWords', [('left', 2, False), ('right', 2, False), ('gate', 1, False)], [('selected', 2, False)]) +
    objects('signedByte', [('left', 1, False), ('right', 1, False), ('gate', 1, False)]) +
    objects('signedWord', [('left', 2, False), ('right', 2, False), ('gate', 1, False)])
)
EFFECTS = (
    objects('touch', [('location', 2, True), ('mask', 1, False), ('answer', 1, False)]) +
    objects('sideEffects', [('left', 1, False), ('right', 1, False)], [('marker', 2, True), ('selected', 1, False)]) +
    objects('nestedEffects', [('left', 1, False), ('right', 1, False)], [('marker', 2, True)]) +
    objects('main', locals=[('marker', 2, True)])
)
VOLATILE = (
    objects('orderedReads', locals=[('timer', 2, True), ('observed', 2, True), ('selected', 1, False)]) +
    objects('guardedRead', [('gate', 1, False)], [('timer', 2, True), ('observed', 2, True), ('selected', 1, False)]) +
    objects('main', locals=[('observed', 2, True)])
)
ASM = objects('asmPredicate', [('left', 1, False), ('right', 1, False)]) + objects('asmBarrier', [('value', 1, False)])
UNUSED = objects('comparisonValue', [('left', 1, False), ('right', 1, False)]) + objects('storedValue', [('left', 2, False), ('right', 2, False)], [('saved', 1, False)])
OBJECTS = dict(values=VALUES, resident=VALUES, effects=EFFECTS, volatile=VOLATILE, asm=ASM, unused=UNUSED)
LIVE_STACK = dict(enumerate((0x34, 0x12, 0xa5, 0x5a, 0x69, 0x96), 0x1fa))
GUARDS = {0xc0ff: 0xa6, 0xc1ff: 0x59, 0xc202: 0x96, 0xc300: 0x69, 0xc700: 0x3c}
NATIVE_ZP_GUARDS = (0, 1, 0x30, 0x31, 0x3e, 0x3f, 0x70, 0x71, 0x80, 0x8f, 0x90, 0xa2, 0xaf, 0xf0, 0xf6, 0xff)
BYTE_EDGES = (0, 1, 2, 127, 128, 254, 255)
WORD_EDGES = (0, 1, 2, 127, 128, 255, 256, 257, 0x7fff, 0x8000, 0x80ff, 0xff00, 0xfffe, 0xffff)


def execute(im, variant, info, function, arguments, memory, seed_value, status):
    seed(im, variant, info, function, arguments, memory, seed_value, status)
    m = im.machine
    code = im.run(m, 0xf9, 50000)
    assert code == 0, (im.path, function, 'BRK/budget', code)
    r = im.regs(m)
    assert r.sp == 0xf9
    for address, expected in (LIVE_STACK | GUARDS).items():
        assert im.read(m, address) == expected, (im.path, function, 'caller/RAM guard', address)
    owned = {a for claim in info.get('claims', []) for a in range(claim['addr'], claim['addr'] + claim['size'])}
    for address in set(NATIVE_ZP_GUARDS) - owned:
        assert im.read(m, address) == (address * 73 + seed_value) & 255, (im.path, function, 'unclaimed ZP guard', address)
    pointer_words = {}
    for name in ('zeropage_ptr_tmp', 'zeropage_string_ptr'):
        if name in im.labels:
            address = im.labels[name]
            value = im.read(m, address) | im.read(m, address + 1) << 8
            pointer_words[name] = identity(im, OBJECTS[variant], value)
    ram = {a: im.read(m, a) for a in memory}
    return r, (r.a, r.x, r.y, r.p, r.sp), snapshots(im, OBJECTS[variant]), pointer_words, ram


def run_main(im, variant, mapping, info):
    seed(im, variant, info, 'main', {}, {0xc200: 0x96, 0xc201: 0x69}, 0x42, 0, full_zp=True)
    m = im.machine
    initial_zp = bytes(im.read(m, a) for a in range(256))
    im.set_pc(m, im.labels.get('zeropage_entry', im.labels['main']))
    hooks = {v: k for k, v in im.labels.items() if k.startswith('zeropage_test6502_')}
    main_section = next(s for s in mapping['sections'] if s['kind'] == 'code' and s['owner'] == 'function:main')
    hits = 0
    main_enter = main_return = None
    for _ in range(100000):
        r = im.regs(m); op = im.read(m, r.pc)
        if r.pc == im.labels['main'] and main_enter is None:
            main_enter = r.cycles
        if op == 0x20:
            target = im.read(m, r.pc + 1) | im.read(m, r.pc + 2) << 8
            if target in hooks:
                name = hooks[target]; hits += 1
                if name != 'zeropage_test6502_pass':
                    match = re.fullmatch('zeropage_test6502_expect_equal_(u8|u16|bool)_[0-9a-f]+_([0-9a-f]+)', name)
                    assert match, (im.path, name)
                    actual = r.a | r.x << 8 if match[1] == 'u16' else r.a
                    assert actual == int(match[2], 16), (im.path, name, actual)
                im.set_pc(m, r.pc + 3)
                continue
        if op == 0x60 and main_section['start'] <= r.pc < main_section['end'] and r.sp in (0xf7, 0xf9):
            main_return = r
        assert op != 0, (im.path, 'main BRK', r.pc)
        if op == 0x60 and r.sp == 0xf9:
            assert hits >= 3 and main_return is not None
            assert (r.a, r.x, r.y, r.p) == (main_return.a, main_return.x, main_return.y, main_return.p), (im.path, 'cleanup changed AXYP')
            owned = {a for cl in info.get('claims', []) for a in range(cl['addr'], cl['addr'] + cl['size'])}
            restored = owned & set(range(2, 0x90))
            for a in (set(range(256)) - owned) | restored:
                assert im.read(m, a) == initial_zp[a], (im.path, 'entry ZP lifecycle/canary', a)
            for a, v in LIVE_STACK.items():
                assert im.read(m, a) == v
            return dict(cycles=r.cycles, instructions=r.instructions, enter_cycles=main_enter,
                        body_cycles=main_return.cycles - main_enter, leave_cycles=r.cycles - main_return.cycles,
                        equality_and_pass_hooks=hits, restored_bytes=len(restored))
        im.step(m)
    raise AssertionError((im.path, 'main budget'))


def verify(args):
    lib = c.CDLL(str(args.library.resolve()))
    selected = set(args.variants.split(',')) if args.variants else set(OBJECTS)
    assert selected <= OBJECTS.keys(), selected - OBJECTS.keys()
    images, totals, entries, artifacts = {}, {}, [], []
    try:
        for variant in OBJECTS:
            if variant not in selected:
                continue
            pair = []
            for phase, folder in (('before', args.before), ('after', args.after)):
                path = folder / ('boolean_materialization_' + variant + '.prg')
                im = Image(lib, path); facts = metadata(im, variant)
                assert im.run is not None
                pair.append((im, facts))
                artifacts.append(dict(variant=variant, phase=phase, path=str(path), prg_sha256=digest(path), bytes=path.stat().st_size))
                entries.append(dict(variant=variant, phase=phase, **run_main(im, variant, facts[0], facts[1])))
            labels = lambda im: {name for name in im.labels if re.match(r'(?:cmp|cmp_word|bool_and|bool_or|if_expr|zeropage_cond|if|while|for)_', name)}
            assert labels(pair[0][0]) == labels(pair[1][0]), (variant, 'source/control label names changed')
            if variant in ('asm', 'unused'):
                assert pair[0][0].path.read_bytes() == pair[1][0].path.read_bytes(), (variant, 'negative control PRG changed')
            images[variant] = pair

        def check(variant, function, params, expected, seed_value, status, width=1, memory=None, mutated=None, suffix=''):
            if variant not in images:
                return
            memory = {0xc200: 0x96, 0xc201: 0x69} if memory is None else memory
            results = [execute(im, variant, facts[1], function, params, memory, seed_value, status) for im, facts in images[variant]]
            assert results[0][1:] == results[1][1:], (variant, function, params, status, 'AXYP/SP/source objects/pointers/RAM mismatch', results[0][1:], results[1][1:])
            expected_memory = memory if mutated is None else memory | mutated
            for r in results:
                actual = r[0].a | r[0].x << 8 if width == 2 else r[0].a
                assert actual == expected, (variant, function, params, status, 'independent result', actual, expected)
                assert r[4] == expected_memory, (variant, function, 'side-effect order/result', r[4], expected_memory)
                assert r[0].p & 0x4c == status & 0x4c, (variant, function, 'V/I/D not preserved')
                if variant in ('values', 'resident'):
                    assert r[0].p & 1, (variant, function, 'boolean CMP0 carry oracle')
            key = variant + ':' + function + suffix
            row = totals.setdefault(key, dict(cases=0, decimal_cases=0, before_cycles=0, after_cycles=0, before_instructions=0, after_instructions=0, slower_cases=0))
            row['cases'] += 1; row['decimal_cases'] += bool(status & 8)
            b, a = results[0][0], results[1][0]
            row['before_cycles'] += b.cycles; row['after_cycles'] += a.cycles
            row['before_instructions'] += b.instructions; row['after_instructions'] += a.instructions
            row['slower_cases'] += a.cycles > b.cycles

        if not args.edges_only and 'values' in images:
            for left in range(256):
                for right in range(256):
                    params = dict(left=left, right=right)
                    for status in (0, 8):
                        check('values', 'andBytes', params, int(left < right and right != 0), left ^ right, status, suffix=':exhaustive')
                        check('values', 'orBytes', params, int(left >= right), left ^ right, status, suffix=':exhaustive')
                if (left + 1) % 64 == 0:
                    print('Exhaustive left bytes', left + 1, 'of256', flush=True)
        for bits in range(64):
            status = flags(bits)
            for left in BYTE_EDGES:
                for right in BYTE_EDGES:
                    params = dict(left=left, right=right); seed_value = left ^ right ^ bits
                    for variant in ('values', 'resident'):
                        check(variant, 'andBytes', params, int(left < right and right != 0), seed_value, status)
                        check(variant, 'orBytes', params, int(left >= right), seed_value, status)
                        choose = (left < right and right < 128) or (left == 255 and right != 0)
                        check(variant, 'chooseByte', params, 0xa5 if choose else 0x5a, seed_value, status)
                        for gate in (0, 1):
                            check(variant, 'signedByte', params | dict(gate=gate), int((left == right or gate) and left != 128), seed_value, status)
                    check('effects', 'sideEffects', params, 0xa5 if left < right else 0x5a, seed_value, status,
                          mutated={0xc200: 1 if left < right else 2})
                    check('effects', 'nestedEffects', params, int(left == right), seed_value, status,
                          mutated={0xc200: 1 if left != right else (2 if left == 0 else 0)})
                    check('asm', 'asmPredicate', params, int(left <= right), seed_value, status)
                    check('unused', 'comparisonValue', params, int(left < right), seed_value, status)
            for left in WORD_EDGES:
                for right in WORD_EDGES:
                    seed_value = (left ^ right ^ bits) & 255
                    for gate in (0, 1):
                        params = dict(left=left, right=right, gate=gate)
                        for variant in ('values', 'resident'):
                            expected = (left <= right or gate) and (left != right or not gate)
                            check(variant, 'mixedWords', params, 0xa55a if expected else 0x5aa5, seed_value, status, width=2)
                            check(variant, 'signedWord', params, int((left != right and gate) or left == 32768), seed_value, status)
                    check('unused', 'storedValue', dict(left=left, right=right), int(left == right), seed_value, status)
            check('volatile', 'orderedReads', {}, 1, bits, status, mutated={0xc201: 3})
            for gate in (0, 1):
                check('volatile', 'guardedRead', dict(gate=gate), 0xa5 if gate else 0x5a, bits, status, mutated={0xc201: 2})
            check('asm', 'asmBarrier', dict(value=bits * 3 & 255), bits * 3 & 255, bits, status)
            if (bits + 1) % 16 == 0:
                print('Verified status combinations', bits + 1, 'of64', flush=True)
        report = dict(format='zeropage-boolean-materialization-equivalence-v1', status='success', selected_variants=sorted(selected),
                      exhaustive_byte_pairs=not args.edges_only and 'values' in images,
                      cases=sum(r['cases'] for r in totals.values()), decimal_cases=sum(r['decimal_cases'] for r in totals.values()),
                      functions=totals, entries=entries, artifacts=artifacts,
                      checks=['independent boolean/arithmetic and ordered-side-effect oracles', 'complete endpoint A/X/Y/P/SP',
                              'independent C=1 oracle for boolean materializer CMP0 paths; V/I/D preservation',
                              'all named source objects with verified widths, no frame masks', 'explicit pointer-object identity only',
                              'all unclaimed ZP bytes at full entry; sixteen native ZP canary addresses, fixed RAM and live caller stack',
                              'source/control label names retained', 'ASM/value-only materializer negative controls byte-identical',
                              'normal entry through main return/cleanup to final RTS boundary; equality hooks asserted'],
                      scope='All byte pairs for two scalar boolean functions in D0/D1, plus all64 C/Z/I/D/V/N combinations at byte/word boundary Cartesian products. Signed storage uses only equality/inequality; signed ordering remains unsupported. No decimal arithmetic on relocated private addresses or software-stack arithmetic is tested. Stateful CIA timer model supplies ordered volatile reads; no full device/ROM emulation claim.',
                      cycle_scope='Peddle native cycles exclude final top-level RTS. Main entry includes startup/lifecycle and skips intercepted assertion instructions.')
        args.output.parent.mkdir(parents=True, exist_ok=True); args.output.write_text(json.dumps(report, indent=2) + '\n')
        print('PASS', report['cases'], 'paired cases;', report['decimal_cases'], 'D-set;', sum(r['slower_cases'] for r in totals.values()), 'slower cases', flush=True)
    finally:
        for pair in images.values():
            for im, _ in pair:
                im.close()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('before', 'after', 'library', 'output'):
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--variants', help='comma-separated subset; default all six')
    p.add_argument('--edges-only', action='store_true', help='skip exhaustive byte-pair sweep; retain complete flag/boundary matrix')
    verify(p.parse_args())


if __name__ == '__main__':
    main()
