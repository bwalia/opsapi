local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local sdk = require("helper.plugin-sdk")
local Merge = require("opsapi_marketing.merge_fields")

return function(app)
    app:get("/merge-fields", sdk.handler({ permission = "opsapi_marketing_templates.read" }, function(self)
        local ns = sdk.namespace_id(self)
        Merge.ensure_defaults(ns)
        return sdk.ok(sdk.array(Merge.for_namespace(ns)))
    end))

    app:post("/merge-fields", sdk.handler({ permission = "opsapi_marketing_templates.create" }, function(self)
        local ns = sdk.namespace_id(self)
        local body = sdk.body(self) or {}
        local d, errors = sdk.validate(body, {
            key = { type = "string", required = true, max = 128 },
            label = { type = "string", required = true, max = 255 },
            field_type = { type = "string", enum = { "string", "number", "date", "boolean", "currency" } },
            source_path = { type = "string", max = 255 },
            default_value = { type = "string", max = 500 },
            allow_html = { type = "boolean" },
        })
        if not d then return { status = 422, json = { success = false, errors = errors } } end
        local row, err = Merge.upsert(ns, d)
        if not row then return sdk.error(400, err) end
        return sdk.created(row)
    end))

    app:post("/merge-fields/validate", sdk.handler({ permission = "opsapi_marketing_templates.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local body = sdk.body(self) or {}
        local ok, info = Merge.validate_template(ns, body)
        return sdk.ok({ valid = ok, unknown = info.unknown or {}, fields = info.fields or {} })
    end))
end
