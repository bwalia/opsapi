#!/bin/bash
# Installs (or updates) the Ollama watchdog on the model host. Safe to run again.
#   bash devops/ollama-host/install.sh
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.opsapi.ollama-watchdog"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$HOME/.opsapi" "$HOME/Library/Logs/ollama"
install -m 755 "$SRC/ollama-watchdog.sh" "$HOME/.opsapi/ollama-watchdog.sh"
sed "s|__HOME__|$HOME|g" "$SRC/$LABEL.plist" > "$PLIST.new"
plutil -lint "$PLIST.new" >/dev/null
mv "$PLIST.new" "$PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart "gui/$(id -u)/$LABEL"
echo "Installed $LABEL (every 2 minutes; log: ~/Library/Logs/ollama/watchdog.log)"
