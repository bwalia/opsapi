--[[
    Namespace Routes

    API endpoints for namespace (tenant) management:
    - Platform-level namespace CRUD (super admin)
    - User's namespaces listing
    - Namespace switching
    - Namespace member management
    - Namespace role management
]]

local respond_to = require("lapis.application").respond_to
local NamespaceQueries = require("queries.NamespaceQueries")
local NamespaceMemberQueries = require("queries.NamespaceMemberQueries")
local NamespaceRoleQueries = require("queries.NamespaceRoleQueries")
local NamespaceInvitationQueries = require("queries.NamespaceInvitationQueries")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local RequestParser = require("helper.request_parser")
local Global = require("helper.global")
local db = require("lapis.db")
local cjson = require("cjson")

-- Configure cjson
cjson.encode_empty_table_as_object(false)

return function(app)

    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Namespace API error: ", message, " | Details: ", tostring(details))
        return {
            status = status,
            json = {
                error = message,
                details = type(details) == "string" and details or nil
            }
        }
    end

    local function success_response(data, status)
        return {
            status = status or 200,
            json = data
        }
    end

    -- ============================================================
    -- USER NAMESPACE ROUTES (Available to all authenticated users)
    -- ============================================================

    -- Get current user's namespaces (USER-FIRST: User is global, namespaces are assigned)
    app:get("/api/v2/user/namespaces", AuthMiddleware.requireAuth(function(self)
        local user = db.select("id FROM users WHERE uuid = ?", self.current_user.uuid)
        if not user or #user == 0 then
            return error_response(404, "User not found")
        end

        local namespaces = NamespaceQueries.getForUser(self.current_user.uuid)

        -- Parse roles JSON for each namespace
        for _, ns in ipairs(namespaces or {}) do
            if ns.roles and type(ns.roles) == "string" then
                local ok, parsed = pcall(cjson.decode, ns.roles)
                if ok then
                    ns.roles = parsed
                end
            end
            -- Parse settings
            if ns.settings and type(ns.settings) == "string" then
                local ok, parsed = pcall(cjson.decode, ns.settings)
                if ok then
                    ns.settings = parsed
                end
            end
        end

        -- Get user's namespace settings
        local settings = NamespaceQueries.getUserSettings(user[1].id)

        return success_response({
            data = namespaces or {},
            total = #(namespaces or {}),
            settings = settings and {
                default_namespace_id = settings.default_namespace_id,
                default_namespace_uuid = settings.default_namespace_uuid,
                default_namespace_slug = settings.default_namespace_slug,
                last_active_namespace_id = settings.last_active_namespace_id,
                last_active_namespace_uuid = settings.last_active_namespace_uuid,
                last_active_namespace_slug = settings.last_active_namespace_slug
            } or nil
        })
    end))

    -- Get details of a specific namespace (if user is member)
    app:get("/api/v2/user/namespaces/:id", AuthMiddleware.requireAuth(function(self)
        local namespace_id = self.params.id

        -- Check user is member
        if not NamespaceQueries.isUserMember(self.current_user.uuid, namespace_id) then
            return error_response(403, "You don't have access to this namespace")
        end

        local namespace = NamespaceQueries.show(namespace_id)
        if not namespace then
            return error_response(404, "Namespace not found")
        end

        -- Get user's membership details
        local membership = NamespaceMemberQueries.findByUserAndNamespace(self.current_user.uuid, namespace_id)
        local member_details = membership and NamespaceMemberQueries.getWithDetails(membership.id)

        -- Parse settings
        if namespace.settings and type(namespace.settings) == "string" then
            local ok, parsed = pcall(cjson.decode, namespace.settings)
            if ok then
                namespace.settings = parsed
            end
        end

        return success_response({
            namespace = namespace,
            membership = member_details
        })
    end))

    -- Switch active namespace (generates new token with namespace context)
    -- USER-FIRST: Updates user's last active namespace setting
    app:post("/api/v2/user/namespaces/:id/switch", AuthMiddleware.requireAuth(function(self)
        local namespace_id = self.params.id

        -- Check user is member
        if not NamespaceQueries.isUserMember(self.current_user.uuid, namespace_id) then
            return error_response(403, "You don't have access to this namespace")
        end

        local namespace = NamespaceQueries.show(namespace_id)
        if not namespace then
            return error_response(404, "Namespace not found")
        end

        if namespace.status ~= "active" then
            return error_response(403, "Namespace is not active")
        end

        -- Get user id
        local user = db.select("id FROM users WHERE uuid = ?", self.current_user.uuid)
        if not user or #user == 0 then
            return error_response(404, "User not found")
        end

        -- Update user's last active namespace
        NamespaceQueries.updateLastActiveNamespace(user[1].id, namespace.id)

        -- Get membership and roles
        local membership = NamespaceMemberQueries.findByUserAndNamespace(self.current_user.uuid, namespace_id)
        local member_details = membership and NamespaceMemberQueries.getWithDetails(membership.id)
        local permissions = membership and NamespaceMemberQueries.getPermissions(membership.id)

        -- Generate new JWT with namespace context
        local jwt = require("resty.jwt")
        local JWT_SECRET_KEY = Global.getEnvVar("JWT_SECRET_KEY")

        -- Get primary role
        local primary_role = nil
        if member_details and member_details.roles then
            local roles = member_details.roles
            if type(roles) == "string" then
                local ok, parsed = pcall(cjson.decode, roles)
                if ok then roles = parsed end
            end
            if type(roles) == "table" and #roles > 0 then
                primary_role = roles[1].role_name
            end
        end

        local payload = {
            userinfo = {
                uuid = self.current_user.uuid,
                email = self.current_user.email,
                name = self.current_user.name
            },
            namespace = {
                uuid = namespace.uuid,
                slug = namespace.slug,
                name = namespace.name,
                role = primary_role,
                is_owner = membership.is_owner
            },
            exp = os.time() + 86400 -- 24 hours
        }

        local token = jwt:sign(JWT_SECRET_KEY, {
            header = { typ = "JWT", alg = "HS256" },
            payload = payload
        })

        return success_response({
            message = "Switched to namespace: " .. namespace.name,
            token = token,
            namespace = {
                uuid = namespace.uuid,
                slug = namespace.slug,
                name = namespace.name,
                logo_url = namespace.logo_url
            },
            membership = {
                is_owner = membership.is_owner,
                roles = member_details and member_details.roles,
                permissions = permissions
            }
        })
    end))

    -- Create a new namespace (any authenticated user can create)
    -- USER-FIRST: Creates namespace with user as owner, sets up default roles
    app:post("/api/v2/user/namespaces", AuthMiddleware.requireAuth(function(self)
        local params = RequestParser.parse_request(self)

        if not params.name or params.name == "" then
            return error_response(400, "Namespace name is required")
        end

        -- Check if slug is provided and available
        if params.slug then
            if not NamespaceQueries.isSlugAvailable(params.slug) then
                return error_response(400, "Slug is already taken")
            end
        end

        -- Get user id
        local user = db.select("id FROM users WHERE uuid = ?", self.current_user.uuid)
        if not user or #user == 0 then
            return error_response(404, "User not found")
        end

        -- Use the createWithOwner function which handles everything
        local result, err = NamespaceQueries.createWithOwner(user[1].id, {
            name = params.name,
            slug = params.slug,
            description = params.description,
            logo_url = params.logo_url,
            plan = "free"
        })

        if not result then
            return error_response(500, "Failed to create namespace", err)
        end

        -- Generate JWT with namespace context
        local jwt = require("resty.jwt")
        local JWT_SECRET_KEY = Global.getEnvVar("JWT_SECRET_KEY")

        local payload = {
            userinfo = {
                uuid = self.current_user.uuid,
                email = self.current_user.email,
                name = self.current_user.name
            },
            namespace = {
                uuid = result.namespace.uuid,
                slug = result.namespace.slug,
                name = result.namespace.name,
                role = "owner",
                is_owner = true
            },
            exp = os.time() + 86400
        }

        local token = jwt:sign(JWT_SECRET_KEY, {
            header = { typ = "JWT", alg = "HS256" },
            payload = payload
        })

        return success_response({
            message = "Namespace created successfully",
            namespace = result.namespace,
            membership = result.membership,
            token = token
        }, 201)
    end))

    -- Get user's namespace settings
    app:get("/api/v2/user/namespace-settings", AuthMiddleware.requireAuth(function(self)
        local user = db.select("id FROM users WHERE uuid = ?", self.current_user.uuid)
        if not user or #user == 0 then
            return error_response(404, "User not found")
        end

        local settings = NamespaceQueries.getUserSettings(user[1].id)
        local default_namespace = NamespaceQueries.getUserDefaultNamespace(user[1].id)

        return success_response({
            settings = settings,
            default_namespace = default_namespace
        })
    end))

    -- Update user's namespace settings (default namespace)
    app:match("user_namespace_settings", "/api/v2/user/namespace-settings", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            local params = RequestParser.parse_request(self)
            local user = db.select("id FROM users WHERE uuid = ?", self.current_user.uuid)
            if not user or #user == 0 then
                return error_response(404, "User not found")
            end

            -- Validate namespace exists and user is a member
            if params.default_namespace_id then
                local namespace = NamespaceQueries.show(params.default_namespace_id)
                if not namespace then
                    return error_response(404, "Namespace not found")
                end
                if not NamespaceQueries.isUserMember(self.current_user.uuid, namespace.id) then
                    return error_response(403, "You are not a member of this namespace")
                end
                params.default_namespace_id = namespace.id
            end

            local settings = NamespaceQueries.setUserSettings(user[1].id, {
                default_namespace_id = params.default_namespace_id
            })

            return success_response({
                message = "Settings updated successfully",
                settings = settings
            })
        end)
    }))

    -- Get pending invitations for current user
    app:get("/api/v2/user/invitations", AuthMiddleware.requireAuth(function(self)
        local user = db.select("id, email FROM users WHERE uuid = ?", self.current_user.uuid)
        if not user or #user == 0 then
            return error_response(404, "User not found")
        end

        local invitations = NamespaceInvitationQueries.getPendingForEmail(user[1].email)

        -- Structure the response
        local structured_invitations = {}
        for _, inv in ipairs(invitations or {}) do
            table.insert(structured_invitations, {
                id = inv.id,
                uuid = inv.uuid,
                token = inv.token,
                email = inv.email,
                status = inv.status,
                message = inv.message,
                expires_at = inv.expires_at,
                created_at = inv.created_at,
                namespace = {
                    uuid = inv.namespace_uuid,
                    name = inv.namespace_name,
                    slug = inv.namespace_slug,
                    logo_url = inv.namespace_logo
                },
                role = inv.role_id and {
                    id = inv.role_id,
                    role_name = inv.role_name,
                    display_name = inv.role_display_name
                } or nil,
                inviter = {
                    name = inv.invited_by_name
                }
            })
        end

        return success_response({
            data = structured_invitations,
            total = #structured_invitations
        })
    end))

    -- ============================================================
    -- NAMESPACE CONTEXT ROUTES (Requires active namespace)
    -- ============================================================

    -- Get current namespace details
    app:get("/api/v2/namespace", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local namespace = self.namespace

            -- Parse settings
            if namespace.settings and type(namespace.settings) == "string" then
                local ok, parsed = pcall(cjson.decode, namespace.settings)
                if ok then
                    namespace.settings = parsed
                end
            end

            -- Get stats if user has permission
            local stats = nil
            if NamespaceMiddleware.hasPermission(self, "dashboard", "read") then
                stats = NamespaceQueries.getStats(namespace.id)
            end

            return success_response({
                namespace = namespace,
                membership = {
                    is_owner = self.is_namespace_owner,
                    roles = self.namespace_roles,
                    permissions = self.namespace_permissions
                },
                stats = stats
            })
        end)
    ))

    -- Update current namespace
    app:match("update_namespace", "/api/v2/namespace", respond_to({
        PUT = AuthMiddleware.requireAuth(
            NamespaceMiddleware.requirePermission("namespace", "update", function(self)
                local params = RequestParser.parse_request(self)

                -- Validate slug if changing
                if params.slug and params.slug ~= self.namespace.slug then
                    if not NamespaceQueries.isSlugAvailable(params.slug, self.namespace.id) then
                        return error_response(400, "Slug is already taken")
                    end
                end

                -- Validate domain if changing
                if params.domain and params.domain ~= self.namespace.domain then
                    if not NamespaceQueries.isDomainAvailable(params.domain, self.namespace.id) then
                        return error_response(400, "Domain is already in use")
                    end
                end

                -- Only owners can change certain fields
                if not self.is_namespace_owner then
                    params.slug = nil
                    params.domain = nil
                    params.plan = nil
                    params.max_users = nil
                    params.max_stores = nil
                end

                -- Encode settings if provided as table
                if type(params.settings) == "table" then
                    params.settings = cjson.encode(params.settings)
                end

                local ok, namespace = pcall(NamespaceQueries.update, self.namespace.id, params)

                if not ok then
                    return error_response(500, "Failed to update namespace", namespace)
                end

                return success_response({
                    message = "Namespace updated successfully",
                    namespace = namespace
                })
            end)
        )
    }))

    -- ============================================================
    -- NAMESPACE MEMBERS ROUTES
    -- ============================================================

    -- List namespace members
    app:get("/api/v2/namespace/members", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("users", "read", function(self)
            local result = NamespaceMemberQueries.all(self.namespace.id, {
                page = self.params.page,
                perPage = self.params.per_page or self.params.limit,
                status = self.params.status,
                search = self.params.search,
                role_id = self.params.role_id
            })

            return success_response(result)
        end)
    ))

    -- Get single member
    app:get("/api/v2/namespace/members/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("users", "read", function(self)
            local member = NamespaceMemberQueries.getWithDetails(self.params.id)

            if not member then
                return error_response(404, "Member not found")
            end

            -- Verify member belongs to this namespace
            if member.namespace_id ~= self.namespace.id then
                return error_response(404, "Member not found in this namespace")
            end

            return success_response(member)
        end)
    ))

    -- Add member to namespace
    app:post("/api/v2/namespace/members", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("users", "create", function(self)
            local params = RequestParser.parse_request(self)

            if not params.user_id and not params.email then
                return error_response(400, "user_id or email is required")
            end

            -- If email provided, find or invite user
            local user_id = params.user_id
            if params.email and not user_id then
                local user = db.select("id FROM users WHERE email = ?", params.email)
                if #user > 0 then
                    user_id = user[1].id
                else
                    -- TODO: Create invitation instead
                    return error_response(404, "User not found. Use invite endpoint instead.")
                end
            end

            -- Check namespace limits
            local member_count = NamespaceMemberQueries.count(self.namespace.id, "active")
            if member_count >= (self.namespace.max_users or 10) then
                return error_response(400, "Namespace has reached maximum member limit")
            end

            -- Get inviter's user id
            local inviter = db.select("id FROM users WHERE uuid = ?", self.current_user.uuid)

            local ok, member = pcall(NamespaceMemberQueries.create, {
                namespace_id = self.namespace.id,
                user_id = user_id,
                status = "active",
                invited_by = inviter[1] and inviter[1].id,
                role_ids = params.role_ids
            })

            if not ok then
                return error_response(500, "Failed to add member", member)
            end

            return success_response({
                message = "Member added successfully",
                member = NamespaceMemberQueries.getWithDetails(member.id)
            }, 201)
        end)
    ))

    -- Update member
    app:match("update_namespace_member", "/api/v2/namespace/members/:id", respond_to({
        PUT = AuthMiddleware.requireAuth(
            NamespaceMiddleware.requirePermission("users", "update", function(self)
                local member = NamespaceMemberQueries.show(self.params.id)

                if not member or member.namespace_id ~= self.namespace.id then
                    return error_response(404, "Member not found")
                end

                local params = RequestParser.parse_request(self)

                -- Only owners can change ownership
                if params.is_owner and not self.is_namespace_owner then
                    return error_response(403, "Only namespace owner can transfer ownership")
                end

                local ok, updated = pcall(NamespaceMemberQueries.update, member.id, {
                    status = params.status
                })

                if not ok then
                    return error_response(500, "Failed to update member", updated)
                end

                -- Update roles if provided
                if params.role_ids then
                    NamespaceMemberQueries.setRoles(member.id, params.role_ids)
                end

                return success_response({
                    message = "Member updated successfully",
                    member = NamespaceMemberQueries.getWithDetails(member.id)
                })
            end)
        ),

        DELETE = AuthMiddleware.requireAuth(
            NamespaceMiddleware.requirePermission("users", "delete", function(self)
                local member = NamespaceMemberQueries.show(self.params.id)

                if not member or member.namespace_id ~= self.namespace.id then
                    return error_response(404, "Member not found")
                end

                -- Can't remove yourself unless you're leaving
                local current_member = NamespaceMemberQueries.findByUserAndNamespace(
                    self.current_user.uuid, self.namespace.id
                )
                if current_member and current_member.id == member.id then
                    return error_response(400, "Use the leave endpoint to remove yourself")
                end

                local ok, result = pcall(NamespaceMemberQueries.destroy, member.id)

                if not ok then
                    return error_response(500, "Failed to remove member", result)
                end

                return success_response({
                    message = "Member removed successfully"
                })
            end)
        )
    }))

    -- Transfer ownership
    app:post("/api/v2/namespace/members/:id/transfer-ownership", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireOwner(function(self)
            local target_member = NamespaceMemberQueries.show(self.params.id)

            if not target_member or target_member.namespace_id ~= self.namespace.id then
                return error_response(404, "Member not found")
            end

            local current_user = db.select("id FROM users WHERE uuid = ?", self.current_user.uuid)

            local ok, result = pcall(NamespaceMemberQueries.transferOwnership,
                self.namespace.id,
                current_user[1].id,
                target_member.id
            )

            if not ok then
                return error_response(500, "Failed to transfer ownership", result)
            end

            return success_response({
                message = "Ownership transferred successfully"
            })
        end)
    ))

    -- Leave namespace
    app:post("/api/v2/namespace/leave", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local membership = self.namespace_membership

            if not membership then
                return error_response(400, "You are not a member of this namespace")
            end

            -- Owners can't leave (must transfer ownership first)
            if self.is_namespace_owner then
                return error_response(400, "Owners cannot leave. Transfer ownership first.")
            end

            local ok, result = pcall(NamespaceMemberQueries.destroy, membership.id)

            if not ok then
                return error_response(500, "Failed to leave namespace", result)
            end

            return success_response({
                message = "Successfully left namespace"
            })
        end)
    ))

    -- ============================================================
    -- NAMESPACE INVITATIONS ROUTES
    -- ============================================================

    -- List namespace invitations
    app:get("/api/v2/namespace/invitations", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("users", "read", function(self)
            local result = NamespaceInvitationQueries.all(self.namespace.id, {
                page = self.params.page,
                perPage = self.params.per_page or self.params.limit,
                status = self.params.status,
                search = self.params.search
            })

            return success_response(result)
        end)
    ))

    -- Get single invitation
    app:get("/api/v2/namespace/invitations/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("users", "read", function(self)
            local invitation = NamespaceInvitationQueries.show(self.params.id)

            if not invitation then
                return error_response(404, "Invitation not found")
            end

            -- Verify invitation belongs to this namespace
            if invitation.namespace_id ~= self.namespace.id then
                return error_response(404, "Invitation not found in this namespace")
            end

            return success_response({ invitation = invitation })
        end)
    ))

    -- Create invitation (invite member by email)
    app:post("/api/v2/namespace/invitations", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("users", "create", function(self)
            local params = RequestParser.parse_request(self)

            if not params.email or params.email == "" then
                return error_response(400, "Email is required")
            end

            -- Validate email format
            if not params.email:match("^[%w%._%+-]+@[%w%.%-]+%.[%w]+$") then
                return error_response(400, "Invalid email format")
            end

            -- Check namespace member limit
            local member_count = NamespaceMemberQueries.count(self.namespace.id, "active")
            local pending_count = NamespaceInvitationQueries.count(self.namespace.id, "pending")
            if (member_count + pending_count) >= (self.namespace.max_users or 10) then
                return error_response(400, "Namespace has reached maximum member limit")
            end

            -- Get inviter's user id
            local inviter = db.select("id FROM users WHERE uuid = ?", self.current_user.uuid)
            if not inviter or #inviter == 0 then
                return error_response(400, "Could not identify inviter")
            end

            local ok, invitation = pcall(NamespaceInvitationQueries.create, {
                namespace_id = self.namespace.id,
                email = params.email,
                role_id = params.role_id and tonumber(params.role_id),
                message = params.message,
                invited_by = inviter[1].id,
                expires_in_days = params.expires_in_days and tonumber(params.expires_in_days)
            })

            if not ok then
                local err_msg = tostring(invitation)
                if err_msg:match("already a member") then
                    return error_response(400, "User is already a member of this namespace")
                elseif err_msg:match("already pending") then
                    return error_response(400, "An invitation is already pending for this email")
                end
                return error_response(500, "Failed to create invitation", invitation)
            end

            -- TODO: Send invitation email here
            -- EmailService.sendInvitation(invitation)

            return success_response({
                message = "Invitation sent successfully",
                invitation = invitation
            }, 201)
        end)
    ))

    -- Resend invitation
    app:post("/api/v2/namespace/invitations/:id/resend", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("users", "create", function(self)
            local invitation = NamespaceInvitationQueries.show(self.params.id)

            if not invitation then
                return error_response(404, "Invitation not found")
            end

            if invitation.namespace_id ~= self.namespace.id then
                return error_response(404, "Invitation not found in this namespace")
            end

            local ok, updated = pcall(NamespaceInvitationQueries.resend, invitation.id)

            if not ok then
                return error_response(500, "Failed to resend invitation", updated)
            end

            -- TODO: Resend invitation email here
            -- EmailService.sendInvitation(updated)

            return success_response({
                message = "Invitation resent successfully",
                invitation = updated
            })
        end)
    ))

    -- Revoke invitation
    app:match("revoke_namespace_invitation", "/api/v2/namespace/invitations/:id", respond_to({
        DELETE = AuthMiddleware.requireAuth(
            NamespaceMiddleware.requirePermission("users", "delete", function(self)
                local invitation = NamespaceInvitationQueries.show(self.params.id)

                if not invitation then
                    return error_response(404, "Invitation not found")
                end

                if invitation.namespace_id ~= self.namespace.id then
                    return error_response(404, "Invitation not found in this namespace")
                end

                if invitation.status ~= "pending" then
                    return error_response(400, "Can only revoke pending invitations")
                end

                local ok, result = pcall(NamespaceInvitationQueries.revoke, invitation.id)

                if not ok then
                    return error_response(500, "Failed to revoke invitation", result)
                end

                return success_response({
                    message = "Invitation revoked successfully"
                })
            end)
        )
    }))

    -- ============================================================
    -- PUBLIC INVITATION ROUTES (Token-based, no namespace context required)
    -- ============================================================

    -- Get invitation details by token (public - for invitation landing page)
    app:get("/api/v2/invitations/:token", function(self)
        local invitation = NamespaceInvitationQueries.findByToken(self.params.token)

        if not invitation then
            return error_response(404, "Invitation not found or expired")
        end

        -- Don't expose sensitive data for non-pending invitations
        if invitation.status ~= "pending" then
            return success_response({
                invitation = {
                    status = invitation.status,
                    namespace = invitation.namespace
                }
            })
        end

        -- Check if expired
        local expires_time = Global.parseTimestamp and Global.parseTimestamp(invitation.expires_at)
        if expires_time and os.time() > expires_time then
            return success_response({
                invitation = {
                    status = "expired",
                    namespace = invitation.namespace
                }
            })
        end

        return success_response({
            invitation = {
                uuid = invitation.uuid,
                email = invitation.email,
                status = invitation.status,
                message = invitation.message,
                expires_at = invitation.expires_at,
                namespace = invitation.namespace,
                role = invitation.role,
                inviter = invitation.inviter
            }
        })
    end)

    -- Accept invitation (requires authentication)
    app:post("/api/v2/invitations/:token/accept", AuthMiddleware.requireAuth(function(self)
        local result = NamespaceInvitationQueries.accept(self.params.token, self.current_user.uuid)

        if not result.success then
            return error_response(400, result.error)
        end

        -- Get namespace details for response
        local invitation = NamespaceInvitationQueries.findByToken(self.params.token)
        local namespace = invitation and NamespaceQueries.show(invitation.namespace_id)

        return success_response({
            message = "Invitation accepted successfully",
            member = result.member,
            namespace = namespace and {
                uuid = namespace.uuid,
                name = namespace.name,
                slug = namespace.slug
            }
        })
    end))

    -- Decline invitation (can be done without auth if token is valid)
    app:post("/api/v2/invitations/:token/decline", function(self)
        local result = NamespaceInvitationQueries.decline(self.params.token)

        if not result.success then
            return error_response(400, result.error)
        end

        return success_response({
            message = "Invitation declined"
        })
    end)

    -- ============================================================
    -- NAMESPACE ROLES ROUTES
    -- ============================================================

    -- List namespace roles
    app:get("/api/v2/namespace/roles", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("roles", "read", function(self)
            local roles = NamespaceRoleQueries.all(self.namespace.id, {
                include_member_count = true
            })

            return success_response({
                data = roles,
                total = #roles
            })
        end)
    ))

    -- Get single role
    app:get("/api/v2/namespace/roles/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("roles", "read", function(self)
            local role = NamespaceRoleQueries.show(self.params.id)

            if not role or role.namespace_id ~= self.namespace.id then
                return error_response(404, "Role not found")
            end

            -- Get members with this role
            local members = NamespaceRoleQueries.getMembers(role.id, {
                page = 1,
                perPage = 10
            })

            return success_response({
                role = role,
                members = members
            })
        end)
    ))

    -- Create role
    app:post("/api/v2/namespace/roles", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("roles", "create", function(self)
            local params = RequestParser.parse_request(self)

            if not params.role_name or params.role_name == "" then
                return error_response(400, "role_name is required")
            end

            local ok, role = pcall(NamespaceRoleQueries.create, {
                namespace_id = self.namespace.id,
                role_name = params.role_name,
                display_name = params.display_name,
                description = params.description,
                permissions = params.permissions,
                is_default = params.is_default,
                priority = params.priority
            })

            if not ok then
                return error_response(500, "Failed to create role", role)
            end

            return success_response({
                message = "Role created successfully",
                role = role
            }, 201)
        end)
    ))

    -- Update role
    app:match("update_namespace_role", "/api/v2/namespace/roles/:id", respond_to({
        PUT = AuthMiddleware.requireAuth(
            NamespaceMiddleware.requirePermission("roles", "update", function(self)
                local role = NamespaceRoleQueries.show(self.params.id)

                if not role or role.namespace_id ~= self.namespace.id then
                    return error_response(404, "Role not found")
                end

                local params = RequestParser.parse_request(self)

                local ok, updated = pcall(NamespaceRoleQueries.update, role.id, params)

                if not ok then
                    return error_response(500, "Failed to update role", updated)
                end

                return success_response({
                    message = "Role updated successfully",
                    role = updated
                })
            end)
        ),

        DELETE = AuthMiddleware.requireAuth(
            NamespaceMiddleware.requirePermission("roles", "delete", function(self)
                local role = NamespaceRoleQueries.show(self.params.id)

                if not role or role.namespace_id ~= self.namespace.id then
                    return error_response(404, "Role not found")
                end

                local ok, result = pcall(NamespaceRoleQueries.destroy, role.id)

                if not ok then
                    return error_response(500, "Failed to delete role", result)
                end

                return success_response({
                    message = "Role deleted successfully"
                })
            end)
        )
    }))

    -- Get available modules and actions for permissions
    app:get("/api/v2/namespace/roles/meta/permissions", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("roles", "read", function(self)
            return success_response({
                modules = NamespaceRoleQueries.getAvailableModules(),
                actions = NamespaceRoleQueries.getAvailableActions()
            })
        end)
    ))

    -- ============================================================
    -- PLATFORM ADMIN ROUTES (Super admin only)
    -- ============================================================

    -- Helper function to check platform admin access
    local function check_platform_admin(current_user)
        if not current_user then
            return false
        end

        local admin_check = db.query([[
            SELECT ur.id FROM user__roles ur
            JOIN roles r ON ur.role_id = r.id
            JOIN users u ON ur.user_id = u.id
            WHERE u.uuid = ? AND LOWER(r.role_name) = 'administrative'
        ]], current_user.uuid)

        return admin_check and #admin_check > 0
    end

    -- Helper function to check namespace create permission
    local function check_namespace_create_permission(current_user)
        if not current_user then
            return false
        end

        -- First check if user is platform admin
        if check_platform_admin(current_user) then
            return true
        end

        -- Then check for specific namespace create permission
        local perm_check = db.query([[
            SELECT p.id FROM permissions p
            JOIN roles r ON p.role_id = r.id
            JOIN user__roles ur ON ur.role_id = r.id
            JOIN users u ON ur.user_id = u.id
            JOIN modules m ON p.module_id = m.id
            WHERE u.uuid = ?
            AND m.machine_name = 'namespaces'
            AND p.permissions LIKE '%create%'
        ]], current_user.uuid)

        return perm_check and #perm_check > 0
    end

    -- List all namespaces (platform admin)
    app:get("/api/v2/admin/namespaces", AuthMiddleware.requireAuth(function(self)
        if not check_platform_admin(self.current_user) then
            return error_response(403, "Platform admin access required")
        end

        local result = NamespaceQueries.all({
            page = self.params.page,
            perPage = self.params.per_page or self.params.limit,
            status = self.params.status,
            search = self.params.search,
            orderBy = self.params.order_by,
            orderDir = self.params.order_dir
        })

        return success_response(result)
    end))

    -- Get single namespace details (platform admin)
    app:get("/api/v2/admin/namespaces/:id", AuthMiddleware.requireAuth(function(self)
        if not check_platform_admin(self.current_user) then
            return error_response(403, "Platform admin access required")
        end

        local namespace = NamespaceQueries.show(self.params.id)
        if not namespace then
            return error_response(404, "Namespace not found")
        end

        -- Get member count
        local member_count = db.query([[
            SELECT COUNT(*) as count FROM namespace_members
            WHERE namespace_id = ? AND status = 'active'
        ]], namespace.id)

        -- Get store count
        local store_count = db.query([[
            SELECT COUNT(*) as count FROM stores
            WHERE namespace_id = ?
        ]], namespace.id)

        namespace.member_count = member_count and member_count[1] and member_count[1].count or 0
        namespace.store_count = store_count and store_count[1] and store_count[1].count or 0

        return success_response({ namespace = namespace })
    end))

    -- Create namespace (platform admin or users with namespace create permission)
    app:post("/api/v2/admin/namespaces", AuthMiddleware.requireAuth(function(self)
        if not check_namespace_create_permission(self.current_user) then
            return error_response(403, "You don't have permission to create namespaces")
        end

        local params = RequestParser.parse_request(self)

        -- Validate required fields
        if not params.name or params.name == "" then
            return error_response(400, "Namespace name is required")
        end

        -- Check slug availability
        if params.slug then
            if not NamespaceQueries.isSlugAvailable(params.slug) then
                return error_response(400, "Slug is already taken")
            end
        end

        -- Get owner user if specified, otherwise use current user
        local owner_user_id = nil
        if params.owner_uuid then
            local owner = db.select("id FROM users WHERE uuid = ?", params.owner_uuid)
            if not owner or #owner == 0 then
                return error_response(400, "Owner user not found")
            end
            owner_user_id = owner[1].id
        else
            local current = db.select("id FROM users WHERE uuid = ?", self.current_user.uuid)
            if current and #current > 0 then
                owner_user_id = current[1].id
            end
        end

        -- Create namespace with owner
        local result, err = NamespaceQueries.createWithOwner(owner_user_id, {
            name = params.name,
            slug = params.slug,
            description = params.description,
            domain = params.domain,
            logo_url = params.logo_url,
            banner_url = params.banner_url,
            status = params.status or "active",
            plan = params.plan or "free",
            max_users = tonumber(params.max_users) or 10,
            max_stores = tonumber(params.max_stores) or 5,
            settings = params.settings
        })

        if not result then
            return error_response(500, "Failed to create namespace", err)
        end

        return success_response({
            message = "Namespace created successfully",
            namespace = result.namespace,
            membership = result.membership
        }, 201)
    end))

    -- Update namespace (platform admin)
    app:match("admin_namespace_update", "/api/v2/admin/namespaces/:id", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            if not check_platform_admin(self.current_user) then
                return error_response(403, "Platform admin access required")
            end

            local namespace = NamespaceQueries.show(self.params.id)
            if not namespace then
                return error_response(404, "Namespace not found")
            end

            local params = RequestParser.parse_request(self)

            -- Check slug availability if changing
            if params.slug and params.slug ~= namespace.slug then
                if not NamespaceQueries.isSlugAvailable(params.slug) then
                    return error_response(400, "Slug is already taken")
                end
            end

            -- Update namespace
            local updated, err = NamespaceQueries.update(namespace.id, {
                name = params.name,
                slug = params.slug,
                description = params.description,
                domain = params.domain,
                logo_url = params.logo_url,
                banner_url = params.banner_url,
                status = params.status,
                plan = params.plan,
                max_users = params.max_users and tonumber(params.max_users),
                max_stores = params.max_stores and tonumber(params.max_stores),
                settings = params.settings
            })

            if not updated then
                return error_response(500, "Failed to update namespace", err)
            end

            return success_response({
                message = "Namespace updated successfully",
                namespace = updated
            })
        end),

        DELETE = AuthMiddleware.requireAuth(function(self)
            if not check_platform_admin(self.current_user) then
                return error_response(403, "Platform admin access required")
            end

            local namespace = NamespaceQueries.show(self.params.id)
            if not namespace then
                return error_response(404, "Namespace not found")
            end

            -- Prevent deletion of system namespace
            if namespace.slug == "system" or namespace.slug == "default" then
                return error_response(400, "Cannot delete system namespace")
            end

            -- Check if namespace has active members other than owner
            local member_count = db.query([[
                SELECT COUNT(*) as count FROM namespace_members
                WHERE namespace_id = ? AND status = 'active' AND is_owner = false
            ]], namespace.id)

            if member_count and member_count[1] and member_count[1].count > 0 then
                return error_response(400, "Cannot delete namespace with active members. Remove all members first.")
            end

            -- Soft delete by setting status to archived
            local success, err = NamespaceQueries.update(namespace.id, {
                status = "archived"
            })

            if not success then
                return error_response(500, "Failed to delete namespace", err)
            end

            return success_response({
                message = "Namespace archived successfully"
            })
        end)
    }))

    -- Get namespace statistics (platform admin)
    app:get("/api/v2/admin/namespaces/:id/stats", AuthMiddleware.requireAuth(function(self)
        if not check_platform_admin(self.current_user) then
            return error_response(403, "Platform admin access required")
        end

        local namespace = NamespaceQueries.show(self.params.id)
        if not namespace then
            return error_response(404, "Namespace not found")
        end

        local stats = {
            total_members = 0,
            total_stores = 0,
            total_products = 0,
            total_orders = 0,
            total_customers = 0,
            total_revenue = 0
        }

        -- Get counts
        local members = db.query("SELECT COUNT(*) as count FROM namespace_members WHERE namespace_id = ? AND status = 'active'", namespace.id)
        local stores = db.query("SELECT COUNT(*) as count FROM stores WHERE namespace_id = ?", namespace.id)
        local products = db.query("SELECT COUNT(*) as count FROM store_products sp JOIN stores s ON sp.store_uuid = s.uuid WHERE s.namespace_id = ?", namespace.id)
        local orders = db.query("SELECT COUNT(*) as count FROM orders o JOIN stores s ON o.store_uuid = s.uuid WHERE s.namespace_id = ?", namespace.id)
        local customers = db.query("SELECT COUNT(DISTINCT customer_uuid) as count FROM orders o JOIN stores s ON o.store_uuid = s.uuid WHERE s.namespace_id = ?", namespace.id)
        local revenue = db.query("SELECT COALESCE(SUM(total), 0) as total FROM orders o JOIN stores s ON o.store_uuid = s.uuid WHERE s.namespace_id = ? AND o.payment_status = 'paid'", namespace.id)

        stats.total_members = members and members[1] and members[1].count or 0
        stats.total_stores = stores and stores[1] and stores[1].count or 0
        stats.total_products = products and products[1] and products[1].count or 0
        stats.total_orders = orders and orders[1] and orders[1].count or 0
        stats.total_customers = customers and customers[1] and customers[1].count or 0
        stats.total_revenue = revenue and revenue[1] and tonumber(revenue[1].total) or 0

        return success_response({ stats = stats })
    end))

    -- ============================================================
    -- ADMIN INVITATION ROUTES (Platform admin - operates on any namespace)
    -- ============================================================

    -- Create invitation for a specific namespace (admin context)
    -- This endpoint takes namespace_id from URL, not from header
    app:post("/api/v2/admin/namespaces/:id/invitations", AuthMiddleware.requireAuth(function(self)
        if not check_platform_admin(self.current_user) then
            return error_response(403, "Platform admin access required")
        end

        local namespace = NamespaceQueries.show(self.params.id)
        if not namespace then
            return error_response(404, "Namespace not found")
        end

        local params = RequestParser.parse_request(self)

        if not params.email or params.email == "" then
            return error_response(400, "Email is required")
        end

        -- Validate email format
        if not params.email:match("^[%w%._%+-]+@[%w%.%-]+%.[%w]+$") then
            return error_response(400, "Invalid email format")
        end

        -- Check namespace member limit
        local member_count = NamespaceMemberQueries.count(namespace.id, "active")
        local pending_count = NamespaceInvitationQueries.count(namespace.id, "pending")
        if (member_count + pending_count) >= (namespace.max_users or 10) then
            return error_response(400, "Namespace has reached maximum member limit")
        end

        -- Get inviter's user id
        local inviter = db.select("id FROM users WHERE uuid = ?", self.current_user.uuid)
        if not inviter or #inviter == 0 then
            return error_response(400, "Could not identify inviter")
        end

        local ok, invitation = pcall(NamespaceInvitationQueries.create, {
            namespace_id = namespace.id,
            email = params.email,
            role_id = params.role_id and tonumber(params.role_id),
            message = params.message,
            invited_by = inviter[1].id,
            expires_in_days = params.expires_in_days and tonumber(params.expires_in_days)
        })

        if not ok then
            local err_msg = tostring(invitation)
            if err_msg:match("already a member") then
                return error_response(400, "User is already a member of this namespace")
            elseif err_msg:match("already pending") then
                return error_response(400, "An invitation is already pending for this email")
            end
            return error_response(500, "Failed to create invitation", invitation)
        end

        return success_response({
            message = "Invitation sent successfully",
            invitation = invitation
        }, 201)
    end))

    -- List invitations for a specific namespace (admin context)
    app:get("/api/v2/admin/namespaces/:id/invitations", AuthMiddleware.requireAuth(function(self)
        if not check_platform_admin(self.current_user) then
            return error_response(403, "Platform admin access required")
        end

        local namespace = NamespaceQueries.show(self.params.id)
        if not namespace then
            return error_response(404, "Namespace not found")
        end

        local result = NamespaceInvitationQueries.all(namespace.id, {
            page = self.params.page,
            perPage = self.params.per_page or self.params.limit,
            status = self.params.status,
            search = self.params.search
        })

        return success_response(result)
    end))

    -- Get roles for a specific namespace (admin context)
    app:get("/api/v2/admin/namespaces/:id/roles", AuthMiddleware.requireAuth(function(self)
        if not check_platform_admin(self.current_user) then
            return error_response(403, "Platform admin access required")
        end

        local namespace = NamespaceQueries.show(self.params.id)
        if not namespace then
            return error_response(404, "Namespace not found")
        end

        local roles = NamespaceRoleQueries.all(namespace.id, {
            include_member_count = true
        })

        return success_response({
            data = roles,
            total = #roles
        })
    end))

    -- Transfer namespace ownership (platform admin)
    app:post("/api/v2/admin/namespaces/:id/transfer-ownership", AuthMiddleware.requireAuth(function(self)
        if not check_platform_admin(self.current_user) then
            return error_response(403, "Platform admin access required")
        end

        local namespace = NamespaceQueries.show(self.params.id)
        if not namespace then
            return error_response(404, "Namespace not found")
        end

        local params = RequestParser.parse_request(self)
        if not params.new_owner_uuid then
            return error_response(400, "New owner UUID is required")
        end

        -- Find new owner
        local new_owner = db.select("id FROM users WHERE uuid = ?", params.new_owner_uuid)
        if not new_owner or #new_owner == 0 then
            return error_response(404, "New owner user not found")
        end

        -- Check if new owner is a member
        local membership = db.query([[
            SELECT nm.id FROM namespace_members nm
            JOIN users u ON nm.user_id = u.id
            WHERE u.uuid = ? AND nm.namespace_id = ?
        ]], params.new_owner_uuid, namespace.id)

        if not membership or #membership == 0 then
            return error_response(400, "New owner must be a member of the namespace")
        end

        -- Remove current owner flag
        db.update("namespace_members", {
            is_owner = false
        }, {
            namespace_id = namespace.id,
            is_owner = true
        })

        -- Set new owner
        db.update("namespace_members", {
            is_owner = true
        }, {
            id = membership[1].id
        })

        -- Update namespace owner_user_id
        db.update("namespaces", {
            owner_user_id = new_owner[1].id
        }, {
            id = namespace.id
        })

        return success_response({
            message = "Ownership transferred successfully"
        })
    end))

    ngx.log(ngx.NOTICE, "Namespace routes initialized successfully")
end
