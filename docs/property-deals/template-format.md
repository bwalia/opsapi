# Workflow template format (version 1)

A workflow template is one JSON document. Each workspace has its own templates. Every published
version is **immutable**, and a deal stays pinned to the version it started on. Editing a template
always publishes a new version.

API: `GET /workflow-templates/:id/export` returns this JSON. `POST /workflow-templates/import`
with `{ "definition": {...}, "notes": "..." }` creates a template, or publishes a new version when
the `key` already exists. `POST /workflow-templates/:id/versions` publishes a new version of one
template. An invalid definition gets a `422` with one message per problem, for example
`"stages[3].tasks[1].due.from: stage_entry, deal_created, task_done, target_exchange or target_completion"`.

Seeds: `projects/property-deals/property_deals/seed/uk_guaranteed_sale.lua` and
`sell_via_estate_agent.lua`.

> These templates are starting points, not legal advice. See [compliance-disclaimer.md](compliance-disclaimer.md).

## Shape

```jsonc
{
  "format": 1,                         // required, always 1 for now
  "key": "uk_guaranteed_sale",         // required, [a-z][a-z0-9_]*, unique per workspace, never changes
  "name": "UK residential — guaranteed-sale buyer + investor sourcing",
  "description": "…",
  "jurisdiction": "england-and-wales", // which bank-holiday calendar / compliance pack it assumes
  "deal_types": ["buy", "buy_and_assign", "sourcing"],   // deal types that default to this template
  "stages": [ Stage, … ],              // required, in order
  "compliance": [ ComplianceItem, … ]
}
```

### Stage

```jsonc
{
  "key": "exchange",                   // unique within the template
  "name": "Exchange",
  "optional": false,                   // not on the normal path: never chosen by "advance", only moved to on purpose
  "parallel": false,                   // runs alongside the stage before it: its tasks start when that stage is
                                       // entered, the deal's stage doesn't change, and it isn't on the critical path
  "expected_working_days": 10,         // typical duration, for the completion-slip forecast (urgency.md)
  "when": { "tenure": ["leasehold"] }, // only for deals whose property matches (else skipped)
  "entry_gate": {                      // checked before a deal may ENTER this stage
    "tasks_done": ["order_searches", "buyer_aml"],         // task keys (any stage) that must be done
    "compliance_passed": ["aml_cdd_buyer"],                // compliance item keys that must be passed and not expired
    "documents": ["title", "searches"],                    // document categories that must be uploaded
    "fields": ["agreed_price", "target_completion_date"],  // deal fields that must be filled in
    "no_open_blocking_enquiries": true
  },
  "tasks": [ Task, … ]                 // created when the deal enters the stage
}
```

Moving a deal (`POST /deals/:id/stage { "to": "exchange" }`) checks the target stage's gate. If it
isn't met the answer is `409` with `details.missing`, one entry per problem:
`{ "type": "compliance", "key": "aml_cdd_buyer", "message": "AML customer due diligence — buyer is not passed (in progress)" }`.
`GET /deals/:id/gate?to=exchange` previews the same list. Gate items whose task or stage doesn't
apply to the deal (a `when` that fails) are not required. Compliance items count when their latest
check is `passed` and not expired, or `waived`.

### Task

```jsonc
{
  "key": "book_epc",                   // unique across the WHOLE template (gates and dependencies refer to it)
  "title": "Book an EPC assessor",
  "description": "…",
  "owner": "operator",                 // operator | manager | compliance | agent (role the task is routed to)
  "priority": "high",                  // critical | high | medium | low (default medium)
  "sla_minutes": 60,                   // optional; drives the 75/100/125% SLA warnings
  "due": { "from": "stage_entry", "minutes": 60 },
  "blocking": true,                    // on the path to exchange/completion (urgency + deal health)
  "compliance": true,                  // closing it needs evidence and a named person
  "depends_on": ["epc_register_check"],// can't start until these tasks are done
  "approval": "any_operator",          // none | any_operator | manager | two_person — for anything it sends/books/pays
  "agent": { "eligible": true, "agent_key": "booking_agent", "auto": false },
  "skip_if": { "epc_valid": true },    // when this holds the task closes itself, with the facts as evidence
  "when": { "tenure": ["leasehold", "share_of_freehold"] },
  "repeat_every": { "working_days": 1 }// recreated until the stage is left (e.g. daily chase)
}
```

`due` needs exactly one of `minutes`, `hours` or `working_days`. It counts from:

| `from` | Meaning |
|---|---|
| `stage_entry` | when the deal entered the stage |
| `deal_created` | when the deal was created |
| `task_done` | when task `due.task` was finished (`"task": "<key>"` required) |
| `target_exchange` | the deal's target exchange date; negative counts back (`"working_days": -5`) |
| `target_completion` | the deal's target completion date; negative counts back |

Working days skip weekends and the workspace's holidays (`/holidays`, seeded with UK bank holidays).
A task with `depends_on` (or `due.from = task_done`) has no clock until its prerequisites are done;
then `stage_entry`/`task_done` offsets count from that moment. If `sla_minutes` is missing, the SLA
window is from the clock start to the due time.

### Conditions (`when`, `skip_if`)

| Key | Holds when |
|---|---|
| `tenure: ["leasehold", …]` | the deal's property has one of these tenures |
| `deal_type: ["buy", …]` | the deal is one of these types |
| `party_is_company: true/false` | a party on the deal is (or isn't) a company |
| `epc_valid: true/false` | the property has an EPC certificate number and an expiry date that hasn't passed |

Unknown keys never hold. When a task closes with evidence `{ "epc_valid": true,
"certificate_number", "expires_on", "rating" }` (for example the EPC register check), the property
is updated and any `skip_if: { epc_valid: true }` task closes itself.
`repeat_every: { "working_days": n }` creates the next copy each time one is done, while the deal is
still in that stage.

### Compliance item

```jsonc
{
  "key": "aml_cdd_buyer",
  "name": "AML customer due diligence — buyer",
  "description": "…",
  "subject": "deal_party",             // deal_party | deal | property | workspace
  "party_role": "buyer",               // for deal_party: which party
  "expires_after_days": 365,           // passed checks expire (compliance_expiry job re-opens them)
  "when": { "party_is_company": true }
}
```

A compliance item becomes a `compliance-checks` row when the engine needs it. Only a person can
set it to `passed` or `waived`. The API records who did it and when, and refuses the AI service
account.

## Rules the validator enforces

- `format` is 1. `key`, `name` and at least one stage are present.
- Stage keys are unique. Task keys are unique across the whole template. Compliance keys are unique.
- `owner`, `approval`, `priority` and `due.from` are from the lists above.
- `depends_on`, `due.task` and `entry_gate.tasks_done` name tasks that exist. `entry_gate.compliance_passed` names compliance items that exist. A task can't depend on itself.
- Importing a definition whose `key` matches an existing template publishes a new version of it. A template's `key` can't change.
