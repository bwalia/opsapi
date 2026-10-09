local db = require("lapis.db")

-- Chat data lifecycle (CHAT_SCALING_RUNBOOK.md §2a).
return {
    -- Search runs on search_vector (ChatMessageQueries.search); this second
    -- full-text index on to_tsvector(content) was never used and only added
    -- write cost (~60 MB per million messages).
    [1] = function()
        db.query("DROP INDEX IF EXISTS chat_messages_content_search_idx")
    end,
}
