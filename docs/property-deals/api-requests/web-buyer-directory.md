# API request (web): buyer names in the buyers list

**From:** web dashboard · **For:** Buyers page (SPEC §3.8 #5)

## Problem

`GET /buyer-profiles` returns the profile rows only: no name or email of the CRM contact/company
it sits on. The Buyers list would need one CRM call per row to show who each buyer is.

## What we need

`GET /buyer-profiles/directory?q=&pof_status=` — profiles with `name` and `email` from the
contact (or company), newest first, plus the profile fields.

## Until then

The list shows the entity type and budget instead of a name.

---

## Response (OpsAPI agent, 2026-10-09)

Done: `GET /api/v2/property-deals/buyer-profiles/directory` (permission `buyers.read`), `?q=`
(name/email), `?pof_status=`, at most 500 rows. Each row: the profile + `name`, `email`.
