local cjson = require "cjson"
local lfs = require "lfs"
local helper = {}

function helper.create_directory_if_not_exists(directory)
    local command = string.format("mkdir -p %s", directory)
    local status = os.execute(command)
    if status then
        return true
    else
        return false
    end
end

function helper.get_files_in_directory(directory)
    local files = {}
    for file in lfs.dir(directory) do
        if file ~= "." and file ~= ".." then
            table.insert(files, file)
        end
    end
    return files
end

function helper.sort_files_by_timestamp(files)
    table.sort(files)
    return files
end

function helper.read_file(file_path)
    local file = io.open(file_path, "r")
    if not file then
        return nil, "Cannot open file: " .. file_path
    end
    local content = file:read("*all")
    file:close()
    return content
end

function helper.contains(str, substr)
    if #substr == 0 then return true end
    return string.find(str, substr, 1, true) ~= nil
end

function helper.GetPayloads(body)
    local keyset = {}
    local n = 0
    for k, v in pairs(body) do
        n = n + 1
        if type(v) == "string" then
            if v ~= nil and v ~= "" then
                table.insert(keyset, cjson.decode(k .. v))
            end
        else
            table.insert(keyset, cjson.decode(k))
        end
    end
    return keyset[1]
end

function helper.generate_uuid()
    local random = math.random(1000000000)
    local timestamp = os.time()
    local hash = ngx.md5(tostring(random) .. tostring(timestamp))
    local uuid = string.format("%s-%s-%s-%s-%s", string.sub(hash, 1, 8), string.sub(hash, 9, 12),
        string.sub(hash, 13, 16), string.sub(hash, 17, 20), string.sub(hash, 21, 32))
    return uuid
end

return helper