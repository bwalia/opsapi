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

return helper