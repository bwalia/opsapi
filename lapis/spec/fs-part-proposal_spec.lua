--[[
    Regression spec for the engineer part-replacement proposal.

    Standalone — no busted/luarocks needed. Run from the repo root with:
        luajit lapis/spec/fs-part-proposal_spec.lua

    The feature's whole point is anti-fraud: an engineer proposes a part from the
    EXISTING catalogue and MUST attach photo evidence, which the manager reviews
    before approving (an approved part is what reaches the invoice). These are
    the easy invariants to regress, so they're asserted against the source:

      1. a proposal cannot be created without a photo (server-enforced);
      2. proposal photos link to the specific item (fs_job_photos.job_item_id);
      3. the engineer picks a catalogue part (part_uuid), not free text;
      4. the manager can see the evidence on a pending item.
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
    local h = assert(io.open(path))
    local s = h:read("*a")
    h:close()
    return s
end

-- ── Schema: photos can be tied to a specific proposed item ──
print("schema:")
local mig = read("lapis/migrations/field-service-photos.lua")
check("fs_job_photos gains job_item_id (nullable FK, CASCADE)",
    mig:find("job_item_id BIGINT REFERENCES fs_job_items(id) ON DELETE CASCADE", 1, true) ~= nil)
local reg = read("lapis/migrations.lua")
check("migration registered (921, sorts after 890 so the table exists)",
    reg:find("921_fs_job_photos_add_item_id", 1, true) ~= nil)

-- ── Query layer ──
print("\nqueries:")
local pq = read("lapis/queries/JobPhotoQueries.lua")
check("addPhoto resolves an optional item_uuid link", pq:find("item_uuid", 1, true) ~= nil)
check("listByItemId returns a proposal's evidence", pq:find("function JobPhotoQueries.listByItemId", 1, true) ~= nil)

-- ── Route: the anti-fraud invariants ──
print("\nroute:")
local routes = read("lapis/routes/field-service-jobs.lua")
local ep = routes:match('part%-proposals".-\n    end%)%)')
check("part-proposals endpoint exists", ep ~= nil)
if ep then
    check("a photo is MANDATORY to propose (server-enforced)",
        ep:find("A photo of the fault is required", 1, true) ~= nil)
    check("engineer must pick a catalogue part (part_uuid)",
        ep:find("Select a part from the catalogue", 1, true) ~= nil)
    check("the evidence photo is linked to the created item",
        ep:find("item_uuid = item.uuid", 1, true) ~= nil)
    check("no evidence-less proposal survives (item deleted if photo fails)",
        ep:find("JobQueries.deleteItem", 1, true) ~= nil)
end
check("manager can view a proposed item's evidence photos",
    routes:find('job%-items/:uuid/photos') ~= nil
    and routes:find("JobPhotoQueries.listByItemId", 1, true) ~= nil)

-- ── Frontend wiring ──
print("\nfrontend:")
local modal = read("opsapi-dashboard/components/field-service/PartProposalModal.tsx")
check("proposal form blocks submit without a photo",
    modal:find("photos.length === 0", 1, true) ~= nil)
check("proposal form picks from the catalogue (SearchableSelect)",
    modal:find("SearchableSelect", 1, true) ~= nil)
local mywork = read("opsapi-dashboard/app/dashboard/field-service/my-work/[uuid]/page.tsx")
check("engineer screen opens the proposal modal (not the free-text material form)",
    mywork:find("PartProposalModal", 1, true) ~= nil)

print("")
if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all checks passed")
