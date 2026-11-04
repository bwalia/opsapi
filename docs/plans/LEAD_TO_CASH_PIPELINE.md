# Lead-to-cash pipeline: plan

Status (2026-11-04): **built** on branch `feat/lead-pipeline` (one PR), except what §12 lists as later.
Decisions taken: core CRM for every workspace; members see their own and unassigned leads, managers
everything; the AI runs on every new lead; meetings by calendar invite; payment links left for later.
Added on request: the AI sizes the deal (web price search), suggests the next best action for the
situation, and deals can be passed to partners for a commission (§4.10).
Covers: core CRM leads and deals, the Property Deals module, invoicing and payments. Joy (the portfoliolab plugin in bwalia/joyai) has its own client journey and is out of scope (see §11).

---

## 1. The goal in one picture

```
 Lead comes in ─► NEW ─► CONTACTING ─► QUALIFIED ─► MEETING ─► CONVERTED ─► DEAL STAGES ─► WON ─► INVOICED ─► PAID
 form, website,   │  AI analyses it    calls logged,   checklist    booked,      one button      value,        quote,       payment link
 shop, chat,      │  owner assigned    attempts, SLA   filled in    reminded,                    probability   invoice      or manual
 email, map       │  first call due                                 outcome                                    record
                  └──────────────► NURTURE (come back on a date) or LOST (with a reason), from any stage
```

The question every screen answers: where is this lead, who owns it, what is the next step and when is it due, and how much money is involved.

---

## 2. What exists today, step by step

✓ works · ~ partly · ✗ missing

| Step | Today | Where |
|---|---|---|
| **Lead comes in** | ✓ Six ways: the public endpoint, the form builder, the shop, the AI assistant, typing it in by hand, and Property Deals (Companies House and the map). ✗ The public endpoint has no bot check, although forms do. ~ The new-lead email and Telegram alert fires on only 3 of the 6 ways. | `routes/crm-leads-public.lua:30`, `lib/forms/targets.lua:79`, `queries/ShopLeadQueries.lua`, `lib/agent/tools.lua:387`, `projects/property-deals/property_deals/signals.lua:216` |
| **Owner assigned** | ✗ Leads from the public endpoint and forms arrive with no owner. There are no assignment rules, and the UI has no owner picker. | `crm-leads-public.lua` sets `owner=nil` |
| **AI analysis** | ✗ Nothing runs when a lead arrives. Property Deals has a `lead_triage` agent, but nothing ever starts it. AI only scores a lead's **replies** (hot/warm/cold). | `property_deals/ai/agents.lua:197`, `property_deals/replies.lua` |
| **First call** | ✗ None in core CRM. In Property Deals the "Call the seller back (60 min)" task appears only **after** the lead becomes a deal, and "Call them now" only after a hot reply. | `seed/uk_guaranteed_sale.lua`, `replies.lua:223` |
| **Call logged** | ~ `crm_activities` can record a call, but it **can't be attached to a lead** (no `lead_id`). In Property Deals the outcome is free text on a chase, and the "Called" button on Hot leads logs nothing. | `migrations/crm-system.lua:208`, `components/property-deals/HotLeads.tsx:68` |
| **Meeting** | ✗ Nothing: no meeting record, no calendar invite (.ics), no reminders, no meeting outcome. Viewings exist only as words in seed text. | — |
| **Qualified** | ~ It's just a status value someone picks. There's no checklist and no history of when it changed. | `routes/crm-leads.lua:183` (plain PUT) |
| **Convert to deal** | ~ There are **two** buttons in the same drawer (core "Convert" and Property Deals "Create deal"). Both lose information (see §3). | `queries/CrmLeadQueries.lua:161`, `property_deals/deals.lua:105` |
| **Deal stages** | Core CRM: ~ no board, and "Closed Won" never marks a deal as won (bug, §3). Property Deals: ✓ a full stage engine with gates, tasks, SLAs and health. | `queries/CrmQueries.lua:469`, `property_deals/engine.lua` |
| **Money on the deal** | ~ `crm_deals.value`, plus offer and agreed price in Property Deals. The `fees` field is never used. There's no commission and no offer history. | `property_deals_deals.fees` |
| **Quote** | ✗ CRM has none. The only quotes are shop quotes and field-service quotes. | `shop_quotes`, `fs_quotes` |
| **Invoice** | ~ Invoicing exists, but an invoice can't be linked to a deal or contact. Its email goes through the platform's SMTP, not the workspace's. | `migrations/invoicing-system.lua:34`, `routes/invoices.lua:415` |
| **Payment** | ~ Payments can only be recorded by hand. There's no pay link, and `partially_paid` and `overdue` are never set. | `queries/InvoiceQueries.lua:946` |
| **Accounting** | ✗ Invoices and payments are not posted to the books. | `lib/accounting-engine.lua` |
| **Reports** | ~ Lead counts by status, and Property Deals conversion by month (its "exchanged" column is always 0). ✗ No funnel, no speed-to-lead, no pipeline value, no revenue. | `CrmLeadQueries.lua:249`, `property_deals/reports.lua:76` |
| **Map** | ✓ Deals and properties show on the map. ~ The leads layer is effectively empty, because nothing sets a lead's property. | `projects/property-deals/api/map.lua:113` |

Building blocks we can reuse:
- **Events:** `crm.lead.created` fires for every way a lead is created. Delivery is at-least-once with retries, and core code can subscribe (`helper/plugin-events.lua:97`, `CORE_SUBSCRIPTIONS :553`).
- **AI:** the workspace's own AI providers with metering (`lib/ai-providers.lua:376`, `ai_usage`), and the async AI pattern from ATS (`AtsInterviewQueries.lua:695`).
- **Workspace email:** `NamespaceMail.send` (the workspace's own SMTP).
- **Notifications:** push (`helper/push-notification.lua`), in-app (`helper/notification-helper.lua`) and Telegram.
- **Speech to text:** `routes/voice.lua:111`.
- **Record → invoice precedent:** a field-service job already creates its own invoice (`FieldServiceJobQueries.lua:1302`).
- **Payments:** workspaces' own Stripe Connect accounts (`billing_connect_accounts`, `lib/payment-provider.lua`).
- **Kanban board components:** `@dnd-kit` (`components/kanban/*`) and the Property Deals stage board with gate checks (`app/dashboard/property-deals/deals/page.tsx`).

---

## 3. Broken today: fix these first (Phase 0)

Found by reading the code. I checked the ones marked ✔ line by line; the rest still need confirming as they're fixed.

| # | Problem | Effect | Where |
|---|---|---|---|
| 1 ✔ | Picking "Closed Won/Lost" on the CRM page never marks the deal won or lost: the code only reacts to the literal stage `won`/`lost`. | Win rate and won value are wrong for every deal closed from the UI. | `CrmQueries.lua:469` vs `crm/page.tsx:95` |
| 2 ✔ | **No permission checks on any CRM route** (leads, deals, contacts, accounts, activities, pipelines). `crm_leads` isn't a registered module, even though the event catalog uses it. | Any workspace member can read, change or delete every lead and deal. | `routes/crm-*.lua` (0 `requirePermission`), `helper/project-config.lua:563` |
| 3 ✔ | Converting a lead in Property Deals **wipes the lead's property link**, and the property isn't copied to the deal. | The property is lost, and the map's leads layer stays empty. | `property_deals/deals.lua:194` |
| 4 | Two convert buttons. Both make the person who clicked the owner (not the lead's owner). Core convert drops company, notes and source, can convert a deleted lead, and the UI can set "converted" without converting at all. | Duplicate or half-made deals, and lost history. | `leads-shared.tsx:347,477`, `CrmLeadQueries.lua:161` |
| 5 | The public lead endpoint has no bot protection; forms have a honeypot, a fill-time check and optional Turnstile. | Spam leads. | `crm-leads-public.lua:30` |
| 6 | The new-lead alert fires only for public, form and shop leads. | Leads typed in by hand or by AI get no alert. | `CrmLeadNotificationQueries.notify` callers |
| 7 ✔ | `actual_exchange_at` is never written. | The Property Deals "exchanged" report is always 0. | `property_deals/reports.lua:76` |
| 8 ✔ | The invoice email puts the customer's name and the staff note into HTML without escaping. | HTML injection into customer emails. | `routes/invoices.lua:442-443` |
| 9 | Invoices: `partially_paid` and `overdue` are never stored, numbering has a race, and email ignores the workspace's SMTP. | Wrong statuses, rare duplicate numbers, and email from the wrong sender. | `InvoiceQueries.lua:28,978`, `invoices.lua:415` |
| 10 | Currency defaults disagree: USD in the database, GBP in the code, and the Property Deals UI always shows GBP. | Wrong currency on deals and invoices. | `crm-system.lua`, `ui.tsx:21` |
| 11 | CRM page: the total count is always 0, the activity type filter does nothing, and the pipeline endpoint returns a different shape than the page expects (all from reading the code). | Lists and filters look broken. | `services/crm.service.ts:213`, `crm-activities.lua:69` |

---

## 4. The target flow, stage by stage

For each stage: what the system does by itself, what a person does, and what the AI adds.

### 4.1 NEW: a lead comes in
- **Sources:** all six above, plus:
  - an email to the workspace's mailbox from an unknown sender, which offers to create a lead (Property Deals `mail_sync` already reads mailboxes)
  - later: Facebook and LinkedIn lead ads through a signed inbound webhook.
- **Automatic, within seconds** (one core event handler on `crm.lead.created`, so every way in behaves the same):
  1. **Duplicate check.** If there's an open lead with the same email or phone, add this enquiry to that lead as a note instead of creating a second one. If they're already a customer, flag it.
  2. **Owner.** Assign by the workspace's rules (source, area, kind → person), then round-robin among the people marked as taking leads, then the manager.
  3. **First call due** within the speed-to-lead time (default 60 minutes in working hours; set per workspace).
  4. **Tell the owner** in the app, by push to their phone, and by email.
  5. **Start the AI analysis** (4.2).
- The public endpoint gets the same bot checks as forms (fixes §3 #5).

### 4.2 AI analysis (automatic, no one has to press anything)
- **Reads:**
  - the lead's fields, message and form answers
  - the page it came from
  - any history (existing contact, earlier leads, invoices)
  - the Property Deals details when that module is on.
- **Writes an analysis the person sees at the top of the lead:**
  - a two-line summary and what they actually want
  - an estimated value (a band and a number) and how urgent it is, with the deadline if they gave one
  - a **fit score from 0 to 100, with the reasons** ("budget mentioned", "outside service area"…)
  - warnings: possibly vulnerable, possibly spam, duplicate, existing customer
  - **questions to ask on the first call**
  - **a draft first reply** (email or WhatsApp text) for the person to edit and send.
- **Rules:**
  - It never contacts the lead.
  - It never overwrites anything a person typed.
  - Suggestions carry an "AI" badge and can be accepted with one click.
  - With Property Deals on, it also fills in kind, situation and deadline, which replaces the unreachable `lead_triage` task.
- **Runs again** after a call note, a reply or a meeting outcome ("Update analysis").
- **Cost and failure:**
  - It uses the workspace's own AI provider, with a daily cost cap.
  - If AI is off or unreachable, the pipeline still works. The card says "AI isn't set up — ask an admin", with a link to the setting.
- **Possible spam is never deleted.** It goes under a "Possible spam" filter for a person to confirm.

### 4.3 CONTACTING: calls and messages
- The owner's **"Call <name>"** step is due by the speed-to-lead time. It shows on their list, on their phone and in the daily digest.
- **Call button:** on a phone it dials (`tel:`); on a computer it shows the number. It then asks "How did it go?":
  - Spoke to them
  - No answer
  - Left a message
  - Wrong number
  - Call back later (pick a time; this creates the next step)
  - Not interested (moves to Lost and asks for the reason).
- Notes can be **typed or spoken** (speech to text already exists).
- **Attempt plan**, set per workspace. Default: now, +4 hours, next day, +3 days. After the last failed attempt the system **suggests** Nurture; it never moves the lead by itself.
- **Email from a template** through the workspace's own SMTP, and **WhatsApp** as a click-to-chat link (no paid API in v1). Both are logged on the timeline.
- **Late steps:** the owner is warned at 75% of the time allowed; the manager is told at 100%. This uses the same SLA rules as Property Deals.

### 4.4 QUALIFIED
- A short **checklist** that each workspace can edit. Default: budget, need, timeline, decision maker. With Property Deals on: kind, situation, deadline, property address, funds.
- The AI pre-fills answers from the analysis and call notes. **A person confirms them.**
- The person sets the **estimated value** and **expected close date**; these carry over to the deal.

### 4.5 MEETING (or viewing)
- **"Book a meeting"** records:
  - the type (phone, video, in person, viewing)
  - date and time, and length
  - a place, or a video link (the workspace's default Teams/Zoom/Meet link, or paste one)
  - who is coming (staff and the lead)
  - with Property Deals on, which property it's about.
- **The lead gets an email with a calendar invite (.ics).** It works in Google, Outlook and Apple calendars without connecting any accounts.
- **Staff get the same invite.**
- **Reminders:**
  - the lead: email 24 hours before
  - staff: in-app and phone 1 hour before.
- **Changing or cancelling** sends an updated invite (same invite ID, so calendars update instead of duplicating).
- **After the meeting time,** the owner is asked "Did it happen?" (held, no-show, rescheduled) and writes notes. The AI updates its analysis and suggests the next step: convert, another meeting, or nurture.

### 4.6 CONVERTED: one button, nothing lost
- **There is one "Convert to deal" button.** The second button goes away.
- **It creates or reuses:**
  - an account from the company name
  - the contact
  - the deal: name, value (from Qualified), currency, pipeline, **owner = the lead's owner**, expected close date, and a link back to the lead.
- **It carries over:**
  - notes, source and the AI analysis
  - the activities: calls and meetings stay visible on the deal's timeline.
- **With Property Deals on,** the module adds its deal record through a hook in that same action:
  - **the lead's property is copied** (fixes §3 #3)
  - the workflow's first-stage tasks are created.
- **Afterwards** the lead becomes read-only ("Converted → open deal") and can't be marked converted any other way.

### 4.7 NURTURE or LOST (from any stage)
- **Lost** needs a reason: not interested, no budget, couldn't reach, went elsewhere, spam, duplicate, other.
- **Nurture** needs a "contact again on" date. On that date the lead returns to Contacting with a call step for its owner.

### 4.8 DEAL, MONEY, INVOICE, PAID
- **CRM deals board** (drag between stages; fixes the "won" bug) and a **deal page** showing:
  - value, probability, weighted value, expected close and owner
  - the lead it came from
  - the timeline, quotes, invoices and payments.
- **Quote:**
  - Created from the deal: lines, tax and a "valid until" date.
  - Sent as a PDF by email with an **Accept** link.
  - The public accept page asks for their name and an "I accept" tick.
  - Once accepted, the quote is marked accepted and the deal can move to Won (a workspace setting).
- **Invoice from the deal or an accepted quote:**
  - It copies the lines.
  - It can be a **deposit** (a percentage) now, with the balance later.
  - It's linked to the deal and the contact.
  - It's emailed through the workspace's own SMTP, with escaped text.
- **Property Deals: a fee schedule per deal** (sourcing fee, reservation deposit, balance on completion). At the right stage gate the system makes a **draft invoice for a person to check and send** (an approval, as Property Deals already does for other actions).
- **Payment:**
  - Each invoice has a **"Pay now" link** (Stripe Checkout on the workspace's own Stripe Connect account). With no Stripe account, the invoice shows bank details instead.
  - Stripe's webhook records the payment and sets `paid` or `partially_paid`.
  - A daily check marks invoices `overdue` and sends polite reminders on a schedule the workspace sets.
  - The deal shows "Paid".
- **Accounting** (only when that module is on): post the invoice (receivables, sales, VAT) and the payment (bank, receivables) through `lib/accounting-engine.lua`.

### 4.10 Partners and commissions (added)
- A **partner** is a CRM account with a profile: what it supplies, categories, regions, who receives
  referrals, and the default commission (% of the deal or a fixed fee).
- The AI matches a lead's need against the partner directory and can suggest **“Pass to a partner”**
  as the next best action when the business can't fulfil it itself.
- **Pass to partner** (lead or deal): the partner gets an email with a private link
  (`/partner-referral/<token>`, only a hash is stored) to accept or decline, and later to say they won
  or lost it with the final value. The customer's name and contact details are shared only when a
  person confirms the customer agreed (UK GDPR); otherwise the partner sees the need and its size.
- Referral states: draft → sent → accepted → won → commission invoiced → commission paid (or declined /
  lost / cancelled). Commission is recomputed from the final value; **Invoice the commission** creates a
  draft invoice to the partner linked to the deal; when it's paid (`invoice.paid`) the referral closes.

### 4.9 Reports
- **Funnel:** leads → contacted → qualified → meeting → deal → won → paid, by source, owner and month, with the conversion rate and the **typical time between steps**.
- **Speed to lead:** typical time to first contact, and the percentage within the time allowed.
- **Pipeline value:** open deals × probability by stage, and a forecast by expected close month.
- **Money:** invoiced, paid, outstanding and overdue.
- **AI check:** do high-score leads really convert? This tells us whether to trust and tune the score.

---

## 5. Decisions (my recommendation first)

| # | Decision | Recommend | Why / alternative |
|---|---|---|---|
| D1 | Where does the pipeline live? | **Core CRM, for every workspace.** Property Deals adds its property pieces through hooks. | Invoicing and CRM are core, and every workspace that has leads benefits. The alternative, building it only in Property Deals, would leave other workspaces with nothing. |
| D2 | Lead stages | **A fixed set** (New, Contacting, Qualified, Meeting, Converted, Nurture, Lost); workspaces can rename the labels. | Reports and automations need stages they can rely on. Fully custom lead stages cost a lot for little gain. Deal stages stay custom per pipeline. |
| D3 | One place for calls and meetings | **`crm_activities`**, with a `lead_id` and meeting fields added. Planned activities are the to-do steps. | It already exists, already has events, and is already shown in CRM. Property Deals keeps kanban tasks for **deal** work after conversion, and its pre-deal "Call now" task becomes a planned call. |
| D4 | AI | **Automatic on every new lead**, using the workspace's provider, with a daily cost cap; it only suggests and drafts. | "AI analyses it" is the request. The alternative is a button only, which is cheaper but slower to first call. |
| D5 | Who sees which leads | **Members see their own and unassigned leads; managers see everything.** | Today every member sees and can delete everything (§3 #2). |
| D6 | Meetings, v1 | **Calendar invites by email (.ics) and reminders.** Calendar sync comes later. | It works with every calendar and needs no account connections. Google/Microsoft sync, free/busy and a self-booking page come in a later phase. |
| D7 | Quotes | **Part of invoicing** (a "quote" document type that reuses lines, tax, PDF, email and numbering as `QUO-0001`). | No second line-item system, and accept → invoice is a copy. The alternative is a separate quotes module. |
| D8 | Payments | **Stripe Checkout on the workspace's own Stripe Connect account**, falling back to bank details. | The money must go to the workspace, not the platform, and Connect accounts already exist from billing. |
| D9 | Turning on permission checks | **Add a `crm_leads` module and checks on every CRM route, and give existing roles the access they effectively have today**, so nobody is locked out on the day it ships. A "Sales" role is added for new invitations. | This fixes the security gap without surprises. Prove it with the API regression sandbox (main vs branch on copies of the database). |
| D10 | PR shape | **One branch and one PR, one commit per phase. I stop after each phase so you can try it on int.** Phase 0 can go out on its own first if you want the fixes live sooner. | This follows your one-PR-per-work-item rule. |

---

## 6. Data changes (core migrations, keys with the `zz…` prefix so they sort last)

| Table | Change |
|---|---|
| `crm_leads` | Set `status` to the stages in D2, with a CHECK (map old `contacted` → `contacting`). Add: `next_action_at`, `next_action_type`, `first_contacted_at`, `last_contacted_at`, `contact_attempts`, `assigned_at`, `estimated_value`, `currency`, `expected_close_date`, `nurture_until`, `ai_score`, `ai_summary`, `ai_analysed_at`. |
| `crm_lead_stage_history` (new) | lead, from, to, at, by, reason. Feeds the funnel and timing reports. |
| `crm_lead_analyses` (new) | One row per AI run: status, model, input fingerprint, output JSON, `ai_usage` link, error. |
| `crm_lead_settings` (new, or extend `crm_lead_notification_settings`) | Speed-to-lead minutes, working hours, attempt plan, AI on/off and cost cap, qualification questions, default meeting link, reminder times, lost reasons. |
| `crm_lead_assignment_rules` (new) | Order, conditions (JSON: source, area, kind), assignee or round-robin pool. |
| `crm_activities` | Add `lead_id`, `outcome`, `ends_at`, `location`, `meeting_url`, `attendees` JSONB, `ics_uid`, `ics_sequence`, `reminders_sent` JSONB. |
| `crm_deals` | Add `lead_id`. |
| `invoices` | Add `deal_id`, `document_type` (`invoice` \| `quote`), `valid_until`, `accepted_at`, `accepted_by_name`, `accept_token_hash`, `payment_link_url`, `stripe_checkout_session_id`. Extend the status CHECK with `accepted`, `declined` and `expired` for quotes. Number quotes separately. |
| `property_deals_deals` | Use `fees` for real: a fee schedule `[{label, amount, due_at_stage}]`. Set `actual_exchange_at`. |

---

## 7. Server work

- **`core.leads` event handler** on `crm.lead.created`: duplicate check, assignment, first step, alerts, then queue the AI analysis. This replaces the three hand-wired `notify` calls.
- **Lead endpoints:**
  - `POST /crm/leads/:uuid/stage` (checks the rules and records history)
  - `/assign`
  - `/calls` (log a call with its outcome)
  - `/meetings` (book, change, cancel, record the outcome)
  - `/analyse` (run the AI again)
  - `/timeline` (activities, stage changes, analyses, replies and form answers in one list)
  - an improved `/convert` with a plugin hook (`crm.lead.converting`) so Property Deals can add its deal record.
- **Jobs (every minute or daily):**
  - late-step warnings (75%/100%)
  - meeting reminders
  - "did the meeting happen?" prompts
  - nurture dates coming back
  - overdue invoices and their reminders.
- **AI:** one prompt with a fixed JSON shape, run through `lib/ai-providers.lua` with the workspace's chain. Store the result in `crm_lead_analyses` and fill the summary columns on the lead. A mock provider for tests.
- **Calendar invites:** a small RFC 5545 builder (UID, SEQUENCE, METHOD REQUEST or CANCEL), attached through `NamespaceMail`.
- **Quotes and invoices:** create a quote from a deal; a public accept page (token, rate-limited); create an invoice from a deal or quote (deposit or balance); a Stripe Checkout link per invoice; a branch in the Stripe webhook that writes `invoice_payments`; `partially_paid` and `overdue` statuses; a row lock on numbering.
- **Accounting posting** when an invoice is sent and when it's paid (only when accounting is on).
- **Permissions:** the `crm_leads` module, `requirePermission` on all CRM routes, a backfill for existing roles, a "Sales" role preset, and the own-or-unassigned visibility rule.

## 8. Dashboard work

- **Leads board:** one column per stage. Drag moves the stage, with the same rules as the API. Filters: mine, unassigned, late, hot, possible spam. The current list stays as a view.
- **Lead page (`/dashboard/leads/[uuid]`):**
  - the stage, owner, score, value and next step at the top
  - the **AI card** (summary, why this score, questions to ask, draft reply)
  - a **timeline**
  - big plain buttons: **Call**, **Email**, **WhatsApp**, **Book meeting**, **Qualify**, **Convert to deal**, **Nurture**, **Lost**.
  - The Property Deals panel stays where it is.
- **"My next steps"** on the Leads page and the home page: due now, late, and today's meetings.
- **CRM deals board and deal page:** money, quotes, invoices, payments and the source lead.
- **Quote screen** (built from the invoice editor) and the **public accept page**.
- **Settings → Leads:** speed-to-lead time, working hours, attempt plan, assignment rules, AI on/off and cost cap, qualification questions, meeting link, reminders and lost reasons.
- **Reports:** funnel, speed to lead, pipeline value, money and the AI check.
- **General:** themed dialogs only, plain words, no dead ends. Every empty state says what to do next.

## 9. Phases (each one ends with something you can try)

| Phase | What you get | Size |
|---|---|---|
| **0. Fix what's broken** | Everything in §3. | S–M |
| **1. Pipeline without AI** | Stages and history, owner rules, the first-call step and late warnings, logging calls on leads, the attempt plan, nurture and lost, alerts on every source, the leads board, lead page and timeline, and permission checks. | L |
| **2. AI analysis** | Automatic analysis, the AI card, the draft first reply, re-running after calls, the cost cap, and Property Deals triage merged in. | M |
| **3. Meetings** | Booking a meeting or viewing, calendar invites, reminders, the "did it happen?" prompt, and outcomes. | M–L |
| **4. One convert, real deals** | One convert button with nothing lost, the Property Deals hook (property kept), the CRM deals board and page, probability, expected close and pipeline value. | M |
| **5. Quote → invoice → paid** | Quotes and the accept link, invoice from a deal (deposit or balance), the Property Deals fee schedule, the Stripe pay link and webhook, overdue status and reminders, and accounting posting. | L |
| **6. Reports and polish** | Funnel, speed to lead, pipeline value, money and the AI check, plus anything Phases 1–5 turned up. | M |
| Later | Google/Microsoft calendar sync and a self-booking page (Joy's slot logic can be reused), SMS and WhatsApp providers, Facebook/LinkedIn lead ads, e-signature, and moving Joy onto these events. | — |

## 10. How we prove it works

- **End-to-end script** (`lapis/spec/lead-pipeline-e2e/run.sh`, in the same style as the forms and chat proofs), run against a mock AI, Stripe in test mode (stripe-mock) and email in dry-run:
  1. A public form lead arrives.
  2. It gets an owner and an analysis; the first call is due in 60 minutes.
  3. Call 1: no answer. Call 2: spoke to them, qualified.
  4. A meeting is booked: the invite is sent and the reminder fires.
  5. The meeting is held; the lead is converted and the deal has a value.
  6. A quote is sent and accepted through the public link.
  7. A deposit invoice is created and paid by the Stripe webhook.
  8. The funnel report shows each step with its times.
  Run the same script with Property Deals on: a seller lead with a property → a deal on the map with the property kept → a fee invoice at the stage gate.
- **Permissions:** run the API regression sandbox (main vs branch, with copies of the database and no internet) to show that existing users keep their access and only the new rules change.
- **UI:** Cypress through the flow as a first-time user, and screenshots of each screen.

## 12. Built vs later

Built (one PR): everything in §3 except the invoice number race, §4.1–4.8 except quotes and pay links,
§4.10, the board/insights/list, the lead page, settings, partners, and the checks in §10
(`lapis/spec/crm-lead-pipeline-pure_spec.lua`, `lapis/spec/lead-pipeline-e2e/` check.py, ai_check.lua,
pd_check.lua, `opsapi-dashboard/cypress/e2e/leads-pipeline.cy.ts`).

Later:
- **Payment links on invoices.** Workspaces can already connect Stripe (Billing → Stripe Connect
  onboarding), but invoices have no checkout link or webhook into `invoice_payments`; payments are
  recorded by hand. Next step: Checkout on the workspace's connected account + a webhook branch.
- **Quotes** as an invoicing document type with a public accept link.
- `partially_paid` / `overdue` invoice statuses, the numbering race, accounting posting.
- Calendar account sync (Google/Microsoft free/busy), a self-booking page, paid SMS/WhatsApp, lead ads.
- CRM deals board/page in core (Property Deals has its own); deal-level referrals from a deal page.

## 11. Out of scope, and how Joy fits

- **Joy** (the Portfolio Lab CRM in bwalia/joyai) keeps its own client journey, calls and templates. Later it can listen to the same `crm.lead.*` events instead of having its own intake.
- **Not in v1:**
  - calendar account sync and free/busy
  - a self-booking page
  - paid SMS and WhatsApp APIs
  - lead-ad integrations
  - e-signature beyond "I accept"
  - currency conversion.
