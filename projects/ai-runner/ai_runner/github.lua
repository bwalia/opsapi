-- GitHub App client for the built-in runner (docs/AI_RUNNER.md §28.3). The platform admin registers one GitHub App
-- (platform settings: app id, slug, client id, and the client secret and private key, sealed); workspaces install it
-- on the repositories they choose. OpsAPI signs a 9-minute app JWT (RS256) to mint an installation token, scoped to
-- the one repository a run works in and cached until shortly before it expires. GitHub Enterprise Server works by
-- setting api_url / web_url. No machine, git or shell: files are read and written through the REST API.
local cjson = require("cjson.safe").new()
cjson.encode_empty_table_as_object(true)
local R = require("ai_runner.runs")

local G = {}

G.PURPOSE = "ai_runner_github" -- secret-box purpose of the sealed client secret and private key
G.API_URL, G.WEB_URL = "https://api.github.com", "https://github.com"
G.TIMEOUT_MS = 30000

local function b64url(s)
    return (ngx.encode_base64(s):gsub("+", "-"):gsub("/", "_"):gsub("=+$", ""))
end

local function blank(v) return v == nil or v == "" or v == cjson.null end

--- An API or web base address: http(s), a host, an optional port and path, no trailing slash; else nil.
function G.base_url(v)
    if type(v) ~= "string" or #v > 255 then return nil end
    local s = v:gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
    local host, rest = s:match("^https?://([%w%-%.]+)(.*)$")
    if not host then return nil end
    rest = rest:gsub("^:%d+", "")
    if rest == "" or rest:match("^/[%w%-%._/]+$") then return s end
end

--- The platform's GitHub App: { api_url, web_url, app_id, app_slug, client_id, client_secret, private_key,
-- configured, stored } — the secrets opened from their seals (never returned to a browser).
function G.config()
    local s = R.platform().github
    s = type(s) == "table" and s or {}
    local Box = require("helper.secret-box")
    local c = { api_url = G.base_url(s.api_url) or G.API_URL, web_url = G.base_url(s.web_url) or G.WEB_URL,
        app_id = not blank(s.app_id) and tostring(s.app_id) or nil,
        app_slug = not blank(s.app_slug) and s.app_slug or nil,
        client_id = not blank(s.client_id) and s.client_id or nil, stored = s }
    if not blank(s.client_secret_sealed) then c.client_secret = Box.open(s.client_secret_sealed, G.PURPOSE) end
    if not blank(s.private_key_sealed) then c.private_key = Box.open(s.private_key_sealed, G.PURPOSE) end
    c.configured = c.app_id ~= nil and c.app_slug ~= nil and c.client_id ~= nil and c.client_secret ~= nil
        and c.private_key ~= nil
    return c
end

-- One HTTP call. @return decoded body (or {}), status | nil, status, short error
local function request(method, url, headers, body)
    local http = require("resty.http").new()
    http:set_timeout(G.TIMEOUT_MS)
    headers = headers or {}
    headers["Accept"] = headers["Accept"] or "application/vnd.github+json"
    headers["User-Agent"] = "opsapi-ai-runs"
    headers["X-GitHub-Api-Version"] = "2022-11-28"
    local payload
    if body ~= nil then
        headers["Content-Type"] = "application/json"
        payload = cjson.encode(body)
    elseif method == "POST" or method == "PUT" then
        payload = "" -- resty.http refuses a POST without one
    end
    local res, err = http:request_uri(url, { method = method, headers = headers, body = payload, ssl_verify = true })
    if not res then return nil, nil, "GitHub is unreachable (" .. tostring(err) .. ")" end
    local data = res.body ~= nil and res.body ~= "" and cjson.decode(res.body) or {}
    if res.status >= 400 then
        local msg = type(data) == "table" and type(data.message) == "string" and data.message or nil
        return nil, res.status, "GitHub answered " .. res.status .. (msg and (": " .. msg:sub(1, 200)) or "")
    end
    return type(data) == "table" and data or {}, res.status
end
G.request = request

--- A path segment by segment, each escaped (slashes stay separators).
function G.path(p)
    return (tostring(p):gsub("[^/]+", function(seg) return ngx.escape_uri(seg) end))
end

--- The app's own JWT (RS256, 9 minutes; iat 60 s back for clock drift). nil, err when the key can't sign.
function G.app_jwt(c)
    local ok, key = pcall(require("resty.openssl.pkey").new, c.private_key)
    if not ok or not key then return nil, "the GitHub App private key can't be read" end
    local now = ngx.time()
    local input = b64url(cjson.encode({ alg = "RS256", typ = "JWT" })) .. "."
        .. b64url(cjson.encode({ iat = now - 60, exp = now + 540, iss = tonumber(c.app_id) or c.app_id }))
    local sig, err = key:sign(input, "sha256")
    if not sig then return nil, "signing failed: " .. tostring(err) end
    return input .. "." .. b64url(sig)
end

--- An installation token, for one repository (its name) or every repository the installation covers (nil).
-- Cached in the shared cache for 50 minutes (they live 60). @return token | nil, err
function G.installation_token(c, installation_id, repo)
    local cache = ngx.shared and ngx.shared.cache
    local key = "ar:gh:token:" .. tostring(c.app_id) .. ":" .. tostring(installation_id) .. ":" .. tostring(repo or "*")
    local hit = cache and cache:get(key)
    if hit then return hit end
    local jwt, jerr = G.app_jwt(c)
    if not jwt then return nil, jerr end
    local data, status, err = request("POST", c.api_url .. "/app/installations/" .. tostring(installation_id)
        .. "/access_tokens", { Authorization = "Bearer " .. jwt }, repo and { repositories = { repo } } or nil)
    if not data then
        if status == 404 then return nil, "the GitHub App is no longer installed there (reconnect it)" end
        return nil, err
    end
    if type(data.token) ~= "string" then return nil, "GitHub gave no installation token" end
    if cache then cache:set(key, data.token, 50 * 60) end
    return data.token
end

--- Every repository an installation covers (up to 500). @return list | nil, err
function G.installation_repos(c, installation_id)
    local token, err = G.installation_token(c, installation_id)
    if not token then return nil, err end
    local out = {}
    for page = 1, 5 do
        local data, _, rerr = request("GET", c.api_url .. "/installation/repositories?per_page=100&page=" .. page,
            { Authorization = "Bearer " .. token })
        if not data then return nil, rerr end
        for _, r in ipairs(type(data.repositories) == "table" and data.repositories or {}) do
            if type(r) == "table" and type(r.full_name) == "string" then
                out[#out + 1] = { full_name = r.full_name, default_branch = r.default_branch,
                    private = r.private == true, archived = r.archived == true }
            end
        end
        if #(data.repositories or {}) < 100 then break end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Connecting an installation (OAuth): the person proves they can reach it
-- ---------------------------------------------------------------------------

local function secret()
    local s = os.getenv("JWT_SECRET_KEY")
    if not s or s == "" then error("JWT_SECRET_KEY is not set") end
    return s
end

local function mac(payload)
    return b64url(require("resty.openssl.hmac").new(secret(), "sha256"):final("ai_runner_github_state|" .. payload))
end

--- A signed, 10-minute state for the OAuth round trip: { ns, user, installation_id }.
function G.sign_state(t)
    t.exp = ngx.time() + 600
    local payload = b64url(cjson.encode(t))
    return payload .. "." .. mac(payload)
end

--- The state's contents, or nil when it was changed or has expired.
function G.read_state(s)
    if type(s) ~= "string" or #s > 2000 then return nil end
    local payload, sig = s:match("^([%w%-_]+)%.([%w%-_]+)$")
    if not payload or mac(payload) ~= sig then return nil end
    local pad = payload:gsub("-", "+"):gsub("_", "/")
    local t = cjson.decode(ngx.decode_base64(pad .. string.rep("=", (4 - #pad % 4) % 4)) or "")
    if type(t) ~= "table" or type(t.exp) ~= "number" or t.exp < ngx.time() then return nil end
    return t
end

--- The OAuth address that brings the person back to the dashboard with a code.
function G.authorize_url(c, state, redirect_uri)
    return c.web_url .. "/login/oauth/authorize?client_id=" .. ngx.escape_uri(c.client_id) .. "&redirect_uri="
        .. ngx.escape_uri(redirect_uri) .. "&state=" .. ngx.escape_uri(state)
end

--- The installation as the person who came back with `code` sees it, or nil + why. Proves they can reach it.
function G.verify_installation(c, code, redirect_uri, installation_id)
    local data, _, err = request("POST", c.web_url .. "/login/oauth/access_token", { Accept = "application/json" },
        { client_id = c.client_id, client_secret = c.client_secret, code = code, redirect_uri = redirect_uri })
    if not data then return nil, err end
    if type(data.access_token) ~= "string" then
        return nil, "GitHub didn't accept the sign-in (" .. tostring(data.error or "no token") .. "); try again"
    end
    for page = 1, 10 do
        local list, _, lerr = request("GET", c.api_url .. "/user/installations?per_page=100&page=" .. page,
            { Authorization = "Bearer " .. data.access_token })
        if not list then return nil, lerr end
        for _, i in ipairs(type(list.installations) == "table" and list.installations or {}) do
            if type(i) == "table" and tostring(i.id) == tostring(installation_id) then
                local account = type(i.account) == "table" and i.account or {}
                return { installation_id = i.id, account_login = account.login, account_type = account.type,
                    repository_selection = i.repository_selection }
            end
        end
        if #(list.installations or {}) < 100 then break end
    end
    return nil, "your GitHub account can't reach that installation"
end

-- ---------------------------------------------------------------------------
-- One repository, with an installation token (the run's)
-- ---------------------------------------------------------------------------

local Repo = {}
Repo.__index = Repo

--- A client for owner/name: { c, full_name, token }.
function G.repo(c, full_name, token)
    return setmetatable({ c = c, full_name = full_name, token = token }, Repo)
end

function Repo:call(method, path, body, accept)
    return request(method, self.c.api_url .. "/repos/" .. self.full_name .. path,
        { Authorization = "Bearer " .. self.token, Accept = accept }, body)
end

function Repo:info()
    return self:call("GET", "")
end

--- The commit a branch points at, or nil (404: no such branch) / nil, err.
function Repo:branch_sha(branch)
    local data, status, err = self:call("GET", "/git/ref/heads/" .. G.path(branch))
    if not data then
        if status == 404 then return nil end
        return nil, err
    end
    return type(data.object) == "table" and data.object.sha or nil
end

function Repo:create_branch(branch, sha)
    return self:call("POST", "/git/refs", { ref = "refs/heads/" .. branch, sha = sha })
end

--- Every file path in the tree of a commit (up to GitHub's limit; `truncated` says it was cut).
function Repo:tree(sha)
    return self:call("GET", "/git/trees/" .. G.path(sha) .. "?recursive=1")
end

--- A file's text and blob sha at a ref, or nil, status, err (404: no such file).
function Repo:file(path, ref)
    local data, status, err = self:call("GET", "/contents/" .. G.path(path) .. "?ref=" .. ngx.escape_uri(ref))
    if not data then return nil, status, err end
    if data.type ~= "file" then return nil, 400, path .. " is not a file" end
    if data.encoding ~= "base64" or type(data.content) ~= "string" then
        return nil, 413, path .. " is too large to read through the API"
    end
    return { text = ngx.decode_base64((data.content:gsub("%s", ""))) or "", sha = data.sha, size = data.size }
end

--- Create or update one file on a branch: one commit. sha = the blob being replaced (nil for a new file).
function Repo:put_file(path, text, message, branch, sha)
    return self:call("PUT", "/contents/" .. G.path(path), { message = message, content = ngx.encode_base64(text),
        branch = branch, sha = sha })
end

--- Code search (GitHub searches the default branch). @return { total, items = { { path, fragments } } }
function Repo:search(query)
    local data, _, err = request("GET", self.c.api_url .. "/search/code?per_page=20&q="
        .. ngx.escape_uri(query .. " repo:" .. self.full_name),
        { Authorization = "Bearer " .. self.token, Accept = "application/vnd.github.text-match+json" })
    if not data then return nil, err end
    local items = {}
    for _, i in ipairs(type(data.items) == "table" and data.items or {}) do
        local frags = {}
        for _, m in ipairs(type(i.text_matches) == "table" and i.text_matches or {}) do
            if type(m.fragment) == "string" then frags[#frags + 1] = m.fragment:sub(1, 300) end
        end
        items[#items + 1] = { path = i.path, fragments = frags }
    end
    return { total = data.total_count, items = items }
end

--- Open a pull request; when one is already open for the branch, that one. @return html_url | nil, err
function Repo:pull_request(head, base, title, body, draft)
    local data, status, err = self:call("POST", "/pulls", { title = title, head = head, base = base, body = body,
        draft = draft == true })
    if data then return data.html_url end
    if status == 422 then
        local owner = self.full_name:match("^([^/]+)/")
        local list = self:call("GET", "/pulls?state=open&head=" .. ngx.escape_uri(owner .. ":" .. head))
        if type(list) == "table" and type(list[1]) == "table" then return list[1].html_url end
    end
    return nil, err
end

return G
