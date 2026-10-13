-- Routing rules for sessions started by hand (docs/AI_RUNNER.md §27.3): where each one's task goes, or that it gets
-- none. Ordered per workspace; the first enabled rule whose match fits wins; no rule -> the workspace default (the
-- §26.2 session_tracking target). In a match, an empty field matches anything, any entry of a field may match, and
-- every field must.
local db = require("lapis.db")
local U = require("ai_runner.util")

local Rules = {}

Rules.MATCH_FIELDS = { "runner_uuids", "tools", "folder_globs", "branch_globs", "prompt_keywords" }
Rules.NOTIFY = { "managers", "assignees", "none", "users" }
Rules.VARIABLES = { "first_prompt", "prompt_preview", "tool", "tool_label", "folder", "repo", "branch", "runner",
    "started", "session_id" }
-- The defaults reproduce the §26.3 title (the first prompt's first line, else "<Tool> session in <folder> on
-- <runner>") and description: lines, and paragraphs, whose variables are all empty are left out.
Rules.TITLE_TEMPLATE = "{{first_prompt}}"
Rules.DESCRIPTION_TEMPLATE = table.concat({
    "Started by hand on {{runner}} and tracked automatically by AI Runs.",
    "",
    "Tool: {{tool_label}}",
    "Folder: {{folder}}",
    "Branch: {{branch}}",
    "Started: {{started}}",
    "Session id: {{session_id}}",
    "",
    "First prompt:",
    "{{first_prompt}}",
}, "\n")

local function list(v)
    return type(v) == "table" and v or {}
end

local function str(v)
    return type(v) == "string" and v or nil
end

--- An action as the API shows it: every key, whatever the type ("" template = the default one).
function Rules.action_view(a)
    a = type(a) == "table" and a or {}
    return { type = a.type == "ignore" and "ignore" or "create_task", project_uuid = U.null(str(a.project_uuid)),
        column = U.null(str(a.column)), status = str(a.status) or "in_progress", priority = U.null(str(a.priority)),
        assignee_uuids = U.array({ unpack(list(a.assignee_uuids)) }), title_template = str(a.title_template) or "",
        description_template = str(a.description_template) or "", notify = str(a.notify) or "managers",
        notify_user_uuids = U.array({ unpack(list(a.notify_user_uuids)) }) }
end

function Rules.view(r)
    local m = U.json(r.match)
    m = type(m) == "table" and m or {}
    local match = {}
    for _, k in ipairs(Rules.MATCH_FIELDS) do match[k] = U.array({ unpack(list(m[k])) }) end
    return { uuid = r.uuid, name = r.name or "", enabled = r.enabled ~= false, position = r.position, match = match,
        action = Rules.action_view(U.json(r.action)), created_by = U.null(r.created_by),
        created_at = U.null(r.created_at), updated_at = U.null(r.updated_at) }
end

--- The workspace's rules in order (enabled ones only, or all).
function Rules.load(ns, all)
    local rows = db.query("SELECT * FROM ar_track_rules WHERE namespace_id = ?" .. (all and "" or " AND enabled")
        .. " ORDER BY position, id", ns)
    for i, r in ipairs(rows) do rows[i] = Rules.view(r) end
    return rows
end

--- Does a session (s: tool, cwd, branch, first_prompt, prompt_preview) of this runner fit a rule's match?
function Rules.matches(match, runner_uuid, s)
    local function any(field, test)
        local l = list(match[field])
        if #l == 0 then return true end
        for _, x in ipairs(l) do
            if test(x) then return true end
        end
        return false
    end
    local tool = (str(s.tool) or ""):lower():match("^%s*(.-)%s*$")
    local text = ((str(s.first_prompt) or "") .. "\n" .. (str(s.prompt_preview) or "")):lower()
    return any("runner_uuids", function(u) return u == runner_uuid end)
        and any("tools", function(t) return t == tool end)
        and any("folder_globs", function(g) return str(s.cwd) ~= nil and U.folder_match(g, s.cwd) end)
        and any("branch_globs", function(g) return str(s.branch) ~= nil and U.glob(g, s.branch) end)
        and any("prompt_keywords", function(k) return text:find(k, 1, true) ~= nil end)
end

--- The first rule (of Rules.load) that fits, or nil.
function Rules.pick(rules, runner_uuid, s)
    for _, r in ipairs(rules) do
        if r.enabled and Rules.matches(r.match, runner_uuid, s) then return r end
    end
end

--- What a session no rule fits gets: the workspace's session_tracking target (§26.2).
function Rules.default_action(st)
    return Rules.action_view({ type = "create_task", project_uuid = st.project_uuid, column = st.column,
        status = st.status, notify = st.notify == false and "none" or "managers" })
end

--- Template variables of a session (s: tool, cwd, branch, session_id, first_prompt, prompt_preview, started).
function Rules.vars(runner_name, s, tool_labels)
    local tool = str(s.tool) or ""
    local labels = type(tool_labels) == "table" and tool_labels or {}
    local label = str(labels[tool]) or str(labels[tool:lower()])
        or (tool ~= "" and (tool:gsub("^%l", string.upper))) or "AI"
    local cwd = str(s.cwd)
    return { first_prompt = str(s.first_prompt) or "", prompt_preview = str(s.prompt_preview) or "", tool = tool,
        tool_label = label, folder = cwd or "", repo = cwd and cwd:match("([^/]+)$") or "",
        branch = str(s.branch) or "", runner = runner_name or "", started = str(s.started) or "",
        session_id = str(s.session_id) or "" }
end

--- Fill a template, line by line: {{name}} -> its value, unknown names empty, in one pass (a value is never
-- expanded again). A line whose variables all came out empty is left out, and so is a paragraph (lines between blank
-- lines) whose variables all did; a line without variables stays.
function Rules.render(template, vars)
    local paras, cur = {}, nil
    local function close()
        if cur and #cur.lines > 0 and not (cur.vars > 0 and cur.filled == 0) then
            paras[#paras + 1] = table.concat(cur.lines, "\n")
        end
        cur = { lines = {}, vars = 0, filled = 0 }
    end
    close()
    for line in (template:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^%s*$") then
            close()
        else
            local n, filled = 0, 0
            local out = line:gsub("{{%s*([%w_]+)%s*}}", function(k)
                n = n + 1
                local v = vars[k] or ""
                if v ~= "" then filled = filled + 1 end
                return v
            end)
            cur.vars, cur.filled = cur.vars + n, cur.filled + filled
            if n == 0 or filled > 0 then cur.lines[#cur.lines + 1] = out end
        end
    end
    close()
    return table.concat(paras, "\n\n")
end

local function template(v, default)
    return type(v) == "string" and v ~= "" and v or default
end

--- The task title: the rendered title template's first line (at most 120 characters), else "<Tool> session in
-- <folder> on <runner>".
function Rules.title(action, vars)
    local line = Rules.render(template(action.title_template, Rules.TITLE_TEMPLATE), vars)
        :match("^%s*([^\r\n]*)"):gsub("%s+$", "")
    if line == "" then
        line = vars.tool_label .. " session in " .. (vars.repo ~= "" and vars.repo or vars.folder ~= "" and vars.folder
            or "an unknown folder") .. " on " .. vars.runner
    end
    return U.cut(line, 120)
end

function Rules.description(action, vars)
    return U.clean(Rules.render(template(action.description_template, Rules.DESCRIPTION_TEMPLATE), vars), 20000)
end

--- What a session would become: the rule that fits (nil: the default), its action, and the task's title and
-- description (nil when ignored). st: the workspace's session_tracking.
function Rules.evaluate(rules, st, runner_uuid, runner_name, s)
    local rule = Rules.pick(rules, runner_uuid, s)
    local action = rule and rule.action or Rules.default_action(st)
    if action.type == "ignore" then return rule, action end
    local vars = Rules.vars(runner_name, s, st.tool_labels)
    return rule, action, Rules.title(action, vars), Rules.description(action, vars), vars
end


return Rules
