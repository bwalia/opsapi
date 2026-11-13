#!/bin/bash
# Restarts OpsAPI's own Ollama copies (launchd com.opsapi.ollama :11439, com.opsapi.ollama-b :11440) when one is up
# but has stopped answering, and keeps qwen3.8 loaded on each so a request never pays a cold start.
# Ollama 0.34's scheduler can wedge: /api/version still answers, but no generation request ever starts, so the
# OpsAPI assistant times out until someone restarts it (seen 2026-10-02, -05, -14, -15).
# Run every 2 minutes by launchd (com.opsapi.ollama-watchdog); install with ./install.sh. A server that isn't
# running at all is launchd's job (KeepAlive), not this one's. Each copy is checked on its own, at the same time.
set -u

# "url=launchd-label" pairs, space-separated.
TARGETS="${OLLAMA_WATCHDOG_TARGETS:-http://127.0.0.1:11439=com.opsapi.ollama http://127.0.0.1:11440=com.opsapi.ollama-b}"
MODEL="${OLLAMA_WATCHDOG_MODEL:-qwen3.8:latest}"
FAILS_TO_RESTART="${OLLAMA_WATCHDOG_FAILS:-3}"  # about 6 minutes without one answer
COOLDOWN="${OLLAMA_WATCHDOG_COOLDOWN:-600}"     # seconds between restarts, so a slow cold start isn't restarted again
DIR="$HOME/Library/Logs/ollama"
mkdir -p "$DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$DIR/watchdog.log"; }

check() { # url label
  local url="$1" label="$2" fails_file="$DIR/watchdog.$2.fails" restarted_file="$DIR/watchdog.$2.restarted"
  curl -sf -m 5 "$url/api/version" >/dev/null || return 0

  # One token from the model OpsAPI uses, kept loaded (keep_alive -1).
  if curl -sf -m 90 -o /dev/null "$url/api/generate" \
      -d "{\"model\":\"$MODEL\",\"prompt\":\"ok\",\"stream\":false,\"keep_alive\":-1,\"options\":{\"num_predict\":1}}"; then
    echo 0 > "$fails_file"
    return 0
  fi

  local fails=$(( $(cat "$fails_file" 2>/dev/null || echo 0) + 1 ))
  echo "$fails" > "$fails_file"
  log "$label: no answer from $MODEL ($fails/$FAILS_TO_RESTART)"
  [ "$fails" -lt "$FAILS_TO_RESTART" ] && return 0

  local last
  last=$(stat -f %m "$restarted_file" 2>/dev/null || echo 0)
  if [ $(( $(date +%s) - last )) -lt "$COOLDOWN" ]; then
    log "$label: still no answer, but restarted less than ${COOLDOWN}s ago: waiting"
    return 0
  fi
  touch "$restarted_file"
  echo 0 > "$fails_file"
  log "$label: restarting"
  launchctl kickstart -k "gui/$(id -u)/$label"
}

for t in $TARGETS; do check "${t%%=*}" "${t#*=}" & done
wait
