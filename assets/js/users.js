/* ==========================================================================
   SISKU · users.js — страница «Пользователи» (v0.4.0-draft)
   Черновая ролевая модель: admin (администратор), assembler (сборщик),
   manager (менеджер), partner (бизнес-партнёр). Страницы ролями пока
   не ограничиваются — модель копится для боевой версии.
   Пароль хранится хешем SHA-256 (только для макета!).
   ========================================================================== */
(function () {
  'use strict';

  var ROLES = {
    admin: 'Администратор',
    assembler: 'Сборщик',
    manager: 'Менеджер',
    partner: 'Бизнес-партнёр'
  };

  var state = { users: [], editingId: null };

  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }
  function emailOk(v) {
    return /^[a-zа-яё0-9._%+-]+@[a-zа-яё0-9-]+(\.[a-zа-яё0-9-]+)*\.[a-zа-яё]{2,}$/i.test(v);
  }
  function sha256hex(text) {
    var buf = new TextEncoder().encode(text);
    return crypto.subtle.digest('SHA-256', buf).then(function (d) {
      return Array.prototype.map.call(new Uint8Array(d), function (b) {
        return b.toString(16).padStart(2, '0');
      }).join('');
    });
  }

  /* ---------- список ---------- */
  function load() {
    $('users-loading').hidden = false;
    $('users-empty').hidden = true;
    $('users-error').hidden = true;
    if (!db) {
      $('users-loading').hidden = true;
      $('users-error').hidden = false;
      $('users-error').textContent = 'База не подключена: ' + (dbError || 'заполните assets/js/config.js');
      return;
    }
    db.from('admin_users').select('*').order('id').then(function (res) {
      $('users-loading').hidden = true;
      if (res.error) {
        $('users-error').hidden = false;
        $('users-error').textContent = res.error.message;
        return;
      }
      state.users = res.data || [];
      if (!state.users.length) { $('users-empty').hidden = false; $('users-body').innerHTML = ''; return; }
      $('users-body').innerHTML = state.users.map(function (u) {
        return '<tr>' +
          '<td><b>' + esc(u.fio) + '</b>' + (u.is_active ? '' : ' <span class="muted">(отключён)</span>') + '</td>' +
          '<td class="muted">' + esc(u.email) + '</td>' +
          '<td>' + (u.messenger_url ? '<a href="' + esc(u.messenger_url) + '" target="_blank" rel="noopener">ссылка</a>' : '<span class="muted">—</span>') + '</td>' +
          '<td><span class="role-pill" data-role="' + esc(u.role) + '">' + esc(ROLES[u.role] || u.role) + '</span></td>' +
          '<td class="tabular muted">' + new Date(u.created_at).toLocaleDateString('ru-RU') + '</td>' +
          '<td><button class="btn" data-edit="' + u.id + '" style="min-height:34px;padding:0 14px">Изменить</button></td>' +
        '</tr>';
      }).join('');
    });
  }

  /* ---------- модалка ---------- */
  function openModal(userId) {
    state.editingId = userId || null;
    var u = userId ? state.users.filter(function (x) { return x.id === userId; })[0] : null;
    $('um-title').textContent = u ? 'Редактирование: ' + u.fio : 'Новый администратор';
    $('um-fio').value = u ? u.fio : '';
    $('um-email').value = u ? u.email : '';
    $('um-mess').value = u ? (u.messenger_url || '') : '';
    $('um-role').value = u ? u.role : 'manager';
    $('um-pass').value = '';
    $('um-pass-hint').hidden = !u;
    ['um-fio-err', 'um-email-err', 'um-pass-err', 'um-error'].forEach(function (id) { $(id).hidden = true; });
    $('user-modal-backdrop').classList.add('open');
    if (window.enhanceSelects) enhanceSelects($('user-modal-backdrop'));
  }
  function closeModal() { $('user-modal-backdrop').classList.remove('open'); }

  function save(e) {
    e.preventDefault();
    var errBox = $('um-error');
    errBox.hidden = true;
    var fio = $('um-fio').value.trim();
    var email = $('um-email').value.trim();
    var mess = $('um-mess').value.trim();
    var role = $('um-role').value;
    var pass = $('um-pass').value;
    var ok = true;
    $('um-fio-err').hidden = true; $('um-email-err').hidden = true; $('um-pass-err').hidden = true;
    if (fio.length < 5) { $('um-fio-err').textContent = 'Укажите ФИО полностью'; $('um-fio-err').hidden = false; ok = false; }
    if (!emailOk(email)) { $('um-email-err').textContent = 'Формат почты: name@example.ru'; $('um-email-err').hidden = false; ok = false; }
    if (!state.editingId && pass.length < 6) { $('um-pass-err').textContent = 'Пароль минимум 6 символов'; $('um-pass-err').hidden = false; ok = false; }
    if (state.editingId && pass && pass.length < 6) { $('um-pass-err').textContent = 'Пароль минимум 6 символов'; $('um-pass-err').hidden = false; ok = false; }
    if (!ok) return;

    var finish = function (hash) {
      var row = { fio: fio, email: email, messenger_url: mess || null, role: role, updated_at: new Date().toISOString() };
      if (hash) row.password_hash = hash;
      var q = state.editingId
        ? db.from('admin_users').update(row).eq('id', state.editingId)
        : db.from('admin_users').insert(Object.assign({ password_hash: hash, is_active: true }, row));
      q.then(function (res) {
        if (res.error) { errBox.textContent = res.error.message; errBox.hidden = false; return; }
        closeModal();
        load();
      });
    };
    if (pass) sha256hex(pass).then(finish);
    else finish(null);
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('ver').textContent = SITE_VERSION;
    if (window.initAdminTheme) window.initAdminTheme();
    $('btn-logout').addEventListener('click', function () { if (window.mockLogout) window.mockLogout(); });
    $('btn-refresh').addEventListener('click', load);
    $('btn-new').addEventListener('click', function () { openModal(null); });
    $('user-modal-close').addEventListener('click', closeModal);
    $('user-modal-backdrop').addEventListener('click', function (e) { if (e.target === $('user-modal-backdrop')) closeModal(); });
    $('user-form').addEventListener('submit', save);
    $('users-body').addEventListener('click', function (e) {
      var b = e.target.closest('button[data-edit]');
      if (b) openModal(Number(b.getAttribute('data-edit')));
    });
    load();
  });
})();
