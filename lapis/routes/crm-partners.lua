--[[
    Partners and referrals API (lib/crm/partners.lua)
    =================================================

    Partners are CRM accounts, so the directory uses the crm_accounts
    permission; referrals are deal work, so they use crm_deals (and a lead's
    visibility rule when the referral is about a lead).

      GET    /api/v2/crm/partners                 directory (search, active=all)
      POST   /api/v2/crm/partners                 add a partner (new company, or account_uuid)
      GET    /api/v2/crm/partners/:uuid
      PUT    /api/v2/crm/partners/:uuid
      GET    /api/v2/crm/referrals                (status, partner_uuid)
      POST   /api/v2/crm/referrals                pass a deal or lead to a partner
      POST   /api/v2/crm/referrals/:uuid/status   { status, deal_value?, partner_reference?, notes? }
      POST   /api/v2/crm/referrals/:uuid/send     send again (a fresh link)
      POST   /api/v2/crm/referrals/:uuid/invoice  bill the commission { tax_rate?, payment_terms_days? }
    Public (the partner's private link; rate limited):
      GET    /api/v2/public/referrals/:token
      POST   /api/v2/public/referrals/:token      { action: accept|decline|won|lost, reference?, notes?, deal_value? }
]]

local Api = require("lib.crm.api")
local U = require("lib.crm.util")
local Access = require("lib.crm.lead-access")
local Partners = require("lib.crm.partners")
local RateLimit = require("middleware.rate-limit")
local NamespaceMiddleware = require("middleware.namespace")

local H = Api.handler

local function off()
    return Api.fail({ status = 409, code = "PARTNERS_OFF", message = "Partners need the CRM module in this deployment" })
end

return function(app)
    app:get("/api/v2/crm/partners", H("crm_accounts", "read", function(self)
        if not Partners.available() then return off() end
        return Api.ok(Partners.list(self.namespace.id, { search = self.params.search, active = self.params.active }))
    end))

    app:post("/api/v2/crm/partners", H("crm_accounts", "create", function(self)
        local saved, err = Partners.save(self.namespace.id, Access.me(self), self.body)
        return Api.result(saved, err, 201)
    end))

    app:get("/api/v2/crm/partners/:uuid", H("crm_accounts", "read", function(self)
        if not Partners.available() then return off() end
        local p = Partners.get(self.namespace.id, self.params.uuid)
        if not p then return Api.not_found("Partner not found") end
        p.referral_list = Partners.referrals(self.namespace.id, { partner_uuid = p.uuid })
        return Api.ok(p)
    end))

    app:put("/api/v2/crm/partners/:uuid", H("crm_accounts", "update", function(self)
        if not U.is_uuid(self.params.uuid) then return Api.not_found("Partner not found") end
        return Api.result(Partners.save(self.namespace.id, Access.me(self), self.body, self.params.uuid))
    end))

    app:get("/api/v2/crm/referrals", H("crm_deals", "read", function(self)
        return Api.ok(Partners.referrals(self.namespace.id, { status = self.params.status, partner_uuid = self.params.partner_uuid }))
    end))

    app:post("/api/v2/crm/referrals", H("crm_deals", "update", function(self)
        local ns = self.namespace.id
        local subject, err = Partners.subject(ns, self.body)
        if not subject then return Api.fail(err) end
        if subject.lead and not subject.deal then
            if not Access.can_work(self, subject.lead) then return Api.denied("You can only pass on leads you own or unassigned ones") end
        end
        local r, rerr = Partners.refer(ns, Access.me(self), self.body)
        if not r then return Api.fail(rerr) end
        return Api.ok(r, 201)
    end))

    app:post("/api/v2/crm/referrals/:uuid/status", H("crm_deals", "update", function(self)
        if not U.is_uuid(self.params.uuid) then return Api.not_found("Referral not found") end
        return Api.result(Partners.move(self.namespace.id, Access.me(self), self.params.uuid, self.body))
    end))

    app:post("/api/v2/crm/referrals/:uuid/send", H("crm_deals", "update", function(self)
        if not U.is_uuid(self.params.uuid) then return Api.not_found("Referral not found") end
        local ok, why = Partners.send(self.namespace.id, self.params.uuid, nil, Access.me(self))
        if not ok then
            return Api.fail({ status = 409, code = "REFERRAL_NOT_SENT", message = "Couldn't send: " .. tostring(why) })
        end
        return Api.ok(Partners.referral(self.namespace.id, self.params.uuid))
    end))

    app:post("/api/v2/crm/referrals/:uuid/invoice", H("crm_deals", "update", function(self)
        if not U.is_uuid(self.params.uuid) then return Api.not_found("Referral not found") end
        if not NamespaceMiddleware.hasPermission(self, "invoices", "create") then
            return Api.denied("You need permission to create invoices")
        end
        local billed, err = Partners.invoice(self.namespace.id, Access.me(self), self.params.uuid, self.body)
        return Api.result(billed, err, 201)
    end))

    -- Public: the partner's link ------------------------------------------------

    app:get("/api/v2/public/referrals/:token", RateLimit.wrap({ rate = 30, window = 60, prefix = "public_referral" },
        Api.public(function(self)
            return Api.result(Partners.public_view(self.params.token))
        end)))

    app:post("/api/v2/public/referrals/:token", RateLimit.wrap({ rate = 10, window = 60, prefix = "public_referral_answer" },
        Api.public(function(self)
            local moved, err = Partners.respond(self.params.token, self.body)
            if not moved then return Api.fail(err) end
            return Api.result(Partners.public_view(self.params.token))
        end)))
end
