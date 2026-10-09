--[[
    The one way OpsAPI verifies its own JWTs (helper/jwt-verify.lua)
    ==============================================================
    Every token OpsAPI issues is HS256 with an `exp`. Anything else is refused,
    whatever resty.jwt would accept: another algorithm (even one using the same
    secret), `none`, or a token that never expires.

      local verify = require("helper.jwt-verify")
      local obj = verify(secret, token[, claim_spec])   -- same result shape as jwt:verify
]]

local jwt = require("resty.jwt")

return function(secret, token, claim_spec)
    local obj = jwt:verify(secret, token, claim_spec)
    if not obj or not obj.verified then
        return obj or { verified = false, reason = "invalid token" }
    end
    if type(obj.header) ~= "table" or obj.header.alg ~= "HS256" then
        return { verified = false, reason = "algorithm not allowed" }
    end
    if type(obj.payload) ~= "table" or type(obj.payload.exp) ~= "number" then
        return { verified = false, reason = "token has no expiry" }
    end
    return obj
end
