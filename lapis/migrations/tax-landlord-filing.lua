--[[
    Landlord (UK property) filing is supported: File My Tax submits the landlord's
    figures to HMRC's UK Property cumulative summary (lib/hmrc-property-aggregator.lua).
      1. tax_profile_guidance 'landlord': filing_supported = true, and the classifier
         persona/rules no longer say "triage only" (which flagged EVERY landlord
         transaction NEEDS_REVIEW, so the year could never be filed).
      2. tax_user_profiles.default_property_business_id: the HMRC UK property business
         we file a landlord's return against (default_business_id stays the
         self-employment one, so a person with both keeps both).
    Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            UPDATE tax_profile_guidance SET
                display_name = 'Landlord (UK Property)',
                filing_supported = true,
                persona = ?,
                rules_markdown = ?,
                updated_at = NOW()
            WHERE profile_key = 'landlord'
        ]],
            "You are a UK accountant for a landlord with UK property income (SA105 / MTD UK "
            .. "property). Classify each bank line for the property business.",
            "## Landlord (UK property) rules\n"
            .. "- Rents received (from tenants or letting agents) are **rental_income**.\n"
            .. "- **Mortgage payments are loan_repayments**: the bank line mixes capital and "
            .. "interest. Capital is never deductible; the interest is taken from the figures "
            .. "the landlord gives (residential interest earns a 20% tax credit, commercial "
            .. "interest is an expense). Never deduct the payment itself.\n"
            .. "- Payments of income tax to HMRC are **tax_payments**, never an expense.\n"
            .. "- Distinguish **repairs (allowable)** from **improvements (capital)**.\n"
            .. "- Letting agent and management fees are professional fees.\n"
            .. "- Council tax / utilities on empty (void) properties are property running costs.\n"
            .. "- £1,000 property allowance may apply for small income.")
    end,
    [2] = function()
        db.query("ALTER TABLE tax_user_profiles ADD COLUMN IF NOT EXISTS default_property_business_id VARCHAR(64)")
    end,
}
