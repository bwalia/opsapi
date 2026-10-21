---
title: Marketing Cloud
pages: /dashboard/opsapi-marketing
api: /api/v2/opsapi-marketing
modules: opsapi_marketing_campaigns, opsapi_marketing_lists, opsapi_marketing_templates, opsapi_marketing_consent, opsapi_marketing_analytics, opsapi_marketing_conversations, opsapi_marketing_ai, opsapi_marketing_settings
tools: mkt_campaign_overview, mkt_audience_preview, mkt_draft_campaign, mkt_classify_reply, mkt_check_eligibility
suggestions: Summarise campaign performance this month | Draft an email campaign for our newsletter list | Is this contact eligible for SMS? | Classify this reply: not interested thanks
readonly: false
---
# Marketing Cloud
Multi-channel marketing (email + SMS) on CRM contacts. Consent, suppression and quiet hours are enforced in code by `can_send` — AI cannot override them. Opens are always estimated.

## Pages
- **Overview** (/dashboard/opsapi-marketing/overview): campaign + delivery snapshot.
- **Campaigns** (/dashboard/opsapi-marketing/campaigns): draft → validate → approve → schedule → send. A/B and max_deliveries supported.
- **Studio** (/dashboard/opsapi-marketing/studio): TipTap email + SMS composers with merge fields.
- **Conversations** (/dashboard/opsapi-marketing/conversations): inbound replies and classifications.
- **Lists / Suppressions**: plugin CRUD under /dashboard/plugins/opsapi_marketing/.

## Answers
- Workspace snapshot: `GET /api/v2/opsapi-marketing/analytics/overview`
- Campaign breakdown: `GET /api/v2/opsapi-marketing/analytics/campaigns/{uuid}`
- Contact timeline: `GET /api/v2/opsapi-marketing/analytics/contacts/{contact_uuid}`
- Replies: `GET /api/v2/opsapi-marketing/replies`
- Classify preview: `POST /api/v2/opsapi-marketing/replies/classify-preview`
- Audience preview: `POST /api/v2/opsapi-marketing/campaigns/{uuid}/audience-preview`

## Rules
- Never send, schedule, approve, or remove suppressions for the user — point them to the campaign page.
- Draft campaigns only; always remind that validate → approve → schedule is required.
- Label opens as estimated.
- Never invent consent; never auto-reply from a classification.
- Prefer tools `mkt_*` over inventing API bodies.
