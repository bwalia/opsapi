/*!
 * OpsAPI page bridge v1 — for plugin pages shown in the dashboard.
 * Guide: PLUGINS.md §6.2 in the opsapi repo.
 *
 *   <link rel="stylesheet" href="/plugin-ui/_sdk/opsapi-ui.css">
 *   <script src="/plugin-ui/_sdk/opsapi-ui.js"></script>
 *   <script>
 *     OpsAPI.connect().then(async (ops) => {
 *       const { data } = await ops.api.get('/tickets', { status: 'open' });
 *       ...
 *     });
 *   </script>
 *
 * The page runs in a sandboxed frame with no credentials of its own. Every
 * API call goes through the dashboard, as the signed-in user, in the current
 * workspace, and only to the plugin's own API (relative paths such as
 * '/tickets') or the prefixes its manifest lists for the page.
 */
(function (global) {
  'use strict';

  var VERSION = 1;
  var token = (global.location.hash.match(/opsapi=([A-Za-z0-9_-]+)/) || [])[1] || '';
  var seq = 0;
  var pending = {};
  var listeners = {};
  var connecting = null;

  function OpsAPIError(message, status, body) {
    var err = new Error(message);
    err.name = 'OpsAPIError';
    err.status = status;
    err.body = body;
    return err;
  }

  function send(type, payload) {
    var msg = { __opsapi: VERSION, token: token, type: type };
    for (var k in payload) if (Object.prototype.hasOwnProperty.call(payload, k)) msg[k] = payload[k];
    global.parent.postMessage(msg, '*');
  }

  function call(type, payload, timeoutMs) {
    return new Promise(function (resolve, reject) {
      var id = ++seq;
      var timer = setTimeout(function () {
        delete pending[id];
        reject(OpsAPIError('The dashboard did not answer (' + type + ')', 0));
      }, timeoutMs || 60000);
      pending[id] = function (m) {
        clearTimeout(timer);
        if (m.ok) resolve(m.result);
        else reject(OpsAPIError(m.error || 'Request failed', m.status || 0, m.body));
      };
      payload = payload || {};
      payload.id = id;
      send(type, payload);
    });
  }

  function emit(name, data) {
    (listeners[name] || []).slice().forEach(function (fn) {
      try { fn(data); } catch (e) { setTimeout(function () { throw e; }); }
    });
  }

  global.addEventListener('message', function (e) {
    if (e.source !== global.parent) return;
    var m = e.data;
    if (!m || m.__opsapi !== VERSION) return;
    if (m.type === 'reply' && pending[m.id]) {
      var done = pending[m.id];
      delete pending[m.id];
      done(m);
    } else if (m.type === 'event') {
      if (m.name === 'theme') applyTheme(m.data);
      emit(m.name, m.data);
    }
  });

  // The dashboard's colours (tenant branding, light/dark) as CSS variables,
  // so opsapi-ui.css — and your own CSS using var(--ops-…) — match it.
  function applyTheme(theme) {
    if (!theme) return;
    var root = global.document.documentElement;
    root.classList.toggle('dark', theme.mode === 'dark');
    root.style.colorScheme = theme.mode === 'dark' ? 'dark' : 'light';
    var tokens = theme.tokens || {};
    for (var name in tokens) {
      if (/^--ops-[a-z0-9-]+$/.test(name) && typeof tokens[name] === 'string') root.style.setProperty(name, tokens[name]);
    }
  }

  // Keep the frame as tall as the page, so the dashboard scrolls, not the frame.
  function watchHeight() {
    var last = 0;
    var queued = false;
    function report() {
      queued = false;
      // The content's height: scrollHeight is never less than the frame's own
      // height, so it could only ever grow. (Don't give html/body height: 100%.)
      var h = Math.ceil(global.document.documentElement.getBoundingClientRect().height);
      if (h !== last) {
        last = h;
        send('resize', { height: h });
      }
    }
    function schedule() {
      if (!queued) {
        queued = true;
        global.requestAnimationFrame(report);
      }
    }
    if (global.ResizeObserver) new global.ResizeObserver(schedule).observe(global.document.documentElement);
    global.addEventListener('load', schedule);
    schedule();
    return schedule;
  }

  function query(params) {
    if (!params) return '';
    var parts = [];
    Object.keys(params).forEach(function (k) {
      var v = params[k];
      if (v === undefined || v === null || v === '') return;
      parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(v)));
    });
    return parts.length ? '?' + parts.join('&') : '';
  }

  function makeClient(ctx, resize) {
    var permissions = ctx.permissions || {};

    function request(method, path, options) {
      options = options || {};
      return call('request', {
        method: method,
        path: String(path) + query(options.query),
        body: options.body,
      });
    }

    var ops = {
      version: VERSION,
      /** { plugin, page, user, namespace, params, theme, can, permissions, isAdmin } */
      context: ctx,
      api: {
        /** Resolves with the JSON body ({ success, data, meta }); rejects with an OpsAPIError. */
        request: request,
        get: function (path, params) { return request('GET', path, { query: params }); },
        post: function (path, body) { return request('POST', path, { body: body }); },
        put: function (path, body) { return request('PUT', path, { body: body }); },
        patch: function (path, body) { return request('PATCH', path, { body: body }); },
        delete: function (path) { return request('DELETE', path); },
      },
      /** can('create') for the page's module, or can('customers', 'read'). */
      can: function (module, action) {
        if (action === undefined) {
          action = module;
          module = ctx.page.module;
        }
        if (ctx.isAdmin) return true;
        // The page's own module: what the server decided for this user.
        if (module === ctx.page.module && ctx.can && typeof ctx.can[action] === 'boolean') return ctx.can[action];
        var actions = permissions[module] || [];
        return actions.indexOf('manage') !== -1 || actions.indexOf(action) !== -1;
      },
      /** Open another dashboard page, e.g. '/dashboard/plugins/helpdesk/tickets'. */
      navigate: function (path) { send('navigate', { path: path }); },
      /** toast('Saved'), toast('Could not save', 'error'); types: success | error | info */
      toast: function (message, type) { send('toast', { message: String(message), toastType: type || 'success' }); },
      /** Resolves true/false. { title, message, confirmLabel, danger } */
      confirm: function (options) { return call('confirm', { options: options || {} }, 24 * 3600 * 1000); },
      /** Put page state in the dashboard URL (deep links, back button): setParams({ ticket: id }). */
      setParams: function (params) {
        ctx.params = params || {};
        send('setParams', { params: ctx.params });
      },
      /** on('params', fn) after back/forward; on('theme', fn) after a light/dark switch. */
      on: function (name, fn) {
        (listeners[name] = listeners[name] || []).push(fn);
        return function () {
          listeners[name] = (listeners[name] || []).filter(function (f) { return f !== fn; });
        };
      },
      /** Re-measure the page height (it's automatic; call after unusual layout changes). */
      resize: resize,
    };
    ops.on('params', function (params) { ctx.params = params || {}; });
    ops.on('theme', function (theme) { ctx.theme = theme; });
    return ops;
  }

  /** Connect to the dashboard. Resolves with the `ops` client. */
  function connect() {
    if (connecting) return connecting;
    connecting = new Promise(function (resolve, reject) {
      if (global.parent === global || !token) {
        reject(OpsAPIError('Open this page from the OpsAPI dashboard: it runs inside the dashboard, not on its own.', 0));
        return;
      }
      var tries = 0;
      (function hello() {
        call('hello', { version: VERSION }, 1000).then(function (ctx) {
          applyTheme(ctx.theme);
          resolve(makeClient(ctx, watchHeight()));
        }, function (err) {
          if (++tries < 15) hello();
          else reject(err);
        });
      })();
    });
    return connecting;
  }

  global.OpsAPI = { version: VERSION, connect: connect, OpsAPIError: OpsAPIError };
})(window);
