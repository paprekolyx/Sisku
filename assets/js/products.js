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
   ========================================================================== */
(function () {
  'use strict';

  var state = {
    products: [], variants: {}, brands: [], cats: [], reserved: {},
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
      db.rpc('draft_reserved_map')
    ]).then(function (res) {
      res.forEach(function (r) { if (r.error) throw r.error; });
      state.products = res[0].data || [];
      state.variants = {};
      (res[1].data || []).forEach(function (v) {
        (state.variants[v.product_id] = state.variants[v.product_id] || []).push(v);
      });
      state.brands = res[2].data || [];
      state.cats = res[3].data || [];
      state.reserved = {};
      (res[4].data || []).forEach(function (r) { state.reserved[r.variant_id] = Number(r.reserved) || 0; });
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
        '<td class="user-fio" data-edit="' + p.id + '" title="Открыть карточку">' + esc(p.name) + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(catName(p.category_id)) + '</td>' +
        '<td class="muted" style="font-size:13px">' + esc(brandName(p.brand_id)) + '</td>' +
        '<td class="tabular">' + money(p.price) + '</td>' +
        '<td class="tabular' + (stock < 3 ? ' low-stock' : '') + '">' + stock + '</td>' +
        '<td class="tabular muted">' + reservedOf(p.id) + '</td>' +
        '<td class="tabular' + (quarantineOf(p.id) ? ' quarantine-cell' : ' muted') + '">' + (quarantineOf(p.id) || '—') + '</td>' +
        '<td><button class="btn" data-active="' + p.id + '" style="min-height:32px;padding:0 12px">' +
          (p.is_active ? 'активен' : 'скрыт') + '</button></td>' +
        '<td><button class="btn" data-edit="' + p.id + '" style="min-height:34px;padding:0 14px">Карточка</button></td>' +
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
  }

  /* ---------- полный предпросмотр карточки витрины (правка 2.15) ----------
     Разметка модалки товара витрины рендерится в iframe, который грузит
     настоящие styles.css/fonts.css и применяет кэш токенов брендбука
     (brandvars.js) — переиспользование, а не дублирование стилей.
     Тема iframe — текущая тема админки. */
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
    var isNew = true;
    if (state.editingId) {
      var pr = state.products.filter(function (x) { return x.id === state.editingId; })[0];
      isNew = !!(pr && pr.created_at && (Date.now() - new Date(pr.created_at).getTime()) < 30 * 864e5);
    }
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
    var card =
      '<div class="product-grid" style="max-width:920px;margin:0 auto;border:1px solid var(--line);background:var(--surface)">' +
        '<div class="product-media"><img src="' + esc(img) + '" alt=""></div>' +
        '<div class="product-info">' +
          (isNew ? '<div style="margin-bottom:12px"><span style="display:inline-block;background:var(--accent);color:var(--bg);font-size:10.5px;letter-spacing:.14em;text-transform:uppercase;padding:4px 10px;font-weight:600">New</span></div>' : '') +
          '<div class="brand">' + esc(brand) + '</div>' +
          '<h3>' + esc(name) + '</h3>' +
          '<div class="price">' + money(price) + '</div>' +
          '<p class="desc">' + esc(desc) + '</p>' +
          '<div class="variant-label">' + (isPerfume ? 'Объём' : 'Размер') + '</div>' +
          '<div class="variants">' + (vars.length
            ? vars.map(function (v) {
                return '<button class="variant' + (v.stock ? '' : ' out') + '">' + esc(v.label) +
                  '<span class="st">' + (v.stock ? v.stock + ' шт.' : 'нет') + '</span></button>';
              }).join('')
            : '<span class="muted">варианты не заданы</span>') + '</div>' +
          '<div style="margin-top:26px;display:flex;gap:12px;align-items:center">' +
            '<button class="btn accent">В корзину</button>' +
            '<span class="muted" style="font-size:13px">' + (totalStock ? 'остаток: ' + totalStock + ' шт.' : 'нет в наличии') + '</span>' +
          '</div>' +
        '</div>' +
      '</div>';
    $('pvfull-frame').srcdoc =
      '<!DOCTYPE html><html lang="ru" data-theme="' + theme + '"><head><meta charset="utf-8">' +
      '<link rel="stylesheet" href="assets/css/fonts.css">' +
      '<link rel="stylesheet" href="assets/css/styles.css">' +
      '<style>' + pvTokenCss + '</style>' +
      '</head><body style="margin:0;padding:28px 20px">' + card + '</body></html>';
    $('pvfull-modal-backdrop').classList.add('open');
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
        var warns = results.filter(function (r) { return r && r.error; }).map(function (r) { return r.error.message; });
        return warns;
      });
    };

    var done = function (warns) {
      state.saving = false;
      $('pf-submit').disabled = false;
      closeModal();
      load();
      if (warns && warns.length) {
        alert('Товар сохранён, но по вариантам: ' + warns.join('; ') + ' (вариант из заказа удалить нельзя — он остался).');
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
        saveProduct(state.editingId).then(done);
      }).catch(function (err) { fail('Ошибка сети: ' + err.message); });
    } else {
      db.from('products').insert(row).then(function (res) {
        if (res.error) { fail(res.error.message); return; }
        var newId = res.data && res.data.length ? res.data[0].id : null;
        if (!newId) { fail('Товар создан, но id не вернулся — обновите список'); return; }
        saveProduct(newId).then(done);
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
      var ed = e.target.closest('[data-edit]');
      if (ed) openModal(Number(ed.getAttribute('data-edit')));
    });
    load();
  });
})();
