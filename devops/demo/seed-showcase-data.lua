-- Sample business data for the `showcase` workspace, so every app on the
-- full demo (PROJECT_CODE=all, values-opsapi-showcase.yaml) has something to
-- show. Run AFTER seed-showcase.lua. Safe to re-run: a module that already has
-- rows in `showcase` is skipped, and a module whose tables don't exist on this
-- deployment is reported and skipped. All names, emails and figures are made up.
--
--   kubectl -n demo cp devops/demo/seed-showcase-data.lua <api-pod>:/tmp/seed-showcase-data.lua
--   kubectl -n demo exec <api-pod> -- sh -c 'cd /app && \
--     lapis exec "assert(loadfile(\"/tmp/seed-showcase-data.lua\"))()"'
local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")

local ns = db.select("id FROM namespaces WHERE slug = 'showcase'")[1]
assert(ns, "run seed-showcase.lua first (no `showcase` namespace)")
local owner = db.select([[u.id, u.uuid FROM users u JOIN namespaces n ON n.owner_user_id = u.id
                          WHERE n.id = ?]], ns.id)[1]
assert(owner, "showcase has no owner")

local uuid = Global.generateUUID
local function ago(days) return db.raw(("NOW() - INTERVAL '%d days'"):format(days)) end
local function ahead(days) return db.raw(("NOW() + INTERVAL '%d days'"):format(days)) end
local function date_ago(days) return db.raw(("CURRENT_DATE - %d"):format(days)) end
local function date_ahead(days) return db.raw(("CURRENT_DATE + %d"):format(days)) end
local function insert(tbl, row) return db.insert(tbl, row, "id")[1].id end

local report = {}
-- Seed one module: skipped when `tbl` is missing or already has showcase rows.
local function seed(name, tbl, fn)
    if #db.select("1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = ?", tbl) == 0 then
        table.insert(report, name .. ": not on this deployment")
        return
    end
    if #db.select("1 FROM " .. db.escape_identifier(tbl) .. " WHERE namespace_id = ? LIMIT 1", ns.id) > 0 then
        table.insert(report, name .. ": already seeded")
        return
    end
    local ok, err = pcall(function()
        db.query("SAVEPOINT seed_module")
        fn()
        db.query("RELEASE SAVEPOINT seed_module")
    end)
    if not ok then
        pcall(db.query, "ROLLBACK TO SAVEPOINT seed_module")
        table.insert(report, name .. ": FAILED " .. tostring(err))
    else
        table.insert(report, name .. ": seeded")
    end
end

db.query("BEGIN")

seed("CRM", "crm_accounts", function()
    local stages = { "prospecting", "qualification", "proposal", "negotiation", "closed_won", "closed_lost" }
    local pipeline = insert("crm_pipelines", {
        uuid = uuid(), namespace_id = ns.id, name = "Sales", description = "New business",
        stages = cjson.encode(stages), is_default = true, created_at = ago(90), updated_at = ago(90),
    })
    local accounts = {
        { "Northwind Logistics", "Logistics", "Manchester", "northwind.example.com" },
        { "Brightwater Clinics", "Healthcare", "Leeds", "brightwater.example.com" },
        { "Juniper & Finch", "Retail", "Bristol", "juniperfinch.example.com" },
        { "Copperleaf Studios", "Media", "London", "copperleaf.example.com" },
        { "Halden Engineering", "Manufacturing", "Sheffield", "halden.example.com" },
    }
    local people = {
        { "Grace", "Holloway", "Operations Director" }, { "Samuel", "Achebe", "Practice Manager" },
        { "Isla", "Moreno", "Head of Buying" }, { "Theo", "Lindqvist", "Creative Director" },
        { "Priya", "Raman", "Plant Manager" },
    }
    local deals = {
        { "Fleet tracking rollout", 48000, "negotiation", 70 }, { "Patient portal", 26500, "proposal", 50 },
        { "Spring stock system", 12000, "closed_won", 100 }, { "Asset library", 8400, "qualification", 30 },
        { "Shop-floor tablets", 31000, "prospecting", 10 },
    }
    for i, a in ipairs(accounts) do
        local account = insert("crm_accounts", {
            uuid = uuid(), namespace_id = ns.id, name = a[1], industry = a[2], city = a[3],
            country = "United Kingdom", website = "https://" .. a[4], email = "hello@" .. a[4],
            owner_user_uuid = owner.uuid, status = "active", created_at = ago(80 - i * 5), updated_at = ago(10),
        })
        local p = people[i]
        local contact = insert("crm_contacts", {
            uuid = uuid(), namespace_id = ns.id, account_id = account, first_name = p[1], last_name = p[2],
            email = p[1]:lower() .. "@" .. a[4], job_title = p[3], owner_user_uuid = owner.uuid,
            status = "active", created_at = ago(70 - i * 5), updated_at = ago(10),
        })
        local d = deals[i]
        insert("crm_deals", {
            uuid = uuid(), namespace_id = ns.id, pipeline_id = pipeline, account_id = account, contact_id = contact,
            name = d[1], value = d[2], currency = "GBP", stage = d[3], probability = d[4],
            expected_close_date = date_ahead(i * 9), owner_user_uuid = owner.uuid,
            status = d[3] == "closed_won" and "won" or "open", created_at = ago(40 - i * 3), updated_at = ago(i),
        })
    end
end)

seed("Leads", "crm_leads", function()
    local leads = {
        { "Ella", "Carter", "Carter Bakeries", "website", "new" }, { "Jonas", "Weber", "Weber Freight", "referral", "contacted" },
        { "Amara", "Nwosu", "Nwosu Dental", "event", "qualified" }, { "Felix", "Tan", "Tan Architects", "website", "new" },
    }
    for i, l in ipairs(leads) do
        insert("crm_leads", {
            uuid = uuid(), namespace_id = ns.id, first_name = l[1], last_name = l[2], company_name = l[3],
            email = l[1]:lower() .. "@example.com", source = l[4], status = l[5], score = 90 - i * 12,
            owner_user_uuid = owner.uuid, created_at = ago(i * 2), updated_at = ago(i),
        })
    end
end)

seed("Invoices", "invoices", function()
    local invoices = {
        { "Northwind Logistics", "paid", 30, 4200 }, { "Brightwater Clinics", "sent", 12, 2650 },
        { "Juniper & Finch", "overdue", 45, 1800 }, { "Copperleaf Studios", "draft", 1, 960 },
        { "Halden Engineering", "partially_paid", 20, 5400 },
    }
    for i, inv in ipairs(invoices) do
        local subtotal = inv[4]
        local tax = subtotal * 0.2
        local total = subtotal + tax
        local paid = inv[2] == "paid" and total or inv[2] == "partially_paid" and total / 2 or 0
        local id = insert("invoices", {
            uuid = uuid(), namespace_id = ns.id, invoice_number = ("INV-%04d"):format(1000 + i),
            customer_name = inv[1], customer_email = "accounts@example.com", status = inv[2],
            issue_date = date_ago(inv[3]), due_date = date_ago(inv[3] - 30), currency = "GBP",
            subtotal = subtotal, tax_amount = tax, total_amount = total, amount_paid = paid,
            balance_due = total - paid, payment_terms_days = 30, owner_user_uuid = owner.uuid,
            created_at = ago(inv[3]), updated_at = ago(1),
        })
        insert("invoice_line_items", {
            uuid = uuid(), invoice_id = id, description = "Consulting (days)", quantity = subtotal / 600,
            unit_price = 600, tax_rate = 20, tax_amount = tax, line_total = subtotal, sort_order = 1,
            created_at = ago(inv[3]), updated_at = ago(inv[3]),
        })
    end
end)

seed("Projects (Kanban)", "kanban_projects", function()
    local KanbanProjectQueries = require("queries.KanbanProjectQueries")
    local projects = {
        { "Website relaunch", "#6366F1", { "Write homepage copy", "Pick photography", "Set up redirects", "Launch checklist" } },
        { "Mobile app v2", "#10B981", { "Offline mode", "Push notifications", "App Store screenshots" } },
    }
    for _, p in ipairs(projects) do
        local project = KanbanProjectQueries.create({
            namespace_id = ns.id, name = p[1], color = p[2], owner_user_uuid = owner.uuid, visibility = "internal",
            budget_currency = "GBP", start_date = date_ago(30), due_date = date_ahead(45),
        })
        local columns = db.select([[c.id, c.board_id, c.is_done_column FROM kanban_columns c
            JOIN kanban_boards b ON b.id = c.board_id WHERE b.project_id = ? ORDER BY c.position]], project.id)
        for i, title in ipairs(p[3]) do
            local col = columns[((i - 1) % #columns) + 1]
            insert("kanban_tasks", {
                uuid = uuid(), board_id = col.board_id, column_id = col.id, task_number = i, title = title,
                status = col.is_done_column and "completed" or (i == 2 and "in_progress" or "open"),
                priority = ({ "high", "medium", "low", "medium" })[i], position = i,
                reporter_user_uuid = owner.uuid, due_date = date_ahead(i * 5),
                created_at = ago(20 - i), updated_at = ago(i),
            })
        end
        db.query("UPDATE kanban_projects SET task_count = ? WHERE id = ?", #p[3], project.id)
    end
end)

seed("Timesheets", "timesheets", function()
    local entries = { { 7, "Northwind Logistics", 7.5, "approved" }, { 6, "Brightwater Clinics", 6, "approved" },
        { 3, "Copperleaf Studios", 8, "submitted" }, { 1, "Halden Engineering", 4.5, "draft" } }
    for _, e in ipairs(entries) do
        insert("timesheets", {
            uuid = uuid(), namespace_id = ns.id, user_uuid = owner.uuid, period_start = date_ago(e[1]),
            period_end = date_ago(e[1]), work_date = date_ago(e[1]), client_name = e[2], task = "Client work",
            total_hours = e[3], billable_hours = e[3], is_billable = true, hourly_rate = 75, status = e[4],
            created_at = ago(e[1]), updated_at = ago(e[1]),
        })
    end
end)

seed("Shop & orders", "stores", function()
    local store = insert("stores", {
        uuid = uuid(), namespace_id = ns.id, user_id = owner.id, name = "Showcase Outfitters",
        slug = "showcase-outfitters", description = "Outdoor gear, made up for the demo",
        contact_email = "shop@example.com", country = "United Kingdom", currency = "GBP", status = "active",
        tax_rate = 0.2, created_at = ago(60), updated_at = ago(5),
    })
    local products = { { "Trail backpack 30L", 89 }, { "Merino base layer", 55 }, { "Insulated bottle", 24 },
        { "Rain shell jacket", 145 }, { "Camp stove", 62 } }
    for i, pr in ipairs(products) do
        insert("storeproducts", {
            uuid = uuid(), namespace_id = ns.id, store_id = store, name = pr[1],
            slug = pr[1]:lower():gsub("[^%w]+", "-"), sku = ("SKU-%03d"):format(i), price = pr[2], compare_price = pr[2],
            inventory_quantity = 40 - i * 6, track_inventory = true, is_active = true,
            created_at = ago(50), updated_at = ago(5),
        })
    end
    local orders = { { "delivered", "paid", 144 }, { "shipped", "paid", 89 }, { "processing", "paid", 207 },
        { "pending", "pending", 55 }, { "cancelled", "voided", 62 } }
    for i, o in ipairs(orders) do
        insert("orders", {
            uuid = uuid(), namespace_id = ns.id, store_id = store, order_number = ("SO-%05d"):format(20400 + i),
            status = o[1], financial_status = o[2], subtotal = o[3], total_amount = o[3] * 1.2,
            tax_amount = o[3] * 0.2, currency = "GBP", created_at = ago(i * 3), updated_at = ago(i),
        })
    end
end)

seed("Hospital", "hospitals", function()
    local hospital = insert("hospitals", {
        uuid = uuid(), namespace_id = ns.id, name = "Riverside Care Centre", type = "care_home",
        license_number = "DEMO-CQC-0001", city = "York", country = "United Kingdom", capacity = 60,
        phone = "01904 000000", status = "active", created_at = ago(120), updated_at = ago(3),
    })
    local patients = { { "Margaret", "Hale", "1938-04-12", "female", "12A" }, { "Harold", "Finch", "1941-09-30", "male", "14B" },
        { "Edith", "Crane", "1935-01-22", "female", "3C" } }
    for i, p in ipairs(patients) do
        insert("patients", {
            uuid = uuid(), hospital_id = hospital, patient_id = ("RCC-%03d"):format(i), first_name = p[1],
            last_name = p[2], date_of_birth = p[3], gender = p[4], room_number = p[5], status = "active",
            admission_date = date_ago(200 - i * 40), created_at = ago(200 - i * 40), updated_at = ago(i),
        })
    end
end)

seed("CMS", "cms_pages", function()
    for i, pg in ipairs({ { "Home", "home" }, { "About us", "about" }, { "Contact", "contact" } }) do
        insert("cms_pages", {
            uuid = uuid(), namespace_id = ns.id, title = pg[1], slug = pg[2], status = "published",
            content_html = "<p>Sample " .. pg[1]:lower() .. " page for the OpsAPI demo.</p>", menu_order = i,
            show_in_nav = true, author_uuid = owner.uuid, published_at = ago(30), created_at = ago(30), updated_at = ago(2),
        })
    end
    for i, post in ipairs({ "Five ways to tidy your bookkeeping", "What we learned shipping v2", "Spring opening hours" }) do
        insert("cms_posts", {
            uuid = uuid(), namespace_id = ns.id, title = post, slug = post:lower():gsub("[^%w]+", "-"),
            excerpt = "A sample article for the demo.", content_html = "<p>Sample article body.</p>",
            status = i == 3 and "draft" or "published", visibility = "public", author_uuid = owner.uuid,
            author_name = "Ava Patel", reading_minutes = 3 + i, published_at = i == 3 and db.NULL or ago(i * 7),
            created_at = ago(i * 7), updated_at = ago(i),
        })
    end
end)

seed("Academy", "academy_courses", function()
    for i, c in ipairs({ { "Getting started with OpsAPI", "beginner" }, { "Running payroll-ready timesheets", "intermediate" } }) do
        insert("academy_courses", {
            uuid = uuid(), namespace_id = ns.id, title = c[1], slug = c[1]:lower():gsub("[^%w]+", "-"),
            description = "A sample course for the demo.", level = c[2], status = "published", is_free = true,
            duration_minutes = 45 * i, owner_user_uuid = owner.uuid, created_at = ago(25), updated_at = ago(4),
        })
    end
end)

seed("Forms", "forms", function()
    local schema = { fields = {
        { key = "name", type = "text", label = "Your name", required = true },
        { key = "email", type = "email", label = "Email", required = true },
        { key = "message", type = "textarea", label = "How can we help?" },
    } }
    insert("forms", {
        uuid = uuid(), namespace_id = ns.id, public_id = uuid():gsub("-", ""):sub(1, 12), -- varchar(16)
        title = "Contact us", description = "Sample enquiry form", status = "draft",
        draft_schema = cjson.encode(schema), created_by_uuid = owner.uuid, created_at = ago(14), updated_at = ago(2),
    })
end)

seed("Hiring", "ats_jobs", function()
    for _, j in ipairs({ { "Frontend engineer", "Engineering", "open" }, { "Customer success lead", "Support", "open" },
                         { "Office manager", "Operations", "paused" } }) do
        insert("ats_jobs", {
            uuid = uuid(), namespace_id = ns.id, title = j[1], department = j[2], location = "Remote (UK)",
            employment_type = "Full-time", status = j[3], description = "A sample role for the demo.",
            created_by_uuid = owner.uuid, created_at = ago(20), updated_at = ago(3),
        })
    end
    for _, c in ipairs({ "Ruby Sinclair", "Daniel Osei", "Hannah Kowalski", "Marco Bianchi" }) do
        insert("ats_candidates", {
            uuid = uuid(), namespace_id = ns.id, name = c, source = "careers page",
            email = c:lower():gsub(" ", ".") .. "@example.com", created_at = ago(9), updated_at = ago(2),
        })
    end
end)

seed("Field service", "fs_jobs", function()
    local jobs = { { "Boiler service", "scheduled", "normal", "maintenance" }, { "Leak call-out", "in_progress", "urgent", "callout" },
        { "Air-con install", "draft", "normal", "project" }, { "Annual safety check", "completed", "low", "service" } }
    for i, j in ipairs(jobs) do
        insert("fs_jobs", {
            uuid = uuid(), namespace_id = ns.id, job_number = ("JOB-%04d"):format(300 + i), title = j[1], status = j[2],
            priority = j[3], kind = j[4], due_date = date_ahead(i * 3), service_postcode = "LS1 4AP",
            created_by_uuid = owner.uuid, created_at = ago(10 - i), updated_at = ago(1),
        })
    end
end)

db.query("COMMIT")
for _, line in ipairs(report) do print(line) end
