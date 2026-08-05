local Model = require("lapis.db.model").Model

local CreatorAccounts = Model:extend("creator_accounts", {
    timestamp = true,
    relations = {
        { "namespace", belongs_to = "NamespaceModel", key = "namespace_id" },
    }
})

return CreatorAccounts
