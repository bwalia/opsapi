#!/bin/bash
# =============================================================================
# OPSAPI Project CLI
#
# Manage modular projects within the OPSAPI platform.
#
# Usage:
#   ./scripts/opsapi-project.sh create <project-code>     Scaffold a new project
#   ./scripts/opsapi-project.sh list                       List discovered projects
#   ./scripts/opsapi-project.sh info <project-code>        Show project manifest
#   ./scripts/opsapi-project.sh migrate <project-code>     Run migrations for one project
#   ./scripts/opsapi-project.sh migrate --all              Run migrations for all projects
#   ./scripts/opsapi-project.sh status <project-code>      Show migration status
#
# Environment:
#   OPSAPI_CONTAINER  Container name (default: opsapi)
#   PROJECTS_DIR      Projects directory (default: ./projects)
# =============================================================================

set -euo pipefail

OPSAPI_CONTAINER="${OPSAPI_CONTAINER:-opsapi}"
PROJECTS_DIR="${PROJECTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)/projects}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN} OPSAPI Project Manager${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_usage() {
    print_header
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  create <code>          Scaffold a new project"
    echo "  list                   List all discovered projects"
    echo "  info <code>            Show project details"
    echo "  migrate <code>         Run migrations for a project"
    echo "  migrate --all          Run migrations for all projects"
    echo "  status <code>          Show migration status"
    echo ""
    echo "Examples:"
    echo "  $0 create hospital-patient-manager"
    echo "  $0 list"
    echo "  $0 migrate hospital-patient-manager"
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# CREATE: Scaffold a new project
# ──────────────────────────────────────────────────────────────────────────────
cmd_create() {
    local code="$1"

    if [[ -z "$code" ]]; then
        echo -e "${RED}Error: Project code is required${NC}"
        echo "Usage: $0 create <project-code>"
        exit 1
    fi

    # Validate code format (lowercase, hyphens, alphanumeric)
    if ! [[ "$code" =~ ^[a-z][a-z0-9-]*$ ]]; then
        echo -e "${RED}Error: Project code must be lowercase alphanumeric with hyphens (e.g., my-project)${NC}"
        exit 1
    fi

    local project_dir="${PROJECTS_DIR}/${code}"

    if [[ -d "$project_dir" ]]; then
        echo -e "${RED}Error: Project directory already exists: ${project_dir}${NC}"
        exit 1
    fi

    echo -e "${GREEN}Creating project: ${code}${NC}"

    # Create directory structure
    mkdir -p "${project_dir}"/{api,migrations,services,queries,models,dashboards,themes/default}

    # Convert code to lua-safe name (hyphens to underscores)
    local lua_code="${code//-/_}"
    # Create short prefix (first letter of each word)
    local prefix=$(echo "$code" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) printf substr($i,1,1)}')

    # Generate project.lua
    cat > "${project_dir}/project.lua" <<LUAEOF
return {
    code = "${lua_code}",
    name = "$(echo "$code" | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')",
    version = "0.1.0",
    description = "TODO: Add project description",
    enabled = true,

    -- Features this project depends on from core OPSAPI
    depends = { "core", "menu", "notifications" },

    -- Feature code this project registers
    feature = "${lua_code}",

    -- RBAC modules
    modules = {
        -- { machine_name = "${prefix}_example", name = "Example", description = "Example module", category = "$(echo "$code" | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')" },
    },

    -- Dashboard configuration
    dashboard = {
        menu_items = {
            -- { label = "Home", icon = "home", path = "/" },
        },
    },

    -- Theme (matches /themes/<name>/ directory)
    theme = "default",
}
LUAEOF

    # Generate theme.json
    cat > "${project_dir}/themes/default/theme.json" <<JSONEOF
{
    "name": "Default",
    "primary_color": "#2563eb",
    "secondary_color": "#1e40af",
    "accent_color": "#3b82f6",
    "font_family": "Inter, sans-serif",
    "layout": "modern"
}
JSONEOF

    # Generate styles.css
    cat > "${project_dir}/themes/default/styles.css" <<CSSEOF
/* Custom styles for ${code} */
:root {
    --project-primary: #2563eb;
    --project-secondary: #1e40af;
    --project-accent: #3b82f6;
}
CSSEOF

    # Generate example migration
    cat > "${project_dir}/migrations/001_initial_setup.lua" <<LUAEOF
-- Initial setup migration for ${code}
-- Table names should be prefixed with '${prefix}_' to avoid collisions
return function(schema, db)
    local types = schema.types

    -- Example table - replace with your actual schema
    -- schema.create_table("${prefix}_example", {
    --     { "id", types.serial },
    --     { "uuid", "UUID DEFAULT gen_random_uuid() UNIQUE" },
    --     { "namespace_id", types.integer },
    --     { "name", types.varchar },
    --     { "status", "VARCHAR(50) DEFAULT 'active'" },
    --     { "created_at", "TIMESTAMP WITH TIME ZONE DEFAULT NOW()" },
    --     { "updated_at", "TIMESTAMP WITH TIME ZONE DEFAULT NOW()" },
    --     "PRIMARY KEY (id)"
    -- })
    -- schema.create_index("${prefix}_example", "namespace_id")

    print("[${lua_code}] Initial setup migration completed")
end
LUAEOF

    # Generate example route
    cat > "${project_dir}/api/health.lua" <<LUAEOF
-- Health check route for ${code}
-- Mounted at: /api/v2/${code}/health

return function(app)
    app:get("/health", function(self)
        return {
            status = 200,
            json = {
                project = "${lua_code}",
                status = "healthy",
                version = "0.1.0",
            }
        }
    end)
end
LUAEOF

    echo -e "${GREEN}Project scaffolded successfully!${NC}"
    echo ""
    echo "  Directory: ${project_dir}"
    echo ""
    echo "  Structure:"
    echo "    project.lua              -- Project manifest"
    echo "    api/health.lua           -- Example route"
    echo "    migrations/001_*.lua     -- Initial migration (template)"
    echo "    services/               -- Business logic"
    echo "    queries/                -- Database queries"
    echo "    models/                 -- Lapis models"
    echo "    dashboards/            -- Dashboard JSON definitions"
    echo "    themes/default/        -- Default theme"
    echo ""
    echo "  Next steps:"
    echo "    1. Edit project.lua with your project details"
    echo "    2. Add migrations in migrations/"
    echo "    3. Add API routes in api/"
    echo "    4. Run: $0 migrate ${code}"
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# LIST: Show all discovered projects
# ──────────────────────────────────────────────────────────────────────────────
cmd_list() {
    print_header
    echo ""

    if [[ ! -d "$PROJECTS_DIR" ]]; then
        echo -e "${YELLOW}No projects directory found at: ${PROJECTS_DIR}${NC}"
        exit 0
    fi

    local count=0
    for project_dir in "${PROJECTS_DIR}"/*/; do
        if [[ -f "${project_dir}project.lua" ]]; then
            local code=$(basename "$project_dir")
            local name=$(grep -oP 'name\s*=\s*"\K[^"]+' "${project_dir}project.lua" | head -1)
            local version=$(grep -oP 'version\s*=\s*"\K[^"]+' "${project_dir}project.lua" | head -1)
            local enabled=$(grep -oP 'enabled\s*=\s*\K\w+' "${project_dir}project.lua" | head -1)

            local status_icon="+"
            local status_color="${GREEN}"
            if [[ "$enabled" == "false" ]]; then
                status_icon="-"
                status_color="${RED}"
            fi

            printf "  ${status_color}[${status_icon}]${NC} %-35s ${CYAN}v%-8s${NC} %s\n" \
                "$code" "${version:-0.0.0}" "${name:-Unknown}"
            count=$((count + 1))
        fi
    done

    if [[ $count -eq 0 ]]; then
        echo -e "  ${YELLOW}No projects found. Create one with:${NC}"
        echo "    $0 create <project-code>"
    else
        echo ""
        echo -e "  ${GREEN}${count} project(s) discovered${NC}"
    fi
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# INFO: Show project details
# ──────────────────────────────────────────────────────────────────────────────
cmd_info() {
    local code="$1"
    local project_dir="${PROJECTS_DIR}/${code}"

    if [[ ! -f "${project_dir}/project.lua" ]]; then
        echo -e "${RED}Error: Project not found: ${code}${NC}"
        exit 1
    fi

    print_header
    echo ""
    echo -e "  ${CYAN}Project: ${code}${NC}"
    echo ""
    echo "  Manifest (project.lua):"
    cat "${project_dir}/project.lua" | sed 's/^/    /'
    echo ""

    # Count files
    local api_count=$(find "${project_dir}/api" -name "*.lua" 2>/dev/null | wc -l)
    local migration_count=$(find "${project_dir}/migrations" -name "*.lua" 2>/dev/null | wc -l)
    local dashboard_count=$(find "${project_dir}/dashboards" -name "*.json" 2>/dev/null | wc -l)

    echo "  Files:"
    echo "    API routes:    ${api_count}"
    echo "    Migrations:    ${migration_count}"
    echo "    Dashboards:    ${dashboard_count}"
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# MIGRATE: Run project migrations
# ──────────────────────────────────────────────────────────────────────────────
cmd_migrate() {
    local target="$1"

    if [[ "$target" == "--all" ]]; then
        echo -e "${GREEN}Running migrations for all projects...${NC}"
        docker exec -e "OPSAPI_PROJECTS_DIR=/app/projects" "$OPSAPI_CONTAINER" \
            lapis migrate 2>&1 | tail -20
    else
        local project_dir="${PROJECTS_DIR}/${target}"
        if [[ ! -f "${project_dir}/project.lua" ]]; then
            echo -e "${RED}Error: Project not found: ${target}${NC}"
            exit 1
        fi

        echo -e "${GREEN}Running migrations for project: ${target}${NC}"
        docker exec -e "OPSAPI_PROJECTS_DIR=/app/projects" "$OPSAPI_CONTAINER" \
            lapis migrate 2>&1 | grep -E "(ProjectMigrator|project_migration)" || true
        echo -e "${GREEN}Done${NC}"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STATUS: Show migration status
# ──────────────────────────────────────────────────────────────────────────────
cmd_status() {
    local code="$1"
    local project_dir="${PROJECTS_DIR}/${code}"

    if [[ ! -f "${project_dir}/project.lua" ]]; then
        echo -e "${RED}Error: Project not found: ${code}${NC}"
        exit 1
    fi

    local lua_code="${code//-/_}"

    echo -e "${CYAN}Migration status for: ${code}${NC}"
    echo ""

    # List migration files
    echo "  Migration files:"
    if [[ -d "${project_dir}/migrations" ]]; then
        for mig in "${project_dir}"/migrations/*.lua; do
            if [[ -f "$mig" ]]; then
                echo "    $(basename "$mig" .lua)"
            fi
        done
    else
        echo "    (none)"
    fi
    echo ""

    # Query executed migrations from database
    echo "  Executed migrations (from database):"
    docker exec "$OPSAPI_CONTAINER" lapis exec "
        local db = require('lapis.db')
        local rows = db.select('migration_name, executed_at FROM project_migrations WHERE project_code = ? ORDER BY migration_name', '${lua_code}')
        if #rows == 0 then
            print('    (none)')
        else
            for _, r in ipairs(rows) do
                print('    ' .. r.migration_name .. '  (' .. tostring(r.executed_at) .. ')')
            end
        end
    " 2>/dev/null || echo "    (unable to query database)"
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────────
main() {
    local command="${1:-help}"
    local arg="${2:-}"

    case "$command" in
        create)
            [[ -z "$arg" ]] && { echo -e "${RED}Error: Project code required${NC}"; print_usage; exit 1; }
            cmd_create "$arg"
            ;;
        list|ls)
            cmd_list
            ;;
        info)
            [[ -z "$arg" ]] && { echo -e "${RED}Error: Project code required${NC}"; exit 1; }
            cmd_info "$arg"
            ;;
        migrate|mig)
            [[ -z "$arg" ]] && { echo -e "${RED}Error: Project code or --all required${NC}"; exit 1; }
            cmd_migrate "$arg"
            ;;
        status|st)
            [[ -z "$arg" ]] && { echo -e "${RED}Error: Project code required${NC}"; exit 1; }
            cmd_status "$arg"
            ;;
        help|--help|-h)
            print_usage
            ;;
        *)
            echo -e "${RED}Unknown command: ${command}${NC}"
            print_usage
            exit 1
            ;;
    esac
}

main "$@"
