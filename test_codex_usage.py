import datetime as dt
import json
from pathlib import Path
import tempfile
import unittest

from codex_usage import collect, render, window_text, countdown, quota_windows, available_windows


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

    def test_expired_window_and_no_data(self):
        self.assertIsNone(window_text({'used_percent': 90, 'resets_at': 10}, 20)[1])
        with tempfile.TemporaryDirectory() as root:
            self.assertIn('暂无额度数据', render(collect(Path(root), 20)))

    def test_colors_and_staleness(self):
        data = {'refreshed_at': 1000, 'latest': {'timestamp': 999, 'limits': {'primary': {'used_percent': 96, 'resets_at': 9999}}}, 'today': dict.fromkeys(['total_tokens', 'input_tokens', 'cached_input_tokens', 'output_tokens'], 0), 'skipped_files': 0}
        self.assertIn('#E5484D', render(data).splitlines()[0])
        data['latest']['timestamp'] = 1
        self.assertIn('⏱', render(data).splitlines()[0])
        self.assertIn('#888888', render(data).splitlines()[0])

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
        output = render(data)
        self.assertIn('Codex 5h余 80%', output.splitlines()[0])
        self.assertIn('5小时额度  剩余 80%', output)
        self.assertIn('本周额度  剩余 51%', output)
        self.assertIn('Codex 周余 51%', render(data, {'window': 'secondary'}).splitlines()[0])

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
            output = render(collect(home, 1000))
            self.assertIn('5小时额度：未提供', output)
            self.assertIn('本周额度  剩余 51%', output)
            self.assertNotIn('20%', output)
            self.assertIn('Codex 周余 51%', output.splitlines()[0])

    def test_unknown_duration_is_not_mislabelled(self):
        self.assertEqual(quota_windows({'primary': {'window_minutes': 1440, 'used_percent': 10}}),
                         {'primary': None, 'secondary': None})
        windows = quota_windows({'primary': {'window_minutes': 10080, 'used_percent': 49},
                                 'secondary': {'used_percent': 20}})
        self.assertIsNone(windows['primary'])

    def test_both_sections_visible_without_data(self):
        with tempfile.TemporaryDirectory() as root:
            output = render(collect(Path(root), 1000))
        self.assertIn('5小时额度：未提供', output)
        self.assertIn('本周额度：未提供', output)

    def test_available_windows_and_menu_fallback(self):
        data = {'refreshed_at': 1000, 'latest': {'timestamp': 999, 'limits': {
            'primary': {'window_minutes': 10080, 'used_percent': 48, 'resets_at': 9999}}},
            'today': {'total_tokens': 0}, 'skipped_files': 0}
        self.assertEqual(available_windows(data), {'primary': False, 'secondary': True})
        output = render(data, {'window': 'primary'})
        self.assertIn('Codex 周余 52%', output.splitlines()[0])
        self.assertNotIn('Codex 待更新', output.splitlines()[0])
        self.assertEqual(available_windows({'refreshed_at': 1, 'latest': None}),
                         {'primary': False, 'secondary': False})


if __name__ == '__main__':
    unittest.main()
