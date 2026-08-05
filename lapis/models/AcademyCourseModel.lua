local Model = require("lapis.db.model").Model

local AcademyCourses = Model:extend("academy_courses", {
    timestamp = true,
    relations = {
        { "namespace", belongs_to = "NamespaceModel", key = "namespace_id" },
        { "lessons",   has_many = "AcademyLessonModel", key = "course_id" },
    }
})

return AcademyCourses
