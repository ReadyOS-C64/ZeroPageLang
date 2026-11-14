import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/build_readyos_tictactoe.py"
APP_SOURCE = SCRIPT.parents[1] / "sampleapps/tictactoe_readyos/tictactoe_readyos.zp64"
TUI_SOURCE = SCRIPT.parents[1] / "sampleapps/tictactoe_readyos/readyos_tui.zp64"
SPEC = importlib.util.spec_from_file_location("build_readyos_tictactoe", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class ReadyOSTicTacToePackagingTests(unittest.TestCase):
    def test_catalog_autostarts_and_preloads_readyos_apps(self):
        source = b"[LAUNCHER]\rLOAD_ALL_TO_REU=0\rRUNAPPFIRST=\r[APPS]\r"
        result = MODULE.patch_catalog(source)
        self.assertIn(b"LOAD_ALL_TO_REU=1\r", result)
        self.assertIn(b"RUNAPPFIRST=TICTACTOE\r", result)
        self.assertIn(b"8:EDITOR:EDITOR:1\r", result)
        self.assertTrue(result.endswith(b"ZEROPAGE READYOS TUI GAME\r"))

    def test_readyos_directory_groups_do_not_compete(self):
        entries = [
            {"name": "rbtest1", "type": "prg"},
            {"name": "rsparser", "type": "prg"},
            {"name": "tictactoe", "type": "prg"},
            {"name": "apps.cfg", "type": "seq"},
            {"name": "preboot", "type": "prg"},
            {"name": "cal26.rel", "type": "rel"},
        ]
        names = [entry["name"] for entry in MODULE.ordered(entries)]
        self.assertEqual(names, ["preboot", "apps.cfg", "tictactoe", "rsparser", "cal26.rel", "rbtest1"])

    def test_vice_plan_exercises_readyos_ui_and_help(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "plan.yaml"
            MODULE.write_plan(path, Path("readyos.d81"), Path("preboot.prg"))
            text = path.read_text(encoding="utf-8")
        self.assertIn("keys: [140]", text)
        self.assertIn("TIC TAC TOE HELP", text)
        self.assertIn("MODE:1 PLAYER  HUMAN:X  CPU:O", text)
        self.assertIn("MODE:2 PLAYER  PLAYERS:X/O", text)
        self.assertIn('contains: "TURN:O"', text)
        self.assertIn('not_contains: "NO WINNING LINES"', text)
        self.assertIn("type: assert.screen_not_contains", text)
        self.assertIn('not_contains: "F2:NEXT APP"', text)
        self.assertIn("label: tictactoe_readyos_cursor_moved", text)
        self.assertIn('contains: "START A NEW GAME"', text)
        self.assertIn('contains: "F1  TWO PLAYER"', text)
        self.assertIn('contains: "F3  ONE PLAYER / AI"', text)
        self.assertIn("label: tictactoe_readyos_invalid", text)
        self.assertIn("max_attempts: 4", text)
        self.assertEqual(text.count('params: { command: "warp on" }'), 1)
        self.assertNotIn("keys: [137]", text)
        self.assertNotIn("keys: [138]", text)
        self.assertNotIn("keys: [2]", text)

    def test_game_uses_incremental_rendering_and_column_zero_header(self):
        app = APP_SOURCE.read_text(encoding="utf-8")
        tui = TUI_SOURCE.read_text(encoding="utf-8")
        self.assertIn("fn renderDelta(", app)
        self.assertIn("copyBoard(&previous_board, &game.board)", app)
        self.assertIn("drawCell(board, i, game.cursor)", app)
        self.assertIn("if (previous_outcome == .playing)", app)
        self.assertIn("if (redraw_all != 0)", app)
        self.assertEqual(app.count("render(&game);"), 2)
        self.assertIn("return 1;", app)
        self.assertIn("return 7;", app)
        self.assertIn("sta $0400", tui)
        self.assertIn("sta $0428", tui)
        self.assertIn("sta $0450", tui)
        self.assertIn("fn drawResultWindow()", tui)

    def test_switch_plan_isolates_normal_f2_f4_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "switch.yaml"
            MODULE.write_switch_plan(path, Path("readyos.d81"), Path("preboot.prg"))
            text = path.read_text(encoding="utf-8")
        self.assertIn("keys: [137]", text)
        self.assertIn("keys: [138]", text)
        self.assertEqual(text.count('params: { command: "warp on" }'), 3)
        self.assertNotIn("keys: [140]", text)
        self.assertNotIn("keys: [2]", text)

    def test_ctrl_b_plan_isolated_from_cached_app_switches(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ctrl_b.yaml"
            MODULE.write_ctrl_b_plan(path, Path("readyos.d81"), Path("preboot.prg"))
            text = path.read_text(encoding="utf-8")
        self.assertIn("keys: [2]", text)
        self.assertIn("max_attempts: 4", text)
        self.assertEqual(text.count('params: { command: "warp on" }'), 2)
        self.assertNotIn("keys: [137]", text)
        self.assertNotIn("keys: [138]", text)


if __name__ == "__main__":
    unittest.main()
