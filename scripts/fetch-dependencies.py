#!/usr/bin/env python3
"""Fetch pinned, verified upstream artifacts without executing downloaded code."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache"
LOCK = ROOT / "scripts/dependencies.lock.json"


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def fetch(item):
    folder = CACHE / "downloads"
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / item["filename"]
    if target.exists() and digest(target) == item["sha256"]:
        return target
    request = urllib.request.Request(item["url"], headers={"User-Agent": "AndroidOnMac-build/0.1.0"})
    with tempfile.NamedTemporaryFile(dir=folder, delete=False) as temporary:
        temporary_path = Path(temporary.name)
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                shutil.copyfileobj(response, temporary)
            temporary.flush()
            if digest(temporary_path) != item["sha256"]:
                raise RuntimeError(f"SHA-256 mismatch: {item['id']}")
            temporary_path.replace(target)
        finally:
            temporary_path.unlink(missing_ok=True)
    print(f"Verified {item['filename']}")
    return target


def extract_engine(item):
    archive = fetch(item)
    folder = CACHE / "engine"
    folder.mkdir(parents=True, exist_ok=True)
    expected = {"scrcpy", "adb", "scrcpy-server", "scrcpy.png", "disconnected.png", "scrcpy.1", "LICENSE"}
    found = set()
    with tarfile.open(archive, "r:gz") as source:
        for member in source.getmembers():
            name = Path(member.name).name
            if name not in expected or not member.isfile():
                continue
            content = source.extractfile(member).read()
            target = folder / name
            if not target.exists() or target.read_bytes() != content:
                # Atomic replacement also avoids truncating an adb executable
                # while an already running server still owns the old inode.
                with tempfile.NamedTemporaryFile(dir=folder, delete=False) as temporary:
                    temporary.write(content)
                    temporary_path = Path(temporary.name)
                temporary_path.chmod(0o755 if name in {"adb", "scrcpy"} else 0o644)
                temporary_path.replace(target)
            target.chmod(0o755 if name in {"adb", "scrcpy"} else 0o644)
            found.add(name)
    if found != expected:
        raise RuntimeError(f"Incomplete engine archive: {sorted(expected - found)}")
    (folder / "version.json").write_text(json.dumps({"version": item["version"], "sha256": item["sha256"]}, indent=2) + "\n")
    print(f"Engine ready: {folder}")


def extract_notices(item, archive, destination):
    destination.mkdir(parents=True, exist_ok=True)
    names = {"copying", "copying.lgplv2.1", "copying.lgplv3", "copying.gplv2", "copying.gplv3", "license", "license.txt", "copyright", "notice", "notice.txt", "copying.txt", "patents", "license.md"}
    count = 0
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as source:
            if item["id"] == "adb":
                # Verify the exact Google binary and its complete notice. This
                # establishes origin, not a corresponding-source/relink claim.
                for member, field in (("platform-tools/adb", "binarySha256"),
                                      ("platform-tools/NOTICE.txt", "noticeSha256")):
                    if hashlib.sha256(source.read(member)).hexdigest() != item[field]:
                        raise RuntimeError(f"Unexpected official ADB material: {member}")
            members = [(name, source.read(name)) for name in source.namelist()
                       if Path(name).name.lower() in names and not name.endswith("/")]
    else:
        with tarfile.open(archive) as source:
            members = [(member.name, source.extractfile(member).read()) for member in source.getmembers()
                       if member.isfile() and Path(member.name).name.lower() in names]
    for name, content in members:
        # Preserve nested license names while preventing archive path traversal.
        safe_name = "__".join(part for part in Path(name).parts if part not in {"..", "/", "."})
        (destination / safe_name).write_bytes(content)
        count += 1
    if not count:
        raise RuntimeError(f"No upstream licenses found: {item['id']}")


def prepare_compliance(manifest):
    folder = CACHE / "compliance"
    sources = folder / "sources"
    sources.mkdir(parents=True, exist_ok=True)
    for item in manifest["artifacts"]:
        if item["id"] == "engine":
            continue
        archive = fetch(item)
        extract_notices(item, archive, folder / "licenses" / item["id"])
        if item["id"] == "adb":
            engine_adb = CACHE / "engine" / "adb"
            if engine_adb.exists() and digest(engine_adb) != item["binarySha256"]:
                raise RuntimeError("Cached engine ADB differs from the pinned Google binary")
        if item["source"]:
            shutil.copy2(archive, sources / item["filename"])
    shutil.copy2(LOCK, folder / "dependencies.lock.json")
    shutil.copy2(ROOT / "scripts/rebuild-engine.sh", folder / "rebuild-engine.sh")
    shutil.copy2(ROOT / "docs/THIRD_PARTY_SOURCES.md", folder / "README.md")
    shutil.copy2(ROOT / "docs/REBUILD_MATERIALS_LICENSE.txt", folder / "REBUILD_MATERIALS_LICENSE.txt")
    notices = (ROOT / "THIRD_PARTY_NOTICES.md").read_text()
    (folder / "THIRD_PARTY_NOTICES.md").write_text(notices.replace("(docs/THIRD_PARTY_SOURCES.md)", "(README.md)"))
    with (folder / "SHA256SUMS.txt").open("w") as output:
        for path in sorted(sources.iterdir()):
            output.write(f"{digest(path)}  sources/{path.name}\n")
    print(f"scrcpy source and license bundle ready: {folder}")
    print("ADB: official binary and complete NOTICE verified; exact source/build mapping remains unverified.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", action="store_true")
    parser.add_argument("--compliance", action="store_true")
    args = parser.parse_args()
    manifest = json.loads(LOCK.read_text())
    if args.engine or not args.compliance:
        extract_engine(next(item for item in manifest["artifacts"] if item["id"] == "engine"))
    if args.compliance:
        prepare_compliance(manifest)


if __name__ == "__main__":
    main()
