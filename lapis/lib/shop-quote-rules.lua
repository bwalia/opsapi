-- luacheck: max line length 140
--[[
    Shop quote rules (pure, no database): customer PO numbers, quote revisions and when a quote is locked.

    Covered by spec/shop-quote-revisions_spec.lua.

      clean_po_number(v)        the customer's purchase order number: trimmed, inner whitespace collapsed,
                                at most 64 characters, printable only. "" / nil = none.
      root_number(n)            "WSQ-2026-00012-R2" -> "WSQ-2026-00012"
      revision_number(root, n)  "WSQ-2026-00012", 3 -> "WSQ-2026-00012-R3"
      next_revision_no(nos)     one more than the highest revision_no in the chain (the original is 0)
      has_order(q)              the quote has turned into an order (order_id set, or converted)
      can_revise(q)             revisions: draft, sent, expired, accepted without an order; never converted,
                                cancelled or already superseded
      can_edit_content(q)       staff edits of lines, prices, customer or delivery: not once it has an order
                                and not once it is superseded
      locked_for_customer(q)    authorised (accepted), has an order, converted, cancelled or superseded: the
                                customer can't change anything any more
      order_fields(q)           the quote fields every order made from it carries ({ customer_po_number })
      supplier_po_notes(t)      the notes on a supplier PO raised from a shop order
]]

local R = {}

R.PO_NUMBER_MAX = 64

local function trim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end

--- Returns (value | nil, err). nil value without err = no PO number (blank).
function R.clean_po_number(v)
    if v == nil or v == false then return nil end
    if type(v) == "number" then v = string.format("%d", v) end
    if type(v) ~= "string" then return nil, "customer_po_number must be text" end
    local s = trim(v:gsub("[%c]", " ")):gsub("%s+", " ")
    if s == "" then return nil end
    if #s > R.PO_NUMBER_MAX then
        return nil, "customer_po_number must be " .. R.PO_NUMBER_MAX .. " characters or fewer"
    end
    return s
end

function R.root_number(n)
    n = tostring(n or "")
    return (n:gsub("%-R%d+$", ""))
end

function R.revision_number(root, n)
    return R.root_number(root) .. "-R" .. tostring(math.floor(tonumber(n) or 1))
end

--- nos: the revision_no of every quote in the chain (the original included).
function R.next_revision_no(nos)
    local max = 0
    for _, v in ipairs(nos or {}) do
        local n = tonumber(v) or 0
        if n > max then max = n end
    end
    return max + 1
end

local function set(v) return v ~= nil and v ~= false and v ~= "" and type(v) ~= "userdata" end

function R.has_order(q)
    return set(q.order_id) or set(q.order_uuid) or q.status == "converted"
end

function R.is_superseded(q)
    return set(q.superseded_by_id)
end

--- Returns (true) or (false, error_code, message).
function R.can_revise(q)
    if R.is_superseded(q) then
        return false, "QUOTE_SUPERSEDED", "This quote has already been revised: work on the latest revision"
    end
    if R.has_order(q) then
        return false, "QUOTE_HAS_ORDER", "This has turned into an order and can't be revised. "
            .. "Raise a new quote for any changes"
    end
    if q.status == "cancelled" then
        return false, "QUOTE_CANCELLED", "A cancelled quote can't be revised: create a new quote instead"
    end
    if q.status ~= "draft" and q.status ~= "sent" and q.status ~= "expired" and q.status ~= "accepted" then
        return false, "QUOTE_NOT_REVISABLE", "This quote can't be revised (status " .. tostring(q.status) .. ")"
    end
    return true
end

--- Staff edits of what the customer agreed to (lines, prices, discounts, shipping, customer, delivery).
function R.can_edit_content(q)
    if R.has_order(q) then
        return false, "QUOTE_HAS_ORDER", "This has turned into an order, so its lines, prices, customer and "
            .. "delivery can't change. Raise a new quote for any changes"
    end
    if R.is_superseded(q) then
        return false, "QUOTE_SUPERSEDED", "This quote has been replaced by a revision: edit the latest revision"
    end
    return true
end

--- The customer's own PO number on the quote (admin edit): not once it has an order or is closed.
function R.can_edit_po_number(q)
    if R.has_order(q) then
        return false, "QUOTE_HAS_ORDER", "This has turned into an order: change the PO number on the order instead"
    end
    if q.status == "converted" or q.status == "cancelled" then
        return false, "QUOTE_CLOSED", "The PO number can't change on a " .. q.status .. " quote"
    end
    return true
end

function R.locked_for_customer(q)
    return q.status == "accepted" or q.status == "converted" or q.status == "cancelled"
        or set(q.authorised_at) or R.has_order(q) or R.is_superseded(q)
end

function R.order_fields(q)
    local po = R.clean_po_number(q and q.customer_po_number)
    return { customer_po_number = po }
end

--- t: { delivery_method?, customer_po_number?, account_number?, supplier_notes?, notes? } -> string
function R.supplier_po_notes(t)
    local parts = {}
    local function add(s) if type(s) == "string" and s:match("%S") then parts[#parts + 1] = s end end
    if set(t.customer_po_number) then add("End customer PO: " .. t.customer_po_number) end
    if set(t.account_number) then add("Our account number: " .. t.account_number) end
    if set(t.delivery_method) then add("Delivery method: " .. t.delivery_method) end
    add(t.supplier_notes)
    add(t.notes)
    return table.concat(parts, "\n\n")
end

return R
