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

function pgTables.create(args)
    local DB = connection.connectPgsql()
    if DB then
        local tableName = args.table
        local tableFile = "/opt/nginx/data/migrations/" .. os.time() .. "-create_table_" .. tableName .. ".json"
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
                    local migrationQuery = "CREATE TABLE IF NOT EXISTS migrations"
                        .. " (id SERIAL PRIMARY KEY, name VARCHAR(255) NOT NULL, created_at TIMESTAMP NOT NULL);"
                    local migRes, migErr = DB:query(migrationQuery)
                    if not migRes then
                        ngx.say("Error executing SQL query: ", migErr)
                        ngx.exit(500)
                    end
                    local fileName = os.time() .. "-create_table_" .. tableName .. ".json"
                    local insertQuery = "INSERT INTO migrations (name, created_at) VALUES ('" .. fileName .. "', NOW());"
                    local insertRes, insertErr = DB:query(insertQuery)
                    if not insertRes then
                        ngx.say("Error executing SQL query: ", insertErr)
                        ngx.exit(500)
                    end
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

function pgTables.alter(args, table)
    local DB = connection.connectPgsql()
    if DB then
        local tableName = args.table
        local tableFile = "/opt/nginx/data/migrations/" .. os.time() .. "-alter_table_" .. table .. ".json"
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
                    local fileName = os.time() .. "-alter_table_" .. table .. ".json"
                    local insertQuery = "INSERT INTO migrations (name, created_at) VALUES ('" .. fileName .. "', NOW());"
                    local insertRes, insertErr = DB:query(insertQuery)
                    if not insertRes then
                        ngx.say("Error executing SQL query: ", insertErr)
                        ngx.exit(500)
                    end

                    ngx.say("Table has been altered!")
                    ngx.exit(ngx.HTTP_OK)
                end
            end
        end
    end
end

function pgTables.drop(args)
    local DB = connection.connectPgsql()
    if DB then
        for _i, table in ipairs(args.tables) do
            local tableFile = "/opt/nginx/data/migrations/delete_table_" .. table.name .. ".json"
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
                    local createQuery = "DROP TABLE IF EXISTS " .. table.name
                    local res, err = DB:query(createQuery)
                    if not res then
                        ngx.say("Error executing SQL query: ", err)
                        ngx.exit(500)
                    end
                end
            end
        end
        ngx.say("Table has been deleted!")
        ngx.exit(ngx.HTTP_OK)
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
    for i, file in ipairs(unMigratedFiles) do
        local filePath = "/opt/nginx/data/migrations/" .. file
        local migrationFile = read_file(filePath)
        local isCreate = contains(file, "create_table")
        local payloads = cjson.decode(migrationFile)
        local table = payloads.table
        if isCreate then
            pgTables.create(payloads)
        else
            pgTables.alter(payloads, table)
        end
    end
end

return pgTables
