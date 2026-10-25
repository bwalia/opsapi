-- The building blocks of the email designs: a white card, a brand line, banners, headings,
-- highlight boxes, buttons, discount codes, a signature and a footer — all inline-styled and
-- made only of what the easy editor keeps. Used by the ready-made designs and the AI designer.
-- Text passed in is HTML already (callers escape what people or the AI wrote).

local B = {}

-- The Workstation website's fonts: Poppins for text, Unbounded for big headings, JetBrains Mono
-- for small labels. Email apps that can't load web fonts (Gmail, Outlook on Windows) fall back
-- to Helvetica / Arial. B.document adds the <link> that loads them where they can.
B.FONT_BODY = "Poppins,'Helvetica Neue',Helvetica,Arial,sans-serif"
B.FONT_DISPLAY = "Unbounded,Poppins,'Helvetica Neue',Helvetica,Arial,sans-serif"
B.FONT_MONO = "'JetBrains Mono',ui-monospace,Menlo,Consolas,monospace"
B.FONTS_CSS = "https://fonts.googleapis.com/css2?family=Poppins:wght@400;600;700"
    .. "&family=Unbounded:wght@500;700&family=JetBrains+Mono:wght@500&display=swap"

local FONT = "font-family:" .. B.FONT_BODY
local DISPLAY = "font-family:" .. B.FONT_DISPLAY .. ";"
local MONO = "font-family:" .. B.FONT_MONO .. ";"

function B.card(inner)
    return '<div style="' .. FONT .. ';max-width:600px;margin:0 auto;padding:36px 32px;background:#ffffff;'
        .. 'color:#1f2937;font-size:16px;line-height:1.65;border:1px solid #e5e7eb;border-radius:16px">\n'
        .. table.concat(inner, "\n") .. "\n</div>"
end

function B.brand(accent)
    return '<p style="margin:0 0 28px;' .. MONO .. 'font-size:12px;font-weight:500;letter-spacing:2px;'
        .. 'text-transform:uppercase;color:' .. accent .. '">[Your business name]</p>'
end

function B.banner(bg, text)
    return '<h1 style="margin:0 0 24px;padding:40px 28px;background:' .. bg .. ';color:#ffffff;border-radius:12px;'
        .. DISPLAY .. 'font-size:28px;line-height:1.2;font-weight:700;text-align:center">' .. text .. "</h1>"
end

function B.title(text)
    return '<h1 style="margin:0 0 16px;' .. DISPLAY .. 'font-size:26px;line-height:1.25;font-weight:700;color:#111827">'
        .. text .. "</h1>"
end

function B.heading(text)
    return '<h2 style="margin:28px 0 8px;' .. DISPLAY
        .. 'font-size:19px;line-height:1.3;font-weight:700;color:#111827">'
        .. text .. "</h2>"
end

function B.p(text)
    return '<p style="margin:0 0 16px">' .. text .. "</p>"
end

function B.lead(text)
    return '<p style="margin:0 0 20px;font-size:18px;color:#374151">' .. text .. "</p>"
end

function B.note(accent, text)
    return '<p style="margin:24px 0;padding:18px 20px;background:#f9fafb;border-left:4px solid ' .. accent
        .. ';border-radius:8px">' .. text .. "</p>"
end

function B.list(items)
    local li = {}
    for i, t in ipairs(items) do li[i] = "<li><p>" .. t .. "</p></li>" end
    return "<ul>" .. table.concat(li) .. "</ul>"
end

function B.button(bg, label, href)
    return '<p style="margin:28px 0;text-align:center"><a href="' .. (href or "https://yourwebsite.co.uk")
        .. '" style="display:inline-block;background:' .. bg .. ';color:#ffffff;padding:14px 28px;border-radius:8px;'
        .. 'text-decoration:none;font-weight:600">' .. label .. "</a></p>"
end

function B.code(accent, c)
    return '<p style="margin:24px 0 8px;padding:18px;text-align:center;' .. MONO
        .. 'font-size:28px;font-weight:500;letter-spacing:6px;'
        .. "color:" .. accent .. ";border:2px dashed " .. accent .. ';border-radius:12px">' .. c .. "</p>"
end

function B.small(text)
    return '<p style="margin:0 0 16px;font-size:13px;color:#6b7280;text-align:center">' .. text .. "</p>"
end

function B.sign(closing)
    return '<p style="margin:28px 0 0">' .. (closing or "Best wishes,")
        .. "<br><strong>[Your name]</strong><br>[Your business name]</p>"
end

function B.footer(why)
    return '<p style="margin:32px 0 0;padding-top:20px;border-top:1px solid #e5e7eb;font-size:12px;line-height:1.5;'
        .. 'color:#6b7280;text-align:center">' .. (why or "You’re getting this because you’re a customer or asked to hear from us.")
        .. '<br><a href="{{unsubscribe_url}}" style="color:#6b7280">Unsubscribe</a> · '
        .. '<a href="{{preferences_url}}" style="color:#6b7280">Email preferences</a></p>'
end

--- A small top line for the start of an email: a link to the browser copy.
function B.view_online()
    return '<p style="margin:0 0 16px;font-size:12px;color:#6b7280;text-align:center">Trouble viewing? '
        .. '<a href="{{view_online_url}}" style="color:#6b7280">View this email in your browser</a></p>'
end

--- A whole HTML document around an email body, with the <link> that loads the fonts.
-- Email apps read <head> styles, so this is how Apple Mail, iOS and Outlook for Mac get Poppins.
function B.document(html, title)
    local t = (tostring(title or ""):gsub("[<>&\"]",
        { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;", ['"'] = "&quot;" }))
    return '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        .. '<meta name="viewport" content="width=device-width,initial-scale=1">'
        .. '<meta name="x-apple-disable-message-reformatting"><title>' .. t .. '</title>'
        .. '<link rel="stylesheet" href="' .. (B.FONTS_CSS:gsub("&", "&amp;")) .. '">'
        .. '</head><body style="margin:0;padding:16px 8px;font-family:' .. B.FONT_BODY .. '">'
        .. html .. "</body></html>"
end

return B
