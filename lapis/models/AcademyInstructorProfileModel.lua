local Model = require("lapis.db.model").Model

local AcademyInstructorProfiles = Model:extend("academy_instructor_profiles", {
    timestamp = true,
})

return AcademyInstructorProfiles
