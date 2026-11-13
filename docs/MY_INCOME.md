# My Income — definition-driven income types

Customers tell us about every kind of income they had in a tax year (jobs, self-employment,
UK and overseas property, pensions, savings, dividends, capital gains, other) under
**Tax → My Income**. Accountants and workspace administrators maintain those income types
under **Tax → Income types** without code changes. The figures feed the tax estimate on
Reports, File My Tax and the AI assistant.

## Data model

Built on the `income_types` catalogue that diy-tax-return-uk already uses — extended, not
duplicated. The diy routes (`/api/v2/tax/my-incomes*`, `/api/v2/tax/admin/income-types*`)
are unchanged, and their reads are now limited to system rows, so a workspace's own types
never show up in diy's shared dropdown.

| Table | What it holds |
|---|---|
| `income_types` (+ columns) | `icon`, `help_text`, `entity_type`, `entity_label`, `estimate_note`, `field_schema` (JSONB), `estimator_mapping` (JSONB). System rows have `namespace_id` NULL; a workspace's own types have `namespace_id` set and key `ns<id>_<slug>` (the key stays globally unique, which other migrations' `ON CONFLICT (income_type_key)` relies on). |
| `income_type_namespace_overrides` | One row per (namespace, system type): the workspace's name, help, icon, order, shown/hidden, form or mapping. A NULL column inherits the default. |
| `user_profile_entities` (existing) | The customer's properties, jobs and businesses. Shared with the diy hubs (`entity_type` `property`, `employment`, `business`, `overseas_property`). |
| `tax_income_records` | The figures: one row per (namespace, user, tax year, income type, entity?), `figures` JSONB, `value_sources` (`statements` or `manual` per field), `status` (`in_progress`, `done`, `not_applicable`). Unique on `(namespace_id, user_id, tax_year, income_type_key, COALESCE(entity_uuid,''))`. |

**Field schema:** `{ sections: [ { key, title, help?, fields: [ { key, label, type, required?, help?, placeholder?, min?, max?, default?, role?, hmrc_box?, options?, show_if?, prefill? } ] } ] }`.
The types are currency, number, percentage, boolean, text, date and select. The role is income,
expense, tax_paid, relief or info, and drives the totals on the cards. `prefill` takes
`{ categories, direction }` and sums the customer's classified bank transactions in those
categories for the year as a suggestion. The figure is used only when the customer clicks
"Use this figure", and is then marked "From your statements".

**Estimator mapping:** `[ { field, input, scale_by?, sign? } ]`, where `input` is one of
the `lib/tax-calc` `compute_full` inputs (listed in `lib/income-types.lua`
`ESTIMATOR_INPUTS`). `scale_by` names a percentage field, such as the ownership share of a
jointly owned property. `sign = -1` subtracts the figure, for example costs set against
other income. The tax rules stay in `tax-calc`. The mapping only labels the figures.

Validation is server-side in `lib/income-types.lua`:

- `validate_schema`, `validate_mapping` and `validate_definition` check the admin's edits.
- `validate_values` checks the customer's figures. Required fields are enforced only on "mark as done".

## Seeded types → where they go

| Key | Per item | Feeds (compute_full input) | Form |
|---|---|---|---|
| salary | employment | employment_income (pay, tips, P11D benefits), employment_expenses, paye_deducted | SA102 boxes 1–3, 9–20 |
| self_employment | business | se_turnover, se_expenses, se_capital_allowances | SA103S/F |
| dividends | — | dividends | SA100 TR3 box 4 |
| foreign_dividends | — | dividends (foreign tax recorded only) | SA100 TR3 box 5 / SA106 |
| other_dividends | — | dividends | SA100 TR3 box 4 |
| rental | property | property_rents, property_expenses, property_finance_costs (all × ownership share) | SA105 boxes 20, 24–29, 44 |
| overseas_property | overseas_property | property_rents, property_expenses, property_finance_costs (× share) | SA106 boxes 14, 24, 24A |
| interest | — | savings_interest | SA100 TR3 box 2 |
| foreign_interest | — | savings_interest | SA100 TR3 box 3 / SA106 |
| pension | — | pension_income (State + private), tax_deducted_at_source | SA100 TR3 boxes 8, 11, 12 |
| pension_payments | — | pension_ras (relief, extends the basic-rate band) | SA100 TR4 box 1 |
| capital_gains | — | — (Capital Gains Tax isn't in the estimate; shown with a note) | SA108 |
| other | — | other_income (amount − costs), tax_deducted_at_source | SA100 TR3 boxes 17–19 |

`compute_full` gained `pension_income`, `other_income` (non-savings, no NIC) and
`tax_deducted_at_source` (credited like PAYE).

## How it feeds the estimate

`TaxTools.compute_year` loads My Income through `TaxIncomeQueries.estimator_inputs`.
`TaxTools.estimate` then overlays it one schedule at a time:

- **Income types.** If the customer never told the assistant their income types, the types come from My Income. Otherwise the two lists are merged.
- **Property.** My Income's rents and expenses split the bank-statement totals, using the same rule as figures given in the chat, and then replace them.
- **Self-employment.** My Income's figures replace the bank-statement totals. A note in the estimate says so.
- **Everything else.** My Income's figure for employment, pensions, savings, dividends and the rest overrides the chat profile's figure.

Hidden types still count, because hiding a type stops new entries and keeps the figures.
Without a namespace (the legacy routes), the records of the customer's most recently edited
namespace are used. Records are never summed across namespaces.

**AI assistant.** `set_tax_profile` validates against the workspace's catalogue, and the
original keys (`employment`, `uk_property`, `savings_interest`) still work. A new read-only
tool, `get_my_income`, returns the customer's types, progress and totals.

## Access

| Endpoint | Who can call it |
|---|---|
| Customer endpoints (`/api/v2/tax/my-income*`) | `requireAuth` + `requireNamespace`. Rows are always scoped by `namespace_id` and `user_id`. |
| Admin endpoints (`/api/v2/tax/income-types*`) | RBAC module `tax_income_types`: read to view; create and update to maintain. The migration propagates it to namespace owner and admin roles. Grant it to an accountant role to let them maintain the types. |
| `scope=global` | Edits the platform default. Needs a platform administrator. |

The menu adds **My Income** (`tax_my_income`, module `tax_statements`, like File My Tax) and
**Income types** (`tax_income_types`).

## Deferred, not built in v1

- Uploading documents per income type, such as a P60 or a lender's statement, and reading them with OCR or AI.
- Two-way sync with diy's itemised panels: profile-builder answers, `property_line_items`, `business_line_values`. The two products share entities, but each keeps its own figures.
- Foreign Tax Credit Relief, the Capital Gains Tax calculation, and losses carried across property businesses.
- The rule that you can't claim the property or trading allowance and finance-cost relief together. The estimate picks the lower profit automatically.
- Student loan and High Income Child Benefit Charge.
- Per-field audit history, and accountant review or sign-off for each income type.
- Drag-and-drop reordering. v1 uses accessible up and down buttons.
