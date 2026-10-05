/* ==========================================================================
   SISKU · brandbook.js — «Управление → Брендбук» (v0.11.0-draft)
   Редактор цветов витрины (таблица brand_colors, не site_content):
   • плашки обеих тем как в брендбуке, но с пипеткой и hex-полем;
   • типографика: базовый размер и масштаб заголовков (theme=global);
   • живая проверка контрастов WCAG 2.1 по контрольным парам;
   • предпросмотр на реальных компонентах (отдельная кнопка, модалка);
   • шаблоны палитр: название + комментарий + все значения обеих тем;
   • справка «Брендбук» — окно, идентичное витринному; с v0.15.0 (правка 2.18)
     палитры справки ЖИВЫЕ — из токенов редактора, обе темы рядом;
   • режим сравнения «сохранённая vs новая (несохранённая)» — правка 2.18;
   • названия тем — изменяемые (правка 2.17): ключи site_content
     theme.light.name/role, theme.dark.name/role (скрипт 20), поля
     редактирования на этой странице; витрина и справка берут имена оттуда;
   • индикатор скорости применения темы на витрине (localStorage-замер).
   ========================================================================== */
(function () {
  'use strict';

  var TOKENS = [
    { key: 'bg', name: 'Фон' },
    { key: 'surface', name: 'Карточки' },
    { key: 'card', name: 'Карточки (внутр.)' },
    { key: 'text', name: 'Текст' },
    { key: 'muted', name: 'Второстепенный' },
    { key: 'accent', name: 'Акцент' },
    { key: 'line', name: 'Линии' },
    { key: 'btn_bg', name: 'Кнопка (фон)' },
    { key: 'btn_text', name: 'Кнопка (текст)' }
  ];

  var state = {
    values: { light: {}, dark: {}, global: {} },
    saved: { light: {}, dark: {}, global: {} },   /* правка 2.18: сохранённая палитра — для режима сравнения */
    names: {},                                    /* правка 2.17: theme.*.name / theme.*.role из site_content */
    templates: [], saving: false, savingNames: false
  };
  var NAME_KEYS = ['theme.light.name', 'theme.light.role', 'theme.dark.name', 'theme.dark.role'];
  var NAME_DEFAULTS = {
    'theme.light.name': 'Ivoire', 'theme.light.role': 'основная тема витрины',
    'theme.dark.name': 'Noir & Champagne', 'theme.dark.role': 'вторая тема'
  };
  function safeHex(v) { return /^#[0-9a-fA-F]{6}$/.test(String(v || '')) ? String(v) : 'transparent'; }
  function copyVals() {
    return {
      light: Object.assign({}, state.values.light),
      dark: Object.assign({}, state.values.dark),
      global: Object.assign({}, state.values.global)
    };
  }

  function $(id) { return document.getElementById(id); }
  /* общие утилиты — assets/js/util.js (v0.14.0, фикс F32: одна копия на проект) */
  var esc = SiskuUtil.esc;

  /* ---------- загрузка ---------- */
  function load() {
    $('bb-error').hidden = true;
    if (!db) {
      $('bb-error').hidden = false;
      $('bb-error').textContent = 'База не подключена: ' + (dbError || 'заполните assets/js/config.js');
      return;
    }
    Promise.all([
      db.from('brand_colors').select('*'),
      db.from('brand_templates').select('*').order('created_at', { ascending: false }),
      /* правка 2.17: названия тем — из site_content (скрипт 20) */
      db.from('site_content').select('key,value').in('key', NAME_KEYS)
    ]).then(function (res) {
      if (res[0].error) throw res[0].error;
      if (res[2] && !res[2].error) {
        state.names = {};
        (res[2].data || []).forEach(function (r) { state.names[r.key] = r.value; });
      }
      (res[0].data || []).forEach(function (r) {
        state.values[r.theme] = state.values[r.theme] || {};
        /* фикс F05 (v0.14.0): значения из БД валидируются до попадания
           в редактор: цвета — строго #rrggbb, типографика — число;
           всё прочее заменяется безопасным дефолтом (stored-XSS закрыт) */
        var v = r.value;
        if (r.theme !== 'global') {
          if (!/^#[0-9a-fA-F]{6}$/.test(String(v || ''))) v = '#888888';
        } else if (!/^\d+(\.\d+)?$/.test(String(v || ''))) {
          v = r.key === 'typo_base' ? '16' : '100';
        }
        state.values[r.theme][r.key] = v;
      });
      state.templates = res[1].data || [];
      buildEditors();
      state.saved = copyVals();   /* правка 2.18: срез сохранённой палитры */
      renderNames();
      renderTemplates();
      refreshContrast();
      refreshSpeed();
    }).catch(function (e) {
      $('bb-error').hidden = false;
      $('bb-error').textContent = 'Ошибка загрузки: ' + e.message;
    });
  }

  /* ---------- редакторы плашек ---------- */
  function buildEditors() {
    ['light', 'dark'].forEach(function (theme) {
      var host = $('bbe-' + theme);
      host.innerHTML = TOKENS.map(function (t) {
        /* фикс F05 (v0.14.0): hex-валидация + esc() — значение из БД
           больше не вставляется в атрибут value="…" сырым */
        var raw = state.values[theme][t.key];
        var val = /^#[0-9a-fA-F]{6}$/.test(String(raw || '')) ? raw : '#888888';
        return '<div class="bbe-swatch">' +
          '<input type="color" class="bbe-color" data-theme="' + theme + '" data-key="' + t.key + '" value="' + esc(val) + '" aria-label="' + esc(t.name) + '">' +
          '<input type="text" class="bbe-hex" data-theme="' + theme + '" data-key="' + t.key + '" value="' + esc(val) + '" maxlength="7" aria-label="' + esc(t.name) + ' hex">' +
          '<div class="bbe-name">' + esc(t.name) + ' · ' + esc(t.key) + '</div>' +
        '</div>';
      }).join('');
    });
    $('bb-typo-base').value = state.values.global.typo_base || 16;
    $('bb-typo-scale').value = state.values.global.typo_scale || 100;
    document.querySelectorAll('.bbe-color, .bbe-hex').forEach(function (inp) {
      inp.addEventListener('input', function () {
        var theme = inp.getAttribute('data-theme'), key = inp.getAttribute('data-key');
        var v = inp.value.trim();
        if (inp.classList.contains('bbe-hex')) {
          if (!/^#[0-9a-fA-F]{6}$/.test(v)) return;
          var colorInput = document.querySelector('.bbe-color[data-theme="' + theme + '"][data-key="' + key + '"]');
          if (colorInput) colorInput.value = v;
        } else {
          var hexInput = document.querySelector('.bbe-hex[data-theme="' + theme + '"][data-key="' + key + '"]');
          if (hexInput) hexInput.value = v;
        }
        state.values[theme][key] = v;
        refreshContrast();
      });
    });
    $('bb-typo-base').addEventListener('input', function () { state.values.global.typo_base = this.value; });
    $('bb-typo-scale').addEventListener('input', function () { state.values.global.typo_scale = this.value; });
  }

  function editorRows() {
    var rows = [];
    ['light', 'dark'].forEach(function (theme) {
      TOKENS.forEach(function (t) {
        rows.push({ theme: theme, key: t.key, value: state.values[theme][t.key] });
      });
    });
    rows.push({ theme: 'global', key: 'typo_base', value: String($('bb-typo-base').value || 16) });
    rows.push({ theme: 'global', key: 'typo_scale', value: String($('bb-typo-scale').value || 100) });
    return rows;
  }

  /* ---------- контрасты WCAG ---------- */
  function refreshContrast() {
    ['light', 'dark'].forEach(function (theme) {
      var c = state.values[theme];
      var pairs = window.brandPairs ? brandPairs(c) : [];
      $('wcag-' + theme).innerHTML = pairs.map(function (p) {
        var r = brandContrast(p.a, p.b);
        var ok = r >= p.min;
        return '<div class="wcag-row"><span>' + esc(p.name) + '</span>' +
          '<span class="wcag-val">' + r + ':1</span>' +
          '<span class="wcag-badge ' + (ok ? 'wcag-ok' : 'wcag-bad') + '">' + (ok ? 'AA' : 'ниже нормы') + '</span></div>';
      }).join('');
    });
  }

  /* ---------- названия тем (правка 2.17) ---------- */
  function themeName(theme) {
    var v = state.names['theme.' + theme + '.name'];
    return (v == null || String(v).trim() === '') ? NAME_DEFAULTS['theme.' + theme + '.name'] : String(v);
  }
  function themeRole(theme) {
    var v = state.names['theme.' + theme + '.role'];
    return (v == null || String(v).trim() === '') ? NAME_DEFAULTS['theme.' + theme + '.role'] : String(v);
  }
  function renderNames() {
    ['light', 'dark'].forEach(function (theme) {
      var full = esc(themeName(theme)) + ' — ' + esc(themeRole(theme));
      var edName = $('bbe-name-' + theme);
      if (edName) edName.innerHTML = full;
      var helpName = $('bbhelp-name-' + theme);
      if (helpName) helpName.innerHTML = full;
      var tag = $('pvf-tag-' + theme);
      if (tag) tag.textContent = themeName(theme);
      $('bb-tn-' + theme).value = themeName(theme);
      $('bb-tr-' + theme).value = themeRole(theme);
    });
  }
  function saveNames() {
    if (state.savingNames) return;
    var rows = [];
    ['light', 'dark'].forEach(function (theme) {
      var n = $('bb-tn-' + theme).value.trim() || NAME_DEFAULTS['theme.' + theme + '.name'];
      var r = $('bb-tr-' + theme).value.trim() || NAME_DEFAULTS['theme.' + theme + '.role'];
      rows.push({ key: 'theme.' + theme + '.name', value: n, updated_at: new Date().toISOString() });
      rows.push({ key: 'theme.' + theme + '.role', value: r, updated_at: new Date().toISOString() });
    });
    state.savingNames = true;
    $('bb-names-save').disabled = true;
    db.from('site_content').upsert(rows, { onConflict: 'key' }).then(function (res) {
      state.savingNames = false;
      $('bb-names-save').disabled = false;
      if (res.error) { $('bb-names-msg').textContent = 'Ошибка: ' + res.error.message; return; }
      rows.forEach(function (r) { state.names[r.key] = r.value; });
      renderNames();
      $('bb-names-msg').textContent = 'Сохранено. Витрина подхватит названия после Ctrl + F5.';
    }).catch(function (e) {
      state.savingNames = false;
      $('bb-names-save').disabled = false;
      $('bb-names-msg').textContent = 'Ошибка сети: ' + e.message;
    });
  }

  /* ---------- справка: живые палитры обеих тем (правка 2.18) ---------- */
  var HELP_TOKENS = [
    { key: 'bg', name: 'Фон' }, { key: 'surface', name: 'Карточки' },
    { key: 'text', name: 'Текст' }, { key: 'muted', name: 'Второстепенный' },
    { key: 'accent', name: 'Акцент' }, { key: 'line', name: 'Линии' }
  ];
  function renderHelp() {
    ['light', 'dark'].forEach(function (theme) {
      var host = $('bbhelp-swatches-' + theme);
      if (!host) return;
      var vals = state.values[theme] || {};
      host.innerHTML = HELP_TOKENS.filter(function (tk) {
        return /^#[0-9a-fA-F]{6}$/.test(String(vals[tk.key] || ''));
      }).map(function (tk) {
        var hex = String(vals[tk.key]).toUpperCase();
        return '<div class="bb-swatch"><div class="color" style="background:' + esc(hex) + '"></div>' +
          '<div class="meta"><b>' + tk.name + '</b>' + esc(hex) + '</div></div>';
      }).join('');
    });
  }

  /* ---------- сравнение «сохранённая vs новая» (правка 2.18) ---------- */
  function renderCompare() {
    function col(title, src, theme) {
      return '<div class="bbc-col"><h4>' + esc(title) + '</h4>' + TOKENS.map(function (tk) {
        var a = String((state.saved[theme] || {})[tk.key] || '').toUpperCase();
        var b = String((state.values[theme] || {})[tk.key] || '').toUpperCase();
        var v = src === 'saved' ? a : b;
        return '<div class="bbc-row' + (a !== b ? ' diff' : '') + '">' +
          '<span class="bbc-name">' + esc(tk.name) + '</span>' +
          '<span class="bbc-chip" style="background:' + safeHex(v) + '"></span>' +
          '<span class="bbc-hex">' + esc(v) + '</span></div>';
      }).join('') + '</div>';
    }
    $('bb-compare-body').innerHTML = ['light', 'dark'].map(function (theme) {
      return '<div><div class="subhead-sm">' + esc(themeName(theme)) + ' — ' + esc(themeRole(theme)) + '</div>' +
        '<div class="bbc-pair">' + col('Текущая сохранённая', 'saved', theme) + col('Новая (в редакторе)', 'cur', theme) + '</div></div>';
    }).join('');
  }

  /* ---------- скорость темы ---------- */
  function refreshSpeed() {
    var ms = null;
    try { ms = localStorage.getItem('sisku_theme_apply_ms'); } catch (e) {}
    $('bb-speed').textContent = ms != null
      ? 'Замер скорости темы: применение токенов на витрине — ' + ms + ' ms (последнее открытие сайта)'
      : 'Замер скорости темы: данных пока нет — откройте витрину с Ctrl + F5';
  }

  /* ---------- сохранение цветов ---------- */
  function saveColors(cb) {
    if (state.saving) return;
    state.saving = true;
    $('bb-save').disabled = true;
    db.from('brand_colors').upsert(editorRows(), { onConflict: 'theme,key' }).then(function (res) {
      state.saving = false;
      $('bb-save').disabled = false;
      if (res.error) {
        $('bb-error').hidden = false;
        $('bb-error').textContent = res.error.message;
        return;
      }
      /* v0.13.0: кэш токенов обновляется сразу — витрина и админка подхватят
         новую палитру до отрисовки, не дожидаясь запроса к базе */
      if (window.brandCacheSave) brandCacheSave(editorRows());
      if (window.applyBrandCached) applyBrandCached();
      state.saved = copyVals();   /* правка 2.18: сохранённая палитра = текущая */
      if (cb) cb();
    }).catch(function (e) {
      state.saving = false;
      $('bb-save').disabled = false;
      $('bb-error').hidden = false;
      $('bb-error').textContent = 'Ошибка сети: ' + e.message;
    });
  }

  /* ---------- предпросмотр ---------- */
  function openPreview() {
    [['light', 'pvf-light'], ['dark', 'pvf-dark']].forEach(function (pair) {
      var c = state.values[pair[0]];
      var el = $(pair[1]);
      el.style.setProperty('--bg', c.bg); el.style.setProperty('--surface', c.surface);
      el.style.setProperty('--card', c.card); el.style.setProperty('--text', c.text);
      el.style.setProperty('--muted', c.muted); el.style.setProperty('--accent', c.accent);
      el.style.setProperty('--line', c.line); el.style.setProperty('--btn-bg', c.btn_bg);
      el.style.setProperty('--btn-text', c.btn_text);
      el.style.setProperty('--font-base', (state.values.global.typo_base || 16) + 'px');
      el.style.setProperty('--type-scale', (Number(state.values.global.typo_scale || 100) / 100));
    });
    $('pv-modal-backdrop').classList.add('open');
  }

  /* ---------- шаблоны ---------- */
  function renderTemplates() {
    $('bt-empty').hidden = state.templates.length !== 0;
    $('bt-body').innerHTML = state.templates.map(function (t) {
      return '<tr>' +
        '<td><b style="font-weight:600">' + esc(t.name) + '</b></td>' +
        '<td class="muted" style="font-size:13px">' + esc(t.comment || '—') + '</td>' +
        '<td class="tabular muted" style="font-size:12.5px;white-space:nowrap">' + new Date(t.created_at).toLocaleDateString('ru-RU') + '</td>' +
        '<td style="white-space:nowrap">' +
          '<button class="btn" data-apply="' + t.id + '" style="min-height:34px;padding:0 14px;margin-right:6px">Применить</button>' +
          '<button class="btn" data-tdel="' + t.id + '" style="min-height:34px;padding:0 14px">Удалить</button>' +
        '</td></tr>';
    }).join('');
  }
  function saveTemplate() {
    var name = $('bt-name').value.trim();
    if (name.length < 3) { alert('Укажите название шаблона'); return; }
    var colors = { light: {}, dark: {}, global: {} };
    editorRows().forEach(function (r) { colors[r.theme][r.key] = r.value; });
    db.from('brand_templates').insert({ name: name, comment: $('bt-comment').value.trim() || null, colors: colors })
      .then(function (res) {
        if (res.error) { alert(res.error.message); return; }
        $('bt-name').value = ''; $('bt-comment').value = '';
        load();
      });
  }
  function applyTemplate(id) {
    var t = state.templates.filter(function (x) { return x.id === id; })[0];
    if (!t) return;
    ['light', 'dark', 'global'].forEach(function (theme) {
      Object.keys(t.colors[theme] || {}).forEach(function (k) {
        state.values[theme] = state.values[theme] || {};
        state.values[theme][k] = t.colors[theme][k];
      });
    });
    buildEditors();
    refreshContrast();
    saveColors(function () { load(); alert('Шаблон «' + t.name + '» применён и сохранён. Витрина и админ-панель обновятся после Ctrl + F5.'); });
  }

  /* ---------- старт ---------- */
  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;
    if (window.initAdminTheme) window.initAdminTheme();
    $('btn-logout').addEventListener('click', function () { if (window.mockLogout) window.mockLogout(); });
    $('bb-refresh').addEventListener('click', load);
    $('bb-save').addEventListener('click', function () {
      saveColors(function () { alert('Цвета сохранены. Откройте витрину или любую страницу админки с Ctrl + F5 — тема применится до отрисовки.'); refreshSpeed(); });
    });
    $('bb-preview').addEventListener('click', openPreview);
    $('bb-book').addEventListener('click', function () {
      renderNames(); renderHelp();   /* правки 2.17/2.18: справка живая — из значений редактора */
      $('brandbook-modal-backdrop').classList.add('open');
    });
    $('bb-compare').addEventListener('click', function () {
      renderCompare();
      $('bb-compare-backdrop').classList.add('open');
    });
    $('bb-names-save').addEventListener('click', saveNames);
    $('bt-save').addEventListener('click', saveTemplate);
    $('bt-body').addEventListener('click', function (e) {
      var ap = e.target.closest('button[data-apply]');
      if (ap) { applyTemplate(Number(ap.getAttribute('data-apply'))); return; }
      var dl = e.target.closest('button[data-tdel]');
      if (dl) {
        var id = Number(dl.getAttribute('data-tdel'));
        var t = state.templates.filter(function (x) { return x.id === id; })[0];
        if (!confirm('Удалить шаблон «' + (t ? t.name : '') + '»?')) return;
        db.from('brand_templates').delete().eq('id', id).then(function (res) {
          if (res.error) { alert(res.error.message); return; }
          load();
        });
      }
    });
    document.querySelectorAll('[data-close]').forEach(function (b) {
      b.addEventListener('click', function () { $(b.getAttribute('data-close')).classList.remove('open'); });
    });
    load();
  });
})();
