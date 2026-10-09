-- Seed workflow template: UK residential — guaranteed-sale buyer + investor
-- sourcing (England & Wales). SPEC §3.2 and §3.4.
--
-- A starting point, not legal advice: each workspace's own solicitor or
-- compliance lead must review and edit it (docs/property-deals/compliance-disclaimer.md).
-- Format: docs/property-deals/template-format.md

local function task(t)
    t.owner = t.owner or "operator"
    t.approval = t.approval or "none"
    return t
end

return {
    format = 1,
    key = "uk_guaranteed_sale",
    name = "UK residential — guaranteed-sale buyer + investor sourcing",
    description = "Buy from motivated sellers (England & Wales), optionally assign to an investor buyer.",
    jurisdiction = "england-and-wales",
    deal_types = { "buy", "buy_and_assign", "sourcing" },
    stages = {
        {
            key = "new_lead", name = "New seller lead",
            tasks = {
                task { key = "call_back", title = "Call the seller back", sla_minutes = 60,
                       due = { from = "stage_entry", minutes = 60 }, blocking = true, priority = "high" },
                task { key = "log_situation", title = "Log situation, deadline and vulnerability check",
                       sla_minutes = 240, due = { from = "stage_entry", hours = 4 }, depends_on = { "call_back" },
                       compliance = true,
                       description = "Record why they are selling, any deadline, and whether the seller may be vulnerable." },
            },
        },
        {
            key = "qualified", name = "Qualified",
            tasks = {
                task { key = "pull_title", title = "Pull title register and plan", due = { from = "stage_entry", hours = 24 },
                       agent = { eligible = true, agent_key = "property_enrichment" } },
                task { key = "epc_lookup", title = "EPC register lookup", due = { from = "stage_entry", hours = 24 },
                       agent = { eligible = true, agent_key = "property_enrichment" } },
                task { key = "sold_comps", title = "Sold comparables", due = { from = "stage_entry", hours = 24 },
                       agent = { eligible = true, agent_key = "property_enrichment" } },
                task { key = "flood_mining", title = "Flood and mining risk check", due = { from = "stage_entry", hours = 24 },
                       agent = { eligible = true, agent_key = "property_enrichment" } },
                task { key = "lease_check", title = "Lease check (if leasehold)", due = { from = "stage_entry", hours = 24 },
                       when = { tenure = { "leasehold", "share_of_freehold" } } },
                task { key = "draft_offer", title = "Draft written offer with reasoning", sla_minutes = 1440,
                       due = { from = "stage_entry", hours = 24 }, owner = "manager", blocking = true,
                       depends_on = { "sold_comps" },
                       agent = { eligible = true, agent_key = "offer_reasoning" }, approval = "manager" },
            },
        },
        {
            key = "offer_sent", name = "Offer sent",
            tasks = {
                task { key = "send_offer", title = "Send written offer with reasoning", blocking = true,
                       due = { from = "deal_created", hours = 48 }, approval = "manager", compliance = true,
                       description = "Written offer and the reasons for the price are kept on file (consumer protection)." },
            },
        },
        {
            key = "accepted", name = "Accepted",
            tasks = {
                task { key = "memo_of_sale", title = "Issue memorandum of sale", blocking = true,
                       due = { from = "stage_entry", hours = 8 } },
                task { key = "instruct_solicitors", title = "Instruct both solicitors", blocking = true,
                       due = { from = "stage_entry", hours = 8 } },
                task { key = "request_seller_id", title = "Request seller ID and property forms", blocking = true,
                       due = { from = "stage_entry", hours = 8 }, compliance = true },
            },
        },
        {
            key = "seller_papers", name = "Seller papers",
            tasks = {
                task { key = "chase_seller_forms", title = "Chase seller forms (TA6, TA10, TA7 if leasehold)",
                       due = { from = "stage_entry", working_days = 2 }, blocking = true,
                       agent = { eligible = true, agent_key = "legal_chaser" }, approval = "any_operator" },
            },
        },
        {
            key = "searches", name = "Searches",
            tasks = {
                task { key = "order_searches", title = "Order searches", due = { from = "stage_entry", working_days = 1 },
                       blocking = true,
                       description = "Record the council and its expected turnaround." },
            },
        },
        {
            key = "epc", name = "EPC",
            tasks = {
                task { key = "epc_register_check", title = "Check the public register for a valid EPC",
                       sla_minutes = 30, due = { from = "stage_entry", minutes = 30 }, blocking = true,
                       agent = { eligible = true, agent_key = "property_enrichment", auto = true },
                       description = "If a valid certificate is found, the booking task closes itself with it as evidence." },
                task { key = "book_epc", title = "Book an EPC assessor", sla_minutes = 60,
                       due = { from = "stage_entry", minutes = 60 }, blocking = true,
                       skip_if = { epc_valid = true },
                       agent = { eligible = true, agent_key = "booking_agent" }, approval = "any_operator" },
            },
        },
        {
            key = "survey", name = "Survey / valuation",
            tasks = {
                task { key = "book_survey", title = "Book survey or lender valuation", sla_minutes = 60,
                       due = { from = "stage_entry", minutes = 60 }, blocking = true,
                       agent = { eligible = true, agent_key = "booking_agent" }, approval = "any_operator" },
            },
        },
        {
            key = "lease_pack", name = "Lease pack",
            when = { tenure = { "leasehold", "share_of_freehold" } },
            tasks = {
                task { key = "request_lease_pack", title = "Request management pack from managing agent / freeholder",
                       due = { from = "stage_entry", working_days = 1 }, blocking = true },
            },
        },
        {
            key = "enquiries", name = "Enquiries",
            tasks = {
                task { key = "chase_enquiries", title = "Chase each open enquiry", repeat_every = { working_days = 1 },
                       due = { from = "stage_entry", working_days = 1 }, blocking = true,
                       agent = { eligible = true, agent_key = "legal_chaser", auto = true }, approval = "any_operator",
                       description = "Daily chase; phone after 24 hours with no reply." },
            },
        },
        {
            key = "funds_buyer", name = "Funds & buyer",
            tasks = {
                task { key = "buyer_funds", title = "Buyer proof of funds / mortgage or bridging offer",
                       due = { from = "target_exchange", working_days = -5 }, blocking = true, compliance = true },
                task { key = "buyer_aml", title = "AML checks on the buyer", due = { from = "target_exchange", working_days = -5 },
                       blocking = true, compliance = true, owner = "compliance",
                       agent = { eligible = true, agent_key = "compliance_assistant" } },
            },
        },
        {
            key = "exchange", name = "Exchange",
            entry_gate = {
                tasks_done = { "order_searches", "buyer_funds", "buyer_aml" },
                compliance_passed = { "aml_cdd_seller", "aml_cdd_buyer", "aml_source_of_funds_buyer",
                                      "sanctions_pep_seller", "sanctions_pep_buyer" },
                documents = { "title", "searches" },
                no_open_blocking_enquiries = true,
                fields = { "agreed_price", "target_completion_date" },
            },
            tasks = {
                task { key = "exchange_contracts", title = "Exchange contracts", owner = "manager", blocking = true,
                       due = { from = "target_exchange", working_days = 0 }, approval = "manager" },
            },
        },
        {
            key = "completion", name = "Completion",
            entry_gate = {
                tasks_done = { "exchange_contracts" },
                compliance_passed = { "completion_statement_agreed" },
            },
            tasks = {
                task { key = "move_funds", title = "Funds moved", blocking = true,
                       due = { from = "target_completion", working_days = 0 }, approval = "two_person", owner = "manager" },
                task { key = "keys", title = "Keys released", due = { from = "target_completion", working_days = 0 } },
                task { key = "final_statement", title = "Final completion statement filed",
                       due = { from = "target_completion", working_days = 2 } },
            },
        },
        {
            key = "after_completion", name = "After completion",
            optional = true,
            tasks = {
                task { key = "refurb_plan", title = "Refurb plan", due = { from = "stage_entry", working_days = 5 } },
                task { key = "letting", title = "Letting (optional compliance pack: lettings)",
                       due = { from = "stage_entry", working_days = 10 } },
                task { key = "refinance", title = "Refinance", due = { from = "stage_entry", working_days = 30 } },
            },
        },
    },

    -- Compliance items (SPEC §3.4). `subject` says who the check is about;
    -- `party_role` picks the deal party. expires_after_days drives re-checks.
    compliance = {
        { key = "aml_cdd_seller", name = "AML customer due diligence — seller", subject = "deal_party",
          party_role = "seller", expires_after_days = 365,
          description = "ID and address verification (Money Laundering Regulations 2017)." },
        { key = "aml_cdd_buyer", name = "AML customer due diligence — buyer", subject = "deal_party",
          party_role = "buyer", expires_after_days = 365 },
        { key = "aml_beneficial_owners", name = "Beneficial owners (company buyers/sellers)", subject = "deal_party",
          party_role = "buyer", when = { party_is_company = true },
          description = "Companies House lookup; record every owner over 25%." },
        { key = "aml_source_of_funds_buyer", name = "Source of funds / source of wealth — buyer", subject = "deal_party",
          party_role = "buyer", expires_after_days = 90 },
        { key = "sanctions_pep_seller", name = "Sanctions and PEP screening — seller", subject = "deal_party",
          party_role = "seller", expires_after_days = 90 },
        { key = "sanctions_pep_buyer", name = "Sanctions and PEP screening — buyer", subject = "deal_party",
          party_role = "buyer", expires_after_days = 90 },
        { key = "aml_risk_rating", name = "AML risk rating (enhanced checks if high)", subject = "deal" },
        { key = "vulnerability_review", name = "Vulnerability flag reviewed and handling noted", subject = "deal" },
        { key = "written_offer_on_file", name = "Written offer with reasoning kept on file", subject = "deal" },
        { key = "gdpr_lawful_basis", name = "Lawful basis / consent recorded and privacy notice sent", subject = "deal_party",
          party_role = "seller" },
        { key = "completion_statement_agreed", name = "Completion statement agreed", subject = "deal" },
        { key = "redress_scheme", name = "Redress scheme membership recorded", subject = "workspace",
          expires_after_days = 365 },
    },
}
