--[[
    Per-worker cache of the public form payload (GET /api/v2/public/forms/:id).
    A published version never changes, so a short TTL is safe; publishing,
    closing or deleting drops this worker's entry at once, and other workers
    and pods catch up within TTL seconds. Submissions never use it: they
    re-read the form and re-check its state in the same UPDATE that counts them.
]]

local TTL = 15
local ok, lrucache = pcall(require, "resty.lrucache")
local cache = ok and lrucache.new(2000) or nil

local PublicCache = {}

function PublicCache.get(public_id)
    return cache and cache:get(public_id)
end

function PublicCache.set(public_id, value)
    if cache then cache:set(public_id, value, TTL) end
end

function PublicCache.bust(public_id)
    if cache and public_id then cache:delete(public_id) end
end

return PublicCache
