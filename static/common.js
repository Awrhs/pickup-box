/* Shared helpers: password storage, API calls, formatting. */
(function () {
  'use strict';
  var KEY = 'pb_pw';
  var PB = window.PB = {};

  PB.password = function () { try { return localStorage.getItem(KEY) || ''; } catch (e) { return ''; } };
  PB.setPassword = function (v) { try { localStorage.setItem(KEY, v); } catch (e) { /* private mode */ } };
  PB.clearPassword = function () { try { localStorage.removeItem(KEY); } catch (e) {} };

  PB.api = function (method, path, body, password) {
    var headers = { 'Authorization': 'Bearer ' + (password || PB.password()) };
    var opts = { method: method, headers: headers, credentials: 'same-origin' };
    if (body !== undefined) { headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(body); }
    return fetch(path, opts).then(function (r) {
      return r.text().then(function (t) {
        var data = null;
        try { data = t ? JSON.parse(t) : null; } catch (e) { data = null; }
        return { status: r.status, ok: r.ok, data: data };
      });
    });
  };

  PB.size = function (n) {
    n = Number(n) || 0;
    if (n < 1024) return n + ' B';
    var u = ['KB', 'MB', 'GB', 'TB'], v = n / 1024, i = 0;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return (v < 10 ? v.toFixed(1) : v.toFixed(0)) + ' ' + u[i];
  };

  PB.duration = function (sec) {
    sec = Math.max(0, Math.floor(sec));
    var d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60);
    if (d > 0) return d + ' 天' + (h ? ' ' + h + ' 小时' : '');
    if (h > 0) return h + ' 小时' + (m ? ' ' + m + ' 分钟' : '');
    if (m > 0) return m + ' 分钟';
    return '不到 1 分钟';
  };

  PB.expiryLabel = function (sec) {
    if (sec % 86400 === 0) return (sec / 86400) + ' 天';
    if (sec % 3600 === 0) return (sec / 3600) + ' 小时';
    return Math.round(sec / 60) + ' 分钟';
  };

  PB.copy = function (text, btn) {
    function done() { if (btn) { var o = btn.textContent; btn.textContent = '已复制'; setTimeout(function () { btn.textContent = o; }, 1500); } }
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(done, function () { fallback(); });
    } else { fallback(); }
    function fallback() {
      var ta = document.createElement('textarea');
      ta.value = text; ta.setAttribute('readonly', ''); ta.style.position = 'fixed'; ta.style.opacity = '0';
      document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy'); done(); } catch (e) { window.prompt('复制下面的内容：', text); }
      document.body.removeChild(ta);
    }
  };

  PB.el = function (tag, attrs, children) {
    var e = document.createElement(tag);
    if (attrs) Object.keys(attrs).forEach(function (k) {
      if (k === 'text') e.textContent = attrs[k];
      else if (k === 'class') e.className = attrs[k];
      else if (k.slice(0, 2) === 'on') e.addEventListener(k.slice(2), attrs[k]);
      else e.setAttribute(k, attrs[k]);
    });
    (children || []).forEach(function (c) { if (c) e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c); });
    return e;
  };

  /* Login gate: calls onReady(me) once a working password is stored. */
  PB.gate = function (onReady) {
    var form = document.getElementById('login');
    var input = document.getElementById('password');
    var err = document.getElementById('login-error');
    function showLogin(msg) {
      form.hidden = false;
      if (msg) { err.textContent = msg; err.hidden = false; } else { err.hidden = true; }
      input.focus();
    }
    function check(pw, fromForm) {
      return PB.api('GET', '/api/me', undefined, pw).then(function (r) {
        if (r.ok) { PB.setPassword(pw); form.hidden = true; onReady(r.data); return; }
        if (!fromForm) { PB.clearPassword(); return showLogin(); }
        if (r.status === 429) return showLogin('密码错误次数过多，请稍后再试。');
        showLogin('密码不正确。');
      }, function () { showLogin('网络错误，请重试。'); });
    }
    form.addEventListener('submit', function (ev) { ev.preventDefault(); check(input.value, true); });
    var saved = PB.password();
    if (saved) check(saved, false); else showLogin();
    var out = document.getElementById('logout');
    if (out) out.addEventListener('click', function (ev) { ev.preventDefault(); PB.clearPassword(); location.reload(); });
  };
})();
