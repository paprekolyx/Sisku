/* ==========================================================================
   SISKU · looks.js — подраздел «Комплекты» вкладки «Магазин» (v0.10.0-draft)
   CRUD луков: название, описание, скидка комплекта, активность,
   состав из конкретных товаров с вариантами. Витрина показывает активные
   луки в разделе «Комплекты» (до v0.15.0 — «Готовые образы», правка 2.7)
   и умеет добавлять комплект в корзину целиком; скидку пересчитывает сервер
   в create_order (проверка полноты корзины).
   v0.15.0 (правка 2.1-Б): сохранение — ОДНИМ RPC draft_save_look (скрипт 17):
   комплект и состав в одной транзакции; при ошибке вставки позиций комплект
   больше не остаётся в таблице без состава (баг записки 1).
   ========================================================================== */
(function () {
  'use strict';

  var state = {
    looks: [], items: {}, products: [], variants: {},
    editingId: null, saving: false
  };

  function $(id) { return document.getElementById(id); }
  /* общие утилиты — assets/js/util.js (v0.14.0, фикс F32: одна копия на проект) */
  var esc = SiskuUtil.esc;
  function productName(id) { var p = state.products.filter(function (x) { return x.id === id; })[0]; return p ? p.name : '—'; }
  function variantLabel(pid, vid) {
    var list = state.variants[pid] || [];
    var v = list.filter(function (x) { return x.id === vid; })[0];
    return v ? v.label : '—';
  }

  function load() {
    $('look-empty').hidden = true;
    $('look-error').hidden = true;
    if (!db) {
      $('look-error').hidden = false;
      $('look-error').textContent = 'База не подключена: ' + (dbError || 'заполните assets/js/config.js');
      return;
    }
    Promise.all([
      db.from('looks').select('*').order('id', { ascending: false }),
      db.from('look_items').select('*').order('sort_order'),
      db.from('products').select('*').order('name'),
      db.from('product_variants').select('*').order('sort_order')
    ]).then(function (res) {
      res.forEach(function (r) { if (r.error) throw r.error; });
      state.looks = res[0].data || [];
      state.items = {};
      (res[1].data || []).forEach(function (i) {
        (state.items[i.look_id] = state.items[i.look_id] || []).push(i);
      });
      state.products = res[2].data || [];
      state.variants = {};
      (res[3].data || []).forEach(function (v) {
        (state.variants[v.product_id] = state.variants[v.product_id] || []).push(v);
      });
      render();
    }).catch(function (e) {
      $('look-error').hidden = false;
      $('look-error').textContent = 'Ошибка загрузки: ' + e.message;
    });
  }

  function render() {
    if (!state.looks.length) { $('look-empty').hidden = false; $('look-body').innerHTML = ''; return; }
    $('look-body').innerHTML = state.looks.map(function (l) {
      var items = state.items[l.id] || [];
      var состав = items.slice(0, 3).map(function (i) { return productName(i.product_id); }).join(', ');
      if (items.length > 3) состав += '…';
      return '<tr>' +
        '<td class="user-fio" data-edit="' + l.id + '" title="Открыть редактирование">' + esc(l.title) + '</td>' +
        '<td class="muted" style="font-size:13px">' + (состав ? esc(состав) + ' (' + items.length + ')' : 'пусто') + '</td>' +
        '<td class="tabular">' + (l.discount_percent > 0 ? '−' + l.discount_percent + '%' : '—') + '</td>' +
        '<td><button class="btn" data-toggle="' + l.id + '" style="min-height:32px;padding:0 12px">' + (l.is_active ? 'активен' : 'скрыт') + '</button></td>' +
        '<td><button class="btn" data-del="' + l.id + '" style="min-height:34px;padding:0 14px">Удалить</button></td>' +
      '</tr>';
    }).join('');
  }

  /* ---------- редактор состава ---------- */
  function addRow(productId, variantId) {
    var row = document.createElement('div');
    row.className = 'var-row look-row';
    row.style.gridTemplateColumns = '1.2fr 1fr 44px';
    var opts = '<option value="">— товар —</option>' + state.products.map(function (p) {
      return '<option value="' + p.id + '"' + (String(p.id) === String(productId) ? ' selected' : '') + '>' + esc(p.name) + '</option>';
    }).join('');
    row.innerHTML = '<select class="look-prod">' + opts + '</select>' +
      '<select class="look-var"></select>' +
      '<button type="button" class="btn ghost small look-del" title="Убрать из комплекта">×</button>';
    function fillVars(sel) {
      var pid = Number(row.querySelector('.look-prod').value || 0);
      var vs = state.variants[pid] || [];
      row.querySelector('.look-var').innerHTML = '<option value="">— вся размерная сетка —</option>' + vs.map(function (v) {
        return '<option value="' + v.id + '"' + (String(v.id) === String(sel) ? ' selected' : '') + '>' + esc(v.label) + ' (' + v.stock + ' шт.)</option>';
      }).join('');
      if (window.enhanceSelects) enhanceSelects(row);
    }
    fillVars(variantId);
    row.querySelector('.look-prod').addEventListener('change', function () { fillVars(''); });
    row.querySelector('.look-del').addEventListener('click', function () { row.remove(); });
    $('lk-items').appendChild(row);
    if (window.enhanceSelects) enhanceSelects(row);
  }

  function openModal(id) {
    state.editingId = id || null;
    state.saving = false;
    $('lk-submit').disabled = false;
    var l = id ? state.looks.filter(function (x) { return x.id === id; })[0] : null;
    $('lk-title-h').textContent = l ? 'Комплект: ' + l.title : 'Новый комплект';
    $('lk-title').value = l ? l.title : '';
    $('lk-desc').value = l ? (l.description || '') : '';
    $('lk-discount').value = l ? (l.discount_percent || 0) : 0;
    $('lk-active').checked = l ? l.is_active : true;
    ['lk-title-err', 'lk-items-err', 'lk-error'].forEach(function (x) { $(x).hidden = true; });
    $('lk-items').innerHTML = '';
    var items = l ? (state.items[l.id] || []) : [];
    if (items.length) items.forEach(function (i) { addRow(i.product_id, i.variant_id); });
    else addRow(null, null);
    $('look-modal-backdrop').classList.add('open');
  }
  function closeModal() { $('look-modal-backdrop').classList.remove('open'); }

  function save(e) {
    e.preventDefault();
    if (state.saving) return;
    var errBox = $('lk-error');
    errBox.hidden = true;
    var title = $('lk-title').value.trim();
    $('lk-title-err').hidden = true;
    $('lk-items-err').hidden = true;
    if (title.length < 3) { $('lk-title-err').textContent = 'Укажите название комплекта'; $('lk-title-err').hidden = false; return; }
    var rows = [];
    $('lk-items').querySelectorAll('.look-row').forEach(function (r) {
      var pid = Number(r.querySelector('.look-prod').value || 0);
      var vid = Number(r.querySelector('.look-var').value || 0);
      if (pid) rows.push({ product_id: pid, variant_id: vid || null });
    });
    if (!rows.length) { $('lk-items-err').textContent = 'Добавьте в комплект хотя бы один товар'; $('lk-items-err').hidden = false; return; }

    state.saving = true;
    $('lk-submit').disabled = true;
    /* правка 2.1-Б (v0.15.0, скрипт 17): комплект + состав — один RPC,
       одна транзакция. Ошибка 42883 (функции ещё нет) — база не обновлена,
       friendlyDbError подскажет выполнить SQL-скрипт последней волны. */
    db.rpc('draft_save_look', { p: {
      id: state.editingId || null,
      title: title,
      description: $('lk-desc').value.trim() || null,
      discount_percent: Number($('lk-discount').value || 0),
      is_active: $('lk-active').checked,
      items: rows.map(function (r) {
        return { product_id: r.product_id, variant_id: r.variant_id };
      })
    } }).then(function (res) {
      state.saving = false;
      $('lk-submit').disabled = false;
      if (res.error) { errBox.textContent = SiskuUtil.friendlyDbError(res.error); errBox.hidden = false; return; }
      closeModal();
      load();
    }).catch(function (err) {
      state.saving = false;
      $('lk-submit').disabled = false;
      errBox.textContent = 'Ошибка сети: ' + err.message;
      errBox.hidden = false;
    });
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;
    if (window.initAdminTheme) window.initAdminTheme();
    $('btn-logout').addEventListener('click', function () { if (window.mockLogout) window.mockLogout(); });
    $('btn-refresh').addEventListener('click', load);
    $('btn-new-look').addEventListener('click', function () { openModal(null); });
    $('lk-item-add').addEventListener('click', function () { addRow(null, null); });
    $('look-modal-close').addEventListener('click', closeModal);
    $('look-modal-backdrop').addEventListener('click', function (e) { if (e.target === $('look-modal-backdrop')) closeModal(); });
    $('look-form').addEventListener('submit', save);
    $('look-body').addEventListener('click', function (e) {
      var tg = e.target.closest('button[data-toggle]');
      if (tg) {
        var id = Number(tg.getAttribute('data-toggle'));
        var l = state.looks.filter(function (x) { return x.id === id; })[0];
        if (!l) return;
        tg.disabled = true;
        db.from('looks').update({ is_active: !l.is_active }).eq('id', id).then(function (res) {
          if (res.error) { alert('Не удалось переключить: ' + res.error.message); tg.disabled = false; return; }
          load();
        });
        return;
      }
      var del = e.target.closest('button[data-del]');
      if (del) {
        var id2 = Number(del.getAttribute('data-del'));
        var l2 = state.looks.filter(function (x) { return x.id === id2; })[0];
        if (!confirm('Удалить комплект «' + (l2 ? l2.title : '') + '»? Состав удалится вместе с ним.')) return;
        del.disabled = true;
        db.from('looks').delete().eq('id', id2).then(function (res) {
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
