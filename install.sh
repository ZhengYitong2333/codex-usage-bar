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
swiftbar_app='/Applications/SwiftBar.app'
if [[ ! -d "$swiftbar_app" ]]; then swiftbar_app="$HOME/Applications/SwiftBar.app"; fi
if [[ ! -d "$swiftbar_app" ]]; then printf '请先安装 SwiftBar：brew install --cask swiftbar\n' >&2; exit 1; fi
if [[ "$skip_build" == false ]]; then "$project_root/script/build_and_run.sh" --build-only; fi
if [[ ! -x "$project_root/dist/menu_icon" || ! -x "$project_root/dist/Codex Usage Settings.app/Contents/MacOS/CodexUsageSettings" ]]; then
  printf '缺少构建产物，请先执行 ./script/build_and_run.sh --build-only。\n' >&2; exit 1
fi
support_dir="$HOME/Library/Application Support/CodexUsage"
plugin_dir="$(/usr/bin/defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
if [[ -z "$plugin_dir" ]]; then plugin_dir="$HOME/Library/Application Support/SwiftBar/Plugins"; fi
mkdir -p "$support_dir" "$plugin_dir" "$HOME/Applications"
for source in codex_usage.py quota_api.py settings.py codex_action.sh codex-usage.5m.sh; do cp "$project_root/$source" "$support_dir/"; done
cp "$project_root/dist/menu_icon" "$support_dir/menu_icon"
chmod +x "$support_dir/codex_action.sh" "$support_dir/menu_icon"
/usr/bin/ditto "$project_root/dist/Codex Usage Settings.app" "$HOME/Applications/Codex Usage Settings.app"
/usr/bin/python3 - "$support_dir" "$plugin_dir" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import settings
settings.apply(settings.read(), plugins=Path(sys.argv[2]))
PY
/usr/bin/defaults write com.ameba.SwiftBar PluginDirectory -string "$plugin_dir"
if [[ "$login_item" == true ]]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  agent_path="$HOME/Library/LaunchAgents/local.codex-usage.swiftbar.plist"
  /usr/bin/python3 - "$agent_path" "$swiftbar_app" <<'PY'
import plistlib
import sys
from pathlib import Path
content = {'Label': 'local.codex-usage.swiftbar', 'ProgramArguments': ['/usr/bin/open', '-g', '-a', sys.argv[2]], 'RunAtLoad': True}
Path(sys.argv[1]).write_bytes(plistlib.dumps(content))
PY
  if [[ "$launch" == true ]] && ! /bin/launchctl print "gui/$(id -u)/local.codex-usage.swiftbar" >/dev/null 2>&1; then
    /bin/launchctl bootstrap "gui/$(id -u)" "$agent_path" || printf '登录启动暂未加载，可在下次登录后生效。\n' >&2
  fi
fi
if [[ "$launch" == true ]]; then
  /usr/bin/open -g -a "$swiftbar_app"
  /usr/bin/open -g 'swiftbar://refreshallplugins'
fi
printf '已安装。个人设置已保留；请在菜单中选择“立即查询额度”或“设置…”。\n'
