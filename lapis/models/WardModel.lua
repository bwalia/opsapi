local Model = require("lapis.db.model").Model
local cJson = require("cjson")
local Global = require "helper.global"

local WardModel = Model:extend("wards", {
    timestamp = true,
    relations = {
        { "hospital",   belongs_to = "HospitalModel",   key = "hospital_id" },
        { "department", belongs_to = "DepartmentModel",  key = "department_id" },
        { "rooms_beds", has_many = "RoomBedModel",       key = "ward_id" }
    }
})

function WardModel:getByHospital(hospital_id)
    return self:select("WHERE hospital_id = ? AND status = 'active' ORDER BY name ASC", hospital_id)
end

function WardModel:getByDepartment(department_id)
    return self:select("WHERE department_id = ? AND status = 'active' ORDER BY name ASC", department_id)
end

function WardModel:getWithParsedData(id)
    local ward = self:find(id)
    if not ward then return nil end

    if ward.visiting_hours then
        local ok, parsed = pcall(cJson.decode, ward.visiting_hours)
        if ok then ward.visiting_hours = parsed end
    end
    if ward.restrictions then
        local ok, parsed = pcall(cJson.decode, ward.restrictions)
        if ok then ward.restrictions = parsed end
    end

    return ward
end

return WardModel
