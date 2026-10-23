-- The pages a person sees from the links in a marketing email (unsubscribe, preferences).
-- Plain HTML: no scripts, readable on a phone, light and dark; every value is escaped.
local U = require("opsapi_marketing.util")

local P = {}

local function esc(s)
    return (tostring(s or ""):gsub("[&<>\"']", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;",
    }))
end
P.esc = esc

local CSS = [[
:root{color-scheme:light dark;--bg:#f4f5f7;--card:#fff;--text:#111827;--muted:#4b5563;--line:#e5e7eb;
--btn:#111827;--btntext:#fff;--ok:#047857}
@media (prefers-color-scheme:dark){:root{--bg:#0b0f17;--card:#141a24;--text:#f3f4f6;--muted:#9ca3af;
--line:#273041;--btn:#f3f4f6;--btntext:#111827;--ok:#34d399}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);
font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
display:flex;min-height:100vh;align-items:center;justify-content:center;padding:24px 16px}
.card{width:100%;max-width:480px;background:var(--card);border:1px solid var(--line);border-radius:16px;
padding:28px 24px;box-shadow:0 10px 30px rgba(0,0,0,.06)}
.from{margin:0 0 6px;font-size:14px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
h1{margin:0 0 12px;font-size:24px;line-height:1.25}p{margin:0 0 14px;color:var(--muted)}b{color:var(--text)}
.done{color:var(--ok);font-weight:600}
form{margin:16px 0 0}.btn{display:block;width:100%;min-height:48px;border:0;border-radius:10px;
background:var(--btn);color:var(--btntext);font-family:inherit;font-size:16px;font-weight:600;cursor:pointer}
.btn.secondary{background:transparent;color:var(--text);border:1px solid var(--line)}
.row{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:14px 0;border-top:1px solid var(--line)}
.row form{margin:0}.row .btn{width:auto;min-height:40px;padding:0 16px;font-size:14px}
.addr{margin:22px 0 0;padding-top:14px;border-top:1px solid var(--line);font-size:13px;white-space:pre-line}
]]

--- Who sent the emails: the workspace's name and the postal address shown in its emails.
function P.sender(ns)
    local n = ns and U.one("SELECT name FROM namespaces WHERE id = ?", ns)
    local settings = ns and U.settings(ns) or {}
    return {
        name = n and n.name or "this sender",
        address = type(settings.sender_address) == "string" and settings.sender_address or "",
    }
end

--- A POST form with hidden fields and one button. secondary = outlined button.
function P.form(action, fields, button, secondary)
    local hidden = {}
    for k, v in pairs(fields or {}) do
        hidden[#hidden + 1] = '<input type="hidden" name="' .. esc(k) .. '" value="' .. esc(v) .. '">'
    end
    return '<form method="post" action="' .. esc(action) .. '">' .. table.concat(hidden)
        .. '<button type="submit" class="btn' .. (secondary and " secondary" or "") .. '">' .. esc(button)
        .. "</button></form>"
end

--- A whole page. opts: title, body (HTML, values already escaped), sender, status.
function P.page(opts)
    local sender = opts.sender or {}
    local html = '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        .. '<meta name="viewport" content="width=device-width,initial-scale=1">'
        .. '<meta name="robots" content="noindex"><title>' .. esc(opts.title) .. "</title><style>" .. CSS
        .. '</style></head><body><main class="card">'
        .. (sender.name and ('<p class="from">' .. esc(sender.name) .. "</p>") or "")
        .. "<h1>" .. esc(opts.title) .. "</h1>" .. (opts.body or "")
        .. ((sender.address or "") ~= "" and ('<p class="addr">' .. esc(sender.address) .. "</p>") or "")
        .. "</main></body></html>"
    return {
        status = opts.status or 200,
        layout = false,
        headers = {
            ["Content-Type"] = "text/html; charset=utf-8",
            ["Cache-Control"] = "no-store",
            ["X-Robots-Tag"] = "noindex",
            ["Referrer-Policy"] = "no-referrer",
            ["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
        },
        html,
    }
end

return P
