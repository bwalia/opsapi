-- Work log (docs/AI_RUNNER_WEB_TERMINAL.md §11).
--   POST /public/terminal/activity          the terminal: tab states + events (signed body) -> { tabs, events }
--   POST /public/terminal/recordings        the terminal: one gzipped asciicast part (X-Opsapi-Tab/Part/Final)
--                                           Both: 403 TERMINAL_OFF when the terminal is switched off, 404
--                                           PLUGIN_DISABLED when its workspace is inactive or has AI Runs off.
--   GET  /work-log?user_uuid&task_uuid&from&to&page&per_page   your tabs; everyone's with ai_terminal_worklogs.read
--   GET  /work-log/people?from&to           ai_terminal_worklogs.read: totals per person
--   GET  /work-log/tabs/:uuid               one tab: totals, timeline (prompts, AI requests, actions), recording parts
--   GET  /work-log/tabs/:uuid/recording/:part   the gzipped asciicast part
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local U = require("ai_runner.util")
local T = require("ai_runner.terminal")
local W = require("ai_runner.worklog")

local MAX_ACTIVITY = 5 * 1024 * 1024

local function header(name)
    local v = ngx.req.get_headers()[name]
    if type(v) == "table" then v = v[1] end
    return v
end

-- The raw request body, also when nginx spooled it to a file. @return bytes | nil
local function raw_body(max)
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if not data then
        local path = ngx.req.get_body_file()
        local f = path and io.open(path, "rb")
        if f then
            data = f:read(max + 1)
            f:close()
        end
    end
    if data and #data > max then return nil end
    return data or ""
end

local function sees_everyone(self)
    return sdk.can(self, W.PERMISSION[1], W.PERMISSION[2])
end

-- A tab the caller may see: everyone's with the permission, else only their own.
local function visible_tab(self)
    local t = W.find(sdk.namespace_id(self), self.params.uuid)
    if not t or (not sees_everyone(self) and t.user_uuid ~= sdk.user(self).uuid) then
        U.fail(404, "Session not found")
    end
    return t
end

return function(app)
    app:post("/public/terminal/activity", sdk.handler({ namespace = false }, U.guard(function()
        local body = raw_body(MAX_ACTIVITY)
        if not body then return sdk.error(413, "Too large") end
        local term = T.signed_terminal(header("x-opsapi-terminal"), body, header("x-opsapi-signature"))
        if not term then return sdk.error(401, "Unauthorized") end
        T.ensure_poll_timer()
        local out, status, message = W.ingest(term, require("cjson.safe").decode(body))
        if not out then return sdk.error(status, message) end
        return sdk.ok(out)
    end)))

    app:post("/public/terminal/recordings", sdk.handler({ namespace = false }, U.guard(function()
        local body = raw_body(W.MAX_PART)
        if not body then return sdk.error(413, "A part can be up to 4 MiB") end
        local tab, part = header("x-opsapi-tab") or "", header("x-opsapi-part") or ""
        local term = T.signed_terminal(header("x-opsapi-terminal"), tab .. "\n" .. part .. "\n" .. body,
            header("x-opsapi-signature"))
        if not term then return sdk.error(401, "Unauthorized") end
        local out, status, message = W.store_recording(term, tab, part, header("x-opsapi-final") == "1", body)
        if not out then return sdk.error(status, message) end
        return sdk.ok(out)
    end)))

    app:get("/work-log", sdk.handler(U.guard(function(self)
        local p = self.params
        local f = { user_uuid = p.user_uuid, task_uuid = p.task_uuid, from = p.from, to = p.to }
        if not sees_everyone(self) then f.user_uuid = sdk.user(self).uuid end
        local page, per_page = sdk.page(p)
        local rows, meta = W.list(sdk.namespace_id(self), f, page, per_page)
        meta.sees_everyone = sees_everyone(self)
        return sdk.ok(rows, meta)
    end)))

    app:get("/work-log/people", sdk.handler({ permission = "ai_terminal_worklogs.read" }, U.guard(function(self)
        local p = self.params
        return sdk.ok(W.people(sdk.namespace_id(self), { user_uuid = p.user_uuid, from = p.from, to = p.to }))
    end)))

    app:get("/work-log/tabs/:uuid", sdk.handler(U.guard(function(self)
        return sdk.ok(W.detail(visible_tab(self)))
    end)))

    app:get("/work-log/tabs/:uuid/recording/:part", sdk.handler(U.guard(function(self)
        local bytes = W.recording_part(visible_tab(self), self.params.part)
        if not bytes then U.fail(404, "Recording not found") end
        return { status = 200, layout = false, bytes, headers = { ["Content-Type"] = "application/gzip",
            ["Cache-Control"] = "private, no-store" } }
    end)))
end
