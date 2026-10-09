--[[
    Workspace AI providers and idempotent creates (core)
    ====================================================
      [1] namespace_ai_providers  a workspace's own model endpoints (gap map D11):
                                  cloud APIs with the workspace's key, local
                                  OpenAI-compatible servers, or a JobShout link.
                                  The key is sealed with AES-256-GCM
                                  (helper/secret-box.lua, D10) and never returned.
      [2] idempotency_keys        Idempotency-Key header → first response, per
                                  workspace + user, kept 24 h (helper/idempotency.lua).
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS namespace_ai_providers (
                id BIGSERIAL PRIMARY KEY,
                uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
                namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                name VARCHAR(120) NOT NULL,
                provider_type VARCHAR(30) NOT NULL CHECK (provider_type IN ('anthropic', 'openai', 'gemini',
                    'azure_openai', 'mistral', 'openai_compatible', 'ollama', 'jobshout')),
                base_url TEXT,
                default_model VARCHAR(160),
                models JSONB NOT NULL DEFAULT '[]',
                secret_sealed TEXT,
                secret_hint VARCHAR(12),
                username VARCHAR(255),
                options JSONB NOT NULL DEFAULT '{}',
                is_local BOOLEAN NOT NULL DEFAULT FALSE,
                enabled BOOLEAN NOT NULL DEFAULT TRUE,
                input_cost_per_mtok NUMERIC(12,4) NOT NULL DEFAULT 0 CHECK (input_cost_per_mtok >= 0),
                output_cost_per_mtok NUMERIC(12,4) NOT NULL DEFAULT 0 CHECK (output_cost_per_mtok >= 0),
                last_tested_at TIMESTAMPTZ,
                last_error TEXT,
                created_by VARCHAR(255),
                updated_by VARCHAR(255),
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE (namespace_id, name)
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS idx_ns_ai_providers_ns ON namespace_ai_providers (namespace_id, enabled)")
    end,

    [2] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS idempotency_keys (
                id BIGSERIAL PRIMARY KEY,
                namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                user_uuid VARCHAR(255) NOT NULL,
                idem_key VARCHAR(255) NOT NULL,
                method VARCHAR(10) NOT NULL,
                path TEXT NOT NULL,
                request_sha256 VARCHAR(64) NOT NULL,
                status INTEGER,
                response JSONB,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE (namespace_id, user_uuid, idem_key)
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS idx_idempotency_keys_created ON idempotency_keys (created_at)")
    end,
}
