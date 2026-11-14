#!/usr/bin/env python3
"""Verify the actual assembled multiply helper against host integer products.

Exhausts all byte pairs, then covers word boundaries and seeded word pairs.
Expected helper cycle/instruction bases can be overridden for an older baseline.
"""

import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path
import re
import subprocess

from verify_runtime_loop_pages import ROOT, Regs, bind, literal_body


def verify(args):
    source = args.runtime.read_text()
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    assembly = output / "multiply.asm"
    prg = assembly.with_suffix(".prg")
    labels_file = assembly.with_suffix(".labels")
    assembly.write_text("* = $2000\nzeropage_mul_lhs = $3000\nzeropage_mul_rhs = $3002\n"
                        "zeropage_mul_result = $3004\n" + literal_body(source, "emitMultiplyRoutine"))
    subprocess.run([args.assembler, "-q", "--cbm-prg", "--vice-labels", "-l", str(labels_file),
                    "-o", str(prg), str(assembly)], capture_output=True, check=True)
    labels = {match[2]: int(match[1], 16) for line in labels_file.read_text().splitlines()
              if (match := re.fullmatch(r"al ([0-9a-fA-F]+) \.(.+)", line))}
    library = c.CDLL(str(args.library.resolve()))
    pointer = c.c_void_p
    create = bind(library, "create", [], pointer)
    destroy = bind(library, "destroy", [pointer])
    reset = bind(library, "reset", [pointer])
    clear = bind(library, "clear_memory", [pointer])
    load = bind(library, "load", [pointer, c.c_uint16, c.POINTER(c.c_uint8), c.c_size_t])
    read = bind(library, "read", [pointer, c.c_uint16], c.c_uint8)
    write = bind(library, "write", [pointer, c.c_uint16, c.c_uint8])
    set_pc = bind(library, "set_pc", [pointer, c.c_uint16])
    set_sp = bind(library, "set_sp", [pointer, c.c_uint8])
    set_y = bind(library, "set_y", [pointer, c.c_uint8])
    set_p = bind(library, "set_p", [pointer, c.c_uint8])
    regs = bind(library, "regs", [pointer], Regs)
    step = bind(library, "step_instruction", [pointer])
    machine = create()
    counts = {"byte_pairs": 0, "word_boundaries": 0, "seeded_word_pairs": 0}
    digest = hashlib.sha256()
    minimum, maximum = None, None
    try:
        clear(machine)
        data = prg.read_bytes()
        payload = (c.c_uint8 * (len(data) - 2)).from_buffer_copy(data[2:])
        load(machine, 0x2000, payload, len(payload))

        def check(lhs, rhs, group):
            nonlocal minimum, maximum
            reset(machine)
            set_pc(machine, labels["zeropage_mul16"])
            set_sp(machine, 0xfd)
            set_y(machine, 0xa5)
            set_p(machine, 0x20 | ((lhs ^ rhs) & 1))  # Exercise either incoming carry, D clear.
            for address, value in [(0x3000, lhs & 255), (0x3001, lhs >> 8),
                                   (0x3002, rhs & 255), (0x3003, rhs >> 8),
                                   (0x3004, 0x5a), (0x3005, 0xa5)]:
                write(machine, address, value)
            for _ in range(1000):
                opcode = read(machine, regs(machine).pc)
                if opcode == 0x60:
                    break
                assert opcode != 0, (lhs, rhs, "executed filler")
                step(machine)
            else:
                raise AssertionError((lhs, rhs, "instruction budget"))
            result = regs(machine)
            expected = (lhs * rhs) & 65535
            actual = result.a | (result.x << 8)
            assert actual == expected, (lhs, rhs, expected, actual)
            assert (read(machine, 0x3004) | (read(machine, 0x3005) << 8)) == expected
            assert all(read(machine, address) == 0 for address in range(0x3000, 0x3004))
            assert result.y == 0xa5 and result.sp == 0xfd
            cycles = args.base_cycles + 25 * rhs.bit_count()
            instructions = args.base_instructions + 7 * rhs.bit_count()
            assert result.cycles == cycles, (lhs, rhs, "cycles", result.cycles, cycles)
            assert result.instructions == instructions, (lhs, rhs, "instructions", result.instructions, instructions)
            minimum = cycles if minimum is None else min(minimum, cycles)
            maximum = cycles if maximum is None else max(maximum, cycles)
            digest.update(lhs.to_bytes(2, "little") + rhs.to_bytes(2, "little") + actual.to_bytes(2, "little"))
            counts[group] += 1

        for lhs in range(256):
            for rhs in range(256):
                check(lhs, rhs, "byte_pairs")
            if (lhs + 1) % 64 == 0:
                print(f"Verified {counts['byte_pairs']} byte pairs", flush=True)
        boundaries = (0, 1, 2, 7, 15, 127, 128, 255, 256, 257, 32767, 32768, 32769, 43690, 65534, 65535)
        for lhs in boundaries:
            for rhs in boundaries:
                check(lhs, rhs, "word_boundaries")
        state = 0x6502
        for _ in range(4096):
            state = (state * 1664525 + 1013904223) & 0xffffffff
            lhs = (state >> 8) & 65535
            state = (state * 1664525 + 1013904223) & 0xffffffff
            check(lhs, (state >> 8) & 65535, "seeded_word_pairs")
    finally:
        destroy(machine)
    result = {"format": "zeropage-runtime-products-v1", "counts": counts,
              "runtime_sha256": hashlib.sha256(source.encode()).hexdigest(),
              "prg_sha256": hashlib.sha256(data).hexdigest(), "products_sha256": digest.hexdigest(),
              "base_cycles": args.base_cycles, "base_instructions": args.base_instructions,
              "cycles_excluding_final_rts": {"min": minimum, "max": maximum},
              "seed": 0x6502, "status": "success"}
    (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, default=ROOT / "src/codegen/tass64/runtime.zig")
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--assembler")
    parser.add_argument("--output", type=Path, default=ROOT / "build/runtime-products")
    parser.add_argument("--base-cycles", type=int, default=531)
    parser.add_argument("--base-instructions", type=int, default=118)
    args = parser.parse_args()
    import os
    import shutil
    if not args.assembler:
        sibling = ROOT.parent / "zeropage-tooling/bin/64tass"
        args.assembler = os.environ.get("ZEROPAGE_64TASS") or (str(sibling) if sibling.is_file() else shutil.which("64tass"))
    if not args.assembler:
        parser.error("64tass not found")
    verify(args)


if __name__ == "__main__":
    main()
