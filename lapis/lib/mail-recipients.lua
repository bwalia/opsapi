--[[
    Which recipients can never receive mail (pure, no nginx; spec/mail-recipients_spec.lua).

    Test data uses reserved names (RFC 2606 / RFC 6761): lp-rep1@e2e.invalid, someone@example.com,
    manager@workstation.test. Sending to them only earns an "Address not found" bounce in the sending
    account's inbox, on every environment, so helper/mail.lua drops them before SMTP.
]]

local M = {}

local RESERVED_TLD = { invalid = true, test = true, example = true, localhost = true }
local RESERVED_DOMAIN = { ["example.com"] = true, ["example.net"] = true, ["example.org"] = true }

--- The domain of an address ("Name <a@b.c>" or "a@b.c"), lower-cased; nil when there isn't one.
local function domain_of(address)
    if type(address) ~= "string" then return nil end
    local inner = address:match("<([^>]*)>") or address
    local domain = inner:match("@([^@%s]+)%s*$")
    if not domain then return nil end
    return (domain:lower():gsub("%.$", ""))
end

--- True when the address is on a reserved domain that can never receive mail.
function M.undeliverable(address)
    local domain = domain_of(address)
    if not domain then return false end
    if RESERVED_DOMAIN[domain] then return true end
    for _, base in ipairs({ "example.com", "example.net", "example.org" }) do
        if domain:sub(-(#base + 1)) == "." .. base then return true end
    end
    local tld = domain:match("([^.]+)$")
    return RESERVED_TLD[tld] == true
end

--- Split a recipient field (string, comma-separated string or list) into addresses.
local function list(value)
    local out = {}
    if type(value) == "table" then
        for _, v in ipairs(value) do
            if type(v) == "string" and v:match("%S") then out[#out + 1] = v end
        end
    elseif type(value) == "string" then
        for part in value:gmatch("[^,]+") do
            local v = part:match("^%s*(.-)%s*$")
            if v ~= "" then out[#out + 1] = v end
        end
    end
    return out
end

--- Drop undeliverable addresses from a recipient field.
--- Returns (kept, dropped): kept keeps the input's shape (one string stays a string, otherwise a list;
--- nil when nothing is left); dropped is a list of the addresses removed.
function M.filter(value)
    local kept, dropped = {}, {}
    for _, address in ipairs(list(value)) do
        if M.undeliverable(address) then dropped[#dropped + 1] = address else kept[#kept + 1] = address end
    end
    if #kept == 0 then return nil, dropped end
    if type(value) == "string" and #kept == 1 then return kept[1], dropped end
    return kept, dropped
end

return M
