--[[
    Spec: e-invoices belong to one VAT registration, not the whole workspace (sole traders
    share a workspace), and the training-data similarity search is platform-admin only.

    Run: /usr/local/openresty/luajit/bin/luajit lapis/spec/vat-einvoice-scoping_spec.lua
]]

package.path = "./?.lua;lapis/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

ngx = { null = {}, log = function() end, ERR = 3 } -- luacheck: ignore 111

-- A tiny in-memory vat_einvoice_documents table behind a fake lapis.db that understands
-- the few query shapes VatEinvoiceQueries uses.
local NULL = setmetatable({}, { __tostring = function() return "NULL" end })
local docs, next_id = {}, 1
local function rid(v) return (v == nil or v == NULL) and 0 or tonumber(v) end
local function args_of(...) return { ... } end

package.loaded["lapis.db"] = {
    NULL = NULL,
    raw = function(s) return s end,
    escape_literal = function(v) return type(v) == "number" and tostring(v) or ("'" .. tostring(v) .. "'") end,
    insert = function(_, row)
        row.id, row.uuid = next_id, "doc-" .. next_id
        next_id = next_id + 1
        docs[#docs + 1] = row
    end,
    update = function(_, row, where)
        for _, d in ipairs(docs) do
            if d.id == where.id then for k, v in pairs(row) do d[k] = v end end
        end
    end,
    query = function(sql, ...)
        local a = args_of(...)
        local out = {}
        if sql:find("FROM vat_einvoice_documents WHERE id = ?", 1, true) then
            for _, d in ipairs(docs) do if d.id == a[1] then out[1] = d end end
        elseif sql:find("COALESCE(registration_id, 0) = ? AND direction = ? AND document_id = ?", 1, true) then
            for _, d in ipairs(docs) do
                if d.namespace_id == a[1] and rid(d.registration_id) == a[2] and d.direction == a[3]
                    and d.document_id == a[4] then out[#out + 1] = d end
            end
        elseif sql:find("WHERE uuid = ? AND namespace_id = ?", 1, true) then
            for _, d in ipairs(docs) do
                if d.uuid == a[1] and d.namespace_id == a[2] and (not sql:find("registration_id", 1, true)
                    or rid(d.registration_id) == a[3]) then out[1] = d end
            end
        elseif sql:find("FROM vat_einvoice_documents WHERE ", 1, true) then -- list: inline literals
            local ns = tonumber(sql:match("namespace_id = (%d+)"))
            local reg = tonumber(sql:match("registration_id = (%d+)"))
            for _, d in ipairs(docs) do
                if d.namespace_id == ns and (reg == nil or rid(d.registration_id) == reg) then out[#out + 1] = d end
            end
        end
        return out
    end,
}

local Q = require("queries.VatEinvoiceQueries")
local E = require("lib.vat-einvoice")

local NS = 7
local alice = { id = 11, namespace_id = NS, vrn = "100000034" }
local bob = { id = 12, namespace_id = NS, vrn = "100000042" }
local xml = E.build({ invoice_number = "SUP-42", issue_date = "2026-11-02", currency = "GBP",
    customer_name = "Alice Ltd" }, { { description = "Widgets", quantity = 3, unit_price = 10, tax_rate = 20 } },
    { name = "Supplier Co", vrn = "100000034" })

print("== e-invoices are kept per VAT registration")
local ra = Q.import(alice, { id = 1 }, xml, false)
check("Alice's import is stored", ra and ra.document ~= nil, ra and ra.document)
local rb = Q.import(bob, { id = 2 }, xml, false)
check("Bob importing the same supplier invoice gets his own document", ra and rb and rb.document ~= ra.document)
check("...and doesn't overwrite Alice's", #docs == 2 and docs[1].registration_id == alice.id, #docs)
check("Alice lists only hers", #Q.list(NS, alice) == 1 and Q.list(NS, alice)[1].uuid == ra.document)
check("Bob lists only his", #Q.list(NS, bob) == 1 and Q.list(NS, bob)[1].uuid == rb.document)
local row, _, status = Q.get(NS, bob, ra.document)
check("Bob can't open Alice's document", row == nil and status == 404, status)
check("Alice can open hers", Q.get(NS, alice, ra.document) ~= nil)
local again = Q.import(alice, { id = 1 }, xml, false)
check("Alice re-importing replaces her own copy", again.document == ra.document and #docs == 2, #docs)

print("== training-data similarity search is admin-only")
local src = assert(io.open("lapis/routes/tax-training-data.lua")):read("*a")
local route = src:match('app:get%("/api/v2/training%-data/search%-similar".-\n    %)')
check("route found", route ~= nil)
check("checks platform admin before anything else", route and route:find("isAdmin%(self%.current_user%)")
    and route:find("isAdmin") < route:find("self.params.description"))
check("clamps limit and threshold", route and route:find("math.min%(math.floor%(tonumber%(self.params.limit%)")
    and route:find("math.max%(0, math.min%(tonumber%(self.params.threshold%)"))

if failures > 0 then print(failures .. " FAILED") os.exit(1) end
print("all passed")
