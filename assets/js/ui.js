/* ==========================================================================
   SISKU · ui.js — кастомные выпадающие списки (v0.2.0-draft)
   Нативный <select> остаётся в DOM как носитель значения и логики
   (change-события, form-value), но визуально заменён кнопкой + списком
   в стиле сайта. Вызов: enhanceSelects([root]) — идемпотентно.
   ========================================================================== */
(function () {
  'use strict';

  window.enhanceSelects = function (root) {
    (root || document).querySelectorAll('select:not([data-cs-done])').forEach(function (sel) {
      sel.setAttribute('data-cs-done', '1');

      var wrap = document.createElement('div');
      wrap.className = 'cselect';
      sel.parentNode.insertBefore(wrap, sel);
      wrap.appendChild(sel);
      sel.classList.add('cselect-native');

      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'cselect-btn';
      if (sel.disabled) btn.disabled = true;

      var list = document.createElement('ul');
      list.className = 'cselect-list';
      list.setAttribute('role', 'listbox');

      wrap.appendChild(btn);
      wrap.appendChild(list);

      function rebuild() {
        var current = sel.value;
        var selected = sel.options[sel.selectedIndex];
        btn.textContent = selected ? selected.textContent : '';
        btn.disabled = sel.disabled;
        list.innerHTML = '';
        Array.prototype.forEach.call(sel.options, function (o) {
          var li = document.createElement('li');
          li.textContent = o.textContent;
          li.setAttribute('role', 'option');
          if (o.value === current) li.classList.add('active');
          li.addEventListener('mousedown', function (e) { e.preventDefault(); });
          li.addEventListener('click', function () {
            if (sel.value !== o.value) {
              sel.value = o.value;
              sel.dispatchEvent(new Event('change', { bubbles: true }));
            }
            close();
            rebuild();
          });
          list.appendChild(li);
        });
      }
      function open() {
        document.querySelectorAll('.cselect.open').forEach(function (w) {
          if (w !== wrap) w.classList.remove('open');
        });
        wrap.classList.add('open');
        rebuild();
      }
      function close() { wrap.classList.remove('open'); }

      btn.addEventListener('click', function (e) {
        e.preventDefault();
        wrap.classList.contains('open') ? close() : open();
      });
      document.addEventListener('click', function (e) {
        if (!wrap.contains(e.target)) close();
      });
      document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape') close();
      });

      /* внешние страницы могут дёрнуть refresh после динамической подмены option */
      sel.addEventListener('refresh', rebuild);
      rebuild();
    });
  };

  /* ==========================================================================
     v0.7.0: степперы ± для числовых полей и фирменный датапикер
     (нативные спиннеры и календарь браузера скрываются, логика остаётся
     на нативных input — значение и change-события не меняются)
     ========================================================================== */
  window.enhanceNumbers = function (root) {
    (root || document).querySelectorAll('input[type="number"]:not([data-st-done]):not([data-no-stepper])').forEach(function (inp) {
      inp.setAttribute('data-st-done', '1');
      var wrap = document.createElement('div');
      wrap.className = 'stepper';
      inp.parentNode.insertBefore(wrap, inp);
      wrap.appendChild(inp);
      var minus = document.createElement('button');
      minus.type = 'button'; minus.className = 'st-btn minus'; minus.textContent = '−';
      minus.setAttribute('aria-label', 'Уменьшить');
      var plus = document.createElement('button');
      plus.type = 'button'; plus.className = 'st-btn plus'; plus.textContent = '+';
      plus.setAttribute('aria-label', 'Увеличить');
      wrap.appendChild(minus);
      wrap.appendChild(plus);
      function step(dir) {
        var s = Number(inp.step || 1);
        var min = inp.min !== '' ? Number(inp.min) : -Infinity;
        var max = inp.max !== '' ? Number(inp.max) : Infinity;
        var v = Number(inp.value || 0) + dir * s;
        v = Math.min(max, Math.max(min, v));
        inp.value = v;
        inp.dispatchEvent(new Event('input', { bubbles: true }));
        inp.dispatchEvent(new Event('change', { bubbles: true }));
      }
      minus.addEventListener('click', function () { step(-1); });
      plus.addEventListener('click', function () { step(1); });
    });
  };

  window.enhanceDates = function (root) {
    (root || document).querySelectorAll('input[type="date"]:not([data-dp-done])').forEach(function (inp) {
      inp.setAttribute('data-dp-done', '1');
      var wrap = document.createElement('div');
      wrap.className = 'dp';
      inp.parentNode.insertBefore(wrap, inp);
      wrap.appendChild(inp);
      inp.classList.add('dp-native');
      var btn = document.createElement('button');
      btn.type = 'button'; btn.className = 'dp-btn';
      var pop = document.createElement('div');
      pop.className = 'dp-pop';
      wrap.appendChild(btn);
      wrap.appendChild(pop);
      var view = null;
      var MONTHS = ['Январь','Февраль','Март','Апрель','Май','Июнь','Июль','Август','Сентябрь','Октябрь','Ноябрь','Декабрь'];
      function pad(n) { return String(n).padStart(2, '0'); }
      function iso(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
      function fmt(v) { var p = v.split('-'); return p[2] + '.' + p[1] + '.' + p[0]; }
      function label() {
        btn.textContent = inp.value ? fmt(inp.value) : 'дд.мм.гггг';
        btn.classList.toggle('empty', !inp.value);
      }
      function build() {
        var base = view || (inp.value ? new Date(inp.value + 'T00:00:00') : new Date());
        view = new Date(base.getFullYear(), base.getMonth(), 1);
        var y = view.getFullYear(), m = view.getMonth();
        var startDow = (new Date(y, m, 1).getDay() + 6) % 7;
        var days = new Date(y, m + 1, 0).getDate();
        var todayStr = iso(new Date());
        var html = '<div class="dp-head"><button type="button" data-nav="-1" aria-label="Предыдущий месяц">‹</button>' +
          '<span>' + MONTHS[m] + ' ' + y + '</span>' +
          '<button type="button" data-nav="1" aria-label="Следующий месяц">›</button></div>' +
          '<div class="dp-week">' + ['Пн','Вт','Ср','Чт','Пт','Сб','Вс'].map(function (d) { return '<span>' + d + '</span>'; }).join('') + '</div>' +
          '<div class="dp-days">';
        for (var i = 0; i < startDow; i++) html += '<span class="dp-blank"></span>';
        for (var d = 1; d <= days; d++) {
          var cur = y + '-' + pad(m + 1) + '-' + pad(d);
          html += '<button type="button" data-day="' + cur + '" class="' +
            (cur === inp.value ? 'dp-sel ' : '') + (cur === todayStr ? 'dp-today' : '') + '">' + d + '</button>';
        }
        html += '</div><div class="dp-foot"><button type="button" data-clear>Очистить</button>' +
          '<button type="button" data-today>Сегодня</button></div>';
        pop.innerHTML = html;
      }
      function open() { pop.classList.add('open'); build(); }
      function close() { pop.classList.remove('open'); }
      function setVal(v) {
        inp.value = v;
        inp.dispatchEvent(new Event('change', { bubbles: true }));
        label();
      }
      btn.addEventListener('click', function (e) { e.preventDefault(); pop.classList.contains('open') ? close() : open(); });
      pop.addEventListener('click', function (e) {
        var nav = e.target.closest('[data-nav]');
        if (nav) { view = new Date(view.getFullYear(), view.getMonth() + Number(nav.getAttribute('data-nav')), 1); build(); return; }
        var day = e.target.closest('[data-day]');
        if (day) { setVal(day.getAttribute('data-day')); close(); return; }
        if (e.target.closest('[data-clear]')) { setVal(''); close(); return; }
        if (e.target.closest('[data-today]')) { setVal(iso(new Date())); close(); }
      });
      document.addEventListener('click', function (e) { if (!wrap.contains(e.target)) close(); });
      label();
    });
  };
})();
