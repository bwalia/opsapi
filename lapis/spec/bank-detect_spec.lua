--[[
    Bank detail detection (lib/bank-detect.lua) — bank name, sort code and
    account number read from a statement's own header, never from transaction
    lines that name other banks.

    Runs under busted (`busted lapis/spec/bank-detect_spec.lua`) or standalone,
    like the other specs here, from the repo root:
        luajit lapis/spec/bank-detect_spec.lua

    Fixtures are SYNTHETIC plain-text renderings of common UK layouts
    (lapis/spec/fixtures/bank-statements/). The northbridge_* files are
    `pdftotext -layout` output of the synthetic Northbridge Demo Bank PDFs.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

-- Minimal describe/it/assert when not running under busted.
local standalone = (describe == nil)
local failures, passed = 0, 0
if standalone then
    local prefix = {}
    _G.describe = function(name, fn)
        prefix[#prefix + 1] = name
        fn()
        prefix[#prefix] = nil
    end
    _G.it = function(name, fn)
        local ok, err = pcall(fn)
        local label = table.concat(prefix, " / ") .. " :: " .. name
        if ok then
            passed = passed + 1
            print("  ok   - " .. label)
        else
            failures = failures + 1
            print("  FAIL - " .. label .. "\n         " .. tostring(err))
        end
    end
    local function eq(expected, actual)
        if expected ~= actual then
            error(string.format("expected %s, got %s", tostring(expected), tostring(actual)), 2)
        end
    end
    _G.assert = setmetatable({
        are = { equal = eq, same = eq },
        equal = eq,
        is_nil = function(v) if v ~= nil then error("expected nil, got " .. tostring(v), 2) end end,
        is_true = function(v) if v ~= true then error("expected true, got " .. tostring(v), 2) end end,
        is_false = function(v) if v ~= false then error("expected false, got " .. tostring(v), 2) end end,
        truthy = function(v) if not v then error("expected truthy, got " .. tostring(v), 2) end end,
    }, { __call = function(_, v, msg) if not v then error(msg or "assertion failed", 2) end return v end })
end

-- parse_llm_reply needs cjson; outside OpenResty provide a tiny flat-object decoder.
if not pcall(require, "cjson") then
    package.preload["cjson"] = function()
        return {
            decode = function(s)
                local obj = {}
                local body = s:match("^%s*{(.*)}%s*$")
                if not body then error("not an object") end
                for k, v in body:gmatch('"([%w_]+)"%s*:%s*("?[^,"}]*"?)') do
                    if v == "null" then obj[k] = nil
                    else obj[k] = v:match('^"(.*)"$') or tonumber(v) end
                end
                return obj
            end,
        }
    end
end

local BankDetect = require("lib.bank-detect")

local FIXTURES = "lapis/spec/fixtures/bank-statements/"
local function fixture(name)
    local f = assert(io.open(FIXTURES .. name, "rb"), "missing fixture " .. name)
    local s = f:read("*a")
    f:close()
    return s
end

local function detect(name)
    local kind = name:match("%.csv$") and "csv" or "text"
    return BankDetect.detect(fixture(name), kind, { llm = false })
end

describe("bank-detect", function()
    describe("PDF statement text (pdftotext -layout)", function()
        local cases = {
            -- fixture,                      bank,                    sort code,  account
            { "barclays.txt",                "Barclays",              "20-45-77", "43218765" },
            { "hsbc.txt",                    "HSBC",                  "40-11-62", "71234590" },
            { "lloyds.txt",                  "Lloyds",                "30-94-12", "55501234" },
            { "natwest.txt",                 "NatWest",               "60-12-34", "87654321" },
            { "santander.txt",               "Santander",             "09-01-28", "12340987" },
            { "monzo.txt",                   "Monzo",                 "04-00-04", "31415926" },
            { "starling.txt",                "Starling",              "60-83-71", "27182818" },
            { "northbridge_business.txt",    "Northbridge Demo Bank", "00-00-00", nil },
            { "northbridge_landlord.txt",    "Northbridge Demo Bank", "00-00-00", nil },
        }
        for _, c in ipairs(cases) do
            it(c[1] .. " -> " .. c[2], function()
                local r = detect(c[1])
                assert.is_true(r.detected)
                assert.are.equal(c[2], r.bank_name)
                assert.are.equal(c[3], r.sort_code)
                assert.are.equal(c[4], r.account_number)
            end)
        end

        it("does not invent an account number from 'TEST-ACCOUNT-7310'", function()
            assert.is_nil(detect("northbridge_landlord.txt").account_number)
        end)

        it("reads the statement period and balances from the header", function()
            local r = detect("northbridge_business.txt")
            assert.are.equal("2026-09-01", r.period_start)
            assert.are.equal("2026-09-30", r.period_end)
            assert.are.equal(17920.07, r.opening_balance)
            assert.are.equal(21062.25, r.closing_balance)
            local h = detect("hsbc.txt")
            assert.are.equal("2026-09-01", h.period_start)
            assert.are.equal("2026-09-30", h.period_end)
        end)

        it("reads the account type only from an explicit account title", function()
            assert.are.equal("business", detect("barclays.txt").account_type)
            assert.are.equal("current", detect("santander.txt").account_type)
            -- "Test scenario: business/client receipts" is not an account type.
            assert.is_nil(detect("northbridge_business.txt").account_type)
        end)

        it("Starling's 60-83-71 is Starling, not NatWest (footer + exact sort code)", function()
            assert.are.equal("Starling", detect("starling.txt").bank_name)
            assert.are.equal("Starling", BankDetect.bank_from_sort_code("60-83-71"))
        end)

        it("reads sort code + account number from a GB IBAN", function()
            local iban = BankDetect.parse_iban("IBAN: GB33 BARC 2045 7743 2187 65")
            assert.are.equal("20-45-77", iban.sort_code)
            assert.are.equal("43218765", iban.account_number)
            assert.are.equal("Barclays", iban.bank_name)
            local r = BankDetect.from_text("Statement\nIBAN GB29NWBK60161331926819\n\nDate Description Balance\n")
            assert.are.equal("60-16-13", r.sort_code)
            assert.are.equal("31926819", r.account_number)
            assert.are.equal("NatWest", r.bank_name)
        end)
    end)

    describe("other banks named in transaction lines (the trap)", function()
        it("Northbridge statement paying 'LLOYDS BANK BTL MORTGAGE' is Northbridge", function()
            local r = detect("trap_other_bank_in_txn.txt")
            assert.are.equal("Northbridge Demo Bank", r.bank_name)
            assert.are.equal("00-00-00", r.sort_code)
            assert.are.equal("24681357", r.account_number)
        end)

        it("no name in the header: falls back to the sort code, not the transactions", function()
            local r = detect("trap_no_header_name.txt")
            assert.are.equal("Barclays", r.bank_name) -- 20-xx prefix
            assert.are.equal("sort_code", r.source)
            assert.are.equal("20-11-22", r.sort_code)
            assert.are.equal("99887766", r.account_number)
        end)

        it("nothing in the header at all: not detected (no guessing from payees)", function()
            local r = detect("unknown_bank.txt")
            assert.is_false(r.detected)
            assert.is_nil(r.bank_name)
        end)

        it("Monzo statement mentioning Halifax and Lloyds payees is Monzo", function()
            assert.are.equal("Monzo", detect("monzo.txt").bank_name)
        end)

        it("Santander statement paying Barclays is Santander", function()
            assert.are.equal("Santander", detect("santander.txt").bank_name)
        end)

        it("transaction extraction tags the issuer, not the payee", function()
            package.preload["cjson"] = package.preload["cjson"] or function() return {} end
            local Extraction = require("lib.tax-extraction")
            local res = Extraction.extract_from_text(fixture("trap_other_bank_in_txn.txt"))
            assert.are.equal("northbridge demo bank", res.bank)
        end)
    end)

    describe("CSV statements", function()
        local cases = {
            { "lloyds.csv",              "Lloyds",    "30-94-12", "55501234" },
            { "barclays.csv",            "Barclays",  "20-45-77", "43218765" },
            { "natwest.csv",             "NatWest",   "60-12-34", "87654321" },
            { "header_block.csv",        "HSBC",      "40-11-62", "71234590" },
            { "sortcode_only_block.csv", "Santander", "09-01-28", "12348765" },
            { "monzo.csv",               "Monzo",     nil,        nil },
            { "starling.csv",            "Starling",  nil,        nil },
        }
        for _, c in ipairs(cases) do
            it(c[1] .. " -> " .. c[2], function()
                local r = detect(c[1])
                assert.is_true(r.detected)
                assert.are.equal(c[2], r.bank_name)
                assert.are.equal(c[3], r.sort_code)
                assert.are.equal(c[4], r.account_number)
            end)
        end

        it("header block period is parsed", function()
            local r = detect("header_block.csv")
            assert.are.equal("2026-09-01", r.period_start)
            assert.are.equal("2026-09-30", r.period_end)
        end)

        it("sort code in a header row is not mistaken for a date", function()
            local r = detect("sortcode_only_block.csv")
            assert.are.equal("2026-06-02", r.period_end)
        end)

        it("a CSV of transactions naming banks is not detected as those banks", function()
            local r = detect("trap_txn_only.csv")
            assert.is_false(r.detected)
            assert.is_nil(r.bank_name)
        end)

        it("CSV transaction extraction tags the issuer and reads the rows", function()
            local Extraction = require("lib.tax-extraction")
            local l = Extraction.extract_from_csv(fixture("lloyds.csv"))
            assert.are.equal("lloyds", l.bank) -- not "santander" from the mortgage payee
            assert.are.equal(2, l.count)
            assert.are.equal("DEBIT", l.transactions[1].transaction_type)
            assert.are.equal(950, l.transactions[1].amount)
            assert.are.equal("CREDIT", l.transactions[2].transaction_type)
            local m = Extraction.extract_from_csv(fixture("monzo.csv"))
            assert.are.equal("monzo", m.bank)
            assert.are.equal(2, m.count)
            assert.are.equal("HALIFAX ISA", m.transactions[1].description)
            local s = Extraction.extract_from_csv(fixture("starling.csv"))
            assert.are.equal(1, s.count)
            assert.are.equal("NatWest Loan", s.transactions[1].description)
            local h = Extraction.extract_from_csv(fixture("header_block.csv"))
            assert.are.equal("hsbc", h.bank)
            assert.are.equal(1, h.count)
            assert.are.equal(300, h.transactions[1].amount)
        end)

        it("strips a UTF-8 BOM and Excel's leading apostrophe", function()
            local r = BankDetect.from_csv("\239\187\191Sort Code,'20-00-00\nAccount Number,'12345678\n")
            assert.are.equal("20-00-00", r.sort_code)
            assert.are.equal("12345678", r.account_number)
            assert.are.equal("Barclays", r.bank_name)
        end)
    end)

    describe("sort code lookup", function()
        it("maps prefixes like diy-tax-return-uk", function()
            assert.are.equal("HSBC", BankDetect.bank_from_sort_code("40-12-34"))
            assert.are.equal("Barclays", BankDetect.bank_from_sort_code("200000"))
            assert.are.equal("Lloyds", BankDetect.bank_from_sort_code("30 99 99"))
            assert.are.equal("Santander", BankDetect.bank_from_sort_code("09-01-28"))
            assert.are.equal("Nationwide", BankDetect.bank_from_sort_code("07-01-16"))
            assert.are.equal("Monzo", BankDetect.bank_from_sort_code("04-00-04"))
            assert.are.equal("Revolut", BankDetect.bank_from_sort_code("04-00-75"))
            assert.is_nil(BankDetect.bank_from_sort_code("00-00-00"))
            assert.is_nil(BankDetect.bank_from_sort_code(nil))
        end)

        it("normalises sort codes and account numbers", function()
            assert.are.equal("12-34-56", BankDetect.normalize_sort_code("123456"))
            assert.are.equal("12-34-56", BankDetect.normalize_sort_code("12 34 56"))
            assert.is_nil(BankDetect.normalize_sort_code("12-34-5"))
            assert.is_nil(BankDetect.normalize_sort_code("AB-CD-EF"))
            assert.are.equal("12345678", BankDetect.normalize_account_number("1234 5678"))
            assert.is_nil(BankDetect.normalize_account_number("TEST-ACCOUNT-7310"))
            assert.is_nil(BankDetect.normalize_account_number("1234"))
        end)
    end)

    describe("masking", function()
        it("masks account numbers and sort codes for logs", function()
            assert.are.equal("****5678", BankDetect.mask_account_number("12345678"))
            assert.are.equal("20-**-**", BankDetect.mask_sort_code("20-45-77"))
            assert.is_nil(BankDetect.mask_account_number(nil))
            local line = BankDetect.log_line(detect("barclays.txt"))
            assert.truthy(line:find("****8765", 1, true))
            assert.truthy(line:find("20-**-**", 1, true))
            assert.is_nil(line:find("43218765", 1, true))
            assert.is_nil(line:find("20-45-77", 1, true))
        end)

        it("returns a masked copy without touching the original", function()
            local r = detect("lloyds.txt")
            local m = BankDetect.masked(r)
            assert.are.equal("****1234", m.account_number)
            assert.are.equal("55501234", r.account_number)
            assert.are.equal("****1234", r.account_number_masked)
        end)
    end)

    describe("LLM fallback", function()
        it("is not called when the rules found the bank and a number", function()
            local called = false
            BankDetect.detect(fixture("lloyds.txt"), "text", {
                llm_fn = function() called = true return {} end,
            })
            assert.is_false(called)
        end)

        it("fills only the missing fields", function()
            local r = BankDetect.detect(fixture("unknown_bank.txt"), "text", {
                llm_fn = function() return { bank_name = "Tide" } end,
            })
            assert.are.equal("Tide", r.bank_name)
            assert.are.equal("llm", r.source)
            assert.is_true(r.detected)
        end)

        it("survives a failing provider", function()
            local r = BankDetect.detect(fixture("unknown_bank.txt"), "text", {
                llm_fn = function() error("provider down") end,
            })
            assert.is_false(r.detected)
            assert.truthy(r.llm_error)
        end)

        it("rejects numbers the model made up (not in the text)", function()
            local text = "Sort code 20-11-22\nAccount 99887766\n"
            -- Nothing the model said can be found in the text: rejected outright.
            assert.is_nil(BankDetect.parse_llm_reply(
                '{"bank_name": "Barclays", "sort_code": "30-00-00", "account_number": "11112222"}', text))
            local ok = BankDetect.parse_llm_reply(
                '{"bank_name": null, "sort_code": "20-11-22", "account_number": "99887766"}', text)
            assert.are.equal("20-11-22", ok.sort_code)
            assert.are.equal("99887766", ok.account_number)
        end)

        it("accepts a bank name only if it is in the text or matches the sort code", function()
            local text = "Sort code 20-11-22\nAccount 99887766\n"
            local by_sc = BankDetect.parse_llm_reply('{"bank_name": "Barclays", "sort_code": "20-11-22"}', text)
            assert.are.equal("Barclays", by_sc.bank_name)
            local wrong = BankDetect.parse_llm_reply('{"bank_name": "Lloyds", "sort_code": "20-11-22"}', text)
            assert.is_nil(wrong.bank_name)
            local named = BankDetect.parse_llm_reply('{"bank_name": "Kingsmead Mutual"}', "KINGSMEAD MUTUAL\nStatement")
            assert.are.equal("Kingsmead Mutual", named.bank_name)
        end)

        it("is never shown transaction lines (CSV without a header block: no call)", function()
            local called = false
            local r = BankDetect.detect(fixture("trap_txn_only.csv"), "csv", {
                llm_fn = function() called = true return { bank_name = "Lloyds" } end,
            })
            assert.is_false(called)
            assert.is_nil(r.bank_name)
        end)

        it("PDF text: the model sees the header, not 'LLOYDS BANK BTL MORTGAGE'", function()
            local seen
            BankDetect.detect(fixture("unknown_bank.txt"), "text", {
                llm_fn = function(snippet) seen = snippet return nil end,
            })
            assert.truthy(seen:find("Statement of account", 1, true))
            assert.is_nil(seen:find("LLOYDS", 1, true))
        end)

        it("is not asked for numbers a CSV export doesn't carry (Monzo)", function()
            local called = false
            BankDetect.detect(fixture("monzo.csv"), "csv", {
                llm_fn = function() called = true return nil end,
            })
            assert.is_false(called)
        end)
    end)
end)

if standalone then
    print(string.format("\n%d passed, %d failed", passed, failures))
    if failures > 0 then os.exit(1) end
end
