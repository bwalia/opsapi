-- Luacheck configuration for OpenResty/Lapis project

-- Define globals available in OpenResty environment
globals = {
    "ngx",  -- OpenResty nginx Lua API
}

-- Standard Lua 5.1 compatibility
std = "min"

-- Ignore specific warnings if needed
-- ignore = {}

-- Set line length limit
max_line_length = 120