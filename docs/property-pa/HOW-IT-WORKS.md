# How It Works — a day with the Property PA (DRAFT)

> **DRAFT, rebuilt by us from the build prompt** while the client's original `HOW-IT-WORKS.md` is not in the
> repo. Names, scenes and figures come from the build prompt; everything else is our assumption, marked
> *(assumed)*. Replace with the client's document when it arrives. **All people, numbers and addresses are
> fake.**

## Cast (fixtures)

| Person | Role | Notes |
|---|---|---|
| Sophie | Seller agent (the PA user) | Works through her PA on her phone. |
| Ashley | Manager | Approves negotiation moves and teaches company rules. |
| Sarah | Seller, **22 Station Road** | Second valuation happened yesterday *(assumed)*; said she'd decide after it. |
| Michael | Seller, **14 Green Lane** | Promised a follow-up this week *(assumed)*. |
| Rick | Seller, **18 Market Street** | Quiet for 3 weeks *(assumed)*; relationship risk. |
| James | Buyer | Interested in **94 Milton Road** *(assumed)*. |
| + 6 more sellers | fixtures | So that "I have one hour" has to choose (10 sellers in total). |

## Scene 1 — "Morning. What do I need to focus on today?"
The PA gives a short brief and **ranked priority cards**: who/which property, recommended action, why now,
objective and the PA's view. Sarah is #1: her second valuation was yesterday and she said she'd decide after it.
"Why #1?" lists the real signals (event just happened, promised decision, temperature, days since meaningful contact).
"I have 30 minutes" packs the list to fit.

## Scene 2 — "Prepare me for Sarah."
A 30–60 second brief:
- snapshot, motivation, last meaningful interaction;
- price and offer position, decision makers and any promises;
- likely objections, questions to establish, the relevant playbook and the objective for the call.

**Every fact links to its source record.** Unknowns are said as unknown.

## Scene 3 — the voice note after the call (capture)
Sophie records: *(assumed wording)* "Spoke to Sarah. Second agent valued it at £240k. She won't go below £235k.
Her husband Tom needs to agree. I reckon £225k might work if we can complete in 4 weeks. Call her tomorrow at 11."

The PA transcribes, resolves Sarah and 22 Station Road, and shows a **confirm sheet**:

| Field | Value | Type |
|---|---|---|
| Second valuation (other agent) | £240,000 | stated |
| Seller's stated minimum | £235,000 | stated |
| Decision makers | Sarah + Tom (husband) | stated |
| Price that might work | £225,000 | **SOPHIE'S JUDGEMENT, UNCONFIRMED** (`is_inferred`) |
| Timescale lever | completion in 4 weeks | inferred |
| Next action | Call Sarah tomorrow 11:00, owner Sophie, reason "she'll decide after speaking to Tom" | proposed |

[Confirm] [Change something]. Material fields (price, offer, decision makers, next action time) always need
confirmation. A correction replaces the value and keeps the history. The CRM updates underneath.

## Scene 4 — "Sarah won't move below £235k… what would you do?" (coach)
The PA separates fact from assumption, suggests questions (what does Tom think? what matters more, price
or speed?), refers to the negotiation playbook, and **does not default to a higher offer.**

## Scene 5 — "Ask Ashley…" (handoff)
The PA packages the context, the exact question and its recommendation into a **decision card** on Ashley's
Today ([Agree] [Reply] [Open deal]). Ashley's reply goes back to the deal and into Sophie's next brief.

## Scene 6 — Ashley teaches a rule
"An agent's valuation is not the seller's minimum price — treat it as their anchor." The PA proposes a rule
(category, rationale, triggers). Ashley chooses [Teach company], approves it, and it is versioned. It appears in
Sophie's next brief about Sarah.

## Scene 10 — Ashley's Manager Today
Exceptions only: handoffs waiting, unusual negotiations, relationship risks (Rick), deal risks and top
opportunities. "Everything else is being handled."

## Tests derived from these scenes (P01–P12, our reconstruction)

| Id | Checks |
|---|---|
| P01 | Today ranks Sarah #1 with the right reason. |
| P02 | Prepare Me: every material fact maps to a record id. |
| P03 | Voice note → exactly the fields above. |
| P04 | Next action "call Sarah tomorrow 11:00", owner Sophie, with the reason. |
| P05 | No invented facts anywhere (grounded or silent). |
| P06 | Coach suggests questions, not a higher offer. |
| P07 | "Why #1?" lists the real signals and weights. |
| P08 | Handoff reaches Ashley; his reply returns to the deal. |
| P09 | £225k stored as inferred, labelled unconfirmed. |
| P10 | AI changes show source, model, prompt version and approver. |
| P11 | A correction replaces the value and keeps the history. |
| P12 | The plain CRM screens work with the AI switched off. |

The client's wording of P01–P12 may differ; update the table and the tests when the original arrives.
