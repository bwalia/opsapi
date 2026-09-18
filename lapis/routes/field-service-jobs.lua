--[[
    Field Service — job, phase, item and invoicing routes

    Endpoints:
    - GET    /api/v2/field-service/jobs                        - List (?status=open|<status>&priority=&account_uuid=
                                                                 &site_uuid=&job_type_uuid=&manager_uuid=&engineer_uuid=
                                                                 &overdue=&uninvoiced=&search=&page=&per_page=
                                                                 &order_by=&order_dir=)
    - POST   /api/v2/field-service/jobs                        - Create (phases copied from job_type_uuid's templates,
                                                                 or an explicit `phases` array)
    - GET    /api/v2/field-service/jobs/:uuid                  - Job + phases + visits + items + activity + totals
    - PUT    /api/v2/field-service/jobs/:uuid                  - Update details
    - DELETE /api/v2/field-service/jobs/:uuid                  - Soft delete (not once invoiced)
    - POST   /api/v2/field-service/jobs/:uuid/status           - { status, reason?, force? }

    - POST   /api/v2/field-service/jobs/:uuid/phases           - Add a phase
    - PUT    /api/v2/field-service/jobs/:uuid/phases/reorder   - { order = [phase uuid, ...] }
    - PUT    /api/v2/field-service/job-phases/:uuid            - Update a phase
    - DELETE /api/v2/field-service/job-phases/:uuid            - Remove a phase
    - POST   /api/v2/field-service/job-phases/:uuid/status     - { status, signoff_name?, force?, notes? }
    - POST   /api/v2/field-service/job-phases/:uuid/checklist/:index - { done } (0-based index)

    - POST   /api/v2/field-service/jobs/:uuid/items            - Log a part / material / expense
    - PUT    /api/v2/field-service/job-items/:uuid             - Update (not once invoiced)
    - DELETE /api/v2/field-service/job-items/:uuid             - Remove (not once invoiced)

    - GET    /api/v2/field-service/jobs/:uuid/invoice-preview  - Uninvoiced billable lines (?hourly_rate=&labour_tax_rate=)
    - POST   /api/v2/field-service/jobs/:uuid/invoice          - Bill them as one draft invoice
                                                                 { hourly_rate?, labour_tax_rate?, due_date?, notes? }

    Engineers assigned to a visit on a job may view it, tick checklists,
    start/complete/block its phases and log items against it without holding
    fs_jobs grants.
]]

local Http = require("helper.field-service-http")
local Common = require("queries.FieldServiceCommon")
local JobQueries = require("queries.FieldServiceJobQueries")
local JobPhotoQueries = require("queries.JobPhotoQueries")
local MinioClient = require("helper.minio")
local Mail = require("helper.mail")

return function(app)
    -- fs_jobs.<action>, or the caller is an engineer booked on the job.
    local function can_work_job(self, job_id, action)
        return Http.has_perm(self, "fs_jobs", action) or Common.is_engineer_on_job(job_id, Http.actor(self))
    end

    -- ============================================================
    -- JOBS
    -- ============================================================

    app:get("/api/v2/field-service/jobs", Http.route(function(self)
        local p = self.params
        local engineer = p.engineer_uuid
        -- A caller who can't update jobs (an engineer, vs a manager who can
        -- dispatch) only ever sees jobs assigned to them — i.e. jobs that have a
        -- visit booked to them. Managers may still ask for their own via ?mine.
        if p.mine == "true" or not Http.has_perm(self, "fs_jobs", "update") then
            engineer = Http.actor(self)
        end
        local result = JobQueries.listJobs(self.namespace.id, {
            status = p.status, priority = p.priority, customer_uuid = p.customer_uuid, product_uuid = p.product_uuid,
            job_type_uuid = p.job_type_uuid, manager_uuid = p.manager_uuid, engineer_uuid = engineer,
            overdue = p.overdue, uninvoiced = p.uninvoiced, search = p.search,
            page = p.page, per_page = p.per_page, order_by = p.order_by, order_dir = p.order_dir,
        })
        return Http.ok(result.items, 200, result.meta)
    end))

    app:post("/api/v2/field-service/jobs", Http.guard("fs_jobs", "create", function(self)
        local job, err = JobQueries.createJob(self.namespace.id, Http.actor(self), Http.body(self))
        return Http.result(job, err, 201)
    end))

    app:get("/api/v2/field-service/jobs/:uuid", Http.route(function(self)
        local row = JobQueries.findJobRow(self.namespace.id, self.params.uuid)
        if not row then return Http.fail(404, "Job not found") end
        -- A dispatcher (fs_jobs.update) may open any job; an engineer only the
        -- jobs they're assigned to. Plain fs_jobs.read is enough for the list
        -- (auto-scoped to own) but not to open another engineer's job by uuid.
        if not can_work_job(self, row.id, "update") then return Http.forbidden("fs_jobs", "read") end
        return Http.ok(JobQueries.getJob(self.namespace.id, self.params.uuid))
    end))

    app:put("/api/v2/field-service/jobs/:uuid", Http.guard("fs_jobs", "update", function(self)
        return Http.result(JobQueries.updateJob(self.namespace.id, self.params.uuid, Http.body(self), Http.actor(self)))
    end))

    app:delete("/api/v2/field-service/jobs/:uuid", Http.guard("fs_jobs", "delete", function(self)
        local ok, err = JobQueries.deleteJob(self.namespace.id, self.params.uuid, Http.actor(self))
        if not ok then return Http.from_error(err) end
        return Http.ok({ message = "Job deleted" })
    end))

    app:post("/api/v2/field-service/jobs/:uuid/status", Http.guard("fs_jobs", "update", function(self)
        local body = Http.body(self)
        if not body.status or body.status == "" then return Http.fail(400, "status is required") end
        return Http.result(JobQueries.setJobStatus(self.namespace.id, self.params.uuid, body.status, {
            reason = body.reason, force = body.force,
        }, Http.actor(self)))
    end))

    -- ============================================================
    -- PHASES
    -- ============================================================

    app:post("/api/v2/field-service/jobs/:uuid/phases", Http.guard("fs_jobs", "update", function(self)
        local phase, err = JobQueries.addPhase(self.namespace.id, self.params.uuid, Http.body(self), Http.actor(self))
        return Http.result(phase, err, 201)
    end))

    app:put("/api/v2/field-service/jobs/:uuid/phases/reorder", Http.guard("fs_jobs", "update", function(self)
        local body = Http.body(self)
        return Http.result(JobQueries.reorderPhases(self.namespace.id, self.params.uuid, body.order, Http.actor(self)))
    end))

    app:put("/api/v2/field-service/job-phases/:uuid", Http.guard("fs_jobs", "update", function(self)
        return Http.result(JobQueries.updatePhase(self.namespace.id, self.params.uuid, Http.body(self),
            Http.actor(self)))
    end))

    app:delete("/api/v2/field-service/job-phases/:uuid", Http.guard("fs_jobs", "update", function(self)
        local ok, err = JobQueries.deletePhase(self.namespace.id, self.params.uuid, Http.actor(self))
        if not ok then return Http.from_error(err) end
        return Http.ok({ message = "Phase removed" })
    end))

    -- Engineers on site may move a phase through the working states; skipping
    -- or reopening to pending is a service-manager decision.
    local ENGINEER_PHASE_STATUSES = { in_progress = true, blocked = true, completed = true }

    app:post("/api/v2/field-service/job-phases/:uuid/status", Http.route(function(self)
        local phase = JobQueries.findPhaseRow(self.namespace.id, self.params.uuid)
        if not phase then return Http.fail(404, "Phase not found") end
        local body = Http.body(self)
        if not body.status or body.status == "" then return Http.fail(400, "status is required") end

        local allowed = Http.has_perm(self, "fs_jobs", "update")
            or (ENGINEER_PHASE_STATUSES[body.status] and Common.is_engineer_on_job(phase.job_id, Http.actor(self)))
        if not allowed then return Http.forbidden("fs_jobs", "update") end

        return Http.result(JobQueries.setPhaseStatus(self.namespace.id, self.params.uuid, body.status, {
            signoff_name = body.signoff_name, force = body.force, notes = body.notes,
        }, Http.actor(self)))
    end))

    app:post("/api/v2/field-service/job-phases/:uuid/checklist/:index", Http.route(function(self)
        local phase = JobQueries.findPhaseRow(self.namespace.id, self.params.uuid)
        if not phase then return Http.fail(404, "Phase not found") end
        if not can_work_job(self, phase.job_id, "update") then return Http.forbidden("fs_jobs", "update") end
        local body = Http.body(self)
        return Http.result(JobQueries.setChecklistItem(self.namespace.id, self.params.uuid, self.params.index,
            body.done, Http.actor(self)))
    end))

    -- ============================================================
    -- ITEMS (parts / materials / expenses)
    -- ============================================================

    app:post("/api/v2/field-service/jobs/:uuid/items", Http.route(function(self)
        local job = JobQueries.findJobRow(self.namespace.id, self.params.uuid)
        if not job then return Http.fail(404, "Job not found") end
        if not can_work_job(self, job.id, "update") then return Http.forbidden("fs_jobs", "update") end
        local item, err = JobQueries.addItem(self.namespace.id, self.params.uuid, Http.body(self), Http.actor(self))
        return Http.result(item, err, 201)
    end))

    -- Post a free-text comment/note to the job timeline. Engineer-allowed (same
    -- can_work_job gate as items), so an engineer on site can leave a note.
    app:post("/api/v2/field-service/jobs/:uuid/comments", Http.route(function(self)
        local job = JobQueries.findJobRow(self.namespace.id, self.params.uuid)
        if not job then return Http.fail(404, "Job not found") end
        if not can_work_job(self, job.id, "update") then return Http.forbidden("fs_jobs", "update") end
        local body = Http.body(self)
        local ok, err = JobQueries.addComment(self.namespace.id, job.id, Http.actor(self), body.message or body.comment)
        return Http.result(ok, err, 201)
    end))

    -- Managers edit any item; an engineer only the items they logged.
    local function can_edit_item(self, item)
        if Http.has_perm(self, "fs_jobs", "update") then return true end
        return item.created_by_uuid == Http.actor(self) and Common.is_engineer_on_job(item.job_id, Http.actor(self))
    end

    app:put("/api/v2/field-service/job-items/:uuid", Http.route(function(self)
        local item = JobQueries.findItemRow(self.namespace.id, self.params.uuid)
        if not item then return Http.fail(404, "Item not found") end
        if not can_edit_item(self, item) then return Http.forbidden("fs_jobs", "update") end
        return Http.result(JobQueries.updateItem(self.namespace.id, self.params.uuid, Http.body(self),
            Http.actor(self)))
    end))

    app:delete("/api/v2/field-service/job-items/:uuid", Http.route(function(self)
        local item = JobQueries.findItemRow(self.namespace.id, self.params.uuid)
        if not item then return Http.fail(404, "Item not found") end
        if not can_edit_item(self, item) then return Http.forbidden("fs_jobs", "update") end
        local ok, err = JobQueries.deleteItem(self.namespace.id, self.params.uuid, Http.actor(self))
        if not ok then return Http.from_error(err) end
        return Http.ok({ message = "Item removed" })
    end))

    -- Back-office approval of parts before they can be invoiced (manager only).
    app:post("/api/v2/field-service/job-items/:uuid/approve", Http.guard("fs_jobs", "update", function(self)
        return Http.result(JobQueries.setItemApproval(self.namespace.id, self.params.uuid, true, Http.body(self),
            Http.actor(self)))
    end))

    app:post("/api/v2/field-service/job-items/:uuid/reject", Http.guard("fs_jobs", "update", function(self)
        return Http.result(JobQueries.setItemApproval(self.namespace.id, self.params.uuid, false, Http.body(self),
            Http.actor(self)))
    end))

    -- Engineer part-replacement proposal (multipart). The engineer picks a part
    -- that ALREADY EXISTS in the namespace catalogue (part_uuid — they can't
    -- invent parts), says what they're fixing (reason) and attaches a fault
    -- photo. Evidence is MANDATORY: the item and its first photo are created in
    -- one request, so a proposal can never exist without a photo for the manager
    -- to verify. The item lands approval_status='pending' (addItem does this for
    -- parts); the manager approves via the existing approve/reject routes, which
    -- is what lets it reach the invoice. Extra photos post to the photos route
    -- above with item_uuid. Allowed to the engineer booked on the job.
    app:post("/api/v2/field-service/jobs/:uuid/part-proposals", Http.route(function(self)
        local job = JobQueries.findJobRow(self.namespace.id, self.params.uuid)
        if not job then return Http.fail(404, "Job not found") end
        if not can_work_job(self, job.id, "update") then return Http.forbidden("fs_jobs", "update") end

        if not self.params.part_uuid or self.params.part_uuid == "" then
            return Http.fail(400, "Select a part from the catalogue")
        end
        local file = self.params.photo or self.params.file or self.params.image
        if type(file) ~= "table" or not file.content or file.content == "" then
            return Http.fail(400, "A photo of the fault is required to propose a part")
        end
        if #file.content > 15 * 1024 * 1024 then
            return Http.fail(413, "Photo is too large (max 15MB)")
        end

        -- Upload the evidence first: if MinIO fails we create nothing, so we
        -- never leave an evidence-less proposal behind.
        local url, uerr, meta = MinioClient.quickUpload(file, {
            prefix = "field-service/jobs/" .. job.uuid .. "/photos",
        })
        if not url then return Http.fail(502, "Photo upload failed: " .. tostring(uerr)) end

        -- Create the pending part line. Price/tax come from the caller (the form
        -- copies them off the picked catalogue part) so the invoice is right.
        local item, ierr = JobQueries.addItem(self.namespace.id, self.params.uuid, {
            item_type = "part",
            part_uuid = self.params.part_uuid,
            quantity = self.params.quantity,
            description = self.params.reason or self.params.description,
            unit_price = self.params.unit_price,
            tax_rate = self.params.tax_rate,
            visit_uuid = self.params.visit_uuid,
            is_billable = true,
        }, Http.actor(self))
        if not item then return Http.from_error(ierr) end

        local photo, perr = JobPhotoQueries.addPhoto(self.namespace.id, self.params.uuid, {
            url = url,
            object_key = meta and meta.object_key,
            filename = file.filename,
            content_type = file.content_type,
            caption = "Fault evidence",
            visit_uuid = self.params.visit_uuid,
            item_uuid = item.uuid,
        }, Http.actor(self))
        -- The evidence link is the whole point — if it fails, don't keep a
        -- proposal without it.
        if not photo then
            JobQueries.deleteItem(self.namespace.id, item.uuid, Http.actor(self))
            return Http.fail(502, "Could not attach evidence photo: " .. tostring(perr))
        end

        return Http.ok({ item = item, photo = photo }, 201)
    end))

    -- Evidence photos for a proposed item. Manager (fs_jobs) or the engineer
    -- booked on the job can view them.
    app:get("/api/v2/field-service/job-items/:uuid/photos", Http.route(function(self)
        local item = JobQueries.findItemRow(self.namespace.id, self.params.uuid)
        if not item then return Http.fail(404, "Item not found") end
        if not can_work_job(self, item.job_id, "read") then return Http.forbidden("fs_jobs", "read") end
        return Http.ok(JobPhotoQueries.listByItemId(item.id))
    end))

    -- ============================================================
    -- PHOTOS (site / fault photos for the quote sheet)
    -- ============================================================

    app:get("/api/v2/field-service/jobs/:uuid/photos", Http.route(function(self)
        local row = JobQueries.findJobRow(self.namespace.id, self.params.uuid)
        if not row then return Http.fail(404, "Job not found") end
        if not can_work_job(self, row.id, "update") then return Http.forbidden("fs_jobs", "read") end
        return Http.ok(JobPhotoQueries.listByJobId(row.id))
    end))

    -- Upload one photo (multipart: `photo`|`file`|`image`). The assigned
    -- engineer may add photos on site; the file goes to MinIO.
    app:post("/api/v2/field-service/jobs/:uuid/photos", Http.route(function(self)
        local row = JobQueries.findJobRow(self.namespace.id, self.params.uuid)
        if not row then return Http.fail(404, "Job not found") end
        if not can_work_job(self, row.id, "update") then return Http.forbidden("fs_jobs", "update") end

        local file = self.params.photo or self.params.file or self.params.image
        if type(file) ~= "table" or not file.content or file.content == "" then
            return Http.fail(400, "No photo uploaded (use the 'photo' field)")
        end
        if #file.content > 15 * 1024 * 1024 then
            return Http.fail(413, "Photo is too large (max 15MB)")
        end

        local url, err, meta = MinioClient.quickUpload(file, {
            prefix = "field-service/jobs/" .. row.uuid .. "/photos",
        })
        if not url then return Http.fail(502, "Upload failed: " .. tostring(err)) end

        local photo, perr = JobPhotoQueries.addPhoto(self.namespace.id, self.params.uuid, {
            url = url,
            object_key = meta and meta.object_key,
            filename = file.filename,
            content_type = file.content_type,
            caption = self.params.caption,
            visit_uuid = self.params.visit_uuid,
            item_uuid = self.params.item_uuid,   -- optional: tie to a proposed item
        }, Http.actor(self))
        return Http.result(photo, perr, 201)
    end))

    app:delete("/api/v2/field-service/job-photos/:uuid", Http.route(function(self)
        local job_id = JobPhotoQueries.jobIdForPhoto(self.namespace.id, self.params.uuid)
        if not job_id then return Http.fail(404, "Photo not found") end
        if not can_work_job(self, job_id, "update") then return Http.forbidden("fs_jobs", "update") end
        local ok, err = JobPhotoQueries.deletePhoto(self.namespace.id, self.params.uuid)
        if not ok then return Http.from_error(err) end
        return Http.ok({ message = "Photo removed" })
    end))

    -- ============================================================
    -- INVOICING
    -- ============================================================

    app:get("/api/v2/field-service/jobs/:uuid/invoice-preview", Http.guard("fs_jobs", "read", function(self)
        return Http.result(JobQueries.invoicePreview(self.namespace.id, self.params.uuid, {
            hourly_rate = self.params.hourly_rate,
            labour_tax_rate = self.params.labour_tax_rate,
        }))
    end))

    app:post("/api/v2/field-service/jobs/:uuid/invoice", Http.guard("fs_jobs", "update", function(self)
        if not Http.has_perm(self, "invoices", "create") then return Http.forbidden("invoices", "create") end
        local body = Http.body(self)
        local invoice, err = JobQueries.createInvoice(self.namespace.id, self.params.uuid, Http.actor(self), {
            hourly_rate = body.hourly_rate,
            labour_tax_rate = body.labour_tax_rate,
            due_date = body.due_date,
            notes = body.notes,
        })
        return Http.result(invoice, err, 201)
    end))

    -- ============================================================
    -- QUOTATION
    -- ============================================================

    -- Email the job's quotation PDF to the customer. The browser builds the PDF
    -- from the job's quote-sheet lines (labour / materials / hire) and posts it
    -- as base64; we attach + send and record it in the job activity. This is a
    -- pre-work estimate — it does not touch invoicing.
    app:post("/api/v2/field-service/jobs/:uuid/quote-email", Http.guard("fs_jobs", "update", function(self)
        local body = Http.body(self)
        local pdf_b64 = body.pdf_base64
        if not pdf_b64 or pdf_b64 == "" then return Http.fail(400, "pdf_base64 is required") end

        local job = JobQueries.getJob(self.namespace.id, self.params.uuid)
        if not job then return Http.fail(404, "Job not found") end

        local to = (body.to ~= nil and body.to ~= "" and body.to) or job.customer_email
        if not to or to == "" then
            return Http.fail(400, "No customer email on this job — add one to the customer or pass a recipient")
        end

        local company = self.namespace.name or "Your Company"
        local number = job.job_number or "job"
        local ref = "QUO-" .. number
        local subject = (body.subject ~= nil and body.subject ~= "" and body.subject)
            or ("Quotation " .. ref .. " from " .. company)
        local greeting = job.customer_name and ("Dear " .. tostring(job.customer_name) .. ",") or "Hello,"
        local note = (body.message ~= nil and body.message ~= "") and ("<p>" .. tostring(body.message) .. "</p>") or ""
        local html = table.concat({
            "<p>", greeting, "</p>", note,
            "<p>Please find attached our quotation <strong>", ref, "</strong> for ",
            tostring(job.title or "the requested work"), ".</p>",
            "<p>This quotation is valid for 30 days. Let us know if you'd like to go ahead.</p>",
            "<p>Thank you,<br>", company, "</p>",
        })
        local filename = (body.filename ~= nil and body.filename ~= "" and body.filename) or ("Quote-" .. number .. ".pdf")

        local ok, mail_err = Mail.send({
            to = to,
            subject = subject,
            html = html,
            attachments = {
                { filename = filename, content_type = "application/pdf", content_b64 = pdf_b64 },
            },
        })
        if not ok then return Http.fail(502, "Could not send email: " .. tostring(mail_err)) end

        local row = JobQueries.findJobRow(self.namespace.id, self.params.uuid)
        if row then
            Common.log_activity(self.namespace.id, row.id, Http.actor(self), "quote_sent",
                "Quotation emailed to " .. to, { to = to, ref = ref })
        end
        return Http.ok({ message = "Quotation emailed to " .. to, to = to })
    end))
end
