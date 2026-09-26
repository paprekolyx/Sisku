/* ==========================================================================
   SISKU · categories.js — подраздел «Категории» вкладки «Магазин» (v0.9.0-draft)
   CRUD категорий каталога: создание, правка кликом по названию, авто-slug,
   удаление с защитой FK, счётчик товаров в категории.
   ========================================================================== */
(function () {
  'use strict';

  var state = { cats: [], catCounts: {}, editingCatId: null };

  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }
  function loadCats() {
    Promise.all([
      db.from('categories').select('*').order('id'),
      db.from('products').select('category_id')
    ]).then(function (res) {
      if (res[0].error) throw res[0].error;
      state.cats = res[0].data || [];
      state.catCounts = {};
      (res[1].data || []).forEach(function (p) {
        state.catCounts[p.category_id] = (state.catCounts[p.category_id] || 0) + 1;
      });
      renderCats();
    }).catch(function (e) {
      $('cat-empty').hidden = true;
      $('cat-body').innerHTML = '<tr><td colspan="5" class="muted">Ошибка: ' + esc(e.message) + '</td></tr>';
    });
  }
  function renderCats() {
    $('cat-empty').hidden = state.cats.length !== 0;
    $('cat-body').innerHTML = state.cats.map(function (c) {
      return '<tr>' +
        '<td class="user-fio" data-catedit="' + c.id + '" title="Открыть редактирование">' + esc(c.name) + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(c.slug) + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(c.description || '—') + '</td>' +
        '<td class="tabular">' + (state.catCounts[c.id] || 0) + '</td>' +
        '<td><button class="btn" data-catdel="' + c.id + '" style="min-height:34px;padding:0 14px">Удалить</button></td>' +
      '</tr>';
    }).join('');
  }
  function slugify(s) {
    var map = { 'а':'a','б':'b','в':'v','г':'g','д':'d','е':'e','ё':'e','ж':'zh','з':'z','и':'i','й':'y','к':'k','л':'l','м':'m','н':'n','о':'o','п':'p','р':'r','с':'s','т':'t','у':'u','ф':'f','х':'h','ц':'c','ч':'ch','ш':'sh','щ':'sch','ъ':'','ы':'y','ь':'','э':'e','ю':'yu','я':'ya' };
    return s.toLowerCase().split('').map(function (ch) {
      return map[ch] !== undefined ? map[ch] : ch;
    }).join('').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  }
  function openCatModal(id) {
    state.editingCatId = id || null;
    var c = id ? state.cats.filter(function (x) { return x.id === id; })[0] : null;
    $('cm-title').textContent = c ? 'Категория: ' + c.name : 'Новая категория';
    $('cm-name').value = c ? c.name : '';
    $('cm-slug').value = c ? c.slug : '';
    $('cm-desc').value = c ? (c.description || '') : '';
    ['cm-name-err', 'cm-slug-err', 'cm-error'].forEach(function (x) { $(x).hidden = true; });
    $('cat-modal-backdrop').classList.add('open');
  }
  function saveCat(e) {
    e.preventDefault();
    var errBox = $('cm-error');
    errBox.hidden = true;
    var name = $('cm-name').value.trim();
    var slug = $('cm-slug').value.trim() || slugify(name);
    var desc = $('cm-desc').value.trim() || null;
    var ok = true;
    $('cm-name-err').hidden = true; $('cm-slug-err').hidden = true;
    if (name.length < 2) { $('cm-name-err').textContent = 'Укажите название'; $('cm-name-err').hidden = false; ok = false; }
    if (!/^[a-z0-9-]{2,40}$/.test(slug)) { $('cm-slug-err').textContent = 'Slug: латиница/цифры/дефис, 2–40 (например, platya)'; $('cm-slug-err').hidden = false; ok = false; }
    if (!ok) return;
    var btn = $('cm-submit');
    btn.disabled = true;
    var row = { name: name, slug: slug, description: desc };
    var q = state.editingCatId
      ? db.from('categories').update(row).eq('id', state.editingCatId)
      : db.from('categories').insert(row);
    q.then(function (res) {
      btn.disabled = false;
      if (res.error) { errBox.textContent = res.error.message; errBox.hidden = false; return; }
      $('cat-modal-backdrop').classList.remove('open');
      loadCats();
    }).catch(function (err) {
      btn.disabled = false;
      errBox.textContent = 'Ошибка сети: ' + err.message;
      errBox.hidden = false;
    });
  }


  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;
    if (window.initAdminTheme) window.initAdminTheme();
    $('btn-logout').addEventListener('click', function () { if (window.mockLogout) window.mockLogout(); });
    $('btn-refresh').addEventListener('click', loadCats);
    $('btn-new-cat').addEventListener('click', function () { openCatModal(null); });
    $('cat-modal-close').addEventListener('click', function () { $('cat-modal-backdrop').classList.remove('open'); });
    $('cat-form').addEventListener('submit', saveCat);
    $('cm-name').addEventListener('input', function () {
      if (state.editingCatId) return;      /* авто-slug только при создании */
      $('cm-slug').value = slugify(this.value);
    });
    $('cat-body').addEventListener('click', function (e) {
      var del = e.target.closest('button[data-catdel]');
      if (del) {
        var id = Number(del.getAttribute('data-catdel'));
        var c = state.cats.filter(function (x) { return x.id === id; })[0];
        if (!confirm('Удалить категорию ' + (c ? c.name : '') + '? Категорию с товарами база удалить не даст.')) return;
        del.disabled = true;
        db.from('categories').delete().eq('id', id).then(function (res) {
          if (res.error) { alert('Не удалось удалить: ' + res.error.message); del.disabled = false; return; }
          loadCats();
        });
        return;
      }
      var ed = e.target.closest('[data-catedit]');
      if (ed) openCatModal(Number(ed.getAttribute('data-catedit')));
    });
    loadCats();
  });
})();
