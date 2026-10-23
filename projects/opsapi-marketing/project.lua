-- OpsAPI Marketing Cloud — multi-channel marketing automation plugin.
-- Channel-agnostic: email (v1 reference) and sms adapters (opsapi_marketing/channels).
-- Reliable delivery: Postgres transactional outbox + leased plugin jobs (NOT Kafka).
local ProjectConfig = require("helper.project-config")

local function module(machine_name, name, description)
    return {
        machine_name = machine_name,
        name = name,
        category = "Marketing",
        description = description,
    }
end

return {
    code = "opsapi_marketing",
    name = "Marketing Cloud",
    icon = "Megaphone",
    version = "0.2.0",
    description = "Multi-channel campaigns, consent, suppression, and AI-assisted engagement on CRM data.",
    sdk_version = 1,
    depends = { "core", "crm" },
    enabled = ProjectConfig.isCrmEnabled(),
    default_enabled = false,

    modules = {
        module("opsapi_marketing_campaigns", "Campaigns", "Campaigns, schedules and delivery"),
        module("opsapi_marketing_lists", "Lists & segments", "Static lists and dynamic segments"),
        module("opsapi_marketing_templates", "Templates", "Channel templates and the studio"),
        module("opsapi_marketing_consent", "Consent & suppression", "Consent, subscriptions and suppression"),
        module("opsapi_marketing_analytics", "Analytics", "Opens, clicks, conversions and reports"),
        module("opsapi_marketing_conversations", "Conversations", "Inbound replies and threads"),
        module("opsapi_marketing_ai", "AI assistant", "Campaign planner, copywriter and reply analyst"),
        module("opsapi_marketing_settings", "Settings", "Channels, providers, quotas and retention"),
        -- opsapi:modules
    },

    publishes = {
        campaign = {
            table = "mkt_campaigns",
            verbs = {
                scheduled = { status = "scheduled" },
                sending = { status = "sending" },
                completed = { status = "completed" },
                paused = { status = "paused" },
                cancelled = { status = "cancelled" },
                failed = { status = "failed" },
            },
            emits = { "validated" },
        },
        delivery = {
            table = "mkt_deliveries",
            hide = "body_html,body_text,subject",
            verbs = {
                queued = { state = "queued" },
                accepted = { state = "accepted" },
                delivered = { state = "delivered" },
                bounced = { state = "bounced" },
                failed = { state = "failed" },
            },
            emits = { "opened", "clicked", "replied" },
        },
        subscription = {
            table = "mkt_subscriptions",
            verbs = {
                opted_in = { status = "subscribed" },
                opted_out = { status = "unsubscribed" },
            },
        },
        suppression = { table = "mkt_suppressions" },
        list = { table = "mkt_lists" },
        template = { table = "mkt_templates", hide = "body_html,body_text" },
        tracking_event = { table = "mkt_tracking_events", hide = "ip_hash,user_agent" },
        conversion = { table = "mkt_conversions", emits = { "recorded" } },
        -- opsapi:publishes
    },

    pages = {
        -- opsapi:pages
    },

    menu = {
        { label = "Getting started", route = "/dashboard/opsapi-marketing/guide",
          module = "opsapi_marketing_campaigns", icon = "BookOpen" },
        { label = "Overview", route = "/dashboard/opsapi-marketing/overview",
          module = "opsapi_marketing_analytics", icon = "LayoutDashboard" },
        { label = "Campaigns", route = "/dashboard/opsapi-marketing/campaigns",
          module = "opsapi_marketing_campaigns", icon = "Send" },
        { label = "Lists", route = "/dashboard/opsapi-marketing/lists",
          module = "opsapi_marketing_lists", icon = "Users" },
        { label = "Pixels & attribution", route = "/dashboard/opsapi-marketing/pixels",
          module = "opsapi_marketing_analytics", icon = "Radar" },
        { label = "Studio", route = "/dashboard/opsapi-marketing/studio",
          module = "opsapi_marketing_templates", icon = "Palette" },
        { label = "Templates", resource = "templates", module = "opsapi_marketing_templates", icon = "FileText" },
        { label = "Conversations", route = "/dashboard/opsapi-marketing/conversations",
          module = "opsapi_marketing_conversations", icon = "MessageSquare" },
        { label = "Suppressions", resource = "suppressions",
          module = "opsapi_marketing_consent", icon = "ShieldOff" },
        { label = "Settings", route = "/dashboard/opsapi-marketing/settings",
          module = "opsapi_marketing_settings", icon = "Settings" },
        -- opsapi:menu
    },

    settings = {
        timezone = {
            type = "string", label = "Workspace time zone", default = "Europe/London",
            description = "IANA zone for quiet hours and scheduled sends.",
        },
        jurisdiction = {
            type = "string", label = "Marketing jurisdiction", default = "uk",
            enum = { "uk", "eu", "us", "other" },
            description = "Drives consent and List-Unsubscribe expectations.",
        },
        require_approval = {
            type = "boolean", label = "Every campaign needs approval", default = false,
            description = "Someone with Campaigns manage access, other than the campaign's author, must approve it.",
        },
        dry_run = {
            type = "boolean", label = "Test mode: don't really send (dry run)", default = false,
            description = "Everything works but no email or SMS leaves, test emails to yourself included. "
                .. "Switch off when you are ready to send.",
        },
        default_from_email = {
            type = "string", label = "Default from email", default = "",
            description = "Fallback when workspace SMTP has no from address.",
        },
        default_from_name = {
            type = "string", label = "Default from name", default = "Marketing",
        },
        sender_address = {
            type = "text", label = "Business name and postal address (email footer)", default = "",
            description = "Shown in every marketing email. UK PECR and US CAN-SPAM require it for promotional email.",
        },
        email_rate_per_min = {
            type = "integer", label = "Email sends per minute", default = 60, min = 1, max = 10000,
        },
        email_daily_limit = {
            type = "integer", label = "Emails per day (0 = no limit)", default = 0, min = 0, max = 1000000,
            description = "Your SMTP provider's daily cap, e.g. 500 for Gmail, 2,000 for Google Workspace. "
                .. "Emails over it wait in the queue for the next day.",
        },
        email_parallel = {
            type = "integer", label = "Emails sent at once", default = 1, min = 1, max = 10,
            description = "Separate SMTP connections used together. Raise it if your provider allows.",
        },
        sms_rate_per_min = {
            type = "integer", label = "SMS sends per minute", default = 30, min = 1, max = 1000,
        },
        quiet_hours_from = {
            type = "string", label = "Quiet hours start (local HH:MM)", default = "21:00",
        },
        quiet_hours_to = {
            type = "string", label = "Quiet hours end (local HH:MM)", default = "08:00",
        },
        marketing_frequency_cap_days = {
            type = "integer", label = "Max marketing messages per contact per N days",
            default = 7, min = 1, max = 90,
        },
        marketing_frequency_cap_count = {
            type = "integer", label = "…count", default = 3, min = 1, max = 50,
        },
        sms_gateway_url = {
            type = "url", label = "SMS gateway base URL",
            description = "Android SMS Gateway / HTTP provider base (e.g. https://sms.example/api).",
        },
        sms_gateway_username = {
            type = "string", label = "SMS gateway username", default = "",
        },
        sms_gateway_password = {
            type = "string", label = "SMS gateway password", secret = true,
            description = "Stored encrypted per workspace.",
        },
        tracking_retention_days = {
            type = "integer", label = "Keep raw tracking events (days)", default = 365,
            min = 30, max = 3650,
        },
        meta_pixel_id = {
            type = "string", label = "Meta pixel / dataset ID", default = "",
            description = "Forward conversions server-side to Meta Conversions API.",
        },
        meta_capi_access_token = {
            type = "string", label = "Meta Conversions API access token", secret = true,
        },
        meta_test_event_code = {
            type = "string", label = "Meta test event code", default = "",
            description = "Shows forwarded events in Events Manager → Test events. Clear for live.",
        },
        ga4_measurement_id = {
            type = "string", label = "GA4 measurement ID", default = "",
            description = "e.g. G-XXXXXXX — forward conversions via the Measurement Protocol.",
        },
        ga4_api_secret = {
            type = "string", label = "GA4 Measurement Protocol API secret", secret = true,
        },
        forward_page_views = {
            type = "boolean", label = "Also forward page views", default = false,
            description = "Off by default: conversions and custom events only.",
        },
        public_base_url = {
            type = "string", label = "Public tracking/unsubscribe base URL", default = "",
            description = "e.g. https://api.example.com — used in List-Unsubscribe and pixels.",
        },
    },
}
