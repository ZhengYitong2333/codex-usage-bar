from pathlib import Path
import json
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import settings
import metrics
from codex_usage import ui_model


class SettingsTests(unittest.TestCase):
    def test_invalid_values(self):
        for raw in ({'refresh_minutes': 0}, {'refresh_minutes': 1.0}, {'refresh_minutes': True},
                    {'window': 'daily'}, {'show_tokens': 'false'}, {'value_size': 100},
                    {'low_quota_threshold': 90}, {'low_quota_warning': 1}, {'stale_minutes': 0}):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                settings.validate(raw)

    def test_display_options_and_settings_action(self):
        data = {'refreshed_at': 1000, 'latest': {'timestamp': 999, 'limits': {
            'primary': {'used_percent': 20, 'resets_at': 9999},
            'secondary': {'used_percent': 70, 'resets_at': 9999}}},
            'today': {'total_tokens': 123}, 'skipped_files': 0}
        model = ui_model(data, {'window': 'secondary', 'display': 'used',
                                'show_tokens': False, 'show_countdown': False, 'refresh_minutes': 2})
        self.assertEqual(model['title'], 'Codex 周用 70%')
        self.assertIsNone(model['tokens'])
        self.assertNotIn('倒计时', ' '.join(model['details']))
        self.assertIn('每 2 分钟扫描本机日志', model['details'])
        self.assertEqual(ui_model(data)['title'], 'Codex 5h余 80%')

    def test_corrupt_settings_fallback(self):
        with tempfile.TemporaryDirectory() as root:
            config = Path(root) / 'settings.json'
            config.write_text('{partial')
            self.assertEqual(settings.read(config), settings.DEFAULTS)

    def test_old_settings_gain_new_defaults_without_losing_choices(self):
        with tempfile.TemporaryDirectory() as root:
            config = Path(root) / 'settings.json'
            config.write_text('{"refresh_minutes": 1, "weight": "medium", "show_tokens": false}')
            saved = settings.read(config)
            self.assertEqual(saved['refresh_minutes'], 1)
            self.assertEqual(saved['weight'], 'medium')
            self.assertFalse(saved['show_tokens'])
            self.assertFalse(saved['low_quota_warning'])
            self.assertEqual(saved['stale_minutes'], 15)

    def test_warning_threshold_and_stale_suppression(self):
        data = {'refreshed_at': 2000, 'latest': {'timestamp': 1000, 'limits': {
            'primary': {'window_minutes': 300, 'used_percent': 80, 'resets_at': 9999},
            'secondary': {'window_minutes': 10080, 'used_percent': 95, 'resets_at': 9999}}},
            'today': {'total_tokens': 0}, 'skipped_files': 0}
        config = {'low_quota_warning': True, 'stale_minutes': 30}
        model = ui_model(data, config)
        self.assertEqual(model['low_quota'], ['5 小时', '每周'])
        self.assertFalse(model['stale'])
        self.assertEqual(ui_model(data, {'low_quota_warning': False})['low_quota'], [])
        config['stale_minutes'] = 15
        model = ui_model(data, config)
        self.assertEqual(model['low_quota'], [])
        self.assertTrue(model['stale'])
        self.assertIn('⏱', model['title'])
        self.assertIn('额度来源：', ' '.join(model['details']))
        self.assertTrue(model['updated'])
        data['latest']['timestamp'] = 1999
        data['latest']['limits']['secondary']['resets_at'] = 1998
        config['low_quota_threshold'] = 10
        self.assertEqual(ui_model(data, config)['low_quota'], [])

    def test_menu_bar_selection_round_trip_and_old_defaults(self):
        self.assertEqual(settings.validate({})['menu_bar_items'], [dict(provider='codex', meter='auto')])
        chosen = ['codex_primary', 'codex_secondary', 'opencode_rolling', 'opencode_weekly', 'opencode_monthly']
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder) / 'settings.json'
            settings.save({'menu_bar_items': chosen, 'show_codex': False}, config)
            self.assertEqual(settings.read(config)['menu_bar_items'], metrics.selection(chosen))
            self.assertFalse(settings.read(config)['show_codex'])
        saved = settings.validate({'menu_bar_items': chosen})
        saved['menu_bar_items'].clear()
        self.assertEqual(len(chosen), 5)
        self.assertEqual(settings.DEFAULTS['menu_bar_items'], [dict(provider='codex', meter='auto')])

    def test_menu_bar_rejects_empty_unknown_duplicate_and_bad_types(self):
        for items in ([], '', None, ['other'], ['codex', 'codex'], [1], [{}]):
            with self.subTest(items=items), self.assertRaises(ValueError):
                settings.validate({'menu_bar_items': items})

    def test_cross_field_rules_apply_outside_the_settings_window(self):
        for raw in ({'show_codex': False, 'show_opencode': False},
                    {'menu_bar_items': ['codex', 'codex_primary']},
                    {'menu_bar_items': ['codex_secondary', 'codex']}):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                settings.validate(raw)

    def test_save_patch_preserves_unknown_and_concurrently_changed_fields(self):
        with tempfile.TemporaryDirectory() as root:
            config = Path(root) / 'settings.json'
            config.write_text(json.dumps({'future_setting': {'values': [1, '保留']},
                                          'display': 'used', 'refresh_minutes': 30}))
            saved = settings.save({'value_size': 14}, config)
            self.assertEqual(saved['future_setting'], {'values': [1, '保留']})
            self.assertEqual(saved['display'], 'used')
            self.assertEqual(saved['refresh_minutes'], 30)
            self.assertEqual(saved['value_size'], 14)
            self.assertEqual(settings.read(config), saved)

    def test_future_metrics_do_not_reset_other_settings_and_survive_edits(self):
        with tempfile.TemporaryDirectory() as root:
            config = Path(root) / 'settings.json'
            config.write_text(json.dumps({'display': 'used', 'menu_bar_items': ['codex', 'future_metric']}))
            self.assertEqual(settings.read(config)['display'], 'used')
            saved = settings.save({'value_size': 14}, config)
            self.assertEqual(saved['menu_bar_items'], metrics.selection(['codex', 'future_metric'], allow_unknown=True))
            saved = settings.save({'menu_bar_items': ['opencode_weekly']}, config)
            self.assertEqual(saved['menu_bar_items'], metrics.selection(['opencode_weekly', 'future_metric'], allow_unknown=True))
            with self.assertRaises(ValueError):
                settings.save({'menu_bar_items': ['another_unknown']}, config)

    def test_save_does_not_overwrite_an_unreadable_settings_document(self):
        with tempfile.TemporaryDirectory() as root:
            config = Path(root) / 'settings.json'
            for content in ('{broken', '[]'):
                config.write_text(content)
                with self.subTest(content=content), self.assertRaises(ValueError):
                    settings.save({'display': 'used'}, config)
                self.assertEqual(config.read_text(), content)

    def test_cli_defaults_match_the_settings_authority(self):
        output = subprocess.check_output(['python3', str(Path(__file__).with_name('codex_usage.py')),
                                          '--get-settings', '--defaults'])
        self.assertEqual(json.loads(output), settings.DEFAULTS)


if __name__ == '__main__':
    unittest.main()


class ProviderSettingsTests(unittest.TestCase):
    def test_provider_cards_can_be_hidden(self):
        with tempfile.TemporaryDirectory() as root:
            config = Path(root) / 'settings.json'
            settings.save({'show_codex': False, 'show_opencode': True}, config)
            saved = settings.read(config)
            self.assertFalse(saved['show_codex'])
            self.assertTrue(saved['show_opencode'])

    def test_opencode_days_must_be_an_integer(self):
        with self.assertRaises(ValueError):
            settings.validate({'opencode_days': 7.0})
        self.assertEqual(settings.validate({'opencode_days': 30})['opencode_days'], 30)
