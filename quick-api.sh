#!/bin/bash

# Quick Lapis API Generator - Minimal prompts, maximum productivity

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Directories
MODELS_DIR="lapis/models"
QUERIES_DIR="lapis/queries"
ROUTES_DIR="lapis/routes"

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }

to_pascal_case() {
    echo "$1" | sed 's/[^a-zA-Z0-9]/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1' | sed 's/ //g'
}

to_snake_case() {
    echo "$1" | sed 's/[^a-zA-Z0-9]/_/g' | tr '[:upper:]' '[:lower:]' | sed 's/__*/_/g' | sed 's/^_\|_$//g'
}

pluralize() {
    local word="$1"
    if [[ "$word" =~ y$ ]]; then
        echo "${word%y}ies"
    elif [[ "$word" =~ [sxz]$ ]] || [[ "$word" =~ [cs]h$ ]]; then
        echo "${word}es"
    else
        echo "${word}s"
    fi
}

# Quick model generation
generate_model() {
    cat > "$MODELS_DIR/${model_name}Model.lua" << EOF
local Model = require("lapis.db.model").Model

local ${model_name}Model = Model:extend("$table_name", {
    timestamp = true
})

return ${model_name}Model
EOF
}

# Quick queries generation
generate_queries() {
    cat > "$QUERIES_DIR/${model_name}Queries.lua" << EOF
local ${model_name}Model = require "models.${model_name}Model"
local Global = require "helper.global"

local ${model_name}Queries = {}

function ${model_name}Queries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    return ${model_name}Model:create(params, { returning = "*" })
end

function ${model_name}Queries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'
    
    local paginated = ${model_name}Model:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function ${model_name}Queries.show(id)
    return ${model_name}Model:find({ uuid = id })
end

function ${model_name}Queries.update(id, params)
    local record = ${model_name}Model:find({ uuid = id })
    if not record then return nil end
    params.id = record.id
    return record:update(params, { returning = "*" })
end

function ${model_name}Queries.destroy(id)
    local record = ${model_name}Model:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

return ${model_name}Queries
EOF
}

# Quick routes generation
generate_routes() {
    cat > "$ROUTES_DIR/${route_name}.lua" << EOF
local respond_to = require("lapis.application").respond_to
local ${model_name}Queries = require "queries.${model_name}Queries"

return function(app)
    app:match("${route_name}", "/api/v2/${route_name}", respond_to({
        GET = function(self)
            return { json = ${model_name}Queries.all(self.params) }
        end,
        POST = function(self)
            return { json = ${model_name}Queries.create(self.params), status = 201 }
        end
    }))

    app:match("edit_${model_name_snake}", "/api/v2/${route_name}/:id", respond_to({
        before = function(self)
            self.${model_name_snake} = ${model_name}Queries.show(tostring(self.params.id))
            if not self.${model_name_snake} then
                self:write({ json = { error = "${model_name} not found!" }, status = 404 })
            end
        end,
        GET = function(self)
            return { json = self.${model_name_snake}, status = 200 }
        end,
        PUT = function(self)
            return { json = ${model_name}Queries.update(self.params.id, self.params), status = 204 }
        end,
        DELETE = function(self)
            return { json = ${model_name}Queries.destroy(self.params.id), status = 204 }
        end
    }))
end
EOF
}

# Function to add route to app.lua
add_route_to_app() {
    local app_file="lapis/app.lua"
    local route_require="require(\"routes.${route_name}\")(app)"
    
    if [[ ! -f "$app_file" ]]; then
        print_info "app.lua not found, skipping route addition"
        return
    fi
    
    # Check if route already exists
    if grep -q "routes\.${route_name}" "$app_file"; then
        print_info "Route already exists in app.lua"
        return
    fi
    
    # Find the last require line and add after it
    local last_require_line=$(grep -n "require(\"routes\." "$app_file" | tail -1 | cut -d: -f1)
    
    if [[ -n "$last_require_line" ]]; then
        sed -i "" "${last_require_line}a\\
$route_require" "$app_file"
        print_success "Added to app.lua"
    else
        print_info "Please add manually to app.lua: $route_require"
    fi
}

# Main execution
if [[ $# -eq 0 ]]; then
    echo "Usage: ./quick-api.sh ModelName"
    echo "Example: ./quick-api.sh Product"
    exit 1
fi

model_name=$(to_pascal_case "$1")
model_name_snake=$(to_snake_case "$1")
table_name=$(pluralize "$model_name_snake")
route_name="$table_name"

print_info "Generating API for: $model_name"
print_info "Table: $table_name | Routes: /api/v2/$route_name"

generate_model && print_success "Model created"
generate_queries && print_success "Queries created"  
generate_routes && print_success "Routes created"
add_route_to_app

echo
print_success "Done! Ready to use at /api/v2/${route_name}"