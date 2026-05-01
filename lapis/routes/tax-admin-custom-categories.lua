--[[
    Tax Admin Custom Categories Routes — issue #308

    Admin moderation surface for user-created custom categories. The
    user-side CRUD (POST, GET-mine, DELETE-mine) is the other developer's
    responsibility — this file only exposes admin endpoints.

    Endpoint summary:
      GET    /api/v2/admin/custom-categories              — paginated list, filterable
      GET    /api/v2/admin/custom-categories/stats         — counts by status
      GET    /api/v2/admin/custom-categories/duplicates    — promotion candidates
      GET    /api/v2/admin/custom-categories/:uuid         — detail + sample transactions
      PUT    /api/v2/admin/custom-categories/:uuid/approve — approve + map
      PUT    /api/v2/admin/custom-categories/:uuid/reject  — reject with notes
      POST   /api/v2/admin/custom-categories/:uuid/promote — create system category + migrate

    Permission gate uses the existing AdminCheck pattern (matches
    tax-admin-categories.lua / permissions.lua).
]]

local CustomCategoryQueries = require("queries.CustomCategoryQueries")
local RequestParser = require("helper.request_parser")
local AuthMiddleware = require("middleware.auth")
local AdminCheck = require("helper.admin-check")
local cjson = require("cjson")

cjson.encode_empty_table_as_object(false)

local function is_admin(user)
    return AdminCheck.isPlatformAdmin(user)
end

local function error_response(status, message, details)
    ngx.log(ngx.ERR, "[Custom Categories Admin] ", message,
            details and (" | " .. tostring(details)) or "")
    return {
        status = status,
        json = {
            error = message,
            details = type(details) == "string" and details or nil,
        },
    }
end

return function(app)

    -- LIST custom categories with filters
    --   ?status=pending|approved|rejected|promoted|all (default: pending)
    --   ?user_uuid=<uuid>
    --   ?namespace_id=<int>
    --   ?search=<string>          (matches name or key_normalized)
    --   ?page=1&per_page=25
    app:get("/api/v2/admin/custom-categories", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return error_response(403, "Admin access required")
        end

        local ok, rows, total, page, per_page = pcall(CustomCategoryQueries.list, {
            status = self.params.status or "pending",
            user_uuid = self.params.user_uuid,
            namespace_id = self.params.namespace_id,
            search = self.params.search,
            page = self.params.page,
            per_page = self.params.per_page,
        })
        if not ok then
            return error_response(500, "Failed to list custom categories", tostring(rows))
        end

        return {
            status = 200,
            json = {
                data = rows or {},
                total = total or 0,
                page = page or 1,
                per_page = per_page or 25,
            },
        }
    end))

    -- AGGREGATE stats — counts by status. Cheap query the dashboard polls.
    app:get("/api/v2/admin/custom-categories/stats", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return error_response(403, "Admin access required")
        end

        local ok, stats = pcall(CustomCategoryQueries.stats)
        if not ok then
            return error_response(500, "Failed to compute stats", tostring(stats))
        end
        return { status = 200, json = { data = stats } }
    end))

    -- DUPLICATES — names that ≥N users have created. Promotion candidates.
    --   ?min_users=3 (default)
    app:get("/api/v2/admin/custom-categories/duplicates", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return error_response(403, "Admin access required")
        end

        local ok, rows = pcall(
            CustomCategoryQueries.find_duplicates, self.params.min_users
        )
        if not ok then
            return error_response(500, "Failed to find duplicates", tostring(rows))
        end
        return { status = 200, json = { data = rows or {} } }
    end))

    -- DETAIL view — full row + sample transactions
    app:get("/api/v2/admin/custom-categories/:uuid", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return error_response(403, "Admin access required")
        end

        local row = CustomCategoryQueries.get_by_uuid(self.params.uuid)
        if not row then
            return error_response(404, "Custom category not found")
        end

        local samples = CustomCategoryQueries.sample_transactions(self.params.uuid, 10)

        return {
            status = 200,
            json = {
                data = row,
                sample_transactions = samples,
            },
        }
    end))

    -- APPROVE: link the custom to an existing system tax_categories row.
    -- Body: {
    --   "mapped_to_category_uuid": <string UUID, required>,
    --   "mapped_to_hmrc_category_uuid": <string UUID, optional — inferred if absent>,
    --   "admin_notes": <string, optional>
    -- }
    app:put("/api/v2/admin/custom-categories/:uuid/approve", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return error_response(403, "Admin access required")
        end

        local params = RequestParser.parse_request(self)
        local valid, missing = RequestParser.require_params(params, { "mapped_to_category_uuid" })
        if not valid then
            return error_response(400, "Missing required fields",
                                  table.concat(missing, ", "))
        end

        local reviewer_uuid = self.current_user
            and (self.current_user.uuid or self.current_user.id)
            or nil

        local ok, row, err = pcall(CustomCategoryQueries.approve, self.params.uuid, {
            mapped_to_category_uuid = params.mapped_to_category_uuid,
            mapped_to_hmrc_category_uuid = params.mapped_to_hmrc_category_uuid,
            admin_notes = params.admin_notes,
            reviewer_uuid = reviewer_uuid,
        })
        if not ok then
            return error_response(500, "Approve failed", tostring(row))
        end
        if not row and err then
            return error_response(422, err)
        end

        return {
            status = 200,
            json = { data = row, message = "Custom category approved" },
        }
    end))

    -- REJECT with mandatory admin_notes (so the user knows why if we ever
    -- expose rejection reasons in the user UI).
    -- Body: { "admin_notes": <string, required> }
    app:put("/api/v2/admin/custom-categories/:uuid/reject", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return error_response(403, "Admin access required")
        end

        local params = RequestParser.parse_request(self)
        local valid, missing = RequestParser.require_params(params, { "admin_notes" })
        if not valid then
            return error_response(400, "Missing required fields",
                                  table.concat(missing, ", "))
        end

        local reviewer_uuid = self.current_user
            and (self.current_user.uuid or self.current_user.id)
            or nil

        local ok, row, err = pcall(CustomCategoryQueries.reject, self.params.uuid, {
            admin_notes = params.admin_notes,
            reviewer_uuid = reviewer_uuid,
        })
        if not ok then
            return error_response(500, "Reject failed", tostring(row))
        end
        if not row and err then
            return error_response(422, err)
        end

        return {
            status = 200,
            json = { data = row, message = "Custom category rejected" },
        }
    end))

    -- PROMOTE: create a brand-new system tax_categories row and migrate
    -- every transaction across users to point at it. Optionally promotes
    -- every custom with the same key_normalized in one go.
    --
    -- Body: {
    --   "system_key":          <slug, required>,
    --   "system_label":        <string, required>,
    --   "hmrc_category_uuid":  <UUID string, required>,
    --   "type":                "income"|"expense" (required),
    --   "is_tax_deductible":   <bool, optional, default true>,
    --   "deduction_rate":      <number, optional, default 1.0>,
    --   "description":         <string, optional>,
    --   "examples":            <string, optional>,
    --   "include_other_users": <bool, optional, default false>,
    --   "admin_notes":         <string, optional>
    -- }
    app:post("/api/v2/admin/custom-categories/:uuid/promote", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return error_response(403, "Admin access required")
        end

        local params = RequestParser.parse_request(self)
        local required = { "system_key", "system_label", "hmrc_category_uuid", "type" }
        local valid, missing = RequestParser.require_params(params, required)
        if not valid then
            return error_response(400, "Missing required fields",
                                  table.concat(missing, ", "))
        end

        local promoter_uuid = self.current_user
            and (self.current_user.uuid or self.current_user.id)
            or nil

        if not promoter_uuid then
            return error_response(401, "Promoter user UUID could not be determined")
        end

        -- Coerce booleans defensively — promote() is destructive, so we
        -- want to be explicit about every flag we forward.
        local include_others = params.include_other_users
        if type(include_others) == "string" then
            include_others = (include_others == "true")
        end
        local is_deductible = params.is_tax_deductible
        if type(is_deductible) == "string" then
            is_deductible = (is_deductible == "true")
        end

        local ok, result, err = pcall(CustomCategoryQueries.promote, self.params.uuid, {
            system_key = params.system_key,
            system_label = params.system_label,
            hmrc_category_uuid = params.hmrc_category_uuid,
            type = params.type,
            is_tax_deductible = is_deductible ~= false,
            deduction_rate = tonumber(params.deduction_rate),
            description = params.description,
            examples = params.examples,
            include_other_users = include_others,
            admin_notes = params.admin_notes,
            promoter_uuid = promoter_uuid,
        })
        if not ok then
            return error_response(500, "Promote failed", tostring(result))
        end
        if not result and err then
            return error_response(422, err)
        end

        return {
            status = 200,
            json = {
                data = result,
                message = "Custom category promoted to system category",
            },
        }
    end))

    ngx.log(ngx.NOTICE, "[Custom Categories Admin] routes initialized")
end
