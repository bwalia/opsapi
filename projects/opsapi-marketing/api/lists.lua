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

local Prospects = require("opsapi_marketing.prospects")
local parse_csv_line = Prospects.parse_csv_line

return function(app)
    sdk.crud(app, "/lists", {
        table = "mkt_lists",
        module = "opsapi_marketing_lists",
        fields = {
            name = { type = "string", required = true },
            description = { type = "text" },
            list_type = { type = "string", enum = { "static", "dynamic" } },
            channel = { type = "string", enum = U.CHANNEL_ENUM },
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
                -- Stored as E.164 when it parses: clean() would strip the leading "+".
                local raw_phone = col.phone and cols[col.phone] or ""
                local phone = U.e164(raw_phone) or clean(raw_phone) or ""

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

    -- Contacts from a file (CSV, XLSX or PDF of business contacts): every email in it is
    -- found; commit=false previews what would be imported, commit=true (+ confirm) imports.
    app:post("/lists/:id/prospects", sdk.handler({ permission = "opsapi_marketing_lists.update" }, function(self)
        local ns = sdk.namespace_id(self)
        local list = find_list(ns, self.params.id)
        if not list then return sdk.not_found("list") end
        if list.list_type == "dynamic" or (list.channel and list.channel ~= "email") then
            return sdk.error(400, "Import into a static email list")
        end
        local body, berr = sdk.body(self)
        if not body then return sdk.error(400, berr) end
        local b64 = type(body.content_base64) == "string" and body.content_base64:gsub("^data:[^,]*,", "")
        local bytes = b64 and ngx.decode_base64(b64)
        if not bytes or #bytes == 0 then return sdk.error(400, "content_base64 (the file, base64) is required") end
        if #bytes > Prospects.MAX_BYTES then return sdk.error(413, "File too large: the limit is 7 MB") end
        local basis = body.legal_basis or "legitimate_interest"
        if basis ~= "legitimate_interest" and basis ~= "consent" then
            return sdk.error(422, "legal_basis must be legitimate_interest or consent")
        end
        local file_name = tostring(body.file_name or "upload")
        local scan, err = Prospects.scan(ns, file_name, bytes, basis)
        if not scan then return sdk.error(400, err) end
        if body.commit ~= true then return sdk.ok(scan.summary) end
        if #scan.importable == 0 then return sdk.error(400, "Nothing to import from this file") end
        if body.confirm ~= true then
            return sdk.error(400, "Confirm you may email these contacts and that every email lets them unsubscribe.",
                { code = "confirm_required" })
        end
        local user = sdk.user(self) or {}
        if not user.uuid then return sdk.error(400, "missing user") end
        return sdk.ok(Prospects.import(ns, list, scan, {
            file_name = file_name,
            source_note = type(body.source_note) == "string" and body.source_note:sub(1, 1000) or nil,
            legal_basis = basis,
            actor_uuid = user.uuid,
        }))
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
                   c.first_name, c.last_name, c.email, c.phone,
                   COALESCE(a.name, c.metadata->>'company') AS company
            FROM mkt_list_members m
            LEFT JOIN crm_contacts c ON c.uuid = m.contact_uuid AND c.namespace_id = m.namespace_id
            LEFT JOIN crm_accounts a ON a.id = c.account_id AND a.namespace_id = c.namespace_id
            WHERE m.namespace_id = ? AND m.list_id = ? AND m.removed_at IS NULL
            ORDER BY m.added_at DESC LIMIT 500
        ]], ns, list.id)
        -- The newest 500 are listed; meta.total is the real size (imports run to thousands).
        local total = U.one([[
            SELECT COUNT(*)::int AS n FROM mkt_list_members WHERE namespace_id = ? AND list_id = ? AND removed_at IS NULL
        ]], ns, list.id)
        return sdk.ok(sdk.array(rows), { total = total and total.n or #rows })
    end))
end
