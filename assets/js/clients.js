/* ==========================================================================
   SISKU · clients.js — страница «Клиенты» (v0.13.0-draft, РЕАЛЬНАЯ база)
   Данные: draft_clients_bundle() (скрипт 15) — таблица clients + агрегаты
   заказов (кол-во, суммы, даты первого/последнего). Клиенты попадают в базу
   автоматически из заказов (create_order v5), дедупликация по телефону/e-mail.
   Паттерны проекта: маска + «глазик» (admin.js), CSV с BOM и «;»,
   пагинация по 30, сортировка кликом по заголовку, валидация телефона/почты
   по российским маскам, блокировка повторной отправки «Сохранить».
   История заказов в карточке — следующая волна (feature-proposals.md, п. 1).
   ========================================================================== */
(function () {
  'use strict';

  var state = {
    clients: [],                 /* клиенты с присоединёнными агрегатами */
    revealed: {},                /* клиент, у которого раскрыты контакты */
    sort: { field: 'last', dir: 'desc' },
    page: 1,
    editingId: null,
    saving: false
  };

  function $(id) { return document.getElementById(id); }
  /* общие утилиты — assets/js/util.js (v0.14.0, фикс F32: одна копия на проект) */
  var esc = SiskuUtil.esc, money = SiskuUtil.money, fmtDate = SiskuUtil.fmtDate,
      dayKey = SiskuUtil.dayKey,
      maskPhone = SiskuUtil.maskPhone, maskEmail = SiskuUtil.maskEmail,
      phoneOk = SiskuUtil.phoneOk, emailOk = SiskuUtil.emailOk;
  /* ключи дедупликации — ЗЕРКАЛО серверных draft_phone_key / draft_email_key
     (скрипт 15); истина — сервер (фикс F32: упрощённая emailOk clients.js
     унифицирована со строгой маской site.js/users.js) */
  var phoneKey = SiskuUtil.phoneKey, emailKey = SiskuUtil.emailKey;

  /* ---------- загрузка ---------- */
  function load() {
    if (!db) {
      $('cl-loading').hidden = true;
      $('cl-error').hidden = false;
      $('cl-error').textContent = 'База не подключена: ' + (dbError || 'заполните assets/js/config.js');
      return Promise.reject(new Error(dbError || 'нет БД'));
    }
    $('cl-loading').hidden = false;
    return db.rpc('draft_clients_bundle').then(function (res) {
      $('cl-loading').hidden = true;
      if (res.error) throw res.error;
      var d = res.data || {};
      var stats = {};
      (d.stats || []).forEach(function (s) { stats[s.client_id] = s; });
      state.clients = (d.clients || []).map(function (c) {
        var st = stats[c.id] || {};
        c.orders = Number(st.orders || 0);
        c.sum = Number(st.sum || 0);
        c.paidSum = Number(st.paid_sum || 0);
        c.first = st.first_order || null;
        c.last = st.last_order || null;
        return c;
      });
      $('cl-error').hidden = true;
      render();
    }).catch(function (e) {
      $('cl-loading').hidden = true;
      $('cl-error').hidden = false;
      $('cl-error').textContent = 'Ошибка загрузки: ' + e.message;
    });
  }

  /* ---------- список ---------- */
  function filtered() {
    var q = $('cl-search').value.trim().toLowerCase();
    var list = state.clients.filter(function (c) {
      if (!q) return true;
      return (c.full_name + ' ' + (c.phone || '') + ' ' + (c.email || '')).toLowerCase().indexOf(q) !== -1;
    });
    var f = state.sort.field, dir = state.sort.dir === 'asc' ? 1 : -1;
    list.sort(function (a, b) {
      function num(x) { return f === 'sum' ? x.sum : f === 'count' ? x.orders : 0; }
      function ts(x) { return f === 'first' ? (x.first ? new Date(x.first).getTime() : 0) : f === 'last' ? (x.last ? new Date(x.last).getTime() : 0) : 0; }
      if (f === 'name') return a.full_name.localeCompare(b.full_name, 'ru') * dir;
      if (f === 'sum' || f === 'count') return (num(a) - num(b)) * dir;
      return (ts(a) - ts(b)) * dir;
    });
    return list;
  }
  function renderSortIcons() {
    document.querySelectorAll('th.sortable').forEach(function (th) {
      var active = th.getAttribute('data-sort') === state.sort.field;
      th.classList.toggle('active', active);
      th.querySelector('.sort-ic').textContent = active ? (state.sort.dir === 'asc' ? '▲' : '▼') : '↕';
    });
  }
  function render() {
    var list = filtered();
    var PAGESIZE = 30;                                 /* пагинация: 30 клиентов на страницу */
    var pages = Math.max(1, Math.ceil(list.length / PAGESIZE));
    if (state.page > pages) state.page = pages;
    if (state.page < 1) state.page = 1;
    var visible = list.slice((state.page - 1) * PAGESIZE, state.page * PAGESIZE);
    /* фикс F28 (v0.14.0): признак «пусто» — по отфильтрованному списку */
    if (list.length === 0) {
      $('cl-empty').hidden = false;
      $('cl-empty').textContent = state.clients.length
        ? 'Ничего не найдено по этому поиску — измените или очистите запрос.'
        : 'Клиентов пока нет. Оформите тестовый заказ на витрине — клиент появится здесь автоматически.';
    } else {
      $('cl-empty').hidden = true;
    }
    $('cl-body').innerHTML = visible.map(function (c) {
      var revealed = state.revealed[c.id];
      return '<tr>' +
        '<td class="user-fio" data-edit="' + c.id + '" title="Открыть карточку клиента">' + esc(c.full_name) + '</td>' +
        '<td class="tabular muted masked">' + esc(revealed ? (c.phone || '—') : maskPhone(c.phone)) +
          '<button class="eye" data-eye="' + c.id + '" title="Показать или скрыть контакты">' + (revealed ? 'скрыть' : 'показать') + '</button>' +
        '</td>' +
        '<td class="muted">' + esc(revealed ? (c.email || '—') : maskEmail(c.email)) + '</td>' +
        '<td class="tabular muted">' + fmtDate(c.first) + '</td>' +
        '<td class="tabular muted">' + fmtDate(c.last) + '</td>' +
        '<td class="tabular">' + money(c.sum) + '</td>' +
        '<td class="tabular">' + c.orders + '</td>' +
      '</tr>';
    }).join('');
    renderSortIcons();
    var pager = $('cl-pager');
    if (pages > 1) {
      pager.hidden = false;
      $('cl-pg-info').textContent = 'Стр. ' + state.page + ' из ' + pages +
        ' (показано ' + ((state.page - 1) * PAGESIZE + 1) + '–' +
        Math.min(list.length, state.page * PAGESIZE) + ' из ' + list.length + ')';
      $('cl-pg-prev').disabled = state.page <= 1;
      $('cl-pg-next').disabled = state.page >= pages;
    } else {
      pager.hidden = true;
    }
  }

  /* ---------- CSV (BOM + «;» — открывается в Excel, как в учебном проекте) ---------- */
  function exportCsv() {
    var list = filtered();
    var head = ['ФИО', 'Телефон', 'E-mail', 'Адрес', 'Первый заказ', 'Последний заказ', 'Заказов', 'Сумма заказов, ₽', 'Оплачено, ₽', 'Комментарий'];
    var lines = [head.join(';')];
    list.forEach(function (c) {
      var row = [
        c.full_name, c.phone || '', c.email || '', (c.address || '').replace(/;/g, ','),
        fmtDate(c.first), fmtDate(c.last), c.orders, Math.round(c.sum), Math.round(c.paidSum),
        (c.note || '').replace(/;/g, ',').replace(/\n/g, ' ')
      ];
      lines.push(row.map(SiskuUtil.csvCell).join(';'));   /* фикс F06 (v0.14.0): анти-формульный префикс против CSV-инъекции */
    });
    var blob = new Blob(['\uFEFF' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'sisku-clients-' + dayKey(new Date()) + '.csv';   /* фикс F29: локальная дата, без UTC-фантома */
    a.click();
    URL.revokeObjectURL(a.href);
  }

  /* ---------- карточка клиента ---------- */
  function openCard(id) {
    var c = state.clients.filter(function (x) { return x.id === id; })[0];
    if (!c) return;
    state.editingId = id;
    $('clm-title').textContent = c.full_name;
    $('clm-stats').textContent = 'Заказов: ' + c.orders + ' · на сумму ' + money(c.sum) +
      ' (оплачено ' + money(c.paidSum) + ')' +
      ' · первый ' + fmtDate(c.first) + ' · последний ' + fmtDate(c.last);
    $('clm-fio').value = c.full_name;
    $('clm-phone').value = c.phone || '';
    $('clm-email').value = c.email || '';
    $('clm-comment').value = c.note || '';
    $('clm-error').hidden = true;
    $('cl-modal-backdrop').classList.add('open');
  }
  function cardError(msg) {
    $('clm-error').textContent = msg;
    $('clm-error').hidden = false;
  }
  function saveCard(e) {
    e.preventDefault();
    if (state.saving) return;                          /* защита от повторных кликов */
    var c = state.clients.filter(function (x) { return x.id === state.editingId; })[0];
    if (!c) return;
    var fio = $('clm-fio').value.trim();
    var phone = $('clm-phone').value.trim();
    var email = $('clm-email').value.trim();
    var note = $('clm-comment').value.trim();
    if (!fio) { cardError('ФИО не может быть пустым'); return; }
    if (phone && !phoneOk(phone)) { cardError('Формат телефона: +7 (999) 123-45-67 или 8 999 123-45-67'); return; }
    if (email && !emailOk(email)) { cardError('Формат почты: name@example.ru'); return; }
    if (!phone && !email) { cardError('Оставьте хотя бы один контакт: телефон или e-mail'); return; }

    state.saving = true;
    $('clm-save').disabled = true;
    db.from('clients').update({
      full_name: fio,
      phone: phone || null,
      email: email || null,
      note: note || null,
      phone_key: phoneKey(phone),
      email_key: emailKey(email),
      updated_at: new Date().toISOString()
    }).eq('id', c.id).then(function (res) {
      state.saving = false;
      $('clm-save').disabled = false;
      if (res.error) {
        /* 23505 — другой клиент уже занимает такой телефон/e-mail */
        cardError(res.error.code === '23505'
          ? 'Такой телефон или e-mail уже принадлежит другому клиенту — объедините дубли вручную (Table Editor → clients).'
          : res.error.message);
        return;
      }
      $('cl-modal-backdrop').classList.remove('open');
      load();
    }).catch(function (err) {
      state.saving = false;
      $('clm-save').disabled = false;
      cardError('Ошибка сети: ' + err.message);
    });
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;
    if (window.initAdminTheme) window.initAdminTheme();
    $('btn-logout').addEventListener('click', function () { if (window.mockLogout) window.mockLogout(); });
    $('btn-refresh').addEventListener('click', load);
    $('btn-cl-csv').addEventListener('click', exportCsv);
    $('cl-search').addEventListener('input', function () { state.page = 1; render(); });
    $('cl-pg-prev').addEventListener('click', function () { state.page -= 1; render(); });
    $('cl-pg-next').addEventListener('click', function () { state.page += 1; render(); });
    document.querySelectorAll('th.sortable').forEach(function (th) {
      th.addEventListener('click', function () {
        var f = th.getAttribute('data-sort');
        if (state.sort.field === f) {
          state.sort.dir = state.sort.dir === 'asc' ? 'desc' : 'asc';
        } else {
          state.sort.field = f;
          state.sort.dir = f === 'name' ? 'asc' : 'desc';
        }
        state.page = 1;
        render();
      });
    });
    $('cl-body').addEventListener('click', function (e) {
      var eye = e.target.closest('button[data-eye]');
      if (eye) {
        var eid = Number(eye.getAttribute('data-eye'));
        state.revealed[eid] = !state.revealed[eid];
        render();
        e.stopPropagation();
        return;
      }
      var ed = e.target.closest('[data-edit]');
      if (ed) openCard(Number(ed.getAttribute('data-edit')));
    });
    $('cl-modal-close').addEventListener('click', function () { $('cl-modal-backdrop').classList.remove('open'); });
    $('cl-modal-backdrop').addEventListener('click', function (e) {
      if (e.target === $('cl-modal-backdrop')) $('cl-modal-backdrop').classList.remove('open');
    });
    $('cl-form').addEventListener('submit', saveCard);
    load();
  });
})();
