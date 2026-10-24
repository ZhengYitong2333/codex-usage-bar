"""Read subscription quotas through Codex's authenticated app-server API."""
import json
import math
import os
import selectors
import shutil
import subprocess
import time
from pathlib import Path


class QuotaQueryError(Exception):
    """A safe, user-facing error without credentials or raw server output."""


class AuthError(QuotaQueryError):
    """The Codex account is not signed in, so the user has to log in."""


def find_codex():
    candidates = [shutil.which('codex'), str(Path.home() / '.local/bin/codex'),
                  '/Applications/Codex.app/Contents/Resources/codex',
                  '/opt/homebrew/bin/codex', '/usr/local/bin/codex']
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise QuotaQueryError('未找到 Codex CLI，无法主动查询额度')


def api_error(error):
    message = str(error.get('message', '')).lower()
    if any(word in message for word in ('401', 'unauthorized', 'authentication', 'not logged', 'not authenticated', 'requires chatgpt', 'not available for api key')):
        return AuthError('Codex 登录状态不可用，请在 Codex 中重新登录 ChatGPT 账号')
    if '429' in message or 'too many requests' in message:
        return QuotaQueryError('额度接口暂时限流，稍后重试')
    if '403' in message or 'forbidden' in message:
        return QuotaQueryError('额度接口拒绝访问')
    if error.get('code') == -32601:
        return QuotaQueryError('当前 Codex CLI 不支持额度查询，请更新 Codex')
    return QuotaQueryError('Codex 额度接口暂时不可用')


def normalize(result):
    """Only select the Codex bucket; slot order does not imply duration."""
    if not isinstance(result, dict):
        raise QuotaQueryError('额度接口返回的数据格式不正确')
    buckets = result.get('rateLimitsByLimitId')
    limits = buckets.get('codex') if isinstance(buckets, dict) else None
    if limits is None:
        limits = result.get('rateLimits')
    if not isinstance(limits, dict) or limits.get('limitId') not in (None, 'codex'):
        raise QuotaQueryError('接口未返回 Codex 额度')
    normalized = {'limit_id': 'codex', 'primary': None, 'secondary': None}
    for key in ('primary', 'secondary'):
        window = limits.get(key)
        if not isinstance(window, dict):
            continue
        used = window.get('usedPercent')
        if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used):
            continue
        value = {'used_percent': used}
        for source, target in (('windowDurationMins', 'window_minutes'), ('resetsAt', 'resets_at')):
            number = window.get(source)
            if not isinstance(number, bool) and isinstance(number, (int, float)) and math.isfinite(number):
                value[target] = number
        normalized[key] = value
    if not any(normalized[key] is not None for key in ('primary', 'secondary')):
        raise QuotaQueryError('接口暂未提供额度窗口')
    return normalized


def query(home, timeout=12):
    """Query quotas without creating a conversation or reading auth secrets."""
    env = dict(os.environ)
    env['CODEX_HOME'] = str(Path(home).expanduser().resolve())
    process = None
    selector = selectors.DefaultSelector()
    try:
        process = subprocess.Popen(
            [find_codex(), 'app-server', '--listen', 'stdio://'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=env, bufsize=0,
        )
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout
        buffer = b''

        def send(message):
            process.stdin.write((json.dumps(message) + '\n').encode('utf-8'))
            process.stdin.flush()

        send({'id': 1, 'method': 'initialize', 'params': {
            'clientInfo': {'name': 'codex_usage_bar', 'title': 'Codex Usage', 'version': '2.0.0'},
        }})
        initialized = False
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise QuotaQueryError('额度查询超时，稍后重试')
            block = os.read(process.stdout.fileno(), 65536)
            if not block:
                raise QuotaQueryError('Codex 查询进程提前结束')
            buffer += block
            if len(buffer) > 1024 * 1024:
                raise QuotaQueryError('额度接口返回的数据过大')
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                if not line.strip():
                    continue
                message = json.loads(line)
                if not isinstance(message, dict):
                    continue
                request_id = message.get('id')
                if 'method' in message:
                    if request_id is not None:
                        send({'id': request_id, 'error': {
                            'code': -32601, 'message': 'Quota monitor supports read-only queries only',
                        }})
                    continue
                if request_id == 1 and not initialized:
                    if 'error' in message:
                        raise api_error(message['error'])
                    initialized = True
                    send({'method': 'initialized', 'params': {}})
                    send({'id': 2, 'method': 'account/rateLimits/read'})
                elif request_id == 2 and initialized:
                    if 'error' in message:
                        raise api_error(message['error'])
                    return {'timestamp': time.time(), 'limits': normalize(message.get('result'))}
    except QuotaQueryError:
        raise
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        raise QuotaQueryError('无法完成 Codex 额度查询') from None
    finally:
        selector.close()
        if process is not None:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            for stream in (process.stdin, process.stdout):
                if stream is not None:
                    stream.close()
