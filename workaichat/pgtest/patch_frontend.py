#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Волна v0.17.0 — фронтенд-правки по внешнему ревью 06.10.2026.
Все замены — программные, с assertion на точное совпадение якоря (грабля №6).
Запуск из /home/user: python3 pgtest/patch_frontend.py
"""
import io
import os
import sys

ROOT = 'sisku'
EDITS = []   # (file, old, new, expected_count)


def e(f, old, new, cnt=1):
    EDITS.append((f, old, new, cnt))


# ============================ util.js ========================================
e('assets/js/util.js',
  """  function money(n) {
    return new Intl.NumberFormat('ru-RU').format(Math.round(Number(n || 0))) + ' ₽';
  }""",
  """  /* v0.17.0 (внешний ревью 06.10.2026, находка D1): форматирование чисел
     вынесено из money() — колбэки осей графиков админки используют fmtNum
     вместо локальных копий Intl.NumberFormat */
  function fmtNum(n) {
    return new Intl.NumberFormat('ru-RU').format(Math.round(Number(n || 0)));
  }
  function money(n) {
    return fmtNum(n) + ' ₽';
  }""")

e('assets/js/util.js',
  """  window.SiskuUtil = {
    esc: esc, safeUrl: safeUrl, money: money,""",
  """  /* ---------- заглушка изображений: делегирование вместо inline onerror ----
     v0.17.0 (внешний ревью 06.10.2026, находка E3): инлайновые on*-обработчики
     запрещены (check-repo v2.5). Событие error ресурса не всплывает, но
     ловится в фазе capture на document: <img data-img-fallback="stub"> при
     ошибке загрузки получает src заглушки от провайдера модуля страницы
     (site.js/products.js регистрируют его через setStubProvider). */
  var stubProvider = null;
  function setStubProvider(fn) { stubProvider = fn; }
  document.addEventListener('error', function (e) {
    var t = e.target;
    if (t && t.tagName === 'IMG' && t.getAttribute &&
        t.getAttribute('data-img-fallback') === 'stub') {
      t.removeAttribute('data-img-fallback');   /* защита от цикла подмен */
      if (stubProvider) { try { t.src = stubProvider(); } catch (err) { /* тишина */ } }
    }
  }, true);

  window.SiskuUtil = {
    esc: esc, safeUrl: safeUrl, money: money, fmtNum: fmtNum,
    setStubProvider: setStubProvider,""")

# ============================ site.js ========================================
e('assets/js/site.js',
  """  /* заглушка вместо отсутствующего фото (монограмма на градиенте) */
  function stubSrc() {
    var svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 400">' +
      '<rect width="300" height="400" fill="#1D1D24"/>' +
      '<rect x="1" y="1" width="298" height="398" fill="none" stroke="#2A2A33"/>' +
      '<text x="150" y="215" font-family="Georgia,serif" font-size="64" fill="#C9A96A" text-anchor="middle">S</text></svg>';
    return 'data:image/svg+xml,' + encodeURIComponent(svg);
  }
  function imgTag(src, alt, cls) {
    return '<img class="' + (cls || '') + '" src="' + esc(src || stubSrc()) + '" alt="' + esc(alt || '') + '" loading="lazy" onerror="this.onerror=null;this.src=\\'' + stubSrc() + '\\'">';
  }""",
  """  /* заглушка вместо отсутствующего фото (монограмма на градиенте)
     v0.17.0 (внешний ревью 06.10.2026, находка B4): dataURL кэшируется —
     раньше пересоздавался на каждый рендер */
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
  /* v0.17.0 (находка E3): вместо inline onerror — data-img-fallback +
     делегирование в util.js; заглушка — провайдер подмены src */
  if (window.SiskuUtil) SiskuUtil.setStubProvider(stubSrc);
  function imgTag(src, alt, cls) {
    return '<img class="' + (cls || '') + '" src="' + esc(src || stubSrc()) + '" alt="' + esc(alt || '') + '" loading="lazy" data-img-fallback="stub">';
  }""")

e('assets/js/site.js',
  """    img.src = dark ? 'assets/img/hero-dark.jpg' : 'assets/img/hero.jpg';""",
  """    img.src = dark ? 'assets/img/hero-dark.webp' : 'assets/img/hero.webp';   /* v0.17.0 (находка B1): WebP */""")

e('assets/js/site.js',
  """    img.src = custom || 'assets/img/products/p001.jpg';""",
  """    img.src = custom || 'assets/img/products/p001.webp';   /* v0.17.0 (находка B1): WebP */""")

e('assets/js/site.js',
  """    loadAll().catch(function (err) {
      $('product-grid').innerHTML = '<div class="cart-empty" style="grid-column:1/-1">Не удалось загрузить каталог: ' + esc(err.message) + '</div>';
    });""",
  """    loadAll().catch(function (err) {
      /* v0.17.0 (находка D2): сообщение — через friendlyDbError (сырой код
         ошибки покупателю не показывается) */
      $('product-grid').innerHTML = '<div class="cart-empty" style="grid-column:1/-1">Не удалось загрузить каталог: ' + esc(SiskuUtil.friendlyDbError(err)) + '</div>';
    });""")

# ============================ index.html =====================================
e('index.html',
  """<img class="hero-img" src="assets/img/hero.jpg" alt="Коллекция Sisku: пальто и парфюмерия в светлом интерьере">""",
  """<img class="hero-img" src="assets/img/hero.webp" alt="Коллекция Sisku: пальто и парфюмерия в светлом интерьере" width="1600" height="1600" fetchpriority="high">""")

e('index.html',
  """<img id="about-img" src="assets/img/products/p001.jpg" alt="Пальто из коллекции Sisku">""",
  """<img id="about-img" src="assets/img/products/p001.webp" alt="Пальто из коллекции Sisku" width="1200" height="1200" loading="lazy">""")

e('index.html',
  """<a data-content-href="contacts.messenger_url" data-content="contacts.messenger" href="https://t.me/sisku_shop">Написать в Telegram</a>""",
  """<a data-content-href="contacts.messenger_url" data-content="contacts.messenger">Написать в Telegram</a><!-- v0.17.0 (находка F3): хардкод-fallback URL убран — href только из site_content (правило: изменяемые тексты не хардкодить) -->""")

# ============================ brandbook.html =================================
e('brandbook.html',
  """<div class="pvf-media"><img src="assets/img/products/p001.jpg" alt=""></div>""",
  """<div class="pvf-media"><img src="assets/img/products/p001.webp" alt="" loading="lazy"></div>""")
e('brandbook.html',
  """<div class="pvf-media"><img src="assets/img/products/p006.jpg" alt=""></div>""",
  """<div class="pvf-media"><img src="assets/img/products/p006.webp" alt="" loading="lazy"></div>""")

# ============================ products.html ==================================
e('products.html',
  """<input id="pf-img-url" placeholder="или ссылка/путь: assets/img/products/p009.jpg">""",
  """<input id="pf-img-url" placeholder="или ссылка/путь: assets/img/products/p009.webp">""")
e('products.html',
  """<iframe class="pvfull-frame" id="pvfull-frame" title="Предпросмотр карточки товара на витрине"></iframe>""",
  """<iframe class="pvfull-frame" id="pvfull-frame" title="Предпросмотр карточки товара на витрине" sandbox=""></iframe><!-- v0.17.0 (находка A1): sandbox — скрипты в предпросмотре запрещены -->""")

# ============================ products.js ====================================
e('assets/js/products.js',
  """  function stubSrc() {
    var svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 400">' +
      '<rect width="300" height="400" fill="#1D1D24"/>' +
      '<rect x="1" y="1" width="298" height="398" fill="none" stroke="#2A2A33"/>' +
      '<text x="150" y="215" font-family="Georgia,serif" font-size="64" fill="#C9A96A" text-anchor="middle">S</text></svg>';
    return 'data:image/svg+xml,' + encodeURIComponent(svg);
  }""",
  """  /* v0.17.0 (находка B4): dataURL заглушки кэшируется (раньше пересоздавался
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
  if (window.SiskuUtil) SiskuUtil.setStubProvider(stubSrc);""")

e('assets/js/products.js',
  """        '<td><img class="thumb" src="' + esc(p.image_url || stubSrc()) + '" alt="" onerror="this.onerror=null;this.src=\\'' + stubSrc() + '\\'"></td>' +""",
  """        '<td><img class="thumb" src="' + esc(p.image_url || stubSrc()) + '" alt="" data-img-fallback="stub"></td>' +""")

e('assets/js/products.js',
  """    var theme = document.documentElement.getAttribute('data-theme') === 'light' ? 'light' : 'dark';""",
  """    var theme = document.documentElement.getAttribute('data-theme') === 'light' ? 'light' : 'dark';
    /* v0.17.0 (находка A1): токены брендбука для предпросмотра — статическим
       инлайн-<style> из УЖЕ ПРИМЕНЁННЫХ переменных страницы (computed styles),
       со строгой валидацией: цвет — только hex, типографика — только число,
       accent-soft пересобирается из валидированного accent. Скриптов в iframe
       нет (sandbox="" в products.html) — путь исполнения JS из
       неконтролируемого localStorage-кэша токенов закрыт. */
    var pvTokenCss = (function () {
      var cs = getComputedStyle(document.documentElement);
      var hexOk = /^#[0-9a-fA-F]{3,8}$/;
      var names = ['--bg', '--surface', '--card', '--text', '--muted', '--accent',
                   '--line', '--btn-bg', '--btn-text'];
      var css = ':root{', accent = '';
      names.forEach(function (n) {
        var v = (cs.getPropertyValue(n) || '').trim();
        if (!hexOk.test(v)) return;
        css += n + ':' + v + ';';
        if (n === '--accent') accent = v;
      });
      if (accent) css += '--accent-soft:color-mix(in srgb, ' + accent + ' ' +
        (theme === 'dark' ? '14' : '10') + '%, transparent);';
      var fb = parseFloat(cs.getPropertyValue('--font-base'));
      if (isFinite(fb) && fb > 8 && fb < 32) css += '--font-base:' + fb + 'px;';
      var ts = parseFloat(cs.getPropertyValue('--type-scale'));
      if (isFinite(ts) && ts > 0.5 && ts < 3) css += '--type-scale:' + ts + ';';
      return css + '}';
    })();""")

e('assets/js/products.js',
  """        '<div class="product-media"><img src="' + esc(img) + '" alt="" onerror="this.style.display=\\'none\\'"></div>' +""",
  """        '<div class="product-media"><img src="' + esc(img) + '" alt=""></div>' +""")

e('assets/js/products.js',
  """      '<link rel="stylesheet" href="assets/css/fonts.css">' +
      '<link rel="stylesheet" href="assets/css/styles.css">' +
      '<script src="assets/js/brandvars.js"></' + 'script>' +
      '</head><body style="margin:0;padding:28px 20px">' + card + '</body></html>';""",
  """      '<link rel="stylesheet" href="assets/css/fonts.css">' +
      '<link rel="stylesheet" href="assets/css/styles.css">' +
      '<style>' + pvTokenCss + '</style>' +
      '</head><body style="margin:0;padding:28px 20px">' + card + '</body></html>';""")

e('assets/js/products.js',
  """        var article = get('article'), name = get('name'), price = Number(get('price'));
        if (!article || !name || !price) { errors.push('строка ' + (i + 2) + ': пропущены article/name/price'); return; }
        payload.push({
          article: article, name: name, price: price,
          brand_id: get('brand_id') ? Number(get('brand_id')) : null,
          category_id: get('category_id') ? Number(get('category_id')) : null,""",
  """        var article = get('article'), name = get('name'), price = Number(get('price'));
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
          category_id: catId,""")

# ============================ admin.js =======================================
e('assets/js/admin.js',
  """  function itemsOf(orderId) { return state.items.filter(function (i) { return i.order_id === orderId; }); }""",
  """  /* v0.17.0 (внешний ревью 06.10.2026, находка B3): индекс order_id → позиции
     (строится в loadAll) вместо O(N²) filter на каждую строку таблицы */
  function itemsOf(orderId) {
    if (state.itemsByOrder) return state.itemsByOrder[orderId] || [];
    return state.items.filter(function (i) { return i.order_id === orderId; });
  }

  /* v0.17.0 (находка B2): после смены статуса/оплаты — точечное обновление:
     заказ в state правится на месте, история этого заказа перезапрашивается одним
     лёгким запросом, список/карточка/статистика пересчитываются локально —
     полная перезагрузка draft_admin_bundle больше не дёргается */
  function refreshOrderHistory(orderId) {
    if (!db) return Promise.resolve();
    return db.from('order_status_history').select('*').eq('order_id', orderId)
      .then(function (res) {
        if (res.error || !res.data) return;
        state.history = state.history.filter(function (h) { return h.order_id !== orderId; })
          .concat(res.data);
      });
  }""")

e('assets/js/admin.js',
  """      state.orders = d.orders;
      state.items = d.items;""",
  """      state.orders = d.orders;
      state.items = d.items;
      state.itemsByOrder = {};   /* v0.17.0 (находка B3) */
      d.items.forEach(function (i) {
        (state.itemsByOrder[i.order_id] = state.itemsByOrder[i.order_id] || []).push(i);
      });""")

e('assets/js/admin.js',
  """            if (res.error) { $('oc-error').textContent = res.error.message; $('oc-error').hidden = false; self.disabled = false; return; }
            loadAll().then(function () { openOrder(o.id); });""",
  """            if (res.error) { $('oc-error').textContent = res.error.message; $('oc-error').hidden = false; self.disabled = false; return; }
            /* v0.17.0 (находка B2): точечное обновление вместо loadAll() */
            var ns = state.statuses.filter(function (s) { return s.code === code; })[0];
            if (ns) o.status_id = ns.id;
            refreshOrderHistory(o.id).then(function () {
              renderOrders(); renderStatsActive(); openOrder(o.id);
            });""")

e('assets/js/admin.js',
  """            if (res && res.error) { $('oc-error').textContent = res.error.message; $('oc-error').hidden = false; self.disabled = false; return; }
            loadAll().then(function () { openOrder(o.id); });""",
  """            if (res && res.error) { $('oc-error').textContent = res.error.message; $('oc-error').hidden = false; self.disabled = false; return; }
            /* v0.17.0 (находка B2): признак оплаты — точечно; событие оплаты
               в истории придёт лёгким запросом refreshOrderHistory */
            o.is_paid = !o.is_paid;
            o.paid_at = o.is_paid ? new Date().toISOString() : null;
            refreshOrderHistory(o.id).then(function () {
              renderOrders(); renderStatsActive(); openOrder(o.id);
            });""")

e('assets/js/admin.js',
  """    $('btn-refresh').addEventListener('click', function () {
      $('orders-loading').hidden = false;
      loadAll();
    });""",
  """    $('btn-refresh').addEventListener('click', function () {
      $('orders-loading').hidden = false;
      /* v0.17.0 (находка D2): сетевая ошибка при обновлении — плашка,
         а не вечный скелетон (unhandled rejection больше не теряется) */
      loadAll().catch(function (err) {
        $('orders-loading').hidden = true;
        $('orders-error').hidden = false;
        $('orders-error').textContent = 'Ошибка загрузки: ' + SiskuUtil.friendlyDbError(err);
      });
    });""")

e('assets/js/admin.js',
  """    loadAll().catch(function (err) {
      $('orders-loading').hidden = true;
      $('orders-error').hidden = false;
      $('orders-error').textContent = 'Ошибка загрузки: ' + err.message;
    });""",
  """    loadAll().catch(function (err) {
      $('orders-loading').hidden = true;
      $('orders-error').hidden = false;
      /* v0.17.0 (находка D2): читаемое сообщение вместо сырого */
      $('orders-error').textContent = 'Ошибка загрузки: ' + SiskuUtil.friendlyDbError(err);
    });""")

e('assets/js/admin.js',
  """y1: { position: 'right', grid: { display: false }, ticks: { callback: function (v) { return new Intl.NumberFormat('ru-RU').format(v); } } }""",
  """y1: { position: 'right', grid: { display: false }, ticks: { callback: function (v) { return SiskuUtil.fmtNum(v); } } }""",
  cnt=2)

e('assets/js/admin.js',
  """          /* при «Товар вернулся на склад» заказ переведён в «Возврат»,
             остатки — в карантине: обновляем оба бандла и перерисовываем */""",
  """          /* при «Товар вернулся на склад» заказ переведён в «Возврат»,
             остатки — в карантине: обновляем оба бандла и перерисовываем
             (v0.17.0, находка B2 — здесь полная перезагрузка ОПРАВДАНА:
             переход заявки меняет заказ, остатки и карантин одновременно) */""")

# ============================ brandvars.js ===================================
e('assets/js/brandvars.js',
  """      var v = VAR_MAP[r.key];
      if (v) el.style.setProperty(v, r.value);
      if (r.key === 'accent') accent = r.value;""",
  """      var v = VAR_MAP[r.key];
      /* v0.17.0 (внешний ревью 06.10.2026, находка A1): значения из кэша
         валидируются до применения — цвет только hex (CSS-инъекция из
         localStorage-кэша токенов исключена; hex-валидация сохранения брендбука
         v0.14.0 теперь продублирована на пути применения) */
      var cv = String(r.value == null ? '' : r.value).trim();
      if (v && /^#[0-9a-fA-F]{3,8}$/.test(cv)) {
        el.style.setProperty(v, cv);
        if (r.key === 'accent') accent = cv;
      }""")

e('assets/js/brandvars.js',
  """    if (typoBase) el.style.setProperty('--font-base', typoBase + 'px');
    if (typoScale) el.style.setProperty('--type-scale', (Number(typoScale) / 100));""",
  """    /* v0.17.0 (находка A1): типографика — только число */
    if (typoBase && /^\\d{1,3}$/.test(String(typoBase).trim())) el.style.setProperty('--font-base', String(typoBase).trim() + 'px');
    if (typoScale && /^\\d{2,3}$/.test(String(typoScale).trim())) el.style.setProperty('--type-scale', (Number(typoScale) / 100));""")


# ---------------------------------------------------------------------------
def main():
    changed = {}
    for f, old, new, cnt in EDITS:
        path = os.path.join(ROOT, f)
        if path not in changed:
            changed[path] = io.open(path, encoding='utf-8').read()
        n = changed[path].count(old)
        if n != cnt:
            print('FAIL якорь (%s) найден %d раз (жду %d): %s...' % (f, n, cnt, old[:70]))
            sys.exit(1)
        changed[path] = changed[path].replace(old, new)
    for path, text in changed.items():
        io.open(path, 'w', encoding='utf-8').write(text)
        print('OK %s' % path)
    print('всего файлов изменено:', len(changed))


if __name__ == '__main__':
    main()
