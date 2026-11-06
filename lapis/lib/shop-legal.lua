-- luacheck: max line length 140
--[[
    Shop legal acceptances — pure rules (no nginx, no DB), unit-tested in spec/shop-legal_spec.lua.

    The shop shows versioned legal documents (terms of sale, privacy notice, Trade terms, …) and the exact
    statements a customer ticks at each critical point. OpsAPI does not decide which versions are current:
    the shop does. OpsAPI keeps the evidence — an append-only record of who accepted which version of which
    document, the statement they ticked, where (checkpoint), against what (cart / quote / chat), and from
    which IP and browser.
]]

local M = {}

M.CHECKPOINTS = {
    "register",    -- first sign-in, or a document changed since the last acceptance
    "quote",       -- quote request
    "checkout",    -- basket checkout / payment
    "trade_join",  -- Trade membership sign-up
    "chat",        -- AI sales engineer: email gate / save chat
    "enquiry",     -- enquiry or waitlist form
    "contact",     -- website contact form
}
local CHECKPOINT = {}
for _, c in ipairs(M.CHECKPOINTS) do CHECKPOINT[c] = true end

M.MAX_DOCUMENTS = 12
M.MAX_STATEMENT = 1000
M.MAX_UA = 400

local function trim(v)
    if type(v) ~= "string" then return nil end
    v = v:match("^%s*(.-)%s*$")
    if v == "" then return nil end
    return v
end

--- Lower-cased, trimmed email, or nil when it doesn't look like one.
function M.email(v)
    v = trim(v)
    if not v then return nil end
    v = v:lower()
    if #v > 254 or not v:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then return nil end
    return v
end

function M.key(v)
    v = trim(v)
    if v and #v <= 48 and v:match("^[a-z][a-z0-9%-]+$") then return v end
    return nil
end

function M.version(v)
    v = trim(v)
    if v and #v <= 32 and v:match("^[%w%.%-]+$") then return v end
    return nil
end

function M.hash(v)
    v = trim(v)
    if v == nil then return nil, true end
    v = v:lower()
    if #v == 64 and v:match("^[0-9a-f]+$") then return v, true end
    return nil, false
end

function M.checkpoint(v)
    v = trim(v)
    if v and CHECKPOINT[v] then return v end
    return nil
end

function M.subject_ref(v)
    v = trim(v)
    if v == nil then return nil, true end
    if #v <= 64 and v:match("^[%w%._:%-]+$") then return v, true end
    return nil, false
end

--- Validate a POST /legal/acceptances body.
--- Returns rec | nil, code, message.
--- rec = { email, checkpoint, subject_ref, ip, user_agent, documents = { {key, version, hash, statement}, … } }
function M.validate(body)
    if type(body) ~= "table" then return nil, "INVALID_BODY", "Expected a JSON object" end
    local email = M.email(body.email)
    if not email then return nil, "INVALID_EMAIL", "A valid email is required" end
    local checkpoint = M.checkpoint(body.checkpoint)
    if not checkpoint then
        return nil, "INVALID_CHECKPOINT", "checkpoint must be one of: " .. table.concat(M.CHECKPOINTS, ", ")
    end
    local subject_ref, ok_ref = M.subject_ref(body.subject_ref)
    if not ok_ref then return nil, "INVALID_SUBJECT", "subject_ref must be up to 64 letters, digits, . _ : -" end

    local docs = body.documents
    if type(docs) ~= "table" or #docs == 0 then return nil, "NO_DOCUMENTS", "documents must list at least one document" end
    if #docs > M.MAX_DOCUMENTS then return nil, "TOO_MANY_DOCUMENTS", "At most " .. M.MAX_DOCUMENTS .. " documents" end

    local out, seen = {}, {}
    for i, d in ipairs(docs) do
        if type(d) ~= "table" then return nil, "INVALID_DOCUMENT", "documents[" .. i .. "] must be an object" end
        local key = M.key(d.key)
        if not key then return nil, "INVALID_DOCUMENT", "documents[" .. i .. "].key is invalid" end
        local version = M.version(d.version)
        if not version then return nil, "INVALID_DOCUMENT", "documents[" .. i .. "].version is invalid" end
        local hash, ok_hash = M.hash(d.hash)
        if not ok_hash then return nil, "INVALID_DOCUMENT", "documents[" .. i .. "].hash must be a sha256 hex digest" end
        local statement = trim(d.statement)
        if not statement then return nil, "INVALID_DOCUMENT", "documents[" .. i .. "].statement is required" end
        if #statement > M.MAX_STATEMENT then statement = statement:sub(1, M.MAX_STATEMENT) end
        local dedupe = key .. "\0" .. statement
        if not seen[dedupe] then
            seen[dedupe] = true
            out[#out + 1] = { key = key, version = version, hash = hash, statement = statement }
        end
    end

    local ip = trim(body.ip)
    if ip and (#ip > 64 or not ip:match("^[%x%.:]+$")) then ip = nil end
    local ua = trim(body.user_agent)
    if ua and #ua > M.MAX_UA then ua = ua:sub(1, M.MAX_UA) end

    return {
        email = email,
        checkpoint = checkpoint,
        subject_ref = subject_ref,
        ip = ip,
        user_agent = ua,
        documents = out,
    }
end

--- Latest acceptance per document key from rows ordered newest first (or any order).
--- rows: { {document_key, document_version, content_hash, checkpoint, created_at}, … }
function M.latest(rows)
    local out = {}
    for _, r in ipairs(rows or {}) do
        local cur = out[r.document_key]
        if not cur or tostring(r.created_at) > tostring(cur.accepted_at) then
            out[r.document_key] = {
                version = r.document_version,
                hash = r.content_hash,
                checkpoint = r.checkpoint,
                accepted_at = r.created_at,
            }
        end
    end
    return out
end

return M
