-- luacheck: max line length 160
--[[
    Proof of delivery: the customer signs for their order
    =====================================================
    On the order page (dashboard, or the CRM app's web view on a phone or tablet) a member of staff
    hands over the goods, the customer signs on the screen and types (or says) their name. We keep:

      the signature      a PNG in the deployment's MinIO (shop/signatures/<workspace>/<order uuid>/<uuid>.png),
                         never public: staff read it through GET /orders/:uuid/signature/image (shop read)
      its fingerprint    SHA-256 of the PNG, taken when it was signed (shows the file wasn't swapped)
      who and when       the signer's name, the member of staff, the time, IP address and device
      a note             e.g. "left with reception", "one box damaged"

    Signing marks the order delivered (unless staff untick it) and adds "Received and signed for by <name>."
    to the customer's order updates. One signature in force per order: a wrong one is voided with a reason
    (kept for the record, and that update is hidden from the customer) before a new one is taken. Table: migrations/shop-order-signatures.lua.

      get(ns_id, order_uuid)                          the signature in force, or null
      capture(ns_id, order_uuid, body, actor, user_id, client)
                                                      body { signer_name, image (PNG data URL or base64), note?,
                                                      mark_delivered? (default true) }
      image(ns_id, order_uuid)                        the PNG bytes
      void(ns_id, order_uuid, body, actor)            body { reason }

    Functions return (value) or (nil, err) where err = U.err(status, code, message). Specced by
    spec/shop-order-signature_spec.lua.
]]

local db = require("lapis.db")
local Global = require("helper.global")
local U = require("lib.shop-util")

local Q = {}

Q.MAX_BYTES = 300 * 1024
Q.MIN_BYTES = 200 -- an empty canvas is about 100 bytes
Q.NAME_MAX = 120
Q.NOTE_MAX = 1000
-- An order can be signed for unless it never went ahead.
Q.UNSIGNABLE = { cancelled = true, refunded = true, payment_failed = true }

local PNG_MAGIC = "\137PNG\r\n\26\n"

local function clean(v, max)
    if type(v) ~= "string" then return nil end
    v = v:gsub("[%c]", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
    if v == "" then return nil end
    return U.cut(v, max)
end
Q.clean = clean

local function be32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

--- A PNG from a data URL ("data:image/png;base64,...") or bare base64. → bytes | nil, message
function Q.decode_png(v, decode64)
    if type(v) ~= "string" or v == "" then return nil, "Ask the customer to sign in the box first" end
    local b64 = v:match("^data:image/png;base64,(.+)$") or v
    if #b64 > math.ceil(Q.MAX_BYTES / 3) * 4 + 4 then return nil, "The signature is too large" end
    if b64:find("[^%w%+/=\r\n]") then return nil, "The signature isn't a PNG image" end
    local bytes = decode64(b64:gsub("[\r\n]", ""))
    if type(bytes) ~= "string" or bytes:sub(1, 8) ~= PNG_MAGIC or bytes:sub(13, 16) ~= "IHDR" then
        return nil, "The signature isn't a PNG image"
    end
    if #bytes > Q.MAX_BYTES then return nil, "The signature is too large" end
    if #bytes < Q.MIN_BYTES then return nil, "The signature box is empty. Ask the customer to sign." end
    local w, h = be32(bytes, 17), be32(bytes, 21)
    if w < 50 or h < 30 or w > 4000 or h > 4000 then return nil, "The signature image has an odd size" end
    return bytes
end

local function sha256hex(s)
    local d = assert(require("resty.openssl.digest").new("sha256"))
    return (d:final(s):gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function storage()
    local Minio = require("helper.minio")
    local name = os.getenv("SHOP_FILES_BUCKET") or os.getenv("MINIO_BUCKET")
    local c = Minio.new({ bucket = (name and name ~= "") and name or nil })
    if not c:validate() then return nil end
    return c
end

local function order_for(ns_id, order_uuid)
    if type(order_uuid) ~= "string" or order_uuid == "" then return nil end
    return db.query("SELECT id, uuid, namespace_id, status, order_number FROM shop_orders WHERE namespace_id = ? AND uuid = ?",
        ns_id, order_uuid)[1]
end

local function live(order_id)
    return db.query([[SELECT uuid, signer_name, image_key, image_sha256, image_bytes, note, captured_by,
        to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS signed_at
        FROM shop_order_signatures WHERE order_id = ? AND voided_at IS NULL]], order_id)[1]
end

local function shape(r)
    if not r then return U.null end
    return { uuid = r.uuid, signer_name = r.signer_name, note = U.nz(r.note) or U.null, signed_at = r.signed_at,
             captured_by = U.nz(r.captured_by) or U.null, image_sha256 = r.image_sha256, image_bytes = tonumber(r.image_bytes) }
end

function Q.get(ns_id, order_uuid)
    local o = order_for(ns_id, order_uuid)
    if not o then return nil, U.err(404, "NOT_FOUND", "Order not found") end
    return { signature = shape(live(o.id)), can_sign = not Q.UNSIGNABLE[o.status], status = o.status }
end

--- client = { ip, user_agent } of the device it was signed on.
function Q.capture(ns_id, order_uuid, body, actor, user_id, client)
    body = type(body) == "table" and body or {}
    local name = clean(body.signer_name, Q.NAME_MAX)
    if not name or #name < 2 then
        return nil, U.err(400, "VALIDATION_ERROR", "Type the name of the person signing", { field = "signer_name" })
    end
    local note = clean(body.note, Q.NOTE_MAX)
    local png, perr = Q.decode_png(body.image, ngx.decode_base64)
    if not png then return nil, U.err(400, "VALIDATION_ERROR", perr, { field = "image" }) end

    local o = order_for(ns_id, order_uuid)
    if not o then return nil, U.err(404, "NOT_FOUND", "Order not found") end
    if Q.UNSIGNABLE[o.status] then
        return nil, U.err(409, "ORDER_NOT_SIGNABLE", "This order is " .. o.status:gsub("_", " ") .. ", so it can't be signed for")
    end
    if live(o.id) then
        return nil, U.err(409, "ALREADY_SIGNED", "This order is already signed for. Void that signature first to take a new one.")
    end

    local c = storage()
    if not c then return nil, U.err(503, "STORAGE_UNAVAILABLE", "File storage isn't set up here, so the signature can't be kept") end
    local uuid = Global.generateUUID()
    local key = ("shop/signatures/%s/%s/%s.png"):format(tostring(ns_id), o.uuid, uuid)
    local _, uerr, info = c:upload({ content = png, filename = "signature.png", content_type = "image/png" },
        { object_key = key, validate_type = false, max_size = Q.MAX_BYTES + 1 })
    if not info then
        ngx.log(ngx.ERR, "[shop] signature store failed: ", tostring(uerr))
        return nil, U.err(503, "STORAGE_FAILED", "The signature couldn't be saved. Try again.")
    end
    key = info.key or key

    local mark = body.mark_delivered ~= false
    client = client or {}
    -- U.tx returns (nil, err) for a refusal and re-raises anything else: either way the stored file goes.
    local tok, done, err = pcall(U.tx, function()
        local ok, ierr = pcall(db.query, [[
            INSERT INTO shop_order_signatures (uuid, namespace_id, order_id, signer_name, image_key, image_sha256, image_bytes,
                note, captured_by_user_id, captured_by, ip_address, user_agent)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
            uuid, ns_id, o.id, name, key, sha256hex(png), #png, note or db.NULL, tonumber(user_id) or db.NULL,
            U.nz(actor) and U.cut(tostring(actor), 254) or db.NULL,
            U.nz(client.ip) and U.cut(tostring(client.ip), 64) or db.NULL,
            U.nz(client.user_agent) and U.cut(tostring(client.user_agent), 500) or db.NULL)
        if not ok then
            if tostring(ierr):find("shop_order_signatures_one_live", 1, true) then
                return nil, U.err(409, "ALREADY_SIGNED", "This order was signed for a moment ago. Reload the page.")
            end
            error(ierr, 0)
        end
        local Events = require("queries.ShopOrderEventQueries")
        local message = "Received and signed for by " .. name .. "."
        if mark and o.status ~= "delivered" then
            db.query("UPDATE shop_orders SET status = 'delivered', updated_at = NOW() WHERE id = ?", o.id)
            Events.record(o, "status", { status = "delivered", message = message, author = actor, author_user_id = user_id })
        else
            Events.record(o, "comment", { message = message, author = actor, author_user_id = user_id })
        end
        return true
    end)
    if not tok or not done then
        pcall(c.delete, c, key)
        if not tok then
            ngx.log(ngx.ERR, "[shop] signature save failed: ", tostring(done))
            return nil, U.err(500, "SIGNATURE_FAILED", "The signature couldn't be saved. Try again.")
        end
        return nil, err
    end
    return Q.get(ns_id, order_uuid)
end

function Q.image(ns_id, order_uuid)
    local o = order_for(ns_id, order_uuid)
    if not o then return nil, U.err(404, "NOT_FOUND", "Order not found") end
    local s = live(o.id)
    if not s then return nil, U.err(404, "NOT_FOUND", "This order hasn't been signed for") end
    local c = storage()
    if not c then return nil, U.err(503, "STORAGE_UNAVAILABLE", "File storage isn't set up here") end
    local bytes, gerr = c:get(s.image_key)
    if not bytes then
        ngx.log(ngx.ERR, "[shop] signature read failed: ", tostring(gerr))
        return nil, U.err(503, "STORAGE_FAILED", "The signature couldn't be read. Try again shortly.")
    end
    return bytes
end

function Q.void(ns_id, order_uuid, body, actor)
    body = type(body) == "table" and body or {}
    local reason = clean(body.reason, 500)
    if not reason or #reason < 3 then
        return nil, U.err(400, "VALIDATION_ERROR", "Say why this signature is being taken back", { field = "reason" })
    end
    local o = order_for(ns_id, order_uuid)
    if not o then return nil, U.err(404, "NOT_FOUND", "Order not found") end
    local by = U.nz(actor) and U.cut(tostring(actor), 254) or db.NULL
    local r = db.query([[UPDATE shop_order_signatures SET voided_at = NOW(), voided_by = ?, void_reason = ?
        WHERE order_id = ? AND voided_at IS NULL RETURNING uuid, signer_name]], by, reason, o.id)[1]
    if not r then return nil, U.err(404, "NOT_FOUND", "This order hasn't been signed for") end
    -- The customer no longer reads "signed for by …" on their order page (the event is kept, hidden).
    pcall(db.query, [[UPDATE shop_order_events SET deleted_at = NOW(), deleted_by = ?
        WHERE order_id = ? AND deleted_at IS NULL AND message = ?]], by, o.id, "Received and signed for by " .. r.signer_name .. ".")
    return Q.get(ns_id, order_uuid)
end

return Q
