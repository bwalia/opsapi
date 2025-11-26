--[[
    Chat Helper Functions

    Common utility functions for the chat system
]]

local cjson = require("cjson.safe")

local ChatHelper = {}

-- Extract @mentions from message content
-- Supports @username and @uuid formats
function ChatHelper.extractMentions(content)
    if not content then return {} end

    local mentions = {}
    local seen = {}

    -- Match @username or @uuid patterns
    for mention in string.gmatch(content, "@([%w%-_]+)") do
        if not seen[mention] then
            table.insert(mentions, mention)
            seen[mention] = true
        end
    end

    return mentions
end

-- Check for special mentions (@everyone, @here, @channel)
function ChatHelper.extractSpecialMentions(content)
    if not content then return {} end

    local special = {}

    if string.match(content, "@everyone") then
        table.insert(special, "everyone")
    end
    if string.match(content, "@here") then
        table.insert(special, "here")
    end
    if string.match(content, "@channel") then
        table.insert(special, "channel")
    end

    return special
end

-- Extract task references from content (#TASK-123)
function ChatHelper.extractTaskRefs(content)
    if not content then return {} end

    local tasks = {}

    -- Match #TASK-123 or #task-123 pattern
    for task_id in string.gmatch(content, "#[Tt][Aa][Ss][Kk]%-(%d+)") do
        table.insert(tasks, task_id)
    end

    return tasks
end

-- Extract URLs from content
function ChatHelper.extractUrls(content)
    if not content then return {} end

    local urls = {}

    -- Simple URL pattern
    for url in string.gmatch(content, "https?://[%w%.%-_/%%?&=#+]+") do
        table.insert(urls, url)
    end

    return urls
end

-- Sanitize HTML/script tags from content
function ChatHelper.sanitizeHtml(content)
    if not content then return "" end

    -- Remove script tags
    content = string.gsub(content, "<script[^>]*>.-</script>", "")

    -- Remove dangerous attributes
    content = string.gsub(content, "on%w+%s*=%s*[\"'][^\"']*[\"']", "")

    -- Escape HTML entities
    content = string.gsub(content, "<", "&lt;")
    content = string.gsub(content, ">", "&gt;")

    return content
end

-- Truncate content with ellipsis
function ChatHelper.truncate(content, max_length)
    if not content then return "" end
    max_length = max_length or 100

    if string.len(content) <= max_length then
        return content
    end

    return string.sub(content, 1, max_length - 3) .. "..."
end

-- Format message content for preview (strip markdown, truncate)
function ChatHelper.formatPreview(content, max_length)
    if not content then return "" end
    max_length = max_length or 50

    -- Remove markdown formatting
    content = string.gsub(content, "%*%*(.-)%*%*", "%1") -- bold
    content = string.gsub(content, "%*(.-)%*", "%1") -- italic
    content = string.gsub(content, "~~(.-)~~", "%1") -- strikethrough
    content = string.gsub(content, "`(.-)`", "%1") -- code
    content = string.gsub(content, "```.-```", "[code]") -- code blocks
    content = string.gsub(content, "\n", " ") -- newlines

    return ChatHelper.truncate(content, max_length)
end

-- Parse JSON safely
function ChatHelper.parseJson(json_string)
    if not json_string or json_string == "" then
        return nil
    end

    local data, err = cjson.decode(json_string)
    if not data then
        ngx.log(ngx.ERR, "JSON parse error: ", err)
        return nil
    end

    return data
end

-- Encode to JSON safely
function ChatHelper.toJson(data)
    if not data then return "{}" end

    local json, err = cjson.encode(data)
    if not json then
        ngx.log(ngx.ERR, "JSON encode error: ", err)
        return "{}"
    end

    return json
end

-- Get file extension from filename
function ChatHelper.getFileExtension(filename)
    if not filename then return nil end
    return string.match(filename, "%.([^%.]+)$")
end

-- Get MIME type category
function ChatHelper.getMimeCategory(mime_type)
    if not mime_type then return "other" end

    if string.match(mime_type, "^image/") then
        return "image"
    elseif string.match(mime_type, "^video/") then
        return "video"
    elseif string.match(mime_type, "^audio/") then
        return "audio"
    elseif string.match(mime_type, "^text/") then
        return "text"
    elseif string.match(mime_type, "pdf") then
        return "document"
    elseif string.match(mime_type, "word") or string.match(mime_type, "document") then
        return "document"
    elseif string.match(mime_type, "sheet") or string.match(mime_type, "excel") then
        return "spreadsheet"
    elseif string.match(mime_type, "presentation") or string.match(mime_type, "powerpoint") then
        return "presentation"
    elseif string.match(mime_type, "zip") or string.match(mime_type, "compressed") or string.match(mime_type, "archive") then
        return "archive"
    else
        return "other"
    end
end

-- Check if file type is allowed
function ChatHelper.isAllowedFileType(mime_type)
    local allowed = {
        -- Images
        ["image/jpeg"] = true,
        ["image/png"] = true,
        ["image/gif"] = true,
        ["image/webp"] = true,
        ["image/svg+xml"] = true,
        -- Documents
        ["application/pdf"] = true,
        ["application/msword"] = true,
        ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"] = true,
        ["application/vnd.ms-excel"] = true,
        ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"] = true,
        ["application/vnd.ms-powerpoint"] = true,
        ["application/vnd.openxmlformats-officedocument.presentationml.presentation"] = true,
        -- Text
        ["text/plain"] = true,
        ["text/csv"] = true,
        ["text/html"] = true,
        ["text/markdown"] = true,
        -- Archives
        ["application/zip"] = true,
        ["application/x-rar-compressed"] = true,
        ["application/gzip"] = true,
        -- Audio
        ["audio/mpeg"] = true,
        ["audio/wav"] = true,
        ["audio/ogg"] = true,
        -- Video
        ["video/mp4"] = true,
        ["video/webm"] = true,
        ["video/quicktime"] = true,
    }

    return allowed[mime_type] == true
end

-- Format file size for display
function ChatHelper.formatFileSize(bytes)
    bytes = tonumber(bytes)
    if not bytes or bytes < 1024 then
        return bytes .. " B"
    elseif bytes < 1048576 then
        return string.format("%.1f KB", bytes / 1024)
    elseif bytes < 1073741824 then
        return string.format("%.1f MB", bytes / 1048576)
    else
        return string.format("%.1f GB", bytes / 1073741824)
    end
end

-- Time ago in words
function ChatHelper.timeAgo(timestamp)
    if not timestamp then return "never" end

    local now = ngx.now()
    local diff = now - timestamp

    if diff < 60 then
        return "just now"
    elseif diff < 3600 then
        local minutes = math.floor(diff / 60)
        return minutes .. " minute" .. (minutes > 1 and "s" or "") .. " ago"
    elseif diff < 86400 then
        local hours = math.floor(diff / 3600)
        return hours .. " hour" .. (hours > 1 and "s" or "") .. " ago"
    elseif diff < 604800 then
        local days = math.floor(diff / 86400)
        return days .. " day" .. (days > 1 and "s" or "") .. " ago"
    else
        return os.date("%Y-%m-%d %H:%M", timestamp)
    end
end

-- Generate slug from string
function ChatHelper.slugify(str)
    if not str then return "" end

    str = string.lower(str)
    str = string.gsub(str, "%s+", "-")
    str = string.gsub(str, "[^%w%-]", "")
    str = string.gsub(str, "%-+", "-")
    str = string.gsub(str, "^%-+", "")
    str = string.gsub(str, "%-+$", "")

    return str
end

-- Validate channel name
function ChatHelper.validateChannelName(name)
    if not name or name == "" then
        return false, "Channel name is required"
    end

    if string.len(name) < 1 then
        return false, "Channel name must be at least 1 character"
    end

    if string.len(name) > 100 then
        return false, "Channel name must be less than 100 characters"
    end

    return true
end

-- Validate message content
function ChatHelper.validateMessageContent(content)
    if not content or content == "" then
        return false, "Message content is required"
    end

    if string.len(content) > 10000 then
        return false, "Message content must be less than 10000 characters"
    end

    return true
end

-- Check if user can perform action on channel
function ChatHelper.canPerformAction(member_role, action)
    local permissions = {
        admin = {
            delete_channel = true,
            update_channel = true,
            add_members = true,
            remove_members = true,
            change_roles = true,
            pin_messages = true,
            delete_any_message = true,
        },
        moderator = {
            add_members = true,
            remove_members = true,
            pin_messages = true,
            delete_any_message = true,
        },
        member = {
            send_message = true,
            add_reaction = true,
            delete_own_message = true,
        }
    }

    local role_perms = permissions[member_role]
    if not role_perms then return false end

    return role_perms[action] == true
end

return ChatHelper
