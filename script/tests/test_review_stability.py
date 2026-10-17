"""Regression tests for the public stability assessment and command-line workflow."""
import importlib.util
import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "review_stability.py"
SPEC = importlib.util.spec_from_file_location("review_stability", SCRIPT)
review_stability = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(review_stability)


def sessions(build, count, prefix="session"):
    return {
        f"{prefix}-{index}": {
            "build": build,
            "day": f"2026-10-{index % 3 + 1:02d}",
            "finish_ms": 100,
            "samples": 16000,
            "paste_outcome": "verified",
        }
        for index in range(count)
    }


class StabilityAssessmentTests(unittest.TestCase):
    def test_two_builds_cannot_combine_dictations_to_pass(self):
        state = {
            "sessions": {
                **sessions("old", 25, "old"),
                **sessions("candidate", 25, "candidate"),
            },
            "faults": {},
        }

        result = review_stability.assess(state)

        self.assertFalse(result["passing"])
        self.assertEqual(result["coverage"], "ambiguous_builds")
        self.assertIsNone(result["build"])
        self.assertEqual(result["by_build"]["old"]["completed_dictations"], 25)
        self.assertEqual(result["by_build"]["candidate"]["completed_dictations"], 25)

    def test_selected_build_passes_without_inheriting_another_builds_faults(self):
        state = {
            "sessions": {**sessions("candidate", 50), **sessions("old", 25, "old")},
            "faults": {"old-fault": {"event": "finish_timeout", "build": "old"}},
        }
        result = review_stability.assess(state, "candidate")
        self.assertTrue(result["passing"])
        self.assertEqual(result["completed_dictations"], 50)
        self.assertEqual(result["fault_count"], 0)
        self.assertFalse(result["by_build"]["old"]["passing"])

    def test_missing_session_identity_blocks_even_a_selected_build(self):
        state = {"sessions": {**sessions("candidate", 50),
                              **sessions(None, 1, "legacy")}, "faults": {}}
        result = review_stability.assess(state, "candidate")
        self.assertFalse(result["passing"])
        self.assertEqual(result["coverage"], "missing_build_identity")
        self.assertEqual(result["missing_build_sessions"], 1)

    def test_legacy_fault_identity_is_reported_as_incomplete(self):
        state = {"sessions": sessions("candidate", 50),
                 "faults": {"legacy": "finish_timeout"}}
        result = review_stability.assess(state)
        self.assertFalse(result["passing"])
        self.assertEqual(result["coverage"], "missing_build_identity")
        self.assertEqual(result["missing_build_faults"], 1)

    def test_a_requested_build_without_evidence_cannot_use_another_build(self):
        result = review_stability.assess(
            {"sessions": sessions("old", 50), "faults": {}}, "candidate")
        self.assertFalse(result["passing"])
        self.assertEqual(result["coverage"], "no_evidence")
        self.assertEqual(result["completed_dictations"], 0)

    def test_selected_builds_own_fault_blocks_the_gate(self):
        state = {"sessions": sessions("candidate", 50),
                 "faults": {"failure": {"event": "finish_timeout", "build": "candidate"}}}
        result = review_stability.assess(state)
        self.assertFalse(result["passing"])
        self.assertEqual(result["fault_count"], 1)

    def test_unverified_receipts_still_count_only_for_responsiveness(self):
        evidence = sessions("candidate", 50)
        for entry in evidence.values():
            entry["paste_outcome"] = "unverified"
        result = review_stability.assess({"sessions": evidence, "faults": {}})
        self.assertTrue(result["passing"])
        self.assertEqual(result["unverified_deliveries"], 50)
        self.assertIn("not proof", result["note"])

    def test_existing_day_and_latency_thresholds_still_apply(self):
        evidence = sessions("candidate", 50)
        for entry in evidence.values():
            entry["day"] = "2026-10-01"
        self.assertFalse(review_stability.assess({"sessions": evidence, "faults": {}})["passing"])
        evidence = sessions("candidate", 50)
        evidence["session-0"]["finish_ms"] = 5001
        result = review_stability.assess({"sessions": evidence, "faults": {}})
        self.assertFalse(result["passing"])
        self.assertEqual(result["slow_completions"], 1)


class StabilityCommandTests(unittest.TestCase):
    def test_legacy_migration_keeps_newer_persisted_timing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state.json"
            now = time.time()
            evidence = sessions(None, 50)
            evidence["session-0"]["finish_ms"] = 5001
            state.write_text(json.dumps({
                "since": now - 4 * 86400, "updated_at": now - 60,
                "reason": "legacy", "sessions": {
                    "launch:" + key: entry for key, entry in evidence.items()
                }, "faults": {}, "previous_windows": [],
            }))
            rows = [{
                "timestamp": now - 3600, "build": "candidate", "launch": "launch",
                "session": key, "event": "finish_returned", "elapsed_ms": 100,
            } for key in evidence]
            (root / "diagnostics.jsonl").write_text("\n".join(json.dumps(row) for row in rows))
            command = [sys.executable, str(SCRIPT), "--state", str(state),
                       "--directory", str(root), "--build", "candidate"]
            result = json.loads(subprocess.run(command, check=True, capture_output=True,
                                               text=True).stdout)
            saved = json.loads(state.read_text())
            self.assertEqual(result["coverage"], "build_identified")
            self.assertFalse(result["passing"])
            self.assertEqual(result["slow_completions"], 1)
            self.assertEqual(saved["sessions"]["launch:session-0"]["finish_ms"], 5001)

    def test_older_replayed_rows_cannot_replace_newer_persisted_timing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state.json"
            now = time.time()
            state.write_text(json.dumps({
                "since": now - 4 * 86400, "reason": "rotation",
                "sessions": {}, "faults": {}, "previous_windows": [],
            }))
            rows = []
            for index in range(50):
                row = {"timestamp": now - 7200 - index % 3 * 86400,
                       "build": "candidate", "launch": "launch", "session": str(index)}
                rows.extend([
                    {**row, "event": "decode_returned", "samples": 16000},
                    {**row, "event": "finish_returned", "elapsed_ms": 100},
                    {**row, "event": "paste_returned", "outcome": "verified"},
                ])
            (root / "diagnostics.1.jsonl").write_text("\n".join(json.dumps(row) for row in rows))
            latest = root / "diagnostics.jsonl"
            latest.write_text(json.dumps({
                "timestamp": now - 3600, "build": "candidate", "launch": "launch",
                "session": "0", "event": "finish_returned", "elapsed_ms": 5001,
            }))
            command = [sys.executable, str(SCRIPT), "--state", str(state),
                       "--directory", str(root), "--build", "candidate"]
            first = json.loads(subprocess.run(command, check=True, capture_output=True,
                                              text=True).stdout)
            self.assertFalse(first["passing"])
            latest.unlink()
            second = json.loads(subprocess.run(command, check=True, capture_output=True,
                                               text=True).stdout)
            self.assertFalse(second["passing"])
            self.assertEqual(second["slow_completions"], 1)

    def test_rotated_logs_keep_builds_separate_and_persist_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            logs = root / "logs"
            logs.mkdir()
            state = root / "state.json"
            state.write_text(json.dumps({
                "since": time.time() - 4 * 86400,
                "reason": "test window",
                "sessions": {},
                "faults": {},
                "previous_windows": [],
            }))
            for build, filename in [("old", "diagnostics.1.jsonl"),
                                    ("candidate", "diagnostics.jsonl")]:
                rows = []
                for index in range(25):
                    row = {"build": build, "launch": build + "-launch",
                           "session": str(index),
                           "timestamp": time.time() - 7200 - index % 3 * 86400}
                    rows.extend([
                        {**row, "event": "decode_returned", "samples": 16000},
                        {**row, "event": "finish_returned", "elapsed_ms": 100},
                        {**row, "event": "paste_returned", "outcome": "verified"},
                    ])
                (logs / filename).write_text("\n".join(json.dumps(row) for row in rows))

            completed = subprocess.run(
                [sys.executable, str(SCRIPT), "--state", str(state),
                 "--directory", str(logs), "--build", "candidate"],
                check=True, capture_output=True, text=True,
            )
            result = json.loads(completed.stdout)
            saved = json.loads(state.read_text())

            self.assertFalse(result["passing"])
            self.assertEqual(result["build"], "candidate")
            self.assertEqual(result["completed_dictations"], 25)
            self.assertEqual(result["by_build"]["old"]["completed_dictations"], 25)
            self.assertEqual(saved["target_build"], "candidate")
            self.assertEqual({s["build"] for s in saved["sessions"].values()},
                             {"old", "candidate"})
            (logs / "diagnostics.1.jsonl").unlink()
            rerun = subprocess.run(
                [sys.executable, str(SCRIPT), "--state", str(state),
                 "--directory", str(logs)],
                check=True, capture_output=True, text=True,
            )
            repeated = json.loads(rerun.stdout)
            self.assertEqual(repeated["completed_dictations"], 25)
            self.assertEqual(repeated["by_build"]["old"]["completed_dictations"], 25)

    def test_reset_retains_previous_window_and_excludes_older_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state.json"
            state.write_text(json.dumps({
                "since": time.time() - 4 * 86400, "reason": "old window",
                "target_build": "old", "sessions": sessions("old", 50),
                "faults": {}, "previous_windows": [],
            }))
            (root / "diagnostics.1.jsonl").write_text(json.dumps({
                "timestamp": time.time() - 3600, "build": "old", "launch": "old",
                "session": "discarded", "event": "finish_returned", "elapsed_ms": 100,
            }))
            completed = subprocess.run(
                [sys.executable, str(SCRIPT), "--state", str(state), "--directory", str(root),
                 "--reset", "new candidate window", "--build", "candidate"],
                check=True, capture_output=True, text=True,
            )
            result = json.loads(completed.stdout)
            saved = json.loads(state.read_text())
            self.assertEqual(result["completed_dictations"], 0)
            self.assertFalse(result["passing"])
            self.assertEqual(saved["sessions"], {})
            self.assertEqual(saved["previous_windows"][0]["result"]["build"], "old")
            self.assertTrue(saved["previous_windows"][0]["result"]["passing"])

    def test_retained_rows_backfill_identity_in_a_legacy_ledger(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state.json"
            stamp = time.time() - 60
            state.write_text(json.dumps({
                "since": stamp - 60, "reason": "legacy",
                "sessions": {"launch:session": {"day": "2026-10-04",
                    "samples": 16000, "finish_ms": 100, "paste_outcome": "verified"}},
                "faults": {f"launch:{stamp}": "finish_timeout"}, "previous_windows": [],
            }))
            (root / "diagnostics.jsonl").write_text(json.dumps({
                "timestamp": stamp, "build": "candidate", "launch": "launch",
                "session": "session", "event": "finish_timeout",
            }))
            completed = subprocess.run(
                [sys.executable, str(SCRIPT), "--state", str(state), "--directory", str(root)],
                check=True, capture_output=True, text=True,
            )
            result = json.loads(completed.stdout)
            saved = json.loads(state.read_text())
            self.assertEqual(result["coverage"], "build_identified")
            self.assertEqual(result["missing_build_sessions"], 0)
            self.assertEqual(result["missing_build_faults"], 0)
            self.assertEqual(result["fault_count"], 1)
            self.assertEqual(saved["sessions"]["launch:session"]["build"], "candidate")

    def test_conflicting_identity_for_one_session_stays_incomplete(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state.json"
            stamp = time.time() - 60
            state.write_text(json.dumps({
                "since": stamp - 60, "reason": "conflict", "sessions": {},
                "faults": {}, "previous_windows": [],
            }))
            rows = [
                {"timestamp": stamp + index, "build": build, "launch": "launch",
                 "session": "session", "event": "finish_returned", "elapsed_ms": 100}
                for index, build in enumerate(["old", "candidate", "candidate"])
            ]
            (root / "diagnostics.jsonl").write_text("\n".join(json.dumps(row) for row in rows))
            completed = subprocess.run(
                [sys.executable, str(SCRIPT), "--state", str(state), "--directory", str(root)],
                check=True, capture_output=True, text=True,
            )
            result = json.loads(completed.stdout)
            self.assertEqual(result["coverage"], "missing_build_identity")
            self.assertEqual(result["missing_build_sessions"], 1)


if __name__ == "__main__":
    unittest.main()
