local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local sdk = require("helper.plugin-sdk")
local Images = require("opsapi_marketing.images")

return function(app)
    -- Upload an image for an email: { file_name, content_base64 } -> { uuid, url }.
    app:post("/images", sdk.handler({ permission = "opsapi_marketing_templates.create" }, function(self)
        local body, berr = sdk.body(self)
        if not body then return sdk.error(400, berr) end
        local b64 = type(body.content_base64) == "string" and body.content_base64:gsub("^data:[^,]*,", "")
        local bytes = b64 and ngx.decode_base64(b64)
        if not bytes or #bytes == 0 then return sdk.error(400, "content_base64 (the image, base64) is required") end
        if #bytes > Images.MAX_BYTES then return sdk.error(413, "Images can be up to 2 MB") end
        local user = sdk.user(self)
        local row, err = Images.save(sdk.namespace_id(self), body.file_name, bytes, user and user.uuid)
        if not row then return sdk.error(err == "Could not store the image" and 502 or 400, err) end
        return sdk.ok(row)
    end))
end
