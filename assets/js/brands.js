/* ==========================================================================
   SISKU · brands.js — подраздел «Бренды» вкладки «Магазин» (v0.9.0-draft)
   CRUD брендов: создание, правка кликом по названию, активация,
   удаление с защитой FK (бренд с товарами база не отдаст), счётчик товаров.
   ========================================================================== */
(function () {
  'use strict';

  var state = { brands: [], counts: {}, editingId: null, saving: false };

  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function load() {
    $('brand-empty').hidden = true;
    $('brand-error').hidden = true;
    if (!db) {
      $('brand-error').hidden = false;
      $('brand-error').textContent = 'База не подключена: ' + (dbError || 'заполните assets/js/config.js');
      return;
    }
    Promise.all([
      db.from('brands').select('*').order('name'),
      db.from('products').select('brand_id')
    ]).then(function (res) {
      if (res[0].error) throw res[0].error;
      state.brands = res[0].data || [];
      state.counts = {};
      (res[1].data || []).forEach(function (p) {
        state.counts[p.brand_id] = (state.counts[p.brand_id] || 0) + 1;
      });
      render();
    }).catch(function (e) {
      $('brand-error').hidden = false;
      $('brand-error').textContent = 'Ошибка загрузки: ' + e.message;
    });
  }

  function render() {
    if (!state.brands.length) { $('brand-empty').hidden = false; $('brand-body').innerHTML = ''; return; }
    $('brand-body').innerHTML = state.brands.map(function (b) {
      return '<tr>' +
        '<td class="user-fio" data-edit="' + b.id + '" title="Открыть редактирование">' + esc(b.name) + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(b.country || '—') + '</td>' +
        '<td class="tabular">' + (state.counts[b.id] || 0) + '</td>' +
        '<td><button class="btn" data-toggle="' + b.id + '" style="min-height:32px;padding:0 12px">' +
          (b.is_active ? 'активен' : 'скрыт') + '</button></td>' +
        '<td><button class="btn" data-del="' + b.id + '" style="min-height:34px;padding:0 14px">Удалить</button></td>' +
      '</tr>';
    }).join('');
  }

  function openModal(id) {
    state.editingId = id || null;
    state.saving = false;
    $('bm-submit').disabled = false;
    var b = id ? state.brands.filter(function (x) { return x.id === id; })[0] : null;
    $('bm-title').textContent = b ? 'Бренд: ' + b.name : 'Новый бренд';
    $('bm-name').value = b ? b.name : '';
    $('bm-country').value = b ? (b.country || '') : '';
    $('bm-active').checked = b ? b.is_active : true;
    ['bm-name-err', 'bm-error'].forEach(function (x) { $(x).hidden = true; });
    $('brand-modal-backdrop').classList.add('open');
  }
  function closeModal() { $('brand-modal-backdrop').classList.remove('open'); }

  function save(e) {
    e.preventDefault();
    if (state.saving) return;
    var errBox = $('bm-error');
    errBox.hidden = true;
    var name = $('bm-name').value.trim();
    $('bm-name-err').hidden = true;
    if (name.length < 2) { $('bm-name-err').textContent = 'Укажите название'; $('bm-name-err').hidden = false; return; }
    state.saving = true;
    $('bm-submit').disabled = true;
    var row = { name: name, country: $('bm-country').value.trim() || null, is_active: $('bm-active').checked };
    var q = state.editingId
      ? db.from('brands').update(row).eq('id', state.editingId)
      : db.from('brands').insert(row);
    q.then(function (res) {
      state.saving = false;
      $('bm-submit').disabled = false;
      if (res.error) { errBox.textContent = res.error.message; errBox.hidden = false; return; }
      closeModal();
      load();
    }).catch(function (err) {
      state.saving = false;
      $('bm-submit').disabled = false;
      errBox.textContent = 'Ошибка сети: ' + err.message;
      errBox.hidden = false;
    });
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;
    if (window.initAdminTheme) window.initAdminTheme();
    $('btn-logout').addEventListener('click', function () { if (window.mockLogout) window.mockLogout(); });
    $('btn-refresh').addEventListener('click', load);
    $('btn-new-brand').addEventListener('click', function () { openModal(null); });
    $('brand-modal-close').addEventListener('click', closeModal);
    $('brand-modal-backdrop').addEventListener('click', function (e) { if (e.target === $('brand-modal-backdrop')) closeModal(); });
    $('brand-form').addEventListener('submit', save);
    $('brand-body').addEventListener('click', function (e) {
      var tg = e.target.closest('button[data-toggle]');
      if (tg) {
        var id = Number(tg.getAttribute('data-toggle'));
        var b = state.brands.filter(function (x) { return x.id === id; })[0];
        if (!b) return;
        tg.disabled = true;
        db.from('brands').update({ is_active: !b.is_active }).eq('id', id).then(function (res) {
          if (res.error) { alert('Не удалось переключить: ' + res.error.message); tg.disabled = false; return; }
          load();
        });
        return;
      }
      var del = e.target.closest('button[data-del]');
      if (del) {
        var id2 = Number(del.getAttribute('data-del'));
        var b2 = state.brands.filter(function (x) { return x.id === id2; })[0];
        if (!confirm('Удалить бренд ' + (b2 ? b2.name : '') + '? Бренд с товарами база удалить не даст.')) return;
        del.disabled = true;
        db.from('brands').delete().eq('id', id2).then(function (res) {
          if (res.error) { alert('Не удалось удалить: ' + res.error.message); del.disabled = false; return; }
          load();
        });
        return;
      }
      var ed = e.target.closest('[data-edit]');
      if (ed) openModal(Number(ed.getAttribute('data-edit')));
    });
    load();
  });
})();
