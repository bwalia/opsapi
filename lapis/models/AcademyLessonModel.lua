local Model = require("lapis.db.model").Model

local AcademyLessons = Model:extend("academy_lessons", {
    timestamp = true,
    relations = {
        { "course",    belongs_to = "AcademyCourseModel", key = "course_id" },
        { "namespace", belongs_to = "NamespaceModel", key = "namespace_id" },
    }
})

return AcademyLessons
