# Prompt 2 of 3 — WSL CRM Web Dashboard (Next.js) — Property Deals module

> Run this in the **web dashboard repo** after the OpsAPI agent has finished its Phase 4 (API contract published). Read `docs/property-deals/SPEC.md` (the full product spec) and `docs/property-deals/API.md` + the Swagger file first.

## Your scope

You build the **web pages only**. You do **not** change the database or the Lua backend.

## Rules

1. **Use the API as it is.** Call OpsAPI through the typed `@opsapi/client` (update it to the new release). Do not write raw fetch calls with made-up shapes.
2. If a page needs data the API does not give, **do not work around it.** Write `docs/property-deals/api-requests/web-<short-name>.md` in the opsapi repo (what you need, why, and an example response), use a clearly marked mock for now, and carry on.
3. **Reuse what exists:** the app layout, nav, auth, workspace switcher, tables, forms, theme and **the existing leads pages**. Extend the leads list and detail page; don't build a second leads page.
4. The module only shows if the plugin is switched on for the workspace. Respect roles: hide buttons a role can't use, and still handle a 403 nicely.
5. Never show an LLM or integration key after it is saved (show `••••1234` and a "replace" button only).
6. Pages must work on a laptop and a tablet, in light and dark mode, with keyboard use and good contrast.

## Pages to build (SPEC §3.8)

1. **Today:** my tasks sorted by urgency, with the "why" shown on hover. Red deals, approvals waiting, £ at risk. Live updates (WebSocket or polling).
2. **Leads (extend):** new fields (kind, situation, deadline, vulnerability flag, consent), filters, and a "Create deal" action.
3. **Deals:** Kanban by stage (drag only where gates allow; show the blocking reason if not) plus a list view.
4. **Deal page:** header with stage, health colour, target dates, money at risk and slip prediction. Tabs: Tasks, Enquiries & blockers, Chase log, Documents (MinIO upload), Compliance, Buyers/matches, Timeline (audit). Each task has "Do it", "Let AI do it", "Assign" and "Snooze with reason".
5. **Approvals inbox:** AI draft, its sources, an edit box with a diff, and approve / edit and approve / reject with a note. Show the agent, model, cost and whether it came from JobShout.
6. **Map / Deal finder:** Leaflet + OpenStreetMap, drop a pin, radius slider (5–50 miles, default 25), layer toggles, property card with top 3 matching buyers and score breakdown, save the search.
7. **Buyers:** buyer profiles, proof-of-funds status and expiry, matches, "send deal pack" (goes through approval).
8. **Suppliers:** directory, filters by type and area, speed stats, "book nearest" (creates a booking task).
9. **Compliance:** all checks, status, evidence, expiring soon.
10. **Settings:**
    - Workflow template editor (stages, tasks, deadlines, gates, owners, agent-eligible flag, approval rule), with JSON import/export and versions.
    - Urgency weights.
    - AI providers and models: cloud, local base URL, JobShout URL and key, agent mapping, fallback order, cost caps, a "test connection" button.
    - Data connectors, notification channels and digest time.
11. **Reports:** time per stage, late days, conversion, supplier/solicitor/council speed, AI usage and cost. Charts must be simple and readable.

## Phases (stop after each one and show me screenshots)

1. **Plan:** a list of existing components and pages you'll reuse, any missing API pieces (as api-request files), and the route map. Wait for approval.
2. Today, Leads (extend), Deals Kanban/list, Deal page.
3. Approvals inbox, Compliance, Settings (templates, AI, JobShout).
4. Map, Buyers, Suppliers.
5. Reports, polish, accessibility pass, Playwright tests.

## Done when

- Playwright runs the scenario from SPEC §5 in the browser. The deal shows red, the EPC task is overdue, an AI chase draft appears in Approvals, approving it records the chase, and the Exchange move is blocked with the AML reason shown.
- A user in another workspace sees none of it.
- No backend code changed in this repo. All gaps are written up as api-request files.
