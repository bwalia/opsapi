--[[
    Does a table exist? For code that reads tables another product owns
    (e.g. diy-tax-return-uk's dms_documents): deployments without them must
    keep working instead of failing every request.

    Pass a column too — exists("dms_documents", "bank_account_uuid") — when the
    other product adds columns in later migrations than the table itself.

    Cached per worker: a found table stays found; a missing one is re-checked
    after a minute, so creating it later is picked up without a restart.
]]

local db = require("lapis.db")

local found, checked_at = {}, {}

return function(name, column)
    local key = column and (name .. "." .. column) or name
    if found[key] then return true end
    local now = ngx and ngx.now() or os.time()
    if checked_at[key] and now - checked_at[key] < 60 then return false end
    checked_at[key] = now
    local ok, rows
    if column then
        ok, rows = pcall(db.query, [[SELECT EXISTS (SELECT 1 FROM information_schema.columns
            WHERE table_schema = current_schema() AND table_name = ? AND column_name = ?) AS ok]], name, column)
    else
        ok, rows = pcall(db.query, "SELECT to_regclass(?) IS NOT NULL AS ok", name)
    end
    found[key] = ok and rows[1] and rows[1].ok == true or nil
    return found[key] == true
end
