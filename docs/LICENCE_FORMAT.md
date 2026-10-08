# OpsAPI licence and entitlement token format (v1)

Status: **proposed v1**, for approval with docs/BILLING_ENTITLEMENTS.md. Nothing ships until it is approved.

This document is for developers of apps that check OpsAPI licences or entitlements: desktop apps (Swift,
C#, Kotlin, Rust, Electron), self-hosted servers and web back ends. Everything here can be built from this
page alone. The TypeScript SDK (`@opsapi/client/billing`) is only a convenience.

OpsAPI issues two kinds of signed token:

| Token | `typ` header | Who gets it | Used for |
|---|---|---|---|
| **Licence file** | `opsapi-license+jwt` | A machine that activated a licence key | Desktop and self-hosted apps, checked **offline** |
| **Entitlement token** | `opsapi-entitlements+jwt` | Your server, with its secret key | Web/SaaS back ends, cached between checks |

Both are compact JWS (the JWT wire format), signed with **ES256** (ECDSA on P-256 with SHA-256) and nothing
else. ES256 verification is built into WebCrypto, Apple CryptoKit, the JVM, .NET, Go, Rust and Python.

## 1. Header

```json
{ "alg": "ES256", "typ": "opsapi-license+jwt", "kid": "billing-2026-01" }
```

- `alg` is always `ES256`. **Reject every other value**, including `none` and any `HS…`.
- `typ` names the token kind. Reject a licence file where you expect an entitlement token, and the reverse.
- `kid` names the signing key in the JWKS (§3).

## 2. Claims

| Claim | Type | Licence file | Entitlement token | Meaning |
|---|---|---|---|---|
| `ver` | integer | ✓ | ✓ | Format version, `1`. Reject versions you don't know |
| `iss` | string | ✓ | ✓ | The OpsAPI that signed it, e.g. `https://api.example.com`. Pin it if you can |
| `aud` | string | ✓ | ✓ | Your app's id (UUID). Must equal your app id |
| `sub` | string | licence id | your user id | Whom it is about. Licence files: the licence's UUID. Entitlement tokens: the customer's `external_id` (your own user id) |
| `iat` | integer | ✓ | ✓ | Issued at (Unix seconds) |
| `exp` | integer | ✓ | ✓ | Refresh by. After it, ask OpsAPI for a fresh one when you can |
| `grace_until` | integer | ✓ | ✓ | Valid without refreshing until here (= `exp` + the app's grace) |
| `plan_key` | string or null | ✓ | ✓ | The plan that decides access, e.g. `pro` |
| `status` | string | — | ✓ | `free`, `granted`, `active`, `trialing`, `past_due`, `purchased` or `none` |
| `features` | object | ✓ | ✓ | Resolved features: `true`/`false` for on/off features; a number for limits; `null` = unlimited. Missing key = off / 0 |
| `access_until` | integer or null | ✓ | ✓ | Access ends here (fixed-term pass, end of paid period). `null` = no end (perpetual) |
| `updates_until` | integer or null | ✓ | ✓ | New releases are covered until here. `null` = all future releases (§5.3) |
| `fingerprint_hash` | string | ✓ | — | The machine this file was activated on (§6) |
| `offline_policy` | string | ✓ | ✓ | `fail_closed` or `fail_open`: what to do after `grace_until` when OpsAPI can't be reached (§5.2) |

Verifiers **must ignore claims they don't know**. New optional claims can appear in v1. Anything that
changes the meaning of an existing claim gets `ver: 2`.

Example licence file payload (test vector L1):

```json
{
  "ver": 1,
  "iss": "https://billing.example.test",
  "aud": "8b0c7e0e-5d2a-4f43-9c1e-2a6f0d3b7c11",
  "sub": "3d5e8f20-6b1a-4c9e-a7d4-0f2b9c8e1a55",
  "iat": 1767225600,
  "exp": 1767830400,
  "grace_until": 1770422400,
  "plan_key": "pro",
  "features": {
    "export_pdf": true,
    "projects": 10,
    "seats": null
  },
  "access_until": null,
  "updates_until": 1798761600,
  "fingerprint_hash": "300f03f0619eebec6e53c02276ceb4825649d7b8f396be23c3e53f24cabc7011",
  "offline_policy": "fail_closed"
}
```

Example entitlement token payload (test vector E1):

```json
{
  "ver": 1,
  "iss": "https://billing.example.test",
  "aud": "8b0c7e0e-5d2a-4f43-9c1e-2a6f0d3b7c11",
  "sub": "user_42",
  "iat": 1767225600,
  "exp": 1767226500,
  "grace_until": 1767485700,
  "plan_key": "pro",
  "status": "active",
  "features": {
    "export_pdf": true,
    "projects": 10,
    "seats": null
  },
  "access_until": 1769904000,
  "updates_until": null,
  "offline_policy": "fail_closed"
}
```

## 3. Keys (JWKS)

- Public keys are served at `GET {iss}/api/v2/public/billing/jwks.json` (cacheable for 5 minutes).
- Each key is an EC P-256 JWK with `kid`, `alg: ES256` and `use: sig`.
- **Rotation:** a new key gets a new `kid`. Old public keys stay in the JWKS until every token they signed is
  past its `grace_until`, then they are removed.
- **Desktop apps:** ship a copy of the JWKS in the app, so the first start works offline. When you meet an
  unknown `kid` while online, fetch the JWKS **once** and retry. Never fetch keys from a URL found inside a
  token.
- The private key never leaves the OpsAPI server (`BILLING_SIGNING_KEY`).

## 4. Verifying, step by step

Stop at the first failure. The reference verifiers in §9 do exactly this.

1. Split the token on `.` into exactly three parts: `header`, `payload`, `signature`. Each is base64url
   without padding.
2. Decode the header. `alg` must be `ES256`, and `typ` must be the kind you expect. (`bad_alg`, `bad_type`)
3. Find the JWK whose `kid` equals the header's `kid`. If there is none, refetch the JWKS once (online) and
   retry; otherwise fail. (`unknown_key`)
4. Verify the ECDSA P-256 / SHA-256 signature over the ASCII bytes of `header + "." + payload` (the two
   base64url strings joined by a dot). The signature is **64 raw bytes, r then s** (IEEE P1363), not DER.
   Convert if your library wants DER (§8). (`bad_signature`)
5. Decode the payload. `ver` must be `1`. (`bad_version`)
6. `aud` must equal your app id. If you pinned your OpsAPI URL, `iss` must equal it. (`wrong_app`, `wrong_issuer`)
7. Licence files only: `fingerprint_hash` must equal the hash you compute for this machine (§6). (`wrong_machine`)
8. Check time (§5) and apply the result.

## 5. Time

### 5.1 Effective time and clock tampering

Use `t = max(now, high_water, iat − 300)`:
- 300 seconds is the tolerated clock skew. The same 300 is added to `access_until`, `exp` and `grace_until`.
- `high_water` is the latest time this app has seen: `max(previous high_water, now, iat)`. Persist it
  after every check (alongside the licence file is fine).

**If the clock moves backwards**, `t` doesn't: a user can't extend the grace period by turning the clock
back. If the clock is behind the token (`now < iat`), the token's own issue time is used.

Optional: if `now` is far behind `high_water` (say more than a day), warn the user that the clock looks wrong.
Keep working with `high_water`.

### 5.2 Decision

Check in this order:

| Condition | State | What the app does |
|---|---|---|
| `access_until` set and `t > access_until + 300` | `access_ended` | Deny. The pass or paid period is over: offer renewal |
| `t <= exp + 300` | `valid` | Allow |
| `t <= grace_until + 300` | `refresh` | Allow, and refresh in the background when online |
| otherwise | `past_grace` | Refresh now. If OpsAPI answers, its answer decides. If it can't be reached: `fail_closed` → deny until a refresh works; `fail_open` → allow, and keep trying |

A refresh is `POST /api/v2/public/licenses/validate` (licence files) or the entitlement check (tokens). It
returns a new token, or an error such as `license_revoked` that you must obey even inside the grace period.

**Recommended settings** (per app, in the dashboard):
- Desktop / self-hosted: `fail_closed`, refresh every 7 days, 30 days of grace. Customers can be offline
  for a month, and revocation reaches them within 37 days.
- Web / SaaS back ends: `fail_closed`, 15-minute tokens, 3 days of grace. Your server is online, so the
  grace only covers OpsAPI outages.

### 5.3 Updates (`updates_until`)

`features` is already resolved for the licence's update window: features released after `updates_until`
are not in it. For **app versions**, compare your build's release date with `updates_until`:
- if the build is newer, this licence doesn't cover this version;
- the app can say so, and offer an upgrade or the last covered version.

`null` means every version is covered.

## 6. Machine fingerprints

Apps send a **hash** and never a raw hardware id:

```
machine_id       = lowercase(trim(<stable id for this machine>))
fingerprint_hash = lowercase hex( SHA-256( UTF-8( fingerprint_salt + ":" + machine_id ) ) )
```

- `fingerprint_salt` is published per app (dashboard, and `GET /api/v2/public/billing/apps/{app}`), so the
  same machine has a different hash in every app and hashes can't be linked across apps.
- OpsAPI stores only this hash.

Stable machine ids:

| Platform | Source | How to read it |
|---|---|---|
| macOS | `IOPlatformUUID` | IOKit `IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformUUIDKey)`, or `ioreg -rd1 -c IOPlatformExpertDevice` |
| Windows | `MachineGuid` | Registry `HKLM\SOFTWARE\Microsoft\Cryptography`, value `MachineGuid`. Read the 64-bit view from 32-bit processes |
| Linux | `machine-id` | `/etc/machine-id`, else `/var/lib/dbus/machine-id` |
| Containers / self-hosted | install id | A random UUID generated on first start and kept in the app's data volume. `/etc/machine-id` is often missing or shared in containers |

Don't use MAC addresses, disk serials or IP addresses: they change, and some of them are personal data.
Cloned VMs share a machine id. The app's activation limit and "free a seat" handle that.

Test vector: salt `f3a9c1d27b4e8a6055c0e1b2d3f4a5b6`, raw id `"  1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D "` → machine_id `1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d` →
fingerprint_hash `300f03f0619eebec6e53c02276ceb4825649d7b8f396be23c3e53f24cabc7011`.

## 7. Test vectors

Everything below is in **[licence-format-vectors.json](licence-format-vectors.json)** too: the keys, all tokens,
and every case with its expected result. Load that file in your test suite. The keys are **TEST ONLY**:
they are published, so never use them for anything real.

- App id (`aud`): `8b0c7e0e-5d2a-4f43-9c1e-2a6f0d3b7c11`
- Issuer (`iss`): `https://billing.example.test`

### 7.1 JWKS

```json
{
  "keys": [
    {
      "kty": "EC",
      "crv": "P-256",
      "x": "7AM0h4qC2DspKjEG-IDTPodKQnBh2P3ae1DOMC_qWj8",
      "y": "gLLG-ZpW5KIZMuBE8K78J0MuGs55dXuHQVCMxpVRmu4",
      "kid": "test-2026-01",
      "alg": "ES256",
      "use": "sig"
    },
    {
      "kty": "EC",
      "crv": "P-256",
      "x": "zW9l-AgGkSzsgLNHkbOdEY5FFnKWcSMcE-WlT3Wiecc",
      "y": "gOKkRyk9YptnrFmxnFZnof-DueJKuJS_L0Gd7YQLgpc",
      "kid": "test-2025-07",
      "alg": "ES256",
      "use": "sig"
    }
  ]
}
```

Private keys (JWK `d`, test only):

```json
[
  {
    "kty": "EC",
    "crv": "P-256",
    "x": "7AM0h4qC2DspKjEG-IDTPodKQnBh2P3ae1DOMC_qWj8",
    "y": "gLLG-ZpW5KIZMuBE8K78J0MuGs55dXuHQVCMxpVRmu4",
    "kid": "test-2026-01",
    "alg": "ES256",
    "use": "sig",
    "d": "NvmfI1DawkSstG7kM64Li4UQCi6nrz82tnXMora-egE"
  },
  {
    "kty": "EC",
    "crv": "P-256",
    "x": "zW9l-AgGkSzsgLNHkbOdEY5FFnKWcSMcE-WlT3Wiecc",
    "y": "gOKkRyk9YptnrFmxnFZnof-DueJKuJS_L0Gd7YQLgpc",
    "kid": "test-2025-07",
    "alg": "ES256",
    "use": "sig",
    "d": "e1jVX-HX7KnGe0_MMkYTUBkr2TeIZVx0GCBqz08-X4M"
  }
]
```

### 7.2 Tokens

| Name | What it is |
|---|---|
| L1 | Valid licence file: `pro`, perpetual access, updates until 2027-01-01, refresh every 7 days, 30 days of grace |
| L2 | L1 with `projects` changed to 1000 after signing |
| L3 | L1 with `"alg": "none"` and no signature |
| L4 | L1 signed with the previous key `test-2025-07` (still in the JWKS) |
| L5 | L1 signed with a `kid` that isn't in the JWKS |
| L6 | A 30-day pass: `access_until` = 2026-01-31 |
| L7 | L1 issued for another app |
| L8 | L1 with `ver: 2` |
| E1 | Entitlement token for `user_42`: 15-minute token, 3 days of grace |

```
L1  eyJhbGciOiJFUzI1NiIsInR5cCI6Im9wc2FwaS1saWNlbnNlK2p3dCIsImtpZCI6InRlc3QtMjAyNi0wMSJ9.eyJ2ZXIiOjEsImlzcyI6Imh0dHBzOi8vYmlsbGluZy5leGFtcGxlLnRlc3QiLCJhdWQiOiI4YjBjN2UwZS01ZDJhLTRmNDMtOWMxZS0yYTZmMGQzYjdjMTEiLCJzdWIiOiIzZDVlOGYyMC02YjFhLTRjOWUtYTdkNC0wZjJiOWM4ZTFhNTUiLCJpYXQiOjE3NjcyMjU2MDAsImV4cCI6MTc2NzgzMDQwMCwiZ3JhY2VfdW50aWwiOjE3NzA0MjI0MDAsInBsYW5fa2V5IjoicHJvIiwiZmVhdHVyZXMiOnsiZXhwb3J0X3BkZiI6dHJ1ZSwicHJvamVjdHMiOjEwLCJzZWF0cyI6bnVsbH0sImFjY2Vzc191bnRpbCI6bnVsbCwidXBkYXRlc191bnRpbCI6MTc5ODc2MTYwMCwiZmluZ2VycHJpbnRfaGFzaCI6IjMwMGYwM2YwNjE5ZWViZWM2ZTUzYzAyMjc2Y2ViNDgyNTY0OWQ3YjhmMzk2YmUyM2MzZTUzZjI0Y2FiYzcwMTEiLCJvZmZsaW5lX3BvbGljeSI6ImZhaWxfY2xvc2VkIn0.wcepEJJf03lopY9ftwmd1TXt91Puxj7o_fMXOfo5qVKm_jIYbsTy4TT0KsQFFVzOHaYc1OzEKKyQ1EURf6Ec1A
L2  eyJhbGciOiJFUzI1NiIsInR5cCI6Im9wc2FwaS1saWNlbnNlK2p3dCIsImtpZCI6InRlc3QtMjAyNi0wMSJ9.eyJ2ZXIiOjEsImlzcyI6Imh0dHBzOi8vYmlsbGluZy5leGFtcGxlLnRlc3QiLCJhdWQiOiI4YjBjN2UwZS01ZDJhLTRmNDMtOWMxZS0yYTZmMGQzYjdjMTEiLCJzdWIiOiIzZDVlOGYyMC02YjFhLTRjOWUtYTdkNC0wZjJiOWM4ZTFhNTUiLCJpYXQiOjE3NjcyMjU2MDAsImV4cCI6MTc2NzgzMDQwMCwiZ3JhY2VfdW50aWwiOjE3NzA0MjI0MDAsInBsYW5fa2V5IjoicHJvIiwiZmVhdHVyZXMiOnsiZXhwb3J0X3BkZiI6dHJ1ZSwicHJvamVjdHMiOjEwMDAsInNlYXRzIjpudWxsfSwiYWNjZXNzX3VudGlsIjpudWxsLCJ1cGRhdGVzX3VudGlsIjoxNzk4NzYxNjAwLCJmaW5nZXJwcmludF9oYXNoIjoiMzAwZjAzZjA2MTllZWJlYzZlNTNjMDIyNzZjZWI0ODI1NjQ5ZDdiOGYzOTZiZTIzYzNlNTNmMjRjYWJjNzAxMSIsIm9mZmxpbmVfcG9saWN5IjoiZmFpbF9jbG9zZWQifQ.wcepEJJf03lopY9ftwmd1TXt91Puxj7o_fMXOfo5qVKm_jIYbsTy4TT0KsQFFVzOHaYc1OzEKKyQ1EURf6Ec1A
L3  eyJhbGciOiJub25lIiwidHlwIjoib3BzYXBpLWxpY2Vuc2Urand0Iiwia2lkIjoidGVzdC0yMDI2LTAxIn0.eyJ2ZXIiOjEsImlzcyI6Imh0dHBzOi8vYmlsbGluZy5leGFtcGxlLnRlc3QiLCJhdWQiOiI4YjBjN2UwZS01ZDJhLTRmNDMtOWMxZS0yYTZmMGQzYjdjMTEiLCJzdWIiOiIzZDVlOGYyMC02YjFhLTRjOWUtYTdkNC0wZjJiOWM4ZTFhNTUiLCJpYXQiOjE3NjcyMjU2MDAsImV4cCI6MTc2NzgzMDQwMCwiZ3JhY2VfdW50aWwiOjE3NzA0MjI0MDAsInBsYW5fa2V5IjoicHJvIiwiZmVhdHVyZXMiOnsiZXhwb3J0X3BkZiI6dHJ1ZSwicHJvamVjdHMiOjEwLCJzZWF0cyI6bnVsbH0sImFjY2Vzc191bnRpbCI6bnVsbCwidXBkYXRlc191bnRpbCI6MTc5ODc2MTYwMCwiZmluZ2VycHJpbnRfaGFzaCI6IjMwMGYwM2YwNjE5ZWViZWM2ZTUzYzAyMjc2Y2ViNDgyNTY0OWQ3YjhmMzk2YmUyM2MzZTUzZjI0Y2FiYzcwMTEiLCJvZmZsaW5lX3BvbGljeSI6ImZhaWxfY2xvc2VkIn0.
L4  eyJhbGciOiJFUzI1NiIsInR5cCI6Im9wc2FwaS1saWNlbnNlK2p3dCIsImtpZCI6InRlc3QtMjAyNS0wNyJ9.eyJ2ZXIiOjEsImlzcyI6Imh0dHBzOi8vYmlsbGluZy5leGFtcGxlLnRlc3QiLCJhdWQiOiI4YjBjN2UwZS01ZDJhLTRmNDMtOWMxZS0yYTZmMGQzYjdjMTEiLCJzdWIiOiIzZDVlOGYyMC02YjFhLTRjOWUtYTdkNC0wZjJiOWM4ZTFhNTUiLCJpYXQiOjE3NjcyMjU2MDAsImV4cCI6MTc2NzgzMDQwMCwiZ3JhY2VfdW50aWwiOjE3NzA0MjI0MDAsInBsYW5fa2V5IjoicHJvIiwiZmVhdHVyZXMiOnsiZXhwb3J0X3BkZiI6dHJ1ZSwicHJvamVjdHMiOjEwLCJzZWF0cyI6bnVsbH0sImFjY2Vzc191bnRpbCI6bnVsbCwidXBkYXRlc191bnRpbCI6MTc5ODc2MTYwMCwiZmluZ2VycHJpbnRfaGFzaCI6IjMwMGYwM2YwNjE5ZWViZWM2ZTUzYzAyMjc2Y2ViNDgyNTY0OWQ3YjhmMzk2YmUyM2MzZTUzZjI0Y2FiYzcwMTEiLCJvZmZsaW5lX3BvbGljeSI6ImZhaWxfY2xvc2VkIn0.WOCSqjvjw4YGTlXfs78NC_w1EaTFbGs5eCl_kW44uVrHc3LqU7ZSXPf_I0uQnlzFWJROk9pRERbVyaTjcXWQ-A
L5  eyJhbGciOiJFUzI1NiIsInR5cCI6Im9wc2FwaS1saWNlbnNlK2p3dCIsImtpZCI6InRlc3QtMjAyNC0wMSJ9.eyJ2ZXIiOjEsImlzcyI6Imh0dHBzOi8vYmlsbGluZy5leGFtcGxlLnRlc3QiLCJhdWQiOiI4YjBjN2UwZS01ZDJhLTRmNDMtOWMxZS0yYTZmMGQzYjdjMTEiLCJzdWIiOiIzZDVlOGYyMC02YjFhLTRjOWUtYTdkNC0wZjJiOWM4ZTFhNTUiLCJpYXQiOjE3NjcyMjU2MDAsImV4cCI6MTc2NzgzMDQwMCwiZ3JhY2VfdW50aWwiOjE3NzA0MjI0MDAsInBsYW5fa2V5IjoicHJvIiwiZmVhdHVyZXMiOnsiZXhwb3J0X3BkZiI6dHJ1ZSwicHJvamVjdHMiOjEwLCJzZWF0cyI6bnVsbH0sImFjY2Vzc191bnRpbCI6bnVsbCwidXBkYXRlc191bnRpbCI6MTc5ODc2MTYwMCwiZmluZ2VycHJpbnRfaGFzaCI6IjMwMGYwM2YwNjE5ZWViZWM2ZTUzYzAyMjc2Y2ViNDgyNTY0OWQ3YjhmMzk2YmUyM2MzZTUzZjI0Y2FiYzcwMTEiLCJvZmZsaW5lX3BvbGljeSI6ImZhaWxfY2xvc2VkIn0.YTYWAPSQ14ewdtprtpOmSyILsrQZQTsUL_5DPdk896oDOhQnbAhBY_kRPMB2T7-Je6ryHV-Swb-bxuAGoN2LwA
L6  eyJhbGciOiJFUzI1NiIsInR5cCI6Im9wc2FwaS1saWNlbnNlK2p3dCIsImtpZCI6InRlc3QtMjAyNi0wMSJ9.eyJ2ZXIiOjEsImlzcyI6Imh0dHBzOi8vYmlsbGluZy5leGFtcGxlLnRlc3QiLCJhdWQiOiI4YjBjN2UwZS01ZDJhLTRmNDMtOWMxZS0yYTZmMGQzYjdjMTEiLCJzdWIiOiI5YTFiMmMzZC00ZTVmLTRhNmItOGM3ZC05ZTBmMWEyYjNjNGQiLCJpYXQiOjE3NjcyMjU2MDAsImV4cCI6MTc2NzgzMDQwMCwiZ3JhY2VfdW50aWwiOjE3NzA0MjI0MDAsInBsYW5fa2V5IjoicGFzc18zMGQiLCJmZWF0dXJlcyI6eyJleHBvcnRfcGRmIjp0cnVlLCJwcm9qZWN0cyI6MTAsInNlYXRzIjpudWxsfSwiYWNjZXNzX3VudGlsIjoxNzY5ODE3NjAwLCJ1cGRhdGVzX3VudGlsIjpudWxsLCJmaW5nZXJwcmludF9oYXNoIjoiMzAwZjAzZjA2MTllZWJlYzZlNTNjMDIyNzZjZWI0ODI1NjQ5ZDdiOGYzOTZiZTIzYzNlNTNmMjRjYWJjNzAxMSIsIm9mZmxpbmVfcG9saWN5IjoiZmFpbF9jbG9zZWQifQ.shamlAlZotVbxgtt01FuSC8KUdILwa15gyauU5fXzJxitTJt86QeDiFl80xYtGa8ADayumETZPZvVaxLNI7CMg
L7  eyJhbGciOiJFUzI1NiIsInR5cCI6Im9wc2FwaS1saWNlbnNlK2p3dCIsImtpZCI6InRlc3QtMjAyNi0wMSJ9.eyJ2ZXIiOjEsImlzcyI6Imh0dHBzOi8vYmlsbGluZy5leGFtcGxlLnRlc3QiLCJhdWQiOiIwMDAwMDAwMC0wMDAwLTQwMDAtODAwMC0wMDAwMDAwMDAwMDEiLCJzdWIiOiIzZDVlOGYyMC02YjFhLTRjOWUtYTdkNC0wZjJiOWM4ZTFhNTUiLCJpYXQiOjE3NjcyMjU2MDAsImV4cCI6MTc2NzgzMDQwMCwiZ3JhY2VfdW50aWwiOjE3NzA0MjI0MDAsInBsYW5fa2V5IjoicHJvIiwiZmVhdHVyZXMiOnsiZXhwb3J0X3BkZiI6dHJ1ZSwicHJvamVjdHMiOjEwLCJzZWF0cyI6bnVsbH0sImFjY2Vzc191bnRpbCI6bnVsbCwidXBkYXRlc191bnRpbCI6MTc5ODc2MTYwMCwiZmluZ2VycHJpbnRfaGFzaCI6IjMwMGYwM2YwNjE5ZWViZWM2ZTUzYzAyMjc2Y2ViNDgyNTY0OWQ3YjhmMzk2YmUyM2MzZTUzZjI0Y2FiYzcwMTEiLCJvZmZsaW5lX3BvbGljeSI6ImZhaWxfY2xvc2VkIn0.z7Vx8D5ZMfFr01qlQgvrZU_F9v-gnNW1rvrX7JDEaNycBRVQtzB_22EMZANlMPfJ3JOPLkCyi6T8yQAob8n6jw
L8  eyJhbGciOiJFUzI1NiIsInR5cCI6Im9wc2FwaS1saWNlbnNlK2p3dCIsImtpZCI6InRlc3QtMjAyNi0wMSJ9.eyJ2ZXIiOjIsImlzcyI6Imh0dHBzOi8vYmlsbGluZy5leGFtcGxlLnRlc3QiLCJhdWQiOiI4YjBjN2UwZS01ZDJhLTRmNDMtOWMxZS0yYTZmMGQzYjdjMTEiLCJzdWIiOiIzZDVlOGYyMC02YjFhLTRjOWUtYTdkNC0wZjJiOWM4ZTFhNTUiLCJpYXQiOjE3NjcyMjU2MDAsImV4cCI6MTc2NzgzMDQwMCwiZ3JhY2VfdW50aWwiOjE3NzA0MjI0MDAsInBsYW5fa2V5IjoicHJvIiwiZmVhdHVyZXMiOnsiZXhwb3J0X3BkZiI6dHJ1ZSwicHJvamVjdHMiOjEwLCJzZWF0cyI6bnVsbH0sImFjY2Vzc191bnRpbCI6bnVsbCwidXBkYXRlc191bnRpbCI6MTc5ODc2MTYwMCwiZmluZ2VycHJpbnRfaGFzaCI6IjMwMGYwM2YwNjE5ZWViZWM2ZTUzYzAyMjc2Y2ViNDgyNTY0OWQ3YjhmMzk2YmUyM2MzZTUzZjI0Y2FiYzcwMTEiLCJvZmZsaW5lX3BvbGljeSI6ImZhaWxfY2xvc2VkIn0.UjcRFPLq1pSL_3kOSn8lKo1Nl8htPs1KMXXLeq8A6SknGrZtYZabAizkdiaA_toEoqglPApeeS3tzm3io9X7Kg
E1  eyJhbGciOiJFUzI1NiIsInR5cCI6Im9wc2FwaS1lbnRpdGxlbWVudHMrand0Iiwia2lkIjoidGVzdC0yMDI2LTAxIn0.eyJ2ZXIiOjEsImlzcyI6Imh0dHBzOi8vYmlsbGluZy5leGFtcGxlLnRlc3QiLCJhdWQiOiI4YjBjN2UwZS01ZDJhLTRmNDMtOWMxZS0yYTZmMGQzYjdjMTEiLCJzdWIiOiJ1c2VyXzQyIiwiaWF0IjoxNzY3MjI1NjAwLCJleHAiOjE3NjcyMjY1MDAsImdyYWNlX3VudGlsIjoxNzY3NDg1NzAwLCJwbGFuX2tleSI6InBybyIsInN0YXR1cyI6ImFjdGl2ZSIsImZlYXR1cmVzIjp7ImV4cG9ydF9wZGYiOnRydWUsInByb2plY3RzIjoxMCwic2VhdHMiOm51bGx9LCJhY2Nlc3NfdW50aWwiOjE3Njk5MDQwMDAsInVwZGF0ZXNfdW50aWwiOm51bGwsIm9mZmxpbmVfcG9saWN5IjoiZmFpbF9jbG9zZWQifQ.ovhvTdZ9Y-rYoqWsLBc8stR4Dl2WTHaCvbGYrl1DLED5iysYibMJKT-w9s6GJig06-VURCfTqo6IDhvh-H5dGw
```

### 7.3 Expected results

`t` is the evaluation time (Unix seconds). Unless stated, licence files are checked with
fingerprint_hash `300f03f0619eebec6e53c02276ceb4825649d7b8f396be23c3e53f24cabc7011` and no pinned issuer.

| Token | now | Also | Expected | Case |
|---|---|---|---|---|
| L1 | 1767312000 | — | `valid` | valid licence |
| L1 | 1767916800 | — | `refresh` | past exp, inside grace: use it and refresh |
| L1 | 1770508800 | — | `past_grace` | past grace: refresh, or apply offline_policy |
| L1 | 1767312000 | another machine's fingerprint | `error:wrong_machine` | activated on another machine |
| L1 | 1764547200 | high_water 1770508800 | `past_grace` | clock set back, high-water from an earlier run |
| L1 | 1764547200 | — | `valid` | clock before iat, no high-water yet |
| L1 | 1767312000 | checked as an entitlement token | `error:bad_type` | licence file presented as an entitlement token |
| L1 | 1767312000 | pinned iss `https://billing.example.test` | `valid` | issuer pinned and matching |
| L1 | 1767312000 | pinned iss `https://evil.test` | `error:wrong_issuer` | issuer pinned, different |
| L2 | 1767312000 | — | `error:bad_signature` | payload changed after signing |
| L3 | 1767312000 | — | `error:bad_alg` | alg none |
| L4 | 1767312000 | — | `valid` | signed with the previous key (still published) |
| L5 | 1767312000 | — | `error:unknown_key` | kid not in the JWKS |
| L6 | 1767312000 | — | `valid` | 30-day pass, inside its access window |
| L6 | 1769904000 | — | `access_ended` | 30-day pass, after access_until |
| L7 | 1767312000 | — | `error:wrong_app` | issued for another app |
| L8 | 1767312000 | — | `error:bad_version` | unknown format version |
| E1 | 1767225660 | — | `valid` | entitlement token, fresh |
| E1 | 1767312000 | — | `refresh` | entitlement token, past exp inside grace |
| E1 | 1767571200 | — | `past_grace` | entitlement token, past grace |

## 8. Signature encoding by platform

The 64-byte signature is `r || s`, each 32 bytes big-endian (IEEE P1363). Platforms that accept this format
directly:
- **WebCrypto:** `crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" })`.
- **Apple CryptoKit:** `P256.Signing.ECDSASignature(rawRepresentation:)`.
- **.NET:** `ECDsa.VerifyData(data, sig, HashAlgorithmName.SHA256)`; P1363 is the default.
- **Java 9+:** `Signature.getInstance("SHA256withECDSAinP1363Format")`.
- **Go:** split into `r`, `s` for `ecdsa.Verify`.
- **Rust:** `p256::ecdsa::Signature::from_slice`.

Platforms that need DER (Python `cryptography`, OpenSSL's `EVP_DigestVerify`, older Java with
`SHA256withECDSA`) must convert `r`, `s` to DER first. The Python verifier below shows how.

## 9. Reference verifiers

Both pass every case in §7.3. They return the state from §5.2, or raise the error codes from §4.

### Python (`cryptography`)

```python
"""Reference verifier for OpsAPI licence files and entitlement tokens (format v1).
Needs: pip install cryptography"""
import base64, json, time
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

LICENCE = "opsapi-license+jwt"
ENTITLEMENTS = "opsapi-entitlements+jwt"
SKEW = 300  # seconds of clock difference we tolerate


class LicenceError(Exception):
    """code: malformed, bad_alg, bad_type, unknown_key, bad_signature, bad_version,
    wrong_app, wrong_issuer, wrong_machine"""
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def _b64(part):
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


def verify(token, jwks, *, typ, app_id, fingerprint_hash=None, iss=None, now=None, high_water=0):
    """Returns (state, claims). state is one of:
       "valid"        use it;
       "refresh"      use it, and refresh it when you are online;
       "past_grace"   refresh now; if OpsAPI can't be reached, allow only when
                      claims["offline_policy"] == "fail_open";
       "access_ended" deny: a fixed-term pass or access period is over.
    Raises LicenceError when the token must not be trusted at all."""
    try:
        head_b64, body_b64, sig_b64 = token.split(".")
        header = json.loads(_b64(head_b64))
    except Exception:
        raise LicenceError("malformed")
    if header.get("alg") != "ES256":
        raise LicenceError("bad_alg")
    if header.get("typ") != typ:
        raise LicenceError("bad_type")
    jwk = next((k for k in jwks["keys"] if k.get("kid") == header.get("kid")), None)
    if jwk is None:
        raise LicenceError("unknown_key")  # online: fetch the JWKS once and retry
    raw = _b64(sig_b64)
    if len(raw) != 64:
        raise LicenceError("bad_signature")
    public_key = ec.EllipticCurvePublicNumbers(
        int.from_bytes(_b64(jwk["x"]), "big"), int.from_bytes(_b64(jwk["y"]), "big"), ec.SECP256R1()
    ).public_key()
    der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
    try:
        public_key.verify(der, f"{head_b64}.{body_b64}".encode("ascii"), ec.ECDSA(hashes.SHA256()))
    except InvalidSignature:
        raise LicenceError("bad_signature")
    claims = json.loads(_b64(body_b64))
    if claims.get("ver") != 1:
        raise LicenceError("bad_version")
    if claims.get("aud") != app_id:
        raise LicenceError("wrong_app")
    if iss is not None and claims.get("iss") != iss:
        raise LicenceError("wrong_issuer")
    if typ == LICENCE and claims.get("fingerprint_hash") != fingerprint_hash:
        raise LicenceError("wrong_machine")

    # Time. Never let the clock go backwards past what we've already seen
    # (persist high_water = max(high_water, now, claims["iat"]) after each check).
    t = max(now if now is not None else int(time.time()), high_water, claims["iat"] - SKEW)
    if claims.get("access_until") is not None and t > claims["access_until"] + SKEW:
        return "access_ended", claims
    if t <= claims["exp"] + SKEW:
        return "valid", claims
    if t <= claims["grace_until"] + SKEW:
        return "refresh", claims
    return "past_grace", claims
```

### Swift (CryptoKit)

```swift
// Reference verifier for OpsAPI licence files and entitlement tokens (format v1).
// Apple platforms: CryptoKit (macOS 10.15+, iOS 13+). Elsewhere, swap in swift-crypto.
import CryptoKit
import Foundation

enum LicenceError: Error, Equatable {
    case malformed, badAlg, badType, unknownKey, badSignature, badVersion, wrongApp, wrongIssuer, wrongMachine
}

enum LicenceState: String { case valid, refresh, pastGrace = "past_grace", accessEnded = "access_ended" }

let licenceType = "opsapi-license+jwt"
let entitlementsType = "opsapi-entitlements+jwt"
let skew: Int64 = 300 // seconds of clock difference we tolerate

func base64url(_ s: Substring) -> Data? {
    var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    b += String(repeating: "=", count: (4 - b.count % 4) % 4)
    return Data(base64Encoded: b)
}

func object(_ data: Data?) -> [String: Any]? {
    data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

func int(_ v: Any?) -> Int64? { (v as? NSNumber)?.int64Value }

/// jwks: the decoded JWKS ({"keys": [...]}), embedded in the app and/or fetched.
/// Persist highWater = max(highWater, now, claims["iat"]) after each check.
func verify(_ token: String, jwks: [String: Any], type: String, appId: String,
            fingerprintHash: String? = nil, issuer: String? = nil,
            now: Int64 = Int64(Date().timeIntervalSince1970), highWater: Int64 = 0) throws -> (LicenceState, [String: Any]) {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let header = object(base64url(parts[0])) else { throw LicenceError.malformed }
    guard header["alg"] as? String == "ES256" else { throw LicenceError.badAlg }
    guard header["typ"] as? String == type else { throw LicenceError.badType }
    let keys = jwks["keys"] as? [[String: Any]] ?? []
    guard let jwk = keys.first(where: { $0["kid"] as? String == header["kid"] as? String }),
          let x = (jwk["x"] as? String).flatMap({ base64url(Substring($0)) }),
          let y = (jwk["y"] as? String).flatMap({ base64url(Substring($0)) })
    else { throw LicenceError.unknownKey } // online: fetch the JWKS once and retry
    guard let raw = base64url(parts[2]), raw.count == 64,
          let key = try? P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y),
          let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
          key.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8))
    else { throw LicenceError.badSignature }
    guard let claims = object(base64url(parts[1])) else { throw LicenceError.malformed }
    guard int(claims["ver"]) == 1 else { throw LicenceError.badVersion }
    guard claims["aud"] as? String == appId else { throw LicenceError.wrongApp }
    if let issuer, claims["iss"] as? String != issuer { throw LicenceError.wrongIssuer }
    if type == licenceType, claims["fingerprint_hash"] as? String != fingerprintHash { throw LicenceError.wrongMachine }

    // Time: never let the clock go backwards past what we've already seen.
    guard let iat = int(claims["iat"]), let exp = int(claims["exp"]), let grace = int(claims["grace_until"])
    else { throw LicenceError.malformed }
    let t = max(now, highWater, iat - skew)
    if let accessUntil = int(claims["access_until"]), t > accessUntil + skew { return (.accessEnded, claims) }
    if t <= exp + skew { return (.valid, claims) }
    if t <= grace + skew { return (.refresh, claims) }
    return (.pastGrace, claims) // refresh now; offline, allow only if offline_policy == "fail_open"
}

/// fingerprint_hash = hex(SHA-256(salt + ":" + lowercase(trim(machine id))))
func fingerprintHash(salt: String, machineId: String) -> String {
    let id = machineId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return SHA256.hash(data: Data("\(salt):\(id)".utf8)).map { String(format: "%02x", $0) }.joined()
}
```
