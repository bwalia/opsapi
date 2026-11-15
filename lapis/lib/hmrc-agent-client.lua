-- HMRC Agent Authorisation API 1.0 client (VAT plan phase 8, docs/plans/VAT_MTD.md).
--
-- An accountant (an "agent" with an Agent Reference Number, ARN) asks a client for
-- authority to deal with their VAT; the client accepts on HMRC's site; then HMRC's
-- relationship check confirms the agent may act (and the agent's own HMRC token can
-- call the VAT API for that client's VRN).
--
--   create invitation   POST   /agents/{arn}/invitations          -> 204 + Location
--   get invitation      GET    /agents/{arn}/invitations/{id}
--   cancel invitation   DELETE /agents/{arn}/invitations/{id}       -> 204
--   check relationship  POST   /agents/{arn}/relationships          -> 204 (authorised) | 404
--
-- Scopes: read:sent-invitations write:sent-invitations write:cancel-invitations
-- read:check-relationship (connect with /auth/hmrc/initiate?purpose=vat_agent).

local cjson = require("cjson")
local HMRC = require("helper.hmrc")

local Client = {}

local function environment() return os.getenv("HMRC_ENVIRONMENT") or "sandbox" end
function Client.is_sandbox() return environment() ~= "production" end
local function base_url()
    return Client.is_sandbox() and "https://test-api.service.hmrc.gov.uk" or "https://api.service.hmrc.gov.uk"
end

Client._http = nil -- specs replace the HTTP layer

local function http_client()
    if Client._http then return Client._http end
    local ok, http = pcall(require, "resty.http")
    if not ok then return nil, "resty.http not available" end
    local c = http.new()
    c:set_timeout(30000)
    return c
end

local function decode(body)
    if not body or body == "" then return {} end
    local ok, t = pcall(cjson.decode, body)
    return (ok and type(t) == "table") and t or {}
end

--- Is this an Agent Reference Number (e.g. AARN1234567)?
function Client.valid_arn(arn)
    return type(arn) == "string" and arn:match("^[A-Z]ARN%d%d%d%d%d%d%d$") ~= nil
end

local function call(method, path, token, body)
    local httpc, err = http_client()
    if not httpc then return nil, err end
    local h = HMRC.build_fraud_headers()
    h["Authorization"] = "Bearer " .. token
    h["Accept"] = "application/vnd.hmrc.1.0+json"
    if body then h["Content-Type"] = "application/json" end
    local res, rerr = httpc:request_uri(base_url() .. path, {
        method = method, body = body and cjson.encode(body) or nil, headers = h, ssl_verify = true })
    if not res then return nil, method .. " " .. path .. " failed: " .. tostring(rerr) end
    return res
end

local function fail(res)
    local b = decode(res.body)
    return nil, "HTTP " .. res.status, b, res.status
end

--- The body for MTD VAT: the client's VRN, and their VAT registration date as proof.
function Client.vat_request(vrn, vat_registration_date)
    return { service = { "MTD-VAT" }, clientType = "business", clientIdType = "vrn", clientId = vrn,
        knownFact = vat_registration_date }
end

--- Ask a client for authority. @return invitation id (from the Location header)
function Client.create_invitation(token, arn, vrn, vat_registration_date)
    if not Client.valid_arn(arn) then return nil, "Invalid Agent Reference Number" end
    local res, err = call("POST", "/agents/" .. arn .. "/invitations", token,
        Client.vat_request(vrn, vat_registration_date))
    if not res then return nil, err end
    if res.status ~= 204 and res.status ~= 201 then return fail(res) end
    local loc = res.headers and (res.headers["Location"] or res.headers["location"]) or ""
    local id = tostring(loc):match("/invitations/([%w]+)$")
    if not id then return nil, "HMRC didn't return the request's location" end
    return id
end

--- The request's status (Pending / Accepted / Rejected / Expired / Cancelled) and the
-- link the client opens to accept.
function Client.get_invitation(token, arn, id)
    local res, err = call("GET", "/agents/" .. arn .. "/invitations/" .. id, token)
    if not res then return nil, err end
    if res.status ~= 200 then return fail(res) end
    return decode(res.body)
end

function Client.cancel_invitation(token, arn, id)
    local res, err = call("DELETE", "/agents/" .. arn .. "/invitations/" .. id, token)
    if not res then return nil, err end
    if res.status ~= 204 then return fail(res) end
    return true
end

--- Is the agent authorised for this client's VAT? @return true | false | nil, err
function Client.check_relationship(token, arn, vrn, vat_registration_date)
    local body = Client.vat_request(vrn, vat_registration_date)
    body.clientType = nil
    local res, err = call("POST", "/agents/" .. arn .. "/relationships", token, body)
    if not res then return nil, err end
    if res.status == 204 then return true end
    if res.status == 404 then return false end
    return fail(res)
end

Client.ERRORS = {
    AGENT_NOT_SUBSCRIBED = "Your HMRC sign-in isn't an agent services account.",
    NOT_AN_AGENT = "Your HMRC sign-in isn't an agent services account.",
    NO_PERMISSION_ON_AGENCY = "That Agent Reference Number doesn't belong to your HMRC sign-in.",
    CLIENT_REGISTRATION_NOT_FOUND = "HMRC has no VAT registration for that VAT number.",
    VAT_REG_DATE_DOES_NOT_MATCH = "The VAT registration date doesn't match HMRC's records.",
    DUPLICATE_AUTHORISATION_REQUEST = "There's already a request waiting for this client.",
    ALREADY_AUTHORISED = "You're already authorised for this client.",
    VAT_CLIENT_INSOLVENT = "HMRC can't authorise an agent for an insolvent business here.",
    RESOURCE_FORBIDDEN = "The HMRC application isn't subscribed to the Agent Authorisation API.",
}

function Client.explain(body)
    local code = type(body) == "table" and body.code or nil
    local msg = (code and Client.ERRORS[code]) or (type(body) == "table" and body.message)
    return msg or "HMRC refused the request.", code
end

return Client
