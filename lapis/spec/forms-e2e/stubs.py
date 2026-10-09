"""Stand-ins for the outside services the forms e2e needs (stdlib only):
  POST /v1/chat/completions  an OpenAI-compatible model: a form draft when the
                             system prompt asks to design one, else a summary.
                             Every request body is saved to /w/stub/llm-<n>.json.
  POST /turnstile            Cloudflare Turnstile siteverify: success only for
                             secret "test-secret" + response "ok-token"."""
import itertools, json, os, urllib.parse
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


ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
