/* ==========================================================================
   SISKU · admin.js — админ-панель черновика (вход через мок-авторизацию login.html, v0.4.0-draft)
   Вкладки: заказы (список, карточка, смена статусов по модели переходов,
   признак оплаты, маскирование контактов, CSV) и статистика (KPI, графики).
   Паттерны учебного проекта: маска + «глазик», CSV с BOM и «;»,
   смена статусов только через серверную функцию с проверкой переходов.
   ========================================================================== */
(function () {
  'use strict';

  var state = {
    orders: [], items: [], statuses: [], transitions: [],
    payments: [], deliveries: [], history: [],
    promos: [],              /* v0.13.0: промокоды — подвкладка статистики «Акции» */
    statsTab: 'orders',      /* v0.13.0: активная подвкладка: orders | promos | admins | clients */
    promoMode: 'chart',      /* v0.13.0: «по кодам» — диаграмма или таблица */
    revealed: {},            /* заказ, у которого раскрыты контакты */
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
  function itemsOf(orderId) { return state.items.filter(function (i) { return i.order_id === orderId; }); }


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

  /* ---------- карточка заказа ---------- */
  function openOrder(id) {
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
            loadAll().then(function () { openOrder(o.id); });
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
            loadAll().then(function () { openOrder(o.id); });
          })
          .catch(function (e) {
            $('oc-error').textContent = 'Ошибка сети: ' + e.message;
            $('oc-error').hidden = false;
            self.disabled = false;
          });
      });

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
          y1: { position: 'right', grid: { display: false }, ticks: { callback: function (v) { return new Intl.NumberFormat('ru-RU').format(v); } } }
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
  var STATS_TABS = ['orders', 'promos', 'admins', 'clients'];
  function switchStatsTab(tab) {
    if (STATS_TABS.indexOf(tab) === -1) tab = 'orders';
    state.statsTab = tab;
    $('stats-subseg').querySelectorAll('.seg-btn').forEach(function (b) {
      var on = b.getAttribute('data-stab') === tab;
      b.classList.toggle('active', on);
      b.setAttribute('aria-selected', on ? 'true' : 'false');
    });
    STATS_TABS.forEach(function (t) { $('stab-' + t).hidden = t !== tab; });
    renderStatsActive();
  }
  function renderStatsActive() {
    if (state.statsTab === 'orders') renderStats();
    else if (state.statsTab === 'promos') renderPromoStats();
    /* admins и clients — заглушки, рендер не нужен */
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
          y1: { position: 'right', grid: { display: false }, ticks: { callback: function (v) { return new Intl.NumberFormat('ru-RU').format(v); } } }
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

  /* ---------- вкладки и события ---------- */
  /* правка 2.11 (v0.15.0): «Заказы → Возвраты» — панель-заглушка внутри
     admin.html (П21: отдельная страница и статусная модель возвратов — M4) */
  function showReturns(on) {
    $('panel-orders').hidden = on;
    $('panel-returns').hidden = !on;
    if (on) $('panel-stats').hidden = true;
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

    /* правка 2.11: кнопка сегмента «Возвраты» и хэш admin.html#returns
       (ссылка со страницы «Сборка») открывают панель-заглушку */
    $('seg-returns').addEventListener('click', function () { showReturns(true); });

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
      loadAll();
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

    loadAll().catch(function (err) {
      $('orders-loading').hidden = true;
      $('orders-error').hidden = false;
      $('orders-error').textContent = 'Ошибка загрузки: ' + err.message;
    });
  });
})();
