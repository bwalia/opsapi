# Test supplier feed: serves /feed/<name> behind HTTP Basic auth (user "trade", password "s3cret").
import base64, http.server, os
OK = "Basic " + base64.b64encode(b"trade:s3cret").decode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Authorization") != OK:
            self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="feed"')
            self.send_header("Content-Length", "0"); self.end_headers(); return
        path = os.path.join("/feed", os.path.basename(self.path))
        if not os.path.isfile(path):
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
        body = open(path, "rb").read()
        self.send_response(200); self.send_header("Content-Type", "text/csv"); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
os.makedirs("/feed", exist_ok=True)
http.server.ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
