local Model = require("lapis.db.model").Model

local AcademyEnrollments = Model:extend("academy_enrollments", {
    timestamp = true,
    relations = {
        { "course",    belongs_to = "AcademyCourseModel", key = "course_id" },
        { "namespace", belongs_to = "NamespaceModel", key = "namespace_id" },
    }
})

return AcademyEnrollments
