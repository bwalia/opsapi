-- luacheck: max line length 140
--[[
    Never price below cost — pure rules (no nginx, no DB)
    =====================================================

    A hard rule with no override: nothing in the shop is saved, synced, quoted or sold at a price below
    its known cost. Unknown cost never blocks (the below-cost report counts what has no cost yet).

    Costs are integer pence ex VAT, like prices.
      product cost  = linked supplier item's cost, else the manual shop_products.cost_minor, else unknown
      option cost   = its component product's cost (× the qty chosen, like the price), else the option's own
                      shop_options.cost_minor, else unknown
      line cost     = product cost + Σ(option cost × qty) over the parts whose cost is known
                      (lib/shop-pricing.lua price() computes it; a line priced below it is invalid: below_cost)

    Customers are never told the cost: they get PRICE_CHECK_MESSAGE. Staff get the item, price and cost.
    Unit tested by spec/shop-cost-floor_spec.lua.
]]

local M = {}

-- The one wording, shared with the pricing engine (its below_cost violation).
M.PRICE_CHECK_MESSAGE = require("lib.shop-pricing").PRICE_CHECK_MESSAGE

local function int_or_nil(v)
    local n = tonumber(v)
    if n == nil or n ~= n or n ~= math.floor(n) then return nil end
    return n
end

--- Effective cost: the first known one (supplier item cost, then the manual cost). nil = unknown.
function M.effective(...)
    local list = { ... }
    for i = 1, select("#", ...) do
        local n = int_or_nil(list[i])
        if n and n >= 0 then return n end
    end
    return nil
end

--- Validate a cost_minor field from an admin document.
-- Returns (kind, value, err): kind "unset" (field absent), "clear" (null or ""), "set" (value = integer ≥ 0),
-- or (nil, nil, message).
function M.parse(v, null)
    if v == nil then return "unset" end
    if v == null or v == "" or (type(v) == "userdata") then return "clear" end
    local n = int_or_nil(v)
    if n == nil or n < 0 then return nil, nil, "cost_minor must be a non-negative integer (pence, ex VAT) or null" end
    if n > 100000000 then return nil, nil, "cost_minor is too large" end
    return "set", n
end

--- Is this price below this cost? Unknown cost (nil) never is.
function M.below(price_minor, cost_minor)
    local p, c = tonumber(price_minor), tonumber(cost_minor)
    if p == nil or c == nil then return false end
    return p < c
end

local function money(minor)
    minor = tonumber(minor) or 0
    local neg = minor < 0
    if neg then minor = -minor end
    local whole = math.floor(minor / 100)
    local s = tostring(whole):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (neg and "-" or "") .. "£" .. s .. string.format(".%02d", minor % 100)
end
M.money = money

--- The admin check for one product and its options (as loaded with effective costs).
-- product = { name, sku, price_mode, base_price_minor, cost_minor (effective) }
-- groups  = { { code, name, is_active, options = { { code, name, is_active, price_delta_minor,
--               price_follows_component, cost_minor (effective) } } } }
-- Returns a list of violations { kind, name, product_name, group_code?, option_code?, price_minor, cost_minor,
-- message } (empty when fine). A quote_only product has no list price to check; an option whose price follows
-- its component product is covered by that product's own check.
function M.check_product(product, groups)
    local out = {}
    product = product or {}
    local pname = product.name or product.sku or "Product"
    if product.price_mode ~= "quote_only" and M.below(product.base_price_minor, product.cost_minor) then
        out[#out + 1] = {
            kind = "product", name = pname, product_name = pname,
            price_minor = tonumber(product.base_price_minor), cost_minor = tonumber(product.cost_minor),
            message = string.format("%s: price %s is below its cost %s", pname, money(product.base_price_minor),
                money(product.cost_minor)),
        }
    end
    for _, g in ipairs(groups or {}) do
        if g.is_active ~= false then
            for _, o in ipairs(g.options or {}) do
                if o.is_active ~= false and o.price_follows_component ~= true
                    and M.below(o.price_delta_minor, o.cost_minor) then
                    local oname = o.name or o.code
                    out[#out + 1] = {
                        kind = "option", name = oname, product_name = pname, group_code = g.code, option_code = o.code,
                        price_minor = tonumber(o.price_delta_minor), cost_minor = tonumber(o.cost_minor),
                        message = string.format("%s option %s: price %s is below its cost %s", pname, oname,
                            money(o.price_delta_minor), money(o.cost_minor)),
                    }
                end
            end
        end
    end
    return out
end

--- One message for a list of violations (the 422 BELOW_COST error text).
function M.summary(violations)
    local parts = {}
    for i, v in ipairs(violations or {}) do
        if i > 5 then
            parts[#parts + 1] = string.format("and %d more", #violations - 5)
            break
        end
        parts[#parts + 1] = v.message
    end
    return "Below cost, not saved: " .. table.concat(parts, "; ")
end

return M
