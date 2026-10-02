-- luacheck: max line length 140
--[[
    Shop pricing / rules engine (pure Lua — no ngx, no DB, no cjson)
    ================================================================

    The single source of truth for "what does this configuration cost, is it
    valid, and can we ship it". Everything that prices anything in the shop
    (public /price, cart lines, quotes, checkout, admin quote editing) goes
    through ShopPricing.price(). It never mutates its inputs.

    Inputs (plain tables, already loaded from the DB by queries/ShopCatalogQueries):

      product = {
        slug, name, base_price_minor, vat_rate, price_mode, attributes = {},
        available = <int|nil>,          -- stock_qty - held reservations (nil = untracked)
        stock_key = "p:<id>",           -- aggregation key for demand / shortages
        allow_backorder = bool, lead_time_days = int,
      }
      groups = { {
        code, name, selection = "single"|"multi", required = bool,
        min_qty, max_qty, sort_order, is_active,
        options = { {
          code, name, price_delta_minor, max_qty, is_default, is_active, attributes = {},
          available = <int|nil>, stock_key = "p:<id>"|"o:<id>"|nil,
          allow_backorder = bool, lead_time_days = int,
        } },
      } }
      rules = { { kind, params = {}, message, is_active } }
      selections = { ["<group>"] = { { option = "<code>", qty = n } } }
      qty = number of units of the configured product

    Output: the Priced shape (BUILD.prompt.md §3) plus a second return value
    `demand` = { { stock_key, qty, name, available, allow_backorder } } that the
    checkout uses to place stock reservations.

    Rule kinds (shop_rules.params):
      requires   {"if":"<group>.<option>", "then_group":"<group>", "one_of":["<option>",...]}
      excludes   {"a":"<group>.<option>", "b":"<group>.<option>"}
      power      {"budget_from":"psu", "budget_attr":"psu_watts", "sum_attr":"watts",
                  "groups":["cpu","gpu"], "base_watts":250, "headroom":0.9}
                 Σ(watts × qty over groups) + base_watts ≤ Σ(selected psu.psu_watts × qty) × headroom
      max_total  {"group":"gpu", "attr":"slots", "limit_attr":"gpu_slots"}
                 Σ(attr × qty) ≤ product.attributes[limit_attr]
                 (extensions: "limit": <number> literal; "attr":"qty" counts units;
                  "when_attr"/"when_equals" only counts options whose attribute matches)
      attr_match {"group":"memory", "attr":"memory_type", "equals_product_attr":"memory_type"}
                 (extension: "equals": <literal>)
]]

local ShopPricing = {}

local DEFAULT_VAT = 0.20

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n then return default end
    return n
end

local function int(v, default)
    local n = num(v, nil)
    if n == nil then return default end
    if n >= 0 then return math.floor(n) end
    return -math.floor(-n)
end

local function str(v)
    if type(v) == "string" then return v end
    if type(v) == "number" then return tostring(v) end
    return nil
end

local function is_list(t)
    return type(t) == "table" and (next(t) == nil or t[1] ~= nil)
end

-- Round half away from zero to an integer (money in minor units).
function ShopPricing.round(x)
    x = num(x, 0)
    if x >= 0 then return math.floor(x + 0.5) end
    return -math.floor(-x + 0.5)
end
local round = ShopPricing.round

local function truthy(v)
    return v == true or v == 1 or v == "t" or v == "true"
end

local function attr(t, key)
    if type(t) ~= "table" or key == nil then return nil end
    return t[key]
end

local function split_ref(ref)
    ref = str(ref)
    if not ref then return nil, nil end
    local g, o = ref:match("^([^%.]+)%.(.+)$")
    return g, o
end

local function fmt_watts(n)
    return tostring(round(n)) .. "W"
end

-- ---------------------------------------------------------------------------
-- selections
-- ---------------------------------------------------------------------------

--- Normalise a client selection value for one group into {{option, qty}}.
-- Accepts [{option, qty}], ["code", ...], "code", {option=..}.
local function normalise_group_selection(v)
    local out = {}
    if v == nil then return nil end
    if type(v) == "string" then
        out[1] = { option = v, qty = 1 }
        return out
    end
    if type(v) ~= "table" then return out end
    if not is_list(v) then
        v = { v }
    end
    for _, item in ipairs(v) do
        if type(item) == "string" then
            out[#out + 1] = { option = item, qty = 1 }
        elseif type(item) == "table" then
            local code = str(item.option) or str(item.code)
            if code then
                out[#out + 1] = { option = code, qty = int(item.qty, 1) }
            end
        end
    end
    return out
end

--- Default selections for a product: every active group's active is_default
-- options (qty = max(1, group.min_qty) for single, 1 each for multi).
function ShopPricing.default_selections(groups)
    local out = {}
    for _, g in ipairs(groups or {}) do
        if g.is_active ~= false then
            local defs = {}
            for _, o in ipairs(g.options or {}) do
                if o.is_active ~= false and truthy(o.is_default) then
                    defs[#defs + 1] = o
                end
            end
            if #defs > 0 then
                local list = {}
                if g.selection == "multi" then
                    for _, o in ipairs(defs) do list[#list + 1] = { option = o.code, qty = 1 } end
                else
                    local q = math.max(1, int(g.min_qty, 0))
                    local max_q = int(g.max_qty, 1)
                    if max_q > 0 and q > max_q then q = max_q end
                    list[1] = { option = defs[1].code, qty = q }
                end
                out[g.code] = list
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- from-price (cheapest valid-looking configuration, for listings)
-- ---------------------------------------------------------------------------

function ShopPricing.from_price(product, groups)
    local total = int(product.base_price_minor, 0)
    for _, g in ipairs(groups or {}) do
        if g.is_active ~= false then
            local cheapest
            for _, o in ipairs(g.options or {}) do
                if o.is_active ~= false then
                    local d = int(o.price_delta_minor, 0)
                    if cheapest == nil or d < cheapest then cheapest = d end
                end
            end
            if cheapest then
                local min_units = int(g.min_qty, 0)
                if truthy(g.required) and min_units < 1 then min_units = 1 end
                if min_units > 0 then
                    total = total + cheapest * min_units
                elseif cheapest < 0 then
                    total = total + cheapest
                end
            end
        end
    end
    return total
end

-- ---------------------------------------------------------------------------
-- the engine
-- ---------------------------------------------------------------------------

function ShopPricing.price(product, groups, rules, selections, qty)
    product = product or {}
    groups = groups or {}
    rules = rules or {}
    qty = int(qty, 1)

    local violations = {}
    local function violate(rule, message, grps)
        violations[#violations + 1] = { rule = rule, message = message, groups = grps or {} }
    end

    if qty < 1 then
        violate("qty", "Quantity must be at least 1", {})
        qty = 1
    end
    if qty > 1000 then
        violate("qty", "Quantity must be at most 1000", {})
    end

    -- index groups/options
    local group_by_code, ordered_groups = {}, {}
    for _, g in ipairs(groups) do
        if g.is_active ~= false then
            local idx = {}
            for _, o in ipairs(g.options or {}) do idx[o.code] = o end
            group_by_code[g.code] = { def = g, options = idx }
            ordered_groups[#ordered_groups + 1] = g
        end
    end

    -- resolve selections: explicit ones + defaults for omitted groups
    local input = type(selections) == "table" and selections or {}
    local defaults = ShopPricing.default_selections(ordered_groups)
    local resolved = {}      -- group code -> { {option=code, qty=n, opt=<row>} }
    local resolved_out = {}  -- group code -> { {option, qty} } (normalised echo)

    for gcode in pairs(input) do
        if type(gcode) == "string" and not group_by_code[gcode] then
            violate("unknown_group", "Unknown option group '" .. gcode .. "'", { gcode })
        end
    end

    for _, g in ipairs(ordered_groups) do
        local code = g.code
        local entries = normalise_group_selection(input[code])
        if entries == nil then entries = defaults[code] or {} end

        local merged, order = {}, {}
        for _, e in ipairs(entries) do
            local opt = group_by_code[code].options[e.option]
            if not opt or opt.is_active == false then
                violate("unknown_option", "Option '" .. tostring(e.option) .. "' is not available for "
                    .. (g.name or code), { code })
            elseif e.qty < 1 then
                violate("option_qty", "Quantity for " .. (opt.name or e.option) .. " must be at least 1", { code })
            else
                if not merged[e.option] then
                    merged[e.option] = { option = e.option, qty = 0, opt = opt }
                    order[#order + 1] = e.option
                end
                merged[e.option].qty = merged[e.option].qty + e.qty
            end
        end

        local list, echo = {}, {}
        for _, oc in ipairs(order) do
            list[#list + 1] = merged[oc]
            echo[#echo + 1] = { option = oc, qty = merged[oc].qty }
        end
        resolved[code] = list
        if #echo > 0 or input[code] ~= nil then resolved_out[code] = echo end
    end

    -- group constraints
    for _, g in ipairs(ordered_groups) do
        local list = resolved[g.code]
        local units, distinct = 0, #list
        for _, e in ipairs(list) do
            units = units + e.qty
            local omax = int(e.opt.max_qty, 1)
            if omax > 0 and e.qty > omax then
                violate("option_max_qty", string.format("At most %d × %s allowed", omax, e.opt.name or e.option),
                    { g.code })
            end
        end
        local gname = g.name or g.code
        local min_q = int(g.min_qty, 0)
        local max_q = int(g.max_qty, 1)
        if truthy(g.required) and units < math.max(1, min_q) then
            if units == 0 then
                violate("required", gname .. " is required", { g.code })
            else
                violate("group_min", string.format("Select at least %d for %s", math.max(1, min_q), gname), { g.code })
            end
        elseif units > 0 and min_q > 0 and units < min_q then
            violate("group_min", string.format("Select at least %d for %s", min_q, gname), { g.code })
        end
        if max_q > 0 and units > max_q then
            violate("group_max", string.format("Select at most %d for %s", max_q, gname), { g.code })
        end
        if g.selection ~= "multi" and distinct > 1 then
            violate("selection", "Choose only one option for " .. gname, { g.code })
        end
    end

    local function selected(gcode, ocode)
        for _, e in ipairs(resolved[gcode] or {}) do
            if e.option == ocode then return e end
        end
        return nil
    end

    local function sum_attr(gcode, key)
        local s = 0
        for _, e in ipairs(resolved[gcode] or {}) do
            local v
            if key == "qty" or key == nil then v = 1 else v = num(attr(e.opt.attributes, key), 0) end
            s = s + v * e.qty
        end
        return s
    end

    -- rules
    local pattrs = type(product.attributes) == "table" and product.attributes or {}
    for _, r in ipairs(rules) do
        if r.is_active ~= false then
            local p = type(r.params) == "table" and r.params or {}
            local kind = r.kind
            if kind == "requires" then
                local ig, io = split_ref(p["if"])
                local tg = str(p.then_group)
                if ig and selected(ig, io) and tg then
                    local ok = false
                    local one_of = type(p.one_of) == "table" and p.one_of or {}
                    if #one_of == 0 then
                        ok = #(resolved[tg] or {}) > 0
                    else
                        for _, oc in ipairs(one_of) do
                            if selected(tg, oc) then ok = true break end
                        end
                    end
                    if not ok then
                        violate("requires", r.message or ("Selection " .. p["if"] .. " requires a compatible "
                            .. tg .. " option"), { ig, tg })
                    end
                end
            elseif kind == "excludes" then
                local ag, ao = split_ref(p.a)
                local bg, bo = split_ref(p.b)
                if ag and bg and selected(ag, ao) and selected(bg, bo) then
                    violate("excludes", r.message or (p.a .. " cannot be combined with " .. p.b), { ag, bg })
                end
            elseif kind == "power" then
                local sum_key = str(p.sum_attr) or "watts"
                local draw = num(p.base_watts, 0)
                local grps = type(p.groups) == "table" and p.groups or {}
                for _, gc in ipairs(grps) do draw = draw + sum_attr(gc, sum_key) end
                local budget_group = str(p.budget_from) or "psu"
                local budget_key = str(p.budget_attr) or "psu_watts"
                local budget
                if #(resolved[budget_group] or {}) > 0 then
                    budget = sum_attr(budget_group, budget_key)
                else
                    budget = num(pattrs[budget_key], 0)
                end
                local headroom = num(p.headroom, 1)
                if headroom <= 0 then headroom = 1 end
                local usable = budget * headroom
                if budget > 0 or #(resolved[budget_group] or {}) > 0 or group_by_code[budget_group] then
                    if draw > usable then
                        local detail = string.format("estimated draw %s exceeds %s usable (%s PSU × %d%%)",
                            fmt_watts(draw), fmt_watts(usable), fmt_watts(budget), round(headroom * 100))
                        local msg = r.message and (r.message .. " (" .. detail .. ")")
                            or ("Power budget exceeded: " .. detail)
                        local vg = { budget_group }
                        for _, gc in ipairs(grps) do vg[#vg + 1] = gc end
                        violate("power", msg, vg)
                    end
                end
            elseif kind == "max_total" then
                local gc = str(p.group)
                if gc then
                    local key = str(p.attr) or "qty"
                    local total = 0
                    for _, e in ipairs(resolved[gc] or {}) do
                        local counts = true
                        if p.when_attr ~= nil then
                            counts = attr(e.opt.attributes, p.when_attr) == p.when_equals
                        end
                        if counts then
                            local v = (key == "qty") and 1 or num(attr(e.opt.attributes, key), 0)
                            total = total + v * e.qty
                        end
                    end
                    local limit = num(p.limit, nil)
                    if limit == nil and p.limit_attr then limit = num(pattrs[p.limit_attr], nil) end
                    if limit ~= nil and total > limit then
                        local detail = string.format("%s %s selected, maximum %s", tostring(total), key, tostring(limit))
                        violate("max_total", r.message and (r.message .. " (" .. detail .. ")")
                            or ("Too many for " .. gc .. ": " .. detail), { gc })
                    end
                end
            elseif kind == "attr_match" then
                local gc = str(p.group)
                local key = str(p.attr)
                if gc and key then
                    local want = p.equals
                    if want == nil and p.equals_product_attr then want = pattrs[p.equals_product_attr] end
                    if want ~= nil then
                        for _, e in ipairs(resolved[gc] or {}) do
                            local have = attr(e.opt.attributes, key)
                            if have ~= nil and tostring(have) ~= tostring(want) then
                                violate("attr_match", r.message or string.format("%s is %s but this system needs %s",
                                    e.opt.name or e.option, tostring(have), tostring(want)), { gc })
                            end
                        end
                    end
                end
            end
        end
    end

    -- price + breakdown
    local unit = int(product.base_price_minor, 0)
    local breakdown = {}
    local label_parts = {}
    for _, g in ipairs(ordered_groups) do
        local names = {}
        for _, e in ipairs(resolved[g.code]) do
            local delta = int(e.opt.price_delta_minor, 0)
            unit = unit + delta * e.qty
            breakdown[#breakdown + 1] = {
                group = g.code, option = e.option, name = e.opt.name or e.option,
                qty = e.qty, price_delta_minor = delta,
            }
            names[#names + 1] = (e.qty > 1 and (tostring(e.qty) .. "× ") or "") .. (e.opt.name or e.option)
        end
        if #names > 0 then label_parts[#label_parts + 1] = table.concat(names, " + ") end
    end

    local vat_rate = num(product.vat_rate, DEFAULT_VAT)
    local line_subtotal = unit * qty
    local line_vat = round(line_subtotal * vat_rate)

    local label = product.name or product.slug or "Item"
    if #label_parts > 0 then
        label = label .. " — " .. table.concat(label_parts, ", ")
    end
    if #label > 240 then label = label:sub(1, 237) .. "..." end

    -- availability: aggregate demand per stock key
    local demand, demand_by_key = {}, {}
    local function add_demand(key, n, name, available, allow_backorder, lead)
        if not key then return end
        local d = demand_by_key[key]
        if not d then
            d = { stock_key = key, qty = 0, name = name, available = available,
                  allow_backorder = allow_backorder, lead_time_days = lead }
            demand_by_key[key] = d
            demand[#demand + 1] = d
        end
        d.qty = d.qty + n
    end
    local product_lead = int(product.lead_time_days, 10)
    add_demand(product.stock_key, qty, product.name, product.available,
        product.allow_backorder ~= false, product_lead)
    for _, g in ipairs(ordered_groups) do
        for _, e in ipairs(resolved[g.code]) do
            local o = e.opt
            if o.stock_key then
                local ab = o.allow_backorder
                if ab == nil then ab = product.allow_backorder ~= false end
                add_demand(o.stock_key, e.qty * qty, o.name or e.option, o.available, ab,
                    int(o.lead_time_days, product_lead))
            end
        end
    end

    local shortages, orderable, lead = {}, true, product_lead
    for _, d in ipairs(demand) do
        if d.available ~= nil and d.qty > d.available then
            shortages[#shortages + 1] = {
                name = d.name, requested = d.qty, available = math.max(0, int(d.available, 0)),
            }
            if not d.allow_backorder then orderable = false end
            if d.lead_time_days and d.lead_time_days > lead then lead = d.lead_time_days end
        end
    end

    local priced = {
        product_slug = product.slug,
        qty = qty,
        selections = resolved_out,
        unit_price_minor = unit,
        line_subtotal_minor = line_subtotal,
        line_vat_minor = line_vat,
        line_total_minor = line_subtotal + line_vat,
        vat_rate = vat_rate,
        currency = product.currency or "GBP",
        price_mode = product.price_mode or "fixed",
        price_verified = product.price_verified,
        label = label,
        breakdown = breakdown,
        violations = violations,
        valid = #violations == 0,
        availability = {
            in_stock = #shortages == 0,
            lead_time_days = lead,
            shortages = shortages,
            orderable = orderable,
        },
    }
    return priced, demand
end

--- Apply an admin unit-price override to a Priced table (returns a copy).
function ShopPricing.apply_override(priced, override_minor)
    local o = int(override_minor, nil)
    if o == nil then return priced end
    local out = {}
    for k, v in pairs(priced) do out[k] = v end
    out.list_unit_price_minor = priced.unit_price_minor
    out.price_override_minor = o
    out.unit_price_minor = o
    out.line_subtotal_minor = o * priced.qty
    out.line_vat_minor = round(out.line_subtotal_minor * num(priced.vat_rate, DEFAULT_VAT))
    out.line_total_minor = out.line_subtotal_minor + out.line_vat_minor
    return out
end

--- Sum a list of priced lines into totals.
function ShopPricing.totals(lines, shipping_minor)
    local sub, vat, items = 0, 0, 0
    for _, l in ipairs(lines or {}) do
        sub = sub + int(l.line_subtotal_minor, 0)
        vat = vat + int(l.line_vat_minor, 0)
        items = items + int(l.qty, 0)
    end
    local ship = int(shipping_minor, 0)
    return {
        subtotal_minor = sub, vat_minor = vat, shipping_minor = ship,
        total_minor = sub + vat + ship, item_count = items,
    }
end

--- Canonical string for a (normalised) selections table — used to merge
-- identical cart lines.
function ShopPricing.selection_key(selections)
    local groups = {}
    for g, list in pairs(selections or {}) do
        local parts = {}
        for _, e in ipairs(list) do parts[#parts + 1] = tostring(e.option) .. "*" .. tostring(e.qty) end
        table.sort(parts)
        if #parts > 0 then groups[#groups + 1] = g .. "=" .. table.concat(parts, ",") end
    end
    table.sort(groups)
    return table.concat(groups, ";")
end

return ShopPricing
