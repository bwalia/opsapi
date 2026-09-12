local Model = require("lapis.db.model").Model
local FsPhaseTemplates = Model:extend("fs_phase_templates", { timestamp = true })
return FsPhaseTemplates
