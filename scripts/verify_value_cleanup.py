#!/usr/bin/env python3
"""Compare compiler-generated value cleanup across all bytes/flags and words."""

import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path

from verify_pointer_reuse import Image


def verify(args):
    library = c.CDLL(str(args.library.resolve()))
    values = [Image(library, args.before), Image(library, args.after)]
    stacks = [Image(library, args.before_stack), Image(library, args.after_stack)]
    frames = {image: {frame["owner"]: frame for frame in image.frames} for image in values + stacks}
    totals = {}
    decimal_cases = 0

    def check(function, arguments, memory, seed, decimal, expected):
        nonlocal decimal_cases
        images = stacks if function.startswith("stack") else values
        before, after = [image.call(function, arguments, memory, seed, decimal) for image in images]
        assert before[1:] == after[1:], (function, seed, decimal, "state mismatch", before[1:], after[1:])
        observed_frames = []
        for image in images:
            frame = frames[image]["function:" + function]
            observed_frames.append(bytes(image.read(image.machine, address) for address in range(frame["start"], frame["end"])))
        assert observed_frames[0] == observed_frames[1], (function, seed, decimal, "function-frame RAM mismatch")
        if expected is not None:
            actual = after[0].a | (after[0].x << 8) if function in ("wordCopies", "stackWord") else after[0].a
            assert actual == expected, (function, seed, decimal, expected, actual)
        row = totals.setdefault(function, {"cases": 0, "before_cycles": 0, "after_cycles": 0,
                                          "before_instructions": 0, "after_instructions": 0, "slower_cases": 0})
        row["cases"] += 1
        row["before_cycles"] += before[0].cycles
        row["after_cycles"] += after[0].cycles
        row["before_instructions"] += before[0].instructions
        row["after_instructions"] += after[0].instructions
        row["slower_cases"] += after[0].cycles > before[0].cycles
        decimal_cases += decimal

    try:
        for value in range(256):
            for bits in range(64):
                flags = (bits & 15) | ((bits & 16) << 2) | ((bits & 32) << 2)
                decimal = bool(flags & 8)
                param = {"value": (value, 1)}
                for function, expected in [("copies", value), ("aggregate", value),
                                           ("decimalFlags", None if decimal else (value + 123) & 255),
                                           ("callBarrier", None if decimal else (2 * value + 1) & 255),
                                           ("asmBarrier", None if decimal else (value + 7) & 255)]:
                    check(function, param, {}, flags, decimal, expected)
                check("stackArray", param, {}, flags, decimal, value)
                check("stackDecimal", param, {}, flags, decimal, None if decimal else (value + 123) & 255)
                # CPU reads from the CIA timer advance its modeled value. Two
                # real volatile reads produce 1 + 2; a forwarded read would not.
                check("volatileReads", {"location": (0xdc04, 2)}, {}, flags, decimal, 3)
            if (value + 1) % 64 == 0:
                print(f"Verified all byte/flag combinations through {value}", flush=True)
        for word in range(65536):
            check("wordCopies", {"value": (word, 2)}, {}, word, bool(word & 8), word)
            check("stackWord", {"value": (word, 2)}, {}, word, bool(word & 8), word)
            if (word + 1) % 16384 == 0:
                print(f"Verified {word + 1} word values", flush=True)
    finally:
        for image in values + stacks:
            image.close()
    result = {"format": "zeropage-value-equivalence-v1", "status": "success",
              "cases": sum(row["cases"] for row in totals.values()), "decimal_cases": decimal_cases,
              "functions": totals,
              "before_prg_sha256": hashlib.sha256(args.before.read_bytes()).hexdigest(),
              "after_prg_sha256": hashlib.sha256(args.after.read_bytes()).hexdigest(),
              "before_stack_sha256": hashlib.sha256(args.before_stack.read_bytes()).hexdigest(),
              "after_stack_sha256": hashlib.sha256(args.after_stack.read_bytes()).hexdigest(),
              "checks": ["A/X/Y/P/SP", "function-frame RAM", "pointer scratch by storage identity", "host results where specified", "two CIA timer reads"],
              "notes": "Dead hardware-stack bytes are private ABI scratch. Decimal cases compare actual NMOS behavior, not a new source arithmetic guarantee.",
              "cycle_scope": "Peddle CPU cycles excluding the final top-level RTS"}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("before", "after", "before-stack", "after-stack", "library", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    verify(parser.parse_args())


if __name__ == "__main__":
    main()
