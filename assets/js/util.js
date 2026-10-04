/* ==========================================================================
   SISKU · util.js — общие утилиты всех модулей (v0.14.0-draft, фикс F32
   независимого ревью: 8+ копий esc/money/maskPhone/… расходились между
   модулями; теперь источник один). Подключается на всех страницах сразу
   после config.js, до ui.js и модулей страниц.

   Состав (window.SiskuUtil):
   • esc(s)            — экранирование HTML (текст и атрибуты);
   • safeUrl(u)        — whitelist схем для href: http/https/mailto/tel и
                         относительные пути; javascript: и protocol-relative
                         отбрасываются (фикс F05); строка предварительно
                         очищается от управляющих символов и пробелов
                         (v0.14.1, ревью N1 — обход «java\tscript:»);
   • money(n)          — «12 345 ₽» (ru-RU, без копеек);
   • fmtDate(iso)      — короткая локальная дата «дд.мм.гггг»;
   • fmtDateTime(iso)  — локальные дата и время «дд.мм.гг чч:мм»;
   • dayKey(d|iso)     — ключ локальной даты YYYY-MM-DD (без UTC-фантома —
                         грабля №4; используется и в именах CSV, фикс F29);
   • maskPhone/maskEmail — маскирование контактов (паттерн учебного проекта);
   • phoneOk/emailOk   — валидация российских форматов (единая маска;
                         emailOk clients.js была упрощённой — унифицировано);
   • phoneKey/emailKey — ЗЕРКАЛО серверных draft_phone_key/draft_email_key
                         (скрипт 15): дедупликация клиентов. Истина — сервер;
   • csvCell(v)        — ячейка CSV: кавычки + анти-формульный префикс '
                         для значений, начинающихся с = + - @ TAB CR
                         (CSV-инъекция формул, фикс F06);
   • friendlyDbError(e)— человекочитаемые сообщения вместо сырых кодов БД
                         (23505/23514/23503/40P01…, фикс F02-фронт);
   • hexToRgba(hex, a) — #rrggbb → rgba() (палитры Chart.js из токенов
                         брендбука, фикс F34).
   ========================================================================== */
(function () {
  'use strict';

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  /* whitelist схем href (фикс F05): http(s)/mailto/tel и относительные пути.
     Всё прочее (javascript:, data:, //host) — пустая строка.
     v0.14.1 (ревью N1): строка сначала очищается от управляющих символов
     и пробелов — браузеры при резолве URL вырезают TAB/LF/CR, поэтому
     'java\tscript:…' без очистки прошёл бы как «относительный путь»
     и в href попал бы исполняемый javascript: */
  function safeUrl(u) {
    var s = String(u == null ? '' : u).replace(/[\u0000-\u0020]/g, '');
    if (!s) return '';
    if (/^(https?:|mailto:|tel:)/i.test(s)) return s;
    if (/^(\/\/|\/\\)/.test(s)) return '';                 /* protocol-relative */
    if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(s)) return '';    /* прочие схемы */
    return s;                                              /* относительный путь */
  }

  function money(n) {
    return new Intl.NumberFormat('ru-RU').format(Math.round(Number(n || 0))) + ' ₽';
  }
  function fmtDate(iso) { return iso ? new Date(iso).toLocaleDateString('ru-RU') : '—'; }
  function fmtDateTime(iso) {
    var d = new Date(iso);
    return d.toLocaleDateString('ru-RU', { day: '2-digit', month: '2-digit', year: '2-digit' }) +
      ' ' + d.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
  }
  /* ключ ЛОКАЛЬНОЙ даты (UTC toISOString() давал фантомный предыдущий день) */
  function dayKey(d) {
    var x = (d instanceof Date) ? d : new Date(d);
    return x.getFullYear() + '-' + String(x.getMonth() + 1).padStart(2, '0') +
      '-' + String(x.getDate()).padStart(2, '0');
  }

  function maskPhone(p) {
    if (!p) return '—';
    if (p.replace(/\D/g, '').length < 5) return p;
    return p.slice(0, Math.max(0, p.length - 9)) + ' ••• •• ' + p.slice(-2);
  }
  function maskEmail(e) {
    if (!e) return '—';
    var at = e.indexOf('@');
    if (at < 1) return e;
    return e[0] + '•••' + e.slice(at);
  }

  function phoneOk(v) {
    return /^(\+7|8)\d{10}$/.test(String(v || '').replace(/[\s()-]/g, ''));
  }
  function emailOk(v) {
    return /^[a-zа-яё0-9._%+-]+@[a-zа-яё0-9-]+(\.[a-zа-яё0-9-]+)*\.[a-zа-яё]{2,}$/i.test(String(v || ''));
  }

  /* зеркало draft_phone_key (скрипт 15): только цифры, ведущая 8 → 7 */
  function phoneKey(v) {
    var d = String(v || '').replace(/\D/g, '');
    if (!d) return null;
    if (d.length === 11 && d[0] === '8') d = '7' + d.slice(1);
    return d;
  }
  /* зеркало draft_email_key (скрипт 15): trim + нижний регистр */
  function emailKey(v) {
    var e = String(v || '').trim().toLowerCase();
    return e || null;
  }

  /* ячейка CSV (фикс F06): значение, начинающееся с = + - @ TAB CR, Excel
     трактует как формулу — ставим защитный префикс '. Числа не трогаем. */
  function csvCell(v) {
    var s = String(v == null ? '' : v);
    if (/^[=+\-@\t\r]/.test(s) && isNaN(Number(s))) s = "'" + s;
    return '"' + s.replace(/"/g, '""') + '"';
  }

  /* человекочитаемые ошибки БД вместо сырых кодов (фикс F02-фронт).
     P0001/P0002 — наши raise exception с готовым текстом. */
  function friendlyDbError(e) {
    if (!e) return 'Неизвестная ошибка';
    if (e.code === 'P0001' || e.code === 'P0002') return e.message;
    if (e.code === '23505') return 'Такие контактные данные уже занимает другой клиент. Измените телефон или e-mail и попробуйте снова.';
    if (e.code === '23514') return 'Недостаточно остатка товара на складе — обновите корзину и попробуйте снова.';
    if (e.code === '23503') return 'Часть данных формы устарела (справочник или товар изменились). Обновите страницу и попробуйте снова.';
    if (e.code === '40P01' || e.code === '40001') return 'Слишком много одновременных операций с заказом. Подождите несколько секунд и попробуйте снова.';
    if (e.code === '42883') return 'База не обновлена: выполните SQL-скрипт последней волны (инструкция — docs/update/, последний update-v0XX.md).';
    return e.message || 'Ошибка базы данных';
  }

  function hexToRgba(hex, a) {
    var h = String(hex || '').replace('#', '');
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    if (!/^[0-9a-fA-F]{6}$/.test(h)) return 'rgba(201,169,106,' + a + ')';
    var r = parseInt(h.substr(0, 2), 16), g = parseInt(h.substr(2, 2), 16), b = parseInt(h.substr(4, 2), 16);
    return 'rgba(' + r + ',' + g + ',' + b + ',' + a + ')';
  }

  window.SiskuUtil = {
    esc: esc, safeUrl: safeUrl, money: money,
    fmtDate: fmtDate, fmtDateTime: fmtDateTime, dayKey: dayKey,
    maskPhone: maskPhone, maskEmail: maskEmail,
    phoneOk: phoneOk, emailOk: emailOk, phoneKey: phoneKey, emailKey: emailKey,
    csvCell: csvCell, friendlyDbError: friendlyDbError, hexToRgba: hexToRgba
  };
})();
