--[[
    Simpro mock build
    =================

    Stands in for a real Simpro build so the connector can be demonstrated, and
    tested, without credentials. It is a genuine implementation of the subset of
    Simpro's API the sync uses — same paths, same JSON shapes, same paging
    contract — so switching a connection from `mock` to `sandbox` changes the
    base URL and nothing else in the calling code.

    Where the data comes from:

      * Records that already carry a simpro_id are projected out of the local
        tables into Simpro's shape. That makes a pull idempotent, which is the
        property worth proving: run it twice, nothing doubles.
      * A small fixed set of Simpro-only records (MOCK_ONLY below) is served
        alongside them. These have no local counterpart, so the first pull
        visibly creates rows — a sync that only ever says "0 changes" demos
        nothing.
      * A POST mints a new id in Simpro's numeric-string style and echoes the
        record back the way Simpro does, so the push path exercises the same
        "read the id out of the response" code a live build would.

    What it deliberately does NOT do: persist pushes. The mock has no store of
    its own, so a pushed record is acknowledged and forgotten. That is the one
    place it diverges from a real build, and the sync engine is written not to
    depend on read-after-write.
]]

local db = require("lapis.db")

local Mock = {}

-- Ids are minted in a band well clear of the seeded ones so a mock id is
-- recognisable at a glance in the sync log during a demo. They come from a
-- sequence, not the clock: a push sends a batch within the same millisecond,
-- and two records sharing an id would make the next pull merge them.
local MINT_BASE = 900000

local function mint_id()
    db.query(("CREATE SEQUENCE IF NOT EXISTS simpro_mock_ids START %d"):format(MINT_BASE))
    return tonumber(db.query("SELECT nextval('simpro_mock_ids') AS id")[1].id)
end

--- Simpro-only records: present in the "build", absent locally. The first pull
--- creates them, which is what makes the demo show a non-zero result.
local MOCK_ONLY = {
    customers = {
        {
            ID = 880001,
            CompanyName = "Mitie Property Services (UK) Ltd",
            GivenName = "Rachel", FamilyName = "Okonjo",
            Email = "rachel.okonjo@mitie-property.example",
            Phone = "+44 20 7946 1180",
            CustomerType = "Company",
            Archived = false,
        },
        {
            ID = 880002,
            CompanyName = "Lendlease Construction (Europe) Ltd",
            GivenName = "Tom", FamilyName = "Bracewell",
            Email = "tom.bracewell@lendlease-eu.example",
            Phone = "+44 20 7946 1204",
            CustomerType = "Company",
            Archived = false,
        },
    },
    sites = {
        {
            ID = 881001,
            Name = "Elizabeth House — 39 York Road",
            Address = {
                Address = "39 York Road", City = "London",
                State = "Greater London", PostalCode = "SE1 7NQ", Country = "United Kingdom",
            },
            Zone = { ID = 3, Name = "London South" },
            Customers = { { ID = 880001 } },
        },
    },
}

-- ---------------------------------------------------------------------------
-- Projections: local row -> Simpro shape
-- ---------------------------------------------------------------------------

local function address_of(row)
    return {
        Address = row.address_line1,
        City = row.city,
        State = row.county,
        PostalCode = row.postal_code,
        Country = row.country or "United Kingdom",
    }
end

local function project_customer(r)
    local individual = r.customer_type == "individual"
    return {
        ID = tonumber(r.simpro_id) or r.simpro_id,
        -- Customers created before the Simpro columns existed carry the company
        -- in first_name only.
        CompanyName = (not individual) and (r.company_name or r.first_name) or nil,
        GivenName = (r.customer_type == "individual") and r.first_name or nil,
        FamilyName = (r.customer_type == "individual") and r.last_name or nil,
        Email = r.email,
        Phone = r.phone,
        CustomerType = (r.customer_type == "individual") and "Individual" or "Company",
        Archived = false,
    }
end

local function project_site(r)
    return {
        ID = tonumber(r.simpro_id) or r.simpro_id,
        Name = r.name,
        Address = address_of(r),
        Zone = r.zone and { Name = r.zone } or nil,
        Customers = r.customer_simpro_id
            and { { ID = tonumber(r.customer_simpro_id) or r.customer_simpro_id } } or {},
    }
end

local function project_asset(r)
    return {
        ID = tonumber(r.simpro_id) or r.simpro_id,
        AssetType = {
            ID = tonumber(r.type_simpro_id) or r.type_simpro_id,
            Name = r.asset_type_name,
        },
        Site = { ID = tonumber(r.site_simpro_id) or r.site_simpro_id, Name = r.site_name },
        -- Simpro carries the free-text identity fields as custom fields on the
        -- asset; the sync reads them back out of CustomFields by name.
        CustomFields = {
            { CustomField = { Name = "Asset Tag" }, Value = r.asset_tag },
            { CustomField = { Name = "Description" }, Value = r.name },
            { CustomField = { Name = "Serial Number" }, Value = r.serial_number },
            { CustomField = { Name = "Manufacturer" }, Value = r.manufacturer },
            { CustomField = { Name = "Model" }, Value = r.model },
            { CustomField = { Name = "Refrigerant" }, Value = r.refrigerant_type },
            { CustomField = { Name = "Charge (kg)" },
              Value = r.refrigerant_charge_kg and tostring(r.refrigerant_charge_kg) or nil },
            { CustomField = { Name = "Condition Rating" },
              Value = r.condition_rating and tostring(r.condition_rating) or nil },
        },
        ServiceLevels = {},
        Archived = r.archived == true,
        DisplayOrder = tonumber(r.display_order) or 0,
    }
end

local function project_job(r)
    return {
        ID = tonumber(r.simpro_id) or r.simpro_id,
        Type = (r.kind == "project") and "Project" or "Service",
        Name = r.title,
        Description = r.description,
        -- Simpro capitalises its stages.
        Stage = (r.stage or "pending"):gsub("^%l", string.upper),
        Customer = r.customer_simpro_id
            and { ID = tonumber(r.customer_simpro_id) or r.customer_simpro_id } or nil,
        Site = r.site_simpro_id
            and { ID = tonumber(r.site_simpro_id) or r.site_simpro_id } or nil,
        DateIssued = r.date_issued,
        DueDate = r.due_date,
        OrderNo = r.order_no,
        Total = {
            ExTax = tonumber(r.total_ex_tax) or 0,
            IncTax = tonumber(r.total_inc_tax) or 0,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Collection readers
-- ---------------------------------------------------------------------------

local COLLECTIONS = {
    customers = function(ns)
        local rows = db.query([[
            SELECT simpro_id, company_name, first_name, last_name, email, phone, customer_type
            FROM customers
            WHERE namespace_id = ? AND simpro_id IS NOT NULL
            ORDER BY simpro_id
        ]], ns)
        local out = {}
        for _, r in ipairs(rows) do table.insert(out, project_customer(r)) end
        for _, r in ipairs(MOCK_ONLY.customers) do table.insert(out, r) end
        return out
    end,

    sites = function(ns)
        local rows = db.query([[
            SELECT s.simpro_id, s.name, s.address_line1, s.city, s.county, s.postal_code,
                   s.country, s.zone, c.simpro_id AS customer_simpro_id
            FROM fs_sites s
            LEFT JOIN customers c ON c.id = s.customer_id
            WHERE s.namespace_id = ? AND s.simpro_id IS NOT NULL AND s.deleted_at IS NULL
            ORDER BY s.simpro_id
        ]], ns)
        local out = {}
        for _, r in ipairs(rows) do table.insert(out, project_site(r)) end
        for _, r in ipairs(MOCK_ONLY.sites) do table.insert(out, r) end
        return out
    end,

    customerAssets = function(ns)
        local rows = db.query([[
            SELECT a.simpro_id, a.asset_tag, a.name, a.serial_number, a.manufacturer, a.model,
                   a.refrigerant_type, a.refrigerant_charge_kg, a.condition_rating,
                   a.archived, a.display_order,
                   at.simpro_id AS type_simpro_id, at.name AS asset_type_name,
                   s.simpro_id AS site_simpro_id, s.name AS site_name
            FROM fs_assets a
            LEFT JOIN fs_asset_types at ON at.id = a.asset_type_id
            LEFT JOIN fs_sites s        ON s.id = a.site_id
            WHERE a.namespace_id = ? AND a.simpro_id IS NOT NULL AND a.deleted_at IS NULL
            ORDER BY a.simpro_id
        ]], ns)
        local out = {}
        for _, r in ipairs(rows) do table.insert(out, project_asset(r)) end
        return out
    end,

    jobs = function(ns)
        local rows = db.query([[
            SELECT j.simpro_id, j.title, j.description, j.stage, j.kind, j.due_date,
                   j.date_issued, j.order_no, j.total_ex_tax, j.total_inc_tax,
                   c.simpro_id AS customer_simpro_id, s.simpro_id AS site_simpro_id
            FROM fs_jobs j
            LEFT JOIN customers c ON c.id = j.customer_id
            LEFT JOIN fs_sites s  ON s.id = j.site_id
            WHERE j.namespace_id = ? AND j.simpro_id IS NOT NULL AND j.deleted_at IS NULL
            ORDER BY j.simpro_id
        ]], ns)
        local out = {}
        for _, r in ipairs(rows) do table.insert(out, project_job(r)) end
        return out
    end,
}

-- ---------------------------------------------------------------------------
-- Request handling
-- ---------------------------------------------------------------------------

--- Strip the collection name out of a resource path: "sites/12/assets" -> "sites".
local function head_of(resource)
    return tostring(resource or ""):gsub("^/+", ""):match("^([^/?]+)") or ""
end

local function page_slice(rows, query)
    local page = math.max(tonumber(query and query.page) or 1, 1)
    local size = math.min(math.max(tonumber(query and query.pageSize) or 30, 1), 250)
    local first = (page - 1) * size + 1
    local out = {}
    for i = first, math.min(first + size - 1, #rows) do
        table.insert(out, rows[i])
    end
    return out, #rows
end

--- Entry point used by SimproClient:request when the connection is in mock mode.
function Mock.handle(client, method, resource, opts)
    opts = opts or {}
    local namespace_id = client.connection and client.connection.namespace_id
    if not namespace_id then
        return nil, "Mock Simpro needs a namespace-scoped connection"
    end

    local head = head_of(resource)

    -- The company root, which SimproClient:ping reads.
    if resource == "" or resource == "/" then
        return {
            ID = tonumber(client.company_id) or 0,
            Name = "DBS Ltd (mock Simpro build)",
            Country = "United Kingdom",
            Currency = "GBP",
        }, { status = 200 }
    end

    if method == "GET" then
        local reader = COLLECTIONS[head]
        if not reader then
            -- Unknown collections answer empty rather than erroring: the sync
            -- walks a fixed list, and a 404 here would look like a fault.
            return {}, { status = 200, total = 0 }
        end
        local rows = reader(namespace_id)
        local slice, total = page_slice(rows, opts.query)
        return slice, { status = 200, total = total }
    end

    if method == "POST" or method == "PATCH" then
        local body = opts.body or {}
        -- Echo the record back with an id, the way Simpro does. On a PATCH the
        -- id is already in the path, so preserve whatever the caller sent.
        local id = body.ID or mint_id()
        local echoed = {}
        for k, v in pairs(body) do echoed[k] = v end
        echoed.ID = id
        return echoed, { status = method == "POST" and 201 or 200 }
    end

    if method == "DELETE" then
        return {}, { status = 204 }
    end

    return nil, ("Mock Simpro does not implement %s %s"):format(method, resource)
end

Mock.MOCK_ONLY = MOCK_ONLY

return Mock
