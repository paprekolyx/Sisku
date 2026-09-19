/* ==========================================================================
   SISKU · site.js — логика витрины (черновик v0.1.0-draft)
   Паттерны учебного проекта: подстановка site_content, корзина в localStorage,
   скелетоны, экранирование вывода, заказ только через серверную функцию.
   ========================================================================== */
(function () {
  'use strict';

  var CART_KEY = 'sisku_cart_v1';
  var PAGE_SIZE = 8;

  var state = {
    brands: [], categories: [], products: [], variants: {},
    payments: [], deliveries: [],
    filterCat: '', filterBrand: '', filterStock: false, sort: 'new',
    shown: PAGE_SIZE,
    cart: loadCart(),
    currentProduct: null, currentVariant: null
  };

  /* ---------- утилиты ---------- */
  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }
  function money(n) {
    return new Intl.NumberFormat('ru-RU').format(Math.round(Number(n || 0))) + ' ₽';
  }
  function toast(msg) {
    var t = $('toast');
    t.textContent = msg;
    t.classList.add('show');
    clearTimeout(t._h);
    t._h = setTimeout(function () { t.classList.remove('show'); }, 2600);
  }
  /* заглушка вместо отсутствующего фото (монограмма на градиенте) */
  function stubSrc() {
    var svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 400">' +
      '<rect width="300" height="400" fill="#1D1D24"/>' +
      '<rect x="1" y="1" width="298" height="398" fill="none" stroke="#2A2A33"/>' +
      '<text x="150" y="215" font-family="Georgia,serif" font-size="64" fill="#C9A96A" text-anchor="middle">S</text></svg>';
    return 'data:image/svg+xml,' + encodeURIComponent(svg);
  }
  function imgTag(src, alt, cls) {
    return '<img class="' + (cls || '') + '" src="' + esc(src || stubSrc()) + '" alt="' + esc(alt || '') + '" loading="lazy" onerror="this.onerror=null;this.src=\'' + stubSrc() + '\'">';
  }

  /* ---------- корзина (localStorage, паттерн учебного проекта) ---------- */
  function loadCart() {
    try { return JSON.parse(localStorage.getItem(CART_KEY)) || []; } catch (e) { return []; }
  }
  function saveCart() { localStorage.setItem(CART_KEY, JSON.stringify(state.cart)); }
  function cartCount() {
    return state.cart.reduce(function (s, l) { return s + l.qty; }, 0);
  }
  function findVariant(productId, variantId) {
    var list = state.variants[productId] || [];
    for (var i = 0; i < list.length; i++) if (list[i].id === variantId) return list[i];
    return null;
  }
  function findProduct(id) {
    for (var i = 0; i < state.products.length; i++) if (state.products[i].id === id) return state.products[i];
    return null;
  }
  function brandName(id) {
    for (var i = 0; i < state.brands.length; i++) if (state.brands[i].id === id) return state.brands[i].name;
    return '';
  }

  /* ---------- тема (механизм учебного проекта) ---------- */
  function initTheme() {
    $('theme-toggle').addEventListener('click', function () {
      var cur = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
      document.documentElement.setAttribute('data-theme', cur);
      try { localStorage.setItem('sisku_theme', cur); } catch (e) {}
    });
  }

  /* ---------- site_content: тексты подставляются из базы ---------- */
  function applyContent(rows) {
    var map = {};
    rows.forEach(function (r) { map[r.key] = r.value; });
    document.querySelectorAll('[data-content]').forEach(function (el) {
      var v = map[el.getAttribute('data-content')];
      if (v) el.textContent = v;               /* текст внутри тега остаётся запасным */
    });
    document.querySelectorAll('[data-content-href]').forEach(function (el) {
      var key = el.getAttribute('data-content-href');
      var v = map[key];
      if (key === 'contacts.email.href') v = map['contacts.email'] ? 'mailto:' + map['contacts.email'] : null;
      if (v) el.setAttribute('href', v);
    });
  }

  /* ---------- загрузка данных ---------- */
  function skeletonGrid() {
    var html = '';
    for (var i = 0; i < 8; i++) {
      html += '<div><div class="skeleton media"></div><div class="skeleton line"></div><div class="skeleton line" style="width:60%"></div></div>';
    }
    $('product-grid').innerHTML = html;
  }

  function loadAll() {
    if (!db) {
      $('product-grid').innerHTML = '<div class="cart-empty" style="grid-column:1/-1">База данных не подключена.<br>Заполните ключи в <code>assets/js/config.js</code> (инструкция: docs/setup-supabase.md).</div>';
      return Promise.reject(new Error(dbError || 'нет БД'));
    }
    skeletonGrid();
    return Promise.all([
      db.from('brands').select('*').eq('is_active', true).order('name'),
      db.from('categories').select('*').order('id'),
      db.from('products').select('*').eq('is_active', true).order('created_at', { ascending: false }),
      db.from('product_variants').select('*').order('sort_order'),
      db.from('site_content').select('key,value'),
      db.from('payment_methods').select('*').eq('is_active', true).order('id'),
      db.from('delivery_methods').select('*').eq('is_active', true).order('id')
    ]).then(function (res) {
      res.forEach(function (r) { if (r.error) throw r.error; });
      state.brands = res[0].data;
      state.categories = res[1].data;
      state.products = res[2].data;
      state.variants = {};
      res[3].data.forEach(function (v) {
        (state.variants[v.product_id] = state.variants[v.product_id] || []).push(v);
      });
      applyContent(res[4].data);
      state.payments = res[5].data;
      state.deliveries = res[6].data;
      buildFilters();
      buildOrderSelects();
      if (window.enhanceSelects) enhanceSelects();   /* кастомные селекты поверх нативных */
      renderCatalog();
      renderCart();
    });
  }

  /* ---------- фильтры ---------- */
  function buildFilters() {
    var chips = '<button class="chip active" data-cat="">Все</button>';
    state.categories.forEach(function (c) {
      chips += '<button class="chip" data-cat="' + c.id + '">' + esc(c.name) + '</button>';
    });
    $('cat-chips').innerHTML = chips;
    $('cat-chips').addEventListener('click', function (e) {
      var b = e.target.closest('.chip');
      if (!b) return;
      state.filterCat = b.getAttribute('data-cat');
      state.shown = PAGE_SIZE;
      $('cat-chips').querySelectorAll('.chip').forEach(function (x) { x.classList.remove('active'); });
      b.classList.add('active');
      renderCatalog();
    });

    var bo = '';
    state.brands.forEach(function (b) { bo += '<option value="' + b.id + '">' + esc(b.name) + '</option>'; });
    $('brand-filter').insertAdjacentHTML('beforeend', bo);
    $('brand-filter').addEventListener('change', function () { state.filterBrand = this.value; state.shown = PAGE_SIZE; renderCatalog(); });
    $('sort-filter').addEventListener('change', function () { state.sort = this.value; renderCatalog(); });
    $('stock-filter').addEventListener('click', function () {
      state.filterStock = !state.filterStock;
      this.classList.toggle('active', state.filterStock);
      state.shown = PAGE_SIZE;
      renderCatalog();
    });
    $('show-more').addEventListener('click', function () { state.shown += PAGE_SIZE; renderCatalog(); });
  }

  function productStock(p) {
    return (state.variants[p.id] || []).reduce(function (s, v) { return s + v.stock; }, 0);
  }
  function filteredProducts() {
    var list = state.products.slice();
    if (state.filterCat) list = list.filter(function (p) { return String(p.category_id) === state.filterCat; });
    if (state.filterBrand) list = list.filter(function (p) { return String(p.brand_id) === state.filterBrand; });
    if (state.filterStock) list = list.filter(function (p) { return productStock(p) > 0; });
    if (state.sort === 'asc') list.sort(function (a, b) { return a.price - b.price; });
    else if (state.sort === 'desc') list.sort(function (a, b) { return b.price - a.price; });
    return list;
  }

  /* ---------- каталог ---------- */
  function renderCatalog() {
    var list = filteredProducts();
    var visible = list.slice(0, state.shown);
    $('catalog-count').textContent = list.length ? list.length + ' товар' + plural(list.length) : 'скоро пополнение';
    if (!visible.length) {
      $('product-grid').innerHTML = '<div class="cart-empty" style="grid-column:1/-1">По выбранным фильтрам ничего нет</div>';
      $('show-more').hidden = true;
      return;
    }
    $('product-grid').innerHTML = visible.map(function (p) {
      var stock = productStock(p);
      return '<article class="card" data-id="' + p.id + '" tabindex="0">' +
        '<div class="card-media">' + imgTag(p.image_url, p.name) +
          (p.created_at && (Date.now() - new Date(p.created_at).getTime()) < 30 * 864e5 ? '<span class="badge">New</span>' : '') +
          '<button class="quick" data-id="' + p.id + '">Быстрый просмотр</button>' +
        '</div>' +
        '<div class="card-brand">' + esc(brandName(p.brand_id)) + '</div>' +
        '<div class="card-name">' + esc(p.name) + '</div>' +
        '<div class="card-price">' + money(p.price) + '</div>' +
        '<div class="card-stock' + (stock ? '' : ' out') + '">' + (stock ? 'в наличии' : 'нет в наличии') + '</div>' +
      '</article>';
    }).join('');
    $('show-more').hidden = list.length <= state.shown;
  }
  function plural(n) {
    var m = n % 100;
    if (m >= 11 && m <= 14) return 'ов';
    switch (n % 10) { case 1: return ''; case 2: case 3: case 4: return 'а'; default: return 'ов'; }
  }

  /* ---------- карточка товара ---------- */
  function openProduct(id) {
    var p = findProduct(Number(id));
    if (!p) return;
    state.currentProduct = p;
    state.currentVariant = null;
    var vars = state.variants[p.id] || [];
    var isPerfume = /мл/i.test((vars[0] || {}).label || '');
    $('pm-img').src = p.image_url || stubSrc();
    $('pm-img').alt = p.name;
    $('pm-brand').textContent = brandName(p.brand_id);
    $('pm-name').textContent = p.name;
    $('pm-price').textContent = money(p.price);
    $('pm-desc').textContent = p.description || '';
    $('pm-variant-label').textContent = isPerfume ? 'Объём' : 'Размер';
    $('pm-variants').innerHTML = vars.map(function (v) {
      return '<button class="variant' + (v.stock ? '' : ' out') + '" data-vid="' + v.id + '">' +
        esc(v.label) + '<span class="st">' + (v.stock ? v.stock + ' шт.' : 'нет') + '</span></button>';
    }).join('') || '<span class="muted">варианты не заданы</span>';
    $('pm-variants').querySelectorAll('.variant').forEach(function (b) {
      b.addEventListener('click', function () {
        if (b.classList.contains('out')) return;
        $('pm-variants').querySelectorAll('.variant').forEach(function (x) { x.classList.remove('active'); });
        b.classList.add('active');
        state.currentVariant = Number(b.getAttribute('data-vid'));
        var v = findVariant(p.id, state.currentVariant);
        $('pm-stock').textContent = v ? 'остаток: ' + v.stock + ' шт.' : '';
      });
    });
    var first = vars.filter(function (v) { return v.stock > 0; })[0];
    if (first) {
      var btn = $('pm-variants').querySelector('[data-vid="' + first.id + '"]');
      if (btn) btn.click();
    }
    openModal('product-modal-backdrop');
  }

  /* ---------- корзина ---------- */
  function addToCart(productId, variantId) {
    var v = findVariant(productId, variantId);
    if (!v || !v.stock) { toast('Нет в наличии'); return; }
    var line = null;
    state.cart.forEach(function (l) { if (l.product_id === productId && l.variant_id === variantId) line = l; });
    if (line) {
      if (line.qty >= v.stock) { toast('Больше нет: остаток ' + v.stock + ' шт.'); return; }
      line.qty += 1;
    } else {
      state.cart.push({ product_id: productId, variant_id: variantId, qty: 1 });
    }
    saveCart(); renderCart();
    toast('Добавлено в корзину');
  }
  function renderCart() {
    var n = cartCount();
    $('cart-count').hidden = !n;
    $('cart-count').textContent = n;
    $('cart-clear').hidden = !state.cart.length;
    if (!state.cart.length) {
      $('cart-body').innerHTML = '<div class="cart-empty">Корзина пуста</div>';
      $('cart-total').textContent = money(0);
      $('checkout-btn').disabled = true;
      return;
    }
    $('checkout-btn').disabled = false;
    var total = 0;
    $('cart-body').innerHTML = state.cart.map(function (l, i) {
      var p = findProduct(l.product_id);
      var v = findVariant(l.product_id, l.variant_id);
      if (!p) return '';
      var sum = p.price * l.qty;
      total += sum;
      return '<div class="cart-line">' + imgTag(p.image_url, p.name) +
        '<div><div class="nm">' + esc(p.name) + '</div>' +
        '<div class="vr">' + esc(brandName(p.brand_id)) + (v ? ' · ' + esc(v.label) : '') + '</div>' +
        '<div class="qty"><button data-act="minus" data-i="' + i + '" aria-label="Меньше">−</button><span>' + l.qty + '</span><button data-act="plus" data-i="' + i + '" aria-label="Больше">+</button></div></div>' +
        '<div><div class="pr">' + money(sum) + '</div><button class="rm" data-act="rm" data-i="' + i + '">убрать</button></div>' +
      '</div>';
    }).join('');
    $('cart-total').textContent = money(total);
  }
  function cartTotal() {
    return state.cart.reduce(function (s, l) {
      var p = findProduct(l.product_id);
      return s + (p ? p.price * l.qty : 0);
    }, 0);
  }

  /* ---------- модалки / drawer ---------- */
  function openModal(id) { $(id).classList.add('open'); document.body.style.overflow = 'hidden'; }
  function closeModal(id) { $(id).classList.remove('open'); document.body.style.overflow = ''; }
  function initModals() {
    document.querySelectorAll('[data-close]').forEach(function (b) {
      b.addEventListener('click', function () { closeModal(b.getAttribute('data-close')); });
    });
    document.querySelectorAll('.modal-backdrop').forEach(function (m) {
      m.addEventListener('click', function (e) { if (e.target === m) closeModal(m.id); });
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') document.querySelectorAll('.modal-backdrop.open').forEach(function (m) { closeModal(m.id); });
    });
    $('drawer-backdrop').addEventListener('click', closeDrawer);
    $('cart-close').addEventListener('click', closeDrawer);
    $('cart-open').addEventListener('click', function () {
      $('cart-drawer').classList.add('open');
      $('drawer-backdrop').classList.add('open');
    });
  }
  function closeDrawer() {
    $('cart-drawer').classList.remove('open');
    $('drawer-backdrop').classList.remove('open');
  }

  /* ---------- оформление заказа ---------- */
  function buildOrderSelects() {
    $('of-payment').innerHTML = state.payments.map(function (m) {
      return '<option value="' + m.id + '">' + esc(m.name) + '</option>';
    }).join('');
    $('of-delivery').innerHTML = state.deliveries.map(function (m) {
      var price = m.base_price > 0
        ? (m.price_max && m.price_max > m.base_price ? ' · ' + money(m.base_price) + '–' + money(m.price_max) : ' · ' + money(m.base_price))
        : ' · бесплатно';
      return '<option value="' + m.id + '">' + esc(m.name) + price + '</option>';
    }).join('');
    $('of-delivery').addEventListener('change', renderOrderSummary);
  }
  function renderOrderSummary() {
    var d = state.deliveries.filter(function (x) { return x.id === Number($('of-delivery').value); })[0];
    var deliv = d ? d.base_price : 0;
    var total = cartTotal();
    $('order-summary').innerHTML =
      '<div class="row"><span>Товары (' + cartCount() + ' шт.)</span><span>' + money(total) + '</span></div>' +
      '<div class="row"><span>Доставка</span><span>' + (deliv > 0 ? 'от ' + money(deliv) : 'бесплатно') + '</span></div>' +
      '<div class="row total"><span>Итого</span><span>' + money(total + deliv) + '</span></div>';
  }

  function setFieldError(inputId, msg) {
    var box = $(inputId).parentElement.querySelector('.err');
    if (msg) { box.textContent = msg; box.hidden = false; } else { box.hidden = true; }
  }
  function submitOrder(e) {
    e.preventDefault();
    var errBox = $('of-error');
    errBox.hidden = true;

    /* honeypot: боты заполняют скрытое поле — молча «принимаем» и выходим */
    if ($('of-hp').value) { closeModal('order-modal-backdrop'); return; }

    var name = $('of-name').value.trim();
    var phone = $('of-phone').value.trim();
    var email = $('of-email').value.trim();
    var ok = true;
    setFieldError('of-name', ''); setFieldError('of-phone', ''); setFieldError('of-email', '');
    if (name.length < 2) { setFieldError('of-name', 'Укажите имя'); ok = false; }
    if (!phone && !email) { setFieldError('of-phone', 'Телефон или e-mail для связи'); ok = false; }
    if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { setFieldError('of-email', 'Похоже, в адресе ошибка'); ok = false; }
    if (!ok) return;

    var btn = $('of-submit');
    btn.disabled = true;                       /* блокировка повторной отправки */
    btn.textContent = 'Отправляем…';

    db.rpc('create_order', { p: {
      customer_name: name,
      customer_phone: phone || null,
      customer_email: email || null,
      customer_address: $('of-address').value.trim() || null,
      payment_method_id: Number($('of-payment').value),
      delivery_method_id: Number($('of-delivery').value),
      comment: $('of-comment').value.trim() || null,
      items: state.cart.map(function (l) {
        return { product_id: l.product_id, variant_id: l.variant_id, quantity: l.qty };
      })
    } }).then(function (res) {
      btn.disabled = false;
      btn.textContent = 'Отправить заказ';
      if (res.error) { errBox.textContent = res.error.message; errBox.hidden = false; return; }
      $('os-number').textContent = '№ ' + res.data.order_id;
      $('order-form-view').hidden = true;
      $('order-success-view').hidden = false;
      state.cart = [];
      saveCart(); renderCart(); renderCatalog();   /* остатки изменились на сервере */
    }).catch(function (err) {
      btn.disabled = false;
      btn.textContent = 'Отправить заказ';
      errBox.textContent = 'Ошибка сети: ' + err.message;
      errBox.hidden = false;
    });
  }

  /* ---------- появление секций при скролле ---------- */
  function initReveal() {
    if (!('IntersectionObserver' in window)) {
      document.querySelectorAll('.reveal').forEach(function (el) { el.classList.add('in'); });
      return;
    }
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) { if (en.isIntersecting) { en.target.classList.add('in'); io.unobserve(en.target); } });
    }, { threshold: 0.12 });
    document.querySelectorAll('.reveal').forEach(function (el) { io.observe(el); });
  }

  /* ---------- старт ---------- */
  document.addEventListener('DOMContentLoaded', function () {
    $('ver-top').textContent = SITE_VERSION;
    $('ver-bottom').textContent = SITE_VERSION;
    initTheme();
    initModals();
    initReveal();

    /* кнопка «Очистить» в корзине */
    $('cart-clear').addEventListener('click', function () {
      if (!state.cart.length) return;
      state.cart = [];
      saveCart(); renderCart();
      toast('Корзина очищена');
    });
    /* универсальное открытие модалок кнопками (брендбук и пр.) */
    document.querySelectorAll('[data-open]').forEach(function (b) {
      b.addEventListener('click', function () { openModal(b.getAttribute('data-open')); });
    });

    $('product-grid').addEventListener('click', function (e) {
      var card = e.target.closest('.card');
      if (card) openProduct(card.getAttribute('data-id'));
    });
    $('product-grid').addEventListener('keydown', function (e) {
      if (e.key === 'Enter') {
        var card = e.target.closest('.card');
        if (card) openProduct(card.getAttribute('data-id'));
      }
    });
    $('pm-add').addEventListener('click', function () {
      if (!state.currentProduct) return;
      if (!state.currentVariant) { toast('Выберите ' + $('pm-variant-label').textContent.toLowerCase()); return; }
      addToCart(state.currentProduct.id, state.currentVariant);
    });
    $('cart-body').addEventListener('click', function (e) {
      var b = e.target.closest('button[data-act]');
      if (!b) return;
      var i = Number(b.getAttribute('data-i'));
      var line = state.cart[i];
      if (!line) return;
      var v = findVariant(line.product_id, line.variant_id);
      if (b.getAttribute('data-act') === 'plus') {
        if (v && line.qty >= v.stock) { toast('Остаток: ' + v.stock + ' шт.'); return; }
        line.qty += 1;
      } else if (b.getAttribute('data-act') === 'minus') {
        line.qty -= 1;
        if (line.qty < 1) state.cart.splice(i, 1);
      } else if (b.getAttribute('data-act') === 'rm') {
        state.cart.splice(i, 1);
      }
      saveCart(); renderCart();
    });
    $('checkout-btn').addEventListener('click', function () {
      if (!state.cart.length) return;
      closeDrawer();
      renderOrderSummary();
      $('order-form-view').hidden = false;
      $('order-success-view').hidden = true;
      openModal('order-modal-backdrop');
    });
    $('order-form').addEventListener('submit', submitOrder);

    loadAll().catch(function (err) {
      $('product-grid').innerHTML = '<div class="cart-empty" style="grid-column:1/-1">Не удалось загрузить каталог: ' + esc(err.message) + '</div>';
    });
  });
})();
