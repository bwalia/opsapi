local connection = require "connection"
local cjson = require "cjson"
local helper = require "helper-functions"

local msTables = {}

function msTables.create(args, isMigration)
    local DB = connection.connectMysql()
    if DB then
        local tableName = args.table
        local isDir, tableFile, timestamp = false, "", os.time()
        if not isMigration then
            tableFile = "/opt/nginx/data/migrations/msql/" .. timestamp .. "-create_table_" .. tableName .. ".json"
            isDir = helper.create_directory_if_not_exists("/opt/nginx/data/migrations/msql")
        end
        if isDir or isMigration then
            local file, fileErr = false, ""
            if isDir then
                file, fileErr = io.open(tableFile, "w")
                if fileErr then
                    return ngx.say(cjson.encode({
                        data = {
                            message = "Something wrong while opening the migration file",
                            error = fileErr
                        },
                        status = 500
                    }))
                end
            end
            if file or isMigration then
                if file then
                    file:write(cjson.encode(args))
                    file:close()
                end
                local createQuery = string.format("CREATE TABLE IF NOT EXISTS %s (", tableName)
                for i, column in ipairs(args.columns) do
                    createQuery = createQuery .. column.name .. " " .. (column.primary ~= true and column.type or "")
                    if column.default ~= "" then
                        createQuery = createQuery .. " DEFAULT " .. column.default
                    end
                    if column.auto_increment then
                        createQuery = createQuery .. " AUTO_INCREMENT"
                    end
                    if column.primary then
                        createQuery = createQuery .. " PRIMARY KEY (" .. column.name .. ")"
                    end
                    if column.unique then
                        createQuery = createQuery .. " UNIQUE (" .. column.name .. ")"
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
                    return ngx.say(cjson.encode({
                        data = {
                            message = "Error executing SQL query while creating table " .. tableName,
                            error = err
                        },
                        status = 500
                    }))
                else
                    local migrationQuery = "CREATE TABLE IF NOT EXISTS migrations"
                        .. " (id SERIAL PRIMARY KEY, name VARCHAR(255) NOT NULL, created_at TIMESTAMP NOT NULL);"
                    local migRes, migErr = DB:query(migrationQuery)
                    if not migRes then
                        return ngx.say(cjson.encode({
                            data = {
                                message = "Error executing SQL query while creating table migrations",
                                error = migErr
                            },
                            status = 500
                        }))
                    end
                    local fileName = isMigration and isMigration or timestamp .. "-create_table_" .. tableName .. ".json"
                    local insertQuery = "INSERT INTO migrations (name, created_at) VALUES ('" .. fileName .. "', NOW());"
                    local insertRes, insertErr = DB:query(insertQuery)
                    if not insertRes then
                        return ngx.say(cjson.encode({
                            data = {
                                message = "Error executing SQL query while inserting into migrations",
                                error = insertErr
                            },
                            status = 500
                        }))
                    end
                    return ngx.say(cjson.encode({
                        data = {
                            message = "Table created successfully!",
                        },
                        status = 200
                    }))
                end
            end
        else
            return ngx.say(cjson.encode({
                data = {
                    message = "Table Migration already exists!",
                },
                status = 500
            }))
        end
    else
        return ngx.say(cjson.encode({
            data = {
                message = "Failed to open file for writing.",
            },
            status = 500
        }))
    end
end

function msTables.alter(args, table, isMigration)
    local DB = connection.connectMysql()
    if DB then
        local tableName, isDir, tableFile, timestamp = args.table, false, "", os.time()
        if not isMigration then
            tableFile = "/opt/nginx/data/migrations/msql/" .. timestamp .. "-alter_table_" .. table .. ".json"
            isDir = helper.create_directory_if_not_exists("/opt/nginx/data/migrations/msql")
        end
        if isDir or isMigration then
            local file, fileErr = false, ""
            if isDir then
                file, fileErr = io.open(tableFile, "w")
                if fileErr then
                    return ngx.say(cjson.encode({
                        data = {
                            message = "Something wrong while opening the migration file",
                            error = fileErr
                        },
                        status = 500
                    }))
                end
            end
            if file or isMigration then
                if file then
                    file:write(cjson.encode(args))
                    file:close()
                end
                local createQuery = string.format("ALTER TABLE %s ", tableName)
                if args.clause == "add" then
                    for i, column in ipairs(args.columns) do
                        createQuery = createQuery ..
                            "ADD COLUMN " .. column.name .. " " .. (column.primary ~= true and column.type or "")
                        if column.default ~= "" then
                            createQuery = createQuery .. " DEFAULT " .. column.default
                        end
                        if column.auto_increment then
                            createQuery = createQuery .. " AUTO_INCREMENT"
                        end
                        if column.primary then
                            createQuery = createQuery .. " PRIMARY KEY (" .. column.name .. ")"
                        end
                        if column.unique then
                            createQuery = createQuery .. " UNIQUE (" .. column.name .. ")"
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
                        createQuery = createQuery .. "MODIFY COLUMN " .. column.name
                        if column.type then
                            createQuery = createQuery .. " " .. column.type
                        end
                        if column.default ~= "" then
                            createQuery = createQuery .. ", MODIFY COLUMN " .. column.name
                            createQuery = createQuery .. " DEFAULT " .. column.default
                        end
                        if column.auto_increment then
                            createQuery = createQuery .. " AUTO_INCREMENT"
                        end
                        if column.primary then
                            createQuery = createQuery .. ", MODIFY COLUMN " .. column.name
                            createQuery = createQuery .. " ADD PRIMARY KEY (" .. column.name .. ")"
                        end
                        if column.unique then
                            createQuery = createQuery .. ", MODIFY COLUMN " .. column.name
                            createQuery = createQuery .. " ADD UNIQUE (" .. column.name .. ")"
                        end
                        if column.not_null then
                            createQuery = createQuery .. ", MODIFY COLUMN " .. column.name
                            createQuery = createQuery .. " NOT NULL"
                        end
                        if i < #args.columns then
                            createQuery = createQuery .. ", "
                        end
                    end
                end
                local res, err = DB:query(createQuery)
                if not res then
                    ngx.say(cjson.encode({
                        data = {
                            message = "Error executing SQL query while altering table " .. tableName,
                            error = err
                        },
                        status = 500
                    }))
                else
                    local fileName = isMigration and isMigration or timestamp .. "-alter_table_" .. table .. ".json"
                    local insertQuery = "INSERT INTO migrations (name, created_at) VALUES ('" .. fileName .. "', NOW());"
                    local insertRes, insertErr = DB:query(insertQuery)
                    if not insertRes then
                        ngx.say(cjson.encode({
                            data = {
                                message = "Error executing SQL query while inserting into migration",
                                error = insertErr
                            },
                            status = 500
                        }))
                    end
                    return ngx.say(cjson.encode({
                        data = {
                            message = "Table has been altered!",
                        },
                        status = 200
                    }))
                end
            end
        end
    end
end

function msTables.drop(args, isMigration)
    local DB = connection.connectMysql()
    if DB then
        for _i, table in ipairs(args.tables) do
            local tableFile, isDir = "", false
            if not isMigration then
                tableFile = "/opt/nginx/data/migrations/msql/" .. os.time() .. "-delete_table_" .. table.name .. ".json"
                isDir = helper.create_directory_if_not_exists("/opt/nginx/data/migrations/msql")
            end
            if isDir or isMigration then
                local file, fileErr = false, ""
                if isDir then
                    file, fileErr = io.open(tableFile, "w")
                    if fileErr then
                        return ngx.say(cjson.encode({
                            data = {
                                message = "Something wrong while opening the migration file",
                                error = fileErr
                            },
                            status = 500
                        }))
                    end
                end
                if file or isMigration then
                    if file then
                        file:write(cjson.encode(args))
                        file:close()
                    end
                    local createQuery = "DROP TABLE IF EXISTS " .. table.name
                    local res, err = DB:query(createQuery)
                    if not res then
                        return ngx.say(cjson.encode({
                            data = {
                                message = "Error executing SQL query while deleting table " .. table.name,
                                error = err
                            },
                            status = 500
                        }))
                    end
                end
            end
        end
        return ngx.say(cjson.encode({
            data = {
                message = "Table has been deleted!",
            },
            status = 200
        }))
    end
end

function msTables.migrate()
    local DB = connection.connectMysql()
    if DB then
        local directory = "/opt/nginx/data/migrations/msql"
        local files = helper.get_files_in_directory(directory)
        local unMigrated = {}
        for _i, migration in ipairs(files) do
            local query = string.format("SELECT id, name FROM migrations WHERE name='%s'", migration)
            local res, err, num = DB:query(query)
            if not res then
                ngx.say("Error executing SQL query: ", err)
                ngx.exit(500)
            end
            if next(res) == nil then
                table.insert(unMigrated, migration)
            end
        end
        local unMigratedFiles = helper.sort_files_by_timestamp(unMigrated)
        local response = {}
        for i, file in ipairs(unMigratedFiles) do
            local filePath = "/opt/nginx/data/migrations/msql/" .. file
            local migrationFile = helper.read_file(filePath)
            local isCreate = helper.contains(file, "create_table")
            local isAlter = helper.contains(file, "alter_table")
            local isDelete = helper.contains(file, "delete_table")
            local payloads = cjson.decode(migrationFile)
            local table = payloads.table
            if isCreate then
                response = msTables.create(payloads, file)
            elseif isAlter then
                response = msTables.alter(payloads, table, file)
            elseif isDelete then
                response = msTables.drop(payloads, file)
            end
    
        end
        ngx.say(response)
    else
        ngx.say(cjson.encode({
            data = {
                message = "Error connecting to database"
            },
            status = 500
        }))
    end
end

return msTables
