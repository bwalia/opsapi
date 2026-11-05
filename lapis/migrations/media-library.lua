--[[
    Media library (lib/media-library.lua, routes/cms-media.lua)
    ===========================================================

    [1] media_assets: one row per image a workspace can reuse in its content.
        storage = minio      our own object store, served by GET /api/v2/public/media/<uuid>.<ext>
                  s3_public  the public website bucket (CMS_PUBLIC_S3_*)
                  link       an image we only point at (added before the library existed)
        source_asset_id links an edited copy (crop/resize) to its original.
    [2] Backfill: every image the workspace's posts and pages already use
        (featured image + <img src> in the content, full URLs or site-relative
        paths like /img/x.jpg) becomes a `link` row, so old images can be reused
        from the library. Idempotent.

    Feature-gated under FEATURES.CMS (the library uses the cms permissions).
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS media_assets (
                id BIGSERIAL PRIMARY KEY,
                uuid VARCHAR(36) NOT NULL UNIQUE,
                namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                storage VARCHAR(20) NOT NULL CHECK (storage IN ('minio', 's3_public', 'link')),
                bucket VARCHAR(255),
                object_key TEXT,
                url TEXT NOT NULL,
                filename VARCHAR(255),
                mime_type VARCHAR(100),
                size_bytes BIGINT,
                width INTEGER,
                height INTEGER,
                alt_text TEXT,
                title VARCHAR(255),
                source_asset_id BIGINT REFERENCES media_assets(id) ON DELETE SET NULL,
                uploaded_by_user_uuid VARCHAR(36),
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS media_assets_ns_created_idx ON media_assets (namespace_id, created_at DESC)")
        db.query("CREATE INDEX IF NOT EXISTS media_assets_ns_url_idx ON media_assets (namespace_id, md5(url))")
    end,

    [2] = function()
        for _, t in ipairs({ "cms_posts", "cms_pages" }) do
            if db.query("SELECT to_regclass(?) IS NOT NULL AS ok", t)[1].ok then
                db.query(([[
                    INSERT INTO media_assets (uuid, namespace_id, storage, url, filename, created_at, updated_at)
                    SELECT gen_random_uuid()::text, u.namespace_id, 'link', u.url,
                           -- chr(63) is "?": Lapis reads a literal one as a placeholder.
                           left(regexp_replace(split_part(u.url, chr(63), 1), '^.*/', ''), 255), u.first_seen, NOW()
                    FROM (
                        SELECT namespace_id, url, MIN(created_at) AS first_seen FROM (
                            SELECT namespace_id, featured_image_url AS url, created_at FROM %s
                             WHERE deleted_at IS NULL AND featured_image_url IS NOT NULL
                            UNION ALL
                            SELECT namespace_id, (regexp_matches(content_html, '<img[^>]+src="([^"]+)"', 'gi'))[1], created_at
                              FROM %s WHERE deleted_at IS NULL AND content_html IS NOT NULL
                        ) raw
                        -- full URLs and site-relative paths (/img/x.jpg); not data: or //host
                        WHERE url ~* '^(https?://|/[^/])' AND length(url) <= 2000
                        GROUP BY namespace_id, url
                    ) u
                    WHERE NOT EXISTS (SELECT 1 FROM media_assets m
                                       WHERE m.namespace_id = u.namespace_id AND md5(m.url) = md5(u.url))
                ]]):format(t, t))
            end
        end
    end,
}
