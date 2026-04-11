local Model = require("lapis.db.model").Model

local KafkaOutbox = Model:extend("kafka_outbox", {
    timestamp = false
})

return KafkaOutbox
