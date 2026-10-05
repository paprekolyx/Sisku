/* ==========================================================================
   SISKU · manage.js — подраздел «Оплата и доставка» вкладки «Управление»
   (v0.9.0-draft). Список и редактирование delivery_methods / payment_methods:
   название, код, цены (вилка), активность. История заказов не страдает:
   способы отключаются (is_active), а удаление (с v0.14.0 — настоящие
   DELETE-политики скрипта 16, фикс F09) блокирует FK, если способ уже
   использован в заказах.
   ========================================================================== */
(function () {
  'use strict';

  var state = {
    deliveries: [], payments: [],
    kind: 'delivery',          /* какой справочник правим в модалке */
    editingId: null, saving: false
  };

  function $(id) { return document.getElementById(id); }
  /* общие утилиты — assets/js/util.js (v0.14.0, фикс F32: одна копия на проект) */
  var esc = SiskuUtil.esc, money = SiskuUtil.money;

  function load() {
    $('mng-error').hidden = true;
    if (!db) {
      $('mng-error').hidden = false;
      $('mng-error').textContent = 'База не подключена: ' + (dbError || 'заполните assets/js/config.js');
      return;
    }
    Promise.all([
      db.from('delivery_methods').select('*').order('id'),
      db.from('payment_methods').select('*').order('id')
    ]).then(function (res) {
      if (res[0].error) throw res[0].error;
      if (res[1].error) throw res[1].error;
      state.deliveries = res[0].data || [];
      state.payments = res[1].data || [];
      render();
    }).catch(function (e) {
      $('mng-error').hidden = false;
      $('mng-error').textContent = 'Ошибка загрузки: ' + e.message;
    });
  }

  function render() {
    $('del-body').innerHTML = state.deliveries.map(function (m) {
      return '<tr>' +
        '<td class="user-fio" data-edit="' + m.id + '" data-kind="delivery" title="Открыть редактирование">' + esc(m.name) + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(m.code) + '</td>' +
        '<td class="tabular">' + (m.base_price > 0 ? money(m.base_price) : 'бесплатно') + '</td>' +
        '<td class="tabular muted">' + (m.price_max ? money(m.price_max) : '—') + '</td>' +
        '<td><button class="btn" data-toggle="' + m.id + '" data-kind="delivery" style="min-height:32px;padding:0 12px">' +
          (m.is_active ? 'активен' : 'отключён') + '</button></td>' +
        '<td><button class="btn" data-del="' + m.id + '" data-kind="delivery" style="min-height:34px;padding:0 14px">Удалить</button></td>' +
      '</tr>';
    }).join('');
    $('pay-body').innerHTML = state.payments.map(function (m) {
      return '<tr>' +
        '<td class="user-fio" data-edit="' + m.id + '" data-kind="payment" title="Открыть редактирование">' + esc(m.name) + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(m.code) + '</td>' +
        '<td><button class="btn" data-toggle="' + m.id + '" data-kind="payment" style="min-height:32px;padding:0 12px">' +
          (m.is_active ? 'активен' : 'отключён') + '</button></td>' +
        '<td><button class="btn" data-del="' + m.id + '" data-kind="payment" style="min-height:34px;padding:0 14px">Удалить</button></td>' +
      '</tr>';
    }).join('');
  }

  function openModal(kind, id) {
    state.kind = kind;
    state.editingId = id || null;
    state.saving = false;
    $('mm-submit').disabled = false;
    var list = kind === 'delivery' ? state.deliveries : state.payments;
    var m = id ? list.filter(function (x) { return x.id === id; })[0] : null;
    $('mm-title').textContent = (m ? 'Правка: ' : 'Новый способ ') + (kind === 'delivery' ? 'доставки' : 'оплаты') + (m ? m.name : '');
    $('mm-name').value = m ? m.name : '';
    $('mm-code').value = m ? m.code : '';
    $('mm-code').disabled = !!m;             /* код не меняем задним числом */
    $('mm-base').value = m && kind === 'delivery' ? (m.base_price || '') : '';
    $('mm-max').value = m && kind === 'delivery' && m.price_max ? m.price_max : '';
    $('mm-active').checked = m ? m.is_active : true;
    $('mm-prices').hidden = kind !== 'delivery';
    ['mm-name-err', 'mm-code-err', 'mm-error'].forEach(function (x) { $(x).hidden = true; });
    $('mng-modal-backdrop').classList.add('open');
  }
  function closeModal() { $('mng-modal-backdrop').classList.remove('open'); }

  function save(e) {
    e.preventDefault();
    if (state.saving) return;
    var errBox = $('mm-error');
    errBox.hidden = true;
    var name = $('mm-name').value.trim();
    var code = $('mm-code').value.trim().toLowerCase();
    var ok = true;
    $('mm-name-err').hidden = true; $('mm-code-err').hidden = true;
    if (name.length < 3) { $('mm-name-err').textContent = 'Укажите название'; $('mm-name-err').hidden = false; ok = false; }
    if (!state.editingId && !/^[a-z0-9_-]{2,30}$/.test(code)) {
      $('mm-code-err').textContent = 'Код: латиница/цифры/дефис, 2–30 символов'; $('mm-code-err').hidden = false; ok = false;
    }
    if (!ok) return;
    state.saving = true;
    $('mm-submit').disabled = true;
    var table = state.kind === 'delivery' ? 'delivery_methods' : 'payment_methods';
    var row = { name: name, is_active: $('mm-active').checked };
    if (state.kind === 'delivery') {
      row.base_price = Number($('mm-base').value || 0);
      row.price_max = $('mm-max').value ? Number($('mm-max').value) : null;
      if (row.price_max != null && row.price_max < row.base_price) row.price_max = row.base_price;
    }
    if (!state.editingId) row.code = code;
    var q = state.editingId
      ? db.from(table).update(row).eq('id', state.editingId)
      : db.from(table).insert(row);
    q.then(function (res) {
      state.saving = false;
      $('mm-submit').disabled = false;
      if (res.error) { errBox.textContent = res.error.message; errBox.hidden = false; return; }
      closeModal();
      load();
    }).catch(function (err) {
      state.saving = false;
      $('mm-submit').disabled = false;
      errBox.textContent = 'Ошибка сети: ' + err.message;
      errBox.hidden = false;
    });
  }

  /* правка 2.11 (v0.15.0): manage.html#audit — панель-заглушка «Журнал действий и отмена» */
  function applyAuditHash() {
    var on = location.hash === '#audit';
    $('panel-audit').hidden = !on;
    $('panel-manage').hidden = on;
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;
    if (window.initAdminTheme) window.initAdminTheme();
    applyAuditHash();
    window.addEventListener('hashchange', applyAuditHash);
    $('btn-logout').addEventListener('click', function () { if (window.mockLogout) window.mockLogout(); });
    $('btn-refresh').addEventListener('click', load);
    $('btn-new-delivery').addEventListener('click', function () { openModal('delivery', null); });
    $('btn-new-payment').addEventListener('click', function () { openModal('payment', null); });
    $('mng-modal-close').addEventListener('click', closeModal);
    $('mng-modal-backdrop').addEventListener('click', function (e) { if (e.target === $('mng-modal-backdrop')) closeModal(); });
    $('mng-form').addEventListener('submit', save);

    document.querySelectorAll('tbody').forEach(function (tbody) {
      tbody.addEventListener('click', function (e) {
        var tg = e.target.closest('button[data-toggle]');
        if (tg) {
          var kind = tg.getAttribute('data-kind');
          var id = Number(tg.getAttribute('data-toggle'));
          var list = kind === 'delivery' ? state.deliveries : state.payments;
          var m = list.filter(function (x) { return x.id === id; })[0];
          if (!m) return;
          tg.disabled = true;
          var table = kind === 'delivery' ? 'delivery_methods' : 'payment_methods';
          db.from(table).update({ is_active: !m.is_active }).eq('id', id).then(function (res) {
            if (res.error) { alert('Не удалось переключить: ' + res.error.message); tg.disabled = false; return; }
            load();
          });
          return;
        }
        var del = e.target.closest('button[data-del]');
        if (del) {
          var kindD = del.getAttribute('data-kind');
          var idD = Number(del.getAttribute('data-del'));
          var listD = kindD === 'delivery' ? state.deliveries : state.payments;
          var mD = listD.filter(function (x) { return x.id === idD; })[0];
          var tableD = kindD === 'delivery' ? 'delivery_methods' : 'payment_methods';
          if (!confirm('Удалить способ «' + (mD ? mD.name : '') + '»? Способ, который уже используется в заказах, база удалить не даст.')) return;
          del.disabled = true;
          /* фикс F09 (v0.14.0): DELETE-политики добавлены скриптом 16 —
             удаление настоящее. .select() возвращает удалённые строки:
             пустой массив = строка не удалена (редкая гонка), FK (23503) =
             способ использован в заказах → предлагаем отключить */
          db.from(tableD).delete().eq('id', idD).select('id').then(function (res) {
            if (res.error) {
              alert(res.error.code === '23503'
                ? 'Способ «' + (mD ? mD.name : '') + '» используется в заказах — удалить нельзя. Отключите его кнопкой активности.'
                : 'Не удалось удалить: ' + res.error.message);
              del.disabled = false;
              return;
            }
            if (!res.data || !res.data.length) {
              alert('Способ не удалён: строка уже отсутствует в базе. Список обновлён.');
            }
            load();
          }).catch(function (err) { alert('Ошибка сети: ' + err.message); del.disabled = false; });
          return;
        }
        var ed = e.target.closest('[data-edit]');
        if (ed) openModal(ed.getAttribute('data-kind'), Number(ed.getAttribute('data-edit')));
      });
    });

    if (window.enhanceNumbers) enhanceNumbers(document.getElementById('mng-form'));
    load();
  });
})();
