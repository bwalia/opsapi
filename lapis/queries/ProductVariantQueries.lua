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

function ProductVariantQueries.update(id, params)
    local record = ProductVariantModel:find({ uuid = id })
    if not record then return nil end
    params.id = record.id
    return record:update(params, { returning = "*" })
end

function ProductVariantQueries.destroy(id)
    local record = ProductVariantModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

return ProductVariantQueries