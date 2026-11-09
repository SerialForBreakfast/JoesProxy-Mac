#!/usr/bin/env python3
"""Compile actual caption sources and shared XCTest cases without an app or package graph.

This supplemental lane does not certify app linkage, serving, UI or player behavior.
Every invocation builds fresh products. Artifacts remain under build/CaptionContracts.
"""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
SOURCES = (
    "JoesProxy/MediaFixture/HLSFixtureLimits.swift",
    "JoesProxy/MediaFixture/HLSPlaybackConfiguration.swift",
    "JoesProxy/MediaFixture/HLSFixtureProfileDescriptor.swift",
    "JoesProxy/MediaFixture/HLSSlidingPlaylistComputer.swift",
    "JoesProxy/MediaFixture/HLSWebVTTFixture.swift",
    "JoesProxy/MediaInfo/WebVTTEngine.swift",
    "JoesProxy/MediaInfo/WebVTTModels.swift",
)
TESTS = (
    "JoesProxyTests/WebVTTEngineTests.swift",
    "JoesProxyTests/MediaFixture/CaptionPreparationContractTests.swift",
    "JoesProxyTests/MediaFixture/HLSPlaybackConfigurationTests.swift",
    "JoesProxyTests/MediaFixture/HLSSlidingPlaylistComputerTests.swift",
)


def expected_cases():
    result = set()
    for relative in TESTS:
        text = (ROOT / relative).read_text()
        classes = re.findall(r"final class (\w+): XCTestCase", text)
        if len(classes) != 1:
            raise ValueError(f"Expected one concrete test class: {relative}")
        methods = re.findall(r"\bfunc (test\w+)\(\)", text)
        if not methods or len(methods) != len(set(methods)):
            raise ValueError(f"Missing or duplicate cases: {relative}")
        result.update(f"{classes[0]}/{method}" for method in methods)
    return result


def passed_cases(text):
    return [f"{name}/{method}" for name, method in re.findall(
        r"Test Case '-\[(?:\w+\.)?(\w+) (test\w+)\]' passed", text)]


def validate_test_result(expected, text):
    passed = passed_cases(text)
    if not expected or set(passed) != expected or len(passed) != len(expected):
        raise ValueError("Passed identities do not match intended cases exactly once; inspect tests.log")
    if re.search(r"Test Case .* (failed|skipped)", text):
        raise ValueError("Failed or skipped cases are not accepted")
    return sorted(passed)


def main():
    artifact_root = ROOT / "build/CaptionContracts"
    if artifact_root.resolve() != artifact_root or (ROOT / "build").is_symlink():
        raise ValueError("Artifact path must not traverse symlinks")
    # Do not inherit test injection, credentials or unrelated developer environment overrides.
    environment = {key: os.environ[key] for key in ("HOME",) if key in os.environ}
    environment.update(PATH="/usr/bin:/bin", LANG="en_US.UTF-8")

    def read_tool(*command):
        return subprocess.check_output(command, env=environment, text=True, timeout=30).strip()

    processes = read_tool("/bin/ps", "-axo", "comm=")
    if any(Path(line.strip()).name == "xcodebuild" for line in processes.splitlines()):
        raise ValueError("An existing Xcode build is active; no process stopped")
    developer = Path(read_tool("/usr/bin/xcode-select", "-p"))
    sdk = read_tool("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path")
    compiler = read_tool("/usr/bin/xcrun", "--find", "swiftc")
    runner = read_tool("/usr/bin/xcrun", "--find", "xctest")
    frameworks = developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
    swift_support = developer / "Platforms/MacOSX.platform/Developer/usr/lib"
    if not (frameworks / "XCTest.framework").is_dir():
        raise ValueError("Installed XCTest framework missing; no installation attempted")
    expected = expected_cases()
    artifact_root.mkdir(parents=True, exist_ok=True)
    lock_path = artifact_root / "serial.lock"
    if lock_path.is_symlink():
        raise ValueError("Lock must not be a symlink")
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run = Path(tempfile.mkdtemp(prefix="run-", dir=artifact_root))
        environment["TMPDIR"] = str(run / "tmp") + "/"
        (run / "tmp").mkdir()
        bundle = run / "CaptionContracts.xctest"
        binary = bundle / "Contents/MacOS/CaptionContracts"
        binary.parent.mkdir(parents=True)
        with (bundle / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "com.ShowBlender.JoesProxy.CaptionContracts",
                          "CFBundleExecutable": "CaptionContracts", "CFBundlePackageType": "BNDL"}, stream)
        inputs = {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in SOURCES + TESTS}
        receipt = {"scope": "source-contracts-only", "expected": sorted(expected), "inputs": inputs,
                   "compiler": read_tool(compiler, "--version"), "sdk": sdk, "outcome": "incomplete"}
        print(f"Host-independent contracts; no app, UI, player or package resolution. Artifacts: {run}", flush=True)

        def execute(command, name, timeout):
            start = time.monotonic()
            try:
                with (run / f"{name}.log").open("w") as log:
                    result = subprocess.run(command, env=environment, cwd=ROOT, stdout=log,
                                            stderr=subprocess.STDOUT, timeout=timeout, check=False)
                receipt[f"{name}ExitCode"] = result.returncode
                if result.returncode:
                    raise RuntimeError(f"{name} failed; inspect {run / (name + '.log')}")
            finally:
                receipt[f"{name}Seconds"] = round(time.monotonic() - start, 3)

        try:
            execute([compiler, "-emit-library", "-module-name", "CaptionContracts", "-sdk", sdk,
                     "-swift-version", "5", "-Onone", "-g", "-D", "JOESPROXY_CAPTION_CONTRACT_TESTS",
                     "-F", str(frameworks), "-framework", "XCTest", "-Xlinker", "-rpath",
                     "-Xlinker", str(frameworks), "-I", str(swift_support), "-L", str(swift_support),
                     "-lXCTestSwiftSupport", "-Xlinker", "-rpath", "-Xlinker", str(swift_support),
                     "-module-cache-path", str(run / "ModuleCache"),
                     *[str(ROOT / path) for path in SOURCES + TESTS], "-o", str(binary)], "compile", 180)
            execute([runner, str(bundle)], "tests", 120)
            receipt["passed"] = validate_test_result(expected, (run / "tests.log").read_text())
            after = {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in SOURCES + TESTS}
            if after != inputs:
                raise RuntimeError("Sources changed during validation; result not accepted")
            receipt["outcome"] = "passed"
        finally:
            (run / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(f"Passed {len(expected)} exact cases. Receipt: {run / 'receipt.json'}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Contract validation incomplete: {error}", flush=True)
        raise SystemExit(65)
