"""Menu-bar catalog, quota wording and legacy selection migration."""
import math

FIVE_HOUR = '5 小时额度'
WEEKLY = '每周额度'
MONTHLY = '每月额度'
QUOTA_LABELS = {'primary': FIVE_HOUR, 'secondary': WEEKLY,
                'rolling': FIVE_HOUR, 'weekly': WEEKLY, 'monthly': MONTHLY}
CATALOG = [
    dict(provider='codex', meter='auto', label='Codex 当前主额度（自动）', short_label='Codex', automatic=True),
    dict(provider='codex', meter='primary', label=f'Codex · {FIVE_HOUR}', short_label='Codex 5h'),
    dict(provider='codex', meter='secondary', label=f'Codex · {WEEKLY}', short_label='Codex 周'),
    dict(provider='opencode', meter='rolling', label=f'OpenCode · {FIVE_HOUR}', short_label='OpenCode'),
    dict(provider='opencode', meter='weekly', label=f'OpenCode · {WEEKLY}', short_label='OpenCode 周'),
    dict(provider='opencode', meter='monthly', label=f'OpenCode · {MONTHLY}', short_label='OpenCode 月'),
]
LEGACY = {
    'codex': dict(provider='codex', meter='auto'),
    'codex_primary': dict(provider='codex', meter='primary'),
    'codex_secondary': dict(provider='codex', meter='secondary'),
    'opencode_rolling': dict(provider='opencode', meter='rolling'),
    'opencode_weekly': dict(provider='opencode', meter='weekly'),
    'opencode_monthly': dict(provider='opencode', meter='monthly'),
}


def identity(item):
    if isinstance(item, str):
        item = LEGACY.get(item, {'provider': 'unknown', 'meter': item})
    if isinstance(item, dict) and item.get('provider') == 'unknown' and isinstance(item.get('meter'), str):
        item = LEGACY.get(item['meter'], item)
    if (not isinstance(item, dict) or set(item) != {'provider', 'meter'}
            or any(not isinstance(item[key], str) or not item[key] for key in ('provider', 'meter'))):
        raise ValueError('无效设置：menu_bar_items')
    return dict(item)


def key(item):
    item = identity(item)
    return item['provider'], item['meter']


def selection(items, allow_unknown=False):
    if not isinstance(items, list) or not items:
        raise ValueError('无效设置：menu_bar_items')
    result = [identity(item) for item in items]
    keys = [key(item) for item in result]
    known = {key({'provider': m['provider'], 'meter': m['meter']}) for m in CATALOG}
    if len(keys) != len(set(keys)) or (not allow_unknown and any(k not in known for k in keys)):
        raise ValueError('无效设置：menu_bar_items')
    for metric in CATALOG:
        if metric.get('automatic') and (metric['provider'], metric['meter']) in keys:
            if any(provider == metric['provider'] and meter != metric['meter'] for provider, meter in keys):
                raise ValueError('自动额度与固定窗口不能同时选择')
    return result


def catalog(settings=None):
    settings = settings or {}
    return [{**item, 'automatic': item.get('automatic', False), 'used': None, 'updated': None,
             'quota_label': QUOTA_LABELS.get(item['meter']),
             'display_key': 'display' if item['provider'] == 'codex' else 'opencode_display',
             'display': settings.get('display' if item['provider'] == 'codex' else 'opencode_display', 'remaining')}
            for item in CATALOG]


def readings(provider, snapshot, settings, updated=None):
    result = [m for m in catalog(settings) if m['provider'] == provider]
    if provider == 'codex':
        values = {w['key']: w.get('used') for w in snapshot.get('windows', []) if w.get('available')}
        headline = snapshot.get('headline') or {}
        values['auto'] = headline.get('used')
        if headline.get('label'):
            result[0]['label'] = 'Codex · ' + headline['label']
    else:
        values = {m['key']: m.get('used') for m in snapshot.get('menu_bar_meters', [])}
        updated = snapshot.get('updated')
    for metric in result:
        used = values.get(metric['meter'])
        metric['used'] = used if isinstance(used, (int, float)) and not isinstance(used, bool) and math.isfinite(used) else None
        metric['updated'] = updated
    return result
