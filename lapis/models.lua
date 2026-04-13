local autoload = require("lapis.util").autoload

-- Hospital CRM Models
local HospitalModel = require("models.HospitalModel")
local PatientModel = require("models.PatientModel")
local PatientHealthRecordModel = require("models.PatientHealthRecordModel")
local HospitalStaffModel = require("models.HospitalStaffModel")
local PatientAssignmentModel = require("models.PatientAssignmentModel")
local PatientAppointmentModel = require("models.PatientAppointmentModel")
local PatientDocumentModel = require("models.PatientDocumentModel")

return autoload("models")
