local Model = require("lapis.db.model").Model
local Global = require "helper.global"

local PatientDocumentModel = Model:extend("patient_documents", {
    timestamp = true,
    relations = {
        {"patient", belongs_to = "PatientModel", key = "patient_id"}
    }
})

-- Create a new patient document
function PatientDocumentModel:create(data)
    local document_data = {
        uuid = Global.generateUUID(),
        patient_id = data.patient_id,
        document_type = data.document_type,
        title = data.title,
        description = data.description,
        file_path = data.file_path,
        file_size = data.file_size,
        file_type = data.file_type,
        uploaded_by = data.uploaded_by,
        document_date = data.document_date,
        is_confidential = data.is_confidential or false,
        status = data.status or "active",
        created_at = Global.getCurrentTimestamp(),
        updated_at = Global.getCurrentTimestamp()
    }
    
    return self:create(document_data)
end

-- Update patient document
function PatientDocumentModel:update(document_id, data)
    local update_data = {}
    
    if data.document_type then update_data.document_type = data.document_type end
    if data.title then update_data.title = data.title end
    if data.description then update_data.description = data.description end
    if data.file_path then update_data.file_path = data.file_path end
    if data.file_size then update_data.file_size = data.file_size end
    if data.file_type then update_data.file_type = data.file_type end
    if data.uploaded_by then update_data.uploaded_by = data.uploaded_by end
    if data.document_date then update_data.document_date = data.document_date end
    if data.is_confidential ~= nil then update_data.is_confidential = data.is_confidential end
    if data.status then update_data.status = data.status end
    
    update_data.updated_at = Global.getCurrentTimestamp()
    
    return self:update(document_id, update_data)
end

-- Get documents by patient
function PatientDocumentModel:getByPatient(patient_id, limit, offset)
    local query = "WHERE patient_id = ? ORDER BY document_date DESC, created_at DESC"
    local params = {patient_id}
    
    if limit then
        query = query .. " LIMIT ?"
        table.insert(params, limit)
        
        if offset then
            query = query .. " OFFSET ?"
            table.insert(params, offset)
        end
    end
    
    return self:select(query, unpack(params))
end

-- Get documents by type
function PatientDocumentModel:getByType(patient_id, document_type)
    return self:select("WHERE patient_id = ? AND document_type = ? ORDER BY document_date DESC", patient_id, document_type)
end

-- Get confidential documents
function PatientDocumentModel:getConfidential(patient_id)
    return self:select("WHERE patient_id = ? AND is_confidential = true ORDER BY document_date DESC", patient_id)
end

-- Get public documents
function PatientDocumentModel:getPublic(patient_id)
    return self:select("WHERE patient_id = ? AND is_confidential = false ORDER BY document_date DESC", patient_id)
end

-- Search documents
function PatientDocumentModel:search(criteria)
    local conditions = {}
    local params = {}
    
    if criteria.patient_id then
        table.insert(conditions, "patient_id = ?")
        table.insert(params, criteria.patient_id)
    end
    
    if criteria.document_type then
        table.insert(conditions, "document_type = ?")
        table.insert(params, criteria.document_type)
    end
    
    if criteria.title then
        table.insert(conditions, "title ILIKE ?")
        table.insert(params, "%" .. criteria.title .. "%")
    end
    
    if criteria.uploaded_by then
        table.insert(conditions, "uploaded_by ILIKE ?")
        table.insert(params, "%" .. criteria.uploaded_by .. "%")
    end
    
    if criteria.is_confidential ~= nil then
        table.insert(conditions, "is_confidential = ?")
        table.insert(params, criteria.is_confidential)
    end
    
    if criteria.status then
        table.insert(conditions, "status = ?")
        table.insert(params, criteria.status)
    end
    
    if criteria.document_date_from then
        table.insert(conditions, "document_date >= ?")
        table.insert(params, criteria.document_date_from)
    end
    
    if criteria.document_date_to then
        table.insert(conditions, "document_date <= ?")
        table.insert(params, criteria.document_date_to)
    end
    
    local where_clause = ""
    if #conditions > 0 then
        where_clause = "WHERE " .. table.concat(conditions, " AND ")
    end
    
    local query = "SELECT * FROM patient_documents " .. where_clause .. " ORDER BY document_date DESC, created_at DESC"
    
    return self.db.select(query, unpack(params))
end

-- Get document statistics
function PatientDocumentModel:getStatistics(patient_id)
    local db = require("lapis.db")
    
    local stats = {}
    
    -- Total documents
    local total_documents = db.select("SELECT COUNT(*) as count FROM patient_documents WHERE patient_id = ?", patient_id)
    stats.total_documents = total_documents[1] and total_documents[1].count or 0
    
    -- Documents by type
    local documents_by_type = db.select("SELECT document_type, COUNT(*) as count FROM patient_documents WHERE patient_id = ? GROUP BY document_type", patient_id)
    stats.by_type = {}
    for _, row in ipairs(documents_by_type) do
        stats.by_type[row.document_type] = row.count
    end
    
    -- Confidential documents
    local confidential_docs = db.select("SELECT COUNT(*) as count FROM patient_documents WHERE patient_id = ? AND is_confidential = true", patient_id)
    stats.confidential_documents = confidential_docs[1] and confidential_docs[1].count or 0
    
    -- Recent documents (last 30 days)
    local recent_documents = db.select("SELECT COUNT(*) as count FROM patient_documents WHERE patient_id = ? AND created_at >= CURRENT_DATE - INTERVAL '30 days'", patient_id)
    stats.recent_documents = recent_documents[1] and recent_documents[1].count or 0
    
    return stats
end

-- Get documents by date range
function PatientDocumentModel:getByDateRange(patient_id, start_date, end_date)
    return self:select("WHERE patient_id = ? AND document_date >= ? AND document_date <= ? ORDER BY document_date DESC", 
        patient_id, start_date, end_date)
end

-- Archive document
function PatientDocumentModel:archive(document_id)
    local update_data = {
        status = "archived",
        updated_at = Global.getCurrentTimestamp()
    }
    
    return self:update(document_id, update_data)
end

-- Restore document
function PatientDocumentModel:restore(document_id)
    local update_data = {
        status = "active",
        updated_at = Global.getCurrentTimestamp()
    }
    
    return self:update(document_id, update_data)
end

-- Get document types
function PatientDocumentModel:getDocumentTypes()
    local db = require("lapis.db")
    
    local result = db.select("SELECT DISTINCT document_type FROM patient_documents ORDER BY document_type ASC")
    local types = {}
    
    for _, row in ipairs(result) do
        table.insert(types, row.document_type)
    end
    
    return types
end

-- Get recent documents
function PatientDocumentModel:getRecent(patient_id, limit)
    limit = limit or 10
    
    return self:select("WHERE patient_id = ? ORDER BY created_at DESC LIMIT ?", patient_id, limit)
end

return PatientDocumentModel
