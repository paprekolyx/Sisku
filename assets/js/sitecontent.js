/* ==========================================================================
   SISKU · sitecontent.js — подраздел «Сайт» вкладки «Управление» (v0.9.0-draft)
   Правка текстов витрины из таблицы site_content: ключи не меняются,
   значение обновляется на сервере; витрина подхватит его при следующем
   открытии страницы (Ctrl + F5). Поиск по ключу/значению/подсказке.
   ========================================================================== */
(function () {
  'use strict';

  var state = { rows: [], editingKey: null, saving: false };

  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }
  function clip(s, n) {
    s = String(s == null ? '' : s);
    return s.length > n ? s.slice(0, n) + '…' : s;
  }

  function load() {
    $('sc-loading').hidden = false;
    $('sc-error').hidden = true;
    if (!db) {
      $('sc-loading').hidden = true;
      $('sc-error').hidden = false;
      $('sc-error').textContent = 'База не подключена: ' + (dbError || 'заполните assets/js/config.js');
      return;
    }
    db.from('site_content').select('*').order('key').then(function (res) {
      $('sc-loading').hidden = true;
      if (res.error) {
        $('sc-error').hidden = false;
        $('sc-error').textContent = res.error.message;
        return;
      }
      state.rows = res.data || [];
      render();
    });
  }

  function render() {
    var q = $('sc-search').value.trim().toLowerCase();
    var list = state.rows.filter(function (r) {
      if (!q) return true;
      return (r.key + ' ' + (r.value || '') + ' ' + (r.description || '')).toLowerCase().indexOf(q) !== -1;
    });
    $('sc-body').innerHTML = list.map(function (r) {
      return '<tr>' +
        '<td style="white-space:nowrap;font-size:13px" class="muted">' + esc(r.key) + '</td>' +
        '<td class="user-fio sc-val" data-edit="' + esc(r.key) + '" title="Редактировать значение">' + esc(clip(r.value, 90) || '—') + '</td>' +
        '<td class="muted" style="font-size:12.5px">' + esc(r.description || '') + '</td>' +
        '<td class="tabular muted" style="font-size:12.5px;white-space:nowrap">' +
          (r.updated_at ? new Date(r.updated_at).toLocaleString('ru-RU', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) : '—') + '</td>' +
      '</tr>';
    }).join('');
  }

  function openModal(key) {
    var r = state.rows.filter(function (x) { return x.key === key; })[0];
    if (!r) return;
    state.editingKey = key;
    state.saving = false;
    $('sc-submit').disabled = false;
    $('sc-title').textContent = r.key;
    $('sc-desc').textContent = r.description || '';
    $('sc-value').value = r.value || '';
    $('sc-err').hidden = true;
    $('sc-modal-backdrop').classList.add('open');
  }
  function closeModal() { $('sc-modal-backdrop').classList.remove('open'); }

  function save(e) {
    e.preventDefault();
    if (state.saving) return;
    state.saving = true;
    $('sc-submit').disabled = true;
    var errBox = $('sc-err');
    errBox.hidden = true;
    db.from('site_content')
      .update({ value: $('sc-value').value, updated_at: new Date().toISOString() })
      .eq('key', state.editingKey)
      .then(function (res) {
        state.saving = false;
        $('sc-submit').disabled = false;
        if (res.error) { errBox.textContent = res.error.message; errBox.hidden = false; return; }
        closeModal();
        load();
      }).catch(function (err) {
        state.saving = false;
        $('sc-submit').disabled = false;
        errBox.textContent = 'Ошибка сети: ' + err.message;
        errBox.hidden = false;
      });
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;
    if (window.initAdminTheme) window.initAdminTheme();
    $('btn-logout').addEventListener('click', function () { if (window.mockLogout) window.mockLogout(); });
    $('btn-refresh').addEventListener('click', load);
    $('sc-search').addEventListener('input', render);
    $('sc-body').addEventListener('click', function (e) {
      var ed = e.target.closest('[data-edit]');
      if (ed) openModal(ed.getAttribute('data-edit'));
    });
    $('sc-modal-close').addEventListener('click', closeModal);
    $('sc-modal-backdrop').addEventListener('click', function (e) { if (e.target === $('sc-modal-backdrop')) closeModal(); });
    $('sc-form').addEventListener('submit', save);
    load();
  });
})();
