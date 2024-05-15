local connection = require "connection"
local cjson = require "cjson"
local lfs = require "lfs"

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

local function get_files_in_directory(directory)
    local files = {}
    for file in lfs.dir(directory) do
        if file ~= "." and file ~= ".." then
            table.insert(files, file)
        end
    end
    return files
end

local function sort_files_by_timestamp(files)
    table.sort(files)
    return files
end

local function read_file(file_path)
    local file = io.open(file_path, "r")
    if not file then
        return nil, "Cannot open file: " .. file_path
    end
    local content = file:read("*all")
    file:close()
    return content
end

local function contains(str, substr)
    if #substr == 0 then return true end
    return string.find(str, substr, 1, true) ~= nil
end

function pgTables.create(args, isMigration)
    local DB = connection.connectPgsql()
    if DB then
        local tableName = args.table
        local isDir, tableFile, timestamp = false, "", os.time()
        if not isMigration then
            tableFile = "/opt/nginx/data/migrations/" .. timestamp .. "-create_table_" .. tableName .. ".json"
            isDir = create_directory_if_not_exists("/opt/nginx/data/migrations")
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

function pgTables.alter(args, table, isMigration)
    local DB = connection.connectPgsql()
    if DB then
        local tableName, isDir, tableFile, timestamp = args.table, false, "", os.time()
        if not isMigration then
            tableFile = "/opt/nginx/data/migrations/" .. timestamp .. "-alter_table_" .. table .. ".json"
            isDir = create_directory_if_not_exists("/opt/nginx/data/migrations")
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

function pgTables.drop(args, isMigration)
    local DB = connection.connectPgsql()
    if DB then
        for _i, table in ipairs(args.tables) do
            local tableFile, isDir = "", false
            if not isMigration then
                tableFile = "/opt/nginx/data/migrations/" .. os.time() .. "-delete_table_" .. table.name .. ".json"
                isDir = create_directory_if_not_exists("/opt/nginx/data/migrations")
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

function pgTables.migrate()
    local DB = connection.connectPgsql()
    local directory = "/opt/nginx/data/migrations"
    local files = get_files_in_directory(directory)
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
    local unMigratedFiles = sort_files_by_timestamp(unMigrated)
    local response = {}
    for i, file in ipairs(unMigratedFiles) do
        local filePath = "/opt/nginx/data/migrations/" .. file
        local migrationFile = read_file(filePath)
        local isCreate = contains(file, "create_table")
        local isAlter = contains(file, "alter_table")
        local isDelete = contains(file, "delete_table")
        local payloads = cjson.decode(migrationFile)
        local table = payloads.table
        if isCreate then
            response = pgTables.create(payloads, file)
        elseif isAlter then
            response = pgTables.alter(payloads, table, file)
        elseif isDelete then
            response = pgTables.drop(payloads, file)
        end

    end
    ngx.say(response)
end

return pgTables
