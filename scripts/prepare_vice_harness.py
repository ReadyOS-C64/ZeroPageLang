#!/usr/bin/env python3
"""Prepare the same isolated macOS VICE bridge used by sibling compiler projects.

The external harness and installed tools are never modified. Dependency source
is pinned, checksum-verified, and retains its license under ignored build/.
"""

import argparse
import hashlib
from pathlib import Path
import shutil
import tarfile
import urllib.request
from xml.sax.saxutils import escape


REVISION = "b75ed9940ff2c3e3da795aeea190ae4a9ad51e87"
SHA256 = "f148be9d384d6b8850cce788f081e216f532619a90a93af901f09aedc5269330"


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"unexpected harness/bridge source: expected one {old!r}")
    return text.replace(old, new)


def patch_bridge(text):
    text = replace_once(
        text, "await WaitForPort(port, ct).ConfigureAwait(false);",
        "// Connect directly: macOS may report an empty TCP listener table.",
    )
    marker = '_logger.LogError(ex, "Unknown exception occurred");'
    return replace_once(text, marker, marker + "\n                        await Task.Delay(100, ct).ConfigureAwait(false);")


def prepare(root, source):
    source = Path(source).resolve()
    if not source.is_file():
        raise FileNotFoundError(f"VICE harness project not found: {source}")
    build = Path(root).resolve() / "build"
    build.mkdir(parents=True, exist_ok=True)
    archive = build / "vice-bridge.tar.gz"
    if not archive.exists():
        url = f"https://codeload.github.com/MihaMarkic/vice-bridge-net/tar.gz/{REVISION}"
        with urllib.request.urlopen(url, timeout=30) as response:
            archive.write_bytes(response.read())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise ValueError("VICE bridge archive checksum mismatch")
    # Restore pinned pristine source before patching, so reruns are deterministic.
    with tarfile.open(archive) as tar:
        tar.extractall(build, filter="data")
    bridge = build / f"vice-bridge-net-{REVISION}" / "source/ViceMonitor.Bridge/Righthand.ViceMonitor.Bridge"
    code = bridge / "Services/Implementation/ViceBridge.cs"
    code.write_text(patch_bridge(code.read_text(encoding="utf-8-sig")))
    target = build / "vice-harness"
    for name in ("ViceTasks.Binary", "ViceTasks.Ultimate"):
        shutil.copytree(source.parent.parent / name, target / name,
                        ignore=shutil.ignore_patterns("bin", "obj"), dirs_exist_ok=True)
    copied = target / "ViceTasks.Binary" / source.name
    project = copied.read_text(encoding="utf-8-sig")
    project = replace_once(
        project, '<PackageReference Include="Righthand.Vice.Bridge" Version="1.0.4" />',
        f'<ProjectReference Include="{escape(str(bridge / "Righthand.ViceMonitor.Bridge.csproj"))}" />',
    )
    copied.write_text(project)
    return copied


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=root.parent / "agenticdevharness/tools/vice_tasks_dotnet/src/ViceTasks.Binary/ViceTasks.Binary.csproj")
    args = parser.parse_args()
    print(prepare(root, args.source))


if __name__ == "__main__":
    main()
