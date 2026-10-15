import importlib.util
import pathlib
import unittest


spec = importlib.util.spec_from_file_location('diagnostics', pathlib.Path(__file__).parents[1] / 'review_diagnostics.py')
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)


class PerformanceDiagnosticsTests(unittest.TestCase):
    def test_scheduling_gaps_do_not_count_as_ui_freezes(self):
        report = diagnostics.summarize([
            {'timestamp': '99', 'event': 'monitoring_gap', 'elapsed_ms': '60000', 'launch': 'a'},
        ], now=100, hours=2)
        self.assertEqual(report['monitoring_gaps'], 1)
        self.assertEqual(report['issues'], [])

    def test_permission_and_secure_input_state_are_separate_per_launch(self):
        report = diagnostics.summarize([
            {'timestamp': '90', 'event': 'interaction_state', 'launch': 'a', 'accessibility': 'false', 'app_active': 'false'},
            {'timestamp': '95', 'event': 'interaction_state', 'launch': 'b', 'accessibility': 'true', 'secure_input': 'true'},
            {'timestamp': '96', 'event': 'hotkey_transition', 'launch': 'b', 'event_source': 'global', 'elapsed_ms': '300'},
        ], now=100, hours=2)
        self.assertIn({'kind': 'global_hotkey_permission_missing', 'launch': 'a'}, report['issues'])
        self.assertIn({'kind': 'secure_keyboard_input_enabled', 'launch': 'b'}, report['issues'])
        self.assertIn({'kind': 'slow_hotkey_dispatch', 'count': 1, 'max_ms': 300}, report['issues'])

    def test_restored_permission_and_old_launch_do_not_raise_current_issue(self):
        report = diagnostics.summarize([
            {'timestamp': '100', 'event': 'interaction_state', 'launch': 'old', 'accessibility': 'false'},
            {'timestamp': '150', 'event': 'interaction_state', 'launch': 'current', 'accessibility': 'false'},
            {'timestamp': '290', 'event': 'interaction_state', 'launch': 'current', 'accessibility': 'true', 'secure_input': 'false'},
        ], now=300, hours=2)
        self.assertEqual(report['issues'], [])


if __name__ == '__main__':
    unittest.main()
