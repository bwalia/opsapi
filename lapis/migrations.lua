local schema = require("lapis.db.schema")
local types = schema.types

return {
  ['01_create_users'] = function()
    schema.create_table("users", {
      { "id", types.serial },
      { "uuid", types.varchar({ unique = true }) },
      { "name", types.varchar },
      { "email", types.varchar({ unique = true }) },
      { "username", types.varchar({ unique = true }) },
      { "password", types.text },
      {"created_at", types.time({ null = true})},
      {"updated_at", types.time({ null = true})},

      "PRIMARY KEY (id)"
    })
  end,
  ['02_create_roles'] = function()
    schema.create_table("roles", {
      { "id", types.serial },
      { "uuid", types.varchar({ unique = true }) },
      { "role_name", types.varchar({ unique = true }) },
      {"created_at", types.time({ null = true})},
      {"updated_at", types.time({ null = true})},

      "PRIMARY KEY (id)"
    })
  end,
  ['create_user__roles'] = function()
    schema.create_table("user__roles", {
      { "id", types.serial },
      { "uuid", types.varchar({ unique = true }) },
      { "role_id", types.foreign_key },
      { "user_id", types.foreign_key },
      {"created_at", types.time({ null = true})},
      {"updated_at", types.time({ null = true})},

      "PRIMARY KEY (id)",
      "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE",
      "FOREIGN KEY (role_id) REFERENCES roles(id) ON DELETE CASCADE"
    })
  end,
  ['create_modules'] = function()
    schema.create_table("modules", {
      { "id", types.serial },
      { "uuid", types.varchar({ unique = true }) },
      { "machine_name", types.varchar({ unique = true }) },
      { "name", types.varchar },
      { "description", types.text({ null = true }) },
      { "priority", types.varchar },
      {"created_at", types.time({ null = true})},
      {"updated_at", types.time({ null = true})},

      "PRIMARY KEY (id)"
    })
  end,
  ['create_permissions'] = function()
    schema.create_table("permissions", {
      { "id", types.serial },
      { "uuid", types.varchar({ unique = true }) },
      { "module_id", types.foreign_key },
      { "permissions", types.text({ null = true }) },
      {"created_at", types.time({ null = true})},
      {"updated_at", types.time({ null = true})},

      "PRIMARY KEY (id)",
      "FOREIGN KEY (module_id) REFERENCES modules(id) ON DELETE CASCADE",
    })
  end,
  ['create_role__permissions'] = function()
    schema.create_table("role__permissions", {
      { "id", types.serial },
      { "uuid", types.varchar({ unique = true }) },
      { "role_id", types.foreign_key },
      { "permission_id", types.foreign_key },
      {"created_at", types.time({ null = true})},
      {"updated_at", types.time({ null = true})},

      "PRIMARY KEY (id)",
      "FOREIGN KEY (role_id) REFERENCES roles(id) ON DELETE CASCADE",
      "FOREIGN KEY (permission_id) REFERENCES permissions(id) ON DELETE CASCADE",
    })
  end,
}