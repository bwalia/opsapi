-- luacheck: max line length 140
--[[
    Plain-Lua unit test for lib/shop-leads.lua (no nginx, no DB, no busted).

    Run from lapis/:
        luajit spec/shop-leads-test.lua
    or in the openresty image:
        docker run --rm -v "$PWD":/w -w /w openresty/openresty:alpine \
            luajit spec/shop-leads-test.lua
]]

package.path = "./?.lua;./?/init.lua;" .. package.path
local L = require("lib.shop-leads")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("ok   - " .. name)
    else
        failed = failed + 1
        print("FAIL - " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

-- email ----------------------------------------------------------------------------
check("email: trimmed + lower-cased", L.email("  Ada@Example.CO.UK ") == "ada@example.co.uk")
check("email: rejects junk", L.email("not-an-email") == nil and L.email("a@b") == nil and L.email(nil) == nil)
check("email: rejects spaces inside", L.email("a b@c.com") == nil)

-- requirements -------------------------------------------------------------------------
local r = L.requirements({ goal = "  Train a vision model faster ", budget_gbp = 40000, models = { "YOLO", "SAM 2" },
    password = "x", in_house = "", sector = "university" })
check("requirements: keeps known keys, trims", r.goal == "Train a vision model faster")
check("requirements: numbers become text", r.budget_gbp == "40000")
check("requirements: lists joined", r.models == "YOLO, SAM 2", r.models)
check("requirements: unknown keys dropped", r.password == nil)
check("requirements: empty values dropped", r.in_house == nil)
check("requirements: long text capped", #L.requirements({ goal = string.rep("x", 2000) }).goal == L.MAX_FIELD)
check("requirements: control chars removed", L.requirements({ goal = "a\nb" }).goal == "a b")
check("requirements: non-table → empty", next(L.requirements("goal")) == nil)

local m = L.merge_requirements({ goal = "old goal", deadline = "March" }, { goal = "new goal", team_size = 4 })
check("merge: newer wins", m.goal == "new goal")
check("merge: older kept when not repeated", m.deadline == "March")
check("merge: new added", m.team_size == "4")

check("requirements_line: fixed order, plain labels",
    L.requirements_line({ budget_gbp = "40000", goal = "Fine-tune Llama" }) == "Goal: Fine-tune Llama · Budget (£): 40000")
check("requirements_line: empty", L.requirements_line({}) == "")

-- metadata ------------------------------------------------------------------------------
local meta = L.merge_metadata({ other = 1 }, { chat_session_uuid = "s1", improve_consent = true })
meta = L.merge_metadata(meta, { chat_session_uuid = "s1" })
meta = L.merge_metadata(meta, { chat_session_uuid = "s2", quote = { uuid = "q1", number = "Q-1", total_minor = 100 } })
meta = L.merge_metadata(meta, { quote = { uuid = "q1", number = "Q-1", total_minor = 100 } })
check("metadata: unrelated keys kept", meta.other == 1)
check("metadata: chats de-duplicated", #meta.shop.chat_sessions == 2)
check("metadata: quotes de-duplicated", #meta.shop.quotes == 1)
check("metadata: consent kept when a later event says nothing", meta.shop.improve_consent == true)
meta = L.merge_metadata(meta, { improve_consent = false })
check("metadata: consent can be withdrawn", meta.shop.improve_consent == false)

local big = {}
for i = 1, L.MAX_LIST + 5 do big = L.merge_metadata(big, { chat_session_uuid = "c" .. i }) end
check("metadata: list capped, oldest dropped", #big.shop.chat_sessions == L.MAX_LIST and big.shop.chat_sessions[1] == "c6")

-- notes ------------------------------------------------------------------------------------
check("notes: first line", L.append_note(nil, "hello", "T") == "[T] hello")
check("notes: appended", L.append_note("[A] one", "two", "B") == "[A] one\n[B] two")
check("notes: nothing to add", L.append_note("x", nil, "T") == "x")
local long = L.append_note(string.rep("a", L.MAX_NOTES), "new", "T")
check("notes: trimmed to cap, newest kept", #long == L.MAX_NOTES and long:sub(-7) == "[T] new")

-- names --------------------------------------------------------------------------------------
local f, l = L.split_name("Ada King Lovelace")
check("name: first + rest", f == "Ada" and l == "King Lovelace")
f, l = L.split_name("")
check("name: unknown placeholder", f == "Shop customer" and l == nil)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
