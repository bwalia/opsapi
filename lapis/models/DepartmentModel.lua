local Model = require("lapis.db.model").Model
local cJson = require("cjson")
local Global = require "helper.global"

local DepartmentModel = Model:extend("departments", {
    timestamp = true,
    relations = {
        { "hospital", belongs_to = "HospitalModel", key = "hospital_id" },
        { "wards",    has_many = "WardModel",        key = "department_id" }
    }
})

function DepartmentModel:getByHospital(hospital_id)
    return self:select("WHERE hospital_id = ? AND status = 'active' ORDER BY name ASC", hospital_id)
end

function DepartmentModel:getWithParsedData(id)
    local dept = self:find(id)
    if not dept then return nil end

    if dept.specialties then
        local ok, parsed = pcall(cJson.decode, dept.specialties)
        if ok then dept.specialties = parsed end
    end
    if dept.operating_hours then
        local ok, parsed = pcall(cJson.decode, dept.operating_hours)
        if ok then dept.operating_hours = parsed end
    end

    return dept
end

return DepartmentModel
