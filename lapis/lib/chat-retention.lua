--[[
    Chat retention (CHAT_SCALING_RUNBOOK.md §2a)
    =============================================
    Deleting a message only sets is_deleted. 30 days later this job purges what
    the message said: content → '[deleted]' (chat_messages_has_content needs
    some text), attachments / mentions / metadata → NULL,
    its edit history deleted, and its uploaded files deleted. The row stays as
    a tombstone so threads, reply counts and reactions keep working.

    Files: attachments are client-written URLs, so only an object in the
    author's own folder (chat-attachments/<author uuid>/…, where the upload
    route puts it) is ever deleted. A URL pointing anywhere else is left alone:
    a crafted attachment can't make this job delete someone else's file.

    Runs once a day on worker 0 of every pod; an advisory lock lets one pod
    work at a time. 1,000 messages a batch, each its own transaction; files are
    deleted only after the batch commits.
]]

local cjson = require("cjson.safe")

local Retention = {}

Retention.PURGE_AFTER_DAYS = 30
local BATCH = 1000
local MAX_BATCHES = 50          -- per run (50,000 messages); the next run resumes
local INTERVAL_SECONDS = 24 * 3600

local function db()
    return require("lapis.db")
end

--- The object key of an uploaded chat file, or nil unless it is in the
-- author's own chat-attachments folder.
function Retention.object_key(url, author_uuid)
    if type(url) ~= "string" or type(author_uuid) ~= "string" or author_uuid == "" then return nil end
    local key = url:gsub("[?#].*$", ""):match("/(chat%-attachments/.+)$")
    if not key or key:find("..", 1, true) or key:find("[^%w%-_./]") then return nil end
    local own = "chat-attachments/" .. author_uuid .. "/"
    return key:sub(1, #own) == own and key or nil
end

local function attachment_keys(attachments, author_uuid, keys)
    local list = type(attachments) == "string" and cjson.decode(attachments) or nil
    if type(list) ~= "table" then return end
    for _, a in ipairs(list) do
        if type(a) == "table" then
            for _, field in ipairs({ "file_url", "url", "thumbnail_url" }) do
                local key = Retention.object_key(a[field], author_uuid)
                if key then keys[#keys + 1] = key end
            end
        end
    end
end

-- One batch in one transaction. @return purged count, object keys | nil when another pod holds the lock
local function purge_batch(d)
    d.query("BEGIN")
    local ok, res = pcall(function()
        if not d.query("SELECT pg_try_advisory_xact_lock(hashtext('opsapi.chat.retention')) AS l")[1].l then
            return nil
        end
        local rows = d.query(([[
            WITH b AS (
                SELECT id, uuid, user_uuid, attachments FROM chat_messages
                WHERE is_deleted AND COALESCE(deleted_at, updated_at) < NOW() - interval '%d days'
                  AND (content <> '[deleted]' OR attachments IS NOT NULL OR mentions IS NOT NULL
                       OR metadata IS NOT NULL)
                ORDER BY id LIMIT %d FOR UPDATE SKIP LOCKED
            ), purged AS (
                UPDATE chat_messages m
                SET content = '[deleted]', attachments = NULL, mentions = NULL, metadata = NULL
                FROM b WHERE m.id = b.id RETURNING m.id
            )
            SELECT b.uuid, b.user_uuid, b.attachments FROM b
        ]]):format(Retention.PURGE_AFTER_DAYS, BATCH))
        local keys, uuids = {}, {}
        for _, r in ipairs(rows) do
            uuids[#uuids + 1] = d.escape_literal(r.uuid)
            attachment_keys(r.attachments, r.user_uuid, keys)
        end
        if #uuids > 0 then
            local list = table.concat(uuids, ",")
            -- The UPDATE above fires track_message_edit(), which copies the old
            -- text into chat_message_edits: deleting the history comes after it.
            d.query("DELETE FROM chat_message_edits WHERE message_uuid IN (" .. list .. ")")
            local files = d.query("UPDATE chat_file_attachments SET is_deleted = true, updated_at = NOW() "
                .. "WHERE message_uuid IN (" .. list .. ") AND NOT is_deleted "
                .. "RETURNING file_url, thumbnail_url, user_uuid")
            for _, f in ipairs(files) do
                keys[#keys + 1] = Retention.object_key(f.file_url, f.user_uuid)
                keys[#keys + 1] = Retention.object_key(f.thumbnail_url, f.user_uuid)
            end
        end
        return { count = #rows, keys = keys }
    end)
    d.query(ok and res and "COMMIT" or "ROLLBACK")
    if not ok then error(res, 0) end
    return res
end

--- Purge every deleted message older than PURGE_AFTER_DAYS (up to MAX_BATCHES
-- batches). @return messages purged, files deleted, files that failed to delete
function Retention.purge()
    local d = db()
    local purged, deleted, failed = 0, 0, 0
    for _ = 1, MAX_BATCHES do
        local batch = purge_batch(d)
        if not batch then break end -- another pod is purging
        purged = purged + batch.count
        local minio = #batch.keys > 0 and require("helper.minio")
        for _, key in pairs(batch.keys) do
            local ok, res = pcall(minio.quickDelete, key)
            if ok and res then deleted = deleted + 1 else failed = failed + 1 end
        end
        if batch.count < BATCH then break end
    end
    return purged, deleted, failed
end

local function run(premature)
    if premature then return end
    local ok, purged, deleted, failed = pcall(Retention.purge)
    if not ok then
        ngx.log(ngx.ERR, "[chat-retention] purge failed: ", tostring(purged))
    elseif purged > 0 then
        ngx.log(failed > 0 and ngx.WARN or ngx.NOTICE, "[chat-retention] purged ", purged,
            " deleted message(s); deleted ", deleted, " file(s)", failed > 0 and (", " .. failed .. " failed") or "")
    end
    pcall(function()
        local d = db()
        if d.query("SELECT now() <> statement_timestamp() AS open")[1].open then d.query("ROLLBACK") end
    end)
    pcall(require("lapis.nginx.context").run_after_dispatch)
end

--- Start the daily purge (init_worker; worker 0, deployments with chat).
function Retention.start()
    if ngx.worker.id() ~= 0 or not require("helper.project-config").isFeatureEnabled("chat") then return end
    ngx.timer.at(300, run)
    ngx.timer.every(INTERVAL_SECONDS, run)
end

return Retention
