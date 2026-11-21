"""Build the path-discovery hotfix on the verified v2.2.4 package inventory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
from zipfile import ZIP_DEFLATED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
VERSION = "2.2.5"
NAME = f"ZhaoHuoPortraitManager-v{VERSION}-win-x64"
BASE = "verification/history-v2.2.4/ReleaseManifest.json"
BASE_SHA256 = "94EB067026E6DA5E74FDD9EBEBD00C51C52921C526CB63E9CE18B59BEE720F53"
STEAM_TEST = "tests/Test-SteamDiscovery.ps1"
STEAM_REPORT = "verification/steam-discovery-tests.json"
UPDATE_REPORT = "verification/package-updater-tests-v2.2.5.json"
MODULE = "installer/ZhaoHuoInstaller.psm1"
VERSION_FILES = ("VariantCatalog.json", "installer/CharacterCatalog.ps1", "scripts/CharacterReleaseRules.ps1")
CHANGED = {
    "CHANGELOG.md", "README.md", "docs/release-notes-v2.2.4.md",
    "docs/形象管理器安装指南.md", "docs/角色管理器常见问题.md", "verification/README.md",
    "scripts/Build-Release.ps1", MODULE, *VERSION_FILES,
}
ADDED = {
    BASE, STEAM_REPORT, STEAM_TEST, UPDATE_REPORT, "docs/小包更新.md",
    "docs/release-notes-v2.2.5.md", "scripts/build-manager-hotfix.py",
    "scripts/Build-SmallUpdate.ps1", "updates/Update-Manager.ps1", "updates/双击更新管理器.cmd",
    "updates/先看这里.txt", "updates/tests/Test-UpdateManager.ps1", "verification/package-updater-tests.json",
    "verification/package-updater-real-packages.json", "verification/small-update-v2.2.4.json",
}


def digest(data):
    return hashlib.sha256(data).hexdigest().upper()


def source_bytes(name):
    path = ROOT / name
    if not path.resolve().is_relative_to(ROOT) or path.is_symlink():
        raise ValueError(f"Unexpected source path: {name}")
    return path.read_bytes()


def checked_report(name, required, count_field):
    report = json.loads(source_bytes(name))
    if report["Passed"] is not True or report[count_field] < 1:
        raise ValueError(f"Regression checks did not pass: {name}")
    if report["CodeHashAlgorithm"] != "SHA256-UTF8-noBOM-LF-v1":
        raise ValueError(f"Unknown code-hash format: {name}")
    entries = report["CodeHashes"]
    hashes = entries if isinstance(entries, dict) else {row["Path"]: row["Sha256"] for row in entries}
    if not required.issubset(hashes):
        raise ValueError(f"Regression report is missing tested files: {name}")
    for file, expected in hashes.items():
        source = source_bytes(file).decode("utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")
        if digest(source.encode()) != expected.upper():
            raise ValueError(f"Code changed after testing: {file}")
    return {"Path": name, "SHA256": digest(source_bytes(name)), count_field: report[count_field]}


def frozen_bytes(name, data, expected):
    if digest(data) == expected:
        return data
    # Git checkouts on different platforms can apply different text endings.
    if Path(name).suffix.lower() in {".ps1", ".psm1", ".cmd", ".md", ".py", ".json", ".cs", ".txt", ".tsv"}:
        lf = data.replace(b"\r\n", b"\n")
        for candidate in (lf, lf.replace(b"\n", b"\r\n")):
            if digest(candidate) == expected:
                return candidate
    raise ValueError(f"File differs from the verified v2.2.4 release: {name}")


def build(output, check_only):
    baseline_bytes = source_bytes(BASE)
    if digest(baseline_bytes) != BASE_SHA256:
        raise ValueError("The pinned v2.2.4 release inventory changed.")
    baseline = json.loads(baseline_bytes)
    original = {row["Path"]: row["SHA256"] for row in baseline["Files"]}
    if baseline["Version"] != "2.2.4" or ADDED.intersection(original) or not CHANGED.issubset(original):
        raise ValueError("The baseline and the hotfix file list disagree.")
    for name in VERSION_FILES:
        data = source_bytes(name)
        if data.count(b"2.2.5") != 1:
            raise ValueError(f"Unexpected version metadata: {name}")
        frozen_bytes(name, data.replace(b"2.2.5", b"2.2.4"), original[name])
    steam = checked_report(STEAM_REPORT, {MODULE, STEAM_TEST}, "TestsPassed")
    updater = checked_report(UPDATE_REPORT, {"updates/Update-Manager.ps1", "updates/tests/Test-UpdateManager.ps1", "updates/双击更新管理器.cmd"}, "AssertionCount")
    if digest(source_bytes(MODULE)) == original[MODULE] or updater["AssertionCount"] < 48:
        raise ValueError("Missing installer change or incomplete updater regression coverage.")
    paths = sorted(set(original) | ADDED)
    archive = output / (NAME + ".zip")
    if not check_only:
        output.mkdir(parents=True, exist_ok=True)
        if archive.exists() or Path(str(archive) + ".sha256").exists():
            raise FileExistsError(archive)
    with tempfile.TemporaryDirectory(dir=output if not check_only else None) as tmp:
        tmpzip = Path(tmp) / "release.zip"
        from contextlib import nullcontext
        with (nullcontext() if check_only else ZipFile(tmpzip, "x", ZIP_DEFLATED, compresslevel=6)) as zipped:
            def write(name, data):
                if zipped is not None:
                    zipped.writestr(f"{NAME}/{name}", data)

            entries = []
            for name in paths:
                data = source_bytes(name)
                if name in original and name not in CHANGED:
                    data = frozen_bytes(name, data, original[name])
                entries.append({"Path": name, "SHA256": digest(data), "Bytes": len(data)})
                write(name, data)
            manifest = {key: baseline[key] for key in (
                "Package", "RuntimeVersion", "Platform", "SteamAppId", "DefaultCharacterId",
                "CatalogSchemaVersion", "InstallationSchemaVersion", "Characters", "Variants",
                "PortraitCount", "SharedPluginFiles", "KnownGameFingerprintGroups", "CompatibilityCheck",
            )}
            manifest.update({
                "Version": VERSION, "Catalog": {"Path": "VariantCatalog.json", "SHA256": digest(source_bytes("VariantCatalog.json"))},
                "ManagerHotfixValidation": {"SteamDiscovery": steam, "OfflineUpdater": updater},
                "HistoricalValidation": {"Version": "2.2.4", "Manifest": BASE, "SHA256": BASE_SHA256,
                                         "Scope": "Unchanged portrait art, layouts, runtime plugin and compatibility baselines. Prior gameplay evidence was collected on v2.2.4."},
                "Files": entries,
            })
            manifest_bytes = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode()
            write("ReleaseManifest.json", manifest_bytes)
            sums = {row["Path"]: row["SHA256"] for row in entries}
            sums["ReleaseManifest.json"] = digest(manifest_bytes)
            write("SHA256SUMS.txt", "".join(f"{sums[n]}  {n}\n" for n in sorted(sums)).encode())
        if not check_only:
            with tmpzip.open("rb") as stream:
                checksum = hashlib.file_digest(stream, "sha256").hexdigest().upper()
            # Windows rename refuses to overwrite a target produced by another build.
            os.rename(tmpzip, archive)
            with Path(str(archive) + ".sha256").open("x", encoding="ascii") as stream:
                stream.write(f"{checksum}  {archive.name}\n")
    return {"Status": "passed", "Version": VERSION, "Files": len(paths),
            "Characters": manifest["Characters"], "CustomVariants": len(manifest["Variants"]),
            "PortraitCount": manifest["PortraitCount"], "ManifestSHA256": digest(manifest_bytes),
            "NoOutputWritten": check_only, "Archive": None if check_only else str(archive)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    print(json.dumps(build(args.output, args.check_only)))
