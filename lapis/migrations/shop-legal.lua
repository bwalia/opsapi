--[[
    Shop legal acceptances (FEATURES.SHOP)
    ======================================

    [1] shop_legal_acceptances — append-only evidence of every legal confirmation a customer ticks in the
        shop or on the website: one row per document per acceptance.

          email             who (lower-cased; shop customers are identified by email)
          document_key      e.g. terms-of-sale, privacy-notice, trade-terms, ai-assistant
          document_version  the version the customer saw (the shop decides which is current)
          content_hash      sha256 of the document text they saw, when the shop has it
          statement         the exact sentence they ticked
          checkpoint        register | quote | checkout | trade_join | chat | enquiry | contact
          subject_ref       cart / quote / chat uuid the acceptance was given for
          client_ip, user_agent   the customer's, forwarded by the shop server

        Rows are never updated (a trigger refuses UPDATE). They are deleted only with the namespace or by
        an erasure request.

    Registered in migrations.lua as zzs37. Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_legal_acceptances (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                email varchar(254) NOT NULL,
                document_key varchar(48) NOT NULL,
                document_version varchar(32) NOT NULL,
                content_hash varchar(64),
                statement text NOT NULL,
                checkpoint varchar(16) NOT NULL
                    CHECK (checkpoint IN ('register', 'quote', 'checkout', 'trade_join', 'chat', 'enquiry', 'contact')),
                subject_ref varchar(64),
                client_ip varchar(64),
                user_agent varchar(400),
                created_at timestamptz NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS shop_legal_acceptances_email_key_idx
                ON shop_legal_acceptances (namespace_id, lower(email), document_key, created_at DESC)
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS shop_legal_acceptances_created_idx
                ON shop_legal_acceptances (namespace_id, created_at DESC)
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS shop_legal_acceptances_subject_idx
                ON shop_legal_acceptances (namespace_id, subject_ref) WHERE subject_ref IS NOT NULL
        ]])
        db.query([[
            CREATE OR REPLACE FUNCTION shop_legal_acceptances_no_update() RETURNS trigger AS $$
            BEGIN
                RAISE EXCEPTION 'shop_legal_acceptances is append-only';
            END;
            $$ LANGUAGE plpgsql
        ]])
        db.query([[DROP TRIGGER IF EXISTS shop_legal_acceptances_append_only ON shop_legal_acceptances]])
        db.query([[
            CREATE TRIGGER shop_legal_acceptances_append_only
                BEFORE UPDATE ON shop_legal_acceptances
                FOR EACH ROW EXECUTE FUNCTION shop_legal_acceptances_no_update()
        ]])
    end,
}
