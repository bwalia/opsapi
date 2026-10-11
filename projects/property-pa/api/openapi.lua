-- OpenAPI description of the Property PA routes (served in /openapi.json and /swagger). Responses use the house
-- envelope { success, data, meta? }; null fields are left out of the JSON.
local sdk = require("helper.plugin-sdk")

local function t(type_, extra)
    local s = { type = type_ }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end
local S = function(d) return t("string", d and { description = d }) end
local UUID = function(d) return t("string", { format = "uuid", description = d }) end
local DT = function(d) return t("string", { format = "date-time", description = d }) end
local INT = function(d) return t("integer", d and { description = d }) end
local NUM = function(d) return t("number", d and { description = d }) end
local BOOL = function(d) return t("boolean", d and { description = d }) end
local function ENUM(values, d) return t("string", { enum = values, description = d }) end
local function ARR(items, d) return t("array", { items = items, description = d }) end
local function OBJ(props, required, d)
    if next(props) == nil then return t("object", { additionalProperties = true, description = d }) end
    return t("object", { properties = props, required = required, description = d })
end
local ANY = function(d) return { description = d or "Any JSON value" } end

return function(app)
    local function schema(name, s) return sdk.schema(app, name, s) end
    local E404 = { ["404"] = "Not found in this workspace" }
    local E422 = { ["422"] = "Validation failed (details: field -> message)" }
    local id = { id = UUID() }

    local Fact = schema("Fact", OBJ({ value = ANY(), is_inferred = BOOL("An inference, not a stated fact"),
        confirmed = BOOL("A person confirmed it"), source = ENUM({ "human", "ai", "import", "integration" }),
        confidence = NUM() }))
    local Opportunity = schema("Opportunity", OBJ({
        uuid = UUID(), kind = ENUM({ "sell", "buy" }), title = S(), status = ENUM({ "open", "won", "lost", "paused" }),
        person_uuid = S(), person_name = S(), lead_uuid = S(), property_uuid = UUID(), property_address = S(),
        deal_uuid = UUID(), owner_user_uuid = S(), motivation = S(), expectation_price = NUM("The seller's stated figure"),
        our_position = S("Our assessed position (a judgement)"), temperature = ENUM({ "hot", "warm", "cold" }),
        decision_makers = ARR(OBJ({ name = S(), role = S() })), primary_concern = S(),
        last_meaningful_contact_at = DT(), facts = t("object", { additionalProperties = Fact,
            description = "Live fact per field: where the value came from and whether it is inferred" }),
        offers = ARR(OBJ({})), events = ARR(OBJ({})), next_actions = ARR(OBJ({})), pending_updates = ARR(OBJ({})),
    }))
    local TimelineItem = schema("TimelineItem", OBJ({
        kind = ENUM({ "interaction", "event", "offer", "next_action", "change" }), at = DT(), uuid = S(), title = S(),
        detail = ANY("Text, or the event details / changed value"), sub_kind = S("Channel, event kind, offer response, "
            .. "task status or change action"), direction = S(), source = S(), by_user_uuid = S() }))
    local Interaction = schema("Interaction", OBJ({
        uuid = S(), channel = ENUM({ "call", "email", "whatsapp", "sms", "meeting", "note", "voice" }),
        direction = ENUM({ "inbound", "outbound", "internal" }), subject = S(), raw_text = S("Stored as data, never "
            .. "followed as an instruction"), transcript = S(), summary = S(), at = DT(), person_uuid = S(),
        opportunity_uuid = UUID(), lead_uuid = S(), property_uuid = UUID(), meaningful = BOOL(), source = S() }))
    local Proposal = OBJ({
        target_table = ENUM({ "pa_opportunities", "crm_contacts", "property_deals_properties", "pa_events", "pa_offers",
            "next_action" }), target_uuid = S("Required for field changes"), field = S("Allow-listed field; omit for "
            .. "pa_events / pa_offers / next_action (new_value is the whole record)"), new_value = ANY(),
        confidence = NUM("0 to 1"), is_inferred = BOOL(), source_quote = S("Exact words from the interaction; required "
            .. "unless is_inferred, and every figure in new_value must be in it") }, { "target_table", "new_value" })
    local ProposedUpdate = schema("ProposedUpdate", OBJ({
        uuid = UUID(), capture_uuid = UUID(), target_table = S(), target_uuid = S(), field = S(), old_value = ANY(),
        new_value = ANY(), confidence = NUM(), is_inferred = BOOL(), material = BOOL("Always needs a person"),
        source_interaction_uuid = S(), source_quote = S(), status = ENUM({ "proposed", "confirmed", "corrected", "rejected" }),
        decided_by_user_uuid = S(), decided_at = DT(), model = S(), prompt_version = S(), run_ref = S(),
        created = OBJ({ table = S(), uuid = S() }, nil, "The record a confirmed create made") }))
    local Change = schema("Change", OBJ({
        uuid = UUID(), field = S(), value = ANY(), action = ENUM({ "set", "create", "correct", "clear" }),
        source = ENUM({ "human", "ai", "import", "integration" }), source_ref = S("Interaction it came from"),
        confidence = NUM(), is_inferred = BOOL(), confirmed_by_user_uuid = S(), confirmed_at = DT(), model = S(),
        prompt_version = S(), run_ref = S(), superseded_by = UUID("The value that replaced this one"), created_at = DT() }))
    local Knowledge = schema("Knowledge", OBJ({
        uuid = UUID(), key = S(), domain = S(), scope = ENUM({ "personal", "team", "company" }),
        status = ENUM({ "draft", "approved", "retired" }), current_version = INT(), title = S(), rule = S(),
        rationale = S(), triggers = ARR(S()), approved_by_user_uuid = S(), approved_at = DT(),
        versions = ARR(OBJ({ version = INT(), title = S(), rule = S(), status = ENUM({ "proposed", "approved",
            "rejected", "superseded" }), proposed_by_user_uuid = S(), proposed_by_ai = BOOL(),
            approved_by_user_uuid = S(), approved_at = DT() })) }))
    local Verdict = schema("GroundingVerdict", OBJ({ ok = BOOL(), violations = ARR(OBJ({
        kind = ENUM({ "no_source", "unknown_ref", "empty_field", "unsupported_figure", "unlabelled_inference",
            "uncited_figure" }), claim = INT(), ref = S(), figure = NUM(), message = S() })) }))
    local Run = schema("Run", OBJ({
        uuid = UUID(), agent_key = ENUM({ "pa_seller_agent", "pa_manager" }),
        status = ENUM({ "running", "succeeded", "failed" }), model = S(), prompt_version = S(),
        input_snapshot = OBJ({ mode = S(), role = S(), message = S(), opportunity_uuid = UUID() }),
        output = OBJ({ grounded = BOOL(), contract_ok = BOOL(), mode = S(), answer = S("Shown only when grounded"),
            withheld = S("Why the answer isn't shown"), violations = ARR(OBJ({})), sources = ARR(OBJ({})),
            unknowns = ARR(S()), inferences = ARR(S()), actions = ARR(OBJ({})), needs_human = BOOL() }),
        error = S(), jobshout_task_id = S(), jobshout_run_id = S(), started_at = DT(), finished_at = DT() }))

    local function doc(route, d) sdk.doc(app, route, d) end
    doc("POST /setup", { summary = "Set the workspace up for the PA", permission = "property_pa_knowledge.manage",
        description = "Idempotent: Property Deals setup, PA permissions on the PD roles, the first seller playbook.",
        response = OBJ({ roles_updated = ARR(S()), knowledge_added = INT() }) })
    doc("GET /opportunities", { summary = "Opportunities", permission = "property_pa_records.read", paginated = true,
        query = { status = S(), kind = ENUM({ "sell", "buy" }), mine = BOOL() }, response = ARR(Opportunity) })
    doc("POST /opportunities", { summary = "Create an opportunity", permission = "property_pa_records.create",
        status = 201, body = Opportunity, response = Opportunity, errors = E422 })
    doc("GET /opportunities/:id", { summary = "An opportunity with its facts, offers, events and next actions",
        permission = "property_pa_records.read", path = id, response = Opportunity, errors = E404 })
    doc("PUT /opportunities/:id", { summary = "Edit fields (every value kept in the history)",
        permission = "property_pa_records.update", path = id, body = Opportunity, response = Opportunity, errors = E422 })
    doc("GET /opportunities/:id/timeline", { summary = "Interactions, events, offers, next actions and changes",
        permission = "property_pa_records.read", path = id, query = { limit = INT("max 300") }, response = ARR(TimelineItem) })
    doc("GET /people", { summary = "Find people by name, email, phone or property address",
        permission = "property_pa_records.read", query = { q = S("At least 2 characters") }, response = ARR(OBJ({})) })
    doc("GET /people/:id", { summary = "A person: roles, relationship, opportunities", permission = "property_pa_records.read",
        path = { id = S("Contact uuid") }, response = OBJ({}), errors = E404 })
    doc("GET /people/:id/timeline", { summary = "A person's timeline", permission = "property_pa_records.read",
        path = { id = S("Contact uuid") }, response = ARR(TimelineItem) })
    doc("POST /interactions", { summary = "Log a call, email, note or voice note", permission = "property_pa_records.create",
        status = 201, body = Interaction, response = Interaction, errors = E422 })
    doc("GET /interactions/:id", { summary = "An interaction", permission = "property_pa_records.read",
        path = { id = S() }, response = Interaction, errors = E404 })
    doc("POST /events", { summary = "Record an event (valuation, promise, deadline...)", permission = "property_pa_records.create",
        status = 201, body = OBJ({}), response = OBJ({}) })
    doc("POST /offers", { summary = "Record an offer (the caller is the authority)", permission = "property_pa_records.create",
        status = 201, body = OBJ({ amount = NUM(), opportunity_uuid = UUID(), deal_uuid = UUID(), conditions = S() }),
        response = OBJ({}) })
    doc("PUT /offers/:id", { summary = "Record the response to an offer", permission = "property_pa_records.update",
        path = id, body = OBJ({ response = ENUM({ "pending", "accepted", "rejected", "countered", "withdrawn" }),
            response_note = S() }), response = OBJ({}) })
    doc("POST /next-actions", { summary = "Create a next action (owner, due time, reason)",
        permission = "property_pa_records.create", status = 201, body = OBJ({ title = S(), due_at = DT(), reason = S(),
            opportunity_uuid = UUID(), owner_user_uuid = S() }, { "title", "due_at", "reason" }), response = OBJ({}) })
    doc("GET /next-actions", { summary = "Open next actions", permission = "property_pa_records.read",
        query = { opportunity_uuid = UUID(), mine = BOOL() }, response = ARR(OBJ({})) })
    doc("GET /history/:table/:id", { summary = "Every value a record's fields ever had (P10, P11)",
        permission = "property_pa_records.read", path = { table = S(), id = S() }, query = { field = S() },
        response = ARR(Change) })

    doc("POST /captures", { summary = "Log an interaction and propose changes from it (nothing is applied)",
        permission = "property_pa_updates.create", status = 201,
        body = OBJ({ interaction = Interaction, interaction_uuid = S("Or an interaction already logged"),
            proposals = ARR(Proposal), model = S(), prompt_version = S(), run_ref = S() }, { "proposals" }),
        response = OBJ({ capture_uuid = UUID(), interaction = Interaction, proposed_updates = ARR(ProposedUpdate) }),
        errors = { ["422"] = "Validation failed, or a proposal isn't grounded in the interaction" } })
    local SheetRow = schema("SheetRow", OBJ({ uuid = UUID(), target_table = S(), target_uuid = S(), field = S(),
        label = S("How the field reads on the sheet"), kind = ENUM({ "stated", "inferred", "proposed" }),
        kind_label = S("e.g. SOPHIE'S JUDGEMENT, UNCONFIRMED"), old_value = ANY(), new_value = ANY(), confidence = NUM(),
        is_inferred = BOOL(), material = BOOL(), source_quote = S(), status = ENUM({ "proposed", "confirmed", "corrected",
            "rejected" }), owner = OBJ({ user_uuid = S(), name = S() }, nil, "Next actions: who will own it") }))
    local Sheet = schema("CaptureSheet", OBJ({ interaction = Interaction, author = S("First name, for own notes"),
        run = OBJ({ uuid = UUID(), status = S(), model = S(), prompt_version = S(), error = S() }),
        proposals = ARR(SheetRow), counts = OBJ({ proposed = INT(), confirmed = INT(), corrected = INT(), rejected = INT(),
            material = INT("Material rows still waiting") }) }))
    doc("POST /captures/start", { summary = "Capture a voice note (its transcript) or a typed note; the PA proposes",
        permission = "property_pa_records.create", status = 201,
        body = OBJ({ text = S(), channel = ENUM({ "voice", "note", "call", "meeting", "email", "whatsapp", "sms" }),
            opportunity_uuid = UUID(), person_uuid = S(), audio_document_uuid = UUID() }, { "text" }),
        response = OBJ({ interaction = Interaction, pa = OBJ({ run_uuid = UUID(), status = S(),
            error = S("Why the PA wasn't asked (the note is saved anyway)") }) }) })
    doc("GET /interactions/:id/capture", { summary = "The confirm sheet for a note", permission = "property_pa_updates.read",
        path = { id = S() }, response = Sheet, errors = E404 })
    doc("POST /interactions/:id/decide", { summary = "Confirm / correct / reject rows; confirm_rest confirms the rest",
        permission = "property_pa_updates.update", path = { id = S() },
        body = OBJ({ decisions = ARR(OBJ({ uuid = UUID(), action = ENUM({ "confirm", "correct", "reject" }),
            value = ANY("For correct") }, { "uuid", "action" })), confirm_rest = BOOL() }),
        response = OBJ({ results = ARR(OBJ({ uuid = UUID(), action = S(), ok = BOOL(), status = S(), error = S() })),
            sheet = Sheet }), errors = E422 })
    doc("GET /proposed-updates", { summary = "Proposed updates", permission = "property_pa_updates.read",
        query = { status = S("Comma separated"), capture_uuid = UUID(), target_uuid = S() }, response = ARR(ProposedUpdate) })
    doc("GET /proposed-updates/:id", { summary = "A proposed update", permission = "property_pa_updates.read", path = id,
        response = ProposedUpdate, errors = E404 })
    for _, a in ipairs({ "confirm", "reject" }) do
        doc("POST /proposed-updates/:id/" .. a, { summary = a:sub(1, 1):upper() .. a:sub(2) .. " a proposed update",
            permission = "property_pa_updates.update", path = id, response = ProposedUpdate,
            errors = { ["404"] = "Not found", ["409"] = "Already decided" } })
    end
    doc("POST /proposed-updates/:id/correct", { summary = "Apply the person's value instead (the AI's stays in the history)",
        permission = "property_pa_updates.update", path = id, body = OBJ({ value = ANY() }, { "value" }),
        response = ProposedUpdate, errors = { ["409"] = "Already decided", ["422"] = "Value not valid for the field" } })

    doc("GET /knowledge", { summary = "Approved rules I may use", permission = "property_pa_knowledge.read",
        query = { domain = S(), trigger = S(), q = S(), status = S("all = include drafts and retired") },
        response = ARR(Knowledge) })
    doc("GET /knowledge/pending", { summary = "Proposed versions waiting for my decision",
        permission = "property_pa_knowledge.read", response = ARR(OBJ({})) })
    doc("GET /knowledge/:id", { summary = "A rule and all its versions", permission = "property_pa_knowledge.read",
        path = id, response = Knowledge, errors = E404 })
    doc("POST /knowledge", { summary = "Propose a rule or a new version", permission = "property_pa_knowledge.create",
        status = 201, body = OBJ({ key = S("snake_case"), scope = ENUM({ "personal", "team", "company" }), domain = S(),
            title = S(), rule = S(), rationale = S(), triggers = ARR(S()), proposed_by_ai = BOOL() },
            { "key", "title", "rule" }), response = OBJ({ knowledge_uuid = UUID(), version = INT(), status = S() }),
        errors = E422 })
    for _, a in ipairs({ "approve", "reject" }) do
        doc("POST /knowledge/:id/versions/:version/" .. a, { summary = a:sub(1, 1):upper() .. a:sub(2) .. " a version "
            .. "(company/team: managers; personal: the owner)", permission = "property_pa_knowledge.read",
            path = { id = UUID(), version = INT() }, response = Knowledge,
            errors = { ["403"] = "Not a manager", ["409"] = "Already decided" } })
    end
    doc("POST /knowledge/:id/retire", { summary = "Retire a rule (history kept)", permission = "property_pa_knowledge.read",
        path = id, response = Knowledge })

    local Signal = OBJ({ key = S(), weight = INT(), text = S(), ref = S("The record it came from") })
    local Card = schema("TodayCard", OBJ({ rank = INT(), score = INT("Sum of the signal weights"), opportunity_uuid = UUID(),
        title = S(), kind = S(), person_name = S(), property_address = S(), why_now = S(), action = S("Recommended action"),
        objective = S(), minutes = INT(), signals = ARR(Signal), next_action = OBJ({ task_uuid = S(), title = S(), due_at = DT() }) }))
    local Line = OBJ({ text = S(), ref = S(), label = S("stated / judgement, unconfirmed / inference"), is_inferred = BOOL() })
    local Rule = OBJ({ key = S(), version = INT(), scope = S(), title = S(), rule = S(), ref = S() })
    doc("GET /today", { summary = "My opportunities ranked by explainable rules (P01)", permission = "property_pa_records.read",
        query = { minutes = INT("Time budget, 5-600: which cards fit and what waits") },
        response = OBJ({ cards = ARR(Card), weights = OBJ({}), budget = OBJ({ minutes = INT(), used = INT(),
            fits = ARR(Card), waits = ARR(OBJ({})) }) }) })
    doc("GET /today/why/:opportunity_id", { summary = "Why it ranks where it does: signals, weights, sources (P07)",
        permission = "property_pa_records.read", path = { opportunity_id = UUID() },
        response = OBJ({ rank = INT(), of = INT(), score = INT(), signals = ARR(Signal), weights = OBJ({}), action = S(),
            objective = S(), explanation = S() }), errors = E404 })
    doc("GET /prepare/:opportunity_id", { summary = "Prepare Me: a brief where every line cites its record (P02)",
        permission = "property_pa_records.read", path = { opportunity_id = UUID() },
        response = schema("PrepareBrief", OBJ({ opportunity_uuid = UUID(), title = S(), person_name = S(),
            snapshot = ARR(Line), last_interaction = OBJ({ text = S(), at = DT(), channel = S(), ref = S() }),
            price = ARR(Line), decision_makers = ARR(Line), promises = ARR(Line), objections = ARR(Line),
            manager_replies = ARR(Line), unknowns = ARR(S()), questions = ARR(OBJ({ field = S(), question = S() })),
            triggers = ARR(S()),
            playbook = ARR(Rule), objective = S(), recommended_action = S(), why_now = ARR(Signal) })), errors = E404 })
    doc("GET /coach/:opportunity_id", { summary = "Coach: known vs assumed, questions before any figure, the rules (P06)",
        permission = "property_pa_records.read", path = { opportunity_id = UUID() }, query = { situation = S() },
        response = OBJ({ known = ARR(Line), assumed = ARR(Line), questions = ARR(S()), playbook = ARR(Rule),
            next_step = S(), never = S() }), errors = E404 })
    doc("POST /knowledge/teach", { summary = "Teach the PA a rule (managers can approve it in the same step)",
        permission = "property_pa_knowledge.create", status = 201, body = OBJ({ statement = S(), title = S(), key = S(),
            scope = ENUM({ "personal", "team", "company" }), domain = S(), rationale = S(), triggers = ARR(S()),
            approve = BOOL() }, { "statement" }), response = Knowledge,
        errors = { ["403"] = "Only managers approve company or team rules" } })
    local Item = OBJ({ opportunity_uuid = UUID(), title = S(), owner_user_uuid = S(), text = S(), ref = S() })
    doc("GET /manager/today", { summary = "Manager Today: exceptions only (scene 10, P08)", permission = "property_pa_handoffs.read",
        description = "Managers only (property_pa_knowledge.manage).",
        response = schema("ManagerToday", OBJ({ handoffs = ARR(OBJ({ uuid = UUID(), question = S(), pa_recommendation = S(),
            context = OBJ({}), opportunity_uuid = UUID(), opportunity_title = S(), from_name = S(), created_at = DT(), ref = S() })),
            unusual_negotiations = ARR(Item), relationship_risks = ARR(OBJ({ uuid = UUID(), title = S(), days = INT(),
                temperature = S(), owner_name = S(), text = S(), ref = S() })), overdue_actions = ARR(OBJ({})),
            deal_risks = ARR(OBJ({})), top_opportunities = ARR(OBJ({ opportunity_uuid = UUID(), title = S(), score = INT(),
                why_now = S(), ref = S() })), open_opportunities = INT(), handled = INT(), summary = S() })),
        errors = { ["403"] = "For managers" } })
    doc("GET /metrics", { summary = "Is the PA working? Capture accuracy, groundedness, speed, follow-through",
        permission = "property_pa_records.read", query = { days = INT("1-365, default 30") },
        response = schema("Metrics", OBJ({ days = INT(), capture = OBJ({ captures = INT(), proposals = INT(), waiting = INT(),
            confirmed = INT(), corrected = INT(), rejected = INT(), accepted_as_proposed = NUM(), correction_rate = NUM(),
            rejection_rate = NUM(), median_seconds_to_confirm = INT() }), answers = OBJ({ runs = INT(), succeeded = INT(),
            failed = INT(), grounded = INT(), withheld = INT(), grounded_rate = NUM(), p50_seconds = INT(), p90_seconds = INT() }),
            follow_through = OBJ({ next_actions_open = INT(), next_actions_overdue = INT(), next_actions_done = INT(),
                opportunities_gone_quiet = INT() }), handoffs = OBJ({ total = INT(), waiting = INT(),
                median_seconds_to_reply = INT() }) })), errors = { ["403"] = "For managers" } })
    doc("POST /integrations/mail/import", { summary = "Inbound email (Outlook / Gmail / IMAP) onto timelines, once each",
        permission = "property_pa_records.create", response = OBJ({ imported = INT(), considered = INT() }) })
    doc("POST /integrations/ghl/sync", { summary = "Pull GoHighLevel contacts (read only; also hourly)",
        permission = "property_pa_knowledge.manage", response = OBJ({ created = INT(), updated = INT(), unchanged = INT(),
            pages = INT() }), errors = { ["409"] = "GHL not set up", ["502"] = "GHL unreachable or refused" } })
    doc("POST /runs/sweep", { summary = "Poll PA runs without a webhook; fail ones past the timeout",
        permission = "property_pa_knowledge.manage", response = OBJ({ polled = INT(), finished = INT(), timed_out = INT() }) })
    doc("GET /status", { summary = "Go-live checklist", permission = "property_pa_records.read",
        response = OBJ({ ready = BOOL(), checks = ARR(OBJ({ key = S(), ok = BOOL(), text = S(), fix = S(), optional = BOOL() })),
            limits = OBJ({ running_per_person = INT(), per_person_per_hour = INT(), run_timeout_minutes = INT() }) }) })
    doc("GET /briefing", { summary = "My day for the PA", permission = "property_pa_records.read", response = OBJ({}) })
    doc("GET /context/:opportunity_id", { summary = "Every fact the PA may use about an opportunity, each with a ref",
        permission = "property_pa_records.read", path = { opportunity_id = UUID() }, response = OBJ({}), errors = E404 })
    doc("POST /grounding/check", { summary = "Check an answer's figures against the refs it cites (P05)",
        permission = "property_pa_records.read", body = OBJ({ text = S(), claims = ARR(OBJ({ text = S(),
            refs = ARR(S("table:uuid or table:uuid:field")) })) }, { "text" }), response = Verdict })
    doc("GET /audit", { summary = "AI change history: source, model, prompt version, run, approver (P10)",
        permission = "property_pa_records.read", paginated = true,
        query = { target_table = S(), target_uuid = S(), since = DT() }, response = ARR(Change) })
    doc("POST /handoffs", { summary = "Ask a manager (context, question, recommendation)",
        permission = "property_pa_handoffs.create", status = 201, body = OBJ({ to_user_uuid = S(), question = S(),
            opportunity_uuid = UUID(), context = OBJ({}), pa_recommendation = S() }, { "to_user_uuid", "question" }),
        response = OBJ({}) })
    doc("GET /handoffs", { summary = "My handoffs", permission = "property_pa_handoffs.read",
        query = { box = ENUM({ "inbox", "sent" }), status = ENUM({ "open", "replied", "closed" }) }, response = ARR(OBJ({})) })
    doc("POST /handoffs/:id/reply", { summary = "Reply; it goes back onto the deal", permission = "property_pa_handoffs.update",
        path = id, body = OBJ({ reply = S(), decision = S() }, { "reply" }), response = OBJ({}),
        errors = { ["404"] = "Not found or not asked of you", ["409"] = "Already replied" } })

    doc("POST /ask", { summary = "Talk to your PA (runs in JobShout; the answer is checked before it is shown)",
        permission = "property_pa_records.read", status = 202, body = OBJ({ message = S(), mode = ENUM({ "today",
            "prepare", "capture", "coach", "ask", "handoff", "manager_today", "teach" }), role = ENUM({ "seller_agent",
            "manager" }), opportunity_uuid = UUID(), inputs = OBJ({}) }, { "message" }), response = Run,
        errors = { ["403"] = "Manager PA for managers only", ["409"] = "The PA isn't connected", ["502"] = "JobShout unreachable" } })
    doc("GET /ask/:id", { summary = "My PA run: running, or the checked answer", permission = "property_pa_records.read",
        path = id, response = Run, errors = E404 })
    doc("POST /public/jobshout/events", { summary = "JobShout webhook (run.completed / run.failed)",
        description = "Signed: X-JobShout-Signature = sha256=HMAC(secret, X-JobShout-Timestamp + '.' + body).",
        body = OBJ({}), response = OBJ({}), errors = { ["401"] = "Bad or stale signature" } })
    doc("POST /demo/reset", { summary = "Reset the How It Works fixtures", permission = "property_pa_knowledge.manage",
        body = OBJ({ sophie_user_uuid = S(), ashley_user_uuid = S() }), response = OBJ({}) })
    doc("DELETE /demo", { summary = "Remove the fixtures", permission = "property_pa_knowledge.manage", response = OBJ({}) })
end
