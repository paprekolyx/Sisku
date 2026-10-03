/* ==========================================================================
   SISKU · clients.js — страница «Клиенты» (v0.11.0-draft, МОК без базы)
   Демонстрация интерфейса клиентской базы: таблица (ФИО, телефон, e-mail,
   даты первого/последнего заказов, сумма, количество) и карточка клиента
   с редактированием личных данных и комментарием.
   Данные — мок: сохранения живут до перезагрузки страницы.
   Реальная реализация (агрегаты по orders + история заказов в карточке) —
   см. docs/feature-proposals.md, волна 3.
   ========================================================================== */
(function () {
  'use strict';

  var state = {
    clients: [
      {
        id: 1,
        fio: 'Смирнова Анна Сергеевна',
        phone: '+7 (916) 240-18-36',
        email: 'a.smirnova@example.ru',
        first: '2026-08-14',
        last: '2026-09-21',
        sum: 184300,
        count: 4,
        comment: 'Берёт пальто на размер меньше — любит приталенную посадку. Предпочитает доставку в шоурум.'
      }
    ],
    editingId: null
  };

  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }
  function money(n) { return new Intl.NumberFormat('ru-RU').format(Math.round(Number(n || 0))) + ' ₽'; }
  function fmtDate(d) { return d ? new Date(d + 'T00:00:00').toLocaleDateString('ru-RU') : '—'; }

  function render() {
    var q = $('cl-search').value.trim().toLowerCase();
    var list = state.clients.filter(function (c) {
      if (!q) return true;
      return (c.fio + ' ' + (c.phone || '') + ' ' + (c.email || '')).toLowerCase().indexOf(q) !== -1;
    });
    $('cl-empty').hidden = list.length !== 0;
    $('cl-body').innerHTML = list.map(function (c) {
      return '<tr>' +
        '<td class="user-fio" data-edit="' + c.id + '" title="Открыть карточку клиента">' + esc(c.fio) + '</td>' +
        '<td class="tabular muted">' + esc(c.phone || '—') + '</td>' +
        '<td class="muted">' + esc(c.email || '—') + '</td>' +
        '<td class="tabular muted">' + fmtDate(c.first) + '</td>' +
        '<td class="tabular muted">' + fmtDate(c.last) + '</td>' +
        '<td class="tabular">' + money(c.sum) + '</td>' +
        '<td class="tabular">' + c.count + '</td>' +
      '</tr>';
    }).join('');
  }

  function openCard(id) {
    var c = state.clients.filter(function (x) { return x.id === id; })[0];
    if (!c) return;
    state.editingId = id;
    $('clm-title').textContent = c.fio;
    $('clm-stats').textContent = 'Заказов: ' + c.count + ' · на сумму ' + money(c.sum) +
      ' · первый ' + fmtDate(c.first) + ' · последний ' + fmtDate(c.last);
    $('clm-fio').value = c.fio;
    $('clm-phone').value = c.phone || '';
    $('clm-email').value = c.email || '';
    $('clm-comment').value = c.comment || '';
    $('cl-modal-backdrop').classList.add('open');
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;
    if (window.initAdminTheme) window.initAdminTheme();
    $('btn-logout').addEventListener('click', function () { if (window.mockLogout) window.mockLogout(); });
    $('btn-refresh').addEventListener('click', render);
    $('cl-search').addEventListener('input', render);
    $('cl-body').addEventListener('click', function (e) {
      var ed = e.target.closest('[data-edit]');
      if (ed) openCard(Number(ed.getAttribute('data-edit')));
    });
    $('cl-modal-close').addEventListener('click', function () { $('cl-modal-backdrop').classList.remove('open'); });
    $('cl-modal-backdrop').addEventListener('click', function (e) {
      if (e.target === $('cl-modal-backdrop')) $('cl-modal-backdrop').classList.remove('open');
    });
    $('cl-form').addEventListener('submit', function (e) {
      e.preventDefault();
      var c = state.clients.filter(function (x) { return x.id === state.editingId; })[0];
      if (!c) return;
      c.fio = $('clm-fio').value.trim() || c.fio;
      c.phone = $('clm-phone').value.trim();
      c.email = $('clm-email').value.trim();
      c.comment = $('clm-comment').value.trim();
      $('cl-modal-backdrop').classList.remove('open');
      render();
      /* мок: в боевой версии здесь будет update таблицы clients + audit_log */
      alert('Сохранено (демонстрационные данные: до боевой версии клиентская база живёт только в этой вкладке).');
    });
    render();
  });
})();
