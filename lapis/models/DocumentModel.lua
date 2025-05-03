local Model = require("lapis.db.model").Model
local db = require("lapis.db")

local Document = Model:extend("documents", {
  timestamp = true,
  relations = {
    { "tags", has_many = "DocumentTagsModel", key = "document_id" }
  }
})

function Document:get_full_tags()
  return db.select([[
    t.* FROM tags t
    INNER JOIN document__tags dt ON dt.tag_id = t.id
    WHERE dt.document_id = ?
  ]], self.id)
end

return Document
