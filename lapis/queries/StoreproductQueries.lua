local StoreproductModel = require "models.StoreproductModel"
local StoreModel = require "models.StoreModel"
local Global = require "helper.global"

local StoreproductQueries = {}

function StoreproductQueries.create(params)
    -- Validate required fields
    if not params.name or params.name == "" then
        error("Product name is required")
    end
    if not params.price or tonumber(params.price) <= 0 then
        error("Valid product price is required")
    end

    -- Generate UUID if not provided
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end

    -- Set defaults
    if not params.inventory_quantity then
        params.inventory_quantity = 0
    end
    if params.track_inventory == nil then
        params.track_inventory = true
    end
    if params.is_active == nil then
        params.is_active = true
    end
    if not params.sort_order then
        params.sort_order = 0
    end

    -- Sanitize numeric fields - convert "null" string to actual nil
    if params.weight == "null" or params.weight == "" then
        params.weight = nil
    elseif params.weight then
        params.weight = tonumber(params.weight)
    end

    if params.compare_price == "null" or params.compare_price == "" then
        params.compare_price = nil
    elseif params.compare_price then
        params.compare_price = tonumber(params.compare_price)
    end

    -- Sanitize text fields
    if params.dimensions == "null" or params.dimensions == "" then
        params.dimensions = nil
    end

    if params.tags == "null" or params.tags == "" then
        params.tags = nil
    end

    if params.sku == "null" or params.sku == "" then
        params.sku = nil
    end

    -- Generate slug if not provided
    if not params.slug or params.slug == "" then
        params.slug = string.lower(params.name):gsub("[^a-z0-9-]", "-"):gsub("-+", "-")
    end

    -- Validate and convert store_id
    local store = StoreModel:find({ uuid = params.store_id })
    if not store then
        error("Store not found")
    end
    params.store_id = store.id

    -- Validate category if provided
    if params.category_id and params.category_id ~= "" then
        local CategoryModel = require "models.CategoryModel"
        local category = CategoryModel:find({ uuid = params.category_id })
        if category then
            params.category_id = category.id
        else
            params.category_id = nil
        end
    else
        params.category_id = nil
    end

    return StoreproductModel:create(params, { returning = "*" })
end

function StoreproductQueries.updateInventory(product_uuid, quantity_change)
    local product = StoreproductModel:find({ uuid = product_uuid })
    if not product then
        return nil, "Product not found"
    end

    if product.track_inventory then
        local new_quantity = product.inventory_quantity + quantity_change
        if new_quantity < 0 then
            return nil, "Insufficient inventory. Available: " .. product.inventory_quantity
        end
        product:update({ inventory_quantity = new_quantity })
    end

    return product, nil
end

function StoreproductQueries.checkInventory(product_uuid, required_quantity, variant_uuid)
    local product = StoreproductModel:find({ uuid = product_uuid })
    if not product then
        return false, "Product not found"
    end

    -- Check variant inventory if variant is specified
    if variant_uuid then
        local ProductVariantModel = require "models.ProductVariantModel"
        local variant = ProductVariantModel:find({ uuid = variant_uuid })
        if not variant then
            return false, "Variant not found"
        end

        if variant.inventory_quantity < required_quantity then
            return false, "Insufficient variant inventory. Available: " .. variant.inventory_quantity
        end
    else
        -- Check product inventory
        if product.track_inventory and product.inventory_quantity < required_quantity then
            return false, "Insufficient inventory. Available: " .. product.inventory_quantity
        end
    end

    return true, nil
end

function StoreproductQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 10

    -- Validate ORDER BY to prevent SQL injection
    local valid_fields = { id = true, name = true, sku = true, price = true, quantity = true, status = true, created_at = true, updated_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_fields, "id", "desc")

    local paginated = StoreproductModel:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })

    local products = paginated:get_page(page)
    for i, product in ipairs(products) do
        product:get_store()
        product:get_category()
    end

    return {
        data = products,
        total = paginated:total_items()
    }
end

-- Get products by store
function StoreproductQueries.getByStore(store_id, params)
    local store = StoreModel:find({ uuid = store_id })
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = StoreproductModel:paginated(
        "WHERE store_id = " .. store.id .. " ORDER BY " .. orderField .. " " .. orderDir, {
            per_page = perPage
        })

    local products = paginated:get_page(page)
    for i, product in ipairs(products) do
        product:get_category()
    end

    return {
        data = products,
        total = paginated:total_items()
    }
end

-- Get products by store and category
function StoreproductQueries.getByStoreAndCategory(store_id, category_id, params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = StoreproductModel:paginated(
        "WHERE store_id = ? AND category_id = ? ORDER BY " .. orderField .. " " .. orderDir, {
            per_page = perPage
        }, store_id, category_id)

    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function StoreproductQueries.show(id)
    return StoreproductModel:find({ uuid = id })
end

function StoreproductQueries.update(id, params)
    local record = StoreproductModel:find({ uuid = id })
    if not record then return nil end

    -- Sanitize numeric fields - convert "null" string to actual nil
    if params.weight == "null" or params.weight == "" then
        params.weight = nil
    elseif params.weight then
        params.weight = tonumber(params.weight)
    end

    if params.compare_price == "null" or params.compare_price == "" then
        params.compare_price = nil
    elseif params.compare_price then
        params.compare_price = tonumber(params.compare_price)
    end

    -- Sanitize text fields
    if params.dimensions == "null" or params.dimensions == "" then
        params.dimensions = nil
    end

    if params.tags == "null" or params.tags == "" then
        params.tags = nil
    end

    if params.sku == "null" or params.sku == "" then
        params.sku = nil
    end

    -- Handle category_id conversion
    if params.category_id and params.category_id ~= "" then
        local CategoryModel = require "models.CategoryModel"
        local category = CategoryModel:find({ uuid = params.category_id })
        if category then
            params.category_id = category.id
        else
            params.category_id = nil
        end
    else
        params.category_id = nil
    end

    -- Remove id from params to avoid conflicts
    params.id = nil
    params.uuid = nil

    return record:update(params, { returning = "*" })
end

function StoreproductQueries.destroy(id)
    local record = StoreproductModel:find({ uuid = id })
    if not record then return nil end

    -- Delete associated variants and order items
    record:get_variants():delete_all()
    record:get_orderitems():delete_all()

    return record:delete()
end

-- Enhanced product search with filters
function StoreproductQueries.searchProducts(params)
    local page = params.page or 1
    local perPage = params.perPage or 20
    local search = params.search
    local category_id = params.category_id
    local store_id = params.store_id
    local min_price = params.min_price
    local max_price = params.max_price
    local is_featured = params.is_featured
    local orderBy = params.orderBy or 'created_at'
    local orderDir = params.orderDir or 'desc'

    local where_conditions = { "is_active = true" }
    local where_params = {}

    if search and search ~= "" then
        table.insert(where_conditions, "(name ILIKE ? OR description ILIKE ? OR tags ILIKE ?)")
        local search_term = "%" .. search .. "%"
        table.insert(where_params, search_term)
        table.insert(where_params, search_term)
        table.insert(where_params, search_term)
    end

    if store_id and store_id ~= "" then
        local store = StoreModel:find({ uuid = store_id })
        if store then
            table.insert(where_conditions, "store_id = ?")
            table.insert(where_params, store.id)
        end
    end

    if category_id and category_id ~= "" then
        table.insert(where_conditions, "category_id = ?")
        table.insert(where_params, category_id)
    end

    if min_price and tonumber(min_price) > 0 then
        table.insert(where_conditions, "price >= ?")
        table.insert(where_params, tonumber(min_price))
    end

    if max_price and tonumber(max_price) > 0 then
        table.insert(where_conditions, "price <= ?")
        table.insert(where_params, tonumber(max_price))
    end

    if is_featured == "true" then
        table.insert(where_conditions, "is_featured = true")
    end

    local where_clause = table.concat(where_conditions, " AND ")
    local order_clause = "ORDER BY " .. orderBy .. " " .. orderDir

    local where_clause_full = "WHERE " .. where_clause .. " " .. order_clause

    -- Use the correct Lapis pagination syntax from official docs
    local paginated
    if #where_params > 0 then
        -- Build arguments table: query, param1, param2, ..., options
        local args = { where_clause_full }
        for i, param in ipairs(where_params) do
            table.insert(args, param)
        end
        table.insert(args, { per_page = perPage })

        -- Call paginated with explicit arguments
        paginated = StoreproductModel:paginated(table.unpack(args))
    else
        -- For queries without parameters: Model:paginated("WHERE clause", {options})
        paginated = StoreproductModel:paginated(where_clause_full, {
            per_page = perPage
        })
    end

    local products = paginated:get_page(page)
    for i, product in ipairs(products) do
        product:get_store()
        product:get_category()
    end

    return {
        data = products,
        total = paginated:total_items(),
        page = page,
        per_page = perPage
    }
end

-- Get low stock products for a store
function StoreproductQueries.getLowStockProducts(store_uuid)
    local store = StoreModel:find({ uuid = store_uuid })
    if not store then
        return { data = {}, total = 0 }
    end

    local products = StoreproductModel:select(
        "WHERE store_id = ? AND track_inventory = true AND inventory_quantity <= low_stock_threshold AND is_active = true ORDER BY inventory_quantity ASC",
        store.id
    )

    return {
        data = products,
        total = #products
    }
end

-- Get featured products
function StoreproductQueries.getFeaturedProducts(params)
    local page = params.page or 1
    local perPage = params.perPage or 12

    local paginated = StoreproductModel:paginated(
        "WHERE is_active = true AND is_featured = true ORDER BY sort_order ASC, created_at DESC",
        { per_page = perPage }
    )

    local products = paginated:get_page(page)
    for i, product in ipairs(products) do
        product:get_store()
        product:get_category()
    end

    return {
        data = products,
        total = paginated:total_items()
    }
end

return StoreproductQueries
