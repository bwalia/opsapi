#!/bin/bash
# Installs (or updates) OpsAPI's own Ollama (:11439) and its watchdog on the model host. Safe to run again.
#   bash devops/ollama-host/install.sh
# Leaves the shared Ollama (com.ollama.server, :11434) and kubepilot's (:11438) alone.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
mkdir -p "$HOME/.opsapi" "$HOME/Library/Logs/ollama" "$AGENTS"

load() { # label: write the plist from this folder, then (re)start the job
  local plist="$AGENTS/$1.plist"
  sed "s|__HOME__|$HOME|g" "$SRC/$1.plist" > "$plist.new"
  plutil -lint "$plist.new" >/dev/null
  mv "$plist.new" "$plist"
  launchctl bootout "gui/$(id -u)/$1" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  launchctl kickstart "gui/$(id -u)/$1"
}

# A port already taken by something else would leave this job restarting forever.
owner=$(lsof -nP -iTCP:11439 -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | head -1 || true) # lsof exits 1 when free
if [ -n "$owner" ] && [ "$owner" != "$(launchctl list | awk '$3 == "com.opsapi.ollama" {print $1}')" ]; then
  echo "Port 11439 is already in use by process $owner; not installing." >&2
  exit 1
fi

load com.opsapi.ollama
for _ in $(seq 30); do curl -sf -m 2 http://127.0.0.1:11439/api/version >/dev/null && break; sleep 1; done
curl -sf -m 2 http://127.0.0.1:11439/api/version >/dev/null || { echo "OpsAPI's Ollama didn't start: see ~/Library/Logs/ollama/opsapi.err.log" >&2; exit 1; }
echo "Running com.opsapi.ollama on :11439 (log: ~/Library/Logs/ollama/opsapi.err.log)"

install -m 755 "$SRC/ollama-watchdog.sh" "$HOME/.opsapi/ollama-watchdog.sh"
load com.opsapi.ollama-watchdog
echo "Running com.opsapi.ollama-watchdog (every 2 minutes; log: ~/Library/Logs/ollama/watchdog.log)"
