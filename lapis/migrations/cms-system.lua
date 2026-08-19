--[[
    CMS (Content Management) System Migrations
    ==========================================

    A multi-tenant Content Management System powering the public-facing website
    of a namespace: static **Pages** (About, Contact, ...) and a proper **Blog**
    (articles with categories + tags). Rich WYSIWYG content, mirroring the
    academy module's storage model.

    Tables:
    =======
    1. cms_categories - Blog categories (hierarchical, namespace-scoped)
    2. cms_tags       - Blog tags (flat, namespace-scoped)
    3. cms_posts      - Blog articles (rich HTML + editor JSON, SEO, publishing)
    4. cms_pages      - Static site pages (rich HTML + editor JSON, SEO, nav)
    5. cms_post_tags  - Post <-> Tag join (many-to-many)

    Notes:
    ======
    - Every content table is namespace-scoped (FK -> namespaces ON DELETE CASCADE)
      so tenants are fully isolated and it can share a DB with any other project.
    - Soft deletes (deleted_at) everywhere; unique slug per namespace applies only
      to live rows (partial index WHERE deleted_at IS NULL), so a deleted slug can
      be reused / revived.
    - Body is stored as sanitized `content_html` (rendered) plus `content_json`
      (the editor document, for re-editing) — same contract as academy_lessons.
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

local function table_exists(table_name)
    local result = db.query([[
        SELECT EXISTS (
            SELECT FROM information_schema.tables WHERE table_name = ?
        ) as exists
    ]], table_name)
    return result[1] and result[1].exists
end

local function index_exists(index_name)
    local result = db.query([[
        SELECT EXISTS (SELECT FROM pg_indexes WHERE indexname = ?) as exists
    ]], index_name)
    return result[1] and result[1].exists
end

return {
    -- ========================================================================
    -- [1] Create cms_categories (hierarchical blog categories)
    -- ========================================================================
    [1] = function()
        if table_exists("cms_categories") then return end

        schema.create_table("cms_categories", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer },
            { "name", types.varchar },
            { "slug", types.varchar },
            { "description", types.text({ null = true }) },
            { "parent_id", types.integer({ null = true }) },
            { "position", types.integer({ default = 0 }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        pcall(function()
            db.query([[
                ALTER TABLE cms_categories
                ADD CONSTRAINT cms_categories_namespace_fk
                FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE
            ]])
        end)

        -- lapis types.integer gives the column a DEFAULT 0; for a nullable FK
        -- that means an omitted parent inserts 0 and breaks the FK. Drop it so
        -- an unspecified parent is NULL.
        pcall(function()
            db.query("ALTER TABLE cms_categories ALTER COLUMN parent_id DROP DEFAULT")
        end)

        -- Self-reference for nesting; a deleted parent orphans children (SET NULL)
        -- rather than cascading — a child category should survive its parent.
        pcall(function()
            db.query([[
                ALTER TABLE cms_categories
                ADD CONSTRAINT cms_categories_parent_fk
                FOREIGN KEY (parent_id) REFERENCES cms_categories(id) ON DELETE SET NULL
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX cms_categories_namespace_slug_unique
                ON cms_categories (namespace_id, slug)
                WHERE deleted_at IS NULL
            ]])
        end)

        if not index_exists("idx_cms_categories_uuid") then
            db.query("CREATE UNIQUE INDEX idx_cms_categories_uuid ON cms_categories (uuid)")
        end
        if not index_exists("idx_cms_categories_ns") then
            db.query([[
                CREATE INDEX idx_cms_categories_ns
                ON cms_categories (namespace_id)
                WHERE deleted_at IS NULL
            ]])
        end
    end,

    -- ========================================================================
    -- [2] Create cms_tags (flat blog tags)
    -- ========================================================================
    [2] = function()
        if table_exists("cms_tags") then return end

        schema.create_table("cms_tags", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer },
            { "name", types.varchar },
            { "slug", types.varchar },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        pcall(function()
            db.query([[
                ALTER TABLE cms_tags
                ADD CONSTRAINT cms_tags_namespace_fk
                FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX cms_tags_namespace_slug_unique
                ON cms_tags (namespace_id, slug)
                WHERE deleted_at IS NULL
            ]])
        end)

        if not index_exists("idx_cms_tags_uuid") then
            db.query("CREATE UNIQUE INDEX idx_cms_tags_uuid ON cms_tags (uuid)")
        end
        if not index_exists("idx_cms_tags_ns") then
            db.query([[
                CREATE INDEX idx_cms_tags_ns
                ON cms_tags (namespace_id)
                WHERE deleted_at IS NULL
            ]])
        end
    end,

    -- ========================================================================
    -- [3] Create cms_posts (blog articles)
    -- ========================================================================
    [3] = function()
        if table_exists("cms_posts") then return end

        schema.create_table("cms_posts", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer },
            { "category_id", types.integer({ null = true }) },
            { "title", types.varchar },
            { "slug", types.varchar },
            { "excerpt", types.text({ null = true }) },
            { "content_html", types.text({ null = true }) },   -- sanitized, rendered
            { "content_json", types.text({ null = true }) },   -- editor document (re-editing)
            { "featured_image_url", types.varchar({ null = true }) },
            { "status", types.varchar({ default = "draft" }) },      -- draft|published|scheduled|archived
            { "visibility", types.varchar({ default = "public" }) }, -- public|private
            { "is_featured", types.boolean({ default = false }) },
            { "author_uuid", types.varchar({ null = true }) },
            { "author_name", types.varchar({ null = true }) },
            { "published_at", types.time({ null = true }) },
            { "scheduled_at", types.time({ null = true }) },
            { "seo_title", types.varchar({ null = true }) },
            { "seo_description", types.text({ null = true }) },
            { "seo_keywords", types.varchar({ null = true }) },
            { "reading_minutes", types.integer({ default = 0 }) },
            { "view_count", types.integer({ default = 0 }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        pcall(function()
            db.query([[
                ALTER TABLE cms_posts
                ADD CONSTRAINT cms_posts_namespace_fk
                FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE
            ]])
        end)

        -- Nullable FK: drop the DEFAULT 0 so an uncategorised post inserts NULL.
        pcall(function()
            db.query("ALTER TABLE cms_posts ALTER COLUMN category_id DROP DEFAULT")
        end)

        -- Deleting a category detaches its posts (SET NULL) — posts outlive
        -- their category.
        pcall(function()
            db.query([[
                ALTER TABLE cms_posts
                ADD CONSTRAINT cms_posts_category_fk
                FOREIGN KEY (category_id) REFERENCES cms_categories(id) ON DELETE SET NULL
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE cms_posts
                ADD CONSTRAINT cms_posts_status_check
                CHECK (status IN ('draft', 'published', 'scheduled', 'archived'))
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE cms_posts
                ADD CONSTRAINT cms_posts_visibility_check
                CHECK (visibility IN ('public', 'private'))
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX cms_posts_namespace_slug_unique
                ON cms_posts (namespace_id, slug)
                WHERE deleted_at IS NULL
            ]])
        end)
    end,

    -- ========================================================================
    -- [4] cms_posts indexes
    -- ========================================================================
    [4] = function()
        if not index_exists("idx_cms_posts_uuid") then
            db.query("CREATE UNIQUE INDEX idx_cms_posts_uuid ON cms_posts (uuid)")
        end
        -- Catalogue listing: newest published first per namespace.
        if not index_exists("idx_cms_posts_ns_status_pub") then
            db.query([[
                CREATE INDEX idx_cms_posts_ns_status_pub
                ON cms_posts (namespace_id, status, published_at DESC)
                WHERE deleted_at IS NULL
            ]])
        end
        if not index_exists("idx_cms_posts_ns_category") then
            db.query([[
                CREATE INDEX idx_cms_posts_ns_category
                ON cms_posts (namespace_id, category_id)
                WHERE deleted_at IS NULL
            ]])
        end
        if not index_exists("idx_cms_posts_ns_featured") then
            db.query([[
                CREATE INDEX idx_cms_posts_ns_featured
                ON cms_posts (namespace_id, is_featured)
                WHERE deleted_at IS NULL
            ]])
        end
    end,

    -- ========================================================================
    -- [5] Create cms_pages (static site pages)
    -- ========================================================================
    [5] = function()
        if table_exists("cms_pages") then return end

        schema.create_table("cms_pages", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer },
            { "parent_id", types.integer({ null = true }) },
            { "title", types.varchar },
            { "slug", types.varchar },
            { "excerpt", types.text({ null = true }) },
            { "content_html", types.text({ null = true }) },   -- sanitized, rendered
            { "content_json", types.text({ null = true }) },   -- editor document (re-editing)
            { "featured_image_url", types.varchar({ null = true }) },
            { "status", types.varchar({ default = "draft" }) },     -- draft|published|archived
            { "template", types.varchar({ default = "default" }) }, -- theme template hint
            { "menu_order", types.integer({ default = 0 }) },
            { "show_in_nav", types.boolean({ default = false }) },
            { "author_uuid", types.varchar({ null = true }) },
            { "published_at", types.time({ null = true }) },
            { "seo_title", types.varchar({ null = true }) },
            { "seo_description", types.text({ null = true }) },
            { "seo_keywords", types.varchar({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        pcall(function()
            db.query([[
                ALTER TABLE cms_pages
                ADD CONSTRAINT cms_pages_namespace_fk
                FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE
            ]])
        end)

        -- Nullable FK: drop the DEFAULT 0 so a top-level page inserts NULL.
        pcall(function()
            db.query("ALTER TABLE cms_pages ALTER COLUMN parent_id DROP DEFAULT")
        end)

        pcall(function()
            db.query([[
                ALTER TABLE cms_pages
                ADD CONSTRAINT cms_pages_parent_fk
                FOREIGN KEY (parent_id) REFERENCES cms_pages(id) ON DELETE SET NULL
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE cms_pages
                ADD CONSTRAINT cms_pages_status_check
                CHECK (status IN ('draft', 'published', 'archived'))
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX cms_pages_namespace_slug_unique
                ON cms_pages (namespace_id, slug)
                WHERE deleted_at IS NULL
            ]])
        end)

        if not index_exists("idx_cms_pages_uuid") then
            db.query("CREATE UNIQUE INDEX idx_cms_pages_uuid ON cms_pages (uuid)")
        end
        if not index_exists("idx_cms_pages_ns_status") then
            db.query([[
                CREATE INDEX idx_cms_pages_ns_status
                ON cms_pages (namespace_id, status)
                WHERE deleted_at IS NULL
            ]])
        end
        if not index_exists("idx_cms_pages_ns_nav") then
            db.query([[
                CREATE INDEX idx_cms_pages_ns_nav
                ON cms_pages (namespace_id, show_in_nav, menu_order)
                WHERE deleted_at IS NULL
            ]])
        end
    end,

    -- ========================================================================
    -- [6] Create cms_post_tags (post <-> tag many-to-many)
    -- ========================================================================
    [6] = function()
        if table_exists("cms_post_tags") then return end

        schema.create_table("cms_post_tags", {
            { "id", types.serial },
            { "post_id", types.integer },
            { "tag_id", types.integer },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })

        pcall(function()
            db.query([[
                ALTER TABLE cms_post_tags
                ADD CONSTRAINT cms_post_tags_post_fk
                FOREIGN KEY (post_id) REFERENCES cms_posts(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE cms_post_tags
                ADD CONSTRAINT cms_post_tags_tag_fk
                FOREIGN KEY (tag_id) REFERENCES cms_tags(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX cms_post_tags_unique
                ON cms_post_tags (post_id, tag_id)
            ]])
        end)

        if not index_exists("idx_cms_post_tags_tag") then
            db.query("CREATE INDEX idx_cms_post_tags_tag ON cms_post_tags (tag_id)")
        end
    end,

    -- ========================================================================
    -- [7] Create cms_post_categories (post <-> category many-to-many)
    --     Adds multi-category support without dropping cms_posts.category_id,
    --     which stays as the optional "primary" category (back-compat). The
    --     join is the source of truth for the full set; existing category_id
    --     values are backfilled so category filtering can rely on the join.
    -- ========================================================================
    [7] = function()
        if table_exists("cms_post_categories") then return end

        schema.create_table("cms_post_categories", {
            { "id", types.serial },
            { "post_id", types.integer },
            { "category_id", types.integer },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })

        pcall(function()
            db.query([[
                ALTER TABLE cms_post_categories
                ADD CONSTRAINT cms_post_categories_post_fk
                FOREIGN KEY (post_id) REFERENCES cms_posts(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE cms_post_categories
                ADD CONSTRAINT cms_post_categories_category_fk
                FOREIGN KEY (category_id) REFERENCES cms_categories(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX cms_post_categories_unique
                ON cms_post_categories (post_id, category_id)
            ]])
        end)

        if not index_exists("idx_cms_post_categories_category") then
            db.query("CREATE INDEX idx_cms_post_categories_category ON cms_post_categories (category_id)")
        end

        -- Backfill: mirror each existing post's primary category_id into the
        -- join so a category filter over the join returns pre-existing posts too.
        pcall(function()
            db.query([[
                INSERT INTO cms_post_categories (post_id, category_id, created_at)
                SELECT id, category_id, NOW() FROM cms_posts
                WHERE category_id IS NOT NULL
                ON CONFLICT (post_id, category_id) DO NOTHING
            ]])
        end)
    end,
}
