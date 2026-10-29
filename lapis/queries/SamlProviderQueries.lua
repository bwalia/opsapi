--[[
    SAML identity providers of a workspace (migrations/saml-sso.lua)
    Every read/write is scoped by namespace_id; the IdP certificate is stored
    as PEM and validated (it must parse as an X.509 certificate).
]]

local db = require("lapis.db")
local cjson = require("cjson.safe")
local XML = require("lib.saml.xml")

local Q = {}

local COLUMNS = [[id, uuid, namespace_id, name, idp_entity_id, idp_sso_url, idp_x509_cert, email_domains,
    default_role, auto_provision, allow_idp_initiated, attribute_mapping, is_enabled, last_login_at,
    login_count, created_at, updated_at]]

local function normalize_domains(raw)
    if type(raw) == "table" then raw = table.concat(raw, ",") end
    if type(raw) ~= "string" then return "" end
    local out, seen = {}, {}
    for d in raw:lower():gmatch("[^,%s]+") do
        d = d:gsub("^@", "")
        if d:match("^[%w%-]+%.[%w%.%-]+$") and not seen[d] then
            seen[d] = true
            out[#out + 1] = d
        end
    end
    return table.concat(out, ",")
end

local function shape(row)
    if not row then return nil end
    if type(row.attribute_mapping) == "string" then
        row.attribute_mapping = cjson.decode(row.attribute_mapping) or {}
    end
    local domains = setmetatable({}, cjson.array_mt)
    for d in (row.email_domains or ""):gmatch("[^,]+") do domains[#domains + 1] = d end
    row.email_domains = domains
    for _, k in ipairs({ "default_role", "last_login_at" }) do
        if row[k] == db.NULL then row[k] = nil end
    end
    return row
end

local function is_url(s)
    return type(s) == "string" and s:match("^https?://[^%s]+$") ~= nil
end

-- Validate + coerce an admin payload. `partial` for updates.
local function clean(body, partial)
    local out = {}
    local function str(k, max)
        local v = body[k]
        if v == nil then return end
        if type(v) ~= "string" then return k .. " must be text" end
        v = v:gsub("^%s+", ""):gsub("%s+$", "")
        if #v > (max or 2048) then return k .. " is too long" end
        out[k] = v
    end
    for _, k in ipairs({ "name", "idp_entity_id", "idp_sso_url", "default_role" }) do
        local err = str(k, k == "name" and 255 or 2048)
        if err then return nil, err end
    end
    if body.idp_x509_cert ~= nil then
        local pem = XML.pem(body.idp_x509_cert)
        local ok = pem and require("resty.openssl.x509").new(pem)
        if not ok then return nil, "IdP certificate is not a valid X.509 certificate" end
        out.idp_x509_cert = pem
    end
    if body.email_domains ~= nil then out.email_domains = normalize_domains(body.email_domains) end
    for _, k in ipairs({ "auto_provision", "allow_idp_initiated", "is_enabled" }) do
        if body[k] ~= nil then out[k] = body[k] == true or body[k] == "true" end
    end
    if body.attribute_mapping ~= nil then
        if type(body.attribute_mapping) ~= "table" then return nil, "attribute_mapping must be an object" end
        local m = {}
        for _, k in ipairs({ "email", "first_name", "last_name" }) do
            local v = body.attribute_mapping[k]
            if type(v) == "string" and v ~= "" then m[k] = v:sub(1, 512) end
        end
        out.attribute_mapping = db.raw(db.escape_literal(cjson.encode(m)) .. "::jsonb")
    end
    if out.default_role == "" then out.default_role = db.NULL end

    if not partial then
        if not out.name or out.name == "" then return nil, "Give the provider a name" end
        if not out.idp_entity_id or out.idp_entity_id == "" then return nil, "IdP entity ID is required" end
        if not out.idp_x509_cert then return nil, "IdP signing certificate is required" end
    end
    if out.idp_sso_url ~= nil and not is_url(out.idp_sso_url) then
        return nil, "IdP sign-in URL must be an http(s) URL"
    end
    if not partial and not out.idp_sso_url then return nil, "IdP sign-in URL is required" end
    if out.name == "" then return nil, "Give the provider a name" end
    return out
end

local function check_role(namespace_id, role)
    if type(role) ~= "string" or role == "" then return true end
    return #db.select("1 FROM namespace_roles WHERE namespace_id = ? AND role_name = ?", namespace_id, role) > 0
end

function Q.list(namespace_id)
    local rows = db.select(COLUMNS .. " FROM saml_providers WHERE namespace_id = ? ORDER BY created_at", namespace_id)
    local out = setmetatable({}, cjson.array_mt)
    for _, r in ipairs(rows) do out[#out + 1] = shape(r) end
    return out
end

function Q.find(namespace_id, uuid)
    return shape(db.select(COLUMNS .. " FROM saml_providers WHERE namespace_id = ? AND uuid = ?",
        namespace_id, tostring(uuid))[1])
end

--- An enabled provider by uuid, any workspace (the public sign-in endpoints).
function Q.findPublic(uuid)
    if type(uuid) ~= "string" or not uuid:match("^[%w%-]+$") then return nil end
    return shape(db.select(COLUMNS .. " FROM saml_providers WHERE uuid = ? AND is_enabled = true", uuid)[1])
end

--- Enabled providers that claim an email's domain.
function Q.findByEmailDomain(domain)
    domain = type(domain) == "string" and domain:lower() or ""
    if domain == "" then return {} end
    local rows = db.query([[
        SELECT p.uuid, p.name, n.name AS namespace_name, n.slug AS namespace_slug
        FROM saml_providers p JOIN namespaces n ON n.id = p.namespace_id
        WHERE p.is_enabled = true AND ? = ANY(string_to_array(p.email_domains, ','))
        ORDER BY p.created_at
    ]], domain)
    return rows
end

--- Enabled providers of a workspace, by slug.
function Q.findByNamespaceSlug(slug)
    if type(slug) ~= "string" or slug == "" then return {} end
    return db.query([[
        SELECT p.uuid, p.name, n.name AS namespace_name, n.slug AS namespace_slug
        FROM saml_providers p JOIN namespaces n ON n.id = p.namespace_id
        WHERE p.is_enabled = true AND n.slug = ?
        ORDER BY p.created_at
    ]], slug)
end

function Q.create(namespace_id, body)
    local data, err = clean(body or {}, false)
    if not data then return nil, err end
    if not check_role(namespace_id, data.default_role) then return nil, "No role named " .. data.default_role end
    data.namespace_id = namespace_id
    local row = db.insert("saml_providers", data, "uuid")
    return Q.find(namespace_id, row[1].uuid)
end

function Q.update(namespace_id, uuid, body)
    if not Q.find(namespace_id, uuid) then return nil end
    local data, err = clean(body or {}, true)
    if not data then return nil, err end
    if not check_role(namespace_id, data.default_role) then return nil, "No role named " .. data.default_role end
    data.updated_at = db.raw("NOW()")
    db.update("saml_providers", data, { namespace_id = namespace_id, uuid = tostring(uuid) })
    return Q.find(namespace_id, uuid)
end

function Q.delete(namespace_id, uuid)
    local res = db.delete("saml_providers", { namespace_id = namespace_id, uuid = tostring(uuid) })
    return res and (res.affected_rows or 0) > 0
end

--- Mark an assertion ID as used. false when it was already used (replay).
function Q.consumeAssertion(provider_id, assertion_id, expires_at)
    db.query("DELETE FROM saml_used_assertions WHERE expires_at < NOW() - INTERVAL '1 hour'")
    local res = db.query([[
        INSERT INTO saml_used_assertions (assertion_id, provider_id, expires_at)
        VALUES (?, ?, to_timestamp(?) AT TIME ZONE 'UTC')
        ON CONFLICT (assertion_id) DO NOTHING
        RETURNING assertion_id
    ]], tostring(provider_id) .. ":" .. assertion_id, provider_id, expires_at)
    return res[1] ~= nil
end

local function sha256_hex(s)
    local d = require("resty.openssl.digest").new("sha256"):final(s)
    return (d:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

--- Park a signed-in token behind a one-time code (valid 2 minutes).
function Q.issueLoginCode(token)
    db.query("DELETE FROM saml_login_codes WHERE expires_at < NOW()")
    local raw = require("resty.openssl.rand").bytes(32)
    local code = (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end))
    db.query("INSERT INTO saml_login_codes (code_hash, token, expires_at) VALUES (?, ?, NOW() + INTERVAL '2 minutes')",
        sha256_hex(code), token)
    return code
end

--- Redeem a one-time code: the token, once; nil when unknown, used or expired.
function Q.redeemLoginCode(code)
    if type(code) ~= "string" or not code:match("^%x+$") or #code ~= 64 then return nil end
    local row = db.query([[
        DELETE FROM saml_login_codes WHERE code_hash = ? AND expires_at >= NOW() RETURNING token
    ]], sha256_hex(code))[1]
    return row and row.token or nil
end

function Q.recordLogin(provider_id)
    db.query("UPDATE saml_providers SET last_login_at = NOW(), login_count = login_count + 1 WHERE id = ?",
        provider_id)
end

return Q
