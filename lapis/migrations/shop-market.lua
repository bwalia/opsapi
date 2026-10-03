--[[
    Shop market-price RAG migrations (FEATURES.SHOP)
    ================================================

    Pinned third-party catalogue sources per shop product and the price/stock
    observations a worker scrapes from them. Contract: workstation-website
    shop/MARKET.prompt.md §A. Registered in migrations.lua after the
    shop-system entries (zzs14/zzs15) and gated on FEATURES.SHOP.

    Idempotent (CREATE ... IF NOT EXISTS) so `lapis migrate` can be re-run.

    Tables: shop_market_sources, shop_market_observations.
]]

local db = require("lapis.db")

return {
    -- [1] sources ------------------------------------------------------------
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_market_sources (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                product_id integer NOT NULL REFERENCES shop_products(id) ON DELETE CASCADE,
                name varchar(255) NOT NULL,
                url text NOT NULL,
                fetch_mode varchar(16) NOT NULL DEFAULT 'direct'
                    CHECK (fetch_mode IN ('direct','firecrawl')),
                prices_include_vat boolean NOT NULL DEFAULT true,
                currency varchar(3) NOT NULL DEFAULT 'GBP',
                match jsonb NOT NULL DEFAULT '{}'::jsonb,
                is_active boolean NOT NULL DEFAULT true,
                last_checked_at timestamptz,
                last_status varchar(16)
                    CHECK (last_status IS NULL OR last_status IN
                        ('ok','no_price','mismatch','http_error','blocked','rejected','anomaly')),
                last_error text,
                created_at timestamp NOT NULL DEFAULT NOW(),
                updated_at timestamp NOT NULL DEFAULT NOW(),
                UNIQUE (namespace_id, product_id, url)
            )
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS shop_market_sources_due_idx
                ON shop_market_sources (namespace_id, is_active, last_checked_at)
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS shop_market_sources_product_idx ON shop_market_sources (product_id)
        ]])
    end,

    -- [2] observations -------------------------------------------------------
    [2] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_market_observations (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                source_id integer NOT NULL REFERENCES shop_market_sources(id) ON DELETE CASCADE,
                product_id integer NOT NULL REFERENCES shop_products(id) ON DELETE CASCADE,
                price_minor integer CHECK (price_minor IS NULL OR price_minor > 0),
                currency varchar(3) NOT NULL DEFAULT 'GBP',
                price_ex_vat_minor integer,
                price_inc_vat_minor integer,
                availability varchar(16) NOT NULL DEFAULT 'unknown'
                    CHECK (availability IN ('in_stock','limited','out_of_stock','preorder','backorder','unknown')),
                stock_qty integer,
                title text,
                method varchar(16) NOT NULL CHECK (method IN ('json_ld','meta','microdata','llm')),
                confidence numeric(4,3),
                evidence text,
                flags jsonb NOT NULL DEFAULT '{}'::jsonb,
                accepted boolean NOT NULL DEFAULT true,
                fetched_at timestamptz NOT NULL DEFAULT NOW(),
                created_at timestamp NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS shop_market_observations_source_idx
                ON shop_market_observations (source_id, fetched_at DESC)
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS shop_market_observations_product_idx
                ON shop_market_observations (product_id, fetched_at DESC)
        ]])
    end,
}
