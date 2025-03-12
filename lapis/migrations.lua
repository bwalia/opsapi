local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")
local Global = require "helper.global"

return {
  ['01_create_users'] = function()
    schema.create_table("users", {
      { "id",         types.serial },
      { "uuid",       types.varchar({ unique = true }) },
      { "first_name", types.varchar },
      { "last_name",  types.varchar },
      { "email",      types.varchar({ unique = true }) },
      { "username",   types.varchar({ unique = true }) },
      { "password",   types.text },
      { "phone_no",   types.text({ null = true }) },
      { "address",    types.text({ null = true }) },
      { "active",     types.boolean,                   default = false },
      { "created_at", types.time({ null = true }) },
      { "updated_at", types.time({ null = true }) },

      "PRIMARY KEY (id)"
    })
    local adminExists = db.select("id from users where username = ?", "administrative")
    if not adminExists or #adminExists == 0 then
      db.query([[
        INSERT INTO users (uuid, first_name, last_name, username, password, email, active, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ]], Global.generateStaticUUID(), "Super", "User", "administrative", Global.hashPassword("Admin@123"),
        "administrative@admin.com", true, Global.getCurrentTimestamp(), Global.getCurrentTimestamp())
    end
  end,
  ['02_create_roles'] = function()
    schema.create_table("roles", {
      { "id",         types.serial },
      { "uuid",       types.varchar({ unique = true }) },
      { "role_name",  types.varchar({ unique = true }) },
      { "created_at", types.time({ null = true }) },
      { "updated_at", types.time({ null = true }) },

      "PRIMARY KEY (id)"
    })
    local roleExists = db.select("id from roles where role_name = ?", "administrative")
    if not roleExists or #roleExists == 0 then
      db.query([[
        INSERT INTO roles (uuid, role_name, created_at, updated_at)
        VALUES (?, ?, ?, ?)
      ]], Global.generateStaticUUID(), "administrative", Global.getCurrentTimestamp(), Global.getCurrentTimestamp())
    end
  end,
  ['create_user__roles'] = function()
    schema.create_table("user__roles", {
      { "id",         types.serial },
      { "uuid",       types.varchar({ unique = true }) },
      { "role_id",    types.foreign_key },
      { "user_id",    types.foreign_key },
      { "created_at", types.time({ null = true }) },
      { "updated_at", types.time({ null = true }) },

      "PRIMARY KEY (id)",
      "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE",
      "FOREIGN KEY (role_id) REFERENCES roles(id) ON DELETE CASCADE"
    })
    local roleExists = db.select("id from user__roles where role_id = ? and user_id = ?", 1, 1)
    if not roleExists or #roleExists == 0 then
      db.query([[
        INSERT INTO user__roles (uuid, role_id, user_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
      ]], Global.generateStaticUUID(), 1, 1, Global.getCurrentTimestamp(), Global.getCurrentTimestamp())
    end
  end,
  ['create_modules'] = function()
    schema.create_table("modules", {
      { "id",           types.serial },
      { "uuid",         types.varchar({ unique = true }) },
      { "machine_name", types.varchar({ unique = true }) },
      { "name",         types.varchar },
      { "description",  types.text({ null = true }) },
      { "priority",     types.varchar },
      { "created_at",   types.time({ null = true }) },
      { "updated_at",   types.time({ null = true }) },

      "PRIMARY KEY (id)"
    })
  end,
  ['create_permissions'] = function()
    schema.create_table("permissions", {
      { "id",          types.serial },
      { "uuid",        types.varchar({ unique = true }) },
      { "module_id",   types.foreign_key },
      { "permissions", types.text({ null = true }) },
      { "role_id",     types.foreign_key },
      { "created_at",  types.time({ null = true }) },
      { "updated_at",  types.time({ null = true }) },

      "PRIMARY KEY (id)",
      "FOREIGN KEY (module_id) REFERENCES modules(id) ON DELETE CASCADE",
      "FOREIGN KEY (role_id) REFERENCES roles(id) ON DELETE CASCADE"
    })
  end,
  ['create_groups'] = function()
    schema.create_table("groups", {
      { "id",           types.serial },
      { "uuid",         types.varchar({ unique = true }) },
      { "machine_name", types.varchar({ unique = true }) },
      { "name",         types.varchar },
      { "description",  types.text({ null = true }) },
      { "created_at",   types.time({ null = true }) },
      { "updated_at",   types.time({ null = true }) },

      "PRIMARY KEY (id)"
    })
  end,
  ['create_user__groups'] = function()
    schema.create_table("user__groups", {
      { "id",         types.serial },
      { "uuid",       types.varchar({ unique = true }) },
      { "user_id",    types.foreign_key },
      { "group_id",   types.foreign_key },
      { "created_at", types.time({ null = true }) },
      { "updated_at", types.time({ null = true }) },

      "PRIMARY KEY (id)",
      "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE",
      "FOREIGN KEY (group_id) REFERENCES groups(id) ON DELETE CASCADE"
    })
  end,

  ['create_secrets'] = function()
    schema.create_table("secrets", {
      { "id",          types.serial },
      { "uuid",        types.varchar({ unique = true }) },
      { "secret",      types.varchar },
      { "name",        types.varchar },
      { "description", types.text({ null = true }) },
      { "created_at",  types.time({ null = true }) },
      { "updated_at",  types.time({ null = true }) },

      "PRIMARY KEY (id)"
    })
  end,

  ['00_create_templates'] = function()
    schema.create_table("templates", {
      { "id",               types.serial },
      { "uuid",             types.varchar({ unique = true }) },
      { "code",             types.varchar },
      { "template_content", types.text },
      { "template_type",    types.varchar({ null = true }) },
      { "description",      types.text({ null = true }) },
      { "created_at",       types.time({ null = true }) },
      { "updated_at",       types.time({ null = true }) },

      "PRIMARY KEY (id)"
    })
  end,

  ['01_create_projects'] = function()
    schema.create_table("projects", {
      { "id",            types.serial },
      { "uuid",          types.varchar({ unique = true }) },
      { "name",          types.varchar },
      { "start_date",    types.date({ null = true }) },
      { "budget",        types.double({ null = true }) },
      { "deadline_date", types.date({ null = true }) },
      { "active",        types.boolean },
      { "created_at",    types.time({ null = true }) },
      { "updated_at",    types.time({ null = true }) },

      "PRIMARY KEY (id)"
    })
  end,

  ['02_create_project__templates'] = function()
    schema.create_table("project__templates", {
      { "id",          types.serial },
      { "uuid",        types.varchar({ unique = true }) },
      { "project_id",  types.foreign_key },
      { "template_id", types.foreign_key },
      { "created_at",  types.time({ null = true }) },
      { "updated_at",  types.time({ null = true }) },

      "PRIMARY KEY (id)",
      "FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE",
      "FOREIGN KEY (template_id) REFERENCES templates(id) ON DELETE CASCADE"
    })
  end,
}
