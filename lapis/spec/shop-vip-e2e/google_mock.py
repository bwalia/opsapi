"""Stand-in for Google's OAuth token + userinfo endpoints in the sandbox (answers as oauth2.googleapis.com and
www.googleapis.com; /auth/google/callback calls them with ssl_verify off, so a self-signed cert is enough).

The authorization code decides who signs in:  code = "verified:<email>" or "unverified:<email>".
"""
import json
import os
import ssl
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/token":
            return self._send(404, {"error": "not_found"})
        form = urllib.parse.parse_qs(self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode())
        code = (form.get("code") or [""])[0]
        if ":" not in code:
            return self._send(400, {"error": "invalid_grant"})
        return self._send(200, {"access_token": "at." + urllib.parse.quote(code, safe=""), "token_type": "Bearer"})

    def do_GET(self):
        if not self.path.startswith("/oauth2/v2/userinfo"):
            return self._send(404, {"error": "not_found"})
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer at."):
            return self._send(401, {"error": "invalid_token"})
        kind, email = urllib.parse.unquote(auth[len("Bearer at."):]).split(":", 1)
        return self._send(200, {"id": "g-" + email, "email": email, "verified_email": kind == "verified",
                                "name": "Test Customer", "given_name": "Test", "family_name": "Customer"})

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("0.0.0.0", 443), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
for name in ("cert", "key"):  # the TLS pair arrives as env (MOCK_CERT / MOCK_KEY), see run.sh
    with open(f"/tmp/{name}.pem", "w") as f:
        f.write(os.environ["MOCK_" + name.upper()])
ctx.load_cert_chain("/tmp/cert.pem", "/tmp/key.pem")
server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.serve_forever()
