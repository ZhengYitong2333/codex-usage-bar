#!/bin/bash
case "$1" in
  refresh) open -g 'swiftbar://refreshallplugins' ;;
  usage) open 'https://chatgpt.com/codex/settings/usage' ;;
  settings) open "$HOME/Applications/Codex Usage Settings.app" ;;
esac
