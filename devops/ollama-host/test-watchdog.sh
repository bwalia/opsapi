#!/bin/bash
# Checks ollama-watchdog.sh against a fake Ollama and a fake launchctl (macOS, python3).
#   bash devops/ollama-host/test-watchdog.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"
printf '#!/bin/sh\necho "$@" >> "%s/kicks"\n' "$T" > "$T/bin/launchctl"; chmod +x "$T/bin/launchctl"
echo ok > "$T/mode"
python3 - "$T/mode" > /dev/null 2>&1 <<'EOF' &
import http.server, sys
MODE = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code):
        self.send_response(code); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")
    def do_GET(self): self.reply(200)
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.reply(200 if open(MODE).read().strip() == "ok" else 500)
http.server.HTTPServer(("127.0.0.1", 18434), H).serve_forever()
EOF
SRV=$!; sleep 1

run() { HOME="$T/home" PATH="$T/bin:$PATH" OLLAMA_WATCHDOG_URL=http://127.0.0.1:18434 bash "$HERE/ollama-watchdog.sh"; }
kicks() { [ -f "$T/kicks" ] && wc -l < "$T/kicks" | tr -d ' ' || echo 0; }
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1 (got $2, want $3)"; fails=$((fails + 1)); fi; }

run; check "a healthy server is left alone" "$(kicks)" 0
echo wedged > "$T/mode"
run; run; check "two missed answers: no restart yet" "$(kicks)" 0
run; check "the third missed answer restarts com.ollama.server" "$(grep -c 'kickstart -k gui/.*/com.ollama.server' "$T/kicks")" 1
run; run; run; check "...and not again within the cooldown" "$(kicks)" 1
echo ok > "$T/mode"; run
check "an answer resets the count" "$(cat "$T/home/Library/Logs/ollama/watchdog.fails")" 0
kill $SRV; wait $SRV 2>/dev/null; rm -f "$T/home/Library/Logs/ollama/watchdog.restarted"
run; run; run; check "a server that isn't running is launchd's job, not a restart" "$(kicks)" 1

[ "$fails" = 0 ] && echo "ALL PASSED" || { echo "FAILED: $fails"; exit 1; }
