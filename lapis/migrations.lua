local schema = require("lapis.db.schema")
local types = schema.types

return {
  ['create_users'] = function()
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
  ['create_roles'] = function()
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

      "PRIMARY KEY (id)"
    })
  end
}