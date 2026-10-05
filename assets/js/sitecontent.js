/* ==========================================================================
   SISKU · sitecontent.js — подраздел «Сайт» вкладки «Управление» (v0.9.0-draft)
   Правка текстов витрины из таблицы site_content: ключи не меняются,
   значение обновляется на сервере; витрина подхватит его при следующем
   открытии страницы (Ctrl + F5). Поиск по ключу/значению/подсказке.
   v0.15.0 (правка 2.16): группы по префиксу ключа — раскрываемые секции
   с человекочитаемыми именами; значение шире (clip 140, полный текст —
   в редакторе по клику); «Обновлён» — только дата, время в тултипе.
   ========================================================================== */
(function () {
  'use strict';

  var state = { rows: [], editingKey: null, saving: false, collapsed: {} };

  /* правка 2.16: справочник префиксов — заголовок группы = человекочитаемое имя */
  var GROUPS = [
    { prefix: 'brand.',    name: 'Бренд' },
    { prefix: 'hero.',     name: 'Первый экран' },
    { prefix: 'about.',    name: 'О магазине' },
    { prefix: 'adv.',      name: 'Преимущества' },
    { prefix: 'catalog.',  name: 'Каталог' },
    { prefix: 'looks.',    name: 'Комплекты' },
    { prefix: 'order.',    name: 'Заказ и условия' },
    { prefix: 'checkout.', name: 'Форма оформления' },
    { prefix: 'contacts.', name: 'Контакты' },
    { prefix: 'footer.',   name: 'Футер' },
    { prefix: 'theme.',    name: 'Брендбук: темы' }
  ];
  var OTHER = { prefix: '', name: 'Прочее' };
  function groupOf(key) {
    for (var i = 0; i < GROUPS.length; i++) {
      if (String(key).indexOf(GROUPS[i].prefix) === 0) return GROUPS[i];
    }
    return OTHER;
  }

  function $(id) { return document.getElementById(id); }
  /* общие утилиты — assets/js/util.js (v0.14.0, фикс F32: одна копия на проект) */
  var esc = SiskuUtil.esc;
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

  function rowHtml(r) {
    /* правка 2.16: значение — clip 140 (полный текст — в редакторе по клику);
       «Обновлён» — только дата, полные дата и время — в тултипе */
    var upd = r.updated_at ? new Date(r.updated_at) : null;
    return '<tr>' +
      '<td class="sc-key">' + esc(r.key) + '</td>' +
      '<td class="user-fio sc-val" data-edit="' + esc(r.key) + '" title="Редактировать значение — полный текст в редакторе">' + esc(clip(r.value, 140) || '—') + '</td>' +
      '<td class="sc-desc">' + esc(r.description || '') + '</td>' +
      '<td class="sc-upd" title="' + (upd ? esc(upd.toLocaleString('ru-RU')) : '') + '">' +
        (upd ? upd.toLocaleDateString('ru-RU') : '—') + '</td>' +
    '</tr>';
  }
  function tableHtml(rows) {
    return '<table><thead><tr><th>Ключ</th><th>Значение</th><th>Где используется</th><th>Обновлён</th></tr></thead>' +
      '<tbody>' + rows.map(rowHtml).join('') + '</tbody></table>';
  }
  function render() {
    var q = $('sc-search').value.trim().toLowerCase();
    var list = state.rows.filter(function (r) {
      if (!q) return true;
      return (r.key + ' ' + (r.value || '') + ' ' + (r.description || '')).toLowerCase().indexOf(q) !== -1;
    });
    if (q) {
      /* поиск — плоский список без групп (иначе результаты прятались бы по свёрнутым секциям) */
      $('sc-list').innerHTML = list.length
        ? '<section class="sc-group"><div class="sc-group-body">' + tableHtml(list) + '</div></section>'
        : '<div class="empty">Ничего не найдено по запросу «' + esc(q) + '»</div>';
      return;
    }
    var byGroup = {};
    list.forEach(function (r) {
      var g = groupOf(r.key).name;
      (byGroup[g] = byGroup[g] || []).push(r);
    });
    var names = GROUPS.map(function (g) { return g.name; }).concat([OTHER.name]);
    $('sc-list').innerHTML = names.filter(function (n) { return byGroup[n] && byGroup[n].length; }).map(function (n) {
      var rowsG = byGroup[n];
      return '<section class="sc-group' + (state.collapsed[n] ? ' collapsed' : '') + '">' +
        '<button type="button" class="sc-group-head" data-toggle-group="' + esc(n) + '">' +
          '<span>' + esc(n) + '</span>' +
          '<span class="sc-group-count">' + rowsG.length + ' ключ' + pluralKeys(rowsG.length) + '</span>' +
          '<span class="sc-caret">▼</span>' +
        '</button>' +
        '<div class="sc-group-body">' + tableHtml(rowsG) + '</div>' +
      '</section>';
    }).join('');
  }
  function pluralKeys(n) {
    var m = n % 100;
    if (m >= 11 && m <= 14) return 'ей';
    switch (n % 10) { case 1: return ''; case 2: case 3: case 4: return 'а'; default: return 'ей'; }
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
    $('sc-list').addEventListener('click', function (e) {
      /* правка 2.16: клик по заголовку группы — свернуть/развернуть секцию */
      var gh = e.target.closest('[data-toggle-group]');
      if (gh) {
        var name = gh.getAttribute('data-toggle-group');
        state.collapsed[name] = !state.collapsed[name];
        gh.closest('.sc-group').classList.toggle('collapsed', !!state.collapsed[name]);
        return;
      }
      var ed = e.target.closest('[data-edit]');
      if (ed) openModal(ed.getAttribute('data-edit'));
    });
    $('sc-modal-close').addEventListener('click', closeModal);
    $('sc-modal-backdrop').addEventListener('click', function (e) { if (e.target === $('sc-modal-backdrop')) closeModal(); });
    $('sc-form').addEventListener('submit', save);
    load();
  });
})();
