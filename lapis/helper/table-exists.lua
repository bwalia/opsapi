--[[
    Does a table exist? For code that reads tables another product owns
    (e.g. diy-tax-return-uk's dms_documents): deployments without them must
    keep working instead of failing every request.

    Cached per worker: a found table stays found; a missing one is re-checked
    after a minute, so creating it later is picked up without a restart.
]]

local db = require("lapis.db")

local found, checked_at = {}, {}

return function(name)
    if found[name] then return true end
    local now = ngx and ngx.now() or os.time()
    if checked_at[name] and now - checked_at[name] < 60 then return false end
    checked_at[name] = now
    local ok, rows = pcall(db.query, "SELECT to_regclass(?) IS NOT NULL AS ok", name)
    found[name] = ok and rows[1] and rows[1].ok == true or nil
    return found[name] == true
end
