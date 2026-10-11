# Property PA — Week 2 "Capture": what was built

Scope (SUPPLIER-RESPONSE.md): voice and text capture, extraction, confirm and correct, next actions.
Tests: **P03** (the voice note gives exactly the expected fields), **P04** (next action "call Sarah tomorrow 11:00",
owner Sophie, with the reason), **P09** (£225k stored as inferred and labelled unconfirmed), **P11** (a correction
replaces the value and keeps the history).

## Flow

1. **Say or type it.** On the dashboard (PA capture), Sophie picks Sarah or leaves it to the PA, then records a voice
   note or types one.
   - Voice is transcribed on our own speech server (`/api/v2/voice/transcribe` → `PA_STT_URL`). No cloud speech
     service is used.
2. **`POST /captures/start`** logs the note as an interaction. The text is stored as data and never acted on. It then
   starts the Seller PA in JobShout in `capture` mode with `inputs.interaction_uuid`.
   - If the PA isn't connected, the note is still saved, and the reply says why the PA wasn't asked.
3. **The PA proposes.** It reads `/context`, then posts `/captures` with `interaction_uuid` and one proposal per change:
   - every proposal not marked `is_inferred` must quote the note exactly, with its figures inside the quote;
   - the next action has a title, a UK-local due time and a reason, with Sophie (the opportunity's owner) as owner.
   - Each proposal is tied to the PA run. When the run finishes, its real model and prompt version are written onto
     the proposals and facts (P10).
4. **The confirm sheet.** `GET /interactions/:id/capture` returns the sheet. It polls JobShout while the PA works. Each
   row is typed **Stated**, **SOPHIE'S JUDGEMENT, UNCONFIRMED** (P09) or **Proposed**, shows old → new and the quoted
   words, and material rows are flagged.
5. **[Change something] → [Confirm].** `POST /interactions/:id/decide` with the corrections and rejections, plus
   `confirm_rest`.
   - Each row is applied in its own transaction.
   - A correction keeps the PA's value in the history (P11).
   - The next action becomes a task with its reason and the note it came from (P04).
   - Only a person can do this: the agent's `pd_agent` role is refused.

## Screens (`opsapi-dashboard`)

| Page | What |
|---|---|
| `/dashboard/property-pa/capture` | Pick who it's about (people search by name, phone or address), record or type, send. A "your PA is reading it" state while the PA works (minutes on the private model). Then the confirm sheet. `?opportunity=` preselects; `?interaction=` reopens a sheet. |
| `/dashboard/property-pa/opportunities` | My open opportunities with temperature, minimum and next action due. |
| `/dashboard/property-pa/opportunities/:id` | What we know, each field badged (entered by a person / from a note, confirmed / judgement, unconfirmed). Per-field **History** (P10/P11: source, model, prompt version, confirmed or not, replaced or current). "N changes waiting → Review". Next actions with their reasons, offers, and the timeline. |

Menu: **PA capture** and **My opportunities** (module `property_pa_records`).

## Model regression (P03 / P04 / P09)

- `projects/property-pa/spec/regression/scenes.py` holds the scene 3 note and the checker.
  - The checker requires exactly these rows: event, seller's minimum, decision makers, inferred position, next action.
    A few optional ones are allowed.
  - It checks the values: £240k valuation, £235k stated minimum (material), Sarah + Tom, £225k inferred and labelled,
    next action tomorrow 11:00 UK with an owner and a reason.
- `projects/property-pa/scripts/pa_regression.py` runs the scene against a live OpsAPI + JobShout + model, prints the
  sheet and PASS/FAIL, then rejects the rows so the record is unchanged (`--keep` to leave them; `--reset` re-seeds
  the fixtures). **Run it before any model, provider or prompt change.**
- The sandbox suite `pa_week2_test.py` proves the checker both ways: the expected proposals pass, and broken ones fail
  on each rule. The full Property Deals + PA regression passes: 13 suites, 1,200 checks.

## JobShout

`feat/property-pa-agents`:
- the capture skill sends `interaction_uuid` when the note was already logged in OpsAPI;
- due times are UK local with an offset;
- prompts and skills are at **1.2.0**.

## Not done / next

- **The real model hasn't been run against scene 3 yet.** `pa_regression.py` is ready for it, once both PRs are merged
  and deployed on int with the JobShout link configured.
- **The screens weren't clicked through in a browser.** The local API port (4020) refuses host connections and needs a
  colima restart. Type-check and lint are clean, and the API behind them is covered by the sandbox suite.
- **Audio isn't kept.** Only the transcript is stored (`audio_document_uuid` is there for when we store it in MinIO).
- **Week 3:** Today ranking with "why #1" (P01/P07), Prepare Me (P02), coach (P06), Teach PA.
