"""A stand-in for Ollama and GitHub, for builtin_test.py (run by run.sh as the container ar-mock:8080).

Ollama  POST /api/chat: a scripted agent. The scenario is a marker in the run's prompt ([plan], [code], [ask],
        [slow], [loop], [fail], [followup]); the step is how many assistant messages the conversation already has.
GitHub  /gh/... (REST) and /ghweb/... (OAuth): two installations (1001 = acme: acme/web, acme/api; 2002 = other:
        other/secret), repositories as commits of whole file maps, installation tokens scoped like GitHub's (a token
        for one repository can't touch another: 404), app JWTs kept for the test to verify with the public key.
GET /_log: what was asked (chats, app JWTs, GitHub calls), for the test's checks. Standard library only.
"""
import base64
import hashlib
import json
import re
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

APP_ID, CLIENT_ID, CLIENT_SECRET = 4242, "Iv1.mockclient", "mocksecret0123456789"
LOCK = threading.Lock()
LOG = {"chats": [], "jwts": [], "github": [], "oauth": []}
INSTALLS = {1001: {"login": "acme", "type": "Organization", "repos": ["acme/web", "acme/api"]},
            2002: {"login": "other", "type": "User", "repos": ["other/secret"]}}
REPOS = {}
TOKENS = {}  # token -> {"install": id, "repos": [full names] or None}
USER_TOKENS = {"gho_1001": [1001], "gho_both": [1001, 2002]}
PULLS = {}


def blob(text):
    return hashlib.sha1(text.encode()).hexdigest()


def new_repo(name, files):
    REPOS[name] = {"default_branch": "main", "branches": {"main": "c-" + name.replace("/", "-") + "-1"},
                   "commits": {"c-" + name.replace("/", "-") + "-1": dict(files)}, "n": 1}


new_repo("acme/web", {"README.md": "# Web\n", "src/app.js": "export const greeting = 'hi';\n", ".env": "KEY=x\n"})
new_repo("acme/api", {"README.md": "# API\n"})
new_repo("other/secret", {"README.md": "# Secret\n"})


def scenario_of(messages):
    text = " ".join(m.get("content") or "" for m in messages if m.get("role") == "user")
    for s in ("plan", "code", "ask", "slow", "loop", "fail", "followup"):
        if "[" + s + "]" in text:
            return s
    return "plan"


def call(name, **args):
    return {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": name, "arguments": args}}]}


def say(text):
    return {"role": "assistant", "content": text}


def agent(messages):
    s, step = scenario_of(messages), sum(1 for m in messages if m.get("role") == "assistant")
    users = [m.get("content") or "" for m in messages if m.get("role") == "user"]
    if s == "fail":
        return None
    if s == "plan":
        return [call("get_task"), call("add_subtask", title="Write the migration", description="Add the table"),
                call("add_comment", text="Plan: 1) migration 2) API"), say("Planned it: one subtask and a comment.")
                ][min(step, 3)]
    if s == "code":
        return [call("get_task"), call("list_files"), call("search_code", query="greeting"),
                call("read_file", path="README.md"),
                call("write_file", path="README.md", content="# Web\n\nHello from the agent\n", message="Add a greeting"),
                call("write_file", path=".env", content="KEY=stolen\n"),
                call("write_file", path=".github/workflows/x.yml", content="on: push\n"),
                call("read_file", path="../etc/passwd"),
                call("read_file", path=".env"),
                say("Added a greeting to README.md.")][min(step, 9)]
    if s == "ask":
        if step == 0:
            return say("I need one detail.\nNEEDS_INPUT: Which colour should the button be?")
        return say("Painted the button " + ("blue" if "blue" in users[-1].lower() else "grey") + ".")
    if s in ("slow", "loop"):
        if s == "slow":
            time.sleep(2)
        return call("get_task")
    if s == "followup":
        if step == 0:
            time.sleep(4)
            return call("get_task")
        notes = [u for u in users if u.startswith("Message from")]
        return say("Got your note: " + notes[-1].split("\n", 1)[1] if notes else "No note.")
    return say("?")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, status, body, ctype="application/json"):
        raw = (json.dumps(body) if ctype == "application/json" else body).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"null") if n else None

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")

    def route(self, method):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        path = u.path
        b = self.body() if method in ("POST", "PUT") else None
        if path == "/_log":
            with LOCK:
                state = {n: {br: r["commits"][sha] for br, sha in r["branches"].items()} for n, r in REPOS.items()}
                return self.send(200, dict(LOG, state=state, pulls=PULLS))
        if path == "/api/chat":
            # Like Ollama: a tool's `required` must be a list when given (an empty Lua table encodes as {}).
            for t in b.get("tools") or []:
                req = t["function"].get("parameters", {}).get("required")
                if req is not None and not isinstance(req, list):
                    return self.send(400, {"error": "json: cannot unmarshal object into Go struct field "
                                                    ".tools.function.parameters.required of type []string"})
            msgs = b.get("messages") or []
            reply = agent(msgs)
            with LOCK:
                LOG["chats"].append({"scenario": scenario_of(msgs), "model": b.get("model"),
                                     "tools": [t["function"]["name"] for t in b.get("tools") or []],
                                     "system": next((m["content"] for m in msgs if m["role"] == "system"), ""),
                                     "messages": len(msgs)})
            if reply is None:
                return self.send(500, {"error": "the model fell over"})
            return self.send(200, json.dumps({"model": b.get("model"), "message": reply, "done": True,
                                              "prompt_eval_count": 100, "eval_count": 20}) + "\n",
                             "application/x-ndjson")
        if path == "/ghweb/login/oauth/access_token":
            with LOCK:
                LOG["oauth"].append({"code": b.get("code"), "redirect_uri": b.get("redirect_uri")})
            if b.get("client_id") != CLIENT_ID or b.get("client_secret") != CLIENT_SECRET:
                return self.send(200, {"error": "incorrect_client_credentials"})
            token = {"ok-1001": "gho_1001", "ok-both": "gho_both"}.get(b.get("code"))
            return self.send(200, {"access_token": token} if token else {"error": "bad_verification_code"})
        if path.startswith("/gh/"):
            return self.github(method, path[3:], q, b)
        self.send(404, {"message": "Not Found"})

    def token(self):
        return (self.headers.get("Authorization") or "").replace("Bearer ", "")

    def github(self, method, path, q, b):
        tok = self.token()
        with LOCK:
            LOG["github"].append({"method": method, "path": path, "token": tok[:12],
                                  "scope": (TOKENS.get(tok) or {}).get("repos")})
        m = re.match(r"^/app/installations/(\d+)/access_tokens$", path)
        if m:
            parts = tok.split(".")
            try:
                head = json.loads(base64.urlsafe_b64decode(parts[0] + "=="))
                claims = json.loads(base64.urlsafe_b64decode(parts[1] + "=="))
            except Exception:
                return self.send(401, {"message": "A JSON web token could not be decoded"})
            with LOCK:
                LOG["jwts"].append(tok)
            if head.get("alg") != "RS256" or claims.get("iss") != APP_ID or claims["exp"] - claims["iat"] > 600:
                return self.send(401, {"message": "bad app jwt"})
            inst = int(m.group(1))
            if inst not in INSTALLS:
                return self.send(404, {"message": "Not Found"})
            names = (b or {}).get("repositories")
            scope = None
            if names:
                scope = [f"{INSTALLS[inst]['login']}/{n}" for n in names]
                if any(r not in INSTALLS[inst]["repos"] for r in scope):
                    return self.send(422, {"message": "repository not in installation"})
            t = "ghs_" + uuid.uuid4().hex
            TOKENS[t] = {"install": inst, "repos": scope}
            return self.send(201, {"token": t, "expires_at": "2099-01-01T00:00:00Z"})
        if path == "/user/installations":
            ids = USER_TOKENS.get(tok)
            if ids is None:
                return self.send(401, {"message": "Bad credentials"})
            return self.send(200, {"total_count": len(ids), "installations": [
                {"id": i, "account": {"login": INSTALLS[i]["login"], "type": INSTALLS[i]["type"]},
                 "repository_selection": "selected"} for i in ids]})
        t = TOKENS.get(tok)
        if not t:
            return self.send(401, {"message": "Bad credentials"})
        if path == "/installation/repositories":
            names = t["repos"] or INSTALLS[t["install"]]["repos"]
            return self.send(200, {"total_count": len(names), "repositories": [
                {"full_name": n, "default_branch": REPOS[n]["default_branch"], "private": True, "archived": False}
                for n in names]})
        if path.startswith("/search/code"):
            words = q.get("q", "").split()
            repo = next((w[5:] for w in words if w.startswith("repo:")), None)
            term = next((w for w in words if not w.startswith("repo:")), "")
            if not self.can(t, repo):
                return self.send(422, {"message": "Validation Failed"})
            r = REPOS[repo]
            files = r["commits"][r["branches"][r["default_branch"]]]
            items = [{"path": p, "text_matches": [{"fragment": c[:80]}]} for p, c in files.items()
                     if term.lower() in c.lower()]
            return self.send(200, {"total_count": len(items), "items": items})
        m = re.match(r"^/repos/([^/]+/[^/]+)(.*)$", path)
        if not m or not self.can(t, m.group(1)):
            return self.send(404, {"message": "Not Found"})
        name, rest = m.group(1), m.group(2)
        r = REPOS[name]
        if rest == "":
            return self.send(200, {"full_name": name, "default_branch": r["default_branch"]})
        m2 = re.match(r"^/git/ref/heads/(.+)$", rest)
        if m2:
            sha = r["branches"].get(unquote(m2.group(1)))
            return self.send(200, {"object": {"sha": sha}}) if sha else self.send(404, {"message": "Not Found"})
        if rest == "/git/refs" and method == "POST":
            br = b["ref"].replace("refs/heads/", "")
            if br in r["branches"]:
                return self.send(422, {"message": "Reference already exists"})
            r["branches"][br] = b["sha"]
            return self.send(201, {"ref": b["ref"], "object": {"sha": b["sha"]}})
        m2 = re.match(r"^/git/trees/([^/?]+)$", rest)
        if m2:
            files = r["commits"].get(m2.group(1))
            if files is None:
                return self.send(404, {"message": "Not Found"})
            return self.send(200, {"tree": [{"path": p, "type": "blob"} for p in sorted(files)], "truncated": False})
        m2 = re.match(r"^/contents/(.+)$", rest)
        if m2:
            p = unquote(m2.group(1))
            if method == "GET":
                ref = q.get("ref", r["default_branch"])
                files = r["commits"].get(r["branches"].get(ref, ref))
                if files is None or p not in files:
                    return self.send(404, {"message": "Not Found"})
                c = files[p]
                return self.send(200, {"type": "file", "encoding": "base64", "sha": blob(c), "size": len(c),
                                       "content": base64.b64encode(c.encode()).decode()})
            br = b["branch"]
            if br not in r["branches"]:
                return self.send(404, {"message": "Branch not found"})
            files = dict(r["commits"][r["branches"][br]])
            if (p in files) != bool(b.get("sha")) or (p in files and blob(files[p]) != b["sha"]):
                return self.send(409, {"message": "sha does not match"})
            files[p] = base64.b64decode(b["content"]).decode()
            r["n"] += 1
            sha = "c-" + name.replace("/", "-") + "-" + str(r["n"])
            r["commits"][sha], r["branches"][br] = files, sha
            with LOCK:
                LOG["github"].append({"method": "COMMIT", "path": name + ":" + br + ":" + p, "message": b["message"]})
            return self.send(201 if not b.get("sha") else 200, {"content": {"sha": blob(files[p])},
                                                                "commit": {"sha": sha}})
        if rest == "/pulls" and method == "POST":
            key = name + ":" + b["head"]
            if b["head"] not in r["branches"] or b["base"] not in r["branches"]:
                return self.send(422, {"message": "Validation Failed"})
            if key in PULLS:
                return self.send(422, {"message": "A pull request already exists"})
            PULLS[key] = {"html_url": f"https://github.example/{name}/pull/{len(PULLS) + 1}", "base": b["base"],
                          "draft": b.get("draft"), "title": b["title"], "body": b["body"]}
            return self.send(201, PULLS[key])
        if rest.startswith("/pulls"):
            head = q.get("head", "").split(":", 1)[-1]
            p = PULLS.get(name + ":" + head)
            return self.send(200, [p] if p else [])
        return self.send(404, {"message": "Not Found"})

    def can(self, t, repo):
        if repo not in REPOS or repo not in INSTALLS[t["install"]]["repos"]:
            return False
        return t["repos"] is None or repo in t["repos"]


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("0.0.0.0", 8080), H)
    srv.serve_forever()
