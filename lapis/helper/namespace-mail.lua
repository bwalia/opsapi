--[[
    Workspace email (core) — docs/BILLING_ENTITLEMENTS.md §10
    ========================================================
    Each workspace can send through its own SMTP server (namespace_mail_settings;
    the password is stored encrypted) and override the subject and body of any
    built-in template (namespace_email_templates). Without its own server the
    deployment's SMTP (SMTP_* env) is used.

    Built-in templates are etlua files in views/emails (trusted code). A
    workspace's override uses {{placeholder}} substitution with HTML escaping,
    never code, so tenant-written templates can't run anything.
]]

local db = require("lapis.db")
local Global = require("helper.global")
local Mail = require("helper.mail")
local ProjectConfig = require("helper.project-config")

local NamespaceMail = {}

--- Every email a workspace can customise: its default subject, the etlua file
-- of its default body, the variables it can use, sample data for previews, and
-- the feature that sends it (hidden where that feature isn't deployed).
NamespaceMail.TEMPLATES = {
    ["billing.access_link"] = {
        name = "Billing: account link",
        feature = "billing",
        file = "billing_access_link",
        subject = "Your {{app_name}} account link",
        variables = { "app_name", "customer_email", "link", "expires_minutes", "support_email" },
        sample = { app_name = "Acme Desktop", customer_email = "you@example.com",
            link = "https://billing.example.com/b/app/account#token=sample", expires_minutes = 15,
            support_email = "support@example.com" },
    },
    ["billing.licence_key"] = {
        name = "Billing: licence key",
        feature = "billing",
        file = "billing_licence_key",
        subject = "Your {{app_name}} licence key",
        variables = { "app_name", "customer_email", "licence_key", "plan_name", "account_link", "support_email" },
        sample = { app_name = "Acme Desktop", customer_email = "you@example.com",
            licence_key = "ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2", plan_name = "Pro",
            account_link = "https://billing.example.com/b/app/account", support_email = "support@example.com" },
    },
}

-- ---------------------------------------------------------------------------
-- SMTP settings
-- ---------------------------------------------------------------------------

local function allow_private()
    return os.getenv("OPSAPI_MAIL_ALLOW_PRIVATE") == "true" or os.getenv("OPSAPI_WEBHOOKS_ALLOW_PRIVATE") == "true"
end

-- The SMTP host must be public (no SSRF into the cluster), checked again on
-- every send because DNS can change.
local function host_ok(host)
    if allow_private() then return true end
    local Webhooks = require("lib.outbound-webhooks")
    if host == "localhost" or host:match("%.local$") or host:match("%.internal$") or host:match("%.svc$")
        or not host:find(".", 1, true) then
        return nil, "host must be a public server"
    end
    local ips, err = Webhooks.resolve(host)
    if not ips then return nil, err end
    for _, ip in ipairs(ips) do
        if not Webhooks.isPublicIPv4(ip) then return nil, "host must not resolve to a private address" end
    end
    return true
end

function NamespaceMail.settings(namespace_id)
    return db.query("SELECT * FROM namespace_mail_settings WHERE namespace_id = ?", namespace_id)[1]
end

--- The settings as the API shows them (never the password).
function NamespaceMail.present(row)
    if not row then return { configured = false } end
    return {
        configured = true, enabled = row.enabled, host = row.host, port = row.port, security = row.security,
        username = row.username, has_password = row.password_encrypted ~= nil and row.password_encrypted ~= db.NULL,
        from_email = row.from_email, from_name = row.from_name, reply_to = row.reply_to,
        last_tested_at = row.last_tested_at, last_error = row.last_error, updated_at = row.updated_at,
    }
end

local EMAIL = "^[^%s@]+@[^%s@]+%.[^%s@]+$"

function NamespaceMail.save(namespace_id, actor, b)
    local current = NamespaceMail.settings(namespace_id)
    local host = b.host or (current and current.host)
    if type(host) ~= "string" or not host:match("^[%w%-%.]+$") or #host > 253 then
        return nil, "host must be a hostname like smtp.example.com"
    end
    local port = tonumber(b.port or (current and current.port) or 587)
    if not port or port < 1 or port > 65535 or port ~= math.floor(port) then return nil, "port must be 1-65535" end
    local security = b.security or (current and current.security) or "starttls"
    if security ~= "starttls" and security ~= "ssl" and security ~= "none" then
        return nil, "security must be starttls, ssl or none"
    end
    local from_email = b.from_email or (current and current.from_email)
    if type(from_email) ~= "string" or not from_email:match(EMAIL) then return nil, "from_email must be an email address" end
    for _, k in ipairs({ "reply_to" }) do
        if b[k] ~= nil and b[k] ~= "" and (type(b[k]) ~= "string" or not b[k]:match(EMAIL)) then
            return nil, k .. " must be an email address"
        end
    end
    local ok, herr = host_ok(host)
    if not ok then return nil, herr end
    local f = {
        host = host, port = port, security = security, from_email = from_email,
        username = b.username ~= nil and (b.username ~= "" and b.username or db.NULL) or (current and current.username or db.NULL),
        from_name = b.from_name ~= nil and (b.from_name ~= "" and b.from_name:sub(1, 120) or db.NULL)
            or (current and current.from_name or db.NULL),
        reply_to = b.reply_to ~= nil and (b.reply_to ~= "" and b.reply_to or db.NULL) or (current and current.reply_to or db.NULL),
        enabled = b.enabled == nil and (current == nil or current.enabled) or b.enabled == true,
        updated_by = actor, updated_at = db.raw("NOW()"), last_error = db.NULL,
    }
    -- The password is write-only: omitted = keep, "" = remove.
    if b.password ~= nil then
        f.password_encrypted = b.password ~= "" and Global.encryptSecret(b.password) or db.NULL
    end
    if current then
        db.update("namespace_mail_settings", f, { namespace_id = namespace_id })
    else
        f.namespace_id = namespace_id
        db.insert("namespace_mail_settings", f)
    end
    return NamespaceMail.present(NamespaceMail.settings(namespace_id))
end

function NamespaceMail.remove(namespace_id)
    db.query("DELETE FROM namespace_mail_settings WHERE namespace_id = ?", namespace_id)
    return true
end

--- The SMTP config to send a workspace's mail with (nil = the deployment's).
function NamespaceMail.smtp(namespace_id)
    local row = namespace_id and NamespaceMail.settings(namespace_id)
    if not row or not row.enabled then return nil end
    local password = ""
    if row.password_encrypted and row.password_encrypted ~= db.NULL then
        local ok, pw = pcall(Global.decryptSecret, row.password_encrypted)
        if ok then password = pw end
    end
    return {
        host = row.host, port = tonumber(row.port), security = row.security,
        username = row.username ~= db.NULL and row.username or "", password = password,
        from_email = row.from_email, from_name = row.from_name ~= db.NULL and row.from_name or nil,
        reply_to = row.reply_to ~= db.NULL and row.reply_to or nil,
    }
end

-- ---------------------------------------------------------------------------
-- Templates
-- ---------------------------------------------------------------------------

local function escape(s)
    return (tostring(s):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;",
        ["'"] = "&#39;" }))
end

--- {{name}} -> the value (HTML-escaped unless `plain`); unknown names -> "".
function NamespaceMail.fill(text, data, plain)
    return (text:gsub("{{%s*([%w_]+)%s*}}", function(k)
        local v = data[k]
        if v == nil then return "" end
        return plain and tostring(v):gsub("[\r\n]", " ") or escape(v)
    end))
end

-- The template for `key`, if the feature that sends it is deployed.
local function template(key)
    local t = NamespaceMail.TEMPLATES[key]
    if t and (not t.feature or ProjectConfig.isFeatureEnabled(t.feature)) then return t end
end

local function override(namespace_id, key)
    return namespace_id and db.query([[SELECT subject, html, updated_at FROM namespace_email_templates
        WHERE namespace_id = ? AND template_key = ?]], namespace_id, key)[1]
end

function NamespaceMail.listTemplates(namespace_id)
    local out = {}
    for key in pairs(NamespaceMail.TEMPLATES) do
        local t = template(key)
        if t then
            local o = override(namespace_id, key)
            out[#out + 1] = { key = key, name = t.name, variables = t.variables, default_subject = t.subject,
                customised = o ~= nil, subject = o and o.subject or t.subject, html = o and o.html or nil,
                updated_at = o and o.updated_at or nil }
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

function NamespaceMail.saveTemplate(namespace_id, key, b, actor)
    if not template(key) then return nil, "Template not found" end
    if type(b.subject) ~= "string" or b.subject == "" or #b.subject > 200 then return nil, "subject is required (max 200)" end
    if type(b.html) ~= "string" or b.html == "" or #b.html > 100000 then return nil, "html is required (max 100 kB)" end
    db.query([[INSERT INTO namespace_email_templates (namespace_id, template_key, subject, html, updated_by)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT (namespace_id, template_key) DO UPDATE SET subject = EXCLUDED.subject, html = EXCLUDED.html,
            updated_by = EXCLUDED.updated_by, updated_at = NOW()]], namespace_id, key, b.subject, b.html, actor or db.NULL)
    return true
end

function NamespaceMail.resetTemplate(namespace_id, key)
    if not template(key) then return nil, "Template not found" end
    db.query("DELETE FROM namespace_email_templates WHERE namespace_id = ? AND template_key = ?", namespace_id, key)
    return true
end

-- Mail.send options for a template: the workspace's override, else the built-in.
-- `brand`: { app_name, brand_color, brand_logo_url, support_email } for the layout.
local function message(namespace_id, key, data, brand, draft)
    local t = NamespaceMail.TEMPLATES[key]
    local o = draft or override(namespace_id, key)
    local vars = {}
    for k, v in pairs(brand or {}) do vars[k] = v end
    for k, v in pairs(data or {}) do vars[k] = v end
    local subject = NamespaceMail.fill(o and o.subject or t.subject, vars, true)
    vars.subject = subject
    if o and o.html then
        return { subject = subject, html = NamespaceMail.fill(o.html, vars), wrap_in_layout = true, data = vars }
    end
    return { subject = subject, template = t.file, data = vars }
end

--- Render a template (for previews). @return { subject, html } | nil, err
function NamespaceMail.preview(namespace_id, key, draft)
    local t = template(key)
    if not t then return nil, "Template not found" end
    local m = message(namespace_id, key, t.sample, { app_name = t.sample.app_name }, draft)
    m.to, m.preview = "preview@example.com", true
    if m.template then
        local html, err = Mail.preview(m.template, m.data)
        if not html then return nil, err end
        return { subject = m.subject, html = html }
    end
    return { subject = m.subject, html = Mail.previewHtml(m.html, m.data) }
end

--- Send a template now (call from a background job: the outbox retries on failure).
-- @return true | nil, err
function NamespaceMail.send(namespace_id, key, to, data, brand)
    if not NamespaceMail.TEMPLATES[key] then return nil, "unknown template " .. tostring(key) end
    local smtp = NamespaceMail.smtp(namespace_id)
    if smtp then
        local ok, herr = host_ok(smtp.host)
        if not ok then return nil, "workspace SMTP: " .. herr end
    end
    local m = message(namespace_id, key, data, brand)
    m.to, m.sync, m.smtp = to, true, smtp
    if smtp then
        m.from_email = smtp.from_email
        m.from_name = (brand and brand.app_name) or smtp.from_name
        m.reply_to = (brand and brand.support_email ~= "" and brand.support_email) or smtp.reply_to
    elseif brand then
        m.from_name = brand.app_name
        if brand.support_email and brand.support_email ~= "" then m.reply_to = brand.support_email end
    end
    return Mail.send(m)
end

--- Send a test message through the workspace's SMTP and record the result.
function NamespaceMail.test(namespace_id, to)
    if type(to) ~= "string" or not to:match(EMAIL) then return nil, "to must be an email address" end
    local smtp = NamespaceMail.smtp(namespace_id)
    if not smtp then return nil, "Set up and enable this workspace's SMTP first" end
    local ok, herr = host_ok(smtp.host)
    local err
    if ok then
        ok, err = Mail.send({ to = to, subject = "Test email from OpsAPI", sync = true, smtp = smtp,
            from_email = smtp.from_email, from_name = smtp.from_name, reply_to = smtp.reply_to,
            html = "<p>Your workspace's email settings work.</p>", wrap_in_layout = true, data = {} })
    else
        err = herr
    end
    db.query("UPDATE namespace_mail_settings SET last_tested_at = NOW(), last_error = ? WHERE namespace_id = ?",
        ok and db.NULL or tostring(err):sub(1, 500), namespace_id)
    if not ok then return nil, tostring(err) end
    return true
end

return NamespaceMail
