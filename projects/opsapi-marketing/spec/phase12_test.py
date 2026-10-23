#!/usr/bin/env python3
"""Phase 12: the unsubscribe and preferences pages. Opening a link changes nothing (mail
scanners open links); pressing the button does; mail apps' one-click POST works; "Subscribe
again" undoes it; links never expire; broken links get a page, not JSON."""
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mktest import (  # noqa: E402
    API, P, SECRET, call, check, data, enable, expect, finish, new_uuid, sql, workspace,
)

PLUGINS = API + "/api/v2/namespace/plugins/opsapi_marketing"
UNSUB = API + "/api/v2/opsapi-marketing/public/unsubscribe"
PREFS = API + "/api/v2/opsapi-marketing/public/preferences"


def mint(claims):
    """The same signed token the server puts in emails (base64url(json).hmac_sha256_hex)."""
    payload = base64.urlsafe_b64encode(json.dumps(claims, separators=(",", ":")).encode()).rstrip(b"=").decode()
    return payload + "." + hmac.new(SECRET.encode(), payload.encode(), hashlib.sha256).hexdigest()


def http(method, url, form=None):
    body = urllib.parse.urlencode(form).encode() if form is not None else None
    req = urllib.request.Request(url, data=body, method=method,
                                 headers={"Content-Type": "application/x-www-form-urlencoded"} if body else {})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode(), r.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(), e.headers.get("Content-Type", "")


W = workspace("owner_a", "P12 Unsubscribe Ltd", "p12-" + new_uuid()[:8])
enable("owner_a", W)
expect("settings", call("PUT", PLUGINS, "owner_a", W, {"settings": {
    "dry_run": True, "sender_address": "P12 Ltd, 2 Market Street, Leeds"}}), 200)
lst = data(expect("list", call("POST", P + "/lists", "owner_a", W,
                               {"name": "L12", "list_type": "static", "channel": "email"}), 201))
expect("add a person", call("POST", P + f"/lists/{lst['uuid']}/import", "owner_a", W,
                            {"csv": "email,first_name\nsam@p12.invalid,Sam\n", "grant_consent": True}), 200)
ns_id = int(sql(f"SELECT id FROM namespaces WHERE uuid = '{W}'")[0])
cu = sql(f"SELECT c.uuid FROM crm_contacts c WHERE c.namespace_id = {ns_id} AND c.email = 'sam@p12.invalid'")[0]
now = int(time.time())
tok = mint({"purpose": "unsubscribe", "namespace_id": ns_id, "contact_uuid": cu, "channel": "email",
            "list_id": int(lst["id"]), "iat": now, "exp": now + 3600})


def suppressed():
    return sql(f"SELECT coalesce(string_agg(source, ','), '-') FROM mkt_suppressions WHERE namespace_id = {ns_id} "
               f"AND address = 'sam@p12.invalid'")[0]


st, html, ctype = http("GET", UNSUB + "?token=" + urllib.parse.quote(tok))
check("opening the link shows a page", st == 200 and "text/html" in ctype and "Unsubscribe from" in html
      and "P12 Unsubscribe Ltd" in html and "sam@p12.invalid" in html, (st, html[:300]))
check("opening the link changes nothing (scanners)", suppressed() == "-", suppressed())
check("page shows the business address", "2 Market Street" in html)

st, html, _ = http("POST", UNSUB, {"token": tok, "action": "unsubscribe"})
check("pressing Unsubscribe unsubscribes", st == 200 and "unsubscribed" in html and suppressed() == "unsubscribe_page",
      (st, suppressed()))
check("…and offers Subscribe again", "Subscribe again" in html)
st, html, _ = http("GET", UNSUB + "?token=" + urllib.parse.quote(tok))
check("opening the link again says they're unsubscribed", "You’re unsubscribed" in html, html[:200])

st, html, _ = http("POST", UNSUB, {"token": tok, "action": "resubscribe"})
sub = sql(f"SELECT s.status || '|' || coalesce(s.legal_basis, '') FROM mkt_subscriptions s "
          f"WHERE s.namespace_id = {ns_id} AND s.contact_uuid = '{cu}' AND s.list_id = {lst['id']}")
check("Subscribe again undoes it, as their consent", st == 200 and suppressed() == "-"
      and sub == ["subscribed|consent"], (suppressed(), sub))

st, body, _ = http("POST", UNSUB + "?token=" + urllib.parse.quote(tok), {"List-Unsubscribe": "One-Click"})
check("mail apps' one-click button still works", st == 200 and '"success":true' in body.replace(" ", "")
      and suppressed() == "list_unsubscribe_post", (st, body, suppressed()))

old = mint({"purpose": "unsubscribe", "namespace_id": ns_id, "contact_uuid": cu, "channel": "email",
            "iat": now - 400 * 86400, "exp": now - 300 * 86400})
st, html, _ = http("GET", UNSUB + "?token=" + urllib.parse.quote(old))
check("a link from a year-old email still works", st == 200 and "You’re unsubscribed" in html, (st, html[:200]))

st, html, ctype = http("GET", UNSUB + "?token=broken")
check("a broken link gets a page, not JSON", st == 400 and "text/html" in ctype and "isn’t working" in html,
      (st, ctype))
forged = mint({"purpose": "unsubscribe", "namespace_id": ns_id, "contact_uuid": cu}).rsplit(".", 1)[0] + "." + "0" * 64
check("a forged link is refused", http("GET", UNSUB + "?token=" + forged)[0] == 400)

ptok = mint({"purpose": "preferences", "namespace_id": ns_id, "contact_uuid": cu, "iat": now, "exp": now + 3600})
st, html, _ = http("GET", PREFS + "?token=" + urllib.parse.quote(ptok))
check("preferences is a page", st == 200 and "Your preferences" in html and "Marketing emails" in html
      and "Turn on" in html, (st, html[:300]))
st, html, _ = http("POST", PREFS, {"token": ptok, "channel": "email", "action": "start"})
check("preferences: turn emails back on", "again" in html and suppressed() == "-", suppressed())
st, html, _ = http("POST", PREFS, {"token": ptok, "channel": "email", "action": "stop"})
check("preferences: turn emails off", "won’t get" in html and suppressed() == "preferences_page", suppressed())
check("preferences: a click-tracking token is refused",
      http("GET", PREFS + "?token=" + urllib.parse.quote(tok))[0] == 400)

# --- the Unsubscribed page: the business can't undo someone's unsubscribe, only its own blocks ---
sam = sql(f"SELECT uuid FROM mkt_suppressions WHERE namespace_id = {ns_id} AND address = 'sam@p12.invalid'")[0]
st, body = call("DELETE", P + f"/suppressions/{sam}", "owner_a", W)
check("can't remove someone who unsubscribed", st == 409 and suppressed() == "preferences_page", (st, body))
check("no generic edit", call("PUT", P + f"/suppressions/{sam}", "owner_a", W, {"source": "manual"})[0] in (404, 405))
blk = data(expect("block an address", call("POST", P + "/suppressions", "owner_a", W,
                                           {"address": " Spam@P12.invalid ", "notes": "asked us by phone"}), 201))
check("blocked, tidied", blk.get("address") == "spam@p12.invalid" and blk.get("reason") == "blocked"
      and blk.get("source") == "manual", blk)
again = data(expect("block it again", call("POST", P + "/suppressions", "owner_a", W, {"address": "spam@p12.invalid"}), 200))
check("…is the same block", again.get("uuid") == blk.get("uuid"))
expect("block a mobile", call("POST", P + "/suppressions", "owner_a", W, {"address": "07700 900123", "channel": "sms"}), 201)
check("mobile stored as +44", sql(f"SELECT count(*) FROM mkt_suppressions WHERE namespace_id = {ns_id} "
                                  f"AND address = '+447700900123' AND channel = 'sms'") == ["1"])
expect("a bad address is refused", call("POST", P + "/suppressions", "owner_a", W, {"address": "not an email"}), 422)
expect("remove your own block", call("DELETE", P + f"/suppressions/{blk['uuid']}", "owner_a", W), 200)
check("…it's gone", sql(f"SELECT count(*) FROM mkt_suppressions WHERE namespace_id = {ns_id} "
                        f"AND address = 'spam@p12.invalid'") == ["0"])

# --- the ready-made templates: all added, each renders cleanly with the person's name ---
seeded = data(expect("add ready-made templates", call("POST", P + "/templates/seed", "owner_a", W, {}), 200))
rows = sql(f"SELECT name || '|' || channel FROM mkt_templates WHERE namespace_id = {ns_id} ORDER BY id")
check("14 email + 3 text templates", len([r for r in rows if r.endswith("|email")]) == 14
      and len([r for r in rows if r.endswith("|sms")]) == 3, rows)
for r in rows:
    name, channel = r.rsplit("|", 1)
    t = sql(f"SELECT uuid FROM mkt_templates WHERE namespace_id = {ns_id} AND name = $q${name}$q$")[0]
    tpl = data(call("GET", P + f"/templates/{t}", "owner_a", W)[1])
    pv = data(expect(f"preview {name}", call("POST", P + "/templates/preview", "owner_a", W, {"template": {
        "channel": channel, "subject": tpl.get("subject"), "body_html": tpl.get("body_html"),
        "body_text": tpl.get("body_text")}, "sample": {"contact": {"first_name": "Sam"}}}), 200))
    out = (pv.get("html") or "") + (pv.get("text") or "")
    check(f"{name}: greets Sam, no leftover merge tags", "Sam" in out and "{{contact" not in out, out[:200])

sys.exit(finish())
