"""Validated settings shared by the native window and the SwiftBar plugin."""
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

SUPPORT = Path.home() / 'Library/Application Support/CodexUsage'
CONFIG = SUPPORT / 'settings.json'
DEFAULTS = dict(refresh_minutes=5, window='primary', display='remaining',
                show_tokens=True, show_countdown=True, label_size=7,
                value_size=12, weight='regular', width=30, value_offset=0,
                stale_minutes=15, low_quota_warning=False, low_quota_threshold=20)
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
    for key in ('show_tokens', 'show_countdown', 'low_quota_warning'):
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


def plugin_directory():
    result = subprocess.run(['/usr/bin/defaults', 'read', 'com.ameba.SwiftBar', 'PluginDirectory'],
                            capture_output=True, text=True, timeout=5)
    value = result.stdout.strip()
    return Path(value).expanduser() if result.returncode == 0 and value else Path.home() / 'Library/Application Support/SwiftBar/Plugins'


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


def apply(raw, config=CONFIG, plugins=None, template=None):
    settings = validate(raw)
    plugins = plugin_directory() if plugins is None else plugins
    template = SUPPORT / 'codex-usage.5m.sh' if template is None else template
    source = template.read_text()
    target = plugins / f"codex-usage.{settings['refresh_minutes']}m.sh"
    # Refuse to replace another plugin with a coinciding name.
    owned = []
    for path in plugins.glob('codex-usage.*m.sh'):
        if re.fullmatch(r'codex-usage\.\d+m\.sh', path.name):
            if 'CodexUsage/codex_usage.py' not in path.read_text():
                if path == target:
                    raise ValueError('插件文件名已被其他脚本占用')
            else:
                owned.append(path)
    previous = config.read_text() if config.exists() else None
    atomic_write(config, json.dumps(settings, ensure_ascii=False, indent=2) + '\n')
    try:
        atomic_write(target, source, 0o755)
    except OSError:
        if previous is not None:
            atomic_write(config, previous)
        else:
            config.unlink(missing_ok=True)
        raise
    for path in owned:
        if path != target:
            path.unlink()  # Only this application's obsolete interval wrapper.
    return settings
