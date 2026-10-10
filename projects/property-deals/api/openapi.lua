-- OpenAPI description of every hand-written Property Deals route (sdk.crud routes
-- are typed by the SDK already). Served in /openapi.json and /swagger, and the
-- source of the @opsapi/client/property-deals types. Responses use the house
-- envelope { success, data, meta? }; fields that are null are left out of the JSON,
-- so every non-required property may be missing.
local sdk = require("helper.plugin-sdk")

-- Schema shorthands
local function t(type_, extra)
    local s = { type = type_ }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end
local S = function(d) return t("string", d and { description = d }) end
local UUID = function(d) return t("string", { format = "uuid", description = d }) end
local DATE = function(d) return t("string", { format = "date", description = d }) end
local DT = function(d) return t("string", { format = "date-time", description = d }) end
local INT = function(d) return t("integer", d and { description = d }) end
local NUM = function(d) return t("number", d and { description = d }) end
local BOOL = function(d) return t("boolean", d and { description = d }) end
local function ENUM(values, d) return t("string", { enum = values, description = d }) end
local function ARR(items, d) return t("array", { items = items, description = d }) end
-- (empty Lua tables would encode as JSON arrays, so leave them out)
local function OBJ(props, required, d)
    if next(props) == nil then return t("object", { additionalProperties = true, description = d }) end
    return t("object", { properties = props, required = required, description = d })
end
local ANY = function(d) return { description = d or "Any JSON value" } end
local MONEY = function(d) return t("number", { description = d }) end

local PD_STATUS = { "todo", "in_progress", "waiting_third_party", "agent_running", "awaiting_approval", "done", "cancelled" }
local HEALTH = { "green", "amber", "red" }
local PARTIES = { "seller", "buyer", "buyer_solicitor", "seller_solicitor", "lender", "freeholder", "managing_agent",
                  "council", "other" }

return function(app)
    local function schema(name, s) return sdk.schema(app, name, s) end

    -- ------------------------------------------------------------------ schemas
    local UrgencyFactor = schema("UrgencyFactor", OBJ({
        factor = ENUM({ "time", "completion", "blocking", "blockers", "silence", "money" }),
        value = NUM("0–1"), points = NUM("weight × value"), why = S("Plain-English reason"),
    }, { "factor", "value", "points", "why" }, "One line of the urgency 'why' (docs/property-deals/urgency.md)"))

    local Task = schema("Task", OBJ({
        uuid = UUID("Details row id"), task_uuid = UUID("Kanban task uuid — use this as the task id"),
        title = S(), description = S(), priority = ENUM({ "critical", "high", "medium", "low", "none" }),
        task_number = INT(), kanban_status = S("Status on kanban boards (follows pd_status)"),
        pd_status = ENUM(PD_STATUS), deal_uuid = UUID(), deal_name = S(), crm_deal_uuid = S(),
        property_uuid = UUID(), lead_uuid = S(), template_key = S("Template task key"), stage_key = S(),
        owner_user_uuid = S(), owner_agent_key = S(), due_at = DT(), sla_minutes = INT(), sla_started_at = DT(),
        sla_warned_at = DT(), sla_breached_at = DT("Set when the task went overdue"),
        escalation_level = INT("0 none, 1 warned, 2 overdue, 3 escalated"),
        urgency_score = NUM("0–100"), urgency_why = ARR(UrgencyFactor),
        blocking = BOOL("On the path to exchange/completion"), compliance = BOOL("Closing needs evidence"),
        agent_eligible = BOOL(), agent_key = S(), approval_rule = ENUM({ "none", "any_operator", "manager", "two_person" }),
        snoozed_until = DT(), snooze_reason = S(), completed_at = DT(), completed_by_user_uuid = S(),
        evidence = ANY("Object: note, document_uuid, … (auto-closed tasks: auto, reason)"),
        metadata = ANY("depends_on_keys, waiting_on (task keys this task waits for), due_note"),
        comment_count = INT(), attachment_count = INT(), created_at = DT(), updated_at = DT(),
    }, { "task_uuid", "title", "pd_status" }))

    local TaskSummary = schema("TaskSummary", OBJ({
        task_uuid = UUID(), title = S(), pd_status = ENUM(PD_STATUS), stage_key = S(), template_key = S(),
        due_at = DT(), sla_minutes = INT(), urgency_score = NUM(), urgency_why = ARR(UrgencyFactor),
        blocking = BOOL(), compliance = BOOL(), escalation_level = INT(), agent_eligible = BOOL(), agent_key = S(),
        approval_rule = S(), owner_user_uuid = S(), owner_agent_key = S(), snoozed_until = DT(),
        overdue = BOOL(), deal_uuid = UUID(), deal_name = S(), deal_health = ENUM(HEALTH),
    }, { "task_uuid", "title", "pd_status" }))

    local Deal = schema("Deal", OBJ({
        uuid = UUID("Property deal id"), crm_deal_uuid = S("The CRM deal it extends"), name = S(),
        deal_type = ENUM({ "buy", "sell", "buy_and_assign", "sourcing" }),
        status = ENUM({ "active", "on_hold", "completed", "fell_through" }), crm_status = S(),
        stage_key = S(), stage_entered_at = DT(), template_key = S(), template_version = INT(),
        template_version_uuid = UUID(), property_uuid = UUID(), seller_lead_uuid = S(), seller_contact_uuid = S(),
        owner_user_uuid = S(), currency = S(), value = NUM(), offer_amount = MONEY(), agreed_price = MONEY(),
        fees = ANY("Object"), finance_route = S(), target_exchange_date = DATE(), target_completion_date = DATE(),
        actual_exchange_at = DT(), actual_completion_at = DT(), late_penalty_per_day = MONEY(),
        late_penalty_cap_days = INT(), health = ENUM(HEALTH), health_reasons = ARR(S()),
        predicted_completion_date = DATE(), money_at_risk = MONEY(), kanban_epic_uuid = S(), notes = S(),
        address_line1 = S(), postcode = S(), town = S(), lat = NUM(), lng = NUM(), epc_rating = S(), tenure = S(),
        metadata = ANY("slip: the completion forecast breakdown"), created_at = DT(), updated_at = DT(),
    }, { "uuid", "crm_deal_uuid", "name", "stage_key", "status", "health" }))

    local DealCreate = schema("DealCreate", OBJ({
        lead_uuid = UUID("Seller lead to convert (contact + seller party are created)"),
        contact_uuid = UUID("Or an existing CRM contact"), name = S("Default: the property address or contact name"),
        deal_type = ENUM({ "buy", "sell", "buy_and_assign", "sourcing" }),
        template = S("Template uuid or key (default per deal type)"), property_uuid = UUID(),
        offer_amount = MONEY(), agreed_price = MONEY(), currency = S(), fees = ANY(), finance_route = S(),
        target_exchange_date = DATE(), target_completion_date = DATE(), late_penalty_per_day = MONEY(),
        late_penalty_cap_days = INT(), notes = S(),
    }, nil, "Give lead_uuid or contact_uuid, not both. The first stage's tasks are created."))

    local DealUpdate = schema("DealUpdate", OBJ({
        name = S(), property_uuid = UUID(), offer_amount = MONEY(), agreed_price = MONEY(), fees = ANY(),
        finance_route = S(), target_exchange_date = DATE(), target_completion_date = DATE(),
        late_penalty_per_day = MONEY(), late_penalty_cap_days = INT(),
        status = ENUM({ "active", "on_hold", "completed", "fell_through" }), notes = S(),
    }, nil, "Only fields sent change. Stage moves: POST /deals/{id}/stage. Changing target dates re-times tasks."))

    local GateItem = schema("GateItem", OBJ({
        type = ENUM({ "task", "compliance", "document", "field", "enquiries" }),
        key = S("Task key, compliance key, document category or field"), message = S("What is missing, in words"),
    }, { "type", "key", "message" }))
    local Gate = schema("Gate", OBJ({ stage = S(), ok = BOOL(), missing = ARR(GateItem) }, { "stage", "ok", "missing" }))

    local Health = schema("DealHealth", OBJ({
        health = ENUM(HEALTH), reasons = ARR(S()), money_at_risk = MONEY(), predicted_completion_date = DATE(),
        target_completion_date = DATE(),
        facts = OBJ({
            working_days_left = INT(), open_blocking_tasks = INT(), overdue_blocking_tasks = INT(),
            open_blocking_enquiries = INT(), hours_since_third_party_reply = INT(), days_late = INT(),
            days_at_risk = INT(), slip = OBJ({ current_stage_wd = INT(), later_stages_wd = INT(), silence_wd = INT(),
                                               notes = ARR(S()) }),
        }),
    }, { "health", "reasons" }))

    local Lead = schema("Lead", OBJ({
        uuid = S(), first_name = S(), last_name = S(), email = S(), phone = S(), company_name = S(), source = S(),
        channel = S(), status = S("new | contacted | qualified | converted | lost"), priority = S(), score = INT(),
        owner_user_uuid = S(), notes = S(), converted_at = DT(), created_at = DT(), updated_at = DT(),
        deal_uuid = UUID("Latest property deal from this lead"),
        details = OBJ({
            uuid = UUID(), lead_kind = S(), situation = S(), situation_note = S(), deadline_date = DATE(),
            vulnerability_flag = BOOL(), vulnerability_note = S(), consent_basis = S(), consent_given_at = DT(),
            consent_channels = ARR(S()), privacy_notice_sent_at = DT(), retention_until = DATE(), property_uuid = UUID(),
        }, nil, "Property Deals fields (missing until set)"),
    }, { "uuid", "first_name" }))
    local LeadDetails = schema("LeadDetailsUpdate", OBJ({
        lead_kind = ENUM({ "seller", "buyer_investor", "landlord", "agent_referral", "other" }),
        situation = ENUM({ "probate", "broken_chain", "divorce", "relocation", "care_fees", "repossession_risk",
                           "tenanted", "unmortgageable", "other" }),
        situation_note = S(), deadline_date = DATE(), vulnerability_flag = BOOL(), vulnerability_note = S(),
        consent_basis = ENUM({ "consent", "contract", "legitimate_interests", "legal_obligation" }),
        consent_given_at = DT(), consent_channels = ARR(S()), privacy_notice_sent_at = DT(), retention_until = DATE(),
        property_uuid = UUID(),
    }))

    local TemplateRow = schema("WorkflowTemplate", OBJ({
        uuid = UUID(), key = S(), name = S(), description = S(), jurisdiction = S(), is_active = BOOL(),
        active_version_uuid = UUID(), active_version = INT(), active_deals = INT(),
        definition = ANY("The active version's definition (GET one template only)"), created_at = DT(), updated_at = DT(),
    }, { "uuid", "key", "name" }))
    local Definition = ANY("Workflow template definition — docs/property-deals/template-format.md")
    local TemplateVersion = schema("WorkflowTemplateVersion", OBJ({
        uuid = UUID(), template_uuid = UUID(), version = INT(), definition = Definition, notes = S(),
        published_by_user_uuid = S(), is_active = BOOL(), created_at = DT(),
    }, { "uuid", "version" }))
    local DefinitionBody = schema("TemplateDefinitionBody", OBJ({ definition = Definition, notes = S() }, { "definition" }))

    local Supplier = schema("Supplier", OBJ({
        uuid = UUID(), account_uuid = S("The CRM company"), name = S(), email = S(), phone = S(), website = S(),
        address_line1 = S(), city = S(), postal_code = S(), kinds = ARR(S()), base_lat = NUM(), base_lng = NUM(),
        radius_miles = NUM(), coverage = ANY(), accreditations = ANY(), price_list = ANY(),
        booking_method = ENUM({ "email", "api", "link", "phone" }), booking_config = ANY(),
        avg_turnaround_hours = NUM("Measured"), on_time_pct = NUM("Measured"), jobs_measured = INT(), rating = NUM(),
        active = BOOL(), notes = S(), created_at = DT(), updated_at = DT(),
    }, { "uuid", "account_uuid", "name" }))
    local SupplierWrite = schema("SupplierWrite", OBJ({
        account_uuid = UUID("Extend an existing CRM company (create only)"), name = S("Or create a company"),
        email = S(), phone = S(), website = S(), address_line1 = S(), city = S(), postal_code = S(),
        kinds = ARR(S("solicitor, surveyor, epc_assessor, broker, bridging_lender, builder, letting_agent, "
            .. "auction_house, freeholder, managing_agent, council, searches_provider")),
        base_lat = NUM(), base_lng = NUM(), radius_miles = NUM(), coverage = ANY(), accreditations = ANY(),
        price_list = ANY(), booking_method = ENUM({ "email", "api", "link", "phone" }), booking_config = ANY(),
        rating = NUM(), active = BOOL(), notes = S(),
    }))

    local Compliance = schema("ComplianceCheck", OBJ({
        uuid = UUID(), check_type = S("Template compliance key, e.g. aml_cdd_buyer"), jurisdiction_pack = S(),
        subject_type = ENUM({ "contact", "account", "deal", "property", "workspace" }), contact_uuid = S(),
        account_uuid = S(), deal_uuid = UUID(), property_uuid = UUID(), party_role = S(), task_uuid = S(),
        status = ENUM({ "not_started", "in_progress", "passed", "failed", "waived", "expired" }),
        risk_rating = ENUM({ "low", "medium", "high" }), evidence_document_uuid = UUID(),
        checked_by_user_uuid = S("Set by the server when passed/waived"), checked_at = DT(), expires_at = DT(),
        data = ANY(), notes = S(), created_at = DT(), updated_at = DT(),
    }, { "uuid", "check_type", "subject_type", "status" }))
    local ComplianceWrite = schema("ComplianceCheckWrite", OBJ({
        check_type = S(), jurisdiction_pack = S(), subject_type = ENUM({ "contact", "account", "deal", "property", "workspace" }),
        contact_uuid = UUID(), account_uuid = UUID(), deal_uuid = UUID(), property_uuid = UUID(), party_role = S(),
        task_uuid = UUID(), status = ENUM({ "not_started", "in_progress", "passed", "failed", "waived", "expired" }),
        risk_rating = ENUM({ "low", "medium", "high" }), evidence_document_uuid = UUID(), expires_at = DT(),
        data = ANY(), notes = S("Required to waive"),
    }, nil, "check_type and subject_type are required on create. Passing/waiving records who and when; AI agents can't."))

    local Document = schema("Document", OBJ({
        uuid = UUID(), deal_uuid = UUID(), property_uuid = UUID(), task_uuid = S(),
        category = ENUM({ "title", "lease", "survey", "valuation", "epc", "searches", "id", "proof_of_funds", "aml",
                          "contract", "completion_statement", "photo", "correspondence", "other" }),
        filename = S(), mime_type = S(), size_bytes = INT(), sha256 = S(), bucket = S(), object_key = S(),
        source = ENUM({ "upload", "agent", "email", "connector" }), uploaded_by_user_uuid = S(),
        download_url = S("Presigned, valid 5 minutes (GET one document only)"), created_at = DT(),
    }, { "uuid", "filename", "category" }))
    local DocumentUpload = schema("DocumentUpload", OBJ({
        file = t("string", { format = "binary" }), deal_uuid = UUID(), property_uuid = UUID(), task_uuid = UUID(),
        category = S(),
    }, { "file" }, "multipart/form-data; give deal_uuid or property_uuid. Max 25 MB."))

    local Approval = schema("Approval", OBJ({
        uuid = UUID(), subject_type = ENUM({ "agent_draft", "chase", "booking", "compliance_close", "offer", "deal_pack",
                                             "stage_gate", "other" }),
        action = S("What runs on approval, e.g. send_email, confirm_booking"), title = S(),
        agent_run_uuid = UUID(), task_uuid = S(), task_title = S(), deal_uuid = UUID(), deal_name = S(),
        payload = ANY("What will be sent/done (e.g. { to, subject, body })"),
        original_payload = ANY("The draft before edits"), payload_version = INT(), payload_sha256 = S(),
        rule = ENUM({ "any_operator", "manager", "two_person" }),
        status = ENUM({ "pending", "approved", "rejected", "cancelled", "executed", "failed" }),
        requested_by_user_uuid = S(), requested_by_agent = S(),
        decisions = ARR(OBJ({ user_uuid = S(), decision = ENUM({ "approve", "reject" }), note = S(), at = DT(),
                              payload_version = INT(), payload_sha256 = S(), edited = BOOL() })),
        decided_at = DT(), executed_at = DT(), execution_result = ANY(), jobshout_approval_id = S(), expires_at = DT(),
        agent_key = S(), provider = S(), model = S(), cost_usd = NUM(), tokens_in = INT(), tokens_out = INT(),
        run_sources = ANY("Sources the agent used"), run_steps = ANY("Inbox: the agent's tool calls (refused ones too)"),
        run_output = ANY("Inbox: the agent's structured output"), execution_attempts = INT(),
        jobshout_provider_uuid = UUID(), from_jobshout = BOOL(), can_decide = BOOL("Inbox only"),
        waiting_for = S("After a first two_person approval"), created_at = DT(), updated_at = DT(),
    }, { "uuid", "title", "status", "rule" }))
    local ApprovalCreate = schema("ApprovalCreate", OBJ({
        subject_type = ENUM({ "agent_draft", "chase", "booking", "compliance_close", "offer", "deal_pack", "stage_gate", "other" }),
        action = S(), title = S(), payload = ANY(), rule = ENUM({ "any_operator", "manager", "two_person" }),
        deal_uuid = UUID(), task_uuid = UUID(), agent_run_uuid = UUID(), expires_at = DT(),
    }, { "subject_type", "action", "title", "payload" }))
    local Decide = schema("ApprovalDecision", OBJ({
        decision = ENUM({ "approve", "reject" }), note = S("Required to reject"),
        payload = ANY("Edited version (approve only); stored as a new payload version"),
        payload_version = INT("The version you looked at: 409 if the draft changed since (recommended)"),
        payload_sha256 = S("Or its hash"),
    }, { "decision" }))

    local DealCard = OBJ({ uuid = UUID(), name = S(), stage_key = S(), health = ENUM(HEALTH), health_reasons = ARR(S()),
        money_at_risk = MONEY(), target_completion_date = DATE(), predicted_completion_date = DATE() })
    local ApprovalCard = OBJ({ uuid = UUID(), title = S(), subject_type = S(), action = S(), rule = S(), deal_uuid = UUID(),
        deal_name = S(), task_uuid = S(), created_at = DT(), requested_by_agent = S(), approvals_so_far = INT(),
        agent_key = S(), provider = S(), model = S(), cost_usd = NUM(), from_jobshout = BOOL() })

    local Today = schema("Today", OBJ({
        generated_at = DT(), today = DATE("Workspace-local date"),
        counts = OBJ({ open = INT(), overdue = INT(), due_today = INT(), awaiting_approval = INT() }),
        tasks = ARR(TaskSummary, "My open tasks, most urgent first"),
        red_deals = ARR(DealCard, "Red deals I own or work on (managers: all)"),
        money_at_risk = MONEY("Total across those deals"),
        approvals_waiting = ARR(ApprovalCard, "Up to 10 I may decide"), approvals_waiting_count = INT(),
    }, { "tasks", "red_deals", "approvals_waiting", "counts" }))

    local Me = schema("Me", OBJ({
        user_uuid = S(), namespace_uuid = S(), is_manager = BOOL(), setup_done = BOOL(),
        permissions = OBJ({}, nil, "module (deals, properties, buyers, tasks, suppliers, compliance, approvals, ai, "
            .. "settings, reports) -> allowed actions (read, create, update, delete, manage)"),
        settings = OBJ({ timezone = S(), jurisdiction = S(), currency = S(), digest_time = S(), due_time = S(),
            sla_warn_pct = INT(), sla_breach_pct = INT(), sla_reassign_pct = INT(), escalation_action = S(),
            red_min_working_days = INT() }),
    }, { "user_uuid", "permissions" }))

    local Board = schema("DealBoard", OBJ({
        template = OBJ({ uuid = UUID(), key = S(), name = S(), version = INT() }),
        columns = ARR(OBJ({
            key = S(), name = S(), parallel = BOOL(), optional = BOOL(), has_gate = BOOL("Dropping here checks a gate"),
            gate_summary = OBJ({ tasks = INT(), compliance = INT(), documents = INT(), fields = INT(),
                                 no_open_blocking_enquiries = BOOL() }),
            deals = ARR(OBJ({ uuid = UUID(), name = S(), stage_key = S(), status = S(), health = ENUM(HEALTH),
                money_at_risk = MONEY(), deal_type = S(), target_completion_date = DATE(), predicted_completion_date = DATE(),
                owner_user_uuid = S(), address_line1 = S(), postcode = S(), open_tasks = INT(), overdue_tasks = INT() })),
        })),
        other_stage = ARR(ANY(), "Deals on a stage no longer in the template"),
    }))

    local Overview = schema("DealOverview", OBJ({
        deal = Deal, property = ANY("Property record (see Property schema of /properties)"),
        stage = OBJ({ current = S(), next = S(), next_gate = Gate,
            stages = ARR(OBJ({ key = S(), name = S(), parallel = BOOL(), optional = BOOL(), has_gate = BOOL(),
                               state = ENUM({ "done", "current", "upcoming", "skipped" }) })) }),
        health = OBJ({ health = ENUM(HEALTH), reasons = ARR(S()), money_at_risk = MONEY(), target_completion_date = DATE(),
            predicted_completion_date = DATE(), working_days_left = INT(), late_penalty_per_day = MONEY(),
            late_penalty_cap_days = INT() }),
        parties = ARR(OBJ({ uuid = UUID(), role = S(), is_primary = BOOL(), contact_uuid = S(), account_uuid = S(),
                            name = S(), email = S(), phone = S() })),
        tasks = OBJ({ counts = OBJ({ total = INT(), done = INT(), overdue = INT() }), open = ARR(TaskSummary) }),
        enquiries = ARR(OBJ({ uuid = UUID(), title = S(), owner_party = ENUM(PARTIES), status = S(), blocking = BOOL(),
                              raised_at = DT(), due_at = DT(), source = S() })),
        recent_chases = ARR(OBJ({ uuid = UUID(), to_party = S(), to_name = S(), channel = S(), subject = S(), status = S(),
                                  sent_at = DT(), reply_at = DT(), enquiry_uuid = UUID() })),
        compliance = ARR(OBJ({ key = S(), name = S(), party_role = S(), applies = BOOL(), status = S(),
                               check = ANY("Latest ComplianceCheck") })),
        documents = ARR(OBJ({ category = S(), count = INT() })),
        approvals_waiting = ARR(ApprovalCard), top_matches = ARR(ANY("Match")),
    }, { "deal", "stage", "health", "tasks" }))

    local TimelineItem = schema("TimelineItem", OBJ({
        uuid = S(), event_type = S("e.g. property_deals.task.updated, property_deals.deal.stage_changed"),
        entity_type = S(), entity_id = S(), actor_user_uuid = S(), old_values = ANY(), new_values = ANY(), created_at = DT(),
    }))

    local MapFeature = schema("MapFeature", OBJ({
        layer = ENUM({ "properties", "deals", "leads", "holdings", "sold_prices", "epc", "listings", "auction_lots" }),
        uuid = S(), lat = NUM(), lng = NUM(),
        title = S(), subtitle = S(), distance_miles = NUM("Radius queries"), tenure = S(), epc_rating = S(), bedrooms = INT(),
        est_market_value = MONEY(), deal_uuid = UUID(), deal_stage = S(), deal_health = ENUM(HEALTH), deal_name = S(),
        lead_kind = S(), situation = S(), deadline_date = DATE(), status = S(), property_uuid = UUID(),
        record_type = S("Market layers"), price = MONEY(), previous_price = MONEY("Before a price cut"),
        event_date = DATE("Sold / lodged / listed / auction date"), property_type = S(), cash_only = BOOL(), url = S(),
        source = S("Connector kind or CSV source"),
    }, { "layer", "uuid", "lat", "lng" }))
    local MapResult = schema("MapResult", OBJ({
        center = OBJ({ lat = NUM(), lng = NUM() }), radius_miles = NUM(), polygon = ARR(ARR(NUM())),
        features = ARR(MapFeature), counts = OBJ({}, nil, "layer -> features"), truncated = BOOL("More than 2000"),
    }, { "features" }))
    local Card = schema("PropertyCard", OBJ({
        property = ANY("Property"), deal = DealCard, gross_yield_pct = NUM(), discount_pct = NUM("vs estimated value"),
        comps = OBJ({ count = INT(), median = MONEY(), radius_miles = NUM(), months = INT(), from = DATE(), to = DATE() },
            nil, "Sold-price comparables within a mile, last 24 months"),
        discount_vs_comps_pct = NUM("Price (or estimate) vs the comparables' median"),
        top_matches = ARR(OBJ({ uuid = UUID(), buyer_profile_uuid = UUID(), buyer_name = S(), score = NUM(),
                                breakdown = ANY(), status = S() })),
    }))

    local Digest = schema("Digest", OBJ({
        date = DATE(), user_uuid = S(), manager = BOOL(), summary = S("One line"),
        overdue = ARR(TaskSummary), due_today = ARR(TaskSummary), deals_at_risk = ARR(DealCard),
        compliance_expiring = ARR(ANY("ComplianceCheck summary")), proof_of_funds_expiring = ARR(ANY()),
        approvals_waiting = ARR(ANY()),
        totals = OBJ({ overdue = INT(), due_today = INT(), deals_at_risk = INT(), money_at_risk = MONEY(),
                       compliance_expiring = INT(), approvals_waiting = INT() }),
    }))
    local Setup = schema("WorkspaceState", OBJ({
        uuid = UUID(), kanban_project_uuid = S(), kanban_board_uuid = S(), setup_at = DT(), setup_by_user_uuid = S(),
    }))

    -- ------------------------------------------------------------------ routes
    local id = { id = UUID("Deal uuid") }
    local tid = { id = UUID("Task uuid (kanban task uuid)") }
    local E404 = { ["404"] = "Not found in this workspace" }
    local E422 = { ["422"] = "Validation failed (details: field -> message)" }

    sdk.doc(app, "GET /me", { summary = "Who I am here", permission = "property_deals_deals.read", response = Me,
        description = "Permissions per Property Deals module, so screens can hide what a role can't do." })
    sdk.doc(app, "GET /today", { summary = "Today screen", permission = "property_deals_tasks.read", response = Today,
        query = { limit = INT("Tasks to return (default 50, max 200)") } })
    local Renovation = schema("Renovation", OBJ({
        uuid = UUID(), project_uuid = S("Kanban project uuid: open it at /dashboard/projects/<uuid>"), board_uuid = S(),
        deal_uuid = UUID(), deal_name = S(), property_uuid = UUID(), address = S(), postcode = S(), template_key = S(),
        name = S(), status = S(), budget = MONEY(), budget_spent = MONEY(), budget_currency = S(),
        start_date = DATE(), due_date = DATE(), jobs_total = INT(), jobs_done = INT(), jobs_overdue = INT(),
        created_at = DT(), builders_added = ARR(S("User uuid added to the project")),
    }))
    local DueItem = schema("DueItem", OBJ({
        kind = ENUM({ "deal_task", "renovation_job" }), uuid = S("Kanban task uuid"), title = S(), due_at = DT(),
        overdue = BOOL(), status = S(), deal_uuid = UUID(), deal_name = S(), project_uuid = S(), project_name = S(),
        column_name = S("Build stage (renovation jobs)"), assignee = S(),
    }))
    sdk.doc(app, "GET /renovations", { summary = "Renovation projects with progress", permission = "property_deals_deals.read",
        response = ARR(Renovation), query = { status = ENUM({ "active", "completed", "all" }), deal_uuid = UUID() } })
    sdk.doc(app, "POST /renovations", { summary = "Start a renovation (kanban project with build-stage columns)",
        permission = "property_deals_deals.create", response = Renovation, errors = E422,
        body = OBJ({ deal_uuid = UUID(), property_uuid = UUID(), name = S(), budget = MONEY(), currency = S(),
            start_date = DATE(), target_end_date = DATE("The standard jobs are spread to finish by this date"),
            builder_user_uuids = ARR(S("Workspace members to add to the board")) }) })
    sdk.doc(app, "GET /due", { summary = "Deal tasks and renovation jobs due soon", permission = "property_deals_tasks.read",
        response = OBJ({ days = INT(), everyone = BOOL("True when a manager sees the whole team"), items = ARR(DueItem) }),
        query = { days = INT("Look-ahead in days (default 7, max 60)"), mine = BOOL("Managers: only my own") } })
    sdk.doc(app, "GET /setup", { summary = "Workspace setup state", permission = "property_deals_settings.read",
        response = Setup, description = "Missing (null) until POST /setup ran." })
    sdk.doc(app, "POST /setup", { summary = "Set up the workspace (idempotent)", permission = "property_deals_settings.manage",
        status = 200, response = OBJ({ state = Setup, created = OBJ({ roles = ARR(S()), templates = ARR(S()), holidays = INT() }) }) })
    local SignalRun = OBJ({ watch = OBJ({ leads = INT(), signals = INT(), errors = INT(),
            followups = INT("Follow-up drafts started for leads with news") }),
        new_companies = OBJ({ areas = INT(), companies = INT(), leads = INT() }) })
    sdk.doc(app, "POST /engine/run", { summary = "Run engine checks now", permission = "property_deals_settings.manage",
        status = 200, body = OBJ({ checks = ARR(ENUM({ "sla", "health", "compliance_expiry", "digest", "agents", "mail",
            "scout", "nightly", "signals" })) }),
        response = OBJ({ sla = OBJ({ warned = INT(), overdue = INT(), escalated = INT() }), health = OBJ({ deals = INT() }),
                         compliance_expiry = OBJ({ expired = INT(), warned = INT(), pof_expired = INT() }),
                         digest = OBJ({ sent = INT() }),
                         agents = OBJ({ resumed = INT(), timed_out = INT(), jobshout_polled = INT(), jobshout_decided = INT(),
                                        auto_started = INT() }),
                         mail = OBJ({ connectors = INT(), stored = INT(), errors = INT() }),
                         scout = OBJ({ searches = INT(), alerts = INT(), synced = OBJ({ connectors = INT(),
                             postcodes = INT(), stored = INT() }) }),
                         nightly = OBJ({ suppliers = INT(), inbound = INT(), agent_runs = INT(), market = INT() }),
                         signals = SignalRun }),
        errors = E422 })

    local LeadSignal = schema("LeadSignal", OBJ({
        uuid = UUID(), lead_uuid = S(), kind = ENUM({ "company_formed", "officer_appointed", "company_filing",
            "charge_registered", "social_post", "website", "news", "note" }),
        source = ENUM({ "companies_house", "manual", "share" }), title = S(), summary = S(), url = S(),
        occurred_at = DT(), data = ANY("Source details (company number, SIC codes, role...)"),
        used_at = DT("When a follow-up last quoted it"), created_by_user_uuid = S(), created_at = DT(),
    }))
    local LeadReply = schema("LeadReply", OBJ({
        uuid = UUID(), lead_uuid = S(), deal_uuid = UUID(), channel = ENUM({ "email", "sms", "whatsapp", "phone", "social", "other" }),
        from_address = S(), from_name = S(), subject = S(), received_at = DT(), body_text = S(),
        reply_temperature = ENUM({ "hot", "warm", "cold" }), reply_score = INT("0-100"), reply_reason = S("Why"),
        hot_task_uuid = S("The \"call now\" task a hot reply raised"), matched_by = S(), logged_by_user_uuid = S(),
        alerted = INT("People alerted (POST only)"), scored_by = ENUM({ "ai", "rules" }, "POST only"),
    }))
    local HotLead = schema("HotLead", OBJ({
        lead_uuid = S(), first_name = S(), last_name = S(), company_name = S(), phone = S(), email = S(),
        owner_user_uuid = S(), lead_kind = S(), hot_score = INT(), hot_reason = S(), last_reply_at = DT(),
        call_task_uuid = S(), call_due_at = DT(),
    }))
    local lid = { uuid = S("Lead uuid") }
    sdk.doc(app, "GET /leads/:uuid/signals", { summary = "A lead's recent news", permission = "property_deals_deals.read",
        path = lid, response = ARR(LeadSignal), errors = E404, query = { limit = INT("Default 50, max 200") } })
    sdk.doc(app, "POST /leads/:uuid/signals", { summary = "Capture a post, page or note about a lead",
        permission = "property_deals_deals.update", path = lid, response = LeadSignal, errors = E422,
        description = "Paste what they posted (or its link). Social networks are never fetched by the server.",
        body = OBJ({ kind = ENUM({ "social_post", "website", "news", "note" }), text = S(), url = S(), title = S(),
            occurred_at = DT() }, { "kind" }) })
    sdk.doc(app, "DELETE /signals/:id", { summary = "Delete a signal", permission = "property_deals_deals.update",
        path = { id = UUID() }, status = 200, response = OBJ({ deleted = BOOL() }), errors = E404 })
    sdk.doc(app, "GET /leads/:uuid/replies", { summary = "A lead's replies, scored", permission = "property_deals_deals.read",
        path = lid, response = ARR(LeadReply), errors = E404 })
    sdk.doc(app, "POST /leads/:uuid/replies", { summary = "Log a reply (WhatsApp, SMS, call, DM): scored, hot -> call alert",
        permission = "property_deals_deals.update", path = lid, response = LeadReply, errors = E422,
        body = OBJ({ channel = ENUM({ "whatsapp", "sms", "phone", "social", "email", "other" }), text = S(),
            received_at = DT(), from_name = S(), subject = S() }, { "channel", "text" }) })
    sdk.doc(app, "GET /hot-leads", { summary = "Leads whose last reply was hot (7 days)", permission = "property_deals_tasks.read",
        response = ARR(HotLead), query = { mine = BOOL("Only leads I own"), limit = INT() } })
    sdk.doc(app, "GET /companies-house/officers", { summary = "Find a Companies House officer to link to a lead",
        permission = "property_deals_deals.read", query = { q = S("Name, 3+ characters") }, errors = E422,
        response = ARR(OBJ({ officer_id = S(), name = S(), appointments = INT(), address = S(), born = S("MM/YYYY") })) })
    sdk.doc(app, "POST /leads/:uuid/follow-up", { summary = "AI drafts a personal follow-up (approved before sending)",
        permission = "property_deals_tasks.create", path = lid, status = 202, errors = E422,
        description = "Starts the lead_followup agent on a follow-up task. The draft becomes an approval (action "
            .. "send_lead_followup): email is sent through the workspace SMTP, SMS through the workspace's Android "
            .. "SMS Gateway, WhatsApp becomes a click-to-chat link a person sends. 409 if the lead opted out or a "
            .. "follow-up is already being drafted / waiting.",
        body = OBJ({ channel = ENUM({ "email", "whatsapp", "sms" }), signal_uuid = UUID("News item to open with"),
            note = S("A steer for the AI, e.g. 'mention the Leeds HMO'") }),
        response = OBJ({ task_uuid = S(), run_uuid = UUID(), status = S() }) })
    sdk.doc(app, "POST /signals/run", { summary = "Run the Companies House watch now", permission = "property_deals_settings.manage",
        status = 200, response = SignalRun })
    sdk.doc(app, "GET /leads", { summary = "Leads with Property Deals fields", permission = "property_deals_deals.read",
        paginated = true, response = ARR(Lead), query = {
            lead_kind = S(), situation = S(), status = S(), source = S(), owner_user_uuid = S(),
            temperature = ENUM({ "hot", "warm", "cold" }, "From the last reply"),
            vulnerable = ENUM({ "true" }), deadline_before = DATE(), q = S("Name, email or phone"),
            sort = ENUM({ "created", "deadline", "last_reply" }) } })
    sdk.doc(app, "GET /leads/:uuid", { summary = "A lead with its Property Deals fields", permission = "property_deals_deals.read",
        response = Lead, errors = E404, path = { uuid = S("CRM lead uuid") } })
    sdk.doc(app, "PUT /leads/:uuid/details", { summary = "Set a lead's Property Deals fields", status = 200,
        permission = "property_deals_deals.update", body = LeadDetails, response = Lead, errors = { ["404"] = "Not found", ["422"] = E422["422"] } })

    sdk.doc(app, "GET /deals", { summary = "List deals", permission = "property_deals_deals.read", paginated = true,
        response = ARR(Deal), query = { stage_key = S(), status = S(), health = ENUM(HEALTH), deal_type = S(),
            property_uuid = UUID(), owner_user_uuid = S(), q = S("Name, address or postcode"),
            sort = ENUM({ "created", "target_completion", "money_at_risk", "health" }) } })
    sdk.doc(app, "GET /deals/board", { summary = "Deals by stage (Kanban)", permission = "property_deals_deals.read",
        response = Board, query = { template = S("Template key or uuid (default: the one most active deals use)") }, errors = E404 })
    sdk.doc(app, "GET /deals/:id", { summary = "Get a deal", permission = "property_deals_deals.read", response = Deal,
        path = id, errors = E404 })
    sdk.doc(app, "POST /deals", { summary = "Create a deal", permission = "property_deals_deals.create", body = DealCreate,
        response = Deal, errors = E422 })
    sdk.doc(app, "PUT /deals/:id", { summary = "Update a deal", permission = "property_deals_deals.update", body = DealUpdate,
        response = Deal, path = id, errors = { ["404"] = "Not found", ["422"] = E422["422"] } })
    sdk.doc(app, "GET /deals/:id/overview", { summary = "Deal page in one call", permission = "property_deals_deals.read",
        response = Overview, path = id, errors = E404 })
    sdk.doc(app, "GET /deals/:id/timeline", { summary = "Deal timeline (audit trail)", permission = "property_deals_deals.read",
        response = ARR(TimelineItem), paginated = true, path = id, errors = E404 })
    sdk.doc(app, "GET /deals/:id/gate", { summary = "What stops the deal entering a stage", permission = "property_deals_deals.read",
        response = Gate, path = id, query = { to = S("Stage key (default: the next stage)") }, errors = { ["404"] = "Not found", ["422"] = "Unknown stage" } })
    sdk.doc(app, "POST /deals/:id/stage", { summary = "Move a deal to a stage", permission = "property_deals_deals.update",
        status = 200, path = id, body = OBJ({ to = S("Stage key") }, { "to" }),
        response = OBJ({ deal = Deal, tasks_created = ARR(Task) }),
        errors = { ["404"] = "Not found", ["409"] = "Gate not met: error lists the reasons, details.missing the items (GateItem[])",
                   ["422"] = "Unknown stage" } })
    sdk.doc(app, "POST /deals/:id/advance", { summary = "Move to the next stage", permission = "property_deals_deals.update",
        status = 200, path = id, response = OBJ({ deal = Deal, tasks_created = ARR(Task) }),
        errors = { ["404"] = "Not found", ["409"] = "Gate not met, or already at the last stage" } })
    sdk.doc(app, "GET /deals/:id/health", { summary = "Deal health and forecast (recomputed now)",
        permission = "property_deals_deals.read", response = Health, path = id, errors = E404 })

    sdk.doc(app, "GET /tasks", { summary = "List deal tasks", permission = "property_deals_tasks.read", paginated = true,
        response = ARR(Task), query = { deal_uuid = UUID(), pd_status = S("Comma list"), owner_user_uuid = S(),
            open = ENUM({ "true" }), blocking = ENUM({ "true" }), compliance = ENUM({ "true" }),
            sort = ENUM({ "urgency", "due", "created" }) } })
    sdk.doc(app, "GET /tasks/:id", { summary = "Get a task", permission = "property_deals_tasks.read", response = Task, path = tid, errors = E404 })
    sdk.doc(app, "POST /tasks", { summary = "Create an ad-hoc task", permission = "property_deals_tasks.create",
        body = OBJ({ title = S(), description = S(), priority = ENUM({ "critical", "high", "medium", "low" }),
            deal_uuid = UUID(), property_uuid = UUID(), lead_uuid = UUID(), stage_key = S(), owner_user_uuid = UUID(),
            due_at = DT(), sla_minutes = INT(), blocking = BOOL(), compliance = BOOL(), agent_eligible = BOOL(),
            agent_key = S(), approval_rule = ENUM({ "none", "any_operator", "manager", "two_person" }) }, { "title" }),
        response = Task, errors = E422 })
    sdk.doc(app, "PUT /tasks/:id", { summary = "Update a task (do it, assign, snooze...)", permission = "property_deals_tasks.update",
        path = tid, response = Task, errors = { ["404"] = "Not found", ["422"] = "Validation failed — compliance tasks need evidence to close; snoozing needs a reason" },
        body = OBJ({ pd_status = ENUM(PD_STATUS), title = S(), description = S(), priority = S(), owner_user_uuid = UUID(),
            due_at = DT(), sla_minutes = INT(), blocking = BOOL(), compliance = BOOL(), agent_eligible = BOOL(), agent_key = S(),
            approval_rule = S(), snoozed_until = DT(), snooze_reason = S(), evidence = ANY("Object") }),
        description = "Finishing a task starts its dependants, closes tasks whose condition now holds and repeats repeating tasks." })
    local Dep = OBJ({ depends_on_task_uuid = UUID(), title = S(), pd_status = S() })
    sdk.doc(app, "GET /tasks/:id/dependencies", { summary = "What a task waits for", permission = "property_deals_tasks.read",
        path = tid, response = ARR(Dep), errors = E404 })
    sdk.doc(app, "POST /tasks/:id/dependencies", { summary = "Add a prerequisite", permission = "property_deals_tasks.update",
        path = tid, body = OBJ({ depends_on_task_uuid = UUID() }, { "depends_on_task_uuid" }),
        response = OBJ({ task_uuid = UUID(), depends_on_task_uuid = UUID() }), errors = { ["404"] = "Not found", ["422"] = "Unknown task or a cycle" } })
    sdk.doc(app, "DELETE /tasks/:id/dependencies/:dep", { summary = "Remove a prerequisite", permission = "property_deals_tasks.update",
        path = { id = UUID(), dep = UUID() }, response = OBJ({}), errors = E404 })

    sdk.doc(app, "GET /workflow-templates", { summary = "List workflow templates", permission = "property_deals_settings.read",
        response = ARR(TemplateRow) })
    sdk.doc(app, "GET /workflow-templates/:id", { summary = "A template with its active definition",
        permission = "property_deals_settings.read", response = TemplateRow, path = { id = UUID() }, errors = E404 })
    sdk.doc(app, "PUT /workflow-templates/:id", { summary = "Rename, (de)activate or roll back a template",
        permission = "property_deals_settings.update", path = { id = UUID() }, response = TemplateRow,
        body = OBJ({ name = S(), description = S(), is_active = BOOL(), active_version_uuid = UUID() }),
        errors = { ["404"] = "Not found", ["422"] = E422["422"] } })
    sdk.doc(app, "GET /workflow-templates/:id/versions", { summary = "Template versions", permission = "property_deals_settings.read",
        path = { id = UUID() }, response = ARR(TemplateVersion), errors = E404 })
    sdk.doc(app, "GET /workflow-templates/:id/versions/:version", { summary = "One template version",
        permission = "property_deals_settings.read", path = { id = UUID(), version = INT() }, response = TemplateVersion, errors = E404 })
    sdk.doc(app, "POST /workflow-templates/:id/versions", { summary = "Publish a new version",
        permission = "property_deals_settings.update", path = { id = UUID() }, body = DefinitionBody, response = TemplateVersion,
        errors = { ["404"] = "Not found", ["422"] = "Template is not valid (details: one message per problem)" } })
    sdk.doc(app, "GET /workflow-templates/:id/export", { summary = "Export the active definition (JSON)",
        permission = "property_deals_settings.read", path = { id = UUID() }, response = Definition, errors = E404 })
    sdk.doc(app, "POST /workflow-templates/import", { summary = "Import a template (new, or a new version of the same key)",
        permission = "property_deals_settings.create", body = DefinitionBody,
        response = OBJ({ template = TemplateRow, version = INT() }), errors = { ["422"] = "Template is not valid" } })

    sdk.doc(app, "GET /suppliers", { summary = "Supplier directory", permission = "property_deals_suppliers.read",
        paginated = true, response = ARR(Supplier), query = { kind = S(), active = ENUM({ "true", "false" }), q = S(),
            sort = ENUM({ "name", "speed", "on_time", "rating" }) } })
    sdk.doc(app, "GET /suppliers/:id", { summary = "Get a supplier", permission = "property_deals_suppliers.read",
        response = Supplier, path = { id = UUID() }, errors = E404 })
    sdk.doc(app, "POST /suppliers", { summary = "Add a supplier", permission = "property_deals_suppliers.create",
        body = SupplierWrite, response = Supplier, errors = E422 })
    sdk.doc(app, "PUT /suppliers/:id", { summary = "Update a supplier", permission = "property_deals_suppliers.update",
        body = SupplierWrite, response = Supplier, path = { id = UUID() }, errors = { ["404"] = "Not found", ["422"] = E422["422"] } })
    sdk.doc(app, "DELETE /suppliers/:id", { summary = "Remove a supplier (the CRM company stays)",
        permission = "property_deals_suppliers.delete", response = OBJ({}), path = { id = UUID() }, errors = E404 })

    sdk.doc(app, "GET /compliance-checks", { summary = "Compliance checks", permission = "property_deals_compliance.read",
        paginated = true, response = ARR(Compliance), query = { status = S(), check_type = S(), subject_type = S(),
            party_role = S(), deal_uuid = UUID(), property_uuid = UUID(), contact_uuid = UUID(), account_uuid = UUID(),
            expiring_within_days = INT("Passed checks expiring within N days") } })
    sdk.doc(app, "POST /compliance-checks", { summary = "Start or record a compliance check",
        permission = "property_deals_compliance.create", body = ComplianceWrite, response = Compliance,
        errors = { ["403"] = "AI agents can't sign off", ["422"] = E422["422"] } })
    sdk.doc(app, "PUT /compliance-checks/:id", { summary = "Update / sign off a compliance check",
        permission = "property_deals_compliance.update", body = ComplianceWrite, response = Compliance,
        path = { id = UUID() }, errors = { ["404"] = "Not found", ["422"] = E422["422"] } })

    sdk.doc(app, "GET /documents", { summary = "Documents on a deal or property", permission = "property_deals_properties.read",
        paginated = true, response = ARR(Document), query = { deal_uuid = UUID(), property_uuid = UUID(), task_uuid = UUID(), category = S() } })
    sdk.doc(app, "POST /documents", { summary = "Upload a document", permission = "property_deals_properties.create",
        body = DocumentUpload, multipart = true, response = Document,
        errors = { ["400"] = "No file", ["413"] = "Over 25 MB", ["422"] = E422["422"], ["502"] = "Storage failed" } })
    sdk.doc(app, "GET /documents/:id", { summary = "Document + download link", permission = "property_deals_properties.read",
        response = Document, path = { id = UUID() }, errors = E404 })
    sdk.doc(app, "DELETE /documents/:id", { summary = "Delete a document", permission = "property_deals_properties.delete",
        response = OBJ({}), path = { id = UUID() }, errors = E404 })

    sdk.doc(app, "GET /approvals/inbox", { summary = "Approvals inbox", permission = "property_deals_approvals.read",
        response = ARR(Approval), query = { all = ENUM({ "true" }, "Include ones I can't decide (can_decide = false)") } })
    sdk.doc(app, "POST /approvals", { summary = "Ask for approval", permission = "property_deals_approvals.create",
        body = ApprovalCreate, response = Approval, errors = E422 })
    sdk.doc(app, "POST /approvals/:id/decide", { summary = "Approve (optionally edited) or reject",
        permission = "property_deals_approvals.update", status = 200, path = { id = UUID() }, body = Decide, response = Approval,
        errors = { ["403"] = "Own request, needs a manager, or an AI agent", ["404"] = "Not found",
                   ["409"] = "Already decided, or you already approved (two_person)", ["422"] = E422["422"] } })

    sdk.doc(app, "GET /map", { summary = "Map query (radius or polygon)", permission = "property_deals_properties.read",
        response = MapResult, errors = { ["422"] = "Bad area or layer" }, query = {
            lat = NUM(), lng = NUM(), radius_miles = NUM("1–100, default 25"),
            polygon = S("lat,lng;lat,lng;… (3–200 points) instead of lat/lng/radius"),
            layers = S("Comma list: properties, deals, leads, holdings, sold_prices, epc, listings, auction_lots "
                .. "(default properties,deals)") } })
    sdk.doc(app, "GET /properties/:id/card", { summary = "Map property card", permission = "property_deals_properties.read",
        response = Card, path = { id = UUID() }, errors = E404 })

    sdk.doc(app, "GET /digest", { summary = "My digest for today (live)", permission = "property_deals_tasks.read", response = Digest })
    sdk.doc(app, "GET /digest/history", { summary = "Digests sent to me", permission = "property_deals_tasks.read",
        paginated = true, response = ARR(OBJ({ local_date = DATE(), payload = Digest, empty = BOOL(), created_at = DT() })) })
    sdk.doc(app, "POST /digest/send", { summary = "Send today's digests now", permission = "property_deals_settings.manage",
        status = 200, response = OBJ({ sent = INT() }) })

    -- ------------------------------------------------------------------ AI layer (Phase 5)
    local AgentRun = schema("AgentRun", OBJ({
        uuid = UUID(), task_uuid = S(), deal_uuid = UUID(), agent_key = S(),
        provider = ENUM({ "builtin", "jobshout" }), provider_uuid = UUID("The workspace AI provider / JobShout link used"),
        model = S(), prompt_version = S(), status = ENUM({ "queued", "running", "succeeded", "failed", "cancelled" }),
        trigger = ENUM({ "manual", "auto", "email", "retry" }), attempt = INT(), retry_note = S("Reviewer's note it redrafted with"),
        steps = ARR(OBJ({ round = INT(), tool = S(), args = ANY(), refused = BOOL(), reason = S(), reply = BOOL(),
                          parsed = BOOL(), note = S(), error = S() })),
        output = ANY("Structured output"), output_draft = S("The draft text"), error = S(),
        tokens_in = INT(), tokens_out = INT(), cost_usd = NUM(), latency_ms = INT(), fallback_used = BOOL(),
        jobshout_task_id = S(), jobshout_run_id = S(), jobshout_execution_id = S(), triggered_by_user_uuid = S(),
        started_at = DT(), finished_at = DT(), created_at = DT(), updated_at = DT(),
    }, { "uuid", "agent_key", "provider", "status" }))
    local AgentConfig = schema("AgentConfig", OBJ({
        agent_key = S(), enabled = BOOL(), route = ENUM({ "builtin", "jobshout" }), jobshout_provider_uuid = UUID(),
        jobshout_agent_id = S(), jobshout_project_id = S(), fallback_to_builtin = BOOL("Use the built-in model when JobShout is down"),
        local_only = BOOL("Only providers flagged is_local"), approval_rule = ENUM({ "any_operator", "manager", "two_person" }),
        auto_pickup = BOOL(), auto_pickup_at = S("HH:MM, workspace time"), last_auto_run_on = DATE(),
        default = BOOL("Not saved yet: these are the defaults"),
    }, { "agent_key", "enabled", "route" }))
    local Agent = schema("Agent", OBJ({
        key = S(), name = S(), job_type = ENUM({ "classify", "extract", "draft", "plan", "chat", "summarise" }),
        version = S("Prompt version"), tools = ARR(S(), "Tool allowlist"),
        default_approval = S(), needs_deal = BOOL(), config = AgentConfig,
    }, { "key", "name", "job_type", "tools", "config" }))
    local Route = schema("AiRoute", OBJ({
        uuid = UUID(), job_type = S(), chain = ARR(OBJ({ provider_uuid = UUID(), model = S() }, { "provider_uuid" }),
            "Fallback order: tried in turn"), local_only = BOOL(), max_tokens = INT(), created_at = DT(), updated_at = DT(),
    }, { "job_type", "chain" }))
    local MailConnector = schema("MailConnector", OBJ({
        uuid = UUID(), name = S(), kind = ENUM({ "imap", "gmail", "m365" }),
        config = ANY("imap { host, port, ssl, username, mailbox } | gmail { client_id } | m365 { tenant_id, client_id, mailbox }"),
        has_secret = BOOL("The secret itself is never returned"), secret_hint = S(), enabled = BOOL(), cursor = ANY(),
        last_synced_at = DT(), last_error = S(), created_at = DT(), updated_at = DT(),
    }, { "uuid", "name", "kind", "has_secret" }))
    local MailConnectorWrite = schema("MailConnectorWrite", OBJ({
        name = S(), kind = ENUM({ "imap", "gmail", "m365" }), config = ANY(),
        secret = ANY("IMAP password | Gmail { client_secret, refresh_token } | M365 client secret; \"\" clears it"),
        enabled = BOOL(),
    }, nil, "name, kind and config are required on create"))
    local Inbound = schema("InboundMessage", OBJ({
        uuid = UUID(), connector_uuid = UUID(), from_address = S(), from_name = S(), subject = S(), received_at = DT(),
        body_text = S("Untrusted: shown as data, never acted on"), deal_uuid = UUID(),
        matched_by = ENUM({ "reference", "sender" }), chase_uuid = UUID("The chase this replied to"),
        agent_run_uuid = UUID("Legal chaser run it started"), processed_at = DT(),
    }, { "uuid", "from_address" }))
    local Channel = OBJ({ push = BOOL("App push (WSLCRM iOS/Android) + in-app"), email = BOOL(),
        ntfy = BOOL("ntfy connector; off unless turned on"), telegram = BOOL("Telegram bot connector; off unless turned on"),
        sms = BOOL("Android SMS Gateway connector; off unless turned on") })
    local Prefs = schema("NotificationPreferences", OBJ({
        sla_warning = Channel, overdue = Channel, escalated = Channel, approval_requested = Channel, digest = Channel,
        compliance_expiring = Channel, agent_update = Channel, deal_scout = Channel,
        hot_lead = OBJ({ push = BOOL(), email = BOOL(), ntfy = BOOL(), telegram = BOOL(), sms = BOOL() }, nil,
            "A lead replied and looks keen: call them now. Every channel is on by default."),
        ntfy_topic = S("My ntfy topic (default <topic_prefix>-<first 12 of my user uuid>)"),
        telegram_chat_id = S("My chat id with the workspace's Telegram bot"),
        quiet_hours = OBJ({ from = S("HH:MM"), to = S("HH:MM") }, { "from", "to" },
            "Workspace time; holds back push, ntfy, Telegram and SMS, not email or the digest"),
    }))
    local Chase = OBJ({ uuid = UUID(), deal_uuid = UUID(), lead_uuid = S(), task_uuid = S(), to_party = S(), to_name = S(),
        to_address = S(), channel = S(), subject = S(), body = S(), outcome = S(), status = S(), sent_at = DT(),
        sent_by_user_uuid = S(), created_at = DT() })

    sdk.doc(app, "GET /ai/agents", { summary = "Agent catalogue + this workspace's settings", permission = "property_deals_ai.read",
        response = ARR(Agent) })
    sdk.doc(app, "PUT /ai/agents/:key", { summary = "Configure an agent", permission = "property_deals_settings.update",
        status = 200, path = { key = S("Agent key, e.g. legal_chaser") }, response = AgentConfig, errors = E422,
        body = OBJ({ enabled = BOOL(), route = ENUM({ "builtin", "jobshout" }), jobshout_provider_uuid = UUID(),
            jobshout_agent_id = S(), jobshout_project_id = S(), fallback_to_builtin = BOOL(), local_only = BOOL(),
            approval_rule = ENUM({ "any_operator", "manager", "two_person" }), auto_pickup = BOOL(), auto_pickup_at = S("HH:MM") }) })
    sdk.doc(app, "GET /ai/routes", { summary = "Model chain per job type", permission = "property_deals_ai.read",
        response = ARR(Route) })
    sdk.doc(app, "PUT /ai/routes/:job_type", { summary = "Set a job type's model chain (fallback order)",
        permission = "property_deals_settings.update", status = 200, response = Route, errors = E422,
        path = { job_type = ENUM({ "classify", "extract", "draft", "plan", "chat", "summarise" }) },
        body = OBJ({ chain = ARR(OBJ({ provider_uuid = UUID(), model = S("Default: the provider's default_model") }, { "provider_uuid" })),
            local_only = BOOL(), max_tokens = INT() }, { "chain" }) })
    sdk.doc(app, "GET /ai/usage", { summary = "AI spend and runs", permission = "property_deals_ai.read",
        query = { days = INT("Window, 1–366 (default 30)") },
        response = OBJ({ days = INT(), spent_today_usd = NUM(), spent_window_usd = NUM(), cap_day_usd = NUM(), cap_run_usd = NUM(),
            by_agent = ARR(OBJ({ agent_key = S(), runs = INT(), failed = INT(), tokens_in = INT(), tokens_out = INT(),
                cost_usd = NUM(), avg_latency_ms = INT() })) }) })
    sdk.doc(app, "POST /tasks/:id/agent-run", { summary = "Let AI do it", permission = "property_deals_ai.create", status = 202,
        path = tid, body = OBJ({ note = S("Extra instruction for this run") }), response = AgentRun,
        description = "Starts the task's agent; poll GET /agent-runs/{id}. The draft lands in Approvals.",
        errors = { ["404"] = "Not found", ["409"] = "An agent is already on it, or the task is closed",
                   ["422"] = "Not agent-eligible, agent off/unavailable, or no AI provider", ["429"] = "Daily AI budget used up" } })
    sdk.doc(app, "POST /agent-runs/:id/cancel", { summary = "Cancel a queued/running run", permission = "property_deals_ai.update",
        status = 200, path = { id = UUID() }, response = AgentRun, errors = { ["409"] = "Not queued or running" } })
    sdk.doc(app, "POST /approvals/:id/retry", { summary = "Run a failed approved action again",
        permission = "property_deals_approvals.manage", status = 200, path = { id = UUID() }, response = Approval,
        errors = { ["404"] = "Not found", ["409"] = "Not failed", ["422"] = "Failed again (details.approval)" } })
    sdk.doc(app, "POST /bookings/:id/confirm", { summary = "Ask to confirm a supplier's slot (creates an approval)",
        permission = "property_deals_suppliers.update", path = { id = UUID("Booking uuid") }, response = Approval,
        body = OBJ({ slot_start = DT(), slot_end = DT(), cost = NUM(), subject = S(), body = S() }),
        errors = { ["404"] = "Not found", ["409"] = "Not requested/tentative", ["422"] = E422["422"] } })
    sdk.doc(app, "POST /tasks/:id/contact-log", { summary = "Log a call / message made from a task (deal or lead)",
        permission = "property_deals_tasks.create", path = tid, response = Chase, errors = E422,
        body = OBJ({ channel = ENUM({ "phone", "sms", "whatsapp", "email", "letter", "portal" }), to_party = ENUM(PARTIES),
            to_name = S(), to_address = S(), outcome = S("e.g. no_answer, spoke, left_message"), note = S(), subject = S(),
            sent_at = DT() }, { "channel" }) })
    local mc = { id = UUID("Mail connector uuid") }
    sdk.doc(app, "GET /mail-connectors", { summary = "Mailboxes the legal chaser reads", permission = "property_deals_settings.read",
        response = ARR(MailConnector) })
    sdk.doc(app, "POST /mail-connectors", { summary = "Add a mailbox (IMAP, Gmail, Microsoft 365)",
        permission = "property_deals_settings.update", body = MailConnectorWrite, response = MailConnector, errors = E422 })
    sdk.doc(app, "GET /mail-connectors/:id", { summary = "A mailbox", permission = "property_deals_settings.read",
        path = mc, response = MailConnector, errors = E404 })
    sdk.doc(app, "PUT /mail-connectors/:id", { summary = "Update a mailbox", permission = "property_deals_settings.update",
        status = 200, path = mc, body = MailConnectorWrite, response = MailConnector, errors = E422 })
    sdk.doc(app, "DELETE /mail-connectors/:id", { summary = "Remove a mailbox", permission = "property_deals_settings.update",
        path = mc, response = OBJ({ deleted = BOOL() }), errors = E404 })
    sdk.doc(app, "POST /mail-connectors/:id/sync", { summary = "Fetch new mail now", permission = "property_deals_settings.update",
        status = 200, path = mc, response = OBJ({ fetched = INT(), stored = INT(), matched = INT() }),
        errors = { ["404"] = "Not found", ["502"] = "Mailbox sign-in or fetch failed (also in last_error)" } })
    sdk.doc(app, "GET /inbound-messages", { summary = "Emails received about deals", permission = "property_deals_tasks.read",
        response = ARR(Inbound), query = { deal_uuid = UUID(), unmatched = ENUM({ "true" }), per_page = INT("1–100") } })
    sdk.doc(app, "POST /inbound-messages", { summary = "Log a received email by hand", permission = "property_deals_tasks.create",
        response = Inbound, errors = { ["409"] = "Already logged", ["422"] = E422["422"] },
        body = OBJ({ from_address = S(), from_name = S(), subject = S(), body_text = S(), received_at = DT(),
            deal_uuid = UUID("Attach to this deal (else matched by reference / sender)") }, { "from_address", "body_text" }) })
    sdk.doc(app, "GET /notification-preferences", { summary = "My notification preferences here", response = Prefs })
    sdk.doc(app, "PUT /notification-preferences", { summary = "Change my notification preferences", status = 200,
        body = Prefs, response = Prefs, errors = E422 })

    -- ------------------------------------------------------------------ map data + matching (Phase 6)
    local KINDS = { "epc", "price_paid", "companies_house", "postcodes", "csv", "propertydata", "searchland", "streetdata",
        "homedata" }
    local Connector = schema("Connector", OBJ({
        uuid = UUID(), kind = ENUM(KINDS), name = S(), label = S(), config = ANY("base_url?, email (EPC), …"),
        has_secret = BOOL("The key is never returned"), enabled = BOOL(), sync_enabled = BOOL("Daily sync by the deal scout"),
        stub = BOOL("Paid feed without an adapter yet: use CSV import"), last_run_at = DT(), last_error = S(),
        records_count = INT(), created_at = DT(), updated_at = DT(),
    }, { "uuid", "kind", "name", "has_secret" }))
    local ConnectorWrite = schema("ConnectorWrite", OBJ({ kind = ENUM(KINDS), name = S(), config = ANY(),
        secret = S("API key; \"\" clears it"), enabled = BOOL(), sync_enabled = BOOL() }, nil, "kind and name required on create"))
    local MarketRecord = schema("MarketRecord", OBJ({
        uuid = UUID(), connector_uuid = UUID(), source = S(), record_type = ENUM({ "sold_price", "epc", "listing", "auction_lot", "other" }),
        external_id = S(), address = S(), postcode = S(), lat = NUM(), lng = NUM(), property_type = S(), tenure = S(),
        bedrooms = INT(), price = MONEY(), previous_price = MONEY(), event_date = DATE(), epc_rating = S(), status = S(),
        cash_only = BOOL(), url = S(), data = ANY(), first_seen_at = DT(), fetched_at = DT(),
    }, { "uuid", "source", "record_type", "external_id" }))
    local Breakdown = OBJ({ weight = NUM(), fit = NUM("0–1"), points = NUM(), why = S() })
    local MatchRow = schema("MatchWithBreakdown", OBJ({
        uuid = UUID(), property_uuid = UUID(), buyer_profile_uuid = UUID(), score = NUM("0–100; 0 when a deal-breaker hits"),
        breakdown = OBJ({ budget = Breakdown, area = Breakdown, strategy = Breakdown, yield = Breakdown, condition = Breakdown,
            deal_breakers = ARR(S()) }),
        status = ENUM({ "suggested", "sent", "interested", "declined" }), sent_at = DT(), computed_at = DT(),
        buyer_name = S(), address_line1 = S(), postcode = S(), town = S(),
    }, { "uuid", "score", "breakdown" }))
    local ScoutAlert = schema("ScoutAlert", OBJ({
        uuid = UUID(), saved_search_uuid = UUID(), saved_search_name = S(), kind = ENUM({ "new", "reduced", "stale", "cash_only" }),
        detail = S(), price = MONEY(), previous_price = MONEY(), seen_at = DT(), created_at = DT(), market_record_uuid = UUID(),
        record_type = S(), address = S(), postcode = S(), lat = NUM(), lng = NUM(), url = S(), property_type = S(),
        bedrooms = INT(), cash_only = BOOL(),
    }, { "uuid", "kind" }))
    local CompanyCheck = schema("CompanyCheck", OBJ({
        company_number = S(), name = S(), status = S(), type = S(), created_on = DATE(), sic_codes = ARR(S()),
        registered_office = ANY(), officers = ARR(OBJ({ name = S(), role = S(), appointed_on = DATE() })),
        flags = ARR(S("e.g. insolvency history, accounts overdue")), checked_at = DT(),
    }, { "company_number", "flags" }))
    local cid = { id = UUID("Connector uuid") }

    sdk.doc(app, "GET /connectors", { summary = "Data connectors", permission = "property_deals_settings.read",
        response = ARR(Connector) })
    sdk.doc(app, "POST /connectors", { summary = "Add a data connector", permission = "property_deals_settings.update",
        body = ConnectorWrite, response = Connector, errors = E422 })
    sdk.doc(app, "GET /connectors/:id", { summary = "A data connector", permission = "property_deals_settings.read",
        path = cid, response = Connector, errors = E404 })
    sdk.doc(app, "PUT /connectors/:id", { summary = "Update a data connector", permission = "property_deals_settings.update",
        status = 200, path = cid, body = ConnectorWrite, response = Connector, errors = E422 })
    sdk.doc(app, "DELETE /connectors/:id", { summary = "Remove a data connector", permission = "property_deals_settings.update",
        path = cid, response = OBJ({ deleted = BOOL() }), errors = E404 })
    sdk.doc(app, "POST /connectors/:id/run", { summary = "Fetch from a connector now", permission = "property_deals_settings.update",
        status = 200, path = cid, body = OBJ({ postcode = S() }), response = OBJ({ fetched = INT(), stored = INT() }),
        errors = { ["404"] = "Not found", ["501"] = "Stub connector (no adapter yet)", ["502"] = "Source failed (also last_error)" } })
    sdk.doc(app, "GET /market-records", { summary = "Market data (sold prices, EPCs, listings, auction lots)",
        permission = "property_deals_properties.read", response = ARR(MarketRecord),
        query = { record_type = ENUM({ "sold_price", "epc", "listing", "auction_lot", "other" }), postcode = S(), per_page = INT("1–200") } })
    sdk.doc(app, "POST /market-records/import", { summary = "Import market data from CSV", status = 200,
        permission = "property_deals_properties.create",
        description = "Header row; columns used: external_id|id|lot|url, address, postcode, lat, lng, property_type, tenure, "
            .. "bedrooms, price, date, epc_rating, status, cash_only, url, guide_price, notes. Missing lat/lng are geocoded.",
        body = OBJ({ record_type = ENUM({ "sold_price", "epc", "listing", "auction_lot", "other" }), csv = S(), source = S() },
            { "record_type", "csv" }),
        response = OBJ({ rows = INT(), stored = INT(), skipped = INT() }), errors = { ["413"] = "Over 5 MB", ["422"] = E422["422"] } })
    sdk.doc(app, "POST /properties/:id/enrich", { summary = "EPC register + sold prices for a property", status = 200,
        permission = "property_deals_properties.update", path = { id = UUID() },
        response = OBJ({ epc = OBJ({ rating = S(), certificate_number = S(), expires_on = DATE(), address = S() }),
            epc_error = S(), sold_prices = INT(), property = ANY("Property"), comps = ANY("Comparables") }),
        errors = { ["404"] = "Not found", ["422"] = "No postcode" } })
    sdk.doc(app, "GET /companies/search", { summary = "Companies House search", permission = "property_deals_buyers.read",
        query = { q = S("Name or number") }, errors = { ["422"] = "No Companies House connector, or q too short" },
        response = ARR(OBJ({ company_number = S(), title = S(), company_status = S(), date_of_creation = DATE(), address = S() })) })
    sdk.doc(app, "POST /buyer-profiles/:id/company-check", { summary = "Companies House check for a company buyer", status = 200,
        permission = "property_deals_buyers.update", path = { id = UUID() }, body = OBJ({ company_number = S() }),
        response = CompanyCheck, errors = { ["404"] = "Not found", ["422"] = "No number / connector" } })
    sdk.doc(app, "POST /saved-searches/:id/run", { summary = "Run a saved search now", status = 200,
        permission = "property_deals_properties.read", path = { id = UUID() },
        response = OBJ({ new = INT(), reduced = INT(), stale = INT(), cash_only = INT() }), errors = E404 })
    sdk.doc(app, "GET /scout-alerts", { summary = "Deal scout alerts", permission = "property_deals_properties.read",
        response = ARR(ScoutAlert), query = { saved_search_uuid = UUID(), unseen = ENUM({ "true" }) } })
    sdk.doc(app, "POST /scout-alerts/seen", { summary = "Mark alerts seen (all, or the uuids given)", status = 200,
        permission = "property_deals_properties.read", body = OBJ({ uuids = ARR(UUID()) }), response = OBJ({ updated = INT() }) })
    sdk.doc(app, "POST /matches/recompute", { summary = "Re-score matches", status = 200, permission = "property_deals_buyers.update",
        body = OBJ({ property_uuid = UUID(), buyer_profile_uuid = UUID() }, nil, "Neither: the whole workspace"),
        response = OBJ({ scored = INT() }) })
    sdk.doc(app, "GET /properties/:id/matches", { summary = "Buyers matching a property, best first",
        permission = "property_deals_buyers.read", path = { id = UUID() }, response = ARR(MatchRow) })
    sdk.doc(app, "GET /buyer-profiles/:id/matches", { summary = "Properties matching a buyer, best first",
        permission = "property_deals_buyers.read", path = { id = UUID() }, response = ARR(MatchRow) })
    sdk.doc(app, "POST /matches/:id/send", { summary = "Send the deal pack to the buyer (creates an approval)",
        permission = "property_deals_buyers.update", path = { id = UUID() }, body = OBJ({ subject = S(), body = S() }),
        response = Approval, errors = { ["404"] = "Not found", ["409"] = "Hits the buyer's deal-breakers" } })
    sdk.doc(app, "POST /suppliers/nearest", { summary = "Book nearest: suppliers of a kind, nearest first", status = 200,
        permission = "property_deals_suppliers.read",
        body = OBJ({ kind = S("e.g. epc_assessor"), task_uuid = UUID(), property_uuid = UUID(), lat = NUM(), lng = NUM(),
            limit = INT("1–10") }, { "kind" }),
        response = ARR(OBJ({ supplier_uuid = UUID(), name = S(), distance_miles = NUM(), radius_miles = NUM(),
            avg_turnaround_hours = NUM(), on_time_pct = NUM(), rating = NUM(), booking_method = S() })), errors = E422 })

    -- ------------------------------------------------------------------ reports + export (Phase 7)
    local win = { from = DATE("Default: 90 days before `to`"), to = DATE("Exclusive; default tomorrow") }
    local function report(path, summary, response)
        sdk.doc(app, "GET /reports/" .. path, { summary = summary, permission = "property_deals_reports.read", query = win,
            response = response })
    end
    report("stage-times", "Time per stage", OBJ({
        completed_stages = ARR(OBJ({ stage_key = S(), deals = INT(), avg_days = NUM(), median_days = NUM(), max_days = NUM() })),
        current = ARR(OBJ({ stage_key = S(), deals = INT(), avg_days_so_far = NUM() })) }))
    report("late-days", "Completed deals vs their target date", OBJ({ completed = INT(), with_target = INT(), on_time = INT(),
        late = INT(), total_days_late = INT(), avg_days_late = NUM(), on_time_pct = NUM(), penalty_cost = MONEY(),
        worst = ARR(OBJ({ uuid = UUID(), name = S(), target = DATE(), actual = DATE(), days_late = INT() })) }))
    report("conversion", "Leads → deals → exchanged → completed", OBJ({
        totals = OBJ({ leads = INT(), deals = INT(), completed = INT(), lead_to_deal_pct = NUM(), deal_to_completion_pct = NUM() }),
        by_month = ARR(OBJ({ month = S("YYYY-MM"), leads = INT(), deals = INT(), exchanged = INT(), completed = INT(),
            fell_through = INT() })),
        by_source = ARR(OBJ({ source = S(), leads = INT(), deals = INT(), completed = INT() })) }))
    report("supplier-speed", "Supplier speed and reliability", ARR(OBJ({ supplier_uuid = UUID(), name = S(), kinds = ARR(S()),
        bookings = INT(), avg_hours_to_confirm = NUM(), avg_hours_to_done = NUM(), measured = INT(), on_time_pct = NUM(),
        cancelled = INT() })))
    report("party-speed", "Solicitor / lender / council speed", OBJ({
        chases = ARR(OBJ({ to_party = S(), chases = INT(), replied = INT(), avg_hours_to_reply = NUM(), median_hours_to_reply = NUM() })),
        enquiries = ARR(OBJ({ owner_party = S(), raised = INT(), resolved = INT(), still_open = INT(), avg_days_to_resolve = NUM() })) }))
    report("ai-usage", "AI spend, runs and approval outcomes", OBJ({ total_cost_usd = NUM(),
        daily = ARR(OBJ({ day = DATE(), agent_key = S(), runs = INT(), failed = INT(), cost_usd = NUM(), tokens = INT() })),
        approval_outcomes = ARR(OBJ({ agent_key = S(), drafts = INT(), approved = INT(), rejected = INT(), edited = INT(),
            failed_to_run = INT(), pending = INT() })) }))
    sdk.doc(app, "GET /export/:entity", { summary = "Export a workspace's data (CSV or JSON)", permission = "property_deals_reports.manage",
        path = { entity = ENUM({ "deals", "tasks", "properties", "buyer_profiles", "suppliers", "bookings", "enquiries", "chases",
            "compliance_checks", "documents", "approvals", "agent_runs", "matches", "market_records", "stage_history" }) },
        query = { format = ENUM({ "csv", "json" }), from = DATE("created on/after"), to = DATE("created before") },
        description = "At most 50,000 rows (header X-Truncated when cut). CSV cells that start with = + - @ are prefixed with ' "
            .. "so spreadsheets don't run them.", response = ARR(ANY("A row")), errors = { ["404"] = "Unknown export" } })

    sdk.doc(app, "GET /buyer-profiles/directory", { summary = "Buyers with names (Buyers page)", permission = "property_deals_buyers.read",
        query = { q = S("Name or email"), pof_status = S() },
        response = ARR(OBJ({ uuid = UUID(), name = S(), email = S(), contact_uuid = S(), account_uuid = S(), entity_type = S(),
            pof_status = S(), pof_expires_on = DATE(), funding_route = S(), price_min = MONEY(), price_max = MONEY(),
            strategies = ANY(), areas = ANY(), deal_breakers = ANY(), min_yield_pct = NUM(), min_discount_pct = NUM(),
            refurb_appetite = S(), company_number = S(), company_check = ANY(), active = BOOL(), updated_at = DT() }, { "uuid" })) })
end
