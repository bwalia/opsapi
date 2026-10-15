# Deal autopilot

When a deal is added, the AI gets to work on it by itself. A person still decides anything that leaves OpsAPI.

| Step | What happens | Needs |
|---|---|---|
| **Pin** | The home goes on the Deal finder map (postcode → point, postcodes.io). | Nothing (a postcode). |
| **Research** | One Google Gemini call with Google Search finds notes on the area (transport, schools, amenities, flood risk, planning, prices) and firms nearby (conveyancers, surveyors, EPC assessors, estate and letting agents). | The workspace's own Google Gemini provider. |
| **Register** | The nearest firms on the SRA register that do residential property work, with an email, are added to Suppliers as conveyancers, with their place on the map. | An SRA register connector (a free key). |
| **Quotes** | A quote-request email to the nearest 3 of those firms is drafted. It waits in Approvals, and nothing is sent until another person approves it. | Setting `autopilot_quote_requests` (on by default). |

The deal page shows all of it in its **AI research** card, and **Research again** runs it again. It also runs again when a deal gets a different property. The Deal finder's **Suppliers** layer shows the firms.

Code: `projects/property-deals/property_deals/research.lua`, `register.lua`, `api/research.lua`, `events/autopilot.lua`.
Tests: `spec/research_test.py`.

## What goes where

- **To Google:** only the address (street, town, postcode). The seller, the buyer, the price and the notes are never sent. The search is billed to the workspace's own Gemini key. Google charges per search on top of tokens (see its pricing). Tokens and cost count toward the workspace's daily AI budget (Deals settings → AI) and show in reports. Each call is also metered in `ai_usage` (feature `property_deals_research`).
- **To the SRA:** the workspace's key fetches the register at most once a day. A copy of the offices of authorised firms that do residential property work is kept in `property_deals_register_offices`.
- **To the firms:** nothing, until a person approves a quote request in Approvals. Approved requests go out through the workspace's own SMTP and appear on the deal's chase log.

## Google's rules for search results

Gemini's terms for Grounding with Google Search shape how the research behaves:

- **Shown unchanged:** the answer appears as it came, together with Google's **Search Suggestions** (an HTML snippet, shown in a sandboxed frame) and the pages it used.
- **Kept two years at most:** the answer is kept for that long as the deal's research. `R.sweep` clears older ones, whatever the workspace's AI-run retention.
- **Never stored or used automatically:** OpsAPI does not copy firms from the search into Suppliers, and does not crawl their websites.
  - A person adds a firm with **Add to Suppliers**. That is an individual result saved by the person who saw it, which the terms allow. The firm is marked `source = ai_research`.
  - **Ask for a quote** drafts the email for approval.

The automatic directory and quote drafts come from the SRA register instead. Its terms allow the data to be stored and reused in our product, with attribution, as long as it isn't used for advertising.

## Setting it up (per workspace)

1. **Deals settings → AI & JobShout → add provider:** type *Google Gemini*, the workspace's API key, and a model that supports Google Search grounding (for example a current Gemini Flash).
2. **Deals settings → Data connectors → add *SRA register of solicitors*:**
   - The key is free: go to www.sra.org.uk/datasharing → API portal → Products → *SRA Data Share API Version V1* → Subscribe → Profile → Show key.
   - The key is personal to whoever registered it, which is why each workspace adds its own.
3. **Settings → SLA, urgency & more:**
   - `autopilot_on_new_deal`: research every new deal, on by default. `ai_auto_runs` off also stops it.
   - `autopilot_radius_miles`: how far to look, default 10.
   - `autopilot_quote_requests`: draft quote requests, on by default.

## Limits and known gaps

- **SRA field names are unconfirmed.** The SRA's V1 field names aren't public. The parser reads the usual spellings (`PracticeName`, `Offices`, `WorkArea`, `PhoneNumber`...) case-insensitively. If the SRA renames a field, the connector shows "no firms could be read from the SRA's answer" as its last error rather than storing wrong data. **Check the first real sync.**
- **Only SRA-regulated firms are found automatically.** That leaves out licensed conveyancers (CLC), surveyors (RICS), EPC assessors and estate agents. They appear in the web search, and a person adds them with a click.
- **Firms over a postcode-area border can be missed.** Offices are put on the map by postcode area (YO, LS...) as deals need them, so a firm just across an area border shows up once a deal in its own area has been researched.
- **The Gemini model must support Google Search grounding.** Otherwise the research step fails with the provider's reason.

## Troubleshooting

| You see | Do this |
|---|---|
| "Add Google Gemini in Deals settings..." | Add a Gemini provider with a key and a model. |
| "Add the SRA register (a free key)..." | Add the SRA connector. |
| "SRA register: the SRA answered HTTP 401 (check the key)" | Re-save the connector with the key from the SRA portal. |
| "The home isn't on the map yet" | The property has no postcode, or postcodes.io didn't know it. Add or correct the postcode, then Research again. |
| Research "failed": Authentication failed (401/403) | Check the Gemini key. |
| Research "failed": Not found (404) | Check the Gemini model name. |
| "The nearest conveyancers were already asked for a quote" | Nothing new to draft. The earlier requests are listed on the deal. |
