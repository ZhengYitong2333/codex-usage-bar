"""Read OpenCode local usage stats and the OpenCode Go allowance.

The background service publishes its endpoint and a private local password in
$XDG_STATE_HOME/opencode/service.json. Reading that file is the documented
discovery contract for OpenCode clients. Neither value is logged or persisted.
"""
import base64
import datetime as dt
import json
import math
import os
import shutil
import sqlite3
import subprocess
import time
import http.client
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


class OpenCodeError(Exception):
    """A safe, user-facing error without credentials or raw output."""


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def timestamp(value):
    if isinstance(value, str):
        try:
            parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        except ValueError:
            return None
        return parsed.timestamp()
    if not number(value):
        return None
    # OpenCode sends milliseconds; tolerate seconds from older builds.
    return value / 1000 if value > 10**12 else value


def local_time(value):
    return dt.datetime.fromtimestamp(value).strftime('%m-%d %H:%M')


def countdown(value, now):
    if not number(value) or value <= now:
        return '已到期'
    seconds = int(value - now)
    days, remainder = divmod(seconds, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes = remainder // 60
    if days:
        return f'{days}天{hours}小时'
    if hours:
        return f'{hours}小时{minutes}分'
    return f'{max(1, minutes)}分钟'


def compact(value):
    value = int(value or 0)
    for scale, suffix in ((1_000_000_000, 'B'), (1_000_000, 'M'), (1_000, 'k')):
        if value >= scale:
            return f'{value / scale:.1f}'.rstrip('0').rstrip('.') + suffix
    return str(value)


def find_opencode():
    candidates = [
        str(Path(__file__).resolve().parent / 'opencode'),
        shutil.which('opencode'),
        str(Path.home() / '.local/bin/opencode'),
        str(Path.home() / '.opencode/bin/opencode'),
        str(Path.home() / '.volta/bin/opencode'),
        str(Path.home() / '.asdf/shims/opencode'),
        '/opt/homebrew/bin/opencode',
        '/usr/local/bin/opencode',
    ]
    node_versions = Path.home() / '.nvm/versions/node'
    if node_versions.is_dir():
        candidates = [str(path) for path in sorted(node_versions.glob('*/bin/opencode'), reverse=True)] + candidates
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise OpenCodeError('未找到 OpenCode CLI')


def service_registration():
    state = Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state')))
    path = state / 'opencode' / 'service.json'
    try:
        info = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(info, dict) or not isinstance(info.get('url'), str):
        return None
    return info


def usage_limits(timeout=8):
    """Go allowance and Console budgets from the local OpenCode service.

    Returns a (payload, status) pair. status is one of ok, signed_out,
    unsupported, or unavailable, so the UI can explain why meters are empty.
    """
    info = service_registration()
    if info is None:
        return None, 'unavailable'
    request = urllib.request.Request(
        info['url'].rstrip('/') + '/api/experimental/usage/limits',
        headers={'Accept': 'application/json'},
    )
    password = info.get('password')
    if isinstance(password, str):
        token = base64.b64encode(f'opencode:{password}'.encode()).decode('ascii')
        request.add_header('Authorization', 'Basic ' + token)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            data = json.load(response)
            return (data, 'ok') if isinstance(data, dict) else (None, 'signed_out')
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            raise OpenCodeError('OpenCode 本地服务认证失败') from None
        if error.code == 404:
            return None, 'unsupported'  # This OpenCode release has no limits route.
        raise OpenCodeError('OpenCode 额度接口暂时不可用') from None
    except http.client.HTTPException:
        return None, 'unavailable'
    except (urllib.error.URLError, OSError, ValueError):
        return None, 'unavailable'


def console_credential(integration="opencode"):
    """The signed-in OpenCode credential, read from OpenCode's own store.

    OpenCode keeps integration credentials in its local database. Reading it
    here only fills the Authorization header of the user's own Console
    requests; the value is never logged, stored, or shown.

    Returns (credential, status) where status is "ok", "signed_out" or
    "unreadable", so a locked database is not reported as a missing sign-in.
    """
    data_home = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share')))
    database = data_home / 'opencode' / 'opencode.db'
    if not database.is_file():
        return None, 'signed_out'
    try:
        connection = sqlite3.connect(f'file:{database}?mode=ro', uri=True, timeout=2)
        try:
            rows = connection.execute(
                "select integration_id, value, active from credential").fetchall()
        finally:
            connection.close()
    except sqlite3.Error:
        return None, 'unreadable'
    for integration_id, raw, active in rows:
        if integration_id != integration or not active:
            continue
        try:
            value = json.loads(raw)
        except (TypeError, ValueError):
            continue
        if not isinstance(value, dict):
            continue
        metadata = value.get('metadata') if isinstance(value.get('metadata'), dict) else {}
        token = value.get('access') if value.get('type') == 'oauth' else value.get('key')
        if not isinstance(token, str) or not token:
            continue
        return {'token': token, 'org_id': metadata.get('orgID'),
                'org_name': metadata.get('orgName'),
                'server': metadata.get('server')}, 'ok'
    return None, 'signed_out'


def console_server(credential):
    server = credential.get('server')
    if not isinstance(server, str) or not server:
        server = 'https://opencode.ai/console'
    # Credentials saved before August 2026 name the retired console host.
    if server.startswith('https://console.opencode.ai'):
        server = 'https://opencode.ai' + server[len('https://console.opencode.ai'):]
    return server.rstrip('/')


def console_request(url, credential, timeout=8, org_header='x-org-id'):
    request = urllib.request.Request(url, headers={
        # The Go edge rejects urllib's default Python User-Agent.
        'User-Agent': 'CodexUsageBar/1.0',
        'Accept': 'application/json',
        'Authorization': 'Bearer ' + credential['token'],
    })
    org_id = credential.get('org_id')
    if isinstance(org_id, str) and org_id:
        request.add_header(org_header, org_id)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 401:
            raise OpenCodeError('OpenCode 登录凭据已失效，请重新登录') from None
        if error.code == 403:
            raise OpenCodeError('OpenCode 额度查询被拒绝（HTTP 403），请检查 Go 订阅或访问权限') from None
        raise OpenCodeError('OpenCode Console 额度接口暂时不可用') from None
    except http.client.HTTPException:
        raise OpenCodeError('OpenCode 额度响应不完整，请稍后重试') from None
    except (urllib.error.URLError, OSError, ValueError):
        raise OpenCodeError('OpenCode 额度查询失败，请稍后重试') from None


def console_limits(timeout=8):
    """Go allowance and Console budgets straight from the Console API.

    OpenCode releases before 2.2 do not expose the local limits route, so the
    same two Console endpoints the CLI uses are called directly.
    """
    credential, credential_status = console_credential()
    go_credential, go_status = console_credential('opencode-go')
    if go_credential is None:
        go_credential = credential
        go_status = credential_status
    if go_credential is None:
        return None, go_status
    payload = {'workspace': None, 'go': None, 'budgets': []}
    error = None
    server = console_server(go_credential)
    parsed = urllib.parse.urlsplit(server)
    try:
        usage = console_request(parsed.scheme + '://' + parsed.netloc + '/zen/go/v1/usage',
                                go_credential, timeout, org_header='x-opencode-org-id')
        if isinstance(usage, dict) and isinstance(usage.get('usage'), dict):
            payload['go'] = usage['usage']
    except OpenCodeError as exc:
        error = exc
        if '凭据已失效' in str(exc):
            return None, 'signed_out'

    # Go provider keys authorize Go usage, not Console workspace budgets.
    if credential is not None:
        server = console_server(credential)
        try:
            budgets = console_request(server + '/api/policies/current-budgets', credential, timeout)
            if isinstance(budgets, list):
                payload['budgets'] = budgets
        except OpenCodeError as exc:
            error = error or exc
        org_id = credential.get('org_id')
        payload['workspace'] = {'id': org_id, 'name': credential.get('org_name'),
                                'usageURL': server + '/' + str(org_id) + '/activity/overview'}
    if payload['go'] is None and not payload['budgets']:
        if error:
            raise error
        return None, 'unavailable'
    return payload, 'ok'


def read_stats(binary, days=7, timeout=45):
    command = [binary, 'stats', '--json', '--days', str(days)]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        raise OpenCodeError('OpenCode 统计查询超时或失败') from None
    if result.returncode != 0:
        message = (result.stderr or '').lower()
        if 'unknown' in message or 'argument' in message or 'json' in message:
            raise OpenCodeError('当前 OpenCode 版本不支持 stats --json，请升级')
        raise OpenCodeError('OpenCode 统计查询失败')
    try:
        stats = json.loads(result.stdout)
    except ValueError:
        raise OpenCodeError('无法解析 OpenCode 统计结果') from None
    if not isinstance(stats, dict):
        raise OpenCodeError('OpenCode 统计结果格式不正确')
    return stats


def token_counts(stats):
    tokens = stats.get('tokens')
    if not isinstance(tokens, dict):
        raise OpenCodeError('OpenCode 未提供 token 统计')
    cache = tokens.get('cache') or {}
    if not isinstance(cache, dict):
        raise OpenCodeError('OpenCode token 统计格式不正确')
    values = [tokens.get('input', 0), tokens.get('output', 0),
              tokens.get('reasoning', 0), cache.get('read', 0), cache.get('write', 0)]
    if not all(number(value) and value >= 0 for value in values):
        raise OpenCodeError('OpenCode token 统计格式不正确')
    return {'input_tokens': int(values[0]), 'output_tokens': int(values[1]),
            'tokens': int(sum(values))}


def read_history(binary, now, timeout=45, known=None):
    """Derive calendar-day tokens from CLI cumulative calendar-day windows.

    `known` carries the window already fetched so it is not queried twice.
    """
    today = dt.datetime.fromtimestamp(now).date()
    deadline = time.monotonic() + timeout
    previous = dict.fromkeys(('input_tokens', 'output_tokens', 'tokens'), 0)
    history = []
    for days in range(1, 8):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise OpenCodeError('OpenCode 每日统计查询超时')
        stats = known.get(days) if known and days in known else read_stats(binary, days=days, timeout=remaining)
        day = today - dt.timedelta(days=days - 1)
        window = stats.get('range')
        start = timestamp(window.get('from')) if isinstance(window, dict) else None
        if start is None or dt.datetime.fromtimestamp(start).date() != day:
            raise OpenCodeError('OpenCode 未提供按自然日统计的用量')
        counts = token_counts(stats)
        entry = {key: max(0, counts[key] - previous[key]) for key in previous}
        entry.update(date=day.strftime('%m-%d'), text=compact(entry['tokens']))
        history.append(entry)
        previous = counts
    return list(reversed(history))


def meter(key, label, raw, now, display):
    if not isinstance(raw, dict) or not number(raw.get('percent')):
        return None
    used = min(100.0, max(0.0, float(raw['percent'])))
    resets = timestamp(raw.get('resetsAt'))
    status = raw.get('status')
    limited = bool(raw.get('limited')) or status == 'rate-limited'
    return {
        'key': key,
        'label': label,
        'used': used,
        'remaining': 100 - used,
        'amount': 100 - used if display == 'remaining' else used,
        'limited': limited,
        'resets_at': resets,
        'reset_text': (countdown(resets, now) + '后重置') if resets and resets > now else None,
        'reset_clock': local_time(resets) if resets else None,
    }


def budget(label, raw, now):
    if not isinstance(raw, dict):
        return None
    # The local service route reports limit/spent; the Console API reports dollars.
    limit = raw.get('limit', raw.get('limitDollars'))
    spent = raw.get('spent', raw.get('spentDollars'))
    if not number(limit) or float(limit) <= 0:
        return None
    limit = float(limit)
    spent = float(spent) if number(spent) else 0.0
    resets = timestamp(raw.get('resetsAt'))
    return {
        'label': label,
        'limit': limit,
        'spent': spent,
        'remaining': max(0.0, limit - spent),
        'percent': min(100.0, max(0.0, spent / limit * 100)),
        'resets_at': resets,
        'reset_text': (countdown(resets, now) + '后重置') if resets and resets > now else None,
    }


def count(value, default=0):
    """A count from untrusted CLI output; anything unexpected reads as zero."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return default
    if isinstance(value, float) and (value != value or value in (float('inf'), float('-inf'))):
        return default
    return int(value)


def normalize(stats, limits, days, display, now,
              show_go=True, show_rolling=True, show_weekly=True, show_monthly=True,
              show_stats=True, show_cost=True):
    tokens = stats.get('tokens') if isinstance(stats.get('tokens'), dict) else {}
    cache = tokens.get('cache') if isinstance(tokens.get('cache'), dict) else {}
    values = {
        'input': count(tokens.get('input')),
        'output': count(tokens.get('output')),
        'reasoning': count(tokens.get('reasoning')),
        'cache_read': count(cache.get('read')),
        'cache_write': count(cache.get('write')),
    }
    total = sum(values.values())
    activity = []
    for item in stats.get('activity') or []:
        if isinstance(item, dict) and isinstance(item.get('date'), str) and number(item.get('steps')):
            activity.append({'date': item['date'], 'steps': count(item['steps'])})
    peak = max([item['steps'] for item in activity] + [1])
    for item in activity:
        item['level'] = min(4, round(item['steps'] / peak * 4)) if item['steps'] else 0
    result = {
        'available': True,
        'days': days,
        'display': display,
        'workspace': None,
        'usage_url': None,
        'go': None,
        'go_meters': [],
        'menu_bar_meters': [],
        'budgets': [],
        'show_go': show_go,
        'limits_status': None,
        'stats': {
            'tokens': values,
            'total': total,
            'total_text': compact(total),
            'input_text': compact(values['input']),
            'output_text': compact(values['output']),
            'cost': float(stats['cost']) if number(stats.get('cost')) else None,
            'sessions': count(stats.get('sessions')),
            'active_days': count(stats.get('activeDays')),
            'streak': count(stats.get('streak')),
            'activity': activity,
        },
        'updated': time.time(),
        'error': None,
    }
    if isinstance(limits, dict):
        workspace = limits.get('workspace')
        if isinstance(workspace, dict):
            result['workspace'] = workspace.get('name') or None
            result['usage_url'] = workspace.get('usageURL') if isinstance(workspace.get('usageURL'), str) else None
        go = limits.get('go')
        if isinstance(go, dict):
            for key, label in (('rolling', '滚动额度'), ('weekly', '每周额度'), ('monthly', '每月额度')):
                entry = meter(key, label, go.get(key), now, display)
                if entry is not None:
                    result['menu_bar_meters'].append(entry)
            enabled = {'rolling': show_rolling, 'weekly': show_weekly, 'monthly': show_monthly}
            if not show_go:
                enabled = {key: False for key in enabled}
            result['go'] = {key: meter(key, label, go.get(key), now, display)
                            for key, label in (('rolling', '滚动额度'),
                                               ('weekly', '每周额度'),
                                               ('monthly', '每月额度'))
                            if enabled[key]}
            result['go_meters'] = [m for m in result['go'].values() if m]
            result['go'] = result['go'] if result['go_meters'] else None
        budgets = limits.get('budgets') if isinstance(limits.get('budgets'), list) else []
        for index, raw in enumerate(budgets):
            entry = budget('月度预算' if len(budgets) == 1 else f'预算 {index + 1}', raw, now)
            if entry:
                result['budgets'].append(entry)
    if not show_cost and result['stats']:
        result['stats']['cost'] = None
    if not show_stats:
        result['stats'] = None
    return result


def query(days=7, display='remaining', timeout=45, cli=None,
          show_go=True, show_rolling=True, show_weekly=True, show_monthly=True,
          show_stats=True, show_cost=True):
    if cli:
        binary = str(Path(cli).expanduser())
        if not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
            raise OpenCodeError('OpenCode CLI 路径无效')
    else:
        binary = find_opencode()
    stats = read_stats(binary, days=days, timeout=timeout)
    now = time.time()
    limits = None
    limits_status = 'unavailable'
    error = None
    try:
        limits, limits_status = usage_limits()
    except OpenCodeError as exc:
        error = str(exc)
    if limits_status in ('unsupported', 'unavailable', 'signed_out'):
        try:
            console, console_status = console_limits()
        except OpenCodeError as exc:
            console, console_status = None, 'unavailable'
            error = error or str(exc)
        if console is not None:
            limits, limits_status = console, console_status
        else:
            limits_status = console_status
    result = normalize(stats, limits, days, display, now, show_go=show_go,
                       show_rolling=show_rolling, show_weekly=show_weekly,
                       show_monthly=show_monthly, show_stats=show_stats,
                       show_cost=show_cost)
    result['limits_status'] = limits_status
    result['error'] = error
    if result['stats'] is not None:
        try:
            known = {days: stats} if days == 7 else None
            result['stats']['history'] = read_history(binary, now, timeout=timeout, known=known)
            result['stats']['today_text'] = result['stats']['history'][-1]['text']
        except OpenCodeError as exc:
            result['stats']['history'] = []
            result['stats']['today_text'] = None
            result['stats']['error'] = str(exc)
    result['queried_at'] = now
    return result


def empty(reason):
    return {'available': False, 'reason': reason, 'error': reason, 'updated': time.time()}
