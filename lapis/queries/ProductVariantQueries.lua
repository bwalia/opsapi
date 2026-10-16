local ProductVariantModel = require "models.ProductVariantModel"
local StoreproductModel = require "models.StoreproductModel"
local Global = require "helper.global"

local ProductVariantQueries = {}

function ProductVariantQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end

    local product = StoreproductModel:find({ uuid = params.product_id })
    if not product then
        error("Product not found")
    end
    params.product_id = product.id

    return ProductVariantModel:create(params, { returning = "*" })
end

function ProductVariantQueries.all(product_id)
    local product = StoreproductModel:find({ uuid = product_id })
    if not product then
        return {}
    end
    return ProductVariantModel:select("where product_id = ?", product.id)
end

function ProductVariantQueries.show(id)
    return ProductVariantModel:find({ uuid = id })
end

-- What an update may change: never the product it belongs to, nor its ids.
local UPDATABLE = { "title", "option1", "option2", "option3", "sku", "price", "compare_price", "inventory_quantity",
    "weight", "image_url", "is_active", "position" }

function ProductVariantQueries.update(id, request)
    local record = ProductVariantModel:find({ uuid = id })
    if not record then return nil end
    local params = Global.pick(request, UPDATABLE)
    if next(params) == nil then return record end
    record:update(params, { returning = "*" })
    return record
end

function ProductVariantQueries.destroy(id)
    local record = ProductVariantModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

return ProductVariantQueries