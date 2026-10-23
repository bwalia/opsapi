-- The building blocks of the email designs: a white card, a brand line, banners, headings,
-- highlight boxes, buttons, discount codes, a signature and a footer — all inline-styled and
-- made only of what the easy editor keeps. Used by the ready-made designs and the AI designer.
-- Text passed in is HTML already (callers escape what people or the AI wrote).

local B = {}

local FONT = "font-family:'Helvetica Neue',Helvetica,Arial,sans-serif"

function B.card(inner)
    return '<div style="' .. FONT .. ';max-width:600px;margin:0 auto;padding:36px 32px;background:#ffffff;'
        .. 'color:#1f2937;font-size:16px;line-height:1.65;border:1px solid #e5e7eb;border-radius:16px">\n'
        .. table.concat(inner, "\n") .. "\n</div>"
end

function B.brand(accent)
    return '<p style="margin:0 0 28px;font-size:13px;font-weight:700;letter-spacing:2px;text-transform:uppercase;'
        .. "color:" .. accent .. '">[Your business name]</p>'
end

function B.banner(bg, text)
    return '<h1 style="margin:0 0 24px;padding:40px 28px;background:' .. bg .. ';color:#ffffff;border-radius:12px;'
        .. 'font-size:30px;line-height:1.2;font-weight:800;text-align:center">' .. text .. "</h1>"
end

function B.title(text)
    return '<h1 style="margin:0 0 16px;font-size:28px;line-height:1.25;font-weight:800;color:#111827">'
        .. text .. "</h1>"
end

function B.heading(text)
    return '<h2 style="margin:28px 0 8px;font-size:20px;line-height:1.3;font-weight:700;color:#111827">'
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
    return '<p style="margin:24px 0 8px;padding:18px;text-align:center;font-size:30px;font-weight:800;letter-spacing:6px;'
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


return B
