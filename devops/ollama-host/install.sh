#!/bin/bash
# Installs (or updates) OpsAPI's own Ollama copies and their watchdog on the model host. Safe to run again.
#   bash devops/ollama-host/install.sh
# Leaves the shared Ollama (com.ollama.server, :11434) and kubepilot's (:11438) alone.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
COPIES="com.opsapi.ollama:11439:opsapi com.opsapi.ollama-b:11440:opsapi-b" # label:port:log name
mkdir -p "$HOME/.opsapi" "$HOME/Library/Logs/ollama" "$AGENTS"

load() { # label, then sed expressions for the plist
  local label="$1" plist="$AGENTS/$1.plist" src="$SRC/$1.plist"; shift
  [ -f "$src" ] || src="$SRC/com.opsapi.ollama.plist"
  sed -e "s|__HOME__|$HOME|g" "$@" "$src" > "$plist.new"
  plutil -lint "$plist.new" >/dev/null
  mv "$plist.new" "$plist"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  launchctl kickstart "gui/$(id -u)/$label"
}

for copy in $COPIES; do
  IFS=: read -r label port logname <<< "$copy"
  # A port already taken by something else would leave this job restarting forever.
  owner=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | head -1 || true) # lsof exits 1 when free
  if [ -n "$owner" ] && [ "$owner" != "$(launchctl list | awk -v l="$label" '$3 == l {print $1}')" ]; then
    echo "Port $port is already in use by process $owner; not installing $label." >&2
    exit 1
  fi
  load "$label" -e "s|__LABEL__|$label|g" -e "s|__PORT__|$port|g" -e "s|__LOG__|$logname|g"
  for _ in $(seq 30); do curl -sf -m 2 "http://127.0.0.1:$port/api/version" >/dev/null && break; sleep 1; done
  curl -sf -m 2 "http://127.0.0.1:$port/api/version" >/dev/null \
    || { echo "$label didn't start: see ~/Library/Logs/ollama/$logname.err.log" >&2; exit 1; }
  echo "Running $label on :$port (log: ~/Library/Logs/ollama/$logname.err.log)"
done

install -m 755 "$SRC/ollama-watchdog.sh" "$HOME/.opsapi/ollama-watchdog.sh"
load com.opsapi.ollama-watchdog
rm -f "$HOME/Library/Logs/ollama/watchdog.fails" "$HOME/Library/Logs/ollama/watchdog.restarted" # pre-copy-B state
echo "Running com.opsapi.ollama-watchdog (every 2 minutes; log: ~/Library/Logs/ollama/watchdog.log)"
