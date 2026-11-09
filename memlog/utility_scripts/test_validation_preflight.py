"""Unattended regression checks; all synthetic scratch is retained under repository build/."""
import importlib.util
from pathlib import Path
import tempfile
import plistlib
import unittest

SPEC = importlib.util.spec_from_file_location("preflight", Path(__file__).with_name("validation_preflight.py"))
PREFLIGHT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREFLIGHT)


class ValidationPreflightTests(unittest.TestCase):
    def test_transport_rejects_unbounded_or_ui_selection(self):
        for value in ("JoesProxyTests/ExampleTests", "JoesProxyTests/ProxyServerTests", "JoesProxyUITests/CaptureStabilityProfilingUITests"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                PREFLIGHT.validate_selection(self.root, value, "transport")

    def test_transport_requires_release_unit_products_without_injected_checkers(self):
        derived = self.root / "build/data"
        products = derived / "Build/Products"
        host = products / "Release/JoesProxy.app"
        executable = host / "Contents/MacOS/JoesProxy"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"synthetic")
        test_binary = host / "Contents/PlugIns/JoesProxyTests.xctest/Contents/MacOS/JoesProxyTests"
        test_binary.parent.mkdir(parents=True)
        test_binary.write_bytes(b"synthetic")
        target = {"BlueprintName": "JoesProxyTests", "TestHostPath": "__TESTROOT__/Release/JoesProxy.app"}
        path = products / "JoesProxy-Transport_test.xctestrun"
        def save():
            path.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [target]}]}))
        save()
        PREFLIGHT.require_transport_products(derived)
        for key, value in (("IsUITestBundle", True), ("TestHostPath", "__TESTROOT__/Debug/JoesProxy.app"),
                           ("TestingEnvironmentVariables", {"DYLD_INSERT_LIBRARIES": "libMainThreadChecker.dylib"})):
            original = dict(target)
            target[key] = value
            save()
            with self.assertRaises(ValueError):
                PREFLIGHT.require_transport_products(derived)
            target.clear()
            target.update(original)
        save()
        executable.write_bytes(b"")
        with self.assertRaises(ValueError):
            PREFLIGHT.require_transport_products(derived)

    def setUp(self):
        scratch = PREFLIGHT.ROOT / "build/ValidationHelperTests"
        scratch.mkdir(parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(dir=scratch))
        (self.root / "JoesProxyTests").mkdir()
        (self.root / "JoesProxyTests/Fixture.swift").write_text("final class ExampleTests: XCTestCase { func testExample() {} }")

    def test_selection_rejects_unknown_ui_and_wildcards(self):
        PREFLIGHT.validate_selection(self.root, "JoesProxyTests/ExampleTests/testExample")
        for value in ("JoesProxyUITests/ExampleTests", "JoesProxyTests/*", "JoesProxyTests/Missing",
                      "JoesProxyTests/ExampleTests/testMissing", "../ExampleTests"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                PREFLIGHT.validate_selection(self.root, value)

    def test_artifacts_must_stay_inside_build(self):
        self.assertEqual(PREFLIGHT.artifact_path(self.root, "build/data"), self.root / "build/data")
        for value in ("build", "build/../../elsewhere", "JoesProxyTests", "/tmp"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                PREFLIGHT.artifact_path(self.root, value)

    def test_source_additions_changes_and_deletions_invalidate(self):
        tree = self.root / "JoesProxyTests"
        original = PREFLIGHT.digest([tree])
        extra = tree / "Added.swift"
        extra.write_text("new input")
        added = PREFLIGHT.digest([tree])
        self.assertNotEqual(original, added)
        extra.write_text("new INPUT")
        self.assertNotEqual(added, PREFLIGHT.digest([tree]))
        # Rename away inside retained scratch models removal without deleting user files.
        extra.rename(self.root / "removed-input.txt")
        self.assertEqual(original, PREFLIGHT.digest([tree]))

    def test_internal_symlinks_are_hashed_and_external_links_reject(self):
        tree = self.root / "JoesProxyTests"
        (tree / "alias").symlink_to("Fixture.swift")
        PREFLIGHT.digest([tree])
        (tree / "external").symlink_to(self.root / "removed-input.txt")
        with self.assertRaises(ValueError):
            PREFLIGHT.digest([tree])

    def test_same_size_product_changes_invalidate(self):
        product = self.root / "binary"
        product.write_bytes(b"AAAA")
        first = PREFLIGHT.digest([product])
        product.write_bytes(b"BBBB")
        self.assertNotEqual(first, PREFLIGHT.digest([product]))

    def test_missing_inputs_do_not_certify(self):
        with self.assertRaises(ValueError):
            PREFLIGHT.digest([self.root / "missing"])

    def test_partial_release_cannot_certify_stability(self):
        derived = self.root / "build/data"
        products = derived / "Build/Products"
        app = products / "Release/JoesProxy.app/Contents/MacOS/JoesProxy"
        app.parent.mkdir(parents=True)
        app.write_bytes(b"synthetic")
        with self.assertRaises(ValueError):
            PREFLIGHT.require_stability_products(derived)
        runner = products / "Release/JoesProxyUITests-Runner.app/Contents/MacOS/JoesProxyUITests-Runner"
        runner.parent.mkdir(parents=True)
        runner.write_bytes(b"synthetic")
        with self.assertRaises(ValueError):
            PREFLIGHT.require_stability_products(derived)
        (products / "JoesProxy-Stability_test.xctestrun").write_bytes(b"synthetic")
        PREFLIGHT.require_stability_products(derived)

    def test_toolchain_scope_and_packages_are_part_of_identity(self):
        packages = self.root / "build/packages"
        (packages / "checkouts").mkdir(parents=True)
        package = packages / "checkouts/dependency.swift"
        package.write_text("revision one")
        args = (self.root, packages, self.root / "build/data")
        first = PREFLIGHT.fingerprint(*args, ["A"], "Xcode A")
        self.assertNotEqual(first, PREFLIGHT.fingerprint(*args, ["B"], "Xcode A"))
        self.assertNotEqual(first, PREFLIGHT.fingerprint(*args, ["A"], "Xcode B"))
        self.assertNotEqual(first, PREFLIGHT.fingerprint(*args, ["A"], "Xcode A", "stability"))
        self.assertNotEqual(first, PREFLIGHT.fingerprint(*args, ["A"], "Xcode A", "transport"))
        normal = PREFLIGHT.fingerprint(*args, ["A"], "Xcode A", "stability")
        measured = PREFLIGHT.fingerprint(*args, ["A"], "Xcode A", "stability", True)
        self.assertNotEqual(normal, measured)
        self.assertTrue(measured["compilerStats"])
        package.write_text("revision two")
        self.assertNotEqual(first, PREFLIGHT.fingerprint(*args, ["A"], "Xcode A"))

    def test_outcomes_do_not_conflate_environment_skips_and_passes(self):
        passed = {"result": "Passed", "totalTestCount": 2, "passedTests": 2, "failedTests": 0}
        cases = [(0, passed, "", "passed"), (65, passed, "", "test_failure"),
                 (0, None, "", "incomplete_result"),
                 (0, dict(passed, totalTestCount=0), "", "empty_selection"),
                 (0, dict(passed, passedTests=0), "", "no_passed_tests"),
                 (65, None, "Timed out while enabling automation mode", "infrastructure_blocked")]
        for code, summary, log, expected in cases:
            with self.subTest(expected=expected):
                self.assertEqual(PREFLIGHT.classify(code, summary, log), expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
