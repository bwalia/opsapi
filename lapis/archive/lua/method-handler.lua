local pgTables = require "pg-tables"
local msTables = require "ms-tables"
local helper = require "helper-functions"
local roles = require "api.roles"

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
    if path == "/mysql/migrate" then
        msTables.migrate()
    end
    if helper.contains(path, "/roles/") then
        roles.show(uuid)
    end
end

local function handle_post_request(args, path)
    local postData = helper.GetPayloads(args)
    local pattern = ".*/.*/.*/(.*)"
    local pathSegment = string.match(path, pattern)

    if path == "/pgsql/create/table" then
        pgTables.create(postData, false)
    end
    if path == "/mysql/create/table" then
        msTables.create(postData, false)
    end
    if path == "/roles" then
        roles.create(postData)
    end
end

local function handle_put_request(args, path)
    local pattern = ".*/.*/.*/(.*)"
    local pathSegment = string.match(path, pattern)
    local postData = helper.GetPayloads(args)
    if string.find(path, "/pgsql/alter/table", 1, true) then
        pgTables.alter(postData, pathSegment, false)
    end
    if string.find(path, "/mysql/alter/table", 1, true) then
        msTables.alter(postData, pathSegment, false)
    end
end

local function handle_delete_request(args, path)
    local postData = helper.GetPayloads(args)
    if path == "/pgsql/drop/table" then
        pgTables.drop(postData)
    end
    if path == "/mysql/drop/table" then
        msTables.drop(postData)
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