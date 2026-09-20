/* ==========================================================================
   SISKU · mockauth.js — мок-авторизация черновика (v0.4.0-draft)
   Пароля НЕТ в базе: он живёт только здесь и на странице входа (123456),
   чтобы любой смотрящий мог войти. Сессия — флаг в sessionStorage вкладки.
   Для боевой версии заменяется настоящей моделью (migration-plan.md п. 4.3).
   ========================================================================== */
(function () {
  'use strict';
  var KEY = 'sisku_mock_admin';
  var page = (location.pathname.split('/').pop() || 'index.html');

  window.mockLogout = function () {
    try { sessionStorage.removeItem(KEY); } catch (e) {}
    location.replace('login.html');
  };

  if (page === 'login.html') return;   /* страница входа не гейтится */

  var ok = false;
  try { ok = sessionStorage.getItem(KEY) === '1'; } catch (e) {}
  if (!ok) {
    location.replace('login.html?next=' + encodeURIComponent(location.pathname + location.search + location.hash));
  }
})();
