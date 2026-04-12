local Model = require("lapis.db.model").Model
local HmrcExpenseCategories = Model:extend("hmrc_expense_categories", { timestamp = true })
return HmrcExpenseCategories
