#!/bin/bash
# <xbar.title>Codex 用量</xbar.title>
# <xbar.version>1.3</xbar.version>
# <xbar.desc>主动查询 Codex 额度，本机日志提供 token 估算与故障回退。</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
exec /usr/bin/python3 "$HOME/Library/Application Support/CodexUsage/codex_usage.py"
