#!/usr/bin/env python3
"""Build ZeroPage Sheet and package its two disk targets and VICE plans."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from build_readyos_tictactoe import disk_entries, extract, ordered, resolve_tool, verify_order, write_entry
from spreadsheet_help import generate
from spreadsheet_examples import SAMPLES, chain_workbook, from_text, workbook

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "sampleapps/spreadsheet"
READYOS = ROOT.parent / "readyosprecog"
READYOS_MANIFEST = READYOS / "Releases/0.5/precog-d81/manifest.json"

IMPORT_CELLS = {
    "A1": "CAFE", "A2": "ITEM", "B2": "PRICE", "C2": "TOTAL", "D2": "QTY",
    "A3": "APRON", "B3": "19.95", "C3": "=B3*D3", "D3": "2",
}
IMPORT_WIDTHS = {"A": 9, "B": 8, "C": 10, "D": 6, "E": 6, **dict.fromkeys("FGHIJ", 6)}
IMPORT_FORMATS = {"A": 1, "B": 4, "C": 4, "D": 2, "E": 3}
IMPORT_COLORS = {"A1": 7, **dict.fromkeys(("A2", "B2", "C2", "D2"), 14), "B3": 2}
IMPORT_VIEW = (2, 2, 0, 0, 6)


def command(*args: str | Path) -> None:
    subprocess.run(args, check=True)


def catalog(data: bytes) -> bytes:
    system, marker, _ = data.partition(b"[APPS]\r")
    if not marker or b"RUNAPPFIRST=" not in system:
        raise ValueError("unrecognized ReadyOS catalog")
    lines = system.split(b"\r")
    settings = {b"RUNAPPFIRST": b"ZSHEET", b"LOAD_ALL_TO_REU": b"1"}
    for index, line in enumerate(lines):
        key = line.partition(b"=")[0]
        if key in settings:
            lines[index] = key + b"=" + settings[key]
    return b"\r".join(lines) + marker + (
        b"8:EDITOR:EDITOR:1\rTEXT EDITOR WITH CLIPBOARD\r"
        b"8:ZSHEET:ZEROPAGE SHEET\rREU SPREADSHEET\r"
    )


def file_entry(path: Path, name: str | None = None, kind: str = "prg") -> dict:
    return {"name": name or path.stem, "type": kind, "host": path}


def make_disk(c1541: str, disk: Path, entries: list[dict]) -> None:
    if disk.exists():
        disk.unlink()
    command(c1541, "-format", "zeropage sheet,zs", disk.suffix[1:], disk)
    for entry in entries:
        write_entry(c1541, disk, entry)


def plan(path: Path, disk: Path, hosted: bool, test_fixtures: bool = False) -> None:
    drive_type = 1581 if disk.suffix == ".d81" else 1541
    boot = f"{disk}:{'preboot' if hosted else 'zsheet'}"
    lines = [
        "version: 1", "kind: vice_task_plan",
        f"plan_id: zeropage_sheet_{'readyos' if hosted else 'standalone'}",
        "run_mode: gui_vice", "global_defaults:", "  monitor_host: 127.0.0.1",
        "  monitor_port_start: 6532", "  monitor_port_span: 28",
        "  retry_policy: { max_attempts: 2, backoff_ms: 300, jitter: false }",
        "  timeouts: { launch_s: 45, step_s: 245, read_s: 2 }",
        "  artifact_policy: { capture_screen: true, capture_state: false, capture_dump: false }",
        "  vice:", f"    disk8: {json.dumps(str(disk))}",
        f"    autostart_prg: {json.dumps(boot)}",
        f"    drive8_type: {drive_type}", "    true_drive: false", "    close_vice: true",
        "    headless: true", f"    drive9_enabled: {str(not hosted).lower()}",
        f"    disk9: {json.dumps(str(disk.with_name('sheet-examples.d81')))}",
        "    drive9_type: 1581", "    speed_percent: 250", "steps:",
    ]

    def step(name: str, kind: str, **params: object) -> None:
        if kind == "screen.capture":
            params["include_border"] = True
        lines.extend((f"  - id: {name}", f"    type: {kind}", f"    params: {json.dumps(params)}"))

    def keys(name: str, *values: int | str) -> None:
        batch: list[int] = []
        for val in values:
            batch.extend(val.encode("ascii") if isinstance(val, str) else [val])
        step(name, "input.sequence", keys=batch, inter_key_delay_s=0.12, post_delay_s=0.3)

    def wait(name: str, value: str, seconds: int = 20) -> None:
        step(name, "screen.wait_contains", text=value, wait_timeout_s=seconds)

    step("launch", "vice.launch", kill_stale=False)
    step("warp", "monitor.command", command="warp on")
    # The harness decodes lowercase screen codes as ASCII uppercase and
    # skips uppercase glyphs. Check the exact title bytes below.
    wait("open_sheet", "ERO", 220 if hosted else 30)
    wait("grid_ready", "ARROWS MOVE")
    step("mixed_case_charset", "assert.memory", start=0xd018, end=0xd018, equals_hex="17")
    step("mixed_case_title", "assert.memory", start=0x040c, end=0x0419,
         equals_hex="5a 05 12 0f 50 01 07 05 20 53 08 05 05 14")
    keys("edit_a1", 13, "7", 13)
    keys("move_to_b1", 29, 134)
    wait("formula_dialog", "DIT FORMULA")
    keys("set_b1", "A1*3", 13)
    keys("move_to_c1", 29, 134)
    keys("set_c1", "B1+8", 13)
    wait("chained_result", "1+8")
    step("c1_screen", "screen.capture", label="c1_screen")
    step("c1_value", "assert.memory", start=0x04dc, end=0x04dd, equals_hex="b2 b9")
    keys("move_to_d1", 29, 134)
    keys("set_d1", "SUM(A1:C1)", 13)
    wait("range_result", "...(.1:.1)")
    step("capital_function_name", "assert.memory", start=0x047e, end=0x0480, equals_hex="53 55 4d")
    step("d1_screen", "screen.capture", label="d1_screen")
    step("d1_value", "assert.memory", start=0x04e2, end=0x04e3, equals_hex="b5 b7")
    if hosted:
        keys("next_app", 137)
        wait("editor_loaded", "EDITOR", 120)
        keys("previous_app", 138)
        wait("sheet_resumed", "ERO", 120)
        wait("retained_formula", "...(.1:.1)")
    keys("save_dialog", 135)
    wait("save_prompt", "AVE WORKBOOK")
    keys("type_save_name", "PROOF")
    step("save_dialog_screen", "screen.capture", label="save-dialog")
    keys("write_book", 13)
    wait("saved", "WORKBOOK SAVED", 150)
    # The file frame's upper-left corner occupies the spacer in grid row 3.
    step("save_restores_row_gutter", "assert.memory", start=0x0518, end=0x051b,
         equals_hex="30 33 20 5d")
    keys("erase_d1", 20)
    keys("move_away_before_load", 157, 17, 139)
    keys("load_dialog", 136)
    wait("discard_prompt", "ISCARD UNSAVED EDITS?")
    step("confirm_screen", "screen.capture", label="discard-dialog")
    keys("confirm_discard", "Y")
    wait("load_prompt", "OAD WORKBOOK")
    keys("type_load_name", "PROOF")
    step("load_dialog_screen", "screen.capture", label="load-dialog")
    keys("read_book", 13)
    wait("loaded", "WORKBOOK LOADED", 150)
    wait("restored_formula", "...(.1:.1)")
    step("disk_restores_selection", "assert.memory", start=0x0430, end=0x0432, equals_hex="04 30 31")
    step("disk_restores_default_width", "assert.memory", start=0xc0f6, end=0xc0f6, equals_hex="06")
    keys("open_help", 140)
    wait("help_index", "UICK START")
    step("help_screen", "screen.capture", label="help-index")
    keys("formula_help", "2")
    wait("formula_help_visible", "ORMULA BASICS")
    keys("function_help", "3")
    wait("function_help_visible", "FORMULA ERRORS PROPAGATE.")
    step("function_help_screen", "screen.capture", label="help-functions")
    keys("dismiss_help", 13)
    wait("sheet_restored", "...(.1:.1)")
    wait("help_status_restored", "ARROWS MOVE")
    step("help_restores_row_gutter", "assert.memory", start=0x0748, end=0x074b,
         equals_hex="31 37 20 5d")
    keys("open_bad_load", 136)
    wait("bad_load_prompt", "OAD WORKBOOK")
    keys("load_other_seq_file", "ZSPAGES", 13)
    wait("reject_bad_file", "FILE ERROR - SHEET UNCHANGED")
    wait("retain_old_formula", "...(.1:.1)")
    if hosted and test_fixtures:
        # PROOF was loaded from disk above. Edit it before and after a trip
        # through the launcher so both edits must survive in the saved copy.
        keys("resume_select_a1", 157, 157, 157)
        keys("resume_clear_a1", 20)
        keys("resume_begin_a1", 13)
        keys("resume_edit_a1", "1", "1", 13)
        keys("resume_select_d1", 29, 29, 29)
        step("resume_result_before_switch", "assert.memory", start=0x04e2, end=0x04e3,
             equals_hex="b8 b5")
        keys("resume_open_launcher", 2)
        wait("resume_launcher_from_sheet", "READY OS", 60)
        keys("resume_launch_editor", 145, 13)
        wait("resume_in_editor", "EDITOR:", 60)
        keys("resume_leave_editor", 2)
        wait("resume_launcher_from_editor", "READY OS", 60)
        keys("resume_launch_sheet", 17, 13)
        wait("resume_in_sheet", "ARROWS MOVE", 60)
        step("resume_retains_selected_result", "assert.memory", start=0x04e2, end=0x04e3,
             equals_hex="b8 b5")
        step("resume_retains_unsaved_flag", "assert.memory", start=0x044d, end=0x044d,
             equals_hex="2a")
        keys("resume_edit_b1", 157, 157, 13, 20, "4", 13)
        keys("resume_reselect_d1", 29, 29)
        step("resume_recalculated_result", "assert.memory", start=0x04e1, end=0x04e3,
             equals_hex="b1 b0 b7")
        keys("resume_open_save", 135)
        wait("resume_save_prompt", "AVE WORKBOOK")
        keys("resume_write_copy", "RESUME-PROOF", 13)
        wait("resume_copy_saved", "WORKBOOK SAVED", 150)
        keys("resume_open_saved_copy", 136)
        wait("resume_load_prompt", "OAD WORKBOOK")
        keys("resume_load_saved_copy", "RESUME-PROOF", 13)
        wait("resume_copy_loaded", "WORKBOOK LOADED", 150)
        step("resume_result_from_disk", "assert.memory", start=0x04e1, end=0x04e3,
             equals_hex="b1 b0 b7")
    if test_fixtures:
        for filename in ("TRUNCATED", "DUPLICATE", "TRAILING", "BAD-CELL", "BAD-VIEW", "BAD-COLOR"):
            keys("open_" + filename.lower(), 136)
            wait("prompt_" + filename.lower(), "OAD WORKBOOK")
            keys("read_" + filename.lower(), filename, 13)
            wait("reject_" + filename.lower(), "FILE ERROR - SHEET UNCHANGED")
            wait("retain_" + filename.lower(), "...(.1:.1)")
        keys("open_legacy", 136)
        wait("prompt_legacy", "OAD WORKBOOK")
        keys("read_legacy", "LEGACY", 13)
        wait("legacy_loaded", "WORKBOOK LOADED")
        wait("legacy_formula", ".1*3")
        keys("clear_legacy_status", 140)
        wait("legacy_help_open", "UICK START")
        keys("close_legacy_help", 13)
        wait("legacy_help_closed", "ARROWS MOVE")
        keys("open_empty", 136)
        wait("prompt_empty", "OAD WORKBOOK")
        keys("read_empty", "EMPTY", 13)
        wait("empty_loaded", "WORKBOOK LOADED")
        step("empty_replaces_a1", "assert.memory", start=0x04d1, end=0x04d1, equals_hex="20")
        step("empty_replaces_d1", "assert.memory", start=0x04e3, end=0x04e3, equals_hex="a0")
        keys("clear_empty_status", 140)
        wait("empty_help_open", "UICK START")
        keys("close_empty_help", 13)
        wait("empty_help_closed", "ARROWS MOVE")

    keys("select_a1", 157, 157, 157)
    keys("open_chain", 136)
    wait("chain_load_prompt", "OAD WORKBOOK")
    keys("load_chain", "CHAIN", 13)
    wait("all_1536_cells_calculated", "WORKBOOK LOADED", 180)
    step("full_depth_result", "assert.memory", start=0x04ce, end=0x04d1, equals_hex="b1 b5 b3 b6")
    step("chain_screen", "screen.capture", label="chain_screen")
    keys("wide_layout", 139)
    step("wide_a1_value", "assert.memory", start=0x04d1, end=0x04d4, equals_hex="b1 b5 b3 b6")
    keys("compact_layout", 139)
    step("compact_a1_value", "assert.memory", start=0x04ce, end=0x04d1, equals_hex="b1 b5 b3 b6")
    if test_fixtures:
        keys("open_chain_save", 135)
        wait("chain_save_prompt", "AVE WORKBOOK")
        keys("save_chain_copy", "CHAIN-COPY", 13)
        wait("chain_copy_saved", "WORKBOOK SAVED", 150)
        keys("saved_view_scroll", *([29] * 15 + [17] * 20), 139)
        keys("saved_view_save", 135)
        wait("saved_view_save_prompt", "AVE WORKBOOK")
        keys("saved_view_write", "SCROLLED", 13)
        wait("saved_view_saved", "WORKBOOK SAVED")
        keys("saved_view_move_away", 157, 145, 139)
        keys("saved_view_load", 136)
        wait("saved_view_load_prompt", "OAD WORKBOOK")
        keys("saved_view_read", "SCROLLED", 13)
        wait("saved_view_loaded", "WORKBOOK LOADED")
        step("saved_view_reappears", "assert.memory", start=0x0430, end=0x0432, equals_hex="10 32 31")
        step("saved_view_dimensions", "assert.memory", start=0xc0ca, end=0xc0ce, equals_hex="14 0f 03 0c 09")
        step("saved_view_screen", "screen.capture", label="saved-view")
        keys("return_to_a1_from_scrolled", 139, *([157] * 15 + [145] * 20))
    if hosted:
        def open_demo(name: str, header: str, *, step_name: str | None = None) -> None:
            tag = step_name or name
            keys(f"open_{tag}", 136)
            wait(f"prompt_{tag}", "OAD WORKBOOK")
            keys(f"read_{tag}", name.upper(), 13)
            wait(f"loaded_{tag}", header)
            wait(f"ready_{tag}", "WORKBOOK LOADED")

        open_demo("budget", "BIG LO")
        step("budget_compact_screen", "screen.capture", label="budget-compact")
        keys("budget_wide", 139)
        wait("budget_labels", "CATEGORY")
        step("budget_positive", "assert.memory", start=0x0566, end=0x0567, equals_hex="31 35")
        step("budget_screen", "screen.capture", label="budget-wide")
        keys("budget_compact", 139)
        if test_fixtures:
            keys("budget_select_min", *([29] * 3 + [17] * 11))
            step("budget_min_screen", "screen.capture", label="formula-min")
            keys("budget_return_origin", *([157] * 3 + [145] * 11))
        open_demo("stock", "REORDE")
        step("stock_screen", "screen.capture", label="stock")
        open_demo("lab", "STRESS")
        keys("lab_select_final", *([29] * 5 + [17] * 13))
        wait("lab_formula", ".....(.2:.6)")
        step("lab_final", "assert.memory", start=0x06f3, end=0x06f7, equals_hex="b7 b8 ae b1 b6")
        step("lab_screen", "screen.capture", label="lab-chain")
        if test_fixtures:
            keys("lab_select_product", 145, 145)
            step("lab_product_screen", "screen.capture", label="formula-prod")
            keys("lab_select_maximum", 145, 145)
            step("lab_maximum_screen", "screen.capture", label="formula-max")
            keys("lab_select_average", 145)
            step("lab_average_screen", "screen.capture", label="formula-avg")
            keys("lab_select_sum", 145)
            step("lab_sum_screen", "screen.capture", label="formula-sum")
            keys("lab_select_absolute", *([145] * 6))
            step("lab_absolute_screen", "screen.capture", label="formula-abs")
            keys("lab_reselect_final", *([17] * 12))
        keys("edit_final_formula", 134)
        wait("final_formula_editor", "DIT FORMULA")
        step("long_formula_editor", "screen.capture", label="formula-editor")
        keys("cancel_formula_edit", 3)
        keys("return_origin", *([157] * 5 + [145] * 13))
        open_demo("errors", "#CYCLE")
        step("errors_screen", "screen.capture", label="formula-errors")
        if test_fixtures:
            open_demo("budget", "BIG LO", step_name="fill_budget")
    else:
        keys("open_drive9_load", 136)
        wait("drive9_load_prompt", "OAD WORKBOOK")
        keys("choose_drive9", 133, "BUDGET", 13)
        wait("drive9_workbook", "BIG LO")
        wait("drive9_loaded", "WORKBOOK LOADED")
    if test_fixtures:
        # Copy from a blank-area formula cell and fill down two rows. Lock
        # the source column of the first endpoint and row of the second.
        keys("fill_select_a15", *([17] * 14))
        keys("fill_enter_formula", 13, "=SUM($B2:C$7)", 13)
        if hosted:
            step("fill_source_screen", "screen.capture", label="formula-fill-source")
        keys("fill_copy_and_extend", "C", 17, 17, "D")
        step("fill_rewrites_range", "assert.memory", start=0x047d, end=0x0488,
             equals_hex="3d 53 55 4d 28 24 42 34 3a 43 24 37")
        if hosted:
            step("fill_last_screen", "screen.capture", label="formula-fill-last")
        keys("fill_select_previous_row", 145)
        step("fill_writes_intermediate_row", "assert.memory", start=0x0484, end=0x0484, equals_hex="33")
        if hosted:
            step("fill_formula_screen", "screen.capture", label="formula-fill")
        keys("float_enter_decimal", 29, 13, "19.95", 13)
        step("float_literal_visible", "assert.memory", start=0x072b, end=0x072f,
             equals_hex="b1 b9 ae b9 b5")
        keys("float_enter_chain", 29, 13, "=B16/2+1.025", 13)
        step("float_formula_visible", "assert.memory", start=0x0734, end=0x0735,
             equals_hex="b1 b1")
        keys("float_enter_overflow", 29, 13, "=1E99", 13)
        step("float_overflow_screen", "screen.capture", label="float-overflow")
        step("float_overflow_returns_to_sheet", "assert.memory", start=0x0736, end=0x0739,
             equals_hex="a3 8e 95 8d")
        keys("float_if", 29, 13, "=IF(B16>19,8,9)", 13)
        step("float_if_value", "assert.memory", start=0x0741, end=0x0741, equals_hex="b8")
        keys("float_lookup", 29, 13, "=LOOKUP(B16,B15:B17,C15:C17)", 13)
        step("float_lookup_value", "assert.memory", start=0x0746, end=0x0747, equals_hex="b1 b1")
        keys("float_sum", 17, 13, "=SUM(B16:C16)", 13)
        step("mixed_sum_value", "assert.memory", start=0x076b, end=0x076f, equals_hex="b3 b0 ae b9 b5")
        keys("float_integer_division", 157, 13, "=5/2", 13)
        step("float_fractional_quotient", "assert.memory", start=0x0767, end=0x0769, equals_hex="b2 ae b5")
        keys("parity_edit_inside_formula", 13, 157, 157, 20, "7", 13)
        step("parity_keeps_formula_suffix", "assert.memory", start=0x0767, end=0x0769, equals_hex="b3 ae b5")
        keys("parity_large_product", 157, 13, "=200*200", 13)
        step("parity_product_does_not_wrap", "assert.memory", start=0x075f, end=0x0763, equals_hex="b4 b0 b0 b0 b0")
        keys("parity_large_sum", 157, 13, "=30000+30000", 13)
        step("parity_sum_does_not_wrap", "assert.memory", start=0x0759, end=0x075d, equals_hex="b6 b0 b0 b0 b0")
        keys("parity_integer_average", 29, 29, 29, 20, 13, "=AVG(B15:C15)", 13)
        keys("parity_avg_inputs", 145, 145, 157, 157, 157, 157, 13, "1", 13, 29, 13, "2", 13)
        keys("parity_select_average", 29, 29, 29, 17, 17)
        step("parity_fractional_average", "assert.memory", start=0x076d, end=0x076f, equals_hex="b1 ae b5")
        keys("open_format_menu", "F")
        wait("format_menu_open", "ORMAT COLUMN")
        keys("format_select_currency", 17, 17, 17, 17)
        step("format_menu_screen", "screen.capture", label="format-menu")
        keys("format_apply_currency", 13)
        step("format_currency_fraction", "assert.memory", start=0x076b, end=0x076f,
             equals_hex="a4 b1 ae b5 b0")
        step("format_currency_integer", "assert.memory", start=0x0742, end=0x0747,
             equals_hex="24 31 31 2e 30 30")
        step("currency_screen", "screen.capture", label="format-currency")
        keys("format_decimal", "F", 145, 13)
        step("format_decimal_fraction", "assert.memory", start=0x076c, end=0x076f,
             equals_hex="b1 ae b5 b0")
        keys("format_integer", "F", 145, 13)
        step("format_integer_rounds", "assert.memory", start=0x076f, end=0x076f,
             equals_hex="b2")
        keys("format_restore_general", "F", 145, 145, 13)
        keys("rates_open_load", 136)
        wait("rates_discard_prompt", "ISCARD UNSAVED EDITS?")
        keys("rates_discard", "Y")
        wait("rates_load_prompt", "OAD WORKBOOK")
        if not hosted:
            keys("rates_use_program_disk", 133)
        keys("rates_load_demo", "RATES", 13)
        wait("rates_loaded", "WORKBOOK LOADED")
        keys("rates_return_to_origin", *([157] * 4 + [145] * 16))
        keys("rates_wide_display", 139)
        step("rates_both_if_branches", "assert.memory", start=0x053f, end=0x053f, equals_hex="31")
        step("rates_scientific_lookup", "assert.memory", start=0x057a, end=0x057d, equals_hex="2e 30 32 35")
        step("rates_screen", "screen.capture", label="rates")
        if hosted:
            keys("rates_select_if", 29, 29, 29, 17)
            step("rates_if_screen", "screen.capture", label="formula-if")
            keys("rates_select_lookup", 157, 157, 17, 17, 17)
            step("rates_lookup_screen", "screen.capture", label="formula-lookup")
            keys("rates_select_charge", 17)
            step("rates_charge_screen", "screen.capture", label="formula-charge")
        keys("rates_restore_compact", 139)
        keys("rates_select_format_column", *([157] * 6 + [145] * 16), 29)
        keys("rates_open_format", "F")
        wait("rates_format_prompt", "ORMAT COLUMN")
        keys("rates_set_currency", 17, 17, 17, 17, 13)
        step("rates_currency_is_set", "assert.memory", start=0xc311, end=0xc311, equals_hex="04")
        keys("rates_open_save", 135)
        wait("rates_save_prompt", "AVE WORKBOOK")
        keys("rates_save_copy", "RATES-COPY", 13)
        wait("rates_copy_saved", "WORKBOOK SAVED")
        keys("rates_reopen_format", "F")
        wait("rates_reformat_prompt", "ORMAT COLUMN")
        keys("rates_remove_currency", 145, 145, 145, 145, 13)
        step("rates_currency_is_removed", "assert.memory", start=0xc311, end=0xc311, equals_hex="00")
        keys("rates_reload_open", 136)
        wait("rates_reformat_discard", "ISCARD UNSAVED EDITS?")
        keys("rates_reformat_confirm", "Y")
        wait("rates_reload_prompt", "OAD WORKBOOK")
        keys("rates_reload_copy", "RATES-COPY", 13)
        wait("rates_reload_done", "WORKBOOK LOADED")
        step("rates_currency_restored", "assert.memory", start=0xc311, end=0xc311, equals_hex="04")
        keys("rates_currency_widen", 157, 139)
        step("rates_currency_visible", "assert.memory", start=0x0500, end=0x0505,
             equals_hex="24 31 39 2e 39 35")
        step("rates_currency_screen", "screen.capture", label="rates-currency")
        for book, label in (("MARKET", "market-sales"), ("SHIPPING", "parcel-quote")):
            keys("open_" + label, 136)
            wait("prompt_" + label, "OAD WORKBOOK")
            keys("read_" + label, book, 13)
            wait("loaded_" + label, "WORKBOOK LOADED")
            keys("origin_" + label, *([157] * 5 + [145] * 16))
            if book == "MARKET":
                step("market_widths", "assert.memory", start=0xc310, end=0xc313,
                     equals_hex="a0 62 a4 a4")
                keys("market_select_widths", "F")
                wait("market_width_prompt", "ORMAT COLUMN")
                keys("market_reduce_width", 157, 13)
                step("market_width_changes", "assert.memory", start=0xc321, end=0xc321, equals_hex="0c")
                keys("market_restore_width_menu", "F")
                wait("market_restore_width_prompt", "ORMAT COLUMN")
                keys("market_restore_width", 29, 13)
                keys("market_pick_formula", *([29] * 3 + [17] * 14))
                step("market_fee", "assert.memory", start=0x071b, end=0x071f,
                     equals_hex="b4 b5 ae b0 b0")
                keys("market_show_format", "F")
                wait("market_show_format_prompt", "ORMAT COLUMN")
                step("market_width_label", "assert.memory", start=0x063e, end=0x063f, equals_hex="31 30")
                step("market_format", "screen.capture", label="market-format")
                keys("market_close_format", 3)
                keys("market_save", 135)
                wait("market_save_open", "AVE WORKBOOK")
                keys("market_save_copy", "MARKET-COPY", 13)
                wait("market_copy_saved", "WORKBOOK SAVED")
            else:
                keys("shipping_pick_lookup", *([29] * 3 + [17] * 3))
                step("shipping_lookup", "assert.memory", start=0x0563, end=0x0567,
                     equals_hex="a4 b3 ae b5 b0")
            step(label, "screen.capture", label=label)
        keys("browser_dialog", 136)
        wait("browser_load_prompt", "OAD WORKBOOK")
        keys("browser_open", 134)
        wait("browser_visible", "ROWSE WORKBOOKS")
        keys("browser_next_page", 29)
        wait("browser_second_page_visible", "LEGACY")
        step("browser_later_page", "screen.capture", label="workbook-browser-page")
        keys("browser_previous_page", 157)
        wait("browser_first_page_restored", "MARKET")
        step("browser_first_page", "screen.capture", label="workbook-browser")
        if not hosted:
            keys("browser_drive9", 133)
            step("browser_uses_drive9", "assert.memory", start=0xc0c4, end=0xc0c4, equals_hex="09")
            keys("browser_drive9_highlight", 17)
            step("browser_drive9_screen", "screen.capture", label="workbook-browser-drive9")
            keys("browser_drive9_choose", 13)
            wait("browser_drive9_loaded", "WORKBOOK LOADED", 180)
            wait("browser_drive9_budget", "BIG LO")
            keys("browser_switch_back_dialog", 136)
            wait("browser_switch_back_prompt", "OAD WORKBOOK")
            keys("browser_switch_back", 133, 3)
        else:
            keys("browser_choose_chain", 17, 17, 13)
            wait("browser_loaded_chain", "WORKBOOK LOADED", 180)
            keys("browser_chain_origin", *([157] * 3 + [145] * 3))
            step("browser_chain_value", "assert.memory", start=0x04d1, end=0x04d4, equals_hex="b1 b5 b3 b6")
        keys("replace_select_a1", *([157] * 15 + [145] * 18))
        keys("replace_load_open", 136)
        wait("replace_load_prompt", "OAD WORKBOOK")
        keys("replace_load_fixture", "REPLACE-TEST", 13)
        wait("replace_fixture_loaded", "WORKBOOK LOADED")
        keys("replace_use_compact_width", 139)
        keys("replace_edit_a1", 13, 20, "9", 13)
        keys("replace_first_save", 135)
        wait("replace_first_prompt", "AVE WORKBOOK")
        keys("replace_try_plain_save", "REPLACE-TEST", 13)
        wait("replace_plain_refused", "FILE ERROR - SHEET UNCHANGED")
        step("replace_keeps_unsaved", "assert.memory", start=0x044d, end=0x044d, equals_hex="2a")
        keys("replace_confirm_prompt", 135)
        wait("replace_confirm_visible", "REPLACE SAME NAME")
        keys("replace_type_name", "REPLACE-TEST")
        step("replace_save_screen", "screen.capture", label="replace-workbook")
        keys("replace_commit", 134)
        wait("replace_saved", "WORKBOOK SAVED")
        keys("replace_reopen", 136)
        wait("replace_reopen_prompt", "OAD WORKBOOK")
        keys("replace_reopen_book", "REPLACE-TEST", 13)
        wait("replace_reopened", "WORKBOOK LOADED")
        step("replace_reopened_value", "assert.memory", start=0x04d1, end=0x04d1, equals_hex="b9")
        keys("color_format_open", "F")
        wait("color_format_ready", "ORMAT COLUMN")
        keys("color_picker_open", 134)
        wait("color_picker_ready", "ELL COLOR")
        keys("color_picker_red", 17, 17, 17)
        step("color_picker_capture", "screen.capture", label="cell-color")
        keys("color_apply", 13)
        keys("color_copy", "C", 29, "V", 29)
        step("color_paste_nibbles", "assert.memory", start=0xc340, end=0xc340, equals_hex="22")
        keys("color_save_open", 135)
        wait("color_save_prompt", "AVE WORKBOOK")
        keys("color_save_copy", "COLOR-COPY", 13)
        wait("color_saved", "WORKBOOK SAVED")
        keys("color_load_open", 136)
        wait("color_load_prompt", "OAD WORKBOOK")
        keys("color_read_copy", "COLOR-COPY", 13)
        wait("color_loaded", "WORKBOOK LOADED")
        step("color_restored_nibbles", "assert.memory", start=0xc340, end=0xc340, equals_hex="22")
        keys("color_chain_jump", 157, 157, 17, 17, "D", 29)
        step("color_fill_nibble", "assert.memory", start=0xc350, end=0xc350, equals_hex="02")
        keys("color_delete_open", 157, 20, 29)
        step("color_clear_nibble", "assert.memory", start=0xc350, end=0xc350, equals_hex="00")
        keys("forecast_open", 136)
        wait("forecast_discard", "ISCARD UNSAVED EDITS?")
        keys("forecast_discard_yes", "Y")
        wait("forecast_prompt", "OAD WORKBOOK")
        keys("forecast_read", "FORECAST", 13)
        wait("forecast_loaded", "WORKBOOK LOADED")
        keys("forecast_select_total", *([29] * 3 + [17] * 12))
        step("forecast_final_cash", "assert.memory", start=0x06c9, end=0x06cf,
             equals_hex="a4 b3 b0 b4 ae b2 b5")
        step("forecast_title_color", "assert.memory", start=0xc340, end=0xc340, equals_hex="07")
        step("forecast_reserve_color", "assert.memory", start=0xc399, end=0xc399, equals_hex="20")
        step("forecast_gallery", "screen.capture", label="cash-forecast")
        keys("simplecells_open", 136)
        wait("simplecells_prompt", "OAD WORKBOOK")
        keys("simplecells_read", "SIMPLECELLS", 13)
        wait("simplecells_loaded", "WORKBOOK LOADED")
        step("simplecells_currency", "assert.memory", start=0x0531, end=0x0536, equals_hex="a4 b3 b9 ae b9 b0")
        step("simplecells_imported_columns", "assert.memory", start=0xc310, end=0xc314, equals_hex="91 84 a4 62 63")
        step("simplecells_imported_color", "assert.memory", start=0xc350, end=0xc350, equals_hex="20")
        step("simplecells_imported_view", "assert.memory", start=0xc0ca, end=0xc0ce, equals_hex="02 02 00 00 06")
        step("simplecells_gallery", "screen.capture", label="simplecells-import")
        keys("simplecells_truncated_open", 136)
        wait("simplecells_truncated_prompt", "OAD WORKBOOK")
        keys("simplecells_truncated_read", "SCLS-TRUNCATED", 13)
        wait("simplecells_truncated_rejected", "FILE ERROR - SHEET UNCHANGED")
        step("simplecells_unchanged", "assert.memory", start=0x0531, end=0x0536, equals_hex="a4 b3 b9 ae b9 b0")
        step("simplecells_same_columns", "assert.memory", start=0xc310, end=0xc314, equals_hex="91 84 a4 62 63")
        step("simplecells_same_color", "assert.memory", start=0xc350, end=0xc350, equals_hex="20")
        keys("simplecells_save_open", 135)
        wait("simplecells_save_prompt", "AVE WORKBOOK")
        keys("simplecells_save_copy", "IMPORT-COPY", 13)
        wait("simplecells_saved", "WORKBOOK SAVED")
        keys("simplecells_copy_open", 136)
        wait("simplecells_copy_prompt", "OAD WORKBOOK")
        keys("simplecells_copy_read", "IMPORT-COPY", 13)
        wait("simplecells_copy_loaded", "WORKBOOK LOADED")
        step("simplecells_copy_currency", "assert.memory", start=0x0531, end=0x0536, equals_hex="a4 b3 b9 ae b9 b0")
        step("simplecells_copy_widths", "assert.memory", start=0xc310, end=0xc314, equals_hex="91 84 a4 62 63")
        keys("text_demo_open", 136)
        wait("text_demo_prompt", "OAD WORKBOOK")
        keys("text_demo_read", "ORDERS", 13)
        wait("text_demo_loaded", "WORKBOOK LOADED")
        # A9 joins a text cell, a quoted string, and an integer. A10
        # joins that cached result with the text selected by IF.
        step("text_label", "assert.memory", start=0x060c, end=0x0613,
             equals_hex="0e 0f 12 14 08 20 23 36")
        step("text_chain", "assert.memory", start=0x0634, end=0x063e,
             equals_hex="0e 0f 12 14 08 20 23 36 20 18 0c")
        keys("text_select_formula", *([17] * 9))
        step("text_demo_gallery", "screen.capture", label="dispatch-board")
        keys("text_edit_input", *([145] * 6 + [29, 13, 20, "7", 13]))
        step("text_chain_updated", "assert.memory", start=0x063b, end=0x063b, equals_hex="37")
        keys("text_save_open", 135)
        wait("text_save_prompt", "AVE WORKBOOK")
        keys("text_save_copy", "ORDERS-COPY", 13)
        wait("text_saved", "WORKBOOK SAVED")
        if hosted:
            keys("text_switch_to_editor", 137)
            wait("text_editor_active", "EDITOR", 60)
            keys("text_switch_back", 138)
            wait("text_sheet_resumed", "ARROWS MOVE", 60)
            step("text_chain_resumed", "assert.memory", start=0x063b, end=0x063b, equals_hex="37")
        keys("text_reload_open", 136)
        wait("text_reload_prompt", "OAD WORKBOOK")
        keys("text_reload_copy", "ORDERS-COPY", 13)
        wait("text_reloaded", "WORKBOOK LOADED")
        step("text_chain_restored", "assert.memory", start=0x063b, end=0x063b, equals_hex="37")
    if hosted:
        keys("return_to_launcher", 2)
        wait("launcher", "READY OS", 60)
    path.write_text("\n".join(lines) + "\n")


def build(output: Path, targets: str, manifest_path: Path, test_fixtures: bool = False) -> None:
    output.mkdir(parents=True, exist_ok=True)
    compiler = os.environ.get("ZEROPAGE_COMPILER")
    if not compiler:
        local = ROOT / "zig-out/bin/zp64c"
        compiler = str(local) if local.is_file() else resolve_tool("ZEROPAGE_COMPILER", "bin/zp64c", "zp64c")
    c1541 = resolve_tool("ZEROPAGE_C1541", "bin/c1541", "c1541")

    def compile_source(source: str, name: str) -> Path:
        path = output / (name + ".prg")
        command(compiler, "compile", SOURCE / (source + ".zp64"), "-o", path)
        return path

    file = compile_source("file_overlay", "zsfile")
    help_code = compile_source("help_overlay", "zshelp")
    edit = compile_source("edit_overlay", "zsedit")
    help_data = output / "zspages.seq"
    help_data.write_bytes(generate())
    for overlay in (file, help_code, edit):
        data = overlay.read_bytes()
        if data[:2] != b"\x00\xa0" or len(data) > 0x1F02:
            raise ValueError(f"invalid overlay window: {overlay}")
        overlay.write_bytes(data.ljust(0x1F02, b"\0"))
    demo = output / "chain.seq"
    demo.write_bytes(chain_workbook())
    assets = [file_entry(file), file_entry(help_code), file_entry(edit), file_entry(help_data, "zspages", "seq"),
              file_entry(demo, "chain", "seq")]

    examples = []
    for source in sorted(SAMPLES.glob("*.tsv")):
        path = output / (source.stem + ".seq")
        path.write_bytes(from_text(source))
        examples.append(file_entry(path, source.stem, "seq"))
    make_disk(c1541, output / "sheet-examples.d81", [assets[-1], *examples])
    fixtures = []
    if test_fixtures:
        valid = workbook({"A1": "7"})
        simplecells = bytearray.fromhex("d3 c3 cc d3 31 02 12 0a 02 02 00")
        for col in IMPORT_WIDTHS:
            simplecells.extend((IMPORT_WIDTHS[col], IMPORT_FORMATS.get(col, 0)))
        for address, content in IMPORT_CELLS.items():
            col, row = address
            source = content.encode("ascii")
            simplecells.extend((int(row) - 1, ord(col) - ord("A"), int(content.startswith("=")),
                                IMPORT_COLORS.get(address, 0), len(source)))
            simplecells.extend(source)
        simplecells.append(255)
        invalid_view = bytearray(workbook({"A1": "9"}, view=(0, 0, 0, 0, 6)))
        invalid_view[23] = 79
        data = {
            "empty": workbook({}),
            "legacy": workbook({"A1": "7", "D1": "=A1*3"}, legacy=True),
            "truncated": valid[:-1],
            "duplicate": valid[:-2] + valid[5:9] + valid[-2:],
            "trailing": valid + b"\x00",
            "bad-cell": valid[:5] + b"\x00\x06" + valid[7:],
            "bad-view": invalid_view,
            "bad-color": workbook({"A1": "9"}, colors={"A1": 2})[:-3] + b"\x10\xff\xff",
            "replace-test": valid,
            "simplecells": simplecells,
            "scls-truncated": simplecells[:-3],
        }
        for name, content in data.items():
            path = output / (name + ".seq")
            path.write_bytes(content)
            fixtures.append(file_entry(path, name, "seq"))

    if targets in {"both", "standalone"}:
        app = compile_source("standalone", "standalone")
        disk = output / "zeropage-sheet.d64"
        make_disk(c1541, disk, [file_entry(app, "zsheet"), *assets, *examples, *fixtures])
        plan(output / "standalone.vice.yaml", disk, hosted=False, test_fixtures=test_fixtures)

    if targets in {"both", "readyos"}:
        app = compile_source("readyos", "zsheet")
        meta = json.loads(manifest_path.read_text())
        if meta.get("version_text") != "0.5" or meta.get("id") != "precog-d81":
            raise ValueError("choose the ReadyOS Precog 0.5 D81 release manifest")
        # Official manifest paths are relative to the ReadyOS source root.
        base = manifest_path.parents[3]
        disk_in = base / meta["disks"][0]["path"]
        disk = output / "readyos-zeropage-sheet.d81"
        preboot = output / "readyos-preboot.prg"
        shutil.copyfile(base / meta["autostart_prg"], preboot)
        with tempfile.TemporaryDirectory(prefix="zeropage-sheet-") as name:
            stage = Path(name)
            # Use a focused derivative: keeping every ReadyOS demo left no
            # room for a workbook. Preserve boot order and Editor resources.
            keep = {"preboot", "showcfg", "boot", "launcher", "apps.cfg", "editor", "editor help"}
            entries = [entry for entry in disk_entries(c1541, disk_in)
                       if str(entry["name"]).lower() in keep]
            for index, entry in enumerate(entries):
                path = stage / f"{index:03d}.{entry['type']}"
                extract(c1541, disk_in, entry, path)
                entry["host"] = path
                if entry["name"].lower() == "apps.cfg":
                    path.write_bytes(catalog(path.read_bytes()))
            make_disk(c1541, disk, ordered([*entries, file_entry(app), *assets, *examples, *fixtures]))
        verify_order(disk_entries(c1541, disk))
        plan(output / "readyos.vice.yaml", disk, hosted=True, test_fixtures=test_fixtures)


def verify_saved_workbook(disk: Path) -> None:
    c1541 = resolve_tool("ZEROPAGE_C1541", "bin/c1541", "c1541")
    expected = {
        "proof": workbook({"A1": "7", "B1": "=A1*3", "C1": "=B1+8", "D1": "=SUM(A1:C1)"},
                          view=(0, 3, 0, 0, 6)),
        "chain-copy": workbook({}, view=(0, 0, 0, 0, 6))[:-2] + chain_workbook()[5:],
        "scrolled": workbook({}, view=(20, 15, 3, 12, 9))[:-2] + chain_workbook()[5:],
        "replace-test": workbook({"A1": "9"}, view=(0, 0, 0, 0, 6)),
        "color-copy": workbook({"A1": "9", "B1": "9"}, colors={"A1": 2, "B1": 2}, view=(0, 2, 0, 0, 6)),
        "import-copy": workbook(IMPORT_CELLS, widths=IMPORT_WIDTHS, formats=IMPORT_FORMATS,
                                colors=IMPORT_COLORS, view=IMPORT_VIEW),
        "rates-copy": workbook({}, formats={"B": 4}, view=(0, 1, 0, 0, 6))[:-2]
                      + from_text(SAMPLES / "rates.tsv")[5:],
    }
    if disk.suffix == ".d81":
        expected["resume-proof"] = workbook({"A1": "11", "B1": "=A1*4", "C1": "=B1+8", "D1": "=SUM(A1:C1)"},
                                            view=(0, 3, 0, 0, 6))
    market = from_text(SAMPLES / "market.tsv")
    expected["market-copy"] = b"ZPSH\x06" + market[5:21] + bytes((14, 3, 0, 0, 9)) + market[21:]
    orders = from_text(SAMPLES / "orders.tsv").replace(b"\x31\x00\x01\x36", b"\x31\x00\x01\x37", 1)
    expected["orders-copy"] = orders[:21] + bytes((3, 1, 0, 0, 6)) + orders[26:]
    with tempfile.TemporaryDirectory(prefix="sheet-save-") as directory:
        for name, stream in expected.items():
            output = Path(directory) / (name + ".seq")
            extract(c1541, disk, {"name": name, "type": "seq"}, output)
            if output.read_bytes() != stream:
                raise ValueError(f"{disk.name}: {name} differs from the expected workbook stream")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=("both", "standalone", "readyos"), default="both")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/spreadsheet")
    parser.add_argument("--readyos-manifest", type=Path, default=READYOS_MANIFEST)
    parser.add_argument("--test-fixtures", action="store_true", help="add files for compatibility and rejection tests")
    parser.add_argument("--verify-save", type=Path, help="verify workbooks written by a VICE plan")
    args = parser.parse_args()
    if args.verify_save:
        verify_saved_workbook(args.verify_save)
        return
    build(args.output_dir.resolve(), args.target, args.readyos_manifest.resolve(), args.test_fixtures)


if __name__ == "__main__":
    main()
