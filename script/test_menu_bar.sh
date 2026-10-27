#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$project_root/.build/module-cache"
xcrun swiftc -parse-as-library -module-cache-path "$project_root/.build/module-cache" \
  "$project_root/MenuBarMetric.swift" "$project_root/script/test_menu_bar.swift" \
  -o "$project_root/.build/test-menu-bar"
"$project_root/.build/test-menu-bar" "$project_root"
