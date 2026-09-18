--[[
    Regression spec for MinIO bucket creation.

    Standalone — no busted/luarocks needed. Run from the repo root with:
        luajit lapis/spec/minio-bucket_spec.lua

    Every upload path auto-creates its bucket on first use, so a broken
    createBucket takes every photo in Field Service with it. On int it did:

        502 Upload failed: Failed to create bucket: Create bucket request failed:
            Request body is nil but PUT method expects a body.

    lua-resty-http refuses a PUT whose body is nil, and creating a bucket is a PUT
    with nothing in it — so the body has to be an explicit empty string. The
    signature is computed over the empty payload (x-amz-content-sha256 = sha256("")),
    so an empty-string body is also what was signed.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

local function read(path)
    local handle = assert(io.open(path), "missing " .. path)
    local contents = handle:read("*a")
    handle:close()
    return contents
end

local minio = read("lapis/helper/minio.lua")

print("createBucket:")

-- The request options table for the PUT that creates the bucket.
local create = minio:match("function MinioClient:createBucket.-\n end") or
    minio:match("function MinioClient:createBucket.-\nend")
check("createBucket exists", create ~= nil)

if create then
    local put_options = create:match('method = "PUT".-%}')
    check("the create request is a PUT", put_options ~= nil)
    check("the PUT carries an explicit body (lua-resty-http rejects nil)",
        put_options ~= nil and put_options:find('body%s*=') ~= nil)
    check("that body is the empty payload the signature was computed over",
        put_options ~= nil and put_options:find('body%s*=%s*""') ~= nil)
    check("still signs the empty payload",
        create:find('sha256%(""%)') ~= nil)
end

print("\nevery PUT in the client:")

-- A nil body fails the same way wherever it appears, so hold the whole file to it.
local puts, bodied = 0, 0
for options in minio:gmatch('request_uri%b()') do
    if options:find('method%s*=%s*"PUT"') then
        puts = puts + 1
        if options:find('body%s*=') then bodied = bodied + 1 end
    end
end
check(("all %d PUT request(s) send a body"):format(puts), puts > 0 and puts == bodied,
    ("%d of %d"):format(bodied, puts))

print("")
if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all checks passed")
