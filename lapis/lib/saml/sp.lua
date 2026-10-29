--[[
    SAML 2.0 service provider (Web Browser SSO profile)
    ===================================================
    Pure protocol logic, no database: build the AuthnRequest, SP metadata, read
    IdP metadata, and validate a SAML Response against a provider's settings.
    routes/saml.lua does the HTTP and the account side.

    Validation (validate_response) refuses unless ALL of these hold:
      - status Success, Destination (if present) is our ACS URL;
      - no EncryptedAssertion, exactly one Assertion directly under the Response;
      - a valid signature from the configured IdP certificate on the Response or
        the Assertion (lib/saml/xml.lua), and no invalid one on either;
      - Issuer is the IdP entity ID; Audience includes our SP entity ID;
      - Conditions and the bearer SubjectConfirmationData are in their time
        window (3 min skew) with Recipient = our ACS URL;
      - InResponseTo matches the request we sent, or, with no request,
        the provider allows IdP-initiated sign-in and the message claims none.
    The caller still has to reject a replayed assertion ID (single use).
]]

local XML = require("lib.saml.xml")

local M = {}

local CLOCK_SKEW = 180
local BEARER = "urn:oasis:names:tc:SAML:2.0:cm:bearer"
local SUCCESS = "urn:oasis:names:tc:SAML:2.0:status:Success"
local NAMEID_EMAIL = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"

local function xml_escape(s)
    return (tostring(s):gsub("[&<>\"']", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&apos;",
    }))
end

--- xs:dateTime (UTC, optional fraction, Z or +00:00) -> epoch seconds.
function M.parse_time(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, sec, rest = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
    if not y then return nil end
    rest = rest:gsub("^%.%d+", "")
    local offset = 0
    if rest ~= "Z" and rest ~= "" then
        local sign, oh, om = rest:match("^([+-])(%d%d):(%d%d)$")
        if not sign then return nil end
        offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "+" and 1 or -1)
    end
    y, mo = tonumber(y), tonumber(mo)
    -- days from civil (Howard Hinnant), independent of the server's timezone
    local yy = mo <= 2 and y - 1 or y
    local era = math.floor(yy / 400)
    local yoe = yy - era * 400
    local mp = (mo + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + tonumber(d) - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec) - offset
end

local function iso_now(t)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", t or ngx.time())
end

function M.new_id()
    local bytes = require("resty.openssl.rand").bytes(20)
    return "_" .. (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

--- AuthnRequest for the HTTP-Redirect binding: returns the IdP URL to send the
-- browser to, and the request ID to remember for InResponseTo.
function M.authn_redirect_url(p)
    local id = M.new_id()
    local xml = string.format(
        '<samlp:AuthnRequest xmlns:samlp="%s" xmlns:saml="%s" ID="%s" Version="2.0" IssueInstant="%s"'
        .. ' Destination="%s" AssertionConsumerServiceURL="%s"'
        .. ' ProtocolBinding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST">'
        .. '<saml:Issuer>%s</saml:Issuer>'
        .. '<samlp:NameIDPolicy Format="%s" AllowCreate="true"/>'
        .. '</samlp:AuthnRequest>',
        XML.NS.samlp, XML.NS.saml, id, iso_now(), xml_escape(p.idp_sso_url), xml_escape(p.acs_url),
        xml_escape(p.sp_entity_id), p.name_id_format or NAMEID_EMAIL)

    -- HTTP-Redirect binding: raw DEFLATE, base64, URL-encode.
    local zlib = require("ffi-zlib")
    local chunks, pos = {}, 1
    local ok, err = zlib.deflateGzip(function(size)
        local piece = xml:sub(pos, pos + size - 1)
        pos = pos + size
        return piece ~= "" and piece or nil
    end, function(data) chunks[#chunks + 1] = data end, 16384, { windowBits = -15 })
    if not ok then return nil, nil, "could not encode the sign-in request: " .. tostring(err) end

    local query = "SAMLRequest=" .. ngx.escape_uri(ngx.encode_base64(table.concat(chunks)))
    if p.relay_state then query = query .. "&RelayState=" .. ngx.escape_uri(p.relay_state) end
    local sep = p.idp_sso_url:find("?", 1, true) and "&" or "?"
    return p.idp_sso_url .. sep .. query, id
end

--- SP metadata XML for a provider.
function M.metadata(p)
    return string.format([[<?xml version="1.0" encoding="UTF-8"?>
<md:EntityDescriptor xmlns:md="%s" entityID="%s">
  <md:SPSSODescriptor AuthnRequestsSigned="false" WantAssertionsSigned="true"
      protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">
    <md:NameIDFormat>%s</md:NameIDFormat>
    <md:AssertionConsumerService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
        Location="%s" index="0" isDefault="true"/>
  </md:SPSSODescriptor>
</md:EntityDescriptor>
]], XML.NS.md, xml_escape(p.sp_entity_id), NAMEID_EMAIL, xml_escape(p.acs_url))
end

--- Read the fields we need out of IdP metadata XML.
-- @return { idp_entity_id, idp_sso_url, idp_x509_cert } | nil, reason
function M.parse_idp_metadata(xml)
    local doc, err = XML.parse(xml)
    if not doc then return nil, err end
    local root = doc:root()
    local ed = XML.is(root, "md", "EntityDescriptor") and root
        or doc:one("md:EntityDescriptor[md:IDPSSODescriptor]")
    if not ed then return nil, "no EntityDescriptor with an IDPSSODescriptor" end
    local idp = doc:one("md:IDPSSODescriptor", ed)
    if not idp then return nil, "the metadata is not for an identity provider" end

    local sso = doc:one("md:SingleSignOnService[@Binding='urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect']", idp)
    local cert = doc:text("md:KeyDescriptor[@use='signing' or not(@use)]/ds:KeyInfo/ds:X509Data/ds:X509Certificate",
        idp)
    local out = {
        idp_entity_id = XML.attr(ed, "entityID"),
        idp_sso_url = sso and XML.attr(sso, "Location"),
        idp_x509_cert = cert and XML.pem(cert),
    }
    if not out.idp_sso_url then
        return nil, "the IdP has no HTTP-Redirect SingleSignOnService"
    end
    if not out.idp_entity_id or not out.idp_x509_cert then
        return nil, "the metadata has no entityID or signing certificate"
    end
    return out
end

local function fail(msg) return nil, msg end

--- Validate a base64 SAMLResponse.
-- @param p { idp_entity_id, idp_x509_cert, sp_entity_id, acs_url, request_id?, allow_idp_initiated? }
-- @return { assertion_id, name_id, name_id_format, session_index, expires_at, attributes } | nil, reason
function M.validate_response(b64_response, p, now)
    now = now or ngx.time()
    if type(b64_response) ~= "string" or b64_response == "" then return fail("missing SAMLResponse") end
    local xml = ngx.decode_base64((b64_response:gsub("%s+", "")))
    if not xml then return fail("SAMLResponse is not base64") end

    local doc, perr = XML.parse(xml)
    if not doc then return fail("unreadable SAMLResponse: " .. perr) end
    local response = doc:root()
    if not XML.is(response, "samlp", "Response") then return fail("not a SAML Response") end

    local status = XML.attr(doc:one("samlp:Status/samlp:StatusCode", response), "Value")
    if status ~= SUCCESS then
        local sub = XML.attr(doc:one("samlp:Status/samlp:StatusCode/samlp:StatusCode", response), "Value")
        local msg = doc:text("samlp:Status/samlp:StatusMessage", response)
        return fail("the identity provider refused the sign-in (" .. tostring(sub or status)
            .. (msg and (": " .. msg) or "") .. ")")
    end

    local destination = XML.attr(response, "Destination")
    if destination and destination ~= p.acs_url then return fail("Response Destination is not this service") end
    if #doc:find("//saml:EncryptedAssertion") > 0 then
        return fail("encrypted assertions are not supported; turn off assertion encryption at the IdP")
    end
    local assertions = doc:find("saml:Assertion", response)
    if #assertions ~= 1 or #doc:find("//saml:Assertion") ~= 1 then
        return fail("expected exactly one Assertion")
    end
    local assertion = assertions[1]

    -- Signatures: at least one valid, none invalid.
    local cert = XML.pem(p.idp_x509_cert)
    if not cert then return fail("the provider has no valid IdP certificate") end
    local signed = false
    for _, node in ipairs({ response, assertion }) do
        local ok, why = doc:verify(node, cert)
        if ok then
            signed = true
        elseif why ~= "absent" then
            return fail("invalid signature: " .. why)
        end
    end
    if not signed then return fail("the Response is not signed") end
    if #doc:find("//ds:Signature") > 2 then return fail("unexpected extra signatures") end

    -- Issuers
    local resp_issuer = doc:text("saml:Issuer", response)
    if resp_issuer and resp_issuer ~= p.idp_entity_id then return fail("Response Issuer is not this IdP") end
    if doc:text("saml:Issuer", assertion) ~= p.idp_entity_id then return fail("Assertion Issuer is not this IdP") end

    -- InResponseTo (solicited vs IdP-initiated)
    local resp_irt = XML.attr(response, "InResponseTo")
    if p.request_id then
        if resp_irt and resp_irt ~= p.request_id then return fail("Response is for a different sign-in request") end
    else
        if resp_irt then return fail("sign-in request expired or was started in another browser") end
        if not p.allow_idp_initiated then
            return fail("sign-in must start from OpsAPI (IdP-initiated sign-in is off for this provider)")
        end
    end

    -- Conditions
    local cond = doc:one("saml:Conditions", assertion)
    if not cond then return fail("Assertion has no Conditions") end
    local nb = M.parse_time(XML.attr(cond, "NotBefore"))
    local noa = M.parse_time(XML.attr(cond, "NotOnOrAfter"))
    if nb and now + CLOCK_SKEW < nb then return fail("Assertion is not yet valid") end
    if noa and now - CLOCK_SKEW >= noa then return fail("Assertion has expired") end
    local audience_ok = false
    for _, a in ipairs(doc:find("saml:AudienceRestriction/saml:Audience", cond)) do
        if doc:text(".", a) == p.sp_entity_id then audience_ok = true end
    end
    if not audience_ok then return fail("Assertion is not addressed to this service (Audience)") end

    -- Subject + bearer confirmation
    local subject = doc:one("saml:Subject", assertion)
    local name_id_node = subject and doc:one("saml:NameID", subject)
    if not name_id_node then return fail("Assertion has no NameID") end
    local confirmed = false
    for _, sc in ipairs(doc:find("saml:SubjectConfirmation[@Method='" .. BEARER .. "']", subject)) do
        local scd = doc:one("saml:SubjectConfirmationData", sc)
        local recipient = XML.attr(scd, "Recipient")
        local exp = M.parse_time(XML.attr(scd, "NotOnOrAfter"))
        local irt = XML.attr(scd, "InResponseTo")
        if recipient == p.acs_url and exp and now - CLOCK_SKEW < exp
            and (p.request_id and irt == p.request_id or (not p.request_id and not irt)) then
            confirmed = true
            noa = noa and math.min(noa, exp) or exp
        end
    end
    if not confirmed then return fail("no valid bearer SubjectConfirmation for this service") end

    local attributes = {}
    for _, attr in ipairs(doc:find("saml:AttributeStatement/saml:Attribute", assertion)) do
        local values = {}
        for _, v in ipairs(doc:find("saml:AttributeValue", attr)) do values[#values + 1] = doc:text(".", v) end
        for _, key in ipairs({ XML.attr(attr, "Name"), XML.attr(attr, "FriendlyName") }) do
            if key and key ~= "" then attributes[key] = values end
        end
    end

    return {
        assertion_id = XML.attr(assertion, "ID"),
        name_id = doc:text(".", name_id_node),
        name_id_format = XML.attr(name_id_node, "Format"),
        session_index = XML.attr(doc:one("saml:AuthnStatement", assertion), "SessionIndex"),
        expires_at = noa or (now + 300),
        attributes = attributes,
    }
end

local DEFAULT_ATTRS = {
    email = { "email", "mail", "emailAddress", "Email",
        "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress", "urn:oid:0.9.2342.19200300.100.1.3" },
    first_name = { "firstName", "givenName", "given_name", "FirstName",
        "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname", "urn:oid:2.5.4.42" },
    last_name = { "lastName", "sn", "surname", "family_name", "LastName",
        "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname", "urn:oid:2.5.4.4" },
}

--- Email / names from a validated assertion. `mapping` ({ email = "attr", … })
-- overrides the usual attribute names.
function M.profile(result, mapping)
    mapping = type(mapping) == "table" and mapping or {}
    local function pick(field)
        local names = {}
        if type(mapping[field]) == "string" and mapping[field] ~= "" then names[1] = mapping[field] end
        for _, n in ipairs(DEFAULT_ATTRS[field]) do names[#names + 1] = n end
        for _, n in ipairs(names) do
            local v = result.attributes[n]
            if v and v[1] and v[1] ~= "" then return v[1] end
        end
    end
    local email = pick("email")
    if not email and result.name_id and result.name_id:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then
        email = result.name_id
    end
    return {
        email = email and email:lower(),
        first_name = pick("first_name") or "",
        last_name = pick("last_name") or "",
    }
end

return M
