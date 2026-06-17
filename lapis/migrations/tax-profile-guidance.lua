--[[
    Tax Profile Guidance migration  (Phase 0 of the accountant-grade classifier)

    Creates `tax_profile_guidance` — an opsApi-OWNED reference table that maps each
    business profile to its HMRC filing context: the SA form, an accountant persona,
    the categories it prefers/excludes, and free-text `rules_markdown` guidance that
    the classifier prompt (Phase 2) will inline.

    Why a new table instead of reusing `classification_profiles`?
      The diy-tax-return-uk app (a release-branch consumer of opsApi) seeds
      `classification_profiles` itself via add-if-missing on the same profile_key
      values. Seeding it here would collide. This table is opsApi-only, so our
      migration can never conflict with diy's seeders. It does NOT touch
      tax_hmrc_categories or classification_profiles.

    Landlord (SA105) filing is DEFERRED: the row exists for classification/triage
    but is flagged filing_supported = false, and we add NO SA105 categories to the
    shared tax_hmrc_categories catalogue.

    Idempotent: CREATE TABLE IF NOT EXISTS + add-if-missing seed by profile_key.
]]

local db = require("lapis.db")
local cjson = require("cjson")

-- Profile seed data. `affinity`/`excluded` are category KEYS (tax_categories.key);
-- stored as JSON text and decoded by the classifier in Phase 2.
local PROFILES = {
    {
        profile_key = "sole_trader",
        display_name = "Sole Trader",
        sa_form = "SA103F",
        mtd_section = "self-employment",
        filing_supported = true,
        persona = "You are a UK chartered accountant preparing a sole trader's Self "
            .. "Assessment (SA103). Apply the wholly-and-exclusively test, separate "
            .. "capital purchases from revenue expenses, and disallow private-use "
            .. "proportions.",
        affinity = { "sales_income", "consulting_income", "office_supplies",
            "software_subscriptions", "accountancy_fees", "bank_charges",
            "travel_transport", "marketing_advertising" },
        excluded = { "rental_income", "repairs_property" },
        rules_markdown = "## Sole trader (SA103) rules\n"
            .. "- Allow only expenses incurred **wholly and exclusively** for the trade.\n"
            .. "- **Capital items** (equipment, computers, vehicles) are NOT P&L expenses — "
            .. "flag for capital allowances / Annual Investment Allowance, not box deduction.\n"
            .. "- **Client entertaining is disallowable.** Fines/penalties are disallowable.\n"
            .. "- Mixed personal/business spend: deduct only the business proportion.\n"
            .. "- £1,000 trading allowance may apply for very small turnover.",
    },
    {
        profile_key = "it_contractor",
        display_name = "IT Contractor",
        sa_form = "SA103F",
        mtd_section = "self-employment",
        filing_supported = true,
        persona = "You are a UK accountant for an IT contractor (sole trader basis). "
            .. "Most spend is software, equipment, home office and professional development.",
        affinity = { "consulting_income", "software_subscriptions", "equipment_purchase",
            "home_office", "training_courses", "professional_memberships",
            "accountancy_fees", "travel_transport" },
        excluded = { "inventory_stock", "subcontractors", "rental_income" },
        rules_markdown = "## IT contractor rules\n"
            .. "- Hardware/laptops are **capital** (capital allowances/AIA), not revenue.\n"
            .. "- SaaS/cloud subscriptions are allowable admin costs.\n"
            .. "- Home-office: use HMRC simplified flat rate OR a fair business proportion.\n"
            .. "- Training to maintain existing skills is allowable; wholly new trades are not.",
    },
    {
        profile_key = "freelance_developer",
        display_name = "Freelance Developer",
        sa_form = "SA103F",
        mtd_section = "self-employment",
        filing_supported = true,
        persona = "You are a UK accountant for a freelance software developer (sole "
            .. "trader). Spend skews to software, equipment, internet and home office.",
        affinity = { "consulting_income", "software_subscriptions", "equipment_purchase",
            "home_office", "internet", "training_courses", "travel_transport",
            "accountancy_fees" },
        excluded = { "inventory_stock", "subcontractors", "rental_income" },
        rules_markdown = "## Freelance developer rules\n"
            .. "- Treat computers/peripherals as **capital** (AIA), not revenue expense.\n"
            .. "- Apportion home internet/phone between business and private use.\n"
            .. "- Domain/hosting/SaaS are allowable admin costs.",
    },
    {
        profile_key = "amazon_seller",
        display_name = "Amazon Seller",
        sa_form = "SA103F",
        mtd_section = "self-employment",
        filing_supported = true,
        persona = "You are a UK accountant for an e-commerce/Amazon seller (sole "
            .. "trader). Watch stock/COGS, FBA and selling fees, shipping and advertising.",
        affinity = { "inventory_stock", "shipping_and_delivery", "cost_of_sales",
            "sales_income", "marketing_advertising", "software_subscriptions",
            "bank_charges", "accountancy_fees" },
        excluded = { "rental_income", "repairs_property" },
        rules_markdown = "## Amazon seller rules\n"
            .. "- **Stock/inventory** purchased for resale is cost of goods sold (COGS), "
            .. "matched to the period it is sold.\n"
            .. "- Amazon FBA/referral/selling fees are allowable cost of sales.\n"
            .. "- Postage and packaging are allowable.\n"
            .. "- Advertising/PPC is an allowable advertising cost.",
    },
    {
        profile_key = "construction",
        display_name = "Construction / Trades",
        sa_form = "SA103F",
        mtd_section = "self-employment",
        filing_supported = true,
        persona = "You are a UK accountant for a construction trade (sole trader, "
            .. "possibly within CIS). Watch materials, subcontractors, plant and vehicles.",
        affinity = { "materials_supplies", "subcontractors", "equipment_purchase",
            "vehicle_fuel", "vehicle_maintenance", "salaries_wages",
            "business_insurance", "rent_business" },
        excluded = { "rental_income", "inventory_stock" },
        rules_markdown = "## Construction / trades rules\n"
            .. "- Materials and consumables are allowable cost of sales.\n"
            .. "- **Subcontractor payments** may fall under CIS — record gross; CIS "
            .. "deductions are handled separately, not as a normal expense.\n"
            .. "- Tools/plant: small tools are revenue; substantial plant is **capital** (AIA).\n"
            .. "- Vehicle costs: actual-cost-with-private-apportionment OR mileage rate.",
    },
    {
        profile_key = "landlord",
        display_name = "Landlord (UK Property) — filing deferred",
        sa_form = "SA105",
        mtd_section = "uk-property",
        filing_supported = false,  -- SA105 box mapping not yet built; classify/triage only
        persona = "You are a UK accountant for a residential landlord (SA105 UK "
            .. "property). NOTE: property filing is not yet supported — classify for "
            .. "triage only; do not assert SA105 box numbers.",
        affinity = { "rental_income", "repairs_property", "premises_insurance",
            "rent_business", "utilities", "accountancy_fees", "legal_fees",
            "business_rates" },
        excluded = { "inventory_stock", "cost_of_sales", "subcontractors" },
        rules_markdown = "## Landlord (SA105) rules — FILING DEFERRED\n"
            .. "- **Mortgage/loan interest is NOT a deductible expense** for residential "
            .. "lets — it is a 20% tax reducer (finance-cost restriction). Flag, never deduct.\n"
            .. "- Distinguish **repairs (allowable)** from **improvements (capital)**.\n"
            .. "- £1,000 property allowance may apply for small income.\n"
            .. "- This profile is classify-only until SA105 box support ships.",
    },
}

return {
    [1] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        -- 1. Create the opsApi-owned guidance table (idempotent).
        db.query([[
            CREATE TABLE IF NOT EXISTS tax_profile_guidance (
                id                 SERIAL PRIMARY KEY,
                uuid               VARCHAR(255) UNIQUE,
                profile_key        VARCHAR(100) UNIQUE NOT NULL,
                display_name       VARCHAR(255),
                sa_form            VARCHAR(20),
                mtd_section        VARCHAR(50),
                filing_supported   BOOLEAN DEFAULT TRUE,
                persona            TEXT,
                category_affinity  TEXT DEFAULT '[]',   -- JSON array of category keys
                excluded_categories TEXT DEFAULT '[]',  -- JSON array of category keys
                rules_markdown     TEXT,
                is_active          BOOLEAN DEFAULT TRUE,
                created_at         TIMESTAMP DEFAULT NOW(),
                updated_at         TIMESTAMP DEFAULT NOW()
            )
        ]])
        pcall(function()
            db.query("CREATE INDEX IF NOT EXISTS tax_profile_guidance_profile_key_idx "
                .. "ON tax_profile_guidance (profile_key)")
        end)

        -- 2. Seed the six profiles, add-if-missing by profile_key.
        for _, p in ipairs(PROFILES) do
            if #db.select("id FROM tax_profile_guidance WHERE profile_key = ?", p.profile_key) == 0 then
                db.insert("tax_profile_guidance", {
                    uuid = MigrationUtils.generateUUID(),
                    profile_key = p.profile_key,
                    display_name = p.display_name,
                    sa_form = p.sa_form,
                    mtd_section = p.mtd_section,
                    filing_supported = p.filing_supported,
                    persona = p.persona,
                    category_affinity = cjson.encode(p.affinity),
                    excluded_categories = cjson.encode(p.excluded),
                    rules_markdown = p.rules_markdown,
                    is_active = true,
                    created_at = timestamp,
                    updated_at = timestamp,
                })
            end
        end

        print("[Tax Copilot] tax_profile_guidance ready (" .. #PROFILES .. " profiles seeded)")
    end,
}
