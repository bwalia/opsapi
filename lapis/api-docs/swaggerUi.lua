local db = require("lapis.db")
local cjson = require "cjson"

local SwaggerUi = {}

local function firstToUpper(str)
    return (str:gsub("^%l", string.upper))
end

-- Define JWT security schema
local jwtSecurity = {
    type = "http",
    scheme = "bearer",
    bearerFormat = "JWT",
    description = "JWT Authorization header using the Bearer scheme. Example: 'Authorization: Bearer {token}'"
}

-- Check whether a field should be included
local function isIncludable(column)
    local skip = {
        uuid = true,
        id = true,
        created_at = true,
        updated_at = true,
        module_id = true
    }
    return not skip[column]
end

function SwaggerUi.generate()
    local res = db.query([[
    SELECT table_name, column_name, data_type
    FROM information_schema.columns
    WHERE table_schema = 'public'
    ORDER BY table_name, ordinal_position;
  ]])

    if not res then
        ngx.log(ngx.ERR, "Failed to query database.")
        ngx.exit(500)
    end

    local swagger = {
        openapi = "3.0.0",
        info = {
            title = "API Documentation",
            version = "1.0",
            description = "Generated from database schema"
        },
        components = {
            securitySchemes = {
                BearerAuth = jwtSecurity
            }
        },
        security = {
            { BearerAuth = {} }
        },
        paths = {}
    }

    -- Add extra fields manually
    table.insert(res, 1, { column_name = "role", table_name = "users", data_type = "character varying" })
    table.insert(res, 1, { column_name = "role", table_name = "permissions", data_type = "character varying" })
    table.insert(res, 1,
        { column_name = "module_machine_name", table_name = "permissions", data_type = "character varying" })

    for _, row in ipairs(res) do
        local table_name, column_name, data_type = row.table_name, row.column_name, row.data_type
        if not table_name:find("__") and not table_name:find("pg_stat_") and table_name ~= "lapis_migrations" then
            local basePath = "/api/v2/" .. table_name
            local itemPath = basePath .. "/{uuid}"

            -- Ensure base route exists
            if not swagger.paths[basePath] then
                swagger.paths[basePath] = {
                    get = {
                        tags = { firstToUpper(table_name) },
                        summary = "Get all " .. table_name,
                        security = { { BearerAuth = {} } },
                        responses = {
                            ["200"] = {
                                description = "Successful operation",
                                content = {
                                    ["multipart/form-data"] = {
                                        schema = {
                                            type = "array",
                                            items = {
                                                type = "object",
                                                properties = {}
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        parameters = {
                            { name = "page",     ["in"] = "query", schema = { type = "number" }, required = false },
                            { name = "perPage",  ["in"] = "query", schema = { type = "number" }, required = false },
                            { name = "orderBy",  ["in"] = "query", schema = { type = "string" }, required = false },
                            { name = "orderDir", ["in"] = "query", schema = { type = "string" }, required = false },
                        }
                    },
                    post = {
                        tags = { firstToUpper(table_name) },
                        summary = "Create a new " .. table_name,
                        security = { { BearerAuth = {} } },
                        requestBody = {
                            required = true,
                            content = {
                                ["multipart/form-data"] = {
                                    schema = {
                                        type = "object",
                                        properties = {}
                                    }
                                }
                            }
                        },
                        responses = {
                            ["201"] = {
                                description = table_name .. " created successfully"
                            }
                        }
                    }
                }
            end

            local propType = (data_type == "int" or data_type == "bigint") and "integer" or "string"
            swagger.paths[basePath].get.responses["200"].content["multipart/form-data"].schema.items.properties[column_name] = {
                type = propType,
                description = "Description of " .. column_name,
                example = "Example value"
            }
            if isIncludable(column_name) then
                swagger.paths[basePath].post.requestBody.content["multipart/form-data"].schema.properties[column_name] = {
                    type = propType,
                    description = "Description of " .. column_name,
                    example = "Example value"
                }
            end

            -- Ensure item path exists
            if not swagger.paths[itemPath] then
                swagger.paths[itemPath] = {
                    get = {
                        tags = { firstToUpper(table_name) },
                        summary = "Get one " .. table_name,
                        security = { { BearerAuth = {} } },
                        parameters = {
                            { name = "uuid", ["in"] = "path", required = true, schema = { type = "string" }, description = "UUID" }
                        },
                        responses = {
                            ["200"] = {
                                description = "Success",
                                content = {
                                    ["multipart/form-data"] = {
                                        schema = {
                                            type = "array",
                                            items = {
                                                type = "object",
                                                properties = {}
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    },
                    delete = {
                        tags = { firstToUpper(table_name) },
                        summary = "Delete " .. table_name,
                        security = { { BearerAuth = {} } },
                        parameters = {
                            { name = "uuid", ["in"] = "path", required = true, schema = { type = "string" } }
                        },
                        responses = {
                            ["204"] = { description = "Deleted successfully" }
                        }
                    },
                    put = {
                        tags = { firstToUpper(table_name) },
                        summary = "Update " .. table_name,
                        security = { { BearerAuth = {} } },
                        parameters = {
                            { name = "uuid", ["in"] = "path", required = true, schema = { type = "string" } }
                        },
                        requestBody = {
                            required = true,
                            content = {
                                ["multipart/form-data"] = {
                                    schema = {
                                        type = "object",
                                        properties = {}
                                    }
                                }
                            }
                        },
                        responses = {
                            ["201"] = {
                                description = table_name .. " updated successfully"
                            }
                        }
                    }
                }
            end

            swagger.paths[itemPath].get.responses["200"].content["multipart/form-data"].schema.items.properties[column_name] = {
                type = propType,
                description = "Description of " .. column_name,
                example = "Example value"
            }
            if isIncludable(column_name) then
                swagger.paths[itemPath].put.requestBody.content["multipart/form-data"].schema.properties[column_name] = {
                    type = propType,
                    description = "Description of " .. column_name,
                    example = "Example value"
                }
            end
        end
    end

    local swagger_json = cjson.encode(swagger)

    local file = io.open("/tmp/swagger.json", "w")
    if file then
        file:write(swagger_json)
        file:close()
    else
        ngx.log(ngx.ERR, "Failed to write Swagger JSON file.")
    end
end

return SwaggerUi
