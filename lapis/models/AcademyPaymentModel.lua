local Model = require("lapis.db.model").Model

local AcademyPayments = Model:extend("academy_payments", {
    timestamp = true,
    relations = {
        { "namespace", belongs_to = "NamespaceModel", key = "namespace_id" },
        { "course",    belongs_to = "AcademyCourseModel", key = "course_id" },
    }
})

return AcademyPayments
