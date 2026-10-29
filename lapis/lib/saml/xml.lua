--[[
    SAML XML: parsing, XPath and XML-DSig verification (libxml2 via FFI)
    ====================================================================
    libxml2 ships in the OpenResty image (nginx's xslt module needs it), so
    SAML needs no extra system package. Only what SAML 2.0 Web SSO uses is
    supported:

      canonicalization  exc-c14n (with or without comments, InclusiveNamespaces),
                        c14n 1.0 for SignedInfo
      transforms        enveloped-signature + one of the c14n methods above
      digests           sha256 / sha384 / sha512   (sha1 is refused)
      signatures        rsa-sha256 / rsa-sha384 / rsa-sha512

    Defences that matter (signature wrapping, XXE):
      - documents with a DTD are refused, the network is never touched, entities
        are never expanded;
      - a signature is only accepted on the element that is its PARENT, and the
        Reference URI must be "#" .. that element's ID, and that ID must be unique
        in the document. Callers then read data from that same node, never via a
        fresh document-wide search;
      - the key is always the certificate configured for the IdP — any
        KeyInfo/X509Certificate inside the message is ignored.
]]

local ffi = require("ffi")
local C = ffi.C

ffi.cdef [[
typedef unsigned char xmlChar;
typedef struct _xmlNs {
    struct _xmlNs *next; int type; const xmlChar *href; const xmlChar *prefix;
    void *_private; void *context;
} xmlNs;
typedef struct _xmlNode {
    void *_private; int type; const xmlChar *name;
    struct _xmlNode *children; struct _xmlNode *last; struct _xmlNode *parent;
    struct _xmlNode *next; struct _xmlNode *prev; void *doc;
    xmlNs *ns; xmlChar *content; void *properties; xmlNs *nsDef;
    void *psvi; unsigned short line; unsigned short extra;
} xmlNode;
typedef struct _xmlNodeSet { int nodeNr; int nodeMax; xmlNode **nodeTab; } xmlNodeSet;
typedef struct _xmlXPathObject {
    int type; xmlNodeSet *nodesetval; int boolval; double floatval; xmlChar *stringval;
    void *user; int index; void *user2; int index2;
} xmlXPathObject;
typedef struct _xmlDoc xmlDoc;
typedef struct _xmlXPathContext xmlXPathContext;

xmlDoc *xmlReadMemory(const char *buffer, int size, const char *URL, const char *encoding, int options);
void xmlFreeDoc(xmlDoc *doc);
xmlNode *xmlDocGetRootElement(const xmlDoc *doc);
void *xmlGetIntSubset(const xmlDoc *doc);
xmlXPathContext *xmlXPathNewContext(xmlDoc *doc);
void xmlXPathFreeContext(xmlXPathContext *ctx);
int xmlXPathRegisterNs(xmlXPathContext *ctx, const xmlChar *prefix, const xmlChar *ns_uri);
xmlXPathObject *xmlXPathNodeEval(xmlNode *node, const xmlChar *str, xmlXPathContext *ctx);
void xmlXPathFreeObject(xmlXPathObject *obj);
xmlChar *xmlGetNoNsProp(const xmlNode *node, const xmlChar *name);
xmlChar *xmlNodeGetContent(const xmlNode *cur);
int xmlC14NDocDumpMemory(xmlDoc *doc, xmlNodeSet *nodes, int mode, xmlChar **inclusive_ns_prefixes,
                         int with_comments, xmlChar **doc_txt_ptr);
void xmlUnlinkNode(xmlNode *cur);
xmlNode *xmlAddPrevSibling(xmlNode *cur, xmlNode *elem);
xmlNode *xmlAddChild(xmlNode *parent, xmlNode *cur);
void free(void *ptr);
]]

-- Only the versioned soname is installed (no -dev package).
local lib
for _, name in ipairs({ "libxml2.so.2", "xml2", "libxml2.2.dylib" }) do
    local ok, l = pcall(ffi.load, name)
    if ok then lib = l break end
end
assert(lib, "libxml2 not found")

local M = {}

M.NS = {
    samlp = "urn:oasis:names:tc:SAML:2.0:protocol",
    saml = "urn:oasis:names:tc:SAML:2.0:assertion",
    ds = "http://www.w3.org/2000/09/xmldsig#",
    ec = "http://www.w3.org/2001/10/xml-exc-c14n#",
    md = "urn:oasis:names:tc:SAML:2.0:metadata",
    xenc = "http://www.w3.org/2001/04/xmlenc#",
}

-- XML_PARSE_NOERROR | XML_PARSE_NOWARNING | XML_PARSE_NONET
local PARSE_OPTIONS = 32 + 64 + 2048
local MAX_XML_BYTES = 512 * 1024
local XML_ELEMENT_NODE = 1

local C14N = {
    ["http://www.w3.org/2001/10/xml-exc-c14n#"]              = { mode = 1, comments = 0 },
    ["http://www.w3.org/2001/10/xml-exc-c14n#WithComments"]  = { mode = 1, comments = 1 },
    ["http://www.w3.org/TR/2001/REC-xml-c14n-20010315"]      = { mode = 0, comments = 0 },
    ["http://www.w3.org/TR/2001/REC-xml-c14n-20010315#WithComments"] = { mode = 0, comments = 1 },
}
local ENVELOPED = "http://www.w3.org/2000/09/xmldsig#enveloped-signature"
local DIGESTS = {
    ["http://www.w3.org/2001/04/xmlenc#sha256"] = "sha256",
    ["http://www.w3.org/2001/04/xmldsig-more#sha384"] = "sha384",
    ["http://www.w3.org/2001/04/xmlenc#sha512"] = "sha512",
}
local SIGNATURES = {
    ["http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"] = "sha256",
    ["http://www.w3.org/2001/04/xmldsig-more#rsa-sha384"] = "sha384",
    ["http://www.w3.org/2001/04/xmldsig-more#rsa-sha512"] = "sha512",
}

local function take_string(ptr)
    if ptr == nil then return nil end
    local s = ffi.string(ptr)
    C.free(ptr)
    return s
end

local Doc = {}
Doc.__index = Doc

--- Parse an XML string. Returns a Doc, or nil and a reason.
function M.parse(xml)
    if type(xml) ~= "string" or xml == "" then return nil, "empty document" end
    if #xml > MAX_XML_BYTES then return nil, "document too large" end
    local raw = lib.xmlReadMemory(xml, #xml, nil, nil, PARSE_OPTIONS)
    if raw == nil then return nil, "not well-formed XML" end
    local doc = ffi.gc(raw, lib.xmlFreeDoc)
    if lib.xmlGetIntSubset(doc) ~= nil then return nil, "DTDs are not allowed" end
    local ctx = lib.xmlXPathNewContext(doc)
    if ctx == nil then return nil, "XPath context unavailable" end
    ctx = ffi.gc(ctx, lib.xmlXPathFreeContext)
    for prefix, uri in pairs(M.NS) do lib.xmlXPathRegisterNs(ctx, prefix, uri) end
    return setmetatable({ doc = doc, ctx = ctx }, Doc)
end

function Doc:root()
    local r = lib.xmlDocGetRootElement(self.doc)
    return r ~= nil and r or nil
end

--- Nodes matching `expr`, evaluated with `node` (default: the root) as context.
function Doc:find(expr, node)
    node = node or self:root()
    if not node then return {} end
    local obj = lib.xmlXPathNodeEval(node, expr, self.ctx)
    if obj == nil then return {} end
    local out = {}
    local set = obj.nodesetval
    if set ~= nil then
        for i = 0, set.nodeNr - 1 do out[#out + 1] = set.nodeTab[i] end
    end
    lib.xmlXPathFreeObject(obj)
    return out
end

function Doc:one(expr, node)
    local list = self:find(expr, node)
    return list[1], #list
end

function Doc:text(expr, node)
    local n = self:one(expr, node)
    if not n then return nil end
    local s = take_string(lib.xmlNodeGetContent(n))
    return s and (s:gsub("^%s+", ""):gsub("%s+$", "")) or nil
end

function M.attr(node, name)
    if not node then return nil end
    return take_string(lib.xmlGetNoNsProp(node, name))
end

function M.is(node, ns, name)
    return node ~= nil and node.type == XML_ELEMENT_NODE and node.ns ~= nil
        and ffi.string(node.ns.href) == M.NS[ns] and ffi.string(node.name) == name
end

-- Canonical form of the subtree rooted at `node`.
local function canonicalize(doc, node, method, prefixes)
    local c14n = C14N[method]
    if not c14n then return nil, "unsupported canonicalization " .. tostring(method) end
    local obj = lib.xmlXPathNodeEval(node,
        "descendant-or-self::node() | descendant-or-self::node()/@* | descendant-or-self::node()/namespace::*",
        doc.ctx)
    if obj == nil then return nil, "canonicalization failed" end
    local prefix_arr
    if c14n.mode == 1 and prefixes and #prefixes > 0 then
        prefix_arr = ffi.new("xmlChar*[?]", #prefixes + 1)
        local keep = {}
        for i, p in ipairs(prefixes) do
            keep[i] = ffi.new("char[?]", #p + 1, p)
            prefix_arr[i - 1] = ffi.cast("xmlChar*", keep[i])
        end
        prefix_arr[#prefixes] = nil
        doc._keep = keep
    end
    local out = ffi.new("xmlChar*[1]")
    local n = lib.xmlC14NDocDumpMemory(doc.doc, obj.nodesetval, c14n.mode, prefix_arr, c14n.comments, out)
    lib.xmlXPathFreeObject(obj)
    if n < 0 or out[0] == nil then return nil, "canonicalization failed" end
    local s = ffi.string(out[0], n)
    C.free(out[0])
    return s
end

local function prefix_list(doc, method_node)
    local inc = method_node and doc:one("ec:InclusiveNamespaces", method_node)
    local list = {}
    local raw = inc and M.attr(inc, "PrefixList")
    if raw then for p in raw:gmatch("%S+") do list[#list + 1] = p end end
    return list
end

local function b64(s)
    return s and ngx.decode_base64((s:gsub("%s+", ""))) or nil
end

--- Normalise a certificate (PEM, or bare base64 as found in metadata) to PEM.
function M.pem(cert)
    if type(cert) ~= "string" then return nil end
    local body = cert:gsub("%-%-%-%-%-BEGIN CERTIFICATE%-%-%-%-%-", "")
        :gsub("%-%-%-%-%-END CERTIFICATE%-%-%-%-%-", ""):gsub("%s+", "")
    if body == "" or not body:match("^[A-Za-z0-9+/=]+$") then return nil end
    local lines = {}
    for i = 1, #body, 64 do lines[#lines + 1] = body:sub(i, i + 63) end
    return "-----BEGIN CERTIFICATE-----\n" .. table.concat(lines, "\n") .. "\n-----END CERTIFICATE-----\n"
end

--- Verify the enveloped ds:Signature that is a direct child of `node`.
-- @return true | nil, reason ; "absent" as the reason when there is no signature
function Doc:verify(node, cert_pem)
    local sigs = self:find("ds:Signature", node)
    if #sigs == 0 then return nil, "absent" end
    if #sigs > 1 then return nil, "more than one signature on the element" end
    local sig = sigs[1]

    local id = M.attr(node, "ID")
    if not id or id == "" then return nil, "signed element has no ID" end
    if not id:match("^[%w_%.%-]+$") then return nil, "signed element has an invalid ID" end
    if #self:find("//*[@ID='" .. id .. "']") ~= 1 then return nil, "duplicate ID" end

    local signed_info, n_si = self:one("ds:SignedInfo", sig)
    if not signed_info or n_si ~= 1 then return nil, "missing SignedInfo" end
    local refs = self:find("ds:Reference", signed_info)
    if #refs ~= 1 then return nil, "expected exactly one Reference" end
    local ref = refs[1]
    if M.attr(ref, "URI") ~= "#" .. id then return nil, "signature does not reference its parent element" end

    local si_c14n_node = self:one("ds:CanonicalizationMethod", signed_info)
    local si_method = M.attr(si_c14n_node, "Algorithm")
    local sig_alg = SIGNATURES[M.attr(self:one("ds:SignatureMethod", signed_info), "Algorithm") or ""]
    if not sig_alg then return nil, "unsupported signature algorithm (use RSA-SHA256 or stronger)" end
    local digest_alg = DIGESTS[M.attr(self:one("ds:DigestMethod", ref), "Algorithm") or ""]
    if not digest_alg then return nil, "unsupported digest algorithm (use SHA-256 or stronger)" end

    -- Transforms: enveloped-signature, then at most one canonicalization.
    local ref_method, ref_prefixes = "http://www.w3.org/TR/2001/REC-xml-c14n-20010315", {}
    for _, t in ipairs(self:find("ds:Transforms/ds:Transform", ref)) do
        local alg = M.attr(t, "Algorithm")
        if C14N[alg] then
            ref_method, ref_prefixes = alg, prefix_list(self, t)
        elseif alg ~= ENVELOPED then
            return nil, "unsupported transform " .. tostring(alg)
        end
    end

    local expected_digest = b64(self:text("ds:DigestValue", ref))
    local signature_value = b64(self:text("ds:SignatureValue", sig))
    if not expected_digest or not signature_value then return nil, "missing digest or signature value" end

    local x509 = require("resty.openssl.x509")
    local cert, cerr = x509.new(cert_pem or "")
    if not cert then return nil, "IdP certificate is invalid: " .. tostring(cerr) end
    local pkey = cert:get_pubkey()

    -- 1. SignedInfo, canonicalised in place, must carry a valid signature.
    local si, si_err = canonicalize(self, signed_info, si_method, prefix_list(self, si_c14n_node))
    if not si then return nil, si_err end
    local ok = pkey:verify(signature_value, si, sig_alg)
    if not ok then return nil, "signature value does not match the IdP certificate" end

    -- 2. The element, without this signature (enveloped transform), must
    --    hash to the signed digest.
    local parent, next_sibling = sig.parent, sig.next
    lib.xmlUnlinkNode(sig)
    local body, body_err = canonicalize(self, node, ref_method, ref_prefixes)
    if next_sibling ~= nil then lib.xmlAddPrevSibling(next_sibling, sig) else lib.xmlAddChild(parent, sig) end
    if not body then return nil, body_err end
    local digest = require("resty.openssl.digest").new(digest_alg):final(body)
    if digest ~= expected_digest then return nil, "digest mismatch: the signed content was changed" end
    return true
end

return M
