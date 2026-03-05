--[[
  Project Configuration Helper

  This module manages project-based conditional feature loading.
  Set the PROJECT_CODE environment variable to control which features are enabled.

  Usage:
    PROJECT_CODE=tax_copilot  (Only core + tax features)
    PROJECT_CODE=ecommerce    (Core + full ecommerce suite)
    PROJECT_CODE=all          (All features - default for backward compatibility)

  Multiple projects can be combined with comma:
    PROJECT_CODE=ecommerce,chat
]]

local ProjectConfig = {}

-- Define all available feature modules
ProjectConfig.FEATURES = {
    -- Core features (always included for any project)
    CORE = "core",

    -- Optional feature modules
    ECOMMERCE = "ecommerce",           -- Stores, products, orders, payments
    DELIVERY = "delivery",             -- Delivery partner system
    CHAT = "chat",                     -- Slack-like messaging
    KANBAN = "kanban",                 -- Project management
    HOSPITAL = "hospital",             -- Hospital CRM
    NOTIFICATIONS = "notifications",   -- Push notifications
    REVIEWS = "reviews",               -- Product/store reviews
    MENU = "menu",                     -- Backend-driven navigation
    VAULT = "vault",                   -- Secret vault
    SERVICES = "services",             -- GitHub workflow integration
    BANK_TRANSACTIONS = "bank_transactions", -- Bank transaction tracking

    -- New project-specific features
    TAX_COPILOT = "tax_copilot",       -- UK Tax Return AI Agent
}

-- Define what features each project code includes
ProjectConfig.PROJECT_FEATURES = {
    -- All features (backward compatibility / development)
    all = {
        ProjectConfig.FEATURES.CORE,
        ProjectConfig.FEATURES.ECOMMERCE,
        ProjectConfig.FEATURES.DELIVERY,
        ProjectConfig.FEATURES.CHAT,
        ProjectConfig.FEATURES.KANBAN,
        ProjectConfig.FEATURES.HOSPITAL,
        ProjectConfig.FEATURES.NOTIFICATIONS,
        ProjectConfig.FEATURES.REVIEWS,
        ProjectConfig.FEATURES.MENU,
        ProjectConfig.FEATURES.VAULT,
        ProjectConfig.FEATURES.SERVICES,
        ProjectConfig.FEATURES.BANK_TRANSACTIONS,
        ProjectConfig.FEATURES.TAX_COPILOT,
    },

    -- Tax Copilot - UK Tax Return AI Agent
    -- Core auth + tax-specific tables + menu (required for dashboard navigation)
    tax_copilot = {
        ProjectConfig.FEATURES.CORE,
        ProjectConfig.FEATURES.TAX_COPILOT,
        ProjectConfig.FEATURES.NOTIFICATIONS,
        ProjectConfig.FEATURES.MENU,
    },

    -- Ecommerce platform
    ecommerce = {
        ProjectConfig.FEATURES.CORE,
        ProjectConfig.FEATURES.ECOMMERCE,
        ProjectConfig.FEATURES.DELIVERY,
        ProjectConfig.FEATURES.NOTIFICATIONS,
        ProjectConfig.FEATURES.REVIEWS,
        ProjectConfig.FEATURES.MENU,
    },

    -- Ecommerce with chat
    ecommerce_chat = {
        ProjectConfig.FEATURES.CORE,
        ProjectConfig.FEATURES.ECOMMERCE,
        ProjectConfig.FEATURES.DELIVERY,
        ProjectConfig.FEATURES.CHAT,
        ProjectConfig.FEATURES.NOTIFICATIONS,
        ProjectConfig.FEATURES.REVIEWS,
        ProjectConfig.FEATURES.MENU,
    },

    -- Full collaboration platform
    collaboration = {
        ProjectConfig.FEATURES.CORE,
        ProjectConfig.FEATURES.CHAT,
        ProjectConfig.FEATURES.KANBAN,
        ProjectConfig.FEATURES.NOTIFICATIONS,
        ProjectConfig.FEATURES.MENU,
        ProjectConfig.FEATURES.VAULT,
        ProjectConfig.FEATURES.SERVICES,
    },

    -- Hospital CRM
    hospital = {
        ProjectConfig.FEATURES.CORE,
        ProjectConfig.FEATURES.HOSPITAL,
        ProjectConfig.FEATURES.NOTIFICATIONS,
        ProjectConfig.FEATURES.MENU,
    },

    -- Minimal core only (just auth system + menu for dashboard)
    core_only = {
        ProjectConfig.FEATURES.CORE,
        ProjectConfig.FEATURES.MENU,
    },
}

-- Cache for enabled features
local _enabled_features = nil

-- Get the project code from environment
function ProjectConfig.getProjectCode()
    return os.getenv("PROJECT_CODE") or "all"
end

-- Parse project codes (supports comma-separated for combining)
function ProjectConfig.parseProjectCodes()
    local project_code = ProjectConfig.getProjectCode()
    local codes = {}

    for code in string.gmatch(project_code, "[^,]+") do
        local trimmed = code:match("^%s*(.-)%s*$") -- trim whitespace
        if trimmed and #trimmed > 0 then
            table.insert(codes, trimmed:lower())
        end
    end

    return codes
end

-- Get all enabled features for current project(s)
function ProjectConfig.getEnabledFeatures()
    if _enabled_features then
        return _enabled_features
    end

    local features = {}
    local feature_set = {}

    local project_codes = ProjectConfig.parseProjectCodes()

    for _, code in ipairs(project_codes) do
        local project_features = ProjectConfig.PROJECT_FEATURES[code]
        if project_features then
            for _, feature in ipairs(project_features) do
                if not feature_set[feature] then
                    feature_set[feature] = true
                    table.insert(features, feature)
                end
            end
        else
            -- Unknown project code - log warning but continue
            print("[ProjectConfig] Warning: Unknown PROJECT_CODE '" .. code .. "', skipping")
        end
    end

    -- Always ensure CORE is included
    if not feature_set[ProjectConfig.FEATURES.CORE] then
        table.insert(features, 1, ProjectConfig.FEATURES.CORE)
        feature_set[ProjectConfig.FEATURES.CORE] = true
    end

    _enabled_features = features
    return features
end

-- Check if a specific feature is enabled
function ProjectConfig.isFeatureEnabled(feature)
    local features = ProjectConfig.getEnabledFeatures()
    for _, f in ipairs(features) do
        if f == feature then
            return true
        end
    end
    return false
end

-- Shorthand checks for common features
function ProjectConfig.isCoreEnabled()
    return true -- Core is always enabled
end

function ProjectConfig.isEcommerceEnabled()
    return ProjectConfig.isFeatureEnabled(ProjectConfig.FEATURES.ECOMMERCE)
end

function ProjectConfig.isDeliveryEnabled()
    return ProjectConfig.isFeatureEnabled(ProjectConfig.FEATURES.DELIVERY)
end

function ProjectConfig.isChatEnabled()
    return ProjectConfig.isFeatureEnabled(ProjectConfig.FEATURES.CHAT)
end

function ProjectConfig.isKanbanEnabled()
    return ProjectConfig.isFeatureEnabled(ProjectConfig.FEATURES.KANBAN)
end

function ProjectConfig.isHospitalEnabled()
    return ProjectConfig.isFeatureEnabled(ProjectConfig.FEATURES.HOSPITAL)
end

function ProjectConfig.isNotificationsEnabled()
    return ProjectConfig.isFeatureEnabled(ProjectConfig.FEATURES.NOTIFICATIONS)
end

function ProjectConfig.isReviewsEnabled()
    return ProjectConfig.isFeatureEnabled(ProjectConfig.FEATURES.REVIEWS)
end

function ProjectConfig.isMenuEnabled()
    return ProjectConfig.isFeatureEnabled(ProjectConfig.FEATURES.MENU)
end

function ProjectConfig.isVaultEnabled()
    return ProjectConfig.isFeatureEnabled(ProjectConfig.FEATURES.VAULT)
end

function ProjectConfig.isServicesEnabled()
    return ProjectConfig.isFeatureEnabled(ProjectConfig.FEATURES.SERVICES)
end

function ProjectConfig.isBankTransactionsEnabled()
    return ProjectConfig.isFeatureEnabled(ProjectConfig.FEATURES.BANK_TRANSACTIONS)
end

function ProjectConfig.isTaxCopilotEnabled()
    return ProjectConfig.isFeatureEnabled(ProjectConfig.FEATURES.TAX_COPILOT)
end

-- Get project info for debugging/logging
function ProjectConfig.getProjectInfo()
    return {
        project_code = ProjectConfig.getProjectCode(),
        project_codes = ProjectConfig.parseProjectCodes(),
        enabled_features = ProjectConfig.getEnabledFeatures(),
    }
end

-- Print project configuration (useful for startup logs)
function ProjectConfig.printConfig()
    local info = ProjectConfig.getProjectInfo()
    print("=== Project Configuration ===")
    print("PROJECT_CODE: " .. info.project_code)
    print("Parsed codes: " .. table.concat(info.project_codes, ", "))
    print("Enabled features: " .. table.concat(info.enabled_features, ", "))
    print("=============================")
end

-- Reset cache (useful for testing)
function ProjectConfig.resetCache()
    _enabled_features = nil
end

-- =============================================================================
-- RBAC MODULE DEFINITIONS PER FEATURE
-- =============================================================================
-- Maps feature names to their RBAC modules (for the modules DB table).
-- When a project is set up, only modules relevant to its enabled features are seeded.

ProjectConfig.PROJECT_MODULES = {
    -- Core modules (always included for any project)
    -- allowed_actions: which actions the UI should show. nil = full CRUD + manage (default).
    core = {
        { machine_name = "dashboard", name = "Admin Dashboard", description = "Admin panel access and analytics dashboard", category = "Core", is_system = true, allowed_actions = {"access"} },
        { machine_name = "users", name = "Users", description = "User management within namespace", category = "Core", is_system = true },
        { machine_name = "roles", name = "Roles", description = "Role management within namespace", category = "Core", is_system = true },
        { machine_name = "settings", name = "Settings", description = "Namespace settings", category = "Core", is_system = true },
        { machine_name = "reports", name = "Reports", description = "Analytics and reports", category = "Core", allowed_actions = {"access"} },
    },

    -- Ecommerce modules
    ecommerce = {
        { machine_name = "stores", name = "Stores", description = "Store management", category = "Commerce" },
        { machine_name = "products", name = "Products", description = "Product catalog management", category = "Commerce" },
        { machine_name = "orders", name = "Orders", description = "Order processing", category = "Commerce" },
        { machine_name = "customers", name = "Customers", description = "Customer management", category = "Commerce" },
    },

    -- Delivery modules
    delivery = {
        { machine_name = "delivery", name = "Delivery", description = "Delivery partners management", category = "Commerce" },
    },

    -- Chat modules
    chat = {
        { machine_name = "chat", name = "Chat", description = "Chat and messaging", category = "Communication" },
    },

    -- Kanban modules
    kanban = {
        { machine_name = "projects", name = "Projects", description = "Kanban projects and tasks", category = "Productivity" },
    },

    -- Services modules
    services = {
        { machine_name = "services", name = "Services", description = "Service deployment and management", category = "Infrastructure" },
    },

    -- Hospital modules
    hospital = {
        { machine_name = "hospital_patients", name = "Patients", description = "Patient management", category = "Hospital" },
        { machine_name = "hospital_appointments", name = "Appointments", description = "Appointment scheduling", category = "Hospital" },
        { machine_name = "hospital_records", name = "Medical Records", description = "Medical records management", category = "Hospital" },
    },

    -- Tax Copilot modules
    tax_copilot = {
        { machine_name = "tax_support", name = "Support Chat", description = "View and reply to support conversations", category = "Tax", allowed_actions = {"read", "reply"} },
        { machine_name = "tax_transactions", name = "Transactions", description = "Bank transaction tracking", category = "Tax" },
        { machine_name = "tax_categories", name = "Categories", description = "Transaction categories", category = "Tax" },
        { machine_name = "tax_bank_accounts", name = "Bank Accounts", description = "Bank account management", category = "Tax", allowed_actions = {"access"} },
        { machine_name = "tax_statements", name = "Statements", description = "Bank statement uploads", category = "Tax" },
        { machine_name = "tax_file", name = "HMRC Filing", description = "Submit tax returns to HMRC", category = "Tax", allowed_actions = {"access"} },
    },
}

--- Get RBAC modules for current PROJECT_CODE (core + project-specific features)
-- @return table List of module definitions
function ProjectConfig.getProjectModules()
    local modules = {}
    local seen = {}

    -- Always include core modules
    for _, m in ipairs(ProjectConfig.PROJECT_MODULES.core) do
        if not seen[m.machine_name] then
            seen[m.machine_name] = true
            table.insert(modules, m)
        end
    end

    -- Add modules for each enabled feature
    local features = ProjectConfig.getEnabledFeatures()
    for _, feature in ipairs(features) do
        local feature_modules = ProjectConfig.PROJECT_MODULES[feature]
        if feature_modules then
            for _, m in ipairs(feature_modules) do
                if not seen[m.machine_name] then
                    seen[m.machine_name] = true
                    table.insert(modules, m)
                end
            end
        end
    end

    return modules
end

return ProjectConfig
