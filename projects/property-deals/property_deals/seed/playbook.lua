-- Default playbook for a UK property-sourcing / portfolio business. Seeded once per workspace on setup
-- (never overwritten); managers edit it in Deals settings → Playbook. Keep each section short and concrete:
-- the PA quotes it to the team and follows it when it drafts.
return {
    { key = "who_we_are", title = "Who we are", body = [[
We buy, source and sell UK residential property: below-market homes from motivated sellers, matched to
investors (BTL, BRR, HMO, flips) and our own portfolio. We are fast, honest and calm. We never pressure a
seller. Our edge: certainty and speed (cash buyers, 7-28 day completions) and knowing what investors want.]] },
    { key = "roles", title = "Roles", body = [[
- Acquisitions (operator): calls sellers and agents, books viewings, keeps every deal task moving.
- Manager: approves offers and anything to a vulnerable seller, owns pricing and escalations.
- Dispositions: matches deals to buyers, sends deal packs (always approved first).
- Compliance: AML/ID checks; a named person signs every check off.
- Builders / site managers: work the renovation boards.]] },
    { key = "daily_rhythm", title = "Daily rhythm", body = [[
1. Hot leads first: anyone who replied keenly gets a call within 15 minutes.
2. Overdue blocking tasks, then today's.
3. Approvals waiting (don't leave drafts more than 2 hours).
4. New Companies House news: send personal follow-ups.
5. End of day: log every call (outcome + next step) and set the next task.]] },
    { key = "seller_call", title = "Seller call script", body = [[
Open: thank them, say who we are in one line, ask "what's prompting the move?".
Find out: situation (probate, divorce, relocation, arrears, tenanted…), timescale and any deadline, what they
owe, condition and known issues, who else is involved (co-owners, executors), and what they hope to get.
Never quote a price on the first call. Close with the next step: "I'll look at the numbers and call you
back by <day> with options." Log the call with outcome and next step.]] },
    { key = "buyer_qualification", title = "Buyer qualification", body = [[
Ask: strategy (BTL, BRR, HMO, flip, blocks), areas, price range, how they fund it (cash, mortgage, bridging),
proof of funds and when it expires, minimum yield/discount, refurb appetite, deal-breakers, how fast they can
commit. No deal pack goes to a buyer without proof of funds on file.]] },
    { key = "follow_up_rules", title = "Follow-up rules", body = [[
- Open with something real about them (a company they formed, a post, a deal they did). Never fake it and
  never say how we found it.
- One idea and one easy question per message. Under 90 words for email, under 300 characters for WhatsApp/SMS.
- Cadence for a new lead: day 0, day 2, day 5, day 12, then monthly. Stop the moment they reply.
- Agents and solicitors: offer to solve their problem (hard-to-sell stock, clients needing a fast sale).
- Every message is approved by a person before it goes.]] },
    { key = "objections", title = "Objection handling", body = [[
- "Your offer is too low": explain the numbers (comparables, refurb, our costs) and what they gain (speed,
  certainty, no fees, no chain). Offer a range, not a single take-it-or-leave-it.
- "I'll try an estate agent first": agree it's sensible, offer to stay in touch, follow up in 4-6 weeks.
- "Not now": ask when to come back and set that task.]] },
    { key = "compliance", title = "Compliance", body = [[
- GDPR/PECR: a private person needs a recorded consent basis before marketing messages; companies (B2B) may
  be contacted with legitimate interests. Anyone who says stop is never contacted again.
- Vulnerable sellers (bereavement, illness, debt, age, distress): be patient, involve family if they wish,
  a manager approves every message and offer.
- AML: ID + proof of address + source of funds before exchange. A named person signs off each check.
- We never use public AI services with customer data: our AI runs on our own servers.]] },
    { key = "escalation", title = "When a human must take over", body = [[
Hand to a person (never let the AI decide): offers and prices, anything legal, complaints, vulnerable
people, a seller who is upset, anything that commits money, and anything the playbook doesn't cover.]] },
}
