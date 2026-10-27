#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$project_root/.build/module-cache"
# Compile the production settings model and store without the app entrypoint.
/usr/bin/python3 - "$project_root" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1])
source = (root / 'SettingsApp.swift').read_text().split('struct SettingsView: View')[0]
(root / '.build/SettingsTestSource.swift').write_text(source)
app = (root / 'CodexUsageApp.swift').read_text().split('// MARK: - Entry point')[0]
(root / '.build/SettingsAppTestSource.swift').write_text(app)
PY
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$project_root/.build/module-cache" \
  "$project_root/MenuBarMetric.swift" "$project_root/Preferences.swift" "$project_root/.build/SettingsTestSource.swift" \
  "$project_root/.build/SettingsAppTestSource.swift" \
  "$project_root/script/test_settings.swift" -o "$project_root/.build/test-settings"
"$project_root/.build/test-settings" "$project_root"
