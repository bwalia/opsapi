--[[
    Kafka Consumer Module

    Provides background Kafka message consumption with:
    - Topic subscription with handler functions
    - At-least-once delivery with idempotency via audit_events table
    - Retry logic with exponential backoff
    - Graceful degradation when lua-resty-kafka-fast is unavailable

    Usage:
        local KafkaConsumer = require("lib.kafka-consumer")
        KafkaConsumer.subscribe("timesheet.submitted", function(payload)
            -- process the message
        end)
        KafkaConsumer.start()
]]--

local cjson = require("cjson")
local db = require("lapis.db")
local Global = require("helper.global")

local KafkaConsumer = {}

local _handlers = {}
local _running = false
local _consumer = nil
local _kafka_available = false
local _broker_list = {}

-- Configuration
local POLL_INTERVAL = 1       -- seconds between polls
local MAX_RETRIES = 5
local BASE_BACKOFF = 1        -- base seconds for exponential backoff

-- Parse KAFKA_BROKERS env var into broker list table
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

-- Check if a message has already been processed (idempotency via audit_events)
local function is_already_processed(topic, partition, offset)
    local result = db.query([[
        SELECT id FROM audit_events
        WHERE kafka_topic = ? AND kafka_partition = ? AND kafka_offset = ?
        LIMIT 1
    ]], topic, partition, offset)
    return result and #result > 0
end

-- Record a processed message in audit_events for idempotency
local function record_processed(topic, partition, offset, message_payload)
    pcall(function()
        db.query([[
            INSERT INTO audit_events (uuid, namespace_id, event_type, entity_type, metadata, kafka_topic, kafka_partition, kafka_offset)
            VALUES (?, 0, ?, 'kafka_message', ?::jsonb, ?, ?, ?)
        ]], Global.generateUUID(), "kafka.consumed", cjson.encode(message_payload or {}), topic, partition, offset)
    end)
end

-- Process a single message with retry logic
local function process_message(topic, partition, offset, raw_message)
    -- Idempotency check
    if is_already_processed(topic, partition, offset) then
        ngx.log(ngx.DEBUG, "Skipping already-processed message: ", topic, "/", partition, "/", offset)
        return true
    end

    -- Decode message
    local decode_ok, payload = pcall(cjson.decode, raw_message)
    if not decode_ok then
        ngx.log(ngx.ERR, "Failed to decode Kafka message: ", raw_message)
        return false, "JSON decode error"
    end

    -- Find handlers for this topic
    local topic_handlers = _handlers[topic]
    if not topic_handlers or #topic_handlers == 0 then
        ngx.log(ngx.WARN, "No handlers registered for topic: ", topic)
        return true
    end

    -- Execute each handler with retries
    for _, handler in ipairs(topic_handlers) do
        local success = false
        local last_err = nil

        for attempt = 1, MAX_RETRIES do
            local handler_ok, handler_err = pcall(handler, payload)
            if handler_ok then
                success = true
                break
            end

            last_err = handler_err
            local backoff = BASE_BACKOFF * (2 ^ (attempt - 1))
            ngx.log(ngx.WARN, string.format(
                "Handler failed for %s (attempt %d/%d), retrying in %ds: %s",
                topic, attempt, MAX_RETRIES, backoff, tostring(handler_err)
            ))

            -- Sleep for backoff period
            ngx.sleep(backoff)
        end

        if not success then
            ngx.log(ngx.ERR, "Handler exhausted retries for topic ", topic, ": ", tostring(last_err))
            return false, last_err
        end
    end

    -- Record successful processing for idempotency
    record_processed(topic, partition, offset, payload)
    return true
end

-- Background consumer loop (runs via ngx.timer.at)
local function consumer_loop(premature)
    if premature then
        return
    end

    if not _running then
        return
    end

    -- Process messages from Kafka if available
    if _kafka_available and _consumer then
        local poll_ok, poll_err = pcall(function()
            -- Attempt to fetch messages from subscribed topics
            for topic, _ in pairs(_handlers) do
                local fetch_ok, messages = pcall(function()
                    return _consumer:fetch(topic, 0, 0)  -- partition 0, offset from last
                end)

                if fetch_ok and messages then
                    for _, msg in ipairs(messages) do
                        process_message(topic, msg.partition or 0, msg.offset or 0, msg.value or msg.message)
                    end
                end
            end
        end)

        if not poll_ok then
            ngx.log(ngx.ERR, "Kafka consumer poll error: ", poll_err)
        end
    end

    -- Process outbox messages as a fallback/supplement
    local outbox_ok, outbox_err = pcall(function()
        local pending = db.query([[
            SELECT id, uuid, topic, key, payload, retry_count, max_retries
            FROM kafka_outbox
            WHERE status = 'pending'
            AND (next_retry_at IS NULL OR next_retry_at <= NOW())
            ORDER BY created_at ASC
            LIMIT 100
        ]])

        if pending then
            for _, msg in ipairs(pending) do
                local topic_handlers = _handlers[msg.topic]
                if topic_handlers and #topic_handlers > 0 then
                    local decode_ok, payload = pcall(cjson.decode, msg.payload)
                    if decode_ok then
                        local all_ok = true
                        for _, handler in ipairs(topic_handlers) do
                            local h_ok, h_err = pcall(handler, payload)
                            if not h_ok then
                                all_ok = false
                                ngx.log(ngx.ERR, "Outbox handler failed for ", msg.topic, ": ", h_err)
                            end
                        end

                        if all_ok then
                            db.query("UPDATE kafka_outbox SET status = 'sent', sent_at = NOW() WHERE id = ?", msg.id)
                        else
                            local new_retry = (msg.retry_count or 0) + 1
                            if new_retry >= (msg.max_retries or 5) then
                                db.query("UPDATE kafka_outbox SET status = 'failed', failed_at = NOW(), retry_count = ? WHERE id = ?",
                                    new_retry, msg.id)
                            else
                                local backoff = BASE_BACKOFF * (2 ^ new_retry)
                                db.query("UPDATE kafka_outbox SET retry_count = ?, next_retry_at = NOW() + INTERVAL '" .. backoff .. " seconds' WHERE id = ?",
                                    new_retry, msg.id)
                            end
                        end
                    end
                end
            end
        end
    end)

    if not outbox_ok then
        ngx.log(ngx.ERR, "Outbox processing error: ", outbox_err)
    end

    -- Schedule next iteration
    if _running then
        ngx.timer.at(POLL_INTERVAL, consumer_loop)
    end
end

-- Register a handler for a topic
-- @param topic string - Kafka topic to subscribe to
-- @param handler function - Handler function receiving (payload_table)
function KafkaConsumer.subscribe(topic, handler)
    if not _handlers[topic] then
        _handlers[topic] = {}
    end
    table.insert(_handlers[topic], handler)
    ngx.log(ngx.INFO, "Subscribed handler to topic: ", topic)
end

-- Start the consumer background loop
function KafkaConsumer.start()
    if _running then
        ngx.log(ngx.WARN, "Kafka consumer is already running")
        return
    end

    -- Initialize broker list
    local brokers_env = os.getenv("KAFKA_BROKERS") or "kafka:9092"
    _broker_list = parse_brokers(brokers_env)

    -- Try to create Kafka consumer
    local ok, consumer_mod = pcall(require, "resty.kafka.consumer")
    if ok then
        local create_ok, c = pcall(function()
            return consumer_mod:new(_broker_list)
        end)

        if create_ok and c then
            _consumer = c
            _kafka_available = true
            ngx.log(ngx.INFO, "Kafka consumer initialized with ", #_broker_list, " broker(s)")
        else
            ngx.log(ngx.WARN, "Failed to create Kafka consumer, will process outbox only: ", tostring(c))
            _kafka_available = false
        end
    else
        ngx.log(ngx.WARN, "lua-resty-kafka-fast consumer not available, will process outbox only")
        _kafka_available = false
    end

    _running = true
    ngx.timer.at(0, consumer_loop)
    ngx.log(ngx.INFO, "Kafka consumer started")
end

-- Stop the consumer loop
function KafkaConsumer.stop()
    _running = false
    ngx.log(ngx.INFO, "Kafka consumer stopped")
end

-- Check if consumer is running
function KafkaConsumer.is_running()
    return _running
end

return KafkaConsumer
