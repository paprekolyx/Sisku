/* ==========================================================================
   SISKU · categories.js — подраздел «Категории» вкладки «Магазин» (v0.9.0-draft)
   CRUD категорий каталога: создание, правка кликом по названию, авто-slug,
   удаление с защитой FK, счётчик товаров в категории.
   v0.15.0 (правка 2.14): клик по счётчику товаров — модалка со списком
   связанных товаров (название, вариант, цена, остаток, активность) и
   фильтром: FK-защита удаления объясняет «почему нельзя», а список
   показывает «что именно мешает».
   v0.22.0 (fp №14): конструктор атрибутов категории — кнопка «Атрибуты»
   у строки категории, модалка: список (порядок, тип, флаги), добавление/
   правка (код, название, тип text/number/enum, значения enum построчно,
   порядок, «показывать в списке», «фильтруемый», активен), удаление с
   подтверждением (значения товаров — каскадом); запись — RPC
   admin_save_category_attr / admin_delete_category_attr (скрипт 34).
   ========================================================================== */
(function () {
  'use strict';

  var state = { cats: [], catCounts: {}, products: [], variants: {}, editingCatId: null, prodsCatId: null,
    /* v0.22.0 (fp №14): конструктор атрибутов */
    attrs: [], attrsCatId: null, editingAttrId: null };

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
        /* v0.22.0 (fp №14): «Атрибуты» — конструктор атрибутов категории */
        '<td style="white-space:nowrap"><button class="btn" data-catattrs="' + c.id + '" style="min-height:34px;padding:0 14px;margin-right:8px">Атрибуты</button>' +
        '<button class="btn" data-catdel="' + c.id + '" style="min-height:34px;padding:0 14px">Удалить</button></td>' +
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

  /* ---------- v0.22.0 (fp №14): конструктор атрибутов категории ----------
     Чтение — прямая выборка category_attrs (включая неактивные — для
     повторной активации; anon_read_category_attrs, скрипт 34); запись —
     только RPC (SECURITY DEFINER): admin_save_category_attr (upsert) и
     admin_delete_category_attr (значения товаров — каскадом) */
  function openAttrs(catId) {
    state.attrsCatId = catId;
    state.editingAttrId = null;
    var c = state.cats.filter(function (x) { return x.id === catId; })[0];
    $('at-title').textContent = 'Атрибуты категории: ' + (c ? c.name : '№ ' + catId);
    $('at-form').hidden = true;
    $('at-error').hidden = true;
    loadAttrs();
    $('attrs-modal-backdrop').classList.add('open');
  }
  function loadAttrs() {
    $('at-body').innerHTML = '<tr><td colspan="7" class="muted">Загружаем атрибуты…</td></tr>';
    db.from('category_attrs').select('*').eq('category_id', state.attrsCatId)
      .order('sort_order').order('id')
      .then(function (res) {
        if (res.error) {
          $('at-body').innerHTML = '<tr><td colspan="7" class="muted">Ошибка: ' +
            esc(SiskuUtil.friendlyDbError(res.error)) + '</td></tr>';
          return;
        }
        state.attrs = res.data || [];
        renderAttrs();
      });
  }
  function renderAttrs() {
    $('at-empty').hidden = state.attrs.length !== 0;
    var TYPE_NAMES = { text: 'text', number: 'number', enum: 'enum' };
    $('at-body').innerHTML = state.attrs.map(function (a) {
      var flags = [];
      if (a.show_in_list) flags.push('в списке');
      if (a.is_filterable) flags.push('фильтр');
      var enumN = (a.type === 'enum' && Array.isArray(a.enum_values)) ? a.enum_values.length : 0;
      return '<tr' + (a.is_active ? '' : ' style="opacity:.55"') + '>' +
        '<td class="user-fio" data-atedit="' + a.id + '" title="Открыть редактирование">' + esc(a.name) + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(a.code) + '</td>' +
        '<td class="muted" style="font-size:13px" title="' + (enumN ? esc((a.enum_values || []).join(', ')) : '') + '">' +
          esc(TYPE_NAMES[a.type] || a.type) + (enumN ? ' (' + enumN + ')' : '') + '</td>' +
        '<td class="tabular" style="text-align:right">' + a.sort_order + '</td>' +
        '<td class="muted" style="font-size:12.5px">' + (flags.length ? esc(flags.join(' · ')) : '—') + '</td>' +
        '<td>' + (a.is_active ? '<span class="role-pill" data-role="admin">активен</span>' : '<span class="role-pill">скрыт</span>') + '</td>' +
        '<td><button class="btn" data-atdel="' + a.id + '" style="min-height:32px;padding:0 12px">Удалить</button></td>' +
      '</tr>';
    }).join('');
  }
  function toggleEnumWrap() {
    $('at-enum-wrap').hidden = $('at-type').value !== 'enum';
  }
  function openAttrForm(id) {
    state.editingAttrId = id || null;
    var a = id ? state.attrs.filter(function (x) { return x.id === id; })[0] : null;
    $('at-form-title').textContent = a ? 'Атрибут: ' + a.name : 'Новый атрибут';
    $('at-name').value = a ? a.name : '';
    $('at-code').value = a ? a.code : '';
    $('at-type').value = a ? a.type : 'text';
    $('at-sort').value = a ? a.sort_order
      : (state.attrs.reduce(function (m, x) { return Math.max(m, x.sort_order || 0); }, 0) + 1);
    $('at-enum').value = a && Array.isArray(a.enum_values) ? a.enum_values.join('\n') : '';
    $('at-list').checked = a ? !!a.show_in_list : false;
    $('at-filter').checked = a ? !!a.is_filterable : false;
    $('at-active').checked = a ? !!a.is_active : true;
    $('at-form-err').hidden = true;
    toggleEnumWrap();
    if (window.enhanceSelects) { enhanceSelects($('at-form')); $('at-type').dispatchEvent(new Event('refresh')); }
    $('at-form').hidden = false;
    $('at-name').focus();
  }
  function saveAttr(e) {
    e.preventDefault();
    var err = $('at-form-err');
    err.hidden = true;
    var name = $('at-name').value.trim();
    var code = $('at-code').value.trim().toLowerCase();
    var type = $('at-type').value;
    var sortN = parseInt($('at-sort').value, 10);
    if (name.length < 1) { err.textContent = 'Укажите название'; err.hidden = false; return; }
    if (!/^[a-z0-9_]{1,50}$/.test(code)) { err.textContent = 'Код: строчная латиница, цифры и «_», 1–50 (например, composition)'; err.hidden = false; return; }
    if (!(sortN >= 1)) { err.textContent = 'Порядок — число от 1'; err.hidden = false; return; }
    var enumValues = [];
    if (type === 'enum') {
      enumValues = $('at-enum').value.split('\n').map(function (s) { return s.trim(); })
        .filter(function (s) { return s !== ''; });
      if (!enumValues.length) { err.textContent = 'Атрибут enum: нужно хотя бы одно значение (каждое с новой строки)'; err.hidden = false; return; }
    }
    var pAttr = {
      category_id: state.attrsCatId,
      code: code, name: name, type: type,
      enum_values: enumValues,
      sort_order: sortN,
      show_in_list: $('at-list').checked,
      is_filterable: $('at-filter').checked,
      is_active: $('at-active').checked
    };
    if (state.editingAttrId) pAttr.id = state.editingAttrId;
    var btn = $('at-submit');
    btn.disabled = true;
    db.rpc('admin_save_category_attr', { p_attr: pAttr }).then(function (res) {
      btn.disabled = false;
      if (res.error) { err.textContent = SiskuUtil.friendlyDbError(res.error); err.hidden = false; return; }
      $('at-form').hidden = true;
      state.editingAttrId = null;
      loadAttrs();
    }).catch(function (e2) {
      btn.disabled = false;
      err.textContent = 'Ошибка сети: ' + e2.message;
      err.hidden = false;
    });
  }
  function delAttr(id) {
    var a = state.attrs.filter(function (x) { return x.id === id; })[0];
    if (!confirm('Удалить атрибут «' + (a ? a.name : '№ ' + id) + '»? Значения этого атрибута у товаров будут удалены (без восстановления).')) return;
    db.rpc('admin_delete_category_attr', { p_attr_id: id }).then(function (res) {
      var box = $('at-error');
      if (res.error) { box.textContent = SiskuUtil.friendlyDbError(res.error); box.hidden = false; return; }
      box.hidden = true;
      loadAttrs();
    });
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
    /* v0.22.0 (fp №14): конструктор атрибутов — события модалки */
    $('at-new').addEventListener('click', function () { openAttrForm(null); });
    $('at-modal-close').addEventListener('click', function () { $('attrs-modal-backdrop').classList.remove('open'); });
    $('attrs-modal-backdrop').addEventListener('click', function (e) { if (e.target === $('attrs-modal-backdrop')) $('attrs-modal-backdrop').classList.remove('open'); });
    $('at-form').addEventListener('submit', saveAttr);
    $('at-cancel').addEventListener('click', function () { $('at-form').hidden = true; state.editingAttrId = null; });
    $('at-type').addEventListener('change', toggleEnumWrap);
    /* авто-код из названия — только при создании (паттерн авто-slug категории) */
    $('at-name').addEventListener('input', function () {
      if (state.editingAttrId) return;
      $('at-code').value = slugify(this.value).replace(/-/g, '_').slice(0, 50);
    });
    $('at-body').addEventListener('click', function (e) {
      var del = e.target.closest('button[data-atdel]');
      if (del) { delAttr(Number(del.getAttribute('data-atdel'))); return; }
      var ed = e.target.closest('[data-atedit]');
      if (ed) openAttrForm(Number(ed.getAttribute('data-atedit')));
    });
    $('cat-body').addEventListener('click', function (e) {
      var ca = e.target.closest('button[data-catattrs]');
      if (ca) { openAttrs(Number(ca.getAttribute('data-catattrs'))); return; }
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
