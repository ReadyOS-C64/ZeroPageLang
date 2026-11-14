#!/usr/bin/env python3
"""Assemble and execute tight runtime loops at all 256 page offsets.

Requires the project's Peddle C ABI as a shared library (--library). Tests the
literal routines emitted by runtime.zig, including page guards and filler.
"""

import argparse
import ctypes as c
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


ROOT = Path(__file__).resolve().parent.parent


class Regs(c.Structure):
    _fields_ = [("pc", c.c_uint16), ("pc0", c.c_uint16),
                ("sp", c.c_uint8), ("a", c.c_uint8), ("x", c.c_uint8),
                ("y", c.c_uint8), ("p", c.c_uint8),
                ("cycles", c.c_uint64), ("instructions", c.c_uint64)]


def bind(library, name, arguments, result=None):
    function = getattr(library, "zeropage_peddle_" + name)
    function.argtypes = arguments
    function.restype = result
    return function


def literal_body(source, function):
    body = source.split("pub fn " + function + "(", 1)[1].split("\npub fn ", 1)[0]
    lines = [line.split("\\\\", 1)[1] for line in body.splitlines() if "\\\\" in line]
    if not lines:
        raise ValueError(f"no literal assembly body in {function}")
    return "\n".join(lines) + "\n"


def verify(library, assembler, output):
    source = (ROOT / "src/codegen/tass64/runtime.zig").read_text()
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
    regs = bind(library, "regs", [pointer], Regs)
    step = bind(library, "step_instruction", [pointer])
    output.mkdir(parents=True, exist_ok=True)
    machine = create()
    records = []
    try:
        routines = [
            ("clear", "emitClearScreenRoutine", "clearScreen", "clearScreenLoop", 20, 15, (6403, 6406)),
            ("multiply", "emitMultiplyRoutine", "zeropage_mul16", "zeropage_mul16_loop", 53, 36, (581, 584)),
        ]
        for kind, function, entry, loop, native_size, span, expected_cycles in routines:
            for low in range(256):
                origin = 0x2000 + low
                assembly = output / f"{kind}-{low}.asm"
                prg = assembly.with_suffix(".prg")
                labels_file = assembly.with_suffix(".labels")
                assembly.write_text(
                    f"* = ${origin:04x}\nzeropage_mul_lhs = $3000\n"
                    "zeropage_mul_rhs = $3002\nzeropage_mul_result = $3004\n" + literal_body(source, function))
                subprocess.run([assembler, "-q", "--cbm-prg", "--vice-labels", "-l", str(labels_file),
                                "-o", str(prg), str(assembly)], check=True, capture_output=True)
                labels = {match[2]: int(match[1], 16) for line in labels_file.read_text().splitlines()
                          if (match := re.fullmatch(r"al ([0-9a-fA-F]+) \.(.+)", line))}
                loop_start = labels[loop]
                assert loop_start >> 8 == (loop_start + span) >> 8, (kind, low, "branch page")
                data = prg.read_bytes()
                extra = len(data) - 2 - native_size
                assert 0 <= extra <= span, (kind, low, "padding", extra)
                clear(machine)
                payload = (c.c_uint8 * (len(data) - 2)).from_buffer_copy(data[2:])
                load(machine, origin, payload, len(payload))
                reset(machine)
                set_sp(machine, 255)
                set_pc(machine, labels[entry])
                if kind == "multiply":
                    for address, value in [(0x3000, 0x34), (0x3001, 0x12), (0x3002, 5), (0x3003, 0)]:
                        write(machine, address, value)
                for _ in range(10000):
                    opcode = read(machine, regs(machine).pc)
                    if opcode == 0x60:
                        break
                    assert opcode != 0, (kind, low, "executed filler")
                    step(machine)
                else:
                    raise AssertionError((kind, low, "instruction budget"))
                result = regs(machine)
                if kind == "multiply":
                    assert result.a | (result.x << 8) == 0x5b04, (kind, low, "product")
                else:
                    assert all(read(machine, address) == 32 for address in range(0x400, 0x7e8)), (kind, low, "screen")
                    assert read(machine, 0x7e8) == 0, (kind, low, "screen boundary")
                assert result.cycles in expected_cycles, (kind, low, "cycles", result.cycles)
                records.append({"kind": kind, "origin": origin, "loop": loop_start,
                                "extra_bytes": extra, "cycles_excluding_final_rts": result.cycles})
    finally:
        destroy(machine)
    (output / "results.json").write_text(json.dumps({"tested_origins": len(records), "records": records}, indent=2) + "\n")
    for kind in ("clear", "multiply"):
        rows = [row for row in records if row["kind"] == kind]
        print(f"{kind}: {len(rows)} origins, max {max(row['extra_bytes'] for row in rows)} extra bytes, "
              f"cycles {sorted({row['cycles_excluding_final_rts'] for row in rows})}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--assembler")
    parser.add_argument("--output", type=Path, default=ROOT / "build/runtime-loop-pages")
    args = parser.parse_args()
    assembler = args.assembler or os.environ.get("ZEROPAGE_64TASS")
    if not assembler:
        sibling = ROOT.parent / "zeropage-tooling/bin/64tass"
        assembler = str(sibling) if sibling.is_file() else shutil.which("64tass")
    if not assembler:
        parser.error("64tass not found")
    verify(c.CDLL(str(args.library.resolve())), assembler, args.output)


if __name__ == "__main__":
    main()
