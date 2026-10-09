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
  "optional": false,                   // optional stages can be skipped by a manager
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

If the gate isn't met, the stage move is refused with a list of exactly what is missing (Phase 3).

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
  "skip_if": { "epc_valid": true },    // engine condition (Phase 3): close itself with evidence
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
