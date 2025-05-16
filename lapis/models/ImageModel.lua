local Model = require("lapis.db.model").Model

local Image = Model:extend("images", {
  relations = {
    { "document", belongs_to = "DocumentModel" }
  }
})

return Image
