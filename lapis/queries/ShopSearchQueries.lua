-- luacheck: max line length 140
--[[
    Shop search (hybrid RAG) + knowledge base
    ==========================================

    search(): full text (websearch_to_tsquery) ALWAYS; plus pgvector cosine
    similarity when the embedding columns exist and the query can be embedded
    (LLMClient.generate_embedding, Ollama all-minilm, 384-dim). Embedding
    failures never surface — a per-worker circuit breaker skips the embedder
    for 60 s after a failure. Ranked lists are merged with reciprocal-rank
    fusion (k = 60).

    Knowledge: chunks of ~800 chars with 100 overlap from FAQs / manuals /
    URLs / products / published CMS posts, each with a tsvector and (when
    possible) an embedding.
]]

local db = require("lapis.db")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143
local Global = require("helper.global")
local U = require("lib.shop-util")
local Catalog = require("queries.ShopCatalogQueries")

local ShopSearchQueries = {}

local RRF_K = 60
local EMBED_DIM = 384
local SOURCE_TYPES = { product = true, cms_post = true, faq = true, manual = true, url = true }
ShopSearchQueries.SOURCE_TYPES = SOURCE_TYPES

-- ---------------------------------------------------------------------------
-- embeddings
-- ---------------------------------------------------------------------------

local _breaker_until = 0

--- 384-dim embedding for text, or nil (never raises).
function ShopSearchQueries.embed(text)
    if not Catalog.hasEmbeddings() then return nil end
    if not U.nz(text) then return nil end
    if ngx.now() < _breaker_until then return nil end
    local ok, res = pcall(function()
        local LLMClient = require("lib.llm-client")
        return LLMClient.generate_embedding({ text = text:sub(1, 4000), provider = "ollama" })
    end)
    if ok and type(res) == "table" and type(res.embedding) == "table" and #res.embedding == EMBED_DIM then
        return res.embedding
    end
    _breaker_until = ngx.now() + 60
    return nil
end

local function vec_literal(emb)
    local parts = {}
    for i, v in ipairs(emb) do parts[i] = string.format("%.7g", tonumber(v) or 0) end
    return "[" .. table.concat(parts, ",") .. "]"
end

-- ---------------------------------------------------------------------------
-- search
-- ---------------------------------------------------------------------------

local function rrf(lists)
    local scores, order = {}, {}
    for _, list in ipairs(lists) do
        for rank, key in ipairs(list) do
            if not scores[key] then
                scores[key] = 0
                order[#order + 1] = key
            end
            scores[key] = scores[key] + 1 / (RRF_K + rank)
        end
    end
    table.sort(order, function(a, b)
        if scores[a] == scores[b] then return tostring(a) < tostring(b) end
        return scores[a] > scores[b]
    end)
    return order, scores
end

local function like_pattern(q)
    return "%" .. q:gsub("[%%_\\]", "\\%0") .. "%"
end

function ShopSearchQueries.search(ns_id, q, limit)
    limit = U.clamp(U.int(limit, 8), 1, 30)
    q = U.nz(q) and tostring(q):sub(1, 300) or nil
    local result = { products = U.arr({}), knowledge = U.arr({}) }
    if not q then return result, { semantic = false } end
    local pool = math.max(limit * 3, 20)
    local like = like_pattern(q)

    -- full text
    local fts_products = db.query([[
        SELECT p.id FROM shop_products p, websearch_to_tsquery('english', ?) query
         WHERE p.namespace_id = ? AND p.status = 'active'
           AND (p.search_tsv @@ query OR p.name ILIKE ? OR p.sku ILIKE ?)
         ORDER BY ts_rank_cd(p.search_tsv, query) DESC, p.is_featured DESC, p.name
         LIMIT ?
    ]], q, ns_id, like, like, pool)
    local fts_chunks = db.query([[
        SELECT k.id, k.source_type, k.source_ref FROM shop_knowledge_chunks k, websearch_to_tsquery('english', ?) query
         WHERE k.namespace_id = ? AND (k.search_tsv @@ query OR k.title ILIKE ?)
         ORDER BY ts_rank_cd(k.search_tsv, query) DESC
         LIMIT ?
    ]], q, ns_id, like, pool)

    -- vector
    local vec_products, vec_chunks = {}, {}
    local emb = ShopSearchQueries.embed(q)
    if emb then
        local lit = vec_literal(emb)
        local ok1, r1 = pcall(db.query, [[
            SELECT id FROM shop_products
             WHERE namespace_id = ? AND status = 'active' AND embedding IS NOT NULL
             ORDER BY embedding <=> ?::vector LIMIT ?
        ]], ns_id, lit, pool)
        if ok1 then vec_products = r1 end
        local ok2, r2 = pcall(db.query, [[
            SELECT id, source_type, source_ref FROM shop_knowledge_chunks
             WHERE namespace_id = ? AND embedding IS NOT NULL
             ORDER BY embedding <=> ?::vector LIMIT ?
        ]], ns_id, lit, pool)
        if ok2 then vec_chunks = r2 end
    end

    -- products: RRF over ids
    local function ids(rows)
        local out = {}
        for _, r in ipairs(rows) do out[#out + 1] = r.id end
        return out
    end
    local porder, pscores = rrf({ ids(fts_products), ids(vec_products) })
    local top = {}
    for i = 1, math.min(limit, #porder) do top[i] = porder[i] end
    local cards = Catalog.cardsByIds(ns_id, top)
    local products = {}
    for _, id in ipairs(top) do
        local c = cards[id]
        if c then
            c.score = math.floor(pscores[id] * 1e6 + 0.5) / 1e6
            products[#products + 1] = c
        end
    end

    -- knowledge: RRF over chunk ids, then one hit per source document
    local corder, cscores = rrf({ ids(fts_chunks), ids(vec_chunks) })
    local knowledge, seen_src, chosen = {}, {}, {}
    local chunk_src = {}
    for _, r in ipairs(fts_chunks) do chunk_src[r.id] = r.source_type .. "|" .. r.source_ref end
    for _, r in ipairs(vec_chunks) do chunk_src[r.id] = r.source_type .. "|" .. r.source_ref end
    for _, cid in ipairs(corder) do
        local src = chunk_src[cid]
        if src and not seen_src[src] then
            seen_src[src] = true
            chosen[#chosen + 1] = cid
            if #chosen >= limit then break end
        end
    end
    if #chosen > 0 then
        local rows = db.query([[
            SELECT id, title, url, source_type, source_ref, left(content, 320) AS snippet
              FROM shop_knowledge_chunks WHERE id = ANY(?)
        ]], db.array(chosen))
        local by_id = {}
        for _, r in ipairs(rows) do by_id[r.id] = r end
        for _, cid in ipairs(chosen) do
            local r = by_id[cid]
            if r then
                knowledge[#knowledge + 1] = {
                    title = r.title, url = r.url or U.null, source_type = r.source_type, source_ref = r.source_ref,
                    snippet = (r.snippet or ""):gsub("%s+", " "),
                    score = math.floor(cscores[cid] * 1e6 + 0.5) / 1e6,
                }
            end
        end
    end
    result.products = U.arr(products)
    result.knowledge = U.arr(knowledge)
    return result, { semantic = emb ~= nil }
end

-- ---------------------------------------------------------------------------
-- knowledge: chunking + indexing
-- ---------------------------------------------------------------------------

--- Split text into ~size-char chunks with `overlap` chars of overlap, breaking
-- on whitespace where possible.
function ShopSearchQueries.chunk(text, size, overlap)
    size = size or 800
    overlap = overlap or 100
    text = tostring(text or ""):gsub("\r\n", "\n"):gsub("[ \t]+", " "):gsub("\n\n\n+", "\n\n")
    text = text:match("^%s*(.-)%s*$")
    local chunks = {}
    if text == "" then return chunks end
    local n = #text
    local start = 1
    while start <= n do
        local stop = math.min(start + size - 1, n)
        if stop < n then
            -- back off to the last whitespace in the final 25% of the window
            local window = text:sub(start, stop)
            local cut
            for i = #window, math.floor(#window * 0.75), -1 do
                if window:sub(i, i):match("%s") then cut = i break end
            end
            if cut then stop = start + cut - 1 end
        end
        local piece = text:sub(start, stop):match("^%s*(.-)%s*$")
        if piece ~= "" then chunks[#chunks + 1] = piece end
        if stop >= n then break end
        local next_start = stop - overlap + 1
        if next_start <= start then next_start = stop + 1 end
        start = next_start
    end
    return chunks
end

local function strip_html(html)
    local s = tostring(html or "")
    s = s:gsub("<script.-</script>", " "):gsub("<style.-</style>", " ")
    s = s:gsub("<br%s*/?>", "\n"):gsub("</p>", "\n\n"):gsub("</h%d>", "\n\n"):gsub("</li>", "\n")
    s = s:gsub("<[^>]+>", " ")
    s = s:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
        :gsub("&#39;", "'")
    return s
end
ShopSearchQueries.stripHtml = strip_html

--- Replace all chunks of one source document. Returns { chunks, embedded }.
function ShopSearchQueries.indexDocument(ns_id, doc)
    local pieces = ShopSearchQueries.chunk(doc.content, 800, 100)
    local embedded = 0
    local has_emb = Catalog.hasEmbeddings()
    -- embed outside the transaction (network calls)
    local embs = {}
    for i, piece in ipairs(pieces) do
        embs[i] = has_emb and ShopSearchQueries.embed((doc.title or "") .. "\n" .. piece) or false
    end
    U.tx(function()
        db.query("DELETE FROM shop_knowledge_chunks WHERE namespace_id = ? AND source_type = ? AND source_ref = ?",
            ns_id, doc.source_type, doc.source_ref)
        for i, piece in ipairs(pieces) do
            local emb = embs[i] or nil
            if emb then embedded = embedded + 1 end
            local cols = "uuid, namespace_id, source_type, source_ref, title, url, chunk_index, content, created_at, updated_at"
            local vals = "?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW()"
            local args = { Global.generateUUID(), ns_id, doc.source_type, doc.source_ref,
                tostring(doc.title or ""):sub(1, 500), U.nz(doc.url) or db.NULL, i - 1, piece }
            if emb then
                cols = cols .. ", embedding"
                vals = vals .. ", ?::vector"
                args[#args + 1] = vec_literal(emb)
            end
            db.query("INSERT INTO shop_knowledge_chunks (" .. cols .. ") VALUES (" .. vals .. ")", unpack(args))
        end
        return true
    end)
    return { source_type = doc.source_type, source_ref = doc.source_ref, chunks = #pieces, embedded = embedded }
end

--- Admin POST /knowledge.
function ShopSearchQueries.addDocument(ns_id, body)
    local st = body.source_type
    if st ~= "faq" and st ~= "manual" and st ~= "url" then
        return nil, U.err(400, "VALIDATION_ERROR", "source_type must be faq, manual or url")
    end
    if not U.nz(body.title) then return nil, U.err(400, "VALIDATION_ERROR", "title is required") end
    if not U.nz(body.content) then return nil, U.err(400, "VALIDATION_ERROR", "content is required") end
    if #tostring(body.content) > 500000 then return nil, U.err(400, "VALIDATION_ERROR", "content too large") end
    local ref = U.nz(body.source_ref) and U.slugify(body.source_ref) or U.slugify(body.title)
    if ref == "" then ref = Global.generateUUID() end
    local content = tostring(body.content)
    if content:find("<%a") then content = strip_html(content) end
    return ShopSearchQueries.indexDocument(ns_id, {
        source_type = st, source_ref = ref, title = body.title, url = body.url, content = content,
    })
end

function ShopSearchQueries.deleteSource(ns_id, source_ref, source_type)
    local sql = "DELETE FROM shop_knowledge_chunks WHERE namespace_id = ? AND source_ref = ?"
    local res
    if U.nz(source_type) then
        res = db.query(sql .. " AND source_type = ?", ns_id, source_ref, source_type)
    else
        res = db.query(sql, ns_id, source_ref)
    end
    return res and res.affected_rows or 0
end

function ShopSearchQueries.listKnowledge(ns_id, params)
    params = params or {}
    local limit = U.clamp(U.int(params.limit, 50), 1, 500)
    local offset = math.max(0, U.int(params.offset, 0))
    local where, vals = { "namespace_id = ?" }, { ns_id }
    if U.nz(params.source_type) then
        where[#where + 1] = "source_type = ?"
        vals[#vals + 1] = params.source_type
    end
    if U.nz(params.q) then
        where[#where + 1] = "(title ILIKE ? OR source_ref ILIKE ?)"
        local like = like_pattern(tostring(params.q))
        vals[#vals + 1] = like
        vals[#vals + 1] = like
    end
    local emb_expr = Catalog.hasEmbeddings() and "COUNT(embedding)::int" or "0"
    vals[#vals + 1] = limit
    vals[#vals + 1] = offset
    local rows = db.query([[
        SELECT source_type, source_ref, MAX(title) AS title, MAX(url) AS url, COUNT(*)::int AS chunks,
               ]] .. emb_expr .. [[ AS embedded_chunks, SUM(length(content))::int AS characters,
               MAX(updated_at) AS updated_at, left(MIN(CASE WHEN chunk_index = 0 THEN content END), 240) AS preview,
               COUNT(*) OVER() AS total
          FROM shop_knowledge_chunks
         WHERE ]] .. table.concat(where, " AND ") .. [[
         GROUP BY source_type, source_ref
         ORDER BY MAX(updated_at) DESC LIMIT ? OFFSET ?
    ]], unpack(vals))
    local total = rows[1] and tonumber(rows[1].total) or 0
    for _, r in ipairs(rows) do
        r.total = nil
        r.has_embedding = (tonumber(r.embedded_chunks) or 0) > 0
        if r.url == nil then r.url = U.null end
    end
    return U.arr(rows), { total = total, limit = limit, offset = offset }
end

--- Product → knowledge document text.
local function product_text(p)
    local parts = { p.name }
    if U.nz(p.brand) then parts[#parts + 1] = "Brand: " .. p.brand end
    parts[#parts + 1] = "Type: " .. tostring(p.product_type) .. "; SKU: " .. tostring(p.sku)
    if U.nz(p.short_description) then parts[#parts + 1] = p.short_description end
    if U.nz(p.description) then parts[#parts + 1] = p.description end
    local specs = U.dec(p.specs, {})
    local keys = {}
    for k in pairs(specs) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. ": " .. tostring(specs[k]) end
    return table.concat(parts, "\n")
end

--- Admin POST /knowledge/reindex { sources: ["products","cms_posts"], blog_base_url? }
function ShopSearchQueries.reindex(ns_id, body)
    body = body or {}
    local sources = type(body.sources) == "table" and body.sources or { "products", "cms_posts" }
    local summary = { products = 0, cms_posts = 0, chunks = 0, embedded = 0, product_embeddings = 0 }
    local want = {}
    for _, s in ipairs(sources) do want[s] = true end

    if want.products then
        local rows = db.query("SELECT " .. Catalog.PRODUCT_COLS .. [[
              FROM shop_products p WHERE p.namespace_id = ? AND p.status = 'active' ORDER BY p.id]], ns_id)
        local has_emb = Catalog.hasEmbeddings()
        local keep = {}
        for _, p in ipairs(rows) do
            local text = product_text(p)
            local r = ShopSearchQueries.indexDocument(ns_id, {
                source_type = "product", source_ref = p.uuid, title = p.name, url = "/p/" .. p.slug, content = text,
            })
            keep[#keep + 1] = p.uuid
            summary.products = summary.products + 1
            summary.chunks = summary.chunks + r.chunks
            summary.embedded = summary.embedded + r.embedded
            if has_emb then
                local emb = ShopSearchQueries.embed(text)
                if emb then
                    db.query("UPDATE shop_products SET embedding = ?::vector WHERE id = ?", vec_literal(emb), p.id)
                    summary.product_embeddings = summary.product_embeddings + 1
                end
            end
        end
        -- drop chunks of products that are no longer active
        if #keep > 0 then
            db.query([[DELETE FROM shop_knowledge_chunks WHERE namespace_id = ? AND source_type = 'product'
                        AND NOT (source_ref = ANY(?))]], ns_id, db.array(keep))
        else
            db.query("DELETE FROM shop_knowledge_chunks WHERE namespace_id = ? AND source_type = 'product'", ns_id)
        end
    end

    if want.cms_posts then
        local exists = db.query("SELECT to_regclass('public.cms_posts') IS NOT NULL AS ok")[1].ok
        if exists then
            local base = U.nz(body.blog_base_url) or "/blog"
            base = tostring(base):gsub("/+$", "")
            local posts = db.query([[
                SELECT uuid, title, slug, excerpt, content_html FROM cms_posts
                 WHERE namespace_id = ? AND status = 'published' AND deleted_at IS NULL
                 ORDER BY id
            ]], ns_id)
            local keep = {}
            for _, post in ipairs(posts) do
                local text = (U.nz(post.excerpt) and (post.excerpt .. "\n\n") or "") .. strip_html(post.content_html)
                local r = ShopSearchQueries.indexDocument(ns_id, {
                    source_type = "cms_post", source_ref = post.uuid, title = post.title,
                    url = base .. "/" .. tostring(post.slug), content = text,
                })
                keep[#keep + 1] = post.uuid
                summary.cms_posts = summary.cms_posts + 1
                summary.chunks = summary.chunks + r.chunks
                summary.embedded = summary.embedded + r.embedded
            end
            if #keep > 0 then
                db.query([[DELETE FROM shop_knowledge_chunks WHERE namespace_id = ? AND source_type = 'cms_post'
                            AND NOT (source_ref = ANY(?))]], ns_id, db.array(keep))
            end
        else
            summary.cms_posts_skipped = "cms feature not installed"
        end
    end
    summary.semantic = Catalog.hasEmbeddings() and ngx.now() >= _breaker_until
    return summary
end

return ShopSearchQueries
