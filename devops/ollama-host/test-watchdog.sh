#!/bin/bash
# Checks ollama-watchdog.sh against two fake Ollama copies and a fake launchctl (macOS, python3).
#   bash devops/ollama-host/test-watchdog.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap '{ kill $A $B; wait; } 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"
printf '#!/bin/sh\necho "$@" >> "%s/kicks"\n' "$T" > "$T/bin/launchctl"; chmod +x "$T/bin/launchctl"

fake() { # port, mode file: answers generate with 200 while the file says ok, 500 otherwise
  echo ok > "$2"
  python3 - "$1" "$2" > /dev/null 2>&1 <<'EOF' &
import http.server, sys
PORT, MODE = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code):
        self.send_response(code); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")
    def do_GET(self): self.reply(200)
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.reply(200 if open(MODE).read().strip() == "ok" else 500)
http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
EOF
}
fake 18434 "$T/a"; A=$!
fake 18435 "$T/b"; B=$!
sleep 1

run() { HOME="$T/home" PATH="$T/bin:$PATH" \
  OLLAMA_WATCHDOG_TARGETS="http://127.0.0.1:18434=copy.a http://127.0.0.1:18435=copy.b" bash "$HERE/ollama-watchdog.sh"; }
kicks() { touch "$T/kicks"; grep -c "$1\$" "$T/kicks"; }
state() { cat "$T/home/Library/Logs/ollama/watchdog.$1.fails"; }
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1 (got $2, want $3)"; fails=$((fails + 1)); fi; }

run; check "healthy copies are left alone" "$(kicks copy.a)$(kicks copy.b)" 00
echo wedged > "$T/b"
run; run; check "two missed answers: no restart yet" "$(kicks copy.b)" 0
run; check "the third missed answer restarts that copy" "$(grep -c 'kickstart -k gui/.*/copy.b$' "$T/kicks")" 1
check "...and only that copy" "$(kicks copy.a)" 0
check "the healthy copy's count stays at 0" "$(state copy.a)" 0
run; run; run; check "...and not again within the cooldown" "$(kicks copy.b)" 1
echo ok > "$T/b"; run
check "an answer resets the count" "$(state copy.b)" 0
{ kill $B; wait $B; } 2>/dev/null; rm -f "$T/home/Library/Logs/ollama/watchdog.copy.b.restarted"
run; run; run; check "a copy that isn't running is launchd's job, not a restart" "$(kicks copy.b)" 1

[ "$fails" = 0 ] && echo "ALL PASSED" || { echo "FAILED: $fails"; exit 1; }
