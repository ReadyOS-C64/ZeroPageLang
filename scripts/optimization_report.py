#!/usr/bin/env python3
"""Snapshot fresh host measurements and compare immutable optimization rounds."""

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re


ABI_BENCHMARK_DIR = Path("tests/fixtures/emu/lang/pass/optimization_reference/abi_calls")
ABI_VARIANTS = ("static", "stack")
STACK_FIELDS = ("hardware_stack_peak", "software_stack_written", "software_stack_capacity")

TIMING_MODEL = "Peddle stepped CPU cycles; intercepted test/KERNAL calls excluded; no VIC/CIA/ROM timing"


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def input_digest(source):
    """Include transitive local source imports; built-in imports have no file."""
    visited = set()
    result = hashlib.sha256()

    def visit(path):
        path = Path(path).resolve()
        if path in visited:
            return
        visited.add(path)
        data = path.read_bytes()
        # Relative names keep snapshots portable between workspace checkouts.
        result.update(os.path.relpath(path, Path(source).resolve().parent).encode())
        result.update(b"\0" + data + b"\0")
        for imported in re.findall(rb'@import\s*\(\s*"([^"\n]+)"\s*\)', data):
            child = path.parent / imported.decode()
            if child.suffix == ".zp64" and child.is_file():
                visit(child)

    visit(source)
    return result.hexdigest()


def host_measurements(text):
    rows = {}
    stacks = {}
    for line in text.splitlines():
        if line.startswith("host-stack-metrics\t"):
            _, source, *metrics = line.split("\t")
            if source in stacks:
                raise ValueError(f"duplicate stack measurement: {source}")
            stacks[source] = dict(zip(STACK_FIELDS, map(int, metrics), strict=True))
        if line.startswith("host-metrics\t"):
            _, source, artifact, size, cycles, instructions, intercepted = line.split("\t")
            if source in rows:
                raise ValueError(f"duplicate measurement: {source}")
            if Path(artifact).stat().st_size != int(size):
                raise ValueError(f"artifact changed since measurement: {artifact}")
            rows[source] = artifact_row(source, artifact) | {
                "cycles": int(cycles), "instructions": int(instructions),
                "intercepted_calls": int(intercepted),
            }
    if not rows:
        raise ValueError("log contains no host-metrics rows")
    for source, metrics in stacks.items():
        if source not in rows:
            raise ValueError(f"stack measurement without host metrics: {source}")
        if not 0 <= metrics["hardware_stack_peak"] <= 255 or not (
            0 <= metrics["software_stack_written"] <= metrics["software_stack_capacity"]
        ):
            raise ValueError(f"invalid stack measurement: {source}")
        rows[source].update(metrics)
    return rows


def snapshot(log, extras):
    text = Path(log).read_text()
    completion = re.search(r"host-emulated (\d+) language pass,[^\n]*?(\d+) smoke cases", text)
    if not completion:
        raise ValueError("log has no successful full-suite completion")
    rows = host_measurements(text)
    expected = int(completion[1]) + int(completion[2])
    if len(rows) != expected:
        raise ValueError(f"incomplete metrics: expected {expected} passing cases, found {len(rows)}")
    if not abi_sources() <= rows.keys():
        raise ValueError("full suite does not cover every ABI benchmark variant")
    for spec in extras:
        source, artifact = spec.split("=", 1)
        if source in rows:
            raise ValueError(f"duplicate source: {source}")
        rows[source] = artifact_row(source, artifact)
    validate_abi_measurements(rows)
    return rows


def artifact_row(source, artifact):
    row = {
        "source": source, "artifact": artifact,
        "source_sha256": digest(source), "prg_sha256": digest(artifact),
        "input_sha256": input_digest(source),
        "prg_bytes": Path(artifact).stat().st_size,
    }
    if abi_workload(source):
        mapping = json.loads(Path(str(artifact) + ".zpmap.json").read_text())
        row["static_frame_bytes"] = sum(section["size"] for section in mapping["sections"]
                                        if section["kind"] == "static_frame")
    return row


def load_snapshot(path):
    lines = Path(path).read_text().splitlines()
    metadata, *records = map(json.loads, lines)
    if metadata.get("format") != "zeropage-optimization-v1":
        raise ValueError(f"unsupported snapshot: {path}")
    rows = {row["source"]: row for row in records}
    if len(rows) != len(records):
        raise ValueError(f"duplicate sources in snapshot: {path}")
    return metadata, rows


def abi_workload(source):
    path = Path(source)
    if path.parts[-len(ABI_BENCHMARK_DIR.parts)-1:-1] != ABI_BENCHMARK_DIR.parts:
        return None
    workload, _, variant = path.stem.rpartition("_")
    if workload and not workload.startswith("_") and variant in ABI_VARIANTS:
        return workload, variant
    return None


def abi_sources():
    return {path.as_posix() for path in ABI_BENCHMARK_DIR.glob("*.zp64") if abi_workload(path)}


def abi_size_table(tsv):
    """Show the canonical host artifacts from the standalone PRG size report."""
    artifacts = {
        "build/emu/" + re.sub(r"[/\\.]", "_", source) + ".prg": abi_workload(source)
        for source in abi_sources()
    }
    pairs = {}
    for row in csv.DictReader(tsv, delimiter="\t"):
        key = artifacts.get(row["path"])
        if key is not None:
            workload, variant = key
            variants = pairs.setdefault(workload, {})
            if variant in variants:
                raise ValueError(f"duplicate ABI size row: {row['path']}")
            variants[variant] = row
    if not artifacts:
        return ""
    if sum(len(pair) for pair in pairs.values()) != len(artifacts):
        raise ValueError("size report does not cover every ABI benchmark variant")

    def baseline_delta(row):
        return f"{int(row['delta_bytes']):+,}" if row["delta_bytes"] else "—"

    lines = ["## Static and software-stack calling conventions", "",
             "| Workload | Static PRG bytes | Stack PRG bytes | Stack − static | Static Δ from baseline | Stack Δ from baseline |",
             "| --- | ---: | ---: | ---: | ---: | ---: |"]
    for workload, pair in sorted(pairs.items()):
        static, stack = (pair[variant] for variant in ABI_VARIANTS)
        static_size, stack_size = int(static["prg_bytes"]), int(stack["prg_bytes"])
        lines.append(f"| {workload} | {static_size:,} | {stack_size:,} | {stack_size - static_size:+,} | "
                     f"{baseline_delta(static)} | {baseline_delta(stack)} |")
    return "\n".join(lines) + "\n\n"


def abi_pairs(rows):
    pairs = {}
    for source, row in rows.items():
        key = abi_workload(source)
        if key is None:
            continue
        workload, variant = key
        variants = pairs.setdefault(workload, {})
        if variant in variants:
            raise ValueError(f"duplicate ABI variant: {source}")
        variants[variant] = row
    for workload, variants in pairs.items():
        if variants.keys() != set(ABI_VARIANTS):
            raise ValueError(f"incomplete ABI pair: {workload}")
        static, stack = (variants[variant] for variant in ABI_VARIANTS)
        if "cycles" not in static or "cycles" not in stack:
            raise ValueError(f"missing timing in ABI pair: {workload}")
        if static.get("intercepted_calls") != stack.get("intercepted_calls"):
            raise ValueError(f"intercepted call counts differ in ABI pair: {workload}")
    return pairs


def abi_table(rows):
    pairs = abi_pairs(rows)
    if not pairs:
        return []
    lines = ["| Workload | Static PRG | Stack PRG | Δ bytes | Static cycles | Stack cycles | Δ cycles | "
             "Static frame B (static / stack) | Hardware stack B (static / stack) | "
             "Software stack B written / reserved |",
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for workload, pair in sorted(pairs.items()):
        static, stack = (pair[variant] for variant in ABI_VARIANTS)
        lines.append(
            f"| {workload} | {static['prg_bytes']:,} | {stack['prg_bytes']:,} | "
            f"{stack['prg_bytes'] - static['prg_bytes']:+,} | "
            f"{static['cycles']:,} | {stack['cycles']:,} | {stack['cycles'] - static['cycles']:+,} | "
            f"{static.get('static_frame_bytes', '—')} / {stack.get('static_frame_bytes', '—')} | "
            f"{static.get('hardware_stack_peak', '—')} / {stack.get('hardware_stack_peak', '—')} | "
            f"{stack.get('software_stack_written', '—')} / {stack.get('software_stack_capacity', '—')} |"
        )
    return lines


def abi_snapshot(log):
    text = Path(log).read_text()
    completion = re.search(r"^targeted-peddle filter=.*: (\d+) language pass, 0 compile-fail, "
                           r"0 runtime-fail, 0 smoke cases$", text, re.M)
    if not completion:
        raise ValueError("log has no successful targeted ABI suite completion")
    rows = host_measurements(text)
    expected = abi_sources()
    if rows.keys() != expected or len(rows) != int(completion[1]):
        raise ValueError("targeted ABI suite does not cover every benchmark variant")
    validate_abi_measurements(rows)
    return rows


def validate_abi_measurements(rows):
    for workload, pair in abi_pairs(rows).items():
        for variant, row in pair.items():
            if not all(field in row for field in STACK_FIELDS):
                raise ValueError(f"missing stack metrics: {workload} {variant}")
            written, capacity = row["software_stack_written"], row["software_stack_capacity"]
            if (variant == "stack" and not 0 < written <= capacity) or (
                variant == "static" and (written or capacity)
            ):
                raise ValueError(f"software stack usage does not match variant: {workload} {variant}")


def abi_comparison(before, after):
    lines = abi_table(after)
    if not lines:
        return []
    common = {source for source in before.keys() & after.keys() if abi_workload(source)}
    lines = ["", "## Static and software-stack calling conventions", "", *lines]
    if common:
        lines += ["", "| Workload | ABI | PRG before → after | Cycles before → after | "
                  "Static frame B before → after | Hardware stack B before → after | "
                  "Software stack B written before → after | Software stack B reserved before → after |",
                  "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
        fields = ("prg_bytes", "cycles", "static_frame_bytes", *STACK_FIELDS)
        for source in sorted(common, key=abi_workload):
            workload, variant = abi_workload(source)
            old, new = before[source], after[source]
            spans = " | ".join(f"{old.get(field, '—')} → {new.get(field, '—')}" for field in fields)
            lines.append(f"| {workload} | {variant} | {spans} |")
    return lines + ["", "ABI deltas compare stack to static in the same compiler. Software stack usage is "
                    "the highest byte written within the declared reservation.", ""]


def compare(before, after):
    lines = ["| Source | PRG before | PRG after | Delta | CPU cycles before | CPU cycles after | Delta |",
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    common = before.keys() & after.keys()
    changed = []
    for source in sorted(common):
        old, new = before[source], after[source]
        if old["source_sha256"] != new["source_sha256"]:
            raise ValueError(f"source changed; compare a fresh common corpus: {source}")
        if old.get("input_sha256") != new.get("input_sha256"):
            raise ValueError(f"imported source changed; compare a fresh common corpus: {source}")
        delta = new["prg_bytes"] - old["prg_bytes"]
        cycles_old, cycles_new, cycles_delta = "—", "—", "—"
        if "cycles" in old and "cycles" in new:
            if old["intercepted_calls"] != new["intercepted_calls"]:
                raise ValueError(f"intercepted call count changed; investigate timing: {source}")
            cycles_old, cycles_new = old["cycles"], new["cycles"]
            cycles_delta = cycles_new - cycles_old
        if delta or (isinstance(cycles_delta, int) and cycles_delta):
            changed.append((source, old, new, delta, cycles_old, cycles_new, cycles_delta))
    for source, old, new, delta, cycles_old, cycles_new, cycles_delta in changed:
        lines.append(f"| `{source}` | {old['prg_bytes']} | {new['prg_bytes']} | {delta:+d} | {cycles_old} | {cycles_new} | {cycles_delta} |")
    lines += ["", f"Common artifacts: {len(common)}; changed: {len(changed)}; "
              f"PRG delta: {sum(after[s]['prg_bytes'] - before[s]['prg_bytes'] for s in common):+d} bytes.",
              f"New artifacts (excluded from delta): {', '.join(sorted(after.keys() - before.keys())) or 'none'}.",
              f"Missing artifacts (excluded from delta): {', '.join(sorted(before.keys() - after.keys())) or 'none'}.",
              "", TIMING_MODEL + ".", ""]
    return "\n".join(lines + abi_comparison(before, after))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    snap = sub.add_parser("snapshot")
    snap.add_argument("--label", required=True)
    snap.add_argument("--emu-log", required=True)
    snap.add_argument("--compiler", default="zig-out/bin/zp64c")
    snap.add_argument("--abi-only", action="store_true", help="require a complete targeted ABI benchmark run")
    snap.add_argument("--extra", action="append", default=[], metavar="SOURCE=PRG")
    snap.add_argument("--output", type=Path, required=True)
    diff = sub.add_parser("compare")
    diff.add_argument("before")
    diff.add_argument("after")
    diff.add_argument("--output", type=Path, required=True)
    sizes = sub.add_parser("abi-sizes", help="print the matched ABI table from a PRG size report")
    sizes.add_argument("tsv", type=Path)
    args = parser.parse_args()
    if args.command == "abi-sizes":
        with args.tsv.open() as tsv:
            print(abi_size_table(tsv), end="")
        return
    if args.output.exists():
        parser.error("output exists; choose a new round path to preserve history")
    if args.command == "snapshot":
        if args.abi_only and args.extra:
            parser.error("--abi-only cannot include size-only extras")
        rows = abi_snapshot(args.emu_log) if args.abi_only else snapshot(args.emu_log, args.extra)
        metadata = {"format": "zeropage-optimization-v1", "label": args.label,
                    "compiler_sha256": digest(args.compiler), "timing_model": TIMING_MODEL}
        output = "\n".join(json.dumps(row, sort_keys=True) for row in
                           [metadata] + [rows[s] for s in sorted(rows)]) + "\n"
    else:
        old_meta, old = load_snapshot(args.before)
        new_meta, new = load_snapshot(args.after)
        if old_meta["timing_model"] != new_meta["timing_model"]:
            raise ValueError("timing models differ")
        output = f"# {old_meta['label']} → {new_meta['label']}\n\n" + compare(old, new)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(output)


if __name__ == "__main__":
    main()
