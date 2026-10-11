#!/usr/bin/env python3
"""Live model regression for the Property PA (P03, P04, P09 so far), against a real OpsAPI + JobShout + model.

Run it before any model, provider or prompt change (docs/property-pa/01-private-endpoint.md).

  OPSAPI=https://int-opsapi.example TOKEN=<jwt or opsk_ key of an agent like Sophie> NS=<namespace slug> \\
      projects/property-pa/scripts/pa_regression.py [--reset] [--keep] [--timeout 900]

  --reset    re-seed the How It Works fixtures first (needs a manager token)
  --keep     leave the proposals for a person to look at (default: reject them, the record stays as it was)

Exit code 0 = all scenes pass.
"""
import argparse
import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "../spec/regression"))
import scenes  # noqa: E402

API = os.environ["OPSAPI"].rstrip("/") + "/api/v2/property-pa"
HEADERS = {"Authorization": "Bearer " + os.environ["TOKEN"], "X-Namespace-Slug": os.environ["NS"],
           "Content-Type": "application/json"}


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, headers=HEADERS,
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reset", action="store_true")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--timeout", type=int, default=900)
    a = ap.parse_args()
    if a.reset:
        st, res = call("POST", "/demo/reset", {})
        print("fixtures reset:", st)
    st, found = call("GET", "/people?q=" + urllib.parse.quote("22 Station Road"))
    sarah = next((p for p in (found or {}).get("data", []) if p.get("opportunity_uuid")), None) if st == 200 else None
    if not sarah:
        sys.exit(f"Sarah / 22 Station Road not found ({st}); run with --reset")
    started = datetime.datetime.now(datetime.timezone.utc)
    st, res = call("POST", "/captures/start", {"text": scenes.SCENE3_NOTE, "channel": "voice",
                                                "opportunity_uuid": sarah["opportunity_uuid"]})
    if st != 201:
        sys.exit(f"capture didn't start: {st} {res}")
    it, pa = res["data"]["interaction"]["uuid"], res["data"]["pa"]
    if pa.get("error"):
        sys.exit("the PA wasn't asked: " + pa["error"])
    print(f"scene 3: voice note captured ({it}); waiting for the PA…")
    deadline = time.time() + a.timeout
    sheet = None
    while time.time() < deadline:
        st, res = call("GET", f"/interactions/{it}/capture")
        sheet = res.get("data") if st == 200 else None
        run = (sheet or {}).get("run") or {}
        if run and run.get("status") != "running":
            break
        time.sleep(10)
    run = (sheet or {}).get("run") or {}
    took = (datetime.datetime.now(datetime.timezone.utc) - started).total_seconds()
    print(f"  run {run.get('status')} in {took:.0f}s, model {run.get('model')}, prompt {run.get('prompt_version')}")
    rows = (sheet or {}).get("proposals") or []
    problems = scenes.compare_scene3(rows, started) if run.get("status") == "succeeded" else ["run did not succeed"]
    for r in rows:
        print(f"  - {r['label']}: {json.dumps(r.get('new_value'))[:90]} [{r['kind_label']}]")
    for p in problems:
        print("  FAIL", p)
    if not a.keep and rows:
        call("POST", f"/interactions/{it}/decide", {"decisions": [{"uuid": r["uuid"], "action": "reject"}
                                                                  for r in rows if r["status"] == "proposed"]})
    print("P03/P04/P09:", "PASS" if not problems else "FAIL")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
