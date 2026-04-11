--[[
    Timesheet Routes

    API endpoints for namespace-scoped timesheet management with approval workflow.

    Workflow: draft -> submitted -> approved/rejected -> (rejected can reopen to draft)

    Endpoints:
    - GET    /api/v2/timesheets                    - List timesheets (own by default, all with ?all=true)
    - POST   /api/v2/timesheets                    - Create timesheet
    - GET    /api/v2/timesheets/:uuid              - Get timesheet with entries
    - PUT    /api/v2/timesheets/:uuid              - Update timesheet (draft only)
    - DELETE /api/v2/timesheets/:uuid              - Soft delete (draft only)

    - POST   /api/v2/timesheets/:uuid/submit       - Submit for approval
    - POST   /api/v2/timesheets/:uuid/approve      - Approve (manager action)
    - POST   /api/v2/timesheets/:uuid/reject       - Reject with reason
    - POST   /api/v2/timesheets/:uuid/reopen       - Reopen rejected timesheet

    - GET    /api/v2/timesheets/approval-queue      - List pending timesheets for approval
    - GET    /api/v2/timesheets/summary             - Get summary stats

    - GET    /api/v2/timesheets/:uuid/entries       - List entries for a timesheet
    - POST   /api/v2/timesheets/:uuid/entries       - Add entry
    - PUT    /api/v2/timesheets/entries/:entry_uuid - Update entry
    - DELETE /api/v2/timesheets/entries/:entry_uuid - Delete entry
]]

local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local TimesheetQueries = require("queries.TimesheetQueries")
local RequestParser = require("helper.request_parser")

return function(app)

    local function error_response(status, message)
        return {
            status = status,
            json = { success = false, error = message }
        }
    end

    local function success_response(data, status)
        return {
            status = status or 200,
            json = { success = true, data = data }
        }
    end

    -- ============================================================
    -- APPROVAL QUEUE (must be before :uuid routes)
    -- ============================================================

    app:get("/api/v2/timesheets/approval-queue", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local params = self.params or {}
            local result = TimesheetQueries.getApprovalQueue(self.namespace.id, self.current_user.uuid, {
                page = params.page,
                per_page = params.per_page
            })
            return success_response(result)
        end)
    ))

    -- ============================================================
    -- SUMMARY (must be before :uuid routes)
    -- ============================================================

    app:get("/api/v2/timesheets/summary", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local params = self.params or {}
            local result = TimesheetQueries.getSummary(
                self.namespace.id,
                params.user_uuid or self.current_user.uuid,
                params.start_date,
                params.end_date
            )
            return success_response(result)
        end)
    ))

    -- ============================================================
    -- TIMESHEET CRUD
    -- ============================================================

    -- List timesheets
    app:get("/api/v2/timesheets", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local params = self.params or {}

            if params.all == "true" then
                -- Admin view: list all timesheets in namespace
                local result = TimesheetQueries.list(self.namespace.id, {
                    page = params.page,
                    per_page = params.per_page,
                    status = params.status,
                    user_uuid = params.user_uuid,
                    period_start = params.period_start,
                    period_end = params.period_end
                })
                return success_response(result)
            else
                -- Default: list user's own timesheets
                local result = TimesheetQueries.getMyTimesheets(self.namespace.id, self.current_user.uuid, {
                    page = params.page,
                    per_page = params.per_page,
                    status = params.status
                })
                return success_response(result)
            end
        end)
    ))

    -- Create timesheet
    app:post("/api/v2/timesheets", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local params = RequestParser.parse_request(self)

            if not params.period_start or params.period_start == "" then
                return error_response(400, "period_start is required")
            end

            if not params.period_end or params.period_end == "" then
                return error_response(400, "period_end is required")
            end

            local ok, timesheet = pcall(TimesheetQueries.create, {
                namespace_id = self.namespace.id,
                user_uuid = self.current_user.uuid,
                title = params.title,
                description = params.description,
                period_start = params.period_start,
                period_end = params.period_end
            })

            if not ok then
                return error_response(500, "Failed to create timesheet: " .. tostring(timesheet))
            end

            return success_response(timesheet, 201)
        end)
    ))

    -- Get timesheet with entries
    app:get("/api/v2/timesheets/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local timesheet = TimesheetQueries.get(self.params.uuid)
            if not timesheet then
                return error_response(404, "Timesheet not found")
            end

            if timesheet.namespace_id ~= self.namespace.id then
                return error_response(403, "Timesheet not found in this namespace")
            end

            return success_response(timesheet)
        end)
    ))

    -- Update timesheet (draft only)
    app:put("/api/v2/timesheets/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local params = RequestParser.parse_request(self)

            local updated, err = TimesheetQueries.update(self.params.uuid, {
                title = params.title,
                description = params.description,
                period_start = params.period_start,
                period_end = params.period_end
            })

            if err then
                if err == "Timesheet not found" then
                    return error_response(404, err)
                end
                return error_response(400, err)
            end

            return success_response(updated)
        end)
    ))

    -- Soft delete timesheet (draft only)
    app:delete("/api/v2/timesheets/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local deleted, err = TimesheetQueries.delete(self.params.uuid)

            if err then
                if err == "Timesheet not found" then
                    return error_response(404, err)
                end
                return error_response(400, err)
            end

            return success_response({ message = "Timesheet deleted successfully" })
        end)
    ))

    -- ============================================================
    -- WORKFLOW
    -- ============================================================

    -- Submit timesheet for approval
    app:post("/api/v2/timesheets/:uuid/submit", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local result, err = TimesheetQueries.submit(self.params.uuid, self.current_user.uuid)

            if err then
                if err == "Timesheet not found" then
                    return error_response(404, err)
                end
                return error_response(400, err)
            end

            return success_response(result)
        end)
    ))

    -- Approve timesheet (manager action)
    app:post("/api/v2/timesheets/:uuid/approve", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local params = RequestParser.parse_request(self)

            local result, err = TimesheetQueries.approve(
                self.params.uuid,
                self.current_user.uuid,
                params.comments
            )

            if err then
                if err == "Timesheet not found" then
                    return error_response(404, err)
                end
                return error_response(400, err)
            end

            return success_response(result)
        end)
    ))

    -- Reject timesheet with reason
    app:post("/api/v2/timesheets/:uuid/reject", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local params = RequestParser.parse_request(self)

            if not params.reason or params.reason == "" then
                return error_response(400, "Rejection reason is required")
            end

            local result, err = TimesheetQueries.reject(
                self.params.uuid,
                self.current_user.uuid,
                params.reason,
                params.comments
            )

            if err then
                if err == "Timesheet not found" then
                    return error_response(404, err)
                end
                return error_response(400, err)
            end

            return success_response(result)
        end)
    ))

    -- Reopen rejected timesheet
    app:post("/api/v2/timesheets/:uuid/reopen", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local result, err = TimesheetQueries.reopen(self.params.uuid)

            if err then
                if err == "Timesheet not found" then
                    return error_response(404, err)
                end
                return error_response(400, err)
            end

            return success_response(result)
        end)
    ))

    -- ============================================================
    -- ENTRIES
    -- ============================================================

    -- List entries for a timesheet
    app:get("/api/v2/timesheets/:uuid/entries", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local timesheet = TimesheetQueries.get(self.params.uuid)
            if not timesheet then
                return error_response(404, "Timesheet not found")
            end

            if timesheet.namespace_id ~= self.namespace.id then
                return error_response(403, "Timesheet not found in this namespace")
            end

            local entries = TimesheetQueries.getEntriesByTimesheet(timesheet.internal_id)
            return success_response(entries)
        end)
    ))

    -- Add entry to timesheet
    app:post("/api/v2/timesheets/:uuid/entries", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local params = RequestParser.parse_request(self)

            if not params.entry_date or params.entry_date == "" then
                return error_response(400, "entry_date is required")
            end

            if not params.hours then
                return error_response(400, "hours is required")
            end

            if not params.description or params.description == "" then
                return error_response(400, "description is required")
            end

            -- Look up the timesheet to get its internal id
            local timesheet = TimesheetQueries.get(self.params.uuid)
            if not timesheet then
                return error_response(404, "Timesheet not found")
            end

            if timesheet.namespace_id ~= self.namespace.id then
                return error_response(403, "Timesheet not found in this namespace")
            end

            local entry, err = TimesheetQueries.createEntry({
                timesheet_id = timesheet.internal_id,
                entry_date = params.entry_date,
                hours = tonumber(params.hours),
                billable = params.billable == true or params.billable == "true",
                description = params.description,
                project_uuid = params.project_uuid,
                category = params.category,
                task_reference = params.task_reference
            })

            if err then
                return error_response(400, err)
            end

            return success_response(entry, 201)
        end)
    ))

    -- Update entry
    app:put("/api/v2/timesheets/entries/:entry_uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local params = RequestParser.parse_request(self)

            local updated, err = TimesheetQueries.updateEntry(self.params.entry_uuid, {
                entry_date = params.entry_date,
                hours = params.hours and tonumber(params.hours),
                billable = params.billable == true or params.billable == "true",
                description = params.description,
                project_uuid = params.project_uuid,
                category = params.category,
                task_reference = params.task_reference
            })

            if err then
                if err == "Entry not found" then
                    return error_response(404, err)
                end
                return error_response(400, err)
            end

            return success_response(updated)
        end)
    ))

    -- Delete entry
    app:delete("/api/v2/timesheets/entries/:entry_uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local deleted, err = TimesheetQueries.deleteEntry(self.params.entry_uuid)

            if err then
                if err == "Entry not found" then
                    return error_response(404, err)
                end
                return error_response(400, err)
            end

            return success_response({ message = "Entry deleted successfully" })
        end)
    ))

    ngx.log(ngx.NOTICE, "Timesheet routes initialized successfully")
end
