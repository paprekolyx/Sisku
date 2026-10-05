/* ==========================================================================
   SISKU · brands.js — подраздел «Бренды» вкладки «Магазин» (v0.9.0-draft)
   CRUD брендов: создание, правка кликом по названию, активация,
   удаление с защитой FK (бренд с товарами база не отдаст), счётчик товаров.
   v0.15.0 (правка 2.14): клик по счётчику товаров — модалка со списком
   связанных товаров и фильтром («посмотреть, что мешает» удалить бренд).
   ========================================================================== */
(function () {
  'use strict';

  var state = { brands: [], counts: {}, products: [], variants: {}, editingId: null, saving: false, prodsBrandId: null };

  function $(id) { return document.getElementById(id); }
  /* общие утилиты — assets/js/util.js (v0.14.0, фикс F32: одна копия на проект) */
  var esc = SiskuUtil.esc, money = SiskuUtil.money;

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
      /* правка 2.14 (v0.15.0): поля товаров и варианты — для модалки связей */
      db.from('products').select('id,article,name,price,is_active,brand_id'),
      db.from('product_variants').select('product_id,label,stock')
    ]).then(function (res) {
      res.forEach(function (r) { if (r.error) throw r.error; });
      state.brands = res[0].data || [];
      state.products = res[1].data || [];
      state.variants = {};
      (res[2].data || []).forEach(function (v) {
        (state.variants[v.product_id] = state.variants[v.product_id] || []).push(v);
      });
      state.counts = {};
      state.products.forEach(function (p) {
        if (p.brand_id != null) state.counts[p.brand_id] = (state.counts[p.brand_id] || 0) + 1;
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
        '<td class="tabular">' + (state.counts[b.id]
          ? '<button class="count-link" data-brandprods="' + b.id + '" title="Показать товары бренда">' + state.counts[b.id] + '</button>'
          : '0') + '</td>' +
        '<td><button class="btn" data-toggle="' + b.id + '" style="min-height:32px;padding:0 12px">' +
          (b.is_active ? 'активен' : 'скрыт') + '</button></td>' +
        '<td><button class="btn" data-del="' + b.id + '" style="min-height:34px;padding:0 14px">Удалить</button></td>' +
      '</tr>';
    }).join('');
  }

  /* ---------- товары бренда (правка 2.14) ---------- */
  function openBrandProds(id) {
    var b = state.brands.filter(function (x) { return x.id === id; })[0];
    state.prodsBrandId = id;
    $('bp-title').textContent = 'Товары бренда: ' + (b ? b.name : '№ ' + id);
    $('bp-filter').value = '';
    renderBrandProds();
    $('brandprods-modal-backdrop').classList.add('open');
  }
  function renderBrandProds() {
    var q = $('bp-filter').value.trim().toLowerCase();
    var list = state.products.filter(function (p) {
      if (p.brand_id !== state.prodsBrandId) return false;
      if (q && (p.name + ' ' + p.article).toLowerCase().indexOf(q) === -1) return false;
      return true;
    });
    $('bp-empty').hidden = list.length !== 0;
    $('bp-body').innerHTML = list.map(function (p) {
      var vs = state.variants[p.id] || [];
      var stock = vs.reduce(function (s, v) { return s + v.stock; }, 0);
      var vars = vs.length
        ? vs.map(function (v) { return esc(v.label) + ' (' + v.stock + ')'; }).join(', ')
        : '<span class="muted">—</span>';
      return '<tr>' +
        '<td>' + esc(p.name) + '<div class="muted" style="font-size:12px">' + esc(p.article) + '</div></td>' +
        '<td class="muted" style="font-size:12.5px">' + vars + '</td>' +
        '<td class="tabular" style="text-align:right">' + money(p.price) + '</td>' +
        '<td class="tabular' + (stock < 3 ? ' low-stock' : '') + '" style="text-align:right">' + stock + '</td>' +
        '<td>' + (p.is_active ? '<span class="role-pill" data-role="admin">активен</span>' : '<span class="role-pill">скрыт</span>') + '</td>' +
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
    /* правка 2.14: клик по счётчику — модалка товаров бренда */
    $('bp-filter').addEventListener('input', renderBrandProds);
    $('bp-modal-close').addEventListener('click', function () { $('brandprods-modal-backdrop').classList.remove('open'); });
    $('brandprods-modal-backdrop').addEventListener('click', function (e) { if (e.target === $('brandprods-modal-backdrop')) $('brandprods-modal-backdrop').classList.remove('open'); });
    $('brand-body').addEventListener('click', function (e) {
      var bp = e.target.closest('button[data-brandprods]');
      if (bp) { openBrandProds(Number(bp.getAttribute('data-brandprods'))); return; }
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
