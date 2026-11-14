"""Read-only, dependency-free checks for focused Policy validation and build reuse."""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TREES = ("JoesProxy", "JoesProxyTests", "JoesProxyUITests", "JoesProxyCLI", "DocumentationShared",
         "JoesProxyAgentPrototypeResources", "Config", "Fixtures", "JoesProxy.xcodeproj",
         "JoesProxy.xcworkspace", "assets", "memlog/utility_scripts")


def artifact_path(root, value):
    path = (root / value).resolve()
    if not path.is_relative_to(root / "build") or path == root / "build":
        raise ValueError("Paths must resolve strictly inside this repository's build directory")
    return path


def validate_selection(root, value, lane="policy"):
    if lane == "transport" and value not in (
        "JoesProxyTests/ProxyServerTests/testScriptedBinaryFramingMatrixAcrossTransportModes",
        "JoesProxyTests/ProxyServerTests/testScriptedMixedBurstIdleResumeDrainsWithMetrics",
        "JoesProxyTests/NetworkThrottleSocketPressureTests",
    ):
        raise ValueError("Transport lane is restricted to bounded scripted transport tests")
    if lane == "soak" and value != "JoesProxyTests/ProxyServerTests/testCaptureSoakWithAgentWorkflows":
        raise ValueError("Soak lane is restricted to the opt-in capture soak test")
    if lane == "stability":
        if value != "JoesProxyUITests/CaptureStabilityProfilingUITests":
            raise ValueError("Stability preparation must select the complete CaptureStabilityProfilingUITests class")
        if not (root / "JoesProxyUITests/CaptureStabilityProfilingUITests.swift").is_file():
            raise ValueError("Missing stability test source")
        return
    if not re.fullmatch(r"JoesProxyTests/[A-Za-z_][A-Za-z0-9_]*(/[A-Za-z_][A-Za-z0-9_]*)?", value):
        raise ValueError("Expected an explicit Policy class/method, not UI or a wildcard")
    parts = value.split("/")
    sources = [p.read_text() for p in (root / "JoesProxyTests").rglob("*.swift")]
    candidates = [s for s in sources if re.search(r"\bclass\s+" + re.escape(parts[1]) + r"\b", s)]
    if not candidates or (len(parts) == 3 and not any(re.search(r"\bfunc\s+" + re.escape(parts[2]) + r"\s*\(", s) for s in candidates)):
        raise ValueError("Unknown test selection: " + value)


def digest(paths):
    result = hashlib.sha256()
    for base in sorted(paths):
        if not base.exists():
            raise ValueError("Missing input: " + str(base))
        for path in ([base] if base.is_file() else sorted(base.rglob("*"))):
            if any(p in (".git", "xcuserdata", "__pycache__") for p in path.relative_to(base.parent).parts):
                continue
            result.update(str(path).encode())
            if path.is_symlink():
                if not path.resolve().is_relative_to(base) or not path.exists():
                    raise ValueError("External/broken symlink cannot certify reuse: " + str(path))
                result.update(os.readlink(path).encode())
                continue
            if path.is_file():
                with path.open("rb") as source:
                    for block in iter(lambda: source.read(1024 * 1024), b""):
                        result.update(block)
    return result.hexdigest()


def fingerprint(root, packages, derived, selections, version, lane="policy", compiler_stats=False):
    paths = [root / name for name in TREES if (root / name).exists()]
    paths += list(root.glob("*.xctestplan")) + [packages / "checkouts"]
    identity = {"schema": 1, "inputs": digest(paths), "derivedData": str(derived),
                "packages": str(packages), "selections": sorted(selections), "xcode": version,
                "configuration": ("Release/Stability/serial/no-sanitizers/no-checkers/no-coverage" if lane == "stability"
                                  else "Release/Transport/serial/testability/no-sanitizers/no-checkers/no-coverage" if lane == "transport"
                                  else "Release/Soak/serial/testability/no-sanitizers/no-checkers/no-coverage" if lane == "soak"
                                  else "Debug/Policy/serial/default-scheme-instrumentation"),
                "environment": {key: os.environ.get(key) for key in
                                ("DEVELOPER_DIR", "TOOLCHAINS", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET")}}
    if compiler_stats:
        identity["compilerStats"] = True
    return identity


def classify(code, summary, log):
    markers = ("Timed out while enabling automation mode", "failed to initialize for UI testing",
               "Failed to establish communication", "Failed to establish a connection",
               "test runner never began executing", "Testing failed to start")
    if any(m.lower() in log.lower() for m in markers):
        return "infrastructure_blocked"
    if not isinstance(summary, dict):
        return "incomplete_result"
    if summary.get("totalTestCount", 0) == 0:
        return "empty_selection"
    if code or summary.get("failedTests", 0) or summary.get("result") != "Passed":
        return "test_failure"
    return "passed" if summary.get("passedTests", 0) else "no_passed_tests"


def require_stability_products(derived):
    products = derived / "Build/Products"
    required = [products / "Release/JoesProxy.app/Contents/MacOS/JoesProxy",
                products / "Release/JoesProxyUITests-Runner.app/Contents/MacOS/JoesProxyUITests-Runner"]
    if not all(path.is_file() for path in required) or not list(products.glob("*JoesProxy-Stability*.xctestrun")):
        raise ValueError("Incomplete stability products: Release app, UI runner and stability xctestrun are required")


def require_transport_products(derived, plan="JoesProxy-Transport"):
    products = derived / "Build/Products"
    runs = list(products.glob("*" + plan + "*.xctestrun"))
    if len(runs) != 1:
        raise ValueError("Exactly one transport xctestrun required")
    with runs[0].open("rb") as source:
        run = plistlib.load(source)
    targets = [t for c in run.get("TestConfigurations", []) for t in c.get("TestTargets", [])]
    if len(targets) != 1 or targets[0].get("BlueprintName") != "JoesProxyTests" or targets[0].get("IsUITestBundle"):
        raise ValueError("Transport products must contain only the unit-test target")
    target = targets[0]
    host = Path(target.get("TestHostPath", "").replace("__TESTROOT__", str(products)))
    if not host.is_relative_to(products) or "Release" not in host.parts:
        raise ValueError("Transport test host must be a repository Release product")
    for binary in (host / "Contents/MacOS/JoesProxy", host / "Contents/PlugIns/JoesProxyTests.xctest/Contents/MacOS/JoesProxyTests"):
        if not binary.is_file() or binary.stat().st_size == 0:
            raise ValueError("Incomplete transport executable: " + str(binary))
    env = str(target.get("EnvironmentVariables", {})) + str(target.get("TestingEnvironmentVariables", {}))
    if any(value in env.lower() for value in ("libmainthreadchecker", "librpac", "libclang_rt.asan", "libclang_rt.tsan", "libclang_rt.ubsan")):
        raise ValueError("Instrumented transport runtime cannot certify performance reuse")


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "--classify":
        try:
            summary = json.loads(Path(sys.argv[3]).read_text())
        except (OSError, ValueError):
            summary = None
        print(classify(int(sys.argv[2]), summary, Path(sys.argv[4]).read_text(errors="replace")))
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", required=True)
    parser.add_argument("--lane", choices=("policy", "stability", "transport", "soak"), default="policy")
    parser.add_argument("--compiler-stats", action="store_true")
    parser.add_argument("--packages", required=True)
    parser.add_argument("--products", action="store_true")
    parser.add_argument("--check-idle", action="store_true")
    parser.add_argument("--paths-only", action="store_true")
    parser.add_argument("selection", nargs="+")
    args = parser.parse_args()
    derived = artifact_path(ROOT, args.derived_data)
    packages = artifact_path(ROOT, args.packages)
    if not (packages / "checkouts").is_dir():
        raise ValueError("Existing package checkouts required; no installation/resolution attempted")
    if os.environ.get("XCODE_XCCONFIG_FILE"):
        raise ValueError("External XCODE_XCCONFIG_FILE is outside the freshness contract")
    if any(os.environ.get(key) == "1" for key in ("JOESPROXY_CAPTION_PLAYER_ACCEPTANCE",
                                                "TEST_RUNNER_JOESPROXY_CAPTION_PLAYER_ACCEPTANCE")):
        raise ValueError("Player acceptance requires the approved host wrapper, not the Policy helper")
    for selection in args.selection:
        validate_selection(ROOT, selection, args.lane)
    if args.paths_only:
        print(json.dumps({"derivedData": str(derived), "packages": str(packages)}))
        return
    if args.check_idle:
        active = subprocess.run(["ps", "-axo", "comm="], capture_output=True, text=True)
        if active.returncode or any(Path(p.strip()).name == "xcodebuild" for p in active.stdout.splitlines()):
            raise ValueError("Cannot establish idle build host; inspect existing builds. No process stopped")
    version = subprocess.check_output(["xcodebuild", "-version"], text=True)
    version += subprocess.check_output(["xcode-select", "-p"], text=True)
    version += subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-build-version"], text=True)
    value = fingerprint(ROOT, packages, derived, args.selection, version, args.lane, args.compiler_stats)
    if args.products:
        if args.lane == "stability":
            require_stability_products(derived)
        if args.lane == "transport":
            require_transport_products(derived)
        if args.lane == "soak":
            require_transport_products(derived, "JoesProxy-Soak")
        value["products"] = digest([derived / "Build/Products"])
    print(json.dumps(value, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print("Preflight rejected: " + str(error), file=sys.stderr)
        sys.exit(65)
