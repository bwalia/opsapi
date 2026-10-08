--[[
    Store purchase verifiers (docs/BILLING_ENTITLEMENTS.md §12).
    Each source is a file in this folder exporting verify(app, payload) ->
    a normalised purchase { customer_external_id, store_product_id | plan_key,
    external_transaction_id, original_transaction_id?, expires_at?, status } | nil, err.
    Adding a real verifier is a new file here, not a change to callers.
]]

local Verifiers = {}
local KNOWN = { app_store = true, play_store = true }

function Verifiers.verify(source, app, payload)
    if not KNOWN[source] then
        return nil, { status = 400, code = "unknown_source", message = "source must be app_store or play_store" }
    end
    return require("lib.billing-verifiers." .. source).verify(app, payload)
end

return Verifiers
