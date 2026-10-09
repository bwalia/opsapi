--[[
    Billing & Entitlements — a customer's billing data (docs/BILLING_ENTITLEMENTS.md §16).

      GET    /api/v2/customers/:uuid/billing-export   customers.read AND subscriptions.read
      DELETE /api/v2/customers/:uuid/billing-data     customers.delete AND subscriptions.delete
                                                     (revoke + anonymise; accounting rows kept)
]]

local Http = require("helper.field-service-http")
local Privacy = require("queries.BillingPrivacyQueries")

-- Both permissions: customer data AND billing data.
local function both(action, handler)
    return Http.route(function(self)
        for _, module in ipairs({ "customers", "subscriptions" }) do
            if not Http.has_perm(self, module, action) then return Http.forbidden(module, action) end
        end
        return handler(self)
    end)
end

return function(app)
    app:get("/api/v2/customers/:uuid/billing-export", both("read", function(self)
        return Http.result(Privacy.export(self.namespace.id, self.params.uuid))
    end))

    app:delete("/api/v2/customers/:uuid/billing-data", both("delete", function(self)
        local res, err, status = Privacy.erase(self.namespace.id, self.params.uuid)
        -- Stripe unreachable: a gateway error (502), and nothing erased; retry later.
        if not res and status then return Http.fail(status, err) end
        return Http.result(res, err)
    end))
end
