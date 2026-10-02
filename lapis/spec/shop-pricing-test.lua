-- luacheck: max line length 140
--[[
    Plain-Lua unit test for lib/shop-pricing.lua (no nginx, no DB, no busted).

    Run from lapis/:
        luajit spec/shop-pricing-test.lua
    or in the openresty image:
        docker run --rm -v "$PWD":/w -w /w openresty/openresty:alpine \
            luajit spec/shop-pricing-test.lua
]]

package.path = "./?.lua;./?/init.lua;" .. package.path
local P = require("lib.shop-pricing")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("ok   - " .. name)
    else
        failed = failed + 1
        print("FAIL - " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

local function has_violation(priced, rule)
    for _, v in ipairs(priced.violations) do
        if v.rule == rule then return v end
    end
    return nil
end

local function rules_of(priced)
    local t = {}
    for _, v in ipairs(priced.violations) do t[#t + 1] = v.rule .. ": " .. v.message end
    return table.concat(t, " | ")
end

-- ---------------------------------------------------------------------------
-- Fixture: Threadripper PRO tower, 4 dual-slot GPU bays, 8-ch DDR5 RDIMM
-- ---------------------------------------------------------------------------
local product = {
    slug = "tr-pro-9000-tower", name = "Threadripper PRO 9000 AI Workstation",
    base_price_minor = 300000, vat_rate = 0.20, price_mode = "configurable",
    attributes = { gpu_slots = 8, memory_type = "DDR5-RDIMM", socket = "sTR5" },
    available = 3, stock_key = "p:1", allow_backorder = true, lead_time_days = 10,
}

local groups = {
    { code = "cpu", name = "Processor", selection = "single", required = true, min_qty = 1, max_qty = 1, options = {
        { code = "9965wx", name = "Threadripper PRO 9965WX", price_delta_minor = 350000, max_qty = 1, is_default = true,
          attributes = { watts = 350, socket = "sTR5" }, available = 2, stock_key = "p:10", allow_backorder = true },
        { code = "9995wx", name = "Threadripper PRO 9995WX", price_delta_minor = 1100000, max_qty = 1,
          attributes = { watts = 350, socket = "sTR5" }, available = 0, stock_key = "p:11", allow_backorder = false,
          lead_time_days = 21 },
    } },
    { code = "gpu", name = "Graphics", selection = "multi", required = true, min_qty = 1, max_qty = 4, options = {
        { code = "rtx-pro-6000-we", name = "RTX PRO 6000 Blackwell Workstation Edition", price_delta_minor = 750000,
          max_qty = 4, is_default = true, attributes = { watts = 600, slots = 2, vram_gb = 96, edition = "workstation" },
          available = 10, stock_key = "o:20" },
        { code = "rtx-pro-6000-maxq", name = "RTX PRO 6000 Blackwell Max-Q", price_delta_minor = 750000,
          max_qty = 4, attributes = { watts = 300, slots = 2, vram_gb = 96, edition = "maxq" } },
        { code = "rtx-pro-4000", name = "RTX PRO 4000 Blackwell", price_delta_minor = 150000,
          max_qty = 4, attributes = { watts = 140, slots = 1, vram_gb = 24 } },
    } },
    { code = "memory", name = "Memory", selection = "single", required = true, min_qty = 1, max_qty = 1, options = {
        { code = "256gb", name = "256 GB DDR5 RDIMM (8×32 GB)", price_delta_minor = 120000, is_default = true,
          attributes = { memory_type = "DDR5-RDIMM", capacity_gb = 256 } },
        { code = "256gb-udimm", name = "256 GB DDR5 UDIMM", price_delta_minor = 90000,
          attributes = { memory_type = "DDR5-UDIMM", capacity_gb = 256 } },
    } },
    { code = "psu", name = "Power supply", selection = "single", required = true, min_qty = 1, max_qty = 1, options = {
        { code = "1600w", name = "1600 W Titanium", price_delta_minor = 0, is_default = true, attributes = { psu_watts = 1600 } },
        { code = "2x1600w", name = "2× 1600 W redundant", price_delta_minor = 60000, attributes = { psu_watts = 3200 } },
    } },
    { code = "warranty", name = "Warranty", selection = "single", required = false, min_qty = 0, max_qty = 1, options = {
        { code = "3y", name = "3 years", price_delta_minor = 0, is_default = true },
        { code = "5y-onsite", name = "5 years onsite", price_delta_minor = 45000 },
    } },
    { code = "accessories", name = "Accessories", selection = "multi", required = false, min_qty = 0, max_qty = 3, options = {
        { code = "kb", name = "Keyboard", price_delta_minor = 5000, max_qty = 1 },
        { code = "rails", name = "Rack rails", price_delta_minor = 9000, max_qty = 1 },
    } },
}

local rules = {
    { kind = "power", message = "The selected PSU cannot power this configuration",
      params = { budget_from = "psu", budget_attr = "psu_watts", sum_attr = "watts",
                 groups = { "cpu", "gpu" }, base_watts = 250, headroom = 0.9 } },
    { kind = "max_total", message = "Not enough PCIe slots",
      params = { group = "gpu", attr = "slots", limit_attr = "gpu_slots" } },
    { kind = "attr_match", message = "Memory type must match the platform",
      params = { group = "memory", attr = "memory_type", equals_product_attr = "memory_type" } },
    { kind = "requires", message = "The 5 year onsite warranty needs the redundant PSU",
      params = { ["if"] = "warranty.5y-onsite", then_group = "psu", one_of = { "2x1600w" } } },
    { kind = "excludes", message = "Rack rails are not compatible with the keyboard bundle",
      params = { a = "accessories.rails", b = "accessories.kb" } },
}

-- 1. Defaults only -----------------------------------------------------------
local p1, demand1 = P.price(product, groups, rules, {}, 1)
check("defaults: valid", p1.valid, rules_of(p1))
check("defaults: unit price = base + cpu + 1 gpu + memory",
    p1.unit_price_minor == 300000 + 350000 + 750000 + 120000, p1.unit_price_minor)
check("defaults: vat 20%", p1.line_vat_minor == math.floor(p1.line_subtotal_minor * 0.2 + 0.5), p1.line_vat_minor)
check("defaults: total = subtotal + vat", p1.line_total_minor == p1.line_subtotal_minor + p1.line_vat_minor)
check("defaults: selections echo psu + warranty", p1.selections.psu and p1.selections.psu[1].option == "1600w"
    and p1.selections.warranty and p1.selections.warranty[1].option == "3y")
check("defaults: breakdown has 5 entries", #p1.breakdown == 5, #p1.breakdown)
check("defaults: in stock", p1.availability.in_stock)
check("defaults: demand aggregates product + cpu + gpu", #demand1 == 3, #demand1)
check("defaults: label mentions product", p1.label:find("Threadripper PRO 9000", 1, true) ~= nil, p1.label)

-- 2. THE case: 4× RTX PRO 6000 WE (600 W, 2 slots each) on a 1600 W PSU -------
local sel_power = {
    cpu = { { option = "9965wx", qty = 1 } },
    gpu = { { option = "rtx-pro-6000-we", qty = 4 } },
    memory = { { option = "256gb", qty = 1 } },
    psu = { { option = "1600w", qty = 1 } },
}
local p2 = P.price(product, groups, rules, sel_power, 1)
local pv = has_violation(p2, "power")
check("4x RTX PRO 6000 WE on 1600W: invalid", p2.valid == false)
check("4x RTX PRO 6000 WE on 1600W: power violation", pv ~= nil, rules_of(p2))
check("power violation mentions 3000W draw vs 1440W usable",
    pv and pv.message:find("3000W", 1, true) and pv.message:find("1440W", 1, true), pv and pv.message)
check("power violation groups include psu and gpu", pv and pv.groups[1] == "psu" and pv.groups[3] == "gpu")
check("8 slots used of 8: no max_total violation", has_violation(p2, "max_total") == nil, rules_of(p2))
check("price still computed for invalid config", p2.unit_price_minor == 300000 + 350000 + 4 * 750000 + 120000)

-- 2b. same GPUs with the 2× 1600 W PSU: 3000 ≤ 3200×0.9=2880? no -> still over
local sel_power2 = { gpu = { { option = "rtx-pro-6000-we", qty = 4 } }, psu = { { option = "2x1600w", qty = 1 } } }
local p2b = P.price(product, groups, rules, sel_power2, 1)
check("4x WE on 2x1600W (2880W usable vs 3000W): still power violation", has_violation(p2b, "power") ~= nil)
-- 2c. Max-Q edition: 4×300 + 350 + 250 = 1800 ≤ 2880 -> valid
local p2c = P.price(product, groups, rules,
    { gpu = { { option = "rtx-pro-6000-maxq", qty = 4 } }, psu = { { option = "2x1600w", qty = 1 } } }, 1)
check("4x Max-Q on 2x1600W: valid", p2c.valid, rules_of(p2c))
-- 2d. 2× WE on 1600 W: 1200+350+250 = 1800 > 1440 -> violation
local p2d = P.price(product, groups, rules, { gpu = { { option = "rtx-pro-6000-we", qty = 2 } } }, 1)
check("2x WE on 1600W: power violation", has_violation(p2d, "power") ~= nil)

-- 3. max_total (slots) ---------------------------------------------------------
local small = {}
for k, v in pairs(product) do small[k] = v end
small.attributes = { gpu_slots = 4, memory_type = "DDR5-RDIMM" }
local p3 = P.price(small, groups, rules,
    { gpu = { { option = "rtx-pro-6000-maxq", qty = 3 } }, psu = { { option = "2x1600w", qty = 1 } } }, 1)
check("3 dual-slot GPUs in 4 slots: max_total violation", has_violation(p3, "max_total") ~= nil, rules_of(p3))

-- 4. attr_match ------------------------------------------------------------------
local p4 = P.price(product, groups, rules, { memory = { { option = "256gb-udimm", qty = 1 } } }, 1)
check("UDIMM on RDIMM platform: attr_match violation", has_violation(p4, "attr_match") ~= nil, rules_of(p4))

-- 5. requires ----------------------------------------------------------------------
local p5 = P.price(product, groups, rules, { warranty = { { option = "5y-onsite", qty = 1 } } }, 1)
check("5y onsite without redundant PSU: requires violation", has_violation(p5, "requires") ~= nil, rules_of(p5))
local p5b = P.price(product, groups, rules,
    { warranty = { { option = "5y-onsite", qty = 1 } }, psu = { { option = "2x1600w", qty = 1 } } }, 1)
check("5y onsite with redundant PSU: no requires violation", has_violation(p5b, "requires") == nil, rules_of(p5b))

-- 6. excludes -------------------------------------------------------------------------
local p6 = P.price(product, groups, rules,
    { accessories = { { option = "rails", qty = 1 }, { option = "kb", qty = 1 } } }, 1)
check("rails + keyboard: excludes violation", has_violation(p6, "excludes") ~= nil, rules_of(p6))

-- 7. group constraints -------------------------------------------------------------------
local p7 = P.price(product, groups, rules, { cpu = {} }, 1)
check("explicitly empty required group: required violation", has_violation(p7, "required") ~= nil, rules_of(p7))
local p7b = P.price(product, groups, rules,
    { cpu = { { option = "9965wx", qty = 1 }, { option = "9995wx", qty = 1 } } }, 1)
check("two CPUs in single group: selection + group_max violations",
    has_violation(p7b, "selection") ~= nil and has_violation(p7b, "group_max") ~= nil, rules_of(p7b))
local p7c = P.price(product, groups, rules, { gpu = { { option = "rtx-pro-4000", qty = 5 } } }, 1)
check("5 GPUs (max 4): option_max_qty + group_max", has_violation(p7c, "option_max_qty") ~= nil
    and has_violation(p7c, "group_max") ~= nil, rules_of(p7c))
local p7d = P.price(product, groups, rules, { gpu = { { option = "nope", qty = 1 } } }, 1)
check("unknown option: unknown_option + required", has_violation(p7d, "unknown_option") ~= nil
    and has_violation(p7d, "required") ~= nil, rules_of(p7d))
local p7e = P.price(product, groups, rules, { bogus = { { option = "x", qty = 1 } } }, 1)
check("unknown group: unknown_group violation", has_violation(p7e, "unknown_group") ~= nil)
local p7f = P.price(product, groups, rules, { cpu = "9965wx", gpu = { "rtx-pro-4000" } }, 1)
check("shorthand selections accepted", p7f.valid and p7f.selections.gpu[1].option == "rtx-pro-4000", rules_of(p7f))

-- 8. availability / stock -------------------------------------------------------------------
local p8 = P.price(product, groups, rules, { cpu = { { option = "9995wx", qty = 1 } } }, 1)
check("component with 0 stock and no backorder: shortage + not orderable",
    not p8.availability.in_stock and p8.availability.orderable == false and #p8.availability.shortages == 1)
check("shortage lead time = component lead time (21)", p8.availability.lead_time_days == 21,
    p8.availability.lead_time_days)
check("stock shortage is not a rule violation", p8.valid)
local p8b = P.price(product, groups, rules, {}, 4)
check("qty 4 > product available 3 and cpu 2: two shortages, backorderable",
    #p8b.availability.shortages == 2 and p8b.availability.orderable == true, #p8b.availability.shortages)
local p8c = P.price(product, groups, rules, { gpu = { { option = "rtx-pro-6000-we", qty = 3 } } }, 4)
local gpu_short
for _, s in ipairs(p8c.availability.shortages) do if s.name:find("Workstation Edition", 1, true) then gpu_short = s end end
check("gpu demand = 3 per unit × 4 units = 12 > 10", gpu_short and gpu_short.requested == 12 and gpu_short.available == 10)
check("line totals scale with qty", p8c.line_subtotal_minor == p8c.unit_price_minor * 4)

-- 9. fixed product, no groups ----------------------------------------------------------------
local fixed = { slug = "dgx-spark", name = "NVIDIA DGX Spark", base_price_minor = 399900, vat_rate = 0.2,
    price_mode = "fixed", available = nil, allow_backorder = true, lead_time_days = 5 }
local p9 = P.price(fixed, {}, {}, nil, 2)
check("fixed product: valid, untracked => in stock", p9.valid and p9.availability.in_stock)
check("fixed product: subtotal 2×399900", p9.line_subtotal_minor == 799800)
check("fixed product: vat 159960", p9.line_vat_minor == 159960, p9.line_vat_minor)
check("qty 0 -> violation", has_violation(P.price(fixed, {}, {}, nil, 0), "qty") ~= nil)

-- 10. helpers ----------------------------------------------------------------------------------
check("from_price = base + cheapest required", P.from_price(product, groups) == 300000 + 350000 + 150000 + 90000 + 0,
    P.from_price(product, groups))
local ov = P.apply_override(p9, 350000)
check("override recomputes totals", ov.unit_price_minor == 350000 and ov.line_subtotal_minor == 700000
    and ov.line_vat_minor == 140000 and ov.list_unit_price_minor == 399900)
local t = P.totals({ p9, ov }, 0)
check("totals sum lines", t.subtotal_minor == 799800 + 700000 and t.item_count == 4)
check("selection_key is order independent",
    P.selection_key({ a = { { option = "x", qty = 1 }, { option = "y", qty = 2 } }, b = { { option = "z", qty = 1 } } })
    == P.selection_key({ b = { { option = "z", qty = 1 } }, a = { { option = "y", qty = 2 }, { option = "x", qty = 1 } } }))
check("round half up", P.round(2.5) == 3 and P.round(2.49) == 2 and P.round(-2.5) == -3)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
