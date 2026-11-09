"""Fast, host-independent checks for lane isolation and bounded preparation."""
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch, Mock
import xml.etree.ElementTree as ET

import bounded_build
import validation_preflight as preflight

ROOT = preflight.ROOT


class StabilityWorkflowTests(unittest.TestCase):
    def test_compiler_statistics_avoid_crashing_detail_profiler(self):
        helper = (ROOT / "memlog/utility_scripts/focused_test.sh").read_text()
        self.assertIn("-stats-output-dir", helper)
        self.assertNotIn("-profile-stats-events", helper)
        self.assertNotIn("-profile-stats-entities", helper)

    def test_compiler_stats_cannot_change_policy_preparation(self):
        result = subprocess.run(["/bin/zsh", str(ROOT / "memlog/utility_scripts/focused_test.sh"),
                                 "--compiler-stats", "--prepare-only", "--dry-run"],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 64)
        self.assertIn("restricted to stability", result.stdout)

    def test_compiler_stats_hook_only_exists_on_main_release_target(self):
        result = subprocess.run(["plutil", "-convert", "json", "-o", "-",
                                 str(ROOT / "JoesProxy.xcodeproj/project.pbxproj")],
                                text=True, capture_output=True, check=True)
        objects = json.loads(result.stdout)["objects"]
        matches = [(key, value) for key, value in objects.items()
                   if "JOESPROXY_COMPILER_DIAGNOSTIC_FLAGS" in
                   value.get("buildSettings", {}).get("OTHER_SWIFT_FLAGS", "")]
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0][0], "4498EC402CDAED9B00844D6D")
        self.assertEqual(matches[0][1]["name"], "Release")

    def test_stability_builds_only_main_app_explicitly(self):
        scheme = ET.parse(ROOT / "JoesProxy.xcodeproj/xcshareddata/xcschemes/JoesProxy-Stability.xcscheme")
        names = [item.attrib["BlueprintName"] for item in scheme.findall(".//BuildActionEntry/BuildableReference")]
        self.assertEqual(names, ["JoesProxy"])
        self.assertEqual(scheme.find("TestAction").attrib["buildConfiguration"], "Release")
        plan = json.loads((ROOT / "JoesProxy-Stability.xctestplan").read_text())
        self.assertEqual(plan["testTargets"][0]["selectedTests"], ["CaptureStabilityProfilingUITests"])
        self.assertFalse(plan["defaultOptions"]["mainThreadCheckerEnabled"])

    def test_stability_uses_screenshots_instead_of_continuous_video(self):
        plan = json.loads((ROOT / "JoesProxy-Stability.xctestplan").read_text())
        self.assertEqual(plan["defaultOptions"]["preferredScreenCaptureFormat"], "screenshots")
        self.assertNotEqual(plan["defaultOptions"].get("userAttachmentLifetime"), "keepNever")

    def test_comparison_lane_retains_prototype(self):
        scheme = ET.parse(ROOT / "JoesProxy.xcodeproj/xcshareddata/xcschemes/JoesProxy-Profiling.xcscheme")
        self.assertIn("JoesProxyAgentPrototype", [node.attrib["BlueprintName"]
                      for node in scheme.findall(".//BuildActionEntry/BuildableReference")])

    def test_stability_selection_is_closed(self):
        preflight.validate_selection(ROOT, "JoesProxyUITests/CaptureStabilityProfilingUITests", "stability")
        for selection in ["JoesProxyUITests/AgentWorkspaceProfilingUITests", "JoesProxyUITests/*", "JoesProxyTests/Test"]:
            with self.assertRaises(ValueError):
                preflight.validate_selection(ROOT, selection, "stability")

    def test_timeout_interrupts_only_owned_child(self):
        child = Mock(pid=123)
        child.wait.side_effect = [subprocess.TimeoutExpired("build", 600), -2]
        with patch.object(bounded_build.subprocess, "Popen", return_value=child):
            self.assertEqual(bounded_build.run(["xcodebuild", "build-for-testing"], 600), 124)
        child.send_signal.assert_called_once_with(bounded_build.signal.SIGINT)
        child.kill.assert_not_called()

    def test_success_preserves_exit(self):
        child = Mock()
        child.wait.return_value = 0
        with patch.object(bounded_build.subprocess, "Popen", return_value=child):
            self.assertEqual(bounded_build.run(["xcodebuild", "build-for-testing"], 600), 0)
        child.send_signal.assert_not_called()

    def test_real_child_timeout_does_not_launch_xcode(self):
        self.assertEqual(bounded_build.run(["/bin/sleep", "2"], 0.01), 124)

    def test_stability_host_lane_cannot_implicitly_build(self):
        result = subprocess.run(["/bin/zsh", str(ROOT / "memlog/utility_scripts/host_ui_test.sh"),
                                 "--dry-run", "--acknowledge-host-control", "--plan", "stability"],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 64)
        self.assertIn("never builds", result.stdout)

    def test_stability_helper_cannot_launch_ui(self):
        result = subprocess.run(["/bin/zsh", str(ROOT / "memlog/utility_scripts/focused_test.sh"),
                                 "--lane", "stability"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 64)
        self.assertIn("preparation/reuse verification only", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
