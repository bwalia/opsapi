#!/bin/bash
# Restarts the platform's Ollama (launchd com.ollama.server, :11434) when it is up but has stopped answering.
# Ollama 0.34's scheduler can wedge: /api/version still answers, but no generation request ever starts, so the
# OpsAPI assistant times out on every environment until someone restarts it (seen 2026-10-02, -05, -14, -15).
# Run every 2 minutes by launchd (com.opsapi.ollama-watchdog); install with ./install.sh. A server that isn't
# running at all is launchd's job (KeepAlive), not this one's.
set -u

URL="${OLLAMA_WATCHDOG_URL:-http://127.0.0.1:11434}"
MODEL="${OLLAMA_WATCHDOG_MODEL:-qwen3.8:latest}"
LABEL="${OLLAMA_WATCHDOG_LABEL:-com.ollama.server}"
FAILS_TO_RESTART="${OLLAMA_WATCHDOG_FAILS:-3}"  # about 6 minutes without one answer
COOLDOWN="${OLLAMA_WATCHDOG_COOLDOWN:-600}"     # seconds between restarts, so a slow cold start isn't restarted again
DIR="$HOME/Library/Logs/ollama"
mkdir -p "$DIR"
FAILS_FILE="$DIR/watchdog.fails"
RESTARTED_FILE="$DIR/watchdog.restarted"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$DIR/watchdog.log"; }

curl -sf -m 5 "$URL/api/version" >/dev/null || exit 0

# One token from the model OpsAPI uses, kept loaded (keep_alive -1) so the next request doesn't pay a cold start.
if curl -sf -m 90 -o /dev/null "$URL/api/generate" \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"ok\",\"stream\":false,\"keep_alive\":-1,\"options\":{\"num_predict\":1}}"; then
  echo 0 > "$FAILS_FILE"
  exit 0
fi

fails=$(( $(cat "$FAILS_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$fails" > "$FAILS_FILE"
log "no answer from $MODEL ($fails/$FAILS_TO_RESTART)"
[ "$fails" -lt "$FAILS_TO_RESTART" ] && exit 0

last=$(stat -f %m "$RESTARTED_FILE" 2>/dev/null || echo 0)
if [ $(( $(date +%s) - last )) -lt "$COOLDOWN" ]; then
  log "still no answer, but restarted less than ${COOLDOWN}s ago: waiting"
  exit 0
fi
touch "$RESTARTED_FILE"
echo 0 > "$FAILS_FILE"
log "restarting $LABEL"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
