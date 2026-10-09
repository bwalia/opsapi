-- Seed workflow template: sell a home through an estate agent (England & Wales).
-- Smaller than the guaranteed-sale template; it proves the engine is generic.
-- Not legal advice — review and edit before use.
return {
    format = 1,
    key = "sell_via_estate_agent",
    name = "Sell via estate agent",
    description = "List with an agent, accept an offer, then conveyancing to completion.",
    jurisdiction = "england-and-wales",
    deal_types = { "sell" },
    stages = {
        {
            key = "instruct_agent", name = "Instruct agent", expected_working_days = 5,
            tasks = {
                { key = "choose_agent", title = "Choose and instruct an estate agent", owner = "operator",
                  due = { from = "stage_entry", working_days = 3 }, blocking = true, approval = "none" },
                { key = "material_info", title = "Complete material information (Parts A/B/C)", owner = "operator",
                  due = { from = "stage_entry", working_days = 3 }, blocking = true, compliance = true, approval = "none" },
                { key = "epc_valid", title = "Make sure a valid EPC is on the register", owner = "operator",
                  due = { from = "stage_entry", working_days = 2 }, blocking = true, approval = "none",
                  agent = { eligible = true, agent_key = "property_enrichment", auto = true } },
            },
        },
        {
            key = "marketing", name = "On the market", expected_working_days = 30,
            tasks = {
                { key = "weekly_update", title = "Weekly viewing and feedback update", owner = "operator",
                  repeat_every = { working_days = 5 }, due = { from = "stage_entry", working_days = 5 }, approval = "none" },
            },
        },
        {
            key = "sale_agreed", name = "Sale agreed", expected_working_days = 2,
            tasks = {
                { key = "instruct_solicitor", title = "Instruct seller's solicitor", owner = "operator",
                  due = { from = "stage_entry", working_days = 1 }, blocking = true, approval = "none" },
                { key = "seller_aml", title = "Seller ID and AML", owner = "compliance",
                  due = { from = "stage_entry", working_days = 2 }, blocking = true, compliance = true, approval = "none" },
            },
        },
        {
            key = "conveyancing", name = "Conveyancing", expected_working_days = 40,
            tasks = {
                { key = "chase_progress", title = "Chase solicitors for progress", owner = "operator",
                  repeat_every = { working_days = 2 }, due = { from = "stage_entry", working_days = 2 },
                  agent = { eligible = true, agent_key = "legal_chaser" }, approval = "any_operator" },
            },
        },
        {
            key = "exchange", name = "Exchange", expected_working_days = 1,
            entry_gate = { tasks_done = { "seller_aml" }, compliance_passed = { "aml_cdd_seller" },
                           fields = { "agreed_price", "target_completion_date" } },
            tasks = {
                { key = "exchange_contracts", title = "Exchange contracts", owner = "manager", blocking = true,
                  due = { from = "target_exchange", working_days = 0 }, approval = "manager" },
            },
        },
        {
            key = "completion", name = "Completion", expected_working_days = 10,
            entry_gate = { tasks_done = { "exchange_contracts" } },
            tasks = {
                { key = "completion_funds", title = "Sale proceeds received", owner = "manager", blocking = true,
                  due = { from = "target_completion", working_days = 0 }, approval = "none" },
            },
        },
    },
    compliance = {
        { key = "aml_cdd_seller", name = "AML customer due diligence — seller", subject = "deal_party",
          party_role = "seller", expires_after_days = 365 },
    },
}
