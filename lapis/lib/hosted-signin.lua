--[[
    Hosted sign-in: "Login with OpsAPI" for other apps (lib/hosted-signin.lua).

    OpsAPI acts as the identity provider for apps on trusted origins (the
    demo's hello-java / hello-php). An app sends the browser to

        GET /auth/signin?frontend_url=<app origin>&from=<app state>

    and gets it back at <app origin>/auth/callback?token=<JWT>&redirect=<from>,
    the same contract as /auth/google, so an app that already takes Google
    sign-ins needs no new callback.

    The page offers every way OpsAPI can sign someone in: email + password
    (with the emailed code when the workspace requires one) and Google, which
    OpsAPI federates. It holds no login logic of its own; its script calls the
    existing endpoints, so lockout, MFA and the audit trail are unchanged:

        POST /auth/refresh      already signed in to OpsAPI (the HttpOnly
                                refresh cookie) -> straight back, no prompt.
                                This is the single sign-on.
        POST /auth/login        email + password
        POST /auth/2fa/verify   the emailed code
        GET  /auth/google       Google, with the same frontend_url / from

    GET /auth/signout?frontend_url=<app origin> ends the OpsAPI session
    (POST /auth/logout) and returns to the app, so the next sign-in prompts.

    What the server side owns, and why it is here rather than in the script:
      * frontend_url must be a trusted origin, checked before the page renders.
        The token is handed to it, so an untrusted one is refused outright,
        never replaced by a default.
      * The page is served with a nonce CSP, no framing (it takes passwords)
        and no-store.
]]

local cjson = require("cjson.safe")

local HostedSignin = {}

-- `from` is the app's own state (a nonce for the demo apps). It travels in a
-- URL and back, so keep it to URL-safe characters and a sane length.
local FROM_PATTERN = "^[%w%-%._~/]+$"
local FROM_MAX = 256

--- Validate the request.
-- @param params table  request params (frontend_url, from)
-- @param trusted function(url) -> origin|nil  (middleware.cors.trustedFrontend)
-- @return { frontend = origin, from = string, app_host = string } | nil, error message
function HostedSignin.resolve(params, trusted)
    local frontend = trusted(params.frontend_url)
    if not frontend then
        return nil, "This app is not allowed to sign in with OpsAPI."
    end
    local from = params.from
    if from == nil or from == "" then
        from = "/"
    end
    if type(from) ~= "string" or #from > FROM_MAX or not from:match(FROM_PATTERN) then
        return nil, "The sign-in request is malformed."
    end
    return { frontend = frontend, from = from, app_host = frontend:match("^https?://(.+)$") }
end

local function escape(s)
    return (tostring(s):gsub("[&<>\"']", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;",
    }))
end
HostedSignin.escape = escape

local function query(t)
    local parts = {}
    for _, k in ipairs({ "frontend_url", "from" }) do
        if t[k] then
            parts[#parts + 1] = k .. "=" .. (tostring(t[k]):gsub("[^%w%-%._~]", function(c)
                return string.format("%%%02X", c:byte())
            end))
        end
    end
    return table.concat(parts, "&")
end

--- Response headers for the page.
function HostedSignin.headers(nonce)
    return {
        ["Content-Security-Policy"] = "default-src 'none'; script-src 'nonce-" .. nonce .. "'; style-src 'nonce-"
            .. nonce .. "'; connect-src 'self'; img-src 'self' data:; form-action 'none'; base-uri 'none'; "
            .. "frame-ancestors 'none'",
        ["X-Frame-Options"] = "DENY",
        ["Referrer-Policy"] = "no-referrer",
        ["Cache-Control"] = "no-store",
    }
end

local STYLE = [[
:root{color-scheme:light dark;--fg:#16181d;--muted:#5d6472;--bg:#f4f5f7;--card:#fff;--line:#dfe2e8;
--accent:#3b5bdb;--accent-fg:#fff;--err:#c92a2a}
@media (prefers-color-scheme:dark){:root{--fg:#e8eaee;--muted:#9aa1ad;--bg:#111317;--card:#1a1d23;
--line:#2c3038;--accent:#5c7cfa;--err:#ff8787}}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px 16px;
background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
main{width:100%;max-width:380px;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:28px}
h1{font-size:20px;margin:0 0 4px}
.for{margin:0 0 20px;color:var(--muted);font-size:14px}
.for strong{color:var(--fg);font-weight:600}
label{display:block;font-size:13px;font-weight:600;margin:12px 0 4px}
input{width:100%;padding:10px 12px;font:inherit;color:inherit;background:transparent;border:1px solid var(--line);
border-radius:8px}
input:focus{outline:2px solid var(--accent);outline-offset:1px;border-color:transparent}
button,.button{display:block;width:100%;margin-top:16px;padding:10px 12px;font:inherit;font-weight:600;
text-align:center;text-decoration:none;border-radius:8px;cursor:pointer}
button{background:var(--accent);color:var(--accent-fg);border:0}
.button{background:transparent;color:var(--fg);border:1px solid var(--line)}
.or{display:flex;align-items:center;gap:12px;margin:20px 0 4px;color:var(--muted);font-size:13px}
.or::before,.or::after{content:"";flex:1;border-top:1px solid var(--line)}
.error{margin:12px 0 0;color:var(--err);font-size:14px}
.note{margin:20px 0 0;color:var(--muted);font-size:13px}
.spinner{width:28px;height:28px;margin:8px auto 16px;border:3px solid var(--line);border-top-color:var(--accent);
border-radius:50%;animation:spin 0.8s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
@media (prefers-reduced-motion:reduce){.spinner{animation:none}}
[hidden]{display:none!important}
]]

local SCRIPT = [[
(function () {
  var cfg = JSON.parse(document.getElementById('cfg').textContent);
  function $(id) { return document.getElementById(id); }
  function show(id) {
    ['checking', 'signin', 'code'].forEach(function (s) { if ($(s)) $(s).hidden = s !== id; });
  }
  function fail(msg) { var e = $('error'); e.textContent = msg || ''; e.hidden = !msg; }
  // OpsAPI errors: {"error": {"code", "message", ...}} or legacy {"error": "text"}.
  function message(body, status) {
    var err = body && body.error;
    if (err && typeof err === 'object') return err.message || err.code;
    if (typeof err === 'string') return err;
    return (body && body.message) || ('Sign-in failed (' + status + ').');
  }
  function post(path, body) {
    return fetch(path, {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
      body: JSON.stringify(body)
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (b) {
        return { ok: r.ok, status: r.status, body: b };
      });
    });
  }
  function back(token) {
    location.replace(cfg.frontend + '/auth/callback?token=' + encodeURIComponent(token) +
      '&redirect=' + encodeURIComponent(cfg.from));
  }
  var offline = function () { fail('Could not reach OpsAPI. Try again.'); };

  if (cfg.mode === 'signout') {
    post('/auth/logout', {}).then(null, function () {}).then(function () {
      location.replace(cfg.frontend + '/');
    });
    return;
  }

  // Single sign-on: an OpsAPI session (refresh cookie) means no prompt at all.
  post('/auth/refresh', {}).then(function (r) {
    if (r.ok && r.body.token) {
      $('checking-text').textContent = 'You are already signed in to OpsAPI. Returning you to ' + cfg.appHost + '…';
      back(r.body.token);
    } else {
      show('signin');
      $('email').focus();
    }
  }, function () { show('signin'); });

  var session = null;
  $('signin-form').addEventListener('submit', function (ev) {
    ev.preventDefault();
    fail('');
    $('signin-submit').disabled = true;
    post('/auth/login', { username: $('email').value.trim(), password: $('password').value }).then(function (r) {
      $('signin-submit').disabled = false;
      if (r.ok && r.body.token) return back(r.body.token);
      if (r.ok && r.body.requires_2fa) {
        session = r.body.session_token;
        $('code-email').textContent = r.body.email || 'your email';
        show('code');
        $('code-input').focus();
        return;
      }
      fail(message(r.body, r.status));
    }, function () { $('signin-submit').disabled = false; offline(); });
  });
  $('code-form').addEventListener('submit', function (ev) {
    ev.preventDefault();
    fail('');
    post('/auth/2fa/verify', { session_token: session, code: $('code-input').value.trim() }).then(function (r) {
      if (r.ok && r.body.token) return back(r.body.token);
      fail(message(r.body, r.status));
    }, offline);
  });
})();
]]

--- Render the page.
-- @param opts { mode = "signin"|"signout"|"error", ctx = resolve() result, nonce = string,
--               google = bool (Google sign-in configured), error = string }
-- @return string HTML
function HostedSignin.render(opts)
    local nonce = escape(opts.nonce)
    local ctx = opts.ctx or {}
    local head = '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        .. '<meta name="viewport" content="width=device-width, initial-scale=1">'
        .. '<meta name="robots" content="noindex">'
        .. '<title>Sign in with OpsAPI</title><style nonce="' .. nonce .. '">' .. STYLE .. '</style></head><body><main>'
    local tail = '</main></body></html>'

    if opts.mode == "error" then
        return head .. '<h1>Can\'t sign in</h1><p class="error">' .. escape(opts.error) .. '</p>'
            .. '<p class="note">Go back to the app and start again.</p>' .. tail
    end

    -- JSON in a data block: "<" escaped so a value can never close the script tag.
    local cfg = (cjson.encode({
        mode = opts.mode, frontend = ctx.frontend, from = ctx.from, appHost = ctx.app_host,
    }) or "{}"):gsub("<", "\\u003c")
    local scripts = '<script type="application/json" id="cfg">' .. cfg .. '</script>'
        .. '<script nonce="' .. nonce .. '">' .. SCRIPT .. '</script>'

    if opts.mode == "signout" then
        return head .. '<div class="spinner" aria-hidden="true"></div><h1>Signing you out of OpsAPI</h1>'
            .. '<p class="for">Then back to <strong>' .. escape(ctx.app_host) .. '</strong>.</p>' .. scripts .. tail
    end

    local google = ""
    if opts.google then
        google = '<div class="or">or</div><a class="button" href="/auth/google?'
            .. escape(query({ frontend_url = ctx.frontend, from = ctx.from })) .. '">Continue with Google</a>'
    end

    return head
        .. '<div id="checking"><div class="spinner" aria-hidden="true"></div>'
        .. '<p class="for" id="checking-text" role="status">Checking for an OpsAPI session&hellip;</p></div>'
        .. '<div id="signin" hidden><h1>Sign in with OpsAPI</h1>'
        .. '<p class="for">to continue to <strong>' .. escape(ctx.app_host) .. '</strong></p>'
        .. '<form id="signin-form"><label for="email">Email or username</label>'
        .. '<input id="email" name="username" autocomplete="username" required>'
        .. '<label for="password">Password</label>'
        .. '<input id="password" name="password" type="password" autocomplete="current-password" required>'
        .. '<button id="signin-submit" type="submit">Sign in</button></form>'
        .. google
        .. '<p class="note">One OpsAPI account signs you in to every app that uses OpsAPI.</p></div>'
        .. '<div id="code" hidden><h1>Check your email</h1>'
        .. '<p class="for">We sent a sign-in code to <strong id="code-email"></strong>.</p>'
        .. '<form id="code-form"><label for="code-input">Code</label>'
        .. '<input id="code-input" inputmode="numeric" autocomplete="one-time-code" required>'
        .. '<button type="submit">Verify</button></form></div>'
        .. '<p class="error" id="error" role="alert" hidden></p>'
        .. scripts .. tail
end

return HostedSignin
