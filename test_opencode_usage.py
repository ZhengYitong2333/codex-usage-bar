import json
import sqlite3
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

import opencode_usage


class OpenCodeUsageTests(unittest.TestCase):
    def test_normalize_go_budget_and_activity(self):
        stats = {
            'sessions': 12, 'activeDays': 5, 'streak': 3,
            'tokens': {'input': 1_500_000, 'output': 250_000, 'reasoning': 0,
                       'cache': {'read': 100_000, 'write': 0}},
            'cost': 12.34,
            'activity': [{'date': '10-24', 'steps': 10}, {'date': '10-25', 'steps': 40}],
        }
        limits = {
            'workspace': {'name': 'Team', 'usageURL': 'https://opencode.ai/console/x/activity'},
            'go': {
                'rolling': {'percent': 40, 'limited': False, 'resetsAt': 1_800_003_600_000},
                'weekly': {'percent': 80, 'limited': False, 'resetsAt': 1_800_007_200_000},
                'monthly': {'percent': 100, 'limited': True, 'resetsAt': 1_800_010_800_000},
            },
            'budgets': [{'limit': 100, 'spent': 25, 'resetsAt': 1_800_014_400_000}],
        }
        model = opencode_usage.normalize(stats, limits, 7, 'remaining', now=1_800_000_000)
        self.assertTrue(model['available'])
        self.assertEqual(model['workspace'], 'Team')
        self.assertEqual(model['stats']['total'], 1_850_000)
        self.assertTrue(model['stats']['total_text'].endswith('M'))
        self.assertEqual(model['stats']['input_text'], '1.5M')
        self.assertEqual(model['stats']['cost'], 12.34)
        self.assertEqual([m['label'] for m in model['go_meters']],
                         ['滚动额度', '每周额度', '每月额度'])
        self.assertEqual(model['go_meters'][0]['remaining'], 60)
        self.assertTrue(model['go_meters'][2]['limited'])
        self.assertEqual(model['go_meters'][0]['reset_text'], '1小时0分后重置')
        self.assertEqual(model['budgets'][0]['remaining'], 75)
        self.assertEqual(model['stats']['activity'][1]['level'], 4)
        used = opencode_usage.normalize(stats, limits, 7, 'used', now=1_800_000_000)
        self.assertEqual(used['go_meters'][0]['amount'], 40)

    def test_missing_go_and_bad_values(self):
        model = opencode_usage.normalize(
            {'tokens': {'input': 10}}, {'go': {'rolling': {'percent': 'x'}}, 'budgets': [{'limit': 0}]},
            7, 'remaining', now=1_000)
        self.assertIsNone(model['go'])
        self.assertEqual(model['go_meters'], [])
        self.assertEqual(model['budgets'], [])
        self.assertEqual(model['stats']['total'], 10)

    def test_empty_reason(self):
        model = opencode_usage.empty('未找到 OpenCode CLI')
        self.assertFalse(model['available'])
        self.assertEqual(model['reason'], '未找到 OpenCode CLI')


class ConsoleFallbackTests(unittest.TestCase):
    def test_console_go_payload_becomes_meters(self):
        payload = {'workspace': {'id': 'org-1', 'name': 'Team', 'usageURL': 'https://opencode.ai/console/org-1/activity/overview'},
                   'go': {'rolling': {'percent': 30, 'status': 'ok', 'resetsAt': 1_800_003_600_000},
                          'weekly': {'percent': 55, 'status': 'rate-limited', 'resetsAt': 1_800_007_200_000},
                          'monthly': {'percent': 10, 'status': 'ok', 'resetsAt': 1_800_010_800_000}},
                   'budgets': []}
        model = opencode_usage.normalize({'tokens': {'input': 1}}, payload, 7, 'remaining', now=1_800_000_000)
        self.assertEqual([m['label'] for m in model['go_meters']],
                         ['滚动额度', '每周额度', '每月额度'])
        self.assertTrue(model['go_meters'][1]['limited'])
        self.assertEqual(model['go_meters'][0]['remaining'], 70)
        self.assertEqual(model['workspace'], 'Team')

    def test_console_server_rewrites_retired_host(self):
        self.assertEqual(opencode_usage.console_server({'server': 'https://console.opencode.ai'}),
                         'https://opencode.ai')
        self.assertEqual(opencode_usage.console_server({}), 'https://opencode.ai/console')


class ConsoleBudgetTests(unittest.TestCase):
    def test_console_budget_dollar_fields(self):
        limits = {'budgets': [{'limitDollars': 50, 'spentDollars': 12.5,
                               'resetsAt': '2026-10-31T11:39:00.000Z'}]}
        model = opencode_usage.normalize({'tokens': {}}, limits, 7, 'remaining', now=1_800_000_000)
        self.assertEqual(len(model['budgets']), 1)
        self.assertEqual(model['budgets'][0]['limit'], 50)
        self.assertEqual(model['budgets'][0]['remaining'], 37.5)
        self.assertIsNotNone(model['budgets'][0]['resets_at'])


class OpenCodeLoginTests(unittest.TestCase):
    def test_go_key_in_database_is_recognized(self):
        with tempfile.TemporaryDirectory() as folder:
            database = Path(folder) / 'opencode' / 'opencode.db'
            database.parent.mkdir()
            with sqlite3.connect(database) as connection:
                connection.execute('create table credential (integration_id text, value text, active integer)')
                connection.executemany('insert into credential values (?, ?, ?)', [
                    ('opencode-go', json.dumps({'type': 'key', 'key': 'inactive-key'}), 0),
                    ('opencode-go', json.dumps({'type': 'key', 'key': 'go-key'}), 1),
                    ('opencode', json.dumps({'type': 'oauth', 'access': 'console-token',
                                            'metadata': {'orgID': 'org-1'}}), 1),
                ])
            with patch.dict('os.environ', {'XDG_DATA_HOME': folder}):
                self.assertEqual(opencode_usage.console_credential('opencode-go')['token'], 'go-key')
                self.assertEqual(opencode_usage.console_credential()['token'], 'console-token')
                self.assertEqual(opencode_usage.console_credential()['org_id'], 'org-1')

    def test_go_key_queries_usage_without_console_budgets(self):
        credential = {'token': 'go-key'}
        usage = {'rolling': {'percent': 25}}
        with patch.object(opencode_usage, 'console_credential',
                          side_effect=lambda integration='opencode': credential if integration == 'opencode-go' else None), \
             patch.object(opencode_usage, 'console_request', return_value={'usage': usage}) as request:
            payload, status = opencode_usage.console_limits()
        self.assertEqual(status, 'ok')
        self.assertEqual(payload['go'], usage)
        self.assertEqual(payload['budgets'], [])
        request.assert_called_once_with('https://opencode.ai/zen/go/v1/usage', credential, 8,
                                        org_header='x-opencode-org-id')

    def test_go_and_console_use_separate_credentials(self):
        console = {'token': 'console-token', 'org_id': 'org-1'}
        go = {'token': 'go-key'}
        with patch.object(opencode_usage, 'console_credential',
                          side_effect=lambda integration='opencode': go if integration == 'opencode-go' else console), \
             patch.object(opencode_usage, 'console_request',
                          side_effect=[{'usage': {'rolling': {'percent': 25}}}, []]) as request:
            _, status = opencode_usage.console_limits()
        self.assertEqual(status, 'ok')
        self.assertEqual(request.call_args_list[0].args[1], go)
        self.assertEqual(request.call_args_list[1].args[1], console)

    def test_no_credentials_is_signed_out(self):
        with patch.object(opencode_usage, 'console_credential', return_value=None), \
             patch.object(opencode_usage, 'console_request') as request:
            self.assertEqual(opencode_usage.console_limits(), (None, 'signed_out'))
        request.assert_not_called()

    def test_credentials_without_usage_are_not_signed_out(self):
        with patch.object(opencode_usage, 'console_credential', return_value={'token': 'test'}), \
             patch.object(opencode_usage, 'console_request', return_value={}):
            self.assertEqual(opencode_usage.console_limits(), (None, 'unavailable'))

    def test_console_request_identifies_app_and_keeps_credentials_in_headers(self):
        with patch.object(opencode_usage.urllib.request, 'urlopen') as urlopen:
            response = urlopen.return_value.__enter__.return_value
            response.read.return_value = b'{"usage": {}}'
            opencode_usage.console_request('https://opencode.ai/zen/go/v1/usage',
                                           {'token': 'test-key'})
        request = urlopen.call_args.args[0]
        self.assertEqual(request.get_header('User-agent'), 'CodexUsageBar/1.0')
        self.assertEqual(request.get_header('Authorization'), 'Bearer test-key')
        self.assertNotIn('test-key', request.full_url)

    def test_http_errors_are_not_reported_as_missing_login(self):
        for code in (401, 403, 503):
            with self.subTest(code=code), \
                 patch.object(opencode_usage.urllib.request, 'urlopen',
                              side_effect=urllib.error.HTTPError('https://opencode.ai', code, '', {}, None)):
                with self.assertRaises(opencode_usage.OpenCodeError):
                    opencode_usage.console_request('https://opencode.ai/zen/go/v1/usage', {'token': 'test'})

    def test_local_signed_out_can_fall_back_to_go_key(self):
        limits = {'go': {'rolling': {'percent': 25}}}
        with patch.object(opencode_usage, 'find_opencode', return_value='/test/opencode'), \
             patch.object(opencode_usage, 'read_stats', return_value={}), \
             patch.object(opencode_usage, 'usage_limits', return_value=(None, 'signed_out')), \
             patch.object(opencode_usage, 'console_limits', return_value=(limits, 'ok')):
            result = opencode_usage.query()
        self.assertEqual(result['limits_status'], 'ok')
        self.assertEqual(result['go_meters'][0]['remaining'], 75)

    def test_console_error_survives_query_fallback(self):
        with patch.object(opencode_usage, 'find_opencode', return_value='/test/opencode'), \
             patch.object(opencode_usage, 'read_stats', return_value={}), \
             patch.object(opencode_usage, 'usage_limits', return_value=(None, 'unsupported')), \
             patch.object(opencode_usage, 'console_limits',
                          side_effect=opencode_usage.OpenCodeError('HTTP 403')):
            result = opencode_usage.query()
        self.assertEqual(result['limits_status'], 'unavailable')
        self.assertEqual(result['error'], 'HTTP 403')


if __name__ == '__main__':
    unittest.main()
