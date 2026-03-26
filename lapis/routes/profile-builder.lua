--[[
    Profile Builder Routes (Dynamic Profile Management)

    Full CRUD for profile categories, questions, options, rules, tags,
    lookup tables, touchpoints, answers, completion tracking, and audit logs.

    Route prefix: /api/v2/profile-builder
    Admin endpoints require admin or accountant role.
    Answer endpoints are user-scoped.
]]

local db = require("lapis.db")
local cjson = require("cjson")

-- =========================================================================
-- Helper Functions
-- =========================================================================

local function parseJsonBody(self)
    local params = self.params or {}
    local ct = ngx.req.get_headers()["content-type"]
    if ct and ct:find("application/json") then
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if body then
            local ok, parsed = pcall(cjson.decode, body)
            if ok and parsed then
                for k, v in pairs(parsed) do params[k] = v end
            end
        end
    end
    return params
end

local function requireAuth(self)
    local user = self.current_user
    if not user then
        return nil
    end
    return user
end

local function requireAdmin(self)
    local user = self.current_user
    if not user then
        return nil, "auth"
    end
    local user_uuid = user.uuid or user.id
    local ok, rows = pcall(db.query, [[
        SELECT r.role_name
        FROM user__roles ur
        JOIN roles r ON ur.role_id = r.id
        JOIN users u ON ur.user_id = u.id
        WHERE u.uuid = ?
        LIMIT 1
    ]], user_uuid)
    if ok and rows and #rows > 0 then
        local role = rows[1].role_name
        if role == "administrative" or role == "tax_admin" or role == "tax_accountant" then
            return user
        end
    end
    return nil, "forbidden"
end

local function getNamespaceId(self)
    local ns_header = ngx.req.get_headers()["x-namespace-id"]
    if ns_header and ns_header ~= "" then
        local n = tonumber(ns_header)
        if n then return n end
    end
    local user = self.current_user
    if user then
        local user_uuid = user.uuid or user.id
        local ok, rows = pcall(db.query, [[
            SELECT namespace_id FROM user_namespaces WHERE user_uuid = ? LIMIT 1
        ]], user_uuid)
        if ok and rows and #rows > 0 then
            return rows[1].namespace_id
        end
    end
    return nil
end

local function auditLog(params)
    local ok, err = pcall(db.query, [[
        INSERT INTO profile_audit_logs (uuid, namespace_id, user_id, action, entity_type, entity_uuid, old_data_json, new_data_json, ip_address, created_at)
        VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
    ]],
        params.namespace_id,
        params.user_id,
        params.action,
        params.entity_type,
        params.entity_uuid,
        params.old_data_json,
        params.new_data_json,
        params.ip_address
    )
    if not ok then
        ngx.log(ngx.ERR, "[ProfileBuilder] audit log insert failed: ", tostring(err))
    end
end

local function recalculateCompletion(user_id, user_uuid, category_id)
    local ok, err = pcall(function()
        local total_rows = db.query([[
            SELECT COUNT(*) AS cnt FROM profile_questions
            WHERE category_id = ? AND is_active = true AND is_archived = false
        ]], category_id)
        local total = total_rows and total_rows[1] and tonumber(total_rows[1].cnt) or 0

        local required_rows = db.query([[
            SELECT COUNT(*) AS cnt FROM profile_questions
            WHERE category_id = ? AND is_active = true AND is_archived = false AND is_required = true
        ]], category_id)
        local required = required_rows and required_rows[1] and tonumber(required_rows[1].cnt) or 0

        local answered_rows = db.query([[
            SELECT COUNT(DISTINCT upa.question_id) AS cnt
            FROM user_profile_answers upa
            JOIN profile_questions pq ON pq.id = upa.question_id
            WHERE upa.user_id = ? AND pq.category_id = ? AND pq.is_active = true AND pq.is_archived = false
              AND upa.is_draft = false
        ]], user_id, category_id)
        local answered = answered_rows and answered_rows[1] and tonumber(answered_rows[1].cnt) or 0

        local req_answered_rows = db.query([[
            SELECT COUNT(DISTINCT upa.question_id) AS cnt
            FROM user_profile_answers upa
            JOIN profile_questions pq ON pq.id = upa.question_id
            WHERE upa.user_id = ? AND pq.category_id = ? AND pq.is_active = true AND pq.is_archived = false
              AND pq.is_required = true AND upa.is_draft = false
        ]], user_id, category_id)
        local req_answered = req_answered_rows and req_answered_rows[1] and tonumber(req_answered_rows[1].cnt) or 0

        local pct = 0
        if total > 0 then
            pct = math.floor((answered / total) * 100)
        end

        local status = "not_started"
        if pct >= 100 then
            status = "complete"
        elseif pct > 0 then
            status = "in_progress"
        end

        db.query([[
            INSERT INTO profile_completion_status (uuid, user_id, user_uuid, category_id, total_questions, answered_questions, required_questions, required_answered, completion_percent, status, last_calculated_at, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW(), NOW())
            ON CONFLICT (user_id, category_id) DO UPDATE SET
                total_questions = EXCLUDED.total_questions,
                answered_questions = EXCLUDED.answered_questions,
                required_questions = EXCLUDED.required_questions,
                required_answered = EXCLUDED.required_answered,
                completion_percent = EXCLUDED.completion_percent,
                status = EXCLUDED.status,
                last_calculated_at = NOW(),
                updated_at = NOW()
        ]], user_id, user_uuid, category_id, total, answered, required, req_answered, pct, status)
    end)
    if not ok then
        ngx.log(ngx.ERR, "[ProfileBuilder] recalculateCompletion failed: ", tostring(err))
    end
end

local function getUserIdByUuid(user_uuid)
    local ok, rows = pcall(db.query, "SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    if ok and rows and #rows > 0 then
        return rows[1].id
    end
    return nil
end

local function getClientIp()
    return ngx.var.remote_addr or "unknown"
end

local PREFIX = "/api/v2/profile-builder"

-- =========================================================================
-- Route definitions
-- =========================================================================

return function(app)

    -- =====================================================================
    -- 1. GET /schema — Full schema for end-user
    -- =====================================================================
    app:get(PREFIX .. "/schema", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_uuid = user.uuid or user.id
        local user_id = getUserIdByUuid(user_uuid)
        local namespace_id = getNamespaceId(self)

        local ok_cats, categories = pcall(db.query, [[
            SELECT * FROM profile_categories
            WHERE is_active = true AND is_archived = false
            ]] .. (namespace_id and " AND namespace_id = " .. db.escape_literal(namespace_id) or "") .. [[
            ORDER BY display_order ASC, name ASC
        ]])
        if not ok_cats then
            ngx.log(ngx.ERR, "[ProfileBuilder] schema categories query failed: ", tostring(categories))
            return { status = 500, json = { error = "Failed to load schema" } }
        end

        local result = {}
        for _, cat in ipairs(categories or {}) do
            local ok_q, questions = pcall(db.query, [[
                SELECT * FROM profile_questions
                WHERE category_id = ? AND is_active = true AND is_archived = false
                ORDER BY display_order ASC, label ASC
            ]], cat.id)
            if not ok_q then
                ngx.log(ngx.ERR, "[ProfileBuilder] schema questions query failed: ", tostring(questions))
                questions = {}
            end

            local q_list = {}
            for _, q in ipairs(questions or {}) do
                local ok_opts, options = pcall(db.query, [[
                    SELECT * FROM profile_question_options
                    WHERE question_id = ? AND is_active = true
                    ORDER BY display_order ASC, label ASC
                ]], q.id)
                if not ok_opts then options = {} end

                local answer = nil
                if user_id then
                    local ok_ans, ans_rows = pcall(db.query, [[
                        SELECT * FROM user_profile_answers
                        WHERE user_id = ? AND question_id = ?
                        ORDER BY answered_at DESC LIMIT 1
                    ]], user_id, q.id)
                    if ok_ans and ans_rows and #ans_rows > 0 then
                        answer = ans_rows[1]
                    end
                end

                local opt_list = {}
                for _, o in ipairs(options or {}) do
                    table.insert(opt_list, {
                        uuid = o.uuid,
                        label = o.label,
                        value = o.value,
                        description = o.description,
                        display_order = o.display_order,
                        is_default = o.is_default,
                        parent_option_id = o.parent_option_id,
                        metadata_json = o.metadata_json
                    })
                end

                table.insert(q_list, {
                    uuid = q.uuid,
                    question_key = q.question_key,
                    label = q.label,
                    description = q.description,
                    help_text = q.help_text,
                    placeholder = q.placeholder,
                    question_type = q.question_type,
                    is_required = q.is_required,
                    is_multi_value = q.is_multi_value,
                    is_editable_by_user = q.is_editable_by_user,
                    display_order = q.display_order,
                    validation_json = q.validation_json,
                    default_value = q.default_value,
                    config_json = q.config_json,
                    version = q.version,
                    options = opt_list,
                    answer = answer and {
                        uuid = answer.uuid,
                        answer_text = answer.answer_text,
                        answer_number = answer.answer_number,
                        answer_boolean = answer.answer_boolean,
                        answer_date = answer.answer_date,
                        answer_json = answer.answer_json,
                        answer_file_url = answer.answer_file_url,
                        is_draft = answer.is_draft,
                        answered_at = answer.answered_at
                    } or nil
                })
            end

            local completion = nil
            if user_id then
                local ok_comp, comp_rows = pcall(db.query, [[
                    SELECT * FROM profile_completion_status
                    WHERE user_id = ? AND category_id = ?
                    LIMIT 1
                ]], user_id, cat.id)
                if ok_comp and comp_rows and #comp_rows > 0 then
                    local c = comp_rows[1]
                    completion = {
                        total_questions = c.total_questions,
                        answered_questions = c.answered_questions,
                        required_questions = c.required_questions,
                        required_answered = c.required_answered,
                        completion_percent = c.completion_percent,
                        status = c.status
                    }
                end
            end

            table.insert(result, {
                uuid = cat.uuid,
                name = cat.name,
                slug = cat.slug,
                description = cat.description,
                icon = cat.icon,
                display_order = cat.display_order,
                parent_id = cat.parent_id,
                visibility_rule_json = cat.visibility_rule_json,
                completion_rule_json = cat.completion_rule_json,
                questions = q_list,
                completion = completion
            })
        end

        return { status = 200, json = { schema = result } }
    end)

    -- =====================================================================
    -- 2. GET /schema/preview — Admin: preview schema as a specific user
    -- =====================================================================
    app:get(PREFIX .. "/schema/preview", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local target_uuid = self.params.user_uuid
        if not target_uuid or target_uuid == "" then
            return { status = 400, json = { error = "user_uuid query parameter is required" } }
        end

        local target_user_id = getUserIdByUuid(target_uuid)
        if not target_user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        local namespace_id = getNamespaceId(self)

        local ok_cats, categories = pcall(db.query, [[
            SELECT * FROM profile_categories
            WHERE is_active = true AND is_archived = false
            ]] .. (namespace_id and " AND namespace_id = " .. db.escape_literal(namespace_id) or "") .. [[
            ORDER BY display_order ASC, name ASC
        ]])
        if not ok_cats then
            return { status = 500, json = { error = "Failed to load schema" } }
        end

        local result = {}
        for _, cat in ipairs(categories or {}) do
            local ok_q, questions = pcall(db.query, [[
                SELECT * FROM profile_questions
                WHERE category_id = ? AND is_active = true AND is_archived = false
                ORDER BY display_order ASC, label ASC
            ]], cat.id)
            if not ok_q then questions = {} end

            local q_list = {}
            for _, q in ipairs(questions or {}) do
                local ok_opts, options = pcall(db.query, [[
                    SELECT * FROM profile_question_options
                    WHERE question_id = ? AND is_active = true
                    ORDER BY display_order ASC, label ASC
                ]], q.id)
                if not ok_opts then options = {} end

                local answer = nil
                local ok_ans, ans_rows = pcall(db.query, [[
                    SELECT * FROM user_profile_answers
                    WHERE user_id = ? AND question_id = ?
                    ORDER BY answered_at DESC LIMIT 1
                ]], target_user_id, q.id)
                if ok_ans and ans_rows and #ans_rows > 0 then
                    answer = ans_rows[1]
                end

                local opt_list = {}
                for _, o in ipairs(options or {}) do
                    table.insert(opt_list, {
                        uuid = o.uuid, label = o.label, value = o.value,
                        description = o.description, display_order = o.display_order,
                        is_default = o.is_default, parent_option_id = o.parent_option_id,
                        metadata_json = o.metadata_json
                    })
                end

                table.insert(q_list, {
                    uuid = q.uuid, question_key = q.question_key, label = q.label,
                    description = q.description, help_text = q.help_text,
                    placeholder = q.placeholder, question_type = q.question_type,
                    is_required = q.is_required, is_multi_value = q.is_multi_value,
                    is_editable_by_user = q.is_editable_by_user, display_order = q.display_order,
                    validation_json = q.validation_json, default_value = q.default_value,
                    config_json = q.config_json, version = q.version,
                    options = opt_list,
                    answer = answer and {
                        uuid = answer.uuid, answer_text = answer.answer_text,
                        answer_number = answer.answer_number, answer_boolean = answer.answer_boolean,
                        answer_date = answer.answer_date, answer_json = answer.answer_json,
                        answer_file_url = answer.answer_file_url, is_draft = answer.is_draft,
                        answered_at = answer.answered_at
                    } or nil
                })
            end

            local completion = nil
            local ok_comp, comp_rows = pcall(db.query, [[
                SELECT * FROM profile_completion_status
                WHERE user_id = ? AND category_id = ? LIMIT 1
            ]], target_user_id, cat.id)
            if ok_comp and comp_rows and #comp_rows > 0 then
                local c = comp_rows[1]
                completion = {
                    total_questions = c.total_questions, answered_questions = c.answered_questions,
                    required_questions = c.required_questions, required_answered = c.required_answered,
                    completion_percent = c.completion_percent, status = c.status
                }
            end

            table.insert(result, {
                uuid = cat.uuid, name = cat.name, slug = cat.slug,
                description = cat.description, icon = cat.icon,
                display_order = cat.display_order, parent_id = cat.parent_id,
                questions = q_list, completion = completion
            })
        end

        return { status = 200, json = { schema = result, preview_user_uuid = target_uuid } }
    end)

    -- =====================================================================
    -- 3. CATEGORIES CRUD
    -- =====================================================================

    -- GET /categories — list
    app:get(PREFIX .. "/categories", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local namespace_id = getNamespaceId(self)
        local include_archived = self.params.include_archived == "true"
        local parent_id = self.params.parent_id

        local where_parts = {}
        local where_vals = {}

        if not include_archived then
            table.insert(where_parts, "is_archived = false")
        end
        if namespace_id then
            table.insert(where_parts, "namespace_id = ?")
            table.insert(where_vals, namespace_id)
        end
        if parent_id and parent_id ~= "" then
            if parent_id == "null" then
                table.insert(where_parts, "parent_id IS NULL")
            else
                table.insert(where_parts, "parent_id = ?")
                table.insert(where_vals, tonumber(parent_id))
            end
        end

        local where_clause = ""
        if #where_parts > 0 then
            where_clause = " WHERE " .. table.concat(where_parts, " AND ")
        end

        local sql = "SELECT * FROM profile_categories" .. where_clause .. " ORDER BY display_order ASC, name ASC"
        local ok, rows = pcall(db.query, sql, unpack(where_vals))
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] categories list failed: ", tostring(rows))
            return { status = 500, json = { error = "Failed to load categories" } }
        end

        return { status = 200, json = { categories = rows or {}, total = #(rows or {}) } }
    end)

    -- GET /categories/:uuid — get one with question_count
    app:get(PREFIX .. "/categories/:uuid", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local cat_uuid = self.params.uuid
        local ok, rows = pcall(db.query, "SELECT * FROM profile_categories WHERE uuid = ? LIMIT 1", cat_uuid)
        if not ok then
            return { status = 500, json = { error = "Failed to load category" } }
        end
        if not rows or #rows == 0 then
            return { status = 404, json = { error = "Category not found" } }
        end

        local cat = rows[1]
        local ok_cnt, cnt_rows = pcall(db.query, [[
            SELECT COUNT(*) AS cnt FROM profile_questions
            WHERE category_id = ? AND is_active = true AND is_archived = false
        ]], cat.id)
        cat.question_count = (ok_cnt and cnt_rows and cnt_rows[1]) and tonumber(cnt_rows[1].cnt) or 0

        return { status = 200, json = { category = cat } }
    end)

    -- POST /categories — create (admin only)
    app:post(PREFIX .. "/categories", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        if not params.name or params.name == "" then
            return { status = 400, json = { error = "name is required" } }
        end
        if not params.slug or params.slug == "" then
            return { status = 400, json = { error = "slug is required" } }
        end

        local namespace_id = getNamespaceId(self)
        local admin_uuid = admin.uuid or admin.id

        local ok, result = pcall(db.query, [[
            INSERT INTO profile_categories (uuid, namespace_id, name, slug, description, icon, display_order, parent_id, is_active, is_archived, visibility_rule_json, completion_rule_json, created_by, updated_by, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, ?, true, false, ?, ?, ?, ?, NOW(), NOW())
            RETURNING *
        ]],
            namespace_id,
            params.name,
            params.slug,
            params.description,
            params.icon,
            params.display_order or 0,
            params.parent_id,
            params.visibility_rule_json,
            params.completion_rule_json,
            admin_uuid,
            admin_uuid
        )
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] create category failed: ", tostring(result))
            return { status = 500, json = { error = "Failed to create category" } }
        end

        local cat = result and result[1] or nil
        if cat then
            auditLog({
                namespace_id = namespace_id,
                user_id = admin_uuid,
                action = "create",
                entity_type = "category",
                entity_uuid = cat.uuid,
                old_data_json = nil,
                new_data_json = cjson.encode(cat),
                ip_address = getClientIp()
            })
        end

        return { status = 201, json = { category = cat } }
    end)

    -- PUT /categories/:uuid — update (admin)
    app:put(PREFIX .. "/categories/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local cat_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_categories WHERE uuid = ? LIMIT 1", cat_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Category not found" } }
        end
        local old_cat = find_rows[1]

        local set_parts = {}
        local set_vals = {}
        local allowed = {"name", "slug", "description", "icon", "display_order", "parent_id", "is_active", "is_archived", "visibility_rule_json", "completion_rule_json"}
        for _, field in ipairs(allowed) do
            if params[field] ~= nil then
                table.insert(set_parts, db.escape_identifier(field) .. " = ?")
                table.insert(set_vals, params[field])
            end
        end

        if #set_parts == 0 then
            return { status = 400, json = { error = "No fields to update" } }
        end

        local admin_uuid = admin.uuid or admin.id
        table.insert(set_parts, "updated_by = ?")
        table.insert(set_vals, admin_uuid)
        table.insert(set_parts, "updated_at = NOW()")
        table.insert(set_vals, cat_uuid)

        local sql = "UPDATE profile_categories SET " .. table.concat(set_parts, ", ") .. " WHERE uuid = ? RETURNING *"
        local ok_upd, upd_result = pcall(db.query, sql, unpack(set_vals))
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] update category failed: ", tostring(upd_result))
            return { status = 500, json = { error = "Failed to update category" } }
        end

        local updated = upd_result and upd_result[1] or nil
        if updated then
            auditLog({
                namespace_id = old_cat.namespace_id,
                user_id = admin_uuid,
                action = "update",
                entity_type = "category",
                entity_uuid = cat_uuid,
                old_data_json = cjson.encode(old_cat),
                new_data_json = cjson.encode(updated),
                ip_address = getClientIp()
            })
        end

        return { status = 200, json = { category = updated } }
    end)

    -- DELETE /categories/:uuid — archive (admin)
    app:delete(PREFIX .. "/categories/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local cat_uuid = self.params.uuid
        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_categories WHERE uuid = ? LIMIT 1", cat_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Category not found" } }
        end

        local admin_uuid = admin.uuid or admin.id
        local ok_upd, upd_err = pcall(db.query, [[
            UPDATE profile_categories SET is_archived = true, updated_by = ?, updated_at = NOW()
            WHERE uuid = ?
        ]], admin_uuid, cat_uuid)
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] archive category failed: ", tostring(upd_err))
            return { status = 500, json = { error = "Failed to archive category" } }
        end

        auditLog({
            namespace_id = find_rows[1].namespace_id,
            user_id = admin_uuid,
            action = "archive",
            entity_type = "category",
            entity_uuid = cat_uuid,
            old_data_json = cjson.encode(find_rows[1]),
            new_data_json = nil,
            ip_address = getClientIp()
        })

        return { status = 200, json = { message = "Category archived", uuid = cat_uuid } }
    end)

    -- PUT /categories/reorder — bulk update display_order (admin)
    app:put(PREFIX .. "/categories/reorder", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        local items = params.items
        if not items or type(items) ~= "table" or #items == 0 then
            return { status = 400, json = { error = "items array is required with uuid and display_order" } }
        end

        local admin_uuid = admin.uuid or admin.id
        for _, item in ipairs(items) do
            if item.uuid and item.display_order ~= nil then
                local ok, err = pcall(db.query, [[
                    UPDATE profile_categories SET display_order = ?, updated_by = ?, updated_at = NOW()
                    WHERE uuid = ?
                ]], item.display_order, admin_uuid, item.uuid)
                if not ok then
                    ngx.log(ngx.ERR, "[ProfileBuilder] reorder category failed: ", tostring(err))
                end
            end
        end

        return { status = 200, json = { message = "Categories reordered", count = #items } }
    end)

    -- =====================================================================
    -- 4. QUESTIONS CRUD
    -- =====================================================================

    -- GET /questions — list
    app:get(PREFIX .. "/questions", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local where_parts = {"1=1"}
        local where_vals = {}
        local include_archived = self.params.include_archived == "true"
        local include_options = self.params.include_options == "true"
        local include_rules = self.params.include_rules == "true"

        if not include_archived then
            table.insert(where_parts, "pq.is_archived = false")
        end

        if self.params.category_id and self.params.category_id ~= "" then
            -- category_id param is a uuid, look up the actual id
            local ok_cat, cat_rows = pcall(db.query, "SELECT id FROM profile_categories WHERE uuid = ? LIMIT 1", self.params.category_id)
            if ok_cat and cat_rows and #cat_rows > 0 then
                table.insert(where_parts, "pq.category_id = ?")
                table.insert(where_vals, cat_rows[1].id)
            else
                return { status = 200, json = { questions = {}, total = 0 } }
            end
        end

        if self.params.question_type and self.params.question_type ~= "" then
            table.insert(where_parts, "pq.question_type = ?")
            table.insert(where_vals, self.params.question_type)
        end

        if self.params.is_active ~= nil and self.params.is_active ~= "" then
            table.insert(where_parts, "pq.is_active = ?")
            table.insert(where_vals, self.params.is_active == "true")
        end

        if self.params.touchpoint and self.params.touchpoint ~= "" then
            table.insert(where_parts, [[
                pq.id IN (
                    SELECT pqt.question_id FROM profile_question_touchpoints pqt
                    JOIN profile_touchpoints pt ON pt.id = pqt.touchpoint_id
                    WHERE pt.uuid = ?
                )
            ]])
            table.insert(where_vals, self.params.touchpoint)
        end

        local sql = "SELECT pq.* FROM profile_questions pq WHERE " .. table.concat(where_parts, " AND ") .. " ORDER BY pq.display_order ASC, pq.label ASC"
        local ok, rows = pcall(db.query, sql, unpack(where_vals))
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] questions list failed: ", tostring(rows))
            return { status = 500, json = { error = "Failed to load questions" } }
        end

        if include_options or include_rules then
            for _, q in ipairs(rows or {}) do
                if include_options then
                    local ok_opts, opts = pcall(db.query, [[
                        SELECT * FROM profile_question_options WHERE question_id = ? AND is_active = true ORDER BY display_order ASC
                    ]], q.id)
                    q.options = (ok_opts and opts) or {}
                end
                if include_rules then
                    local ok_rules, rules = pcall(db.query, [[
                        SELECT * FROM profile_question_rules WHERE question_id = ? AND is_active = true ORDER BY priority ASC
                    ]], q.id)
                    q.rules = (ok_rules and rules) or {}
                end
            end
        end

        return { status = 200, json = { questions = rows or {}, total = #(rows or {}) } }
    end)

    -- GET /questions/:uuid — get one with options + rules
    app:get(PREFIX .. "/questions/:uuid", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local q_uuid = self.params.uuid
        local ok, rows = pcall(db.query, "SELECT * FROM profile_questions WHERE uuid = ? LIMIT 1", q_uuid)
        if not ok or not rows or #rows == 0 then
            return { status = 404, json = { error = "Question not found" } }
        end

        local question = rows[1]

        local ok_opts, opts = pcall(db.query, [[
            SELECT * FROM profile_question_options WHERE question_id = ? AND is_active = true ORDER BY display_order ASC
        ]], question.id)
        question.options = (ok_opts and opts) or {}

        local ok_rules, rules = pcall(db.query, [[
            SELECT * FROM profile_question_rules WHERE question_id = ? AND is_active = true ORDER BY priority ASC
        ]], question.id)
        question.rules = (ok_rules and rules) or {}

        return { status = 200, json = { question = question } }
    end)

    -- POST /questions — create (admin)
    app:post(PREFIX .. "/questions", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)

        if not params.category_uuid or params.category_uuid == "" then
            return { status = 400, json = { error = "category_uuid is required" } }
        end
        if not params.question_key or params.question_key == "" then
            return { status = 400, json = { error = "question_key is required" } }
        end
        if not params.label or params.label == "" then
            return { status = 400, json = { error = "label is required" } }
        end
        if not params.question_type or params.question_type == "" then
            return { status = 400, json = { error = "question_type is required" } }
        end

        local ok_cat, cat_rows = pcall(db.query, "SELECT id, namespace_id FROM profile_categories WHERE uuid = ? LIMIT 1", params.category_uuid)
        if not ok_cat or not cat_rows or #cat_rows == 0 then
            return { status = 404, json = { error = "Category not found" } }
        end
        local category = cat_rows[1]

        local namespace_id = category.namespace_id or getNamespaceId(self)
        local admin_uuid = admin.uuid or admin.id

        local lookup_table_id = nil
        if params.lookup_table_uuid and params.lookup_table_uuid ~= "" then
            local ok_lt, lt_rows = pcall(db.query, "SELECT id FROM profile_lookup_tables WHERE uuid = ? LIMIT 1", params.lookup_table_uuid)
            if ok_lt and lt_rows and #lt_rows > 0 then
                lookup_table_id = lt_rows[1].id
            end
        end

        local ok_ins, ins_result = pcall(db.query, [[
            INSERT INTO profile_questions (uuid, namespace_id, category_id, question_key, label, description, help_text, placeholder, question_type, is_required, is_multi_value, is_editable_by_user, display_order, validation_json, default_value, config_json, lookup_table_id, version, is_active, is_archived, created_by, updated_by, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, true, false, ?, ?, NOW(), NOW())
            RETURNING *
        ]],
            namespace_id,
            category.id,
            params.question_key,
            params.label,
            params.description,
            params.help_text,
            params.placeholder,
            params.question_type,
            params.is_required or false,
            params.is_multi_value or false,
            params.is_editable_by_user ~= false,
            params.display_order or 0,
            params.validation_json,
            params.default_value,
            params.config_json,
            lookup_table_id,
            params.version or 1,
            admin_uuid,
            admin_uuid
        )
        if not ok_ins then
            ngx.log(ngx.ERR, "[ProfileBuilder] create question failed: ", tostring(ins_result))
            return { status = 500, json = { error = "Failed to create question" } }
        end

        local question = ins_result and ins_result[1] or nil
        if question then
            auditLog({
                namespace_id = namespace_id,
                user_id = admin_uuid,
                action = "create",
                entity_type = "question",
                entity_uuid = question.uuid,
                old_data_json = nil,
                new_data_json = cjson.encode(question),
                ip_address = getClientIp()
            })
        end

        return { status = 201, json = { question = question } }
    end)

    -- PUT /questions/:uuid — update (admin)
    app:put(PREFIX .. "/questions/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local q_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_questions WHERE uuid = ? LIMIT 1", q_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Question not found" } }
        end
        local old_q = find_rows[1]

        local set_parts = {}
        local set_vals = {}
        local allowed = {"question_key", "label", "description", "help_text", "placeholder", "question_type", "is_required", "is_multi_value", "is_editable_by_user", "display_order", "validation_json", "default_value", "config_json", "version", "is_active", "is_archived"}
        for _, field in ipairs(allowed) do
            if params[field] ~= nil then
                table.insert(set_parts, db.escape_identifier(field) .. " = ?")
                table.insert(set_vals, params[field])
            end
        end

        if params.category_uuid and params.category_uuid ~= "" then
            local ok_cat, cat_rows = pcall(db.query, "SELECT id FROM profile_categories WHERE uuid = ? LIMIT 1", params.category_uuid)
            if ok_cat and cat_rows and #cat_rows > 0 then
                table.insert(set_parts, "category_id = ?")
                table.insert(set_vals, cat_rows[1].id)
            end
        end

        if params.lookup_table_uuid ~= nil then
            if params.lookup_table_uuid == "" or params.lookup_table_uuid == cjson.null then
                table.insert(set_parts, "lookup_table_id = NULL")
            else
                local ok_lt, lt_rows = pcall(db.query, "SELECT id FROM profile_lookup_tables WHERE uuid = ? LIMIT 1", params.lookup_table_uuid)
                if ok_lt and lt_rows and #lt_rows > 0 then
                    table.insert(set_parts, "lookup_table_id = ?")
                    table.insert(set_vals, lt_rows[1].id)
                end
            end
        end

        if #set_parts == 0 then
            return { status = 400, json = { error = "No fields to update" } }
        end

        local admin_uuid = admin.uuid or admin.id
        table.insert(set_parts, "updated_by = ?")
        table.insert(set_vals, admin_uuid)
        table.insert(set_parts, "updated_at = NOW()")
        table.insert(set_vals, q_uuid)

        local sql = "UPDATE profile_questions SET " .. table.concat(set_parts, ", ") .. " WHERE uuid = ? RETURNING *"
        local ok_upd, upd_result = pcall(db.query, sql, unpack(set_vals))
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] update question failed: ", tostring(upd_result))
            return { status = 500, json = { error = "Failed to update question" } }
        end

        local updated = upd_result and upd_result[1] or nil
        if updated then
            auditLog({
                namespace_id = old_q.namespace_id,
                user_id = admin_uuid,
                action = "update",
                entity_type = "question",
                entity_uuid = q_uuid,
                old_data_json = cjson.encode(old_q),
                new_data_json = cjson.encode(updated),
                ip_address = getClientIp()
            })
        end

        return { status = 200, json = { question = updated } }
    end)

    -- DELETE /questions/:uuid — archive (admin)
    app:delete(PREFIX .. "/questions/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local q_uuid = self.params.uuid
        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_questions WHERE uuid = ? LIMIT 1", q_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Question not found" } }
        end

        local admin_uuid = admin.uuid or admin.id
        local ok_upd, upd_err = pcall(db.query, [[
            UPDATE profile_questions SET is_archived = true, updated_by = ?, updated_at = NOW()
            WHERE uuid = ?
        ]], admin_uuid, q_uuid)
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] archive question failed: ", tostring(upd_err))
            return { status = 500, json = { error = "Failed to archive question" } }
        end

        auditLog({
            namespace_id = find_rows[1].namespace_id,
            user_id = admin_uuid,
            action = "archive",
            entity_type = "question",
            entity_uuid = q_uuid,
            old_data_json = cjson.encode(find_rows[1]),
            new_data_json = nil,
            ip_address = getClientIp()
        })

        return { status = 200, json = { message = "Question archived", uuid = q_uuid } }
    end)

    -- PUT /questions/reorder — bulk reorder (admin)
    app:put(PREFIX .. "/questions/reorder", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        local items = params.items
        if not items or type(items) ~= "table" or #items == 0 then
            return { status = 400, json = { error = "items array is required with uuid and display_order" } }
        end

        local admin_uuid = admin.uuid or admin.id
        for _, item in ipairs(items) do
            if item.uuid and item.display_order ~= nil then
                local ok, err = pcall(db.query, [[
                    UPDATE profile_questions SET display_order = ?, updated_by = ?, updated_at = NOW()
                    WHERE uuid = ?
                ]], item.display_order, admin_uuid, item.uuid)
                if not ok then
                    ngx.log(ngx.ERR, "[ProfileBuilder] reorder question failed: ", tostring(err))
                end
            end
        end

        return { status = 200, json = { message = "Questions reordered", count = #items } }
    end)

    -- =====================================================================
    -- 5. QUESTION OPTIONS
    -- =====================================================================

    -- GET /questions/:uuid/options
    app:get(PREFIX .. "/questions/:uuid/options", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local q_uuid = self.params.uuid
        local ok_q, q_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", q_uuid)
        if not ok_q or not q_rows or #q_rows == 0 then
            return { status = 404, json = { error = "Question not found" } }
        end

        local ok, rows = pcall(db.query, [[
            SELECT * FROM profile_question_options WHERE question_id = ? ORDER BY display_order ASC, label ASC
        ]], q_rows[1].id)
        if not ok then
            return { status = 500, json = { error = "Failed to load options" } }
        end

        return { status = 200, json = { options = rows or {}, total = #(rows or {}) } }
    end)

    -- POST /questions/:uuid/options (admin)
    app:post(PREFIX .. "/questions/:uuid/options", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local q_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_q, q_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", q_uuid)
        if not ok_q or not q_rows or #q_rows == 0 then
            return { status = 404, json = { error = "Question not found" } }
        end
        local question_id = q_rows[1].id

        if not params.label or params.label == "" then
            return { status = 400, json = { error = "label is required" } }
        end
        if not params.value or params.value == "" then
            return { status = 400, json = { error = "value is required" } }
        end

        local parent_option_id = nil
        if params.parent_option_uuid and params.parent_option_uuid ~= "" then
            local ok_po, po_rows = pcall(db.query, "SELECT id FROM profile_question_options WHERE uuid = ? LIMIT 1", params.parent_option_uuid)
            if ok_po and po_rows and #po_rows > 0 then
                parent_option_id = po_rows[1].id
            end
        end

        local ok_ins, ins_result = pcall(db.query, [[
            INSERT INTO profile_question_options (uuid, question_id, label, value, description, display_order, is_default, is_active, parent_option_id, metadata_json, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, true, ?, ?, NOW(), NOW())
            RETURNING *
        ]],
            question_id,
            params.label,
            params.value,
            params.description,
            params.display_order or 0,
            params.is_default or false,
            parent_option_id,
            params.metadata_json
        )
        if not ok_ins then
            ngx.log(ngx.ERR, "[ProfileBuilder] create option failed: ", tostring(ins_result))
            return { status = 500, json = { error = "Failed to create option" } }
        end

        return { status = 201, json = { option = ins_result and ins_result[1] or nil } }
    end)

    -- PUT /questions/:questionUuid/options/:optionUuid (admin)
    app:put(PREFIX .. "/questions/:questionUuid/options/:optionUuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local option_uuid = self.params.optionUuid
        local params = parseJsonBody(self)

        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_question_options WHERE uuid = ? LIMIT 1", option_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Option not found" } }
        end

        local set_parts = {}
        local set_vals = {}
        local allowed = {"label", "value", "description", "display_order", "is_default", "is_active", "metadata_json"}
        for _, field in ipairs(allowed) do
            if params[field] ~= nil then
                table.insert(set_parts, db.escape_identifier(field) .. " = ?")
                table.insert(set_vals, params[field])
            end
        end

        if params.parent_option_uuid ~= nil then
            if params.parent_option_uuid == "" or params.parent_option_uuid == cjson.null then
                table.insert(set_parts, "parent_option_id = NULL")
            else
                local ok_po, po_rows = pcall(db.query, "SELECT id FROM profile_question_options WHERE uuid = ? LIMIT 1", params.parent_option_uuid)
                if ok_po and po_rows and #po_rows > 0 then
                    table.insert(set_parts, "parent_option_id = ?")
                    table.insert(set_vals, po_rows[1].id)
                end
            end
        end

        if #set_parts == 0 then
            return { status = 400, json = { error = "No fields to update" } }
        end

        table.insert(set_parts, "updated_at = NOW()")
        table.insert(set_vals, option_uuid)

        local sql = "UPDATE profile_question_options SET " .. table.concat(set_parts, ", ") .. " WHERE uuid = ? RETURNING *"
        local ok_upd, upd_result = pcall(db.query, sql, unpack(set_vals))
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] update option failed: ", tostring(upd_result))
            return { status = 500, json = { error = "Failed to update option" } }
        end

        return { status = 200, json = { option = upd_result and upd_result[1] or nil } }
    end)

    -- DELETE /questions/:questionUuid/options/:optionUuid (admin)
    app:delete(PREFIX .. "/questions/:questionUuid/options/:optionUuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local option_uuid = self.params.optionUuid
        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_question_options WHERE uuid = ? LIMIT 1", option_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Option not found" } }
        end

        local ok_del, del_err = pcall(db.query, [[
            UPDATE profile_question_options SET is_active = false, updated_at = NOW() WHERE uuid = ?
        ]], option_uuid)
        if not ok_del then
            ngx.log(ngx.ERR, "[ProfileBuilder] delete option failed: ", tostring(del_err))
            return { status = 500, json = { error = "Failed to delete option" } }
        end

        return { status = 200, json = { message = "Option deactivated", uuid = option_uuid } }
    end)

    -- PUT /questions/:uuid/options/reorder (admin)
    app:put(PREFIX .. "/questions/:uuid/options/reorder", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        local items = params.items
        if not items or type(items) ~= "table" or #items == 0 then
            return { status = 400, json = { error = "items array is required with uuid and display_order" } }
        end

        for _, item in ipairs(items) do
            if item.uuid and item.display_order ~= nil then
                local ok, err = pcall(db.query, [[
                    UPDATE profile_question_options SET display_order = ?, updated_at = NOW() WHERE uuid = ?
                ]], item.display_order, item.uuid)
                if not ok then
                    ngx.log(ngx.ERR, "[ProfileBuilder] reorder option failed: ", tostring(err))
                end
            end
        end

        return { status = 200, json = { message = "Options reordered", count = #items } }
    end)

    -- =====================================================================
    -- 6. RULES
    -- =====================================================================

    -- GET /rules
    app:get(PREFIX .. "/rules", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local where_parts = {"1=1"}
        local where_vals = {}

        if self.params.question_uuid and self.params.question_uuid ~= "" then
            local ok_q, q_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", self.params.question_uuid)
            if ok_q and q_rows and #q_rows > 0 then
                table.insert(where_parts, "pqr.question_id = ?")
                table.insert(where_vals, q_rows[1].id)
            else
                return { status = 200, json = { rules = {}, total = 0 } }
            end
        end

        if self.params.rule_type and self.params.rule_type ~= "" then
            table.insert(where_parts, "pqr.rule_type = ?")
            table.insert(where_vals, self.params.rule_type)
        end

        if self.params.is_active ~= nil and self.params.is_active ~= "" then
            table.insert(where_parts, "pqr.is_active = ?")
            table.insert(where_vals, self.params.is_active == "true")
        end

        local sql = "SELECT pqr.* FROM profile_question_rules pqr WHERE " .. table.concat(where_parts, " AND ") .. " ORDER BY pqr.priority ASC"
        local ok, rows = pcall(db.query, sql, unpack(where_vals))
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] rules list failed: ", tostring(rows))
            return { status = 500, json = { error = "Failed to load rules" } }
        end

        return { status = 200, json = { rules = rows or {}, total = #(rows or {}) } }
    end)

    -- POST /rules (admin)
    app:post(PREFIX .. "/rules", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)

        if not params.question_uuid or params.question_uuid == "" then
            return { status = 400, json = { error = "question_uuid is required" } }
        end
        if not params.rule_name or params.rule_name == "" then
            return { status = 400, json = { error = "rule_name is required" } }
        end
        if not params.rule_type or params.rule_type == "" then
            return { status = 400, json = { error = "rule_type is required" } }
        end

        local ok_q, q_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", params.question_uuid)
        if not ok_q or not q_rows or #q_rows == 0 then
            return { status = 404, json = { error = "Question not found" } }
        end
        local question_id = q_rows[1].id

        local source_question_id = nil
        if params.source_question_uuid and params.source_question_uuid ~= "" then
            local ok_sq, sq_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", params.source_question_uuid)
            if ok_sq and sq_rows and #sq_rows > 0 then
                source_question_id = sq_rows[1].id
            end
        end

        local admin_uuid = admin.uuid or admin.id

        local ok_ins, ins_result = pcall(db.query, [[
            INSERT INTO profile_question_rules (uuid, question_id, rule_name, rule_type, operator, logic_group, source_question_id, source_field, expected_value, expected_values_json, priority, is_active, created_by, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, true, ?, NOW(), NOW())
            RETURNING *
        ]],
            question_id,
            params.rule_name,
            params.rule_type,
            params.operator,
            params.logic_group,
            source_question_id,
            params.source_field,
            params.expected_value,
            params.expected_values_json,
            params.priority or 0,
            admin_uuid
        )
        if not ok_ins then
            ngx.log(ngx.ERR, "[ProfileBuilder] create rule failed: ", tostring(ins_result))
            return { status = 500, json = { error = "Failed to create rule" } }
        end

        return { status = 201, json = { rule = ins_result and ins_result[1] or nil } }
    end)

    -- PUT /rules/:uuid (admin)
    app:put(PREFIX .. "/rules/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local rule_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_question_rules WHERE uuid = ? LIMIT 1", rule_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Rule not found" } }
        end

        local set_parts = {}
        local set_vals = {}
        local allowed = {"rule_name", "rule_type", "operator", "logic_group", "source_field", "expected_value", "expected_values_json", "priority", "is_active"}
        for _, field in ipairs(allowed) do
            if params[field] ~= nil then
                table.insert(set_parts, db.escape_identifier(field) .. " = ?")
                table.insert(set_vals, params[field])
            end
        end

        if params.source_question_uuid ~= nil then
            if params.source_question_uuid == "" or params.source_question_uuid == cjson.null then
                table.insert(set_parts, "source_question_id = NULL")
            else
                local ok_sq, sq_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", params.source_question_uuid)
                if ok_sq and sq_rows and #sq_rows > 0 then
                    table.insert(set_parts, "source_question_id = ?")
                    table.insert(set_vals, sq_rows[1].id)
                end
            end
        end

        if #set_parts == 0 then
            return { status = 400, json = { error = "No fields to update" } }
        end

        table.insert(set_parts, "updated_at = NOW()")
        table.insert(set_vals, rule_uuid)

        local sql = "UPDATE profile_question_rules SET " .. table.concat(set_parts, ", ") .. " WHERE uuid = ? RETURNING *"
        local ok_upd, upd_result = pcall(db.query, sql, unpack(set_vals))
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] update rule failed: ", tostring(upd_result))
            return { status = 500, json = { error = "Failed to update rule" } }
        end

        return { status = 200, json = { rule = upd_result and upd_result[1] or nil } }
    end)

    -- DELETE /rules/:uuid (admin)
    app:delete(PREFIX .. "/rules/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local rule_uuid = self.params.uuid
        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_question_rules WHERE uuid = ? LIMIT 1", rule_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Rule not found" } }
        end

        local ok_del, del_err = pcall(db.query, "UPDATE profile_question_rules SET is_active = false, updated_at = NOW() WHERE uuid = ?", rule_uuid)
        if not ok_del then
            ngx.log(ngx.ERR, "[ProfileBuilder] delete rule failed: ", tostring(del_err))
            return { status = 500, json = { error = "Failed to delete rule" } }
        end

        return { status = 200, json = { message = "Rule deactivated", uuid = rule_uuid } }
    end)

    -- =====================================================================
    -- 7. ANSWERS (end-user)
    -- =====================================================================

    -- GET /answers — user's current answers
    app:get(PREFIX .. "/answers", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_uuid = user.uuid or user.id
        local user_id = getUserIdByUuid(user_uuid)
        if not user_id then
            return { status = 200, json = { answers = {}, total = 0 } }
        end

        local category_slug = self.params.category_slug

        local sql
        local vals = {user_id}
        if category_slug and category_slug ~= "" then
            sql = [[
                SELECT upa.*, pq.question_key, pq.label AS question_label, pq.uuid AS question_uuid,
                       pc.slug AS category_slug, pc.name AS category_name
                FROM user_profile_answers upa
                JOIN profile_questions pq ON pq.id = upa.question_id
                JOIN profile_categories pc ON pc.id = pq.category_id
                WHERE upa.user_id = ? AND pc.slug = ?
                ORDER BY pq.display_order ASC
            ]]
            table.insert(vals, category_slug)
        else
            sql = [[
                SELECT upa.*, pq.question_key, pq.label AS question_label, pq.uuid AS question_uuid
                FROM user_profile_answers upa
                JOIN profile_questions pq ON pq.id = upa.question_id
                WHERE upa.user_id = ?
                ORDER BY pq.display_order ASC
            ]]
        end

        local ok, rows = pcall(db.query, sql, unpack(vals))
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] answers list failed: ", tostring(rows))
            return { status = 500, json = { error = "Failed to load answers" } }
        end

        return { status = 200, json = { answers = rows or {}, total = #(rows or {}) } }
    end)

    -- POST /answers — save answers (upsert)
    app:post(PREFIX .. "/answers", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_uuid = user.uuid or user.id
        local user_id = getUserIdByUuid(user_uuid)
        if not user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        local params = parseJsonBody(self)
        local answers = params.answers
        if not answers or type(answers) ~= "table" or #answers == 0 then
            return { status = 400, json = { error = "answers array is required" } }
        end

        local namespace_id = getNamespaceId(self)
        local saved = 0
        local errors = {}
        local affected_category_ids = {}

        for i, ans in ipairs(answers) do
            if not ans.question_uuid or ans.question_uuid == "" then
                table.insert(errors, { index = i, error = "question_uuid is required" })
            else
                local ok_q, q_rows = pcall(db.query, "SELECT id, version, category_id FROM profile_questions WHERE uuid = ? AND is_active = true LIMIT 1", ans.question_uuid)
                if not ok_q or not q_rows or #q_rows == 0 then
                    table.insert(errors, { index = i, error = "Question not found: " .. ans.question_uuid })
                else
                    local question = q_rows[1]
                    affected_category_ids[question.category_id] = true

                    -- Get existing answer for history
                    local old_answer = nil
                    local ok_old, old_rows = pcall(db.query, [[
                        SELECT * FROM user_profile_answers WHERE user_id = ? AND question_id = ? LIMIT 1
                    ]], user_id, question.id)
                    if ok_old and old_rows and #old_rows > 0 then
                        old_answer = old_rows[1]
                    end

                    local ok_upsert, upsert_err = pcall(db.query, [[
                        INSERT INTO user_profile_answers (uuid, user_id, user_uuid, namespace_id, question_id, question_version, answer_text, answer_number, answer_boolean, answer_date, answer_json, answer_file_url, is_draft, answered_at, updated_at)
                        VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
                        ON CONFLICT (user_id, question_id) DO UPDATE SET
                            question_version = EXCLUDED.question_version,
                            answer_text = EXCLUDED.answer_text,
                            answer_number = EXCLUDED.answer_number,
                            answer_boolean = EXCLUDED.answer_boolean,
                            answer_date = EXCLUDED.answer_date,
                            answer_json = EXCLUDED.answer_json,
                            answer_file_url = EXCLUDED.answer_file_url,
                            is_draft = EXCLUDED.is_draft,
                            answered_at = NOW(),
                            updated_at = NOW()
                    ]],
                        user_id,
                        user_uuid,
                        namespace_id,
                        question.id,
                        question.version,
                        ans.answer_text,
                        ans.answer_number,
                        ans.answer_boolean,
                        ans.answer_date,
                        ans.answer_json,
                        ans.answer_file_url,
                        ans.is_draft or false
                    )

                    if not ok_upsert then
                        ngx.log(ngx.ERR, "[ProfileBuilder] upsert answer failed: ", tostring(upsert_err))
                        table.insert(errors, { index = i, error = "Failed to save answer for " .. ans.question_uuid })
                    else
                        saved = saved + 1

                        -- Insert history record
                        if old_answer then
                            pcall(db.query, [[
                                INSERT INTO user_profile_answer_history (uuid, answer_id, user_id, question_id, question_version, old_answer_text, old_answer_number, old_answer_boolean, old_answer_date, old_answer_json, new_answer_text, new_answer_number, new_answer_boolean, new_answer_date, new_answer_json, changed_by, change_source, change_reason, created_at)
                                VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
                            ]],
                                old_answer.id,
                                user_id,
                                question.id,
                                question.version,
                                old_answer.answer_text,
                                old_answer.answer_number,
                                old_answer.answer_boolean,
                                old_answer.answer_date,
                                old_answer.answer_json,
                                ans.answer_text,
                                ans.answer_number,
                                ans.answer_boolean,
                                ans.answer_date,
                                ans.answer_json,
                                user_uuid,
                                "user",
                                ans.change_reason
                            )
                        end
                    end
                end
            end
        end

        -- Recalculate completion for affected categories
        for category_id, _ in pairs(affected_category_ids) do
            recalculateCompletion(user_id, user_uuid, category_id)
        end

        local response = { message = "Answers saved", saved = saved, total = #answers }
        if #errors > 0 then
            response.errors = errors
        end

        return { status = 200, json = response }
    end)

    -- POST /answers/validate — validate without saving
    app:post(PREFIX .. "/answers/validate", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        local answers = params.answers
        if not answers or type(answers) ~= "table" or #answers == 0 then
            return { status = 400, json = { error = "answers array is required" } }
        end

        local results = {}
        for i, ans in ipairs(answers) do
            local result = { index = i, question_uuid = ans.question_uuid, valid = true, errors = {} }

            if not ans.question_uuid or ans.question_uuid == "" then
                result.valid = false
                table.insert(result.errors, "question_uuid is required")
            else
                local ok_q, q_rows = pcall(db.query, [[
                    SELECT * FROM profile_questions WHERE uuid = ? AND is_active = true LIMIT 1
                ]], ans.question_uuid)
                if not ok_q or not q_rows or #q_rows == 0 then
                    result.valid = false
                    table.insert(result.errors, "Question not found")
                else
                    local q = q_rows[1]

                    -- Check required
                    if q.is_required then
                        local has_value = (ans.answer_text and ans.answer_text ~= "") or
                            ans.answer_number ~= nil or
                            ans.answer_boolean ~= nil or
                            (ans.answer_date and ans.answer_date ~= "") or
                            (ans.answer_json and ans.answer_json ~= "")
                        if not has_value then
                            result.valid = false
                            table.insert(result.errors, "This field is required")
                        end
                    end

                    -- Check validation_json rules if present
                    if q.validation_json and q.validation_json ~= "" then
                        local ok_parse, validation = pcall(cjson.decode, q.validation_json)
                        if ok_parse and validation then
                            if validation.min_length and ans.answer_text then
                                if #ans.answer_text < validation.min_length then
                                    result.valid = false
                                    table.insert(result.errors, "Minimum length is " .. validation.min_length)
                                end
                            end
                            if validation.max_length and ans.answer_text then
                                if #ans.answer_text > validation.max_length then
                                    result.valid = false
                                    table.insert(result.errors, "Maximum length is " .. validation.max_length)
                                end
                            end
                            if validation.min and ans.answer_number then
                                if tonumber(ans.answer_number) < validation.min then
                                    result.valid = false
                                    table.insert(result.errors, "Minimum value is " .. validation.min)
                                end
                            end
                            if validation.max and ans.answer_number then
                                if tonumber(ans.answer_number) > validation.max then
                                    result.valid = false
                                    table.insert(result.errors, "Maximum value is " .. validation.max)
                                end
                            end
                            if validation.pattern and ans.answer_text then
                                if not ans.answer_text:match(validation.pattern) then
                                    result.valid = false
                                    table.insert(result.errors, validation.pattern_message or "Invalid format")
                                end
                            end
                        end
                    end
                end
            end

            table.insert(results, result)
        end

        local all_valid = true
        for _, r in ipairs(results) do
            if not r.valid then
                all_valid = false
                break
            end
        end

        return { status = 200, json = { valid = all_valid, results = results } }
    end)

    -- GET /answers/history — user's answer change history
    app:get(PREFIX .. "/answers/history", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_uuid = user.uuid or user.id
        local user_id = getUserIdByUuid(user_uuid)
        if not user_id then
            return { status = 200, json = { history = {}, total = 0 } }
        end

        local page = tonumber(self.params.page) or 1
        local per_page = tonumber(self.params.per_page) or 50
        if per_page > 100 then per_page = 100 end
        local offset = (page - 1) * per_page

        local ok_cnt, cnt_rows = pcall(db.query, [[
            SELECT COUNT(*) AS cnt FROM user_profile_answer_history WHERE user_id = ?
        ]], user_id)
        local total = (ok_cnt and cnt_rows and cnt_rows[1]) and tonumber(cnt_rows[1].cnt) or 0

        local ok, rows = pcall(db.query, [[
            SELECT upah.*, pq.question_key, pq.label AS question_label, pq.uuid AS question_uuid
            FROM user_profile_answer_history upah
            JOIN profile_questions pq ON pq.id = upah.question_id
            WHERE upah.user_id = ?
            ORDER BY upah.created_at DESC
            LIMIT ? OFFSET ?
        ]], user_id, per_page, offset)
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] answer history failed: ", tostring(rows))
            return { status = 500, json = { error = "Failed to load answer history" } }
        end

        return { status = 200, json = { history = rows or {}, total = total, page = page, per_page = per_page } }
    end)

    -- =====================================================================
    -- 8. TAGS
    -- =====================================================================

    -- GET /tags
    app:get(PREFIX .. "/tags", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local namespace_id = getNamespaceId(self)
        local where_clause = "is_active = true"
        local vals = {}
        if namespace_id then
            where_clause = where_clause .. " AND namespace_id = ?"
            table.insert(vals, namespace_id)
        end

        local ok, rows = pcall(db.query, "SELECT * FROM profile_tags WHERE " .. where_clause .. " ORDER BY name ASC", unpack(vals))
        if not ok then
            return { status = 500, json = { error = "Failed to load tags" } }
        end

        return { status = 200, json = { tags = rows or {}, total = #(rows or {}) } }
    end)

    -- POST /tags (admin)
    app:post(PREFIX .. "/tags", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        if not params.name or params.name == "" then
            return { status = 400, json = { error = "name is required" } }
        end
        if not params.slug or params.slug == "" then
            return { status = 400, json = { error = "slug is required" } }
        end

        local namespace_id = getNamespaceId(self)
        local admin_uuid = admin.uuid or admin.id

        local ok, result = pcall(db.query, [[
            INSERT INTO profile_tags (uuid, namespace_id, name, slug, description, color, tag_type, is_active, created_by, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, true, ?, NOW(), NOW())
            RETURNING *
        ]],
            namespace_id,
            params.name,
            params.slug,
            params.description,
            params.color,
            params.tag_type,
            admin_uuid
        )
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] create tag failed: ", tostring(result))
            return { status = 500, json = { error = "Failed to create tag" } }
        end

        return { status = 201, json = { tag = result and result[1] or nil } }
    end)

    -- PUT /tags/:uuid (admin)
    app:put(PREFIX .. "/tags/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local tag_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_tags WHERE uuid = ? LIMIT 1", tag_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Tag not found" } }
        end

        local set_parts = {}
        local set_vals = {}
        local allowed = {"name", "slug", "description", "color", "tag_type", "is_active"}
        for _, field in ipairs(allowed) do
            if params[field] ~= nil then
                table.insert(set_parts, db.escape_identifier(field) .. " = ?")
                table.insert(set_vals, params[field])
            end
        end

        if #set_parts == 0 then
            return { status = 400, json = { error = "No fields to update" } }
        end

        table.insert(set_parts, "updated_at = NOW()")
        table.insert(set_vals, tag_uuid)

        local sql = "UPDATE profile_tags SET " .. table.concat(set_parts, ", ") .. " WHERE uuid = ? RETURNING *"
        local ok_upd, upd_result = pcall(db.query, sql, unpack(set_vals))
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] update tag failed: ", tostring(upd_result))
            return { status = 500, json = { error = "Failed to update tag" } }
        end

        return { status = 200, json = { tag = upd_result and upd_result[1] or nil } }
    end)

    -- DELETE /tags/:uuid (admin)
    app:delete(PREFIX .. "/tags/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local tag_uuid = self.params.uuid
        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_tags WHERE uuid = ? LIMIT 1", tag_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Tag not found" } }
        end

        local ok_del, del_err = pcall(db.query, "UPDATE profile_tags SET is_active = false, updated_at = NOW() WHERE uuid = ?", tag_uuid)
        if not ok_del then
            return { status = 500, json = { error = "Failed to delete tag" } }
        end

        return { status = 200, json = { message = "Tag deactivated", uuid = tag_uuid } }
    end)

    -- POST /tags/:uuid/assign — assign tag to user (admin)
    app:post(PREFIX .. "/tags/:uuid/assign", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local tag_uuid = self.params.uuid
        local params = parseJsonBody(self)

        if not params.user_uuid or params.user_uuid == "" then
            return { status = 400, json = { error = "user_uuid is required" } }
        end

        local ok_tag, tag_rows = pcall(db.query, "SELECT id FROM profile_tags WHERE uuid = ? AND is_active = true LIMIT 1", tag_uuid)
        if not ok_tag or not tag_rows or #tag_rows == 0 then
            return { status = 404, json = { error = "Tag not found" } }
        end
        local tag_id = tag_rows[1].id

        local target_user_id = getUserIdByUuid(params.user_uuid)
        if not target_user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        local admin_uuid = admin.uuid or admin.id

        local ok_ins, ins_result = pcall(db.query, [[
            INSERT INTO user_profile_tags (uuid, user_id, user_uuid, tag_id, assigned_by, assignment_source, assignment_reason, is_active, created_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, true, NOW())
            ON CONFLICT (user_id, tag_id) DO UPDATE SET
                is_active = true,
                assigned_by = EXCLUDED.assigned_by,
                assignment_source = EXCLUDED.assignment_source,
                assignment_reason = EXCLUDED.assignment_reason,
                created_at = NOW()
            RETURNING *
        ]],
            target_user_id,
            params.user_uuid,
            tag_id,
            admin_uuid,
            params.assignment_source or "admin",
            params.assignment_reason
        )
        if not ok_ins then
            ngx.log(ngx.ERR, "[ProfileBuilder] assign tag failed: ", tostring(ins_result))
            return { status = 500, json = { error = "Failed to assign tag" } }
        end

        return { status = 201, json = { assignment = ins_result and ins_result[1] or nil } }
    end)

    -- DELETE /tags/:uuid/users/:userUuid — remove tag from user (admin)
    app:delete(PREFIX .. "/tags/:uuid/users/:userUuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local tag_uuid = self.params.uuid
        local target_user_uuid = self.params.userUuid

        local ok_tag, tag_rows = pcall(db.query, "SELECT id FROM profile_tags WHERE uuid = ? LIMIT 1", tag_uuid)
        if not ok_tag or not tag_rows or #tag_rows == 0 then
            return { status = 404, json = { error = "Tag not found" } }
        end

        local target_user_id = getUserIdByUuid(target_user_uuid)
        if not target_user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        local ok_del, del_err = pcall(db.query, [[
            UPDATE user_profile_tags SET is_active = false
            WHERE user_id = ? AND tag_id = ?
        ]], target_user_id, tag_rows[1].id)
        if not ok_del then
            return { status = 500, json = { error = "Failed to remove tag" } }
        end

        return { status = 200, json = { message = "Tag removed from user" } }
    end)

    -- =====================================================================
    -- 9. TAG RULES
    -- =====================================================================

    -- GET /tag-rules
    app:get(PREFIX .. "/tag-rules", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local ok, rows = pcall(db.query, [[
            SELECT ptr.*, pt.name AS tag_name, pt.slug AS tag_slug
            FROM profile_tag_rules ptr
            JOIN profile_tags pt ON pt.id = ptr.tag_id
            WHERE ptr.is_active = true
            ORDER BY ptr.priority ASC
        ]])
        if not ok then
            return { status = 500, json = { error = "Failed to load tag rules" } }
        end

        return { status = 200, json = { tag_rules = rows or {}, total = #(rows or {}) } }
    end)

    -- POST /tag-rules (admin)
    app:post(PREFIX .. "/tag-rules", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)

        if not params.tag_uuid or params.tag_uuid == "" then
            return { status = 400, json = { error = "tag_uuid is required" } }
        end
        if not params.rule_name or params.rule_name == "" then
            return { status = 400, json = { error = "rule_name is required" } }
        end

        local ok_tag, tag_rows = pcall(db.query, "SELECT id FROM profile_tags WHERE uuid = ? LIMIT 1", params.tag_uuid)
        if not ok_tag or not tag_rows or #tag_rows == 0 then
            return { status = 404, json = { error = "Tag not found" } }
        end

        local source_question_id = nil
        if params.source_question_uuid and params.source_question_uuid ~= "" then
            local ok_sq, sq_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", params.source_question_uuid)
            if ok_sq and sq_rows and #sq_rows > 0 then
                source_question_id = sq_rows[1].id
            end
        end

        local admin_uuid = admin.uuid or admin.id

        local ok_ins, ins_result = pcall(db.query, [[
            INSERT INTO profile_tag_rules (uuid, tag_id, rule_name, description, source_question_id, source_field, operator, expected_value, expected_values_json, logic_group, priority, is_active, created_by, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, true, ?, NOW(), NOW())
            RETURNING *
        ]],
            tag_rows[1].id,
            params.rule_name,
            params.description,
            source_question_id,
            params.source_field,
            params.operator,
            params.expected_value,
            params.expected_values_json,
            params.logic_group,
            params.priority or 0,
            admin_uuid
        )
        if not ok_ins then
            ngx.log(ngx.ERR, "[ProfileBuilder] create tag rule failed: ", tostring(ins_result))
            return { status = 500, json = { error = "Failed to create tag rule" } }
        end

        return { status = 201, json = { tag_rule = ins_result and ins_result[1] or nil } }
    end)

    -- PUT /tag-rules/:uuid (admin)
    app:put(PREFIX .. "/tag-rules/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local rule_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_tag_rules WHERE uuid = ? LIMIT 1", rule_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Tag rule not found" } }
        end

        local set_parts = {}
        local set_vals = {}
        local allowed = {"rule_name", "description", "source_field", "operator", "expected_value", "expected_values_json", "logic_group", "priority", "is_active"}
        for _, field in ipairs(allowed) do
            if params[field] ~= nil then
                table.insert(set_parts, db.escape_identifier(field) .. " = ?")
                table.insert(set_vals, params[field])
            end
        end

        if params.source_question_uuid ~= nil then
            if params.source_question_uuid == "" or params.source_question_uuid == cjson.null then
                table.insert(set_parts, "source_question_id = NULL")
            else
                local ok_sq, sq_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", params.source_question_uuid)
                if ok_sq and sq_rows and #sq_rows > 0 then
                    table.insert(set_parts, "source_question_id = ?")
                    table.insert(set_vals, sq_rows[1].id)
                end
            end
        end

        if #set_parts == 0 then
            return { status = 400, json = { error = "No fields to update" } }
        end

        table.insert(set_parts, "updated_at = NOW()")
        table.insert(set_vals, rule_uuid)

        local sql = "UPDATE profile_tag_rules SET " .. table.concat(set_parts, ", ") .. " WHERE uuid = ? RETURNING *"
        local ok_upd, upd_result = pcall(db.query, sql, unpack(set_vals))
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] update tag rule failed: ", tostring(upd_result))
            return { status = 500, json = { error = "Failed to update tag rule" } }
        end

        return { status = 200, json = { tag_rule = upd_result and upd_result[1] or nil } }
    end)

    -- DELETE /tag-rules/:uuid (admin)
    app:delete(PREFIX .. "/tag-rules/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local rule_uuid = self.params.uuid
        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_tag_rules WHERE uuid = ? LIMIT 1", rule_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Tag rule not found" } }
        end

        local ok_del, del_err = pcall(db.query, "UPDATE profile_tag_rules SET is_active = false, updated_at = NOW() WHERE uuid = ?", rule_uuid)
        if not ok_del then
            return { status = 500, json = { error = "Failed to delete tag rule" } }
        end

        return { status = 200, json = { message = "Tag rule deactivated", uuid = rule_uuid } }
    end)

    -- =====================================================================
    -- 10. LOOKUP TABLES
    -- =====================================================================

    -- GET /lookup-tables
    app:get(PREFIX .. "/lookup-tables", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local namespace_id = getNamespaceId(self)
        local where_clause = "is_active = true"
        local vals = {}
        if namespace_id then
            where_clause = where_clause .. " AND namespace_id = ?"
            table.insert(vals, namespace_id)
        end

        local ok, rows = pcall(db.query, "SELECT * FROM profile_lookup_tables WHERE " .. where_clause .. " ORDER BY name ASC", unpack(vals))
        if not ok then
            return { status = 500, json = { error = "Failed to load lookup tables" } }
        end

        return { status = 200, json = { lookup_tables = rows or {}, total = #(rows or {}) } }
    end)

    -- POST /lookup-tables (admin)
    app:post(PREFIX .. "/lookup-tables", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        if not params.name or params.name == "" then
            return { status = 400, json = { error = "name is required" } }
        end
        if not params.slug or params.slug == "" then
            return { status = 400, json = { error = "slug is required" } }
        end

        local namespace_id = getNamespaceId(self)

        local ok, result = pcall(db.query, [[
            INSERT INTO profile_lookup_tables (uuid, namespace_id, name, slug, description, is_active, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, true, NOW(), NOW())
            RETURNING *
        ]],
            namespace_id,
            params.name,
            params.slug,
            params.description
        )
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] create lookup table failed: ", tostring(result))
            return { status = 500, json = { error = "Failed to create lookup table" } }
        end

        return { status = 201, json = { lookup_table = result and result[1] or nil } }
    end)

    -- GET /lookup-tables/:uuid/values
    app:get(PREFIX .. "/lookup-tables/:uuid/values", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local lt_uuid = self.params.uuid
        local ok_lt, lt_rows = pcall(db.query, "SELECT id FROM profile_lookup_tables WHERE uuid = ? LIMIT 1", lt_uuid)
        if not ok_lt or not lt_rows or #lt_rows == 0 then
            return { status = 404, json = { error = "Lookup table not found" } }
        end

        local ok, rows = pcall(db.query, [[
            SELECT * FROM profile_lookup_values WHERE lookup_table_id = ? AND is_active = true
            ORDER BY display_order ASC, label ASC
        ]], lt_rows[1].id)
        if not ok then
            return { status = 500, json = { error = "Failed to load lookup values" } }
        end

        return { status = 200, json = { values = rows or {}, total = #(rows or {}) } }
    end)

    -- POST /lookup-tables/:uuid/values (admin)
    app:post(PREFIX .. "/lookup-tables/:uuid/values", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local lt_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_lt, lt_rows = pcall(db.query, "SELECT id FROM profile_lookup_tables WHERE uuid = ? LIMIT 1", lt_uuid)
        if not ok_lt or not lt_rows or #lt_rows == 0 then
            return { status = 404, json = { error = "Lookup table not found" } }
        end

        if not params.label or params.label == "" then
            return { status = 400, json = { error = "label is required" } }
        end
        if not params.value or params.value == "" then
            return { status = 400, json = { error = "value is required" } }
        end

        local parent_value_id = nil
        if params.parent_value_uuid and params.parent_value_uuid ~= "" then
            local ok_pv, pv_rows = pcall(db.query, "SELECT id FROM profile_lookup_values WHERE uuid = ? LIMIT 1", params.parent_value_uuid)
            if ok_pv and pv_rows and #pv_rows > 0 then
                parent_value_id = pv_rows[1].id
            end
        end

        local ok_ins, ins_result = pcall(db.query, [[
            INSERT INTO profile_lookup_values (uuid, lookup_table_id, label, value, display_order, parent_value_id, is_active, metadata_json, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, true, ?, NOW(), NOW())
            RETURNING *
        ]],
            lt_rows[1].id,
            params.label,
            params.value,
            params.display_order or 0,
            parent_value_id,
            params.metadata_json
        )
        if not ok_ins then
            ngx.log(ngx.ERR, "[ProfileBuilder] create lookup value failed: ", tostring(ins_result))
            return { status = 500, json = { error = "Failed to create lookup value" } }
        end

        return { status = 201, json = { value = ins_result and ins_result[1] or nil } }
    end)

    -- PUT /lookup-tables/:uuid/values/:valueUuid (admin)
    app:put(PREFIX .. "/lookup-tables/:uuid/values/:valueUuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local value_uuid = self.params.valueUuid
        local params = parseJsonBody(self)

        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_lookup_values WHERE uuid = ? LIMIT 1", value_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Lookup value not found" } }
        end

        local set_parts = {}
        local set_vals = {}
        local allowed = {"label", "value", "display_order", "is_active", "metadata_json"}
        for _, field in ipairs(allowed) do
            if params[field] ~= nil then
                table.insert(set_parts, db.escape_identifier(field) .. " = ?")
                table.insert(set_vals, params[field])
            end
        end

        if params.parent_value_uuid ~= nil then
            if params.parent_value_uuid == "" or params.parent_value_uuid == cjson.null then
                table.insert(set_parts, "parent_value_id = NULL")
            else
                local ok_pv, pv_rows = pcall(db.query, "SELECT id FROM profile_lookup_values WHERE uuid = ? LIMIT 1", params.parent_value_uuid)
                if ok_pv and pv_rows and #pv_rows > 0 then
                    table.insert(set_parts, "parent_value_id = ?")
                    table.insert(set_vals, pv_rows[1].id)
                end
            end
        end

        if #set_parts == 0 then
            return { status = 400, json = { error = "No fields to update" } }
        end

        table.insert(set_parts, "updated_at = NOW()")
        table.insert(set_vals, value_uuid)

        local sql = "UPDATE profile_lookup_values SET " .. table.concat(set_parts, ", ") .. " WHERE uuid = ? RETURNING *"
        local ok_upd, upd_result = pcall(db.query, sql, unpack(set_vals))
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] update lookup value failed: ", tostring(upd_result))
            return { status = 500, json = { error = "Failed to update lookup value" } }
        end

        return { status = 200, json = { value = upd_result and upd_result[1] or nil } }
    end)

    -- DELETE /lookup-tables/:uuid/values/:valueUuid (admin)
    app:delete(PREFIX .. "/lookup-tables/:uuid/values/:valueUuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local value_uuid = self.params.valueUuid
        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_lookup_values WHERE uuid = ? LIMIT 1", value_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Lookup value not found" } }
        end

        local ok_del, del_err = pcall(db.query, "UPDATE profile_lookup_values SET is_active = false, updated_at = NOW() WHERE uuid = ?", value_uuid)
        if not ok_del then
            return { status = 500, json = { error = "Failed to delete lookup value" } }
        end

        return { status = 200, json = { message = "Lookup value deactivated", uuid = value_uuid } }
    end)

    -- =====================================================================
    -- 11. TOUCHPOINTS
    -- =====================================================================

    -- GET /touchpoints
    app:get(PREFIX .. "/touchpoints", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local namespace_id = getNamespaceId(self)
        local where_clause = "is_active = true"
        local vals = {}
        if namespace_id then
            where_clause = where_clause .. " AND namespace_id = ?"
            table.insert(vals, namespace_id)
        end

        local ok, rows = pcall(db.query, "SELECT * FROM profile_touchpoints WHERE " .. where_clause .. " ORDER BY name ASC", unpack(vals))
        if not ok then
            return { status = 500, json = { error = "Failed to load touchpoints" } }
        end

        return { status = 200, json = { touchpoints = rows or {}, total = #(rows or {}) } }
    end)

    -- POST /touchpoints (admin)
    app:post(PREFIX .. "/touchpoints", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        if not params.name or params.name == "" then
            return { status = 400, json = { error = "name is required" } }
        end
        if not params.slug or params.slug == "" then
            return { status = 400, json = { error = "slug is required" } }
        end

        local namespace_id = getNamespaceId(self)
        local admin_uuid = admin.uuid or admin.id

        local ok, result = pcall(db.query, [[
            INSERT INTO profile_touchpoints (uuid, namespace_id, name, slug, description, touchpoint_type, is_active, config_json, created_by, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, true, ?, ?, NOW(), NOW())
            RETURNING *
        ]],
            namespace_id,
            params.name,
            params.slug,
            params.description,
            params.touchpoint_type,
            params.config_json,
            admin_uuid
        )
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] create touchpoint failed: ", tostring(result))
            return { status = 500, json = { error = "Failed to create touchpoint" } }
        end

        return { status = 201, json = { touchpoint = result and result[1] or nil } }
    end)

    -- PUT /touchpoints/:uuid (admin)
    app:put(PREFIX .. "/touchpoints/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local tp_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_touchpoints WHERE uuid = ? LIMIT 1", tp_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Touchpoint not found" } }
        end

        local set_parts = {}
        local set_vals = {}
        local allowed = {"name", "slug", "description", "touchpoint_type", "is_active", "config_json"}
        for _, field in ipairs(allowed) do
            if params[field] ~= nil then
                table.insert(set_parts, db.escape_identifier(field) .. " = ?")
                table.insert(set_vals, params[field])
            end
        end

        if #set_parts == 0 then
            return { status = 400, json = { error = "No fields to update" } }
        end

        table.insert(set_parts, "updated_at = NOW()")
        table.insert(set_vals, tp_uuid)

        local sql = "UPDATE profile_touchpoints SET " .. table.concat(set_parts, ", ") .. " WHERE uuid = ? RETURNING *"
        local ok_upd, upd_result = pcall(db.query, sql, unpack(set_vals))
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] update touchpoint failed: ", tostring(upd_result))
            return { status = 500, json = { error = "Failed to update touchpoint" } }
        end

        return { status = 200, json = { touchpoint = upd_result and upd_result[1] or nil } }
    end)

    -- POST /touchpoints/:uuid/questions — link questions (admin)
    app:post(PREFIX .. "/touchpoints/:uuid/questions", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local tp_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_tp, tp_rows = pcall(db.query, "SELECT id FROM profile_touchpoints WHERE uuid = ? LIMIT 1", tp_uuid)
        if not ok_tp or not tp_rows or #tp_rows == 0 then
            return { status = 404, json = { error = "Touchpoint not found" } }
        end
        local touchpoint_id = tp_rows[1].id

        local questions = params.questions
        if not questions or type(questions) ~= "table" or #questions == 0 then
            return { status = 400, json = { error = "questions array is required with question_uuid and display_order" } }
        end

        local linked = 0
        for _, item in ipairs(questions) do
            if item.question_uuid and item.question_uuid ~= "" then
                local ok_q, q_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", item.question_uuid)
                if ok_q and q_rows and #q_rows > 0 then
                    local ok_ins, ins_err = pcall(db.query, [[
                        INSERT INTO profile_question_touchpoints (question_id, touchpoint_id, display_order, is_required_in_touchpoint, created_at)
                        VALUES (?, ?, ?, ?, NOW())
                        ON CONFLICT (question_id, touchpoint_id) DO UPDATE SET
                            display_order = EXCLUDED.display_order,
                            is_required_in_touchpoint = EXCLUDED.is_required_in_touchpoint,
                            created_at = NOW()
                    ]],
                        q_rows[1].id,
                        touchpoint_id,
                        item.display_order or 0,
                        item.is_required_in_touchpoint or false
                    )
                    if ok_ins then
                        linked = linked + 1
                    else
                        ngx.log(ngx.ERR, "[ProfileBuilder] link question to touchpoint failed: ", tostring(ins_err))
                    end
                end
            end
        end

        return { status = 200, json = { message = "Questions linked to touchpoint", linked = linked, total = #questions } }
    end)

    -- =====================================================================
    -- 12. COMPLETION
    -- =====================================================================

    -- GET /completion — current user's completion
    app:get(PREFIX .. "/completion", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_uuid = user.uuid or user.id
        local user_id = getUserIdByUuid(user_uuid)
        if not user_id then
            return { status = 200, json = { completion = {}, overall = { total = 0, answered = 0, percent = 0, status = "not_started" } } }
        end

        local ok, rows = pcall(db.query, [[
            SELECT pcs.*, pc.name AS category_name, pc.slug AS category_slug, pc.uuid AS category_uuid
            FROM profile_completion_status pcs
            JOIN profile_categories pc ON pc.id = pcs.category_id
            WHERE pcs.user_id = ?
            ORDER BY pc.display_order ASC
        ]], user_id)
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] completion query failed: ", tostring(rows))
            return { status = 500, json = { error = "Failed to load completion" } }
        end

        -- Calculate overall
        local total_q = 0
        local total_a = 0
        local total_req = 0
        local total_req_a = 0
        for _, r in ipairs(rows or {}) do
            total_q = total_q + (tonumber(r.total_questions) or 0)
            total_a = total_a + (tonumber(r.answered_questions) or 0)
            total_req = total_req + (tonumber(r.required_questions) or 0)
            total_req_a = total_req_a + (tonumber(r.required_answered) or 0)
        end

        local overall_pct = 0
        if total_q > 0 then
            overall_pct = math.floor((total_a / total_q) * 100)
        end
        local overall_status = "not_started"
        if overall_pct >= 100 then
            overall_status = "complete"
        elseif overall_pct > 0 then
            overall_status = "in_progress"
        end

        return {
            status = 200,
            json = {
                completion = rows or {},
                overall = {
                    total_questions = total_q,
                    answered_questions = total_a,
                    required_questions = total_req,
                    required_answered = total_req_a,
                    completion_percent = overall_pct,
                    status = overall_status
                }
            }
        }
    end)

    -- GET /completion/users — admin: all users completion
    app:get(PREFIX .. "/completion/users", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local page = tonumber(self.params.page) or 1
        local per_page = tonumber(self.params.per_page) or 25
        if per_page > 100 then per_page = 100 end
        local offset = (page - 1) * per_page

        local where_parts = {"1=1"}
        local where_vals = {}

        if self.params.search and self.params.search ~= "" then
            local search_term = "%" .. self.params.search .. "%"
            table.insert(where_parts, "(u.email ILIKE ? OR u.first_name ILIKE ? OR u.last_name ILIKE ?)")
            table.insert(where_vals, search_term)
            table.insert(where_vals, search_term)
            table.insert(where_vals, search_term)
        end

        if self.params.status and self.params.status ~= "" then
            table.insert(where_parts, "agg.overall_status = ?")
            table.insert(where_vals, self.params.status)
        end

        if self.params.tag and self.params.tag ~= "" then
            table.insert(where_parts, [[
                u.id IN (
                    SELECT upt.user_id FROM user_profile_tags upt
                    JOIN profile_tags pt ON pt.id = upt.tag_id
                    WHERE pt.slug = ? AND upt.is_active = true
                )
            ]])
            table.insert(where_vals, self.params.tag)
        end

        -- Count total
        local count_sql = [[
            SELECT COUNT(DISTINCT u.id) AS cnt
            FROM users u
            LEFT JOIN (
                SELECT user_id,
                    SUM(total_questions) AS total_q,
                    SUM(answered_questions) AS total_a,
                    CASE
                        WHEN SUM(total_questions) = 0 THEN 'not_started'
                        WHEN SUM(answered_questions) >= SUM(total_questions) THEN 'complete'
                        WHEN SUM(answered_questions) > 0 THEN 'in_progress'
                        ELSE 'not_started'
                    END AS overall_status
                FROM profile_completion_status
                GROUP BY user_id
            ) agg ON agg.user_id = u.id
            WHERE ]] .. table.concat(where_parts, " AND ")

        local ok_cnt, cnt_rows = pcall(db.query, count_sql, unpack(where_vals))
        local total = (ok_cnt and cnt_rows and cnt_rows[1]) and tonumber(cnt_rows[1].cnt) or 0

        -- Get paginated results
        local vals_with_pagination = {}
        for _, v in ipairs(where_vals) do table.insert(vals_with_pagination, v) end
        table.insert(vals_with_pagination, per_page)
        table.insert(vals_with_pagination, offset)

        local data_sql = [[
            SELECT u.uuid, u.email, u.first_name, u.last_name,
                COALESCE(agg.total_q, 0) AS total_questions,
                COALESCE(agg.total_a, 0) AS answered_questions,
                COALESCE(agg.total_req, 0) AS required_questions,
                COALESCE(agg.total_req_a, 0) AS required_answered,
                CASE
                    WHEN COALESCE(agg.total_q, 0) = 0 THEN 0
                    ELSE FLOOR((COALESCE(agg.total_a, 0)::numeric / agg.total_q) * 100)
                END AS completion_percent,
                CASE
                    WHEN COALESCE(agg.total_q, 0) = 0 THEN 'not_started'
                    WHEN COALESCE(agg.total_a, 0) >= COALESCE(agg.total_q, 0) THEN 'complete'
                    WHEN COALESCE(agg.total_a, 0) > 0 THEN 'in_progress'
                    ELSE 'not_started'
                END AS overall_status
            FROM users u
            LEFT JOIN (
                SELECT user_id,
                    SUM(total_questions) AS total_q,
                    SUM(answered_questions) AS total_a,
                    SUM(required_questions) AS total_req,
                    SUM(required_answered) AS total_req_a,
                    CASE
                        WHEN SUM(total_questions) = 0 THEN 'not_started'
                        WHEN SUM(answered_questions) >= SUM(total_questions) THEN 'complete'
                        WHEN SUM(answered_questions) > 0 THEN 'in_progress'
                        ELSE 'not_started'
                    END AS overall_status
                FROM profile_completion_status
                GROUP BY user_id
            ) agg ON agg.user_id = u.id
            WHERE ]] .. table.concat(where_parts, " AND ") .. [[
            ORDER BY u.email ASC
            LIMIT ? OFFSET ?
        ]]

        local ok_data, data_rows = pcall(db.query, data_sql, unpack(vals_with_pagination))
        if not ok_data then
            ngx.log(ngx.ERR, "[ProfileBuilder] completion users query failed: ", tostring(data_rows))
            return { status = 500, json = { error = "Failed to load user completion data" } }
        end

        return {
            status = 200,
            json = {
                users = data_rows or {},
                total = total,
                page = page,
                per_page = per_page
            }
        }
    end)

    -- =====================================================================
    -- 13. ADMIN user endpoints
    -- =====================================================================

    -- GET /admin/users/:userUuid/profile
    app:get(PREFIX .. "/admin/users/:userUuid/profile", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local target_uuid = self.params.userUuid
        local target_user_id = getUserIdByUuid(target_uuid)
        if not target_user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        -- Get user info
        local ok_user, user_rows = pcall(db.query, [[
            SELECT uuid, email, first_name, last_name, created_at FROM users WHERE uuid = ? LIMIT 1
        ]], target_uuid)
        local user_info = (ok_user and user_rows and #user_rows > 0) and user_rows[1] or nil

        -- Get answers
        local ok_ans, answers = pcall(db.query, [[
            SELECT upa.*, pq.question_key, pq.label AS question_label, pq.uuid AS question_uuid,
                   pc.name AS category_name, pc.slug AS category_slug
            FROM user_profile_answers upa
            JOIN profile_questions pq ON pq.id = upa.question_id
            JOIN profile_categories pc ON pc.id = pq.category_id
            WHERE upa.user_id = ?
            ORDER BY pc.display_order ASC, pq.display_order ASC
        ]], target_user_id)
        if not ok_ans then answers = {} end

        -- Get tags
        local ok_tags, tags = pcall(db.query, [[
            SELECT upt.*, pt.name AS tag_name, pt.slug AS tag_slug, pt.color AS tag_color
            FROM user_profile_tags upt
            JOIN profile_tags pt ON pt.id = upt.tag_id
            WHERE upt.user_id = ? AND upt.is_active = true
            ORDER BY pt.name ASC
        ]], target_user_id)
        if not ok_tags then tags = {} end

        -- Get completion
        local ok_comp, completion = pcall(db.query, [[
            SELECT pcs.*, pc.name AS category_name, pc.slug AS category_slug
            FROM profile_completion_status pcs
            JOIN profile_categories pc ON pc.id = pcs.category_id
            WHERE pcs.user_id = ?
            ORDER BY pc.display_order ASC
        ]], target_user_id)
        if not ok_comp then completion = {} end

        return {
            status = 200,
            json = {
                user = user_info,
                answers = answers or {},
                tags = tags or {},
                completion = completion or {}
            }
        }
    end)

    -- GET /admin/users/:userUuid/tags
    app:get(PREFIX .. "/admin/users/:userUuid/tags", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local target_uuid = self.params.userUuid
        local target_user_id = getUserIdByUuid(target_uuid)
        if not target_user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        local ok, rows = pcall(db.query, [[
            SELECT upt.*, pt.name AS tag_name, pt.slug AS tag_slug, pt.color AS tag_color, pt.tag_type
            FROM user_profile_tags upt
            JOIN profile_tags pt ON pt.id = upt.tag_id
            WHERE upt.user_id = ? AND upt.is_active = true
            ORDER BY pt.name ASC
        ]], target_user_id)
        if not ok then
            return { status = 500, json = { error = "Failed to load user tags" } }
        end

        return { status = 200, json = { tags = rows or {}, total = #(rows or {}) } }
    end)

    -- GET /admin/users/:userUuid/answers/history
    app:get(PREFIX .. "/admin/users/:userUuid/answers/history", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local target_uuid = self.params.userUuid
        local target_user_id = getUserIdByUuid(target_uuid)
        if not target_user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        local page = tonumber(self.params.page) or 1
        local per_page = tonumber(self.params.per_page) or 50
        if per_page > 100 then per_page = 100 end
        local offset = (page - 1) * per_page

        local ok_cnt, cnt_rows = pcall(db.query, "SELECT COUNT(*) AS cnt FROM user_profile_answer_history WHERE user_id = ?", target_user_id)
        local total = (ok_cnt and cnt_rows and cnt_rows[1]) and tonumber(cnt_rows[1].cnt) or 0

        local ok, rows = pcall(db.query, [[
            SELECT upah.*, pq.question_key, pq.label AS question_label, pq.uuid AS question_uuid
            FROM user_profile_answer_history upah
            JOIN profile_questions pq ON pq.id = upah.question_id
            WHERE upah.user_id = ?
            ORDER BY upah.created_at DESC
            LIMIT ? OFFSET ?
        ]], target_user_id, per_page, offset)
        if not ok then
            return { status = 500, json = { error = "Failed to load answer history" } }
        end

        return { status = 200, json = { history = rows or {}, total = total, page = page, per_page = per_page } }
    end)

    -- =====================================================================
    -- 14. AUDIT LOGS
    -- =====================================================================

    -- GET /audit-logs (admin)
    app:get(PREFIX .. "/audit-logs", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local page = tonumber(self.params.page) or 1
        local per_page = tonumber(self.params.per_page) or 50
        if per_page > 100 then per_page = 100 end
        local offset = (page - 1) * per_page

        local where_parts = {"1=1"}
        local where_vals = {}

        if self.params.entity_type and self.params.entity_type ~= "" then
            table.insert(where_parts, "pal.entity_type = ?")
            table.insert(where_vals, self.params.entity_type)
        end

        if self.params.action and self.params.action ~= "" then
            table.insert(where_parts, "pal.action = ?")
            table.insert(where_vals, self.params.action)
        end

        if self.params.user_id and self.params.user_id ~= "" then
            table.insert(where_parts, "pal.user_id = ?")
            table.insert(where_vals, self.params.user_id)
        end

        if self.params.from_date and self.params.from_date ~= "" then
            table.insert(where_parts, "pal.created_at >= ?")
            table.insert(where_vals, self.params.from_date)
        end

        if self.params.to_date and self.params.to_date ~= "" then
            table.insert(where_parts, "pal.created_at <= ?")
            table.insert(where_vals, self.params.to_date)
        end

        local namespace_id = getNamespaceId(self)
        if namespace_id then
            table.insert(where_parts, "pal.namespace_id = ?")
            table.insert(where_vals, namespace_id)
        end

        local where_clause = table.concat(where_parts, " AND ")

        -- Count
        local count_vals = {}
        for _, v in ipairs(where_vals) do table.insert(count_vals, v) end
        local ok_cnt, cnt_rows = pcall(db.query,
            "SELECT COUNT(*) AS cnt FROM profile_audit_logs pal WHERE " .. where_clause,
            unpack(count_vals)
        )
        local total = (ok_cnt and cnt_rows and cnt_rows[1]) and tonumber(cnt_rows[1].cnt) or 0

        -- Data
        local data_vals = {}
        for _, v in ipairs(where_vals) do table.insert(data_vals, v) end
        table.insert(data_vals, per_page)
        table.insert(data_vals, offset)

        local ok, rows = pcall(db.query,
            "SELECT pal.* FROM profile_audit_logs pal WHERE " .. where_clause .. " ORDER BY pal.created_at DESC LIMIT ? OFFSET ?",
            unpack(data_vals)
        )
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] audit logs query failed: ", tostring(rows))
            return { status = 500, json = { error = "Failed to load audit logs" } }
        end

        return {
            status = 200,
            json = {
                audit_logs = rows or {},
                total = total,
                page = page,
                per_page = per_page
            }
        }
    end)

end
