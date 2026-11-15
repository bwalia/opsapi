-- luacheck: max line length 140
--[[
    Order update emails: presets and rules (pure Lua, no DB, no ngx)
    ================================================================
    Staff email a customer a short update about their order from the dashboard order page ("Email the
    customer"). The email is a transactional message (template shop.order_update in
    helper/namespace-mail.lua), never marketing: no unsubscribe link, no tracking pixel.
    queries/ShopOrderUpdateQueries.lua does the sending, the log and the order note.
    Unit-tested in spec/shop-order-updates_spec.lua.

      PRESETS                      ordered list of { key, label, headline, message }; messages use
                                   {first_name}, {order_number} and {tracking_line}
      preset(key)                  the preset, or nil
      first_name(name)             "Sam" from "Sam Taylor"; nil when blank
      fill(text, vars)             {name} → vars[name]; unknown names are left as they are
      render(preset, vars)         { key, label, headline, message } with the placeholders filled
      tracking_line(tracking)      "\n\nTracking: DPD 1234 (https://…)" or "" (for {tracking_line})
      unfilled(text)               the first "[NEW DATE]"-style marker staff must replace, or nil
      validate(body)               ({ headline, message }) | (nil, { field, message })
      delivery_summary(o)          "Tue 18 Nov 2026, morning, to 1 High St, London SW1A 1AA" or nil
      note_line(stamp, to, by, h)  the line appended to the order's internal notes after a real send
]]

local R = require("lib.shop-delivery-change")

local M = {}

M.HEADLINE_MAX = 120
M.MESSAGE_MAX = 4000
M.MAX_PER_DAY = 5        -- real sends to the customer per order in any 24 hours
M.TEST_MAX_PER_DAY = 20  -- test sends per order in any 24 hours
M.DEFAULT_SIGNATURE = "The Workstation team"
M.TEMPLATE_KEY = "shop.order_update"

-- Never name a supplier or distributor here: the customer only deals with us.
M.PRESETS = {
    {
        key = "received_reserved",
        label = "Order received, item reserved",
        headline = "Order received",
        message = "Thank you, we've received your order {order_number}. We've placed the order with our supplier and your "
            .. "item is reserved for you. We'll collect it in the next day or two, and as soon as it's with us we'll be "
            .. "in touch to agree a delivery time that suits you.",
    },
    {
        key = "in_stock_book_delivery",
        label = "Arrived, agree a delivery time",
        headline = "Ready to deliver",
        message = "Good news: your order {order_number} has arrived with us and is ready to deliver.\n\n"
            .. "Please reply to this email or give us a call to agree a delivery day and time that suits you. "
            .. "We're available Monday to Friday, 9am to 6pm.\n\n"
            .. "If you have an account with us, you can also sign in and request a delivery change from your order page.",
    },
    {
        key = "dispatched",
        label = "Dispatched",
        headline = "On its way",
        message = "Your order {order_number} has been dispatched and is on its way to you.{tracking_line}\n\n"
            .. "If anything isn't right when it arrives, please reply to this email or give us a call.",
    },
    {
        key = "delayed",
        label = "Delayed",
        headline = "Update on your order",
        message = "We're sorry, your order {order_number} is taking longer than we expected. We now expect it to be with "
            .. "you by [NEW DATE].\n\n"
            .. "We'll keep you updated, and if you have any questions please reply to this email or give us a call.",
    },
    {
        key = "custom",
        label = "Write your own",
        headline = "",
        message = "",
    },
}

local BY_KEY = {}
for _, p in ipairs(M.PRESETS) do BY_KEY[p.key] = p end

function M.preset(key)
    return type(key) == "string" and BY_KEY[key] or nil
end

function M.first_name(name)
    if type(name) ~= "string" then return nil end
    local first = name:match("^%s*(%S+)")
    return first
end

--- {name} → vars[name] (tostring). Unknown names stay as written so staff can see them.
function M.fill(text, vars)
    if type(text) ~= "string" then return "" end
    vars = vars or {}
    return (text:gsub("{([%w_]+)}", function(k)
        local v = vars[k]
        if v == nil then return nil end
        return tostring(v)
    end))
end

function M.render(p, vars)
    return { key = p.key, label = p.label, headline = M.fill(p.headline, vars), message = M.fill(p.message, vars) }
end

--- Tracking details for the {tracking_line} placeholder ("" when there are none).
-- tracking: { carrier?, tracking_number?, url? } as staff saved it on the order.
function M.tracking_line(tracking)
    if type(tracking) ~= "table" then return "" end
    local carrier = R.clean_line(tracking.carrier, 60)
    local number = R.clean_line(tracking.tracking_number, 80)
    local url = type(tracking.url) == "string" and tracking.url:match("^https?://[^%s]+$") or nil
    if not carrier and not number and not url then return "" end
    local parts = {}
    if carrier then parts[#parts + 1] = carrier end
    if number then parts[#parts + 1] = number end
    local s = "\n\nTracking: " .. (#parts > 0 and table.concat(parts, " ") or "")
    if url then s = s .. (#parts > 0 and " (" .. url .. ")" or url) end
    return s
end

--- A "[NEW DATE]" marker (capitals in square brackets) left in the text for staff to replace, or nil.
function M.unfilled(text)
    if type(text) ~= "string" then return nil end
    return text:match("%[[A-Z][A-Z0-9 /%-]*%]")
end

local function char_len(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

--- body: { headline, message } → ({ headline, message }) | (nil, { field, message }).
-- Control characters (and bidi overrides) are removed; the message keeps its line breaks.
function M.validate(body)
    if type(body) ~= "table" then return nil, { field = "body", message = "Invalid request" } end
    local headline = R.clean_line(body.headline, 100000)
    if not headline then return nil, { field = "headline", message = "Enter a headline" } end
    if char_len(headline) > M.HEADLINE_MAX then
        return nil, { field = "headline", message = "The headline can be at most " .. M.HEADLINE_MAX .. " characters" }
    end
    local message = R.clean_note(body.message, 100000)
    if not message then return nil, { field = "message", message = "Write the message" } end
    if char_len(message) > M.MESSAGE_MAX then
        return nil, { field = "message", message = "The message can be at most " .. M.MESSAGE_MAX .. " characters" }
    end
    return { headline = headline, message = message }
end

--- The agreed delivery in one line, or nil when nothing is agreed yet.
-- o: { delivery_date?, delivery_window?, delivery_address? (table), delivery_method? }
function M.delivery_summary(o)
    if type(o) ~= "table" then return nil end
    local parts = {}
    if type(o.delivery_date) == "string" and R.parse_date(o.delivery_date) then
        parts[#parts + 1] = R.date_label(o.delivery_date)
    end
    if R.WINDOWS[o.delivery_window] and o.delivery_window ~= "all_day" then
        parts[#parts + 1] = R.window_label(o.delivery_window):lower()
    end
    local s = table.concat(parts, ", ")
    if type(o.delivery_address) == "table" and next(o.delivery_address) then
        local a = {}
        for _, k in ipairs({ "name", "company", "line1", "line2", "city", "county", "postcode", "country" }) do
            a[k] = o.delivery_address[k]
        end
        local where = R.describe_address(a)
        if where ~= "not set" then s = s ~= "" and (s .. ", to " .. where) or ("To " .. where) end
    end
    return s ~= "" and s or nil
end

--- "[2026-11-15 14:03] Update emailed to ann@example.com by Sam Taylor: Order received"
function M.note_line(stamp, to, by, headline)
    return string.format("[%s] Update emailed to %s by %s: %s", tostring(stamp), tostring(to), tostring(by or "staff"),
        tostring(headline))
end

return M
