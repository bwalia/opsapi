-- luacheck: max line length 140
--[[
    Shop legal acceptances — ledger reads and writes (see migrations/shop-legal.lua, lib/shop-legal.lua).
]]

local db = require("lapis.db")
local U = require("lib.shop-util")
local L = require("lib.shop-legal")
local Global = require("helper.global")

local Q = {}

local COLS = [[uuid, email, document_key, document_version, content_hash, statement, checkpoint, subject_ref,
    client_ip, user_agent, created_at]]

--- Record one acceptance (several documents) in a single transaction.
--- body: see L.validate. Returns { recorded, accepted_at, uuids } | nil, err
function Q.record(ns_id, body)
    local rec, code, msg = L.validate(body)
    if not rec then return nil, U.err(400, code, msg) end
    local uuids, accepted_at = {}, nil
    U.tx(function()
        for _, d in ipairs(rec.documents) do
            local id = Global.generateUUID()
            local rows = db.query([[
                INSERT INTO shop_legal_acceptances (uuid, namespace_id, email, document_key, document_version, content_hash,
                    statement, checkpoint, subject_ref, client_ip, user_agent)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                RETURNING created_at
            ]], id, ns_id, rec.email, d.key, d.version, d.hash or db.NULL, d.statement, rec.checkpoint,
                rec.subject_ref or db.NULL, rec.ip or db.NULL, rec.user_agent or db.NULL)
            uuids[#uuids + 1] = id
            accepted_at = rows[1] and rows[1].created_at or accepted_at
        end
        return true
    end)
    return { recorded = #uuids, accepted_at = accepted_at, uuids = uuids, email = rec.email, checkpoint = rec.checkpoint }
end

--- The newest acceptance of each document for one email: { [document_key] = { version, hash, checkpoint, accepted_at } }.
function Q.latestForEmail(ns_id, email)
    email = L.email(email)
    if not email then return nil, U.err(400, "INVALID_EMAIL", "A valid email is required") end
    local rows = db.query([[
        SELECT DISTINCT ON (document_key) document_key, document_version, content_hash, checkpoint, created_at
        FROM shop_legal_acceptances
        WHERE namespace_id = ? AND lower(email) = ?
        ORDER BY document_key, created_at DESC, id DESC
    ]], ns_id, email)
    return { email = email, documents = L.latest(rows) }
end

--- Back office: every acceptance, newest first. ?q= (email) &document_key= &checkpoint= &subject_ref= &limit= &offset=
function Q.adminList(ns_id, params)
    params = params or {}
    local limit = U.clamp(U.int(params.limit, 25), 1, 200)
    local offset = math.max(0, U.int(params.offset, 0))
    local where, vals = { "namespace_id = ?" }, { ns_id }
    if U.nz(params.q) then
        where[#where + 1] = "email ILIKE ?"
        vals[#vals + 1] = "%" .. tostring(params.q):sub(1, 200):gsub("[%%_\\]", "\\%0") .. "%"
    end
    if U.nz(params.document_key) then
        where[#where + 1] = "document_key = ?"
        vals[#vals + 1] = tostring(params.document_key)
    end
    if U.nz(params.checkpoint) then
        where[#where + 1] = "checkpoint = ?"
        vals[#vals + 1] = tostring(params.checkpoint)
    end
    if U.nz(params.subject_ref) then
        where[#where + 1] = "subject_ref = ?"
        vals[#vals + 1] = tostring(params.subject_ref)
    end
    vals[#vals + 1] = limit
    vals[#vals + 1] = offset
    local rows = db.query("SELECT " .. COLS .. ", COUNT(*) OVER() AS total FROM shop_legal_acceptances WHERE "
        .. table.concat(where, " AND ") .. " ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?", unpack(vals))
    local total = rows[1] and tonumber(rows[1].total) or 0
    for _, r in ipairs(rows) do
        r.total = nil
        for _, k in ipairs({ "content_hash", "subject_ref", "client_ip", "user_agent" }) do
            if r[k] == nil then r[k] = U.null end
        end
    end
    return U.arr(rows), { total = total, limit = limit, offset = offset }
end

return Q
