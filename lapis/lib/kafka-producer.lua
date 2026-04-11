--[[
    Kafka Producer Module

    Provides reliable message publishing to Kafka with transactional outbox fallback.
    Uses lua-resty-kafka-fast when available, otherwise falls back to outbox-only mode.

    Usage:
        local KafkaProducer = require("lib.kafka-producer")
        KafkaProducer.init()
        KafkaProducer.send("timesheet.submitted", tenant_id, {
            tenant_id = namespace_id,
            user_id = user_uuid,
            timesheet_id = ts_uuid,
            timestamp = ngx.now()
        })
]]--

local cjson = require("cjson")
local db = require("lapis.db")
local Global = require("helper.global")

local KafkaProducer = {}

local _producer = nil
local _kafka_available = false
local _broker_list = {}

-- Parse KAFKA_BROKERS env var into broker list table
-- Format: "host1:port1,host2:port2"
local function parse_brokers(brokers_str)
    local brokers = {}
    for entry in brokers_str:gmatch("[^,]+") do
        local host, port = entry:match("^%s*(.+):(%d+)%s*$")
        if host and port then
            table.insert(brokers, { host = host, port = tonumber(port) })
        end
    end
    return brokers
end

-- Write message to kafka_outbox table for later delivery
local function write_to_outbox(topic, key, message_table)
    local ok, err = pcall(function()
        db.query([[
            INSERT INTO kafka_outbox (uuid, topic, key, payload, status, next_retry_at)
            VALUES (?, ?, ?, ?::jsonb, 'pending', NOW())
        ]], Global.generateUUID(), topic, key, cjson.encode(message_table))
    end)

    if not ok then
        ngx.log(ngx.ERR, "Failed to write to kafka_outbox: ", err)
        return false, err
    end

    return true
end

-- Initialize the Kafka producer instance
function KafkaProducer.init()
    local brokers_env = os.getenv("KAFKA_BROKERS") or "kafka:9092"
    _broker_list = parse_brokers(brokers_env)

    if #_broker_list == 0 then
        ngx.log(ngx.WARN, "No valid Kafka brokers parsed, using outbox-only mode")
        _kafka_available = false
        return
    end

    local ok, producer_mod = pcall(require, "resty.kafka.producer")
    if not ok then
        ngx.log(ngx.WARN, "lua-resty-kafka-fast not available, using outbox-only mode: ", producer_mod)
        _kafka_available = false
        return
    end

    local create_ok, p = pcall(function()
        return producer_mod:new(_broker_list, { producer_type = "async" })
    end)

    if not create_ok or not p then
        ngx.log(ngx.WARN, "Failed to create Kafka producer, using outbox-only mode: ", tostring(p))
        _kafka_available = false
        return
    end

    _producer = p
    _kafka_available = true
    ngx.log(ngx.INFO, "Kafka producer initialized with ", #_broker_list, " broker(s)")
end

-- Send a message to Kafka topic with outbox fallback
-- @param topic string - Kafka topic name
-- @param key string|nil - Message key (used for partitioning)
-- @param message_table table - Message payload (will be JSON-encoded)
-- @return boolean, string|nil - success, error message
function KafkaProducer.send(topic, key, message_table)
    if not topic then
        return false, "topic is required"
    end

    local message_json = cjson.encode(message_table or {})
    local key_str = key and tostring(key) or nil

    -- Attempt direct Kafka send if available
    if _kafka_available and _producer then
        local send_ok, send_err = pcall(function()
            local ok, err = _producer:send(topic, key_str, message_json)
            if not ok then
                error(err)
            end
        end)

        if send_ok then
            return true
        end

        ngx.log(ngx.WARN, "Kafka send failed, falling back to outbox: ", send_err)
    end

    -- Fall back to outbox
    return write_to_outbox(topic, key_str, message_table)
end

-- Check if Kafka is available (direct mode vs outbox-only)
function KafkaProducer.is_available()
    return _kafka_available
end

return KafkaProducer
