import unittest
from pathlib import Path
import tempfile

from prepare_vice_harness import patch_bridge, prepare, replace_once


class PrepareViceHarnessTests(unittest.TestCase):
    def test_connects_directly_with_retry_backoff(self):
        source = ('before\nawait WaitForPort(port, ct).ConfigureAwait(false);\n'
                  '_logger.LogError(ex, "Unknown exception occurred");\nafter\n')
        result = patch_bridge(source)
        self.assertNotIn("await WaitForPort", result)
        self.assertIn("await Task.Delay(100, ct).ConfigureAwait(false);", result)
        self.assertTrue(result.startswith("before\n"))
        self.assertTrue(result.endswith("after\n"))

    def test_changed_or_already_patched_source_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "expected one"):
            patch_bridge("// incompatible bridge")
        with self.assertRaisesRegex(ValueError, "expected one"):
            replace_once("marker marker", "marker", "replacement")

    def test_corrupt_archive_is_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "ViceTasks.Binary.csproj"
            source.write_text("source project")
            (root / "build").mkdir()
            (root / "build/vice-bridge.tar.gz").write_bytes(b"corrupt archive")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                prepare(root, source)
            self.assertFalse((root / "build/vice-harness").exists())


if __name__ == "__main__":
    unittest.main()
