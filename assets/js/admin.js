/* ==========================================================================
   SISKU · admin.js — админ-панель черновика (без пароля, доступ по ссылке)
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
    revealed: {},            /* заказ, у которого раскрыты контакты */
    methodsMode: 'chart',    /* «Диаграмма» / «Таблица» в блоке доставки и оплаты */
    sort: { field: 'created', dir: 'desc' },   /* сортировка таблицы заказов */
    charts: {}
  };

  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }
  function money(n) { return new Intl.NumberFormat('ru-RU').format(Math.round(Number(n || 0))) + ' ₽'; }
  function fmtDate(iso) {
    var d = new Date(iso);
    return d.toLocaleDateString('ru-RU', { day: '2-digit', month: '2-digit', year: '2-digit' }) +
      ' ' + d.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
  }
  function statusByid(id) { return state.statuses.filter(function (s) { return s.id === id; })[0] || {}; }
  function paymentByid(id) { return state.payments.filter(function (m) { return m.id === id; })[0] || {}; }
  function deliveryByid(id) { return state.deliveries.filter(function (m) { return m.id === id; })[0] || {}; }
  function itemsOf(orderId) { return state.items.filter(function (i) { return i.order_id === orderId; }); }

  /* маскирование контактов (паттерн учебного проекта) */
  function maskPhone(p) {
    if (!p) return '—';
    if (p.replace(/\D/g, '').length < 5) return p;
    return p.slice(0, Math.max(0, p.length - 9)) + ' ••• •• ' + p.slice(-2);
  }
  function maskEmail(e) {
    if (!e) return '—';
    var at = e.indexOf('@');
    if (at < 1) return e;
    return e[0] + '•••' + e.slice(at);
  }

  /* ---------- загрузка ---------- */
  function loadAll() {
    if (!db) {
      $('orders-loading').hidden = true;
      $('orders-error').hidden = false;
      $('orders-error').textContent = 'База не подключена: ' + (dbError || 'заполните assets/js/config.js');
      return Promise.reject(new Error(dbError || 'нет БД'));
    }
    return Promise.all([
      db.from('orders').select('*').order('created_at', { ascending: false }),
      db.from('order_items').select('*'),
      db.from('order_statuses').select('*').order('sort_order'),
      db.from('status_transitions').select('*'),
      db.from('payment_methods').select('*'),
      db.from('delivery_methods').select('*'),
      db.from('order_status_history').select('*')
    ]).then(function (res) {
      res.forEach(function (r) { if (r.error) throw r.error; });
      state.orders = res[0].data;
      state.items = res[1].data;
      state.statuses = res[2].data;
      state.transitions = res[3].data;
      state.payments = res[4].data;
      state.deliveries = res[5].data;
      state.history = res[6].data;

      $('f-status').innerHTML = '<option value="">Все статусы</option>' +
        state.statuses.map(function (s) { return '<option value="' + s.id + '">' + esc(s.name) + '</option>'; }).join('');
      if (window.enhanceSelects) enhanceSelects();
      renderOrders();
      renderStats();
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
    $('orders-loading').hidden = true;
    $('orders-empty').hidden = state.orders.length !== 0;
    $('orders-error').hidden = true;
    $('orders-body').innerHTML = list.map(function (o) {
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
  }

  /* ---------- карточка заказа ---------- */
  function openOrder(id) {
    var o = state.orders.filter(function (x) { return x.id === id; })[0];
    if (!o) return;
    var items = itemsOf(id);
    var history = [];
    /* история подгружается отдельно (лёгкий запрос) */
    db.from('order_status_history').select('*').eq('order_id', id).order('changed_at').then(function (h) {
      history = (h.data || []);
      var st = statusByid(o.status_id);
      var allowed = state.transitions
        .filter(function (t) { return t.from_status_id === o.status_id; })
        .map(function (t) { return statusByid(t.to_status_id); })
        .sort(function (a, b) { return (a.sort_order || 0) - (b.sort_order || 0); });   /* «Сборка» раньше «Отменён» */
      var locked = st.code === 'cancelled';   /* отменённые заказы не изменяются */

      $('order-modal-body').innerHTML =
        '<div class="modal-head-row"><h2>Заказ № ' + o.id + '</h2>' +
        '<span class="status-pill" data-code="' + esc(st.code) + '">' + esc(st.name) + '</span></div>' +
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
          '<button class="btn" id="oc-paid"' + (locked ? ' disabled' : '') + '>' + (o.is_paid ? 'Снять отметку оплаты' : 'Отметить оплаченным') + '</button>' +
        '</div>' +
        (locked ? '<div class="locked-note">Заказ отменён — изменения статусов и оплаты заблокированы.</div>' : '') +
        '<div class="err-box" id="oc-error" hidden></div>' +
        '<div class="subhead">История статусов</div>' +
        '<ul class="history">' + history.map(function (h) {
          return '<li><b>' + esc(statusByid(h.status_id).name) + '</b> — ' + fmtDate(h.changed_at) +
            ' · ' + esc(h.changed_by) + (h.comment ? ' · ' + esc(h.comment) : '') + '</li>';
        }).join('') + '</ul>';

      $('oc-apply').addEventListener('click', function () {
        var code = $('oc-status').value;
        if (!code) return;
        this.disabled = true;
        db.rpc('admin_set_status', { p_order_id: o.id, p_status_code: code, p_changed_by: 'draft-admin' })
          .then(function (res) {
            if (res.error) { $('oc-error').textContent = res.error.message; $('oc-error').hidden = false; this.disabled = false; return; }
            loadAll().then(function () { openOrder(o.id); });
          }.bind(this));
      });
      $('oc-paid').addEventListener('click', function () {
        this.disabled = true;
        db.rpc('admin_set_paid', { p_order_id: o.id, p_is_paid: !o.is_paid })
          .then(function () { loadAll().then(function () { openOrder(o.id); }); });
      });

      $('order-modal-backdrop').classList.add('open');
      if (window.enhanceSelects) enhanceSelects($('order-modal-body'));
    });
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
      lines.push(row.map(function (c) { return '"' + String(c).replace(/"/g, '""') + '"'; }).join(';'));
    });
    var blob = new Blob(['\uFEFF' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'sisku-orders-' + new Date().toISOString().slice(0, 10) + '.csv';
    a.click();
    URL.revokeObjectURL(a.href);
  }

  /* ---------- статистика ---------- */
  function periodOrders() {
    var days = $('s-period').value;
    if (days === 'all') return state.orders.slice();
    var from = Date.now() - Number(days) * 864e5;
    return state.orders.filter(function (o) { return new Date(o.created_at).getTime() >= from; });
  }

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
    var light = document.documentElement.getAttribute('data-theme') === 'light';
    if (light) { GOLD = '#7A5C2E'; MUTED = '#6F6A60'; LINE = '#E5E0D6'; TEXT = '#1A1A1E'; }
    else       { GOLD = '#C9A96A'; MUTED = '#A79FB0'; LINE = '#2A2A33'; TEXT = '#F2EEE4'; }
    Chart.defaults.color = MUTED;
    Chart.defaults.borderColor = LINE;
    Chart.defaults.font.family = "'Manrope', sans-serif";
  }
  function destroyChart(key) { if (state.charts[key]) { state.charts[key].destroy(); state.charts[key] = null; } }

  function drawDaysChart(list) {
    chartDefaults(); destroyChart('days');
    var byDay = {};
    list.forEach(function (o) {
      var d = new Date(o.created_at).toLocaleDateString('ru-RU', { day: '2-digit', month: '2-digit' });
      byDay[d] = byDay[d] || { n: 0, sum: 0 };
      byDay[d].n += 1; byDay[d].sum += o.total + o.delivery_cost;
    });
    var labels = Object.keys(byDay);
    state.charts.days = new Chart($('chart-days'), {
      type: 'line',
      data: {
        labels: labels,
        datasets: [
          { label: 'Заявки', data: labels.map(function (d) { return byDay[d].n; }), borderColor: GOLD, backgroundColor: 'rgba(201,169,106,.15)', fill: true, tension: .35, yAxisID: 'y' },
          { label: 'Сумма, ₽', data: labels.map(function (d) { return byDay[d].sum; }), borderColor: MUTED, borderDash: [5, 4], tension: .35, yAxisID: 'y1' }
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
    state.charts.funnel = new Chart($('chart-funnel'), {
      type: 'bar',
      data: {
        labels: state.statuses.map(function (s) { return s.name; }),
        datasets: [{ data: counts, backgroundColor: GOLD, borderRadius: 2 }]
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
      .sort(function (a, b) { return b.v.sum - a.v.sum; }).slice(0, 6);
    $('top-products').innerHTML =
      '<thead><tr><th>№</th><th>Товар</th><th style="text-align:right">Кол-во</th><th style="text-align:right">Сумма</th></tr></thead><tbody>' +
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
      data: { labels: labels, datasets: [{ data: counts, backgroundColor: GOLD, borderRadius: 2, barThickness: 20 }] },
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

  /* ---------- метрики времени между статусами (под воронкой) ---------- */
  function renderTiming(list) {
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
    var a = stat(diffs('new', ['confirmed']));
    var b = stat(diffs('new', ['delivered', 'cancelled', 'returned']));
    var c = stat(diffs('delivered', ['returned']));
    var d = stat(diffs('new', ['cancelled']));
    $('funnel-metrics').innerHTML =
      '<li><span>Новый → Подтверждён<span class="hint">среднее время реакции на заявку</span></span><span class="val">' + a.v + (a.n ? ' · кол-во: ' + a.n : '') + '</span></li>' +
      '<li><span>Новый → Завершён<span class="hint">до «Доставлен», «Отменён» или «Возврат»</span></span><span class="val">' + b.v + (b.n ? ' · кол-во: ' + b.n : '') + '</span></li>' +
      '<li><span>Новый → Отменён<span class="hint">как быстро отменяют заказы</span></span><span class="val">' + d.v + (d.n ? ' · кол-во: ' + d.n : '') + '</span></li>' +
      '<li><span>Доставлен → Возврат<span class="hint">возвраты после завершения</span></span><span class="val">' + c.v + (c.n ? ' · кол-во: ' + c.n : '') + '</span></li>';
  }

  /* ---------- вкладки и события ---------- */
  function switchTab(which) {
    var orders = which === 'orders';
    $('tab-orders').classList.toggle('active', orders);
    $('tab-stats').classList.toggle('active', !orders);
    $('tab-orders').setAttribute('aria-selected', orders);
    $('tab-stats').setAttribute('aria-selected', !orders);
    $('panel-orders').hidden = !orders;
    $('panel-stats').hidden = orders;
    if (!orders) renderStats();
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;

    /* тема админки: общий модуль admintheme.js (тёмная по умолчанию) */
    if (window.initAdminTheme) window.initAdminTheme(function () {
      if (!$('panel-stats').hidden) renderStats();   /* перерисовать графики в цветах темы */
    });

    /* переключатель «Диаграмма / Таблица» в блоке доставки и оплаты */
    $('methods-seg').addEventListener('click', function (e) {
      var b = e.target.closest('.seg-btn');
      if (!b) return;
      state.methodsMode = b.getAttribute('data-mode') === 'table' ? 'table' : 'chart';
      $('methods-seg').querySelectorAll('.seg-btn').forEach(function (x) { x.classList.toggle('active', x === b); });
      renderMethods(periodOrders());
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
        renderOrders();
      });
    });

    /* ссылка admin.html#stats открывает сразу вкладку статистики */
    if (location.hash === '#stats') switchTab('stats');

    /* выход из мок-сессии черновика */
    $('btn-logout').addEventListener('click', function () {
      if (window.mockLogout) window.mockLogout();
    });

    $('tab-orders').addEventListener('click', function () { switchTab('orders'); });
    $('tab-stats').addEventListener('click', function () { switchTab('stats'); });
    $('f-search').addEventListener('input', renderOrders);
    $('f-status').addEventListener('change', renderOrders);
    $('f-paid').addEventListener('change', renderOrders);
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
