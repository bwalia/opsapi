local Global = require "helper.global"
local Secrets = require "models.SecretModel"
local Validation = require "helper.validations"
local cjson = require "cjson"


local SecretQueries = {}

function SecretQueries.create(secretData)
    Validation.createSecret(secretData)
    if secretData.secret then
        local encodedSecret = Global.encryptSecret(secretData.secret)
        secretData.secret = encodedSecret
    end
    if secretData.uuid == nil then
        secretData.uuid = Global.generateUUID()
    end
    return Secrets:create(secretData, {
        returning = "*"
    })
end

function SecretQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = Secrets:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    return paginated:get_page(page)
end

function SecretQueries.show(id)
    return Secrets:find({
        uuid = id
    })
end

function SecretQueries.update(id, params)
    local secret = Secrets:find({
        uuid = id
    })
    params.id = secret.id
    if params.secret and params.secret ~= nil and params.secret ~= ngx.null and params.secret ~= "" then
        local encodedSecret = Global.encryptSecret(params.secret)
        params.secret = encodedSecret
    else
        params.secret = secret.secret
    end
    return secret:update(params, {
        returning = "*"
    })
end

function SecretQueries.destroy(id)
    local secret = Secrets:find({
        uuid = id
    })
    return secret:delete()
end

function SecretQueries.showSecret(id)
    local secret = Secrets:find({
        uuid = id
    })
    if secret then
        if secret.secret and secret.secret ~= nil then
            local secretValue = Global.decryptSecret(secret.secret)
            secret.secret = secretValue
        end
    end
    return secret
end

return SecretQueries