/* ==========================================================================
   SISKU · assembly.js — экран «Сборка» (v0.5.0-draft)
   Обезличенный производственный список: заказы в статусе «Сборка»
   с позициями и остатками склада (данные клиента и доставки не читаются).
   v0.5.0: один запрос-сборка draft_assembly_bundle(); кнопка перевода
   заказа в следующий статус («Отправлен»); сигнализация остатка < 3 шт.
   v0.20.0 (Д5/7.1, АН-21 вариант (б)): минус/ноль остатка после проведения
   инвентаризации — штатное состояние: выводится как есть, подсвечивается
   (.stock-negative), статичная подсказка сборщику — в warnbar страницы.
   ========================================================================== */
(function () {
  'use strict';

  function $(id) { return document.getElementById(id); }
  /* общие утилиты — assets/js/util.js (v0.14.0, фикс F32: одна копия на проект) */
  var esc = SiskuUtil.esc;
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
    $('asm-warn').hidden = true;
    if (!db) { showError('База не подключена: ' + (dbError || 'заполните assets/js/config.js')); return; }

    db.rpc('draft_assembly_bundle').then(function (res) {
      if (res.error) throw res.error;
      var d = res.data;
      var stock = {};
      var quarantine = {};   /* v0.16.0 (скрипт 23): бандл v2 — остатки с карантином */
      (d.stock || []).forEach(function (v) {
        stock[v.id] = v.stock;
        quarantine[v.id] = Number(v.quarantine_qty || 0);
      });
      if (!(d.orders || []).length) { showEmpty(); $('asm-body').innerHTML = ''; return; }
      render(d.orders, d.items || [], stock, quarantine);
    }).catch(function (e) { showError('Ошибка загрузки: ' + e.message); });
  }

  function render(orders, items, stock, quarantine) {
    $('asm-loading').hidden = true;
    $('asm-empty').hidden = true;
    var byOrder = {};
    items.forEach(function (i) { (byOrder[i.order_id] = byOrder[i.order_id] || []).push(i); });

    /* сигнализация: варианты с остатком < 3 среди собираемых */
    var low = {};
    items.forEach(function (i) {
      var st = stock[i.variant_id];
      if (st != null && st < 3) low[i.variant_id] = true;
    });
    var lowCount = Object.keys(low).length;
    if (lowCount) {
      $('asm-warn').hidden = false;
      $('asm-warn').textContent = '⚠ После сборки остаток менее 3 шт: ' + lowCount +
        ' товар(ов) — проверьте закупку (отмечены в таблице).';
    }

    var html = '';
    orders.forEach(function (o) {
      var list = byOrder[o.id] || [];
      if (!list.length) return;
      list.forEach(function (i, idx) {
        var st = stock[i.variant_id];
        var short = st != null && st < i.quantity;
        var lowStock = st != null && st < 3;
        /* v0.20.0 (Д5/7.1, АН-21 вариант (б)): после проведения инвентаризации
           минус/ноль остатка — штатное состояние: число выводится как есть,
           подсвечивается (.stock-negative), сборщик сообщает владельцу */
        var negative = st != null && st <= 0;
        html += '<tr data-order="' + o.id + '">' +
          (idx === 0
            ? '<td rowspan="' + list.length + '"><b>№ ' + o.id + '</b>' +
              '<div class="muted" style="font-size:12px">' + new Date(o.created_at).toLocaleDateString('ru-RU') + '</div></td>' +
              '<td rowspan="' + list.length + '" class="muted" style="font-size:13px">' + esc(o.comment || '—') + '</td>'
            : '') +
          '<td>' + esc(i.title_snapshot) + '</td>' +
          '<td class="muted">' + esc(i.variant_snapshot || '—') + '</td>' +
          '<td class="tabular">' + i.quantity + '</td>' +
          '<td class="tabular' + (negative ? ' stock-negative' : (lowStock ? ' low-stock' : '')) + '"' +
            (negative ? ' title="Нулевой или отрицательный остаток — расхождение с резервом (проведённая инвентаризация): сообщите владельцу"'
              : (short ? ' title="Остатка меньше, чем нужно в заказе"' : (lowStock ? ' title="Остаток менее 3 шт"' : ''))) + '>' +
            (st != null ? st + (negative ? ' ‼' : (lowStock ? ' ⚠' : '')) : '—') +
            /* v0.16.0 (фикс F51): единицы в карантине — не продаются, ждут осмотра */
            (quarantine && quarantine[i.variant_id]
              ? ' <span class="asm-quarantine" title="В карантине, требует осмотра (возврат)">+' + quarantine[i.variant_id] + ' кар.</span>'
              : '') + '</td>' +
          (idx === 0
            ? '<td rowspan="' + list.length + '"><button class="btn" data-ship="' + o.id + '" style="min-height:34px;padding:0 14px">→ Отправлен</button></td>'
            : '') +
        '</tr>';
      });
    });
    $('asm-body').innerHTML = html || '<tr><td colspan="7" class="muted">Нет позиций</td></tr>';
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;
    if (window.initAdminTheme) window.initAdminTheme();
    $('btn-logout').addEventListener('click', function () { if (window.mockLogout) window.mockLogout(); });
    $('btn-refresh').addEventListener('click', load);

    /* подсветка всей группы строк заказа при наведении (rowspan-таблица).
       фикс F10 (v0.14.0): блок был случайно вклеен ВНУТРЬ .then() колбэка
       RPC «→ Отправлен» — подсветка не работала до первой успешной отгрузки,
       а каждая отгрузка добавляла ещё пару слушателей. Теперь вешается
       один раз при открытии страницы (пункт чек-листа волны: hover работает
       сразу). */
    var asmBody = $('asm-body');
    function setGroup(gid) {
      asmBody.querySelectorAll('tr.group-hover').forEach(function (r) { r.classList.remove('group-hover'); });
      if (gid) asmBody.querySelectorAll('tr[data-order="' + gid + '"]').forEach(function (r) { r.classList.add('group-hover'); });
    }
    asmBody.addEventListener('mouseover', function (e) {
      var tr = e.target.closest('tr[data-order]');
      setGroup(tr ? tr.getAttribute('data-order') : null);
    });
    asmBody.addEventListener('mouseleave', function () { setGroup(null); });

    /* перевод заказа из «Сборка» в следующий статус модели («Отправлен») */
    $('asm-body').addEventListener('click', function (e) {
      var b = e.target.closest('button[data-ship]');
      if (!b || b.disabled) return;
      var id = Number(b.getAttribute('data-ship'));
      b.disabled = true;
      b.textContent = 'Переводим…';
      db.rpc('admin_set_status', { p_order_id: id, p_status_code: 'shipped', p_changed_by: 'assembly' })
        .then(function (res) {
          if (res.error) { alert('Не удалось перевести статус: ' + res.error.message); b.disabled = false; b.textContent = '→ Отправлен'; return; }
          load();   /* список и остатки обновляются после отгрузки */
        })
        .catch(function (err) {
          alert('Ошибка сети: ' + err.message);
          b.disabled = false;
          b.textContent = '→ Отправлен';
        });
    });

    load();
  });
})();
