#!/bin/bash

# Lapis API Generator Script
# Generates Model, Queries, and Routes files automatically

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Directories
MODELS_DIR="lapis/models"
QUERIES_DIR="lapis/queries"
ROUTES_DIR="lapis/routes"

# Helper functions
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Function to convert string to PascalCase
to_pascal_case() {
    echo "$1" | sed 's/[^a-zA-Z0-9]/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1' | sed 's/ //g'
}

# Function to convert string to snake_case
to_snake_case() {
    echo "$1" | sed 's/[^a-zA-Z0-9]/_/g' | tr '[:upper:]' '[:lower:]' | sed 's/__*/_/g' | sed 's/^_\|_$//g'
}

# Function to pluralize table name
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

# Function to get relations
get_relations() {
    local relations=""
    
    print_info "Configure relations for your model:" >&2
    print_info "Available relation types: belongs_to, has_many, has_one" >&2
    print_info "Press Enter without input to finish adding relations" >&2
    
    while true; do
        echo >&2
        read -p "Relation name (or press Enter to finish): " rel_name
        [[ -z "$rel_name" ]] && break
        
        echo "Select relation type:" >&2
        echo "1) belongs_to" >&2
        echo "2) has_many" >&2
        echo "3) has_one" >&2
        read -p "Choice (1-3): " rel_type
        
        case $rel_type in
            1) rel_type_str="belongs_to" ;;
            2) rel_type_str="has_many" ;;
            3) rel_type_str="has_one" ;;
            *) print_error "Invalid choice. Skipping relation."; continue ;;
        esac
        
        read -p "Related model name (e.g., UserModel): " related_model
        
        if [[ "$rel_type_str" == "has_many" ]]; then
            read -p "Foreign key (default: ${model_name_snake}_id): " foreign_key
            [[ -z "$foreign_key" ]] && foreign_key="${model_name_snake}_id"
            relations+="\n        {\"$rel_name\", $rel_type_str = \"$related_model\", key = \"$foreign_key\"},"
        else
            relations+="\n        {\"$rel_name\", $rel_type_str = \"$related_model\"},"
        fi
        
        print_success "Added $rel_type_str relation: $rel_name -> $related_model" >&2
    done
    
    # Remove trailing comma
    relations=$(echo -e "$relations" | sed 's/,$//')
    echo "$relations"
}

# Function to generate model file
generate_model() {
    local model_file="$MODELS_DIR/${model_name}Model.lua"
    
    print_info "Generating model file: $model_file"
    
    # Get relations
    local relations=$(get_relations)
    
    # Generate model content
    if [[ -n "$relations" ]]; then
        cat > "$model_file" << EOF
local Model = require("lapis.db.model").Model

local ${model_name}Model = Model:extend("$table_name", {
    timestamp = true,
    relations = {$relations
    }
})

return ${model_name}Model
EOF
    else
        cat > "$model_file" << EOF
local Model = require("lapis.db.model").Model

local ${model_name}Model = Model:extend("$table_name", {
    timestamp = true
})

return ${model_name}Model
EOF
    fi
    
    print_success "Model file generated: $model_file"
}

# Function to generate queries file
generate_queries() {
    local queries_file="$QUERIES_DIR/${model_name}Queries.lua"
    
    print_info "Generating queries file: $queries_file"
    
    cat > "$queries_file" << EOF
local ${model_name}Model = require "models.${model_name}Model"
local Validation = require "helper.validations"
local Global = require "helper.global"

local ${model_name}Queries = {}

function ${model_name}Queries.create(params)
    -- Add validation here if needed
    -- Validation.create${model_name}(params)
    
    local data = params
    if not data.uuid then
        data.uuid = Global.generateUUID()
    end
    
    return ${model_name}Model:create(data, {
        returning = "*"
    })
end

function ${model_name}Queries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = ${model_name}Model:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    
    local records = paginated:get_page(page)
    
    -- Load relations if needed
    -- for i, record in ipairs(records) do
    --     record:get_relation_name()
    -- end
    
    return {
        data = records,
        total = paginated:total_items()
    }
end

function ${model_name}Queries.show(id)
    local record = ${model_name}Model:find({
        uuid = id
    })
    
    -- Load relations if needed
    -- if record then
    --     record:get_relation_name()
    -- end
    
    return record
end

function ${model_name}Queries.update(id, params)
    local record = ${model_name}Model:find({
        uuid = id
    })
    
    if not record then
        return nil
    end
    
    params.id = record.id
    return record:update(params, {
        returning = "*"
    })
end

function ${model_name}Queries.destroy(id)
    local record = ${model_name}Model:find({
        uuid = id
    })
    
    if not record then
        return nil
    end
    
    return record:delete()
end

return ${model_name}Queries
EOF
    
    print_success "Queries file generated: $queries_file"
}

# Function to generate routes file
generate_routes() {
    local routes_file="$ROUTES_DIR/${route_name}.lua"
    
    print_info "Generating routes file: $routes_file"
    
    cat > "$routes_file" << EOF
local respond_to = require("lapis.application").respond_to
local ${model_name}Queries = require "queries.${model_name}Queries"

return function(app)
    app:match("${route_name}", "/api/v2/${route_name}", respond_to({
        GET = function(self)
            self.params.timestamp = true
            local records = ${model_name}Queries.all(self.params)
            return {
                json = records
            }
        end,
        POST = function(self)
            local record = ${model_name}Queries.create(self.params)
            return {
                json = record,
                status = 201
            }
        end
    }))

    app:match("edit_${model_name_snake}", "/api/v2/${route_name}/:id", respond_to({
        before = function(self)
            self.${model_name_snake} = ${model_name}Queries.show(tostring(self.params.id))
            if not self.${model_name_snake} then
                self:write({
                    json = {
                        lapis = {
                            version = require("lapis.version")
                        },
                        error = "${model_name} not found! Please check the UUID and try again."
                    },
                    status = 404
                })
            end
        end,
        GET = function(self)
            local record = ${model_name}Queries.show(tostring(self.params.id))
            return {
                json = record,
                status = 200
            }
        end,
        PUT = function(self)
            local record = ${model_name}Queries.update(tostring(self.params.id), self.params)
            return {
                json = record,
                status = 204
            }
        end,
        DELETE = function(self)
            local record = ${model_name}Queries.destroy(tostring(self.params.id))
            return {
                json = record,
                status = 204
            }
        end
    }))
end
EOF
    
    print_success "Routes file generated: $routes_file"
}

# Function to add route to app.lua
add_route_to_app() {
    local app_file="lapis/app.lua"
    local route_require="require(\"routes.${route_name}\")(app)"
    
    if [[ ! -f "$app_file" ]]; then
        print_warning "app.lua not found, skipping route addition"
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
        print_success "Added route to app.lua: $route_require"
    else
        print_warning "Could not find existing routes in app.lua, please add manually"
    fi
}

# Main function
main() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════╗"
    echo "║        Lapis API Generator           ║"
    echo "║   Model • Queries • Routes           ║"
    echo "╚══════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Check if we're in the right directory
    if [[ ! -d "$MODELS_DIR" ]] || [[ ! -d "$QUERIES_DIR" ]] || [[ ! -d "$ROUTES_DIR" ]]; then
        print_error "Please run this script from the project root directory"
        print_info "Expected directories: $MODELS_DIR, $QUERIES_DIR, $ROUTES_DIR"
        exit 1
    fi
    
    # Get model name
    read -p "Enter model name (e.g., User, Product, Category): " input_name
    
    if [[ -z "$input_name" ]]; then
        print_error "Model name cannot be empty"
        exit 1
    fi
    
    # Convert names
    model_name=$(to_pascal_case "$input_name")
    model_name_snake=$(to_snake_case "$input_name")
    table_name=$(pluralize "$model_name_snake")
    route_name="$table_name"
    
    print_info "Model Name: $model_name"
    print_info "Table Name: $table_name"
    print_info "Route Name: $route_name"
    
    # Confirm generation
    echo
    read -p "Generate files for $model_name? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "Generation cancelled"
        exit 0
    fi
    
    # Check if files already exist
    local model_file="$MODELS_DIR/${model_name}Model.lua"
    local queries_file="$QUERIES_DIR/${model_name}Queries.lua"
    local routes_file="$ROUTES_DIR/${route_name}.lua"
    
    if [[ -f "$model_file" ]] || [[ -f "$queries_file" ]] || [[ -f "$routes_file" ]]; then
        print_warning "Some files already exist:"
        [[ -f "$model_file" ]] && echo "  - $model_file"
        [[ -f "$queries_file" ]] && echo "  - $queries_file"
        [[ -f "$routes_file" ]] && echo "  - $routes_file"
        
        read -p "Overwrite existing files? (y/N): " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            print_warning "Generation cancelled"
            exit 0
        fi
    fi
    
    echo
    print_info "Generating API files..."
    
    # Generate files
    generate_model
    generate_queries
    generate_routes
    
    # Add route to app.lua
    add_route_to_app
    
    echo
    print_success "API files generated successfully!"
    print_info "Next steps:"
    echo "  1. Create database migration for '$table_name' table"
    echo "  2. Add validation functions in helper/validations.lua if needed"
    echo "  3. Update relations in generated files as needed"
}

# Run main function
main "$@"