--[[
    Tax Bank Account Queries

    CRUD operations for tax_bank_accounts table.
    All operations are scoped to the authenticated user.
]]

local Global = require "helper.global"
local TaxBankAccounts = require "models.TaxBankAccountModel"
local TaxAuditLogQueries = require "queries.TaxAuditLogQueries"
local db = require("lapis.db")
local cjson = require("cjson")

local TaxBankAccountQueries = {}

-- Create a new bank account
function TaxBankAccountQueries.create(data, user)
    local user_uuid = user.uuid or user.id

    if data.uuid == nil then
        data.uuid = Global.generateUUID()
    end

    -- Get internal user ID from users table
    local user_record
    if user.uuid then
        user_record = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    else
        user_record = db.query("SELECT id FROM users WHERE id = ? LIMIT 1", user_uuid)
    end
    if not user_record or #user_record == 0 then
        return nil, "User not found"
    end
    data.user_id = user_record[1].id

    -- If this is the first account, make it primary
    local existing = db.query("SELECT COUNT(*) as count FROM tax_bank_accounts WHERE user_id = ?", data.user_id)
    if existing[1].count == 0 then
        data.is_primary = true
    end

    -- If setting as primary, unset existing primary
    if data.is_primary then
        db.query("UPDATE tax_bank_accounts SET is_primary = false WHERE user_id = ? AND is_primary = true", data.user_id)
    end

    local bank_account = TaxBankAccounts:create({
        uuid = data.uuid,
        user_id = data.user_id,
        namespace_id = data.namespace_id,
        bank_name = data.bank_name,
        account_name = data.account_name,
        account_number_last4 = data.account_number_last4,
        sort_code = data.sort_code,
        account_type = data.account_type or "BUSINESS",
        currency = data.currency or "GBP",
        is_primary = data.is_primary or false,
        is_active = true
    }, { returning = "*" })

    -- Audit log
    TaxAuditLogQueries.log({
        user_id = data.user_id,
        user_email = user.email,
        entity_type = "BANK_ACCOUNT",
        entity_id = bank_account.uuid,
        action = "CREATE",
        new_values = cjson.encode(bank_account)
    })

    -- Return with uuid as id
    bank_account.internal_id = bank_account.id
    bank_account.id = bank_account.uuid
    return { data = bank_account }
end

-- List all bank accounts for user
function TaxBankAccountQueries.all(params, user)
    local user_uuid = user.uuid or user.id

    -- Get internal user ID
    local user_record
    if user.uuid then
        user_record = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    else
        user_record = db.query("SELECT id FROM users WHERE id = ? LIMIT 1", user_uuid)
    end
    if not user_record or #user_record == 0 then
        return { data = {}, total = 0 }
    end
    local user_id = user_record[1].id

    local page = tonumber(params.page) or 1
    local perPage = tonumber(params.perPage) or 20

    local paginated = TaxBankAccounts:paginated(
        "WHERE user_id = ? AND is_active = true ORDER BY is_primary DESC, created_at DESC",
        user_id,
        {
            per_page = perPage,
            fields = 'id as internal_id, uuid as id, user_id, bank_name, account_name, account_number_last4, sort_code, account_type, currency, is_primary, is_active, created_at, updated_at'
        }
    )

    local accounts = paginated:get_page(page)

    -- Add statement count for each account
    for _, account in ipairs(accounts) do
        local count_result = db.query("SELECT COUNT(*) as count FROM tax_statements WHERE bank_account_id = (SELECT id FROM tax_bank_accounts WHERE uuid = ?)", account.id)
        account.statement_count = count_result[1] and count_result[1].count or 0
    end

    return {
        data = accounts,
        total = paginated:total_items(),
        page = page,
        per_page = perPage
    }
end

-- Get single bank account
function TaxBankAccountQueries.show(uuid, user)
    local user_uuid = user.uuid or user.id

    -- Get internal user ID
    local user_record
    if user.uuid then
        user_record = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    else
        user_record = db.query("SELECT id FROM users WHERE id = ? LIMIT 1", user_uuid)
    end
    if not user_record or #user_record == 0 then
        return nil
    end
    local user_id = user_record[1].id

    local result = db.query([[
        SELECT id as internal_id, uuid as id, user_id, bank_name, account_name,
               account_number_last4, sort_code, account_type, currency,
               is_primary, is_active, created_at, updated_at
        FROM tax_bank_accounts
        WHERE uuid = ? AND user_id = ?
        LIMIT 1
    ]], uuid, user_id)

    if result and #result > 0 then
        local account = result[1]
        -- Add statement count
        local count_result = db.query("SELECT COUNT(*) as count FROM tax_statements WHERE bank_account_id = (SELECT id FROM tax_bank_accounts WHERE uuid = ?)", uuid)
        account.statement_count = count_result[1] and count_result[1].count or 0
        return account
    end

    return nil
end

-- Update bank account
function TaxBankAccountQueries.update(uuid, params, user)
    local user_uuid = user.uuid or user.id

    -- Get internal user ID
    local user_record
    if user.uuid then
        user_record = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    else
        user_record = db.query("SELECT id FROM users WHERE id = ? LIMIT 1", user_uuid)
    end
    if not user_record or #user_record == 0 then
        return nil
    end
    local user_id = user_record[1].id

    local bank_account = TaxBankAccounts:find({
        uuid = uuid,
        user_id = user_id
    })

    if not bank_account then
        return nil
    end

    local old_values = cjson.encode({
        bank_name = bank_account.bank_name,
        account_name = bank_account.account_name,
        account_number_last4 = bank_account.account_number_last4,
        sort_code = bank_account.sort_code,
        account_type = bank_account.account_type,
        currency = bank_account.currency,
        is_primary = bank_account.is_primary
    })

    -- If setting as primary, unset existing primary
    if params.is_primary then
        db.query("UPDATE tax_bank_accounts SET is_primary = false WHERE user_id = ? AND id != ? AND is_primary = true",
            user_id, bank_account.id)
    end

    -- Update allowed fields
    local update_data = {}
    if params.bank_name then update_data.bank_name = params.bank_name end
    if params.account_name then update_data.account_name = params.account_name end
    if params.account_number_last4 then update_data.account_number_last4 = params.account_number_last4 end
    if params.sort_code then update_data.sort_code = params.sort_code end
    if params.account_type then update_data.account_type = params.account_type end
    if params.currency then update_data.currency = params.currency end
    if params.is_primary ~= nil then update_data.is_primary = params.is_primary end
    update_data.updated_at = db.raw("NOW()")

    bank_account:update(update_data)

    -- Audit log
    TaxAuditLogQueries.log({
        user_id = user_id,
        user_email = user.email,
        entity_type = "BANK_ACCOUNT",
        entity_id = uuid,
        action = "UPDATE",
        old_values = old_values,
        new_values = cjson.encode(update_data),
        change_reason = params.change_reason
    })

    return TaxBankAccountQueries.show(uuid, user)
end

-- Delete/deactivate bank account
function TaxBankAccountQueries.destroy(uuid, user)
    local user_uuid = user.uuid or user.id

    -- Get internal user ID
    local user_record
    if user.uuid then
        user_record = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    else
        user_record = db.query("SELECT id FROM users WHERE id = ? LIMIT 1", user_uuid)
    end
    if not user_record or #user_record == 0 then
        return false
    end
    local user_id = user_record[1].id

    local bank_account = TaxBankAccounts:find({
        uuid = uuid,
        user_id = user_id
    })

    if not bank_account then
        return false
    end

    -- Check if there are statements
    local statements = db.query("SELECT COUNT(*) as count FROM tax_statements WHERE bank_account_id = ?", bank_account.id)
    local has_statements = statements[1] and statements[1].count > 0

    if has_statements then
        -- Soft delete
        bank_account:update({ is_active = false, updated_at = db.raw("NOW()") })
    else
        -- Hard delete
        bank_account:delete()
    end

    -- Audit log
    TaxAuditLogQueries.log({
        user_id = user_id,
        user_email = user.email,
        entity_type = "BANK_ACCOUNT",
        entity_id = uuid,
        action = has_statements and "DEACTIVATE" or "DELETE"
    })

    return true, has_statements and "deactivated" or "deleted"
end

return TaxBankAccountQueries
