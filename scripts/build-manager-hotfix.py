"""Build the current portrait manager against the previous official release inventory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
from contextlib import nullcontext
from zipfile import ZIP_DEFLATED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
VERSION = "2.2.6"
PREVIOUS = "2.2.5"
BUILD = "26844506"
NAME = f"ZhaoHuoPortraitManager-v{VERSION}-win-x64"
BASE = f"verification/history-v{PREVIOUS}/ReleaseManifest.json"
BASE_SHA256 = "C96B52724DAE34577878B3AB4A9113C38D3795F0303215E294FB467868BD4F1F"
STEAM_TEST = "tests/Test-SteamDiscovery.ps1"
STEAM_REPORT = f"verification/steam-discovery-tests-build{BUILD}.json"
UPDATE_REPORT = f"verification/package-updater-tests-v{VERSION}.json"
MODULE = "installer/ZhaoHuoInstaller.psm1"
PROBE = "installer/CompatibilityProbe.ps1"
GAME_BASELINE = f"installer/compatibility-baseline-{BUILD}.json"
PROBE_REPORT = f"verification/compatibility-probe-tests-build{BUILD}.json"
ROUTE_REPORT = f"verification/build{BUILD}-validation-tests.json"
RESOURCE_DIR = f"verification/game-resources-build{BUILD}"
RUNTIME_REPORT = f"verification/runtime-build{BUILD}/compatibility-runtime.json"
RUNTIME_EVIDENCE = {f"verification/runtime-build{BUILD}/{name}.json" for name in (
    "all-on", "all-original", "normal-startup", "preservation",
)}
VERSION_FILES = ("VariantCatalog.json", "installer/CharacterCatalog.ps1")
CHANGED = {
    "CHANGELOG.md", "README.md", "docs/小包更新.md", "docs/形象管理器安装指南.md",
    "docs/角色管理器常见问题.md", "docs/安装与卸载.md", "verification/README.md",
    "scripts/Build-Release.ps1", "scripts/build-manager-hotfix.py", "scripts/CharacterReleaseRules.ps1",
    "scripts/Generate-CompatibilityBaseline.ps1",
    "updates/Update-Manager.ps1", "updates/先看这里.txt", "updates/tests/Test-UpdateManager.ps1",
    "tests/Test-CompatibilityProbe.ps1", MODULE, PROBE, *VERSION_FILES,
}
ADDED = {
    BASE, STEAM_REPORT, UPDATE_REPORT, GAME_BASELINE, PROBE_REPORT, ROUTE_REPORT, RUNTIME_REPORT, *RUNTIME_EVIDENCE,
    f"docs/release-notes-v{VERSION}.md", f"tests/Test-Build{BUILD}Validation.ps1",
    f"{RESOURCE_DIR}/api-surface.json", f"{RESOURCE_DIR}/resource-graph.json", f"{RESOURCE_DIR}/avatar-resources.json",
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
    if name == "LICENSE" or Path(name).suffix.lower() in {".ps1", ".psm1", ".cmd", ".md", ".py", ".json", ".cs", ".txt", ".tsv"}:
        lf = data.replace(b"\r\n", b"\n")
        for candidate in (lf, lf.replace(b"\n", b"\r\n")):
            if digest(candidate) == expected:
                return candidate
    raise ValueError(f"File differs from the verified v{PREVIOUS} release: {name}")


def package_bytes(name, original):
    data = source_bytes(name)
    if name in original and name not in CHANGED:
        return frozen_bytes(name, data, original[name])
    if name in VERSION_FILES:
        old = frozen_bytes(name, data.replace(VERSION.encode(), PREVIOUS.encode()), original[name])
        return old.replace(PREVIOUS.encode(), VERSION.encode())
    if name.startswith("verification/") or name == GAME_BASELINE:
        return data
    lf = data.replace(b"\r\n", b"\n")
    return lf.replace(b"\n", b"\r\n") if Path(name).suffix.lower() in {".ps1", ".psm1", ".cmd"} else lf


def build(output, check_only):
    baseline_bytes = source_bytes(BASE)
    if digest(baseline_bytes) != BASE_SHA256:
        raise ValueError(f"The pinned v{PREVIOUS} release inventory changed.")
    baseline = json.loads(baseline_bytes)
    original = {row["Path"]: row["SHA256"] for row in baseline["Files"]}
    if baseline["Version"] != PREVIOUS or ADDED.intersection(original) or not CHANGED.issubset(original):
        raise ValueError("The baseline and the hotfix file list disagree.")
    for name in VERSION_FILES:
        data = source_bytes(name)
        if data.count(VERSION.encode()) != 1:
            raise ValueError(f"Unexpected version metadata: {name}")
        frozen_bytes(name, data.replace(VERSION.encode(), PREVIOUS.encode()), original[name])
    steam = checked_report(STEAM_REPORT, {MODULE, STEAM_TEST}, "TestsPassed")
    updater = checked_report(UPDATE_REPORT, {"updates/Update-Manager.ps1", "updates/tests/Test-UpdateManager.ps1", "updates/双击更新管理器.cmd"}, "AssertionCount")
    if digest(source_bytes(MODULE)) == original[MODULE] or updater["AssertionCount"] < 53 or steam["TestsPassed"] < 24:
        raise ValueError("Missing installer change or incomplete updater regression coverage.")
    probe = checked_report(PROBE_REPORT, {PROBE, MODULE, GAME_BASELINE, "tests/Test-CompatibilityProbe.ps1"}, "TestCount")
    route = checked_report(ROUTE_REPORT, {MODULE, f"tests/Test-Build{BUILD}Validation.ps1"}, "TestCount")
    captured = json.loads(source_bytes(GAME_BASELINE))
    version = captured["CapturedGameVersion"]
    if (captured["BaselineBuildIds"] != [BUILD] or captured["CapturedFromBuildId"] != BUILD
            or version != "release_1.0.6001.2" or captured["GameMemberReferenceCount"] != 23
            or len(captured["FixedFiles"]) != 395 or len(captured["CoreSurface"]["Methods"]) != 151
            or len(captured["CoreSurface"]["Types"]) != 35):
        raise ValueError("The new baseline does not describe the target build.")
    static_reports = {}
    inspected = {}
    for filename in ("api-surface.json", "resource-graph.json", "avatar-resources.json"):
        path = f"{RESOURCE_DIR}/{filename}"
        record = json.loads(source_bytes(path))
        if record["Passed"] is not True or str(record["SourceBuildId"]) != BUILD:
            raise ValueError(f"The static report did not verify build {BUILD}: {path}")
        inspected[filename] = record
        static_reports[filename] = {"Path": path, "SHA256": digest(source_bytes(path))}
    api = inspected["api-surface.json"]
    graph = inspected["resource-graph.json"]
    avatars = inspected["avatar-resources.json"]
    if (api["SourceGameVersion"] != version or graph["SourceGameVersion"] != version
            or api["GameMemberReferenceCount"] != 23 or api["AllGameReferencesResolve"] is not True
            or api["ManagedAssemblyNamesUnchanged"] is not True):
        raise ValueError("The target build, game references or managed assembly names failed verification.")
    review = api["ReviewedCoreSurfaceDelta"]
    expected = {"Passed": True, "ExistingMethodsUnchanged": 146, "AddedPropertyGetterCount": 4,
                "CompilerGeneratedEmptyLambdaRenamed": True, "OtherTypeLayoutsUnchanged": 34,
                "CurrentMethodCount": 151, "CurrentTypeCount": 35}
    if any(review[key] != value for key, value in expected.items()):
        raise ValueError("The reviewed Core API delta differs from this build's audit.")
    closure = {row["Category"]: (row["Unchanged"], row["PreviousCount"], row["CurrentCount"])
               for row in api["StoryPortraitClosure"]["Closure"]}
    if closure != {"Methods": (True, 60, 60), "Types": (True, 14, 14)}:
        raise ValueError("The audited Story portrait controller closure changed.")
    if (graph["CharacterCount"] != 7 or graph["RecordCount"] != 48 or graph["BundleCount"] != 11
            or graph["ExistingAllowedMappingsAndSpriteBytesPreserved"] is not True
            or graph["AllPortraitBundlesByteIdentical"] is not True or avatars["ScriptDefinitionUnchanged"] is not True
            or avatars["PreviousComponentCount"] != len(avatars["CurrentComponents"]) or not avatars["CurrentComponents"]):
        raise ValueError("The portrait resources and avatar evidence do not match this release.")
    fingerprints = api["FingerprintSet"]
    if (set(fingerprints) != set(baseline["KnownGameFingerprintGroups"][-1]["Hashes"])
            or any(len(h) != 64 or any(c not in '0123456789ABCDEF' for c in h) for h in fingerprints.values())):
        raise ValueError("Incomplete game fingerprint group.")
    runtime = json.loads(source_bytes(RUNTIME_REPORT))
    if runtime["Passed"] is not True or runtime["ActualGameRun"] is not True or str(runtime["GameBuildId"]) != BUILD or runtime["PackageVersion"] != VERSION:
        raise ValueError("The runtime validation report does not match this release.")
    if runtime["GameVersion"] != version or runtime["CatalogSha256"].upper() != digest(package_bytes("VariantCatalog.json", original)):
        raise ValueError("The runtime validation report tested different game or catalog bytes.")
    plugin_hash = baseline["SharedPluginFiles"][0]["Sha256"]
    if (runtime["PluginSha256"] != plugin_hash or api["PluginSha256"] != plugin_hash
            or len(runtime["Characters"]) != 7 or any(row["Passed"] is not True for row in runtime["Characters"])
            or runtime["Preservation"]["Passed"] is not True or runtime["NormalSteamStartup"]["Passed"] is not True):
        raise ValueError("The runtime report does not cover all characters, normal startup and preservation.")
    evidence = {row["Path"]: row["Sha256"] for row in runtime["EvidenceFiles"]}
    if set(evidence) != RUNTIME_EVIDENCE or any(digest(source_bytes(path)) != ref for path, ref in evidence.items()):
        raise ValueError("The runtime evidence files differ from the signed-off report.")
    if str(json.loads(source_bytes(ROUTE_REPORT))["GameBuildId"]) != BUILD or route["TestCount"] < 17:
        raise ValueError("The installer routing tests do not cover all previously verified builds and the new build.")
    groups = baseline["KnownGameFingerprintGroups"] + [{"BuildId": BUILD, "GameVersion": version, "Hashes": fingerprints}]
    compat = dict(baseline["CompatibilityCheck"])
    compat.update({"ProbeSHA256": digest(package_bytes(PROBE, original)), "Baselines": compat["Baselines"] + [
        {"Path": GAME_BASELINE, "Sha256": digest(source_bytes(GAME_BASELINE)), "BuildIds": [BUILD]},
    ]})
    checked_baselines = json.loads(source_bytes(PROBE_REPORT))["Baselines"]
    if (probe["TestCount"] < 38 or [{k: item[k] for k in ("Path", "Sha256", "BuildIds")} for item in checked_baselines]
            != compat["Baselines"]):
        raise ValueError("The offline compatibility tests did not verify these exact six baselines.")
    paths = sorted(set(original) | ADDED)
    archive = output / (NAME + ".zip")
    if not check_only:
        output.mkdir(parents=True, exist_ok=True)
        if archive.exists() or Path(str(archive) + ".sha256").exists():
            raise FileExistsError(archive)
    with tempfile.TemporaryDirectory(dir=output if not check_only else None) as tmp:
        tmpzip = Path(tmp) / "release.zip"
        with (nullcontext() if check_only else ZipFile(tmpzip, "x", ZIP_DEFLATED, compresslevel=6)) as zipped:
            def write(name, data):
                if zipped is not None:
                    zipped.writestr(f"{NAME}/{name}", data)

            entries = []
            for name in paths:
                data = package_bytes(name, original)
                entries.append({"Path": name, "SHA256": digest(data), "Bytes": len(data)})
                write(name, data)
            manifest = {key: baseline[key] for key in (
                "Package", "RuntimeVersion", "Platform", "SteamAppId", "DefaultCharacterId",
                "CatalogSchemaVersion", "InstallationSchemaVersion", "Characters", "Variants",
                "PortraitCount", "SharedPluginFiles",
            )}
            manifest.update({
                "Version": VERSION, "Catalog": {"Path": "VariantCatalog.json", "SHA256": digest(package_bytes("VariantCatalog.json", original))},
                "KnownGameFingerprintGroups": groups, "CompatibilityCheck": compat,
                "Validation": {"SteamDiscovery": steam, "OfflineUpdater": updater, "OfflineProbe": probe,
                               "BuildRouting": route, "GameResources": static_reports,
                               "GameRuntime": {"Path": RUNTIME_REPORT, "SHA256": digest(source_bytes(RUNTIME_REPORT))}},
                "HistoricalValidation": {"Version": PREVIOUS, "Manifest": BASE, "SHA256": BASE_SHA256,
                                         "Scope": "Unchanged portrait art, layouts, runtime plugin and previous build fingerprints."},
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
