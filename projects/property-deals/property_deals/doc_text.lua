-- Text of a stored document (MinIO) for the document checker and compliance
-- assistant: PDFs through pdftotext with "[page N]" markers (so flags can cite
-- pages), text files as they are. Read-only; the text is untrusted data.
local db = require("lapis.db")

local D = {}

local MAX_BYTES = 25 * 1024 * 1024

local function fetch(doc)
    local minio = require("helper.minio").getDefault()
    if not minio then return nil, "file storage is not configured" end
    local url = minio:getPresignedUrl(doc.object_key, 120, doc.bucket ~= db.NULL and doc.bucket or nil, false)
    if not url then return nil, "no download link" end
    local httpc = require("resty.http").new()
    httpc:set_timeout(30000)
    local res, err = httpc:request_uri(url, { method = "GET" })
    if not res then return nil, "download failed: " .. tostring(err) end
    if res.status ~= 200 then return nil, "download failed: HTTP " .. res.status end
    if #(res.body or "") > MAX_BYTES then return nil, "file too large" end
    return res.body
end

local function pdf_text(bytes, max_pages)
    local tmp = os.tmpname()
    local f = io.open(tmp, "wb")
    if not f then return nil, "can't write a temp file" end
    f:write(bytes)
    f:close()
    local pipe = require("ngx.pipe")
    local proc, err = pipe.spawn({ "pdftotext", "-layout", "-enc", "UTF-8", "-l", tostring(max_pages), tmp, "-" })
    if not proc then os.remove(tmp); return nil, "pdftotext: " .. tostring(err) end
    proc:set_timeouts(nil, 30000, 30000, 30000)
    local out, rerr = proc:stdout_read_all()
    proc:wait()
    os.remove(tmp)
    if not out then return nil, "pdftotext: " .. tostring(rerr) end
    local pages, n = {}, 0
    for page in (out .. "\f"):gmatch("(.-)\f") do
        n = n + 1
        if page:match("%S") then pages[#pages + 1] = "[page " .. n .. "]\n" .. page end
    end
    return table.concat(pages, "\n"), n
end

--- @return text, pages | nil, err
function D.text(doc, max_pages)
    max_pages = math.max(1, math.min(200, tonumber(max_pages) or 60))
    local bytes, err = fetch(doc)
    if not bytes then return nil, err end
    local mime = tostring(doc.mime_type or "")
    if mime == "application/pdf" or bytes:sub(1, 5) == "%PDF-" then return pdf_text(bytes, max_pages) end
    if mime:match("^text/") or mime == "application/json" then return bytes, 1 end
    return nil, "can't read " .. mime .. " (PDF or text only)"
end

return D
