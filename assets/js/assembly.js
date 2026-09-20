/* ==========================================================================
   SISKU · assembly.js — экран «Сборка» (v0.4.0-draft)
   Обезличенный производственный список: заказы в статусе «Сборка»
   с позициями и остатками склада. Данные клиента и доставки НЕ читаются
   вовсе (select только нужных колонок) — минимизация ПДн даже в черновике.
   ========================================================================== */
(function () {
  'use strict';

  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }
  function showEmpty() { $('asm-loading').hidden = true; $('asm-empty').hidden = false; }
  function showError(msg) {
    $('asm-loading').hidden = true;
    $('asm-error').hidden = false;
    $('asm-error').textContent = msg;
  }

  function load() {
    $('asm-loading').hidden = false;
    $('asm-empty').hidden = true;
    $('asm-error').hidden = true;
    if (!db) { showError('База не подключена: ' + (dbError || 'заполните assets/js/config.js')); return; }

    Promise.all([
      db.from('order_statuses').select('id').eq('code', 'packing').limit(1),
      db.from('product_variants').select('id,stock')
    ]).then(function (prep) {
      var packing = prep[0].data.length ? prep[0].data[0].id : null;
      var stock = {};
      (prep[1].data || []).forEach(function (v) { stock[v.id] = v.stock; });
      if (packing == null) { showEmpty(); return null; }

      /* только обезличенные поля заказа */
      return db.from('orders')
        .select('id,comment,created_at')
        .eq('status_id', packing)
        .order('created_at')
        .then(function (oRes) {
          var orders = oRes.data || [];
          if (!orders.length) { showEmpty(); return null; }
          var ids = orders.map(function (o) { return o.id; });
          return db.from('order_items')
            .select('order_id,title_snapshot,variant_snapshot,quantity,variant_id')
            .in('order_id', ids)
            .then(function (iRes) {
              render(orders, iRes.data || [], stock);
              return null;
            });
        });
    }).catch(function (e) { showError('Ошибка загрузки: ' + e.message); });
  }

  function render(orders, items, stock) {
    $('asm-loading').hidden = true;
    $('asm-empty').hidden = true;
    var byOrder = {};
    items.forEach(function (i) { (byOrder[i.order_id] = byOrder[i.order_id] || []).push(i); });
    var html = '';
    orders.forEach(function (o) {
      var list = byOrder[o.id] || [];
      if (!list.length) return;
      list.forEach(function (i, idx) {
        var st = stock[i.variant_id];
        var short = st != null && st < i.quantity;
        html += '<tr>' +
          (idx === 0
            ? '<td rowspan="' + list.length + '"><b>№ ' + o.id + '</b>' +
              '<div class="muted" style="font-size:12px">' + new Date(o.created_at).toLocaleDateString('ru-RU') + '</div></td>' +
              '<td rowspan="' + list.length + '" class="muted" style="font-size:13px">' + esc(o.comment || '—') + '</td>'
            : '') +
          '<td>' + esc(i.title_snapshot) + '</td>' +
          '<td class="muted">' + esc(i.variant_snapshot || '—') + '</td>' +
          '<td class="tabular">' + i.quantity + '</td>' +
          '<td class="tabular"' + (short ? ' style="color:var(--danger)" title="Остатка меньше, чем нужно в заказе"' : '') + '>' +
            (st != null ? st : '—') + '</td>' +
        '</tr>';
      });
    });
    $('asm-body').innerHTML = html || '<tr><td colspan="6" class="muted">Нет позиций</td></tr>';
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;
    if (window.initAdminTheme) window.initAdminTheme();
    $('btn-logout').addEventListener('click', function () { if (window.mockLogout) window.mockLogout(); });
    $('btn-refresh').addEventListener('click', load);
    load();
  });
})();
