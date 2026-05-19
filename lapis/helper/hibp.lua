--- Have I Been Pwned (HIBP) k-anonymity password breach check.
--
-- We never send the plaintext password — not even hashed in full —
-- to a third party. HIBP's k-anonymity API takes the *first 5
-- characters* of the SHA-1 hash and returns every suffix that
-- matches that 5-char prefix. We then look for the rest of the hash
-- locally. The user's password (and its full hash) never leaves
-- this process.
--
-- See: https://haveibeenpwned.com/API/v3#PwnedPasswords
--
-- Why we bother (HMRC + GDPR):
--   The HMRC production-application questionnaire asks whether
--   passwords are checked against known-breached datasets. A "yes"
--   means a defensible answer; without it we have to tick "no". The
--   ICO's secure-by-design guidance points at the same control. A
--   single network call on registration is the cheapest way to honour
--   both.
--
-- Failure mode:
--   If HIBP is unreachable (DNS down, network egress blocked, their
--   service degraded), we LOG and ALLOW the registration to proceed.
--   Failing closed here would lock users out of signup over an
--   issue they can't fix; the rest of the password policy
--   (length + complexity) still applies, so a leaked-passwords
--   miss is the worst case, not a security breach.
local HIBP = {}

local DEFAULT_TIMEOUT_MS = 4000   -- HIBP usually answers in <300ms; 4s = generous
local DEFAULT_RANGE_URL = "https://api.pwnedpasswords.com/range/"

--- Compute upper-case hex SHA-1 of the input.
-- ``ngx.sha1_bin`` returns 20 bytes of raw SHA-1; ``resty.string.to_hex``
-- gives the canonical hex form. We upper-case because HIBP returns
-- the suffix list in upper-case and we want a byte-for-byte compare.
local function sha1_hex_upper(s)
    local raw = ngx.sha1_bin(s)
    if not raw then return nil, "sha1_bin unavailable" end
    return (require("resty.string").to_hex(raw)):upper()
end

--- Fetch the suffix list for a 5-char prefix from HIBP.
-- Returns the raw response body string on success, nil + err on failure.
local function fetch_range(prefix)
    local ok, http = pcall(require, "resty.http")
    if not ok then
        return nil, "resty.http not available"
    end
    local httpc = http.new()
    httpc:set_timeout(DEFAULT_TIMEOUT_MS)

    local res, err = httpc:request_uri(DEFAULT_RANGE_URL .. prefix, {
        method = "GET",
        headers = {
            -- HIBP uses Add-Padding to defeat traffic-analysis side
            -- channels (each response is padded to a uniform size).
            -- Cheap belt-and-braces; we already have the URL the request
            -- went to so the network observer learns nothing about
            -- which prefix we asked.
            ["Add-Padding"] = "true",
            ["User-Agent"] = "OpsAPI-Registration/1.0",
        },
        -- Match project-wide pattern for outbound TLS from Lua
        -- cosockets (see helper/hmrc.lua, lib/llm-client.lua):
        -- ssl_verify=true requires lua_ssl_trusted_certificate, which
        -- this image doesn't ship. The k-anonymity guarantee is
        -- preserved either way — only a 5-hex-char prefix ever leaves
        -- this process — so MITM on the lookup learns nothing about
        -- the underlying password.
        ssl_verify = false,
    })

    if not res then
        return nil, ("hibp request failed: %s"):format(tostring(err))
    end
    if res.status ~= 200 then
        return nil, ("hibp returned status %d"):format(res.status)
    end
    return res.body
end

--- Return the breach count (>=0) for ``password``, or nil + err if
-- the check could not be performed.
--
-- A non-nil, non-zero count means HIBP has seen this exact password
-- in at least that many breached datasets. Even a count of 1 is
-- enough to block the registration: HMRC's questionnaire and NIST
-- 800-63B both say "any" hit, not "many hits".
function HIBP.check_password(password)
    if type(password) ~= "string" or password == "" then
        return nil, "empty password"
    end

    local hash, err = sha1_hex_upper(password)
    if not hash then return nil, err end

    local prefix = hash:sub(1, 5)
    local suffix = hash:sub(6)   -- 35 chars

    local body, fetch_err = fetch_range(prefix)
    if not body then return nil, fetch_err end

    -- Body lines look like:
    --   "0018A45C4D1DEF81644B54AB7F969B88D65:1"
    --   "00D4F6E8FA6EECAD2A3AA415EEC418D38EC:2"
    -- Each line carries the 35-char hash suffix followed by `:` and
    -- the count of times that password appears in HIBP's corpus.
    -- Linear scan is fine — body is ~25 KB on average and we exit early
    -- on the first match.
    for line in body:gmatch("[^\r\n]+") do
        local colon = line:find(":", 1, true)
        if colon then
            local suffix_part = line:sub(1, colon - 1):upper()
            if suffix_part == suffix then
                return tonumber(line:sub(colon + 1)) or 1
            end
        end
    end
    return 0
end

return HIBP
