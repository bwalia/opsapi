local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local cjson = require("cjson")
local sdk = require("helper.plugin-sdk")
local U = require("opsapi_marketing.util")
local Seg = require("opsapi_marketing.segments")
local E = require("opsapi_marketing.eligibility")
local db = require("lapis.db")

local function find_list(ns, id)
    if U.is_uuid(id) then
        return U.one("SELECT * FROM mkt_lists WHERE namespace_id = ? AND uuid = ?", ns, id)
    end
    return U.one("SELECT * FROM mkt_lists WHERE namespace_id = ? AND id = ?", ns, tonumber(id))
end

local function parse_csv_line(line)
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

return function(app)
    sdk.crud(app, "/lists", {
        table = "mkt_lists",
        module = "opsapi_marketing_lists",
        fields = {
            name = { type = "string", required = true },
            description = { type = "text" },
            list_type = { type = "string", enum = { "static", "dynamic" } },
            channel = { type = "string", enum = { "email", "sms", "push", "webhook" } },
        },
        searchable = { "name", "description" },
        filterable = { "list_type", "channel" },
        sortable = { "name", "list_type", "created_at", "updated_at" },
        ui = {
            label = "Lists",
            columns = { "name", "list_type", "channel" },
            form = { "name", "list_type", "channel", "description" },
        },
    })

    app:get("/segments/fields", sdk.handler({ permission = "opsapi_marketing_lists.read" }, function()
        return sdk.ok({ fields = sdk.array(Seg.fields()), ops = sdk.array(Seg.ops()) })
    end))

    app:post("/segments/preview", sdk.handler({ permission = "opsapi_marketing_lists.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local body = sdk.body(self) or {}
        local out, err = Seg.preview(ns, body.rule or body, body.limit)
        if not out then return sdk.error(400, err) end
        return sdk.ok(out)
    end))

    app:put("/lists/:id/segment", sdk.handler({ permission = "opsapi_marketing_lists.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local list = find_list(ns, self.params.id)
        if not list then return sdk.not_found("list") end
        local body = sdk.body(self) or {}
        local rule = body.rule or body.segment_rule or {}
        -- Validate by compiling
        local preview, err = Seg.preview(ns, rule, 1)
        if not preview then return sdk.error(400, err) end
        db.query([[
            UPDATE mkt_lists SET list_type = 'dynamic', segment_rule = ?::jsonb, updated_at = NOW()
            WHERE id = ?
        ]], cjson.encode(rule), list.id)
        if body.sync == true then
            local sync, serr = Seg.sync_list(ns, list.id)
            if not sync then return sdk.error(400, serr) end
            return sdk.ok({ list = U.one("SELECT * FROM mkt_lists WHERE id = ?", list.id), sync = sync })
        end
        return sdk.ok(U.one("SELECT * FROM mkt_lists WHERE id = ?", list.id))
    end))

    app:post("/lists/:id/sync", sdk.handler({ permission = "opsapi_marketing_lists.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local list = find_list(ns, self.params.id)
        if not list then return sdk.not_found("list") end
        local sync, err = Seg.sync_list(ns, list.id)
        if not sync then return sdk.error(400, err) end
        return sdk.ok(sync)
    end))

    -- CSV import: header row email,first_name,last_name,phone — max 2000 rows
    app:post("/lists/:id/import", sdk.handler({ permission = "opsapi_marketing_lists.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local list = find_list(ns, self.params.id)
        if not list then return sdk.not_found("list") end
        local body = sdk.body(self) or {}
        local csv = body.csv
        if type(csv) ~= "string" or #csv < 3 then return sdk.error(400, "csv required") end
        if #csv > 2 * 1024 * 1024 then return sdk.error(400, "csv too large") end

        local lines = {}
        for line in (csv .. "\n"):gmatch("(.-)\r?\n") do
            if line ~= "" then lines[#lines + 1] = line end
        end
        if #lines < 2 then return sdk.error(400, "csv needs header + rows") end
        if #lines > 2001 then return sdk.error(400, "max 2000 rows") end

        local headers = parse_csv_line(lines[1])
        local col = {}
        for i, h in ipairs(headers) do
            col[h:lower():gsub("^%s*(.-)%s*$", "%1")] = i
        end
        if not col.email then return sdk.error(400, "csv must include email column") end

        local user = sdk.user(self) or {}
        local owner = user.uuid
        if not owner then return sdk.error(400, "missing user") end

        local added, created, skipped, errors = 0, 0, 0, {}
        for r = 2, #lines do
            local cols = parse_csv_line(lines[r])
            local email = U.norm_email(cols[col.email] or "")
            if not email then
                skipped = skipped + 1
                if #errors < 20 then errors[#errors + 1] = { row = r, error = "invalid_email" } end
            else
                -- Formula-injection: strip leading = + - @ from text fields
                local function clean(s)
                    if type(s) ~= "string" then return s end
                    return (s:gsub("^[%s%=%+%-%@]+", ""))
                end
                local first = clean(col.first_name and cols[col.first_name] or "") or "Contact"
                local last = clean(col.last_name and cols[col.last_name] or "") or ""
                local phone = clean(col.phone and cols[col.phone] or "") or ""

                local contact = U.one([[
                    SELECT uuid FROM crm_contacts
                    WHERE namespace_id = ? AND lower(email) = lower(?) AND deleted_at IS NULL
                    LIMIT 1
                ]], ns, email)
                if not contact then
                    local uuid = require("helper.global").generateUUID()
                    db.query([[
                        INSERT INTO crm_contacts
                            (uuid, namespace_id, first_name, last_name, email, phone, owner_user_uuid, status, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, 'active', NOW(), NOW())
                    ]], uuid, ns, first ~= "" and first or "Contact", last ~= "" and last or db.NULL,
                        email, phone ~= "" and phone or db.NULL, owner)
                    contact = { uuid = uuid }
                    created = created + 1
                end
                -- Record consent for new contacts and for existing ones with no prior
                -- decision on this channel; never override an earlier opt-out.
                local channel = list.channel or "email"
                if body.grant_consent == true and not U.one([[
                    SELECT id FROM mkt_subscriptions WHERE namespace_id = ? AND contact_uuid = ? AND channel = ?
                    LIMIT 1
                ]], ns, contact.uuid, channel) then
                    E.opt_in(ns, contact.uuid, channel, {
                        list_id = list.id,
                        source = "csv_import",
                        legal_basis = body.legal_basis or "consent",
                        evidence = "csv_import_row_" .. r,
                        actor_uuid = owner,
                    })
                end
                db.query([[
                    INSERT INTO mkt_list_members (namespace_id, list_id, contact_uuid, source)
                    VALUES (?, ?, ?, 'csv')
                    ON CONFLICT (namespace_id, list_id, contact_uuid)
                    DO UPDATE SET removed_at = NULL, source = 'csv', added_at = NOW()
                ]], ns, list.id, contact.uuid)
                added = added + 1
            end
        end
        return sdk.ok({ added = added, created = created, skipped = skipped, errors = sdk.array(errors) })
    end))

    app:post("/lists/:id/members", sdk.handler({ permission = "opsapi_marketing_lists.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local list = find_list(ns, self.params.id)
        if not list then return sdk.not_found("list") end
        local body = sdk.body(self) or {}
        local contact_uuid = body.contact_uuid
        if not U.is_uuid(contact_uuid) then return sdk.error(400, "contact_uuid required") end
        local contact = U.one("SELECT uuid FROM crm_contacts WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL", ns, contact_uuid)
        if not contact then return sdk.error(400, "contact not in this workspace") end

        db.query([[
            INSERT INTO mkt_list_members (namespace_id, list_id, contact_uuid, source)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (namespace_id, list_id, contact_uuid)
            DO UPDATE SET removed_at = NULL, source = EXCLUDED.source, added_at = NOW()
        ]], ns, list.id, contact_uuid, body.source or "manual")

        return sdk.created(U.one([[
            SELECT * FROM mkt_list_members WHERE namespace_id = ? AND list_id = ? AND contact_uuid = ?
        ]], ns, list.id, contact_uuid))
    end))

    app:delete("/lists/:id/members/:contact_uuid", sdk.handler({ permission = "opsapi_marketing_lists.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local list = find_list(ns, self.params.id)
        if not list then return sdk.not_found("list") end
        db.query([[
            UPDATE mkt_list_members SET removed_at = NOW()
            WHERE namespace_id = ? AND list_id = ? AND contact_uuid = ? AND removed_at IS NULL
        ]], ns, list.id, self.params.contact_uuid)
        return sdk.ok({ removed = true })
    end))

    app:get("/lists/:id/members", sdk.handler({ permission = "opsapi_marketing_lists.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local list = find_list(ns, self.params.id)
        if not list then return sdk.not_found("list") end
        local rows = db.query([[
            SELECT m.uuid, m.contact_uuid, m.source, m.added_at,
                   c.first_name, c.last_name, c.email, c.phone
            FROM mkt_list_members m
            LEFT JOIN crm_contacts c ON c.uuid = m.contact_uuid AND c.namespace_id = m.namespace_id
            WHERE m.namespace_id = ? AND m.list_id = ? AND m.removed_at IS NULL
            ORDER BY m.added_at DESC LIMIT 500
        ]], ns, list.id)
        return sdk.ok(sdk.array(rows))
    end))
end
