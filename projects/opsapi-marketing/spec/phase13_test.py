#!/usr/bin/env python3
"""Phase 13: "View this email in your browser". {{view_online_url}} is a known merge field
(analyse / publish / validate accept it, previews fill it in); every sent email carries a signed
link; opening it shows the same personalised email as a web page — no merge tags left, no open
pixel, not counted as an open, noindex, scripts blocked. Broken, expired, wrong-purpose and
other-workspace links get a page, never someone's email."""
import base64
import hashlib
import hmac
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mktest import (  # noqa: E402
    API, P, SECRET, USERS, call, check, data, enable, expect, finish, new_uuid, run_sender, sql, workspace,
)

PLUGINS = API + "/api/v2/namespace/plugins/opsapi_marketing"
VIEW = API + "/api/v2/opsapi-marketing/public/view"
OWNER = USERS["owner_a"][0]
VIEW_RE = re.compile(r'href="(http://mkt-api\.invalid/api/v2/opsapi-marketing/public/view\?token=[^"]+)"')


def mint(claims):
    """The same signed token the server puts in emails (base64url(json).hmac_sha256_hex)."""
    payload = base64.urlsafe_b64encode(json.dumps(claims, separators=(",", ":")).encode()).rstrip(b"=").decode()
    return payload + "." + hmac.new(SECRET.encode(), payload.encode(), hashlib.sha256).hexdigest()


def get(url):
    try:
        with urllib.request.urlopen(urllib.request.Request(url), timeout=30) as r:
            return r.status, r.read().decode(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(), dict(e.headers)


def local(url):
    """Emails link the public base (http://mkt-api.invalid); open them on the test server."""
    return url.replace("http://mkt-api.invalid", API)


BODY = ('<p style="font-size:12px">Trouble viewing? <a href="{{view_online_url}}">View this email in your browser</a></p>'
        '<p>Hello {{contact.first_name}}, here is our news.</p>'
        '<p><a href="https://example.org/offer">See the offer</a></p>'
        '<p><a href="{{unsubscribe_url}}">Unsubscribe</a> · <a href="{{preferences_url}}">Preferences</a></p>')

W = workspace("owner_a", "P13 View Online Ltd", "p13-" + new_uuid()[:8])
enable("owner_a", W)
expect("settings", call("PUT", PLUGINS, "owner_a", W, {"settings": {
    "dry_run": True, "quiet_hours_from": "00:00", "quiet_hours_to": "00:00",
    "marketing_frequency_cap_count": 50, "sender_address": "P13 Ltd, 3 Mill Lane, York"}}), 200)
ns_id = int(sql(f"SELECT id FROM namespaces WHERE uuid = '{W}'")[0])

# --- the merge field ------------------------------------------------------------------------
fields = data(expect("merge fields", call("GET", P + "/merge-fields", "owner_a", W), 200))
keys = [f.get("key") for f in (fields if isinstance(fields, list) else fields.get("items") or fields.get("fields") or [])]
check("view_online_url is a built-in merge field", "view_online_url" in keys, keys)

an = data(expect("analyse", call("POST", P + "/templates/analyse", "owner_a", W, {
    "channel": "email", "subject": "News for {{contact.first_name}}", "body_html": BODY}), 200))
check("analyse: view_online_url is not unknown", "view_online_url" not in (an.get("unknown_merge") or [])
      and "view_online_url" in (an.get("merge_fields") or []), an)

pv = data(expect("preview", call("POST", P + "/templates/preview", "owner_a", W, {"template": {
    "channel": "email", "subject": "News", "body_html": BODY}}), 200))
check("preview fills in a sample view link", "https://example.com/view" in (pv.get("html") or ""),
      (pv.get("html") or "")[:300])

tpl = data(expect("create template", call("POST", P + "/templates", "owner_a", W, {
    "name": "P13 view", "channel": "email", "subject": "News for {{contact.first_name}}",
    "body_html": BODY, "body_text": "Hello {{contact.first_name}}. Online: {{view_online_url}}", "status": "draft"}), 201))
pub = data(expect("publish a template using {{view_online_url}}",
                  call("POST", P + f"/templates/{tpl['uuid']}/publish", "owner_a", W, {}), 200))
check("published", pub.get("status") == "published", pub)

# --- a real send ----------------------------------------------------------------------------
cu = new_uuid()
sql(f"""INSERT INTO crm_contacts (uuid, namespace_id, first_name, last_name, email, owner_user_uuid, status,
        created_at, updated_at)
        SELECT '{cu}', id, 'Priya', 'Thirteen', 'priya@p13.invalid', '{OWNER}', 'active', now(), now()
        FROM namespaces WHERE uuid = '{W}'""")
expect("opt-in", call("POST", P + "/consent/opt-in", "owner_a", W,
                      {"contact_uuid": cu, "channel": "email", "source": "form"}), 200)
lst = data(expect("list", call("POST", P + "/lists", "owner_a", W,
                               {"name": "L13", "list_type": "static", "channel": "email"}), 201))
expect("member", call("POST", P + f"/lists/{lst['uuid']}/members", "owner_a", W, {"contact_uuid": cu}), 201)
cid = data(expect("campaign", call("POST", P + "/campaigns", "owner_a", W, {
    "name": "P13 news", "channel": "email", "message_type": "marketing",
    "subject": "News for {{contact.first_name}}", "body_html": BODY,
    "body_text": "Hello {{contact.first_name}}. Online: {{view_online_url}}"}), 201))["uuid"]
expect("validate (view_online_url accepted)", call("POST", P + f"/campaigns/{cid}/validate", "owner_a", W,
                                                  {"list_uuid": lst["uuid"]}), 200)
expect("send now", call("POST", P + f"/campaigns/{cid}/schedule", "owner_a", W, {"send_now": True}), 200)
for _ in range(5):
    run_sender(W)
    if sql(f"SELECT count(*) FROM mkt_deliveries d JOIN mkt_campaigns c ON c.id = d.campaign_id "
           f"WHERE c.uuid = '{cid}' AND d.state = 'accepted'") == ["1"]:
        break

row = sql(f"SELECT d.uuid || '|' || replace(coalesce(d.body_html, ''), E'\\n', ' ') FROM mkt_deliveries d "
          f"JOIN mkt_campaigns c ON c.id = d.campaign_id WHERE c.uuid = '{cid}' AND d.state = 'accepted'")
check("campaign sent", len(row) == 1, row)
d_uuid, sent_html = (row[0].split("|", 1) if row else ("", ""))
m = VIEW_RE.search(sent_html)
check("the sent email carries a view-in-browser link", m is not None, sent_html[:400])
check("the view link isn't wrapped in click tracking", m is not None and "/public/c?" not in m.group(1))
check("the sent email has the open pixel (so the browser copy must drop it)", "/public/o.gif" in sent_html)
text = sql(f"SELECT replace(coalesce(d.body_text, ''), E'\\n', ' ') FROM mkt_deliveries d WHERE d.uuid = '{d_uuid}'")
check("the plain-text email has the view link too", bool(text) and "/public/view?token=" in text[0], text)
view_url = local(m.group(1)) if m else VIEW + "?token=missing"

# --- the browser copy -----------------------------------------------------------------------
st, html, hdr = get(view_url)
h = {k.lower(): v for k, v in hdr.items()}
check("view page is 200 HTML", st == 200 and "text/html" in h.get("content-type", ""), (st, h))
check("personalised: greets Priya", "Hello Priya" in html, html[:400])
check("no merge tags left", "{{" not in html and "{%" not in html, html[:400])
check("no open pixel", "o.gif" not in html, html[-400:])
check("a whole document with the subject as title", html.lower().startswith("<!doctype html")
      and "<title>News for Priya</title>" in html, html[:300])
check("working unsubscribe link", "/public/unsubscribe?token=" in html)
check("working preferences link", "/public/preferences?token=" in html)
check("the view link inside is the same link", m is not None and m.group(1) in html)
check("noindex", "noindex" in h.get("x-robots-tag", ""), h)
check("private, no-store", "no-store" in h.get("cache-control", "") and "private" in h.get("cache-control", ""), h)
check("no referrer", h.get("referrer-policy") == "no-referrer", h)
csp = h.get("content-security-policy", "")
check("CSP blocks scripts, allows email images", "default-src 'none'" in csp and "img-src https: data:" in csp
      and "script-src" not in csp and "frame-ancestors 'none'" in csp, csp)
opened = sql(f"SELECT coalesce(opened_at::text, 'null') FROM mkt_deliveries WHERE uuid = '{d_uuid}'")
opens = sql(f"SELECT count(*) FROM mkt_tracking_events e JOIN mkt_deliveries d ON d.id = e.delivery_id "
            f"WHERE d.uuid = '{d_uuid}' AND e.event_type = 'open'")
check("viewing is not counted as an open", opened == ["null"] and opens == ["0"], (opened, opens))

# --- bad links ------------------------------------------------------------------------------
now = int(time.time())
st, html, hdr = get(VIEW + "?token=broken")
check("broken link → 400 page", st == 400 and "isn’t working" in html and "Priya" not in html, (st, html[:200]))
forged = (view_url.split("token=", 1)[1].rsplit(".", 1)[0]) + "." + "0" * 64
check("forged link → 400", get(VIEW + "?token=" + forged)[0] == 400)
old = mint({"purpose": "view_online", "namespace_id": ns_id, "delivery_uuid": d_uuid,
            "iat": now - 400 * 86400, "exp": now - 35 * 86400})
st, html, _ = get(VIEW + "?token=" + urllib.parse.quote(old))
check("expired link → 400 page", st == 400 and "Priya" not in html, (st, html[:200]))
wrong = mint({"purpose": "preferences", "namespace_id": ns_id, "contact_uuid": cu, "iat": now, "exp": now + 3600})
check("a preferences token can't open the email", get(VIEW + "?token=" + urllib.parse.quote(wrong))[0] == 400)

# Another workspace's token can't read this workspace's delivery.
W2 = workspace("owner_b", "P13 Other Ltd", "p13b-" + new_uuid()[:8])
enable("owner_b", W2)
ns2 = int(sql(f"SELECT id FROM namespaces WHERE uuid = '{W2}'")[0])
other = mint({"purpose": "view_online", "namespace_id": ns2, "delivery_uuid": d_uuid, "iat": now, "exp": now + 3600})
st, html, _ = get(VIEW + "?token=" + urllib.parse.quote(other))
check("other workspace's token → no longer available, no content", st == 404 and "no longer available" in html
      and "Priya" not in html, (st, html[:300]))

# Gone: the contact deleted → a friendly 404, not the email.
sql(f"UPDATE crm_contacts SET deleted_at = now() WHERE uuid = '{cu}'")
st, html, _ = get(view_url)
check("deleted contact → 404 no longer available", st == 404 and "no longer available" in html
      and "Priya" not in html, (st, html[:300]))

sys.exit(finish())
