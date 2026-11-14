#!/usr/bin/env python3
"""Differentially execute pointer-optimization fixtures, including ABI-level aliases.

Uses real PRGs compiled by the saved and new compilers. Tests all pointer low
bytes, word page crossings, index pairs, and stores aliasing the parameter slot.
"""

import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path
import re

from verify_runtime_loop_pages import Regs, bind


class Image:
    def __init__(self, library, path):
        self.path = path
        self.labels = {m[2]: int(m[1], 16) for line in Path(str(path) + ".labels").read_text().splitlines()
                       if (m := re.fullmatch(r"al ([0-9a-fA-F]+) \.(.+)", line))}
        self.frames = [section for section in json.loads(Path(str(path) + ".zpmap.json").read_text())["sections"]
                       if section["kind"] == "static_frame" and section["start"] is not None]
        pointer = c.c_void_p
        self.destroy = bind(library, "destroy", [pointer])
        self.reset = bind(library, "reset", [pointer])
        self.read = bind(library, "read", [pointer, c.c_uint16], c.c_uint8)
        self.write = bind(library, "write", [pointer, c.c_uint16, c.c_uint8])
        self.set_pc = bind(library, "set_pc", [pointer, c.c_uint16])
        self.set_sp = bind(library, "set_sp", [pointer, c.c_uint8])
        self.set_a = bind(library, "set_a", [pointer, c.c_uint8])
        self.set_x = bind(library, "set_x", [pointer, c.c_uint8])
        self.set_y = bind(library, "set_y", [pointer, c.c_uint8])
        self.set_p = bind(library, "set_p", [pointer, c.c_uint8])
        self.regs = bind(library, "regs", [pointer], Regs)
        self.step = bind(library, "step_instruction", [pointer])
        self.run = bind(library, "run_until_rts", [pointer, c.c_uint8, c.c_uint32], c.c_int) if hasattr(library, "zeropage_peddle_run_until_rts") else None
        self.machine = bind(library, "create", [], pointer)()
        bind(library, "clear_memory", [pointer])(self.machine)
        data = path.read_bytes()
        payload = (c.c_uint8 * (len(data) - 2)).from_buffer_copy(data[2:])
        bind(library, "load", [pointer, c.c_uint16, c.POINTER(c.c_uint8), c.c_size_t])(
            self.machine, int.from_bytes(data[:2], "little"), payload, len(payload))

    def call(self, function, arguments, memory, seed, decimal=False):
        m = self.machine
        self.reset(m)
        self.set_pc(m, self.labels[function])
        self.set_sp(m, 0xf9)
        self.set_a(m, (seed + 0x23) & 255)
        self.set_x(m, (seed ^ 0x89) & 255)
        self.set_y(m, (seed ^ 0x67) & 255)
        self.set_p(m, 0x20 | (seed & 0xc7) | (8 if decimal else 0))
        self.write(m, 0xfb, 0x5a)
        self.write(m, 0xfc, 0xa5)
        for address, value in memory.items():
            self.write(m, address, value)
        for name, (value, width) in arguments.items():
            if isinstance(value, str):
                value = self.labels[value]
            address = self.labels[function + "_" + name]
            for offset in range(width):
                self.write(m, address + offset, (value >> (8 * offset)) & 255)
        if self.run is not None:
            status = self.run(m, 0xf9, 10000)
            assert status == 0, (self.path, function, "BRK" if status == 1 else "instruction budget")
        else:
            for _ in range(10000):
                regs = self.regs(m)
                opcode = self.read(m, regs.pc)
                if opcode == 0x60 and regs.sp == 0xf9:
                    break
                assert opcode != 0, (self.path, function, "BRK")
                self.step(m)
            else:
                raise AssertionError((function, "instruction budget"))
        regs = self.regs(m)
        state = (regs.a, regs.x, regs.y, regs.p, regs.sp)
        observed = bytes(self.read(m, address) for address in sorted(memory))
        pointer = self.read(m, 0xfb) | (self.read(m, 0xfc) << 8)
        # Code shrinkage can move private static frames. Compare a pointer to
        # such storage by owner/byte offset, retaining literal addresses elsewhere.
        identity = ("absolute", pointer)
        for frame in self.frames:
            if frame["start"] <= pointer < frame["end"]:
                identity = ("frame", frame["owner"], pointer - frame["start"])
                break
        return regs, state, observed, identity

    def close(self):
        self.destroy(self.machine)


def record(address, a, b, word, bytes_, words):
    data = [a, b, word & 255, word >> 8] + list(bytes_)
    for value in words:
        data += [value & 255, value >> 8]
    return dict(enumerate(data, address))


def verify(args):
    library = c.CDLL(str(args.library.resolve()))
    reads = [Image(library, args.before_read), Image(library, args.after_read)]
    aliases = [Image(library, args.before_alias), Image(library, args.after_alias)]
    totals = {}

    def check(images, function, arguments, memory, seed, expected):
        before, after = [image.call(function, arguments, memory, seed) for image in images]
        assert before[1:] == after[1:], (function, seed, "register/flags/memory/pointer mismatch", before[1:], after[1:])
        actual = after[0].a | (after[0].x << 8)
        assert actual == (expected & 65535), (function, seed, expected & 65535, actual)
        row = totals.setdefault(function, {"cases": 0, "before_cycles": 0, "after_cycles": 0,
                                          "before_instructions": 0, "after_instructions": 0, "slower_cases": 0})
        row["cases"] += 1
        row["before_cycles"] += before[0].cycles
        row["after_cycles"] += after[0].cycles
        row["before_instructions"] += before[0].instructions
        row["after_instructions"] += after[0].instructions
        row["slower_cases"] += after[0].cycles > before[0].cycles

    try:
        for low in range(256):
            address = 0xc100 + low
            a, b = low, 255 - low
            word = (low << 8) | ((low * 17) & 255)
            bytes_ = (low ^ 0x55, (low + 11) & 255, (low * 3) & 255, 255 - low)
            words = ((low * 257) & 65535, 65535 - low, 0x8001)
            memory = record(address, a, b, word, bytes_, words)
            memory.update(record(0xc500, 8, 9, 0x8000, (1, 2, 3, 4), (1, 2, 3)))
            memory[0xc700] = 4
            param = {"record": (address, 2)}
            check(reads, "fields", param, memory, low, word + a + b)
            check(reads, "words", param, memory, low, word + words[0] + words[1])
            for i in range(4):
                for j in range(4):
                    check(reads, "indexes", param | {"i": (i, 1), "j": (j, 1)}, memory, low, words[2] + bytes_[i] + bytes_[j])
            pointers = {"first": (address, 2), "second": (0xc500, 2)}
            check(reads, "redirect", pointers, memory, low, a + 9)
            for flag in (0, 1):
                check(reads, "acrossBranch", pointers | {"choose": (flag, 1)}, memory, low, a + (9 if flag else b))
            check(reads, "acrossCall", param, memory, low, a + 22)
            check(reads, "acrossVolatile", param | {"location": (0xc700, 2)}, memory, low, a + b + 4)

            # Native ABI callers can make an indirect store alias the parameter
            # word itself, even though source address-of-pointer is unsupported.
            alias_memory = record(0xc400, 5, 7, 256, (1, 2, 3, 4), (1, 2, 3))
            alias_memory.update(record(0xc41f, 3, 37, 0xfffe, (0, 0, 0, 0), (0, 0, 0)))
            alias_memory.update(record(0xc680, 31, 53, 0x1234, (0, 0, 0, 0), (0, 0, 0)))
            check(aliases, "aliasWrite", {"record": (0xc400, 2), "location": ("aliasWrite_record", 2)}, alias_memory, low, 42)
            check(aliases, "aliasWord", {"record": (0xc400, 2), "location": ("aliasWord_record", 2)}, alias_memory, low, 0x1239)
            check(aliases, "acrossAsm", {"record": (0xc400, 2)}, alias_memory, low, 12)
            if (low + 1) % 64 == 0:
                print(f"Verified pointer low bytes 0..{low}", flush=True)
    finally:
        for image in reads + aliases:
            image.close()
    result = {"format": "zeropage-pointer-equivalence-v1", "status": "success",
              "cases": sum(row["cases"] for row in totals.values()), "functions": totals,
              "prg_sha256": {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                             for path in (args.before_read, args.after_read, args.before_alias, args.after_alias)},
              "checks": ["host expected word results", "A/X/Y/P/SP", "record memory effects", "final pointer scratch"],
              "cycle_scope": "Peddle CPU cycles excluding the final top-level RTS"}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("before-read", "after-read", "before-alias", "after-alias", "library", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    verify(parser.parse_args())


if __name__ == "__main__":
    main()
