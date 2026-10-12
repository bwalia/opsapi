# Property PA — Product Requirements (DRAFT v0.1)

> **DRAFT, rebuilt by us from the build prompt** while the client's PRD v1.0 (the source of truth) is not in
> the repo. Section numbers follow the build prompt's references (§6 entities, §7 components, §8 authority,
> §11 tests, §13 measurement). Replace with the client's PRD when it arrives.

## 1. Product
An **AI PA for property professionals** that turns ordinary agents into super agents.
- **The CRM is the system of record; the PA is the system of work.** The agent talks to the PA; the PA
  updates the CRM, prioritises, prepares, reminds, coordinates and learns. The agent should almost never fill
  in a CRM form.
- **The PoC question:** would a real agent choose to work through their PA while the CRM quietly updates
  underneath?
- **PoC users:** Seller Agent and Manager. Buyer PA and Progressor PA come later on the same core.

## 2. Principles
- **Private AI only:** no client data goes to public ChatGPT, Claude or Gemini.
- **Grounded or silent:** every fact links to a record.
- **Fact vs inference is always visible.**
- **Humans decide** offers, commitments, legal or compliance judgements and external messages.
- **Audit everything.**
- **Explainable priority.**
- **Knowledge is versioned and approved.**
- **The plain CRM still works if the AI is down.**

## 6. Data
People, properties and transactions are kept separate:
- Person, Organisation, Property, Lead, Opportunity, Deal, Interaction, Task/Next action, Event, Offer;
- Relationship, Risk, Knowledge, Decision, Outcome, ProposedUpdate, HandoffCard.

AI summaries are derived views. Every AI-writable field carries source, confidence, is_inferred and confirmed_by.
(Mapping: `00-gap-map.md` §2. In the PoC, Risk is computed live for Manager Today and Outcome is not recorded yet;
both get tables with risk detection and learning in month 3.)

## 7. Components
- **Daily:** Today (time-aware), Why #1?, Prepare Me.
- **Capture:** Capture (voice/text), Confirm & correct.
- **Thinking with the agent:** Ask PA, Coach.
- **Team:** Handoff, Teach PA, Manager Today.
- **Integrations:** GoHighLevel, Outlook.

(Mapping: `00-gap-map.md` §3.)

## 8. Authority levels
1. **Observe.**
2. **Recommend.**
3. **Prepare.**
4. **Execute with approval.**
5. **Autonomous:** off in the PoC and MVP.

## 11. Acceptance tests
P01–P12 (see `HOW-IT-WORKS.md`), run on fixture data and kept as the model regression set.

## 13. Measurement
- Admin minutes per user per day (forms vs PA).
- Recommendation accept/reject rate.
- AI correction rate.
- Missed promised follow-ups.
- Errors logged for review.

## Roadmap
- **Weeks 0–4:** PoC (Brain, Capture, Think, Work).
- **Month 2, Super Agent:** coaching, scoring, escalation, versioned Teach PA, WhatsApp Business, Alto gate.
- **Month 3, Proactive PA:** research packs, risk detection, collaboration, management view, metrics.
