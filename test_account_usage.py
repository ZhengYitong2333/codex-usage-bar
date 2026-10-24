import datetime as dt
import unittest
from pathlib import Path
from unittest.mock import patch

import codex_usage
import quota_api


class AccountUsageTests(unittest.TestCase):
    def test_daily_parser_discards_other_metadata(self):
        payload = {'summary': {'lifetimeTokens': 999}, 'threadUsage': [{'id': 'private'}],
                   'dailyUsageBuckets': [{'startDate': '2026-10-24', 'tokens': 100}]}
        with patch.object(quota_api, 'account_request', return_value=payload) as request:
            self.assertEqual(quota_api.query_usage(Path('.')), {'2026-10-24': 100})
        request.assert_called_once_with(Path('.'), 'account/usage/read', 12)

    def test_missing_or_invalid_data_does_not_become_zero(self):
        for payload in (None, {}, {'dailyUsageBuckets': []},
                        {'dailyUsageBuckets': [{'startDate': '2026-10-24', 'tokens': True}]},
                        {'dailyUsageBuckets': [{'startDate': '2026-10-24', 'tokens': -1}]}):
            with self.subTest(payload=payload), patch.object(quota_api, 'account_request', return_value=payload):
                with self.assertRaises(quota_api.QuotaQueryError):
                    quota_api.query_usage(Path('.'))

    def test_account_dates_and_pending_today_are_preserved(self):
        now = dt.datetime(2026, 10, 25, 2).timestamp()
        data = codex_usage.account_tokens({'2026-10-24': 123, '2026-10-23': 0}, now)
        self.assertIsNone(data['today']['total_tokens'])
        self.assertFalse(data['history'][-1]['available'])
        self.assertEqual(data['history'][-1]['text'], '—')
        self.assertEqual(data['history'][-2]['tokens'], 123)
        self.assertIsNone(data['history'][-2]['input_tokens'])
        self.assertTrue(data['history'][-3]['available'])
        self.assertEqual(data['history'][-3]['text'], '0')

    def test_account_totals_replace_local_estimates(self):
        base = {'latest': None, 'today': {'total_tokens': 1200}, 'skipped_files': 0, 'refreshed_at': 1000}
        with patch.object(codex_usage, 'collect', return_value=base), \
             patch.object(quota_api, 'query', side_effect=quota_api.QuotaQueryError('Fixture')), \
             patch.object(quota_api, 'query_usage', return_value={dt.date.today().isoformat(): 75}):
            model = codex_usage.ui_model(codex_usage.collect_usage(Path('.')))
        self.assertEqual(model['tokens']['raw'], 75)
        self.assertEqual(model['tokens_source'], '账户 API')
        self.assertIsNone(model['history'][-1]['input_tokens'])

    def test_usage_failure_explicitly_falls_back_to_local(self):
        base = {'latest': None, 'today': {'total_tokens': 1200}, 'skipped_files': 0, 'refreshed_at': 1000}
        with patch.object(codex_usage, 'collect', return_value=base), \
             patch.object(quota_api, 'query', side_effect=quota_api.QuotaQueryError('Fixture')), \
             patch.object(quota_api, 'query_usage', side_effect=quota_api.QuotaQueryError('Unsupported')):
            model = codex_usage.ui_model(codex_usage.collect_usage(Path('.')))
        self.assertEqual(model['tokens']['raw'], 1200)
        self.assertEqual(model['tokens_source'], '本机统计')
        self.assertIn('回退', model['tokens_note'])
