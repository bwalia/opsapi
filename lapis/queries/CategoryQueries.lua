local CategoryModel = require "models.CategoryModel"
local StoreQueries = require "queries.StoreQueries"
local Global = require "helper.global"
local db = require("lapis.db")

local CategoryQueries = {}

function CategoryQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end

    if params.store_id then
        -- Ensure store_id is valid
        local store = StoreQueries.show(params.store_id)
        if store then
            params.store_id = store.id
        end
    end

    -- Check for duplicate category name in the same store (case-insensitive)
    if params.name and params.store_id then
        local existing = db.select(
            "* FROM categories WHERE store_id = ? AND LOWER(name) = ? LIMIT 1",
            params.store_id,
            string.lower(params.name)
        )
        if existing and #existing > 0 then
            error("Category with this name already exists in your store")
        end
    end

    return CategoryModel:create(params, { returning = "*" })
end

function CategoryQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'
    
    local where_clause = ""
    local where_params = {}
    
    if params.store_id and params.store_id ~= "" then
        local store = StoreQueries.showByUUID(params.store_id)
        if store then
            where_clause = "WHERE store_id = ?"
            table.insert(where_params, store.id)
        else
            -- Return empty if store not found
            return { data = {}, total = 0 }
        end
    end
    
    local paginated = CategoryModel:paginated(
        where_clause .. " order by " .. orderField .. " " .. orderDir,
         unpack(where_params),{
        per_page = perPage
    })
    
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function CategoryQueries.show(id)
    return CategoryModel:find({ uuid = id })
end

function CategoryQueries.update(id, params)
    local record = CategoryModel:find({ uuid = id })
    if not record then return nil end
    params.id = record.id
    return record:update(params, { returning = "*" })
end

function CategoryQueries.destroy(id)
    local record = CategoryModel:find({ uuid = id })
    if not record then return nil end

    -- Delete associated products
    record:get_products():delete_all()

    return record:delete()
end

-- Search categories by name (case-insensitive) within a store
function CategoryQueries.search(params)
    local search_term = params.search or ""
    local store_id = params.store_id
    local limit = tonumber(params.limit) or 10

    if not store_id or store_id == "" then
        return { data = {} }
    end

    -- Get store's internal ID
    local store = StoreQueries.showByUUID(store_id)
    if not store then
        return { data = {} }
    end

    local where_clause = "WHERE store_id = ? AND is_active = true"
    local where_params = { store.id }

    -- Add search filter if provided
    if search_term and search_term ~= "" then
        where_clause = where_clause .. " AND LOWER(name) LIKE ?"
        table.insert(where_params, "%" .. string.lower(search_term) .. "%")
    end

    where_clause = where_clause .. " ORDER BY name ASC LIMIT ?"
    table.insert(where_params, limit)

    local results = db.select("* FROM categories " .. where_clause, unpack(where_params))

    return { data = results or {} }
end

-- Check if category name exists in store (for real-time validation)
function CategoryQueries.checkExists(store_id, name)
    if not store_id or not name then
        return false
    end

    local store = StoreQueries.showByUUID(store_id)
    if not store then
        return false
    end

    local existing = db.select(
        "* FROM categories WHERE store_id = ? AND LOWER(name) = ? LIMIT 1",
        store.id,
        string.lower(name)
    )

    return existing and #existing > 0
end

return CategoryQueries
