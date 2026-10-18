/* ==========================================================================
   SISKU · products.js — управление товарами (v0.8.0-draft)
   Список с фильтром и активацией, карточка товара с живым предпросмотром
   витрины, редактор вариантов (размеры/объёмы + остатки), черновая загрузка
   фото (сжатие в браузере до ~320px, dataURL хранится в image_url),
   импорт CSV и шаблон CSV. Категории и бренды — справочники из БД.
   v0.15.0 (правка 2.15): «Полный предпросмотр» — модалка карточки товара
   глазами покупателя: разметка и styles.css витрины переиспользуются
   (iframe srcdoc), а не дублируются; данные — из текущей формы
   (включая несохранённые правки).
   v0.21.0 (fp №16 — бейджи): секция «Бейджи» в карточке товара (мультивыбор
   из справочника, сохранение набора одним RPC draft_save_product_badges —
   Д3), пилюли в списке (Д8), «New» предвыбран у нового товара (Д2);
   предпросмотры — с бейджами; хардкод «New по created_at» убран (Д6).
   v0.22.0 (fp №14 — атрибуты): динамическая секция «Характеристики» в
   карточке товара по категории (draft_attrs_bundle + сохранение
   draft_save_product_attrs); вторая кнопка таблицы — «Предпросмотр»
   (П14/Д12 — модалка из данных БД без редакционной формы); полный
   предпросмотр — явный <base href> в srcdoc (П13: относительные пути
   картинок), блок характеристик, описание модалки убрано; чек-бокс бейджа —
   стандартного размера, пилюля «системный» убрана (П12а/б).
   ========================================================================== */
(function () {
  'use strict';

  var state = {
    products: [], variants: {}, brands: [], cats: [], reserved: {},
    badges: [], prodBadges: {},   /* v0.21.0 (fp №16): справочник и назначения */
    attrs: [], attrValues: {},    /* v0.22.0 (fp №14): активные атрибуты и значения товаров (draft_attrs_bundle) */
    editingId: null, saving: false, imgData: null
  };

  function $(id) { return document.getElementById(id); }
  /* общие утилиты — assets/js/util.js (v0.14.0, фикс F32: одна копия на проект) */
  var esc = SiskuUtil.esc, money = SiskuUtil.money;
  /* v0.17.0 (находка B4): dataURL заглушки кэшируется (раньше пересоздавался
     на каждый рендер); находка E3: подмена битых src — делегированием util.js */
  var stubCache = null;
  function stubSrc() {
    if (stubCache) return stubCache;
    var svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 400">' +
      '<rect width="300" height="400" fill="#1D1D24"/>' +
      '<rect x="1" y="1" width="298" height="398" fill="none" stroke="#2A2A33"/>' +
      '<text x="150" y="215" font-family="Georgia,serif" font-size="64" fill="#C9A96A" text-anchor="middle">S</text></svg>';
    stubCache = 'data:image/svg+xml,' + encodeURIComponent(svg);
    return stubCache;
  }
  if (window.SiskuUtil) SiskuUtil.setStubProvider(stubSrc);
  function catName(id) { var c = state.cats.filter(function (x) { return x.id === id; })[0]; return c ? c.name : '—'; }
  function brandName(id) { var b = state.brands.filter(function (x) { return x.id === id; })[0]; return b ? b.name : '—'; }
  /* v0.21.0 (fp №16): бейджи товара — справочник и назначения */
  function badgeById(id) {
    return state.badges.filter(function (b) { return b.id === id; })[0] || null;
  }
  /* Д8: в списке — компактные пилюли (не более 3, далее «+N») */
  function badgeMinis(productId) {
    var pbs = (state.prodBadges[productId] || []).filter(function (pb) {
      var b = badgeById(pb.badge_id);
      return b && b.is_active;
    });
    if (!pbs.length) return '';
    var shown = pbs.slice(0, 3).map(function (pb) {
      return '<span class="badge-mini">' + esc(badgeById(pb.badge_id).name) + '</span>';
    }).join('');
    if (pbs.length > 3) shown += '<span class="badge-mini">+' + (pbs.length - 3) + '</span>';
    return ' ' + shown;
  }
  function stockOf(productId) {
    return (state.variants[productId] || []).reduce(function (s, v) { return s + v.stock; }, 0);
  }
  function reservedOf(productId) {
    return (state.variants[productId] || []).reduce(function (s, v) { return s + (state.reserved[v.id] || 0); }, 0);
  }
  /* v0.16.0 (скрипт 23, фикс F51): карантин — вернувшиеся по заявкам единицы,
     «требует осмотра»; в доступный остаток витрины НЕ входит */
  function quarantineOf(productId) {
    return (state.variants[productId] || []).reduce(function (s, v) { return s + Number(v.quarantine_qty || 0); }, 0);
  }

  /* ---------- список ---------- */
  function load() {
    $('prod-loading').hidden = false;
    $('prod-empty').hidden = true;
    $('prod-error').hidden = true;
    if (!db) {
      $('prod-loading').hidden = true;
      $('prod-error').hidden = false;
      $('prod-error').textContent = 'База не подключена: ' + (dbError || 'заполните assets/js/config.js');
      return;
    }
    Promise.all([
      db.from('products').select('*').order('article'),
      db.from('product_variants').select('*').order('sort_order'),
      db.from('brands').select('*').order('name'),
      db.from('categories').select('*').order('id'),
      db.rpc('draft_reserved_map'),
      /* v0.21.0 (fp №16): справочник бейджей и назначения — если скрипт 33
         ещё не выполнен, оба списка пусты, страница работает (паттерн
         справочников manage.js); ошибка запроса не роняет загрузку */
      db.from('badges').select('*').order('sort_order').order('id').then(function (r) {
        return r.error ? [] : (r.data || []);
      }),
      db.from('product_badges').select('*').order('sort_order').order('id').then(function (r) {
        return r.error ? [] : (r.data || []);
      }),
      /* v0.22.0 (fp №14): атрибуты и значения — если скрипт 34 не выполнен
         (42883), бандл пуст, секция «Характеристики» не рисуется (паттерн
         бейджей); ошибка запроса не роняет загрузку */
      db.rpc('draft_attrs_bundle').then(function (r) {
        return (r.error || !r.data) ? { attrs: [], values: [] } : r.data;
      })
    ]).then(function (res) {
      [res[0], res[1], res[2], res[3], res[4]].forEach(function (r) { if (r && r.error) throw r.error; });
      state.products = res[0].data || [];
      state.variants = {};
      (res[1].data || []).forEach(function (v) {
        (state.variants[v.product_id] = state.variants[v.product_id] || []).push(v);
      });
      state.brands = res[2].data || [];
      state.cats = res[3].data || [];
      state.reserved = {};
      (res[4].data || []).forEach(function (r) { state.reserved[r.variant_id] = Number(r.reserved) || 0; });
      state.badges = res[5] || [];
      state.prodBadges = {};
      (res[6] || []).forEach(function (pb) {
        (state.prodBadges[pb.product_id] = state.prodBadges[pb.product_id] || []).push(pb);
      });
      /* v0.22.0 (fp №14): attrs — активные атрибуты (порядок sort_order),
         attrValues — product_id → { attr_id: value } */
      state.attrs = res[7].attrs || [];
      state.attrValues = {};
      (res[7].values || []).forEach(function (v) {
        (state.attrValues[v.product_id] = state.attrValues[v.product_id] || {})[v.attr_id] = v.value;
      });
      $('p-cat').innerHTML = '<option value="">Все категории</option>' +
        state.cats.map(function (c) { return '<option value="' + c.id + '">' + esc(c.name) + '</option>'; }).join('');
      $('pf-brand').innerHTML = '<option value="">— без бренда —</option>' +
        state.brands.map(function (b) { return '<option value="' + b.id + '">' + esc(b.name) + '</option>'; }).join('');
      $('pf-cat').innerHTML = '<option value="">— выберите —</option>' +
        state.cats.map(function (c) { return '<option value="' + c.id + '">' + esc(c.name) + '</option>'; }).join('');
      if (window.enhanceSelects) enhanceSelects();
      render();
    }).catch(function (e) {
      $('prod-loading').hidden = true;
      $('prod-error').hidden = false;
      $('prod-error').textContent = 'Ошибка загрузки: ' + e.message;
    });
  }

  function filtered() {
    var q = $('p-search').value.trim().toLowerCase();
    var cat = $('p-cat').value;
    return state.products.filter(function (p) {
      if (cat && String(p.category_id) !== cat) return false;
      if (q && (p.article + ' ' + p.name).toLowerCase().indexOf(q) === -1) return false;
      return true;
    });
  }

  function render() {
    $('prod-loading').hidden = true;
    var list = filtered();
    $('prod-empty').hidden = state.products.length !== 0;
    $('prod-body').innerHTML = list.map(function (p) {
      var stock = stockOf(p.id);
      return '<tr>' +
        '<td><img class="thumb" src="' + esc(p.image_url || stubSrc()) + '" alt="" data-img-fallback="stub"></td>' +
        '<td class="tabular">' + esc(p.article) + '</td>' +
        '<td class="user-fio" data-edit="' + p.id + '" title="Открыть карточку">' + esc(p.name) + badgeMinis(p.id) + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(catName(p.category_id)) + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(brandName(p.brand_id)) + '</td>' +
        '<td class="tabular">' + money(p.price) + '</td>' +
        '<td class="tabular' + (stock < 3 ? ' low-stock' : '') + '">' + stock + '</td>' +
        '<td class="tabular muted">' + reservedOf(p.id) + '</td>' +
        '<td class="tabular' + (quarantineOf(p.id) ? ' quarantine-cell' : ' muted') + '">' + (quarantineOf(p.id) || '—') + '</td>' +
        '<td><button class="btn" data-active="' + p.id + '" style="min-height:32px;padding:0 12px">' +
          (p.is_active ? 'активен' : 'скрыт') + '</button></td>' +
        /* v0.22.0 (П14/Д12): вторая кнопка — «Предпросмотр» (модалка карточки
           витрины из данных БД); наименование — по-прежнему открывает карточку */
        '<td><button class="btn" data-preview="' + p.id + '" style="min-height:34px;padding:0 14px" title="Карточка глазами покупателя — данные из БД">Предпросмотр</button></td>' +
      '</tr>';
    }).join('');
  }

  /* ---------- предпросмотр ---------- */
  function refreshPreview() {
    var url = $('pf-img-url').value.trim() || state.imgData || '';
    $('pv-img').src = url || stubSrc();
    $('pv-brand').textContent = $('pf-brand').value ? brandName(Number($('pf-brand').value)) : '';
    $('pv-name').textContent = $('pf-name').value.trim() || 'Название товара';
    $('pv-price').textContent = money($('pf-price').value || 0);
    var stock = 0;
    $('pf-variants').querySelectorAll('.var-row').forEach(function (row) {
      stock += Number(row.querySelector('.var-stock').value || 0);
    });
    $('pv-stock').textContent = stock > 0 ? 'в наличии' : 'нет в наличии';
    $('pv-stock').className = 'pv-stock' + (stock > 0 ? '' : ' out');
    /* v0.21.0 (fp №16): пилюли бейджей поверх фото — из чекбоксов карточки
       (живьём, включая несохранённые правки) */
    var pvB = $('pv-badges');
    if (pvB) {
      pvB.innerHTML = checkedBadgeIds().map(function (id) {
        var b = badgeById(id);
        return b ? '<span class="pv-badge-chip">' + esc(b.name) + '</span>' : '';
      }).join('');
    }
  }

  /* ---------- полный предпросмотр карточки витрины (правка 2.15) ----------
     Разметка модалки товара витрины рендерится в iframe, который грузит
     настоящие styles.css/fonts.css и применяет кэш токенов брендбука
     (brandvars.js) — переиспользование, а не дублирование стилей.
     Тема iframe — текущая тема админки.
     v0.22.0 (П13): в srcdoc — явный <base href> (URL родительского документа):
     относительные пути картинок (assets/img/…) в about:srcdoc ломались.
     v0.22.0 (П14/Д12): второй вход openDbPreview(id) — карточка из данных БД
     (товар, варианты, бейджи, атрибуты) без показа редакционной формы и
     несохранённых правок; общий построитель pvCardHtml. */
  function pvCardHtml(o) {
    return '<div class="product-grid" style="max-width:920px;margin:0 auto;border:1px solid var(--line);background:var(--surface)">' +
      '<div class="product-media"><img src="' + esc(o.img) + '" alt=""></div>' +
      '<div class="product-info">' +
        '<div class="brand">' + esc(o.brand) + '</div>' +
        (o.badgeHtml ? '<div style="margin:10px 0 2px">' + o.badgeHtml + '</div>' : '') +
        '<h3>' + esc(o.name) + '</h3>' +
        '<div class="price">' + money(o.price) + '</div>' +
        '<p class="desc">' + esc(o.desc) + '</p>' +
        o.attrsHtml +
        '<div class="variant-label">' + (o.isPerfume ? 'Объём' : 'Размер') + '</div>' +
        '<div class="variants">' + (o.vars.length
          ? o.vars.map(function (v) {
              return '<button class="variant' + (v.stock ? '' : ' out') + '">' + esc(v.label) +
                '<span class="st">' + (v.stock ? v.stock + ' шт.' : 'нет') + '</span></button>';
            }).join('')
          : '<span class="muted">варианты не заданы</span>') + '</div>' +
        '<div style="margin-top:26px;display:flex;gap:12px;align-items:center">' +
          '<button class="btn accent">В корзину</button>' +
          '<span class="muted" style="font-size:13px">' + (o.totalStock ? 'остаток: ' + o.totalStock + ' шт.' : 'нет в наличии') + '</span>' +
        '</div>' +
      '</div>' +
    '</div>';
  }
  /* пилюли бейджей — из списка id (только активные, порядок назначений);
     v0.22.0 (П12в/Д8): min/max-ширина, nowrap, ellipsis + title — как на витрине */
  function pvBadgeHtml(ids) {
    return (ids || []).map(function (id) {
      var b = badgeById(id);
      return b && b.is_active
        ? '<span title="' + esc(b.name) + '" style="display:inline-block;min-width:72px;max-width:180px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;text-align:center;background:var(--bg);border:1px solid var(--line);color:var(--accent);font-size:10.5px;letter-spacing:.14em;text-transform:uppercase;padding:4px 10px;font-weight:600;margin:0 6px 6px 0">' + esc(b.name) + '</span>'
        : '';
    }).join('');
  }
  /* блок «Характеристики» — пары [{name, value}]; стили витрины .pm-attrs/
     .pa-row (styles.css загружается в iframe — волна v0.22.0, fp №14) */
  function pvAttrsHtml(pairs) {
    if (!pairs.length) return '';
    return '<div class="pm-attrs"><div class="pa-title">Характеристики</div>' +
      pairs.map(function (x) {
        return '<div class="pa-row"><span class="pa-name">' + esc(x.name) + '</span>' +
          '<span class="pa-val">' + esc(x.value) + '</span></div>';
      }).join('') + '</div>';
  }
  function showPvFrame(card) {
    var theme = document.documentElement.getAttribute('data-theme') === 'light' ? 'light' : 'dark';
    /* v0.17.0 (внешний ревью 06.10.2026, находка A1): токены брендбука для
       предпросмотра — статическим инлайн-<style> из КЭША токенов
       (window.brandCachedRows) со СТРОГОЙ валидацией каждого значения:
       цвет — только hex (#RGB…#RRGGBBAA), типографика — только число.
       Скриптов в iframe нет (sandbox="" в products.html) — путь исполнения
       JS из неконтролируемого localStorage-кэша закрыт; CSS-инъекция через
       подменённый кэш исключена валидацией (двойная защита: brandvars.js
       валидирует и при применении к страницам витрины). */
    var pvTokenCss = (function () {
      var hexOk = /^#[0-9a-fA-F]{3,8}$/;
      var numOk = /^\d{1,3}$/;
      var VAR_MAP = { bg: '--bg', surface: '--surface', card: '--card',
                      text: '--text', muted: '--muted', accent: '--accent',
                      line: '--line', btn_bg: '--btn-bg', btn_text: '--btn-text' };
      var css = ':root{', accent = '', typoBase = null, typoScale = null;
      var rows = (typeof window.brandCachedRows === 'function') ? (window.brandCachedRows() || []) : [];
      rows.forEach(function (r) {
        if (!r || !r.key) return;
        if (r.theme !== 'global' && r.theme !== theme) return;
        var v = String(r.value == null ? '' : r.value).trim();
        var name = VAR_MAP[r.key];
        if (name && hexOk.test(v)) {
          css += name + ':' + v + ';';
          if (r.key === 'accent') accent = v;
        }
        if (r.theme === 'global') {
          if (r.key === 'typo_base' && numOk.test(v)) typoBase = v;
          if (r.key === 'typo_scale' && numOk.test(v) && Number(v) >= 50 && Number(v) <= 200) typoScale = v;
        }
      });
      if (accent) css += '--accent-soft:color-mix(in srgb, ' + accent + ' ' +
        (theme === 'dark' ? '14' : '10') + '%, transparent);';
      if (typoBase) css += '--font-base:' + typoBase + 'px;';
      if (typoScale) css += '--type-scale:' + (Number(typoScale) / 100) + ';';
      return css + '}';
    })();
    $('pvfull-frame').srcdoc =
      '<!DOCTYPE html><html lang="ru" data-theme="' + theme + '"><head><meta charset="utf-8">' +
      '<base href="' + esc(location.href.replace(/[#?].*$/, '')) + '">' +
      '<link rel="stylesheet" href="assets/css/fonts.css">' +
      '<link rel="stylesheet" href="assets/css/styles.css">' +
      '<style>' + pvTokenCss + '</style>' +
      '</head><body style="margin:0;padding:28px 20px">' + card + '</body></html>';
    $('pvfull-modal-backdrop').classList.add('open');
  }
  function openFullPreview() {
    var name = $('pf-name').value.trim() || 'Название товара';
    var price = $('pf-price').value || 0;
    var brand = $('pf-brand').value ? brandName(Number($('pf-brand').value)) : '';
    if (brand === '—') brand = '';
    var desc = $('pf-desc').value.trim();
    var img = $('pf-img-url').value.trim() || state.imgData || stubSrc();
    var vars = [];
    $('pf-variants').querySelectorAll('.var-row').forEach(function (r) {
      var label = r.querySelector('.var-label').value.trim();
      var stock = Number(r.querySelector('.var-stock').value || 0);
      if (label) vars.push({ label: label, stock: stock });
    });
    var isPerfume = /мл/i.test((vars[0] || {}).label || '');
    var totalStock = vars.reduce(function (s, v) { return s + v.stock; }, 0);
    /* v0.22.0 (fp №14): характеристики — из текущей формы (живьём, включая
       несохранённые правки) */
    var pairs = [];
    $('pf-attrs').querySelectorAll('.attr-row').forEach(function (row) {
      var el = row.querySelector('.attr-val');
      var v = el ? String(el.value == null ? '' : el.value).trim() : '';
      if (v) pairs.push({ name: row.querySelector('label').textContent, value: v });
    });
    showPvFrame(pvCardHtml({
      name: name, price: price, brand: brand, desc: desc, img: img,
      vars: vars, isPerfume: isPerfume, totalStock: totalStock,
      badgeHtml: pvBadgeHtml(checkedBadgeIds()),
      attrsHtml: pvAttrsHtml(pairs)
    }));
  }
  /* П14/Д12: «Предпросмотр» из таблицы товаров — данные из БД (товар,
     варианты, бейджи, атрибуты), без редакционной формы */
  function openDbPreview(id) {
    var p = state.products.filter(function (x) { return x.id === id; })[0];
    if (!p) return;
    var vars = (state.variants[id] || []).slice().sort(function (a, b) {
      return (a.sort_order || 0) - (b.sort_order || 0);
    }).map(function (v) { return { label: v.label, stock: Number(v.stock) || 0 }; });
    var isPerfume = /мл/i.test((vars[0] || {}).label || '');
    var totalStock = vars.reduce(function (s, v) { return s + v.stock; }, 0);
    var brand = p.brand_id ? brandName(p.brand_id) : '';
    if (brand === '—') brand = '';
    showPvFrame(pvCardHtml({
      name: p.name, price: p.price, brand: brand,
      desc: p.description || '',
      img: p.image_url || stubSrc(),
      vars: vars, isPerfume: isPerfume, totalStock: totalStock,
      badgeHtml: pvBadgeHtml((state.prodBadges[id] || []).map(function (pb) { return pb.badge_id; })),
      attrsHtml: pvAttrsHtml(dbAttrPairs(p))
    }));
  }
  /* заполненные активные атрибуты категории товара (порядок sort_order) */
  function dbAttrPairs(p) {
    var vals = state.attrValues[p.id] || {};
    return state.attrs.filter(function (a) {
      return a.category_id === p.category_id && vals[a.id];
    }).map(function (a) { return { name: a.name, value: String(vals[a.id]) }; });
  }

  /* ---------- варианты ---------- */
  function addVariantRow(id, label, stock, quarantine) {
    var row = document.createElement('div');
    row.className = 'var-row';
    if (id) row.setAttribute('data-vid', id);
    var quar = Number(quarantine || 0);
    row.innerHTML =
      /* v0.16.0 (фикс F51): карантин варианта — счётчик + осмотр («вернуть
         в продажу» / «списать», RPC admin_resolve_quarantine, скрипт 23);
         блок живёт в одной grid-ячейке с названием (var-row — 3 колонки);
         складские движения с журналом — fp №3b (v0.28.0) */
      '<div class="var-label-cell">' +
        '<input class="var-label" placeholder="Размер / объём (S, 50 мл…)" value="' + esc(label || '') + '">' +
        (id && quar > 0
          ? '<div class="var-quarantine-row">' +
              '<span class="var-quarantine" title="Требует осмотра: вернулось по заявке на возврат">карантин ' + quar + ' шт.</span>' +
              '<button type="button" class="btn ghost small var-q-restock" title="Вернуть ' + quar + ' шт. в продажу">В продажу</button>' +
              '<button type="button" class="btn ghost small var-q-writeoff" title="Списать ' + quar + ' шт. (брак и т.п.)">Списать</button>' +
            '</div>'
          : '') +
      '</div>' +
      '<input class="var-stock" type="number" min="0" step="1" placeholder="Остаток" value="' + (stock != null ? stock : 0) + '">' +
      '<button type="button" class="btn ghost small var-del" title="Убрать вариант">×</button>';
    row.querySelector('.var-del').addEventListener('click', function () { row.remove(); refreshPreview(); });
    row.querySelector('.var-stock').addEventListener('input', refreshPreview);
    ['restock', 'writeoff'].forEach(function (action) {
      var b = row.querySelector('.var-q-' + action);
      if (!b) return;
      b.addEventListener('click', function () {
        var what = action === 'restock' ? 'вернуть в продажу' : 'списать';
        if (!confirm('Осмотр карантина: ' + what + ' ' + quar + ' шт. варианта «' + (label || '') + '»?')) return;
        b.disabled = true;
        db.rpc('admin_resolve_quarantine', {
          p_variant_id: id, p_qty: quar, p_action: action, p_changed_by: 'draft-admin'
        }).then(function (res) {
          if (res.error) { alert(SiskuUtil.friendlyDbError(res.error)); b.disabled = false; return; }
          /* свежие значения — из ответа RPC (локально, без гонки с load()),
             затем фоновое перечитывание и перерисовка карточки */
          var d = res.data || {};
          (state.variants[state.editingId] || []).forEach(function (v) {
            if (v.id === id) { v.stock = d.stock; v.quarantine_qty = d.quarantine_qty; }
          });
          load();
          openModal(state.editingId);
        }).catch(function (e) { alert('Ошибка сети: ' + e.message); b.disabled = false; });
      });
    });
    $('pf-variants').appendChild(row);
    refreshPreview();
  }

  /* ---------- бейджи карточки (v0.21.0, fp №16; Д2/Д3/Д4) ----------
     Мультивыбор из справочника: активные бейджи + неактивные, уже назначенные
     этому товару (помечены — при сохранении остаются, если отмечены).
     Новый товар: «New» предвыбран (Д2). Системный «New» — значок; снятие
     любого бейджа — вручную (ответ 7.4). Сохранение набора — одним RPC
     draft_save_product_badges (Д3, одна транзакция). */
  function renderBadgeEditor(p) {
    var box = $('pf-badges');
    if (!state.badges.length) {
      box.innerHTML = '<span class="muted" style="font-size:12px">Справочник бейджей пуст — выполните скрипт 33 базы (волна v0.21.0).</span>';
      return;
    }
    var assigned = {};
    ((p && state.prodBadges[p.id]) || []).forEach(function (pb) { assigned[pb.badge_id] = true; });
    box.innerHTML = state.badges.map(function (b) {
      if (!b.is_active && !assigned[b.id]) return '';   /* неактивный и не назначенный — не предлагаем */
      var checked = p ? !!assigned[b.id] : b.code === 'new';   /* Д2: новому товару — New */
      return '<label class="inv-check"' + (b.is_system ? ' title="Системный бейдж: по умолчанию у всех товаров; справочником не деактивируется; снятие с товара — только вручную (ответ 7.4)"' : '') + '>' +
        '<input type="checkbox" data-bid="' + b.id + '"' + (checked ? ' checked' : '') + '>' +
        /* v0.22.0 (П12б): пилюля «системный» убрана — пояснение осталось
           в title и в пометке внизу секции (products.html) */
        '<span>' + esc(b.name) +
          (b.is_active ? '' : ' <span class="muted" style="font-size:12px">(отключён)</span>') +
        '</span>' +
      '</label>';
    }).join('');
    box.querySelectorAll('input[data-bid]').forEach(function (cb) {
      cb.addEventListener('change', refreshPreview);
    });
    refreshPreview();
  }
  function checkedBadgeIds() {
    var ids = [];
    $('pf-badges').querySelectorAll('input[data-bid]').forEach(function (cb) {
      if (cb.checked) ids.push(Number(cb.getAttribute('data-bid')));
    });
    return ids;
  }

  /* ---------- атрибуты карточки товара (v0.22.0, fp №14) ----------
     Динамическая секция «Характеристики» по категории из формы: text/number —
     инпут, enum — select из enum_values; значения — draft_attrs_bundle
     (state.attrs/attrValues); сохранение — RPC draft_save_product_attrs
     вместе с сохранением карточки (пустые значения удаляются). При смене
     категории в форме секция перерисовывается: значения другой категории не
     показываются; сохранённые остаются в БД до правки (бандлы витрины их
     тоже не отдают — фильтр по категории товара). */
  function renderAttrEditor(p) {
    var field = $('pf-attrs-field');
    var host = $('pf-attrs');
    var catId = $('pf-cat').value ? Number($('pf-cat').value) : null;
    var attrs = catId ? state.attrs.filter(function (a) { return a.category_id === catId; }) : [];
    if (!catId || !attrs.length) {
      field.hidden = true;
      host.innerHTML = '';
      return;
    }
    field.hidden = false;
    var vals = (p && state.attrValues[p.id]) || {};
    host.innerHTML = attrs.map(function (a) {
      var v = vals[a.id] != null ? String(vals[a.id]) : '';
      var ctrl;
      if (a.type === 'enum') {
        ctrl = '<select class="attr-val" data-aid="' + a.id + '">' +
          '<option value="">— не задано —</option>' +
          (a.enum_values || []).map(function (ev) {
            return '<option value="' + esc(ev) + '"' + (String(ev) === v ? ' selected' : '') + '>' + esc(ev) + '</option>';
          }).join('') + '</select>';
      } else {
        ctrl = '<input class="attr-val" data-aid="' + a.id + '"' +
          ' type="' + (a.type === 'number' ? 'number' : 'text') + '"' +
          (a.type === 'number' ? ' step="any"' : '') +
          ' value="' + esc(v) + '" placeholder="' + (a.type === 'number' ? '0' : 'значение') + '">';
      }
      return '<div class="attr-row"><label>' + esc(a.name) + '</label>' + ctrl + '</div>';
    }).join('');
    if (window.enhanceSelects) enhanceSelects(host);
  }
  function editingProduct() {
    return state.editingId
      ? state.products.filter(function (x) { return x.id === state.editingId; })[0] || null
      : null;
  }
  function collectAttrValues() {
    var out = {};
    $('pf-attrs').querySelectorAll('.attr-val').forEach(function (el) {
      out[el.getAttribute('data-aid')] = String(el.value == null ? '' : el.value).trim();
    });
    return out;
  }

  /* ---------- черновая загрузка фото: сжатие в браузере ---------- */
  function compressImage(file, cb) {
    var reader = new FileReader();
    reader.onload = function () {
      var img = new Image();
      img.onload = function () {
        var max = 320;
        var k = Math.min(1, max / Math.max(img.width, img.height));
        var canvas = document.createElement('canvas');
        canvas.width = Math.round(img.width * k);
        canvas.height = Math.round(img.height * k);
        canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
        cb(canvas.toDataURL('image/jpeg', 0.65));
      };
      img.src = reader.result;
    };
    reader.readAsDataURL(file);
  }

  /* ---------- карточка товара ---------- */
  function openModal(id) {
    state.editingId = id || null;
    state.saving = false;
    state.imgData = null;
    $('pf-submit').disabled = false;
    var p = id ? state.products.filter(function (x) { return x.id === id; })[0] : null;
    $('pm-title').textContent = p ? ('Товар ' + p.article) : 'Новый товар';
    $('pf-article').value = p ? p.article : '';
    $('pf-name').value = p ? p.name : '';
    $('pf-price').value = p ? p.price : '';
    $('pf-desc').value = p ? (p.description || '') : '';
    $('pf-img-url').value = p && p.image_url && p.image_url.indexOf('data:') !== 0 ? p.image_url : '';
    $('pf-img-file').value = '';
    $('pf-img-name').textContent = 'файл не выбран';
    state.imgData = p && p.image_url && p.image_url.indexOf('data:') === 0 ? p.image_url : null;
    $('pf-active').checked = p ? p.is_active : true;
    ['pf-article-err', 'pf-name-err', 'pf-price-err', 'pf-cat-err', 'pf-error'].forEach(function (x) { $(x).hidden = true; });
    $('pf-variants').innerHTML = '';
    var vars = p ? (state.variants[p.id] || []) : [];
    if (vars.length) vars.forEach(function (v) { addVariantRow(v.id, v.label, v.stock, v.quarantine_qty); });
    else addVariantRow(null, '', 0, 0);
    /* селекты бренда/категории ставим после enhance (нативный select живёт внутри .cselect) */
    $('pf-brand').value = p && p.brand_id ? String(p.brand_id) : '';
    $('pf-cat').value = p && p.category_id ? String(p.category_id) : '';
    $('pf-brand').dispatchEvent(new Event('refresh'));
    $('pf-cat').dispatchEvent(new Event('refresh'));
    renderBadgeEditor(p);   /* v0.21.0 (fp №16) */
    renderAttrEditor(p);    /* v0.22.0 (fp №14): «Характеристики» по категории */
    $('prod-modal-backdrop').classList.add('open');
    refreshPreview();
  }
  function closeModal() { $('prod-modal-backdrop').classList.remove('open'); }

  function save(e) {
    e.preventDefault();
    if (state.saving) return;
    var errBox = $('pf-error');
    errBox.hidden = true;
    var article = $('pf-article').value.trim();
    var name = $('pf-name').value.trim();
    var price = Number($('pf-price').value);
    var cat = $('pf-cat').value ? Number($('pf-cat').value) : null;
    var brand = $('pf-brand').value ? Number($('pf-brand').value) : null;
    var ok = true;
    ['pf-article-err', 'pf-name-err', 'pf-price-err', 'pf-cat-err'].forEach(function (x) { $(x).hidden = true; });
    if (!article) { $('pf-article-err').textContent = 'Укажите артикул'; $('pf-article-err').hidden = false; ok = false; }
    if (name.length < 3) { $('pf-name-err').textContent = 'Укажите название'; $('pf-name-err').hidden = false; ok = false; }
    if (!price || price <= 0) { $('pf-price-err').textContent = 'Цена больше 0'; $('pf-price-err').hidden = false; ok = false; }
    if (!cat) { $('pf-cat-err').textContent = 'Выберите категорию'; $('pf-cat-err').hidden = false; ok = false; }
    if (!ok) return;

    state.saving = true;
    $('pf-submit').disabled = true;

    var imgUrl = $('pf-img-url').value.trim() || state.imgData || null;
    var row = {
      article: article, name: name, price: price, category_id: cat, brand_id: brand,
      description: $('pf-desc').value.trim() || null,
      image_url: imgUrl, is_active: $('pf-active').checked
    };

    var rows = [];
    $('pf-variants').querySelectorAll('.var-row').forEach(function (r, i) {
      var label = r.querySelector('.var-label').value.trim();
      var stock = Number(r.querySelector('.var-stock').value || 0);
      if (label) rows.push({ vid: r.getAttribute('data-vid') ? Number(r.getAttribute('data-vid')) : null, label: label, stock: stock, sort: i + 1 });
    });

    var saveProduct = function (productId) {
      /* синхронизация вариантов: update существующих, insert новых, delete убранных */
      var jobs = [];
      var keep = {};
      rows.forEach(function (v) {
        if (v.vid) {
          keep[v.vid] = true;
          jobs.push(db.from('product_variants').update({ label: v.label, stock: v.stock, sort_order: v.sort }).eq('id', v.vid));
        } else {
          jobs.push(db.from('product_variants').insert({ product_id: productId, label: v.label, stock: v.stock, sort_order: v.sort }));
        }
      });
      (state.variants[productId] || []).forEach(function (v) {
        if (!keep[v.id]) jobs.push(db.from('product_variants').delete().eq('id', v.id));
      });
      return Promise.all(jobs).then(function (results) {
        var warns = results.filter(function (r) { return r && r.error; }).map(function (r) {
          return 'варианты: ' + r.error.message +
            (String(r.error.message).indexOf('foreign key') > -1
              ? ' (вариант из заказа удалить нельзя — он остался)' : '');
        });
        return warns;
      });
    };

    /* v0.21.0 (Д3): бейджи — замена набора одним RPC draft_save_product_badges
       (одна транзакция); если скрипт 33 не выполнен — пропускаем (в редакторе
       карточки — примечание); ошибка RPC — предупреждением (товар сохранён) */
    var badgeIds = checkedBadgeIds();
    var saveBadges = function (productId) {
      if (!state.badges.length) return Promise.resolve([]);
      return db.rpc('draft_save_product_badges', {
        p: { product_id: productId, badge_ids: badgeIds }
      }).then(function (res) {
        if (!res.error) return [];
        return [res.error.code === '42883'
          ? 'бейджи: функция draft_save_product_badges не найдена (скрипт 33 не выполнен) — набор не сохранён'
          : 'бейджи: ' + res.error.message];
      });
    };

    /* v0.22.0 (fp №14): значения атрибутов — одним RPC draft_save_product_attrs
       (пустые значения удаляют строки); скрипт 34 не выполнен — пропускаем;
       ошибка RPC — предупреждением (товар сохранён) */
    var attrPayload = collectAttrValues();
    var saveAttrs = function (productId) {
      if (!state.attrs.length) return Promise.resolve([]);
      return db.rpc('draft_save_product_attrs', { p_product_id: productId, p_attrs: attrPayload })
        .then(function (res) {
          if (!res.error) return [];
          return [res.error.code === '42883'
            ? 'атрибуты: функция draft_save_product_attrs не найдена (скрипт 34 не выполнен) — значения не сохранены'
            : 'атрибуты: ' + res.error.message];
        });
    };

    var done = function (warns) {
      state.saving = false;
      $('pf-submit').disabled = false;
      closeModal();
      load();
      if (warns && warns.length) {
        alert('Товар сохранён, но с замечаниями: ' + warns.join('; '));
      }
    };
    var fail = function (msg) {
      state.saving = false;
      $('pf-submit').disabled = false;
      errBox.textContent = msg;
      errBox.hidden = false;
    };

    if (state.editingId) {
      db.from('products').update(row).eq('id', state.editingId).then(function (res) {
        if (res.error) { fail(res.error.message); return; }
        saveProduct(state.editingId).then(function (warns) {
          saveBadges(state.editingId).then(function (bw) {
            saveAttrs(state.editingId).then(function (aw) { done(warns.concat(bw, aw)); });
          });
        });
      }).catch(function (err) { fail('Ошибка сети: ' + err.message); });
    } else {
      db.from('products').insert(row).then(function (res) {
        if (res.error) { fail(res.error.message); return; }
        var newId = res.data && res.data.length ? res.data[0].id : null;
        if (!newId) { fail('Товар создан, но id не вернулся — обновите список'); return; }
        saveProduct(newId).then(function (warns) {
          saveBadges(newId).then(function (bw) {
            saveAttrs(newId).then(function (aw) { done(warns.concat(bw, aw)); });
          });
        });
      }).catch(function (err) { fail('Ошибка сети: ' + err.message); });
    }
  }

  /* ---------- CSV: шаблон и импорт ---------- */
  function parseCSV(text) {
    var rows = [], row = [], cur = '', inQ = false;
    for (var i = 0; i < text.length; i++) {
      var ch = text[i];
      if (inQ) {
        if (ch === '"') {
          if (text[i + 1] === '"') { cur += '"'; i++; } else inQ = false;
        } else cur += ch;
      } else if (ch === '"') inQ = true;
      else if (ch === ',') { row.push(cur); cur = ''; }
      else if (ch === '\n') { row.push(cur); rows.push(row); row = []; cur = ''; }
      else if (ch !== '\r') cur += ch;
    }
    if (cur !== '' || row.length) { row.push(cur); rows.push(row); }
    return rows.filter(function (r) { return r.some(function (c) { return c.trim() !== ''; }); });
  }
  function csvTemplate() {
    var head = 'article,name,price,brand_id,category_id,description,image_url,is_active';
    var ex = '10005,Пальто Demo из шерсти,24900.00,2,1,Демо-описание состава и кроя.,,true';
    var blob = new Blob(['\uFEFF' + head + '\n' + ex + '\n'], { type: 'text/csv;charset=utf-8' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'products-template.csv';
    a.click();
    URL.revokeObjectURL(a.href);
  }
  function importCsv(file) {
    var reader = new FileReader();
    reader.onload = function () {
      var rows = parseCSV(String(reader.result));
      if (rows.length < 2) { showReport('В файле нет строк данных'); return; }
      var head = rows[0].map(function (h) { return h.trim(); });
      var idx = {};
      head.forEach(function (h, i) { idx[h] = i; });
      var need = ['article', 'name', 'price'];
      for (var n = 0; n < need.length; n++) {
        if (idx[need[n]] === undefined) { showReport('Нет обязательной колонки: ' + need[n]); return; }
      }
      var payload = [], errors = [];
      rows.slice(1).forEach(function (r, i) {
        var get = function (k) { return idx[k] !== undefined ? (r[idx[k]] || '').trim() : ''; };
        var article = get('article'), name = get('name'), price = Number(get('price'));
        if (!article || !name || !price) { errors.push('строка ' + (i + 2) + ': пропущены article/name/price'); return; }
        /* v0.17.0 (находка A4): brand_id/category_id проверяются по загруженным
           справочникам — битые/несуществующие id не летят в базу молча, строка
           пропускается с читаемым отчётом */
        var brandId = get('brand_id') ? Number(get('brand_id')) : null;
        var catId = get('category_id') ? Number(get('category_id')) : null;
        if (brandId !== null && (!isFinite(brandId) ||
            !state.brands.some(function (b) { return b.id === brandId; }))) {
          errors.push('строка ' + (i + 2) + ': brand_id «' + get('brand_id') + '» нет в справочнике'); return;
        }
        if (catId !== null && (!isFinite(catId) ||
            !state.cats.some(function (c) { return c.id === catId; }))) {
          errors.push('строка ' + (i + 2) + ': category_id «' + get('category_id') + '» нет в справочнике'); return;
        }
        payload.push({
          article: article, name: name, price: price,
          brand_id: brandId,
          category_id: catId,
          description: get('description') || null,
          image_url: get('image_url') || null,
          is_active: get('is_active').toLowerCase() !== 'false'
        });
      });
      if (!payload.length) { showReport('Некорректных строк: ' + errors.length + '\n' + errors.slice(0, 10).join('\n')); return; }
      db.from('products').insert(payload).then(function (res) {
        if (res.error) { showReport('Импорт отклонён целиком: ' + res.error.message + (errors.length ? '\nОшибки строк:\n' + errors.slice(0, 10).join('\n') : '')); return; }
        showReport('Импортировано товаров: ' + payload.length + (errors.length ? '\nПропущено строк с ошибками: ' + errors.length + '\n' + errors.slice(0, 10).join('\n') : ''));
        load();
      });
    };
    reader.readAsText(file, 'utf-8');
  }
  function showReport(text) {
    var box = $('import-report');
    box.textContent = text;
    box.hidden = false;
  }

  /* ---------- старт ---------- */
  /* правка 2.11 (v0.15.0): products.html#inventory — панель-заглушка «Инвентаризация» */
  function applyInventoryHash() {
    var on = location.hash === '#inventory';
    $('panel-inventory').hidden = !on;
    $('panel-products').hidden = on;
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;
    if (window.initAdminTheme) window.initAdminTheme();
    applyInventoryHash();
    window.addEventListener('hashchange', applyInventoryHash);
    $('btn-logout').addEventListener('click', function () { if (window.mockLogout) window.mockLogout(); });
    /* правка 2.15: полный предпросмотр карточки витрины */
    $('pv-full').addEventListener('click', openFullPreview);
    $('pvfull-modal-close').addEventListener('click', function () { $('pvfull-modal-backdrop').classList.remove('open'); });
    $('pvfull-modal-backdrop').addEventListener('click', function (e) { if (e.target === $('pvfull-modal-backdrop')) $('pvfull-modal-backdrop').classList.remove('open'); });
    $('btn-refresh').addEventListener('click', load);
    $('p-search').addEventListener('input', render);
    $('p-cat').addEventListener('change', render);
    $('btn-new-product').addEventListener('click', function () { openModal(null); });
    $('btn-csv-template').addEventListener('click', csvTemplate);
    $('btn-csv-import').addEventListener('click', function () { $('csv-file').click(); });
    $('csv-file').addEventListener('change', function () {
      if (this.files && this.files[0]) importCsv(this.files[0]);
      this.value = '';
    });
    $('prod-modal-close').addEventListener('click', closeModal);
    $('prod-modal-backdrop').addEventListener('click', function (e) { if (e.target === $('prod-modal-backdrop')) closeModal(); });
    $('prod-form').addEventListener('submit', save);
    $('pf-var-add').addEventListener('click', function () { addVariantRow(null, '', 0); });
    $('pf-img-btn').addEventListener('click', function () { $('pf-img-file').click(); });
    $('pf-img-file').addEventListener('change', function () {
      var f = this.files && this.files[0];
      if (!f) { state.imgData = null; $('pf-img-name').textContent = 'файл не выбран'; refreshPreview(); return; }
      $('pf-img-name').textContent = f.name + ' → сжатие…';
      compressImage(f, function (dataUrl) {
        state.imgData = dataUrl;
        $('pf-img-name').textContent = f.name + ' (сжато до ~320px)';
        refreshPreview();
      });
    });
    ['pf-name', 'pf-price', 'pf-img-url'].forEach(function (id) {
      $(id).addEventListener('input', refreshPreview);
    });
    /* v0.22.0 (fp №14): смена категории — перерисовка секции «Характеристики» */
    $('pf-cat').addEventListener('change', function () { renderAttrEditor(editingProduct()); });
    $('prod-body').addEventListener('click', function (e) {
      var act = e.target.closest('button[data-active]');
      if (act) {
        var id = Number(act.getAttribute('data-active'));
        var p = state.products.filter(function (x) { return x.id === id; })[0];
        if (!p) return;
        act.disabled = true;
        db.from('products').update({ is_active: !p.is_active }).eq('id', id).then(function (res) {
          if (res.error) { alert('Не удалось переключить: ' + res.error.message); act.disabled = false; return; }
          load();
        });
        return;
      }
      /* v0.22.0 (П14/Д12): «Предпросмотр» — модалка витрины из данных БД */
      var pv = e.target.closest('button[data-preview]');
      if (pv) { openDbPreview(Number(pv.getAttribute('data-preview'))); return; }
      var ed = e.target.closest('[data-edit]');
      if (ed) openModal(Number(ed.getAttribute('data-edit')));
    });
    load();
  });
})();
