local connection = require "connection"
local cjson = require "cjson"

local pgTables = {}

local function create_directory_if_not_exists(directory)
    local command = string.format("mkdir -p %s", directory)
    local status = os.execute(command)
    if status then
        return true
    else
        return false
    end
end

local function file_exists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    else
        return false
    end
end

function pgTables.create(args)
    local DB = connection.connectPgsql()
    if DB then
        local tableName = args.table
        local tableFile = "/opt/nginx/data/migrations/create_table_" .. tableName .. ".json"
        local isDir = create_directory_if_not_exists("/opt/nginx/data/migrations")
        if isDir then
            if not file_exists(tableFile) then
                local file, fileErr = io.open(tableFile, "w")
                if fileErr then
                    ngx.log(ngx.ERR, fileErr)
                    ngx.exit(500)
                end
                if file then
                    file:write(cjson.encode(args))
                    file:close()
                    local createQuery = string.format("CREATE TABLE IF NOT EXISTS %s (", tableName)
                    for i, column in ipairs(args.columns) do
                        createQuery = createQuery .. column.name .. " " .. (column.primary ~= true and column.type or "")
                        if column.default ~= "" then
                            createQuery = createQuery .. " DEFAULT " .. column.default
                        end
                        if column.auto_increment then
                            createQuery = createQuery .. " SERIAL"
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
                        if i < #args.columns then
                            createQuery = createQuery .. ", "
                        end
                    end
                    createQuery = createQuery .. ");"

                    local res, err = DB:query(createQuery)
                    if not res then
                        ngx.say("Error executing SQL query: ", err)
                        ngx.exit(500)
                    else
                        ngx.say("Table created successfully")
                        ngx.exit(ngx.HTTP_OK)
                    end
                end
            else
                ngx.say("Table Migration already exists!")
                ngx.exit(ngx.HTTP_BAD_GATEWAY)
            end
        else
            ngx.log(ngx.ERR, "Failed to open file for writing.")
        end
    end
end

function pgTables.alter(args, table)
    local DB = connection.connectPgsql()
    if DB then
        local tableName = args.table
        local tableFile = "/opt/nginx/data/migrations/alter_table_" .. table .. "_" .. os.time() + os.clock() .. ".json"
        local isDir = create_directory_if_not_exists("/opt/nginx/data/migrations")
        if isDir then
            local file, fileErr = io.open(tableFile, "w")
            if fileErr then
                ngx.log(ngx.ERR, fileErr)
                ngx.exit(500)
            end
            if file then
                file:write(cjson.encode(args))
                file:close()
                local createQuery = string.format("ALTER TABLE %s ", tableName)
                if args.clause == "add" then
                    for i, column in ipairs(args.columns) do
                        createQuery = createQuery ..
                            "ADD COLUMN " .. column.name .. " " .. (column.primary ~= true and column.type or "")
                        if column.default ~= "" then
                            createQuery = createQuery .. " DEFAULT " .. column.default
                        end
                        if column.auto_increment then
                            createQuery = createQuery .. " SERIAL"
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
                        if i < #args.columns then
                            createQuery = createQuery .. ", "
                        end
                    end
                end
                if args.clause == "drop" then
                    for i, column in ipairs(args.columns) do
                        createQuery = createQuery .. "DROP COLUMN " .. column.name
                        if i < #args.columns then
                            createQuery = createQuery .. ", "
                        end
                    end
                end
                if args.clause == "rename" then
                    for i, column in ipairs(args.columns) do
                        createQuery = createQuery .. "RENAME COLUMN " .. column.name .. " TO " .. column.new_name
                        if i < #args.columns then
                            createQuery = createQuery .. ", "
                        end
                    end
                end
                if args.clause == "alter_column" then
                    for i, column in ipairs(args.columns) do
                        createQuery = createQuery .. "ALTER COLUMN " .. column.name
                        if column.type then
                            createQuery = createQuery .. " SET DATA TYPE " .. column.type
                        end
                        if column.default ~= "" then
                            createQuery = createQuery .. ", ALTER COLUMN " .. column.name
                            createQuery = createQuery .. " SET DEFAULT " .. column.default
                        end
                        if column.auto_increment then
                            createQuery = createQuery .. " SERIAL"
                        end
                        if column.primary then
                            createQuery = createQuery .. ", ALTER COLUMN " .. column.name
                            createQuery = createQuery .. " ADD PRIMARY KEY (" .. column.name .. ")"
                        end
                        if column.unique then
                            createQuery = createQuery .. ", ALTER COLUMN " .. column.name
                            createQuery = createQuery .. " ADD UNIQUE (" .. column.name .. ")"
                        end
                        if column.not_null then
                            createQuery = createQuery .. ", ALTER COLUMN " .. column.name
                            createQuery = createQuery .. " SET NOT NULL"
                        end
                        if column.not_null == false then
                            createQuery = createQuery .. ", ALTER COLUMN " .. column.name
                            createQuery = createQuery .. " DROP NOT NULL"
                        end
                        if i < #args.columns then
                            createQuery = createQuery .. ", "
                        end
                    end
                end
                local res, err = DB:query(createQuery)
                if not res then
                    ngx.say("Error executing SQL query: ", err)
                    ngx.exit(500)
                else
                    ngx.say("Table has been altered!")
                    ngx.exit(ngx.HTTP_OK)
                end
            end
        end
    end
end

function pgTables.drop(args, table)
    local DB = connection.connectPgsql()
    ngx.say(args)
    ngx.exit(200)
    if DB then
        local tableFile = "/opt/nginx/data/migrations/delete_table_" .. table .. ".json"
        local isDir = create_directory_if_not_exists("/opt/nginx/data/migrations")
        if isDir then
            local file, fileErr = io.open(tableFile, "w")
            if fileErr then
                ngx.say(fileErr)
                ngx.exit(500)
            end
            if file then
                file:write(cjson.encode(args))
                file:close()
                local createQuery = ""
                for i, tableName in ipairs(args.tables) do
                    createQuery = "DROP TABLE IF EXISTS " .. tableName.name
                    if i < #args.tables then
                        createQuery = createQuery .. ", " .. tableName.name
                    end
                end
                local res, err = DB:query(createQuery)
                if not res then
                    ngx.say("Error executing SQL query: ", err)
                    ngx.exit(500)
                else
                    ngx.say("Table has been altered!")
                    ngx.exit(ngx.HTTP_OK)
                end
            end
        end
    end
end

return pgTables
