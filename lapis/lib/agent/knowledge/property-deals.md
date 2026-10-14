---
title: Property Deals
pages: /dashboard/property-deals
api: /api/v2/property-deals
modules: property_deals_deals, property_deals_leads, property_deals_tasks, property_deals_approvals, property_deals_properties, property_deals_buyers, property_deals_suppliers, property_deals_compliance, property_deals_reports
suggestions: Create a deal for 12 Brick Lane, London E1 6AN, we're buying, offer £610k | What's most urgent today? | Why is this deal red? | What's waiting for my approval?
readonly: false
---
# Property Deals
Deals for buying and selling homes, from first lead to completion. Rules (not AI) set deadlines, urgency, deal health and money at risk. AI agents only draft; nothing is sent, booked or signed until a person approves it in Approvals.

## Pages
- **Today** (/dashboard/property-deals/today): "Due this week" first — deal tasks and renovation jobs grouped Overdue / Today / Tomorrow / Later (managers see the whole team, with an Only mine switch; 7/14/30 days) — then my open tasks by urgency score (hover the score for why), red deals, approvals waiting, money at risk. Each task: Do it, Let AI do it, Assign, Snooze (needs a reason), Log contact. Take the tour restarts the guided tour.
- **Renovations** (/dashboard/property-deals/renovations): build projects. Each is a kanban project (open it under Projects) whose columns are the stages — Survey & quotes, Strip-out, Structural, First fix, Plastering, Second fix, Decorating, Snagging & sign-off, Done — with dated job cards. Start one here or from a deal's Renovation tab; pick builders/site managers to add to the board. Builders get the "Builder / site manager" role. Purchase orders for the job are linked from each renovation.
- **Hot leads** (top of Today): leads who just replied keenly — call them now (Call button dials, Called closes the task). On a lead (Leads page drawer): Companies House links (company number, officer — Find on Companies House), Recent news (checked daily; paste a post they made — we never fetch social networks), Replies (emails arrive automatically; log WhatsApp/SMS/call replies — a hot one raises a call task and alerts the owner by app push, email, ntfy, Telegram or SMS as set up). Draft a personal follow-up (email / WhatsApp / SMS, with an optional steer) or "Follow up about this" on a news item: the AI writes one message opening with their news; it waits in Approvals and is only sent once a person approves (WhatsApp opens ready to send). News from Companies House starts a draft by itself. Leads who said stop are never drafted to. Alert channels: Deals settings → Data connectors (ntfy, Telegram bot, Android SMS Gateway — free/open source) and My notifications (ntfy alerts only reach people who set their own topic — "generate" makes a private one — and only say "open OpsAPI", never the lead's name or number). Leads, their replies and news, hot leads and the inbox need the Leads permission (property_deals_leads); builders don't have it. An emailed "unsubscribe" opts a lead out only when the sender was verified; otherwise a "Check: did … ask not to be contacted?" task asks a person to confirm.
- **Deals** (/dashboard/property-deals/deals): board by stage (dragging checks the stage gate and lists what is missing) or list. New deal creates a property and the first stage's tasks.
- **Deal page** (/dashboard/property-deals/deals/{uuid}): health and reasons, target and forecast dates, money at risk, stage track with Move to / Next, Edit deal; tabs Tasks, Enquiries & blockers, Chase log, Documents, Compliance, Buyers, Renovation, Timeline.
- **AI research** (on the deal page): the deal autopilot. A new deal is pinned on the map; with the workspace's Google Gemini provider a Google search finds notes on the area and firms nearby, shown as Google returned them (a person clicks Add to Suppliers or Ask for a quote on a firm); with the SRA register connector (a free key) the nearest solicitors doing residential property work become suppliers and the nearest 3 get quote requests that wait in Approvals. Only the address goes to Google. Research again re-runs it.
- **Approvals**: AI drafts and requests with agent, model and cost; Edit, Approve, or Reject with a note (the agent redrafts with it).
- **Deal finder**: map with a pin and radius (5-50 miles), layers (including Suppliers: conveyancers and other firms near the pin), a property card with comparables and the top buyers, saved searches with daily alerts.
- **Buyers**, **Suppliers** (Book nearest), **Compliance** (a named person signs off), **Deal reports** (export CSV/JSON), **Deals settings** (templates, SLA and urgency, AI providers and agents, data connectors, mailboxes, my notifications).

## Answers
- My tasks and the day: `GET /api/v2/property-deals/today`
- What's due soon (deal tasks + renovation jobs): `GET /api/v2/property-deals/due?days=7`
- Leads to call now (hot replies): `GET /api/v2/property-deals/hot-leads`
- A lead's recent news (Companies House, captured posts): `GET /api/v2/property-deals/leads/{uuid}/signals`
- A lead's replies and how hot they were: `GET /api/v2/property-deals/leads/{uuid}/replies`
- Renovations and their progress: `GET /api/v2/property-deals/renovations`
- A deal page in one call: `GET /api/v2/property-deals/deals/{uuid}/overview`
- Why a deal is red: `GET /api/v2/property-deals/deals/{uuid}/health`
- What blocks the next stage: `GET /api/v2/property-deals/deals/{uuid}/gate`
- Approvals I can decide: `GET /api/v2/property-deals/approvals/inbox`
- The AI's research on a deal (official area data, area notes, nearby firms, quote requests): `GET /api/v2/property-deals/deals/{uuid}/research`

## Create a deal (only when the user asks for one)
- You need the address (line 1 and town) and the postcode, written like E1 6AN. No postcode: ask_user once; never invent one. Deal type: buying (buy), selling (sell), buy and assign (buy_and_assign) or sourcing; ask if it isn't clear.
- Look first: `GET /api/v2/property-deals/properties?q=E1 6AN` and, if the home is there, `GET /api/v2/property-deals/deals?property_uuid={uuid}`. An open deal on it already: show it and don't create another.
- A new home: `POST /api/v2/property-deals/properties` with {"address_line1": "12 Brick Lane", "town": "London", "postcode": "E1 6AN", "tenure": "unknown"} (tenure freehold or leasehold when the user says so).
- Then `POST /api/v2/property-deals/deals` with {"property_uuid": "<uuid of that property>", "deal_type": "buy", "offer_amount": 610000} and, when given, "name", "agreed_price", "target_completion_date" (YYYY-MM-DD) and "notes". Money as plain numbers (£610k is 610000). Call each once.
- Then reply with a link [the address](/dashboard/property-deals/deals/{uuid}) and say the autopilot is pinning it on the map and researching the area (official planning, flood, crime and price data; a Google search when the workspace has Gemini; SRA conveyancers, whose quote requests wait in Approvals).

## Rules
- Never approve, reject, send or move stages for the user: explain where the button is.
- Create a deal only when the user asks for one; never change or close a deal here.
- Compliance checks are passed or waived only by a named person.
