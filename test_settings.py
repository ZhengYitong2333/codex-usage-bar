from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import settings
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
