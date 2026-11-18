--[[
    Spec: the pure-Lua PDF writer (lib/pdf-lite.lua).

    Standalone (no busted). From the repo root:
        luajit lapis/spec/pdf-lite_spec.lua
    When `pdftotext` (poppler-utils, in bwalia/opsapi-base) is on the PATH it also reads the file back.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

local Pdf = require("lib.pdf-lite")

-- encoding: UTF-8 in, Windows-1252 out
check("ascii kept", Pdf.encode("Hello 123") == "Hello 123")
check("pound sign", Pdf.encode("£5") == "\163" .. "5")
check("euro, dashes, curly quotes, bullet", Pdf.encode("€–—‘’“”•…") == "\128\150\151\145\146\147\148\149\133")
check("accents (Latin-1)", Pdf.encode("café") == "caf\233")
check("emoji and CJK become ?", Pdf.encode("ok 🎯 日") == "ok ? ?", Pdf.encode("ok 🎯 日"))
check("control characters become spaces", Pdf.encode("a\tb\nc\0d") == "a b c d")
check("broken UTF-8 never errors", pcall(Pdf.encode, "\255\254abc\195"))

-- widths and wrapping
check("width of 'a' at 10pt = 5.56", math.abs(Pdf.width("a", 10) - 5.56) < 1e-9)
check("bold is wider", Pdf.width("bold text", 10, true) > Pdf.width("bold text", 10, false))
local lines = Pdf.wrap(("word "):rep(60), 10, false, 200)
local fits = true
for _, l in ipairs(lines) do if Pdf.width(l, 10, false) > 200 then fits = false end end
check("wrapped lines fit the width", fits and #lines > 3, #lines)
local long = Pdf.wrap(("x"):rep(300), 10, false, 100)
local fit2 = #long > 1
for _, l in ipairs(long) do if Pdf.width(l, 10, false) > 100 then fit2 = false end end
check("a word longer than the line is split", fit2)

-- a document
local doc = Pdf.new({ title = "Lead (report)", footer = "Workstation" })
doc:heading("Lead report — Jane (Smith)")
doc:badge("7/10", "Good fit", { 0.1, 0.6, 0.3 })
doc:row("Source", "Website form")
doc:row("Empty", "")
doc:bullets({ "First reason", "Second reason with £ and back\\slash" })
doc:rule()
for i = 1, 120 do doc:text("Line " .. i .. " of a long message that should flow onto further pages.") end
local bytes = doc:render()

check("starts with the PDF header", bytes:sub(1, 8) == "%PDF-1.4")
check("ends with %%EOF", bytes:sub(-6) == "%%EOF\n")
check("several pages", #doc.pages >= 3, #doc.pages)
check("page count in the tree", bytes:find("/Count " .. #doc.pages, 1, true) ~= nil)
check("brackets and backslashes escaped", bytes:find("Jane \\(Smith\\)", 1, true) ~= nil and bytes:find("back\\\\slash", 1, true) ~= nil)
check("footer on every page", select(2, bytes:gsub("Page %d+ of " .. #doc.pages, "")) == #doc.pages)
check("an empty row is left out", not bytes:find("(Empty)", 1, true))

-- every xref offset points at its object
local xref_at = tonumber(bytes:match("startxref\n(%d+)\n"))
check("startxref points at the xref table", bytes:sub(xref_at + 1, xref_at + 4) == "xref")
local n = tonumber(bytes:match("xref\n0 (%d+)\n"))
local good = true
local i = 0
for off in bytes:sub(xref_at + 1):gmatch("(%d%d%d%d%d%d%d%d%d%d) 00000 n") do
    i = i + 1
    local at = tonumber(off)
    if bytes:sub(at + 1, at + #tostring(i) + 6) ~= i .. " 0 obj" then good = false end
end
check("xref offsets are exact", good and i == n - 1, i .. " of " .. tostring(n))

-- stream lengths match
local lens_ok = true
for len, body in bytes:gmatch("/Length (%d+) >>\nstream\n(.-)\nendstream") do
    if tonumber(len) ~= #body then lens_ok = false end
end
check("stream lengths match", lens_ok)

-- read it back when poppler is installed
local probe = io.popen("command -v pdftotext 2>/dev/null")
local has = probe and probe:read("*a") or ""
if probe then probe:close() end
if has:match("%S") then
    local path = os.tmpname()
    local f = assert(io.open(path, "wb"))
    f:write(bytes)
    f:close()
    local p = io.popen("pdftotext -enc UTF-8 " .. path .. " - 2>&1")
    local txt = p:read("*a")
    p:close()
    os.remove(path)
    check("pdftotext reads the heading", txt:find("Lead report", 1, true) ~= nil, txt:sub(1, 200))
    check("pdftotext reads the pound sign", txt:find("£", 1, true) ~= nil)
    check("pdftotext reads the last line", txt:find("Line 120 of", 1, true) ~= nil)
else
    print("  skip - pdftotext not installed")
end

if failures > 0 then
    print(failures .. " check(s) failed")
    os.exit(1)
end
print("all checks passed")
