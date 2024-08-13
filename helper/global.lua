local bcrypt = require("bcrypt")
local saltRounds = 10 
local Global = {}

function Global.generateUUID()
    local random = math.random(1000000000)
    local timestamp = os.time()
    local hash = ngx.md5(tostring(random) .. tostring(timestamp))
    local uuid = string.format("%s-%s-%s-%s-%s", string.sub(hash, 1, 8), string.sub(hash, 9, 12),
        string.sub(hash, 13, 16), string.sub(hash, 17, 20), string.sub(hash, 21, 32))
    return uuid
end

function Global.hashPassword(password)
    local hash = bcrypt.digest(password, saltRounds)
    return hash
end

function Global.matchPassword(password, hashedPassword)
    return bcrypt.verify(password, hashedPassword)
end

return Global