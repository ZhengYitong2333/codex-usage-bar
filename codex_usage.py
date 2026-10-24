#!/usr/bin/python3
"""Query Codex quotas; estimate daily tokens from local usage events."""
import argparse
import base64
import datetime as dt
import json
import math
import os
import struct
import subprocess
import sys
import zlib
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
    latest = None
    totals = {'input_tokens': 0, 'cached_input_tokens': 0, 'output_tokens': 0, 'total_tokens': 0}
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
                            delta = {k: max(0, cumulative.get(k, 0) - previous.get(k, 0)) for k in totals}
                        else:
                            # First observation may inherit a fork's historical counters.
                            delta = info.get('last_token_usage') or {}
                        previous = cumulative
                        if dt.datetime.fromtimestamp(when).date() == today:
                            for key in totals:
                                value = delta.get(key, 0)
                                if number(value) and value > 0:
                                    totals[key] += int(value)
            except OSError:
                skipped += 1
    return {'latest': latest, 'today': totals, 'skipped_files': skipped, 'refreshed_at': now}


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


def progress_image(amount, fill, track):
    """A small, dependency-free PNG for a native menu's thin quota bar."""
    width, height = 240, 6
    radius = height / 2
    fill_rgb = tuple(bytes.fromhex(fill.lstrip('#')))
    track_rgb = tuple(bytes.fromhex(track.lstrip('#')))
    pixels = bytearray()
    for y in range(height):
        pixels.append(0)  # PNG scanline filter: none.
        for x in range(width):
            center = min(max(x + 0.5, radius), width - radius)
            inside = (x + 0.5 - center) ** 2 + (y + 0.5 - radius) ** 2 <= radius ** 2
            rgb = fill_rgb if x + 0.5 < width * amount / 100 else track_rgb
            pixels.extend((*rgb, 255 if inside else 0))

    def chunk(kind, payload):
        return (struct.pack('>I', len(payload)) + kind + payload
                + struct.pack('>I', zlib.crc32(kind + payload) & 0xffffffff))

    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(bytes(pixels))) + chunk(b'IEND', b''))
    return base64.b64encode(png).decode('ascii')


def render(data, settings=None):
    settings = preferences.validate(settings or {})
    now = data['refreshed_at']
    latest = data['latest']
    foreground = '#242424,#F2F2F2'
    secondary_color = '#626262,#B9B9B9'
    warning_color = '#946200,#EAC363'
    limits = {'primary': None, 'secondary': None}
    stale = False
    detail_lines = []
    lines = []
    source = data.get('quota_source', 'log')
    query_enabled = data.get('query_enabled', False)
    missing_reason = '接口未提供' if source == 'api' else '当前日志未提供'
    if latest:
        limits = quota_windows(latest['limits'])
        primary, p = window_text(limits.get('primary'), now)
        secondary, s = window_text(limits.get('secondary'), now)
        stale = now - latest['timestamp'] > settings['stale_minutes'] * 60
        selected_key = settings['window']
        selected_used = p if selected_key == 'primary' else s
        # A persisted selection can outlive its matching log field. Keep the
        # menu bar useful until the settings app updates that selection.
        displayed_key = selected_key if selected_used is not None else (
            'secondary' if selected_key == 'primary' and s is not None else
            'primary' if selected_key == 'secondary' and p is not None else selected_key)
        used = p if displayed_key == 'primary' else s
        mode = '剩余' if settings['display'] == 'remaining' else '已用'
        amount = (100 - used if mode == '剩余' else used) if used is not None else None
        period = '周' if displayed_key == 'secondary' else '5h'
        short_mode = '余' if mode == '剩余' else '用'
        title = f'Codex {period}{short_mode} {amount:g}%' if amount is not None else 'Codex 待更新'
        if stale:
            title += ' ⏱'
        worst = max([v for v in (p, s) if v is not None], default=0)
        color = '#888888' if stale or used is None else '#E5484D' if worst >= 95 else '#D99A00' if worst >= 80 else None
        lines.extend([title + ' | dropdown=false' + (f' color={color}' if color else ''), '---',
                      f'**Codex 额度** | md=true color={foreground}'])
        if stale:
            lines.append(f'额度记录已过时 · {local_time(latest["timestamp"])} | color={warning_color} size=12')
        if data.get('quota_error'):
            lines.append(f'查询失败，显示本机日志记录 | color={warning_color} size=12')
        if settings['low_quota_warning'] and not stale:
            low = [label for label, value in (('5 小时', p), ('每周', s))
                   if value is not None and 100 - value <= settings['low_quota_threshold']]
            if low:
                lines.extend([f"⚠ {'、'.join(low)}剩余额度 ≤ {settings['low_quota_threshold']}%", '---'])
        windows = [('primary', '5小时额度', primary, p), ('secondary', '本周额度', secondary, s)]
        windows.sort(key=lambda row: (row[3] is None, row[0] != displayed_key))
        for key, label, text, value in windows:
            window = limits.get(key)
            if value is None:
                status = '待更新' if text == '待更新' else '未提供'
                lines.append(f'{label}：{status} | color={secondary_color} size=12')
                if status == '未提供':
                    detail_lines.append(f'--{label}：{missing_reason} | color={secondary_color}')
                else:
                    reset = (window or {}).get('resets_at')
                    if number(reset):
                        detail_lines.append(f'--{label}上次重置：{local_time(reset)} | color={secondary_color}')
                continue
            amount = 100 - value if mode == '剩余' else value
            lines.append(f'**{label}  {mode} {amount:g}%** | md=true color={foreground}')
            colors = ('#858585', '#A5A5A5') if stale else (
                ('#C33439', '#F27479') if value >= 95 else
                ('#986500', '#E8B952') if value >= 80 else ('#24804B', '#61C88A'))
            light = progress_image(amount, colors[0], '#E2E6E2')
            dark = progress_image(amount, colors[1], '#414841')
            lines.append(f'额度进度 | image={light},{dark} size=1 color={secondary_color} '
                         f'tooltip="{label}：已用 {value:g}% · 剩余 {100 - value:g}%"')
            reset = (window or {}).get('resets_at')
            if number(reset) and reset > now:
                reset_text = countdown(reset, now) + '后重置' if settings['show_countdown'] else '重置于 ' + local_time(reset)
                lines.append(f'{reset_text} | color={secondary_color} size=12 tooltip="重置于 {local_time(reset)}"')
                detail_lines.append(f'--{label}重置：{local_time(reset)} | color={secondary_color}')
    else:
        lines.extend(['Codex 暂无额度数据 | dropdown=false', '---',
                      f'**Codex 额度** | md=true color={foreground}',
                      f'{"额度查询失败，暂无可用记录" if data.get("quota_error") else "尚未找到额度记录"} | color={secondary_color}',
                      f'5小时额度：未提供 | color={secondary_color} size=12',
                      f'本周额度：未提供 | color={secondary_color} size=12'])
    lines.extend(['---', f'用量与记录详情 | color={foreground}'])
    if settings['show_tokens']:
        tokens = data['today']['total_tokens']
        lines.append(f'--今日 tokens：{compact_tokens(tokens)}（本机估算） | color={foreground} '
                     f'tooltip="原始值：{tokens:,} tokens；本机日志估算"')
    if latest:
        state = ' · 已过时' if stale else ''
        lines.append(f'--额度记录：{local_time(latest["timestamp"])}{state} | color={secondary_color}')
    else:
        lines.append(f'--额度记录：尚无记录 | color={secondary_color}')
    lines.extend([
        f'--本机扫描：{local_time(data.get("scanned_at", now))} | color={secondary_color}',
        f'--额度来源：{"Codex 查询接口" if source == "api" else "本机日志"} | color={secondary_color}',
        f'--每 {settings["refresh_minutes"]} 分钟{"查询额度" if query_enabled else "扫描本机日志"} | color={secondary_color}',
        *detail_lines,
    ])
    if data.get('queried_at'):
        lines.append(f'--接口查询：{local_time(data["queried_at"])} | color={secondary_color}')
    if data.get('quota_error'):
        lines.append(f'--查询结果：{data["quota_error"]} | color={warning_color}')
    if data['skipped_files']:
        lines.append(f'--无法读取 {data["skipped_files"]} 个日志文件 | color={warning_color}')
    action_script = Path.home() / 'Library/Application Support/CodexUsage/codex_action.sh'
    lines.extend([
        '---',
        ('立即查询额度' if query_enabled else '重新读取本机记录') + ' | refresh=true',
        f'打开用量页面 | bash="{action_script}" param1=usage terminal=false',
        f'设置… | bash="{action_script}" param1=settings terminal=false',
    ])
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--codex-home', type=Path, default=Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))))
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--get-settings', action='store_true')
    parser.add_argument('--apply-settings', action='store_true')
    parser.add_argument('--available-windows', action='store_true')
    parser.add_argument('--local-only', action='store_true', help='只读取本机日志，不查询额度接口')
    args = parser.parse_args()
    if args.get_settings:
        print(json.dumps(preferences.read(), ensure_ascii=False))
        return
    if args.apply_settings:
        result = preferences.apply(json.load(sys.stdin))
        subprocess.run(['/usr/bin/open', '-g', 'swiftbar://refreshallplugins'], check=True)
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
    output = render(data, settings)
    icon = Path(__file__).resolve().with_name('menu_icon')
    if icon.is_file():
        title, rest = output.split('\n', 1)
        label = title.split(' | ', 1)[0]
        value = next((word for word in label.split() if word.endswith('%')), '—')
        try:
            command = [str(icon), value, 'stale' if '⏱' in label else 'fresh']
            light = subprocess.run(command + ['000000'], capture_output=True, text=True, timeout=5, check=True)
            dark = subprocess.run(command + ['FFFFFF'], capture_output=True, text=True, timeout=5, check=True)
            effective_key = settings['window']
            availability = available_windows(data)
            if not availability.get(effective_key):
                other = 'secondary' if effective_key == 'primary' else 'primary'
                if availability.get(other):
                    effective_key = other
            period = '5 小时窗口' if effective_key == 'primary' else '每周窗口'
            if effective_key != settings['window']:
                period += '（已自动切换）'
            output = f' | image={light.stdout.strip()},{dark.stdout.strip()} tooltip="{label}（{period}）" dropdown=false\n{rest}'
        except (OSError, subprocess.SubprocessError):
            pass  # Keep the text title if the optional renderer is unavailable.
    print(output)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('Codex 读取失败 | color=#888888\n---\n请在终端运行 codex_usage.py 检查本机日志格式')
        raise
