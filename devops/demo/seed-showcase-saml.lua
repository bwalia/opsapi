--[[
    Showcase demo: connect the `showcase` workspace to the demo SAML IdP
    (devops/k8s/mock-saml-idp.yaml, https://saml-idp.demo.opsapi.org).

    Visitors choose "Sign in with SSO", type any address at example.com or
    example.org, and land in the showcase as a read-only `viewer`.

    Reads the IdP metadata from /tmp/idp-metadata.xml (the deploy workflow
    fetches it in-cluster). Idempotent: creates the provider once, then keeps
    its certificate / URLs in step with the IdP's metadata.

    Run inside an opsapi-showcase pod:
        cd /app && lapis exec 'assert(loadfile("/tmp/seed-showcase-saml.lua"))()'
]]

local db = require("lapis.db")
local SP = require("lib.saml.sp")
local Q = require("queries.SamlProviderQueries")

local NAME = "Demo IdP (Mock SAML)"

local ns = assert(db.select("id FROM namespaces WHERE slug = 'showcase'")[1], "showcase workspace missing")
local h = assert(io.open("/tmp/idp-metadata.xml", "rb"), "no /tmp/idp-metadata.xml")
local xml = h:read("*a")
h:close()
local md = assert(SP.parse_idp_metadata(xml))

local fields = {
    name = NAME,
    idp_entity_id = md.idp_entity_id,
    idp_sso_url = md.idp_sso_url,
    idp_x509_cert = md.idp_x509_cert,
    email_domains = "example.com,example.org",
    default_role = "viewer",
    auto_provision = true,
    allow_idp_initiated = false,
    is_enabled = true,
}

local existing = db.select("uuid FROM saml_providers WHERE namespace_id = ? AND name = ?", ns.id, NAME)[1]
local p, err
if existing then
    p, err = Q.update(ns.id, existing.uuid, fields)
else
    p, err = Q.create(ns.id, fields)
end
assert(p, err)
print(string.format("[showcase-saml] %s provider %s -> %s (role viewer, domains %s)",
    existing and "updated" or "created", p.uuid, p.idp_sso_url, table.concat(p.email_domains, ",")))
