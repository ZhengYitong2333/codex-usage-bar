import datetime as dt
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import codex_usage
from codex_usage import collect, summary, window_text, countdown, quota_windows, available_windows, ui_model


class UsageTests(unittest.TestCase):
    def test_counters_midnight_duplicates_and_other_limit(self):
        now = dt.datetime.now().replace(hour=12, minute=0, second=0, microsecond=0)
        midnight = now.replace(hour=0).timestamp()
        def event(when, total, last, limits=None):
            return json.dumps({'timestamp': dt.datetime.fromtimestamp(when, dt.timezone.utc).isoformat(), 'type': 'event_msg', 'payload': {'type': 'token_count', 'info': {'total_token_usage': {'total_tokens': total}, 'last_token_usage': {'total_tokens': last}}, 'rate_limits': limits}})
        limits = {'limit_id': 'codex', 'primary': {'used_percent': 82, 'window_minutes': 300, 'resets_at': now.timestamp() + 3600}}
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            (home / 'sessions').mkdir()
            (home / 'archived_sessions').mkdir()
            content = '\n'.join([event(midnight - 1, 100, 100), event(midnight + 1, 150, 50, limits), event(midnight + 2, 150, 50), event(midnight + 3, 170, 20, {'limit_id': 'premium', 'primary': {'used_percent': 90}}), '{partial'])
            (home / 'sessions/a.jsonl').write_text(content)
            (home / 'archived_sessions/a.jsonl').write_text(content)
            # A fork starts with inherited counters: count only new work.
            (home / 'sessions/b.jsonl').write_text(event(midnight + 4, 1000, 5))
            data = collect(home, now.timestamp())
            self.assertEqual(data['today']['total_tokens'], 75)
            self.assertEqual(data['latest']['limits']['primary']['used_percent'], 82)
            self.assertEqual(len(data['history']), 7)
            self.assertEqual(data['history'][-1]['tokens'], 75)
            self.assertEqual(data['history'][-1]['text'], '75')
            self.assertIn('input_tokens', data['history'][-1])
            self.assertIn('output_tokens', data['history'][-1])

    def test_expired_window_and_no_data(self):
        self.assertIsNone(window_text({'used_percent': 90, 'resets_at': 10}, 20)[1])
        with tempfile.TemporaryDirectory() as root:
            model = ui_model(collect(Path(root), 20))
        self.assertIsNone(model['headline'])
        self.assertIn('尚未找到额度记录', model['details'])

    def test_staleness_marks_the_snapshot(self):
        data = {'refreshed_at': 1000, 'latest': {'timestamp': 999, 'limits': {'primary': {'used_percent': 96, 'resets_at': 9999}}}, 'today': dict.fromkeys(['total_tokens', 'input_tokens', 'cached_input_tokens', 'output_tokens'], 0), 'skipped_files': 0}
        self.assertFalse(ui_model(data)['stale'])
        data['latest']['timestamp'] = 1
        self.assertTrue(ui_model(data)['stale'])
        self.assertIn('⏱', ui_model(data)['title'])

    def test_terminal_summary_reports_windows(self):
        data = {'refreshed_at': 1000, 'latest': {'timestamp': 999, 'limits': {
            'primary': {'window_minutes': 10080, 'used_percent': 19, 'resets_at': 9999}}},
            'today': {'total_tokens': 1234}, 'skipped_files': 0, 'quota_source': 'api'}
        text = summary(data)
        self.assertIn('Codex 周余 81%', text)
        self.assertIn('本周额度', text)
        self.assertIn('5小时额度', text)
        self.assertIn('Codex 查询接口', text)

    def test_reset_countdown(self):
        self.assertEqual(countdown(90061, 0), '1天1小时')
        self.assertEqual(countdown(3661, 0), '1小时1分')
        self.assertEqual(countdown(0, 1), '已到期，等待新记录')

    def test_swapped_slots_identified_by_duration(self):
        weekly = {'window_minutes': 10080, 'used_percent': 49, 'resets_at': 9999}
        five_hour = {'window_minutes': 300, 'used_percent': 20, 'resets_at': 9999}
        limits = {'primary': weekly, 'secondary': five_hour}
        self.assertEqual(quota_windows(limits), {'primary': five_hour, 'secondary': weekly})
        data = {'refreshed_at': 1000, 'latest': {'timestamp': 999, 'limits': limits},
                'today': {'total_tokens': 0}, 'skipped_files': 0}
        model = ui_model(data)
        self.assertEqual(model['title'], 'Codex 5h余 80%')
        self.assertEqual(model['headline']['label'], '5小时额度')
        self.assertEqual(model['headline']['amount'], 80)
        self.assertEqual(model['windows'][1]['label'], '本周额度')
        self.assertEqual(model['windows'][1]['amount'], 51)
        self.assertEqual(ui_model(data, {'window': 'secondary'})['title'], 'Codex 周余 51%')

    def test_weekly_only_snapshot_does_not_reuse_older_five_hour_quota(self):
        def event(when, limits):
            return json.dumps({'timestamp': dt.datetime.fromtimestamp(when, dt.timezone.utc).isoformat(),
                               'type': 'event_msg', 'payload': {'type': 'token_count', 'rate_limits': limits}})
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            (home / 'sessions').mkdir()
            (home / 'sessions/a.jsonl').write_text('\n'.join([
                event(998, {'primary': {'window_minutes': 300, 'used_percent': 20, 'resets_at': 9999}}),
                event(999, {'primary': {'window_minutes': 10080, 'used_percent': 49, 'resets_at': 9999}, 'secondary': None})]))
            model = ui_model(collect(home, 1000))
            windows = {w['label']: w for w in model['windows']}
            self.assertEqual(windows['5小时额度']['status'], '未提供')
            self.assertEqual(windows['本周额度']['amount'], 51)
            self.assertNotIn('20%', json.dumps(model, ensure_ascii=False))
            self.assertEqual(model['title'], 'Codex 周余 51%')

    def test_unknown_duration_is_not_mislabelled(self):
        self.assertEqual(quota_windows({'primary': {'window_minutes': 1440, 'used_percent': 10}}),
                         {'primary': None, 'secondary': None})
        windows = quota_windows({'primary': {'window_minutes': 10080, 'used_percent': 49},
                                 'secondary': {'used_percent': 20}})
        self.assertIsNone(windows['primary'])

    def test_both_sections_visible_without_data(self):
        with tempfile.TemporaryDirectory() as root:
            model = ui_model(collect(Path(root), 1000))
        self.assertEqual(model['windows'], [])
        self.assertIsNone(model['headline'])
        self.assertIn('尚未找到额度记录', model['details'])

    def test_available_windows_and_menu_fallback(self):
        data = {'refreshed_at': 1000, 'latest': {'timestamp': 999, 'limits': {
            'primary': {'window_minutes': 10080, 'used_percent': 48, 'resets_at': 9999}}},
            'today': {'total_tokens': 0}, 'skipped_files': 0}
        self.assertEqual(available_windows(data), {'primary': False, 'secondary': True})
        model = ui_model(data, {'window': 'primary'})
        self.assertEqual(model['title'], 'Codex 周余 52%')
        self.assertEqual(model['displayed_key'], 'secondary')
        self.assertNotIn('Codex 待更新', model['title'])
        self.assertEqual(available_windows({'refreshed_at': 1, 'latest': None}),
                         {'primary': False, 'secondary': False})

    def test_auth_required_is_reported_to_the_app(self):
        data = {'refreshed_at': 1000, 'latest': None, 'today': {'total_tokens': 0},
                'skipped_files': 0, 'quota_error': 'Codex 登录状态不可用，请在 Codex 中重新登录 ChatGPT 账号',
                'auth_required': True}
        model = ui_model(data)
        self.assertTrue(model['auth_required'])
        self.assertIsNone(model['headline'])
        self.assertFalse(ui_model({'refreshed_at': 1, 'latest': None, 'today': {'total_tokens': 0},
                                   'skipped_files': 0})['auth_required'])


    def test_account_tokens_name_the_day_they_belong_to(self):
        data = {'refreshed_at': 1000, 'latest': None, 'today': {'total_tokens': 13584975},
                'skipped_files': 0, 'tokens_source': '账户 API',
                'tokens_note': '账户 token 活动口径'}
        model = ui_model(data)
        self.assertEqual(model['tokens']['text'], '13.6M')
        self.assertIsNone(model['tokens']['label'])
        data['today'] = {'total_tokens': None}
        data['last_synced'] = {'date': '10-24', 'tokens': 13584975}
        model = ui_model(data)
        self.assertEqual(model['tokens']['label'], '10-24')
        self.assertEqual(model['tokens']['text'], '13.6M')

    def test_account_api_skips_the_full_local_scan(self):
        calls = {}
        def fake_collect(home, now, tail_only=False):
            calls['tail_only'] = tail_only
            return {'latest': None, 'today': {'total_tokens': 0}, 'history': [], 'skipped_files': 0}
        with patch.object(codex_usage, 'collect', side_effect=fake_collect), \
             patch.object(codex_usage.quota_api, 'query', return_value={'timestamp': 1, 'limits': {}}), \
             patch.object(codex_usage.quota_api, 'query_usage',
                          return_value={dt.datetime.now().strftime('%Y-%m-%d'): 100}):
            data = codex_usage.collect_usage(Path('.'))
        self.assertTrue(calls['tail_only'])
        self.assertEqual(data['tokens_source'], '账户 API')
        self.assertEqual(data['history'][-1]['tokens'], 100)


if __name__ == '__main__':
    unittest.main()
