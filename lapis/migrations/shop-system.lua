--[[
    Shop System Migrations (FEATURES.SHOP)
    ======================================

    Workstation AI Shop backend: configurable catalogue, server-priced carts,
    quotes, orders + Stripe hosted checkout, stock reservations, chat
    transcripts and a RAG knowledge base. Contract: BUILD.prompt.md §2.

    Every step is idempotent (CREATE ... IF NOT EXISTS / guarded ALTERs) so
    `lapis migrate` can be run repeatedly. pgvector is optional: the extension
    is created inside pcall and the `embedding vector(384)` columns + ANN
    indexes are only added when the `vector` type exists — search then falls
    back to full text only.

    Tables: shop_categories, shop_products, shop_option_groups, shop_options,
    shop_rules, shop_carts, shop_cart_lines, shop_quotes, shop_orders,
    shop_stock_reservations, shop_stock_movements, shop_stripe_events,
    shop_chat_sessions, shop_knowledge_chunks.
]]

local db = require("lapis.db")

-- Run a statement that is allowed to fail. Inside a transaction (lapis migrate
-- --transaction) a failed statement would abort the whole block, so wrap it in
-- a savepoint; outside one, SAVEPOINT itself errors harmlessly.
local function try(sql)
    local sp = pcall(db.query, "SAVEPOINT shop_try")
    local ok, err = pcall(db.query, sql)
    if sp then
        if ok then db.query("RELEASE SAVEPOINT shop_try") else db.query("ROLLBACK TO SAVEPOINT shop_try") end
    end
    return ok, err
end

local function vector_available()
    local ok, rows = pcall(db.query, "SELECT 1 AS ok FROM pg_type WHERE typname = 'vector' LIMIT 1")
    return ok and rows and #rows > 0
end

local function column_exists(tbl, col)
    local rows = db.query([[
        SELECT 1 FROM information_schema.columns WHERE table_name = ? AND column_name = ? LIMIT 1
    ]], tbl, col)
    return rows and #rows > 0
end

local function add_embedding_column(tbl)
    if not vector_available() then return end
    if not column_exists(tbl, "embedding") then
        db.query("ALTER TABLE " .. tbl .. " ADD COLUMN embedding vector(384)")
    end
    local idx = tbl .. "_embedding_idx"
    -- hnsw needs pgvector >= 0.5; fall back to ivfflat, else no ANN index
    -- (exact scans are fine at shop scale).
    local ok = try("CREATE INDEX IF NOT EXISTS " .. idx .. " ON " .. tbl
        .. " USING hnsw (embedding vector_cosine_ops)")
    if not ok then
        try("CREATE INDEX IF NOT EXISTS " .. idx .. " ON " .. tbl
            .. " USING ivfflat (embedding vector_cosine_ops) WITH (lists = 50)")
    end
end

return {
    -- [1] pgvector (optional) --------------------------------------------------
    [1] = function()
        local ok, err = try("CREATE EXTENSION IF NOT EXISTS vector")
        if not ok then
            print("[Shop] pgvector unavailable — semantic search disabled, full text only: " .. tostring(err))
        end
        db.query("CREATE SEQUENCE IF NOT EXISTS shop_quote_number_seq")
        db.query("CREATE SEQUENCE IF NOT EXISTS shop_order_number_seq")
    end,

    -- [2] catalogue -------------------------------------------------------------
    [2] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_categories (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                slug varchar(160) NOT NULL,
                name varchar(255) NOT NULL,
                description text,
                image_url text,
                parent_id integer REFERENCES shop_categories(id) ON DELETE SET NULL,
                sort_order integer NOT NULL DEFAULT 0,
                is_active boolean NOT NULL DEFAULT true,
                created_at timestamp NOT NULL DEFAULT NOW(),
                updated_at timestamp NOT NULL DEFAULT NOW(),
                UNIQUE (namespace_id, slug)
            )
        ]])

        db.query([[
            CREATE TABLE IF NOT EXISTS shop_products (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                category_id integer REFERENCES shop_categories(id) ON DELETE SET NULL,
                sku varchar(120) NOT NULL,
                slug varchar(200) NOT NULL,
                name varchar(255) NOT NULL,
                brand varchar(120),
                product_type varchar(32) NOT NULL DEFAULT 'workstation'
                    CHECK (product_type IN ('workstation','server','gpu','cpu','memory','storage',
                                            'networking','peripheral','software','service')),
                price_mode varchar(16) NOT NULL DEFAULT 'fixed'
                    CHECK (price_mode IN ('fixed','configurable','quote_only')),
                short_description text,
                description text,
                specs jsonb NOT NULL DEFAULT '{}'::jsonb,
                attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
                images jsonb NOT NULL DEFAULT '[]'::jsonb,
                tags text[] NOT NULL DEFAULT '{}',
                base_price_minor integer NOT NULL DEFAULT 0,
                currency varchar(3) NOT NULL DEFAULT 'GBP',
                vat_rate numeric(5,4) NOT NULL DEFAULT 0.20,
                stock_qty integer NOT NULL DEFAULT 0,
                low_stock_threshold integer NOT NULL DEFAULT 2,
                lead_time_days integer NOT NULL DEFAULT 10,
                allow_backorder boolean NOT NULL DEFAULT true,
                price_verified boolean NOT NULL DEFAULT false,
                status varchar(16) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','archived')),
                is_featured boolean NOT NULL DEFAULT false,
                sort_order integer NOT NULL DEFAULT 0,
                search_tsv tsvector,
                created_at timestamp NOT NULL DEFAULT NOW(),
                updated_at timestamp NOT NULL DEFAULT NOW(),
                UNIQUE (namespace_id, sku),
                UNIQUE (namespace_id, slug)
            )
        ]])
        add_embedding_column("shop_products")
    end,

    -- [3] configurator: option groups, options, rules --------------------------
    [3] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_option_groups (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                product_id integer NOT NULL REFERENCES shop_products(id) ON DELETE CASCADE,
                code varchar(64) NOT NULL,
                name varchar(255) NOT NULL,
                description text,
                selection varchar(8) NOT NULL DEFAULT 'single' CHECK (selection IN ('single','multi')),
                required boolean NOT NULL DEFAULT false,
                min_qty integer NOT NULL DEFAULT 0,
                max_qty integer NOT NULL DEFAULT 1,
                sort_order integer NOT NULL DEFAULT 0,
                is_active boolean NOT NULL DEFAULT true,
                created_at timestamp NOT NULL DEFAULT NOW(),
                updated_at timestamp NOT NULL DEFAULT NOW(),
                UNIQUE (product_id, code)
            )
        ]])
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_options (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                group_id integer NOT NULL REFERENCES shop_option_groups(id) ON DELETE CASCADE,
                code varchar(64) NOT NULL,
                name varchar(255) NOT NULL,
                description text,
                price_delta_minor integer NOT NULL DEFAULT 0,
                component_product_id integer REFERENCES shop_products(id) ON DELETE SET NULL,
                stock_qty integer,
                max_qty integer NOT NULL DEFAULT 1,
                is_default boolean NOT NULL DEFAULT false,
                is_active boolean NOT NULL DEFAULT true,
                sort_order integer NOT NULL DEFAULT 0,
                attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
                created_at timestamp NOT NULL DEFAULT NOW(),
                updated_at timestamp NOT NULL DEFAULT NOW(),
                UNIQUE (group_id, code)
            )
        ]])
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_rules (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                product_id integer NOT NULL REFERENCES shop_products(id) ON DELETE CASCADE,
                kind varchar(16) NOT NULL CHECK (kind IN ('requires','excludes','power','max_total','attr_match')),
                params jsonb NOT NULL DEFAULT '{}'::jsonb,
                message text,
                is_active boolean NOT NULL DEFAULT true,
                sort_order integer NOT NULL DEFAULT 0,
                created_at timestamp NOT NULL DEFAULT NOW(),
                updated_at timestamp NOT NULL DEFAULT NOW()
            )
        ]])
    end,

    -- [4] carts -----------------------------------------------------------------
    [4] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_carts (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                token_hash varchar(64) NOT NULL UNIQUE,
                status varchar(16) NOT NULL DEFAULT 'active' CHECK (status IN ('active','converted','abandoned')),
                email varchar(255),
                currency varchar(3) NOT NULL DEFAULT 'GBP',
                chat_session_id integer,
                expires_at timestamp NOT NULL DEFAULT (NOW() + interval '30 days'),
                last_seen_at timestamp NOT NULL DEFAULT NOW(),
                created_at timestamp NOT NULL DEFAULT NOW(),
                updated_at timestamp NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_cart_lines (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                cart_id integer NOT NULL REFERENCES shop_carts(id) ON DELETE CASCADE,
                product_id integer NOT NULL REFERENCES shop_products(id) ON DELETE CASCADE,
                qty integer NOT NULL DEFAULT 1 CHECK (qty > 0),
                selections jsonb NOT NULL DEFAULT '{}'::jsonb,
                unit_price_minor integer NOT NULL DEFAULT 0,
                label text,
                sort_order integer NOT NULL DEFAULT 0,
                created_at timestamp NOT NULL DEFAULT NOW(),
                updated_at timestamp NOT NULL DEFAULT NOW()
            )
        ]])
    end,

    -- [5] quotes + orders -------------------------------------------------------
    [5] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_orders (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                order_number varchar(32) NOT NULL UNIQUE,
                access_token varchar(128) NOT NULL,
                status varchar(24) NOT NULL DEFAULT 'pending_payment'
                    CHECK (status IN ('pending_payment','paid','processing','shipped','delivered',
                                      'cancelled','refunded','payment_failed')),
                email varchar(255),
                customer jsonb NOT NULL DEFAULT '{}'::jsonb,
                shipping_address jsonb,
                billing_address jsonb,
                lines jsonb NOT NULL DEFAULT '[]'::jsonb,
                subtotal_minor integer NOT NULL DEFAULT 0,
                vat_minor integer NOT NULL DEFAULT 0,
                shipping_minor integer NOT NULL DEFAULT 0,
                total_minor integer NOT NULL DEFAULT 0,
                currency varchar(3) NOT NULL DEFAULT 'GBP',
                cart_id integer REFERENCES shop_carts(id) ON DELETE SET NULL,
                quote_id integer,
                stripe_session_id varchar(255) UNIQUE,
                stripe_payment_intent_id varchar(255),
                paid_at timestamp,
                tracking jsonb,
                internal_notes text,
                created_at timestamp NOT NULL DEFAULT NOW(),
                updated_at timestamp NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_quotes (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                quote_number varchar(32) NOT NULL UNIQUE,
                access_token varchar(128) NOT NULL,
                status varchar(16) NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft','sent','accepted','expired','converted','cancelled')),
                source varchar(8) NOT NULL DEFAULT 'cart' CHECK (source IN ('cart','chat','admin')),
                customer jsonb NOT NULL DEFAULT '{}'::jsonb,
                notes text,
                internal_notes text,
                lines jsonb NOT NULL DEFAULT '[]'::jsonb,
                subtotal_minor integer NOT NULL DEFAULT 0,
                vat_minor integer NOT NULL DEFAULT 0,
                shipping_minor integer NOT NULL DEFAULT 0,
                total_minor integer NOT NULL DEFAULT 0,
                currency varchar(3) NOT NULL DEFAULT 'GBP',
                valid_until timestamp NOT NULL DEFAULT (NOW() + interval '30 days'),
                cart_id integer REFERENCES shop_carts(id) ON DELETE SET NULL,
                chat_session_id integer,
                order_id integer REFERENCES shop_orders(id) ON DELETE SET NULL,
                crm_lead_id integer,
                viewed_at timestamp,
                created_by_user_id integer,
                created_at timestamp NOT NULL DEFAULT NOW(),
                updated_at timestamp NOT NULL DEFAULT NOW()
            )
        ]])
        try([[
            ALTER TABLE shop_orders ADD CONSTRAINT shop_orders_quote_fk
            FOREIGN KEY (quote_id) REFERENCES shop_quotes(id) ON DELETE SET NULL
        ]])
    end,

    -- [6] stock, stripe ledger --------------------------------------------------
    [6] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_stock_reservations (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                product_id integer REFERENCES shop_products(id) ON DELETE CASCADE,
                option_id integer REFERENCES shop_options(id) ON DELETE CASCADE,
                qty integer NOT NULL CHECK (qty > 0),
                order_id integer NOT NULL REFERENCES shop_orders(id) ON DELETE CASCADE,
                status varchar(16) NOT NULL DEFAULT 'held' CHECK (status IN ('held','committed','released')),
                expires_at timestamp NOT NULL,
                created_at timestamp NOT NULL DEFAULT NOW(),
                updated_at timestamp NOT NULL DEFAULT NOW(),
                CHECK (product_id IS NOT NULL OR option_id IS NOT NULL)
            )
        ]])
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_stock_movements (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                product_id integer REFERENCES shop_products(id) ON DELETE CASCADE,
                option_id integer REFERENCES shop_options(id) ON DELETE CASCADE,
                delta integer NOT NULL,
                reason varchar(16) NOT NULL CHECK (reason IN ('adjustment','sale','release','restock','import')),
                ref text,
                user_id integer,
                created_at timestamp NOT NULL DEFAULT NOW(),
                updated_at timestamp NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_stripe_events (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                event_id varchar(255) NOT NULL UNIQUE,
                type varchar(120) NOT NULL,
                namespace_id integer,
                order_id integer REFERENCES shop_orders(id) ON DELETE SET NULL,
                processed_at timestamp NOT NULL DEFAULT NOW(),
                created_at timestamp NOT NULL DEFAULT NOW(),
                updated_at timestamp NOT NULL DEFAULT NOW()
            )
        ]])
    end,

    -- [7] chat transcripts + knowledge -----------------------------------------
    [7] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_chat_sessions (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                cart_id integer REFERENCES shop_carts(id) ON DELETE SET NULL,
                email varchar(255),
                messages jsonb NOT NULL DEFAULT '[]'::jsonb,
                summary text,
                quote_id integer REFERENCES shop_quotes(id) ON DELETE SET NULL,
                order_id integer REFERENCES shop_orders(id) ON DELETE SET NULL,
                message_count integer NOT NULL DEFAULT 0,
                created_at timestamp NOT NULL DEFAULT NOW(),
                updated_at timestamp NOT NULL DEFAULT NOW()
            )
        ]])
        try([[
            ALTER TABLE shop_carts ADD CONSTRAINT shop_carts_chat_fk
            FOREIGN KEY (chat_session_id) REFERENCES shop_chat_sessions(id) ON DELETE SET NULL
        ]])
        try([[
            ALTER TABLE shop_quotes ADD CONSTRAINT shop_quotes_chat_fk
            FOREIGN KEY (chat_session_id) REFERENCES shop_chat_sessions(id) ON DELETE SET NULL
        ]])
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_knowledge_chunks (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                source_type varchar(16) NOT NULL CHECK (source_type IN ('product','cms_post','faq','manual','url')),
                source_ref varchar(255) NOT NULL,
                title varchar(500) NOT NULL DEFAULT '',
                url text,
                chunk_index integer NOT NULL DEFAULT 0,
                content text NOT NULL,
                search_tsv tsvector,
                created_at timestamp NOT NULL DEFAULT NOW(),
                updated_at timestamp NOT NULL DEFAULT NOW(),
                UNIQUE (namespace_id, source_type, source_ref, chunk_index)
            )
        ]])
        add_embedding_column("shop_knowledge_chunks")
    end,

    -- [8] full-text triggers + indexes -----------------------------------------
    [8] = function()
        db.query([[
            CREATE OR REPLACE FUNCTION shop_products_tsv_update() RETURNS trigger AS $$
            BEGIN
                NEW.search_tsv :=
                    setweight(to_tsvector('english', coalesce(NEW.name, '')), 'A') ||
                    setweight(to_tsvector('english', coalesce(NEW.sku, '') || ' ' || coalesce(NEW.brand, '')
                        || ' ' || coalesce(NEW.product_type, '') || ' '
                        || coalesce(array_to_string(NEW.tags, ' '), '')), 'B') ||
                    setweight(to_tsvector('english', coalesce(NEW.short_description, '')), 'C') ||
                    setweight(to_tsvector('english', coalesce(NEW.description, '') || ' '
                        || coalesce(NEW.specs::text, '')), 'D');
                RETURN NEW;
            END
            $$ LANGUAGE plpgsql
        ]])
        db.query("DROP TRIGGER IF EXISTS trg_shop_products_tsv ON shop_products")
        db.query([[
            CREATE TRIGGER trg_shop_products_tsv BEFORE INSERT OR UPDATE ON shop_products
            FOR EACH ROW EXECUTE FUNCTION shop_products_tsv_update()
        ]])

        db.query([[
            CREATE OR REPLACE FUNCTION shop_knowledge_tsv_update() RETURNS trigger AS $$
            BEGIN
                NEW.search_tsv :=
                    setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A') ||
                    setweight(to_tsvector('english', coalesce(NEW.content, '')), 'B');
                RETURN NEW;
            END
            $$ LANGUAGE plpgsql
        ]])
        db.query("DROP TRIGGER IF EXISTS trg_shop_knowledge_tsv ON shop_knowledge_chunks")
        db.query([[
            CREATE TRIGGER trg_shop_knowledge_tsv BEFORE INSERT OR UPDATE ON shop_knowledge_chunks
            FOR EACH ROW EXECUTE FUNCTION shop_knowledge_tsv_update()
        ]])

        local indexes = {
            "CREATE INDEX IF NOT EXISTS shop_categories_ns_idx ON shop_categories (namespace_id)",
            "CREATE INDEX IF NOT EXISTS shop_categories_parent_idx ON shop_categories (parent_id)",
            "CREATE INDEX IF NOT EXISTS shop_products_ns_idx ON shop_products (namespace_id)",
            "CREATE INDEX IF NOT EXISTS shop_products_category_idx ON shop_products (category_id)",
            "CREATE INDEX IF NOT EXISTS shop_products_status_idx ON shop_products (namespace_id, status)",
            "CREATE INDEX IF NOT EXISTS shop_products_tsv_idx ON shop_products USING GIN (search_tsv)",
            "CREATE INDEX IF NOT EXISTS shop_option_groups_product_idx ON shop_option_groups (product_id)",
            "CREATE INDEX IF NOT EXISTS shop_options_group_idx ON shop_options (group_id)",
            "CREATE INDEX IF NOT EXISTS shop_options_component_idx ON shop_options (component_product_id)",
            "CREATE INDEX IF NOT EXISTS shop_rules_product_idx ON shop_rules (product_id)",
            "CREATE INDEX IF NOT EXISTS shop_carts_ns_idx ON shop_carts (namespace_id)",
            "CREATE INDEX IF NOT EXISTS shop_carts_status_idx ON shop_carts (status)",
            "CREATE INDEX IF NOT EXISTS shop_carts_chat_idx ON shop_carts (chat_session_id)",
            "CREATE INDEX IF NOT EXISTS shop_cart_lines_cart_idx ON shop_cart_lines (cart_id)",
            "CREATE INDEX IF NOT EXISTS shop_cart_lines_product_idx ON shop_cart_lines (product_id)",
            "CREATE INDEX IF NOT EXISTS shop_quotes_ns_idx ON shop_quotes (namespace_id)",
            "CREATE INDEX IF NOT EXISTS shop_quotes_status_idx ON shop_quotes (namespace_id, status)",
            "CREATE INDEX IF NOT EXISTS shop_quotes_cart_idx ON shop_quotes (cart_id)",
            "CREATE INDEX IF NOT EXISTS shop_quotes_chat_idx ON shop_quotes (chat_session_id)",
            "CREATE INDEX IF NOT EXISTS shop_quotes_order_idx ON shop_quotes (order_id)",
            "CREATE INDEX IF NOT EXISTS shop_orders_ns_idx ON shop_orders (namespace_id)",
            "CREATE INDEX IF NOT EXISTS shop_orders_status_idx ON shop_orders (namespace_id, status)",
            "CREATE INDEX IF NOT EXISTS shop_orders_cart_idx ON shop_orders (cart_id)",
            "CREATE INDEX IF NOT EXISTS shop_orders_quote_idx ON shop_orders (quote_id)",
            "CREATE INDEX IF NOT EXISTS shop_orders_pi_idx ON shop_orders (stripe_payment_intent_id)",
            "CREATE INDEX IF NOT EXISTS shop_reservations_ns_idx ON shop_stock_reservations (namespace_id)",
            "CREATE INDEX IF NOT EXISTS shop_reservations_product_idx ON shop_stock_reservations (product_id)",
            "CREATE INDEX IF NOT EXISTS shop_reservations_option_idx ON shop_stock_reservations (option_id)",
            "CREATE INDEX IF NOT EXISTS shop_reservations_order_idx ON shop_stock_reservations (order_id)",
            "CREATE INDEX IF NOT EXISTS shop_reservations_status_idx ON shop_stock_reservations (status, expires_at)",
            "CREATE INDEX IF NOT EXISTS shop_movements_ns_idx ON shop_stock_movements (namespace_id)",
            "CREATE INDEX IF NOT EXISTS shop_movements_product_idx ON shop_stock_movements (product_id)",
            "CREATE INDEX IF NOT EXISTS shop_movements_option_idx ON shop_stock_movements (option_id)",
            "CREATE INDEX IF NOT EXISTS shop_stripe_events_order_idx ON shop_stripe_events (order_id)",
            "CREATE INDEX IF NOT EXISTS shop_chat_sessions_ns_idx ON shop_chat_sessions (namespace_id)",
            "CREATE INDEX IF NOT EXISTS shop_chat_sessions_cart_idx ON shop_chat_sessions (cart_id)",
            "CREATE INDEX IF NOT EXISTS shop_chat_sessions_quote_idx ON shop_chat_sessions (quote_id)",
            "CREATE INDEX IF NOT EXISTS shop_chat_sessions_order_idx ON shop_chat_sessions (order_id)",
            "CREATE INDEX IF NOT EXISTS shop_knowledge_ns_idx ON shop_knowledge_chunks (namespace_id)",
            "CREATE INDEX IF NOT EXISTS shop_knowledge_tsv_idx ON shop_knowledge_chunks USING GIN (search_tsv)",
        }
        for _, sql in ipairs(indexes) do db.query(sql) end
    end,

    -- [9] late pgvector: if the extension appeared after [2]/[7] ran, add the
    -- embedding columns now (no-op otherwise / when already present).
    [9] = function()
        try("CREATE EXTENSION IF NOT EXISTS vector")
        add_embedding_column("shop_products")
        add_embedding_column("shop_knowledge_chunks")
    end,
}
