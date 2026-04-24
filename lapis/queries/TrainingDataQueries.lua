-- Training Data Queries (classification_training_data + classification_reference_data)
-- Handles pgvector embedding storage and similarity search for RAG.

local db = require("lapis.db")

local TrainingDataQueries = {}

--- Get pending rows (no embedding) for batch processing
function TrainingDataQueries.getPending(limit)
    limit = limit or 50
    return db.select(
        "* FROM classification_training_data WHERE embedding IS NULL ORDER BY id LIMIT ?",
        limit
    )
end

--- Update a row's embedding vector
function TrainingDataQueries.updateEmbedding(id, embedding)
    if not embedding or #embedding == 0 then return false end

    local vec_parts = {}
    for _, v in ipairs(embedding) do
        table.insert(vec_parts, tostring(v))
    end
    local vec_literal = "[" .. table.concat(vec_parts, ",") .. "]"

    db.query(
        "UPDATE classification_training_data SET embedding = ?::vector WHERE id = ?",
        vec_literal, id
    )
    return true
end

--- Search for similar transactions using pgvector cosine similarity
-- Searches both training_data and reference_data tables
function TrainingDataQueries.searchSimilar(embedding, limit, threshold)
    limit = limit or 5
    threshold = threshold or 0.7

    if not embedding or #embedding == 0 then return {} end

    local vec_parts = {}
    for _, v in ipairs(embedding) do
        table.insert(vec_parts, tostring(v))
    end
    local vec_literal = "[" .. table.concat(vec_parts, ",") .. "]"

    local sql = string.format([[
        SELECT * FROM (
            (SELECT id, original_description as description, category, hmrc_category,
                    confidence, is_tax_deductible, source,
                    1 - (embedding <=> '%s'::vector) as similarity
             FROM classification_training_data
             WHERE embedding IS NOT NULL
             ORDER BY embedding <=> '%s'::vector
             LIMIT %d)
            UNION ALL
            (SELECT id, description, category, hmrc_category,
                    confidence, is_tax_deductible, 'reference' as source,
                    1 - (embedding <=> '%s'::vector) as similarity
             FROM classification_reference_data
             WHERE embedding IS NOT NULL
             ORDER BY embedding <=> '%s'::vector
             LIMIT %d)
        ) combined
        WHERE similarity >= %f
        ORDER BY similarity DESC
        LIMIT %d
    ]], vec_literal, vec_literal, limit, vec_literal, vec_literal, limit, threshold, limit)

    local ok, results = pcall(db.query, sql)
    if not ok then return {} end
    return results or {}
end

--- Get training data statistics
function TrainingDataQueries.getStats()
    local training = db.query([[
        SELECT
            COUNT(*) as total,
            COUNT(embedding) as with_embedding,
            COUNT(*) - COUNT(embedding) as without_embedding,
            COUNT(*) FILTER (WHERE source = 'ai_classification') as ai_count,
            COUNT(*) FILTER (WHERE source = 'accountant_correction') as accountant_count,
            MAX(created_at) as last_created
        FROM classification_training_data
    ]])

    local reference = db.query([[
        SELECT
            COUNT(*) as total,
            COUNT(embedding) as with_embedding,
            COUNT(*) - COUNT(embedding) as without_embedding,
            MAX(created_at) as last_created
        FROM classification_reference_data
    ]])

    return {
        training = training and training[1] or {},
        reference = reference and reference[1] or {},
    }
end

--- Delete all embeddings (for re-embedding)
function TrainingDataQueries.deleteAllEmbeddings()
    db.query("UPDATE classification_training_data SET embedding = NULL")
    return true
end

--- Delete all reference embeddings
function TrainingDataQueries.deleteAllReferenceEmbeddings()
    db.query("UPDATE classification_reference_data SET embedding = NULL")
    return true
end

--- Get pending reference data rows
function TrainingDataQueries.getPendingReference(limit)
    limit = limit or 50
    return db.select(
        "* FROM classification_reference_data WHERE embedding IS NULL ORDER BY id LIMIT ?",
        limit
    )
end

--- Update reference data embedding
function TrainingDataQueries.updateReferenceEmbedding(id, embedding)
    if not embedding or #embedding == 0 then return false end

    local vec_parts = {}
    for _, v in ipairs(embedding) do
        table.insert(vec_parts, tostring(v))
    end
    local vec_literal = "[" .. table.concat(vec_parts, ",") .. "]"

    db.query(
        "UPDATE classification_reference_data SET embedding = ?::vector WHERE id = ?",
        vec_literal, id
    )
    return true
end

return TrainingDataQueries
