import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import metrics
import settings
from codex_usage import ui_model, opencode_model


class MetricTests(unittest.TestCase):
    def test_legacy_and_object_selections_share_validation(self):
        objects = metrics.selection(['codex_primary', 'opencode_rolling'])
        self.assertEqual(objects, [{'provider': 'codex', 'meter': 'primary'}, {'provider': 'opencode', 'meter': 'rolling'}])
        self.assertEqual(settings.validate({'menu_bar_items': objects})['menu_bar_items'], objects)
        for items in ([objects[0], 'codex_primary'], [{'provider': 'codex', 'meter': ''}],
                      [{'provider': 1, 'meter': 'auto'}], [dict(provider='codex', meter='auto'), 'codex_secondary']):
            with self.subTest(items=items), self.assertRaises(ValueError):
                settings.validate({'menu_bar_items': items})

    def test_object_migration_preserves_unknown_fields_and_metrics(self):
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder) / 'settings.json'
            unknown = dict(provider='third', meter='daily')
            config.write_text(json.dumps({'menu_bar_items': ['codex', unknown], 'future': {'keep': True}}))
            result = settings.save({'value_size': 14}, config)
            self.assertEqual(result['menu_bar_items'], [dict(provider='codex', meter='auto'), unknown])
            self.assertEqual(result['future'], {'keep': True})
            result = settings.save({'menu_bar_items': [dict(provider='opencode', meter='monthly')]}, config)
            self.assertEqual(result['menu_bar_items'][-1], unknown)

    def test_metric_payload_uses_provider_display_and_quota_timestamp(self):
        data = {'refreshed_at': 2000, 'latest': {'timestamp': 1900, 'limits': {
            'secondary': {'used_percent': 30, 'resets_at': 9999}}},
            'today': {'total_tokens': 0}, 'skipped_files': 0}
        model = ui_model(data, {'display': 'used'})
        readings = {m['meter']: m for m in model['metrics']}
        self.assertEqual(readings['auto']['used'], 30)
        self.assertEqual(readings['secondary']['used'], 30)
        self.assertIsNone(readings['primary']['used'])
        self.assertEqual(readings['auto']['updated'], 1900)
        self.assertEqual(readings['auto']['display'], 'used')
        self.assertIn(metrics.WEEKLY, readings['auto']['label'])

    def test_failed_opencode_query_still_returns_all_metric_definitions(self):
        with patch('opencode_usage.query', side_effect=__import__('opencode_usage').OpenCodeError('查询失败')):
            result = opencode_model(settings.validate({}))
        self.assertEqual(len(result['metrics']), 3)
        self.assertTrue(all(m['used'] is None for m in result['metrics']))

    def test_catalog_and_settings_envelope_are_offline_and_validated(self):
        root = Path(__file__).parent
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder) / 'Library/Application Support/CodexUsage/settings.json'
            config.parent.mkdir(parents=True)
            config.write_text(json.dumps({'refresh_minutes': 999, 'display': 'used'}))
            env = {**os.environ, 'HOME': folder}
            data = subprocess.check_output(['python3', str(root / 'codex_usage.py'), '--get-settings', '--catalog'], env=env)
            result = json.loads(data)
            self.assertEqual(result['settings']['refresh_minutes'], 5)
            self.assertEqual(len(result['metrics']), len(metrics.CATALOG))
            data = subprocess.check_output(['python3', str(root / 'codex_usage.py'), '--metrics', '--catalog'], env=env)
            self.assertEqual(len(json.loads(data)), len(metrics.CATALOG))
