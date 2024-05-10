local connection = require "connection"
local cjson = require "cjson"

local tables = {}

local function create_directory_if_not_exists(directory)
    local command = string.format("mkdir -p %s", directory)
    local status = os.execute(command)
    if status then
        return true
    else
        return false
    end
end

function tables.create(args)
    local DB = connection.connectPgsql()
    if DB then
        local tableName = args.table
        local tableFile = "/opt/nginx/data/migrations/" .. tableName .. "_" .. os.time() + os.clock() .. ".json"
        local isDir = create_directory_if_not_exists("/opt/nginx/data/migrations")
        if not isDir then
            local file, fileErr = io.open(tableFile, "w")
            if fileErr then
                ngx.log(ngx.ERR, fileErr)
                ngx.exit(500)
            end
            if file then
                file:write(cjson.encode(args))
                file:close()
                ngx.say(cjson.encode(tableFile))
                ngx.exit(ngx.HTTP_OK)
                local createQuery = string.format("CREATE TABLE IF NOT EXISTS %s (", tableName)
                for i, column in ipairs(args.columns) do
                    createQuery = createQuery .. column.name .. " " .. column.type
                    if column.default ~= "" then
                        createQuery = createQuery .. " DEFAULT " .. column.default
                    end
                    if column.primary then
                        createQuery = createQuery .. " PRIMARY KEY"
                    end
                    if column.unique then
                        createQuery = createQuery .. " UNIQUE"
                    end
                    if column.not_null then
                        createQuery = createQuery .. " NOT NULL"
                    end
                    if column.auto_increment then
                        createQuery = createQuery .. " SERIAL"
                    end
                    if i < #args.columns then
                        createQuery = createQuery .. ", "
                    end
                end
                createQuery = createQuery .. ")"

                ngx.say(cjson.encode(createQuery))
                ngx.exit(ngx.HTTP_OK)
            end
        else
            ngx.log(ngx.ERR, "Failed to open file for writing.")
        end
    end
end

return tables
