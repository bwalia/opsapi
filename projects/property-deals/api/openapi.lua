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
        run_sources = ANY("Sources the agent used"), from_jobshout = BOOL(), can_decide = BOOL("Inbox only"),
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
        layer = ENUM({ "properties", "deals", "leads", "holdings" }), uuid = S(), lat = NUM(), lng = NUM(),
        title = S(), subtitle = S(), distance_miles = NUM("Radius queries"), tenure = S(), epc_rating = S(), bedrooms = INT(),
        est_market_value = MONEY(), deal_uuid = UUID(), deal_stage = S(), deal_health = ENUM(HEALTH), deal_name = S(),
        lead_kind = S(), situation = S(), deadline_date = DATE(), status = S(), property_uuid = UUID(),
    }, { "layer", "uuid", "lat", "lng" }))
    local MapResult = schema("MapResult", OBJ({
        center = OBJ({ lat = NUM(), lng = NUM() }), radius_miles = NUM(), polygon = ARR(ARR(NUM())),
        features = ARR(MapFeature), counts = OBJ({}, nil, "layer -> features"), truncated = BOOL("More than 2000"),
    }, { "features" }))
    local Card = schema("PropertyCard", OBJ({
        property = ANY("Property"), deal = DealCard, gross_yield_pct = NUM(), discount_pct = NUM("vs estimated value"),
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
    sdk.doc(app, "GET /setup", { summary = "Workspace setup state", permission = "property_deals_settings.read",
        response = Setup, description = "Missing (null) until POST /setup ran." })
    sdk.doc(app, "POST /setup", { summary = "Set up the workspace (idempotent)", permission = "property_deals_settings.manage",
        status = 200, response = OBJ({ state = Setup, created = OBJ({ roles = ARR(S()), templates = ARR(S()), holidays = INT() }) }) })
    sdk.doc(app, "POST /engine/run", { summary = "Run engine checks now", permission = "property_deals_settings.manage",
        status = 200, body = OBJ({ checks = ARR(ENUM({ "sla", "health", "compliance_expiry", "digest" })) }),
        response = OBJ({ sla = OBJ({ warned = INT(), overdue = INT(), escalated = INT() }), health = OBJ({ deals = INT() }),
                         compliance_expiry = OBJ({ expired = INT(), warned = INT(), pof_expired = INT() }),
                         digest = OBJ({ sent = INT() }) }), errors = E422 })

    sdk.doc(app, "GET /leads", { summary = "Leads with Property Deals fields", permission = "property_deals_deals.read",
        paginated = true, response = ARR(Lead), query = {
            lead_kind = S(), situation = S(), status = S(), source = S(), owner_user_uuid = S(),
            vulnerable = ENUM({ "true" }), deadline_before = DATE(), q = S("Name, email or phone"),
            sort = ENUM({ "created", "deadline" }) } })
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
            layers = S("Comma list: properties, deals, leads, holdings (default properties,deals)") } })
    sdk.doc(app, "GET /properties/:id/card", { summary = "Map property card", permission = "property_deals_properties.read",
        response = Card, path = { id = UUID() }, errors = E404 })

    sdk.doc(app, "GET /digest", { summary = "My digest for today (live)", permission = "property_deals_tasks.read", response = Digest })
    sdk.doc(app, "GET /digest/history", { summary = "Digests sent to me", permission = "property_deals_tasks.read",
        paginated = true, response = ARR(OBJ({ local_date = DATE(), payload = Digest, empty = BOOL(), created_at = DT() })) })
    sdk.doc(app, "POST /digest/send", { summary = "Send today's digests now", permission = "property_deals_settings.manage",
        status = 200, response = OBJ({ sent = INT() }) })
end
