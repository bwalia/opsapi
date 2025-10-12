local cjson = require("cjson")

local _M = {}

function _M.generate()
    return {
        openapi = "3.0.0",
        info = {
            title = "OpsAPI",
            description = "Multi-tenant E-commerce API built with Lapis/OpenResty\n\n**Authentication:** Most endpoints require a JWT Bearer token. Get your token by calling the `/auth/login` endpoint.",
            version = "1.0.0",
            contact = {
                name = "API Support",
                email = "support@opsapi.com"
            },
            license = {
                name = "MIT",
                url = "https://opensource.org/licenses/MIT"
            }
        },
        servers = {
            {
                url = "http://localhost:4010",
                description = "Local Development"
            },
            {
                url = "https://api.yourdomain.com",
                description = "Production"
            }
        },
        components = {
            securitySchemes = {
                BearerAuth = {
                    type = "http",
                    scheme = "bearer",
                    bearerFormat = "JWT",
                    description = "Enter JWT token obtained from /auth/login"
                }
            },
            schemas = {
                User = {
                    type = "object",
                    properties = {
                        id = { type = "string", format = "uuid" },
                        email = { type = "string", format = "email" },
                        first_name = { type = "string" },
                        last_name = { type = "string" },
                        phone = { type = "string" },
                        created_at = { type = "string", format = "date-time" },
                        updated_at = { type = "string", format = "date-time" }
                    }
                },
                Group = {
                    type = "object",
                    properties = {
                        id = { type = "string", format = "uuid" },
                        name = { type = "string" },
                        description = { type = "string" },
                        type = { type = "string" },
                        created_at = { type = "string", format = "date-time" }
                    }
                },
                Role = {
                    type = "object",
                    properties = {
                        id = { type = "string", format = "uuid" },
                        name = { type = "string" },
                        description = { type = "string" },
                        permissions = { type = "array", items = { type = "string" } }
                    }
                },
                Product = {
                    type = "object",
                    properties = {
                        id = { type = "string", format = "uuid" },
                        name = { type = "string" },
                        description = { type = "string" },
                        price = { type = "number", format = "double" },
                        currency = { type = "string", default = "USD" },
                        sku = { type = "string" },
                        stock_quantity = { type = "integer" },
                        category_id = { type = "string", format = "uuid" },
                        images = { type = "array", items = { type = "string" } },
                        is_active = { type = "boolean" },
                        created_at = { type = "string", format = "date-time" }
                    }
                },
                Category = {
                    type = "object",
                    properties = {
                        id = { type = "string", format = "uuid" },
                        name = { type = "string" },
                        slug = { type = "string" },
                        description = { type = "string" },
                        parent_id = { type = "string", format = "uuid", nullable = true },
                        image = { type = "string" }
                    }
                },
                Order = {
                    type = "object",
                    properties = {
                        id = { type = "string", format = "uuid" },
                        user_id = { type = "string", format = "uuid" },
                        status = { type = "string", enum = { "pending", "processing", "shipped", "delivered", "cancelled" } },
                        total_amount = { type = "number", format = "double" },
                        currency = { type = "string" },
                        items = { type = "array", items = { ["$ref"] = "#/components/schemas/OrderItem" } },
                        shipping_address = { type = "object" },
                        created_at = { type = "string", format = "date-time" }
                    }
                },
                OrderItem = {
                    type = "object",
                    properties = {
                        product_id = { type = "string", format = "uuid" },
                        quantity = { type = "integer" },
                        price = { type = "number", format = "double" },
                        subtotal = { type = "number", format = "double" }
                    }
                },
                Cart = {
                    type = "object",
                    properties = {
                        id = { type = "string", format = "uuid" },
                        user_id = { type = "string", format = "uuid" },
                        items = { type = "array", items = { ["$ref"] = "#/components/schemas/CartItem" } },
                        total = { type = "number", format = "double" }
                    }
                },
                CartItem = {
                    type = "object",
                    properties = {
                        product_id = { type = "string", format = "uuid" },
                        quantity = { type = "integer" },
                        price = { type = "number", format = "double" }
                    }
                },
                Payment = {
                    type = "object",
                    properties = {
                        id = { type = "string", format = "uuid" },
                        order_id = { type = "string", format = "uuid" },
                        amount = { type = "number", format = "double" },
                        currency = { type = "string" },
                        status = { type = "string", enum = { "pending", "completed", "failed", "refunded" } },
                        payment_method = { type = "string" },
                        transaction_id = { type = "string" },
                        created_at = { type = "string", format = "date-time" }
                    }
                },
                Address = {
                    type = "object",
                    properties = {
                        id = { type = "string", format = "uuid" },
                        user_id = { type = "string", format = "uuid" },
                        type = { type = "string", enum = { "billing", "shipping" } },
                        street = { type = "string" },
                        city = { type = "string" },
                        state = { type = "string" },
                        postal_code = { type = "string" },
                        country = { type = "string" },
                        is_default = { type = "boolean" }
                    }
                },
                Tenant = {
                    type = "object",
                    properties = {
                        id = { type = "string", format = "uuid" },
                        name = { type = "string" },
                        slug = { type = "string" },
                        domain = { type = "string" },
                        settings = { type = "object" },
                        is_active = { type = "boolean" },
                        created_at = { type = "string", format = "date-time" }
                    }
                },
                Permission = {
                    type = "object",
                    properties = {
                        id = { type = "string", format = "uuid" },
                        name = { type = "string" },
                        resource = { type = "string" },
                        action = { type = "string" },
                        description = { type = "string" }
                    }
                },
                Error = {
                    type = "object",
                    properties = {
                        error = { type = "string" },
                        details = { type = "string" }
                    }
                },
                PaginatedResponse = {
                    type = "object",
                    properties = {
                        data = { type = "array", items = {} },
                        total = { type = "integer" },
                        limit = { type = "integer" },
                        offset = { type = "integer" }
                    }
                },
                Hospital = {
                    type = "object",
                    properties = {
                        id = { type = "integer" },
                        uuid = { type = "string" },
                        name = { type = "string" },
                        type = { type = "string", enum = { "hospital", "care_home", "clinic" } },
                        license_number = { type = "string" },
                        address = { type = "string" },
                        city = { type = "string" },
                        state = { type = "string" },
                        postal_code = { type = "string" },
                        country = { type = "string" },
                        phone = { type = "string" },
                        email = { type = "string" },
                        website = { type = "string" },
                        capacity = { type = "integer" },
                        specialties = { type = "array", items = { type = "string" } },
                        services = { type = "array", items = { type = "string" } },
                        facilities = { type = "array", items = { type = "string" } },
                        emergency_services = { type = "boolean" },
                        operating_hours = { type = "object" },
                        contact_person = { type = "string" },
                        contact_phone = { type = "string" },
                        status = { type = "string", enum = { "active", "inactive", "suspended" } },
                        created_at = { type = "string", format = "date-time" },
                        updated_at = { type = "string", format = "date-time" }
                    }
                },
                HospitalInput = {
                    type = "object",
                    required = { "name", "license_number", "address", "city", "state", "country", "phone", "email" },
                    properties = {
                        name = { type = "string" },
                        type = { type = "string", enum = { "hospital", "care_home", "clinic" } },
                        license_number = { type = "string" },
                        address = { type = "string" },
                        city = { type = "string" },
                        state = { type = "string" },
                        postal_code = { type = "string" },
                        country = { type = "string" },
                        phone = { type = "string" },
                        email = { type = "string" },
                        website = { type = "string" },
                        capacity = { type = "integer" },
                        specialties = { type = "array", items = { type = "string" } },
                        services = { type = "array", items = { type = "string" } },
                        facilities = { type = "array", items = { type = "string" } },
                        emergency_services = { type = "boolean" },
                        operating_hours = { type = "object" },
                        contact_person = { type = "string" },
                        contact_phone = { type = "string" },
                        status = { type = "string", enum = { "active", "inactive", "suspended" } }
                    }
                },
                Patient = {
                    type = "object",
                    properties = {
                        id = { type = "integer" },
                        uuid = { type = "string" },
                        hospital_id = { type = "integer" },
                        patient_id = { type = "string" },
                        first_name = { type = "string" },
                        last_name = { type = "string" },
                        date_of_birth = { type = "string", format = "date" },
                        gender = { type = "string", enum = { "male", "female", "other" } },
                        phone = { type = "string" },
                        email = { type = "string" },
                        address = { type = "string" },
                        city = { type = "string" },
                        state = { type = "string" },
                        postal_code = { type = "string" },
                        country = { type = "string" },
                        emergency_contact_name = { type = "string" },
                        emergency_contact_phone = { type = "string" },
                        emergency_contact_relation = { type = "string" },
                        blood_type = { type = "string" },
                        allergies = { type = "array", items = { type = "string" } },
                        medical_conditions = { type = "array", items = { type = "string" } },
                        medications = { type = "array", items = { type = "string" } },
                        insurance_provider = { type = "string" },
                        insurance_number = { type = "string" },
                        admission_date = { type = "string", format = "date" },
                        discharge_date = { type = "string", format = "date" },
                        room_number = { type = "string" },
                        bed_number = { type = "string" },
                        status = { type = "string", enum = { "active", "discharged", "transferred", "deceased" } },
                        notes = { type = "string" },
                        created_at = { type = "string", format = "date-time" },
                        updated_at = { type = "string", format = "date-time" }
                    }
                },
                PatientInput = {
                    type = "object",
                    required = { "hospital_id", "patient_id", "first_name", "last_name", "date_of_birth", "gender" },
                    properties = {
                        hospital_id = { type = "integer" },
                        patient_id = { type = "string" },
                        first_name = { type = "string" },
                        last_name = { type = "string" },
                        date_of_birth = { type = "string", format = "date" },
                        gender = { type = "string", enum = { "male", "female", "other" } },
                        phone = { type = "string" },
                        email = { type = "string" },
                        address = { type = "string" },
                        city = { type = "string" },
                        state = { type = "string" },
                        postal_code = { type = "string" },
                        country = { type = "string" },
                        emergency_contact_name = { type = "string" },
                        emergency_contact_phone = { type = "string" },
                        emergency_contact_relation = { type = "string" },
                        blood_type = { type = "string" },
                        allergies = { type = "array", items = { type = "string" } },
                        medical_conditions = { type = "array", items = { type = "string" } },
                        medications = { type = "array", items = { type = "string" } },
                        insurance_provider = { type = "string" },
                        insurance_number = { type = "string" },
                        admission_date = { type = "string", format = "date" },
                        discharge_date = { type = "string", format = "date" },
                        room_number = { type = "string" },
                        bed_number = { type = "string" },
                        status = { type = "string", enum = { "active", "discharged", "transferred", "deceased" } },
                        notes = { type = "string" }
                    }
                },
                HealthRecord = {
                    type = "object",
                    properties = {
                        id = { type = "integer" },
                        uuid = { type = "string" },
                        patient_id = { type = "integer" },
                        record_type = { type = "string", enum = { "vital_signs", "medication", "meal", "activity", "note", "procedure" } },
                        record_date = { type = "string", format = "date" },
                        record_time = { type = "string", format = "time" },
                        recorded_by = { type = "string" },
                        temperature = { type = "number" },
                        blood_pressure_systolic = { type = "integer" },
                        blood_pressure_diastolic = { type = "integer" },
                        heart_rate = { type = "integer" },
                        respiratory_rate = { type = "integer" },
                        oxygen_saturation = { type = "number" },
                        weight = { type = "number" },
                        height = { type = "number" },
                        pain_level = { type = "integer", minimum = 1, maximum = 10 },
                        medication_name = { type = "string" },
                        medication_dose = { type = "string" },
                        medication_time = { type = "string", format = "time" },
                        medication_notes = { type = "string" },
                        meal_type = { type = "string", enum = { "breakfast", "lunch", "dinner", "snack" } },
                        meal_intake = { type = "string", enum = { "full", "partial", "refused" } },
                        meal_notes = { type = "string" },
                        activity_type = { type = "string" },
                        activity_duration = { type = "integer" },
                        activity_notes = { type = "string" },
                        procedure_name = { type = "string" },
                        procedure_notes = { type = "string" },
                        general_notes = { type = "string" },
                        follow_up_required = { type = "boolean" },
                        follow_up_date = { type = "string", format = "date" },
                        created_at = { type = "string", format = "date-time" },
                        updated_at = { type = "string", format = "date-time" }
                    }
                },
                HealthRecordInput = {
                    type = "object",
                    required = { "record_type", "record_date" },
                    properties = {
                        record_type = { type = "string", enum = { "vital_signs", "medication", "meal", "activity", "note", "procedure" } },
                        record_date = { type = "string", format = "date" },
                        record_time = { type = "string", format = "time" },
                        recorded_by = { type = "string" },
                        temperature = { type = "number" },
                        blood_pressure_systolic = { type = "integer" },
                        blood_pressure_diastolic = { type = "integer" },
                        heart_rate = { type = "integer" },
                        respiratory_rate = { type = "integer" },
                        oxygen_saturation = { type = "number" },
                        weight = { type = "number" },
                        height = { type = "number" },
                        pain_level = { type = "integer", minimum = 1, maximum = 10 },
                        medication_name = { type = "string" },
                        medication_dose = { type = "string" },
                        medication_time = { type = "string", format = "time" },
                        medication_notes = { type = "string" },
                        meal_type = { type = "string", enum = { "breakfast", "lunch", "dinner", "snack" } },
                        meal_intake = { type = "string", enum = { "full", "partial", "refused" } },
                        meal_notes = { type = "string" },
                        activity_type = { type = "string" },
                        activity_duration = { type = "integer" },
                        activity_notes = { type = "string" },
                        procedure_name = { type = "string" },
                        procedure_notes = { type = "string" },
                        general_notes = { type = "string" },
                        follow_up_required = { type = "boolean" },
                        follow_up_date = { type = "string", format = "date" }
                    }
                }
            }
        },
        tags = {
            { name = "Public", description = "Public endpoints (no authentication)" },
            { name = "Authentication", description = "Authentication and authorization" },
            { name = "Users", description = "User management" },
            { name = "Groups", description = "Group management" },
            { name = "Roles", description = "Role and permission management" },
            { name = "Products", description = "Product catalog management" },
            { name = "Categories", description = "Product category management" },
            { name = "Orders", description = "Order management" },
            { name = "Cart", description = "Shopping cart operations" },
            { name = "Payments", description = "Payment processing" },
            { name = "Addresses", description = "User address management" },
            { name = "Tenants", description = "Multi-tenant management" },
            { name = "Permissions", description = "Permission management" },
            { name = "Hospitals", description = "Hospital and care home management" },
            { name = "Patients", description = "Patient management and health tracking" }
        },
        paths = {
            -- Public endpoints
            ["/"] = {
                get = {
                    summary = "API Root",
                    tags = { "Public" },
                    security = {},
                    responses = {
                        ["200"] = { description = "API information" }
                    }
                }
            },
            ["/health"] = {
                get = {
                    summary = "Health Check",
                    tags = { "Public" },
                    security = {},
                    responses = {
                        ["200"] = { description = "Service health status" }
                    }
                }
            },
            ["/metrics"] = {
                get = {
                    summary = "Prometheus Metrics",
                    description = "Expose application metrics in Prometheus format for monitoring",
                    tags = { "Public" },
                    security = {},
                    responses = {
                        ["200"] = {
                            description = "Prometheus metrics in text format",
                            content = {
                                ["text/plain"] = {
                                    schema = {
                                        type = "string",
                                        example = "# HELP opsapi_up API is running\n# TYPE opsapi_up gauge\nopsapi_up 1\n"
                                    }
                                }
                            }
                        }
                    }
                }
            },
            
            -- Authentication
            ["/auth/login"] = {
                post = {
                    summary = "User Login",
                    tags = { "Authentication" },
                    security = {},
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = {
                                    type = "object",
                                    required = { "email", "password" },
                                    properties = {
                                        email = { type = "string", format = "email" },
                                        password = { type = "string", format = "password" }
                                    }
                                }
                            }
                        }
                    },
                    responses = {
                        ["200"] = { description = "Login successful, returns JWT token" }
                    }
                }
            },
            ["/auth/register"] = {
                post = {
                    summary = "User Registration",
                    tags = { "Authentication" },
                    security = {},
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = {
                                    type = "object",
                                    required = { "email", "password", "first_name", "last_name" },
                                    properties = {
                                        email = { type = "string", format = "email" },
                                        password = { type = "string", format = "password" },
                                        first_name = { type = "string" },
                                        last_name = { type = "string" }
                                    }
                                }
                            }
                        }
                    },
                    responses = {
                        ["201"] = { description = "User registered successfully" }
                    }
                }
            },
            ["/auth/logout"] = {
                post = {
                    summary = "User Logout",
                    tags = { "Authentication" },
                    security = { { BearerAuth = {} } },
                    responses = {
                        ["200"] = { description = "Logout successful" }
                    }
                }
            },
            ["/auth/refresh"] = {
                post = {
                    summary = "Refresh JWT Token",
                    tags = { "Authentication" },
                    security = { { BearerAuth = {} } },
                    responses = {
                        ["200"] = { description = "New token issued" }
                    }
                }
            },
            
            -- Users
            ["/api/v2/users"] = {
                get = {
                    summary = "List Users",
                    tags = { "Users" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "limit", ["in"] = "query", schema = { type = "integer", default = 10 } },
                        { name = "offset", ["in"] = "query", schema = { type = "integer", default = 0 } },
                        { name = "search", ["in"] = "query", schema = { type = "string" } }
                    },
                    responses = {
                        ["200"] = { description = "List of users" }
                    }
                },
                post = {
                    summary = "Create User",
                    tags = { "Users" },
                    security = { { BearerAuth = {} } },
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = { ["$ref"] = "#/components/schemas/User" }
                            }
                        }
                    },
                    responses = {
                        ["201"] = { description = "User created" }
                    }
                }
            },
            ["/api/v2/users/{id}"] = {
                get = {
                    summary = "Get User",
                    tags = { "Users" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "User details" }
                    }
                },
                put = {
                    summary = "Update User",
                    tags = { "Users" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = { ["$ref"] = "#/components/schemas/User" }
                            }
                        }
                    },
                    responses = {
                        ["200"] = { description = "User updated" }
                    }
                },
                delete = {
                    summary = "Delete User",
                    tags = { "Users" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "User deleted" }
                    }
                }
            },
            
            -- Groups
            ["/api/v2/groups"] = {
                get = {
                    summary = "List Groups",
                    tags = { "Groups" },
                    security = { { BearerAuth = {} } },
                    responses = {
                        ["200"] = { description = "List of groups" }
                    }
                },
                post = {
                    summary = "Create Group",
                    tags = { "Groups" },
                    security = { { BearerAuth = {} } },
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = { ["$ref"] = "#/components/schemas/Group" }
                            }
                        }
                    },
                    responses = {
                        ["201"] = { description = "Group created" }
                    }
                }
            },
            ["/api/v2/groups/{id}"] = {
                get = {
                    summary = "Get Group",
                    tags = { "Groups" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Group details" }
                    }
                },
                put = {
                    summary = "Update Group",
                    tags = { "Groups" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Group updated" }
                    }
                },
                delete = {
                    summary = "Delete Group",
                    tags = { "Groups" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Group deleted" }
                    }
                }
            },
            
            -- Roles
            ["/api/v2/roles"] = {
                get = {
                    summary = "List Roles",
                    tags = { "Roles" },
                    security = { { BearerAuth = {} } },
                    responses = {
                        ["200"] = { description = "List of roles" }
                    }
                },
                post = {
                    summary = "Create Role",
                    tags = { "Roles" },
                    security = { { BearerAuth = {} } },
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = { ["$ref"] = "#/components/schemas/Role" }
                            }
                        }
                    },
                    responses = {
                        ["201"] = { description = "Role created" }
                    }
                }
            },
            ["/api/v2/roles/{id}"] = {
                get = {
                    summary = "Get Role",
                    tags = { "Roles" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Role details" }
                    }
                },
                put = {
                    summary = "Update Role",
                    tags = { "Roles" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Role updated" }
                    }
                },
                delete = {
                    summary = "Delete Role",
                    tags = { "Roles" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Role deleted" }
                    }
                }
            },
            
            -- Products
            ["/api/v2/products"] = {
                get = {
                    summary = "List Products",
                    tags = { "Products" },
                    security = {},
                    parameters = {
                        { name = "limit", ["in"] = "query", schema = { type = "integer", default = 20 } },
                        { name = "offset", ["in"] = "query", schema = { type = "integer", default = 0 } },
                        { name = "category_id", ["in"] = "query", schema = { type = "string", format = "uuid" } },
                        { name = "search", ["in"] = "query", schema = { type = "string" } },
                        { name = "min_price", ["in"] = "query", schema = { type = "number" } },
                        { name = "max_price", ["in"] = "query", schema = { type = "number" } }
                    },
                    responses = {
                        ["200"] = { description = "List of products" }
                    }
                },
                post = {
                    summary = "Create Product",
                    tags = { "Products" },
                    security = { { BearerAuth = {} } },
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = { ["$ref"] = "#/components/schemas/Product" }
                            }
                        }
                    },
                    responses = {
                        ["201"] = { description = "Product created" }
                    }
                }
            },
            ["/api/v2/products/{id}"] = {
                get = {
                    summary = "Get Product",
                    tags = { "Products" },
                    security = {},
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Product details" }
                    }
                },
                put = {
                    summary = "Update Product",
                    tags = { "Products" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Product updated" }
                    }
                },
                delete = {
                    summary = "Delete Product",
                    tags = { "Products" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Product deleted" }
                    }
                }
            },
            
            -- Categories
            ["/api/v2/categories"] = {
                get = {
                    summary = "List Categories",
                    tags = { "Categories" },
                    security = {},
                    responses = {
                        ["200"] = { description = "List of categories" }
                    }
                },
                post = {
                    summary = "Create Category",
                    tags = { "Categories" },
                    security = { { BearerAuth = {} } },
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = { ["$ref"] = "#/components/schemas/Category" }
                            }
                        }
                    },
                    responses = {
                        ["201"] = { description = "Category created" }
                    }
                }
            },
            ["/api/v2/categories/{id}"] = {
                get = {
                    summary = "Get Category",
                    tags = { "Categories" },
                    security = {},
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Category details" }
                    }
                }
            },
            
            -- Orders
            ["/api/v2/orders"] = {
                get = {
                    summary = "List Orders",
                    tags = { "Orders" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "status", ["in"] = "query", schema = { type = "string" } },
                        { name = "user_id", ["in"] = "query", schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "List of orders" }
                    }
                },
                post = {
                    summary = "Create Order",
                    tags = { "Orders" },
                    security = { { BearerAuth = {} } },
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = { ["$ref"] = "#/components/schemas/Order" }
                            }
                        }
                    },
                    responses = {
                        ["201"] = { description = "Order created" }
                    }
                }
            },
            ["/api/v2/orders/{id}"] = {
                get = {
                    summary = "Get Order",
                    tags = { "Orders" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Order details" }
                    }
                },
                put = {
                    summary = "Update Order Status",
                    tags = { "Orders" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Order updated" }
                    }
                }
            },
            
            -- Cart
            ["/api/v2/cart"] = {
                get = {
                    summary = "Get Cart",
                    tags = { "Cart" },
                    security = { { BearerAuth = {} } },
                    responses = {
                        ["200"] = { description = "Cart contents" }
                    }
                },
                post = {
                    summary = "Add to Cart",
                    tags = { "Cart" },
                    security = { { BearerAuth = {} } },
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = { ["$ref"] = "#/components/schemas/CartItem" }
                            }
                        }
                    },
                    responses = {
                        ["200"] = { description = "Item added to cart" }
                    }
                },
                delete = {
                    summary = "Clear Cart",
                    tags = { "Cart" },
                    security = { { BearerAuth = {} } },
                    responses = {
                        ["200"] = { description = "Cart cleared" }
                    }
                }
            },
            ["/api/v2/cart/{product_id}"] = {
                put = {
                    summary = "Update Cart Item",
                    tags = { "Cart" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "product_id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Cart item updated" }
                    }
                },
                delete = {
                    summary = "Remove from Cart",
                    tags = { "Cart" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "product_id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Item removed from cart" }
                    }
                }
            },
            
            -- Payments
            ["/api/v2/payments"] = {
                get = {
                    summary = "List Payments",
                    tags = { "Payments" },
                    security = { { BearerAuth = {} } },
                    responses = {
                        ["200"] = { description = "List of payments" }
                    }
                },
                post = {
                    summary = "Process Payment",
                    tags = { "Payments" },
                    security = { { BearerAuth = {} } },
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = { ["$ref"] = "#/components/schemas/Payment" }
                            }
                        }
                    },
                    responses = {
                        ["201"] = { description = "Payment processed" }
                    }
                }
            },
            ["/api/v2/payments/{id}"] = {
                get = {
                    summary = "Get Payment",
                    tags = { "Payments" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Payment details" }
                    }
                }
            },
            
            -- Addresses
            ["/api/v2/addresses"] = {
                get = {
                    summary = "List Addresses",
                    tags = { "Addresses" },
                    security = { { BearerAuth = {} } },
                    responses = {
                        ["200"] = { description = "List of user addresses" }
                    }
                },
                post = {
                    summary = "Create Address",
                    tags = { "Addresses" },
                    security = { { BearerAuth = {} } },
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = { ["$ref"] = "#/components/schemas/Address" }
                            }
                        }
                    },
                    responses = {
                        ["201"] = { description = "Address created" }
                    }
                }
            },
            ["/api/v2/addresses/{id}"] = {
                get = {
                    summary = "Get Address",
                    tags = { "Addresses" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Address details" }
                    }
                },
                put = {
                    summary = "Update Address",
                    tags = { "Addresses" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Address updated" }
                    }
                },
                delete = {
                    summary = "Delete Address",
                    tags = { "Addresses" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Address deleted" }
                    }
                }
            },
            
            -- Tenants
            ["/api/v2/tenants"] = {
                get = {
                    summary = "List Tenants",
                    tags = { "Tenants" },
                    security = { { BearerAuth = {} } },
                    responses = {
                        ["200"] = { description = "List of tenants" }
                    }
                },
                post = {
                    summary = "Create Tenant",
                    tags = { "Tenants" },
                    security = { { BearerAuth = {} } },
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = { ["$ref"] = "#/components/schemas/Tenant" }
                            }
                        }
                    },
                    responses = {
                        ["201"] = { description = "Tenant created" }
                    }
                }
            },
            ["/api/v2/tenants/{id}"] = {
                get = {
                    summary = "Get Tenant",
                    tags = { "Tenants" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "string", format = "uuid" } }
                    },
                    responses = {
                        ["200"] = { description = "Tenant details" }
                    }
                }
            },
            
            -- Permissions
            ["/api/v2/permissions"] = {
                get = {
                    summary = "List Permissions",
                    tags = { "Permissions" },
                    security = { { BearerAuth = {} } },
                    responses = {
                        ["200"] = { description = "List of permissions" }
                    }
                },
                post = {
                    summary = "Create Permission",
                    tags = { "Permissions" },
                    security = { { BearerAuth = {} } },
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = { ["$ref"] = "#/components/schemas/Permission" }
                            }
                        }
                    },
                    responses = {
                        ["201"] = { description = "Permission created" }
                    }
                }
            },
            
            -- Hospitals
            ["/hospitals"] = {
                get = {
                    summary = "Get all hospitals",
                    tags = { "Hospitals" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "page", ["in"] = "query", schema = { type = "integer", default = 1 } },
                        { name = "per_page", ["in"] = "query", schema = { type = "integer", default = 20 } }
                    },
                    responses = {
                        ["200"] = { 
                            description = "Success",
                            content = {
                                ["application/json"] = {
                                    schema = {
                                        type = "object",
                                        properties = {
                                            hospitals = { type = "array", items = { ["$ref"] = "#/components/schemas/Hospital" } },
                                            pagination = { ["$ref"] = "#/components/schemas/PaginatedResponse" }
                                        }
                                    }
                                }
                            }
                        }
                    }
                },
                post = {
                    summary = "Create new hospital",
                    tags = { "Hospitals" },
                    security = { { BearerAuth = {} } },
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = { ["$ref"] = "#/components/schemas/HospitalInput" }
                            }
                        }
                    },
                    responses = {
                        ["201"] = { 
                            description = "Hospital created successfully",
                            content = {
                                ["application/json"] = {
                                    schema = {
                                        type = "object",
                                        properties = {
                                            message = { type = "string" },
                                            hospital = { ["$ref"] = "#/components/schemas/Hospital" }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            },
            ["/hospitals/{id}"] = {
                get = {
                    summary = "Get hospital by ID",
                    tags = { "Hospitals" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "integer" } }
                    },
                    responses = {
                        ["200"] = { 
                            description = "Success",
                            content = {
                                ["application/json"] = {
                                    schema = {
                                        type = "object",
                                        properties = {
                                            hospital = { ["$ref"] = "#/components/schemas/Hospital" }
                                        }
                                    }
                                }
                            }
                        },
                        ["404"] = { description = "Hospital not found" }
                    }
                },
                put = {
                    summary = "Update hospital",
                    tags = { "Hospitals" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "integer" } }
                    },
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = { ["$ref"] = "#/components/schemas/HospitalInput" }
                            }
                        }
                    },
                    responses = {
                        ["200"] = { 
                            description = "Hospital updated successfully",
                            content = {
                                ["application/json"] = {
                                    schema = {
                                        type = "object",
                                        properties = {
                                            message = { type = "string" },
                                            hospital = { ["$ref"] = "#/components/schemas/Hospital" }
                                        }
                                    }
                                }
                            }
                        },
                        ["404"] = { description = "Hospital not found" }
                    }
                },
                delete = {
                    summary = "Delete hospital",
                    tags = { "Hospitals" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "integer" } }
                    },
                    responses = {
                        ["200"] = { 
                            description = "Hospital deleted successfully",
                            content = {
                                ["application/json"] = {
                                    schema = {
                                        type = "object",
                                        properties = {
                                            message = { type = "string" }
                                        }
                                    }
                                }
                            }
                        },
                        ["404"] = { description = "Hospital not found" }
                    }
                }
            },
            ["/hospitals/search"] = {
                get = {
                    summary = "Search hospitals",
                    tags = { "Hospitals" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "name", ["in"] = "query", schema = { type = "string" } },
                        { name = "type", ["in"] = "query", schema = { type = "string" } },
                        { name = "city", ["in"] = "query", schema = { type = "string" } },
                        { name = "state", ["in"] = "query", schema = { type = "string" } },
                        { name = "emergency_services", ["in"] = "query", schema = { type = "boolean" } },
                        { name = "status", ["in"] = "query", schema = { type = "string" } }
                    },
                    responses = {
                        ["200"] = { 
                            description = "Success",
                            content = {
                                ["application/json"] = {
                                    schema = {
                                        type = "object",
                                        properties = {
                                            hospitals = { type = "array", items = { ["$ref"] = "#/components/schemas/Hospital" } }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            },
            ["/hospitals/{id}/statistics"] = {
                get = {
                    summary = "Get hospital statistics",
                    tags = { "Hospitals" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "integer" } }
                    },
                    responses = {
                        ["200"] = { 
                            description = "Success",
                            content = {
                                ["application/json"] = {
                                    schema = {
                                        type = "object",
                                        properties = {
                                            statistics = {
                                                type = "object",
                                                properties = {
                                                    total_patients = { type = "integer" },
                                                    active_patients = { type = "integer" },
                                                    total_staff = { type = "integer" },
                                                    active_staff = { type = "integer" },
                                                    recent_admissions = { type = "integer" }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        ["404"] = { description = "Hospital not found" }
                    }
                }
            },
            
            -- Patients
            ["/patients"] = {
                get = {
                    summary = "Get all patients",
                    tags = { "Patients" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "page", ["in"] = "query", schema = { type = "integer", default = 1 } },
                        { name = "per_page", ["in"] = "query", schema = { type = "integer", default = 20 } },
                        { name = "hospital_id", ["in"] = "query", schema = { type = "integer" } }
                    },
                    responses = {
                        ["200"] = { 
                            description = "Success",
                            content = {
                                ["application/json"] = {
                                    schema = {
                                        type = "object",
                                        properties = {
                                            patients = { type = "array", items = { ["$ref"] = "#/components/schemas/Patient" } },
                                            pagination = { ["$ref"] = "#/components/schemas/PaginatedResponse" }
                                        }
                                    }
                                }
                            }
                        }
                    }
                },
                post = {
                    summary = "Create new patient",
                    tags = { "Patients" },
                    security = { { BearerAuth = {} } },
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = { ["$ref"] = "#/components/schemas/PatientInput" }
                            }
                        }
                    },
                    responses = {
                        ["201"] = { 
                            description = "Patient created successfully",
                            content = {
                                ["application/json"] = {
                                    schema = {
                                        type = "object",
                                        properties = {
                                            message = { type = "string" },
                                            patient = { ["$ref"] = "#/components/schemas/Patient" }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            },
            ["/patients/{id}"] = {
                get = {
                    summary = "Get patient by ID",
                    tags = { "Patients" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "integer" } }
                    },
                    responses = {
                        ["200"] = { 
                            description = "Success",
                            content = {
                                ["application/json"] = {
                                    schema = {
                                        type = "object",
                                        properties = {
                                            patient = { ["$ref"] = "#/components/schemas/Patient" }
                                        }
                                    }
                                }
                            }
                        },
                        ["404"] = { description = "Patient not found" }
                    }
                },
                put = {
                    summary = "Update patient",
                    tags = { "Patients" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "integer" } }
                    },
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = { ["$ref"] = "#/components/schemas/PatientInput" }
                            }
                        }
                    },
                    responses = {
                        ["200"] = { 
                            description = "Patient updated successfully",
                            content = {
                                ["application/json"] = {
                                    schema = {
                                        type = "object",
                                        properties = {
                                            message = { type = "string" },
                                            patient = { ["$ref"] = "#/components/schemas/Patient" }
                                        }
                                    }
                                }
                            }
                        },
                        ["404"] = { description = "Patient not found" }
                    }
                },
                delete = {
                    summary = "Delete patient",
                    tags = { "Patients" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "integer" } }
                    },
                    responses = {
                        ["200"] = { 
                            description = "Patient deleted successfully",
                            content = {
                                ["application/json"] = {
                                    schema = {
                                        type = "object",
                                        properties = {
                                            message = { type = "string" }
                                        }
                                    }
                                }
                            }
                        },
                        ["404"] = { description = "Patient not found" }
                    }
                }
            },
            ["/patients/{id}/health-records"] = {
                get = {
                    summary = "Get patient health records",
                    tags = { "Patients" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "integer" } },
                        { name = "limit", ["in"] = "query", schema = { type = "integer", default = 50 } },
                        { name = "offset", ["in"] = "query", schema = { type = "integer", default = 0 } }
                    },
                    responses = {
                        ["200"] = { 
                            description = "Success",
                            content = {
                                ["application/json"] = {
                                    schema = {
                                        type = "object",
                                        properties = {
                                            health_records = { type = "array", items = { ["$ref"] = "#/components/schemas/HealthRecord" } }
                                        }
                                    }
                                }
                            }
                        },
                        ["404"] = { description = "Patient not found" }
                    }
                },
                post = {
                    summary = "Create health record",
                    tags = { "Patients" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "integer" } }
                    },
                    requestBody = {
                        required = true,
                        content = {
                            ["application/json"] = {
                                schema = { ["$ref"] = "#/components/schemas/HealthRecordInput" }
                            }
                        }
                    },
                    responses = {
                        ["201"] = { 
                            description = "Health record created successfully",
                            content = {
                                ["application/json"] = {
                                    schema = {
                                        type = "object",
                                        properties = {
                                            message = { type = "string" },
                                            health_record = { ["$ref"] = "#/components/schemas/HealthRecord" }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            },
            ["/patients/{id}/daily-summary/{date}"] = {
                get = {
                    summary = "Get daily summary for patient",
                    tags = { "Patients" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "id", ["in"] = "path", required = true, schema = { type = "integer" } },
                        { name = "date", ["in"] = "path", required = true, schema = { type = "string", format = "date" } }
                    },
                    responses = {
                        ["200"] = { 
                            description = "Success",
                            content = {
                                ["application/json"] = {
                                    schema = {
                                        type = "object",
                                        properties = {
                                            daily_summary = {
                                                type = "object",
                                                properties = {
                                                    vitals = { type = "array", items = { ["$ref"] = "#/components/schemas/HealthRecord" } },
                                                    medications = { type = "array", items = { ["$ref"] = "#/components/schemas/HealthRecord" } },
                                                    meals = { type = "array", items = { ["$ref"] = "#/components/schemas/HealthRecord" } },
                                                    activities = { type = "array", items = { ["$ref"] = "#/components/schemas/HealthRecord" } },
                                                    notes = { type = "array", items = { ["$ref"] = "#/components/schemas/HealthRecord" } }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        ["404"] = { description = "Patient not found" }
                    }
                }
            },
            ["/patients/search"] = {
                get = {
                    summary = "Search patients",
                    tags = { "Patients" },
                    security = { { BearerAuth = {} } },
                    parameters = {
                        { name = "hospital_id", ["in"] = "query", schema = { type = "integer" } },
                        { name = "patient_id", ["in"] = "query", schema = { type = "string" } },
                        { name = "first_name", ["in"] = "query", schema = { type = "string" } },
                        { name = "last_name", ["in"] = "query", schema = { type = "string" } },
                        { name = "room_number", ["in"] = "query", schema = { type = "string" } },
                        { name = "status", ["in"] = "query", schema = { type = "string" } },
                        { name = "admission_date_from", ["in"] = "query", schema = { type = "string", format = "date" } },
                        { name = "admission_date_to", ["in"] = "query", schema = { type = "string", format = "date" } }
                    },
                    responses = {
                        ["200"] = { 
                            description = "Success",
                            content = {
                                ["application/json"] = {
                                    schema = {
                                        type = "object",
                                        properties = {
                                            patients = { type = "array", items = { ["$ref"] = "#/components/schemas/Patient" } }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
end

return _M