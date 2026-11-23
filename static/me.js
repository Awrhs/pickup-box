/* "My shares": list, copy, preview, extend and revoke. */
(function () {
  'use strict';
  var PB = window.PB;
  var list = document.getElementById('share-list');
  var empty = document.getElementById('empty');
  var mine = document.getElementById('mine');
  var role = 'upload', showAll = false;

  var STATE = { live: '有效', expired: '已过期', revoked: '已撤回', exhausted: '次数用完' };

  function render(shares) {
    list.innerHTML = '';
    empty.hidden = shares.length > 0;
    shares.forEach(function (s) {
      var title = s.title || (s.file_count + ' 个文件');
      var meta = [PB.size(s.total_bytes), '打开 ' + s.visit_count + (s.max_visits ? ' / ' + s.max_visits : '') + ' 次'];
      if (s.state === 'live') meta.push(PB.duration(s.expires_in) + '后过期');
      if (showAll && s.owner) meta.push('来自 ' + s.owner);
      var acts = [];
      if (s.state === 'live') {
        var copy = PB.el('button', { class: 'btn', type: 'button', text: '复制链接' });
        copy.addEventListener('click', function () { PB.copy(s.url, copy); });
        var view = PB.el('button', { class: 'btn', type: 'button', text: '预览' });
        view.addEventListener('click', function () {
          PB.api('POST', '/api/shares/' + s.id + '/preview').then(function (r) {
            if (r.ok) window.open(r.data.url, '_blank', 'noopener');
          });
        });
        var extend = PB.el('button', { class: 'btn', type: 'button', text: '延长到 7 天' });
        extend.addEventListener('click', function () {
          PB.api('POST', '/api/shares/' + s.id + '/extend', { expires_in: 7 * 86400 }).then(load);
        });
        var revoke = PB.el('button', { class: 'btn', type: 'button', text: '撤回' });
        revoke.addEventListener('click', function () {
          if (window.confirm('撤回后对方将无法再下载，确定吗？')) {
            PB.api('POST', '/api/shares/' + s.id + '/revoke').then(load);
          }
        });
        acts = [copy, view, extend, revoke];
      }
      list.appendChild(PB.el('li', null, [
        PB.el('div', { class: 'row1' }, [
          PB.el('span', { class: 'stitle', text: title }),
          s.code ? PB.el('span', { class: 'scode', text: s.code }) : null,
          PB.el('span', { class: 'badge' + (s.state === 'live' ? ' live' : ''), text: STATE[s.state] || s.state })
        ]),
        PB.el('div', { class: 'smeta', text: meta.join(' · ') }),
        acts.length ? PB.el('div', { class: 'sact' }, acts) : null
      ]));
    });
  }

  function load() {
    PB.api('GET', '/api/shares' + (showAll ? '?all=1' : '')).then(function (r) {
      if (r.status === 401) { PB.clearPassword(); location.reload(); return; }
      if (r.ok) render(r.data.shares || []);
    });
  }

  PB.gate(function (me) {
    role = me.role;
    mine.hidden = false;
    if (role === 'admin') {
      var toggle = PB.el('label', { class: 'small muted' });
      var cb = PB.el('input', { type: 'checkbox' });
      cb.addEventListener('change', function () { showAll = cb.checked; load(); });
      toggle.appendChild(cb);
      toggle.appendChild(document.createTextNode(' 显示所有人的分享'));
      mine.insertBefore(toggle, list);
    }
    load();
  });
})();
