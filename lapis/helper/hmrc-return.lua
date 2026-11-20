--[[
    Where HMRC's OAuth callback may send someone after they sign in (`/auth/hmrc/initiate`
    signs it into the state; the callback redirects there with hmrc_connected / hmrc_error).

    Only the iOS app's address or a frontend this API already trusts: anything else would be
    an open redirect carrying the result of an HMRC sign-in.
]]

local Cors = require("middleware.cors")

local HMRCReturn = {}

-- The iOS app's return address (wslcrm-app Features/Tax/HMRCSignIn.swift): Apple's sign-in
-- sheet closes when HMRC's callback sends the person here.
HMRCReturn.APP = "wslcrm://hmrc"

-- Origins trusted beyond CORS for a sign-in return (bare origins, from the env).
function HMRCReturn.extra_frontends()
    local extra = {}
    for _, key in ipairs({ "PASSWORD_RESET_ALLOWED_ORIGINS", "FRONTEND_URL", "HMRC_FRONTEND_URL" }) do
        local raw = os.getenv(key)
        if raw then
            for entry in raw:gmatch("[^,%s]+") do
                local origin = entry:match("^(https?://[^/]+)")
                if origin then extra[origin] = true end
            end
        end
    end
    return extra
end

--- The address to use, or nil (the caller then uses its default frontend): the app, or a trusted
-- frontend origin with a plain path (`https://app.example/dashboard/tax`). No query, fragment,
-- user@host or other scheme.
function HMRCReturn.safe(url)
    if type(url) ~= "string" or url == "" then return nil end
    url = url:gsub("/+$", "")
    if url == HMRCReturn.APP then return url end
    local origin, path = url:match("^(https?://[^/?#]+)(.*)$")
    if not origin then return nil end
    if path ~= "" and not path:match("^/[%w%-%._~/]*$") then return nil end
    if not Cors.trustedFrontend(origin, HMRCReturn.extra_frontends()) then return nil end
    return origin .. path
end

return HMRCReturn
