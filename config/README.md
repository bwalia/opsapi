# opsapi/config/ — Config as Code (CMI)

Git-tracked source of truth for admin catalogues that must stay in sync
across `int`, `acc`, and `prod`. Replaces the "make the change on each
env's admin dashboard by hand" flow. Modelled after Drupal's CMI.

## Layout

```
config/
  _global/                     # tables with no namespace concept
    tax_hmrc_categories.json   #   SA103 HMRC boxes
    menu_items.json            #   global sidebar template
  tax-copilot/                 # per-namespace admin catalogues
    income_types.json          #   sync target for the DIY-tax product
    tax_categories.json
    profile_categories.json
    profile_questions.json
    profile_question_options.json
    profile_question_rules.json
    profile_tag_rules.json
    profile_tags.json
    profile_touchpoints.json
    profile_question_touchpoints.json
    profile_lookup_tables.json
    profile_lookup_values.json
    pension_payment_categories.json
    property_line_categories.json
    business_line_categories.json
    tax_form_sections.json
```

Everything under `_global/` is single-copy per env. Everything under a
namespace subfolder (only `tax-copilot/` in v1) is scoped to that
namespace on both export and import — cross-tenant leakage is
impossible by construction because every SELECT and every UPDATE carries
the namespace filter.

## Commands

Run inside the opsapi container (or a dev shell with `lapis` on PATH):

```sh
# Export the tax-copilot namespace + globals from THIS env's DB
lapis exec "require('scripts.config-cli').export('/app/config', 'tax-copilot')"

# Preview an import (no writes)
lapis exec "require('scripts.config-cli').import_dry('/app/config', 'tax-copilot')"

# Apply an import (upsert + mark-inactive-not-delete)
lapis exec "require('scripts.config-cli').import_apply('/app/config', 'tax-copilot')"

# Structural drift check — exits non-zero on any add/remove
lapis exec "require('scripts.config-cli').status('/app/config', 'tax-copilot')"
```

The namespace slug is **required** on every command. Passing `nil` errors
out — that would silently span all tenants. Unknown slugs error out too.

## The workflow

1. **Author on int.** Admin uses the dashboard to add/edit an income type,
   tax category, form section, etc. — same as today.
2. **Nightly (or on-demand) CI job on int** runs `export` against the int
   DB and opens a PR against opsapi with the JSON diff.
3. **PR review** happens on git — see the added/removed/changed rows
   before they touch acc or prod.
4. **On merge to main**, CI runs `import_apply` on acc and (after a
   promotion gate) prod.
5. **Rollback** is `git revert` + re-run `import_apply`.

## First-time baseline

The current baseline was exported from a **local dev DB**. Before
enabling CI-driven `import_apply` on any real env:

1. On **int**, run `export` and PR the result.
2. Verify the JSON matches what int should look like everywhere.
3. Merge that PR — now the baseline is authoritative.
4. Only then wire up CI's `import_apply` against acc/prod.

## Safety guards baked in

- **Namespace preflight.** CMI refuses to run if any tenant-scoped table
  holds `namespace_id IS NULL` or `namespace_id = 0` rows. The
  `994_cmi_ns_cleanup_to_tax_copilot` migration cleans those up first;
  once it's applied, the guard is silent.
- **Never DELETE.** Rows that disappear from a file get `is_active = false`
  instead — historical user rows that reference retired config keep
  referential integrity.
- **Slug-in / id-out.** Every FK in the JSON is a stable business key,
  not an integer id. IDs resolve locally at import time — an env's
  namespace id can differ from int's and everything still lines up.

## Adding a new config table

1. Confirm the table has (or gets) a stable business key column (single
   or composite) with a UNIQUE index. If the key is composite and there's
   no unique index yet, add one via a small migration modelled on
   `config-cmi-unique-keys`.
2. Add an entry to `lapis/config/registry.lua` — pick the right
   `namespace_scope` and (if `inherited`) `inherit_ns_via`.
3. Add its name to `export_order` in dependency order (parents first).
4. Run `lapis exec "require('scripts.config-cli').export(...)"` to
   generate the file.
5. Commit the registry change + the new JSON file together.
