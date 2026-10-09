--[[
    Regression spec: the form builder (docs/FORM_BUILDER_PLAN.md).

    Standalone — run from the repo root in the OpenResty image (needs cjson):
        luajit lapis/spec/forms_spec.lua

    Field validation, schema normalisation (contact fields added and locked
    for targets), CSV escaping, and the wiring that keeps the module gated,
    tenant-scoped and out of the audit trail. The live behaviour (records,
    links, emails, isolation, concurrency) is proven by spec/forms-e2e/run.sh.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end
local function read(path)
    local h = io.open(path) or assert(io.open((path:gsub("^lapis/", ""))))
    local s = h:read("*a")
    h:close()
    return s
end
local function has(s, needle) return s:find(needle, 1, true) ~= nil end

local ok_mod, Fields = pcall(require, "lib.forms.fields")
if not ok_mod then
    check("lib.forms.fields loads (needs cjson: run in the OpenResty image)", false, Fields)
    os.exit(1)
end
local cjson = require("lib.forms.json")
local ROLES = { ["contact.name"] = true, ["contact.email"] = true }

print("normalize: contact fields for targets")
local s = assert(Fields.normalize({ fields = { { type = "short_text", label = "Company" } } }, ROLES))
check("name then email are added at the top, required and locked",
    s.fields[1].system == "contact.name" and s.fields[2].system == "contact.email"
    and s.fields[1].required and s.fields[2].required and s.fields[3].label == "Company")
check("keys come from labels",
    s.fields[1].key == "name" and s.fields[2].key == "email" and s.fields[3].key == "company")

local again = assert(Fields.normalize({ fields = { s.fields[3], s.fields[1] } }, ROLES))
check("a removed locked field comes back, right after the name", again.fields[1].key == "company"
    and again.fields[2].system == "contact.name" and again.fields[3].system == "contact.email")

local s2 = assert(Fields.normalize({ fields = { { type = "email", label = "Work email" } } }, ROLES))
check("an existing email question is promoted instead of adding a second one",
    #s2.fields == 2 and s2.fields[2].key == "work_email" and s2.fields[2].system == "contact.email")

local s3 = assert(Fields.normalize({ fields = {
    { type = "name", label = "Name", system = "contact.name", required = false },
    { type = "email", label = "Email", system = "contact.email" } } }, ROLES))
check("a locked field can't be made optional", s3.fields[1].required == true)
local s4 = assert(Fields.normalize({ fields = { { type = "short_text", label = "Email", system = "contact.email" } } },
    { ["contact.email"] = true }))
check("a locked field's type can't change", s4.fields[1].type == "email")
local s5 = assert(Fields.normalize(s.fields and { fields = s.fields } or {}, {}))
check("turning the targets off unlocks the fields", s5.fields[1].system == nil and s5.fields[2].system == nil)

check("unknown type rejected with the valid list",
    select(2, Fields.normalize({ fields = { { type = "colour", label = "X" } } }, {})):find("unknown type", 1, true))
check("choice field needs options", Fields.normalize({ fields = { { type = "radio", label = "X" } } }, {}) == nil)
check("duplicate option values rejected",
    Fields.normalize({ fields = { { type = "radio", label = "X", options = { "A", "a" } } } }, {}) == nil)
check("maps_to must fit the type",
    Fields.normalize({ fields = { { type = "number", label = "N", maps_to = "phone" } } }, {}) == nil)
local many = {}
for i = 1, Fields.MAX_FIELDS + 1 do many[i] = { type = "short_text", label = "Q" .. i } end
check("at most " .. Fields.MAX_FIELDS .. " fields", Fields.normalize({ fields = many }, {}) == nil)
local dup = assert(Fields.normalize({ fields = {
    { type = "short_text", label = "Q" }, { type = "short_text", label = "Q" } } }, {}))
check("duplicate labels get distinct keys", dup.fields[1].key ~= dup.fields[2].key)
check("unknown properties are dropped",
    assert(Fields.normalize({ fields = { { type = "short_text", label = "Q", onclick = "x" } } }, {}))
        .fields[1].onclick == nil)

print("validate: answers")
local form = assert(Fields.normalize({ fields = {
    { type = "short_text", label = "Company", validation = { max_length = 5 } },
    { type = "number", label = "Age", validation = { min = 18, integer = true } },
    { type = "multi_select", label = "Pick", options = { "A", "B", "C" }, validation = { max_selected = 2 } },
    { type = "boolean", label = "Subscribe", required = true },
    { type = "consent", label = "Terms", text = "I agree", required = true },
    { type = "date", label = "When" },
    { type = "rating", label = "Rate", scale = 5 },
    { type = "heading", label = "Section" },
} }, ROLES))
local good, errs = Fields.validate(form, {
    name = "Ann Lee", email = "ann@example.com", company = "Acme", age = "30", pick = { "a", "b", "a" },
    subscribe = false, terms = true, when = "2026-02-28", rate = 4, section = "ignored", junk = "dropped",
})
check("valid answers pass", good ~= nil, errs and cjson.encode(errs))
good = good or {}
check("a name string is split into first/last", good.name and good.name.first == "Ann" and good.name.last == "Lee")
check("numbers coerced, duplicates in a multi-select removed", good.age == 30 and #good.pick == 2)
check("required yes/no accepts 'no'", good.subscribe == false)
check("display-only and unknown keys are dropped", good.section == nil and good.junk == nil)
local _, e = Fields.validate(form, { name = { first = "", last = "" }, email = "bad", company = "Too long",
    age = 17.5, pick = { "a", "b", "c" }, terms = false, when = "2026-02-30", rate = 6 })
check("every bad answer has its own error", e and e.name and e.email and e.company and e.age and e.pick
    and e.subscribe and e.terms and e.when and e.rate, e and cjson.encode(e))
check("an unticked required consent is 'must be ticked'", e and e.terms == "must be ticked")
check("invalid UTF-8 is refused", select(2, Fields.validate(form, { company = "\255\254", name = "A", email = "a@b.co",
    subscribe = true, terms = true })).company ~= nil)

print("logic and steps")
local lf = assert(Fields.normalize({ fields = {
    { type = "radio", label = "Plan", options = { "Basic", "Pro" }, required = true },
    { type = "short_text", label = "Team size", required = true,
      logic = { match = "all", rules = { { field = "plan", op = "eq", value = "pro" } } } },
    { type = "page_break", label = "" },
    { type = "multi_select", label = "Extras", options = { "A", "B" } },
    { type = "short_text", label = "Why A", logic = { match = "any", rules = {
        { field = "extras", op = "contains", value = "a" }, { field = "plan", op = "in", value = { "pro" } } } } },
} }, {}))
check("a page break needs no label", lf.fields[3].type == "page_break")
local v1 = Fields.validate(lf, { plan = "basic", team_size = "9", extras = { "b" }, why_a = "x" })
check("hidden questions take no answer", v1 and v1.team_size == nil and v1.why_a == nil)
local _, e1 = Fields.validate(lf, { plan = "pro" })
check("a shown required question is required", e1 and e1.team_size == "is required")
local v2 = Fields.validate(lf, { plan = "basic", extras = { "a" }, why_a = "because" })
check("'any' + contains on a multi-select", v2 and v2.why_a == "because")
check("a rule can't point below its question", Fields.normalize({ fields = {
    { type = "short_text", label = "One", logic = { rules = { { field = "two", op = "filled" } } } },
    { type = "short_text", label = "Two" } } }, {}) == nil)
check("a rule's value must be one of the options", Fields.normalize({ fields = {
    { type = "radio", label = "R", options = { "X" } },
    { type = "short_text", label = "T", logic = { rules = { { field = "r", op = "eq", value = "nope" } } } } } }, {}) == nil)
check("locked contact fields can't be hidden", assert(Fields.normalize({ fields = {
    { type = "boolean", label = "Q" },
    { type = "email", label = "Email", system = "contact.email", logic = { rules = { { field = "q", op = "eq", value = true } } } },
} }, { ["contact.email"] = true })).fields[2].logic == nil)

print("file questions")
local ff = assert(Fields.normalize({ fields = { { type = "file_upload", label = "CV", max_files = 2, accept = "documents" } } }, {}))
check("file question settings", ff.fields[1].max_files == 2 and ff.fields[1].max_size_mb == 10 and ff.fields[1].accept == "documents")
local U1 = "9e98ab27-846a-43c3-9473-64668b0c7859"
check("the answer is upload ids", Fields.validate(ff, { cv = { U1 } }).cv[1] == U1)
check("stored details are accepted again (retry)", Fields.validate(ff, { cv = { { id = U1, name = "cv.pdf" } } }).cv[1] == U1)
check("too many files refused", select(2, Fields.validate(ff, { cv = { U1, U1, U1 } })).cv ~= nil)
check("no SVG or HTML among allowed files", Fields.FILE_TYPES.svg == nil and Fields.FILE_TYPES.html == nil
    and Fields.FILE_TYPES.png[2] == "images" and Fields.FILE_TYPES.pdf[2] == "documents")
check("file answers show their names", Fields.show(ff.fields[1], { { id = U1, name = "cv.pdf" } }) == "cv.pdf")

print("contact + display")
local contact, mapped = Fields.contact(assert(Fields.normalize({ fields = {
    { type = "phone", label = "Phone", maps_to = "phone" } } }, ROLES)),
    { name = { first = "Ann", last = "" }, email = "a@b.co", phone = "+44 20 7946 0000" })
check("contact and mapped values extracted", contact.email == "a@b.co" and contact.first_name == "Ann"
    and mapped.phone == "+44 20 7946 0000")
check("multi-select shows its option labels",
    Fields.show(form.fields[5], { "a", "c" }) == "A, C")

print("CSV")
check("formulas defused", Fields.csv_cell("=SUM(A1)") == "'=SUM(A1)" and Fields.csv_cell("+1") == "'+1"
    and Fields.csv_cell("@x") == "'@x" and Fields.csv_cell("-2") == "'-2")
check("quotes, commas and newlines quoted", Fields.csv_cell('a,"b"\nc') == '"a,""b""\nc"')

print("JSON")
check("an empty object stays an object", cjson.encode({}) == "{}")
check("an empty list stays a list", cjson.encode(setmetatable({}, cjson.array_mt)) == "[]")

print("wiring")
local app = read("lapis/app.lua")
check("admin + public routes load only with the forms feature",
    has(app, 'load_if("forms", "routes.forms")') and has(app, 'load_if("forms", "routes.forms-public")'))
check("migrations are gated on the same feature", has(read("lapis/migrations.lua"),
    'load_if_enabled(ProjectConfig.FEATURES.FORMS, "migrations.forms")'))
local cfg = read("lapis/helper/project-config.lua")
check("tax_copilot preset doesn't include forms (diy opts in with ,forms)",
    not cfg:match("tax_copilot = {[^}]*FEATURES%.FORMS"))
check("forms is a feature-only code", cfg:match("FEATURE_ONLY_CODES = {[^}]*forms = true") ~= nil)
check("public routes live under /api/v2/public/", has(read("lapis/routes/forms-public.lua"),
    '"/api/v2/public/forms/:public_id/submissions"'))
local events = read("lapis/helper/plugin-events.lua")
check("responses stay out of the audit trail",
    has(events, 'entity = "form.submission"') and has(events, "audit = false"))
local routes = read("lapis/routes/forms.lua")
local unguarded = 0
for line in routes:gmatch("app:[a-z]+%([^\n]+") do
    if not line:find("guard%(") then unguarded = unguarded + 1 end
end
check("every admin route is permission-guarded", unguarded == 0, unguarded .. " unguarded")
check("every form lookup is namespace-scoped", has(read("lapis/queries/FormQueries.lua"),
    "WHERE f.namespace_id = ? AND f.uuid = ? AND f.deleted_at IS NULL"))
check("responses are reached only through their form", has(read("lapis/queries/FormSubmissionQueries.lua"),
    "WHERE s.form_id = ? AND s.uuid = ?"))
local OFFSET = "OFFSET%s+[%?%d]"
check("lists are keyset-paged (no OFFSET)", not read("lapis/queries/FormSubmissionQueries.lua"):find(OFFSET)
    and not read("lapis/queries/FormQueries.lua"):find(OFFSET))
check("the agent can't publish without asking", has(read("lapis/lib/agent/tools.lua"), 'name = "publish_form"')
    and read("lapis/lib/agent/tools.lua"):match('name = "publish_form".-confirm = function') ~= nil)

print("")
print(failures == 0 and "All checks passed." or (failures .. " check(s) failed."))
os.exit(failures == 0 and 0 or 1)
