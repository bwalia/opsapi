local cjson = require "cjson"
local pgTables = require "pg-tables"

local function GetPayloads(body)
    local keyset = {}
    local n = 0
    for k, v in pairs(body) do
        n = n + 1
        if type(v) == "string" then
            if v ~= nil and v ~= "" then
                table.insert(keyset, cjson.decode(k .. v))
            end
        else
            table.insert(keyset, cjson.decode(k))
        end
    end
    return keyset[1]
end

local function handle_get_request(args, path)
    local delimiter = "/"
    local subPath = {}
    for substring in string.gmatch(path, "[^" .. delimiter .. "]+") do
        table.insert(subPath, substring)
    end
    local pattern = ".*/(.*)"
    local uuid = string.match(path, pattern)

    if path == "/pgsql/migrate" then
        pgTables.migrate()
    end
end

local function handle_post_request(args, path)
    local postData = GetPayloads(args)
    local pattern = ".*/.*/.*/(.*)"
    local pathSegment = string.match(path, pattern)
    if path == "/pgsql/create/table" then
        pgTables.create(postData)
    end
end

local function handle_put_request(args, path)
    local pattern = ".*/.*/.*/(.*)"
    local pathSegment = string.match(path, pattern)
    local postData = GetPayloads(args)
    if string.find(path, "/pgsql/alter/table", 1, true) then
        pgTables.alter(postData, pathSegment)
    end
end

local function handle_delete_request(args, path)
    local postData = GetPayloads(args)
    if path == "/pgsql/drop/table" then
        pgTables.drop(postData)
    end
end

local path = ngx.var.uri:match("^/opsapi/v1(.*)$")

if ngx.req.get_method() == "GET" then
    handle_get_request(ngx.req.get_uri_args(), path)
elseif ngx.req.get_method() == "POST" then
    ngx.req.read_body()
    handle_post_request(ngx.req.get_post_args(), path)
elseif ngx.req.get_method() == "PUT" then
    ngx.req.read_body()
    handle_put_request(ngx.req.get_post_args(), path)
elseif ngx.req.get_method() == "DELETE" then
    ngx.req.read_body()
    handle_delete_request(ngx.req.get_post_args(), path)
else
    ngx.exit(ngx.HTTP_NOT_ALLOWED)
end