#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-run}"
case "$mode" in run|--build-only|--verify|--debug|--logs) ;; *) printf 'Usage: %s [--build-only|--verify|--debug|--logs]\n' "$0" >&2; exit 2 ;; esac
if [[ "$(uname -s)" != Darwin ]]; then printf 'Building requires macOS.\n' >&2; exit 1; fi
if [[ "$mode" != --build-only ]]; then pkill -x CodexUsageSettings 2>/dev/null || true; fi
build_dir="$project_root/.build"
dist_dir="$project_root/dist"
app_bundle="$dist_dir/Codex Usage Settings.app"
mkdir -p "$build_dir/module-cache" "$app_bundle/Contents/MacOS"
target="$(uname -m)-apple-macosx13.0"
xcrun swiftc -O -parse-as-library -target "$target" -module-cache-path "$build_dir/module-cache" "$project_root/SettingsApp.swift" -o "$app_bundle/Contents/MacOS/CodexUsageSettings"
cp "$project_root/SettingsInfo.plist" "$app_bundle/Contents/Info.plist"
xcrun swiftc -O -target "$target" -module-cache-path "$build_dir/module-cache" "$project_root/menu_icon.swift" -o "$dist_dir/menu_icon"
/usr/bin/codesign --force --sign - "$app_bundle" >/dev/null 2>&1
printf 'Built settings app and menu renderer in dist/.\n'
if [[ "$mode" == --build-only ]]; then exit 0; fi
"$project_root/install.sh" --skip-build --no-launch --no-login-item
installed_app="$HOME/Applications/Codex Usage Settings.app"
case "$mode" in
  --debug) /usr/bin/lldb -- "$installed_app/Contents/MacOS/CodexUsageSettings" ;;
  --logs) /usr/bin/open "$installed_app"; /usr/bin/log stream --info --style compact --predicate 'process == "CodexUsageSettings"' ;;
  --verify) /usr/bin/open "$installed_app"; sleep 1; pgrep -x CodexUsageSettings >/dev/null; printf 'Settings process is running.\n' ;;
  run) /usr/bin/open "$installed_app" ;;
esac
