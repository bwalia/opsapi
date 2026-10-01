-- React to core events: open a follow-up ticket when an invoice is paid or a
-- customer is added. Handlers run in the background, at least once per event;
-- returning normally marks the delivery done, raising an error retries it.
local sdk = require("helper.plugin-sdk")

local tickets = sdk.resource("helpdesk_tickets")

local function open_ticket(event, title, description)
    if not event.namespace_id then return end
    local row, status, err = tickets.create(event.namespace_id, {
        title = title:sub(1, 255),
        description = description,
        status = "open",
        source_event = event.id,
    })
    if not row and status ~= 409 then -- 409: this event already opened its ticket
        error(err or "could not open ticket")
    end
end

return {
    -- A business event: fires once when an invoice becomes paid.
    ["invoice.paid"] = function(event)
        local invoice = event.data
        open_ticket(event,
            "Thank " .. (invoice.customer_name or "the customer") .. " for paying " .. (invoice.invoice_number or "their invoice"),
            "Invoice " .. (invoice.invoice_number or invoice.uuid) .. " was paid in full.")
    end,

    ["customer.created"] = function(event)
        local c = event.data
        local name = c.company_name or table.concat({ c.first_name or "", c.last_name or "" }, " "):match("^%s*(.-)%s*$")
        if name == "" then name = c.email or "new customer" end
        open_ticket(event, "Onboard " .. name, "New customer" .. (c.email and (" (" .. c.email .. ")") or "") .. ".")
    end,
}
