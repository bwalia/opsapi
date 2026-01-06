# Multi-Tenant Namespace Implementation Plan

## Executive Summary

This plan outlines the implementation of a multi-tenant namespace system that allows multiple companies to use the same product instance with complete data isolation. Each namespace operates as an independent environment with its own users, roles, permissions, stores, products, orders, chat, and all other modules.

---

## 1. Database Schema Design

### 1.1 Core Namespace Tables

```sql
-- Namespaces (Companies/Tenants)
CREATE TABLE namespaces (
    id SERIAL PRIMARY KEY,
    uuid VARCHAR(255) NOT NULL UNIQUE,
    name VARCHAR(255) NOT NULL,                    -- Company name
    slug VARCHAR(255) NOT NULL UNIQUE,             -- URL-friendly identifier (e.g., "acme-corp")
    domain VARCHAR(255),                           -- Custom domain (optional)
    logo_url VARCHAR(255),
    status VARCHAR(50) NOT NULL DEFAULT 'active',  -- active, suspended, inactive
    plan VARCHAR(50) DEFAULT 'free',               -- free, starter, professional, enterprise
    settings JSONB DEFAULT '{}',                   -- Namespace-specific settings
    max_users INTEGER DEFAULT 10,
    max_stores INTEGER DEFAULT 5,
    owner_user_id INTEGER,                         -- Super admin of this namespace
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    CONSTRAINT namespaces_status_valid CHECK (status IN ('active', 'suspended', 'inactive')),
    CONSTRAINT namespaces_slug_format CHECK (slug ~ '^[a-z0-9\-]+$')
);

-- User-Namespace Membership (Many-to-Many)
CREATE TABLE namespace_members (
    id SERIAL PRIMARY KEY,
    uuid VARCHAR(255) NOT NULL UNIQUE,
    namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status VARCHAR(50) NOT NULL DEFAULT 'active',  -- active, invited, suspended
    is_owner BOOLEAN DEFAULT false,                 -- Is this user the namespace owner
    joined_at TIMESTAMP,
    invited_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    UNIQUE(namespace_id, user_id)
);

-- Namespace-Specific Roles (Roles scoped to namespace)
CREATE TABLE namespace_roles (
    id SERIAL PRIMARY KEY,
    uuid VARCHAR(255) NOT NULL UNIQUE,
    namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
    role_name VARCHAR(255) NOT NULL,
    description TEXT,
    is_default BOOLEAN DEFAULT false,              -- Auto-assign to new members
    permissions JSONB DEFAULT '{}',                -- Module permissions
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    UNIQUE(namespace_id, role_name)
);

-- User Roles within a Namespace
CREATE TABLE namespace_user_roles (
    id SERIAL PRIMARY KEY,
    uuid VARCHAR(255) NOT NULL UNIQUE,
    namespace_member_id INTEGER NOT NULL REFERENCES namespace_members(id) ON DELETE CASCADE,
    namespace_role_id INTEGER NOT NULL REFERENCES namespace_roles(id) ON DELETE CASCADE,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    UNIQUE(namespace_member_id, namespace_role_id)
);

-- Namespace Invitations
CREATE TABLE namespace_invitations (
    id SERIAL PRIMARY KEY,
    uuid VARCHAR(255) NOT NULL UNIQUE,
    namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
    email VARCHAR(255) NOT NULL,
    role_id INTEGER REFERENCES namespace_roles(id) ON DELETE SET NULL,
    token VARCHAR(255) NOT NULL UNIQUE,
    status VARCHAR(50) NOT NULL DEFAULT 'pending', -- pending, accepted, expired, revoked
    invited_by INTEGER NOT NULL REFERENCES users(id),
    expires_at TIMESTAMP NOT NULL,
    accepted_at TIMESTAMP,
    created_at TIMESTAMP,
    updated_at TIMESTAMP
);
```

### 1.2 Modify Existing Tables to Include namespace_id

All tenant-specific tables will have a `namespace_id` foreign key:

```sql
-- Add namespace_id to existing tables
ALTER TABLE stores ADD COLUMN namespace_id INTEGER REFERENCES namespaces(id) ON DELETE CASCADE;
ALTER TABLE storeproducts ADD COLUMN namespace_id INTEGER REFERENCES namespaces(id) ON DELETE CASCADE;
ALTER TABLE orders ADD COLUMN namespace_id INTEGER REFERENCES namespaces(id) ON DELETE CASCADE;
ALTER TABLE customers ADD COLUMN namespace_id INTEGER REFERENCES namespaces(id) ON DELETE CASCADE;
ALTER TABLE categories ADD COLUMN namespace_id INTEGER REFERENCES namespaces(id) ON DELETE CASCADE;
ALTER TABLE chat_channels ADD COLUMN namespace_id INTEGER REFERENCES namespaces(id) ON DELETE CASCADE;
ALTER TABLE delivery_partners ADD COLUMN namespace_id INTEGER REFERENCES namespaces(id) ON DELETE CASCADE;
ALTER TABLE notifications ADD COLUMN namespace_id INTEGER REFERENCES namespaces(id) ON DELETE CASCADE;
-- ... (all other tenant-specific tables)

-- Create indexes for performance
CREATE INDEX idx_stores_namespace ON stores(namespace_id);
CREATE INDEX idx_orders_namespace ON orders(namespace_id);
CREATE INDEX idx_customers_namespace ON customers(namespace_id);
CREATE INDEX idx_chat_channels_namespace ON chat_channels(namespace_id);
-- ... (all other indexes)
```

### 1.3 Namespace Settings Schema

```json
{
  "branding": {
    "primaryColor": "#3B82F6",
    "logoUrl": "https://...",
    "faviconUrl": "https://..."
  },
  "features": {
    "chat": true,
    "deliveryPartners": true,
    "multiCurrency": false,
    "customDomain": false
  },
  "limits": {
    "maxProducts": 1000,
    "maxOrders": 10000,
    "storageGB": 10
  },
  "notifications": {
    "emailEnabled": true,
    "slackWebhook": null
  }
}
```

---

## 2. API Architecture

### 2.1 Namespace Context Resolution

Every request will resolve the namespace through one of these methods (in order):
1. **Subdomain**: `acme.opsapi.com` → namespace: "acme"
2. **Header**: `X-Namespace-Id: uuid` or `X-Namespace-Slug: acme`
3. **URL Path**: `/api/v2/ns/{namespace_slug}/...`
4. **JWT Token**: Namespace included in token payload

### 2.2 API Route Structure

```
# Namespace Management (Super Admin / Platform Level)
POST   /api/v2/namespaces                    # Create namespace
GET    /api/v2/namespaces                    # List namespaces (platform admin)
GET    /api/v2/namespaces/:id                # Get namespace details
PUT    /api/v2/namespaces/:id                # Update namespace
DELETE /api/v2/namespaces/:id                # Delete namespace

# Namespace Switching (User Level)
GET    /api/v2/user/namespaces               # List user's namespaces
POST   /api/v2/user/namespaces/:id/switch    # Switch active namespace
GET    /api/v2/user/current-namespace        # Get current namespace context

# Namespace Members (Namespace Admin)
GET    /api/v2/namespace/members             # List members
POST   /api/v2/namespace/members/invite      # Invite user
DELETE /api/v2/namespace/members/:id         # Remove member
PUT    /api/v2/namespace/members/:id/role    # Change member role

# Namespace Roles (Namespace Admin)
GET    /api/v2/namespace/roles               # List roles
POST   /api/v2/namespace/roles               # Create role
PUT    /api/v2/namespace/roles/:id           # Update role
DELETE /api/v2/namespace/roles/:id           # Delete role

# All existing routes work within namespace context
GET    /api/v2/stores                        # Returns stores for current namespace
GET    /api/v2/orders                        # Returns orders for current namespace
GET    /api/v2/chat/channels                 # Returns channels for current namespace
# ... all other existing routes
```

### 2.3 JWT Token Structure with Namespace

```json
{
  "userinfo": {
    "uuid": "user-uuid",
    "email": "user@example.com",
    "name": "John Doe"
  },
  "namespace": {
    "uuid": "namespace-uuid",
    "slug": "acme-corp",
    "role": "admin"
  },
  "exp": 1234567890
}
```

---

## 3. Backend Implementation (Lapis/Lua)

### 3.1 New Query Modules

```
lapis/queries/
├── NamespaceQueries.lua          # CRUD for namespaces
├── NamespaceMemberQueries.lua    # Member management
├── NamespaceRoleQueries.lua      # Namespace-specific roles
└── NamespaceInvitationQueries.lua # Invitation management
```

### 3.2 Middleware Enhancement

```lua
-- middleware/namespace.lua
local NamespaceMiddleware = {}

function NamespaceMiddleware.resolveNamespace(handler)
    return function(self)
        -- Priority 1: Header
        local ns_header = self.req.headers["x-namespace-id"] or
                          self.req.headers["x-namespace-slug"]

        -- Priority 2: JWT Token
        local ns_from_token = self.current_user and
                              self.current_user.namespace and
                              self.current_user.namespace.uuid

        -- Priority 3: Subdomain (parsed from Host header)
        local host = self.req.headers["host"]
        local ns_from_subdomain = host and host:match("^([^.]+)%.") or nil

        local namespace_id = ns_header or ns_from_token or ns_from_subdomain

        if not namespace_id then
            return { json = { error = "Namespace context required" }, status = 400 }
        end

        -- Validate namespace and user membership
        local namespace = NamespaceQueries.findByIdOrSlug(namespace_id)
        if not namespace then
            return { json = { error = "Namespace not found" }, status = 404 }
        end

        -- Check user has access to this namespace
        if self.current_user then
            local membership = NamespaceMemberQueries.findByUserAndNamespace(
                self.current_user.uuid, namespace.id
            )
            if not membership then
                return { json = { error = "Access denied to namespace" }, status = 403 }
            end
            self.namespace_membership = membership
            self.namespace_role = membership.role
        end

        self.namespace = namespace
        return handler(self)
    end
end

return NamespaceMiddleware
```

### 3.3 Route Files

```
lapis/routes/
├── namespaces.lua                # Namespace CRUD
├── namespace-members.lua         # Member management
├── namespace-roles.lua           # Role management
├── namespace-invitations.lua     # Invitation handling
└── namespace-switch.lua          # Namespace switching
```

---

## 4. Frontend Implementation (Next.js Dashboard)

### 4.1 Component Architecture

```
opsapi-dashboard/
├── components/
│   └── namespace/
│       ├── NamespaceSwitcher.tsx        # Dropdown to switch namespaces
│       ├── NamespaceSelector.tsx        # Full page namespace selector
│       ├── NamespaceSettingsPanel.tsx   # Namespace settings
│       ├── NamespaceMembersList.tsx     # Members management
│       ├── NamespaceRoleManager.tsx     # Role management
│       ├── NamespaceInviteModal.tsx     # Invite users
│       ├── CreateNamespaceModal.tsx     # Create new namespace
│       └── NamespaceBranding.tsx        # Branding customization
├── contexts/
│   └── NamespaceContext.tsx             # Namespace state & switching
├── hooks/
│   └── useNamespace.ts                  # Namespace hook
├── services/
│   └── namespace.service.ts             # Namespace API calls
├── store/
│   └── namespace.store.ts               # Zustand store for namespace
└── app/
    └── dashboard/
        └── namespace/
            ├── page.tsx                 # Namespace dashboard
            ├── settings/
            │   └── page.tsx             # Namespace settings
            ├── members/
            │   └── page.tsx             # Members management
            └── roles/
                └── page.tsx             # Roles management
```

### 4.2 Namespace Context Provider

```typescript
// contexts/NamespaceContext.tsx
interface NamespaceContextValue {
  currentNamespace: Namespace | null;
  userNamespaces: Namespace[];
  isLoading: boolean;
  switchNamespace: (namespaceId: string) => Promise<void>;
  hasNamespacePermission: (permission: string) => boolean;
  isNamespaceOwner: boolean;
  isNamespaceAdmin: boolean;
}
```

### 4.3 Namespace Switcher Component

The namespace switcher will appear in the header, allowing users to:
- See current namespace name and logo
- Quick-switch between their namespaces
- Create a new namespace (if permitted)
- Access namespace settings

### 4.4 Updated Dashboard Layout

```typescript
// DashboardLayout.tsx will wrap content with NamespaceProvider
<AuthProvider>
  <NamespaceProvider>
    <PermissionsProvider>
      <DashboardContent />
    </PermissionsProvider>
  </NamespaceProvider>
</AuthProvider>
```

---

## 5. Migration Strategy

### Phase 1: Database Migrations
1. Create namespace tables
2. Create default "system" namespace
3. Add namespace_id to all existing tables (nullable initially)
4. Migrate existing data to default namespace
5. Make namespace_id NOT NULL

### Phase 2: Backend Updates
1. Implement NamespaceQueries
2. Add namespace middleware
3. Update all existing queries to filter by namespace_id
4. Update JWT token generation with namespace
5. Create namespace API routes

### Phase 3: Frontend Updates
1. Create NamespaceContext
2. Add NamespaceSwitcher to header
3. Update API client to include namespace header
4. Add namespace management pages
5. Update all data fetching to use namespace context

### Phase 4: Testing & Rollout
1. Test namespace isolation
2. Test role-based access within namespaces
3. Test namespace switching
4. Performance testing with multiple namespaces
5. Security audit for data leakage

---

## 6. Security Considerations

### 6.1 Data Isolation
- Every database query MUST include namespace_id filter
- Row-Level Security (RLS) policies as additional protection
- API middleware validates namespace access on every request

### 6.2 Authentication Flow
1. User logs in (no namespace context yet)
2. Backend returns list of user's namespaces
3. User selects namespace (or auto-select if only one)
4. New token issued with namespace context
5. All subsequent requests use namespaced token

### 6.3 Cross-Namespace Access
- Prevented by design
- Users can only see data from their current namespace
- Namespace switching requires re-authentication context

---

## 7. Default Roles per Namespace

Each new namespace gets these default roles:

| Role | Description | Permissions |
|------|-------------|-------------|
| owner | Full control over namespace | All permissions |
| admin | Administrative access | All except delete namespace |
| manager | Manage daily operations | CRUD on most modules |
| member | Standard member access | Read most, write limited |
| viewer | Read-only access | Read only |

---

## 8. Files to Create/Modify

### New Files (Backend)
- `lapis/migrations/namespace-system.lua` - Database migrations
- `lapis/queries/NamespaceQueries.lua` - Namespace CRUD
- `lapis/queries/NamespaceMemberQueries.lua` - Member management
- `lapis/queries/NamespaceRoleQueries.lua` - Role management
- `lapis/queries/NamespaceInvitationQueries.lua` - Invitations
- `lapis/middleware/namespace.lua` - Namespace resolution
- `lapis/routes/namespaces.lua` - Namespace API
- `lapis/routes/namespace-members.lua` - Members API
- `lapis/routes/namespace-roles.lua` - Roles API
- `lapis/routes/namespace-switch.lua` - Switching API

### Modified Files (Backend)
- `lapis/migrations.lua` - Add namespace migrations
- `lapis/routes/auth.lua` - Include namespace in JWT
- `lapis/middleware/auth.lua` - Parse namespace from token
- All existing query files - Add namespace filtering

### New Files (Frontend)
- `opsapi-dashboard/contexts/NamespaceContext.tsx`
- `opsapi-dashboard/store/namespace.store.ts`
- `opsapi-dashboard/services/namespace.service.ts`
- `opsapi-dashboard/hooks/useNamespace.ts`
- `opsapi-dashboard/components/namespace/` (all components)
- `opsapi-dashboard/app/dashboard/namespace/` (all pages)
- `opsapi-dashboard/types/namespace.ts`

### Modified Files (Frontend)
- `opsapi-dashboard/components/layout/Header.tsx` - Add namespace switcher
- `opsapi-dashboard/components/layout/DashboardLayout.tsx` - Add NamespaceProvider
- `opsapi-dashboard/lib/api-client.ts` - Add namespace header
- `opsapi-dashboard/store/auth.store.ts` - Store active namespace
- All service files - Pass namespace context

---

## 9. Estimated Scope

| Component | Estimated Lines | Complexity |
|-----------|-----------------|------------|
| Database Migrations | ~400 | Medium |
| Backend Queries (4 files) | ~800 | Medium |
| Backend Middleware | ~150 | Medium |
| Backend Routes (5 files) | ~1200 | Medium |
| Modify Existing Queries | ~500 | Low |
| Frontend Context/Store | ~400 | Medium |
| Frontend Components (8) | ~1500 | Medium |
| Frontend Pages (4) | ~1000 | Medium |
| Frontend Service | ~200 | Low |
| Tests | ~800 | Medium |

**Total: ~7000 lines of new/modified code**

---

## 10. Questions for Clarification

1. **Platform Admin**: Should there be a "platform admin" role that can manage all namespaces (super admin across the entire system)?

2. **Billing Integration**: Will namespaces have different plans/billing? Should we integrate with Stripe for subscription management?

3. **Custom Domains**: Should each namespace be able to configure a custom domain (e.g., `dashboard.acme.com`)?

4. **Data Export**: Should users be able to export their namespace data?

5. **Namespace Deletion**: What happens when a namespace is deleted? Soft delete with data retention period?

---

## Approval Required

Please review this plan and confirm if you'd like me to proceed with implementation. I can start with:
- **Option A**: Database migrations first (safest, allows parallel development)
- **Option B**: Full backend implementation (namespace system + API routes)
- **Option C**: Full-stack implementation (backend + frontend together)

Which approach would you prefer?
