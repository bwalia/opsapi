local StoreModel = require "models.StoreModel"
local Errors = require("lib.errors")
local db = require("lapis.db")
local Global = require "helper.global"

local StoreQueries = {}

-- Columns a store create may set; anything else in the request is ignored
-- (unknown fields used to reach the INSERT, and is_verified is an admin
-- decision, not something a seller sets on their own store).
local STORE_WRITABLE = {}
for _, f in ipairs({ "uuid", "user_id", "namespace_id", "name", "description", "slug", "logo_url", "banner_url",
    "contact_email", "contact_phone", "address", "city", "state", "country", "postal_code", "status", "settings",
    "tax_rate", "currency", "timezone", "shipping_enabled", "shipping_flat_rate", "free_shipping_threshold",
    "can_self_ship" }) do
    STORE_WRITABLE[f] = true
end

function StoreQueries.create(params)
    -- Validate required fields
    if not params.name or params.name == "" then
        Errors.invalid("Store name is required")
    end
    if not params.user_id then
        error("User ID is required for store creation")
    end

    -- Generate UUID if not provided
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end

    -- Set default status
    if not params.status then
        params.status = 'active'
    end

    -- Sanitize slug
    if params.slug then
        params.slug = string.lower(params.slug):gsub("[^a-z0-9-]", "-"):gsub("-+", "-")
    else
        params.slug = string.lower(params.name):gsub("[^a-z0-9-]", "-"):gsub("-+", "-")
    end

    -- Handle tax rate validation and conversion
    if params.tax_rate then
        local tax_rate = tonumber(params.tax_rate)
        if not tax_rate or tax_rate < 0 or tax_rate > 100 then
            Errors.invalid("Tax rate must be a number between 0 and 100")
        end
        params.tax_rate = tax_rate / 100  -- Convert percentage to decimal (10% -> 0.1)
    else
        params.tax_rate = 0.1  -- Default 10%
    end

    -- Handle shipping configuration
    if params.shipping_enabled == nil then
        params.shipping_enabled = false
    end

    if params.shipping_enabled then
        -- Validate shipping rate
        if params.shipping_flat_rate then
            local shipping_rate = tonumber(params.shipping_flat_rate)
            if not shipping_rate or shipping_rate < 0 then
                Errors.invalid("Shipping rate must be a positive number")
            end
            params.shipping_flat_rate = shipping_rate
        else
            params.shipping_flat_rate = 0
        end

        -- Validate free shipping threshold
        if params.free_shipping_threshold then
            local threshold = tonumber(params.free_shipping_threshold)
            if not threshold or threshold < 0 then
                Errors.invalid("Free shipping threshold must be a positive number")
            end
            params.free_shipping_threshold = threshold
        else
            params.free_shipping_threshold = 0
        end
    else
        -- If shipping is disabled, set shipping values to 0
        params.shipping_flat_rate = 0
        params.free_shipping_threshold = 0
    end

    local row = {}
    for field in pairs(STORE_WRITABLE) do
        if params[field] ~= nil then row[field] = params[field] end
    end
    return StoreModel:create(row, { returning = "*" })
end

-- Get stores by user (store owner)
function StoreQueries.getByUser(user_id, params)
    local page = params.page or 1
    local perPage = params.perPage or 10

    -- Validate ORDER BY to prevent SQL injection
    local valid_fields = { id = true, name = true, slug = true, status = true, created_at = true, updated_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_fields, "id", "desc")

    local paginated = StoreModel:paginated("WHERE user_id = ? ORDER BY " .. orderField .. " " .. orderDir, user_id, {
        per_page = perPage
    })

    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function StoreQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 10

    -- Validate ORDER BY to prevent SQL injection
    local valid_fields = { id = true, name = true, slug = true, status = true, created_at = true, updated_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_fields, "id", "desc")

    -- Scope to the caller's namespace when one is in context (the route sets
    -- params.namespace_id from self.namespace). Without this the list leaked
    -- every tenant's stores to an authenticated user. Public (no namespace)
    -- browse still returns all.
    local paginated
    if params.namespace_id then
        paginated = StoreModel:paginated("where namespace_id = ? order by " .. orderField .. " " .. orderDir,
            tonumber(params.namespace_id), { per_page = perPage })
    else
        paginated = StoreModel:paginated("order by " .. orderField .. " " .. orderDir, { per_page = perPage })
    end

    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function StoreQueries.showByUUID(uuid)
    return StoreModel:find({ uuid = uuid })
end

function StoreQueries.show(id)
    local store = StoreModel:find({ uuid = id })
    if store then
        store:get_owner()
        store:get_products()
        store:get_categories()
    end
    return store
end

-- Show store with owner verification
function StoreQueries.showByOwner(id, user_id)
    local store = StoreModel:find({ uuid = id, user_id = user_id })
    if store then
        store:get_products()
        store:get_categories()
    end
    return store
end

function StoreQueries.update(id, params)
    local record = StoreModel:find({ uuid = tostring(id) })
    if not record then return nil end
    -- Same allow-list as create; the owner, workspace and uuid never change.
    local changes = {}
    for field in pairs(STORE_WRITABLE) do
        if params[field] ~= nil and field ~= "uuid" and field ~= "user_id" and field ~= "namespace_id" then
            changes[field] = params[field]
        end
    end
    if next(changes) == nil then return record end
    changes.updated_at = db.raw("NOW()")
    record:update(changes)
    return record
end

function StoreQueries.destroy(id)
    local record = StoreModel:find({ uuid = id })
    if not record then return nil end

    -- Delete associated products, categories, and orders
    record:get_products():delete_all()
    record:get_categories():delete_all()
    record:get_orders():delete_all()

    return record:delete()
end

return StoreQueries
