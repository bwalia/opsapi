-- Renovation projects and the "what's due" list.
--   GET  /renovations       list with progress ?status=active|completed|all&deal_uuid=
--   POST /renovations       { deal_uuid? | property_uuid?, name?, budget?, start_date?, target_end_date?,
--                             builder_user_uuids?[] } -> a kanban project with one column per build
--                             stage and the standard jobs as dated cards (seed/renovation_standard)
--   GET  /due               open deal tasks + renovation jobs due within ?days= (default 7), overdue
--                           first. Managers see everyone's (?mine=true for their own); others see theirs.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local U = require("property_deals.util")

local DONE_JOB = "(t.completed_at IS NOT NULL OR t.status IN ('completed', 'cancelled') OR c.is_done_column)"

local LIST = [[
    SELECT r.uuid, r.deal_uuid, r.property_uuid, r.template_key, r.created_at,
           p.uuid AS project_uuid, p.name, p.status, p.budget, p.budget_spent, p.budget_currency,
           p.start_date, p.due_date, cd.name AS deal_name,
           COALESCE(pr.address_line1, '') AS address, pr.postcode,
           COUNT(t.id) FILTER (WHERE t.id IS NOT NULL)::int AS jobs_total,
           COUNT(t.id) FILTER (WHERE ]] .. DONE_JOB .. [[)::int AS jobs_done,
           COUNT(t.id) FILTER (WHERE t.due_date < CURRENT_DATE AND NOT ]] .. DONE_JOB .. [[)::int AS jobs_overdue,
           (SELECT b.uuid FROM kanban_boards b WHERE b.project_id = p.id AND b.archived_at IS NULL
            ORDER BY b.is_default DESC, b.position LIMIT 1) AS board_uuid
    FROM property_deals_renovations r
    JOIN kanban_projects p ON p.uuid = r.kanban_project_uuid
    LEFT JOIN property_deals_deals dl ON dl.uuid = r.deal_uuid
    LEFT JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
    LEFT JOIN property_deals_properties pr ON pr.uuid = COALESCE(r.property_uuid, dl.property_uuid)
    LEFT JOIN kanban_boards b ON b.project_id = p.id AND b.archived_at IS NULL
    LEFT JOIN kanban_tasks t ON t.board_id = b.id AND t.archived_at IS NULL AND t.deleted_at IS NULL
    LEFT JOIN kanban_columns c ON c.id = t.column_id
]]
local GROUP = " GROUP BY r.id, p.id, cd.name, pr.address_line1, pr.postcode "

local function date_only(v)
    return type(v) == "string" and v:match("^(%d%d%d%d%-%d%d%-%d%d)") or nil
end

-- Days between two YYYY-MM-DD dates (b - a).
local function days_between(a, b)
    local function t(d)
        local y, m, dd = d:match("^(%d+)-(%d+)-(%d+)$")
        return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 12 })
    end
    return math.floor((t(b) - t(a)) / 86400 + 0.5)
end

local function add_days(d, n)
    local y, m, dd = d:match("^(%d+)-(%d+)-(%d+)$")
    return os.date("!%Y-%m-%d", os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd) + n, hour = 12 }))
end

local function create(ns, user, data)
    local tpl = require("property_deals.seed.renovation_standard")
    local deal, property
    if data.deal_uuid then
        deal = U.one([[
            SELECT dl.uuid, dl.property_uuid, cd.name FROM property_deals_deals dl
            JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid WHERE dl.namespace_id = ? AND dl.uuid = ?
        ]], ns, data.deal_uuid)
        if not deal then return nil, { deal_uuid = "no such deal in this workspace" } end
    end
    local property_uuid = data.property_uuid or (deal and deal.property_uuid ~= db.NULL and deal.property_uuid) or nil
    if property_uuid then
        property = U.one("SELECT uuid, address_line1, postcode FROM property_deals_properties WHERE namespace_id = ? AND uuid = ?",
            ns, property_uuid)
        if not property then return nil, { property_uuid = "no such property in this workspace" } end
    end

    local start = data.start_date or os.date("!%Y-%m-%d")
    local finish = data.target_end_date or add_days(start, tpl.days)
    local span = days_between(start, finish)
    if span < 1 then return nil, { target_end_date = "must be after the start date" } end
    local scale = span / tpl.days

    local name = data.name
        or ("Renovation — " .. ((property and property.address_line1) or (deal and deal.name) or os.date("!%d %b %Y")))
    return U.tx(function()
        local KP = require("queries.KanbanProjectQueries")
        local project = KP.create({
            namespace_id = ns, name = name:sub(1, 255), owner_user_uuid = user, icon = "Hammer", color = "#B45309",
            description = "Renovation board: one column per build stage. Move cards as work progresses.",
            budget = data.budget, budget_currency = data.currency or "GBP",
            start_date = start, due_date = finish,
        })
        local board = U.one("SELECT id, uuid FROM kanban_boards WHERE project_id = ? ORDER BY is_default DESC, position LIMIT 1",
            project.id)
        db.update("kanban_boards", { name = "Build stages", description = tpl.name }, { id = board.id })
        -- Replace the generic Backlog/To Do/... columns with the build stages.
        db.query("DELETE FROM kanban_columns WHERE board_id = ?", board.id)
        local Global = require("helper.global")
        for i, stage in ipairs(tpl.stages) do
            local col = db.insert("kanban_columns", {
                uuid = Global.generateUUID(), board_id = board.id, name = stage.name, position = i - 1,
                color = stage.color, is_done_column = stage.done == true, auto_close_tasks = stage.done == true,
                created_at = db.raw("NOW()"), updated_at = db.raw("NOW()"),
            }, { returning = { "id" } })[1]
            for pos, job in ipairs(stage.jobs) do
                local title, day, days, priority = job[1], job[2], job[3], job[4]
                local s = math.floor(day * scale + 0.5)
                local e = math.max(s, math.floor((day + days) * scale + 0.5) - 1)
                if day + days >= tpl.days then e = span end -- the last jobs end on the finish date
                require("queries.KanbanTaskQueries").create({
                    board_id = board.id, column_id = col.id, title = title, priority = priority,
                    position = pos - 1, start_date = add_days(start, s), due_date = add_days(start, e),
                    reporter_user_uuid = user, status = "open",
                })
            end
        end
        local added = {}
        for _, uuid in ipairs(data.builder_user_uuids or {}) do
            if KP.addMember(project.id, uuid, "member", user) then added[#added + 1] = uuid end
        end
        local r = db.insert("property_deals_renovations", {
            namespace_id = ns, kanban_project_uuid = project.uuid, deal_uuid = data.deal_uuid or db.NULL,
            property_uuid = property and property.uuid or db.NULL, template_key = tpl.key,
            created_by_user_uuid = user,
        }, { returning = { "uuid" } })[1]
        local row = U.one(LIST .. " WHERE r.uuid = ?" .. GROUP, r.uuid)
        row.builders_added = sdk.array(added)
        return row
    end)
end

return function(app)
    app:get("/renovations", sdk.handler({ permission = "property_deals_deals.read" }, function(self)
        local p, ns = self.params, sdk.namespace_id(self)
        local where = { "r.namespace_id = " .. db.escape_literal(ns), "p.deleted_at IS NULL" }
        if p.status == "completed" then
            where[#where + 1] = "p.status = 'completed'"
        elseif p.status ~= "all" then
            where[#where + 1] = "p.status IN ('active', 'on_hold')"
        end
        if U.is_uuid(p.deal_uuid) then where[#where + 1] = "r.deal_uuid = " .. db.escape_literal(p.deal_uuid) end
        local rows = db.query(LIST .. " WHERE " .. table.concat(where, " AND ") .. GROUP
            .. " ORDER BY p.due_date NULLS LAST, r.created_at DESC LIMIT 200")
        return sdk.ok(sdk.array(rows))
    end))

    app:post("/renovations", sdk.handler({ permission = "property_deals_deals.create" }, U.guard_create(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        -- A list of user uuids (sdk "json" fields come back encoded, so check it here).
        local builders = body.builder_user_uuids
        body.builder_user_uuids = nil
        if builders ~= nil then
            local ok = type(builders) == "table"
            for _, u in ipairs(ok and builders or {}) do ok = ok and U.is_uuid(u) end
            if not ok then
                return sdk.error(422, "Validation failed", { builder_user_uuids = "must be a list of user uuids" })
            end
        end
        local data, errors = sdk.validate(body, {
            deal_uuid = { type = "uuid" }, property_uuid = { type = "uuid" },
            name = { type = "string", max = 255 }, budget = { type = "number", min = 0 },
            currency = { type = "string", min = 3, max = 3 },
            start_date = { type = "string" }, target_end_date = { type = "string" },
        })
        if not data then return sdk.error(422, "Validation failed", errors) end
        for _, k in ipairs({ "start_date", "target_end_date" }) do
            if data[k] ~= nil then
                data[k] = date_only(data[k])
                if not data[k] then return sdk.error(422, "Validation failed", { [k] = "use YYYY-MM-DD" }) end
            end
        end
        data.builder_user_uuids = builders
        local row, errs = create(sdk.namespace_id(self), sdk.user(self).uuid, data)
        if not row then return sdk.error(422, "Validation failed", errs) end
        return sdk.created(row)
    end)))

    app:get("/due", sdk.handler({ permission = "property_deals_tasks.read" }, U.guard(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local days = math.max(0, math.min(tonumber(self.params.days) or 7, 60))
        local everyone = sdk.can(self, "property_deals_approvals", "manage") and self.params.mine ~= "true"
        local mine_task = everyone and "TRUE" or ("d.owner_user_uuid = " .. db.escape_literal(me))
        local mine_job = everyone and "TRUE" or ("EXISTS (SELECT 1 FROM kanban_task_assignees a WHERE a.task_id = t.id AND a.deleted_at IS NULL"
            .. " AND a.user_uuid = " .. db.escape_literal(me) .. ")")
        local rows = db.query([[
            SELECT * FROM (
                SELECT 'deal_task' AS kind, d.task_uuid AS uuid, t.title, d.due_at, (d.due_at < NOW()) AS overdue,
                       d.pd_status AS status, d.deal_uuid, cd.name AS deal_name, NULL::text AS project_uuid,
                       NULL::text AS project_name, NULL::text AS column_name,
                       COALESCE(NULLIF(TRIM(CONCAT(u.first_name, ' ', u.last_name)), ''), u.email) AS assignee
                FROM property_deals_task_details d
                JOIN kanban_tasks t ON t.uuid = d.task_uuid
                LEFT JOIN property_deals_deals dl ON dl.uuid = d.deal_uuid
                LEFT JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
                LEFT JOIN users u ON u.uuid = d.owner_user_uuid
                WHERE d.namespace_id = ? AND d.pd_status NOT IN ('done', 'cancelled') AND d.due_at IS NOT NULL
                  AND d.due_at < (CURRENT_DATE + (? || ' days')::interval + INTERVAL '1 day') AND ]] .. mine_task .. [[
                UNION ALL
                SELECT 'renovation_job', t.uuid, t.title, (t.due_date + TIME '17:00')::timestamptz,
                       (t.due_date < CURRENT_DATE), t.status, r.deal_uuid, cd.name, p.uuid, p.name, c.name,
                       (SELECT string_agg(COALESCE(NULLIF(TRIM(CONCAT(uu.first_name, ' ', uu.last_name)), ''), uu.email), ', ')
                        FROM kanban_task_assignees a JOIN users uu ON uu.uuid = a.user_uuid
                        WHERE a.task_id = t.id AND a.deleted_at IS NULL)
                FROM property_deals_renovations r
                JOIN kanban_projects p ON p.uuid = r.kanban_project_uuid AND p.deleted_at IS NULL
                JOIN kanban_boards b ON b.project_id = p.id AND b.archived_at IS NULL
                JOIN kanban_tasks t ON t.board_id = b.id AND t.archived_at IS NULL AND t.deleted_at IS NULL
                LEFT JOIN kanban_columns c ON c.id = t.column_id
                LEFT JOIN property_deals_deals dl ON dl.uuid = r.deal_uuid
                LEFT JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
                WHERE r.namespace_id = ? AND t.due_date IS NOT NULL AND NOT ]] .. DONE_JOB .. [[
                  AND t.due_date <= CURRENT_DATE + ?::int AND ]] .. mine_job .. [[
            ) x ORDER BY x.due_at ASC LIMIT 300
        ]], ns, tostring(days), ns, days)
        return sdk.ok({ days = days, everyone = everyone, items = sdk.array(rows) })
    end)))
end
