/* ==========================================================================
   SISKU · clients.js — страница «Клиенты» (v0.18.0-draft, РЕАЛЬНАЯ база)
   Данные: draft_clients_bundle() (скрипт 15 → baseline 09) — таблица clients
   + агрегаты заказов (кол-во, суммы, даты первого/последнего). Клиенты
   попадают в базу автоматически из заказов (create_order v9), дедупликация
   по телефону/e-mail.
   v0.18.0 (fp №1, решения Д4–Д7): карточка клиента — история заказов,
   варианты имён и история контактов одним RPC draft_client_card_bundle
   (скрипт 29; грабля №6 — один запрос на открытие, без N+1); сохранение
   карточки — RPC admin_update_client (одна транзакция: clients + история +
   name_confirmed); клик по № заказа — admin.html?order=N&back=client:M
   (обратная навигация «← К клиенту» — обобщение механизма «← К заявке»
   v0.16.0); диплинк clients.html?client=N открывает карточку после загрузки.
   Паттерны проекта: маска + «глазик» (admin.js), CSV с BOM и «;»,
   пагинация по 30, сортировка кликом по заголовку, валидация телефона/почты
   по российским маскам, блокировка повторной отправки «Сохранить».
   ========================================================================== */
(function () {
  'use strict';

  var state = {
    clients: [],                 /* клиенты с присоединёнными агрегатами */
    revealed: {},                /* клиент, у которого раскрыты контакты */
    sort: { field: 'last', dir: 'desc' },
    page: 1,
    editingId: null,
    saving: false,
    card: null                   /* v0.18.0: бандл открытой карточки */
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
    /* v0.18.0 (Д7): ФИО в списке — clients.full_name = подтверждённое имя
       (name_confirmed) либо последний вариант из заказов — приоритет
       «подтверждённое → последнее → первое» обеспечен сервером (create_order
       v7+/v9), пересчёта на клиенте не требуется */
    $('cl-body').innerHTML = visible.map(function (c) {
      var revealed = state.revealed[c.id];
      return '<tr>' +
        '<td class="user-fio" data-edit="' + c.id + '" title="Открыть карточку клиента">' + esc(c.full_name) +
          (c.name_confirmed ? ' <span class="muted" style="font-size:11px" title="Имя подтверждено администратором — новыми заказами не перезаписывается">✓</span>' : '') +
        '</td>' +
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

  /* ---------- карточка клиента (v0.18.0: история заказов, имён, контактов) ---------- */
  var NAME_SRC = { order: 'заказ', admin: 'админ', merge: 'слияние', backfill: 'исходное' };
  var CONTACT_TYPE = { phone: 'Телефон', email: 'E-mail' };
  var CONTACT_ACTION = {
    set: 'указан', changed: 'изменён',
    offered: 'предложен в заказе', invalidated: 'утратил силу'
  };
  var WHO = { site: 'сайт', admin: 'админ', backfill: 'исходные данные' };

  function cardError(msg) {
    $('clm-card-error').textContent = msg;
    $('clm-card-error').hidden = false;
  }

  function loadCardBundle(id) {
    $('clm-card-error').hidden = true;
    return db.rpc('draft_client_card_bundle', { p_client_id: id }).then(function (res) {
      if (res.error) throw res.error;
      var d = res.data || {};
      state.card = { id: id, data: d };
      renderOrdersBlock(d);
      renderNamesBlock(d);
      renderContactsBlock(d);
    }).catch(function (e) {
      cardError('Не удалось загрузить историю: ' + SiskuUtil.friendlyDbError(e));
      $('clm-orders').innerHTML = '<span class="muted">—</span>';
      $('clm-names').innerHTML = '<span class="muted">—</span>';
      $('clm-contacts').innerHTML = '<span class="muted">—</span>';
    });
  }

  function renderOrdersBlock(d) {
    var orders = d.orders || [];
    $('clm-orders-count').textContent = orders.length
      ? orders.length + ' шт.' : '';
    if (!orders.length) {
      $('clm-orders').innerHTML = '<span class="muted">Заказов пока нет.</span>';
      return;
    }
    $('clm-orders').innerHTML = orders.map(function (o) {
      var items = o.items || [];
      var first = items.length
        ? items[0].title_snapshot + (Number(items[0].quantity) > 1 ? ' ×' + items[0].quantity : '')
        : '';
      var comp = items.length > 1 ? first + ' и ещё ' + (items.length - 1) : first;
      var sum = Number(o.total || 0) + Number(o.delivery_cost || 0);
      return '<div style="display:flex;align-items:baseline;gap:10px;padding:7px 0;border-bottom:1px solid var(--line)">' +
        '<button class="linklike" data-goto-order="' + Number(o.id) + '" ' +
          'title="Открыть карточку заказа (с возвратом к клиенту)" ' +
          'style="background:none;border:0;padding:0;cursor:pointer;font:inherit;color:var(--accent)">№ ' + Number(o.id) + '</button>' +
        '<span class="tabular muted">' + fmtDate(o.created_at) + '</span>' +
        '<span class="status-pill" data-code="' + esc(o.status_code || '') + '">' + esc(o.status_name || '') + '</span>' +
        '<span class="tabular" style="margin-left:auto;white-space:nowrap">' + money(sum) +
          (o.is_paid ? ' · оплачен' : '') + '</span>' +
        '<span class="muted" style="flex-basis:100%;font-size:12px">' +
          esc(items.length + ' поз. — ' + comp) + '</span>' +
      '</div>';
    }).join('');
  }

  function renderNamesBlock(d) {
    var cl = d.client || {};
    var names = d.names || [];
    $('clm-name-flag').hidden = !cl.name_confirmed;
    if (!names.length) {
      $('clm-names').innerHTML = '<span class="muted">История имён пока не ведётся.</span>';
      return;
    }
    $('clm-names').innerHTML = names.slice().reverse().map(function (n) {
      var current = n.full_name === cl.full_name;
      return '<div style="padding:5px 0;border-bottom:1px solid var(--line)">' +
        '<span' + (current ? ' style="font-weight:600"' : '') + '>' + esc(n.full_name) + '</span>' +
        (current ? ' <span class="muted" style="font-size:11px">· текущее</span>' : '') +
        '<div class="muted" style="font-size:12px">' + fmtDate(n.created_at) +
          ' · ' + esc(NAME_SRC[n.source] || n.source) + '</div>' +
      '</div>';
    }).join('');
  }

  function renderContactsBlock(d) {
    var contacts = d.contacts || [];
    if (!contacts.length) {
      $('clm-contacts').innerHTML = '<span class="muted">Изменений контактов не было.</span>';
      return;
    }
    $('clm-contacts').innerHTML = contacts.slice().reverse().map(function (h) {
      return '<div style="padding:5px 0;border-bottom:1px solid var(--line)">' +
        '<span>' + esc(CONTACT_TYPE[h.type] || h.type) + ': ' + esc(h.value || '—') + '</span>' +
        '<div class="muted" style="font-size:12px">' + fmtDate(h.created_at) +
          ' · ' + esc(CONTACT_ACTION[h.action] || h.action) +
          ' · ' + esc(WHO[h.changed_by] || h.changed_by) + '</div>' +
      '</div>';
    }).join('');
  }

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
    $('clm-card-error').hidden = true;
    $('clm-orders').innerHTML = '<span class="muted">Загружаем…</span>';
    $('clm-names').innerHTML = '<span class="muted">Загружаем…</span>';
    $('clm-contacts').innerHTML = '<span class="muted">Загружаем…</span>';
    $('clm-orders-count').textContent = '';
    $('cl-modal-backdrop').classList.add('open');
    loadCardBundle(id);                                /* v0.18.0: один RPC на карточку */
  }

  function formError(msg) {
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
    if (!fio) { formError('ФИО не может быть пустым'); return; }
    if (phone && !phoneOk(phone)) { formError('Формат телефона: +7 (999) 123-45-67 или 8 999 123-45-67'); return; }
    if (email && !emailOk(email)) { formError('Формат почты: name@example.ru'); return; }
    if (!phone && !email) { formError('Оставьте хотя бы один контакт: телефон или e-mail'); return; }

    state.saving = true;
    $('clm-save').disabled = true;
    /* v0.18.0 (Д4): сохранение — RPC admin_update_client (скрипт 29), одна
       транзакция: clients (включая ключи дедупликации и name_confirmed) +
       client_contact_history (старое — invalidated, новое — changed) +
       client_name_history (admin). Правка 2.20 (v0.15.0) сохранена:
       сохранение карточки = имя подтверждено — create_order v9 больше не
       перезапишет full_name новыми заказами этого клиента. */
    db.rpc('admin_update_client', { p: {
      client_id: c.id, full_name: fio,
      phone: phone, email: email, note: note
    } }).then(function (res) {
      state.saving = false;
      $('clm-save').disabled = false;
      if (res.error) {
        formError(SiskuUtil.friendlyDbError(res.error));
        return;
      }
      /* список и карточка — из свежих данных (карточка остаётся открытой) */
      load().then(function () { openCard(c.id); });
    }).catch(function (err) {
      state.saving = false;
      $('clm-save').disabled = false;
      formError('Ошибка сети: ' + err.message);
    });
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;
    if (window.initAdminTheme) window.initAdminTheme();
    $('btn-logout').addEventListener('click', function () { if (window.mockLogout) window.mockLogout(); });
    $('btn-refresh').addEventListener('click', function () { load(); });
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
    /* v0.18.0 (Д6): клик по № заказа в истории — карточка заказа в admin.html
       с обратной навигацией «← К клиенту» (deep link) */
    $('clm-orders').addEventListener('click', function (e) {
      var b = e.target.closest('button[data-goto-order]');
      if (!b) return;
      window.location.href = 'admin.html?order=' + Number(b.getAttribute('data-goto-order')) +
        '&back=client:' + state.editingId;
    });
    $('cl-modal-close').addEventListener('click', function () { $('cl-modal-backdrop').classList.remove('open'); });
    $('cl-modal-backdrop').addEventListener('click', function (e) {
      if (e.target === $('cl-modal-backdrop')) $('cl-modal-backdrop').classList.remove('open');
    });
    $('cl-form').addEventListener('submit', saveCard);
    /* v0.18.0 (Д6): диплинк clients.html?client=N — карточка после загрузки
       (строго в then() бандла — гонка исключена) */
    load().then(function () {
      var m = /^(\d+)$/.exec(new URLSearchParams(window.location.search).get('client') || '');
      if (!m) return;
      var id = Number(m[1]);
      var found = state.clients.filter(function (x) { return x.id === id; })[0];
      if (found) {
        openCard(id);
      } else {
        $('cl-error').hidden = false;
        $('cl-error').textContent = 'Клиент № ' + id + ' не найден — ссылка устарела.';
      }
    }).catch(function () { /* плашка ошибки уже показана в load() */ });
  });
})();
