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
PY
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$project_root/.build/module-cache" \
  "$project_root/MenuBarMetric.swift" "$project_root/.build/HoverAppSource.swift" \
  "$project_root/script/test_hover.swift" -o "$project_root/.build/test-hover"
"$project_root/.build/test-hover"
