"""Validated settings shared by the native menu bar app and the settings window."""
import json
import os
import tempfile
from pathlib import Path
import metrics

SUPPORT = Path.home() / 'Library/Application Support/CodexUsage'
CONFIG = SUPPORT / 'settings.json'
DEFAULTS = dict(refresh_minutes=5, window='primary', display='remaining',
                show_tokens=True, show_countdown=True, label_size=7,
                value_size=12, weight='regular', width=30, value_offset=0,
                stale_minutes=15, low_quota_warning=False, low_quota_threshold=20,
                show_codex=True, show_opencode=True,
                opencode_display='remaining', opencode_days=7,
                opencode_show_go=True, opencode_show_rolling=True,
                opencode_show_weekly=True, opencode_show_monthly=True,
                opencode_show_stats=True, opencode_show_cost=True,
                opencode_cli='', menu_bar_items=[dict(provider='codex', meter='auto')])
INTERVALS = (1, 2, 5, 10, 15, 30)


def validate(raw, *, allow_unknown_metrics=False):
    if not isinstance(raw, dict):
        raise ValueError('设置格式不正确')
    result = {**DEFAULTS, **raw}
    for key, choices in dict(refresh_minutes=INTERVALS, window=('primary', 'secondary'),
                             display=('remaining', 'used'), weight=('regular', 'medium', 'semibold'),
                             stale_minutes=(15, 30, 60, 120), low_quota_threshold=(10, 20, 30),
                             opencode_display=('remaining', 'used'), opencode_days=(7, 30)).items():
        if result[key] not in choices or isinstance(result[key], bool):
            raise ValueError(f'无效设置：{key}')
    for key in ('show_tokens', 'show_countdown', 'low_quota_warning', 'show_codex', 'show_opencode',
                'opencode_show_go', 'opencode_show_rolling', 'opencode_show_weekly', 'opencode_show_monthly',
                'opencode_show_stats', 'opencode_show_cost'):
        if not isinstance(result[key], bool):
            raise ValueError(f'无效设置：{key}')
    for key in ('refresh_minutes', 'stale_minutes', 'low_quota_threshold', 'opencode_days'):
        if type(result[key]) is not int:
            raise ValueError(f'无效设置：{key}')
    if not result['show_codex'] and not result['show_opencode']:
        raise ValueError('至少保留一张卡片')
    if not isinstance(result['opencode_cli'], str):
        raise ValueError('无效设置：opencode_cli')
    result['menu_bar_items'] = metrics.selection(result['menu_bar_items'], allow_unknown_metrics)
    for key, low, high in [('label_size', 6, 10), ('value_size', 10, 15), ('width', 30, 44), ('value_offset', -2, 2)]:
        value = result[key]
        if type(value) is not int or not low <= value <= high:
            raise ValueError(f'无效设置：{key}')
    return result


def read(path=CONFIG):
    try:
        return validate(json.loads(path.read_text()), allow_unknown_metrics=True)
    except (OSError, ValueError, TypeError):
        return validate({})


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
    """Apply changed keys to the latest file, preserving fields from newer versions."""
    if not isinstance(raw, dict):
        raise ValueError('设置格式不正确')
    try:
        stored = json.loads(config.read_text())
    except FileNotFoundError:
        stored = {}
    if not isinstance(stored, dict):
        raise ValueError('设置格式不正确')
    changes = dict(raw)
    if 'menu_bar_items' in changes:
        items = metrics.selection(changes['menu_bar_items'], allow_unknown=True)
        previous = metrics.selection(stored.get('menu_bar_items', DEFAULTS['menu_bar_items']), allow_unknown=True)
        known = {metrics.key({'provider': m['provider'], 'meter': m['meter']}) for m in metrics.CATALOG}
        previous_keys = {metrics.key(item) for item in previous}
        if any(metrics.key(item) not in known | previous_keys for item in items):
            raise ValueError('无效设置：menu_bar_items')
        # Older windows cannot edit metrics they do not recognize.
        selected = {metrics.key(item) for item in items}
        changes['menu_bar_items'] = items + [item for item in previous
                                            if metrics.key(item) not in known | selected]
    values = validate({**stored, **changes}, allow_unknown_metrics=True)
    atomic_write(config, json.dumps(values, ensure_ascii=False, indent=2) + '\n')
    return values
