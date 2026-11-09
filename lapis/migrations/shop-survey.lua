-- luacheck: max line length 140
--[[
    Shop survey funnel events (FEATURES.SHOP)
    =========================================

    [1] shop_survey_events — one row per step a visitor takes through a shop survey (first: the Trade
        "What do I need?" survey at shop.workstation.co.uk/trade/what-do-i-need). Written by
        POST /api/v2/public/shop/:ns/survey-events, read by GET /api/v2/shop/admin/analytics/survey.

          survey      survey slug (default what-do-i-need)
          visitor_id  random id the browser makes up for the survey run; not linked to any account
          event       view | start | answer | back | result | lead | ask | apply
          step        question number, when the event belongs to one
          question    question key / label (answer events)
          answer      answer key / label
          product     product key the result recommended
          plan        Trade plan chosen on apply (y | m)

        Non-personal: no IP address, email, name or free text. Rows are kept for 13 months, then
        deleted by the daily job (ShopInsightsQueries.dailySnapshot, run by the market-sync CronJob).

    Registered in migrations.lua as zzs38. Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_survey_events (
                id bigserial PRIMARY KEY,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                survey varchar(48) NOT NULL DEFAULT 'what-do-i-need',
                visitor_id varchar(64) NOT NULL,
                event varchar(16) NOT NULL
                    CHECK (event IN ('view', 'start', 'answer', 'back', 'result', 'lead', 'ask', 'apply')),
                step smallint CHECK (step IS NULL OR step BETWEEN 0 AND 100),
                question varchar(120),
                answer varchar(120),
                product varchar(32),
                plan varchar(8),
                created_at timestamptz NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[
            COMMENT ON TABLE shop_survey_events IS
                'Shop survey funnel events. Non-personal (random visitor id, no IP/email/name). Retention: 13 months.'
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS shop_survey_events_window_idx
                ON shop_survey_events (namespace_id, survey, created_at)
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS shop_survey_events_event_idx
                ON shop_survey_events (namespace_id, survey, event, created_at)
        ]])
    end,
}
