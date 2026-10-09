"""Chat WebSocket delivery across pods (run by run.sh; python stdlib only).

  check.py cross   alice@api-a, bob@api-b, carol@api-c (REDIS_ENABLED=false):
                   sends and reactions cross pods exactly once; api-c stays local-only
  check.py down    Redis stopped: a send still answers 201 and reaches its own pod
  check.py ready N GET /ready answers N on api-a and api-b (CHAT_REQUIRE_REDIS=true), 200 on api-c
"""
import base64, hashlib, hmac, json, os, socket, sys, threading, time, urllib.request

W = "/w"
SECRET = open(f"{W}/jwt_secret").read().strip()
USERS = json.load(open(f"{W}/users.json"))
CHANNEL = open(f"{W}/channel_uuid").read().strip()
fails = 0


def check(ok, what):
    global fails
    print(("  ok   " if ok else "  FAIL ") + what, flush=True)
    fails += 0 if ok else 1


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def token(who):
    u = USERS[who]
    now = int(time.time())
    head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    body = b64(json.dumps({"userinfo": {"uuid": u["uuid"], "email": u["email"]},
                           "iat": now, "exp": now + 900, "iss": "opsapi"}).encode())
    sig = hmac.new(SECRET.encode(), f"{head}.{body}".encode(), hashlib.sha256).digest()
    return f"{head}.{body}.{b64(sig)}"


class Client:
    """Minimal RFC 6455 client: collects every text frame the server pushes."""

    def __init__(self, who, host):
        self.who, self.host, self.events = who, host, []
        self.sock = socket.create_connection((host, 80), timeout=60)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET /api/chat/ws?token={token(who)} HTTP/1.1\r\nHost: {host}\r\n"
                           "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            head += self.sock.recv(1)
        assert b" 101 " in head.split(b"\r\n")[0], head
        threading.Thread(target=self.read, daemon=True).start()

    def recv(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise EOFError
            buf += chunk
        return buf

    def read(self):
        try:
            while True:
                b0, b1 = self.recv(2)
                n = b1 & 0x7F
                if n == 126:
                    n = int.from_bytes(self.recv(2), "big")
                elif n == 127:
                    n = int.from_bytes(self.recv(8), "big")
                data = self.recv(n)
                if b0 & 0x0F == 1:
                    self.events.append(json.loads(data))
        except (EOFError, OSError):
            pass

    def got(self, typ, pred=lambda d: True):
        return [e for e in self.events if e.get("type") == typ and pred(e.get("data") or {})]

    def wait(self, typ, pred=lambda d: True, secs=5):
        end = time.time() + secs
        while time.time() < end:
            if self.got(typ, pred):
                return True
            time.sleep(0.05)
        return False


def post(who, host, path, body):
    req = urllib.request.Request(f"http://{host}{path}", data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": f"Bearer {token(who)}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, {}


def send(who, host, text):
    status, body = post(who, host, f"/api/chat/channels/{CHANNEL}/messages", {"content": text})
    data = body.get("data") or body.get("message") or body
    return status, data.get("uuid")


def is_msg(uuid):
    return lambda d: (d.get("message") or {}).get("uuid") == uuid


def connect_all(pods):
    clients = {who: Client(who, host) for who, host in pods.items()}
    for c in clients.values():
        check(c.wait("connected"), f"{c.who} connected to {c.host}")
    return clients


def cross():
    c = connect_all({"alice": "api-a", "bob": "api-b", "carol": "api-c"})
    alice, bob, carol = c["alice"], c["bob"], c["carol"]

    status, m1 = send("alice", "api-a", "hello from pod A")
    check(status in (200, 201) and m1, f"alice sends on api-a ({status})")
    check(bob.wait("message:new", is_msg(m1)), "bob on api-b receives alice's message (via Redis)")
    check(alice.wait("message:new", is_msg(m1)), "alice on api-a receives it too (same pod, direct)")

    status, m2 = send("bob", "api-b", "hello from pod B")
    check(status in (200, 201) and m2, f"bob sends on api-b ({status})")
    check(alice.wait("message:new", is_msg(m2)), "alice on api-a receives bob's message (via Redis)")

    status, _ = post("bob", "api-b", f"/api/chat/messages/{m1}/reactions/toggle", {"emoji": "👍"})
    check(status in (200, 201), f"bob reacts on api-b ({status})")
    check(alice.wait("reaction:update", lambda d: d.get("message_uuid") == m1),
          "alice on api-a receives the reaction:update (via Redis)")

    status, m3 = send("carol", "api-c", "local only")
    check(status in (200, 201) and m3, f"carol sends on api-c, REDIS_ENABLED=false ({status})")
    check(carol.wait("message:new", is_msg(m3)), "carol on api-c receives it (local delivery, as before)")

    time.sleep(2)  # anything late or duplicated has arrived by now
    for who, cl, uuid in (("alice", alice, m1), ("bob", bob, m1), ("alice", alice, m2), ("bob", bob, m2)):
        n = len(cl.got("message:new", is_msg(uuid)))
        check(n == 1, f"{who} got message {'1' if uuid == m1 else '2'} exactly once ({n})")
    check(not carol.got("message:new", is_msg(m1)), "api-c (REDIS_ENABLED=false) did not get pod A's message")
    check(not alice.got("message:new", is_msg(m3)) and not bob.got("message:new", is_msg(m3)),
          "api-c published nothing (its message stayed on api-c)")


def down():
    c = connect_all({"alice": "api-a", "bob": "api-b"})
    t = time.time()
    status, m = send("alice", "api-a", "redis is down")
    check(status in (200, 201) and m, f"send with Redis stopped still answers {status} ({time.time() - t:.2f}s)")
    check(c["alice"].wait("message:new", is_msg(m)), "alice on api-a still receives it (local fallback)")
    time.sleep(2)
    check(not c["bob"].got("message:new", is_msg(m)), "bob on api-b does not (expected while Redis is down)")


def ready():
    want = int(sys.argv[2])

    def status(host):
        try:
            with urllib.request.urlopen(f"http://{host}/ready", timeout=10) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")

    for host, expect in (("api-a", want), ("api-b", want), ("api-c", 200)):
        end = time.time() + 20
        got = status(host)
        while got[0] != expect and time.time() < end:
            time.sleep(0.5)
            got = status(host)
        check(got[0] == expect, f"{host} /ready answers {got[0]} (want {expect}) {got[1].get('reason') or ''}".rstrip())


{"cross": cross, "down": down, "ready": ready}[sys.argv[1]]()
print(f"  {sys.argv[1]}: {fails} failure(s)")
sys.exit(1 if fails else 0)
