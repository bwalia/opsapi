-- Professional Multi-Currency Utility Module
-- Provides currency formatting, validation, and conversion utilities

local db = require("lapis.db")
local cjson = require("cjson")

local CurrencyHelper = {}

-- Cache for supported currencies (loaded once on startup)
local supported_currencies_cache = nil

-- Load supported currencies from database
function CurrencyHelper.loadSupportedCurrencies()
    if supported_currencies_cache then
        return supported_currencies_cache
    end

    local success, currencies = pcall(function()
        return db.query("SELECT * FROM supported_currencies WHERE is_active = true")
    end)

    if success and currencies then
        supported_currencies_cache = {}
        for _, currency in ipairs(currencies) do
            supported_currencies_cache[currency.code] = currency
        end
        return supported_currencies_cache
    end

    -- Fallback if database table doesn't exist yet
    return CurrencyHelper.getDefaultCurrencies()
end

-- Get default currencies (fallback when DB not available)
function CurrencyHelper.getDefaultCurrencies()
    return {
        USD = { code = 'USD', name = 'US Dollar', symbol = '$', decimal_places = 2, stripe_supported = true },
        EUR = { code = 'EUR', name = 'Euro', symbol = '€', decimal_places = 2, stripe_supported = true },
        GBP = { code = 'GBP', name = 'British Pound', symbol = '£', decimal_places = 2, stripe_supported = true },
        INR = { code = 'INR', name = 'Indian Rupee', symbol = '₹', decimal_places = 2, stripe_supported = true },
        CAD = { code = 'CAD', name = 'Canadian Dollar', symbol = 'CA$', decimal_places = 2, stripe_supported = true },
        AUD = { code = 'AUD', name = 'Australian Dollar', symbol = 'A$', decimal_places = 2, stripe_supported = true },
        JPY = { code = 'JPY', name = 'Japanese Yen', symbol = '¥', decimal_places = 0, stripe_supported = true },
        CNY = { code = 'CNY', name = 'Chinese Yuan', symbol = '¥', decimal_places = 2, stripe_supported = true },
        CHF = { code = 'CHF', name = 'Swiss Franc', symbol = 'CHF', decimal_places = 2, stripe_supported = true },
        SGD = { code = 'SGD', name = 'Singapore Dollar', symbol = 'S$', decimal_places = 2, stripe_supported = true },
    }
end

-- Validate currency code
function CurrencyHelper.isValidCurrency(currency_code)
    if not currency_code or type(currency_code) ~= "string" then
        return false
    end

    local currencies = CurrencyHelper.loadSupportedCurrencies()
    return currencies[currency_code:upper()] ~= nil
end

-- Get currency symbol
function CurrencyHelper.getSymbol(currency_code)
    local currencies = CurrencyHelper.loadSupportedCurrencies()
    local currency = currencies[currency_code:upper()]
    return currency and currency.symbol or currency_code
end

-- Get currency decimal places
function CurrencyHelper.getDecimalPlaces(currency_code)
    local currencies = CurrencyHelper.loadSupportedCurrencies()
    local currency = currencies[currency_code:upper()]
    return currency and currency.decimal_places or 2
end

-- Format amount with currency symbol
-- Example: CurrencyHelper.format(1234.56, "USD") → "$1,234.56"
function CurrencyHelper.format(amount, currency_code)
    if not amount or amount == ngx.null then
        amount = 0
    end

    local currency_code_upper = currency_code and currency_code:upper() or "USD"
    local symbol = CurrencyHelper.getSymbol(currency_code_upper)
    local decimal_places = CurrencyHelper.getDecimalPlaces(currency_code_upper)

    -- Convert to number
    local num = tonumber(amount)
    if not num then
        return symbol .. "0.00"
    end

    -- Format with decimal places
    local formatted = string.format("%." .. decimal_places .. "f", num)

    -- Add thousand separators
    local parts = {}
    local int_part, dec_part = formatted:match("^(.-)%.?(.*)$")

    -- Add commas to integer part
    while true do
        local left, right = int_part:match("^(.-)(%d%d%d)$")
        if left == "" then break end
        table.insert(parts, 1, right)
        int_part = left
    end
    table.insert(parts, 1, int_part)

    local formatted_int = table.concat(parts, ",")

    if decimal_places > 0 and dec_part ~= "" then
        return symbol .. formatted_int .. "." .. dec_part
    else
        return symbol .. formatted_int
    end
end

-- Format for Stripe (convert to smallest unit)
-- USD: 100.50 → 10050 cents
-- JPY: 1000 → 1000 (no decimals)
function CurrencyHelper.toStripeAmount(amount, currency_code)
    local currency_code_upper = currency_code and currency_code:upper() or "USD"
    local decimal_places = CurrencyHelper.getDecimalPlaces(currency_code_upper)

    local num = tonumber(amount)
    if not num then
        return 0
    end

    -- Multiply by 10^decimal_places
    return math.floor(num * math.pow(10, decimal_places))
end

-- Convert from Stripe amount (smallest unit) to decimal
-- USD: 10050 cents → 100.50
-- JPY: 1000 → 1000
function CurrencyHelper.fromStripeAmount(stripe_amount, currency_code)
    local currency_code_upper = currency_code and currency_code:upper() or "USD"
    local decimal_places = CurrencyHelper.getDecimalPlaces(currency_code_upper)

    local num = tonumber(stripe_amount)
    if not num then
        return 0
    end

    -- Divide by 10^decimal_places
    return num / math.pow(10, decimal_places)
end

-- Check if currency is supported by Stripe
function CurrencyHelper.isStripeSupported(currency_code)
    local currencies = CurrencyHelper.loadSupportedCurrencies()
    local currency = currencies[currency_code:upper()]
    return currency and currency.stripe_supported or false
end

-- Get currency info for API responses
function CurrencyHelper.getCurrencyInfo(currency_code)
    local currencies = CurrencyHelper.loadSupportedCurrencies()
    local currency = currencies[currency_code:upper()]

    if currency then
        return {
            code = currency.code,
            name = currency.name,
            symbol = currency.symbol,
            decimal_places = currency.decimal_places,
            stripe_supported = currency.stripe_supported
        }
    end

    return nil
end

-- Get all active currencies
function CurrencyHelper.getAllCurrencies()
    local currencies = CurrencyHelper.loadSupportedCurrencies()
    local result = {}

    for code, currency in pairs(currencies) do
        table.insert(result, {
            code = currency.code,
            name = currency.name,
            symbol = currency.symbol,
            decimal_places = currency.decimal_places,
            stripe_supported = currency.stripe_supported
        })
    end

    -- Sort by code
    table.sort(result, function(a, b) return a.code < b.code end)

    return result
end

-- Detect currency from country code (ISO 3166-1 alpha-2)
function CurrencyHelper.detectFromCountry(country_code)
    local country_to_currency = {
        US = "USD", GB = "GBP", IN = "INR", CA = "CAD", AU = "AUD",
        JP = "JPY", CN = "CNY", CH = "CHF", SG = "SGD",
        -- European Union countries
        DE = "EUR", FR = "EUR", IT = "EUR", ES = "EUR", NL = "EUR",
        BE = "EUR", AT = "EUR", PT = "EUR", IE = "EUR", FI = "EUR",
        GR = "EUR", LU = "EUR", SI = "EUR", CY = "EUR", MT = "EUR",
        SK = "EUR", EE = "EUR", LV = "EUR", LT = "EUR",
    }

    return country_to_currency[country_code:upper()] or "USD"
end

-- Clear cache (for testing or when currencies are updated)
function CurrencyHelper.clearCache()
    supported_currencies_cache = nil
end

return CurrencyHelper
