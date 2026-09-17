--[[
    Simpro sync engine
    ==================

    Moves records between OpsAPI and a Simpro build, in both directions, and
    writes what it did to simpro_sync_log.

    Pull order matters and is fixed: customers, then sites, then assets, then
    jobs. Each depends on the one before it for its foreign key, so pulling a
    site before its customer would either fail or orphan the row.

    Matching is by simpro_id, never by name. Two DBS sites are called "Cannon
    Street" and two customers are "BNP Paribas"; name matching would merge them.
    A record with no simpro_id has never been to Simpro and is a push candidate;
    a record with one is matched and updated in place.

    Conflict handling is last-writer-wins with a record of the loss. If a row
    changed locally since its last sync AND changed in Simpro, the Simpro copy
    is taken (it is the system of record) and the local values are written into
    the sync log's request_payload so nothing is silently destroyed — an
    operator can see exactly what was overwritten and put it back.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Common = require("queries.FieldServiceCommon")
local SimproClient = require("helper.simpro-client")

local SyncQueries = {}

-- Pull order is a dependency order, not a preference.
local PULL_ORDER = { "customers", "sites", "assets", "jobs" }

-- ---------------------------------------------------------------------------
-- Connection + credentials
-- ---------------------------------------------------------------------------

function SyncQueries.getConnection(namespace_id)
    return db.query([[
        SELECT * FROM simpro_connections
        WHERE namespace_id = ? AND deleted_at IS NULL
        LIMIT 1
    ]], namespace_id)[1]
end

--- Credentials come from the namespace vault, never from the connection row.
--- A mock connection needs none, which is why the demo works with an empty vault.
local function load_credentials(connection)
    if not connection or connection.mode == "mock" then return {} end
    if not connection.credentials_vault_key then return {} end

    local ok, vault = pcall(require, "queries.NamespaceVaultQueries")
    if not ok or not vault or not vault.readSecretValue then return {} end

    local read_ok, value = pcall(vault.readSecretValue,
        connection.namespace_id, connection.credentials_vault_key)
    if not read_ok or not value then return {} end

    local decoded_ok, decoded = pcall(cjson.decode, value)
    return (decoded_ok and type(decoded) == "table") and decoded or {}
end

function SyncQueries.clientFor(namespace_id)
    local connection = SyncQueries.getConnection(namespace_id)
    if not connection then
        return nil, "No Simpro connection is configured for this workspace"
    end
    if not connection.is_active then
        return nil, "The Simpro connection is disabled"
    end
    return SimproClient.new(connection, load_credentials(connection)), connection
end

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------

local function log(namespace_id, batch_uuid, entry)
    -- Logging must never be the reason a sync fails.
    pcall(function()
        db.insert("simpro_sync_log", {
            uuid = Common.uuid(),
            namespace_id = namespace_id,
            batch_uuid = batch_uuid,
            direction = entry.direction,
            entity_type = entry.entity_type,
            entity_uuid = entry.entity_uuid or db.NULL,
            simpro_id = entry.simpro_id and tostring(entry.simpro_id) or db.NULL,
            operation = entry.operation,
            status = entry.status,
            http_status = entry.http_status or db.NULL,
            request_payload = entry.request_payload and cjson.encode(entry.request_payload) or db.NULL,
            response_payload = entry.response_payload and cjson.encode(entry.response_payload) or db.NULL,
            error_message = entry.error_message or db.NULL,
            duration_ms = entry.duration_ms or db.NULL,
            created_by_uuid = entry.actor_uuid or db.NULL,
        })
    end)
end

-- ---------------------------------------------------------------------------
-- Field extraction from Simpro payloads
-- ---------------------------------------------------------------------------

--- Simpro carries an asset's identity fields as named custom fields. Reading
--- them by name keeps this working when a build reorders them.
local function custom_field(record, name)
    for _, cf in ipairs(record.CustomFields or {}) do
        local field_name = cf.CustomField and cf.CustomField.Name
        if field_name == name then return cf.Value end
    end
    return nil
end

local function addr(record, key)
    return record.Address and record.Address[key] or nil
end

-- ---------------------------------------------------------------------------
-- Pull: Simpro -> OpsAPI
-- ---------------------------------------------------------------------------

--- Upsert one record. Returns "created", "updated", "unchanged" or nil+err.
local function upsert(namespace_id, table_name, simpro_id, values, uuid_is_native, insert_defaults)
    simpro_id = tostring(simpro_id)

    local existing = db.query(
        ("SELECT id, uuid, updated_at, simpro_synced_at, simpro_sync_state " ..
         "FROM %s WHERE namespace_id = ? AND simpro_id = ? LIMIT 1"):format(table_name),
        namespace_id, simpro_id)[1]

    if not existing then
        -- Values only a brand-new row needs (a NOT NULL column Simpro did not send),
        -- which must never overwrite what an existing row already holds.
        for k, v in pairs(insert_defaults or {}) do
            if values[k] == nil then values[k] = v end
        end
        values.uuid = uuid_is_native and db.raw("gen_random_uuid()") or Common.uuid()
        values.namespace_id = namespace_id
        values.simpro_id = simpro_id
        values.simpro_synced_at = db.raw("NOW()")
        values.simpro_sync_state = "synced"
        local row = db.insert(table_name, values, { returning = "*" })[1]
        return "created", row
    end

    -- Did this row change locally since we last agreed with Simpro? If so we are
    -- about to overwrite it, which the caller logs as a conflict.
    --
    -- Decided by sync state, not by comparing updated_at with simpro_synced_at:
    -- customers has a trigger that stamps updated_at on every write (including
    -- this one), so a timestamp comparison reports conflicts that are not there.
    -- The write paths that edit Simpro-mirrored rows set the state to 'pending'.
    local diverged = existing.simpro_sync_state == "pending"
        or existing.simpro_sync_state == "error"

    -- Before overwriting a locally-edited row, keep what it held so the sync log
    -- can show exactly what Simpro replaced.
    local before
    if diverged then
        local cols = {}
        for k in pairs(values) do table.insert(cols, db.escape_identifier(k)) end
        if #cols > 0 then
            before = db.query(("SELECT %s FROM %s WHERE id = ?")
                :format(table.concat(cols, ", "), table_name), existing.id)[1]
        end
    end

    values.simpro_synced_at = db.raw("NOW()")
    values.simpro_sync_state = "synced"
    values.updated_at = db.raw("NOW()")
    db.update(table_name, values, { id = existing.id })

    return diverged and "conflict" or "updated", existing, before
end

local PULLERS = {}

PULLERS.customers = function(ctx)
    local records, err = ctx.client:list_all("customers/")
    if not records then return nil, err end

    local stats = { created = 0, updated = 0, conflict = 0, failed = 0 }
    for _, r in ipairs(records) do
        if r.ID then
            -- OpsAPI's customer screens read first_name as the display name, so a
            -- company carries its name there and leaves last_name empty; only an
            -- individual customer is split into given and family names.
            --
            -- A field Simpro did not send is left alone rather than cleared: a
            -- sparse payload (or a `columns=` filtered one) must never blank a
            -- customer's name.
            local is_company = r.CustomerType ~= "Individual"
            local values = {
                company_name = is_company and r.CompanyName or nil,
                first_name = (is_company and r.CompanyName) or r.GivenName or nil,
                last_name = (not is_company) and r.FamilyName or nil,
                email = r.Email,
                phone = r.Phone,
                customer_type = is_company and "company" or "individual",
            }
            local ok_status, outcome, existing, before = pcall(upsert, ctx.namespace_id, "customers", r.ID, values)
            if ok_status and outcome then
                stats[outcome] = (stats[outcome] or 0) + 1
                log(ctx.namespace_id, ctx.batch_uuid, {
                    direction = "pull", entity_type = "customer",
                    entity_uuid = existing and existing.uuid, simpro_id = r.ID,
                    operation = outcome == "created" and "create" or "update",
                    status = outcome == "conflict" and "conflict" or "ok",
                    request_payload = before, response_payload = r, actor_uuid = ctx.actor_uuid,
                })
            else
                stats.failed = stats.failed + 1
                log(ctx.namespace_id, ctx.batch_uuid, {
                    direction = "pull", entity_type = "customer", simpro_id = r.ID,
                    operation = "update", status = "error",
                    error_message = tostring(outcome), actor_uuid = ctx.actor_uuid,
                })
            end
        end
    end
    return stats
end

PULLERS.sites = function(ctx)
    local records, err = ctx.client:list_all("sites/")
    if not records then return nil, err end

    local stats = { created = 0, updated = 0, conflict = 0, failed = 0, skipped = 0 }
    for _, r in ipairs(records) do
        if r.ID then
            -- A site needs its customer; if that customer has not been pulled
            -- yet the site is skipped rather than orphaned, and the next run
            -- (after customers) picks it up.
            local customer_simpro_id = r.Customers and r.Customers[1] and r.Customers[1].ID
            local customer = customer_simpro_id and db.query(
                "SELECT id FROM customers WHERE namespace_id = ? AND simpro_id = ? LIMIT 1",
                ctx.namespace_id, tostring(customer_simpro_id))[1]

            if not customer then
                stats.skipped = stats.skipped + 1
                log(ctx.namespace_id, ctx.batch_uuid, {
                    direction = "pull", entity_type = "site", simpro_id = r.ID,
                    operation = "create", status = "skipped",
                    error_message = "Owning customer has not been pulled yet",
                    response_payload = r, actor_uuid = ctx.actor_uuid,
                })
            else
                local values = {
                    customer_id = customer.id,
                    name = r.Name or "Unnamed site",
                    address_line1 = addr(r, "Address") or db.NULL,
                    city = addr(r, "City") or db.NULL,
                    county = addr(r, "State") or db.NULL,
                    postal_code = addr(r, "PostalCode") or db.NULL,
                    country = addr(r, "Country") or db.NULL,
                    zone = (r.Zone and r.Zone.Name) or db.NULL,
                }
                -- fs_sites.uuid is a native uuid column, not text.
                local outcome, existing, before = upsert(ctx.namespace_id, "fs_sites", r.ID, values, true)
                stats[outcome] = (stats[outcome] or 0) + 1
                log(ctx.namespace_id, ctx.batch_uuid, {
                    direction = "pull", entity_type = "site",
                    entity_uuid = existing and tostring(existing.uuid), simpro_id = r.ID,
                    operation = outcome == "created" and "create" or "update",
                    status = outcome == "conflict" and "conflict" or "ok",
                    request_payload = before, response_payload = r, actor_uuid = ctx.actor_uuid,
                })
            end
        end
    end
    return stats
end

PULLERS.assets = function(ctx)
    local records, err = ctx.client:list_all("customerAssets/")
    if not records then return nil, err end

    local stats = { created = 0, updated = 0, conflict = 0, failed = 0, skipped = 0 }
    for _, r in ipairs(records) do
        local site_simpro_id = r.Site and r.Site.ID
        local site = site_simpro_id and db.query(
            "SELECT id, customer_id FROM fs_sites WHERE namespace_id = ? AND simpro_id = ? LIMIT 1",
            ctx.namespace_id, tostring(site_simpro_id))[1]

        if not (r.ID and site) then
            stats.skipped = stats.skipped + 1
        else
            -- Asset types arrive inline on the asset rather than as their own
            -- pull, so they are created on demand here.
            local type_id = db.NULL
            if r.AssetType and r.AssetType.ID then
                local t = db.query(
                    "SELECT id FROM fs_asset_types WHERE namespace_id = ? AND simpro_id = ? LIMIT 1",
                    ctx.namespace_id, tostring(r.AssetType.ID))[1]
                if not t then
                    t = db.insert("fs_asset_types", {
                        uuid = Common.uuid(), namespace_id = ctx.namespace_id,
                        name = r.AssetType.Name or ("Simpro type " .. tostring(r.AssetType.ID)),
                        simpro_id = tostring(r.AssetType.ID),
                        simpro_sync_state = "synced",
                        simpro_synced_at = db.raw("NOW()"),
                    }, { returning = "*" })[1]
                end
                type_id = t.id
            end

            local charge = tonumber(custom_field(r, "Charge (kg)"))
            local rating = tonumber(custom_field(r, "Condition Rating"))
            local values = {
                site_id = site.id,
                customer_id = site.customer_id or db.NULL,
                asset_type_id = type_id,
                name = custom_field(r, "Description"),
                asset_tag = custom_field(r, "Asset Tag") or db.NULL,
                serial_number = custom_field(r, "Serial Number") or db.NULL,
                manufacturer = custom_field(r, "Manufacturer") or db.NULL,
                model = custom_field(r, "Model") or db.NULL,
                refrigerant_type = custom_field(r, "Refrigerant") or db.NULL,
                refrigerant_charge_kg = charge or db.NULL,
                condition_rating = (rating and rating >= 1 and rating <= 6) and rating or db.NULL,
                archived = r.Archived == true,
                display_order = tonumber(r.DisplayOrder) or 0,
            }

            local outcome, existing, before = upsert(ctx.namespace_id, "fs_assets", r.ID, values, false, {
                name = custom_field(r, "Asset Tag") or (r.AssetType and r.AssetType.Name) or "Simpro asset",
            })
            stats[outcome] = (stats[outcome] or 0) + 1
            log(ctx.namespace_id, ctx.batch_uuid, {
                direction = "pull", entity_type = "asset",
                entity_uuid = existing and existing.uuid, simpro_id = r.ID,
                operation = outcome == "created" and "create" or "update",
                status = outcome == "conflict" and "conflict" or "ok",
                request_payload = before, response_payload = r, actor_uuid = ctx.actor_uuid,
            })
        end
    end
    return stats
end

PULLERS.jobs = function(ctx)
    local records, err = ctx.client:list_all("jobs/")
    if not records then return nil, err end

    local stats = { created = 0, updated = 0, conflict = 0, failed = 0, skipped = 0 }
    for _, r in ipairs(records) do
        -- Only update jobs we already know about. Creating a job locally from a
        -- Simpro pull would need a job type, phases and a request to hang off,
        -- none of which the jobs payload carries — so that stays a push-only
        -- direction for now and is logged as skipped rather than silently
        -- dropped.
        local existing = r.ID and db.query(
            "SELECT id, uuid FROM fs_jobs WHERE namespace_id = ? AND simpro_id = ? LIMIT 1",
            ctx.namespace_id, tostring(r.ID))[1]

        if not existing then
            stats.skipped = stats.skipped + 1
            log(ctx.namespace_id, ctx.batch_uuid, {
                direction = "pull", entity_type = "job", simpro_id = r.ID,
                operation = "create", status = "skipped",
                error_message = "Jobs are created in OpsAPI and pushed; no local match",
                response_payload = r, actor_uuid = ctx.actor_uuid,
            })
        else
            local stage = tostring(r.Stage or "Pending"):lower()
            local VALID = { pending = true, progress = true, complete = true, archived = true }
            local values = {
                stage = VALID[stage] and stage or "pending",
                order_no = r.OrderNo or db.NULL,
                total_ex_tax = (r.Total and tonumber(r.Total.ExTax)) or db.NULL,
                total_inc_tax = (r.Total and tonumber(r.Total.IncTax)) or db.NULL,
            }
            local outcome, _, before = upsert(ctx.namespace_id, "fs_jobs", r.ID, values)
            stats[outcome] = (stats[outcome] or 0) + 1
            log(ctx.namespace_id, ctx.batch_uuid, {
                direction = "pull", entity_type = "job",
                entity_uuid = existing.uuid, simpro_id = r.ID,
                operation = "update",
                status = outcome == "conflict" and "conflict" or "ok",
                request_payload = before, response_payload = r, actor_uuid = ctx.actor_uuid,
            })
        end
    end
    return stats
end

--- Pull one or more entity types from Simpro.
function SyncQueries.pull(namespace_id, actor_uuid, params)
    params = params or {}
    local client, connection = SyncQueries.clientFor(namespace_id)
    if not client then return nil, connection end
    if not connection.pull_enabled then
        return nil, "Pulling is disabled on this Simpro connection"
    end

    local wanted = {}
    if params.entities and params.entities ~= "" then
        for name in tostring(params.entities):gmatch("[^,%s]+") do wanted[name] = true end
    end

    local batch_uuid = Common.uuid()
    local started = os.time()
    local results, failures = {}, {}

    for _, entity in ipairs(PULL_ORDER) do
        if next(wanted) == nil or wanted[entity] then
            local ctx = {
                namespace_id = namespace_id, client = client,
                batch_uuid = batch_uuid, actor_uuid = actor_uuid,
            }
            local stats, err = PULLERS[entity](ctx)
            if stats then
                results[entity] = stats
            else
                failures[entity] = err
                log(namespace_id, batch_uuid, {
                    direction = "pull", entity_type = entity, operation = "read",
                    status = "error", error_message = err, actor_uuid = actor_uuid,
                })
            end
        end
    end

    db.update("simpro_connections", {
        last_pull_at = db.raw("NOW()"),
        last_error = next(failures) and cjson.encode(failures) or db.NULL,
        updated_at = db.raw("NOW()"),
    }, { id = connection.id })

    return {
        batch_uuid = batch_uuid,
        direction = "pull",
        mode = connection.mode,
        duration_seconds = os.time() - started,
        results = results,
        failures = next(failures) and failures or nil,
    }
end

-- ---------------------------------------------------------------------------
-- Push: OpsAPI -> Simpro
-- ---------------------------------------------------------------------------

--- What a push sends for each entity, and how to find the rows that need it.
local PUSHERS = {
    customers = {
        entity_type = "customer",
        resource = "customers/",
        select = [[
            SELECT id, uuid, simpro_id, company_name, first_name, last_name,
                   email, phone, customer_type
            FROM customers
            WHERE namespace_id = ? AND simpro_sync_state IN ('pending', 'local_only')
            ORDER BY id LIMIT ?
        ]],
        payload = function(r)
            local individual = r.customer_type == "individual"
            return {
                CustomerType = individual and "Individual" or "Company",
                CompanyName = r.company_name or (not individual and r.first_name) or nil,
                GivenName = individual and r.first_name or nil,
                FamilyName = individual and r.last_name or nil,
                Email = r.email,
                Phone = r.phone,
            }
        end,
    },
    sites = {
        entity_type = "site",
        resource = "sites/",
        select = [[
            SELECT s.id, s.uuid, s.simpro_id, s.name, s.address_line1, s.city, s.county,
                   s.postal_code, s.country, s.zone, c.simpro_id AS customer_simpro_id
            FROM fs_sites s
            JOIN customers c ON c.id = s.customer_id
            WHERE s.namespace_id = ?
              AND s.deleted_at IS NULL
              AND s.simpro_sync_state IN ('pending', 'local_only')
              AND c.simpro_id IS NOT NULL
            ORDER BY s.id LIMIT ?
        ]],
        payload = function(r)
            return {
                Name = r.name,
                Address = {
                    Address = r.address_line1, City = r.city, State = r.county,
                    PostalCode = r.postal_code, Country = r.country or "United Kingdom",
                },
                Customers = { tonumber(r.customer_simpro_id) or r.customer_simpro_id },
            }
        end,
    },
    assets = {
        entity_type = "asset",
        -- Assets are written under their site in Simpro, so the resource is
        -- per-row rather than fixed.
        resource = function(r)
            return ("sites/%s/assets/"):format(tostring(r.site_simpro_id))
        end,
        select = [[
            SELECT a.id, a.uuid, a.simpro_id, a.asset_tag, a.name, a.serial_number,
                   a.manufacturer, a.model, a.refrigerant_type,
                   a.refrigerant_charge_kg, a.condition_rating, a.archived,
                   at.simpro_id AS type_simpro_id,
                   s.simpro_id AS site_simpro_id
            FROM fs_assets a
            LEFT JOIN fs_asset_types at ON at.id = a.asset_type_id
            LEFT JOIN fs_sites s        ON s.id = a.site_id
            WHERE a.namespace_id = ?
              AND a.deleted_at IS NULL
              AND a.simpro_sync_state IN ('pending', 'local_only')
              AND s.simpro_id IS NOT NULL
            ORDER BY a.id LIMIT ?
        ]],
        payload = function(r)
            return {
                AssetType = r.type_simpro_id and tonumber(r.type_simpro_id) or nil,
                Archived = r.archived == true,
                CustomFields = {
                    { Name = "Asset Tag", Value = r.asset_tag },
                    { Name = "Description", Value = r.name },
                    { Name = "Serial Number", Value = r.serial_number },
                    { Name = "Manufacturer", Value = r.manufacturer },
                    { Name = "Model", Value = r.model },
                    { Name = "Refrigerant", Value = r.refrigerant_type },
                    { Name = "Charge (kg)",
                      Value = r.refrigerant_charge_kg and tostring(r.refrigerant_charge_kg) or nil },
                    { Name = "Condition Rating",
                      Value = r.condition_rating and tostring(r.condition_rating) or nil },
                },
            }
        end,
    },
}

PUSHERS.jobs = {
    entity_type = "job",
    resource = "jobs/",
    -- A job can only be written once Simpro knows its customer and site.
    select = [[
        SELECT j.id, j.uuid, j.simpro_id, j.title, j.description, j.kind, j.stage,
               j.order_no, j.customer_reference, j.due_date, j.date_issued,
               c.simpro_id AS customer_simpro_id, s.simpro_id AS site_simpro_id
        FROM fs_jobs j
        JOIN customers c ON c.id = j.customer_id
        JOIN fs_sites s  ON s.id = j.site_id
        WHERE j.namespace_id = ?
          AND j.deleted_at IS NULL
          AND j.simpro_sync_state IN ('pending', 'local_only')
          AND c.simpro_id IS NOT NULL AND s.simpro_id IS NOT NULL
        ORDER BY j.id LIMIT ?
    ]],
    payload = function(r)
        return {
            Type = (r.kind == "project") and "Project" or "Service",
            Customer = tonumber(r.customer_simpro_id) or r.customer_simpro_id,
            Site = tonumber(r.site_simpro_id) or r.site_simpro_id,
            Name = r.title,
            Description = r.description,
            Stage = (r.stage or "pending"):gsub("^%l", string.upper),
            OrderNo = r.order_no or r.customer_reference,
            DueDate = r.due_date,
            DateIssued = r.date_issued,
        }
    end,
}

PUSHERS.quotes = {
    entity_type = "quote",
    resource = "quotes/",
    select = [[
        SELECT q.id, q.uuid, q.simpro_id, q.title, q.description, q.stage, q.status,
               q.date_issued, q.valid_until, q.customer_order_no, q.total_amount,
               c.simpro_id AS customer_simpro_id, s.simpro_id AS site_simpro_id
        FROM fs_quotes q
        JOIN customers c ON c.id = q.customer_id
        LEFT JOIN fs_sites s ON s.id = q.site_id
        WHERE q.namespace_id = ?
          AND q.deleted_at IS NULL
          AND q.simpro_sync_state IN ('pending', 'local_only')
          AND c.simpro_id IS NOT NULL
        ORDER BY q.id LIMIT ?
    ]],
    payload = function(r)
        return {
            Customer = tonumber(r.customer_simpro_id) or r.customer_simpro_id,
            Site = r.site_simpro_id and (tonumber(r.site_simpro_id) or r.site_simpro_id) or nil,
            Name = r.title,
            Description = r.description,
            Stage = ({ in_progress = "InProgress", complete = "Complete",
                       approved = "Approved", archived = "Archived" })[r.stage] or "InProgress",
            DateIssued = r.date_issued,
            DueDate = r.valid_until,
            OrderNo = r.customer_order_no,
        }
    end,
}

-- Push order is a dependency order: a site needs its customer's Simpro id, and a
-- job or quote needs both.
local PUSH_ORDER = { "customers", "sites", "assets", "jobs", "quotes" }

-- Table each entity's rows live in, for the post-push state update.
local PUSH_TABLE = {
    customers = "customers", sites = "fs_sites", assets = "fs_assets",
    jobs = "fs_jobs", quotes = "fs_quotes",
}

--- Push locally-changed records to Simpro.
function SyncQueries.push(namespace_id, actor_uuid, params)
    params = params or {}
    local client, connection = SyncQueries.clientFor(namespace_id)
    if not client then return nil, connection end
    if not client:can_write() then
        return nil, ("Pushing is disabled: the connection is in %s mode with push_enabled off")
            :format(connection.mode)
    end

    -- A push is a burst of outbound HTTP inside one request, so it is capped.
    -- The remainder stays queued and the next run takes it.
    local batch_limit = math.min(math.max(tonumber(params.limit) or 100, 1), 500)

    local wanted = {}
    if params.entities and params.entities ~= "" then
        for name in tostring(params.entities):gmatch("[^,%s]+") do wanted[name] = true end
    end

    local batch_uuid = Common.uuid()
    local started = os.time()
    local results = {}

    for _, entity in ipairs(PUSH_ORDER) do
        local spec = PUSHERS[entity]
        if next(wanted) == nil or wanted[entity] then
            local stats = { created = 0, updated = 0, failed = 0 }
            local rows = db.query(db.interpolate_query(spec.select, namespace_id, batch_limit))

            for _, r in ipairs(rows) do
                local resource = type(spec.resource) == "function"
                    and spec.resource(r) or spec.resource
                local payload = spec.payload(r)

                local response, err, status
                if r.simpro_id then
                    response, err, status = client:patch(resource .. tostring(r.simpro_id), payload)
                else
                    response, err, status = client:post(resource, payload)
                end

                if response then
                    local simpro_id = response.ID and tostring(response.ID) or r.simpro_id
                    db.update(PUSH_TABLE[entity], {
                        simpro_id = simpro_id or db.NULL,
                        simpro_sync_state = "synced",
                        simpro_synced_at = db.raw("NOW()"),
                    }, { id = r.id })

                    local op = r.simpro_id and "update" or "create"
                    stats[r.simpro_id and "updated" or "created"] =
                        stats[r.simpro_id and "updated" or "created"] + 1
                    log(namespace_id, batch_uuid, {
                        direction = "push", entity_type = spec.entity_type,
                        entity_uuid = tostring(r.uuid), simpro_id = simpro_id,
                        operation = op, status = "ok",
                        request_payload = payload, response_payload = response,
                        actor_uuid = actor_uuid,
                    })
                else
                    -- Mark the row errored rather than leaving it 'pending', so a
                    -- repeatedly failing record is visible instead of silently
                    -- retried forever.
                    db.update(PUSH_TABLE[entity],
                        { simpro_sync_state = "error" }, { id = r.id })
                    stats.failed = stats.failed + 1
                    log(namespace_id, batch_uuid, {
                        direction = "push", entity_type = spec.entity_type,
                        entity_uuid = tostring(r.uuid), simpro_id = r.simpro_id,
                        operation = r.simpro_id and "update" or "create",
                        status = "error", http_status = status,
                        request_payload = payload, error_message = err,
                        actor_uuid = actor_uuid,
                    })
                end
            end

            stats.queued_remaining = (#rows == batch_limit) and "more" or 0
            results[entity] = stats
        end
    end

    db.update("simpro_connections",
        { last_push_at = db.raw("NOW()"), updated_at = db.raw("NOW()") },
        { id = connection.id })

    return {
        batch_uuid = batch_uuid,
        direction = "push",
        mode = connection.mode,
        duration_seconds = os.time() - started,
        results = results,
    }
end

-- ---------------------------------------------------------------------------
-- Status + log
-- ---------------------------------------------------------------------------

--- How much is waiting to go, per table, plus the connection's own state.
function SyncQueries.status(namespace_id)
    local connection = SyncQueries.getConnection(namespace_id)

    local counts = {}
    local TABLES = {
        { "customers", "customers" }, { "fs_sites", "sites" },
        { "fs_assets", "assets" }, { "fs_jobs", "jobs" },
        { "fs_quotes", "quotes" }, { "invoices", "invoices" },
        { "fs_asset_test_history", "asset_tests" },
    }
    for _, t in ipairs(TABLES) do
        local ok, row = pcall(function()
            return db.query(([[
                SELECT
                    COUNT(*) FILTER (WHERE simpro_sync_state = 'synced')     AS synced,
                    COUNT(*) FILTER (WHERE simpro_sync_state = 'pending')    AS pending,
                    COUNT(*) FILTER (WHERE simpro_sync_state = 'error')      AS errored,
                    COUNT(*) FILTER (WHERE simpro_sync_state = 'local_only') AS local_only,
                    COUNT(*)                                                 AS total
                FROM %s WHERE namespace_id = ?
            ]]):format(t[1]), namespace_id)[1]
        end)
        if ok and row then counts[t[2]] = row end
    end

    local recent = db.query([[
        SELECT status, COUNT(*) AS n
        FROM simpro_sync_log
        WHERE namespace_id = ? AND created_at > NOW() - INTERVAL '7 days'
        GROUP BY status
    ]], namespace_id)

    return {
        connected = connection ~= nil,
        connection = connection and {
            uuid = connection.uuid, name = connection.name,
            base_url = connection.base_url, company_id = connection.company_id,
            mode = connection.mode,
            push_enabled = connection.push_enabled, pull_enabled = connection.pull_enabled,
            is_active = connection.is_active,
            last_pull_at = connection.last_pull_at, last_push_at = connection.last_push_at,
            last_error = connection.last_error,
            -- Deliberately absent: credentials_vault_key. Even the key name is
            -- not something a dashboard needs.
        } or nil,
        counts = counts,
        last_7_days = recent,
    }
end

function SyncQueries.listLog(namespace_id, params)
    params = params or {}
    local page, per_page, offset = Common.paging(params)
    local where, values = { "namespace_id = ?" }, { namespace_id }

    if params.status and params.status ~= "" then
        table.insert(where, "status = ?")
        table.insert(values, params.status)
    end
    if params.entity_type and params.entity_type ~= "" then
        table.insert(where, "entity_type = ?")
        table.insert(values, params.entity_type)
    end
    if params.batch_uuid and params.batch_uuid ~= "" then
        table.insert(where, "batch_uuid = ?")
        table.insert(values, params.batch_uuid)
    end

    local clause = table.concat(where, " AND ")
    local total = db.query(db.interpolate_query(
        "SELECT COUNT(*) AS n FROM simpro_sync_log WHERE " .. clause, unpack(values)))[1]

    local list_values = {}
    for _, v in ipairs(values) do table.insert(list_values, v) end
    table.insert(list_values, per_page)
    table.insert(list_values, offset)

    local rows = db.query(db.interpolate_query([[
        SELECT uuid, direction, entity_type, entity_uuid, simpro_id, operation,
               status, http_status, error_message, duration_ms, batch_uuid, created_at
        FROM simpro_sync_log WHERE ]] .. clause .. [[
        ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?
    ]], unpack(list_values)))

    return { items = Common.arr(rows), meta = Common.meta(total and total.n, page, per_page) }
end

--- Create or update the workspace's connection.
function SyncQueries.saveConnection(namespace_id, actor_uuid, body)
    body = body or {}
    local existing = SyncQueries.getConnection(namespace_id)

    local mode = body.mode or (existing and existing.mode) or "mock"
    local VALID = { mock = true, sandbox = true, live = true }
    if not VALID[mode] then return nil, "Mode must be one of: mock, sandbox, live" end

    -- A real build needs somewhere to point at; the mock does not.
    local base_url = body.base_url or (existing and existing.base_url)
    if mode ~= "mock" and (not base_url or base_url == "") then
        return nil, "A base URL is required for a sandbox or live connection"
    end

    local patch = {
        name = body.name or (existing and existing.name) or "Simpro",
        base_url = base_url or "mock://simpro",
        company_id = tostring(body.company_id or (existing and existing.company_id) or "0"),
        mode = mode,
        credentials_vault_key = body.credentials_vault_key
            or (existing and existing.credentials_vault_key) or db.NULL,
        sync_interval_minutes = tonumber(body.sync_interval_minutes)
            or (existing and existing.sync_interval_minutes) or 15,
        updated_at = db.raw("NOW()"),
    }

    if body.pull_enabled ~= nil then
        patch.pull_enabled = Common.to_bool(body.pull_enabled, true)
    end
    -- Turning on pushes to a live build is the one switch that can modify DBS's
    -- system of record, so it is never inferred — only an explicit true sets it.
    if body.push_enabled ~= nil then
        patch.push_enabled = Common.to_bool(body.push_enabled, false)
    end
    if body.is_active ~= nil then
        patch.is_active = Common.to_bool(body.is_active, true)
    end

    if existing then
        db.update("simpro_connections", patch, { id = existing.id })
    else
        patch.uuid = Common.uuid()
        patch.namespace_id = namespace_id
        patch.created_by_uuid = actor_uuid
        db.insert("simpro_connections", patch)
    end

    return SyncQueries.status(namespace_id)
end

SyncQueries.PULL_ORDER = PULL_ORDER

return SyncQueries
