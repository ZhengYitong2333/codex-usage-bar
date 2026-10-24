#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-run}"
case "$mode" in run|--build-only|--verify|--debug|--logs) ;; *) printf 'Usage: %s [--build-only|--verify|--debug|--logs]\n' "$0" >&2; exit 2 ;; esac
if [[ "$(uname -s)" != Darwin ]]; then printf 'Building requires macOS.\n' >&2; exit 1; fi
if [[ "$mode" != --build-only ]]; then pkill -x CodexUsage 2>/dev/null || true; pkill -x CodexUsageSettings 2>/dev/null || true; fi
build_dir="$project_root/.build"
dist_dir="$project_root/dist"
target="$(uname -m)-apple-macosx13.0"
mkdir -p "$build_dir/module-cache"

build_app() {
  local source="$1" plist="$2" bundle="$3" executable="$4"
  mkdir -p "$bundle/Contents/MacOS"
  xcrun swiftc -O -parse-as-library -target "$target" -module-cache-path "$build_dir/module-cache" \
    "$project_root/$source" -o "$bundle/Contents/MacOS/$executable"
  cp "$project_root/$plist" "$bundle/Contents/Info.plist"
  /usr/bin/codesign --force --sign - "$bundle" >/dev/null 2>&1
}

build_app SettingsApp.swift SettingsInfo.plist "$dist_dir/Codex Usage Settings.app" CodexUsageSettings
build_app CodexUsageApp.swift CodexUsageInfo.plist "$dist_dir/Codex Usage.app" CodexUsage

printf 'Built native menu bar app and settings app in dist/.\n'
if [[ "$mode" == --build-only ]]; then exit 0; fi
"$project_root/install.sh" --skip-build --no-launch --no-login-item
installed_app="$HOME/Applications/Codex Usage.app"
case "$mode" in
  --debug) /usr/bin/lldb -- "$installed_app/Contents/MacOS/CodexUsage" ;;
  --logs) /usr/bin/open "$installed_app"; /usr/bin/log stream --info --style compact --predicate 'process == "CodexUsage"' ;;
  --verify) /usr/bin/open "$installed_app"; sleep 1; pgrep -x CodexUsage >/dev/null; printf 'Menu bar process is running.\n' ;;
  run) /usr/bin/open "$installed_app" ;;
esac
