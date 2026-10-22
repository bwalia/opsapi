--[[
    Business-contact import: pull every email (plus name / company / phone / website when
    the file has those columns) out of a CSV, XLSX or PDF, sort out the ones that can't be
    emailed, and add the rest to a list in a few set-based statements.

    Lawful basis (recorded per contact, with the file as evidence):
      legitimate_interest — business contacts (B2B). Under UK/EU rules (PECR) consumer
                            mailboxes (gmail, hotmail…) are private individuals who must
                            consent first, so they're skipped when the workspace
                            jurisdiction is uk or eu.
      consent             — the people on the file opted in.
    Anyone suppressed or unsubscribed is skipped and never re-subscribed by an import.
]]
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("opsapi_marketing.util")

local P = {}

P.MAX_BYTES = 7 * 1024 * 1024
P.MAX_EMAILS = 50000

-- Consumer mailbox providers: exact domains, plus families by first label (yahoo.co.uk…).
local PERSONAL = {}
for _, d in ipairs({
    "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "protonmail.com", "proton.me", "pm.me",
    "mail.com", "email.com", "zoho.com", "zohomail.com", "ymail.com", "rocketmail.com", "msn.com",
    "btinternet.com", "btopenworld.com", "sky.com", "virginmedia.com", "ntlworld.com", "talktalk.net",
    "tiscali.co.uk", "blueyonder.co.uk", "qq.com", "163.com", "126.com", "web.de", "t-online.de",
    "orange.fr", "free.fr", "laposte.net", "libero.it", "rediffmail.com", "fastmail.com", "hey.com",
    "tutanota.com", "mail.ru", "inbox.com",
}) do PERSONAL[d] = true end
local PERSONAL_FAMILY = { yahoo = true, hotmail = true, live = true, outlook = true, aol = true, gmx = true,
    yandex = true }

function P.is_personal(email)
    local domain = email:match("@(.+)$") or ""
    return PERSONAL[domain] == true or PERSONAL_FAMILY[domain:match("^([^%.]+)%.")] == true
end

-- Not addresses: image names like logo@2x.png that sit in exported HTML/PDF text.
local FILE_TLD = { png = true, jpg = true, jpeg = true, gif = true, svg = true, webp = true }

--- Every email in a piece of text, normalised, in order.
function P.emails_in(text)
    local out = {}
    if type(text) ~= "string" or text == "" then return out end
    for raw in text:gmatch("[%w%.%%%+%-_']+@[%w%-]+%.[%w%.%-]+") do
        local e = U.norm_email((raw:gsub("^[%.']+", ""):gsub("[%.%-]+$", "")))
        local tld = e and e:match("%.(%a+)$")
        if e and tld and #tld >= 2 and not FILE_TLD[tld] then out[#out + 1] = e end
    end
    return out
end

function P.parse_csv_line(line)
    local fields, field, in_q = {}, "", false
    local i, n = 1, #line
    while i <= n do
        local ch = line:sub(i, i)
        if in_q then
            if ch == '"' then
                if line:sub(i + 1, i + 1) == '"' then field = field .. '"'; i = i + 1
                else in_q = false end
            else field = field .. ch end
        else
            if ch == '"' then in_q = true
            elseif ch == "," then fields[#fields + 1] = field; field = ""
            else field = field .. ch end
        end
        i = i + 1
    end
    fields[#fields + 1] = field
    return fields
end

-- Header names (lower-case, letters/digits only) → field.
local HEADERS = {
    first_name = { "firstname", "first", "forename", "givenname" },
    last_name = { "lastname", "surname", "last", "familyname" },
    name = { "name", "fullname", "contactname", "contact", "contactperson" },
    company = { "company", "companyname", "organisation", "organization", "business", "businessname",
                "account", "accountname", "employer", "firm" },
    website = { "website", "web", "url", "site", "domain", "homepage" },
    phone = { "phone", "telephone", "tel", "mobile", "phonenumber", "contactnumber" },
}

local function header_map(cells)
    local map, found = {}, false
    for i, cell in ipairs(cells) do
        local h = tostring(cell or ""):lower():gsub("[^%w]", "")
        for field, names in pairs(HEADERS) do
            for _, n in ipairs(names) do
                if h == n and not map[field] then map[field] = i; found = true end
            end
        end
        if h:find("mail", 1, true) then found = true end
    end
    return found and map or nil
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^[=+%-@]+", "")):sub(1, 255)
end

--- rows (arrays of cell strings) → prospects. The first row is a header when it has no
-- email and names at least one known column.
local function from_rows(rows)
    local map
    local first = rows[1]
    if first and #P.emails_in(table.concat(first, " ")) == 0 then map = header_map(first) end
    local out = {}
    for r = map and 2 or 1, #rows do
        local cells = rows[r]
        local emails = P.emails_in(table.concat(cells, " "))
        if #emails > 0 then
            local function col(f) return map and map[f] and trim(cells[map[f]]) or "" end
            local first_name, last_name = col("first_name"), col("last_name")
            if first_name == "" and col("name") ~= "" then
                first_name, last_name = col("name"):match("^(%S+)%s*(.-)$")
            end
            -- E.164 when it parses (trim's formula guard would drop a leading "+").
            local phone = map and map.phone and U.e164(cells[map.phone]) or col("phone")
            for _, e in ipairs(emails) do
                out[#out + 1] = {
                    email = e, first_name = first_name or "", last_name = last_name or "",
                    company = col("company"), website = col("website"), phone = phone,
                }
            end
        end
    end
    return out
end

-- Run a command (argv) and return its stdout. ngx.pipe: io.popen races nginx's SIGCHLD.
local function run(argv)
    local ok, pipe = pcall(require, "ngx.pipe")
    if not ok then return nil, "can't run " .. argv[1] end
    local proc, err = pipe.spawn(argv)
    if not proc then return nil, err end
    proc:set_timeouts(nil, 30000, 30000, 30000)
    local out = proc:stdout_read_all()
    proc:wait()
    return out
end

local function xml_text(s)
    return (s:gsub("<[^>]+>", ""):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
        :gsub("&apos;", "'"):gsub("&#(%d+);", function(n)
            local c = tonumber(n)
            return c and c < 128 and string.char(c) or ""
        end):gsub("&amp;", "&"))
end

local function col_index(letters)
    local n = 0
    for i = 1, #letters do n = n * 26 + (letters:upper():byte(i) - 64) end
    return n
end

-- XLSX = zip of XML: shared strings + one XML per sheet. Every sheet is read.
local function xlsx_rows(path)
    local listing = run({ "unzip", "-Z1", path })
    if not listing then return nil, "couldn't open the spreadsheet" end
    local strings = {}
    local sst = run({ "unzip", "-p", path, "xl/sharedStrings.xml" }) or ""
    for si in sst:gmatch("<si>(.-)</si>") do
        local parts = {}
        for t in si:gmatch("<t[^>]*>(.-)</t>") do parts[#parts + 1] = t end
        strings[#strings + 1] = xml_text(table.concat(parts))
    end
    local rows = {}
    for entry in listing:gmatch("[^\r\n]+") do
        if entry:match("^xl/worksheets/sheet%d+%.xml$") then
            local xml = run({ "unzip", "-p", path, entry }) or ""
            for row in xml:gmatch("<row[^>]*>(.-)</row>") do
                local cells, last = {}, 0
                for attrs, inner in row:gsub("<c%s[^>]-/>", ""):gmatch("<c(%s[^>]*)>(.-)</c>") do
                    local t = attrs:match('t="([^"]+)"')
                    local v
                    if t == "s" then v = strings[(tonumber(inner:match("<v>(.-)</v>")) or -1) + 1]
                    elseif t == "inlineStr" then v = xml_text(inner)
                    else v = xml_text(inner:match("<v>(.-)</v>") or "") end
                    local ref = attrs:match('r="(%a+)%d*"') -- optional: without it, the next column
                    last = ref and col_index(ref) or last + 1
                    cells[last] = v or ""
                end
                local max = 0
                for k in pairs(cells) do if k > max then max = k end end
                for k = 1, max do cells[k] = cells[k] or "" end
                rows[#rows + 1] = cells
            end
        end
    end
    return rows
end

local function file_type(name, bytes)
    if bytes:sub(1, 5) == "%PDF-" then return "pdf" end
    if bytes:sub(1, 4) == "PK\3\4" then return "xlsx" end
    local ext = (name or ""):lower():match("%.(%w+)$")
    if ext == "xls" then return nil, "Old .xls files aren't supported: save it as .xlsx or .csv" end
    return "csv"
end

--- Extract prospects from a file's bytes. @return { type, rows } or nil, err
function P.extract(name, bytes)
    local kind, err = file_type(name, bytes)
    if not kind then return nil, err end
    if kind == "csv" then
        local rows = {}
        for line in (bytes .. "\n"):gmatch("(.-)\r?\n") do
            if line:match("%S") then rows[#rows + 1] = P.parse_csv_line(line) end
        end
        return { type = kind, rows = from_rows(rows) }
    end
    local path = os.tmpname()
    local fh = io.open(path, "wb")
    if not fh then return nil, "couldn't store the upload" end
    fh:write(bytes)
    fh:close()
    local rows, rerr
    if kind == "xlsx" then
        rows, rerr = xlsx_rows(path)
        rows = rows and from_rows(rows)
    else
        local text = run({ "pdftotext", "-layout", path, "-" })
        if not text then rerr = "couldn't read the PDF" else
            rows = {}
            for _, e in ipairs(P.emails_in(text)) do
                rows[#rows + 1] = { email = e, first_name = "", last_name = "", company = "", website = "", phone = "" }
            end
        end
    end
    os.remove(path)
    if not rows then return nil, rerr end
    return { type = kind, rows = rows }
end

--- Sort extracted rows: unique, valid, lawful to email, not unsubscribed.
-- @return { type, importable = rows, summary }
function P.scan(ns, name, bytes, legal_basis)
    local ext, err = P.extract(name, bytes)
    if not ext then return nil, err end
    local settings = U.settings(ns)
    local strict = legal_basis ~= "consent" and (settings.jurisdiction or "uk") ~= "us"
        and (settings.jurisdiction or "uk") ~= "other"

    local seen, unique, dups, personal = {}, {}, 0, 0
    for _, r in ipairs(ext.rows) do
        if seen[r.email] then dups = dups + 1
        elseif strict and P.is_personal(r.email) then seen[r.email] = true; personal = personal + 1
        else seen[r.email] = true; unique[#unique + 1] = r end
    end
    if #unique > P.MAX_EMAILS then
        return nil, ("The file has %d emails; import at most %d at a time."):format(#unique, P.MAX_EMAILS)
    end

    -- Unsubscribed / suppressed: an address on the suppression list, or a CRM contact who opted out.
    local emails = {}
    for i, r in ipairs(unique) do emails[i] = r.email end
    local json = cjson.encode(U.array(emails))
    local blocked = {}
    for _, row in ipairs(db.query([[
        SELECT e.v AS email FROM json_array_elements_text(?::json) e(v)
        WHERE EXISTS (SELECT 1 FROM mkt_suppressions s WHERE s.namespace_id = ?
                        AND (s.channel IS NULL OR s.channel = 'email') AND lower(s.address) = e.v)
           OR EXISTS (SELECT 1 FROM crm_contacts c JOIN mkt_subscriptions s
                        ON s.namespace_id = c.namespace_id AND s.contact_uuid = c.uuid
                      WHERE c.namespace_id = ? AND lower(c.email) = e.v AND c.deleted_at IS NULL
                        AND s.channel = 'email' AND s.status = 'unsubscribed')
    ]], json, ns, ns)) do blocked[row.email] = true end
    local existing = {}
    for _, row in ipairs(db.query([[
        SELECT DISTINCT lower(c.email) AS email FROM crm_contacts c
        JOIN json_array_elements_text(?::json) e(v) ON lower(c.email) = e.v
        WHERE c.namespace_id = ? AND c.deleted_at IS NULL
    ]], json, ns)) do existing[row.email] = true end

    local importable, unsubscribed, known = {}, 0, 0
    for _, r in ipairs(unique) do
        if blocked[r.email] then unsubscribed = unsubscribed + 1
        else
            importable[#importable + 1] = r
            if existing[r.email] then known = known + 1 end
        end
    end
    local sample = {}
    for i = 1, math.min(20, #importable) do sample[i] = importable[i] end
    return {
        type = ext.type,
        importable = importable,
        summary = {
            file_type = ext.type,
            found = #ext.rows,
            importable = #importable,
            new_contacts = #importable - known,
            existing_contacts = known,
            skipped = {
                duplicates = dups,
                personal = personal,
                unsubscribed = unsubscribed,
            },
            personal_rule = strict,
            legal_basis = legal_basis,
            sample = U.array(sample),
        },
    }
end

--- Add the importable rows to a static list. Existing CRM contacts are matched by email and
-- left as they are; nobody with an email opt-out is (re-)subscribed.
function P.import(ns, list, scan, opts)
    local rows = cjson.encode(U.array(scan.importable))
    local evidence
    return U.tx(function()
        local rec = db.query([[
            INSERT INTO mkt_list_imports (namespace_id, list_id, file_name, file_type, source_note, legal_basis,
                found, skipped, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?::jsonb, ?)
            RETURNING id, uuid
        ]], ns, list.id, opts.file_name:sub(1, 255), scan.type, opts.source_note or db.NULL, opts.legal_basis,
            scan.summary.found, cjson.encode(scan.summary.skipped), opts.actor_uuid or db.NULL)[1]
        evidence = "import:" .. rec.uuid .. " file:" .. opts.file_name:sub(1, 200)

        local created = db.query([[
            INSERT INTO crm_contacts (uuid, namespace_id, first_name, last_name, email, phone, owner_user_uuid,
                status, metadata, created_at, updated_at)
            SELECT gen_random_uuid()::text, ?, COALESCE(r.first_name, ''), NULLIF(r.last_name, ''), r.email,
                   NULLIF(r.phone, ''), ?, 'active',
                   jsonb_strip_nulls(jsonb_build_object('company', NULLIF(r.company, ''),
                       'website', NULLIF(r.website, ''), 'source', ?)),
                   NOW(), NOW()
            FROM json_to_recordset(?::json) AS r(email text, first_name text, last_name text, company text,
                                                 phone text, website text)
            WHERE NOT EXISTS (SELECT 1 FROM crm_contacts c WHERE c.namespace_id = ? AND lower(c.email) = r.email
                                AND c.deleted_at IS NULL)
        ]], ns, opts.actor_uuid, evidence, rows, ns).affected_rows or 0

        db.query([[
            CREATE TEMP TABLE mkt_import_contacts ON COMMIT DROP AS
            SELECT DISTINCT ON (lower(c.email)) c.uuid AS contact_uuid
            FROM crm_contacts c JOIN json_to_recordset(?::json) AS r(email text) ON lower(c.email) = r.email
            WHERE c.namespace_id = ? AND c.deleted_at IS NULL
            ORDER BY lower(c.email), c.id
        ]], rows, ns)

        -- Lawful basis for this list (never over an opt-out, never twice), with an audit event.
        db.query([[
            WITH ins AS (
                INSERT INTO mkt_subscriptions (namespace_id, contact_uuid, channel, list_id, status, legal_basis,
                    source, evidence)
                SELECT ?, t.contact_uuid, 'email', ?, 'subscribed', ?, 'import', ?
                FROM mkt_import_contacts t
                WHERE NOT EXISTS (SELECT 1 FROM mkt_subscriptions s WHERE s.namespace_id = ?
                                    AND s.contact_uuid = t.contact_uuid AND s.channel = 'email'
                                    AND (s.status = 'unsubscribed' OR s.list_id = ?))
                RETURNING contact_uuid
            )
            INSERT INTO mkt_subscription_events (namespace_id, contact_uuid, channel, list_id, previous_status,
                new_status, source, evidence, actor_uuid)
            SELECT ?, contact_uuid, 'email', ?, NULL, 'subscribed', 'import', ?, ? FROM ins
        ]], ns, list.id, opts.legal_basis, evidence, ns, list.id,
            ns, list.id, evidence, opts.actor_uuid or db.NULL)

        local imported = db.query([[
            INSERT INTO mkt_list_members (namespace_id, list_id, contact_uuid, source)
            SELECT ?, ?, contact_uuid, 'import' FROM mkt_import_contacts
            ON CONFLICT (namespace_id, list_id, contact_uuid)
            DO UPDATE SET removed_at = NULL, source = 'import', added_at = NOW()
        ]], ns, list.id).affected_rows or 0

        db.query("UPDATE mkt_list_imports SET imported = ?, created_contacts = ? WHERE id = ?",
            imported, created, rec.id)
        local out = {}
        for k, v in pairs(scan.summary) do out[k] = v end
        out.sample = nil
        out.import_uuid = rec.uuid
        out.imported = imported
        out.created_contacts = created
        return out
    end)
end

return P
