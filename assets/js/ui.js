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
})();
