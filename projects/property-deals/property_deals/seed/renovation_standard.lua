-- Standard UK refurb: board columns are the build stages, cards the jobs.
-- `day` / `days` are offsets from the start date on a ~50-day plan; when the
-- user gives a target end date the plan is stretched or squeezed to fit.
return {
    key = "standard",
    name = "Standard refurbishment",
    days = 50,
    stages = {
        { name = "Survey & quotes", color = "#6B7280", jobs = {
            { "Survey and schedule of works", 0, 3, "high" },
            { "Get three builder quotes", 0, 7, "high" },
            { "Check planning / building control / party wall", 0, 7, "medium" },
            { "Order long-lead items (kitchen, windows, doors)", 5, 3, "medium" },
        } },
        { name = "Strip-out", color = "#64748B", jobs = {
            { "Asbestos check before demolition", 7, 1, "critical" },
            { "Strip-out and skip hire", 8, 5, "medium" },
        } },
        { name = "Structural", color = "#B45309", jobs = {
            { "Structural work (walls, beams, damp)", 13, 10, "high" },
            { "Roof, gutters and windows", 13, 6, "medium" },
        } },
        { name = "First fix", color = "#3B82F6", jobs = {
            { "First-fix electrics", 23, 4, "medium" },
            { "First-fix plumbing and heating", 23, 4, "medium" },
        } },
        { name = "Plastering", color = "#8B5CF6", jobs = {
            { "Boarding and skim", 27, 6, "medium" },
        } },
        { name = "Second fix", color = "#0EA5E9", jobs = {
            { "Kitchen install", 33, 4, "medium" },
            { "Bathroom install", 33, 4, "medium" },
            { "Second-fix electrics and plumbing", 37, 3, "medium" },
        } },
        { name = "Decorating", color = "#F59E0B", jobs = {
            { "Decorating", 40, 5, "medium" },
            { "Flooring", 44, 3, "medium" },
        } },
        { name = "Snagging & sign-off", color = "#EF4444", jobs = {
            { "Snagging walk-round", 47, 2, "high" },
            { "Certificates: EICR, gas safe, building control, EPC", 47, 3, "high" },
            { "Final clean and photos", 49, 1, "low" },
        } },
        { name = "Done", color = "#10B981", done = true, jobs = {} },
    },
}
