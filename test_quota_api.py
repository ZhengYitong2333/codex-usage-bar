import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import codex_usage
import quota_api


def response():
    return {'rateLimits': {'limitId': 'other', 'primary': {'usedPercent': 99}},
            'rateLimitsByLimitId': {'codex': {'limitId': 'codex',
                'primary': {'usedPercent': 18, 'windowDurationMins': 10080, 'resetsAt': 9999},
                'secondary': None}}, 'accountId': 'fictional-account'}


def local_data(latest=True):
    return {'latest': {'timestamp': 999, 'limits': quota_api.normalize(response())} if latest else None,
            'today': {'total_tokens': 1200}, 'skipped_files': 0, 'refreshed_at': 1000}


class QuotaTests(unittest.TestCase):
    def setUp(self):
        usage = patch.object(quota_api, 'query_usage', side_effect=quota_api.QuotaQueryError('Fixture'))
        self.usage_query = usage.start()
        self.addCleanup(usage.stop)

    def test_selects_codex_bucket_and_discards_account_metadata(self):
        snapshot = quota_api.normalize(response())
        self.assertEqual(snapshot['primary']['used_percent'], 18)
        self.assertNotIn('accountId', snapshot)
        windows = codex_usage.quota_windows(snapshot)
        self.assertIsNone(windows['primary'])
        self.assertEqual(windows['secondary']['window_minutes'], 10080)

    def test_legacy_response_and_zero_usage(self):
        value = quota_api.normalize({'rateLimits': {'primary': {
            'usedPercent': 0, 'windowDurationMins': 300, 'resetsAt': 9999}}})
        self.assertEqual(value['primary']['used_percent'], 0)

    def test_invalid_or_different_bucket_is_not_shown(self):
        values = [{}, None, {'rateLimits': {'limitId': 'different', 'primary': {'usedPercent': 1}}},
                  {'rateLimits': {'primary': {'usedPercent': True}}},
                  {'rateLimits': {'primary': {'usedPercent': float('nan')}}}]
        for value in values:
            with self.subTest(value=value), self.assertRaises(quota_api.QuotaQueryError):
                quota_api.normalize(value)

    def test_api_replaces_entire_log_snapshot(self):
        live = {'timestamp': 1000, 'limits': quota_api.normalize(response())}
        data = local_data()
        data['latest']['limits']['secondary'] = {'used_percent': 77, 'window_minutes': 300}
        with patch.object(codex_usage, 'collect', return_value=data), patch.object(quota_api, 'query', return_value=live):
            result = codex_usage.collect_usage(Path('.'))
        self.assertEqual(result['quota_source'], 'api')
        self.assertIs(result['latest'], live)
        model = codex_usage.ui_model(result)
        self.assertEqual(model['source'], 'Codex 查询接口')
        self.assertEqual(model['query_enabled'], True)
        windows = {w['label']: w for w in model['windows']}
        self.assertEqual(windows['5小时额度']['reason'], '接口未提供')
        self.assertNotIn('77%', json.dumps(model, ensure_ascii=False))

    def test_failure_labels_fallback_without_rejuvenating_log(self):
        base = local_data()
        stamp = base['latest']['timestamp']
        with patch.object(codex_usage, 'collect', return_value=base), patch.object(quota_api, 'query', side_effect=quota_api.QuotaQueryError('额度查询超时，稍后重试')):
            result = codex_usage.collect_usage(Path('.'))
        self.assertEqual(result['latest']['timestamp'], stamp)
        model = codex_usage.ui_model(result)
        self.assertEqual(model['source'], '本机日志')
        self.assertIn('额度查询超时，稍后重试', model['error'])
        self.assertTrue(model['stale'])

    def test_failure_without_log_has_no_fabricated_quota(self):
        with patch.object(codex_usage, 'collect', return_value=local_data(False)), patch.object(quota_api, 'query', side_effect=quota_api.QuotaQueryError('额度接口拒绝访问')):
            model = codex_usage.ui_model(codex_usage.collect_usage(Path('.')))
        self.assertIsNone(model['headline'])
        self.assertIn('额度查询失败，暂无可用记录', ' '.join(model['details']))
        self.assertEqual(model['error'], '额度接口拒绝访问')

    def test_local_only_never_calls_api(self):
        with patch.object(codex_usage, 'collect', return_value=local_data()), patch.object(quota_api, 'query') as query:
            result = codex_usage.collect_usage(Path('.'), local_only=True)
        query.assert_not_called()
        self.usage_query.assert_not_called()
        self.assertEqual(result['quota_source'], 'log')

    def test_rpc_handshake_notifications_and_cleanup(self):
        real_popen = subprocess.Popen
        processes = []
        fixture = '''import json, sys
for line in sys.stdin:
    message = json.loads(line)
    if message.get('id') == 1:
        print(json.dumps({'method': 'account/updated', 'params': {}}), flush=True)
        print(json.dumps({'id': 1, 'result': {}}), flush=True)
    elif message.get('method') == 'initialized':
        pass
    elif message.get('method') == 'account/rateLimits/read':
        print(json.dumps(PAYLOAD), flush=True)
    else:
        raise RuntimeError('Unexpected request')
'''.replace('PAYLOAD', repr({'id': 2, 'result': response()}))

        def start(command, **kwargs):
            process = real_popen([sys.executable, '-u', '-c', fixture], **kwargs)
            processes.append(process)
            return process

        with patch.object(quota_api, 'find_codex', return_value='fixture'), patch.object(quota_api.subprocess, 'Popen', side_effect=start):
            result = quota_api.query(Path('.'), timeout=3)
        self.assertEqual(result['limits'], quota_api.normalize(response()))
        self.assertTrue(all(process.poll() is not None for process in processes))

    def test_timeout_terminates_query_process(self):
        real_popen = subprocess.Popen
        processes = []

        def start(command, **kwargs):
            process = real_popen([sys.executable, '-c', 'import time; time.sleep(10)'], **kwargs)
            processes.append(process)
            return process

        with patch.object(quota_api, 'find_codex', return_value='fixture'), patch.object(quota_api.subprocess, 'Popen', side_effect=start):
            with self.assertRaisesRegex(quota_api.QuotaQueryError, '超时'):
                quota_api.query(Path('.'), timeout=0.1)
        self.assertTrue(all(process.poll() is not None for process in processes))

    def test_auth_failure_is_flagged_for_the_sign_in_prompt(self):
        base = local_data()
        with patch.object(codex_usage, 'collect', return_value=base), \
             patch.object(quota_api, 'query', side_effect=quota_api.AuthError('Codex 登录状态不可用，请在 Codex 中重新登录 ChatGPT 账号')):
            result = codex_usage.collect_usage(Path('.'))
        model = codex_usage.ui_model(result)
        self.assertTrue(model['auth_required'])
        self.assertIn('登录状态', model['error'])


if __name__ == '__main__':
    unittest.main()
