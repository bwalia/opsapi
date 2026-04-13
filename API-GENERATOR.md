# Lapis API Generator

Automated scripts to generate Lapis API files (Models, Queries, Routes) with CRUD operations.

## Scripts Available

### 1. `generate-api.sh` - Full Featured Generator
Interactive script with relation configuration and detailed prompts.

**Usage:**
```bash
./generate-api.sh
```

**Features:**
- Interactive prompts for model configuration
- Relation setup (belongs_to, has_many, has_one)
- Foreign key configuration
- File existence checking
- Detailed validation and error handling
- **Automatic route registration** in app.lua

### 2. `quick-api.sh` - Quick Generator
Fast generation with minimal prompts for rapid development.

**Usage:**
```bash
./quick-api.sh ModelName
```

**Examples:**
```bash
./quick-api.sh Product      # Creates files + adds to app.lua automatically
./quick-api.sh BlogPost     # Creates files + adds to app.lua automatically  
./quick-api.sh UserProfile  # Creates files + adds to app.lua automatically
```

**Features:**
- **Zero configuration** - one command does everything
- **Automatic route registration** in app.lua
- **Instant ready** - API endpoints work immediately

## Generated Files Structure

For a model named `Product`, the scripts generate:

### Model File: `lapis/models/ProductModel.lua`
```lua
local Model = require("lapis.db.model").Model

local ProductModel = Model:extend("products", {
    timestamp = true
})

return ProductModel
```

### Queries File: `lapis/queries/ProductQueries.lua`
```lua
local ProductModel = require "models.ProductModel"
local Global = require "helper.global"

local ProductQueries = {}

function ProductQueries.create(params)
    -- CRUD operations with UUID generation
end

function ProductQueries.all(params)
    -- Paginated listing with sorting
end

function ProductQueries.show(id)
    -- Find by UUID
end

function ProductQueries.update(id, params)
    -- Update by UUID
end

function ProductQueries.destroy(id)
    -- Delete by UUID
end

return ProductQueries
```

### Routes File: `lapis/routes/products.lua`
```lua
local respond_to = require("lapis.application").respond_to
local ProductQueries = require "queries.ProductQueries"

return function(app)
    -- GET/POST /api/v2/products
    -- GET/PUT/DELETE /api/v2/products/:id
end
```

## Generated API Endpoints

For a `Product` model, you get:

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v2/products` | List all products (paginated) |
| POST | `/api/v2/products` | Create new product |
| GET | `/api/v2/products/:id` | Get product by UUID |
| PUT | `/api/v2/products/:id` | Update product by UUID |
| DELETE | `/api/v2/products/:id` | Delete product by UUID |

## Query Parameters

### Pagination & Sorting
- `page` - Page number (default: 1)
- `perPage` - Items per page (default: 10)
- `orderBy` - Field to sort by (default: 'id')
- `orderDir` - Sort direction: 'asc' or 'desc' (default: 'desc')

**Example:**
```
GET /api/v2/products?page=2&perPage=20&orderBy=name&orderDir=asc
```

## After Generation

✅ **Route automatically added to app.lua** - No manual step needed!

**Next steps:**

1. **Create database migration:**
```lua
-- migrations.lua
create_table("products", {
    {"id", "serial"},
    {"uuid", "varchar(36) NOT NULL UNIQUE"},
    {"name", "varchar(255)"},
    {"description", "text"},
    {"price", "decimal(10,2)"},
    {"created_at", "timestamp"},
    {"updated_at", "timestamp"},
    "PRIMARY KEY (id)"
})
```

2. **Add validation (optional):**
```lua
-- helper/validations.lua
function Validation.createProduct(params)
    -- Add your validation logic
end
```

## Naming Conventions

| Input | Model | Table | Route |
|-------|-------|-------|-------|
| Product | ProductModel | products | products |
| BlogPost | BlogPostModel | blog_posts | blog_posts |
| UserProfile | UserProfileModel | user_profiles | user_profiles |

## Relations Support (generate-api.sh only)

The full generator supports adding relations:

### belongs_to
```lua
relations = {
    {"user", belongs_to = "UserModel"}
}
```

### has_many
```lua
relations = {
    {"orders", has_many = "OrderModel", key = "product_id"}
}
```

### has_one
```lua
relations = {
    {"profile", has_one = "ProfileModel"}
}
```

## Automatic Route Registration

Both scripts now automatically:
- ✅ **Add route to app.lua** - `require("routes.your_model")(app)`
- ✅ **Check for duplicates** - won't add if already exists
- ✅ **Smart insertion** - adds after existing routes
- ✅ **Ready to use** - API works immediately

**Example app.lua after generation:**
```lua
require("routes.users")(app)
require("routes.products")(app)  -- ← Automatically added
return app
```

## Tips

- Use `quick-api.sh` for rapid prototyping - **zero setup needed**
- Use `generate-api.sh` when you need relations configured
- **No manual route registration** - scripts handle everything
- Create database migrations after generating files
- Add validation functions in `helper/validations.lua`

## Troubleshooting

**Script not executable:**
```bash
chmod +x generate-api.sh quick-api.sh
```

**Wrong directory:**
Make sure you're in the project root with `lapis/` folder present.

**File conflicts:**
The full generator will prompt before overwriting existing files.

**Route already exists:**
Scripts detect existing routes and skip duplicate additions.