/* Send page: pick files, upload them with tus (resumable), create a share. */
(function () {
  'use strict';
  var PB = window.PB;
  var section = document.getElementById('send');
  if (!section) return;

  var cfg = {
    maxFile: Number(section.getAttribute('data-max-file')),
    maxFiles: Number(section.getAttribute('data-max-files')),
    expiryDefault: Number(section.getAttribute('data-expiry-default')),
    expiryChoices: (section.getAttribute('data-expiry-choices') || '').split(',').map(Number).filter(Boolean)
  };
  var CHUNK = 8 * 1024 * 1024;

  var $ = function (id) { return document.getElementById(id); };
  var composer = $('composer'), queueEl = $('queue'), startBtn = $('start');
  var sendErr = $('send-error'), result = $('result'), picker = $('files');
  var queue = [];          // { file, li, bar, state, hash }
  var busy = false;
  var wakeLock = null;

  // ------------------------------------------------------------- setup --
  var expirySel = $('expiry');
  var choices = cfg.expiryChoices.slice();
  if (choices.indexOf(cfg.expiryDefault) < 0) choices.push(cfg.expiryDefault);
  choices.sort(function (a, b) { return a - b; });
  choices.forEach(function (s) {
    var o = PB.el('option', { value: String(s), text: PB.expiryLabel(s) });
    if (s === cfg.expiryDefault) o.selected = true;
    expirySel.appendChild(o);
  });

  PB.gate(function (me) {
    composer.hidden = false;
    if (me && me.quota_bytes) {
      $('usage').textContent = '本月已用 ' + PB.size(me.used_bytes) + ' / ' + PB.size(me.quota_bytes) + ' ·';
    }
  });

  window.addEventListener('beforeunload', function (ev) {
    if (busy) { ev.preventDefault(); ev.returnValue = ''; }
  });

  // ------------------------------------------------------------- queue --
  function showError(msg) { sendErr.textContent = msg; sendErr.hidden = !msg; }

  function refresh() {
    startBtn.disabled = busy || queue.length === 0;
    startBtn.textContent = queue.length ? '开始发送（' + queue.length + ' 个文件，' +
      PB.size(queue.reduce(function (n, q) { return n + q.file.size; }, 0)) + '）' : '开始发送';
  }

  function addFiles(list) {
    showError('');
    for (var i = 0; i < list.length; i++) {
      var f = list[i];
      if (queue.length >= cfg.maxFiles) { showError('一次最多发送 ' + cfg.maxFiles + ' 个文件。'); break; }
      if (f.size > cfg.maxFile) { showError('「' + f.name + '」超过单个文件上限 ' + PB.size(cfg.maxFile) + '。'); continue; }
      addItem(f);
    }
    refresh();
  }

  function addItem(file) {
    var item = { file: file, state: 'waiting', hash: null };
    // A div bar whose width comes from classes p0..p20 (5% steps), so no
    // inline styles are needed under the strict CSP (WebKit reports even
    // the internal styles of <progress>).
    var fill = PB.el('i');
    var bar = PB.el('div', { class: 'bar', role: 'progressbar', 'aria-valuemin': '0', 'aria-valuemax': '100' }, [fill]);
    var stateEl = PB.el('span', { class: 'qstate', text: PB.size(file.size) });
    var rm = PB.el('button', { class: 'qremove', type: 'button', 'aria-label': '移除', text: '✕',
      onclick: function () {
        if (busy) return;
        queue.splice(queue.indexOf(item), 1);
        queueEl.removeChild(item.li);
        refresh();
      } });
    item.li = PB.el('li', null, [PB.el('span', { class: 'qname', text: file.name }),
      PB.el('span', null, [stateEl, rm]), bar]);
    item.bar = bar; item.fill = fill; item.stateEl = stateEl; item.rm = rm;
    queue.push(item);
    queueEl.appendChild(item.li);
  }

  picker.addEventListener('change', function () { addFiles(picker.files); picker.value = ''; });

  // --------------------------------------------------------------- tus --
  function b64(s) { return btoa(unescape(encodeURIComponent(s))); }
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function fingerprint(f) { return 'pb_up_' + [f.name, f.size, f.lastModified, f.type].join('|'); }
  function store(k, v) { try { if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (e) {} }
  function load(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }

  function tusHeaders(extra) {
    var h = { 'Tus-Resumable': '1.0.0', 'Authorization': 'Bearer ' + PB.password() };
    for (var k in extra) h[k] = extra[k];
    return h;
  }

  // Transient failures (rate limiting, server restart, flaky network) are
  // retried with backoff; anything else is reported to the user.
  function retryable(status) { return status === 0 || status === 429 || status >= 500 && status !== 507; }

  function createUpload(file, attempt) {
    attempt = attempt || 0;
    return fetch('/files/', { method: 'POST', headers: tusHeaders({
      'Upload-Length': String(file.size),
      'Upload-Metadata': 'filename ' + b64(file.name) + ',filetype ' + b64(file.type || '')
    }) }).then(function (r) {
      if (r.status === 201) {
        return { url: r.headers.get('Location'), hash: r.headers.get('X-Blob-Hash') };
      }
      return r.text().then(function (t) { throw httpError(r.status, t); });
    }, function () { throw httpError(0, '网络错误'); }).catch(function (err) {
      if (retryable(err.status) && attempt < 8) {
        return sleep(Math.min(30000, 1000 * Math.pow(2, attempt))).then(function () {
          return createUpload(file, attempt + 1);
        });
      }
      throw err;
    });
  }

  function headUpload(url) {
    return fetch(url, { method: 'HEAD', headers: tusHeaders({}) }).then(function (r) {
      if (!r.ok) return null;
      return { offset: Number(r.headers.get('Upload-Offset')), hash: r.headers.get('X-Blob-Hash') };
    });
  }

  function patchChunk(url, offset, blob, onProgress) {
    return new Promise(function (resolve) {
      var xhr = new XMLHttpRequest();
      xhr.open('PATCH', url, true);
      var h = tusHeaders({ 'Upload-Offset': String(offset), 'Content-Type': 'application/offset+octet-stream' });
      for (var k in h) xhr.setRequestHeader(k, h[k]);
      xhr.upload.onprogress = function (e) { if (e.lengthComputable) onProgress(e.loaded); };
      xhr.onload = function () {
        resolve({ status: xhr.status, offset: Number(xhr.getResponseHeader('Upload-Offset')),
                  hash: xhr.getResponseHeader('X-Blob-Hash'), text: xhr.responseText });
      };
      xhr.onerror = xhr.ontimeout = xhr.onabort = function () { resolve({ status: 0 }); };
      xhr.send(blob);
    });
  }

  function httpError(status, text) {
    var e = new Error(text || ('HTTP ' + status));
    e.status = status;
    return e;
  }

  function uploadOne(item) {
    var file = item.file, key = fingerprint(file);
    var url = load(key), offset = 0;
    function progress(n) {
      var pct = file.size ? Math.min(100, Math.floor(n / file.size * 100)) : 100;
      item.fill.className = 'p' + Math.round(pct / 5);
      item.bar.setAttribute('aria-valuenow', String(pct));
      item.stateEl.textContent = pct + '%';
    }
    function begin() {
      if (url) {
        return headUpload(url).then(function (h) {
          if (h && h.hash) return h.hash;
          if (h) { offset = h.offset; return null; }
          url = null; return begin();
        }, function () { return null; });
      }
      return createUpload(file).then(function (c) {
        url = c.url; store(key, url);
        return c.hash || null;
      });
    }
    function loop(attempt) {
      if (offset >= file.size && file.size > 0) return headUpload(url).then(function (h) { return h && h.hash; });
      var end = Math.min(offset + CHUNK, file.size);
      return patchChunk(url, offset, file.slice(offset, end), function (n) { progress(offset + n); })
        .then(function (r) {
          if (r.status === 204) {
            offset = r.offset; progress(offset);
            if (r.hash) return r.hash;
            return loop(0);
          }
          if (r.status === 413 || r.status === 507 || r.status === 401 || r.status === 410 || r.status === 404) {
            // The upload session is gone (expired/failed): start over next time.
            if (r.status === 410 || r.status === 404) store(key, null);
            throw httpError(r.status, r.text);
          }
          // Network error, conflict or server hiccup: wait, resync, retry.
          if (attempt >= 12) throw httpError(r.status, '网络不稳定，上传失败');
          item.stateEl.textContent = '网络中断，正在重试…';
          return sleep(Math.min(30000, 1000 * Math.pow(2, attempt))).then(function () {
            return headUpload(url).then(function (h) {
              if (h && h.hash) return h.hash;
              if (h) offset = h.offset;
              return loop(attempt + 1);
            }, function () { return loop(attempt + 1); });
          });
        });
    }
    return begin().then(function (doneHash) {
      if (doneHash) return doneHash;
      return loop(0);
    }).then(function (hash) {
      store(key, null);
      if (!hash) throw httpError(500, '上传未完成');
      item.hash = hash; item.state = 'done';
      item.fill.className = 'p20'; item.stateEl.textContent = '✓';
      return hash;
    });
  }

  // ------------------------------------------------------------- send --
  function friendly(err) {
    var s = err && err.status;
    if (s === 401) return '登录已失效，请重新登录。';
    if (s === 413) return '超过上传额度或文件大小上限。';
    if (s === 507) return '服务器存储空间不足。';
    if (s === 429) return '操作太频繁，请稍后再试。';
    return (err && err.message) || '上传失败，请重试。';
  }

  function lockScreen() {
    if (navigator.wakeLock && navigator.wakeLock.request) {
      navigator.wakeLock.request('screen').then(function (l) { wakeLock = l; }, function () {});
    }
  }
  function unlockScreen() { if (wakeLock) { wakeLock.release(); wakeLock = null; } }

  startBtn.addEventListener('click', function () {
    if (busy || !queue.length) return;
    busy = true; showError(''); refresh(); lockScreen();
    picker.disabled = true;
    queue.forEach(function (q) { q.rm.hidden = true; });
    var i = 0;
    function next() {
      if (i >= queue.length) return Promise.resolve();
      var item = queue[i++];
      if (item.hash) return next();
      return uploadOne(item).then(next);
    }
    next().then(function () {
      startBtn.textContent = '正在生成分享…';
      var payload = {
        files: queue.map(function (q) { return { hash: q.hash, name: q.file.name }; }),
        expires_in: Number(expirySel.value),
        max_visits: Number($('visits').value),
        title: $('title').value
      };
      function post(attempt) {
        return PB.api('POST', '/api/shares', payload).then(function (r) {
          if (retryable(r.status) && attempt < 5) {
            return sleep(1000 * Math.pow(2, attempt)).then(function () { return post(attempt + 1); });
          }
          return r;
        }, function () {
          if (attempt < 5) return sleep(1000 * Math.pow(2, attempt)).then(function () { return post(attempt + 1); });
          throw httpError(0, '网络错误，请重试');
        });
      }
      return post(0);
    }).then(function (r) {
      if (!r.ok) throw httpError(r.status, (r.data && r.data.message) || '创建分享失败');
      busy = false; unlockScreen();
      showResult(r.data);
    }).catch(function (err) {
      busy = false; unlockScreen(); picker.disabled = false;
      queue.forEach(function (q) { q.rm.hidden = false; });
      showError(friendly(err));
      if (err.status === 401) { PB.clearPassword(); }
      refresh();
      startBtn.textContent = '继续发送';
    });
  });

  function showResult(s) {
    composer.hidden = true;
    result.hidden = false;
    result.innerHTML = '';
    var copyLink = PB.el('button', { class: 'btn primary', type: 'button', text: '复制链接' });
    copyLink.addEventListener('click', function () { PB.copy(s.url, copyLink); });
    var copyAll = PB.el('button', { class: 'btn', type: 'button', text: '复制链接和取件码' });
    copyAll.addEventListener('click', function () {
      PB.copy('我给你发了 ' + s.file_count + ' 个文件，打开链接即可下载：' + s.url + ' （取件码 ' + s.code + '，' +
        PB.duration(s.expires_in) + '内有效）', copyAll);
    });
    var actions = [copyLink, copyAll];
    if (navigator.share) {
      var shareBtn = PB.el('button', { class: 'btn', type: 'button', text: '分享…' });
      shareBtn.addEventListener('click', function () {
        navigator.share({ title: '文件', text: '取件码 ' + s.code, url: s.url }).catch(function () {});
      });
      actions.push(shareBtn);
    }
    var again = PB.el('button', { class: 'btn', type: 'button', text: '再发一份' });
    again.addEventListener('click', function () { location.reload(); });
    actions.push(again);

    result.appendChild(PB.el('div', { class: 'result' }, [
      PB.el('p', { class: 'muted', text: '发送成功！对方输入取件码或打开链接即可下载' }),
      PB.el('div', { class: 'code', text: s.code }),
      PB.el('p', { class: 'link' }, [PB.el('a', { href: s.url, target: '_blank', rel: 'noopener', text: s.url })]),
      PB.el('img', { class: 'qr', src: '/p/' + s.slug + '/qr.svg', alt: '二维码' }),
      PB.el('p', { class: 'muted small', text: s.file_count + ' 个文件 · ' + PB.size(s.total_bytes) + ' · ' +
        PB.duration(s.expires_in) + '后过期' + (s.max_visits ? ' · 可打开 ' + s.max_visits + ' 次' : '') }),
      PB.el('div', { class: 'actions' }, actions)
    ]));
  }
})();
