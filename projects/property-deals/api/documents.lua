-- Documents on a deal / property (files in MinIO, gap map §2.12):
--   GET    /documents             list ?deal_uuid=&property_uuid=&task_uuid=&category=
--   POST   /documents             multipart: file + deal_uuid|property_uuid [+ task_uuid, category]
--   GET    /documents/:id         metadata + a short-lived download URL
--   DELETE /documents/:id         removes the record and the object
-- Objects are keyed property-deals/<namespace uuid>/<document uuid>/<filename>,
-- so one workspace's keys never collide with or overwrite another's.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local U = require("property_deals.util")

local CATEGORIES = { "title", "lease", "survey", "valuation", "epc", "searches", "id", "proof_of_funds", "aml",
                     "contract", "completion_statement", "photo", "correspondence", "other" }
local CATEGORY = {}
for _, c in ipairs(CATEGORIES) do CATEGORY[c] = true end

local MAX_BYTES = 25 * 1024 * 1024

local function sha256_hex(content)
    local sha = require("resty.sha256"):new()
    sha:update(content)
    return require("resty.string").to_hex(sha:final())
end

local function minio()
    return require("helper.minio").getDefault()
end

local function get(ns, id)
    if not U.is_uuid(id) then return nil end
    return U.one("SELECT * FROM property_deals_documents WHERE namespace_id = ? AND uuid = ?", ns, id)
end

return function(app)
    app:get("/documents", sdk.handler({ permission = "property_deals_properties.read" }, function(self)
        local p, ns = self.params, sdk.namespace_id(self)
        local where = { "namespace_id = " .. db.escape_literal(ns) }
        for _, col in ipairs({ "deal_uuid", "property_uuid", "task_uuid" }) do
            if U.is_uuid(p[col]) then where[#where + 1] = col .. " = " .. db.escape_literal(p[col]) end
        end
        if CATEGORY[p.category] then where[#where + 1] = "category = " .. db.escape_literal(p.category) end
        local page, per_page, offset = sdk.page(p)
        local w = table.concat(where, " AND ")
        local rows = db.query("SELECT * FROM property_deals_documents WHERE " .. w
            .. " ORDER BY created_at DESC, id DESC LIMIT " .. per_page .. " OFFSET " .. offset)
        local total = db.query("SELECT COUNT(*)::int AS n FROM property_deals_documents WHERE " .. w)[1].n
        return sdk.ok(sdk.array(rows), { page = page, per_page = per_page, total = total, total_pages = math.ceil(total / per_page) })
    end))

    app:post("/documents", sdk.handler({ permission = "property_deals_properties.create" }, U.guard(function(self)
        local file = self.params.file
        if type(file) ~= "table" or not file.content or file.content == "" then
            return sdk.error(400, "Send the file as multipart/form-data field 'file'")
        end
        if #file.content > MAX_BYTES then return sdk.error(413, "File is larger than 25 MB") end
        local data, errors = sdk.validate(self.params, {
            deal_uuid = { type = "uuid" }, property_uuid = { type = "uuid" }, task_uuid = { type = "uuid" },
            category = { enum = CATEGORIES },
        })
        if not data then return sdk.error(422, "Validation failed", errors) end
        if not data.deal_uuid and not data.property_uuid then
            return sdk.error(422, "Validation failed", { deal_uuid = "give deal_uuid or property_uuid" })
        end
        local ns = sdk.namespace_id(self)
        local ns_uuid = self.namespace.uuid
        local doc_uuid = require("helper.global").generateUUID()
        local safe_name = tostring(file.filename or "file"):gsub("[^%w%._%-]", "_"):sub(-120)
        local key = "property-deals/" .. ns_uuid .. "/" .. doc_uuid .. "/" .. safe_name

        -- Insert first (checks the references belong to this workspace), then upload.
        local row = db.insert("property_deals_documents", {
            uuid = doc_uuid, namespace_id = ns,
            deal_uuid = data.deal_uuid, property_uuid = data.property_uuid, task_uuid = data.task_uuid,
            category = data.category or "other", filename = tostring(file.filename or safe_name):sub(1, 255),
            mime_type = file.content_type, size_bytes = #file.content,
            sha256 = sha256_hex(file.content),
            object_key = key, source = "upload", uploaded_by_user_uuid = sdk.user(self).uuid,
        }, { returning = "*" })[1]
        local client = minio()
        local url, err = client:upload(file, { object_key = key, validate_type = false })
        if not url then
            db.query("DELETE FROM property_deals_documents WHERE id = ?", row.id)
            return sdk.error(502, "Could not store the file: " .. tostring(err))
        end
        db.update("property_deals_documents", { bucket = client.bucket }, { id = row.id })
        return sdk.created(get(ns, doc_uuid))
    end)))

    app:get("/documents/:id", sdk.handler({ permission = "property_deals_properties.read" }, function(self)
        local doc = get(sdk.namespace_id(self), self.params.id)
        if not doc then return sdk.not_found("Document") end
        doc.download_url = minio():getPresignedUrl(doc.object_key, 300, doc.bucket, true)
        return sdk.ok(doc)
    end))

    app:delete("/documents/:id", sdk.handler({ permission = "property_deals_properties.delete" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local doc = get(ns, self.params.id)
        if not doc then return sdk.not_found("Document") end
        db.query("DELETE FROM property_deals_documents WHERE namespace_id = ? AND uuid = ?", ns, doc.uuid)
        minio():delete(doc.object_key, doc.bucket)
        return sdk.ok()
    end)))
end
