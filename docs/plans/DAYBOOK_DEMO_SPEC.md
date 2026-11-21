# Daybook demo: shared spec (website, demo back office, videos)

The website, the demo seed, and the video scripts and recorders all use these names and
numbers. Change them here first. Everything below is **fictional**.

## Brand

- **Name:** Daybook. **Strapline:** "AI tax returns for UK accountancy practices."
- **Domain:** `daybook.co.uk`. **Email:** `hello@daybook.co.uk`.
- **Theme:** reuse opsapi.org's theme from `website/src/app/globals.scss` and
  `layout.js`:
  - the same fonts: **Unbounded** for display, **Poppins** for body, **JetBrains Mono**
    for code;
  - the same type scale, spacing, card/band/button components and light/dark switch.

  Only the colours change, to a traditional accountancy palette of navy, muted gold and
  warm paper:

  | Token | Light | Dark |
  |---|---|---|
  | `--bg` | `#F6F4EE` (warm paper) | `#0E1626` |
  | `--surface` | `#FFFFFF` | `#141F33` |
  | `--surface-2` | `#EFEBE1` | `#1A2740` |
  | `--ink` | `#14213D` (navy ink) | `#E8ECF3` |
  | `--ink-2` | `#46526A` | `#B3BDCE` |
  | `--ink-3` | `#6E7890` | `#8592A8` |
  | `--line` | `#DDD6C6` | `#2A3852` |
  | `--accent` | `#1D3A5F` (navy) | `#8FB3E0` |
  | `--accent-strong` | `#274B78` | `#B5CDEE` |
  | `--accent-tint` | `#E3EAF3` | `#1C2C47` |
  | `--gold` (eyebrows, rules, highlights) | `#9C7A2E` | `#D4B26A` |
  | `--gold-tint` | `#F4ECD8` | `#33291A` |
  | `--amber` / `--amber-tint` ("needs review") | `#A85F00` / `#FCEFD9` | `#F2B04F` / `#3A2A12` |
  | `--band` (hero/footer, both themes) | `#14213D` | `#0A1220` |
  | `--band-ink` / `--band-ink-2` | `#EEF1F6` / `#B3BDCE` | same |
  | `--band-accent` | `#D4B26A` (gold on navy) | same |

  - **Motif:** a thin gold rule under eyebrows and section headings, and a faint ruled
    "ledger" texture in the hero band.
  - Buttons are navy, with gold only as a highlight. Keep it restrained: no gradients,
    no neon.
- **Logo:** wordmark "Daybook" in Unbounded, with a small open-ledger glyph in gold on
  navy.

## Hosts

| Host | What |
|---|---|
| `daybook.co.uk` | Marketing site (repo `bwalia/daybook-website`, GitHub Pages behind the edge) |
| `www.daybook.co.uk` | 301 → apex |
| `demo.daybook.co.uk` | Demo back office: OpsAPI dashboard, Daybook theme |
| `demo-api.daybook.co.uk` | Demo API: OpsAPI, `PROJECT_CODE=tax_copilot` |

k3s1, namespace `daybook-demo`. Helm releases `daybook-demo` (API) and
`daybook-demo-dashboard`. Postgres StatefulSet `daybook-demo-db`. Vault path
`daybook-demo/config`.

## Demo login (published on daybook.co.uk/demo)

| | |
|---|---|
| Email | `demo@daybook.co.uk` |
| Password | published on daybook.co.uk/demos; stored in the Actions secret `DAYBOOK_DEMO_PASSWORD` (not in the repo) |
| Role | `viewer`: reads every module, every change → 403 |
| Reset | every 30 minutes |
| Emailed code | off for this workspace only |

## The practice (workspace `daybook-demo`, name "Harbour & Lane Accountants")

Staff use the domain `sample.daybook.co.uk`. Nobody can sign in as them: their passwords
are random.

| Person | Email | Role |
|---|---|---|
| Ruth Hughes, partner | `ruth.hughes@sample.daybook.co.uk` | owner |
| Ade Okoro, tax senior | `ade.okoro@sample.daybook.co.uk` | admin |
| Lucy Fairbairn, bookkeeper | `lucy.fairbairn@sample.daybook.co.uk` | member |

## Clients (all `@sample.daybook.co.uk`, tax year 2025-26)

| # | Client | Email | Profile | Data |
|---|---|---|---|---|
| C1 | Jordan Hale | `jordan.hale@` | Landlord, 100 residential properties, residential mortgages | 12 monthly statements, 275 transactions. 2024-25 confirmed, so the AI learns from last year; 1 line flagged |
| C2 | Priya Shah | `priya.shah@` | Small landlord, 2 flats (1 residential mortgage) | 1 account, ~60 transactions, 3 flagged |
| C3 | Tom Reid | `tom.reid@` | Sole trader IT consultant, mixed personal/business account | 2 statements, ~120 transactions, 6 flagged (personal vs business) |
| C4 | Ellie Moss t/a Corner Cup Café | `ellie.moss@` | Sole trader café, VAT-registered (standard scheme, quarterly) | ~400 transactions, VAT-coded; 1 VAT quarter ready, 1 open; 5 flagged |
| C5 | Dan Kowalski | `dan.kowalski@` | Subcontractor builder. CIS deductions are only noted on lines: the Income Tax engine has no CIS field yet, so don't present CIS as handled | ~150 transactions, 4 flagged |
| C6 | Sam Rivers | `sam.rivers@` | Employee (PAYE) plus a craft side business on Etsy | 1 employment, ~80 transactions, 2 flagged |

Workflow states to show:

- **C1:** sorted, reviewed, filed in HMRC sandbox. The final declaration is shown as
  filed.
- **C2, C6:** sorted, review queue open.
- **C3:** mid-review (some corrections done).
- **C4:** VAT return ready to submit; Income Tax in progress.
- **C5:** statements just uploaded, sorting complete, not yet reviewed.

Use realistic UK merchants and amounts, but invented counterparties for people, e.g.
"Tenant – Flat 3, 12 Mill Lane". Invent every address, and use no real company's
account numbers. NINOs only from the HMRC test range (as HMRC sandbox test users give
out), and none on screen.

## Demos by use case (daybook.co.uk/demos)

There is one demo deployment (`demo.daybook.co.uk`, `PROJECT_CODE=tax_copilot`) with
**one namespace per use case**:

- the data stays separate;
- each vertical is reset on its own;
- a new vertical is a data file, not a new deployment.

| Slug | Namespace | Status | Story |
|---|---|---|---|
| `practice` | `daybook-demo` | first | Harbour & Lane Accountants with clients C1–C6 (above). The practice-side view |
| `landlords` | `daybook-landlords` | next | Landlord portfolio practice: small, medium and 100-property landlords, mortgage interest, UK property MTD |
| `trades` | `daybook-trades` | later | Plumbers, electricians, builders: CIS, vans and tools, cash jobs, materials |
| `payroll` | `daybook-payroll` | after payroll module | Café with 8 staff, builder with 3 CIS subcontractors + 2 PAYE, director-only company. RTI to HMRC's Local Test Service only (`PROMPT_PAYROLL.md`) |
| `companies` | `daybook-companies` | after CT module | Consultancy Ltd near the marginal relief band with an overdrawn director's loan, café Ltd with van/equipment additions, a dormant company (`PROMPT_CORPORATION_TAX.md`) |
| … | `daybook-<slug>` | later | e.g. cafés/hospitality (VAT), consultants/IT contractors, creatives/Etsy sellers, care workers, taxi drivers |

- **One seed per vertical:** `devops/daybook-demo/verticals/<slug>.lua` returns data
  (practice, staff, clients, transaction generators, workflow states). The generic
  `seed-daybook-data.lua` loads it by slug. The reset job loops over every vertical.
- **One published login for all of them:** `demo@daybook.co.uk` is a `viewer` in every
  demo namespace, and the workspace switcher moves between them.
- **Deep links:** `/demos/<slug>` links straight into that namespace if the dashboard
  supports it (e.g. a namespace slug in the URL). If not, the page tells the visitor
  which workspace to pick.
- **Website:** `src/content/demos.json` drives `/demos` (an index of cards) and
  `/demos/<slug>` (the story, the clients, a guided tour, related videos). Only verticals
  whose seed exists are `live`. The rest show as "Coming soon", and the page never
  claims a demo exists before it does.
- **Videos:** `catalogue.json` entries carry a `vertical` so each `/demos/<slug>` page
  lists its own videos.
