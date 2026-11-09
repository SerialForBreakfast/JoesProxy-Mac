import unittest

import caption_contract_test as runner


class CaptionContractRunnerTests(unittest.TestCase):
    def test_actual_shared_sources_have_nonempty_unique_cases(self):
        cases = runner.expected_cases()
        self.assertIn("WebVTTEngineTests/testCueParsingAndTimestampCalculation", cases)
        self.assertIn("CaptionPreparationContractTests/testPreparedTracksHaveResolvableManifestsHashesAndParseableCues", cases)
        self.assertTrue(all((runner.ROOT / path).is_file() for path in runner.SOURCES + runner.TESTS))

    def test_accepts_exact_pass_identities(self):
        text = "Test Case '-[CaptionContracts.Example testContract]' passed (0.01 seconds)."
        self.assertEqual(runner.validate_test_result({"Example/testContract"}, text), ["Example/testContract"])

    def test_empty_missing_or_extra_cases_do_not_pass(self):
        text = "Test Case '-[CaptionContracts.Example testContract]' passed (0.01 seconds)."
        for expected, output in [(set(), ""), ({"Example/testContract"}, ""),
                                 ({"Example/testOther"}, text),
                                 ({"Example/testContract", "Example/testOther"}, text)]:
            with self.assertRaises(ValueError):
                runner.validate_test_result(expected, output)

    def test_retries_or_skips_do_not_hide_failures(self):
        passed = "Test Case '-[CaptionContracts.Example testContract]' passed (0.01 seconds).\n"
        for output in [passed * 2, passed + passed.replace("passed", "failed"),
                       passed + passed.replace("passed", "skipped")]:
            with self.assertRaises(ValueError):
                runner.validate_test_result({"Example/testContract"}, output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
