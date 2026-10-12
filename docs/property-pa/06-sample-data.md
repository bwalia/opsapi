# Property PA — sample data, and how the PA learns

A workspace with sample data shows every PA screen working before a real model is connected. Load it with:

```http
POST /api/v2/property-pa/demo/reset
{ "story": true }                          # optional: "sophie_user_uuid", "ashley_user_uuid"
```

or `scripts/reset-demo.sh` with `STORY=true`. Platform admins only (for anyone else the route doesn't exist). Without
`story` you get just the people (the How It Works fixtures). A reset removes only sample rows: the workspace's real
records and its seller playbook are left alone, and a sample person someone has since worked on is kept. All people,
numbers and addresses are made up.

**Sophie** is the agent and **Ashley** the manager. In a small workspace both can be you.

## What's in it

The people: 10 sellers and 1 buyer, each with an address, a motivation, a temperature and a last contact.

| Who | What the sample adds | Where to look |
|---|---|---|
| Sarah Hughes, 22 Station Road | A second valuation yesterday; she promised to decide after it. One shown answer: "When is Sarah deciding?" | Today #1, Why #1, Prepare, Coach |
| Michael Grant, 14 Green Lane | A voice note 4 days ago. The PA proposed 6 changes and Sophie confirmed 5. She **corrected** its guess "hot" to "warm". A next action (send comparables), a deadline (Christmas). One shown answer citing his £260,000 minimum | Capture sheet, History, Audit |
| Priya Shah, 7 Mill Close | A note 2 days ago. The PA misheard £210k as £215k and Sophie **corrected** it. It read "keen" as "hot" and she **rejected** that. A handoff answered by Ashley: "up to £205k once Raj confirms in writing" | Capture sheet, Prepare (manager reply), timeline |
| Helen Price, 3 Orchard Way | A note from an hour ago, **waiting** for Sophie: her daughter Jo now decides, and they'll wait for the care home | Capture (confirm sheet), Today "changes waiting" |
| Dev Patel, 40 King Street | A £150k offer waiting, plus an **open handoff**: "Can I go to £155k?" Two answers **withheld** (below) | Manager Today, PA insights |
| Gary Lowe, 51 Church Street | Our position (£255k, a judgement) is 15% below his £300k | Manager Today, "unusual negotiations" |
| Rick, Tom, Ann, Linda | Gone quiet (9 to 60 days) | Today, Manager Today, "relationship risks" |
| James Carter | A buyer for 94 Milton Road | My opportunities |

### Answers the checks withheld

Every PA answer is checked in OpsAPI before anyone sees it. The sample includes two answers the checks stopped:

- **"What will Dev accept?"** The answer says "£158,000", but that figure isn't in the record and no source is cited, so it is withheld.
- **"Dev is pushing back on £150k. What should I say?"** The coaching answer says "raise your offer to £160,000". The PA never suggests paying more (a person with authority decides), so it is withheld.

These are the same checks a live answer goes through. The sample only supplies the model's words; the checks really
run. Every sample run and proposal is labelled model `sample-data`, prompt `sample`, so it can't be mistaken for a
live answer.

PA insights shows the results: 14 proposals from 3 notes (7 confirmed, 2 corrected, 1 rejected, 4 waiting), 7 answers
(5 shown, 2 withheld), and 2 handoffs (1 waiting).

## How the PA learns ("training")

The PA does **not** retrain or fine-tune the model, and nothing a person types is sent to a model to learn from. The
model stays the same, private one. What changes is what the PA knows and the rules it follows, and each change is
something you can see and undo:

1. **The record: facts, confirmed by a person.** The PA proposes; a person confirms, corrects or rejects. Only
   confirmed values go into the record, and the next answer is built from the record. Corrections keep the AI's
   value in the history, under the person's. *Sample: Michael's temperature history shows the AI's "hot", then
   Sophie's "warm".*
2. **The playbook: rules with versions, approved by a manager.** The PA cites the rules it used (for example
   `[seller_no_higher_offer v1]`). A rule only takes effect once approved, and a new version supersedes the old one,
   which is kept as history. *Sample: "Probate: value near the grant" is on v2 after Tom went cold; v1 is kept.*
3. **Rules the PA proposes itself.** When people keep correcting the same thing, the PA can propose a rule. It waits
   for a manager like any other. *Sample: "Temperature is the agent's call" was proposed after Sophie corrected
   "hot" twice. It is waiting in PA knowledge.*
4. **Personal rules.** Each agent can teach their own PA things only they need. *Sample: Sophie's "Helen: speak to
   Jo"; Ashley doesn't see it.*
5. **Rejected rules are never used.** *Sample: "Mention other agents' fees" was turned down by Ashley.*
6. **Manager answers return to the deal.** A handoff reply becomes a decision on record and appears in the agent's
   next brief. *Sample: Ashley's reply about Priya.*
7. **Measurement.** PA insights shows how often people accept, correct or reject what the PA proposes, and how many
   answers the checks stopped. Run `scripts/pa_regression.py` before changing the model or the prompts.

What is decided by fixed rules, not the AI: the order of Today (weighted signals; "Why #1?" shows them), what counts as
on record, whether an answer is shown, and who may approve a rule.

## A 10-minute walk-through

1. **PA today**: Sarah is #1. Open "Why #1?" and look at the signals and their points. Helen shows "changes waiting".
2. **Sarah**: Prepare Me, then Coach. The questions to ask, the rules applied, and no offer figure.
3. **PA capture**: open Helen's note. Confirm two rows, correct the temperature, then confirm the rest. Her record and
   next actions update.
4. **Michael**: the timeline, then the temperature history: the AI's value and Sophie's correction.
5. **Manager today** (as Ashley): Dev's handoff, Dev's offer, Gary's gap and the quiet sellers. Reply to Dev.
6. **PA knowledge**: approve or reject "Temperature is the agent's call", and open the probate rule's versions.
7. **PA insights**: the capture accuracy, the answers withheld, and the go-live checklist.

Reset any time to start again.
