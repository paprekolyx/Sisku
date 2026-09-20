/* ==========================================================================
   SISKU · shop.js — раздел «Магазин»: промокоды (v0.6.0-draft)
   CRUD промокодов черновика. Проверку и применение кодов при заказе
   выполняет сервер (check_promo / create_order) — клиент не считает скидки.
   Раздел будет расширяться (акции, комплекты, справочники).
   ========================================================================== */
(function () {
  'use strict';

  var state = { promos: [], editingId: null, saving: false };

  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }
  function money(n) { return new Intl.NumberFormat('ru-RU').format(Math.round(Number(n || 0))) + ' ₽'; }
  function fmtDate(d) { return d ? new Date(d).toLocaleDateString('ru-RU') : '—'; }

  function load() {
    $('promo-loading').hidden = false;
    $('promo-empty').hidden = true;
    $('promo-error').hidden = true;
    if (!db) {
      $('promo-loading').hidden = true;
      $('promo-error').hidden = false;
      $('promo-error').textContent = 'База не подключена: ' + (dbError || 'заполните assets/js/config.js');
      return;
    }
    db.from('promo_codes').select('*').order('id', { ascending: false }).then(function (res) {
      $('promo-loading').hidden = true;
      if (res.error) {
        $('promo-error').hidden = false;
        $('promo-error').textContent = res.error.message;
        return;
      }
      state.promos = res.data || [];
      if (!state.promos.length) { $('promo-empty').hidden = false; $('promo-body').innerHTML = ''; return; }
      $('promo-body').innerHTML = state.promos.map(function (p) {
        var discount = p.discount_type === 'percent'
          ? '−' + p.discount_value + '%'
          : '−' + money(p.discount_value);
        var period = (p.valid_from || p.valid_until)
          ? fmtDate(p.valid_from) + ' — ' + fmtDate(p.valid_until)
          : 'бессрочно';
        var limit = p.usage_limit != null ? (p.usage_limit + ' / ' + p.used_count) : ('без лимита / ' + p.used_count);
        return '<tr>' +
          '<td><b>' + esc(p.code) + '</b></td>' +
          '<td>' + discount + '</td>' +
          '<td class="tabular muted">' + (p.min_order_amount > 0 ? money(p.min_order_amount) : '—') + '</td>' +
          '<td class="muted" style="font-size:13px">' + period + '</td>' +
          '<td class="tabular muted">' + limit + '</td>' +
          '<td>' + (p.is_active
              ? '<span class="role-pill" data-role="admin">активен</span>'
              : '<span class="role-pill">отключён</span>') + '</td>' +
          '<td style="white-space:nowrap">' +
            '<button class="btn" data-edit="' + p.id + '" style="min-height:34px;padding:0 12px;margin-right:6px">Изменить</button>' +
            '<button class="btn" data-toggle="' + p.id + '" style="min-height:34px;padding:0 12px">' + (p.is_active ? 'Отключить' : 'Включить') + '</button>' +
          '</td>' +
        '</tr>';
      }).join('');
    });
  }

  function openModal(id) {
    state.editingId = id || null;
    state.saving = false;
    $('pc-submit').disabled = false;
    var p = id ? state.promos.filter(function (x) { return x.id === id; })[0] : null;
    $('pm-title').textContent = p ? 'Промокод ' + p.code : 'Новый промокод';
    $('pc-code').value = p ? p.code : '';
    $('pc-code').disabled = !!p;                 /* код не переименовываем задним числом */
    $('pc-type').value = p ? p.discount_type : 'percent';
    $('pc-value').value = p ? p.discount_value : '';
    $('pc-min').value = p ? (p.min_order_amount || '') : '';
    $('pc-from').value = p && p.valid_from ? p.valid_from : '';
    $('pc-until').value = p && p.valid_until ? p.valid_until : '';
    $('pc-limit').value = p && p.usage_limit != null ? p.usage_limit : '';
    $('pc-active').checked = p ? p.is_active : true;
    ['pc-code-err', 'pc-value-err', 'pc-error'].forEach(function (x) { $(x).hidden = true; });
    $('promo-modal-backdrop').classList.add('open');
    if (window.enhanceSelects) enhanceSelects($('promo-modal-backdrop'));
  }
  function closeModal() { $('promo-modal-backdrop').classList.remove('open'); }

  function save(e) {
    e.preventDefault();
    if (state.saving) return;
    var errBox = $('pc-error');
    errBox.hidden = true;
    var code = $('pc-code').value.trim().toUpperCase();
    var type = $('pc-type').value;
    var value = Number($('pc-value').value);
    var min = Number($('pc-min').value || 0);
    var from = $('pc-from').value || null;
    var until = $('pc-until').value || null;
    var limit = $('pc-limit').value ? Number($('pc-limit').value) : null;
    var active = $('pc-active').checked;
    var ok = true;
    $('pc-code-err').hidden = true; $('pc-value-err').hidden = true;
    if (!state.editingId && !/^[A-ZА-Я0-9_-]{3,20}$/.test(code)) {
      $('pc-code-err').textContent = 'Код: 3–20 символов, буквы/цифры/дефис (например, SISKU10)';
      $('pc-code-err').hidden = false; ok = false;
    }
    if (!value || value <= 0 || (type === 'percent' && value > 100)) {
      $('pc-value-err').textContent = type === 'percent' ? 'Процент: от 1 до 100' : 'Сумма скидки: больше 0';
      $('pc-value-err').hidden = false; ok = false;
    }
    if (from && until && from > until) {
      errBox.textContent = 'Дата «по» раньше даты «с»';
      errBox.hidden = false; ok = false;
    }
    if (!ok) return;

    state.saving = true;
    $('pc-submit').disabled = true;
    var row = {
      discount_type: type, discount_value: value, min_order_amount: min,
      valid_from: from, valid_until: until, usage_limit: limit, is_active: active
    };
    var q = state.editingId
      ? db.from('promo_codes').update(row).eq('id', state.editingId)
      : db.from('promo_codes').insert(Object.assign({ code: code, used_count: 0 }, row));
    q.then(function (res) {
      state.saving = false;
      $('pc-submit').disabled = false;
      if (res.error) { errBox.textContent = res.error.message; errBox.hidden = false; return; }
      closeModal();
      load();
    }).catch(function (err) {
      state.saving = false;
      $('pc-submit').disabled = false;
      errBox.textContent = 'Ошибка сети: ' + err.message;
      errBox.hidden = false;
    });
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;
    if (window.initAdminTheme) window.initAdminTheme();
    $('btn-logout').addEventListener('click', function () { if (window.mockLogout) window.mockLogout(); });
    $('btn-refresh').addEventListener('click', load);
    $('btn-new-promo').addEventListener('click', function () { openModal(null); });
    $('promo-modal-close').addEventListener('click', closeModal);
    $('promo-modal-backdrop').addEventListener('click', function (e) { if (e.target === $('promo-modal-backdrop')) closeModal(); });
    $('promo-form').addEventListener('submit', save);
    $('promo-body').addEventListener('click', function (e) {
      var ed = e.target.closest('button[data-edit]');
      if (ed) { openModal(Number(ed.getAttribute('data-edit'))); return; }
      var tg = e.target.closest('button[data-toggle]');
      if (tg) {
        var id = Number(tg.getAttribute('data-toggle'));
        var p = state.promos.filter(function (x) { return x.id === id; })[0];
        if (!p) return;
        tg.disabled = true;
        db.from('promo_codes').update({ is_active: !p.is_active }).eq('id', id).then(function (res) {
          if (res.error) { alert('Не удалось изменить статус: ' + res.error.message); tg.disabled = false; return; }
          load();
        });
      }
    });
    load();
  });
})();
