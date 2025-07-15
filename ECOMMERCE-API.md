# Multi-Tenant Ecommerce API

Complete API documentation for the multi-tenant ecommerce system with user registration, authentication, and role-based access control.

## 🔐 Authentication

All protected endpoints require JWT token in Authorization header:
```
Authorization: Bearer <jwt_token>
```

## 🏪 Core Entities

### Store
- **Owner**: User who creates and manages the store
- **Multi-tenant**: Each user can have multiple stores
- **Products**: Each store has its own products and categories

### StoreProduct
- **Store-specific**: Products belong to a specific store
- **Categories**: Products can be categorized within each store
- **Inventory**: Track stock levels per product

### Order & OrderItem
- **Store-specific**: Orders belong to a specific store
- **Customer**: Orders can be linked to customers
- **Items**: Each order contains multiple items

## 👥 User Management

### Register User
```http
POST /api/v2/register
Content-Type: application/json

{
  "username": "john_seller",
  "email": "john@example.com",
  "password": "securepass123",
  "first_name": "John",
  "last_name": "Doe",
  "role": "seller"  // "seller" or "buyer"
}
```

### Login
```http
POST /auth/login
Content-Type: application/json

{
  "username": "john@example.com",
  "password": "securepass123"
}
```

**Response:**
```json
{
  "user": {
    "id": "uuid",
    "email": "john@example.com",
    "name": "John Doe"
  },
  "token": "jwt_token_here"
}
```

## 🚀 API Endpoints

### Store Management

#### Create Store (Seller Only)
```http
POST /api/v2/stores
Authorization: Bearer <jwt_token>
Content-Type: application/json

{
  "name": "My Awesome Store",
  "description": "Best products in town",
  "slug": "my-awesome-store"
}
```
**Note:** Requires seller role. user_id is automatically set from JWT token.

#### Get User's Stores
```http
GET /api/v2/users/{user_id}/stores?page=1&perPage=10
```

#### Get Store Details
```http
GET /api/v2/stores/{store_uuid}
```

#### Update Store
```http
PUT /api/v2/stores/{store_uuid}
Content-Type: application/json

{
  "user_id": 1,
  "name": "Updated Store Name",
  "description": "Updated description"
}
```

### Product Management

#### Get Store Products
```http
GET /api/v2/stores/{store_id}/products?page=1&perPage=20
```

#### Add Product to Store (Seller Only)
```http
POST /api/v2/stores/{store_id}/products
Authorization: Bearer <jwt_token>
Content-Type: application/json

{
  "name": "Amazing Product",
  "description": "Product description",
  "price": 29.99,
  "sku": "PROD-001",
  "category_id": 1,
  "inventory_quantity": 100,
  "track_inventory": true
}
```
**Note:** Requires seller role and store ownership.

#### Get All Products (Admin)
```http
GET /api/v2/storeproducts?page=1&perPage=20
```

#### Update Product
```http
PUT /api/v2/storeproducts/{product_uuid}
Content-Type: application/json

{
  "name": "Updated Product Name",
  "price": 39.99,
  "inventory_quantity": 150
}
```

### Category Management

#### Get Store Categories
```http
GET /api/v2/categories?store_id={store_id}
```

#### Create Category
```http
POST /api/v2/categories
Content-Type: application/json

{
  "store_id": 1,
  "name": "Electronics",
  "description": "Electronic products",
  "slug": "electronics"
}
```

### Customer Management

#### Create Customer
```http
POST /api/v2/customers
Content-Type: application/json

{
  "email": "customer@example.com",
  "first_name": "John",
  "last_name": "Doe",
  "phone": "+1234567890"
}
```

#### Get Customers
```http
GET /api/v2/customers?page=1&perPage=20
```

### Order Management

#### Create Order (Authenticated)
```http
POST /api/v2/orders
Authorization: Bearer <jwt_token>
Content-Type: application/json

{
  "store_id": 1,
  "customer_id": 1,
  "subtotal": 59.98,
  "tax_amount": 4.80,
  "total_amount": 64.78,
  "billing_address": {
    "name": "John Doe",
    "address1": "123 Main St",
    "city": "New York",
    "zip": "10001"
  }
}
```
**Note:** order_number, status, and timestamps are auto-generated.

#### Get Store Orders
```http
GET /api/v2/orders?store_id={store_id}&page=1&perPage=20
```

#### Add Order Items
```http
POST /api/v2/orderitems
Content-Type: application/json

{
  "order_id": 1,
  "product_id": 1,
  "quantity": 2,
  "price": 29.99,
  "total": 59.98
}
```

## 🔐 Multi-Tenant Security

### Store Ownership Verification
- Store operations require `user_id` parameter
- Only store owners can modify their stores
- Access denied (403) for unauthorized operations

### Example with Ownership Check
```http
PUT /api/v2/stores/{store_uuid}
Content-Type: application/json

{
  "user_id": 1,  // Required for ownership verification
  "name": "Updated Store Name"
}
```

## 📊 Database Schema

### Key Relationships
```sql
users (1) -> (many) stores
stores (1) -> (many) storeproducts
stores (1) -> (many) categories
stores (1) -> (many) orders
categories (1) -> (many) storeproducts
orders (1) -> (many) orderitems
customers (1) -> (many) orders
storeproducts (1) -> (many) orderitems
```

### Sample Data Structure

#### Store
```json
{
  "id": 1,
  "uuid": "550e8400-e29b-41d4-a716-446655440000",
  "user_id": 1,
  "name": "Tech Store",
  "description": "Latest technology products",
  "slug": "tech-store",
  "status": "active",
  "created_at": "2024-01-01T00:00:00Z"
}
```

#### StoreProduct
```json
{
  "id": 1,
  "uuid": "550e8400-e29b-41d4-a716-446655440001",
  "store_id": 1,
  "category_id": 1,
  "name": "Smartphone",
  "description": "Latest smartphone",
  "price": 699.99,
  "sku": "PHONE-001",
  "inventory_quantity": 50,
  "is_active": true
}
```

#### Order
```json
{
  "id": 1,
  "uuid": "550e8400-e29b-41d4-a716-446655440002",
  "store_id": 1,
  "customer_id": 1,
  "order_number": "ORD-001",
  "status": "completed",
  "total_amount": 759.98,
  "created_at": "2024-01-01T00:00:00Z"
}
```

## 🛠 Implementation Status

### ✅ Completed
- [x] User registration with seller/buyer roles
- [x] JWT authentication & middleware
- [x] Role-based access control
- [x] Store model with relations
- [x] StoreProduct model with relations  
- [x] Category model with relations
- [x] Order & OrderItem models with relations
- [x] Customer model
- [x] Multi-tenant store routes
- [x] Store ownership verification
- [x] Inventory management
- [x] Order processing logic
- [x] Database migrations
- [x] API documentation

### 🔄 Next Steps
1. **File upload** - Product images, store logos
2. **Payment integration** - Stripe, PayPal
3. **Order fulfillment** - Shipping, tracking
4. **Product variations** - Size, color, etc.
5. **Shopping cart** - Session-based cart
6. **Analytics** - Sales reports, dashboard
7. **Email notifications** - Order confirmations, updates
8. **Search & filters** - Product search functionality

## 🚀 Quick Start

1. **Run migrations**:
```bash
# Add to your migrations.lua file
require("ecommerce-migrations")
```

2. **Test the API**:
```bash
# Create a store
curl -X POST http://localhost:8080/api/v2/stores \
  -H "Content-Type: application/json" \
  -d '{"user_id": 1, "name": "My Store", "description": "Test store"}'

# Get user's stores  
curl http://localhost:8080/api/v2/users/1/stores
```

3. **Register and login**:
```bash
# Register as seller
curl -X POST http://localhost:8080/api/v2/register \
  -H "Content-Type: application/json" \
  -d '{"username": "seller1", "email": "seller@test.com", "password": "password123", "role": "seller", "first_name": "John", "last_name": "Doe"}'

# Login to get token
curl -X POST http://localhost:8080/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username": "seller@test.com", "password": "password123"}'
```

4. **Add products**:
```bash
# Add product to store (with JWT token)
curl -X POST http://localhost:8080/api/v2/stores/1/products \
  -H "Authorization: Bearer <jwt_token>" \
  -H "Content-Type: application/json" \
  -d '{"name": "Test Product", "price": 19.99, "sku": "TEST-001", "inventory_quantity": 50}'
```

The multi-tenant ecommerce API is now ready for use! 🎉