/* ==========================================================================
   SISKU · categories.js — подраздел «Категории» вкладки «Магазин» (v0.9.0-draft)
   CRUD категорий каталога: создание, правка кликом по названию, авто-slug,
   удаление с защитой FK, счётчик товаров в категории.
   v0.15.0 (правка 2.14): клик по счётчику товаров — модалка со списком
   связанных товаров (название, вариант, цена, остаток, активность) и
   фильтром: FK-защита удаления объясняет «почему нельзя», а список
   показывает «что именно мешает».
   ========================================================================== */
(function () {
  'use strict';

  var state = { cats: [], catCounts: {}, products: [], variants: {}, editingCatId: null, prodsCatId: null };

  function $(id) { return document.getElementById(id); }
  /* общие утилиты — assets/js/util.js (v0.14.0, фикс F32: одна копия на проект) */
  var esc = SiskuUtil.esc, money = SiskuUtil.money;
  function loadCats() {
    /* фикс F31 (v0.14.0): guard неподключённой БД — общий паттерн плашки
       вместо непойманного TypeError (единственный модуль без guard'а) */
    if (!db) {
      $('cat-empty').hidden = true;
      $('cat-body').innerHTML = '<tr><td colspan="5" class="muted">База не подключена: ' +
        esc(dbError || 'заполните assets/js/config.js') + '</td></tr>';
      return;
    }
    Promise.all([
      db.from('categories').select('*').order('id'),
      /* правка 2.14 (v0.15.0): поля товаров и варианты — для модалки связей */
      db.from('products').select('id,article,name,price,is_active,category_id'),
      db.from('product_variants').select('product_id,label,stock')
    ]).then(function (res) {
      res.forEach(function (r) { if (r.error) throw r.error; });
      state.cats = res[0].data || [];
      state.products = res[1].data || [];
      state.variants = {};
      (res[2].data || []).forEach(function (v) {
        (state.variants[v.product_id] = state.variants[v.product_id] || []).push(v);
      });
      state.catCounts = {};
      state.products.forEach(function (p) {
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
        '<td class="tabular">' + (state.catCounts[c.id]
          ? '<button class="count-link" data-catprods="' + c.id + '" title="Показать товары категории">' + state.catCounts[c.id] + '</button>'
          : '0') + '</td>' +
        '<td><button class="btn" data-catdel="' + c.id + '" style="min-height:34px;padding:0 14px">Удалить</button></td>' +
      '</tr>';
    }).join('');
  }
  /* ---------- товары категории (правка 2.14) ---------- */
  function openCatProds(id) {
    var c = state.cats.filter(function (x) { return x.id === id; })[0];
    state.prodsCatId = id;
    $('cp-title').textContent = 'Товары категории: ' + (c ? c.name : '№ ' + id);
    $('cp-filter').value = '';
    renderCatProds();
    $('catprods-modal-backdrop').classList.add('open');
  }
  function renderCatProds() {
    var q = $('cp-filter').value.trim().toLowerCase();
    var list = state.products.filter(function (p) {
      if (p.category_id !== state.prodsCatId) return false;
      if (q && (p.name + ' ' + p.article).toLowerCase().indexOf(q) === -1) return false;
      return true;
    });
    $('cp-empty').hidden = list.length !== 0;
    $('cp-body').innerHTML = list.map(function (p) {
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
    /* правка 2.14: клик по счётчику — модалка товаров категории */
    $('cp-filter').addEventListener('input', renderCatProds);
    $('cp-modal-close').addEventListener('click', function () { $('catprods-modal-backdrop').classList.remove('open'); });
    $('catprods-modal-backdrop').addEventListener('click', function (e) { if (e.target === $('catprods-modal-backdrop')) $('catprods-modal-backdrop').classList.remove('open'); });
    $('cat-body').addEventListener('click', function (e) {
      var cp = e.target.closest('button[data-catprods]');
      if (cp) { openCatProds(Number(cp.getAttribute('data-catprods'))); return; }
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
