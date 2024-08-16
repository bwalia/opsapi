local roles = {}
local cjson = require "cjson"
local helper = require "helper-functions"
local connection = require "connection"

function roles.create(payloads)
    local DB = connection.connectPgsql()
    local uuid = helper.generate_uuid()

    local insertQuery = string.format(
        "INSERT INTO roles (uuid, role_name, description, workspace) VALUES ('%s', '%s', '%s')",
        uuid, payloads.role_name, payloads.description, payloads.workspace
    )
    local result, err = DB:query(insertQuery)
    if not result then
        return ngx.say(cjson.encode({
            data = {
                message = "Error executing SQL query while inserting into Roles",
                error = err
            },
            status = 500
        }))
    end
    return ngx.say(cjson.encode({
        data = {
            message = string.format("New Role '%s' has been created!", payloads.role_name),
        },
        status = 200
    }))
end

function roles.show(uuid)
    local DB = connection.connectPgsql()
    local selectQuery = string.format("SELECT * FROM roles WHERE uuid = '%s'", uuid)
    local response, err = DB:query(selectQuery)
    if not response then
        return ngx.say(cjson.encode({
            data = {
                message = "Error executing SQL query while getting results from roles",
                error = err
            },
            status = 500
        }))
    end
    return ngx.say(cjson.encode({
        data = response,
        status = 200
    }))
end

function roles.list()
    
end

return roles
