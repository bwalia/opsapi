-- Built-in bank holidays, copied into each workspace's property_deals_holidays
-- on setup (editable there). Source: https://www.gov.uk/bank-holidays.json
-- (England and Wales). Other jurisdictions are added as rows per workspace, or
-- by the holiday sync job (Phase 3).
return {
    ["england-and-wales"] = {
        { "2025-01-01", "New Year's Day" }, { "2025-04-18", "Good Friday" }, { "2025-04-21", "Easter Monday" },
        { "2025-05-05", "Early May bank holiday" }, { "2025-05-26", "Spring bank holiday" },
        { "2025-08-25", "Summer bank holiday" }, { "2025-12-25", "Christmas Day" }, { "2025-12-26", "Boxing Day" },

        { "2026-01-01", "New Year's Day" }, { "2026-04-03", "Good Friday" }, { "2026-04-06", "Easter Monday" },
        { "2026-05-04", "Early May bank holiday" }, { "2026-05-25", "Spring bank holiday" },
        { "2026-08-31", "Summer bank holiday" }, { "2026-12-25", "Christmas Day" },
        { "2026-12-28", "Boxing Day (substitute day)" },

        { "2027-01-01", "New Year's Day" }, { "2027-03-26", "Good Friday" }, { "2027-03-29", "Easter Monday" },
        { "2027-05-03", "Early May bank holiday" }, { "2027-05-31", "Spring bank holiday" },
        { "2027-08-30", "Summer bank holiday" }, { "2027-12-27", "Christmas Day (substitute day)" },
        { "2027-12-28", "Boxing Day (substitute day)" },

        { "2028-01-03", "New Year's Day (substitute day)" }, { "2028-04-14", "Good Friday" },
        { "2028-04-17", "Easter Monday" }, { "2028-05-01", "Early May bank holiday" },
        { "2028-05-29", "Spring bank holiday" }, { "2028-08-28", "Summer bank holiday" },
        { "2028-12-25", "Christmas Day" }, { "2028-12-26", "Boxing Day" },
    },
}
