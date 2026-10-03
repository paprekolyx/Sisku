/* ==========================================================================
   SISKU · brandbook.js — «Управление → Брендбук» (v0.11.0-draft)
   Редактор цветов витрины (таблица brand_colors, не site_content):
   • плашки обеих тем как в брендбуке, но с пипеткой и hex-полем;
   • типографика: базовый размер и масштаб заголовков (theme=global);
   • живая проверка контрастов WCAG 2.1 по контрольным парам;
   • предпросмотр на реальных компонентах (отдельная кнопка, модалка);
   • шаблоны палитр: название + комментарий + все значения обеих тем;
   • справка «Брендбук» — окно, идентичное витринному;
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

  var state = { values: { light: {}, dark: {}, global: {} }, templates: [], saving: false };

  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

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
      db.from('brand_templates').select('*').order('created_at', { ascending: false })
    ]).then(function (res) {
      if (res[0].error) throw res[0].error;
      (res[0].data || []).forEach(function (r) {
        state.values[r.theme] = state.values[r.theme] || {};
        state.values[r.theme][r.key] = r.value;
      });
      state.templates = res[1].data || [];
      buildEditors();
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
        var val = state.values[theme][t.key] || '#888888';
        return '<div class="bbe-swatch">' +
          '<input type="color" class="bbe-color" data-theme="' + theme + '" data-key="' + t.key + '" value="' + val + '" aria-label="' + t.name + '">' +
          '<input type="text" class="bbe-hex" data-theme="' + theme + '" data-key="' + t.key + '" value="' + val + '" maxlength="7" aria-label="' + t.name + ' hex">' +
          '<div class="bbe-name">' + t.name + ' · ' + t.key + '</div>' +
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
    $('bb-book').addEventListener('click', function () { $('brandbook-modal-backdrop').classList.add('open'); });
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
