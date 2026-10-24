-- AI Runs — start AI coding agents (Claude Code, Cursor) on kanban tasks (OpsAPI plugin).
-- Design: docs/AI_RUNNER.md (Phase 2 contract: §22).
--
-- Machines pull: a runner (PromptPilot runner mode) registered here with a workspace token heartbeats, claims
-- queued runs, works in the folder the user chose on a new branch and reports status and events back. Users and
-- managers start, watch, cancel and retry runs. Needs kanban; without it the plugin switches itself off.
local ProjectConfig = require("helper.project-config")

local function module(machine_name, name, description)
    return { machine_name = machine_name, name = name, category = "AI Runs", description = description }
end

return {
    code = "ai_runner",           -- stable id: keys migrations + RBAC; never rename
    name = "AI Runs",
    icon = "Bot",
    version = "0.1.0",
    description = "Start AI coding agents on tasks; runners on your machines claim and run them.",
    sdk_version = 1,
    depends = { "core", "kanban" },
    enabled = ProjectConfig.isKanbanEnabled(),
    default_enabled = false,      -- opt-in per workspace (Workspace -> Plugins)

    modules = {
        module("ai_runs", "AI runs", "Start, watch, cancel and retry AI runs on tasks (manage = every run)"),
        module("ai_runs_approvals", "AI run approvals", "Decide the permission requests of AI runs"),
        module("ai_runners", "AI runners", "Register, pause and revoke the machines that run AI runs"),
        module("ai_runs_settings", "AI run settings", "Workspace AI run settings and the prompt template"),
        module("ai_terminal_autologin", "Web terminal auto sign-in",
            "Be signed in to a web terminal by Start with AI (after an emailed code; the terminal must also allow you)"),
    },

    -- Native pages in opsapi-dashboard/app/dashboard/ai-runner.
    menu = {
        { label = "AI Runs", route = "/dashboard/ai-runner/runs", module = "ai_runs", icon = "Bot" },
        { label = "Runners & sources", route = "/dashboard/ai-runner/runners", module = "ai_runners", icon = "Server" },
        { label = "Machines", route = "/dashboard/ai-runner/machines", module = "ai_runners", icon = "Monitor" },
        { label = "AI run settings", route = "/dashboard/ai-runner/settings", module = "ai_runs_settings",
          icon = "Settings" },
    },

    -- Settings live in ar_settings / ar_project_settings / ar_prompt_templates (they have nested values and
    -- versions), edited through this plugin's API, not Workspace -> Plugins.
}
