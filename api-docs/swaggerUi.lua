local db = require("lapis.db")
local cjson = require "cjson"

local SwaggerUi = {}

local function firstToUpper(str)
    return (str:gsub("^%l", string.upper))
end

function SwaggerUi.generate()

    local res =
        db.query(
            "SELECT table_name, column_name, data_type FROM information_schema.columns WHERE table_schema = 'public' ORDER BY  table_name, ordinal_position;"
        )

    if not res then
        ngx.log(ngx.ERR, "Failed to query database: ")
        ngx.exit(500)
    end

    local swagger = {
        openapi = "3.0.0",
        info = {
            title = "API Documentation",
            version = "1.0",
            description = "Generated from database schema",
        },
        paths = {}
    }
    for _, row in ipairs(res) do
            local table_name = row.table_name
            local column_name = row.column_name
            local data_type = row.data_type
            local isRelationTable = string.find(table_name, "__")
            -- Check if the table has been added to Swagger
            if table_name ~= "lapis_migrations" then
                if not isRelationTable then
                    if not swagger.paths["/api/v2/" .. table_name] then
                        swagger.paths["/api/v2/" .. table_name] = {
                            get = {
                                tags = { firstToUpper(table_name) },
                                summary = "Get all " .. table_name,
                                responses = {
                                    ["200"] = {
                                        description = "Successful operation",
                                        content = {
                                            ["application/json"] = {
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
                                    {
                                        name = "page",
                                        ["in"] = "query",
                                        schema = {
                                            type = "number"
                                        },
                                        required = false,
                                        description = "Unique identifier of the Business"
                                    },
                                    {
                                        name = "perPage",
                                        ["in"] = "query",
                                        schema = {
                                            type = "number"
                                        },
                                        required = false,
                                        description = "Unique identifier of the Business"
                                    },
                                    {
                                        name = "orderBy",
                                        ["in"] = "query",
                                        schema = {
                                            type = "string"
                                        },
                                        required = false,
                                        description = "Unique identifier of the Business"
                                    },
                                    {
                                        name = "orderDir",
                                        ["in"] = "query",
                                        schema = {
                                            type = "string"
                                        },
                                        required = false,
                                        description = "Unique identifier of the Business"
                                    },
                                }
                            },
                            post = {
                                tags = { firstToUpper(table_name) },
                                summary = "Create a new " .. table_name,
                                requestBody = {
                                    required = true,
                                    content = {
                                        ["application/json"] = {
                                            schema = {
                                                type = "object",
                                                properties = {}
                                            }
                                        }
                                    }
                                },
                                responses = {
                                    ["201"] = {
                                        description = table_name .. "created successfully"
                                    }
                                }
                            }
                        }
                    end
    
                    swagger.paths["/api/v2/" .. table_name].get.responses["200"].content["application/json"].schema.items.properties[column_name] = {
                        type = (data_type == "int" or data_type == "bigint") and "integer" or "string",
                        description = "Description of " .. column_name,
                        example = "Example value"
                    }
                    if column_name ~= "uuid" then
                        if column_name ~= "id" then
                            if column_name ~= "created_at" then
                                if column_name ~= "updated_at" then
                                    swagger.paths["/api/v2/" .. table_name].post.requestBody.content["application/json"].schema.properties[column_name] = {
                                        type = (data_type == "int" or data_type == "bigint") and "integer" or "string",
                                        description = "Description of " .. column_name,
                                        example = "Example value"
                                    }
                                end
                            end
                        end
                    end
    
                    if not swagger.paths["/api/v2/" .. table_name .. "/{uuid}"] then
                        swagger.paths["/api/v2/" .. table_name .. "/{uuid}"] = {
                            get = {
                                tags = { firstToUpper(table_name) },
                                summary = "Get all " .. table_name,
                                responses = {
                                    ["200"] = {
                                        description = "Successful operation",
                                        content = {
                                            ["application/json"] = {
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
                                parameters = { {
                                    name = "uuid",
                                    ["in"] = "path",
                                    schema = {
                                        type = "string"
                                    },
                                    required = true,
                                    description = "Unique identifier for the " .. table_name
                                } }
                            },
                            delete = {
                                tags = { firstToUpper(table_name) },
                                summary = "Delete Data from " .. table_name,
                                responses = {
                                    ["204"] = {
                                        description = "Successful operation",
                                        content = {
                                            ["application/json"] = {
                                                schema = {
                                                    type = "boolean",
                                                }
                                            }
                                        }
                                    }
                                },
                                parameters = { {
                                    name = "uuid",
                                    ["in"] = "path",
                                    schema = {
                                        type = "string"
                                    },
                                    required = true,
                                    description = "Unique identifier for the " .. table_name
                                } }
                            },
                            put = {
                                tags = { firstToUpper(table_name) },
                                summary = "Create a new " .. table_name,
                                requestBody = {
                                    required = true,
                                    content = {
                                        ["application/json"] = {
                                            schema = {
                                                type = "object",
                                                properties = {}
                                            }
                                        }
                                    }
                                },
                                parameters = { {
                                    name = "uuid",
                                    ["in"] = "path",
                                    schema = {
                                        type = "string"
                                    },
                                    required = true,
                                    description = "Unique identifier for the " .. table_name
                                } },
                                responses = {
                                    ["201"] = {
                                        description = table_name .. "created successfully"
                                    }
                                }
                            }
                        }
                    end
                    swagger.paths["/api/v2/" .. table_name .. "/{uuid}"].get.responses["200"].content["application/json"].schema.items.properties[column_name] = {
                        type = (data_type == "int" or data_type == "bigint") and "integer" or "string",
                        description = "Description of " .. column_name,
                        example = "Example value"
                    }
                    if column_name ~= "uuid" then
                        if column_name ~= "id" then
                            if column_name ~= "created_at" then
                                if column_name ~= "updated_at" then
                                    swagger.paths["/api/v2/" .. table_name .. "/{uuid}"].put.requestBody.content["application/json"].schema.properties[column_name] = {
                                        type = (data_type == "int" or data_type == "bigint") and "integer" or "string",
                                        description = "Description of " .. column_name,
                                        example = "Example value"
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end

        local swagger_json = cjson.encode(swagger)

        local file = io.open("/app/api-docs/swagger.json", "w")
        if file then
            file:write(swagger_json)
            file:close()
        else
            ngx.log(ngx.ERR, "Failed to open file for writing.")
        end
end


return SwaggerUi