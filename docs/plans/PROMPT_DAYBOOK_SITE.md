# Build prompt: Daybook — the AI tax return brand for UK accountants (daybook.co.uk)

Build **daybook.co.uk**, a marketing website and video library for **Daybook**: AI tax
return software that UK accountancy practices roll out to their clients. Also build a
**Daybook-branded live demo**.

- **OpsAPI stays the engine.** opsapi.org keeps talking to developers, DevOps and SRE (API,
  tenancy, Helm, Lua). Daybook talks to **accountants, practice owners and bookkeepers**.
  It never mentions Lua, nginx, `PROJECT_CODE` or namespaces. The only link back is a
  small "Powered by OpsAPI" line in the footer and on the security page.
- **Daybook sells outcomes:** client statements in, transactions sorted by an AI agent, an
  accountant reviews, then Income Tax (MTD ITSA) and VAT are filed with HMRC. All under
  the practice's own brand.
- **Reuse, don't rebuild.** The videos, scenario copy, brochure, demo deployment pattern
  and video recorders already exist in this repo (§2). The new work is the brand, the
  accountant-facing story, the Daybook demo, and the new videos in §6.

---

## 0. Ground rules

- **Only claim what the software does today.** Every capability on the site must map to
  code in `lapis/` or `opsapi-dashboard/`. Anything else is labelled **"On the roadmap"**
  or left out. This matters most on the integrations page (§5). If you can't find the
  code for a claim, ask; don't write it.
- **Never say "HMRC approved", "HMRC accredited" or "HMRC certified".** HMRC recognises
  software; it doesn't endorse it. Say "files through HMRC's Making Tax Digital APIs".
  Only say "HMRC-recognised" if the product appears on HMRC's published list of
  software, and link that list.
- **A person signs off.** Say it on every page that mentions AI. The AI sorts and
  explains. A rules engine computes the figures (`lib/vat-return.lua`, HMRC's own
  calculation for Income Tax). An accountant or the taxpayer confirms. Nothing is filed
  without a person.
- **No invented proof.** No fake testimonials, customer logos, client counts, "trusted
  by" bars, star ratings or accuracy percentages. Figures from the demo videos (e.g. "274
  of 275 transactions sorted from last year's confirmations") may be used, with the
  scenario named as a demo. Leave a slot for real case studies, hidden until there is
  one.
- **Check dates and thresholds on GOV.UK at build time**, then cite the GOV.UK page:
  - MTD for Income Tax: qualifying income over £50k from April 2026, £30k from
    April 2027, £20k from April 2028;
  - the VAT rules.

  The site is a sales tool for regulated professionals, so a wrong date costs trust.
- **UK English.** Plain words, short sentences. Write for a partner at a 5–50 person
  practice who has ten minutes. No "revolutionise", "seamless", "unlock",
  "cutting-edge" or "game-changer".
- **Privacy and compliance:**
  - UK GDPR privacy notice and cookie notice;
  - no tracking before consent;
  - data location stated plainly (UK hosting, encryption, who can see client data);
  - ICO registration number in the footer once it exists.
- **Accessibility:** WCAG 2.2 AA. Every video has captions and a text transcript on its
  page.
- **No real client or taxpayer data** anywhere: in the site, the demo, the videos or
  fixtures. HMRC sandbox test users only (`sidecars/hmrc-test-users`).

## 1. Decisions to confirm before building

Ask the user about these; don't guess:

1. **Who sells Daybook?** The existing copy says TenthMatrix licenses the application to
   practices (`website/src/content/ai-tax-filing.json` → `agents.intro`). Is Daybook a
   TenthMatrix brand, or its own company? This decides the footer, legal pages and
   contact routing.
2. **Repo name.** The site needs **its own repo**, because this repo's GitHub Pages
   already serves opsapi.org (one Pages site per repo; see §10). Recommended name:
   `bwalia/daybook-website`. It mirrors `website/`: Next.js static export with
   JSON content.
3. **Pricing.** Show prices, show "from £X per client per year", or only "Book a pilot"?
4. **YouTube channel.** Re-upload the 7 existing videos under a Daybook channel with
   Daybook branding, or embed the current uploads as they are?
5. **Go-ahead for the DNS and edge changes in §10.** They publish public hostnames.
   Dry-run everything first, show the user the plan, and wait for a yes.

## 2. What already exists (reuse it)

| Asset | Where | How Daybook uses it |
|---|---|---|
| 7 scenario videos (YouTube), titles, captions, thumbnails, durations | `website/src/content/ai-tax-filing.json` → `videos`; thumbnails in `website/public/img/ai-tax-filing/` | The core of the video library (§6, V01–V07) |
| Scenario copy: pillars, steps, features, "offer it to your clients", FAQ | same JSON | Starting copy for Home, How it works, For practices and FAQ. Rewrite for accountants and remove developer wording |
| Brochure with QR codes per video | `website/brochure-src/` → `/brochures/opsapi-ai-tax-filing-scenarios.pdf` | Rebrand as the Daybook brochure (same layout, Daybook logo and colours, new QR targets on daybook.co.uk) |
| Video recorders (Playwright, captions, speed-up edit) | `devops/demo/landlord-video/` (`record_*.mjs`, `edit.py`, `make_statements.py`, README) | Use the same method for every new video in §6. Synthetic statements from `make_statements.py` |
| Live demo pattern: read-only login, fictional workspace, reset every 30 min, self-heal | `devops/demo/` (`seed-showcase*.lua`, `demo-account-reset.yaml`, `selfheal.yaml`); technote "Building a safe public demo login" | Copy it for `demo.daybook.co.uk` (§4) |
| Tenant theming / white-label | `THEMING_GUIDE.md`, `lib/theme-*.lua` | Make the demo dashboard look like Daybook, which also shows "your brand, not ours" |
| HMRC sandbox test taxpayers | `sidecars/hmrc-test-users` | Demo and video filing runs |
| OpsAPI live demo | https://opsapi.org/demo/ (showcase.demo.opsapi.org) | Keep it as the technical demo. Daybook links to it only from the security / "for your IT team" page |
| Forms and CRM modules | `docs/FORMS.md`, `routes/crm-*.lua` | Daybook's "Book a demo" and "Start a pilot" forms post into an OpsAPI workspace. We use our own product |

**What the tax engine does today** (read the "HMRC MTD" sections of `CLAUDE.md` and the
listed files before writing copy):

- **Statements in:** PDF, CSV and photographed statements (`lib/tax-extraction.lua`),
  with detection of UK bank CSV layouts (Lloyds/Halifax/Bank of Scotland, HSBC, …).
- **AI sorting:** rules → memory of last year's confirmations → LLM
  (`lib/tax-classifier.lua`). Unsure lines are flagged for review.
- **Accountant review queue and corrections:** shown in video V04.
- **Income types:** employment, self-employment, UK and overseas property, pensions,
  savings, dividends, capital gains (`docs/MY_INCOME.md`).
- **MTD Income Tax:**
  - self-employment and UK property cumulative submissions;
  - HMRC calculation;
  - final declaration;
  - the 6-step File My Tax wizard;
  - HMRC fraud-prevention headers.
- **MTD VAT:**
  - deterministic 9-box engine;
  - flat-rate, cash and margin schemes;
  - partial exemption and capital goods scheme;
  - EC Sales List;
  - VAT groups;
  - AI coding of lines (never the figures);
  - accountant/agent access to clients via HMRC agent authorisation (`routes/vat.lua`,
    `lib/hmrc-agent-client.lua`).
- **Peppol e-invoices (UBL):** `lib/vat-einvoice.lua`.
- **Practice-side tools:**
  - clients' filing requests;
  - statements, transactions and reports;
  - invoices, CRM, bookkeeping/accounting (`routes/accounting.lua`);
  - documents (MinIO);
  - chat with the practice.
- **Connecting to other systems:**
  - REST API with API keys;
  - signed webhooks (`WEBHOOKS.md`);
  - TypeScript SDK (`sdk/typescript`);
  - MCP server (`mcp/`) so Claude and other AI agents can work with a practice's data.
- **Branded apps:** a white-label web app per practice; iPhone/Android apps are in the
  enterprise licence (per the existing copy; confirm current status before claiming).

## 3. Site map and page briefs

All copy lives in `src/content/*.json` (same pattern as `website/`) so non-developers can
edit it.

| Page | Path | Purpose and must-haves |
|---|---|---|
| Home | `/` | Hero: "AI does the sorting. Your accountants sign it off. HMRC gets the return." Primary CTA **Book a demo**, secondary **Watch a 5-minute demo** (V01). Then: three-step strip (statements in → AI sorts, accountant reviews → filed through MTD); the MTD deadline band (§0 dates); the video grid (top 4); "under your brand" section; security summary; CTA band |
| For practices | `/for-accountants` | The business case: fewer hours per return, capacity for MTD quarterly updates without hiring, one client app instead of Xero/QuickBooks + email + Dropbox, include it in fees or charge for it. A **capacity calculator** (clients × returns per year × minutes saved, with editable assumptions shown in plain sight and no invented default "savings") |
| How it works | `/how-it-works` | The workflow in 6 steps with screenshots from the demo, the "person signs off" principle, what the AI does and doesn't do, how it learns from last year |
| MTD for Income Tax | `/making-tax-digital/income-tax` | Who's in scope and when (GOV.UK-cited), quarterly updates + final declaration, sole traders and landlords, what Daybook files today |
| MTD for VAT | `/making-tax-digital/vat` | 9 boxes from a rules engine, schemes supported, agent authorisation for practices, Peppol e-invoicing |
| Landlords | `/landlords` | Landlord-heavy practices: mortgage interest (residential 20% credit vs commercial), 100-property scenario (V01, V02, V03, V05) |
| Sole traders | `/sole-traders` | Personal vs business spending, V06 |
| Your brand | `/white-label` | The practice's logo, colours and domain. Clients never see "Daybook" unless the practice wants them to. V07 and the mobile apps |
| Payroll | `/payroll` | Payroll with RTI, payroll bureau for practices, employee app. **Status: in development** (`PROMPT_PAYROLL*.md`). Until RTI passes HMRC testing, the page says "in development, join the pilot", with no claims of filing or recognition |
| Corporation Tax | `/corporation-tax` | Year-end accounts, CT600 with iXBRL, Companies House filing. **Status: in development** (`PROMPT_CORPORATION_TAX.md`), same honesty rule |
| Integrations | `/integrations` | See §5. One card per integration with an honest status badge |
| Demos | `/demo` | The live demo (§4): login, what to try, reset notice. Plus the HMRC sandbox walkthrough |
| Videos | `/videos` and `/videos/[slug]` | The library from §6. Each video has its own page: embed, chapters, full transcript, "what this shows", related videos, CTA. `VideoObject` structured data |
| Security and data | `/security` | UK hosting, encryption, tenant isolation (in plain words: "each practice's data is kept apart, and each client sees only their own"), roles, 2FA, SSO for the practice, audit trail, HMRC fraud-prevention headers, AI model location (local Ollama vs hosted, per `docs/AI_PROVIDERS.md`), "Powered by OpsAPI" with a link to opsapi.org for the practice's IT person |
| Pricing / pilot | `/pricing` | Per decision §1.3. Always ends with the pilot offer: a 30-minute scoping call, then a branded pilot with the agent tested on the practice's sample statements |
| Resources | `/guides/*` | Guides for practices, to rank in search: "MTD ITSA checklist for practices", "Getting clients' bank statements in", "Landlord mortgage interest under MTD", "AI and professional standards: keeping sign-off with a qualified person". Each guide cites GOV.UK / ICAEW / ACCA where relevant |
| FAQ | `/faq` | Rewritten from the existing FAQ, plus: Does the AI file on its own? Who is liable? Can my clients use their phone? Where is data stored? Can we leave and take our data? Do you replace our practice software? |
| About, Contact, Book a demo | `/about`, `/contact`, `/book-a-demo` | Forms post to an OpsAPI workspace (CRM lead + form response) and send a confirmation email |
| Legal | `/privacy`, `/cookies`, `/terms` | Per §1.1 |

**Design:**

- Its own identity, not OpsAPI's: calm, trustworthy, financial.
  - A ledger/daybook motif: ruled lines, a serif display face with a clean sans body.
  - One accent colour.
- Light by default.
- Fast: static export, no client-side JS beyond the calculator, video embeds and forms.
  Lighthouse ≥ 95 on every category.
- YouTube embeds use `youtube-nocookie.com` and load on click, behind a thumbnail.

**SEO:**

- Target terms like "MTD software for accountants", "MTD ITSA software", "AI
  bookkeeping for accountants", "landlord MTD software", "bank statement to tax
  return".
- One H1 per page, plus a sitemap, robots, OG images per page, `Organization`,
  `SoftwareApplication`, `FAQPage` and `VideoObject` schema.

## 4. The Daybook live demo (`demo.daybook.co.uk`)

Copy the opsapi.org/demo pattern (`devops/demo/`) with an accountant's story instead of
a developer's:

- **Deployment:** one OpsAPI release with `PROJECT_CODE=tax_copilot`, its own Postgres,
  and the dashboard themed as Daybook. It runs on k3s1 in namespace `daybook-demo`, with
  a workflow copied from `.github/workflows/deploy-opsapi-showcase.yml`. Hosts:
  - `demo.daybook.co.uk`: dashboard;
  - `demo-api.daybook.co.uk`: API.

  Both go through the edge as in §10.
- **Workspace `daybook-demo`:** a fictional practice, "Example & Co Accountants",
  containing:
  - 6 fictional clients: a 100-property landlord, a small landlord, a sole-trader
    consultant, a VAT-registered café, a CIS builder, and an employee with a side
    business;
  - a year of synthetic statements per client (`make_statements.py`), already sorted,
    with a few lines left flagged for review.
- **Read-only login** published on `/demo` and reset every 30 minutes
  (`demo-account-reset.yaml`, `selfheal.yaml`). Every change is refused with 403, as on
  the OpsAPI showcase.
- **"Try a filing" path:** a second, rate-limited, sign-up-per-visitor sandbox where a
  visitor uploads the sample statements and files against the **HMRC sandbox**, using a
  test taxpayer from `sidecars/hmrc-test-users`. Say clearly that this is HMRC's test
  service and nothing reaches a real tax record.
- **Guided tour on `/demo`:** "1. Open the review queue. 2. Open the landlord. 3. See
  why the AI chose each category. 4. Open the VAT return. 5. Try to change something
  and see the read-only refusal."
- **Keep the existing showcase:** opsapi.org/demo stays as it is, as the technical demo.
  Daybook's `/security` links to it for IT reviewers.

## 5. Integrations page — honest by construction

Build it from `src/content/integrations.json`. Each entry has a `status`:
`available` | `beta` | `roadmap`, plus `evidence`, the repo path that backs it. A build
check fails if an `available` entry has no `evidence` path that exists.

| Integration | Status today | Evidence |
|---|---|---|
| HMRC MTD Income Tax (self-employment, UK property, calculations, final declaration) | available | `lib/hmrc-mtd-client.lua` |
| HMRC MTD VAT, including agent authorisation for practices | available (filing behind `VAT_FILING_ENABLED`) | `lib/hmrc-vat-client.lua`, `lib/hmrc-agent-client.lua` |
| Bank statements: PDF, CSV, photo; UK bank CSV layouts | available | `lib/tax-extraction.lua` |
| Peppol e-invoicing (UBL) | check status | `lib/vat-einvoice.lua`, `docs/plans/VAT_EINVOICING.md` |
| Stripe (practice billing its clients) | available | `lib/stripe*.lua` |
| REST API + API keys, signed webhooks, TypeScript SDK | available | `routes/api-keys.lua`, `WEBHOOKS.md`, `sdk/typescript` |
| Claude / AI agents via MCP | check status | `mcp/` |
| Google / SAML single sign-on for practice staff | available | opsapi.org technotes |
| Xero, QuickBooks, Sage, FreeAgent: import a client's history / migrate off | **roadmap**: not built (the classifier only *recognises* these as subscription expenses) | — |
| HMRC PAYE RTI (FPS/EPS/EYU), CIS300 | **roadmap**: in development | `docs/plans/PROMPT_PAYROLL.md` |
| HMRC Corporation Tax online (CT600 + iXBRL), Companies House accounts | **roadmap**: in development | `docs/plans/PROMPT_CORPORATION_TAX.md` |
| Open Banking live bank feeds | **roadmap**: not built | — |
| Dext / receipt capture apps | **roadmap**: not built | — |
| Practice management (e.g. IRIS, CCH, TaxCalc, BrightManager, Karbon) | **roadmap**: webhooks/API today, no named connector | — |

Roadmap cards say "Tell us you need this" and post into the same lead form, tagged with
the integration, so demand is measured before anything is built.

## 6. Video library

Re-upload the existing videos as decided in §1.4. Every video has:

- captions (`.vtt`) and a transcript page;
- chapters;
- a branded thumbnail;
- a QR code for the brochure;
- an entry in `src/content/videos.json`.

New videos are filmed with the `devops/demo/landlord-video` method: Playwright on the
Daybook demo, on-screen captions, waits sped up by `edit.py`, and a British voice-over
with subtitles. They use fictional data and the HMRC sandbox only. **Integration videos
are filmed only for integrations marked `available`.**

### Existing (reuse; rename for Daybook)

| # | Title | Audience | Length | Source |
|---|---|---|---|---|
| V01 | A landlord with 100 properties, and an AI that learns from last year | Practices with landlord clients | 4:58 | youtu.be/SN6tJKGKN1M |
| V02 | Landlord Self Assessment, filed with HMRC | Practices, landlords | 5:55 | youtu.be/Zw7udRqE8FQ |
| V03 | Landlord VAT return under Making Tax Digital | VAT practices | 2:33 | youtu.be/NoESPLppAlc |
| V04 | The AI sorts, an accountant reviews | Practice partners (the key "you stay in charge" video) | 5:35 | youtu.be/_N9YtS_jMKA |
| V05 | Bank statements to HMRC-ready figures | Practices, clients | 3:36 | youtu.be/aK2fMdtoIUI |
| V06 | Sole trader: AI bookkeeping to HMRC filing | Practices with sole traders | 2:24 | youtu.be/N3hxLIOb2FQ |
| V07 | Your own branded app for your clients | Practice owners | 0:27 | youtu.be/PEyJKsYIN-c |

### New: for practices

| # | Title | Length | What it shows |
|---|---|---|---|
| V08 | Daybook in 90 seconds | 1:30 | Brand intro: statements in → AI sorts → accountant signs off → filed. Cut from V01, V04 and V07 with a new voice-over. Homepage hero video |
| V09 | MTD for Income Tax: what changes for your practice | 4:00 | Explainer, no product for the first 2 minutes. GOV.UK-cited dates, quarterly updates, final declaration, then how Daybook handles each |
| V10 | A morning in the review queue | 5:00 | An accountant clears flagged lines across 6 clients: why the AI was unsure, one-click corrections, and the AI remembering them next year |
| V11 | Onboarding a client in five minutes | 3:00 | Practice invites a client → client signs in to the practice's branded app → uploads statements → the practice sees them sorted |
| V12 | Acting as agent: VAT for your clients | 4:00 | HMRC agent authorisation, the client list, filing a client's VAT return under the agent link |
| V13 | Quarterly updates at scale | 4:00 | One practice, many MTD clients: which quarters are due, aggregating, submitting each cumulative update |
| V14 | Your brand, your domain, your colours | 2:30 | Setting up the white-label app: theme, logo, domain, the client view before and after |
| V15 | Security and data: what your IT person will ask | 4:00 | UK hosting, each practice's data kept apart, roles, 2FA/SSO, audit trail, fraud-prevention headers, which AI model sees what |

### New: for the practice's clients (white-label; practices can share these)

| # | Title | Length | What it shows |
|---|---|---|---|
| V16 | Uploading your bank statements from your phone | 1:30 | Mobile upload, photo of a paper statement |
| V17 | Answering your accountant's questions | 1:30 | Client sees a flagged line, picks the answer, done |
| V18 | Your tax estimate, explained | 2:00 | Reading the estimate, what changes it, when it's final |

### New: integrations (film only when `available`)

| # | Title | Length | Status gate |
|---|---|---|---|
| V19 | Connecting to HMRC (Income Tax and VAT) | 2:00 | available |
| V20 | Getting statements in: PDF, CSV and photos from UK banks | 2:30 | available |
| V21 | Sending e-invoices with Peppol | 2:00 | after Peppol status is confirmed |
| V22 | Connecting Daybook to your practice systems: API and webhooks | 3:00 | available. Aimed at the practice's IT person |
| V23 | Asking Claude about a client's year (MCP) | 2:30 | after MCP status is confirmed; read-only questions, a person signs off |
| V24 | Moving clients off Xero / QuickBooks | — | **roadmap**: script only, don't film |
| V25 | Live bank feeds (Open Banking) | — | **roadmap**: script only, don't film |

**For each new video, deliver:**

- a script (`videos/scripts/Vxx.md`);
- the recorder (`videos/recorders/record_Vxx.mjs`);
- the captions;
- a thumbnail;
- a transcript;
- the YouTube title, description (with a link to its page on daybook.co.uk and
  chapters), and tags.

Open every description with one plain sentence about what the viewer will see.

**Distribution:** a Daybook YouTube channel with playlists "For practices", "For your
clients", "Making Tax Digital" and "Integrations". Cut 30–60 s vertical versions of V01,
V04, V08 and V10 for LinkedIn, where UK accountants are.

## 7. Campaign assets for UK accountants

- **Brochure:** a rebranded `brochure-src`, with all videos and QR codes to
  `daybook.co.uk/videos/<slug>`.
- **One-page "MTD readiness" PDF** that a practice can hand to clients, white-labelled
  with the practice's logo. This is the lead magnet.
- **Email sequence (5 emails)** for practices that book a demo or download the brochure:
  V08 → V04 → V09 → V12 → pilot offer. Plain text, one link each, unsubscribe in every
  email.
- **LinkedIn posts (10)**, each built on one demo fact or one MTD date, linking to a video
  page.
- **Events:** a version of the demo and V08 looped for stands at accountancy shows.
  Leave the show names to the user.

## 8. Acceptance criteria

- [ ] All pages in §3 are built from JSON content, statically exported, Lighthouse ≥ 95,
      and pass axe with no violations.
- [ ] No page mentions Lua, nginx, OpenResty, `PROJECT_CODE`, namespace or Helm, except
      `/security`'s "for your IT team" panel.
- [ ] Every claim on the site is traceable: features cite a repo path in a comment in
      the content JSON, and dates cite GOV.UK.
- [ ] The integrations build check fails on an `available` entry without evidence.
- [ ] `/videos` lists V01–V07 live and V08+ as they're published, each with a transcript
      and `VideoObject` schema.
- [ ] `demo.daybook.co.uk` is live with the read-only login, a 30-minute reset, the
      self-heal job and fictional data only. The sandbox filing path works end to end
      against the HMRC sandbox.
- [ ] Book-a-demo and pilot forms create a lead in the OpsAPI workspace and send a
      confirmation.
- [ ] Cookie consent blocks analytics until accepted. Privacy notice, terms and data
      location are published.
- [ ] daybook.co.uk, `www`, `demo` and `demo-api` serve trusted Let's Encrypt
      certificates from lon1. `www` 301s to the apex. Security headers are set (HSTS,
      CSP).
- [ ] lon2 has mirrored every host. cp.pop0.uk holds the same rule and server ids as
      lon1. The CP → git sync PRs for `lon1` and `pop0` are open, with links given to
      the user.
- [ ] The shared rule `hh-netscaler-grafana-int-3001` still lists every server except
      `www.daybook.co.uk`, and its other hosts still answer as before.
- [ ] opsapi.org's `/ai-tax-filing` page links to daybook.co.uk as "the product for
      accountants", and Daybook's footer links back with "Powered by OpsAPI".

## 9. Order of work

1. Settle the §1 decisions with the user.
2. Brand: name lock-up, logo, palette, type. Then home page and video library with V01–V07.
3. Ship that as the first public version: create the repo, run the Pages workflow, then
   the edge and DNS steps in §10 for the apex and `www`.
4. Daybook demo deployment and the `/demo` page.
5. V08, V04 re-cut, V09 and V10: the four videos that sell to partners.
6. Remaining pages, guides, integrations page with the build check.
7. Remaining videos, brochure, email sequence, LinkedIn cuts.

## 10. Hosting, DNS and edge (same setup as opsapi.org, `*.demo.opsapi.org` and jobshout)

### How the request flows

```
browser → daybook.co.uk --(Cloudflare CNAME, DNS only)--> lon1.pop0.uk (wslproxy edge, Let's Encrypt TLS)
        → rule daybook-website-pages: 305 to https://bwalia.github.io/daybook-website  (GitHub Pages)
browser → demo.daybook.co.uk / demo-api.daybook.co.uk → lon1.pop0.uk
        → rule daybook-demo-default: 305 to 193.237.176.232:8888 (k3s1 traefik-edge, routes by Host)
```

The edge estate:

- **lon1** (`lon1.pop0.uk`, 195.20.255.201) serves all public traffic. Records are live
  on the next request; no reload is needed.
- **lon2 / pop0** (85.190.106.189) copies lon1 every 5 minutes. Never edit it directly.
- **cp.pop0.uk** is the control plane and the source of truth for git. Records are
  imported with `POST /api/projects/import` so ids match lon1. Then the workflow
  `Sync POP config from CP (Go → data/ → PR)` mirrors CP into `bwalia/wslproxy` `data/`
  as PRs.

### State on 2026-11-21 (re-check before changing anything)

- **DNS is already in place.** `daybook.co.uk` and `www.daybook.co.uk` both resolve to
  `lon1.pop0.uk` (195.20.255.201).
- **The apex has no vhost on the edge.** It answers 503 with the fallback certificate,
  which is the TLS error seen when browsing to it.
- **`www.daybook.co.uk` has a stale vhost.** It is attached to the shared rule
  `01dd6df7-0dca-7f50-70bc-88c5f8e61e4a` (`hh-netscaler-grafana-int-3001`, backend
  `193.237.176.232:3001`).
  - Eight other hosts share that rule, including `kubepilot.org`, `dev.jobshout.co.uk`
    and the diytaxreturn S3/vault hosts.
  - **Never use `--update --backend` on www**: it would repoint the shared rule and
    break those hosts.
  - Instead, move www to its own redirect rule and remove it from the shared rule's
    `servers` list.

### 10.1 Website on GitHub Pages (copy `.github/workflows/pages.yml`)

- **Build:** the repo `bwalia/daybook-website` builds a static export and publishes it to
  Pages at `bwalia.github.io/daybook-website/`.
- **No custom domain on Pages.** No `CNAME` file: the edge owns the hostname. A custom
  domain on Pages would redirect back to daybook.co.uk, which loops.
- **No `basePath`** in the site; the edge adds `/daybook-website`.

### 10.2 Cloudflare DNS (zone `daybook.co.uk`)

Use opsapi's idempotent upsert script, as for `*.demo.opsapi.org`. Keep it DNS-only: the
proxy must be off for Let's Encrypt HTTP-01 on the edge.

```bash
# token in ~/.config/cloudflare/token (Zone:Read + DNS:Edit); never paste it into chat
export CLOUDFLARE_API_TOKEN="$(cat ~/.config/cloudflare/token)" CLOUDFLARE_ZONE=daybook.co.uk
for h in daybook.co.uk www.daybook.co.uk demo.daybook.co.uk demo-api.daybook.co.uk; do
  ./devops/scripts/cloudflare-dns.sh --name "$h" --content lon1.pop0.uk --proxied false --dry-run
done
# then the same without --dry-run (apex CNAME works through Cloudflare flattening)
```

Alternative: dispatch `.github/workflows/cloudflare-workflow.yml` once per record.

Also add records for email:

- **Outbound:** SPF, DKIM and DMARC for whatever sends the confirmation emails.
- **Inbound:** MX, if `hello@daybook.co.uk` should receive mail.

### 10.3 wslproxy edge records

Use the `wslproxy-add-domain` skill in the wslproxy repo (`/wslproxy-add-domain`, or
`.claude/skills/wslproxy-add-domain/scripts/add_domain.py`). It runs these stages:

1. preflight
2. generate
3. lon1
4. verify
5. lon2
6. cp import
7. dns

Skip its `dns` stage (`--steps preflight,generate,lon1,verify,lon2,cp`): its zone
lookup and `--dns-from` copy are built for `workstation.co.uk`, and DNS is done in
§10.2.

**Credentials:**

- `~/.config/wslproxy/cp.env` (`CP_API_USER`, `CP_API_PASSWD`);
- SSH keys to lon1 and lon2.

Files only, `chmod 600`.

**Records to create:**

| Rule id | Response | Servers |
|---|---|---|
| `daybook-website-pages` | 305 to `https://bwalia.github.io/daybook-website`, as in `nebuladb-website-pages` | `host:daybook.co.uk` |
| `daybook-www-redirect` | 301 to `https://daybook.co.uk`, preserve URI, as in `opsapi-org-www-redirect` | `host:www.daybook.co.uk` (moved off the shared grafana rule) |
| `daybook-demo-default` | 305 to `193.237.176.232:8888` (k3s1 traefik-edge), as in `opsapi-demo-default` | `host:demo.daybook.co.uk`, `host:demo-api.daybook.co.uk` |

**Server settings** (copy `host:showcase.demo.opsapi.org.json`):

- `ssl_enabled: true`, `ssl_force_https: true`, `ssl_auto_renew: true`,
  `ssl_staging: false`;
- `pop_ids: ["lon1","pop0"]`, or the CP → git sync silently skips them.

**If the script can't express a rule** (e.g. the Pages 305 with a hostname backend):
write the rule JSON by hand, import it into cp.pop0.uk through `/api/projects/import`,
and install it on lon1 the way the script does. Never use plain `POST /api/rules`: it
mints new ids.

**Order of operations:**

1. Dry-run each host.
2. Show the user the generated JSON.
3. Run.
4. Check HTTPS on lon1. The first hit takes 30–60 s while the certificate is issued.
5. Wait for lon2.
6. Read back from CP.

**Then mirror CP to git:**

```bash
gh workflow run 'Sync POP config from CP (Go → data/ → PR)' -R bwalia/wslproxy -f pop_id=lon1 -f env_profile=prod
gh workflow run 'Sync POP config from CP (Go → data/ → PR)' -R bwalia/wslproxy -f pop_id=pop0 -f env_profile=prod
```

- Each run "fails" at its merge step because of branch protection. That's expected.
  Give the user the PR links to approve; don't bypass review.
- Also commit the demo hosts' records under this repo's `.github/wslproxy/data/` next to
  the `*.demo.opsapi.org` ones, for reference.

### 10.4 Demo hosts on k3s1

- Ingresses for `demo.daybook.co.uk` and `demo-api.daybook.co.uk` on traefik-edge, as in
  `devops/demo/hello-apps.yaml`.
- Secrets in WSL Vault under `daybook-demo/config` (copy `devops/demo/seed-vault-demo.sh`).
- The dashboard image is built with `NEXT_PUBLIC_API_URL=https://demo-api.daybook.co.uk`.
- Add `https://demo.daybook.co.uk` to the demo namespace's trusted origins (as
  `opsapi-demo-trusted-origins.yml` does).

### 10.5 Rollback

1. On lon1, delete the server and rule files.
2. Delete them on CP and re-run the CP → git sync. lon2 follows lon1.
3. Put `www.daybook.co.uk` back on its old rule only if the user asks. It pointed at
   Grafana, which was never right for this domain.
