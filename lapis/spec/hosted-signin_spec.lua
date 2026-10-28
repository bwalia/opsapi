--[[
    Spec: hosted "Login with OpsAPI" page (lib/hosted-signin.lua, routes/auth-signin.lua).

    Standalone, from the repo root:
        luajit lapis/spec/hosted-signin_spec.lua
    (CI runs it in the OpenResty image: .github/workflows/lapis-checks.yml.)
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
    local h = io.open(path)
    if not h then return "" end
    local s = h:read("*a")
    h:close()
    return s
end

if not pcall(require, "cjson.safe") then
    package.loaded["cjson.safe"] = require("cjson")
end
local HostedSignin = require("lib.hosted-signin")

local TRUSTED = { ["https://hello-java.demo.opsapi.org"] = true }
local function trusted(url)
    if type(url) ~= "string" then return nil end
    url = url:gsub("/+$", "")
    return TRUSTED[url] and url or nil
end

print("resolve: only trusted apps, only URL-safe state")
local ctx = HostedSignin.resolve({ frontend_url = "https://hello-java.demo.opsapi.org/", from = "6c208d5f1b52ad26" }, trusted)
check("trusted app resolves", ctx and ctx.frontend == "https://hello-java.demo.opsapi.org"
    and ctx.from == "6c208d5f1b52ad26" and ctx.app_host == "hello-java.demo.opsapi.org")
local none, err = HostedSignin.resolve({ frontend_url = "https://evil.example", from = "x" }, trusted)
check("untrusted app is refused, not defaulted", none == nil and err:find("not allowed"))
check("missing frontend_url is refused", HostedSignin.resolve({ from = "x" }, trusted) == nil)
check("missing from defaults to /",
    HostedSignin.resolve({ frontend_url = "https://hello-java.demo.opsapi.org" }, trusted).from == "/")
check("from with markup is refused",
    HostedSignin.resolve({ frontend_url = "https://hello-java.demo.opsapi.org", from = "</script>" }, trusted) == nil)
check("over-long from is refused",
    HostedSignin.resolve({ frontend_url = "https://hello-java.demo.opsapi.org", from = ("a"):rep(257) }, trusted) == nil)

print("headers: nonce CSP, no framing, no caching")
local h = HostedSignin.headers("abc123")
check("CSP allows only the nonce'd script", h["Content-Security-Policy"]:find("script-src 'nonce-abc123'", 1, true)
    and not h["Content-Security-Policy"]:find("unsafe-inline", 1, true))
check("CSP limits fetch to OpsAPI itself", h["Content-Security-Policy"]:find("connect-src 'self'", 1, true))
check("cannot be framed", h["X-Frame-Options"] == "DENY"
    and h["Content-Security-Policy"]:find("frame-ancestors 'none'", 1, true))
check("not cached", h["Cache-Control"] == "no-store")

print("render: sign-in page")
local html = HostedSignin.render({ mode = "signin", ctx = ctx, nonce = "n0nce", google = true })
check("names the app being signed in to", html:find("hello-java.demo.opsapi.org", 1, true))
check("email + password form", html:find('id="signin-form"', 1, true) and html:find('type="password"', 1, true))
check("emailed-code step", html:find('id="code-form"', 1, true))
check("Google carries the same frontend_url and from",
    html:find('href="/auth/google?frontend_url=https%3A%2F%2Fhello-java.demo.opsapi.org&amp;from=6c208d5f1b52ad26"', 1, true))
check("script and style carry the nonce", html:find('<script nonce="n0nce">', 1, true)
    and html:find('<style nonce="n0nce">', 1, true))
check("script tries silent SSO first", html:find("'/auth/refresh'", 1, true))
check("script returns to <app>/auth/callback?token=&redirect=",
    html:find("cfg.frontend + '/auth/callback?token='", 1, true) and html:find("'&redirect='", 1, true))
check("no Google button when Google isn't configured",
    not HostedSignin.render({ mode = "signin", ctx = ctx, nonce = "n" }):find("/auth/google", 1, true))

print("render: nothing user-supplied escapes its context")
local hostile = { frontend = "https://x</script><script>alert(1)</script>", from = "/", app_host = "<b>x</b>" }
local bad = HostedSignin.render({ mode = "signin", ctx = hostile, nonce = "n", google = true })
check("config JSON cannot close the script tag", not bad:find("</script><script>alert", 1, true))
check("app host is HTML-escaped", bad:find("&lt;b&gt;x&lt;/b&gt;", 1, true) and not bad:find("<b>x</b>", 1, true))
check("error text is HTML-escaped",
    HostedSignin.render({ mode = "error", error = "<img src=x>", nonce = "n" }):find("&lt;img src=x&gt;", 1, true))

print("render: sign-out page")
local out = HostedSignin.render({ mode = "signout", ctx = ctx, nonce = "n" })
check("signs out through /auth/logout then returns", out:find('"mode":"signout"', 1, true)
    and out:find("'/auth/logout'", 1, true))

print("wiring")
local app_src = read("lapis/app.lua")
check("routes are loaded", app_src:find('safe_load_routes("routes.auth-signin")', 1, true))
check("routes are public (no JWT needed to reach a sign-in page)",
    app_src:find('["/auth/signin"] = true', 1, true) and app_src:find('["/auth/signout"] = true', 1, true))
local route_src = read("lapis/routes/auth-signin.lua")
check("routes check the app with trustedFrontend", route_src:find("Cors.trustedFrontend", 1, true))
check("an untrusted app gets a 400 page", select(2, route_src:gsub("page%(400", "")) == 2)

print(failures == 0 and "\nall checks passed" or ("\n" .. failures .. " check(s) failed"))
os.exit(failures == 0 and 0 or 1)
