--[[
    TLS Peer Certificate Fetcher
    ============================

    Reads a remote host's leaf TLS certificate (notAfter + issuer) WITHOUT the
    OpenResty cosocket→SSL bridge (this build lacks lua-resty-openssl-aux-module,
    so resty.openssl.ssl.from_socket is unavailable).

    Approach: open a raw TCP socket and send a minimal TLS 1.2 ClientHello that
    deliberately does NOT advertise TLS 1.3 (no supported_versions extension), so
    the server replies with a TLS 1.2 handshake whose Certificate message is sent
    in cleartext. We parse the handshake records, pull the leaf certificate DER,
    and hand it to resty.openssl.x509 (which loads fine — only the socket bridge
    was missing) to read notAfter + issuer.

    Limitation: a TLS 1.3-only server (rare) that refuses TLS 1.2 will not return
    a cleartext Certificate; check_ssl degrades gracefully in that case.
]]

local byte, char, sub = string.byte, string.char, string.sub

local TLSCert = {}

-- 16-bit / 24-bit big-endian encoders
local function u16(n) return char(math.floor(n / 256) % 256, n % 256) end
local function u24(n) return char(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256) end
local function u16be(s, off) return byte(s, off) * 256 + byte(s, off + 1) end
local function u24be(s, off) return byte(s, off) * 65536 + byte(s, off + 1) * 256 + byte(s, off + 2) end

-- Build a ClientHello TLS record for the given SNI hostname.
local function client_hello(host)
    -- 32-byte "random" — cryptographic strength is irrelevant here (we never
    -- derive keys); Math.random is unavailable in this runtime anyway.
    local rnd = "opsapi-domain-tls-probe-0000000\0"
    rnd = sub((rnd .. rnd), 1, 32)

    local cipher_suites = {
        0xc02f, 0xc030, 0xc02b, 0xc02c, -- ECDHE-(RSA|ECDSA)-AES-GCM
        0x009c, 0x009d,                 -- RSA-AES-GCM
        0x002f, 0x0035,                 -- RSA-AES-CBC-SHA
        0x000a,                         -- RSA-3DES (legacy fallback)
        0x00ff,                         -- TLS_EMPTY_RENEGOTIATION_INFO_SCSV
    }
    local cs = {}
    for _, c in ipairs(cipher_suites) do cs[#cs + 1] = u16(c) end
    cs = table.concat(cs)

    -- Extensions ----------------------------------------------------------
    -- SNI (server_name). Entry = name_type(1 byte, 0=host_name) + name(u16 len + bytes)
    local sni_host = host
    local sni_entry = char(0) .. u16(#sni_host) .. sni_host
    local sni_list = u16(#sni_entry) .. sni_entry   -- ServerNameList
    local ext_sni = u16(0x0000) .. u16(#sni_list) .. sni_list

    -- supported_groups: x25519, secp256r1, secp384r1
    local groups = u16(0x001d) .. u16(0x0017) .. u16(0x0018)
    local sg = u16(#groups) .. groups
    local ext_groups = u16(0x000a) .. u16(#sg) .. sg

    -- ec_point_formats: uncompressed
    local epf = char(1) .. char(0)
    local ext_epf = u16(0x000b) .. u16(#epf) .. epf

    -- signature_algorithms
    local sigs = {
        0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501,
        0x0806, 0x0601, 0x0201, 0x0203,
    }
    local sa = {}
    for _, s in ipairs(sigs) do sa[#sa + 1] = u16(s) end
    sa = table.concat(sa)
    sa = u16(#sa) .. sa
    local ext_sa = u16(0x000d) .. u16(#sa) .. sa

    local extensions = ext_sni .. ext_groups .. ext_epf .. ext_sa
    local ext_block = u16(#extensions) .. extensions

    -- ClientHello body ----------------------------------------------------
    local body = u16(0x0303)            -- client_version = TLS 1.2
        .. rnd                          -- random
        .. char(0)                      -- session_id length = 0
        .. u16(#cs) .. cs               -- cipher_suites
        .. char(1) .. char(0)           -- compression_methods: null
        .. ext_block

    local handshake = char(1) .. u24(#body) .. body      -- type 1 = ClientHello
    local record = char(22) .. u16(0x0301) .. u16(#handshake) .. handshake
    return record
end

-- Read one TLS record. Returns content_type, payload or nil, err.
local function read_record(sock)
    local hdr, err = sock:receive(5)
    if not hdr then return nil, "record header: " .. tostring(err) end
    local ctype = byte(hdr, 1)
    local len = u16be(hdr, 4)
    if len == 0 then return ctype, "" end
    local payload, perr = sock:receive(len)
    if not payload then return nil, "record body: " .. tostring(perr) end
    return ctype, payload
end

-- From an accumulated handshake byte-stream, find the Certificate (type 11)
-- message and return the leaf certificate DER, or nil if not yet present.
local function extract_leaf_cert(hs)
    local i = 1
    local n = #hs
    while i + 4 <= n + 1 do
        local mtype = byte(hs, i)
        local mlen = u24be(hs, i + 1)
        local body_start = i + 4
        if body_start + mlen - 1 > n then
            return nil -- incomplete message; need more records
        end
        if mtype == 11 then -- Certificate
            -- body: certs_len(3) then [ cert_len(3) cert(der) ]...
            local p = body_start
            -- local certs_len = u24be(hs, p)  -- total, unused
            p = p + 3
            local cert_len = u24be(hs, p)
            p = p + 3
            return sub(hs, p, p + cert_len - 1)
        end
        i = body_start + mlen
    end
    return nil
end

--- Fetch the leaf certificate's expiry + issuer for host:port.
-- @return { not_after = <epoch>, issuer = <string> } or nil, err
function TLSCert.fetch(host, port, timeout)
    port = port or 443
    local sock = ngx.socket.tcp()
    sock:settimeout(timeout or 8000)

    local ok, cerr = sock:connect(host, port)
    if not ok then return nil, "TCP connect failed: " .. tostring(cerr) end

    local bytes_sent, serr = sock:send(client_hello(host))
    if not bytes_sent then sock:close(); return nil, "send ClientHello: " .. tostring(serr) end

    local hs = {}
    local hs_len = 0
    local leaf = nil
    -- Read up to a bounded number of records for the handshake certificate.
    for _ = 1, 24 do
        local ctype, payload = read_record(sock)
        if not ctype then break end
        if ctype == 21 then -- Alert
            sock:close()
            return nil, "server sent TLS alert (likely TLS 1.3-only or handshake refused)"
        elseif ctype == 22 then -- Handshake
            hs[#hs + 1] = payload
            hs_len = hs_len + #payload
            local joined = table.concat(hs)
            leaf = extract_leaf_cert(joined)
            if leaf then break end
        end
        -- ignore other content types (e.g. ChangeCipherSpec)
        if hs_len > 65536 then break end
    end
    sock:close()

    if not leaf then
        return nil, "no Certificate message received"
    end

    local x509_ok, x509 = pcall(require, "resty.openssl.x509")
    if not x509_ok then return nil, "resty.openssl.x509 not available: " .. tostring(x509) end

    local cert, e1 = x509.new(leaf, "DER")
    if not cert then return nil, "parse cert: " .. tostring(e1) end

    local not_after, e2 = cert:get_not_after()
    if not not_after then return nil, "no notAfter: " .. tostring(e2) end

    local out = { not_after = not_after }
    local ok_iss, issuer = pcall(function() return cert:get_issuer_name() end)
    if ok_iss and issuer then
        out.issuer = tostring(issuer):sub(1, 255)
    end
    return out, nil
end

return TLSCert
