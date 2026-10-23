#!/usr/bin/env python3
"""Phase 11: scalable + dynamic sending — daily limit, parallel SMTP, retries with backoff,
stuck sends recovered, "Hi there" for nameless imports, the sending summary, email images.
A tiny SMTP stub on this machine plays the workspace's own mail server."""
import base64
import os
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mktest import (  # noqa: E402
    API, P, call, check, data, enable, expect, finish, new_uuid, run_sender, sql, workspace,
)

PLUGINS = API + "/api/v2/namespace/plugins/opsapi_marketing"


class Smtp:
    """RCPT busy@ -> 451 (try later), reject@ -> 550 (never), anything else is accepted."""

    def __init__(self):
        self.messages, self.open, self.peak, self.lock = [], 0, 0, threading.Lock()
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1" if sys.platform == "darwin" else "0.0.0.0", 0))
        self.sock.listen(20)
        self.port = self.sock.getsockname()[1]
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            conn, _ = self.sock.accept()
            threading.Thread(target=self.session, args=(conn,), daemon=True).start()

    def session(self, conn):
        with self.lock:
            self.open += 1
            self.peak = max(self.peak, self.open)
        f = conn.makefile("rb")
        say = lambda s: conn.sendall(s.encode() + b"\r\n")  # noqa: E731
        try:
            say("220 stub")
            while True:
                line = f.readline().decode(errors="replace").strip()
                if not line:
                    break
                cmd = line.upper()
                if cmd.startswith("EHLO") or cmd.startswith("HELO"):
                    say("250 stub")
                elif cmd.startswith("RCPT"):
                    say("451 4.7.1 busy, try later" if "BUSY@" in cmd else
                        "550 5.1.1 no such user" if "REJECT@" in cmd else "250 ok")
                elif cmd == "DATA":
                    say("354 go")
                    body = b""
                    while not body.endswith(b"\r\n.\r\n"):
                        chunk = f.readline()
                        if not chunk:
                            return
                        body += chunk
                    time.sleep(0.5)  # slow enough for parallel connections to overlap
                    with self.lock:
                        self.messages.append(body.decode(errors="replace"))
                    say("250 queued")
                elif cmd == "QUIT":
                    say("221 bye")
                    break
                else:
                    say("250 ok")
        finally:
            with self.lock:
                self.open -= 1
            conn.close()


def setup(name, **settings):
    ns = workspace("owner_a", name, "p11-" + new_uuid()[:8])
    enable("owner_a", ns)
    base = {"dry_run": True, "quiet_hours_from": "00:00", "quiet_hours_to": "00:00",
            "marketing_frequency_cap_count": 50, "email_rate_per_min": 500,
            "sender_address": "P11 Ltd, 1 High Street, London"}
    base.update(settings)
    expect("settings " + name, call("PUT", PLUGINS, "owner_a", ns, {"settings": base}), 200)
    return ns


def settings(ns, **kw):
    expect("update settings", call("PUT", PLUGINS, "owner_a", ns, {"settings": kw}), 200)


def paste_list(ns, csv):
    lst = data(expect("list", call("POST", P + "/lists", "owner_a", ns,
                                   {"name": "L" + new_uuid()[:6], "list_type": "static", "channel": "email"}), 201))
    expect("paste import", call("POST", P + f"/lists/{lst['uuid']}/import", "owner_a", ns,
                                {"csv": csv, "grant_consent": True}), 200)
    return lst["uuid"]


def send(ns, list_uuid, **kw):
    body = {"name": "P11 " + new_uuid()[:6], "channel": "email", "message_type": "marketing",
            "subject": "Hi {{contact.first_name}}", "body_html": "<p>Hello {{contact.first_name}}</p>",
            "body_text": "Hello {{contact.first_name}}"}
    body.update(kw)
    cid = data(expect("campaign", call("POST", P + "/campaigns", "owner_a", ns, body), 201))["uuid"]
    expect("send now", call("POST", P + f"/campaigns/{cid}/schedule", "owner_a", ns,
                            {"list_uuid": list_uuid, "send_now": True}), 200)
    return cid


def states(cid):
    return sql(f"SELECT d.state, count(*) FROM mkt_deliveries d JOIN mkt_campaigns c ON c.id = d.campaign_id "
               f"WHERE c.uuid = '{cid}' GROUP BY 1 ORDER BY 1")


def one(cid, address, cols):
    return sql(f"SELECT {cols} FROM mkt_deliveries d JOIN mkt_campaigns c ON c.id = d.campaign_id "
               f"WHERE c.uuid = '{cid}' AND d.address = '{address}'")


def get(path):
    try:
        with urllib.request.urlopen(API + path, timeout=20) as r:
            return r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


# --- daily limit, nameless contacts, stuck sends (dry run) ---
W = setup("P11 limits", email_daily_limit=4, email_parallel=3)
L = paste_list(W, "email\n" + "".join(f"n{i}@p11.invalid\n" for i in range(6)))
check("no name stays empty (not 'Contact')", sql(
    f"SELECT '[' || first_name || ']' FROM crm_contacts c JOIN namespaces n ON n.id = c.namespace_id "
    f"WHERE n.uuid = '{W}' AND c.email = 'n0@p11.invalid'") == ["[]"])
counts = data(expect("people per list", call("GET", P + "/list-counts", "owner_a", W), 200))
check("list counts: 6 people", counts.get(L) == 6, counts)
cid = send(W, L)
run_sender(W)
check("daily limit: 4 sent, 2 wait", states(cid) == ["accepted|4", "queued|2"], states(cid))
check("nameless contact greeted 'Hi there'", one(cid, "n0@p11.invalid", "d.subject") == ["Hi there"],
      one(cid, "n0@p11.invalid", "d.subject"))

info = data(expect("sending summary", call("GET", P + "/sending", "owner_a", W), 200))
check("summary: limit and use", info.get("daily_limit") == 4 and info.get("sent_last_24h") == 4
      and info.get("parallel") == 3, info)
check("summary: test mode, env tag, public URL, no workspace SMTP",
      info.get("dry_run") is True and info.get("env_tag") == "[DEVELOPMENT]"
      and info.get("public_url") == "http://mkt-api.invalid" and info.get("via") != "workspace", info)
check("summary needs settings access", call("GET", P + "/sending", "owner_b", W)[0] in (403, 404))

# A send that died mid-way (worker killed) is picked up again.
sql(f"UPDATE mkt_deliveries d SET state = 'sending', updated_at = NOW() - interval '20 minutes' "
    f"FROM mkt_campaigns c WHERE c.id = d.campaign_id AND c.uuid = '{cid}' AND d.address = 'n4@p11.invalid'")
settings(W, email_daily_limit=0)
run_sender(W)
check("limit lifted + stuck send recovered: all 6 sent", states(cid) == ["accepted|6"], states(cid))
check("campaign completed", sql(f"SELECT status FROM mkt_campaigns WHERE uuid = '{cid}'") == ["completed"])

# --- the workspace's own SMTP: parallel connections, From, retries (real sends to the stub) ---
stub = Smtp()
W2 = setup("P11 smtp", dry_run=False, email_parallel=3, default_from_name="Marketing")
expect("workspace SMTP", call("PUT", API + "/api/v2/namespace/mail-settings", "owner_a", W2, {
    "host": "host.docker.internal", "port": stub.port, "security": "none",
    "from_email": "news@p11.invalid", "from_name": "P11 News", "enabled": True}), 200)
info = data(expect("sending summary (workspace SMTP)", call("GET", P + "/sending", "owner_a", W2), 200))
check("summary: workspace SMTP and its From", info.get("via") == "workspace"
      and info.get("host") == "host.docker.internal" and info.get("from_email") == "news@p11.invalid"
      and info.get("from_name") == "P11 News", info)

L2 = paste_list(W2, "email,first_name\n" + "".join(f"ok{i}@p11.invalid,Ok{i}\n" for i in range(4))
                + "busy@p11.invalid,Busy\nreject@p11.invalid,Reject\n")
c2 = send(W2, L2)
run_sender(W2)
check("4 delivered to the SMTP server", len(stub.messages) == 4 and states(c2)[0] == "accepted|4",
      {"stub": len(stub.messages), "states": states(c2)})
check("sent over parallel connections", stub.peak >= 2, stub.peak)
msg = stub.messages[0] if stub.messages else ""
check("From = the workspace SMTP's name and address (not the plugin default)",
      "P11 News" in msg and "news@p11.invalid" in msg and "From: Marketing" not in msg, msg[:400])
busy = one(c2, "busy@p11.invalid", "d.state || '|' || d.attempts || '|' || d.reason || '|' || (d.send_after > NOW())")
check("451: queued again with backoff", busy and busy[0].startswith("queued|1|retry 1:") and busy[0].endswith("|true"),
      busy)
rej = one(c2, "reject@p11.invalid", "d.state || '|' || d.attempts")
check("550: failed, not retried", rej == ["failed|0"], rej)

for _ in range(2):
    sql(f"UPDATE mkt_deliveries d SET send_after = NOW() FROM mkt_campaigns c "
        f"WHERE c.id = d.campaign_id AND c.uuid = '{c2}' AND d.state = 'queued'")
    run_sender(W2)
busy = one(c2, "busy@p11.invalid", "d.state || '|' || d.attempts")
check("gives up after 3 attempts", busy == ["failed|3"], busy)
check("campaign completed after retries", sql(f"SELECT status FROM mkt_campaigns WHERE uuid = '{c2}'") == ["completed"])

# --- a smart list can be turned into a regular one (people are then added by hand) ---
smart = data(expect("smart list", call("POST", P + "/lists", "owner_a", W,
                                       {"name": "Smart " + new_uuid()[:6], "list_type": "dynamic", "channel": "email"}), 201))
made = data(expect("make it regular", call("PUT", P + f"/lists/{smart['uuid']}", "owner_a", W, {"list_type": "static"}), 200))
check("now a regular list", made.get("list_type") == "static", made)
expect("people can be added to it", call("POST", P + f"/lists/{smart['uuid']}/import", "owner_a", W,
                                         {"csv": "email\nsmart@p11.invalid\n", "grant_consent": True}), 200)

# --- test emails go to any typed address; the chosen list saves on the email straight away ---
cmp = data(expect("draft for tests", call("POST", P + "/campaigns", "owner_a", W, {
    "name": "Tests " + new_uuid()[:6], "channel": "email", "message_type": "marketing",
    "subject": "Hi {{contact.first_name}}", "body_html": "<p>Hello</p>"}), 201))["uuid"]
lst = data(expect("list for tests", call("POST", P + "/lists", "owner_a", W,
                                         {"name": "T " + new_uuid()[:6], "list_type": "static", "channel": "email"}), 201))
saved = data(expect("choose a list", call("PUT", P + f"/campaigns/{cmp}", "owner_a", W, {"list_uuid": lst["uuid"]}), 200))
check("the list is saved on the email", str(saved.get("list_id")) == str(lst.get("id")), saved)
check("an unknown list is refused", call("PUT", P + f"/campaigns/{cmp}", "owner_a", W,
                                          {"list_uuid": new_uuid()})[0] == 400)
t = data(expect("test to a typed address", call("POST", P + f"/campaigns/{cmp}/test-send", "owner_a", W,
                                                {"email": "Me.Myself@p11.invalid"}), 200))
check("test accepted without recorded consent (dry run)", t.get("state") == "accepted", t)
check("the test address isn't added to the list", sql(
    f"SELECT count(*) FROM mkt_list_members m JOIN mkt_lists l ON l.id = m.list_id WHERE l.uuid = '{lst['uuid']}' "
    f"AND m.removed_at IS NULL") == ["0"])
check("a bad address is refused", call("POST", P + f"/campaigns/{cmp}/test-send", "owner_a", W,
                                       {"email": "not-an-email"})[0] == 400)
sql(f"""INSERT INTO mkt_suppressions (namespace_id, channel, address, reason, source)
        SELECT id, 'email', 'gone@p11.invalid', 'unsubscribe', 'unsubscribe' FROM namespaces WHERE uuid = '{W}'""")
g = data(expect("test to an unsubscribed address", call("POST", P + f"/campaigns/{cmp}/test-send", "owner_a", W,
                                                         {"email": "gone@p11.invalid"}), 200))
check("unsubscribed: not even a test", g.get("state") == "skipped" and str(g.get("reason", "")).startswith("suppressed"), g)

# --- email images ---
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
img = data(expect("upload image", call("POST", P + "/images", "owner_a", W,
                                       {"file_name": "logo.png", "content_base64": base64.b64encode(PNG).decode()}), 200))
url = img.get("url") or ""
check("public image URL", url.startswith("http://mkt-api.invalid/api/v2/opsapi-marketing/public/img/")
      and url.endswith(".png"), img)
path = url.replace("http://mkt-api.invalid", "")
st, body, hdr = get(path)
check("image served to anyone (mail clients)", st == 200 and body == PNG, st)
check("image cached for good", "immutable" in hdr.get("Cache-Control", "") and hdr.get("Content-Type") == "image/png",
      hdr)
check("SVG refused", call("POST", P + "/images", "owner_a", W, {
    "file_name": "x.svg", "content_base64": base64.b64encode(b"<svg onload=alert(1)></svg>").decode()})[0] == 400)
big = PNG[:8] + b"\0" * (2 * 1024 * 1024)
check("over 2 MB refused", call("POST", P + "/images", "owner_a", W, {
    "file_name": "big.png", "content_base64": base64.b64encode(big).decode()})[0] == 413)
check("other workspaces can't upload here", call("POST", P + "/images", "owner_b", W, {
    "file_name": "logo.png", "content_base64": base64.b64encode(PNG).decode()})[0] in (403, 404))
check("unknown image 404", get(f"/api/v2/opsapi-marketing/public/img/{new_uuid()}.png")[0] == 404)
check("bad image name 404", get("/api/v2/opsapi-marketing/public/img/..%2Fetc.png")[0] == 404)

L3 = paste_list(W, "email\nimg@p11.invalid\n")
c3 = send(W, L3, body_html=f'<p>Hi</p><img src="{url}" alt="Logo" style="max-width:100%">')
run_sender(W)
check("image kept in the sent email", any(url in r for r in one(c3, "img@p11.invalid", "d.body_html")),
      one(c3, "img@p11.invalid", "d.body_html"))

expect("turn the plugin off", call("PUT", PLUGINS, "owner_a", W, {"enabled": False}), 200)
check("images stop when the plugin is off", get(path)[0] == 404)

sys.exit(finish())
