from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import settings
from codex_usage import render


class SettingsTests(unittest.TestCase):
    def test_invalid_values(self):
        for raw in ({'refresh_minutes': 0}, {'refresh_minutes': 1.0}, {'refresh_minutes': True},
                    {'window': 'daily'}, {'show_tokens': 'false'}, {'value_size': 100},
                    {'low_quota_threshold': 90}, {'low_quota_warning': 1}, {'stale_minutes': 0}):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                settings.validate(raw)

    def test_interval_migration_and_persistence(self):
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root)
            config, plugins, template = folder / 'settings.json', folder / 'plugins', folder / 'template'
            template.write_text('#!/bin/bash\nexec python3 "$HOME/Library/Application Support/CodexUsage/codex_usage.py"\n')
            settings.apply({}, config, plugins, template)
            unrelated = plugins / 'other.5m.sh'
            unrelated.write_text('unrelated')
            settings.apply({'refresh_minutes': 1, 'display': 'used'}, config, plugins, template)
            self.assertFalse((plugins / 'codex-usage.5m.sh').exists())
            self.assertEqual((plugins / 'codex-usage.1m.sh').read_text(), template.read_text())
            self.assertTrue((plugins / 'codex-usage.1m.sh').stat().st_mode & 0o111)
            self.assertEqual(settings.read(config)['refresh_minutes'], 1)
            self.assertEqual(settings.read(config)['display'], 'used')
            self.assertEqual(unrelated.read_text(), 'unrelated')
            collision = plugins / 'codex-usage.2m.sh'
            collision.write_text('another plugin')
            with self.assertRaises(ValueError):
                settings.apply({'refresh_minutes': 2}, config, plugins, template)
            self.assertEqual(settings.read(config)['refresh_minutes'], 1)
            self.assertEqual(collision.read_text(), 'another plugin')

    def test_failed_wrapper_write_restores_config(self):
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root)
            config, plugins, template = folder / 'settings.json', folder / 'plugins', folder / 'template'
            template.write_text('CodexUsage/codex_usage.py')
            settings.apply({}, config, plugins, template)
            original = settings.atomic_write
            def fail_wrapper(path, *args):
                if path.parent == plugins:
                    raise OSError('test: read-only plugin directory')
                original(path, *args)
            with patch.object(settings, 'atomic_write', side_effect=fail_wrapper), self.assertRaises(OSError):
                settings.apply({'refresh_minutes': 1}, config, plugins, template)
            self.assertEqual(settings.read(config)['refresh_minutes'], 5)
            self.assertTrue((plugins / 'codex-usage.5m.sh').exists())

    def test_display_options_and_settings_action(self):
        data = {'refreshed_at': 1000, 'latest': {'timestamp': 999, 'limits': {
            'primary': {'used_percent': 20, 'resets_at': 9999},
            'secondary': {'used_percent': 70, 'resets_at': 9999}}},
            'today': {'total_tokens': 123}, 'skipped_files': 0}
        output = render(data, {'window': 'secondary', 'display': 'used',
                              'show_tokens': False, 'show_countdown': False, 'refresh_minutes': 2})
        self.assertIn('Codex 周用 70%', output.splitlines()[0])
        self.assertNotIn('今日 tokens', output)
        self.assertNotIn('倒计时', output)
        self.assertIn('param1=settings', output)
        self.assertIn('每 2 分钟扫描本机日志', output)
        self.assertIn('Codex 5h余 80%', render(data).splitlines()[0])

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
        output = render(data, config)
        self.assertIn('⚠ 5 小时、每周剩余额度 ≤ 20%', output)
        self.assertNotIn('⏱', output)
        self.assertNotIn('⚠', render(data, {'low_quota_warning': False}))
        config['stale_minutes'] = 15
        output = render(data, config)
        self.assertNotIn('⚠', output)
        self.assertIn('⏱', output)
        self.assertIn('额度记录：', output)
        self.assertIn('本机扫描：', output)
        data['latest']['timestamp'] = 1999
        data['latest']['limits']['secondary']['resets_at'] = 1998
        config['low_quota_threshold'] = 10
        self.assertNotIn('⚠', render(data, config))


if __name__ == '__main__':
    unittest.main()
