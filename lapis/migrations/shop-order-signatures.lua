--[[
    Proof of delivery: the customer's signature on a shop order (FEATURES.SHOP)
    ===========================================================================
    See queries/ShopOrderSignatureQueries.lua.

    [1] shop_order_signatures
          signer_name        who signed (typed by them or the member of staff handing over)
          image_key          the signature (PNG) in the deployment's MinIO; never public
          image_sha256       its fingerprint, recorded when it was taken
          note               e.g. "left with reception", "2 boxes, one damaged"
          captured_by_*      the member of staff who took it, from where (ip, user agent)
          voided_*           taken back (wrong order, wrong person): kept for the record, never deleted
        One signature in force per order (partial unique index).

    Registered in migrations.lua as zzs63. Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_order_signatures (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                order_id integer NOT NULL REFERENCES shop_orders(id) ON DELETE CASCADE,
                signer_name varchar(120) NOT NULL,
                image_key text NOT NULL,
                image_sha256 varchar(64) NOT NULL,
                image_bytes integer NOT NULL,
                note text CHECK (note IS NULL OR char_length(note) <= 1000),
                captured_by_user_id integer,
                captured_by varchar(254),
                ip_address varchar(64),
                user_agent varchar(500),
                created_at timestamptz NOT NULL DEFAULT NOW(),
                voided_at timestamptz,
                voided_by varchar(254),
                void_reason text
            )
        ]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS shop_order_signatures_one_live
                   ON shop_order_signatures (order_id) WHERE voided_at IS NULL]])
        db.query([[CREATE INDEX IF NOT EXISTS shop_order_signatures_ns_idx
                   ON shop_order_signatures (namespace_id, created_at)]])
    end,
}
