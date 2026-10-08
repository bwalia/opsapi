--[[
    Per-account auth limits (helper/auth-throttle.lua)
    ==================================================
    Counters in Postgres (auth_throttle), so they hold across pods and can't be
    dodged by changing IP the way per-IP limits can. Fixed windows: a key's
    count resets once its window has passed.

      Throttle.count(key, window)        current count (0 when the window passed)
      Throttle.hit(key, window)          +1, returns the new count
      Throttle.clear(key)                forget the key (e.g. after a good login)

    Used for: failed passwords per account (login lockout), OTP codes sent per
    user, failed OTP checks per user (routes/auth.lua).
]]

local db = require("lapis.db")

local Throttle = {}

Throttle.LOGIN = { limit = 10, window = 900 }     -- 10 failed passwords / 15 min, then locked for the rest of it
Throttle.OTP_SEND = { limit = 6, window = 3600 }  -- codes sent per user per hour (sign-ins + resends)
Throttle.OTP_FAIL = { limit = 10, window = 3600 } -- wrong codes per user per hour

function Throttle.key(kind, id)
    return kind .. ":" .. tostring(id or ""):lower()
end

function Throttle.count(key, window)
    local row = db.query([[SELECT count, EXTRACT(EPOCH FROM (window_start + make_interval(secs => ?) - NOW()))::int AS left
        FROM auth_throttle WHERE key = ? AND window_start > NOW() - make_interval(secs => ?)]], window, key, window)[1]
    if not row then return 0, 0 end
    return tonumber(row.count), math.max(tonumber(row.left) or 0, 0)
end

function Throttle.hit(key, window)
    return tonumber(db.query([[
        INSERT INTO auth_throttle (key, count, window_start) VALUES (?, 1, NOW())
        ON CONFLICT (key) DO UPDATE SET
            count = CASE WHEN auth_throttle.window_start <= NOW() - make_interval(secs => ?) THEN 1
                         ELSE auth_throttle.count + 1 END,
            window_start = CASE WHEN auth_throttle.window_start <= NOW() - make_interval(secs => ?) THEN NOW()
                                ELSE auth_throttle.window_start END
        RETURNING count]], key, window, window)[1].count)
end

function Throttle.clear(key)
    db.query("DELETE FROM auth_throttle WHERE key = ?", key)
end

--- Over the limit? @return true, seconds left | false
function Throttle.blocked(key, rule)
    local n, left = Throttle.count(key, rule.window)
    if n >= rule.limit then return true, left end
    return false
end

--- Housekeeping: drop expired windows.
function Throttle.purge()
    db.query("DELETE FROM auth_throttle WHERE window_start < NOW() - interval '1 day'")
end

return Throttle
