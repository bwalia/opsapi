--[[
    ATS — small text helpers shared by the engine, validator and evaluator.
    Pure Lua (no ngx), so the tests run under plain LuaJIT.

    Word boundaries use Lua frontier patterns: %f[%w] (a word starts) and
    %f[%W] (a word ends), the equivalent of \b in the Swift (ICU) regexes.
]]

local T = {}

T.B = "%f[%w]"
T.E = "%f[%W]"

function T.trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Number of characters (UTF-8 code points).
function T.len(s)
    local _, n = tostring(s or ""):gsub("[^\128-\191]", "")
    return n
end

--- The first n characters (UTF-8 aware).
function T.prefix(s, n)
    s = tostring(s or "")
    if T.len(s) <= n then return s end
    local count, i = 0, 1
    while i <= #s do
        local c = s:byte(i)
        if c < 128 or c >= 192 then
            count = count + 1
            if count > n then return s:sub(1, i - 1) end
        end
        i = i + 1
    end
    return s
end

--- Escapes Lua pattern magic characters.
function T.escape(s)
    return (tostring(s):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

--- A case-insensitive pattern for a literal word.
function T.caseless(s)
    return (T.escape(s):gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end))
end

--- Plain (non-pattern) substring test.
function T.contains(s, needle)
    return s:find(needle, 1, true) ~= nil
end

--- Replaces every plain occurrence of `needle`.
function T.replace(s, needle, with)
    local out, start = {}, 1
    while true do
        local a, b = s:find(needle, start, true)
        if not a then break end
        out[#out + 1] = s:sub(start, a - 1)
        out[#out + 1] = with
        start = b + 1
    end
    out[#out + 1] = s:sub(start)
    return table.concat(out)
end

--- Splits text into sentences: {text, first, last} byte ranges, each ending
-- after its . ! or ? and any trailing spaces (like Foundation's .bySentences
-- for ordinary prose).
function T.sentences(s)
    s = tostring(s or "")
    local list, start, i = {}, 1, 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == "." or c == "!" or c == "?" or c == "\n" then
            local j = i
            while j < #s and s:sub(j + 1, j + 1):match("[%.!%?]") do j = j + 1 end
            local k = j
            while k < #s and s:sub(k + 1, k + 1):match("%s") do k = k + 1 end
            if k > j or j == #s then
                list[#list + 1] = { text = s:sub(start, k), first = start, last = k }
                start = k + 1
                i = k + 1
            else
                i = j + 1
            end
        else
            i = i + 1
        end
    end
    if start <= #s then list[#list + 1] = { text = s:sub(start), first = start, last = #s } end
    return list
end

--- ISO 8601 (UTC, seconds) for an epoch time.
function T.iso(t)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(t))
end

return T
