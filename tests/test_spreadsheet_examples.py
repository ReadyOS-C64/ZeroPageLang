import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from spreadsheet_examples import SAMPLES, chain_workbook, from_text, workbook


class SpreadsheetExamplesTest(unittest.TestCase):
    @staticmethod
    def record(data, index):
        offset = 5 + index * 32
        return data[offset:offset + 32]

    def test_legacy_record_order_and_petscii_bytes(self):
        data = workbook({"A1": "7", "B1": "=A1*3", "P96": "END"}, legacy=True)
        self.assertEqual(data[:5], b"ZPSH\x01")
        self.assertEqual(len(data), 49157)
        self.assertEqual(self.record(data, 0), b"\x01" + b"7" + bytes(30))
        self.assertEqual(self.record(data, 1), b"\x05=A1*3" + bytes(26))
        self.assertEqual(self.record(data, 16), bytes(32))
        self.assertEqual(self.record(data, 1535), b"\x03END" + bytes(28))

    def test_sparse_stream_omits_gaps_and_uses_little_endian_ids(self):
        self.assertEqual(workbook({}), b"ZPSH\x02\xff\xff")
        self.assertEqual(
            workbook({"P96": "END", "B1": "=A1*3", "A2": "", "A1": "7"}),
            b"ZPSH\x02\x00\x00\x017\x01\x00\x05=A1*3\xff\x05\x03END\xff\xff",
        )

    def test_chain_wraps_rows_and_reaches_last_cell(self):
        data = chain_workbook()
        self.assertIn(b"\x0f\x00\x05=A2+1", data)
        self.assertTrue(data.endswith(b"\xfe\x05\x06=P96+1\xff\x05\x011\xff\xff"))

    def test_column_format_header_keeps_sparse_records(self):
        data = workbook({"A1": "7"}, formats={"A": 4, "P": 2})
        self.assertEqual(data, b"ZPSH\x03\x04" + bytes(14) + b"\x02\x00\x00\x017\xff\xff")
        self.assertEqual(workbook({}, formats={"A": 0}), workbook({}))

    def test_v4_packs_width_and_text_mode_in_existing_header(self):
        data = workbook({"A1": "007"}, widths={"A": 10}, formats={"A": 1, "P": 4})
        self.assertEqual(data, b"ZPSH\x04\xa1" + bytes(14) + b"\x04\x00\x00\x03007\xff\xff")
        with self.assertRaises(ValueError):
            workbook({}, widths={"A": 13})

    def test_odd_column_widths_use_v6(self):
        data = workbook({}, widths={"A": 7})
        self.assertEqual(data, b"ZPSH\x06\x70" + bytes(19) + b"\x06\xff\xff")

    def test_saved_view_keeps_the_selection_and_scroll_origin(self):
        data = workbook({"P96": "7"}, view=(95, 15, 78, 12, 9))
        self.assertEqual(data[:26], b"ZPSH\x06" + bytes(16) + bytes((95, 15, 78, 12, 9)))
        self.assertEqual(data[26:], b"\xff\x05\x017\xff\xff")
        for view in ((95, 15, 79, 12, 9), (12, 15, 13, 12, 9), (95, 11, 78, 12, 9)):
            with self.subTest(view=view), self.assertRaises(ValueError):
                workbook({}, view=view)

    def test_colors_are_sparse_sorted_and_can_precede_cell_entry(self):
        data = workbook({"A1": "7"}, colors={"P96": 14, "B1": 2, "A1": 7})
        self.assertEqual(data[26:], b"\x00\x00\x017\x00\x80\x07\x01\x80\x02\xff\x85\x0e\xff\xff")

    def test_rejects_values_the_example_generator_cannot_encode(self):
        for cells in ({"Q1": "1"}, {"A97": "1"}, {"A1": "A" * 32}, {"B1": "x\0"}):
            with self.subTest(cells=cells), self.assertRaises(ValueError):
                workbook(cells)

    def test_example_inputs_can_be_packaged(self):
        for name in ("budget", "errors", "forecast", "lab", "market", "orders", "rates", "shipping", "stock"):
            self.assertLess(len(from_text(SAMPLES / (name + ".tsv"))), 600)
