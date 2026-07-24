--[[
  Adds admin-configurable "linked HMRC form" metadata to income_types.

  Motivation: /my-income/[type] rendered a HARDCODED "SA100 boxes —
  {year}" header above the profile-builder ContextSections region.
  The label was accurate for dividends (SA100) but wrong for anything
  else — SA110 users saw the SA100 label above SA110 boxes, SA108
  users saw it above SA108 boxes, and every future income type would
  either have to accept the misleading header or force a
  per-type code change to the frontend.

  Solution: three optional metadata columns on income_types that let
  admins name the reference form themselves, describe what the fields
  map to, and link the HMRC PDF as an external reference.

    linked_form_title       varchar(120)  e.g. "SA100" / "SA110" / "SA108"
    linked_form_description text          e.g. "These fields map directly
                                               to the SA100 form."
    linked_form_weblink     text          e.g. https://assets.publishing
                                               .service.gov.uk/.../SA110-2026.pdf

  Rendered by the frontend as: card header showing the title (when
  set), the description below it, and — when weblink is set — an
  "Open reference form ↗" link that opens the PDF in a new tab
  (target="_blank" rel="noopener noreferrer" — the noreferrer half
  strips Referer so HMRC's server doesn't get a trail of who
  opened it from where).

  All three columns nullable — a type without them still renders,
  just without the reference-form card. Empty string treated as
  "not set" on the frontend (matches how income_types.description
  is already handled).

  IF NOT EXISTS on every ADD COLUMN so a re-run on an env where
  the columns already exist is a no-op. Only executed when
  PROJECT_CODE includes 'tax_copilot'.
]]

local db = require("lapis.db")

return {
    -- =========================================================================
    -- 1. Add the three linked-form columns to income_types. All nullable
    --    — a type without them renders unchanged.
    -- =========================================================================
    [1] = function()
        db.query([[
            ALTER TABLE income_types
              ADD COLUMN IF NOT EXISTS linked_form_title       VARCHAR(120),
              ADD COLUMN IF NOT EXISTS linked_form_description TEXT,
              ADD COLUMN IF NOT EXISTS linked_form_weblink     TEXT
        ]])
        print("[income_types] Added linked_form_title / linked_form_description / linked_form_weblink columns")
    end,

    -- =========================================================================
    -- 2. Seed the initial known types with sensible defaults so admins
    --    see the reference-form card without having to fill in every
    --    type by hand. Admin can edit any of these values via
    --    /admin/income-types afterwards. Idempotent — UPDATE with a
    --    WHERE guard so a row where the admin has already customised
    --    the copy isn't clobbered on re-run.
    -- =========================================================================
    [2] = function()
        local seeds = {
            {
                key = "dividends",
                title = "SA100",
                description = "These fields map directly to the SA100 form.",
                weblink = "https://assets.publishing.service.gov.uk/media/6874c86d4c1a4020117e9d68/SA100-2025.pdf",
            },
            {
                key = "salary",
                title = "SA102",
                description = "These fields map directly to the SA102 Employment supplementary form.",
                weblink = "https://assets.publishing.service.gov.uk/media/6874ca9c66bef7d5e5b60fc7/SA102-2025.pdf",
            },
            {
                key = "pension_payments",
                title = "SA100 TR4",
                description = "These fields map to the 'Tax reliefs' section on page TR4 of the SA100 form.",
                weblink = "https://assets.publishing.service.gov.uk/media/6874c86d4c1a4020117e9d68/SA100-2025.pdf",
            },
            {
                key = "sa110",
                title = "SA110",
                description = "These fields map directly to the SA110 Tax calculation summary form.",
                weblink = "https://assets.publishing.service.gov.uk/media/68af7c2fe1055f748d55c184/SA110-2026.pdf",
            },
            {
                key = "sa108",
                title = "SA108",
                description = "These fields map directly to the SA108 Capital Gains Tax summary form.",
                weblink = "https://assets.publishing.service.gov.uk/media/6874ca08d24a86df80b8ceac/SA108-2025.pdf",
            },
            {
                key = "rental",
                title = "SA105",
                description = "These fields map directly to the SA105 UK property supplementary form.",
                weblink = "https://assets.publishing.service.gov.uk/media/6874c94af6a03e18e2ca4a3d/SA105-2025.pdf",
            },
            {
                key = "self_employment",
                title = "SA103",
                description = "These fields map to the SA103 Self-employment supplementary form.",
                weblink = "https://assets.publishing.service.gov.uk/media/6874c8cd63b78ce8bc3c2f5b/SA103F-2025.pdf",
            },
            {
                key = "overseas_property",
                title = "SA106",
                description = "These fields map to the SA106 Foreign income supplementary form.",
                weblink = "https://assets.publishing.service.gov.uk/media/6874c9e963b78ce8bc3c2f78/SA106-2025.pdf",
            },
        }
        for _, s in ipairs(seeds) do
            -- Only fill columns that are still NULL — never overwrite
            -- an admin's manual edit. COALESCE keeps existing values
            -- intact while filling the blanks.
            db.query([[
                UPDATE income_types
                   SET linked_form_title       = COALESCE(linked_form_title, ?),
                       linked_form_description = COALESCE(linked_form_description, ?),
                       linked_form_weblink     = COALESCE(linked_form_weblink, ?),
                       updated_at              = NOW()
                 WHERE income_type_key = ?
            ]], s.title, s.description, s.weblink, s.key)
        end
        print("[income_types] Seeded linked-form defaults for 8 known income types (COALESCE — never overwrites admin edits)")
    end,
}
