--[[
    Spec: PDF statement rows get the right direction (money in vs money out)
    whatever the column alignment, via Extraction.extract_from_text on
    pdftotext -layout style text.

    Regression: on a statement whose amounts are RIGHT-aligned under the
    "Money out / Money in / Balance" headings, every row came out flipped —
    a £6,000 client receipt was saved as a DEBIT and every expense as a CREDIT.

    Run inside the API container:
        docker exec -w /app opsapi /usr/local/openresty/luajit/bin/luajit spec/tax-extraction-columns_spec.lua
]]

package.path = "./?.lua;lapis/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

local Extraction = require("lib.tax-extraction")

local function by_description(result)
    local out = {}
    for _, t in ipairs(result.transactions) do out[t.description] = t end
    return out
end

print("right-aligned amounts with em-dash placeholders (pdftotext -layout of a real PDF)")
do
    local text = table.concat({
        "     Date             Description                                          Money out (£)           Money in (£)            Balance (£)",
        "",
        "     01/09/2026       CONSULTING INVOICE                                                     —               £6,000.00              £23,920.07",
        "",
        "     02/09/2026       COUNCIL TAX                                                      £150.24                       —              £23,769.83",
        "",
        "     02/09/2026       INSURANCE PAYMENT                                                  £95.59                      —              £23,674.24",
    }, "\n")
    local res = Extraction.extract_from_text(text)
    local tx = by_description(res)
    check("three rows parsed", res.count == 3, res.count)
    local c = tx["CONSULTING INVOICE"]
    check("client receipt is a CREDIT of 6000", c and c.transaction_type == "CREDIT" and c.amount == 6000,
        c and (c.transaction_type .. " " .. c.amount))
    check("client receipt balance read from Balance column", c and c.balance == 23920.07, c and c.balance)
    local ct = tx["COUNCIL TAX"]
    check("expense is a DEBIT of 150.24", ct and ct.transaction_type == "DEBIT" and ct.amount == 150.24,
        ct and (ct.transaction_type .. " " .. ct.amount))
    local ins = tx["INSURANCE PAYMENT"]
    check("narrower expense is a DEBIT of 95.59", ins and ins.transaction_type == "DEBIT" and ins.amount == 95.59,
        ins and (ins.transaction_type .. " " .. ins.amount))
end

print("left-aligned amounts under the headings")
do
    local text = table.concat({
        "Date        Description                 Paid out    Paid in     Balance",
        "03/04/2026  CARD PAYMENT TESCO          42.10                   1,957.90",
        "04/04/2026  FASTER PAYMENT ACME LTD                 1,500.00    3,457.90",
    }, "\n")
    local tx = by_description(Extraction.extract_from_text(text))
    local t = tx["CARD PAYMENT TESCO"]
    check("left-aligned paid out is a DEBIT", t and t.transaction_type == "DEBIT" and t.amount == 42.10,
        t and (t.transaction_type .. " " .. t.amount))
    local a = tx["FASTER PAYMENT ACME LTD"]
    check("left-aligned paid in is a CREDIT", a and a.transaction_type == "CREDIT" and a.amount == 1500,
        a and (a.transaction_type .. " " .. a.amount))
end

print("a number inside the description is not taken as an amount")
do
    local text = table.concat({
        "Date        Description                 Paid out    Paid in     Balance",
        "05/04/2026  REFUND ORDER 12.50 X                    12.50       3,470.40",
    }, "\n")
    local res = Extraction.extract_from_text(text)
    local t = res.transactions[1]
    check("row is a CREDIT of 12.50 with the right balance",
        t and t.transaction_type == "CREDIT" and t.amount == 12.5 and t.balance == 3470.40,
        t and (t.transaction_type .. " " .. t.amount .. " bal " .. tostring(t.balance)))
end

if failures > 0 then
    print(string.format("\n%d check(s) failed", failures))
    os.exit(1)
end
print("\nall checks passed")
