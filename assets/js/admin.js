/* ==========================================================================
   SISKU · admin.js — админ-панель черновика (вход через мок-авторизацию login.html, v0.4.0-draft)
   Вкладки: заказы (список, карточка, смена статусов по модели переходов,
   признак оплаты, маскирование контактов, CSV) и статистика (KPI, графики).
   Паттерны учебного проекта: маска + «глазик», CSV с BOM и «;»,
   смена статусов только через серверную функцию с проверкой переходов.
   v0.18.0 (Д6): диплинк admin.html?order=N&back=client:M — карточка заказа
   из истории заказов карточки клиента, обратная навигация «← К клиенту».
   ========================================================================== */
(function () {
  'use strict';

  var state = {
    orders: [], items: [], statuses: [], transitions: [],
    payments: [], deliveries: [], history: [],
    promos: [],              /* v0.13.0: промокоды — подвкладка статистики «Акции» */
    statsTab: 'orders',      /* v0.13.0: активная подвкладка: orders | promos | admins | clients | returns */
    promoMode: 'table',      /* правка 2.3 (v0.16.0, записка 6): «Акции» по умолчанию — таблица (было chart) */
    returns: { requests: [], reasons: [], content: {} },   /* v0.16.0 (fp №3): заявки, причины, тексты returns.* */
    returnsLoaded: false,    /* бандл возвратов загружен (лениво — при первом открытии) */
    rrFilter: '',            /* фильтр очереди заявок по статусу */
    rrPage: 1,               /* пагинация очереди (30 на страницу) */
    returnMode: 'table',     /* статистика причин: chart | table */
    revealed: {},            /* заказ, у которого раскрыты контакты */
    orderBack: null,         /* v0.18.0 (Д6): контекст обратной навигации карточки заказа */
    clientsStats: null,      /* v0.19.0 (fp №7): строки + пороги сегментов (лениво — при первом открытии подвкладки) */
    cstFilter: '',           /* фильтр сегментов: '' | new | repeat | vip | dormant */
    cstSort: { field: 'sum', dir: 'desc' },
    cstPage: 1,              /* пагинация таблицы сегментов (30 на страницу) */
    cstRevealed: {},         /* клиент, у которого раскрыты контакты */
    cstSaving: false,        /* блокировка повторной отправки «Сохранить» (пороги) */
    writeoffs: { rows: [], reasons: [], sessions: [] },   /* v0.20.0 (fp №9): журнал + итоги сессий */
    writeoffsLoaded: false,  /* бандл списаний загружен (лениво — при первом открытии) */
    woMode: 'table',         /* причины списаний: chart | table (по умолчанию таблица — правка 2.3) */
    methodsMode: 'table',    /* «Таблица» по умолчанию, «Диаграмма» — по переключателю */
    sort: { field: 'created', dir: 'desc' },   /* сортировка таблицы заказов */
    page: 1,                                    /* пагинация таблицы заказов */
    topSort: 'sum',                             /* топ товаров: sum | qty */
    funnelMode: 'table',                        /* воронка: chart | table (v0.15.0, правка 2.12: по умолчанию таблица) */
    charts: {}
  };

  function $(id) { return document.getElementById(id); }
  /* общие утилиты — assets/js/util.js (v0.14.0, фикс F32: одна копия на проект) */
  var esc = SiskuUtil.esc, money = SiskuUtil.money, fmtDate = SiskuUtil.fmtDateTime,
      maskPhone = SiskuUtil.maskPhone, maskEmail = SiskuUtil.maskEmail,
      dayKey = SiskuUtil.dayKey;
  function statusByid(id) { return state.statuses.filter(function (s) { return s.id === id; })[0] || {}; }
  function paymentByid(id) { return state.payments.filter(function (m) { return m.id === id; })[0] || {}; }
  function deliveryByid(id) { return state.deliveries.filter(function (m) { return m.id === id; })[0] || {}; }
  /* v0.17.0 (внешний ревью 06.10.2026, находка B3): индекс order_id → позиции
     (строится в loadAll) вместо O(N²) filter на каждую строку таблицы */
  function itemsOf(orderId) {
    if (state.itemsByOrder) return state.itemsByOrder[orderId] || [];
    return state.items.filter(function (i) { return i.order_id === orderId; });
  }

  /* v0.17.0 (находка B2): после смены статуса/оплаты — точечное обновление:
     заказ в state правится на месте, история этого заказа перезапрашивается одним
     лёгким запросом, список/карточка/статистика пересчитываются локально —
     полная перезагрузка draft_admin_bundle больше не дёргается */
  function refreshOrderHistory(orderId) {
    if (!db) return Promise.resolve();
    return db.from('order_status_history').select('*').eq('order_id', orderId)
      .then(function (res) {
        if (res.error || !res.data) return;
        state.history = state.history.filter(function (h) { return h.order_id !== orderId; })
          .concat(res.data);
      });
  }


  /* ---------- загрузка ---------- */
  function loadAll() {
    if (!db) {
      $('orders-loading').hidden = true;
      $('orders-error').hidden = false;
      $('orders-error').textContent = 'База не подключена: ' + (dbError || 'заполните assets/js/config.js');
      return Promise.reject(new Error(dbError || 'нет БД'));
    }
    /* v0.5.0: один запрос-сборка вместо семи — лечит долгую загрузку */
    return db.rpc('draft_admin_bundle').then(function (res) {
      if (res.error) throw res.error;
      var d = res.data;
      state.orders = d.orders;
      state.items = d.items;
      state.itemsByOrder = {};   /* v0.17.0 (находка B3) */
      d.items.forEach(function (i) {
        (state.itemsByOrder[i.order_id] = state.itemsByOrder[i.order_id] || []).push(i);
      });
      state.statuses = d.statuses;
      state.transitions = d.transitions;
      state.payments = d.payments;
      state.deliveries = d.deliveries;
      state.history = d.history;
      state.promos = d.promos || [];      /* v0.13.0: draft_admin_bundle v2 */

      var keepStatus = $('f-status').value;      /* фильтр не сбрасывается перезагрузкой */
      $('f-status').innerHTML = '<option value="">Все статусы</option>' +
        state.statuses.map(function (s) { return '<option value="' + s.id + '">' + esc(s.name) + '</option>'; }).join('');
      $('f-status').value = keepStatus;
      $('f-status').dispatchEvent(new Event('refresh'));   /* лейбл кастом-селекта в такт значению */
      if (window.enhanceSelects) enhanceSelects();
      renderOrders();
      renderStatsActive();
    });
  }

  /* ---------- список заказов ---------- */
  function filteredOrders() {
    var q = $('f-search').value.trim().toLowerCase();
    var st = $('f-status').value;
    var pd = $('f-paid').value;
    var list = state.orders.filter(function (o) {
      if (st && String(o.status_id) !== st) return false;
      if (pd === '1' && !o.is_paid) return false;
      if (pd === '0' && o.is_paid) return false;
      if (q) {
        var hay = [o.id, o.customer_name, o.customer_phone, o.customer_email].join(' ').toLowerCase();
        if (hay.indexOf(q) === -1) return false;
      }
      return true;
    });
    /* сортировка: № / дата / сумма, asc и desc */
    var f = state.sort.field, dir = state.sort.dir === 'asc' ? 1 : -1;
    list.sort(function (a, b) {
      if (f === 'id') return (a.id - b.id) * dir;
      if (f === 'total') return ((a.total + a.delivery_cost) - (b.total + b.delivery_cost)) * dir;
      return (new Date(a.created_at) - new Date(b.created_at)) * dir;
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

  function renderOrders() {
    var list = filteredOrders();
    var PAGESIZE = 30;                                  /* пагинация: 30 заказов на страницу */
    var pages = Math.max(1, Math.ceil(list.length / PAGESIZE));
    if (state.page > pages) state.page = pages;
    if (state.page < 1) state.page = 1;
    var visible = list.slice((state.page - 1) * PAGESIZE, state.page * PAGESIZE);
    $('orders-loading').hidden = true;
    /* фикс F28 (v0.14.0): признак «пусто» — по ОТФИЛЬТРОВАННОМУ списку;
       при нулевом результате фильтра больше не молчаливая пустая таблица */
    if (list.length === 0) {
      $('orders-empty').hidden = false;
      $('orders-empty').textContent = state.orders.length
        ? 'Ничего не найдено по фильтрам — измените статус/оплату или очистите поиск.'
        : 'Заказов пока нет. Оформите тестовый заказ на витрине — он появится здесь.';
    } else {
      $('orders-empty').hidden = true;
    }
    $('orders-error').hidden = true;
    $('orders-body').innerHTML = visible.map(function (o) {
      var st = statusByid(o.status_id);
      var n = itemsOf(o.id).reduce(function (s, i) { return s + i.quantity; }, 0);
      var revealed = state.revealed[o.id];
      var phone = o.customer_phone || '';
      var email = o.customer_email || '';
      return '<tr data-id="' + o.id + '">' +
        '<td class="tabular"><b>№ ' + o.id + '</b></td>' +
        '<td class="tabular muted col-created">' + fmtDate(o.created_at) + '</td>' +
        '<td>' + esc(o.customer_name) +
          '<div class="muted masked" style="font-size:12.5px">' +
            esc(revealed ? (phone || '—') : maskPhone(phone)) +
            (email ? '<div>' + esc(revealed ? email : maskEmail(email)) + '</div>' : '') +
            '<button class="eye" data-eye="' + o.id + '" title="Показать или скрыть контакты">' + (revealed ? 'скрыть' : 'показать') + '</button>' +
          '</div></td>' +
        '<td class="tabular col-items">' + n + ' шт.</td>' +
        '<td class="tabular">' + money(o.total + o.delivery_cost) + '</td>' +
        '<td class="col-paid">' + (o.is_paid
            ? '<span class="paid-mark">оплачен ' + (o.paid_at ? fmtDate(o.paid_at) : '') + '</span>'
            : '<span class="paid-mark no">не оплачен</span>') + '</td>' +
        '<td class="muted col-delivery" style="font-size:13px">' + esc(deliveryByid(o.delivery_method_id).name || '—') + '</td>' +
        '<td><span class="status-pill" data-code="' + esc(st.code) + '">' + esc(st.name) + '</span></td>' +
      '</tr>';
    }).join('');
    renderSortIcons();
    /* пагинация */
    var pager = $('orders-pager');
    if (pages > 1) {
      pager.hidden = false;
      $('pg-info').textContent = 'Стр. ' + state.page + ' из ' + pages +
        ' (показано ' + ((state.page - 1) * PAGESIZE + 1) + '–' +
        Math.min(list.length, state.page * PAGESIZE) + ' из ' + list.length + ')';
      $('pg-prev').disabled = state.page <= 1;
      $('pg-next').disabled = state.page >= pages;
    } else {
      pager.hidden = true;
    }
  }

  /* ---------- карточка заказа ----------
     back (v0.16.0 → v0.18.0 обобщён): контекст обратной навигации —
     { kind: 'return', id } — заявка на возврат («← К заявке на возврат № X»);
     { kind: 'client', id } — карточка клиента («← К карточке клиента»,
     deep link clients.html?client=N — решение Д6 волны v0.18.0) */
  function openOrder(id, back) {
    state.orderBack = back || null;   /* повторное открытие после смены статуса/оплаты — с тем же контекстом */
    var o = state.orders.filter(function (x) { return x.id === id; })[0];
    if (!o) return;
    var items = itemsOf(id);
    /* фикс F26 (v0.14.0): история уже есть в state.history из draft_admin_bundle —
       отдельный запрос убран (очередь соединений бесплатного тарифа — грабля №6) */
    var history = state.history.filter(function (h) { return h.order_id === id; })
      .slice().sort(function (a, b) { return new Date(a.changed_at) - new Date(b.changed_at); });
    var st = statusByid(o.status_id);
      var allowed = state.transitions
        .filter(function (t) { return t.from_status_id === o.status_id; })
        .map(function (t) { return statusByid(t.to_status_id); })
        .sort(function (a, b) { return (a.sort_order || 0) - (b.sort_order || 0); });   /* «Сборка» раньше «Отменён» */
      var locked = st.code === 'cancelled';   /* отменённые: статусы заблокированы, оплата — нет (правка 2.2) */

      $('order-modal-body').innerHTML =
        (back && back.kind === 'return' ? '<div style="margin-bottom:10px"><button class="linklike" id="oc-back-return">← К заявке на возврат № ' + back.id + '</button></div>' : '') +
        (back && back.kind === 'client' ? '<div style="margin-bottom:10px"><button class="linklike" id="oc-back-client">← К карточке клиента</button></div>' : '') +
        '<div class="modal-head-row"><h2>Заказ № ' + o.id + '</h2>' +
        '<span class="status-pill status-pill-lg" data-code="' + esc(st.code) + '">' + esc(st.name) + '</span></div>' +
        '<div class="muted" style="font-size:12.5px;margin-top:2px">создан ' + fmtDate(o.created_at) + '</div>' +
        '<div class="order-meta">' +
          '<div>' +
            metaRow('Клиент', esc(o.customer_name)) +
            metaRow('Телефон', '<span class="tabular">' + esc(o.customer_phone || '—') + '</span>') +
            metaRow('E-mail', esc(o.customer_email || '—')) +
            metaRow('Комментарий', o.comment ? esc(o.comment) : '—') +
          '</div>' +
          '<div>' +
            metaRow('Оплата', esc(paymentByid(o.payment_method_id).name || '—') + (o.is_paid ? ' · <b style="color:var(--ok)">оплачен' + (o.paid_at ? ' ' + fmtDate(o.paid_at) : '') + '</b>' : ' · не оплачен')) +
            metaRow('Адрес', esc(o.customer_address || '—')) +
            metaRow('Доставка', esc(deliveryByid(o.delivery_method_id).name || '—')) +
            metaRow('Итого', '<b class="tabular">' + money(o.total + o.delivery_cost) + '</b>') +
          '</div>' +
        '</div>' +
        '<div class="subhead">Состав заказа</div>' +
        '<table class="items-table"><thead><tr><th>Товар</th><th>Вариант</th><th>Кол-во</th><th>Цена</th><th>Сумма</th></tr></thead><tbody>' +
        items.map(function (i) {
          return '<tr><td>' + esc(i.title_snapshot) + '</td><td>' + esc(i.variant_snapshot || '—') + '</td>' +
            '<td class="tabular">' + i.quantity + '</td><td class="tabular">' + money(i.price) + '</td>' +
            '<td class="tabular">' + money(i.price * i.quantity) + '</td></tr>';
        }).join('') + '</tbody></table>' +
        '<div class="subhead">Смена статуса (модель переходов)</div>' +
        '<div class="actions-row">' +
          '<select id="oc-status"' + (locked ? ' disabled' : '') + '>' +
            (allowed.length
              ? allowed.map(function (s) { return '<option value="' + esc(s.code) + '">→ ' + esc(s.name) + '</option>'; }).join('')
              : '<option value="">переходы недоступны (финальный статус)</option>') +
          '</select>' +
          '<button class="btn" id="oc-apply"' + (allowed.length && !locked ? '' : ' disabled') + '>Применить</button>' +
          '<button class="btn" id="oc-paid">' + (o.is_paid ? 'Снять отметку оплаты' : 'Отметить оплаченным') + '</button>' +
        '</div>' +
        (locked ? '<div class="locked-note">Заказ отменён — смена статуса заблокирована. Признак оплаты изменить можно: деньги могли поступить после отмены или быть возвращены (правка 2.2, скрипт 18).</div>' : '') +
        '<div class="err-box" id="oc-error" hidden></div>' +
        '<div class="subhead">История статусов</div>' +
        '<ul class="history">' + history.map(function (h) {
          return '<li><b>' + esc(statusByid(h.status_id).name) + '</b> — ' + fmtDate(h.changed_at) +
            ' · ' + esc(h.changed_by) + (h.comment ? ' · ' + esc(h.comment) : '') + '</li>';
        }).join('') + '</ul>';

      $('oc-apply').addEventListener('click', function () {
        var code = $('oc-status').value;
        if (!code) return;
        var self = this;
        self.disabled = true;
        db.rpc('admin_set_status', { p_order_id: o.id, p_status_code: code, p_changed_by: 'draft-admin' })
          .then(function (res) {
            if (res.error) { $('oc-error').textContent = res.error.message; $('oc-error').hidden = false; self.disabled = false; return; }
            /* v0.17.0 (находка B2): точечное обновление вместо loadAll() */
            var ns = state.statuses.filter(function (s) { return s.code === code; })[0];
            if (ns) o.status_id = ns.id;
            refreshOrderHistory(o.id).then(function () {
              renderOrders(); renderStatsActive(); openOrder(o.id, state.orderBack);
            });
          })
          .catch(function (e) {
            $('oc-error').textContent = 'Ошибка сети: ' + e.message;
            $('oc-error').hidden = false;
            self.disabled = false;   /* фикс F11 (v0.14.0): кнопка не залипает */
          });
      });
      $('oc-paid').addEventListener('click', function () {
        var self = this;   /* фикс F11 (v0.14.0): при ошибке RPC кнопка возвращалась
                              в disabled навсегда — карточка «залипала» до переоткрытия */
        self.disabled = true;
        /* правка 2.2 (v0.15.0): v2 функции — с автором события (скрипт 18);
           событие смены оплаты пишется в историю заказа */
        db.rpc('admin_set_paid', { p_order_id: o.id, p_is_paid: !o.is_paid, p_changed_by: 'draft-admin' })
          .then(function (res) {
            if (res && res.error) { $('oc-error').textContent = res.error.message; $('oc-error').hidden = false; self.disabled = false; return; }
            /* v0.17.0 (находка B2): признак оплаты — точечно; событие оплаты
               в истории придёт лёгким запросом refreshOrderHistory */
            o.is_paid = !o.is_paid;
            o.paid_at = o.is_paid ? new Date().toISOString() : null;
            refreshOrderHistory(o.id).then(function () {
              renderOrders(); renderStatsActive(); openOrder(o.id, state.orderBack);
            });
          })
          .catch(function (e) {
            $('oc-error').textContent = 'Ошибка сети: ' + e.message;
            $('oc-error').hidden = false;
            self.disabled = false;
          });
      });

    if (back && back.kind === 'return') {
      $('oc-back-return').addEventListener('click', function () {
        $('order-modal-backdrop').classList.remove('open');
        openReturnRequest(back.id);
      });
    }
    if (back && back.kind === 'client') {
      /* v0.18.0 (Д6): возврат в карточку клиента — deep link clients.html */
      $('oc-back-client').addEventListener('click', function () {
        window.location.href = 'clients.html?client=' + encodeURIComponent(back.id);
      });
    }
    $('order-modal-backdrop').classList.add('open');
    if (window.enhanceSelects) enhanceSelects($('order-modal-body'));
  }
  function metaRow(k, v) { return '<div class="row"><dt>' + k + '</dt><dd>' + v + '</dd></div>'; }

  /* ---------- CSV (BOM + «;» — открывается в Excel, как в учебном проекте) ---------- */
  function exportCsv() {
    var list = filteredOrders();
    var head = ['Номер', 'Создан', 'Клиент', 'Телефон', 'E-mail', 'Адрес', 'Статус', 'Оплачен', 'Сумма товаров', 'Доставка', 'Итого', 'Способ оплаты', 'Способ доставки', 'Комментарий'];
    var lines = [head.join(';')];
    list.forEach(function (o) {
      var row = [
        o.id, fmtDate(o.created_at), o.customer_name, o.customer_phone || '', o.customer_email || '',
        (o.customer_address || '').replace(/;/g, ','), statusByid(o.status_id).name, o.is_paid ? 'да' : 'нет',
        o.total, o.delivery_cost, o.total + o.delivery_cost,
        paymentByid(o.payment_method_id).name, deliveryByid(o.delivery_method_id).name,
        (o.comment || '').replace(/;/g, ',').replace(/\n/g, ' ')
      ];
      lines.push(row.map(SiskuUtil.csvCell).join(';'));   /* фикс F06 (v0.14.0): анти-формульный префикс против CSV-инъекции */
    });
    var blob = new Blob(['\uFEFF' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'sisku-orders-' + dayKey(new Date()) + '.csv';   /* фикс F29: локальная дата, без UTC-фантома */
    a.click();
    URL.revokeObjectURL(a.href);
  }

  /* ---------- статистика ---------- */
  function ordersInPeriod(sel) {
    var days = sel.value;
    if (days === 'all') return state.orders.slice();
    var from = Date.now() - Number(days) * 864e5;
    return state.orders.filter(function (o) { return new Date(o.created_at).getTime() >= from; });
  }
  function periodOrders() { return ordersInPeriod($('s-period')); }

  function renderStats() {
    var list = periodOrders();
    var sum = list.reduce(function (s, o) { return s + o.total + o.delivery_cost; }, 0);
    var paidSum = list.filter(function (o) { return o.is_paid; })
      .reduce(function (s, o) { return s + o.total + o.delivery_cost; }, 0);
    var cancelled = list.filter(function (o) { return statusByid(o.status_id).code === 'cancelled'; }).length;
    var avg = list.length ? sum / list.length : 0;

    $('kpi-grid').innerHTML =
      kpi('Заявок', list.length, 'за выбранный период') +
      kpi('Сумма заявок', money(sum), 'по оформленным заявкам') +
      kpi('Оплачено', money(paidSum), list.filter(function (o) { return o.is_paid; }).length + ' заказ(ов)') +
      kpi('Средний чек', money(avg), 'сумма заявок / число заявок') +
      kpi('Отменено', list.length ? Math.round(cancelled / list.length * 100) + '%' : '0%', cancelled + ' заказ(ов)');

    drawDaysChart(list);
    drawFunnel(list);
    drawTop(list);
    renderMethods(list);
    renderTiming(list);
  }
  function kpi(lbl, val, sub) {
    return '<div class="kpi"><div class="lbl">' + lbl + '</div><div class="val">' + val + '</div><div class="sub">' + sub + '</div></div>';
  }

  var GOLD = '#C9A96A', MUTED = '#A79FB0', LINE = '#2A2A33', TEXT = '#F2EEE4';
  function chartDefaults() {
    /* фикс F34 (v0.14.0): токены брендбука (кэш brand_colors) приоритетнее
       захардкоженной палитры тем — графики следуют цветам владельца;
       дефолты ниже синхронны со скриптом 14 (brand_colors) */
    var light = document.documentElement.getAttribute('data-theme') === 'light';
    var tok = null;
    if (window.brandCachedRows) {
      var theme = light ? 'light' : 'dark';
      tok = {};
      (brandCachedRows() || []).forEach(function (r) { if (r.theme === theme) tok[r.key] = r.value; });
      if (!tok.accent || !tok.muted || !tok.line || !tok.text) tok = null;
    }
    if (tok)       { GOLD = tok.accent; MUTED = tok.muted; LINE = tok.line; TEXT = tok.text; }
    else if (light) { GOLD = '#7A5C2E'; MUTED = '#6F6A60'; LINE = '#E5E0D6'; TEXT = '#1A1A1E'; }
    else           { GOLD = '#C9A96A'; MUTED = '#A79FB0'; LINE = '#2A2A33'; TEXT = '#F2EEE4'; }
    Chart.defaults.color = MUTED;
    Chart.defaults.borderColor = LINE;
    Chart.defaults.font.family = "'Manrope', sans-serif";
  }
  function destroyChart(key) { if (state.charts[key]) { state.charts[key].destroy(); state.charts[key] = null; } }

  function drawDaysChart(list) {
    chartDefaults(); destroyChart('days');
    var byDay = {};
    list.forEach(function (o) {
      var k = dayKey(o.created_at);
      byDay[k] = byDay[k] || { n: 0, sum: 0 };
      byDay[k].n += 1; byDay[k].sum += o.total + o.delivery_cost;
    });
    var keys = Object.keys(byDay).sort();   /* хронология: старые слева, новые справа */
    var labels = keys.map(function (k) { var p = k.split('-'); return p[2] + '.' + p[1]; });
    state.charts.days = new Chart($('chart-days'), {
      type: 'line',
      data: {
        labels: labels,
        datasets: [
          { label: 'Заявки', data: keys.map(function (k) { return byDay[k].n; }), borderColor: GOLD, backgroundColor: SiskuUtil.hexToRgba(GOLD, .15), fill: true, tension: .35, yAxisID: 'y' },
          { label: 'Сумма, ₽', data: keys.map(function (k) { return byDay[k].sum; }), borderColor: MUTED, borderDash: [5, 4], tension: .35, yAxisID: 'y1' }
        ]
      },
      options: {
        responsive: true,
        interaction: { mode: 'index', intersect: false },
        scales: {
          y: { ticks: { precision: 0 }, grid: { color: LINE } },
          y1: { position: 'right', grid: { display: false }, ticks: { callback: function (v) { return SiskuUtil.fmtNum(v); } } }
        },
        plugins: { legend: { labels: { color: MUTED, boxWidth: 14 } } }
      }
    });
  }

  function drawFunnel(list) {
    destroyChart('funnel');
    var counts = state.statuses.map(function (s) {
      return list.filter(function (o) { return o.status_id === s.id; }).length;
    });
    if (state.funnelMode === 'table') {
      $('funnel-chart').hidden = true;
      $('funnel-table').hidden = false;
      $('table-funnel').innerHTML =
        '<thead><tr><th>Статус</th><th style="text-align:right">Заказов</th><th style="text-align:right">Доля</th></tr></thead><tbody>' +
        state.statuses.map(function (s, i) {
          return '<tr><td>' + esc(s.name) + '</td><td class="num">' + counts[i] + '</td>' +
            '<td class="num">' + (list.length ? Math.round(counts[i] / list.length * 100) : 0) + '%</td></tr>';
        }).join('') + '</tbody>';
      return;
    }
    $('funnel-chart').hidden = false;
    $('funnel-table').hidden = true;
    state.charts.funnel = new Chart($('chart-funnel'), {
      type: 'bar',
      data: {
        labels: state.statuses.map(function (s) { return s.name; }),
        datasets: [{ data: counts, backgroundColor: GOLD, borderRadius: 2, barThickness: 12 }]
      },
      options: {
        indexAxis: 'y', responsive: true,
        scales: { x: { ticks: { precision: 0 }, grid: { color: LINE } }, y: { grid: { display: false } } },
        plugins: { legend: { display: false } }
      }
    });
  }

  function drawTop(list) {
    var ids = {};
    list.forEach(function (o) {
      itemsOf(o.id).forEach(function (i) {
        ids[i.title_snapshot] = ids[i.title_snapshot] || { n: 0, sum: 0 };
        ids[i.title_snapshot].n += i.quantity;
        ids[i.title_snapshot].sum += i.price * i.quantity;
      });
    });
    var top = Object.keys(ids).map(function (k) { return { k: k, v: ids[k] }; })
      .sort(function (a, b) {
        return state.topSort === 'qty' ? (b.v.n - a.v.n) || (b.v.sum - a.v.sum) : (b.v.sum - a.v.sum) || (b.v.n - a.v.n);
      }).slice(0, 6);
    var ic = function (key) {
      return '<span class="sort-ic">' + (state.topSort === key ? '▼' : '↕') + '</span>';
    };
    $('top-products').innerHTML =
      '<thead><tr><th>№</th><th>Товар</th>' +
      '<th class="sortable" data-top="qty" style="text-align:right">Кол-во' + ic('qty') + '</th>' +
      '<th class="sortable" data-top="sum" style="text-align:right">Сумма' + ic('sum') + '</th></tr></thead><tbody>' +
      (top.length
        ? top.map(function (t, i) {
            return '<tr><td>' + (i + 1) + '</td><td>' + esc(t.k) + '</td><td class="num">' + t.v.n + ' шт.</td><td class="num">' + money(t.v.sum) + '</td></tr>';
          }).join('')
        : '<tr><td colspan="4" class="muted">Нет данных за период</td></tr>') +
      '</tbody>';
  }

  /* ---------- доставка и оплата: раздельно, диаграмма или таблицы ---------- */
  function methodCounts(refs, field, list) {
    return refs.map(function (m) {
      return list.filter(function (o) { return o[field] === m.id; }).length;
    });
  }
  function drawSimpleBar(key, canvas, labels, counts) {
    chartDefaults(); destroyChart(key);
    state.charts[key] = new Chart(canvas, {
      type: 'bar',
      data: { labels: labels, datasets: [{ data: counts, backgroundColor: GOLD, borderRadius: 2, barThickness: 12 }] },
      options: {
        indexAxis: 'y', responsive: true,
        scales: { x: { ticks: { precision: 0 }, grid: { color: LINE } }, y: { grid: { display: false } } },
        plugins: { legend: { display: false } }
      }
    });
  }
  function methodsTableHtml(refs, counts, total) {
    var rows = refs.map(function (m, i) {
      var share = total ? Math.round(counts[i] / total * 100) : 0;
      return '<tr><td>' + esc(m.name) + '</td><td class="num">' + counts[i] + '</td><td class="num">' + share + '%</td></tr>';
    }).join('');
    return '<thead><tr><th>Способ</th><th style="text-align:right">Заказов</th><th style="text-align:right">Доля</th></tr></thead><tbody>' +
      (rows || '<tr><td colspan="3" class="muted">Нет данных за период</td></tr>') + '</tbody>';
  }
  function renderMethods(list) {
    var dCounts = methodCounts(state.deliveries, 'delivery_method_id', list);
    var pCounts = methodCounts(state.payments, 'payment_method_id', list);
    if (state.methodsMode === 'chart') {
      $('methods-charts').hidden = false;
      $('methods-tables').hidden = true;
      drawSimpleBar('delivery', $('chart-delivery'), state.deliveries.map(function (m) { return m.name; }), dCounts);
      drawSimpleBar('payment', $('chart-payment'), state.payments.map(function (m) { return m.name; }), pCounts);
    } else {
      destroyChart('delivery'); destroyChart('payment');
      $('methods-charts').hidden = true;
      $('methods-tables').hidden = false;
      $('table-delivery').innerHTML = methodsTableHtml(state.deliveries, dCounts, list.length);
      $('table-payment').innerHTML = methodsTableHtml(state.payments, pCounts, list.length);
    }
  }

  /* ---------- метрики времени между статусами (под воронкой и в CSV) ---------- */
  function computeTiming(list) {
    function statusId(code) {
      var s = state.statuses.filter(function (x) { return x.code === code; })[0];
      return s ? s.id : null;
    }
    function firstAt(orderId, code) {
      var sid = statusId(code);
      if (sid == null) return null;
      var rows = state.history.filter(function (h) { return h.order_id === orderId && h.status_id === sid; })
        .sort(function (a, b) { return new Date(a.changed_at) - new Date(b.changed_at); });
      return rows.length ? new Date(rows[0].changed_at).getTime() : null;
    }
    function diffs(fromCode, toCodes) {
      var out = [];
      list.forEach(function (o) {
        var f = firstAt(o.id, fromCode);
        if (f == null) return;
        var to = null;
        toCodes.forEach(function (c) {
          var t = firstAt(o.id, c);
          if (t != null && (to == null || t < to)) to = t;
        });
        if (to != null && to >= f) out.push(to - f);
      });
      return out;
    }
    function fmt(ms) {
      var min = Math.round(ms / 60000);
      if (min < 60) return min + ' мин';
      var h = Math.floor(min / 60), m = min % 60;
      if (h < 48) return h + ' ч' + (m ? ' ' + m + ' мин' : '');
      return Math.floor(h / 24) + ' д ' + (h % 24) + ' ч';
    }
    function stat(d) {
      if (!d.length) return { v: '—', n: 0 };
      return { v: fmt(d.reduce(function (s, x) { return s + x; }, 0) / d.length), n: d.length };
    }
    return [
      { label: 'Новый → Подтверждён', hint: 'среднее время реакции на заявку', st: stat(diffs('new', ['confirmed'])) },
      { label: 'Новый → Завершён', hint: 'до «Доставлен», «Отменён» или «Возврат»', st: stat(diffs('new', ['delivered', 'cancelled', 'returned'])) },
      { label: 'Новый → Отменён', hint: 'как быстро отменяют заказы', st: stat(diffs('new', ['cancelled'])) },
      { label: 'Доставлен → Возврат', hint: 'возвраты после завершения', st: stat(diffs('delivered', ['returned'])) }
    ];
  }
  function renderTiming(list) {
    $('funnel-metrics').innerHTML = computeTiming(list).map(function (m) {
      return '<li><span>' + m.label + '<span class="hint">' + m.hint + '</span></span>' +
        '<span class="val">' + m.st.v + (m.st.n ? ' · кол-во: ' + m.st.n : '') + '</span></li>';
    }).join('');
  }

  /* ---------- выгрузка статистики в CSV (все показатели периода) ---------- */
  function exportStatsCsv() {
    var list = periodOrders();
    var periodLabel = $('s-period').selectedOptions[0].textContent;
    var sum = list.reduce(function (s, o) { return s + o.total + o.delivery_cost; }, 0);
    var paidSum = list.filter(function (o) { return o.is_paid; })
      .reduce(function (s, o) { return s + o.total + o.delivery_cost; }, 0);
    var cancelled = list.filter(function (o) { return statusByid(o.status_id).code === 'cancelled'; }).length;
    var R = [];
    R.push(['Sisku — выгрузка статистики'], ['Период', periodLabel], ['Дата выгрузки', new Date().toLocaleString('ru-RU')], []);
    R.push(['1. Ключевые показатели'], ['Метрика', 'Значение'],
      ['Заказов', list.length],
      ['Сумма заявок, ₽', sum],
      ['Оплачено, ₽', paidSum],
      ['Средний чек, ₽', list.length ? Math.round(sum / list.length) : 0],
      ['Отменено', cancelled + (list.length ? ' (' + Math.round(cancelled / list.length * 100) + '%)' : '')], []);
    /* по дням — хронологически, ключ по локальной дате */
    var byDay = {};
    list.forEach(function (o) {
      var k = dayKey(o.created_at);
      byDay[k] = byDay[k] || { n: 0, sum: 0 };
      byDay[k].n += 1; byDay[k].sum += o.total + o.delivery_cost;
    });
    var keys = Object.keys(byDay).sort();
    R.push(['2. Заявки и суммы по дням'], ['Дата', 'Заказов', 'Сумма, ₽']);
    keys.forEach(function (k) { R.push([k, byDay[k].n, byDay[k].sum]); });
    R.push([]);
    R.push(['3. Воронка статусов'], ['Статус', 'Заказов']);
    state.statuses.forEach(function (s) {
      R.push([s.name, list.filter(function (o) { return o.status_id === s.id; }).length]);
    });
    R.push([]);
    R.push(['4. Топ товаров'], ['№', 'Товар', 'Кол-во', 'Сумма, ₽']);
    var ids = {};
    list.forEach(function (o) {
      itemsOf(o.id).forEach(function (i) {
        ids[i.title_snapshot] = ids[i.title_snapshot] || { n: 0, sum: 0 };
        ids[i.title_snapshot].n += i.quantity;
        ids[i.title_snapshot].sum += i.price * i.quantity;
      });
    });
    Object.keys(ids).map(function (k) { return { k: k, v: ids[k] }; })
      .sort(function (a, b) { return b.v.sum - a.v.sum; })
      .forEach(function (t, i) { R.push([i + 1, t.k, t.v.n, t.v.sum]); });
    R.push([]);
    function block(title, refs, field) {
      R.push([title], ['Способ', 'Заказов', 'Доля, %']);
      var counts = refs.map(function (m) { return list.filter(function (o) { return o[field] === m.id; }).length; });
      refs.forEach(function (m, i) {
        R.push([m.name, counts[i], list.length ? Math.round(counts[i] / list.length * 100) : 0]);
      });
      R.push([]);
    }
    block('5. Способы доставки', state.deliveries, 'delivery_method_id');
    block('6. Способы оплаты', state.payments, 'payment_method_id');
    R.push(['7. Время между статусами'], ['Метрика', 'Среднее', 'Кол-во']);
    computeTiming(list).forEach(function (m) { R.push([m.label, m.st.v, m.st.n]); });
    var csv = R.map(function (row) {
      return row.map(SiskuUtil.csvCell).join(';');   /* фикс F06: анти-формульный префикс */
    }).join('\r\n');
    var blob = new Blob(['\uFEFF' + csv], { type: 'text/csv;charset=utf-8' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'sisku-stats-' + $('s-period').value + '-' + dayKey(new Date()) + '.csv';   /* фикс F29 */
    a.click();
    URL.revokeObjectURL(a.href);
  }

  /* ---------- подвкладки статистики (v0.13.0) ---------- */
  var STATS_TABS = ['orders', 'promos', 'admins', 'clients', 'returns', 'writeoffs'];
  function switchStatsTab(tab) {
    if (STATS_TABS.indexOf(tab) === -1) tab = 'orders';
    state.statsTab = tab;
    $('stats-subseg').querySelectorAll('.seg-btn').forEach(function (b) {
      var on = b.getAttribute('data-stab') === tab;
      b.classList.toggle('active', on);
      b.setAttribute('aria-selected', on ? 'true' : 'false');
    });
    STATS_TABS.forEach(function (t) { $('stab-' + t).hidden = t !== tab; });
    /* v0.19.0 (fp №7): «Клиенты» — сегменты из draft_clients_bundle v3
       (ленивая загрузка — паттерн «Возвратов», грабля №6: один запрос) */
    if (tab === 'clients') {
      loadClientsStats(false).then(function () { renderClientsStats(); }).catch(function (e) {
        $('cst-loading').hidden = true;
        $('cst-error').textContent = 'Не удалось загрузить клиентов: ' + SiskuUtil.friendlyDbError(e);
        $('cst-error').hidden = false;
      });
      return;
    }
    /* v0.16.0: «Возвраты» — данные из отдельного бандла (ленивая загрузка) */
    if (tab === 'returns') {
      loadReturns(false).then(function () { renderReturnStats(); }).catch(function (e) {
        $('kpi-returns').innerHTML = '';
        $('reasons-empty').hidden = false;
        $('reasons-empty').textContent = 'Не удалось загрузить заявки: ' + (e.message || e);
      });
      return;
    }
    /* v0.20.0 (fp №9): «Списания» — данные из отдельного бандла (ленивая
       загрузка — паттерн «Возвратов», грабля №6: один запрос) */
    if (tab === 'writeoffs') {
      loadWriteoffs(false).then(function () { renderWriteoffStats(); }).catch(function (e) {
        $('wo-loading').hidden = true;
        $('wo-kpi').innerHTML = '';
        $('wo-error').textContent = 'Не удалось загрузить списания: ' + SiskuUtil.friendlyDbError(e);
        $('wo-error').hidden = false;
      });
      return;
    }
    renderStatsActive();
  }
  function renderStatsActive() {
    if (state.statsTab === 'orders') renderStats();
    else if (state.statsTab === 'promos') renderPromoStats();
    else if (state.statsTab === 'returns') renderReturnStats();
    else if (state.statsTab === 'writeoffs') { if (state.writeoffsLoaded) renderWriteoffStats(); }
    else if (state.statsTab === 'clients') { if (state.clientsStats) renderClientsStats(); }
    /* admins — заглушка, рендер не нужен */
  }

  /* ---------- подвкладка «Клиенты»: сегменты (v0.19.0, fp №7) ----------
     Данные — draft_clients_bundle v3 (скрипт 30): сегмент считает сервер
     (new/repeat/vip, приоритет VIP > repeat > new) + независимый признак
     is_dormant («уснувший VIP» виден в обоих фильтрах — решение Д2);
     пороги — site_content segments.* (модальное окно — Д4).
     Ленивая загрузка — паттерн «Возвратов» (грабля №6: один запрос). */
  var SEG_LABEL = { 'new': 'Новый', 'repeat': 'Повторный', 'vip': 'VIP' };

  function loadClientsStats(force) {
    if (state.clientsStats && !force) return Promise.resolve();
    if (!db) return Promise.reject({ message: dbError || 'нет БД' });
    $('cst-loading').hidden = false;
    $('cst-error').hidden = true;
    return db.rpc('draft_clients_bundle').then(function (res) {
      $('cst-loading').hidden = true;
      if (res.error) throw res.error;
      var d = res.data || {};
      var stats = {};
      (d.stats || []).forEach(function (s) { stats[s.client_id] = s; });
      var rows = (d.clients || []).map(function (c) {
        var st = stats[c.id] || {};
        c.orders = Number(st.orders || 0);
        c.sum = Number(st.sum || 0);
        c.paidSum = Number(st.paid_sum || 0);
        c.first = st.first_order || null;
        c.last = st.last_order || null;
        /* клиент без заказов (крайний случай, смоук S7): тракт как «новый» */
        c.segment = st.segment || 'new';
        c.dormant = !!st.is_dormant;
        return c;
      });
      state.clientsStats = { rows: rows, thresholds: d.thresholds || {} };
    });
  }

  function cstFiltered() {
    var f = state.cstFilter;
    var list = state.clientsStats.rows.filter(function (c) {
      if (!f) return true;
      return f === 'dormant' ? c.dormant : c.segment === f;
    });
    var s = state.cstSort, dir = s.dir === 'asc' ? 1 : -1;
    list.sort(function (a, b) {
      function ts(x) { return x ? new Date(x).getTime() : 0; }
      if (s.field === 'name') return a.full_name.localeCompare(b.full_name, 'ru') * dir;
      if (s.field === 'count') return (a.orders - b.orders) * dir;
      if (s.field === 'sum') return (a.sum - b.sum) * dir;
      if (s.field === 'first') return (ts(a.first) - ts(b.first)) * dir;
      return (ts(a.last) - ts(b.last)) * dir;   /* 'last' — давность */
    });
    return list;
  }

  function renderClientsStats() {
    if (!state.clientsStats) return;
    var rows = state.clientsStats.rows;
    var th = state.clientsStats.thresholds;
    /* KPI — один проход (Д3): счётчики сегментов, доля выручки VIP, LTV, средний чек */
    var nNew = 0, nRep = 0, nVip = 0, nDor = 0, sumAll = 0, ordAll = 0, sumVip = 0;
    rows.forEach(function (c) {
      if (c.segment === 'vip') { nVip += 1; sumVip += c.sum; }
      else if (c.segment === 'repeat') nRep += 1;
      else nNew += 1;
      if (c.dormant) nDor += 1;
      sumAll += c.sum; ordAll += c.orders;
    });
    $('cst-kpi').innerHTML =
      kpi('Клиентов', rows.length, 'всего в базе') +
      kpi('Новые', nNew, 'один заказ') +
      kpi('Повторные', nRep, 'два и более заказа') +
      kpi('VIP', nVip, 'заказов ≥ ' + (th.vip_orders_min != null ? th.vip_orders_min : 5) +
        ' или сумма ≥ ' + SiskuUtil.fmtNum(th.vip_sum_min != null ? th.vip_sum_min : 100000) + ' ₽') +
      kpi('Уснули', nDor, 'без заказов ' + (th.dormant_days != null ? th.dormant_days : 90) + '+ дней') +
      kpi('Доля выручки VIP', sumAll ? Math.round(sumVip / sumAll * 100) + '%' : '0%', 'от суммы всех заказов') +
      kpi('LTV', money(rows.length ? sumAll / rows.length : 0), 'средняя сумма на клиента') +
      kpi('Средний чек', money(ordAll ? sumAll / ordAll : 0), 'сумма заказов / число заказов');
    $('cst-filters').querySelectorAll('.seg-btn').forEach(function (b) {
      b.classList.toggle('active', b.getAttribute('data-seg') === state.cstFilter);
    });
    var list = cstFiltered();
    var PAGESIZE = 30;                                 /* пагинация: 30 на страницу (паттерн проекта) */
    var pages = Math.max(1, Math.ceil(list.length / PAGESIZE));
    if (state.cstPage > pages) state.cstPage = pages;
    if (state.cstPage < 1) state.cstPage = 1;
    var visible = list.slice((state.cstPage - 1) * PAGESIZE, state.cstPage * PAGESIZE);
    if (rows.length === 0) {
      $('cst-empty').hidden = false;
      $('cst-empty').textContent = 'Клиентов пока нет. Оформите тестовый заказ на витрине — клиенты появятся здесь автоматически.';
    } else if (list.length === 0) {
      $('cst-empty').hidden = false;
      $('cst-empty').textContent = 'В этом сегменте клиентов нет — измените фильтр.';
    } else {
      $('cst-empty').hidden = true;
    }
    $('cst-body').innerHTML = visible.map(function (c) {
      /* Д5: контакты маскируются; после «глазика» — tel:/mailto: только для
         валидных (паттерн users.js v0.15.0/v0.16.0), невалидные — текст */
      var revealed = state.cstRevealed[c.id];
      var phone = revealed
        ? (c.phone
            ? (SiskuUtil.phoneOk(c.phone)
                ? '<a class="tel-link" href="tel:' + esc(String(c.phone).replace(/[^\d+]/g, '')) + '">' + esc(c.phone) + '</a>'
                : esc(c.phone))
            : '—')
        : esc(maskPhone(c.phone));
      var email = revealed
        ? (c.email
            ? (SiskuUtil.emailOk(c.email)
                ? '<a class="mail-link" href="mailto:' + esc(c.email) + '">' + esc(c.email) + '</a>'
                : esc(c.email))
            : '—')
        : esc(maskEmail(c.email));
      return '<tr>' +
        '<td class="user-fio">' + esc(c.full_name) + '</td>' +
        '<td><span class="seg-pill" data-seg="' + esc(c.segment) + '">' + esc(SEG_LABEL[c.segment] || c.segment) + '</span>' +
          (c.dormant ? '<span class="dormant-mark" title="Без заказов ' + (th.dormant_days != null ? th.dormant_days : 90) + '+ дней">уснул</span>' : '') +
        '</td>' +
        '<td class="tabular muted masked">' + phone +
          '<button class="eye" data-cst-eye="' + c.id + '" title="Показать или скрыть контакты">' + (revealed ? 'скрыть' : 'показать') + '</button>' +
        '</td>' +
        '<td class="muted">' + email + '</td>' +
        '<td class="tabular">' + c.orders + '</td>' +
        '<td class="tabular">' + money(c.sum) + '</td>' +
        '<td class="tabular">' + money(c.paidSum) + '</td>' +
        '<td class="tabular muted">' + fmtDate(c.first) + '</td>' +
        '<td class="tabular muted">' + fmtDate(c.last) + '</td>' +
      '</tr>';
    }).join('');
    document.querySelectorAll('#stab-clients th.sortable').forEach(function (t) {
      var active = t.getAttribute('data-cst-sort') === state.cstSort.field;
      t.classList.toggle('active', active);
      t.querySelector('.sort-ic').textContent = active ? (state.cstSort.dir === 'asc' ? '▲' : '▼') : '↕';
    });
    var pager = $('cst-pager');
    if (pages > 1) {
      pager.hidden = false;
      $('cst-pg-info').textContent = 'Стр. ' + state.cstPage + ' из ' + pages +
        ' (показано ' + ((state.cstPage - 1) * PAGESIZE + 1) + '–' +
        Math.min(list.length, state.cstPage * PAGESIZE) + ' из ' + list.length + ')';
      $('cst-pg-prev').disabled = state.cstPage <= 1;
      $('cst-pg-next').disabled = state.cstPage >= pages;
    } else {
      pager.hidden = true;
    }
  }

  function exportCstCsv() {
    if (!state.clientsStats) return;
    var list = cstFiltered();                          /* выгрузка текущего сегмента — «для рассылок» (fp №7) */
    var head = ['ФИО', 'Сегмент', 'Уснул', 'Телефон', 'E-mail', 'Заказов', 'Сумма заказов, ₽', 'Оплачено, ₽', 'Первый заказ', 'Последний заказ', 'Комментарий'];
    var lines = [head.join(';')];
    list.forEach(function (c) {
      var row = [
        c.full_name, SEG_LABEL[c.segment] || c.segment, c.dormant ? 'да' : 'нет',
        c.phone || '', c.email || '', c.orders, Math.round(c.sum), Math.round(c.paidSum),
        fmtDate(c.first), fmtDate(c.last),
        (c.note || '').replace(/;/g, ',').replace(/\n/g, ' ')
      ];
      lines.push(row.map(SiskuUtil.csvCell).join(';'));   /* фикс F06 (v0.14.0): анти-формульный префикс */
    });
    var blob = new Blob(['\uFEFF' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'sisku-clients-segments-' + dayKey(new Date()) + '.csv';   /* фикс F29: локальная дата */
    a.click();
    URL.revokeObjectURL(a.href);
  }

  /* Пороги VIP/«уснувших» — модальное окно (Д4): значения — site_content
     segments.*, сохранение — три последовательных точечных update (паттерн
     sitecontent.js; блокировка повторной отправки), затем бандл force */
  function openThresholds() {
    if (!state.clientsStats) return;
    var th = state.clientsStats.thresholds;
    $('cstm-vip-orders').value = th.vip_orders_min != null ? th.vip_orders_min : 5;
    $('cstm-vip-sum').value = th.vip_sum_min != null ? th.vip_sum_min : 100000;
    $('cstm-days').value = th.dormant_days != null ? th.dormant_days : 90;
    $('cstm-error').hidden = true;
    $('cstm-backdrop').classList.add('open');
  }
  function thError(msg) { $('cstm-error').textContent = msg; $('cstm-error').hidden = false; }
  function saveThresholds(e) {
    e.preventDefault();
    if (state.cstSaving) return;                       /* защита от повторных кликов */
    var vo = parseInt($('cstm-vip-orders').value, 10);
    var vs = parseInt($('cstm-vip-sum').value, 10);
    var vd = parseInt($('cstm-days').value, 10);
    if (!(vo >= 1)) { thError('VIP (заказов): целое число не менее 1'); return; }
    if (!(vs >= 0)) { thError('VIP (сумма): число не менее 0'); return; }
    if (!(vd >= 1)) { thError('«Уснул» (дней): целое число не менее 1'); return; }
    state.cstSaving = true;
    $('cstm-save').disabled = true;
    var vals = [
      { key: 'segments.vip_orders_min', v: vo },
      { key: 'segments.vip_sum_min', v: vs },
      { key: 'segments.dormant_days', v: vd }
    ];
    var chain = Promise.resolve();
    vals.forEach(function (it) {
      chain = chain.then(function () {
        return db.from('site_content')
          .update({ value: String(it.v), updated_at: new Date().toISOString() })
          .eq('key', it.key)
          .then(function (res) { if (res.error) throw res.error; });
      });
    });
    chain.then(function () {
      $('cstm-backdrop').classList.remove('open');
      return loadClientsStats(true);                   /* пороги применились — пересчёт сегментов */
    }).then(function () {
      renderClientsStats();
    }).catch(function (err) {
      thError(SiskuUtil.friendlyDbError(err));
    }).then(function () {
      state.cstSaving = false;
      $('cstm-save').disabled = false;
    });
  }

  /* ---------- подвкладка «Акции»: статистика промокодов (v0.13.0) ---------- */
  function promoPeriodOrders() { return ordersInPeriod($('p-period')); }
  function discountLabel(p) {
    if (!p) return '—';
    return p.discount_type === 'percent'
      ? '−' + Number(p.discount_value) + '%'
      : '−' + money(p.discount_value);
  }
  function promoStateOf(p) {
    /* t — полное название (CSV, метрики), s — короткое слово для пилюли (правка 2.13) */
    var now = new Date();
    if (!p.is_active) return { t: 'отключён', s: 'отключён', c: 'cancelled' };
    if (p.valid_until && new Date(p.valid_until + 'T23:59:59') < now) return { t: 'истёк', s: 'истёк', c: 'cancelled' };
    if (p.usage_limit != null && Number(p.used_count) >= Number(p.usage_limit)) return { t: 'лимит исчерпан', s: 'лимит', c: 'returned' };
    if (p.valid_from && new Date(p.valid_from + 'T00:00:00') > now) return { t: 'ещё не начался', s: 'не начался', c: 'new' };
    return { t: 'активен', s: 'активен', c: 'delivered' };
  }
  function promoAggregates(list) {
    var withP = list.filter(function (o) { return o.promo_code_id != null; });
    var without = list.filter(function (o) { return o.promo_code_id == null; });
    function sum(arr, f) { return arr.reduce(function (s, o) { return s + f(o); }, 0); }
    return {
      all: list, withP: withP, without: without,
      discSum: sum(withP, function (o) { return Number(o.promo_discount || 0); }),
      sumWith: sum(withP, function (o) { return o.total + o.delivery_cost; }),
      sumWithout: sum(without, function (o) { return o.total + o.delivery_cost; })
    };
  }
  function renderPromoStats() {
    var agg = promoAggregates(promoPeriodOrders());
    var avgWith = agg.withP.length ? agg.sumWith / agg.withP.length : 0;
    var avgWithout = agg.without.length ? agg.sumWithout / agg.without.length : 0;
    $('kpi-promos').innerHTML =
      kpi('Заказов с кодом', agg.withP.length, 'из ' + agg.all.length + ' за период') +
      kpi('Доля кодов', agg.all.length ? Math.round(agg.withP.length / agg.all.length * 100) + '%' : '0%', 'заявок оформлено с промокодом') +
      kpi('Сумма скидок', money(agg.discSum), 'фактические скидки промокодов') +
      kpi('Средняя скидка', money(agg.withP.length ? agg.discSum / agg.withP.length : 0), 'на заказ с кодом') +
      kpi('Средний чек с кодом', money(avgWith), 'без кода: ' + money(avgWithout));
    drawPromoDays(agg.withP);
    renderPromoCodes(agg.withP);
    renderPromoSplit(agg, avgWith, avgWithout);
  }
  function drawPromoDays(withP) {
    chartDefaults(); destroyChart('promoDays');
    $('promo-days-empty').hidden = withP.length !== 0;
    $('chart-promo-days').style.display = withP.length ? '' : 'none';
    if (!withP.length) return;
    var byDay = {};
    withP.forEach(function (o) {
      var k = dayKey(o.created_at);          /* локальная дата — без UTC-фантомов (фикс v0.7.0) */
      byDay[k] = byDay[k] || { n: 0, disc: 0 };
      byDay[k].n += 1;
      byDay[k].disc += Number(o.promo_discount || 0);
    });
    var keys = Object.keys(byDay).sort();    /* хронология: старые слева */
    var labels = keys.map(function (k) { var p = k.split('-'); return p[2] + '.' + p[1]; });
    state.charts.promoDays = new Chart($('chart-promo-days'), {
      type: 'line',
      data: {
        labels: labels,
        datasets: [
          { label: 'Заказы с кодом', data: keys.map(function (k) { return byDay[k].n; }), borderColor: GOLD, backgroundColor: SiskuUtil.hexToRgba(GOLD, .15), fill: true, tension: .35, yAxisID: 'y' },
          { label: 'Скидки, ₽', data: keys.map(function (k) { return byDay[k].disc; }), borderColor: MUTED, borderDash: [5, 4], tension: .35, yAxisID: 'y1' }
        ]
      },
      options: {
        responsive: true,
        interaction: { mode: 'index', intersect: false },
        scales: {
          y: { ticks: { precision: 0 }, grid: { color: LINE } },
          y1: { position: 'right', grid: { display: false }, ticks: { callback: function (v) { return SiskuUtil.fmtNum(v); } } }
        },
        plugins: { legend: { labels: { color: MUTED, boxWidth: 14 } } }
      }
    });
  }
  function metricRow(label, val) {
    return '<li><span>' + label + '</span><span class="val">' + val + '</span></li>';
  }
  function promoCodeRows(withP) {
    return state.promos.map(function (p) {
      var used = withP.filter(function (o) { return o.promo_code_id === p.id; });
      return {
        p: p,
        n: used.length,
        disc: used.reduce(function (s, o) { return s + Number(o.promo_discount || 0); }, 0)
      };
    }).sort(function (a, b) { return (b.n - a.n) || (b.disc - a.disc); });
  }
  function renderPromoCodes(withP) {
    var rows = promoCodeRows(withP);
    var now = new Date();
    var active = state.promos.filter(function (p) { return promoStateOf(p).t === 'активен'; }).length;
    var expired = state.promos.filter(function (p) { return p.valid_until && new Date(p.valid_until + 'T23:59:59') < now; }).length;
    var exhausted = state.promos.filter(function (p) { return p.usage_limit != null && Number(p.used_count) >= Number(p.usage_limit); }).length;
    $('promo-metrics').innerHTML =
      metricRow('Всего кодов', state.promos.length) +
      metricRow('Действуют сейчас', active) +
      metricRow('С истёкшим сроком', expired) +
      metricRow('С исчерпанным лимитом', exhausted);

    if (state.promoMode === 'table') {
      destroyChart('promoCodes');
      $('promocodes-chart').hidden = true;
      $('promocodes-table').hidden = false;
      /* правка 2.13 (v0.15.0): короткие заголовки («Заказов», «Скидки, ₽»),
         «Использовано» объединено с кодом (n/лимит), статус — короткое слово;
         колонка «Скидки, ₽» прячется на узких экранах (.col-promo-disc) */
      $('table-promo-codes').innerHTML =
        '<thead><tr><th>Код</th><th style="text-align:right">Скидка</th>' +
        '<th style="text-align:right">Заказов</th><th class="col-promo-disc" style="text-align:right">Скидки, ₽</th>' +
        '<th>Статус</th></tr></thead><tbody>' +
        (rows.length
          ? rows.map(function (r) {
              var st = promoStateOf(r.p);
              var used = r.p.used_count + (r.p.usage_limit != null ? '/' + r.p.usage_limit : ', без лимита');
              return '<tr><td><b>' + esc(r.p.code) + '</b>' +
                '<div class="muted" style="font-size:11.5px">использовано: ' + used + '</div></td>' +
                '<td class="num">' + discountLabel(r.p) + '</td>' +
                '<td class="num">' + r.n + '</td>' +
                '<td class="num col-promo-disc">' + money(r.disc) + '</td>' +
                '<td><span class="status-pill" data-code="' + st.c + '">' + st.s + '</span></td></tr>';
            }).join('')
          : '<tr><td colspan="5" class="muted">Промокодов пока нет — создайте в «Управление → Промокоды»</td></tr>') +
        '</tbody>';
      return;
    }
    $('promocodes-chart').hidden = false;
    $('promocodes-table').hidden = true;
    chartDefaults(); destroyChart('promoCodes');
    if (!rows.length) return;
    state.charts.promoCodes = new Chart($('chart-promo-codes'), {
      type: 'bar',
      data: {
        labels: rows.map(function (r) { return r.p.code; }),
        datasets: [{ data: rows.map(function (r) { return r.n; }), backgroundColor: GOLD, borderRadius: 2, barThickness: 12 }]
      },
      options: {
        indexAxis: 'y', responsive: true,
        scales: { x: { ticks: { precision: 0 }, grid: { color: LINE } }, y: { grid: { display: false } } },
        plugins: { legend: { display: false } }
      }
    });
  }
  function renderPromoSplit(agg, avgWith, avgWithout) {
    var n = agg.all.length;
    function paidSum(arr) {
      return arr.filter(function (o) { return o.is_paid; })
        .reduce(function (s, o) { return s + o.total + o.delivery_cost; }, 0);
    }
    function row(label, withV, withoutV) {
      return '<tr><td>' + label + '</td><td class="num">' + withV + '</td><td class="num">' + withoutV + '</td></tr>';
    }
    $('table-promo-split').innerHTML =
      '<thead><tr><th>Показатель</th>' +
      '<th style="text-align:right">Заказы с кодом (' + agg.withP.length + ')</th>' +
      '<th style="text-align:right">Заказы без кода (' + agg.without.length + ')</th></tr></thead><tbody>' +
      row('Доля заказов периода', n ? Math.round(agg.withP.length / n * 100) + '%' : '0%', n ? Math.round(agg.without.length / n * 100) + '%' : '0%') +
      row('Сумма заявок', money(agg.sumWith), money(agg.sumWithout)) +
      row('Средний чек', money(avgWith), money(avgWithout)) +
      row('Оплачено', money(paidSum(agg.withP)), money(paidSum(agg.without))) +
      '</tbody>';
  }

  /* ---------- выгрузка статистики акций в CSV (v0.13.0) ---------- */
  function exportPromosCsv() {
    var agg = promoAggregates(promoPeriodOrders());
    var periodLabel = $('p-period').selectedOptions[0].textContent;
    var R = [];
    R.push(['Sisku — выгрузка статистики акций'], ['Период', periodLabel], ['Дата выгрузки', new Date().toLocaleString('ru-RU')], []);
    R.push(['1. Ключевые показатели'], ['Метрика', 'Значение'],
      ['Заказов за период', agg.all.length],
      ['Заказов с промокодом', agg.withP.length],
      ['Доля заказов с кодом, %', agg.all.length ? Math.round(agg.withP.length / agg.all.length * 100) : 0],
      ['Сумма скидок, ₽', agg.discSum],
      ['Средняя скидка, ₽', agg.withP.length ? Math.round(agg.discSum / agg.withP.length) : 0],
      ['Средний чек с кодом, ₽', agg.withP.length ? Math.round(agg.sumWith / agg.withP.length) : 0],
      ['Средний чек без кода, ₽', agg.without.length ? Math.round(agg.sumWithout / agg.without.length) : 0], []);
    var byDay = {};
    agg.withP.forEach(function (o) {
      var k = dayKey(o.created_at);
      byDay[k] = byDay[k] || { n: 0, disc: 0 };
      byDay[k].n += 1; byDay[k].disc += Number(o.promo_discount || 0);
    });
    R.push(['2. Использование кодов по дням'], ['Дата', 'Заказов', 'Скидки, ₽']);
    Object.keys(byDay).sort().forEach(function (k) { R.push([k, byDay[k].n, byDay[k].disc]); });
    R.push([]);
    R.push(['3. По кодам'], ['Код', 'Скидка', 'Заказов за период', 'Скидки за период, ₽', 'Использовано всего', 'Лимит', 'Статус']);
    promoCodeRows(agg.withP).forEach(function (r) {
      R.push([r.p.code, discountLabel(r.p), r.n, r.disc, r.p.used_count,
        r.p.usage_limit == null ? 'нет' : r.p.usage_limit, promoStateOf(r.p).t]);
    });
    var csv = R.map(function (row) {
      return row.map(SiskuUtil.csvCell).join(';');   /* фикс F06: анти-формульный префикс */
    }).join('\r\n');
    var blob = new Blob(['\uFEFF' + csv], { type: 'text/csv;charset=utf-8' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'sisku-promo-stats-' + $('p-period').value + '-' + dayKey(new Date()) + '.csv';   /* фикс F29 */
    a.click();
    URL.revokeObjectURL(a.href);
  }

  /* ---------- v0.16.0 (fp №3): возвраты — очередь, карточка, статистика ----------
     Данные — draft_returns_bundle() одним RPC (грабля №4: очередь соединений
     бесплатного тарифа); заказы и статусы — уже в state из draft_admin_bundle.
     Подписи статусов — из ключей site_content returns.status.* (бандл),
     запасные значения — в коде (правило: изменяемые тексты не хардкодить). */
  var RETURN_STATUSES = ['created', 'returned_to_stock', 'verified', 'rejected'];
  var RETURN_FALLBACK = {
    created: 'Заявка оформлена',
    returned_to_stock: 'Товар вернулся на склад',
    verified: 'Товар проверен, возврат оформлен',
    rejected: 'Отклонено'
  };
  var RETURN_NEXT = {
    created: ['returned_to_stock', 'rejected'],
    returned_to_stock: ['verified', 'rejected'],
    verified: [], rejected: []
  };
  var RETURN_ACTION = {
    returned_to_stock: 'Товар вернулся на склад',
    verified: 'Товар проверен, возврат оформлен',
    rejected: 'Отклонить заявку'
  };
  function returnStatusLabel(code) {
    return state.returns.content['returns.status.' + code] || RETURN_FALLBACK[code] || code;
  }
  function returnPill(code) {
    return '<span class="status-pill" data-code="rr_' + esc(code) + '">' + esc(returnStatusLabel(code)) + '</span>';
  }
  function reasonById(id) {
    return state.returns.reasons.filter(function (r) { return r.id === id; })[0] || {};
  }
  function orderById(id) {
    return state.orders.filter(function (o) { return o.id === id; })[0] || null;
  }

  function loadReturns(force) {
    if (state.returnsLoaded && !force) return Promise.resolve();
    if (!db) return Promise.reject({ message: dbError || 'нет БД' });
    $('rr-loading').hidden = false;
    return db.rpc('draft_returns_bundle').then(function (res) {
      $('rr-loading').hidden = true;
      if (res.error) throw res.error;
      var d = res.data || {};
      state.returns.requests = d.requests || [];
      state.returns.reasons = d.reasons || [];
      state.returns.content = {};
      (d.content || []).forEach(function (c) { state.returns.content[c.key] = c.value; });
      state.returnsLoaded = true;
      buildRrFilter();
      var title = state.returns.content['returns.stats.title'];
      if (title && $('stab-returns-btn')) $('stab-returns-btn').textContent = title;
    });
  }
  function buildRrFilter() {
    var keep = $('rr-filter').value;
    $('rr-filter').innerHTML = '<option value="">Все статусы</option>' +
      RETURN_STATUSES.map(function (c) {
        return '<option value="' + c + '">' + esc(returnStatusLabel(c)) + '</option>';
      }).join('');
    $('rr-filter').value = RETURN_STATUSES.indexOf(keep) !== -1 ? keep : '';
    $('rr-filter').dispatchEvent(new Event('refresh'));
    if (window.enhanceSelects) enhanceSelects();
  }
  function filteredReturns() {
    var list = state.returns.requests.slice();
    if (state.rrFilter) list = list.filter(function (r) { return r.status === state.rrFilter; });
    list.sort(function (a, b) { return new Date(b.created_at) - new Date(a.created_at); });
    return list;
  }
  function renderReturns() {
    if (!state.returnsLoaded) return;
    var list = filteredReturns();
    var PAGESIZE = 30;
    var pages = Math.max(1, Math.ceil(list.length / PAGESIZE));
    if (state.rrPage > pages) state.rrPage = pages;
    if (state.rrPage < 1) state.rrPage = 1;
    var visible = list.slice((state.rrPage - 1) * PAGESIZE, state.rrPage * PAGESIZE);
    $('rr-loading').hidden = true;
    $('rr-error').hidden = true;
    $('rr-empty').hidden = list.length !== 0;
    $('rr-empty').textContent = state.returns.requests.length
      ? 'Ничего не найдено по фильтру — выберите другой статус.'
      : 'Заявок на возврат пока нет. Форма заявки — на витрине, в окне отслеживания заказа (статусы «Отправлен» и «Доставлен»).';
    $('rr-body').innerHTML = visible.map(function (r) {
      var o = orderById(r.order_id);
      var cm = r.comment ? (r.comment.length > 60 ? r.comment.slice(0, 60) + '…' : r.comment) : '—';
      return '<tr data-rid="' + r.id + '">' +
        '<td class="tabular"><b>№ ' + r.id + '</b></td>' +
        '<td class="tabular muted">' + fmtDate(r.created_at) + '</td>' +
        '<td class="tabular">№ ' + r.order_id + '</td>' +
        '<td>' + esc(o ? o.customer_name : '—') + '</td>' +
        '<td>' + esc(reasonById(r.reason_id).name || '—') + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(cm) + '</td>' +
        '<td>' + returnPill(r.status) +
          (r.refund_paid ? ' <span class="paid-mark">деньги возвращены</span>' : '') + '</td>' +
      '</tr>';
    }).join('');
    var pager = $('rr-pager');
    if (pages > 1) {
      pager.hidden = false;
      $('rr-info').textContent = 'Стр. ' + state.rrPage + ' из ' + pages +
        ' (показано ' + ((state.rrPage - 1) * PAGESIZE + 1) + '–' +
        Math.min(list.length, state.rrPage * PAGESIZE) + ' из ' + list.length + ')';
      $('rr-prev').disabled = state.rrPage <= 1;
      $('rr-next').disabled = state.rrPage >= pages;
    } else {
      pager.hidden = true;
    }
  }

  function openReturnRequest(id) {
    var r = state.returns.requests.filter(function (x) { return x.id === id; })[0];
    if (!r) return;
    var o = orderById(r.order_id);
    var reason = reasonById(r.reason_id);
    var next = RETURN_NEXT[r.status] || [];
    var inputStyle = 'width:100%;min-height:42px;padding:9px 12px;background:var(--card);color:var(--text);border:1px solid var(--line);border-radius:3px;font-family:var(--font-body);font-size:14px';
    $('ret-modal-body').innerHTML =
      '<div class="modal-head-row"><h2>Заявка на возврат № ' + r.id + '</h2>' + returnPill(r.status) + '</div>' +
      '<div class="muted" style="font-size:12.5px;margin-top:2px">создана ' + fmtDate(r.created_at) +
        ' · ' + esc(r.created_by === 'site' ? 'покупателем с сайта' : (r.created_by || '—')) +
        (r.resolved_at ? ' · завершена ' + fmtDate(r.resolved_at) : '') +
        (r.handled_by ? ' · обработал ' + esc(r.handled_by) : '') + '</div>' +
      '<div class="order-meta">' +
        '<div>' +
          metaRow('Заказ', o
            ? '<button class="linklike" id="ret-to-order" style="font:inherit;font-size:14px">№ ' + o.id + ' от ' + fmtDate(o.created_at) + '</button>'
            : '№ ' + r.order_id) +
          metaRow('Клиент', esc(o ? o.customer_name : '—')) +
          metaRow('Сумма заказа', o ? '<b class="tabular">' + money(o.total + o.delivery_cost) + '</b>' : '—') +
          metaRow('Статус заказа', o ? esc(statusByid(o.status_id).name || '—') : '—') +
        '</div>' +
        '<div>' +
          metaRow('Причина', esc(reason.name || '—')) +
          metaRow('Комментарий', r.comment ? esc(r.comment) : '—') +
          metaRow('Фото', '<span class="muted">не загружено — заглушка до подключения хранилища (M5)</span>') +
          metaRow('Деньги', r.refund_paid
            ? '<b style="color:var(--ok)">возвращены' + (r.refund_paid_at ? ' ' + fmtDate(r.refund_paid_at) : '') + '</b>'
            : 'не возвращены') +
        '</div>' +
      '</div>' +
      (r.status === 'returned_to_stock' || r.status === 'verified'
        ? '<div class="locked-note">Товар по заявке — в карантине «требует осмотра»: остаток не продаётся. Осмотр — в карточке товара («Магазин → Товары»): «вернуть в продажу» или «списать» (скрипт 23).</div>'
        : '') +
      (next.length
        ? '<div class="subhead">Обработка заявки</div>' +
          '<div class="actions-row">' +
          next.map(function (c) {
            return '<button class="btn' + (c === 'rejected' ? '' : ' primary') + '" data-rst="' + c + '"' +
              (c === 'returned_to_stock' ? ' title="Заказ будет переведён в статус «Возврат», остатки уйдут в карантин"' : '') + '>' +
              esc(RETURN_ACTION[c]) + '</button>';
          }).join('') +
          '</div>'
        : '') +
      '<div class="subhead">Деньги возвращены</div>' +
      '<label style="display:flex;align-items:center;gap:10px;font-size:14px">' +
        '<input type="checkbox" id="ret-refund" style="width:18px;height:18px;accent-color:var(--accent)"' + (r.refund_paid ? ' checked' : '') + '> ' +
        'Возврат денег подтверждён' + (r.refund_paid_at ? ' <span class="muted">(' + fmtDate(r.refund_paid_at) + ')</span>' : '') +
      '</label>' +
      '<div style="margin-top:10px">' +
        '<label for="ret-receipt" style="display:block;font-size:12px;letter-spacing:.14em;text-transform:uppercase;color:var(--muted);margin-bottom:7px">Реквизиты чека возврата (в макете необязательные)</label>' +
        '<input id="ret-receipt" value="' + esc(r.refund_receipt || '') + '" placeholder="Например: чек возврата от дд.мм.гггг, сумма" style="' + inputStyle + '">' +
      '</div>' +
      '<div class="actions-row" style="margin-top:12px"><button class="btn" id="ret-refund-save">Сохранить деньги/чек</button></div>' +
      '<div class="err-box" id="ret-error" hidden></div>';

    var toOrder = $('ret-to-order');
    if (toOrder) toOrder.addEventListener('click', function () {
      $('ret-modal-backdrop').classList.remove('open');
      openOrder(r.order_id, { kind: 'return', id: r.id });   /* обратная навигация: заказ → «← К заявке» */
    });
    $('ret-modal-body').querySelectorAll('button[data-rst]').forEach(function (b) {
      b.addEventListener('click', function () {
        var code = b.getAttribute('data-rst');
        if (code === 'rejected' && !confirm('Отклонить заявку № ' + r.id + '?')) return;
        b.disabled = true;
        db.rpc('admin_set_return_status', {
          p_request_id: r.id, p_status_code: code, p_comment: null, p_changed_by: 'draft-admin'
        }).then(function (res) {
          if (res.error) {
            $('ret-error').textContent = SiskuUtil.friendlyDbError(res.error);
            $('ret-error').hidden = false;
            b.disabled = false;
            return;
          }
          /* при «Товар вернулся на склад» заказ переведён в «Возврат»,
             остатки — в карантине: обновляем оба бандла и перерисовываем
             (v0.17.0, находка B2 — здесь полная перезагрузка ОПРАВДАНА:
             переход заявки меняет заказ, остатки и карантин одновременно) */
          Promise.all([loadAll(), loadReturns(true)]).then(function () {
            renderReturns();
            openReturnRequest(r.id);
          });
        }).catch(function (e) {
          $('ret-error').textContent = 'Ошибка сети: ' + e.message;
          $('ret-error').hidden = false;
          b.disabled = false;
        });
      });
    });
    $('ret-refund-save').addEventListener('click', function () {
      var self = this;
      self.disabled = true;
      db.rpc('admin_set_return_refund', {
        p_request_id: r.id, p_paid: $('ret-refund').checked,
        p_receipt: $('ret-receipt').value.trim() || null, p_changed_by: 'draft-admin'
      }).then(function (res) {
        if (res.error) {
          $('ret-error').textContent = SiskuUtil.friendlyDbError(res.error);
          $('ret-error').hidden = false;
          self.disabled = false;
          return;
        }
        loadReturns(true).then(function () { renderReturns(); openReturnRequest(r.id); });
      }).catch(function (e) {
        $('ret-error').textContent = 'Ошибка сети: ' + e.message;
        $('ret-error').hidden = false;
        self.disabled = false;
      });
    });

    $('ret-modal-backdrop').classList.add('open');
  }

  /* ---------- статистика «Возвраты» (v0.16.0) ---------- */
  function returnsInPeriod() {
    var days = $('r-period').value;
    var list = state.returns.requests.slice();
    if (days !== 'all') {
      var from = Date.now() - Number(days) * 864e5;
      list = list.filter(function (r) { return new Date(r.created_at).getTime() >= from; });
    }
    return list;
  }
  function returnAggregates(list) {
    var verified = list.filter(function (r) { return r.status === 'verified'; });
    var rejected = list.filter(function (r) { return r.status === 'rejected'; });
    var sum = verified.reduce(function (s, r) {
      var o = orderById(r.order_id);
      return s + (o ? o.total + o.delivery_cost : 0);
    }, 0);
    var paidN = verified.filter(function (r) { return r.refund_paid; }).length;
    var resolved = list.filter(function (r) { return r.resolved_at; });
    var avgDays = resolved.length
      ? resolved.reduce(function (s, r) { return s + (new Date(r.resolved_at) - new Date(r.created_at)); }, 0) / resolved.length / 864e5
      : 0;
    return { verified: verified, rejected: rejected, sum: sum, paidN: paidN, avgDays: avgDays };
  }
  function renderReturnStats() {
    if (!state.returnsLoaded) return;
    var list = returnsInPeriod();
    var agg = returnAggregates(list);
    $('kpi-returns').innerHTML =
      kpi('Заявок', list.length, 'за выбранный период') +
      kpi('Возвратов оформлено', agg.verified.length, 'товар проверен, возврат оформлен') +
      kpi('Отклонено', agg.rejected.length, 'заявок отклонено') +
      kpi('Сумма возвратов', money(agg.sum), agg.paidN + ' с отметкой «деньги возвращены»') +
      kpi('Средний срок', agg.avgDays ? agg.avgDays.toFixed(1) + ' дн.' : '—', 'от заявки до завершения');
    drawReasons(list);
    drawReturnDays(list);
  }
  function reasonRows(list) {
    var counts = {};
    list.forEach(function (r) { counts[r.reason_id] = (counts[r.reason_id] || 0) + 1; });
    var known = {};
    var rows = state.returns.reasons.map(function (rr) {
      known[rr.id] = true;
      return { name: rr.name, n: counts[rr.id] || 0 };
    });
    Object.keys(counts).forEach(function (rid) {
      if (!known[rid]) rows.push({ name: 'Причина №' + rid + ' (вне справочника)', n: counts[rid] });
    });
    rows.sort(function (a, b) { return b.n - a.n; });
    return rows;
  }
  function drawReasons(list) {
    var rows = reasonRows(list);
    $('reasons-empty').hidden = list.length !== 0;
    if (state.returnMode !== 'chart') {
      destroyChart('reasons');
      $('reasons-chart').hidden = true;
      $('reasons-table').hidden = false;
      $('table-reasons').innerHTML =
        '<thead><tr><th>Причина</th><th style="text-align:right">Заявок</th><th style="text-align:right">Доля, %</th></tr></thead><tbody>' +
        (rows.length
          ? rows.map(function (r) {
              return '<tr><td>' + esc(r.name) + '</td>' +
                '<td class="tabular" style="text-align:right">' + r.n + '</td>' +
                '<td class="tabular" style="text-align:right">' + (list.length ? Math.round(r.n / list.length * 100) : 0) + '</td></tr>';
            }).join('')
          : '<tr><td colspan="3" class="muted">Нет данных</td></tr>') +
        '</tbody>';
      return;
    }
    $('reasons-table').hidden = true;
    $('reasons-chart').hidden = false;
    chartDefaults(); destroyChart('reasons');
    var nz = rows.filter(function (r) { return r.n > 0; });
    $('chart-reasons').style.display = nz.length ? '' : 'none';
    if (!nz.length) return;
    state.charts.reasons = new Chart($('chart-reasons'), {
      type: 'bar',
      data: {
        labels: nz.map(function (r) { return r.name; }),
        datasets: [{ label: 'Заявок', data: nz.map(function (r) { return r.n; }),
          backgroundColor: SiskuUtil.hexToRgba(GOLD, .45), borderColor: GOLD, borderWidth: 1 }]
      },
      options: {
        indexAxis: 'y', responsive: true,
        plugins: { legend: { display: false } },
        scales: {
          x: { ticks: { precision: 0 }, grid: { color: LINE } },
          y: { grid: { display: false } }
        }
      }
    });
  }
  function drawReturnDays(list) {
    chartDefaults(); destroyChart('returnDays');
    $('return-days-empty').hidden = list.length !== 0;
    $('chart-return-days').style.display = list.length ? '' : 'none';
    if (!list.length) return;
    var byDay = {};
    list.forEach(function (r) {
      var k = dayKey(r.created_at);          /* локальная дата — без UTC-фантомов */
      byDay[k] = (byDay[k] || 0) + 1;
    });
    var keys = Object.keys(byDay).sort();
    state.charts.returnDays = new Chart($('chart-return-days'), {
      type: 'line',
      data: {
        labels: keys.map(function (k) { var p = k.split('-'); return p[2] + '.' + p[1]; }),
        datasets: [{ label: 'Заявок', data: keys.map(function (k) { return byDay[k]; }),
          borderColor: GOLD, backgroundColor: SiskuUtil.hexToRgba(GOLD, .15), fill: true, tension: .35 }]
      },
      options: {
        responsive: true,
        plugins: { legend: { display: false } },
        scales: {
          y: { ticks: { precision: 0 }, grid: { color: LINE } },
          x: { grid: { display: false } }
        }
      }
    });
  }
  function exportReturnsCsv() {
    var list = returnsInPeriod();
    var agg = returnAggregates(list);
    var periodLabel = $('r-period').selectedOptions[0].textContent;
    var R = [];
    R.push(['Статистика возвратов — период «' + periodLabel + '»']);
    R.push([]);
    R.push(['1. Сводка'], ['Метрика', 'Значение']);
    R.push(['Заявок', list.length]);
    R.push(['Возвратов оформлено (verified)', agg.verified.length]);
    R.push(['Отклонено', agg.rejected.length]);
    R.push(['В обработке', list.length - agg.verified.length - agg.rejected.length]);
    R.push(['Сумма возвратов, ₽', agg.sum]);
    R.push(['С отметкой «деньги возвращены»', agg.paidN]);
    R.push(['Средний срок, дней', agg.avgDays ? agg.avgDays.toFixed(1) : '—']);
    R.push([]);
    R.push(['2. Причины'], ['Причина', 'Заявок', 'Доля, %']);
    reasonRows(list).forEach(function (r) {
      R.push([r.name, r.n, list.length ? Math.round(r.n / list.length * 100) : 0]);
    });
    R.push([]);
    R.push(['3. Заявки'], ['№', 'Создана', 'Заказ №', 'Клиент', 'Причина', 'Статус', 'Деньги возвращены', 'Завершена', 'Комментарий']);
    list.slice().sort(function (a, b) { return new Date(b.created_at) - new Date(a.created_at); })
      .forEach(function (r) {
        var o = orderById(r.order_id);
        R.push([r.id, fmtDate(r.created_at), r.order_id, o ? o.customer_name : '',
          reasonById(r.reason_id).name || '', returnStatusLabel(r.status),
          r.refund_paid ? 'да' : 'нет', r.resolved_at ? fmtDate(r.resolved_at) : '',
          (r.comment || '').replace(/;/g, ',').replace(/\n/g, ' ')]);
      });
    var csv = R.map(function (row) {
      return row.map(SiskuUtil.csvCell).join(';');   /* анти-формульный префикс (фикс F06) */
    }).join('\r\n');
    var blob = new Blob(['\uFEFF' + csv], { type: 'text/csv;charset=utf-8' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'sisku-returns-stats-' + $('r-period').value + '-' + dayKey(new Date()) + '.csv';
    a.click();
    URL.revokeObjectURL(a.href);
  }

  /* ---------- подвкладка «Списания» (v0.20.0, fp №9, Д8) ----------
     Данные — draft_writeoffs_bundle (скрипт 32): журнал (товар/вариант,
     qty ±, причина, автор, комментарий, сессия + текущая цена товара для
     сумм), справочник причин, итоги проведённых сессий. Суммы — по ТЕКУЩЕЙ
     цене товара (Д8; в бою — по закупочной и цене продажи на момент
     инвентаризации, fp №28). Ленинвая загрузка — паттерн «Возвратов». */
  var fmtNum = SiskuUtil.fmtNum;   /* формат «12 345» (ru-RU) — как в колбэках осей */
  function loadWriteoffs(force) {
    if (state.writeoffsLoaded && !force) return Promise.resolve();
    if (!db) return Promise.reject({ message: dbError || 'нет БД' });
    $('wo-loading').hidden = false;
    $('wo-error').hidden = true;
    return db.rpc('draft_writeoffs_bundle').then(function (res) {
      $('wo-loading').hidden = true;
      if (res.error) throw res.error;
      var d = res.data || {};
      state.writeoffs.rows = (d.writeoffs || []).map(function (w) {
        w.qty = Number(w.qty);
        w.price = Number(w.price || 0);
        return w;
      });
      state.writeoffs.reasons = d.reasons || [];
      state.writeoffs.sessions = d.sessions || [];
      state.writeoffsLoaded = true;
    });
  }
  function writeoffsInPeriod() {
    var days = $('wo-period').value;
    var list = state.writeoffs.rows.slice();
    if (days !== 'all') {
      var from = Date.now() - Number(days) * 864e5;
      list = list.filter(function (w) { return new Date(w.created_at).getTime() >= from; });
    }
    return list;
  }
  function woAggregates(list) {
    var a = { woLines: 0, woQty: 0, woSum: 0, suLines: 0, suQty: 0, suSum: 0, absQty: 0 };
    list.forEach(function (w) {
      var sum = Math.abs(w.qty) * w.price;
      a.absQty += Math.abs(w.qty);
      if (w.qty < 0) { a.woLines += 1; a.woQty += -w.qty; a.woSum += sum; }
      else { a.suLines += 1; a.suQty += w.qty; a.suSum += sum; }
    });
    return a;
  }
  function woSigned(n) {
    return n > 0 ? '+' + fmtNum(n) : (n < 0 ? '−' + fmtNum(Math.abs(n)) : '0');
  }
  function renderWriteoffStats() {
    if (!state.writeoffsLoaded) return;
    var list = writeoffsInPeriod();
    var a = woAggregates(list);
    $('wo-kpi').innerHTML =
      kpi('Списания', a.woLines, 'строк · ' + fmtNum(a.woQty) + ' шт.') +
      kpi('Сумма списаний', money(a.woSum), 'по текущим ценам') +
      kpi('Излишки', a.suLines, 'строк · ' + fmtNum(a.suQty) + ' шт.') +
      kpi('Сумма излишков', money(a.suSum), 'по текущим ценам') +
      kpi('Среднее расхождение', list.length ? (a.absQty / list.length).toFixed(1) + ' шт.' : '—', 'на строку журнала');
    drawWoReasons(list);
    drawWoTop(list);
    drawWoAdmins(list);
    drawWoSessions(list);
  }
  function woReasonRows(list) {
    var agg = {};
    list.forEach(function (w) {
      var k = w.reason_id;
      if (!agg[k]) agg[k] = { name: w.reason || 'Причина №' + k, lines: 0, qty: 0, sum: 0 };
      agg[k].lines += 1;
      agg[k].qty += Math.abs(w.qty);
      agg[k].sum += Math.abs(w.qty) * w.price;
    });
    var rows = Object.keys(agg).map(function (k) { return agg[k]; });
    rows.sort(function (x, y) { return y.qty - x.qty; });
    return rows;
  }
  function drawWoReasons(list) {
    var rows = woReasonRows(list);
    $('wo-reasons-empty').hidden = list.length !== 0;
    if (state.woMode !== 'chart') {
      destroyChart('woReasons');
      $('wo-reasons-chart').hidden = true;
      $('wo-reasons-table').hidden = false;
      $('table-wo-reasons').innerHTML =
        '<thead><tr><th>Причина</th><th style="text-align:right">Строк</th><th style="text-align:right">Единиц</th><th style="text-align:right">Сумма</th></tr></thead><tbody>' +
        (rows.length
          ? rows.map(function (r) {
              return '<tr><td>' + esc(r.name) + '</td>' +
                '<td class="tabular" style="text-align:right">' + r.lines + '</td>' +
                '<td class="tabular" style="text-align:right">' + fmtNum(r.qty) + '</td>' +
                '<td class="tabular" style="text-align:right">' + money(r.sum) + '</td></tr>';
            }).join('')
          : '<tr><td colspan="4" class="muted">Нет данных</td></tr>') +
        '</tbody>';
      return;
    }
    $('wo-reasons-table').hidden = true;
    $('wo-reasons-chart').hidden = false;
    chartDefaults(); destroyChart('woReasons');
    var nz = rows.filter(function (r) { return r.qty > 0; });
    $('chart-wo-reasons').style.display = nz.length ? '' : 'none';
    if (!nz.length) return;
    state.charts.woReasons = new Chart($('chart-wo-reasons'), {
      type: 'bar',
      data: {
        labels: nz.map(function (r) { return r.name; }),
        datasets: [{ label: 'Единиц', data: nz.map(function (r) { return r.qty; }),
          backgroundColor: SiskuUtil.hexToRgba(GOLD, .45), borderColor: GOLD, borderWidth: 1 }]
      },
      options: {
        indexAxis: 'y', responsive: true,
        plugins: { legend: { display: false } },
        scales: {
          x: { ticks: { precision: 0 }, grid: { color: LINE } },
          y: { grid: { display: false } }
        }
      }
    });
  }
  function drawWoTop(list) {
    var agg = {};
    list.filter(function (w) { return w.qty < 0; }).forEach(function (w) {
      var k = w.product_id;
      if (!agg[k]) agg[k] = { name: w.product, article: w.article, lines: 0, qty: 0, sum: 0 };
      agg[k].lines += 1;
      agg[k].qty += -w.qty;
      agg[k].sum += -w.qty * w.price;
    });
    var rows = Object.keys(agg).map(function (k) { return agg[k]; });
    rows.sort(function (x, y) { return y.qty - x.qty; });
    rows = rows.slice(0, 10);
    $('wo-top-empty').hidden = rows.length !== 0;
    $('table-wo-top').innerHTML =
      '<thead><tr><th>Товар</th><th style="text-align:right">Списаний</th><th style="text-align:right">Единиц</th><th style="text-align:right">Сумма</th></tr></thead><tbody>' +
      (rows.length
        ? rows.map(function (r) {
            return '<tr><td>' + esc(r.name) + ' <span class="muted" style="font-size:12px">' + esc(r.article) + '</span></td>' +
              '<td class="tabular" style="text-align:right">' + r.lines + '</td>' +
              '<td class="tabular" style="text-align:right">' + fmtNum(r.qty) + '</td>' +
              '<td class="tabular" style="text-align:right">' + money(r.sum) + '</td></tr>';
          }).join('')
        : '<tr><td colspan="4" class="muted">Списаний за период нет (излишки — в причинах и сводке)</td></tr>') +
      '</tbody>';
  }
  function drawWoAdmins(list) {
    var agg = {};
    list.forEach(function (w) {
      var k = w.changed_by || '—';
      if (!agg[k]) agg[k] = { name: k, lines: 0, qty: 0, sum: 0 };
      agg[k].lines += 1;
      agg[k].qty += Math.abs(w.qty);
      agg[k].sum += Math.abs(w.qty) * w.price;
    });
    var rows = Object.keys(agg).map(function (k) { return agg[k]; });
    rows.sort(function (x, y) { return y.lines - x.lines; });
    $('wo-admins-empty').hidden = rows.length !== 0;
    $('table-wo-admins').innerHTML =
      '<thead><tr><th>Автор</th><th style="text-align:right">Строк</th><th style="text-align:right">Единиц</th><th style="text-align:right">Сумма</th></tr></thead><tbody>' +
      (rows.length
        ? rows.map(function (r) {
            return '<tr><td>' + esc(r.name) + '</td>' +
              '<td class="tabular" style="text-align:right">' + r.lines + '</td>' +
              '<td class="tabular" style="text-align:right">' + fmtNum(r.qty) + '</td>' +
              '<td class="tabular" style="text-align:right">' + money(r.sum) + '</td></tr>';
          }).join('')
        : '<tr><td colspan="4" class="muted">Нет данных</td></tr>') +
      '</tbody>';
  }
  function drawWoSessions(list) {
    var byId = {};
    list.forEach(function (w) {
      if (w.session_id == null) return;
      var g = byId[w.session_id] || (byId[w.session_id] = { wl: 0, wq: 0, wsum: 0, sl: 0, sq: 0, ssum: 0 });
      if (w.qty < 0) { g.wl += 1; g.wq += -w.qty; g.wsum += -w.qty * w.price; }
      else { g.sl += 1; g.sq += w.qty; g.ssum += w.qty * w.price; }
    });
    var rows = state.writeoffs.sessions.map(function (s) {
      var g = byId[s.id] || { wl: 0, wq: 0, wsum: 0, sl: 0, sq: 0, ssum: 0 };
      return { id: s.id, finished: s.finished_at, g: g };
    });
    $('wo-sessions-empty').hidden = rows.length !== 0;
    $('table-wo-sessions').innerHTML =
      '<thead><tr><th>Сессия</th><th>Завершена</th><th style="text-align:right">Списания</th><th style="text-align:right">Излишки</th><th style="text-align:right">Сумма списаний</th></tr></thead><tbody>' +
      (rows.length
        ? rows.map(function (r) {
            return '<tr><td>№ ' + r.id + '</td>' +
              '<td class="tabular muted">' + (r.finished ? SiskuUtil.fmtDate(r.finished) : '—') + '</td>' +
              '<td class="tabular" style="text-align:right">' + r.g.wl + ' стр. · ' + fmtNum(r.g.wq) + ' шт.</td>' +
              '<td class="tabular" style="text-align:right">' + r.g.sl + ' стр. · ' + fmtNum(r.g.sq) + ' шт.</td>' +
              '<td class="tabular" style="text-align:right">' + money(r.g.wsum) + '</td></tr>';
          }).join('')
        : '<tr><td colspan="5" class="muted">Проведённых инвентаризаций нет</td></tr>') +
      '</tbody>';
  }
  function exportWriteoffsCsv() {
    var list = writeoffsInPeriod();
    var a = woAggregates(list);
    var periodLabel = $('wo-period').selectedOptions[0].textContent;
    var R = [];
    R.push(['Статистика списаний — период «' + periodLabel + '»']);
    R.push(['Суммы — по текущим ценам товаров (в бою — исторические цены, fp №28)']);
    R.push([]);
    R.push(['1. Сводка'], ['Метрика', 'Значение']);
    R.push(['Списаний, строк', a.woLines]);
    R.push(['Списано, единиц', a.woQty]);
    R.push(['Сумма списаний, ₽', a.woSum]);
    R.push(['Излишков, строк', a.suLines]);
    R.push(['Излишков, единиц', a.suQty]);
    R.push(['Сумма излишков, ₽', a.suSum]);
    R.push(['Среднее расхождение, единиц', list.length ? (a.absQty / list.length).toFixed(1) : '—']);
    R.push([]);
    R.push(['2. Причины'], ['Причина', 'Строк', 'Единиц', 'Сумма, ₽']);
    woReasonRows(list).forEach(function (r) { R.push([r.name, r.lines, r.qty, r.sum]); });
    R.push([]);
    R.push(['3. Авторы'], ['Автор', 'Строк', 'Единиц', 'Сумма, ₽']);
    (function () {
      var agg = {};
      list.forEach(function (w) {
        var k = w.changed_by || '—';
        if (!agg[k]) agg[k] = { lines: 0, qty: 0, sum: 0 };
        agg[k].lines += 1; agg[k].qty += Math.abs(w.qty); agg[k].sum += Math.abs(w.qty) * w.price;
      });
      Object.keys(agg).forEach(function (k) { R.push([k, agg[k].lines, agg[k].qty, agg[k].sum]); });
    })();
    R.push([]);
    R.push(['4. Журнал'], ['Дата', 'Артикул', 'Товар', 'Вариант', 'Кол-во', 'Причина', 'Автор', 'Комментарий', 'Сессия']);
    list.forEach(function (w) {
      R.push([fmtDate(w.created_at), w.article, w.product, w.variant, woSigned(w.qty),
        w.reason || '', w.changed_by || '', (w.comment || '').replace(/;/g, ',').replace(/\n/g, ' '),
        w.session_id ? '№ ' + w.session_id : 'ручное']);
    });
    var csv = R.map(function (row) {
      return row.map(SiskuUtil.csvCell).join(';');   /* анти-формульный префикс (фикс F06) */
    }).join('\r\n');
    var blob = new Blob(['\uFEFF' + csv], { type: 'text/csv;charset=utf-8' });
    var a2 = document.createElement('a');
    a2.href = URL.createObjectURL(blob);
    a2.download = 'sisku-writeoffs-stats-' + $('wo-period').value + '-' + dayKey(new Date()) + '.csv';   /* локальная дата (фикс F29) */
    a2.click();
    URL.revokeObjectURL(a2.href);
  }

  /* ---------- вкладки и события ---------- */
  /* v0.16.0 (fp №3): «Заказы → Возвраты» — полноценная очередь заявок
     (вместо заглушки v0.15.0); данные — draft_returns_bundle одним RPC */
  function showReturns(on) {
    $('panel-orders').hidden = on;
    $('panel-returns').hidden = !on;
    if (on) {
      $('panel-stats').hidden = true;
      loadReturns(false).then(function () { renderReturns(); }).catch(function (e) {
        $('rr-loading').hidden = true;
        $('rr-error').hidden = false;
        $('rr-error').textContent = 'Не удалось загрузить заявки: ' + (e.message || e);
      });
    }
  }
  function switchTab(which) {
    var orders = which === 'orders';
    $('tab-orders').classList.toggle('active', orders);
    $('tab-stats').classList.toggle('active', !orders);
    $('tab-orders').setAttribute('aria-selected', orders);
    $('tab-stats').setAttribute('aria-selected', !orders);
    $('panel-orders').hidden = !orders;
    $('panel-stats').hidden = orders;
    $('panel-returns').hidden = true;
    if (!orders) renderStatsActive();
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;

    /* тема админки: общий модуль admintheme.js (тёмная по умолчанию) */
    if (window.initAdminTheme) window.initAdminTheme(function () {
      if (!$('panel-stats').hidden) renderStatsActive();   /* перерисовать графики в цветах темы */
    });

    /* v0.13.0: подвкладки статистики */
    $('stats-subseg').addEventListener('click', function (e) {
      var b = e.target.closest('.seg-btn');
      if (b) switchStatsTab(b.getAttribute('data-stab'));
    });
    $('p-period').addEventListener('change', renderPromoStats);
    $('btn-promos-csv').addEventListener('click', exportPromosCsv);
    /* v0.19.0 (fp №7): подвкладка «Клиенты» — сегменты */
    $('cst-filters').addEventListener('click', function (e) {
      var b = e.target.closest('.seg-btn');
      if (!b) return;
      state.cstFilter = b.getAttribute('data-seg') || '';
      state.cstPage = 1;
      renderClientsStats();
    });
    $('cst-refresh').addEventListener('click', function () {
      loadClientsStats(true).then(function () { renderClientsStats(); }).catch(function (e2) {
        $('cst-error').textContent = 'Ошибка загрузки: ' + SiskuUtil.friendlyDbError(e2);
        $('cst-error').hidden = false;
      });
    });
    $('cst-csv').addEventListener('click', exportCstCsv);
    $('cst-thresholds').addEventListener('click', openThresholds);
    document.querySelectorAll('#stab-clients th.sortable').forEach(function (t) {
      t.addEventListener('click', function () {
        var f = t.getAttribute('data-cst-sort');
        if (state.cstSort.field === f) {
          state.cstSort.dir = state.cstSort.dir === 'asc' ? 'desc' : 'asc';
        } else {
          state.cstSort = { field: f, dir: f === 'name' ? 'asc' : 'desc' };
        }
        state.cstPage = 1;
        renderClientsStats();
      });
    });
    $('cst-pg-prev').addEventListener('click', function () { state.cstPage -= 1; renderClientsStats(); });
    $('cst-pg-next').addEventListener('click', function () { state.cstPage += 1; renderClientsStats(); });
    $('cst-body').addEventListener('click', function (e) {
      var eye = e.target.closest('button[data-cst-eye]');
      if (!eye) return;
      var cid = Number(eye.getAttribute('data-cst-eye'));
      state.cstRevealed[cid] = !state.cstRevealed[cid];
      renderClientsStats();
    });
    $('cstm-close').addEventListener('click', function () { $('cstm-backdrop').classList.remove('open'); });
    $('cstm-backdrop').addEventListener('click', function (e) {
      if (e.target === $('cstm-backdrop')) $('cstm-backdrop').classList.remove('open');
    });
    $('cstm-form').addEventListener('submit', saveThresholds);
    $('promocodes-seg').addEventListener('click', function (e) {
      var b = e.target.closest('.seg-btn');
      if (!b) return;
      state.promoMode = b.getAttribute('data-mode') === 'table' ? 'table' : 'chart';
      $('promocodes-seg').querySelectorAll('.seg-btn').forEach(function (x) { x.classList.toggle('active', x === b); });
      renderPromoCodes(promoAggregates(promoPeriodOrders()).withP);
    });

    /* переключатель «Диаграмма / Таблица» в блоке доставки и оплаты */
    $('methods-seg').addEventListener('click', function (e) {
      var b = e.target.closest('.seg-btn');
      if (!b) return;
      state.methodsMode = b.getAttribute('data-mode') === 'table' ? 'table' : 'chart';
      $('methods-seg').querySelectorAll('.seg-btn').forEach(function (x) { x.classList.toggle('active', x === b); });
      renderMethods(periodOrders());
    });

    /* выгрузка статистики в CSV */
    $('btn-stats-csv').addEventListener('click', exportStatsCsv);

    /* сортировка топа товаров: кол-во / сумма */
    $('top-products').addEventListener('click', function (e) {
      var th = e.target.closest('th.sortable[data-top]');
      if (!th) return;
      state.topSort = th.getAttribute('data-top');
      drawTop(periodOrders());
    });

    /* воронка статусов: диаграмма / таблица */
    $('funnel-seg').addEventListener('click', function (e) {
      var b = e.target.closest('.seg-btn');
      if (!b) return;
      state.funnelMode = b.getAttribute('data-mode') === 'table' ? 'table' : 'chart';
      $('funnel-seg').querySelectorAll('.seg-btn').forEach(function (x) { x.classList.toggle('active', x === b); });
      drawFunnel(periodOrders());
    });

    /* сортировка таблицы заказов кликом по заголовку */
    document.querySelectorAll('th.sortable').forEach(function (th) {
      th.addEventListener('click', function () {
        var f = th.getAttribute('data-sort');
        if (state.sort.field === f) {
          state.sort.dir = state.sort.dir === 'asc' ? 'desc' : 'asc';
        } else {
          state.sort.field = f;
          state.sort.dir = f === 'created' ? 'desc' : 'asc';
        }
        state.page = 1;
        renderOrders();
      });
    });

    /* v0.16.0 (fp №3): кнопка сегмента «Возвраты» и хэш admin.html#returns
       (ссылка со страницы «Сборка») открывают очередь заявок */
    $('seg-returns').addEventListener('click', function () { showReturns(true); });

    /* очередь заявок: фильтр, пагинация, обновление, открытие карточки */
    $('rr-filter').addEventListener('change', function () {
      state.rrFilter = this.value; state.rrPage = 1; renderReturns();
    });
    $('rr-refresh').addEventListener('click', function () {
      loadReturns(true).then(function () { renderReturns(); }).catch(function (e) {
        $('rr-loading').hidden = true;
        $('rr-error').hidden = false;
        $('rr-error').textContent = 'Не удалось загрузить заявки: ' + (e.message || e);
      });
    });
    $('rr-prev').addEventListener('click', function () { state.rrPage -= 1; renderReturns(); });
    $('rr-next').addEventListener('click', function () { state.rrPage += 1; renderReturns(); });
    $('rr-body').addEventListener('click', function (e) {
      var tr = e.target.closest('tr[data-rid]');
      if (tr) openReturnRequest(Number(tr.getAttribute('data-rid')));
    });
    $('ret-modal-close').addEventListener('click', function () { $('ret-modal-backdrop').classList.remove('open'); });
    $('ret-modal-backdrop').addEventListener('click', function (e) {
      if (e.target === $('ret-modal-backdrop')) $('ret-modal-backdrop').classList.remove('open');
    });

    /* статистика «Возвраты»: период, CSV, вид причин */
    $('r-period').addEventListener('change', renderReturnStats);
    $('btn-returns-csv').addEventListener('click', exportReturnsCsv);
    $('reasons-seg').addEventListener('click', function (e) {
      var b = e.target.closest('.seg-btn');
      if (!b) return;
      state.returnMode = b.getAttribute('data-mode') === 'chart' ? 'chart' : 'table';
      $('reasons-seg').querySelectorAll('.seg-btn').forEach(function (x) { x.classList.toggle('active', x === b); });
      drawReasons(returnsInPeriod());
    });

    /* статистика «Списания» (v0.20.0, fp №9): период, CSV, вид причин */
    $('wo-period').addEventListener('change', renderWriteoffStats);
    $('btn-writeoffs-csv').addEventListener('click', exportWriteoffsCsv);
    $('wo-reasons-seg').addEventListener('click', function (e) {
      var b = e.target.closest('.seg-btn');
      if (!b) return;
      state.woMode = b.getAttribute('data-mode') === 'chart' ? 'chart' : 'table';
      $('wo-reasons-seg').querySelectorAll('.seg-btn').forEach(function (x) { x.classList.toggle('active', x === b); });
      drawWoReasons(writeoffsInPeriod());
    });

    /* ссылка admin.html#stats открывает сразу вкладку статистики;
       v0.13.0: #stats-promos и т.п. открывают конкретную подвкладку */
    if (location.hash === '#returns') {
      showReturns(true);
    } else if (location.hash === '#stats') {
      switchTab('stats');
    } else if (location.hash.indexOf('#stats-') === 0) {
      switchTab('stats');
      switchStatsTab(location.hash.slice(7));
    }

    /* выход из мок-сессии черновика */
    $('btn-logout').addEventListener('click', function () {
      if (window.mockLogout) window.mockLogout();
    });

    /* пагинация таблицы заказов */
    $('pg-prev').addEventListener('click', function () { state.page -= 1; renderOrders(); });
    $('pg-next').addEventListener('click', function () { state.page += 1; renderOrders(); });

    $('tab-orders').addEventListener('click', function () { switchTab('orders'); });
    $('tab-stats').addEventListener('click', function () { switchTab('stats'); });
    $('f-search').addEventListener('input', function () { state.page = 1; renderOrders(); });
    $('f-status').addEventListener('change', function () { state.page = 1; renderOrders(); });
    $('f-paid').addEventListener('change', function () { state.page = 1; renderOrders(); });
    $('s-period').addEventListener('change', renderStats);
    $('btn-refresh').addEventListener('click', function () {
      $('orders-loading').hidden = false;
      /* v0.17.0 (находка D2): сетевая ошибка при обновлении — плашка,
         а не вечный скелетон (unhandled rejection больше не теряется) */
      loadAll().catch(function (err) {
        $('orders-loading').hidden = true;
        $('orders-error').hidden = false;
        $('orders-error').textContent = 'Ошибка загрузки: ' + SiskuUtil.friendlyDbError(err);
      });
    });
    $('btn-csv').addEventListener('click', exportCsv);
    $('orders-body').addEventListener('click', function (e) {
      var eye = e.target.closest('button[data-eye]');
      if (eye) {
        var oid = Number(eye.getAttribute('data-eye'));
        state.revealed[oid] = !state.revealed[oid];
        renderOrders();
        e.stopPropagation();
        return;
      }
      var tr = e.target.closest('tr[data-id]');
      if (tr) openOrder(Number(tr.getAttribute('data-id')));
    });
    $('order-modal-close').addEventListener('click', function () { $('order-modal-backdrop').classList.remove('open'); });
    $('order-modal-backdrop').addEventListener('click', function (e) {
      if (e.target === $('order-modal-backdrop')) $('order-modal-backdrop').classList.remove('open');
    });

    loadAll().then(function () {
      /* v0.18.0 (Д6): диплинк admin.html?order=N&back=client:M — карточка
         заказа из истории заказов карточки клиента; открывается строго после
         загрузки бандла (гонка исключена); back=client:M — обратная навигация */
      var params = new URLSearchParams(window.location.search);
      var oid = parseInt(params.get('order'), 10);
      if (!oid) return;
      var m = /^client:(\d+)$/.exec(params.get('back') || '');
      var found = state.orders.filter(function (x) { return x.id === oid; })[0];
      if (!found) {
        $('orders-error').hidden = false;
        $('orders-error').textContent = 'Заказ № ' + oid + ' не найден — ссылка устарела.';
        return;
      }
      openOrder(oid, m ? { kind: 'client', id: Number(m[1]) } : null);
    }).catch(function (err) {
      $('orders-loading').hidden = true;
      $('orders-error').hidden = false;
      /* v0.17.0 (находка D2): читаемое сообщение вместо сырого */
      $('orders-error').textContent = 'Ошибка загрузки: ' + SiskuUtil.friendlyDbError(err);
    });
  });
})();
