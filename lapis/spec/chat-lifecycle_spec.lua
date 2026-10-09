--[[
    Regression spec: chat data lifecycle (CHAT_SCALING_RUNBOOK.md §2a).

    Standalone — run from the repo root with:
        luajit lapis/spec/chat-lifecycle_spec.lua

    Deleted messages are purged after 30 days, deleting only the author's own
    uploads; search runs on the search_vector index.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end
local function read(path)
    local h = io.open(path) or assert(io.open((path:gsub("^lapis/", ""))))
    local s = h:read("*a")
    h:close()
    return s
end
local function has(s, needle) return s:find(needle, 1, true) ~= nil end

print("purge deletes only the author's own uploads:")
local ok_mod, Retention = pcall(require, "lib.chat-retention")
if not ok_mod then
    check("lib.chat-retention loads (needs cjson: run in the OpenResty image)", false, Retention)
else
    local key = Retention.object_key
    local base = "https://s3.example.com/bucket/"
    check("own file → its key", key(base .. "chat-attachments/u-a/2026/08/01/x.png", "u-a")
        == "chat-attachments/u-a/2026/08/01/x.png")
    check("query string ignored", key(base .. "chat-attachments/u-a/x.png?X-Amz-Signature=1", "u-a")
        == "chat-attachments/u-a/x.png")
    check("someone else's file → nil", key(base .. "chat-attachments/u-b/x.png", "u-a") == nil)
    check("'..' → nil", key(base .. "chat-attachments/u-a/../u-b/x.png", "u-a") == nil)
    check("encoded characters → nil", key(base .. "chat-attachments/u-a/%2e%2e/u-b/x.png", "u-a") == nil)
    check("outside chat-attachments → nil", key(base .. "uploads/u-a/x.pdf", "u-a") == nil)
    check("author is a prefix of another uuid → nil", key(base .. "chat-attachments/u-ab/x.png", "u-a") == nil)
    check("no author / not a string → nil", key(base .. "chat-attachments/u-a/x.png", "") == nil
        and key(nil, "u-a") == nil and key({}, "u-a") == nil)
end

local src = read("lapis/lib/chat-retention.lua")
print("purge job:")
check("after 30 days, deleted messages only", has(src, "Retention.PURGE_AFTER_DAYS = 30")
    and has(src, "WHERE is_deleted AND COALESCE(deleted_at, updated_at) < NOW()"))
check("keeps a tombstone row (content '[deleted]', has_content check)", has(src, "SET content = '[deleted]'"))
check("edit history deleted after the UPDATE (its trigger copies the old text)",
    src:find("UPDATE chat_messages m", 1, true) < src:find("DELETE FROM chat_message_edits", 1, true))
check("batched + one pod at a time", has(src, "ORDER BY id LIMIT %d FOR UPDATE SKIP LOCKED")
    and has(src, "pg_try_advisory_xact_lock(hashtext('opsapi.chat.retention'))"))
check("files deleted only after the batch commits", has(src, 'd.query(ok and res and "COMMIT" or "ROLLBACK")')
    and src:find("COMMIT", 1, true) < src:find("quickDelete", 1, true))
for _, conf in ipairs({ "lapis/nginx.conf", "lapis/nginx-values-template.conf" }) do
    check(conf .. " starts it", has(read(conf), 'require("lib.chat-retention").start()'))
end

print("search:")
local q = read("lapis/queries/ChatMessageQueries.lua")
check("search uses the search_vector index", has(q, "m.search_vector @@ websearch_to_tsquery('english', ?)")
    and not has(q, "m.content ILIKE"))
check("the unused content index is dropped", has(read("lapis/migrations/chat-lifecycle.lua"),
    "DROP INDEX IF EXISTS chat_messages_content_search_idx")
    and has(read("lapis/migrations.lua"), "['zzchat2_drop_unused_content_search_index']"))

print(failures == 0 and "\nall chat lifecycle checks passed" or ("\n" .. failures .. " check(s) FAILED"))
os.exit(failures == 0 and 0 or 1)
