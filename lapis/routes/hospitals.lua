local HospitalModel = require("models.HospitalModel")
local Global = require("helper.global")

return function(app)
    ----------------- Hospital Routes --------------------

    -- Get all hospitals
    app:get("/hospitals", function(self)
        local page = tonumber(self.params.page) or 1
        local per_page = tonumber(self.params.per_page) or 20
        local offset = (page - 1) * per_page
        
        local hospitals = HospitalModel:select("ORDER BY name ASC LIMIT ? OFFSET ?", per_page, offset)
        
        -- Parse JSON fields for each hospital
        for _, hospital in ipairs(hospitals) do
            if hospital.specialties then
                local ok, parsed = pcall(cJson.decode, hospital.specialties)
                if ok then hospital.specialties = parsed end
            end
            if hospital.services then
                local ok, parsed = pcall(cJson.decode, hospital.services)
                if ok then hospital.services = parsed end
            end
            if hospital.facilities then
                local ok, parsed = pcall(cJson.decode, hospital.facilities)
                if ok then hospital.facilities = parsed end
            end
            if hospital.operating_hours then
                local ok, parsed = pcall(cJson.decode, hospital.operating_hours)
                if ok then hospital.operating_hours = parsed end
            end
        end
        
        local total = HospitalModel:count()
        
        return {
            json = {
                hospitals = hospitals,
                pagination = {
                    page = page,
                    per_page = per_page,
                    total = total,
                    total_pages = math.ceil(total / per_page)
                }
            }
        }
    end)

    -- Get hospital by ID
    app:get("/hospitals/:id", function(self)
        local hospital = HospitalModel:getWithParsedData(self.params.id)
        
        if not hospital then
            return {
                status = 404,
                json = {
                    error = "Hospital not found"
                }
            }
        end
        
        return {
            json = {
                hospital = hospital
            }
        }
    end)

    -- Create new hospital
    app:post("/hospitals", function(self)
        local data = self.params
        
        -- Validate required fields
        if not data.name or not data.license_number or not data.address or not data.city or not data.state or not data.country or not data.phone or not data.email then
            return {
                status = 400,
                json = {
                    error = "Missing required fields: name, license_number, address, city, state, country, phone, email"
                }
            }
        end
        
        -- Check if license number already exists
        local existing = HospitalModel:select("WHERE license_number = ?", data.license_number)
        if #existing > 0 then
            return {
                status = 400,
                json = {
                    error = "Hospital with this license number already exists"
                }
            }
        end
        
        local hospital = HospitalModel:create(data)
        
        if hospital then
            return {
                status = 201,
                json = {
                    message = "Hospital created successfully",
                    hospital = hospital
                }
            }
        else
            return {
                status = 500,
                json = {
                    error = "Failed to create hospital"
                }
            }
        end
    end)

    -- Update hospital
    app:put("/hospitals/:id", function(self)
        local hospital_id = self.params.id
        local data = self.params
        
        local hospital = HospitalModel:find(hospital_id)
        if not hospital then
            return {
                status = 404,
                json = {
                    error = "Hospital not found"
                }
            }
        end
        
        -- Check if license number is being changed and if it already exists
        if data.license_number and data.license_number ~= hospital.license_number then
            local existing = HospitalModel:select("WHERE license_number = ? AND id != ?", data.license_number, hospital_id)
            if #existing > 0 then
                return {
                    status = 400,
                    json = {
                        error = "Hospital with this license number already exists"
                    }
                }
            end
        end
        
        local updated_hospital = HospitalModel:update(hospital_id, data)
        
        if updated_hospital then
            return {
                json = {
                    message = "Hospital updated successfully",
                    hospital = updated_hospital
                }
            }
        else
            return {
                status = 500,
                json = {
                    error = "Failed to update hospital"
                }
            }
        end
    end)

    -- Delete hospital
    app:delete("/hospitals/:id", function(self)
        local hospital_id = self.params.id
        
        local hospital = HospitalModel:find(hospital_id)
        if not hospital then
            return {
                status = 404,
                json = {
                    error = "Hospital not found"
                }
            }
        end
        
        local deleted = HospitalModel:delete(hospital_id)
        
        if deleted then
            return {
                json = {
                    message = "Hospital deleted successfully"
                }
            }
        else
            return {
                status = 500,
                json = {
                    error = "Failed to delete hospital"
                }
            }
        end
    end)

    -- Search hospitals
    app:get("/hospitals/search", function(self)
        local criteria = {
            name = self.params.name,
            type = self.params.type,
            city = self.params.city,
            state = self.params.state,
            emergency_services = self.params.emergency_services,
            status = self.params.status
        }
        
        local hospitals = HospitalModel:search(criteria)
        
        return {
            json = {
                hospitals = hospitals
            }
        }
    end)

    -- Get hospitals by type
    app:get("/hospitals/type/:type", function(self)
        local hospitals = HospitalModel:getByType(self.params.type)
        
        return {
            json = {
                hospitals = hospitals
            }
        }
    end)

    -- Get active hospitals
    app:get("/hospitals/active", function(self)
        local hospitals = HospitalModel:getActive()
        
        return {
            json = {
                hospitals = hospitals
            }
        }
    end)

    -- Get hospital statistics
    app:get("/hospitals/:id/statistics", function(self)
        local hospital_id = self.params.id
        
        local hospital = HospitalModel:find(hospital_id)
        if not hospital then
            return {
                status = 404,
                json = {
                    error = "Hospital not found"
                }
            }
        end
        
        local stats = HospitalModel:getStatistics(hospital_id)
        
        return {
            json = {
                statistics = stats
            }
        }
    end)

    -- Get hospital staff
    app:get("/hospitals/:id/staff", function(self)
        local hospital_id = self.params.id
        
        local hospital = HospitalModel:find(hospital_id)
        if not hospital then
            return {
                status = 404,
                json = {
                    error = "Hospital not found"
                }
            }
        end
        
        local HospitalStaffModel = require("models.HospitalStaffModel")
        local staff = HospitalStaffModel:getByHospital(hospital_id)
        
        return {
            json = {
                staff = staff
            }
        }
    end)

    -- Get hospital patients
    app:get("/hospitals/:id/patients", function(self)
        local hospital_id = self.params.id
        
        local hospital = HospitalModel:find(hospital_id)
        if not hospital then
            return {
                status = 404,
                json = {
                    error = "Hospital not found"
                }
            }
        end
        
        local PatientModel = require("models.PatientModel")
        local patients = PatientModel:getByHospital(hospital_id)
        
        return {
            json = {
                patients = patients
            }
        }
    end)

    -- Get hospital appointments
    app:get("/hospitals/:id/appointments", function(self)
        local hospital_id = self.params.id
        local date = self.params.date
        
        local hospital = HospitalModel:find(hospital_id)
        if not hospital then
            return {
                status = 404,
                json = {
                    error = "Hospital not found"
                }
            }
        end
        
        local PatientAppointmentModel = require("models.PatientAppointmentModel")
        local appointments
        
        if date then
            appointments = PatientAppointmentModel:getByDate(date, hospital_id)
        else
            appointments = PatientAppointmentModel:getUpcoming(hospital_id, 7)
        end
        
        return {
            json = {
                appointments = appointments
            }
        }
    end)
end
