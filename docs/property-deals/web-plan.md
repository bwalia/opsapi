# Property Deals — web dashboard plan (Prompt 2, phase 1)

Native pages in `opsapi-dashboard/app/dashboard/property-deals/` (gap map D7), on the existing layout,
sidebar, auth, workspace switcher, `components/ui` (Button, Card, Table, Modal, Badge, Input, Select,
Textarea, Switch, Pagination), `PageHeader`, toasts, `next-themes` dark mode, recharts and @dnd-kit.

## Data access

- **Typed calls:** every call goes through `services/property-deals.service.ts`, typed with the
  plugin's OpenAPI types.
  - The types are vendored from `@opsapi/client`'s generator: `types/property-deals.generated.ts`,
    refreshed with `npm run sync:property-deals-types`.
  - Requests use the dashboard's `apiClient`, which already adds auth, the workspace headers, token
    refresh and the offline queue.
  - Switch to the npm package once `@opsapi/client` 1.3.0 is published with the Phase 5–7 routes.
- **Permissions:** from `GET /api/v2/property-deals/me` (`permissions[module]`), via the `usePdMe()`
  hook. Buttons a role can't use are hidden, and a 403 still shows a friendly message.
- **Plugin off:** a `PLUGIN_DISABLED` 404 shows "Property Deals is switched off for this workspace".
  Its sidebar entries are already hidden by the menu API.

## Route map

| Route | Page | Main calls |
|---|---|---|
| `/dashboard/property-deals/today` | Today (tasks by urgency + why, red deals, approvals, £ at risk; polls every 30 s) | `/today`, `/tasks/{id}` actions |
| `/dashboard/leads` (existing) | + Property Deals panel in the lead drawer (kind, situation, deadline, vulnerability, consent) and **Create deal** | `/leads/{uuid}`, `PUT /leads/{uuid}/details`, `POST /deals` |
| `/dashboard/property-deals/deals` | Kanban by stage (drag → gate check, blocked reason) + list | `/deals/board`, `/deals`, `/deals/{id}/gate`, `/deals/{id}/stage` |
| `/dashboard/property-deals/deals/[id]` | Deal page: header (stage, health, dates, £ at risk, slip) + tabs Tasks, Enquiries, Chase log, Documents, Compliance, Buyers, Timeline | `/deals/{id}/overview`, `/timeline`, `/tasks`, `/documents`, `/properties/{id}/matches` |
| `/dashboard/property-deals/approvals` | Inbox: draft, sources, tool calls, edit with diff, approve / edit & approve / reject with note | `/approvals/inbox`, `/approvals/{id}/decide` |
| `/dashboard/property-deals/map` | Leaflet + OSM, pin, radius 5–50, layers, card with top 3 buyers, save search, scout alerts | `/map`, `/properties/{id}/card`, `/saved-searches`, `/scout-alerts` |
| `/dashboard/property-deals/buyers` | Profiles, proof of funds, matches + breakdown, send deal pack, company check | `/buyer-profiles`, `/buyer-profiles/{id}/matches`, `/matches/{id}/send` |
| `/dashboard/property-deals/suppliers` | Directory, kind/area filters, speed stats, book nearest | `/suppliers`, `/suppliers/nearest`, `/tasks` |
| `/dashboard/property-deals/compliance` | All checks, status, evidence, expiring soon, sign-off | `/compliance-checks` |
| `/dashboard/property-deals/reports` | Stage times, late days, conversion, supplier / party speed, AI usage | `/reports/*`, `/export/*` |
| `/dashboard/property-deals/settings` | Templates (editor, versions, import/export), SLA & urgency, AI (providers, routes, agents, JobShout, caps), data connectors, mailboxes, my notifications, digest | `/workflow-templates*`, core `/namespace/plugins`, core `/namespace/ai-providers`, `/ai/*`, `/connectors`, `/mail-connectors`, `/notification-preferences` |

## Guided tour

`components/property-deals/Tour.tsx` is a dependency-free tour across every page. It highlights
`data-tour` anchors, steps through the pages, and remembers its place in `localStorage`. Start it
from **Take the tour** on Today; it starts by itself the first time a demo user signs in.

## Tests

Cypress (gap map D14, the repo's runner): `cypress/e2e/property-deals.cy.ts` runs the SPEC §5
scenario in the browser against a sandbox API.

## API requests from the web side

None needed: every page above is served by the published contract (API.md v1.3).
