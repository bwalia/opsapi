/*
 * OpsAPI forms embed: put a form on any website.
 *
 *   <div data-opsapi-form="https://your-dashboard/f/<id>"></div>
 *   <script src="https://your-dashboard/forms-embed.js" async></script>
 *
 * Each element gets an iframe of the form (?embed=1) that resizes itself to the
 * form's height. The host page's query string (utm_source=…) is passed on, so
 * campaigns are recorded with the response.
 */
(function () {
  function init(el) {
    if (el.getAttribute('data-opsapi-ready')) return;
    el.setAttribute('data-opsapi-ready', '1');
    var src = el.getAttribute('data-opsapi-form');
    if (!src || !/^https?:\/\//.test(src)) return;
    var extra = window.location.search ? '&' + window.location.search.slice(1) : '';
    var iframe = document.createElement('iframe');
    iframe.src = src + (src.indexOf('?') > -1 ? '&' : '?') + 'embed=1' + extra;
    iframe.title = el.getAttribute('data-title') || 'Form';
    iframe.setAttribute('loading', 'lazy');
    iframe.style.cssText = 'width:100%;border:0;display:block;overflow:hidden;color-scheme:normal';
    iframe.style.height = (parseInt(el.getAttribute('data-height'), 10) || 600) + 'px';
    el.appendChild(iframe);
    window.addEventListener('message', function (e) {
      if (e.source !== iframe.contentWindow || !e.data || e.data.type !== 'opsapi-form:height') return;
      var h = parseInt(e.data.height, 10);
      if (h > 0) iframe.style.height = h + 4 + 'px';
    });
  }
  function scan() {
    var els = document.querySelectorAll('[data-opsapi-form]');
    for (var i = 0; i < els.length; i++) init(els[i]);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', scan);
  else scan();
})();
