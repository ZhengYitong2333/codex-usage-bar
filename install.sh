#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skip_build=false
launch=true
login_item=true
for option in "$@"; do
  case "$option" in
    --skip-build) skip_build=true ;;
    --no-launch) launch=false ;;
    --no-login-item) login_item=false ;;
    *) printf 'Usage: %s [--no-login-item] [--no-launch] [--skip-build]\n' "$0" >&2; exit 2 ;;
  esac
done
if [[ "$(uname -s)" != Darwin ]]; then printf '安装需要 macOS。\n' >&2; exit 1; fi
if [[ ! -x /usr/bin/python3 ]]; then printf '请先安装 Xcode Command Line Tools。\n' >&2; exit 1; fi
if [[ "$skip_build" == false ]]; then "$project_root/script/build_and_run.sh" --build-only; fi
if [[ ! -x "$project_root/dist/Codex Usage.app/Contents/MacOS/CodexUsage" \
   || ! -x "$project_root/dist/Codex Usage Settings.app/Contents/MacOS/CodexUsageSettings" ]]; then
  printf '缺少构建产物，请先执行 ./script/build_and_run.sh --build-only。\n' >&2; exit 1
fi

support_dir="$HOME/Library/Application Support/CodexUsage"
mkdir -p "$support_dir" "$HOME/Applications"
for source in codex_usage.py opencode_usage.py quota_api.py settings.py metrics.py; do cp "$project_root/$source" "$support_dir/"; done
# Remove files the earlier SwiftBar-based versions installed.
rm -f "$support_dir/codex_action.sh" "$support_dir/codex-usage.5m.sh" "$support_dir/menu_icon"

pkill -x CodexUsage 2>/dev/null || true
/usr/bin/ditto "$project_root/dist/Codex Usage.app" "$HOME/Applications/Codex Usage.app"
/usr/bin/ditto "$project_root/dist/Codex Usage Settings.app" "$HOME/Applications/Codex Usage Settings.app"

# Keep personal settings, but stop writing the legacy SwiftBar wrapper.
/usr/bin/python3 - "$support_dir" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import settings
settings.save({})
PY

# Remove this project's legacy SwiftBar plugin so the menu bar does not show twice.
plugin_dir="$(/usr/bin/defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
if [[ -z "$plugin_dir" ]]; then plugin_dir="$HOME/Library/Application Support/SwiftBar/Plugins"; fi
if [[ -d "$plugin_dir" ]]; then
  removed=false
  for plugin in "$plugin_dir"/codex-usage.*m.sh; do
    [[ -f "$plugin" ]] || continue
    if grep -q 'CodexUsage/codex_usage.py' "$plugin"; then
      rm -f "$plugin"
      removed=true
    fi
  done
fi

old_agent="$HOME/Library/LaunchAgents/local.codex-usage.swiftbar.plist"
if [[ -f "$old_agent" ]]; then
  /bin/launchctl bootout "gui/$(id -u)/local.codex-usage.swiftbar" >/dev/null 2>&1 || true
  rm -f "$old_agent"
fi

if [[ "$login_item" == true ]]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  agent_path="$HOME/Library/LaunchAgents/local.codex-usage.menubar.plist"
  /usr/bin/python3 - "$agent_path" "$HOME/Applications/Codex Usage.app" <<'PY'
import plistlib
import sys
from pathlib import Path
content = {'Label': 'local.codex-usage.menubar',
           'ProgramArguments': ['/usr/bin/open', '-g', '-a', sys.argv[2]],
           'RunAtLoad': True}
Path(sys.argv[1]).write_bytes(plistlib.dumps(content))
PY
  if [[ "$launch" == true ]] && ! /bin/launchctl print "gui/$(id -u)/local.codex-usage.menubar" >/dev/null 2>&1; then
    /bin/launchctl bootstrap "gui/$(id -u)" "$agent_path" || printf '登录启动暂未加载，可在下次登录后生效。\n' >&2
  fi
fi

if [[ "$launch" == true ]]; then
  /usr/bin/open "$HOME/Applications/Codex Usage.app"
fi
printf '已安装原生菜单栏应用。个人设置已保留；点击菜单栏图标查看额度。\n'
