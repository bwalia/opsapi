-- Sample history on top of the How It Works fixtures (POST /demo/reset { story = true }), so every screen has
-- something to show before a real model is connected: notes captured and confirmed / corrected / rejected, an
-- offer, handoffs (one answered, one waiting), PA answers (two shown, two withheld by the checks) and rules the
-- PA has learnt (approved, a new version, one it proposed itself, one a manager turned down).
--
-- It goes through the same code a real run uses (updates.propose / decide, bridge.finish and its grounding check,
-- knowledge.propose / decide), so what you see is what the product does. Only the model's words are written here:
-- every run and proposal is labelled model "sample-data", prompt "sample", so nobody mistakes it for a live answer.
-- docs/property-pa/06-sample-data.md walks through it.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")

local S = {}
S.MODEL, S.PROMPT = "sample-data", "sample"
S.TAG = "how_it_works"
S.REF = "fixture:" .. S.TAG -- source_ref on the facts the story writes directly
-- Rules this story adds; a reset removes exactly these (the seeded playbook is left alone).
S.KNOWLEDGE_KEYS = { "temperature_is_the_agents_call", "probate_valuation_timing", "helen_speak_to_jo",
    "competitor_fees" }

local function iso(days, hours)
    return U.one(string.format([[SELECT to_char((NOW() - INTERVAL '%d days %d hours') AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS t]], days, hours or 0)).t
end
local function ahead(days)
    return U.one(string.format([[SELECT to_char(date_trunc('day', NOW() + INTERVAL '%d days') + INTERVAL '10 hours',
        'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS t]], days)).t
end

--- Mark a story interaction as a fixture (a reset removes it with the fixtures).
local function tag_interaction(ns, uuid)
    db.query([[UPDATE crm_activities SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('fixture', ?::text)
        WHERE namespace_id = ? AND uuid = ?]], S.TAG, ns, uuid)
end

local function opp(ns, title_prefix)
    return U.one([[SELECT o.uuid, o.person_uuid, o.property_uuid FROM pa_opportunities o WHERE o.namespace_id = ?
        AND o.title LIKE ? AND o.metadata ->> 'fixture' = 'how_it_works']], ns, title_prefix .. "%")
end

--- A finished PA run, stored through bridge.finish (so the grounding and authority checks really run).
local function run(ns, user, mode, role, message, opp_uuid, out, days, hours, extra)
    local B = require("property_pa.bridge")
    local snap = { mode = mode, role = role, message = message, opportunity_uuid = opp_uuid, fixture = S.TAG }
    for k, v in pairs(extra or {}) do snap[k] = v end
    local r = db.insert("property_deals_agent_runs", {
        namespace_id = ns, agent_key = "pa_" .. role, provider = B.PROVIDER, model = S.MODEL, status = "running",
        trigger = "manual", input_snapshot = db.raw(db.escape_literal(cjson.encode(snap)) .. "::jsonb"),
        jobshout_task_id = "sample", jobshout_run_id = "sample", triggered_by_user_uuid = user,
        started_at = db.raw("NOW()"),
    }, { returning = { "uuid", "status", "input_snapshot" } })[1]
    out.contract = "property-pa.output.v1"
    out.mode = mode
    B.finish(ns, r, { status = "completed", model_name = S.MODEL, prompt_version = S.PROMPT,
        latency_ms = 9000 + #message * 40, total_tokens = 0,
        output = "Sample answer.\n```pa_output\n" .. cjson.encode(out) .. "\n```" })
    -- No model ran: keep the sample off the AI usage page and out of anyone's daily token limit.
    pcall(db.query, "DELETE FROM ai_usage WHERE namespace_id = ? AND run_uuid = ?", ns, r.uuid)
    db.query(string.format([[UPDATE property_deals_agent_runs SET created_at = NOW() - INTERVAL '%d days %d hours',
        started_at = NOW() - INTERVAL '%d days %d hours', finished_at = NOW() - INTERVAL '%d days %d hours'
        + make_interval(secs => latency_ms / 1000.0) WHERE uuid = ?::uuid]], days, hours, days, hours, days, hours), r.uuid)
    return U.one("SELECT uuid, output FROM property_deals_agent_runs WHERE uuid = ?::uuid", r.uuid)
end

--- A capture: the note on the timeline, the PA's run, its proposals, then the person's decisions.
-- decisions[i] = "confirm" | "reject" | { "correct", value } | nil (left waiting)
local function capture(ns, user, settings, o, note, days, hours, items, decisions, minutes_to_decide)
    local I, P = require("property_pa.interactions"), require("property_pa.updates")
    local it = I.log(ns, { channel = "voice", direction = "internal", subject = "Voice note: " .. note:sub(1, 80),
        transcript = note, raw_text = note, opportunity_uuid = o.uuid, at = iso(days, hours) }, user)
    tag_interaction(ns, it.uuid)
    local r = run(ns, user, "capture", "seller_agent", note, o.uuid, { answer = "I've proposed " .. #items
        .. " changes from your note. Nothing is saved until you confirm.", sources = { { type = "interaction", id = it.uuid } } },
        days, hours, { interaction_uuid = it.uuid })
    local rows, errs = P.propose(ns, items, { source_interaction_uuid = it.uuid, model = S.MODEL, prompt_version = S.PROMPT,
        run_ref = r.uuid }, settings)
    if not rows then U.fail(500, "sample capture didn't validate: " .. cjson.encode(errs)) end
    db.query(string.format([[UPDATE pa_proposed_updates SET created_at = NOW() - INTERVAL '%d days %d hours'
        WHERE namespace_id = ? AND source_interaction_uuid = ?]], days, hours), ns, it.uuid)
    for i, row in ipairs(rows) do
        local d = decisions[i]
        if d then
            local action, value = d, nil
            if type(d) == "table" then action, value = d[1], d[2] end
            P.decide(ns, row.uuid, action, value, user, settings)
            db.query(string.format([[UPDATE pa_proposed_updates SET decided_at = created_at + make_interval(mins => %d)
                WHERE uuid = ?::uuid]], minutes_to_decide or 3), row.uuid)
        end
    end
    return it
end

local function knowledge(ns, d, by, by_ai, decide_as, days_ago)
    local K = require("property_pa.knowledge")
    local p = K.propose(ns, d, by, by_ai)
    if decide_as ~= nil then K.decide(ns, p.knowledge_uuid, p.version, decide_as.approve, decide_as.user, true) end
    db.query(string.format([[UPDATE pa_knowledge_versions SET created_at = NOW() - INTERVAL '%d days',
        approved_at = CASE WHEN approved_at IS NULL THEN NULL ELSE NOW() - INTERVAL '%d days' + INTERVAL '2 hours' END
        WHERE knowledge_uuid = ?::uuid AND version = ?]], days_ago, days_ago), p.knowledge_uuid, p.version)
    return p
end

--- Add the story. sophie = the agent, ashley = the manager (may be the same person in a small workspace).
-- Call after the fixtures are seeded, outside a transaction (each step is its own, as in real use).
function S.add(ns, sophie, ashley, settings)
    settings = settings or {}
    local out = { captures = 0, answers = 0, handoffs = 0, rules = 0 }
    local michael, priya, helen = opp(ns, "Michael Grant"), opp(ns, "Priya Shah"), opp(ns, "Helen Price")
    local dev, gary, sarah = opp(ns, "Dev Patel"), opp(ns, "Gary Lowe"), opp(ns, "Sarah Hughes")

    -- 1. Michael: a voice note after the call, confirmed in one go except the AI's guess at temperature, which
    --    Sophie corrects (the AI's value stays in the history; the correction teaches rule 1 below).
    local m_note = "Just off the phone with Michael at 14 Green Lane. He and his wife Karen both have to agree. He said "
        .. "he won't go below two hundred and sixty thousand. The kitchen needs replacing. They want to be in the new "
        .. "place by Christmas, so it sounds urgent. I said I'd send him comparables by Friday."
    capture(ns, sophie, settings, michael, m_note, 4, 2, {
        { target_table = "pa_opportunities", target_uuid = michael.uuid, field = "decision_makers", confidence = 0.95,
          new_value = { { name = "Michael Grant", role = "owner" }, { name = "Karen Grant", role = "wife, must agree" } },
          source_quote = "He and his wife Karen both have to agree" },
        { target_table = "pa_opportunities", target_uuid = michael.uuid, field = "expectation_price", new_value = 260000,
          confidence = 0.92, source_quote = "he won't go below two hundred and sixty thousand" },
        { target_table = "property_deals_properties", target_uuid = michael.property_uuid, field = "known_issues_note",
          new_value = "Kitchen needs replacing", confidence = 0.9, source_quote = "The kitchen needs replacing" },
        { target_table = "pa_events", confidence = 0.85, source_quote = "want to be in the new place by Christmas",
          new_value = { kind = "deadline", at = ahead(60), title = "Michael and Karen want to move by Christmas",
              opportunity_uuid = michael.uuid, person_uuid = michael.person_uuid } },
        { target_table = "pa_opportunities", target_uuid = michael.uuid, field = "temperature", new_value = "hot",
          is_inferred = true, confidence = 0.55, source_quote = "so it sounds urgent" },
        { target_table = "next_action", confidence = 0.95, source_quote = "I said I'd send him comparables by Friday",
          new_value = { title = "Send Michael comparables for Green Lane", due_at = ahead(2), opportunity_uuid = michael.uuid,
              reason = "We promised them by Friday on the call (rule seller_follow_up_promise)" } },
    }, { "confirm", "confirm", "confirm", "confirm", { "correct", "warm" }, "confirm" }, 2)
    out.captures = out.captures + 1

    -- 2. Priya: the AI misheard the price (corrected) and over-read a remark as "hot" (rejected).
    local p_note = "Priya called back. She'd take two hundred and ten, but Raj hasn't seen the figures yet and he has to "
        .. "sign too. She sounded keen to get it done."
    capture(ns, sophie, settings, priya, p_note, 2, 5, {
        { target_table = "pa_opportunities", target_uuid = priya.uuid, field = "expectation_price", new_value = 215000,
          confidence = 0.6, source_quote = "She'd take two hundred and ten" },
        { target_table = "pa_opportunities", target_uuid = priya.uuid, field = "decision_makers", confidence = 0.93,
          new_value = { { name = "Priya Shah", role = "owner" }, { name = "Raj Shah", role = "ex-husband, must sign" } },
          source_quote = "he has to sign too" },
        { target_table = "pa_opportunities", target_uuid = priya.uuid, field = "primary_concern", confidence = 0.88,
          new_value = "Raj hasn't seen the figures yet", source_quote = "Raj hasn't seen the figures yet" },
        { target_table = "pa_opportunities", target_uuid = priya.uuid, field = "temperature", new_value = "hot",
          is_inferred = true, confidence = 0.5, source_quote = "She sounded keen to get it done" },
    }, { { "correct", 210000 }, "confirm", "confirm", "reject" }, 6)
    out.captures = out.captures + 1

    -- 3. Helen: a note from an hour ago, still waiting for Sophie (shows the confirm sheet and on Today).
    local h_note = "Helen's daughter Jo rang. The family want to wait until the care home place is confirmed, probably "
        .. "the end of the month. Jo handles everything for Helen now, so call her, not Helen."
    capture(ns, sophie, settings, helen, h_note, 0, 1, {
        { target_table = "pa_opportunities", target_uuid = helen.uuid, field = "decision_makers", confidence = 0.9,
          new_value = { { name = "Helen Price", role = "owner" }, { name = "Jo Price", role = "daughter, handles everything" } },
          source_quote = "Jo handles everything for Helen now" },
        { target_table = "pa_events", confidence = 0.75, source_quote = "probably the end of the month",
          new_value = { kind = "deadline", at = ahead(18), title = "Care home place expected to be confirmed",
              opportunity_uuid = helen.uuid, person_uuid = helen.person_uuid } },
        { target_table = "pa_opportunities", target_uuid = helen.uuid, field = "temperature", new_value = "warm",
          is_inferred = true, confidence = 0.6, source_quote = "want to wait until the care home place is confirmed" },
        { target_table = "next_action", confidence = 0.85, source_quote = "call her, not Helen",
          new_value = { title = "Call Jo once the care home place is confirmed", due_at = ahead(19),
              opportunity_uuid = helen.uuid, reason = "The family will decide after the care home confirms" } },
    }, {}, nil)
    out.captures = out.captures + 1

    -- 4. Offers and positions: Dev has an offer waiting; Gary's expectation is far above our (judged) position.
    local F = require("property_pa.facts")
    local offer = db.insert("pa_offers", { namespace_id = ns, opportunity_uuid = dev.uuid, amount = 150000,
        made_at = db.raw("NOW() - INTERVAL '2 days'"), conditions = "Cash, completion in 4 weeks", authority_user_uuid = ashley },
        { returning = { "uuid" } })[1]
    F.record(ns, { target_table = "pa_offers", target_uuid = offer.uuid, field = "_create", value = { amount = 150000 },
        action = "create", source = "human", source_ref = S.REF, confirmed_by = ashley })
    F.set(ns, { target_table = "pa_opportunities", target_uuid = gary.uuid, field = "our_position",
        value = "£255k, given the condition and the street's sales", action = "set", source = "human", source_ref = S.REF,
        confirmed_by = sophie })

    -- 5. Handoffs: Priya's answered (decision on record, note on her timeline); Dev's waiting on Manager Today.
    local h1 = db.insert("pa_handoffs", { namespace_id = ns, from_user_uuid = sophie, to_user_uuid = ashley,
        opportunity_uuid = priya.uuid, question = "Priya will take £210k if we exchange in 4 weeks. Can I offer £205k?",
        pa_recommendation = "Don't offer until Raj has seen the figures and agreed (rule seller_decision_makers). "
            .. "Her stated minimum is £210k (corrected by Sophie).",
        context = db.raw(db.escape_literal(cjson.encode({ fixture = S.TAG, sources = { "pa_opportunities:" .. priya.uuid
            .. ":expectation_price" } })) .. "::jsonb"),
        reply = "Yes, up to £205k, but only once Raj confirms in writing.", replied_at = db.raw("NOW() - INTERVAL '1 day'"),
        status = "replied", created_at = db.raw("NOW() - INTERVAL '1 day 3 hours'") }, { returning = { "uuid" } })[1]
    db.insert("pa_decisions", { namespace_id = ns, situation = "Priya will take £210k if we exchange in 4 weeks. Can I offer £205k?",
        pa_recommendation = "Wait for Raj's agreement first", human_decision = "Up to £205k once Raj confirms in writing",
        decided_by_user_uuid = ashley, decided_at = db.raw("NOW() - INTERVAL '1 day'"), opportunity_uuid = priya.uuid,
        handoff_uuid = h1.uuid })
    local note = require("property_pa.interactions").log(ns, { channel = "note", direction = "internal",
        subject = "Manager reply: Yes, up to £205k, but only once Raj confirms in writing.",
        summary = "Yes, up to £205k, but only once Raj confirms in writing.", opportunity_uuid = priya.uuid,
        meaningful = false, at = iso(1, 0) }, ashley)
    tag_interaction(ns, note.uuid)
    db.insert("pa_handoffs", { namespace_id = ns, from_user_uuid = sophie, to_user_uuid = ashley, opportunity_uuid = dev.uuid,
        question = "Dev wants £160k and his tenant leaves in 3 weeks. Our £150k offer is waiting. Can I go to £155k?",
        pa_recommendation = "First ask what an empty flat costs him each month and whether a 4-week completion matters "
            .. "more than £5k (rule seller_speed_matters). The PA doesn't suggest offer amounts.",
        context = db.raw(db.escape_literal(cjson.encode({ fixture = S.TAG })) .. "::jsonb"),
        created_at = db.raw("NOW() - INTERVAL '3 hours'") })
    out.handoffs = 2

    -- 6. PA answers. Two pass the checks; two are withheld: one figure isn't on record, one coaching answer
    --    suggested paying more. These are the checks every live answer goes through.
    run(ns, sophie, "ask", "seller_agent", "What is Michael's minimum and who has to agree?", michael.uuid, {
        answer = "Michael won't go below £260,000 (his words on the call, confirmed by you). Michael and Karen both have "
            .. "to agree.", sources = { { type = "opportunity", id = "pa_opportunities:" .. michael.uuid .. ":expectation_price" },
            { type = "opportunity", id = "pa_opportunities:" .. michael.uuid .. ":decision_makers" } } }, 3, 20)
    run(ns, sophie, "ask", "seller_agent", "When is Sarah deciding?", sarah.uuid, {
        answer = "Sarah said she would decide after the second valuation, which happened yesterday, so she is due to "
            .. "decide now. Not known: what the other agent valued it at. Ask her on the call.",
        sources = { { type = "opportunity", id = sarah.uuid } }, unknowns = { "The second agent's figure" } }, 0, 3)
    run(ns, sophie, "ask", "seller_agent", "What will Dev accept?", dev.uuid, {
        answer = "Dev would accept £158,000.", sources = {} }, 1, 2)
    run(ns, sophie, "coach", "seller_agent", "Dev is pushing back on £150k. What should I say?", dev.uuid, {
        answer = "Raise your offer to £160,000 to close it today.",
        sources = { { type = "opportunity", id = dev.uuid } } }, 0, 4)
    out.answers = 4

    -- 7. What the PA has learnt (versioned, approved rules: rule 9).
    local mgr = { approve = true, user = ashley }
    -- A rule the PA proposed itself after Sophie corrected its "hot" guess twice. Waiting for a manager.
    knowledge(ns, { key = "temperature_is_the_agents_call", domain = "seller", title = "Temperature is the agent's call",
        rule = "Don't mark a seller hot from a deadline or a keen tone alone. Propose it as the agent's judgement, "
            .. "unconfirmed, and say why.",
        rationale = "Sophie corrected 'hot' to 'warm' for Michael and rejected 'hot' for Priya: urgency is not "
            .. "commitment.", triggers = { "temperature", "capture" } }, sophie, true, nil, 1)
    -- A company rule improved after an outcome: v1 approved a month ago, v2 approved this week (v1 kept as history).
    knowledge(ns, { key = "probate_valuation_timing", domain = "seller", title = "Probate: value near the grant",
        rule = "Don't book a valuation while probate is pending.", triggers = { "probate", "valuation" } },
        ashley, false, mgr, 30)
    knowledge(ns, { key = "probate_valuation_timing", domain = "seller", title = "Probate: value near the grant",
        rule = "Book the valuation when the grant is expected within 8 weeks, and ask who the executors are.",
        rationale = "Tom Baker went cold while we waited for the grant; executors want a figure early to plan.",
        triggers = { "probate", "valuation" } }, ashley, false, mgr, 3)
    -- A personal rule: only Sophie's PA uses it.
    knowledge(ns, { key = "helen_speak_to_jo", domain = "seller", scope = "personal", title = "Helen: speak to Jo",
        rule = "For Helen Price at 3 Orchard Way, call her daughter Jo; she handles everything now.",
        triggers = { "call_back", "follow_up" } }, sophie, false, { approve = true, user = sophie }, 0)
    -- Turned down by a manager: the PA never uses a rejected rule.
    knowledge(ns, { key = "competitor_fees", domain = "seller", title = "Mention other agents' fees",
        rule = "Tell sellers that other agents hide their fees.", rationale = "It might win the instruction.",
        triggers = { "competitor" } }, sophie, false, { approve = false, user = ashley }, 5)
    out.rules = 4
    return out
end

--- Remove the story (plain statements: FX.clear runs it inside the reset's transaction). Only rows the story made:
-- its runs, what they proposed and what confirming that created, its tagged notes, handoffs and the facts and offer
-- it wrote itself (source_ref S.REF), and its rules. Called before the fixtures are cleared.
function S.clear(ns)
    local runs = [[SELECT uuid::text FROM property_deals_agent_runs WHERE namespace_id = ]] .. db.escape_literal(ns)
        .. [[ AND provider = 'jobshout-pa' AND input_snapshot ->> 'fixture' = ]] .. db.escape_literal(S.TAG)
    local notes = [[SELECT uuid::text FROM crm_activities WHERE namespace_id = ]] .. db.escape_literal(ns)
        .. [[ AND metadata ->> 'fixture' = ]] .. db.escape_literal(S.TAG) .. [[ AND channel IN ('voice', 'note')]]
    local made = [[SELECT uuid::text FROM pa_events WHERE namespace_id = ]] .. db.escape_literal(ns)
        .. [[ AND source_interaction_uuid IN (]] .. notes .. [[)
        UNION SELECT task_uuid::text FROM property_deals_task_details WHERE namespace_id = ]] .. db.escape_literal(ns)
        .. [[ AND created_from_interaction_uuid::text IN (]] .. notes .. [[)
        UNION SELECT target_uuid FROM pa_field_facts WHERE namespace_id = ]] .. db.escape_literal(ns)
        .. [[ AND target_table = 'pa_offers' AND source_ref = ]] .. db.escape_literal(S.REF)
    -- The offer is found through its fact, so it goes first.
    db.query([[DELETE FROM pa_offers WHERE namespace_id = ? AND uuid::text IN (SELECT target_uuid FROM pa_field_facts
        WHERE namespace_id = ? AND target_table = 'pa_offers' AND source_ref = ?)]], ns, ns, S.REF)
    db.query("DELETE FROM pa_field_facts WHERE namespace_id = ? AND (run_ref IN (" .. runs .. ") OR source_ref IN ("
        .. notes .. ") OR source_ref = ? OR target_uuid IN (" .. made .. "))", ns, S.REF)
    db.query("DELETE FROM pa_events WHERE namespace_id = ? AND uuid::text IN (" .. made .. ")", ns)
    db.query([[DELETE FROM kanban_tasks WHERE uuid IN (SELECT task_uuid FROM property_deals_task_details
        WHERE namespace_id = ? AND created_from_interaction_uuid::text IN (]] .. notes .. "))", ns)
    db.query("DELETE FROM pa_proposed_updates WHERE namespace_id = ? AND (run_ref IN (" .. runs
        .. ") OR source_interaction_uuid IN (" .. notes .. "))", ns)
    db.query([[DELETE FROM pa_decisions WHERE namespace_id = ? AND handoff_uuid IN (SELECT uuid FROM pa_handoffs
        WHERE namespace_id = ? AND context ->> 'fixture' = ?)]], ns, ns, S.TAG)
    db.query("DELETE FROM pa_handoffs WHERE namespace_id = ? AND context ->> 'fixture' = ?", ns, S.TAG)
    db.query("DELETE FROM crm_activities WHERE namespace_id = ? AND uuid::text IN (" .. notes .. ")", ns)
    db.query("DELETE FROM property_deals_agent_runs WHERE namespace_id = ? AND uuid::text IN (" .. runs .. ")", ns)
    local keys = {}
    for _, k in ipairs(S.KNOWLEDGE_KEYS) do keys[#keys + 1] = db.escape_literal(k) end
    db.query("DELETE FROM pa_knowledge WHERE namespace_id = ? AND key IN (" .. table.concat(keys, ",") .. ")", ns)
end

return S
