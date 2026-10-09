"""Stand-ins for the outside services the forms e2e needs (stdlib only):
  POST /v1/chat/completions  an OpenAI-compatible model: a form draft when the
                             system prompt asks to design one, else a summary.
                             Every request body is saved to /w/stub/llm-<n>.json.
  POST /turnstile            Cloudflare Turnstile siteverify: success only for
                             secret "test-secret" + response "ok-token".
  DNS on UDP 53              answers A (following CNAMEs) and TXT from /w/dns.json,
                             {"name": {"A": [...], "CNAME": "x", "TXT": [...]}};
                             a name not in it is NXDOMAIN."""
import itertools, json, os, socket, struct, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OUT = "/w/stub"
os.makedirs(OUT, exist_ok=True)
n = itertools.count(1)

DRAFT = {
    "title": "Event sign-up",
    "description": "Book your place.",
    "fields": [
        {"label": "Ticket", "type": "radio", "options": ["Standard", "VIP"], "required": True},
        {"label": "Favourite colour", "type": "colour"},
        {"label": "Dietary needs", "type": "long_text"},
    ],
    "create_records": ["lead"],
}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path.endswith("/chat/completions"):
            req = json.loads(raw or b"{}")
            with open(os.path.join(OUT, "llm-%03d.json" % next(n)), "w") as f:
                json.dump(req, f)
            system = (req.get("messages") or [{}])[0].get("content", "")
            content = json.dumps(DRAFT) if "design web forms" in system else \
                "- Most people chose VIP\n- Several asked for vegan food"
            return self.reply(200, {"id": "stub", "model": req.get("model"), "choices": [
                {"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": content}}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 5}})
        if self.path == "/turnstile":
            form = urllib.parse.parse_qs(raw.decode())
            ok = form.get("secret") == ["test-secret"] and form.get("response") == ["ok-token"]
            return self.reply(200, {"success": ok})
        self.reply(404, {})


def dns_name(name):
    return b"".join(bytes([len(p)]) + p.encode() for p in name.rstrip(".").split(".")) + b"\0"


def rr(name, rtype, rdata):
    return dns_name(name) + struct.pack("!HHIH", rtype, 1, 60, len(rdata)) + rdata


def dns_answer(query):
    tid = struct.unpack("!H", query[:2])[0]
    labels, i = [], 12
    while query[i]:
        labels.append(query[i + 1:i + 1 + query[i]].decode())
        i += 1 + query[i]
    qtype = struct.unpack("!H", query[i + 1:i + 3])[0]
    name, question = ".".join(labels).lower(), query[12:i + 5]
    try:
        zone = {k.lower(): v for k, v in json.load(open("/w/dns.json")).items()}
    except (OSError, ValueError):
        zone = {}
    records = []
    if qtype == 16:
        for t in zone.get(name, {}).get("TXT", []):
            records.append(rr(name, 16, bytes([len(t)]) + t.encode()))
    elif qtype == 1:
        cur = name
        for _ in range(5):
            target = zone.get(cur, {}).get("CNAME")
            if not target:
                break
            records.append(rr(cur, 5, dns_name(target)))
            cur = target.lower()
        for a in zone.get(cur, {}).get("A", []):
            records.append(rr(cur, 1, socket.inet_aton(a)))
    rcode = 0 if name in zone else 3
    return struct.pack("!HHHHHH", tid, 0x8180 | rcode, 1, len(records), 0, 0) + question + b"".join(records)


def dns_server():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", 53))
    while True:
        data, addr = sock.recvfrom(512)
        try:
            sock.sendto(dns_answer(data), addr)
        except Exception:  # a malformed query: no answer, like a real server under load
            pass


threading.Thread(target=dns_server, daemon=True).start()
ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
