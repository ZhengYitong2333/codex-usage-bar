#!/usr/bin/python3
"""Query Codex quotas; estimate daily tokens from local usage events."""
import argparse
import datetime as dt
import json
import math
import os
import subprocess
import sys
from pathlib import Path
import quota_api
import settings as preferences


def timestamp(value):
    try:
        return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (AttributeError, TypeError, ValueError):
        return None


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def collect(home, now):
    today = dt.datetime.fromtimestamp(now).date()
    days = [today - dt.timedelta(days=offset) for offset in range(6, -1, -1)]
    keys = ('input_tokens', 'cached_input_tokens', 'output_tokens', 'total_tokens')
    daily = {day: dict.fromkeys(keys, 0) for day in days}
    latest = None
    seen = set()
    skipped = 0
    for folder in ('sessions', 'archived_sessions'):
        for path in sorted((home / folder).rglob('*.jsonl')):
            # Archiving moves a rollout; never count copies of it twice.
            if path.name in seen:
                continue
            seen.add(path.name)
            previous = None
            try:
                with path.open('rb') as stream:
                    for line in stream:
                        if b'"token_count"' not in line:
                            continue
                        try:
                            event = json.loads(line)
                        except (ValueError, UnicodeError):
                            continue  # An active rollout can end with a partial JSON line.
                        payload = event.get('payload') or {}
                        if event.get('type') != 'event_msg' or payload.get('type') != 'token_count':
                            continue
                        when = timestamp(event.get('timestamp'))
                        if when is None or when > now + 60:
                            continue
                        limits = payload.get('rate_limits')
                        if isinstance(limits, dict) and limits.get('limit_id') in (None, 'codex'):
                            windows = {k: limits.get(k) for k in ('primary', 'secondary')}
                            if any(isinstance(w, dict) and number(w.get('used_percent')) for w in windows.values()):
                                if latest is None or when >= latest['timestamp']:
                                    latest = {'timestamp': when, 'limits': limits}
                        info = payload.get('info') or {}
                        cumulative = info.get('total_token_usage')
                        if not isinstance(cumulative, dict) or not number(cumulative.get('total_tokens')):
                            continue
                        if previous is not None and cumulative['total_tokens'] == previous['total_tokens']:
                            continue  # Rate-limit-only events repeat the same token counters.
                        if previous is not None and cumulative['total_tokens'] > previous['total_tokens']:
                            delta = {k: max(0, cumulative.get(k, 0) - previous.get(k, 0)) for k in keys}
                        else:
                            # First observation may inherit a fork's historical counters.
                            delta = info.get('last_token_usage') or {}
                        previous = cumulative
                        event_day = dt.datetime.fromtimestamp(when).date()
                        if event_day in daily:
                            for key in keys:
                                value = delta.get(key, 0)
                                if number(value) and value > 0:
                                    daily[event_day][key] += int(value)
            except OSError:
                skipped += 1
    history = [{'date': day.strftime('%m-%d'),
                'tokens': daily[day]['total_tokens'],
                'input_tokens': daily[day]['input_tokens'],
                'output_tokens': daily[day]['output_tokens'],
                'text': compact_tokens(daily[day]['total_tokens']),
                'input_text': compact_tokens(daily[day]['input_tokens']),
                'output_text': compact_tokens(daily[day]['output_tokens'])} for day in days]
    return {'latest': latest, 'today': daily[today], 'history': history,
            'skipped_files': skipped, 'refreshed_at': now}


def collect_usage(home, local_only=False):
    now = dt.datetime.now().timestamp()
    data = collect(home, now)
    data['scanned_at'] = now
    data['quota_source'] = 'log'
    data['query_enabled'] = not local_only
    if not local_only:
        try:
            data['latest'] = quota_api.query(home)
            data['quota_source'] = 'api'
        except quota_api.AuthError as error:
            data['quota_error'] = str(error)
            data['auth_required'] = True
        except quota_api.QuotaQueryError as error:
            data['quota_error'] = str(error)
        data['queried_at'] = dt.datetime.now().timestamp()
        data['refreshed_at'] = data['queried_at']
    return data


def local_time(value):
    return dt.datetime.fromtimestamp(value).strftime('%m-%d %H:%M')


def countdown(value, now):
    if not number(value) or value <= now:
        return '已到期，等待新记录'
    seconds = int(value - now)
    days, remainder = divmod(seconds, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes = remainder // 60
    if days:
        return f'{days}天{hours}小时'
    if hours:
        return f'{hours}小时{minutes}分'
    return f'{max(1, minutes)}分钟'


def window_text(window, now):
    if not isinstance(window, dict) or not number(window.get('used_percent')):
        return '暂无数据（当前日志未提供）', None
    reset = window.get('resets_at')
    if number(reset) and reset <= now:
        return '待更新', None
    used = min(100, max(0, window['used_percent']))
    return f'已用 {used:g}% · 剩余 {100 - used:g}%', used


def window_label(window, fallback):
    minutes = (window or {}).get('window_minutes')
    if minutes == 10080:
        return '每周'
    if number(minutes) and minutes > 0:
        return f'{minutes / 60:g} 小时' if minutes % 60 == 0 else f'{minutes:g} 分钟'
    return fallback


def quota_windows(limits):
    """Slots are provider ordering, not durations. Never merge older account snapshots."""
    result = {'primary': None, 'secondary': None}
    slots = {key: limits.get(key) for key in result}
    explicit_duration = any(isinstance(w, dict) and number(w.get('window_minutes'))
                            and w['window_minutes'] > 0 for w in slots.values())
    for slot, window in slots.items():
        if not isinstance(window, dict):
            continue
        duration = window.get('window_minutes')
        key = {300: 'primary', 10080: 'secondary'}.get(duration) if number(duration) else None
        # Older logs may omit all duration metadata. Mixed/unknown durations are ambiguous.
        if key is None and not explicit_duration:
            key = slot
        if key is not None:
            existing = result[key]
            if existing is None or (not number(existing.get('used_percent')) and number(window.get('used_percent'))):
                result[key] = window
    return result


def available_windows(data):
    """Report selectable quota windows from the newest snapshot only."""
    latest = data.get('latest')
    if not latest:
        return {'primary': False, 'secondary': False}
    limits = quota_windows(latest.get('limits') or {})
    now = data['refreshed_at']
    return {key: window_text(limits[key], now)[1] is not None for key in limits}


def compact_tokens(value):
    for scale, suffix in ((1_000_000_000, 'B'), (1_000_000, 'M'), (1_000, 'k')):
        if value >= scale:
            return f'{value / scale:.1f}'.rstrip('0').rstrip('.') + suffix
    return str(value)


def displayed_window(settings, primary_used, secondary_used):
    """A persisted selection can outlive its matching log field."""
    selected = settings['window']
    selected_used = primary_used if selected == 'primary' else secondary_used
    return selected if selected_used is not None else (
        'secondary' if selected == 'primary' and secondary_used is not None else
        'primary' if selected == 'secondary' and primary_used is not None else selected)


def ui_model(data, settings=None):
    """Structured view state for the native menu bar app."""
    settings = preferences.validate(settings or {})
    now = data['refreshed_at']
    latest = data.get('latest')
    source = data.get('quota_source', 'log')
    query_enabled = bool(data.get('query_enabled', False))
    missing_reason = '接口未提供' if source == 'api' else '当前日志未提供'
    mode = '剩余' if settings['display'] == 'remaining' else '已用'
    tokens = data['today']['total_tokens']
    model = {
        'title': 'Codex 待更新',
        'tooltip': 'Codex 额度',
        'icon_value': '—',
        'stale': False,
        'displayed_key': None,
        'headline': None,
        'windows': [],
        'low_quota': [],
        'tokens': None,
        'history': [],
        'details': [],
        'error': data.get('quota_error'),
        'auth_required': bool(data.get('auth_required')),
        'source': 'Codex 查询接口' if source == 'api' else '本机日志',
        'updated': local_time(data.get('scanned_at', now)),
        'refresh_minutes': settings['refresh_minutes'],
        'query_enabled': query_enabled,
        'mode': mode,
        'show_codex': settings['show_codex'],
        'show_open_code': settings['show_opencode'],
        'icon': {key: settings[key] for key in
                 ('label_size', 'value_size', 'weight', 'width', 'value_offset')},
    }
    if settings['show_tokens']:
        model['tokens'] = {'text': compact_tokens(tokens), 'raw': tokens}
        model['history'] = data.get('history', [])
    if latest:
        limits = quota_windows(latest['limits'])
        primary, p = window_text(limits.get('primary'), now)
        secondary, s = window_text(limits.get('secondary'), now)
        stale = now - latest['timestamp'] > settings['stale_minutes'] * 60
        displayed = displayed_window(settings, p, s)
        used = p if displayed == 'primary' else s
        amount = (100 - used if settings['display'] == 'remaining' else used) if used is not None else None
        period = '周' if displayed == 'secondary' else '5h'
        short_mode = '余' if settings['display'] == 'remaining' else '用'
        title = f'Codex {period}{short_mode} {amount:g}%' if amount is not None else 'Codex 待更新'
        if stale:
            title += ' ⏱'
        model.update({
            'title': title,
            'tooltip': f'{title}（{"5 小时" if displayed == "primary" else "每周"}窗口'
                       + ('，已自动切换' if displayed != settings['window'] else '') + '）',
            'icon_value': f'{amount:g}%' if amount is not None else '—',
            'stale': stale,
            'displayed_key': displayed,
            'updated': local_time(latest['timestamp']),
        })
        if used is not None:
            model['headline'] = {
                'label': '5小时额度' if displayed == 'primary' else '本周额度',
                'mode': mode, 'amount': amount, 'used': used, 'remaining': 100 - used,
            }
        if settings['low_quota_warning'] and not stale:
            model['low_quota'] = [label for label, value in (('5 小时', p), ('每周', s))
                                  if value is not None and 100 - value <= settings['low_quota_threshold']]
        rows = [('primary', '5小时额度', primary, p), ('secondary', '本周额度', secondary, s)]
        rows.sort(key=lambda row: (row[3] is None, row[0] != displayed))
        for key, label, text, value in rows:
            window = limits.get(key)
            entry = {
                'key': key, 'label': label, 'available': value is not None,
                'used': value, 'remaining': None if value is None else 100 - value,
                'amount': None if value is None else
                          (100 - value if settings['display'] == 'remaining' else value),
                'status': None, 'reason': None, 'reset_text': None, 'reset_at': None,
            }
            reset = (window or {}).get('resets_at')
            if value is None:
                entry['status'] = '待更新' if text == '待更新' else '未提供'
                if entry['status'] == '未提供':
                    entry['reason'] = missing_reason
                elif number(reset):
                    entry['reset_at'] = local_time(reset)
            elif number(reset) and reset > now:
                entry['reset_text'] = (countdown(reset, now) + '后重置'
                                       if settings['show_countdown'] else '重置于 ' + local_time(reset))
                entry['reset_at'] = local_time(reset)
            model['windows'].append(entry)
        details = [f'额度来源：{model["source"]}',
                   f'每 {settings["refresh_minutes"]} 分钟'
                   f'{"查询额度" if query_enabled else "扫描本机日志"}']
        for key, label, text, value in (('primary', '5小时额度', primary, p),
                                        ('secondary', '本周额度', secondary, s)):
            window = limits.get(key)
            reset = (window or {}).get('resets_at')
            if value is None:
                if text == '待更新':
                    if number(reset):
                        details.append(f'{label}上次重置：{local_time(reset)}')
                else:
                    details.append(f'{label}：{missing_reason}')
            elif number(reset):
                details.append(f'{label}重置：{local_time(reset)}')
        if data.get('queried_at'):
            details.append(f'接口查询：{local_time(data["queried_at"])}')
        if data.get('quota_error'):
            details.append(f'查询结果：{data["quota_error"]}')
        if data['skipped_files']:
            details.append(f'无法读取 {data["skipped_files"]} 个日志文件')
        model['details'] = details
    else:
        model['details'] = [
            '额度查询失败，暂无可用记录' if data.get('quota_error') else '尚未找到额度记录',
            f'额度来源：{model["source"]}',
        ]
        if data['skipped_files']:
            model['details'].append(f'无法读取 {data["skipped_files"]} 个日志文件')
    return model


def summary(data, settings=None):
    """A plain-text status for the terminal; the app reads --ui-json instead."""
    settings = preferences.validate(settings or {})
    model = ui_model(data, settings)
    lines = [model['title']]
    for window in model['windows']:
        if window['available']:
            amount = window['amount']
            lines.append(f"  {window['label']}  {model['mode']} {amount:g}%"
                         + (f" · {window['reset_text']}" if window['reset_text'] else ''))
        else:
            lines.append(f"  {window['label']}  {window['status']}"
                         + (f"（{window['reason']}）" if window['reason'] else ''))
    if model['tokens']:
        lines.append(f"  今日 tokens {model['tokens']['text']}（本机估算）")
    lines.append(f"  来源 {model['source']} · 更新于 {model['updated']}")
    if model['error']:
        lines.append(f"  查询失败：{model['error']}")
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--codex-home', type=Path, default=Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))))
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--get-settings', action='store_true')
    parser.add_argument('--save-settings', action='store_true')
    parser.add_argument('--ui-json', action='store_true')
    parser.add_argument('--opencode-json', action='store_true')
    parser.add_argument('--available-windows', action='store_true')
    parser.add_argument('--local-only', action='store_true', help='只读取本机日志，不查询额度接口')
    args = parser.parse_args()
    if args.get_settings:
        print(json.dumps(preferences.read(), ensure_ascii=False))
        return
    if args.save_settings:
        result = preferences.save(json.load(sys.stdin))
        print(json.dumps(result, ensure_ascii=False))
        return
    if args.opencode_json:
        import opencode_usage
        try:
            settings = preferences.read()
            result = opencode_usage.query(
                days=settings['opencode_days'], display=settings['opencode_display'],
                cli=settings['opencode_cli'] or None,
                show_go=settings['opencode_show_go'],
                show_rolling=settings['opencode_show_rolling'],
                show_weekly=settings['opencode_show_weekly'],
                show_monthly=settings['opencode_show_monthly'],
                show_stats=settings['opencode_show_stats'],
                show_cost=settings['opencode_show_cost'])
        except opencode_usage.OpenCodeError as error:
            result = opencode_usage.empty(str(error))
        print(json.dumps(result, ensure_ascii=False))
        return
    if args.available_windows:
        data = collect_usage(args.codex_home, local_only=args.local_only)
        print(json.dumps(available_windows(data), ensure_ascii=False))
        return
    settings = preferences.read()
    data = collect_usage(args.codex_home, local_only=args.local_only)
    if args.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return
    if args.ui_json:
        print(json.dumps(ui_model(data, settings), ensure_ascii=False))
        return
    print(summary(data, settings))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('Codex 读取失败，请在终端运行 codex_usage.py 查看详细错误')
        raise
