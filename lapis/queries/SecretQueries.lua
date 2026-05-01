local Global = require "helper.global"
local Secrets = require "models.SecretModel"
local Validation = require "helper.validations"
local cJson = require "cjson"


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
    local secret = Secrets:create(secretData, {
        returning = "*"
    })
    secret.internal_id = secret.id
    secret.id = secret.uuid
    return { data = secret }
end

function SecretQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 10

    -- Validate ORDER BY to prevent SQL injection
    local valid_fields = { id = true, name = true, created_at = true, updated_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_fields, "id", "desc")

    local paginated = Secrets:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage,
        fields = 'id as internal_id, uuid as id, name, description, created_at, updated_at'
    })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function SecretQueries.show(id)
    local secret = Secrets:find({
        uuid = id
    })
    if secret then
        secret.secret = "********"
        secret.internal_id = secret.id
        secret.id = secret.uuid
        return secret
    end
    return {}
end

function SecretQueries.update(id, params)
    local secret = Secrets:find({
        uuid = id
    })
    params.id = secret.id
    if params.secret == "********" then
        params.secret = nil
    end
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
