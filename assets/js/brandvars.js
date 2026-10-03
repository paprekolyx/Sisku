/* ==========================================================================
   SISKU · brandvars.js — токены брендбука из таблицы brand_colors
   v0.11.0 — витрина; v0.13.0 — ТАКЖЕ АДМИН-ПАНЕЛЬ.
   • loadAndApplyBrand(db): читает brand_colors, подставляет значения
     в CSS-переменные, замеряет время применения (localStorage
     'sisku_theme_apply_ms' + console.info) и КЭШИРУЕТ строки в localStorage.
   • applyBrandCached(): синхронно применяет кэш токенов. Скрипт подключён
     в <head> всех страниц (витрина, вход, админка) и сразу сам применяет
     кэш — брендбук подхватывается ДО первой отрисовки, без запроса к базе
     и без «моргания». При первом визите кэш пуст — работают цвета по умолчанию.
   • brandCacheSave(rows): обновляет кэш (brandbook.js после сохранения).
   • brandContrast(hex1, hex2): коэффициент контраста WCAG 2.1.
   • brandPairs(theme): контрольные пары токенов для проверки контраста.
   При переключении темы applyBrandCached() вызывается повторно
   (admintheme.js в админке, site.js на витрине) — инлайн-переменные
   перечитываются под строки новой темы.
   ========================================================================== */
(function () {
  'use strict';

  var CACHE_KEY = 'sisku_brand_colors_v1';

  var VAR_MAP = {
    bg: '--bg', surface: '--surface', card: '--card', text: '--text',
    muted: '--muted', accent: '--accent', line: '--line',
    btn_bg: '--btn-bg', btn_text: '--btn-text'
  };

  function currentTheme(el) {
    return el.getAttribute('data-theme') === 'dark' ? 'dark' : 'light';
  }

  function applyVars(rows, root) {
    var el = root || document.documentElement;
    var typoBase = null, typoScale = null, accent = null;
    var cur = currentTheme(el);
    rows.forEach(function (r) {
      if (r.theme === 'global') {
        if (r.key === 'typo_base') typoBase = r.value;
        if (r.key === 'typo_scale') typoScale = r.value;
        return;
      }
      /* применяем только к активной теме страницы */
      if (r.theme !== cur) return;
      var v = VAR_MAP[r.key];
      if (v) el.style.setProperty(v, r.value);
      if (r.key === 'accent') accent = r.value;
    });
    if (typoBase) el.style.setProperty('--font-base', typoBase + 'px');
    if (typoScale) el.style.setProperty('--type-scale', (Number(typoScale) / 100));
    /* производный токен: мягкая подложка акцента (плашки, warnbar, hover) —
       в той же пропорции, что базовые темы (тёмная 14%, светлая 10%) */
    if (accent) {
      el.style.setProperty('--accent-soft',
        'color-mix(in srgb, ' + accent + ' ' + (cur === 'dark' ? '14' : '10') + '%, transparent)');
    }
  }

  /* ---------- кэш localStorage: применение до отрисовки, без сети ---------- */
  function cacheSave(rows) {
    try { localStorage.setItem(CACHE_KEY, JSON.stringify(rows || [])); } catch (e) {}
  }
  function cacheLoad() {
    try {
      var s = localStorage.getItem(CACHE_KEY);
      return s ? JSON.parse(s) : null;
    } catch (e) { return null; }
  }
  window.brandCacheSave = cacheSave;
  window.applyBrandCached = function () {
    var rows = cacheLoad();
    if (rows && rows.length) applyVars(rows);
    return !!(rows && rows.length);
  };

  window.loadAndApplyBrand = function (db) {
    var t0 = (window.performance && performance.now) ? performance.now() : Date.now();
    return db.from('brand_colors').select('theme,key,value').then(function (res) {
      if (res.error) throw res.error;
      applyVars(res.data || []);
      cacheSave(res.data || []);            /* кэш для следующих открытий (в т.ч. админки) */
      var t1 = (window.performance && performance.now) ? performance.now() : Date.now();
      var ms = Math.round((t1 - t0) * 100) / 100;
      try { localStorage.setItem('sisku_theme_apply_ms', String(ms)); } catch (e) {}
      if (window.console && console.info) console.info('[sisku] brand theme apply: ' + ms + ' ms');
      return res.data || [];
    });
  };

  window.brandApplyRows = applyVars;   /* для предпросмотра без БД */

  /* ---------- WCAG 2.1: контраст ---------- */
  function lum(hex) {
    var h = String(hex || '').replace('#', '');
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    var c = [0, 2, 4].map(function (i) { return parseInt(h.substr(i, 2), 16) / 255; })
      .map(function (v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  }
  window.brandContrast = function (a, b) {
    var la = lum(a), lb = lum(b);
    if (la < lb) { var t = la; la = lb; lb = t; }
    return Math.round(((la + 0.05) / (lb + 0.05)) * 100) / 100;
  };
  window.brandPairs = function (colors) {
    /* colors: {bg, surface, text, muted, accent, btn_bg, btn_text} */
    return [
      { name: 'Текст / фон', a: colors.text, b: colors.bg, min: 4.5 },
      { name: 'Текст / карточка', a: colors.text, b: colors.card, min: 4.5 },
      { name: 'Второстепенный / фон', a: colors.muted, b: colors.bg, min: 4.5 },
      { name: 'Акцент / фон', a: colors.accent, b: colors.bg, min: 4.5 },
      { name: 'Текст кнопки / кнопка', a: colors.btn_text, b: colors.btn_bg, min: 4.5 }
    ];
  };

  /* v0.13.0: скрипт подключается в <head> и сразу применяет кэш —
     тема брендбука встаёт до первой отрисовки на всех страницах */
  window.applyBrandCached();
})();
