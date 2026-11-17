--[[
    Workspace email (core) — docs/BILLING_ENTITLEMENTS.md §10
    ========================================================
    Each workspace can send through its own SMTP accounts (namespace_smtp_accounts;
    passwords stored encrypted), choose which account sends which kind of email
    (namespace_smtp_routes: leads, lead follow-up, shop, invoices...), and override
    the subject and body of any built-in template (namespace_email_templates).
    Without an account of its own the deployment's SMTP (SMTP_* env) is used.

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
-- of its default body, the variables it can use, sample data for previews, the
-- feature that sends it (hidden where that feature isn't deployed), and the kind
-- of email it is (which email account sends it — see NamespaceMail.kind).
NamespaceMail.TEMPLATES = {
    ["billing.access_link"] = {
        name = "Billing: account link",
        feature = "billing",
        file = "billing_access_link", kind = "billing",
        subject = "Your {{app_name}} account link",
        variables = { "app_name", "customer_email", "link", "expires_minutes", "support_email" },
        sample = { app_name = "Acme Desktop", customer_email = "you@example.com",
            link = "https://billing.example.com/b/app/account#token=sample", expires_minutes = 15,
            support_email = "support@example.com" },
    },
    ["billing.licence_key"] = {
        name = "Billing: licence key",
        feature = "billing",
        file = "billing_licence_key", kind = "billing",
        subject = "Your {{app_name}} licence key",
        variables = { "app_name", "customer_email", "licence_key", "plan_name", "account_link", "support_email" },
        sample = { app_name = "Acme Desktop", customer_email = "you@example.com",
            licence_key = "ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2", plan_name = "Pro",
            account_link = "https://billing.example.com/b/app/account", support_email = "support@example.com" },
    },
    ["namespace.invitation"] = {
        name = "Workspace invitation",
        file = "invitation", kind = "invitations",
        subject = "You're invited to join {{namespace_name}}",
        variables = { "namespace_name", "inviter_name", "role_name", "message", "accept_url", "expires_in" },
        sample = { app_name = "Acme Ltd", namespace_name = "Acme Ltd", inviter_name = "Sam Taylor",
            role_name = "Member", message = "Welcome aboard!", accept_url = "https://app.example.com/invite/sample",
            expires_in = "7 days" },
    },
    ["forms.new_response"] = {
        name = "Forms: new response",
        feature = "forms",
        file = "forms_new_response", kind = "forms",
        subject = "New response: {{form_title}}",
        variables = { "form_title", "answers_text", "response_url" },
        sample = { app_name = "Acme Ltd", form_title = "Contact us",
            answers = { { label = "Name", value = "Ann Lee" }, { label = "Email", value = "ann@example.com" } },
            answers_text = "Name: Ann Lee\nEmail: ann@example.com",
            response_url = "https://app.example.com/dashboard/forms/sample" },
    },
    ["crm.meeting_invite"] = {
        name = "Leads: meeting invitation",
        feature = "crm",
        file = "crm_meeting_invite", kind = "crm_meetings",
        subject = "{{meeting_title}}: {{when}}",
        variables = { "recipient_name", "meeting_title", "when", "location", "meeting_url", "organiser_name", "notes", "updated" },
        sample = { app_name = "Acme Ltd", recipient_name = "Ann Lee", meeting_title = "Video call with Ann Lee",
            when = "Thursday 5 November 2026, 14:30 (Europe/London, 30 minutes)", location = "",
            meeting_url = "https://meet.example.com/abc", organiser_name = "Sam Taylor", notes = "We'll go through your options.",
            updated = "" },
    },
    ["crm.meeting_cancelled"] = {
        name = "Leads: meeting cancelled",
        feature = "crm",
        file = "crm_meeting_cancelled", kind = "crm_meetings",
        subject = "Cancelled: {{meeting_title}}",
        variables = { "recipient_name", "meeting_title", "when", "organiser_name" },
        sample = { app_name = "Acme Ltd", recipient_name = "Ann Lee", meeting_title = "Video call with Ann Lee",
            when = "Thursday 5 November 2026, 14:30 (Europe/London, 30 minutes)", organiser_name = "Sam Taylor" },
    },
    ["crm.meeting_reminder"] = {
        name = "Leads: meeting reminder",
        feature = "crm",
        file = "crm_meeting_reminder", kind = "crm_meetings",
        subject = "Reminder: {{meeting_title}}, {{when}}",
        variables = { "recipient_name", "meeting_title", "when", "location", "meeting_url" },
        sample = { app_name = "Acme Ltd", recipient_name = "Ann Lee", meeting_title = "Video call with Ann Lee",
            when = "Thursday 5 November 2026, 14:30 (Europe/London, 30 minutes)", location = "",
            meeting_url = "https://meet.example.com/abc" },
    },
    ["crm.partner_referral"] = {
        name = "Leads: deal passed to a partner",
        feature = "crm",
        file = "crm_partner_referral", kind = "crm_partner_referrals",
        subject = "New referral from {{from_name}}: {{deal_title}}",
        variables = { "partner_name", "from_name", "deal_title", "summary", "wants", "value", "commission", "customer",
            "message", "respond_url" },
        sample = { app_name = "Acme Ltd", partner_name = "Jo at Bosch", from_name = "Acme Ltd",
            deal_title = "40 laptops for a school", summary = "A school wants 40 laptops for its new term.",
            wants = "40 business laptops", value = "32000.00 GBP", commission = "5% of the deal value",
            customer = "", message = "They need delivery before 1 December.",
            respond_url = "https://app.example.com/partner-referral/sample" },
    },
    ["forms.auto_reply"] = {
        name = "Forms: reply to the person who answered",
        feature = "forms",
        file = "forms_auto_reply", kind = "forms_auto_reply",
        subject = "{{reply_subject}}",
        variables = { "form_title", "reply_subject", "reply_body" },
        sample = { app_name = "Acme Ltd", form_title = "Contact us", reply_subject = "Thanks, Ann",
            reply_body = "Thanks for getting in touch.\nWe'll reply within one working day." },
    },
    -- Sent by staff from the order page ("Email the customer"); a transactional message, not marketing.
    -- `message` is plain text: the built-in body shows its line breaks; in a custom body {{message}} is
    -- one escaped paragraph.
    ["shop.order_update"] = {
        name = "Shop: order update to the customer",
        feature = "shop",
        file = "shop_order_update", kind = "shop_orders",
        subject = "{{headline}}: order {{order_number}}",
        variables = { "customer_name", "first_name", "order_number", "headline", "message", "order_link",
            "delivery_summary", "signature", "app_name", "call_phone" },
        sample = { app_name = "Acme Ltd", customer_name = "Ann Lee", first_name = "Ann", order_number = "WS-10042",
            headline = "Order received",
            message = "Thank you, we've received your order WS-10042. We've placed the order with our supplier and "
                .. "your item is reserved for you.\n\nWe'll be in touch to agree a delivery time that suits you.",
            order_link = "https://shop.example.com/orders/sample?t=sample", delivery_summary = "",
            signature = "Sam Taylor", signature_is_person = true, call_phone = "+44 20 7946 0000" },
    },
}

-- ---------------------------------------------------------------------------
-- Kinds of email (which account sends what)
-- ---------------------------------------------------------------------------
-- A workspace keeps several named SMTP accounts (namespace_smtp_accounts) and picks
-- the one that sends each KIND of email (namespace_smtp_routes). A kind with no
-- account picked uses the default account; with no default account (or when the
-- chosen one is switched off) the deployment's server (SMTP_* env) sends it.
--
-- The list is open-ended. A feature that sends email declares its kind once,
-- anywhere that loads at start-up (a route file, a plugin's api file):
--
--     NamespaceMail.kind("quotes", { name = "Quotations", group = "Sales",
--         description = "Quotations sent to customers.", feature = "shop" })
--
-- and sends with that key: NamespaceMail.smtp(ns, "quotes") / prepare / send(...,
-- { purpose = "quotes" }). Workspace → Email then shows it with its own dropdown.
-- A kind used without being declared still appears: the first send records it in
-- namespace_mail_kinds and the page shows it under "Other", named from its key.

local KINDS, KIND_ORDER = {}, {}
local KEY = "^[a-z][a-z0-9_]*$"

--- The order groups appear in on the Email page; a group not listed comes after them.
local GROUPS = { "General", "Leads and customers", "Sales", "Shop", "Marketing", "Team", "Forms", "Billing", "Tax" }
local GROUP_RANK = {}
for i, g in ipairs(GROUPS) do GROUP_RANK[g] = i end

--- Declare a kind of email (idempotent; a later call updates it). Returns the key.
-- meta: { name, group?, description?, feature? (hidden where that feature isn't deployed),
--         plugin? (its code: hidden in a workspace that switched the plugin off) }
function NamespaceMail.kind(key, meta)
    assert(type(key) == "string" and key:match(KEY) and #key <= 40, "email kind keys look like shop_quotes")
    meta = meta or {}
    if not KINDS[key] then KIND_ORDER[#KIND_ORDER + 1] = key end
    KINDS[key] = { key = key, name = meta.name or key, group = meta.group or "Other",
        description = meta.description or "", feature = meta.feature, plugin = meta.plugin }
    return key
end

local K = NamespaceMail.kind
K("default", { group = "General", name = "Default",
    description = "Every email that isn't sent through a different account below." })
-- Leads and customers
K("leads", { group = "Leads and customers", name = "New enquiries",
    description = "The thank-you email to someone who sends an enquiry, and the new-lead alert to your team." })
K("lead_followup", { group = "Leads and customers", name = "Emails to leads and customers",
    description = "Questions and follow-ups your team sends from a lead's page." })
K("crm_meetings", { group = "Leads and customers", name = "Meeting invitations", feature = "crm",
    description = "Meeting invitations, changes, cancellations and reminders." })
K("crm_partner_referrals", { group = "Leads and customers", name = "Partner referrals", feature = "crm",
    description = "Deals you pass to a partner." })
-- Sales
K("shop_quotes", { group = "Sales", name = "Quotations", feature = "shop",
    description = "Quotations and order authorisations sent to shop customers." })
K("field_service", { group = "Sales", name = "Field service quotations", feature = "field_service",
    description = "Quotations sent from field service jobs." })
K("invoices", { group = "Sales", name = "Invoices", feature = "invoicing",
    description = "Invoices sent to your customers." })
K("purchase_orders", { group = "Sales", name = "Purchase orders", feature = "invoicing",
    description = "Purchase orders sent to your suppliers." })
-- Shop
K("shop_orders", { group = "Shop", name = "Order updates", feature = "shop",
    description = "Order updates and delivery changes sent to shop customers." })
K("shop_members", { group = "Shop", name = "Member emails", feature = "shop",
    description = "Members' sign-in links and store credit notices." })
K("shop_alerts", { group = "Shop", name = "Shop alerts to your team", feature = "shop",
    description = "New orders, refunds needed and price checks, sent to your team." })
-- Team
K("team", { group = "Team", name = "Team notifications",
    description = "Lead assignments and reminders sent to your staff." })
K("invitations", { group = "Team", name = "Workspace invitations",
    description = "Invitations to join this workspace." })
K("employee_welcome", { group = "Team", name = "New team member accounts",
    description = "The email telling a new team member their account is ready." })
-- Forms
K("forms", { group = "Forms", name = "New responses", feature = "forms",
    description = "New form responses sent to your team." })
K("forms_auto_reply", { group = "Forms", name = "Automatic replies", feature = "forms",
    description = "The automatic reply to the person who answered a form." })
-- Billing
K("billing", { group = "Billing", name = "Account links and licence keys", feature = "billing",
    description = "Account links and licence keys for your customers." })
-- Tax
K("tax_filing", { group = "Tax", name = "Tax return requests", feature = "tax_copilot",
    description = "Updates to customers about their tax return request, and alerts to the accountant." })

--- Emails the platform always sends itself, whatever the workspace sets up: they must
-- arrive even when a workspace's own account is broken (shown on the Email page).
NamespaceMail.PLATFORM_ONLY = {
    "Sign-in codes and password resets",
    "Security alerts, such as a change to your bank details",
}

--- A key's label when nothing declared it: "property_quotes" -> "Property quotes".
local function humanize(key)
    local s = tostring(key):gsub("_", " ")
    return (s:gsub("^%l", string.upper))
end

-- Kinds this worker has already recorded (or found declared), so a send records at most once.
local recorded = {}

--- A kind used without being declared: record it so the Email page lists it.
local function record(key)
    if KINDS[key] or recorded[key] or type(key) ~= "string" or not key:match(KEY) or #key > 40 then return end
    recorded[key] = true
    pcall(db.query, "INSERT INTO namespace_mail_kinds (key) VALUES (?) ON CONFLICT (key) DO NOTHING", key)
end

local function available(k)
    return not k.feature or ProjectConfig.isFeatureEnabled(k.feature)
end

--- Every kind the Email page shows, in page order: declared ones (where their feature is
-- deployed), then any recorded on first use, each { key, name, group, description }.
function NamespaceMail.kinds()
    local out, seen = {}, {}
    for i, key in ipairs(KIND_ORDER) do
        local k = KINDS[key]
        if available(k) then
            out[#out + 1] = { key = k.key, name = k.name, group = k.group, description = k.description, i = i,
                plugin = k.plugin }
        end
        seen[key] = true
    end
    local ok, rows = pcall(db.query, "SELECT key FROM namespace_mail_kinds ORDER BY key")
    for _, r in ipairs(ok and rows or {}) do
        if not seen[r.key] then
            out[#out + 1] = { key = r.key, name = humanize(r.key), group = "Other", i = #KIND_ORDER + #out + 1,
                description = "Found in use; its feature didn't describe it." }
        end
    end
    table.sort(out, function(a, b)
        local ra, rb = GROUP_RANK[a.group] or #GROUPS + 1, GROUP_RANK[b.group] or #GROUPS + 1
        if ra ~= rb then return ra < rb end
        if a.group ~= b.group then return a.group < b.group end
        return a.i < b.i
    end)
    for _, k in ipairs(out) do k.i = nil end
    return out
end

local function kind_known(key)
    if KINDS[key] then return available(KINDS[key]) end
    if type(key) ~= "string" or not key:match(KEY) then return false end
    local ok, rows = pcall(db.query, "SELECT 1 FROM namespace_mail_kinds WHERE key = ?", key)
    return ok and rows[1] ~= nil
end

--- Which kind a built-in template is sent as (its `kind`, else the default).
function NamespaceMail.templatePurpose(key)
    local t = NamespaceMail.TEMPLATES[key]
    return t and t.kind or "default"
end

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

NamespaceMail.hostOk = host_ok

local function nn(v)
    if v == nil or v == db.NULL then return nil end
    return v
end

local function account_by_uuid(namespace_id, uuid)
    if type(uuid) ~= "string" or uuid == "" then return nil end
    return db.query("SELECT * FROM namespace_smtp_accounts WHERE namespace_id = ? AND uuid = ?", namespace_id, uuid)[1]
end

local function default_account(namespace_id)
    return db.query("SELECT * FROM namespace_smtp_accounts WHERE namespace_id = ? AND is_default", namespace_id)[1]
end

--- An account as the API shows it (never the password).
function NamespaceMail.presentAccount(row)
    return {
        uuid = row.uuid, name = row.name, is_default = row.is_default == true, enabled = row.enabled == true,
        host = row.host, port = tonumber(row.port), security = row.security, username = nn(row.username),
        has_password = nn(row.password_encrypted) ~= nil,
        from_email = row.from_email, from_name = nn(row.from_name), reply_to = nn(row.reply_to),
        last_tested_at = nn(row.last_tested_at), last_error = nn(row.last_error),
        created_at = row.created_at, updated_at = row.updated_at,
    }
end

function NamespaceMail.listAccounts(namespace_id)
    local out = {}
    for _, r in ipairs(db.query([[SELECT * FROM namespace_smtp_accounts WHERE namespace_id = ?
        ORDER BY is_default DESC, lower(name), id]], namespace_id)) do
        out[#out + 1] = NamespaceMail.presentAccount(r)
    end
    return out
end

function NamespaceMail.getAccount(namespace_id, uuid)
    local row = account_by_uuid(namespace_id, uuid)
    if not row then return nil, "Email account not found" end
    return NamespaceMail.presentAccount(row)
end

local EMAIL = "^[^%s@]+@[^%s@]+%.[^%s@]+$"

local function clear_other_defaults(namespace_id, keep_id)
    db.query("UPDATE namespace_smtp_accounts SET is_default = FALSE WHERE namespace_id = ? AND is_default AND id <> ?",
        namespace_id, keep_id)
end

-- Accounts other than `except_id` that are switched on.
local function others_on(namespace_id, except_id)
    return tonumber(db.query([[SELECT count(*) AS n FROM namespace_smtp_accounts
        WHERE namespace_id = ? AND enabled AND id <> ?]], namespace_id, except_id or 0)[1].n) or 0
end

local function has_accounts(namespace_id)
    return db.query("SELECT 1 FROM namespace_smtp_accounts WHERE namespace_id = ? LIMIT 1", namespace_id)[1] ~= nil
end

-- With a switched-off default, every email without its own account would quietly go through
-- the platform's server, even with other accounts switched on. These keep the default usable.
local DEFAULT_STAYS_ON = "This is the default account. Make another account the default first (or pick "
    .. "\"Platform server\" as the default), then switch this one off."
local SWITCH_ON_FIRST = "Switch this account on before making it the default."
local CHANGED_MEANWHILE = "These email accounts were just changed by someone else. Reload the page and try again."

local function conflict(err)
    return tostring(err):find("duplicate key", 1, true) or tostring(err):find("unique", 1, true)
end

--- Create (uuid = nil) or update an account. The workspace's first account becomes the default.
-- @return presented account | nil, err
function NamespaceMail.saveAccount(namespace_id, uuid, actor, b)
    local current
    if uuid then
        current = account_by_uuid(namespace_id, uuid)
        if not current then return nil, "Email account not found" end
    end
    local name = b.name
    if name == nil then name = current and current.name end
    if type(name) ~= "string" or name:match("^%s*$") then return nil, "name is required (e.g. Sales, Support)" end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if #name > 80 then return nil, "name must be 80 characters or fewer" end
    local clash = db.query("SELECT 1 FROM namespace_smtp_accounts WHERE namespace_id = ? AND lower(name) = lower(?) AND id <> ?",
        namespace_id, name, current and current.id or 0)[1]
    if clash then return nil, "Another email account is already called " .. name end

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
    if b.reply_to ~= nil and b.reply_to ~= "" and (type(b.reply_to) ~= "string" or not b.reply_to:match(EMAIL)) then
        return nil, "reply_to must be an email address"
    end
    for _, k in ipairs({ "username", "password", "from_name" }) do
        if b[k] ~= nil and type(b[k]) ~= "string" then return nil, k .. " must be text" end
    end
    local ok, herr = host_ok(host)
    if not ok then return nil, herr end

    local f = {
        name = name, host = host, port = port, security = security, from_email = from_email,
        username = b.username ~= nil and (b.username ~= "" and b.username or db.NULL) or (current and current.username or db.NULL),
        from_name = b.from_name ~= nil and (b.from_name ~= "" and b.from_name:sub(1, 120) or db.NULL)
            or (current and current.from_name or db.NULL),
        reply_to = b.reply_to ~= nil and (b.reply_to ~= "" and b.reply_to or db.NULL) or (current and current.reply_to or db.NULL),
        enabled = b.enabled == nil and (current == nil or current.enabled) or b.enabled == true,
        updated_by = actor or db.NULL, updated_at = db.raw("NOW()"),
    }
    -- A changed server hasn't been tested yet.
    if not current or current.host ~= host or tonumber(current.port) ~= port or b.password ~= nil then
        f.last_error, f.last_tested_at = db.NULL, db.NULL
    end
    -- The password is write-only: omitted = keep, "" = remove.
    if b.password ~= nil then
        f.password_encrypted = b.password ~= "" and Global.encryptSecret(b.password) or db.NULL
    end

    -- Only a workspace's very first account becomes the default by itself: one that chose
    -- "Platform server" as its default keeps that choice when it adds an account.
    local make_default = b.is_default == true or (not current and not has_accounts(namespace_id))
    if current and current.is_default and current.enabled and not f.enabled and b.is_default ~= false
        and others_on(namespace_id, current.id) > 0 then
        return nil, DEFAULT_STAYS_ON
    end
    if make_default and not f.enabled and others_on(namespace_id, current and current.id) > 0 then
        return nil, SWITCH_ON_FIRST
    end
    local id
    db.query("BEGIN")
    local tx_ok, tx_err = pcall(function()
        if current then
            if b.is_default == false and current.is_default then f.is_default = false end
            db.update("namespace_smtp_accounts", f, { id = current.id })
            id = current.id
        else
            f.uuid, f.namespace_id = Global.generateUUID(), namespace_id
            id = db.query([[INSERT INTO namespace_smtp_accounts (uuid, namespace_id, name, host, port, security, username,
                    password_encrypted, from_email, from_name, reply_to, enabled, updated_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id]],
                f.uuid, namespace_id, f.name, f.host, f.port, f.security, f.username, f.password_encrypted or db.NULL,
                f.from_email, f.from_name, f.reply_to, f.enabled, f.updated_by)[1].id
        end
        if make_default then
            clear_other_defaults(namespace_id, id)
            db.query("UPDATE namespace_smtp_accounts SET is_default = TRUE WHERE id = ?", id)
        end
    end)
    if not tx_ok then
        db.query("ROLLBACK")
        if conflict(tx_err) then return nil, CHANGED_MEANWHILE end
        error(tx_err)
    end
    db.query("COMMIT")
    return NamespaceMail.presentAccount(db.query("SELECT * FROM namespace_smtp_accounts WHERE id = ?", id)[1])
end

--- Make an account the default (the one every unrouted email uses).
function NamespaceMail.setDefaultAccount(namespace_id, uuid)
    local row = account_by_uuid(namespace_id, uuid)
    if not row then return nil, "Email account not found" end
    if not row.enabled and others_on(namespace_id, row.id) > 0 then return nil, SWITCH_ON_FIRST end
    db.query("BEGIN")
    local ok, err = pcall(function()
        clear_other_defaults(namespace_id, row.id)
        db.query("UPDATE namespace_smtp_accounts SET is_default = TRUE, updated_at = NOW() WHERE id = ?", row.id)
    end)
    if not ok then
        db.query("ROLLBACK")
        if conflict(err) then return nil, CHANGED_MEANWHILE end
        error(err)
    end
    db.query("COMMIT")
    return NamespaceMail.presentAccount(account_by_uuid(namespace_id, uuid))
end

--- Delete an account. Emails routed to it go back to the default account. If it was the
-- default, the oldest account still switched on takes over (none: the deployment's server).
-- @return { new_default = name | nil } | nil, err
function NamespaceMail.deleteAccount(namespace_id, uuid)
    local row = account_by_uuid(namespace_id, uuid)
    if not row then return nil, "Email account not found" end
    local promoted
    db.query("BEGIN")
    local ok, err = pcall(function()
        db.query("DELETE FROM namespace_smtp_accounts WHERE id = ?", row.id) -- routes cascade
        if row.is_default then
            promoted = db.query([[UPDATE namespace_smtp_accounts SET is_default = TRUE, updated_at = NOW()
                WHERE id = (SELECT id FROM namespace_smtp_accounts WHERE namespace_id = ? AND enabled
                    ORDER BY created_at, id LIMIT 1) RETURNING name]], namespace_id)[1]
        end
    end)
    if not ok then
        db.query("ROLLBACK")
        if conflict(err) then return nil, CHANGED_MEANWHILE end
        error(err)
    end
    db.query("COMMIT")
    return { new_default = promoted and promoted.name or nil }
end

local function smtp_config(row)
    local password = ""
    if nn(row.password_encrypted) then
        local ok, pw = pcall(Global.decryptSecret, row.password_encrypted)
        if ok and pw then password = pw end
    end
    return {
        host = row.host, port = tonumber(row.port), security = row.security,
        username = nn(row.username) or "", password = password,
        from_email = row.from_email, from_name = nn(row.from_name), reply_to = nn(row.reply_to),
        account_uuid = row.uuid, account_name = row.name,
    }
end

local function routed_account(namespace_id, purpose)
    if purpose and purpose ~= "default" then
        local r = db.query([[SELECT a.* FROM namespace_smtp_routes r
            JOIN namespace_smtp_accounts a ON a.id = r.account_id
            WHERE r.namespace_id = ? AND r.purpose = ? AND a.enabled]], namespace_id, purpose)[1]
        if r then return r end
    end
    return db.query("SELECT * FROM namespace_smtp_accounts WHERE namespace_id = ? AND is_default AND enabled",
        namespace_id)[1]
end

--- The SMTP config to send a workspace's `purpose` email with (nil = the deployment's).
-- `purpose` is a kind of email (NamespaceMail.kind); omitted = "default". An undeclared
-- kind is recorded so the Email page lists it. The result carries account_uuid /
-- account_name for logs.
function NamespaceMail.smtp(namespace_id, purpose)
    if not namespace_id then return nil end
    if purpose and purpose ~= "default" then record(purpose) end
    local ok, row = pcall(routed_account, namespace_id, purpose)
    if not ok then
        -- Accounts table not migrated yet: behave as if the workspace has none.
        ngx.log(ngx.WARN, "[namespace-mail] smtp lookup failed: ", tostring(row))
        return nil
    end
    return row and smtp_config(row) or nil
end

--- Put the workspace's server for `purpose` on a Mail.send message: smtp, sender
-- address, and the account's name / reply-to (the caller's from_name / reply_to
-- stay when the account sets none).
-- @return msg, smtp|nil  | nil, err (no server anywhere, or the account's host isn't allowed)
function NamespaceMail.prepare(namespace_id, purpose, msg)
    local smtp = NamespaceMail.smtp(namespace_id, purpose)
    if smtp then
        local ok, herr = host_ok(smtp.host)
        if not ok then return nil, "email account " .. tostring(smtp.account_name) .. ": " .. tostring(herr) end
        msg.smtp, msg.from_email = smtp, smtp.from_email
        msg.from_name = smtp.from_name or msg.from_name
        msg.reply_to = smtp.reply_to or msg.reply_to
        return msg, smtp
    end
    if not Mail.isConfigured() then return nil, "No email server is set up (Workspace → Email)" end
    return msg, nil
end

--- Can this workspace send `purpose` email at all (its own account or the deployment's)?
function NamespaceMail.canSend(namespace_id, purpose)
    return NamespaceMail.smtp(namespace_id, purpose) ~= nil or Mail.isConfigured()
end

--- Every kind of email with the account picked for it (null = the default account;
-- for "default" itself, null = the deployment's server), grouped for the Email page.
function NamespaceMail.routing(namespace_id)
    local routes = {}
    for _, r in ipairs(db.query([[SELECT r.purpose, a.uuid FROM namespace_smtp_routes r
        JOIN namespace_smtp_accounts a ON a.id = r.account_id WHERE r.namespace_id = ?]], namespace_id)) do
        routes[r.purpose] = r.uuid
    end
    local def = default_account(namespace_id)
    local kinds, plugins = NamespaceMail.kinds(), {}
    for _, k in ipairs(kinds) do
        if k.plugin then plugins[#plugins + 1] = k.plugin end
    end
    -- A plugin switched off in this workspace sends nothing here: leave its rows out.
    local ok_off, off = pcall(function() return require("helper.plugin-workspaces").disabledIn(namespace_id, plugins) end)
    off = ok_off and off or {}
    local out = {}
    for _, k in ipairs(kinds) do
        if not (k.plugin and off[k.plugin]) then
            k.account_uuid = (k.key == "default" and (def and def.uuid) or routes[k.key]) or require("cjson").null
            k.plugin = nil
            out[#out + 1] = k
        end
    end
    return out
end

--- Set routes: { [purpose] = account_uuid | "" | null }. "" / null = use the default.
-- "default" sets the default account (null = the deployment's server).
function NamespaceMail.saveRouting(namespace_id, actor, routes)
    if type(routes) ~= "table" then return nil, "routes must be an object of purpose: account uuid" end
    local plan = {}
    for purpose, uuid in pairs(routes) do
        if not kind_known(purpose) then return nil, "unknown kind of email " .. tostring(purpose) end
        local row
        if type(uuid) == "string" and uuid ~= "" then
            row = account_by_uuid(namespace_id, uuid)
            if not row then return nil, "Email account not found for " .. purpose end
            if purpose == "default" and not row.enabled and others_on(namespace_id, row.id) > 0 then
                return nil, SWITCH_ON_FIRST
            end
        elseif uuid ~= "" and uuid ~= db.NULL and uuid ~= require("cjson").null and uuid ~= false then
            return nil, purpose .. " must be an account uuid or null"
        end
        plan[#plan + 1] = { purpose = purpose, row = row }
    end
    db.query("BEGIN")
    local ok, err = pcall(function()
        for _, p in ipairs(plan) do
            if p.purpose == "default" then
                db.query("UPDATE namespace_smtp_accounts SET is_default = FALSE WHERE namespace_id = ? AND is_default",
                    namespace_id)
                if p.row then db.query("UPDATE namespace_smtp_accounts SET is_default = TRUE WHERE id = ?", p.row.id) end
            elseif p.row then
                db.query([[INSERT INTO namespace_smtp_routes (namespace_id, purpose, account_id, updated_by)
                    VALUES (?, ?, ?, ?) ON CONFLICT (namespace_id, purpose) DO UPDATE
                    SET account_id = EXCLUDED.account_id, updated_by = EXCLUDED.updated_by, updated_at = NOW()]],
                    namespace_id, p.purpose, p.row.id, actor or db.NULL)
            else
                db.query("DELETE FROM namespace_smtp_routes WHERE namespace_id = ? AND purpose = ?", namespace_id, p.purpose)
            end
        end
    end)
    if not ok then
        db.query("ROLLBACK")
        error(err)
    end
    db.query("COMMIT")
    return NamespaceMail.routing(namespace_id)
end

--- Send a test message through one account and record the result on it.
function NamespaceMail.testAccount(namespace_id, uuid, to)
    if type(to) ~= "string" or not to:match(EMAIL) then return nil, "to must be an email address" end
    local row = account_by_uuid(namespace_id, uuid)
    if not row then return nil, "Email account not found" end
    local smtp = smtp_config(row)
    local ok, err = host_ok(smtp.host)
    if ok then
        ok, err = Mail.send({ to = to, subject = "Test email from " .. row.name, sync = true, smtp = smtp,
            from_email = smtp.from_email, from_name = smtp.from_name, reply_to = smtp.reply_to,
            html = "<p>The email account <strong>" .. (tostring(row.name):gsub("[&<>\"']", "")) ..
                "</strong> works.</p>", wrap_in_layout = true, data = {} })
    end
    db.query("UPDATE namespace_smtp_accounts SET last_tested_at = NOW(), last_error = ? WHERE id = ?",
        ok and db.NULL or tostring(err):sub(1, 500), row.id)
    if not ok then return nil, tostring(err) end
    return true
end

-- ---------------------------------------------------------------------------
-- Single-server API (older clients): acts on the default account.
-- ---------------------------------------------------------------------------

function NamespaceMail.settings(namespace_id)
    return default_account(namespace_id)
end

--- The default account as the single-server API shows it (never the password).
function NamespaceMail.present(row)
    if not row then return { configured = false } end
    local p = NamespaceMail.presentAccount(row)
    p.configured = true
    return p
end

function NamespaceMail.save(namespace_id, actor, b)
    local current = default_account(namespace_id)
    local body = {}
    for k, v in pairs(b or {}) do body[k] = v end
    body.is_default = true
    if not current and (body.name == nil or body.name == "") then body.name = "Main" end
    local saved, err = NamespaceMail.saveAccount(namespace_id, current and current.uuid or nil, actor, body)
    if not saved then return nil, err end
    saved.configured = true
    return saved
end

function NamespaceMail.remove(namespace_id)
    local current = default_account(namespace_id)
    if current then NamespaceMail.deleteAccount(namespace_id, current.uuid) end
    return true
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

--- Render a template with real data, without sending: the workspace's version if it has one, else the
-- built-in. @return { subject, html, customised } | nil, err
function NamespaceMail.render(namespace_id, key, data, brand)
    if not template(key) then return nil, "Template not found" end
    local m = message(namespace_id, key, data, brand)
    if m.template then
        local html, err = Mail.preview(m.template, m.data)
        if not html then return nil, err end
        return { subject = m.subject, html = html, customised = false }
    end
    return { subject = m.subject, html = Mail.previewHtml(m.html, m.data), customised = true }
end

--- Send a template now (call from a background job: the outbox retries on failure).
-- @return true | nil, err
-- `extra`: { attachments = { { filename, content_type, content_b64 } } } (e.g. a calendar invite),
--          subject_prefix (e.g. "[TEST] " for a test send to staff),
--          purpose (which email account sends it; default: the template's own purpose).
function NamespaceMail.send(namespace_id, key, to, data, brand, extra)
    if not NamespaceMail.TEMPLATES[key] then return nil, "unknown template " .. tostring(key) end
    local purpose = type(extra) == "table" and extra.purpose or NamespaceMail.templatePurpose(key)
    local smtp = NamespaceMail.smtp(namespace_id, purpose)
    if smtp then
        local ok, herr = host_ok(smtp.host)
        if not ok then return nil, "email account " .. tostring(smtp.account_name) .. ": " .. herr end
    end
    local m = message(namespace_id, key, data, brand)
    if type(extra) == "table" and type(extra.subject_prefix) == "string" then
        m.subject = extra.subject_prefix .. m.subject
        if m.data then m.data.subject = m.subject end
    end
    m.to, m.sync, m.smtp = to, true, smtp
    if type(extra) == "table" and type(extra.attachments) == "table" then m.attachments = extra.attachments end
    if smtp then
        m.from_email = smtp.from_email
        -- The workspace chose its own sender name with its own server: that wins over the template's brand.
        m.from_name = smtp.from_name or (brand and brand.app_name)
        m.reply_to = (brand and brand.support_email ~= "" and brand.support_email) or smtp.reply_to
    elseif brand then
        m.from_name = brand.app_name
        if brand.support_email and brand.support_email ~= "" then m.reply_to = brand.support_email end
    end
    return Mail.send(m)
end

--- Send a test message through the default account (single-server API).
function NamespaceMail.test(namespace_id, to)
    local current = default_account(namespace_id)
    if not current then return nil, "Set up this workspace's email account first" end
    return NamespaceMail.testAccount(namespace_id, current.uuid, to)
end

return NamespaceMail
