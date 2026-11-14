#!/usr/bin/env python3
"""Build a derived ReadyOS precog-d81 image containing ZeroPage Tic-Tac-Toe."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
READYOS = ROOT.parent / "readyosprecog"
LIST_RE = re.compile(r'^\s*\d+\s+"([^"]+)"\s+([A-Za-z]+)')
BOOT_NAMES = ("preboot", "showcfg", "boot", "launcher")
OVERLAY_NAMES = {
    "rsparser", "rsvm", "rsdrvilst", "rsldv", "rsstv", "rsfops",
    "rscat", "rscopy", "rsedit",
}
READYBASIC_RE = re.compile(r"^(rbtest|rbproc|rbgfx|rbsnd)")
GROUP_INDEX = {
    "boot": 0,
    "config": 1,
    "seq_usr": 2,
    "program": 3,
    "overlay": 4,
    "rel": 5,
    "readybasic_example": 6,
}


def run(argv: list[str], *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
        stderr=subprocess.PIPE if capture else subprocess.DEVNULL,
    )


def resolve_tool(env_name: str, sibling_name: str, executable: str) -> str:
    override = os.environ.get(env_name)
    if override:
        return override
    sibling = ROOT.parent / "zeropage-tooling" / sibling_name
    if sibling.is_file():
        return str(sibling)
    found = shutil.which(executable)
    if found:
        return found
    raise SystemExit(f"missing {executable}; set {env_name}")


def latest_regular_manifest() -> tuple[Path, dict[str, object]]:
    candidates = list((READYOS / "Releases").glob("*/precog-d81/manifest.json"))
    candidates = [path for path in candidates if path.is_file()]
    if not candidates:
        raise SystemExit(f"no regular precog-d81 release under {READYOS / 'Releases'}")
    path = max(candidates, key=lambda item: item.stat().st_mtime_ns)
    return path, json.loads(path.read_text(encoding="utf-8"))


def patch_catalog(data: bytes) -> bytes:
    run_first = b"RUNAPPFIRST="
    if run_first not in data:
        raise ValueError("ReadyOS catalog has no RUNAPPFIRST setting")
    data = data.replace(run_first + b"\r", run_first + b"TICTACTOE\r", 1)
    data = data.replace(b"LOAD_ALL_TO_REU=0", b"LOAD_ALL_TO_REU=1", 1)
    marker = b"[APPS]\r"
    if marker not in data:
        raise ValueError("ReadyOS catalog has no APPS section")
    system = data.split(marker, 1)[0] + marker
    # The VICE proof catalog is intentionally focused: two cached apps are
    # enough to prove both switch directions and snapshot restoration without
    # turning a Tic-Tac-Toe test into a preload of every ReadyOS dependency.
    return system + (
        b"8:EDITOR:EDITOR:1\rTEXT EDITOR WITH CLIPBOARD\r"
        b"8:TICTACTOE:TIC TAC TOE\rZEROPAGE READYOS TUI GAME\r"
    )


def group_for(name: str, file_type: str) -> str:
    lower = name.lower()
    if lower in BOOT_NAMES:
        return "boot"
    if lower == "apps.cfg" or lower.startswith("app."):
        return "config"
    if READYBASIC_RE.match(lower):
        return "readybasic_example"
    if lower in OVERLAY_NAMES or lower.startswith("rbm."):
        return "overlay"
    if file_type == "rel":
        return "rel"
    if file_type in {"seq", "usr"}:
        return "seq_usr"
    if file_type == "prg":
        return "program"
    raise ValueError(f"unsupported disk entry {name} ({file_type})")


def ordered(entries: list[dict[str, object]]) -> list[dict[str, object]]:
    def key(indexed: tuple[int, dict[str, object]]) -> tuple[int, int, int]:
        index, entry = indexed
        name = str(entry["name"]).lower()
        group = group_for(name, str(entry["type"]))
        within = BOOT_NAMES.index(name) if group == "boot" else index
        if group == "config" and name == "apps.cfg":
            within = 0
        return GROUP_INDEX[group], within, index

    return [entry for _, entry in sorted(enumerate(entries), key=key)]


def disk_entries(c1541: str, disk: Path) -> list[dict[str, object]]:
    listing = run([c1541, str(disk), "-list"], capture=True).stdout
    result: list[dict[str, object]] = []
    for line in listing.splitlines():
        match = LIST_RE.match(line)
        if not match:
            continue
        file_type = match.group(2).lower()
        if file_type in {"prg", "seq", "usr", "rel"}:
            result.append({"name": match.group(1).strip(), "type": file_type})
    return result


def extract(c1541: str, disk: Path, entry: dict[str, object], target: Path) -> None:
    codes = {"prg": "p", "seq": "s", "usr": "u", "rel": "l"}
    spec = f"{entry['name']},{codes[str(entry['type'])]}"
    proc = run([c1541, str(disk), "-read", spec, str(target)], capture=True)
    if str(entry["type"]) == "rel":
        text = proc.stdout + proc.stderr
        match = re.search(r"record length (\d+)", text, re.IGNORECASE)
        if not match:
            raise RuntimeError(f"could not determine REL record length for {entry['name']}")
        entry["record_length"] = int(match.group(1))


def write_entry(c1541: str, disk: Path, entry: dict[str, object]) -> None:
    file_type = str(entry["type"])
    name = str(entry["name"])
    if file_type == "prg":
        spec = name
    elif file_type == "seq":
        spec = f"{name},s"
    elif file_type == "usr":
        spec = f"{name},u"
    else:
        spec = f"{name},l,{entry['record_length']}"
    run([c1541, str(disk), "-write", str(entry["host"]), spec])


def verify_order(entries: list[dict[str, object]]) -> None:
    previous = -1
    for entry in entries:
        current = GROUP_INDEX[group_for(str(entry["name"]), str(entry["type"]))]
        if current < previous:
            raise RuntimeError(f"ReadyOS directory ordering failure at {entry['name']}")
        previous = current
    boot = [str(entry["name"]).lower() for entry in entries if group_for(str(entry["name"]), str(entry["type"])) == "boot"]
    if boot != list(BOOT_NAMES):
        raise RuntimeError(f"unexpected ReadyOS boot order: {boot}")


def write_plan(path: Path, disk: Path, preboot: Path) -> None:
    text = f'''version: 1
kind: vice_task_plan
plan_id: zeropage_readyos_tictactoe
run_mode: gui_vice
global_defaults:
  monitor_host: 127.0.0.1
  monitor_port_start: 6502
  monitor_port_span: 40
  retry_policy: {{ max_attempts: 4, backoff_ms: 500, jitter: false }}
  timeouts: {{ launch_s: 45, step_s: 300, read_s: 2 }}
  artifact_policy: {{ capture_screen: true, capture_state: true, capture_dump: false }}
  vice:
    disk8: "{disk}"
    disk9: "{disk}"
    autostart_prg: "{preboot}"
    drive8_type: 1581
    drive9_type: 1581
    true_drive: false
    close_vice: true
    headless: true
    speed_percent: 200
steps:
  - id: launch_readyos_preboot
    type: vice.launch
    params: {{ kill_stale: true }}
  - id: resume_readyos_boot
    type: monitor.command
    params: {{ command: "warp on" }}
  - id: wait_tictactoe_autostart
    type: screen.wait_contains
    params: {{ text: "MODE:2 PLAYER", wait_timeout_s: 300 }}
  - id: wait_initial_frame_complete
    type: screen.wait_contains
    params: {{ text: "F1:2 PLAYER  F3:1 PLAYER  F8:HELP", wait_timeout_s: 20, capture_label: tictactoe_readyos_initial }}
  - id: assert_clean_playing_state
    type: assert.screen_not_contains
    params: {{ not_contains: "NO WINNING LINES" }}
  - id: assert_main_omits_common_navigation
    type: assert.screen_not_contains
    params: {{ not_contains: "F2:NEXT APP" }}
  - id: move_cursor_without_full_redraw
    type: input.sequence
    params: {{ keys: [29], inter_key_delay_s: 0.05, post_delay_s: 0.3 }}
  - id: capture_cursor_moved
    type: screen.capture
    params: {{ label: tictactoe_readyos_cursor_moved, note: "White selection moved one cell using the incremental two-cell redraw path" }}
  - id: return_cursor_for_gameplay
    type: input.sequence
    params: {{ keys: [157], inter_key_delay_s: 0.05, post_delay_s: 0.3 }}
  - id: open_help_modal
    type: input.sequence
    params: {{ keys: [140], inter_key_delay_s: 0.05, post_delay_s: 0.4 }}
  - id: assert_help_modal
    type: assert.screen
    params: {{ contains: "TIC TAC TOE HELP" }}
  - id: assert_help_readyos_keys
    type: assert.screen
    params: {{ contains: "F2            NEXT APP" }}
  - id: capture_help_modal
    type: screen.capture
    params: {{ label: tictactoe_readyos_help, note: "ReadyOS-style F8 help modal" }}
  - id: close_help_modal
    type: input.sequence
    params: {{ keys: [140], inter_key_delay_s: 0.05, post_delay_s: 0.4 }}
  - id: wait_main_after_help
    type: screen.wait_contains
    params: {{ text: "F1:2 PLAYER  F3:1 PLAYER  F8:HELP", wait_timeout_s: 20 }}
  - id: switch_to_ai_mode
    type: input.sequence
    params: {{ keys: [134], inter_key_delay_s: 0.05, post_delay_s: 0.3 }}
  - id: assert_ai_subheader
    type: assert.screen
    params: {{ contains: "MODE:1 PLAYER  HUMAN:X  CPU:O" }}
  - id: wait_ai_frame_complete
    type: screen.wait_contains
    params: {{ text: "SELECT A SQUARE AND PLACE YOUR MARK", wait_timeout_s: 20, capture_label: tictactoe_readyos_ai_mode }}
  - id: reset_two_player_mode
    type: input.sequence
    params: {{ keys: [133], inter_key_delay_s: 0.05, post_delay_s: 0.3 }}
  - id: assert_two_player_subheader
    type: assert.screen
    params: {{ contains: "MODE:2 PLAYER  PLAYERS:X/O" }}
  - id: play_to_midgame_fast
    type: input.sequence
    params: {{ keys: [32,29,32,17,32], inter_key_delay_s: 0.05, post_delay_s: 0.5 }}
  - id: assert_midgame_turn
    type: assert.screen
    params: {{ contains: "TURN:O" }}
  - id: capture_midgame
    type: screen.capture
    params: {{ label: tictactoe_readyos_midgame, note: "ZeroPage Tic-Tac-Toe inside ReadyOS after three moves at 200% VICE speed" }}
  - id: finish_x_diagonal_win
    type: input.sequence
    params: {{ keys: [32,29,32,17,32,29,32,17,32], inter_key_delay_s: 0.05, post_delay_s: 0.5 }}
  - id: wait_x_win
    type: screen.wait_contains
    params: {{ text: "X WINS", wait_timeout_s: 20, capture_label: tictactoe_readyos_x_win }}
  - id: assert_game_over_modal
    type: assert.screen
    params: {{ contains: "START A NEW GAME" }}
  - id: assert_game_over_f1
    type: assert.screen
    params: {{ contains: "F1  TWO PLAYER" }}
  - id: assert_game_over_f3
    type: assert.screen
    params: {{ contains: "F3  ONE PLAYER / AI" }}
  - id: restart_and_test_invalid
    type: input.sequence
    params: {{ keys: [133,32,32], inter_key_delay_s: 0.06, post_delay_s: 0.5 }}
  - id: assert_invalid_move
    type: assert.screen
    params: {{ contains: "THAT SQUARE IS ALREADY TAKEN" }}
  - id: capture_invalid_move
    type: screen.capture
    params: {{ label: tictactoe_readyos_invalid, note: "Invalid occupied-square feedback remains aligned without disturbing the header or board" }}
'''
    path.write_text(text, encoding="utf-8")


def write_switch_plan(path: Path, disk: Path, preboot: Path) -> None:
    text = f'''version: 1
kind: vice_task_plan
plan_id: zeropage_readyos_tictactoe_switch
run_mode: gui_vice
global_defaults:
  monitor_host: 127.0.0.1
  monitor_port_start: 6502
  monitor_port_span: 40
  retry_policy: {{ max_attempts: 4, backoff_ms: 500, jitter: false }}
  timeouts: {{ launch_s: 45, step_s: 300, read_s: 2 }}
  artifact_policy: {{ capture_screen: true, capture_state: true, capture_dump: false }}
  vice:
    disk8: "{disk}"
    disk9: "{disk}"
    autostart_prg: "{preboot}"
    drive8_type: 1581
    drive9_type: 1581
    true_drive: false
    close_vice: true
    headless: true
    speed_percent: 200
steps:
  - id: launch_readyos_preboot
    type: vice.launch
    params: {{ kill_stale: true }}
  - id: resume_readyos_boot
    type: monitor.command
    params: {{ command: "warp on" }}
  - id: wait_tictactoe_autostart
    type: screen.wait_contains
    params: {{ text: "MODE:2 PLAYER", wait_timeout_s: 300 }}
  - id: f2_next_cached_app
    type: input.sequence
    params: {{ keys: [137], inter_key_delay_s: 0.05, post_delay_s: 1.0 }}
  - id: resume_after_f2_reu_dma
    type: monitor.command
    params: {{ command: "warp on" }}
  - id: wait_editor_after_f2
    type: screen.wait_contains
    params: {{ text: "EDITOR:", wait_timeout_s: 90, capture_label: tictactoe_f2_editor }}
  - id: f4_previous_cached_app
    type: input.sequence
    params: {{ keys: [138], inter_key_delay_s: 0.05, post_delay_s: 1.0 }}
  - id: resume_after_f4_reu_dma
    type: monitor.command
    params: {{ command: "warp on" }}
  - id: wait_tictactoe_resume
    type: screen.wait_contains
    params: {{ text: "MODE:2 PLAYER", wait_timeout_s: 90, capture_label: tictactoe_f4_resumed }}
  - id: assert_cached_app_reentered_cleanly
    type: assert.screen
    params: {{ contains: "TURN:X" }}
'''
    path.write_text(text, encoding="utf-8")


def write_ctrl_b_plan(path: Path, disk: Path, preboot: Path) -> None:
    text = f'''version: 1
kind: vice_task_plan
plan_id: zeropage_readyos_tictactoe_ctrl_b
run_mode: gui_vice
global_defaults:
  monitor_host: 127.0.0.1
  monitor_port_start: 6502
  monitor_port_span: 40
  retry_policy: {{ max_attempts: 4, backoff_ms: 500, jitter: false }}
  timeouts: {{ launch_s: 45, step_s: 300, read_s: 2 }}
  artifact_policy: {{ capture_screen: true, capture_state: true, capture_dump: false }}
  vice:
    disk8: "{disk}"
    disk9: "{disk}"
    autostart_prg: "{preboot}"
    drive8_type: 1581
    drive9_type: 1581
    true_drive: false
    close_vice: true
    headless: true
    speed_percent: 200
steps:
  - id: launch_readyos_preboot
    type: vice.launch
    params: {{ kill_stale: true }}
  - id: resume_readyos_boot
    type: monitor.command
    params: {{ command: "warp on" }}
  - id: wait_tictactoe_autostart
    type: screen.wait_contains
    params: {{ text: "MODE:2 PLAYER", wait_timeout_s: 300 }}
  - id: ctrl_b_launcher
    type: input.sequence
    params: {{ keys: [2], inter_key_delay_s: 0.05, post_delay_s: 1.0 }}
  - id: resume_after_ctrl_b_reu_dma
    type: monitor.command
    params: {{ command: "warp on" }}
  - id: wait_launcher_after_ctrl_b
    type: screen.wait_contains
    params: {{ text: "READY OS", wait_timeout_s: 90, capture_label: tictactoe_ctrl_b_launcher }}
'''
    path.write_text(text, encoding="utf-8")


def build(output_dir: Path) -> dict[str, str]:
    c1541 = resolve_tool("ZEROPAGE_C1541", "bin/c1541", "c1541")
    compiler = ROOT / "zig-out/bin/zp64c"
    if not compiler.is_file():
        raise SystemExit("missing zig-out/bin/zp64c; run zig build first")
    source = ROOT / "sampleapps/tictactoe_readyos/tictactoe_readyos.zp64"
    output_dir.mkdir(parents=True, exist_ok=True)
    prg = output_dir / "tictactoe.prg"
    run([str(compiler), "compile", str(source), "-o", str(prg)])

    manifest_path, manifest = latest_regular_manifest()
    base_disk = Path(str((manifest["disks"])[0]["path"]))  # type: ignore[index]
    base_preboot = Path(str(manifest["autostart_prg"]))
    disk = output_dir / "readyos-zeropage-tictactoe.d81"
    preboot = output_dir / "readyos-zeropage-tictactoe-preboot.prg"
    shutil.copy2(base_preboot, preboot)

    with tempfile.TemporaryDirectory(prefix="zp_readyos_ttt_") as temporary:
        stage = Path(temporary)
        entries = disk_entries(c1541, base_disk)
        for index, entry in enumerate(entries):
            host = stage / f"{index:03d}.{entry['type']}"
            extract(c1541, base_disk, entry, host)
            entry["host"] = host
            if str(entry["name"]).lower() == "apps.cfg":
                host.write_bytes(patch_catalog(host.read_bytes()))
        entries.append({"name": "tictactoe", "type": "prg", "host": prg})
        entries = ordered(entries)
        run([c1541, "-format", "readyoszp,ro", "d81", str(disk)])
        for entry in entries:
            write_entry(c1541, disk, entry)

    listed = disk_entries(c1541, disk)
    verify_order(listed)
    if not any(str(entry["name"]).lower() == "tictactoe" for entry in listed):
        raise RuntimeError("packaged disk is missing tictactoe")
    plan = output_dir / "tictactoe_readyos.vice.yaml"
    write_plan(plan, disk.resolve(), preboot.resolve())
    switch_plan = output_dir / "tictactoe_readyos_switch.vice.yaml"
    write_switch_plan(switch_plan, disk.resolve(), preboot.resolve())
    ctrl_b_plan = output_dir / "tictactoe_readyos_ctrl_b.vice.yaml"
    write_ctrl_b_plan(ctrl_b_plan, disk.resolve(), preboot.resolve())
    metadata = {
        "base_manifest": str(manifest_path.resolve()),
        "base_disk": str(base_disk.resolve()),
        "app_prg": str(prg.resolve()),
        "disk": str(disk.resolve()),
        "preboot": str(preboot.resolve()),
        "vice_plan": str(plan.resolve()),
        "vice_switch_plan": str(switch_plan.resolve()),
        "vice_ctrl_b_plan": str(ctrl_b_plan.resolve()),
    }
    (output_dir / "build.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/readyos_tictactoe")
    args = parser.parse_args()
    print(json.dumps(build(args.output_dir.resolve()), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
