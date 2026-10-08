--[[
    Billing & Entitlements — once-only licence key delivery (docs/BILLING_ENTITLEMENTS.md §10)
    =========================================================================================
    A key bought through Stripe Checkout is issued by the webhook, long before
    the buyer's browser asks for it. It waits here, AES-256-GCM encrypted
    (LICENCE_DELIVERY_KEY, the licence id as associated data), for at most
    24 hours. The success page reveals it once; the email job (if the app emails
    keys) decrypts it at send time. The row is deleted as soon as every channel
    has delivered it, and the maintenance job deletes whatever is left at 24 h.

      LICENCE_DELIVERY_KEY            32 random bytes, base64 (openssl rand -base64 32)
      LICENCE_DELIVERY_KEY_ID         its id, stored with each row (e.g. delivery-2026-10)
      LICENCE_DELIVERY_PREVIOUS_KEYS  "id:base64,id:base64" — old keys, readable until their rows expire
]]

local db = require("lapis.db")

local Delivery = {}

local function keys()
    local out = {}
    local cur, id = os.getenv("LICENCE_DELIVERY_KEY"), os.getenv("LICENCE_DELIVERY_KEY_ID")
    if cur and cur ~= "" then out[(id and id ~= "") and id or "default"] = ngx.decode_base64(cur) end
    for pair in (os.getenv("LICENCE_DELIVERY_PREVIOUS_KEYS") or ""):gmatch("[^,%s]+") do
        local kid, b64 = pair:match("^([^:]+):(.+)$")
        if kid then out[kid] = ngx.decode_base64(b64) end
    end
    return out, (id and id ~= "") and id or "default"
end

--- Whether keys can be delivered (a valid LICENCE_DELIVERY_KEY is set).
function Delivery.configured()
    local k, id = keys()
    return k[id] ~= nil and #k[id] == 32
end

local function b64(s) return ngx.encode_base64(s) end

--- Store a new key for `license_id`, bought in `session_id`. @return true | nil, err
function Delivery.store(license_id, session_id, raw_key, email)
    local all, kid = keys()
    local key = all[kid]
    if not key or #key ~= 32 then return nil, "LICENCE_DELIVERY_KEY is not set (32 bytes, base64)" end
    local nonce = require("resty.random").bytes(12, true)
    local c = assert(require("resty.openssl.cipher").new("aes-256-gcm"))
    local ct, err = c:encrypt(key, nonce, raw_key, false, tostring(license_id))
    if not ct then return nil, err end
    db.query([[INSERT INTO billing_key_deliveries (license_id, checkout_session_id, ciphertext, nonce, tag, key_id, email, expires_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, NOW() + interval '24 hours')
        ON CONFLICT (license_id) DO UPDATE SET checkout_session_id = EXCLUDED.checkout_session_id,
            ciphertext = EXCLUDED.ciphertext, nonce = EXCLUDED.nonce, tag = EXCLUDED.tag, key_id = EXCLUDED.key_id,
            email = EXCLUDED.email, revealed_at = NULL, emailed_at = NULL, expires_at = EXCLUDED.expires_at]],
        license_id, session_id, b64(ct), b64(nonce), b64(c:get_aead_tag()), kid, email == true)
    return true
end

local function decrypt(row)
    local key = keys()[row.key_id]
    if not key then return nil, "delivery key " .. tostring(row.key_id) .. " is no longer configured" end
    local c = assert(require("resty.openssl.cipher").new("aes-256-gcm"))
    local raw, err = c:decrypt(key, ngx.decode_base64(row.nonce), ngx.decode_base64(row.ciphertext), false,
        tostring(row.license_id), ngx.decode_base64(row.tag))
    if not raw then return nil, "could not decrypt the delivery: " .. tostring(err) end
    return raw
end

-- Delete once every channel has delivered (the page always; email if the app emails keys).
local function finish(license_id)
    db.query([[DELETE FROM billing_key_deliveries WHERE license_id = ? AND revealed_at IS NOT NULL
        AND (NOT email OR emailed_at IS NOT NULL)]], license_id)
end

--- The success page: the key bought in `session_id`, once. @return raw key | nil
function Delivery.reveal(session_id)
    local row = db.query([[UPDATE billing_key_deliveries SET revealed_at = NOW()
        WHERE checkout_session_id = ? AND revealed_at IS NULL AND expires_at > NOW() RETURNING *]], session_id)[1]
    if not row then return nil end
    local raw = decrypt(row)
    finish(row.license_id)
    return raw
end

--- The email job: the key for `license_id`, marked emailed. @return raw key | nil, err (nil, nil = nothing to send)
function Delivery.forEmail(license_id)
    local row = db.query([[SELECT * FROM billing_key_deliveries WHERE license_id = ? AND emailed_at IS NULL
        AND expires_at > NOW()]], license_id)[1]
    if not row then return nil end
    local raw, err = decrypt(row)
    if not raw then return nil, err end
    return raw
end

function Delivery.emailed(license_id)
    db.query("UPDATE billing_key_deliveries SET emailed_at = NOW() WHERE license_id = ?", license_id)
    finish(license_id)
end

function Delivery.purge()
    db.query("DELETE FROM billing_key_deliveries WHERE expires_at < NOW()")
end

return Delivery
