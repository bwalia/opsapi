# Property PA — Week 3 "Think": what was built

Scope (SUPPLIER-RESPONSE.md): Today, Prepare Me, next-best action, explainable scoring, playbook retrieval, Teach PA.

| Test | What it checks |
|---|---|
| P01 | Today ranks Sarah #1 with the right reason |
| P02 | Prepare Me: every material fact maps to a record |
| P06 | Coach suggests questions, not a higher offer |
| P07 | "Why #1?" lists the real signals and weights |

Scene 6 (teach a rule, see it in the next brief) is also covered.

## Principle: rules decide, the model phrases

The order of Today, the content of a brief and the coaching questions are built from the record by code. The model
in JobShout only phrases them, and OpsAPI's checks still apply to whatever it says. This makes ranking explainable
(build prompt rule 8) and keeps answers grounded without relying on the model's good behaviour.

## OpsAPI (`projects/property-pa`)

| Route | What |
|---|---|
| `GET /today[?minutes=N]` | My open opportunities ranked by a rules engine (`property_pa/priority.lua`). Each card shows who, the property, the recommended action, why now, the objective, minutes and the signals. With a time budget it says which cards fit and what waits. |
| `GET /today/why/:opportunity` | Rank, score (= the sum of the weights) and every signal, each with its weight, a readable sentence and the record it came from (P07). |
| `GET /prepare/:opportunity` | Prepare Me (`property_pa/brief.lua`), see below. |
| `GET /coach/:opportunity` | Coaching pack: known (cited) vs assumed (inferred), questions to ask before any figure, the rules. It says plainly that the PA never suggests a higher offer. |
| `POST /knowledge/teach` | A manager teaches a rule in one step: the statement becomes a versioned rule, approved straight away when they choose. Agents propose; only managers approve company and team rules; anyone approves their own personal rules. |

Prepare Me contains:
- a snapshot and the last meaningful contact;
- price and offer position, with the seller's figure and our judgement kept apart and labelled;
- decision makers and open promises;
- likely objections, from the record only;
- **unknowns turned into questions**;
- the playbook rules picked by the situation;
- the objective and recommended action.

Every line carries its `ref` (P02).

**Signals and weights** (in `priority.lua`, pinned by the tests):

| Signal | Points |
|---|---|
| Promise due within a day | 30 |
| Valuation / price change / appointment in the last 48h | 25 |
| Next action overdue | 25 |
| Next action due today | 15 |
| Offer awaiting an answer | 20 |
| Hot | 15 |
| Warm | 5 |
| No meaningful contact for 14+ days | 20 |
| No meaningful contact for 7–13 days | 10 |
| Changes waiting for confirmation | 5 |

**Playbook retrieval:** the situation's triggers select the approved rules (company, team and the person's own). The
triggers are: a recent valuation, an offer, an open promise, several decision makers, a price on record, first call,
gone quiet, a deadline, and always.

**Higher-offer guard (P06):** a coach-mode answer that recommends paying more is withheld, even when its figures are
on record. Examples are "increase the offer", "go up to", "meet her at" and "split the difference". The person is told
to ask the PA for the questions to ask first, or to hand the decision to someone with authority.

## Screens (`opsapi-dashboard`)

- **PA today** (`/dashboard/property-pa/today`): ranked cards (Do / Why now / Aim). **Why #N?** shows each signal
  with its +points. Time-budget buttons (all day / 30 / 60 / 120 minutes) with what fits and what waits. Prepare me
  and Capture links on each card.
- **Opportunity page:** new tabs.
  - **Prepare me**: the brief, every line with its source and a label on judgements.
  - **Coach**: known / assumed / ask first / rules, plus "ask the PA" in coach mode.
  - **Ask my PA**: a question goes to JobShout. The checked answer is shown with unknowns, inferences, sources and
    model/prompt version, or why it was withheld.
- **PA knowledge** (`/dashboard/property-pa/knowledge`): teach a rule (Propose / Teach now, scope, triggers),
  approve or reject what's waiting (flagged when it came from the PA), and the rules in use with scope, version and
  triggers.

Menu: **PA today**, **PA capture**, **My opportunities**, **PA knowledge**.

## JobShout (`feat/property-pa-agents`)

- The Today skill reads `/today` and keeps OpsAPI's order; "why" comes from `/today/why`.
- Prepare phrases `/prepare` and cites each line's ref.
- Coach starts from `/coach`.
- Teach proposes and never approves.
- Prompts and skills are at **1.3.0**.

## Tests

`pa_week3_test.py`:
- **P01:** Sarah #1, because her promise is due and the valuation was yesterday.
- **P07:** Why lists signals whose weights sum to the score, and every signal ref grounds. Also covered: the
  30-minute budget, Rick's silence as a relationship risk, and that no one else sees Sophie's Today.
- **P02:** before the voice note, unknowns become questions. After it, every line of the brief passes the grounding
  check, with £235k stated, £240k from the valuation and £225k as a judgement, unconfirmed.
- **Scene 6:** Ashley's rule is approved in one step and appears in Sophie's next brief on Sarah. Agents can't
  approve company rules; personal rules work.
- **P06:** the coach pack has questions with no figures. A coach answer that raises the offer is withheld; one with
  questions and a cited figure is shown.

The full Property Deals + PA regression passes: 14 suites, 1,262 checks.

## Not done / next

- **Same gaps as Week 2:** no run against the real model, and no browser click-through (the local API port is down
  without a colima restart).
- **Weights are code constants.** A per-workspace override can come later if the client wants to tune them.
- **Team scope** is stored and approved like company scope, but there are no team memberships yet: a team rule
  applies to the whole workspace.
- **Week 4:** Manager Today and handoffs UI (P08), GHL + Outlook basics, measurement, P10 completion, P12 (the CRM
  screens work with the AI off), and hardening for one real agent.
