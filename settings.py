"""Validated settings shared by the native menu bar app and the settings window."""
import json
import os
import tempfile
from pathlib import Path

SUPPORT = Path.home() / 'Library/Application Support/CodexUsage'
CONFIG = SUPPORT / 'settings.json'
DEFAULTS = dict(refresh_minutes=5, window='primary', display='remaining',
                show_tokens=True, show_countdown=True, label_size=7,
                value_size=12, weight='regular', width=30, value_offset=0,
                stale_minutes=15, low_quota_warning=False, low_quota_threshold=20,
                show_codex=True, show_opencode=True)
INTERVALS = (1, 2, 5, 10, 15, 30)


def validate(raw):
    if not isinstance(raw, dict):
        raise ValueError('设置格式不正确')
    result = dict(DEFAULTS)
    for key in DEFAULTS:
        if key in raw:
            result[key] = raw[key]
    for key, choices in dict(refresh_minutes=INTERVALS, window=('primary', 'secondary'),
                             display=('remaining', 'used'), weight=('regular', 'medium', 'semibold'),
                             stale_minutes=(15, 30, 60, 120), low_quota_threshold=(10, 20, 30)).items():
        if result[key] not in choices or isinstance(result[key], bool):
            raise ValueError(f'无效设置：{key}')
    for key in ('show_tokens', 'show_countdown', 'low_quota_warning', 'show_codex', 'show_opencode'):
        if not isinstance(result[key], bool):
            raise ValueError(f'无效设置：{key}')
    for key in ('refresh_minutes', 'stale_minutes', 'low_quota_threshold'):
        if type(result[key]) is not int:
            raise ValueError(f'无效设置：{key}')
    for key, low, high in [('label_size', 6, 10), ('value_size', 10, 15), ('width', 30, 44), ('value_offset', -2, 2)]:
        value = result[key]
        if type(value) is not int or not low <= value <= high:
            raise ValueError(f'无效设置：{key}')
    return result


def read(path=CONFIG):
    try:
        return validate(json.loads(path.read_text()))
    except (OSError, ValueError, TypeError):
        return dict(DEFAULTS)


def atomic_write(path, content, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.codex-usage-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def save(raw, config=CONFIG):
    """Persist settings for the native menu bar app."""
    values = validate(raw)
    atomic_write(config, json.dumps(values, ensure_ascii=False, indent=2) + '\n')
    return values
