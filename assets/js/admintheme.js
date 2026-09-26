/* ==========================================================================
   SISKU · admintheme.js — тема админ-страниц (тёмная по умолчанию, выбор
   запоминается). Общая для admin.html, assembly.html, users.html.
   ========================================================================== */
(function () {
  'use strict';
  var KEY = 'sisku_admin_theme';
  function apply(t) {
    document.documentElement.setAttribute('data-theme', t);
    try { localStorage.setItem(KEY, t); } catch (e) {}
  }
  window.currentAdminTheme = function () {
    return document.documentElement.getAttribute('data-theme') === 'light' ? 'light' : 'dark';
  };
  window.initAdminTheme = function (onChange) {
    /* тему ставит инлайн-скрипт в <head> ДО первой отрисовки — моргания нет;
       здесь только привязка переключателя */
    var btn = document.getElementById('admin-theme');
    if (btn) btn.addEventListener('click', function () {
      var cur = window.currentAdminTheme() === 'light' ? 'dark' : 'light';
      apply(cur);
      if (onChange) onChange(cur);
    });
  };
})();
