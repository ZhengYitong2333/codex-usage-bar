#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$project_root/.build/module-cache"
# Compile production views with a test entrypoint, without launching network queries.
/usr/bin/python3 - "$project_root" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1])
source = (root / 'CodexUsageApp.swift').read_text().split('// MARK: - Entry point')[0]
(root / '.build/HoverAppSource.swift').write_text(source)
sys.path.insert(0, str(root))
import json
from codex_usage import ui_model
model = ui_model({'refreshed_at': 1000, 'latest': {'timestamp': 1000, 'limits': {
    'primary': {'used_percent': 18, 'resets_at': 9999},
    'secondary': {'used_percent': 30, 'resets_at': 9999}}},
    'today': {'total_tokens': 1234}, 'skipped_files': 0})
model['error'] = '用于布局验收的长错误说明，请稍后重试。' * 40
(root / '.build/scroll-fixture.json').write_text(json.dumps(model, ensure_ascii=False))
PY
xcrun swiftc -D DEBUG -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$project_root/.build/module-cache" \
  "$project_root/MenuBarMetric.swift" "$project_root/Preferences.swift" "$project_root/.build/HoverAppSource.swift" \
  "$project_root/script/test_hover.swift" -o "$project_root/.build/test-hover"
"$project_root/.build/test-hover" "$project_root"
