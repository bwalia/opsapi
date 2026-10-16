--[[
    ATS — interview packs: a role's kit, decks and media for the Snazzy Pro app,
    encrypted on the recruiter's Mac and stored once in S3, so any number of
    candidates can be invited to it at the same time.

      1. The recruiter's app makes a random 256-bit key, encrypts the pack
         (AES-256-GCM), and calls create() with its size, SHA-256 and the key.
         It gets a signed S3 upload link (PUT, one object, 1 hour) and uploads.
      2. complete() checks the object is there and marks the pack ready.
      3. Invites name the pack. The candidate's app redeems its invite link
         (for_invite): the link is the credential, no passcode. OpsAPI returns
         a signed download link (15 minutes) and the key, only while the invite
         is valid, the workspace is active and the interview isn't finished.
         The first device to redeem keeps the invite: a forwarded link fails.

    The key is stored sealed (helper/secret-box, purpose "ats_pack"); S3 only
    ever holds ciphertext, so a leaked bucket or download link reveals nothing.
]]

local db = require("lapis.db")
local J = require("lib.ats.json")
local T = require("lib.ats.text")
local Hash = require("lib.ats.hash")
local Activation = require("lib.ats.activation")
local Q = require("queries.AtsQueries")

local P = {}

P.UPLOAD_SECONDS = 3600
P.DOWNLOAD_SECONDS = 900
P.KEY_PURPOSE = "ats_pack"

--- The largest pack (bytes): ATS_PACK_MAX_MB, 2 GB by default.
function P.max_bytes()
    return (tonumber(os.getenv("ATS_PACK_MAX_MB")) or 2048) * 1024 * 1024
end

local function v(x) return J.val(x) end

local function storage()
    local ok, Minio = pcall(require, "helper.minio")
    if not ok then return nil end
    local client = Minio.getDefault()
    if not client or not client:validate() then return nil end
    return client
end

local function out(r)
    return { uuid = r.uuid, title = r.title, size_bytes = tonumber(r.size_bytes), sha256 = r.sha256,
        status = r.status, created_at = r.created_at, updated_at = r.updated_at }
end

--- A 32-byte key as base64 (standard or URL-safe), or nil.
function P.decode_key(text)
    if type(text) ~= "string" or #text > 64 then return nil end
    local raw = ngx.decode_base64((text:gsub("-", "+"):gsub("_", "/")))
    if not raw or #raw ~= 32 then return nil end
    return raw
end

--- Validates a create request. @return fields | nil, err
function P.validate(data)
    local title = T.trim(v(data.title) or "")
    if title == "" or T.len(title) > 200 then return nil, "Give the pack a title (200 characters at most)." end
    local size = tonumber(v(data.size_bytes))
    if not size or size < 1 or size % 1 ~= 0 then return nil, "size_bytes must be the pack's size in bytes." end
    if size > P.max_bytes() then
        return nil, ("The pack is too big (%d MB at most)."):format(P.max_bytes() / 1024 / 1024)
    end
    local sha = type(data.sha256) == "string" and data.sha256:lower() or ""
    if not sha:match("^" .. ("%x"):rep(64) .. "$") then return nil, "sha256 must be 64 hex characters." end
    if not P.decode_key(data.key) then return nil, "key must be a 256-bit key, base64 encoded." end
    return { title = title, size = size, sha256 = sha, key = data.key }
end

function P.row(namespace_id, uuid)
    return db.select("* FROM ats_packs WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL",
        namespace_id, tostring(uuid or ""))[1]
end

--- Starts a pack. @return {uuid, upload_url, expires_in, ...} | nil, err, status
function P.create(namespace_id, data, actor)
    local blocked = Activation.require_active(namespace_id)
    if blocked then return nil, blocked.json and blocked.json.error or Activation.LAPSED_MESSAGE, 402 end
    local f, err = P.validate(data)
    if not f then return nil, err end
    local kit_id
    if v(data.kit_uuid) then
        local kit = Q.kit_row(namespace_id, data.kit_uuid)
        if not kit then return nil, "Kit not found" end
        kit_id = kit.id
    end
    local client = storage()
    if not client then return nil, "File storage isn't available.", 503 end
    local object_key = ("ats/%d/packs/%s.snzpack"):format(namespace_id, Hash.random_token())
    local r = db.insert("ats_packs", { namespace_id = namespace_id, kit_id = kit_id, title = f.title,
        object_key = object_key, size_bytes = f.size, sha256 = f.sha256,
        key_sealed = require("helper.secret-box").seal(f.key, P.KEY_PURPOSE), created_by_uuid = actor },
        { returning = "*" })[1]
    local url, uerr = client:getPresignedUrl(object_key, P.UPLOAD_SECONDS, nil, true, "PUT")
    if not url then return nil, tostring(uerr), 503 end
    Q.audit(namespace_id, actor, "pack_created", "pack", r.uuid, { title = f.title, size = f.size })
    local res = out(r)
    res.upload_url, res.upload_method, res.expires_in = url, "PUT", P.UPLOAD_SECONDS
    return res
end

--- After the upload: checks the object is in S3 and marks the pack ready.
function P.complete(namespace_id, uuid, actor)
    local r = P.row(namespace_id, uuid)
    if not r then return nil, "Pack not found" end
    if r.status ~= "ready" then
        local client = storage()
        if not client then return nil, "File storage isn't available.", 503 end
        if not client:exists(r.object_key) then return nil, "The pack hasn't been uploaded yet.", 409 end
        db.update("ats_packs", { status = "ready", updated_at = db.raw("NOW()") }, { id = r.id })
        Q.audit(namespace_id, actor, "pack_ready", "pack", r.uuid, {})
        r.status = "ready"
    end
    return out(r)
end

function P.list(namespace_id)
    local items = J.array({})
    for _, r in ipairs(db.select("* FROM ats_packs WHERE namespace_id = ? AND deleted_at IS NULL "
        .. "ORDER BY created_at DESC LIMIT 200", namespace_id)) do
        items[#items + 1] = out(r)
    end
    return items
end

--- Deletes the pack's file. Invites to it can no longer fetch it.
function P.delete(namespace_id, uuid, actor)
    local r = P.row(namespace_id, uuid)
    if not r then return nil, "Pack not found" end
    local client = storage()
    if client then pcall(client.delete, client, r.object_key) end
    db.update("ats_packs", { deleted_at = db.raw("NOW()"), key_sealed = "", updated_at = db.raw("NOW()") },
        { id = r.id })
    Q.audit(namespace_id, actor, "pack_deleted", "pack", r.uuid, {})
    return { deleted = true }
end

--- A ready pack's id for an invite, or nil, err.
function P.id_for_invite(namespace_id, uuid)
    if not v(uuid) then return nil end
    local r = P.row(namespace_id, uuid)
    if not r then return nil, "Pack not found" end
    if r.status ~= "ready" then return nil, "The pack isn't uploaded yet." end
    return r.id
end

--- The candidate's app redeems its invite: a download link and the key.
-- @param r the interview row (by link token), finished tells whether it ended
-- @return {url, key, sha256, size_bytes, title, expires_in} | nil, err, status
function P.for_invite(r, device_id, finished)
    if not v(r.pack_id) then return nil, "This interview has no pack: open the link in a browser instead.", 404 end
    if finished then return nil, "This interview has finished.", 410 end
    if type(device_id) ~= "string" or #device_id < 16 or #device_id > 200 then
        return nil, "Send this device's id.", 400
    end
    if not Activation.is_active(r.namespace_id) then
        return nil, "This interview can't start right now. Please contact the hiring team.", 402
    end
    local pack = db.select("* FROM ats_packs WHERE id = ? AND deleted_at IS NULL", r.pack_id)[1]
    if not pack or pack.status ~= "ready" then
        return nil, "The interview pack isn't available. Please contact the hiring team.", 404
    end
    -- One invite, one device: the first to redeem keeps it.
    local hash = Hash.sha256_hex("ats-device|" .. device_id)
    local bound = v(r.device_hash)
    if not bound then
        db.query("UPDATE ats_interviews SET device_hash = ? WHERE id = ? AND device_hash IS NULL", hash, r.id)
        bound = db.select("device_hash FROM ats_interviews WHERE id = ?", r.id)[1].device_hash
    end
    if not require("lib.stripe")._secure_compare(bound or "", hash) then
        return nil, "This invite is already in use on another device. Ask the hiring team for a new link.", 403
    end
    local key, kerr = require("helper.secret-box").open(pack.key_sealed, P.KEY_PURPOSE)
    if not key then
        ngx.log(ngx.ERR, "[ats] pack key could not be opened: ", tostring(kerr))
        return nil, "The interview pack isn't available. Please contact the hiring team.", 503
    end
    local client = storage()
    if not client then return nil, "File storage isn't available.", 503 end
    local url, uerr = client:getPresignedUrl(pack.object_key, P.DOWNLOAD_SECONDS, nil, true)
    if not url then return nil, tostring(uerr), 503 end
    db.query("UPDATE ats_interviews SET pack_fetched_at = NOW() WHERE id = ?", r.id)
    Q.audit(r.namespace_id, "candidate", "pack_fetched", "interview", r.uuid, { pack = pack.uuid })
    return { url = url, key = key, sha256 = pack.sha256, size_bytes = tonumber(pack.size_bytes), title = pack.title,
        expires_in = P.DOWNLOAD_SECONDS, cipher = "AES-256-GCM" }
end

--- Lets the invite be redeemed on another device (the recruiter's call).
function P.release_device(namespace_id, interview_uuid, actor)
    local r = db.select("id, uuid FROM ats_interviews WHERE namespace_id = ? AND uuid = ?", namespace_id,
        tostring(interview_uuid or ""))[1]
    if not r then return nil, "Interview not found" end
    db.update("ats_interviews", { device_hash = db.NULL }, { id = r.id })
    Q.audit(namespace_id, actor, "pack_device_released", "interview", r.uuid, {})
    return { released = true }
end

return P
