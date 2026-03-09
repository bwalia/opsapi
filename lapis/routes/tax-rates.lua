--[[
    Tax Rates Routes

    Admin endpoints for managing configurable UK tax rates/brackets.
    Read endpoint available to all authenticated users.
    Write endpoints restricted to admin roles.

    Rates are stored per tax year in the tax_rates table.
]]

local db = require("lapis.db")
local cjson = require("cjson")

local function getUserId(user)
    local user_uuid = user.uuid or user.id
    local rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    if rows and #rows > 0 then return rows[1].id end
    return nil
end

local function isAdmin(user)
    local user_uuid = user.uuid or user.id
    local rows = db.query([[
        SELECT r.role_name
        FROM user__roles ur
        JOIN roles r ON ur.role_id = r.id
        JOIN users u ON ur.user_id = u.id
        WHERE u.uuid = ?
        LIMIT 1
    ]], user_uuid)
    if rows and #rows > 0 then
        local role = rows[1].role_name
        return role == "administrative" or role == "tax_admin"
    end
    return false
end

local function getCurrentTaxYear()
    local now = os.date("*t")
    local year = now.year
    if now.month < 4 or (now.month == 4 and now.day < 6) then
        year = year - 1
    end
    return year .. "-" .. string.format("%02d", (year + 1) % 100)
end

-- Numeric fields that can be updated
local RATE_FIELDS = {
    "personal_allowance", "personal_allowance_taper_threshold",
    "basic_rate", "basic_rate_upper",
    "higher_rate", "higher_rate_upper",
    "additional_rate",
    "nic_class4_main_rate", "nic_class4_lower_threshold",
    "nic_class4_upper_threshold", "nic_class4_additional_rate",
    "nic_class2_weekly", "nic_class2_annual", "nic_class2_threshold",
}

return function(app)

    -- =========================================================================
    -- GET /api/v2/tax/rates
    -- Returns tax rates for a given tax year (or current year)
    -- Available to all authenticated users
    -- =========================================================================
    app:get("/api/v2/tax/rates", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local tax_year = self.params.tax_year or getCurrentTaxYear()

        local rows = db.query(
            "SELECT * FROM tax_rates WHERE tax_year = ? LIMIT 1", tax_year
        )

        if not rows or #rows == 0 then
            -- Return defaults if no DB entry exists
            return {
                status = 200,
                json = {
                    tax_year = tax_year,
                    source = "default",
                    personal_allowance = 12570,
                    personal_allowance_taper_threshold = 100000,
                    basic_rate = 0.20,
                    basic_rate_upper = 50270,
                    higher_rate = 0.40,
                    higher_rate_upper = 125140,
                    additional_rate = 0.45,
                    nic_class4_main_rate = 0.06,
                    nic_class4_lower_threshold = 12570,
                    nic_class4_upper_threshold = 50270,
                    nic_class4_additional_rate = 0.02,
                    nic_class2_weekly = 3.45,
                    nic_class2_annual = 179.40,
                    nic_class2_threshold = 12570,
                }
            }
        end

        local r = rows[1]
        return {
            status = 200,
            json = {
                uuid = r.uuid,
                tax_year = r.tax_year,
                source = "database",
                personal_allowance = tonumber(r.personal_allowance),
                personal_allowance_taper_threshold = tonumber(r.personal_allowance_taper_threshold),
                basic_rate = tonumber(r.basic_rate),
                basic_rate_upper = tonumber(r.basic_rate_upper),
                higher_rate = tonumber(r.higher_rate),
                higher_rate_upper = tonumber(r.higher_rate_upper),
                additional_rate = tonumber(r.additional_rate),
                nic_class4_main_rate = tonumber(r.nic_class4_main_rate),
                nic_class4_lower_threshold = tonumber(r.nic_class4_lower_threshold),
                nic_class4_upper_threshold = tonumber(r.nic_class4_upper_threshold),
                nic_class4_additional_rate = tonumber(r.nic_class4_additional_rate),
                nic_class2_weekly = tonumber(r.nic_class2_weekly),
                nic_class2_annual = tonumber(r.nic_class2_annual),
                nic_class2_threshold = tonumber(r.nic_class2_threshold),
                is_active = r.is_active,
                updated_at = r.updated_at,
            }
        }
    end)

    -- =========================================================================
    -- GET /api/v2/tax/rates/all
    -- Returns all tax year rates (admin view)
    -- =========================================================================
    app:get("/api/v2/tax/rates/all", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end
        if not isAdmin(user) then
            return { status = 403, json = { error = "Admin access required" } }
        end

        local rows = db.query("SELECT * FROM tax_rates ORDER BY tax_year DESC")
        local rates = {}
        for _, r in ipairs(rows or {}) do
            table.insert(rates, {
                uuid = r.uuid,
                tax_year = r.tax_year,
                personal_allowance = tonumber(r.personal_allowance),
                personal_allowance_taper_threshold = tonumber(r.personal_allowance_taper_threshold),
                basic_rate = tonumber(r.basic_rate),
                basic_rate_upper = tonumber(r.basic_rate_upper),
                higher_rate = tonumber(r.higher_rate),
                higher_rate_upper = tonumber(r.higher_rate_upper),
                additional_rate = tonumber(r.additional_rate),
                nic_class4_main_rate = tonumber(r.nic_class4_main_rate),
                nic_class4_lower_threshold = tonumber(r.nic_class4_lower_threshold),
                nic_class4_upper_threshold = tonumber(r.nic_class4_upper_threshold),
                nic_class4_additional_rate = tonumber(r.nic_class4_additional_rate),
                nic_class2_weekly = tonumber(r.nic_class2_weekly),
                nic_class2_annual = tonumber(r.nic_class2_annual),
                nic_class2_threshold = tonumber(r.nic_class2_threshold),
                is_active = r.is_active,
                updated_at = r.updated_at,
            })
        end

        return { status = 200, json = { rates = rates } }
    end)

    -- =========================================================================
    -- PUT /api/v2/tax/rates/:tax_year
    -- Create or update tax rates for a given year (admin only)
    -- =========================================================================
    app:put("/api/v2/tax/rates/:tax_year", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end
        if not isAdmin(user) then
            return { status = 403, json = { error = "Admin access required" } }
        end

        local tax_year = self.params.tax_year
        if not tax_year or not tax_year:match("^%d%d%d%d%-%d%d$") then
            return { status = 400, json = { error = "Invalid tax_year format. Use YYYY-YY (e.g. 2025-26)" } }
        end

        -- Parse JSON body
        local params = {}
        if ngx.req.get_headers()["content-type"] and
           ngx.req.get_headers()["content-type"]:find("application/json") then
            ngx.req.read_body()
            local body = ngx.req.get_body_data()
            if body then
                local ok, parsed = pcall(cjson.decode, body)
                if ok and parsed then params = parsed end
            end
        end

        -- Build SET clause from provided fields
        local sets = {}
        local values = {}
        for _, field in ipairs(RATE_FIELDS) do
            if params[field] ~= nil then
                local val = tonumber(params[field])
                if not val then
                    return { status = 400, json = { error = "Invalid numeric value for " .. field } }
                end
                table.insert(sets, field .. " = ?")
                table.insert(values, val)
            end
        end

        if #sets == 0 then
            return { status = 400, json = { error = "No valid fields provided" } }
        end

        -- Check if exists
        local existing = db.query("SELECT uuid FROM tax_rates WHERE tax_year = ? LIMIT 1", tax_year)

        if existing and #existing > 0 then
            -- Update
            table.insert(sets, "updated_at = NOW()")
            table.insert(values, existing[1].uuid)
            db.query(
                "UPDATE tax_rates SET " .. table.concat(sets, ", ") .. " WHERE uuid = ?",
                unpack(values)
            )
        else
            -- Insert with defaults + overrides (UUID auto-generated)
            local insert_fields = { "uuid", "tax_year" }
            local insert_values = {}
            local placeholders = { "gen_random_uuid()::text", "?" }
            table.insert(insert_values, tax_year)
            for _, field in ipairs(RATE_FIELDS) do
                if params[field] ~= nil then
                    table.insert(insert_fields, field)
                    table.insert(placeholders, "?")
                    table.insert(insert_values, tonumber(params[field]))
                end
            end
            db.query(
                "INSERT INTO tax_rates (" .. table.concat(insert_fields, ", ") .. ") VALUES (" .. table.concat(placeholders, ", ") .. ")",
                unpack(insert_values)
            )
        end

        -- Return updated record
        local rows = db.query("SELECT * FROM tax_rates WHERE tax_year = ? LIMIT 1", tax_year)
        local r = rows[1]

        return {
            status = 200,
            json = {
                message = "Tax rates saved for " .. tax_year,
                uuid = r.uuid,
                tax_year = r.tax_year,
                personal_allowance = tonumber(r.personal_allowance),
                personal_allowance_taper_threshold = tonumber(r.personal_allowance_taper_threshold),
                basic_rate = tonumber(r.basic_rate),
                basic_rate_upper = tonumber(r.basic_rate_upper),
                higher_rate = tonumber(r.higher_rate),
                higher_rate_upper = tonumber(r.higher_rate_upper),
                additional_rate = tonumber(r.additional_rate),
                nic_class4_main_rate = tonumber(r.nic_class4_main_rate),
                nic_class4_lower_threshold = tonumber(r.nic_class4_lower_threshold),
                nic_class4_upper_threshold = tonumber(r.nic_class4_upper_threshold),
                nic_class4_additional_rate = tonumber(r.nic_class4_additional_rate),
                nic_class2_weekly = tonumber(r.nic_class2_weekly),
                nic_class2_annual = tonumber(r.nic_class2_annual),
                nic_class2_threshold = tonumber(r.nic_class2_threshold),
                is_active = r.is_active,
                updated_at = r.updated_at,
            }
        }
    end)

end
