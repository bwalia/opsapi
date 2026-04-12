local Model = require("lapis.db.model").Model
local cJson = require("cjson")
local Global = require "helper.global"

local RoomBedModel = Model:extend("rooms_beds", {
    timestamp = true,
    relations = {
        { "hospital", belongs_to = "HospitalModel", key = "hospital_id" },
        { "ward",     belongs_to = "WardModel",      key = "ward_id" },
        { "patient",  belongs_to = "PatientModel",   key = "patient_id" }
    }
})

function RoomBedModel:getByWard(ward_id)
    return self:select("WHERE ward_id = ? ORDER BY room_number ASC, bed_number ASC", ward_id)
end

function RoomBedModel:getAvailable(ward_id)
    return self:select("WHERE ward_id = ? AND status = 'available' ORDER BY room_number ASC", ward_id)
end

function RoomBedModel:getByPatient(patient_id)
    return self:select("WHERE patient_id = ? AND status = 'occupied'", patient_id)
end

function RoomBedModel:getWithParsedData(id)
    local room = self:find(id)
    if not room then return nil end

    if room.equipment then
        local ok, parsed = pcall(cJson.decode, room.equipment)
        if ok then room.equipment = parsed end
    end

    return room
end

return RoomBedModel
