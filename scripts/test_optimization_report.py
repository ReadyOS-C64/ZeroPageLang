from io import StringIO
from pathlib import Path
import tempfile
import unittest

from optimization_report import (
    ABI_BENCHMARK_DIR, abi_size_table, abi_snapshot, compare, host_measurements, input_digest, snapshot,
)


class OptimizationReportTests(unittest.TestCase):
    def row(self, size=20, cycles=80, **changes):
        return dict(source="test.zp64", source_sha256="same", prg_bytes=size,
                    cycles=cycles, instructions=20, intercepted_calls=1) | changes

    def test_size_improvement_can_have_performance_regression(self):
        report = compare({"test.zp64": self.row()}, {"test.zp64": self.row(size=15, cycles=90)})
        self.assertIn("| 20 | 15 | -5 | 80 | 90 | 10 |", report)

    def test_corpus_changes_are_visible_and_not_counted_as_savings(self):
        report = compare({"old": self.row()}, {"new": self.row(size=1)})
        self.assertIn("PRG delta: +0 bytes", report)
        self.assertIn("New artifacts (excluded from delta): new", report)
        self.assertIn("Missing artifacts (excluded from delta): old", report)

    def test_changed_source_is_not_a_compiler_improvement(self):
        with self.assertRaisesRegex(ValueError, "source changed"):
            compare({"test": self.row()}, {"test": self.row(source_sha256="different")})

    def test_interceptor_changes_require_investigation(self):
        with self.assertRaisesRegex(ValueError, "intercepted call count changed"):
            compare({"test": self.row()}, {"test": self.row(intercepted_calls=2)})

    def test_abi_comparison_retains_both_unchanged_variants_and_stack_usage(self):
        static_path = str(ABI_BENCHMARK_DIR / "leaf_static.zp64")
        stack_path = str(ABI_BENCHMARK_DIR / "leaf_stack.zp64")
        rows = {
            static_path: self.row(size=168, cycles=10045, static_frame_bytes=13, hardware_stack_peak=3),
            stack_path: self.row(size=329, cycles=26383, static_frame_bytes=5, hardware_stack_peak=5,
                                 software_stack_written=8, software_stack_capacity=256),
        }
        report = compare(rows, rows)
        self.assertIn("Common artifacts: 2; changed: 0", report)
        self.assertIn("| leaf | 168 | 329 | +161 | 10,045 | 26,383 | +16,338 | 13 / 5 | 3 / 5 | 8 / 256 |", report)
        self.assertIn("| leaf | static | 168 → 168 | 10045 → 10045 |", report)
        self.assertIn("| leaf | stack | 329 → 329 | 26383 → 26383 |", report)
        self.assertIn("| 8 → 8 | 256 → 256 |", report)

    def test_abi_comparison_rejects_a_missing_variant(self):
        with self.assertRaisesRegex(ValueError, "incomplete ABI pair"):
            compare({}, {str(ABI_BENCHMARK_DIR / "leaf_stack.zp64"): self.row()})

    def test_size_report_uses_canonical_abi_artifacts_and_baseline_deltas(self):
        header = "path\tprg_bytes\tdelta_bytes\n"
        prefix = "build/emu/tests_fixtures_emu_lang_pass_optimization_reference_abi_calls_"
        lines = [f"{prefix}{workload}_static_zp64.prg\t168\t0\n"
                 f"{prefix}{workload}_stack_zp64.prg\t309\t-20\n"
                 for workload in ("branch", "leaf", "nested")]
        archive = "build/archive/tests_fixtures_emu_lang_pass_optimization_reference_abi_calls_leaf_stack_zp64.prg\t900\t\n"
        report = abi_size_table(StringIO(header + archive + "".join(lines)))
        for workload in ("branch", "leaf", "nested"):
            self.assertIn(f"| {workload} | 168 | 309 | +141 | +0 | -20 |", report)
        self.assertNotIn("900", report)
        with self.assertRaisesRegex(ValueError, "does not cover every ABI benchmark variant"):
            abi_size_table(StringIO(header + archive))
        with self.assertRaisesRegex(ValueError, "does not cover every ABI benchmark variant"):
            abi_size_table(StringIO(header + "".join(lines[:-1])))

    def test_stack_metrics_attach_to_their_own_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "fixture.zp64"
            source.write_text("export fn main() void {}")
            artifact = Path(directory) / "fixture.prg"
            artifact.write_bytes(b"1234")
            host = f"host-metrics\t{source}\t{artifact}\t4\t80\t20\t1\n"
            stack = f"host-stack-metrics\t{source}\t5\t8\t256\n"
            row = host_measurements(stack + host)[str(source)]
            self.assertEqual((row["hardware_stack_peak"], row["software_stack_written"],
                              row["software_stack_capacity"]), (5, 8, 256))
            with self.assertRaisesRegex(ValueError, "duplicate stack measurement"):
                host_measurements(host + stack + stack)

    def test_abi_snapshot_rejects_an_unrelated_targeted_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "fixture.prg"
            artifact.write_bytes(b"1234")
            source = Path(directory) / "fixture.zp64"
            source.write_text("export fn main() void {}")
            log = Path(directory) / "host.log"
            log.write_text(f"host-metrics\t{source}\t{artifact}\t4\t80\t20\t1\n"
                           "targeted-peddle filter=fixture: 1 language pass, 0 compile-fail, "
                           "0 runtime-fail, 0 smoke cases\n")
            with self.assertRaisesRegex(ValueError, "does not cover every benchmark variant"):
                abi_snapshot(log)

    def test_partial_suite_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "emu.log"
            log.write_text("host-emulated one-case\n")
            with self.assertRaisesRegex(ValueError, "full-suite completion"):
                snapshot(log, [])

    def test_full_snapshot_requires_abi_workloads_even_if_footer_matches(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "fixture.zp64"
            source.write_text("export fn main() void {}")
            artifact = Path(directory) / "fixture.prg"
            artifact.write_bytes(b"1234")
            log = Path(directory) / "emu.log"
            log.write_text(f"host-metrics\t{source}\t{artifact}\t4\t80\t20\t1\n"
                           "host-emulated 1 language pass, 0 smoke cases\n")
            with self.assertRaisesRegex(ValueError, "full suite does not cover every ABI benchmark variant"):
                snapshot(log, [])

    def test_import_changes_affect_input_hash_and_import_cycles_terminate(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "main.zp64"
            imported = Path(directory) / "module.zp64"
            source.write_text('const lib = @import("module.zp64");')
            imported.write_text('const main = @import("main.zp64");')
            before = input_digest(source)
            imported.write_text(imported.read_text() + "\n// changed")
            self.assertNotEqual(before, input_digest(source))

    def test_stale_artifact_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "test.prg"
            artifact.write_bytes(b"1234")
            log = Path(directory) / "emu.log"
            log.write_text(f"host-metrics\ttest.zp64\t{artifact}\t3\t80\t20\t1\n"
                           "host-emulated 1 language pass, 0 smoke cases\n")
            with self.assertRaisesRegex(ValueError, "artifact changed"):
                snapshot(log, [])

    def test_completed_suite_with_truncated_metrics_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "test.zp64"
            source.write_text("export fn main() void {}")
            artifact = Path(directory) / "test.prg"
            artifact.write_bytes(b"1234")
            log = Path(directory) / "emu.log"
            log.write_text(f"host-metrics\t{source}\t{artifact}\t4\t80\t20\t1\n"
                           "host-emulated 2 language pass, 0 smoke cases\n")
            with self.assertRaisesRegex(ValueError, "expected 2 passing cases, found 1"):
                snapshot(log, [])


if __name__ == "__main__":
    unittest.main()
